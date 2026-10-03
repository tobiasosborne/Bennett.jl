using Test
using Bennett
using Bennett: IRInst, IRBasicBlock, IRBinOp, IRICmp, IRBranch, IRPhi, IRRet,
    IRAlloca, IRStore, IRLoad, IRVarGEP, ParsedIR, ssa, iconst

# Bennett-9378 (Astra review 2026-09-26, B-lowering F15): under
# `mem=:persistent` a dynamic-size alloca is backed by a fixed-capacity
# persistent map whose capacity counts WRITES, not live keys. linear_scan
# appends every `pmap_set` (updates included) to a 4-entry history and, once
# full, overwrites its last slot; cf's diff chain is likewise 4 deep. The
# 5th write therefore discarded the only record of an earlier one — the F15
# witness `a[0]=5; a[1]=7; a[0]=9; a[1]=11; a[0]=13; load a[1]` returned 7
# instead of 11 on all 256 inputs while `verify_reversibility` passed.
#
# Fix: every lowered `pmap_set` (one per store into the slab — guarded
# non-entry-block stores and every unrolled loop iteration included) is an
# upper bound on the writes reaching the map at runtime. Lowering counts
# them per slab and rejects, at compile time, any slab with more than
# `impl.max_n` of them. Within that bound every impl preserves latest-value
# semantics, so the accepted circuits below are checked exhaustively against
# a plain-array oracle.

const _N9378_XS = typemin(Int8):typemax(Int8)
const _N9378_IMPLS = (:linear_scan, :okasaki, :hamt, :cf)

_n9378_max_n(impl) = Bennett._resolve_persistent_impl(impl, :none).max_n

# Entry-block preamble: a 2- or 3-slot dynamic alloca (always valid) plus
# pointers to slots 0..nkeys-1. Size (x & 1) + nkeys keeps n dynamic.
function _n9378_preamble(nkeys)
    insts = IRInst[IRBinOp(:n0, :and, ssa(:x), iconst(1), 8),
                   IRBinOp(:n, :add, ssa(:n0), iconst(nkeys), 8),
                   IRAlloca(:a, 8, ssa(:n))]
    for k in 0:nkeys-1
        push!(insts, IRVarGEP(Symbol(:p, k), ssa(:a), iconst(k), 8))
    end
    return insts
end

# `nwrites` straight-line stores cycling over `nkeys` keys (write j goes to
# key (j-1) % nkeys with value 2j+3), then `load a[loadkey]`.
function _n9378_straight(nwrites, nkeys, loadkey)
    insts = _n9378_preamble(nkeys)
    mem = zeros(Int, nkeys)
    for j in 1:nwrites
        k = (j - 1) % nkeys
        push!(insts, IRStore(ssa(Symbol(:p, k)), iconst(2j + 3), 8))
        mem[k + 1] = 2j + 3
    end
    push!(insts, IRLoad(:r, ssa(Symbol(:p, loadkey)), 8))
    p = ParsedIR(8, [(:x, 8)], [IRBasicBlock(:entry, insts, IRRet(ssa(:r), 8))], [8])
    return p, mem[loadkey + 1]
end

function _n9378_check(c, oracle)
    bad = [(x, simulate(c, x), oracle(x)) for x in _N9378_XS if simulate(c, x) != oracle(x)]
    isempty(bad) || @info "Bennett-9378 mismatches (x, got, want)" first(bad, 4)
    @test isempty(bad)
    @test verify_reversibility(c)
end

_n9378_compile(p; kw...) = reversible_compile(p; mem=:persistent, kw...)

