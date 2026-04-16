# soft_fma Design Consensus — Bennett-0xx3

Synthesized from three parallel research subagents (software algorithm,
reversible gate cost, quantum literature) dispatched 2026-04-16. This doc
pins the concrete choices the implementer will follow. Any deviation
requires re-opening Bennett-0xx3.

## Novelty

First IEEE 754 binary64 reversible fused multiply-add with single rounding
in the quantum / reversible-circuit literature. Häner-Soeken-Roetteler-Svore
2018 (arXiv:1807.02023) implements only FP add and mul; §7 explicitly names
FMA as a useful combination (Horner scheme) but does not implement it; §8
future work does not propose it either. The 2024 comprehensive survey
(arXiv:2406.03867) §2.3 enumerates every known reversible-FP circuit:
"no mention of fused multiply-add (FMA)" and "only single-precision
(binary32) implementations". AnanthaLakshmi-Sudha 2017 (Microprocessors and
Microsystems v.51) is adiabatic-CMOS FP32 with [verify]-unconfirmed IEEE
single-rounding semantics — not in the quantum Clifford+T regime.

## Sources (ground truth — all read verbatim by Agent 1)

Primary algorithm reference:

- **Berkeley SoftFloat 3** `source/s_mulAddF64.c` (Hauser, 496 lines) —
  SOFTFLOAT_FAST_INT64 path. The blueprint. URL:
  `https://raw.githubusercontent.com/ucb-bar/berkeley-softfloat-3/master/source/s_mulAddF64.c`
- Berkeley `source/s_shiftRightJam128.c` — 128-bit right-shift with sticky
  jam. Semantics we replicate.
- Berkeley `source/s_shiftRightJam64.c` — 64-bit variant.
- Berkeley `source/s_roundPackToF64.c` — rounding (we substitute our
  `_sf_round_and_pack`).

Secondary reference:

- **musl** `src/math/fma.c` (183 lines) — cleaner structure than Berkeley
  but ends with a `scalbn` + hardware float step; NOT directly usable
  because Bennett.jl must stay in integer arithmetic. Read for algorithmic
  cross-check.

Not used (verified unnecessary): GCC libgcc soft-fp (CPP-macro heavy,
equivalent to Berkeley), fdlibm `s_fma.c` (not universally present).

Spec: IEEE 754-2019 §5.4.1 "fusedMultiplyAdd: `fma(a, b, c) = round(a·b + c)`
with single correctly-rounded result, `Inf·0 + x = qNaN (invalid)`, NaN
propagation per §6.2."

## Target

```julia
soft_fma(a::UInt64, b::UInt64, c::UInt64)::UInt64
```

Bit-exact vs `Base.fma(::Float64, ::Float64, ::Float64)` across:
- 200k+ random `reinterpret(UInt64, rand(Float64))` sweep
- subnormal-input, subnormal-output, near-cancellation, signed-zero, NaN,
  Inf·0, overflow, single-rounding-witness edge cases (see §Test plan)

Branchless `@inline`. No UInt128. Uses the 56-bit working format
(bit 55 = leading 1, bits 54–3 = fraction, bits 2/1/0 = G/R/S) that
`_sf_round_and_pack` consumes.

## Intermediate width: 128 bits (2×UInt64)

**Resolved against Agent 2's 160-bit proposal** — Agent 1's ground-truth
analysis wins. Berkeley explicitly proved 128 bits is both necessary and
sufficient:

- 53×53 product = 106 bits (bits 0..105 of a 128-bit register).
- With Berkeley's `<<10` scaling, product leading 1 lands at bit 126
  (or bit 125 if no carry, conditionally doubled).
- For `expDiff > 74` (c far below product), c collapses into a single
  sticky bit via `_shiftRightJam128`.
- For `expDiff < 0` (product far below c), product collapses similarly.
- The 22 bits of headroom (128 − 106) cover: the conditional `<<1`
  normalization, the same-sign add carrying into bit 127, and the
  shiftRightJam sticky-accumulation bit.

160 bits is over-provisioned and adds a wider CLZ stage (~3× cost) for no
correctness gain.

## Berkeley scaling convention (locked)

After unpacking and subnormal pre-normalization via `_sf_normalize_to_bit52`:

