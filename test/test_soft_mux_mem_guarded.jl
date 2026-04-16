# Bit-exactness tests for M2d guarded MUX-store callees.
#
# Each `soft_mux_store_guarded_NxW(arr, idx, val, pred)` must match the
# Julia reference: `pred & 1 != 0 ? soft_mux_store_NxW(arr, idx, val) : <arr_packed>`.
# "arr_packed" is the low N·W bits of `arr` — the unguarded callee returns
# the same region, so we compare against the unguarded callee with the same
# (arr, idx, val) when pred=1 and with an idx that matches no slot (i.e.
# every slot preserved) when pred=0. Both reduce to the same Julia reference:
#
#   ref(arr, idx, val, pred) = (pred & 1 != 0) ? unguarded(arr, idx, val)
#                                              : unguarded(arr, typemax(UInt64), val)
#
# The `typemax(UInt64)` index never matches any slot, so every slot falls
# through to OLD — giving us the "arr unchanged (packed region only)" behaviour.

using Test
using Random
using Bennett: soft_mux_store_2x8,   soft_mux_store_guarded_2x8,
               soft_mux_store_4x8,   soft_mux_store_guarded_4x8,
               soft_mux_store_8x8,   soft_mux_store_guarded_8x8,
               soft_mux_store_2x16,  soft_mux_store_guarded_2x16,
               soft_mux_store_4x16,  soft_mux_store_guarded_4x16,
               soft_mux_store_2x32,  soft_mux_store_guarded_2x32

@inline _ref_guarded(unguarded::F, arr, idx, val, pred) where {F} =
    (pred & UInt64(1) != UInt64(0)) ?
        unguarded(arr, idx, val) :
        unguarded(arr, typemax(UInt64), val)

const _M2D_SHAPES = [
    (:_2x8,  (2, 8),  soft_mux_store_2x8,  soft_mux_store_guarded_2x8),
    (:_4x8,  (4, 8),  soft_mux_store_4x8,  soft_mux_store_guarded_4x8),
    (:_8x8,  (8, 8),  soft_mux_store_8x8,  soft_mux_store_guarded_8x8),
    (:_2x16, (2, 16), soft_mux_store_2x16, soft_mux_store_guarded_2x16),
    (:_4x16, (4, 16), soft_mux_store_4x16, soft_mux_store_guarded_4x16),
    (:_2x32, (2, 32), soft_mux_store_2x32, soft_mux_store_guarded_2x32),
]

@testset "M2d soft_mux_store_guarded_NxW bit-exactness" begin
    for (name, (N, W), unguarded, guarded) in _M2D_SHAPES
        @testset "soft_mux_store_guarded$name" begin
            @testset "edge cases" begin
                val_mask = UInt64((UInt128(1) << W) - UInt128(1))
                allzero  = UInt64(0)
                allone   = typemax(UInt64)

                # pred=0 → arr unchanged (packed region)
                for arr in (allzero, allone, UInt64(0xdeadbeefcafebabe))
                    for idx in UInt64(0):UInt64(N-1)
                        for val in (allzero, allone, UInt64(0x55aa))
                            @test guarded(arr, idx, val, UInt64(0)) ==
                                  _ref_guarded(unguarded, arr, idx, val, UInt64(0))
                        end
                    end
                end

                # pred=1 → behaves like unguarded
                for arr in (allzero, allone, UInt64(0xdeadbeefcafebabe))
                    for idx in UInt64(0):UInt64(N-1)
                        for val in (allzero, allone, UInt64(0x55aa))
                            @test guarded(arr, idx, val, UInt64(1)) ==
                                  unguarded(arr, idx, val)
                        end
                    end
                end

                # idx out of range (≥ N) — should behave same as unguarded idx_OOB
                for pred in (UInt64(0), UInt64(1))
                    for arr in (allzero, allone, UInt64(0xdeadbeefcafebabe))
                        for idx_oob in (UInt64(N), UInt64(N+1), typemax(UInt64))
                            @test guarded(arr, idx_oob, UInt64(0x42), pred) ==
                                  _ref_guarded(unguarded, arr, idx_oob, UInt64(0x42), pred)
                        end
                    end
                end

                # high-bit pred garbage: only low bit matters
                @test guarded(UInt64(0), UInt64(0), val_mask, UInt64(0xDEADBEEE)) ==
                      _ref_guarded(unguarded, UInt64(0), UInt64(0), val_mask, UInt64(0xDEADBEEE))
                @test guarded(UInt64(0), UInt64(0), val_mask, UInt64(0xDEADBEEF)) ==
                      _ref_guarded(unguarded, UInt64(0), UInt64(0), val_mask, UInt64(0xDEADBEEF))
                @test guarded(UInt64(0), UInt64(0), val_mask, UInt64(0xFFFFFFFFFFFFFFFE)) ==
                      _ref_guarded(unguarded, UInt64(0), UInt64(0), val_mask, UInt64(0xFFFFFFFFFFFFFFFE))
                @test guarded(UInt64(0), UInt64(0), val_mask, UInt64(0xFFFFFFFFFFFFFFFF)) ==
                      _ref_guarded(unguarded, UInt64(0), UInt64(0), val_mask, UInt64(0xFFFFFFFFFFFFFFFF))
            end

            @testset "1000 random (arr, idx, val, pred)" begin
                # Seed per shape so each shape gets an independent stream.
                rng = MersenneTwister(0x1234 + hash(name) & 0xffff)
                for _ in 1:1000
                    arr  = rand(rng, UInt64)
                    idx  = rand(rng, UInt64)
                    val  = rand(rng, UInt64)
                    pred = rand(rng, UInt64)
                    @test guarded(arr, idx, val, pred) ==
                          _ref_guarded(unguarded, arr, idx, val, pred)
                end
            end
        end
    end
end
