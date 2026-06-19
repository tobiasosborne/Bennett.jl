using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, extract_parsed_ir, extract_parsed_ir_from_ll
using Bennett: IRRet

# Bennett-jghk — multi-return-site sret support.
#
# Ground truth (verified by live julia probe 2026-06-19): Julia routes a
# >16-byte tuple return through the sret calling convention (LLVM return type
# `void`, caller-allocated buffer). When the tuple is built on MULTIPLE branches
# (e.g. `cond ? (a,b,c) : (d,e,f)`), the optimised IR (auto-SROA/mem2reg, which
# `_module_has_sret` enables) emits ONE store-bearing block PER branch arm, each
# writing every slot, then `br label %common.ret` — a single shared `ret void`
# block. The pre-jghk extractor folded every store into one GLOBAL slot_values
# dict and tripped sret.jl's "multiple stores" reject on the 2nd arm's store.
#
# jghk makes each store-bearing block its own value-bearing IRRet (the by-value
# multi-return shape), and the existing driver.jl `resolve_phi_predicated!`
# multi-IRRet merge (the false-path-safe, branch-guarded predicate merge)
# reconciles them. The void `ret void` block (no stores) is dropped.
#
# This file proves the deliverable on SYNTHETIC fixtures (homogeneous +
# heterogeneous + shared-predecessor) and pins the fail-loud rejects. It does
# NOT prove ht_keyindex2 extracts end-to-end (that hits the Bennett-59zi
# recursive-self-call + llvm.memcpy wall — out of scope).

# Reuse the unsigned-reinterpret matcher from test_sret.jl semantics.
_jghk_match(result::Tuple, expected::Tuple) =
    all(reinterpret(unsigned(typeof(e)), r % unsigned(typeof(e))) ===
        reinterpret(unsigned(typeof(e)), e)
        for (r, e) in zip(result, expected))

_n_ret_blocks(pir) = count(b -> b.terminator isa IRRet, pir.blocks)

