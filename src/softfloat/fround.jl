"""
Branchless IEEE 754 floor/ceil/trunc on Float64 bit patterns.

All operations work by masking out fractional bits below the integer part.
The mask depends on the exponent: for exponent e (biased), the integer part
occupies bits [52-e+1023 : 52] of the mantissa. Bits below are fractional.

Branchless: uses ifelse throughout, no branches.
"""

"""
    soft_trunc(a::UInt64) -> UInt64

Truncate toward zero: remove fractional bits. Equivalent to trunc(Float64).
"""
function soft_trunc(a::UInt64)::UInt64
    sign = a & UInt64(0x8000000000000000)
    exp = Int64((a >> 52) & UInt64(0x7ff))

    # Special cases: NaN passes through quietened; Inf passes through as-is.
    # Both share biased exponent 0x7FF; NaN has a nonzero fraction, Inf has 0.
    # Per Bennett-r84x / U08 + IEEE 754-2019 §6.2.3, a signalling-NaN input
    # must be force-quieted by OR-ing bit 51. OR-ing QUIET_BIT unconditionally
    # on Inf would corrupt the encoding (Inf has fraction == 0, setting bit 51
    # makes it a NaN), so split the two.
    is_special = exp == Int64(0x7ff)
    is_nan_input = is_special & ((a & FRAC_MASK) != UInt64(0))
    special_result = ifelse(is_nan_input, a | QUIET_BIT, a)
    # |x| < 1.0 (biased exp < 1023) → trunc = ±0
    is_small = exp < Int64(1023)
    # |x| >= 2^52 (biased exp >= 1075) → already integer, return as-is
    is_integer = exp >= Int64(1075)

    # Number of fractional bits to mask: 1075 - exp (= 52 - (exp - 1023))
    frac_bits = Int64(1075) - exp
    # Clamp to [0, 52] for valid shift
    frac_bits_clamped = clamp(frac_bits, Int64(0), Int64(52))
    # Mask: clear the bottom frac_bits of the mantissa
    mask = ~((UInt64(1) << frac_bits_clamped) - UInt64(1))

    # Normal case: zero out fractional bits
    normal_result = a & mask

    # Select: special → special_result, small → ±0, integer → a, else → normal_result
    result = ifelse(is_special, special_result,
             ifelse(is_small, sign,
             ifelse(is_integer, a,
                    normal_result)))
    return result
end

"""
    soft_floor(a::UInt64) -> UInt64

Floor: round toward -∞. Equivalent to floor(Float64).
trunc(x) if x >= 0 or x is integer, else trunc(x) - 1.
"""
function soft_floor(a::UInt64)::UInt64
    sign = a & UInt64(0x8000000000000000)
    is_neg = sign != UInt64(0)

    truncated = soft_trunc(a)

    # If negative and has fractional part (truncated != a), subtract 1
    has_frac = truncated != a
    need_sub = is_neg & has_frac

    # Subtract 1.0 from truncated value using soft_fadd
    one_bits = reinterpret(UInt64, 1.0)
    neg_one_bits = one_bits | UInt64(0x8000000000000000)

    # floor = ifelse(need_sub, truncated - 1.0, truncated)
    sub_result = soft_fadd(truncated, neg_one_bits)
    return ifelse(need_sub, sub_result, truncated)
end

"""
    soft_ceil(a::UInt64) -> UInt64

Ceiling: round toward +∞. Equivalent to ceil(Float64).
trunc(x) if x <= 0 or x is integer, else trunc(x) + 1.
"""
function soft_ceil(a::UInt64)::UInt64
    sign = a & UInt64(0x8000000000000000)
    is_pos = sign == UInt64(0)

    truncated = soft_trunc(a)

    has_frac = truncated != a
    need_add = is_pos & has_frac

    one_bits = reinterpret(UInt64, 1.0)
    add_result = soft_fadd(truncated, one_bits)
    return ifelse(need_add, add_result, truncated)
end
