# IEEE 754 binary64 arcsine on raw bit patterns. Faithful port of musl's
# `src/math/asin.c` (FreeBSD/SunPro 1993, BSD-licensed; identical
# implementation in glibc and Julia-via-openlibm). Tier C1.3 in the
# Enzyme parity north-star (`Bennett-Enzyme-Parity-NorthStar.md`),
# follow-on to Bennett-qpke (soft_atan).
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across [-1, 1].
# Bennett.jl practical target vs `Base.asin`: ≤2 ULP. Bit-exact at
# ±0, ±1, and the tiny-arg fast path (|x| < 2^-26).
#
# ─── Algorithm (musl asin.c, branchless realisation) ──────────────────
#
# Three input regimes via the high 32 bits of |x| (`ix_hi`):
#
#   Path A  |x| < 2^-26       → return `a` bit-exact (tiny override)
#   Path B  2^-26 ≤ |x| < 0.5 → asin(x) = x + x·R(x²)
#   Path C  0.5 ≤ |x| < 1     → asin(x) = π/2 - 2·asin(√((1-|x|)/2))
#                                via two sub-paths:
#                              C₁  |x| > 0.975: pio2_hi - (2(s + s·r) - pio2_lo)
#                              C₂  0.5 ≤ |x| ≤ 0.975: 0.5·pio2_hi - (2·s·r
#                                  - (pio2_lo - 2·c) - (0.5·pio2_hi - 2·f))
#                                  with f = high32(s), c = (z - f²)/(s + f)
#
# Specials:
#   |x| = 1     → ±π/2 bit-exact (musl returns x·pio2_hi which rounds to π/2)
#   |x| > 1     → NaN  (matches musl `0/(x-x)`)
#   x is NaN    → NaN  (propagate input, force quiet bit)
#
# Rational R(z) ≈ (asin(x) - x) / x³ on [0, 0.5]. The Remez error is
# bounded by 2^-58.75, so the final result on |x| < 0.5 is ≤2 ULP. The
# helper `_asin_R(z)` is module-private and SHARED with `soft_acos`
# (Bennett-bd7f, Tier C1.4) per CLAUDE.md §12 (no duplicated lowering).
#
# Branchless realisation: ALL paths are computed; `ifelse` cascades
# select the right value. The `R(...)` call is dispatched ONCE on a
# pre-selected input (x² for Path B, z for Path C) — this matches the
# qpke (atan) gotcha #1 pattern of avoiding parallel `soft_fdiv` shapes
# that the Julia LLVM SLP-vectorizer would auto-vectorise into
# `<N x i64>` ops that Bennett's IR walker rejects.

# ─────────────────────────────────────────────────────────────────────
# Polynomial coefficients pS0..pS5 / qS1..qS4 (FreeBSD e_asin.c, Sun 1993).
# Rational approximation of (asin(x) - x) / x³ on [0, 0.5].
# Decimal forms reproduce the bit-pattern hex comments exactly.
# ─────────────────────────────────────────────────────────────────────
const _ASIN_PS0 = reinterpret(UInt64,  1.66666666666666657415e-01)  # 0x3FC55555_55555555
const _ASIN_PS1 = reinterpret(UInt64, -3.25565818622400915405e-01)  # 0xBFD4D612_03EB6F7D
const _ASIN_PS2 = reinterpret(UInt64,  2.01212532134862925881e-01)  # 0x3FC9C155_0E884455
const _ASIN_PS3 = reinterpret(UInt64, -4.00555345006794114027e-02)  # 0xBFA48228_B5688F3B
const _ASIN_PS4 = reinterpret(UInt64,  7.91534994289814532176e-04)  # 0x3F49EFE0_7501B288
const _ASIN_PS5 = reinterpret(UInt64,  3.47933107596021167570e-05)  # 0x3F023DE1_0DFDF709

const _ASIN_QS1 = reinterpret(UInt64, -2.40339491173441421878e+00)  # 0xC0033A27_1C8A2D4B
const _ASIN_QS2 = reinterpret(UInt64,  2.02094576023350569471e+00)  # 0x40002AE5_9C598AC8
const _ASIN_QS3 = reinterpret(UInt64, -6.88283971605453293030e-01)  # 0xBFE6066C_1B8D0159
const _ASIN_QS4 = reinterpret(UInt64,  7.70381505559019352791e-02)  # 0x3FB3B8C5_B12E9282

# π/2 split into high+low double-double for ~106-bit precision.
const _ASIN_PIO2_HI      = reinterpret(UInt64, 1.57079632679489655800e+00)  # 0x3FF921FB_54442D18
const _ASIN_PIO2_LO      = reinterpret(UInt64, 6.12323399573676603587e-17)  # 0x3C91A626_33145C07
# 0.5·pio2_hi is exact at f64 (just biased-exponent decrement); precompute
# to save one runtime soft_fmul. Equals atan(1.0) bit pattern.
const _ASIN_HALF_PIO2_HI = reinterpret(UInt64, 7.85398163397448278999e-01)  # 0x3FE921FB_54442D18

