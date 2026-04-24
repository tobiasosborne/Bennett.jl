# Bennett-uyf9 — ir_extract: handle memcpy-form sret via auto-SROA.
#
# Under optimize=false, Julia's specfunc emits aggregate returns via
# `alloca [N x iM]` + llvm.memcpy into the sret pointer. Previously rejected
# by _collect_sret_writes with "sret with llvm.memcpy form is not supported".
#
# Fix: when _module_has_sret returns true and "sroa" isn't already in the
# pass pipeline, auto-prepend ["sroa", "mem2reg"] to effective_passes so SROA
# decomposes the alloca+memcpy into per-slot scalar stores that the existing
# sret pre-walk handles natively.
#
# Consensus: docs/design/gamma_consensus.md.

using Test
using Bennett
using Bennett: extract_parsed_ir, reversible_compile, simulate,
               verify_reversibility, gate_count

@testset "Bennett-uyf9 memcpy-form sret via auto-SROA" begin

    # ---------------- primary repro: NTuple{9,UInt64} under optimize=false ---
    @testset "NTuple{9,UInt64} sret extracts under optimize=false" begin
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                optimize=false)
        @test pir.ret_width == 576
        @test pir.ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
        @test length(pir.args) == 3
    end

    # ---------------- auto-SROA kicks in even with explicit preprocess=false
    @testset "auto-SROA kicks in with explicit preprocess=false" begin
        # preprocess=false means caller said "no preprocessing" — but since
        # sret is detected, we STILL auto-prepend SROA (the alternative is
        # failing with a confusing error). Per consensus §1.
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                optimize=false, preprocess=false)
        @test pir.ret_width == 576
    end

    # ---------------- non-sret regression: no auto-prepend ---------------
    @testset "non-sret function under optimize=false is unchanged" begin
        # Simple scalar-return function — no sret. Auto-SROA should NOT
        # fire (gated on _module_has_sret).
        f(x::Int8)::Int8 = x + Int8(1)
        c = reversible_compile(f, Int8)
        @test verify_reversibility(c)
        # Baseline: i8 x+1 = 58 gates / 12 Toffoli post-U27/U28.
        # (Pre-U28 Cuccaro+no-fold was 100 / 28.)
        @test gate_count(c).total == 58
        @test gate_count(c).Toffoli == 12
    end

    # ---------------- explicit preprocess=true: no double-SROA ------------
    @testset "preprocess=true path unchanged (no double SROA)" begin
        # If user passed preprocess=true, SROA is already in effective_passes
        # via DEFAULT_PREPROCESSING_PASSES. Auto-prepend must skip.
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                optimize=false, preprocess=true)
        @test pir.ret_width == 576
        @test pir.ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
    end

    # ---------------- smaller NTuple under optimize=false -----------------
    @testset "NTuple{3,UInt32} identity under optimize=false" begin
        f3(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        pir = extract_parsed_ir(f3, Tuple{UInt32, UInt32, UInt32};
                                optimize=false)
        @test pir.ret_width == 96
        @test pir.ret_elem_widths == [32, 32, 32]
    end
end
