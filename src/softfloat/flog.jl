# IEEE 754 binary64 natural logarithm on raw bit patterns. Branchless
# integer arithmetic for special-case dispatch + soft_f* primitives for the
# polynomial body. Faithful port of Arm Optimized Routines / musl
# `src/math/log.c` + `log_data.c` (Wilhelm/Sibidanov 2018, MIT-licensed).
#
# Reference accuracy (Arm/musl): worst-case 0.5 + 4.13/N ULP ≈ 0.532 ULP for
# the main path with N=128, LOG_POLY_ORDER=6. Bennett-jl practical target vs
# `Base.log`: ≤2 ULP.
#
# Algorithm:
#   1. Decompose x = 2^k · z where z ∈ [OFF, 2·OFF), OFF = 0x3FE6000000000000
#      (≈0.6875). Subnormals are pre-normalized by counting leading zeros.
#   2. Index i = top 7 bits of (ix - OFF)'s mantissa region. Look up
#      (1/c_i, log(c_i)) from a 128-entry table.
#   3. r = z · (1/c_i) - 1, computed as `soft_fma(z, invc, -1.0)` so r is
#      tiny (|r| < 1/256) and the high bits cancel exactly.
#   4. Reconstruct: log(x) = k·ln(2) + log(c_i) + log1p(r), with log1p
#      expanded as a degree-6 minimax polynomial in r and the
#      catastrophic-cancellation hazard in `k·ln2 + log(c)` mitigated
#      by hi/lo extended precision (Ln2 = Ln2hi + Ln2lo, log(c) precise
#      enough that `k·Ln2hi + log(c)` is exact).
#
# Table layout: 256 UInt64 in interleaved (invc[0], logc[0], invc[1],
# logc[1], …) order so a single `_log_tab_lookup(2*i + offset)` indexes
# it without a tuple-of-tuples dance.

# ── Range-reduction split: ln(2) = Ln2hi + Ln2lo, Arm 2018 constants ────
const _LOG_LN2HI = reinterpret(UInt64, 0x1.62e42fefa3800p-1)
const _LOG_LN2LO = reinterpret(UInt64, 0x1.ef35793c76730p-45)

# ── Main-path polynomial coefficients A[0..4] for log1p(r) ──────────────
# Layout: y = lo + r²·A0 + r³·(A1 + r·A2 + r²·(A3 + r·A4)) + hi
# Arm 2018 table for N=128, LOG_POLY_ORDER=6. Relative error 0x1.926199e8p-56.
const _LOG_A0 = reinterpret(UInt64, -0x1.0000000000001p-1)
const _LOG_A1 = reinterpret(UInt64,  0x1.555555551305bp-2)
const _LOG_A2 = reinterpret(UInt64, -0x1.fffffffeb459p-3)
const _LOG_A3 = reinterpret(UInt64,  0x1.999b324f10111p-3)
const _LOG_A4 = reinterpret(UInt64, -0x1.55575e506c89fp-3)

# ── Near-1.0 path polynomial coefficients B[0..10] (Arm LOG_POLY1_ORDER=12) ─
# Triggered when x ∈ [LO, HI) ⊃ [1 - 1/16, 1 + 1.09/16). Avoids catastrophic
# cancellation in `k·ln2 + log(c) + log1p(r)` when log(x) is tiny. Relative
# error 0x1.c04d76cp-63. Layout: log(1+r) ≈ r + B0·r² + r³·P11(r) where
#   P11(r) = B1 + r·B2 + r²·B3 + r³·(B4 + r·B5 + r²·B6 +
#                                    r³·(B7 + r·B8 + r²·B9 + r³·B10))
# The leading r + B0·r² term gets a Dekker-style hi/lo split via the
# `rhi = (r + r·2^27) - r·2^27` trick to keep B0·r² accurate.
const _LOG_B0  = reinterpret(UInt64, -0x1p-1)                  # = -0.5 (exact)
const _LOG_B1  = reinterpret(UInt64,  0x1.5555555555577p-2)
const _LOG_B2  = reinterpret(UInt64, -0x1.ffffffffffdcbp-3)
const _LOG_B3  = reinterpret(UInt64,  0x1.999999995dd0cp-3)
const _LOG_B4  = reinterpret(UInt64, -0x1.55555556745a7p-3)
const _LOG_B5  = reinterpret(UInt64,  0x1.24924a344de3p-3)
const _LOG_B6  = reinterpret(UInt64, -0x1.fffffa4423d65p-4)
const _LOG_B7  = reinterpret(UInt64,  0x1.c7184282ad6cap-4)
const _LOG_B8  = reinterpret(UInt64, -0x1.999eb43b068ffp-4)
const _LOG_B9  = reinterpret(UInt64,  0x1.78182f7afd085p-4)
const _LOG_B10 = reinterpret(UInt64, -0x1.5521375d145cdp-4)

# Dekker-split scale factor: 2^27 (chosen so r·2^27 has an exponent above r
# yet the sum (r + r·2^27) is representable in 53 bits — extracts the top
# 26-ish bits of r into rhi, leaving the rest as rlo).
const _LOG_TWO_P27 = reinterpret(UInt64, 0x1p27)

