# IEEE 754 binary64 arccosine on raw bit patterns. Faithful port of
# musl's `src/math/acos.c` (FreeBSD/SunPro 1993, BSD-licensed; identical
# implementation in glibc and Julia-via-openlibm). Tier C1.4 in the
# Enzyme parity north-star (`Bennett-Enzyme-Parity-NorthStar.md`),
# follow-on to Bennett-ckvj (soft_asin) — REUSES the rational `_asin_R(z)`
# helper and the 10 polynomial coefficients (pS0..pS5, qS1..qS4) plus
# `pio2_hi`/`pio2_lo` defined module-private in `fasin.jl`. Per
# CLAUDE.md §12 (no duplicated lowering); both files live in the same
# `module SoftFloatLib` so the helpers are in scope by name.
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across [-1, 1].
# Bennett.jl practical target vs `Base.acos`: ≤2 ULP. Bit-exact at
# x = 1 (returns 0), x = -1 (returns π), and the tiny fast path
# (|x| < 2^-57 returns π/2).
#
# ─── Algorithm (musl acos.c, branchless realisation) ──────────────────
#
# Four input regimes via the high 32 bits of |x| (`ix_hi`) plus the
# sign bit:
#
#   Path A  |x| ≤ 2^-57         → return π/2 (tiny override)
#   Path B  2^-57 < |x| < 0.5   → acos(x) = π/2 - (x - (pio2_lo - x·R(x²)))
#   Path C  x ≤ -0.5            → 2·(π/2 - (s + w_neg))
#                                 with z = (1+x)/2, s = √z,
#                                      w_neg = R(z)·s - pio2_lo
#   Path D  x ≥  0.5            → 2·(df + w_pos)
#                                 with z = (1-x)/2, s = √z,
#                                      df = high32(s),
#                                      c = (z - df²)/(s + df),
#                                      w_pos = R(z)·s + c
#
# Note: z for Path C and Path D unify to (1 - |x|)/2 because for x ≤ -0.5
# we have 1 + x = 1 - |x|, and for x ≥ 0.5 we have 1 - x = 1 - |x|.
#
# Specials:
#   x = 1     → 0    (bit-exact; musl returns 0 directly)
#   x = -1    → π    (bit-exact; musl returns 2·pio2_hi which is exact at f64)
#   |x| > 1   → NaN  (matches musl `0/(x-x)`)
#   x is NaN  → NaN  (propagate input, force quiet bit)
#
# Branchless realisation: ALL paths computed; ifelse cascades select.
# Single `_asin_R` dispatch on ifelse-selected input (per qpke gotcha #1).

# ─────────────────────────────────────────────────────────────────────
# Float64 raw bit constants used by acos. The pS0..pS5/qS1..qS4 +
# pio2_hi/pio2_lo + half/two/hi32-mask constants live in fasin.jl;
# they are visible by name within `module SoftFloatLib`.
# ─────────────────────────────────────────────────────────────────────

# π = 2·pio2_hi exactly at f64 (bias-exponent +1 from pio2_hi). Returned
# for x = -1.
const _ACOS_PI_BITS = reinterpret(UInt64, 3.14159265358979311600e+00)  # 0x400921FB_54442D18

# High-word range thresholds (matching musl acos.c exactly).
const _ACOS_TINY_HI = UInt32(0x3c600000)  # |x| ≤ 2^-57 → return π/2
# (acos shares _ASIN_GE1_HI = 0x3ff00000 and _ASIN_LT_HALF_HI = 0x3fe00000
# from fasin.jl — reused by name.)

