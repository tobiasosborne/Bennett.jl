# IEEE 754 binary64 power function `pow(x, y) = x^y` on raw bit patterns.
# Branchless integer arithmetic for special-case dispatch + soft_f* primitives
# for the polynomial body. Faithful port of Arm Optimized Routines / musl
# `src/math/pow.c` + `pow_log_data.c` (Wilhelm/Sibidanov 2018, MIT-licensed).
#
# Reference accuracy (Arm/musl): worst-case 0.54 ULP across the whole input
# domain (claim from pow.c header). Bennett practical target vs `Base.:^`:
# ≤2 ULP (matching the project's transcendental contract).
#
# Algorithm:
#   1. Front-loaded special-case detection. Every IEEE 754-2019 §9.2 case
#      is enumerated as a branchless bool flag and folded into the final
#      ifelse-override chain. The main path is computed unconditionally.
#   2. Main path (for finite x > 0, finite y in normal range):
#        (loghi, loglo) = _pow_log_inline(ix)         -- natural log, extended precision
#        (ehi, elo)     = y · (loghi + loglo)         -- via soft_fma to avoid Dekker split
#        result         = _pow_exp_inline(ehi, elo, sign_bias)
#      where `sign_bias` is 0 for x > 0 and `SIGN_BIAS` (set in the table-
#      lookup index of the exp) for negative-x odd-integer-y (sign rule).
#   3. Special-case override chain (last-write-wins):
#        - pow(x, ±0)  = 1.0 always
#        - pow(±1, y)  = 1.0 (POSIX/C99 — distinct from IEEE 754-2008 powr)
#        - pow(NaN, ·) or pow(·, NaN) = NaN propagated via x+y
#        - pow(±0, y<0, odd-int y) = ±Inf (DivByZero raised in C; we just return)
#        - pow(±0, y<0, else) = +Inf
#        - pow(±0, y>0, odd-int y) = ±0 (sign preserved)
#        - pow(±0, y>0, else) = +0
#        - pow(-1, ±Inf) = 1.0 (754-2008)
#        - pow(|x|<1, +Inf) = +0; pow(|x|<1, -Inf) = +Inf
#        - pow(|x|>1, +Inf) = +Inf; pow(|x|>1, -Inf) = +0
#        - pow(+Inf, y<0) = +0; pow(+Inf, y>0) = +Inf
#        - pow(-Inf, y) sign-flipped per odd-int rule
#        - pow(x<0, non-integer y) = NaN
#        - Overflow / underflow handled inside _pow_exp_inline's sbits arithmetic.

# ── Range-reduction split: ln(2) hi+lo (Arm 2018 constants) ────────────
# Reused from soft_log; redefined here for self-containment of pow.
const _POW_LN2HI = reinterpret(UInt64, 0x1.62e42fefa3800p-1)
const _POW_LN2LO = reinterpret(UInt64, 0x1.ef35793c76730p-45)

# ── Pow's log-polynomial coefficients A[0..6] for log1p(r) ────────────
# Layout (Arm pow.c POW_LOG_POLY_ORDER == 8):
#   poly = ar3·(A[1] + r·A[2] + ar2·(A[3] + r·A[4] + ar2·(A[5] + r·A[6])))
#   where ar = A[0]·r, ar2 = r·ar, ar3 = r·ar2.
#   A[0] = -0.5; A[1..6] are pre-scaled in the C source (·-2, ·4, ·-8).
# Relative error: 0x1.11922ap-70 in [-0x1.6bp-8, 0x1.6bp-8].
const _POW_LOG_A0 = reinterpret(UInt64, -0x1p-1)
const _POW_LOG_A1 = reinterpret(UInt64,  0x1.555555555556p-2 * -2)
const _POW_LOG_A2 = reinterpret(UInt64, -0x1.0000000000006p-2 * -2)
const _POW_LOG_A3 = reinterpret(UInt64,  0x1.999999959554ep-3 *  4)
const _POW_LOG_A4 = reinterpret(UInt64, -0x1.555555529a47ap-3 *  4)
const _POW_LOG_A5 = reinterpret(UInt64,  0x1.2495b9b4845e9p-3 * -8)
const _POW_LOG_A6 = reinterpret(UInt64, -0x1.0002b8b263fc3p-3 * -8)

# Range-reduction offset: OFF = 0x3FE6955500000000 ≈ √(1/2). Different from
# log.c's OFF (which uses 0x3FE6000000000000); pow's wider window keeps
# log(c) away from zero for extended-precision needs.
const _POW_LOG_OFF      = UInt64(0x3FE6955500000000)
const _POW_LOG_NEG_ONE  = reinterpret(UInt64, -1.0)
const _POW_LOG_ONE_BITS = reinterpret(UInt64,  1.0)

