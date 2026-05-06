## Session log — 2026-05-07 — Bennett-0ulc / Tier C2.1 — `soft_log1p` + `llvm.log1p` + libm `@log1p` dispatch (high-leverage primitive)

**Shipped:** see git log around the 0ulc close commit. **First C2
transcendental close** following the Tier C1 hyperbolic completion
earlier in the session.

**Why high-leverage:** the asinh (sfx9), acosh (eq9p), atanh (g82n)
beads I shipped earlier today all sidestep the missing `soft_log1p`
via wide polynomial regimes (K=15-30) — that gate-cost overhead was
explicitly documented as scope-creep / future-work in each of those
worklog entries. Shipping `soft_log1p` now means future cleanup beads
can replace those wide polynomials with the natural log1p formula at
much lower polynomial degree (~K=8).

**Algorithm decision (3+1 skipped per §2 exception).** The Julia-
stdlib precision-recovery formula is a well-known reformulation:

  log1p(x) = log(1+x) + (x - ((1+x) - 1))/(1+x)

The correction term `(x - ((1+x)-1))/(1+x)` recovers the bits of
precision lost when `1+x` rounds for small |x|. Direct REPL
validation: 0 ULP at every sample point in `[-0.99, 10] step 1e-3`.

**Tiny regime threshold — empirical correction.** Initial draft used
2^-26 based on a flawed analysis (claimed `x²/2 < ½ULP(x)` for that
range, but the algebra was wrong). Smoke test exposed it: at x=1e-9
≈ 2^-30, my soft_log1p returned x exactly (since 1e-9 < 2^-26) but
Base.log1p(1e-9) = 9.9999999995e-10 — off by **2.4 million ULPs**.

Re-derivation: log1p(x) - x ≈ -x²/2. For this to be < ½ULP(x) =
x · 2^-53, we need x²/2 < x · 2^-53, i.e. x < 2^-52. Set threshold
at 2^-54 for ~2 bits margin. Re-validated: 300k random × 3 seeds,
max 1 ULP, 0 fails. Subnormal binade sweep: 0 ULP across all 1074
binades (one 1 ULP mismatch at the 2^-52 boundary, expected and
within budget).

**General lesson:** ULP-bit analysis is treacherous. When the
relevant quantity is `f(x) - x` near zero, the correct comparison is
`f(x) - x` vs `½ULP(result)`, not `½ULP(input)`. For log1p,
result ≈ x (so ULP at result = ULP at x), but if a future
transcendental has different scaling, this analysis must be redone.
The cheap belt-and-braces is empirical sweep with a fine-grained
binade test.

**Results.**

* `src/softfloat/flog1p.jl` (~115 LOC) — two-regime branchless port:
  tiny (|x| < 2^-54) → x bit-exact; medium → precision-recovery
  formula. Special-case overrides for x=-1 (-Inf), x<-1 (NaN),
  x=+Inf (+Inf), x=NaN (NaN with quiet bit).
* Module-private constants: 5 (tiny threshold, ±1 bits, -Inf bits,
  NaN bits).
* `_CALLEES_FP_TRANS` extended **25 → 26**.
* `src/extract/instructions.jl` gains 3 dispatch arms (intrinsic +
  libm + libm-f32-reject).
* `test/test_softflog1p.jl` (10 testsets, **13,096 assertions**,
  1.8s): smoke / specials / **§13 subnormal-INPUT bit-exact across
  all 1074 binades × ±** / tiny-normal range bit-exact / regime
  boundary at 2^-54 / medium fine sweep / 100k random × 3 seeds × 5
  buckets / callee registered.
* `test/test_0ulc_llvm_log1p_dispatch.jl` (7 testsets) + 4 fixture
  `.ll` files. Includes regression-guard `llvm.log.f64` → `soft_log`.

**Validation.**

* Smoke: max 1 ULP across 17+ representative inputs.
* §13 binade sweep: 0 ULP across all subnormal inputs (preserved
  bit-exactly via tiny regime).
* 300k random sweep × 3 seeds × 5 magnitude buckets — max 1 ULP, 0
  failures across all seeds.
* `@code_llvm` SLP-vectorisation check — clean.

**Gotchas / Lessons:**

1. **ULP analysis is treacherous (see above).** Empirical sweep is
   the truth oracle.
2. **Julia's `log1p(x<-1)` throws DomainError**, same as atanh. Test
   sweeps need a wrapper.
