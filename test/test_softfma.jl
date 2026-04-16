using Random

@testset "soft_fma library" begin

    function check_fma(a::Float64, b::Float64, c::Float64)
        a_bits = reinterpret(UInt64, a)
        b_bits = reinterpret(UInt64, b)
        c_bits = reinterpret(UInt64, c)
        result_bits = soft_fma(a_bits, b_bits, c_bits)
        expected = Base.fma(a, b, c)
        expected_bits = reinterpret(UInt64, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float64, result_bits))
        else
            @test result_bits == expected_bits
        end
    end

    @testset "basic identity" begin
        check_fma(3.0, 7.0, 0.0)           # == 21.0 (fma as mul)
        check_fma(1.0, 1.0, 1.0)           # == 2.0
        check_fma(2.0, 3.0, 4.0)           # == 10.0
        check_fma(1.5, 2.0, 0.5)           # == 3.5
        check_fma(-2.0, 3.0, 1.0)          # == -5.0
        check_fma(0.0, 0.0, 0.0)
        check_fma(1.0, 0.0, 5.0)           # == 5.0 (0 product, c wins)
        check_fma(0.0, 1.0, -5.0)          # == -5.0
    end

    @testset "Kahan single-rounding witness (Hard case 1)" begin
        # a = b = 1 - 2^-53 = nextfloat below 1.0 in mantissa bit
        # True a*b = 1 - 2^-52 + 2^-106; a*b - 1 = -2^-106 + 2^-159
        # fma returns -2^-106 exactly (single rounding)
        # Naive fmul-then-fadd returns 0 (loses the 2^-106 bit)
        a = 0x1.fffffffffffffp-1   # = 1 - 2^-53
        b = 0x1.fffffffffffffp-1
        c = -1.0
        check_fma(a, b, c)
        # The correct result: -2^-106 (approximately)
        @test reinterpret(Float64, soft_fma(
            reinterpret(UInt64, a),
            reinterpret(UInt64, b),
            reinterpret(UInt64, c))) != 0.0
    end

    @testset "exact cancellation → +0 under RNE (Hard case 2)" begin
        # fma(1.5, 2.0, -3.0) = 0 exactly. Under RNE, result is +0, not -0.
        result_bits = soft_fma(
            reinterpret(UInt64, 1.5),
            reinterpret(UInt64, 2.0),
            reinterpret(UInt64, -3.0))
        @test result_bits == UInt64(0)   # +0, not -0 (0x8000...)
        @test !signbit(reinterpret(Float64, result_bits))

        # Same but all-negative inputs
        result_bits2 = soft_fma(
            reinterpret(UInt64, -1.5),
            reinterpret(UInt64, 2.0),
            reinterpret(UInt64, 3.0))
        @test result_bits2 == UInt64(0)
    end

    @testset "Inf · 0 + x = NaN (Hard case 3)" begin
        # IEEE 754 §5.4.1: Inf * 0 is the "invalid" case; result is qNaN.
        check_fma(Inf, 0.0, 1.0)
        check_fma(-Inf, 0.0, 1.0)
        check_fma(0.0, Inf, -1.0)
        check_fma(Inf, 0.0, 0.0)
        check_fma(Inf, 0.0, Inf)
        check_fma(-Inf, 0.0, -Inf)
    end

    @testset "expDiff = -1 opposite-sign precision trick (Hard case 4)" begin
        # Berkeley line 144: when expDiff==-1 and signs differ, use >>1 not
        # full shiftRightJam to preserve 1 bit for cancellation CLZ.
        # Inputs where the product is half the size of c, opposite sign.
        check_fma(1.0, 2.0, -(1.0 + eps()/2))
        check_fma(1.0, 2.0, -(1.0 - eps()/2))
        check_fma(-1.0, 2.0, (1.0 + eps()/2))
        check_fma(0.5, 1.0, -0.25 - 2^-55)
        check_fma(1.5, 1.0, -0.75 - 2^-55)
    end

    @testset "signed zero rules (Hard case 5)" begin
        # IEEE 754 §6.3 round-to-nearest-even rules for signed zero.
        # These are not all obvious — compared against Base.fma for each.
        check_fma(0.0, 0.0, -0.0)
        check_fma(-0.0, 0.0, 0.0)
        check_fma(-0.0, -0.0, -0.0)
        check_fma(0.0, -0.0, 0.0)
        check_fma(0.0, -0.0, -0.0)
        check_fma(1.0, 0.0, -0.0)
        check_fma(1.0, -0.0, 0.0)
        check_fma(-1.0, 0.0, 0.0)
        check_fma(-1.0, -0.0, -0.0)
        # Product is +0, c is +0 → +0; product is -0, c is +0 → +0 (under RNE)
        check_fma(-0.0, 1.0, 0.0)
    end

    @testset "NaN propagation (Hard case 6)" begin
        check_fma(NaN, 1.0, 1.0)
        check_fma(1.0, NaN, 1.0)
        check_fma(1.0, 1.0, NaN)
        check_fma(NaN, NaN, NaN)
        check_fma(NaN, Inf, 0.0)
        check_fma(NaN, 0.0, Inf)
        check_fma(Inf, NaN, 0.0)
        # Even NaN dominates over Inf·0 invalid
        check_fma(NaN, 0.0, 0.0)
    end

    @testset "Inf clash: Inf + -Inf = NaN (Hard case 7)" begin
        check_fma(Inf, 1.0, -Inf)
        check_fma(-Inf, 1.0, Inf)
        check_fma(1.0, Inf, -Inf)
        check_fma(-1.0, Inf, Inf)
        # Inf · finite + matching-sign Inf = Inf
        check_fma(Inf, 1.0, Inf)
        check_fma(-Inf, 1.0, -Inf)
        check_fma(Inf, -1.0, -Inf)
    end

    @testset "subnormal result from mixed-scale sum (Hard case 8)" begin
        # Product and c contribute to a near-subnormal result.
        check_fma(0x1p-600, 0x1p-500, 0x1p-1100)
        check_fma(0x1p-500, 0x1p-500, 0x1p-1000)
        check_fma(1.0, 0x1p-1073, 0x1p-1074)     # smallest subnormals
        check_fma(0x1p-1074, 0.5, 0x1p-1074)
        check_fma(0x1p-1022, 1.0, -0x1p-1023)    # ~MIN_NORMAL minus half
    end

    @testset "overflow via FMA (Hard case 9)" begin
        check_fma(0x1p1000, 1.5, 0x1p1023)
        check_fma(floatmax(Float64), 2.0, 0.0)          # overflow from product
        check_fma(floatmax(Float64), 1.5, floatmax(Float64))   # overflow from sum
        check_fma(-floatmax(Float64), 2.0, 0.0)
        check_fma(floatmax(Float64), 1.0, floatmax(Float64))   # exactly 2·floatmax
    end

    @testset "fma(a, b, 0) matches a*b (Hard case 10)" begin
        check_fma(3.0, 7.0, 0.0)
        check_fma(3.14, 2.72, 0.0)
        check_fma(1.0e10, 1.0e10, 0.0)
        check_fma(1.0e-10, 1.0e-10, 0.0)
        check_fma(-3.0, 7.0, 0.0)
        check_fma(0.1, 0.2, 0.0)
    end

    @testset "c dominant (expDiff << 0)" begin
        check_fma(1.0, 1.0, 1.0e20)
        check_fma(1.0e-10, 1.0e-10, 1.0)
        check_fma(1.0e-50, 1.0e-50, 1.0)
        check_fma(-1.0e-50, 1.0e-50, 1.0e50)
    end

    @testset "product dominant (expDiff >> 0)" begin
        check_fma(1.0e20, 1.0e20, 1.0)
        check_fma(1.0e50, 1.0e50, 1.0e-50)
        check_fma(1.0e100, 1.0e100, 1.0)
    end

    @testset "near-equal magnitudes (cancellation region)" begin
        # Product and c nearly cancel.
        check_fma(2.0, 3.0, -6.0)           # exact cancel → +0
        check_fma(2.0, 3.0, -6.0 + eps())
        check_fma(2.0, 3.0, -6.0 - eps())
        check_fma(1.1, 2.0, -2.2)           # approximate cancel
        check_fma(1.0 + eps(), 1.0, -(1.0 + eps()))
    end

    @testset "random normal-range sweep (50 000)" begin
        rng = Random.MersenneTwister(0xFA42)
        failures = 0
        for _ in 1:50_000
            a = (rand(rng) * 200 - 100)
            b = (rand(rng) * 200 - 100)
            c = (rand(rng) * 1000 - 500)
            ab = reinterpret(UInt64, a)
            bb = reinterpret(UInt64, b)
            cb = reinterpret(UInt64, c)
            result_bits = soft_fma(ab, bb, cb)
            expected_bits = reinterpret(UInt64, Base.fma(a, b, c))
            if result_bits != expected_bits
                failures += 1
                if failures <= 5
                    @test result_bits == expected_bits
                end
            end
        end
        @test failures == 0
    end

    @testset "random raw-UInt64 sweep (25 000) — covers all regions" begin
        # Uniform UInt64 → reinterpret as Float64 covers all subnormals,
        # NaNs, Infs, signed zeros, normal, and boundary regions.
        rng = Random.MersenneTwister(0xD00D)
        failures = 0
        for _ in 1:25_000
            ab = rand(rng, UInt64)
            bb = rand(rng, UInt64)
            cb = rand(rng, UInt64)
            a = reinterpret(Float64, ab)
            b = reinterpret(Float64, bb)
            c = reinterpret(Float64, cb)
            result_bits = soft_fma(ab, bb, cb)
            expected = Base.fma(a, b, c)
            expected_bits = reinterpret(UInt64, expected)
            if isnan(expected)
                isnan(reinterpret(Float64, result_bits)) || (failures += 1)
            else
                if result_bits != expected_bits
                    failures += 1
                    if failures <= 5
                        @test result_bits == expected_bits
                    end
                end
            end
        end
        @test failures == 0
    end

    @testset "subnormal-input sweep (10 000) — Bennett-fnxg rule" begin
        rng = Random.MersenneTwister(0x5AB9)
        failures = 0
        # Force at least one operand to be subnormal each iteration.
        for _ in 1:10_000
            # Random subnormal-ish UInt64: exponent field cleared, random fraction
            mk_subnormal = () -> (rand(rng, UInt64) & UInt64(0x800FFFFFFFFFFFFF))
            which = rand(rng, 1:3)
            ab = which == 1 ? mk_subnormal() : rand(rng, UInt64)
            bb = which == 2 ? mk_subnormal() : rand(rng, UInt64)
            cb = which == 3 ? mk_subnormal() : rand(rng, UInt64)
            a = reinterpret(Float64, ab)
            b = reinterpret(Float64, bb)
            c = reinterpret(Float64, cb)
            result_bits = soft_fma(ab, bb, cb)
            expected = Base.fma(a, b, c)
            if isnan(expected)
                isnan(reinterpret(Float64, result_bits)) || (failures += 1)
            else
                expected_bits = reinterpret(UInt64, expected)
                if result_bits != expected_bits
                    failures += 1
                    if failures <= 5
                        @test result_bits == expected_bits
                    end
                end
            end
        end
        @test failures == 0
    end

    @testset "cancellation sweep (10 000)" begin
        # Draw a, b random, then choose c ≈ -a*b to stress the cancellation
        # / renormalization path (Berkeley's most precision-sensitive regime).
        rng = Random.MersenneTwister(0xCAFE)
        failures = 0
        for _ in 1:10_000
            a = rand(rng) * 200 - 100
            b = rand(rng) * 200 - 100
            perturb = (rand(rng) - 0.5) * 1e-10 * abs(a * b)
            c = -a * b + perturb
            ab = reinterpret(UInt64, a)
            bb = reinterpret(UInt64, b)
            cb = reinterpret(UInt64, c)
            result_bits = soft_fma(ab, bb, cb)
            expected_bits = reinterpret(UInt64, Base.fma(a, b, c))
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
