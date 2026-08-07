# Bennett-5viz — DESIGN-VERIFYING SCOUT report

**Bead:** `Bennett-5viz` (P1) — "xkl frontier wall 11: ROOT
`memcpy(env+40, new::Array.ref.mem, 8)` — loaded-ptr src memcpy capability
(8bys territory, corpus site #4)"
**HEAD at time of scouting:** `e251a03` (Bennett-57hd, landed 2026-08-07)
**Scope:** verification pass only. **No `src/` or `test/` change was made; no commit.**
**Probes** (session scratchpad, all under `julia --project --check-bounds=yes`,
i.e. suite mode per CLAUDE.md §Build):
`p01_wall.jl` (verbatim wall + marker table), `p03_dump2.jl` (→ `root2.ll`, the
post-strip module the walker actually sees, + `from_ll` byte-identity),
`p04_surgery.jl` (→ `root3.ll`, wall 11 admitted → wall 12), `p05_top.jl` /
`p06_glob.jl` (ParsedIR + `.globals` for `%top`), `p07`–`p09` (successive
admissions → wall 14 reached), `p10_chain4.jl` (all-byte stamping → NO WALL),
`p11_canon.jl` / `p12_canon2.jl` (the §4b canonicalisation route, measured on the
real corpus values).

---

## VERDICT UP FRONT — **REDUCED** (scout → implementer → hostile review)

| tripwire | verdict | evidence |
|---|---|---|
| rigorous-soundness-or-upgrade | **NO** | The src certification is not invented here: `_57hd_canon` **already** reduces the walled src pointer to `%"jl_global#93"`, the 416r.13 empty-`GenericMemory` singleton, **with no change to §4b at all** (probe `p12`, §2.2). Capacity, scale and root identity then come from `parsed.globals` — the same authority doih's G8 bounds-check already uses. |
| genuinely-contested-design-or-upgrade | **NO** | Four routes enumerated (§2.3); three are closed by *measurement*, not argument: R2 (`IRCall(:memcpy)`) by sy29's `_enforce_julia_heap_tier!` probe, still applicable because the program is `gc_alloc_obj`-bearing; S3 ("admit any certified load address") by the fact that Predicate 7 and Predicate 6d both become unenforceable — the exact hole sy29's own hostile review D2 **executed** (`222` vs oracle `333`, `leak = 999`); S-B (`_57hd_roots_disjoint` instead of root identity) survives P7 but supplies no capacity, so it re-opens D2's src-overrun half. One route survives. |
| a BVM src change is needed | **NO** (predicted, must be re-verified by the implementer) | Route S-A emits only `IRPtrOffset` / `IRLoad` / `IRStore` off a `.globals` base — the shape `%top` **already ships** (`IRPtrOffset(:memory_data_ptr, SSAOperand(jl_global#93), 8, 8)` + `IRLoad`, probe `p05`). BVM's `GLOBAL_BASE = 2^48` read-only tier already serves it. |
| a §4b core change is needed | **NO** | The one gap (`_57hd_canon` bottoms out on `LLVMLoad` and the src is an `extractvalue`) is closed **outside** §4b by one call to the existing `_57hd_insertvalue_field` in the memcpy arm. §4b's own behaviour, and every gate of `test_57hd_value_identity.jl`, is untouched. Measured: `p12`. |

**Honest note on CLAUDE.md §2.** This touches `src/extract/instructions.jl`, so §2's
letter asks 3+1. The reduced arc still runs three independent agents plus the
orchestrator. Blind proposers would be ceremonial because the design space has one
survivor and the emission is a mirror of the shipped sy29/doih arms. **Overrule this
if you disagree** — but note the *one* place a proposer pair would genuinely earn
its keep is §3's dst-stamp question, and §3 concludes that question belongs to
`Bennett-bvmd` (wall 14), not to this bead.

---

## 1. Wall 11 at HEAD, reproduced (probe `p01_wall.jl`)

```julia
_push5viz(n::Int64) = begin
    v = Int64[]; push!(v, n); @inbounds v[1]
end
Bennett.extract_parsed_ir_set_from_julia(_push5viz, Tuple{Int64}; ptr_cells=true)
```

Verbatim (the `julia_set.jl` wrapper prefix/suffix elided):

```
ir_extract.jl: call in @julia__push5viz_33537:%L16:
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %23,
                                   ptr align 8 %"new::Array.ref.mem",
                                   i64 8, i1 false)
— llvm.memcpy.p0.p0.i64: memcpy src operand is not alloca-backed (or
alloca-backed via a const-offset GEP). Same restriction as the dst case;
tracked in Bennett-8bys. (Bennett-37mt Phase 1)
```

**The rejecting predicate is Predicate 6's SRC half** — `instructions.jl:3162-3165`,
`(src_root === nothing && arena_src === nothing)`. Confirmed by walking the guards
above it: `_src_reaches_global(src_v)` is `false` (Predicate 5b does not fire —
the src is an SSA `extractvalue`, not a global reference), `_alloca_root_ref(src_v)`
= `nothing`, `_gc_alloc_root_ref(src_v)` = `nothing` (probe `p11`). It is not
Predicate 7, not 8, and not the qmv7 `gc_loaded` branch.

**Marker discriminator — FIRES on the real message** (probe `p01`, exact
`occursin` on the wall text):

| marker | fires | role |
|---|---|---|
| `memcpy`, `Bennett-37mt`, `Bennett-8bys`, `src operand` | **true** | positives (all eight corpus-gate sites) |
| `new::Array.ref.mem` | **true** | **THE DISCRIMINATOR** — wall 11 vs wall 9 |
| `new::Array.size_ptr` | false | **THE INVERSE DISCRIMINATOR** — wall 9 regression detector |
| `Bennett-583s`, `base-cancelling`, `Bennett-foz5`, `Bennett-57hd`, `ptrtoint` | false | wall 10 stays cleared |
| `Bennett-p06b`, `gc_alloc_obj`, `BYTE-granular`, `Bennett-bvmd`, `Bennett-z2ia` | false | walls 8/12/14 not yet reached |
| `Bennett-lgzx`, `Bennett-jbko`, `Bennett-iwo9`, `memmove` | false | walls 3/5/6 stay cleared |
| `Bennett-sy29` | false | wall 9's own arm stays cleared |
| `Bennett-1zow` | false | (wall 12's tag is absent from wall 12's *own* message too — §5.1) |

**Reproducible from a file.** `sprint(code_llvm; debuginfo=:none, optimize=false,
dump_module=true)` → `root2.ll` (316 lines), then
`extract_parsed_ir_from_ll("root2.ll"; entry_function="julia__push5viz_91",
ptr_cells=true)` reproduces the wall **byte-identically** (probe `p03`). Textual
surgery on `root2.ll` is therefore a faithful admission simulator, exactly as in
the sy29 arc. `_module_has_sret(root)` is **true** here (the `sret({ptr,ptr})`
callee), so `sroa`+`mem2reg` **are** prepended — unlike wall 9. Do not carry
sy29 §1.1's "no passes prepend" note forward.

### 1.1 Both operand provenances, exactly

**DST** — `%23 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##1", i32 40`,
a single-index **byte** GEP off `alloca [9 x i64]` (the `_growend!` closure env).
`_alloca_root_ref` resolves it, `_alloca_elem_width_bits` = 64, `_root_scale` =
`(8, 9, "an `alloca` reservation of 9 cell(s)")`, `_root_byte_offset` = 40
(all measured, probe `p11`). **`dst_root !== nothing`: the dst half of Predicate 6
was never in question.**

**SRC** — `%"new::Array.ref.mem" = extractvalue { ptr, ptr } %"new::Array.ref", 1`.
Its full chain, all in `%top` (`root2.ll:38-56`):

```llvm
  %"jl_global#93" = load ptr, ptr @"jl_global#93"            ; the SINGLETON
  %3        = insertvalue { ptr, ptr } zeroinit, ptr %memory_data, 0
  %memory_ref = insertvalue { ptr, ptr } %3, ptr %"jl_global#93", 1
  %"new::Array" = call ptr @julia.gc_alloc_obj(_, i64 24, _)  ; 24-byte Array box
  %5 = getelementptr inbounds i8, ptr %"new::Array", i32 8
  store ptr null, ptr %5                                      ; writes [8,16)  — CLOBBERED
  store { ptr, ptr } %memory_ref, ptr %"new::Array"            ; writes [0,16) — THE WRITER
  ...
  %8 = getelementptr inbounds { ptr, ptr }, ptr %"new::Array", i32 0, i32 1
  %9 = load ptr, ptr %8                                       ; reads  [8,16)  — THE LOAD
  %10 = insertvalue { ptr, ptr } zeroinit, ptr %7, 0
  %"new::Array.ref"     = insertvalue { ptr, ptr } %10, ptr %9, 1
  %"new::Array.ref.mem" = extractvalue { ptr, ptr } %"new::Array.ref", 1
```

So, to answer the bead's question in its own terms: the src is **a load of byte
slot `[8,16)` of the `gc_alloc_obj`'d `Array` box, written by the aggregate
`store { ptr, ptr } %memory_ref` whose field 1 is `%"jl_global#93"`** — a load of a
`private unnamed_addr constant ptr` whose aliasee is `inttoptr (i64 <JIT-addr>)`.
(Two dumps in one session gave two different JIT addresses; the constant is
session-scoped, which is why it is never read — ADR 0021 D3.)

**The src root is NOT the gc_alloc'd Memory. There is no gc_alloc'd Memory in this
program.** `Int64[]` produces the *shared empty `Memory{Int64}` singleton*, which
`_extract_const_globals` models as `(zeros(UInt64, 16), 8)` — a 16-**byte** zero
blob at byte tier — under the `bennettvm-416r.13 / CW-D3 Lever 2` arm
(`module_walk.jl:1013-1024`), gated on `ptr_cells`. Measured: `p.globals` =
`jl_global#93 => data=16×0x0, ew=8` (probe `p06`).

### 1.2 CORRECTION TO THE BEAD — the copied value is an `Int64`, not a pointer

The bead says "it is a POINTER being copied into the env — one 64-bit cell". It is
not. The memcpy's src **operand** is a pointer; the copied **value** is the 8 bytes
*at* that address, i.e. the `Memory` header's `length` field (layout
`{i64 length, ptr data}` — confirmed twice in the same block: `%memory_data_ptr =
getelementptr inbounds { i64, ptr }, ptr %"jl_global#93", i32 0, i32 1` reads field 1,
and `%.unbox = load i64, ptr %"new::Array.ref.mem"` reads field 0 as an `i64`).

