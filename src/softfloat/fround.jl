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

"""
    soft_round(a::UInt64) -> UInt64

IEEE 754 `roundToIntegralTiesToEven` on Float64 bit patterns. Equivalent
to `Base.round(::Float64)` (NOT `Base.round(Int, ::Float64)` which
returns an Integer; this returns the rounded value as a Float64 bit
pattern).

The "round half to even" rule:
  * `round(0.5)  = 0.0`  (tie → even)
  * `round(1.5)  = 2.0`  (tie → even)
  * `round(2.5)  = 2.0`  (tie → even)
  * `round(-0.5) = -0.0` (tie → even, sign preserved)
  * `round(0.7)  = 1.0`  (closer to 1)
  * `round(0.3)  = 0.0`  (closer to 0)

## Algorithm

Special-case shape mirrors `soft_trunc` / `soft_floor` / `soft_ceil`:
NaN passes through quietened, ±Inf passes through unchanged, |x| above
2^52 is already integral, |x| < 0.5 → ±0, |x| == 0.5 → ±0 (tie-to-even),
|x| in (0.5, 1.0) → ±1.0.

For the general |x| in [1.0, 2^52) case, the bit-twiddle:
  * `frac_bits = 1075 - exp` is the number of mantissa bits BELOW the
    integer part (in `[1, 52]` for this range).
  * `truncated_m = m & ~((1 << frac_bits) - 1)` clears the fractional
    bits, leaving the trunc-toward-zero mantissa.
  * `round_bit = bit at (frac_bits - 1)` and `sticky = any bit below
    that` together encode the magnitude of the dropped fraction.
  * `lsb_after_trunc = bit at frac_bits` of the truncated mantissa is
    the LSB of the integer part — needed for the tie-to-even check.
  * `round_up := round_bit AND (sticky OR lsb_after_trunc == 1)` —
    rounds up if the dropped fraction exceeds 0.5, OR if it equals
    exactly 0.5 and the integer part is currently odd (round to even).
  * On round-up, add `1 << frac_bits` to the truncated mantissa; if
    that overflows bit 53, shift right and bump the exponent (handles
    e.g. `round(1.999...) = 2.0`).

Tested bit-exactly against `Base.round(Float64)` over edge cases
(ties, negatives, subnormals, near-2^52, NaN with payload, ±Inf, ±0)
plus a 5,000-input random UInt64 raw-bits sweep.
(Bennett-2hhx / U136.)
"""
function soft_round(a::UInt64)::UInt64
    sign = a & UInt64(0x8000000000000000)
    abs_a = a & UInt64(0x7FFFFFFFFFFFFFFF)
    exp = Int64((abs_a >> 52) & UInt64(0x7ff))

    # ── Special cases (NaN / Inf passthrough) ────────────────────────
    is_special = exp == Int64(0x7ff)
    is_nan_input = is_special & ((abs_a & FRAC_MASK) != UInt64(0))
    special_result = ifelse(is_nan_input, a | QUIET_BIT, a)

    # ── |x| < 0.5 → ±0 (covers subnormals + zero) ────────────────────
    is_below_half = exp < Int64(1022)

    # ── |x| == 0.5 exactly → ±0 (tie-to-even, 0 is even) ─────────────
    is_exactly_half = (exp == Int64(1022)) & ((abs_a & FRAC_MASK) == UInt64(0))

    # ── |x| in (0.5, 1.0) → ±1.0 (closer to 1) ───────────────────────
    is_in_half_to_one = (exp == Int64(1022)) & ((abs_a & FRAC_MASK) != UInt64(0))
    one_with_sign = sign | reinterpret(UInt64, 1.0)

    # ── |x| >= 2^52 → already integer ────────────────────────────────
    is_integer = exp >= Int64(1075)

    # ── General case: |x| in [1.0, 2^52), exp in [1023, 1074] ────────
    # frac_bits in [1, 52]. clamp guards the unselected branches at
    # boundary exponents.
    frac_bits_raw = Int64(1075) - exp
    frac_bits = clamp(frac_bits_raw, Int64(1), Int64(52))
    round_bit_pos = frac_bits - Int64(1)

    m = (abs_a & FRAC_MASK) | IMPLICIT  # add implicit leading 1
    trunc_mask = ~((UInt64(1) << frac_bits) - UInt64(1))
    truncated_m = m & trunc_mask

    round_bit = (m >> round_bit_pos) & UInt64(1)
    sticky_mask = (UInt64(1) << round_bit_pos) - UInt64(1)
    sticky = (m & sticky_mask) != UInt64(0)
    lsb_after_trunc = (truncated_m >> frac_bits) & UInt64(1)

    round_up = (round_bit == UInt64(1)) &
               (sticky | (lsb_after_trunc == UInt64(1)))

    incr = UInt64(1) << frac_bits
    rounded_m = truncated_m + ifelse(round_up, incr, UInt64(0))

    # Carry into exponent: e.g. round(1.999...) → 2.0 sets bit 53.
    has_carry = (rounded_m >> 53) != UInt64(0)
    final_m = ifelse(has_carry, rounded_m >> 1, rounded_m)
    final_exp = ifelse(has_carry, exp + Int64(1), exp)

    normal_result = sign |
                    (UInt64(final_exp) << 52) |
                    (final_m & FRAC_MASK)

    # ── Selection chain ──────────────────────────────────────────────
    result = ifelse(is_special, special_result,
             ifelse(is_below_half | is_exactly_half, sign,
             ifelse(is_in_half_to_one, one_with_sign,
             ifelse(is_integer, a,
                    normal_result))))
    return result
end
