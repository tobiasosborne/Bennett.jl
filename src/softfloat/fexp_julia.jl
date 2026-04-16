"""
    soft_exp_julia(a::UInt64) -> UInt64
    soft_exp2_julia(a::UInt64) -> UInt64

Julia-faithful IEEE 754 binary64 `exp` and `exp2` on raw bit patterns.
Bit-exact vs `Base.exp` / `Base.exp2` on FMA-capable hardware. Line-for-
line port of `Base.Math.exp_impl` from `base/special/exp.jl` with every
`muladd` replaced by `soft_fma`.

Differs from `soft_exp` (bit-exact vs musl AOR) and `soft_exp_fast`
(same but skipping subnormal specialcase) by using Julia's Tang-style
Cody-Waite reduction with a 256-entry table and degree-3 polynomial
(vs musl's 128-entry table, degree-5 polynomial).

This closes the ≤1 ulp gap between `soft_exp` and `Base.exp` that Plan B
(Bennett-wigl) left open: musl uses separate fmul+fadd in range
reduction while Julia uses FMA-based muladd, producing different
intermediate `r` values at round-half cases.

See `base/special/exp.jl` lines 125-175 (J_TABLE), 207-231 (exp_impl).
"""

# ── Julia J_TABLE — verbatim copy from base/special/exp.jl ──────────────
# 256-entry table: for j ∈ 0..255,
#   jU = JU_CONST | (J_TABLE[j+1] & JU_MASK)    # upper part of 2^(j/256)
#   jL = JL_CONST | (J_TABLE[j+1] >> 8)         # lower compensation
# Packs 60 sig figs per entry by exploiting that the first 12 exp bits
# are identical across all entries and the small-part exponent spans
# only ~4 bits.
const _JL_J_TABLE = (0x0000000000000000, 0xaac00b1afa5abcbe, 0x9b60163da9fb3335, 0xab502168143b0280, 0xadc02c9a3e778060,
                     0x656037d42e11bbcc, 0xa7a04315e86e7f84, 0x84c04e5f72f654b1, 0x8d7059b0d3158574, 0xa510650a0e3c1f88,
                     0xa8d0706b29ddf6dd, 0x83207bd42b72a836, 0x6180874518759bc8, 0xa4b092bdf66607df, 0x91409e3ecac6f383,
                     0x85d0a9c79b1f3919, 0x98a0b5586cf9890f, 0x94f0c0f145e46c85, 0x9010cc922b7247f7, 0xa210d83b23395deb,
                     0x4030e3ec32d3d1a2, 0xa5b0efa55fdfa9c4, 0xae40fb66affed31a, 0x8d41073028d7233e, 0xa4911301d0125b50,
                     0xa1a11edbab5e2ab5, 0xaf712abdc06c31cb, 0xae8136a814f204aa, 0xa661429aaea92ddf, 0xa9114e95934f312d,
                     0x82415a98c8a58e51, 0x58f166a45471c3c2, 0xab9172b83c7d517a, 0x70917ed48695bbc0, 0xa7718af9388c8de9,
                     0x94a1972658375d2f, 0x8e51a35beb6fcb75, 0x97b1af99f8138a1c, 0xa351bbe084045cd3, 0x9001c82f95281c6b,
                     0x9e01d4873168b9aa, 0xa481e0e75eb44026, 0xa711ed5022fcd91c, 0xa201f9c18438ce4c, 0x8dc2063b88628cd6,
                     0x935212be3578a819, 0x82a21f49917ddc96, 0x8d322bdda27912d1, 0x99b2387a6e756238, 0x8ac2451ffb82140a,
                     0x8ac251ce4fb2a63f, 0x93e25e85711ece75, 0x82b26b4565e27cdd, 0x9e02780e341ddf29, 0xa2d284dfe1f56380,
                     0xab4291ba7591bb6f, 0x86129e9df51fdee1, 0xa352ab8a66d10f12, 0xafb2b87fd0dad98f, 0xa572c57e39771b2e,
                     0x9002d285a6e4030b, 0x9d12df961f641589, 0x71c2ecafa93e2f56, 0xaea2f9d24abd886a, 0x86f306fe0a31b715,
                     0x89531432edeeb2fd, 0x8a932170fc4cd831, 0xa1d32eb83ba8ea31, 0x93233c08b26416ff, 0xab23496266e3fa2c,
                     0xa92356c55f929ff0, 0xa8f36431a2de883a, 0xa4e371a7373aa9ca, 0xa3037f26231e7549, 0xa0b38cae6d05d865,
                     0xa3239a401b7140ee, 0xad43a7db34e59ff6, 0x9543b57fbfec6cf4, 0xa083c32dc313a8e4, 0x7fe3d0e544ede173,
                     0x8ad3dea64c123422, 0xa943ec70df1c5174, 0xa413fa4504ac801b, 0x8bd40822c367a024, 0xaf04160a21f72e29,
                     0xa3d423fb27094689, 0xab8431f5d950a896, 0x88843ffa3f84b9d4, 0x48944e086061892d, 0xae745c2042a7d231,
                     0x9c946a41ed1d0057, 0xa1e4786d668b3236, 0x73c486a2b5c13cd0, 0xab1494e1e192aed1, 0x99c4a32af0d7d3de,
                     0xabb4b17dea6db7d6, 0x7d44bfdad5362a27, 0x9054ce41b817c114, 0x98e4dcb299fddd0d, 0xa564eb2d81d8abfe,
                     0xa5a4f9b2769d2ca6, 0x7a2508417f4531ee, 0xa82516daa2cf6641, 0xac65257de83f4eee, 0xabe5342b569d4f81,
                     0x879542e2f4f6ad27, 0xa8a551a4ca5d920e, 0xa7856070dde910d1, 0x99b56f4736b527da, 0xa7a57e27dbe2c4ce,
                     0x82958d12d497c7fd, 0xa4059c0827ff07cb, 0x9635ab07dd485429, 0xa245ba11fba87a02, 0x3c45c9268a5946b7,
                     0xa195d84590998b92, 0x9ba5e76f15ad2148, 0xa985f6a320dceb70, 0xa60605e1b976dc08, 0x9e46152ae6cdf6f4,
                     0xa636247eb03a5584, 0x984633dd1d1929fd, 0xa8e6434634ccc31f, 0xa28652b9febc8fb6, 0xa226623882552224,
                     0xa85671c1c70833f5, 0x60368155d44ca973, 0x880690f4b19e9538, 0xa216a09e667f3bcc, 0x7a36b052fa75173e,
                     0xada6c012750bdabe, 0x9c76cfdcddd47645, 0xae46dfb23c651a2e, 0xa7a6ef9298593ae4, 0xa9f6ff7df9519483,
                     0x59d70f7466f42e87, 0xaba71f75e8ec5f73, 0xa6f72f8286ead089, 0xa7a73f9a48a58173, 0x90474fbd35d7cbfd,
                     0xa7e75feb564267c8, 0x9b777024b1ab6e09, 0x986780694fde5d3f, 0x934790b938ac1cf6, 0xaaf7a11473eb0186,
                     0xa207b17b0976cfda, 0x9f17c1ed0130c132, 0x91b7d26a62ff86f0, 0x7057e2f336cf4e62, 0xabe7f3878491c490,
                     0xa6c80427543e1a11, 0x946814d2add106d9, 0xa1582589994cce12, 0x9998364c1eb941f7, 0xa9c8471a4623c7ac,
                     0xaf2857f4179f5b20, 0xa01868d99b4492ec, 0x85d879cad931a436, 0x99988ac7d98a6699, 0x9d589bd0a478580f,
                     0x96e8ace5422aa0db, 0x9ec8be05bad61778, 0xade8cf3216b5448b, 0xa478e06a5e0866d8, 0x85c8f1ae99157736,
                     0x959902fed0282c8a, 0xa119145b0b91ffc5, 0xab2925c353aa2fe1, 0xae893737b0cdc5e4, 0xa88948b82b5f98e4,
                     0xad395a44cbc8520e, 0xaf296bdd9a7670b2, 0xa1797d829fde4e4f, 0x7ca98f33e47a22a2, 0xa749a0f170ca07b9,
                     0xa119b2bb4d53fe0c, 0x7c79c49182a3f090, 0xa579d674194bb8d4, 0x7829e86319e32323, 0xaad9fa5e8d07f29d,
                     0xa65a0c667b5de564, 0x9c6a1e7aed8eb8bb, 0x963a309bec4a2d33, 0xa2aa42c980460ad7, 0xa16a5503b23e255c,
                     0x650a674a8af46052, 0x9bca799e1330b358, 0xa58a8bfe53c12e58, 0x90fa9e6b5579fdbf, 0x889ab0e521356eba,
                     0xa81ac36bbfd3f379, 0x97ead5ff3a3c2774, 0x97aae89f995ad3ad, 0xa5aafb4ce622f2fe, 0xa21b0e07298db665,
                     0x94db20ce6c9a8952, 0xaedb33a2b84f15fa, 0xac1b468415b749b0, 0xa1cb59728de55939, 0x92ab6c6e29f1c52a,
                     0xad5b7f76f2fb5e46, 0xa24b928cf22749e3, 0xa08ba5b030a10649, 0xafcbb8e0b79a6f1e, 0x823bcc1e904bc1d2,
                     0xafcbdf69c3f3a206, 0xa08bf2c25bd71e08, 0xa89c06286141b33c, 0x811c199bdd85529c, 0xa48c2d1cd9fa652b,
                     0x9b4c40ab5fffd07a, 0x912c544778fafb22, 0x928c67f12e57d14b, 0xa86c7ba88988c932, 0x71ac8f6d9406e7b5,
                     0xaa0ca3405751c4da, 0x750cb720dcef9069, 0xac5ccb0f2e6d1674, 0xa88cdf0b555dc3f9, 0xa2fcf3155b5bab73,
                     0xa1ad072d4a07897b, 0x955d1b532b08c968, 0xa15d2f87080d89f1, 0x93dd43c8eacaa1d6, 0x82ed5818dcfba487,
                     0x5fed6c76e862e6d3, 0xa77d80e316c98397, 0x9a0d955d71ff6075, 0x9c2da9e603db3285, 0xa24dbe7cd63a8314,
                     0x92ddd321f301b460, 0xa1ade7d5641c0657, 0xa72dfc97337b9b5e, 0xadae11676b197d16, 0xa42e264614f5a128,
                     0xa30e3b333b16ee11, 0x839e502ee78b3ff6, 0xaa7e653924676d75, 0x92de7a51fbc74c83, 0xa77e8f7977cdb73f,
                     0xa0bea4afa2a490d9, 0x948eb9f4867cca6e, 0xa1becf482d8e67f0, 0x91cee4aaa2188510, 0x9dcefa1bee615a27,
                     0xa66f0f9c1cb64129, 0x93af252b376bba97, 0xacdf3ac948dd7273, 0x99df50765b6e4540, 0x9faf6632798844f8,
                     0xa12f7bfdad9cbe13, 0xaeef91d802243c88, 0x874fa7c1819e90d8, 0xacdfbdba3692d513, 0x62efd3c22b8f71f1, 0x74afe9d96b2a23d9)

