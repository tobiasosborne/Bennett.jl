# Bennett-lqif (Bennett-hao Phase 0): llvm.memcpy / llvm.memmove fail
# loud at IR walking with reference to the proper-lowering sub-beads.
#
# Pre-lqif: silent-dropped via the benign-prefixes allowlist (a
# CLAUDE.md §1 fail-loud violation). Empirically benign for Julia
# frontend code (SROA decomposes upstream) but produces garbage on raw
# .ll/.bc ingest (Bennett-xkv multi-language vision — 60 memcpy sites in
# build/t5_tr2_hashmap.ll alone).
#
# llvm.memset stays in the benign list pending Bennett-9nwt (Phase 2)
# because its only Julia-frontend use is memset(0) on fresh ancillae,
# which is a no-op. Raw .ll/.bc memset(c≠0) is a known gap tracked in
# Bennett-9nwt.

using Test
using Bennett

@testset "Bennett-lqif: llvm.memcpy / llvm.memmove reject (Bennett-hao Phase 0)" begin

    @testset "llvm.memcpy fails loud" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "lqif_memcpy_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memcpy_user")
        # Verify the error message references the right sub-beads.
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_user")
            @test false  # should have thrown
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-37mt", msg)
            @test occursin("Bennett-lqif", msg)
            @test occursin("memcpy", msg)
        end
    end

    @testset "llvm.memmove fails loud" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "lqif_memmove_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memmove_user")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memmove_user")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-37mt", msg)
            @test occursin("memmove", msg)
        end
    end

end
