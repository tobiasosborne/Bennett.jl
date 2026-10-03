using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRInst, IRBinOp, IRAlloca, IRVarGEP,
    IRStore, IRLoad, IRRet, IRCast, ssa, iconst

# Bennett-xjt9 (review 3, 2026-10-03, finding T2) + Bennett-6r3e. A
# `mem=:persistent` slab is a pmap with fixed-width keys (8 bits for every
# shipped impl) while its dynamic size and its GEP indices can be 64-bit.
# f110cea (Bennett-rrop) composed GEP-chain indices as residues mod 2^k at the
# key width, so address 256 of a 512-element slab became key 0 and aliased
# slot 0 (witness below: 33, correct 11). Independently, a constant index was
# masked to the key width by `resolve!` at the pmap call (6r3e: `&a[256]` is
# key 0). Both circuits passed verify_reversibility.
#
# Fix (refusal only): a persistent load/store accepts its key only when every
# in-bounds address it can name is provably below 2^k — a constant in
# [0, 2^k), or a runtime index whose upper bound (signed operand width, summed
# along the GEP chain) is below 2^k. Then key = address for every in-bounds
# access and distinct slots get distinct keys, whatever the slab size; the
# slab size itself is NOT refused (real dynamic allocas carry i32/i64 sizes).

const _XJT9_XS = typemin(Int8):typemax(Int8)
const _XJT9_IMPLS = (:linear_scan, :okasaki, :hamt, :cf)

_xjt9_lower(p; kw...) = Bennett.bennett(Bennett.lower(p; mem=:persistent, kw...))

function _xjt9_refused(p; kw...)
    err = try
        _xjt9_lower(p; kw...); nothing
    catch e
        e
    end
    @test err isa ArgumentError
    err isa ArgumentError && @test occursin("Bennett-xjt9", sprint(showerror, err))
    return err
end

@testset "Bennett-xjt9: persistent keys must provably fit the pmap key width" begin

    @testset "every impl has 8-bit keys (the bounds below assume it)" begin
        for impl in _XJT9_IMPLS
            @test Bennett._K_bits(Bennett._resolve_persistent_impl(impl, :none)) == 8
        end
    end

    @testset "T2 witness (verbatim): composed address 256 is refused" begin
        p = ParsedIR(8, [(:x, 64)], [
            IRBasicBlock(:entry, IRInst[
                IRBinOp(:n, :add, ssa(:x), iconst(512), 64),
                IRAlloca(:a, 8, ssa(:n)),
                IRStore(ssa(:a), iconst(11), 8),
                IRVarGEP(:p0, ssa(:a), iconst(1), 8),
                IRBinOp(:i, :add, ssa(:x), iconst(255), 64),
                IRVarGEP(:p, ssa(:p0), ssa(:i), 8),
                IRStore(ssa(:p), iconst(33), 8),
                IRLoad(:r, ssa(:a), 8),
            ], IRRet(ssa(:r), 8)),
        ], [8])
        _xjt9_refused(p)
    end

    # Slab with 64-bit dynamic size; store 11 at a[0], 33 through `ptr`, load a[0].
    function slab64(ptrinsts)
        insts = IRInst[IRBinOp(:n, :add, ssa(:x), iconst(512), 64),
                       IRAlloca(:a, 8, ssa(:n)),
                       IRStore(ssa(:a), iconst(11), 8)]
        append!(insts, ptrinsts)
        append!(insts, IRInst[IRStore(ssa(:q), iconst(33), 8), IRLoad(:r, ssa(:a), 8)])
        return ParsedIR(8, [(:x, 64)], [IRBasicBlock(:entry, insts, IRRet(ssa(:r), 8))], [8])
    end

    @testset "Bennett-6r3e: constant index outside [0, 256) is refused" begin
        # Pre-fix &a[256] stored to key 0 (returned 33, correct 11).
        _xjt9_refused(slab64([IRVarGEP(:q, ssa(:a), iconst(256), 8)]))
        # Constant chain 200 + 56 = 256.
        _xjt9_refused(slab64([IRVarGEP(:p0, ssa(:a), iconst(200), 8),
                              IRVarGEP(:q, ssa(:p0), iconst(56), 8)]))
        # A negative final constant is a statically out-of-bounds access.
        _xjt9_refused(slab64([IRVarGEP(:q, ssa(:a), iconst(-1), 8)]))
    end

    @testset "runtime index that can exceed 255 is refused" begin
        # Raw i64 index (pre-fix: an unexplained resolve! width DimensionMismatch).
        _xjt9_refused(slab64([IRVarGEP(:q, ssa(:a), ssa(:x), 8)]))
        # i8-only witness of T2: 200 + x (x ≤ 127) reaches 256 at x = 56 -> key 0.
        _xjt9_refused(slab64([IRCast(:x8, :trunc, ssa(:x), 64, 8),
                              IRVarGEP(:p0, ssa(:a), iconst(200), 8),
                              IRVarGEP(:q, ssa(:p0), ssa(:x8), 8)]))
    end

    # Accepted shapes: every key provably < 256. Byte model: zero-initialised
    # array; stores at k1 = 120 + (x & 7) (const base + raw i8, bound 247),
    # k2 = (x >> 4) & 7 (raw i8), then a load at k3 = 118 + ((x >> 1) & 3) + 2
    # (three-step chain, bound 247). Exhaustive over Int8 on all four impls.
    function accepted()
        insts = IRInst[
            IRBinOp(:lo, :and, ssa(:x), iconst(7), 8),
            IRBinOp(:n, :add, ssa(:lo), iconst(3), 8),
            IRAlloca(:a, 8, ssa(:n)),
            IRBinOp(:h0, :lshr, ssa(:x), iconst(4), 8),
            IRBinOp(:hi, :and, ssa(:h0), iconst(7), 8),
            IRBinOp(:m0, :lshr, ssa(:x), iconst(1), 8),
            IRBinOp(:mid, :and, ssa(:m0), iconst(3), 8),
            IRVarGEP(:b1, ssa(:a), iconst(120), 8),
            IRVarGEP(:p1, ssa(:b1), ssa(:lo), 8),
            IRStore(ssa(:p1), iconst(33), 8),
            IRVarGEP(:p2, ssa(:a), ssa(:hi), 8),
            IRStore(ssa(:p2), iconst(-7), 8),
            IRVarGEP(:b3, ssa(:a), iconst(118), 8),
            IRVarGEP(:c3, ssa(:b3), ssa(:mid), 8),
            IRVarGEP(:p3, ssa(:c3), iconst(2), 8),
            IRLoad(:r, ssa(:p3), 8)]
        return ParsedIR(8, [(:x, 8)], [IRBasicBlock(:entry, insts, IRRet(ssa(:r), 8))], [8])
    end
    function model(x::Int8)
        u = Int(reinterpret(UInt8, x))
        mem = zeros(Int, 256)
        mem[120 + (u & 7) + 1] = 33
        mem[((u >> 4) & 7) + 1] = -7
        return Int8(mem[120 + ((u >> 1) & 3) + 1])
    end
    @testset "accepted chains are exact on all inputs (impl=$impl)" for impl in _XJT9_IMPLS
        c = _xjt9_lower(accepted(); persistent_impl=impl)
        bad = [(x, simulate(c, x), model(x)) for x in _XJT9_XS if simulate(c, x) != model(x)]
        isempty(bad) || @info "Bennett-xjt9 mismatches (x, got, want)" impl first(bad, 4)
        @test isempty(bad)
        @test verify_reversibility(c)
    end
end
