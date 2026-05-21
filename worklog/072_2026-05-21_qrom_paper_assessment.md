# Bennett.jl Work Log — Chunk 072

> Sharded chunk. Highest `NNN_` = most recent. Prepend new sessions to the top.
> Started 2026-05-21 (chunk 071 reached 290 lines).

---

## Session log — 2026-05-21 — QROM optimization paper assessment (Motlagh-Pocrnic + Low-Kliuchnikov-Schaeffer)

**Trigger:** user flagged a newly-landed paper, "Halving the cost of QROM"
(Motlagh & Pocrnic, arXiv:2605.20334, 2026), as potentially important for
Bennett. Task: download source, file it sensibly, assess whether it supplies an
improved subroutine, and — if useful on benchmarks — add dispatch for it.

**No code changed this session.** This is a research step per CLAUDE.md §9/§11.
Outcome: two papers assessed, two literature briefs written, one research bead
filed (`Bennett-p4ch`). Implementation deliberately deferred.

### What landed in the repo

- `docs/literature/memory/motlagh-pocrnic-2026-halving-qrom-eprint.tar.gz` + extracted `motlagh-pocrnic-2026-tex/`
- `docs/literature/memory/motlagh_pocrnic_qrom_brief.md` — full technical brief
- `docs/literature/memory/low-kliuchnikov-schaeffer-2024-select-swap-eprint.tar.gz` + extracted `low-kliuchnikov-schaeffer-2024-tex/`
- `docs/literature/memory/low_kliuchnikov_schaeffer_select_swap_brief.md` — full technical brief

### Finding 1 — Motlagh-Pocrnic 2026 "Halving the cost of QROM": NOT APPLICABLE

The paper optimizes the **SelectSwap/QROAM (λ>1)** regime. Bennett's `src/qrom.jl`
is the **λ=1 point** (Babbush-Gidney unary iteration, `2(L-1)` Toffoli,
W-independent) — the paper never touches λ=1.

Decisive blocker: the paper's headline ~50% halving is **built on dirty
ancillae** — registers hold an unknown `|φ⟩`, so `f` is loaded twice to cancel
it. **Bennett has no dirty-ancilla model.** Every ancilla starts and ends at
zero (`WireAllocator.free!` requires zero state; `_validate_self_reversing!` in
`bennett_transform.jl` enforces it at runtime). The paper itself notes the
*clean*-ancilla QROAM is already cheaper than its improved dirty cost — so the
paper's contribution (making dirty as cheap as clean) is moot for a compiler
whose ancillae are already clean. Implementing it literally would mean building
a dirty-ancilla borrowing system to land a circuit *strictly worse* than
Bennett's current QROM. Rejected per CLAUDE.md §10 (skepticism).

Reusable threads: the **SelectCopy** insight (a controlled-copy is half the cost
of two controlled-swaps) and the **Restore** XOR-cleanup mechanism.

### Finding 2 — Low-Kliuchnikov-Schaeffer 2024 (arXiv:1812.00954, Quantum 8,1375): the right reference, but DEFER

This is the **origin paper of SelectSwap/QROAM**. It has a **clean-ancilla
SelectSwap variant** (cost ≈ `2N/λ + 2Wλ` Toffoli; `bW+2⌈log₂N⌉` qubits) that
IS compatible with Bennett's ancilla-zero invariant. This — not the
Motlagh-Pocrnic dirty construction — is the correct algorithm if Bennett ever
wants ancilla-traded QROM.

But **do not schedule it yet**:

- **Crossover: QROAM beats unary iteration only when `L > ~4W`** (optimal
  `λ* = √(L/W)`, cost `≈ 4√(LW)`). At `L=16` (Bennett's entire `:auto` tabulate
  envelope) unary's `2(L-1)=30` Toffoli beats QROAM for any `W≥8`.
- **Every table Bennett emits today is below the crossover.** `tabulate.jl`
  `:auto` picks QROM only for L≤16 entries; the hard cap is L≤2^16. QROAM is
  dead code until Bennett emits `L>4W` tables — the tabulate L-cap must first be
  lifted (or a large-constant-array lowering path added). **This is a blocking
  prerequisite.**
- **W-independence is lost** — every QROAM cost has W in it; unary's `2(L-1)`
  does not. A genuine tradeoff, not a regression.
- The paper's phase-incorrect log-depth Swap is **unsafe for Bennett**: its ±1
  phase fault is invisible to Bennett's phase-blind simulator, so it would pass
  `verify_reversibility` while being quantum-incorrect. If implemented, use the
  linear-depth Swap only.

### Bead filed

- **`Bennett-p4ch`** (P3, feature, open) — "QROAM SelectSwap for read-only QROM
  tables (clean-ancilla, Low-Kliuchnikov-Schaeffer 2024)". Captures both
  assessments, the `L>4W` crossover, the `λ*=√(L/W)` optimum, the blocking
  tabulate-cap prerequisite, and the ~300-LOC implementation plan (generalise
  `emit_qrom!` Select, add `emit_select_swap!`, add `qrom=:unary|:select_swap|:auto`
  dispatch, 3+1 protocol). Defer until a real `L>4W` workload exists.
- Related existing bead **`Bennett-6c6f`** (P3, open) — QROAM for runtime-indexed
  *mutable* memory (`O(N·W)→O(√(N·W))`, ~32× at N=W=64). LKS 2024 is also the
  right algorithm reference there; that bead is blocked on the IRSwap bead
  `Bennett-8guh`.

### Take-home

A freshly-landed paper is not automatically a win. "Halving the cost of QROM"
optimizes a regime (dirty-ancilla QROAM) Bennett structurally cannot use. The
*actual* improved subroutine — clean-ancilla SelectSwap — comes from the 2018/24
origin paper, and even that only helps for large tables Bennett does not
currently emit. Both findings recorded; implementation gated on a real use case.
