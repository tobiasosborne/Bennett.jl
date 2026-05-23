# Bennett-s1zl: direct dispatch for `llvm.tan.f64` as IRCall to `soft_tan`.
#
# Background mirrors Bennett-3mo (sin/cos) and Bennett-1pb (sqrt/exp).
# `llvm.tan.*` arrives in raw `.ll` / `.bc` ingest from the Bennett-xkv
# multi-language vision (clang/rustc emit it for `tan(x)` on doubles).
#
# Routing: `llvm.tan.*` → `soft_tan` (musl `__tan` port reusing
# `_rp_rem_pio2`; ≤2 ULP vs `Base.tan` across the full Float64 range).
# f32 forms rejected per CLAUDE.md §13 (Bennett-3rph).

using Test
using Bennett

@testset "Bennett-s1zl: llvm.tan direct dispatch" begin

    # Bennett-hybr: compile the llvm.tan.f64 fixture ONCE and share the
    # resulting circuit across the two testsets that exercise it.
    _tan_f64_path = joinpath(@__DIR__, "fixtures", "ll", "s1zl_tan_f64.ll")
    _tan_f64_parsed = Bennett.extract_parsed_ir_from_ll(_tan_f64_path; entry_function="tan_f64")
    _tan_f64_c = reversible_compile(_tan_f64_parsed)

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_tan") === Bennett.soft_tan
    end

    @testset "llvm.tan.f64 via .ll ingest" begin
        c = _tan_f64_c
        @test verify_reversibility(c)
        for x in (1.0, 2.0, 0.5, 0.1, 0.6744, 0.7, 0.78539816, 100.0, 1e6, 1e10)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = tan(xf)
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.tan.f64 special cases" begin
        c = _tan_f64_c
        # tan(±0) = ±0 bit-exact (sign-preserving).
        @test simulate(c, reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test simulate(c, reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # tan(±Inf) = NaN, tan(NaN) = NaN.
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, -Inf))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, NaN))))
    end

    @testset "llvm.tan.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "s1zl_tan_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="tan_f32")
    end

end