# ── 128-entry pow_log table split into three index-aligned tables ─────
# Hardcoded from Arm Optimized Routines `math/pow_log_data.c` (2018, N=128,
# POW_LOG_POLY_ORDER=8, MIT-licensed). The reference table T[i] = {invc,
# logc, logctail} (3 doubles per entry); we split into three parallel
# 128-entry tables indexed directly by `i_idx` so that Bennett's QROM
# lookup dispatch sees a stride-1 access pattern. (The previous
# stride-3 layout `T[3*i + offset]` triggered a `_lower_load_legacy!`
# failure when accessed at multiple offsets in the same call site —
# Bennett's QROM materialization currently expects power-of-2 strides.
# Splitting the table sidesteps this without changing semantics.)
const _POW_LOG_TAB_INVC = (
    reinterpret(UInt64, 0x1.6a00000000000p+0),  # i=0
    reinterpret(UInt64, 0x1.6800000000000p+0),  # i=1
    reinterpret(UInt64, 0x1.6600000000000p+0),  # i=2
    reinterpret(UInt64, 0x1.6400000000000p+0),  # i=3
    reinterpret(UInt64, 0x1.6200000000000p+0),  # i=4
    reinterpret(UInt64, 0x1.6000000000000p+0),  # i=5
    reinterpret(UInt64, 0x1.5e00000000000p+0),  # i=6
    reinterpret(UInt64, 0x1.5c00000000000p+0),  # i=7
    reinterpret(UInt64, 0x1.5a00000000000p+0),  # i=8
    reinterpret(UInt64, 0x1.5800000000000p+0),  # i=9
    reinterpret(UInt64, 0x1.5600000000000p+0),  # i=10
    reinterpret(UInt64, 0x1.5600000000000p+0),  # i=11
    reinterpret(UInt64, 0x1.5400000000000p+0),  # i=12
    reinterpret(UInt64, 0x1.5200000000000p+0),  # i=13
    reinterpret(UInt64, 0x1.5000000000000p+0),  # i=14
    reinterpret(UInt64, 0x1.4e00000000000p+0),  # i=15
    reinterpret(UInt64, 0x1.4c00000000000p+0),  # i=16
    reinterpret(UInt64, 0x1.4a00000000000p+0),  # i=17
    reinterpret(UInt64, 0x1.4a00000000000p+0),  # i=18
    reinterpret(UInt64, 0x1.4800000000000p+0),  # i=19
    reinterpret(UInt64, 0x1.4600000000000p+0),  # i=20
    reinterpret(UInt64, 0x1.4400000000000p+0),  # i=21
    reinterpret(UInt64, 0x1.4200000000000p+0),  # i=22
    reinterpret(UInt64, 0x1.4000000000000p+0),  # i=23
    reinterpret(UInt64, 0x1.4000000000000p+0),  # i=24
    reinterpret(UInt64, 0x1.3e00000000000p+0),  # i=25
    reinterpret(UInt64, 0x1.3c00000000000p+0),  # i=26
    reinterpret(UInt64, 0x1.3a00000000000p+0),  # i=27
    reinterpret(UInt64, 0x1.3a00000000000p+0),  # i=28
    reinterpret(UInt64, 0x1.3800000000000p+0),  # i=29
    reinterpret(UInt64, 0x1.3600000000000p+0),  # i=30
    reinterpret(UInt64, 0x1.3400000000000p+0),  # i=31
    reinterpret(UInt64, 0x1.3400000000000p+0),  # i=32
    reinterpret(UInt64, 0x1.3200000000000p+0),  # i=33
    reinterpret(UInt64, 0x1.3000000000000p+0),  # i=34
    reinterpret(UInt64, 0x1.3000000000000p+0),  # i=35
    reinterpret(UInt64, 0x1.2e00000000000p+0),  # i=36
    reinterpret(UInt64, 0x1.2c00000000000p+0),  # i=37
    reinterpret(UInt64, 0x1.2c00000000000p+0),  # i=38
    reinterpret(UInt64, 0x1.2a00000000000p+0),  # i=39
    reinterpret(UInt64, 0x1.2800000000000p+0),  # i=40
    reinterpret(UInt64, 0x1.2600000000000p+0),  # i=41
    reinterpret(UInt64, 0x1.2600000000000p+0),  # i=42
    reinterpret(UInt64, 0x1.2400000000000p+0),  # i=43
    reinterpret(UInt64, 0x1.2400000000000p+0),  # i=44
    reinterpret(UInt64, 0x1.2200000000000p+0),  # i=45
    reinterpret(UInt64, 0x1.2000000000000p+0),  # i=46
    reinterpret(UInt64, 0x1.2000000000000p+0),  # i=47
    reinterpret(UInt64, 0x1.1e00000000000p+0),  # i=48
    reinterpret(UInt64, 0x1.1c00000000000p+0),  # i=49
    reinterpret(UInt64, 0x1.1c00000000000p+0),  # i=50
    reinterpret(UInt64, 0x1.1a00000000000p+0),  # i=51
    reinterpret(UInt64, 0x1.1a00000000000p+0),  # i=52
    reinterpret(UInt64, 0x1.1800000000000p+0),  # i=53
    reinterpret(UInt64, 0x1.1600000000000p+0),  # i=54
    reinterpret(UInt64, 0x1.1600000000000p+0),  # i=55
    reinterpret(UInt64, 0x1.1400000000000p+0),  # i=56
    reinterpret(UInt64, 0x1.1400000000000p+0),  # i=57
    reinterpret(UInt64, 0x1.1200000000000p+0),  # i=58
    reinterpret(UInt64, 0x1.1000000000000p+0),  # i=59
    reinterpret(UInt64, 0x1.1000000000000p+0),  # i=60
    reinterpret(UInt64, 0x1.0e00000000000p+0),  # i=61
    reinterpret(UInt64, 0x1.0e00000000000p+0),  # i=62
    reinterpret(UInt64, 0x1.0c00000000000p+0),  # i=63
    reinterpret(UInt64, 0x1.0c00000000000p+0),  # i=64
    reinterpret(UInt64, 0x1.0a00000000000p+0),  # i=65
    reinterpret(UInt64, 0x1.0a00000000000p+0),  # i=66
    reinterpret(UInt64, 0x1.0800000000000p+0),  # i=67
    reinterpret(UInt64, 0x1.0800000000000p+0),  # i=68
    reinterpret(UInt64, 0x1.0600000000000p+0),  # i=69
    reinterpret(UInt64, 0x1.0400000000000p+0),  # i=70
    reinterpret(UInt64, 0x1.0400000000000p+0),  # i=71
    reinterpret(UInt64, 0x1.0200000000000p+0),  # i=72
    reinterpret(UInt64, 0x1.0200000000000p+0),  # i=73
    reinterpret(UInt64, 0x1.0000000000000p+0),  # i=74
    reinterpret(UInt64, 0x1.0000000000000p+0),  # i=75
    reinterpret(UInt64, 0x1.fc00000000000p-1),  # i=76
    reinterpret(UInt64, 0x1.f800000000000p-1),  # i=77
    reinterpret(UInt64, 0x1.f400000000000p-1),  # i=78
    reinterpret(UInt64, 0x1.f000000000000p-1),  # i=79
    reinterpret(UInt64, 0x1.ec00000000000p-1),  # i=80
    reinterpret(UInt64, 0x1.e800000000000p-1),  # i=81
    reinterpret(UInt64, 0x1.e400000000000p-1),  # i=82
    reinterpret(UInt64, 0x1.e200000000000p-1),  # i=83
    reinterpret(UInt64, 0x1.de00000000000p-1),  # i=84
    reinterpret(UInt64, 0x1.da00000000000p-1),  # i=85
    reinterpret(UInt64, 0x1.d600000000000p-1),  # i=86
    reinterpret(UInt64, 0x1.d400000000000p-1),  # i=87
    reinterpret(UInt64, 0x1.d000000000000p-1),  # i=88
    reinterpret(UInt64, 0x1.cc00000000000p-1),  # i=89
    reinterpret(UInt64, 0x1.ca00000000000p-1),  # i=90
    reinterpret(UInt64, 0x1.c600000000000p-1),  # i=91
    reinterpret(UInt64, 0x1.c400000000000p-1),  # i=92
    reinterpret(UInt64, 0x1.c000000000000p-1),  # i=93
    reinterpret(UInt64, 0x1.be00000000000p-1),  # i=94
    reinterpret(UInt64, 0x1.ba00000000000p-1),  # i=95
    reinterpret(UInt64, 0x1.b800000000000p-1),  # i=96
    reinterpret(UInt64, 0x1.b400000000000p-1),  # i=97
    reinterpret(UInt64, 0x1.b200000000000p-1),  # i=98
    reinterpret(UInt64, 0x1.ae00000000000p-1),  # i=99
    reinterpret(UInt64, 0x1.ac00000000000p-1),  # i=100
    reinterpret(UInt64, 0x1.aa00000000000p-1),  # i=101
    reinterpret(UInt64, 0x1.a600000000000p-1),  # i=102
    reinterpret(UInt64, 0x1.a400000000000p-1),  # i=103
    reinterpret(UInt64, 0x1.a000000000000p-1),  # i=104
    reinterpret(UInt64, 0x1.9e00000000000p-1),  # i=105
    reinterpret(UInt64, 0x1.9c00000000000p-1),  # i=106
    reinterpret(UInt64, 0x1.9a00000000000p-1),  # i=107
    reinterpret(UInt64, 0x1.9600000000000p-1),  # i=108
    reinterpret(UInt64, 0x1.9400000000000p-1),  # i=109
    reinterpret(UInt64, 0x1.9200000000000p-1),  # i=110
    reinterpret(UInt64, 0x1.9000000000000p-1),  # i=111
    reinterpret(UInt64, 0x1.8c00000000000p-1),  # i=112
    reinterpret(UInt64, 0x1.8a00000000000p-1),  # i=113
    reinterpret(UInt64, 0x1.8800000000000p-1),  # i=114
    reinterpret(UInt64, 0x1.8600000000000p-1),  # i=115
    reinterpret(UInt64, 0x1.8400000000000p-1),  # i=116
    reinterpret(UInt64, 0x1.8200000000000p-1),  # i=117
    reinterpret(UInt64, 0x1.7e00000000000p-1),  # i=118
    reinterpret(UInt64, 0x1.7c00000000000p-1),  # i=119
    reinterpret(UInt64, 0x1.7a00000000000p-1),  # i=120
    reinterpret(UInt64, 0x1.7800000000000p-1),  # i=121
    reinterpret(UInt64, 0x1.7600000000000p-1),  # i=122
    reinterpret(UInt64, 0x1.7400000000000p-1),  # i=123
    reinterpret(UInt64, 0x1.7200000000000p-1),  # i=124
    reinterpret(UInt64, 0x1.7000000000000p-1),  # i=125
    reinterpret(UInt64, 0x1.6e00000000000p-1),  # i=126
    reinterpret(UInt64, 0x1.6c00000000000p-1),  # i=127
)

