using Test
using Bennett
using Bennett: soft_fsqrt
using Random

# IEEE 754 double-precision correctly-rounded sqrt.
# Algorithm: digit-by-digit restoring sqrt (fdlibm e_sqrt / Ercegovac-Lang Ch.6),
# mirrors the restoring-division loop in src/softfloat/fdiv.jl. Kahan's theorem
# guarantees sqrt never hits an exact midpoint, so sticky-from-remainder + round-
# nearest-even is trivially correctly-rounded — no Markstein/Tuckerman post-pass.

@testset "soft_fsqrt library" begin

    function check_fsqrt(a::Float64)
        a_bits = reinterpret(UInt64, a)
        result_bits = soft_fsqrt(a_bits)
        expected = sqrt(a)
        expected_bits = reinterpret(UInt64, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float64, result_bits))
        else
            @test result_bits == expected_bits
        end
    end

    @testset "perfect squares (exact)" begin
        check_fsqrt(0.0)
        check_fsqrt(1.0)
        check_fsqrt(4.0)
        check_fsqrt(9.0)
        check_fsqrt(16.0)
        check_fsqrt(25.0)
        check_fsqrt(100.0)
        check_fsqrt(1024.0)
        check_fsqrt(65536.0)
        check_fsqrt(0.25)       # 0.5^2
        check_fsqrt(0.0625)     # 0.25^2
        check_fsqrt(1e100)      # big, sqrt is big
    end

    @testset "irrational (correctly rounded)" begin
        check_fsqrt(2.0)
        check_fsqrt(3.0)
        check_fsqrt(5.0)
        check_fsqrt(7.0)
        check_fsqrt(0.5)
        check_fsqrt(0.1)
        check_fsqrt(3.14159265358979)
        check_fsqrt(2.718281828)
        check_fsqrt(10.0)
        check_fsqrt(1e-10)
    end

    @testset "zeros and sign preservation" begin
        # IEEE 754 §6.3: sqrt(-0) = -0 (sign preserved for zero)
        @test soft_fsqrt(reinterpret(UInt64, 0.0)) == reinterpret(UInt64, 0.0)
        @test soft_fsqrt(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # sanity: -0 sqrt has sign bit set
        @test (soft_fsqrt(reinterpret(UInt64, -0.0)) >> 63) == UInt64(1)
    end

    @testset "infinities" begin
        @test soft_fsqrt(reinterpret(UInt64, Inf)) == reinterpret(UInt64, Inf)
        @test isnan(reinterpret(Float64, soft_fsqrt(reinterpret(UInt64, -Inf))))
    end

    @testset "NaN propagation" begin
        @test isnan(reinterpret(Float64, soft_fsqrt(reinterpret(UInt64, NaN))))
        # Signaling NaN also returns NaN
        snan_bits = UInt64(0x7FF0000000000001)
        @test isnan(reinterpret(Float64, soft_fsqrt(snan_bits)))
    end

    @testset "negative finite -> NaN" begin
        @test isnan(reinterpret(Float64, soft_fsqrt(reinterpret(UInt64, -1.0))))
        @test isnan(reinterpret(Float64, soft_fsqrt(reinterpret(UInt64, -2.0))))
        @test isnan(reinterpret(Float64, soft_fsqrt(reinterpret(UInt64, -1e-300))))
        @test isnan(reinterpret(Float64, soft_fsqrt(reinterpret(UInt64, -1e300))))
    end

    @testset "subnormals" begin
        # Smallest positive subnormal: 5e-324
        smallest = reinterpret(Float64, UInt64(1))
        check_fsqrt(smallest)
        # A few subnormals across the subnormal range
        check_fsqrt(reinterpret(Float64, UInt64(0x0000000000000100)))
        check_fsqrt(reinterpret(Float64, UInt64(0x0000000000010000)))
        check_fsqrt(reinterpret(Float64, UInt64(0x0008000000000000)))  # ~1.1e-308
        # Largest subnormal
        check_fsqrt(reinterpret(Float64, UInt64(0x000FFFFFFFFFFFFF)))
    end

    @testset "boundary (near DBL_MAX / near DBL_MIN)" begin
        check_fsqrt(1.7976931348623157e308)   # DBL_MAX
        check_fsqrt(prevfloat(1.7976931348623157e308))
        check_fsqrt(2.2250738585072014e-308)  # DBL_MIN (smallest normal)
        check_fsqrt(nextfloat(2.2250738585072014e-308))
        check_fsqrt(1.0)
        check_fsqrt(prevfloat(1.0))
        check_fsqrt(nextfloat(1.0))
    end

    @testset "random normal sweep (1000)" begin
        rng = Random.MersenneTwister(42)
        failures = 0
        for _ in 1:1000
            a = rand(rng) * 1e6  # positive, in a reasonable range
            a_bits = reinterpret(UInt64, a)
            result_bits = soft_fsqrt(a_bits)
            expected_bits = reinterpret(UInt64, sqrt(a))
            if result_bits != expected_bits
                failures += 1
                if failures <= 5
                    @test result_bits == expected_bits
                end
            end
        end
        @test failures == 0
    end

    @testset "raw-bits sweep positives (100k)" begin
        # Any positive bit pattern (including subnormals) should match Julia's sqrt.
        rng = Random.MersenneTwister(20260415)
        failures = 0
        for _ in 1:100_000
            bits = rand(rng, UInt64) & UInt64(0x7FFFFFFFFFFFFFFF)  # clear sign
            a = reinterpret(Float64, bits)
            isnan(a) && continue
            result_bits = soft_fsqrt(bits)
            expected_bits = reinterpret(UInt64, sqrt(a))
            if isnan(reinterpret(Float64, expected_bits))
                # should not happen after NaN filter
                continue
            end
            if result_bits != expected_bits
                failures += 1
                if failures <= 3
                    @test result_bits == expected_bits
                end
            end
        end
        @test failures == 0
    end

    @testset "exponent parity — odd vs even unbiased" begin
        # sqrt(2.0) — ideal value 1.41421356237..., unbiased exp of input = 1 (odd)
        check_fsqrt(2.0)
        # sqrt(4.0) — 2.0, unbiased exp = 2 (even)
        check_fsqrt(4.0)
        # sqrt(8.0) — 2.828..., unbiased exp = 3 (odd)
        check_fsqrt(8.0)
        # negative unbiased exp — sqrt(0.5) unbiased = -1 (odd)
        check_fsqrt(0.5)
        # sqrt(0.125) unbiased = -3 (odd)
        check_fsqrt(0.125)
        # sqrt(0.0625) unbiased = -4 (even)
        check_fsqrt(0.0625)
    end

    @testset "SoftFloat dispatch: Base.sqrt(::SoftFloat)" begin
        # Verify the Julia-level dispatch routes sqrt(::SoftFloat) to soft_fsqrt.
        x = Bennett.SoftFloat(9.0)
        y = sqrt(x)
        @test y isa Bennett.SoftFloat
        @test reinterpret(Float64, y.bits) == 3.0
        # Irrational case
        z = sqrt(Bennett.SoftFloat(2.0))
        @test z.bits == reinterpret(UInt64, sqrt(2.0))
    end
end
