# Bennett-0ulc: direct dispatch for `llvm.log1p.f64` and libm `@log1p`.
# Tier C2.1 — first C2 transcendental close.

using Test
using Bennett

@testset "Bennett-0ulc: llvm.log1p direct dispatch" begin

    # Bennett-hybr: compile the llvm.log1p.f64 intrinsic fixture ONCE and share
    # the resulting circuit across the two testsets that exercise it.
    _log1p_intr_path = joinpath(@__DIR__, "fixtures", "ll", "0ulc_log1p_intrinsic.ll")
    _log1p_intr_parsed = Bennett.extract_parsed_ir_from_ll(_log1p_intr_path; entry_function="log1p_intr")
    _log1p_intr_c = reversible_compile(_log1p_intr_parsed)

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_log1p") === Bennett.soft_log1p
    end

    @testset "llvm.log1p.f64 via .ll ingest — both regimes" begin
        c = _log1p_intr_c
        @test verify_reversibility(c)
        for x in (0.0, 1e-100, 0.001, 0.1, 0.5, 1.0, 10.0, -0.001, -0.1, -0.5, -0.99)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = log1p(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.log1p.f64 special cases (bit-exact)" begin
        c = _log1p_intr_c
        @test simulate(c, (reinterpret(UInt64,  0.0),)) == reinterpret(UInt64,  0.0)
        @test simulate(c, (reinterpret(UInt64, -0.0),)) == reinterpret(UInt64, -0.0)
        @test simulate(c, (reinterpret(UInt64, -1.0),)) == reinterpret(UInt64, -Inf)
        @test simulate(c, (reinterpret(UInt64,  Inf),)) == reinterpret(UInt64,  Inf)
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN),))))
        # Domain: x < -1 → NaN.
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, -2.0),))))
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, -Inf),))))
        # Subnormal-input bit-exactness via tiny regime.
        let x = ldexp(1.0, -1024)
            @test simulate(c, (reinterpret(UInt64,  x),)) == reinterpret(UInt64,  x)
            @test simulate(c, (reinterpret(UInt64, -x),)) == reinterpret(UInt64, -x)
        end
    end

    @testset "libm @log1p via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "0ulc_log1p_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="log1p_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 0.5, 1.0, 10.0, -0.5, -0.99)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = log1p(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.log1p.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "0ulc_log1p_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="log1p_f32")
    end

    @testset "libm @log1pf rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "0ulc_log1p_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="log1pf_libm")
    end

    @testset "regression: llvm.log.f64 still dispatches to soft_log" begin
        # Bennett-7goc trailing-`.` discipline.
        path = joinpath(@__DIR__, "fixtures", "ll", "582_log_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="log_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        x = 2.0
        got = reinterpret(Float64, UInt64(simulate(c, (reinterpret(UInt64, x),))))
        # log(2.0) ≈ 0.693, log1p(2.0) ≈ 1.099 — distinguishable.
        @test isapprox(got, log(x); atol=1e-12)
        @test !isapprox(got, log1p(x); atol=1e-2)
    end

end
