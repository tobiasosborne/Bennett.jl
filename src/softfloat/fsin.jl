# IEEE 754 binary64 sin / cos on raw bit patterns. Branchless integer
# arithmetic for special-case dispatch + soft_f* primitives for the
# polynomial bodies, Cody-Waite range reduction for medium args, and
# Payne-Hanek multi-precision reduction for huge args. Faithful port of
# musl's `src/math/sin.c`, `cos.c`, `__sin.c`, `__cos.c`, `__rem_pio2.c`,
# and `__rem_pio2_large.c` (FreeBSD/SunPro 1993, BSD-licensed; identical
# implementation in glibc and Julia-via-openlibm). See worklog/055 for
# the design memo (Bennett-3mo).
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across the full f64
# range. Bennett-jl practical target vs `Base.sin` / `Base.cos`: ≤2 ULP.
# Bit-exact vs `ccall(:sin/cos, ...)` (system libm) on Linux.
#
# Algorithm:
#   1. Special-case dispatch (NaN → propagate, ±Inf → NaN, ±0 → ±0 for
#      sin / +1 for cos, tiny → x for sin / 1 for cos).
#   2. Range reduction `x = n·π/2 + y` with y ∈ [-π/4, π/4]:
#      - |x| < π/4: y = x, n = 0 (no reduction)
#      - |x| < 2^28·π/2: Cody-Waite (3-step pio2_1/pio2_2/pio2_3 split)
#      - |x| ≥ 2^28·π/2: Payne-Hanek multi-precision reduction
#   3. Quadrant select via n & 3 dispatching to sin_kernel or cos_kernel
#      with appropriate sign.

# ─────────────────────────────────────────────────────────────────────
# Sin polynomial coefficients S1..S6 (FreeBSD k_sin.c, Sun 1993).
# Approximation: sin(x) ≈ x + S1·x³ + S2·x⁵ + ... + S6·x¹³ on [0, π/4],
# error ≤ 2^-58 ULP relative to true sin.
# ─────────────────────────────────────────────────────────────────────
const _SIN_S1 = reinterpret(UInt64, -1.66666666666666324348e-01)  # 0xBFC55555_55555549
const _SIN_S2 = reinterpret(UInt64,  8.33333333332248946124e-03)  # 0x3F811111_1110F8A6
const _SIN_S3 = reinterpret(UInt64, -1.98412698298579493134e-04)  # 0xBF2A01A0_19C161D5
const _SIN_S4 = reinterpret(UInt64,  2.75573137070700676789e-06)  # 0x3EC71DE3_57B1FE7D
const _SIN_S5 = reinterpret(UInt64, -2.50507602534068634195e-08)  # 0xBE5AE5E6_8A2B9CEB
const _SIN_S6 = reinterpret(UInt64,  1.58969099521155010221e-10)  # 0x3DE5D93A_5ACFD57C

# ─────────────────────────────────────────────────────────────────────
# Cos polynomial coefficients C1..C6 (FreeBSD k_cos.c, Sun 1993).
# Approximation: cos(x) ≈ 1 - x²/2 + C1·x⁴ + ... + C6·x¹⁴ on [0, π/4].
# ─────────────────────────────────────────────────────────────────────
const _COS_C1 = reinterpret(UInt64,  4.16666666666666019037e-02)  # 0x3FA55555_5555554C
const _COS_C2 = reinterpret(UInt64, -1.38888888888741095749e-03)  # 0xBF56C16C_16C15177
const _COS_C3 = reinterpret(UInt64,  2.48015872894767294178e-05)  # 0x3EFA01A0_19CB1590
const _COS_C4 = reinterpret(UInt64, -2.75573143513906633035e-07)  # 0xBE927E4F_809C52AD
const _COS_C5 = reinterpret(UInt64,  2.08757232129817482790e-09)  # 0x3E21EE9E_BDB4B1C4
const _COS_C6 = reinterpret(UInt64, -1.13596475577881948265e-11)  # 0xBDA8FAE9_BE8838D4

# ─────────────────────────────────────────────────────────────────────
# Cody-Waite π/2 split (FreeBSD __rem_pio2.c). Three-level extended
# precision: pio2 = pio2_1 + pio2_1t exact to 33+53 bits;
# pio2_1t = pio2_2 + pio2_2t exact to 33+53; pio2_2t = pio2_3 + pio2_3t.
# ─────────────────────────────────────────────────────────────────────
const _RP_INVPIO2 = reinterpret(UInt64,  6.36619772367581382433e-01)  # 2/π
const _RP_PIO2_1  = reinterpret(UInt64,  1.57079632673412561417e+00)  # π/2 first 33 bits
const _RP_PIO2_1T = reinterpret(UInt64,  6.07710050650619224932e-11)  # tail of pio2_1
const _RP_PIO2_2  = reinterpret(UInt64,  6.07710050630396597660e-11)
const _RP_PIO2_2T = reinterpret(UInt64,  2.02226624879595063154e-21)
const _RP_PIO2_3  = reinterpret(UInt64,  2.02226624871116645580e-21)
const _RP_PIO2_3T = reinterpret(UInt64,  8.47842766036889956997e-32)

# `toint` for the round-via-add trick: `x*invpio2 + toint - toint`
# rounds-to-nearest-even when toint = 1.5/eps(Float64) = 1.5·2^52.
const _RP_TOINT = reinterpret(UInt64, 1.5 / eps(Float64))

# π/4 bit pattern, used as the small-arg fast-path threshold.
const _RP_PIO4_BITS = reinterpret(UInt64, 0x1.921fb54442d18p-1)

# Float64 constants used in the kernel and quadrant select.
const _RP_ONE_BITS    = reinterpret(UInt64,  1.0)
const _RP_NEG_ONE_BITS = reinterpret(UInt64, -1.0)
const _RP_HALF_BITS   = reinterpret(UInt64,  0.5)