const _POW_LOG_TAB_LOGC = (
    reinterpret(UInt64, -0x1.62c82f2b9c800p-2),  # i=0
    reinterpret(UInt64, -0x1.5d1bdbf580800p-2),  # i=1
    reinterpret(UInt64, -0x1.5767717455800p-2),  # i=2
    reinterpret(UInt64, -0x1.51aad872df800p-2),  # i=3
    reinterpret(UInt64, -0x1.4be5f95777800p-2),  # i=4
    reinterpret(UInt64, -0x1.4618bc21c6000p-2),  # i=5
    reinterpret(UInt64, -0x1.404308686a800p-2),  # i=6
    reinterpret(UInt64, -0x1.3a64c55694800p-2),  # i=7
    reinterpret(UInt64, -0x1.347dd9a988000p-2),  # i=8
    reinterpret(UInt64, -0x1.2e8e2bae12000p-2),  # i=9
    reinterpret(UInt64, -0x1.2895a13de8800p-2),  # i=10
    reinterpret(UInt64, -0x1.2895a13de8800p-2),  # i=11
    reinterpret(UInt64, -0x1.22941fbcf7800p-2),  # i=12
    reinterpret(UInt64, -0x1.1c898c1699800p-2),  # i=13
    reinterpret(UInt64, -0x1.1675cababa800p-2),  # i=14
    reinterpret(UInt64, -0x1.1058bf9ae4800p-2),  # i=15
    reinterpret(UInt64, -0x1.0a324e2739000p-2),  # i=16
    reinterpret(UInt64, -0x1.0402594b4d000p-2),  # i=17
    reinterpret(UInt64, -0x1.0402594b4d000p-2),  # i=18
    reinterpret(UInt64, -0x1.fb9186d5e4000p-3),  # i=19
    reinterpret(UInt64, -0x1.ef0adcbdc6000p-3),  # i=20
    reinterpret(UInt64, -0x1.e27076e2af000p-3),  # i=21
    reinterpret(UInt64, -0x1.d5c216b4fc000p-3),  # i=22
    reinterpret(UInt64, -0x1.c8ff7c79aa000p-3),  # i=23
    reinterpret(UInt64, -0x1.c8ff7c79aa000p-3),  # i=24
    reinterpret(UInt64, -0x1.bc286742d9000p-3),  # i=25
    reinterpret(UInt64, -0x1.af3c94e80c000p-3),  # i=26
    reinterpret(UInt64, -0x1.a23bc1fe2b000p-3),  # i=27
    reinterpret(UInt64, -0x1.a23bc1fe2b000p-3),  # i=28
    reinterpret(UInt64, -0x1.9525a9cf45000p-3),  # i=29
    reinterpret(UInt64, -0x1.87fa06520d000p-3),  # i=30
    reinterpret(UInt64, -0x1.7ab890210e000p-3),  # i=31
    reinterpret(UInt64, -0x1.7ab890210e000p-3),  # i=32
    reinterpret(UInt64, -0x1.6d60fe719d000p-3),  # i=33
    reinterpret(UInt64, -0x1.5ff3070a79000p-3),  # i=34
    reinterpret(UInt64, -0x1.5ff3070a79000p-3),  # i=35
    reinterpret(UInt64, -0x1.526e5e3a1b000p-3),  # i=36
    reinterpret(UInt64, -0x1.44d2b6ccb8000p-3),  # i=37
    reinterpret(UInt64, -0x1.44d2b6ccb8000p-3),  # i=38
    reinterpret(UInt64, -0x1.371fc201e9000p-3),  # i=39
    reinterpret(UInt64, -0x1.29552f81ff000p-3),  # i=40
    reinterpret(UInt64, -0x1.1b72ad52f6000p-3),  # i=41
    reinterpret(UInt64, -0x1.1b72ad52f6000p-3),  # i=42
    reinterpret(UInt64, -0x1.0d77e7cd09000p-3),  # i=43
    reinterpret(UInt64, -0x1.0d77e7cd09000p-3),  # i=44
    reinterpret(UInt64, -0x1.fec9131dbe000p-4),  # i=45
    reinterpret(UInt64, -0x1.e27076e2b0000p-4),  # i=46
    reinterpret(UInt64, -0x1.e27076e2b0000p-4),  # i=47
    reinterpret(UInt64, -0x1.c5e548f5bc000p-4),  # i=48
    reinterpret(UInt64, -0x1.a926d3a4ae000p-4),  # i=49
    reinterpret(UInt64, -0x1.a926d3a4ae000p-4),  # i=50
    reinterpret(UInt64, -0x1.8c345d631a000p-4),  # i=51
    reinterpret(UInt64, -0x1.8c345d631a000p-4),  # i=52
    reinterpret(UInt64, -0x1.6f0d28ae56000p-4),  # i=53
    reinterpret(UInt64, -0x1.51b073f062000p-4),  # i=54
    reinterpret(UInt64, -0x1.51b073f062000p-4),  # i=55
    reinterpret(UInt64, -0x1.341d7961be000p-4),  # i=56
    reinterpret(UInt64, -0x1.341d7961be000p-4),  # i=57
    reinterpret(UInt64, -0x1.16536eea38000p-4),  # i=58
    reinterpret(UInt64, -0x1.f0a30c0118000p-5),  # i=59
    reinterpret(UInt64, -0x1.f0a30c0118000p-5),  # i=60
    reinterpret(UInt64, -0x1.b42dd71198000p-5),  # i=61
    reinterpret(UInt64, -0x1.b42dd71198000p-5),  # i=62
    reinterpret(UInt64, -0x1.77458f632c000p-5),  # i=63
    reinterpret(UInt64, -0x1.77458f632c000p-5),  # i=64
    reinterpret(UInt64, -0x1.39e87b9fec000p-5),  # i=65
    reinterpret(UInt64, -0x1.39e87b9fec000p-5),  # i=66
    reinterpret(UInt64, -0x1.f829b0e780000p-6),  # i=67
    reinterpret(UInt64, -0x1.f829b0e780000p-6),  # i=68
    reinterpret(UInt64, -0x1.7b91b07d58000p-6),  # i=69
    reinterpret(UInt64, -0x1.fc0a8b0fc0000p-7),  # i=70
    reinterpret(UInt64, -0x1.fc0a8b0fc0000p-7),  # i=71
    reinterpret(UInt64, -0x1.fe02a6b100000p-8),  # i=72
    reinterpret(UInt64, -0x1.fe02a6b100000p-8),  # i=73
    reinterpret(UInt64, 0x0.0000000000000p+0),  # i=74
    reinterpret(UInt64, 0x0.0000000000000p+0),  # i=75
    reinterpret(UInt64, 0x1.0101575890000p-7),  # i=76
    reinterpret(UInt64, 0x1.0205658938000p-6),  # i=77
    reinterpret(UInt64, 0x1.8492528c90000p-6),  # i=78
    reinterpret(UInt64, 0x1.0415d89e74000p-5),  # i=79
    reinterpret(UInt64, 0x1.466aed42e0000p-5),  # i=80
    reinterpret(UInt64, 0x1.894aa149fc000p-5),  # i=81
    reinterpret(UInt64, 0x1.ccb73cdddc000p-5),  # i=82
    reinterpret(UInt64, 0x1.eea31c006c000p-5),  # i=83
    reinterpret(UInt64, 0x1.1973bd1466000p-4),  # i=84
    reinterpret(UInt64, 0x1.3bdf5a7d1e000p-4),  # i=85
    reinterpret(UInt64, 0x1.5e95a4d97a000p-4),  # i=86
    reinterpret(UInt64, 0x1.700d30aeac000p-4),  # i=87
    reinterpret(UInt64, 0x1.9335e5d594000p-4),  # i=88
    reinterpret(UInt64, 0x1.b6ac88dad6000p-4),  # i=89
    reinterpret(UInt64, 0x1.c885801bc4000p-4),  # i=90
    reinterpret(UInt64, 0x1.ec739830a2000p-4),  # i=91
    reinterpret(UInt64, 0x1.fe89139dbe000p-4),  # i=92
    reinterpret(UInt64, 0x1.1178e8227e000p-3),  # i=93
    reinterpret(UInt64, 0x1.1aa2b7e23f000p-3),  # i=94
    reinterpret(UInt64, 0x1.2d1610c868000p-3),  # i=95
    reinterpret(UInt64, 0x1.365fcb0159000p-3),  # i=96
    reinterpret(UInt64, 0x1.4913d8333b000p-3),  # i=97
    reinterpret(UInt64, 0x1.527e5e4a1b000p-3),  # i=98
    reinterpret(UInt64, 0x1.6574ebe8c1000p-3),  # i=99
    reinterpret(UInt64, 0x1.6f0128b757000p-3),  # i=100
    reinterpret(UInt64, 0x1.7898d85445000p-3),  # i=101
    reinterpret(UInt64, 0x1.8beafeb390000p-3),  # i=102
    reinterpret(UInt64, 0x1.95a5adcf70000p-3),  # i=103
    reinterpret(UInt64, 0x1.a93ed3c8ae000p-3),  # i=104
    reinterpret(UInt64, 0x1.b31d8575bd000p-3),  # i=105
    reinterpret(UInt64, 0x1.bd087383be000p-3),  # i=106
    reinterpret(UInt64, 0x1.c6ffbc6f01000p-3),  # i=107
    reinterpret(UInt64, 0x1.db13db0d49000p-3),  # i=108
    reinterpret(UInt64, 0x1.e530effe71000p-3),  # i=109
    reinterpret(UInt64, 0x1.ef5ade4dd0000p-3),  # i=110
    reinterpret(UInt64, 0x1.f991c6cb3b000p-3),  # i=111
    reinterpret(UInt64, 0x1.07138604d5800p-2),  # i=112
    reinterpret(UInt64, 0x1.0c42d67616000p-2),  # i=113
    reinterpret(UInt64, 0x1.1178e8227e800p-2),  # i=114
    reinterpret(UInt64, 0x1.16b5ccbacf800p-2),  # i=115
    reinterpret(UInt64, 0x1.1bf99635a6800p-2),  # i=116
    reinterpret(UInt64, 0x1.214456d0eb800p-2),  # i=117
    reinterpret(UInt64, 0x1.2bef07cdc9000p-2),  # i=118
    reinterpret(UInt64, 0x1.314f1e1d36000p-2),  # i=119
    reinterpret(UInt64, 0x1.36b6776be1000p-2),  # i=120
    reinterpret(UInt64, 0x1.3c25277333000p-2),  # i=121
    reinterpret(UInt64, 0x1.419b423d5e800p-2),  # i=122
    reinterpret(UInt64, 0x1.4718dc271c800p-2),  # i=123
    reinterpret(UInt64, 0x1.4c9e09e173000p-2),  # i=124
    reinterpret(UInt64, 0x1.522ae0738a000p-2),  # i=125
    reinterpret(UInt64, 0x1.57bf753c8d000p-2),  # i=126
    reinterpret(UInt64, 0x1.5d5bddf596000p-2),  # i=127
)

