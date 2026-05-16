# Bennett-doih (2026-05-16, Bennett-8bys sub-bead under Bennett-hao Phase 3) —
# Global-pointer src memcpy. Splits the pre-doih predicate 5 in
# `_handle_memcpy_arm` into 5a (DST-as-global → still reject) and 5b
# (SRC-as-global → dispatch to new `_handle_memcpy_global_src` arm).
#
# The new arm lowers to K element-granular IRPtrOffset+IRStore(iconst)
# chunks, mirroring Bennett-9nwt case C but pulling per-element
# constants from `parsed.globals[gname].data` rather than a single
# broadcast byte.
#
# Scope is intentionally narrow per the Bennett-ixiz "scope it tight"
# lesson (worklog/069):
#   - global must be a `ConstantDataArray` (already filtered by
#     `_extract_const_globals` in module_walk.jl)
#   - dst alloca must have the SAME integer element width as the global
#     (G6 same-width predicate; cross-width follow-up: `Bennett-doih-wide`)
#   - dst alloca must be FRESH (G9 reuses `_alloca_is_fresh` from 9nwt)
#   - src may be a direct global ref OR a const-byte-offset GEP of a
#     global; variable-GEP src → `Bennett-doih-vargep` follow-up
#
# t5_tr2_hashmap.ll:153 specifically uses a `ConstantStruct` global with
# a `ptr` first field — out of scope for doih MVP. The `struct_reject`
# fixture below pins that fail-loud path; the eventual fix is tracked
# in `Bennett-doih-struct`.

using Test
using Bennett

@testset "Bennett-doih: global-src memcpy lowering" begin

    # ---- Positive: direct global src ----

    @testset "N=4 [4 x i8] global → 4× IRPtrOffset+IRStore(iconst, 8)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_n4_i8.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_n4_i8")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        # Inspect the lowered IR shape: 4 IRPtrOffset + 4 IRStore(width=8)
        # from the memcpy expansion (plus the trailing load's GEP and any
        # auto-bookkeeping).
        offs = filter(i -> i isa Bennett.IRPtrOffset, all_insts)
        # 4 from memcpy + 1 from %dst2 GEP.
        @test length(offs) >= 5
        stores8 = filter(i -> i isa Bennett.IRStore && i.width == 8, all_insts)
        @test length(stores8) >= 4
        # All 4 memcpy-emitted stores should have ConstOperand values.
        const_stores = filter(s -> s.val isa Bennett.ConstOperand, stores8)
        @test length(const_stores) >= 4
        # The values should match the global bytes: 0x11, 0x22, 0x33, 0x44.
        const_vals = sort(unique(s.val.value for s in const_stores))
        @test 0x11 in const_vals
        @test 0x44 in const_vals

        # End-to-end: compile + verify reversibility + check oracle.
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: dst[2] = gtab[2] = 0x33 = 51. Input %x is unused.
        for x in Int8(-4):Int8(4)
            @test simulate(c, x) == Int8(0x33)
        end
    end

    @testset "N=8 [8 x i8] global → 8 IRStore(iconst, 8)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_n8_i8.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_n8_i8")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: dst[5] = gtab8[5] = 0x66 = 102.
        for x in Int8(-4):Int8(4)
            @test simulate(c, x) == Int8(0x66)
        end
    end

    @testset "N=32 [32 x i8] global (matches t5 byte count)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_n32_i8.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_n32_i8")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        # 32 memcpy stores at width=8.
        stores8 = filter(i -> i isa Bennett.IRStore && i.width == 8, all_insts)
        @test length(stores8) >= 32
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: dst[17] = gtab32[17] = 0x11 = 17.
        for x in Int8(-4):Int8(4)
            @test simulate(c, x) == Int8(0x11)
        end
    end

    @testset "N=32 [4 x i64] global → 4× IRStore(iconst, 64) (wider-element)" begin
        # Exercises G6 same-width path at ew=64 + verifies ixiz integration.
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_n4_i64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_n4_i64")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        stores64 = filter(i -> i isa Bennett.IRStore && i.width == 64, all_insts)
        @test length(stores64) >= 4
        # All 4 memcpy stores should be ConstOperand at width=64.
        const_stores = filter(s -> s.val isa Bennett.ConstOperand, stores64)
        @test length(const_stores) >= 4
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: dst[1] = gtab_i64[1] = 1234605616436508552 = 0x1122334455667788.
        for x in Int64[0, 1, -1, typemax(Int64), typemin(Int64)]
            @test simulate(c, x) == 1234605616436508552
        end
    end

    @testset "const-GEP src: memcpy from @gtab+4" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_const_gep.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_const_gep")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: dst[1] = gtab_gep[4+1] = gtab_gep[5] = 0x66 = 102.
        for x in Int8(-4):Int8(4)
            @test simulate(c, x) == Int8(0x66)
        end
    end

    # ---- Rejects: precise breadcrumb assertions ----

    @testset "global-DST memcpy rejects with Bennett-doih breadcrumb (5a)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_dst_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="doih_global_dst")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_global_dst")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("global-variable dst", msg) || occursin("Global-pointer dst", msg)
        end
    end

    @testset "ConstantStruct global rejects with Bennett-doih-struct (G5)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_struct_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="doih_struct_src")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_struct_src")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-doih-struct", msg)
        end
    end

    @testset "external-declaration global rejects with Bennett-doih-external (G5)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_external_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="doih_ext_src")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_ext_src")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-doih-external", msg)
        end
    end

    @testset "cross-width src/dst rejects with Bennett-doih-wide (G6)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_cross_width_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="doih_cross_width")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_cross_width")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-doih-wide", msg)
            @test occursin("cross-width", msg)
        end
    end

    @testset "oversize N (reads past global end) rejects (G8)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_oversize_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="doih_oversize")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_oversize")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Out-of-bounds", msg) || occursin("past", msg) ||
                  occursin("only", msg)
        end
    end

    @testset "non-fresh dst rejects with Bennett-8bys-uncompute (G9)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_non_fresh_dst_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="doih_non_fresh")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_non_fresh")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-8bys-uncompute", msg)
            @test occursin("non-fresh", msg)
        end
    end

    @testset "variable-GEP src rejects with Bennett-doih-vargep" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "doih_global_src_var_gep_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="doih_var_gep")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="doih_var_gep")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-doih-vargep", msg)
        end
    end

end
