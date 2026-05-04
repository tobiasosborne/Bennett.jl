## Session log — 2026-05-05 — Bennett-bd7f / Tier C1.4 — `soft_acos` + `llvm.acos` dispatch

**Shipped:** see git log around the bd7f close commit. Fourth close in
Tier C1 of the Enzyme parity north-star, follow-on to Bennett-ckvj
(`soft_asin`) shipped 2026-05-04 hours earlier. Same session
spanning midnight UTC.

`soft_acos` is a faithful branchless port of musl `e_acos.c`
(FreeBSD/SunPro 1993, BSD-licensed). **REUSES** the rational `_asin_R(z)`
helper plus the 10 polynomial coefficients (`pS0..pS5`, `qS1..qS4`)
plus `pio2_hi`/`pio2_lo` defined module-private in `fasin.jl`. Both
files live inside `module SoftFloatLib`, so the helper and constants
are visible by name without `import` / `using` — CLAUDE.md §12 (no
duplicated lowering) extends naturally to softfloat. `llvm.acos.f64`
dispatches directly to `soft_acos` in `src/extract/instructions.jl`,
mirroring the ckvj arm. f32 rejected per CLAUDE.md §13.
`_CALLEES_FP_TRANS` extended 17 → 18.

**Empirical accuracy:** 100 primitive tests + N dispatch tests all
green. 100k random samples × 3 seeds across all four in-domain regimes
(tiny / small / pos-large / neg-large) ⇒ max ULP ≤ 2, zero fails.
1075-input subnormal-INPUT binade sweep ⇒ max ULP ≤ 1 (tiny override
bit-exact). 52-input near-1 sweep (x = 1 - 2^-k for k = 1..52) ⇒ max
ULP ≤ 2. **Subnormal-output proven absent** by the test (per §13
contract): acos's range is [0, π] and the smallest reachable non-zero
output is `acos(1 - 2^-52) ≈ 2^-25.5`, normal not subnormal — both
binade sweeps assert `subnormal_outputs == 0`.

**Mode:** direct grind. ~120 LOC primitive port + 8 mechanical wires
(softfloat.jl include + outer + inner export, Bennett.jl outer export,
callees.jl registration, instructions.jl dispatch arm, kmuj counts,
runtests.jl × 2). 3+1 deviation under the Bennett-munq / qpke / ckvj
precedent: dispatcher arm is mechanical; the substantive port is
transcribed from a vetted reference (musl).

**Algorithm:** musl `acos.c`'s 4-regime branchless dispatch:

- `|x| ≤ 2^-57`        → return π/2 bit-exact (tiny override)
- `2^-57 < |x| < 0.5`  → `acos(x) = π/2 - (x - (pio2_lo - x·R(x²)))`
- `x ≤ -0.5`           → `2·(π/2 - (s + (R(z)·s - pio2_lo)))`
                          with `z = (1+x)/2`, `s = √z`
- `x ≥  0.5`           → `2·(df + (R(z)·s + c))`
                          with `z = (1-x)/2`, `s = √z`,
                          `df = high32(s)`, `c = (z - df²)/(s + df)`

Specials: `x = 1 → 0` bit-exact; `x = -1 → π` bit-exact (= 2·pio2_hi
exactly at f64); `|x| > 1 → QNAN`; NaN propagates with quiet bit.

Branchless realisation: ALL 4 regimes computed; ifelse-cascade selects
by sign + magnitude flags. Single `_asin_R(z)` call on ifelse-selected
input (`x²` for small path, `z = (1-|x|)/2` for general).

**Gotchas / Lessons:**

1. **z formula unifies across pos-large and neg-large.** musl's C code
   writes `z = (1+x)*0.5` for x ≤ -0.5 and `z = (1-x)*0.5` for x ≥ 0.5
   — different sign of x in the formula. But both equal `(1-|x|)/2`
   because `1+x = 1-|x|` when x is negative and `1-x = 1-|x|` when x
   is positive. Bennett-branchless uses the unified `z = (1-|x|)/2`,
   simplifying the cascade. Same `s = √z` and `R(z)·s` reused across
   neg/pos sub-paths; only the final composition differs (subtract-
   from-π/2 vs add-df).

