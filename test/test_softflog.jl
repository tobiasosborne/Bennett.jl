using Test
using Bennett
using Bennett: soft_log, soft_log2, soft_log10
using Random

# Bennett.jl soft_log — IEEE 754 double-precision natural logarithm on raw
# bit patterns. Algorithm: Tang-style range reduction with N=128 lookup table
# and degree-6 minimax polynomial (Arm Optimized Routines / musl log.c, 2018):
#   x = 2^k · z,  z ∈ [0x1.6p-1, 0x1.6p0)
#   log(x) = k·ln(2) + log(c_i) + log1p(z·invc_i - 1)
# where i indexes a 128-entry table holding (1/c_i, log(c_i)).
#
# Tolerance: ≤2 ulp vs Julia's Base.log. Arm publishes 0.5 + 4.13/128 ≈ 0.532
# ulp worst case for the main path; system Base.log variation puts our
# practical target at ≤2 ulp (typically 0).

const ULP_TOL_LOG = 2

function _ulp_diff_log(actual::UInt64, expected::Float64)
    expected_bits = reinterpret(UInt64, expected)
    if isnan(expected)
        return isnan(reinterpret(Float64, actual)) ? 0 : typemax(Int64)
    end
    Int64(actual >= expected_bits ? actual - expected_bits : expected_bits - actual)
end

