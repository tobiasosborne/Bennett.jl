# Bennett-k2w6: native IEEE 754 binary64 min/max primitives, closing the
# Bennett-kh6n future-work stub. Two semantic pairs:
#
#   - soft_fmin / soft_fmax       ≡ llvm.minnum  / llvm.maxnum  ≡
#                                   IEEE 754 minNum/maxNum (NaN-absorbing).
#   - soft_fminimum / soft_fmaximum ≡ llvm.minimum / llvm.maximum ≡
#                                   IEEE 754-2008 minimum/maximum
#                                   (NaN-propagating; matches Julia's
#                                   Base.min/Base.max bit-exactly).
#
# Both pairs treat -0.0 < +0.0 for the tie-break: min(±0, ±0) returns the
# negative zero, max returns the positive zero. This matches Julia's
# Base.min/max (and IEEE 754-2008 minimum/maximum's mandate); for minNum
# the LLVM langref says the ±0 result is unspecified, but matching Base
# is the obvious choice for "least surprise".
#
# Built on `soft_fcmp_olt` (src/softfloat/fcmp.jl) which already does
# sign-aware ordered compare with NaN→0 and ±0→0 (ties).
#
# All four primitives are fully branchless (ifelse on UInt64 / Bool).

"""
    soft_fminimum(a::UInt64, b::UInt64) -> UInt64

IEEE 754-2008 minimum on raw bit patterns. NaN-propagating: if either
operand is NaN, the result is a canonical quiet NaN. -0.0 < +0.0 for the
tie-break. Matches `Base.min(::Float64, ::Float64)` bit-exactly.
"""
function soft_fminimum(a::UInt64, b::UInt64)::UInt64
    abs_a = a & UInt64(0x7FFFFFFFFFFFFFFF)
    abs_b = b & UInt64(0x7FFFFFFFFFFFFFFF)
    ea = (a >> 52) & UInt64(0x7FF)
    eb = (b >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    fb = b & FRAC_MASK
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    either_nan = a_nan | b_nan

    both_zero = (abs_a == UInt64(0)) & (abs_b == UInt64(0))
    a_neg = (a & UInt64(0x8000000000000000)) != UInt64(0)

    a_lt_b = soft_fcmp_olt(a, b) != UInt64(0)
    base   = ifelse(a_lt_b, a, b)
    # ±0 tie-break: -0 wins for min (return whichever has sign bit set).
    base   = ifelse(both_zero, ifelse(a_neg, a, b), base)
    return ifelse(either_nan, UInt64(0x7FF8000000000000), base)
end

"""
    soft_fmaximum(a::UInt64, b::UInt64) -> UInt64

IEEE 754-2008 maximum on raw bit patterns. NaN-propagating. +0.0 > -0.0
for the tie-break. Matches `Base.max(::Float64, ::Float64)` bit-exactly.
"""
function soft_fmaximum(a::UInt64, b::UInt64)::UInt64
    abs_a = a & UInt64(0x7FFFFFFFFFFFFFFF)
    abs_b = b & UInt64(0x7FFFFFFFFFFFFFFF)
    ea = (a >> 52) & UInt64(0x7FF)
    eb = (b >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    fb = b & FRAC_MASK
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    either_nan = a_nan | b_nan

    both_zero = (abs_a == UInt64(0)) & (abs_b == UInt64(0))
    a_neg = (a & UInt64(0x8000000000000000)) != UInt64(0)

    # a_gt_b ≡ b < a; reuse soft_fcmp_olt with operands swapped.
    a_gt_b = soft_fcmp_olt(b, a) != UInt64(0)
    base   = ifelse(a_gt_b, a, b)
    # ±0 tie-break: +0 wins for max (return whichever does NOT have sign bit set).
    base   = ifelse(both_zero, ifelse(a_neg, b, a), base)
    return ifelse(either_nan, UInt64(0x7FF8000000000000), base)
end

"""
    soft_fmin(a::UInt64, b::UInt64) -> UInt64

IEEE 754 minNum on raw bit patterns (NaN-absorbing). If exactly one
operand is NaN, returns the other. If both are NaN, returns a canonical
quiet NaN. ±0 tie-break matches `soft_fminimum` (returns the negative
zero) for least-surprise consistency.
"""
function soft_fmin(a::UInt64, b::UInt64)::UInt64
    abs_a = a & UInt64(0x7FFFFFFFFFFFFFFF)
    abs_b = b & UInt64(0x7FFFFFFFFFFFFFFF)
    ea = (a >> 52) & UInt64(0x7FF)
    eb = (b >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    fb = b & FRAC_MASK
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    both_nan = a_nan & b_nan

    both_zero = (abs_a == UInt64(0)) & (abs_b == UInt64(0))
    a_neg = (a & UInt64(0x8000000000000000)) != UInt64(0)

    a_lt_b = soft_fcmp_olt(a, b) != UInt64(0)
    base   = ifelse(a_lt_b, a, b)
    base   = ifelse(both_zero, ifelse(a_neg, a, b), base)
    # NaN absorption: prefer the non-NaN. If both NaN → qNaN.
    res    = ifelse(a_nan, b, ifelse(b_nan, a, base))
    return ifelse(both_nan, UInt64(0x7FF8000000000000), res)
end

"""
    soft_fmax(a::UInt64, b::UInt64) -> UInt64

IEEE 754 maxNum on raw bit patterns (NaN-absorbing). Symmetric to
`soft_fmin`; ±0 tie-break returns the positive zero.
"""
function soft_fmax(a::UInt64, b::UInt64)::UInt64
    abs_a = a & UInt64(0x7FFFFFFFFFFFFFFF)
    abs_b = b & UInt64(0x7FFFFFFFFFFFFFFF)
    ea = (a >> 52) & UInt64(0x7FF)
    eb = (b >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    fb = b & FRAC_MASK
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    both_nan = a_nan & b_nan

    both_zero = (abs_a == UInt64(0)) & (abs_b == UInt64(0))
    a_neg = (a & UInt64(0x8000000000000000)) != UInt64(0)

    a_gt_b = soft_fcmp_olt(b, a) != UInt64(0)
    base   = ifelse(a_gt_b, a, b)
    base   = ifelse(both_zero, ifelse(a_neg, b, a), base)
    res    = ifelse(a_nan, b, ifelse(b_nan, a, base))
    return ifelse(both_nan, UInt64(0x7FF8000000000000), res)
end

# Bennett-p19b: IEEE 754-2019 minimumNumber/maximumNumber (LLVM 19+
# llvm.minimumnum / llvm.maximumnum). Semantically identical to
# soft_fmin / soft_fmax (above) — both are NaN-absorbing and both
# specify the ±0 sign-aware tie-break (returning -0.0 from min, +0.0
# from max). LLVM 19 explicitly tightens the ±0 spec from "unspecified"
# (minnum) to "specified" (minimumnum); soft_fmin already chose the
# specified behavior, so the bodies coincide. Aliased rather than
# duplicated for callsite clarity. The body forms below are full
# `function … end` (rather than `@inline` short-form) so the callee
# registry resolves `soft_minimumnum` / `soft_maximumnum` as distinct
# generic functions from `soft_fmin` / `soft_fmax`, even though every
# instance is delegated identically.

"""
    soft_minimumnum(a::UInt64, b::UInt64) -> UInt64

IEEE 754-2019 `minimumNumber` on raw bit patterns. NaN-absorbing
(returns the non-NaN operand if exactly one is NaN; canonical qNaN
if both NaN). The ±0 tie-break is specified: returns the negative
zero. Bit-identical to [`soft_fmin`](@ref) (which already chose
this convention for least-surprise consistency with `Base.min`).
"""
function soft_minimumnum(a::UInt64, b::UInt64)::UInt64
    return soft_fmin(a, b)
end

"""
    soft_maximumnum(a::UInt64, b::UInt64) -> UInt64

IEEE 754-2019 `maximumNumber` on raw bit patterns. Symmetric to
[`soft_minimumnum`](@ref); ±0 tie-break returns the positive zero.
Bit-identical to [`soft_fmax`](@ref).
"""
function soft_maximumnum(a::UInt64, b::UInt64)::UInt64
    return soft_fmax(a, b)
end