The closure-env layout corroborates it. `#_growend!##0#_growend!##1{Array{Int64,1},
Int64, Int64, Int64, Int64, Int64, Memory{Int64}, GenericMemoryRef}` = 72 bytes =
`9 × i64`: ptr@+0, five `Int64`s@+8…+40, `Memory` ptr@+48, `GenericMemoryRef`@+56.
The three GC-tracked fields (+0, +48, the ref's `.mem` half) are **not** written to
the env — they go to the separate roots array `%2 = alloca ptr, i32 3` (measured:
`store ptr %"new::Array", %2+0`, `store ptr %"new::Array.ref.mem", %2+8`,
`store ptr %28, %2+16`), and env+64 gets a `store i64 -1` placeholder. **`env+40`
is the fifth `Int64` field, and it holds `length(mem)`.**

Why this matters, concretely:
* Predicate 8/8b: `src_ew` is the **value** width (64), never the global's stored
  `ew` (8, which is the *address scale*). Confusing them rejects the corpus at 8b.
* Bennett-land synthetic-address provenance (§7.6 of the sy29 arm) is **not**
  engaged: no pointer is being laundered into an alloca here.
* The already-shipped `IRLoad(:.unbox, SSAOperand(new::Array.ref.mem), 64)` in
  `%top` (probe `p05`) is the *same dereference at the same address at the same
  width*. Wall 11 refuses, one block later, a read the extractor already performs.

### 1.3 The "word-identical to wall 9" claim — TRUE for the reject, with a caveat

The reject sentence is emitted from one string literal
(`instructions.jl:3146-3149`) and is genuinely character-identical to the text
sy29 cleared. But the `_ir_error` **prefix** differs in *three* places, not one:

| | wall 9 | wall 11 |
|---|---|---|
| block | `%top` | `%L16` |
| dst operand | `%"new::Array.size"` | `%23` |
| src operand | `%"new::Array.size_ptr1"` | `%"new::Array.ref.mem"` |

The in-tree marker comments claim the operand name is the *only* discriminator.
That is over-strict but harmless — the src-operand name is the one to use, because
the block label and the numeric dst are both Bennett-0ncn-fragile (numerals move
with LLVM naming; `%L16` moves with Julia codegen). **Keep the existing pair of
lines; do not "improve" them to the block label.**

---

## 2. The src certification

### 2.1 What must be established, and why each item is load-bearing

| obligation | why it cannot be skipped |
|---|---|
| **ROOT IDENTITY** (Predicate 7) | Route R1's per-cell ascending load-then-store bypasses BVM's runtime overlap check entirely (`forward(::IntrinsicMemcpy)` is never reached, because no `IntrinsicMemcpy` is emitted). sy29's arm comment states this and its hostile review D2 **executed** the miscopy. An unresolved src root cannot be shown distinct from the dst alloca, so P7 becomes unenforceable. |
| **CAPACITY** (Predicate 6d) | Same review, second symptom: an src range past its own reservation silently reads the next object (`leak = 999`). |
| **SCALE** (the 4y0d address stamp) | `IRPtrOffset(d, b, off, ew)` lowers to `Define(d, b, :add, off ÷ (ew÷8))`, so `ew` **is** the bytes-per-cell scale. At K = 1 / offset 0 any stamp is vacuous (the (SC) exemption at `instructions.jl:585`) — which is exactly how the pre-4y0d vbv9 defect stayed green. |

### 2.2 The §4b canonicaliser DOES supply all three — measured

Probe `p12_canon2.jl`, run on the real `root2.ll` values with an auto-named
`names` dict (the walker names every instruction):

```
stripped = %9 = load ptr, ptr %8                     # _57hd_insertvalue_field(agg, 1)
_foz5_cert_src_kind(stripped)  = load
_57hd_certified(stripped)      = true                # (V0) passes
canon(stripped)                = %"jl_global#93" = load ptr, ptr @"jl_global#93"
canon is a load-of-GlobalVariable = true
global name                    = jl_global#93
_is_singleton_data_global_name = true
_root_byte_offset(src_v)       = 0
```

The walk is `_57hd_canon`'s **(a) STORE-FORWARD** clause: slot key
`(%"new::Array", 8)`, the last covering store is the aggregate
`store {ptr,ptr} %memory_ref, ptr %"new::Array"`, clause (iv)
(`_p06b_cell_ptr_target_kind` on the `gc_alloc_obj` root) passes, `_57hd_clobbered`
finds nothing between it and `%9` — the only intervening write is
`memcpy(%"new::Array.size_ptr", @"_j_const#1", 8)` whose footprint
`_57hd_write_footprint` computes as `[16, 24)`, disjoint from `[8, 16)`, taken at
the **byte tier** because `_root_scale(%"new::Array")` = scale 1 — then
`_57hd_insertvalue_field(%memory_ref, 1)` = `%"jl_global#93"`. **Every step is
existing, shipped, reviewed machinery.** The earlier `store ptr null, %5` at the
same slot is correctly skipped: canon takes the *last* covering store.

Root, capacity and scale then follow from `parsed.globals`, which the memcpy arm
**already receives as its `globals` argument**:

```
scale_bytes    = ew ÷ 8                     = 1     (byte tier)
capacity_bytes = length(data) * (ew ÷ 8)    = 16
ptr_ew_src     = 8 * scale                  = 8     (ADDRESS stamp)
src_ew         = 64                         (VALUE width — one Int64 per cell)
src offset     = _root_byte_offset(src_v)   = 0
```

`capacity_bytes` is doih G8's own formula (`length(gdata) * ew_bytes`), so this is a
reuse, not a new authority. Range check: `0 + 8 ≤ 16` ✓. Alignment: `0 % 8 == 0` ✓.

**Disjointness is structural, and stronger than sy29's.** BennettVM lays globals in
a fourth address tier based at `GLOBAL_BASE = 2^48`
(`BennettVM/src/ir/IState.jl:261`, `memory_floor.jl:215-280`), **read-only** — a
`MemoryStore` to `≥ GLOBAL_BASE` fails loud. Stack allocas live below it. So a
global-rooted src and an alloca-rooted dst cannot alias, by address-space
construction. Two free corollaries: (i) a *canonicalised-global DST* must be
refused at extraction (the VM would fail loud anyway, but CLAUDE.md §1 wants the
loud refusal at the earliest point); (ii) reading past the 16 seeded cells hits
`memory_floor.jl:280`'s "NOT seeded" fail-loud — a backstop for 6d, **not** a
substitute for it.

### 2.3 Route enumeration, with the soundness obligation each fails

| route | verdict | grounds |
|---|---|---|
| **S-A — canonicalise the src to a `.globals` root, then reuse the sy29 predicate cascade** | **SURVIVES** | §2.2. Root identity, capacity and scale all obtained; every predicate 6c/6d/7/8 transfers verbatim (§4). |
| S-B — keep the src root unresolved; prove P7 with `_57hd_roots_disjoint` | rejected | It *works* (measured: `_57hd_roots_disjoint(%23, %"new::Array.ref.mem")` = **true**, via `_57hd_alloca_noescape` on the `nocapture` env alloca). But it yields **no capacity and no scale**, so 6d is skipped and the address stamp is a guess — re-opening precisely the src-overrun half of sy29 hostile-review D2. Keep it in the pocket as a *redundant* second disjointness proof if the implementer wants belt-and-braces; do not make it the gate. |
| S3 — relax the src half to "any `_57hd_certified` cell pointer" | rejected | Same as S-B but loses P7 as well. This is the tempting one-line diff. It is unsound. |
| R2 — route to `IRCall(:memcpy)` (the vau9 / 8bys D5b void-call shape) | **CLOSED** | sy29 probe `s08`: `_enforce_julia_heap_tier!` (`BennettVM/src/ir/intrinsics_genericmemory.jl:192-199`) refuses `IntrinsicMemcpy`/`IntrinsicMemmove` in any `gc_alloc_obj`-bearing program, and this program is one. Unchanged at this HEAD. |

**S-A is an sy29-arm WIDENING that reuses the §4b canonicaliser inside sy29's src
gate — not a new arm, and not a §4b change.** Concretely, in
`_handle_memcpy_arm`, alongside `arena_src = _gc_alloc_root_ref(src_v)`:

```
global_src_canon = (ptr_cells && src_root === nothing && arena_src === nothing) ?
                   _5viz_canon_global_root(src_v, names, suppressed_refs, ptr_cells,
                                           globals) : nothing
```

where the helper (i) strips a top-level `extractvalue` via the existing
`_57hd_insertvalue_field`, (ii) runs `_57hd_canon` **in the block where the
stripped value is defined**, (iii) requires the result to be a `load` of a
`GlobalVariable` `G` with `haskey(globals, G)`, and (iv) returns
`(G, scale, capacity_bytes)`.

> **IMPLEMENTATION TRAP, MEASURED.** `_57hd_canon` is INTRA-BLOCK
> (`LLVM.parent(v).ref == blk.ref || return v.ref`). The memcpy is in `%L16`; the
> src's definition chain is in `%top`. Probe `p12` ran canon **both ways**: with
> `blk = LLVM.parent(stripped)` it returns `%"jl_global#93"`; with `blk =` the
> memcpy's block it returns `%9` unchanged. The latter is fail-closed (the arm
> would simply be dead code and the wall would persist), but it is exactly the
> kind of silent no-op the arc must not ship. This is sound because canon
> establishes a fact about an **SSA value at its definition**, and SSA values are
> immutable — the fact holds at every use, in every block.

