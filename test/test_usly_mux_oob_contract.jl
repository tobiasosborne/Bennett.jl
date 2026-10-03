# Bennett-usly: soft_mux_{load,store,store_guarded}_NxW index contract.
#
# Contract (src/softmem.jl header): the caller guarantees idx < N. idx >= N is
# undefined-by-contract (a reversible circuit cannot throw), so this file pins
# ONLY in-range behaviour against a plain-Julia reference — it deliberately
# does NOT assert what an out-of-range runtime idx returns.
#
# It also pins the lowering-side half of the contract: a CONSTANT idx never
# reaches a MUX callee (`_pick_alloca_strategy` routes it to :shadow, which
# bounds-checks constants loudly), while a runtime idx on a MUX shape does.

using Test
using Bennett
using Random

const _USLY_SHAPES = [(2, 8), (3, 8), (4, 8), (5, 8), (6, 8), (7, 8), (8, 8),
                      (2, 16), (3, 16), (4, 16), (2, 32)]

_usly_mask(W) = UInt64((UInt128(1) << W) - UInt128(1))
_usly_ref_load(arr, idx, N, W) = (arr >> (Int(idx) * W)) & _usly_mask(W)
function _usly_ref_store(arr, idx, val, N, W)
    sh = Int(idx) * W
    m = _usly_mask(W) << sh
    return (arr & ~m) | (((val & _usly_mask(W)) << sh) & m)
end

@testset "Bennett-usly: MUX callee index contract" begin
    rng = Random.MersenneTwister(0x75736c79)
    @testset "in-range load/store/store_guarded match reference ($N x $W)" for (N, W) in _USLY_SHAPES
        ld = getfield(Bennett, Symbol(:soft_mux_load_, N, :x, W))
        st = getfield(Bennett, Symbol(:soft_mux_store_, N, :x, W))
        sg = getfield(Bennett, Symbol(:soft_mux_store_guarded_, N, :x, W))
        arrs = UInt64[0, typemax(UInt64), 0x0123456789abcdef, rand(rng, UInt64, 40)...]
        vals = UInt64[0, typemax(UInt64), rand(rng, UInt64, 4)...]
        nbad = 0
        for arr in arrs, idx in UInt64(0):UInt64(N - 1)
            nbad += ld(arr, idx) != _usly_ref_load(arr, idx, N, W)
            for val in vals
                want = _usly_ref_store(arr, idx, val, N, W)
                nbad += st(arr, idx, val) != want
                nbad += sg(arr, idx, val, UInt64(1)) != want
                # pred low bit is the enable; high bits are ignored.
                nbad += sg(arr, idx, val, UInt64(0xfe)) != arr
                nbad += sg(arr, idx, val, UInt64(0xff)) != want
            end
        end
        @test nbad == 0
    end

    @testset "constant idx never routes to a MUX callee ($N x $W)" for (N, W) in _USLY_SHAPES
        for k in (0, N - 1, N, N + 7)
            @test Bennett._pick_alloca_strategy((W, N), Bennett.iconst(k)) === :shadow
        end
        @test Bennett._pick_alloca_strategy((W, N), Bennett.ssa(:i)) ===
              Symbol(:mux_exch_, N, :x, W)
    end
end