# Near-1 path trigger range: x ∈ [1 - 1/16, 1 + 1.09/16). Compared as
# unsigned bit patterns via `(a - LO) < (HI - LO)`, which excludes negatives
# and out-of-range values automatically (UInt64 wrap). Boundaries match Arm's
# LOG_POLY1_ORDER == 12 path.
const _LOG_NEAR1_LO_BITS = reinterpret(UInt64, 1.0 - 0x1p-4)
const _LOG_NEAR1_HI_BITS = reinterpret(UInt64, 1.0 + 0x1.09p-4)
const _LOG_NEAR1_RANGE   = _LOG_NEAR1_HI_BITS - _LOG_NEAR1_LO_BITS

# ── Range-reduction offset ──────────────────────────────────────────────
# OFF = 0x3FE6000000000000 ≈ 0.6875. Chosen so [OFF, 2·OFF) ⊃ [√(1/2), √2)
# and the full Float64 range maps cleanly to (k, i) pairs via the
# `tmp = ix - OFF` trick.
const _LOG_OFF = UInt64(0x3FE6000000000000)
const _LOG_NEG_ONE_BITS = reinterpret(UInt64, -1.0)
const _LOG_ONE_BITS     = reinterpret(UInt64,  1.0)

# ── 128-entry table T[i] = (invc, logc) ─────────────────────────────────
# Hardcoded verbatim from Arm Optimized Routines `math/log_data.c`
# (commit 2018, N=128 path), MIT-licensed. Layout: T[2i] = invc, T[2i+1] = logc.
const _LOG_TAB = (
    reinterpret(UInt64, 0x1.734f0c3e0de9fp+0),  reinterpret(UInt64, -0x1.7cc7f79e69000p-2),  # i=0
    reinterpret(UInt64, 0x1.713786a2ce91fp+0),  reinterpret(UInt64, -0x1.76feec20d0000p-2),  # i=1
    reinterpret(UInt64, 0x1.6f26008fab5a0p+0),  reinterpret(UInt64, -0x1.713e31351e000p-2),  # i=2
    reinterpret(UInt64, 0x1.6d1a61f138c7dp+0),  reinterpret(UInt64, -0x1.6b85b38287800p-2),  # i=3
    reinterpret(UInt64, 0x1.6b1490bc5b4d1p+0),  reinterpret(UInt64, -0x1.65d5590807800p-2),  # i=4
    reinterpret(UInt64, 0x1.69147332f0cbap+0),  reinterpret(UInt64, -0x1.602d076180000p-2),  # i=5
    reinterpret(UInt64, 0x1.6719f18224223p+0),  reinterpret(UInt64, -0x1.5a8ca86909000p-2),  # i=6
    reinterpret(UInt64, 0x1.6524f99a51ed9p+0),  reinterpret(UInt64, -0x1.54f4356035000p-2),  # i=7
    reinterpret(UInt64, 0x1.63356aa8f24c4p+0),  reinterpret(UInt64, -0x1.4f637c36b4000p-2),  # i=8
    reinterpret(UInt64, 0x1.614b36b9ddc14p+0),  reinterpret(UInt64, -0x1.49da7fda85000p-2),  # i=9
    reinterpret(UInt64, 0x1.5f66452c65c4cp+0),  reinterpret(UInt64, -0x1.445923989a800p-2),  # i=10
    reinterpret(UInt64, 0x1.5d867b5912c4fp+0),  reinterpret(UInt64, -0x1.3edf439b0b800p-2),  # i=11
    reinterpret(UInt64, 0x1.5babccb5b90dep+0),  reinterpret(UInt64, -0x1.396ce448f7000p-2),  # i=12
    reinterpret(UInt64, 0x1.59d61f2d91a78p+0),  reinterpret(UInt64, -0x1.3401e17bda000p-2),  # i=13
    reinterpret(UInt64, 0x1.5805612465687p+0),  reinterpret(UInt64, -0x1.2e9e2ef468000p-2),  # i=14
    reinterpret(UInt64, 0x1.56397cee76bd3p+0),  reinterpret(UInt64, -0x1.2941b3830e000p-2),  # i=15
    reinterpret(UInt64, 0x1.54725e2a77f93p+0),  reinterpret(UInt64, -0x1.23ec58cda8800p-2),  # i=16
    reinterpret(UInt64, 0x1.52aff42064583p+0),  reinterpret(UInt64, -0x1.1e9e129279000p-2),  # i=17
    reinterpret(UInt64, 0x1.50f22dbb2bddfp+0),  reinterpret(UInt64, -0x1.1956d2b48f800p-2),  # i=18
    reinterpret(UInt64, 0x1.4f38f4734ded7p+0),  reinterpret(UInt64, -0x1.141679ab9f800p-2),  # i=19
    reinterpret(UInt64, 0x1.4d843cfde2840p+0),  reinterpret(UInt64, -0x1.0edd094ef9800p-2),  # i=20
    reinterpret(UInt64, 0x1.4bd3ec078a3c8p+0),  reinterpret(UInt64, -0x1.09aa518db1000p-2),  # i=21
    reinterpret(UInt64, 0x1.4a27fc3e0258ap+0),  reinterpret(UInt64, -0x1.047e65263b800p-2),  # i=22
    reinterpret(UInt64, 0x1.4880524d48434p+0),  reinterpret(UInt64, -0x1.feb224586f000p-3),  # i=23
    reinterpret(UInt64, 0x1.46dce1b192d0bp+0),  reinterpret(UInt64, -0x1.f474a7517b000p-3),  # i=24
    reinterpret(UInt64, 0x1.453d9d3391854p+0),  reinterpret(UInt64, -0x1.ea4443d103000p-3),  # i=25
    reinterpret(UInt64, 0x1.43a2744b4845ap+0),  reinterpret(UInt64, -0x1.e020d44e9b000p-3),  # i=26
    reinterpret(UInt64, 0x1.420b54115f8fbp+0),  reinterpret(UInt64, -0x1.d60a22977f000p-3),  # i=27
    reinterpret(UInt64, 0x1.40782da3ef4b1p+0),  reinterpret(UInt64, -0x1.cc00104959000p-3),  # i=28
    reinterpret(UInt64, 0x1.3ee8f5d57fe8fp+0),  reinterpret(UInt64, -0x1.c202956891000p-3),  # i=29
    reinterpret(UInt64, 0x1.3d5d9a00b4ce9p+0),  reinterpret(UInt64, -0x1.b81178d811000p-3),  # i=30
    reinterpret(UInt64, 0x1.3bd60c010c12bp+0),  reinterpret(UInt64, -0x1.ae2c9ccd3d000p-3),  # i=31
    reinterpret(UInt64, 0x1.3a5242b75dab8p+0),  reinterpret(UInt64, -0x1.a45402e129000p-3),  # i=32
    reinterpret(UInt64, 0x1.38d22cd9fd002p+0),  reinterpret(UInt64, -0x1.9a877681df000p-3),  # i=33
    reinterpret(UInt64, 0x1.3755bc5847a1cp+0),  reinterpret(UInt64, -0x1.90c6d69483000p-3),  # i=34
    reinterpret(UInt64, 0x1.35dce49ad36e2p+0),  reinterpret(UInt64, -0x1.87120a645c000p-3),  # i=35
    reinterpret(UInt64, 0x1.34679984dd440p+0),  reinterpret(UInt64, -0x1.7d68fb4143000p-3),  # i=36
    reinterpret(UInt64, 0x1.32f5cceffcb24p+0),  reinterpret(UInt64, -0x1.73cb83c627000p-3),  # i=37
    reinterpret(UInt64, 0x1.3187775a10d49p+0),  reinterpret(UInt64, -0x1.6a39a9b376000p-3),  # i=38
    reinterpret(UInt64, 0x1.301c8373e3990p+0),  reinterpret(UInt64, -0x1.60b3154b7a000p-3),  # i=39
    reinterpret(UInt64, 0x1.2eb4ebb95f841p+0),  reinterpret(UInt64, -0x1.5737d76243000p-3),  # i=40
    reinterpret(UInt64, 0x1.2d50a0219a9d1p+0),  reinterpret(UInt64, -0x1.4dc7b8fc23000p-3),  # i=41
    reinterpret(UInt64, 0x1.2bef9a8b7fd2ap+0),  reinterpret(UInt64, -0x1.4462c51d20000p-3),  # i=42
    reinterpret(UInt64, 0x1.2a91c7a0c1babp+0),  reinterpret(UInt64, -0x1.3b08abc830000p-3),  # i=43
    reinterpret(UInt64, 0x1.293726014b530p+0),  reinterpret(UInt64, -0x1.31b996b490000p-3),  # i=44
    reinterpret(UInt64, 0x1.27dfa5757a1f5p+0),  reinterpret(UInt64, -0x1.2875490a44000p-3),  # i=45
    reinterpret(UInt64, 0x1.268b39b1d3bbfp+0),  reinterpret(UInt64, -0x1.1f3b9f879a000p-3),  # i=46
    reinterpret(UInt64, 0x1.2539d838ff5bdp+0),  reinterpret(UInt64, -0x1.160c8252ca000p-3),  # i=47
    reinterpret(UInt64, 0x1.23eb7aac9083bp+0),  reinterpret(UInt64, -0x1.0ce7f57f72000p-3),  # i=48
    reinterpret(UInt64, 0x1.22a012ba940b6p+0),  reinterpret(UInt64, -0x1.03cdc49fea000p-3),  # i=49
    reinterpret(UInt64, 0x1.2157996cc4132p+0),  reinterpret(UInt64, -0x1.f57bdbc4b8000p-4),  # i=50
    reinterpret(UInt64, 0x1.201201dd2fc9bp+0),  reinterpret(UInt64, -0x1.e370896404000p-4),  # i=51
    reinterpret(UInt64, 0x1.1ecf4494d480bp+0),  reinterpret(UInt64, -0x1.d17983ef94000p-4),  # i=52
    reinterpret(UInt64, 0x1.1d8f5528f6569p+0),  reinterpret(UInt64, -0x1.bf9674ed8a000p-4),  # i=53
    reinterpret(UInt64, 0x1.1c52311577e7cp+0),  reinterpret(UInt64, -0x1.adc79202f6000p-4),  # i=54
    reinterpret(UInt64, 0x1.1b17c74cb26e9p+0),  reinterpret(UInt64, -0x1.9c0c3e7288000p-4),  # i=55
    reinterpret(UInt64, 0x1.19e010c2c1ab6p+0),  reinterpret(UInt64, -0x1.8a646b372c000p-4),  # i=56
    reinterpret(UInt64, 0x1.18ab07bb670bdp+0),  reinterpret(UInt64, -0x1.78d01b3ac0000p-4),  # i=57
    reinterpret(UInt64, 0x1.1778a25efbcb6p+0),  reinterpret(UInt64, -0x1.674f145380000p-4),  # i=58
    reinterpret(UInt64, 0x1.1648d354c31dap+0),  reinterpret(UInt64, -0x1.55e0e6d878000p-4),  # i=59
    reinterpret(UInt64, 0x1.151b990275fddp+0),  reinterpret(UInt64, -0x1.4485cdea1e000p-4),  # i=60
    reinterpret(UInt64, 0x1.13f0ea432d24cp+0),  reinterpret(UInt64, -0x1.333d94d6aa000p-4),  # i=61
    reinterpret(UInt64, 0x1.12c8b7210f9dap+0),  reinterpret(UInt64, -0x1.22079f8c56000p-4),  # i=62
    reinterpret(UInt64, 0x1.11a3028ecb531p+0),  reinterpret(UInt64, -0x1.10e4698622000p-4),  # i=63
    reinterpret(UInt64, 0x1.107fbda8434afp+0),  reinterpret(UInt64, -0x1.ffa6c6ad20000p-5),  # i=64
    reinterpret(UInt64, 0x1.0f5ee0f4e6bb3p+0),  reinterpret(UInt64, -0x1.dda8d4a774000p-5),  # i=65
    reinterpret(UInt64, 0x1.0e4065d2a9fcep+0),  reinterpret(UInt64, -0x1.bbcece4850000p-5),  # i=66
    reinterpret(UInt64, 0x1.0d244632ca521p+0),  reinterpret(UInt64, -0x1.9a1894012c000p-5),  # i=67
    reinterpret(UInt64, 0x1.0c0a77ce2981ap+0),  reinterpret(UInt64, -0x1.788583302c000p-5),  # i=68
    reinterpret(UInt64, 0x1.0af2f83c636d1p+0),  reinterpret(UInt64, -0x1.5715e67d68000p-5),  # i=69
    reinterpret(UInt64, 0x1.09ddb98a01339p+0),  reinterpret(UInt64, -0x1.35c8a49658000p-5),  # i=70
    reinterpret(UInt64, 0x1.08cabaf52e7dfp+0),  reinterpret(UInt64, -0x1.149e364154000p-5),  # i=71
    reinterpret(UInt64, 0x1.07b9f2f4e28fbp+0),  reinterpret(UInt64, -0x1.e72c082eb8000p-6),  # i=72
    reinterpret(UInt64, 0x1.06ab58c358f19p+0),  reinterpret(UInt64, -0x1.a55f152528000p-6),  # i=73
    reinterpret(UInt64, 0x1.059eea5ecf92cp+0),  reinterpret(UInt64, -0x1.63d62cf818000p-6),  # i=74
    reinterpret(UInt64, 0x1.04949cdd12c90p+0),  reinterpret(UInt64, -0x1.228fb8caa0000p-6),  # i=75
    reinterpret(UInt64, 0x1.038c6c6f0ada9p+0),  reinterpret(UInt64, -0x1.c317b20f90000p-7),  # i=76
    reinterpret(UInt64, 0x1.02865137932a9p+0),  reinterpret(UInt64, -0x1.419355daa0000p-7),  # i=77
    reinterpret(UInt64, 0x1.0182427ea7348p+0),  reinterpret(UInt64, -0x1.81203c2ec0000p-8),  # i=78
    reinterpret(UInt64, 0x1.008040614b195p+0),  reinterpret(UInt64, -0x1.0040979240000p-9),  # i=79
    reinterpret(UInt64, 0x1.fe01ff726fa1ap-1),  reinterpret(UInt64,  0x1.feff384900000p-9),  # i=80
    reinterpret(UInt64, 0x1.fa11cc261ea74p-1),  reinterpret(UInt64,  0x1.7dc41353d0000p-7),  # i=81
    reinterpret(UInt64, 0x1.f6310b081992ep-1),  reinterpret(UInt64,  0x1.3cea3c4c28000p-6),  # i=82
    reinterpret(UInt64, 0x1.f25f63ceeadcdp-1),  reinterpret(UInt64,  0x1.b9fc114890000p-6),  # i=83
    reinterpret(UInt64, 0x1.ee9c8039113e7p-1),  reinterpret(UInt64,  0x1.1b0d8ce110000p-5),  # i=84
    reinterpret(UInt64, 0x1.eae8078cbb1abp-1),  reinterpret(UInt64,  0x1.58a5bd001c000p-5),  # i=85
    reinterpret(UInt64, 0x1.e741aa29d0c9bp-1),  reinterpret(UInt64,  0x1.95c8340d88000p-5),  # i=86
    reinterpret(UInt64, 0x1.e3a91830a99b5p-1),  reinterpret(UInt64,  0x1.d276aef578000p-5),  # i=87
    reinterpret(UInt64, 0x1.e01e009609a56p-1),  reinterpret(UInt64,  0x1.07598e598c000p-4),  # i=88
    reinterpret(UInt64, 0x1.dca01e577bb98p-1),  reinterpret(UInt64,  0x1.253f5e30d2000p-4),  # i=89
    reinterpret(UInt64, 0x1.d92f20b7c9103p-1),  reinterpret(UInt64,  0x1.42edd8b380000p-4),  # i=90
    reinterpret(UInt64, 0x1.d5cac66fb5ccep-1),  reinterpret(UInt64,  0x1.606598757c000p-4),  # i=91
    reinterpret(UInt64, 0x1.d272caa5ede9dp-1),  reinterpret(UInt64,  0x1.7da76356a0000p-4),  # i=92
    reinterpret(UInt64, 0x1.cf26e3e6b2ccdp-1),  reinterpret(UInt64,  0x1.9ab434e1c6000p-4),  # i=93
    reinterpret(UInt64, 0x1.cbe6da2a77902p-1),  reinterpret(UInt64,  0x1.b78c7bb0d6000p-4),  # i=94
    reinterpret(UInt64, 0x1.c8b266d37086dp-1),  reinterpret(UInt64,  0x1.d431332e72000p-4),  # i=95
    reinterpret(UInt64, 0x1.c5894bd5d5804p-1),  reinterpret(UInt64,  0x1.f0a3171de6000p-4),  # i=96
    reinterpret(UInt64, 0x1.c26b533bb9f8cp-1),  reinterpret(UInt64,  0x1.067152b914000p-3),  # i=97
    reinterpret(UInt64, 0x1.bf583eeece73fp-1),  reinterpret(UInt64,  0x1.147858292b000p-3),  # i=98
    reinterpret(UInt64, 0x1.bc4fd75db96c1p-1),  reinterpret(UInt64,  0x1.2266ecdca3000p-3),  # i=99
    reinterpret(UInt64, 0x1.b951e0c864a28p-1),  reinterpret(UInt64,  0x1.303d7a6c55000p-3),  # i=100
    reinterpret(UInt64, 0x1.b65e2c5ef3e2cp-1),  reinterpret(UInt64,  0x1.3dfc33c331000p-3),  # i=101
    reinterpret(UInt64, 0x1.b374867c9888bp-1),  reinterpret(UInt64,  0x1.4ba366b7a8000p-3),  # i=102
    reinterpret(UInt64, 0x1.b094b211d304ap-1),  reinterpret(UInt64,  0x1.5933928d1f000p-3),  # i=103
    reinterpret(UInt64, 0x1.adbe885f2ef7ep-1),  reinterpret(UInt64,  0x1.66acd2418f000p-3),  # i=104
    reinterpret(UInt64, 0x1.aaf1d31603da2p-1),  reinterpret(UInt64,  0x1.740f8ec669000p-3),  # i=105
    reinterpret(UInt64, 0x1.a82e63fd358a7p-1),  reinterpret(UInt64,  0x1.815c0f51af000p-3),  # i=106
    reinterpret(UInt64, 0x1.a5740ef09738bp-1),  reinterpret(UInt64,  0x1.8e92954f68000p-3),  # i=107
    reinterpret(UInt64, 0x1.a2c2a90ab4b27p-1),  reinterpret(UInt64,  0x1.9bb3602f84000p-3),  # i=108
    reinterpret(UInt64, 0x1.a01a01393f2d1p-1),  reinterpret(UInt64,  0x1.a8bed1c2c0000p-3),  # i=109
    reinterpret(UInt64, 0x1.9d79f24db3c1bp-1),  reinterpret(UInt64,  0x1.b5b515c01d000p-3),  # i=110
    reinterpret(UInt64, 0x1.9ae2505c7b190p-1),  reinterpret(UInt64,  0x1.c2967ccbcc000p-3),  # i=111
    reinterpret(UInt64, 0x1.9852ef297ce2fp-1),  reinterpret(UInt64,  0x1.cf635d5486000p-3),  # i=112
    reinterpret(UInt64, 0x1.95cbaeea44b75p-1),  reinterpret(UInt64,  0x1.dc1bd3446c000p-3),  # i=113
    reinterpret(UInt64, 0x1.934c69de74838p-1),  reinterpret(UInt64,  0x1.e8c01b8cfe000p-3),  # i=114
    reinterpret(UInt64, 0x1.90d4f2f6752e6p-1),  reinterpret(UInt64,  0x1.f5509c0179000p-3),  # i=115
    reinterpret(UInt64, 0x1.8e6528effd79dp-1),  reinterpret(UInt64,  0x1.00e6c121fb800p-2),  # i=116
    reinterpret(UInt64, 0x1.8bfce9fcc007cp-1),  reinterpret(UInt64,  0x1.071b80e93d000p-2),  # i=117
    reinterpret(UInt64, 0x1.899c0dabec30ep-1),  reinterpret(UInt64,  0x1.0d46b9e867000p-2),  # i=118
    reinterpret(UInt64, 0x1.87427aa2317fbp-1),  reinterpret(UInt64,  0x1.13687334bd000p-2),  # i=119
    reinterpret(UInt64, 0x1.84f00acb39a08p-1),  reinterpret(UInt64,  0x1.1980d67234800p-2),  # i=120
    reinterpret(UInt64, 0x1.82a49e8653e55p-1),  reinterpret(UInt64,  0x1.1f8ffe0cc8000p-2),  # i=121
    reinterpret(UInt64, 0x1.8060195f40260p-1),  reinterpret(UInt64,  0x1.2595fd7636800p-2),  # i=122
    reinterpret(UInt64, 0x1.7e22563e0a329p-1),  reinterpret(UInt64,  0x1.2b9300914a800p-2),  # i=123
    reinterpret(UInt64, 0x1.7beb377dcb5adp-1),  reinterpret(UInt64,  0x1.3187210436000p-2),  # i=124
    reinterpret(UInt64, 0x1.79baa679725c2p-1),  reinterpret(UInt64,  0x1.377266dec1800p-2),  # i=125
    reinterpret(UInt64, 0x1.77907f2170657p-1),  reinterpret(UInt64,  0x1.3d54ffbaf3000p-2),  # i=126
    reinterpret(UInt64, 0x1.756cadbd6130cp-1),  reinterpret(UInt64,  0x1.432eee32fe000p-2),  # i=127
)