| Quantity | Scaling | Leading 1 position | Rationale |
|----------|---------|--------------------|-----------|
| `ma`, `mb` | `<<10` | bit 62 (of each 64-bit) | Product = `(ma<<10) * (mb<<10)` lands 53+53+20=126 bits wide |
| `mc` | `<<9` | bit 61 | One less than product's per-limb position — makes same-sign add naturally overflow into bit 63 of `hi` limb as carry signal |

**Mandatory normalization after product** (Berkeley line 122):

```julia
prod_lead_low = p_hi < UInt64(0x2000000000000000)
(p_hi, p_lo)  = ifelse(prod_lead_low, shl128_by1(p_hi, p_lo), (p_hi, p_lo))
expZ          = ifelse(prod_lead_low, expZ - 1, expZ)
```

Puts product's leading 1 unconditionally at bit 126. Downstream code
relies on this.

## Case breakdown on `expDiff = expZ - ec_eff`

All cases computed unconditionally, selected via `ifelse`. No branches.

| Case | Action |
|------|--------|
| `expDiff > 0` | Product dominates. Shift `(mc_s, 0)` right-jam by `expDiff` into `(c_hi, c_lo)`. Use `(p_hi, p_lo)` directly as product side. |
| `expDiff < 0` | C dominates. `expZ = ec_eff`. Shift `(p_hi, p_lo)` right-jam by `-expDiff`. Use `(mc_s, 0)` directly as c side. |
| `expDiff == -1 & opp sign` | **Precision-preservation trick** (Berkeley line 144): use `>>1` on product, not full right-jam. Preserves one extra bit for cancellation CLZ to consume. Without this, 1-ulp error on specific cancellation inputs. |
| `expDiff == 0` | Natural alignment. |

After alignment, have `(p_side_hi, p_side_lo)` and `(c_side_hi, c_side_lo)`
both in the product's exponent frame.

## Add/sub path

```julia
same_sign = sign_prod == sc
(sum_hi, sum_lo) = _add128(p_side_hi, p_side_lo, c_side_hi, c_side_lo)
(dif_hi, dif_lo) = _sub128(p_side_hi, p_side_lo, c_side_hi, c_side_lo)
(wr_hi, wr_lo)   = ifelse(same_sign, (sum_hi, sum_lo), (dif_hi, dif_lo))

# Opposite-sign underflow: if top bit of wr_hi set after subtraction, we
# subtracted the larger from the smaller. Negate and flip result_sign.
underflow        = (!same_sign) & ((wr_hi >> 63) != 0)
(neg_hi, neg_lo) = _neg128(wr_hi, wr_lo)
wr_hi            = ifelse(underflow, neg_hi, wr_hi)
wr_lo            = ifelse(underflow, neg_lo, wr_lo)
```

**Complete cancellation** (Berkeley lines 178, 232–237):
`expDiff == 0 & !same_sign & wr_hi == 0 & wr_lo == 0` → return `+0.0`
under round-to-nearest-even (our only mode). Do NOT let sign bit flip.

**Result sign** (Berkeley rules, §Agent-1 pitfall 8):
- `expDiff < 0`: `result_sign = sc` (c dominated).
- `expDiff > 0`: `result_sign = sign_prod`.
- `expDiff == 0`: `result_sign = sign_prod`, flipped iff `underflow`.

## Renormalize

```julia
# Same-sign carry into bit 127 → >>1 jam, ++expZ
same_sign_carry = same_sign & ((wr_hi >> 63) != 0)
(wr_hi, wr_lo)  = ifelse(same_sign_carry, _shr128jam_by1(wr_hi, wr_lo), (wr_hi, wr_lo))
expZ            = ifelse(same_sign_carry, expZ + 1, expZ)

# Opposite-sign cancellation: CLZ on wr_hi. If wr_hi == 0, fold wr_lo up.
hi_zero         = wr_hi == 0
wr_hi_folded    = ifelse(hi_zero, wr_lo, wr_hi)
wr_lo_remainder = ifelse(hi_zero, UInt64(0), wr_lo)
expZ            = ifelse(hi_zero, expZ - 64, expZ)

# 6-stage CLZ to bring leading 1 of wr_hi_folded back to bit 62
(wr_hi_norm, expZ) = _sf_clz_to_bit62(wr_hi_folded, expZ)

# Collect sticky from the non-shifted low limb bits
sticky = ifelse(wr_lo_remainder != 0, UInt64(1), UInt64(0))
```

