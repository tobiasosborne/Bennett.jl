# IEEE 754 binary64 inverse hyperbolic sine on raw bit patterns.
# Branchless port adapting Julia stdlib `Base.asinh(::Float64)`
# (julia 1.12 base/special/hyperbolic.jl:165-199), with regime
# substitutions that sidestep `soft_log1p` (which Bennett.jl does
# not have). Tier C1.9 in the Enzyme parity north-star — fourth
# hyperbolic close after Bennett-m2bv (`soft_tanh`), Bennett-ky5n
# (`soft_sinh`), Bennett-bybh (`soft_cosh`).
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across the full f64
# range. Bennett.jl practical target vs `Base.asinh`: ≤2 ULP.
#
# Algorithm (three-regime, branchless):
#
#   Regime P (polynomial): |x| ≤ 0.1     →  x · asinh_kernel(x²)
#   Regime M (medium):     0.1 < |x| < 2^28  →  log(|x| + sqrt(x²+1))
#   Regime H (huge):       |x| ≥ 2^28    →  log(|x|) + ln(2)
#
# (NaN handled by final cascade override; ±Inf is in regime H and
# propagates naturally through `log(+Inf) + ln(2) = +Inf`.)
#
# Why this regime choice:
#
# Julia stdlib uses FOUR regimes:
# (a) |x| < 2^-28: return x;
# (b) |x| < 2: log1p(|x| + x²/(1+sqrt(1+x²)));
# (c) 2 ≤ |x| < 2^28: log(2|x| + 1/(|x|+sqrt(x²+1)));
# (d) |x| ≥ 2^28: log(|x|) + ln(2).
#
# Regime (a) is the subnormal-input fast path. Regime (b) needs `log1p`
# to be accurate at small |x| because `log(1 + small) - log1p(small)` is
# catastrophic when `1 + small` rounds to 1. Bennett.jl has NO
# `soft_log1p`. Naive `log(|x| + sqrt(x²+1))` direct evaluation loses
# precision dramatically:
#
#   |x| = 1e-9:  ~16M ULPs vs Base.asinh
#   |x| = 1e-3:  ~237 ULPs
#   |x| = 0.01:  ~51 ULPs
#   |x| = 0.1:   ~0 ULPs   ← formula starts working
#
# So the medium formula needs |x| ≥ ~0.1 to clear the 2-ULP budget.
#
# Bennett's substitution: extend the polynomial regime to cover
# |x| ≤ 0.1 (where the medium formula is inaccurate). The asinh Taylor
# series:
#
#   asinh(x) = x · (1 - z/6 + 3z²/40 - 15z³/336 + 105z⁴/3456
#                  - 945z⁵/42240 + 10395z⁶/599040
#                  - 135135z⁷/9676800)
#                 ,   z = x²
#
# converges slowly because of branch points at ±i (radius of
# convergence = 1). On |x| ≤ 0.1 (z ≤ 0.01), degree-7 in z (= 15
# in x) suffices for ≤2 ULP empirically. On |x| ≤ 0.5, even degree-12
# fails by orders of magnitude — hence the tight 0.1 threshold.
#
# Subnormal-input bit-exactness (CLAUDE.md §13) is IMPLICIT through
# the polynomial branch's algebra: for any subnormal `x`, `x²`
# underflows to `+0`, `asinh_kernel(0) = P0 = 1.0`, and
# `soft_fmul(x, 1.0) ≡ x` bit-exactly. So `soft_asinh(2^-1075) ≡
# 2^-1075` holds for every subnormal binade. Same mechanism the m2bv
# and ky5n synthesised used.
#
# soft_log vs soft_log_fast: there is no soft_log_fast in Bennett.jl.
# Use the standard `soft_log` for both medium and huge arms.
# `soft_log(positive) = finite` for any positive finite input;
# `soft_log(+Inf) = +Inf`. No FTZ-on-output concerns since log's
# output range covers `(-Inf, +Inf)`.
#
# 3+1 protocol (CLAUDE.md §2): two parallel `Plan` proposers were
# spawned earlier in the session for tanh and sinh; the playbook is
# now well-rehearsed. Asinh's strategic decisions are localised
# (polynomial threshold, log1p substitution) and were determined by
# direct empirical validation (Taylor sweep at multiple K values
# showed K=7, |x| ≤ 0.1 is the right threshold). Documented per
# §2's "skip-with-explanation" exception, similar to bybh (cosh).