2. **`acos(±0) = π/2`, NOT `±0`** (unlike asin). The tiny override
   (`|x| ≤ 2^-57 → π/2`) catches both `+0.0` and `-0.0` because both
   have `ix_hi = 0` ≤ `0x3c600000`. Test asserts bit-exact `==
   reinterpret(UInt64, π/2)` for both signs. Different from
   `soft_asin` where ±0 is sign-preserved via `result = ifelse(is_tiny,
   a, ...)`. Lesson: each transcendental's tiny path has its own
   semantic — don't copy the asin pattern blindly.

3. **`x = 1` triggers 0/0 division at `c = (z - df²)/(s + df)`.** At
   x=1: z=0, s=0, df=0, so c=0/0=NaN. Path D's result_pos becomes NaN.
   The eq1 override (last-but-one before NaN propagation) replaces with
   `0` bit-exact. Same override-masks-dead-path pattern as ckvj's
   `x=1` for asin. Verified by tracing each input through the cascade
   before commit.

4. **`acos` has no subnormal-output regime — §13 contract met by
   demonstrating absence.** acos's range [0, π] means the only way to
   get a subnormal output is acos(x) close to 0, which requires x
   close to 1. The smallest representable f64 less than 1 is `1 -
   2^-52`, giving `acos(1 - 2^-52) ≈ √(2 · 2^-52) = 2^-25.5` which is
   firmly normal. The §13 "subnormal-output sweep" testset documents
   this and asserts `subnormal_outputs == 0` across both the input-
   binade lattice (2^-1075..2^-1) AND the near-1 sweep. Pattern: when
   a transcendental's range bounds away from 0, the §13 contract is
   met by *demonstrated absence* of subnormal outputs across all
   regimes that could in principle produce one.

5. **`Base.acos` THROWS DomainError for |x|>1, same as `Base.asin`.**
   Random-sweep test split: in-domain assertions vs OOB-NaN-only
   assertion (no `Base.acos` oracle). Same handling as ckvj's asin
   sweep. Pattern firmly established for inverse trig with bounded
   domain.

**Rejected alternatives:**

- **Independently inline `_acos_R` in facos.jl** (no helper sharing):
  duplicates 10 polynomial coefficients + the rational composition.
  Violates CLAUDE.md §12. Rejected. The shared module-private helper
  in fasin.jl is the right shape.
- **CORE-MATH 1-ULP correctly-rounded acos**: same trade-off as
  asin/atan/tan — ~400 LOC vs musl's ~80, marginal accuracy gain on
  Bennett's empirical 2-ULP contract. Not pursued.
- **Three-regime dispatch** (collapse pos-large + neg-large into one
  via abs+sign-flip): would simplify the branchless cascade but
  requires more multiplications by ±1 (the result composition
  `2·(df+w)` vs `2·(π/2-(s+w))` differs structurally, not just by
  sign). Kept the four-regime split for clarity.

**Next agent — Tier C1 remaining (7 of 11):**

1. **`atan2`** — 2-arg variant; quadrant dispatch around `atan(y/x)`.
   File separately because the 2-arg dispatch needs its own LLVM
   ingest path. **VERIFY first whether LLVM ingests as
   `llvm.atan2.f64` intrinsic or as a libm `atan2()` call** — LLVM
   ≤17 doesn't ship `llvm.atan2.*` so it likely arrives as
   `call double @atan2(double, double)`. Different ingest path
   than the unary intrinsic family.

2. **`tanh`** — needs `soft_exp` (already done in `fexp.jl`); use
   `tanh(x) = (e^{2x} - 1) / (e^{2x} + 1)` with the `|x| > 20 → ±1`
   cutoff. ~150 LOC.

