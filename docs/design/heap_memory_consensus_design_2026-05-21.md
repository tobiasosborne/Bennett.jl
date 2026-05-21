# Bennett.jl — Julia Heap-Memory Support: Consensus Design

**Date:** 2026-05-21
**Process:** 3+1 design protocol — 2 independent architects (A, B) + orchestrator
synthesis (+1) + an empirical validation spike. Design-only round; no code.
**Inputs:** `heap_memory_design_brief_2026-05-21.md` (problem statement).
**Status:** validated design, ready to be split into delegated implementation
milestones. This is design-only — no code was written.

---

## 1. Verdict — tractability

**(c) Partially tractable.** A reversible circuit has a compile-time-fixed wire
count; a `Vector` with a runtime-dependent `push!` count cannot map onto it —
**unbounded growth is rejected, fail-loud, no exceptions.** But a large and
useful subset *is* tractable, and the empirical spike (below) proved it does
**not** require modelling the Julia heap at all.

## 2. The validated key insight

Architect B dumped the optimized LLVM IR (`optimize=true`) and observed — and
the validation spike then confirmed across 5 distinct shapes — that **for
statically-shaped heap usage the optimizer has already compiled the collection
away**. The element accesses survive as plain `store`/`load` at compile-time
constant offsets (or runtime indices into a constant-capacity buffer); the GC
machinery — the inline-asm TLS read, `@ijl_gc_small_alloc`, the `j_#_growend!`
calls, the size-counter stores, the `memoryref` pointer arithmetic — is **dead
with respect to the return value**.

Spike results (Julia 1.12.5, `optimize=true`):

| Shape | skeleton dead w.r.t. return? | re-rootable onto a fixed buffer? |
|---|---|---|
| f1 `v=Int8[]; push!(v,x); v[1]` | YES (`ret %x` directly) | trivially |
| f2 `push!×3; reduce(+,v)` (TJ1) | YES (loads read back `x`-derived values) | yes, 3-elem buffer |
| f3 `push!`-in-branch; `reduce` | YES | yes, 2-elem 2-variant shape |
| f4 `Array(undef,8)`; const writes; runtime-index read | YES (alloc ptr is a pure buffer base) | yes, 8-elem buffer, runtime index |
| f5 `push!` in a runtime loop | n/a — **correctly rejected** (runtime trip count) | no static shape |

The hypothesis held for every static shape and the false-case detector (f5)
fired correctly.

## 3. Architecture — adopt Design B (extraction-only skeleton-stripping)

**The design recognises the GC/heap skeleton by its structural signature,
proves it dead w.r.t. the return (conservatively, bail-loud), strips it, and
re-roots the surviving stores/loads onto a synthetic constant-capacity
`IRAlloca` — which the existing `:shadow` / `:mux_exch` / `:shadow_checkpoint`
lowering compiles unchanged.**

**All new logic lives in IR extraction. Lowering is untouched.**

### Why B over A

Architect A proposed a heavier machine: a new `IRHeapAlloc` node, modelling the
`Memory{T}` struct layout, and a `_recognised_collection_ops` table that
intercepts `push!`/`reduce` as semantic operations. A itself flagged its single
biggest risk: *`push!` may be inlined, leaving no callee to intercept.* The
spike shows that risk is fatal to A's framing — and that B's framing **dissolves
it**: after inlining there is no `push!` callee, but the residue is exactly the
constant-offset store pattern B recognises. B reuses Bennett's most-tested
machinery (`:shadow`) and adds **no new IR node, no lowering change, no
`register_callee!` extension, no `Memory{T}` model**. It is the smaller, more
defensible design — what a senior engineer ships.

A's contributions kept: milestone granularity (constant-N `Array(undef)` is a
clean early milestone, separate from `push!`-built `Vector`); `reduce` flagged
as a risk surface for larger vectors / non-arithmetic reducers; the opt-in
`mem=` mode so default behaviour is unchanged.

### Answers to the six brief questions

