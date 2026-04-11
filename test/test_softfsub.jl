using Random

@testset "soft_fsub library" begin

    function check_fsub(a::Float64, b::Float64)
        a_bits = reinterpret(UInt64, a)
        b_bits = reinterpret(UInt64, b)
        result_bits = soft_fsub(a_bits, b_bits)
        expected = a - b
        expected_bits = reinterpret(UInt64, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float64, result_bits))
        else
            @test result_bits == expected_bits
        end
    end

    @testset "basic pairs" begin
        check_fsub(3.0, 1.0)
        check_fsub(1.0, 3.0)
        check_fsub(1.0, 1.0)
        check_fsub(0.0, 0.0)
        check_fsub(-1.0, 1.0)
        check_fsub(0.5, 0.25)
        check_fsub(3.14, 2.72)
        check_fsub(1.0e10, 1.0)
    end

    @testset "edge cases" begin
        check_fsub(0.0, -0.0)
        check_fsub(-0.0, 0.0)
        check_fsub(-0.0, -0.0)
        check_fsub(Inf, 1.0)
        check_fsub(1.0, Inf)
        check_fsub(-1.0, -Inf)
        check_fsub(Inf, Inf)
        check_fsub(-Inf, -Inf)
        check_fsub(Inf, -Inf)
        check_fsub(-Inf, Inf)
        check_fsub(NaN, 1.0)
        check_fsub(1.0, NaN)
        check_fsub(NaN, NaN)
        # Subnormals
        check_fsub(5.0e-324, 0.0)
        check_fsub(0.0, 5.0e-324)
        check_fsub(5.0e-324, 5.0e-324)
        # Overflow boundary
        check_fsub(-1.7976931348623157e308, 1.7976931348623157e308)
        check_fsub(1.7976931348623157e308, -1.7976931348623157e308)
        # Near-cancellation
        check_fsub(1.0, nextfloat(1.0))
        check_fsub(nextfloat(1.0), 1.0)
    end

    @testset "random (10_000 pairs)" begin
        rng = Random.MersenneTwister(42)
        failures = 0
        for _ in 1:10_000
            a = rand(rng) * 200 - 100
            b = rand(rng) * 200 - 100
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_bits = soft_fsub(a_bits, b_bits)
            expected_bits = reinterpret(UInt64, a - b)
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