# ─────────────────────────────────────────────────────────────────────
# Tiny-arg fast-path thresholds (high-word comparisons, matching
# musl sin.c and cos.c).
#   sin: |x| < 2^-26 → return x   (high word < 0x3E500000)
#   cos: |x| < 2^-27·√2 → return 1  (high word < 0x3E46A09E)
# ─────────────────────────────────────────────────────────────────────
const _RP_SIN_TINY_HI = UInt32(0x3E500000)
const _RP_COS_TINY_HI = UInt32(0x3E46A09E)

# ─────────────────────────────────────────────────────────────────────
# Cody-Waite dispatch boundaries (high-word comparisons, musl __rem_pio2).
# ─────────────────────────────────────────────────────────────────────
const _RP_HI_PIO4    = UInt32(0x3FE921FB)  # |x| ≤ π/4
const _RP_HI_3PIO4   = UInt32(0x4002D97C)  # |x| ≤ 3π/4 (use n=±1)
const _RP_HI_5PIO4   = UInt32(0x400F6A7A)  # |x| ≤ 5π/4 (use n=±2)
const _RP_HI_7PIO4   = UInt32(0x4015FDBC)  # |x| ≤ 7π/4 (use n=±3)
const _RP_HI_9PIO4   = UInt32(0x401C463B)  # |x| ≤ 9π/4 (use n=±4)
const _RP_HI_2P28    = UInt32(0x413921FB)  # |x| ≤ 2^28·π/2 → Cody-Waite ext
const _RP_HI_INF     = UInt32(0x7FF00000)  # NaN/Inf
# Special-case singular high-word values that fall on a boundary and need
# the full Cody-Waite ext path even within the n=±2/3/4 ranges.
const _RP_HI_3PIO2   = UInt32(0x4012D97C)  # = round(3π/2)
const _RP_HI_4PIO2   = UInt32(0x401921FB)  # = round(4π/2 = 2π)
const _RP_HI_2PIO2   = UInt32(0x400921FB)  # = round(2π/2 = π)

# ─────────────────────────────────────────────────────────────────────
# INV_2PI: bits of 1/(2π) split into 19 × UInt64 chunks. From Julia's
# `base/special/rem_pio2.jl` (computed at BigFloat precision 4096):
#   1/(2π) = sum(INV_2PI[i] / 0x1p64^i for i = 1:19)
# ─────────────────────────────────────────────────────────────────────
const _RP_INV_2PI = (
    UInt64(0x28be60db9391054a),
    UInt64(0x7f09d5f47d4d3770),
    UInt64(0x36d8a5664f10e410),
    UInt64(0x7f9458eaf7aef158),
    UInt64(0x6dc91b8e909374b8),
    UInt64(0x01924bba82746487),
    UInt64(0x3f877ac72c4a69cf),
    UInt64(0xba208d7d4baed121),
    UInt64(0x3a671c09ad17df90),
    UInt64(0x4e64758e60d4ce7d),
    UInt64(0x272117e2ef7e4a0e),
    UInt64(0xc7fe25ffff781660),  # NB: musl/openlibm value; cross-checked vs Julia table
    UInt64(0xfbcbc462d6829b47),
    UInt64(0xdb4d9fb3c9f2c26d),
    UInt64(0xd3d18fd9a797fa8b),
    UInt64(0x5d49eeb1faf97c5e),
    UInt64(0xcf41ce7de294a4ba),
    UInt64(0x9afed7ec47e35742),
    UInt64(0x1580cc11bf1edaea),
)

# Constant-tuple table-lookup pattern (per `_log_tab_lookup` / `_exp_tab_lookup`).
# Returns the raw bits at index `idx` (0-based externally; `+1` for Julia 1-based).
@inline function _inv_2pi_lookup(idx::Int)::UInt64
    let T = _RP_INV_2PI
        @inbounds T[idx + 1]
    end
end

# π/2 reconstruction constants used by paynehanek (Julia base/special/rem_pio2.jl).
# `pio2_hi + pio2_lo` represents π/2 to ~106 bits.
const _RP_PAYNE_PIO2_HI = reinterpret(UInt64, 1.5707963407039642)        # 0x3FF921FB54400000
const _RP_PAYNE_PIO2_LO = reinterpret(UInt64, -1.3909067614167116e-8)    # 0xBE3DDE973C000000
const _RP_PAYNE_PIO2    = reinterpret(UInt64, 1.5707963267948966)        # 0x3FF921FB54442D18

# ─────────────────────────────────────────────────────────────────────
# poshighword(x) — extract the upper 32 bits of |x| (the high word with
# sign cleared). musl/openlibm idiom. For our bit-input form: `a & ~sign`.
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_pos_high_word(a::UInt64)::UInt32
    UInt32((a & UInt64(0x7FFFFFFFFFFFFFFF)) >> 32)
end

# ─────────────────────────────────────────────────────────────────────
# Sin kernel: sin(yhi + ylo) on [-π/4, π/4]. yhi is the principal value
# after argument reduction; ylo is the tail (zero in the no-reduction
# case). musl __sin with iy=1 path always (we ALWAYS pass a tail; ylo=0
# is the iy=0 special case).
#
#   z = yhi²
#   v = z·yhi
#   r = S2 + z·(S3 + z·S4) + z·z²·(S5 + z·S6)
#   sin = yhi - ((z·(0.5·ylo - v·r) - ylo) - v·S1)
#
# When ylo=0 the formula collapses to: yhi + v·(S1 + z·r), the classical
# odd-power polynomial. The two-term form preserves accuracy when ylo
# carries the rounding error from Cody-Waite reduction.
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_sin_kernel(yhi::UInt64, ylo::UInt64)::UInt64
    z = soft_fmul(yhi, yhi)
    z2 = soft_fmul(z, z)
    # r = S2 + z*(S3 + z*S4) + z*z²*(S5 + z*S6)
    zS4   = soft_fmul(z, _SIN_S4)
    S3_zS4 = soft_fadd(_SIN_S3, zS4)
    z_S3_zS4 = soft_fmul(z, S3_zS4)
    r_lo  = soft_fadd(_SIN_S2, z_S3_zS4)
    zS6   = soft_fmul(z, _SIN_S6)
    S5_zS6 = soft_fadd(_SIN_S5, zS6)
    z2_S5_zS6 = soft_fmul(z2, S5_zS6)
    z_z2_S5_zS6 = soft_fmul(z, z2_S5_zS6)
    r     = soft_fadd(r_lo, z_z2_S5_zS6)

    v = soft_fmul(z, yhi)
    # tail = z*(0.5*ylo - v*r) - ylo
    half_ylo = soft_fmul(_RP_HALF_BITS, ylo)
    vr       = soft_fmul(v, r)
    half_ylo_sub_vr = soft_fsub(half_ylo, vr)
    z_inner  = soft_fmul(z, half_ylo_sub_vr)
    z_inner_sub_ylo = soft_fsub(z_inner, ylo)
    # bracket = (z·(0.5·ylo - v·r) - ylo) - v·S1
    vS1 = soft_fmul(v, _SIN_S1)
    bracket = soft_fsub(z_inner_sub_ylo, vS1)
    # sin = yhi - bracket
    soft_fsub(yhi, bracket)
