# Bennett-p19b: native `soft_minimumnum` / `soft_maximumnum` thin
# aliases over `soft_fmin` / `soft_fmax`, plus LLVM dispatch for
# `llvm.minimumnum.f64` / `llvm.maximumnum.f64` (LLVM 19+, IEEE 754-2019
# minimumNumber / maximumNumber). Closes the third and final
# Bennett-kh6n future-work stub.
#
# Semantically minimumnum/maximumnum are NaN-absorbing (return non-NaN
# operand if exactly one is NaN; canonical qNaN if both NaN) AND specify
# `-0.0 < +0.0` for the ±0 tie-break. Our existing `soft_fmin` /
# `soft_fmax` (Bennett-k2w6) ALREADY chose the specified ±0 tie-break
# (matches `Base.min` / `Base.max`), so the aliases are bit-identical
# to fmin / fmax. We test the alias-identity invariant explicitly, then
# re-run the full bit-level / IR / subnormal coverage to confirm
# composition with the callee registry and LLVM dispatch.

using Test
using Bennett
using Random

@inline _bits(x::Float64) = reinterpret(UInt64, x)
@inline _flt(x::UInt64)   = reinterpret(Float64, x)

# Reference for NaN-absorbing semantics with specified ±0 tie-break
# (≡ llvm.minimumnum / IEEE 754-2019 minimumNumber). Identical to the
# k2w6 _ref_minNum since soft_fmin already implements this convention.
function _ref_minimumNum(a::Float64, b::Float64)::Float64
    isnan(a) && isnan(b) && return NaN
    isnan(a) && return b
    isnan(b) && return a
    if a == 0.0 && b == 0.0
        return signbit(a) ? a : b
    end
    return a < b ? a : b
end

function _ref_maximumNum(a::Float64, b::Float64)::Float64
    isnan(a) && isnan(b) && return NaN
    isnan(a) && return b
    isnan(b) && return a
    if a == 0.0 && b == 0.0
        return signbit(a) ? b : a
    end
    return a > b ? a : b
end

const P19B_LL = joinpath(@__DIR__, "fixtures", "ll")

