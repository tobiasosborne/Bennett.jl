# Bennett-ckvj: direct dispatch for `llvm.asin.f64` as IRCall to `soft_asin`.
#
# Background mirrors Bennett-qpke (atan), Bennett-s1zl (tan), Bennett-3mo
# (sin/cos), and Bennett-1pb (sqrt/exp). `llvm.asin.*` arrives in raw
# `.ll` / `.bc` ingest from the Bennett-xkv multi-language vision (clang/
# rustc emit it for `asin(x)` on doubles).
#
# Routing: `llvm.asin.*` → `soft_asin` (musl asin.c branchless port;
# ≤2 ULP vs `Base.asin` across [-1, 1]). f32 forms rejected per
# CLAUDE.md §13 (Bennett-3rph).

using Test
using Bennett

@testset "Bennett-ckvj: llvm.asin direct dispatch" begin

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_asin") === Bennett.soft_asin
    end

    @testset "llvm.asin.f64 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ckvj_asin_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="asin_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Sweep all four in-domain regimes: tiny / small-poly / mid /
        # near-1. Excludes |x| > 1 (Base.asin throws — no oracle).
        for x in (0.0, 1e-30, 0.1, 0.3, 0.49, 0.5, 0.7, 0.9, 0.97, 0.99, 1.0,
                  -0.5, -0.97, -1.0)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = asin(xf)
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.asin.f64 special cases" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ckvj_asin_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="asin_f64")
        c = reversible_compile(parsed)
        # asin(±0) = ±0 bit-exact (sign-preserving via tiny path).
        @test simulate(c, reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test simulate(c, reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # asin(±1) = ±π/2 bit-exact.
        @test simulate(c, reinterpret(UInt64,  1.0)) == reinterpret(UInt64,  Float64(π/2))
        @test simulate(c, reinterpret(UInt64, -1.0)) == reinterpret(UInt64, -Float64(π/2))
        # asin(NaN) = NaN; asin(±Inf) = NaN; asin(|x|>1) = NaN.
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, NaN))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, -Inf))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, 1.5))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, -2.0))))
    end

    @testset "llvm.asin.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ckvj_asin_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="asin_f32")
    end

end
