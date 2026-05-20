# Paper Outline — §T5: Reversible Memory in an SSA Compiler

**Bead:** Bennett-6siy  
**Tentative title:** "Reversible Memory in an SSA Compiler"  
**Target venue:** PLDI / ICFP  
**Status (2026-05-20):** outline only — data from T5-P7a (Bennett-ktt8) now in hand.

---

## Central contribution: tiered per-allocation-site dispatch

Every `alloca` in the LLVM IR is classified by shape (static vs dynamic index,
size, read-only vs mutable) and routed to the cheapest correct lowering strategy:

| Tier | Strategy | Trigger | Per-store cost | Paper anchor |
|------|----------|---------|----------------|--------------|
| T1b | MUX EXCH | dynamic idx, N·W ≤ 64 | see BENCHMARKS.md | — |
| T1c | QROM | read-only global constant table | 4(L-1) Toffoli | Babbush-Gidney 2018 |
| T3a | Feistel hash | reversible bijective key hash | 8·W Toffoli | Luby-Rackoff 1988 |
| T3b | Shadow memory | static idx, any shape | 3·W CNOT | Enzyme-adapted (Moses & Churavy 2020) |
| T5 | Persistent-DS | runtime-unbounded mutable memory | see §T5 below | — |

The dispatch is **automatic**: the compiler inspects `_pick_alloca_strategy` per
allocation site with no user annotation required. Strategies compose across a
single function (e.g., a static-idx store followed by a dynamic-idx load routes
through shadow then MUX EXCH end-to-end). This is the core publishable result:
**the first reversible compiler that handles the full LLVM `store`/`alloca`
envelope for arbitrary pure deterministic programs**, not just user-scoped
registers or arrays with static indices.

---

## Framing: "The Enzyme of reversible computation"

Enzyme (Moses & Churavy 2020) demonstrated that automatic differentiation can be
total over differentiable LLVM — any LLVM frontend (C, C++, Rust, Fortran, Julia)
produces IR that Enzyme can differentiate. Bennett.jl makes the analogous claim for
reversibility.

| Enzyme (AD) | Bennett.jl (Reversible) |
|---|---|
| Tape compaction via dead-derivative elimination | Persistent-DS version chain as the tape |
| Shadow heap matches primal heap shape | Persistent-DS heap embeds the version chain |
| Reverse pass walks the tape in reverse | Reverse pass uncomputes the IRCall chain |
| `@enzyme_custom_rule` for opaque externals | `register_callee!` for opaque externals |
| Activity analysis prunes inactive shadows | T0 SROA/mem2reg prunes inactive allocas |
| Works across C / C++ / Rust / Fortran / Julia | Works across C / C++ / Rust / Julia via `.ll`/`.bc` (T5-P5) |

The `register_callee!(f)` escape hatch is the reversibility analogue of
`@enzyme_custom_rule`: users can inject gate-level implementations for any
external function that the compiler cannot lower automatically (e.g., system
calls, I/O, user-defined irreversible primitives with known inverses).

Multi-language ingest (T5-P5, Bennett-lmkb/f2p9) ships as
`extract_parsed_ir_from_ll` and `extract_parsed_ir_from_bc`: any LLVM-frontend
language (C via `clang -emit-llvm`, Rust via `rustc --emit=llvm-ir`, C++ via
`clang++`, Fortran via `flang`) can be compiled to `.ll`/`.bc` and fed directly
into the Bennett.jl pipeline. The multi-language T5 corpus
(`test/test_t5_corpus_c.jl`, `test_t5_corpus_rust.jl`, `test_t5_corpus_julia.jl`)
provides the empirical grounding for this claim.

---

## §T5 section outline

### 1. Introduction

- **Problem:** Every prior reversible compiler (ReVerC, Quipper, ProjectQ, Silq,
  Unqomp, ReQomp, Qurts) restricts to user-scoped registers or arrays with static
  indices. Runtime-dynamic heap accesses (`Vector{T}`, `Dict{K,V}`, pointer-chased
  trees) are out of scope for all of them.
- **Claim:** Bennett.jl handles the full LLVM `store`/`alloca` envelope for
  arbitrary pure deterministic programs, with automatic per-allocation-site strategy
  dispatch, verified correct on a multi-language corpus (Julia, C, Rust).
- **Key result (T5-P7a):** The persistent-DS tier's `:linear_scan` implementation is
  at the per-`set` gate floor (1,152–1,444 gates at W=8), flat in operation depth —
  the branchless slot-preserve lowering compresses to ~constant cost.

