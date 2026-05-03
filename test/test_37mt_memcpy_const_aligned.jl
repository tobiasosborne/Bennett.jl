# Bennett-37mt (Phase 1 of Bennett-hao) — const-size memcpy lowering
# between alloca-i8-backed pointers. Replaces Phase 0's blanket fail-loud
# (Bennett-lqif) with proper byte-granular IRPtrOffset+IRLoad+IRStore
# expansion for the in-scope shape:
#
#   - llvm.memcpy.p0.p0.i64, isvolatile=false
#   - N is a positive ConstantInt (any positive N; bead's "multiple of 8"
#     wording was for 64-bit chunking, moot under byte-granular chunks)
#   - dst, src alloca-backed (direct alloca or const-offset GEP-of-alloca)
#   - both alloca's elem_w == 8 (i.e. `alloca i8, i32 K` shape)
#   - distinct alloca roots
#
# Out-of-scope cases fail loud with a precise message naming Bennett-8bys
# (catch-all) or Bennett-haod (globals — sub-bead deferred under hao).

using Test
using Bennett

@testset "Bennett-37mt: memcpy const-size alloca-i8 lowering" begin

    @testset "N=8 byte memcpy → 8 IRPtrOffset×2 + 8 IRLoad + 8 IRStore" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "37mt_memcpy_n8_i8.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_n8_i8")
        # Inspect the lowered IR shape.
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        loads  = filter(i -> i isa Bennett.IRLoad,      all_insts)
        stores = filter(i -> i isa Bennett.IRStore,     all_insts)
        offs   = filter(i -> i isa Bennett.IRPtrOffset, all_insts)
        # 8 chunks × 2 IRPtrOffset (src + dst) + the source-side store/load
        # already emit their own ops. The memcpy expansion alone contributes
        # 8 IRLoad + 8 IRStore at width=8 plus 16 IRPtrOffset.
        memcpy_loads = filter(l -> l.width == 8, loads)
        memcpy_stores = filter(s -> s.width == 8, stores)
        @test length(memcpy_loads)  >= 8
        @test length(memcpy_stores) >= 1 + 8   # %x source store + 8 memcpy stores
        @test length(offs)          >= 16

        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Identity oracle: store x to src[0], memcpy 8 bytes, load dst[0] → x.
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == x
        end
    end

    @testset "N=4 byte memcpy (sub-8 N is in scope under byte-granular chunks)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "37mt_memcpy_n4_i8.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_n4_i8")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Identity-via-byte-3 oracle: src[3]=x, memcpy 4 bytes, dst[3] → x.
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == x
        end
    end

    @testset "N=24 byte memcpy (matches t5_tr2_hashmap.ll line 283 shape)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "37mt_memcpy_n24_i8.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_n24_i8")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        loads  = filter(i -> i isa Bennett.IRLoad      && i.width == 8, all_insts)
        stores = filter(i -> i isa Bennett.IRStore     && i.width == 8, all_insts)
        offs   = filter(i -> i isa Bennett.IRPtrOffset, all_insts)
        @test length(loads)  >= 24    # 24 memcpy loads + final dst[17] load
        @test length(stores) >= 1 + 24
        @test length(offs)   >= 24*2  # 24 chunks × (src_off + dst_off)

        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == x
        end
    end

    @testset "volatile memcpy fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "37mt_memcpy_volatile_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memcpy_volatile")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_volatile")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-37mt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("volatile", msg)
        end
    end

    @testset "same-alloca memcpy fails loud → 8bys (overlap)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "37mt_memcpy_same_alloca_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memcpy_self")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_self")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-37mt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("same alloca", msg)
        end
    end

    @testset "alloca i64 (elem_w≠8) memcpy fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "37mt_memcpy_alloca_i64_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memcpy_alloca_i64")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_alloca_i64")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-37mt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("element width", msg)
        end
    end

    @testset "variable-size memcpy fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "37mt_memcpy_var_size_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memcpy_var_n")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_var_n")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-37mt", msg)
            @test occursin("Bennett-8bys", msg)
            @test occursin("non-constant", msg)
        end
    end

    @testset "memmove always fails loud → 8bys" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "37mt_memmove_reject.ll")
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
