using Test
using Bennett
using Bennett: soft_fpext, soft_fptrunc
using Random

# IEEE 754 Float32 ↔ Float64 conversion on raw bit patterns.
# soft_fpext:   UInt32 (Float32 bits) → UInt64 (Float64 bits)   (widen, always exact)
# soft_fptrunc: UInt64 (Float64 bits) → UInt32 (Float32 bits)   (narrow, round-nearest-even)

@testset "soft_fpext / soft_fptrunc" begin

    function check_fpext(a::Float32)
        bits32 = reinterpret(UInt32, a)
        bits64 = soft_fpext(bits32)
        expected = Float64(a)
        expected_bits = reinterpret(UInt64, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float64, bits64))
        else
            @test bits64 == expected_bits
        end
    end

    function check_fptrunc(a::Float64)
        bits64 = reinterpret(UInt64, a)
        bits32 = soft_fptrunc(bits64)
        expected = Float32(a)
        expected_bits = reinterpret(UInt32, expected)
        if isnan(expected)
            @test isnan(reinterpret(Float32, bits32))
        else
            @test bits32 == expected_bits
        end
    end

    @testset "fpext: exact (normal Float32 → Float64)" begin
        # fpext is always exact for non-subnormals — Float64 precision >> Float32
        check_fpext(0.0f0)
        check_fpext(1.0f0)
        check_fpext(-1.0f0)
        check_fpext(2.0f0)
        check_fpext(0.5f0)
        check_fpext(3.14f0)
        check_fpext(-3.14f0)
        check_fpext(1.0f10)
        check_fpext(1.0f-10)
        check_fpext(prevfloat(1.0f0))
        check_fpext(nextfloat(1.0f0))
        # Largest normal Float32 ~3.4e38
        check_fpext(floatmax(Float32))
        # Smallest normal Float32 ~1.2e-38
        check_fpext(floatmin(Float32))
    end

    @testset "fpext: specials" begin
        check_fpext(0.0f0)
        check_fpext(-0.0f0)
        check_fpext(Inf32)
        check_fpext(-Inf32)
        check_fpext(NaN32)
        # Sign bit preservation on -0
        @test (soft_fpext(reinterpret(UInt32, -0.0f0)) >> 63) == UInt64(1)
    end

    @testset "fpext: subnormal Float32 → normal Float64" begin
        # Float64 range covers all Float32 subnormals as normals.
        # Smallest subnormal Float32 = 2^-149 ≈ 1.4e-45
        smallest_sub32 = reinterpret(Float32, UInt32(1))
        check_fpext(smallest_sub32)
        # A few subnormals across the range
        check_fpext(reinterpret(Float32, UInt32(0x00000002)))
        check_fpext(reinterpret(Float32, UInt32(0x00000100)))
        check_fpext(reinterpret(Float32, UInt32(0x00100000)))
        # Largest subnormal Float32
        check_fpext(reinterpret(Float32, UInt32(0x007FFFFF)))
        # Second-smallest normal Float32
        check_fpext(reinterpret(Float32, UInt32(0x00800001)))
    end

    @testset "fpext: random sweep (10k)" begin
        rng = MersenneTwister(1234)
        failures = 0
        for _ in 1:10_000
            bits32 = rand(rng, UInt32)
            a = reinterpret(Float32, bits32)
            isnan(a) && continue
            bits64 = soft_fpext(bits32)
            expected_bits = reinterpret(UInt64, Float64(a))
            if bits64 != expected_bits
                failures += 1
                if failures <= 3
                    @test bits64 == expected_bits
                end
            end
        end
        @test failures == 0
    end

    @testset "fptrunc: exact normals (Float64 → Float32)" begin
        check_fptrunc(0.0)
        check_fptrunc(1.0)
        check_fptrunc(-1.0)
        check_fptrunc(2.0)
        check_fptrunc(0.5)
        check_fptrunc(3.14)
        check_fptrunc(-3.14)
        check_fptrunc(1e10)
        check_fptrunc(1e-10)
        check_fptrunc(prevfloat(1.0))
        check_fptrunc(nextfloat(1.0))
    end

    @testset "fptrunc: specials" begin
        check_fptrunc(0.0)
        check_fptrunc(-0.0)
        check_fptrunc(Inf)
        check_fptrunc(-Inf)
        check_fptrunc(NaN)
        @test (soft_fptrunc(reinterpret(UInt64, -0.0)) >> 31) == UInt32(1)
    end

    @testset "fptrunc: overflow to ±Inf" begin
        # Values larger than floatmax(Float32) overflow to ±Inf in Float32
        check_fptrunc(1e300)    # huge
        check_fptrunc(-1e300)
        check_fptrunc(1e40)
        check_fptrunc(Float64(floatmax(Float32)) * 2.0)
        check_fptrunc(prevfloat(Float64(floatmax(Float32)) * 2.0))
    end

    @testset "fptrunc: underflow to subnormal or zero" begin
        # Values below floatmin(Float32) go to subnormal or zero
        check_fptrunc(1e-40)                       # subnormal F32
        check_fptrunc(-1e-40)
        check_fptrunc(1e-50)                       # below F32 range (zero or subnormal)
        check_fptrunc(5e-324)                      # smallest positive F64 subnormal → 0 in F32
        check_fptrunc(Float64(floatmin(Float32)))  # smallest normal F32 — exact
        check_fptrunc(Float64(floatmin(Float32)) / 2)
    end

    @testset "fptrunc: round-nearest-even" begin
        # Halfway cases must round to even
        # 1.0 + ulp(Float32) boundary: bit pattern at precision edge
        v = 1.0 + Float64(eps(Float32)) / 2  # halfway between 1.0 and nextfloat(1.0, Float32)
        check_fptrunc(v)
        # Slight perturbation either side
        check_fptrunc(nextfloat(v))
        check_fptrunc(prevfloat(v))
        # Test round-up on odd last-bit
        check_fptrunc(nextfloat(1.0f0, 1) |> Float64 |> x -> x + eps(x)/2)
    end

    @testset "fptrunc: random sweep (100k raw-bits)" begin
        rng = MersenneTwister(20260415)
        failures = 0
        for _ in 1:100_000
            bits64 = rand(rng, UInt64)
            a = reinterpret(Float64, bits64)
            isnan(a) && continue
            bits32 = soft_fptrunc(bits64)
            expected_bits = reinterpret(UInt32, Float32(a))
            if bits32 != expected_bits
                failures += 1
                if failures <= 3
                    @test bits32 == expected_bits
                end
            end
        end
        @test failures == 0
    end

    @testset "round-trip: fpext ∘ fptrunc and fptrunc ∘ fpext" begin
        # Float32 → Float64 → Float32 should be identity for non-NaN, non-subnormal
        # (exact widening + exact narrowing if the value is representable in Float32)
        for v in Float32[1.0, 2.0, 0.5, -3.14, 1.0f10, 0.0, -0.0,
                         floatmin(Float32), floatmax(Float32)]
            bits32 = reinterpret(UInt32, v)
            round_trip = soft_fptrunc(soft_fpext(bits32))
            @test round_trip == bits32
        end
    end
end