end

# ─────────────────────────────────────────────────────────────────────
# Cos kernel: cos(yhi + ylo) on [-π/4, π/4]. musl __cos.
#
#   z   = yhi²
#   r   = z·(C1 + z·(C2 + z·C3)) + z²·z²·(C4 + z·(C5 + z·C6))
#   hz  = 0.5·z
#   w   = 1 - hz
#   cos = w + (((1 - w) - hz) + (z·r - yhi·ylo))
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_cos_kernel(yhi::UInt64, ylo::UInt64)::UInt64
    z = soft_fmul(yhi, yhi)
    z2 = soft_fmul(z, z)

    # inner1 = C2 + z·C3
    zC3 = soft_fmul(z, _COS_C3)
    inner1 = soft_fadd(_COS_C2, zC3)
    # inner2 = C1 + z·inner1
    z_inner1 = soft_fmul(z, inner1)
    inner2 = soft_fadd(_COS_C1, z_inner1)
    # main = z·inner2
    main_part = soft_fmul(z, inner2)
    # high = C4 + z·(C5 + z·C6)
    zC6   = soft_fmul(z, _COS_C6)
    C5_zC6 = soft_fadd(_COS_C5, zC6)
    z_C5_zC6 = soft_fmul(z, C5_zC6)
    high_part = soft_fadd(_COS_C4, z_C5_zC6)
    # high2 = z²·z²·high
    z2z2 = soft_fmul(z2, z2)
    high_full = soft_fmul(z2z2, high_part)
    # r = main + high2
    r = soft_fadd(main_part, high_full)

    hz = soft_fmul(_RP_HALF_BITS, z)
    w  = soft_fsub(_RP_ONE_BITS, hz)
    # tmp = (1 - w) - hz
    one_sub_w = soft_fsub(_RP_ONE_BITS, w)
    tmp = soft_fsub(one_sub_w, hz)
    # corr = z·r - yhi·ylo
    zr = soft_fmul(z, r)
    yhi_ylo = soft_fmul(yhi, ylo)
    corr = soft_fsub(zr, yhi_ylo)
    # cos = w + (tmp + corr)
    tmp_corr = soft_fadd(tmp, corr)
    soft_fadd(w, tmp_corr)
end

# ─────────────────────────────────────────────────────────────────────
# cody_waite_2c — single-step Cody-Waite reduction for |x| in (π/4, 9π/4]
# range (n ∈ {±1, ±2, ±3, ±4}). `fn` is the Float64 of `n` (`±n.0`).
#
#   z   = x − fn·pio2_1
#   yhi = z − fn·pio2_1t
#   ylo = (z − yhi) − fn·pio2_1t
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_cody_waite_2c(a::UInt64, fn::UInt64)::Tuple{UInt64,UInt64}
    fn_pio2_1  = soft_fmul(fn, _RP_PIO2_1)
    z          = soft_fsub(a, fn_pio2_1)
    fn_pio2_1t = soft_fmul(fn, _RP_PIO2_1T)
    yhi        = soft_fsub(z, fn_pio2_1t)
    z_sub_yhi  = soft_fsub(z, yhi)
    ylo        = soft_fsub(z_sub_yhi, fn_pio2_1t)
    (yhi, ylo)
end

