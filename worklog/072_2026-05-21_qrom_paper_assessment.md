# Bennett.jl Work Log — Chunk 072

> Sharded chunk. Highest `NNN_` = most recent. Prepend new sessions to the top.
> Started 2026-05-21 (chunk 071 reached 290 lines).

---

## Session log — 2026-05-21 — Bennett-8su4 close + heap-memory de-risking spike (orchestrated)

**Mode:** orchestrated effort — user asked for the "next most consequential
work" delegated to opus subagents, serial, one at a time; sonnet for
reading/grunt work. Orchestrator picked **Phase 1 of the heap-memory unblock**:
land the one tractable fix (`Bennett-8su4`), then run an empirical de-risking
spike to decide whether the rest of the cluster is worth scheduling.

### What shipped — Bennett-8su4 CLOSED (3+1 protocol)

Julia heap-allocating functions (`Vector`/`Dict`/`Array{T}(undef,N)`) emit a
volatile `c=0` GC-frame zero-init memset at function entry. Bennett's
`_handle_memset_arm` (`src/extract/instructions.jl`) rejected it: the
volatile-reject predicate fired *before* the `c==0` silent-drop predicate.

Fix (full 3+1 — 2 Plan proposers / opus implementer / orchestrator review;
proposers **independently converged** on the same design): split predicate 3 —
keep the malformed-IR guard (`vol_v isa LLVM.ConstantInt`) early, **relocate
only the volatile-value check to after the `c==0` drop**. A `c==0` memset emits
zero IRInsts regardless of volatility, so volatility is moot for it; volatile
`c!=0` still fails loud (control only reaches the relocated check when `c!=0`).
Error string kept byte-identical. ~6 lines move, no new logic.

New test `test_8su4_volatile_c0_memset.jl` (24/24) — positive case-A drop +
`verify_reversibility` + oracle; volatile-`c!=0` still rejects; malformed
isvolatile still rejects. Research finding: a non-constant isvolatile arg IS
constructible in valid `.ll` if the `declare` omits `immarg` — the third
sub-test exercises that. Regressions all green (9nwt 87/87, ixiz, munq, q04a,
37mt, lqif, t5_corpus 258/258).

### The de-risking spike — heap memory is deeper than the bead map said

After 8su4, a sonnet agent ran `code_llvm` + `reversible_compile` on TJ1/TJ2/TJ4.
Findings, all evidence-backed:

1. **SROA-dissolution fear REFUTED.** worklog/071 gotcha 2 claimed Julia's SROA
   would dissolve the `Vector`/`Dict` before Bennett sees a heap alloc. FALSE —
   SROA only dissolves `NTuple` value-types. `Vector`/`Dict`/`Array` are
   heap-managed, escape the frame, survive as live `@ijl_gc_small_alloc` calls.
2. **The next wall is NOT a GEP — it's inline asm.** `Bennett-cc0.5`'s bead
   description ("GEP base thread_ptr not found in variable wires") is **stale**.
   The actual first error post-8su4 is the x86-64 TLS read
   `%thread_ptr = call ptr asm "movq %fs:0, $0"`, caught by the inline-asm
   guard (Bennett-5oyt/U15).
3. **Past that lie 2 more deep walls:** `@ijl_gc_small_alloc` returns a
   GC-managed heap pointer with no alloca root (Bennett's wire model can't track
   it without new machinery); then *irreversible* Julia runtime callees —
   `j_#_growend!` (array realloc) for TJ1, `j_setindex!` (hash mutation) for TJ2.
4. **TJ4 is a store-to-load MIRAGE.** `a[i]=x; a[i]` (same index) folds to
   `ret x`. Even a fully-fixed pipeline compiles TJ4 to an identity circuit —
   a green TJ4 would be a false positive. Filed `Bennett-890r` (redesign with
   distinct store/load indices).

### Verdict / scheduling decision

**Making Julia `Vector`/`Dict`/`Array(undef)` compile to green corpus fixtures
is a multi-effort research program, not a single orchestratable task.**
`Bennett-cc0.5` as scoped (~500 LOC, thread_ptr) would only move the wall one
step (inline-asm → heap-alloc) and leave a mirage. **Not scheduling a delegated
push for it.** Phase 1 delivered: a real fix (8su4), the SROA fear refuted, and
an accurate wall map. Stale comments in `test_t5_corpus_julia.jl` (header + TJ1
+ TJ2 + TJ4) refreshed to name the inline-asm wall. `Bennett-cc0.5` /
`Bennett-25dm` should be re-triaged against this wall map before any further
heap-memory work.

**Beads:** `Bennett-8su4` closed; `Bennett-890r` filed (TJ4 mirage, P3).
**Orchestration lesson:** the 3+1 proposers converging independently on the
identical design is a strong signal the fix was well-posed; the de-risking
spike (cheap sonnet investigation) was worth far more than its cost — it
converted a tempting-but-stall-prone multi-week effort into a one-fix +
evidence-based stop.

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
