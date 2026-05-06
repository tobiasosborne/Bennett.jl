# IEEE 754 binary64 two-argument arctangent on raw bit patterns.
# Faithful port of musl's `src/math/atan2.c` (FreeBSD/SunPro 1993, BSD-
# licensed; identical implementation in glibc, Julia-via-openlibm,
# Apple's libm). Built on `soft_atan` from Bennett-qpke (CLAUDE.md §12 —
# no duplicated lowering): the algorithm reduces atan2(y, x) to
# `atan(|y|/|x|) + quadrant_offset`, and `soft_atan` already handles
# the polynomial + huge/tiny argument fast-paths. Tier C1.5 in the
# Enzyme parity north-star (Bennett-Enzyme-Parity-NorthStar.md).
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across the full f64
# range. Bennett.jl practical target vs `Base.atan(y, x)`: ≤2 ULP.
#
# Algorithm (musl atan2.c, simplified — Bennett-branchless):
#
#   1. Compute |y|/|x| via soft_fdiv (sign bits stripped). The ratio is
#      always non-negative; soft_fdiv produces ±0/±Inf/NaN cleanly at
#      domain boundaries. ONE soft_fdiv call (gotcha #1 from Bennett-qpke
#      — avoid SLP-vectorisation by minimising parallel calls).
#   2. Compute z = soft_atan(|y|/|x|). soft_atan returns z ∈ [0, π/2]
#      for any non-negative input (incl. +Inf via the huge-arg path).
#      ONE soft_atan call.
#   3. Quadrant offset by (sign_x, sign_y):
#        q0 (x≥0, y≥0):  z
#        q1 (x≥0, y<0): -z       (XOR sign bit)
#        q2 (x<0,  y≥0): π - z   (one fsub)
#        q3 (x<0,  y<0): z - π   = -(π - z) (XOR sign bit)
#      All four computed branchlessly; ifelse-cascade selects.
#   4. Special-case overrides (last-write-wins ifelse cascade, in order
#      from generic to most-specific so that more-specific overrides
#      win):
#        - both ±Inf:  ±π/4 (q0/q1) or ±3π/4 (q2/q3)
#        - both ±0:    ±0 (q0/q1) or ±π (q2/q3)
#        - any NaN:    propagate first NaN-operand with quiet-bit set
#
# Edge cases handled by the GENERIC path (no special-case needed):
#
#   - y = ±0, x finite non-zero: |y|/|x| = +0; atan(+0) = +0; quadrant
#     offset gives ±0 in q0/q1, ±π in q2/q3 — all correct (the sign of
#     the y == 0 case comes from the `sign_y` selector, not from the
#     ratio, so -0 input correctly produces -0 / -π output).
#   - x = ±0, y finite non-zero: |y|/|x| = +Inf; atan(+Inf) = +π/2;
#     quadrant offset gives ±π/2 in q0/q1, ±π/2 in q2/q3 (since
#     π - π/2 = π/2 and -π + π/2 = -π/2). Correct per IEEE 754-2019.
#   - x = ±Inf, y finite: |y|/|Inf| = +0; atan(+0) = +0; offset gives
#     ±0 in q0/q1, ±π in q2/q3. Correct.
#   - y = ±Inf, x finite: |Inf|/|x| = +Inf; atan(+Inf) = +π/2; offset
#     gives ±π/2. Correct.
#
# Cases where the generic path produces NaN and the override fires:
#
#   - y = ±0, x = ±0 → 0/0 = NaN; the `both_zero` override fires.
#   - y = ±Inf, x = ±Inf → Inf/Inf = NaN; the `both_inf` override fires.

const _ATAN2_PI_BITS      = reinterpret(UInt64, Float64(π))      # 0x400921FB54442D18
const _ATAN2_PI_2_BITS    = reinterpret(UInt64, Float64(π/2))    # 0x3FF921FB54442D18
const _ATAN2_PI_4_BITS    = reinterpret(UInt64, Float64(π/4))    # 0x3FE921FB54442D18
const _ATAN2_3PI_4_BITS   = reinterpret(UInt64, Float64(3π/4))   # 0x4002D97C7F3321D2