# ─────────────────────────────────────────────────────────────────────
# cody_waite_ext — full three-level Cody-Waite reduction for medium args
# `|x| < 2^28·π/2`. Computes `fn = round(x·invpio2)` via the
# `x·invpio2 + toint − toint` trick, then iteratively peels off pio2_1,
# pio2_2, pio2_3 levels until the cancellation between r and w is tame.
#
# In Bennett's branchless style we ALWAYS run all three levels and select
# the appropriate result via ifelse based on the precision indicators
# (`ex - ey > 16` and `ex - ey > 49`). The selection criteria use the
# difference between the original exponent of x (ex) and the exponent of
# the candidate y[0] (ey). When ex - ey is large, cancellation has eaten
# most of r's significant bits and we need the next refinement level.
#
# Returns `(n::Int32, yhi::UInt64, ylo::UInt64)`.
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_cody_waite_ext(a::UInt64)::Tuple{Int32,UInt64,UInt64}
    # fn = round(x · invpio2), via x*invpio2 + toint - toint trick
    a_invpio2 = soft_fmul(a, _RP_INVPIO2)
    a_invpio2_p_toint = soft_fadd(a_invpio2, _RP_TOINT)
    fn = soft_fsub(a_invpio2_p_toint, _RP_TOINT)
    n  = Int32(reinterpret(Int64, soft_fptosi(fn)) % Int32)

    # Level 1: r = a - fn*pio2_1; w = fn*pio2_1t
    fn_pio2_1  = soft_fmul(fn, _RP_PIO2_1)
    r1         = soft_fsub(a, fn_pio2_1)
    w1         = soft_fmul(fn, _RP_PIO2_1T)
    y1_l1      = soft_fsub(r1, w1)
    # If r - w over/under-shoots ±π/4, fn was wrong by 1; correct it.
    # Compare unsigned-compare-as-flag: y1_l1 < -π/4  OR  y1_l1 > +π/4
    # Bit pattern of -π/4: NEG_PIO4 = sign-flipped PIO4_BITS
    neg_pio4_bits = _RP_PIO4_BITS | UInt64(0x8000000000000000)
    overshoot_lo = (soft_fcmp_olt(y1_l1, neg_pio4_bits) != UInt64(0))
    overshoot_hi = (soft_fcmp_olt(_RP_PIO4_BITS, y1_l1) != UInt64(0))
    # If overshoot, decrement (or increment) fn by 1 and retry. We branchlessly
    # compute both correction directions and select.
    one_bits = _RP_ONE_BITS
    fn_dec = soft_fsub(fn, one_bits)
    fn_inc = soft_fadd(fn, one_bits)
    fn_corr = ifelse(overshoot_lo, fn_dec, ifelse(overshoot_hi, fn_inc, fn))
    n_corr  = ifelse(overshoot_lo, n - Int32(1),
              ifelse(overshoot_hi, n + Int32(1), n))
    # Recompute r, w with corrected fn
    fn_pio2_1c  = soft_fmul(fn_corr, _RP_PIO2_1)
    r           = soft_fsub(a, fn_pio2_1c)
    fn_pio2_1tc = soft_fmul(fn_corr, _RP_PIO2_1T)
    w           = fn_pio2_1tc
    y1          = soft_fsub(r, w)
    # ex = exponent field of x, ey1 = exponent field of y1
    ex  = (a >> 52) & UInt64(0x7FF)
    ey1 = (y1 >> 52) & UInt64(0x7FF)
    diff1 = Int64(ex) - Int64(ey1)
    need_l2 = diff1 > 16

    # Level 2: t=r; w = fn*pio2_2; r = t - w; w = fn*pio2_2t - ((t-r)-w)
    t2            = r
    w2_init       = soft_fmul(fn_corr, _RP_PIO2_2)
    r2            = soft_fsub(t2, w2_init)
    fn_pio2_2t    = soft_fmul(fn_corr, _RP_PIO2_2T)
    t2_sub_r2     = soft_fsub(t2, r2)
    t_sub_r_sub_w = soft_fsub(t2_sub_r2, w2_init)
    w2            = soft_fsub(fn_pio2_2t, t_sub_r_sub_w)
    y1_l2         = soft_fsub(r2, w2)
    ey2           = (y1_l2 >> 52) & UInt64(0x7FF)
    diff2         = Int64(ex) - Int64(ey2)
    need_l3       = diff2 > 49

    # Level 3: t=r; w = fn*pio2_3; r = t - w; w = fn*pio2_3t - ((t-r)-w)
    t3            = r2
    w3_init       = soft_fmul(fn_corr, _RP_PIO2_3)
    r3            = soft_fsub(t3, w3_init)
    fn_pio2_3t    = soft_fmul(fn_corr, _RP_PIO2_3T)
    t3_sub_r3     = soft_fsub(t3, r3)
    t_sub_r_sub_w_l3 = soft_fsub(t3_sub_r3, w3_init)
    w3            = soft_fsub(fn_pio2_3t, t_sub_r_sub_w_l3)
    # y1_l3 will be computed below from (r3, w3) only if need_l3

    # Select level: if need_l3, use (r3, w3); else if need_l2, use (r2, w2);
    # else use (r, w).
    r_sel = ifelse(need_l3, r3, ifelse(need_l2, r2, r))
    w_sel = ifelse(need_l3, w3, ifelse(need_l2, w2, w))
    yhi   = soft_fsub(r_sel, w_sel)
    r_sub_yhi = soft_fsub(r_sel, yhi)
    ylo   = soft_fsub(r_sub_yhi, w_sel)

    (n_corr, yhi, ylo)
end

# ─────────────────────────────────────────────────────────────────────
# 128-bit (hi, lo) UInt64-pair helpers. UInt128 cannot be used directly
# in functions destined for `reversible_compile` because LLVM emits i128
# CONSTANTS for shift amounts (e.g. `shl i128 %x, 64`) and Bennett's
# IR-walker rejects them per Bennett-l9cl / U09 (`IROperand.value` is
# Int64). The hand-rolled (hi, lo) representation produces only i64
# constants, which Bennett accepts.
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_clz64(x::UInt64)::UInt64
    n = UInt64(0)
    is32 = (x >> 32) == UInt64(0); n = ifelse(is32, n + UInt64(32), n); x = ifelse(is32, x << 32, x)
    is16 = (x >> 48) == UInt64(0); n = ifelse(is16, n + UInt64(16), n); x = ifelse(is16, x << 16, x)
    is8  = (x >> 56) == UInt64(0); n = ifelse(is8,  n + UInt64(8),  n); x = ifelse(is8,  x << 8,  x)
    is4  = (x >> 60) == UInt64(0); n = ifelse(is4,  n + UInt64(4),  n); x = ifelse(is4,  x << 4,  x)
    is2  = (x >> 62) == UInt64(0); n = ifelse(is2,  n + UInt64(2),  n); x = ifelse(is2,  x << 2,  x)
    is1  = (x >> 63) == UInt64(0); n = ifelse(is1,  n + UInt64(1),  n)
    all_zero = x == UInt64(0)
    ifelse(all_zero, UInt64(64), n)
end

@inline function _rp_clz128(hi::UInt64, lo::UInt64)::UInt64
    hi_zero = hi == UInt64(0)
    ifelse(hi_zero, UInt64(64) + _rp_clz64(lo), _rp_clz64(hi))
end

# Logical left shift of the 128-bit value (hi, lo) by `n` ∈ [0, 127].
@inline function _rp_shl128(a_hi::UInt64, a_lo::UInt64, n::UInt64)::Tuple{UInt64,UInt64}
    n_lt64 = n < UInt64(64)
    s     = ifelse(n_lt64, n, n - UInt64(64))
    sinv  = UInt64(64) - s
    s_zero = s == UInt64(0)
    cross = ifelse(s_zero, UInt64(0), a_lo >> sinv)
    hi_lt64 = (a_hi << s) | cross
    lo_lt64 = a_lo << s
    hi_ge64 = a_lo << s
    lo_ge64 = UInt64(0)
    (ifelse(n_lt64, hi_lt64, hi_ge64), ifelse(n_lt64, lo_lt64, lo_ge64))
