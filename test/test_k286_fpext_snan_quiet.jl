using Test
using Bennett: soft_fpext
using Random

# Bennett-k286 / U07 — soft_fpext (Float32 → Float64) must quiet signalling
# NaNs per IEEE 754-2019 §5.4.1. Catalogue: reviews/2026-04-21/UNIFIED_CATALOGUE.md.
# Pre-fix: bit 51 of the Float64 result copied Float32 bit 22 (`fa << 29`), so
# any sNaN input (bit 22 = 0) passed through as a sNaN Float64 — ~50% of NaN
# inputs differed from Julia's `Float64(::Float32)`.

@testset "Bennett-k286 soft_fpext sNaN quieting" begin

    # T1 — reviewer's seed-123 sweep: 1000 random NaN bit patterns must
    #       all match Julia's hardware Float64(::Float32).
    @testset "T1 seed-123 random NaN sweep (reviewer repro)" begin
        rng = Random.MersenneTwister(123)
        n_total = 0
        n_mismatch = 0
        for _ in 1:1000
            frac = rand(rng, UInt32) & UInt32(0x7FFFFF)
            frac = frac == 0 ? UInt32(1) : frac
            sign_bit = rand(rng, UInt32) & UInt32(0x80000000)
            bits32 = sign_bit | (UInt32(0xFF) << 23) | frac
            hw = reinterpret(UInt64, Float64(reinterpret(Float32, bits32)))
            soft = soft_fpext(bits32)
            n_total += 1
            n_mismatch += (hw == soft ? 0 : 1)
        end
        @test n_total == 1000
        @test n_mismatch == 0
    end

    # T2 — smallest positive sNaN (payload = 1, quiet bit 22 clear).
    @testset "T2 smallest positive sNaN" begin
        bits32 = UInt32(0x7F800001)
        hw = reinterpret(UInt64, Float64(reinterpret(Float32, bits32)))
        @test soft_fpext(bits32) == hw
        # Hardware sets the quiet bit (bit 51 of Float64 fraction).
        @test (soft_fpext(bits32) & UInt64(0x0008000000000000)) != UInt64(0)
    end

    # T3 — smallest negative sNaN; sign bit preserved, quiet bit set.
    @testset "T3 smallest negative sNaN" begin
        bits32 = UInt32(0xFF800001)
        hw = reinterpret(UInt64, Float64(reinterpret(Float32, bits32)))
        @test soft_fpext(bits32) == hw
        @test (soft_fpext(bits32) & UInt64(0x8000000000000000)) != UInt64(0)
    end

    # T4 — qNaN inputs (bit 22 already set) are passed through unchanged
    #       (fix must not double-set the quiet bit or drop payload).
    @testset "T4 qNaN preserved exactly" begin
        for payload in UInt32[0x00400000, 0x00400001, 0x007FFFFF, 0x0040ABCD]
            bits32 = UInt32(0x7F800000) | payload
            hw = reinterpret(UInt64, Float64(reinterpret(Float32, bits32)))
            @test soft_fpext(bits32) == hw
        end
    end

    # T5 — walking-1 sweep over the 23 payload bits. Every sNaN position
    #       must quiet and preserve the remaining payload bits.
    @testset "T5 walking-1 payload sweep" begin
        fails = 0
        for bit in 0:22
            payload = UInt32(1) << bit
            for sign in (UInt32(0x00000000), UInt32(0x80000000))
                bits32 = sign | UInt32(0x7F800000) | payload
                hw = reinterpret(UInt64, Float64(reinterpret(Float32, bits32)))
                soft = soft_fpext(bits32)
                fails += (hw == soft ? 0 : 1)
            end
        end
        @test fails == 0
    end

    # T6 — regression anchors. Normal / subnormal / zero / infinity paths
    #       must stay bit-exact against hardware (guards against an
    #       over-broad "always OR 0x0008..." fix touching non-NaN paths).
    @testset "T6 non-NaN paths unchanged" begin
        anchors = UInt32[
            0x00000000,   # +0
            0x80000000,   # -0
            0x7F800000,   # +Inf
            0xFF800000,   # -Inf
            0x00000001,   # smallest +subnormal
            0x807FFFFF,   # largest -subnormal
            0x00800000,   # smallest +normal
            0x3F800000,   # 1.0
            0xBF800000,   # -1.0
            0x7F7FFFFF,   # largest +normal
        ]
        for bits32 in anchors
            hw = reinterpret(UInt64, Float64(reinterpret(Float32, bits32)))
            @test soft_fpext(bits32) == hw
        end
    end
end
