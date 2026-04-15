"""
IEEE 754 Float32 ↔ Float64 precision conversion on raw bit patterns.

`soft_fpext`:   UInt32 (Float32) → UInt64 (Float64). Always exact
(Float64 precision strictly exceeds Float32's), including subnormal Float32
inputs which become normal Float64 (the Float64 exponent range covers all
Float32 subnormals as normals).

`soft_fptrunc`: UInt64 (Float64) → UInt32 (Float32). Round-nearest-even.
Handles overflow to ±Inf (value magnitude > floatmax(Float32)), underflow
to Float32 subnormal or ±0, and the rounding carry-out that can bump a
result from largest-subnormal to smallest-normal or from one exponent to
the next.

Both are fully branchless — all paths computed unconditionally, selected
via `ifelse`.
"""

"""
    soft_fpext(a::UInt32) -> UInt64

Widen Float32 bit pattern to Float64 bit pattern. Always exact.
Bit-exact with Julia's `Float64(::Float32)`.
"""
@inline function soft_fpext(a::UInt32)::UInt64
    sa = UInt64(a >> 31)                         # sign (1 bit)
    ea = (a >> 23) & UInt32(0xFF)                # biased exp (8 bits, bias 127)
    fa = a & UInt32(0x7FFFFF)                    # fraction (23 bits)

    a_nan  = (ea == UInt32(0xFF)) & (fa != UInt32(0))
    a_inf  = (ea == UInt32(0xFF)) & (fa == UInt32(0))
    a_zero = (ea == UInt32(0))    & (fa == UInt32(0))
    a_sub  = (ea == UInt32(0))    & (fa != UInt32(0))

    sign64 = sa << 63

    # ── Normal path ──
    # e_new = ea - 127 + 1023 = ea + 896
    # f_new = fa << (52 - 23) = fa << 29
    e_normal = UInt64(ea) + UInt64(896)
    f_normal = UInt64(fa) << 29
    normal_result = sign64 | (e_normal << 52) | f_normal

    # ── Subnormal Float32 → normal Float64 ──
    # A Float32 subnormal has value fa × 2^-149; Float64 can represent this
    # as a normal (biased exp ≥ 874). Normalize the 23-bit fraction to put
    # its leading 1 at bit 52, then compute the biased Float64 exponent.
    #
    # Derivation: with shift count `c` (to move leading bit from position p
    # to bit 52, so c = 52 - p), the value = m_norm × 2^(-149 - c), matching
    # Float64 normal form m_norm × 2^(e_unb - 52). Solving: e_biased = 925 + e_final
    # where e_final is `_sf_normalize_to_bit52`'s returned (Int64) exponent
    # when started at 1.
    (m64_sub, e_final) = _sf_normalize_to_bit52(UInt64(fa), Int64(1))
    e_sub = UInt64(Int64(925) + e_final)
    f_sub = m64_sub & FRAC_MASK                  # strip implicit bit 52
    subnormal_result = sign64 | (e_sub << 52) | f_sub

    # ── NaN / Inf / Zero ──
    # Hardware fpext preserves the NaN payload by left-shifting 29 bits.
    # Quiet-bit position maps correctly: Float32 bit 22 → Float64 bit 51.
    nan_result  = sign64 | UInt64(0x7FF0000000000000) | (UInt64(fa) << 29)
    inf_result  = sign64 | UInt64(0x7FF0000000000000)
    zero_result = sign64

    # ── Select chain ──
    result = normal_result
    result = ifelse(a_sub,  subnormal_result, result)
    result = ifelse(a_zero, zero_result, result)
    result = ifelse(a_inf,  inf_result, result)
    result = ifelse(a_nan,  nan_result, result)
    return result
end