> **PLUMBING.** `_57hd_canon`'s clause (iv) needs the real `suppressed_refs`;
> passing `Set{_LLVMRef}()` would wrongly admit a suppressed (sret) store target.
> `suppressed_refs` is in scope at `_convert_instruction` (`instructions.jl:5727`)
> but is **not** threaded through `_handle_intrinsic` (`:4347`) →
> `_handle_memcpy_arm` (`:2935`). Two kwarg hops. Do not default it to empty.

---

## 3. The dst side — it is `Bennett-bvmd`'s (wall 14), and 5viz must not annex it

`env+40` is a byte GEP into the word-tier `alloca [9 x i64]` — the `z2ia` family, and
the same env alloca `Bennett-bvmd` owns. Findings, all measured:

1. **bvmd's use-directed BYTE-NORMALISATION does NOT fire on this alloca today**,
   and the reason is the memcpy arm itself. Normalisation requires `all_byte[root]`
   — *every* emitted `IRPtrOffset` off the root byte-stamped
   (`instructions.jl:539-546`). The **already-shipped** 37mt/sy29 emission for
   corpus site #3 (`memcpy(env+32, %"new::Array.size", 8)`) stamps
   `ptr_ew_dst = 8·_root_scale(env)[1] = 64`, which sets `all_byte[env] = false`.
