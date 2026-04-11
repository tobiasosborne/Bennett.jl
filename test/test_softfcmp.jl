using Random

@testset "soft_fcmp library" begin

    @testset "ordered less-than (olt)" begin
        check(a, b) = @test soft_fcmp_olt(reinterpret(UInt64, a), reinterpret(UInt64, b)) == UInt64(a < b)

        check(1.0, 2.0)
        check(2.0, 1.0)
        check(1.0, 1.0)
        check(-1.0, 1.0)
        check(1.0, -1.0)
        check(-2.0, -1.0)
        check(-1.0, -2.0)
        check(0.0, 0.0)
        check(-0.0, 0.0)
        check(0.0, -0.0)
        check(0.0, 1.0)
        check(Inf, 1.0)
        check(1.0, Inf)
        check(-Inf, 1.0)
        check(NaN, 1.0)    # NaN comparisons are false (ordered)
        check(1.0, NaN)
        check(NaN, NaN)
    end

    @testset "ordered equal (oeq)" begin
        check(a, b) = @test soft_fcmp_oeq(reinterpret(UInt64, a), reinterpret(UInt64, b)) == UInt64(a == b)

        check(1.0, 1.0)
        check(1.0, 2.0)
        check(0.0, -0.0)  # IEEE: 0.0 == -0.0
        check(-0.0, 0.0)
        check(NaN, NaN)    # NaN != NaN
        check(NaN, 1.0)
        check(Inf, Inf)
        check(-Inf, -Inf)
        check(Inf, -Inf)
    end

    @testset "ordered less-than-or-equal (ole)" begin
        check(a, b) = @test soft_fcmp_ole(reinterpret(UInt64, a), reinterpret(UInt64, b)) == UInt64(a <= b)

        check(1.0, 2.0)
        check(2.0, 1.0)
        check(1.0, 1.0)
        check(-1.0, 1.0)
        check(1.0, -1.0)
        check(-2.0, -1.0)
        check(-1.0, -2.0)
        check(0.0, 0.0)
        check(-0.0, 0.0)   # IEEE: -0.0 <= 0.0
        check(0.0, -0.0)   # IEEE: 0.0 <= -0.0
        check(0.0, 1.0)
        check(Inf, 1.0)
        check(1.0, Inf)
        check(-Inf, 1.0)
        check(Inf, Inf)
        check(-Inf, -Inf)
        check(NaN, 1.0)    # NaN: unordered → false
        check(1.0, NaN)
        check(NaN, NaN)
    end

    @testset "unordered not-equal (une)" begin
        check(a, b) = @test soft_fcmp_une(reinterpret(UInt64, a), reinterpret(UInt64, b)) == UInt64(a != b || isnan(a) || isnan(b))

        check(1.0, 2.0)
        check(1.0, 1.0)
        check(0.0, -0.0)   # IEEE: 0.0 == -0.0 → une = false
        check(-0.0, 0.0)
        check(NaN, 1.0)    # NaN → une = true
        check(1.0, NaN)
        check(NaN, NaN)     # NaN → une = true
        check(Inf, Inf)
        check(-Inf, -Inf)
        check(Inf, -Inf)
    end

    @testset "random olt (1000 pairs)" begin
        rng = Random.MersenneTwister(42)
        for _ in 1:1000
            a = rand(rng) * 200 - 100
            b = rand(rng) * 200 - 100
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            @test soft_fcmp_olt(a_bits, b_bits) == UInt64(a < b)
        end
    end
end
