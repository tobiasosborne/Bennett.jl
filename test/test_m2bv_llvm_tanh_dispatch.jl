# Bennett-m2bv: direct dispatch for `llvm.tanh.f64` AND libm `@tanh`
# as IRCall to `soft_tanh`. Tier C1.6 in Bennett-Enzyme-Parity-NorthStar.md.
#
# Two LLVM-ingest shapes covered (both arise in raw .ll/.bc ingest):
#
# 1. `llvm.tanh.f64` — LLVM 18+ ships this unary intrinsic. clang/rustc
#    targeting modern LLVM emit it directly when math intrinsics are
#    enabled (-fno-math-errno, -O2+, etc.).
#
# 2. `@tanh(double)` (libm-style external call) — what older LLVMs
#    (≤17) emit, what `-fno-builtin-tanh` produces, and the canonical
#    shape for `-O0` C/Rust code.
#
# Both routes lower to the same IRCall(soft_tanh, [x]). f32 forms
# rejected per CLAUDE.md §13.
#
# Bennett-7goc trailing-`.` regression-guard: this test file also
# verifies that `llvm.tan.f64` still dispatches to soft_tan (not
# soft_tanh) — a future drop of the trailing `.` on the tan arm would
# silently break tan inputs by routing them to tanh, and this test
# would catch it.

using Test
using Bennett

@testset "Bennett-m2bv: llvm.tanh direct dispatch" begin

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_tanh") === Bennett.soft_tanh
    end

    @testset "llvm.tanh.f64 via .ll ingest — three regimes" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "m2bv_tanh_intrinsic.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="tanh_intr")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Polynomial regime + exp-formula + saturate, both signs.
        for x in (0.0, 0.1, 0.5, 1.0, 2.0, -0.3, -1.5, 22.5, -22.5, 100.0)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = tanh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.tanh.f64 special cases (bit-exact)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "m2bv_tanh_intrinsic.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="tanh_intr")
        c = reversible_compile(parsed)
        # Sign-preserving zero.
        @test simulate(c, (reinterpret(UInt64,  0.0),)) == reinterpret(UInt64,  0.0)
        @test simulate(c, (reinterpret(UInt64, -0.0),)) == reinterpret(UInt64, -0.0)
        # Saturation at infinity.
        @test simulate(c, (reinterpret(UInt64,  Inf),)) == reinterpret(UInt64,  1.0)
        @test simulate(c, (reinterpret(UInt64, -Inf),)) == reinterpret(UInt64, -1.0)
        # NaN propagation.
        @test isnan(reinterpret(Float64, simulate(c, (reinterpret(UInt64, NaN),))))
        # Subnormal-input passthrough (§13 contract — picks up via the
        # polynomial branch's x²→0, P(0)=1, x·1=x mechanism).
        let x = ldexp(1.0, -1024)   # smallest-binade subnormal
            @test simulate(c, (reinterpret(UInt64,  x),)) == reinterpret(UInt64,  tanh( x))
            @test simulate(c, (reinterpret(UInt64, -x),)) == reinterpret(UInt64, tanh(-x))
        end
    end

    @testset "libm @tanh via .ll ingest — generic accuracy" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "m2bv_tanh_libm.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="tanh_libm")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 0.5, 1.0, -1.5, 22.5, -100.0)
            xu = reinterpret(UInt64, x)
            got = simulate(c, (xu,))
            actual = reinterpret(Float64, UInt64(got))
            expected = tanh(x)
            ulp = let
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.tanh.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "m2bv_tanh_intrinsic_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="tanh_f32")
    end

    @testset "libm @tanhf rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "m2bv_tanh_libm_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="tanhf_libm")
    end

    @testset "regression: llvm.tan.f64 still dispatches to soft_tan" begin
        # Confirms the Bennett-7goc trailing-`.` discipline holds:
        # `startswith("llvm.tanh.f64", "llvm.tan.")` is false because
        # position-9 is `h`, not `.`. So the existing `llvm.tan.` arm
        # does NOT swallow tanh, and the new `llvm.tanh.` arm does NOT
        # swallow tan. A future drop of the trailing dot on the tan arm
        # would route `llvm.tanh.f64` to soft_tan instead — at which
        # point this regression-guard testset would mismatch (tanh(1.0)
        # ≈ 0.762 vs tan(1.0) ≈ 1.557).
        path = joinpath(@__DIR__, "fixtures", "ll", "s1zl_tan_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="tan_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        x = 1.0
        got = reinterpret(Float64, UInt64(simulate(c, (reinterpret(UInt64, x),))))
        # Pin to tan, not tanh: tan(1.0) ≈ 1.557; tanh(1.0) ≈ 0.762.
        @test isapprox(got, tan(x); atol=1e-12)
        @test !isapprox(got, tanh(x); atol=1e-3)
    end

end