## Collapse to 56-bit working format

After renormalization, `wr_hi_norm` has leading 1 at bit 62 of a 64-bit
value. `_sf_round_and_pack` expects leading 1 at bit 55 with G/R/S at
bits 2/1/0 of a 56-bit payload. The shift is 7 bits:

```julia
# bits 62..7 → bits 55..0; bits 6..0 fold into sticky
low7_nonzero = (wr_hi_norm & UInt64(0x7F)) != 0
wr_56 = (wr_hi_norm >> 7) | ifelse(low7_nonzero | (sticky != 0), UInt64(1), UInt64(0))
```

Note: the low-7 bits of `wr_hi_norm` AND the entire `wr_lo_remainder` both
fold into the single sticky bit at position 0 of the 56-bit payload — OR
them together. This is the last place precision is lost, and it's the
single-rounding step.

## Tail (reuse existing primitives verbatim)

```julia
(wr_56, expZ, flushed, subnormal, flush_to_zero) =
    _sf_handle_subnormal(wr_56, expZ, result_sign)
(normal, overflow_result, exp_overflow, exp_overflow_after_round) =
    _sf_round_and_pack(wr_56, expZ, result_sign)
```

## Final select chain (priority-ordered, last-write-wins)

Order matters — see WORKLOG Bennett-wigl for the last-write-wins invariant
and Bennett-cel for the NaN-strictly-last rule.

```julia
result = normal
result = ifelse(exp_overflow | exp_overflow_after_round, overflow_result, result)
result = ifelse(subnormal & flush_to_zero, flushed, result)
result = ifelse(complete_cancel, UInt64(0), result)       # +0 under RNE
result = ifelse(zero_prod & !c_nan & !c_inf, c_result_with_sign_rule, result)
result = ifelse(c_zero & !prod_is_inf & !any_nan, prod_as_float, result)
result = ifelse(inf_clash, QNAN, result)                  # Inf + -Inf
result = ifelse(prod_is_inf & !inf_clash, (sign_prod << 63) | INF_BITS, result)
result = ifelse(c_inf & !prod_is_inf, c, result)
result = ifelse(inf_times_zero, QNAN, result)             # Inf·0 invalid
result = ifelse(any_nan, QNAN, result)                    # STRICTLY LAST
return result
```

Signed-zero rules (§6.3 IEEE 754): `fma(+0, +0, -0) = +0` under RNE;
`fma(-0, +0, -0) = -0`; etc. The `c_result_with_sign_rule` handles this
explicitly — see test case 8.

## New helpers in `src/softfloat/softfloat_common.jl`

All branchless `@inline`. No UInt128.

```julia
@inline _sf_widemul_53x53_to_128(ma_s::UInt64, mb_s::UInt64) -> (hi::UInt64, lo::UInt64)
```
**Hoist from `src/softfloat/fmul.jl` lines 64–127.** The four 27×26 partial
products + 128-bit assembly are currently inline inside `soft_fmul`. Extract
as a reusable helper. Both `soft_fmul` (after refactor) and `soft_fma` call
it. Takes already-scaled inputs (caller applies `<<10` or `<<0` as needed).

```julia
@inline _shiftRightJam128(a_hi::UInt64, a_lo::UInt64, dist::Int64) -> (UInt64, UInt64)
```
Semantics verbatim from Berkeley `s_shiftRightJam128.c`:
- `dist ≤ 0` → `(a_hi, a_lo)` unchanged
- `0 < d < 64` → `hi' = a_hi >> d`; `lo' = (a_hi << (64-d)) | (a_lo >> d) | sticky`
- `64 ≤ d < 128` → `hi' = 0`; `lo' = (a_hi >> (d-64)) | sticky`
- `d ≥ 128` → `hi' = 0`; `lo' = (a_hi | a_lo) != 0 ? 1 : 0`

Sticky = OR of all shifted-out bits. All paths computed, select via `ifelse`
ladder. Clamp shift counts (64/128) to avoid UB-on-shift-by-≥-64 and Julia's
`x << 64 == x` truncation quirk (see `fadd.jl` line 76 pattern).