const _POW_LOG_TAB_TAIL = (
    reinterpret(UInt64, 0x1.ab42428375680p-48),  # i=0
    reinterpret(UInt64, -0x1.ca508d8e0f720p-46),  # i=1
    reinterpret(UInt64, -0x1.362a4d5b6506dp-45),  # i=2
    reinterpret(UInt64, -0x1.684e49eb067d5p-49),  # i=3
    reinterpret(UInt64, -0x1.41b6993293ee0p-47),  # i=4
    reinterpret(UInt64, 0x1.3d82f484c84ccp-46),  # i=5
    reinterpret(UInt64, 0x1.c42f3ed820b3ap-50),  # i=6
    reinterpret(UInt64, 0x1.0b1c686519460p-45),  # i=7
    reinterpret(UInt64, 0x1.5594dd4c58092p-45),  # i=8
    reinterpret(UInt64, 0x1.67b1e99b72bd8p-45),  # i=9
    reinterpret(UInt64, 0x1.5ca14b6cfb03fp-46),  # i=10
    reinterpret(UInt64, 0x1.5ca14b6cfb03fp-46),  # i=11
    reinterpret(UInt64, -0x1.65a242853da76p-46),  # i=12
    reinterpret(UInt64, -0x1.fafbc68e75404p-46),  # i=13
    reinterpret(UInt64, 0x1.f1fc63382a8f0p-46),  # i=14
    reinterpret(UInt64, -0x1.6a8c4fd055a66p-45),  # i=15
    reinterpret(UInt64, -0x1.c6bee7ef4030ep-47),  # i=16
    reinterpret(UInt64, -0x1.036b89ef42d7fp-48),  # i=17
    reinterpret(UInt64, -0x1.036b89ef42d7fp-48),  # i=18
    reinterpret(UInt64, 0x1.d572aab993c87p-47),  # i=19
    reinterpret(UInt64, 0x1.b26b79c86af24p-45),  # i=20
    reinterpret(UInt64, -0x1.72f4f543fff10p-46),  # i=21
    reinterpret(UInt64, 0x1.1ba91bbca681bp-45),  # i=22
    reinterpret(UInt64, 0x1.7794f689f8434p-45),  # i=23
    reinterpret(UInt64, 0x1.7794f689f8434p-45),  # i=24
    reinterpret(UInt64, 0x1.94eb0318bb78fp-46),  # i=25
    reinterpret(UInt64, 0x1.a4e633fcd9066p-52),  # i=26
    reinterpret(UInt64, -0x1.58c64dc46c1eap-45),  # i=27
    reinterpret(UInt64, -0x1.58c64dc46c1eap-45),  # i=28
    reinterpret(UInt64, -0x1.ad1d904c1d4e3p-45),  # i=29
    reinterpret(UInt64, 0x1.bbdbf7fdbfa09p-45),  # i=30
    reinterpret(UInt64, 0x1.bdb9072534a58p-45),  # i=31
    reinterpret(UInt64, 0x1.bdb9072534a58p-45),  # i=32
    reinterpret(UInt64, -0x1.0e46aa3b2e266p-46),  # i=33
    reinterpret(UInt64, -0x1.e9e439f105039p-46),  # i=34
    reinterpret(UInt64, -0x1.e9e439f105039p-46),  # i=35
    reinterpret(UInt64, -0x1.0de8b90075b8fp-45),  # i=36
    reinterpret(UInt64, 0x1.70cc16135783cp-46),  # i=37
    reinterpret(UInt64, 0x1.70cc16135783cp-46),  # i=38
    reinterpret(UInt64, 0x1.178864d27543ap-48),  # i=39
    reinterpret(UInt64, -0x1.48d301771c408p-45),  # i=40
    reinterpret(UInt64, -0x1.e80a41811a396p-45),  # i=41
    reinterpret(UInt64, -0x1.e80a41811a396p-45),  # i=42
    reinterpret(UInt64, 0x1.a699688e85bf4p-47),  # i=43
    reinterpret(UInt64, 0x1.a699688e85bf4p-47),  # i=44
    reinterpret(UInt64, -0x1.575545ca333f2p-45),  # i=45
    reinterpret(UInt64, 0x1.a342c2af0003cp-45),  # i=46
    reinterpret(UInt64, 0x1.a342c2af0003cp-45),  # i=47
    reinterpret(UInt64, -0x1.d0c57585fbe06p-46),  # i=48
    reinterpret(UInt64, 0x1.53935e85baac8p-45),  # i=49
    reinterpret(UInt64, 0x1.53935e85baac8p-45),  # i=50
    reinterpret(UInt64, 0x1.37c294d2f5668p-46),  # i=51
    reinterpret(UInt64, 0x1.37c294d2f5668p-46),  # i=52
    reinterpret(UInt64, -0x1.69737c93373dap-45),  # i=53
    reinterpret(UInt64, 0x1.f025b61c65e57p-46),  # i=54
    reinterpret(UInt64, 0x1.f025b61c65e57p-46),  # i=55
    reinterpret(UInt64, 0x1.c5edaccf913dfp-45),  # i=56
    reinterpret(UInt64, 0x1.c5edaccf913dfp-45),  # i=57
    reinterpret(UInt64, 0x1.47c5e768fa309p-46),  # i=58
    reinterpret(UInt64, 0x1.d599e83368e91p-45),  # i=59
    reinterpret(UInt64, 0x1.d599e83368e91p-45),  # i=60
    reinterpret(UInt64, 0x1.c827ae5d6704cp-46),  # i=61
    reinterpret(UInt64, 0x1.c827ae5d6704cp-46),  # i=62
    reinterpret(UInt64, -0x1.cfc4634f2a1eep-45),  # i=63
    reinterpret(UInt64, -0x1.cfc4634f2a1eep-45),  # i=64
    reinterpret(UInt64, 0x1.502b7f526feaap-48),  # i=65
    reinterpret(UInt64, 0x1.502b7f526feaap-48),  # i=66
    reinterpret(UInt64, -0x1.980267c7e09e4p-45),  # i=67
    reinterpret(UInt64, -0x1.980267c7e09e4p-45),  # i=68
    reinterpret(UInt64, -0x1.88d5493faa639p-45),  # i=69
    reinterpret(UInt64, -0x1.f1e7cf6d3a69cp-50),  # i=70
    reinterpret(UInt64, -0x1.f1e7cf6d3a69cp-50),  # i=71
    reinterpret(UInt64, -0x1.9e23f0dda40e4p-46),  # i=72
    reinterpret(UInt64, -0x1.9e23f0dda40e4p-46),  # i=73
    reinterpret(UInt64, 0x0.0000000000000p+0),  # i=74
    reinterpret(UInt64, 0x0.0000000000000p+0),  # i=75
    reinterpret(UInt64, -0x1.0c76b999d2be8p-46),  # i=76
    reinterpret(UInt64, -0x1.3dc5b06e2f7d2p-45),  # i=77
    reinterpret(UInt64, -0x1.aa0ba325a0c34p-45),  # i=78
    reinterpret(UInt64, 0x1.111c05cf1d753p-47),  # i=79
    reinterpret(UInt64, -0x1.c167375bdfd28p-45),  # i=80
    reinterpret(UInt64, -0x1.97995d05a267dp-46),  # i=81
    reinterpret(UInt64, -0x1.a68f247d82807p-46),  # i=82
    reinterpret(UInt64, -0x1.e113e4fc93b7bp-47),  # i=83
    reinterpret(UInt64, -0x1.5325d560d9e9bp-45),  # i=84
    reinterpret(UInt64, 0x1.cc85ea5db4ed7p-45),  # i=85
    reinterpret(UInt64, -0x1.c69063c5d1d1ep-45),  # i=86
    reinterpret(UInt64, 0x1.c1e8da99ded32p-49),  # i=87
    reinterpret(UInt64, 0x1.3115c3abd47dap-45),  # i=88
    reinterpret(UInt64, -0x1.390802bf768e5p-46),  # i=89
    reinterpret(UInt64, 0x1.646d1c65aacd3p-45),  # i=90
    reinterpret(UInt64, -0x1.dc068afe645e0p-45),  # i=91
    reinterpret(UInt64, -0x1.534d64fa10afdp-45),  # i=92
    reinterpret(UInt64, 0x1.1ef78ce2d07f2p-45),  # i=93
    reinterpret(UInt64, 0x1.ca78e44389934p-45),  # i=94
    reinterpret(UInt64, 0x1.39d6ccb81b4a1p-47),  # i=95
    reinterpret(UInt64, 0x1.62fa8234b7289p-51),  # i=96
    reinterpret(UInt64, 0x1.5837954fdb678p-45),  # i=97
    reinterpret(UInt64, 0x1.633e8e5697dc7p-45),  # i=98
    reinterpret(UInt64, 0x1.9cf8b2c3c2e78p-46),  # i=99
    reinterpret(UInt64, -0x1.5118de59c21e1p-45),  # i=100
    reinterpret(UInt64, -0x1.c661070914305p-46),  # i=101
    reinterpret(UInt64, -0x1.73d54aae92cd1p-47),  # i=102
    reinterpret(UInt64, 0x1.7f22858a0ff6fp-47),  # i=103
    reinterpret(UInt64, -0x1.8724350562169p-45),  # i=104
    reinterpret(UInt64, -0x1.c358d4eace1aap-47),  # i=105
    reinterpret(UInt64, -0x1.d4bc4595412b6p-45),  # i=106
    reinterpret(UInt64, -0x1.1ec72c5962bd2p-48),  # i=107
    reinterpret(UInt64, -0x1.aff2af715b035p-45),  # i=108
    reinterpret(UInt64, 0x1.212276041f430p-51),  # i=109
    reinterpret(UInt64, -0x1.a211565bb8e11p-51),  # i=110
    reinterpret(UInt64, 0x1.bcbecca0cdf30p-46),  # i=111
    reinterpret(UInt64, 0x1.89cdb16ed4e91p-48),  # i=112
    reinterpret(UInt64, 0x1.7188b163ceae9p-45),  # i=113
    reinterpret(UInt64, -0x1.c210e63a5f01cp-45),  # i=114
    reinterpret(UInt64, 0x1.b9acdf7a51681p-45),  # i=115
    reinterpret(UInt64, 0x1.ca6ed5147bdb7p-45),  # i=116
    reinterpret(UInt64, 0x1.a87deba46baeap-47),  # i=117
    reinterpret(UInt64, 0x1.a9cfa4a5004f4p-45),  # i=118
    reinterpret(UInt64, -0x1.8e27ad3213cb8p-45),  # i=119
    reinterpret(UInt64, 0x1.16ecdb0f177c8p-46),  # i=120
    reinterpret(UInt64, 0x1.83b54b606bd5cp-46),  # i=121
    reinterpret(UInt64, 0x1.8e436ec90e09dp-47),  # i=122
    reinterpret(UInt64, -0x1.f27ce0967d675p-45),  # i=123
    reinterpret(UInt64, -0x1.e20891b0ad8a4p-45),  # i=124
    reinterpret(UInt64, 0x1.ebe708164c759p-45),  # i=125
    reinterpret(UInt64, 0x1.fadedee5d40efp-46),  # i=126
    reinterpret(UInt64, -0x1.a0b2a08a465dcp-47),  # i=127
)

