# Bennett-8aes: SoftFloat (the value type `reversible_compile(f, Float64)`
# traces `f` on) lacked Base methods that ordinary Float64 code uses. A missing
# method either threw on the host / died at the VoidType extraction wall
# (mixed `<`, `isnan`, `fma`, `x^2`, mixed `min`, ...) or, worse, fell to a Base
# generic that silently returned the wrong answer at trace time (`isequal`
# defaulted to `==`, so `isequal(NaN, NaN)` was false and
# `isequal(-0.0, 0.0)` true).
#
# Every method added here is checked bit-exactly against native Float64 on
# edge values and a random sweep, and each operator family is compiled to at
# least one circuit checked against native Float64 plus `verify_reversibility`.

using Test
using Bennett
using Random

const E8_SF = Bennett.SoftFloat

@inline _e8_bits(x::Float64) = reinterpret(UInt64, x)
@inline _e8_val(r::E8_SF) = reinterpret(Float64, r.bits)

const E8_EDGE = Float64[0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 0.5, 3.0, -0.75, 1.5,
                        NaN, -NaN, reinterpret(Float64, 0x7ff0000000000001),
                        Inf, -Inf, 5.0e-324, -5.0e-324, 2.2250738585072009e-308,
                        floatmin(Float64), -floatmin(Float64), floatmax(Float64),
                        -floatmax(Float64), 9.007199254740992e15,
                        9.007199254740994e15, 9.223372036854776e18,
                        -9.223372036854776e18, 1.0e300, 1.0e-300]

const E8_INTS = Any[0, 1, -1, 2, -3, 2^53, 2^53 + 1, -(2^53 + 1), typemax(Int64),
                    typemin(Int64), typemax(UInt64), true, false, Int8(-1),
                    UInt8(255), Int128(2)^70, Int128(2)^70 + 1, big(2)^1100]

