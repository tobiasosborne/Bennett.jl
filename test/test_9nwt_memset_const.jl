# Bennett-9nwt (Phase 2 of Bennett-hao) — const-c const-N memset on
# alloca-i8-backed dst. Removes `llvm.memset` from the benign-allowlist
# silent-drop and adds explicit case-discrimination:
#
#   - Case A (c=0, any dst): silent drop — preserves pre-9nwt broad
#     tolerance for Julia GC-frame zeroing patterns. NO alloca/freshness
#     check (intentional; documented gap).
#   - Case C (c≠0, fresh alloca-i8 dst): emit N IRPtrOffset+IRStore
#     pairs at width=8 with ConstOperand(c).
#   - Reject: volatile, non-const c, non-const N, alloca elem_w≠8,
#     non-alloca dst (c≠0 only), non-fresh dst (c≠0 only) — each cites
#     Bennett-9nwt + Bennett-8bys (or Bennett-8bys-uncompute).
#
# Freshness model: option γ — intra-block sweep from alloca to memset
# checking for aliasing writes. Cross-block memset conservatively fails
# loud. See `_alloca_is_fresh` in src/extract/instructions.jl.

using Test
using Bennett

@testset "Bennett-9nwt: const-c const-N memset on alloca-i8" begin

    @testset "c=0 N=8: silent drop (case A)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_c0_n8_fresh.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_c0_n8")
        # Pin: no IRStore was added by the memset (case A is empty no-op).
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        memset_stores = filter(s -> s isa Bennett.IRStore && s.width == 8, all_insts)
        @test length(memset_stores) == 0    # no source-level store either
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: load dst[0] returns 0 since alloca is zero-initialised
        # and memset is a no-op.
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == 0
        end
    end

    @testset "c=0xFF N=8: byte-granular IRStore-of-ConstOperand (case C)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_cFF_n8_fresh.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_cFF_n8")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        offs = filter(i -> i isa Bennett.IRPtrOffset, all_insts)
        stores = filter(s -> s isa Bennett.IRStore && s.width == 8, all_insts)
        @test length(offs)   >= 8
        @test length(stores) >= 8
        # Pin every memset-emitted store carries c=0xFF=255.
        memset_const_stores = filter(stores) do s
            s.val isa Bennett.ConstOperand && s.val.value == 255
        end
        @test length(memset_const_stores) == 8
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: load dst[0] returns 0xFF == Int8(-1).
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == Int8(-1)
        end
    end

    @testset "c=0x55 N=4: case C with mixed-bit fill" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_c55_n4_fresh.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_c55_n4")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: load dst[2] returns 0x55 == 85.
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == 85
        end
    end

    @testset "volatile memset fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_volatile_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memset_volatile")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_volatile")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-9nwt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("volatile", msg)
        end
    end

    @testset "variable-c memset fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_var_c_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memset_var_c")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_var_c")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-9nwt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("non-constant fill", msg)
        end
    end

    @testset "variable-N memset fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_var_n_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memset_var_n")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_var_n")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-9nwt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("non-constant byte count", msg)
        end
    end

    @testset "alloca-i64 dst memset (c≠0) fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_alloca_i64_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memset_alloca_i64")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_alloca_i64")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-9nwt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("element width", msg)
        end
    end

    @testset "non-alloca dst memset (c≠0) fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_param_dst_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memset_param_dst")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_param_dst")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-9nwt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("alloca-backed", msg)
        end
    end

    @testset "non-fresh dst memset (c≠0) fails loud → 8bys-uncompute" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_non_fresh_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memset_non_fresh")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_non_fresh")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-9nwt", msg)
            @test occursin("Bennett-8bys-uncompute", msg)
            @test occursin("non-fresh", msg)
        end
    end

end
