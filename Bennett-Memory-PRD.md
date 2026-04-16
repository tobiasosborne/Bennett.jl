# Bennett.jl — Memory PRD: Reversible Mutable Memory at LLVM Level

**Status:** draft v0.1 — 2026-04-16
**Epic:** Bennett-cc0 (P1 — "Memory epic: reversible mutable memory")
**This PRD:** Bennett-ceps (P2 — "P.1 Bennett-Memory-PRD.md")
**Authors:** Claude/Opus 4.6 with tobias

---

## One-line summary

Bennett.jl is already the first reversible compiler with automatic
end-to-end handling of LLVM `store`/`alloca` via a 5-tier strategy
(T0 preprocess → T1a MUX EXCH → T1b QROM → T2 MemorySSA ingest →
T3a Feistel / T3b Shadow / T3c dispatcher). This PRD closes the
**three remaining failure buckets** at the edges of that envelope
(shape gap, dataflow gap, dynamic-size gap) and lands a BennettBench
head-to-head that beats ReVerC 2017 on MD5 (27.5k Toff) — the
publishable first-in-literature result tracked on Bennett-cc0.

---

## 1. Vision

**Reversible computation belongs at the LLVM level.** Bennett.jl
operates below the source language where every program is a sequence
of primitive instructions. Every deterministic computation can be
made reversible via Bennett's 1973 construction. By operating on
LLVM IR, Bennett.jl reversibilises any language that compiles to
LLVM — without special types, without operator overloading.

**Memory is the hardest opcode.** `store`, `alloca`, `load`,
`getelementptr` are *destructive* in classical semantics and
*unbounded* in dynamic cases. Every prior reversible compiler
(Revs 2015, ReVerC 2017, Quipper, ProjectQ, Silq, Unqomp, ReQomp,
Qurts) handles memory by restricting to user-scoped registers or
arrays with *static* indices. None handles arbitrary LLVM
`load`/`store`/`alloca` (see `docs/literature/memory/SURVEY.md` §2h).

**Bennett.jl's innovation:** tier the dispatch. The cheapest correct
lowering wins per allocation site, driven by a combination of LLVM's
existing analysis passes (SROA, mem2reg, MemorySSA) and novel
reversible primitives (Babbush-Gidney QROM, Luby-Rackoff Feistel,
Enzyme-style shadow). This PRD scopes the work to close the last
failure modes and demonstrate the result on MD5.

---

## 2. The Enzyme Analogy (memory-specific)

| Enzyme (AD) | Bennett.jl (Reversible) |
|---|---|
| Input: LLVM IR with mutating stores | Input: LLVM IR with mutating stores |
| Output: gradient tape for reverse pass | Output: reversible tape for Bennett reverse |
| Type analysis | Alloca shape inference (elem_width, n_elems) |
| Activity analysis | Liveness + escape analysis (Bennett-glh) |
| Shadow memory (mirror heap) | Shadow tape (`docs/memory/shadow_design.md`) |
| Store → zero-shadow + accumulate | Store → tape old value + apply new |
| Accumulate derivatives (*linear*) | Exact inversion (*invertible*) |
| Cache vs recompute | Pebbling: Knill recursion / Meuli SAT |
| `@enzyme_custom_rule` | `register_callee!` |

Enzyme's architectural decomposition (type analysis → activity
analysis → shadow allocation) is directly portable. What does NOT
transfer is the `+=` accumulation trick: reversibility requires
*exact inversion*, not linear approximation. See SURVEY.md §2f
lines 111–118 for the extracted Enzyme design.

---

## 3. Current State (2026-04-16)

Verified against the source at this date.

### Tiers in place

| Tier | Component | File | Per-op cost | Activation |
|---|---|---|---|---|
| **T0** | LLVM preprocess (sroa/mem2reg/simplifycfg/instcombine) | `ir_extract.jl:23` | 0 gates; eliminates ~80% of stores | opt-in via `extract_parsed_ir(...; preprocess=true)` |
| **T1a** | MUX EXCH (W=8, N∈{4,8}) | `src/softmem.jl` | 7,122–14,026 gates/op | dynamic idx, shape match |
| **T1b** | QROM (read-only global table) | `src/qrom.jl` | 4(L−1) Toffoli, O(L·W) CNOT | read-only, L power-of-2 |
| **T2** | MemorySSA ingest (metadata only) | `src/memssa.jl` | 0 gates — **not yet consumed by dispatcher** | `use_memory_ssa=true` |
| **T3a** | Feistel bijective hash (4-round) | `src/feistel.jl` | 8·W Toffoli | user-invoked primitive |
| **T3b** | Shadow memory (static idx, any W) | `src/shadow_memory.jl` | 3W CNOT store, W CNOT load | static idx |
| **T3c** | Universal dispatcher `_pick_alloca_strategy` | `src/lower.jl:1790` | picks T3b / T1a / :unsupported | all alloca ops |

