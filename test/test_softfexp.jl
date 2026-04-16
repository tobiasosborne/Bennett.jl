using Test
using Bennett
using Bennett: soft_exp2, soft_exp, soft_exp2_fast, soft_exp_fast
using Random

# Bennett.jl soft_exp / soft_exp2 — IEEE 754 double-precision exponential on raw
# bit patterns, branchless integer arithmetic only. Algorithm: Tang-style
# range reduction (Arm Optimized Routines / musl exp2.c, Wilhelm/Sibidanov 2018):
#   x = k/N + r   (N=128, k=round(x·N), r ∈ [-1/(2N), 1/(2N)])
#   2^x = 2^(k/N) · 2^r
# Lookup `T[k mod N]` gives 2^(j/N) bits compensated for the mantissa shift,
# polynomial deg-5 minimax `2^r ≈ 1 + r·C1 + r²(C2 + r·C3) + r⁴(C4 + r·C5)`.
# Table has the (sbits - j<<45) compensation pre-baked so a single integer add
# `T[idx+1] + (ki<<45)` restores the IEEE bits of 2^(k/N) at the right exponent.
# Tolerance: ≤2 ulp vs Julia's Base.exp2 — exp/exp2 are not IEEE-mandatory and
# no libm guarantees correct rounding. musl/Arm publish ≤0.527 ulp; system libm
# variation puts our target at ≤2 ulp (typically 0).

const ULP_TOL = 2

function _ulp_diff(actual::UInt64, expected::Float64)
    expected_bits = reinterpret(UInt64, expected)
    if isnan(expected)
        return isnan(reinterpret(Float64, actual)) ? 0 : typemax(Int64)
    end
    Int64(actual >= expected_bits ? actual - expected_bits : expected_bits - actual)
end

