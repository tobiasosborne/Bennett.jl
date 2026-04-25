# Advanced Arithmetic Strategies — PRD

**STATUS: COMPLETED 2026-04-14** — historical PRD; QCLA + Sun-Borissov mul tree shipped per worklog/015. Preserved as the milestone reference.

## One-line summary

Turn Bennett.jl into the benchmarking arena for reversible arithmetic: add
per-op strategy dispatch (mirroring `_pick_alloca_strategy`), land Draper QCLA
(quant-ph/0406142) as a new adder, and land Sun-Borissov 2026 (arXiv 2604.09847)
as a new polylogarithmic-depth multiplier. Karatsuba already exists; this PRD
wires it and the new strategies under a single dispatcher with user-visible
control.

---

## 1. The key insight

Reversible arithmetic is not one algorithm per operation — it is a **cost
surface**. The right point on that surface depends on what the caller is
optimizing for:

| Caller constraint              | Wants low …    | Prefers …            |
|--------------------------------|----------------|----------------------|
| Classical reversible CMOS      | Gate count     | Cuccaro / shift-add  |
| Near-term NISQ oracle          | Ancilla        | Cuccaro              |
| Fault-tolerant quantum oracle  | T-depth        | QCLA / Sun-Borissov  |
| Embedded in circuit with peak wire limit | Peak live qubits | pebbled-group |

Bennett.jl already carries this shape for memory ops
(`_pick_alloca_strategy` → shadow / MUX EXCH / QROM / Feistel) and for Bennett
wrapping (`bennett` vs `pebbled_group_bennett` vs `value_eager_bennett` vs
`checkpoint_bennett`). Extending the same pattern to arithmetic is the
natural next step.

---

## 2. Scope

**In scope (this workstream):**

- **Metric infrastructure** — Rename the current `t_depth` intent-wise into
  `toffoli_depth`; upgrade `t_depth(c; decomp=:ammr|:nc_7t)` to return the
  true Clifford+T decomposition T-depth.
- **QCLA adder** — New primitive `lower_add_qcla!` (out-of-place, O(log n)
  Toffoli-depth, O(n) Toffoli count, O(n) ancilla). Bennett.jl's first
  logarithmic-depth adder.
- **Sun-Borissov multiplier** — New primitive `lower_mul_qcla_tree!` built on
  three sub-primitives: `fast_copy`, `conditional_copy`/`partial_products`,
  and `parallel_adder_tree` (modified QCLA tree with suffix/overlap/carry
  split and level d−2 uncomputed while level d computes).
- **Strategy dispatcher framework** — `_pick_mul_strategy` (and as bonus
  `_pick_add_strategy`) returning a strategy symbol from a budget struct;
  `mul=`/`add=` kwargs on `reversible_compile` for explicit pinning and
  benchmarking.
- **Self-reversing marker** — Generalize the existing Cuccaro-in-place idea
  (issue Bennett-07r) into a first-class flag that tells `bennett.jl` to
  skip the outer forward+copy+uncompute wrap around gate groups that are
  already self-cleaning by construction. Sun-Borissov's 7-step algorithm is
  the canonical second user of this flag.
- **Benchmark harness** — `benchmark/bc6_mul_strategies.jl`, emitting a
  head-to-head table of shift-add vs Karatsuba vs `qcla_tree` at
  W=8/16/32/64 (gates, Toffoli, Toffoli-depth, T-depth, ancilla, peak live).
- **Documentation** — WORKLOG entry with baselines and gotchas; `BENCHMARKS.md`
  updated with the new comparison section; `README.md` feature table
  extended to list the new strategies.

**Out of scope (follow-ups, filed separately if needed):**

- Improved Toffoli decompositions (AMMR-1 vs NC-7T tradeoff implementation).
  We make `t_depth(; decomp=...)` parametric in the decomposition factor, but
  we do not actually emit the Clifford+T gates — Bennett.jl's output remains
  NOT/CNOT/Toffoli.
- QROM-style T-count optimizations layered onto Sun-Borissov. The paper
  presents a single algorithm; we implement it verbatim.