end

# Logical right shift of (hi, lo) by `n` ∈ [0, 127].
@inline function _rp_shr128(a_hi::UInt64, a_lo::UInt64, n::UInt64)::Tuple{UInt64,UInt64}
    n_lt64 = n < UInt64(64)
    s     = ifelse(n_lt64, n, n - UInt64(64))
    sinv  = UInt64(64) - s
    s_zero = s == UInt64(0)
    cross = ifelse(s_zero, UInt64(0), a_hi << sinv)
    lo_lt64 = (a_lo >> s) | cross
    hi_lt64 = a_hi >> s
    lo_ge64 = a_hi >> s
    hi_ge64 = UInt64(0)
    (ifelse(n_lt64, hi_lt64, hi_ge64), ifelse(n_lt64, lo_lt64, lo_ge64))
end

# ─────────────────────────────────────────────────────────────────────
# fromfraction(f::Int128) — convert a signed Int128 fixed-point fraction
# to a (Float64, Float64) pair (z1, z2). Verbatim port of Julia
# base/special/rem_pio2.jl `fromfraction`, using (hi, lo) UInt64 pairs
# instead of native UInt128.
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_fromfraction(f_hi::UInt64, f_lo::UInt64)::Tuple{UInt64,UInt64}
    # Treat (f_hi, f_lo) as a signed Int128. Sign = top bit of f_hi.
    neg = (f_hi >> 63) & UInt64(1)
    f_zero = (f_hi == UInt64(0)) & (f_lo == UInt64(0))

    # |f| via two's complement: ~f + 1.
    (neg_f_hi, neg_f_lo) = _neg128(f_hi, f_lo)
    abs_hi = ifelse(neg != UInt64(0), neg_f_hi, f_hi)
    abs_lo = ifelse(neg != UInt64(0), neg_f_lo, f_lo)

    s = neg << 63

    # n1 = top_set_bit(|f|) = 128 - clz128(|f|)
    n1 = UInt64(128) - _rp_clz128(abs_hi, abs_lo)

    # m1 = ((|f| >> (n1-26)) % UInt64) << 27
    # Substitute n1=27 for the f_zero case so (n1-26) doesn't underflow.
    n1_safe = ifelse(f_zero, UInt64(27), n1)
    (sh_hi, sh_lo) = _rp_shr128(abs_hi, abs_lo, n1_safe - UInt64(26))
    m1 = sh_lo << 27   # only lo part survives the (% UInt64) — top 26 bits of |f| in bits 27..52
    d1 = ((n1_safe - UInt64(128) + UInt64(1021)) & UInt64(0x7FF)) << 52
    z1 = s | (d1 + m1)

    # x2 = |f| - (m1_orig << (n1-26)) where m1_orig = top 26 bits of |f|.
    # Julia source has `x - (UInt128(m1) << (n1-53))` with m1 = m1_orig << 27;
    # collapsing the two shifts: m1_orig << (27 + n1 - 53) = m1_orig << (n1-26).
    m1_orig = sh_lo
    (sub_hi, sub_lo) = _rp_shl128(UInt64(0), m1_orig, n1_safe - UInt64(26))
    (x2_hi, x2_lo) = _sub128(abs_hi, abs_lo, sub_hi, sub_lo)
    x2_zero = (x2_hi == UInt64(0)) & (x2_lo == UInt64(0))

    # n2 = top_set_bit(x2). For x2_zero, substitute 64 (any nonzero ≥53 works).
    n2_raw = UInt64(128) - _rp_clz128(x2_hi, x2_lo)
    n2_safe = ifelse(x2_zero, UInt64(64), n2_raw)

    (sh2_hi, sh2_lo) = _rp_shr128(x2_hi, x2_lo, n2_safe - UInt64(53))
    m2 = sh2_lo
    d2 = ((n2_safe - UInt64(128) + UInt64(1021)) & UInt64(0x7FF)) << 52
    z2_normal = s | (d2 + m2)
    z2 = ifelse(x2_zero, UInt64(0), z2_normal)

    z1_final = ifelse(f_zero, UInt64(0), z1)
    z2_final = ifelse(f_zero, UInt64(0), z2)
    (z1_final, z2_final)
end