# Float64 raw bit constants used in the body.
const _ASIN_HALF_BITS = reinterpret(UInt64, 0.5)             # 0x3FE0000000000000
const _ASIN_TWO_BITS  = reinterpret(UInt64, 2.0)             # 0x4000000000000000
# SET_LOW_WORD(f, 0): zero the low 32 mantissa bits to halve f's precision.
const _ASIN_HI32_MASK = UInt64(0xFFFFFFFF00000000)

# High-word range thresholds (matching musl asin.c exactly).
const _ASIN_GE1_HI    = UInt32(0x3ff00000)  # |x| ≥ 1
const _ASIN_LT_HALF_HI = UInt32(0x3fe00000) # |x| < 0.5
const _ASIN_TINY_HI   = UInt32(0x3e500000)  # |x| < 2^-26
const _ASIN_NEAR1_HI  = UInt32(0x3fef3333)  # |x| > 0.975 (mid ↔ near-1 split)

"""
    _asin_R(z::UInt64) -> UInt64

Module-private helper: rational approximation of `(asin(x) - x) / x³`
on `[0, 0.5]`. Used by both `soft_asin` (input z = x²) and `soft_acos`
(input z = (1 - |x|)/2). Single source of truth per CLAUDE.md §12.

Numerator: `p = z·(pS0 + z·(pS1 + z·(pS2 + z·(pS3 + z·(pS4 + z·pS5)))))`
Denominator: `q = 1.0 + z·(qS1 + z·(qS2 + z·(qS3 + z·qS4)))`
Returns `p / q`. Remez error: ≤2^-58.75 on [0, 0.5].
"""
@inline function _asin_R(z::UInt64)::UInt64
    # p = z·(pS0 + z·(pS1 + z·(pS2 + z·(pS3 + z·(pS4 + z·pS5)))))
    p = soft_fmul(z, _ASIN_PS5)
    p = soft_fadd(_ASIN_PS4, p)
    p = soft_fmul(z, p)
    p = soft_fadd(_ASIN_PS3, p)
    p = soft_fmul(z, p)
    p = soft_fadd(_ASIN_PS2, p)
    p = soft_fmul(z, p)
    p = soft_fadd(_ASIN_PS1, p)
    p = soft_fmul(z, p)
    p = soft_fadd(_ASIN_PS0, p)
    p = soft_fmul(z, p)
    # q = 1.0 + z·(qS1 + z·(qS2 + z·(qS3 + z·qS4)))
    q = soft_fmul(z, _ASIN_QS4)
    q = soft_fadd(_ASIN_QS3, q)
    q = soft_fmul(z, q)
    q = soft_fadd(_ASIN_QS2, q)
    q = soft_fmul(z, q)
    q = soft_fadd(_ASIN_QS1, q)
    q = soft_fmul(z, q)
    q = soft_fadd(_RP_ONE_BITS, q)
    return soft_fdiv(p, q)
end

