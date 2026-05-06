# IEEE 754 binary64 expm1(x) = exp(x) - 1 on raw bit patterns.
# Branchless port. Tier C2.2 — second C2 transcendental close,
# symmetric counterpart to Bennett-0ulc (`soft_log1p`).
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across the full f64
# range. Bennett.jl practical target vs `Base.expm1`: ≤2 ULP.
#
# Algorithm (three-regime, branchless):
#
#   Regime T (tiny):    |x| < 2^-54  →  return x bit-exactly
#   Regime P (poly):    |x| ≤ 0.5    →  K=15 Taylor x · (c1 + x·(c2 + …))
#   Regime M (medium):  |x| > 0.5    →  exp(x) - 1
#
# Cancellation in `exp(x) - 1` is bounded for |x| > 0.5 because
# `exp(0.5) ≈ 1.65 > 1` (clear of 1) and `exp(-0.5) ≈ 0.607 < 1`
# (also clear). For |x| → ∞, the formula handles ±Inf, NaN, and
# subnormal-regime exp output naturally:
#
#   - x = +Inf: exp(+Inf) = +Inf, +Inf - 1 = +Inf ✓
#   - x = -Inf: exp(-Inf) = 0, 0 - 1 = -1 ✓
#   - x ∈ (-745, -708): exp(x) is subnormal; soft_exp_fast flushes
#     to 0; 0 - 1 = -1 (correct to ULP since true expm1 ≈ -1 + ε
#     where ε is subnormal — rounds to -1 at output)
#   - x = NaN: exp(NaN) = NaN, NaN - 1 = NaN; final cascade override
#     restores the input NaN with QUIET_BIT
#
# Subnormal-input bit-exactness (CLAUDE.md §13) IMPLICIT through the
# tiny regime: every subnormal x has |x| < 2^-1022 < 2^-54 → tiny
# regime fires → return a bit-exactly. So `soft_expm1(2^-1075) ≡
# 2^-1075` for every subnormal binade. Same mechanism as soft_log1p.
#
# Tiny threshold derivation (mirrored from soft_log1p):
# `|expm1(x) - x| ≈ x²/2 ≤ ½ULP(x)` requires `x²/2 ≤ x · 2^-53`,
# i.e. `x ≤ 2^-52`. Pick 2^-54 for ~2 bits margin.
#
# Polynomial: c_k = 1/k! for k = 1..15. K=15 covers |x| ≤ 0.5 with
# ≤1 ULP empirically (validated via direct REPL sweep). Layout:
# `expm1(x) = x · (c_1 + x·(c_2 + x·(c_3 + … + x·c_15)))` where
# c_1 = 1.0 is the linear term — final assembly `result = x · poly`
# carries the sign of x naturally (matches sinh/asinh pattern).
#
# soft_exp_fast vs soft_exp: same FTZ-on-output behavior we want
# here. For x ∈ (-745, -708), soft_exp_fast gives 0 instead of
# subnormal; subtracting 1 gives -1, which equals the true expm1
# value to ULP in that range. ~1.4M gates cheaper.
#
# 3+1 protocol skipped per §2 surgical-extension exception (Bennett-
# 0ulc / log1p was the strategic-decision bead; expm1 is its
# mechanical mirror with three localised differences: Taylor in x
# rather than precision-recovery; uses soft_exp instead of soft_log;
# different special-case overrides).

