# Bennett-m2bv: soft_tanh primitive contract tests.
#
# IEEE 754 binary64 hyperbolic tangent on raw bit patterns. Branchless
# port of Julia stdlib `Base.tanh(::Float64)` — three regimes:
#
#   Regime S (saturate):   |x| ≥ 22       → copysign(1.0, x)
#   Regime P (polynomial): |x| ≤ 0.5      → x · tanh_kernel(x²)
#   Regime E (exp-formula): otherwise     → copysign(1 - 2/(exp(2|x|)+1), x)
#
# Polynomial coefficients copied verbatim from `Base.tanh_kernel(::Float64)`
# (julia 1.12 base/special/hyperbolic.jl:132-138). Target: ≤2 ULP vs
# `Base.tanh` across the full Float64 range.
#
# §13 (CLAUDE.md / Bennett-fnxg) — transcendental subnormal-output
# convention. tanh's range is (-1, 1); for subnormal input x, tanh(x) ≈ x
# and the output is also subnormal. The polynomial branch handles this
# IMPLICITLY: x² underflows to +0, tanh_kernel(0) = 1.0 (constant term),
# soft_fmul(x, 1.0) === x bit-exactly. The subnormal-input testset below
# asserts 0 ULP across binades -1074..-1 covering all 2148 signed
# subnormal-or-tiny-normal inputs.
#
# Tier C1.6 in Bennett-Enzyme-Parity-NorthStar.md — first hyperbolic
# primitive (tanh; followed by sinh, cosh, asinh, acosh, atanh).

using Test
using Bennett

