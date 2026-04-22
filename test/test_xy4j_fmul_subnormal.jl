# Bennett-xy4j / U06: soft_fmul skips subnormal pre-normalisation.
#
# src/softfloat/fmul.jl loads `ma = fa | IMPLICIT` (normal) or `ma = fa`
# (subnormal) and then feeds it straight into the 53×53 schoolbook multiply.
# For subnormal operands, ma's leading 1 sits below bit 52, so the extractor
# at fmul.jl:127-182 reads the wrong MSB position and `_sf_normalize_clz`
# can't recover already-truncated bits. Result: ~11-20% of normal × subnormal
# random pairs are off by 1-2 ULP against hardware.
#
# Sibling ops (fdiv.jl:42-43, fma.jl:67-69) already call
# `_sf_normalize_to_bit52`. The fix is to mirror that call for ma and mb
# just after the `ea_eff/eb_eff` computations, before the product.
#
# Violates CLAUDE.md §14 (soft-float bit-exact).
#
# Catalogue: reviews/2026-04-21/UNIFIED_CATALOGUE.md U06. Reports: #07 F1,
# #07 F2 (extractor precondition), #07 F13, #11 F1.

using Test
using Random
using Bennett: soft_fmul

@testset "Bennett-xy4j / U06: soft_fmul bit-exact on subnormals" begin

    @testset "T1: catalogue repro (normal × subnormal, 2 ULP pre-fix)" begin
        # From reviews/2026-04-21/11_softfloat.md §H1 reproduction.
        a_bits = UInt64(0xE4D9C356E967BECD)   # normal
        b_bits = UInt64(0x8000B051DB6FC2B8)   # subnormal, sign bit set
        got = soft_fmul(a_bits, b_bits)
        want = reinterpret(UInt64,
                    reinterpret(Float64, a_bits) *
                    reinterpret(Float64, b_bits))
        @test got == want
    end

    @testset "T2: normal × smallest subnormal (ma leading-1 far below bit 52)" begin
        # b is the minimum-positive-subnormal (0x0000000000000001).
        # Pre-fix loses ~52 mantissa bits of precision.
        a_bits = reinterpret(UInt64, 1.5)
        b_bits = UInt64(1)
        got = soft_fmul(a_bits, b_bits)
        want = reinterpret(UInt64,
                    reinterpret(Float64, a_bits) *
                    reinterpret(Float64, b_bits))
        @test got == want
    end

    @testset "T3: subnormal × subnormal (both operands need normalisation)" begin
        # Product underflows to zero in the native path; soft path must match.
        for b_lo in (UInt64(1), UInt64(0x42), UInt64(0x0000FFFFFFFFFFFF))
            for a_hi in (UInt64(0x0008000000000000),   # sign-bit-set subnormal
                          UInt64(0x0000100000000000))  # tiny subnormal
                got = soft_fmul(a_hi, b_lo)
                want = reinterpret(UInt64,
                            reinterpret(Float64, a_hi) *
                            reinterpret(Float64, b_lo))
                @test got == want
            end
        end
    end

    @testset "T4: 256-pair deterministic subnormal-mix sweep" begin
        # Fixed-seed sweep designed to hit the failure distribution:
        # one operand normal, one subnormal. Pre-fix: ~11% off by 1-2 ULP.
        # Post-fix: bit-exact.
        rng = MersenneTwister(0x5E6D6E6A)
        mismatches = 0
        n_pairs = 256
        for _ in 1:n_pairs
            # Normal-range exponent 1..2046; random sign & mantissa.
            e_norm = UInt64(1 + rand(rng, 1:2044))
            sign_n = UInt64(rand(rng, 0:1)) << 63
            frac_n = UInt64(rand(rng, UInt64(0):UInt64(0x000F_FFFF_FFFF_FFFF)))
            a_bits = sign_n | (e_norm << 52) | frac_n
            # Subnormal: exponent = 0, non-zero fraction.
            sign_s = UInt64(rand(rng, 0:1)) << 63
            frac_s = UInt64(rand(rng, UInt64(1):UInt64(0x000F_FFFF_FFFF_FFFF)))
            b_bits = sign_s | frac_s
            got = soft_fmul(a_bits, b_bits)
            want = reinterpret(UInt64,
                        reinterpret(Float64, a_bits) *
                        reinterpret(Float64, b_bits))
            if got != want
                mismatches += 1
            end
        end
        @test mismatches == 0
    end

    @testset "T5: normal × normal stays bit-exact (no regression)" begin
        # Confirm the pre-norm call is a no-op for inputs with leading-1
        # already at bit 52.
        for (a_f, b_f) in ((1.0, 2.0), (-1.5, 0.25), (1e100, 1e-100),
                            (3.141592653589793, 2.718281828459045))
            a_bits = reinterpret(UInt64, a_f)
            b_bits = reinterpret(UInt64, b_f)
            got = soft_fmul(a_bits, b_bits)
            want = reinterpret(UInt64, a_f * b_f)
            @test got == want
        end
    end
end
