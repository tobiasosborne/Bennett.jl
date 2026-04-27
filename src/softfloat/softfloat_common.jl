"""
Shared branchless building blocks for IEEE 754 soft-float operations.
All functions are @inline to ensure Julia inlines them into the caller,
producing clean LLVM IR without call instructions for the reversible pipeline.
"""

# IEEE 754 double-precision constants
const FRAC_MASK = UInt64(0x000FFFFFFFFFFFFF)   # 52-bit stored fraction
const IMPLICIT  = UInt64(0x0010000000000000)   # bit 52 (implicit leading 1)
const EXP_MASK  = UInt64(0x7FF0000000000000)   # exponent field
const INF_BITS  = UInt64(0x7FF0000000000000)   # +Inf
const QNAN      = UInt64(0x7FF8000000000000)   # canonical quiet NaN (payload 0)
const QUIET_BIT = UInt64(0x0008000000000000)   # fraction bit 51 (IEEE 754-2019 §6.2.1 quiet-bit convention)
const INDEF     = UInt64(0xFFF8000000000000)   # x86 "indefinite" invalid-op result (Intel SDM Vol 1 §4.8.3.7)

"""
    _sf_propagate_nan2(a, b, a_nan, b_nan) -> UInt64

Propagate first-operand NaN (x86 SSE rule): if `a` is NaN return `a | QUIET_BIT`,
else `b | QUIET_BIT`. Preserves sign and payload; force-quiets signalling NaNs
per IEEE 754-2019 §6.2.3. Caller must guard entry with `a_nan | b_nan`.
"""
@inline _sf_propagate_nan2(a::UInt64, b::UInt64, a_nan, b_nan) =
    ifelse(a_nan, a | QUIET_BIT, b | QUIET_BIT)

"""
    _sf_propagate_nan3(a, b, c, a_nan, b_nan, c_nan) -> UInt64

Three-operand variant for FMA: a > b > c precedence, matching Intel VFMADD*'s
NaN-handling order. Caller must guard entry with `a_nan | b_nan | c_nan`.
"""
@inline _sf_propagate_nan3(a::UInt64, b::UInt64, c::UInt64, a_nan, b_nan, c_nan) =
    ifelse(a_nan, a | QUIET_BIT,
    ifelse(b_nan, b | QUIET_BIT,
                  c | QUIET_BIT))