# ─────────────────────────────────────────────────────────────────────
# paynehanek(x) — multi-precision argument reduction for huge args.
# Computes the equivalent of `x mod π/2` to ~106 bits of precision and
# returns `(q, yhi, ylo)` where q is the quadrant and (yhi, ylo) is the
# reduced argument as a DoubleFloat64.
#
# Algorithm:
#   1. X = mantissa with implicit bit set: (a & FRAC_MASK) | (1 << 52)
#   2. k = raw_exponent - bias - 52 = effective binary exponent of X
#   3. idx = k >> 6, shift = k mod 64. Look up a 192-bit window of 1/(2π)
#      from INV_2PI starting at index idx, shifted left by shift.
#   4. Compute w = X * 1/(2π)_window in 256-bit precision (only the
#      relevant 128-bit slice survives after the truncation):
#        w1 = (X * a1) << 64   (bits 64..127)
#        w2 = X * a2           (bits 0..127, plus carry)
#        w3 = (X * a3) >> 64   (bits 0..63)
#        w  = w1 + w2 + w3     (mod 2^128)
#   5. Apply sign of x (negate w if x < 0).
#   6. q = ((w >> 125) + 1) >> 1 mod 4   (round-to-nearest quadrant)
#   7. f = (w << 2) % Int128             (fractional part × 4)
#   8. (z_hi, z_lo) = fromfraction(f)    (Float64 pair representing f / 2^128)
#   9. (y_hi, y_lo) = z * π/2 in extended precision
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_paynehanek(a::UInt64)::Tuple{Int32,UInt64,UInt64}
    fa = a & FRAC_MASK
    raw_exp = (a >> 52) & UInt64(0x7FF)
    X = fa | IMPLICIT
    # k = raw_exp - 1023 - 52 = raw_exp - 1075. For tiny inputs (raw_exp = 0)
    # k = -1075 → idx = -17 (deeply negative). The branchless dispatch in
    # _rp_rem_pio2 / soft_sin / soft_cos discards the paynehanek result
    # for non-huge args; here we just need the lookups to not OOB.
    k_signed = Int64(raw_exp) - Int64(1075)
    idx_signed = k_signed >> 6   # arithmetic shift = floor(k/64)
    shift = UInt64(k_signed - (idx_signed << 6))   # k mod 64, in [0, 63]

    # Lookups: Julia source uses INV_2PI[idx+1..idx+4] (1-based). With our
    # 0-based `_inv_2pi_lookup(i)` returning Julia's INV_2PI[i+1], the
    # mapping is `_inv_2pi_lookup(idx_signed + 0..3)`. All four indices
    # must be clamped into [0, 18] for branchless safety — paynehanek
    # is invoked unconditionally in the dispatch and tiny inputs would
    # otherwise OOB-access the table (LLVM emits `unreachable` for the
    # impossible-but-actually-reachable branch).
    idx_a1 = idx_signed
    idx_a2 = idx_signed + Int64(1)
    idx_a3 = idx_signed + Int64(2)
    idx_a4 = idx_signed + Int64(3)
    a1_invalid = idx_a1 < Int64(0)
    a2_invalid = idx_a2 < Int64(0)
    a3_invalid = idx_a3 < Int64(0)
    a4_invalid = idx_a4 < Int64(0)
    raw_a1 = _inv_2pi_lookup(Int(ifelse(a1_invalid, Int64(0), idx_a1)))
    raw_a2 = _inv_2pi_lookup(Int(ifelse(a2_invalid, Int64(0), idx_a2)))
    raw_a3 = _inv_2pi_lookup(Int(ifelse(a3_invalid, Int64(0), idx_a3)))
    raw_a4 = _inv_2pi_lookup(Int(ifelse(a4_invalid, Int64(0), idx_a4)))
    raw_a1 = ifelse(a1_invalid, UInt64(0), raw_a1)
    raw_a2 = ifelse(a2_invalid, UInt64(0), raw_a2)
    raw_a3 = ifelse(a3_invalid, UInt64(0), raw_a3)
    raw_a4 = ifelse(a4_invalid, UInt64(0), raw_a4)

    # Window construction. For shift == 0, INV_2PI[idx+i] used verbatim.
    # Else each entry shifted left, OR'd with top bits of the next.
    # Guard `>> (64 - shift)` to avoid `>> 64` when shift == 0.
    s_zero = shift == UInt64(0)
    inv_s  = UInt64(64) - shift
    a1_lo = ifelse(s_zero, UInt64(0), raw_a2 >> inv_s)
    a2_lo = ifelse(s_zero, UInt64(0), raw_a3 >> inv_s)
    a3_lo = ifelse(s_zero, UInt64(0), raw_a4 >> inv_s)
    a1 = (raw_a1 << shift) | a1_lo
    a2 = (raw_a2 << shift) | a2_lo
    a3 = (raw_a3 << shift) | a3_lo

    # w = (X*a1) << 64 + X*a2 + ((X*a3) >> 64), all in 128 bits mod 2^128.
    # Use _sf_widemul_u64_to_128 (existing helper) to avoid emitting i128
    # constants — Bennett rejects those (Bennett-l9cl / U09).
    Xa1_lo = X * a1   # low 64 bits of X*a1; high 64 are above the window
    w1_hi = Xa1_lo
    w1_lo = UInt64(0)
    (w2_hi, w2_lo) = _sf_widemul_u64_to_128(X, a2)
    (w3_full_hi, _) = _sf_widemul_u64_to_128(X, a3)
    w3_hi = UInt64(0)
    w3_lo = w3_full_hi   # (X*a3) >> 64 = high half of full product

    (s12_hi, s12_lo) = _add128(w1_hi, w1_lo, w2_hi, w2_lo)
    (w_hi, w_lo)    = _add128(s12_hi, s12_lo, w3_hi, w3_lo)

    # flipsign: if x < 0, negate (hi, lo) mod 2^128.
    sign_x = a >> 63
    (neg_w_hi, neg_w_lo) = _neg128(w_hi, w_lo)
    sw_hi = ifelse(sign_x != UInt64(0), neg_w_hi, w_hi)
    sw_lo = ifelse(sign_x != UInt64(0), neg_w_lo, w_lo)

    # q = (((w >> 125) % Int) + 1) >> 1 — round-to-nearest quadrant.
    # On signed Int128, `>> 125` is arithmetic shift giving [-4, 3].
    # Extract bits [125..127] of the 128-bit value as a 3-bit signed int.
    top3 = (sw_hi >> 61) & UInt64(7)
    top3_signed = Int64(top3) - ifelse((top3 & UInt64(4)) != UInt64(0), Int64(8), Int64(0))
    q_raw = (top3_signed + Int64(1)) >> 1
    q = Int32(q_raw & Int64(3))

    # f = (w << 2) — fractional part scaled by 4 (drop top 2 bits).
    (f_hi, f_lo) = _rp_shl128(sw_hi, sw_lo, UInt64(2))

    (z_hi, z_lo) = _rp_fromfraction(f_hi, f_lo)

    # y = z · π/2 in extended precision.
    pio2_hi = _RP_PAYNE_PIO2_HI
    pio2_lo_const = _RP_PAYNE_PIO2_LO
    pio2 = _RP_PAYNE_PIO2
    z_sum = soft_fadd(z_hi, z_lo)
    y_hi = soft_fmul(z_sum, pio2)
    # y_lo = (((z_hi*pio2_hi - y_hi) + z_hi*pio2_lo) + z_lo*pio2_hi) + z_lo*pio2_lo
    zhi_pi2hi = soft_fmul(z_hi, pio2_hi)
    diff = soft_fsub(zhi_pi2hi, y_hi)
    zhi_pi2lo = soft_fmul(z_hi, pio2_lo_const)
    sum1 = soft_fadd(diff, zhi_pi2lo)
    zlo_pi2hi = soft_fmul(z_lo, pio2_hi)
    sum2 = soft_fadd(sum1, zlo_pi2hi)
    zlo_pi2lo = soft_fmul(z_lo, pio2_lo_const)
    y_lo = soft_fadd(sum2, zlo_pi2lo)

    (q, y_hi, y_lo)
