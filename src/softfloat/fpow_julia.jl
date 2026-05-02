"""
    soft_pow_julia(a::UInt64, b::UInt64) -> UInt64

Julia-faithful IEEE 754 binary64 `pow` on raw bit patterns. Bit-exact vs
`Base.:^(::Float64, ::Float64)` on FMA-capable hardware. Path A of
Bennett-jexo: line-for-line port of Julia's `^(::Float64, ::Float64)` from
`base/math.jl` (with `pow_body` from same file and `_log_ext` from
`base/special/log.jl`), with every `muladd` replaced by `soft_fma`.

Differs from `soft_pow` (bit-exact vs Arm Optimized Routines / musl) by
using Julia's `_log_ext` 128-entry table + degree-6 polynomial and Julia's
`exp_impl(x, xlo, Val(:ℯ))` 256-entry table + degree-3 polynomial — vs
musl's separate-file pow_log_data.c table + degree-7 polynomial and
exp_inline. The two libraries are both within ~0.54 ULP of mathematical
truth but pick different last-ULP values at the smallest-normal /
subnormal-output boundary.

This closes the ~0.83 % one-ULP residual that `soft_pow` showed against
`Base.:^` (Bennett-emv close session log, 2026-05-02). `soft_pow_julia`
is the function that `Base.:^(::SoftFloat, ::SoftFloat)` dispatches to;
the LLVM `llvm.pow.f64` direct-dispatch keeps using `soft_pow` (musl) so
that raw .ll/.bc ingest from non-Julia frontends matches their own libm.

See:
  * `base/math.jl` lines 1137-1174 (^ + pow_body for float y)
  * `base/math.jl` lines 1218-1243 (pow_body for integer y — compensated
    power-by-squaring with two_mul correction)
  * `base/special/exp.jl` lines 233-259 (exp_impl with xlo)
  * `base/special/log.jl` lines 559-587 (_log_ext)
  * `base/twiceprecision.jl` line 48 (canonicalize2)
"""

# ── Constants for _log_ext ─────────────────────────────────────────────
const _PJ_LOG_OFF        = UInt64(0x3fe6955500000000)   # 0x1.69555p-1
const _PJ_LOG_EXP_MASK   = UInt64(0xfff0000000000000)
const _PJ_LOG_NEG_ONE    = reinterpret(UInt64, -1.0)
const _PJ_LOG_LN2_HI     = reinterpret(UInt64, 0.6931471805598903)
const _PJ_LOG_LN2_LO     = reinterpret(UInt64, 5.497923018708371e-14)
const _PJ_LOG_NEG_HALF   = reinterpret(UInt64, -0.5)
# evalpoly coefficients (degree-6 in r)
const _PJ_LOG_P0         = reinterpret(UInt64, -0x1.555555555556p-1)
const _PJ_LOG_P1         = reinterpret(UInt64,  0x1.0000000000006p-1)
const _PJ_LOG_P2         = reinterpret(UInt64, -0x1.999999959554ep-2)
const _PJ_LOG_P3         = reinterpret(UInt64,  0x1.555555529a47ap-2)
const _PJ_LOG_P4         = reinterpret(UInt64, -0x1.2495b9b4845e9p-2)
const _PJ_LOG_P5         = reinterpret(UInt64,  0x1.0002b8b263fc3p-2)

# ── Pow constants ──────────────────────────────────────────────────────
const _PJ_POW_ONE        = reinterpret(UInt64,  1.0)
const _PJ_POW_INF        = UInt64(0x7FF0000000000000)
const _PJ_POW_NAN        = UInt64(0x7FF8000000000000)   # quiet NaN
const _PJ_POW_ZERO       = UInt64(0)
const _PJ_POW_NZERO      = UInt64(0x8000000000000000)
const _PJ_POW_HUGE_Y     = reinterpret(UInt64, 0x1.8p62)   # |y| clamp threshold
const _PJ_POW_X1P52      = reinterpret(UInt64, 0x1p52)
const _PJ_POW_TWO_F64    = reinterpret(UInt64, 2.0)
const _PJ_POW_TWO_P1023  = reinterpret(UInt64, 0x1p1023)
const _PJ_POW_SIGN_MASK  = UInt64(0x8000000000000000)
const _PJ_POW_SIGN_STRIP = UInt64(0x7FFFFFFFFFFFFFFF)
const _PJ_POW_SUBNORM_THRESH = UInt64(1) << 52   # x_bits < 2^52 → subnormal x

# Range covered by Julia's `use_power_by_squaring(n)` =
# `-2^12 <= n <= 3*2^13` (i.e. -4096 .. 24576).
const _PJ_POW_INT_LO = Int64(-4096)
const _PJ_POW_INT_HI = Int64(24576)

