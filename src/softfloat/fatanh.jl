# IEEE 754 binary64 inverse hyperbolic tangent on raw bit patterns.
# Branchless port of Julia stdlib `Base.atanh(::Float64)` (julia 1.12
# base/special/hyperbolic.jl:240-266) using `soft_log1p`.
#
# Bennett-tfmo-followup (2026-05-15): refactored from the original
# K=25 Taylor polynomial regime (Bennett-g82n) that existed because
# Bennett.jl had no `soft_log1p`. With `soft_log1p` now landed
# (Bennett-0ulc, Tier C2.1), the natural Julia stdlib two-regime form
# gives the same ULP bound at ~5× fewer soft-float ops.
#
# Domain: `|x| ≤ 1`. atanh diverges at ±1 (returns ±Inf via natural
# log propagation). Julia stdlib throws `DomainError` for `|x| > 1`;
# Bennett returns NaN matching IEEE 754-2019 OOB convention.
#
# Reference accuracy: musl/openlibm targets ≤1 ULP in domain. Bennett
# practical target vs `Base.atanh`: ≤2 ULP.
#
# Algorithm (three-regime, branchless — matches Julia stdlib):
#
#   Regime D (domain):     |x| > 1        →  NaN
#   Regime (a) small:      |x| < 0.5      →  sign(x) · 0.5·log1p(2|x|/(1-|x|))
#   Regime (b) medium:     0.5 ≤ |x| ≤ 1  →  sign(x) · 0.5·log((1+|x|)/(1-|x|))
#
# atanh is ODD: `atanh(-x) = -atanh(x)`. Work on `|x|`, OR sign at end.
# Special at |x| = 1: regime (b) — denominator (1-|x|) = 0, ratio = +Inf,
# log(+Inf) = +Inf, halved is +Inf, sign-stamped is ±Inf. ✓
# Special at |x| = 0: regime (a) — 2·0/(1-0) = 0, log1p(0) = 0, halved is 0,
# sign-stamped is ±0. ✓
#
# Subnormal-input bit-exactness (CLAUDE.md §13): subnormal |x| triggers
# regime (a). 2|x| is still subnormal (or smallest-normal at the
# binade boundary); (1-|x|) rounds to exactly 1.0; ratio = 2|x|;
# `soft_log1p(subnormal) ≡ subnormal` bit-exactly (flog1p.jl regime A);
# halved is |x|; sign-stamped is the original `a` bit pattern. ✓

# Regime thresholds (bit patterns).
const _ATANH_HALF_BITS = reinterpret(UInt64, 0.5)
const _ATANH_ONE_BITS  = reinterpret(UInt64, 1.0)
const _ATANH_NAN_BITS  = QNAN

"""
    soft_atanh(a::UInt64) -> UInt64

IEEE 754 double-precision inverse hyperbolic tangent `atanh(x)` on raw
bit patterns. **≤2 ULP vs `Base.atanh`** within the valid domain
`|x| ≤ 1`. Returns NaN for `|x| > 1`.

Special cases:

- `atanh(±0)`     = `±0`         (regime (a): log1p(0) = 0)
- `atanh(±1)`     = `±Inf`       (regime (b): log(+Inf) = +Inf)
- `atanh(NaN)`    = `NaN`        (with quiet bit forced)
- `atanh(|x|>1)`  = `NaN`        (per IEEE 754-2019 OOB convention)
- subnormal input → subnormal output bit-exact (§13 contract via
  regime (a) `log1p(2|x|/1) ≡ 2|x|` then halved is `|x|`).

Algorithm: two-regime branchless port of Julia stdlib `Base.atanh`,
using `soft_log1p` for the small-|x| branch. Single `soft_log1p`
call, single `soft_log` call. See file header for trade-offs vs
the pre-Bennett-tfmo-followup K=25 polynomial implementation.
"""
@inline function soft_atanh(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # Sign / abs split.
    abs_a    = a & ~SIGN_BIT
    sign_neg = a & SIGN_BIT

    # NaN classification on the full bit pattern.
    ea     = (a >> 52) & UInt64(0x7FF)
    fa     = a & FRAC_MASK
    is_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    # Domain + regime predicates.
    is_above_one = abs_a > _ATANH_ONE_BITS        # |x| > 1  → NaN
    is_med       = abs_a >= _ATANH_HALF_BITS      # 0.5 ≤ |x| → regime (b)

    # Shared intermediates (computed unconditionally — branchless).
    one_minus_abs = soft_fsub(_ATANH_ONE_BITS, abs_a)   # 1 - |x|  ∈ [0, 1]
    one_plus_abs  = soft_fadd(_ATANH_ONE_BITS, abs_a)   # 1 + |x|  ∈ [1, 2]
    two_abs       = soft_fadd(abs_a, abs_a)             # 2|x|     ∈ [0, 2]

    # Regime (a): 0.5·log1p(2|x|/(1-|x|))
    arg_a       = soft_fdiv(two_abs, one_minus_abs)
    log1p_v     = soft_log1p(arg_a)
    half_log1p  = soft_fmul(_ATANH_HALF_BITS, log1p_v)

    # Regime (b): 0.5·log((1+|x|)/(1-|x|))
    arg_b       = soft_fdiv(one_plus_abs, one_minus_abs)
    log_v       = soft_log(arg_b)
    half_log    = soft_fmul(_ATANH_HALF_BITS, log_v)

    # Sign-stamp via OR (each `half_*` is ≥ 0 for |x| ∈ [0, 1]).
    result_a = half_log1p | sign_neg
    result_b = half_log    | sign_neg

    # Cascade compose: regime (a) default; (b) overrides for |x| ≥ 0.5;
    # NaN for |x| > 1 overrides next; input-NaN overrides last.
    result = result_a
    result = ifelse(is_med,        result_b,         result)
    result = ifelse(is_above_one,  _ATANH_NAN_BITS,  result)
    result = ifelse(is_nan,        a | QUIET_BIT,    result)
    return result
end
