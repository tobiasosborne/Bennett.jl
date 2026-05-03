# IEEE 754 binary64 tangent on raw bit patterns. Faithful port of musl's
# `src/math/tan.c` and `__tan.c` (FreeBSD/SunPro 1993, BSD-licensed;
# identical implementation in glibc and Julia-via-openlibm). Reuses
# `_rp_rem_pio2` from `fsin.jl` for argument reduction. See worklog/057
# for the design memo (Bennett-s1zl).
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across the full f64
# range. Bennett.jl practical target vs `Base.tan`: ≤2 ULP. Bit-exact vs
# `ccall(:tan, ...)` (system libm) on Linux.
#
# Algorithm:
#   1. Special-case dispatch (NaN → propagate, ±Inf → NaN, ±0 → ±0,
#      tiny |x|<2^-27 → x).
#   2. Range reduction `x = n·π/2 + y` with y ∈ [-π/4, π/4]:
#      - |x| ≤ π/4: y = x, n = 0 (no reduction)
#      - else: `_rp_rem_pio2`
#   3. Kernel(yhi, ylo, n & 1): if n is even → tan(y); if odd → -cot(y).
#
# Big-arm refinement (inside the kernel): when |y| ≥ 0.6744, the polynomial
# loses precision near π/4. Fold to `y' = π/4 - |y|`, evaluate the
# polynomial there, and unfold via `tan(π/4 ± y') = (1±tan y')/(1∓tan y')`.
# Bennett evaluates BOTH the small-arm and big-arm polynomials and
# branchlessly selects via ifelse, paying ~2× polynomial cost for branchless
# determinism.

# ─────────────────────────────────────────────────────────────────────
# Tan polynomial coefficients T1..T13 (FreeBSD k_tan.c, Sun 1993).
# Approximation of tan(x) on [0, π/4] via stratified Horner:
#   r = T2 + z²·T4 + z⁴·T6 + z⁶·T8 + z⁸·T10 + z¹⁰·T12
#   v = z·(T3 + z²·T5 + z⁴·T7 + z⁶·T9 + z⁸·T11 + z¹⁰·T13)
#   tan ≈ x + s·T1 + z·(s·(r+v) + y) + y    where s = z·x, z = x²
# ─────────────────────────────────────────────────────────────────────
const _TAN_T1  = reinterpret(UInt64,  3.33333333333334091986e-01)  # 0x3FD55555_55555563
const _TAN_T2  = reinterpret(UInt64,  1.33333333333201242699e-01)  # 0x3FC11111_1110FE7A
const _TAN_T3  = reinterpret(UInt64,  5.39682539762260521377e-02)  # 0x3FABA1BA_1BB341FE
const _TAN_T4  = reinterpret(UInt64,  2.18694882948595424599e-02)  # 0x3F9664F4_8406D637
const _TAN_T5  = reinterpret(UInt64,  8.86323982359930005737e-03)  # 0x3F8226E3_E96E8493
const _TAN_T6  = reinterpret(UInt64,  3.59207910759131235356e-03)  # 0x3F6D6D22_C9560328
const _TAN_T7  = reinterpret(UInt64,  1.45620945432529025516e-03)  # 0x3F57DBC8_FEE08315
const _TAN_T8  = reinterpret(UInt64,  5.88041240820264096874e-04)  # 0x3F4344D8_F2F26501
const _TAN_T9  = reinterpret(UInt64,  2.46463134818469906812e-04)  # 0x3F3026F7_1A8D1068
const _TAN_T10 = reinterpret(UInt64,  7.81794442939557092300e-05)  # 0x3F147E88_A03792A6
const _TAN_T11 = reinterpret(UInt64,  7.14072491382608190305e-05)  # 0x3F12B80F_32F0A7E9
const _TAN_T12 = reinterpret(UInt64, -1.85586374855275456654e-05)  # 0xBEF375CB_DB605373
const _TAN_T13 = reinterpret(UInt64,  2.59073051863633712884e-05)  # 0x3EFB2A70_74BF7AD4

# pio4lo: round-off term such that pio4 + pio4lo ≈ π/4 to ~106 bits.
# (pio4 high part is `_RP_PIO4_BITS` from fsin.jl.)
const _TAN_PIO4LO = reinterpret(UInt64,  3.06161699786838301793e-17)  # 0x3C81A626_33145C07

# Float64 constant 2.0 used in the big-arm unfold.
const _TAN_TWO_BITS = reinterpret(UInt64, 2.0)                       # 0x40000000_00000000

