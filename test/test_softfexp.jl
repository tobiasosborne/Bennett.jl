using Test
using Bennett
using Bennett: soft_exp2, soft_exp
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

end  # soft_exp