### Dispatcher logic (verbatim from `src/lower.jl:1790-1802`)

```julia
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand)
    if idx.kind == :const
        return :shadow                 # static idx → T3b, any shape
    end
    (elem_w, n) = shape
    if elem_w == 8 && n == 4
        return :mux_exch_4x8           # dynamic idx → T1a (only (8,4))
    elseif elem_w == 8 && n == 8
        return :mux_exch_8x8           # dynamic idx → T1a (only (8,8))
    else
        return :unsupported            # everything else → error
    end
end
```

### What's not yet built

- **T4 Shadow-checkpoint + re-exec** (Enzyme-style, `docs/memory/shadow_design.md`): designed, not implemented.
- **T5 Persistent hash-consed array** (Okasaki+Mogensen 2018, SURVEY.md §1(5)): deferred — 71kG/op prototype proves correctness but cost exceeds budget.
- **MemorySSA → dispatcher wiring**: `MemSSAInfo` is parsed (`src/memssa.jl`) but `_pick_alloca_strategy` still uses the local `ctx.ptr_provenance` heuristic. The def-use graph is unused.

---

## 4. Failure Envelope — Three Buckets

Concrete rejection sites in current source:

### Bucket A — Shape gap (dynamic idx, shape ∉ {(8,4),(8,8)})

```
lower_store!: unsupported (elem_width=<W>, n_elems=<N>) for dynamic idx
```
`src/lower.jl:1836` (store) and `src/lower.jl:1533` (load).

**Hit by**: `Array{Int16}(undef, 4)` with runtime idx; `Array{Int8}(undef, 16)`; any (N, W) tuple outside the two hard-coded shapes.

**Cause**: `_pick_alloca_strategy` hard-codes only two (N, W) shapes.

### Bucket B — Dynamic-size gap (runtime-growing arrays)

```
lower_alloca!: dynamic n_elems not supported (%<name>);
T3b.3 shadow memory handles static-sized allocas only.
```
`src/lower.jl:1759`.

**Hit by**: `Vector{T}()` + `push!`, `Dict{K,V}()`, `Int[x for x in xs]`, linked-list mutation, any runtime-determined allocation size.

**Cause**: `lower_alloca!` requires `n_elems.kind == :const`. No strategy handles runtime size.

### Bucket C — Dataflow gap (aliased pointers, no local provenance)

Store path:
```
lower_store!: no provenance for ptr %<name>;
store must target an alloca or GEP thereof
```
`src/lower.jl:1820`. Stores hard-error when `ctx.ptr_provenance` has no entry for the ptr SSA name.

Load path: `src/lower.jl:1512-1518` routes through `ptr_provenance` when present, otherwise falls through to the legacy primitive `lower_load!` at `:1516`. So load-on-unknown-pointer doesn't always error — but when it does reach `_lower_load_via_mux!`, the shape check at `:1533` still fires.

**Hit by**: pointer passed through a `phi` or `select`, stored via an aliased copy, or flowing through a function boundary without registered callee.

**Cause**: `ctx.ptr_provenance` is a *local* dictionary of SSA-names-to-origins. It cannot track phi-merged pointers. MemorySSA provides the correct def-use graph but is not wired in.

---

## 5. Scope

### In scope — this PRD

1. **Bucket A — Parametric MUX EXCH extension**
   Generalise `soft_mux_load/store_NxW` to (N, W) ∈ {2, 4, 8, 16, 32} × {8, 16, 32}. Register callees on demand from `_pick_alloca_strategy`.

2. **Bucket C — MemorySSA-to-dispatcher wiring**
   Hand `MemSSAInfo` into `LoweringCtx`. Replace `ctx.ptr_provenance` with MemorySSA def-use lookup where available; retain heuristic as fallback.

