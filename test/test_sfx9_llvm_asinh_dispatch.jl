# Bennett-sfx9: direct dispatch for `llvm.asinh.f64` and libm `@asinh`.
# Tier C1.9 in Bennett-Enzyme-Parity-NorthStar.md.

using Test
using Bennett

@testset "Bennett-sfx9: llvm.asinh direct dispatch" begin

    # Bennett-hybr: compile the llvm.asinh.f64 intrinsic fixture ONCE and share
    # the resulting circuit across the two testsets that exercise it.
    _asinh_intr_path = joinpath(@__DIR__, "fixtures", "ll", "sfx9_asinh_intrinsic.ll")
    _asinh_intr_parsed = Bennett.extract_parsed_ir_from_ll(_asinh_intr_path; entry_function="asinh_intr")
    _asinh_intr_c = reversible_compile(_asinh_intr_parsed)

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_asinh") === Bennett.soft_asinh
    end

    @testset "llvm.asinh.f64 via .ll ingest — three regimes" begin
        c = _asinh_intr_c
        @test verify_reversibility(c)
        for x in (0.0, 0.1, 0.5, 1.0, 2.0, -0.3, -3.0, 100.0, -100.0, 1e10)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = asinh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.asinh.f64 special cases (bit-exact)" begin
        c = _asinh_intr_c
        @test simulate(c, (reinterpret(UInt64,  0.0),)) == reinterpret(UInt64,  0.0)
        @test simulate(c, (reinterpret(UInt64, -0.0),)) == reinterpret(UInt64, -0.0)
        @test simulate(c, (reinterpret(UInt64,  Inf),)) == reinterpret(UInt64,  Inf)
        @test simulate(c, (reinterpret(UInt64, -Inf),)) == reinterpret(UInt64, -Inf)
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN),))))
        # Subnormal-input bit-exactness via polynomial branch.
        let x = ldexp(1.0, -1024)
            @test simulate(c, (reinterpret(UInt64,  x),)) == reinterpret(UInt64,  asinh( x))
            @test simulate(c, (reinterpret(UInt64, -x),)) == reinterpret(UInt64, asinh(-x))
        end
    end

    @testset "libm @asinh via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "sfx9_asinh_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="asinh_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 0.5, 1.0, -1.5, 5.0, -100.0)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = asinh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.asinh.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "sfx9_asinh_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="asinh_f32")
    end

    @testset "libm @asinhf rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "sfx9_asinh_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="asinhf_libm")
    end

    @testset "regression: llvm.asin.f64 still dispatches to soft_asin" begin
        # Bennett-7goc trailing-`.` discipline.
        path = joinpath(@__DIR__, "fixtures", "ll", "ckvj_asin_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="asin_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        x = 0.5
        got = reinterpret(Float64, UInt64(simulate(c, (reinterpret(UInt64, x),))))
        # asin(0.5) ≈ 0.524 vs asinh(0.5) ≈ 0.481 — distinguishable.
        @test isapprox(got, asin(x); atol=1e-12)
        @test !isapprox(got, asinh(x); atol=1e-2)
    end

end
