## Session log — 2026-04-16 — M2b Bucket C2 pointer-typed phi/select (Bennett-tzb7)

Landed pointer-typed phi and select. Previously both crashed at
`ir_extract.jl` with "Unsupported LLVM type for width:
LLVM.PointerType(ptr)" because `_type_width` hard-errored on pointer
types; now they flow through as `width=0` sentinel on existing
`IRPhi`/`IRSelect`, and lowering routes them via a widened
multi-origin `ptr_provenance`. 3+1 agent protocol invoked per
CLAUDE.md §2 (core-pipeline change touching `ir_extract.jl`,
`ir_types.jl`, `lower.jl`, phi resolution).

### 3+1 protocol outcome

Two proposers spawned in parallel with divergent framings. Orchestrator
synthesis (`docs/design/m2b_consensus.md`) chose:

- **Extraction**: B's sentinel `width=0` on existing `IRPhi`/`IRSelect`
  (smaller blast radius than A's new `IRPtrPhi`/`IRPtrSelect` structs;
  grep confirms `IRPhi` is referenced at ~6 sites across the compiler).
- **Data model**: A's single-map `Dict{Symbol,Vector{PtrOrigin}}`
  (rejected B's dual-map approach — one source of truth is easier to
  reason about).
- **Per-origin predicate**: A's eager `predicate_wire::Int` (simpler;
  laziness isn't needed for L7c/L7d).
- **MemSSA wiring**: skipped entirely (M2a lesson: MemSSA addresses
  only 1 of 3 sub-issues, and PRD R2 text-parse brittleness isn't worth
  paying for correctness — keep as opt-in optimisation layer).

Implementer (this session) followed the synthesis; no design
deviations needed.

### Implementation

`src/ir_types.jl`:
  - NEW `PtrOrigin(alloca_dest, idx_op, predicate_wire)` struct.
    `ptr_provenance[name]::Vector{PtrOrigin}` — one origin per possible
    alloca the pointer might reference at runtime, each guarded by a
    1-wire path predicate.

`src/ir_extract.jl`:
  - Phi + select handlers: compute `w = value_type isa PointerType ? 0
    : _iwidth(inst)`. `_type_width` / `_iwidth` stay fail-loud for any
    other unexpected pointer use.

`src/lower.jl`:
  - `LoweringCtx.ptr_provenance` widened from
    `Dict{Symbol,Tuple{Symbol,IROperand}}` to
    `Dict{Symbol,Vector{PtrOrigin}}`. All three constructors updated.
    Defaults in `lower()` and `lower_block_insts!` kwargs follow.
  - NEW `_entry_predicate_wire(ctx)` helper fetches the always-1
    entry-block predicate wire; `lower_alloca!` seeds single-origin
    producers with this guard, preserving the pre-M2b semantics
    (entry_pred = 1 at runtime, so AND(entry_pred, x) = x).
  - `lower_ptr_offset!` / `lower_var_gep!` iterate over existing
    origins, bumping the `idx_op` per origin (preserves predicate).
  - NEW `_edge_predicate!(gates, wa, src, phi_block, block_pred,
    branch_info)` factored out of `resolve_phi_predicated!` —
    pure refactor, identical gate emission.
  - `lower_phi!` and `lower_select!` branch at the top on
    `inst.width == 0`. The ptr path merges origins from each incoming
    side, AND-ing each origin's own guard with the edge predicate
    (for phi) or cond / NOT(cond) (for select). No wires allocated
    for a "ptr value"; no `vw[inst.dest]` entry.
  - `lower_store!` split: single-origin fast path (`length(origins)
    == 1`) calls new `_lower_store_single_origin!` which wraps the
    pre-M2b dispatch body verbatim — byte-identical baselines. Multi-
    origin path fans out calling new `_emit_store_via_shadow_guarded!`
    per origin with `o.predicate_wire` as the guard. Dynamic idx with
    >1 origin, or fan-out > 8 origins, hard-errors (filed as future
    work in the error message).
  - `lower_load!` similar: single-origin unchanged; multi-origin via
    new `_lower_load_multi_origin!` which allocates a fresh W-wire
    result (zero by WireAllocator invariant) and emits
    `ToffoliGate(o.predicate_wire, primal[i], result[i])` per origin
    per bit. At runtime exactly one predicate is 1, so exactly one
    origin's slot XORs into the zero-initialised result.

`src/Bennett.jl`:
  - `_narrow_inst(IRPhi, W)` / `_narrow_inst(IRSelect, W)` guards
    with `inst.width == 0 ? inst : ...` so ptr-phi/ptr-select pass
    through whole-function narrowing untouched.

`test/test_memory_corpus.jl`:
  - **L7c** flipped `@test_throws Exception` → `@test
    verify_reversibility(c)` + 2D sweep over `x in Int8(-8):2:Int8(8),
    cbit in (false, true)` → 18 inputs.
  - **L7d** same.

### Gate-count invariants preserved

