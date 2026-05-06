# Bennett-o7cy: soft_expm1 primitive contract tests.
#
# IEEE 754 binary64 expm1(x) = exp(x) - 1. Three-regime branchless port:
#   Regime T: |x| < 2^-54  →  return x bit-exactly
#   Regime P: |x| ≤ 0.5    →  K=15 Taylor x · (c1 + x·(c2 + … + x·c15))
#   Regime M: |x| > 0.5    →  exp(x) - 1 (no cancellation since exp clear of 1)
#
# §13: expm1(any subnormal) === subnormal bit-exactly via tiny regime.
# Tier C2.2 — symmetric to soft_log1p (Bennett-0ulc).

using Test
using Bennett

ulp_diff_expm1(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        diff = gb >= eb ? gb - eb : eb - gb
        Int64(diff > UInt64(1<<62) ? Int64(1<<62) : diff)
    end
end

soft_expm1_f(x::Float64) =
    reinterpret(Float64, Bennett.soft_expm1(reinterpret(UInt64, x)))

@testset "Bennett-o7cy: soft_expm1 (Tier C2.2 — symmetric to log1p)" begin

    @testset "smoke — three regimes" begin
        # Tiny regime: bit-exact passthrough.
        for x in (0.0, 1e-20, 1e-100, 1e-300, ldexp(1.0, -1074), ldexp(1.0, -54)/2)
            @test soft_expm1_f( x) ===  x
            @test soft_expm1_f(-x) === -x
        end
        # Polynomial regime, both signs.
        for x in (1e-15, 1e-9, 0.001, 0.01, 0.1, 0.3, 0.5)
            @test ulp_diff_expm1(soft_expm1_f( x), expm1( x)) <= 2
            @test ulp_diff_expm1(soft_expm1_f(-x), expm1(-x)) <= 2
        end
        # Medium regime, both signs.
        for x in (0.5001, 1.0, 2.0, 5.0, 10.0, 50.0, 100.0, 700.0, 709.0)
            @test ulp_diff_expm1(soft_expm1_f( x), expm1( x)) <= 2
            @test ulp_diff_expm1(soft_expm1_f(-x), expm1(-x)) <= 2
        end
    end

    @testset "specials — bit-exact" begin
        @test Bennett.soft_expm1(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_expm1(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        @test soft_expm1_f( Inf) ===  Inf
        @test soft_expm1_f(-Inf) === -1.0
        @test isnan(soft_expm1_f(NaN))
        @test (Bennett.soft_expm1(reinterpret(UInt64, NaN)) & UInt64(0x0008000000000000)) != UInt64(0)
        # Large negative input: expm1(x) → -1 as x → -∞.
        for x in (-50.0, -100.0, -700.0, -800.0, -1e10)
            @test soft_expm1_f(x) === -1.0
        end
        # Large positive input: expm1(x) → +Inf as x → +∞.
        for x in (709.8, 710.0, 1e10, 1e100)
            @test soft_expm1_f(x) === Inf
        end
    end

    @testset "regime boundary — poly ↔ medium at |x| = 0.5" begin
        for δ in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3, 1e-2)
            for sign in (1.0, -1.0)
                xlo = sign * (0.5 - δ); xhi = sign * (0.5 + δ)
                @test ulp_diff_expm1(soft_expm1_f(xlo), expm1(xlo)) <= 2
                @test ulp_diff_expm1(soft_expm1_f(xhi), expm1(xhi)) <= 2
            end
        end
    end

    @testset "subnormal-INPUT bit-exactness (§13 / Bennett-fnxg)" begin
        n_subnormal = 0
        for binade in -1074:-1023
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                xbits = reinterpret(UInt64, ldexp(1.0, binade)) | sign_bit
                if issubnormal(reinterpret(Float64, xbits))
                    n_subnormal += 1
                end
                @test Bennett.soft_expm1(xbits) == xbits
            end
        end
        @test n_subnormal > 0
    end

    @testset "tiny-normal range bit-exact" begin
        for binade in -1022:-54
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                xbits = reinterpret(UInt64, ldexp(1.0, binade)) | sign_bit
                @test Bennett.soft_expm1(xbits) == xbits
            end
        end
    end

    @testset "polynomial-regime fine sweep |x| ∈ [0, 0.5]" begin
        max_ulp = 0
        x = 0.0
        while x <= 0.5
            for s in (1.0, -1.0)
                xs = s * x; got = soft_expm1_f(xs); exp = expm1(xs)
                u = ulp_diff_expm1(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 1.0e-3
        end
        @test max_ulp <= 2
    end

    @testset "medium-regime fine sweep |x| ∈ [0.5, 100]" begin
        max_ulp = 0
        x = 0.5
        while x <= 100.0
            for s in (1.0, -1.0)
                xs = s * x; got = soft_expm1_f(xs); exp = expm1(xs)
                u = ulp_diff_expm1(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 0.05
        end
        @test max_ulp <= 2
    end

    @testset "100k random sweep, 3 seeds × 5 magnitude buckets" begin
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A2A4E32))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            expm1_max = Int64(0); expm1_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; (rand() - 0.5) * 0.001
                    elseif mag == 2; (rand() - 0.5) * 1.0
                    elseif mag == 3; (rand() - 0.5) * 30.0
                    elseif mag == 4; (rand() - 0.5) * 1418.0
                    else;            (rand() - 0.5) * 1e10
                    end
                got = soft_expm1_f(x); expected = expm1(x)
                if isfinite(expected)
                    u = ulp_diff_expm1(got, expected)
                    expm1_max = max(expm1_max, u); u > 2 && (expm1_fail += 1)
                else
                    (got === expected || (isnan(got) && isnan(expected))) || (expm1_fail += 1)
                end
            end
            @test expm1_fail == 0
            @test expm1_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_expm1") === Bennett.soft_expm1
    end

end