"""
    _sf_normalize_to_bit52(m, e) -> (m, e)

Normalize a mantissa so its leading 1 is at bit 52 (the IEEE 754 normalized
form). Decrement the effective exponent `e` by the shift count. Used by
`soft_fdiv` to pre-normalize subnormal operands before the restoring-division
loop, which assumes `ma, mb ∈ [2^52, 2^53)` so that the ratio fits in 56 bits
of precision. For an already-normalized input (bit 52 set), this is a no-op.

Precondition: `m` has no bits set above bit 52. All callers guarantee this
(subnormal inputs have `m < 2^52`; normal inputs have `m < 2^53` with bit 52
set, so already-normalized).

# Bennett-tpg0 / U135 — m == 0 contract

Pre-tpg0 the function had a caller-trust contract: `m == 0` produced
`(0, e - 63)` (every CLZ stage shifts because no leading 1 is found),
documented as "callers handle zero inputs via the select chain before
using m". A future caller that didn't pre-guard would silently get a
nonsense exponent.

Post-tpg0: `m == 0` returns `(0, e)` unchanged. Branchless via an
`ifelse` substitute pattern — internally use `IMPLICIT` (1<<52) as the
sentinel during CLZ (a no-op for the already-normalized form), then
restore `m=0` and `e` at exit. Byte-identical output for all `m != 0`
inputs because the substitute only fires on `m == 0`. Pinned by
`test_tpg0_normalize_zero_input.jl`.

Six-stage branchless binary-search CLZ; structure mirrors `_sf_normalize_clz`
but the target bit is 52 instead of 55.
"""
@inline function _sf_normalize_to_bit52(m::UInt64, e::Int64)
    # Bennett-tpg0: defensive guard for m == 0. Substitute IMPLICIT
    # (1<<52, leading 1 already at the target bit) so the CLZ is a
    # no-op; restore zero outputs at the end.
    m_zero = m == UInt64(0)
    e_orig = e
    m = ifelse(m_zero, IMPLICIT, m)

    need32 = (m & (UInt64(0xFFFFFFFF) << 21)) == UInt64(0)
    m = ifelse(need32, m << 32, m)
    e = ifelse(need32, e - Int64(32), e)

    need16 = (m & (UInt64(0xFFFF) << 37)) == UInt64(0)
    m = ifelse(need16, m << 16, m)
    e = ifelse(need16, e - Int64(16), e)

    need8 = (m & (UInt64(0xFF) << 45)) == UInt64(0)
    m = ifelse(need8, m << 8, m)
    e = ifelse(need8, e - Int64(8), e)

    need4 = (m & (UInt64(0xF) << 49)) == UInt64(0)
    m = ifelse(need4, m << 4, m)
    e = ifelse(need4, e - Int64(4), e)

    need2 = (m & (UInt64(0x3) << 51)) == UInt64(0)
    m = ifelse(need2, m << 2, m)
    e = ifelse(need2, e - Int64(2), e)

    need1 = (m & (UInt64(1) << 52)) == UInt64(0)
    m = ifelse(need1, m << 1, m)
    e = ifelse(need1, e - Int64(1), e)

    # Restore zero: byte-identical for m != 0 (m_zero is false, ifelse
    # picks the CLZ result); for m == 0 returns (0, e_orig).
    m_final = ifelse(m_zero, UInt64(0), m)
    e_final = ifelse(m_zero, e_orig, e)
    return (m_final, e_final)
end

"""
    _sf_normalize_clz(wr, result_exp) -> (wr, result_exp)

Normalize working result so leading 1 is at bit 55.
Six-stage binary-search CLZ (count leading zeros).
"""
@inline function _sf_normalize_clz(wr::UInt64, result_exp::Int64)
    need32 = (wr & (UInt64(0xFFFFFFFF) << 24)) == UInt64(0)
    wr = ifelse(need32, wr << 32, wr)
    result_exp = ifelse(need32, result_exp - Int64(32), result_exp)

    need16 = (wr & (UInt64(0xFFFF) << 40)) == UInt64(0)
    wr = ifelse(need16, wr << 16, wr)
    result_exp = ifelse(need16, result_exp - Int64(16), result_exp)

    need8 = (wr & (UInt64(0xFF) << 48)) == UInt64(0)
    wr = ifelse(need8, wr << 8, wr)
    result_exp = ifelse(need8, result_exp - Int64(8), result_exp)

    need4 = (wr & (UInt64(0xF) << 52)) == UInt64(0)
    wr = ifelse(need4, wr << 4, wr)
    result_exp = ifelse(need4, result_exp - Int64(4), result_exp)

    need2 = (wr & (UInt64(0x3) << 54)) == UInt64(0)
    wr = ifelse(need2, wr << 2, wr)
    result_exp = ifelse(need2, result_exp - Int64(2), result_exp)

    need1 = (wr & (UInt64(1) << 55)) == UInt64(0)
    wr = ifelse(need1, wr << 1, wr)
    result_exp = ifelse(need1, result_exp - Int64(1), result_exp)

    return (wr, result_exp)
end