3. **`sinh` / `cosh`** — need `soft_exp` plus careful overflow
   handling. Common form-of-`expm1`-trick for sinh near zero —
   possibly defer sinh until expm1 (Tier C2) is available.

4. **`asinh` / `acosh` / `atanh`** — reduce to logs.
   `asinh(x) = log(x + √(x² + 1))`,
   `acosh(x) = log(x + √(x² - 1))`,
   `atanh(x) = 0.5·log((1+x)/(1-x))`.
   Need `soft_log` (done) and `soft_fsqrt` (done). Watch for
   cancellation in `atanh` near 0.

After C1: Tier C2 starts with `expm1` (precision-critical, can't be
faked via `exp(x) - 1`) and `log1p` (same). Both have well-known musl
ports.

---

## Session log — 2026-05-04 — Bennett-ckvj / Tier C1.3 — `soft_asin` + `llvm.asin` dispatch

**Shipped:** see git log around the ckvj close commit. Third close in
Tier C1 of the Enzyme parity north-star (filed 2026-05-03), follow-on
to Bennett-qpke (`soft_atan`) earlier today.

`soft_asin` is a faithful branchless port of musl `e_asin.c`
(FreeBSD/SunPro 1993, BSD-licensed; identical in glibc and openlibm).
`llvm.asin.f64` dispatches directly to `soft_asin` in
`src/extract/instructions.jl`, mirroring the qpke arm; f32 rejected per
CLAUDE.md §13. `_CALLEES_FP_TRANS` extended 16 → 17.

**Empirical accuracy:** 147 unit tests across 11 testsets all green
(121 primitive + 26 dispatch). 100k random samples × 3 seeds across all
four in-domain regimes (tiny / small-poly / mid / near-1) ⇒ max ULP ≤
2, zero fails. 1075-input subnormal-INPUT binade sweep ⇒ max ULP = 0
(bit-exact, tiny path returns `a` verbatim). LLVM-ingest `.ll`
roundtrip green for 14 representative inputs + 5 specials (±0, ±Inf,
NaN, OOB). 3000-sample OOB sweep across `(1, 2^200]` ⇒ all NaN.

**Why:** Tier C1.3 was the cheapest pickup after C1.2 (`atan`) closed
earlier today. `asin` reduces to a single rational `R(z)` polynomial
plus a `sqrt`-based reduction for the general regime — no Cody-Waite
or Payne-Hanek argument reduction, no shared `_rp_rem_pio2`
infrastructure to navigate. The `R(z)` helper plus its 10 polynomial
coefficients (`pS0..pS5`, `qS1..qS4`) plus `pio2_hi`/`pio2_lo` are
**shared with `soft_acos`** (Bennett-bd7f, Tier C1.4) per CLAUDE.md
§12 — landing them via `ckvj` first lets `bd7f` ship as a thinner
mirror.

**Mode:** direct grind. Mechanical mirror of the qpke / s1zl
dispatcher arm + a self-contained ~190 LOC primitive port — no
architectural design space, no opcode-coverage decisions. 3+1
deviation under the Bennett-munq / Bennett-qpke precedent: dispatcher
arm is a 1-line `cname`-prefix check + width assertion + IRCall emit.
The substantive work (the polynomial port + the SET_LOW_WORD precision
trick) is mechanically transcribed from a vetted reference (musl).

**Algorithm:** musl `asin.c`'s 3-regime range split via |x|'s high
word, with the general regime further split into mid vs near-1:

- `|x| < 2^-26`        → return `a` bit-exact (tiny override)
- `2^-26 ≤ |x| < 0.5`  → `asin(x) = x + x · R(x²)`           (Path B)
- `0.5 ≤ |x| ≤ 0.975`  → `0.5·pio2_hi - (2·s·r - (pio2_lo - 2·c)`
                            `             - (0.5·pio2_hi - 2·f))`  (Path C₂)
                          with `s = √z`, `z = (1-|x|)/2`,
                          `f = high32(s)`, `c = (z - f²)/(s + f)`