- Cuccaro-to-2n-3-Toffoli tightening (Bennett-gsxe, already tracked).
- Division dispatcher (out of scope — paper does not address division).
- Float strategies — these go through integer strategies via soft-float.

---

## 3. Architecture: strategy dispatcher pattern

Three layers, repeating the working `_pick_alloca_strategy` pattern:

### 3.1 Primitives as named functions

Each strategy is a self-contained lowering in its own file:

| Strategy       | File                       | Entry point                  | Shape                                 |
|----------------|----------------------------|------------------------------|---------------------------------------|
| ripple add     | `src/adder.jl`             | `lower_add!`                 | out-of-place, O(n) depth              |
| Cuccaro        | `src/adder.jl`             | `lower_add_cuccaro!`         | in-place, self-reversing              |
| QCLA           | `src/qcla.jl` (NEW)        | `lower_add_qcla!`            | out-of-place, O(log n) Toffoli-depth  |
| shift-add mul  | `src/multiplier.jl`        | `lower_mul!`                 | O(n²) Toffoli, O(n) peak wires        |
| Karatsuba mul  | `src/multiplier.jl`        | `lower_mul_karatsuba!`       | O(n^1.585) Toffoli                    |
| QCLA tree mul  | `src/mul_qcla_tree.jl` (NEW) | `lower_mul_qcla_tree!`     | O(log²n) Toffoli-depth, self-reversing|

Each primitive documents its cost model in its docstring (gates, Toffoli,
Toffoli-depth, T-depth, ancilla, peak live) in terms of its width parameter.
Docstrings are the regression baseline (principle 6).

### 3.2 Per-op dispatcher

```julia
struct OpBudget
    max_ancilla::Union{Int,Nothing}     # cap; nothing = unlimited
    max_depth::Union{Int,Nothing}
    max_peak_wires::Union{Int,Nothing}
    operand_is_const::Bool              # for future const-aware strategies
end

function _pick_add_strategy(W::Int, budget::OpBudget)::Symbol
    budget.max_depth !== nothing && budget.max_depth < 2W && return :qcla
    budget.max_ancilla !== nothing && budget.max_ancilla <= 2 && return :cuccaro
    return :ripple
end

function _pick_mul_strategy(W::Int, budget::OpBudget)::Symbol
    W <= 4 && return :shift_add  # small widths: overhead of tree exceeds savings
    budget.max_depth !== nothing && budget.max_depth < 3*W && return :qcla_tree
    budget.max_ancilla !== nothing && budget.max_ancilla < 2*W^2 && return :shift_add
    W >= 32 && return :karatsuba
    return :shift_add
end
```

Dispatchers return a `Symbol` matching the strategy name. The user-facing
`mul=`/`add=` kwarg bypasses the dispatcher when set to anything other than
`:auto`.

### 3.3 User kwarg plumbing

```julia
reversible_compile(f, Int64; mul=:qcla_tree, add=:cuccaro, bennett=:pebbled_group)
```

Kwargs thread through `reversible_compile` → `lower()` → `lower_mul!` call
site → `_pick_mul_strategy` (skipped when kwarg is explicit). Default
`:auto` behavior preserves all existing gate-count regression baselines.

---

## 4. Components & test plan

The implementation is broken into 22 bd issues grouped into 9 phases, each
following RED-GREEN TDD (principle 3):

### Phase M — Metrics (Bennett-yxmz, Bennett-z29g)

**M1** adds `toffoli_depth(c)` as the canonical name for the current
behavior and parameterizes `t_depth(c; decomp=:ammr)` with a per-Toffoli
T-layer factor. Default `:ammr` is 1 (preserving current numbers, matching
the Sun-Borissov paper assumption). `:nc_7t` is 3 (Nielsen-Chuang classical
7-T decomposition).

**M2** records Toffoli-depth baselines for existing benchmarks in WORKLOG
and extends `test_gate_count_regression.jl` with a Toffoli-depth column.

### Phase Q — QCLA (Bennett-cnyx, Bennett-6moh, Bennett-bo91, Bennett-63h0)

