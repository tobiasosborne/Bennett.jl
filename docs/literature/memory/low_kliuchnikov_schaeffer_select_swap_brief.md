# Brief: Low, Kliuchnikov & Schaeffer 2024 — SelectSwap / QROAM

## Header

- **Title:** Trading T gates for dirty qubits in state preparation and unitary
  synthesis
- **Authors:** Guang Hao Low, Vadym Kliuchnikov (Microsoft Research / Azure
  Quantum, Redmond), Luke Schaeffer (MIT EECS / QuICS, U. Maryland)
- **Venue:** Quantum, accepted 2024-05-22; arXiv:1812.00954 (preprint 2018).
- **Source status:** Full LaTeX source available locally at
  `docs/literature/memory/low-kliuchnikov-schaeffer-2024-tex/LowTStatePrepQuantum.tex`
  (834 lines) plus `.bbl`, `tCount.pdf`, and 22 `tikz/*.{qpic,pdf}` figure
  files. The compiled main PDF is **not** in the collection.
- **Category:** MEMORY / QROM — this is the *origin paper* of the
  **SelectSwap network** (a.k.a. **QROAM**), the canonical
  ancilla-for-T-gate table-lookup trade-off.
- **One-line key idea:** Split the address `x` into `(q, r)` with `x = q·λ + r`;
  a `Select` multiplexer controlled on `|q⟩` loads λ data words at once into a
  `bλ`-qubit register, then a `Swap` network controlled on `|r⟩` moves the
  wanted word to the output. T-count `O(N/λ + bλ)`, minimised at `λ ≈ √(N/b)`
  for `O(√(Nb))` — a quadratic improvement over the linear-T `λ=1` baseline.
  Crucially, all but `b + ⌈log₂N⌉` qubits may be **dirty**.

---

## 1. Background and context

### 1.1 The data-lookup oracle

The paper's workhorse is the data-lookup oracle (Eq. `standard_oracle`):

    O |x⟩|0⟩|0⟩ = |x⟩|a_x⟩|garbage_x⟩

`x ∈ [N]` is a `⌈log₂N⌉`-qubit address; `a_x ∈ {0,1}^b` is a `b`-bit classical
word fixed at compile time. The garbage register is always uncomputable by
running `O` in reverse. This is exactly Bennett.jl's QROM contract
`(idx, 0^W) → (idx, data[idx])` with `N = L` (table length) and `b = W` (word
width) — except Bennett emits a garbage-free, self-cleaning version.

The wider paper uses `O` to build arbitrary state preparation (`O(√N)` T-count,
a √N win over Shende-Bullock-Markov) and unitary synthesis; those are out of
scope for Bennett. **The QROM/`O` subroutine is the only part relevant here.**

### 1.2 The three building blocks (Table `cost_comparison`)

| Operation | Qubits | T count | T depth |
|---|---|---|---|
| `Select` (multiplexer, λ=1) | `b + 2⌈log₂N⌉` | `4N` | `N` |
| `Swap` (full swap network) | `bN + ⌈log₂N⌉` | `8bN` | `log N` |
| `SelectSwap` (hybrid) | `bλ + 2⌈log₂N⌉` | `4⌈N/λ⌉ + 8bλ` | `N/λ + log λ` |
| Fig. `select`d (dirty) | `b(λ+1) + 2⌈log₂N⌉` | `8⌈N/λ⌉ + 32bλ` | `N/λ + log λ` |

- **`Select`** = the multiplexer of Childs et al. / Babbush-Gidney: apply `X^{a_x}`
  controlled on `|x⟩` via unary iteration. `O(N)` Clifford+T, plus `O(bN)`
  Clifford for the controlled-X fan-out. This is **exactly what Bennett's
  `emit_qrom!` already does** (the `λ=1` row).
- **`Swap`** = a network of controlled-SWAPs that moves the `x`-indexed
  `b`-qubit register to the `x=0` slot. Each CSWAP = 2 CNOT + 1 Toffoli.