"""
    _sf_handle_subnormal(wr, result_exp, result_sign) -> (wr, result_exp, flushed_result, subnormal, flush_to_zero)

Handle subnormal result (exponent underflow). Returns updated wr, result_exp,
and the flushed-to-zero result for use in the final select chain.
Also returns `subnormal` and `flush_to_zero` flags.

# Bennett-xiqt / U133 — flush boundary investigation

The review (reviews/2026-04-21/11_softfloat.md F8/M6) flagged
`flush_to_zero = shift_sub >= 56` as potentially dropping the round-up
case for values whose true magnitude is just above half of smallest
subnormal. Per IEEE-754 RTNE, such values should round UP to smallest
subnormal (frac = 1), not flush to ±0.

**Empirical investigation (Bennett-xiqt):** 200k+ random fmul, 200k+
random fdiv, 100k each of fadd/fsub/fma calls with subnormal-range
inputs produced ZERO disagreements vs `Base.*` / `Base.fma`. The flush
boundary IS exercised at `shift_sub ∈ [56, 60]` (~0.4% of fmul calls)
AND wr's bit 55 IS always set in those cases — but the wr encoding
at the boundary doesn't have a naive "bit 55 = round bit" reading.
For all observed inputs, `Base.*` ALSO rounds these to ±0 (the true
mathematical value is below half of smallest subnormal because of
how fmul scales wr).

**Disposition:** investigated, doc-only. The theoretical RTNE-incorrectness
at `shift_sub == 56` with bit 55 set is not triggered by any current
soft_f* caller. `test/test_xiqt_subnormal_boundary.jl` pins the
empirical-agreement contract as a regression guard against future
changes to (a) this helper or (b) the wr encoding produced by
fmul/fdiv/fma/fadd. If a future caller IS constructed that disagrees
with `Base.*`, that test will trip and reopen this bead.
"""
@inline function _sf_handle_subnormal(wr::UInt64, result_exp::Int64, result_sign::UInt64)
    subnormal = result_exp <= Int64(0)
    shift_sub = Int64(1) - result_exp
    flush_to_zero = shift_sub >= Int64(56)
    shift_clamped = clamp(shift_sub, Int64(0), Int64(63))
    shift_u = UInt64(ifelse(flush_to_zero, Int64(0), shift_clamped))
    lost_mask_sub = (UInt64(1) << shift_u) - UInt64(1)
    lost_sub = ifelse((wr & lost_mask_sub) != UInt64(0), UInt64(1), UInt64(0))
    wr_sub_result = (wr >> shift_u) | lost_sub
    flushed_result = result_sign << 63

    wr = ifelse(subnormal,
         ifelse(flush_to_zero, wr, wr_sub_result),
         wr)
    result_exp = ifelse(subnormal, Int64(0), result_exp)

    return (wr, result_exp, flushed_result, subnormal, flush_to_zero)
end

"""
    _sf_round_and_pack(wr, result_exp, result_sign) -> (normal_result, exp_overflow, exp_overflow_after_round)

Round to nearest even (IEEE 754 default), pack into Float64 bit pattern.
"""
@inline function _sf_round_and_pack(wr::UInt64, result_exp::Int64, result_sign::UInt64)
    # Overflow check
    exp_overflow = result_exp >= Int64(0x7FF)
    overflow_result = (result_sign << 63) | INF_BITS

    # Round to nearest even
    guard      = (wr >> 2) & UInt64(1)
    round_bit  = (wr >> 1) & UInt64(1)
    sticky_bit = wr & UInt64(1)
    frac       = (wr >> 3) & FRAC_MASK

    grs = (guard << 2) | (round_bit << 1) | sticky_bit
    round_up = (grs > UInt64(4)) | ((grs == UInt64(4)) & ((frac & UInt64(1)) != UInt64(0)))

    frac_rounded = frac + UInt64(1)
    mant_overflow = frac_rounded == IMPLICIT
    frac_final = ifelse(round_up,
                 ifelse(mant_overflow, UInt64(0), frac_rounded),
                 frac)
    exp_after_round = ifelse(round_up & mant_overflow,
                             result_exp + Int64(1),
                             result_exp)
    exp_overflow_after_round = exp_after_round >= Int64(0x7FF)

    # Pack normal result
    exp_pack = UInt64(clamp(exp_after_round, Int64(0), Int64(0x7FE)))
    normal_result = (result_sign << 63) | (exp_pack << 52) | frac_final

    return (normal_result, overflow_result, exp_overflow, exp_overflow_after_round)