- `0.975 < |x| < 1`    → `pio2_hi - (2·(s + s·r) - pio2_lo)`  (Path C₁)

Specials:
- `|x| = 1`     → `±π/2` bit-exact
- `|x| > 1`     → QNAN (matches musl `0/(x-x)`)
- `x` is NaN    → `a | QUIET_BIT` (preserve payload, force quiet)

**Gotchas / Lessons:**

1. **`Base.asin(x)` THROWS `DomainError` for `|x| > 1`** — does NOT
   return NaN. The random-sweep test had to be split: in-domain
   samples assert `ulp_diff(soft_asin(x), Base.asin(x)) ≤ 2`; OOB
   samples are asserted as `isnan(soft_asin(x))` only, with NO
   `Base.asin` call (it would throw). qpke's `Base.atan` is total over
   ℝ, so qpke's random sweep didn't hit this. Apply the same split to
   `soft_acos` (also throws OOB) and to `soft_sqrt` of negative if/when
   we ever audit it. Caught by the random-sweep on first run; cost was
   one fix iteration. Future: every test for a `Base.f` that throws on
   OOB should isolate the OOB samples.

2. **Path C₂'s `c = (z - f²) / (s + f)` divides 0/0 at `|x| = 1`
   exactly** — but the override ordering rescues it. At `|x| = 1`,
   `is_near1 = true` (since `0x3ff00000 ≥ 0x3fef3333`), so the path-C
   selector picks `result_near1`, not `result_mid`. Even so, the
   branchless cascade still computes `result_mid = NaN` unconditionally.
   The eq1 override (last-but-one before NaN) replaces the combined
   result with `±π/2`, masking the unused NaN. Belt-and-suspenders:
   the override exists, but the natural Path C₁ flow already produces
   the right value (`pio2_hi - (2·(0+0) - pio2_lo) ≈ π/2`). Lesson:
   in branchless cascades, an unused dead path's NaN is harmless as
   long as the live path produces the right value AND override
   ordering doesn't propagate the dead path's NaN. Verify by tracing
   each special-case input through the cascade by hand before
   committing.

3. **R(z) helper module-private and SHARED across files.** The
   musl-style rational `R(z) = (asin(x) - x)/x³` polynomial uses 10
   coefficients (pS0..pS5, qS1..qS4) plus `pio2_hi`/`pio2_lo`. Both
   `asin.c` AND `acos.c` use the same `R`. CLAUDE.md §12
   (no-duplicated-lowering) extends naturally to softfloat helpers:
   define `_asin_R(z)` once in `fasin.jl` (loaded first), reference it
   by name from `facos.jl` (loaded after). Both files live inside
   `module SoftFloatLib`, so the helper is in scope without an `import`
   or `using`. Constants too: `_ASIN_PIO2_HI`, `_ASIN_PIO2_LO`,
   `_ASIN_HI32_MASK` are defined once in `fasin.jl` and reused.
   **Pattern: when porting a family of related libm functions, look
   for shared helpers in the C source FIRST — the pattern propagates
   to Julia naturally if both files share a module.**

4. **Single R-call per invocation via ifelse-selected input.**
   Branchless realisation tempting: call `_asin_R(x²)` and
   `_asin_R(z)` eagerly, ifelse the results. THIS RECREATES THE QPKE
   GOTCHA #1 (SLP-vectorisation of parallel `soft_fdiv` calls). Fix:
   compute `r_arg = ifelse(is_lt_half, xx, z)` and call
   `_asin_R(r_arg)` ONCE. Same correctness, no parallel-fdiv shape
   for SLP to find. Pattern matched against qpke. **Future
   transcendentals: parallel calls to `soft_fdiv` / `soft_fmul` /
   `soft_fma` over identical operand shape with no data dependency are
   the SLP-vectorisation hazard. Always pre-select operands via
   ifelse, then make ONE call.**