- **`SelectSwap`** = the hybrid. Duplicate the `b`-bit register λ times;
  `Select` (on `|q⟩`) writes λ words into the λ registers at once; `Swap`
  (on `|r⟩`) extracts the one indexed by `r`. T-count `4⌈N/λ⌉ + 8bλ` —
  the `N/λ` term from the smaller `Select`, the `bλ` term from the `Swap`.

### 1.3 Where Bennett.jl sits today

`src/qrom.jl` implements **Babbush-Gidney unary iteration at λ = 1**:
`2(L−1)` Toffoli, `O(L·W)` CNOT, `4(L−1)` T-count, `log₂L` *clean* ancillae,
**W-independent Toffoli count**, self-cleaning (a compute/uncompute pair of AND
trees straddling the data fan-out — so it needs no Bennett wrap).

This is precisely the `Select` row of Table `cost_comparison` — the `λ=1`
corner of the SelectSwap family. Bennett's `2(L−1)` Toffoli is even tighter
than the paper's loose `4N` (Bennett counts an optimised AND-tree;
the paper's `4N` is an `O(·)` upper bound). **Bennett does not implement any
λ > 1 SelectSwap/QROAM variant** — `grep` for `qroam|selectswap|selswap`
across `src/` and `test/` returns nothing.

`tabulate.jl` is the only caller of `emit_qrom!`: `:auto` picks the tabulate
path only for `L ≤ 16` (total input width ≤ 4), capped at `L ≤ 2^16`.

---

## 2. The SelectSwap / QROAM construction

### 2.1 Address split

For `λ` a power of 2, the `⌈log₂N⌉`-qubit address `|x⟩` splits directly into
`|q⟩` (`log₂(N/λ)` qubits) and `|r⟩` (`log₂λ` qubits), `x = q·λ + r` — a free
relabelling of wires. For non-power-of-2 `λ`, the paper computes the quotient
`q = x ÷ ⌊λ⌋` and remainder `r = x mod λ` explicitly, at additive cost
`O(log N · log λ)` gates. **The clean QROAM keeps λ a free integer in `[1,N]`**
(Table `cost_comparison` caption: "a choice of `λ ∈ [1,N]`") — unlike the
Motlagh-Pocrnic 2026 dirty refinement, which constrains λ to a power of 2.

### 2.2 `Select` on `|q⟩` — multiplexed multi-word load

`Select` is a unary iteration over `|q⟩` (an AND tree over `log₂(N/λ)` index
bits → `N/λ` one-hot leaf flags). For each leaf flag `q`, the data fan-out
writes **all λ words** `a_{qλ}, a_{qλ+1}, …, a_{qλ+λ−1}` into a `bλ`-qubit
register simultaneously, i.e. `U_q = ⊗_{j=0}^{λ−1} X^{a_{qλ+j}}`. T-count
`O(N/λ)` (Toffoli `2(N/λ − 1)` for a Bennett-style AND tree), plus `O(bλ)`
CNOT for the fan-out. This is **`emit_qrom!` with a `bλ`-wide output and a
re-shaped data table** — structurally a near-trivial generalisation.

### 2.3 `Swap` on `|r⟩` — extract the wanted word

`Swap` moves the `r`-indexed `b`-qubit sub-register to the `r=0` (output) slot,
controlled on `|r⟩`. Decomposes into `log₂λ` layers of controlled pairwise
SWAPs: for bit `j` of `r`, swap register pairs `{(i, i+2^j)}` controlled on
`|r_j⟩`. Each `CSWAP_n` (swap of two `n`-qubit registers) is `n` controlled
qubit-swaps; each qubit-swap = 3 CNOT, the middle one promoted to Toffoli ⇒
`n` Toffoli + `2n` CNOT per `CSWAP_n`. Total `Swap` Toffoli `O(bλ)`.
Appendix `sec:swap` gives three variants:

- **Linear depth, no ancilla:** `7n` T, depth `4n+4`.
- **Logarithmic depth, no ancilla:** `≤ 10n` T (after cancellations; naive
  `14n`), depth `O(log n)`, via a self-inverse "toggling" trick (the swapped
  registers themselves serve as dirty scratch).
- **Phase-incorrect, log depth, no ancilla:** `4n` T, using the Barenco et al.
  faulty-sign Toffoli `G = S†·H·T·H·S`. The `±1` phase is absorbed into the
  garbage register, so it is harmless *for the oracle of Eq. standard_oracle*.

