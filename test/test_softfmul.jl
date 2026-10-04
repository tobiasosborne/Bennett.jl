using Test, Bennett
using Random

@testset "soft_fmul library" begin

    function check_fmul(a::Float64, b::Float64)
        a_bits = reinterpret(UInt64, a)
        b_bits = reinterpret(UInt64, b)
        result_bits = soft_fmul(a_bits, b_bits)
        expected = a * b
        expected_bits = reinterpret(UInt64, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float64, result_bits))
        else
            @test result_bits == expected_bits
        end
    end

    @testset "basic pairs" begin
        check_fmul(2.0, 3.0)
        check_fmul(1.0, 1.0)
        check_fmul(1.5, 2.0)
        check_fmul(0.5, 0.5)
        check_fmul(-2.0, 3.0)
        check_fmul(-2.0, -3.0)
        check_fmul(1.0e10, 1.0e10)
        check_fmul(1.0e-10, 1.0e-10)
        check_fmul(3.14, 2.72)
        check_fmul(1.0, 0.0)
    end

    @testset "edge cases" begin
        # Zeros
        check_fmul(0.0, 0.0)
        check_fmul(-0.0, 0.0)
        check_fmul(0.0, -0.0)
        check_fmul(-0.0, -0.0)
        check_fmul(0.0, 1.0)
        check_fmul(1.0, 0.0)
        check_fmul(-0.0, 1.0)

        # Infinities
        check_fmul(Inf, 2.0)
        check_fmul(-Inf, 2.0)
        check_fmul(Inf, -2.0)
        check_fmul(2.0, Inf)
        check_fmul(Inf, Inf)
        check_fmul(-Inf, -Inf)
        check_fmul(Inf, -Inf)
        check_fmul(Inf, 0.0)      # Inf * 0 = NaN
        check_fmul(-Inf, 0.0)
        check_fmul(0.0, Inf)

        # NaN
        check_fmul(NaN, 1.0)
        check_fmul(1.0, NaN)
        check_fmul(NaN, NaN)
        check_fmul(NaN, Inf)
        check_fmul(NaN, 0.0)

        # Overflow to Inf
        check_fmul(1.7976931348623157e308, 2.0)

        # Underflow to zero
        check_fmul(5.0e-324, 0.5)

        # Identity
        check_fmul(1.0, 42.0)
        check_fmul(42.0, 1.0)

        # Subnormals
        tiny = 5.0e-324    # smallest subnormal
        check_fmul(tiny, 1.0)
        check_fmul(tiny, 2.0)
        check_fmul(tiny, tiny)

        # Near-overflow boundary
        big = 1.3407807929942596e154   # ~sqrt(floatmax)
        check_fmul(big, big)
    end

    @testset "random (10_000 pairs)" begin
        rng = Random.MersenneTwister(42)
        failures = 0
        for _ in 1:10_000
            a = (rand(rng) * 200 - 100)
            b = (rand(rng) * 200 - 100)
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_bits = soft_fmul(a_bits, b_bits)
            expected_bits = reinterpret(UInt64, a * b)
            if result_bits != expected_bits
                failures += 1
                if failures <= 5
                    @test result_bits == expected_bits
                end
            end
        end
        @test failures == 0
    end

    @testset "commutativity" begin
        rng = Random.MersenneTwister(99)
        for _ in 1:1000
            a = reinterpret(UInt64, rand(rng) * 100 - 50)
            b = reinterpret(UInt64, rand(rng) * 100 - 50)
            @test soft_fmul(a, b) == soft_fmul(b, a)
        end
    end
end