# ── 128-entry log table — verbatim copy from base/special/log.jl ──────
# `t_log_table_compact` (Julia 1.12). Each entry is `(t, logctail)`. We
# pack `logctail` as `UInt64` bit pattern so the whole table is two
# parallel `UInt64` columns; consumers `reinterpret` the second column
# to `Float64` (already done by passing through `soft_fma`).
const _PJ_T_LOG_TAB = (
    (UInt64(0xbfd62c82f2b9c8b5), UInt64(0x3cfab42428375680)),  # i=1, lc=5.92941e-15
    (UInt64(0xbfd5d1bdbf5808b4), UInt64(0xbd1ca508d8e0f720)),  # i=2, lc=-2.54416e-14
    (UInt64(0xbfd57677174558b3), UInt64(0xbd2362a4d5b6506d)),  # i=3, lc=-3.44353e-14
    (UInt64(0xbfd51aad872df8b2), UInt64(0xbce684e49eb067d5)),  # i=4, lc=-2.50012e-15
    (UInt64(0xbfd4be5f957778b1), UInt64(0xbd041b6993293ee0)),  # i=5, lc=-8.92934e-15
    (UInt64(0xbfd4618bc21c60b0), UInt64(0x3d13d82f484c84cc)),  # i=6, lc=1.76254e-14
    (UInt64(0xbfd404308686a8af), UInt64(0x3cdc42f3ed820b3a)),  # i=7, lc=1.56883e-15
    (UInt64(0xbfd3a64c556948ae), UInt64(0x3d20b1c686519460)),  # i=8, lc=2.96553e-14
    (UInt64(0xbfd347dd9a9880ad), UInt64(0x3d25594dd4c58092)),  # i=9, lc=3.79232e-14
    (UInt64(0xbfd2e8e2bae120ac), UInt64(0x3d267b1e99b72bd8)),  # i=10, lc=3.99342e-14
    (UInt64(0xbfd2895a13de88ab), UInt64(0x3d15ca14b6cfb03f)),  # i=11, lc=1.93529e-14
    (UInt64(0xbfd2895a13de88ab), UInt64(0x3d15ca14b6cfb03f)),  # i=12, lc=1.93529e-14
    (UInt64(0xbfd22941fbcf78aa), UInt64(0xbd165a242853da76)),  # i=13, lc=-1.98527e-14
    (UInt64(0xbfd1c898c16998a9), UInt64(0xbd1fafbc68e75404)),  # i=14, lc=-2.81432e-14
    (UInt64(0xbfd1675cababa8a8), UInt64(0x3d1f1fc63382a8f0)),  # i=15, lc=2.76438e-14
    (UInt64(0xbfd1058bf9ae48a7), UInt64(0xbd26a8c4fd055a66)),  # i=16, lc=-4.02509e-14
    (UInt64(0xbfd0a324e27390a6), UInt64(0xbd0c6bee7ef4030e)),  # i=17, lc=-1.26217e-14
    (UInt64(0xbfd0402594b4d0a5), UInt64(0xbcf036b89ef42d7f)),  # i=18, lc=-3.60018e-15
    (UInt64(0xbfd0402594b4d0a5), UInt64(0xbcf036b89ef42d7f)),  # i=19, lc=-3.60018e-15
    (UInt64(0xbfcfb9186d5e40a4), UInt64(0x3d0d572aab993c87)),  # i=20, lc=1.30298e-14
    (UInt64(0xbfcef0adcbdc60a3), UInt64(0x3d2b26b79c86af24)),  # i=21, lc=4.82303e-14
    (UInt64(0xbfce27076e2af0a2), UInt64(0xbd172f4f543fff10)),  # i=22, lc=-2.05922e-14
    (UInt64(0xbfcd5c216b4fc0a1), UInt64(0x3d21ba91bbca681b)),  # i=23, lc=3.14927e-14
    (UInt64(0xbfcc8ff7c79aa0a0), UInt64(0x3d27794f689f8434)),  # i=24, lc=4.1698e-14
    (UInt64(0xbfcc8ff7c79aa0a0), UInt64(0x3d27794f689f8434)),  # i=25, lc=4.1698e-14
    (UInt64(0xbfcbc286742d909f), UInt64(0x3d194eb0318bb78f)),  # i=26, lc=2.24775e-14
    (UInt64(0xbfcaf3c94e80c09e), UInt64(0x3cba4e633fcd9066)),  # i=27, lc=3.65072e-16
    (UInt64(0xbfca23bc1fe2b09d), UInt64(0xbd258c64dc46c1ea)),  # i=28, lc=-3.82777e-14
    (UInt64(0xbfca23bc1fe2b09d), UInt64(0xbd258c64dc46c1ea)),  # i=29, lc=-3.82777e-14
    (UInt64(0xbfc9525a9cf4509c), UInt64(0xbd2ad1d904c1d4e3)),  # i=30, lc=-4.76414e-14
    (UInt64(0xbfc87fa06520d09b), UInt64(0x3d2bbdbf7fdbfa09)),  # i=31, lc=4.92783e-14
    (UInt64(0xbfc7ab890210e09a), UInt64(0x3d2bdb9072534a58)),  # i=32, lc=4.94852e-14
    (UInt64(0xbfc7ab890210e09a), UInt64(0x3d2bdb9072534a58)),  # i=33, lc=4.94852e-14
    (UInt64(0xbfc6d60fe719d099), UInt64(0xbd10e46aa3b2e266)),  # i=34, lc=-1.50033e-14
    (UInt64(0xbfc5ff3070a79098), UInt64(0xbd1e9e439f105039)),  # i=35, lc=-2.71944e-14
    (UInt64(0xbfc5ff3070a79098), UInt64(0xbd1e9e439f105039)),  # i=36, lc=-2.71944e-14
    (UInt64(0xbfc526e5e3a1b097), UInt64(0xbd20de8b90075b8f)),  # i=37, lc=-2.99659e-14
    (UInt64(0xbfc44d2b6ccb8096), UInt64(0x3d170cc16135783c)),  # i=38, lc=2.04724e-14
    (UInt64(0xbfc44d2b6ccb8096), UInt64(0x3d170cc16135783c)),  # i=39, lc=2.04724e-14
    (UInt64(0xbfc371fc201e9095), UInt64(0x3cf178864d27543a)),  # i=40, lc=3.8793e-15
    (UInt64(0xbfc29552f81ff094), UInt64(0xbd248d301771c408)),  # i=41, lc=-3.65068e-14
    (UInt64(0xbfc1b72ad52f6093), UInt64(0xbd2e80a41811a396)),  # i=42, lc=-5.41833e-14
    (UInt64(0xbfc1b72ad52f6093), UInt64(0xbd2e80a41811a396)),  # i=43, lc=-5.41833e-14
    (UInt64(0xbfc0d77e7cd09092), UInt64(0x3d0a699688e85bf4)),  # i=44, lc=1.17295e-14
    (UInt64(0xbfc0d77e7cd09092), UInt64(0x3d0a699688e85bf4)),  # i=45, lc=1.17295e-14
    (UInt64(0xbfbfec9131dbe091), UInt64(0xbd2575545ca333f2)),  # i=46, lc=-3.81176e-14
    (UInt64(0xbfbe27076e2b0090), UInt64(0x3d2a342c2af0003c)),  # i=47, lc=4.65473e-14
    (UInt64(0xbfbe27076e2b0090), UInt64(0x3d2a342c2af0003c)),  # i=48, lc=4.65473e-14
    (UInt64(0xbfbc5e548f5bc08f), UInt64(0xbd1d0c57585fbe06)),  # i=49, lc=-2.58e-14
    (UInt64(0xbfba926d3a4ae08e), UInt64(0x3d253935e85baac8)),  # i=50, lc=3.77005e-14
    (UInt64(0xbfba926d3a4ae08e), UInt64(0x3d253935e85baac8)),  # i=51, lc=3.77005e-14
    (UInt64(0xbfb8c345d631a08d), UInt64(0x3d137c294d2f5668)),  # i=52, lc=1.73062e-14
    (UInt64(0xbfb8c345d631a08d), UInt64(0x3d137c294d2f5668)),  # i=53, lc=1.73062e-14
    (UInt64(0xbfb6f0d28ae5608c), UInt64(0xbd269737c93373da)),  # i=54, lc=-4.01291e-14
    (UInt64(0xbfb51b073f06208b), UInt64(0x3d1f025b61c65e57)),  # i=55, lc=2.75417e-14
    (UInt64(0xbfb51b073f06208b), UInt64(0x3d1f025b61c65e57)),  # i=56, lc=2.75417e-14
    (UInt64(0xbfb341d7961be08a), UInt64(0x3d2c5edaccf913df)),  # i=57, lc=5.03962e-14
    (UInt64(0xbfb341d7961be08a), UInt64(0x3d2c5edaccf913df)),  # i=58, lc=5.03962e-14
    (UInt64(0xbfb16536eea38089), UInt64(0x3d147c5e768fa309)),  # i=59, lc=1.81951e-14
    (UInt64(0xbfaf0a30c0118088), UInt64(0x3d2d599e83368e91)),  # i=60, lc=5.21362e-14
    (UInt64(0xbfaf0a30c0118088), UInt64(0x3d2d599e83368e91)),  # i=61, lc=5.21362e-14
    (UInt64(0xbfab42dd71198087), UInt64(0x3d1c827ae5d6704c)),  # i=62, lc=2.53217e-14
    (UInt64(0xbfab42dd71198087), UInt64(0x3d1c827ae5d6704c)),  # i=63, lc=2.53217e-14
    (UInt64(0xbfa77458f632c086), UInt64(0xbd2cfc4634f2a1ee)),  # i=64, lc=-5.14885e-14
    (UInt64(0xbfa77458f632c086), UInt64(0xbd2cfc4634f2a1ee)),  # i=65, lc=-5.14885e-14
    (UInt64(0xbfa39e87b9fec085), UInt64(0x3cf502b7f526feaa)),  # i=66, lc=4.66529e-15
    (UInt64(0xbfa39e87b9fec085), UInt64(0x3cf502b7f526feaa)),  # i=67, lc=4.66529e-15
    (UInt64(0xbf9f829b0e780084), UInt64(0xbd2980267c7e09e4)),  # i=68, lc=-4.52981e-14
    (UInt64(0xbf9f829b0e780084), UInt64(0xbd2980267c7e09e4)),  # i=69, lc=-4.52981e-14
    (UInt64(0xbf97b91b07d58083), UInt64(0xbd288d5493faa639)),  # i=70, lc=-4.36132e-14
    (UInt64(0xbf8fc0a8b0fc0082), UInt64(0xbcdf1e7cf6d3a69c)),  # i=71, lc=-1.72746e-15
    (UInt64(0xbf8fc0a8b0fc0082), UInt64(0xbcdf1e7cf6d3a69c)),  # i=72, lc=-1.72746e-15
    (UInt64(0xbf7fe02a6b100081), UInt64(0xbd19e23f0dda40e4)),  # i=73, lc=-2.29894e-14
    (UInt64(0xbf7fe02a6b100081), UInt64(0xbd19e23f0dda40e4)),  # i=74, lc=-2.29894e-14
    (UInt64(0x0000000000000080), UInt64(0x0000000000000000)),  # i=75, lc=0
    (UInt64(0x0000000000000080), UInt64(0x0000000000000000)),  # i=76, lc=0
    (UInt64(0x3f8010157589007e), UInt64(0xbd10c76b999d2be8)),  # i=77, lc=-1.49027e-14
    (UInt64(0x3f9020565893807c), UInt64(0xbd23dc5b06e2f7d2)),  # i=78, lc=-3.52798e-14
    (UInt64(0x3f98492528c9007a), UInt64(0xbd2aa0ba325a0c34)),  # i=79, lc=-4.73005e-14
    (UInt64(0x3fa0415d89e74078), UInt64(0x3d0111c05cf1d753)),  # i=80, lc=7.58031e-15
    (UInt64(0x3fa466aed42e0076), UInt64(0xbd2c167375bdfd28)),  # i=81, lc=-4.98938e-14
    (UInt64(0x3fa894aa149fc074), UInt64(0xbd197995d05a267d)),  # i=82, lc=-2.26263e-14
    (UInt64(0x3faccb73cdddc072), UInt64(0xbd1a68f247d82807)),  # i=83, lc=-2.34567e-14
    (UInt64(0x3faeea31c006c071), UInt64(0xbd0e113e4fc93b7b)),  # i=84, lc=-1.33526e-14
    (UInt64(0x3fb1973bd146606f), UInt64(0xbd25325d560d9e9b)),  # i=85, lc=-3.7653e-14
    (UInt64(0x3fb3bdf5a7d1e06d), UInt64(0x3d2cc85ea5db4ed7)),  # i=86, lc=5.11283e-14
    (UInt64(0x3fb5e95a4d97a06b), UInt64(0xbd2c69063c5d1d1e)),  # i=87, lc=-5.04667e-14
    (UInt64(0x3fb700d30aeac06a), UInt64(0x3cec1e8da99ded32)),  # i=88, lc=3.12187e-15
    (UInt64(0x3fb9335e5d594068), UInt64(0x3d23115c3abd47da)),  # i=89, lc=3.38712e-14
    (UInt64(0x3fbb6ac88dad6066), UInt64(0xbd1390802bf768e5)),  # i=90, lc=-1.73767e-14
    (UInt64(0x3fbc885801bc4065), UInt64(0x3d2646d1c65aacd3)),  # i=91, lc=3.95713e-14
    (UInt64(0x3fbec739830a2063), UInt64(0xbd2dc068afe645e0)),  # i=92, lc=-5.28495e-14
    (UInt64(0x3fbfe89139dbe062), UInt64(0xbd2534d64fa10afd)),  # i=93, lc=-3.76701e-14
    (UInt64(0x3fc1178e8227e060), UInt64(0x3d21ef78ce2d07f2)),  # i=94, lc=3.18597e-14
    (UInt64(0x3fc1aa2b7e23f05f), UInt64(0x3d2ca78e44389934)),  # i=95, lc=5.09006e-14
    (UInt64(0x3fc2d1610c86805d), UInt64(0x3d039d6ccb81b4a1)),  # i=96, lc=8.71078e-15
    (UInt64(0x3fc365fcb015905c), UInt64(0x3cc62fa8234b7289)),  # i=97, lc=6.1579e-16
    (UInt64(0x3fc4913d8333b05a), UInt64(0x3d25837954fdb678)),  # i=98, lc=3.82158e-14
    (UInt64(0x3fc527e5e4a1b059), UInt64(0x3d2633e8e5697dc7)),  # i=99, lc=3.944e-14
    (UInt64(0x3fc6574ebe8c1057), UInt64(0x3d19cf8b2c3c2e78)),  # i=100, lc=2.29245e-14
    (UInt64(0x3fc6f0128b757056), UInt64(0xbd25118de59c21e1)),  # i=101, lc=-3.74253e-14
    (UInt64(0x3fc7898d85445055), UInt64(0xbd1c661070914305)),  # i=102, lc=-2.52231e-14
    (UInt64(0x3fc8beafeb390053), UInt64(0xbd073d54aae92cd1)),  # i=103, lc=-1.03204e-14
    (UInt64(0x3fc95a5adcf70052), UInt64(0x3d07f22858a0ff6f)),  # i=104, lc=1.06341e-14
    (UInt64(0x3fca93ed3c8ae050), UInt64(0xbd28724350562169)),  # i=105, lc=-4.34254e-14
    (UInt64(0x3fcb31d8575bd04f), UInt64(0xbd0c358d4eace1aa)),  # i=106, lc=-1.25274e-14
    (UInt64(0x3fcbd087383be04e), UInt64(0xbd2d4bc4595412b6)),  # i=107, lc=-5.20401e-14
    (UInt64(0x3fcc6ffbc6f0104d), UInt64(0xbcf1ec72c5962bd2)),  # i=108, lc=-3.97984e-15
    (UInt64(0x3fcdb13db0d4904b), UInt64(0xbd2aff2af715b035)),  # i=109, lc=-4.79559e-14
    (UInt64(0x3fce530effe7104a), UInt64(0x3cc212276041f430)),  # i=110, lc=5.01569e-16
    (UInt64(0x3fcef5ade4dd0049), UInt64(0xbcca211565bb8e11)),  # i=111, lc=-7.25232e-16
    (UInt64(0x3fcf991c6cb3b048), UInt64(0x3d1bcbecca0cdf30)),  # i=112, lc=2.46883e-14
    (UInt64(0x3fd07138604d5846), UInt64(0x3cf89cdb16ed4e91)),  # i=113, lc=5.46512e-15
    (UInt64(0x3fd0c42d67616045), UInt64(0x3d27188b163ceae9)),  # i=114, lc=4.10265e-14
    (UInt64(0x3fd1178e8227e844), UInt64(0xbd2c210e63a5f01c)),  # i=115, lc=-4.99674e-14
    (UInt64(0x3fd16b5ccbacf843), UInt64(0x3d2b9acdf7a51681)),  # i=116, lc=4.90358e-14
    (UInt64(0x3fd1bf99635a6842), UInt64(0x3d2ca6ed5147bdb7)),  # i=117, lc=5.08963e-14
    (UInt64(0x3fd214456d0eb841), UInt64(0x3d0a87deba46baea)),  # i=118, lc=1.1782e-14
    (UInt64(0x3fd2bef07cdc903f), UInt64(0x3d2a9cfa4a5004f4)),  # i=119, lc=4.72745e-14
    (UInt64(0x3fd314f1e1d3603e), UInt64(0xbd28e27ad3213cb8)),  # i=120, lc=-4.42041e-14
    (UInt64(0x3fd36b6776be103d), UInt64(0x3d116ecdb0f177c8)),  # i=121, lc=1.54835e-14
    (UInt64(0x3fd3c2527733303c), UInt64(0x3d183b54b606bd5c)),  # i=122, lc=2.15221e-14
    (UInt64(0x3fd419b423d5e83b), UInt64(0x3d08e436ec90e09d)),  # i=123, lc=1.1054e-14
    (UInt64(0x3fd4718dc271c83a), UInt64(0xbd2f27ce0967d675)),  # i=124, lc=-5.53433e-14
    (UInt64(0x3fd4c9e09e173039), UInt64(0xbd2e20891b0ad8a4)),  # i=125, lc=-5.35165e-14
    (UInt64(0x3fd522ae0738a038), UInt64(0x3d2ebe708164c759)),  # i=126, lc=5.46121e-14
    (UInt64(0x3fd57bf753c8d037), UInt64(0x3d1fadedee5d40ef)),  # i=127, lc=2.8137e-14
    (UInt64(0x3fd5d5bddf596036), UInt64(0xbd0a0b2a08a465dc)),  # i=128, lc=-1.15657e-14
)