### 2.4 Cost and the optimal λ

SelectSwap T-count `O(N/λ + bλ)`, qubits `bλ + 2⌈log₂N⌉`. Both the `Select`
control register (`log₂(N/λ)`) and the `Swap` control register (`log₂λ`) drive
the cost; `T ∝ N/λ + bλ` is minimised at **`λ = √(N/b)`**, giving
**`T = O(√(Nb))`** — a quadratic improvement over the `λ=1` linear-`N` baseline.
Optimality is proven (paper §"Lower bound") via a circuit-counting argument:
`q·Γ = Ω(bN − q²)`, matched up to log factors when `λ = o(√(N/b))`.

### 2.5 The dirty-qubit modification (Fig. `select`d)

The headline of the broader paper: in `SelectSwap`, the `bλ`-qubit data
register **need not be clean**. For any computational-basis dirty state
`|φ⟩ = ⊗_r |φ_r⟩`, the construction (the chain of `→` arrows after Eq.
`select`d) is:

1. `|0⟩|φ⟩ → |0⟩|φ_r ⊕ a_x⟩_0 …`  — load all words via `Select`, mixing into φ
2. `→ |φ_r ⊕ a_x⟩|φ_r ⊕ a_x⟩_0 …` — copy out
3. `→ |φ_r ⊕ a_x⟩|φ⟩`             — `Swap` back
4. `→ |φ_r ⊕ a_x⟩|φ_r⟩_0 …`       — second `Select` re-mixes
5. `→ |a_x⟩|φ_r⟩_0 …`             — φ cancels (XOR self-inverse)
6. `→ |a_x⟩|φ⟩`                   — `Swap` back; dirty register restored

Cost (Fig. `select`d row of Table `cost_comparison`): `8⌈N/λ⌉ + 32bλ` T —
roughly 2× the clean `SelectSwap`, the price of the double-load. **All but
`b + ⌈log₂N⌉` qubits are dirty.** This is the construction the Motlagh-Pocrnic
2026 paper later refines (SelectCopy halves the `32bλ` swap term; bit-packets
halve the `8N/λ` term).

### 2.6 The "Developments after 2018" addendum (§ same-named)

The published 2024 version appends a survey paragraph. Two facts matter for
Bennett:

- **Berry et al. 2019 garbage uncomputation** (`Berry2019CholeskyQubitization`):
  with intermediate measurements, the garbage register of `SelectSwap` can be
  uncomputed with `4⌈N/λ⌉ + 4λ` T gates and `λ + ⌈log(N/λ)⌉` clean qubits —
  **independent of `b`**. This is the prior SOTA the Motlagh-Pocrnic paper beats.
- "Our `SelectSwap` architecture of table lookup remains state-of-art … all
  methods with an asymptotic advantage … do so by reduction to `SelectSwap`."

---

## 3. Clean-ancilla variant — does it exist? (item 1)

**Yes — unambiguously, and it is the *default / primary* construction of the
paper, not an afterthought.** The dirty-qubit version (Fig. `select`d, §2.5
above) is a *modification* applied on top.

The clean `SelectSwap` row of Table `cost_comparison` is stated outright:

> `SelSwap` — `bλ + 2⌈log₂N⌉` qubits, `4⌈N/λ⌉ + 8bλ` T, depth `N/λ + log λ`.

Nothing in that row is dirty: the `bλ` data register, the `2⌈log₂N⌉` index
ancillae — all clean, initialised `|0⟩`, returned to `|0⟩`. The caption then
*adds*: "Note that `bλ` qubits of the [Fig. `select`d] implementation **may**
be dirty" — i.e. dirtiness is an *optional relaxation* of the clean baseline,
costing the ~2× T-count blow-up (`8N/λ + 32bλ` vs `4N/λ + 8bλ`).

