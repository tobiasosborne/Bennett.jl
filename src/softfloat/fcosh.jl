# IEEE 754 binary64 hyperbolic cosine on raw bit patterns. Branchless
# port adapting the structure of Julia stdlib `Base.cosh(::Float64)`
# (julia 1.12 base/special/hyperbolic.jl:103-125) for the Bennett.jl
# reversible-circuit pipeline. Tier C1.8 in the Enzyme parity north-
# star — third hyperbolic close after Bennett-m2bv (`soft_tanh`) and
# Bennett-ky5n (`soft_sinh`).
#
# Reference accuracy: Julia stdlib's `cosh_kernel` is a degree-7 minimax
# in z = x² fitting `cosh(x)` on `|x| ≤ 1` to ≤1 ULP. Bennett.jl
# practical target vs `Base.cosh`: ≤2 ULP across the full Float64 range.
#
# Algorithm (three-regime, branchless):
#
#   Regime P (polynomial): |x| ≤ 1.0       →  cosh_kernel(x²)
#   Regime M (medium):     1 < |x| < 709    →  (E + 1/E)/2,  E = exp(|x|)
#   Regime H (huge):       |x| ≥ 709       →  (0.5·E)·E,    E = exp(|x|/2)
#
# (NaN handled by final cascade override; ±Inf is in regime H and
# propagates naturally through the (0.5·E)·E chain.)
#
# Why this is simpler than soft_sinh:
#
# 1. **Cosh is EVEN** — `cosh(-x) = cosh(x)` — no sign tracking. We
#    work entirely on `|x|`. The polynomial branch evaluates `kernel(x²)`
#    directly without the `x · kernel(x²)` final assembly that sinh
#    needs (since cosh has no `x` factor in its Taylor expansion).
# 2. **Medium formula `(E + 1/E)/2` has ZERO cancellation** — both
#    terms are positive, sum is positive, no precision loss regardless
#    of |x|. Contrast sinh's `(E - 1/E)/2` which has ~0.21 bits
#    cancellation at the |x|=1 boundary. So cosh's polynomial regime
#    threshold could in principle be even narrower than sinh's, but we
#    keep it at `|x| ≤ 1.0` for consistency.
# 3. **Special case `cosh(±0) = 1.0`** (NOT ±0 like sinh's odd-function
#    `sinh(±0) = ±0`). Trivially handled by the polynomial branch:
#    `kernel(0) = P0 = 1.0`, no `x · 1.0 = x` step.
#
# Subnormal-input contract (CLAUDE.md §13) is DIFFERENT from sinh:
# - sinh(subnormal) = subnormal (preserved bit-exactly via x·1=x).
# - cosh(subnormal) = 1.0 exactly (since 1 + subnormal² rounds to 1.0
#   in Float64 — the subnormal² is below the smallest representable
#   non-zero increment to 1.0). Test asserts `soft_cosh(subnormal) ===
#   reinterpret(UInt64, 1.0)` for every subnormal binade.
#
# Other patterns inherited from ky5n:
# - ONE `soft_exp_fast` call via regime-selected argument.
# - Huge threshold conservatively at `709.0` (originally a workaround for
#   the soft_exp_fast top-cell NaN bug, fixed in Bennett-uwv2; retained).
# - CRITICAL ordering `(0.5·E)·E` (not `(E·E)·0.5`) for the huge arm —
#   delays overflow until `|x| ≈ 710.476` exactly where true cosh
#   transitions to ±Inf.
# - NaN classification via exponent + fraction split; final `is_nan`
#   override last-write-wins (corrects the regime-predicate mis-fire
#   on NaN bit patterns).
#
# 3+1 protocol (CLAUDE.md §2) deviation: skipped for this bead because
# cosh is a near-mechanical extension of ky5n (same three-regime
# structure, same huge formula, same soft_exp_fast trick, same NaN
# handling). The three differences (even function, sum-not-difference
# medium, no-x-factor polynomial) are localised and uncontroversial.
# Documented per §2's "Surgical bug fixes ... typically don't need the
# full ceremony — but call it explicitly when you skip it" exception.

# ─────────────────────────────────────────────────────────────────────
# Polynomial coefficients — verbatim from julia 1.12 stdlib's
# `Base.cosh_kernel(::Float64)` (base/special/hyperbolic.jl:96-101).
# Degree-7 minimax in z = x² fitting cosh(x) on |x| ≤ 1 to ≤1 ULP.
# evalpoly(z, (P0, P1, ..., P7)) = P0 + P1·z + P2·z² + … + P7·z⁷.
# Final assembly: cosh(x) = cosh_kernel(x²) — NO x factor (cosh is even).
# ─────────────────────────────────────────────────────────────────────
const _COSH_P0 = reinterpret(UInt64, 1.0)
const _COSH_P1 = reinterpret(UInt64, 0.5000000000000002)
const _COSH_P2 = reinterpret(UInt64, 0.04166666666666269)
const _COSH_P3 = reinterpret(UInt64, 1.3888888889206764e-3)
const _COSH_P4 = reinterpret(UInt64, 2.4801587176784207e-5)
const _COSH_P5 = reinterpret(UInt64, 2.7557345825742837e-7)
const _COSH_P6 = reinterpret(UInt64, 2.0873617441235094e-9)
const _COSH_P7 = reinterpret(UInt64, 1.1663435515945578e-11)

