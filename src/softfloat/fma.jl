"""
    soft_fma(a::UInt64, b::UInt64, c::UInt64) -> UInt64

IEEE 754 double-precision fused multiply-add on raw bit patterns.
Single-rounded `round(a·b + c)`. Uses only integer operations.
Bit-exact with `Base.fma(::Float64, ::Float64, ::Float64)`.

Fully branchless: every path is computed unconditionally and results are
selected via `ifelse`. This ensures LLVM emits `select` instructions
(not `br`+`phi`), which is required for correct reversible circuit
compilation.

Algorithm: Berkeley SoftFloat 3 `s_mulAddF64.c` SOFTFLOAT_FAST_INT64 path,
ported branchless. 128-bit intermediate (two UInt64 limbs). The
`<<10` / `<<9` significand scaling is Hauser's — it places the normalized
product's leading 1 at bit 125 (of the 128-bit register), one bit below
the add-overflow detection boundary at bit 127.

Single rounding is the defining property of FMA: `round(a·b + c)` vs the
naïve `round(round(a·b) + c)`, which double-rounds and breaks bit-
exactness at round-half cases (Kahan single-rounding witness).

See `docs/design/soft_fma_consensus.md` for the full design, ground-truth
source citations (Berkeley SoftFloat 3 `s_mulAddF64.c`, musl `fma.c`,
IEEE 754-2019 §5.4.1), gate-count analysis, and novelty claim (first
IEEE 754 binary64 reversible FMA in the quantum/reversible literature).
"""
@inline function soft_fma(a::UInt64, b::UInt64, c::UInt64)::UInt64
    BIAS = Int64(1023)

    # ── Unpack ──────────────────────────────────────────────────────────
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    sb = b >> 63
    eb = (b >> 52) & UInt64(0x7FF)
    fb = b & FRAC_MASK
    sc = c >> 63
    ec = (c >> 52) & UInt64(0x7FF)
    fc = c & FRAC_MASK

    # ── Special-case predicates ─────────────────────────────────────────
    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan  = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    c_nan  = (ec == UInt64(0x7FF)) & (fc != UInt64(0))
    a_inf  = (ea == UInt64(0x7FF)) & (fa == UInt64(0))
    b_inf  = (eb == UInt64(0x7FF)) & (fb == UInt64(0))
    c_inf  = (ec == UInt64(0x7FF)) & (fc == UInt64(0))
    a_zero = (ea == UInt64(0)) & (fa == UInt64(0))
    b_zero = (eb == UInt64(0)) & (fb == UInt64(0))
    c_zero = (ec == UInt64(0)) & (fc == UInt64(0))

    sign_prod      = sa ⊻ sb
    any_nan        = a_nan | b_nan | c_nan
    prod_is_inf    = (a_inf | b_inf) & !(a_zero | b_zero)
    inf_times_zero = (a_inf & b_zero) | (b_inf & a_zero)
    inf_clash      = prod_is_inf & c_inf & (sign_prod != sc)
    prod_is_zero   = a_zero | b_zero

    # ── Mantissas with implicit 1, pre-normalize subnormals ─────────────
    ma     = ifelse(ea != UInt64(0), fa | IMPLICIT, fa)
    mb     = ifelse(eb != UInt64(0), fb | IMPLICIT, fb)
    mc     = ifelse(ec != UInt64(0), fc | IMPLICIT, fc)
    ea_eff = ifelse(ea != UInt64(0), Int64(ea), Int64(1))
    eb_eff = ifelse(eb != UInt64(0), Int64(eb), Int64(1))
    ec_eff = ifelse(ec != UInt64(0), Int64(ec), Int64(1))
    (ma, ea_eff) = _sf_normalize_to_bit52(ma, ea_eff)
    (mb, eb_eff) = _sf_normalize_to_bit52(mb, eb_eff)
    (mc, ec_eff) = _sf_normalize_to_bit52(mc, ec_eff)

    # ── Berkeley scaling: ma,mb << 10 (leading 1 at bit 62); mc << 9 ────
    ma_s = ma << 10
    mb_s = mb << 10
    mc_s = mc << 9

    # ── 128-bit product ─────────────────────────────────────────────────
    (p_hi, p_lo) = _sf_widemul_u64_to_128(ma_s, mb_s)
    # Leading 1 at bit 124 or 125 of the 128-bit product.
    expZ = ea_eff + eb_eff - Int64(0x3FE)

    # Berkeley line 122: if top of p_hi has bit 61 clear (= product < 2^125),
    # double so that leading 1 lands at bit 125 unconditionally.
    prod_lead_low = p_hi < UInt64(0x2000000000000000)   # 2^61
    (p_hi_d, p_lo_d) = _shl128_by1(p_hi, p_lo)
    p_hi = ifelse(prod_lead_low, p_hi_d, p_hi)
    p_lo = ifelse(prod_lead_low, p_lo_d, p_lo)
    expZ = ifelse(prod_lead_low, expZ - Int64(1), expZ)
    # Now product's leading 1 is at bit 61 of p_hi (= bit 125 of full reg).

    same_sign = sign_prod == sc
    expDiff   = expZ - ec_eff
    expDiff_neg = expDiff < Int64(0)

    # ── Alignment ───────────────────────────────────────────────────────
    # Product side: if expDiff < 0, shift product right-jam by -expDiff
    # (Berkeley special: if expDiff == -1 AND opposite-sign, use >>1 with
    # sticky to preserve 1 extra bit for cancellation renormalization —
    # line 144 precision-preservation trick).
    (p_rj_hi, p_rj_lo)     = _shiftRightJam128(p_hi, p_lo, -expDiff)
    (p_shr1_hi, p_shr1_lo) = _shr128jam_by1(p_hi, p_lo)
    use_short_shift = (expDiff == Int64(-1)) & !same_sign
    p_right_hi = ifelse(use_short_shift, p_shr1_hi, p_rj_hi)
    p_right_lo = ifelse(use_short_shift, p_shr1_lo, p_rj_lo)

    p_side_hi = ifelse(expDiff_neg, p_right_hi, p_hi)
    p_side_lo = ifelse(expDiff_neg, p_right_lo, p_lo)

    # C side: if expDiff > 0, shift (mc_s, 0) right-jam by expDiff.
    # For expDiff <= 0, c is unshifted at (mc_s, 0).
    (c_right_hi, c_right_lo) = _shiftRightJam128(mc_s, UInt64(0), expDiff)
    c_side_hi = ifelse(expDiff_neg, mc_s, c_right_hi)
    c_side_lo = ifelse(expDiff_neg, UInt64(0), c_right_lo)

    # Result exponent frame (c dominates if expDiff < 0, else product).
    expR = ifelse(expDiff_neg, ec_eff, expZ)

    # ── Add or subtract ─────────────────────────────────────────────────
    (sum_hi, sum_lo)  = _add128(p_side_hi, p_side_lo, c_side_hi, c_side_lo)
    (diff_hi, diff_lo) = _sub128(p_side_hi, p_side_lo, c_side_hi, c_side_lo)
    wr_hi = ifelse(same_sign, sum_hi, diff_hi)
    wr_lo = ifelse(same_sign, sum_lo, diff_lo)

    # Opposite-sign underflow (subtracted larger from smaller): negate
    # and flip the result sign.
    underflow = !same_sign & ((wr_hi >> 63) != UInt64(0))
    (neg_hi, neg_lo) = _neg128(wr_hi, wr_lo)
    wr_hi = ifelse(underflow, neg_hi, wr_hi)
    wr_lo = ifelse(underflow, neg_lo, wr_lo)

    # Result sign: if opposite-sign subtraction underflowed (we subtracted
    # larger from smaller, then negated), the result takes c's sign;
    # otherwise it takes the product's sign. For same-sign add, underflow
    # is always false, so result_sign = sign_prod = sc.
    result_sign = ifelse(underflow, sc, sign_prod)

    # ── Complete cancellation (opposite-sign, result exactly zero) ──────
    complete_cancel = !same_sign & (wr_hi == UInt64(0)) & (wr_lo == UInt64(0))

    # ── Renormalize ─────────────────────────────────────────────────────
    # Target: leading 1 at bit 61 of wr_hi_folded. This matches Berkeley's
    # post-normalize convention (product leading 1 at bit 125 of 128-bit
    # register = bit 61 of hi limb) so `expR` stays correctly biased.

    # Stage A: if wr_hi == 0, fold wr_lo up. Only possible after opposite-
    # sign subtraction with massive cancellation.
    hi_zero       = wr_hi == UInt64(0)
    wr_hi_folded  = ifelse(hi_zero, wr_lo, wr_hi)
    wr_lo_folded  = ifelse(hi_zero, UInt64(0), wr_lo)
    expR          = ifelse(hi_zero, expR - Int64(64), expR)

    # Stage B: if bit 63 of wr_hi_folded is set (possible post-fold when
    # wr_lo had its MSB set), shift right 1 with sticky, expR += 1.
    hi_bit63 = (wr_hi_folded >> 63) != UInt64(0)
    (wr_hi_s63, wr_lo_s63) = _shr128jam_by1(wr_hi_folded, wr_lo_folded)
    wr_hi_folded = ifelse(hi_bit63, wr_hi_s63, wr_hi_folded)
    wr_lo_folded = ifelse(hi_bit63, wr_lo_s63, wr_lo_folded)
    expR         = ifelse(hi_bit63, expR + Int64(1), expR)

    # Stage C: if bit 62 of wr_hi_folded is set (same-sign add carry from
    # bit 61 → bit 62, or post-B bit 63 → bit 62), shift right 1, expR += 1.
    hi_bit62 = (wr_hi_folded >> 62) != UInt64(0)
    (wr_hi_s62, wr_lo_s62) = _shr128jam_by1(wr_hi_folded, wr_lo_folded)
    wr_hi_folded = ifelse(hi_bit62, wr_hi_s62, wr_hi_folded)
    wr_lo_folded = ifelse(hi_bit62, wr_lo_s62, wr_lo_folded)
    expR         = ifelse(hi_bit62, expR + Int64(1), expR)

    # Stage D: 128-bit CLZ to bring leading 1 back to bit 61 of hi.
    # Bits from wr_lo_folded migrate up into wr_hi_folded at each shift
    # stage so no precision is lost. Substitute (1, 0) for the all-zero
    # case to keep the helper in its precondition domain; complete_cancel
    # in the select chain overrides any resulting garbage.
    both_zero = (wr_hi_folded == UInt64(0)) & (wr_lo_folded == UInt64(0))
    wr_hi_for_clz = ifelse(both_zero, UInt64(1), wr_hi_folded)
    wr_lo_for_clz = ifelse(both_zero, UInt64(0), wr_lo_folded)
    (wr_hi_norm, wr_lo_norm, expR) = _sf_clz128_to_hi_bit61(wr_hi_for_clz, wr_lo_for_clz, expR)

    # ── Collapse to 56-bit working format ───────────────────────────────
    # Leading 1 at bit 61 of wr_hi_norm → need leading 1 at bit 55.
    # Shift right 6; fold bits 0–5 of wr_hi_norm + all of wr_lo_norm
    # into sticky (bit 0 of the 56-bit payload).
    low6_nonzero = (wr_hi_norm & UInt64(0x3F)) != UInt64(0)
    lo_nonzero   = wr_lo_norm != UInt64(0)
    sticky = ifelse(low6_nonzero | lo_nonzero, UInt64(1), UInt64(0))
    wr_56  = ((wr_hi_norm >> 6) & ((UInt64(1) << 56) - UInt64(1))) | sticky

    # ── Subnormal handling + round + pack (existing helpers) ────────────
    (wr_56, expR, flushed, subnormal, flush_to_zero) =
        _sf_handle_subnormal(wr_56, expR, result_sign)
    (normal_result, overflow_result, exp_overflow, exp_overflow_after_round) =
        _sf_round_and_pack(wr_56, expR, result_sign)

    # ── Zero-product result: return c, with signed-zero combine when c==0.
    # Under round-to-nearest-even, fma(-0, +0, +0) = +0; fma(-0, +0, -0) = -0;
    # fma(+0, +0, +0) = +0; opposite-sign zero combine = +0.
    prod_zero_c_zero_result = ifelse(sign_prod == sc, c, UInt64(0))
    prod_zero_result        = ifelse(c_zero, prod_zero_c_zero_result, c)

    # ── Final priority select chain (last-write-wins; NaN strictly last) ─
    result = normal_result
    result = ifelse(exp_overflow | exp_overflow_after_round, overflow_result, result)
    result = ifelse(subnormal & flush_to_zero, flushed, result)
    result = ifelse(complete_cancel, UInt64(0), result)
    result = ifelse(prod_is_zero, prod_zero_result, result)
    result = ifelse(c_inf & !prod_is_inf, c, result)
    result = ifelse(prod_is_inf, (sign_prod << 63) | INF_BITS, result)
    result = ifelse(inf_clash, QNAN, result)
    result = ifelse(inf_times_zero, QNAN, result)
    result = ifelse(any_nan, QNAN, result)
    return result
end