For Bennett.jl this is decisive: **the clean `N/λ + bλ` SelectSwap is a
faithful, drop-in target that requires no dirty-ancilla machinery.** The whole
"trade T for *dirty* qubits" headline — and the obstacle it poses to Bennett's
ancilla-zero invariant — applies only to Fig. `select`d. The clean `SelectSwap`
allocates ordinary clean ancillae, runs `Select` then `Swap`, and the AND-tree
flags self-uncompute; ancilla hygiene is identical in spirit to the existing
`emit_qrom!`. (One caveat — §6.)

This also resolves a confusion seeded by the companion Motlagh-Pocrnic brief,
which says "the correct reference for Bennett is the *clean-ancilla* QROAM
`N/λ + bλ`, not the dirty paper." **That clean `N/λ + bλ` reference IS this
paper.** Low-Kliuchnikov-Schaeffer 2024 is simultaneously the origin of QROAM
*and* the source of the clean-ancilla cost Bennett should target.

---

## 4. Crossover analysis — when does QROAM beat Bennett's λ=1 QROM? (item 2)

Bennett's current QROM (λ=1): **Toffoli `2(L−1)`**, W-independent, `log₂L`
clean ancillae. Clean `SelectSwap` at depth λ: **Toffoli ≈ `2(N/λ−1) + (Toffoli
of Swap)`**. Translating the paper's T-counts to Toffoli (each Toffoli ≈ 4 T in
the AND-tree convention Bennett uses; `4N` T ↔ `2N` Toffoli; the `8bλ` T of
`Swap` ↔ `≈ 2bλ` Toffoli since each CSWAP contributes one Toffoli + two CNOT):

    Toffoli_QROAM(λ)  ≈  2·(N/λ − 1)  +  2·b·λ          (clean SelectSwap)
    Toffoli_unary     =  2·(N − 1)                       (Bennett today)

**Crossover condition.** QROAM wins when `2N/λ + 2bλ < 2N`, i.e.

    N/λ + bλ  <  N        ⟺      λ ∈ ( roughly 1 , N/b )   and    N > 4b·(something)

More usefully, at the *optimal* `λ* = √(N/b)` the QROAM Toffoli is
`≈ 4√(Nb) − 2`, versus unary `2N − 2`. So:

> **QROAM (at optimal λ) beats Bennett's λ=1 QROM once `4√(Nb) < 2N`, i.e.
> `N > 4b`.** Equivalently `L > 4W`.

Concrete crossover table (Toffoli, clean SelectSwap, `λ*=√(L/W)` rounded to a
power of 2):

| L (=N) | W (=b) | unary `2(L−1)` | QROAM `≈4√(LW)` | winner |
|---|---|---|---|---|
| 16    | 8  | 30      | ~45  | unary |
| 16    | 64 | 30      | ~128 | unary (W ≥ L) |
| 256   | 8  | 510     | ~181 | **QROAM** |
| 256   | 64 | 510     | ~512 | tie |
| 4096  | 8  | 8190    | ~724 | **QROAM** (~11×) |
| 4096  | 64 | 8190    | ~2048| **QROAM** (~4×) |
| 65536 | 32 | 131070  | ~5793| **QROAM** (~22×) |

**Interpretation for Bennett:**

- **Every table Bennett emits today is on the wrong side of the crossover.**
  `:auto` picks tabulate only for `L ≤ 16` (input width ≤ 4). At `L=16` the
  unary QROM is 30 Toffoli — already tiny — and QROAM's `bλ` overhead makes it
  *strictly worse* for any `W ≥ 8`. The crossover `L > 4W` is never reached
  inside the current tabulate envelope.
- **QROAM only pays off for large tables** — `L ≳ 256` and `L ≫ W`. That means
  Bennett would first have to *raise the tabulate `L` cap* (or add a separate
  QROAM lowering path for large LLVM constant arrays / big S-boxes / LUT-heavy
  code) before QROAM has any customer at all.
- **W-independence is lost.** Bennett's `2(L−1)` Toffoli is W-independent;
  *every* QROAM cost has `b=W` explicitly (`bλ` term). Adopting QROAM makes the
  Toffoli count W-dependent. This is intrinsic to the ancilla-for-Toffoli trade,
  not a regression — W-independence is a property of λ=1 unary iteration
  specifically. The `λ`-vs-`W` crossover (`L > 4W`) is the quantitative face of
  this loss.
