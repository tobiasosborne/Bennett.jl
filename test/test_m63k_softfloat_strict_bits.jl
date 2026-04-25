# Bennett-m63k / U60 — strict-bits NaN coverage replacing isnan()-only checks.
#
# Pre-condition: U08 (Bennett-r84x) closed 2026-04-23 — soft-float NaN
# canonicalisation now matches hardware bit-for-bit (invalid-op produces
# x86 INDEF 0xFFF8…; NaN-input passthrough preserves sign + payload).
# This file consolidates the "strict bit-equality" coverage U60 asked for
# without touching the 10 existing test_softf*.jl files (whose isnan()
# fallbacks are now redundant but not load-bearing).
#
# Three layers:
#   1. Per-op strict bit-equality sweep on randoms — exercises the
#      ordinary arithmetic path under exact-bit comparison.
#   2. NaN payload propagation — explicit qNaN/sNaN/custom-payload inputs;
#      verify each op preserves the operand's sign + payload bits per
#      IEEE 754-2019 §6.2.3 (catches future regressions of the Bennett-r84x
#      canonicalisation fix).
#   3. Cross-op identities — same answer via two pipelines (fma vs
#      fmul+fadd) detects asymmetric drift even without an oracle.

using Test
using Bennett
using Random

# Strict bit-pattern check.  Replaces the "if isnan(expected); isnan(got);
# else; bits==bits; end" pattern that masks NaN-payload regressions.
@inline function _strict_eq(got_bits::UInt64, expected::Float64)
    return got_bits == reinterpret(UInt64, expected)
end

# A small set of NaN bit patterns used throughout: canonical qNaN +/-,
# custom payloads, and a "signaling NaN" pattern (quiet-bit clear).
const _NAN_PATTERNS = UInt64[
    0x7FF8000000000000,    # +qNaN canonical (Julia native NaN)
    0xFFF8000000000000,    # -qNaN canonical (x86 INDEF; invalid-op result)
    0x7FF8DEADBEEFCAFE,    # +qNaN with custom payload
    0xFFF8DEADBEEFCAFE,    # -qNaN with custom payload
    0x7FF0000000000001,    # sNaN payload 1 (quiet bit CLEAR)
    0xFFF0000000000007,    # sNaN payload 7 with sign
]

