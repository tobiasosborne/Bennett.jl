"""
    soft_fcmp_olt(a::UInt64, b::UInt64) -> UInt64

IEEE 754 ordered less-than comparison on raw bit patterns.
Returns 1 if a < b (and neither is NaN), 0 otherwise.
Fully branchless.
"""
function soft_fcmp_olt(a::UInt64, b::UInt64)::UInt64
    SIGN_MASK = UInt64(0x8000000000000000)
    ABS_MASK  = UInt64(0x7FFFFFFFFFFFFFFF)

    sa = a >> 63
    sb = b >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    eb = (b >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    fb = b & FRAC_MASK
    abs_a = a & ABS_MASK
    abs_b = b & ABS_MASK

    # NaN check: exponent all-ones with non-zero fraction
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    either_nan = a_nan | b_nan

    # Both zero (±0 == ±0)
    both_zero = (abs_a == UInt64(0)) & (abs_b == UInt64(0))

    # Same sign comparison
    # For positive: a < b iff abs_a < abs_b
    # For negative: a < b iff abs_a > abs_b
    pos_lt = abs_a < abs_b      # |a| < |b|
    neg_lt = abs_a > abs_b      # |a| > |b| (more negative)

    # Different sign: negative < positive (unless both zero)
    diff_sign_lt = (sa > sb)    # a is negative, b is positive

    same_sign = sa == sb
    result = ifelse(same_sign,
                    ifelse(sa == UInt64(0), pos_lt, neg_lt),
                    diff_sign_lt)

    # Override: NaN → false, both zero → false
    result = result & (!both_zero) & (!either_nan)

    return UInt64(result)
end

"""
    soft_fcmp_oeq(a::UInt64, b::UInt64) -> UInt64

IEEE 754 ordered equal comparison on raw bit patterns.
Returns 1 if a == b (and neither is NaN), 0 otherwise.
Note: +0.0 == -0.0 per IEEE 754.
Fully branchless.
"""
function soft_fcmp_oeq(a::UInt64, b::UInt64)::UInt64
    ABS_MASK  = UInt64(0x7FFFFFFFFFFFFFFF)

    ea = (a >> 52) & UInt64(0x7FF)
    eb = (b >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    fb = b & FRAC_MASK
    abs_a = a & ABS_MASK
    abs_b = b & ABS_MASK

    # NaN check
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    either_nan = a_nan | b_nan

    # +0.0 == -0.0: both absolute values zero
    both_zero = (abs_a == UInt64(0)) & (abs_b == UInt64(0))

    # Bitwise equal or both zero
    result = (a == b) | both_zero

    # NaN != anything
    result = result & (!either_nan)

    return UInt64(result)
end

"""
    soft_fcmp_ole(a::UInt64, b::UInt64) -> UInt64

IEEE 754 ordered less-than-or-equal: a <= b and neither is NaN.
"""
@inline function soft_fcmp_ole(a::UInt64, b::UInt64)::UInt64
    return soft_fcmp_olt(a, b) | soft_fcmp_oeq(a, b)
end

"""
    soft_fcmp_une(a::UInt64, b::UInt64) -> UInt64

IEEE 754 unordered not-equal: a != b or either is NaN.

`une` ≡ `uno | one` ≡ `!oeq` (the latter holds because both unordered
operands AND ordered-not-equal operands have `oeq == 0`).
"""
@inline function soft_fcmp_une(a::UInt64, b::UInt64)::UInt64
    return UInt64(1) - soft_fcmp_oeq(a, b)
end

# Bennett-d77b / U132: 6 new soft_fcmp_* primitives complete the LLVM
# fcmp predicate table (ord, uno, one, ueq, ult, ule). Combined with the
# existing 4 (oeq, olt, ole, une) and the operand-swap dispatch in
# ir_extract.jl for ogt/oge/ugt/uge, every LLVM fcmp predicate now routes
# to a callee. All return UInt64(0) or UInt64(1).

"""
    _either_nan(a::UInt64, b::UInt64) -> Bool

Branchless test: at least one of `a`, `b` is a (quiet or signalling) NaN
in IEEE 754 binary64. NaN encoding: exponent = `0x7FF` AND fraction != 0.
"""
@inline function _either_nan(a::UInt64, b::UInt64)::Bool
    ea = (a >> 52) & UInt64(0x7FF)
    eb = (b >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    fb = b & FRAC_MASK
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    b_nan = (eb == UInt64(0x7FF)) & (fb != UInt64(0))
    return a_nan | b_nan
end

"""
    soft_fcmp_ord(a::UInt64, b::UInt64) -> UInt64

IEEE 754 ordered: neither `a` nor `b` is NaN. Returns 1 if both are
non-NaN, 0 otherwise. Fully branchless.
"""
function soft_fcmp_ord(a::UInt64, b::UInt64)::UInt64
    return UInt64(!_either_nan(a, b))
end

"""
    soft_fcmp_uno(a::UInt64, b::UInt64) -> UInt64

IEEE 754 unordered: at least one of `a`, `b` is NaN. Returns 1 if any
NaN operand is present, 0 otherwise. Fully branchless.
"""
function soft_fcmp_uno(a::UInt64, b::UInt64)::UInt64
    return UInt64(_either_nan(a, b))
end

"""
    soft_fcmp_one(a::UInt64, b::UInt64) -> UInt64

IEEE 754 ordered not-equal: both operands are non-NaN AND `a != b`.
Note `+0.0 == -0.0` per IEEE 754, so `one(+0, -0)` returns 0.
"""
@inline function soft_fcmp_one(a::UInt64, b::UInt64)::UInt64
    return soft_fcmp_ord(a, b) & (UInt64(1) - soft_fcmp_oeq(a, b))
end

"""
    soft_fcmp_ueq(a::UInt64, b::UInt64) -> UInt64

IEEE 754 unordered equal: at least one operand is NaN OR `a == b`.
Returns 1 in either case. NaN comparisons return 1 (the "unordered" bit).
"""
@inline function soft_fcmp_ueq(a::UInt64, b::UInt64)::UInt64
    return soft_fcmp_uno(a, b) | soft_fcmp_oeq(a, b)
end

"""
    soft_fcmp_ult(a::UInt64, b::UInt64) -> UInt64

IEEE 754 unordered less-than: at least one operand is NaN OR `a < b`
(ordered). NaN comparisons return 1.
"""
@inline function soft_fcmp_ult(a::UInt64, b::UInt64)::UInt64
    return soft_fcmp_uno(a, b) | soft_fcmp_olt(a, b)
end

"""
    soft_fcmp_ule(a::UInt64, b::UInt64) -> UInt64

IEEE 754 unordered less-than-or-equal: at least one operand is NaN OR
`a <= b` (ordered). NaN comparisons return 1.
"""
@inline function soft_fcmp_ule(a::UInt64, b::UInt64)::UInt64
    return soft_fcmp_uno(a, b) | soft_fcmp_ole(a, b)
end