### 2. Prior work

- Reversible circuit compilers: ReVerC (Parent/Roetteler/Svore 2017), Quipper,
  Silq, Unqomp (Paradis 2021), ReQomp (Paradis 2024).
- Automatic differentiation via LLVM: Enzyme (Moses & Churavy 2020).
- Memory reversibility: Bennett 1973 (ancilla cleanup), Knill 1995 (pebble game),
  PRS15 (EAGER cleanup), Reqomp (lifetime-guided uncomputation).
- Persistent data structures: Okasaki 1998 (red-black trees), Bagwell 2001 (HAMT),
  Conchon-Filliâtre 2007 (semi-persistent arrays).

### 3. The MemorySSA approach

- LLVM MemorySSA provides a Def/Use graph over memory operations without pointer
  aliasing analysis. Bennett.jl ingests MemorySSA annotations (opt-in,
  `use_memory_ssa=true`) to guide conditional-store lowering decisions.
- The universal dispatcher `_pick_alloca_strategy` classifies each alloca by shape
  and routes to the cheapest strategy without user annotation.
- Non-entry-block stores (the diamond-CFG pattern: `if cond { map.set(k, v) }`) are
  handled via output-MUX guarding (Bennett-smjd): the post-call state is MUX'd
  against the pre-state using the block's path predicate, preserving correctness
  when the branch is not taken.

### 4. Tiered dispatch

Describe each tier in order, with gate-cost formulas and paper anchors (see table
above). Emphasise that each tier is a conservative fallback for the one above: QROM
< MUX EXCH < Feistel < Shadow < Persistent-DS (by generality, not cost).

Key architectural decision: `register_callee!(f)` inlines user-provided gate
sequences for named Julia functions, short-circuiting the LLVM extraction path.
The persistent-DS callees (`linear_scan_pmap_set`, `linear_scan_pmap_get`, etc.) are
registered this way — the compiler lowers calls to them as first-class gate blocks
rather than recursively extracting their IR.

### 5. Benchmarks

- **T5-P7a Pareto sweep** (2026-05-20): 64-cell `impl × W × depth` sweep,
  `optimize=false`, `verify_reversibility` + oracle per cell.
  - `:linear_scan` wins every (W=8, depth) cell.
  - Gate count flat in depth: 1,152 (depth=3) to 1,444 (depth=8..128).
  - `:cf` 2nd: 9,594–1,142,194 (8–791× worse).
  - `:okasaki` worst: 53,682–3,466,432 (47–2,400× worse).
  - Key insight: CPU-cheap primitives (tree balance, popcount, pointer deref) are
    gate-expensive. The right reversible DS matches what Bennett.jl can compress: a
    single target slot with N-1 no-op preserves (linear scan's `ifelse` pattern).
- **Cross-strategy comparison** (diamond-CFG workload, Bennett-smjd):
  - Persistent (`:linear_scan`, 4-slot slab, output-MUX guard): 3,718 gates.
  - Shadow (`:shadow_checkpoint`, 256-slot array): 40,502 gates.
  - Ratio: persistent ≈ 0.09× shadow at this workload.
- **Headline numbers** for the paper abstract:
  - `:linear_scan` at W=8, depth=128: 1,444 gates / 134 Toffoli / 2,005 ancillae.
  - All ancillae verified zero (Bennett's invariant) on every cell.

### 6. Conclusion

- Bennett.jl is the first reversible compiler to handle runtime-unbounded mutable
  memory via a provably non-bottom T5 fallback, closing the proof that reversible
  compilation is total over deterministic LLVM.
- The "Enzyme of reversibility" framing is empirically grounded: the multi-language
  corpus exercises the claim across Julia, C (via clang), and Rust (via rustc).
- Open work: wide-W persistent callees (Bennett-8o70), HAMT `optimize=false`
  compatibility (Bennett-7sb7), HAMT mod-32 collision correctness (Bennett-2xws),
  Rust corpus LLVM-version skew (Bennett-n88f).

---

## Data sources (verify before final draft)

- Gate counts: `benchmark/bc_t5_head_to_head_results.jsonl` (T5-P7a canonical).
- Diamond-CFG cross-strategy: worklog/071 Bennett-smjd entry, gotcha 4.
- Wide-W error messages: same jsonl, `ok=false` cells.
- Multi-language ingest: worklog/030 (Bennett-lmkb + f2p9).
- Persistent-DS scaling sweep: `benchmark/sweep_persistent_summary.md` + BENCHMARKS.md.
