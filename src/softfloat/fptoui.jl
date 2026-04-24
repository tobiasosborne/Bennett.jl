"""
    soft_fptoui(a::UInt64)::UInt64

Convert IEEE 754 double-precision float (as UInt64 bit pattern) to unsigned
UInt64. Branchless implementation for reversible circuit compilation.
Bit-exact with Julia's native `unsafe_trunc(UInt64, ::Float64)` on x86-64,
which lowers `fptoui double to i64` via `cvttsd2si` with a 2^63 bias
correction for the [2^63, 2^64) half.

Bennett-b1vp / U31: prior to this function, the `LLVMFPToUI` opcode was
silently routed through `soft_fptosi`, corrupting any in-range value that
requires the high bit of an unsigned 64-bit integer (e.g. 1e19).

Semantics:
- x ∈ [0, 2^63): identical to `soft_fptosi` (cvttsd2si path).
- x ∈ [2^63, 2^64): subtract 2^63, convert the remainder in [0, 2^63),
  then OR bit 63.
- NaN / ±Inf / |x| ≥ 2^64 / x ≤ -2^63: saturate to 0x8000000000000000
  (the x86 `cvttsd2si` indefinite value).
- x ∈ (-2^63, 0): two's-complement reinterpretation of the signed
  convert. Strictly LLVM poison, but matches x86-64 native behaviour —
  honesty over a stricter LLVM-spec saturation.

Biased-exponent 1086 is the [2^63, 2^64) half: 2^63 has biased exp=1086,
mant=0; prevfloat(2^64) has biased exp=1086, mant=all-ones. 2^64 itself
has biased exp=1087 and is therefore routed down the invalid path.
"""
@inline function soft_fptoui(a::UInt64)::UInt64
    sign = (a >> 63) & UInt64(1)
    exp  = (a >> 52) & UInt64(0x7ff)

    # Select between the "cvttsd2si" path (sign=0, exp < 1086 OR sign=1)
    # and the "subtract 2^63" path (sign=0, exp == 1086).
    in_high_range = (sign == UInt64(0)) & (exp == UInt64(1086))

    # Path A: direct signed convert. For x < 2^63 (positives or any
    # negative in [-2^63, 0)), the reinterpreted bits are what we want.
    # For NaN / ±Inf / x ≤ -2^63, soft_fptosi already saturates to
    # 0x8000000000000000, giving the invalid sentinel unchanged.
    path_a = soft_fptosi(a)

    # Path B: x ∈ [2^63, 2^64). Subtract 2^63 exactly — representable
    # in Float64 as 0x43E0000000000000 — leaving a remainder in [0, 2^63)
    # that soft_fptosi can convert without saturation. OR bit 63 back in.
    adjusted = soft_fsub(a, UInt64(0x43E0000000000000))
    path_b = UInt64(0x8000000000000000) | soft_fptosi(adjusted)

    return ifelse(in_high_range, path_b, path_a)
end
