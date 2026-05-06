# IEEE 754 binary64 hyperbolic tangent on raw bit patterns. Branchless
# port of Julia stdlib `Base.tanh(::Float64)` (julia/base/special/
# hyperbolic.jl:128-159, julia 1.12). Tier C1.6 in the Enzyme parity
# north-star (`Bennett-Enzyme-Parity-NorthStar.md`); follow-on to
# Bennett-7goc (soft_atan2) and the first hyperbolic primitive in the
# six-bead C1 hyperbolic completion (sinh, cosh, tanh, asinh, acosh,
# atanh).
#
# Reference accuracy: Julia's stdlib `tanh_kernel` is a degree-10
# minimax in z = x² fitting tanh(x)/x on |x| ≤ 1 to ≤1 ULP. Bennett.jl
# practical target vs `Base.tanh`: ≤2 ULP across the full Float64 range.
#
# Algorithm (Julia stdlib regime-split — three regimes):
#
#   Regime S (saturate):   |x| ≥ 22       → copysign(1.0, x)
#   Regime P (polynomial): |x| ≤ 0.5      → x · tanh_kernel(x²)
#   Regime E (exp-formula): otherwise     → copysign(1 - 2/(exp(2|x|)+1), x)
#
# (Threshold values: TANH_LARGE_X(Float64) = 44.0, so |2x| ≥ 44 means
# |x| ≥ 22; TANH_SMALL_X(Float64) = 1.0, so |2x| ≤ 1 means |x| ≤ 0.5.)
#
# Bennett-branchless realisation: ALL THREE regime arms are computed
# eagerly; an ifelse-cascade selects the result (constant dispatch cost
# — load-bearing for Bennett's static-CFG model). NaN propagation is
# the final override (last-write-wins).
#
# Subnormal-input preservation (CLAUDE.md §13 / Bennett-fnxg) is
# IMPLICIT: for any subnormal x, x² underflows to +0, tanh_kernel(0) =
# 1.0 (the constant term of the polynomial), and soft_fmul(x, 1.0) === x
# bit-exactly. So `soft_tanh(2^-1075) === 2^-1075` holds by construction
# for every subnormal binade — no explicit override needed. The
# subnormal-input testset asserts 0 ULP across binades -1075..-1022.
#
# soft_exp_fast vs soft_exp: per fexp.jl the FTZ-on-output branch only
# fires for input in [-745.13, -708.40] (negative). Our argument to the
# exp call is `2|x| ≥ 0` (always non-negative). So `soft_exp_fast` and
# `soft_exp` are bit-identical for our use — and `soft_exp_fast` is
# ~1.4M gates cheaper. Choosing `soft_exp_fast` here costs zero accuracy
# and saves substantial circuit area.
#
# Why NOT a verbatim musl `s_tanh.c` port: musl's small-arg branch
# uses `expm1(-2|x|)`, which Bennett.jl does NOT have as a primitive.
# Substituting `soft_exp(-2|x|) - 1.0` would suffer catastrophic
# cancellation at small |x| (the dominant term is exactly -1, not the
# residual ≈2|x|), violating the §13 subnormal-output contract. The
# Julia stdlib path replaces the small-arg branch with a direct minimax
# polynomial in x²; the polynomial preserves all 53 bits at small |x|.
# This pattern is documented in Julia's hyperbolic.jl comments
# (lines 145-152): "0 <= x < TANH_SMALL_X: Use a minimax polynomial
# over the range".

# ─────────────────────────────────────────────────────────────────────
# Polynomial coefficients — verbatim from julia 1.12 stdlib's
# `Base.tanh_kernel(::Float64)` in base/special/hyperbolic.jl:132-138.
# Degree-10 minimax in z = x² fitting tanh(x)/x on |x| ≤ 1 to ≤1 ULP.
# `evalpoly(z, (1.0, c1, c2, …, c10))` returns
#   tanh_kernel(z) = 1.0 + c1·z + c2·z² + … + c10·z¹⁰
# and the final assembly is `tanh(x) = x · tanh_kernel(x²)` for |x| ≤ 0.5.
# ─────────────────────────────────────────────────────────────────────
const _TANH_P0  = reinterpret(UInt64,  1.0)
const _TANH_P1  = reinterpret(UInt64, -0.33333333333332904)
const _TANH_P2  = reinterpret(UInt64,  0.13333333333267555)
const _TANH_P3  = reinterpret(UInt64, -0.05396825393066753)
const _TANH_P4  = reinterpret(UInt64,  0.02186948742242217)
const _TANH_P5  = reinterpret(UInt64, -0.008863215974794633)
const _TANH_P6  = reinterpret(UInt64,  0.003591910693118715)
const _TANH_P7  = reinterpret(UInt64, -0.0014542587440487815)
const _TANH_P8  = reinterpret(UInt64,  0.0005825521659411748)
const _TANH_P9  = reinterpret(UInt64, -0.00021647574085351332)
const _TANH_P10 = reinterpret(UInt64,  5.5752458452673005e-5)

# Regime thresholds. Compared bit-as-UInt64 against |x| (which is non-
# negative finite or +Inf — for non-negative finite/Inf values, unsigned
# UInt64 ordering coincides with magnitude ordering). NaN bit patterns
# have abs > _TANH_22_BITS so `is_saturate` mis-fires on NaN; the final
# `is_nan` override at the end of the cascade restores correctness.
const _TANH_22_BITS   = reinterpret(UInt64, 22.0)   # |x| ≥ 22 ↔ |2x| ≥ 44 → ±1
const _TANH_HALF_BITS = reinterpret(UInt64, 0.5)    # |x| ≤ 0.5 ↔ |2x| ≤ 1 → poly
const _TANH_TWO_BITS  = reinterpret(UInt64, 2.0)
const _TANH_ONE_BITS  = reinterpret(UInt64, 1.0)