"""
    soft_fptrunc(a::UInt64) -> UInt32

Narrow Float64 bit pattern to Float32 bit pattern with round-nearest-even.
Bit-exact with Julia's `Float32(::Float64)`.

Handles:
- Overflow (magnitude > floatmax(Float32)) → ±Inf
- Normal F64 → normal F32 (drop 29 low fraction bits, round-nearest-even)
- Normal F64 in Float32-subnormal range → F32 subnormal (shift mantissa
  right by `30 - e_new` bits including implicit 1, round)
- Float64 subnormal input → ±0 (all below Float32 min)
- NaN / Inf / ±0 → standard IEEE conversions
"""
@inline function soft_fptrunc(a::UInt64)::UInt32
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK

    a_nan    = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_inf    = (ea == UInt64(0x7FF)) & (fa == UInt64(0))
    a_zero   = (ea == UInt64(0))     & (fa == UInt64(0))
    a_f64sub = (ea == UInt64(0))     & (fa != UInt64(0))

    sign32 = UInt32(sa) << 31

    # Target biased Float32 exp = ea - 896 (bias diff 1023 - 127).
    e_new = Int64(ea) - Int64(896)

    # ── Normal-output path (e_new ∈ [1, 254]) ──
    # Drop 29 low bits of fa, round-nearest-even. Carry-out may bump exp.
    dropped = fa & ((UInt64(1) << 29) - UInt64(1))
    f_top = UInt32(fa >> 29)                             # top 23 bits of fa
    round_bit = (dropped >> 28) & UInt64(1)
    sticky_mask = (UInt64(1) << 28) - UInt64(1)
    sticky = ifelse((dropped & sticky_mask) != UInt64(0), UInt64(1), UInt64(0))
    round_up_n = (round_bit == UInt64(1)) &
                 ((sticky == UInt64(1)) | ((UInt64(f_top) & UInt64(1)) != UInt64(0)))
    f_rounded = f_top + ifelse(round_up_n, UInt32(1), UInt32(0))
    mant_of = f_rounded == UInt32(0x800000)              # carry into bit 23
    f_final_n = ifelse(mant_of, UInt32(0), f_rounded)
    e_final_n = e_new + ifelse(mant_of, Int64(1), Int64(0))
    overflow = e_final_n >= Int64(255)
    normal_result = sign32 | (UInt32(e_final_n & Int64(0xFF)) << 23) | f_final_n

    # ── Subnormal-output path (e_new ∈ [-23, 0]) ──
    # Shift the full mantissa (2^52 | fa, 53 bits including implicit 1)
    # right by (30 - e_new) bits total. Round-nearest-even.
    # For e_new << 0 the shift exceeds mantissa width and result is 0 after
    # rounding (the Kahan no-midpoint argument applies — half-ULP ties round
    # to even = 0 here since f_top=0).
    m_full = fa | UInt64(0x0010000000000000)             # 2^52 | fa
    shift_amt_sub = Int64(30) - e_new                    # ≥ 30 for e_new ≤ 0
    shift_sub = UInt64(clamp(shift_amt_sub, Int64(1), Int64(63)))
    # Truncate to UInt32 (upper bits safely discarded: for e_new > 0 the
    # subnormal branch is not selected, so we only need to avoid crashing).
    f_top_sub = (m_full >> shift_sub) % UInt32
    round_bit_s = (m_full >> (shift_sub - UInt64(1))) & UInt64(1)
    sticky_mask_s = (UInt64(1) << (shift_sub - UInt64(1))) - UInt64(1)
    sticky_s = ifelse((m_full & sticky_mask_s) != UInt64(0), UInt64(1), UInt64(0))
    round_up_s = (round_bit_s == UInt64(1)) &
                 ((sticky_s == UInt64(1)) | ((UInt64(f_top_sub) & UInt64(1)) != UInt64(0)))
    f_rounded_s = f_top_sub + ifelse(round_up_s, UInt32(1), UInt32(0))
    # Carry-out from subnormal mantissa: rounds up to smallest normal Float32 (exp=1, frac=0).
    sub_to_normal = f_rounded_s == UInt32(0x800000)
    f_final_s = ifelse(sub_to_normal, UInt32(0), f_rounded_s)
    e_final_s = ifelse(sub_to_normal, UInt32(1), UInt32(0))
    subnormal_result = sign32 | (e_final_s << 23) | f_final_s

    # ── NaN / Inf / Zero ──
    # NaN: preserve sign + top payload bits (fa >> 29 covers bits 51..29 of Float64
    # fraction, landing in bits 22..0 of Float32 fraction). Force quiet bit 22 set
    # so signaling NaNs canonicalize to quiet (IEEE conversion rule).
    nan_payload = UInt32(fa >> 29) | UInt32(0x00400000)
    nan_result  = sign32 | UInt32(0x7F800000) | nan_payload
    inf_result  = sign32 | UInt32(0x7F800000)
    zero_result = sign32

    # ── Select chain ──
    result = normal_result
    result = ifelse(e_new <= Int64(0), subnormal_result, result)    # subnormal output
    result = ifelse(overflow, inf_result, result)                    # overflow to Inf
    result = ifelse(a_f64sub, zero_result, result)                   # F64 subnormal → 0
    result = ifelse(a_zero, zero_result, result)                     # ±0
    result = ifelse(a_inf, inf_result, result)                       # ±Inf
    result = ifelse(a_nan, nan_result, result)                       # NaN (last)
    return result
end
