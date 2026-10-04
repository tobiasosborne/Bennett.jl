# IEEE 754 binary64 two-argument arctangent on raw bit patterns.
# Faithful port of musl's `src/math/atan2.c` (FreeBSD/SunPro 1993, BSD-
# licensed; identical implementation in glibc, Julia-via-openlibm,
# Apple's libm). Built on `soft_atan` from Bennett-qpke (CLAUDE.md §12 —
# no duplicated lowering): the algorithm reduces atan2(y, x) to
# `atan(|y|/|x|) + quadrant_offset`, and `soft_atan` already handles
# the polynomial + huge/tiny argument fast-paths. Tier C1.5 in the
# Enzyme parity north-star (Bennett-Enzyme-Parity-NorthStar.md).
#
# Bennett-vke7: BIT-EXACT vs `Base.atan(y, x)` (CLAUDE.md rule 13). The
# operation order is a step-for-step port of Julia's
# `base/special/trig.jl` `atan(y::T, x::T)` (itself openlibm e_atan2.c);
# the x < 0 half-plane MUST compute `π - (z - ATAN2_PI_LO)`, not `π - z`
# (the pre-vke7 form was 1 ULP off on ~31% of q2/q3 inputs).
#
# Algorithm (Base order; branchless — every branch computed, ifelse picks):
#
#   1. z = atan(|y/x|) via ONE soft_fdiv + ONE soft_atan, except
#        k > 60            (|y/x| > ~2^60): z = π/2 + 0.5·PI_LO, and the
#                          x-sign is dropped (Base's `m &= 1`)
#        x < 0 & k < -60   (|y/x| < ~2^-60): z = 0
#      where k = Int32(hi(|y|) - hi(|x|)) >> 20 (high-word exponent diff).
#   2. Quadrant: m=0 → z, m=1 → -z, m=2 → π - (z - PI_LO),
#      m=3 → (z - PI_LO) - π  (= -(m=2 result) exactly under RNE).
#   3. Overrides in Base's priority order (last in the cascade wins):
#      NaN (x if NaN else y, payload unchanged) > y == ±0 > x == ±0 >
#      x == ±Inf > y == ±Inf > generic. Base's `x == 1.0 → atan(y)` shortcut
#      is the generic path with the k > 60 shortcut disabled (y/1 == y).

const _ATAN2_PI_BITS      = reinterpret(UInt64, Float64(π))      # 0x400921FB54442D18
const _ATAN2_PI_2_BITS    = reinterpret(UInt64, Float64(π/2))    # 0x3FF921FB54442D18
const _ATAN2_PI_4_BITS    = reinterpret(UInt64, Float64(π/4))    # 0x3FE921FB54442D18
const _ATAN2_3PI_4_BITS   = reinterpret(UInt64, 3 * Float64(π) / 4) # 0x4002D97C7F3321D2
# Base.Math.ATAN2_PI_LO(Float64) and the k > 60 saturation value
# `T(pi)/2 + T(0.5)*ATAN2_PI_LO(T)`, evaluated with Base's operation order.
const _ATAN2_PI_LO_BITS   = reinterpret(UInt64, 1.2246467991473531772E-16)
const _ATAN2_HUGE_Z_BITS  = reinterpret(UInt64, Float64(π) / 2 + 0.5 * 1.2246467991473531772E-16)
const _ATAN2_ONE_BITS     = reinterpret(UInt64, 1.0)