# ── _log_ext: Julia-faithful 68-bit-precision log ─────────────────────
# Returns (loghi_bits, loglo_bits). Inlined into _pj_pow_body_float
# below — Julia tuple returns are fine here because soft_pow_julia is
# called as a regular function (not directly compiled into a circuit
# in the bit-exact-vs-Base.^ test path). For circuit lowering paths
# where Tuple returns don't lower, the helper is `@inline`d.
@inline function _pj_log_tab_unpack(t::UInt64)
    invc_bits = (t & UInt64(0xff) | UInt64(0x1ff00)) << 45
    logc_bits = t & ~UInt64(0xff)
    return (invc_bits, logc_bits)
end

@inline function _pj_log_ext(xu::UInt64)
    # tmp = reinterpret(Int64, xu - OFF); z = xu - (tmp & EXP_MASK); k = tmp>>52
    tmp_u = xu - _PJ_LOG_OFF
    tmp_s = reinterpret(Int64, tmp_u)
    z_bits = xu - (tmp_u & _PJ_LOG_EXP_MASK)
    k_int  = tmp_s >> 52
    k_bits = soft_sitofp(reinterpret(UInt64, k_int))

    # idx = (tmp >> 45) & 127 + 1
    idx = Int(((tmp_s >> 45) & Int64(127)) + Int64(1))
    t_entry = getfield(_PJ_T_LOG_TAB, idx)
    t_bits   = getfield(t_entry, 1)
    logctail = getfield(t_entry, 2)
    invc, logc = _pj_log_tab_unpack(t_bits)

    # r = fma(z, invc, -1.0)
    r = soft_fma(z_bits, invc, _PJ_LOG_NEG_ONE)

    # t1 = muladd(k, ln2hi, logc); t2 = t1 + r
    t1 = soft_fma(k_bits, _PJ_LOG_LN2_HI, logc)
    t2 = soft_fadd(t1, r)
    # lo1 = muladd(k, ln2lo, logctail); lo2 = (t1 - t2) + r
    lo1 = soft_fma(k_bits, _PJ_LOG_LN2_LO, logctail)
    lo2 = soft_fadd(soft_fsub(t1, t2), r)

    # ar = -0.5 * r; (ar2, lo3) = two_mul(r, ar)
    ar  = soft_fmul(_PJ_LOG_NEG_HALF, r)
    ar2 = soft_fmul(r, ar)
    lo3 = soft_fma(r, ar, soft_fneg(ar2))

    # hi = t2 + ar2; lo4 = (t2 - hi) + ar2
    hi  = soft_fadd(t2, ar2)
    lo4 = soft_fadd(soft_fsub(t2, hi), ar2)

    # p = evalpoly(r, (P0, P1, P2, P3, P4, P5)) — Horner from highest down:
    # = ((((((P5*r + P4)*r + P3)*r + P2)*r + P1)*r) + P0
    # Standard evalpoly(r, p) = p[1] + r*(p[2] + r*(p[3] + ...)) so:
    # = P0 + r*(P1 + r*(P2 + r*(P3 + r*(P4 + r*P5))))
    # Horner via FMA innermost-out:
    p = soft_fma(r, _PJ_LOG_P5, _PJ_LOG_P4)
    p = soft_fma(r, p,          _PJ_LOG_P3)
    p = soft_fma(r, p,          _PJ_LOG_P2)
    p = soft_fma(r, p,          _PJ_LOG_P1)
    p = soft_fma(r, p,          _PJ_LOG_P0)

    # lo = lo1 + lo2 + lo3 + muladd(r*ar2, p, lo4)
    s1   = soft_fadd(lo1, lo2)
    s2   = soft_fadd(s1, lo3)
    rar2 = soft_fmul(r, ar2)
    fma_term = soft_fma(rar2, p, lo4)
    lo = soft_fadd(s2, fma_term)

    return (hi, lo)
