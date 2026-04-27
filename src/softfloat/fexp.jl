# IEEE 754 binary64 exp / exp2 on raw bit patterns, branchless integer
# arithmetic. Tang-style range reduction with N=128 lookup table and
# degree-5 minimax polynomial. Faithful port of Arm Optimized Routines
# (musl src/math/exp2.c, exp.c, exp_data.c — Wilhelm/Sibidanov 2018).
#
# Reference accuracy (musl): ≤0.527 ulp on entire normal range.
# Our practical target vs Julia's Base.exp / Base.exp2: ≤2 ulp.
#
# Key trick: the 256-entry table stores
#     T[2j+1] = bits(2^(j/N)) - (j << 45)
#     T[2j]   = low-order extension ("tail") of 2^(j/N)
# so that `T[2j+1] + (ki << 45)` reconstructs the IEEE bits of
# 2^k · 2^(j/N) by integer add, without any float scaling.
# `tail` folds back into the polynomial via `tmp += tail`, recovering
# the precision lost when bits(2^(j/N)) was rounded to 53 bits.

# musl exp_data.c: 128-entry table, two UInt64 per entry (tail, sbits-shift).
# Hardcoded verbatim from https://git.musl-libc.org/cgit/musl/plain/src/math/exp_data.c
# Indexing: for j ∈ 0..127, _EXP_TAB[2j+1] = tail, _EXP_TAB[2j+2] = sbits.
const _EXP_TAB = (
    UInt64(0x0),                  UInt64(0x3ff0000000000000),
    UInt64(0x3c9b3b4f1a88bf6e),   UInt64(0x3feff63da9fb3335),
    UInt64(0xbc7160139cd8dc5d),   UInt64(0x3fefec9a3e778061),
    UInt64(0xbc905e7a108766d1),   UInt64(0x3fefe315e86e7f85),
    UInt64(0x3c8cd2523567f613),   UInt64(0x3fefd9b0d3158574),
    UInt64(0xbc8bce8023f98efa),   UInt64(0x3fefd06b29ddf6de),
    UInt64(0x3c60f74e61e6c861),   UInt64(0x3fefc74518759bc8),
    UInt64(0x3c90a3e45b33d399),   UInt64(0x3fefbe3ecac6f383),
    UInt64(0x3c979aa65d837b6d),   UInt64(0x3fefb5586cf9890f),
    UInt64(0x3c8eb51a92fdeffc),   UInt64(0x3fefac922b7247f7),
    UInt64(0x3c3ebe3d702f9cd1),   UInt64(0x3fefa3ec32d3d1a2),
    UInt64(0xbc6a033489906e0b),   UInt64(0x3fef9b66affed31b),
    UInt64(0xbc9556522a2fbd0e),   UInt64(0x3fef9301d0125b51),
    UInt64(0xbc5080ef8c4eea55),   UInt64(0x3fef8abdc06c31cc),
    UInt64(0xbc91c923b9d5f416),   UInt64(0x3fef829aaea92de0),
    UInt64(0x3c80d3e3e95c55af),   UInt64(0x3fef7a98c8a58e51),
    UInt64(0xbc801b15eaa59348),   UInt64(0x3fef72b83c7d517b),
    UInt64(0xbc8f1ff055de323d),   UInt64(0x3fef6af9388c8dea),
    UInt64(0x3c8b898c3f1353bf),   UInt64(0x3fef635beb6fcb75),
    UInt64(0xbc96d99c7611eb26),   UInt64(0x3fef5be084045cd4),
    UInt64(0x3c9aecf73e3a2f60),   UInt64(0x3fef54873168b9aa),
    UInt64(0xbc8fe782cb86389d),   UInt64(0x3fef4d5022fcd91d),
    UInt64(0x3c8a6f4144a6c38d),   UInt64(0x3fef463b88628cd6),
    UInt64(0x3c807a05b0e4047d),   UInt64(0x3fef3f49917ddc96),
    UInt64(0x3c968efde3a8a894),   UInt64(0x3fef387a6e756238),
    UInt64(0x3c875e18f274487d),   UInt64(0x3fef31ce4fb2a63f),
    UInt64(0x3c80472b981fe7f2),   UInt64(0x3fef2b4565e27cdd),
    UInt64(0xbc96b87b3f71085e),   UInt64(0x3fef24dfe1f56381),
    UInt64(0x3c82f7e16d09ab31),   UInt64(0x3fef1e9df51fdee1),
    UInt64(0xbc3d219b1a6fbffa),   UInt64(0x3fef187fd0dad990),
    UInt64(0x3c8b3782720c0ab4),   UInt64(0x3fef1285a6e4030b),
    UInt64(0x3c6e149289cecb8f),   UInt64(0x3fef0cafa93e2f56),
    UInt64(0x3c834d754db0abb6),   UInt64(0x3fef06fe0a31b715),
    UInt64(0x3c864201e2ac744c),   UInt64(0x3fef0170fc4cd831),
    UInt64(0x3c8fdd395dd3f84a),   UInt64(0x3feefc08b26416ff),
    UInt64(0xbc86a3803b8e5b04),   UInt64(0x3feef6c55f929ff1),
    UInt64(0xbc924aedcc4b5068),   UInt64(0x3feef1a7373aa9cb),
    UInt64(0xbc9907f81b512d8e),   UInt64(0x3feeecae6d05d866),
    UInt64(0xbc71d1e83e9436d2),   UInt64(0x3feee7db34e59ff7),
    UInt64(0xbc991919b3ce1b15),   UInt64(0x3feee32dc313a8e5),
    UInt64(0x3c859f48a72a4c6d),   UInt64(0x3feedea64c123422),
    UInt64(0xbc9312607a28698a),   UInt64(0x3feeda4504ac801c),
    UInt64(0xbc58a78f4817895b),   UInt64(0x3feed60a21f72e2a),
    UInt64(0xbc7c2c9b67499a1b),   UInt64(0x3feed1f5d950a897),
    UInt64(0x3c4363ed60c2ac11),   UInt64(0x3feece086061892d),
    UInt64(0x3c9666093b0664ef),   UInt64(0x3feeca41ed1d0057),
    UInt64(0x3c6ecce1daa10379),   UInt64(0x3feec6a2b5c13cd0),
    UInt64(0x3c93ff8e3f0f1230),   UInt64(0x3feec32af0d7d3de),
    UInt64(0x3c7690cebb7aafb0),   UInt64(0x3feebfdad5362a27),
    UInt64(0x3c931dbdeb54e077),   UInt64(0x3feebcb299fddd0d),
    UInt64(0xbc8f94340071a38e),   UInt64(0x3feeb9b2769d2ca7),
    UInt64(0xbc87deccdc93a349),   UInt64(0x3feeb6daa2cf6642),
    UInt64(0xbc78dec6bd0f385f),   UInt64(0x3feeb42b569d4f82),
    UInt64(0xbc861246ec7b5cf6),   UInt64(0x3feeb1a4ca5d920f),
    UInt64(0x3c93350518fdd78e),   UInt64(0x3feeaf4736b527da),
    UInt64(0x3c7b98b72f8a9b05),   UInt64(0x3feead12d497c7fd),
    UInt64(0x3c9063e1e21c5409),   UInt64(0x3feeab07dd485429),
    UInt64(0x3c34c7855019c6ea),   UInt64(0x3feea9268a5946b7),
    UInt64(0x3c9432e62b64c035),   UInt64(0x3feea76f15ad2148),
    UInt64(0xbc8ce44a6199769f),   UInt64(0x3feea5e1b976dc09),
    UInt64(0xbc8c33c53bef4da8),   UInt64(0x3feea47eb03a5585),
    UInt64(0xbc845378892be9ae),   UInt64(0x3feea34634ccc320),
    UInt64(0xbc93cedd78565858),   UInt64(0x3feea23882552225),
    UInt64(0x3c5710aa807e1964),   UInt64(0x3feea155d44ca973),
    UInt64(0xbc93b3efbf5e2228),   UInt64(0x3feea09e667f3bcd),
    UInt64(0xbc6a12ad8734b982),   UInt64(0x3feea012750bdabf),
    UInt64(0xbc6367efb86da9ee),   UInt64(0x3fee9fb23c651a2f),
    UInt64(0xbc80dc3d54e08851),   UInt64(0x3fee9f7df9519484),
    UInt64(0xbc781f647e5a3ecf),   UInt64(0x3fee9f75e8ec5f74),
    UInt64(0xbc86ee4ac08b7db0),   UInt64(0x3fee9f9a48a58174),
    UInt64(0xbc8619321e55e68a),   UInt64(0x3fee9feb564267c9),
    UInt64(0x3c909ccb5e09d4d3),   UInt64(0x3feea0694fde5d3f),
    UInt64(0xbc7b32dcb94da51d),   UInt64(0x3feea11473eb0187),
    UInt64(0x3c94ecfd5467c06b),   UInt64(0x3feea1ed0130c132),
    UInt64(0x3c65ebe1abd66c55),   UInt64(0x3feea2f336cf4e62),
    UInt64(0xbc88a1c52fb3cf42),   UInt64(0x3feea427543e1a12),
    UInt64(0xbc9369b6f13b3734),   UInt64(0x3feea589994cce13),
    UInt64(0xbc805e843a19ff1e),   UInt64(0x3feea71a4623c7ad),
    UInt64(0xbc94d450d872576e),   UInt64(0x3feea8d99b4492ed),
    UInt64(0x3c90ad675b0e8a00),   UInt64(0x3feeaac7d98a6699),
    UInt64(0x3c8db72fc1f0eab4),   UInt64(0x3feeace5422aa0db),
    UInt64(0xbc65b6609cc5e7ff),   UInt64(0x3feeaf3216b5448c),
    UInt64(0x3c7bf68359f35f44),   UInt64(0x3feeb1ae99157736),
    UInt64(0xbc93091fa71e3d83),   UInt64(0x3feeb45b0b91ffc6),
    UInt64(0xbc5da9b88b6c1e29),   UInt64(0x3feeb737b0cdc5e5),
    UInt64(0xbc6c23f97c90b959),   UInt64(0x3feeba44cbc8520f),
    UInt64(0xbc92434322f4f9aa),   UInt64(0x3feebd829fde4e50),
    UInt64(0xbc85ca6cd7668e4b),   UInt64(0x3feec0f170ca07ba),
    UInt64(0x3c71affc2b91ce27),   UInt64(0x3feec49182a3f090),
    UInt64(0x3c6dd235e10a73bb),   UInt64(0x3feec86319e32323),
    UInt64(0xbc87c50422622263),   UInt64(0x3feecc667b5de565),
    UInt64(0x3c8b1c86e3e231d5),   UInt64(0x3feed09bec4a2d33),
    UInt64(0xbc91bbd1d3bcbb15),   UInt64(0x3feed503b23e255d),
    UInt64(0x3c90cc319cee31d2),   UInt64(0x3feed99e1330b358),
    UInt64(0x3c8469846e735ab3),   UInt64(0x3feede6b5579fdbf),
    UInt64(0xbc82dfcd978e9db4),   UInt64(0x3feee36bbfd3f37a),
    UInt64(0x3c8c1a7792cb3387),   UInt64(0x3feee89f995ad3ad),
    UInt64(0xbc907b8f4ad1d9fa),   UInt64(0x3feeee07298db666),
    UInt64(0xbc55c3d956dcaeba),   UInt64(0x3feef3a2b84f15fb),
    UInt64(0xbc90a40e3da6f640),   UInt64(0x3feef9728de5593a),
    UInt64(0xbc68d6f438ad9334),   UInt64(0x3feeff76f2fb5e47),
    UInt64(0xbc91eee26b588a35),   UInt64(0x3fef05b030a1064a),
    UInt64(0x3c74ffd70a5fddcd),   UInt64(0x3fef0c1e904bc1d2),
    UInt64(0xbc91bdfbfa9298ac),   UInt64(0x3fef12c25bd71e09),
    UInt64(0x3c736eae30af0cb3),   UInt64(0x3fef199bdd85529c),
    UInt64(0x3c8ee3325c9ffd94),   UInt64(0x3fef20ab5fffd07a),
    UInt64(0x3c84e08fd10959ac),   UInt64(0x3fef27f12e57d14b),
    UInt64(0x3c63cdaf384e1a67),   UInt64(0x3fef2f6d9406e7b5),
    UInt64(0x3c676b2c6c921968),   UInt64(0x3fef3720dcef9069),
    UInt64(0xbc808a1883ccb5d2),   UInt64(0x3fef3f0b555dc3fa),
    UInt64(0xbc8fad5d3ffffa6f),   UInt64(0x3fef472d4a07897c),
    UInt64(0xbc900dae3875a949),   UInt64(0x3fef4f87080d89f2),
    UInt64(0x3c74a385a63d07a7),   UInt64(0x3fef5818dcfba487),
    UInt64(0xbc82919e2040220f),   UInt64(0x3fef60e316c98398),
    UInt64(0x3c8e5a50d5c192ac),   UInt64(0x3fef69e603db3285),
    UInt64(0x3c843a59ac016b4b),   UInt64(0x3fef7321f301b460),
    UInt64(0xbc82d52107b43e1f),   UInt64(0x3fef7c97337b9b5f),
    UInt64(0xbc892ab93b470dc9),   UInt64(0x3fef864614f5a129),
    UInt64(0x3c74b604603a88d3),   UInt64(0x3fef902ee78b3ff6),
    UInt64(0x3c83c5ec519d7271),   UInt64(0x3fef9a51fbc74c83),
    UInt64(0xbc8ff7128fd391f0),   UInt64(0x3fefa4afa2a490da),
    UInt64(0xbc8dae98e223747d),   UInt64(0x3fefaf482d8e67f1),
    UInt64(0x3c8ec3bc41aa2008),   UInt64(0x3fefba1bee615a27),
    UInt64(0x3c842b94c3a9eb32),   UInt64(0x3fefc52b376bba97),
    UInt64(0x3c8a64a931d185ee),   UInt64(0x3fefd0765b6e4540),
    UInt64(0xbc8e37bae43be3ed),   UInt64(0x3fefdbfdad9cbe14),
    UInt64(0x3c77893b4d91cd9d),   UInt64(0x3fefe7c1819e90d8),
    UInt64(0x3c5305c14160cc89),   UInt64(0x3feff3c22b8f71f1),
)

