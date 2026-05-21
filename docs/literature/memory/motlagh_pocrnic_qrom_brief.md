# Brief: Motlagh & Pocrnic 2026 — Halving the Cost of QROM

## Header

- **Title:** Halving the cost of QROM
- **Authors:** Danial Motlagh, Matthew Pocrnic (both Xanadu, Toronto)
- **arXiv ID:** arXiv:2605.20334 (2026)
- **Source status:** Full LaTeX source available locally at
  `docs/literature/memory/motlagh-pocrnic-2026-tex/main.tex` (32 KB, 327 lines)
  plus `bib.bib` and 4 `.tikz` figure files. The compiled PDF is **not** in the
  collection — only the two `advantage_factor_dirty_{256,1024}.pdf` plot figures.
- **Category:** MEMORY / QROM (table lookup; reversible read of classical data).
- **One-line key idea:** Replace the "SelectSwap" multiplexed-swap step in
  dirty-ancilla QROM with a direct multiplexed "SelectCopy", then treat a
  *b*-bit lookup as α back-to-back (*b*/α)-bit lookups so the dominant
  Toffoli prefactor drops from 2 to ≈ 1, halving the cost of dirty-ancilla
  QROM and matching clean-ancilla QROM.

---

## 1. Background

### 1.1 What QROM is

**QROM (Quantum Read-Only Memory)**, a.k.a. coherent *table lookup*, implements
the transformation (paper Eq. 1, `eq:data_load`):

    Σ_x ψ_x |x⟩|0⟩  →  Σ_x ψ_x |x⟩|f(x)⟩

Given a (log₂N)-qubit *address register* in superposition, it loads a
classical bitstring `f(x)` of length `b` for each of the `N` computational
basis states `|x⟩`. `f` is computed classically ahead of time; QROM is the
quantum circuit that materialises the lookup table coherently. QROM is the
non-Clifford workhorse of Hamiltonian simulation, state preparation, unitary
synthesis, and differential/linear-system solvers; the paper claims it
"constitutes the majority share of algorithmic overheads in most practical
applications of quantum computers."

**Cost-history ladder (paper §1, Introduction):**

| Method | Toffoli cost | Ancilla |
|---|---|---|
| Naive: N back-to-back (log₂N)-controlled NOTs | `N(log₂N − 1)` | 0 |
| **Unary iteration** (Babbush-Gidney 2018) | `N` | `log₂N` clean |
| **SelectSwap / QROAM, clean ancilla** (Low-Kliuchnikov-Schaeffer 2024) | `N/λ + bλ` | `b(λ−1)` clean |
| **SelectSwap, dirty ancilla** (Low et al. 2024) | `2N/λ + 4bλ` | `bλ` dirty |
| **SelectSwap, dirty, refined** (Berry et al. 2019) — *prior SOTA* | `2N/λ + 4b(λ−1)` | `b(λ−1)` dirty |
| **This paper, SelectCopy** (α=1) | `2N/λ + 2b(λ−1) + 2λ−6` | `b(λ−1)` dirty |
| **This paper, sequential bit-packets** (α=b) | `(1+1/b)·N/λ + 2(b+1)(bλ−2)` | `bλ − b/α` dirty |

The paper stresses (§1): "to the best of our knowledge, no improvements have
been found for this key subroutine for over half a decade" — Berry et al. 2019
had been SOTA for seven years.

### 1.2 SelectSwap / QROAM

The **SelectSwap** (also called **QROAM**, QROM-and-merge / "select-swap")
trick, introduced by Low-Kliuchnikov-Schaeffer, splits the (log₂N)-qubit
address into two sub-registers `|q⟩` (size `log₂(N/λ)`) and `|r⟩` (size
`log₂λ`), so `x = q·λ + r` (paper Eq. 2, `eq:data_load_2`):

    Σ_q Σ_r ψ_{q,r} |q⟩|r⟩|0⟩  →  Σ_q Σ_r ψ_{q,r} |q⟩|r⟩|f(q,r)⟩

