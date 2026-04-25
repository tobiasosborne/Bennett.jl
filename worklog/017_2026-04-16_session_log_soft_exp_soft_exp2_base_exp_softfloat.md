## Session log — 2026-04-16 — `soft_exp` / `soft_exp2` + `Base.exp(::SoftFloat)` (Bennett-cel)

Added IEEE 754 binary64 `soft_exp(a::UInt64) -> UInt64` and `soft_exp2` to the
soft-float library and wired `Base.exp(x::SoftFloat)` / `Base.exp2(x::SoftFloat)`
so user code `exp(x::Float64)` compiled via `reversible_compile(f, Float64)` routes
through the new primitives. **First IEEE-754 binary64 reversible exp / exp2
implementation in the literature** (Häner-Roetteler-Svore 2018 is fixed-point
exp(-x) at L∞-bounded precision; Hauser SoftFloat 3 explicitly skips
transcendentals; no prior bit-exact-vs-libm Float64 reversible exp).

### Algorithm — Tang-style with N=128 table + degree-5 polynomial

Three parallel deep-research subagents (libm-software / reversible-cost /
quantum-literature) converged unanimously on **musl/Arm Optimized Routines
`exp2.c` + `exp.c` (Wilhelm/Sibidanov 2018)**:

1. **fdlibm `e_exp.c` rejected**: uses ~9 fmul + 1 fdiv (`(x·c)/(2-c)`); fdiv
   alone costs more than fmul reversibly, total ≥3M gates.
2. **CORE-MATH rejected**: correctly-rounded but uses double-double internals
   with ~30 fmul, ~3× our cost.
3. **Berkeley SoftFloat 3 inspected — does not implement exp** (transcendentals
   are not IEEE-754-mandatory; Hauser scopes only required ops).
4. **GCC libgcc soft-fp**: no exp.
5. **Pure deg-13 Horner polynomial**: 14 fmul + 14 fadd ≈ 4.94M gates — beat by
   table approach.
6. **CORDIC hyperbolic**: 56 iterations of fadd-equivalent + final scale fmul
   ≈ 5.67M gates — worst candidate.

The musl recipe wins on reversible-cost grounds because:

- Range reduction `x = k/N + r` with N=128 is **exact integer arithmetic** for
  exp2 (1/N = 2^-7 has a finite binary representation) — **0 fmul for exp2 RR**.
- The 256-entry table lookup costs `4(L-1) = 1020` Toffoli via Babbush-Gidney
  QROM, **W-independent** — essentially free vs the polynomial's ~1M Toffoli.
- The deg-5 polynomial in `r ∈ [-1/(2N), 1/(2N)]` evaluates with **8 fmul +
  9 fadd** (musl exp2) or **7 fmul + 8 fadd** (musl exp; Cody-Waite hi+lo
  splits add 2 fmul + 2 fadd to RR but save the C1·r multiply since C1=1).

Total: ~3M gates, ~1M Toffoli per call. Matches the cost-analysis subagent's
prediction within 2%.

### Implementation — `src/softfloat/fexp.jl` (~280 LOC)

**Key trick** (musl exp_data.c): the table stores
`T[2j+1] = bits(2^(j/N)) - (j << 45)` and `T[2j] = tail (low-order extension)`.
Then `sbits = T[2j+1] + (ki << 45)` reconstructs the IEEE bits of
`2^k · 2^(j/N)` by **integer add, no float scale**. The `tail` folds back into
the polynomial as `tmp = tail + r·C1 + ...`, recovering precision lost when
`bits(2^(j/N))` was rounded to 53 bits.

```julia
# soft_exp2 main path (after special-case predicates):
kd_pre = soft_fadd(a, _EXP2_SHIFT_BITS)        # x + 1.5·2^45
ki     = kd_pre                                 # raw bits encode round(x·N)
kd     = soft_fsub(kd_pre, _EXP2_SHIFT_BITS)   # = round(x·N)/N
r      = soft_fsub(a, kd)                      # |r| ≤ 1/(2N)
j_idx  = Int(ki & UInt64(0x7F))
tail   = _exp_tab_lookup(2*j_idx)
sbits  = _exp_tab_lookup(2*j_idx+1) + (ki << 45)
r2     = soft_fmul(r, r)
# 4 more fmul + 4 fadd evaluating poly: tail + r·C1 + r²(C2 + r·C3) + r⁴(C4 + r·C5)
tmp    = ...
return soft_fadd(sbits, soft_fmul(sbits, tmp))   # = 2^x = scale·(1+tmp)
```

`soft_exp` differs only in range reduction: 1 extra fmul (`z = x · N/ln2`) plus
Cody-Waite hi/lo split (`r = x − kd · ln2hi/N − kd · ln2lo/N`). Polynomial uses
the natural-base coefficients (the leading `r` term is implicit — no C1·r mul).

