# Bennett-bd7f: direct dispatch for `llvm.acos.f64` as IRCall to `soft_acos`.
#
# Background mirrors Bennett-ckvj (asin), Bennett-qpke (atan), Bennett-s1zl
# (tan). `llvm.acos.*` arrives in raw `.ll` / `.bc` ingest from the
# Bennett-xkv multi-language vision (clang/rustc emit it for `acos(x)`
# on doubles).
#
# Routing: `llvm.acos.*` → `soft_acos` (musl acos.c branchless port,
# reusing `_asin_R(z)` from `fasin.jl` per CLAUDE.md §12; ≤2 ULP vs
# `Base.acos` across [-1, 1]). f32 forms rejected per CLAUDE.md §13
# (Bennett-3rph).

using Test
using Bennett

@testset "Bennett-bd7f: llvm.acos direct dispatch" begin

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_acos") === Bennett.soft_acos
    end

    @testset "llvm.acos.f64 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bd7f_acos_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="acos_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Sweep all four in-domain regimes: tiny / small / pos-large /
        # neg-large. Excludes |x| > 1 (Base.acos throws — no oracle).
        for x in (0.0, 1e-30, 0.1, 0.3, 0.49, 0.5, 0.7, 0.9, 0.97, 0.99, 1.0,
                  -0.5, -0.7, -0.97, -1.0)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = acos(xf)
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.acos.f64 special cases" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bd7f_acos_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="acos_f64")
        c = reversible_compile(parsed)
        # acos(±0) = π/2 bit-exact via tiny override (NOT sign-preserving).
        @test simulate(c, reinterpret(UInt64,  0.0)) == reinterpret(UInt64, Float64(π/2))
        @test simulate(c, reinterpret(UInt64, -0.0)) == reinterpret(UInt64, Float64(π/2))
        # acos(1) = 0 bit-exact; acos(-1) = π bit-exact.
        @test simulate(c, reinterpret(UInt64,  1.0)) == reinterpret(UInt64, 0.0)
        @test simulate(c, reinterpret(UInt64, -1.0)) == reinterpret(UInt64, Float64(π))
        # acos(NaN) = NaN; acos(±Inf) = NaN; acos(|x|>1) = NaN.
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, NaN))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64,  Inf))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, -Inf))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, 1.5))))
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, -2.0))))
    end

    @testset "llvm.acos.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bd7f_acos_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="acos_f32")
    end

end
