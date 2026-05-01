# Bennett-h6f: direct dispatch for `llvm.fma.f64` and `llvm.fmuladd.f64`
# as `IRCall(soft_fma)`.
#
# `soft_fma` was shipped in Bennett-0xx3 (2026-04-16, worklog/019) as a
# bit-exact IEEE 754 binary64 FMA via 106-bit intermediate product. It's
# already in `_CALLEES_FP_BINARY` and routed via `Base.muladd(::SoftFloat,
# ::SoftFloat, ::SoftFloat)` for the Julia frontend. h6f wires the LLVM
# intrinsic name directly so raw `.ll` ingest (Bennett-xkv path) and any
# Julia source that emits `@llvm.fma.f64` directly compiles too.
#
# Per LangRef, `llvm.fmuladd.f64` may be split into fmul+fadd by the
# lowerer. Bennett.jl deliberately routes both to soft_fma (single
# rounding, bit-exact) per CLAUDE.md §1 (fail loud) + §13 (bit-exact
# f64) — the alternative would mean fmuladd produces a different
# answer than fma on the same inputs, which is a class of "silent
# disagreement" bug we explicitly avoid.

@testset "Bennett-h6f: llvm.fma.f64 / llvm.fmuladd.f64 direct dispatch" begin

    @testset "soft_fma callee is registered" begin
        @test Bennett._lookup_callee("soft_fma") === Bennett.soft_fma
    end

    @testset "llvm.fma.f64 via .ll ingest — bit-exact vs Base.fma" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "h6f_fma_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="fma_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        cases = [
            (1.0, 2.0, 3.0),         # 1*2+3 = 5
            (0.0, 1.0, 0.0),         # zero
            (1.5, 2.5, 0.25),        # exact mantissa
            (1e10, 1e-10, 1.0),      # near-cancellation
            (1.0, 1.0, -2.0),        # = -1.0
            (-1.0, -1.0, 0.0),       # 1.0
            (2.5, 4.0, 1.0),         # 11.0
        ]
        for (a, b, c_v) in cases
            ab = reinterpret(UInt64, a)
            bb = reinterpret(UInt64, b)
            cb = reinterpret(UInt64, c_v)
            got_bits = simulate(c, (ab, bb, cb))
            @test reinterpret(Float64, got_bits) === Base.fma(a, b, c_v)
        end
    end

    @testset "llvm.fmuladd.f64 via .ll ingest — same as fma (single-rounding)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "h6f_fmuladd_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="fmuladd_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Bennett routes both to soft_fma (single-rounding), so result
        # should match Base.fma on these inputs — even where the LLVM-
        # spec-permitted fmul+fadd split would differ in the last ulp.
        cases = [
            (1.0, 2.0, 3.0),
            (3.14, 2.71, 1.0),
            (0.0, 1.0, 1.0),
            (1.0, 1.0, 0.0),
        ]
        for (a, b, c_v) in cases
            ab = reinterpret(UInt64, a)
            bb = reinterpret(UInt64, b)
            cb = reinterpret(UInt64, c_v)
            got_bits = simulate(c, (ab, bb, cb))
            @test reinterpret(Float64, got_bits) === Base.fma(a, b, c_v)
        end
    end

end