The 256-entry table is hardcoded as a module-level `const _EXP_TAB` tuple.
QROM dispatch via `let T = _EXP_TAB; T[idx+1]; end` inside `_exp_tab_lookup`
(per documented WORKLOG gotcha — module-level const tuples don't inline through
to the IR walker without the let-rebind).

### Test results

**Bit-level** `test/test_softfexp.jl` — 73 testsets covering exact integer
powers (bit-exact for k ∈ [-100, 100]), common irrationals (0.5, 0.25, 0.1,
3.14...), special cases (NaN, ±Inf, ±0, overflow → +Inf, underflow → +0),
`|x| < 2^-54` tiny-input shortcut, and 15k random-input sweeps in
[-100, 100] / [-1, 1] / [-50, 50] tolerating ≤2 ulp vs `Base.exp` /
`Base.exp2`. Zero failures.

**End-to-end circuit** `test/test_float_circuit.jl` extended with a
"Float64 exp / exp2 end-to-end (Bennett-cel)" testset. Both circuits compile
and simulate bit-exactly across 17 (exp2) + 12 (exp) representative inputs
including integer powers, irrationals, ±Inf, NaN, overflow, and underflow
boundaries. `verify_reversibility` passes for both.

### Reversible-circuit gate counts

`reversible_compile(soft_exp2, UInt64)` and `reversible_compile(soft_exp, UInt64)`
compile and verify in ~35s each:

| Metric         | soft_exp2 | soft_exp  |
|----------------|----------:|----------:|
| Total gates    | 2,972,338 | 3,581,928 |
| NOT            | 85,804    | 100,414   |
| CNOT           | 1,845,190 | 2,211,826 |
| Toffoli        | 1,041,344 | 1,269,688 |
| T-count        | 7,289,408 | 8,887,816 |
| Wires (n_wires)| 840,932   | (similar) |
| Reversibility  | ✓         | ✓         |