const E8_REJECT = (1.0f0, Float16(1), 1 // 2, big(1.0), π)

function e8_inputs()
    rng = Random.MersenneTwister(0x8ae5)
    return vcat(E8_EDGE, [reinterpret(Float64, rand(rng, UInt64)) for _ in 1:200],
                [randn(rng) * 4 for _ in 1:100])
end

# Result of `f` on SoftFloat values in native terms (SoftFloat → Float64).
_e8_unwrap(r::E8_SF) = _e8_val(r)
_e8_unwrap(r::Tuple) = map(_e8_unwrap, r)
_e8_unwrap(r) = r

# Bit-exact equality: Float64 results compare by bit pattern (NaN payloads
# too). `nan_any = true` accepts any NaN for a NaN result: Base's min/max
# lower to llvm.minimum/maximum, whose NaN payload is not specified, and
# soft_fminimum/soft_fmaximum return the canonical quiet NaN (Bennett-k2w6).
_e8_same(a::Float64, b::Float64; nan_any = false) =
    _e8_bits(a) == _e8_bits(b) || (nan_any && isnan(a) && isnan(b))
_e8_same(a::Tuple, b::Tuple; nan_any = false) =
    length(a) == length(b) && all(map((x, y) -> _e8_same(x, y; nan_any), a, b))
_e8_same(a, b; nan_any = false) = typeof(a) == typeof(b) && a == b

# Host check: `f` on SoftFloat-wrapped Float64 arguments (other arguments
# passed through; `wrap = false` passes all raw, for mixed-operand lambdas)
# against `ref` (default: `f` itself) on the natives.
function e8_host_mismatches(f, args_list; ref = f, wrap = true, nan_any = false)
    bad = Any[]
    for args in args_list
        want = ref(args...)
        sargs = wrap ? map(a -> a isa Float64 ? E8_SF(a) : a, args) : args
        got = _e8_unwrap(f(sargs...))
        _e8_same(got, want; nan_any) || push!(bad, (args, got, want))
    end
    isempty(bad) || println("  first host mismatches: ", first(bad, 3))
    return bad
end

# Compiled check: circuit for `f` (traced on SoftFloat) against `ref` on Float64.
_e8_expect(r::Float64) = _e8_bits(r)
_e8_expect(r::Bool) = r
function e8_check_circuit(f, n, args_list, label; ref = f, nan_any = false, kw...)
    @testset "$label" begin
        c = reversible_compile(f, ntuple(_ -> Float64, n)...; kw...)
        bad = Any[]
        for args in args_list
            want = _e8_expect(ref(args...))
            bits = map(_e8_bits, args)
            got = simulate(c, n == 1 ? bits[1] : bits)
            got_cmp = want isa Bool ? got : got % UInt64
            ok = got_cmp == want ||
                 (nan_any && !(want isa Bool) && isnan(reinterpret(Float64, got_cmp)) &&
                  isnan(reinterpret(Float64, want)))
            ok || push!(bad, (args, got, want))
        end
        isempty(bad) || println("  first circuit mismatches: ", first(bad, 3))
        @test isempty(bad)
        @test verify_reversibility(c; n_tests=8)
    end
end

@testset "Bennett-8aes: SoftFloat missing Float64 methods" begin
    X = e8_inputs()
    X1 = [(x,) for x in X]
    PAIRS = vcat(vec([(a, b) for a in E8_EDGE, b in E8_EDGE]),
                 [(X[i], X[end + 1 - i]) for i in eachindex(X)])

    @testset "host: predicates and constants" begin
        for f in (isnan, isinf, isfinite, signbit, issubnormal, iszero, isone,
                  zero, one, inv, abs2)
            @test isempty(e8_host_mismatches(f, X1))
        end
        @test zero(E8_SF) === E8_SF(0.0)
        @test one(E8_SF) === E8_SF(1.0)
    end

    @testset "host: ordered comparisons, SoftFloat vs Float64 both orders" begin
        for op in (<, <=, >, >=)
            @test isempty(e8_host_mismatches(op, PAIRS))
            @test isempty(e8_host_mismatches((a, b) -> op(E8_SF(a), b), PAIRS;
                                             ref = op, wrap = false))
            @test isempty(e8_host_mismatches((a, b) -> op(a, E8_SF(b)), PAIRS;
                                             ref = op, wrap = false))
        end
    end

    @testset "host: ordered comparisons vs Integer are exact, both orders" begin
        for op in (<, <=, >, >=), x in E8_EDGE, n in E8_INTS
            @test (op(E8_SF(x), n)) === op(x, n)
            @test (op(n, E8_SF(x))) === op(n, x)
        end
        # 2^53 + 1 rounds to 2^53 as a Float64 but is strictly greater.
        @test (E8_SF(9.007199254740992e15) < 2^53 + 1) === true
        @test (E8_SF(9.007199254740992e15) >= 2^53 + 1) === false
        @test (2^53 + 1 > E8_SF(9.007199254740992e15)) === true
    end

    @testset "host: other Real operands are rejected loudly" begin
        for y in E8_REJECT, op in (<, <=, >, >=, isequal, isless, min, max, minmax)
            @test_throws ArgumentError op(E8_SF(1.0), y)
            @test_throws ArgumentError op(y, E8_SF(1.0))
        end
        @test_throws ArgumentError fma(E8_SF(1.0), 1.0f0, 1.0)
        @test_throws ArgumentError hash(E8_SF(1.0))
        @test_throws ArgumentError hash(E8_SF(1.0), UInt(7))
    end

    @testset "host: isequal / isless / cmp / minmax (total order)" begin
        for f in (isequal, isless, cmp)
            @test isempty(e8_host_mismatches(f, PAIRS))
        end
        @test isempty(e8_host_mismatches(minmax, PAIRS; nan_any = true))
        for f in (isequal, isless)
            @test isempty(e8_host_mismatches((a, b) -> f(E8_SF(a), b), PAIRS;
                                             ref = f, wrap = false))
            @test isempty(e8_host_mismatches((a, b) -> f(a, E8_SF(b)), PAIRS;
                                             ref = f, wrap = false))
            for x in E8_EDGE, n in E8_INTS
                @test f(E8_SF(x), n) === f(x, n)
                @test f(n, E8_SF(x)) === f(n, x)
            end
        end
        # The wrong answers the generic `isequal(x, y) = x == y` gave.
        @test isequal(E8_SF(NaN), E8_SF(-NaN))
        @test !isequal(E8_SF(-0.0), E8_SF(0.0))
        @test !isequal(E8_SF(-0.0), 0)
    end

    @testset "host: isless-based generics (findmin & co, extrema, clamp)" begin
        for f in ((a, b) -> findmin((a, b)), (a, b) -> findmax((a, b)),
                  (a, b) -> argmin((a, b)), (a, b) -> argmax((a, b)),
                  (a, b) -> extrema((a, b)), (a, b) -> Base.isgreater(a, b),
                  (a, b) -> clamp(a, b, 1.0), (a, b) -> clamp(a, -2.0, b))
            @test isempty(e8_host_mismatches(f, PAIRS; nan_any = true))
        end
        for (lo, hi) in ((-1, 1), (0, 2^53 + 1), (-0.5, 0.5), (-Inf, 0))
            @test isempty(e8_host_mismatches(x -> clamp(x, lo, hi), X1))
        end
        @test_throws ArgumentError clamp(E8_SF(2.0), 0.0f0, 1.0f0)
    end

    @testset "host: mixed min / max, both orders" begin
        for f in (min, max, minmax)
            @test isempty(e8_host_mismatches((a, b) -> f(E8_SF(a), b), PAIRS;
                                             ref = f, wrap = false, nan_any = true))
            @test isempty(e8_host_mismatches((a, b) -> f(a, E8_SF(b)), PAIRS;
                                             ref = f, wrap = false, nan_any = true))
            for x in E8_EDGE, n in E8_INTS[1:end-1]   # BigInt promotes to BigFloat
                @test _e8_same(_e8_unwrap(f(E8_SF(x), n)), f(x, n); nan_any = true)
                @test _e8_same(_e8_unwrap(f(n, E8_SF(x))), f(n, x); nan_any = true)
            end
        end
    end

    @testset "host: fma / muladd" begin
        rng = Random.MersenneTwister(0xf3a)
        TRIPLES = vcat(vec([(a, b, c) for a in E8_EDGE[1:12], b in E8_EDGE[1:12],
                                          c in E8_EDGE[[1, 2, 3, 11, 14, 16]]]),
                       [(randn(rng), randn(rng), randn(rng)) for _ in 1:300],
                       [(reinterpret(Float64, rand(rng, UInt64)),
                         reinterpret(Float64, rand(rng, UInt64)),
                         reinterpret(Float64, rand(rng, UInt64))) for _ in 1:300])
        @test isempty(e8_host_mismatches(fma, TRIPLES))
        # muladd routes to soft_fma — the same choice the llvm.fmuladd ingest
        # makes (Bennett-h6f), so the reference is the fused result.
        @test isempty(e8_host_mismatches(muladd, TRIPLES; ref = fma))
        # Mixed Float64 / Integer operands promote to Float64 like Base.
        @test isempty(e8_host_mismatches((a, b, c) -> fma(E8_SF(a), b, 2), TRIPLES;
                                         ref = (a, b, c) -> fma(a, b, 2), wrap = false))
        @test isempty(e8_host_mismatches((a, b, c) -> fma(a, E8_SF(b), c), TRIPLES;
                                         ref = fma, wrap = false))
        @test isempty(e8_host_mismatches((a, b, c) -> muladd(a, b, E8_SF(c)), TRIPLES;
                                         ref = fma, wrap = false))
    end

    @testset "host: integer powers" begin
        for f in (x -> x^0, x -> x^1, x -> x^2, x -> x^3, x -> x^-1, x -> x^-2)
            @test isempty(e8_host_mismatches(f, X1))
        end
        # Non-literal and other literal powers route to soft_pow_julia
        # (bit-exact vs Base.:^ on the host; compiling it is Bennett-bie9).
        safe(f) = (args...) -> try f(args...) catch e; e isa DomainError ? nothing : rethrow() end
        # Skipped: a negative base whose odd power underflows, where
        # soft_pow_julia returns +0.0 for Base's -0.0 (Bennett-u1zi).
        no_u1zi(f) = [(x,) for x in X if !(x < 0 && iszero(f(x)))]
        for f in (x -> x^5, x -> x^-3, x -> x^7)
            @test isempty(e8_host_mismatches(f, no_u1zi(f)))
        end
        for n in (-4, 0, 1, 2, 4, 9, 100, 8193)
            @test isempty(e8_host_mismatches((x, k) -> x^k,
                                             [(x, n) for (x,) in no_u1zi(x -> x^n)]))
        end
        PP = filter(p -> safe(^)(p...) !== nothing, PAIRS)
        @test isempty(e8_host_mismatches((a, b) -> E8_SF(a)^b, PP; ref = ^, wrap = false))
        @test isempty(e8_host_mismatches((a, b) -> a^E8_SF(b), PP; ref = ^, wrap = false))
        @test isempty(e8_host_mismatches(x -> 2^x, [(x,) for x in X if x < 1000]))
        # Exponents beyond Base's power-by-squaring range take a different
        # Base path; rejected rather than approximated.
        @test_throws ArgumentError E8_SF(1.5)^(2^20)
        @test_throws ArgumentError E8_SF(1.5)^(-5000)
        @test_throws ArgumentError E8_SF(1.5)^1.0f0
        @test_throws ArgumentError (1 // 2)^E8_SF(1.5)
    end

    @testset "compiled circuits match native Float64" begin
        # The bead witness.
        e8_check_circuit(x -> ifelse(x < 0.0, -x, x), 1, X1, "ifelse(x < 0.0, -x, x)")
        e8_check_circuit(x -> ifelse(1 > x, x + 1.0, x), 1, X1, "ifelse(1 > x, x + 1.0, x)")
        e8_check_circuit(x -> ifelse(x >= 2^53 + 1, -x, x), 1, X1, "ifelse(x >= 2^53 + 1, -x, x)")
        e8_check_circuit(x -> isnan(x), 1, X1, "isnan(x)")
        e8_check_circuit(x -> ifelse(isinf(x) | signbit(x), 0.0, x), 1, X1,
                         "ifelse(isinf(x) | signbit(x), 0.0, x)")
        e8_check_circuit(x -> isfinite(x) & !issubnormal(x), 1, X1, "isfinite & !issubnormal")
        e8_check_circuit(x -> isequal(x, -0.0), 1, X1, "isequal(x, -0.0)")
        e8_check_circuit((a, b) -> isless(a, b), 2, PAIRS, "isless(a, b)")
        e8_check_circuit(x -> min(x, 1.0), 1, X1, "min(x, 1.0)"; nan_any = true)
        e8_check_circuit(x -> max(2, x), 1, X1, "max(2, x)"; nan_any = true)
        e8_check_circuit(x -> clamp(x, -1, 1), 1, X1, "clamp(x, -1, 1)")
        e8_check_circuit(x -> x^2, 1, X1, "x^2")
        e8_check_circuit(x -> x^3, 1, X1, "x^3")
        # inv = 1.0 / x: soft_fdiv needs a loop bound (cf. test_float_circuit).
        e8_check_circuit(x -> x^-1, 1, X1, "x^-1"; max_loop_iterations = 60)
        e8_check_circuit(x -> x^-2, 1, X1, "x^-2"; max_loop_iterations = 60)
        rng = Random.MersenneTwister(0xf3b)
        T3 = vcat([(a, b, c) for a in E8_EDGE[1:6], b in E8_EDGE[[1, 4, 11, 14]],
                                c in E8_EDGE[[2, 3]]][:],
                  [(randn(rng), randn(rng), randn(rng)) for _ in 1:40])
        e8_check_circuit(fma, 3, T3, "fma(a, b, c)")
        e8_check_circuit(muladd, 3, T3, "muladd(a, b, c)"; ref = fma)
    end
end