const _JL_JU_MASK   = UInt64(0x000F_FFFF_FFFF_FFFF)   # typemax(UInt64) >> 12
const _JL_JL_MASK   = UInt64(0x00FF_FFFF_FFFF_FFFF)   # typemax(UInt64) >> 8  (unused; shift >> 8 already masks)
const _JL_JU_CONST  = UInt64(0x3FF0_0000_0000_0000)
const _JL_JL_CONST  = UInt64(0x3C00_0000_0000_0000)

# ── Constants: Val(:ℯ) base ─────────────────────────────────────────────
const _LOGBO256INV_E_BITS  = reinterpret(UInt64, 369.3299304675746)
const _LOGBO256U_E_BITS    = reinterpret(UInt64, -0.002707606173999011)
const _LOGBO256L_E_BITS    = reinterpret(UInt64, -6.327543041662719e-14)
const _MAX_EXP_E_BITS      = reinterpret(UInt64, 709.7827128933841)
const _MIN_EXP_E_BITS      = reinterpret(UInt64, -745.1332191019412)
const _SUBNORM_EXP_E_BITS  = reinterpret(UInt64, 708.3964185322641)
const _ABS_MIN_EXP_E_BITS  = reinterpret(UInt64, 745.1332191019412)

# expm1b_kernel(Val(:ℯ), x) polynomial coefficients
const _EXPM1B_E_C0_BITS    = reinterpret(UInt64, 0.9999999999999912)
const _EXPM1B_E_C1_BITS    = reinterpret(UInt64, 0.4999999999999997)
const _EXPM1B_E_C2_BITS    = reinterpret(UInt64, 0.1666666857598779)
const _EXPM1B_E_C3_BITS    = reinterpret(UInt64, 0.04166666857598777)

