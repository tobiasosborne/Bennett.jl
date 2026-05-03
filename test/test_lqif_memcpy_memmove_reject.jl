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

    @testset "llvm.memcpy on alloca-i64 fails loud → 8bys (elem_w predicate)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "lqif_memcpy_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memcpy_user")
        # The fixture uses `alloca i64, align 8` for both src and dst, so
        # post-37mt the rejection routes through the elem_w=8 predicate
        # rather than the old Phase 0 blanket reject.
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_user")
            @test false  # should have thrown
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-37mt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("element width", msg)
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