"""
    soft_acos(a::UInt64) -> UInt64

IEEE 754 double-precision arccosine `acos(x)` on raw bit patterns.
**≤2 ULP vs `Base.acos`** across the input domain `[-1, 1]`; bit-exact
on `x = 1` (returns `0`), `x = -1` (returns `π`), and tiny inputs
(`|x| ≤ 2^-57` returns `π/2`).

Special cases:
- `acos(NaN)`  = NaN  (propagate input, force quiet-bit)
- `acos(±Inf)` = NaN  (|x| > 1 path)
- `acos(±x)` for `|x| > 1` = NaN (matches musl `0/(x-x)`)
- `acos(0)`    = π/2  (sign-preserving inputs hit the tiny override)
- `acos(1)`    = 0
- `acos(-1)`   = π
- `|x| ≤ 2^-57` → `π/2`

Algorithm: faithful musl `e_acos.c` port (Sun 1993, BSD-licensed). Four
input regimes branchlessly computed. Reuses `_asin_R(z)` and the 10
polynomial constants from `fasin.jl` (Bennett-ckvj) per CLAUDE.md §12.
"""
@inline function soft_acos(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # NaN detection up-front (last-write-wins override).
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    abs_a    = a & ~SIGN_BIT
    sign_neg = (a & SIGN_BIT) != UInt64(0)
    ix_hi    = UInt32(abs_a >> 32)
    ix_lo    = UInt32(abs_a & UInt64(0xFFFFFFFF))

    # Range dispatch flags.
    is_ge1     = ix_hi >= _ASIN_GE1_HI                             # |x| ≥ 1 or NaN/Inf
    is_eq1     = (ix_hi == _ASIN_GE1_HI) & (ix_lo == UInt32(0))    # |x| = 1
    is_lt_half = ix_hi <  _ASIN_LT_HALF_HI                         # |x| < 0.5
    is_tiny    = ix_hi <= _ACOS_TINY_HI                            # |x| ≤ 2^-57

    # ─── Single R-call: input is x² for Path B, z = (1-|x|)/2 for Paths C/D.
    xx            = soft_fmul(a, a)                       # x² (sign cancels)
    one_minus_abs = soft_fsub(_RP_ONE_BITS, abs_a)
    z             = soft_fmul(one_minus_abs, _ASIN_HALF_BITS)
    r_arg         = ifelse(is_lt_half, xx, z)
    r             = _asin_R(r_arg)

    # ─── Path B: |x| < 0.5 — y = π/2 - (x - (pio2_lo - x·R(x²))) ─────
    x_r              = soft_fmul(a, r)
    pio2_lo_minus_xr = soft_fsub(_ASIN_PIO2_LO, x_r)
    inner_lt         = soft_fsub(a, pio2_lo_minus_xr)
    result_lt_half   = soft_fsub(_ASIN_PIO2_HI, inner_lt)

    # ─── Paths C and D both need s = √z and r·s ──────────────────────
    s   = soft_fsqrt(z)
    r_s = soft_fmul(r, s)                                  # R(z)·s

    # Path C (x ≤ -0.5):  y = 2·(π/2 - (s + (r·s - pio2_lo)))
    w_neg        = soft_fsub(r_s, _ASIN_PIO2_LO)
    s_plus_wneg  = soft_fadd(s, w_neg)
    inner_neg    = soft_fsub(_ASIN_PIO2_HI, s_plus_wneg)
    result_neg   = soft_fmul(_ASIN_TWO_BITS, inner_neg)

    # Path D (x ≥ 0.5):  df = high32(s); c = (z - df²)/(s + df); w_pos = R(z)·s + c
    #                    y = 2·(df + w_pos)
    df            = s & _ASIN_HI32_MASK                    # SET_LOW_WORD(df, 0)
    df_df         = soft_fmul(df, df)
    z_minus_dfdf  = soft_fsub(z, df_df)
    s_plus_df     = soft_fadd(s, df)
    c             = soft_fdiv(z_minus_dfdf, s_plus_df)
    w_pos         = soft_fadd(r_s, c)
    df_plus_wpos  = soft_fadd(df, w_pos)
    result_pos    = soft_fmul(_ASIN_TWO_BITS, df_plus_wpos)

    # Combine Paths C and D by sign.
    result_ge_half = ifelse(sign_neg, result_neg, result_pos)

    # Combine with Path B.
    result = ifelse(is_lt_half, result_lt_half, result_ge_half)

    # ─── Tiny override: |x| ≤ 2^-57 → π/2 ─────────────────────────────
    result = ifelse(is_tiny, _ASIN_PIO2_HI, result)

    # ─── |x| = 1 override: x = 1 → 0; x = -1 → π ──────────────────────
    eq1_val = ifelse(sign_neg, _ACOS_PI_BITS, UInt64(0))
    result  = ifelse(is_eq1, eq1_val, result)

    # ─── |x| > 1 (finite, non-NaN) override: QNAN ─────────────────────
    is_oob = is_ge1 & ~is_eq1
    result = ifelse(is_oob, QNAN, result)

    # ─── NaN propagation: input NaN → `a | QUIET_BIT` ─────────────────
    result = ifelse(a_nan, a | QUIET_BIT, result)

    return result
end