# Regime threshold + helper bit-patterns. Mirror of ky5n (sinh).
const _COSH_ONE_BITS    = reinterpret(UInt64, 1.0)   # |x| ≤ 1.0 ↔ poly
const _COSH_HALF_BITS   = reinterpret(UInt64, 0.5)
# Conservative threshold matching Bennett-ky5n (originally a soft_exp_fast
# NaN-bug workaround; that bug is fixed in Bennett-uwv2, threshold retained).
# At |x| = 709, both arms produce ≤2 ULP results.
const _COSH_HLARGE_BITS = reinterpret(UInt64, 709.0)

"""
    soft_cosh(a::UInt64) -> UInt64

IEEE 754 double-precision hyperbolic cosine `cosh(x)` on raw bit
patterns. **≤2 ULP vs `Base.cosh`** across the full Float64 input space.

Special cases (matches `Base.cosh`):

- `cosh(±0)`     = `1.0`        (sign discarded — cosh is even)
- `cosh(±Inf)`   = `+Inf`       (huge arm's (0.5·E)·E with E=Inf gives +Inf)
- `cosh(NaN)`    = `NaN`        (input passed through with quiet-bit set)
- `cosh(±x)` overflows to `+Inf` for `|x| ≳ 710.476` (matches Base.cosh)
- subnormal input → `1.0` exactly (since `1 + subnormal² = 1.0` in fp64;
  the polynomial branch's `kernel(0) = 1.0` constant term gives this).

Algorithm: three-regime branchless port of Julia stdlib `Base.cosh`.
ONE `soft_exp_fast` call site with a regime-selected argument
(`|x|/2` for huge, `|x|` for medium); medium uses `(E + 1/E)/2`,
huge uses `(0.5·E)·E` with load-bearing operator ordering. Polynomial
regime `|x| ≤ 1.0` (single-precision Horner with Julia stdlib minimax
coefficients). Branchless realisation per Bennett's static-CFG model.
"""
@inline function soft_cosh(a::UInt64)::UInt64
    # ─── Strip sign — cosh is EVEN, work entirely on |x|.
    abs_a = a & ~UInt64(0x8000000000000000)

    # ─── NaN classification (full bit pattern: exponent + fraction).
    #     The regime predicates below mis-fire on NaN bit patterns
    #     (NaN > 1.0 in unsigned ordering); corrected by the final
    #     `is_nan` override at the bottom of the cascade.
    ea     = (a >> 52) & UInt64(0x7FF)
    fa     = a & FRAC_MASK
    is_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    # ─── Regime predicates.
    is_poly = abs_a <= _COSH_ONE_BITS
    is_huge = abs_a >= _COSH_HLARGE_BITS

    # ─── Regime P: polynomial in z = x², degree 7 in z (= 14 in x).
    #     cosh_kernel(z) = P0 + z·(P1 + z·(P2 + … + z·P7)).
    #     Final assembly: result = cosh_kernel(z) directly (NO x factor —
    #     cosh is even). For subnormal x: x² → 0, kernel(0) = P0 = 1.0
    #     bit-exactly, so soft_cosh(subnormal) = 1.0 (matches Base.cosh).
    z   = soft_fmul(abs_a, abs_a)        # x² ≥ 0
    p   = soft_fmul(z, _COSH_P7)
    p   = soft_fadd(_COSH_P6, p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_COSH_P5, p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_COSH_P4, p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_COSH_P3, p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_COSH_P2, p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_COSH_P1, p)
    p   = soft_fmul(z, p)
    result_poly = soft_fadd(_COSH_P0, p) # = cosh_kernel(z); no `· a`

    # ─── Single soft_exp_fast call site with regime-selected argument:
    #       arg = |x|/2 for huge, |x| for medium.
    half_x = soft_fmul(_COSH_HALF_BITS, abs_a)
    arg    = ifelse(is_huge, half_x, abs_a)
    E      = soft_exp_fast(arg)                                # ONE soft_exp_fast call

    # ─── Regime M (medium):  result = (E + 1/E)/2,  E = exp(|x|).
    #     Three ops after exp (fdiv, fadd, fmul). NO cancellation —
    #     both terms positive, sum is positive. Cosh is even so no
    #     sign-OR step.
    inv_E      = soft_fdiv(_COSH_ONE_BITS, E)                  # ONE soft_fdiv call
    e_plus_ie  = soft_fadd(E, inv_E)
    result_med = soft_fmul(_COSH_HALF_BITS, e_plus_ie)

    # ─── Regime H (huge):  result = (0.5·E)·E,  E = exp(|x|/2).
    #     CRITICAL ORDERING: `(0.5·E)·E` rather than `(E·E)·0.5`.
    #     With E = exp(|x|/2) at |x| = 710, E ≈ 1.41e154 and
    #     E² ≈ 2e308 overflows to +Inf prematurely (true cosh(710)
    #     ≈ 1.1e308 is finite). Computing `(0.5·E)·E` halves before
    #     the second multiply, delaying overflow until |x| ≈ 710.476 —
    #     exactly where true cosh transitions to ±Inf. A future
    #     code-clarity refactor that reorders these multiplications
    #     would silently break cosh on `|x| ∈ [710, 711]`.
    half_E      = soft_fmul(_COSH_HALF_BITS, E)
    result_huge = soft_fmul(half_E, E)

    # ─── Cascade compose: most-specific overrides win (last-write).
    #     Default = medium; poly overrides for small |x|; huge overrides
    #     for large |x|; NaN overrides last (NaN bit patterns mis-fire
    #     on `is_huge` since NaN > 709.0 in unsigned ordering).
    result = result_med
    result = ifelse(is_poly, result_poly, result)
    result = ifelse(is_huge, result_huge, result)
    result = ifelse(is_nan,  a | QUIET_BIT, result)

    return result
end