# Constant-tuple table-lookup pattern (matches `_exp_tab_lookup` in fexp.jl).
# The `let T = _LOG_TAB; T[idx+1]; end` shape is the documented requirement
# for QROM dispatch — module-level const tuples don't inline through to the
# IR walker. Returns the raw bits at index `idx` (1-based after the `+1`).
@inline function _log_tab_lookup(idx::Int)::UInt64
    let T = _LOG_TAB
        @inbounds T[idx + 1]
    end
end

"""
    soft_log(a::UInt64) -> UInt64

IEEE 754 double-precision natural logarithm `log(x) = ln(x)` on raw bit
patterns. **≤2 ulp vs `Base.log`** across the entire IEEE input range.
Branchless integer arithmetic for special-case dispatch + soft_f* primitives
for the polynomial body.

Algorithm: Tang-style range reduction with N=128 lookup table and degree-6
minimax polynomial (Arm Optimized Routines / musl `log.c`, Wilhelm/Sibidanov
2018). For x = 2^k · z with z ∈ [0x1.6p-1, 0x1.6p0), looks up
(1/c_i, log(c_i)) where c_i is near the center of z's subinterval, then
computes `log(x) = k·ln(2) + log(c_i) + log1p(z/c_i - 1)`. The hi/lo
extended-precision split on `k·ln(2) + log(c_i)` mitigates catastrophic
cancellation near x = 1.

Special cases (last-write-wins ifelse chain):
- log(1)        = +0     (bit-exact)
- log(±0)       = -Inf
- log(x < 0)    = NaN    (any negative finite, including -Inf)
- log(+Inf)     = +Inf
- log(NaN)      = NaN    (propagate, force-quiet signalling)

Subnormal inputs are normalized via `_sf_normalize_to_bit52` before range
reduction. The Arm `ix = asuint(x · 2^52); ix -= 52<<52` integer trick is
faithfully reproduced; see worklog/054 for the bit-pattern derivation.
"""
@inline function soft_log(a::UInt64)::UInt64
    sa = a >> 63
    ea = (a >> 52) & UInt64(0x7FF)
    fa = a & FRAC_MASK

    # ── Special-case detection (all branchless) ───────────────────────
    a_nan       = (ea == UInt64(0x7FF)) & (fa != UInt64(0))
    a_pinf      = (ea == UInt64(0x7FF)) & (fa == UInt64(0)) & (sa == UInt64(0))
    a_zero      = (ea == UInt64(0)) & (fa == UInt64(0))
    a_negative  = (sa != UInt64(0)) & ~a_zero       # x < 0 (incl. -Inf, -NaN, -finite)
    a_subnormal = (ea == UInt64(0)) & (fa != UInt64(0))

    # ── Subnormal normalization ───────────────────────────────────────
    # Bring leading 1 to bit 52, decrement effective biased exponent
    # accordingly. _sf_normalize_to_bit52 handles fa==0 defensively (returns
    # input unchanged); we guard with a_subnormal in the select chain below
    # so the no-op behavior is irrelevant.
    fa_norm_w_imp, e_norm = _sf_normalize_to_bit52(fa, Int64(1))
    fa_norm = fa_norm_w_imp & FRAC_MASK
    # ix_eff: re-encoded "as-if-normal" bit pattern. For subnormals e_norm
    # can be ≤0; UInt64 wrap-around lets the (int64)tmp >> 52 arithmetic-
    # shift recover the correct signed k below.
    ea_eff = ifelse(a_subnormal, reinterpret(UInt64, e_norm), ea)
    fa_eff = ifelse(a_subnormal, fa_norm, fa)
    ix_eff = (ea_eff << 52) | fa_eff

    # ── Range reduction: x = 2^k · z, z ∈ [OFF, 2·OFF) ────────────────
    tmp = ix_eff - _LOG_OFF
    # Index i: top 7 bits of mantissa region (bits 45..51 of tmp).
    i_idx = Int((tmp >> 45) & UInt64(0x7F))
    # k: arithmetic shift of signed tmp, recovering the integer exponent.
    k = reinterpret(Int64, tmp) >> 52
    # Re-encode z: subtract the upper-12-bit (sign + biased exponent) part
    # of tmp, leaving ix in [OFF, 2·OFF). Since ea_eff might wrap past 0
    # (subnormal case), this re-anchors z to a valid normal Float64.
    iz = ix_eff - (tmp & (UInt64(0xFFF) << 52))
    z = iz

    # ── Table lookup ──────────────────────────────────────────────────
    invc = _log_tab_lookup(2 * i_idx)
    logc = _log_tab_lookup(2 * i_idx + 1)

    # ── r = z · invc - 1 (small, |r| < 1/(2N)) ────────────────────────
    r = soft_fma(z, invc, _LOG_NEG_ONE_BITS)

    # ── kd = (double) k ──
    kd = soft_sitofp(reinterpret(UInt64, k))

    # ── hi/lo extended-precision: w = kd·Ln2hi + logc; hi = w + r ──
    kd_ln2hi  = soft_fmul(kd, _LOG_LN2HI)
    w         = soft_fadd(kd_ln2hi, logc)
    hi        = soft_fadd(w, r)
    # lo = (w - hi) + r + kd·Ln2lo
    w_sub_hi  = soft_fsub(w, hi)
    w_sub_hi_r = soft_fadd(w_sub_hi, r)
    kd_ln2lo  = soft_fmul(kd, _LOG_LN2LO)
    lo        = soft_fadd(w_sub_hi_r, kd_ln2lo)

    # ── Main-path polynomial: y = lo + r²·A0 + r³·(A1 + r·A2 + r²·(A3 + r·A4)) + hi
    r2 = soft_fmul(r, r)
    r3 = soft_fmul(r, r2)
    rA2     = soft_fmul(r,  _LOG_A2)
    A1_rA2  = soft_fadd(_LOG_A1, rA2)
    rA4     = soft_fmul(r,  _LOG_A4)
    A3_rA4  = soft_fadd(_LOG_A3, rA4)
    r2_A3rA4 = soft_fmul(r2, A3_rA4)
    inner   = soft_fadd(A1_rA2, r2_A3rA4)
    poly_main = soft_fmul(r3, inner)
    r2_A0   = soft_fmul(r2, _LOG_A0)
    y_a     = soft_fadd(lo,   r2_A0)
    y_b     = soft_fadd(y_a,  poly_main)
    y_main  = soft_fadd(y_b,  hi)

    # ── Near-1.0 path: log(1+rn) via degree-12 polynomial in rn = x - 1.0 ─
    # Triggered when x ∈ [1 - 1/16, 1 + 1.09/16), avoiding the cancellation
    # in `k·ln2 + log(c) + log1p(r)` when log(x) is tiny. r=0 (i.e. x=1.0
    # exactly) propagates through every multiply and gives bit-exact 0.0.
    rn  = soft_fsub(a, _LOG_ONE_BITS)
    rn2 = soft_fmul(rn, rn)
    rn3 = soft_fmul(rn, rn2)

    # P11(rn) = B1 + rn·B2 + rn²·B3 + rn³·(B4 + rn·B5 + rn²·B6
    #                                       + rn³·(B7 + rn·B8 + rn²·B9 + rn³·B10))
    rnB8   = soft_fmul(rn,  _LOG_B8)
    rnB5   = soft_fmul(rn,  _LOG_B5)
    rnB2   = soft_fmul(rn,  _LOG_B2)
    rn2B9  = soft_fmul(rn2, _LOG_B9)
    rn2B6  = soft_fmul(rn2, _LOG_B6)
    rn2B3  = soft_fmul(rn2, _LOG_B3)
    B7_rnB8 = soft_fadd(_LOG_B7, rnB8)
    # Inner-3: B7 + rn·B8 + rn²·B9 + rn³·B10
    rn3B10 = soft_fmul(rn3, _LOG_B10)
    rn2B9_rn3B10 = soft_fadd(rn2B9, rn3B10)
    inner3 = soft_fadd(B7_rnB8, rn2B9_rn3B10)
    # Inner-2: B4 + rn·B5 + rn²·B6 + rn³·inner3
    rn3_inner3 = soft_fmul(rn3, inner3)
    rn2B6_rn3I3 = soft_fadd(rn2B6, rn3_inner3)
    B4_rnB5    = soft_fadd(_LOG_B4, rnB5)
    inner2 = soft_fadd(B4_rnB5, rn2B6_rn3I3)
    # Outer poly: B1 + rn·B2 + rn²·B3 + rn³·inner2
    rn3_inner2 = soft_fmul(rn3, inner2)
    rn2B3_rn3I2 = soft_fadd(rn2B3, rn3_inner2)
    B1_rnB2    = soft_fadd(_LOG_B1, rnB2)
    poly11 = soft_fadd(B1_rnB2, rn2B3_rn3I2)
    y_poly = soft_fmul(rn3, poly11)

    # Dekker hi/lo split for the leading r + B0·r² term (B0 = -0.5).
    #   rhi = (rn + rn·2^27) - rn·2^27  → top ~26 bits of rn (rn·2^27 separates them out)
    #   rlo = rn - rhi
    w_split  = soft_fmul(rn, _LOG_TWO_P27)
    rn_plus_w = soft_fadd(rn, w_split)
    rhi      = soft_fsub(rn_plus_w, w_split)
    rlo      = soft_fsub(rn, rhi)
    rhi2     = soft_fmul(rhi, rhi)
    w_b0     = soft_fmul(rhi2, _LOG_B0)              # = -0.5 · rhi² (high-precision part of B0·rn²)
    hi_part  = soft_fadd(rn, w_b0)                   # rn + (-0.5)·rhi²
    rn_sub_hi = soft_fsub(rn, hi_part)
    lo_a     = soft_fadd(rn_sub_hi, w_b0)            # (rn - hi) + (-0.5)·rhi²  (exact-ish)
    rhi_p_rn  = soft_fadd(rhi, rn)
    rlo_x_rhi_p_rn = soft_fmul(rlo, rhi_p_rn)
    B0_correction = soft_fmul(_LOG_B0, rlo_x_rhi_p_rn)
    lo_part  = soft_fadd(lo_a, B0_correction)

    y_near = soft_fadd(soft_fadd(y_poly, lo_part), hi_part)

    # ── Path selection: near-1 when (a - LO_BITS) < (HI_BITS - LO_BITS) ─
    # Unsigned compare: ix outside [LO, HI) wraps to a huge UInt64 value,
    # automatically failing the comparison. Negatives have sign bit set so
    # they're far above HI in unsigned ordering — also fail.
    near_one = (a - _LOG_NEAR1_LO_BITS) < _LOG_NEAR1_RANGE
    y = ifelse(near_one, y_near, y_main)

    # ── Branchless special-case override chain (last-write-wins) ──────
    # Order matters: a_nan must come AFTER a_negative because -NaN sets
    # both flags, and we want NaN propagation (preserve payload, force
    # quiet bit) to win.
    NEG_INF_BITS = UInt64(0xFFF0000000000000)
    result = y
    result = ifelse(a_zero,     NEG_INF_BITS,         result)   # log(±0) = -Inf
    result = ifelse(a_negative, QNAN,                 result)   # log(<0) = NaN
    result = ifelse(a_pinf,     INF_BITS,             result)   # log(+Inf) = +Inf
    result = ifelse(a_nan,      a | QUIET_BIT,        result)   # NaN propagation
    return result