"""
    soft_asin(a::UInt64) -> UInt64

IEEE 754 double-precision arcsine `asin(x)` on raw bit patterns.
**≤2 ULP vs `Base.asin`** across the input domain `[-1, 1]`; bit-exact
on ±0, ±1, and tiny inputs (`|x| < 2^-26`).

Special cases:
- `asin(NaN)`  = NaN  (propagate input, force quiet-bit)
- `asin(±Inf)` = NaN  (|x| > 1 path)
- `asin(±x)` for `|x| > 1` = NaN (matches musl `0/(x-x)`)
- `asin(±0)`   = ±0   (sign-preserving via tiny path)
- `asin(±1)`   = ±π/2 (bit-exact)
- `|x| < 2^-26` → `x` bit-exact

Algorithm: faithful musl `e_asin.c` port (Sun 1993, BSD-licensed). Three
input regimes branchlessly computed, ifelse-selected by high-word range
checks. Single `_asin_R` dispatch per call (ifelse-selected input)
prevents SLP-vectorisation per the qpke (atan) gotcha.
"""
@inline function soft_asin(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # NaN detection up-front (used as last-write-wins override).
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    abs_a    = a & ~SIGN_BIT
    sign_neg = (a & SIGN_BIT) != UInt64(0)
    ix_hi    = UInt32(abs_a >> 32)
    ix_lo    = UInt32(abs_a & UInt64(0xFFFFFFFF))

    # Range dispatch — five flags drive the ifelse cascade.
    is_ge1     = ix_hi >= _ASIN_GE1_HI                        # |x| ≥ 1 or NaN/Inf
    is_eq1     = (ix_hi == _ASIN_GE1_HI) & (ix_lo == UInt32(0))  # |x| = 1 exactly
    is_lt_half = ix_hi <  _ASIN_LT_HALF_HI                    # |x| < 0.5
    is_tiny    = ix_hi <  _ASIN_TINY_HI                       # |x| < 2^-26
    is_near1   = ix_hi >= _ASIN_NEAR1_HI                      # |x| > 0.975

    # ─── Single R-call: input ifelse-selected to avoid SLP-vectorisation.
    # Path B uses R(x²); Path C uses R(z) where z = (1 - |x|)/2.
    xx            = soft_fmul(a, a)                       # x² (sign cancels)
    one_minus_abs = soft_fsub(_RP_ONE_BITS, abs_a)
    z             = soft_fmul(one_minus_abs, _ASIN_HALF_BITS)
    r_arg         = ifelse(is_lt_half, xx, z)
    r             = _asin_R(r_arg)

    # ─── Path B: |x| < 0.5 → x + x·R(x²) ──────────────────────────────
    x_r            = soft_fmul(a, r)
    result_lt_half = soft_fadd(a, x_r)

    # ─── Path C: |x| ≥ 0.5 — sub-paths near-1 and mid both computed.
    s = soft_fsqrt(z)

    # Sub-path C₁ (|x| > 0.975):
    #   y = pio2_hi - (2·(s + s·r) - pio2_lo)
    s_r           = soft_fmul(s, r)
    s_plus_sr     = soft_fadd(s, s_r)
    two_s_plus_sr = soft_fmul(_ASIN_TWO_BITS, s_plus_sr)
    inner_near1   = soft_fsub(two_s_plus_sr, _ASIN_PIO2_LO)
    result_near1  = soft_fsub(_ASIN_PIO2_HI, inner_near1)

    # Sub-path C₂ (0.5 ≤ |x| ≤ 0.975) — SET_LOW_WORD precision trick:
    #   f = high32(s); c = (z - f²) / (s + f)        ← so f + c ≈ √z
    #   y = 0.5·pio2_hi
    #         - (2·s·r - (pio2_lo - 2·c) - (0.5·pio2_hi - 2·f))
    f                   = s & _ASIN_HI32_MASK              # SET_LOW_WORD(f, 0)
    f_f                 = soft_fmul(f, f)
    z_minus_ff          = soft_fsub(z, f_f)
    s_plus_f            = soft_fadd(s, f)
    c                   = soft_fdiv(z_minus_ff, s_plus_f)

    two_s               = soft_fmul(_ASIN_TWO_BITS, s)
    two_s_r             = soft_fmul(two_s, r)              # 2·s·r
    two_c               = soft_fmul(_ASIN_TWO_BITS, c)
    pio2_lo_minus_2c    = soft_fsub(_ASIN_PIO2_LO, two_c)
    inner_mid_a         = soft_fsub(two_s_r, pio2_lo_minus_2c)  # 2·s·r - (pio2_lo - 2·c)
    two_f               = soft_fmul(_ASIN_TWO_BITS, f)
    half_pio2_minus_2f  = soft_fsub(_ASIN_HALF_PIO2_HI, two_f)  # 0.5·pio2_hi - 2·f
    inner_mid           = soft_fsub(inner_mid_a, half_pio2_minus_2f)
    result_mid          = soft_fsub(_ASIN_HALF_PIO2_HI, inner_mid)

    # Combine sub-paths within Path C.
    result_ge_half_pos = ifelse(is_near1, result_near1, result_mid)
    # Sign restore (Path C computed magnitude only).
    result_ge_half     = ifelse(sign_neg, result_ge_half_pos ⊻ SIGN_BIT, result_ge_half_pos)

    # Combine Path B and Path C.
    result = ifelse(is_lt_half, result_lt_half, result_ge_half)

    # ─── Tiny override: |x| < 2^-26 → return `a` bit-exact (musl behaviour).
    result = ifelse(is_tiny, a, result)

    # ─── |x| = 1 override: return ±π/2 bit-exact.
    pio2_signed = ifelse(sign_neg, _ASIN_PIO2_HI ⊻ SIGN_BIT, _ASIN_PIO2_HI)
    result      = ifelse(is_eq1, pio2_signed, result)

    # ─── |x| > 1 (finite) override: return canonical QNAN.
    is_oob = is_ge1 & ~is_eq1
    result = ifelse(is_oob, QNAN, result)

    # ─── NaN propagation: input NaN → return `a | QUIET_BIT`.
    result = ifelse(a_nan, a | QUIET_BIT, result)

    return result
end