# Polynomial coefficients (musl exp_data.c)
const _EXP2_C1 = reinterpret(UInt64, 0x1.62e42fefa39efp-1)   # ln(2)
const _EXP2_C2 = reinterpret(UInt64, 0x1.ebfbdff82c424p-3)   # ln²(2)/2
const _EXP2_C3 = reinterpret(UInt64, 0x1.c6b08d70cf4b5p-5)   # ln³(2)/6
const _EXP2_C4 = reinterpret(UInt64, 0x1.3b2abd24650ccp-7)   # ln⁴(2)/24
const _EXP2_C5 = reinterpret(UInt64, 0x1.5d7e09b4e3a84p-10)  # ln⁵(2)/120

const _EXP_C2  = reinterpret(UInt64, 0x1.ffffffffffdbdp-2)   # 1/2
const _EXP_C3  = reinterpret(UInt64, 0x1.555555555543cp-3)   # 1/6
const _EXP_C4  = reinterpret(UInt64, 0x1.55555cf172b91p-5)   # 1/24
const _EXP_C5  = reinterpret(UInt64, 0x1.1111167a4d017p-7)   # 1/120

# Range-reduction constants
const _EXP2_SHIFT_BITS  = reinterpret(UInt64, 0x1.8p52 / 128.0)  # 1.5·2^45
const _EXP_SHIFT_BITS   = reinterpret(UInt64, 0x1.8p52)
const _INVLN2N_BITS     = reinterpret(UInt64, 0x1.71547652b82fep0 * 128.0)
const _NEGLN2HIN_BITS   = reinterpret(UInt64, -0x1.62e42fefa0000p-8)
const _NEGLN2LON_BITS   = reinterpret(UInt64, -0x1.cf79abc9e3b3ap-47)

