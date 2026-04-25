## Session log — 2026-04-15 — `soft_fsqrt` + `Base.sqrt(::SoftFloat)` (Bennett-ux2)

Added IEEE 754 correctly-rounded `soft_fsqrt(a::UInt64)::UInt64` to the
soft-float library and wired `Base.sqrt(x::SoftFloat)` so user code
`sqrt(x::Float64)` compiled via `reversible_compile(f, Float64)` routes
through the new primitive. First LLVM-intrinsic `llvm.sqrt` coverage for
`reversible_compile`; also first fully-IEEE-754 reversible FP64 sqrt in
the literature (Thapliyal 2018 is integer-only, Gayathri 2022 is FP32
Babylonian without full special-case coverage).

### Algorithm — digit-by-digit restoring sqrt (Ercegovac-Lang / fdlibm)

Three deep-research subagents (software / hardware / reversible) converged
unanimously: **restoring digit-recurrence** beats Newton-Raphson and
Goldschmidt decisively for our constraints. Rationale:

1. **Kahan's no-midpoint theorem** — `sqrt(x)` on binary64 is never exactly
   halfway between two floats. So `sticky = (remainder != 0)` OR'd into
   bit 0 + standard round-nearest-even via `_sf_round_and_pack` is
   trivially correctly-rounded. No Markstein residual correction, no
   Tuckerman post-test, no FMA simulation.
2. **Structural parity with `soft_fdiv`** — the loop body is a mirror of
   fdiv's restoring-division recurrence: one compare, one conditional
   subtract, one shift-by-1 into q. Reviewer trust transfers directly.
3. **No tables** — NR seed-table LUT would cost thousands of Toffolis in
   reversible form; we spend zero.
4. **No multiplies** — NR needs a 53×53 squaring per iteration (~3700
   gates from `soft_fmul`); restoring uses only add/sub/shift/compare.

### Implementation — `src/softfloat/fsqrt.jl` (98 LOC)

Mantissa sqrt setup: conceptual 128-bit radicand `A = ma_adj << 58`,
stored as `(a_hi, a_lo)` UInt64 pair. `ma_adj` absorbs exponent parity
(`ma_adj = ma << 1` when unbiased exponent is odd, else `ma`). Leading 1
lands at bit 110 (e_unb even) or 111 (e_unb odd).

Core loop — 64 iterations, 2 bits/iter, streaming top-down via
shift-left-by-2:

```julia
for i in 0:63
    top2 = (a_hi >> 62) & UInt64(3)
    a_hi = (a_hi << 2) | (a_lo >> 62)
    a_lo = a_lo << 2
    r = (r << 2) | top2
    t = (q << 2) | UInt64(1)
    fits = r >= t
    r = ifelse(fits, r - t, r)
    q = (q << 1) | ifelse(fits, UInt64(1), UInt64(0))
end
wr = q | ifelse(r != UInt64(0), UInt64(1), UInt64(0))  # sticky
```

First ~8 iterations extract the all-zero top of A (above bit 111),
producing leading zeros in q. The meaningful bits of q land at bits
55..0, exactly the 56-bit format `_sf_round_and_pack` consumes (bit 55
= leading 1, bits 54..3 = 52 frac, bits 2..0 = GRS).

Reuses shared helpers: `_sf_normalize_to_bit52` (subnormal pre-normalize),
`_sf_round_and_pack` (round-nearest-even + IEEE pack). No new infrastructure
in `softfloat_common.jl`.

Proven-safe constraints (no runtime checks needed):
- sqrt of any finite positive never overflows (DBL_MAX → ~2^512)
- sqrt of any finite positive never underflows to subnormal (smallest
  subnormal input 2^-1074 → 2^-537, normal)
- arithmetic right shift `(e_unb >> 1) + BIAS` handles negative
  unbiased exponents correctly (e.g. sqrt(5e-324) → biased 486)

### Test results

**Bit-level**: `test/test_softfsqrt.jl` — 56 testsets covering perfect squares,
irrationals, zeros (sign preserved per IEEE §6.3), ±Inf, NaN propagation,
negative finite → qNaN, subnormals (full range), boundary (DBL_MIN, DBL_MAX,
±1.0), exponent-parity edge cases (odd vs even unbiased), and a 100,000
raw-bits positive sweep bit-exact vs `Base.sqrt`. Zero failures.

SoftFloat dispatch tested: `sqrt(SoftFloat(9.0)) → 3.0`, `sqrt(SoftFloat(2.0))`
bit-exact vs `sqrt(2.0)`.