# Stride-1 lookup helpers — each table is 128-element, indexed directly by
# `i_idx ∈ [0, 128)`. Avoids the stride-3 lookup pattern that previously
# triggered Bennett's `_lower_load_legacy!` 0-wires-allocated failure.
@inline _pow_log_invc(i::Int)::UInt64 = (let T = _POW_LOG_TAB_INVC; @inbounds T[i + 1]; end)
@inline _pow_log_logc(i::Int)::UInt64 = (let T = _POW_LOG_TAB_LOGC; @inbounds T[i + 1]; end)
@inline _pow_log_tail(i::Int)::UInt64 = (let T = _POW_LOG_TAB_TAIL; @inbounds T[i + 1]; end)


# Internal log_inline: computes (loghi, loglo) extended-precision natural
# log of |x|. Bennett's reversible-compile lowering doesn't currently
# handle Tuple{UInt64,UInt64} returns through inlined functions
# (`_lower_load_legacy!: load ... but only 0 wires available`); the
# log_inline body is therefore inlined directly into `soft_pow` rather
# than factored as a helper. The Arm pow.c `log_inline` body is preserved
# verbatim — see `_pow_log_inline_ref` below for the reference structure
# this inlining mirrors.
#
# Reference structure (NOT compiled — exists only for documentation /
# unit-testing of the math via Float64 round-tripping):
#   1. tmp = ix - OFF; i = top-7-bits-of-tmp; k = arith-shift-52(tmp)
#   2. iz = ix - (tmp & top-12-mask); z = bits→double(iz)
#   3. (invc, logc, logctail) = T[i]
#   4. r = fma(z, invc, -1.0)
#   5. kd = (double) k
#   6. t1 = kd·Ln2hi + logc; t2 = t1+r; lo1 = kd·Ln2lo + logctail;
#      lo2 = (t1-t2) + r — Cody-Waite split for cancellation.
#   7. ar = A0·r; ar2 = r·ar; ar3 = r·ar2
#   8. hi = t2 + ar2; lo3 = fma(ar, r, -ar2); lo4 = (t2-hi) + ar2
#   9. p = ar3 · (A1 + r·A2 + ar2·(A3 + r·A4 + ar2·(A5 + r·A6)))
#  10. lo = lo1 + lo2 + lo3 + lo4 + p
#  11. y = hi + lo; tail = (hi - y) + lo
#  Return (y, tail).

# ── _pow_checkint(iy) -> 0 (not int), 1 (odd int), 2 (even int) ────────
# Branchless. The C version uses early-return; we compute all conditions
# as flags and pick at the end. Used only for negative-x inputs to detect
# the odd-y sign-flip rule.
@inline function _pow_checkint(iy::UInt64)::UInt64
    e = (iy >> 52) & UInt64(0x7FF)   # biased exponent of |y|
    # |y| < 1.0 → e < 0x3FF  →  not integer
    not_int_low = e < UInt64(0x3FF)
    # |y| ≥ 2^53 → e > 0x3FF + 52 → so big it's necessarily even
    even_big = e > UInt64(0x3FF + 52)
    # Otherwise: check if low bits of mantissa are zero (integer) and
    # whether the lowest integer bit is 1 (odd).
    # Number of bits below the binary point: 0x3FF + 52 - e
    shift_amount = (UInt64(0x3FF + 52) - e) & UInt64(0x3F)  # mod 64 to be safe
    fract_mask = (UInt64(1) << shift_amount) - UInt64(1)
    has_fract = (iy & fract_mask) != UInt64(0)
    low_int_bit = (iy >> shift_amount) & UInt64(1)

    # Result selector:
    #   not_int_low → 0
    #   even_big    → 2
    #   else has_fract → 0
    #   else low_int_bit == 1 → 1, else 2
    in_range_result = ifelse(has_fract, UInt64(0),
                       ifelse(low_int_bit == UInt64(1), UInt64(1), UInt64(2)))
    result = ifelse(even_big, UInt64(2), in_range_result)
    result = ifelse(not_int_low, UInt64(0), result)
    return result
end

# ── Internal exp_inline: computes sign·exp(x + xtail) ──────────────────
#
# Precondition: |xtail| < 2^-8/N and |xtail| ≤ |x|. `sign_bias` is either
# 0 (positive result) or 0x80<<EXP_TABLE_BITS (negative result, for the
# negative-x odd-int-y case in pow); poked into the exp table-index sum.
#
# Algorithm (Arm pow.c exp_inline):
#   z = InvLn2N · x
#   kd = z + Shift; ki = asuint64(kd); kd -= Shift
#   r = x + kd · NegLn2hiN + kd · NegLn2loN + xtail
#   idx = 2·(ki & 0x7F)
#   top = (ki + sign_bias) << 45
#   tail = T[idx]; sbits = T[idx+1] + top
#   r2 = r·r
#   tmp = tail + r + r²·(C2 + r·C3) + r⁴·(C4 + r·C5)
#   if abstop == 0:    # extreme range → underflow/overflow specialcase
#       return _pow_exp_specialcase(tmp, sbits, ki)
#   scale = asdouble(sbits)
#   return scale + scale·tmp
#
# Constants reused from fexp.jl: _INVLN2N_BITS, _EXP_SHIFT_BITS,
# _NEGLN2HIN_BITS, _NEGLN2LON_BITS, _EXP_C2..C5, _EXP_TAB, _ONE_BITS,
# _exp_specialcase_underflow.

const _POW_EXP_SIGN_BIAS = UInt64(0x800) << 7   # 0x40000 — bit 18 of ki

# Pre-computed sbits exponent shifts for the over/underflow specialcases.
# The +1009 / +1022 biases bring an out-of-range sbits BACK into the normal
# Float64 exponent range so the soft_fmul/soft_fadd computations don't
# overflow themselves; we then scale the result back at the end via
# multiply by 2^1009 (overflow) or 2^-1022 (underflow).
const _POW_EXP_OFLOW_BIAS_SHIFT  = UInt64(1009) << 52
const _POW_EXP_UFLOW_BIAS_SHIFT  = UInt64(1022) << 52
const _POW_EXP_2_P1009  = reinterpret(UInt64, 0x1p1009)
const _POW_EXP_2_M1022  = reinterpret(UInt64, 0x1p-1022)