3. **Bucket B (partial) — T4 shadow-checkpoint + re-exec**
   Enzyme-style shadow tape, Meuli-SAT-pebbled. Handles bounded-but-large stores. Still restricts to statically-known allocation sizes. Unlocks MD5 head-to-head.

4. **BennettBench head-to-head**
   MD5 full 64-round, SHA-256 full 64-round, Cuccaro 32-bit adder — tabulated against ReVerC 2017 numbers. `benchmark/bc_memory_headline.jl` new entry.

### Out of scope — deferred to next PRD

- **Bucket B (full) — T5 persistent hash-consed array**
  `Vector{T}` with truly unbounded `push!`, `Dict{K,V}` inserts. Okasaki+Mogensen at ~20–70kG/op. Fallback tier for post-MD5 work.

- **True concurrency**: `atomicrmw` / `cmpxchg` / `fence` under multi-thread. Reversible circuits are synchronous by nature.

- **External functions without `register_callee!`**: analogous to Enzyme's hard stop at `call @printf`.

- **Inline assembly**: `callbr`, `asm!`. No semantic model.

- **Coroutines**: `llvm.coro.*`. Not supported.

- **Complex SEH exceptions**: `catchswitch`, `catchpad`, `cleanuppad`. Historically fragile in Enzyme too.

These align with Enzyme's own coverage frontier (VISION-PRD §4.3).

---

## 6. Success Criteria

All gate-count claims verified by `verify_reversibility(c; n_tests=3)` and exhaustive / random input sweeps per CLAUDE.md §4.

### Primary (PLDI/ICFP headline)

1. **MD5 full (64 steps, 512-bit block)**: ≤27,520 Toffoli.
   Current: ~48,000 Toff (1.75× worse than ReVerC, per BENCHMARKS.md:153).
   Target: **match or beat ReVerC 27,520** via T4 shadow-checkpoint.

2. **SHA-256 full 64-round compression**: Toffoli ≤ 80,000.
   Current: 135,584 Toff (BENCHMARKS.md:26).
   Target: ~40% reduction via MemorySSA-driven def-use elimination.
   Peak-live-qubits already beats PRS15 (28,133 vs 45,056) — preserve this.

### Secondary (completeness)

3. **Bucket A cleared**: every `reversible_compile(f, T)` where f allocates `Array{W}(undef, N)` for N ∈ {2,4,8,16,32}, W ∈ {8,16,32,64} with dynamic idx GREEN and `verify_reversibility` passes.

4. **Bucket C cleared**: every pattern in `test/test_memory_corpus.jl` requiring phi-merged-pointer disambiguation GREEN.

5. **Bucket B (partial) cleared**: static-sized but larger allocations (N up to 256, any W) routed through T4 shadow-checkpoint, gate cost within 2× of the theoretical lower bound (3W CNOT/store).

### Regression (non-negotiable)

6. **Core arithmetic gate counts UNCHANGED**:
   - i8 `x+1` = 100 total, 28 Toff  (BENCHMARKS.md:9)
   - i16 = 204, 60 Toff  (BENCHMARKS.md:10)
   - i32 = 412, 124 Toff  (BENCHMARKS.md:11)
   - i64 = 828, 252 Toff  (BENCHMARKS.md:12)
   - Memory-primitive benchmarks from BENCHMARKS.md §Memory primitives unchanged.

7. **Existing soft-float gate counts UNCHANGED**:
   - `soft_fma` = 447,728 gates (BENCHMARKS.md:29)
   - `soft_exp_julia` = 3,485,262 (BENCHMARKS.md:32)
   - `soft_exp2_julia` = 2,697,734 (BENCHMARKS.md:33)

---

## 7. Test Corpus (`test/test_memory_corpus.jl`)

Ladder of patterns, each ONE `@test` call. Build RED-first before any fix.

