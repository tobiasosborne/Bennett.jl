# IEEE 754 binary64 inverse hyperbolic tangent on raw bit patterns.
# Branchless port adapting Julia stdlib `Base.atanh(::Float64)` (julia
# 1.12 base/special/hyperbolic.jl:240-266). **Tier C1.11 — FINAL
# hyperbolic close, completes Tier C1 11 of 11** in the Enzyme parity
# north-star.
#
# Domain: `|x| ≤ 1`. atanh diverges at ±1 (returns ±Inf via natural
# log propagation). Julia stdlib throws `DomainError` for `|x| > 1`;
# Bennett returns NaN matching IEEE 754-2019 OOB convention.
#
# Reference accuracy: musl/openlibm targets ≤1 ULP in domain. Bennett
# practical target vs `Base.atanh`: ≤2 ULP.
#
# Algorithm (three-regime, branchless):
#
#   Regime D (domain):     |x| > 1        →  NaN
#   Regime P (polynomial): |x| ≤ 0.5      →  x · atanh_kernel(x²)
#   Regime M (medium):     0.5 < |x| ≤ 1  →  copysign(0.5·log((1+|x|)/(1-|x|)), x)
#
# atanh is ODD: `atanh(-x) = -atanh(x)`. Work on `|x|`, OR sign at end.
# Special at |x| = 1: log((1+1)/(1-1)) = log(+Inf) = +Inf, halved is
# +Inf — natural propagation gives ±Inf. Special at |x| = 0:
# polynomial path gives `0 · kernel(0) = 0` bit-exact.
#
# Why this regime choice (vs verbatim Julia stdlib):
#
# Julia stdlib uses `0.5·log1p(2x/(1-x))` for the small-|x| branch
# specifically because `log1p` preserves precision when the argument
# is small. Bennett.jl lacks `soft_log1p`. Same substitution as
# m2bv/ky5n/sfx9/eq9p: extend the polynomial regime to cover the
# range where the medium formula loses precision. Polynomial
# coefficients are exact: `c_k = 1/(2k+1)` (the Maclaurin series of
# atanh has exact rational coefficients).
#
# Polynomial regime upper bound 0.5 chosen empirically: the medium
# formula `0.5·log((1+|x|)/(1-|x|))` hits ≤2 ULP for |x| ≥ 0.5
# (cancellation in `(1+|x|)/(1-|x|)` is bounded above 0.5 since both
# numerator and denominator stay clear of zero by ≥ 0.5). K=25 in z=x²
# covers |x| ≤ 0.5 with ≤2 ULP per direct REPL sweep. Slow Taylor
# convergence at the boundary (radius 1) is the same constraint as
# sfx9 asinh.
#
# Subnormal-input bit-exactness (CLAUDE.md §13) IMPLICIT through the
# polynomial branch: x² → +0, kernel(0) = 1.0, x · 1 ≡ x. So
# `soft_atanh(2^-1075) ≡ 2^-1075` bit-exactly across all subnormal
# binades. Same mechanism as sinh/asinh.
#
# 3+1 protocol skipped per CLAUDE.md §2 surgical-extension exception.
# Atanh is a near-mechanical mirror of sfx9 (asinh) with three
# differences: (a) different polynomial coefficients (atanh's are
# exact rationals 1/(2k+1)); (b) medium formula is `0.5·log((1+|x|)/(1-|x|))`
# instead of `log(|x| + sqrt(x²+1))`; (c) domain restriction at |x| > 1.

# ─────────────────────────────────────────────────────────────────────
# Polynomial coefficients — exact: c_k = 1/(2k+1).
# atanh_kernel(z) = 1 + z/3 + z²/5 + z³/7 + … + z^25/51
# Final assembly: atanh(x) = x · kernel(x²) for |x| ≤ 0.5.
# K=25 covers |x| ≤ 0.5 to ≤2 ULP per direct REPL sweep.
# ─────────────────────────────────────────────────────────────────────
const _ATANH_C0  = reinterpret(UInt64, 1.0)
const _ATANH_C1  = reinterpret(UInt64, 0.3333333333333333)        # 1/3
const _ATANH_C2  = reinterpret(UInt64, 0.2)                       # 1/5
const _ATANH_C3  = reinterpret(UInt64, 0.14285714285714285)       # 1/7
const _ATANH_C4  = reinterpret(UInt64, 0.1111111111111111)        # 1/9
const _ATANH_C5  = reinterpret(UInt64, 0.09090909090909091)       # 1/11
const _ATANH_C6  = reinterpret(UInt64, 0.07692307692307693)       # 1/13
const _ATANH_C7  = reinterpret(UInt64, 0.06666666666666667)       # 1/15
const _ATANH_C8  = reinterpret(UInt64, 0.058823529411764705)      # 1/17
const _ATANH_C9  = reinterpret(UInt64, 0.05263157894736842)       # 1/19
const _ATANH_C10 = reinterpret(UInt64, 0.047619047619047616)      # 1/21
const _ATANH_C11 = reinterpret(UInt64, 0.043478260869565216)      # 1/23
const _ATANH_C12 = reinterpret(UInt64, 0.04)                      # 1/25
const _ATANH_C13 = reinterpret(UInt64, 0.037037037037037035)      # 1/27
const _ATANH_C14 = reinterpret(UInt64, 0.034482758620689655)      # 1/29
const _ATANH_C15 = reinterpret(UInt64, 0.03225806451612903)       # 1/31
const _ATANH_C16 = reinterpret(UInt64, 0.030303030303030304)      # 1/33
const _ATANH_C17 = reinterpret(UInt64, 0.02857142857142857)       # 1/35
const _ATANH_C18 = reinterpret(UInt64, 0.02702702702702703)       # 1/37
const _ATANH_C19 = reinterpret(UInt64, 0.02564102564102564)       # 1/39
const _ATANH_C20 = reinterpret(UInt64, 0.024390243902439025)      # 1/41
const _ATANH_C21 = reinterpret(UInt64, 0.023255813953488372)      # 1/43
const _ATANH_C22 = reinterpret(UInt64, 0.022222222222222223)      # 1/45
const _ATANH_C23 = reinterpret(UInt64, 0.02127659574468085)       # 1/47
const _ATANH_C24 = reinterpret(UInt64, 0.02040816326530612)       # 1/49
const _ATANH_C25 = reinterpret(UInt64, 0.0196078431372549)        # 1/51

