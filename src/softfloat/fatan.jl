# IEEE 754 binary64 arctangent on raw bit patterns. Faithful port of
# musl's `src/math/atan.c` (FreeBSD/SunPro 1993, BSD-licensed; identical
# implementation in glibc and Julia-via-openlibm). Self-contained — no
# dependency on `_rp_rem_pio2` (atan has bounded-range argument reduction
# via rational maps, no Cody-Waite or Payne-Hanek). See worklog/057 for
# the design memo (Bennett-qpke). Tier C1.2 in the Enzyme parity north-
# star (`Bennett-Enzyme-Parity-NorthStar.md`), follow-on to Bennett-s1zl
# (soft_tan).
#
# Reference accuracy: musl/openlibm targets ≤1 ULP across the full f64
# range. Bennett.jl practical target vs `Base.atan`: ≤2 ULP. Bit-exact
# vs `ccall(:atan, ...)` (system libm) on Linux.
#
# Algorithm (musl atan.c, branchless):
#   1. Sign + abs: split into (sign_bit, |x|). |x|'s high 32 bits drive
#      range dispatch.
#   2. Huge fast-path: |x| ≥ 2^66 → return ±π/2 (NaN propagates).
#   3. Tiny fast-path: |x| < 2^-27 → return x bit-exact.
#   4. Range split via |x|'s high word (5 buckets, id ∈ {-1, 0, 1, 2, 3}):
#        |x| < 0.4375        → id = -1, x' = x         (no reduction)
#        0.4375 ≤ |x| < 11/16 → id = 0,  x' = (2|x|-1)/(2+|x|)
#        11/16 ≤ |x| < 19/16 → id = 1,  x' = (|x|-1)/(|x|+1)
#        19/16 ≤ |x| < 39/16 → id = 2,  x' = (|x|-1.5)/(1+1.5|x|)
#        39/16 ≤ |x| < 2^66  → id = 3,  x' = -1/|x|
#   5. Polynomial (degree 22 in x', split into odd/even sub-series):
#        z = x'², w = z²
#        s1 = z·(aT[0] + w·(aT[2] + w·(aT[4] + w·(aT[6] + w·(aT[8] + w·aT[10])))))
#        s2 = w·(aT[1] + w·(aT[3] + w·(aT[5] + w·(aT[7] + w·aT[9]))))
#   6. Recompose:
#        id = -1: result = x - x·(s1+s2)         (sign preserved via x)
#        id ≥  0: z' = atanhi[id] - (x'·(s1+s2) - atanlo[id] - x')
#                 result = sign ? -z' : z'
#
# Bennett-branchless realisation: ALL FIVE id-paths are computed; ifelse
# selects the right reduced argument and the right (atanhi, atanlo)
# pair. This is the same pattern as `_rp_tan_kernel`'s big/small/odd
# branchless arms. ~5× extra divisions/multiplications vs. the C
# branching version, but constant dispatch cost (load-bearing for
# Bennett's static-CFG model).

# ─────────────────────────────────────────────────────────────────────
# Polynomial coefficients aT[0]..aT[10] (FreeBSD s_atan.c, Sun 1993).
# Approximation of (atan(x) - x) / x³ on [0, 7/16] split into odd/even.
# ─────────────────────────────────────────────────────────────────────
const _ATAN_AT0  = reinterpret(UInt64,  3.33333333333329318027e-01)  # 0x3FD55555_5555550D
const _ATAN_AT1  = reinterpret(UInt64, -1.99999999998764832476e-01)  # 0xBFC99999_9998EBC4
const _ATAN_AT2  = reinterpret(UInt64,  1.42857142725034663711e-01)  # 0x3FC24924_920083FF
const _ATAN_AT3  = reinterpret(UInt64, -1.11111104054623557880e-01)  # 0xBFBC71C6_FE231671
const _ATAN_AT4  = reinterpret(UInt64,  9.09088713343650656196e-02)  # 0x3FB745CD_C54C206E
const _ATAN_AT5  = reinterpret(UInt64, -7.69187620504482999495e-02)  # 0xBFB3B0F2_AF749A6D
const _ATAN_AT6  = reinterpret(UInt64,  6.66107313738753120669e-02)  # 0x3FB10D66_A0D03D51
const _ATAN_AT7  = reinterpret(UInt64, -5.83357013379057348645e-02)  # 0xBFADDE2D_52DEFD9A
const _ATAN_AT8  = reinterpret(UInt64,  4.97687799461593236017e-02)  # 0x3FA97B4B_24760DEB
const _ATAN_AT9  = reinterpret(UInt64, -3.65315727442169155270e-02)  # 0xBFA2B444_2C6A6C2F
const _ATAN_AT10 = reinterpret(UInt64,  1.62858201153657823623e-02)  # 0x3F90AD3A_E322DA11

