# Bennett-2hhx / U136 — IEEE 754 roundToIntegralTiesToEven (soft_round).
#
# Bit-exact equivalent to Base.round(::Float64), the default rounding mode
# in IEEE 754. Per CLAUDE.md §13: bit-exact vs Julia native + edge cases
# (ties, negative, subnormal, Inf, NaN) + a random raw-bits sweep.

using Random
import Bennett: soft_round

@testset "Bennett-2hhx / U136 — soft_round (roundToIntegralTiesToEven)" begin

    @testset "ties-to-even (canonical halfway cases)" begin
        # Round-to-even rule: ±N.5 rounds to the nearest EVEN integer.
        ties = [
            (0.5,   0.0),    # tie 0/1, 0 is even
            (-0.5,  -0.0),
            (1.5,   2.0),    # tie 1/2, 2 is even
            (-1.5,  -2.0),
            (2.5,   2.0),    # tie 2/3, 2 is even
            (-2.5,  -2.0),
            (3.5,   4.0),    # tie 3/4, 4 is even
            (-3.5,  -4.0),
            (4.5,   4.0),
            (-4.5,  -4.0),
            (123456789.5,   123456790.0),  # large odd.5 → next even
            (-123456789.5, -123456790.0),
            (1.234567890e15, 1.234567890e15),  # already integer
        ]
        for (x, expected) in ties
            got_bits = soft_round(reinterpret(UInt64, x))
            @test got_bits == reinterpret(UInt64, expected)
            @test got_bits == reinterpret(UInt64, round(x))
        end
    end

    @testset "non-tie rounding" begin
        cases = [
            0.0, -0.0, 0.1, -0.1, 0.3, -0.3, 0.499, -0.499,
            0.501, -0.501, 0.7, -0.7, 1.0, -1.0, 1.1, -1.1,
            1.49, -1.49, 1.51, -1.51, 2.7, -2.7,
            π, -π, ℯ, -ℯ, 100.7, 100.3, -100.7, -100.3,
            1e-5, -1e-5, 1e10, -1e10,
            2.0^52 - 0.25, 2.0^52 - 0.5, 2.0^52 - 0.75,
            -(2.0^52) + 0.25, -(2.0^52) + 0.5,
        ]
        for x in cases
            got_bits = soft_round(reinterpret(UInt64, x))
            @test got_bits == reinterpret(UInt64, round(x))
        end
    end

    @testset "subnormals → ±0" begin
        # All subnormals have |x| < 2^-1022 << 0.5; round to ±0 with
        # sign preserved.
        smallest_subnormal = reinterpret(Float64, UInt64(1))
        largest_subnormal  = reinterpret(Float64, UInt64(0x000FFFFFFFFFFFFF))
        for x in [smallest_subnormal, -smallest_subnormal,
                  largest_subnormal, -largest_subnormal,
                  reinterpret(Float64, UInt64(0x0008000000000000)),  # mid-subnormal
                  reinterpret(Float64, UInt64(0x8008000000000000))]
            got_bits = soft_round(reinterpret(UInt64, x))
            @test got_bits == reinterpret(UInt64, round(x))
        end
    end

    @testset "Inf passes through" begin
        @test soft_round(reinterpret(UInt64,  Inf)) == reinterpret(UInt64,  Inf)
        @test soft_round(reinterpret(UInt64, -Inf)) == reinterpret(UInt64, -Inf)
    end

    @testset "NaN passes through quietened" begin
        # Canonical qNaN
        qnan_bits = reinterpret(UInt64, NaN)
        @test soft_round(qnan_bits) == reinterpret(UInt64, round(NaN))

        # qNaN with payload
        qnan_payload = UInt64(0x7FF8_DEAD_BEEF_CAFE)
        out = soft_round(qnan_payload)
        @test isnan(reinterpret(Float64, out))
        @test (out & UInt64(0x0008000000000000)) != 0  # quiet bit set

        # sNaN must be force-quieted (Bennett-r84x convention)
        snan_bits = UInt64(0x7FF0_0000_0000_0001)  # sNaN, quiet bit clear
        out = soft_round(snan_bits)
        @test isnan(reinterpret(Float64, out))
        @test (out & UInt64(0x0008000000000000)) != 0  # quiet bit now set

        # Negative NaN
        neg_nan_bits = reinterpret(UInt64, -NaN)
        out = soft_round(neg_nan_bits)
        @test isnan(reinterpret(Float64, out))
    end

    @testset "carry-into-exponent (round 1.999... → 2.0)" begin
        # Almost-2 with all fraction bits set, exp=1023 (in [1.0, 2.0)).
        # The round-up adds incr that overflows bit 53, carry shifts
        # the mantissa right and bumps exp to 1024. Result: 2.0.
        almost_two = reinterpret(Float64, UInt64(0x3FFFFFFFFFFFFFFF))
        @test soft_round(reinterpret(UInt64, almost_two)) == reinterpret(UInt64, 2.0)
        @test soft_round(reinterpret(UInt64, -almost_two)) == reinterpret(UInt64, -2.0)
    end

    @testset "boundary at 2^52 (already-integer threshold)" begin
        for x in [2.0^52, 2.0^52 + 1, 2.0^52 - 1, 2.0^53,
                  -(2.0^52), -(2.0^52 + 1)]
            @test soft_round(reinterpret(UInt64, x)) == reinterpret(UInt64, round(x))
        end
    end

    @testset "random raw-bits sweep" begin
        # Per CLAUDE.md §13: 5,000 random UInt64 inputs, bit-exact vs Base.round.
        # Filter NaN payloads → both sides produce a NaN with set quiet bit;
        # we test that property below rather than bit-equality (since Julia's
        # Base.round may produce a different NaN bit pattern depending on its
        # internal helper choice).
        rng = MersenneTwister(0x2bbb_2bbb_2bbb_2bbb)
        for _ in 1:5000
            bits = rand(rng, UInt64)
            x = reinterpret(Float64, bits)
            got = soft_round(bits)
            base_bits = reinterpret(UInt64, round(x))
            if isnan(x)
                @test isnan(reinterpret(Float64, got))
                @test (got & UInt64(0x0008000000000000)) != 0
            else
                @test got == base_bits
            end
        end
    end
end
