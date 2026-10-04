using Test, Bennett
using Random

@testset "Soft-float library" begin

    @testset "soft_fneg" begin
        @test soft_fneg(reinterpret(UInt64, 1.0)) == reinterpret(UInt64, -1.0)
        @test soft_fneg(reinterpret(UInt64, -3.14)) == reinterpret(UInt64, 3.14)
        @test soft_fneg(reinterpret(UInt64, 0.0)) == reinterpret(UInt64, -0.0)
        @test soft_fneg(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, 0.0)
        @test soft_fneg(reinterpret(UInt64, Inf)) == reinterpret(UInt64, -Inf)
    end

    @testset "soft_fadd — basic pairs" begin
        function check_fadd(a::Float64, b::Float64)
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_bits = soft_fadd(a_bits, b_bits)
            expected = a + b
            expected_bits = reinterpret(UInt64, expected)
            if isnan(expected)
                @test isnan(reinterpret(Float64, result_bits))
            else
                @test result_bits == expected_bits
            end
        end

        check_fadd(1.0, 2.0)
        check_fadd(1.0, -1.0)
        check_fadd(3.14, 2.72)
        check_fadd(-5.0, 3.0)
        check_fadd(1.0e10, 1.0)
        check_fadd(1.0e-10, 1.0e-10)
        check_fadd(1.5, 0.5)
        check_fadd(-1.5, -0.5)
        check_fadd(1.0, -0.5)
        check_fadd(0.1, 0.2)   # classic: 0.1 + 0.2 != 0.3
    end

    @testset "soft_fadd — edge cases" begin
        function check_fadd(a::Float64, b::Float64)
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_bits = soft_fadd(a_bits, b_bits)
            expected = a + b
            expected_bits = reinterpret(UInt64, expected)
            if isnan(expected)
                @test isnan(reinterpret(Float64, result_bits))
            else
                @test result_bits == expected_bits
            end
        end

        # Zeros
        check_fadd(0.0, 0.0)
        check_fadd(-0.0, 0.0)
        check_fadd(0.0, -0.0)
        check_fadd(-0.0, -0.0)

        # Infinities
        check_fadd(Inf, 1.0)
        check_fadd(-Inf, 1.0)
        check_fadd(1.0, Inf)
        check_fadd(Inf, Inf)
        check_fadd(-Inf, -Inf)
        check_fadd(Inf, -Inf)
        check_fadd(-Inf, Inf)

        # NaN
        check_fadd(NaN, 1.0)
        check_fadd(1.0, NaN)
        check_fadd(NaN, NaN)
        check_fadd(NaN, Inf)

        # Overflow to Inf
        check_fadd(1.7976931348623157e308, 1.7976931348623157e308)

        # Near-cancellation
        check_fadd(1.0, -1.0)
        x = 1.0000000000000002  # nextfloat(1.0)
        check_fadd(x, -1.0)

        # Subnormals
        tiny = 5.0e-324    # smallest subnormal
        check_fadd(tiny, 0.0)
        check_fadd(tiny, tiny)
        check_fadd(tiny, -tiny)
    end

    @testset "soft_fadd — random (10_000 pairs)" begin
        rng = Random.MersenneTwister(42)
        failures = 0
        for _ in 1:10_000
            a = (rand(rng) * 200 - 100)
            b = (rand(rng) * 200 - 100)
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_bits = soft_fadd(a_bits, b_bits)
            expected_bits = reinterpret(UInt64, a + b)
            if result_bits != expected_bits
                failures += 1
                if failures <= 5
                    @test result_bits == expected_bits  # show first few failures
                end
            end
        end
        @test failures == 0
    end

    @testset "soft_fadd — commutativity" begin
        rng = Random.MersenneTwister(99)
        for _ in 1:1000
            a = reinterpret(UInt64, rand(rng) * 100 - 50)
            b = reinterpret(UInt64, rand(rng) * 100 - 50)
            @test soft_fadd(a, b) == soft_fadd(b, a)
        end
    end
end
