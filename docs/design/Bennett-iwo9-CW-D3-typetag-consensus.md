# Bennett-iwo9 / CW-D3 — Julia type-tag + gc_alloc_obj cluster — 3+1 consensus

**Date:** 2026-06-23. **Protocol:** 2 independent opus proposers (A, B) + orchestrator synthesis (+1).
**Scope:** under the `ptr_cells=true` closed-world VM gate, model the Julia typed-GC-allocation
cluster the `fdict` root hits — `load @"+Type#N" → ptrtoint → inttoptr → gc_alloc_obj(task,size,tag)` —
soundly and deterministically. Cross-repo (Bennett.jl extractor + BennettVM ingest). **CORE change
(ir_extract + ir_types + ingest) → 3+1 per CLAUDE.md §2.**

## The cluster (verified, `fdict_O0.ll`, optimize=false)
```
%tag  = load ptr, ptr @"+Main.Base.Dict#148"       ; type-tag global; init = inttoptr(i64 K) — K is a NON-DETERMINISTIC JIT addr
%Dict = ptrtoint ptr %tag to i64
%1    = inttoptr i64 %Dict to ptr
%task = getelementptr inbounds i8, ptr %pgcstack, i32 -152
%obj  = call ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %1)
```
Recurs ≥3× per root (Dict#148 size 64, AssertionError#153 size 8, KeyError#150 size 8).

## Decisions (where A and B diverged, and why)

1. **Type-tag ID = deterministic, name-derived, NEVER address-derived.** Recognize a type-tag global
   **by name** (`startswith("+")` && matches `#\d+$`). Canonicalize: strip leading `+`, strip trailing
   `#<digits>` → `"Main.Base.Dict"`. Mint a small dense Int64 id via an **extraction-local** interning
   table (path→id), first-seen order (walk order is deterministic → reproducible). `_canonical_type_path`
   **fails loud** (Rule 1) if a `+`-prefixed global lacks the `#N` suffix (unexpected JIT naming). The JIT
   address `K` is never read on this path. (B's explicit fail-loud + A's interning.)

2. **NO `ParsedIR` field.** The interning table is extraction-local; the id is baked into emitted IR.
   Nothing non-deterministic is persisted in the contract. (A's minimality — B's proposed `type_tag_ids`
   field is admittedly never read by BennettVM.) All `ParsedIR` constructors unchanged.

3. **Emit REAL SSA defs, not zero-IR const-propagation.** Each cluster instruction lowers to a width-64
   identity using existing lowering — `IRBinOp(dest, :or, <operand>, iconst(0), 64)` — so dests are bound
   through the normal SSA path. (B's robustness — avoids A's bet that `_operand` is the sole resolution
   chokepoint; if that bet were wrong, A's `return nothing` + alias-map would silently break.)
   - `load @"+Type#N"` (ptr_cells, recognized tag global) → `IRBinOp(dest, :or, iconst(id), iconst(0), 64)`.
     Record `dest` in an extraction-local `tag_ssa::Set{_LLVMRef}` (tag-provenance).
     **Fail loud** if a `+...#N`-named global is loaded but recognition/minting missed it
     ("recognized-but-unminted" — no silent fall-through to the generic 64-bit IRLoad).
   - `ptrtoint`/`inttoptr` (ptr_cells): **if `src ∈ tag_ssa`** → `IRBinOp(dest, :or, _operand(src), iconst(0), 64)`,
     add `dest` to `tag_ssa`. **ELSE fail loud** — only the type-tag round-trip is modelled; genuine
     pointer↔int arithmetic (e.g. `ptrtoint ptr to i32`, casting a real arena pointer) is NOT (it would
     expose ARENA_BASE-relative values to int ops). (A's conservative criterion — strictly safer than B's
     width-only check; smallest sound surface.) Under `ptr_cells=false`: no arm → existing behavior
     (byte-identical).

4. **`gc_alloc_obj` un-drop is gate-clean.** Intercept `cname == "julia.gc_alloc_obj"` **before** the
   benign-prefix allowlist, **inside `if ptr_cells`**. Leave the broad `"julia.gc_"` benign drop intact for
   `ptr_cells=false` → circuit path byte-identical (B's gate-clean approach; avoids A's prefix-narrowing R4
   risk). Emit a **Symbol-callee** `IRCall(dest, :gc_alloc_obj, [size_op, tag_op], [64,64], 64)` (reuses the
   existing Symbol-callee IRCall, Bennett-k3ej; no new IRInst). Drop the `task` arg (a `%pgcstack` GEP with
   no VM meaning). `tag_op` is the bound SSA ref to `%1` (BennettVM ignores its value). Fail loud on arity ≠ 3.

5. **BennettVM ingest (ADR 0021 D3 floor: tag IGNORED).** Add
   `struct IntrinsicGCAlloc <: Instruction; dest::Symbol; nbytes_operand::Union{Symbol,Int64}; tag_operand::Union{Symbol,Int64}; end`
   to `src/ir/intrinsics.jl`; add it to the `_ArenaAlloc` Union so it inherits `predelta_payload`/`forward`/
   `inverse`/L3 verbatim (arena bump alloc identical to `IntrinsicMalloc`; tag stored but **structurally
   unread** by any state transition). Add `_alloc_cells(::IntrinsicGCAlloc, s)` method and the two
   history one-liners (`is_injective(::Type{IntrinsicGCAlloc})=false`, `is_l2_capable(...)=true`). Add
   `:gc_alloc_obj` to `_HEAP_DISPATCH` and a `_lower_intrinsic_call` case (`_need(2)` → size, tag). `free`
   stays a no-op (objects leaked-but-sound, ADR 0018 §B).

## Soundness (must hold; verified-by-construction + tested)
- **No JIT address enters the VM:** recognition is by name; id derives from the `#N`-stripped path; `K` is
  never read; the cluster lowers to a deterministic constant + identities; the BVM floor ignores the tag.
- **Fail-loud coverage:** non-tag `ptrtoint`/`inttoptr` (decision 3), malformed tag names (decision 1),
  recognized-but-unminted load (decision 3), wrong gc_alloc_obj arity (decision 4). The circuit-path
  `:addr` rejection (`module_walk.jl:732`) and `_fold_constexpr_operand` ptrtoint/inttoptr error
  (`constexpr.jl:186`) are UNTOUCHED.
- **Circuit-path byte-identity:** every arm is `ptr_cells`-gated; the broad `julia.gc_` drop stays for
  `ptr_cells=false`. Pin via `test_gate_count_regression.jl` (unchanged: i8 x+1 = 58, …).

## Lever sequencing (lockstep, each independently red-green)
- **Lever 1 = Bennett-iwo9 proper** (this cycle): type-tag recognition + load arm + ptrtoint/inttoptr arm
  (decisions 1–3). Red-green: minimal `.ll` `load @"+T#N" → ptrtoint → inttoptr → (ptrtoint back) → ret i64`
  (NO gc_alloc_obj). Assert: extraction succeeds; result = low bits of the stable id; **extract twice → same
  id**; `Dict#148` and `Dict#999` → same id; non-tag `ptrtoint ptr→i32` fails loud; `ptr_cells=false`
  unchanged + `test_gate_count_regression` 39/39. Advances the fdict root to the gc_alloc_obj wall.
- **Lever 2 = gc_alloc_obj extraction** (next bead, BennettVM `416r.13` Bennett.jl-side): decision 4.
- **Lever 3 = BennettVM arena ingest** (BennettVM `416r.12`): decision 5; tag-invariance test (vary tag →
  identical IState); forward/inverse arena round-trip.

## Research steps the implementer MUST verify empirically (no Julia in design phase)
- **R1:** the EXACT current error at the wall (bead says "unsupported LLVM opcode"; analysis says unbound
  `%Dict`/`%obj` → "unknown operand ref"). Capture before pinning the red test.
- **R2:** confirm `%Dict`/`%1` are *instructions* (instruction arm), not folded ConstantExprs.
- **R3:** confirm the load's pointer operand resolves directly to the `LLVM.GlobalVariable` (name check
  suffices; keep a minimal bitcast chase).
- **R5:** confirm `%pgcstack`/`%current_task` GEP lowers benignly under the get_pgcstack allowlist
  (Bennett-zf5v) or needs an explicit drop — the likeliest Lever-2 surprise.
- **R6:** confirm the `_ArenaAlloc` union covers `predelta_payload`/`forward`/`inverse` but `is_injective`/
  `is_l2_capable` dispatch per concrete type (add the two one-liners).
- Confirm `iconst(id)` at width 64 lowers via `IRBinOp(:or, …, iconst(0), 64)` (simulator const-width ≤64 — fine).

## Touch points
- Bennett.jl: `src/extract/constexpr.jl` (`_canonical_type_path`, `_is_type_tag_global_name`),
  `src/extract/module_walk.jl` (thread interning table + `tag_ssa` into `_convert_instruction`),
  `src/extract/instructions.jl` (load arm, ptrtoint/inttoptr arm, gc_alloc_obj intercept).
- BennettVM.jl: `src/ir/intrinsics.jl`, `src/ir/ingest_call.jl`, history one-liners.
- No change to phi resolution, gate types, or `bennett_transform.jl`.