# Overflow specialcase (Arm pow.c specialcase, k > 0 branch). Brings sbits
# back into normal range by subtracting 1009 from the biased exponent,
# computes `scale + scale·tmp` in that range, then scales back up by 2^1009.
# If the math is genuinely overflow, the final multiply produces +Inf
# correctly; otherwise the result is the precise answer.
@inline function _pow_exp_specialcase_overflow(sbits::UInt64, tmp::UInt64)::UInt64
    sbits_norm = sbits - _POW_EXP_OFLOW_BIAS_SHIFT
    scale_tmp  = soft_fmul(sbits_norm, tmp)
    y          = soft_fadd(sbits_norm, scale_tmp)
    return soft_fmul(y, _POW_EXP_2_P1009)
end

# Underflow specialcase (Arm pow.c specialcase, k < 0 branch). The existing
# `_exp_specialcase_underflow` defined in fexp.jl is the precise port of
# Arm's k<0 path: it does the (hi, lo) Dekker reconstruction `lo = scale -
# y + scale·tmp; hi = 1 + y; ...` for the `|y| < 1.0` case (subnormal
# output) and falls through to `y · 2^-1022` for non-subnormal output.
# Reused here verbatim — mirroring the soft_exp pattern and avoiding code
# duplication. The naïve version (sbits-bias, mul, scale-down) was 14-132
# ULP off in the subnormal-output region because it skipped the
# reconstruction step.
const _pow_exp_specialcase_underflow = _exp_specialcase_underflow

@inline function _pow_exp_inline(x::UInt64, xtail::UInt64, sign_bias::UInt64)::UInt64
    # abstop = top12(x) & 0x7FF — captures the magnitude exponent only.
    abstop = (x >> 52) & UInt64(0x7FF)
    sx     = x >> 63

    # Zone classification — branchless flags. abstop boundaries:
    #   < 0x3C9 (= top12(2^-54)):   tiny-x → return ±1
    #   ∈ [0x3C9, 0x408):           normal range, main path
    #   ∈ [0x408, 0x409):           "extreme but recoverable" → specialcase
    #   ≥ 0x409 (= top12(1024.0)):  definite over/underflow, return ±Inf or ±0
    is_tiny           = abstop < UInt64(0x3C9)
    is_extreme        = abstop >= UInt64(0x408)
    is_def_oflow_uflow = abstop >= UInt64(0x409)

    # Tiny-input alternative: ±1 (sign from sign_bias).
    one_or_neg_one = ifelse(sign_bias != UInt64(0),
                            reinterpret(UInt64, -1.0),
                            _POW_LOG_ONE_BITS)

    # Definite over/underflow: x ≥ 1024 → +Inf; x ≤ -1024 → +0;
    # sign_bias flips both.
    def_path_pos  = ifelse(sign_bias != UInt64(0), _POW_NINF_BITS, _POW_PINF_BITS)
    def_path_neg  = ifelse(sign_bias != UInt64(0), UInt64(0x8000000000000000), UInt64(0))
    def_path      = ifelse(sx != UInt64(0), def_path_neg, def_path_pos)

    # Range reduction (always computed): x = ln2/N · k + r, N = 128.
    z      = soft_fmul(x, _INVLN2N_BITS)
    kd_pre = soft_fadd(z, _EXP_SHIFT_BITS)
    ki     = kd_pre
    kd     = soft_fsub(kd_pre, _EXP_SHIFT_BITS)
    t1     = soft_fmul(kd, _NEGLN2HIN_BITS)
    r_a    = soft_fadd(x, t1)
    t2     = soft_fmul(kd, _NEGLN2LON_BITS)
    r_b    = soft_fadd(r_a, t2)
    r      = soft_fadd(r_b, xtail)   # add the extended-precision tail

    # Table lookup. The `(ki + sign_bias) << 45` integer addition pokes the
    # sign bit through the IEEE exponent field — Arm's branchless way of
    # implementing the sign rule for negative-x odd-int-y in pow. For
    # extreme |x|, ki has bits past position 19 which would shift past
    # bit 64 and produce nonsense; that case is caught by the specialcase
    # paths below where sbits is rebuilt with the correct exponent bias.
    j_idx     = Int(ki & UInt64(0x7F))
    tail_e    = _exp_tab_lookup(2 * j_idx)
    sbits_lo  = _exp_tab_lookup(2 * j_idx + 1)
    top       = (ki + sign_bias) << 45
    sbits     = sbits_lo + top

    # Polynomial: tmp = tail + r + r²·(C2 + r·C3) + r⁴·(C4 + r·C5).
    r2     = soft_fmul(r, r)
    rC3    = soft_fmul(r, _EXP_C3)
    C2_rC3 = soft_fadd(_EXP_C2, rC3)
    rC5    = soft_fmul(r, _EXP_C5)
    C4_rC5 = soft_fadd(_EXP_C4, rC5)
    q1     = soft_fmul(r2, C2_rC3)
    r4     = soft_fmul(r2, r2)
    q2     = soft_fmul(r4, C4_rC5)
    tail_r = soft_fadd(tail_e, r)
    s2     = soft_fadd(tail_r, q1)
    tmp    = soft_fadd(s2, q2)

    # ── Three result candidates, all computed unconditionally ─────────
    # (1) Main path: scale + scale·tmp where scale comes directly from sbits.
    scale_tmp = soft_fmul(sbits, tmp)
    main_res  = soft_fadd(sbits, scale_tmp)
    # (2) Overflow specialcase: handles |ehi| ∈ [512, 1024) with positive sign.
    oflow_res = _pow_exp_specialcase_overflow(sbits, tmp)
    # (3) Underflow specialcase: handles same range with negative sign,
    # AND the existing subnormal-output range. Same flow either way —
    # the existing _exp_specialcase_underflow does the same algorithm
    # but is calibrated to the soft_exp subnormal-output dispatch trigger;
    # this _pow_exp_specialcase_underflow is the unbiased variant Arm
    # pow.c uses, applicable to the wider (-1024, -708) window.
    uflow_res = _pow_exp_specialcase_underflow(sbits, tmp)

    # Pick the specialcase based on sign of x.
    specialcase_res = ifelse(sx != UInt64(0), uflow_res, oflow_res)

    # Result selection — last-write-wins, applied LOW priority first:
    #   normal-range → main_res
    #   extreme-but-recoverable → specialcase (over/under by sign)
    #   definite over/under → def_path
    #   tiny → ±1
    result = main_res
    result = ifelse(is_extreme,          specialcase_res, result)
    result = ifelse(is_def_oflow_uflow,  def_path,        result)
    result = ifelse(is_tiny,             one_or_neg_one,  result)
    return result
end

# ── soft_pow main entry ────────────────────────────────────────────────

const _POW_PINF_BITS = UInt64(0x7FF0000000000000)
const _POW_NINF_BITS = UInt64(0xFFF0000000000000)