end

# ── log2 / log10 via change-of-base identity ────────────────────────────
#
# log2(x)  = log(x) · log2(e)   where log2(e)  ≈ 0x1.71547652b82fep+0
# log10(x) = log(x) · log10(e)  where log10(e) ≈ 0x1.bcb7b1526e50ep-2
#
# Special cases propagate correctly through `soft_fmul`:
#   - log(1) = +0, so log2(1) = log10(1) = +0 bit-exact (0 · anything = 0).
#   - log(±0) = -Inf → -Inf · positive = -Inf.
#   - log(<0) = NaN → NaN · anything = NaN.
#   - log(+Inf) = +Inf → +Inf · positive = +Inf.
#   - NaN propagates with quiet-bit set.
#
# Accuracy: ≤2 ULP vs `Base.log2` / `Base.log10` (soft_log is ≤1 ULP, the
# multiply adds at most 1 ULP). Integer-power-of-2 inputs are NOT
# guaranteed bit-exact (e.g. `log2(2.0)` may return `1.0 ± 1 ULP`); a
# dedicated polynomial with absorbed log2(e) factor would tighten this
# at the cost of a separate 256-UInt64 table. Filed as future work in
# the §13 transcendental contract — current target is ≤2 ULP, met.
const _LOG_LOG2E_BITS  = reinterpret(UInt64, 0x1.71547652b82fep+0)   # log2(e)
const _LOG_LOG10E_BITS = reinterpret(UInt64, 0x1.bcb7b1526e50ep-2)   # log10(e)

