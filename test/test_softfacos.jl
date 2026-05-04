# Bennett-bd7f: soft_acos primitive contract tests.
#
# Bit/ULP coverage of the IEEE 754 binary64 arccosine on raw bit
# patterns. Faithful musl port (acos.c → e_acos.c, FreeBSD/SunPro 1993).
# Branchless, all four input regimes (tiny / small / neg-large / pos-large)
# computed in parallel and ifelse-selected. Reuses `_asin_R(z)` and the
# 10 polynomial constants from `fasin.jl` (Bennett-ckvj) per CLAUDE.md
# §12. Target: ≤2 ULP vs `Base.acos` across [-1, 1].
#
# §13 (CLAUDE.md / Bennett-fnxg) — transcendental subnormal-output
# convention. `acos`'s output range is `[0, π]` and the smallest non-zero
# value reachable from a representable `Float64` input < 1 is
# `acos(1 - 2^-52) ≈ 2^-25.5`, which is NORMAL not subnormal. Therefore
# `acos` has NO subnormal-output regime. The test below sweeps the input
# binade lattice (including subnormal inputs, which all hit the tiny
# override → π/2) and asserts (a) no subnormal output ever occurs and
# (b) all outputs are ≤2 ULP — fulfilling the §13 contract by
# demonstrated coverage of the regime where subnormal output could in
# principle exist.

using Test
using Bennett