@testset "Bennett-p19b: soft_minimumnum / soft_maximumnum + LLVM 19+ dispatch" begin

    @testset "callees registered" begin
        @test Bennett._lookup_callee("soft_minimumnum") === Bennett.soft_minimumnum
        @test Bennett._lookup_callee("soft_maximumnum") === Bennett.soft_maximumnum
    end

    # ---- Alias-identity invariant: soft_minimumnum ≡ soft_fmin bit-for-bit ----

    @testset "alias identity: soft_minimumnum(a,b) === soft_fmin(a,b)" begin
        rng = MersenneTwister(0x7019_b000_1234_abcd)
        for _ in 1:5_000
            a = randn(rng) * exp10(rand(rng) * 4 - 2)
            b = randn(rng) * exp10(rand(rng) * 4 - 2)
            @test Bennett.soft_minimumnum(_bits(a), _bits(b)) ===
                  Bennett.soft_fmin(_bits(a), _bits(b))
            @test Bennett.soft_maximumnum(_bits(a), _bits(b)) ===
                  Bennett.soft_fmax(_bits(a), _bits(b))
        end
        # And on the corner cases that distinguish min/max-style funcs
        for (a, b) in ((NaN, 1.0), (1.0, NaN), (NaN, NaN),
                       (0.0, -0.0), (-0.0, 0.0), (-0.0, -0.0), (0.0, 0.0),
                       (Inf, -Inf), (-Inf, Inf), (Inf, Inf), (-Inf, -Inf),
                       (Inf, 0.0), (-Inf, 0.0), (NaN, Inf), (NaN, -Inf))
            @test Bennett.soft_minimumnum(_bits(a), _bits(b)) ===
                  Bennett.soft_fmin(_bits(a), _bits(b))
            @test Bennett.soft_maximumnum(_bits(a), _bits(b)) ===
                  Bennett.soft_fmax(_bits(a), _bits(b))
        end
    end

    # ---- Bit-level vs IEEE 754-2019 minimumNumber / maximumNumber reference ----

    @testset "soft_minimumnum bit-level vs minimumNumber reference (random pairs)" begin
        rng = MersenneTwister(0x7019_b001_dead_beef)
        for _ in 1:100_000
            a = randn(rng) * exp10(rand(rng) * 4 - 2)
            b = randn(rng) * exp10(rand(rng) * 4 - 2)
            got = _flt(Bennett.soft_minimumnum(_bits(a), _bits(b)))
            expected = _ref_minimumNum(a, b)
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "soft_maximumnum bit-level vs maximumNumber reference (random pairs)" begin
        rng = MersenneTwister(0x7019_b002_cafe_face)
        for _ in 1:100_000
            a = randn(rng) * exp10(rand(rng) * 4 - 2)
            b = randn(rng) * exp10(rand(rng) * 4 - 2)
            got = _flt(Bennett.soft_maximumnum(_bits(a), _bits(b)))
            expected = _ref_maximumNum(a, b)
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "±0 tie-break (sign-aware) — IEEE 754-2019 specification" begin
        # IEEE 754-2019 minimumNumber MUST return -0.0 from min(±0, ±0);
        # maximumNumber MUST return +0.0. (This is the spec tightening
        # vs minNum/maxNum, where the result was "unspecified".)
        for (a, b) in ((-0.0, 0.0), (0.0, -0.0), (-0.0, -0.0), (0.0, 0.0))
            @test _bits(_flt(Bennett.soft_minimumnum(_bits(a), _bits(b)))) ==
                  _bits(_ref_minimumNum(a, b))
            @test _bits(_flt(Bennett.soft_maximumnum(_bits(a), _bits(b)))) ==
                  _bits(_ref_maximumNum(a, b))
        end
    end

    @testset "NaN absorption matrix (IEEE 754-2019 minimumNumber/maximumNumber)" begin
        # Exactly one NaN: return the other operand.
        @test _bits(_flt(Bennett.soft_minimumnum(_bits(NaN), _bits(1.0)))) == _bits(1.0)
        @test _bits(_flt(Bennett.soft_minimumnum(_bits(1.0), _bits(NaN)))) == _bits(1.0)
        @test _bits(_flt(Bennett.soft_maximumnum(_bits(NaN), _bits(1.0)))) == _bits(1.0)
        @test _bits(_flt(Bennett.soft_maximumnum(_bits(1.0), _bits(NaN)))) == _bits(1.0)
        # Both NaN: result is NaN.
        @test isnan(_flt(Bennett.soft_minimumnum(_bits(NaN), _bits(NaN))))
        @test isnan(_flt(Bennett.soft_maximumnum(_bits(NaN), _bits(NaN))))
        # NaN vs ±Inf — Inf wins (NaN absorbed)
        @test _bits(_flt(Bennett.soft_minimumnum(_bits(NaN), _bits(Inf))))  == _bits(Inf)
        @test _bits(_flt(Bennett.soft_minimumnum(_bits(NaN), _bits(-Inf)))) == _bits(-Inf)
        @test _bits(_flt(Bennett.soft_maximumnum(_bits(NaN), _bits(Inf))))  == _bits(Inf)
        @test _bits(_flt(Bennett.soft_maximumnum(_bits(NaN), _bits(-Inf)))) == _bits(-Inf)
        # NaN absorbed by negative zero (NaN replaced by the non-NaN sign)
        @test _bits(_flt(Bennett.soft_minimumnum(_bits(NaN), _bits(-0.0)))) == _bits(-0.0)
        @test _bits(_flt(Bennett.soft_maximumnum(_bits(NaN), _bits(0.0))))  == _bits(0.0)
    end

    @testset "±Inf and finite combinations" begin
        for primitive in (Bennett.soft_minimumnum,)
            ref = _ref_minimumNum
            for (a, b) in ((Inf, -Inf), (Inf, 1.0), (-Inf, 1.0),
                           (Inf, Inf), (-Inf, -Inf), (Inf, 0.0), (-Inf, 0.0))
                got = _flt(primitive(_bits(a), _bits(b)))
                @test _bits(got) == _bits(ref(a, b))
            end
        end
        for primitive in (Bennett.soft_maximumnum,)
            ref = _ref_maximumNum
            for (a, b) in ((Inf, -Inf), (Inf, 1.0), (-Inf, 1.0),
                           (Inf, Inf), (-Inf, -Inf), (Inf, 0.0), (-Inf, 0.0))
                got = _flt(primitive(_bits(a), _bits(b)))
                @test _bits(got) == _bits(ref(a, b))
            end
        end
    end

    # ---- IR-level dispatch (kh6n reject → real native lowering) ----

    @testset "llvm.minimumnum.f64 dispatches via .ll ingest" begin
        path = joinpath(P19B_LL, "p19b_minimumnum_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="p19b_minimumnum_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for (a, b) in ((1.0, 2.0), (-3.5, 0.5),
                       (0.0, -0.0), (-0.0, 0.0),
                       (NaN, 1.0), (1.0, NaN), (NaN, NaN),
                       (Inf, 1.0), (-Inf, 1.0), (Inf, -Inf))
            got = simulate(c, (_bits(a), _bits(b)))
            @test _bits(_flt(got)) == _bits(_ref_minimumNum(a, b))
        end
    end

    @testset "llvm.maximumnum.f64 dispatches via .ll ingest" begin
        path = joinpath(P19B_LL, "p19b_maximumnum_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="p19b_maximumnum_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for (a, b) in ((1.0, 2.0), (-3.5, 0.5),
                       (0.0, -0.0), (-0.0, 0.0),
                       (NaN, 1.0), (1.0, NaN), (NaN, NaN),
                       (Inf, 1.0), (-Inf, 1.0), (Inf, -Inf))
            got = simulate(c, (_bits(a), _bits(b)))
            @test _bits(_flt(got)) == _bits(_ref_maximumNum(a, b))
        end
    end

    @testset "f32 forms still rejected (CLAUDE.md §13)" begin
        for fname in ("p19b_minimumnum_f32_reject.ll",
                      "p19b_maximumnum_f32_reject.ll")
            err = try
                entry = replace(fname, "_reject.ll" => "")
                Bennett.extract_parsed_ir_from_ll(joinpath(P19B_LL, fname);
                                                  entry_function=entry)
                nothing
            catch e
                sprint(showerror, e)
            end
            @test err !== nothing
            @test occursin("f64", err) || occursin("f32", err) || occursin("Bennett-p19b", err)
        end
    end

    # ---- Subnormal-input bit-exactness sweep (per CLAUDE.md §13 spirit) ----

    @testset "subnormal-input bit-exactness sweep (per CLAUDE.md §13 spirit)" begin
        # min/max outputs are always one of the inputs, so subnormal preservation
        # is structural — but sweep all 1074 binades × ± × 4 partner operands × 2
        # primitives to guarantee no precision regression slips in. Mirrors k2w6.
        for shift in 0:1073
            x = ldexp(1.0, -1022 - shift)  # subnormal magnitude
            for s in (1, -1), other in (0.5, -0.5, 1.0, 0.0)
                a = s * x
                @test _bits(_flt(Bennett.soft_minimumnum(_bits(a), _bits(other)))) ==
                      _bits(_ref_minimumNum(a, other))
                @test _bits(_flt(Bennett.soft_maximumnum(_bits(a), _bits(other)))) ==
                      _bits(_ref_maximumNum(a, other))
            end
        end
    end
end