end

# ────────────────────────────────────────────────────────────────────────
# 128-bit helpers for soft_fma (Bennett-0xx3)
#
# All branchless `@inline`. 128-bit values are represented as (hi, lo)
# UInt64 pairs, matching the pattern in `fsqrt.jl` for 128-bit radicand.
#
# # Bennett-yys3 / U163 — historical "no UInt128" rationale is stale
#
# The original docstring claimed UInt128 emits `__udivti3` / `__umodti3`
# compiler-rt intrinsics that lower_call! couldn't extract. Empirically
# (Julia 1.12, verified by `test/test_yys3_uint128_compiler_rt.jl`):
# UInt128 ops `*`, `+`, `-`, `<<`, `>>`, `÷`, `%` all compile to inlined
# sequences with NO compiler-rt calls. The hand-rolled hi/lo helpers
# below could be replaced by native UInt128 arithmetic with no
# compiler-rt risk.
#
# Why kept as-is: the helpers' explicit hi/lo decomposition is the
# direct ancestor of the gate sequence soft_fma emits; replacing them
# with native UInt128 ops would shift soft_fma's gate-emission profile
# and require re-measuring every soft_fma baseline (CLAUDE.md §6). Out
# of scope for the bugs-only directive that surfaced this; the contract
# tests in `test/test_yys3_uint128_compiler_rt.jl` pin the helpers'
# correctness so a future refactor can cross-check.
# ────────────────────────────────────────────────────────────────────────

"""
    _sf_widemul_u64_to_128(a, b) -> (hi, lo)

Full 64×64 → 128-bit unsigned multiply. Returns `(hi, lo)` such that
`(hi << 64) | lo == a * b` mathematically. Uses four 32×32 partial
products; each fits in UInt64 without overflow.

General-purpose (vs. the 27×26 decomposition inlined in `soft_fmul`,
which assumes ≤53-bit inputs). Used by `soft_fma` with Berkeley-scaled
63-bit inputs (`ma << 10`, `mb << 10`).
"""
@inline function _sf_widemul_u64_to_128(a::UInt64, b::UInt64)
    a_lo = a & UInt64(0xFFFFFFFF)
    a_hi = a >> 32
    b_lo = b & UInt64(0xFFFFFFFF)
    b_hi = b >> 32

    pp_ll = a_lo * b_lo       # ≤ (2^32-1)^2 < 2^64
    pp_lh = a_lo * b_hi
    pp_hl = a_hi * b_lo
    pp_hh = a_hi * b_hi

    # Full product layout (bits):
    #   pp_ll occupies  [0   .. 63]
    #   pp_lh, pp_hl    [32  .. 95]
    #   pp_hh           [64  .. 127]
    # Accumulate into (hi, lo).
    mid = pp_lh + pp_hl
    mid_carry = ifelse(mid < pp_lh, UInt64(1), UInt64(0))   # overflow bit

    mid_lo = mid << 32
    mid_hi = (mid >> 32) | (mid_carry << 32)

    lo = pp_ll + mid_lo
    lo_carry = ifelse(lo < pp_ll, UInt64(1), UInt64(0))

    hi = pp_hh + mid_hi + lo_carry
    return (hi, lo)
end

"""
    _add128(a_hi, a_lo, b_hi, b_lo) -> (hi, lo)

128-bit unsigned add: `(a_hi<<64 | a_lo) + (b_hi<<64 | b_lo) mod 2^128`.
"""
@inline function _add128(a_hi::UInt64, a_lo::UInt64, b_hi::UInt64, b_lo::UInt64)
    lo = a_lo + b_lo
    carry = ifelse(lo < a_lo, UInt64(1), UInt64(0))
    hi = a_hi + b_hi + carry
    return (hi, lo)
end

