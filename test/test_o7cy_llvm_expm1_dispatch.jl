# Bennett-o7cy: direct dispatch for `llvm.expm1.f64` and libm `@expm1`.
# Tier C2.2.

using Test
using Bennett

@testset "Bennett-o7cy: llvm.expm1 direct dispatch" begin

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_expm1") === Bennett.soft_expm1
    end

    @testset "llvm.expm1.f64 via .ll ingest — three regimes" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "o7cy_expm1_intrinsic.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="expm1_intr")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 1e-100, 0.001, 0.1, 0.5, 1.0, 5.0, 100.0, -0.5, -1.0, -50.0, -1000.0, 700.0)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = expm1(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.expm1.f64 special cases (bit-exact)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "o7cy_expm1_intrinsic.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="expm1_intr")
        c = reversible_compile(parsed)
        @test simulate(c, (reinterpret(UInt64,  0.0),)) == reinterpret(UInt64,  0.0)
        @test simulate(c, (reinterpret(UInt64, -0.0),)) == reinterpret(UInt64, -0.0)
        @test simulate(c, (reinterpret(UInt64,  Inf),)) == reinterpret(UInt64,  Inf)
        @test simulate(c, (reinterpret(UInt64, -Inf),)) == reinterpret(UInt64, -1.0)
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN),))))
        # Subnormal-input bit-exactness via tiny regime.
        let x = ldexp(1.0, -1024)
            @test simulate(c, (reinterpret(UInt64,  x),)) == reinterpret(UInt64,  x)
            @test simulate(c, (reinterpret(UInt64, -x),)) == reinterpret(UInt64, -x)
        end
        # Large negative → -1.
        @test simulate(c, (reinterpret(UInt64, -1000.0),)) == reinterpret(UInt64, -1.0)
        # Large positive → +Inf.
        @test simulate(c, (reinterpret(UInt64, 1e10),)) == reinterpret(UInt64, Inf)
    end

    @testset "libm @expm1 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "o7cy_expm1_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="expm1_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 0.5, 1.0, 5.0, -0.5, -5.0)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = expm1(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.expm1.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "o7cy_expm1_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="expm1_f32")
    end

    @testset "libm @expm1f rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "o7cy_expm1_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="expm1f_libm")
    end

    @testset "regression: llvm.exp.f64 still dispatches to soft_exp" begin
        # Bennett-7goc / 0ulc trailing-`.` discipline.
        path = joinpath(@__DIR__, "fixtures", "ll", "1pb_exp_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="exp_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        x = 1.0
        got = reinterpret(Float64, UInt64(simulate(c, (reinterpret(UInt64, x),))))
        # exp(1) ≈ 2.718, expm1(1) ≈ 1.718 — distinguishable.
        @test isapprox(got, exp(x); atol=1e-12)
        @test !isapprox(got, expm1(x); atol=1e-2)
    end

end