# ── Constants: Val(2) base ──────────────────────────────────────────────
const _LOGBO256INV_2_BITS  = reinterpret(UInt64, 256.0)
const _LOGBO256U_2_BITS    = reinterpret(UInt64, -0.00390625)
const _LOGBO256L_2_BITS    = reinterpret(UInt64, 0.0)
const _MAX_EXP_2_BITS      = reinterpret(UInt64, 1024.0)
const _MIN_EXP_2_BITS      = reinterpret(UInt64, -1075.0)
const _SUBNORM_EXP_2_BITS  = reinterpret(UInt64, 1022.0)
const _ABS_MIN_EXP_2_BITS  = reinterpret(UInt64, 1075.0)

# expm1b_kernel(Val(2), x) polynomial coefficients
const _EXPM1B_2_C0_BITS    = reinterpret(UInt64, 0.6931471805599393)
const _EXPM1B_2_C1_BITS    = reinterpret(UInt64, 0.24022650695910058)
const _EXPM1B_2_C2_BITS    = reinterpret(UInt64, 0.05550411502333161)
const _EXPM1B_2_C3_BITS    = reinterpret(UInt64, 0.009618129548366803)

# ── Shared constants ────────────────────────────────────────────────────
const _MAGIC_ROUND_CONST_BITS = reinterpret(UInt64, 6.755399441055744e15)   # 1.5 * 2^52
const _TWO_POW_NEG_53_BITS    = reinterpret(UInt64, 0x1p-53)
const _F64_INF_BITS_JL        = UInt64(0x7FF0_0000_0000_0000)
const _F64_SIGN_MASK_JL       = UInt64(0x8000_0000_0000_0000)