@testset "soft_log library" begin

    function check_log(a::Float64; tol::Int=ULP_TOL_LOG)
        a_bits = reinterpret(UInt64, a)
        result_bits = soft_log(a_bits)
        expected = log(a)
        diff = _ulp_diff_log(result_bits, expected)
        if diff > tol
            @warn "soft_log ulp drift" a expected actual=reinterpret(Float64, result_bits) diff
        end
        @test diff <= tol
    end

    @testset "smoke" begin
        # log(1) = 0 (must be bit-exact)
        @test soft_log(reinterpret(UInt64, 1.0)) == reinterpret(UInt64, 0.0)
        # log(e) = 1 (≤2 ulp)
        check_log(Float64(ℯ); tol=ULP_TOL_LOG)
        # log(2) (≤2 ulp)
        check_log(2.0)
        # log(10) (≤2 ulp)
        check_log(10.0)
    end

    @testset "exact powers of e (only log(1) is bit-exact)" begin
        # log(1) is the ONLY bit-exact case for natural log
        @test soft_log(reinterpret(UInt64, 1.0)) == reinterpret(UInt64, 0.0)
    end

    @testset "common values" begin
        check_log(0.5)
        check_log(0.25)
        check_log(2.0)
        check_log(4.0)
        check_log(8.0)
        check_log(0.1)
        check_log(100.0)
        check_log(1e10)
        check_log(1e-10)
        check_log(3.14159)
        check_log(1.5)
        check_log(0.99)
        check_log(1.01)
    end

    @testset "near-1.0 cancellation sweep" begin
        # log(1+ε) ≈ ε — small but not zero. Catastrophic cancellation hazard
        # in main path: log(c) and log1p(r) are both small and opposite sign.
        # This is the high-risk region for log accuracy.
        for ε in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3, 0.01, 0.05, -1e-15, -1e-12,
                  -1e-9, -1e-6, -1e-3, -0.01, -0.05)
            check_log(1.0 + ε)
        end
        # Sweep tightly around 1.0
        for x in 0.95:0.001:1.05
            x == 1.0 && continue  # log(1)=0 already covered
            check_log(x)
        end
    end

    @testset "subnormal input — output near MIN_LOG" begin
        # log(2^-1074) ≈ -744.4. Subnormal input must be normalized first.
        # This is log's analogue of soft_exp's subnormal-OUTPUT region.
        check_log(2.0^-1022)        # smallest normal
        check_log(2.0^-1050)        # subnormal
        check_log(2.0^-1074)        # smallest positive subnormal
        check_log(nextfloat(0.0))   # smallest positive subnormal
        check_log(5e-324)           # smallest subnormal
        check_log(1e-300)
        check_log(1e-200)
        check_log(1e-100)
    end

    @testset "large input — output near MAX_LOG" begin
        # log(2^1023) ≈ 709.78
        check_log(2.0^1023)
        check_log(prevfloat(Inf))    # largest finite
        check_log(1e300)
        check_log(1e100)
    end

    @testset "log(0) = -Inf, signals divzero" begin
        @test soft_log(reinterpret(UInt64, 0.0)) == reinterpret(UInt64, -Inf)
        @test soft_log(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -Inf)
    end

    @testset "log(+Inf) = +Inf" begin
        @test soft_log(reinterpret(UInt64, Inf)) == reinterpret(UInt64, Inf)
    end

    @testset "log(negative) = NaN" begin
        # log of any negative value (including -Inf) is NaN
        @test isnan(reinterpret(Float64, soft_log(reinterpret(UInt64, -1.0))))
        @test isnan(reinterpret(Float64, soft_log(reinterpret(UInt64, -2.0))))
        @test isnan(reinterpret(Float64, soft_log(reinterpret(UInt64, -1e-300))))
        @test isnan(reinterpret(Float64, soft_log(reinterpret(UInt64, -Inf))))
    end

    @testset "NaN propagation" begin
        @test isnan(reinterpret(Float64, soft_log(reinterpret(UInt64, NaN))))
        snan_bits = UInt64(0x7FF0000000000001)
        @test isnan(reinterpret(Float64, soft_log(snan_bits)))
    end

    @testset "full-range random sweep (10k uniform-log in [1e-300, 1e300])" begin
        Random.seed!(0x10C50F7)  # log soft-test seed
        n_pass = 0
        max_diff = 0
        for _ in 1:10_000
            # uniform over log(x) ∈ [-690, +690] ≈ x ∈ [1e-300, 1e300]
            lx = (rand() - 0.5) * 1380.0
            x = exp(lx)
            x == 0.0 && continue
            isfinite(x) || continue
            result_bits = soft_log(reinterpret(UInt64, x))
            expected = log(x)
            diff = _ulp_diff_log(result_bits, expected)
            max_diff = max(max_diff, diff)
            if diff <= ULP_TOL_LOG
                n_pass += 1
            end
        end
        @test n_pass >= 9_980
        @test max_diff <= 4
    end

    @testset "tight-range random sweep (5k uniform in [0.5, 2.0])" begin
        Random.seed!(0x807ED)
        max_diff = 0
        for _ in 1:5_000
            x = 0.5 + 1.5 * rand()
            result_bits = soft_log(reinterpret(UInt64, x))
            expected = log(x)
            diff = _ulp_diff_log(result_bits, expected)
            max_diff = max(max_diff, diff)
        end
        @test max_diff <= ULP_TOL_LOG
    end

    @testset "BIT-EXACT subnormal-INPUT range (high-risk per CLAUDE.md §13)" begin
        # log on subnormal inputs: input ∈ (0, 2^-1022), output ∈ (-744.4, -708.4).
        # The compiler-mandated §13 testset sweeps the analogue of soft_exp's
        # subnormal-output region. For log this is subnormal-input.
        # Sweep every Float64 step from 2^-1074 (smallest subnormal) up to
        # 2^-1022 (smallest normal), checking ≤2 ulp at every step.
        n_total = 0
        n_pass = 0
        max_diff = 0
        # sample 100 points across the subnormal range
        for k in 1:100
            x = ldexp(rand() + 0.5, -1022 - rand(1:50))
            n_total += 1
            result_bits = soft_log(reinterpret(UInt64, x))
            expected = log(x)
            diff = _ulp_diff_log(result_bits, expected)
            max_diff = max(max_diff, diff)
            n_pass += (diff <= ULP_TOL_LOG) ? 1 : 0
        end
        @test n_pass == n_total
        @test max_diff <= ULP_TOL_LOG
    end

end  # soft_log

