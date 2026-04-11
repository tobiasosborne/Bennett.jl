using Test
using Bennett

@testset "soft_sitofp (Int64 → Float64 bit-exact)" begin
    @testset "Basic values" begin
        for v in [Int64(0), Int64(1), Int64(-1), Int64(2), Int64(-2),
                  Int64(100), Int64(-100), Int64(42), Int64(-42)]
            bits_in = reinterpret(UInt64, v)
            expected = reinterpret(UInt64, Float64(v))
            @test soft_sitofp(bits_in) == expected
        end
    end

    @testset "Powers of 2" begin
        for k in 0:62
            v = Int64(1) << k
            bits_in = reinterpret(UInt64, v)
            expected = reinterpret(UInt64, Float64(v))
            @test soft_sitofp(bits_in) == expected
        end
        # Negative powers of 2
        for k in 0:62
            v = -(Int64(1) << k)
            bits_in = reinterpret(UInt64, v)
            expected = reinterpret(UInt64, Float64(v))
            @test soft_sitofp(bits_in) == expected
        end
    end

    @testset "Rounding boundaries (mantissa > 52 bits)" begin
        # 2^53 + 1: requires rounding (53 significant bits)
        for v in [Int64(2)^53 + 1, Int64(2)^53 - 1, Int64(2)^53,
                  Int64(2)^54 + 2, Int64(2)^54 - 2]
            bits_in = reinterpret(UInt64, v)
            expected = reinterpret(UInt64, Float64(v))
            @test soft_sitofp(bits_in) == expected
        end
    end

    @testset "Extremes" begin
        for v in [typemax(Int64), typemin(Int64), typemin(Int64) + 1]
            bits_in = reinterpret(UInt64, v)
            expected = reinterpret(UInt64, Float64(v))
            @test soft_sitofp(bits_in) == expected
        end
    end

    @testset "Random values (1000)" begin
        using Random
        rng = Xoshiro(12345)
        for _ in 1:1000
            v = rand(rng, Int64)
            bits_in = reinterpret(UInt64, v)
            expected = reinterpret(UInt64, Float64(v))
            @test soft_sitofp(bits_in) == expected
        end
    end
end