const _ONE_BITS  = UInt64(0x3FF0000000000000)
const _NEG_INF   = UInt64(0xFFF0000000000000)
const _TWO_NEG_1022_BITS = UInt64(0x0010000000000000)   # 2^-1022 (smallest positive normal Float64)

# Boundary thresholds — Julia.Base.Math constants (consistent with musl exp.c).
# Used both for special-case dispatch and for the underflow specialcase entry.
const _MAX_EXP_E_BITS  = reinterpret(UInt64,  709.7827128933841)   # log(DBL_MAX); largest finite-output input
const _MIN_EXP_E_BITS  = reinterpret(UInt64, -745.1332191019412)   # log(smallest subnormal); smallest nonzero-output input
const _SUBNORM_E_BITS  = reinterpret(UInt64, -708.3964185322641)   # log(smallest normal); subnormal-output threshold
const _MAX_EXP_2_BITS  = reinterpret(UInt64,  1024.0)              # 2^1024 = +Inf
const _MIN_EXP_2_BITS  = reinterpret(UInt64, -1075.0)              # 2^-1075 → 0
const _SUBNORM_2_BITS  = reinterpret(UInt64, -1022.0)              # 2^-1022 = smallest normal

# Compile-time-constant table lookup. The `let T = _EXP_TAB; T[idx+1]; end`
# pattern is the documented requirement for QROM dispatch — module-level
# const tuples don't inline through to the IR walker. Returns the raw bits
# at index `idx` (1-based after the `+1`).
@inline function _exp_tab_lookup(idx::Int)::UInt64
    let T = _EXP_TAB
        @inbounds T[idx + 1]
    end