"""
    _exp_impl_julia(a, LOGBO256INV, LOGBO256U, LOGBO256L, SUBNORM, ABS_MIN, MAX, C0, C1, C2, C3) -> UInt64

Shared core for soft_exp_julia and soft_exp2_julia. Parameterized on the
base constants (log_b(2)/256 in two parts, subnormal/max/min thresholds,
and polynomial coefficients). Follows `Base.Math.exp_impl` line-for-line
with muladds → soft_fma.
"""
@inline function _exp_impl_julia(a::UInt64,
                                 LOGBO256INV::UInt64, LOGBO256U::UInt64, LOGBO256L::UInt64,
                                 SUBNORM::UInt64, ABS_MIN::UInt64, MAX::UInt64,
                                 C0::UInt64, C1::UInt64, C2::UInt64, C3::UInt64)
    # Step 1: N_float = muladd(x, LOGBO256INV, MAGIC)
    N_float = soft_fma(a, LOGBO256INV, _MAGIC_ROUND_CONST_BITS)

    # Step 2: N = reinterpret(UInt64, N_float) % Int32
    N_u = N_float & UInt64(0xFFFFFFFF)
    N_i32 = reinterpret(Int32, UInt32(N_u))
    N_i64 = Int64(N_i32)

    # Step 3: N_float -= MAGIC
    N_float = soft_fsub(N_float, _MAGIC_ROUND_CONST_BITS)

    # Step 4-5: r = muladd(N_float, LOGBO256L, muladd(N_float, LOGBO256U, x))
    r = soft_fma(N_float, LOGBO256U, a)
    r = soft_fma(N_float, LOGBO256L, r)

    # Step 6: k = N >> 8
    k = N_i64 >> 8

    # Step 7: table_unpack — ind = (N & 255) + 1 (1-indexed)
    ind = Int((N_u & UInt64(0xFF)) + UInt64(1))
    j   = getfield(_JL_J_TABLE, ind)
    jU  = _JL_JU_CONST | (j & _JL_JU_MASK)
    jL  = _JL_JL_CONST | (j >> 8)

    # Step 8: kern = r * evalpoly(r, (C0, C1, C2, C3))
    # evalpoly Horner: muladd(r, muladd(r, muladd(r, C3, C2), C1), C0)
    p   = soft_fma(r, C3, C2)     # r*C3 + C2
    p   = soft_fma(r, p,  C1)     # r*p  + C1
    p   = soft_fma(r, p,  C0)     # r*p  + C0
    kern = soft_fmul(r, p)        # outer x*

    # Step 9: small_part = muladd(jU, kern, jL) + jU
    sp  = soft_fma(jU, kern, jL)
    small_part = soft_fadd(sp, jU)

    # Step 10: normal path — twopk + small_part as bit-pattern add
    twopk_bits_normal = reinterpret(UInt64, Int64(k) << 52)
    normal_result     = small_part + twopk_bits_normal

    # Step 11: subnormal path — (k+53)<<52 + small_part, then * 2^-53
    twopk_bits_sub    = reinterpret(UInt64, (Int64(k) + Int64(53)) << 52)
    sub_bits          = small_part + twopk_bits_sub
    subnormal_result  = soft_fmul(sub_bits, _TWO_POW_NEG_53_BITS)

    # Step 12: predicates for edge cases
    abs_a    = a & ~_F64_SIGN_MASK_JL
    is_nan   = abs_a > _F64_INF_BITS_JL     # any NaN bit pattern
    sign_bit = (a >> 63) & UInt64(1)
    a_positive = sign_bit == UInt64(0)

    # x >= MAX: bit-pattern compare on positive floats (monotonic)
    too_big   = !is_nan & a_positive & (a >= MAX)
    # x <= MIN: on negative floats, |x| >= |MIN| means bit-abs >= bit-abs(MIN)
    too_small = !is_nan & !a_positive & (abs_a >= ABS_MIN)
    # abs(x) > SUBNORM_EXP → outside normal range
    out_of_normal = abs_a > SUBNORM
    # k <= -53 → subnormal-output path
    k_tiny = k <= Int64(-53)

    # Step 13: final select chain (last-write-wins priority)
    result = normal_result
    result = ifelse(out_of_normal & k_tiny, subnormal_result, result)
    result = ifelse(too_small, UInt64(0), result)            # 0
    result = ifelse(too_big, _F64_INF_BITS_JL, result)       # +Inf
    result = ifelse(is_nan, a, result)                        # NaN pass-through
    return result
