# IEEE 754 binary64 inverse hyperbolic sine on raw bit patterns.
# Branchless port of Julia stdlib `Base.asinh(::Float64)`
# (julia 1.12 base/special/hyperbolic.jl:165-199) using `soft_log1p`.
#
# Bennett-tfmo (2026-05-15): refactored from the original K=30 Taylor
# polynomial regime (Bennett-sfx9) that existed because Bennett.jl had
# no `soft_log1p`. With `soft_log1p` now landed (Bennett-0ulc, Tier
# C2.1), the natural Julia stdlib formula gives the same ULP bound at
# ~4.6× fewer soft-float ops.
#
# Reference accuracy: musl/openlibm target ≤1 ULP across the full f64
# range. Bennett.jl practical target vs `Base.asinh`: ≤2 ULP.
#
# Algorithm (four-regime, branchless — matches Julia stdlib):
#
#   Regime (a) tiny:   |x| < 2^-28              →  x  (sign/subnormal preserved)
#   Regime (b) small:  2^-28 ≤ |x| < 2          →  sign(x) · log1p(|x| + x²/(1+sqrt(1+x²)))
#   Regime (c) medium: 2 ≤ |x| < 2^28           →  sign(x) · log(2|x| + 1/(sqrt(x²+1)+|x|))
#   Regime (d) huge:   |x| ≥ 2^28               →  sign(x) · (log(|x|) + ln(2))
#
# Non-finite handling (matches Julia's `!isfinite(x) && return x`):
# ±Inf and NaN are returned as the input bits. NaN payload is forced
# to quiet form (sNaN → qNaN); ±Inf is bit-exact.
#
# Subnormal-input bit-exactness (CLAUDE.md §13) is GIVEN by regime (a):
# any subnormal |x| < 2^-1022 ≪ 2^-28, so `is_tiny` fires and the
# function returns `a` bit-exactly. The polynomial regime that needed
# explicit subnormal proof in Bennett-sfx9 is gone.
#
# Why this is better than the Bennett-sfx9 K=30 polynomial:
# - 13 soft-float ops vs 60 (1 fmul + 4 fadd + 1 fsqrt + 2 fdiv +
#   1 log1p + 1 log + 3 fadd in the cascade, all unconditional).
# - Algebraically identical to Julia stdlib's high-precision recipe,
#   so any future improvement to `Base.asinh` ports trivially.
# - The medium regime (c) uses the "small-arg log" trick
#   `log(2|x| + 1/(sqrt(x²+1)+|x|))` instead of the Bennett-sfx9
#   `log(|x| + sqrt(x²+1))`. Both are mathematically asinh, but (c)
#   keeps the argument closer to ~2|x| at moderate |x|, sidestepping
#   the soft_log precision loss that motivated the polynomial workaround.

# Regime thresholds (bit patterns).
const _ASINH_TINY_BITS = reinterpret(UInt64, 2.0^-28)   # ~3.73e-9
const _ASINH_MED_BITS  = reinterpret(UInt64, 2.0)
const _ASINH_HUGE_BITS = reinterpret(UInt64, 2.0^28)    # ~2.68e8

const _ASINH_ONE_BITS  = reinterpret(UInt64, 1.0)
# ln(2) = 0.6931471805599453 — used by the huge-regime tail.
const _ASINH_LN2_BITS  = reinterpret(UInt64, 0.6931471805599453)