`BENCHMARKS.md` regenerated (`julia --project benchmark/run_benchmarks.jl`)
and `git diff BENCHMARKS.md` is empty — byte-identical to the committed
baseline. Every invariant from consensus §11:
  - i8 adder = 100 gates / 28 Toff
  - i16 = 204 / 60 Toff
  - i32 = 412 / 124 Toff
  - i64 = 828 / 252 Toff
  - soft_fma = 447,728 / 148,340 Toff
  - soft_exp_julia = 3,485,262 / 1,195,196 Toff
  - Shadow W=8 = 24 CNOT / 0 Toff
  - All MUX EXCH variants byte-identical

This is what the single-origin fast path buys: every pre-M2b test
lowered through allocas with a 1-Vector of PtrOrigin (predicate_wire =
entry predicate). `_lower_store_single_origin!` wraps the exact same
dispatch body, so the emitted gates are identical.

### L7c / L7d gate counts (actual Bennett-wrapped circuits)

- **L7c** (phi ptr, diamond CFG): 156 gates (4 NOT, 14 CNOT, 138
  Toffoli). Consensus §6.3 estimate was ~71 forward gates; the
  Bennett wrap roughly doubles (forward + copy-out + reverse), so 156
  ≈ 2·(71) + 14 copy-out, which is on the money.
- **L7d** (select ptr, single-block): 146 gates (4 NOT, 10 CNOT, 132
  Toffoli). Consensus estimate ~68 forward → 146 ≈ 2·68 + 10.

Both pass `verify_reversibility` and return `x` for every `(x, c)`
input combination.

### Tests

- **L7c** GREEN. **L7d** GREEN.
- L0-L7b, L7e GREEN (regression). L7f still @test_broken (M2d scope).
  L8 GREEN. L9, L10 RED (M3, M1b scope respectively).
- Full suite: `julia --project -e 'using Pkg; Pkg.test()'` → all tests
  passed.

### Gotchas learned