end

# ── exp_impl(x, xlo, Val(:ℯ)) ──────────────────────────────────────────
# Port of base/special/exp.jl line 233. Specialized to base = e (the
# only base used by pow). Constants reused from fexp_julia.jl
# (`_LOGBO256INV_E_BITS` etc., all in scope inside `module SoftFloatLib`).
@inline function _pj_exp_impl_with_lo(x::UInt64, xlo::UInt64)
    # Step 1: N_float = muladd(x, LOGBO256INV, MAGIC)
    N_float = soft_fma(x, _LOGBO256INV_E_BITS, _MAGIC_ROUND_CONST_BITS)

    # Step 2: N = N_float % Int32; k = N >> 8
    N_u   = N_float & UInt64(0xFFFFFFFF)
    N_i32 = reinterpret(Int32, UInt32(N_u))
    N_i64 = Int64(N_i32)

    # Step 3: N_float -= MAGIC
    N_float = soft_fsub(N_float, _MAGIC_ROUND_CONST_BITS)

    # Step 4-5: r = muladd(N_float, LOGBO256L, muladd(N_float, LOGBO256U, x))
    # NB: this `r` does NOT use xlo — Julia source uses x here, identical
    # to the no-lo variant. xlo enters via small_part below.
    r = soft_fma(N_float, _LOGBO256U_E_BITS, x)
    r = soft_fma(N_float, _LOGBO256L_E_BITS, r)

    # Step 6: k = N >> 8
    k = N_i64 >> 8

    # Step 7: table_unpack — ind = (N & 255) + 1
    ind = Int((N_u & UInt64(0xFF)) + UInt64(1))
    j   = getfield(_JL_J_TABLE, ind)
    jU  = _JL_JU_CONST | (j & _JL_JU_MASK)
    jL  = _JL_JL_CONST | (j >> 8)

    # Step 8: kern = expm1b_kernel(:ℯ, r) — Horner deg-3:
    # = C0 + r*(C1 + r*(C2 + r*C3))
    p = soft_fma(r, _EXPM1B_E_C3_BITS, _EXPM1B_E_C2_BITS)
    p = soft_fma(r, p,                  _EXPM1B_E_C1_BITS)
    p = soft_fma(r, p,                  _EXPM1B_E_C0_BITS)
    kern = soft_fmul(r, p)

    # Step 9 (with xlo):
    # very_small = muladd(kern, jU*xlo, jL)
    jU_xlo     = soft_fmul(jU, xlo)
    very_small = soft_fma(kern, jU_xlo, jL)
    # (hi_canon, lo_canon) = canonicalize2(1.0, kern)
    h_canon  = soft_fadd(_PJ_POW_ONE, kern)
    lo_canon = soft_fadd(soft_fsub(_PJ_POW_ONE, h_canon), kern)
    # small_part = fma(jU, h_canon, muladd(jU, (lo_canon + xlo), very_small))
    inner      = soft_fma(jU, soft_fadd(lo_canon, xlo), very_small)
    small_part = soft_fma(jU, h_canon, inner)

    # Step 10: normal path — twopk + small_part as bit-pattern add
    twopk_normal_bits = reinterpret(UInt64, k << 52)
    normal_result     = small_part + twopk_normal_bits

    # Step 11: subnormal path — (k+53)<<52 + small_part, then * 2^-53
    twopk_sub_bits    = reinterpret(UInt64, (k + Int64(53)) << 52)
    sub_bits          = small_part + twopk_sub_bits
    subnormal_result  = soft_fmul(sub_bits, _TWO_POW_NEG_53_BITS)

    # Step 11.5: k == 1024 path (only present in the with-lo variant):
    # (small_part * 2.0) * 2^1023
    overflow_path = soft_fmul(soft_fmul(small_part, _PJ_POW_TWO_F64), _PJ_POW_TWO_P1023)

    # Step 12: predicates
    abs_x       = x & ~_F64_SIGN_MASK_JL
    is_nan_x    = abs_x > _F64_INF_BITS_JL
    sign_bit    = (x >> 63) & UInt64(1)
    x_positive  = sign_bit == UInt64(0)
    too_big     = !is_nan_x & x_positive & (x >= _MAX_EXP_E_BITS)
    too_small   = !is_nan_x & !x_positive & (abs_x >= _ABS_MIN_EXP_E_BITS)
    out_of_norm = abs_x > _SUBNORM_EXP_E_BITS
    k_tiny      = k <= Int64(-53)
    k_overflow  = k == Int64(1024)

    # Step 13: final select chain (last-write-wins priority)
    result = normal_result
    result = ifelse(out_of_norm & k_overflow, overflow_path,    result)
    result = ifelse(out_of_norm & k_tiny,     subnormal_result, result)
    result = ifelse(too_small,                UInt64(0),        result)
    result = ifelse(too_big,                  _F64_INF_BITS_JL, result)
    result = ifelse(is_nan_x,                 x,                result)
    return result
