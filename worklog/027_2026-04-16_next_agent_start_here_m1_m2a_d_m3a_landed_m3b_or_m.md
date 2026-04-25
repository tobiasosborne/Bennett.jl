## NEXT AGENT — start here — 2026-04-16 (M1 + M2a–d + M3a landed; M3b or M2-residual next)

**Bennett-cc0 memory epic now covers the full dynamic-idx N·W > 64 corridor.
PRD + M1 + M2a + M2b + M2c + M2d + M3a landed. L0-L10 + L7a-L7g all GREEN.
MUX EXCH remains the preferred dispatch for N·W ≤ 64; the new T4 shadow-
checkpoint MVP is the universal correctness fallback. Toffoli cost is
O(N·W) per op — deliberately NOT optimised; PRD §6 primary criterion 1
(MD5 Toffoli-parity with ReVerC) is superseded for M3a per user rescope.

Next options: (1) M3b — SAT pebbling / MemSSA tape de-dup for shrinking
T4 gate cost (if MD5 becomes a headline target again); (2) T5 — unbounded
`Vector{T}` dynamic-size allocas; (3) M4 — BennettBench paper outline.
See `docs/design/m3a_consensus.md` §Deferred for the shortlist.**

### Progress tracker

- ✓ **PRD** (Bennett-ceps) — `Bennett-Memory-PRD.md`, 13 sections,
  3-bucket failure envelope, milestones M1-M4.
- ✓ **M1** — Bucket A: parametric MUX EXCH for single-UInt64 shapes
  (N·W ≤ 64). Added (2,8), (2,16), (4,16), (2,32). Dispatcher extended.
  RED tests L4/L5/L6 flipped to GREEN.
- ✓ **M2a** — Bucket C1: cross-block ptr_provenance + alloca_info
  threading. `lower_block_insts!` no longer re-initialises per-block.
  L7a, L7b GREEN. Matches existing idiom (ssa_liveness, inst_counter,
  gate_groups already per-function).
- ✓ **M2b** — Bucket C2: pointer-typed phi/select support
  (Bennett-tzb7 closed). Extractor emits `width=0` sentinel on
  `IRPhi`/`IRSelect` for pointer-typed results (no new IR structs).
  `LoweringCtx.ptr_provenance` widened to `Dict{Symbol,Vector{PtrOrigin}}`;
  single-origin fast path preserves every BENCHMARKS.md baseline,
  multi-origin fans out via `emit_shadow_store_guarded!` per origin.
  L7c, L7d GREEN.
- ✓ **M2c** — Bucket C3 shadow path: path-predicate guarding for
  conditional shadow-stores (Bennett-oio4 closed). New
  `emit_shadow_store_guarded!` (3W Toffoli per guarded store).
  `_lower_store_via_shadow!` checks `block_label == ctx.entry_label`;
  entry-block stores keep 3W CNOT path (baselines preserved). L7e GREEN.
- ✓ **M2d** — Bucket C3 MUX path: conditional MUX-store guarding
  (Bennett-i2a6 closed). New `soft_mux_store_guarded_NxW` callees for
  all 6 shapes; `pred & 1` folds into per-slot `ifelse` cond. Non-entry
  blocks dispatch to guarded callee; entry blocks stay on unguarded
  (BENCHMARKS.md unguarded rows byte-identical). L7f GREEN.
- ✓ **M3a** — Bucket A/B spillover: T4 shadow-checkpoint MVP
  (Bennett-jqyt closed). New `:shadow_checkpoint` dispatch arm triggered
  when `n*elem_w > 64` (strictly additive — no currently-GREEN shape
  migrates). `_lower_store_via_shadow_checkpoint!` fans out N guarded
  shadow stores keyed on per-slot idx-equality ANDed with block pred.
  `_lower_load_via_shadow_checkpoint!` XOR-copies primal slots under the
  same eq-wire guard into a fresh result register. Helper `_emit_idx_eq_const!`
  builds the idx==k predicate via AND-tree over bit-matches / NOT-bit-matches.
  L7g (diamond CFG × T4) GREEN, L10 (i8×256 dynamic idx) GREEN.
  BENCHMARKS.md byte-identical. Per-op gate cost O(N·W) — not competitive
  with MUX EXCH for small shapes, universal for large.
- ○ **M3b** — SAT pebbling / MemSSA tape de-dup (only if MD5 re-becomes a headline).
- ○ **M4** — BennettBench paper outline.
- ⊘ **M1b** — Multi-word MUX EXCH for N·W > 64. Deferred (T4 covers these
  universally; multi-word MUX is a separate gate-cost optimization).

### Deferred (per PRD §5 non-goals)

- T5 persistent hash-consed array (Okasaki+Mogensen). 71 kG/op exceeds
  budget; next PRD post-MD5 if a benchmark needs unbounded `Vector{T}`.
- Concurrent atomicrmw/cmpxchg, inline asm callbr, llvm.coro.*. Enzyme
  hard-stop frontier.

**Why `store` is the hardest remaining** (retained for context)