5. **Bit-exact `±π/2` and tiny path mean `asin(±0) = ±0` and
   `asin(±1) = ±π/2` are 0-ULP, not 2-ULP.** The tiny override returns
   `a` bit-exact (preserves sign bit), and the eq1 override returns
   precomputed `_ASIN_PIO2_HI` (with sign XOR for `-1`). The `exact
   identities` testset asserts `==` (bit-exact), not `ulp_diff ≤ 2`.
   Same as the qpke `atan(0) = 0`, `atan(±Inf) = ±π/2` pattern.
   **Lesson: where the natural override produces a constant, assert
   bit-exact; where the polynomial fires, assert ≤2 ULP.**

**Rejected alternatives:**

- **CORE-MATH 1-ULP correctly-rounded asin**: ~400 LOC vs musl's
  ~80 LOC, marginal accuracy gain (1-ULP guaranteed vs Bennett's
  empirical max-1-ULP on f64 ≤2-ULP contract). Same trade-off as for
  s1zl/qpke. Not pursued.
- **Eager parallel `_asin_R(x²)` + `_asin_R(z)`** (initial branchless
  draft): clean Julia code but recreates qpke gotcha #1 SLP-
  vectorisation. Collapsed to one R-call on ifelse-selected input.
- **Inline R(z) coefficients into `soft_asin` body** (avoid the
  helper): would require duplicating into `soft_acos` later, violating
  CLAUDE.md §12. Helper-with-shared-constants is the right shape for
  the trig-completion family.
- **Arm Optimized Routines `asin`**: ARM doesn't ship a double-
  precision arcsine in `arm-optimized-routines/math` (only sqrt / exp
  / log / pow / sin / cos). Same gap that bit `Bennett-1pb` (sqrt)
  and `Bennett-s1zl` (tan).

**Next agent — Tier C1 remaining (9 of 11):**

1. **`acos`** (Bennett-bd7f, P2, ALREADY FILED). Cheapest next pickup.
   Reuses `_asin_R` and the 10 R-coefficients verbatim from `fasin.jl`
   (per §12). Four sign-and-magnitude regimes from musl `acos.c`:
   tiny (|x|<2^-57 → π/2), small (|x|<0.5 → polynomial), neg-large
   (x ≤ -0.5 → 2·(π/2 - (s+w))), pos-large (x ≥ 0.5 → 2·(df+w) with
   SET_LOW_WORD trick). Specials: x=1 → 0, x=-1 → π. f32 rejected.
   Mechanical mirror of `ckvj` + `qpke`; no design space.

2. **`atan2`** — 2-arg variant; quadrant dispatch around `atan(y/x)`.
   File separately because the 2-arg dispatch needs its own LLVM
   ingest path. **VERIFY first whether LLVM ingests as
   `llvm.atan2.f64` intrinsic or as a libm `atan2()` call** — LLVM
   ≤17 doesn't ship `llvm.atan2.*` so it likely arrives as
   `call double @atan2(double, double)`. Different ingest path than
   the unary intrinsic family.

3. **`tanh`** — needs `soft_exp` (already done in `fexp.jl`); use
   `tanh(x) = (e^{2x} - 1) / (e^{2x} + 1)` with the `|x| > 20 → ±1`
   cutoff. ~150 LOC.

4. **`sinh` / `cosh`** — need `soft_exp` plus careful overflow
   handling. Common form-of-`expm1`-trick for sinh near zero —
   possibly defer sinh until expm1 (Tier C2) is available.

5. **`asinh` / `acosh` / `atanh`** — reduce to logs.
   `asinh(x) = log(x + √(x² + 1))`,
   `acosh(x) = log(x + √(x² - 1))`,
   `atanh(x) = 0.5·log((1+x)/(1-x))`.
   Need `soft_log` (done) and `soft_fsqrt` (done). Watch for
   cancellation in `atanh` near 0.

After C1: Tier C2 starts with `expm1` (precision-critical, can't be
faked via `exp(x) - 1`) and `log1p` (same). Both have well-known musl
ports.