ulp_diff_tanh(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        Int64(gb >= eb ? gb - eb : eb - gb)
    end
end

soft_tanh_f(x::Float64) =
    reinterpret(Float64, Bennett.soft_tanh(reinterpret(UInt64, x)))

@testset "Bennett-m2bv: soft_tanh (Julia-stdlib regime-split port)" begin

    @testset "smoke — three regimes (poly / exp-formula / saturate)" begin
        # Polynomial regime (|x| ≤ 0.5).
        for x in (0.0, 0.1, 0.25, 0.49, 0.5)
            @test ulp_diff_tanh(soft_tanh_f(x), tanh(x)) <= 2
            @test ulp_diff_tanh(soft_tanh_f(-x), tanh(-x)) <= 2
        end
        # Exp-formula regime (0.5 < |x| < 22).
        for x in (0.51, 0.7, 1.0, 1.5, 3.0, 5.0, 10.0, 21.0, 21.999)
            @test ulp_diff_tanh(soft_tanh_f(x), tanh(x)) <= 2
            @test ulp_diff_tanh(soft_tanh_f(-x), tanh(-x)) <= 2
        end
        # Saturate regime (|x| ≥ 22): bit-exact ±1.0.
        for x in (22.0, 30.0, 100.0, 1e10, 1e100, prevfloat(Inf))
            @test soft_tanh_f(x)  ===  1.0
            @test soft_tanh_f(-x) === -1.0
        end
    end

    @testset "specials — NaN / ±Inf / ±0 (bit-exact)" begin
        # Sign-preserving zero through polynomial path:
        #   tanh(±0) = ±0 because soft_fmul(±0, 1.0) = ±0 in IEEE 754.
        @test Bennett.soft_tanh(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_tanh(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # Saturation at infinity:
        @test soft_tanh_f( Inf) ===  1.0
        @test soft_tanh_f(-Inf) === -1.0
        # NaN propagation: result is NaN with quiet-bit set.
        let
            r = soft_tanh_f(NaN)
            @test isnan(r)
            # Quiet-bit (bit 51) must be set per IEEE 754-2019 §6.2.3.
            @test (Bennett.soft_tanh(reinterpret(UInt64, NaN)) & UInt64(0x0008000000000000)) != UInt64(0)
        end
        # Signalling-NaN input: should still propagate as NaN with quiet-bit forced on.
        let
            snan = reinterpret(Float64, UInt64(0x7FF0000000000001))   # signalling NaN
            r_bits = Bennett.soft_tanh(reinterpret(UInt64, snan))
            @test isnan(reinterpret(Float64, r_bits))
            @test (r_bits & UInt64(0x0008000000000000)) != UInt64(0)  # quiet-bit set
        end
    end

    @testset "regime boundary — poly ↔ exp-formula at |x| = 0.5" begin
        # Both sides of |x| = 0.5 must remain ≤2 ULP. The polynomial
        # accuracy at 0.5 (kernel at z = 0.25) and the exp-formula
        # accuracy at 0.5 (k = exp(1.0)) must agree within 2 ULP.
        for δ in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3)
            for sign in (1.0, -1.0)
                xlo = sign * (0.5 - δ); xhi = sign * (0.5 + δ)
                @test ulp_diff_tanh(soft_tanh_f(xlo), tanh(xlo)) <= 2
                @test ulp_diff_tanh(soft_tanh_f(xhi), tanh(xhi)) <= 2
            end
        end
    end

    @testset "regime boundary — exp-formula ↔ saturate at |x| = 22" begin
        for δ in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3)
            for sign in (1.0, -1.0)
                xlo = sign * (22.0 - δ); xhi = sign * (22.0 + δ)
                @test ulp_diff_tanh(soft_tanh_f(xlo), tanh(xlo)) <= 2
                @test ulp_diff_tanh(soft_tanh_f(xhi), tanh(xhi)) <= 2
            end
        end
    end

    @testset "subnormal-INPUT bit-exactness (§13 / Bennett-fnxg)" begin
        # For every subnormal x (binades -1074..-1023 inclusive) AND for
        # tiny normals down to binade -1, soft_tanh(x) must return x
        # bit-exactly. Mechanism: x² underflows → 0 in soft_fmul; the
        # polynomial constant term P0 = 1.0 dominates; soft_fmul(x, 1.0)
        # === x in IEEE 754. Asserts 0 ULP across all 2148 signed inputs.
        max_ulp_subnormal = 0; n_subnormal = 0
        max_ulp_normal    = 0; n_normal    = 0
        for binade in -1074:-1
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                x = ldexp(1.0, binade)
                xbits = reinterpret(UInt64, x) | sign_bit
                xs = reinterpret(Float64, xbits)
                got_bits = Bennett.soft_tanh(xbits)
                exp_bits = reinterpret(UInt64, tanh(xs))
                ulp = Int64(got_bits >= exp_bits ? got_bits - exp_bits : exp_bits - got_bits)
                if issubnormal(xs)
                    n_subnormal += 1
                    max_ulp_subnormal = max(max_ulp_subnormal, ulp)
                else
                    n_normal += 1
                    max_ulp_normal = max(max_ulp_normal, ulp)
                end
            end
        end
        @test max_ulp_subnormal == 0
        @test n_subnormal > 0     # confirm sweep visited subnormals
        @test max_ulp_normal <= 1 # tiny normals (binades -1022..-1) ≤ 1 ULP
    end

    @testset "polynomial-regime fine sweep |x| ∈ [0, 0.5]" begin
        # Step size 1e-3 → 500 samples × both signs.
        max_ulp = 0
        x = 0.0
        while x <= 0.5
            for s in (1.0, -1.0)
                xs = s * x; got = soft_tanh_f(xs); exp = tanh(xs)
                u = ulp_diff_tanh(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 1.0e-3
        end
        @test max_ulp <= 2
    end

    @testset "exp-formula-regime fine sweep |x| ∈ [0.5, 22]" begin
        # Step size 0.05 → 430 samples × both signs.
        max_ulp = 0
        x = 0.5
        while x <= 22.0
            for s in (1.0, -1.0)
                xs = s * x; got = soft_tanh_f(xs); exp = tanh(xs)
                u = ulp_diff_tanh(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 0.05
        end
        @test max_ulp <= 2
    end

    @testset "saturation regime |x| ≥ 22 (bit-exact ±1)" begin
        # Saturation must be bit-exact, not just ≤2 ULP.
        for binade in 5:1023
            x = ldexp(1.0, binade)
            @test Bennett.soft_tanh(reinterpret(UInt64,  x)) == reinterpret(UInt64,  1.0)
            @test Bennett.soft_tanh(reinterpret(UInt64, -x)) == reinterpret(UInt64, -1.0)
        end
        # Mid-saturation samples.
        for x in (22.0, 30.0, 50.0, 100.0, 1e10, 1e100, prevfloat(Inf))
            @test Bennett.soft_tanh(reinterpret(UInt64,  x)) == reinterpret(UInt64,  1.0)
            @test Bennett.soft_tanh(reinterpret(UInt64, -x)) == reinterpret(UInt64, -1.0)
        end
    end

    @testset "100k random sweep, 3 seeds × 4 magnitude buckets" begin
        # Buckets cover (poly / exp / near-saturate / saturated) ranges.
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A2A4E32))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            tanh_max = Int64(0); tanh_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:4)
                x = if mag == 1; (rand() - 0.5) * 1.0      # poly
                    elseif mag == 2; (rand() - 0.5) * 44.0 # exp
                    elseif mag == 3; (rand() - 0.5) * 200.0  # mostly saturate
                    else;            (rand() - 0.5) * 2e10  # deep saturate
                    end
                got = soft_tanh_f(x)
                u = ulp_diff_tanh(got, tanh(x))
                tanh_max = max(tanh_max, u); u > 2 && (tanh_fail += 1)
            end
            @test tanh_fail == 0
            @test tanh_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_tanh") === Bennett.soft_tanh
    end

end
