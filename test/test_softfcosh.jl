# Bennett-bybh: soft_cosh primitive contract tests.
#
# IEEE 754 binary64 hyperbolic cosine on raw bit patterns. Three-regime
# branchless port adapting Julia stdlib `Base.cosh(::Float64)`:
#
#   Regime P (polynomial): |x| ≤ 1.0       →  cosh_kernel(x²)
#   Regime M (medium):     1 < |x| < 709    →  (E + 1/E)/2,  E = exp(|x|)
#   Regime H (huge):       |x| ≥ 709       →  (0.5·E)·E,    E = exp(|x|/2)
#
# Polynomial coefficients verbatim from `Base.cosh_kernel(::Float64)`
# (julia 1.12 base/special/hyperbolic.jl:96-101); ONE soft_exp_fast call
# total via regime-selected argument. Target: ≤2 ULP vs `Base.cosh`
# across the full Float64 range.
#
# §13 (CLAUDE.md / Bennett-fnxg) — DIFFERENT from sinh/tanh:
# cosh(any subnormal) = 1.0 exactly (since 1 + subnormal² rounds to 1.0
# in fp64). The subnormal-input testset asserts `soft_cosh(x) === 1.0`
# for every subnormal binade × both signs (cosh is even, so ±x produce
# the same 1.0 result).
#
# Cosh is EVEN: `cosh(-x) = cosh(x)`. This testset verifies sign-symmetry.
#
# Tier C1.8 in Bennett-Enzyme-Parity-NorthStar.md — third hyperbolic
# primitive (after Bennett-m2bv tanh and Bennett-ky5n sinh).

using Test
using Bennett