**End-to-end circuit**: `test/test_float_circuit.jl` extended with a
"Float64 sqrt end-to-end (Bennett-ux2)" testset. Compiles
`float_sqrt(x) = sqrt(x)` via `reversible_compile(f, Float64;
max_loop_iterations=70)` and `simulate`s 15 representative inputs
(perfect squares, irrationals, ±0, ±Inf, NaN, negatives → NaN, smallest
subnormal). All bit-exact vs `Base.sqrt`; `verify_reversibility` passes.
Gotcha: Julia's `sqrt(-1.0)` raises `DomainError`, not NaN, so the test
uses a separate `check_sqrt_nan` path for negative inputs.

### Reversible-circuit gate counts

`reversible_compile(soft_fsqrt, UInt64; max_loop_iterations=70)` compiles
and verifies:

| Metric         | Value     |
|----------------|----------:|
| Total gates    | 1,413,468 |
| NOT            | 75,820    |
| CNOT           | 978,274   |
| Toffoli        | 359,374   |
| T-count        | 2,515,618 |
| Toffoli-depth  | 764       |
| ancillae       | 448,533   |
| peak_live      | 112,696   |

~16× `soft_fdiv`'s 87k gates. Per-iteration cost is higher (128-bit
streaming vs fdiv's 64-bit r) and we run 64 iters vs 56. This is the
first correct implementation; optimization candidates are (1) reduce
leading-zero iterations by rotating the initial radicand alignment,
(2) unroll loop manually to eliminate the `max_loop_iterations=70`
buffer (currently 6 wasted iterations), (3) use `_sf_normalize_clz`
pattern to skip the 8-iter leading-zero block. Deferred — correctness
first.

### Research context (deep-dive subagent synthesis)

- **Berkeley SoftFloat 3** uses seeded-Newton (16-entry table, 2 NR
  iterations, Markstein residual correction via 128-bit remainder).
  Gate-expensive for reversible due to tables + wide multiplies.
- **LLVM compiler-rt** ships no soft-sqrt (treats as libm concern).
  **GCC libgcc soft-fp** uses digit-by-digit restoring — the same
  algorithm we adopted.
- **fdlibm `e_sqrt.c`** is the canonical integer-only correctly-rounded
  reference. Our implementation follows the same pattern structurally.
- **Thapliyal-Muñoz-Coreas 2018** (arXiv:1712.08254): integer sqrt
  reversible circuit, formula `T-count = 7n²/2 + 21n - 28`, 2n+1 qubits
  garbageless. For n=56: ~12k T, ~1.7k Toffoli, 113 qubits.
- **Gayathri et al. 2022** (IJTP doi:10.1007/s10773-022-05222-7): first
  "optimized" FP32 Babylonian sqrt reversible, single-precision, no
  full IEEE special-case coverage.
- **No published FP64 fully-IEEE sqrt reversible circuit** predates
  this entry.

### Files changed

- `src/softfloat/fsqrt.jl` (new, 98 lines)
- `src/softfloat/softfloat.jl` — `include("fsqrt.jl")`
- `src/Bennett.jl` — export `soft_fsqrt`, `register_callee!(soft_fsqrt)`,
  `Base.sqrt(x::SoftFloat) = SoftFloat(soft_fsqrt(x.bits))`
- `test/test_softfsqrt.jl` (new, 170 lines, 56 testsets — bit-level)
- `test/test_float_circuit.jl` — new "Float64 sqrt end-to-end" testset
  (compiles + simulates the 1.4M-gate circuit, 15 inputs + reversibility)
- `test/runtests.jl` — wire new bit-level test
- `WORKLOG.md` — this entry

### Gotchas learned

1. **Exponent parity is the #1 subtle bug.** If unbiased exponent is odd,
   mantissa must be doubled (`ma << 1`) before the sqrt loop, else result
   is off by √2. Arithmetic right shift handles the halving correctly for
   negative exponents (`(-1074) >> 1 == -537` in Int64).
