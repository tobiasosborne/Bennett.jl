# Bennett-4qgq: soft-float min/max must return a NaN operand's exact bit
# pattern (sign, payload, signalling state), not a canonical qNaN.
#
# Which native operation each primitive matches (CLAUDE.md §13, Float64):
#
#   - soft_fminimum / soft_fmaximum  ≡  Base.min / Base.max (Float64), which in
#     Julia 1.12 are Core.Intrinsics.min_float / max_float ≡ llvm.minimum /
#     llvm.maximum. Also the target of `reversible_compile(min, Float64, Float64)`
#     via the SoftFloat dispatch. Reference: Base.min / Base.max, bit-for-bit.
#     Observed native rule (x86-64 lowering of fminimum/fmaximum): one input NaN
#     is returned UNCHANGED (no quieting). Precedence is sign-ordered — for min,
#     P = signbit(a) ? b : a; for max, P = signbit(a) ? a : b; Q = the other; the
#     result is P if P is NaN, else Q. ±0: min → -0, max → +0.
#
#   - soft_fmin / soft_fmax  ≡  llvm.minnum / llvm.maxnum (ll ingest only; no
#     Julia Base function lowers to them). Exactly one NaN → the other operand;
#     both NaN → b unchanged (native x86 llvm.minnum/maxnum, cross-checked below
#     via llvmcall). ±0 is unspecified by the LangRef and deliberately sign-aware
#     here (min → -0, max → +0; Bennett-k2w6), so the ±0 reference is that rule,
#     not the native x86 "return a".
#
#   - soft_minimumnum / soft_maximumnum are aliases of soft_fmin / soft_fmax
#     (Bennett-p19b) and inherit the same NaN rule.

using Test
using Bennett
using Random

@inline _u(x::Float64) = reinterpret(UInt64, x)
@inline _f(x::UInt64)  = reinterpret(Float64, x)
@inline _isnanbits(x::UInt64) =
    (x & 0x7ff0000000000000 == 0x7ff0000000000000) & (x & 0x000fffffffffffff != 0)

@noinline _native_minnum(a::Float64, b::Float64) = Base.llvmcall(("""
    declare double @llvm.minnum.f64(double, double)
    define double @entry(double %a, double %b) {
      %r = call double @llvm.minnum.f64(double %a, double %b)
      ret double %r
    }""", "entry"), Float64, Tuple{Float64,Float64}, a, b)
@noinline _native_maxnum(a::Float64, b::Float64) = Base.llvmcall(("""
    declare double @llvm.maxnum.f64(double, double)
    define double @entry(double %a, double %b) {
      %r = call double @llvm.maxnum.f64(double %a, double %b)
      ret double %r
    }""", "entry"), Float64, Tuple{Float64,Float64}, a, b)

_ref_minimum(a::UInt64, b::UInt64) = _u(min(_f(a), _f(b)))
_ref_maximum(a::UInt64, b::UInt64) = _u(max(_f(a), _f(b)))
function _ref_minnum(a::UInt64, b::UInt64)
    _isnanbits(a) && return b
    _isnanbits(b) && return a
    fa, fb = _f(a), _f(b)
    fa == 0.0 && fb == 0.0 && return signbit(fa) ? a : b
    return fa < fb ? a : b
end
function _ref_maxnum(a::UInt64, b::UInt64)
    _isnanbits(a) && return b
    _isnanbits(b) && return a
    fa, fb = _f(a), _f(b)
    fa == 0.0 && fb == 0.0 && return signbit(fa) ? b : a
    return fa > fb ? a : b
end

const _4QGQ_NANS = UInt64[
    0x7ff8000000000000, 0xfff8000000000000,   # canonical qNaN, both signs
    0x7ff8000000000123, 0xfff8000000000123,   # quiet, payload
    0x7fffffffffffffff, 0xfff8000000000456,   # quiet, all-ones payload / neg
    0x7ff0000000000001, 0xfff0000000000001,   # signalling, minimal payload
    0x7ff4000000000abc, 0xfff7ffffffffffff,   # signalling, other payloads
]
const _4QGQ_OTHERS = UInt64[
    _u(0.0), _u(-0.0), _u(1.0), _u(-1.0), _u(2.5), _u(-1.0e300),
    _u(Inf), _u(-Inf), _u(floatmax(Float64)), _u(-floatmin(Float64)),
    0x0000000000000001, 0x8000000000000001, 0x000fffffffffffff,   # subnormals
]
const _4QGQ_VALS = vcat(_4QGQ_NANS, _4QGQ_OTHERS)