end

# ── pow_body(x::Float64, y::Float64) — float-y branch ─────────────────
# Port of base/math.jl line 1162.
@inline function _pj_pow_body_float(x::UInt64, y::UInt64)::UInt64
    # Subnormal-x normalization: xu = (x*2^52)&~sign; xu -= 52<<52
    is_subnormal = x < _PJ_POW_SUBNORM_THRESH
    x_norm = soft_fmul(x, _PJ_POW_X1P52)
    x_for_log_sub = (x_norm & _PJ_POW_SIGN_STRIP) - (UInt64(52) << 52)
    xu = ifelse(is_subnormal, x_for_log_sub, x)

    loghi, loglo = _pj_log_ext(xu)

    # (xyhi, xylo) = two_mul(loghi, y)
    xyhi = soft_fmul(loghi, y)
    xylo = soft_fma(loghi, y, soft_fneg(xyhi))
    # xylo = muladd(loglo, y, xylo)
    xylo = soft_fma(loglo, y, xylo)

    hi = soft_fadd(xyhi, xylo)
    # exp_impl(hi, xylo - (hi - xyhi), Val(:ℯ))
    lo_for_exp = soft_fsub(xylo, soft_fsub(hi, xyhi))
    return _pj_exp_impl_with_lo(hi, lo_for_exp)
