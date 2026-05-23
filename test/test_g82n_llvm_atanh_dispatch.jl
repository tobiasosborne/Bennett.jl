# Bennett-g82n: direct dispatch for `llvm.atanh.f64` and libm `@atanh`.
# Tier C1.11 — FINAL hyperbolic close, completes Tier C1 11/11.

using Test
using Bennett

@testset "Bennett-g82n: llvm.atanh direct dispatch" begin

    # Bennett-hybr: compile the llvm.atanh.f64 intrinsic fixture ONCE and share
    # the resulting circuit across the two testsets that exercise it.
    _atanh_intr_path = joinpath(@__DIR__, "fixtures", "ll", "g82n_atanh_intrinsic.ll")
    _atanh_intr_parsed = Bennett.extract_parsed_ir_from_ll(_atanh_intr_path; entry_function="atanh_intr")
    _atanh_intr_c = reversible_compile(_atanh_intr_parsed)

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_atanh") === Bennett.soft_atanh
    end

    @testset "llvm.atanh.f64 via .ll ingest — two regimes + ±1 boundary" begin
        c = _atanh_intr_c
        @test verify_reversibility(c)
        for x in (0.0, 0.1, 0.3, 0.5, 0.7, 0.9, -0.3, -0.7, 0.99, 0.999)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = atanh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.atanh.f64 special cases (bit-exact)" begin
        c = _atanh_intr_c
        @test simulate(c, (reinterpret(UInt64,  0.0),)) == reinterpret(UInt64,  0.0)
        @test simulate(c, (reinterpret(UInt64, -0.0),)) == reinterpret(UInt64, -0.0)
        @test simulate(c, (reinterpret(UInt64,  1.0),)) == reinterpret(UInt64,  Inf)
        @test simulate(c, (reinterpret(UInt64, -1.0),)) == reinterpret(UInt64, -Inf)
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN),))))
        # Domain: |x| > 1 → NaN.
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64,  1.5),))))
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, -2.0),))))
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64,  Inf),))))
        # Subnormal-input bit-exactness via polynomial branch.
        let x = ldexp(1.0, -1024)
            @test simulate(c, (reinterpret(UInt64,  x),)) == reinterpret(UInt64,  atanh( x))
            @test simulate(c, (reinterpret(UInt64, -x),)) == reinterpret(UInt64, atanh(-x))
        end
    end

    @testset "libm @atanh via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "g82n_atanh_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="atanh_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 0.5, 0.9, -0.5, -0.9)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = atanh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.atanh.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "g82n_atanh_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="atanh_f32")
    end

    @testset "libm @atanhf rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "g82n_atanh_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="atanhf_libm")
    end

    @testset "regression: llvm.atan.f64 still dispatches to soft_atan" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "qpke_atan_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="atan_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        x = 0.5
        got = reinterpret(Float64, UInt64(simulate(c, (reinterpret(UInt64, x),))))
        # atan(0.5) ≈ 0.464, atanh(0.5) ≈ 0.549 — distinguishable.
        @test isapprox(got, atan(x); atol=1e-12)
        @test !isapprox(got, atanh(x); atol=1e-2)
    end

end