Enzyme cleanly solves dynamic mutable memory via MemorySSA + shadow
memory (O(1) per store, gradient-accumulation semantics). Bennett has
a 4-of-5-tier PATCHWORK covering specific patterns but no unified

### Why `store` is the hardest remaining

Enzyme cleanly solves dynamic mutable memory via MemorySSA + shadow
memory (O(1) per store, gradient-accumulation semantics). Bennett has
a 4-of-5-tier PATCHWORK covering specific patterns but no unified
solution for:

- `store` through a dynamically-aliased pointer into a dynamically-
  sized heap with reversible allocation + reversible free
- Runtime-growing `Vector{T}`, `Dict{K,V}`, nested mutable trees

When the pointer is dynamic-unknown-alias, reversibility demands O(heap
size) ancilla per store. MUX EXCH scales only to ~W=8, N=8. Beyond that
it's catastrophic. This is **the open research frontier** (Bennett-cc0,
P1, the only P1 issue in the tracker).

### What Bennett already has (don't re-implement)

Per `docs/literature/memory/SURVEY.md` §1, the 5-tier strategy is
partially in place:

| Tier | Strategy | File | Status | Handles |
|------|----------|------|--------|---------|
| T0 | SSA/mem2reg/escape-elim | `ir_extract.jl` `preprocess=true` kwarg | ✓ done | ~80% of stores eliminated upfront |
| T1a | MUX EXCH (small dyn idx) | `src/softmem.jl` | ✓ done | W=8, N∈{4,8} |
| T1b | QROM (read-only tables) | `src/qrom.jl` | ✓ done | Babbush-Gidney 2018, 4(L-1) Toffoli |
| T2 | MemorySSA ingest (opt-in) | `src/memssa.jl` | ✓ done | Def/Use/Phi graph |
| T3a | Feistel bijective hash | `src/feistel.jl` | ✓ done | Luby-Rackoff 1988, 8W Toffoli |
| T3b | Shadow memory (static idx) | `src/shadow_memory.jl` | ✓ done | 3W CNOT / op |
| T3c | Universal dispatch | `_pick_alloca_strategy` in `lower.jl` | ✓ done | Auto-picks cheapest correct lowering |
| T4 | Shadow checkpoint + re-exec | — | **OPEN** | Enzyme-style for complex stores |
| T5 | Persistent hash-consed array | — | **OPEN** | Truly dynamic heap (Okasaki, AG13) |

Existing memory tests: `test/test_lower_store_alloca.jl`,
`test/test_rev_memory.jl`, `test/test_store_alloca_extract.jl`,
`test/test_soft_mux_mem*.jl`, `test/test_shadow_memory.jl`,
`test/test_qrom*.jl`, `test/test_feistel.jl`,
`test/test_universal_dispatch.jl`, `test/test_mutable_array.jl`,
`test/test_memssa*.jl`. Read these before writing new tests.

### Recommended attack plan

Three milestones, roughly 1 week each. Proceed in order.

#### M1 — Write `Bennett-Memory-PRD.md` (Bennett-ceps, P2)

Before coding, land the PRD. Analogous to `Bennett-VISION-PRD.md` but
scoped to memory. Include:

1. **Scope**: which LLVM memory patterns in target (what's supported
   already, what's next, what's out-of-scope for this phase).
2. **Success criteria**: at least one patten that currently CRASHES
   must work end-to-end with `verify_reversibility` passing. Gate-count
   target: within 2× of ReVerC on MD5/SHA-2 memory patterns.
3. **Test corpus**: curate 10-15 "hard" test programs that exercise
   specific store patterns (dynamic idx, aliased pointers, nested
   `Ref{Ref{Int}}`, `Vector{T}` with `push!`, mutable recursive types).
   Build this in `test/test_memory_corpus.jl`.
4. **Benchmark targets**: ReVerC Table I/II numbers (MD5 = 27,520
   Toff / 4,769 bits). Currently Bennett's MD5 is ~48k Toff — beat
   this on the same benchmark.
5. **Non-goals**: full concurrency (atomicrmw under true concurrency),
   inline asm `callbr`. These are Enzyme hard-stops too.

Mirror the PRD structure from `Bennett-VISION-PRD.md` §§1-10.
Review against `docs/literature/memory/SURVEY.md` and
`COMPLEMENTARY_SURVEY.md` before finalizing.

#### M2 — Identify and fix the FIRST FAILING pattern

Concrete starting point: build a failing test. A candidate:

```julia
# test/test_dynamic_heap_smoke.jl
function push_and_sum(x::Int8)::Int8
    v = Int8[]
    push!(v, x)
    push!(v, x + Int8(1))
    push!(v, x + Int8(2))
    sum(v) % Int8
end

@test reversible_compile(push_and_sum, Int8) isa ReversibleCircuit
# ↑ currently CRASHES or produces wrong result. Find out which.
```

Pick the simplest failing pattern, not the most complex. Examples to
try, in increasing order of difficulty:

1. `Ref{Ref{Int}}` nested mutation (likely works via shadow; verify)
2. `Array{Int8}(undef, 4)` with dynamic `a[i] = v` (dynamic idx)
3. `Vector{Int8}()` + `push!` (dynamic size — MUX EXCH fails)
4. `Dict{Int8, Int8}()` insert/lookup (general hash map)
5. Mutable struct with self-reference (linked list)

Use `bd update Bennett-cc0 --claim` to claim, then file sub-issues for
each specific failure (e.g., `Bennett-cc0-001: Vector{Int8} push!`).

For the chosen pattern, decide strategy:

- If the pattern has a BOUND (e.g., `Vector` with max size from the
  type or a `sizehint!` call): extend T1/T3 to handle bounded dynamic
  size. Probably the cheapest win.
- If genuinely unbounded: implement T4 (shadow checkpoint + Bennett
  re-execute) or T5 (persistent tree). T4 is simpler to implement
  first; T5 is more elegant but heavier (20-70kG per access).

#### M3 — First-in-literature result

The goal per Bennett-cc0 description is: "first reversible compiler
to handle arbitrary LLVM store/alloca/memcpy." Reference comparison:
**ReVerC 2017 (Parent/Roetteler/Svore)** handles arrays with static
indices only — no pointer-based memory, no dynamic indexing, no
memcpy. Beat this on a concrete benchmark.

Target paper deliverable: PLDI / ICFP with BennettBench head-to-head
table. See SURVEY §1 for the target numbers.

### Key references (all local)

- **`docs/literature/memory/SURVEY.md`** — 40+ paper survey, 5-tier
  strategy recommendation. READ FIRST.
- **`docs/literature/memory/COMPLEMENTARY_SURVEY.md`** — persistent
  data structures + reversible AD deep dive.
- **`docs/memory/memssa_investigation.md`** — Go/no-go on MemorySSA
  integration. Shows why the opt-in flag works.
- **`docs/memory/shadow_design.md`** — shadow memory strategy doc.
- **Axelsen-Glück 2013 AG13** — EXCH-based linear heap (reversible
  malloc/free via linearity). `docs/literature/` — download if not
  local.
- **Okasaki 1999** — persistent red-black trees. Hash-consing gives
  O(log n) per access.
- **Enzyme 2020** (arXiv:2010.01709) — shadow memory at LLVM level.
  The reference Bennett is implicitly racing.

### Pattern to follow (same as Bennett-0xx3 and Bennett-t110)

1. **Red-green TDD**: failing test first, watch RED, implement, GREEN.
2. **3+1 agents for core changes**: `lower.jl` memory dispatch is
   CORE — 2 proposers + 1 implementer + orchestrator-reviewer.
   Adding new strategy files (like a persistent-tree primitive) is
   additive — single-implementer OK.
3. **Feedback every ~50 LOC**: don't code blind for 500 lines.
4. **Commit + push per milestone**, not per session. Session not
   done until `git push` succeeds (`git pull --rebase && bd dolt push
   && git push`).
5. **Gate counts are regression baselines** — WORKLOG any change.
6. **WORKLOG session log** — document gotchas, LLVM quirks, design
   choices. Future agents will thank you.

### Currently working memory benchmarks (regression baselines)

From `BENCHMARKS.md`:

| Pattern | Gates | Strategy |
|---------|------:|----------|
| QROM L=4 W=8 | 56 | T1b QROM |
| QROM L=8 W=8 | 144 | T1b QROM |
| MUX EXCH L=4 W=8 read | 7,514 | T1a |
| MUX EXCH L=4 W=8 write | 7,122 | T1a |
| Shadow static W=8 | 24 CNOT | T3b |
| Feistel W=32 | 480 | T3a |

If any of these regress, the core dispatch broke.

### Deferred roadmap (after memory epic)

The transcendental roadmap is queued but not urgent:

- Bennett-582 (`soft_log`) — next most useful; mirror of soft_exp_julia
- Bennett-3mo (`soft_sin`, `soft_cos`) — Payne-Hanek reduction
- Bennett-emv (`soft_pow`) — composed via exp(y·log(x))
- Bennett-1pb — LLVM intrinsic wiring
- Bennett-fnxg — extend subnormal-output sweep across all soft_* tests

Groundwork done (soft_fma at 447,728 gates, soft_exp_julia at
3.48M gates, both bit-exact vs Base). Foundation is solid; the
individual ports are straightforward once memory isn't the
bottleneck.

### Gate counts (current benchmark, soft-float)

| Primitive | Gates | Toffoli | T-count | Note |
|-----------|------:|--------:|--------:|------|
| soft_fma | 447,728 | 148,340 | 1,038,380 | 1.7× soft_fmul (Bennett-0xx3) |
| soft_exp_julia | 3,485,262 | 1,195,196 | 8,366,372 | 30% cheaper than soft_exp (Bennett-t110) |
| soft_exp2_julia | 2,697,734 | 890,168 | 6,231,176 | 38% cheaper than soft_exp2 (Bennett-t110) |

`Base.exp(::SoftFloat)` now dispatches to `soft_exp_julia`.

---

