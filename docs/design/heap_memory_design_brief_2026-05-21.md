# Bennett.jl Design Problem Brief — Julia Heap-Allocated Memory Support

**Date:** 2026-05-21
**Status:** problem statement for a 3+1 design effort (2 independent architects).
**Mandate:** state the problem precisely; do NOT propose a design here.

Bennett.jl compiles pure Julia functions into reversible circuits (NOT/CNOT/
Toffoli) via LLVM IR. It handles stack-allocated arrays (`alloca`-backed, static
size), soft-float, and a persistent-map tier (`mem=:persistent`) for dynamic-
index allocas. It does **not** handle Julia heap memory — `Vector{T}`,
`Dict{K,V}`, `Array{T}(undef,N)` with runtime N — because Julia's codegen for
these passes through three walls the extractor rejects.

---

## Section 1 — The three walls

Test function:
```julia
f(x::Int8) = let v=Int8[]; push!(v,x); push!(v,x+1); push!(v,x+2); reduce(+,v) end
```
`code_llvm(f, (Int8,); optimize=true)` — IR captured & confirmed 2026-05-21.

### Wall 1 — inline-asm TLS read
```llvm
%thread_ptr   = call ptr asm "movq %fs:0, $0", "=r"() #13
%tls_ppgcstack = getelementptr inbounds i8, ptr %thread_ptr, i64 -8
%tls_pgcstack  = load ptr, ptr %tls_ppgcstack, align 8
```
x86-64 TLS read fetching the current task's GC stack root. Emitted
unconditionally at entry of any function touching the GC heap. Its result feeds
only GC-infrastructure (frame chain + the `%ptls_load` arg to the allocator) —
NOT user data directly. The user-data boundary is `%"new::Array"` (the
allocator's return) and its GEPs.

Rejection site — `src/extract/instructions.jl:2101-2104`:
```julia
is_inline_asm = n_ops == 0 || LLVM.API.LLVMIsAInlineAsm(ops[n_ops]) != C_NULL
is_inline_asm && _ir_error(inst,
    "inline-asm call is not supported (Bennett-5oyt / U15)")
```
Fires before Wall 2 is reachable. Bead `Bennett-cc0.5` was scoped here (~500
LOC) but deferred. Prior finding (worklog/029): a naive TLS-suppression broke
`cond_pair` / `array_even_idx` which also traverse the TLS chain under
`--check-bounds=yes`. Any suppression must precisely identify where GC-machinery
ends and user data begins.

### Wall 2 — `@ijl_gc_small_alloc`
```llvm
%"new::Array" = call noalias nonnull align 8 dereferenceable(32) ptr
    @ijl_gc_small_alloc(ptr %ptls_load, i32 408, i32 32, i64 124894668439216)
```
Operands: (1) `%ptls_load` — per-thread state (GC); (2) `i32 408` — pool/bin
selector, NOT size; (3) `i32 32` — **allocation size in bytes, a static i32
constant**; (4) `i64` — Julia type tag. Returns a raw GC-managed heap pointer
with **no `alloca` root** — not in `ctx.ptr_provenance`, no wire allocation.

Julia 1.11+ `Memory{T}` backing-store layout (from the IR):
```
offset -8 : GC type tag (atomic store)
offset  0 : %memory_data — pointer to element data
offset  8 : pointer to the Memory global (initial zero-length backing store)
offset 16 : i64 length count
```
Hard for Bennett's wire model: a GC pointer has runtime address, no static wire
count, no fixed SSA slot. The whole `_pick_alloca_strategy` / `lower_alloca!` /
`ctx.ptr_provenance` system assumes allocations are `alloca` instructions with
known element counts.

### Wall 3 — irreversible runtime callees
`j_#_growend!##0_NNN` (Vector growth/realloc) — three calls, one per `push!`,
each on a capacity-insufficient branch; may call `jl_gc_small_alloc` /
`jl_array_grow_*` internally to **reallocate**, discarding the old backing
store. `j_setindex!` (Dict mutation) — hashing, probing, realloc. Neither is a
registered callee; both are **irreversible as emitted** (the inverse of "free
old memory, allocate new" is not known).

Always emitted: Julia does NOT specialise away the growth check even when the
number of `push!`es is statically known — the conditional branch to the growth
path is always present in the IR. The final allocation size is not trivially
statically inferable (initial capacity comes from a global `Memory` whose size
is a runtime value).

---

## Section 2 — Bennett subsystems a design must work within

- **Wire model** (`src/wire_allocator.jl`): bump allocator + free-list; all
  wires clean (zero); total wire count fixed at compile time; no dynamic
  allocation at simulation time. A GC pointer (no alloca root, runtime address,
  GC-relocatable) breaks every assumption.
- **alloca handling** (`src/lowering/memory.jl`): `_pick_alloca_strategy`
  (148-158) → `:shadow` / `:mux_exch_NxW` / `:shadow_checkpoint`;
  `_pick_alloca_strategy_dynamic_n` (180-190) → `:persistent_tree` under
  `mem=:persistent`, else throws. `_lower_alloca_const_n!` allocates N×W zero
  wires + registers `vw`/`alloca_info`/`ptr_provenance`. The dynamic-n path
  allocates a fixed-size persistent-map NTuple slab. **Both are driven by
  `alloca` instructions — `@ijl_gc_small_alloc` is a `call`, never reaches
  `lower_alloca!`.**
- **persistent-DS tier** (`src/persistent/`): `PersistentMapImpl{...}` —
  state is a fully-typed `NTuple{N,UInt64}` (value type, no heap ptrs); `max_n`
  statically baked into the NTuple size; impls (`linear_scan`/`okasaki`/`hamt`/
  `cf`) are pure branchless Julia registered via `register_callee!`.
  `pmap_get(pmap_new(),k)==zero(V)`; `pmap_get(pmap_set(s,k,v),k)==v`;
  branchless ⇒ data-independent gate count; silently clamps on overflow.
  **KEY QUESTION:** could this be the lowering target for `Vector`/`Dict`?
  `push!`→`pmap_set(state,count,value)`, `getindex`→`pmap_get`. But it sits
  downstream of extraction and is triggered by `alloca`, not by
  `@ijl_gc_small_alloc`; and the `j_#_growend!`/`j_setindex!` callees would
  have to be intercepted/replaced at extraction time.
- **callee registry** (`src/extract/callees.jl`): `register_callee!(f)` keys a
  Julia function by name; matched during extraction by substring on
  `j_<name>_<NNN>`; `lower_call!` recursively extracts+inlines its IR. Today:
  soft-float, integer div, MUX-EXCH, the 4 `*_pmap_*`. A runtime callee can be
  registered only if (a) its IR is extractable (no inline asm / no further
  unregistered callees) and (b) its semantics are reversible — `j_#_growend!`
  fails both.
- **bounded-size annotations**: ONLY `max_loop_iterations` kwarg exists. No
  `@bounded`/`@linear` macro (T2b is PRD-proposed, not built). Persistent `max_n`
  is a compile-time constant baked per-impl, not a user kwarg.

---

## Section 3 — Prior art in the repo

- `Bennett-Memory-PRD.md` "Bucket B" — names `Vector{T}()+push!`, `Dict`, comprehensions
  as the dynamic-size gap; explicitly deferred to a follow-up PRD.
- `Bennett-Memory-T5-PRD.md` — intended `Vector`/`Dict` GREEN via a
  `:persistent_tree` arm in `_pick_alloca_strategy`. **But that design assumed
  heap allocations reach lowering as `alloca` instructions — the 2026-05-21
  spike proved that false** (they are `call @ijl_gc_small_alloc`). The T5
  dynamic-n alloca hook is therefore NOT the right hook; extraction must change
  first.
- `Bennett-VISION-PRD.md` — "reversible memory model (persistent functional data
  structures or EXCH-based heaps)"; lists dynamic alloca in "Tier 3: Research".
- Enzyme analogy: Enzyme mirrors the primal heap with a parallel shadow `malloc`
  — it can, because gradients are linear/non-reversible. Bennett cannot: a
  reversible shadow must be fixed-size ancilla. No repo doc details Enzyme's
  `malloc` shadow beyond `docs/literature/SURVEY.md:219-236`.
- worklog/029 (cc0.5 anatomy): "identify `@ijl_gc_small_alloc` as synthetic
  allocas of known size (from the i32 size operand), emit an IRAlloca keyed on
  the `%memory_data` GEP — teach the extractor Julia's `Memory{T}` layout."

---

## Section 4 — Hard constraints

- **CLAUDE.md §1 fail-loud** — no silent miscompile; partial support that
  corrupts circuits is worse than a clear error.
- **Ancilla-zero invariant** — every wire returns to zero; any new allocation
  abstraction must have a correct reversal.
- **Reversibility — no irreversible realloc.** `j_#_growend!` must be avoided
  (intercept before extraction) or replaced by a provably self-inverse
  equivalent. `register_callee!` cannot take it as-is.
- **Bounded wire count** — circuit wire count is fixed at compile time; it
  cannot depend on a Vector's runtime size.
- **3+1 protocol** — touches `src/extract/instructions.jl` + `src/lowering/` ⇒
  core change.

---

## The six open questions for the architects

- **Q1 — Wall 1 bypass.** How to handle the inline-asm TLS read? Recognise+skip
  the GC preamble, or treat the allocator output as a fresh synthetic alloca?
  Must not break `cond_pair`/`array_even_idx`.
- **Q2 — `@ijl_gc_small_alloc` as synthetic alloca.** The size is a static i32.
  Can the call be modeled as an `alloca` of known byte count, with the
  `Memory{T}` layout modeled to seed `ptr_provenance` for downstream GEPs?
- **Q3 — replacing irreversible `growend!`/`setindex!`.** Intercept at the IR
  level and substitute a reversible persistent-map op? Require `push!`-free
  user code? Something else? The conditional growth branches complicate static
  substitution.
- **Q4 — capacity bound.** User kwarg, static IR inference, persistent `max_n`
  with silent clamp, or reject unbounded entirely?
- **Q5 — TJ4 mirage.** `Array{T}(undef,N)` with the same store/load index folds
  to identity under `optimize=true` (Bennett-890r). A design must account for it.
- **Q6 — persistent-DS as lowering target.** Can GC heap allocs be translated to
  virtual `IRAlloca` nodes early enough (at extraction) to reach the existing
  `_lower_*_via_persistent!` machinery, or is entirely new lowering code needed?

---

## File:line reference table

| Subsystem | File | Lines |
|---|---|---|
| Inline-asm rejection | `src/extract/instructions.jl` | 2101-2110 |
| Benign-call allowlist | `src/extract/instructions.jl` | 2059-2097 |
| Callee lookup / `register_callee!` | `src/extract/callees.jl` | 12-19, 59-74 |
| Registered callees | `src/callees.jl` | 1-147 |
| `lower_alloca!` + const/dynamic-n | `src/lowering/memory.jl` | 19-98 |
| `_pick_alloca_strategy[_dynamic_n]` | `src/lowering/memory.jl` | 148-190 |
| `_lower_{store,load}_via_persistent!` | `src/lowering/memory.jl` | 352-576 |
| WireAllocator | `src/wire_allocator.jl` | 1-52 |
| `lower()` kwargs / `max_loop_iterations` | `src/lowering/driver.jl` | 1-13, 79-83 |
| Persistent protocol / linear_scan | `src/persistent/interface.jl`, `linear_scan.jl` | — |
| `CompileOptions` | `src/Bennett.jl` | 136-161 |
| De-risking spike | `worklog/072_2026-05-21_*.md` | 38-71 |
| cc0.5 anatomy / `Memory{T}` layout | `worklog/029_2026-04-21_*.md` | 201-241 |
