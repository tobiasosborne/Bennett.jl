# Bennett-ky5n: direct dispatch for `llvm.sinh.f64` AND libm `@sinh`
# as IRCall to `soft_sinh`. Tier C1.7 in Bennett-Enzyme-Parity-NorthStar.md.
#
# Two LLVM-ingest shapes covered:
#
# 1. `llvm.sinh.f64` — LLVM 18+ ships this unary intrinsic. clang/rustc
#    targeting modern LLVM emit it directly when math intrinsics are
#    enabled (-fno-math-errno, -O2+, etc.).
#
# 2. `@sinh(double)` (libm-style external call) — what older LLVMs
#    (≤17) emit, what `-fno-builtin-sinh` produces, and the canonical
#    shape for `-O0` C/Rust code.
#
# Both routes lower to the same IRCall(soft_sinh, [x]). f32 forms
# rejected per CLAUDE.md §13.
#
# Bennett-7goc trailing-`.` regression-guard: this test file also
# verifies that `llvm.sin.f64` still dispatches to soft_sin (not
# soft_sinh). The trailing `.` on `llvm.sin.` (Bennett-7goc fix)
# already prevents `startswith("llvm.sin.", "llvm.sinh.f64")` from
# matching (position 8 is `h`, not `.`); this regression test pins
# that defence-in-depth ordering by checking soft_sin produces sin
# values, not sinh values, for the existing 3mo fixture.

using Test
using Bennett

@testset "Bennett-ky5n: llvm.sinh direct dispatch" begin

    # Bennett-hybr: compile the llvm.sinh.f64 intrinsic fixture ONCE and share
    # the resulting circuit across the two testsets that exercise it.
    _sinh_intr_path = joinpath(@__DIR__, "fixtures", "ll", "ky5n_sinh_intrinsic.ll")
    _sinh_intr_parsed = Bennett.extract_parsed_ir_from_ll(_sinh_intr_path; entry_function="sinh_intr")
    _sinh_intr_c = reversible_compile(_sinh_intr_parsed)

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_sinh") === Bennett.soft_sinh
    end

    @testset "llvm.sinh.f64 via .ll ingest — three regimes" begin
        c = _sinh_intr_c
        @test verify_reversibility(c)
        # Polynomial regime + medium + huge (finite + overflow), both signs.
        for x in (0.0, 0.1, 0.5, 1.0, 1.5, -0.3, -3.0, 100.0, -100.0, 710.0, -710.0)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = sinh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.sinh.f64 special cases (bit-exact)" begin
        c = _sinh_intr_c
        # Sign-preserving zero (polynomial path, soft_fmul(±0, 1.0) = ±0).
        @test simulate(c, (reinterpret(UInt64,  0.0),)) == reinterpret(UInt64,  0.0)
        @test simulate(c, (reinterpret(UInt64, -0.0),)) == reinterpret(UInt64, -0.0)
        # ±Inf → ±Inf (huge path, (0.5·Inf)·Inf = Inf, OR with sign).
        @test simulate(c, (reinterpret(UInt64,  Inf),)) == reinterpret(UInt64,  Inf)
        @test simulate(c, (reinterpret(UInt64, -Inf),)) == reinterpret(UInt64, -Inf)
        # NaN propagation.
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN),))))
        # Subnormal-input passthrough (§13 contract via the polynomial
        # branch's x²→0, kernel(0)=1, x·1=x mechanism).
        let x = ldexp(1.0, -1024)   # tiny normal in the polynomial branch
            @test simulate(c, (reinterpret(UInt64,  x),)) == reinterpret(UInt64,  sinh( x))
            @test simulate(c, (reinterpret(UInt64, -x),)) == reinterpret(UInt64, sinh(-x))
        end
        # Overflow boundary at |x| ≈ 710.476 — bit-exact ±Inf.
        @test simulate(c, (reinterpret(UInt64,  1000.0),)) == reinterpret(UInt64,  Inf)
        @test simulate(c, (reinterpret(UInt64, -1000.0),)) == reinterpret(UInt64, -Inf)
    end

    @testset "libm @sinh via .ll ingest — generic accuracy" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ky5n_sinh_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="sinh_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 0.5, 1.0, -1.5, 2.0, 5.0, -100.0, 710.4)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = sinh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.sinh.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ky5n_sinh_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="sinh_f32")
    end

    @testset "libm @sinhf rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "ky5n_sinh_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="sinhf_libm")
    end

    @testset "regression: llvm.sin.f64 still dispatches to soft_sin" begin
        # The Bennett-7goc trailing-`.` discipline holds:
        # `startswith("llvm.sinh.f64", "llvm.sin.")` is false because
        # position 8 is `h`, not `.`. So the existing `llvm.sin.` arm
        # does NOT swallow sinh, and the new `llvm.sinh.` arm does NOT
        # swallow sin. A future drop of the trailing dot would route
        # `llvm.sin.f64` to soft_sinh — at which point this regression-
        # guard testset would mismatch (sin(1.0) ≈ 0.841 vs sinh(1.0)
        # ≈ 1.175 — clearly distinguishable).
        path = joinpath(@__DIR__, "fixtures", "ll", "3mo_sin_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="sin_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        x = 1.0
        got = reinterpret(Float64, UInt64(simulate(c, (reinterpret(UInt64, x),))))
        # Pin to sin, NOT sinh: sin(1.0) ≈ 0.841 vs sinh(1.0) ≈ 1.175.
        @test isapprox(got, sin(x); atol=1e-12)
        @test !isapprox(got, sinh(x); atol=1e-2)
    end

end
