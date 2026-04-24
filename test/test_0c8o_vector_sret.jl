# Bennett-0c8o — ir_extract: handle vector-lane sret stores + vector loads.
#
# Under optimize=true, Julia's LLVM pipeline (SROA + SLPVectorizer +
# VectorCombine) promotes aggregate alloca+sret code into vector stores:
#
#     store <4 x i64> %19, ptr %sret_return.sroa_idx, align 8
#
# where %19 = select <4 x i1> %cmp, <4 x i64> %7, <4 x i64> %18
# where %18 = load <4 x i64>, ptr %"state::Tuple[2]_ptr", align 8
#
# Consensus: docs/design/beta_consensus.md.
# Design: defer lane resolution to pass 2 via pending_vec map; add vector-
# load handler to _convert_vector_instruction so the whole chain resolves.
#
# RED → GREEN TDD per CLAUDE.md §3.

using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, extract_parsed_ir
using Bennett: IRInsertValue, IRRet

@testset "Bennett-0c8o vector-lane sret stores" begin

    # ---------------- primary repro: NTuple{9,UInt64} sret extraction ----
    @testset "linear_scan_pmap_set: NTuple{9,UInt64} sret under optimize=true" begin
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                optimize=true)

        @test pir.ret_width == 576
        @test pir.ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
        @test length(pir.args) == 3
        @test pir.args[1][2] == 576
        @test pir.args[2][2] == 8
        @test pir.args[3][2] == 8

        # Last block must terminate with IRRet over the synthesised chain.
        last_block = pir.blocks[end]
        iv_chain = [i for i in last_block.instructions if i isa IRInsertValue]
        @test length(iv_chain) == 9
        for (k, iv) in enumerate(iv_chain)
            @test iv.index == k - 1
            @test iv.elem_width == 64
            @test iv.n_elems == 9
            # No pending-lane sentinel survives.
            @test !(iv.val.kind == :const &&
                    iv.val.name === :__pending_vec_lane__)
        end
        @test last_block.terminator isa IRRet
        @test last_block.terminator.width == 576
    end

    # ---------------- end-to-end: linear_scan_pmap_set compiles + verifies --
    # Note: semantic `simulate` check is limited by the current simulator API
    # (Tuple{Vararg{Integer}} — each arg ≤ 64 bits), and NTuple{9,UInt64}
    # arg is 576 bits. We cannot drive it through `simulate` directly today.
    # This test proves extraction + lowering + Bennett + reversibility hold;
    # a follow-up bead on simulator-side wide-input support can drive the
    # semantic round-trip once lifted.
    @testset "linear_scan_pmap_set: end-to-end reversible compile + verify" begin
        f(s::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(s, k, v)

        circuit = reversible_compile(f, NTuple{9,UInt64}, Int8, Int8)
        @test circuit isa Bennett.ReversibleCircuit
        @test verify_reversibility(circuit)
        # Expected shape: 1 input of 576 bits + 2 of 8 bits; 9-elem return.
        @test circuit.input_widths == [576, 8, 8]
        @test circuit.output_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
    end

    # ---------------- scalar-input variant: semantic simulate check ----------
    # Exercises the full vector-sret + vector-load path but keeps inputs within
    # the simulator API limit. State comes from individual Int64 args.
    @testset "scalar-input pmap_set semantic roundtrip" begin
        # Mimic linear_scan_pmap_set with 9 individual Int64 state slots as args.
        @inline _pick(idx::Int, target::UInt64, nv::UInt64, ov::UInt64) =
            ifelse(target == UInt64(idx), nv, ov)
        function pmap_set_flat(count::UInt64, s2::UInt64, s3::UInt64,
                               s4::UInt64, s5::UInt64, s6::UInt64,
                               s7::UInt64, s8::UInt64, s9::UInt64,
                               k::Int8, v::Int8)::NTuple{9, UInt64}
            target = ifelse(count >= UInt64(4), UInt64(3), count)
            new_count = ifelse(count >= UInt64(4), UInt64(4), count + UInt64(1))
            k_u = UInt64(reinterpret(UInt8, k))
            v_u = UInt64(reinterpret(UInt8, v))
            k1 = _pick(0, target, k_u, s2)
            v1 = _pick(0, target, v_u, s3)
            k2 = _pick(1, target, k_u, s4)
            v2 = _pick(1, target, v_u, s5)
            k3 = _pick(2, target, k_u, s6)
            v3 = _pick(2, target, v_u, s7)
            k4 = _pick(3, target, k_u, s8)
            v4 = _pick(3, target, v_u, s9)
            return (new_count, k1, v1, k2, v2, k3, v3, k4, v4)
        end

        circuit = reversible_compile(pmap_set_flat,
            UInt64, UInt64, UInt64, UInt64, UInt64,
            UInt64, UInt64, UInt64, UInt64, Int8, Int8)
        @test verify_reversibility(circuit)

        function check(count, s2, s3, s4, s5, s6, s7, s8, s9, k, v)
            got = simulate(circuit,
                (count, s2, s3, s4, s5, s6, s7, s8, s9, k, v))
            expected = pmap_set_flat(count, s2, s3, s4, s5, s6, s7, s8, s9, k, v)
            @test length(got) == 9
            for i in 1:9
                @test (UInt64(got[i]) & typemax(UInt64)) == expected[i]
            end
        end

        # Insert at slot 0.
        check(UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0),
              UInt64(0), UInt64(0), UInt64(0), UInt64(0), Int8(5), Int8(7))
        # Insert at slot 1.
        check(UInt64(1), UInt64(5), UInt64(7), UInt64(0), UInt64(0),
              UInt64(0), UInt64(0), UInt64(0), UInt64(0), Int8(2), Int8(42))
        # Insert at slot 2 with partial state.
        check(UInt64(2), UInt64(10), UInt64(20), UInt64(30), UInt64(40),
              UInt64(0), UInt64(0), UInt64(0), UInt64(0), Int8(-1), Int8(-2))
        # Overflow (count=4): writes at slot 3 (last slot).
        check(UInt64(4), UInt64(1), UInt64(2), UInt64(3), UInt64(4),
              UInt64(5), UInt64(6), UInt64(7), UInt64(8), Int8(99), Int8(100))
    end

    # ---------------- regression: scalar-sret paths byte-identical ------
    @testset "regression: swap2 n=2 byte-identical (test_sret baseline)" begin
        swap2(a::Int8, b::Int8) = (b, a)
        cs = reversible_compile(swap2, Int8, Int8)
        @test verify_reversibility(cs)
        # U28 / Bennett-epwy: fold_constants default flipped to true ⇒
        # 82 → 66 for swap2 (pre-zeroed output-tuple words collapse).
        @test gate_count(cs).total == 66
    end

    @testset "regression: n=3 UInt32 identity sret" begin
        f3(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        c3 = reversible_compile(f3, UInt32, UInt32, UInt32)
        @test verify_reversibility(c3)
    end

    @testset "regression: n=8 UInt32 identity sret (no SLP triggered)" begin
        f8(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
           e::UInt32, f_::UInt32, g::UInt32, h::UInt32) =
            (a, b, c, d, e, f_, g, h)
        c8 = reversible_compile(f8, UInt32, UInt32, UInt32, UInt32,
                                    UInt32, UInt32, UInt32, UInt32)
        @test verify_reversibility(c8)
    end

    @testset "regression: heterogeneous sret still rejected" begin
        f_het(a::UInt32, b::UInt64) = (a, b)
        @test_throws ErrorException reversible_compile(f_het, UInt32, UInt64)
    end

    @testset "regression: memcpy-form auto-canonicalised under optimize=false (post-Bennett-uyf9)" begin
        # β shipped when γ wasn't yet merged — this test originally asserted
        # the memcpy error. γ (Bennett-uyf9) auto-canonicalises via SROA, so
        # optimize=false now extracts successfully. Test updated to reflect.
        f3(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        pir = extract_parsed_ir(f3, Tuple{UInt32, UInt32, UInt32}; optimize=false)
        @test pir.ret_width == 96
        @test pir.ret_elem_widths == [32, 32, 32]
    end
end
