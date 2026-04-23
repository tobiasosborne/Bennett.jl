"""
    soft_fdiv(a::UInt64, b::UInt64) -> UInt64

IEEE 754 double-precision division on raw bit patterns.
Uses only integer operations. Bit-exact with hardware `/`.
Fully branchless.
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
    (normal_result, _overflow_result, exp_overflow, exp_overflow_after_round) =
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
