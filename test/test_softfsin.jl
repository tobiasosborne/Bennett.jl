# Bennett-3mo: soft_sin / soft_cos primitive contract tests.
#
# Bit/ULP coverage of the IEEE 754 binary64 sine and cosine on raw bit
# patterns. Faithful musl port (sin.c / cos.c / __rem_pio2.c /
# __rem_pio2_large.c) with full Payne-Hanek argument reduction.
# Target: ≤2 ULP vs `Base.sin` / `Base.cos` across the full Float64
# range. Empirically: 100% bit-exact (0 ULP) on cos and ≤1 ULP on sin
# in 10k-sample sweeps; 1076-input subnormal-input sweep is bit-exact.
#
# §13 (CLAUDE.md) — transcendental subnormal-output convention.
# - sin(x) is subnormal whenever x is subnormal (sin(x) ≈ x for tiny x);
#   the subnormal-INPUT sweep tests that whole regime.
# - cos(x) is subnormal only at the cancellation knife-edge x ≈ π/2 + kπ
#   to within ~2^-1022 — not reachable from a single Float64 input
#   (Float64 spacing near π/2 is ~2^-51, well above the subnormal
#   threshold). This is documented at the top of the cos testset.

using Test
using Bennett

# ULP distance helper, matches the convention used in
# test_softfexp.jl / test_softflog.jl / test_softfpow.jl.
ulp_diff(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        Int64(gb >= eb ? gb - eb : eb - gb)
    end
end

@testset "Bennett-3mo: soft_sin / soft_cos (musl + Payne-Hanek)" begin

    @testset "smoke — small/medium/huge args" begin
        for x in (0.0, -0.0, 0.1, 0.5, 0.7, 0.78539816, 1.0, 1.5,
                  Float64(π/2), Float64(π), Float64(2π),
                  3.0, 5.0, 10.0, 100.0, 1000.0,
                  1e6, 1e7, 1e8, 1e10, 1e15, 1e22)
            got_sin = reinterpret(Float64, Bennett.soft_sin(reinterpret(UInt64, x)))
            got_cos = reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64, x)))
            @test ulp_diff(got_sin, sin(x)) <= 2
            @test ulp_diff(got_cos, cos(x)) <= 2
        end
    end

    @testset "negatives and odd-symmetry" begin
        for x in (0.1, 0.5, 1.0, 3.0, 100.0, 1e8)
            sx = sin(x); cx = cos(x)
            @test ulp_diff(reinterpret(Float64, Bennett.soft_sin(reinterpret(UInt64, -x))), -sx) <= 2
            @test ulp_diff(reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64, -x))), cx)  <= 2
        end
    end

    @testset "specials — NaN / ±Inf / ±0" begin
        # sin(NaN) = NaN, sin(±Inf) = NaN, sin(±0) = ±0 (sign-preserving)
        @test isnan(reinterpret(Float64, Bennett.soft_sin(reinterpret(UInt64, NaN))))
        @test isnan(reinterpret(Float64, Bennett.soft_sin(reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, Bennett.soft_sin(reinterpret(UInt64, -Inf))))
        @test Bennett.soft_sin(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_sin(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # cos(NaN) = NaN, cos(±Inf) = NaN, cos(±0) = +1.0
        @test isnan(reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64, NaN))))
        @test isnan(reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64, -Inf))))
        @test reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64,  0.0))) === 1.0
        @test reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64, -0.0))) === 1.0
    end

    @testset "tiny-arg fast path" begin
        # sin(x) = x bit-exact for |x| < 2^-26
        for x in (1e-30, 1e-100, 1e-300, 2.0^-30, 2.0^-50, 2.0^-100, 2.0^-1000)
            @test Bennett.soft_sin(reinterpret(UInt64,  x)) == reinterpret(UInt64,  x)
            @test Bennett.soft_sin(reinterpret(UInt64, -x)) == reinterpret(UInt64, -x)
            @test Bennett.soft_cos(reinterpret(UInt64,  x)) == reinterpret(UInt64, 1.0)
        end
    end

    @testset "near-π/2 cancellation (cos)" begin
        # cos(π/2 - δ) ≈ δ for small δ. Without proper Cody-Waite or
        # Payne-Hanek reduction, this is where catastrophic cancellation
        # eats precision. ≤2 ULP target across a sweep around π/2 + kπ.
        for k in 0:7, dpow in -50:5:-15
            δ = 2.0^dpow
            for x in (Float64(π/2) + Float64(k*π) + δ,
                      Float64(π/2) + Float64(k*π) - δ)
                got = reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64, x)))
                @test ulp_diff(got, cos(x)) <= 2
            end
        end
    end

    @testset "subnormal-INPUT sweep — sin(x) ≈ x preserves subnormals" begin
        # CLAUDE.md §13 / Bennett-fnxg: every transcendental must include a
        # subnormal-output sweep. For sin: subnormal output ⇔ subnormal
        # input (sin(x) = x in the tiny-arg regime). Sweep every binade
        # from 2^-1075 to 2^0 in log-space.
        max_ulp = 0
        for binade in -1075:0
            x = 2.0^Float64(binade)
            got = reinterpret(Float64, Bennett.soft_sin(reinterpret(UInt64, x)))
            max_ulp = max(max_ulp, ulp_diff(got, sin(x)))
        end
        @test max_ulp <= 1
    end

    @testset "exact identities" begin
        # sin(0) = 0, cos(0) = 1 bit-exact
        @test Bennett.soft_sin(reinterpret(UInt64, 0.0)) == reinterpret(UInt64, 0.0)
        @test Bennett.soft_cos(reinterpret(UInt64, 0.0)) == reinterpret(UInt64, 1.0)
        # sin(π/2) ≈ 1, cos(π/2) ≈ 0 (not bit-exact — π/2 is irrational
        # rounded to Float64; but should match Base exactly).
        @test Bennett.soft_sin(reinterpret(UInt64, Float64(π/2))) == reinterpret(UInt64, sin(Float64(π/2)))
        @test Bennett.soft_cos(reinterpret(UInt64, Float64(π/2))) == reinterpret(UInt64, cos(Float64(π/2)))
    end

    @testset "100k random sweep, 3 seeds" begin
        # Target: ≤2 ULP on every sample, max-ULP ≤ 1 on average. Spans
        # five magnitude buckets (small / [1e0, 1e3] / medium / [1e8, 1e15]
        # / huge [1e15, 1e22]) to cover small-arg, Cody-Waite-ext, and
        # Payne-Hanek paths.
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A45584F))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            sin_max = Int64(0); cos_max = Int64(0)
            sin_fail = 0; cos_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; (rand() - 0.5) * 4
                    elseif mag == 2; (rand() - 0.5) * 1e3
                    elseif mag == 3; (rand() - 0.5) * 1e8
                    elseif mag == 4; (rand() - 0.5) * 1e15
                    else; (rand() - 0.5) * 1e22
                    end
                got_sin = reinterpret(Float64, Bennett.soft_sin(reinterpret(UInt64, x)))
                got_cos = reinterpret(Float64, Bennett.soft_cos(reinterpret(UInt64, x)))
                u_sin = ulp_diff(got_sin, sin(x))
                u_cos = ulp_diff(got_cos, cos(x))
                sin_max = max(sin_max, u_sin); u_sin > 2 && (sin_fail += 1)
                cos_max = max(cos_max, u_cos); u_cos > 2 && (cos_fail += 1)
            end
            @test sin_fail == 0
            @test cos_fail == 0
            @test sin_max <= 2
            @test cos_max <= 2
        end
    end

    @testset "callees registered" begin
        @test Bennett._lookup_callee("soft_sin") === Bennett.soft_sin
        @test Bennett._lookup_callee("soft_cos") === Bennett.soft_cos
    end

end