end

# ─────────────────────────────────────────────────────────────────────
# rem_pio2 dispatcher: branchless cascade over high-word ranges. Returns
# (n::Int32, yhi, ylo). Mirrors Julia's `rem_pio2_kernel` structure.
#
# In Bennett's branchless idiom we ALWAYS compute every branch's result
# and select the appropriate one via ifelse on the high-word bucket
# membership flags. This is profligate compared to the if/else cascade
# in C/Julia (each branch does ~10-30 fp ops), but it produces a flat IR
# graph for the reversible-compile pipeline.
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_rem_pio2(a::UInt64)::Tuple{Int32,UInt64,UInt64}
    xhp = _rp_pos_high_word(a)
    sign_bit = a >> 63

    # Compute Cody-Waite 2c results for n ∈ {±1, ±2, ±3, ±4}
    fn_p1 = _RP_ONE_BITS                                     # 1.0
    fn_n1 = _RP_NEG_ONE_BITS                                 # -1.0
    fn_p2 = reinterpret(UInt64,  2.0)
    fn_n2 = reinterpret(UInt64, -2.0)
    fn_p3 = reinterpret(UInt64,  3.0)
    fn_n3 = reinterpret(UInt64, -3.0)
    fn_p4 = reinterpret(UInt64,  4.0)
    fn_n4 = reinterpret(UInt64, -4.0)

    fn1 = ifelse(sign_bit != UInt64(0), fn_n1, fn_p1)
    n1  = ifelse(sign_bit != UInt64(0), Int32(-1), Int32(1))
    fn2 = ifelse(sign_bit != UInt64(0), fn_n2, fn_p2)
    n2  = ifelse(sign_bit != UInt64(0), Int32(-2), Int32(2))
    fn3 = ifelse(sign_bit != UInt64(0), fn_n3, fn_p3)
    n3  = ifelse(sign_bit != UInt64(0), Int32(-3), Int32(3))
    fn4 = ifelse(sign_bit != UInt64(0), fn_n4, fn_p4)
    n4  = ifelse(sign_bit != UInt64(0), Int32(-4), Int32(4))

    # Compute 2c reductions for fn1..fn4
    (yhi_2c1, ylo_2c1) = _rp_cody_waite_2c(a, fn1)
    (yhi_2c2, ylo_2c2) = _rp_cody_waite_2c(a, fn2)
    (yhi_2c3, ylo_2c3) = _rp_cody_waite_2c(a, fn3)
    (yhi_2c4, ylo_2c4) = _rp_cody_waite_2c(a, fn4)

    # Compute Cody-Waite ext (general medium-arg path)
    (n_ext, yhi_ext, ylo_ext) = _rp_cody_waite_ext(a)

    # Compute Payne-Hanek (huge-arg path)
    (n_ph, yhi_ph, ylo_ph) = _rp_paynehanek(a)

    # Boundary singular high-word values that force ext path.
    on_3pio2 = (xhp & UInt32(0xFFFFF)) == UInt32(0x21FB) ?
               # masking lower 20 bits of xhp; pio2_n landmarks have
               # specific patterns. Simpler: explicit equality checks.
               UInt64(0) : UInt64(0)   # placeholder — we'll use explicit checks
    # Actually use explicit equality vs the singular boundary high-words:
    is_3pio2_boundary = (xhp == _RP_HI_3PIO2)
    is_4pio2_boundary = (xhp == _RP_HI_4PIO2)
    is_2pio2_boundary = ((xhp & UInt32(0xFFFFF)) == UInt32(0x921FB)) & (xhp <= _RP_HI_5PIO4)

    # Bucket determination (branchless cascade):
    in_2c1 = xhp <= _RP_HI_3PIO4              # |x| ≤ 3π/4 → n=±1
    in_2c2 = (xhp > _RP_HI_3PIO4) & (xhp <= _RP_HI_5PIO4)   # ≤ 5π/4 → n=±2
    in_2c3 = (xhp > _RP_HI_5PIO4) & (xhp <= _RP_HI_7PIO4)   # ≤ 7π/4 → n=±3
    in_2c4 = (xhp > _RP_HI_7PIO4) & (xhp <= _RP_HI_9PIO4)   # ≤ 9π/4 → n=±4
    in_ext = (xhp > _RP_HI_9PIO4) & (xhp < _RP_HI_2P28)     # medium → ext
    in_ph  = xhp >= _RP_HI_2P28                              # huge → Payne-Hanek

    # Singular boundaries (within 2c1..2c4 ranges) force ext to avoid the
    # cancellation that 2c hits at exactly n·π/2.
    force_ext_in_2c1 = is_2pio2_boundary & in_2c1   # never triggers (2pio2 > 3pi/4) but defensive
    force_ext_in_2c3 = is_3pio2_boundary
    force_ext_in_2c4 = is_4pio2_boundary

    use_ext = in_ext | force_ext_in_2c1 | force_ext_in_2c3 | force_ext_in_2c4
    use_ph  = in_ph

    # Unconditional in_2c2 vs ext when 2pio2 boundary lands within 2c2
    # (Julia source maps xhp == 0x4002d97c → ext via the (xhp & 0xfffff) ==
    # 0x921fb check). The check above (`(xhp & 0xFFFFF) == 0x921FB) & (xhp ≤
    # 5π/4)`) covers it.
    use_ext = use_ext | (is_2pio2_boundary & in_2c2)

    # Final select: priority is ext / ph > 2c{1,2,3,4}.
    n_2c   = ifelse(in_2c1, n1, ifelse(in_2c2, n2, ifelse(in_2c3, n3, n4)))
    yhi_2c = ifelse(in_2c1, yhi_2c1, ifelse(in_2c2, yhi_2c2,
              ifelse(in_2c3, yhi_2c3, yhi_2c4)))
    ylo_2c = ifelse(in_2c1, ylo_2c1, ifelse(in_2c2, ylo_2c2,
              ifelse(in_2c3, ylo_2c3, ylo_2c4)))

    n_pre   = ifelse(use_ph, n_ph,  ifelse(use_ext, n_ext, n_2c))
    yhi_pre = ifelse(use_ph, yhi_ph, ifelse(use_ext, yhi_ext, yhi_2c))
    ylo_pre = ifelse(use_ph, ylo_ph, ifelse(use_ext, ylo_ext, ylo_2c))

    (n_pre, yhi_pre, ylo_pre)
