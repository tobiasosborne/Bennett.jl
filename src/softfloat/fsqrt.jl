"""
    soft_fsqrt(a::UInt64) -> UInt64

IEEE 754 double-precision square root on raw bit patterns.
Uses only integer operations. Bit-exact with hardware `sqrt`.
Fully branchless.

Algorithm: digit-by-digit restoring sqrt (Ercegovac-Lang, "Digital Arithmetic"
Ch. 6; fdlibm `e_sqrt.c`). Structurally mirrors `soft_fdiv`'s restoring loop.

Kahan's theorem (no-midpoint property of sqrt on floats): the true real-valued
sqrt of a binary64 input is never exactly halfway between two binary64s. A
sticky bit from `remainder != 0` combined with the standard round-to-nearest-
even in `_sf_round_and_pack` therefore produces correctly-rounded output —
no Markstein correction or Tuckerman post-test needed.

Scaling rationale: to produce a 56-bit quotient (53 mantissa + 3 GRS-slot)
with leading 1 at bit 55 (the format `_sf_round_and_pack` expects), we need
a 112-bit radicand (`m_adj << 58`). We stream the radicand from the top of a
conceptual 128-bit register, processing two bits per iteration. Stored as a
`(a_hi, a_lo)` UInt64 pair. 64 iterations cover the full 128 bits; the top
16 bits of the register are zero (leading bit lands at position 110 or 111
depending on exponent parity), so the first ~8 iterations produce leading
zeros in the quotient and the meaningful bit lands at position 55 as
required.

No subnormal result path: `sqrt` of a positive finite maps to
`[2^-537, 2^512]` which is well within the normal Float64 range. Exponent
overflow also impossible.
"""
@inline function soft_fsqrt(a::UInt64)::UInt64
    BIAS = Int64(1023)

    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK

    # ── Special-case predicates ──
    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_inf  = (ea == UInt64(0x7FF)) & (fa == UInt64(0))
    a_zero = (ea == UInt64(0))    & (fa == UInt64(0))
    a_neg  = sa != UInt64(0)

    # ── Mantissa with implicit bit (subnormal: no implicit) ──
    ma = ifelse(ea != UInt64(0), fa | IMPLICIT, fa)
    ea_eff = ifelse(ea != UInt64(0), Int64(ea), Int64(1))

    # Pre-normalize subnormal operands so leading 1 is at bit 52.
    (ma, ea_eff) = _sf_normalize_to_bit52(ma, ea_eff)

    # ── Exponent parity + halving ──
    # We want the unbiased exponent to be even so that result_exp = e_unb / 2.
    # If odd, absorb a factor of 2 into the mantissa: ma_adj = 2*ma, which shifts
    # leading 1 from bit 52 to bit 53. Use arithmetic right shift to handle
    # negative e_unb correctly (floor toward -inf preserves the identity
    # sqrt(m * 2^e) = sqrt(m or 2m) * 2^((e or e-1)/2)).
    e_unb = ea_eff - BIAS
    e_is_odd = (e_unb & Int64(1)) != Int64(0)
    ma_adj = ifelse(e_is_odd, ma << 1, ma)
    result_exp = (e_unb >> 1) + BIAS        # biased result exponent

    # ── Set up 128-bit radicand A = ma_adj << 58 ──
    # Leading 1 of A lands at bit 110 (e_unb even) or 111 (e_unb odd).
    # Split A as (a_hi, a_lo), each UInt64: a_hi holds bits [64..127] of A,
    # a_lo holds bits [0..63]. ma_adj has ≤ 54 bits (bits 0..53), so after
    # shift by 58: bits 0..5 of ma_adj land in a_lo[58..63], bits 6..53 of
    # ma_adj land in a_hi[0..47].
    a_hi = ma_adj >> 6
    a_lo = (ma_adj & UInt64(0x3F)) << 58

    # ── Restoring digit-recurrence sqrt, 64 iterations (2 bits/iter) ──
    # Invariant: after iteration i, r = A_consumed - q², and 0 ≤ r ≤ 2q.
    # A_consumed is the top 2(i+1) bits of A shifted into r so far.
    # The first ~8 iterations extract the all-zero top of A (above bit 111),
    # producing leading-zero bits in q. The meaningful bits of q begin at
    # bit 55 and run down to bit 0, giving the 56-bit working format that
    # `_sf_round_and_pack` expects.
    q = UInt64(0)
    r = UInt64(0)
    for i in 0:63
        top2 = (a_hi >> 62) & UInt64(3)
        a_hi = (a_hi << 2) | (a_lo >> 62)
        a_lo = a_lo << 2

        r = (r << 2) | top2
        t = (q << 2) | UInt64(1)
        fits = r >= t
        r = ifelse(fits, r - t, r)
        q = (q << 1) | ifelse(fits, UInt64(1), UInt64(0))
    end

    # ── Sticky bit from nonzero remainder ──
    # Kahan's theorem: sqrt is never an exact halfway case. OR-ing a 1 into
    # bit 0 of q when r≠0 preserves the tie-break information needed for
    # round-nearest-even inside `_sf_round_and_pack`.
    wr = q | ifelse(r != UInt64(0), UInt64(1), UInt64(0))

    # ── Round + pack ──
    # sqrt of a valid positive finite can neither overflow to Inf nor
    # underflow to subnormal; the overflow flags from `_sf_round_and_pack`
    # are unused here.
    (normal_result, _overflow_result, _exp_overflow, _exp_overflow_after_round) =
        _sf_round_and_pack(wr, result_exp, UInt64(0))

    # ── Special-case select chain ──
    # Order (last override wins): normal → +Inf → ±0 → -finite/-Inf → NaN.
    # `a_nan` must fire strictly last so the NaN passthrough (preserving
    # sign + payload, force-quieting sNaN per Bennett-r84x / U08) wins over
    # the negative-argument invalid-op, since `a_neg_nonzero` also includes
    # negative NaNs (sign=1, fraction!=0).
    a_neg_nonzero = a_neg & (!a_zero)
    result = normal_result
    result = ifelse(a_inf & (!a_neg), INF_BITS, result)                        # +Inf → +Inf
    result = ifelse(a_zero, a, result)                                          # ±0 → ±0 (incl. sqrt(-0) = -0)
    result = ifelse(a_neg_nonzero & (!a_nan), INDEF, result)                    # -finite / -Inf → x86 INDEF
    result = ifelse(a_nan, a | QUIET_BIT, result)                               # NaN → preserve + quiet
    return result
end
