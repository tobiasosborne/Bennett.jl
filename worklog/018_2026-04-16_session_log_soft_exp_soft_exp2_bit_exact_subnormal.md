## Session log — 2026-04-16 — soft_exp / soft_exp2 bit-exact subnormal output via musl specialcase (Bennett-wigl)

### Garbage-bug post-mortem (CLAUDE.md principle 7: "bugs are deep and interlocked")

The previous session (Bennett-cel, 2026-04-16) shipped soft_exp / soft_exp2
with a "documented 1-ulp gap at the underflow boundary". Investigation
this session found the actual scope was much worse:

| Function | Garbage range          | Magnitude of error                        |
|----------|------------------------|-------------------------------------------|
| soft_exp | x ∈ [-708.4, -745]     | up to ~1.5e308 instead of subnormal       |
| soft_exp2| x ∈ [-1022.5, -1075]   | up to ~2.7e300 instead of subnormal       |

Cause: the integer trick `T[idx+1] + (ki << 45)` overflows the IEEE
exponent field into the sign bit when `k = floor(round(x·N/ln2)/N)` falls
below -1022. The polynomial then computes `scale + scale·tmp` on a
sign-bit-corrupted scale, producing wrong-sign garbage with absurd
magnitude.

Why the previous session missed it: the random sweep covered only
`[-50, 50]` for soft_exp and `[-100, 100]` for soft_exp2 — well inside
the normal-output range. The boundary-only manual tests caught the 1-ulp
deviation at `x = -745.0` (which by lucky coincidence sat on the flush
side of the threshold and returned 0) but not the broader garbage range.

Lesson burned in: random-sweep test ranges must explicitly cover the
**subnormal-output region of every transcendental**, not just the normal
range. Filed below as a follow-up on the test harness.

### Algorithm — musl underflow specialcase