end

# ─────────────────────────────────────────────────────────────────────
# Top-level soft_sin / soft_cos.
# ─────────────────────────────────────────────────────────────────────

"""
    soft_sin(a::UInt64) -> UInt64

IEEE 754 double-precision sine `sin(x)` on raw bit patterns. **≤2 ULP vs
`Base.sin`** across the full Float64 input range; bit-exact vs the
system libm (`ccall(:sin, ...)`) on Linux. Branchless integer arithmetic
for special-case dispatch, soft_f* primitives for the polynomial body,
Cody-Waite range reduction for medium args (`|x| < 2^28·π/2`), and
Payne-Hanek multi-precision reduction for huge args.

Special cases (last-write-wins ifelse cascade):
- sin(NaN)    = NaN  (propagate, force quiet-bit)
- sin(±Inf)   = NaN
- sin(±0)     = ±0   (sign-preserving)

Algorithm: see worklog/055 for the design memo. Faithful port of musl
`sin.c` / `__sin.c` / `__rem_pio2.c` / `__rem_pio2_large.c` (FreeBSD/
SunPro 1993, BSD-licensed).
"""
@inline function soft_sin(a::UInt64)::UInt64
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    xhp = _rp_pos_high_word(a)

    # Special-case detection
    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_inf  = (ea == UInt64(0x7FF)) & (fa == UInt64(0))
    a_zero = (ea == UInt64(0)) & (fa == UInt64(0))
    is_tiny = xhp < _RP_SIN_TINY_HI            # |x| < 2^-26

    # Path A: small-arg (|x| < π/4), use kernel directly with ylo=0
    is_small = xhp <= _RP_HI_PIO4
    yhi_small = a
    ylo_small = UInt64(0)
    sin_small = _rp_sin_kernel(yhi_small, ylo_small)

    # Path B: reduced (|x| ≥ π/4), via rem_pio2 + quadrant select
    (n, yhi_red, ylo_red) = _rp_rem_pio2(a)
    sin_y = _rp_sin_kernel(yhi_red, ylo_red)
    cos_y = _rp_cos_kernel(yhi_red, ylo_red)
    neg_sin_y = sin_y ⊻ UInt64(0x8000000000000000)
    neg_cos_y = cos_y ⊻ UInt64(0x8000000000000000)

    n_mod4 = (n % UInt32) & UInt32(0x3)
    case0 = sin_y         # n%4 == 0: sin(y)
    case1 = cos_y         # n%4 == 1: cos(y)
    case2 = neg_sin_y     # n%4 == 2: -sin(y)
    case3 = neg_cos_y     # n%4 == 3: -cos(y)
    sin_reduced = ifelse(n_mod4 == UInt32(0), case0,
                  ifelse(n_mod4 == UInt32(1), case1,
                  ifelse(n_mod4 == UInt32(2), case2, case3)))

    result = ifelse(is_small, sin_small, sin_reduced)
    # Tiny: sin(x) = x bit-exact (preserves -0 for sin(-0) = -0)
    result = ifelse(is_tiny, a, result)
    # Special-case override chain (last-write-wins)
    result = ifelse(a_zero, a, result)         # sin(±0) = ±0
    result = ifelse(a_inf,  QNAN, result)      # sin(±Inf) = NaN
    result = ifelse(a_nan,  a | QUIET_BIT, result)  # NaN propagation
    return result
end

"""
    soft_cos(a::UInt64) -> UInt64

IEEE 754 double-precision cosine `cos(x)` on raw bit patterns. **≤2 ULP
vs `Base.cos`** across the full Float64 input range; bit-exact vs system
libm (`ccall(:cos, ...)`) on Linux.

Special cases (last-write-wins ifelse cascade):
- cos(NaN)    = NaN
- cos(±Inf)   = NaN
- cos(±0)     = +1.0
"""
@inline function soft_cos(a::UInt64)::UInt64
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    xhp = _rp_pos_high_word(a)

    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_inf  = (ea == UInt64(0x7FF)) & (fa == UInt64(0))
    is_tiny_cos = xhp < _RP_COS_TINY_HI         # |x| < 2^-27·√2 → return 1
    is_small = xhp <= _RP_HI_PIO4

    yhi_small = a
    ylo_small = UInt64(0)
    cos_small = _rp_cos_kernel(yhi_small, ylo_small)

    (n, yhi_red, ylo_red) = _rp_rem_pio2(a)
    sin_y = _rp_sin_kernel(yhi_red, ylo_red)
    cos_y = _rp_cos_kernel(yhi_red, ylo_red)
    neg_sin_y = sin_y ⊻ UInt64(0x8000000000000000)
    neg_cos_y = cos_y ⊻ UInt64(0x8000000000000000)

    n_mod4 = (n % UInt32) & UInt32(0x3)
    case0 = cos_y          # n%4 == 0: cos(y)
    case1 = neg_sin_y      # n%4 == 1: -sin(y)
    case2 = neg_cos_y      # n%4 == 2: -cos(y)
    case3 = sin_y          # n%4 == 3: sin(y)
    cos_reduced = ifelse(n_mod4 == UInt32(0), case0,
                  ifelse(n_mod4 == UInt32(1), case1,
                  ifelse(n_mod4 == UInt32(2), case2, case3)))

    result = ifelse(is_small, cos_small, cos_reduced)
    result = ifelse(is_tiny_cos, _RP_ONE_BITS, result)
    result = ifelse(a_inf, QNAN, result)
    result = ifelse(a_nan, a | QUIET_BIT, result)
    return result
end
