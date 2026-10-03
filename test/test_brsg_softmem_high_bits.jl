# Bennett-brsg (Astra B-arith F10): the soft_mux_store_* primitives in
# src/softmem.jl extracted and reassembled only the low N·W bits of the
# packed UInt64, so every bit of `arr` above N·W came back cleared — even
# for a guarded store with `pred == 0`, whose docstring promises `arr`
# unchanged. Witness: arr=typemax(UInt64), idx=0, val=9, pred=0 returned
# 0xffff (2×8), 0xffffffff (4×8), 0xffffffffffff (3×16).
#
# Contract pinned here, for every store shape, guarded and unguarded:
#   * a store touches only the W bits of slot `idx` (when `idx < N`);
#     every other bit of the 64-bit word — including bits above N·W — is
#     passed through unchanged;
#   * a guarded store with `pred & 1 == 0` is the exact identity on `arr`
#     for every idx and val (out-of-range idx, val with bits above W);
#   * a guarded store with `pred & 1 == 1` equals the unguarded store.

using Test
using Random
using Bennett

const _BRSG_SHAPES = [(2, 8), (3, 8), (4, 8), (5, 8), (6, 8), (7, 8), (8, 8),
                      (2, 16), (3, 16), (4, 16), (2, 32)]

# Independent reference: replace slot idx's W bits, leave every other bit.
function _brsg_ref_store(N::Int, W::Int, arr::UInt64, idx::UInt64, val::UInt64)
    idx < UInt64(N) || return arr
    m = UInt64((UInt128(1) << W) - UInt128(1))
    sh = Int(idx) * W
    return (arr & ~(m << sh)) | ((val & m) << sh)
end

function _brsg_inputs(rng)
    arrs = UInt64[0, typemax(UInt64), 0x0123456789abcdef, 0xfedcba9876543210,
                  0x8000000000000000, 0xaaaaaaaaaaaaaaaa, 0x5555555555555555,
                  0xffffffff00000000, 0x00000000ffffffff, 0xffff000000000000]
    append!(arrs, rand(rng, UInt64, 40))
    idxs = UInt64[0:9; 15; 16; 31; 32; 63; 64; 255; 0xffffffff; 0x100000000;
                  typemax(UInt64) - 1; typemax(UInt64)]
    vals = UInt64[0, 9, 0x7f, 0xff, 0x100, 0xffff, 0x10000, 0xffffffff,
                  0x100000000, typemax(UInt64)]
    append!(vals, rand(rng, UInt64, 6))
    return arrs, idxs, vals
end

@testset "Bennett-brsg: soft_mux_store_* preserve bits above N·W" begin

    @testset "bead witness (arr=typemax, idx=0, val=9, pred=0)" begin
        a = typemax(UInt64)
        @test Bennett.soft_mux_store_guarded_2x8(a, UInt64(0), UInt64(9), UInt64(0)) == a
        @test Bennett.soft_mux_store_guarded_4x8(a, UInt64(0), UInt64(9), UInt64(0)) == a
        @test Bennett.soft_mux_store_guarded_3x16(a, UInt64(0), UInt64(9), UInt64(0)) == a
    end

    rng = MersenneTwister(0xb259)
    arrs, idxs, vals = _brsg_inputs(rng)
    preds0 = UInt64[0, 2, 0xfffe, typemax(UInt64) - 1]
    preds1 = UInt64[1, 3, 0xffff, typemax(UInt64)]

    for (N, W) in _BRSG_SHAPES
        st  = getfield(Bennett, Symbol(:soft_mux_store_, N, :x, W))
        stg = getfield(Bennett, Symbol(:soft_mux_store_guarded_, N, :x, W))
        @testset "$(N)x$(W)" begin
            bad_id = Tuple[]; bad_g = Tuple[]; bad_u = Tuple[]
            for a in arrs, i in idxs, v in vals
                ref = _brsg_ref_store(N, W, a, i, v)
                st(a, i, v) == ref || push!(bad_u, (a, i, v))
                for p in preds0
                    stg(a, i, v, p) == a || push!(bad_id, (a, i, v, p))
                end
                for p in preds1
                    stg(a, i, v, p) == ref || push!(bad_g, (a, i, v, p))
                end
            end
            isempty(bad_id) || println("  brsg $(N)x$(W) pred=0 non-identity, first: ", first(bad_id, 3))
            isempty(bad_g)  || println("  brsg $(N)x$(W) guarded pred=1 mismatch, first: ", first(bad_g, 3))
            isempty(bad_u)  || println("  brsg $(N)x$(W) unguarded mismatch, first: ", first(bad_u, 3))
            @test isempty(bad_id)
            @test isempty(bad_g)
            @test isempty(bad_u)
        end
    end

    # Compiled level: one guarded and one unguarded non-full shape (the ones
    # whose bodies changed), plus a parametric guarded shape.
    @testset "compiled circuits: $(nm)" for (nm, f, nargs, N, W) in [
            ("guarded_4x8",  Bennett.soft_mux_store_guarded_4x8,  4, 4, 8),
            ("guarded_3x16", Bennett.soft_mux_store_guarded_3x16, 4, 3, 16),
            ("unguarded_2x8", Bennett.soft_mux_store_2x8,         3, 2, 8)]
        c = reversible_compile(f, ntuple(_ -> UInt64, nargs)...)
        @test verify_reversibility(c)
        bad = Tuple[]
        for a in UInt64[0, typemax(UInt64), 0x0123456789abcdef, 0xffffffff00000000],
            i in UInt64[0, 1, 2, 3, 7, typemax(UInt64)],
            v in UInt64[9, 0xffff, typemax(UInt64)]
            inputs = nargs == 4 ? [(a, i, v, UInt64(0)), (a, i, v, UInt64(1))] :
                                  [(a, i, v)]
            for inp in inputs
                got = simulate(c, inp) % UInt64
                want = (nargs == 4 && inp[4] == 0) ? a : _brsg_ref_store(N, W, a, i, v)
                got == want || push!(bad, (inp, got))
            end
        end
        isempty(bad) || println("  brsg compiled $(nm) mismatch, first: ", first(bad, 3))
        @test isempty(bad)
    end
end