"""
    soft_atan2(y::UInt64, x::UInt64) -> UInt64

IEEE 754 double-precision two-argument arctangent `atan2(y, x)` on raw
bit patterns. **≤2 ULP vs `Base.atan(y, x)`** across the full Float64 ×
Float64 input space.

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
- NaN in either operand       = NaN (quiet-bit set, first-NaN-wins)

Algorithm: faithful port of musl/FreeBSD `s_atan2.c` (Sun 1993, BSD-
licensed). Reduces to `atan(|y|/|x|) + quadrant_offset`, reusing
`soft_atan` per CLAUDE.md §12. ONE soft_fdiv + ONE soft_atan call;
remaining work is XOR / ifelse / one fsub for the quadrant offset.
Constant dispatch cost (Bennett's static-CFG model).
"""
@inline function soft_atan2(y::UInt64, x::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # ─── Sign + abs split.
    sign_y = (y & SIGN_BIT) != UInt64(0)
    sign_x = (x & SIGN_BIT) != UInt64(0)
    abs_y  = y & ~SIGN_BIT
    abs_x  = x & ~SIGN_BIT

    # ─── NaN / Inf / zero classification (on the abs values).
    y_nan  = abs_y > INF_BITS
    x_nan  = abs_x > INF_BITS
    is_nan = y_nan | x_nan

    y_inf    = abs_y == INF_BITS
    x_inf    = abs_x == INF_BITS
    both_inf = y_inf & x_inf

    y_zero    = abs_y == UInt64(0)
    x_zero    = abs_x == UInt64(0)
    both_zero = y_zero & x_zero

    # ─── Generic path: z = atan(|y|/|x|) ∈ [0, π/2] (incl. boundary).
    # ONE soft_fdiv + ONE soft_atan call. soft_atan handles the
    # huge-arg (|y|/|x| ≥ 2^66 → π/2), tiny-arg (|y|/|x| < 2^-27 → x),
    # and NaN paths via its own overrides — we don't need to pre-clamp.
    ratio = soft_fdiv(abs_y, abs_x)
    z     = soft_atan(ratio)

    # ─── Quadrant offset.
    # neg_z and z_minus_pi computed via XOR (faster than soft_fneg /
    # soft_fsub; correct for any z ∈ [0, π/2] since the result is finite
    # and z is never exactly π — soft_atan's range is bounded by π/2).
    neg_z      = z ⊻ SIGN_BIT
    pi_minus_z = soft_fsub(_ATAN2_PI_BITS, z)
    z_minus_pi = pi_minus_z ⊻ SIGN_BIT

    result_q01 = ifelse(sign_y, neg_z,      z)
    result_q23 = ifelse(sign_y, z_minus_pi, pi_minus_z)
    generic    = ifelse(sign_x, result_q23, result_q01)

    # ─── Override 1: both operands ±Inf → ±π/4 or ±3π/4.
    inf_q01 = ifelse(sign_y, _ATAN2_PI_4_BITS  ⊻ SIGN_BIT, _ATAN2_PI_4_BITS)
    inf_q23 = ifelse(sign_y, _ATAN2_3PI_4_BITS ⊻ SIGN_BIT, _ATAN2_3PI_4_BITS)
    inf_inf_result = ifelse(sign_x, inf_q23, inf_q01)

    # ─── Override 2: both operands ±0 → ±0 (q0/q1) or ±π (q2/q3).
    zero_q01 = ifelse(sign_y, SIGN_BIT,                   UInt64(0))
    zero_q23 = ifelse(sign_y, _ATAN2_PI_BITS ⊻ SIGN_BIT,  _ATAN2_PI_BITS)
    zero_zero_result = ifelse(sign_x, zero_q23, zero_q01)

    # ─── Override 3: NaN propagation. First-NaN-wins (y precedes x —
    # matches Julia's `Base.atan` and the x86 SSE convention used in
    # softfloat_common's `_propagate_nan2`).
    nan_payload = ifelse(y_nan, y, x)

    # ─── Compose: more-specific overrides win (last in ifelse cascade).
    result = generic
    result = ifelse(both_zero, zero_zero_result, result)
    result = ifelse(both_inf,  inf_inf_result,   result)
    result = ifelse(is_nan,    nan_payload | QUIET_BIT, result)

    return result
end
