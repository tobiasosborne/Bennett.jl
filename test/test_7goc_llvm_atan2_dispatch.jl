# Bennett-7goc: direct dispatch for `llvm.atan2.f64` AND libm `@atan2` as
# IRCall to `soft_atan2`. Tier C1.5 in Bennett-Enzyme-Parity-NorthStar.md.
#
# Two LLVM-ingest shapes are covered (both arise in raw .ll/.bc ingest):
#
# 1. `llvm.atan2.f64` — LLVM 18+ ships this binary intrinsic. clang/rustc
#    targeting modern LLVM emit it directly when math intrinsics are
#    enabled (-fno-math-errno, -O2+, etc.).
#
# 2. `@atan2(double, double)` (libm-style external call) — what older
#    LLVMs (≤17) emit, what `-fno-builtin-atan2` produces, and the
#    canonical shape for `-O0` C/Rust code.
#
# Both routes lower to the same IRCall(soft_atan2, [y, x]). f32 forms
# rejected per CLAUDE.md §13 (Bennett-3rph).
#
# Pre-7goc bug fixed by this bead: `startswith(cname, "llvm.atan")`
# matched `"llvm.atan2.f64"` and silently dispatched to `soft_atan(y)`,
# dropping x — wrong results for any quadrant outside (y>0, x>0).
# This file's `llvm.atan2.f64 via .ll ingest` testset would have failed
# pre-7goc with quadrant-wrong outputs (~5/8 mismatches), so it doubles
# as a regression test against the silent-miscompile.

using Test
using Bennett

@testset "Bennett-7goc: llvm.atan2 direct dispatch" begin

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_atan2") === Bennett.soft_atan2
    end

    @testset "llvm.atan2.f64 via .ll ingest — generic accuracy" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "7goc_atan2_intrinsic.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="atan2_intr")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for (y, x) in (
            ( 1.0,  1.0), (-1.0,  1.0), ( 1.0, -1.0), (-1.0, -1.0),
            ( 3.0,  4.0), (-3.0,  4.0), ( 3.0, -4.0), (-3.0, -4.0),
            ( 0.5, -0.5), ( 100.0, 1.0), ( 1.0, 100.0),
        )
            yu = reinterpret(UInt64, y); xu = reinterpret(UInt64, x)
            got = simulate(c, (yu, xu))
            actual = reinterpret(Float64, UInt64(got))
            expected = atan(y, x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.atan2.f64 special cases" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "7goc_atan2_intrinsic.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="atan2_intr")
        c = reversible_compile(parsed)
        # axis points: y == 0
        @test simulate(c, (reinterpret(UInt64,  0.0), reinterpret(UInt64, 1.0))) == reinterpret(UInt64,  0.0)
        @test simulate(c, (reinterpret(UInt64, -0.0), reinterpret(UInt64, 1.0))) == reinterpret(UInt64, -0.0)
        @test simulate(c, (reinterpret(UInt64,  0.0), reinterpret(UInt64,-1.0))) == reinterpret(UInt64,  Float64(π))
        @test simulate(c, (reinterpret(UInt64, -0.0), reinterpret(UInt64,-1.0))) == reinterpret(UInt64, -Float64(π))
        # axis points: x == 0
        @test simulate(c, (reinterpret(UInt64, 1.0), reinterpret(UInt64, 0.0))) == reinterpret(UInt64,  Float64(π/2))
        @test simulate(c, (reinterpret(UInt64,-1.0), reinterpret(UInt64, 0.0))) == reinterpret(UInt64, -Float64(π/2))
        # both ±Inf
        @test simulate(c, (reinterpret(UInt64,  Inf), reinterpret(UInt64,  Inf))) == reinterpret(UInt64,  Float64(π/4))
        @test simulate(c, (reinterpret(UInt64, -Inf), reinterpret(UInt64, -Inf))) == reinterpret(UInt64, -Float64(3π/4))
        # NaN propagation
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN), reinterpret(UInt64, 1.0)))))
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, 1.0), reinterpret(UInt64, NaN)))))
    end

    @testset "libm @atan2 via .ll ingest — generic accuracy" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "7goc_atan2_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="atan2_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for (y, x) in (
            ( 1.0,  1.0), (-1.0,  1.0), ( 1.0, -1.0), (-1.0, -1.0),
            ( 3.0,  4.0), ( 0.5, -0.5),
        )
            yu = reinterpret(UInt64, y); xu = reinterpret(UInt64, x)
            got = simulate(c, (yu, xu))
            actual = reinterpret(Float64, UInt64(got))
            expected = atan(y, x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.atan2.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "7goc_atan2_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="atan2_f32")
    end

    @testset "libm @atan2f rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "7goc_atan2_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="atan2f_libm")
    end

end