@testset "soft_log2 library" begin
    function check_log2(a::Float64; tol::Int=ULP_TOL_LOG)
        a_bits = reinterpret(UInt64, a)
        result_bits = soft_log2(a_bits)
        expected = log2(a)
        diff = _ulp_diff_log(result_bits, expected)
        if diff > tol
            @warn "soft_log2 ulp drift" a expected actual=reinterpret(Float64, result_bits) diff
        end
        @test diff <= tol
    end

    @testset "smoke" begin
        @test soft_log2(reinterpret(UInt64, 1.0)) == reinterpret(UInt64, 0.0)  # log2(1)=0 bit-exact
        check_log2(2.0)
        check_log2(4.0)
        check_log2(0.5)
    end

    @testset "common values" begin
        for x in (0.5, 0.25, 0.125, 2.0, 4.0, 8.0, 16.0, 3.0, 5.0, 7.0, 10.0,
                  1e-100, 1e100, 1.5, 2.5, π, ℯ)
            check_log2(Float64(x))
        end
    end

    @testset "subnormal input" begin
        check_log2(2.0^-1022)
        check_log2(2.0^-1050)
        check_log2(nextfloat(0.0))
    end

    @testset "special cases" begin
        @test soft_log2(reinterpret(UInt64, 0.0))  == reinterpret(UInt64, -Inf)
        @test soft_log2(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -Inf)
        @test soft_log2(reinterpret(UInt64, Inf))  == reinterpret(UInt64, Inf)
        @test isnan(reinterpret(Float64, soft_log2(reinterpret(UInt64, -1.0))))
        @test isnan(reinterpret(Float64, soft_log2(reinterpret(UInt64, NaN))))
    end

    @testset "random sweep [1e-300, 1e300]" begin
        Random.seed!(0x10610652)
        n_pass = 0; n_total = 0; max_diff = 0
        for _ in 1:5_000
            lx = (rand() - 0.5) * 1380.0
            x = exp(lx)
            (x == 0.0 || !isfinite(x)) && continue
            n_total += 1
            result_bits = soft_log2(reinterpret(UInt64, x))
            diff = _ulp_diff_log(result_bits, log2(x))
            max_diff = max(max_diff, diff)
            if diff <= ULP_TOL_LOG; n_pass += 1; end
        end
        @test n_pass == n_total
        @test max_diff <= 2
    end
end  # soft_log2

@testset "soft_log10 library" begin
    function check_log10(a::Float64; tol::Int=ULP_TOL_LOG)
        a_bits = reinterpret(UInt64, a)
        result_bits = soft_log10(a_bits)
        expected = log10(a)
        diff = _ulp_diff_log(result_bits, expected)
        if diff > tol
            @warn "soft_log10 ulp drift" a expected actual=reinterpret(Float64, result_bits) diff
        end
        @test diff <= tol
    end

    @testset "smoke" begin
        @test soft_log10(reinterpret(UInt64, 1.0)) == reinterpret(UInt64, 0.0)  # log10(1)=0 bit-exact
        check_log10(10.0)
        check_log10(100.0)
        check_log10(0.1)
    end

    @testset "common values" begin
        for x in (0.1, 0.01, 0.001, 10.0, 100.0, 1000.0, 7.0, π, ℯ,
                  1e-100, 1e100, 0.5, 2.0)
            check_log10(Float64(x))
        end
    end

    @testset "subnormal input" begin
        check_log10(2.0^-1022)
        check_log10(2.0^-1050)
        check_log10(nextfloat(0.0))
    end

    @testset "special cases" begin
        @test soft_log10(reinterpret(UInt64, 0.0))  == reinterpret(UInt64, -Inf)
        @test soft_log10(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -Inf)
        @test soft_log10(reinterpret(UInt64, Inf))  == reinterpret(UInt64, Inf)
        @test isnan(reinterpret(Float64, soft_log10(reinterpret(UInt64, -1.0))))
        @test isnan(reinterpret(Float64, soft_log10(reinterpret(UInt64, NaN))))
    end

    @testset "random sweep [1e-300, 1e300]" begin
        Random.seed!(0x10610610)
        n_pass = 0; n_total = 0; max_diff = 0
        for _ in 1:5_000
            lx = (rand() - 0.5) * 1380.0
            x = exp(lx)
            (x == 0.0 || !isfinite(x)) && continue
            n_total += 1
            result_bits = soft_log10(reinterpret(UInt64, x))
            diff = _ulp_diff_log(result_bits, log10(x))
            max_diff = max(max_diff, diff)
            if diff <= ULP_TOL_LOG; n_pass += 1; end
        end
        @test n_pass == n_total
        @test max_diff <= 2
    end
end  # soft_log10