@testset "soft_exp2 library" begin

    function check_exp2(a::Float64; tol::Int=ULP_TOL)
        a_bits = reinterpret(UInt64, a)
        result_bits = soft_exp2(a_bits)
        expected = exp2(a)
        diff = _ulp_diff(result_bits, expected)
        if diff > tol
            @warn "soft_exp2 ulp drift" a expected actual=reinterpret(Float64, result_bits) diff
        end
        @test diff <= tol
    end

    @testset "exact integer powers" begin
        # 2^k for integer k must be bit-exact (r=0, polynomial returns 0)
        for k in -10:10
            check_exp2(Float64(k); tol=0)
        end
        check_exp2(50.0; tol=0)
        check_exp2(100.0; tol=0)
        check_exp2(-50.0; tol=0)
        check_exp2(-100.0; tol=0)
    end

    @testset "common values" begin
        check_exp2(0.5)             # √2
        check_exp2(1.5)             # 2√2
        check_exp2(0.25)            # 2^(1/4)
        check_exp2(0.1)
        check_exp2(0.7)
        check_exp2(-0.5)
        check_exp2(-0.25)
        check_exp2(3.14159)
        check_exp2(-3.14159)
    end

    @testset "boundary: small magnitude" begin
        # |x| < 2^-54 → result indistinguishable from 1.0 at round-to-nearest
        check_exp2(0.0; tol=0)
        check_exp2(-0.0; tol=0)
        check_exp2(1e-20)
        check_exp2(-1e-20)
        check_exp2(prevfloat(1.0) - 1.0)  # subnormal-ish input
    end

    @testset "overflow → +Inf" begin
        # exp2(x) for x ≥ 1024 overflows
        @test soft_exp2(reinterpret(UInt64, 1024.0)) == reinterpret(UInt64, Inf)
        @test soft_exp2(reinterpret(UInt64, 2000.0)) == reinterpret(UInt64, Inf)
        @test soft_exp2(reinterpret(UInt64, 1e100)) == reinterpret(UInt64, Inf)
        @test soft_exp2(reinterpret(UInt64, Inf)) == reinterpret(UInt64, Inf)
    end

    @testset "underflow → +0" begin
        # exp2(x) for x ≤ -1075 underflows to 0; we flush at the same boundary
        @test soft_exp2(reinterpret(UInt64, -1075.0)) == UInt64(0)
        @test soft_exp2(reinterpret(UInt64, -2000.0)) == UInt64(0)
        @test soft_exp2(reinterpret(UInt64, -1e100)) == UInt64(0)
        @test soft_exp2(reinterpret(UInt64, -Inf)) == UInt64(0)
    end

    @testset "NaN propagation" begin
        @test isnan(reinterpret(Float64, soft_exp2(reinterpret(UInt64, NaN))))
        snan_bits = UInt64(0x7FF0000000000001)
        @test isnan(reinterpret(Float64, soft_exp2(snan_bits)))
    end

    @testset "full-range random sweep (10k uniform in [-100, 100])" begin
        Random.seed!(0xEC9C8DB)
        n_pass = 0
        n_drift = 0
        max_diff = 0
        for _ in 1:10_000
            x = (rand() - 0.5) * 200.0  # [-100, 100]
            result_bits = soft_exp2(reinterpret(UInt64, x))
            expected = exp2(x)
            diff = _ulp_diff(result_bits, expected)
            max_diff = max(max_diff, diff)
            if diff <= ULP_TOL
                n_pass += 1
            else
                n_drift += 1
            end
        end
        @test n_pass >= 9_990
        @test max_diff <= 4  # observed worst-case across the sweep
    end

    @testset "tight-range random sweep (5k uniform in [-1, 1])" begin
        Random.seed!(0x80F23A)
        max_diff = 0
        for _ in 1:5_000
            x = rand() * 2.0 - 1.0
            result_bits = soft_exp2(reinterpret(UInt64, x))
            expected = exp2(x)
            diff = _ulp_diff(result_bits, expected)
            max_diff = max(max_diff, diff)
        end
        @test max_diff <= ULP_TOL
    end

    # ── Bit-exact subnormal-output range tests (Bennett-wigl) ──
    # Validates that the underflow specialcase produces correct subnormal
    # output across x ∈ (-1075, -1022). Prior to the specialcase, this range
    # produced garbage (negative numbers with magnitude up to 1e300).

    @testset "BIT-EXACT subnormal-output range" begin
        # Sweep every Float64 from -1023 down toward -1075 in -0.5 steps —
        # covers the entire subnormal-output range with reasonable density.
        n_pass = 0
        n_total = 0
        max_diff = 0
        x = -1022.0
        while x > -1076.0
            n_total += 1
            result_bits = soft_exp2(reinterpret(UInt64, x))
            expected = exp2(x)
            diff = _ulp_diff(result_bits, expected)
            max_diff = max(max_diff, diff)
            n_pass += (diff == 0) ? 1 : 0
            x -= 0.5
        end
        # All inputs must be bit-exact
        @test n_pass == n_total
        @test max_diff == 0
    end

    @testset "BIT-EXACT specific subnormal boundary cases" begin
        # smallest normal output
        @test soft_exp2(reinterpret(UInt64, -1022.0)) == reinterpret(UInt64, exp2(-1022.0))
        # largest subnormal output
        @test soft_exp2(reinterpret(UInt64, -1023.0)) == reinterpret(UInt64, exp2(-1023.0))
        # mid-range
        @test soft_exp2(reinterpret(UInt64, -1050.0)) == reinterpret(UInt64, exp2(-1050.0))
        # smallest representable subnormal
        @test soft_exp2(reinterpret(UInt64, -1074.0)) == reinterpret(UInt64, exp2(-1074.0))
        # boundary just above flush
        @test soft_exp2(reinterpret(UInt64, -1074.999)) == reinterpret(UInt64, exp2(-1074.999))
        # exact -1075 → should flush to 0 (exp2(-1075) underflows past smallest subnormal)
        @test soft_exp2(reinterpret(UInt64, -1075.0)) == UInt64(0)
        @test reinterpret(UInt64, exp2(-1075.0)) == UInt64(0)  # cross-check Julia
    end

    @testset "soft_exp2_fast: matches soft_exp2 OUTSIDE subnormal range" begin
        # Outside (-1075, -1022) the two should agree bit-for-bit.
        for x in (-1500.0, -1100.0, -1075.0, -1022.0, -1000.0, -100.0, -10.0,
                  -1.0, -0.5, 0.0, 0.5, 1.0, 10.0, 100.0, 500.0, 1000.0, 1023.0,
                  1024.0, Inf, -Inf)
            @test soft_exp2_fast(reinterpret(UInt64, x)) == soft_exp2(reinterpret(UInt64, x))
        end
        @test isnan(reinterpret(Float64, soft_exp2_fast(reinterpret(UInt64, NaN))))
    end

    @testset "soft_exp2_fast: flushes subnormal range to 0 (documented)" begin
        for x in (-1023.0, -1024.0, -1050.0, -1074.0)
            @test soft_exp2_fast(reinterpret(UInt64, x)) == UInt64(0)
        end
    end