2. **Wall 14 therefore pre-exists 5viz.** Probe `p09`: with wall 11 replaced by a
   *byte-stamped* `load`+`store` pair (and walls 12/13 stepped over), the next wall
   is the bvmd `SCALE-COHERENCE` violation on
   `new::#_growend!##0#_growend!##1` — raised by the *other* memcpys, not by ours.
3. **And it is exactly one stamp decision away from vanishing.** Probe `p10`: with
   **all three** env-rooted memcpys decomposed into byte-stamped `load`/`store`
   pairs, `all_byte[env]` becomes true, normalisation rewrites
   `IRAlloca(env, 64, 9) → IRAlloca(env, 8, 72)`, and **the whole function extracts
   with NO WALL**.

**Recommendation: 5viz takes the sy29 rule unchanged** — `ptr_ew_dst` from
`_root_scale`, i.e. 64 here — and files/points at `Bennett-bvmd` for the env
alloca's tier. Grounds: (a) 5viz's dst is byte-identical in shape to site #3's,
which already ships with that stamp, so 5viz neither creates nor worsens wall 14;
(b) flipping the memcpy arm's dst stamp to the operand's own const-GEP granularity
is a change to a rule three shipped arms depend on, with blast radius across
`test_37mt` (86 assertions), and it is a *tier* decision, which is bvmd's charter,
not a memcpy-src capability. **Say so in the arm comment**, and record probe
`p10`'s result on the bvmd bead — it is the single most useful datum this scout
produced for wall 14 and it should not be re-derived.

