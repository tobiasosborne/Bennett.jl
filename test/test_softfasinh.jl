# Bennett-sfx9: soft_asinh primitive contract tests.
#
# IEEE 754 binary64 inverse hyperbolic sine on raw bit patterns. Three-
# regime branchless port adapting Julia stdlib `Base.asinh` with `log1p`
# substituted by an extended polynomial regime (since Bennett.jl lacks
# `soft_log1p`):
#
#   Regime P (polynomial): |x| ≤ 0.55       →  x · asinh_kernel(x²)
#   Regime M (medium):     0.55 < |x| < 2^28 →  log(|x| + sqrt(x²+1))
#   Regime H (huge):       |x| ≥ 2^28       →  log(|x|) + ln(2)
#
# K=30 polynomial in z=x² covers |x| ≤ 0.55 with ≤2 ULP empirically;
# medium formula is accurate (≤2 ULP) starting from |x| ≥ ~0.56 (below
# that, soft_log of an argument near 1 loses precision that Julia
# stdlib recovers via log1p). Polynomial regime upper bound chosen
# at 0.55 to give the medium arm a safety margin.
#
# §13 (CLAUDE.md / Bennett-fnxg): asinh(subnormal) = subnormal bit-
# exactly, via the polynomial branch's algebra (x²→0, kernel(0)=1.0,
# x·1=x). Subnormal-input testset asserts 0 ULP across all 1074
# binades × ±.
#
# Tier C1.9 in Bennett-Enzyme-Parity-NorthStar.md — fourth hyperbolic
# primitive (after Bennett-m2bv tanh, Bennett-ky5n sinh, Bennett-bybh
# cosh).

using Test
using Bennett