end

# ── Underflow specialcase (musl exp.c / exp2.c specialcase()) ─────────────
#
# When the polynomial path would compute scale·(1+tmp) with scale subnormal
# (k < -1022), the integer trick `T[idx+1] + (ki << 45)` overflows the IEEE
# exponent field into the sign bit and produces garbage. musl's fix:
#   1. Bump `sbits` by +1022·2^52 (an integer add — keeps scale in the
#      normal range).
#   2. Compute `y = scale + scale·tmp` in normal-range floating point.
#   3. If `y < 1.0`, recover the bits lost to single-rounding via the
#      (hi, lo) extended-precision reconstruction:
#           lo  = scale - y + scale*tmp
#           hi  = 1 + y
#           lo' = 1 - hi + y + lo
#           y'  = (hi + lo') - 1
#      The rationale: y_under = 1 + tmp_subnormal, where tmp_subnormal ≪ 1.
#      Single-rounded fadd loses ~1 ulp of low bits which would compound
#      after the final 2^-1022 scale-down. The (hi, lo) split captures the
#      lost bits via (hi + lo) = exact-precision (1 + y_under).
#   4. Final `result = 2^-1022 · y'` produces the correctly-rounded
#      subnormal output.
#
# Used by both `soft_exp` and `soft_exp2` — the only difference between
# their underflow handling is the input range that triggers it (set by the
# caller via `ifelse`-select).
@inline function _exp_specialcase_underflow(sbits::UInt64, tmp::UInt64)::UInt64
    # Bump sbits by +1022 biased-exponent steps to keep scale in normal range.
    sbits_b   = sbits + (UInt64(1022) << 52)
    # Same scale + scale*tmp formulation as the main path, but in normal range.
    scale_tmp = soft_fmul(sbits_b, tmp)
    y         = soft_fadd(sbits_b, scale_tmp)

    # Extended-precision (hi, lo) reconstruction for the y < 1.0 case.
    # We always compute the corrected value, then branchless-select.
    diff      = soft_fsub(sbits_b, y)              # scale - y
    lo        = soft_fadd(diff, scale_tmp)         # scale - y + scale*tmp
    hi        = soft_fadd(_ONE_BITS, y)            # 1 + y
    one_m_hi  = soft_fsub(_ONE_BITS, hi)           # 1 - hi
    omh_p_y   = soft_fadd(one_m_hi, y)             # 1 - hi + y
    lo_final  = soft_fadd(omh_p_y, lo)             # 1 - hi + y + lo
    hi_lo     = soft_fadd(hi, lo_final)            # hi + lo'
    y_corr    = soft_fsub(hi_lo, _ONE_BITS)        # (hi + lo') - 1

    # Branchless select: y < 1.0 ? y_corr : y
    y_lt_1    = soft_fcmp_olt(y, _ONE_BITS) != UInt64(0)
    y_final   = ifelse(y_lt_1, y_corr, y)

    # Final scale into subnormal range: result = 2^-1022 · y_final.
    return soft_fmul(_TWO_NEG_1022_BITS, y_final)