**Capacity at env+40 (6d):** `_root_scale(env)` = `(8, 9)` → 72 bytes;
`_root_byte_offset(%23)` = 40; `40 + 8 = 48 ≤ 72` ✓. No capacity question. There is
also **no** z2ia dynamic-count issue: the reservation is static.

---

## 4. Guard transfer — 6c / 6d / 7 / 8

| guard | transfers? | statement for the global-root src |
|---|---|---|
| **6c** cell-aligned offset | **verbatim** | `_root_byte_offset(src_v)` must be constant, `≥ 0` and `≡ 0 (mod 8)` **when the root's scale is 1**. Corpus: 0. Same rationale as the arena case: the byte tier names a 64-bit value by its base byte address and never names `+1…+7`. Guard `scale ≥ 1` (a `.globals` entry with `ew < 8` would give `ew÷8 == 0`; refuse rather than divide). |
| **6d** in-object range | **verbatim** | `0 ≤ off` and `off + N ≤ length(data)·(ew÷8)`. Corpus: `0 + 8 ≤ 16`, flush on the upper bound — so, exactly as in sy29, flipping `≤` to `<` rejects the corpus, which is this predicate's own mutation test. |
| **7** distinct roots | **verbatim, and stronger** | `eff_src_root` = the global; `eff_dst_root` = the env alloca. Distinct *address tiers* (`≥ 2^48` read-only vs stack), so no dynamic execution can alias them. A canonicalised-global root on **both** sides must keep failing loud with the generalised same-root message. |
| **8/8b/8c** element width | **verbatim, with the 4y0d split spelled out** | `src_ew = 64` (VALUE — one `Int64` per cell, ADR 0018 §A), *not* the global's `ew = 8` (ADDRESS scale). `dst_ew = 64`. 8b passes. 8c: `8·8 % 64 == 0` ✓, K = 1. |

**New hazards from the loaded src, and why they are covered:**

* **D1-class self-reference** (the 57hd hostile-review class). Not engaged. Those
  shapes are hazards of the *symmetric* (V2) equality test — two chains
  canonicalising to one uniqued `undef`/`poison`, or a `phi` carrying the M2b
  width-0 sentinel. 5viz uses canon in **single-value root-finding** mode: there is
  no second chain and no equality comparison. The residual obligation is the one
  canon already carries (a wrong canonical answer ⇒ a wrong root), and canon's
  answer here is *pointer value equality*, which is the strongest aliasing
  statement available.
* **Cross-block use of an intra-block fact.** Covered by SSA immutability; see the
  boxed trap in §2.3. The clobber window canon scans is `%top`'s, between the
  aggregate store and `%9`'s load — the correct window for `%9`'s value.