"""
    _sub128(a_hi, a_lo, b_hi, b_lo) -> (hi, lo)

128-bit unsigned subtract: `(a_hi<<64 | a_lo) - (b_hi<<64 | b_lo) mod 2^128`.
"""
@inline function _sub128(a_hi::UInt64, a_lo::UInt64, b_hi::UInt64, b_lo::UInt64)
    lo = a_lo - b_lo
    borrow = ifelse(a_lo < b_lo, UInt64(1), UInt64(0))
    hi = a_hi - b_hi - borrow
    return (hi, lo)
end

"""
    _neg128(a_hi, a_lo) -> (hi, lo)

Two's complement negation of a 128-bit value. Equivalent to
`(UInt128(0) - ((a_hi << 64) | a_lo))`.
"""
@inline function _neg128(a_hi::UInt64, a_lo::UInt64)
    lo = (~a_lo) + UInt64(1)
    carry = ifelse(lo == UInt64(0), UInt64(1), UInt64(0))
    hi = (~a_hi) + carry
    return (hi, lo)
end

"""
    _shl128_by1(a_hi, a_lo) -> (hi, lo)

128-bit left shift by 1.
"""
@inline function _shl128_by1(a_hi::UInt64, a_lo::UInt64)
    hi = (a_hi << 1) | (a_lo >> 63)
    lo = a_lo << 1
    return (hi, lo)
end

"""
    _shr128jam_by1(a_hi, a_lo) -> (hi, lo)

128-bit right shift by 1 with sticky jam: the bit that falls off the
bottom is OR-ed into bit 0 of the new low limb.
"""
@inline function _shr128jam_by1(a_hi::UInt64, a_lo::UInt64)
    sticky = a_lo & UInt64(1)
    hi = a_hi >> 1
    lo = (a_lo >> 1) | (a_hi << 63) | sticky
    return (hi, lo)
end

"""
    _shiftRightJam128(a_hi, a_lo, dist) -> (hi, lo)

Branchless 128-bit right shift with sticky jam, semantics per Berkeley
SoftFloat 3 `s_shiftRightJam128.c`. All bits shifted out of the bottom
are OR-reduced into bit 0 of the returned low limb.

  dist ≤ 0    → no shift
  0 < d < 64  → hi' = hi >> d
                lo' = (hi << (64-d)) | (lo >> d) | sticky_of(lo_low_d_bits)
  64 ≤ d<128  → hi' = 0
                lo' = (hi >> (d-64)) | sticky_of(low_bits_including_lo)
  d ≥ 128     → hi' = 0; lo' = (hi | lo) != 0 ? 1 : 0

All paths computed unconditionally; selected with `ifelse`. Handles
Julia's `x << 64 == x` shift-count-truncation quirk by using an explicit
mask rather than `x << (64 - d)` when d == 0.
"""
@inline function _shiftRightJam128(a_hi::UInt64, a_lo::UInt64, dist::Int64)
    # Handle the trivial no-shift case separately to avoid the `64 - d` UB
    # at d == 0, and then the range-clamped inner computations handle the
    # rest branchlessly.
    nonpos = dist <= Int64(0)

    # Case A: 0 < d < 64. Use a clamped d' ∈ [1, 63] for mask/shift safety.
    dA = clamp(dist, Int64(1), Int64(63))
    dA_u = UInt64(dA)
    lostA_mask = (UInt64(1) << dA_u) - UInt64(1)
    stickyA = ifelse((a_lo & lostA_mask) != UInt64(0), UInt64(1), UInt64(0))
    hiA = a_hi >> dA_u
    loA = (a_hi << (UInt64(64) - dA_u)) | (a_lo >> dA_u) | stickyA

    # Case B: 64 ≤ d < 128. Use clamped d' ∈ [64, 127] and shift by d-64.
    dB = clamp(dist, Int64(64), Int64(127))
    dB_u = UInt64(dB - Int64(64))   # 0..63
    # Bits lost: a_lo (entirely) and the low dB_u bits of a_hi.
    # Use two masks to accumulate the sticky: `a_lo != 0` (always lost when d≥64)
    # OR low dB_u bits of a_hi. If dB_u == 0, the hi mask is all zero → sticky
    # comes from a_lo only. If dB_u == 63, covers low 63 bits of a_hi.
    hi_lost_mask_B = (UInt64(1) << dB_u) - UInt64(1)
    stickyB = ifelse((a_lo != UInt64(0)) | ((a_hi & hi_lost_mask_B) != UInt64(0)),
                     UInt64(1), UInt64(0))
    hiB = UInt64(0)
    loB = (a_hi >> dB_u) | stickyB

    # Case C: d ≥ 128. Everything sticky.
    hiC = UInt64(0)
    loC = ifelse((a_hi | a_lo) != UInt64(0), UInt64(1), UInt64(0))

    # Select: nonpos → (a_hi, a_lo); d < 64 → A; d < 128 → B; else C.
    big = dist >= Int64(128)
    mid = dist >= Int64(64)
    hi_sel = ifelse(big, hiC, ifelse(mid, hiB, hiA))
    lo_sel = ifelse(big, loC, ifelse(mid, loB, loA))
    hi = ifelse(nonpos, a_hi, hi_sel)
    lo = ifelse(nonpos, a_lo, lo_sel)
    return (hi, lo)