**Q1** (3+1 agents required per principle 2) produces the design
consensus in `docs/design/qcla_consensus.md`.

**Q2** writes `test/test_qcla.jl` RED: exhaustive W=4 add (all 256 pairs →
expected sum mod 16); sampled W=8 (1000 random + edges); gate-count/
Toffoli-depth assertions against Q1's prediction. Must fail on `main`.

**Q3** implements `src/qcla.jl::lower_add_qcla!` until Q2 goes GREEN.

**Q4** extends the scale to W=8/16/32/64 and records the full regression
baseline table in WORKLOG.

### Phase F, C — Sun-Borissov sub-primitives (Bennett-8daw, Bennett-98k2)

**F1** implements `emit_fast_copy!` (doubling broadcast, n copies of an
n-qubit register in ⌈log n⌉ CNOT layers). Pure CNOT, T-depth 0.

**C1** implements `emit_conditional_copy!` and `emit_partial_products!` (n
Toffolis per partial product on disjoint qubits → Toffoli-depth 1 for all
n² Toffolis).

### Phase A — parallel_adder_tree (Bennett-a439, Bennett-5qze, Bennett-lvk4)

**A1** (3+1 agents) designs the modified QCLA splitting into
`suffix_copying` / `overlapping_sum` / `carry_propagation` (Sun-Borissov
§II.D) and the level d−2 concurrent uncompute schedule.

**A2** implements forward pass (tree of QCLA adders).

**A3** implements uncompute-in-flight, verifying all intermediate
partial-sum registers are zero at tree exit, and total ancilla ≤ 2n²
for n ≥ 6 (paper bound).

### Phase X — Multiplier assembly (Bennett-22o5, Bennett-3ma6, Bennett-4rw9)

**X1** assembles the 7-step algorithm (Sun-Borissov Algorithm 3) into
`lower_mul_qcla_tree!`. RED test: exhaustive W=4 multiplication.

**X2** scales to W=8 (65,536 exhaustive), W=16/32 sampled. Asserts
ancilla ≤ 3n².

**X3** verifies measured resource counts against paper Table III
(Depth 3 log²n + 17 log n + 20, Toffoli-depth 3 log²n + 7 log n + 14,
Toffoli 12n² − n log n, total gates 26n² + 2n log n, ancilla 3n²) within
±10%.

### Phase P — Dispatcher (Bennett-ellx, Bennett-h0tf, Bennett-thpa)

**P1** introduces the `self_reversing::Bool` strategy marker honored by
`bennett.jl` (core file, 3+1 agents). Retrofits Cuccaro and
`lower_mul_qcla_tree!` as its first two users.

**P2** implements `_pick_mul_strategy` and `_pick_add_strategy`.

**P3** threads the `mul=`/`add=` kwargs from `reversible_compile` through
`lower()` to the dispatcher.

### Phase B — Benchmark (Bennett-hllu, Bennett-gga6)

**B1** adds `benchmark/bc6_mul_strategies.jl` (following bc1..bc5
pattern) emitting a markdown table comparing all mul strategies across
gates/Toffoli/Toffoli-depth/T-depth/ancilla/peak_live at W=8/16/32/64.

**B2** updates `BENCHMARKS.md` with the comparison narrative citing
Sun-Borissov 2026 and Draper et al. 2004.

### Phase D — Add dispatcher (Bennett-4uys, lower priority)

**D1** wires the add-op dispatcher analogous to P2 + P3. Lower priority
(P3) because shift-and-add + Cuccaro already cover most cases; QCLA add
primarily benefits multi-operand pipelines.

### Phase Z — Close (Bennett-f81j)

**Z1** writes the session WORKLOG entry and runs the session-close
protocol (git push, bd dolt push).

---

## 5. Success criteria

1. **Correctness.** `verify_reversibility` passes on every new primitive at
   all tested widths. All existing tests pass unchanged.

2. **Coverage.** Every new primitive has a RED-first test file. Exhaustive
   enumeration at the smallest meaningful width (W=4 for add and mul — 256
   pairs for add, 256 pairs for mul). Sampled wider (W=8 exhaustive where
   feasible, random + edges otherwise).

