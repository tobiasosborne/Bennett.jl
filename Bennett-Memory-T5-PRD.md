# Bennett.jl — Memory T5 PRD: Persistent Hash-Consed Heap as Universal Fallback

**Status:** draft v0.1 — 2026-04-17
**Epic:** Bennett-cc0 (P1 — "Memory epic: reversible mutable memory")
**This PRD:** Bennett-r1a5 (T5-P1) — sub-bead of Bennett-cc0
**Authors:** Claude/Opus 4.7 with tobias

---

## One-line summary

Bennett.jl already routes the bounded portion of the LLVM `store`/`alloca`
envelope through tiers T0–T4 (preprocess, MUX EXCH, QROM, MemorySSA,
Feistel, shadow, shadow-checkpoint). This PRD lands **T5 — persistent
hash-consed heap** as the *universal fallback* for the only remaining gap:
**runtime-unbounded mutable memory** (`Vector{T}` with arbitrary `push!`,
`Dict{K,V}` insertion, mutable recursive types, runtime-allocated arrays
from any LLVM frontend). T5 is **not optimised for gate cost** — it is the
correctness backstop that makes Bennett.jl total over the LLVM IR a pure
deterministic program can produce, and ships with a multi-language test
corpus (Julia, C via clang, Rust via rustc) that proves the
"Enzyme of reversibility" framing.

---

## 1. Vision

T5 closes the proof that **reversible computation is total over deterministic
LLVM**, just as Enzyme closed the proof that automatic differentiation is
total over differentiable LLVM. Every prior reversible compiler (Revs 2015,
ReVerC 2017, Quipper, ProjectQ, Silq, Unqomp, ReQomp, Qurts) restricts to
user-scoped registers or arrays with static indices. Bennett.jl's T0–T4
already exceeds this; T5 makes the dispatcher's last fallback arm
**provably non-bottom** for any valid LLVM heap pattern.

The multi-language corpus is load-bearing for the vision: a Julia-only T5
demo would re-frame Bennett.jl as a Julia compiler. C and Rust corpus tests
demonstrate the LLVM-level claim concretely — the `extract_parsed_ir_from_ll`
and `extract_parsed_ir_from_bc` entry points (T5-P5a/b) are themselves a
publishable result.

---

## 2. The Enzyme Analogy (T5-specific)

| Enzyme (AD) | Bennett.jl T5 (Reversible) |
|---|---|
| Tape compaction via dead-derivative elimination | Tape compaction via Mogensen hash-cons maximal sharing |
| Shadow heap matches primal heap shape | Persistent-DS heap embeds the version chain in its structure |
| Reverse pass walks the tape in reverse | Reverse pass walks the persistent-DS version chain in reverse |
| `@enzyme_custom_rule` for opaque externals | `register_callee!` for opaque externals (unchanged) |
| Activity analysis prunes inactive shadows | T0 SROA + escape analysis prunes inactive allocas (unchanged) |
| Works across C / C++ / Rust / Fortran / Julia | Works across C / C++ / Rust / Fortran / Julia (T5-P5a/b) |

