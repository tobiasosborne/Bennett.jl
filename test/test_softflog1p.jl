# Bennett-0ulc: soft_log1p primitive contract tests.
#
# IEEE 754 binary64 log1p(x) = log(1+x). Two-regime branchless port
# adapting Julia stdlib's precision-recovery formula:
#
#   Regime T (tiny):   |x| < 2^-54   →  return x bit-exactly
#   Regime M (medium): otherwise     →  log(1+x) + (x - ((1+x)-1))/(1+x)
#
# Tier C2.1 — first C2 transcendental close after Tier C1 hyperbolic
# completion.
#
# §13: log1p(subnormal) === subnormal bit-exactly via the tiny regime
# (|x| ≤ 2^-1022 is far below 2^-54).

using Test
using Bennett

ulp_diff_log1p(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        diff = gb >= eb ? gb - eb : eb - gb
        Int64(diff > UInt64(1<<62) ? Int64(1<<62) : diff)
    end
end

soft_log1p_f(x::Float64) =
    reinterpret(Float64, Bennett.soft_log1p(reinterpret(UInt64, x)))

# Julia's log1p throws DomainError for x < -1; wrap for sweeps.
safe_log1p(x) = (x < -1.0) ? NaN : log1p(x)

@testset "Bennett-0ulc: soft_log1p (precision-recovery formula)" begin

    @testset "smoke — both regimes" begin
        # Tiny regime (|x| < 2^-54): bit-exact passthrough.
        for x in (0.0, 1e-20, 1e-100, 1e-300, ldexp(1.0, -1074), ldexp(1.0, -54)/2)
            @test soft_log1p_f( x) ===  x
            @test soft_log1p_f(-x) === -x
        end
        # Medium regime, x > 0.
        for x in (1e-15, 1e-9, 0.001, 0.01, 0.1, 0.5, 1.0, 10.0, 1e10, 1e100)
            @test ulp_diff_log1p(soft_log1p_f(x), log1p(x)) <= 2
        end
        # Medium regime, x < 0 (down to -1).
        for x in (-1e-15, -0.001, -0.1, -0.5, -0.99, -0.999, -0.9999)
            @test ulp_diff_log1p(soft_log1p_f(x), log1p(x)) <= 2
        end
    end

    @testset "specials — bit-exact" begin
        # Sign-preserving zero.
        @test Bennett.soft_log1p(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_log1p(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # log1p(-1) = -Inf.
        @test soft_log1p_f(-1.0) === -Inf
        # log1p(+Inf) = +Inf.
        @test soft_log1p_f(Inf) === Inf
        # NaN propagation.
        @test isnan(soft_log1p_f(NaN))
        @test (Bennett.soft_log1p(reinterpret(UInt64, NaN)) & UInt64(0x0008000000000000)) != UInt64(0)
        # Domain: x < -1 → NaN.
        for x in (-1.0001, -2.0, -10.0, -1e10, -Inf)
            @test isnan(soft_log1p_f(x))
        end
    end

    @testset "subnormal-INPUT bit-exactness (§13 / Bennett-fnxg)" begin
        # All subnormals have |x| < 2^-1022 < 2^-54 → tiny regime →
        # return x bit-exactly. Test all 1074 binades × both signs.
        n_subnormal = 0; n_mismatch = 0
        for binade in -1074:-1023
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                xbits = reinterpret(UInt64, ldexp(1.0, binade)) | sign_bit
                if issubnormal(reinterpret(Float64, xbits))
                    n_subnormal += 1
                end
                got_bits = Bennett.soft_log1p(xbits)
                @test got_bits == xbits
            end
        end
        @test n_subnormal > 0
    end

    @testset "tiny-normal range |x| ∈ (2^-1022, 2^-54): also bit-exact" begin
        # Tiny normals also handled by the tiny regime.
        for binade in -1022:-54
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                xbits = reinterpret(UInt64, ldexp(1.0, binade)) | sign_bit
                @test Bennett.soft_log1p(xbits) == xbits
            end
        end
    end

    @testset "regime boundary — tiny ↔ medium near |x| = 2^-54" begin
        # Just below 2^-54 (tiny): bit-exact x. Just above: medium formula.
        # Both should give ≤2 ULP results.
        for binade in -56:-50
            for sign in (1.0, -1.0)
                x = sign * ldexp(1.0, binade)
                got = soft_log1p_f(x); expected = log1p(x)
                u = ulp_diff_log1p(got, expected)
                @test u <= 2
            end
        end
    end

    @testset "medium-regime fine sweep |x| ∈ (-0.99, 10] step 1e-3" begin
        max_ulp = 0
        x = -0.99
        while x <= 10.0
            got = soft_log1p_f(x); expected = log1p(x)
            u = ulp_diff_log1p(got, expected)
            max_ulp = max(max_ulp, u)
            @test u <= 2
            x += 1.0e-3
        end
        @test max_ulp <= 2
    end

    @testset "100k random sweep, 3 seeds × 5 magnitude buckets" begin
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A2A4E32))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            log1p_max = Int64(0); log1p_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; (rand() - 0.5) * 0.001
                    elseif mag == 2; (rand() - 0.5) * 1.99
                    elseif mag == 3; (rand() - 0.5) * 100.0
                    elseif mag == 4; rand() * 1e10
                    else;            -1.0 + rand() * 0.99
                    end
                got = soft_log1p_f(x); expected = safe_log1p(x)
                if isfinite(expected)
                    u = ulp_diff_log1p(got, expected)
                    log1p_max = max(log1p_max, u); u > 2 && (log1p_fail += 1)
                else
                    (got === expected || (isnan(got) && isnan(expected))) || (log1p_fail += 1)
                end
            end
            @test log1p_fail == 0
            @test log1p_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_log1p") === Bennett.soft_log1p
    end

end
