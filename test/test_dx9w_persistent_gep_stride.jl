using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRInst, IRBinOp, IRAlloca, IRVarGEP,
    IRStore, IRLoad, IRRet, ssa, iconst

# Bennett-dx9w (review 3, 2026-10-03, finding T4). The persistent-slab arm of
# `lower_var_gep!` returns before the fixed-size path's element-unit
# conversion (`_gep_runtime_shift`), so a GEP whose element type differs from
# the slab's used its index unscaled as the pmap key: an i16 GEP off an i8
# slab addressed key i instead of 2i (witness: 22, correct 33), and passed
# verify_reversibility. Fix (refusal only): a persistent-slab GEP must use the
# slab's own element width; anything else is an ArgumentError naming the bead.

const _DX9W_XS = typemin(Int8):typemax(Int8)

_dx9w_lower(p; kw...) = Bennett.bennett(Bennett.lower(p; mem=:persistent, kw...))

function _dx9w_refused(p)
    err = try
        _dx9w_lower(p); nothing
    catch e
        e
    end
    @test err isa ArgumentError
    err isa ArgumentError && @test occursin("Bennett-dx9w", sprint(showerror, err))
end

# i8 slab, slots 0..2 := 11, 22, 33; then `gep` + i8 load.
function _dx9w_fixture(gep)
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRBinOp(:i, :and, ssa(:x), iconst(1), 8),
            IRBinOp(:n, :add, ssa(:i), iconst(3), 8),
            IRAlloca(:a, 8, ssa(:n)),
            IRVarGEP(:s0, ssa(:a), iconst(0), 8),
            IRStore(ssa(:s0), iconst(11), 8),
            IRVarGEP(:s1, ssa(:a), iconst(1), 8),
            IRStore(ssa(:s1), iconst(22), 8),
            IRVarGEP(:s2, ssa(:a), iconst(2), 8),
            IRStore(ssa(:s2), iconst(33), 8),
            gep,
            IRLoad(:r, ssa(:p), 8),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end

@testset "Bennett-dx9w: persistent-slab GEP stride must match the slab element" begin
    @testset "T4 witness (verbatim): i16 runtime GEP on an i8 slab is refused" begin
        _dx9w_refused(_dx9w_fixture(IRVarGEP(:p, ssa(:a), ssa(:i), 16)))
    end
    @testset "constant-index and narrower-stride GEPs are refused too" begin
        _dx9w_refused(_dx9w_fixture(IRVarGEP(:p, ssa(:a), iconst(1), 16)))  # key 1, not 2
        _dx9w_refused(_dx9w_fixture(IRVarGEP(:p, ssa(:a), ssa(:i), 64)))
        # i8 GEP off an i16 slab: a sub-element displacement.
        p = ParsedIR(8, [(:x, 8)], [IRBasicBlock(:entry, IRInst[
                IRBinOp(:i, :and, ssa(:x), iconst(1), 8),
                IRAlloca(:a, 16, ssa(:x)),
                IRVarGEP(:p, ssa(:a), ssa(:i), 8),
                IRLoad(:r, ssa(:p), 8)], IRRet(ssa(:r), 8))], [8])
        _dx9w_refused(p)
    end
    @testset "matching stride is still exact on all inputs" begin
        c = _dx9w_lower(_dx9w_fixture(IRVarGEP(:p, ssa(:a), ssa(:i), 8)))
        model(x) = isodd(reinterpret(UInt8, x)) ? Int8(22) : Int8(11)
        bad = [(x, simulate(c, x)) for x in _DX9W_XS if simulate(c, x) != model(x)]
        isempty(bad) || @info "Bennett-dx9w mismatches (x, got)" first(bad, 4)
        @test isempty(bad)
        @test verify_reversibility(c)
    end
end