end

# ── pow_body(x::Float64, n::Integer) — integer-y compensated squaring ──
# Port of base/math.jl line 1218. Loop bound: |n| ≤ 24576 < 2^15
# (16 iterations max).
#
# CRITICAL: Julia's `pow_body(::Float64, ::Integer)` is `@noinline`, so its
# `muladd` calls are emitted as `fmul contract; fadd contract` and NOT
# contracted into FMA by LLVM (verified via `@code_llvm` 2026-05-02). The
# soft port therefore uses `soft_fadd(soft_fmul(...), ...)` for those
# `muladd` sites (two roundings), NOT `soft_fma` (one rounding) — the
# 1-ULP difference matters bit-exactly. The `two_mul` correction terms
# DO use `soft_fma` because Julia's `two_mul` calls `fma` directly (not
# `muladd`), and `fma` always emits `@llvm.fma.f64` (one rounding).
@inline _pj_two_round(a::UInt64, b::UInt64, c::UInt64) = soft_fadd(soft_fmul(a, b), c)

function _pj_pow_body_int(x::UInt64, n::Int64)::UInt64
    n == Int64(3) && return soft_fmul(soft_fmul(x, x), x)  # literal_pow compatibility

    y    = _PJ_POW_ONE       # 1.0 bits
    xnlo = _PJ_POW_NZERO     # -0.0 bits
    ynlo = _PJ_POW_ZERO      #  0.0 bits

    if n < Int64(0)
        rx = soft_fdiv(_PJ_POW_ONE, x)
        n == Int64(-2) && return soft_fmul(rx, rx)
        # if isfinite(x): xnlo = -fma(x, rx, -1.) * rx
        # `fma` here is the IEEE FMA intrinsic (one rounding) — this is
        # Julia's verbatim `fma(x, rx, -1.)` call, NOT a `muladd`.
        abs_x = x & _PJ_POW_SIGN_STRIP
        x_finite = abs_x < _PJ_POW_INF
        xnlo_f = soft_fneg(soft_fmul(soft_fma(x, rx, _PJ_LOG_NEG_ONE), rx))
        xnlo   = ifelse(x_finite, xnlo_f, xnlo)
        x = rx
        n = -n
    end

    while n > Int64(1)
        if (n & Int64(1)) > Int64(0)
            # err = muladd(y, xnlo, x*ynlo) — two-rounding (see header note)
            err = _pj_two_round(y, xnlo, soft_fmul(x, ynlo))
            # (y, ynlo) = two_mul(x, y) — one-rounding FMA per Julia
            y_new    = soft_fmul(x, y)
            ynlo_new = soft_fma(x, y, soft_fneg(y_new))
            y    = y_new
            ynlo = soft_fadd(ynlo_new, err)
        end
        # err = x*2*xnlo (two regular multiplies)
        err = soft_fmul(soft_fmul(x, _PJ_POW_TWO_F64), xnlo)
        # (x, xnlo) = two_mul(x, x) — one-rounding FMA
        x_new    = soft_fmul(x, x)
        xnlo_new = soft_fma(x, x, soft_fneg(x_new))
        x    = x_new
        xnlo = soft_fadd(xnlo_new, err)
        n  >>>= 1
    end

    # err = muladd(y, xnlo, x*ynlo) — two-rounding
    err = _pj_two_round(y, xnlo, soft_fmul(x, ynlo))
    # ifelse(isfinite(x) & isfinite(err), muladd(x, y, err), x*y) — two-rounding
    abs_x   = x   & _PJ_POW_SIGN_STRIP
    abs_err = err & _PJ_POW_SIGN_STRIP
    x_finite   = abs_x   < _PJ_POW_INF
    err_finite = abs_err < _PJ_POW_INF
    muladd_path = _pj_two_round(x, y, err)
    fall_path   = soft_fmul(x, y)
    return ifelse(x_finite & err_finite, muladd_path, fall_path)