end

"""
    soft_exp2(a::UInt64) -> UInt64

IEEE 754 double-precision 2^x on raw bit patterns.
**Bit-exact vs musl/Arm Optimized Routines `exp2.c`** across the entire IEEE
input range (≤0.527 ulp from true math). Branchless integer arithmetic.

# Variants — pick the one that matches your accuracy contract (Bennett-ys0d / U134)

| Function           | Bit-exact vs                  | Notes                          |
|--------------------|-------------------------------|--------------------------------|
| `soft_exp2`        | musl `exp2.c`                 | this function                  |
| `soft_exp2_julia`  | `Base.exp2`                   | use for round-trip with Julia  |
| `soft_exp2_fast`   | musl outside subnormal range  | flushes subnormal output to 0  |

`Base.exp2(::SoftFloat)` routes to `soft_exp2_julia` (Bennett.jl:414).
Direct callers of `soft_exp2` who want `Base.exp2`-bit-exactness should
switch to `soft_exp2_julia`. See `soft_exp` for the matching e^x variants.

Algorithm: Tang-style with N=128 lookup table and degree-5 minimax polynomial
(see Wilhelm/Sibidanov 2018, musl src/math/exp2.c). The integer-fractional
split `x = k/N + r` is *exact* for binary radix (1/N = 2^-7). Underflow
specialcase via `_exp_specialcase_underflow` for x ∈ (-1075, -1022) restores
correct subnormal output.

For applications that don't need bit-exactness in the subnormal-output range
(x ∈ (-1075, -1022)) and prefer the smaller circuit, use `soft_exp2_fast`
(saves ~1.4M gates per call by flushing subnormals to zero).

Special cases (last-write-wins ifelse chain):
- ±0           → 1.0
- |x| < 2^-54  → 1.0
- x ≥ 1024     → +Inf  (overflow)
- x < -1075    → +0    (underflow beyond smallest subnormal)
- +Inf         → +Inf
- -Inf         → +0
- NaN          → NaN
"""
@inline function soft_exp2(a::UInt64)::UInt64
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_pinf = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa == UInt64(0))
    a_ninf = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa != UInt64(0))
    a_zero = (ea == UInt64(0)) & (fa == UInt64(0))
    a_tiny = (ea < UInt64(1023 - 54))

    # x ≥ 1024 → +Inf; x ≤ -1075 → +0; x ∈ (-1075, -1022) → subnormal via specialcase.
    a_overflow      = (sa == UInt64(0)) & (a >= _MAX_EXP_2_BITS)
    a_under_zero    = (sa != UInt64(0)) & (a >  _MIN_EXP_2_BITS)
    in_subnormal    = (sa != UInt64(0)) & (a >  _SUBNORM_2_BITS)

    # ── Range reduction (exact for exp2): x = k/N + r ──
    kd_pre = soft_fadd(a, _EXP2_SHIFT_BITS)
    ki     = kd_pre
    kd     = soft_fsub(kd_pre, _EXP2_SHIFT_BITS)
    r      = soft_fsub(a, kd)

    # ── Table lookup ──
    j_idx     = Int(ki & UInt64(0x7F))
    tail      = _exp_tab_lookup(2 * j_idx)
    sbits_lo  = _exp_tab_lookup(2 * j_idx + 1)
    top       = ki << 45
    sbits     = sbits_lo + top

    # ── Polynomial: tmp = tail + r·C1 + r²·(C2 + r·C3) + r⁴·(C4 + r·C5) ──
    r2     = soft_fmul(r, r)
    rC1    = soft_fmul(r, _EXP2_C1)
    rC3    = soft_fmul(r, _EXP2_C3)
    C2_rC3 = soft_fadd(_EXP2_C2, rC3)
    rC5    = soft_fmul(r, _EXP2_C5)
    C4_rC5 = soft_fadd(_EXP2_C4, rC5)
    q1     = soft_fmul(r2, C2_rC3)
    r4     = soft_fmul(r2, r2)
    q2     = soft_fmul(r4, C4_rC5)
    s1     = soft_fadd(tail, rC1)
    s2     = soft_fadd(s1, q1)
    tmp    = soft_fadd(s2, q2)

    # Main path (correct for x ∈ [-1022, 1024)).
    scale_tmp = soft_fmul(sbits, tmp)
    normal    = soft_fadd(sbits, scale_tmp)

    # Underflow specialcase (always computed; selected below).
    under     = _exp_specialcase_underflow(sbits, tmp)

    # ── Branchless override chain (last-write-wins) ──
    result = normal
    result = ifelse(in_subnormal, under,     result)
    result = ifelse(a_tiny,       _ONE_BITS, result)
    result = ifelse(a_zero,       _ONE_BITS, result)
    result = ifelse(a_overflow,   INF_BITS,  result)
    result = ifelse(a_under_zero, UInt64(0), result)
    result = ifelse(a_pinf,       INF_BITS,  result)
    result = ifelse(a_ninf,       UInt64(0), result)
    result = ifelse(a_nan,        a | QNAN,  result)
    return result