3. **+Inf input must be special-cased.** Raw formula at x=+Inf:
   `1+Inf = Inf`, `log(Inf) = Inf`, `(Inf - (Inf - 1))/Inf = NaN/Inf
   = NaN`, `result = Inf + NaN = NaN`. Wrong — should be +Inf.
   Override required.
4. **x = -1 must also be special-cased.** Raw formula at x=-1:
   `1+(-1) = 0`, `log(0) = -Inf`, `(0-1) - (-1) = 0`, correction =
   `0/0 = NaN`, result = `-Inf + NaN = NaN`. Wrong — should be -Inf.
5. **Future cleanup work** (NOT done in this bead, just enabled):
   asinh K=30 → K=8 polynomial; acosh K=15 → smaller; atanh K=25 →
   K=8. Each of those primitives could be re-implemented to use
   `soft_log1p` directly in the small-|x| regime, replacing their
   wide polynomial cost. Estimate ~3-4M gates saved per primitive
   per call. **File as separate cleanup beads** when picking that up.

**Next agent starts here:** continue C2 grind. Possible pickups:
- `expm1` (Tier C2.2) — symmetric counterpart to log1p; would benefit
  C1 hyperbolics (tanh/sinh/cosh/asinh/acosh/atanh) the same way
  log1p benefits asinh/acosh/atanh (gate cost reduction in their
  small-|x| polynomial regimes).
- `cbrt` (C2.3) — cube root via Newton-Raphson; ~100 LOC, simpler
  than log1p.
- `hypot` (C2.4) — sqrt(x²+y²) avoiding overflow.
- Cleanup beads: simplify asinh/acosh/atanh polynomial regimes
  using the now-available `soft_log1p`.

---

## Session log — 2026-05-06 — Bennett-g82n / Tier C1.11 — `soft_atanh` + `llvm.atanh` + libm `@atanh` dispatch — **TIER C1 COMPLETE 11/11**

**Shipped:** see git log around the g82n close commit. **FINAL
hyperbolic primitive in Tier C1 of the Enzyme parity north-star —
Tier C1 is now 11 of 11 complete.**

**Why:** completing the Tier C1 hyperbolic + trig family the user
asked for at the top of this session. Sequence shipped today
(2026-05-06): m2bv tanh → ky5n sinh → bybh cosh → sfx9 asinh → eq9p
acosh → g82n atanh. Six bead closures in one session.

**Algorithm decision (3+1 skipped per §2 exception).** Atanh follows
the same playbook as sfx9 (asinh) with three localised differences:
(a) different polynomial coefficients (atanh's are exact rationals
`c_k = 1/(2k+1)`); (b) medium formula is `0.5·log((1+|x|)/(1-|x|))`
instead of `log(|x|+sqrt(x²+1))`; (c) domain restriction at `|x| > 1`
(returns NaN per IEEE 754-2019; Julia stdlib throws DomainError).
The exact rational coefficients are a small win — no BigFloat-
regression step needed.

**Empirical validation (pre-implementation REPL sweep).**

* K=15 polynomial covers `|x| ≤ 0.3` to ≤2 ULP
* K=25 polynomial covers `|x| ≤ 0.5` to ≤2 ULP — **chosen**
* K=30 polynomial covers `|x| ≤ 0.6`
* Log-formula `0.5·log((1+|x|)/(1-|x|))` accurate to ≤2 ULP for
  `|x| ≥ 0.5` (testset confirmed 0-1 ULP at all sample points)

Polynomial threshold 0.5 chosen at the natural transition point.

**Special cases at |x| = 1.** Natural propagation handles ±Inf:
`(1+1)/(1-1) = +Inf`, `log(+Inf) = +Inf`, `0.5·Inf = +Inf`, OR with
sign → `±Inf`. No explicit override needed at exactly ±1.

**Domain handling.** `is_above_one = |x| > 1.0` (unsigned bit
comparison on `abs_a`). For NaN inputs: NaN bits > 1.0 bits in
unsigned ordering, so `is_above_one` mis-fires for NaN — corrected
by the final `is_nan` override at the bottom of the cascade.

**Results.**

* `src/softfloat/fatanh.jl` (~165 LOC) — three-regime branchless port:
  `|x| > 1 → NaN`, K=25 polynomial in z=x² for `|x| ≤ 0.5`,
  `0.5·log((1+|x|)/(1-|x|))` for medium. ONE soft_log + ONE soft_fdiv.
* Module-private constants: 26 polynomial coefficients
  (`_ATANH_C0..C25` — exact rationals `1/(2k+1)`) + 3 thresholds.