- **Q1 (inline-asm TLS).** A new extraction pre-pass `_detect_gc_preamble!`
  pattern-matches the stereotyped idiom (`call ptr asm "movq %fs:0, $0"` + the
  `-8` GEP + the `load` + GC-frame chaining). The exact asm string is the
  *only* entry in a new `_GC_TLS_ASM_ALLOWLIST`; every other inline-asm still
  hits the existing U15 fail-loud guard. The preamble's instructions are
  dropped (extending the established benign-drop precedent for
  `julia.push/pop_gc_frame`). **Safety gate:** compute the taint set of
  everything derived from `%thread_ptr`; assert it reaches user data *only*
  through the `@ijl_gc_small_alloc` ptls argument — never through the
  allocator's return or any arithmetic/icmp/user-store. If the taint partition
  cannot be proven, **reject loud** ("GC preamble taint reaches user data").
- **Q2 (`@ijl_gc_small_alloc`).** Recognised by the call + the 3-store init
  idiom. **Capacity is inferred from use sites, NOT from the `i32` size operand**
  (that operand is the `jl_array_t` *header* size, 32 bytes — a known
  cc0.5-class trap). A synthetic `IRAlloca(_, elem_width, ConstOperand(n))` is
  emitted, keyed on the backing data pointer; `n` = (count of distinct constant
  element offsets) for `push!`-Vectors, or the constant `N` for
  `Array{T}(undef,N)`. No `Memory{T}` layout is modelled beyond the one
  data-pointer indirection needed to resolve element GEPs.
- **Q3 (irreversible `growend!`/`setindex!`).** **High-level, but neither
  "model the heap" nor "substitute a persistent op" — the third option: the
  `growend!` calls, size-counter stores, capacity `icmp`/`br` diamonds and
  `memoryref` arithmetic are *dead skeleton* and are dropped**, gated by the
  dead-skeleton liveness proof. `growend!` is never registered, never lowered.
  `Dict`'s `j_setindex!` is **not** dead skeleton (its hashing feeds the
  return) → `Dict` is out of scope, rejected loud.
- **Q4 (capacity bound).** Static inference, read off the IR (the constant
  offset set, or the `undef,N` constant). No user kwarg in the MVP — the bound
  is *read*, not *asserted* (YAGNI; a `capacity=` escape hatch is a documented
  future option only if inference proves brittle). Persistent-tier `max_n`
  silent-clamp is explicitly **not** used (silent clamp = silent miscompile).
- **Q5 (TJ4 mirage).** Acknowledged; not a compiler concern. TJ4-as-written
  (`a[i]=x; a[i]`, same index) store-to-load-folds to `ret x`. The corpus
  fixture is rewritten with distinct indices (`Bennett-890r`); the design's
  milestone tests use distinct store/load indices.
- **Q6 (persistent-DS as target).** No. The synthetic alloca is *constant*-n →
  routes to `_lower_alloca_const_n!` and `:shadow`/`:mux`/`:checkpoint`. The
  persistent tier is for genuinely dynamic-n, which this design rejects.

### New abstractions (all in extraction)

| Abstraction | Location |
|---|---|
| `_detect_gc_preamble!` — pre-pass; recognise+drop the TLS/GC-frame idiom | new `src/extract/heap.jl` |
| `_synthesize_heap_alloca!` — recognise `@ijl_gc_small_alloc`; infer capacity; emit synthetic `IRAlloca`; mark skeleton dead | `src/extract/heap.jl` |
| dead-skeleton liveness proof — conservative, bail-loud | `src/extract/heap.jl` |
| `_GC_TLS_ASM_ALLOWLIST` — 1-entry const set | `src/extract/instructions.jl` |
| `mem=:heap` — opt-in mode; default `mem=:auto` unchanged | `src/Bennett.jl`, `src/lowering/driver.jl` |

**No new IR node** (synthetic alloca reuses `IRAlloca`). **No lowering change.**
**No `register_callee!` change.** **`src/lowering/memory.jl` untouched.**

### Constraint compliance

Fail-loud: the liveness proof and every unrecognised shape reject loud.
Ancilla-zero: the synthetic alloca is a normal `IRAlloca` — `:shadow` already
satisfies it. Bounded wire count: capacity is compile-time-constant. No
irreversible realloc: `growend!` is dropped as proven-dead, never lowered.

## 4. Implementation roadmap — 4 milestones (future delegated coding tasks)

Each milestone is independently buildable + red-green testable. **Each is a
future delegated effort — none is implemented in this design round.**