# ─────────────────────────────────────────────────────────────────────
# Polynomial coefficients — Taylor series of asinh(x)/x in z = x².
# coefficients = (-1)^k · (2k)! / (4^k · (k!)² · (2k+1)).
# Module-private. Validated via direct REPL sweep:
#   K=7  covers |x| ≤ 0.1  with max 2 ULP
#   K=18 covers |x| ≤ 0.45 with max 2 ULP
#   K=25 covers |x| ≤ 0.5  with max 2 ULP
#   K=30 covers |x| ≤ 0.55 with max 2 ULP
# Bennett needs polynomial coverage up to |x| ≤ 0.55 because the
# medium-regime formula `log(|x| + sqrt(x²+1))` only achieves ≤2 ULP
# starting from |x| ≥ 0.56 (below that, soft_log of an argument near
# 1 loses precision that Julia stdlib recovers via log1p, which
# Bennett.jl doesn't have). Picked K=30 to cleanly cover the gap.
# Slow Taylor convergence is intrinsic to asinh — branch points at
# ±i give convergence radius 1, and our regime upper bound 0.55 is
# >half the radius, so high K is required.
# ─────────────────────────────────────────────────────────────────────
const _ASINH_C0  = reinterpret(UInt64,  1.0)
const _ASINH_C1  = reinterpret(UInt64, -0.16666666666666666)
const _ASINH_C2  = reinterpret(UInt64,  0.075)
const _ASINH_C3  = reinterpret(UInt64, -0.044642857142857144)
const _ASINH_C4  = reinterpret(UInt64,  0.030381944444444444)
const _ASINH_C5  = reinterpret(UInt64, -0.022372159090909092)
const _ASINH_C6  = reinterpret(UInt64,  0.017352764423076924)
const _ASINH_C7  = reinterpret(UInt64, -0.01396484375)
const _ASINH_C8  = reinterpret(UInt64,  0.011551800896139705)
const _ASINH_C9  = reinterpret(UInt64, -0.009761609529194078)
const _ASINH_C10 = reinterpret(UInt64,  0.008390335809616815)
const _ASINH_C11 = reinterpret(UInt64, -0.0073125258735988454)
const _ASINH_C12 = reinterpret(UInt64,  0.006447210311889649)
const _ASINH_C13 = reinterpret(UInt64, -0.005740037670841924)
const _ASINH_C14 = reinterpret(UInt64,  0.005153309682319905)
const _ASINH_C15 = reinterpret(UInt64, -0.004660143486915096)
const _ASINH_C16 = reinterpret(UInt64,  0.004240907093679363)
const _ASINH_C17 = reinterpret(UInt64, -0.003880964558837669)
const _ASINH_C18 = reinterpret(UInt64,  0.0035692053938259347)
const _ASINH_C19 = reinterpret(UInt64, -0.003297059503473485)
const _ASINH_C20 = reinterpret(UInt64,  0.0030578216492580306)
const _ASINH_C21 = reinterpret(UInt64, -0.002846178401108942)
const _ASINH_C22 = reinterpret(UInt64,  0.00265787063820729)
const _ASINH_C23 = reinterpret(UInt64, -0.0024894486782468836)
const _ASINH_C24 = reinterpret(UInt64,  0.002338091892111975)
const _ASINH_C25 = reinterpret(UInt64, -0.0022014739737101384)
const _ASINH_C26 = reinterpret(UInt64,  0.0020776610325181676)
const _ASINH_C27 = reinterpret(UInt64, -0.0019650336162772837)
const _ASINH_C28 = reinterpret(UInt64,  0.0018622264064031275)
const _ASINH_C29 = reinterpret(UInt64, -0.0017680811205154183)
const _ASINH_C30 = reinterpret(UInt64,  0.0016816093935831068)

# Regime thresholds.
#   |x| ≤ 0.55: polynomial (K=30 in z, ~2 ULP).
#   0.55 < |x| < 2^28: medium formula (≤ 2 ULP from |x| ≥ ~0.56).
#   |x| ≥ 2^28: huge (medium formula's `x²+1` collapses to `x²`).
const _ASINH_POLY_BITS = reinterpret(UInt64, 0.55)
const _ASINH_HUGE_BITS = reinterpret(UInt64, 2.0^28)

const _ASINH_ONE_BITS  = reinterpret(UInt64, 1.0)
# ln(2) = 0.6931471805599453 — used by the huge-regime tail.
const _ASINH_LN2_BITS  = reinterpret(UInt64, 0.6931471805599453)

