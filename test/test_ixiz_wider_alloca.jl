# Bennett-ixiz — wider-element alloca support (lifts ew==8 gates).
#
# Pre-ixiz, three gates pinned `elem_width == 8` and forced all
# memcpy/memset paths through the alloca-i8 / [N x i8] path:
#   - aggregate.jl:227 ptr-provenance bump (G1)
#   - extract/instructions.jl ArrayType alloca handler (G2, line 1975)
#     and _alloca_elem_width_bits helper (G3, line 58)
#   - _handle_memcpy_arm predicate 8 (G4, lines 170-184)
#   - _handle_memset_arm predicate 12 (G5, lines 419-448)
#
# Post-ixiz, those gates accept any equal-width integer ew (8/16/32/64).
# Mixed-width / cross-alloca-width / sub-element-offset / non-multiple-N
# patterns are still fail-loud and route to Bennett-8bys.
#
# The Gate-2 same-width firewall in src/lowering/memory.jl
# (`inst.width == elem_w`) is intentionally LEFT IN PLACE — the
# ptr-offset / shadow-store contract is "stride is the element width";
# sub-element-width stores remain out-of-scope.

using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRBinOp, IRAlloca, IRStore, IRLoad,
                IRPtrOffset, IRRet, IROperand, ConstOperand, SSAOperand,
                ssa, iconst, lower, bennett

@testset "Bennett-ixiz: wider-element alloca support" begin

    @testset "T1: i64 alloca + same-width store/load round-trip" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ixiz_alloca_i64_roundtrip.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="alloca_i64_rt")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        allocas = filter(i -> i isa IRAlloca, all_insts)
        @test length(allocas) == 1
        @test allocas[1].elem_width == 64
        @test allocas[1].n_elems isa ConstOperand && allocas[1].n_elems.value == 1

        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: identity round-trip via the single i64 slot.
        for x in Int64[0, 1, -1, typemax(Int64), typemin(Int64),
                       0xdeadbeefdeadbeef % Int64,
                       0xabababababababab % Int64]
            @test simulate(c, x) == x
        end
    end

    @testset "T2: [4 x i16] alloca round-trip" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ixiz_arr_i16_n4_roundtrip.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="arr_i16_n4_rt")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        allocas = filter(i -> i isa IRAlloca, all_insts)
        @test length(allocas) == 1
        @test allocas[1].elem_width == 16
        @test allocas[1].n_elems isa ConstOperand && allocas[1].n_elems.value == 4

        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: identity via element [0].
        for x in Int16[0, 1, -1, typemax(Int16), typemin(Int16), 0xdead % Int16]
            @test simulate(c, x) == x
        end
    end

    @testset "T3: i64 memcpy 16-byte lowering" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ixiz_memcpy_alloca_i64_n16.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_alloca_i64_n16")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        memcpy_loads  = filter(i -> i isa IRLoad  && i.width == 64, all_insts)
        memcpy_stores = filter(i -> i isa IRStore && i.width == 64, all_insts)
        # 2 memcpy loads + final %y load = 3 loads at width=64
        @test length(memcpy_loads)  >= 2
        # Source-side store of %x + 2 memcpy stores = 3 stores at width=64
        @test length(memcpy_stores) >= 1 + 2

        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: src[0]=x, memcpy 16 bytes, dst[0] → x.
        for x in Int64[0, 1, -1, typemax(Int64), typemin(Int64),
                       0xdeadbeefdeadbeef % Int64]
            @test simulate(c, x) == x
        end
    end

    @testset "T4: i64 memset c=0 N=16 (case A short-circuit, no stores)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ixiz_memset_alloca_i64_c0_n16.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_alloca_i64_c0_n16")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        # Case A: c=0 short-circuits to IRInst[]; no width=64 stores from memset.
        memset_stores = filter(i -> i isa IRStore && i.width == 64, all_insts)
        @test length(memset_stores) == 0   # no source-level store either
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: load returns 0 since the alloca is zero-initialised by
        # the WireAllocator invariant and memset is a no-op.
        for x in Int64[0, 1, -1, typemax(Int64)]
            @test simulate(c, x) == 0
        end
    end

    @testset "T5: i64 memset c=0xAB N=16 (byte-broadcast 0xABABABABABABABAB)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ixiz_memset_alloca_i64_cAB_n16.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_alloca_i64_cAB_n16")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        offs   = filter(i -> i isa IRPtrOffset, all_insts)
        stores = filter(i -> i isa IRStore && i.width == 64, all_insts)
        # 2 IRPtrOffset + 2 IRStore width=64 (N=16 / ew_bytes=8 = 2 chunks).
        @test length(offs)   >= 2
        @test length(stores) >= 2
        # Pin: every memset-emitted store carries c_broadcast = 0xABABABABABABABAB.
        expected_broadcast = Int(0xababababababababab % Int64)
        memset_stores = filter(stores) do s
            s.val isa ConstOperand && s.val.value == expected_broadcast
        end
        @test length(memset_stores) == 2
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: load returns 0xABABABABABABABAB regardless of input.
        for x in Int64[0, 1, -1, typemax(Int64), typemin(Int64)]
            @test simulate(c, x) == expected_broadcast
        end
    end

    @testset "T6: sub-element IRPtrOffset on alloca i64 rejected (fail-loud)" begin
        # Hand-build ParsedIR: alloca i64 [n=2], then an IRPtrOffset with
        # off=4 bytes. 4 bytes is half an i64 element, not a whole multiple,
        # so the per-origin rem-guard in lower_ptr_offset! should fire.
        block = IRBasicBlock(:entry,
            [
                IRAlloca(:p, 64, iconst(2)),
                IRPtrOffset(:q, ssa(:p), 4),
                # never reached; included so the block has a real shape:
                IRLoad(:y, ssa(:q), 64),
            ],
            IRRet(ssa(:y), 64))
        parsed = ParsedIR(64, [(:x, 64)], [block], [64])
        @test_throws DimensionMismatch lower(parsed)
    end

    @testset "T7: mixed-width store rejected via the memory.jl firewall" begin
        # Hand-build: alloca i64 [n=1], then an IRStore at width=32.
        # The existing Gate-2 firewall in memory.jl
        # (`inst.width == elem_w || throw(DimensionMismatch(...))`) is
        # unchanged by ixiz; this confirms it still bites for mixed-width.
        block = IRBasicBlock(:entry,
            [
                IRAlloca(:p, 64, iconst(1)),
                IRStore(ssa(:p), iconst(123), 32),  # narrow store into wide slot
                IRLoad(:y, ssa(:p), 64),
            ],
            IRRet(ssa(:y), 64))
        parsed = ParsedIR(64, [(:x, 64)], [block], [64])
        @test_throws DimensionMismatch lower(parsed)
    end

    @testset "T8: cross-alloca-width memcpy rejected (predicate 8b)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ixiz_memcpy_cross_width_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memcpy_cross_width")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_cross_width")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-ixiz", msg)
            @test occursin("cross-width", msg)
        end
    end

    @testset "T9: memcpy N not multiple of ew_bytes rejected (predicate 8c)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ixiz_memcpy_n_mismatch_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memcpy_n_mismatch")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memcpy_n_mismatch")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-ixiz", msg)
            @test occursin("not a multiple", msg)
        end
    end

end