"""
    soft_tanh(a::UInt64) -> UInt64

IEEE 754 double-precision hyperbolic tangent `tanh(x)` on raw bit
patterns. **≤2 ULP vs `Base.tanh`** across the full Float64 input space.

Special cases (matches `Base.tanh`):

- `tanh(±0)`     = `±0`         (preserved via polynomial branch)
- `tanh(±Inf)`   = `±1`
- `tanh(NaN)`    = `NaN`        (input passed through with quiet-bit set)
- `tanh(±x)` for `|x| ≥ 22` = `±1` bit-exact
- subnormal input → subnormal output bit-exact (§13 contract via the
  polynomial branch: `x²` underflows to `+0`, `tanh_kernel(0) = 1.0`,
  `x · 1.0 ≡ x`).

Algorithm: Julia stdlib regime split (`base/special/hyperbolic.jl:143`):
poly for `|x| ≤ 0.5`, `1 - 2/(exp(2|x|)+1)` for `0.5 < |x| < 22`,
saturate to `±1` for `|x| ≥ 22`. Polynomial coefficients copied
verbatim from `Base.tanh_kernel(::Float64)`. ONE `soft_exp_fast` call
on `2|x|`; ONE `soft_fdiv`. Branchless realisation per Bennett's
static-CFG model.
"""
@inline function soft_tanh(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # ─── Sign + abs split. Sign-bit kept as raw mask (0 or SIGN_BIT) so
    #     it can be OR-set onto a non-negative result for copysign-via-OR.
    abs_a    = a & ~SIGN_BIT
    sign_neg = a & SIGN_BIT

    # ─── NaN classification (full bit pattern: exponent + fraction).
    #     `is_saturate` (below) also fires for NaN bit patterns because
    #     abs_NaN > 22.0 in unsigned ordering — corrected by the final
    #     NaN override at the bottom of the cascade.
    ea     = (a >> 52) & UInt64(0x7FF)
    fa     = a & FRAC_MASK
    is_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    # ─── Regime predicates. Comparisons on UInt64-bits-of-abs are
    #     equivalent to magnitude comparisons for non-negative finite
    #     and +Inf values (and innocuously NaN-affected, see above).
    is_saturate = abs_a >= _TANH_22_BITS    # |x| ≥ 22 → ±1
    is_poly     = abs_a <= _TANH_HALF_BITS  # |x| ≤ 0.5 → polynomial

    # ─── Regime P (polynomial in z = x²).
    #     tanh_kernel(z) = P0 + z·(P1 + z·(P2 + … + z·P10))
    #     evaluated bottom-up via Horner. Final: result = x · kernel(z).
    #     Sign of x is carried implicitly by the final fmul(a, kernel).
    z   = soft_fmul(a, a)               # x² ≥ 0 (sign cancels)
    p   = soft_fmul(z, _TANH_P10)
    p   = soft_fadd(_TANH_P9,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P8,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P7,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P6,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P5,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P4,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P3,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P2,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P1,  p)
    p   = soft_fmul(z, p)
    p   = soft_fadd(_TANH_P0, p)         # = tanh_kernel(z)
    result_poly = soft_fmul(a, p)        # x · kernel(x²); sign carried by `a`

    # ─── Regime E (medium-magnitude exp formula).
    #     `1 - 2/(exp(2|x|)+1)` is in [0, 1) strictly for |x| > 0; we
    #     OR-set the sign bit at the end for copysign(result, x).
    #     SLP-vectorisation guard (Bennett-qpke gotcha #1): only ONE
    #     soft_exp_fast call total in this function — the polynomial
    #     and exp paths share no parallel transcendental calls.
    abs_2x         = soft_fmul(_TANH_TWO_BITS, abs_a)   # |2x| ≥ 0
    k              = soft_exp_fast(abs_2x)              # ONE soft_exp_fast call
    k_plus_1       = soft_fadd(k, _TANH_ONE_BITS)
    two_over_kp1   = soft_fdiv(_TANH_TWO_BITS, k_plus_1)
    one_minus_frac = soft_fsub(_TANH_ONE_BITS, two_over_kp1)
    # copysign-via-OR: one_minus_frac ∈ [0, 1), sign-bit clear, so OR-ing
    # with sign_neg cleanly stamps the sign of x onto the result.
    result_exp     = one_minus_frac | sign_neg

    # ─── Regime S (saturate). copysign(1.0, x) via OR-set on +1.0.
    result_sat = _TANH_ONE_BITS | sign_neg

    # ─── Cascade compose: most-specific overrides win (last-write).
    #     Order from generic (default) to specific: exp ← poly ← saturate.
    result = result_exp
    result = ifelse(is_poly,     result_poly, result)
    result = ifelse(is_saturate, result_sat,  result)

    # ─── NaN override. Must be LAST: `is_saturate` mis-fires for NaN
    #     bit patterns (abs_NaN > _TANH_22_BITS). Pass the input through
    #     with the quiet-bit forced set per IEEE 754-2019 §6.2.3.
    result = ifelse(is_nan, a | QUIET_BIT, result)

    return result
end
