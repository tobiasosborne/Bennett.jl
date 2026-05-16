# Bennett-munq (Phase 3 sub-bead 1 of Bennett-hao) — extract
# `[N x i8]` ArrayType allocas as IRAlloca(elem_w=8, n_elems=N).
# Smallest scope, biggest impact in the Bennett-8bys split: unblocks
# all 60 t5_tr2_hashmap.ll memcpy sites via the existing Phase 1 path
# (Bennett-37mt) and the existing Phase 2 path (Bennett-9nwt).
#
# Reject paths: nested ArrayType (`[N x [M x i8]]`) and wider-element
# ArrayType (`[N x i16]` etc.) defer to Bennett-ixiz / future
# follow-ups — they fail loud at the existing predicate gates.

using Test
using Bennett

@testset "Bennett-munq: [N x i8] ArrayType alloca extraction" begin

    @testset "[8 x i8] alloca + memcpy → green via 37mt path" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "munq_arr_i8_alloca_n8.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="arr_i8_n8")
        # Pin: an IRAlloca was emitted for each `[8 x i8]` alloca.
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        allocas = filter(i -> i isa Bennett.IRAlloca, all_insts)
        @test length(allocas) == 2
        @test all(a -> a.elem_width == 8, allocas)
        @test all(a -> a.n_elems isa Bennett.ConstOperand && a.n_elems.value == 8, allocas)

        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Identity oracle (37mt path): store x to src[0], memcpy 8 bytes,
        # load dst[0] → x.
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == x
        end
    end

    @testset "[24 x i8] alloca + memcpy → matches t5_tr2 line 283 shape" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "munq_arr_i8_alloca_n24.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="arr_i8_n24")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        allocas = filter(i -> i isa Bennett.IRAlloca, all_insts)
        @test length(allocas) == 2
        @test all(a -> a.elem_width == 8 && a.n_elems.value == 24, allocas)

        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Identity-via-byte-17: store x to src[17], memcpy 24 bytes,
        # load dst[17] → x.
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == x
        end
    end

    @testset "[8 x i8] alloca + memset(c=0xFF) → green via 9nwt path" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "munq_arr_i8_memset.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="arr_i8_memset")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == Int8(-1)   # 0xFF
        end
    end

    @testset "Nested ArrayType `[N x [M x i8]]` rejected" begin
        # Should fail downstream — the nested type isn't extracted as IRAlloca,
        # and the SSA name has no provenance, so lower_store! / IRPtrOffset
        # eventually errors out. Exact error message is downstream-dependent;
        # we just assert ErrorException is thrown.
        path = joinpath(@__DIR__, "fixtures", "ll", "munq_arr_nested_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="arr_nested")
    end

    @testset "Wider-element ArrayType `[N x i16]` accepted (Bennett-ixiz)" begin
        # Bennett-ixiz (2026-05-16): the alloca handler in
        # src/extract/instructions.jl previously bailed at
        # `LLVM.width(inner) == 8 || return nothing`, and the
        # `_alloca_elem_width_bits` helper returned 0 for `[N x i16]`.
        # Both gates were lifted to accept any integer inner width.
        # This fixture was the canonical wider-elem `[N x i16]` shape
        # that pre-ixiz rejected at extract; post-ixiz it must compile
        # cleanly via the same memcpy path Bennett-37mt uses for [N x i8].
        path = joinpath(@__DIR__, "fixtures", "ll", "munq_arr_i16_reject.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="arr_i16")
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        allocas = filter(i -> i isa Bennett.IRAlloca, all_insts)
        @test length(allocas) == 2
        @test all(a -> a.elem_width == 16, allocas)
        @test all(a -> a.n_elems isa Bennett.ConstOperand && a.n_elems.value == 4,
                  allocas)
        # Helper invariant: `_alloca_elem_width_bits` now returns 16 for
        # `[4 x i16]` allocas (vs. 0 pre-ixiz).
        # (Direct helper test omitted — covered structurally by the
        # IRAlloca shape assertions above.)
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Identity oracle: store x to src[0], memcpy 8 bytes (1 element
        # at ew=16 → wait: N=8, ew_bytes=2 ⇒ K=4 elements copied).
        for x in Int16[0, 1, -1, typemax(Int16), typemin(Int16)]
            @test simulate(c, x) == x
        end
    end

end