**M1 — GC-preamble recognition + dead-skeleton infrastructure.**
`_detect_gc_preamble!`, the `_GC_TLS_ASM_ALLOWLIST`, the taint/liveness proof,
the `mem=:heap` opt-in mode. Smallest real result: f1
(`v=Int8[]; push!(v,x); v[1]`, which the optimizer already reduces to `ret x`)
compiles green under `mem=:heap`. Files: `src/extract/instructions.jl`, new
`src/extract/heap.jl`, `src/Bennett.jl`, `src/lowering/driver.jl`. **3+1
required** — core extraction change; the taint-proof correctness is the subtle
part. Difficulty: medium-high.

**M2 — `Array{T}(undef, const_N)` (the f4 shape — no `growend!`).** Recognise
the two `@ijl_gc_small_alloc` calls (Memory + Array wrapper), synthesise a
const-N `IRAlloca`, route constant-offset stores and runtime-indexed loads to
the existing `:shadow`/`:mux`/`:checkpoint` strategies. Test: f4-shape with
*distinct* store/load indices, oracle-verified. **3+1 required** — core
extraction. Difficulty: high (the data-pointer indirection). Note: this also
makes the redesigned TJ4 (`Bennett-890r`) reachable.

**M3 — `push!`-built `Vector` with statically-inferable count (TJ1 green).**
Handle the `growend!` calls, size-counter stores and capacity-branch diamonds
as dead skeleton; infer capacity from the constant-offset store set. Makes
`f_tj1` genuinely green (real 3-element circuit, oracle `3x+3`). Files:
`src/extract/heap.jl`. **3+1 required** — the `growend!`-drop + diamond-collapse
is the conceptual core. Difficulty: high.

**M4 — fail-loud scope hardening + corpus/test reconciliation.** Precise
rejections for: runtime-loop `push!` (f5), `Dict` (TJ2), runtime-N `Array`,
nested/non-bits element types. Flip TJ1 `@test_throws`→green; keep TJ2 rejected;
rewrite TJ4 (`Bennett-890r`). **Reconcile `cond_pair`**: under
`--check-bounds=yes` it emits a heap skeleton identical to f4 and is currently
`@test_throws` (U15 inline-asm reject) — once M1/M2 land the recogniser engages
and (its skeleton being dead) it should compile *correctly*; that
`@test_throws` assertion flips to a green oracle check. Difficulty: low-medium.
Standard review.

`Dict` support is **not** a milestone — it is a separate research program
(`j_setindex!` hashing is live, not dead skeleton).

## 5. Scope boundary

**Supported (end state after M4):** `Vector{T}`/`Array{T}` of a concrete
integer `T`, with a statically-known shape — fixed `push!` count or
`Array{T}(undef, const_N)`; `getindex`/`setindex!`/`reduce` over it. **TJ1 goes
genuinely green.**

**Rejected, fail-loud:** `Dict` (TJ2 stays rejected); unbounded / runtime-count
`push!` (f5); `Array{T}(undef, runtime_N)`; nested / non-bits element types;
mid-array `insert!`/`deleteat!`; C/Rust `malloc` heap (different IR idiom).

**T5 corpus end state:** TJ1 green; TJ2 rejected (loud, documented); TJ3 already
green; TJ4 rewritten (`Bennett-890r`), green only in its fixed-shape form.

## 6. Risks

**Biggest risk — the dead-skeleton liveness proof must be sound.** If a
heap-use pattern exists where the skeleton genuinely feeds the return and the
proof misjudges it dead, that is a silent miscompile (worst CLAUDE.md §1
violation). Mitigation: the proof is *conservative and bail-loud* — any taint
ambiguity rejects. The spike audited 5 shapes; M1's 3+1 must stress it against
shapes not audited (push-in-nested-branch, a vector escaping into a callee,
vector-of-tuples).

**Other risks:** Julia-version fragility — the GC-preamble / `Memory{T}` idiom
is Julia-1.12-specific; the recogniser must fail-loud (never miscompile) on an
unrecognised preamble shape, and should assert the layout against
`fieldoffset`/`sizeof`. Capacity-branch diamond collapse — confirm the
post-drop phis converge (M2/M3). `reduce` codegen variance — fine for TJ1
(plain loads+adds, per the spike) but a larger vector / non-arithmetic reducer
may lower to a loop or callee; verify before relying on it. `growend!`
mangled-name (`@"j_#_growend!##0_NNN"`) matching — regex audit needed.

**The gate is already passed:** the validation spike was the cc0.5-style
de-risking step both architects demanded *before* committing implementation.
It confirmed the hypothesis. M1 may be scheduled.