"""
    soft_pow(a::UInt64, b::UInt64) -> UInt64

IEEE 754 double-precision power function `pow(x, y) = x^y` on raw bit
patterns. **≤2 ULP vs `Base.:^`** across the full IEEE input domain.
Branchless integer arithmetic for special-case dispatch + soft_f*
primitives for the polynomial body. Faithful port of Arm Optimized
Routines / musl `src/math/pow.c` (2018, MIT-licensed).

Reference accuracy (Arm/musl): worst-case 0.54 ULP. Bennett practical
target absorbs the soft_f* rounding into a ≤2 ULP window.

Special cases (POSIX/C99-compliant — distinct from IEEE 754-2008 powr):
- pow(x, ±0)         = 1.0  (always, even for x = NaN per C99)
- pow(±1, y)         = 1.0  (always)
- pow(NaN, y)        = NaN  for y ≠ 0
- pow(x, NaN)        = NaN
- pow(±0, y<0)       = +Inf (or -Inf if y is odd integer, sign rule)
- pow(±0, y>0)       = +0   (or -0 if y is odd integer)
- pow(-1, ±Inf)      = 1.0
- pow(|x|<1, +Inf)   = +0;     pow(|x|<1, -Inf) = +Inf
- pow(|x|>1, +Inf)   = +Inf;   pow(|x|>1, -Inf) = +0
- pow(+Inf, y<0)     = +0;     pow(+Inf, y>0)   = +Inf
- pow(-Inf, y)       = sign-flipped per odd-int rule
- pow(x<0, non-int y) = NaN  (InvalidOp)

For float-typed integer y, the `_pow_checkint` helper distinguishes
0 (not integer), 1 (odd int), 2 (even int) branchlessly. Negative x
combined with odd-int y triggers `sign_bias` poked into the table-
index of `_pow_exp_inline`, flipping the sign of the result.
"""
@inline function soft_pow(a::UInt64, b::UInt64)::UInt64
    ix = a
    iy = b

    # Decompose for special-case detection.
    sx = ix >> 63
    sy = iy >> 63
    abs_ix = ix & UInt64(0x7FFFFFFFFFFFFFFF)
    abs_iy = iy & UInt64(0x7FFFFFFFFFFFFFFF)

    # Top-12 bits of |x| and |y| (matches Arm's top12(x) & 0x7ff).
    topx = (abs_ix >> 52) & UInt64(0x7FF)
    topy_full = (iy >> 52) & UInt64(0x7FF)   # signed top12 (Arm masks separately)

    # ── Detect special territory (ANY of the following conditions) ────
    # Arm: topx - 1 >= 0x7ff - 1 (i.e. topx == 0 → subnormal/0, topx ≥ 0x7ff → Inf/NaN)
    x_special = (topx - UInt64(1)) >= UInt64(0x7FF - 1)
    # Arm: topy & 0x7ff - 0x3be >= 0x43e - 0x3be (i.e. |y| < 2^-65 OR |y| ≥ 2^63 OR y NaN)
    y_special = (topy_full - UInt64(0x3BE)) >= UInt64(0x43E - 0x3BE)

    # ── Frontline special-case flags (each independent of others) ──────
    # zeroinfnan(z): 2*z - 1 >= 2*Inf_bits - 1 (catches 0/Inf/NaN)
    zeroinfnan_y = (UInt64(2) * abs_iy) >= (UInt64(2) * _POW_PINF_BITS)
    zeroinfnan_x = (UInt64(2) * abs_ix) >= (UInt64(2) * _POW_PINF_BITS)
    y_is_nan = (topy_full == UInt64(0x7FF)) & ((iy & FRAC_MASK) != UInt64(0))
    x_is_nan = (topx == UInt64(0x7FF)) & ((ix & FRAC_MASK) != UInt64(0))
    y_is_zero = abs_iy == UInt64(0)
    y_is_inf  = (topy_full == UInt64(0x7FF)) & ((iy & FRAC_MASK) == UInt64(0))
    x_is_zero = abs_ix == UInt64(0)
    x_is_inf  = (topx == UInt64(0x7FF)) & ((ix & FRAC_MASK) == UInt64(0))
    x_is_one  = ix == _POW_LOG_ONE_BITS                       # +1 only
    abs_x_is_one = abs_ix == _POW_LOG_ONE_BITS                 # ±1
    x_negative = (sx != UInt64(0)) & ~x_is_zero               # x < 0 (excl. -0)

    # checkint(iy) for negative-x sign rule
    yint = _pow_checkint(iy)
    y_is_odd_int  = yint == UInt64(1)
    y_is_even_int = yint == UInt64(2)
    y_is_int      = (yint == UInt64(1)) | (yint == UInt64(2))

    # ── Subnormal-x normalization: re-encode as if it were normal ─────
    # Arm: ix = asuint(x · 2^52); ix &= 0x7fff...; ix -= 52<<52.
    # We use _sf_normalize_to_bit52 then strip sign and adjust exp.
    x_subnormal = (topx == UInt64(0)) & ~x_is_zero
    fa_in = ix & FRAC_MASK
    fa_norm_w_imp, e_norm = _sf_normalize_to_bit52(fa_in, Int64(1))
    fa_norm = fa_norm_w_imp & FRAC_MASK
    ea_eff_subnorm = reinterpret(UInt64, e_norm) & UInt64(0xFFFFFFFFFFFF)
    ix_norm_subnorm = (ea_eff_subnorm << 52) | fa_norm

    # Build absolute value of x for the main path, with subnormal pre-normalized.
    abs_x_for_log = ifelse(x_subnormal, ix_norm_subnorm, abs_ix)

    # ── Main path: hi+lo = log(|x|); ehi+elo = y · (hi+lo); exp_inline ─
    # sign_bias = SIGN_BIAS iff x_negative AND y_is_odd_int; else 0.
    sign_bias = ifelse(x_negative & y_is_odd_int, _POW_EXP_SIGN_BIAS, UInt64(0))

    # ── Inlined _pow_log_inline body (see commented reference above) ──
    # Tuple{UInt64,UInt64} returns don't lower through Bennett's
    # reversible compile pipeline; the log-inline math is unrolled here.
    # All locals prefixed with `_l_` to namespace away from soft_pow's
    # other intermediates.
    _l_ix       = abs_x_for_log
    _l_tmp      = _l_ix - _POW_LOG_OFF
    _l_i_idx    = Int((_l_tmp >> 45) & UInt64(0x7F))
    _l_k        = reinterpret(Int64, _l_tmp) >> 52
    _l_iz       = _l_ix - (_l_tmp & (UInt64(0xFFF) << 52))
    _l_z        = _l_iz

    _l_invc     = _pow_log_invc(_l_i_idx)
    _l_logc     = _pow_log_logc(_l_i_idx)
    _l_logctail = _pow_log_tail(_l_i_idx)

    _l_r        = soft_fma(_l_z, _l_invc, _POW_LOG_NEG_ONE)
    _l_kd       = soft_sitofp(reinterpret(UInt64, _l_k))

    _l_kd_ln2hi  = soft_fmul(_l_kd, _POW_LN2HI)
    _l_t1        = soft_fadd(_l_kd_ln2hi, _l_logc)
    _l_t2        = soft_fadd(_l_t1, _l_r)
    _l_kd_ln2lo  = soft_fmul(_l_kd, _POW_LN2LO)
    _l_lo1       = soft_fadd(_l_kd_ln2lo, _l_logctail)
    _l_t1_sub_t2 = soft_fsub(_l_t1, _l_t2)
    _l_lo2       = soft_fadd(_l_t1_sub_t2, _l_r)

    _l_ar        = soft_fmul(_POW_LOG_A0, _l_r)
    _l_ar2       = soft_fmul(_l_r, _l_ar)
    _l_ar3       = soft_fmul(_l_r, _l_ar2)

    _l_hi        = soft_fadd(_l_t2, _l_ar2)
    _l_neg_ar2   = soft_fneg(_l_ar2)
    _l_lo3       = soft_fma(_l_ar, _l_r, _l_neg_ar2)
    _l_t2_sub_hi = soft_fsub(_l_t2, _l_hi)
    _l_lo4       = soft_fadd(_l_t2_sub_hi, _l_ar2)

    _l_rA2       = soft_fmul(_l_r,  _POW_LOG_A2)
    _l_rA4       = soft_fmul(_l_r,  _POW_LOG_A4)
    _l_rA6       = soft_fmul(_l_r,  _POW_LOG_A6)
    _l_A5_rA6    = soft_fadd(_POW_LOG_A5, _l_rA6)
    _l_ar2_A5_rA6 = soft_fmul(_l_ar2, _l_A5_rA6)
    _l_A3_rA4    = soft_fadd(_POW_LOG_A3, _l_rA4)
    _l_inner_inner = soft_fadd(_l_A3_rA4, _l_ar2_A5_rA6)
    _l_ar2_inner_inner = soft_fmul(_l_ar2, _l_inner_inner)
    _l_A1_rA2    = soft_fadd(_POW_LOG_A1, _l_rA2)
    _l_inner     = soft_fadd(_l_A1_rA2, _l_ar2_inner_inner)
    _l_p         = soft_fmul(_l_ar3, _l_inner)

    _l_lo_a      = soft_fadd(_l_lo1, _l_lo2)
    _l_lo_b      = soft_fadd(_l_lo3, _l_lo4)
    _l_lo_ab     = soft_fadd(_l_lo_a, _l_lo_b)
    _l_lo        = soft_fadd(_l_lo_ab, _l_p)

    loghi        = soft_fadd(_l_hi, _l_lo)
    _l_hi_sub_y  = soft_fsub(_l_hi, loghi)
    loglo        = soft_fadd(_l_hi_sub_y, _l_lo)

    # ehi + elo = y · (loghi + loglo), via FMA (we have soft_fma):
    # ehi = y·loghi; elo = y·loglo + fma(y, loghi, -ehi)
    ehi      = soft_fmul(b, loghi)
    y_loglo  = soft_fmul(b, loglo)
    neg_ehi  = soft_fneg(ehi)
    fma_corr = soft_fma(b, loghi, neg_ehi)
    elo      = soft_fadd(y_loglo, fma_corr)

    main_result = _pow_exp_inline(ehi, elo, sign_bias)

    # ── Special-case overrides (last-write-wins; order is the inverse
    # priority — earlier overrides are clobbered by later ones if both
    # conditions hold). Order chosen to match the Arm priority where
    # `pow(±1, y) = 1` overrides everything except NaN propagation.

    # Default fallback for "weird" (x_special OR y_special) inputs that
    # don't get caught by the targeted overrides below: use Arm's
    # catchall `y * y` for the zeroinfnan_y residual case.
    y_squared = soft_fmul(b, b)
    x_squared = soft_fmul(a, a)
    neg_x_squared = soft_fneg(x_squared)

    # ifelse chain — highest-priority overrides go LAST.
    result = main_result

    # Overflow/underflow when |y| is huge but x ≠ ±1: |x|>1 && y>0 → Inf;
    # |x|>1 && y<0 → 0; |x|<1 && y>0 → 0; |x|<1 && y<0 → Inf.
    # Already handled inside _pow_exp_inline via is_overflow_range, but
    # we override for the y_is_inf case to catch the limits without
    # going through exp_inline's overflow path.
    abs_x_gt_one = (abs_ix > _POW_LOG_ONE_BITS) & ~x_is_inf
    abs_x_lt_one = (abs_ix < _POW_LOG_ONE_BITS) & ~x_is_zero

    # pow(±0, y<0) = +Inf (handle separately from x_is_inf which goes through main path)
    x0_yneg_oddint = x_is_zero & (sy != UInt64(0)) & y_is_odd_int
    x0_yneg_other  = x_is_zero & (sy != UInt64(0)) & ~y_is_odd_int
    x0_ypos_oddint = x_is_zero & (sy == UInt64(0)) & y_is_odd_int & ~y_is_zero
    x0_ypos_other  = x_is_zero & (sy == UInt64(0)) & ~y_is_odd_int & ~y_is_zero

    # pow(+Inf, ·)
    xpinf_yneg = x_is_inf & (sx == UInt64(0)) & (sy != UInt64(0)) & ~y_is_zero
    xpinf_ypos = x_is_inf & (sx == UInt64(0)) & (sy == UInt64(0)) & ~y_is_zero

    # pow(-Inf, ·): use odd-int rule on positive Inf result
    xninf_yneg_odd  = x_is_inf & (sx != UInt64(0)) & (sy != UInt64(0)) & y_is_odd_int
    xninf_yneg_even = x_is_inf & (sx != UInt64(0)) & (sy != UInt64(0)) & ~y_is_odd_int & ~y_is_zero
    xninf_ypos_odd  = x_is_inf & (sx != UInt64(0)) & (sy == UInt64(0)) & y_is_odd_int
    xninf_ypos_even = x_is_inf & (sx != UInt64(0)) & (sy == UInt64(0)) & ~y_is_odd_int & ~y_is_zero

    # pow(|x|<1, ±Inf) and pow(|x|>1, ±Inf)
    yinf_pos = y_is_inf & (sy == UInt64(0))
    yinf_neg = y_is_inf & (sy != UInt64(0))
    xlt1_yinfp = abs_x_lt_one & yinf_pos
    xlt1_yinfn = abs_x_lt_one & yinf_neg
    xgt1_yinfp = abs_x_gt_one & yinf_pos
    xgt1_yinfn = abs_x_gt_one & yinf_neg

    # pow(x<0, non-int y) = NaN
    x_neg_y_not_int = x_negative & ~y_is_int & ~y_is_zero & ~y_is_inf & ~x_is_zero & ~x_is_inf

    # Apply overrides — order matters; later wins.
    # Tier 4 (lowest): main_result is already in `result`.
    # Tier 3: overflow/underflow for ±Inf in y exponent
    result = ifelse(xlt1_yinfp, UInt64(0),       result)        # |x|<1 && y=+Inf → 0
    result = ifelse(xlt1_yinfn, _POW_PINF_BITS,  result)        # |x|<1 && y=-Inf → +Inf
    result = ifelse(xgt1_yinfp, _POW_PINF_BITS,  result)
    result = ifelse(xgt1_yinfn, UInt64(0),       result)
    # Tier 2: ±Inf in x with finite y handling
    result = ifelse(xpinf_ypos, _POW_PINF_BITS,  result)
    result = ifelse(xpinf_yneg, UInt64(0),       result)
    result = ifelse(xninf_ypos_even, _POW_PINF_BITS,  result)
    result = ifelse(xninf_ypos_odd,  _POW_NINF_BITS,  result)
    result = ifelse(xninf_yneg_even, UInt64(0),                  result)
    result = ifelse(xninf_yneg_odd,  UInt64(0x8000000000000000), result)
    # Tier 2: ±0 in x
    result = ifelse(x0_yneg_oddint, _POW_NINF_BITS, result)     # 0^(-odd) = -Inf? No: pow(+0, y<0) odd → +Inf; pow(-0, y<0) odd → -Inf
    # Wait: pow(+0, -3) = +Inf; pow(-0, -3) = -Inf. The C code: for x_is_zero+yneg+oddint, returns 1/(±0)^|odd| → ±Inf with sign of x.
    # Re-doing: if x = +0 → +Inf; if x = -0 → -Inf
    result = ifelse(x_is_zero & (sy != UInt64(0)) & y_is_odd_int & (sx != UInt64(0)),
                    _POW_NINF_BITS,   result)
    result = ifelse(x_is_zero & (sy != UInt64(0)) & y_is_odd_int & (sx == UInt64(0)),
                    _POW_PINF_BITS,   result)
    result = ifelse(x0_yneg_other,    _POW_PINF_BITS,             result)
    result = ifelse(x0_ypos_oddint,   ix & UInt64(0x8000000000000000),  result)  # ±0 sign of x
    result = ifelse(x0_ypos_other,    UInt64(0),                  result)
    # Tier 2: x<0, non-int y → NaN
    result = ifelse(x_neg_y_not_int,  QNAN,                       result)
    # Tier 1: NaN propagation — pow(NaN, ·) or pow(·, NaN) → NaN.
    # Applied BEFORE abs_x_is_one and y_is_zero overrides so those win
    # for `pow(±1, NaN)` and `pow(NaN, 0)` per POSIX / C99 / Arm pow.c.
    nan_propagated = ifelse(x_is_nan, ix | QUIET_BIT,
                     ifelse(y_is_nan, iy | QUIET_BIT, QNAN))
    result = ifelse(x_is_nan | y_is_nan, nan_propagated, result)
    # Tier 0 (highest): pow(±1, y) = 1.0 even for y = NaN; pow(x, ±0) = 1.0
    # even for x = NaN. Last in the chain so they override NaN propagation.
    result = ifelse(abs_x_is_one,     _POW_LOG_ONE_BITS,          result)
    result = ifelse(y_is_zero,        _POW_LOG_ONE_BITS,          result)
    return result