ulp_diff_acos(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        Int64(gb >= eb ? gb - eb : eb - gb)
    end
end

@testset "Bennett-bd7f: soft_acos (musl acos.c branchless)" begin

    @testset "smoke — every path bucket" begin
        for x in (0.0, -0.0,
                  # tiny path (|x| ≤ 2^-57 → π/2)
                  1e-30, 1e-100, 1e-300, 2.0^-58, 2.0^-100,
                  # |x| < 0.5 polynomial path
                  0.01, 0.1, 0.2, 0.3, 0.4, 0.49,
                  # boundary at 0.5
                  0.5,
                  # x ≥ 0.5 (pos-large)
                  0.51, 0.6, 0.7, 0.8, 0.9, 0.97, 0.99, 0.999,
                  # boundary at 1
                  1.0)
            got = reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64, x)))
            @test ulp_diff_acos(got, acos(x)) <= 2
        end
        # Negatives (neg-large path).
        for x in (-0.5, -0.51, -0.6, -0.7, -0.8, -0.9, -0.97, -0.99, -0.999, -1.0)
            got = reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64, x)))
            @test ulp_diff_acos(got, acos(x)) <= 2
        end
    end

    @testset "specials — NaN / ±Inf / ±0 / |x|>1" begin
        # acos(NaN) = NaN, acos(±Inf) = NaN, acos(±0) = π/2, acos(±1) = 0/π.
        @test isnan(reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64, NaN))))
        @test isnan(reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64, -Inf))))
        # ±0 → π/2 bit-exact via tiny override (NOT sign-preserving like asin).
        @test Bennett.soft_acos(reinterpret(UInt64,  0.0)) == reinterpret(UInt64, Float64(π/2))
        @test Bennett.soft_acos(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, Float64(π/2))
        # |x| > 1 → NaN.
        for x in (1.0000001, 1.5, 2.0, 100.0, 1e10, 1e300)
            @test isnan(reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64,  x))))
            @test isnan(reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64, -x))))
        end
    end

    @testset "tiny-arg fast path — acos(x) = π/2 for |x| ≤ 2^-57" begin
        pio2 = reinterpret(UInt64, Float64(π/2))
        for x in (1e-30, 1e-100, 1e-300, 2.0^-58, 2.0^-100, 2.0^-1000, 2.0^-1074)
            @test Bennett.soft_acos(reinterpret(UInt64,  x)) == pio2
            @test Bennett.soft_acos(reinterpret(UInt64, -x)) == pio2
        end
    end

    @testset "exact identities" begin
        # acos(1) = 0 bit-exact, acos(-1) = π bit-exact.
        @test Bennett.soft_acos(reinterpret(UInt64,  1.0)) == reinterpret(UInt64, 0.0)
        @test Bennett.soft_acos(reinterpret(UInt64, -1.0)) == reinterpret(UInt64, Float64(π))
        # acos(0) = π/2 bit-exact (tiny override).
        @test Bennett.soft_acos(reinterpret(UInt64,  0.0)) == reinterpret(UInt64, Float64(π/2))
        @test Bennett.soft_acos(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, Float64(π/2))
    end

    @testset "range-split boundaries (path transitions)" begin
        # Two boundaries: ±0.5 (small ↔ general). Spread offsets to exercise
        # both adjacent paths.
        for boundary in (0.5, -0.5)
            for offset in (-2.0^-30, -2.0^-40, -2.0^-50, 0.0,
                           2.0^-50, 2.0^-40, 2.0^-30, 1e-6, 1e-3)
                x = boundary + offset
                if abs(x) <= 1.0
                    got = reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64, x)))
                    @test ulp_diff_acos(got, acos(x)) <= 2
                end
            end
        end
    end

    @testset "subnormal-INPUT sweep — input binade lattice, no subnormal output" begin
        # CLAUDE.md §13 / Bennett-fnxg: acos has NO subnormal-output regime
        # (range is [0, π]; min non-zero output ≈ 2^-25.5 reached only near
        # x = 1, which is normal). The test sweeps the input binade lattice
        # (including subnormals — they hit the tiny override → π/2 exactly).
        # Asserts (a) all outputs ≤2 ULP and (b) no subnormal output.
        max_ulp = Int64(0); subnormal_outputs = 0
        for binade in -1075:-1
            x = 2.0^Float64(binade)
            got_bits = Bennett.soft_acos(reinterpret(UInt64, x))
            got = reinterpret(Float64, got_bits)
            max_ulp = max(max_ulp, ulp_diff_acos(got, acos(x)))
            # Subnormal detection: exponent field == 0 AND nonzero mantissa.
            ea = (got_bits >> 52) & UInt64(0x7FF)
            fa = got_bits & UInt64(0x000FFFFFFFFFFFFF)
            (ea == UInt64(0) && fa != UInt64(0)) && (subnormal_outputs += 1)
        end
        @test max_ulp <= 1                # tiny override is bit-exact
        @test subnormal_outputs == 0      # §13: no subnormal output regime
    end

    @testset "near-1 sweep — small-output regime (where subnormals could exist if any)" begin
        # acos(x) for x → 1⁻ produces small-but-normal output ≈ √(2(1-x)).
        # Sweep x = 1 - 2^-k for k = 1..52 (the entire f64 spacing near 1).
        # Output never reaches subnormal range (smallest is ≈ 2^-25.5).
        max_ulp = Int64(0); subnormal_outputs = 0
        for k in 1:52
            x = 1.0 - 2.0^-k
            got_bits = Bennett.soft_acos(reinterpret(UInt64, x))
            got = reinterpret(Float64, got_bits)
            max_ulp = max(max_ulp, ulp_diff_acos(got, acos(x)))
            ea = (got_bits >> 52) & UInt64(0x7FF)
            fa = got_bits & UInt64(0x000FFFFFFFFFFFFF)
            (ea == UInt64(0) && fa != UInt64(0)) && (subnormal_outputs += 1)
        end
        @test max_ulp <= 2
        @test subnormal_outputs == 0
    end

    @testset "100k random sweep, 3 seeds, magnitude buckets" begin
        # Target: ≤2 ULP on every in-domain sample (|x| ≤ 1). Buckets cover
        # all four in-domain regimes. `Base.acos` throws on OOB (separate
        # OOB testset below).
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A45584F))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            acos_max = Int64(0); acos_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:4)
                x = if mag == 1; (rand() - 0.5) * 2.0^-56     # tiny path
                    elseif mag == 2; (rand() - 0.5) * 0.99    # |x| < 0.5
                    elseif mag == 3; (rand() - 0.5) * 1.94    # full [-0.97, 0.97]
                    else
                        # Near-1 band on both sides: (1 - 2^-k) · sign.
                        s = rand() < 0.5 ? -1.0 : 1.0
                        s * (1.0 - 2.0^-(rand(1:52)))
                    end
                got = reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64, x)))
                exp_v = acos(x)
                u = ulp_diff_acos(got, exp_v)
                acos_max = max(acos_max, u); u > 2 && (acos_fail += 1)
            end
            @test acos_fail == 0
            @test acos_max <= 2
        end
    end

    @testset "OOB random sweep — |x| > 1 → NaN" begin
        # `Base.acos` throws on OOB input (just like `Base.asin`); only NaN
        # output is asserted here.
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A45584F))
            Random.seed!(seed)
            oob_fail = 0
            for _ in 1:1000
                exp_mag = rand() * 200.0
                s = rand() < 0.5 ? -1.0 : 1.0
                x = s * (1.0 + rand()) * 2.0^exp_mag
                got = reinterpret(Float64, Bennett.soft_acos(reinterpret(UInt64, x)))
                isnan(got) || (oob_fail += 1)
            end
            @test oob_fail == 0
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_acos") === Bennett.soft_acos
    end

end
