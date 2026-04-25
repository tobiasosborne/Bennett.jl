"""
    soft_fsub(a::UInt64, b::UInt64) -> UInt64

IEEE 754 double-precision subtraction on raw bit patterns.

Implemented as `a + (-b)` via `soft_fadd` and `soft_fneg`, with a
guard for NaN operands: IEEE 754-2019 §6.2.3 requires NaN sign and
payload to propagate through arithmetic ops, but unconditionally
applying `soft_fneg` to a NaN operand would flip its sign bit before
`soft_fadd`'s NaN-input passthrough sees it.  The fix routes NaN-`b`
through `soft_fadd` unchanged so the propagated result preserves
the operand's original sign.

Bennett-r84x's NaN canonicalisation audit explicitly skipped fsub on
the assumption that fadd∘fneg would inherit correct NaN handling;
test_m63k_softfloat_strict_bits.jl Layer 2 caught the resulting
sign-flip on `normal − NaN`.
"""
function soft_fsub(a::UInt64, b::UInt64)::UInt64
    # NaN test: biased exponent all-ones AND fraction non-zero.
    ea_b = (b & EXP_MASK) >> 52
    fa_b =  b & FRAC_MASK
    b_is_nan = (ea_b == UInt64(0x7FF)) & (fa_b != UInt64(0))
    b_eff    = ifelse(b_is_nan, b, soft_fneg(b))
    return soft_fadd(a, b_eff)
end