* **Purity.** `_57hd_canon` / `_57hd_certified` are read-only in
  `names` / `suppressed_refs` (their own docstrings), so calling them mid-conversion
  introduces no ordering dependence.
* **A `.globals` entry that is not the singleton.** The gate is
  `haskey(globals, G)`, which is general; `_is_singleton_data_global_name` is what
  *put* the entry there under `ptr_cells`. Do not hard-code the name.

**Circuit path (`ptr_cells=false`) is byte-identical by construction**: the whole
branch is behind `ptr_cells &&`, so `global_src_canon` is `nothing`, Predicate 6's
src message is unchanged character-for-character, and `test_37mt` / `test_lqif`
keep their pins. That is the vbv9 / u2kk / qmv7 / sy29 gating pattern, unchanged.

---

## 5. Blast radius and the next wall

### 5.1 Wall 12 — CONFIRMED VERBATIM (probe `p04_surgery.jl`)

Replacing the walled memcpy in `root2.ll` with its emission-equivalent
`load i64` + `store i64` gives, immediately, in the same block:

```
ir_extract.jl: store in @julia__push5viz_91:%L16:
  store { ptr, ptr } %"new::Array.ref", ptr %0, align 8
— aggregate store target is not a CERTIFIED cell pointer — it is an
`alloca { ptr, ptr }`, whose allocated type the alloca arm SILENTLY SKIPS — it
emits NO IRAlloca, so nothing ever reserved the cells this store would write.
… (Bennett-p06b, predicate `_p06b_cell_ptr_target_kind`)
```

**The in-tree forecast is exactly right** and the bead's inverted-trap warning is
confirmed: the message contains `Bennett-p06b`, `_p06b_cell_ptr_target_kind`,
`SILENTLY SKIPS`, `aggregate store`, `CERTIFIED cell pointer` — and **NOT**
`Bennett-1zow`, **NOT** `Bennett-37mt`, **NOT** `memcpy`, **NOT** `gc_alloc_obj`,
**NOT** `BYTE-granular`, **NOT** `Bennett-bvmd`, **NOT** `SCALE-COHERENCE`.

> **A SECOND TRAP, NOT IN THE BEAD.** Wall 12's message *does* contain the substring
> `new::Array.ref` (it quotes `store { ptr, ptr } %"new::Array.ref", …`). It does
> **not** contain `new::Array.ref.mem`. So the existing discriminator pair inverts
> **safely only if the `.mem` suffix is kept**: `@test !occursin("new::Array.ref.mem", msg)`
> is correct; `@test !occursin("new::Array.ref", msg)` would be **red**. Check every
> rewritten marker against the real wall-12 text — the sy29 lesson, again.

### 5.2 Walls 13 / 14 — 14 reached, 13 not independently reproducible

* **Wall 14 CONFIRMED** (probe `p09`): the bvmd `SCALE-COHERENCE` violation on the
  `9 × i64` closure alloca, verbatim, naming `_root_scale` / `_check_scale_coherence!`
  and the failed byte-normalisation. See §3.
* **Wall 13 NOT re-verified here, and honestly so.** Every faithful simulation of a
  1zow fix requires *modelling* the `alloca { ptr, ptr }`, and every surgery that
  does so (`[2 x i64]`, or decomposing the aggregate store) also gives
  `_alloca_elem_width_bits` a non-zero answer, which is the exact dimension wall 13
  tests. What *is* certain from code: `_alloca_elem_width_bits`
  (`instructions.jl:2868-2879`) returns `0` for a `StructType`, and Predicate 8
  rejects on `dst_ew == 0 || src_ew == 0` — so under a 1zow fix that models
  `{ptr,ptr}` allocas *as struct allocas*, corpus site #5
  (`memcpy(env+56, %0+0, 8)`) walls there. Two intermediate p06b clauses were
  measured en route and are worth recording for the 1zow scout:
  `_p06b_granularity_violation` fires (a) for a byte GEP off a word-tier `[2 x i64]`
  and (b) for a two-index GEP whose source element type is not the stored struct
  type.

### 5.3 The memcpy census of the ROOT at this HEAD (`root2.ll`, 9 sites)

| # | line | blk | dst | src | status |
|---|---|---|---|---|---|
| 1 | 46 | `%top` | arena +16 | global `@"_j_const#1"` | works (vbv9/doih) |
| 2 | 55 | `%top` | `alloca i64` | arena +16 | works (sy29) |
| 3 | 80 | `%L16` | `alloca[9×i64]` +32 | `alloca i64` | works (37mt/ixiz) — **the wall-14 stamp source** |
| 4 | **82** | `%L16` | `alloca[9×i64]` +40 | **loaded ptr (`.mem`)** | **WALL 11 — this bead** |
| 5 | 87 | `%L16` | `alloca[9×i64]` +56 | `alloca { ptr, ptr }` +0 | wall 13 (Predicate 8) |
| 6 | 107 | `%L18` | arena +16 | `alloca [1×i64]` | works (sy29 mirror) |
| 7 | 112 | `%L21` | `alloca i64` | arena +16 | works (sy29) |
| 8 | 149 | `%L31` | `alloca i64` | arena +16 | works (sy29) |
| 9 | 160 | `%L40` | `alloca i64` | global `@"_j_const#2"` | works (doih) |