# ─────────────────────────────────────────────────────────────────────
# atanhi[]/atanlo[]: high/low double-double pair encoding atan(0.5),
# atan(1.0), atan(1.5), atan(∞)=π/2 to ~106 bits. Used for id ≥ 0
# recompose: result = atanhi[id] - (x'·sum - atanlo[id] - x').
# ─────────────────────────────────────────────────────────────────────
const _ATAN_HI_0 = reinterpret(UInt64, 4.63647609000806093515e-01)  # 0x3FDDAC67_0561BB4F  atan(0.5)
const _ATAN_HI_1 = reinterpret(UInt64, 7.85398163397448278999e-01)  # 0x3FE921FB_54442D18  atan(1.0)
const _ATAN_HI_2 = reinterpret(UInt64, 9.82793723247329054082e-01)  # 0x3FEF730B_D281F69B  atan(1.5)
const _ATAN_HI_3 = reinterpret(UInt64, 1.57079632679489655800e+00)  # 0x3FF921FB_54442D18  atan(∞) = π/2

const _ATAN_LO_0 = reinterpret(UInt64, 2.26987774529616870924e-17)  # 0x3C7A2B7F_222F65E2
const _ATAN_LO_1 = reinterpret(UInt64, 3.06161699786838301793e-17)  # 0x3C81A626_33145C07
const _ATAN_LO_2 = reinterpret(UInt64, 1.39033110312309984516e-17)  # 0x3C700788_7AF0CBBD
const _ATAN_LO_3 = reinterpret(UInt64, 6.12323399573676603587e-17)  # 0x3C91A626_33145C07

# Float64 constants for the rational reductions.
const _ATAN_TWO_BITS      = reinterpret(UInt64, 2.0)   # 0x4000000000000000
const _ATAN_ONE_HALF_BITS = reinterpret(UInt64, 1.5)   # 0x3FF8000000000000

# High-word thresholds (matching musl atan.c exactly).
const _ATAN_HUGE_HI    = UInt32(0x44100000)  # |x| ≥ 2^66
const _ATAN_TINY_HI    = UInt32(0x3E400000)  # |x| < 2^-27
const _ATAN_NEG1_HI    = UInt32(0x3FDC0000)  # |x| < 0.4375  → id = -1
const _ATAN_ID0_END_HI = UInt32(0x3FE60000)  # 0.4375 ≤ |x| < 11/16  → id = 0
const _ATAN_ID1_END_HI = UInt32(0x3FF30000)  # 11/16 ≤ |x| < 19/16   → id = 1
const _ATAN_ID2_END_HI = UInt32(0x40038000)  # 19/16 ≤ |x| < 39/16   → id = 2
                                              # 39/16 ≤ |x| < 2^66  → id = 3

