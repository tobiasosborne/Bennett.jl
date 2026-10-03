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
#
# NaN results (Bennett-4qgq): a NaN result is always one of the input NaNs,
# returned UNCHANGED — sign, payload and signalling state kept, no quieting.
# This is what the native Float64 operations return on the pinned x86-64
# target (CLAUDE.md §5), verified bit-for-bit in
# test/test_4qgq_fminmax_nan_payload.jl:
#   - minimum/maximum (Base.min/max): the x86 lowering orders the operands by
#     sign for the ±0 tie (min: P = signbit(a) ? b : a; max: P = signbit(a) ?
#     a : b; Q = the other) and returns P if P is NaN, else Q.
#   - minnum/maxnum: exactly one NaN → the other operand; both NaN → b.

"""
    soft_fminimum(a::UInt64, b::UInt64) -> UInt64

IEEE 754-2008 minimum on raw bit patterns. NaN-propagating: if either
operand is NaN, the result is one input NaN unchanged (sign-ordered
precedence, see the file header). -0.0 < +0.0 for the tie-break. Matches
`Base.min(::Float64, ::Float64)` bit-exactly, NaN payloads included.
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
    # ±0 tie-break: -0 wins for min (pick whichever has sign bit set).
    pick_a = ifelse(both_zero, a_neg, a_lt_b)
    # NaN (Bennett-4qgq): P = a_neg ? b : a wins if NaN, else Q (the other),
    # returned unchanged. Decided as one Bool so a single 64-bit mux remains.
    pick_a = ifelse(either_nan, ifelse(a_neg, !b_nan, a_nan), pick_a)
    return ifelse(pick_a, a, b)
end

"""
    soft_fmaximum(a::UInt64, b::UInt64) -> UInt64

IEEE 754-2008 maximum on raw bit patterns. NaN-propagating (one input NaN
returned unchanged, sign-ordered precedence). +0.0 > -0.0 for the
tie-break. Matches `Base.max(::Float64, ::Float64)` bit-exactly.
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
    # ±0 tie-break: +0 wins for max (pick whichever does NOT have sign bit set).
    pick_a = ifelse(both_zero, !a_neg, a_gt_b)
    # NaN (Bennett-4qgq): P = a_neg ? a : b wins if NaN, else Q (the other).
    pick_a = ifelse(either_nan, ifelse(a_neg, a_nan, !b_nan), pick_a)
    return ifelse(pick_a, a, b)
end

"""
    soft_fmin(a::UInt64, b::UInt64) -> UInt64

IEEE 754 minNum on raw bit patterns (NaN-absorbing). If exactly one
operand is NaN, returns the other. If both are NaN, returns `b` unchanged
(native x86 `llvm.minnum`; Bennett-4qgq). ±0 tie-break matches `soft_fminimum` (returns the negative
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

    both_zero = (abs_a == UInt64(0)) & (abs_b == UInt64(0))
    a_neg = (a & UInt64(0x8000000000000000)) != UInt64(0)

    a_lt_b = soft_fcmp_olt(a, b) != UInt64(0)
    pick_a = ifelse(both_zero, a_neg, a_lt_b)
    # NaN absorption: prefer the non-NaN. Both NaN → b unchanged (a_nan arm).
    pick_a = ifelse(a_nan, false, ifelse(b_nan, true, pick_a))
    return ifelse(pick_a, a, b)
end

"""
    soft_fmax(a::UInt64, b::UInt64) -> UInt64

IEEE 754 maxNum on raw bit patterns (NaN-absorbing). Symmetric to
`soft_fmin`; ±0 tie-break returns the positive zero; both NaN → `b`.
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

    both_zero = (abs_a == UInt64(0)) & (abs_b == UInt64(0))
    a_neg = (a & UInt64(0x8000000000000000)) != UInt64(0)

    a_gt_b = soft_fcmp_olt(b, a) != UInt64(0)
    pick_a = ifelse(both_zero, !a_neg, a_gt_b)
    pick_a = ifelse(a_nan, false, ifelse(b_nan, true, pick_a))
    return ifelse(pick_a, a, b)
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
(returns the non-NaN operand if exactly one is NaN; `b` unchanged
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