end

"""
    soft_exp(a::UInt64) -> UInt64

IEEE 754 double-precision e^x on raw bit patterns.
**Bit-exact vs musl/Arm Optimized Routines `exp.c`** across the entire IEEE
input range (≤0.527 ulp from true math). Branchless integer arithmetic.

# Variants — pick the one that matches your accuracy contract (Bennett-ys0d / U134)

| Function           | Bit-exact vs                | Notes                         |
|--------------------|-----------------------------|-------------------------------|
| `soft_exp`         | musl `exp.c` (~0.9% off vs `Base.exp` by 1 ulp) | this function |
| `soft_exp_julia`   | `Base.exp`                  | use for round-trip with Julia |
| `soft_exp_fast`    | musl outside subnormal range | flushes subnormal output to 0 |

**Default routing for SoftFloat:** `Base.exp(::SoftFloat)` is wired to
`soft_exp_julia` (Bennett.jl:413), so user code calling `Base.exp` on a
`SoftFloat` gets bit-exact-vs-Base.exp results automatically. Direct callers
of `soft_exp` who want `Base.exp`-bit-exactness should switch to
`soft_exp_julia`. The empirical disagreement rate (50k random samples in
[-30, 30]) is pinned at ~0.9% by `test/test_ys0d_exp_accuracy_contract.jl`.

Algorithm: Tang-style with N=128 lookup table, degree-5 minimax polynomial,
and Cody-Waite range reduction `r = x − k·(ln2/N)` with `ln2/N` split as
hi+lo for accuracy at large |x|. Underflow specialcase via
`_exp_specialcase_underflow` for x ∈ (MIN_EXP_E, SUBNORM_E) =
(-745.13, -708.40) restores correct subnormal output.

For the smaller circuit without subnormal-range bit-exactness, use
`soft_exp_fast` (saves ~1.4M gates by flushing subnormals to zero).

Special cases:
- ±0           → 1.0
- |x| < 2^-54  → 1.0
- x > 709.78   → +Inf  (overflow)
- x < -745.13  → +0    (underflow beyond smallest subnormal)
- +Inf         → +Inf
- -Inf         → +0
- NaN          → NaN
"""
@inline function soft_exp(a::UInt64)::UInt64
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_pinf = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa == UInt64(0))
    a_ninf = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa != UInt64(0))
    a_zero = (ea == UInt64(0)) & (fa == UInt64(0))
    a_tiny = (ea < UInt64(1023 - 54))

    # Tightened thresholds (vs musl uses; matches Julia.Base.Math constants).
    a_overflow   = (sa == UInt64(0)) & (a >  _MAX_EXP_E_BITS)
    a_under_zero = (sa != UInt64(0)) & (a >  _MIN_EXP_E_BITS)
    in_subnormal = (sa != UInt64(0)) & (a >  _SUBNORM_E_BITS)

    # ── Range reduction: x = k·(ln2/N) + r, N = 128 ──
    z      = soft_fmul(a, _INVLN2N_BITS)
    kd_pre = soft_fadd(z, _EXP_SHIFT_BITS)
    ki     = kd_pre
    kd     = soft_fsub(kd_pre, _EXP_SHIFT_BITS)
    t1     = soft_fmul(kd, _NEGLN2HIN_BITS)
    r_hi   = soft_fadd(a, t1)
    t2     = soft_fmul(kd, _NEGLN2LON_BITS)
    r      = soft_fadd(r_hi, t2)

    # ── Table lookup ──
    j_idx     = Int(ki & UInt64(0x7F))
    tail      = _exp_tab_lookup(2 * j_idx)
    sbits_lo  = _exp_tab_lookup(2 * j_idx + 1)
    top       = ki << 45
    sbits     = sbits_lo + top

    # ── Polynomial: tmp = tail + r + r²·(C2 + r·C3) + r⁴·(C4 + r·C5) ──
    r2     = soft_fmul(r, r)
    rC3    = soft_fmul(r, _EXP_C3)
    C2_rC3 = soft_fadd(_EXP_C2, rC3)
    rC5    = soft_fmul(r, _EXP_C5)
    C4_rC5 = soft_fadd(_EXP_C4, rC5)
    q1     = soft_fmul(r2, C2_rC3)
    r4     = soft_fmul(r2, r2)
    q2     = soft_fmul(r4, C4_rC5)
    tail_r = soft_fadd(tail, r)
    s2     = soft_fadd(tail_r, q1)
    tmp    = soft_fadd(s2, q2)

    # Main path + underflow specialcase (always both computed).
    scale_tmp = soft_fmul(sbits, tmp)
    normal    = soft_fadd(sbits, scale_tmp)
    under     = _exp_specialcase_underflow(sbits, tmp)

    result = normal
    result = ifelse(in_subnormal, under,     result)
    result = ifelse(a_tiny,       _ONE_BITS, result)
    result = ifelse(a_zero,       _ONE_BITS, result)
    result = ifelse(a_overflow,   INF_BITS,  result)
    result = ifelse(a_under_zero, UInt64(0), result)
    result = ifelse(a_pinf,       INF_BITS,  result)
    result = ifelse(a_ninf,       UInt64(0), result)
    result = ifelse(a_nan,        a | QNAN,  result)
    return result
