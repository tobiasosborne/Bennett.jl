using Test, Bennett
using Random

@testset "soft_fdiv library" begin

    function check_fdiv(a::Float64, b::Float64)
        a_bits = reinterpret(UInt64, a)
        b_bits = reinterpret(UInt64, b)
        result_bits = soft_fdiv(a_bits, b_bits)
        expected = a / b
        expected_bits = reinterpret(UInt64, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float64, result_bits))
        else
            @test result_bits == expected_bits
        end
    end

    @testset "basic pairs" begin
        check_fdiv(6.0, 3.0)
        check_fdiv(1.0, 2.0)
        check_fdiv(10.0, 3.0)
        check_fdiv(1.0, 1.0)
        check_fdiv(-6.0, 3.0)
        check_fdiv(-6.0, -3.0)
        check_fdiv(3.14, 2.72)
        check_fdiv(1.0, 3.0)
        check_fdiv(1.0, 7.0)
        check_fdiv(1.0, 10.0)
    end

    @testset "edge cases" begin
        check_fdiv(0.0, 1.0)
        check_fdiv(1.0, 0.0)     # 1/0 = Inf
        check_fdiv(-1.0, 0.0)    # -1/0 = -Inf
        check_fdiv(0.0, 0.0)     # 0/0 = NaN
        check_fdiv(Inf, 2.0)     # Inf/2 = Inf
        check_fdiv(2.0, Inf)     # 2/Inf = 0
        check_fdiv(Inf, Inf)     # Inf/Inf = NaN
        check_fdiv(NaN, 1.0)
        check_fdiv(1.0, NaN)
        check_fdiv(0.0, -0.0)
    end

    @testset "random (1000 pairs)" begin
        rng = Random.MersenneTwister(42)
        failures = 0
        for _ in 1:1000
            a = rand(rng) * 200 - 100
            b = rand(rng) * 200 - 100
            b = b == 0.0 ? 1.0 : b  # avoid 0/0 in random
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_bits = soft_fdiv(a_bits, b_bits)
            expected_bits = reinterpret(UInt64, a / b)
            if result_bits != expected_bits
                failures += 1
                if failures <= 5
                    @test result_bits == expected_bits
                end
            end
        end
        @test failures == 0
    end
end
