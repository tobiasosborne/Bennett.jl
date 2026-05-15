# Bennett-k2w6: native soft_fmin / soft_fmax / soft_fminimum / soft_fmaximum
# closing the kh6n future-work stub. Two semantic pairs:
#   - soft_fmin / soft_fmax  ≡ llvm.minnum  / llvm.maxnum  (IEEE 754 minNum,
#                                                            NaN-absorbing)
#   - soft_fminimum / soft_fmaximum ≡ llvm.minimum / llvm.maximum
#                                  (IEEE 754-2008 minimum, NaN-propagating —
#                                   matches Julia Base.min/Base.max bit-exactly)

using Test
using Bennett
using Random

@inline _bits(x::Float64) = reinterpret(UInt64, x)
@inline _flt(x::UInt64)   = reinterpret(Float64, x)

# Reference for NaN-absorbing semantics (≡ llvm.minnum / IEEE 754 minNum).
function _ref_minNum(a::Float64, b::Float64)::Float64
    isnan(a) && isnan(b) && return NaN
    isnan(a) && return b
    isnan(b) && return a
    if a == 0.0 && b == 0.0
        return signbit(a) ? a : b
    end
    return a < b ? a : b
end

function _ref_maxNum(a::Float64, b::Float64)::Float64
    isnan(a) && isnan(b) && return NaN
    isnan(a) && return b
    isnan(b) && return a
    if a == 0.0 && b == 0.0
        return signbit(a) ? b : a
    end
    return a > b ? a : b
end

const K2W6_LL = joinpath(@__DIR__, "fixtures", "ll")