- **`lower_select!` needs `ctx` not just dicts**: the existing
  signature was `lower_select!(gates, wa, vw, inst)`. For ptr-select
  we need the full `ctx.ptr_provenance` threading. Added a
  `ctx::Union{Nothing,LoweringCtx}=nothing` kwarg; dispatcher at line
  129 passes `ctx=ctx`; integer path is unchanged (ctx defaults to
  nothing, code doesn't reference it). This pattern mirrors how
  `lower_load!`/`lower_store!`/`lower_alloca!` take `ctx` directly.

- **Phi dispatcher signature change**: `lower_phi!` gained a
  `ptr_provenance` kwarg with `Union{Nothing,Dict{...}}=nothing`
  default. Integer path ignores it; ptr path hard-errors if `nothing`
  (should be impossible since `_lower_inst!` always passes it).

- **`_entry_predicate_wire` fail-fast for sentinel callers**: direct
  `lower_block_insts!` callers that pass `entry_label = Symbol("")`
  would crash on first `lower_alloca!`. This is intentional — any
  such direct caller has always been the "backward-compat for tests"
  escape hatch and the tests in question don't use pointers. If a
  downstream project hits this, they need to pass `entry_label`.

- **Mutual exclusion is invariant, not enforced**: for L7c the two
  origins' predicates are `AND(entry, c)` and `AND(entry, NOT c)` —
  pairwise exclusive by construction (M2c's `_compute_block_pred!`
  guarantees). For L7d: `c` and `NOT c` — trivially exclusive. So
  exactly one origin's guard fires; the other's Toffolis no-op. If
  we ever had two ptr-phi incoming from the SAME incoming block,
  their edge predicates would overlap → undefined semantics. Filed
  in the fan-out error messages that nested ptr-phi through non-
  diamond CFGs is deferred.

- **Bennett reverse correctness across multi-origin**: each origin
  writes to a physically distinct primal slot (different
  `alloca_dest` → different wire range). Tapes are fresh per
  guarded store. So the reverse pass unwinds each origin's guarded
  Toffolis in reverse order, and pred=0 branches no-op both forward
  and reverse symmetrically. No cross-origin interference; no
  ancilla hygiene violations. Every test passes `verify_reversibility`.

### Filed for follow-up

- **Multi-origin + dynamic idx**: currently hard-errors with a clear
  message. Needs either fan-out of MUX EXCH calls (N origins × M
  shapes) or an exchange-then-MUX collapse. File a bd issue when
  a benchmark hits it.
- **N ≥ 3 origin chains**: design handles N structurally, but the
  `length(origins) ≤ 8` guard errors past that budget. File when
  needed.
- **Nested ptr-phi across non-diamond CFG (loop-back)**: hard-error
  in the edge-predicate path (via `_edge_predicate!` calling
  `block_pred[src_block]` for any unresolved src). File when needed.
- **Pointer phi with non-alloca origin** (e.g. global ptr, ptr
  parameter): hard-errors via `haskey(ptr_provenance, val.name)`
  check. File if a benchmark needs it.

### Next agent steps

1. **M2d** (Bennett-i2a6) — MUX-store path-predicate guarding. Same
   problem as M2c but for dynamic-idx stores. CORE CHANGE → 3+1.
2. **M3** — T4 shadow-checkpoint + re-exec (original PRD plan).
   Depends on M2c's path-predicate threading pattern (now available).

---

## Session log — 2026-04-16 — Bennett-Memory-PRD.md drafted (Bennett-ceps)

Claimed Bennett-ceps and landed draft `Bennett-Memory-PRD.md` (this
repo root). Mirrors `Bennett-VISION-PRD.md` structure but scoped to
reversible mutable memory.

### Deep research phase (2 parallel Explore agents + bd + direct reads)

- **Codebase agent** inventoried every tier with `file:line` citations.
  Key findings verified against source: dispatcher at `src/lower.jl:1790`
  picks `:shadow` / `:mux_exch_{4,8}x8` / `:unsupported`; hard rejection
  sites at `:1759` (dynamic n_elems), `:1817` (const-pointer store),
  `:1820` (no provenance for store ptr), `:1836` and `:1533`
  (unsupported shape for dynamic idx).
- **Literature agent** mapped the 5-tier strategy from
  `docs/literature/memory/SURVEY.md` §1 onto the existing code.
  Both agents independently identified MemorySSA-wiring and T4
  shadow-checkpoint as the two highest-leverage next moves.

### Failure envelope — three buckets (verbatim from PRD §4)

- **Bucket A** — shape gap (dynamic idx, (N,W) ∉ {(8,4),(8,8)}):
  `Array{Int16}(undef, 4)` dynamic-idx crashes at `src/lower.jl:1836`.
  Fix = parametric MUX EXCH extension.
- **Bucket B** — dynamic-size gap (`Vector{T}()` + `push!`, Dict):
  crashes at `src/lower.jl:1759` "dynamic n_elems not supported".
  Fix = T4 shadow-checkpoint (bounded), T5 persistent tree (unbounded).
- **Bucket C** — dataflow gap (phi-merged pointer, no ptr_provenance):
  store crashes at `src/lower.jl:1820`; load falls through to legacy.
  Fix = wire `MemSSAInfo` into `_pick_alloca_strategy`.

### Gotchas learned (for future agents)

- **Agents hallucinate paper paths.** Both Explore agents claimed
  `docs/literature/memory/reverc-2017.pdf`, `Okasaki1999_redblack.pdf`,
  `enzyme/Moses2020_enzyme.pdf` exist — none do. The memory/ subdir
  contains ONLY `SURVEY.md` and `COMPLEMENTARY_SURVEY.md`. Always
  verify `ls` before citing PDFs in a PRD. Per MEMORY.md
  `feedback_ground_truth.md`: no hallucinated paper patterns.

- **`preprocess=false` is the default**, not `true`. One agent reported
  T0 as "default-on". Verified at `src/ir_extract.jl:26`:
  `extract_parsed_ir(f, arg_types; optimize=true, preprocess=false, ...)`.

- **Load rejection is nuanced.** `lower_load!` at `src/lower.jl:1512`
  falls through to legacy primitive when `ptr_provenance` is missing;
  only errors on shape mismatch. Stores always hard-error on missing
  provenance. Bucket C thus asymmetrically affects stores.

- **T2 MemorySSA ingest exists but is NOT YET CONSUMED** by
  `_pick_alloca_strategy`. It's parsed into `MemSSAInfo` metadata and
  left unused. This is the specific wiring that M2 delivers.

- **Budget** per `SURVEY.md` §1: ≤20 kGates per memory op. T4 must
  stay within this for the MD5 benchmark.

### Milestones (PRD §10)

1. **M1** Bucket A: parametric MUX EXCH for (N, W) ∈ {2,4,8,16,32} × {8,16,32}. Additive, single-implementer.
2. **M2** Bucket C: wire MemorySSA into dispatcher. Core change to `lower.jl` + `ir_extract.jl` → **3+1 agents** per CLAUDE.md §2.
3. **M3** Bucket B (partial): T4 shadow-checkpoint + re-exec per `docs/memory/shadow_design.md`. Meuli-SAT pebbled. New strategy tier → **3+1 agents**. MD5 head-to-head vs ReVerC 27,520 Toff.
4. **M4** BennettBench paper outline (PLDI/ICFP, Bennett-6siy).

### Explicitly deferred

- **T5 persistent hash-consed array** (Okasaki+Mogensen). 71 kG/op
  prototype exceeds budget. Next PRD post-MD5 if a benchmark needs
  unbounded `Vector{T}`.
- Concurrent `atomicrmw`/`cmpxchg`/`fence`, inline asm `callbr`,
  `llvm.coro.*`, complex SEH. Matches Enzyme's hard-stop frontier.

### Next agent steps

1. Read `Bennett-Memory-PRD.md` end-to-end.
2. Review against `docs/literature/memory/SURVEY.md` and
   `COMPLEMENTARY_SURVEY.md` (PRD §13 checklist items left open).
3. Get user sign-off.
4. Start M1: red tests for L4/L5/L6 in new `test/test_memory_corpus.jl`.

---

