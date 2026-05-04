# Bennett-ckvj: soft_asin primitive contract tests.
#
# Bit/ULP coverage of the IEEE 754 binary64 arcsine on raw bit patterns.
# Faithful musl port (asin.c → e_asin.c, FreeBSD/SunPro 1993). Branchless,
# all four input regimes computed in parallel and ifelse-selected.
# Target: ≤2 ULP vs `Base.asin` across the full input domain [-1, 1].
#
# §13 (CLAUDE.md / Bennett-fnxg) — transcendental subnormal-output
# convention. `Base.asin(x)` is subnormal whenever |x| ≤ ~2^-1022 because
# `asin(x) ≈ x + x³/6` in the tiny-arg regime, so subnormal-INPUT ⇒
# subnormal-OUTPUT. The subnormal-INPUT sweep below covers the entire
# subnormal-output regime; for |x| ≥ 2^-26 the output is bounded above by
# π/2 and below by `asin(2^-26)` ≈ 2^-26, normal — no other subnormal-
# output regime exists.

using Test
using Bennett

ulp_diff_asin(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        Int64(gb >= eb ? gb - eb : eb - gb)
    end
end

@testset "Bennett-ckvj: soft_asin (musl asin.c branchless)" begin

    @testset "smoke — every path bucket" begin
        for x in (0.0, -0.0,
                  # tiny path (|x| < 2^-26): return x bit-exact
                  1e-30, 1e-100, 1e-300, 2.0^-30, 2.0^-50,
                  # |x| < 0.5 polynomial path (asin(x) = x + x·R(x²))
                  0.01, 0.1, 0.2, 0.3, 0.4, 0.49,
                  # boundary at 0.5
                  0.5,
                  # 0.5 ≤ |x| ≤ 0.975 mid path (SET_LOW_WORD trick)
                  0.51, 0.6, 0.7, 0.8, 0.9, 0.95, 0.97,
                  # |x| > 0.975 near-1 path
                  0.98, 0.99, 0.999, 0.9999,
                  # boundary at 1
                  1.0)
            got = reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, x)))
            @test ulp_diff_asin(got, asin(x)) <= 2
        end
    end

    @testset "negatives and odd-symmetry — asin(-x) = -asin(x)" begin
        for x in (0.1, 0.3, 0.49, 0.5, 0.51, 0.7, 0.9, 0.95, 0.97, 0.99, 1.0)
            ax = asin(x)
            got_neg = reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, -x)))
            @test ulp_diff_asin(got_neg, -ax) <= 2
        end
    end

    @testset "specials — NaN / ±Inf / ±0 / |x|>1" begin
        # asin(NaN) = NaN, asin(±Inf) = NaN (|x|>1 path), asin(±0) = ±0.
        @test isnan(reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, NaN))))
        @test isnan(reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, -Inf))))
        # ±0 → ±0 bit-exact (sign-preserving via tiny path).
        @test Bennett.soft_asin(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_asin(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # |x| > 1 → NaN.
        for x in (1.0000001, 1.5, 2.0, 100.0, 1e10, 1e300)
            @test isnan(reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64,  x))))
            @test isnan(reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, -x))))
        end
    end

    @testset "tiny-arg fast path — asin(x) = x bit-exact for |x| < 2^-26" begin
        for x in (1e-30, 1e-100, 1e-300, 2.0^-27, 2.0^-30, 2.0^-50, 2.0^-100, 2.0^-1000)
            @test Bennett.soft_asin(reinterpret(UInt64,  x)) == reinterpret(UInt64,  x)
            @test Bennett.soft_asin(reinterpret(UInt64, -x)) == reinterpret(UInt64, -x)
        end
    end

    @testset "exact identities" begin
        # asin(0) = 0 bit-exact.
        @test Bennett.soft_asin(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_asin(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # asin(±1) = ±π/2 — bit-exact (musl returns x*pio2_hi + 0x1p-120f
        # which rounds to pio2_hi at f64 precision).
        @test Bennett.soft_asin(reinterpret(UInt64,  1.0)) == reinterpret(UInt64,  Float64(π/2))
        @test Bennett.soft_asin(reinterpret(UInt64, -1.0)) == reinterpret(UInt64, -Float64(π/2))
    end

    @testset "range-split boundaries (path transitions)" begin
        # The two boundaries: 0.5 (small ↔ general) and 0.975 (mid ↔ near-1).
        # 0x3fef3333 corresponds to |x| ≈ 0.97499847... — the high-word
        # threshold the musl branchpoint uses.
        for boundary in (0.5, 0x1.eccccc0000000p-1)  # 0.975 high-word boundary
            for offset in (-2.0^-30, -2.0^-40, -2.0^-50, 0.0,
                           2.0^-50, 2.0^-40, 2.0^-30, 1e-6, 1e-3)
                x = boundary + offset
                if abs(x) <= 1.0
                    got = reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, x)))
                    @test ulp_diff_asin(got, asin(x)) <= 2
                    got_neg = reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, -x)))
                    @test ulp_diff_asin(got_neg, asin(-x)) <= 2
                end
            end
        end
    end

    @testset "subnormal-INPUT sweep — asin(x) ≈ x preserves subnormals" begin
        # CLAUDE.md §13 / Bennett-fnxg: every transcendental must include a
        # subnormal-output sweep. For asin: subnormal output ⇔ subnormal
        # input (asin(x) = x in the tiny-arg regime; asin's range is
        # bounded by π/2, no other subnormal-output regime exists).
        # Sweep every binade from 2^-1075 to 2^-1 in log-space.
        max_ulp = Int64(0)
        for binade in -1075:-1
            x = 2.0^Float64(binade)
            got = reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, x)))
            max_ulp = max(max_ulp, ulp_diff_asin(got, asin(x)))
        end
        @test max_ulp <= 1
    end

    @testset "100k random sweep, 3 seeds, magnitude buckets" begin
        # Target: ≤2 ULP on every in-domain sample (|x| ≤ 1). Buckets
        # cover all four in-domain regimes (tiny / small-poly / mid /
        # near-1). `Base.asin` throws DomainError for |x| > 1, so OOB
        # behaviour is asserted separately as a NaN check (no Base
        # comparison).
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A45584F))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            asin_max = Int64(0); asin_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:4)
                x = if mag == 1; (rand() - 0.5) * 2.0^-25     # tiny path
                    elseif mag == 2; (rand() - 0.5) * 0.99    # |x| < 0.5 (mostly)
                    elseif mag == 3; (rand() - 0.5) * 1.94    # [-0.97, 0.97] band
                    else
                        # Near-1 band: (1 - 2^-k) · sign for k in 1..52.
                        s = rand() < 0.5 ? -1.0 : 1.0
                        s * (1.0 - 2.0^-(rand(1:52)))
                    end
                got = reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, x)))
                exp_v = asin(x)
                u = ulp_diff_asin(got, exp_v)
                asin_max = max(asin_max, u); u > 2 && (asin_fail += 1)
            end
            @test asin_fail == 0
            @test asin_max <= 2
        end
    end

    @testset "OOB random sweep — |x| > 1 → NaN" begin
        # `Base.asin` throws on OOB input, so we can only assert NaN
        # output here. 1000 samples per seed across (1, 2^200].
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A45584F))
            Random.seed!(seed)
            oob_fail = 0
            for _ in 1:1000
                # |x| in (1, 2^200] across log-magnitude.
                exp_mag = rand() * 200.0
                s = rand() < 0.5 ? -1.0 : 1.0
                x = s * (1.0 + rand()) * 2.0^exp_mag
                got = reinterpret(Float64, Bennett.soft_asin(reinterpret(UInt64, x)))
                isnan(got) || (oob_fail += 1)
            end
            @test oob_fail == 0
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_asin") === Bennett.soft_asin
    end

end