@testset "Bennett-k2w6: soft_fmin / soft_fmax / soft_fminimum / soft_fmaximum" begin

    @testset "callees registered" begin
        @test Bennett._lookup_callee("soft_fmin") === Bennett.soft_fmin
        @test Bennett._lookup_callee("soft_fmax") === Bennett.soft_fmax
        @test Bennett._lookup_callee("soft_fminimum") === Bennett.soft_fminimum
        @test Bennett._lookup_callee("soft_fmaximum") === Bennett.soft_fmaximum
    end

    # ---- Bit-level primitives (no IR involved) ----

    @testset "soft_fminimum bit-level vs Base.min (random pairs)" begin
        rng = MersenneTwister(20260515)
        for _ in 1:100_000
            a = randn(rng) * exp10(rand(rng) * 4 - 2)
            b = randn(rng) * exp10(rand(rng) * 4 - 2)
            got = _flt(Bennett.soft_fminimum(_bits(a), _bits(b)))
            expected = min(a, b)
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "soft_fmaximum bit-level vs Base.max (random pairs)" begin
        rng = MersenneTwister(20260515)
        for _ in 1:100_000
            a = randn(rng) * exp10(rand(rng) * 4 - 2)
            b = randn(rng) * exp10(rand(rng) * 4 - 2)
            got = _flt(Bennett.soft_fmaximum(_bits(a), _bits(b)))
            expected = max(a, b)
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "soft_fmin bit-level vs minNum reference (random pairs)" begin
        rng = MersenneTwister(20260516)
        for _ in 1:100_000
            a = randn(rng) * exp10(rand(rng) * 4 - 2)
            b = randn(rng) * exp10(rand(rng) * 4 - 2)
            got = _flt(Bennett.soft_fmin(_bits(a), _bits(b)))
            expected = _ref_minNum(a, b)
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "soft_fmax bit-level vs maxNum reference (random pairs)" begin
        rng = MersenneTwister(20260516)
        for _ in 1:100_000
            a = randn(rng) * exp10(rand(rng) * 4 - 2)
            b = randn(rng) * exp10(rand(rng) * 4 - 2)
            got = _flt(Bennett.soft_fmax(_bits(a), _bits(b)))
            expected = _ref_maxNum(a, b)
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "±0 tie-break (sign-aware)" begin
        # min(±0, ±0) → -0  (or whichever is negative);  max(±0, ±0) → +0
        for (a, b) in ((-0.0, 0.0), (0.0, -0.0), (-0.0, -0.0), (0.0, 0.0))
            @test _bits(_flt(Bennett.soft_fminimum(_bits(a), _bits(b)))) == _bits(min(a, b))
            @test _bits(_flt(Bennett.soft_fmaximum(_bits(a), _bits(b)))) == _bits(max(a, b))
            @test _bits(_flt(Bennett.soft_fmin(_bits(a), _bits(b)))) == _bits(_ref_minNum(a, b))
            @test _bits(_flt(Bennett.soft_fmax(_bits(a), _bits(b)))) == _bits(_ref_maxNum(a, b))
        end
    end

    @testset "NaN propagation: soft_fminimum / soft_fmaximum (IEEE minimum)" begin
        # NaN propagates: min(NaN, x) = NaN for any x (incl. NaN)
        @test isnan(_flt(Bennett.soft_fminimum(_bits(NaN),  _bits(1.0))))
        @test isnan(_flt(Bennett.soft_fminimum(_bits(1.0),  _bits(NaN))))
        @test isnan(_flt(Bennett.soft_fminimum(_bits(NaN),  _bits(NaN))))
        @test isnan(_flt(Bennett.soft_fmaximum(_bits(NaN),  _bits(1.0))))
        @test isnan(_flt(Bennett.soft_fmaximum(_bits(1.0),  _bits(NaN))))
        @test isnan(_flt(Bennett.soft_fmaximum(_bits(NaN),  _bits(NaN))))
        # ±Inf: NaN still propagates
        @test isnan(_flt(Bennett.soft_fminimum(_bits(NaN),  _bits(Inf))))
        @test isnan(_flt(Bennett.soft_fmaximum(_bits(NaN),  _bits(-Inf))))
    end

    @testset "NaN absorption: soft_fmin / soft_fmax (IEEE minNum)" begin
        # Exactly one NaN: return the other operand.
        @test _bits(_flt(Bennett.soft_fmin(_bits(NaN), _bits(1.0)))) == _bits(1.0)
        @test _bits(_flt(Bennett.soft_fmin(_bits(1.0), _bits(NaN)))) == _bits(1.0)
        @test _bits(_flt(Bennett.soft_fmax(_bits(NaN), _bits(1.0)))) == _bits(1.0)
        @test _bits(_flt(Bennett.soft_fmax(_bits(1.0), _bits(NaN)))) == _bits(1.0)
        # Both NaN: result is NaN.
        @test isnan(_flt(Bennett.soft_fmin(_bits(NaN), _bits(NaN))))
        @test isnan(_flt(Bennett.soft_fmax(_bits(NaN), _bits(NaN))))
        # NaN vs Inf
        @test _bits(_flt(Bennett.soft_fmin(_bits(NaN), _bits(Inf))))  == _bits(Inf)
        @test _bits(_flt(Bennett.soft_fmax(_bits(NaN), _bits(-Inf)))) == _bits(-Inf)
    end

    @testset "±Inf and finite combinations" begin
        for primitive in (Bennett.soft_fminimum, Bennett.soft_fmin)
            ref = primitive === Bennett.soft_fminimum ? min : _ref_minNum
            for (a, b) in ((Inf, -Inf), (Inf, 1.0), (-Inf, 1.0),
                           (Inf, Inf), (-Inf, -Inf), (Inf, 0.0), (-Inf, 0.0))
                got = _flt(primitive(_bits(a), _bits(b)))
                @test _bits(got) == _bits(ref(a, b))
            end
        end
        for primitive in (Bennett.soft_fmaximum, Bennett.soft_fmax)
            ref = primitive === Bennett.soft_fmaximum ? max : _ref_maxNum
            for (a, b) in ((Inf, -Inf), (Inf, 1.0), (-Inf, 1.0),
                           (Inf, Inf), (-Inf, -Inf), (Inf, 0.0), (-Inf, 0.0))
                got = _flt(primitive(_bits(a), _bits(b)))
                @test _bits(got) == _bits(ref(a, b))
            end
        end
    end

    @testset "subnormal-input bit-exactness sweep (per CLAUDE.md §13 spirit)" begin
        # Inputs across all 1074 subnormal binades × ±, paired with a
        # representative finite operand. min/max outputs are always one
        # of the inputs, so subnormal preservation is structural — but
        # we sweep to guarantee no loss-of-precision regression slips in.
        for shift in 0:1073
            x = ldexp(1.0, -1022 - shift)  # subnormal magnitude
            for s in (1, -1), other in (0.5, -0.5, 1.0, 0.0)
                a = s * x
                @test _bits(_flt(Bennett.soft_fminimum(_bits(a), _bits(other)))) == _bits(min(a, other))
                @test _bits(_flt(Bennett.soft_fmaximum(_bits(a), _bits(other)))) == _bits(max(a, other))
                @test _bits(_flt(Bennett.soft_fmin(_bits(a), _bits(other)))) == _bits(_ref_minNum(a, other))
                @test _bits(_flt(Bennett.soft_fmax(_bits(a), _bits(other)))) == _bits(_ref_maxNum(a, other))
            end
        end
    end

    # ---- IR-level dispatch (kh6n rejects → real lowering) ----

    @testset "llvm.minimum.f64 dispatches via .ll ingest" begin
        path = joinpath(K2W6_LL, "k2w6_minimum_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="k2w6_minimum_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for (a, b) in ((1.0, 2.0), (-3.5, 0.5), (0.0, -0.0), (Inf, 1.0))
            got = simulate(c, (_bits(a), _bits(b)))
            @test got == _bits(min(a, b))
        end
    end

    @testset "llvm.maximum.f64 dispatches via .ll ingest" begin
        path = joinpath(K2W6_LL, "k2w6_maximum_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="k2w6_maximum_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for (a, b) in ((1.0, 2.0), (-3.5, 0.5), (0.0, -0.0), (-Inf, 1.0))
            got = simulate(c, (_bits(a), _bits(b)))
            @test got == _bits(max(a, b))
        end
    end

    @testset "llvm.minnum.f64 dispatches (NaN-absorbing) via .ll ingest" begin
        path = joinpath(K2W6_LL, "k2w6_minnum_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="k2w6_minnum_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for (a, b) in ((1.0, 2.0), (NaN, 1.0), (1.0, NaN), (0.0, -0.0))
            got = simulate(c, (_bits(a), _bits(b)))
            @test _bits(_flt(got)) == _bits(_ref_minNum(a, b))
        end
    end

    @testset "llvm.maxnum.f64 dispatches (NaN-absorbing) via .ll ingest" begin
        path = joinpath(K2W6_LL, "k2w6_maxnum_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="k2w6_maxnum_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for (a, b) in ((1.0, 2.0), (NaN, -1.0), (-1.0, NaN), (0.0, -0.0))
            got = simulate(c, (_bits(a), _bits(b)))
            @test _bits(_flt(got)) == _bits(_ref_maxNum(a, b))
        end
    end

    @testset "f32 forms still rejected (CLAUDE.md §13)" begin
        for fname in ("k2w6_minimum_f32_reject.ll",
                      "k2w6_maximum_f32_reject.ll",
                      "k2w6_minnum_f32_reject.ll",
                      "k2w6_maxnum_f32_reject.ll")
            err = try
                entry = replace(fname, "_reject.ll" => "")
                Bennett.extract_parsed_ir_from_ll(joinpath(K2W6_LL, fname);
                                                  entry_function=entry)
                nothing
            catch e
                sprint(showerror, e)
            end
            @test err !== nothing
            @test occursin("f64", err) || occursin("f32", err)
        end
    end

    # ---- SoftFloat dispatch (Julia source compile) ----

    @testset "Base.min(::SoftFloat, ::SoftFloat) routes to soft_fminimum" begin
        c = reversible_compile((x, y) -> min(x, y), Float64, Float64)
        @test verify_reversibility(c)
        for (a, b) in ((1.0, 2.0), (-3.5, 0.5), (0.0, -0.0), (Inf, 1.0), (NaN, 1.0))
            got = simulate(c, (_bits(a), _bits(b)))
            @test _bits(_flt(got)) == _bits(min(a, b))
        end
    end

    @testset "Base.max(::SoftFloat, ::SoftFloat) routes to soft_fmaximum" begin
        c = reversible_compile((x, y) -> max(x, y), Float64, Float64)
        @test verify_reversibility(c)
        for (a, b) in ((1.0, 2.0), (-3.5, 0.5), (0.0, -0.0), (-Inf, 1.0), (NaN, 1.0))
            got = simulate(c, (_bits(a), _bits(b)))
            @test _bits(_flt(got)) == _bits(max(a, b))
        end
    end
end
