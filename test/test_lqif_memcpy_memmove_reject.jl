# Bennett-lqif (Bennett-hao Phase 0): llvm.memcpy / llvm.memmove fail
# loud at IR walking. Phase 0 was a blanket fail-loud (no per-shape
# discrimination). Phase 1 (Bennett-37mt, 2026-05-03) replaces the
# memcpy arm with proper byte-granular lowering for the in-scope shape
# (alloca-i8-backed pointers, distinct allocas, const N).
#
# This test pins the REMAINING fail-loud paths after Phase 1:
#   - the existing `lqif_memcpy_reject.ll` fixture uses `alloca i64`,
#     which now hits the Phase 1 `alloca elem_w must be 8` predicate
#     and fails loud with a `Bennett-8bys` reference (not `lqif`).
#   - llvm.memmove ALWAYS fails loud → Bennett-8bys.
#
# Per-shape green-path coverage for memcpy lives in
# `test/test_37mt_memcpy_const_aligned.jl`.
#
# llvm.memset is handled by Bennett-9nwt's `_handle_memset_arm` (see
# test/test_9nwt_memset_const.jl). c=0 takes a fast-path silent drop
# (preserves pre-9nwt behaviour for Julia GC-frame zeroing); c≠0 lowers
# to byte-granular IRStore-of-ConstOperand on fresh alloca-i8 dst, with
# fail-loud reject for non-fresh / wider-element / non-alloca cases.

using Test
using Bennett

@testset "Bennett-lqif: llvm.memcpy / llvm.memmove reject (post-37mt residue)" begin

    @testset "llvm.memcpy on alloca-i64 lowers cleanly (Bennett-ixiz)" begin
        # Bennett-ixiz (2026-05-16): the prior Phase 1 alloca-i64 reject
        # at predicate 8 (`elem_w must be 8`) was lifted to accept any
        # equal-width integer alloca. The fixture `lqif_memcpy_reject.ll`
        # uses `alloca i64` + an 8-byte memcpy (= 1 element at ew=64);
        # post-ixiz it now lowers to 1× IRLoad(width=64) + 1×
        # IRStore(width=64). Filename retained for git history clarity.
        path = joinpath(@__DIR__, "fixtures", "ll", "lqif_memcpy_reject.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_user")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        loads64  = filter(i -> i isa Bennett.IRLoad  && i.width == 64, all_insts)
        stores64 = filter(i -> i isa Bennett.IRStore && i.width == 64, all_insts)
        # 1 memcpy load + final %y load.
        @test length(loads64)  >= 1
        # %x source store + 1 memcpy store.
        @test length(stores64) >= 1 + 1

        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in Int64[0, 1, -1, typemax(Int64), typemin(Int64)]
            @test simulate(c, x) == x
        end
    end

    @testset "llvm.memmove fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "lqif_memmove_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memmove_user")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memmove_user")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-37mt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("memmove", msg)
        end
    end

end