# ─────────────────────────────────────────────────────────────────────
# Polynomial coefficients — exact rationals: c_k = 1/k! for k = 1..15.
# Layout: expm1(x) = x · evalpoly_horner_inside_out(x, (c_1..c_15))
#       = x·(c_1 + x·(c_2 + … + x·c_15))
# Module-private. K=15 covers |x| ≤ 0.5 to ≤1 ULP per REPL sweep.
# ─────────────────────────────────────────────────────────────────────
const _EXPM1_C1  = reinterpret(UInt64, 1.0)
const _EXPM1_C2  = reinterpret(UInt64, 0.5)
const _EXPM1_C3  = reinterpret(UInt64, 0.16666666666666666)
const _EXPM1_C4  = reinterpret(UInt64, 0.041666666666666664)
const _EXPM1_C5  = reinterpret(UInt64, 0.008333333333333333)
const _EXPM1_C6  = reinterpret(UInt64, 0.001388888888888889)
const _EXPM1_C7  = reinterpret(UInt64, 0.0001984126984126984)
const _EXPM1_C8  = reinterpret(UInt64, 2.48015873015873e-5)
const _EXPM1_C9  = reinterpret(UInt64, 2.7557319223985893e-6)
const _EXPM1_C10 = reinterpret(UInt64, 2.755731922398589e-7)
const _EXPM1_C11 = reinterpret(UInt64, 2.505210838544172e-8)
const _EXPM1_C12 = reinterpret(UInt64, 2.08767569878681e-9)
const _EXPM1_C13 = reinterpret(UInt64, 1.6059043836821613e-10)
const _EXPM1_C14 = reinterpret(UInt64, 1.1470745597729725e-11)
const _EXPM1_C15 = reinterpret(UInt64, 7.647163731819816e-13)

# Regime thresholds.
const _EXPM1_TINY_BITS = reinterpret(UInt64, ldexp(1.0, -54))
const _EXPM1_HALF_BITS = reinterpret(UInt64, 0.5)
const _EXPM1_ONE_BITS  = reinterpret(UInt64, 1.0)

"""
    soft_expm1(a::UInt64) -> UInt64

IEEE 754 double-precision `expm1(x) = exp(x) - 1` on raw bit patterns.
**≤2 ULP vs `Base.expm1`** across the full Float64 input space.

Special cases (matches `Base.expm1`):

- `expm1(±0)`     = `±0`         (sign-preserved via tiny regime)
- `expm1(+Inf)`   = `+Inf`
- `expm1(-Inf)`   = `-1`
- `expm1(NaN)`    = `NaN`        (input passed through with quiet-bit set)
- subnormal input → subnormal output bit-exact (§13: |x| < 2^-54 → x).

Algorithm: three-regime branchless port. Tiny |x| < 2^-54 returns x
directly; |x| ≤ 0.5 uses K=15 Taylor; |x| > 0.5 uses `exp(x) - 1`
(no cancellation issue since exp is well-clear of 1 in that regime).
ONE soft_exp_fast call. Polynomial arm computed eagerly as a parallel
candidate; cascade selects.
"""
@inline function soft_expm1(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)
    abs_a = a & ~SIGN_BIT

    # ─── NaN classification.
    ea     = (a >> 52) & UInt64(0x7FF)
    fa     = a & FRAC_MASK
    is_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    # ─── Regime predicates.
    is_tiny = abs_a < _EXPM1_TINY_BITS
    is_poly = abs_a <= _EXPM1_HALF_BITS

    # ─── Regime P: K=15 Taylor in x.
    #     expm1(x) = x · (c_1 + x · (c_2 + x · (c_3 + … + x · c_15)))
    p   = soft_fmul(a, _EXPM1_C15)
    p = soft_fadd(_EXPM1_C14, p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C13, p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C12, p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C11, p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C10, p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C9,  p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C8,  p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C7,  p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C6,  p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C5,  p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C4,  p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C3,  p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C2,  p); p = soft_fmul(a, p)
    p = soft_fadd(_EXPM1_C1,  p)
    result_poly = soft_fmul(a, p)        # x · (c1 + …); sign carried by `a`

    # ─── Regime M: medium/large via direct exp-1.
    #     soft_exp_fast handles ±Inf, NaN, subnormal-output FTZ
    #     (correct semantics for expm1 since FTZ region's true result
    #     rounds to -1 anyway).
    e          = soft_exp_fast(a)
    result_med = soft_fsub(e, _EXPM1_ONE_BITS)

    # ─── Cascade compose: most-specific overrides win (last-write).
    result = result_med
    result = ifelse(is_poly, result_poly,    result)
    result = ifelse(is_tiny, a,              result)
    result = ifelse(is_nan,  a | QUIET_BIT,  result)
    return result
end