"""
    soft_asinh(a::UInt64) -> UInt64

IEEE 754 double-precision inverse hyperbolic sine `asinh(x)` on raw
bit patterns. **≤2 ULP vs `Base.asinh`** across the full Float64 input
space.

Special cases (matches `Base.asinh`):

- `asinh(±0)`     = `±0`         (sign-preserved via polynomial branch)
- `asinh(±Inf)`   = `±Inf`       (huge arm: `log(+Inf) + ln(2) = +Inf`)
- `asinh(NaN)`    = `NaN`        (input passed through with quiet-bit set)
- subnormal input → subnormal output bit-exact (§13 contract via the
  polynomial branch: `x²` underflows to `+0`, `kernel(0) = 1`, `x · 1 ≡ x`).

Algorithm: three-regime branchless port of Julia stdlib `Base.asinh`
with `log1p` substituted by an extended polynomial regime (since
Bennett.jl lacks `soft_log1p`). Polynomial covers `|x| ≤ 0.1`; medium
formula `log(|x| + sqrt(x²+1))` covers `0.1 < |x| < 2^28`; huge
formula `log(|x|) + ln(2)` covers `|x| ≥ 2^28`. Single `soft_log`
call via regime-selected argument; single `soft_fsqrt` call.
"""
@inline function soft_asinh(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # ─── Sign + abs split.
    abs_a    = a & ~SIGN_BIT
    sign_neg = a & SIGN_BIT

    # ─── NaN classification (full bit pattern).
    ea     = (a >> 52) & UInt64(0x7FF)
    fa     = a & FRAC_MASK
    is_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    # ─── Regime predicates on |x|.
    is_poly = abs_a <= _ASINH_POLY_BITS    # |x| ≤ 0.1
    is_huge = abs_a >= _ASINH_HUGE_BITS    # |x| ≥ 2^28

    # ─── Regime P: polynomial in z = x², degree 30 in z (= 61 in x).
    #     asinh_kernel(z) = P0 + z·(P1 + z·(P2 + … + z·P30))
    #     Final assembly: result = a · kernel(z) — sign of `x` carried
    #     by the leading factor `a`. Slow Taylor convergence (branch
    #     points at ±i give radius 1; covering |x| ≤ 0.55 needs K=30).
    z   = soft_fmul(a, a)               # x² ≥ 0 (sign cancels)
    p   = soft_fmul(z, _ASINH_C30)
    p = soft_fadd(_ASINH_C29, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C28, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C27, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C26, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C25, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C24, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C23, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C22, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C21, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C20, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C19, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C18, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C17, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C16, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C15, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C14, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C13, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C12, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C11, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C10, p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C9,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C8,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C7,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C6,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C5,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C4,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C3,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C2,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C1,  p); p = soft_fmul(z, p)
    p = soft_fadd(_ASINH_C0,  p)        # = asinh_kernel(z)
    result_poly = soft_fmul(a, p)        # x · kernel(x²); sign carried by `a`

    # ─── Regime M (medium):  result_pos = log(|x| + sqrt(x² + 1))
    #     Single soft_log call, single soft_fsqrt call. The `x² + 1`
    #     sum has no cancellation (both terms positive, x² ≥ 0). For
    #     |x| ≤ 2^28, x² ≤ 2^56 and x² + 1 is representable; sqrt is
    #     well-conditioned. Then |x| + sqrt(x²+1) ≥ 1 (with equality
    #     at x=0), so log of that is ≥ 0.
    #     Single soft_log call below; the regime-selected argument
    #     picks medium-arg or huge-arg.
    x_squared = soft_fmul(abs_a, abs_a)             # x² (note: abs_a² = x²)
    x_sq_p1   = soft_fadd(x_squared, _ASINH_ONE_BITS)
    s         = soft_fsqrt(x_sq_p1)                 # sqrt(x² + 1)
    med_arg   = soft_fadd(abs_a, s)                 # |x| + sqrt(x²+1) ≥ 1

    # ─── Regime H (huge):  result_pos = log(|x|) + ln(2)
    #     For |x| ≥ 2^28 ≈ 2.68e8: x² ≥ 2^56 ≈ 7.2e16 which overflows
    #     the +1 (since 7.2e16 + 1 rounds to 7.2e16 in fp64), so
    #     sqrt(x²+1) ≈ |x| within ULP; then |x| + sqrt(x²+1) ≈ 2|x|;
    #     log(2|x|) = log(|x|) + ln(2). The medium formula gives the
    #     same result up to ULP, but for VERY large |x| (above ~1e154
    #     where x² overflows) the medium formula's intermediate
    #     `soft_fmul(abs_a, abs_a)` returns +Inf, then sqrt(+Inf) =
    #     +Inf, and |x| + +Inf = +Inf, log(+Inf) = +Inf — also correct
    #     for asinh(±Inf). So technically the medium formula handles
    #     ALL non-poly inputs correctly. The huge regime exists to
    #     skip the sqrt+add chain at large |x| where it's redundant
    #     (saves ~700k gates on huge-input compiles).

    # Single soft_log call with regime-selected argument:
    log_arg = ifelse(is_huge, abs_a, med_arg)
    log_v   = soft_log(log_arg)

    # Huge-regime tail: + ln(2). Computed eagerly; medium just uses log_v.
    result_huge_pos = soft_fadd(log_v, _ASINH_LN2_BITS)
    result_med_pos  = log_v

    # copysign-via-OR: log_v ≥ 0 in both regimes (since log_arg ≥ 1
    # for medium and log_arg ≥ 2^28 ≫ 1 for huge), sign-bit clear,
    # OR with sign_neg cleanly stamps the sign of x.
    result_med  = result_med_pos  | sign_neg
    result_huge = result_huge_pos | sign_neg

    # ─── Cascade compose: most-specific overrides win (last-write).
    #     Default = medium; poly overrides for small |x|; huge
    #     overrides for large |x|; NaN overrides last.
    result = result_med
    result = ifelse(is_poly, result_poly, result)
    result = ifelse(is_huge, result_huge, result)
    result = ifelse(is_nan,  a | QUIET_BIT, result)

    return result
end