const _4QGQ_PRIMS = (
    ("soft_fminimum",   Bennett.soft_fminimum,   _ref_minimum),
    ("soft_fmaximum",   Bennett.soft_fmaximum,   _ref_maximum),
    ("soft_fmin",       Bennett.soft_fmin,       _ref_minnum),
    ("soft_fmax",       Bennett.soft_fmax,       _ref_maxnum),
    ("soft_minimumnum", Bennett.soft_minimumnum, _ref_minnum),
    ("soft_maximumnum", Bennett.soft_maximumnum, _ref_maxnum),
)

_hex(x::UInt64) = "0x" * string(x; base=16, pad=16)

function _mismatches(f, ref, pairs)
    bad = Tuple{UInt64,UInt64,UInt64,UInt64}[]
    for (a, b) in pairs
        got, exp = f(a, b), ref(a, b)
        got == exp || push!(bad, (a, b, got, exp))
    end
    if !isempty(bad)
        for (a, b, g, e) in first(bad, 5)
            println("  mismatch a=$(_hex(a)) b=$(_hex(b)) got=$(_hex(g)) exp=$(_hex(e))")
        end
    end
    return bad
end

const _4QGQ_MATRIX = [(a, b) for a in _4QGQ_VALS for b in _4QGQ_VALS]

@testset "Bennett-4qgq: soft min/max NaN sign + payload bit-exact" begin

    @testset "references agree with native intrinsics" begin
        # minnum/maxnum model ≡ native x86 llvm.minnum/maxnum on every pair
        # except the deliberately sign-aware ±0 tie.
        nonzero_tie = [(a, b) for (a, b) in _4QGQ_MATRIX
                       if !(_f(a) == 0.0 && _f(b) == 0.0)]
        @test isempty(_mismatches(_ref_minnum, (a, b) -> _u(_native_minnum(_f(a), _f(b))), nonzero_tie))
        @test isempty(_mismatches(_ref_maxnum, (a, b) -> _u(_native_maxnum(_f(a), _f(b))), nonzero_tie))
    end

    @testset "witness: (-qNaN payload 0x123, 1.0)" begin
        w = 0xfff8000000000123
        @test Bennett.soft_fminimum(w, _u(1.0)) == w
        @test Bennett.soft_fmaximum(w, _u(1.0)) == w
        @test Bennett.soft_fminimum(_u(1.0), w) == w
        @test Bennett.soft_fmaximum(_u(1.0), w) == w
    end

    for (name, f, ref) in _4QGQ_PRIMS
        @testset "$name: NaN / ±0 / ±Inf / subnormal matrix (both orders)" begin
            @test isempty(_mismatches(f, ref, _4QGQ_MATRIX))
        end
    end

    @testset "random raw-bit sweep (NaN-heavy)" begin
        rng = MersenneTwister(0x4a9e)
        function draw()
            r = rand(rng, 1:4)
            r == 1 && return rand(rng, UInt64)                                   # anything
            if r == 2                                                            # NaN
                x = rand(rng, UInt64) | 0x7ff0000000000000
                return x & 0x000fffffffffffff == 0 ? x | 0x1 : x
            end
            r == 3 && return rand(rng, UInt64) & 0x800fffffffffffff              # subnormal/±0
            return _u(randn(rng) * exp10(rand(rng) * 20 - 10))                   # normal
        end
        pairs = [(draw(), draw()) for _ in 1:100_000]
        @test count(p -> _isnanbits(p[1]) | _isnanbits(p[2]), pairs) > 30_000
        for (name, f, ref) in _4QGQ_PRIMS
            @test isempty(_mismatches(f, ref, pairs))
        end
    end

    # ---- Compiled circuits: one per primitive family ----
    ll = joinpath(@__DIR__, "fixtures", "ll")
    circuits = (
        ("min (SoftFloat → soft_fminimum)", () -> reversible_compile((x, y) -> min(x, y), Float64, Float64), _ref_minimum),
        ("max (SoftFloat → soft_fmaximum)", () -> reversible_compile((x, y) -> max(x, y), Float64, Float64), _ref_maximum),
        ("llvm.minnum.f64 → soft_fmin", () -> reversible_compile(Bennett.extract_parsed_ir_from_ll(
            joinpath(ll, "k2w6_minnum_f64.ll"); entry_function="k2w6_minnum_f64")), _ref_minnum),
        ("llvm.maxnum.f64 → soft_fmax", () -> reversible_compile(Bennett.extract_parsed_ir_from_ll(
            joinpath(ll, "k2w6_maxnum_f64.ll"); entry_function="k2w6_maxnum_f64")), _ref_maxnum),
    )
    for (name, build, ref) in circuits
        @testset "circuit: $name" begin
            c = build()
            @test verify_reversibility(c)
            sim(a, b) = simulate(c, (a, b)) % UInt64
            @test isempty(_mismatches(sim, ref, _4QGQ_MATRIX))
        end
    end
end
