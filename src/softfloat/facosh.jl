# IEEE 754 binary64 inverse hyperbolic cosine on raw bit patterns.
# Branchless port of Julia stdlib `Base.acosh(::Float64)` (julia 1.12
# base/special/hyperbolic.jl:201-237) using `soft_log1p`.
#
# Bennett-tfmo-followup (2026-05-15): refactored from the original
# K=15 Taylor polynomial with `s²=2(x-1)` substitution (Bennett-eq9p)
# that existed because Bennett.jl had no `soft_log1p`. With
# `soft_log1p` now landed (Bennett-0ulc, Tier C2.1), the natural
# Julia stdlib three-regime form gives the same ULP bound at ~3×
# fewer soft-float ops AND covers the full `1 ≤ x < 2` range with
# one log1p call (vs the polynomial's empirically-tightened `x ≤ 1.05`
# threshold).
#
# Domain restriction: `acosh(x)` is mathematically defined only for
# `x ≥ 1`. Julia stdlib throws `DomainError` for `x < 1`. Bennett.jl
# CANNOT throw in the branchless model — we return `NaN` for `x < 1`,
# matching IEEE 754-2019 invalid-domain semantics.
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across `[1, +Inf)`.
# Bennett.jl practical target vs `Base.acosh`: ≤2 ULP within domain.
#
# Algorithm (four-regime, branchless — matches Julia stdlib):
#
#   Regime D (domain):  x < 1            →  NaN
#   Regime (b) small:   1 ≤ x < 2        →  log1p(t + sqrt(2t + t²)), t = x-1
#   Regime (c) medium:  2 ≤ x < 2^28     →  log(2x - 1/(x + sqrt(x²-1)))
#   Regime (d) huge:    x ≥ 2^28         →  log(x) + ln(2)
#
# At x = 1 exactly: t = 0, 2t+t² = 0, sqrt = 0, log1p(0) = 0. ✓
#
# §13 (CLAUDE.md / Bennett-fnxg) — DIFFERENT from sinh/tanh/cosh/asinh/atanh:
# acosh's domain excludes the entire subnormal range. So `soft_acosh
# (any subnormal) = NaN`, matching IEEE 754-2019 (and matching the
# pre-refactor contract).

# Regime thresholds (bit patterns).
const _ACOSH_ONE_BITS  = reinterpret(UInt64, 1.0)
const _ACOSH_TWO_BITS  = reinterpret(UInt64, 2.0)
const _ACOSH_HUGE_BITS = reinterpret(UInt64, 2.0^28)
const _ACOSH_LN2_BITS  = reinterpret(UInt64, 0.6931471805599453)
const _ACOSH_NAN_BITS  = QNAN

"""
    soft_acosh(a::UInt64) -> UInt64

IEEE 754 double-precision inverse hyperbolic cosine `acosh(x)` on raw
bit patterns. **≤2 ULP vs `Base.acosh`** within the valid domain
`x ≥ 1`. Returns `NaN` for `x < 1` (domain error, per IEEE 754-2019).

Special cases:

- `acosh(1)`     = `0`       (regime (b): log1p(0) = 0)
- `acosh(+Inf)`  = `+Inf`    (regime (d): log(+Inf) + ln(2) = +Inf)
- `acosh(NaN)`   = `NaN`     (input passed through with quiet-bit set)
- `acosh(x)` for `x < 1` (incl. negative, ±0, subnormal) = `NaN` (domain).
- `acosh(-Inf)`  = `NaN`     (out of domain).

Algorithm: four-regime branchless port of Julia stdlib `Base.acosh`,
using `soft_log1p` for the `1 ≤ x < 2` branch. Single `soft_log1p`
call, single `soft_log` call (with regime-selected argument), two
`soft_fsqrt`. See file header for trade-offs vs the pre-Bennett-tfmo-
followup K=15 polynomial implementation.
"""
@inline function soft_acosh(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # NaN classification on the full bit pattern.
    ea     = (a >> 52) & UInt64(0x7FF)
    fa     = a & FRAC_MASK
    is_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    # Domain check: x < 1?
    #   - For x < 0 (sign bit set): definitely < 1.
    #   - For 0 ≤ x: unsigned bit comparison (a < 1.0_bits) iff x < 1.
    #   - NaN bit patterns slip through this check; final is_nan override fixes them.
    is_negative   = (a & SIGN_BIT) != UInt64(0)
    is_lt_one_pos = a < _ACOSH_ONE_BITS
    is_below_one  = is_negative | is_lt_one_pos

    # Regime predicates (positive-x bit-pattern compares).
    is_med  = a >= _ACOSH_TWO_BITS    # 2 ≤ x  → regime (c) or (d)
    is_huge = a >= _ACOSH_HUGE_BITS   # 2^28 ≤ x  → regime (d)

    # Regime (b) intermediates: t = x - 1; arg = t + sqrt(2t + t²)
    t            = soft_fsub(a, _ACOSH_ONE_BITS)
    two_t        = soft_fadd(t, t)                            # 2t
    t_squared    = soft_fmul(t, t)                            # t²
    inner_b      = soft_fadd(two_t, t_squared)                # 2t + t²
    sqrt_b       = soft_fsqrt(inner_b)
    arg_b        = soft_fadd(t, sqrt_b)
    result_b_pos = soft_log1p(arg_b)

    # Regime (c) intermediates: 2x - 1/(x + sqrt(x²-1))
    x_squared    = soft_fmul(a, a)
    x_sq_m1      = soft_fsub(x_squared, _ACOSH_ONE_BITS)
    sqrt_c       = soft_fsqrt(x_sq_m1)
    x_p_sqrt     = soft_fadd(a, sqrt_c)
    inv_x_p_sqrt = soft_fdiv(_ACOSH_ONE_BITS, x_p_sqrt)
    two_x        = soft_fadd(a, a)
    arg_c        = soft_fsub(two_x, inv_x_p_sqrt)

    # Regimes (c) and (d) share one soft_log call with regime-selected arg.
    log_arg      = ifelse(is_huge, a, arg_c)
    log_v        = soft_log(log_arg)
    result_c_pos = log_v
    result_d_pos = soft_fadd(log_v, _ACOSH_LN2_BITS)

    # Cascade compose. Regime (b) default; (c) overrides for x ≥ 2;
    # (d) overrides for x ≥ 2^28; NaN for x < 1 next; input-NaN last.
    result = result_b_pos
    result = ifelse(is_med,       result_c_pos,    result)
    result = ifelse(is_huge,      result_d_pos,    result)
    result = ifelse(is_below_one, _ACOSH_NAN_BITS, result)
    result = ifelse(is_nan,       a | QUIET_BIT,   result)
    return result
end
