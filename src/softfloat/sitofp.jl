"""
    soft_sitofp(a::UInt64)::UInt64

Convert signed Int64 (as UInt64 bit pattern) to IEEE 754 double-precision float
(as UInt64 bit pattern). Branchless implementation for reversible circuit compilation.

Algorithm:
1. Extract sign (bit 63), compute absolute value
2. Find position of MSB (count leading zeros)
3. Compute exponent = 1023 + 62 - clz
4. Shift mantissa: align MSB to bit 52 (the implicit 1-bit)
5. Round-to-nearest-even on the lost bits
6. Pack sign + exponent + mantissa
"""
@inline function soft_sitofp(a::UInt64)::UInt64
    # Handle zero
    is_zero = a == UInt64(0)

    # Extract sign and absolute value
    sign = (a >> 63) & UInt64(1)
    # Two's complement absolute value: if negative, negate
    neg = (~a) + UInt64(1)
    magnitude = ifelse(sign == UInt64(1), neg, a)

    # Count leading zeros (branchless binary search, 6 stages for 64-bit)
    clz = UInt64(0)
    tmp = magnitude
    # Stage 1: check top 32 bits
    top32_zero = (tmp >> 32) == UInt64(0)
    clz = ifelse(top32_zero, clz + UInt64(32), clz)
    tmp = ifelse(top32_zero, tmp << 32, tmp)
    # Stage 2: check top 16
    top16_zero = (tmp >> 48) == UInt64(0)
    clz = ifelse(top16_zero, clz + UInt64(16), clz)
    tmp = ifelse(top16_zero, tmp << 16, tmp)
    # Stage 3: check top 8
    top8_zero = (tmp >> 56) == UInt64(0)
    clz = ifelse(top8_zero, clz + UInt64(8), clz)
    tmp = ifelse(top8_zero, tmp << 8, tmp)
    # Stage 4: check top 4
    top4_zero = (tmp >> 60) == UInt64(0)
    clz = ifelse(top4_zero, clz + UInt64(4), clz)
    tmp = ifelse(top4_zero, tmp << 4, tmp)
    # Stage 5: check top 2
    top2_zero = (tmp >> 62) == UInt64(0)
    clz = ifelse(top2_zero, clz + UInt64(2), clz)
    tmp = ifelse(top2_zero, tmp << 2, tmp)
    # Stage 6: check top 1
    top1_zero = (tmp >> 63) == UInt64(0)
    clz = ifelse(top1_zero, clz + UInt64(1), clz)

    # Exponent: biased (1023 + bit_position_of_MSB)
    # MSB position = 63 - clz (for non-zero). Exponent = 1023 + 63 - clz = 1086 - clz
    exponent = UInt64(1086) - clz

    # Shift magnitude so MSB is at bit 63.
    # Left-shift by clz puts MSB at bit 63. Then bits [62:11] are the mantissa
    # (bit 63 is the implicit 1-bit, not stored in IEEE 754).
    shift_clamped = ifelse(clz > UInt64(63), UInt64(63), clz)
    shifted = magnitude << shift_clamped

    # Mantissa = bits [62:11] of shifted (52 bits after the implicit 1)
    mantissa = (shifted >> 11) & UInt64(0x000FFFFFFFFFFFFF)

    # Round-to-nearest-even: check bit 10 (round bit), bits 9:0 (sticky)
    # After shifting MSB to bit 63: mantissa bits are [62:11], round bit is [10],
    # sticky bits are [9:0]
    round_bit = (shifted >> 10) & UInt64(1)
    sticky = shifted & UInt64(0x3FF)  # bits 9:0
    # Round up if round_bit=1 AND (sticky!=0 OR mantissa bit 0 = 1)
    round_up = round_bit & (ifelse(sticky != UInt64(0), UInt64(1), UInt64(0)) | (mantissa & UInt64(1)))
    mantissa = mantissa + round_up

    # Handle mantissa overflow from rounding (mantissa becomes 2^52 → increment exponent)
    mant_overflow = (mantissa >> 52) & UInt64(1)
    exponent = exponent + mant_overflow
    mantissa = mantissa & UInt64(0x000FFFFFFFFFFFFF)  # mask back to 52 bits

    # Pack result
    result = (sign << 63) | (exponent << 52) | mantissa

    # Zero → +0.0
    result = ifelse(is_zero, UInt64(0), result)

    return result
end

"""
    soft_uitofp(a::UInt64)::UInt64

Convert unsigned UInt64 to IEEE 754 double-precision float (as UInt64 bit
pattern), round-to-nearest-even. Bit-exact with `Float64(::UInt64)`.
Branchless; reuses `soft_sitofp`.

Bennett-s6d6: `uitofp i64` used to be routed through `soft_sitofp`, which
reads bit 63 as a sign, so every input ≥ 2^63 came out negative.

Algorithm (the standard halve-with-sticky trick): for a ≥ 2^63, convert
`v = (a >> 1) | (a & 1)` — which is < 2^63, so the signed converter sees a
non-negative value — and add 1 to the biased exponent (×2). The OR keeps the
dropped bit as a sticky bit: v has 63 significant bits and rounds at bit 9,
so bit 0 only ever feeds the sticky, and RNE is preserved exactly. The ×2
cannot overflow (the largest result is 2^64). For a < 2^63 this is plain
`soft_sitofp(a)`.
"""
@inline function soft_uitofp(a::UInt64)::UInt64
    hi = (a >> 63) & UInt64(1)
    v = ifelse(hi == UInt64(1), (a >> 1) | (a & UInt64(1)), a)
    return soft_sitofp(v) + (hi << 52)
end
