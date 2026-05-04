# Bennett-qpke: soft_atan primitive contract tests.
#
# Bit/ULP coverage of the IEEE 754 binary64 arctangent on raw bit
# patterns. Faithful musl port (atan.c) — branchless, no `_rp_rem_pio2`
# dependency (atan's argument reduction is bounded-range rational maps,
# not Cody-Waite/Payne-Hanek). Target: ≤2 ULP vs `Base.atan` across the
# full Float64 range.
#
# §13 (CLAUDE.md) — transcendental subnormal-output convention.
# `Base.atan(x)` is subnormal whenever |x| ≤ ~2^-1022 (atan(x) ≈ x for
# tiny x); the subnormal-INPUT sweep below covers the entire
# subnormal-output regime. Subnormal-output cannot otherwise occur (atan
# range is bounded by π/2; near the bounds output is normal not
# subnormal).

using Test
using Bennett

ulp_diff_atan(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        Int64(gb >= eb ? gb - eb : eb - gb)
    end
end

@testset "Bennett-qpke: soft_atan (musl atan.c branchless)" begin

    @testset "smoke — small/medium/huge args" begin
        for x in (0.0, -0.0,
                  # tiny path
                  1e-30, 1e-100, 1e-300, 2.0^-30, 2.0^-50,
                  # id = -1 path
                  0.1, 0.2, 0.3, 0.4,
                  # id = 0 path (0.4375 ≤ |x| < 11/16)
                  0.4375, 0.5, 0.6, 0.6875,
                  # id = 1 path (11/16 ≤ |x| < 19/16)
                  0.7, 0.8, 0.9, 1.0, 1.1, 1.1875,
                  # id = 2 path (19/16 ≤ |x| < 39/16)
                  1.2, 1.3, 1.5, 1.8, 2.0, 2.4375,
                  # id = 3 path (39/16 ≤ |x| < 2^66)
                  2.5, 3.0, 5.0, 10.0, 100.0, 1000.0,
                  1e6, 1e10, 1e15, 1e20,
                  # huge path (|x| ≥ 2^66)
                  2.0^66, 2.0^100, 2.0^500, 1e300)
            got = reinterpret(Float64, Bennett.soft_atan(reinterpret(UInt64, x)))
            @test ulp_diff_atan(got, atan(x)) <= 2
        end
    end

    @testset "negatives and odd-symmetry — atan(-x) = -atan(x)" begin
        for x in (0.1, 0.3, 0.4375, 0.5, 0.6875, 0.8, 1.0, 1.1875, 1.5, 2.4375,
                  3.0, 100.0, 1e10, 2.0^66, 1e300)
            ax = atan(x)
            got_neg = reinterpret(Float64, Bennett.soft_atan(reinterpret(UInt64, -x)))
            @test ulp_diff_atan(got_neg, -ax) <= 2
        end
    end

    @testset "specials — NaN / ±Inf / ±0" begin
        # atan(NaN) = NaN, atan(±Inf) = ±π/2, atan(±0) = ±0 (sign-preserving).
        @test isnan(reinterpret(Float64, Bennett.soft_atan(reinterpret(UInt64, NaN))))
        # ±Inf → ±π/2 bit-exact (huge path returns ATAN_HI_3).
        @test Bennett.soft_atan(reinterpret(UInt64,  Inf)) == reinterpret(UInt64,  Float64(π/2))
        @test Bennett.soft_atan(reinterpret(UInt64, -Inf)) == reinterpret(UInt64, -Float64(π/2))
        # ±0 → ±0 bit-exact (sign-preserving).
        @test Bennett.soft_atan(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_atan(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
    end

    @testset "tiny-arg fast path — atan(x) = x bit-exact for |x| < 2^-27" begin
        for x in (1e-30, 1e-100, 1e-300, 2.0^-30, 2.0^-50, 2.0^-100, 2.0^-1000)
            @test Bennett.soft_atan(reinterpret(UInt64,  x)) == reinterpret(UInt64,  x)
            @test Bennett.soft_atan(reinterpret(UInt64, -x)) == reinterpret(UInt64, -x)
        end
    end

    @testset "huge-arg fast path — |x| ≥ 2^66 → ±π/2" begin
        for x in (2.0^66, 2.0^67, 2.0^100, 2.0^500, 1e150, 1e300)
            @test Bennett.soft_atan(reinterpret(UInt64,  x)) == reinterpret(UInt64,  Float64(π/2))
            @test Bennett.soft_atan(reinterpret(UInt64, -x)) == reinterpret(UInt64, -Float64(π/2))
        end
    end

    @testset "range-split boundaries (id transitions)" begin
        # The four range-split boundaries: 0.4375, 11/16, 19/16, 39/16.
        # Any ifelse-selection bug between adjacent ids will surface here.
        for boundary in (0.4375, 11/16, 19/16, 39/16)
            for offset in (-2.0^-30, -2.0^-40, -2.0^-50, 0.0,
                           2.0^-50, 2.0^-40, 2.0^-30, 1e-6, 1e-3)
                x = boundary + offset
                got = reinterpret(Float64, Bennett.soft_atan(reinterpret(UInt64, x)))
                @test ulp_diff_atan(got, atan(x)) <= 2
                got_neg = reinterpret(Float64, Bennett.soft_atan(reinterpret(UInt64, -x)))
                @test ulp_diff_atan(got_neg, atan(-x)) <= 2
            end
        end
    end

    @testset "exact identities" begin
        # atan(0) = 0 bit-exact.
        @test Bennett.soft_atan(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_atan(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # atan(1) ≈ π/4 — should match Base exactly (id = 1 path, x' = 0).
        @test Bennett.soft_atan(reinterpret(UInt64,  1.0)) == reinterpret(UInt64, atan( 1.0))
        @test Bennett.soft_atan(reinterpret(UInt64, -1.0)) == reinterpret(UInt64, atan(-1.0))
        # atan(0.5), atan(1.5) — id = 0 / id = 2 paths with x' = 0.
        @test Bennett.soft_atan(reinterpret(UInt64, 0.5)) == reinterpret(UInt64, atan(0.5))
        @test Bennett.soft_atan(reinterpret(UInt64, 1.5)) == reinterpret(UInt64, atan(1.5))
    end

    @testset "subnormal-INPUT sweep — atan(x) ≈ x preserves subnormals" begin
        # CLAUDE.md §13 / Bennett-fnxg: every transcendental must include a
        # subnormal-output sweep. For atan: subnormal output ⇔ subnormal
        # input (atan(x) = x in the tiny-arg regime; atan's range is
        # bounded by π/2, no other subnormal-output regime exists).
        # Sweep every binade from 2^-1075 to 2^0 in log-space.
        max_ulp = Int64(0)
        for binade in -1075:0
            x = 2.0^Float64(binade)
            got = reinterpret(Float64, Bennett.soft_atan(reinterpret(UInt64, x)))
            max_ulp = max(max_ulp, ulp_diff_atan(got, atan(x)))
        end
        @test max_ulp <= 1
    end

    @testset "100k random sweep, 3 seeds, 5 magnitude buckets" begin
        # Target: ≤2 ULP on every sample. Five magnitude buckets cover
        # all five id paths plus the huge-arg fast path.
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A45584F))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            atan_max = Int64(0); atan_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; (rand() - 0.5) * 0.5            # |x| ≤ 0.25, id=-1
                    elseif mag == 2; (rand() - 0.5) * 4          # |x| ≤ 2, id ∈ {-1,0,1,2}
                    elseif mag == 3; (rand() - 0.5) * 80         # |x| ≤ 40, id ∈ {2,3}
                    elseif mag == 4; (rand() - 0.5) * 1e10       # id = 3
                    else; (rand() - 0.5) * 1e22                  # straddles huge boundary
                    end
                got = reinterpret(Float64, Bennett.soft_atan(reinterpret(UInt64, x)))
                u = ulp_diff_atan(got, atan(x))
                atan_max = max(atan_max, u); u > 2 && (atan_fail += 1)
            end
            @test atan_fail == 0
            @test atan_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_atan") === Bennett.soft_atan
    end

end