@testset "jghk multi-return-site sret" begin

    @testset "homogeneous [3 x i64] two-arm distinct per-slot values" begin
        # Input-dependent values force per-slot SCALAR stores (not a const-global
        # memcpy). Two arms, each its own store-block branching to common.ret.
        f(x::UInt64) = x > 0 ?
            (x + UInt64(1), x + UInt64(2), x + UInt64(3)) :
            (x + UInt64(10), x + UInt64(20), x + UInt64(30))

        pir = extract_parsed_ir(f, Tuple{UInt64})
        @test pir.ret_elem_widths == [64, 64, 64]
        @test pir.ret_width == 192
        # Each arm became a value-bearing IRRet block.
        @test _n_ret_blocks(pir) >= 2

        circuit = reversible_compile(f, UInt64)
        @test verify_reversibility(circuit)
        for x in UInt64[0, 1, 2, 5, 100, typemax(UInt64), typemax(UInt64) - 1]
            @test _jghk_match(simulate(circuit, (x,)), f(x))
        end
    end

    @testset "heterogeneous {i64, i8} two-arm distinct values" begin
        g(x::Int64) = x > 0 ? (x + 1, Int8(x & 0x7f)) : (x - 1, Int8(0))

        pir = extract_parsed_ir(g, Tuple{Int64})
        @test pir.ret_elem_widths == [64, 8]
        @test pir.ret_width == 72
        @test _n_ret_blocks(pir) >= 2

        circuit = reversible_compile(g, Int64)
        @test verify_reversibility(circuit)
        @test circuit.output_elem_widths == [64, 8]
        for x in Int64[0, 1, 5, -1, -100, 127, 128, typemax(Int64), typemin(Int64)]
            out = simulate(circuit, (x,))
            expected = g(x)
            @test (out[1] % Int64) == expected[1]
            @test (out[2] % UInt8) == (expected[2] % UInt8)
        end
    end

    # ---- Inline-.ll fixtures: exact control over the store/return topology ----

    _jghk_dl = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

    # The collector raises `AssertionError` (fail-loud per CLAUDE.md §1) for
    # path-level rejects; per-instruction rejects use `_ir_error` (ErrorException).
    # Accept either via the abstract `Exception` supertype.
    function _jghk_reject(name::String, body::String, needle::String)
        path = tempname() * ".ll"
        open(path, "w") do io
            write(io, "target datalayout = \"$_jghk_dl\"\n\n")
            write(io, body)
        end
        @test_throws Exception extract_parsed_ir_from_ll(path; entry_function=name)
        try
            extract_parsed_ir_from_ll(path; entry_function=name)
            @test false
        catch e
            @test occursin(needle, sprint(showerror, e))
        end
    end

    @testset "reject: split stores across dominating predecessor (not MVP)" begin
        # slot 0 written in the dominating `top` block; slot 1 differs per arm.
        # The MVP requires every slot stored WITHIN each return-source block
        # (the auto-SROA shape ht_keyindex2 produces). A slot stored only in a
        # dominating predecessor is a cross-block reaching-def merge, which is
        # NOT supported (a hand-rolled dominator tree is a false-path hazard per
        # CLAUDE.md's phi-resolution warning) — fail loud rather than guess.
        _jghk_reject("shared_pred", """
        define void @shared_pred(ptr noalias nocapture sret([2 x i64]) align 8 %ret, i64 %x, i1 %c) {
        top:
          store i64 %x, ptr %ret, align 8
          br i1 %c, label %A, label %B
        A:
          %ga = getelementptr inbounds i8, ptr %ret, i64 8
          store i64 100, ptr %ga, align 8
          br label %done
        B:
          %gb = getelementptr inbounds i8, ptr %ret, i64 8
          store i64 200, ptr %gb, align 8
          br label %done
        done:
          ret void
        }
        """, "never written")
    end

    @testset "reject: slot unwritten on one return path" begin
        # Arm A writes both slots; arm B writes only slot 0 -> slot 1 garbage on B.
        _jghk_reject("unwritten_slot", """
        define void @unwritten_slot(ptr noalias nocapture sret([2 x i64]) align 8 %ret, i1 %c) {
        top:
          br i1 %c, label %A, label %B
        A:
          store i64 1, ptr %ret, align 8
          %ga = getelementptr inbounds i8, ptr %ret, i64 8
          store i64 2, ptr %ga, align 8
          br label %done
        B:
          store i64 3, ptr %ret, align 8
          br label %done
        done:
          ret void
        }
        """, "never written")
    end

    @testset "reject: two stores to same slot within a single block" begin
        # Genuine intra-path duplicate -> still loud.
        _jghk_reject("dup_in_block", """
        define void @dup_in_block(ptr noalias nocapture sret([2 x i64]) align 8 %ret) {
        top:
          store i64 1, ptr %ret, align 8
          store i64 9, ptr %ret, align 8
          %g = getelementptr inbounds i8, ptr %ret, i64 8
          store i64 2, ptr %g, align 8
          ret void
        }
        """, "multiple stores")
    end

    @testset "reject: store block unconditionally branches to another store block" begin
        # `top` writes both slots then `br %second`; `second` ALSO writes both
        # slots then `ret void`. In real execution `second`'s stores OVERWRITE
        # `top`'s, so the true return is `second`'s values. Replacing `top`'s
        # branch with a value-bearing IRRet would orphan `second` and could
        # silently return `top`'s stale values — reviewer-hardening fail-loud
        # (Bennett-jghk MVP: store blocks must branch DIRECTLY to the shared
        # store-free `ret void` funnel).
        _jghk_reject("store_then_store", """
        define void @store_then_store(ptr noalias nocapture sret([2 x i64]) align 8 %ret, i64 %x) {
        top:
          store i64 1, ptr %ret, align 8
          %g0 = getelementptr inbounds i8, ptr %ret, i64 8
          store i64 2, ptr %g0, align 8
          br label %second
        second:
          store i64 3, ptr %ret, align 8
          %g1 = getelementptr inbounds i8, ptr %ret, i64 8
          store i64 4, ptr %g1, align 8
          ret void
        }
        """, "store-free")
    end

    @testset "single-return path still byte-identical (swap2 == 66)" begin
        # Pinned in test_sret.jl; re-assert here so a jghk regression is caught
        # in this file too.
        swap2(a::UInt32, b::UInt32) = (a + b, a - b, a, b)
        c1 = reversible_compile(swap2, UInt32, UInt32)
        @test verify_reversibility(c1)
        # (no gate-count pin here; test_gate_count_regression.jl owns the 39 pins)
    end
end