# Tiny-arg fast-path threshold (high-word comparison, matching musl tan.c).
#   tan: |x| < 2^-27 → return x   (high word < 0x3E400000)
const _RP_TAN_TINY_HI = UInt32(0x3E400000)

# Big-arm threshold (matching musl __tan.c).
#   |x| ≥ 0.6744 → fold to π/4 - |x| inside the kernel for accuracy.
const _RP_TAN_BIG_HI = UInt32(0x3FE59428)

# Mask that zeros the low 32 bits of a Float64 mantissa. Used in the
# odd-arm SET_LOW_WORD precision trick from musl __tan.c.
const _TAN_HI32_MASK = UInt64(0xFFFFFFFF00000000)

# ─────────────────────────────────────────────────────────────────────
# Tan kernel: tan(yhi + ylo) on [-π/4, π/4], with parity flip via `odd`.
# `odd == false` → return tan(y).
# `odd == true`  → return -cot(y) = -1/tan(y).
#
# Branchless: BOTH the small-arm and big-arm polynomial paths are
# computed; ifelse selects the correct one. Both odd and not-odd return
# values are computed and selected the same way.
# ─────────────────────────────────────────────────────────────────────
@inline function _rp_tan_kernel(yhi::UInt64, ylo::UInt64, odd::Bool)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    # Detect "big" (|yhi| ≥ 0.6744) and the original sign of yhi.
    yhi_high = UInt32((yhi & UInt64(0x7FFFFFFFFFFFFFFF)) >> 32)
    big = yhi_high >= _RP_TAN_BIG_HI
    sign = (yhi & SIGN_BIT) != UInt64(0)

    # Big-arm fold (always computed; selected via ifelse below):
    #   yhi_abs = |yhi|, ylo_abs = ylo with sign matching yhi (matches
    #     the musl `if (sign) { x=-x; y=-y; }` step).
    #   xb_hi = pio4 - |yhi|
    #   xb_lo = pio4lo - sign-matched ylo
    #   xb    = xb_hi + xb_lo,  yb = +0
    flip_mask = ifelse(sign, SIGN_BIT, UInt64(0))
    yhi_abs = yhi ⊻ flip_mask
    ylo_abs = ylo ⊻ flip_mask
    xb_hi = soft_fsub(_RP_PIO4_BITS, yhi_abs)
    xb_lo = soft_fsub(_TAN_PIO4LO, ylo_abs)
    xb    = soft_fadd(xb_hi, xb_lo)
    yb    = UInt64(0)  # +0.0

    # Polynomial inputs: small-arm uses (yhi, ylo); big-arm uses (xb, +0).
    x = ifelse(big, xb, yhi)
    y = ifelse(big, yb, ylo)

    # Polynomial body (musl __tan): z = x², w = z².
    z = soft_fmul(x, x)
    w = soft_fmul(z, z)

    # r = T2 + w·(T4 + w·(T6 + w·(T8 + w·(T10 + w·T12))))   — even-numbered
    t = soft_fmul(w, _TAN_T12)
    t = soft_fadd(_TAN_T10, t)
    t = soft_fmul(w, t)
    t = soft_fadd(_TAN_T8, t)
    t = soft_fmul(w, t)
    t = soft_fadd(_TAN_T6, t)
    t = soft_fmul(w, t)
    t = soft_fadd(_TAN_T4, t)
    t = soft_fmul(w, t)
    r_part = soft_fadd(_TAN_T2, t)

    # v_inner = T3 + w·(T5 + w·(T7 + w·(T9 + w·(T11 + w·T13))))   — odd-numbered
    u = soft_fmul(w, _TAN_T13)
    u = soft_fadd(_TAN_T11, u)
    u = soft_fmul(w, u)
    u = soft_fadd(_TAN_T9, u)
    u = soft_fmul(w, u)
    u = soft_fadd(_TAN_T7, u)
    u = soft_fmul(w, u)
    u = soft_fadd(_TAN_T5, u)
    u = soft_fmul(w, u)
    v_inner = soft_fadd(_TAN_T3, u)
    # v = z · v_inner
    v_part = soft_fmul(z, v_inner)

    # s = z·x;  r' = y + z·(s·(r+v) + y) + s·T1
    s = soft_fmul(z, x)
    rpv = soft_fadd(r_part, v_part)
    s_rpv = soft_fmul(s, rpv)
    inner = soft_fadd(s_rpv, y)
    z_inner = soft_fmul(z, inner)
    z_inner_p_y = soft_fadd(y, z_inner)
    s_T1 = soft_fmul(s, _TAN_T1)
    r_final = soft_fadd(z_inner_p_y, s_T1)
    # w_final = x + r_final  (the musl polynomial result, ≈ tan(x))
    w_final = soft_fadd(x, r_final)

    # ─── Big-arm unfold ───────────────────────────────────────────────
    # s_b = 1 - 2·odd  ∈ {+1, -1}
    # v_b = s_b - 2·(x + (r_final - w_final² / (w_final + s_b)))
    # return -v_b if sign else v_b
    s_b = ifelse(odd, _RP_NEG_ONE_BITS, _RP_ONE_BITS)
    wf_sq    = soft_fmul(w_final, w_final)
    wf_p_sb  = soft_fadd(w_final, s_b)
    wfsq_div = soft_fdiv(wf_sq, wf_p_sb)
    r_sub    = soft_fsub(r_final, wfsq_div)
    x_p_r    = soft_fadd(x, r_sub)
    two_xpr  = soft_fmul(_TAN_TWO_BITS, x_p_r)
    v_b      = soft_fsub(s_b, two_xpr)
    v_b_neg  = v_b ⊻ SIGN_BIT
    big_result = ifelse(sign, v_b_neg, v_b)

    # ─── Non-big, not-odd ─────────────────────────────────────────────
    # Return w_final ≈ tan(x).
    not_odd_result = w_final

    # ─── Non-big, odd: -1/(x+r) computed accurately (musl's SET_LOW_WORD
    # trick). z₂ = w_final with low 32 mantissa bits zeroed; v₃ = r -
    # (z₂ - x); a = -1/w_final; a₀ = a with low 32 bits zeroed; result =
    # a₀ + a·(1 + a₀·z₂ + a₀·v₃).
    # ──────────────────────────────────────────────────────────────────
    z2       = w_final & _TAN_HI32_MASK
    z2_sub_x = soft_fsub(z2, x)
    v3       = soft_fsub(r_final, z2_sub_x)
    a        = soft_fdiv(_RP_NEG_ONE_BITS, w_final)
    a0       = a & _TAN_HI32_MASK
    a0_z2    = soft_fmul(a0, z2)
    one_p    = soft_fadd(_RP_ONE_BITS, a0_z2)
    a0_v3    = soft_fmul(a0, v3)
    inside   = soft_fadd(one_p, a0_v3)
    a_inside = soft_fmul(a, inside)
    odd_result = soft_fadd(a0, a_inside)

    non_big = ifelse(odd, odd_result, not_odd_result)
    ifelse(big, big_result, non_big)