end

# ── soft_powi: integer-exponent power via binary squaring ────────────
#
# Faithful port of compiler-rt's `__powidf2` (lib/builtins/powidf2.c, MIT-
# licensed). Branchless 32-iteration squaring loop — `n` is treated as an
# Int32 (the LLVM `llvm.powi.f64.i32` intrinsic signature). Negative `n`
# computes via `1 / pow(a, |n|)` with the reciprocal taken at the end.
#
# Special cases (inherited from soft_fmul propagation):
# - `powi(a, 0)`     = 1.0   (any a, including NaN — matches C99)
# - `powi(NaN, n≠0)` = NaN
# - `powi(±Inf, n)`  follows sign rule from squaring chain
# - `powi(±0, n>0)`  = ±0 (sign by parity of n)
# - `powi(±0, n<0)`  = ±Inf via the final 1/result step
# - `powi(a, INT_MIN)` works correctly (no -INT_MIN overflow because we
#    never negate; the abs-via-shift trick uses arithmetic-right-shift).
"""
    soft_powi(a::UInt64, n::Int32) -> UInt64

IEEE 754 double-precision integer-exponent power `a^n` on raw bit
patterns. Branchless 32-iteration binary squaring. Faithful port of
compiler-rt's `__powidf2`.

For non-integer exponents, use `soft_pow(a, b)` — `soft_powi` is the
specialization for `llvm.powi.f64.i32` where the exponent arrives as
i32 from the LLVM frontend.
"""
@inline function soft_powi(a::UInt64, n::Int32)::UInt64
    # Sign of n: arithmetic right shift to get all-ones (n<0) or all-zeros (n>=0).
    n_neg = n < Int32(0)
    # |n| as UInt32 (handles INT_MIN correctly: abs(INT_MIN) = 2^31 representable
    # as UInt32, which is what we want for the squaring-loop iteration count).
    abs_n = ifelse(n_neg, reinterpret(UInt32, -n), reinterpret(UInt32, n))

    # Loop invariant: at iteration i, base = a^(2^i), result accumulates
    # bits of |n| via if-bit-set-multiply.
    result = _POW_LOG_ONE_BITS   # 1.0
    base   = a
    @inbounds for i in 0:31
        bit_set = ((abs_n >> UInt32(i)) & UInt32(1)) != UInt32(0)
        result = ifelse(bit_set, soft_fmul(result, base), result)
        # Square base for next iteration. The final iteration's square
        # is wasted work but keeps the loop branchless.
        base = soft_fmul(base, base)
    end

    # If n was negative, invert: result = 1.0 / result.
    one_over = soft_fdiv(_POW_LOG_ONE_BITS, result)
    return ifelse(n_neg, one_over, result)
end