**Site #4 is the ONLY member of its class in the root, and it is K = 1, N = 8,
offset 0.** That is the sy29 §5 vacuity trap in its purest form: at K = 1 with
offset 0 the (SC) exemption (`cell_emitted == cell_meant`,
`instructions.jl:593`) makes *any* address stamp pass.

> **IMPLEMENTER OBLIGATION (non-negotiable, inherited from sy29 §5).** The RED test
> must include a **K ≥ 2** global-root-src fixture, and a **non-zero src offset**
> fixture, asserting `(offset_bytes, elem_width) == (8, 8)` for `k = 1` on the src
> side. A corpus-shaped K = 1 fixture proves nothing about the stamp.

### 5.4 The marker advance — **EIGHT sites, not seven**

| # | file | anchor | note |
|---|---|---|---|
| 1 | `test/test_bvmd_root_scale.jl` | `:665-737` gate (I) | |
| 2 | `test/test_p06b_aggregate_store.jl` | `:768-810` | **wall 12 is p06b's own reject** — this file's gate becomes a positive on its own bead |
| 3 | `test/test_foz5_confined_bounds.jl` | `:842-900` gate (W8) | |
| 4 | `test/test_40ys_instanceless_callees.jl` | `:543-590` | |
| 5 | `test/test_7wsz_ptr_sret_fields.jl` | `:545-590` gate (J) | |
| 6 | `test/test_vau9_variable_memmove.jl` | `:318-350` | |
| 7 | `test/test_57hd_value_identity.jl` | `:1204-1243` gate (W) | carries `@test !occursin("SILENTLY SKIPS", msg)` — **this one FLIPS TO A POSITIVE** |
| 8 | **`test/test_sy29_arena_src_memcpy.jl`** | `:566-612` gate (i) | **NOT in the bead's "seven"** — it is the *arm's own* test file, not a "marker file", and it carries the full discriminator block. Do not miss it. (sy29 §12 made the identical correction: "the four" were six.) |

Per-site edit, verified against the real wall-12 text:

```julia
# RETIRE the wall-11 positive:
#   @test occursin("Bennett-37mt", msg) && occursin("src operand", msg)
#   @test occursin("new::Array.ref.mem", msg)
#   @test !occursin("new::Array.size_ptr", msg)
# REPLACE with the wall-12 positive + the wall-11 regression detector:
@test occursin("Bennett-p06b", msg)
@test occursin("_p06b_cell_ptr_target_kind", msg)      # names the predicate
@test occursin("SILENTLY SKIPS", msg)                  # 57hd (W) flips this line
# LOAD-BEARING NEGATIVE — wall 11 is CLEARED; a 37mt/8bys reject at the corpus
# is now a REGRESSION. This is the successor to the identical-text discriminator,
# and it is STRONGER than the operand-name pair it replaces.
@test !occursin("Bennett-37mt", msg)
@test !occursin("new::Array.ref.mem", msg)   # NB: keep the `.mem` suffix —
                                             # `new::Array.ref` alone IS present.
@test !occursin("Bennett-5viz", msg)         # this arm must not be the new wall
```

Everything else in each block stays: `!base-cancelling`, `!_foz5_confined_dead_bounds`,
`!_57hd_value_identity_cluster`, `!(Bennett-583s && _growend!)`,
`!(Bennett-p06b && gc_alloc_obj)`, `!BYTE-granular getelementptr`, `!Bennett-bvmd`,
`!Bennett-jbko`, `!Bennett-iwo9`, `!Bennett-lgzx`, `!memmove`,
`!store of non-integer type`, `!Bennett-sy29`, `!SCALE-COHERENCE` — **all measured
still-true on the wall-12 message** (probe `p04`). Also update the eight stale
testset titles (several still read "wall 9 to wall 10").

**Forward note to leave for the wall-12 scout** (replacing the current one):
wall 13 is a *second* 37mt/8bys memcpy reject (`memcpy operand alloca has
non-integer element type`) — so `!occursin("Bennett-37mt")` will have to flip back
to a positive one wall later, and the discriminator against wall 11 at that point
is the operand pair (`%0` / `env+56`, no `.mem`). Wall 14 is the bvmd
`SCALE-COHERENCE` reject on `new::#_growend!##0#_growend!##1`, and probe `p10` of
this scout shows it is removed entirely if every env-rooted `IRPtrOffset` is
byte-stamped.

### 5.5 Neighbour baselines re-measured at HEAD (targeted runs, suite mode)

`test_qmv7_gc_loaded_memcpy`, `test_u2kk_param_memcpy`, `test_doih_memcpy_global_src`,
`test_vbv9_arena_memcpy`, `test_37mt_memcpy_const_aligned`,
`test_lqif_memcpy_memmove_reject`, `test_sy29_arena_src_memcpy`,
`test_57hd_value_identity`, `test_bvmd_root_scale` — all green at `e251a03`
(no `Fail`/`Error`/`ERROR` lines under `--check-bounds=yes`). Exposure:

* `test_37mt` — the arm being edited. Every testset is alloca↔alloca or a
  circuit-path reject ⇒ must stay green **byte-identically**; that is the
  `ptr_cells`-gating obligation.