end

"""
    _sf_clz128_to_hi_bit61(hi, lo, e) -> (hi, lo, e)

Normalize the 128-bit value `(hi << 64) | lo` so its leading 1 is at
bit 125 (= bit 61 of `hi`). Decrements exponent `e` by the shift count
and propagates bits from `lo` into `hi` at each stage. Six-stage
branchless binary-search CLZ over the 128-bit value.

Used by `soft_fma` because Berkeley's `<<10`/`<<9` scaling convention
places the normalized 128-bit product's leading 1 at bit 125. After
opposite-sign subtraction with cancellation, leading 1 drops below 125;
this helper shifts it back, bringing up low-limb bits into the high
limb so no precision is lost. Callers must pre-normalize any bits above
bit 125 (via `>>1 with sticky`) before calling.

Precondition: `(hi, lo) != (0, 0)` and leading 1 at position ≤ 125.
Callers that might pass the zero pair substitute `hi = UInt64(1)`
(value recovered via the select chain).
"""
@inline function _sf_clz128_to_hi_bit61(hi::UInt64, lo::UInt64, e::Int64)
    need32 = (hi & (UInt64(0xFFFFFFFF) << 30)) == UInt64(0)
    hi = ifelse(need32, (hi << 32) | (lo >> 32), hi)
    lo = ifelse(need32, lo << 32, lo)
    e  = ifelse(need32, e - Int64(32), e)

    need16 = (hi & (UInt64(0xFFFF) << 46)) == UInt64(0)
    hi = ifelse(need16, (hi << 16) | (lo >> 48), hi)
    lo = ifelse(need16, lo << 16, lo)
    e  = ifelse(need16, e - Int64(16), e)

    need8 = (hi & (UInt64(0xFF) << 54)) == UInt64(0)
    hi = ifelse(need8, (hi << 8) | (lo >> 56), hi)
    lo = ifelse(need8, lo << 8, lo)
    e  = ifelse(need8, e - Int64(8), e)

    need4 = (hi & (UInt64(0xF) << 58)) == UInt64(0)
    hi = ifelse(need4, (hi << 4) | (lo >> 60), hi)
    lo = ifelse(need4, lo << 4, lo)
    e  = ifelse(need4, e - Int64(4), e)

    need2 = (hi & (UInt64(0x3) << 60)) == UInt64(0)
    hi = ifelse(need2, (hi << 2) | (lo >> 62), hi)
    lo = ifelse(need2, lo << 2, lo)
    e  = ifelse(need2, e - Int64(2), e)

    need1 = (hi & (UInt64(1) << 61)) == UInt64(0)
    hi = ifelse(need1, (hi << 1) | (lo >> 63), hi)
    lo = ifelse(need1, lo << 1, lo)
    e  = ifelse(need1, e - Int64(1), e)

    return (hi, lo, e)
end