For each `|q⟩` you **Select** (load) *all* λ values `f(q,0)…f(q,λ−1)` into a
`bλ`-qubit ancilla register (one unary iteration over `|q⟩`, cost ≈ N/λ
Toffoli), then **Swap** the correct `b`-qubit block — chosen by `|r⟩` — into
the output register (cost ≈ `bλ`). This trades ancilla qubits for a √N-style
reduction of the Toffoli count: the optimal λ ≈ √(N/b) gives O(√(Nb)) Toffoli.

### 1.3 Babbush-Gidney 2018 baseline — and Bennett.jl's current implementation

Bennett.jl's `src/qrom.jl` implements the **Babbush-Gidney 2018 unary-iteration
QROM** (arXiv:1805.03662v2, §III.A unary iteration, §III.C Fig. 10). The header
comment states the cost as **`2(L−1)` Toffoli + O(L·W) CNOT, T-count `4(L−1)`,
independent of the word width W**, where `L` is the table length (paper's `N`)
and `W` is the word width (paper's `b`). Construction: a complete binary AND
tree over `log₂L` index bits produces L one-hot leaf flags; exactly one fires;
data-dependent CNOT fan-out copies the selected word into the output; the AND
tree is reversed to uncompute all flags (self-clean — a compute/uncompute pair
straddling the fan-out).

This is the **λ = 1** point of the cost ladder — no SelectSwap, no ancilla
register beyond the `log₂L` AND-tree flags. Bennett.jl does **not** currently
implement any SelectSwap/QROAM variant: its Toffoli count is `2(L−1)`, linear
in L and (notably) **independent of W**.

### 1.4 The dirty-ancilla model

A **clean ancilla** starts in `|0⟩` and must be returned to `|0⟩`. A **dirty
ancilla** starts in an arbitrary unknown state `|φ⟩` (it is borrowed — qubits
"in use" elsewhere in the algorithm) and must be returned to *exactly that same*
`|φ⟩`. Dirty ancillae are "free" in the sense that an algorithm usually has many
qubits idle at any moment; the cost is the factor-of-2 Toffoli overhead.

The dirty-ancilla QROM works because XOR is self-inverse: for any state `|φ⟩`,
`|φ ⊕ φ ⊕ f(q,r)⟩ = |f(q,r)⟩` (paper §2.1). The construction loads `f` into the
dirty register *twice* with the same `|q⟩`-controlled circuit — the first load
mixes `f` into `φ`, the second load cancels `φ` back out — and in between
extracts the answer into a clean output. This double-load is the source of the
factor-2 prefactor `2N/λ` in all dirty-ancilla QROM costs.

---

## 2. The Algorithms

The paper assumes `N`, `b`, `λ` are powers of 2 in the main text; Appendix A
(`sec:non_power`) lifts this.

**Symbol glossary** (used uniformly below):

- `N` — number of table entries (Bennett's `L`).
- `b` — bitstring/word length loaded per entry (Bennett's `W`).
- `λ` — the SelectSwap/SelectCopy "depth": the address splits into `|q⟩`
  (`N/λ` values) and `|r⟩` (`λ` values), `x = q·λ + r`. Constrained to a
  power of 2, `1 < λ < N`.
- `φ_j` (or `φ_l`) — the unknown initial state of the `j`-th / `l`-th
  `b`-qubit dirty register.
- `α` — number of sequential "bit-packets": a `b`-bit QROM is decomposed into
  α back-to-back (`b/α`)-bit QROMs. `α=1` recovers SelectCopy; `α=b` gives the
  ≈50% reduction.
- `μ` — bits loaded per iteration (Appendix A), `α = ⌈b/μ⌉`. With powers of 2,
  `μ = b/α`.
- `m` — number of genuine back-to-back QROMs in the Sequential-QROM result.
- `Sel`, `Sel_j` — the multiplexed *load* operation controlled on `|q⟩`.
- `Copy` — the multiplexed *copy* operation controlled on `|r⟩`.

### 2.1 Optimization 1 — SelectCopy replaces SelectSwap (§2.2, `sec:select_copy`)

**The prior dirty construction** (Berry et al. 2019, paper §2.1, 8 steps): for
each `|q⟩`, (1) controlled-swap the `r`-th dirty register into the 0-th based on
`|r⟩`; (2) copy the 0-th register into a clean register; (3) swap back;
(4) `|q⟩`-controlled load all `f(q,r)` into the dirty registers; (5)–(7) repeat
the swap-copy-swap; (8) `|q⟩`-controlled unload. Cost `2N/λ + 4b(λ−1)`,
`b(λ−1)` dirty qubits.

**Key realisation:** "swap the `r`-th register into the 0-th, copy the 0-th into
a clean register, swap back" is *equivalent to* a single **multiplexed copy**
of the `r`-th register directly into the clean register, controlled on `|r⟩`
(paper Eq. 3):

    Copy |q⟩|r⟩|0⟩ ⊗_j |φ_j⟩  →  |q⟩|r⟩|0 ⊕ φ_r⟩ ⊗_j |φ_j⟩
                               =  |q⟩|r⟩|φ_r⟩ ⊗_j |φ_j⟩

A direct multiplexed copy has **half the Toffoli cost of two multiplexed swaps**
and "requires no CNOTs (of which the previous approach requires `4bλ`)". This
alone gives `2N/λ + 2bλ + 2λ − 6`. The extra `2λ−6` comes from doing unary
iteration over `|r⟩` for each multiplexed copy, cost `λ−3` per copy, two copies.

**Refinement to drop `bλ → b(λ−1)`:** instead of iterating `r = 0…λ−1` in the
copy, iterate `r = 1…λ−1` (skip `r=0`). Then modify the first load so it loads
`f(q,0)` *directly into the clean register* and `f(q,r) ⊕ f(q,0)` into the
`r`-th dirty register for `r = 1…λ−1`; the second load only loads
`f(q,r) ⊕ f(q,0)` into the `r`-th dirty register. This yields the §2.2 final
cost:

> **`2N/λ + 2b(λ−1) + 2λ − 6` Toffoli, `b(λ−1)` dirty qubits.**

The construction is drawn in `figures/qroam.tikz` (Fig. 2b): `Sel_1` (a "big
gate" controlled on `|q⟩`) → `Copy` (controlled on `|r⟩`) → `Sel_2` →
`Copy`. `Sel_1` loads `f(q,0)` into the clean register and the XOR-corrections
into the dirty registers; `Sel_2` is "similar but only goes over `r=1…λ−1`".

**Bonus (§2.2 final paragraph):** the same idea cuts the cost of *measurement-
based uncomputation* of a table lookup from `2N/λ' + 4λ'` (Berry et al. 2019)
to **`2N/λ' + 2λ' − 6`** Toffoli, by treating uncomputation as a `b=1` QROM
that loads `1` for every address needing a phase correction and replacing the
`|r⟩`-controlled copy of the `r`-th dirty qubit with a `|r⟩`-controlled
Pauli-Z.

### 2.2 Sequential QROMs (§2.3)

For `m` *genuine* back-to-back QROMs (common in THC-factorised electronic-
structure block encodings), the un-load step for QROM `j` can be **fused** with
the load step of QROM `j+1`: instead of unloading `f(q,r)_{j−1}` and then
loading `f(q,r)_j`, load `f(q,r)_{j−1} ⊕ f(q,r)_j` in one `Sel`. Only one
final un-load is needed, regardless of `m`. So the number of loads — the
coefficient of `N/λ` — is `m+1`, not `2m`.

A second, analogous fusion applies to the second multiplexed `Copy` (the
"fix-up" `|φ_r ⊕ f(q,r)⟩ → |f(q,r)⟩`): cache `|φ_r⟩` once at the start with one
multiplexed copy into an extra `b`-qubit ancilla, then reuse it via CNOTs only.
Total Toffoli cost for `m` sequential QROMs:

> `(m+1)·N/λ + (m+2)·(b(λ−1) + λ−3)`

If the sequential QROMs write to a *fresh clean register* each time (rather than
rewriting the previous output — which is the case for the next section), the
initial caching is unneeded and the fix-ups are all done once at the end,
giving the headline Sequential-QROM result (paper Eq. `eq:sequential`):

> **`(m+1)·(N/λ + b(λ−1) + λ−3)` Toffoli.**

### 2.3 Optimization 2 — Halving via sequential bit-packets (§2.4, `sec:halving_qrom`)

The core trick. In the qubit-constrained regime the dominant term is `2N/λ`.
But the Sequential-QROM prefactor is `m+1`, not `2m`. So: **treat a single
`b`-bit QROM as `α` sequential `(b/α)`-bit QROMs.** Because each sub-QROM loads
only `b/α` bits, the *same* dirty-qubit budget (≈ `bλ`) now allows a SelectCopy
depth of `αλ` instead of `λ`. Substituting `m → α`, `b → b/α`, `λ → αλ` into
Eq. `eq:sequential` gives the **parametric-family cost** (paper Eq.
`eq:bit_batch_load`):

> **`(1 + 1/α)·N/λ + (b + b/α)·(αλ − 1) + (α+1)·(αλ − 3)` Toffoli,
> using `bλ − b/α` dirty ancillae.**

- **`α = 1`** recovers the §2.2 SelectCopy cost.
- **`α = b`** (one bit per packet) gives `(1 + 1/b)·N/λ + 2(b+1)(bλ − 2)`.
  When `N ≫ b²λ²` this is `≈ (1 + 1/b)·N/λ` — a **≈50% reduction** vs the
  prior `2N/λ`, "effectively matching the performance of clean-qubit QROM
  using dirty qubits."

`α` is a tunable knob: small `α` when dirty qubits are scarce, large `α` when
plentiful. The paper plots the advantage factor (Fig. 1) and notes the optimal
`α` is chosen per `(N, b, dirty-budget)`.

### 2.4 Non-power-of-2 generalisation (Appendix A, Theorem A.1 / `thm:mu_bit_qrom`)

> **Theorem (`thm:mu_bit_qrom`).** Given `f : Z_N → Z_2^b` and `λ` a power of 2
> with `1 < λ < N`, the transformation of Eq. 1 can be built with
>
>   `(⌈b/μ⌉+1)·(⌈N/λ⌉ + λ − 3) + (λ−1)·(μ(⌊b/μ⌋+1) + b mod μ)`
>
> Toffoli gates, `μ(λ−1)` dirty ancilla, `max{⌈log(N/λ)⌉, log λ}` clean
> ancilla, and `b` clean output qubits.

Here `μ` bits are loaded per iteration, `α = ⌈b/μ⌉` iterations; the last
iteration loads `b mod μ` bits. With all parameters powers of 2 and `α = b/μ`
this reduces exactly to Eq. `eq:bit_batch_load`. The proof gives the unary-
iteration sub-costs from Babbush-Gidney 2018: `⌈N/λ⌉ − 1` for the `|q⟩`
iteration, `λ − 2` for the `|r⟩` iteration.

---

## 3. Circuit Construction (implementer's view)

### 3.1 Address split

Split the `log₂N`-qubit address into `|q⟩` (`log₂(N/λ)` qubits) and `|r⟩`
(`log₂λ` qubits), `x = q·λ + r`.

### 3.2 The `Sel` (load) primitive

`Sel_j` is a multiplexed load controlled on `|q⟩`: a unary iteration over
`|q⟩` (Babbush-Gidney AND tree, `⌈N/λ⌉ − 1` Toffoli) with data-dependent CNOT
fan-out. Critically, `Sel_1` loads **XOR-differenced data**: `f(q,0)` straight
into the clean output, and `c_{q·λ+r,j} = f_{q·λ+r,j} ⊕ f_{q·λ,j}` into the
`r`-th dirty register (the XOR against the 0-th element). `Sel_2 … Sel_α` and
`Sel†` (the restore-load) load further XOR-differences as derived in the
Appendix-A step-by-step (Eqs. around `xrightarrow{Sel_1}` … `Sel_{⌊b/μ⌋}`).

### 3.3 The `Copy` (SelectCopy) primitive — *the new gate*

`Copy` is a **multiplexed copy controlled on `|r⟩`**: it copies the contents of
the `r`-th `b`-qubit dirty register into a target register, conditioned on the
`|r⟩` value. Concretely (paper Eq. 3, Appendix A): unary-iterate over `|r⟩`
(`λ−2` Toffoli plus per-leaf temp-ANDs), and for each `|r⟩` value, controlled on
that leaf flag, CNOT every qubit of dirty register `r` into the corresponding
output qubit. The paper notes `Copy` "requires no CNOTs" *of the SelectSwap
kind* — meaning no `4bλ` swap-CNOTs; it still uses CNOT fan-out internally, but
the **Toffoli** cost is `λ−3` per copy for the `|r⟩` unary iteration plus
`(λ−1)·μ` for the temp-AND-controlled copies. The paper explicitly says: "in
principle `Copy` operations need not be controlled since the Restore operation
serves as the adjoint."

### 3.4 The `Restore` operation (Appendix B, `sec:restore`)

After all `α` iterations, each output qubit holds `f_{x,j} ⊕ φ_{r, j mod μ}` —
the dirty-register state `φ` repeats with period `μ` across the `b` output
bits. `Restore` cleans this up:

1. `Sel†` — un-load: a `|q⟩`-controlled load that returns the dirty registers
   to their original `⊗_l |φ_l⟩` state.
2. A final `Copy`: for each dirty-qubit state `φ_{r,[0,μ-1]}`, iterate over
   `|r⟩`, initialise one temp-AND per `(unary-iteration outcome, dirty-qubit)`
   pair, and — controlled on that temp-AND — CNOT into *every* output location
   where that particular `φ` error occurs. The error pattern is deterministic
   from the circuit construction, so the CNOT targets are known at compile time.
   This final `Copy` has the same Toffoli cost as a prior `Copy` (`(λ−1)·μ`).

`figures/restore.tikz` shows a worked 5-bit / `μ=2` example: pre-restore the
output is `|f_{x,0}⊕φ_{r,0}⟩|f_{x,1}⊕φ_{r,1}⟩|f_{x,2}⊕φ_{r,0}⟩
|f_{x,3}⊕φ_{r,1}⟩|f_{x,4}⊕φ_{r,0}⟩` — `φ_{r,0}` on bits 0,2,4 and `φ_{r,1}` on
bits 1,3 — and the restore CNOTs each `φ` out of its three / two locations.

### 3.5 Overall structure (Fig. 3, `iterative_qrom.tikz`, for α = b)

`Sel_1 → Copy → Sel_2 → Copy → … → Sel_b → Copy → [Restore: Sel† → Copy]`.
Each `Sel_j`/`Copy` pair loads/copies one more bit-packet into the output
register; the boxed `Restore` at the end runs `Sel†` then the final cleanup
`Copy`. Dirty registers and output registers are single qubits per wire in the
`α=b` picture.

---

## 4. Verified Claims (exact quotes / equation numbers)

- **Abstract:** "given access to `bλ` dirty qubits, one can reduce the Toffoli
  cost of QROM to `2N/λ + 4b(λ−1)`" → reduced "to `2N/λ + 2b(λ−1) + 2λ−6` …
  by replacing the 'SelectSwap' architecture with 'SelectCopy'" → qubit-
  constrained regime "reduce it to `~(1+1/b)·N/λ`, cutting the cost by
  approximately 50%".
- **§1:** prior SOTA = Berry et al. 2019, `2N/λ + 4b(λ−1)` Toffoli, `b(λ−1)`
  dirty — "remained the state-of-the-art for the past seven years."
- **Eq. 1 (`eq:data_load`):** the QROM transformation.
- **Eq. 2 (`eq:data_load_2`):** the `x = q·λ + r` address split.
- **Eq. 3:** the `Copy` definition `Copy|q⟩|r⟩|0⟩⊗_j|φ_j⟩ → |q⟩|r⟩|φ_r⟩⊗_j|φ_j⟩`.
- **§2.2:** "`2N/λ + 2b(λ−1) + 2λ−6` … dirty qubit count `b(λ−1)`"; the
  `2λ−6` is "from having to do unary iteration over the `|r⟩` register for each
  multiplexed copy which has cost `λ−3`."
- **§2.3, Eq. `eq:sequential`:** `m` sequential QROMs cost
  `(m+1)·(N/λ + b(λ−1) + λ−3)`.
- **§2.4, Eq. `eq:bit_batch_load`:** parametric family
  `(1+1/α)·N/λ + (b+b/α)(αλ−1) + (α+1)(αλ−3)`, `bλ − b/α` dirty ancillae.
  `α=b` ⇒ `(1+1/b)·N/λ + 2(b+1)(bλ−2)`; `N ≫ b²λ²` ⇒ `~(1+1/b)·N/λ`.
- **Theorem A.1 (`thm:mu_bit_qrom`):** non-power-of-2 cost (quoted §2.4 above).
- The paper states the construction "is now available in PennyLane."

### Ambiguities / things to be skeptical of

- **CNOT cost is not tracked carefully.** The paper counts only Toffoli/T gates
  (the fault-tolerant cost driver) and is loose about CNOTs — it says `Copy`
  "requires no CNOTs" then immediately uses CNOT fan-out in the Restore
  description. For Bennett.jl, which counts *all* gates, the CNOT term matters
  and is **not** given by a clean closed form here.
- **`λ−3` vs `λ−2` for `|r⟩` unary iteration.** §2.2 says the per-copy cost is
  `λ−3`; Appendix A's proof says the `|r⟩` unary iteration is `λ−2`. The
  discrepancy is the controlled-vs-uncontrolled distinction ("in principle
  `Copy` operations need not be controlled"). Treat the exact subleading
  constants as ±1 fuzzy.
- **`λ` must be a power of 2.** Stated throughout; the Conclusion flags lifting
  this (via integer division) as future work. The non-power-of-2 Appendix only
  lifts `b`, `μ`, `N` — not `λ`.
- **"Effectively matching clean-qubit QROM"** is an asymptotic claim
  (`N ≫ b²λ²`); the subleading `2(b+1)(bλ−2)` term is *quadratic in b* and not
  negligible at small N.

---

## 5. Relevance to Bennett.jl — Implementation Assessment

### 5.1 Does this give an improved subroutine vs Bennett's current QROM?

**Not for Bennett.jl's current operating regime — and possibly never, given
Bennett's correctness invariant.** Here is the careful comparison.

Bennett.jl (`src/qrom.jl`) implements **Babbush-Gidney unary iteration at
λ = 1**: `2(L−1)` Toffoli, `O(L·W)` CNOT, `log₂L` *clean* ancillae,
**W-independent Toffoli count**. The Motlagh-Pocrnic paper does **not** improve
the λ=1 unary-iteration point — it improves the **SelectSwap/QROAM (λ > 1)**
regime, which Bennett.jl does not implement at all. The paper's whole premise is
"given access to `b·λ` dirty qubits"; with `λ = 1` there are no SelectSwap
ancillae and the construction degenerates to plain unary iteration.

So the honest framing is: the paper would let Bennett.jl add a **new, faster
QROAM strategy** that beats its current `2(L−1)` Toffoli — but only in a regime
Bennett does not currently target:

- **When it helps:** large tables (`L = N` big), and a generous ancilla budget
  (`≈ b·λ` extra wires). Then QROAM's `≈ 2N/λ` (or the paper's `≈ (1+1/b)N/λ`)
  beats unary iteration's `2(L−1) = 2N` once `λ > 1`. Optimal λ ≈ √(N/b) gives
  O(√(Nb)) Toffoli vs O(N).
- **When it does not:** small tables. Bennett's `tabulate.jl` caps QROM at
  `L ≤ 2^16` and `:auto` only picks tabulate for `L ≤ 16` (total input width
  ≤ 4). At `L = 16` the current QROM is `2(L−1) = 30` Toffoli — already tiny.
  The paper's machinery (address split, dirty-register management, SelectCopy,
  Restore) carries a `(b+1)(bλ−2)`-style subleading overhead that *dominates*
  at small L. **For every table Bennett currently emits, the existing
  `2(L−1)` QROM is at or near optimal and the paper offers no win.**

**Verdict:** the paper is an improvement *to a strategy Bennett has not built*.
It is interesting only if Bennett later wants large read-only tables (big LLVM
global constant arrays, large S-boxes, LUT-heavy code) — and even then the
clean-ancilla QROAM (`N/λ + bλ`, Low et al. 2024) would be the simpler first
target.

### 5.2 Does the improvement preserve W-independence?

**No — it fundamentally breaks it.** Bennett's current QROM Toffoli count
`2(L−1)` is independent of `W` (= the paper's `b`): the word width only affects
the CNOT fan-out. *Every* SelectSwap/QROAM cost — including this paper's —
has `b` (=W) explicitly in the Toffoli count: `2N/λ + 2b(λ−1) + 2λ−6`,
`(1+1/α)N/λ + (b+b/α)(αλ−1) + …`. The `Copy` primitive moves `b`-qubit blocks
under `|r⟩` control, and the per-copy Toffoli cost scales with `b`. So adopting
this paper would make Bennett's QROM Toffoli count **W-dependent**. That is the
intrinsic price of the ancilla-for-Toffoli trade: it is not a regression, it is
the nature of QROAM. The W-independence of the current implementation is a
*feature of λ=1 unary iteration specifically*.

### 5.3 The dirty-ancilla requirement vs Bennett's correctness invariant — CRITICAL

**This is the deciding obstacle.** Bennett.jl's non-negotiable correctness
invariant (CLAUDE.md rules 1, 4; `verify_reversibility`) is that **every
ancilla starts at zero and returns to zero**. The `WireAllocator` bump/free-list
hands out zeroed slots; `simulate` asserts ancilla-zero at the end. Bennett.jl
has **no notion of a dirty (borrowed, arbitrary-state) ancilla**. Every wire is
either an input, an output, or a clean ancilla.

The paper's headline results — the `2N/λ + 2b(λ−1) + 2λ−6` SelectCopy cost and
the `≈(1+1/b)N/λ` halving — are **specifically dirty-ancilla constructions**.
The factor-2 prefactor `2N/λ` exists *because* the registers are dirty (you
load `f` twice to cancel the unknown `φ`). The paper itself notes (§1) that the
*clean*-ancilla QROAM of Low et al. 2024 already costs `N/λ + bλ` — i.e. the
paper's achievement is to make *dirty* ancillae perform like *clean* ones.

For Bennett.jl, which only has clean ancillae, **the right baseline is the
clean-ancilla QROAM `N/λ + bλ`, not this paper.** The Motlagh-Pocrnic
construction is **not directly compatible** with Bennett's invariant: it relies
on `|φ⟩` being an *external borrowed* qubit. Two ways to reconcile:

1. **Allocate the "dirty" registers as clean ancillae** (φ = 0). Then
   `φ ⊕ φ ⊕ f = f` still holds trivially, the Restore step still zeroes them,
   and the invariant is satisfied. **But** if φ is known to be 0 you no longer
   need the double-load — you would just use the clean-ancilla QROAM directly,
   which is *cheaper* (`N/λ + bλ`). Running the dirty construction on clean
   qubits gives you the dirty cost (`2N/λ`-ish) for no reason.
2. **Genuinely borrow live wires as dirty ancillae.** This would require a new
   capability in `WireAllocator`: a "borrow" pool of wires currently holding
   live intermediate values, with a contract that the QROM circuit returns them
   bit-exact. This is a *significant* new concept — it interacts with the
   Bennett forward/uncompute structure (`bennett_transform.jl`), wire-partition
   validation (`gates.jl`, Bennett-6azb), and `verify_reversibility`. The
   "returns to zero" assertion would have to become "returns to its
   pre-circuit value" for borrowed wires.

**Bottom line:** if Bennett wants ancilla-traded QROM, it should implement the
*clean-ancilla* QROAM (Low-Kliuchnikov-Schaeffer 2024, `N/λ + bλ`). This paper's
specific contribution — making dirty ancillae as cheap as clean ones — is
**moot for Bennett**, because Bennett's ancillae are *already* clean. The
SelectCopy idea (§2.1) and the Restore mechanism are still instructive, but the
"halving" headline does not transfer: you cannot halve below the clean-ancilla
baseline that Bennett would start from.

### 5.4 New primitives Bennett would need

To implement *any* QROAM strategy (clean or dirty):

- **Address split logic:** partition the `idx_wires` into `|q⟩` and `|r⟩`
  sub-registers; choose `λ` (power of 2) from a cost model.
- **`Sel` (multiplexed load) gate:** Bennett already has the building block —
  `_qrom_tree!` is exactly a `|q⟩`-style unary iteration with CNOT fan-out.
  A `Sel` is `_qrom_tree!` over `N/λ` entries, fanning into a `bλ`-qubit
  register, with **XOR-differenced data** (`f(q,r) ⊕ f(q,0)`) baked into the
  constant table — a straightforward modification of the data array.
- **`Copy` (SelectCopy) gate:** genuinely new. A multiplexed copy controlled on
  `|r⟩`: unary-iterate `|r⟩` (reuse `_qrom_tree!`'s AND-tree to make λ leaf
  flags) and, per leaf flag, emit `b` Toffoli gates `Toffoli(leaf_flag,
  dirty_reg[r][j], out[j])` for each bit `j`. This is a new
  `emit_selectcopy!` helper. It is *not* a single gate type — it decomposes
  into existing `ToffoliGate`/`CNOTGate`, so no new gate primitive is needed,
  only a new emission routine.
- **`Restore` routine:** the deterministic XOR-error-cleanup of §3.4 — emit
  temp-AND + CNOT fan-out to known compile-time output positions.
- **(Only for the dirty variant) a dirty-ancilla / wire-borrow facility** in
  `WireAllocator` + a relaxed `verify_reversibility` — see §5.3. This is the
  expensive, invasive part and the reason the dirty construction is a poor fit.

Note: the `Copy`/`Sel`/`Restore` operations all decompose to NOT/CNOT/Toffoli,
so they are *expressible* in Bennett's gate set — there is no fundamental gate
obstruction, only the dirty-ancilla model obstruction.

### 5.5 Implementation difficulty & placement

- **Clean-ancilla QROAM (Low et al. 2024, `N/λ + bλ`)** — the *recommended*
  path if large read-only tables ever matter. Medium difficulty: extend
  `qrom.jl` with `emit_qroam!` (address split + `Sel` + `Copy`) and a cost
  model picking λ vs the plain `emit_qrom!`. New dispatch arm in
  `_emit_qrom_from_gep!` / a `qrom=:unary | :qroam | :auto` kwarg analogous to
  `add=:ripple | :qcla`. Estimate: ~1 new file or a ~300-LOC extension of
  `qrom.jl`, plus regression baselines in `test_gate_count_regression.jl`. A
  3+1 agent split is warranted (it touches the lowering cost model).
- **The Motlagh-Pocrnic dirty construction itself** — **not recommended** for
  Bennett. It would additionally require the dirty-ancilla/wire-borrow
  infrastructure (§5.3), which touches `WireAllocator`, `bennett_transform.jl`,
  `gates.jl` wire-partition validation, and `simulator.jl`'s ancilla-zero
  assertion — a core-pipeline change requiring the full 3+1 process — for a
  result that, on clean ancillae, is *strictly worse* than the clean-ancilla
  QROAM Bennett would build anyway.
- **Quick win, low risk:** the **SelectCopy idea in isolation** (§2.1) — "a
  controlled-copy of register `r` is half the cost of two controlled-swaps" —
  is a general reversible-circuit lesson worth noting wherever Bennett emits
  multiplexed swaps (`shadow_memory.jl`, `softmem.jl`). No QROM rework needed;
  just audit existing swap-based MUX patterns for this 2× saving.

**Recommendation:** File a research bead noting that (a) QROM ancilla-trading is
viable future work *if* large read-only tables become a target, (b) the correct
reference for Bennett is the *clean-ancilla* QROAM (`N/λ + bλ`), not this
dirty-ancilla paper, and (c) this paper is nonetheless the SOTA survey of the
QROAM design space and the `SelectCopy` and `Restore` mechanisms are reusable.
Do **not** schedule the dirty-ancilla construction: its entire value
proposition collapses against Bennett's clean-ancilla invariant.