| # | Program | Bucket | Current | Target |
|---|---|---|---|---|
| L0 | `Ref{Int8}` scalar mutation | — | GREEN (T3b shadow) | GREEN |
| L1 | `Array{Int8}(undef, 4)` const idx | — | GREEN (T3b shadow) | GREEN |
| L2 | `Array{Int8}(undef, 4)` dynamic idx | — | GREEN (T1a mux_4x8) | GREEN |
| L3 | `Array{Int8}(undef, 8)` dynamic idx | — | GREEN (T1a mux_8x8) | GREEN |
| L4 | `Array{Int16}(undef, 4)` dynamic idx | **A** | **RED** (unsupported shape) | GREEN M1 |
| L5 | `Array{Int8}(undef, 16)` dynamic idx | **A** | **RED** (unsupported shape) | GREEN M1 |
| L6 | `Array{Int32}(undef, 32)` dynamic idx | **A** | **RED** | GREEN M1 |
| L7 | `if c then p = &a[0] else p = &b[0]; *p = v` | **C** | **RED** (no provenance) | GREEN M2 |
| L8 | `let a = [x,y]; b = a; b[0] = v; return a[0]` | **C** | **RED** (aliased store) | GREEN M2 |
| L9 | `Vector{Int8}()` + `push!` × 3, `sum` | **B** | **RED** (dynamic n_elems) | GREEN M3 (bounded) |
| L10 | `Array{Int8}(undef, 256)` dynamic idx | **B** | **RED** (budget-exceeded) | GREEN M3 (T4) |
| L11 | 512-bit MD5 compression (static) | — | works but ~48k Toff | ≤27.5k Toff (M3) |

Each test:
- Compiles with `reversible_compile(f, arg_types)` — no special annotations.
- Exhaustive input sweep for Int8 (256 cases); 1000 random inputs for Int16/32/64.
- `verify_reversibility(c; n_tests=3)` passes.
- Gate count within the per-bucket budget in §8.

---

## 8. Gate-Count Budget

| Bucket | Per-op budget | Theoretical lower bound | Justification |
|---|---:|---:|---|
| A — MUX EXCH (N, W) | 4·N·W gates | ~N·W | Extension of existing `soft_mux` with same structure |
| B (bounded) — T4 shadow-checkpoint | W CNOT + O(D·W) tape | W CNOT | `docs/memory/shadow_design.md:130` |
| C — MemorySSA dispatch | 0 additional | 0 | Analysis-only, picks existing strategy |
| D (deferred) — T5 persistent tree | ≤50 kG | ~10 kG | Okasaki prototype at 71 kG is upper witness |

Overall SURVEY.md §1 budget: **≤20 kG per memory op**. T4 must stay within this for the MD5 benchmark.

---

## 9. Non-Goals

Matches Enzyme's coverage frontier (VISION-PRD §4.3, SURVEY.md §2f).

- **Inline assembly** (`callbr`, `asm!`) — no semantic model, hard stop for Enzyme and us.
- **External functions without `register_callee!`** — analogous to Enzyme erroring on unknown externals.
- **Non-reproducible intrinsics** — `llvm.readcyclecounter`, `llvm.thread.pointer`, `llvm.returnaddress`, `llvm.frameaddress`.
- **Complex SEH exception handling** — `catchswitch`, `catchpad`, `cleanuppad`. Filed as P3 bd issues (Bennett-c1t, -iaq, -nd9).
- **Coroutines** (`llvm.coro.*`) — not supported.
- **True concurrency** — `atomicrmw`/`cmpxchg`/`fence` handled only under single-thread collapse.
- **Unbounded `Vector{T}` via persistent tree** — deferred to post-MD5 PRD.
- **GC / free-list (AG13 full)** — partial via MemorySSA-guided dead-alloca elimination only.

---

## 10. Milestones

Order chosen by cost-to-fix × independence. Milestones are strictly sequential; each must GREEN before the next starts.

### M1 — Bucket A: Parametric MUX EXCH extension (~1 week, single implementer)

**Classification**: *additive*. New functions + dispatcher entries. No core-change 3+1 protocol required per CLAUDE.md §2.

1. RED: commit `test/test_memory_corpus.jl` with L4, L5, L6 failing.
2. Generalise `soft_mux_load_NxW(arr, idx)` and `soft_mux_store_NxW(arr, idx, val)` over (N, W) ∈ {2,4,8,16,32} × {8,16,32}.
3. Extend `_pick_alloca_strategy` to dispatch for each (N, W) pair.
4. `register_callee!` each new MUX variant in the bootstrap.
5. GREEN: L4/L5/L6 compile, verify, pass.
6. Update `BENCHMARKS.md` §Memory primitives with the new scaling table.

Deliverable: 15 new MUX variants, L4/L5/L6 GREEN, no regression.

### M2 — Bucket C: MemorySSA-wired dispatcher (~1 week, **3+1 agents**)