- **Ancilla cost.** QROAM needs `bλ ≈ √(Nb)` extra clean wires vs unary's
  `log₂L`. At `L=4096, W=8`: unary uses 12 ancillae, QROAM `λ*` uses `bλ ≈ 8·23
  ≈ 184`. The trade is real: ~15× the ancillae for ~11× fewer Toffoli.

---

## 5. The two implementation targets (item 4)

If Bennett ever wants ancilla-traded large-table lookup, there are two distinct,
separable targets from this paper. They are ordered by recommendation.

### Target A — Clean-ancilla `SelectSwap` / QROAM  *(recommended first target)*

The clean `4⌈N/λ⌉ + 8bλ` T construction of §2.2–2.4. **Fully compatible with
Bennett's ancilla-zero invariant** — every wire is a clean ancilla or
input/output; the AND-tree flags self-uncompute exactly as in `emit_qrom!`.

Building blocks Bennett already has or nearly has:

- **`Select` on `|q⟩`:** `emit_qrom!`'s AND-tree + CNOT fan-out, generalised to
  a `bλ`-wide output register and a re-shaped data table (row `q` holds the λ
  words `a_{qλ..qλ+λ−1}` concatenated). Near-trivial extension of existing code.
- **`Swap` on `|r⟩`:** genuinely new. A `log₂λ`-layer network of controlled
  pairwise register-swaps. Each register-CSWAP decomposes to existing
  `CNOTGate` + `ToffoliGate` (3 CNOT per qubit-swap, middle → Toffoli). New
  `emit_select_swap!` helper; **no new gate primitive** needed.
- **Address split + cost model:** partition `idx_wires` into `|q⟩`/`|r⟩`, pick
  `λ` (power of 2 nearest `√(L/W)`) from a cost model — analogous to the
  `add=:ripple|:qcla|:auto` dispatcher.

Difficulty: **medium.** ~300-LOC extension of `qrom.jl` (or one new file
`qroam.jl`), plus a `qrom=:unary|:qroam|:auto` kwarg and a new dispatch arm in
the tabulate / GEP-lowering path. Touches the lowering cost model ⇒ **3+1 agent
split warranted** (CLAUDE.md rule 2). New regression baselines in
`test_gate_count_regression.jl`.

### Target B — Phase-incorrect log-depth `Swap` (Appendix `sec:swap`)  *(optional, low priority)*

The `4n`-T phase-incorrect `CSWAP_n` of §2.3 (Barenco faulty-sign Toffoli).
**NOT directly usable in Bennett**: the `±1` phase is only harmless when
absorbed into a *garbage register* that is later uncomputed by `O†`. Bennett's
QROM is garbage-free and Bennett has no phase bookkeeping — a faulty sign on a
classical reversible circuit is invisible to `simulate` (which tracks bit
values, not phases), so it would *pass* `verify_reversibility` while being
quantum-incorrect. **Do not adopt the phase-incorrect Swap** unless/until
Bennett grows a phase-aware simulator. The *correct* log-depth Swap (`≤10n` T,
the self-inverse toggling trick, §2.3) IS safe and is the right choice if depth
ever matters; but it uses borrowed registers as dirty scratch — see §6.

**Not a target: the dirty-qubit Fig. `select`d construction.** Same verdict as
the Motlagh-Pocrnic brief — it relies on `|φ⟩` being an externally borrowed
arbitrary-state qubit, which Bennett's `WireAllocator` and `verify_reversibility`
have no concept of. Running it on clean ancillae just buys the dirty cost
(`8N/λ + 32bλ`) for no reason when clean `SelectSwap` (`4N/λ + 8bλ`) is
strictly cheaper. Skip it.

---

## 6. Implementation plan and verdict (items 5, 6)

### 6.1 Implementation plan (for Target A, if scheduled)

1. **Prerequisite — raise the table-size envelope.** QROAM has zero customers
   until Bennett emits tables with `L > 4W`. Either lift the `tabulate` `L` cap
   above 16, or add a separate large-array lowering that routes big LLVM global
   constant arrays / S-boxes through QROM directly. *Without this step Target A
   is dead code.* File as a blocking predecessor bead.
