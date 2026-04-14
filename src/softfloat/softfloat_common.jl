"""
Shared branchless building blocks for IEEE 754 soft-float operations.
All functions are @inline to ensure Julia inlines them into the caller,
producing clean LLVM IR without call instructions for the reversible pipeline.
"""

# IEEE 754 double-precision constants
const FRAC_MASK = UInt64(0x000FFFFFFFFFFFFF)   # 52-bit stored fraction
const IMPLICIT  = UInt64(0x0010000000000000)   # bit 52 (implicit leading 1)
const EXP_MASK  = UInt64(0x7FF0000000000000)   # exponent field
const INF_BITS  = UInt64(0x7FF0000000000000)   # +Inf
const QNAN      = UInt64(0x7FF8000000000000)   # canonical quiet NaN

"""
    _sf_normalize_to_bit52(m, e) -> (m, e)

Normalize a mantissa so its leading 1 is at bit 52 (the IEEE 754 normalized
form). Decrement the effective exponent `e` by the shift count. Used by
`soft_fdiv` to pre-normalize subnormal operands before the restoring-division
loop, which assumes `ma, mb ∈ [2^52, 2^53)` so that the ratio fits in 56 bits
of precision. For an already-normalized input (bit 52 set), this is a no-op.

Precondition: `m` has no bits set above bit 52. All callers guarantee this
(subnormal inputs have `m < 2^52`; normal inputs have `m < 2^53` with bit 52
set, so already-normalized). `m == 0` yields a pathological result (63
shifts, no leading 1 found) but callers handle zero inputs via the select
chain before using `m`.

Six-stage branchless binary-search CLZ; structure mirrors `_sf_normalize_clz`
but the target bit is 52 instead of 55.
"""
@inline function _sf_normalize_to_bit52(m::UInt64, e::Int64)
    need32 = (m & (UInt64(0xFFFFFFFF) << 21)) == UInt64(0)
    m = ifelse(need32, m << 32, m)
    e = ifelse(need32, e - Int64(32), e)

    need16 = (m & (UInt64(0xFFFF) << 37)) == UInt64(0)
    m = ifelse(need16, m << 16, m)
    e = ifelse(need16, e - Int64(16), e)

    need8 = (m & (UInt64(0xFF) << 45)) == UInt64(0)
    m = ifelse(need8, m << 8, m)
    e = ifelse(need8, e - Int64(8), e)

    need4 = (m & (UInt64(0xF) << 49)) == UInt64(0)
    m = ifelse(need4, m << 4, m)
    e = ifelse(need4, e - Int64(4), e)

    need2 = (m & (UInt64(0x3) << 51)) == UInt64(0)
    m = ifelse(need2, m << 2, m)
    e = ifelse(need2, e - Int64(2), e)

    need1 = (m & (UInt64(1) << 52)) == UInt64(0)
    m = ifelse(need1, m << 1, m)
    e = ifelse(need1, e - Int64(1), e)

    return (m, e)
end

"""
    _sf_normalize_clz(wr, result_exp) -> (wr, result_exp)

Normalize working result so leading 1 is at bit 55.
Six-stage binary-search CLZ (count leading zeros).
"""
@inline function _sf_normalize_clz(wr::UInt64, result_exp::Int64)
    need32 = (wr & (UInt64(0xFFFFFFFF) << 24)) == UInt64(0)
    wr = ifelse(need32, wr << 32, wr)
    result_exp = ifelse(need32, result_exp - Int64(32), result_exp)

    need16 = (wr & (UInt64(0xFFFF) << 40)) == UInt64(0)
    wr = ifelse(need16, wr << 16, wr)
    result_exp = ifelse(need16, result_exp - Int64(16), result_exp)

    need8 = (wr & (UInt64(0xFF) << 48)) == UInt64(0)
    wr = ifelse(need8, wr << 8, wr)
    result_exp = ifelse(need8, result_exp - Int64(8), result_exp)

    need4 = (wr & (UInt64(0xF) << 52)) == UInt64(0)
    wr = ifelse(need4, wr << 4, wr)
    result_exp = ifelse(need4, result_exp - Int64(4), result_exp)

    need2 = (wr & (UInt64(0x3) << 54)) == UInt64(0)
    wr = ifelse(need2, wr << 2, wr)
    result_exp = ifelse(need2, result_exp - Int64(2), result_exp)

    need1 = (wr & (UInt64(1) << 55)) == UInt64(0)
    wr = ifelse(need1, wr << 1, wr)
    result_exp = ifelse(need1, result_exp - Int64(1), result_exp)

    return (wr, result_exp)
end

"""
    _sf_handle_subnormal(wr, result_exp, result_sign) -> (wr, result_exp, flushed_result)

Handle subnormal result (exponent underflow). Returns updated wr, result_exp,
and the flushed-to-zero result for use in the final select chain.
Also returns `subnormal` and `flush_to_zero` flags.
"""
@inline function _sf_handle_subnormal(wr::UInt64, result_exp::Int64, result_sign::UInt64)
    subnormal = result_exp <= Int64(0)
    shift_sub = Int64(1) - result_exp
    flush_to_zero = shift_sub >= Int64(56)
    shift_clamped = clamp(shift_sub, Int64(0), Int64(63))
    shift_u = UInt64(ifelse(flush_to_zero, Int64(0), shift_clamped))
    lost_mask_sub = (UInt64(1) << shift_u) - UInt64(1)
    lost_sub = ifelse((wr & lost_mask_sub) != UInt64(0), UInt64(1), UInt64(0))
    wr_sub_result = (wr >> shift_u) | lost_sub
    flushed_result = result_sign << 63

    wr = ifelse(subnormal,
         ifelse(flush_to_zero, wr, wr_sub_result),
         wr)
    result_exp = ifelse(subnormal, Int64(0), result_exp)

    return (wr, result_exp, flushed_result, subnormal, flush_to_zero)
end

"""
    _sf_round_and_pack(wr, result_exp, result_sign) -> (normal_result, exp_overflow, exp_overflow_after_round)

Round to nearest even (IEEE 754 default), pack into Float64 bit pattern.
"""
@inline function _sf_round_and_pack(wr::UInt64, result_exp::Int64, result_sign::UInt64)
    # Overflow check
    exp_overflow = result_exp >= Int64(0x7FF)
    overflow_result = (result_sign << 63) | INF_BITS

    # Round to nearest even
    guard      = (wr >> 2) & UInt64(1)
    round_bit  = (wr >> 1) & UInt64(1)
    sticky_bit = wr & UInt64(1)
    frac       = (wr >> 3) & FRAC_MASK

    grs = (guard << 2) | (round_bit << 1) | sticky_bit
    round_up = (grs > UInt64(4)) | ((grs == UInt64(4)) & ((frac & UInt64(1)) != UInt64(0)))

    frac_rounded = frac + UInt64(1)
    mant_overflow = frac_rounded == IMPLICIT
    frac_final = ifelse(round_up,
                 ifelse(mant_overflow, UInt64(0), frac_rounded),
                 frac)
    exp_after_round = ifelse(round_up & mant_overflow,
                             result_exp + Int64(1),
                             result_exp)
    exp_overflow_after_round = exp_after_round >= Int64(0x7FF)

    # Pack normal result
    exp_pack = UInt64(clamp(exp_after_round, Int64(0), Int64(0x7FE)))
    normal_result = (result_sign << 63) | (exp_pack << 52) | frac_final

    return (normal_result, overflow_result, exp_overflow, exp_overflow_after_round)
end