end

"""
    soft_tan(a::UInt64) -> UInt64

IEEE 754 double-precision tangent `tan(x)` on raw bit patterns. **≤2 ULP
vs `Base.tan`** across the full Float64 input range; bit-exact vs system
libm (`ccall(:tan, ...)`) on Linux.

Special cases (last-write-wins ifelse cascade):
- tan(NaN)   = NaN  (propagate, force quiet-bit)
- tan(±Inf)  = NaN
- tan(±0)    = ±0   (sign-preserving)
- |x| < 2^-27 → x   (bit-exact, matches musl tan.c)

Algorithm: see worklog/057 for the design memo. Faithful port of musl
`tan.c` / `__tan.c` (FreeBSD/SunPro 1993, BSD-licensed) reusing the
`_rp_rem_pio2` argument-reduction infrastructure from `fsin.jl`.
"""
@inline function soft_tan(a::UInt64)::UInt64
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    xhp = _rp_pos_high_word(a)

    # Special-case detection
    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_inf  = (ea == UInt64(0x7FF)) & (fa == UInt64(0))
    a_zero = (ea == UInt64(0)) & (fa == UInt64(0))
    is_tiny = xhp < _RP_TAN_TINY_HI            # |x| < 2^-27

    # Path A: small (|x| ≤ π/4), kernel directly with ylo=0, odd=false.
    is_small = xhp <= _RP_HI_PIO4
    tan_small = _rp_tan_kernel(a, UInt64(0), false)

    # Path B: reduced (|x| > π/4), via rem_pio2 + parity select.
    (n, yhi_red, ylo_red) = _rp_rem_pio2(a)
    n_odd = (n & Int32(1)) != Int32(0)
    tan_reduced = _rp_tan_kernel(yhi_red, ylo_red, n_odd)

    result = ifelse(is_small, tan_small, tan_reduced)
    # Tiny: tan(x) = x bit-exact (preserves -0 for tan(-0) = -0).
    result = ifelse(is_tiny, a, result)
    # Special-case override chain (last-write-wins).
    result = ifelse(a_zero, a, result)
    result = ifelse(a_inf,  QNAN, result)
    result = ifelse(a_nan,  a | QUIET_BIT, result)
    return result
end