2. **RED:** add `test/test_qroam.jl` — verify `(idx, 0^W) → (idx, data[idx])`
   for representative `(L, W, λ)` triples, exhaustively over all `L` addresses;
   assert ancilla-zero via `verify_reversibility`. Include a diamond case `L`
   not a power of 2 only if the address-split path supports it (else require
   power-of-2 `L` like `emit_qrom!`).
3. **GREEN — `Select` generalisation:** extend `emit_qrom!` (or factor a shared
   `_qrom_tree!`) to fan out into a `bλ`-wide register from a re-shaped table.
   Verify against the existing λ=1 baseline (`λ=1` must reproduce `emit_qrom!`
   bit-for-bit and gate-for-gate — a regression anchor).
4. **GREEN — `emit_select_swap!`:** the `log₂λ`-layer controlled pairwise
   register-swap network, decomposed to `CNOTGate`/`ToffoliGate`. Start with the
   linear-depth ancilla-free variant (§2.3 first bullet) — simplest, correct,
   no borrowed scratch. Test `Swap` in isolation first.
5. **GREEN — cost model + dispatch:** `qrom=:unary|:qroam|:auto` kwarg; `:auto`
   picks `λ* = `nearest-power-of-2-to-`√(L/W)` and chooses QROAM iff
   `4√(LW) < 2(L−1)` (the §4 crossover). Mirror the `add=:auto` dispatcher
   shape so explicit-strategy gate-count baselines stay pinned (CLAUDE.md
   rule 6 / Bennett-hjwp).
6. **Baselines:** pin `qrom=:qroam` Toffoli/CNOT counts for a few `(L,W,λ)` in
   `test_gate_count_regression.jl`; document the `:auto` default-vs-explicit
   delta in `BENCHMARKS.md` *without* touching the existing `:unary` baselines.
7. **Process:** 3+1 agent split (touches lowering cost model — CLAUDE.md rule 2).
   2 independent proposers for the `Swap`-network design (linear vs log depth,
   wire-allocation scheme), 1 implementer, orchestrator reviews ancilla hygiene.
8. **Defer:** the log-depth `Swap` (toggling trick) and the phase-incorrect
   `Swap` — both touch dirty/borrowed scratch or phase correctness; not needed
   for a first correct QROAM. File as follow-up beads.

**Caveat on §3's "no dirty machinery" claim.** The *clean* `SelectSwap` body
itself is dirty-free, BUT the paper's *ancilla-free* `Swap` sub-variants
(log-depth toggling, §2.3) borrow the swapped registers as dirty scratch. The
**linear-depth `Swap`** (step 4) does NOT — it is genuinely ancilla-free and
clean-compatible. So Target A with the linear-depth `Swap` needs zero
dirty-ancilla infrastructure; only the optional depth-optimised variants do.

### 6.2 Verdict

**This is the canonical, correct reference for ancilla-traded QROM in Bennett —
and the clean-ancilla `SelectSwap` (`O(N/λ + bλ)`, `λ* = √(N/b)`) is a faithful,
invariant-compatible target.** It is strictly preferable to the Motlagh-Pocrnic
2026 dirty construction *for Bennett*, because Bennett's ancillae are already
clean: the Motlagh-Pocrnic achievement (making dirty qubits as cheap as clean
ones) is moot when you have clean qubits, and its construction is strictly
costlier on clean ancillae than this paper's clean `SelectSwap`.

**However, do not schedule it yet.** Three gating facts:

1. **No customer.** Every table Bennett emits today (`L ≤ 16`, `:auto` tabulate
   envelope) is below the `L > 4W` crossover. Inside the current envelope the
   existing `2(L−1)` unary QROM is at or near optimal; QROAM's `bλ` overhead
   makes it *worse*. QROAM only earns its keep at `L ≳ 256, L ≫ W`.
2. **A prerequisite is missing.** QROAM is dead code until Bennett first grows a
   large-read-only-table path (lift the tabulate `L` cap, or a big-constant-array
   lowering). That predecessor work must land first.