```julia
@inline _add128(a_hi, a_lo, b_hi, b_lo) -> (hi, lo)
@inline _sub128(a_hi, a_lo, b_hi, b_lo) -> (hi, lo)
@inline _neg128(a_hi, a_lo) -> (hi, lo)            # two's complement
@inline _shl128_by1(hi, lo) -> (hi, lo)            # left shift by 1
@inline _shr128jam_by1(hi, lo) -> (hi, lo)         # right shift by 1 with sticky in bit 0
@inline _sf_clz_to_bit62(hi, e) -> (hi, e)         # 6-stage CLZ targeting bit 62
```

Each 5–15 lines straight-line. Patterns mirror `_sf_normalize_clz`
(softfloat_common.jl line 66).

## Gate-count target

From Agent 2 analysis, corrected for 128-bit (not 160-bit) intermediate:

- **Budget:** 300–400k total gates post-Bennett (WORKLOG Plan A line 45)
- **Estimate:** ~280–350k gates, ~110–140k Toffolis post-Bennett
- **Dominant cost:** the 53×53→106-bit raw product (~120k pre-Bennett,
  ~240k Bennett-wrapped)
- **Secondary:** shiftRightJam128 barrel + 128-bit add/sub + CLZ + select
  chain ≈ 60–100k additional

The raw-product hoist (§helpers) matters: keeps soft_fmul and soft_fma
from emitting two copies. Per CLAUDE.md §12 "no duplicated lowering."

## Test plan (Red-Green TDD, CLAUDE.md §3)

Write `test/test_softfma.jl` BEFORE touching `src/softfloat/fma.jl`.
Watch red. Then implement.

### Hard cases (must pass before random sweep)

1. **Kahan single-rounding witness:** `a = b = 0x1.fffffffffffffp-1`, `c = -1.0`.
   True `a·b + c = -2^-106 + 2^-159`. Bit-exact vs `Base.fma` = `-2^-106`.
   Naive `fadd(fmul(a,b), c)` gives 0 — fails.
2. **Exact cancellation:** `fma(1.5, 2.0, -3.0) == +0.0` (NOT -0.0).
3. **Inf·0 + x:** `fma(Inf, 0.0, 1.0)` = `QNAN` (invalid).
4. **expDiff = −1 opposite-sign precision trick:**
   `a=1.0, b=2.0, c=-1.0-eps()/2`. Exercises Berkeley line-144 path.
5. **Signed zero:** `fma(+0, +0, -0) == +0`; `fma(-0, +0, -0) == -0`;
   `fma(+0, -0, +0) == +0`.
6. **NaN propagation:** any NaN in → QNAN out.
7. **Inf clash:** `fma(Inf, 1.0, -Inf)` = `QNAN`.
8. **Subnormal result from mixed-scale sum:**
   `a = 0x1p-600, b = 0x1p-500, c = 0x1p-1100` — product dominates, c is
   sticky; result is near-subnormal.
9. **Overflow via FMA:** `a = 0x1p1000, b = 1.5, c = 0x1p1023` — test
   overflow boundary.
10. **fma(a, b, 0) ≈ a·b (same scale):** `fma(3.0, 7.0, 0.0) == 21.0`.

### Random sweep (CLAUDE.md §13 bit-exactness + Bennett-fnxg subnormal rule)

- **Normal range:** 200k uniform `reinterpret(UInt64, rand(Float64))` triples
  from `[-1e100, 1e100]`-ish. Compare bit-for-bit vs `Base.fma`.
- **Subnormal-input region:** 50k triples where at least one operand has
  `e == 0`. Per Bennett-fnxg: every soft-float test MUST include this.
- **Subnormal-output region:** 50k triples engineered to produce
  subnormal results (product slightly below `2^-1022`, c offset).
- **Cancellation region:** 50k triples where `a·b ≈ -c` within ~2^-40.
  This is where single-rounding vs double-rounding diverges most visibly.
- **Special mix:** all 64 combinations of {±0, ±Inf, QNaN, SNaN, MAX,
  MIN_NORMAL, MIN_SUBNORMAL, 1.0} × 3 positions. 262,144 cases total —
  still quick.

### End-to-end circuit (`test/test_float_circuit.jl`)

- Compile `soft_fma(a, b, c)` via `reversible_compile`; verify
  `verify_reversibility` passes.
- Simulate 10-15 representative inputs (including one subnormal-output
  and one cancellation); check bit-exact vs `Base.fma`.