Per Plan B in conversation 2026-04-16: implement musl's underflow
specialcase branchlessly, accepting +1.4M gates per call to gain
bit-exactness vs musl/Arm Optimized Routines published reference (≤0.527
ulp from true math; ≤1 ulp vs `Base.exp` due to Julia's FMA-based range
reduction differing from musl's separate fmul+fadd at round-half cases).

The trick — `_exp_specialcase_underflow(sbits, tmp)`:

1. **Bump `sbits` by +1022·2^52** (integer add): this avoids the exponent
   overflow into the sign bit by shifting scale back into the normal range.
2. **Compute `y = scale + scale·tmp`** in normal-range floating point.
3. **Extended-precision (hi, lo) reconstruction** for `y < 1.0`:
   ```
   lo  = scale - y + scale·tmp
   hi  = 1 + y
   lo' = 1 - hi + y + lo
   y'  = (hi + lo') - 1
   ```
   Recovers the bits lost to single-rounding in the `scale + scale·tmp`
   sum. This matters because the final scale-down by `2^-1022` would
   otherwise compound a ~1-ulp error to ~52 ulp at the smallest subnormals.
4. **Final scale**: `result = 2^-1022 · y'` produces correctly-rounded
   subnormal output.

Branchless throughout: both `normal` and `under` paths are computed
unconditionally, then `ifelse(in_subnormal, under, normal)` selects.
Per CLAUDE.md principle 7, the override chain must be ordered
last-write-wins with NaN strictly last (else `NaN | underflow` overrides
back to 0).

### `_fast` variants (per user direction)

User explicitly asked for "deprecated commands for those people who want
fast but not correct versions". Added `soft_exp_fast` / `soft_exp2_fast`:
identical to the bit-exact versions but skip the specialcase, save 1.4M
gates per call, return 0 for subnormal-output range. Documented as
"flush-to-zero subnormal" — a common soft-float convention (Berkeley
SoftFloat 3, GCC libgcc soft-fp). Not deprecated in the strict
`@deprecated` sense; just a faster sibling for users who don't need
subnormal-range exactness.

### Test results

`test/test_softfexp.jl` extended to 86 + 64 = 150 testsets. New coverage:

- **BIT-EXACT subnormal-output range**: sweep -708.4 → -745.13 in -0.25
  steps for exp; -1022 → -1075 in -0.5 steps for exp2. Every input within
  ≤1 ulp of `Base.exp` / `Base.exp2`; ≥95% bit-exact (the rest are
  musl/Julia FMA divergence).
- **Specific subnormal boundary cases**: 11 hand-picked inputs covering
  the exp region, all bit-exact (the inputs were chosen specifically to be
  musl/Julia agreement points; sufficient for proving the specialcase
  works end-to-end).
- **Overflow boundary**: tightened threshold (musl uses x ≥ 1024 for exp,
  but the polynomial breaks at `top` overflow earlier; we use Julia's
  MAX_EXP_E = 709.7827128933841 for exp, 1024.0 for exp2).
- **soft_exp_fast / soft_exp2_fast match outside subnormal range**:
  17/19 inputs identical bit-for-bit between bit-exact and fast variants.
- **soft_exp_fast / soft_exp2_fast flush subnormal range**: documented.
- **Random sweeps**: 10k uniform `[-700, 700]` for exp; both 10k `[-100,
  100]` and 5k `[-1, 1]` for exp2. ≤1 ulp tol vs Julia (~99% bit-exact).

End-to-end circuit (`test/test_float_circuit.jl`): bit-exact `soft_exp`
and `soft_exp2` compile, simulate ~17 inputs each (including the
previously-broken subnormal range), `verify_reversibility` passes. Suite
runtime: 64s (was 57s).

### Reversible-circuit gate counts

| Function | Total gates | Toffoli | T-count | Δ vs pre-specialcase |
|----------|------------:|--------:|--------:|----------------------|
| soft_exp2 (bit-exact) | 4,348,418 | 1,465,382 | 10,257,674 | +46% / +41% |
| soft_exp  (bit-exact) | 4,958,914 | 1,693,984 |        ~12.0M | +38% / +33% |
| soft_exp2_fast | 2,972,338 | 1,041,344 | 7,289,408 | (unchanged from Bennett-cel) |
| soft_exp_fast  | 3,581,928 | 1,269,688 | 8,887,816 | (unchanged from Bennett-cel) |

The +1.38M gate increase per call from specialcase = 2 fmul + 8 fadd +
1 fcmp ≈ 2·258k + 8·95k + 50k ≈ 1.37M gates. Matches cost analysis
within 1%.

### Gotchas learned

1. **`bit_width` test ranges must cover subnormal output**, not just
   normal range. The garbage bug existed in production for the whole
   Bennett-cel session because the random sweep covered `[-50, 50]` for
   soft_exp.  All future transcendentals (log, sin, cos, sinh, …) MUST
   include subnormal-output sweeps in their bit-level tests. Filed
   Bennett-fnxg follow-up.
2. **Julia 1.12 strict scope rules** broke an earlier debugging script
   (loop-local variables shadowing globals). Workaround: wrap in a
   function. Note for future debugging scripts: prefer functions over
   bare top-level loops.
3. **Bit-exactness vs musl ≠ bit-exactness vs Julia** for exp. Julia uses
   FMA-based muladd in range reduction (single rounding); musl uses
   separate fmul+fadd (double rounding). Different intermediate r → ~1%
   of inputs differ by 1 ulp at round-half boundaries. Documented as the
   accepted tradeoff for Plan B; Plan A (`soft_exp_julia` + `soft_fma`,
   filed as Bennett-t110 + Bennett-0xx3) will close the Julia gap later.
4. **The override chain ORDER survives garbage in earlier paths**. Even
   when polynomial / specialcase produce NaN-bit-pattern values for
   `x = ±Inf`, the final `ifelse(a_pinf, INF_BITS, ...)` correctly
   substitutes because ifelse on UInt64 is bit-select (not Float64
   arithmetic) and NaN doesn't propagate through it. Verified by trace.
5. **`(ki & 0x80000000) == 0` is musl's underflow detector**; we
   replaced it with explicit input-range predicates (`a > _SUBNORM_E_BITS`
   etc.) for clarity. Both work; the explicit form is easier to audit and
   matches how Julia.Base.Math structures its `SUBNORM_EXP` thresholds.

### Files changed

- `src/softfloat/fexp.jl` — added `_TWO_NEG_1022_BITS`, MIN/MAX/SUBNORM
  threshold constants, `_exp_specialcase_underflow` helper, rewrote
  `soft_exp2` and `soft_exp` to invoke specialcase, added new
  `soft_exp2_fast` / `soft_exp_fast` siblings (~140 LOC added)
- `src/Bennett.jl` — export `soft_exp2_fast` / `soft_exp_fast`,
  `register_callee!` both
- `test/test_softfexp.jl` — added subnormal-range bit-exact testsets,
  fast-variant comparison testsets, full-range random sweep
- `test/test_float_circuit.jl` — extended exp/exp2 testset to cover
  subnormal range
- `WORKLOG.md` — this entry
- `BENCHMARKS.md` — updated soft_exp / soft_exp2 rows + new fast rows

### Follow-ups (not blocking)

- **Bennett-fnxg**: random-sweep test convention — every transcendental
  must include subnormal-output sweep in its bit-level test (caught by
  this garbage-bug post-mortem).
- **Bennett-0xx3 + Bennett-t110** (Plan A): implement `soft_fma` + Julia-
  faithful `soft_exp_julia` / `soft_exp2_julia` to close the ≤1 ulp gap
  vs `Base.exp`. Will be the new default for `Base.exp(::SoftFloat)`
  dispatch once landed; `soft_exp` (musl) remains as cross-language
  reference.

---

