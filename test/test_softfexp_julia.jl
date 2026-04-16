using Test
using Bennett
using Bennett: soft_exp_julia, soft_exp2_julia
using Random

# Bennett.jl soft_exp_julia / soft_exp2_julia — bit-exact vs Base.exp / Base.exp2
# on FMA-capable hardware. Port of Julia's Base.Math.exp_impl line-for-line
# from `base/special/exp.jl` with every `muladd` replaced by `soft_fma`.
# Plan A of the transcendental roadmap (see Bennett-t110, WORKLOG 2026-04-16).

@testset "soft_exp_julia library" begin

    function check_exp(a::Float64)
        a_bits = reinterpret(UInt64, a)
        result_bits = soft_exp_julia(a_bits)
        expected = Base.exp(a)
        expected_bits = reinterpret(UInt64, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float64, result_bits))
        else
            @test result_bits == expected_bits
        end
    end

    @testset "exact integer arguments" begin
        check_exp(0.0); check_exp(-0.0)
        check_exp(1.0); check_exp(2.0); check_exp(-1.0); check_exp(-2.0)
        check_exp(0.5); check_exp(-0.5)
    end

    @testset "well-known values" begin
        check_exp(1.0)              # e
        check_exp(log(2.0))         # 2
        check_exp(log(0.5))         # 0.5
        check_exp(0.69314718)       # ≈ 2
        check_exp(2.302585)         # ≈ 10
        check_exp(-0.69314718)      # ≈ 0.5
    end

    @testset "specials: NaN, ±Inf" begin
        # NaN pass-through (matches Base.exp behavior)
        @test isnan(reinterpret(Float64, soft_exp_julia(reinterpret(UInt64, NaN))))
        check_exp(Inf)              # → +Inf
        check_exp(-Inf)             # → 0
    end

    @testset "overflow / underflow boundaries" begin
        check_exp(709.0); check_exp(709.7)       # near-overflow
        check_exp(709.78)                         # very near-overflow
        check_exp(710.0)                          # overflow → Inf
        check_exp(1000.0)                         # overflow
        check_exp(-745.0); check_exp(-745.1)     # near-underflow
        check_exp(-746.0)                         # underflow → 0
        check_exp(-1000.0)                        # underflow
    end

    @testset "subnormal output (k <= -53)" begin
        # x ∈ (-745.13, -708.4) → subnormal result per Julia's shift trick
        check_exp(-709.0); check_exp(-710.0)
        check_exp(-720.0); check_exp(-730.0); check_exp(-740.0)
        check_exp(-744.0); check_exp(-745.0)
    end

    @testset "random normal-range sweep (10 000)" begin
        rng = Random.MersenneTwister(0xE7EE)
        failures = 0
        for _ in 1:10_000
            a = (rand(rng) * 200 - 100)
            a_bits = reinterpret(UInt64, a)
            result_bits = soft_exp_julia(a_bits)
            expected = reinterpret(UInt64, Base.exp(a))
            if result_bits != expected
                failures += 1
                if failures <= 5
                    @test result_bits == expected
                end
            end
        end
        @test failures == 0
    end

    @testset "random full-range sweep (10 000, [-700, 700])" begin
        rng = Random.MersenneTwister(0xE710)
        failures = 0
        for _ in 1:10_000
            a = (rand(rng) * 1400 - 700)
            a_bits = reinterpret(UInt64, a)
            result_bits = soft_exp_julia(a_bits)
            expected = reinterpret(UInt64, Base.exp(a))
            if result_bits != expected
                failures += 1
                if failures <= 5
                    @test result_bits == expected
                end
            end
        end
        @test failures == 0
    end

    @testset "random subnormal-output sweep (Bennett-fnxg)" begin
        # x ∈ [-745.13, -708.4] triggers the k ≤ -53 subnormal path.
        # This is the region where musl-vs-Julia diverged in Plan B.
        rng = Random.MersenneTwister(0xE712)
        failures = 0
        for _ in 1:2_000
            a = -708.4 - rand(rng) * 36.7    # ∈ [-745.1, -708.4]
            a_bits = reinterpret(UInt64, a)
            result_bits = soft_exp_julia(a_bits)
            expected = reinterpret(UInt64, Base.exp(a))
            if result_bits != expected
                failures += 1
                if failures <= 5
                    @test result_bits == expected
                end
            end
        end
        @test failures == 0
    end
end

@testset "soft_exp2_julia library" begin

    function check_exp2(a::Float64)
        a_bits = reinterpret(UInt64, a)
        result_bits = soft_exp2_julia(a_bits)
        expected = Base.exp2(a)
        expected_bits = reinterpret(UInt64, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float64, result_bits))
        else
            @test result_bits == expected_bits
        end
    end

    @testset "exact integer powers (r=0 path)" begin
        for k in -10:10
            check_exp2(Float64(k))
        end
    end

    @testset "well-known values" begin
        check_exp2(0.5); check_exp2(1.5); check_exp2(2.5)
        check_exp2(-0.5); check_exp2(-1.5)
        check_exp2(10.0); check_exp2(-10.0)
    end

    @testset "specials: NaN, ±Inf" begin
        @test isnan(reinterpret(Float64, soft_exp2_julia(reinterpret(UInt64, NaN))))
        check_exp2(Inf); check_exp2(-Inf)
    end

    @testset "overflow / underflow boundaries" begin
        check_exp2(1023.0); check_exp2(1024.0)
        check_exp2(1025.0)              # overflow
        check_exp2(-1022.0); check_exp2(-1074.0); check_exp2(-1075.0)
        check_exp2(-1076.0)             # underflow
    end

    @testset "subnormal output range" begin
        check_exp2(-1022.5); check_exp2(-1050.0)
        check_exp2(-1060.0); check_exp2(-1070.0); check_exp2(-1074.0)
    end

    @testset "random sweep (10 000, [-100, 100])" begin
        rng = Random.MersenneTwister(0xE2E2)
        failures = 0
        for _ in 1:10_000
            a = (rand(rng) * 200 - 100)
            a_bits = reinterpret(UInt64, a)
            result_bits = soft_exp2_julia(a_bits)
            expected = reinterpret(UInt64, Base.exp2(a))
            if result_bits != expected
                failures += 1
                if failures <= 5
                    @test result_bits == expected
                end
            end
        end
        @test failures == 0
    end

    @testset "random subnormal-output sweep" begin
        rng = Random.MersenneTwister(0xE2E3)
        failures = 0
        for _ in 1:2_000
            a = -1022.5 - rand(rng) * 52.5    # ∈ [-1075, -1022.5]
            a_bits = reinterpret(UInt64, a)
            result_bits = soft_exp2_julia(a_bits)
            expected = reinterpret(UInt64, Base.exp2(a))
            if result_bits != expected
                failures += 1
                if failures <= 5
                    @test result_bits == expected
                end
            end
        end
        @test failures == 0
    end
end