end

"""
    soft_exp_julia(a::UInt64) -> UInt64

Natural base exponential, bit-exact vs `Base.exp` on FMA hardware.
"""
@inline function soft_exp_julia(a::UInt64)::UInt64
    return _exp_impl_julia(a,
        _LOGBO256INV_E_BITS, _LOGBO256U_E_BITS, _LOGBO256L_E_BITS,
        _SUBNORM_EXP_E_BITS, _ABS_MIN_EXP_E_BITS, _MAX_EXP_E_BITS,
        _EXPM1B_E_C0_BITS, _EXPM1B_E_C1_BITS, _EXPM1B_E_C2_BITS, _EXPM1B_E_C3_BITS)
end

"""
    soft_exp2_julia(a::UInt64) -> UInt64

Base-2 exponential, bit-exact vs `Base.exp2` on FMA hardware.
"""
@inline function soft_exp2_julia(a::UInt64)::UInt64
    return _exp_impl_julia(a,
        _LOGBO256INV_2_BITS, _LOGBO256U_2_BITS, _LOGBO256L_2_BITS,
        _SUBNORM_EXP_2_BITS, _ABS_MIN_EXP_2_BITS, _MAX_EXP_2_BITS,
        _EXPM1B_2_C0_BITS, _EXPM1B_2_C1_BITS, _EXPM1B_2_C2_BITS, _EXPM1B_2_C3_BITS)
end