"""
    soft_asinh(a::UInt64) -> UInt64

IEEE 754 double-precision inverse hyperbolic sine `asinh(x)` on raw
bit patterns. **≤2 ULP vs `Base.asinh`** across the full Float64 input
space.

Special cases (matches `Base.asinh`):

- `asinh(±0)`     = `±0`   (regime (a): `|x| < 2^-28` returns input bits)
- `asinh(±Inf)`   = `±Inf` (non-finite passthrough)
- `asinh(NaN)`    = `NaN`  (with quiet bit forced; payload preserved otherwise)
- subnormal input → subnormal output bit-exact (§13 contract via regime (a))

Algorithm: four-regime branchless port of Julia stdlib `Base.asinh`,
using `soft_log1p` for the small-arg regime. Single `soft_log1p` call,
single `soft_log` call (with regime-selected argument), one `soft_fsqrt`,
two `soft_fdiv`. See file header for the trade-offs vs the pre-Bennett-tfmo
K=30 polynomial implementation.
"""
@inline function soft_asinh(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # Sign / abs split. `abs_a` is the bit pattern of |x|; `sign_neg`
    # is the input's sign bit (we OR it back at the end to copysign).
    abs_a    = a & ~SIGN_BIT
    sign_neg = a & SIGN_BIT

    # Non-finite classification on the full bit pattern of `a`.
    ea     = (a >> 52) & UInt64(0x7FF)
    fa     = a & FRAC_MASK
    is_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    is_inf = (ea == UInt64(0x7FF)) & (fa == UInt64(0))

    # Regime predicates on |x| (bit-pattern comparisons work because
    # IEEE 754 positive ordering coincides with unsigned-int ordering).
    is_tiny = abs_a <  _ASINH_TINY_BITS    # |x| < 2^-28  → return x
    is_med  = abs_a >= _ASINH_MED_BITS     # |x| ≥ 2       → use formula (c) or (d)
    is_huge = abs_a >= _ASINH_HUGE_BITS    # |x| ≥ 2^28   → use formula (d)

    # Shared intermediates (computed unconditionally — branchless).
    x_squared = soft_fmul(abs_a, abs_a)                        # x² ≥ 0
    x_sq_p1   = soft_fadd(x_squared, _ASINH_ONE_BITS)          # x² + 1 ≥ 1
    s         = soft_fsqrt(x_sq_p1)                            # sqrt(x²+1) ≥ 1

    # Regime (b) arg: |x| + x² / (1 + sqrt(1+x²))
    one_p_s = soft_fadd(_ASINH_ONE_BITS, s)                    # 1 + s ≥ 2
    ratio_b = soft_fdiv(x_squared, one_p_s)                    # x²/(1+s)
    arg_b   = soft_fadd(abs_a, ratio_b)                        # |x| + ratio

    # Regime (c) arg: 2|x| + 1 / (sqrt(x²+1) + |x|)
    s_p_x   = soft_fadd(s, abs_a)                              # s + |x| ≥ 1
    inv_spx = soft_fdiv(_ASINH_ONE_BITS, s_p_x)                # 1/(s+|x|)
    two_x   = soft_fadd(abs_a, abs_a)                          # 2|x|
    arg_c   = soft_fadd(two_x, inv_spx)                        # 2|x| + 1/(s+|x|)

    # Regime (b) result: log1p of arg_b.
    result_b_pos = soft_log1p(arg_b)

    # Regimes (c) and (d) share a single soft_log call with a
    # regime-selected argument: arg_c for medium, |x| for huge.
    log_arg      = ifelse(is_huge, abs_a, arg_c)
    log_v        = soft_log(log_arg)
    result_c_pos = log_v
    result_d_pos = soft_fadd(log_v, _ASINH_LN2_BITS)           # log(|x|) + ln(2)

    # copysign-via-OR: each `result_*_pos` is ≥ 0 because the asinh
    # value is positive for |x| ≥ ε (regimes b/c/d), so the sign bit
    # is clear and OR-ing `sign_neg` cleanly stamps the input's sign.
    result_b = result_b_pos | sign_neg
    result_c = result_c_pos | sign_neg
    result_d = result_d_pos | sign_neg

    # Cascade compose: default = regime (b); medium overrides for |x| ≥ 2;
    # huge overrides for |x| ≥ 2^28; tiny / Inf / NaN override last.
    # Note: `is_huge` implies `is_med` (since 2^28 > 2), so the cascade
    # ordering correctly lands on the most-specific arm.
    result = result_b
    result = ifelse(is_med,  result_c, result)
    result = ifelse(is_huge, result_d, result)
    result = ifelse(is_tiny, a,        result)
    result = ifelse(is_inf,  a,        result)
    result = ifelse(is_nan,  a | QUIET_BIT, result)

    return result
end
