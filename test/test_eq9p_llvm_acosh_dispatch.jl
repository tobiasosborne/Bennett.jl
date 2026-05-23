# Bennett-eq9p: direct dispatch for `llvm.acosh.f64` and libm `@acosh`.
# Tier C1.10 in Bennett-Enzyme-Parity-NorthStar.md.

using Test
using Bennett

@testset "Bennett-eq9p: llvm.acosh direct dispatch" begin

    # Bennett-hybr: compile the llvm.acosh.f64 intrinsic fixture ONCE and share
    # the resulting circuit across the two testsets that exercise it. The
    # previous structure compiled the same 2.4M-gate circuit twice back-to-back
    # with zero reuse. verify_reversibility is an invariant check (deterministic)
    # so a single call suffices for both testsets.
    _acosh_intr_path = joinpath(@__DIR__, "fixtures", "ll", "eq9p_acosh_intrinsic.ll")
    _acosh_intr_parsed = Bennett.extract_parsed_ir_from_ll(_acosh_intr_path; entry_function="acosh_intr")
    _acosh_intr_c = reversible_compile(_acosh_intr_parsed)

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_acosh") === Bennett.soft_acosh
    end

    @testset "llvm.acosh.f64 via .ll ingest — three regimes" begin
        c = _acosh_intr_c
        @test verify_reversibility(c)
        for x in (1.0, 1.05, 1.2, 1.5, 2.0, 5.0, 100.0, 1e10)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = acosh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.acosh.f64 special cases (bit-exact)" begin
        c = _acosh_intr_c
        @test simulate(c, (reinterpret(UInt64, 1.0),)) == reinterpret(UInt64, 0.0)
        @test simulate(c, (reinterpret(UInt64, Inf),)) == reinterpret(UInt64, Inf)
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN),))))
        # Domain: x < 1 → NaN.
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64,  0.5),))))
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, -1.0),))))
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, -Inf),))))
    end

    @testset "libm @acosh via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "eq9p_acosh_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="acosh_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (1.0, 1.5, 2.0, 5.0, 100.0)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = acosh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                d = ab >= eb ? ab - eb : eb - ab
                Int64(d > UInt64(1<<62) ? Int64(1<<62) : d)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.acosh.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "eq9p_acosh_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="acosh_f32")
    end

    @testset "libm @acoshf rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "eq9p_acosh_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="acoshf_libm")
    end

    @testset "regression: llvm.acos.f64 still dispatches to soft_acos" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "bd7f_acos_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="acos_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        x = 0.5
        got = reinterpret(Float64, UInt64(simulate(c, (reinterpret(UInt64, x),))))
        # acos(0.5) ≈ 1.047, acosh(0.5) is NaN; check we get acos.
        @test isapprox(got, acos(x); atol=1e-12)
        @test !isnan(got)
    end

end