**Classification**: *core change to `lower.jl` and `ir_extract.jl`*. Per CLAUDE.md §2, 2 independent proposer agents + 1 implementer + orchestrator-reviewer.

1. RED: extend test corpus with L7, L8 (aliased-pointer patterns).
2. Proposer A and Proposer B independently design the MemSSA → dispatcher interface. Specific questions:
   - How is `MemSSAInfo` threaded into `LoweringCtx`?
   - What's the fallback order (MemSSA → ptr_provenance → error)?
   - How are phi-merged pointer defs handled?
3. Orchestrator picks better design. Implementer lands it.
4. GREEN: L7/L8 compile, verify. Regression: all existing tests pass. Gate-count baselines UNCHANGED.
5. Bonus: SHA-256 Toff count drops toward PRS15 43,712.

Deliverable: `MemSSAInfo` consumed by `_pick_alloca_strategy`. L7/L8 GREEN.

### M3 — Bucket B (partial): T4 shadow-checkpoint + re-exec (~2-3 weeks, **3+1 agents**)

**Classification**: *new strategy tier in `lower.jl`*. Requires 3+1 per CLAUDE.md §2.

1. RED: add L10, L11 to test corpus.
2. Proposer A and Proposer B independently design the tape-allocation + pebbling scheme. Specific questions:
   - Per-SSA-store or per-basic-block tape granularity?
   - Meuli SAT pebbling or simpler Knill recursion?
   - How does T4 interact with existing T1a/T3b dispatch?
3. Orchestrator picks better design. Implementer lands `src/shadow_checkpoint.jl` + dispatch hook.
4. GREEN: L10/L11 compile, verify, pass gate-count budget in §8.
5. **MD5 head-to-head**: `benchmark/bc_md5_full.jl` achieves ≤27,520 Toff. Publish.
6. Update `BENCHMARKS.md` §Head-to-head with ReVerC comparison row.

Deliverable: MD5 full 64-round ≤27,520 Toff (beats ReVerC). `src/shadow_checkpoint.jl`, `docs/memory/shadow_checkpoint_implementation.md`.

### M4 — BennettBench head-to-head paper (~1-2 weeks)

1. Tabulate all results: MD5, SHA-256, Cuccaro adder, Bucket-A/B/C corpus.
2. Draft PLDI/ICFP outline (filed as Bennett-6siy, "Paper outline (PLDI/ICFP target)").
3. Write up the 5-tier dispatch architecture as the paper's central contribution.

Deliverable: draft submission to PLDI 2027 or ICFP 2027.

### Skipped (this PRD): M5 T5 persistent tree

Deferred to next PRD (Bennett-nw1 — "v0.7: Hash-consing for reversible memory (Mogensen 2018)"). Reason: 71kG/op exceeds budget; T4 covers the MD5 headline without needing unbounded memory. Revisit if a benchmark requires unbounded `Vector{T}` runtime growth.

---

## 11. Risks and Mitigations

### R1 — T4 tape explosion

**Risk**: for SHA-256 with ~1000 stores, naïve shadow tape needs ~64k wires.

**Mitigation**: Meuli 2019 SAT pebbling compacts tape to O(log N) at time-cost. Already referenced in `docs/memory/shadow_design.md:92-105`. If Meuli solver too slow, fall back to Knill recursion (already in `src/pebbling.jl`).

### R2 — MemorySSA text-parse brittleness

**Risk**: LLVM's `print<memoryssa>` text format may change across LLVM versions. CLAUDE.md §5 "LLVM IR is not stable".

**Mitigation**: parse defensively with regex assertions; add regression test with committed annotated-IR fixtures in `test/fixtures/memssa_*.txt`. Current memssa investigation doc (`docs/memory/memssa_investigation.md`) pins LLVM 18.1.7; flag on version drift.

### R3 — Phi resolution interaction with shadow checkpoint

**Risk**: CLAUDE.md §"Phi Resolution and Control Flow — CORRECTNESS RISK" warns of false-path sensitization. T4 shadow-checkpoint must not sensitise shadow tapes across dominance-violating paths.

**Mitigation**: diamond-CFG test in the corpus (L7 is that shape). Proposer A/B must address dominance-correctness explicitly. Draw CFG and trace by hand for each proposer design.

### R4 — Regression in gate counts

**Risk**: new MUX variants or MemSSA integration accidentally change existing gate counts.