@testset "Bennett-m63k / U60 — soft-float strict-bits NaN coverage" begin

    @testset "Layer 1 — per-op strict bit-equality on randoms" begin
        Random.seed!(0x6033)

        # 1000 random pairs across exponents [-30, 30].  All must round-trip
        # to hardware bit patterns under strict equality (no isnan fallback).
        n = 1000
        for _ in 1:n
            a = randn() * (2.0 ^ rand(-30:30))
            b = randn() * (2.0 ^ rand(-30:30))
            c = randn() * (2.0 ^ rand(-30:30))
            ab, bb, cb = reinterpret(UInt64, a), reinterpret(UInt64, b), reinterpret(UInt64, c)

            @test _strict_eq(soft_fadd(ab, bb), a + b)
            @test _strict_eq(soft_fsub(ab, bb), a - b)
            @test _strict_eq(soft_fmul(ab, bb), a * b)
            @test _strict_eq(soft_fma(ab, bb, cb), fma(a, b, c))
        end

        # Division by zero (1/0) and 0/0 — pinned in their own block to
        # surface regression in invalid-op canonicalisation specifically.
        zero_b = reinterpret(UInt64, 0.0)
        one_b  = reinterpret(UInt64, 1.0)
        @test _strict_eq(soft_fdiv(one_b,  zero_b), 1.0 / 0.0)   #  Inf
        @test _strict_eq(soft_fdiv(zero_b, zero_b), 0.0 / 0.0)   #  NaN (INDEF)
    end

    @testset "Layer 2 — NaN-input payload propagation (sign + payload preserved)" begin
        # IEEE 754-2019 §6.2.3: when a quiet NaN is an operand, the result
        # is one of the input NaNs (with the quiet bit forced).  All six
        # NaN bit patterns above must round-trip through every soft op
        # against the hardware reference.
        for nan_bits in _NAN_PATTERNS
            nan_f = reinterpret(Float64, nan_bits)
            # Exercise each op with the NaN as the LHS and a normal RHS.
            rhs   = 2.5
            rhs_b = reinterpret(UInt64, rhs)

            @test _strict_eq(soft_fadd(nan_bits, rhs_b),         nan_f + rhs)
            @test _strict_eq(soft_fsub(nan_bits, rhs_b),         nan_f - rhs)
            @test _strict_eq(soft_fmul(nan_bits, rhs_b),         nan_f * rhs)
            @test _strict_eq(soft_fdiv(nan_bits, rhs_b),         nan_f / rhs)
            @test _strict_eq(soft_fma(nan_bits, rhs_b, rhs_b),   fma(nan_f, rhs, rhs))
            # And as RHS for the binary ops.
            @test _strict_eq(soft_fadd(rhs_b, nan_bits),         rhs + nan_f)
            @test _strict_eq(soft_fsub(rhs_b, nan_bits),         rhs - nan_f)
            @test _strict_eq(soft_fmul(rhs_b, nan_bits),         rhs * nan_f)
            @test _strict_eq(soft_fdiv(rhs_b, nan_bits),         rhs / nan_f)
        end

        # sqrt(NaN) — payload + sign must propagate through fsqrt too.
        for nan_bits in _NAN_PATTERNS
            nan_f = reinterpret(Float64, nan_bits)
            hw    = ccall(:sqrt, Cdouble, (Cdouble,), nan_f)
            @test _strict_eq(soft_fsqrt(nan_bits), hw)
        end
    end

    @testset "Layer 3 — invalid-op NaN matches HW INDEF (0xFFF8…)" begin
        # The Bennett-r84x fix produces x86 INDEF 0xFFF8000000000000 for
        # invalid ops where neither operand is itself a NaN.  Pin it here
        # so any future regression of the invalid-op path surfaces.
        inf_pos  = reinterpret(UInt64, Inf)
        inf_neg  = reinterpret(UInt64, -Inf)
        zero_pos = reinterpret(UInt64, 0.0)
        neg_one  = reinterpret(UInt64, -1.0)
        indef    = UInt64(0xFFF8000000000000)

        @test soft_fsub(inf_pos, inf_pos) == indef    # Inf - Inf
        @test soft_fadd(inf_pos, inf_neg) == indef    # Inf + (-Inf)
        @test soft_fmul(inf_pos, zero_pos) == indef   # Inf * 0
        @test soft_fdiv(zero_pos, zero_pos) == indef  # 0 / 0
        @test soft_fdiv(inf_pos, inf_pos) == indef    # Inf / Inf
        @test soft_fsqrt(neg_one) == indef            # sqrt(-1)
    end

    @testset "Layer 4 — cross-op identity: fma(a,b,0) ≡ fmul(a,b) bit-exact" begin
        # An asymmetric drift in either fma or fmul surfaces here without
        # needing a hardware oracle.  Holds bit-exactly post-U08.
        Random.seed!(0x6034)
        zero_b = reinterpret(UInt64, 0.0)
        for _ in 1:500
            a = randn() * (2.0 ^ rand(-20:20))
            b = randn() * (2.0 ^ rand(-20:20))
            ab, bb = reinterpret(UInt64, a), reinterpret(UInt64, b)
            @test soft_fma(ab, bb, zero_b) == soft_fmul(ab, bb)
        end

        # Same identity on every NaN pattern.
        for nan_bits in _NAN_PATTERNS
            rhs_b = reinterpret(UInt64, 2.5)
            @test soft_fma(nan_bits, rhs_b, zero_b) == soft_fmul(nan_bits, rhs_b)
        end
    end
end