"""
    soft_log2(a::UInt64) -> UInt64

IEEE 754 double-precision base-2 logarithm `log2(x)` on raw bit patterns.
**≤2 ULP vs `Base.log2`**. Implemented via `soft_log(x) · log2(e)`, so
special cases (NaN, ±Inf, ±0, negative) propagate from `soft_log` through
`soft_fmul` correctly without per-case dispatch.

For integer-power-of-2 inputs (e.g. `log2(2.0)` should be exactly 1.0),
the multiply-by-constant approach does NOT guarantee bit-exactness — the
result lands within ≤2 ULP of the integer. Bit-exact behavior would
require a dedicated polynomial absorbing the `log2(e)` factor (Arm
`log2.c` pattern); deferred as future work pending a tightness need.
"""
@inline soft_log2(a::UInt64)::UInt64 = soft_fmul(soft_log(a), _LOG_LOG2E_BITS)

"""
    soft_log10(a::UInt64) -> UInt64

IEEE 754 double-precision base-10 logarithm `log10(x)` on raw bit patterns.
**≤2 ULP vs `Base.log10`**. Implemented via `soft_log(x) · log10(e)`.

See `soft_log2` for the bit-exactness caveat on `log10(10)` and powers of 10.
"""
@inline soft_log10(a::UInt64)::UInt64 = soft_fmul(soft_log(a), _LOG_LOG10E_BITS)