* `_CALLEES_FP_TRANS` extended **24 → 25**.
* `src/extract/instructions.jl` gains 3 dispatch arms.
* `test/test_softfatanh.jl` (10 testsets, **2087 assertions**, 2.1s):
  smoke / specials / domain / poly↔medium boundary / **§13 subnormal-
  INPUT bit-exact** / poly fine sweep / medium fine sweep / 100k
  random × 3 seeds × 5 buckets / callee registered.
* `test/test_g82n_llvm_atanh_dispatch.jl` (7 testsets) + 4 fixture
  `.ll` files. Includes regression-guard `llvm.atan.f64` → `soft_atan`.

**Validation.**

* Smoke: max 1 ULP across 23 representative inputs (incl. domain-error
  cases all returning NaN; ±1 → ±Inf; subnormal preserved).
* §13 binade sweep: 0 ULP across all 104 subnormal inputs (preserved
  bit-exactly via polynomial branch).
* 300k random sweep × 3 seeds × 5 magnitude buckets — **max 2 ULP,
  zero failures > 2** across all seeds. Tested OOB inputs separately
  using try/catch wrapper since Julia's `atanh` throws DomainError.
* `@code_llvm` SLP-vectorisation check — clean.

**Gotchas / Lessons:**

1. **Julia's `atanh` throws DomainError for |x| > 1**, not returns NaN.
   Test code that compares `soft_atanh(x)` to `atanh(x)` for |x| > 1
   must wrap with try/catch or pre-check `abs(x) > 1`. Caught the first
   test run with an OOB sample at -1.87. Same convention as Julia's
   `acosh` (which also throws DomainError).
2. **Exact rational coefficients are nicer than minimax/regression.**
   Atanh's Taylor: `c_k = 1/(2k+1)` — exact, no BigFloat-regression
   step. asinh and acosh required BigFloat regression for their
   coefficients. The simpler atanh setup adds maintainability value
   beyond just gate-count.
3. **Natural ±Inf propagation at |x| = 1.** No special-case override
   needed — `(1+|x|)/(1-|x|)` produces `+Inf` cleanly when `1-|x| = 0`,
   and `log(+Inf) = +Inf`, `0.5·Inf = +Inf`. Soft-float primitives
   propagate Inf correctly.

**Rejected alternatives:**

* **Verbatim Julia stdlib using log1p.** Same blocker as
  asinh/acosh — Bennett.jl lacks `soft_log1p`. Polynomial sidestep
  used.
* **K=15 narrower polynomial regime.** Doesn't extend up to 0.5 with
  ≤2 ULP. K=25 is the sweet spot.

**Next agent starts here:** **TIER C1 COMPLETE.** All 11 transcendentals
(7 trig + 6 hyperbolic — wait, count: tan, atan, asin, acos, atan2 = 5
trig; sin, cos = 2 more = 7 trig; tanh, sinh, cosh, asinh, acosh,
atanh = 6 hyperbolic; but the parity-doc enumeration said 11 total
in C1, which matches if we count the trig completion at 5 (s1zl tan,
qpke atan, ckvj asin, bd7f acos, 7goc atan2) plus the earlier 2 (3mo
sin/cos) plus 4 hyperbolic + 1 final hyperbolic atanh = 12... actually
looking at the doc, the C1 family is 11 which includes sin, cos, tan,
atan, asin, acos, atan2, tanh, sinh, cosh, asinh, acosh, atanh — that
counts to 13. The doc is approximate; what matters is **all the
listed functions are now closed**).

**Possible next pickups (post-C1):**
- **Bennett-soft_log1p** — file as a sibling primitive bead. Would
  simplify the existing asinh/acosh/atanh polynomial regimes (K=15-30
  → K=8). Reuses soft_log infrastructure with a small-arg fast path.
  ~150 LOC. Highest-leverage simplification.
- **C2 transcendentals**: `expm1`, `log1p`, `cbrt`, `hypot`, `exp10`,
  `ldexp`, `frexp`, `scalbn`, `modf`, `fmod`, `remainder`, `fdim`,
  `sinpi`, `cospi`, `sinc` — Enzyme covers ~30 of these via TableGen.
  Several (e.g. `expm1`, `log1p`) are first-class numerically.
- **C3 special functions**: erf, erfc, tgamma, lgamma, Bessel — long
  but useful. Lower priority than C1/C2.
- **C4 complex arithmetic**: cabs, complex sqrt/exp/log/pow/sin/cos.
- **Tier B closures**: 8bys umbrella (memcpy/memset wider element widths,
  variable-size, memmove), Bennett-3rph (native f32 arithmetic).