@testset "Bennett-9378: persistent-slab write capacity is sound" begin

    @testset "F15 witness: 5 writes to 2 keys under :linear_scan is rejected" begin
        p, _ = _n9378_straight(5, 2, 1)
        err = try
            _n9378_compile(p); nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test err !== nothing && occursin("Bennett-9378", sprint(showerror, err))
    end

    @testset "$impl: max_n writes accepted and exact, max_n + 1 rejected" for impl in _N9378_IMPLS
        mn = _n9378_max_n(impl)
        for loadkey in (0, 1)
            p, want = _n9378_straight(mn, 2, loadkey)
            c = _n9378_compile(p; persistent_impl=impl)
            _n9378_check(c, x -> Int8(want))
        end
        p, _ = _n9378_straight(mn + 1, 2, 1)
        @test_throws ArgumentError _n9378_compile(p; persistent_impl=impl)
    end

    @testset "distinct-key overflow (max_n + 1 keys) is rejected" begin
        mn = _n9378_max_n(:linear_scan)
        p, _ = _n9378_straight(mn + 1, mn + 1, 0)
        @test_throws ArgumentError _n9378_compile(p)
    end

    # Diamond: entry stores a[0]=5, then (x > 0 ? (a[1]=7; a[0]=9) : a[1]=11),
    # join loads a[1]. Guarded non-entry stores each lower one pmap_set.
    function _n9378_diamond(extra_join_store::Bool)
        entry = _n9378_preamble(2)
        append!(entry, IRInst[IRStore(ssa(:p0), iconst(5), 8),
                              IRICmp(:c, :sgt, ssa(:x), iconst(0), 8)])
        thn = IRInst[IRStore(ssa(:p1), iconst(7), 8), IRStore(ssa(:p0), iconst(9), 8)]
        els = IRInst[IRStore(ssa(:p1), iconst(11), 8)]
        join = IRInst[]
        extra_join_store && push!(join, IRStore(ssa(:p0), iconst(13), 8))
        push!(join, IRLoad(:r, ssa(:p1), 8))
        blocks = [IRBasicBlock(:entry, entry, IRBranch(ssa(:c), :thn, :els)),
                  IRBasicBlock(:thn, thn, IRBranch(nothing, :join, nothing)),
                  IRBasicBlock(:els, els, IRBranch(nothing, :join, nothing)),
                  IRBasicBlock(:join, join, IRRet(ssa(:r), 8))]
        return ParsedIR(8, [(:x, 8)], blocks, [8])
    end

    @testset "conditional writes: 4 lowered sets accepted and exact" begin
        c = _n9378_compile(_n9378_diamond(false))
        _n9378_check(c, x -> x > 0 ? Int8(7) : Int8(11))
    end

    @testset "conditional writes: 5 lowered sets rejected (static bound)" begin
        @test_throws ArgumentError _n9378_compile(_n9378_diamond(true))
    end

    # Loop: for i in 0:(trip-1): a[i & 1] = i + 20; then load a[1].
    # Every unrolled iteration lowers its own pmap_set.
    function _n9378_loop(trip)
        entry = _n9378_preamble(2)
        header = IRInst[IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:inext), :body)]),
                        IRICmp(:c, :ult, ssa(:i), iconst(trip), 8)]
        body = IRInst[IRBinOp(:k, :and, ssa(:i), iconst(1), 8),
                      IRVarGEP(:pk, ssa(:a), ssa(:k), 8),
                      IRBinOp(:v, :add, ssa(:i), iconst(20), 8),
                      IRStore(ssa(:pk), ssa(:v), 8),
                      IRBinOp(:inext, :add, ssa(:i), iconst(1), 8)]
        exitb = IRInst[IRLoad(:r, ssa(:p1), 8)]
        blocks = [IRBasicBlock(:entry, entry, IRBranch(nothing, :header, nothing)),
                  IRBasicBlock(:header, header, IRBranch(ssa(:c), :body, :exit)),
                  IRBasicBlock(:body, body, IRBranch(nothing, :header, nothing)),
                  IRBasicBlock(:exit, exitb, IRRet(ssa(:r), 8))]
        return ParsedIR(8, [(:x, 8)], blocks, [8])
    end

    @testset "loop: K = 3 unrolled stores accepted and exact" begin
        c = _n9378_compile(_n9378_loop(3); max_loop_iterations=3)
        _n9378_check(c, x -> Int8(21))
    end

    @testset "loop: K = 5 unrolled stores rejected" begin
        @test_throws ArgumentError _n9378_compile(_n9378_loop(5); max_loop_iterations=5)
    end
end