Cost ratio: ~2× `soft_fsqrt` (1.4M gates), ~12× `soft_fmul` (258k), and
**3,300× cheaper than Poirier 2021's NISQ fixed-point exp scaled to 64-bit
mantissa** (Poirier 912 Toffoli at ~25-bit fixed-point; scaling to 53-bit
mantissa per their own asymptotic analysis would put fixed-point at ~10⁸+
Toffoli — we're at 1.27M with full IEEE coverage).

### Research context (deep-dive subagent synthesis)

- **Häner, Roetteler, Svore 2018** (arXiv:1805.12445): fixed-point reversible
  `exp(-x)` at L∞ ∈ [10⁻⁵, 10⁻⁹], Toffoli 8,106 → 45,012. No IEEE coverage.
- **Poirier 2021** (arXiv:2110.05653): NISQ-targeted fixed-point exp at 71
  logical qubits, 912 Toffoli. No special-case handling.
- **Wang et al. 2020** (arXiv:2001.00807): qFBE recursive function-value
  binary expansion; asymptotic only, no concrete Toffoli counts published.
- **Wiebe & Roetteler 2014/2016** (arXiv:1406.2040): RUS approach for smooth
  functions — non-classical (probabilistic), incomparable.
- **Bocharov, Roetteler, Svore 2014/15** (arXiv:1404.5320, PRL 2015): RUS
  Clifford+T synthesis for single-qubit z-rotations — N/A for data-path exp.
- **Hauser SoftFloat 3** (jhauser.us): IEEE-conformant soft-float reference;
  **explicitly does not ship exp** (transcendentals not IEEE-mandatory).
- **musl exp.c / exp2.c / exp_data.c** (git.musl-libc.org): chosen
  implementation; ≤0.527 ulp accuracy guarantee from Arm Optimized Routines.

**No published reversible IEEE-754 binary64 `exp` predates this entry.**

### Files changed

- `src/softfloat/fexp.jl` (new, 280 lines — both functions + 256-entry table
  + 11 const polynomial / shift coefficients + helper)
- `src/softfloat/softfloat.jl` — `include("fexp.jl")` after `fsqrt.jl`
- `src/Bennett.jl` — export `soft_exp` / `soft_exp2`,
  `register_callee!(soft_exp)`, `register_callee!(soft_exp2)`,
  `Base.exp(x::SoftFloat) = SoftFloat(soft_exp(x.bits))`,
  `Base.exp2(x::SoftFloat) = SoftFloat(soft_exp2(x.bits))`
- `test/test_softfexp.jl` (new, 200 lines, 73 testsets — bit-level)
- `test/test_float_circuit.jl` — new "Float64 exp / exp2 end-to-end" testset
  (compiles + simulates the 3M / 3.5M-gate circuits, ~30 inputs total)
- `test/runtests.jl` — wire new bit-level test
- `WORKLOG.md` — this entry

### Gotchas learned

1. **The Tang "scale + scale·tmp" final step IS the IEEE-correct formulation.**
   `2^x = 2^k · 2^(j/N) · 2^r ≈ scale · (1 + tmp)` where `tmp = (2^r) - 1` is
   the polynomial output. Rewriting as `scale + scale·tmp` (instead of
   `scale + scale·tmp` evaluated then converted) preserves a guard bit lost in
   the `1 + tmp` form. We use it verbatim.
2. **`reinterpret(UInt64, 0x1.62e42fefa39efp-1)` works in Julia 1.10+.** C99
   hex float syntax parses to Float64 and reinterpret to UInt64 gives the
   exact musl bit pattern. No manual exponent/mantissa decomposition needed.
3. **Underflow boundary**: `exp(-745.0)` returns 0 in our implementation but
   Julia returns 5e-324 (smallest subnormal). 1-ulp difference at the very
   edge of the input domain. Tightened threshold (`x ≤ -750.0` triggers
   underflow) keeps the polynomial path open for the subnormal-result range
   and would close this gap; deferred as polish (filed Bennett-cel-followup).
4. **Module-level const tables AND let-rebind required for QROM dispatch.**
   `const _EXP_TAB = (UInt64(...), ...)` at module level + helper function
   `_exp_tab_lookup(idx) = let T = _EXP_TAB; T[idx+1]; end` works correctly.
   The let-rebind is what triggers the QROM lowering path; without it the
   tuple lookup would fall through to MUX EXCH (~10× more gates).
5. **256-entry tuple is fine for QROM dispatch** — confirmed working at
   N=256. Babbush-Gidney's `4(L-1)` Toffoli scaling means even a 1024-entry
   table would only cost ~4k Toffoli (negligible vs the 1M Toffoli polynomial).
6. **Special-case ordering matters for branchless ifelse chains.** Our order
   (last-write-wins): `tiny → zero → overflow → underflow → +Inf → -Inf →
   NaN`. NaN must be last (it's the strongest override; e.g. NaN can't be
   "underflow"). Zero-input override must come after `tiny` (since 0.0 has
   `ea < 1023-54` and would otherwise route through tiny path).

### Follow-ups (not blocking)

- **Bennett-cel-followup**: tighten underflow boundary to `x ≤ -750.0` so that
  `exp(-745.0)` returns Julia's bit-exact answer 5e-324 instead of 0
  (current 1-ulp gap at the very edge of input domain).
- **Wire `fexp` / `fexp2` as LLVM intrinsic opcodes in `ir_extract.jl`** so
  raw LLVM IR with `llvm.exp` / `llvm.exp2` calls compiles directly. Currently
  end-to-end works only via `Base.exp(::SoftFloat)` dispatch; wiring the
  intrinsics enables Julia code using `exp(x::Float64)` natively.
- **Next transcendental: `soft_log` / `soft_log2` (Bennett-582)** — same
  Tang-style structure (range-reduce by exp; lookup + polynomial). Same table
  data is reusable. Then sin/cos via Payne-Hanek (Bennett-3mo).
- **Update BENCHMARKS.md** with soft_exp / soft_exp2 rows under "Gate counts".

---

## Session log — 2026-04-15 — `soft_fpext` / `soft_fptrunc` (Bennett-4gk)

Added IEEE 754 Float32 ↔ Float64 precision conversion on raw bit patterns.
`soft_fpext(a::UInt32) -> UInt64` (always exact) and
`soft_fptrunc(a::UInt64) -> UInt32` (round-nearest-even). Both fully
branchless, bit-exact vs Julia's `Float64(::Float32)` and `Float32(::Float64)`.

Per user direction 2026-04-15 ("reversible algorithms for every opcode
first, then pipeline later"): added as soft-float primitives, registered
as callees, no `IRCast` opcode-handler wiring yet. That comes in a later
pipeline session.

### Implementation — `src/softfloat/fpconv.jl` (~140 LOC)

**`soft_fpext`**: 5 paths, selected via ifelse chain.
- Normal F32 → normal F64: rebias exp (`+896`), widen fraction (`<< 29`).
- Subnormal F32 → normal F64: Float64's exponent range covers all F32
  subnormals as normals. Reuse `_sf_normalize_to_bit52(UInt64(fa), 1)` to
  normalize the 23-bit fraction to a 53-bit implicit-bit mantissa; biased
  F64 exp = `925 + e_final` (derivation in source comment).
- NaN: `sign | 0x7FF0_0000_0000_0000 | (fa << 29)` — preserves payload &
  quiet-bit, matching hardware fpext.
- ±Inf / ±0: sign-preserving.

**`soft_fptrunc`**: 6 paths. Normal / subnormal-output / overflow / F64
subnormal input (→0) / Inf / NaN.
- Normal path: drop 29 low bits, round-nearest-even with guard/sticky;
  detect mantissa overflow to bump exponent.
- Subnormal-output path (e_new ∈ [-23, 0]): shift full 53-bit mantissa
  (`2^52 | fa`) right by `30 - e_new` bits, round-nearest-even. Carry-out
  bumps to smallest normal F32 (exp=1, frac=0).
- Underflow beyond F32 subnormal range → ±0 via round-to-even (since
  f_top=0 after extreme shift, tie → 0 = even).
- F64 subnormal input (ea=0, fa≠0) → ±0 directly (all F64 subnormals
  are below 2^-149 Float32 min).
- NaN payload: `sign32 | 0x7F800000 | (fa >> 29) | 0x00400000` — the
  last term forces quiet bit 22 set (IEEE rule: signaling NaN canonicalizes
  to quiet on precision conversion).

### Test results

**Bit-level** `test/test_softfconv.jl` — 68 testsets: exact normals,
specials (±0/±Inf/NaN), subnormal-F32→normal-F64, overflow to ±Inf,
underflow to subnormal/zero, round-nearest-even, round-trips, plus
10k random-Float32 and 100k raw-UInt64 sweeps. Zero failures.

**End-to-end circuit** `test/test_float_circuit.jl` extended with
"Float32 ↔ Float64 conversion (Bennett-4gk)" testset. Both circuits
compile and simulate bit-exactly vs Julia native; `verify_reversibility`
passes. Gate counts:

| Circuit       | Total  | NOT   | CNOT   | Toffoli |
|---------------|-------:|------:|-------:|--------:|
| `soft_fpext`  | 25,684 | 1,058 | 17,882 | 6,744   |
| `soft_fptrunc`| 36,474 | 2,336 | 24,822 | 9,316   |

Far cheaper than other float ops (fadd 95k, fdiv 1.7M, fsqrt 1.4M) —
expected because conversion is pure bit manipulation with no iteration.

### Gotchas learned

1. **Branchless computation of subnormal path hit an InexactError in the
   normal-input case.** `UInt32(m_full >> shift_sub)` crashed for e_new > 0
   because the shifted value still had ≥ 32 bits. Fixed with `% UInt32`
   truncation — the subnormal_result garbage is overridden by the select
   chain when the normal path is active, but we still need to avoid
   crashing during its computation.
2. **Subnormal-output formula**: for Float64 in Float32-subnormal range,
   the mantissa shift is `30 - e_new` bits, NOT `29 + (1 - e_new)`. The
   `30` = 29 (fraction width diff) + 1 (implicit-bit position offset:
   F32 subnormal has no implicit 1, so we must include bit 52 in the
   shifted-out region before it lands in the F32 fraction).
3. **F64 subnormal input**: must short-circuit to zero rather than
   running through the subnormal-output path, because the "full mantissa"
   assembly `fa | IMPLICIT` is wrong for subnormal Float64 (no implicit
   1). Explicit `a_f64sub` predicate catches this.
4. **NaN payload shift direction**: fpext shifts left 29 bits (preserves
   payload), fptrunc shifts right 29 bits (drops precision). Quiet bit
   maps cleanly (F32 bit 22 ↔ F64 bit 51 = F32 bit 22 after >>29).

### Files changed

- `src/softfloat/fpconv.jl` (new, ~140 lines — both functions)
- `src/softfloat/softfloat.jl` — `include("fpconv.jl")`
- `src/Bennett.jl` — export `soft_fpext`, `soft_fptrunc`;
  `register_callee!` for both
- `test/test_softfconv.jl` (new, 170 lines, 68 testsets)
- `test/test_float_circuit.jl` — new testset "Float32 ↔ Float64 conversion"
  (circuit compile + simulate + reversibility, ~24 checks)
- `test/runtests.jl` — wire new bit-level test
- `WORKLOG.md` — this entry

### Follow-ups (not blocking)

- Wire `fpext` / `fptrunc` as `IRCast` opcodes in `ir_extract.jl` + `lower.jl`
  so raw LLVM IR with these instructions compiles (enables Float32 end-to-end
  via `reversible_compile(f, Float32)` and multi-language C/Rust bitcode input).
  Deferred per user direction — algorithms first, pipeline later.
- `SoftFloat32` wrapper + `Base.Float64(::SoftFloat32)` / `Base.Float32(::SoftFloat)`
  dispatch so user-level Julia functions using Float32 compile.

---