"""
    soft_atan2(y::UInt64, x::UInt64) -> UInt64

IEEE 754 double-precision two-argument arctangent `atan2(y, x)` on raw
bit patterns. **Bit-exact vs `Base.atan(y, x)`** across the full Float64 ×
Float64 input space, NaN payloads included (Bennett-vke7).

Special cases (per IEEE 754-2019 §9.2.1, matches `Base.atan`):

- atan2(±0, +x finite, x≠0)   = ±0   (sign of y)
- atan2(±0, -x finite)        = ±π
- atan2(±0, +0)               = ±0
- atan2(±0, -0)               = ±π
- atan2(±y, ±0) where y≠0     = ±π/2 (sign of y)
- atan2(±Inf, finite)         = ±π/2
- atan2(±y finite, +Inf)      = ±0
- atan2(±y finite, -Inf)      = ±π
- atan2(±Inf, +Inf)           = ±π/4
- atan2(±Inf, -Inf)           = ±3π/4
- NaN in either operand       = x if x is NaN, else y (payload unchanged)

Algorithm: step-for-step port of Julia Base's `atan(y::T, x::T)`
(openlibm e_atan2.c). Reduces to `atan(|y|/|x|) + quadrant_offset`, reusing
`soft_atan` per CLAUDE.md §12. ONE soft_fdiv + ONE soft_atan call;
remaining work is XOR / ifelse / two fsubs for the x < 0 quadrant offset
`π - (z - ATAN2_PI_LO)`.
Constant dispatch cost (Bennett's static-CFG model).
"""
@inline function soft_atan2(y::UInt64, x::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # ─── Sign + abs split.
    sign_y = (y & SIGN_BIT) != UInt64(0)
    sign_x = (x & SIGN_BIT) != UInt64(0)
    abs_y  = y & ~SIGN_BIT
    abs_x  = x & ~SIGN_BIT

    # ─── Classification (on the abs values).
    y_nan  = abs_y > INF_BITS
    x_nan  = abs_x > INF_BITS
    is_nan = y_nan | x_nan
    y_inf  = abs_y == INF_BITS
    x_inf  = abs_x == INF_BITS
    y_zero = abs_y == UInt64(0)
    x_zero = abs_x == UInt64(0)
    x_one  = x == _ATAN2_ONE_BITS

    # ─── Generic path (Base: ypw/xpw high words, k = Int32(ypw-xpw) >> 20).
    ypw = UInt32(abs_y >> 32)
    xpw = UInt32(abs_x >> 32)
    k   = reinterpret(Int32, ypw - xpw) >> 20
    # Base's `x == 1.0 → atan(y)` shortcut: y/1 == y exactly and soft_atan is
    # odd, so the generic path reproduces it provided the k > 60 shortcut is
    # disabled (one soft_atan call total, not two).
    k_huge = (k > Int32(60)) & !x_one
    k_tiny = sign_x & (k < Int32(-60))

    ratio = soft_fdiv(abs_y, abs_x)          # |y/x| == |y|/|x| exactly
    z_gen = soft_atan(ratio)
    z = ifelse(k_huge, _ATAN2_HUGE_Z_BITS, ifelse(k_tiny, UInt64(0), z_gen))
    neg_x = sign_x & !k_huge                 # Base: `m &= 1` when k > 60

    z_m_lo     = soft_fsub(z, _ATAN2_PI_LO_BITS)        # z - ATAN2_PI_LO
    pi_minus_w = soft_fsub(_ATAN2_PI_BITS, z_m_lo)      # π - (z - PI_LO)
    # (z - PI_LO) - π == -(π - (z - PI_LO)) exactly (RNE is sign-symmetric;
    # the difference is never 0 since z - PI_LO < π/2 + 1).
    w_minus_pi = pi_minus_w ⊻ SIGN_BIT

    result_q01 = ifelse(sign_y, z ⊻ SIGN_BIT, z)
    result_q23 = ifelse(sign_y, w_minus_pi, pi_minus_w)
    result     = ifelse(neg_x, result_q23, result_q01)

    # ─── Overrides, lowest Base priority first (last write wins).
    pi_2_signed = ifelse(sign_y, _ATAN2_PI_2_BITS ⊻ SIGN_BIT, _ATAN2_PI_2_BITS)
    # isinf(y) (x finite): copysign(π/2, y)
    result = ifelse(y_inf, pi_2_signed, result)
    # isinf(x): both inf → ±π/4 / ±3π/4; y finite → ±0 / ±π
    inf_inf = ifelse(sign_x, _ATAN2_3PI_4_BITS, _ATAN2_PI_4_BITS)
    fin_inf = ifelse(sign_x, _ATAN2_PI_BITS, UInt64(0))
    x_inf_r = ifelse(y_inf, inf_inf, fin_inf) | ifelse(sign_y, SIGN_BIT, UInt64(0))
    result = ifelse(x_inf, x_inf_r, result)
    # iszero(x) (y ≠ 0): flipsign(π/2, y)
    result = ifelse(x_zero, pi_2_signed, result)
    # iszero(y): m ∈ {0,1} → y; m == 2 → π; m == 3 → -π
    y_zero_r = ifelse(sign_x, _ATAN2_PI_BITS | (y & SIGN_BIT), y)
    result = ifelse(y_zero, y_zero_r, result)
    # NaN: isnan(x) ? x : y (payload returned unchanged, as Base does)
    result = ifelse(is_nan, ifelse(x_nan, x, y), result)

    return result
end
