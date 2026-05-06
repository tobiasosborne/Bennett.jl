# Bennett-bybh: direct dispatch for `llvm.cosh.f64` AND libm `@cosh`
# as IRCall to `soft_cosh`. Tier C1.8 in Bennett-Enzyme-Parity-NorthStar.md.
#
# Mirrors Bennett-ky5n (sinh) test pattern. cosh-specific differences:
# - cosh is EVEN — `cosh(-Inf) = +Inf` (not -Inf), `cosh(±0) = 1.0`.
# - Subnormal input → 1.0 exactly (via the polynomial branch's
#   kernel(0) = 1.0 constant term).
#
# Bennett-7goc trailing-`.` regression-guard: verifies that
# `llvm.cos.f64` still dispatches to soft_cos (not soft_cosh).

using Test
using Bennett

@testset "Bennett-bybh: llvm.cosh direct dispatch" begin

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_cosh") === Bennett.soft_cosh
    end

    @testset "llvm.cosh.f64 via .ll ingest — three regimes" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bybh_cosh_intrinsic.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="cosh_intr")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 0.1, 0.5, 1.0, 1.5, -0.3, -3.0, 100.0, -100.0, 710.0, -710.0)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = cosh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.cosh.f64 special cases (bit-exact)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bybh_cosh_intrinsic.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="cosh_intr")
        c = reversible_compile(parsed)
        # ±0 → 1.0 (NOT ±0 — cosh discards sign).
        @test simulate(c, (reinterpret(UInt64,  0.0),)) == reinterpret(UInt64, 1.0)
        @test simulate(c, (reinterpret(UInt64, -0.0),)) == reinterpret(UInt64, 1.0)
        # ±Inf → +Inf (even function).
        @test simulate(c, (reinterpret(UInt64,  Inf),)) == reinterpret(UInt64, Inf)
        @test simulate(c, (reinterpret(UInt64, -Inf),)) == reinterpret(UInt64, Inf)
        # NaN propagation.
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN),))))
        # Subnormal input → 1.0 (since 1 + subnormal² rounds to 1.0).
        let x = ldexp(1.0, -1024)
            @test simulate(c, (reinterpret(UInt64,  x),)) == reinterpret(UInt64, 1.0)
            @test simulate(c, (reinterpret(UInt64, -x),)) == reinterpret(UInt64, 1.0)
        end
        # Far overflow.
        @test simulate(c, (reinterpret(UInt64,  1000.0),)) == reinterpret(UInt64, Inf)
        @test simulate(c, (reinterpret(UInt64, -1000.0),)) == reinterpret(UInt64, Inf)
    end

    @testset "libm @cosh via .ll ingest — generic accuracy" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bybh_cosh_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="cosh_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 0.5, 1.0, -1.5, 2.0, 5.0, -100.0, 710.4)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = cosh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.cosh.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bybh_cosh_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="cosh_f32")
    end

    @testset "libm @coshf rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bybh_cosh_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="coshf_libm")
    end

    @testset "regression: llvm.cos.f64 still dispatches to soft_cos" begin
        # The Bennett-7goc trailing-`.` discipline holds:
        # `startswith("llvm.cosh.f64", "llvm.cos.")` is false because
        # position 8 is `h`, not `.`. Defence-in-depth.
        path = joinpath(@__DIR__, "fixtures", "ll", "3mo_cos_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="cos_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        x = 1.0
        got = reinterpret(Float64, UInt64(simulate(c, (reinterpret(UInt64, x),))))
        # Pin to cos, NOT cosh: cos(1.0) ≈ 0.540 vs cosh(1.0) ≈ 1.543.
        @test isapprox(got, cos(x); atol=1e-12)
        @test !isapprox(got, cosh(x); atol=1e-2)
    end

end