2. **128-bit streaming via (a_hi, a_lo) UInt64 pair** mirrors `soft_fmul`'s
   106-bit product assembly — no UInt128 needed (which would hit runtime
   library calls like `__udivti3` that aren't registered callees).
3. **64 iterations, not 56.** We process the full 128-bit register (top
   16 bits known zero for our radicand placement); first ~8 iters produce
   leading zeros in q but the meaningful bits land at position 55 exactly.
   Alternative (56 iters with per-iter compile-time shift amount) requires
   loop metaprogramming — avoided for simplicity.
4. **`max_loop_iterations` needed** for `reversible_compile(soft_fsqrt, ...)`:
   the LLVM IR is not fully unrolled; Bennett.jl's lowering detects the
   back-edge and needs the bound. Pass `max_loop_iterations=70` (64 iters +
   buffer; same pattern as `float_div` with `=60`).
5. **sqrt(-0) = -0** (IEEE 754 §6.3), not NaN. Preserved via `a_zero` branch
   returning `a` unchanged.

### Follow-ups (not blocking)

- Gate-count reduction via manual loop unroll or leading-zero-iteration skip
- Extend intrinsic coverage: next candidates per the group-A transcendental
  roadmap are `llvm.exp` / `llvm.log` (Bennett-cel / Bennett-582)

---

## Session log — 2026-04-15 — `:tabulate` strategy for small-W pure functions (Bennett-cfjx)

Sturm.jl hit statevector caps on trivial-looking polynomials at low bit-width
(x²+3x+1 @ W=2 compiled to 43 wires, exceeding 30-qubit Orkan). Root cause:
the expression-graph path holds every SSA intermediate live simultaneously
even when the input domain has only 2^W points — at W=2 the input has 4
values total, so evaluating f classically and emitting the result via QROM
is strictly smaller.

### What was built

- `src/tabulate.jl` — new file.
  - `lower_tabulate(f, arg_types, widths; out_width) → LoweringResult`.
    Enumerates all 2^sum(widths) input tuples, evaluates `f`, packs the
    result into a UInt64 table, and emits via the existing `emit_qrom!`
    (Babbush-Gidney). Sets `self_reversing=true` so `bennett()` skips the
    copy+reverse wrap — QROM is already self-cleaning.
  - `_tabulate_applicable(arg_types, bit_width) → (Bool, String)` — hard
    cap at total input width ≤ 16 bits; integer arg types only.
  - `_tabulate_auto_picks(parsed, arg_types, bit_width) → Bool` — the
    `:auto` cost model. Picks tabulate only when (a) total input width ≤ 4
    AND (b) the IR contains at least one O(W²)-lowered op (`mul`/`udiv`/
    `sdiv`/`urem`/`srem`). This correctly flips `x^2+3x+1 @ W=2` to tabulate
    while keeping `x+1` on the expression path at every width.
- `src/Bennett.jl` — new `strategy::Symbol=:auto` kwarg on both integer
  and Float64 `reversible_compile` entry points. Validates the value
  (`:auto | :tabulate | :expression`); Float64 rejects `:tabulate` with a
  clear error (2^64 table would be absurd).
- `test/test_tabulate.jl` — 94 assertions. Covers acceptance case
  (x²+3x+1 @ W=2 ≤ 10 wires / ≤ 15 Toffoli), single- and two-arg
  polynomials, W=2/3/4 scaling, `:auto` flip behavior, `:expression`
  override, and explicit-error paths (unknown strategy, Float64 reject).

### Acceptance numbers

| Function            | Strategy        | Wires | Gates | Toffoli |
|---------------------|----------------|------:|------:|--------:|
| x²+3x+1 @ W=2       | `:tabulate`    |     9 |    26 |       6 |
| x²+3x+1 @ W=2       | `:expression`  |    25 |    80 |       — |
| x*x @ W=4           | `:tabulate`    |    17 |   124 |      30 |
| x*x @ W=4           | `:expression`  |    61 |    ~220 |     — |
| x+1 @ W=4 (:auto)   | `:expression` ✓|    14 |    48 |       — |
| a+b @ W=2 (:auto)   | `:expression` ✓|     8 |    22 |       — |
| a*b @ W=2 (:auto)   | `:tabulate` ✓  |    15 |    51 |       — |

All nine regression baselines in `test_gate_count_regression.jl`
unchanged. `test_narrow.jl` `Int4 poly` baseline moved from 71w/256g
→ 17w/132g because `:auto` now correctly picks tabulate — assertion
(`< gate_count at Int8`) still holds.

### Cost-model rationale (what actually breaks the width-only heuristic)

First pass used `W ≤ 4` as the sole predicate. Wrong: at W=4, `x+1`
expression path is 14 wires / 48 gates, while tabulate is 17 wires /
124 gates. Expression wins for pure additive functions because ripple-carry
is O(W) while tabulate is 2(2^W - 1) Toffoli + fan-out, which grows
exponentially in W. The fix is to require an O(W²)-lowered op in the IR
— `mul`/`udiv`/`sdiv`/`urem`/`srem`. These are the only ops where the
expression path is quadratic, and they're exactly what makes `x²+3x+1`
expensive.

Empirical check across (W, function) pairs confirmed the two-factor model
picks the smaller circuit in all probed cases (see commit discussion).

### Bit-exactness of classical evaluation

`lower_tabulate` evaluates `f` at the source type (e.g. `Int8`) and masks
the result to the output bit width. This matches the narrowed-IR semantics
for add/sub/mul/shift/bitwise (these form a ring homomorphism under
reduction mod 2^W). For signed division and comparisons, native and
narrowed paths can diverge at small W — documented as a known limitation;
the user should stick to `strategy=:expression` for div/rem-heavy code at
narrow bit widths.

### Integration surface

Zero changes to `lower.jl`, `bennett_transform.jl`, `ir_types.jl`,
`ir_extract.jl`, `gates.jl`, or the phi resolution algorithm. Not a
"core change" under CLAUDE.md §2; followed red-green TDD (principle 3).
Sturm.jl inherits the new kwarg through its existing
`oracle(f, x; kw...)` pass-through — no Sturm-side changes needed.

### Files changed

- `src/tabulate.jl` (new, 168 lines)
- `src/Bennett.jl` — `include("tabulate.jl")`, `strategy=` kwarg on both
  `reversible_compile` signatures, dispatch logic
- `test/test_tabulate.jl` (new, 130 lines, 94 assertions)
- `test/runtests.jl` — wire in new test file
- `WORKLOG.md` — this entry

---

## Session log — 2026-04-14 — advanced-arithmetic workstream kickoff

Sidequest triggered by Sun-Borissov 2026
(`docs/literature/multiplication/sun-borissov-2026.pdf`, arXiv:2604.09847, a
polylogarithmic-depth quantum multiplier using indicator-controlled copies +
binary adder tree of Draper QCLAs). Spawned a 22-issue workstream to land
the algorithm plus supporting infrastructure. PRD:
`docs/prd/advanced-arithmetic-PRD.md`. DAG in bd memory under
`advanced-arithmetic-workstream-sun-borissov-2026-mul-draper`. Ground truth
papers downloaded to `docs/literature/arithmetic/` (Draper QCLA,
quant-ph/0406142) and `docs/literature/multiplication/` (Sun-Borissov).

### Closed so far this session

| Issue | Phase | Summary |
|-------|-------|---------|
| Bennett-6xdi | G0 | PRD for advanced-arithmetic workstream |
| Bennett-yxmz | M1 | `toffoli_depth(c)` + `t_depth(c; decomp=:ammr|:nc_7t)` |
| Bennett-z29g | M2 | Toffoli-depth baselines pinned in regression test |
| Bennett-8daw | F1 | `emit_fast_copy!` (Sun-Borissov Alg 1); 84/84 pass |
| Bennett-98k2 | C1 | `emit_conditional_copy!` + `emit_partial_products!`; 3585/3585 pass |
| Bennett-cnyx | Q1 | QCLA design consensus (`docs/design/qcla_consensus.md`) |
| Bennett-6moh | Q2 | `test/test_qcla.jl` RED test landed |
| Bennett-bo91 | Q3 | `src/qcla.jl` GREEN; 2587/2587 pass |
| Bennett-63h0 | Q4 | Three-way adder baseline table (this section) |
| Bennett-4uys | D1 | `add=:auto|:ripple|:cuccaro|:qcla` kwarg dispatcher; 46/46 pass |
| Bennett-a439 | A1 | parallel_adder_tree design consensus (Schedule A, black-box QCLA) |
| Bennett-5qze | A2 | `emit_parallel_adder_tree!` forward pass; 398/398 pass |

### Open workstream (10 issues remaining)

Critical path: A3 (uncompute-in-flight) → X1 (7-step multiplier assembly)
→ X2 (scale) → X3 (paper-match). Then P1 (self_reversing flag) → P2
(mul dispatcher) → P3 (kwarg plumbing). Then B1/B2 (benchmark) and Z1
(session close).

Blockers and gotchas for the next session:
- **A3 (Bennett-lvk4)**: Schedule A linearized uncompute per consensus.
  Each `_AdderRecord` replays `gates[gs:ge]` in reverse to zero
  internal wires. Consensus accepts 2× depth hit; Schedule B is a
  deferred tightening for X3.
- **X1 (Bennett-22o5)**: 7-step Sun-Borissov algorithm. F1/C1/A3 are
  the building blocks. Implement in `src/mul_qcla_tree.jl`.
- **P1 (Bennett-ellx)**: core change to `bennett.jl` — requires 3+1
  agents per principle 2. Generalize Cuccaro's self-reversing pattern.
- **X1 test edge**: `UInt8 * UInt8` in Julia wraps mod 256 — test
  expectations must widen operands to `Int` before multiplying (see
  `test/test_parallel_adder_tree.jl` for the fix).

