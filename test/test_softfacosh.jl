# Bennett-eq9p: soft_acosh primitive contract tests.
#
# IEEE 754 binary64 inverse hyperbolic cosine on raw bit patterns.
# Domain restriction: x < 1 returns NaN (Julia stdlib throws DomainError;
# Bennett can't throw in branchless model). Four-regime branchless port:
#
#   Regime D: x < 1            →  NaN
#   Regime P: 1 ≤ x ≤ 1.3      →  s · acosh_kernel(s²),  s² = 2(x-1)
#   Regime M: 1.3 < x < 2^28   →  log(x + sqrt(x² - 1))
#   Regime H: x ≥ 2^28         →  log(x) + ln(2)
#
# §13: acosh's domain excludes the entire subnormal range. So
# soft_acosh(any subnormal) = NaN — that's the §13 contract for
# domain-restricted transcendentals (parallel to soft_asin: |x| > 1
# returns NaN, NOT preserved).
#
# Tier C1.10 — fifth hyperbolic close after Bennett-m2bv tanh,
# Bennett-ky5n sinh, Bennett-bybh cosh, Bennett-sfx9 asinh.

using Test
using Bennett

ulp_diff_acosh(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        diff = gb >= eb ? gb - eb : eb - gb
        Int64(diff > UInt64(1<<62) ? Int64(1<<62) : diff)
    end
end

soft_acosh_f(x::Float64) =
    reinterpret(Float64, Bennett.soft_acosh(reinterpret(UInt64, x)))

@testset "Bennett-eq9p: soft_acosh (domain-restricted, log1p sidestep via wide poly)" begin

    @testset "smoke — three valid regimes (poly / medium / huge)" begin
        # Polynomial regime (1 ≤ x ≤ 1.3).
        for x in (1.0, 1.0001, 1.001, 1.01, 1.05, 1.1, 1.2, 1.3)
            @test ulp_diff_acosh(soft_acosh_f(x), acosh(x)) <= 2
        end
        # Medium regime (1.3 < x < 2^28).
        for x in (1.3001, 1.4, 1.5, 2.0, 5.0, 10.0, 100.0, 1e6, 1e8)
            @test ulp_diff_acosh(soft_acosh_f(x), acosh(x)) <= 2
        end
        # Huge regime.
        for x in (2.0^28, 2.0^29, 1e15, 1e100, prevfloat(Inf))
            @test ulp_diff_acosh(soft_acosh_f(x), acosh(x)) <= 2
        end
    end

    @testset "specials — exact at x=1, +Inf, NaN" begin
        @test soft_acosh_f(1.0) === 0.0
        @test soft_acosh_f(Inf) === Inf
        @test isnan(soft_acosh_f(NaN))
        @test (Bennett.soft_acosh(reinterpret(UInt64, NaN)) & UInt64(0x0008000000000000)) != UInt64(0)
    end

    @testset "domain — x < 1 returns NaN" begin
        # Negative x, ±0, subnormals, tiny normals, x just below 1 — all NaN.
        for x in (-Inf, -1e100, -1.0, -1e-15, -0.0, 0.0, 1e-15, 0.1, 0.5, 0.9, 0.99,
                  0.999999, prevfloat(1.0))
            @test isnan(soft_acosh_f(x))
        end
    end

    @testset "regime boundary — poly ↔ medium at x = 1.3" begin
        H = 1.3
        for δ in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3, 1e-2)
            @test ulp_diff_acosh(soft_acosh_f(H - δ), acosh(H - δ)) <= 2
            @test ulp_diff_acosh(soft_acosh_f(H + δ), acosh(H + δ)) <= 2
        end
    end

    @testset "regime boundary — medium ↔ huge at x = 2^28" begin
        H = 2.0^28
        for δ in (1.0, 1e3, 1e5, 1e7)
            @test ulp_diff_acosh(soft_acosh_f(H - δ), acosh(H - δ)) <= 2
            @test ulp_diff_acosh(soft_acosh_f(H + δ), acosh(H + δ)) <= 2
        end
    end

    @testset "subnormal-INPUT contract (§13): always NaN" begin
        # Domain-restricted: subnormal < 1 → NaN.
        for binade in -1074:-1
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                xbits = reinterpret(UInt64, ldexp(1.0, binade)) | sign_bit
                @test isnan(reinterpret(Float64, Bennett.soft_acosh(xbits)))
            end
        end
    end

    @testset "polynomial-regime fine sweep |x| ∈ [1, 1.3]" begin
        max_ulp = 0
        x = 1.0
        while x <= 1.3
            got = soft_acosh_f(x); exp = acosh(x)
            u = ulp_diff_acosh(got, exp)
            max_ulp = max(max_ulp, u)
            @test u <= 2
            x += 1e-3
        end
        @test max_ulp <= 2
    end

    @testset "medium-regime fine sweep [1.3, 100]" begin
        max_ulp = 0
        x = 1.3
        while x <= 100.0
            got = soft_acosh_f(x); exp = acosh(x)
            u = ulp_diff_acosh(got, exp)
            max_ulp = max(max_ulp, u)
            @test u <= 2
            x += 0.05
        end
        @test max_ulp <= 2
    end

    @testset "100k random sweep, 3 seeds × 5 magnitude buckets" begin
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A2A4E32))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            acosh_max = Int64(0); acosh_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; 1.0 + rand() * 0.3       # poly
                    elseif mag == 2; 1.3 + rand() * 0.7     # med-small
                    elseif mag == 3; 2.0 + rand() * 200.0
                    elseif mag == 4; 200.0 + rand() * 1e8
                    else;            1e8 + rand() * 1e100
                    end
                got = soft_acosh_f(x); expected = acosh(x)
                if isfinite(expected)
                    u = ulp_diff_acosh(got, expected)
                    acosh_max = max(acosh_max, u); u > 2 && (acosh_fail += 1)
                else
                    (got === expected || (isnan(got) && isnan(expected))) || (acosh_fail += 1)
                end
            end
            @test acosh_fail == 0
            @test acosh_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_acosh") === Bennett.soft_acosh
    end

end