- Record gate count, Toffoli count as regression baseline per CLAUDE.md §6.

### soft_fmul non-regression

After the raw-product hoist, run full existing `test/test_softffmul.jl`
suite. All existing 1M+ test cases must still pass. Gate count must not
increase (the refactor is semantics-preserving).

## Wiring into Bennett.jl module

- `src/softfloat/fma.jl` — new file, ~250–350 LOC
- `src/softfloat/softfloat.jl` — `include("fma.jl")` after `include("fmul.jl")`
- `src/softfloat/softfloat_common.jl` — new helpers at bottom of file
- `src/softfloat/fmul.jl` — refactor to call `_sf_widemul_53x53_to_128` helper
- `src/Bennett.jl` — `export soft_fma`; `register_callee!(soft_fma)`;
  `Base.fma(a::SoftFloat, b::SoftFloat, c::SoftFloat) = SoftFloat(soft_fma(a.bits, b.bits, c.bits))`

## Known pitfalls (from Agent 1 ground-truth reading)

1. **Berkeley line 122 normalize-to-bit-126 is mandatory**, not a special
   case. Missing it shifts everything by 1 bit.
2. **Berkeley line 144 expDiff=-1 opposite-sign trick is required** —
   1-ulp error on specific cancellation inputs without it.
3. **Complete-cancellation result is +0**, not ±0, under RNE.
4. **Julia `x << 64 == x`** (Julia's shift-count truncation, unlike C UB).
   Clamp all shift counts explicitly — see `fadd.jl` line 76.
5. **Subnormal c with `mc == 0`**: `_sf_normalize_to_bit52` produces
   pathological output on zero input per its docstring. The final select
   chain catches `c_zero` before using `mc`, so the arithmetic path
   computes garbage that is never selected — verify this is actually true
   by ensuring no division / UB in the main path.
6. **Result sign on opposite-sign subtraction** has three sub-cases (see
   §Case breakdown, result-sign rules). Wrong sign rule is the most common
   fma bug.
7. **Sticky collection across 128 bits**: the single final sticky bit in
   the 56-bit working format must OR in: (a) bits shifted out during
   Berkeley's <<10 / <<9 alignment setup (none — scaling is into higher
   bits, no loss), (b) bits lost during `_shiftRightJam128` alignment of
   c or product, (c) `wr_lo_remainder` after the high-limb CLZ, (d) low 7
   bits of `wr_hi_norm` after the collapse to 56-bit. Missing any of
   these produces 1-ulp errors at round-half boundaries.

## Implementation sequence (milestones)

Per Red-Green TDD + "feedback every ~50 lines" (CLAUDE.md §8):

1. **M1** (~50 LOC): Write `test/test_softfma.jl` with 10 hard cases.
   Run → red. Commit RED test.
2. **M2** (~30 LOC): Extract `_sf_widemul_53x53_to_128` from `fmul.jl`.
   Refactor `soft_fmul` to call it. All existing fmul tests green.
   Commit refactor.
3. **M3** (~80 LOC): Add `_shiftRightJam128`, `_add128`, `_sub128`,
   `_neg128`, `_shl128_by1`, `_shr128jam_by1`, `_sf_clz_to_bit62` helpers.
   Unit-test each against hand-computed cases.
4. **M4** (~200 LOC): Implement `soft_fma` body. Iterate until all 10
   hard cases pass. Expect to re-visit expDiff=-1 trick and complete-
   cancellation-sign at least once.
5. **M5**: Random sweep (200k normal + 50k each subnormal/cancellation).
   Expect 100% bit-exact.
6. **M6**: End-to-end circuit compile + verify_reversibility + gate count.
   Record baseline.
7. **M7**: WORKLOG entry + novelty citation block + BENCHMARKS row +
   commit + push.

## Deferred

- Plan A `soft_exp_julia` (Bennett-t110) unblocks on M7. Do not combine.
- `soft_fms` (fused multiply-subtract) = `soft_fma(a, b, c ⊻ SIGN_MASK)`.
  Trivial wrapper; file as separate issue if/when wanted.
- Further gate reduction (below ~280k) would need a hand-rolled
  `_sf_fma_fused_wide_add!` primitive at the `lower.jl` level. Not
  in scope for this issue; file as a follow-up if the Plan A exp
  transcendental roadmap bottlenecks on it.