end

# ── Fast variants (no specialcase; flush subnormal output to zero) ────────
#
# Identical to `soft_exp` / `soft_exp2` but skip the underflow specialcase
# branch. ~1.4M gates cheaper per call. Returns 0 for inputs in the
# subnormal-output range:
#   * `soft_exp_fast`:  x ∈ [-745.13, -708.40] → 0  (Julia returns subnormal)
#   * `soft_exp2_fast`: x ∈ [-1075, -1022)     → 0  (Julia returns subnormal)
# All other inputs produce bit-exact (or ≤1 ulp vs musl) output.

"""
    soft_exp2_fast(a::UInt64) -> UInt64

Fast variant of `soft_exp2` that flushes subnormal-output range to zero
(x ∈ [-1075, -1022) → 0). ~1.4M gates cheaper per reversible compile.
Bit-exact vs `soft_exp2` everywhere outside the subnormal range.

Use when subnormal-range exactness isn't required (most numerical work).
For full bit-exactness vs musl, use `soft_exp2`.
"""
@inline function soft_exp2_fast(a::UInt64)::UInt64
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_pinf = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa == UInt64(0))
    a_ninf = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa != UInt64(0))
    a_zero = (ea == UInt64(0)) & (fa == UInt64(0))
    a_tiny = (ea < UInt64(1023 - 54))

    # Tightened to flush the entire subnormal-output range to zero.
    a_overflow  = (sa == UInt64(0)) & (a >= _MAX_EXP_2_BITS)
    a_underflow = (sa != UInt64(0)) & (a >  _SUBNORM_2_BITS)

    kd_pre = soft_fadd(a, _EXP2_SHIFT_BITS)
    ki     = kd_pre
    kd     = soft_fsub(kd_pre, _EXP2_SHIFT_BITS)
    r      = soft_fsub(a, kd)

    j_idx     = Int(ki & UInt64(0x7F))
    tail      = _exp_tab_lookup(2 * j_idx)
    sbits_lo  = _exp_tab_lookup(2 * j_idx + 1)
    top       = ki << 45
    sbits     = sbits_lo + top

    r2     = soft_fmul(r, r)
    rC1    = soft_fmul(r, _EXP2_C1)
    rC3    = soft_fmul(r, _EXP2_C3)
    C2_rC3 = soft_fadd(_EXP2_C2, rC3)
    rC5    = soft_fmul(r, _EXP2_C5)
    C4_rC5 = soft_fadd(_EXP2_C4, rC5)
    q1     = soft_fmul(r2, C2_rC3)
    r4     = soft_fmul(r2, r2)
    q2     = soft_fmul(r4, C4_rC5)
    s1     = soft_fadd(tail, rC1)
    s2     = soft_fadd(s1, q1)
    tmp    = soft_fadd(s2, q2)

    scale_tmp = soft_fmul(sbits, tmp)
    normal    = soft_fadd(sbits, scale_tmp)

    result = normal
    result = ifelse(a_tiny,      _ONE_BITS, result)
    result = ifelse(a_zero,      _ONE_BITS, result)
    result = ifelse(a_overflow,  INF_BITS,  result)
    result = ifelse(a_underflow, UInt64(0), result)
    result = ifelse(a_pinf,      INF_BITS,  result)
    result = ifelse(a_ninf,      UInt64(0), result)
    result = ifelse(a_nan,       a | QNAN,  result)
    return result