# Regime thresholds.
const _ATANH_HALF_BITS = reinterpret(UInt64, 0.5)
const _ATANH_ONE_BITS  = reinterpret(UInt64, 1.0)
const _ATANH_NAN_BITS  = QNAN

"""
    soft_atanh(a::UInt64) -> UInt64

IEEE 754 double-precision inverse hyperbolic tangent `atanh(x)` on raw
bit patterns. **≤2 ULP vs `Base.atanh`** within the valid domain
`|x| ≤ 1`. Returns NaN for `|x| > 1`.

Special cases (matches `Base.atanh` semantics for in-domain inputs):

- `atanh(±0)`     = `±0`         (sign-preserved via polynomial branch)
- `atanh(±1)`     = `±Inf`       (medium formula: log(+Inf) = +Inf)
- `atanh(NaN)`    = `NaN`        (input passed through with quiet-bit set)
- `atanh(|x|>1)`  = `NaN`        (domain error per IEEE 754-2019)
- subnormal input → subnormal output bit-exact (§13 contract via the
  polynomial branch: `x²` underflows to `+0`, `kernel(0) = 1`, `x · 1 ≡ x`).

Algorithm: three-regime branchless port of Julia stdlib `Base.atanh`
with `log1p` substituted by an extended polynomial regime. K=25 Taylor
in z=x² for `|x| ≤ 0.5`; `0.5·log((1+|x|)/(1-|x|))` for medium. ONE
soft_log call, ONE soft_fdiv. NaN propagation via final cascade.

**Final hyperbolic close, completes Tier C1 11/11 in Bennett-Enzyme-
Parity-NorthStar.md.**
"""
@inline function soft_atanh(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # ─── Sign + abs split.
    abs_a    = a & ~SIGN_BIT
    sign_neg = a & SIGN_BIT

    # ─── NaN classification (full bit pattern).
    ea     = (a >> 52) & UInt64(0x7FF)
    fa     = a & FRAC_MASK
    is_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    # ─── Domain check: is |x| > 1?
    is_above_one = abs_a > _ATANH_ONE_BITS

    # ─── Regime predicate.
    is_poly = abs_a <= _ATANH_HALF_BITS

    # ─── Regime P: polynomial in z = x², degree 25 in z.
    #     atanh_kernel(z) = c0 + z·(c1 + z·(c2 + … + z·c25))
    #     Final assembly: result = a · kernel(z) — sign of x carried by
    #     the leading factor. atanh(±0) = ±0 via soft_fmul(±0, 1) = ±0.
    z   = soft_fmul(a, a)               # x² ≥ 0 (sign cancels)
    p   = soft_fmul(z, _ATANH_C25)
    p = soft_fadd(_ATANH_C24, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C23, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C22, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C21, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C20, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C19, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C18, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C17, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C16, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C15, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C14, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C13, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C12, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C11, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C10, p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C9,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C8,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C7,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C6,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C5,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C4,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C3,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C2,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C1,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ATANH_C0,  p)        # = atanh_kernel(z)
    result_poly = soft_fmul(a, p)        # x · kernel(x²); sign carried by `a`

    # ─── Regime M (medium): result = copysign(0.5 · log((1+|x|)/(1-|x|)), x)
    #     For |x| < 1: numerator (1+|x|) ∈ (1, 2], denominator (1-|x|)
    #     ∈ [0, 0.5). Ratio ∈ [2, +Inf]. log of [2, Inf] is well-conditioned.
    #     At |x| = 1: denominator = 0, ratio = +Inf, log(+Inf) = +Inf,
    #     halved is +Inf — natural propagation gives ±Inf.
    one_plus_abs   = soft_fadd(_ATANH_ONE_BITS, abs_a)
    one_minus_abs  = soft_fsub(_ATANH_ONE_BITS, abs_a)
    ratio          = soft_fdiv(one_plus_abs, one_minus_abs)
    log_ratio      = soft_log(ratio)
    half_log_ratio = soft_fmul(_ATANH_HALF_BITS, log_ratio)
    # copysign-via-OR: half_log_ratio ≥ 0 for |x| > 0 (since ratio > 1
    # ⇒ log > 0). At |x| = 0 polynomial path is selected. For |x| ∈ (0, 1)
    # the medium result is positive; OR with sign_neg stamps the sign.
    result_med     = half_log_ratio | sign_neg

    # ─── Cascade compose: most-specific overrides win (last-write).
    result = result_med
    result = ifelse(is_poly,       result_poly,    result)
    result = ifelse(is_above_one,  _ATANH_NAN_BITS, result)
    result = ifelse(is_nan,        a | QUIET_BIT,   result)
    return result
end