What does NOT transfer from Enzyme: T5's persistent DS does not need
explicit allocation/deallocation reversibility (AG13's hard problem) because
the version chain *is* the allocation history — every "free" is just walking
back to a prior version.

---

## 3. Current State (2026-04-17, post-M3a)

Verified against the source as of `c5736e0` on main.

### Tiers in place

| Tier | Component | File | Per-op cost | Activation |
|---|---|---|---|---|
| **T0** | LLVM preprocess (sroa/mem2reg/simplifycfg/instcombine) | `ir_extract.jl` | 0 gates; eliminates ~80% of stores | `extract_parsed_ir(...; preprocess=true)` |
| **T1a** | MUX EXCH (W=8, N∈{4,8}; M1: + (2,8),(2,16),(4,16),(2,32)) | `src/softmem.jl` | 7,122–14,026 gates/op | dynamic idx, shape ≤ 64 bits |
| **T1b** | QROM (read-only global table) | `src/qrom.jl` | 4(L−1) Toffoli, O(L·W) CNOT | read-only, L power-of-2 |
| **T2** | MemorySSA ingest + dispatcher wiring (M2a–d) | `src/memssa.jl`, `src/lower.jl` | 0 gates analysis-only | always-on for shape inference |
| **T3a** | Feistel bijective hash (4-round) | `src/feistel.jl` | 8·W Toffoli | user-invoked primitive |
| **T3b** | Shadow memory (static idx, any W) | `src/shadow_memory.jl` | 3W CNOT store, W CNOT load | static idx |
| **T3c** | Universal dispatcher `_pick_alloca_strategy` | `src/lower.jl` | picks tier per op | all alloca ops |
| **T4** | Shadow checkpoint + re-exec (M3a, 2026-04-16) | `src/lower.jl` `:shadow_checkpoint` arm | O(N·W) per op | static-sized N·W > 64 |

### What T5 closes

| Pattern | Today | After T5 |
|---|---|---|
| `Vector{Int8}() + push!` | hard-error at `_pick_alloca_strategy` ("dynamic n_elems not supported") | GREEN via `:persistent_tree` arm |
| `Dict{Int8, Int8}` insert+lookup | hard-error | GREEN |
| `let v = malloc(N); v[i]++` from clang | hard-error (no Julia entry point for raw `.ll`) | GREEN via T5-P5a + `:persistent_tree` |
| `Vec<u8>::push` from rustc | hard-error | GREEN via T5-P5b + `:persistent_tree` |
| Mutable recursive types (linked list, tree) | partial via shadow if static; hard-error if dynamic | GREEN |

---

## 4. Failure Envelope — What Lives in Bucket B (Dynamic-Size Gap)

Concrete rejection sites in current source (per Memory PRD §4 Bucket B):

```
lower_alloca!: dynamic n_elems not supported (%<name>);
T3b.3 shadow memory handles static-sized allocas only.
```

`src/lower.jl` (around the M3a edit). Hit by every program where the
compiler cannot bound the allocation size at compile time — exactly the
patterns T5 targets.

T4 (M3a) covers the spillover case where `n_elems` IS const but
`n*elem_w > 64` (so MUX EXCH won't fit). T5 covers the case where
`n_elems` itself is not const.

---

## 5. Scope

### In scope — this PRD

1. **Three persistent-DS implementations behind a common interface** (T5-P3a/b/c/d)
   - Track A: Okasaki red-black tree (recover and extend prior prototype from Bennett-282 / `test/test_rev_memory.jl`; needs Kahrs 2001 for delete — see Bennett-cc0.1)
   - Track B: Bagwell HAMT with reversible popcount (needs Clojure/Steindorfer-Vinju for insert/delete — see Bennett-cc0.2)
   - Track C: Conchon-Filliâtre semi-persistent array
2. **Two reversible hash-cons compression layers** (T5-P4a/b)
   - Naive Mogensen 2018 reversible hash-cons table (Jenkins 96-bit reversible mix)
   - Feistel-perfect-hash variant reusing `src/feistel.jl`
3. **Multi-language LLVM IR ingest** (T5-P5a/b) — sister entry points to `extract_parsed_ir`:
   - `extract_parsed_ir_from_ll(path; entry_function)` — raw `.ll` text
   - `extract_parsed_ir_from_bc(path; entry_function)` — bitcode
4. **Dispatcher integration** (T5-P6) — `:persistent_tree` arm in
   `_pick_alloca_strategy`, plus `mem=` / `persistent_impl=` / `hashcons=`
   user kwargs on `reversible_compile` for explicit selection
5. **BennettBench head-to-head** (T5-P7a) — full Pareto front: 3 DS × 3
   hash-cons states (none, naive, Feistel) × W ∈ {8,16,32,64} × depth ∈
   {3,8,32,128}
6. **Multi-language test corpus** (T5-P2a/b/c) — Julia, C via clang, Rust via rustc

### Out of scope — deferred to later PRDs

- **AG13 reversible alloc/free** — the persistent-DS approach makes this
  unnecessary for T5's universal-fallback role; the version chain *is* the
  allocation history. Revisit if a benchmark needs explicit `free`.
- **True concurrency** (`atomicrmw` / `cmpxchg` / `fence` under multi-thread)
  — reversible circuits are synchronous by nature; matches Enzyme's frontier.
- **External functions without `register_callee!`** — analogous to Enzyme erroring on `call @printf`.
- **Inline assembly** (`callbr`, `asm!`) — no semantic model; Enzyme hard stop.
- **Coroutines** (`llvm.coro.*`) — not supported.
- **Complex SEH exception handling** — `catchswitch`, `catchpad`, `cleanuppad`.

---

## 6. Success Criteria

Per user directive (2026-04-17): **correctness is primary, gate cost is
secondary**. There is no per-op gate budget for T5; the goal is to measure
and document the Pareto front, not hit a target.

### Primary (correctness, non-negotiable)

1. **Every test in T5-P2a/b/c passes** with `verify_reversibility(c; n_tests=3)`.
   Specifically:
   - **Julia (P2a)**: `Vector{Int8}` push×3+sum; `Dict{Int8,Int8}` insert/lookup; mutable singly-linked list; `Array{Int8}(undef, 256)` dynamic idx.
   - **C via clang (P2b)**: `int* v = malloc; v[i]++` runtime i; growing buffer realloc; malloc-based linked list.
   - **Rust via rustc (P2c)**: `Vec<u8>::push`; `HashMap` insert+get; Box-based linked list.

2. **Multi-language ingest works**: `extract_parsed_ir_from_ll` and
   `_from_bc` produce regression-equal `ParsedIR` to the Julia path on
   ≥5 test programs that exist in both forms.

3. **Dispatcher is monotonic**: every test that GREENs today STAYS GREEN
   after T5-P6 lands. Specifically, every BENCHMARKS.md row from the
   M3a baseline (`c5736e0`) is byte-identical post-T5.

### Secondary (measurement, document don't target)

4. **Pareto front published** in BENCHMARKS.md: 3 impls × 3 hash-cons
   states × 4 widths × 4 depths = 144 cells. Each cell records (gates,
   ancillae, Toffoli count, Toffoli depth, verify_reversibility status).

5. **Default winner identified** — for each (W, depth) cell, the
   recommended-default impl is named. The dispatcher's `:persistent_tree`
   arm picks the per-shape default at lowering time; users can override.

### Stretch (nice-to-have, not blocking)

6. **End-to-end benchmark vs ReVerC on a memory-heavy workload** — pick
   one (sort, hash table fill+iterate, graph traversal) where ReVerC
   cannot run at all (because it has no dynamic-idx alloca support). The
   "infinite improvement vs N/A" framing is paper material.

### Regression (non-negotiable)

7. **Core arithmetic gate counts UNCHANGED** (per Memory PRD §6.6):
   - i8 `x+1` = 100 total, 28 Toff
   - i16 = 204, 60 Toff
   - i32 = 412, 124 Toff
   - i64 = 828, 252 Toff
   - All BENCHMARKS.md rows from `c5736e0` byte-identical.

8. **Existing soft-float gate counts UNCHANGED**:
   - `soft_fma` = 447,728 gates
   - `soft_exp_julia` = 3,485,262 gates
   - `soft_exp2_julia` = 2,697,734 gates

---

## 7. Test Corpus

Three files, mirroring the Memory PRD §7 ladder structure:

### `test/test_t5_corpus_julia.jl` (T5-P2a)

Each test wraps `reversible_compile` in `@test_throws` today; flips to `@test`
+ `verify_reversibility` once T5-P6 lands.

| # | Program | Trigger condition |
|---|---|---|
| TJ1 | `Vector{Int8}() + push!×3 + sum-mod-Int8` | dynamic n_elems |
| TJ2 | `Dict{Int8,Int8}` insert + lookup roundtrip | dynamic n_elems + hashing |
| TJ3 | mutable singly-linked list (Julia mutable struct + self-ref) | mutable recursive type |
| TJ4 | `Array{Int8}(undef, 256)` dynamic idx | static-sized but T4 shadow-checkpoint vs T5 borderline; both should work post-T5 |

### `test/test_t5_corpus_c.jl` + `test/fixtures/c/t5_*.c` (T5-P2b)

Compile `.c` with `clang -O0 -emit-llvm -S -o test/fixtures/c/<name>.ll <name>.c`. Harness loads via `extract_parsed_ir_from_ll`.

| # | Program (C) | Pattern |
|---|---|---|
| TC1 | `int* v = malloc(N*sizeof(int)); v[i]++` runtime i | dynamic idx + heap |
| TC2 | growing buffer via `realloc` | resize semantics |
| TC3 | malloc-based singly-linked list | unbounded recursion |

### `test/test_t5_corpus_rust.jl` + `test/fixtures/rust/t5_*.rs` (T5-P2c)

Compile `.rs` with `rustc --emit=llvm-ir -C opt-level=0 --crate-type lib`. Harness loads via `extract_parsed_ir_from_ll`.

| # | Program (Rust) | Pattern |
|---|---|---|
| TR1 | `Vec<u8>::push() ×3 + iter sum` | unbounded vector |
| TR2 | `HashMap<u8,u8>` insert + get roundtrip | hashing |
| TR3 | `Box`-based singly-linked list | unbounded recursion |

If `rustc`'s `HashMap` produces too much LLVM (>10k lines), TR2 falls
back to a hand-rolled hash table — captured as a test-corpus
implementation note in `test/fixtures/rust/README.md`.

---

## 8. Gate-Count Budget

**There is no budget.** Per user directive: T5 is the correctness backstop;
gate cost is observational. The Pareto front (T5-P7a) is the deliverable.

For context, expected order-of-magnitude per-op costs (from the briefs):

| Strategy | Predicted per-op cost | Source |
|---|---|---|
| Okasaki RBT insert at depth 3, W=32 | ~30·W·depth = ~3000 Toff (extrapolated from the 71 kG figure for the 2017 prototype after refactor) | `okasaki_rbt_brief.md` §4 |
| HAMT insert at depth 3, W=32 | ~150 Toff for CTPop + ~200 Toff per hop × depth = ~750 Toff | `bagwell_hamt_brief.md` §4 |
| C-F semi-persistent set, W=32 | O(k·W) where k=path-to-root, amortizes to ~W=32 Toff/op under linear access | `cf_semipersistent_brief.md` §5 |
| Mogensen hash-cons (Jenkins mix), W=32 | ~52/71 instructions of best-case `cons` × 3W Toff each = ~5000 Toff | `mogensen_hashcons_brief.md` §3 |
| Feistel hash-cons, W=32 | 8·W = 256 Toff | `src/feistel.jl` |

**Critical Phase-0 finding** (from `cf_semipersistent_brief.md` §5): the C-F
`Diff` chain *is* Bennett's history tape, and `reroot` *is* the uncompute
pass. This is a structural correspondence at the algorithmic level, not just
the asymptotic level. C-F may significantly outperform the cost predictions
above by exploiting this correspondence directly in `bennett_transform.jl` rather than
treating C-F as just-another-primitive.

---

## 9. Non-Goals

Matches Enzyme's coverage frontier (VISION-PRD §4.3, Memory PRD §9).

- **Inline assembly** (`callbr`, `asm!`) — no semantic model.
- **External functions without `register_callee!`** — Enzyme's hard stop too.
- **Non-reproducible intrinsics** — `llvm.readcyclecounter`, `llvm.thread.pointer`, `llvm.returnaddress`, `llvm.frameaddress`.
- **Complex SEH exception handling** — `catchswitch`, `catchpad`, `cleanuppad`.
- **Coroutines** (`llvm.coro.*`) — not supported.
- **True concurrency** — `atomicrmw`/`cmpxchg`/`fence` only under single-thread collapse.
- **AG13-style explicit reversible free** — version chain subsumes; revisit if a benchmark demands.
- **Gate-cost optimisation of T5 paths** — measured, not targeted; if a real workload needs cheaper unbounded heap, file a follow-up PRD.

---

## 10. Milestones

Order = T5 bead phase order. Each phase RED-first, GREEN measured, no phase
starts before its blockers GREEN. Bead IDs in parentheses.

### M5.0 — Ground truth (Bennett-iiu2, nrl7, 64yf, 4g0d, 3x2v) — **DONE 2026-04-17**

5 PDFs + 5 briefs in `docs/literature/memory/`. Companion beads filed for
the two algorithm gaps discovered during brief-writing: Bennett-cc0.1
(Kahrs 2001 for Okasaki delete), Bennett-cc0.2 (Clojure/Steindorfer-Vinju
for HAMT insert/delete).

### M5.1 — This PRD (Bennett-r1a5) — **IN PROGRESS**

Author + commit `Bennett-Memory-T5-PRD.md`. Reviewed against the 5 briefs.

### M5.2 — Multi-language test corpus (Bennett-t61h, w985, gl2m)

RED tests in three files. clang and rustc must be installed
(verify in CI). All RED with documented error message.

### M5.3 — Persistent-DS interface + 3 implementations (Bennett-isab, mcgk, a7zy, 6thy)

- `src/persistent/interface.jl` (T5-P3a) — orchestrator implements
- `src/persistent/okasaki_rbt.jl` (T5-P3b) — sonnet drafts from `test_rev_memory.jl`, orchestrator reviews tightly; needs Bennett-cc0.1 for delete
- `src/persistent/hamt.jl` + `src/persistent/popcount.jl` (T5-P3c) — sonnet drafts, orchestrator reviews tightly; needs Bennett-cc0.2 for insert/delete; reversible popcount validated standalone first
- `src/persistent/cf_semi_persistent.jl` (T5-P3d) — sonnet drafts, orchestrator reviews tightly; **special attention to Bennett-tape correspondence finding** — may simplify lowering significantly

Each impl: full `verify_reversibility` exhaustive K=Int8 sweep, gate-count table in WORKLOG.md.

### M5.4 — Hash-cons compression (Bennett-gv8g, 7pgw)

- `src/persistent/hashcons_naive.jl` (T5-P4a) — **orchestrator implements** (novel reversible hash table)
- `src/persistent/hashcons_feistel.jl` (T5-P4b) — orchestrator implements
- 6 measured combinations (3 DS × 2 hashcons) tabulated.

### M5.5 — Multi-language LLVM IR ingest (Bennett-lmkb, f2p9)

- `extract_parsed_ir_from_ll(path; entry_function)` (T5-P5a) — **3+1 protocol**, core change to `ir_extract.jl`
- `extract_parsed_ir_from_bc(path; entry_function)` (T5-P5b) — **3+1 protocol**

Regression: 5 existing test programs produce identical `ParsedIR` from
`extract_parsed_ir(f, T)` and `extract_parsed_ir_from_ll(<.ll dump of f>)`.

### M5.6 — Dispatcher integration (Bennett-z2dj)

- `:persistent_tree` arm in `_pick_alloca_strategy` (T5-P6) — **3+1 protocol**, core change to `lower.jl`
- `mem=:persistent`, `persistent_impl=:hamt|:okasaki|:cf`, `hashcons=:naive|:feistel|:none` user kwargs

All T5-P2a/b/c tests GREEN. All BENCHMARKS.md rows from `c5736e0` byte-identical.

### M5.7 — BennettBench + writeup (Bennett-ktt8, 2uas)

- `benchmark/bc_t5_head_to_head.jl` (T5-P7a) — full Pareto front
- `BENCHMARKS.md` + `WORKLOG.md` updates + paper-outline section for Bennett-6siy (T5-P7b)
- README.md feature-table entry for `:persistent` dispatch + multi-language

---

## 11. Risks and Mitigations

### R1 — Phi-merged pointer × persistent-DS interaction

**Risk**: per CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS RISK",
phi-merged pointers may falsely sensitise persistent-DS version chains
across dominance-violating paths. M2c (Bennett-oio4) addressed this for
shadow stores; T5 must replicate.

**Mitigation**: every persistent-DS impl has at least one diamond-CFG test
in its harness. T5-P3a's harness specifies this in the contract. Rule out
by inspection during T5-P6 review.

### R2 — Hash-cons table size explosion

**Risk**: a naive reversible hash-cons table with table size H grows the
ancilla count by O(H) per insertion event. For a `Vector` push of 256
elements, this is 256·H wires.

**Mitigation**: Mogensen 2018 §3 specifies a fixed-segment hash table that
reuses slots; brief verbatim. T5-P4a follows this verbatim. T5-P4b uses
Feistel which is bijective by construction (no table at all).

### R3 — Multi-language IR variance

**Risk**: clang and rustc emit subtly different LLVM IR conventions
(calling convention, struct layout, attribute set) than Julia. T5-P5a/b
may parse Julia-emitted IR perfectly but fail on clang/rustc IR.

**Mitigation**: T5-P5a/b acceptance includes round-trip regression
between Julia and clang/rustc IR for ≥5 trivial programs (e.g.,
`int add(int x, int y)`). 3+1 protocol on both beads.

### R4 — C-F Bennett-tape correspondence may not hold under all CFGs

**Risk**: the structural correspondence noted in `cf_semipersistent_brief.md`
§5 was identified for linear access patterns. Under branching access (where
multiple "current versions" co-exist transiently), the `reroot` semantics
may diverge from Bennett uncompute.

**Mitigation**: T5-P3d harness includes branching tests explicitly. If the
correspondence breaks, fall back to treating C-F as a generic primitive
(keeps it as a viable Track C; just loses the algorithmic-shortcut benefit).

### R5 — Phase 5 (multi-language ingest) blocks P6

**Risk**: `extract_parsed_ir_from_ll` is a substantial new core entry point
and the 3+1 protocol may take longer than estimated. P6 cannot land until
P5b is GREEN (per the dependency graph) because P6's dispatcher is what
the C/Rust corpus tests in P2b/c hit.

**Mitigation**: split the work: P6 *can* land for the Julia path only first
(disabling C/Rust tests with a `if VERSION_HAS_LLVM_INGEST` skip flag),
then re-enable when P5b lands. File this as a fallback plan.

### R6 — `wisp_dependencies` table missing in `bd`

**Risk**: filed as Bennett-ponm (P3 bug). Cross-bead dep tracking via
`bd dep` is broken; we rely on description text for the DAG. Risk: a future
agent picks up a bead whose blocker isn't actually GREEN yet.

**Mitigation**: T5-P3a–P7b descriptions name their blocker beads inline.
`bd ready` filtering still works for parent_id (children of an open epic
are listed). Manual check of "is its blocker closed?" before claiming.

---

## 12. Key References

### Local — Phase 0 deliverables (2026-04-17)

- `docs/literature/memory/okasaki_rbt_brief.md` — verbatim insert + 4 balance cases (Okasaki 1999 JFP 9(4)). Delete from Kahrs 2001 (pending Bennett-cc0.1).
- `docs/literature/memory/bagwell_hamt_brief.md` — AMT essentials + verbatim CTPop emulation (Bagwell 2001). Insert/delete from Clojure / Steindorfer-Vinju (pending Bennett-cc0.2).
- `docs/literature/memory/cf_semipersistent_brief.md` — verbatim version-tree + `reroot` (Conchon-Filliâtre 2007). **Contains the Bennett-tape correspondence finding (§5).**
- `docs/literature/memory/mogensen_hashcons_brief.md` — verbatim reversible `cons`, Jenkins 96-bit reversible hash, ref-count reversibility (Mogensen 2018 NGC 36:203). Notes the RC 2015 → NGC 2018 correctness fix.
- `docs/literature/memory/ag13_brief.md` — verbatim EXCH semantics, free-list invariant, linear-ref discipline (Axelsen-Glück 2013 LNCS 7948). Reference for deferred AG13 work; not used in T5 directly.

### Local — surveys (already in repo)

- `docs/literature/memory/SURVEY.md` — 40+ paper survey, 5-tier strategy.
- `docs/literature/memory/COMPLEMENTARY_SURVEY.md` — persistent-DS + reversible AD deep dive.
- `docs/literature/SURVEY.md` — project-wide bibliography.

### Local — design docs

- `docs/memory/shadow_design.md` — T4 design (M3a in production).
- `docs/memory/memssa_investigation.md` — MemorySSA go/no-go.

### Local — PRDs

- `Bennett-VISION-PRD.md` — full v1.0 roadmap.
- `Bennett-Memory-PRD.md` — current memory PRD (M1–M4 done as of 2026-04-16).
- `Bennett-PRD.md`, `BennettIR-PRD.md`, `BennettIR-v0{3,4,5}-PRD.md` — historical.

### External pending acquisition

- **Kahrs 2001** — "Red-black trees with types" JFP 11(4):425, DOI 10.1017/S0956796801004026. Springer paywall, TIB. Bennett-cc0.1.
- **Clojure PersistentHashMap.java** — github.com/clojure/clojure/blob/master/src/jvm/clojure/lang/PersistentHashMap.java, free. Bennett-cc0.2.
- (Optional alt) **Steindorfer-Vinju 2015** — "Optimizing Hash-Array Mapped Tries..." OOPSLA, ACM paywall. Bennett-cc0.2 alternative.

### External — cited via SURVEY summaries (no acquisition needed for T5)

- BENNETT89, KNILL95 — pebbling foundation.
- ENZYME20, REQOMP24 — AD analogy.
- PRS15, REVERC17 — prior reversible compiler comparisons.
- BABBUSH18, MEULI19 — already implemented (T1b, pebbling).

---

## 13. Review Checklist

Before merging this PRD to main:

- [x] Scope decision documented (§5).
- [x] Success criteria correctness-primary, gate-cost-secondary per user directive (§6).
- [x] Test corpus concrete with multi-language dimensions (§7).
- [x] Gate-count "no budget, measure" call-out per user directive (§8).
- [x] Non-goals aligned with Enzyme frontier (§9).
- [x] Milestones bead-mapped (§10).
- [x] Risks include phi-merged-pointer × persistent-DS, multi-language IR variance, C-F correspondence fragility (§11).
- [x] References cite all 5 Phase-0 briefs + companion-bead pending acquisitions (§12).
- [ ] **User sign-off on PRD** — pending.
- [ ] Reviewed against `docs/literature/memory/SURVEY.md` end-to-end — pending.
- [ ] Reviewed against `docs/literature/memory/COMPLEMENTARY_SURVEY.md` end-to-end — pending.
- [ ] Re-checked C-F brief §5 correspondence claim against actual `bennett_transform.jl` semantics — pending (assigned to T5-P3d).