3. **W-independence is sacrificed.** Bennett's `2(L−1)` Toffoli is W-independent;
   QROAM's is not. Acceptable — it is the nature of the ancilla-trade — but a
   real, documented behavioural change.

**Recommendation:** File a research bead recording that (a) the clean-ancilla
`SelectSwap`/QROAM of Low-Kliuchnikov-Schaeffer 2024 is the correct,
invariant-compatible reference for ancilla-traded QROM, with crossover `L > 4W`
and optimal `λ = √(L/W)`; (b) it is *blocked* on a large-table lowering path
that does not yet exist; (c) the implementation is a medium-difficulty,
3+1-process, ~300-LOC extension of `qrom.jl` once unblocked; (d) the
phase-incorrect `Swap` and the dirty Fig. `select`d construction are explicitly
out of scope for Bennett's classical-reversible, phase-blind, clean-ancilla
model. Do **not** schedule the implementation until a large-table use case is
real — building QROAM before then produces dead code that only adds a
W-dependence regression risk.

---

## 7. Verified claims (equation / table references)

- **Table `cost_comparison`:** the four data-lookup implementations and their
  exact qubit / T-count / T-depth columns (quoted §1.2).
- **`SelectSwap` T-count `4⌈N/λ⌉ + 8bλ`, qubits `bλ + 2⌈log₂N⌉`** — Table
  `cost_comparison`, row `SelSwap`. Minimised `O(√(Nb))` at `λ = O(√(N/b))`
  (Table caption + §"Data-lookup oracle" body).
- **Dirty modification:** Fig. `select`d, `8⌈N/λ⌉ + 32bλ` T, `b(λ+1) +
  2⌈log₂N⌉` qubits; "all but `b + ⌈log₂N⌉` of the qubits may be made dirty"
  (§"Data-lookup oracle", para. beginning "Importantly").
- **`λ ∈ [1,N]`**, integer; non-power-of-2 λ costs an extra `O(log N · log λ)`
  (§"Data-lookup oracle").
- **Lower bound** `q·Γ = Ω(bN − q²)`, SelectSwap optimal up to log factors for
  `λ = o(√(N/b))` (§"Lower bound").
- **Swap sub-variants** (Appendix `sec:swap`, Table `cost_comparison_swap`):
  linear `7n` T / depth `4n+4`; logarithmic `≤10n` T (naive `14n`); phase-
  incorrect `4n` T.
- **Berry et al. 2019 garbage uncomputation** `4⌈N/λ⌉ + 4λ` T, `b`-independent
  (§"Developments after 2018 release of preprint").
- "Our `SelectSwap` architecture of table lookup remains state-of-art" (ibid.).

### Ambiguities / things to be skeptical of

- **T vs Toffoli accounting.** The paper counts T gates with loose `O(·)`
  prefactors (`4N`, `8bλ`); Bennett counts Toffoli/CNOT exactly. The §4
  crossover uses the conversion `4 T ≈ 1 Toffoli` for AND-tree-style circuits;
  treat the crossover constant (`L > 4W`) as ±a small factor, not exact. The
  precise Bennett Toffoli count must come from the actual `emit_select_swap!`
  implementation, not from this paper's `O(·)` bounds.
- **CNOT cost is uncounted.** The paper folds CNOT into "Clifford" and does not
  give a closed form. Bennett counts all gates — the `O(bN)` / `O(bλ)` CNOT
  fan-out term will need to be measured empirically.
- **"`λ ∈ [1,N]`" vs power-of-2.** The clean `SelectSwap` allows any integer λ;
  the simplest Bennett implementation should restrict λ to powers of 2 (free
  address split, like `emit_qrom!`'s power-of-2 `L`) and document the deviation.
- **Phase-incorrect Swap is a trap for Bennett** — see §5 Target B: it would
  silently pass `verify_reversibility` while being quantum-incorrect, because
  Bennett's simulator is phase-blind. Flagged, not a defect of the paper.
- **The dirty-qubit headline does not transfer.** The paper's marquee result is
  about *dirty* qubits; Bennett has only clean ones. The transferable content is
  the *clean* `SelectSwap` (§2.2–2.4) — a genuine `O(√(Nb))` construction in its
  own right, and the part this brief recommends.