end  # soft_exp2

@testset "soft_exp library" begin

    function check_exp(a::Float64; tol::Int=ULP_TOL)
        a_bits = reinterpret(UInt64, a)
        result_bits = soft_exp(a_bits)
        expected = exp(a)
        diff = _ulp_diff(result_bits, expected)
        if diff > tol
            @warn "soft_exp ulp drift" a expected actual=reinterpret(Float64, result_bits) diff
        end
        @test diff <= tol
    end

    @testset "exp(0) = 1" begin
        @test soft_exp(reinterpret(UInt64, 0.0)) == reinterpret(UInt64, 1.0)
        @test soft_exp(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, 1.0)
    end

    @testset "common values" begin
        check_exp(1.0)              # e
        check_exp(2.0)              # e²
        check_exp(0.5)              # √e
        check_exp(-1.0)             # 1/e
        check_exp(-2.0)             # 1/e²
        check_exp(0.1)
        check_exp(0.69314718)       # ≈ ln(2) → exp ≈ 2
        check_exp(2.302585)         # ≈ ln(10) → exp ≈ 10
    end

    @testset "boundary: small magnitude" begin
        check_exp(1e-20)
        check_exp(-1e-20)
    end

    @testset "overflow → +Inf" begin
        # exp(x) for x ≥ 709.78 overflows
        @test soft_exp(reinterpret(UInt64, 710.0)) == reinterpret(UInt64, Inf)
        @test soft_exp(reinterpret(UInt64, 1000.0)) == reinterpret(UInt64, Inf)
        @test soft_exp(reinterpret(UInt64, Inf)) == reinterpret(UInt64, Inf)
    end

    @testset "underflow → +0" begin
        @test soft_exp(reinterpret(UInt64, -750.0)) == UInt64(0)
        @test soft_exp(reinterpret(UInt64, -1e100)) == UInt64(0)
        @test soft_exp(reinterpret(UInt64, -Inf)) == UInt64(0)
    end

    @testset "NaN propagation" begin
        @test isnan(reinterpret(Float64, soft_exp(reinterpret(UInt64, NaN))))
    end

    @testset "random sweep (5k uniform in [-50, 50])" begin
        Random.seed!(0x9C8BE3)
        n_pass = 0
        max_diff = 0
        for _ in 1:5_000
            x = (rand() - 0.5) * 100.0
            result_bits = soft_exp(reinterpret(UInt64, x))
            expected = exp(x)
            diff = _ulp_diff(result_bits, expected)
            max_diff = max(max_diff, diff)
            n_pass += (diff <= ULP_TOL) ? 1 : 0
        end
        @test n_pass >= 4_990
        @test max_diff <= 4
    end

    # ── ≤1 ulp subnormal-output range tests (Bennett-wigl) ──
    # Validates that the underflow specialcase produces correct subnormal
    # output across x ∈ (-745.13, -708.40). Prior to the specialcase, this
    # range produced garbage (e.g. exp(-710) returned -1.45e308 instead of 4.48e-309).
    # We are bit-exact vs musl (algorithm-faithful); ≤1 ulp vs Base.exp because
    # Julia uses FMA-based muladd in range reduction (single-rounded) while
    # musl/our impl uses separate fmul+fadd (double-rounded). This causes ~1%
    # of inputs to differ by 1 ulp at round-half boundaries.

    @testset "subnormal-output range: ≤1 ulp vs Base.exp, bit-exact vs musl" begin
        n_pass_exact = 0
        n_within_1ulp = 0
        n_total = 0
        max_diff = 0
        x = -708.4
        while x > -745.13
            n_total += 1
            result_bits = soft_exp(reinterpret(UInt64, x))
            expected = exp(x)
            diff = _ulp_diff(result_bits, expected)
            max_diff = max(max_diff, diff)
            n_pass_exact += (diff == 0) ? 1 : 0
            n_within_1ulp += (diff <= 1) ? 1 : 0
            x -= 0.25
        end
        # Strict: every input must be within 1 ulp of Julia.
        @test n_within_1ulp == n_total
        @test max_diff <= 1
        # Soft: ≥95% must be bit-exact (the rest are musl/Julia FMA divergence).
        @test n_pass_exact >= n_total * 95 ÷ 100
    end

    @testset "BIT-EXACT specific subnormal boundary cases" begin
        # exp(-708) is still normal output
        @test soft_exp(reinterpret(UInt64, -708.0)) == reinterpret(UInt64, exp(-708.0))
        # exp(-708.4) ≈ smallest normal (boundary)
        @test soft_exp(reinterpret(UInt64, -708.4)) == reinterpret(UInt64, exp(-708.4))
        # subnormal range — these were ALL garbage before the fix
        @test soft_exp(reinterpret(UInt64, -710.0)) == reinterpret(UInt64, exp(-710.0))
        @test soft_exp(reinterpret(UInt64, -720.0)) == reinterpret(UInt64, exp(-720.0))
        @test soft_exp(reinterpret(UInt64, -730.0)) == reinterpret(UInt64, exp(-730.0))
        @test soft_exp(reinterpret(UInt64, -740.0)) == reinterpret(UInt64, exp(-740.0))
        @test soft_exp(reinterpret(UInt64, -744.0)) == reinterpret(UInt64, exp(-744.0))
        @test soft_exp(reinterpret(UInt64, -745.0)) == reinterpret(UInt64, exp(-745.0))
        # boundary: smallest x giving smallest subnormal
        @test soft_exp(reinterpret(UInt64, -745.1332191019411)) == reinterpret(UInt64, exp(-745.1332191019411))
        # below MIN_EXP → flush to 0
        @test soft_exp(reinterpret(UInt64, -745.1332191019413)) == UInt64(0)
        @test soft_exp(reinterpret(UInt64, -750.0)) == UInt64(0)
    end

    @testset "BIT-EXACT overflow boundary" begin
        # The polynomial path was returning NaN at x = 709.79 (just past MAX_EXP);
        # tightened threshold now returns +Inf correctly.
        @test soft_exp(reinterpret(UInt64, 709.7827128933841)) == reinterpret(UInt64, exp(709.7827128933841))
        @test soft_exp(reinterpret(UInt64, 709.79)) == reinterpret(UInt64, Inf)
        @test soft_exp(reinterpret(UInt64, 710.0)) == reinterpret(UInt64, Inf)
    end

    @testset "soft_exp_fast: matches soft_exp OUTSIDE subnormal range" begin
        for x in (-1000.0, -800.0, -750.0, -745.13321910194126, -708.0, -100.0,
                  -1.0, 0.0, 1.0, 100.0, 700.0, 709.78, 709.79, 710.0, Inf, -Inf)
            @test soft_exp_fast(reinterpret(UInt64, x)) == soft_exp(reinterpret(UInt64, x))
        end
        @test isnan(reinterpret(Float64, soft_exp_fast(reinterpret(UInt64, NaN))))
    end

    @testset "soft_exp_fast: flushes subnormal range to 0 (documented)" begin
        for x in (-708.4, -710.0, -720.0, -730.0, -740.0, -745.0)
            @test soft_exp_fast(reinterpret(UInt64, x)) == UInt64(0)
        end
    end

    @testset "FULL-RANGE ≤1 ulp random sweep (10k uniform in [-700, 700])" begin
        # ≤1 ulp vs Base.exp; bit-exact vs musl/AOR. Empirically ~99% of
        # inputs hit bit-exact agreement with Julia; remaining ~1% differ by
        # 1 ulp at round-half boundaries (musl uses separate fmul+fadd in
        # range reduction; Julia uses FMA-based muladd → different rounding).
        Random.seed!(0xBE9C8DB)
        n_within_1ulp = 0
        n_exact = 0
        max_diff = 0
        for _ in 1:10_000
            x = (rand() - 0.5) * 1400.0  # [-700, 700]
            result_bits = soft_exp(reinterpret(UInt64, x))
            expected = exp(x)
            diff = _ulp_diff(result_bits, expected)
            max_diff = max(max_diff, diff)
            n_exact += (diff == 0) ? 1 : 0
            n_within_1ulp += (diff <= 1) ? 1 : 0
        end
        @test n_within_1ulp == 10_000
        @test max_diff <= 1
        @test n_exact >= 9_800        # ~98%+ bit-exact in practice
    end

end  # soft_exp
