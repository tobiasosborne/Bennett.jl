# Bennett-qpke: direct dispatch for `llvm.atan.f64` as IRCall to `soft_atan`.
#
# Background mirrors Bennett-s1zl (tan), Bennett-3mo (sin/cos), and
# Bennett-1pb (sqrt/exp). `llvm.atan.*` arrives in raw `.ll` / `.bc`
# ingest from the Bennett-xkv multi-language vision (clang/rustc emit
# it for `atan(x)` on doubles).
#
# Routing: `llvm.atan.*` → `soft_atan` (musl atan.c branchless port;
# ≤2 ULP vs `Base.atan` across the full Float64 range). f32 forms
# rejected per CLAUDE.md §13 (Bennett-3rph).

using Test
using Bennett

@testset "Bennett-qpke: llvm.atan direct dispatch" begin

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_atan") === Bennett.soft_atan
    end

    @testset "llvm.atan.f64 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "qpke_atan_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="atan_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (1.0, 2.0, 0.5, 0.1, 0.4375, 0.6875, 1.1875, 2.4375, 100.0, 1e6, 1e10)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = atan(xf)
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.atan.f64 special cases" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "qpke_atan_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="atan_f64")
        c = reversible_compile(parsed)
        # atan(±0) = ±0 bit-exact (sign-preserving).
        @test simulate(c, reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test simulate(c, reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # atan(±Inf) = ±π/2 bit-exact.
        @test simulate(c, reinterpret(UInt64,  Inf)) == reinterpret(UInt64,  Float64(π/2))
        @test simulate(c, reinterpret(UInt64, -Inf)) == reinterpret(UInt64, -Float64(π/2))
        # atan(NaN) = NaN.
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, NaN))))
    end

    @testset "llvm.atan.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "qpke_atan_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="atan_f32")
    end

end
