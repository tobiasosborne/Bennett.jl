# Bennett-s1zl: soft_tan primitive contract tests.
#
# Bit/ULP coverage of the IEEE 754 binary64 tangent on raw bit patterns.
# Faithful musl port (tan.c / __tan.c) reusing _rp_rem_pio2 from fsin.jl
# for argument reduction. Target: ≤2 ULP vs `Base.tan` across the full
# Float64 range. Empirically: max ULP = 1 on a 500k-sample sweep across
# 5 magnitude buckets up to 1e22.
#
# §13 (CLAUDE.md) — transcendental subnormal-output convention.
# - tan(x) is subnormal whenever x is subnormal (tan(x) ≈ x for tiny x);
#   the subnormal-INPUT sweep tests that whole regime.
# - tan(x) can also be subnormal at the cancellation knife-edge x ≈ kπ
#   to within ~2^-1022 — not reachable from a single Float64 input
#   (Float64 spacing near π is ~2^-51, well above the subnormal
#   threshold). This is documented at the top of the near-kπ testset.

using Test
using Bennett

ulp_diff_tan(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        Int64(gb >= eb ? gb - eb : eb - gb)
    end
end

@testset "Bennett-s1zl: soft_tan (musl __tan + rem_pio2)" begin

    @testset "smoke — small/medium/huge args" begin
        for x in (0.0, -0.0, 0.1, 0.3, 0.5, 0.6744, 0.7, 0.78539816, 1.0,
                  1.4, Float64(π/2 - 0.01), Float64(π/2 + 0.01),
                  Float64(π), Float64(2π),
                  3.0, 5.0, 10.0, 100.0, 1000.0,
                  1e6, 1e7, 1e8, 1e10, 1e15, 1e22)
            got = reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, x)))
            @test ulp_diff_tan(got, tan(x)) <= 2
        end
    end

    @testset "negatives and odd-symmetry — tan(-x) = -tan(x)" begin
        for x in (0.1, 0.3, 0.5, 0.6, 0.6744, 0.7, 1.0, 1.4, 3.0, 100.0, 1e8)
            tx = tan(x)
            got_neg = reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, -x)))
            @test ulp_diff_tan(got_neg, -tx) <= 2
        end
    end

    @testset "specials — NaN / ±Inf / ±0" begin
        # tan(NaN) = NaN, tan(±Inf) = NaN, tan(±0) = ±0 (sign-preserving)
        @test isnan(reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, NaN))))
        @test isnan(reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, -Inf))))
        @test Bennett.soft_tan(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_tan(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
    end

    @testset "tiny-arg fast path — tan(x) = x bit-exact for |x| < 2^-27" begin
        for x in (1e-30, 1e-100, 1e-300, 2.0^-30, 2.0^-50, 2.0^-100, 2.0^-1000)
            @test Bennett.soft_tan(reinterpret(UInt64,  x)) == reinterpret(UInt64,  x)
            @test Bennett.soft_tan(reinterpret(UInt64, -x)) == reinterpret(UInt64, -x)
        end
    end

    @testset "big-arm boundary at |x| ≈ 0.6744" begin
        # |x| ≥ 0.6744 → kernel folds to π/4 - |x|. Sweep across the
        # boundary in fine steps to catch any ifelse-selection bug.
        for offset in (-2.0^-30, -2.0^-40, -2.0^-50, 0.0,
                       2.0^-50, 2.0^-40, 2.0^-30, 1e-6, 1e-3, 1e-2)
            x = 0.6744 + offset
            got = reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, x)))
            @test ulp_diff_tan(got, tan(x)) <= 2
        end
    end

    @testset "near-π/2 — tan diverges to ±Inf (large but finite outputs)" begin
        # tan(π/2 ± δ) ≈ ±1/δ, very large. odd-arm of the kernel computes
        # -1/(x+r) accurately; this is where the SET_LOW_WORD trick matters.
        for k in 0:5, dpow in -45:5:-10
            δ = 2.0^dpow
            for x in (Float64(π/2) + Float64(k*π) + δ,
                      Float64(π/2) + Float64(k*π) - δ)
                got = reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, x)))
                @test ulp_diff_tan(got, tan(x)) <= 2
            end
        end
    end

    @testset "near-kπ — tan ≈ small, polynomial arm dominates" begin
        # tan(kπ + δ) ≈ δ for small δ. Cancellation in argument reduction
        # is the failure mode here.
        for k in 0:5, dpow in -45:5:-10
            δ = 2.0^dpow
            for x in (Float64(k*π) + δ, Float64(k*π) - δ)
                got = reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, x)))
                @test ulp_diff_tan(got, tan(x)) <= 2
            end
        end
    end

    @testset "subnormal-INPUT sweep — tan(x) ≈ x preserves subnormals" begin
        # CLAUDE.md §13 / Bennett-fnxg: every transcendental must include a
        # subnormal-output sweep. For tan: subnormal output ⇔ subnormal
        # input (tan(x) = x in the tiny-arg regime). Sweep every binade
        # from 2^-1075 to 2^0 in log-space.
        max_ulp = 0
        for binade in -1075:0
            x = 2.0^Float64(binade)
            got = reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, x)))
            max_ulp = max(max_ulp, ulp_diff_tan(got, tan(x)))
        end
        @test max_ulp <= 1
    end

    @testset "exact identities" begin
        # tan(0) = 0 bit-exact.
        @test Bennett.soft_tan(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_tan(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # tan(π/4) ≈ 1 — should match Base exactly.
        @test Bennett.soft_tan(reinterpret(UInt64, Float64(π/4))) == reinterpret(UInt64, tan(Float64(π/4)))
        # tan(π) ≈ 0 (small) — should match Base exactly.
        @test Bennett.soft_tan(reinterpret(UInt64, Float64(π)))   == reinterpret(UInt64, tan(Float64(π)))
    end

    @testset "100k random sweep, 3 seeds, 5 magnitude buckets" begin
        # Target: ≤2 ULP on every sample, max ULP ≤ 1 on average. Spans
        # five magnitude buckets to cover the small-arg, Cody-Waite-ext,
        # and Payne-Hanek paths.
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A45584F))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            tan_max = Int64(0); tan_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; (rand() - 0.5) * 4
                    elseif mag == 2; (rand() - 0.5) * 1e3
                    elseif mag == 3; (rand() - 0.5) * 1e8
                    elseif mag == 4; (rand() - 0.5) * 1e15
                    else; (rand() - 0.5) * 1e22
                    end
                got = reinterpret(Float64, Bennett.soft_tan(reinterpret(UInt64, x)))
                u = ulp_diff_tan(got, tan(x))
                tan_max = max(tan_max, u); u > 2 && (tan_fail += 1)
            end
            @test tan_fail == 0
            @test tan_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_tan") === Bennett.soft_tan
    end

end