end

"""
    soft_exp_fast(a::UInt64) -> UInt64

Fast variant of `soft_exp` that flushes subnormal-output range to zero
(x ∈ [-745.13, -708.40] → 0). ~1.4M gates cheaper per reversible compile.
Bit-exact vs `soft_exp` everywhere outside the subnormal range.

Use when subnormal-range exactness isn't required. For full bit-exactness
vs musl (including subnormal output), use `soft_exp`.
"""
@inline function soft_exp_fast(a::UInt64)::UInt64
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK
    a_nan  = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_pinf = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa == UInt64(0))
    a_ninf = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa != UInt64(0))
    a_zero = (ea == UInt64(0)) & (fa == UInt64(0))
    a_tiny = (ea < UInt64(1023 - 54))

    a_overflow  = (sa == UInt64(0)) & (a >  _MAX_EXP_E_BITS)
    a_underflow = (sa != UInt64(0)) & (a >  _SUBNORM_E_BITS)

    z      = soft_fmul(a, _INVLN2N_BITS)
    kd_pre = soft_fadd(z, _EXP_SHIFT_BITS)
    ki     = kd_pre
    kd     = soft_fsub(kd_pre, _EXP_SHIFT_BITS)
    t1     = soft_fmul(kd, _NEGLN2HIN_BITS)
    r_hi   = soft_fadd(a, t1)
    t2     = soft_fmul(kd, _NEGLN2LON_BITS)
    r      = soft_fadd(r_hi, t2)

    j_idx     = Int(ki & UInt64(0x7F))
    tail      = _exp_tab_lookup(2 * j_idx)
    sbits_lo  = _exp_tab_lookup(2 * j_idx + 1)
    top       = ki << 45
    sbits     = sbits_lo + top

    r2     = soft_fmul(r, r)
    rC3    = soft_fmul(r, _EXP_C3)
    C2_rC3 = soft_fadd(_EXP_C2, rC3)
    rC5    = soft_fmul(r, _EXP_C5)
    C4_rC5 = soft_fadd(_EXP_C4, rC5)
    q1     = soft_fmul(r2, C2_rC3)
    r4     = soft_fmul(r2, r2)
    q2     = soft_fmul(r4, C4_rC5)
    tail_r = soft_fadd(tail, r)
    s2     = soft_fadd(tail_r, q1)
    tmp    = soft_fadd(s2, q2)

    scale_tmp = soft_fmul(sbits, tmp)
    normal    = soft_fadd(sbits, scale_tmp)

    result = normal
    result = ifelse(a_tiny,      _ONE_BITS, result)
    result = ifelse(a_zero,      _ONE_BITS, result)
    result = ifelse(a_overflow,  INF_BITS,  result)
    result = ifelse(a_underflow, UInt64(0), result)
    result = ifelse(a_pinf,      INF_BITS,  result)
    result = ifelse(a_ninf,      UInt64(0), result)
    result = ifelse(a_nan,       a | QNAN,  result)
    return result
end
