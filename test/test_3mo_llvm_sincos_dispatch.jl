# Bennett-3mo: direct dispatch for `llvm.sin` / `llvm.cos` as IRCall to
# the matching soft_{sin,cos} primitive.
#
# Background mirrors Bennett-1pb / Bennett-582 / Bennett-emv. Julia's
# `Base.sin` / `Base.cos` normally route through SoftFloat dispatch when
# callers wrap their inputs in `SoftFloat`, so `llvm.sin.f64` rarely
# appears in IR Bennett extracts from Julia frontends. But the intrinsic
# CAN arrive with raw operands via `@fastmath sin(x)` on a Float64,
# `Core.Intrinsics`, or raw `.ll`/`.bc` ingest (Bennett-xkv multi-language
# vision).
#
# Routing: `llvm.sin.*` → `soft_sin`, `llvm.cos.*` → `soft_cos`.
# f32 forms are rejected per CLAUDE.md §13 (Bennett-3rph / U137).

using Test
using Bennett

@testset "Bennett-3mo: llvm.sin / llvm.cos direct dispatch" begin

    # Bennett-hybr: compile the llvm.sin.f64 / llvm.cos.f64 fixtures ONCE each
    # and share each circuit across the two testsets that exercise it
    # (accuracy + special-cases).
    _sin_f64_path = joinpath(@__DIR__, "fixtures", "ll", "3mo_sin_f64.ll")
    _sin_f64_parsed = Bennett.extract_parsed_ir_from_ll(_sin_f64_path; entry_function="sin_f64")
    _sin_f64_c = reversible_compile(_sin_f64_parsed)
    _cos_f64_path = joinpath(@__DIR__, "fixtures", "ll", "3mo_cos_f64.ll")
    _cos_f64_parsed = Bennett.extract_parsed_ir_from_ll(_cos_f64_path; entry_function="cos_f64")
    _cos_f64_c = reversible_compile(_cos_f64_parsed)

    @testset "callees registered" begin
        @test Bennett._lookup_callee("soft_sin") === Bennett.soft_sin
        @test Bennett._lookup_callee("soft_cos") === Bennett.soft_cos
    end

    @testset "llvm.sin.f64 via .ll ingest" begin
        c = _sin_f64_c
        @test verify_reversibility(c)
        for x in (1.0, 2.0, 0.5, 0.1, 100.0, 0.78539816, 1e6, 1e10)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = sin(xf)
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.cos.f64 via .ll ingest" begin
        c = _cos_f64_c
        @test verify_reversibility(c)
        for x in (0.0, 1.0, 2.0, 0.5, 0.1, 100.0, 0.78539816, 1e6, 1e10)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = cos(xf)
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.sin.f64 special cases" begin
        c = _sin_f64_c
        # sin(0) = 0 bit-exact, sin(-0) = -0 (sign-preserving)
        @test simulate(c, reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test simulate(c, reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # sin(±Inf) = NaN, sin(NaN) = NaN
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, NaN))))
    end

    @testset "llvm.cos.f64 special cases" begin
        c = _cos_f64_c
        # cos(±0) = 1.0 bit-exact
        @test simulate(c, reinterpret(UInt64,  0.0)) == reinterpret(UInt64, 1.0)
        @test simulate(c, reinterpret(UInt64, -0.0)) == reinterpret(UInt64, 1.0)
        # cos(±Inf) = NaN, cos(NaN) = NaN
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, NaN))))
    end

    @testset "llvm.sin.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "3mo_sin_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="sin_f32")
    end

    @testset "llvm.cos.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "3mo_cos_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="cos_f32")
    end

end
