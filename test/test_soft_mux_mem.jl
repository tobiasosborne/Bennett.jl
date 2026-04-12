using Test
using Bennett: soft_mux_store_4x8, soft_mux_load_4x8

# Reference implementation: unpack 4×8 array from UInt64, manipulate naively,
# repack. Used to check soft_mux_* bit-exact.

function _unpack_4x8(arr::UInt64)::NTuple{4, UInt8}
    m = UInt64(0xff)
    (UInt8(arr & m),
     UInt8((arr >> 8)  & m),
     UInt8((arr >> 16) & m),
     UInt8((arr >> 24) & m))
end

function _pack_4x8(slots::NTuple{4, UInt8})::UInt64
    UInt64(slots[1]) |
    (UInt64(slots[2]) << 8)  |
    (UInt64(slots[3]) << 16) |
    (UInt64(slots[4]) << 24)
end

function _ref_store(arr::UInt64, idx::UInt64, val::UInt64)::UInt64
    slots = _unpack_4x8(arr)
    i = Int(idx) + 1  # 1-based
    new_slots = ntuple(k -> k == i ? UInt8(val & 0xff) : slots[k], 4)
    _pack_4x8(new_slots)
end

function _ref_load(arr::UInt64, idx::UInt64)::UInt64
    slots = _unpack_4x8(arr)
    UInt64(slots[Int(idx) + 1])
end

@testset "T1b.1 soft_mux_store_4x8 / soft_mux_load_4x8" begin

    @testset "soft_mux_load_4x8 — each slot readable" begin
        arr = UInt64(0x87654321)  # slots 0x21, 0x43, 0x65, 0x87
        @test soft_mux_load_4x8(arr, UInt64(0)) == 0x21
        @test soft_mux_load_4x8(arr, UInt64(1)) == 0x43
        @test soft_mux_load_4x8(arr, UInt64(2)) == 0x65
        @test soft_mux_load_4x8(arr, UInt64(3)) == 0x87
    end

    @testset "soft_mux_store_4x8 — write each slot" begin
        arr = UInt64(0x00000000)
        @test soft_mux_store_4x8(arr, UInt64(0), UInt64(0xab)) == 0x000000ab
        @test soft_mux_store_4x8(arr, UInt64(1), UInt64(0xab)) == 0x0000ab00
        @test soft_mux_store_4x8(arr, UInt64(2), UInt64(0xab)) == 0x00ab0000
        @test soft_mux_store_4x8(arr, UInt64(3), UInt64(0xab)) == 0xab000000
    end

    @testset "soft_mux_store_4x8 preserves other slots" begin
        arr = UInt64(0xaabbccdd)
        # Writing slot 1 should preserve slots 0, 2, 3
        new_arr = soft_mux_store_4x8(arr, UInt64(1), UInt64(0x55))
        @test (new_arr & 0xff) == 0xdd              # slot 0 unchanged
        @test ((new_arr >> 8) & 0xff) == 0x55       # slot 1 written
        @test ((new_arr >> 16) & 0xff) == 0xbb      # slot 2 unchanged
        @test ((new_arr >> 24) & 0xff) == 0xaa      # slot 3 unchanged
    end

    @testset "soft_mux_store only writes low 8 bits of val" begin
        arr = UInt64(0x00000000)
        # val with garbage in high bits — mask to 8 bits
        new_arr = soft_mux_store_4x8(arr, UInt64(0), UInt64(0xffffff77))
        @test (new_arr & 0xff) == 0x77
        @test (new_arr >> 8) == 0  # nothing above slot 0
    end

    @testset "exhaustive: 1024 random combos bit-exact vs reference" begin
        # 4 indices × 256 vals — 1024 combos, fixed arr
        for arr_seed in (UInt64(0), UInt64(0xaabbccdd), UInt64(0xffffffff))
            for idx in UInt64(0):UInt64(3)
                for val in UInt64(0):UInt64(255)
                    @test soft_mux_store_4x8(arr_seed, idx, val) ==
                          _ref_store(arr_seed, idx, val)
                    # load: doesn't depend on val, skip inner loop for speed
                end
                @test soft_mux_load_4x8(arr_seed, idx) ==
                      _ref_load(arr_seed, idx)
            end
        end
    end

    @testset "store + load round-trip: reading back the value just written" begin
        arr = UInt64(0xdeadbeef)
        for idx in UInt64(0):UInt64(3)
            for val in UInt64(0):UInt64(255)
                new_arr = soft_mux_store_4x8(arr, idx, val)
                @test soft_mux_load_4x8(new_arr, idx) == val
            end
        end
    end
end
