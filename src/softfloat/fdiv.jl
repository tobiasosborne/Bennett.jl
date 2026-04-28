"""
    soft_fdiv(a::UInt64, b::UInt64) -> UInt64

IEEE 754 double-precision division on raw bit patterns.
Uses only integer operations. Bit-exact with hardware `/`.
Fully branchless.

## Correctness sketch

Both inputs are pre-normalized so the leading 1 sits at bit 52 (Bennett-r6e3
fixed a subnormal-divisor bug where this was assumed but not enforced — the
fix prepends `_sf_normalize_to_bit52` to both ma and mb). After
normalization, ma, mb ∈ [2^52, 2^53), so the true quotient ma/mb ∈ [1/2, 2)
and fits in 56 bits with 55 fractional bits.

The 56-iteration restoring-division loop maintains the invariant
`r < 2·mb` before each iteration:
  * Initial: r = ma < 2^53 ≤ 2·mb (since mb ≥ 2^52).
  * Per-iteration: subtract mb if r ≥ mb (so r < mb), then shift left by 1
    (so r < 2·mb).
Each iteration extracts one quotient bit (whether the subtraction fired)
and shifts it into q. After 56 iterations, q is the 56-bit truncated
quotient with leading 1 at bit 54 or 55 depending on whether ma ≥ mb.

The final remainder `r` carries the rounded-off tail. We collapse any
non-zero r into a single **sticky bit** OR'd into the quotient LSB. This
preserves round-to-nearest-even: `_sf_round_and_pack` reads guard / round
/ sticky from wr's low bits to compute the correctly-rounded result.

Then a single normalization shift moves the leading 1 from bit 54 to
bit 55 if ma < mb. CLZ-based subnormal renormalization handles the case
where the result exponent went below the subnormal threshold. Finally
`_sf_round_and_pack` produces the IEEE 754 binary64 result.

The select chain at the bottom handles NaN / Inf / zero edge cases
branchlessly per IEEE 754: a/0 = ±Inf (with NaN if a is also 0),
0/b = ±0, Inf/finite = ±Inf, finite/Inf = ±0, NaN propagates with
quieted payload.

Tested bit-exactly against Base./ over 5000 randomly-drawn UInt64 pairs
(test/test_9x75_softfloat_raw_bits_sweep.jl) plus the canonical edge
cases in test/test_softfdiv*.jl and test/test_m63k_softfloat_strict_bits.jl.
"""
@inline function soft_fdiv(a::UInt64, b::UInt64)::UInt64
    BIAS      = Int64(1023)

    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    sb = b >> 63
    eb = (b >> 52) & UInt64(0x7FF)
    fb = b & FRAC_MASK

    result_sign = sa ⊻ sb

    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    a_inf = (ea == UInt64(0x7FF)) & (fa == UInt64(0))
    b_inf = (eb == UInt64(0x7FF)) & (fb == UInt64(0))
    a_zero = (ea == UInt64(0)) & (fa == UInt64(0))
    b_zero = (eb == UInt64(0)) & (fb == UInt64(0))

    inf_result = (result_sign << 63) | INF_BITS
    zero_result = result_sign << 63

    ma = ifelse(ea != UInt64(0), fa | IMPLICIT, fa)
    mb = ifelse(eb != UInt64(0), fb | IMPLICIT, fb)
    ea_eff = ifelse(ea != UInt64(0), Int64(ea), Int64(1))
    eb_eff = ifelse(eb != UInt64(0), Int64(eb), Int64(1))

    # Bennett-r6e3: pre-normalize subnormal operands so leading 1 is at bit 52.
    # The 56-bit restoring-division loop below requires ma, mb ∈ [2^52, 2^53)
    # so that the quotient ma/mb ∈ [1/2, 2) fits in 56 bits. For subnormal
    # inputs, ma or mb has its leading 1 below bit 52; without this step the
    # loop overflows and the result's low 52 bits zero out.
    # No-op for already-normalized inputs (normal operand, or zero — zero is
    # caught by the final select chain regardless).
    (ma, ea_eff) = _sf_normalize_to_bit52(ma, ea_eff)
    (mb, eb_eff) = _sf_normalize_to_bit52(mb, eb_eff)

    result_exp = ea_eff - eb_eff + BIAS

    # ── Mantissa division: produce quotient with leading 1 at bit 55 ──
    # We want Q = (ma / mb) in 56-bit fixed point with 55 fractional bits.
    # This means Q = floor(ma * 2^55 / mb) approximately.
    # Since ma << 55 would overflow UInt64, use restoring division:
    # Start with r = ma, iterate 56 times, each time checking if r >= mb,
    # shifting quotient bit in, and shifting remainder.
    q = UInt64(0)
    r = ma  # start with full mantissa as initial remainder
    for i in 0:55
        # Check if current remainder can subtract divisor
        fits = r >= mb
        r = ifelse(fits, r - mb, r)
        q = (q << 1) | ifelse(fits, UInt64(1), UInt64(0))
        # Shift remainder left for next iteration (multiply by 2)
        r = r << 1
    end

    # Sticky from remainder
    sticky = ifelse(r != UInt64(0), UInt64(1), UInt64(0))
    wr = q | sticky

    # ── Normalize: leading 1 should be at bit 55 ──
    # If ma >= mb, leading 1 is at bit 55. If ma < mb, at bit 54.
    need_shift = (wr >> 55) == UInt64(0)
    wr = ifelse(need_shift, wr << 1, wr)
    result_exp = ifelse(need_shift, result_exp - Int64(1), result_exp)

    # ── Normalize (subnormal CLZ) ──
    (wr, result_exp) = _sf_normalize_clz(wr, result_exp)

    # ── Subnormal result ──
    (wr, result_exp, flushed_result, subnormal, flush_to_zero) =
        _sf_handle_subnormal(wr, result_exp, result_sign)

    # ── Round + pack ──
    # Bennett-ardf / U138: 2nd tuple position (overflow_result) is dead —
    # the overflow flags fire `inf_result` directly via the select chain
    # below, so the round-and-pack overflow value is unused. Discard
    # explicitly with `_` rather than the prior named-but-unused binding.
    (normal_result, _, exp_overflow, exp_overflow_after_round) =
        _sf_round_and_pack(wr, result_exp, result_sign)

    # ── Select chain ──
    result = normal_result
    result = ifelse(exp_overflow | exp_overflow_after_round, inf_result, result)
    result = ifelse(subnormal & flush_to_zero, flushed_result, result)
    # 0/0 and Inf/Inf are invalid — emit x86 INDEF (Bennett-r84x / U08).
    result = ifelse(a_zero & b_zero, INDEF, result)
    result = ifelse(a_zero & (!b_zero), zero_result, result)
    result = ifelse(b_zero & (!a_zero), inf_result, result)
    result = ifelse(a_inf & b_inf, INDEF, result)
    result = ifelse(a_inf & (!b_inf), inf_result, result)
    result = ifelse(b_inf & (!a_inf), zero_result, result)
    result = ifelse(a_nan | b_nan, _sf_propagate_nan2(a, b, a_nan, b_nan), result)

    return result
end