end

# ── soft_pow_julia: outer ^(::Float64, ::Float64) wrapper ─────────────
# Port of base/math.jl line 1137.
@inline function soft_pow_julia(a::UInt64, b::UInt64)::UInt64
    x = a
    y = b

    # (A) x === 1.0 (bit-pattern compare on +1.0 only — matches Julia)
    x == _PJ_POW_ONE && return _PJ_POW_ONE

    # (B) Clamp huge |y|; pass-through NaN
    abs_y = y & _PJ_POW_SIGN_STRIP
    if !(abs_y < _PJ_POW_HUGE_Y)
        # isnan(y) → return y
        abs_y > _PJ_POW_INF && return y
        # y = sign(y) * 0x1.8p62
        y = (y & _PJ_POW_SIGN_MASK) | _PJ_POW_HUGE_Y
    end

    # (C) Integer test — yint = unsafe_trunc(Int64, y); yisint = (y == yint)
    # Saturates NaN/Inf/oversize to INT_MIN; we handled NaN above and
    # clamped huge |y| so |y| ∈ [0, 0x1.8p62) at this point.
    yint_bits  = soft_fptosi(y)
    yint       = reinterpret(Int64, yint_bits)
    y_back     = soft_sitofp(yint_bits)
    yisint     = (soft_fcmp_oeq(y, y_back) != UInt64(0))

    if yisint
        # (D) yint == 0 → return 1.0 (catches y == ±0.0)
        yint == Int64(0) && return _PJ_POW_ONE
        # (E) Small integer y → squaring path
        if _PJ_POW_INT_LO <= yint <= _PJ_POW_INT_HI
            return _pj_pow_body_int(x, yint)
        end
    end

    # (F) x === ±0 → abs(y) * Inf * (!(y > 0))
    # 2*xu == 0 (UInt64 wrap) catches both ±0. y == 0 was handled above.
    if (UInt64(2) * x) == UInt64(0)
        # y > 0 → 0.0 ; y ≤ 0 OR NaN-y → +Inf
        # (NaN-y was returned above; here y is finite and ≠ 0.)
        y_pos = (soft_fcmp_olt(_PJ_POW_ZERO, y) != UInt64(0))
        return ifelse(y_pos, _PJ_POW_ZERO, _PJ_POW_INF)
    end

    # (G) Negative-x sign rule
    s_negative = false
    sign_x = (x >> 63) & UInt64(1)
    if sign_x != UInt64(0)
        # Negative x with non-int y → DomainError in Julia; we return NaN
        # per IEEE 754-2019 (Julia throws but we route through the FP
        # `^(::SoftFloat, ::SoftFloat)` dispatch where exceptions cannot
        # propagate cleanly, and IEEE NaN matches libm semantics).
        yisint || return _PJ_POW_NAN
        s_negative = (yint & Int64(1)) != Int64(0)
    end

    # (H) Non-finite x: copysign(x, s) * (y > 0 || isnan(x))
    abs_x = x & _PJ_POW_SIGN_STRIP
    if abs_x >= _PJ_POW_INF
        x_is_nan = abs_x > _PJ_POW_INF
        x_signed = ifelse(s_negative, x | _PJ_POW_SIGN_MASK, x & _PJ_POW_SIGN_STRIP)
        y_pos    = (soft_fcmp_olt(_PJ_POW_ZERO, y) != UInt64(0))
        keep     = y_pos | x_is_nan
        # x_signed * Bool(keep): true → x_signed; false → copysign(0, x_signed)
        return ifelse(keep, x_signed, x_signed & _PJ_POW_SIGN_MASK)
    end

    # Main path: copysign(pow_body(abs(x), y), s_negative)
    body = _pj_pow_body_float(abs_x, y)
    return ifelse(s_negative, body | _PJ_POW_SIGN_MASK, body & _PJ_POW_SIGN_STRIP)
end