**Mitigation**: CI guard — `benchmark/run_benchmarks.jl` compared against BENCHMARKS.md baselines at every M-gate. Core baselines in §6.6.

### R5 — Scope creep into T5

**Risk**: Bucket B cases that T4 can't cover tempt us to land T5.

**Mitigation**: explicit non-goal in §5; PRD review gate before any T5 work.

---

## 12. Key References

### Locally present (must read before implementing)

- `docs/literature/memory/SURVEY.md` — 40+ paper survey, 5-tier strategy recommendation. The canonical source for this PRD.
- `docs/literature/memory/COMPLEMENTARY_SURVEY.md` — persistent DS + reversible AD deep dive, Hybrid H1 (MemSSA+escape).
- `docs/literature/SURVEY.md` — project-wide bibliography.
- `docs/memory/shadow_design.md` — T4 shadow-checkpoint detailed design (Enzyme-style adaptation).
- `docs/memory/memssa_investigation.md` — go/no-go on MemorySSA integration, `print<memoryssa>` printer-pass parsing.
- `Bennett-VISION-PRD.md` — full v1.0 roadmap.
- `BENCHMARKS.md` — auto-generated gate-count tables.

### External references (not locally downloaded — cited via SURVEY.md summaries)

Primary:

- **[ENZYME20]** Moses-Churavy 2020, "Instead of Rewriting Foreign Code...", NeurIPS / arXiv:2010.01709. Shadow memory design — template for T4.
- **[MEULI19]** Meuli et al. 2019, "Reversible Pebbling Game for Quantum Memory Management", DATE / arXiv:1904.02121. SAT pebbling for tape compaction.
- **[BABBUSH18]** Babbush-Gidney-Berry-Wiebe 2018, "Encoding Electronic Spectra...", PRX 8:041015 / arXiv:1805.03662. QROM: 4L Toffoli, log L ancillae. Already implemented as T1b.
- **[PRS15]** Parent-Roetteler-Svore 2015, "Revs: A Reversible Compiler", arXiv:1510.00377. EAGER cleanup; MDD dependency graph.
- **[REVERC17]** Amy-Roetteler-Svore 2017, "Verified compilation of space-efficient reversible circuits", CAV. ReVerC — prior SOTA, MD5 head-to-head target.
- **[CUCCARO04]** Cuccaro-Draper-Kutin-Moulton 2004, "A New Quantum Ripple-Carry Addition Circuit", quant-ph/0410184. In-place adder — already in `src/adder.jl`.

Secondary (theoretical foundation):

- **[BENNETT89]** Bennett 1989, SIAM J. Computing. Time/Space trade-offs.
- **[KNILL95]** Knill 1995, arXiv:math/9508218. Pebble game analysis.
- **[AG13]** Axelsen-Glück 2013, LNCS 7948. Reversible heap via EXCH + linear refs. Background for deferred T5.
- **[OKASAKI99]** Okasaki 1999, JFP 9(4). Persistent red-black trees. Background for deferred T5.
- **[REQOMP24]** Paradis et al. 2024, Quantum 8:1258. Lifetime-guided uncomputation.
- **[LUBY-RACKOFF88]** Luby-Rackoff 1988, SICOMP. Feistel bijective permutation — already implemented as T3a.

**If a paper is needed for implementation (e.g. Meuli SAT encoding for T4 pebbling), download it to `docs/literature/memory/` or `docs/literature/pebbling/` before using it.**

---

## 13. Review Checklist

Before committing this PRD to main:

- [x] Scope decision documented (§5).
- [x] Success criteria numeric and verifiable (§6).
- [x] Test corpus concrete (§7).
- [x] Gate-count budgets per-bucket (§8).
- [x] Non-goals aligned with Enzyme's frontier (§9).
- [x] Milestones time-boxed and 3+1-flagged where required (§10).
- [x] Risks identified and mitigated (§11).
- [x] References cross-checked against local files (§12).
- [x] User sign-off — 2026-04-16 ("lgtm get to work").
- [ ] Reviewed against `docs/literature/memory/SURVEY.md` end-to-end (spot-checked §1, §2f, §2h during drafting; full pass still open).
- [ ] Reviewed against `docs/literature/memory/COMPLEMENTARY_SURVEY.md` end-to-end (spot-checked §Hybrid H1 + MemorySSA discussion; full pass still open).
