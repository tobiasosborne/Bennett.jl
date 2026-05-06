# Bennett-g82n: soft_atanh primitive contract tests.
#
# IEEE 754 binary64 inverse hyperbolic tangent. Domain |x| ≤ 1.
# atanh diverges at ±1 (returns ±Inf via natural log propagation).
# Three-regime branchless port:
#
#   Regime D: |x| > 1        →  NaN
#   Regime P: |x| ≤ 0.5      →  x · atanh_kernel(x²)
#   Regime M: 0.5 < |x| ≤ 1  →  copysign(0.5·log((1+|x|)/(1-|x|)), x)
#
# atanh is ODD: atanh(-x) = -atanh(x). At |x| = 1, log(+Inf) = +Inf
# yields ±Inf naturally.
#
# §13: atanh(subnormal) = subnormal bit-exactly (polynomial branch).
#
# Tier C1.11 — FINAL hyperbolic, completes Tier C1 11/11.

using Test
using Bennett

ulp_diff_atanh(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        diff = gb >= eb ? gb - eb : eb - gb
        Int64(diff > UInt64(1<<62) ? Int64(1<<62) : diff)
    end
end

soft_atanh_f(x::Float64) =
    reinterpret(Float64, Bennett.soft_atanh(reinterpret(UInt64, x)))

@testset "Bennett-g82n: soft_atanh (regime-split, log1p sidestep)" begin

    @testset "smoke — two valid regimes (poly / medium)" begin
        for x in (0.0, 1e-15, 1e-9, 0.001, 0.01, 0.1, 0.3, 0.49, 0.5)
            @test ulp_diff_atanh(soft_atanh_f( x), atanh( x)) <= 2
            @test ulp_diff_atanh(soft_atanh_f(-x), atanh(-x)) <= 2
        end
        for x in (0.5001, 0.7, 0.9, 0.99, 0.999, 0.9999, 0.99999)
            @test ulp_diff_atanh(soft_atanh_f( x), atanh( x)) <= 2
            @test ulp_diff_atanh(soft_atanh_f(-x), atanh(-x)) <= 2
        end
    end

    @testset "specials — bit-exact at ±0, ±1, NaN" begin
        @test Bennett.soft_atanh(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_atanh(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        @test soft_atanh_f( 1.0) ===  Inf
        @test soft_atanh_f(-1.0) === -Inf
        @test isnan(soft_atanh_f(NaN))
        @test (Bennett.soft_atanh(reinterpret(UInt64, NaN)) & UInt64(0x0008000000000000)) != UInt64(0)
    end

    @testset "domain — |x| > 1 returns NaN" begin
        for x in (1.0001, 1.5, 2.0, 1e10, 1e100, Inf, -1.0001, -1.5, -2.0, -1e10, -Inf)
            @test isnan(soft_atanh_f(x))
        end
    end

    @testset "regime boundary — poly ↔ medium at |x| = 0.5" begin
        for δ in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3, 1e-2, 1e-1)
            for sign in (1.0, -1.0)
                xlo = sign * (0.5 - δ); xhi = sign * (0.5 + δ)
                @test ulp_diff_atanh(soft_atanh_f(xlo), atanh(xlo)) <= 2
                @test ulp_diff_atanh(soft_atanh_f(xhi), atanh(xhi)) <= 2
            end
        end
    end

    @testset "subnormal-INPUT bit-exactness (§13 / Bennett-fnxg)" begin
        max_ulp_subnormal = 0; n_subnormal = 0
        max_ulp_normal    = 0
        for binade in -1074:-1
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                xbits = reinterpret(UInt64, ldexp(1.0, binade)) | sign_bit
                xs    = reinterpret(Float64, xbits)
                got_bits = Bennett.soft_atanh(xbits)
                exp_bits = reinterpret(UInt64, atanh(xs))
                ulp = Int64(got_bits >= exp_bits ? got_bits - exp_bits : exp_bits - got_bits)
                if issubnormal(xs)
                    n_subnormal += 1
                    max_ulp_subnormal = max(max_ulp_subnormal, ulp)
                else
                    max_ulp_normal = max(max_ulp_normal, ulp)
                end
            end
        end
        @test max_ulp_subnormal == 0
        @test n_subnormal > 0
        @test max_ulp_normal <= 1
    end

    @testset "polynomial-regime fine sweep |x| ∈ [0, 0.5]" begin
        max_ulp = 0
        x = 0.0
        while x <= 0.5
            for s in (1.0, -1.0)
                xs = s * x; got = soft_atanh_f(xs); exp = atanh(xs)
                u = ulp_diff_atanh(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 1.0e-3
        end
        @test max_ulp <= 2
    end

    @testset "medium-regime fine sweep |x| ∈ [0.5, ~1)" begin
        max_ulp = 0
        x = 0.5
        while x <= 0.999
            for s in (1.0, -1.0)
                xs = s * x; got = soft_atanh_f(xs); exp = atanh(xs)
                u = ulp_diff_atanh(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 1.0e-3
        end
        @test max_ulp <= 2
    end

    @testset "100k random sweep, 3 seeds × 5 magnitude buckets" begin
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A2A4E32))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            atanh_max = Int64(0); atanh_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; (rand() - 0.5) * 1.0      # poly
                    elseif mag == 2; (rand() - 0.5) * 1.99   # mostly medium
                    elseif mag == 3; sign(rand()-0.5) * (0.5 + rand()*0.499) # medium tight
                    elseif mag == 4; sign(rand()-0.5) * (0.99 + rand()*0.009) # near boundary
                    else;            (rand() - 0.5) * 4.0  # spans domain (some OOB)
                    end
                got = soft_atanh_f(x)
                # Julia's atanh throws DomainError for |x| > 1.
                expected = abs(x) > 1.0 ? NaN : atanh(x)
                if isfinite(expected)
                    u = ulp_diff_atanh(got, expected)
                    atanh_max = max(atanh_max, u); u > 2 && (atanh_fail += 1)
                else
                    (got === expected || (isnan(got) && isnan(expected))) || (atanh_fail += 1)
                end
            end
            @test atanh_fail == 0
            @test atanh_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_atanh") === Bennett.soft_atanh
    end

end