* `test_sy29` — the cascade being widened; its GATE (b)-style `ptr_cells=false`
  controls pin the unchanged Predicate-6 text.
* `test_doih` — the G1-G9 global-src cascade. 5viz must **not** route through
  `_handle_memcpy_global_src`: Predicate 5b (`_src_reaches_global`) is a *syntactic*
  global reference and stays `false` here. Keep 5viz on the non-global path.
* `test_57hd` — §4b is *used*, not *changed*; every gate must stay green unchanged.
  If any 57hd gate moves, the arc has drifted into §4b and the tripwire re-fires.
* `test_qmv7` — the `gc_loaded` dst branch must still be consulted **before** the
  new src branch.
* Also re-check `_bvmd_reject_normalised_alloca!` (`src/lowering/driver.jl`) still
  fires for `ptr_cells=true` + `lower()`.

---

## 6. Corrections to the bead text

1. **"copying the LOADED .mem half of the MemoryRef into a closure-env slot … it is
   a POINTER being copied into the env"** — the *address* is the `.mem` pointer; the
   *value copied* is the `Memory` header's `i64` **length**, into the closure's fifth
   `Int64` field. §1.2, with the env layout as evidence. This changes Predicate 8's
   reading and removes the Bennett-land provenance question entirely.
2. **"whether the src root is provably the gc_alloc'd Memory"** — there is **no**
   gc_alloc'd `Memory` in this program. `Int64[]` yields the shared *empty*
   singleton, modelled as a 16-byte zero `.globals` blob by the shipped
   `bennettvm-416r.13 / CW-D3 Lever 2` arm. The certification target is a **global
   root**, not an arena root.
3. **"the reject text is IDENTICAL to wall 9's — the ONLY message-text discriminator
   is the operand name"** — true of the reject *sentence*; the `_ir_error` prefix
   also differs in block label and dst operand (§1.3). The operand name remains the
   right discriminator (the other two are 0ncn-fragile).
4. **"the SEVEN advanced marker files"** — there are **eight** corpus-gate sites;
   `test/test_sy29_arena_src_memcpy.jl` gate (i) is the extra (§5.4).
5. **"wall 14 = bvmd SCALE-COHERENCE"** — correct, and it is *pre-existing*: raised
   by the already-shipped site-#3 memcpy's word stamp, not by anything 5viz emits
   (§3). Probe `p10` shows it vanishes under uniform byte stamping.
6. Sy29 §1.1's "`_module_has_sret(root) == false`, no passes prepend" does **not**
   hold at this HEAD — `sroa`/`mem2reg` are prepended (§1).

---

## 7. Recommended arc

1. **RED first** (CLAUDE.md §3): `test/test_5viz_loaded_ptr_src_memcpy.jl` with
   (a) a corpus-shaped fixture (loaded ptr canonicalising to a `.globals` root,
   K = 1, offset 0); (b) **a K ≥ 2 fixture pinning `(8, 8)` on the src side**;
   (c) **a non-zero src offset** fixture; (d) a src whose canon does *not* reach a
   global — must fail loud, unchanged message; (e) a same-root global↔global reject;
   (f) a canonicalised-global **DST** reject; (g) an over-long src (`off + N > 16`)
   6d reject; (h) a `ptr_cells=false` byte-identity control on the unchanged
   Predicate-6 text.
2. **GREEN**: the `_handle_memcpy_arm` widening of §2.3 + the two-hop
   `suppressed_refs` plumbing. Nothing in `src/extract/instructions.jl`'s §4b region
   (`~1844-2600`) changes.
3. **BennettVM**: `test_5viz_global_src_vm.jl` — E2E oracle under both history
   regimes with exact `unrun!`, asserting no `IntrinsicMemcpy`/`IntrinsicMemmove`
   and that the `GLOBAL_BASE` read returns the seeded cell. **Expect ZERO BVM
   `src/` change; if that turns out false, stop and escalate.**
4. **Marker advance**: the eight sites of §5.4, each verified against the real
   wall-12 text, plus the stale titles.
5. **File / record**: probe `p10`'s result on `Bennett-bvmd` (wall 14 is one stamp
   decision away); note on `Bennett-8bys` that corpus site #5's
   `alloca { ptr, ptr }` src class remains its territory; note on the wall-12 bead
   that its own message lacks the `Bennett-1zow` tag *and* that
   `_p06b_granularity_violation` sits immediately behind it.
6. **Do not** touch §4b, `_root_scale`, the dst stamp rule, `Bennett-21rj`, or the
   doih global-src path.

---

## 8. Tripwire — **REDUCED**

No trigger fires, and each non-firing is measured (see the table in the VERDICT).
The one genuinely contested question that surfaced — the dst-side stamp for a
byte-GEP'd word-tier alloca — is **out of scope by construction** (§3): 5viz's dst
is shape-identical to an already-shipped site, so the bead can neither create nor
resolve wall 14. If the implementer or reviewer concludes that 5viz *must* change
the dst stamp rule, that is a scope change and the tripwire should be re-armed at
that moment, because it would be a `Bennett-bvmd` tier decision with blast radius
across three shipped arms.