"""
    soft_atan(a::UInt64) -> UInt64

IEEE 754 double-precision arctangent `atan(x)` on raw bit patterns.
**≤2 ULP vs `Base.atan`** across the full Float64 input range; bit-
exact vs system libm (`ccall(:atan, ...)`) on Linux.

Special cases:
- atan(NaN)   = NaN  (propagate, force quiet-bit)
- atan(±Inf)  = ±π/2 (via huge-arg fast path, |x| ≥ 2^66)
- atan(±0)    = ±0   (sign-preserving)
- |x| < 2^-27 → x    (bit-exact, matches musl atan.c)

Algorithm: see worklog/057 for the design memo. Faithful port of
musl/FreeBSD `s_atan.c` (Sun 1993, BSD-licensed). All five id-paths
are computed branchlessly; ifelse cascade selects the right reduced
argument and atanhi/atanlo pair. Constant dispatch cost.
"""
@inline function soft_atan(a::UInt64)::UInt64
    SIGN_BIT = UInt64(0x8000000000000000)

    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    a_nan = (ea == UInt64(0x7FF)) & (fa != UInt64(0))

    abs_a = a & ~SIGN_BIT
    sign  = (a & SIGN_BIT) != UInt64(0)
    ix_hi = UInt32(abs_a >> 32)

    # Range dispatch via high word.
    is_huge = ix_hi >= _ATAN_HUGE_HI                    # |x| ≥ 2^66
    is_tiny = ix_hi < _ATAN_TINY_HI                     # |x| < 2^-27
    is_neg1 = ix_hi < _ATAN_NEG1_HI                     # |x| < 0.4375
    use_id0 = ix_hi < _ATAN_ID0_END_HI                  # |x| < 11/16
    use_id1 = ix_hi < _ATAN_ID1_END_HI                  # |x| < 19/16
    use_id2 = ix_hi < _ATAN_ID2_END_HI                  # |x| < 39/16

    # ─── Reduced-argument: select (num, den) branchlessly, then ONE fdiv.
    #
    # Eagerly precomputing four soft_fdiv calls (one per id) is the natural
    # branchless shape, but Julia's LLVM SLP-vectorizer recognises the four
    # parallel divisions and emits `<4 x i64>` vector intrinsics including
    # `llvm.smax.v4i64`, which Bennett's IR walker rejects (vectors.jl:343).
    # Collapsing to a single fdiv on a pre-selected (num, den) pair breaks
    # the SLP pattern. The id=3 sign flip (`-1/|x|`) is folded into the
    # numerator selection (NEG_ONE_BITS) so the final XOR is unnecessary.
    #
    #   id = 0: num = 2|x| - 1,    den = 2 + |x|
    #   id = 1: num = |x| - 1,     den = |x| + 1
    #   id = 2: num = |x| - 1.5,   den = 1 + 1.5·|x|
    #   id = 3: num = -1,          den = |x|

    two_a       = soft_fmul(_ATAN_TWO_BITS, abs_a)
    num_id0     = soft_fsub(two_a, _RP_ONE_BITS)
    num_id1     = soft_fsub(abs_a, _RP_ONE_BITS)
    num_id2     = soft_fsub(abs_a, _ATAN_ONE_HALF_BITS)
    num_id3     = _RP_NEG_ONE_BITS

    den_id0     = soft_fadd(_ATAN_TWO_BITS, abs_a)
    den_id1     = soft_fadd(abs_a, _RP_ONE_BITS)
    one_half_a  = soft_fmul(_ATAN_ONE_HALF_BITS, abs_a)
    den_id2     = soft_fadd(_RP_ONE_BITS, one_half_a)
    den_id3     = abs_a

    num = ifelse(use_id0, num_id0,
          ifelse(use_id1, num_id1,
          ifelse(use_id2, num_id2, num_id3)))
    den = ifelse(use_id0, den_id0,
          ifelse(use_id1, den_id1,
          ifelse(use_id2, den_id2, den_id3)))

    xp_ge0 = soft_fdiv(num, den)

    # For the polynomial, id = -1 uses the original signed `a`; id ≥ 0
    # uses the reduced positive xp_ge0.
    xp = ifelse(is_neg1, a, xp_ge0)

    # ─── Polynomial body (musl's odd/even split) ──────────────────────
    z = soft_fmul(xp, xp)
    w = soft_fmul(z, z)

    # s1 = z·(AT0 + w·(AT2 + w·(AT4 + w·(AT6 + w·(AT8 + w·AT10)))))
    s1 = soft_fmul(w, _ATAN_AT10)
    s1 = soft_fadd(_ATAN_AT8, s1)
    s1 = soft_fmul(w, s1)
    s1 = soft_fadd(_ATAN_AT6, s1)
    s1 = soft_fmul(w, s1)
    s1 = soft_fadd(_ATAN_AT4, s1)
    s1 = soft_fmul(w, s1)
    s1 = soft_fadd(_ATAN_AT2, s1)
    s1 = soft_fmul(w, s1)
    s1 = soft_fadd(_ATAN_AT0, s1)
    s1 = soft_fmul(z, s1)

    # s2 = w·(AT1 + w·(AT3 + w·(AT5 + w·(AT7 + w·AT9))))
    s2 = soft_fmul(w, _ATAN_AT9)
    s2 = soft_fadd(_ATAN_AT7, s2)
    s2 = soft_fmul(w, s2)
    s2 = soft_fadd(_ATAN_AT5, s2)
    s2 = soft_fmul(w, s2)
    s2 = soft_fadd(_ATAN_AT3, s2)
    s2 = soft_fmul(w, s2)
    s2 = soft_fadd(_ATAN_AT1, s2)
    s2 = soft_fmul(w, s2)

    sum = soft_fadd(s1, s2)

    # ─── id = -1 path: result = a - a·sum  (sign preserved via a) ─────
    a_sum         = soft_fmul(a, sum)
    result_neg1   = soft_fsub(a, a_sum)

    # ─── id ≥ 0 path: z' = atanhi[id] - (xp·sum - atanlo[id] - xp) ────
    hi = ifelse(use_id0, _ATAN_HI_0,
         ifelse(use_id1, _ATAN_HI_1,
         ifelse(use_id2, _ATAN_HI_2, _ATAN_HI_3)))
    lo = ifelse(use_id0, _ATAN_LO_0,
         ifelse(use_id1, _ATAN_LO_1,
         ifelse(use_id2, _ATAN_LO_2, _ATAN_LO_3)))

    xp_sum         = soft_fmul(xp_ge0, sum)
    xp_sum_m_lo    = soft_fsub(xp_sum, lo)
    inner          = soft_fsub(xp_sum_m_lo, xp_ge0)
    z_pos          = soft_fsub(hi, inner)
    z_neg          = z_pos ⊻ SIGN_BIT
    result_ge0     = ifelse(sign, z_neg, z_pos)

    # Combine id = -1 vs id ≥ 0.
    result = ifelse(is_neg1, result_neg1, result_ge0)

    # ─── Tiny override: |x| < 2^-27 → return a bit-exact ──────────────
    result = ifelse(is_tiny, a, result)

    # ─── Huge override: |x| ≥ 2^66 → return ±π/2 ──────────────────────
    huge_val = ifelse(sign, _ATAN_HI_3 ⊻ SIGN_BIT, _ATAN_HI_3)
    result   = ifelse(is_huge, huge_val, result)

    # ─── NaN override: propagate NaN with quiet-bit set ───────────────
    result = ifelse(a_nan, a | QUIET_BIT, result)

    return result
end