3. **Measurability.** `toffoli_depth` and `t_depth(; decomp=...)` are
   exported and benchmark-reported. Gate counts and Toffoli-depth for every
   new strategy are recorded in WORKLOG and pinned in
   `test_gate_count_regression.jl`.

4. **Dispatcher integrity.** `reversible_compile(f, T; mul=:X)` for each
   `X ∈ {:shift_add, :karatsuba, :qcla_tree, :auto}` produces three
   distinct gate counts (distinct strategies → distinct circuits) and the
   compiled circuit computes the same mathematical product in all cases.

5. **Paper alignment.** Measured resource counts for `lower_mul_qcla_tree!`
   agree with Sun-Borissov Table III to within ±10% at n ∈ {8, 16, 32}.
   Divergences are investigated and documented in WORKLOG (principle 7).

6. **Benchmark publishability.** `BENCHMARKS.md` contains a
   Multiplication-strategies section citing the two papers with a full
   comparison table.

---

## 6. Test-coverage requirements

- **Unit**: every primitive (`lower_add_qcla!`, `emit_fast_copy!`,
  `emit_conditional_copy!`, `emit_partial_products!`, `lower_mul_qcla_tree!`)
  has a dedicated test file with exhaustive small-W cases.
- **Integration**: `lower_mul_qcla_tree!` is reachable from a plain Julia
  function `f(x, y) = x * y` compiled with `reversible_compile(..., mul=:qcla_tree)`,
  and the end-to-end circuit passes `verify_reversibility`.
- **Regression**: `test_gate_count_regression.jl` pins per-strategy gate
  counts and Toffoli-depth so that unintended changes break the build.
- **Paper-match**: `test_mul_qcla_tree_paper_match.jl` asserts measured
  resource counts fit Sun-Borissov's formulas.

---

## 7. Dependencies & ordering

See the DAG in bd memory key
`advanced-arithmetic-workstream-sun-borissov-2026-mul-draper`. Critical
path: G0 → Q1 → Q3 → A1 → A3 → X1 → X2 → X3 → P1 → Z1. Parallel side
chains: F1, C1, D1, B1 can run once their gates are open.

Key blockers:
- Q1 and A1 require 3+1 agents per principle 2 and should be front-loaded
  because their outputs are inputs to Q3 / A2.
- P1 (self_reversing flag) must land BEFORE `lower_mul_qcla_tree!` is
  wired to the dispatcher, otherwise Bennett double-wraps the already
  self-cleaning primitive and correctness fails loudly (principle 1).

---

## 8. References

- `docs/literature/multiplication/sun-borissov-2026.pdf` — A
  Polylogarithmic-Depth Quantum Multiplier, Fred Sun & Anton Borissov,
  softwareQ + Waterloo, arXiv:2604.09847, 2026-04-10.
- `docs/literature/arithmetic/draper-kutin-rains-svore-2004.pdf` — A
  Logarithmic-Depth Quantum Carry-Lookahead Adder, Draper/Kutin/Rains/Svore,
  arXiv:quant-ph/0406142, 2004.
- Amy/Maslov/Mosca/Roetteler 2013 — `T`-depth 1 Toffoli decomposition
  assumption underpinning the `:ammr` choice in `t_depth`.
- `docs/prd/Bennett-VISION-PRD.md` — the enclosing roadmap. This
  workstream advances pillar II (space/time optimization) and pillar III
  (composability).

---

## 9. Non-goals made explicit

- **Not a new compiler version.** This is feature work on the v0.5 codebase,
  not a v0.6 bump.
- **Not a paper reproduction.** We implement the algorithms faithfully but
  we don't promise bit-identical gate sequences to the paper's reference
  implementation (which doesn't exist as code yet) — only resource-cost
  equivalence to within ±10%.
- **Not a T-gate emission target.** Bennett.jl continues to emit
  NOT/CNOT/Toffoli. `t_depth` is derived via decomposition assumption.
- **Not a dynamic benchmark runner.** `bc6_mul_strategies.jl` is a static,
  reproducible snapshot; it does not do continuous/CI benchmarking.