ulp_diff_asinh(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        diff = gb >= eb ? gb - eb : eb - gb
        Int64(diff > UInt64(1<<62) ? Int64(1<<62) : diff)
    end
end

soft_asinh_f(x::Float64) =
    reinterpret(Float64, Bennett.soft_asinh(reinterpret(UInt64, x)))

@testset "Bennett-sfx9: soft_asinh (regime-split, log1p sidestep via wide poly)" begin

    @testset "smoke — three regimes (poly / medium / huge)" begin
        # Polynomial regime (|x| ≤ 0.55).
        for x in (0.0, 1e-15, 1e-9, 0.001, 0.01, 0.1, 0.3, 0.5, 0.55)
            @test ulp_diff_asinh(soft_asinh_f( x), asinh( x)) <= 2
            @test ulp_diff_asinh(soft_asinh_f(-x), asinh(-x)) <= 2
        end
        # Medium regime (0.55 < |x| < 2^28).
        for x in (0.56, 0.7, 1.0, 2.0, 10.0, 1e3, 1e6, 1e8)
            @test ulp_diff_asinh(soft_asinh_f( x), asinh( x)) <= 2
            @test ulp_diff_asinh(soft_asinh_f(-x), asinh(-x)) <= 2
        end
        # Huge regime (|x| ≥ 2^28).
        for x in (2.0^28, 2.0^29, 1e10, 1e15, 1e100, prevfloat(Inf))
            @test ulp_diff_asinh(soft_asinh_f( x), asinh( x)) <= 2
            @test ulp_diff_asinh(soft_asinh_f(-x), asinh(-x)) <= 2
        end
    end

    @testset "specials — NaN / ±Inf / ±0 (bit-exact)" begin
        # Sign-preserving zero (polynomial path: soft_fmul(±0, kernel(0)) = ±0).
        @test Bennett.soft_asinh(reinterpret(UInt64,  0.0)) == reinterpret(UInt64,  0.0)
        @test Bennett.soft_asinh(reinterpret(UInt64, -0.0)) == reinterpret(UInt64, -0.0)
        # Saturation at infinity (huge arm: log(+Inf) + ln(2) = +Inf).
        @test soft_asinh_f( Inf) ===  Inf
        @test soft_asinh_f(-Inf) === -Inf
        # NaN propagation.
        @test isnan(soft_asinh_f(NaN))
        @test (Bennett.soft_asinh(reinterpret(UInt64, NaN)) & UInt64(0x0008000000000000)) != UInt64(0)
        # Signalling-NaN.
        let snan = reinterpret(Float64, UInt64(0x7FF0000000000001))
            r_bits = Bennett.soft_asinh(reinterpret(UInt64, snan))
            @test isnan(reinterpret(Float64, r_bits))
            @test (r_bits & UInt64(0x0008000000000000)) != UInt64(0)
        end
    end

    @testset "regime boundary — poly ↔ medium at |x| = 0.55" begin
        for δ in (1e-15, 1e-12, 1e-9, 1e-6, 1e-3)
            for sign in (1.0, -1.0)
                xlo = sign * (0.55 - δ); xhi = sign * (0.55 + δ)
                @test ulp_diff_asinh(soft_asinh_f(xlo), asinh(xlo)) <= 2
                @test ulp_diff_asinh(soft_asinh_f(xhi), asinh(xhi)) <= 2
            end
        end
    end

    @testset "regime boundary — medium ↔ huge at |x| = 2^28" begin
        H = 2.0^28
        for δ in (1.0, 1e3, 1e5)
            for sign in (1.0, -1.0)
                xlo = sign * (H - δ); xhi = sign * (H + δ)
                @test ulp_diff_asinh(soft_asinh_f(xlo), asinh(xlo)) <= 2
                @test ulp_diff_asinh(soft_asinh_f(xhi), asinh(xhi)) <= 2
            end
        end
    end

    @testset "subnormal-INPUT bit-exactness (§13 / Bennett-fnxg)" begin
        max_ulp_subnormal = 0; n_subnormal = 0
        max_ulp_normal    = 0
        for binade in -1074:-1
            for sign_bit in (UInt64(0), UInt64(0x8000000000000000))
                xbits = reinterpret(UInt64, ldexp(1.0, binade)) | sign_bit
                xs    = reinterpret(Float64, xbits)
                got_bits = Bennett.soft_asinh(xbits)
                exp_bits = reinterpret(UInt64, asinh(xs))
                ulp = Int64(got_bits >= exp_bits ? got_bits - exp_bits : exp_bits - got_bits)
                if issubnormal(xs)
                    n_subnormal += 1
                    max_ulp_subnormal = max(max_ulp_subnormal, ulp)
                else
                    max_ulp_normal = max(max_ulp_normal, ulp)
                end
            end
        end
        @test max_ulp_subnormal == 0
        @test n_subnormal > 0
        @test max_ulp_normal <= 1
    end

    @testset "polynomial-regime fine sweep |x| ∈ [0, 0.55]" begin
        max_ulp = 0
        x = 0.0
        while x <= 0.55
            for s in (1.0, -1.0)
                xs = s * x; got = soft_asinh_f(xs); exp = asinh(xs)
                u = ulp_diff_asinh(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 1.0e-3
        end
        @test max_ulp <= 2
    end

    @testset "medium-regime fine sweep |x| ∈ [0.55, 100]" begin
        max_ulp = 0
        x = 0.55
        while x <= 100.0
            for s in (1.0, -1.0)
                xs = s * x; got = soft_asinh_f(xs); exp = asinh(xs)
                u = ulp_diff_asinh(got, exp)
                max_ulp = max(max_ulp, u)
                @test u <= 2
            end
            x += 0.05
        end
        @test max_ulp <= 2
    end

    @testset "100k random sweep, 3 seeds × 5 magnitude buckets" begin
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A2A4E32))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            asinh_max = Int64(0); asinh_fail = 0
            for _ in 1:n_per_seed
                mag = rand(1:5)
                x = if mag == 1; (rand() - 0.5) * 1.1     # poly + boundary
                    elseif mag == 2; (rand() - 0.5) * 4.0   # mid
                    elseif mag == 3; (rand() - 0.5) * 200.0
                    elseif mag == 4; (rand() - 0.5) * 1e10  # spans huge boundary
                    else;            (rand() - 0.5) * 1e100 # huge
                    end
                got = soft_asinh_f(x); expected = asinh(x)
                if isfinite(expected)
                    u = ulp_diff_asinh(got, expected)
                    asinh_max = max(asinh_max, u); u > 2 && (asinh_fail += 1)
                else
                    (got === expected || (isnan(got) && isnan(expected))) || (asinh_fail += 1)
                end
            end
            @test asinh_fail == 0
            @test asinh_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_asinh") === Bennett.soft_asinh
    end

end