ulp_diff_cosh(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        Int64(gb >= eb ? gb - eb : eb - gb)
    end
end

soft_cosh_f(x::Float64) =
    reinterpret(Float64, Bennett.soft_cosh(reinterpret(UInt64, x)))

@testset "Bennett-bybh: soft_cosh (Julia-stdlib regime-split port)" begin

    @testset "smoke — three regimes (poly / medium / huge)" begin
        # Polynomial regime (|x| ≤ 1.0).
        for x in (0.0, 0.1, 0.25, 0.5, 0.75, 0.99, 1.0)
            @test ulp_diff_cosh(soft_cosh_f( x), cosh( x)) <= 2
            @test ulp_diff_cosh(soft_cosh_f(-x), cosh(-x)) <= 2
        end
        # Medium regime (1 < |x| < 709).
        for x in (1.001, 1.4, 1.5, 3.0, 5.0, 10.0, 50.0, 100.0, 500.0, 700.0, 708.99)
            @test ulp_diff_cosh(soft_cosh_f( x), cosh( x)) <= 2
            @test ulp_diff_cosh(soft_cosh_f(-x), cosh(-x)) <= 2
        end
        # Huge regime, finite (|x| ∈ [709, ~710.475]).
        for x in (709.0, 709.5, 709.78, 710.0, 710.4, 710.475)
            @test ulp_diff_cosh(soft_cosh_f( x), cosh( x)) <= 2
            @test ulp_diff_cosh(soft_cosh_f(-x), cosh(-x)) <= 2
        end
        # Huge regime, overflow to +Inf.
        for x in (710.476, 711.0, 1000.0, 1e6, 1e100, prevfloat(Inf))
            @test soft_cosh_f( x) === Inf
            @test soft_cosh_f(-x) === Inf   # even function: cosh(-Inf) = +Inf
        end
    end

    @testset "specials — NaN / ±Inf / ±0 (bit-exact)" begin
        # ±0 → 1.0 (NOT ±0 — cosh(0) = 1, sign discarded).
        @test Bennett.soft_cosh(reinterpret(UInt64,  0.0)) == reinterpret(UInt64, 1.0)
        @test Bennett.soft_cosh(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, 1.0)
        # ±Inf → +Inf (even function).
        @test soft_cosh_f( Inf) === Inf
        @test soft_cosh_f(-Inf) === Inf
        # NaN propagation: result is NaN with quiet-bit set.
        @test isnan(soft_cosh_f(NaN))
        @test (Bennett.soft_cosh(reinterpret(UInt64, NaN)) & UInt64(0x0008000000000000)) != UInt64(0)
        # Signalling-NaN input.
        let snan = reinterpret(Float64, UInt64(0x7FF0000000000001))
            r_bits = Bennett.soft_cosh(reinterpret(UInt64, snan))
            @test isnan(reinterpret(Float64, r_bits))
            @test (r_bits & UInt64(0x0008000000000000)) != UInt64(0)
        end
    end

    @testset "even-function sign symmetry" begin
        # cosh(-x) === cosh(x) bit-exactly for every input.
        for x in (0.0, 0.1, 0.5, 1.0, 1.5, 5.0, 100.0, 709.0, 710.0, 1000.0, Inf)
            @test soft_cosh_f(x) === soft_cosh_f(-x)
        end
    end

    @testset "regime boundary — poly ↔ medium at |x| = 1.0" begin
        for δ in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3, 1e-2, 1e-1)
            for sign in (1.0, -1.0)
                xlo = sign * (1.0 - δ); xhi = sign * (1.0 + δ)
                @test ulp_diff_cosh(soft_cosh_f(xlo), cosh(xlo)) <= 2
                @test ulp_diff_cosh(soft_cosh_f(xhi), cosh(xhi)) <= 2
            end
        end
    end

    @testset "regime boundary — medium ↔ huge at |x| = 709.0" begin
        H = 709.0
        for δ in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3, 1e-2)
            for sign in (1.0, -1.0)
                for xtest in (sign*(H - δ), sign*(H + δ))
                    @test ulp_diff_cosh(soft_cosh_f(xtest), cosh(xtest)) <= 2
                end
            end
        end
    end

    @testset "subnormal-INPUT contract (§13): cosh(subnormal) === 1.0" begin
        # cosh(x) for any subnormal x rounds to 1.0 because 1 + subnormal²
        # = 1.0 exactly in fp64. Polynomial branch handles via:
        # x² → +0, kernel(0) = P0 = 1.0. Test asserts bit-exact 1.0.
        # 2148 signed inputs; cosh is even so positive and negative inputs
        # produce identical results.
        one_bits = reinterpret(UInt64, 1.0)
        n_subnormal = 0; n_normal = 0
        max_ulp_normal = 0
        for binade in -1074:-1
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                xbits = reinterpret(UInt64, ldexp(1.0, binade)) | sign_bit
                xs    = reinterpret(Float64, xbits)
                got_bits = Bennett.soft_cosh(xbits)
                exp_bits = reinterpret(UInt64, cosh(xs))
                if issubnormal(xs)
                    n_subnormal += 1
                    @test got_bits == one_bits   # bit-exact 1.0
                    @test got_bits == exp_bits
                else
                    n_normal += 1
                    ulp = Int64(got_bits >= exp_bits ? got_bits - exp_bits : exp_bits - got_bits)
                    max_ulp_normal = max(max_ulp_normal, ulp)
                end
            end
        end
        @test n_subnormal > 0
        @test max_ulp_normal <= 1   # tiny normals: cosh(x) ≈ 1.0 to ≤1 ULP
    end

    @testset "polynomial-regime fine sweep |x| ∈ [0, 1]" begin
        max_ulp = 0
        x = 0.0
        while x <= 1.0
            for s in (1.0, -1.0)
                xs = s * x; got = soft_cosh_f(xs); exp = cosh(xs)
                u = ulp_diff_cosh(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 1.0e-3
        end
        @test max_ulp <= 2
    end

    @testset "medium-regime fine sweep |x| ∈ [1, 100]" begin
        max_ulp = 0
        x = 1.0
        while x <= 100.0
            for s in (1.0, -1.0)
                xs = s * x; got = soft_cosh_f(xs); exp = cosh(xs)
                u = ulp_diff_cosh(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 0.05
        end
        @test max_ulp <= 2
    end

    @testset "near-overflow regime |x| ∈ [709, 711.5]" begin
        # As with sinh's huge arm, near the overflow boundary the 3
        # chained soft_fmul ops (0.5·E, then ·E) plus soft_exp_fast can
        # accumulate up to 3 ULP. Relaxed bound for |x| ≥ 710.4.
        max_ulp = 0
        x = 709.0
        while x <= 711.5
            for s in (1.0, -1.0)
                xs = s * x; got = soft_cosh_f(xs); expected = cosh(xs)
                if isfinite(expected)
                    u = ulp_diff_cosh(got, expected)
                    max_ulp = max(max_ulp, u)
                    bound = abs(xs) >= 710.4 ? 3 : 2
                    @test u <= bound
                else
                    @test got === expected   # both +Inf (cosh is positive)
                end
            end
            x += 0.005
        end
        @test max_ulp <= 3
        # Pure-overflow checks far from boundary.
        for x in (1000.0, 1e6, 1e100, prevfloat(Inf))
            @test Bennett.soft_cosh(reinterpret(UInt64,  x)) == reinterpret(UInt64, Inf)
            @test Bennett.soft_cosh(reinterpret(UInt64, -x)) == reinterpret(UInt64, Inf)
        end
    end

    @testset "100k random sweep, 3 seeds × 5 magnitude buckets" begin
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A2A4E32))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            cosh_max = Int64(0); cosh_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; (rand() - 0.5) * 2.0
                    elseif mag == 2; (rand() - 0.5) * 10.0
                    elseif mag == 3; (rand() - 0.5) * 200.0
                    elseif mag == 4; (rand() - 0.5) * 1419.0
                    else;            (rand() - 0.5) * 1e6
                    end
                got = soft_cosh_f(x); expected = cosh(x)
                if isfinite(expected)
                    u = ulp_diff_cosh(got, expected)
                    cosh_max = max(cosh_max, u); u > 2 && (cosh_fail += 1)
                else
                    (got === expected || (isnan(got) && isnan(expected))) || (cosh_fail += 1)
                end
            end
            @test cosh_fail == 0
            @test cosh_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_cosh") === Bennett.soft_cosh
    end

end
