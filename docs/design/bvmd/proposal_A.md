# Bennett-bvmd — PROPOSER A

**Bead:** `Bennett-bvmd` (P1) — xkl frontier wall 8.
**HEAD:** `e8b21a4`. Sister BennettVM.jl `d44f1c3`.
**Basis:** `docs/design/bvmd_scout.md`, **independently re-verified** (§0 below).
No `src/`, no `test/`, no commit. Every stamp/cell claim below is a measured
probe output, not a derivation.

---

## 0. Re-verification of the scout's load-bearing claims

Run under `julia --project --check-bounds=yes` at `e8b21a4`, probes from the
session scratchpad. I re-ran rather than re-derived; all four reproduce.

| claim | probe | result |
|---|---|---|
| wall 8 is the p06b `gc_alloc_obj` (P4b) reject in the **ROOT** `%top` | `b01_wall.jl` | reproduced verbatim; markers `gc_alloc_obj`/`BYTE-granular`/`Bennett-p06b` **true**, `583s`/`base-cancelling`/`jbko`/`iwo9`/`lgzx`/`memcpy`/`37mt` **false** — scout's table exact |
| the byte/word split is **already live** | `b04_stamps.jl` | `IRPtrOffset(:b8, obj, 8, 8)` → cell **+8** vs `IRPtrOffset(:w1, obj, 8, 64)` → cell **+1** |
| (P5) fires on the corpus use-shape | `b06_p5.jl` | fires: *"addressed at BOTH the WORD granularity … and an incompatible granularity, via the single-index BYTE-granular getelementptr"* |
| alloca reservation ≠ addressing (z2ia) | `b09_alloca.jl` | `IRAlloca(:env, 64, ConstOperand(9))` (9 cells) vs `IRPtrOffset(:g56, env, 56, 8)` (cell **+56**) |

Corpus census re-counted directly from `root.ll`: **6** class-D two-index
`{ptr,ptr}` GEPs on `%"new::Array"` (lines 45/47, 111/113, 164/166 — three
blocks), **10** literal `{i64,ptr}` header GEPs, and the closure env addressed
**exclusively** by `gep i8` at byte offsets 8/16/24/32/40/56.

**Three facts I established that the scout report does not contain.** Each is
load-bearing for my route:

* **F1 — BVM alloca reservation ignores `elem_width`.** `_lower_alloca!`
  (`BennettVM/src/ir/ingest_body.jl:558-605`) reserves `N` cells and advances the
  cursor by `N`; its docstring states *"`elem_width` (in bits) does NOT enter the
  address"*. So `IRAlloca(dest, 8, 72)` reserves **72 cells today, with zero BVM
  src change**.
* **F2 — byte-normalising a reservation is wire-count-neutral in the gate path.**
  `_lower_alloca_const_n!` (`src/lowering/memory.jl:34-51`) allocates
  `elem_width * n` **bits**. `64 × 9 = 8 × 72 = 576`. The rewrite
  `(w, n) → (8, (w÷8)·n)` is **byte-identical in wires** and **8× larger in VM
  cells** — exactly the asymmetry z2ia needs.
* **F3 — BVM memory is sparse.** `IState.memory::Dict{Int64,Int64}`
  (`BennettVM/src/ir/IState.jl:319`) with a zero-init convention. Over-reserving
  cells costs arena cursor space only — no storage, no wires (with F2).

Together F1+F2+F3 mean the containment half of this bead is **free**.

---

## 1. Route decision

### 1.1 The scout's framing, sharpened

The scout treats "coherent granularity discipline" as one property. It is
**two independent properties**, and every failure in this arc is one or the other:

* **(AGREE)** — the *map*. For one object, byte offset `b` must be sent to the
  same cell by every access class. Violating it is a **silent wrong answer**
  (p06b's "EXPECTED 42, ACTUAL 0"; the class-A/class-D split at `b=8`).
* **(CONTAIN)** — the *reservation*. Every cell an access touches must lie inside
  the object's reservation. Violating it is a **silent adjacent-allocation
  clobber** (z2ia: cell +56 in a 9-cell reservation).

Conflating them is why the design looks intractable. Separated:

> **(CONTAIN) can be discharged unconditionally, with no tier classification at
> all, at zero cost — because over-reservation is monotone-safe.**

If an object is reserved in *bytes* (`nbytes` cells), then a word-stamped access
lands at `b÷8 ≤ b < nbytes` and a byte-stamped access lands at `b < nbytes`.
**Both** are contained. Over-reserving can never break (AGREE), because (AGREE)
is a statement about the map, not the size. With F2 it costs no wires and with
F3 no storage.

That leaves (AGREE) as the only genuinely contested question — and it is a
strictly smaller one than the scout's three-arm framing suggests.

### 1.2 Chosen route: **α, refined** — *root-tier stamping with a single shared stamp function, plus unconditional unit-normalised reservations*

I choose **α (per-root tier tagging)** for (AGREE), and add a component the
scout's α/β split does not contain — unit normalisation — for (CONTAIN).

**Why α over β.** β ("make the word side conform" / byte-cell reservations) is
what my (CONTAIN) half *is*, and I adopt it there. But β cannot carry (AGREE):
reservations say nothing about which cell `gep {ptr,ptr} %obj,0,1` names. Under
β alone the class-D GEP still emits `ew=64` → cell +1 while the store writes +8,
and the corpus is still wrong. β is necessary and insufficient for the same
reason the bead's one-liner is.

**Why not fail-loud-first as the whole arc.** I do take a fail-loud *first
commit* (§2.6), but not as the terminus: a blanket "refuse any object addressed
at two granularities" guard would have to fire on the 416r.13 singleton headers
(literal `{i64,ptr}` at word-shaped GEPs, byte-stamped by the shipped type
predicate, and byte-addressed elsewhere) — i.e. it would refuse a
**shipped, correct** configuration. A guard that cannot express the shipped
convention is not a guard, it is a regression.

**Why not the tempting shortcut.** The cheapest-looking (AGREE) fix is to widen
the D4 type predicate from *literal `{i64,ptr}`* to *any literal struct*
(Julia's codegen emits literal structs; clang emits named `%struct.T`). It is
depth-0, needs no provenance, and I verified it would be **byte-identical on the
entire existing test corpus** — the only literal-struct two-index GEPs anywhere
in `test/` are the two in `test_9n3y_memheader_gep.jl:58,60`. **I reject it
anyway.** It is unsound in the direction that matters: a `malloc(16)` object
addressed by `gep {i64,i64}, ptr %p, 0, 1` would flip from cell +1 (inside a
2-cell reservation) to cell +8 (outside it) — trading the corpus's silent wrong
answer for a new silent clobber, on a shape no test covers. Type literalness is
a proxy for provenance; provenance is what actually determines the reservation,
so provenance is what must drive the stamp.

**The scout's stated objection to α is refuted by the code.** §7.2 calls α "a new
global-ish analysis in an extractor that is deliberately depth-0 everywhere".
Three depth-8-bounded root walkers already ship and are already used by vbv9 and
p06b: `_alloca_root_ref` (`instructions.jl:20-32`), `_gc_alloc_root_ref`
(`:688-711`), `_param_ptr_root_ref` (`:714+`). Tier classification is a **fourth
thin wrapper composing the three**, not a new analysis. α is the cheap route,
not the expensive one.

### 1.3 The coherence table (probe-backed)

Corpus object `%"new::Array"` = `julia.gc_alloc_obj(task, i64 24, +Core.Array)`;
BVM reserves `_byte_cells(24)` = **24 cells** (`intrinsics.jl:256-261`). Cell
recovered by BVM as `offset_bytes ÷ (elem_width ÷ 8)`
(`ingest_body.jl:495-535`). "today" columns are `b04`/`b07` measurements.

| class | LLVM shape | byte off | today ew | today cell | **proposed ew** | **proposed cell** |
|---|---|---|---|---|---|---|
| A | `gep i8 %obj, 8` → `store ptr null` | 8 | 8 | +8 | 8 | **+8** |
| B | `gep i8 %obj, 16` → memcpy dst | 16 | 8 | +16 | 8 | **+16** |
| C | `gep i8 %obj, 16` → memcpy src ×3 | 16 | (walls, 37mt) | — | 8 | **+16** |
| D | `gep {ptr,ptr} %obj, 0, 0` ×3 | 0 | 64 | +0 | **8** | **+0** |
| D | `gep {ptr,ptr} %obj, 0, 1` ×3 | 8 | 64 | **+1** ❌ | **8** | **+8** ✅ |
| E | aggregate store, field 0 | 0 | WALL | — | 8 | **+0** |
| E | aggregate store, field 1 | 8 | WALL | — | 8 | **+8** |
| F | cell-opaque (roots array, throw) | — | n/a | n/a | n/a | n/a |

**Verdict: the proposed column is the identity map `b ↦ b`, single-valued, and
every cell is `< 24`.** (AGREE) ✅ and (CONTAIN) ✅. Today's column is
two-valued at `b = 8` — the defect, live now.

Three further objects, same discipline, showing the C tier and the shipped
convention are untouched:

| object | root | tier | stamps | map | change |
|---|---|---|---|---|---|
| closure env `alloca [9 x i64]` | alloca | :word | all `gep i8` → ew 8 | `b ↦ b`, max +56 | reservation 9 → **72 cells** (F2: 576 wires either way) — z2ia closed |
| 416r.13 singleton, `gep {i64,ptr} @jl_global#93, 0, 1` | **global** (no root) | :unknown | type predicate → ew 8 | +8 | **unchanged** (union carve-out) |
| C tier `%struct.ht` on `malloc`/`alloca` | malloc/alloca | :word | named struct → ew 64 | `b ↦ b÷8` | **unchanged**; reservation over-reserves (safe) |

The 416r.13 row is why the discriminator must be a **union, never a
replacement** — verified: both `test_9n3y_memheader_gep.jl` fixtures root at a
function **parameter** (`ptr noundef %m`), so tier is `:unknown` for both, and
only the type predicate separates them. Union preserves both controls exactly.

---

## 2. Mechanism

### 2.1 `_cell_tier` — one classifier, composed from shipped walkers

```
_cell_tier(v, names, ptr_cells) -> :byte | :word | :unknown
```

* `_gc_alloc_root_ref(v) !== nothing` → **`:byte`** (BVM `_byte_cells`).
* GenericMemory-alloc root → **`:byte`** (`GM_HEADER_CELLS + _byte_cells`).
* `_alloca_root_ref(v) !== nothing`, or an `_M4_C_ALLOCATOR_NAMES` call root →
  **`:word`** (status quo; C tier).
* `_param_ptr_root_ref(v) !== nothing`, a global, or an unwalkable chain
  (ptr-`phi`/`select`, the cc0 M2b WIDTH-0 sentinel) → **`:unknown`**.

`:unknown` is **not** silently defaulted to `:word`. It means "no tier proof",
and each consumer states what it does with that (§2.2–§2.4) — the prose-vs-
predicate rule: no message may claim a tier the classifier did not return.

### 2.2 One shared stamp function — the anti-drift lemma

The single most important structural decision in this proposal:

> `_cell_elem_width(base_or_gep, names, ptr_cells) -> 8 | 64` is defined **once**
> and called by **all four** consumers: the D4 GEP emission, the (P5) scan, the
> p06b store decomposition, and the vbv9 memcpy dst.

```
_cell_elem_width(g) = (_is_genericmemory_header_struct(src_ty(g))   # UNION arm:
                       || _cell_tier(base(g)) === :byte) ? 8 : 64   # shipped 416r.13
```

This mirrors p06b's own stated design principle (`instructions.jl:5736-5740`:
*"byte-identical IN FORM to the arm that already emits it … which is what makes
cell agreement a syntactic identity rather than a claim about two code paths"*)
and extends it from *form* to *value*. **(P5) verifies by calling the emitter's
own stamp function**, so the checker and the emitter cannot drift. This is what
makes the coherence argument a lemma rather than a review obligation.

### 2.3 D4 re-stamp (`instructions.jl:4977`)

```
- ew_gep = _is_genericmemory_header_struct(src_type_gep) ? 8 : 64
+ ew_gep = _cell_elem_width(inst, names, ptr_cells)
```

Pure union: byte-identical wherever `_cell_tier ≠ :byte`, which includes every
C-tier test and both 9n3y controls (verified §1.3). `:unknown` → falls through to
the type predicate → status quo. Scope: this arm only; the `offset_bytes % 8`
cell-alignment guard is **kept** for `:word` and **relaxed to `% 1`** (vacuous)
for `:byte`, since a byte-tier field need not be cell-aligned.

### 2.4 p06b: (P4b) admission, (P4c) in byte units, (P5) tier-parametrised, emission

* **(P4b)** `_p06b_cell_ptr_target_kind` gains a `:gc_alloc` kind returning
  `(:gc_alloc, nbytes)` when the callee is `julia.gc_alloc_obj` with a constant
  `nbytes` operand. Non-constant `nbytes` → certifies 0 (mirrors the existing
  malloc rule). The `_p06b_target_kind_name` gc_alloc paragraph
  (`:450-459`) is **replaced**, not deleted — its "Byte-stamped admission is a
  future widening" sentence is now false and must not survive.
* **(P4c)** for `:gc_alloc`, capacity is compared in **bytes**:
  `max(o_k) + 8 ≤ nbytes`. Corpus: `8 + 8 = 16 ≤ 24` ✅. This is *stronger* than
  the `:load` case the arm currently cannot certify at all (the scout's
  "strengthening opportunity" — I take it).
* **(P5)** becomes `_p06b_granularity_violation(pv, st, ew_store)`. The scan no
  longer hard-codes an accepting shape; for each GEP use it compares
  `_cell_elem_width(use)` against `ew_store`. Disagreement is the violation.
  This **subsumes** today's rule (for `:word` targets it accepts exactly the
  two-index-struct-with-leading-0 set and rejects every single-index GEP, since
  those stamp 8 ≠ 64 — byte-identical) and **inverts** correctly for `:byte`
  targets (single-index `i8` GEPs stamp 8 = 8 → accept; the D4 GEPs now also
  stamp 8 → accept). The D2 index-0 carve-out stays dropped; the N2/D3
  `_p06b_slot_key` / `_p06b_alias_group` machinery is reused **verbatim** — it
  folds to byte offsets already and never consults `elem_width`.
* **Emission** (`:5749`): `IRPtrOffset(aname, base_p06b, offs_p06b[k+1], ew_store)`
  where `ew_store = _cell_elem_width(ptr, …)`. One 64-bit `IRStore` per field,
  unchanged — BVM's `MemoryStore` carries no width and writes a whole cell
  (`memory_floor.jl:156-168`); eight single-byte stores are neither expressible
  nor correct.
* The `fw[k+1] == 64 && off_k == 8k` field-layout loop (`:5596-5605`) is
  **kept as-is**. It constrains the *value*'s field layout, not the target's
  granularity; the corpus `{ptr,ptr}` satisfies it. Do not touch it.

### 2.5 z2ia — unit-normalised reservations, at the emission site only

At the **`IRAlloca` emission point** (not inside `_alloca_reservation`), when
`ptr_cells` and the count is a `ConstOperand` and `w % 8 == 0`:

```
IRAlloca(dest, w, n)  ->  IRAlloca(dest, 8, (w ÷ 8) * n)
```

Corpus: `IRAlloca(:env, 64, 9)` → `IRAlloca(:env, 8, 72)`. Cells 9 → 72, covering
the `gep i8 …, 56` write (F1). Wires 576 → 576 (F2). Storage unchanged (F3).

**Deliberately at the emission site, not in `_alloca_reservation`.** That helper
is shared with `_p06b_alloca_cells`, which requires `ew == 64 || return 0`
(`:348`); normalising inside it would make every alloca certify capacity 0 and
turn (P4c) into a blanket reject — a regression on currently-green tests and on
wall 11. Keeping `_alloca_reservation` returning the original `(w, n)` leaves
(P4c) certifying *word* cells against a *byte* reservation, which is
conservative in the safe direction (bytes ≥ words). **This is the single
sharpest implementation trap in the arc; an implementer who "cleans it up" by
normalising in the helper will break the tree.**

**MEASURED CONSTRAINT — the normalisation MUST be gated on `ptr_cells`.** I
probed the gate backend's `alloca_info` consumers (R6) and the hazard is real,
not hypothetical. `src/lowering/aggregate.jl:261-273` reads
`ew = first(info)` and computes `new_idx = o.idx_op.value + div(offset_bytes*8, ew)`
— the `PtrOrigin` slot index is in **element** units. Under normalisation `ew`
becomes 8, so byte offset 56 becomes slot index **56 of 72 eight-bit slots**
instead of slot 7 of 9 sixty-four-bit slots, and `_pick_alloca_strategy(info, …)`
(`src/lowering/memory.jl:670`) then drives `_emit_store_via_shadow_guarded!` to
store an **8-bit** slot for a 64-bit value. F2 guarantees the total wire count is
invariant; it does **not** guarantee slot *semantics*. So:

> Normalisation is emitted **only when `ptr_cells == true`** (the BVM path).
> The gate-lowering path keeps `(w, n)` exactly as today, byte-identically.

If a `ptr_cells` ParsedIR is ever gate-lowered, `aggregate.jl:261` and
`_pick_alloca_strategy` must be re-examined first — flag it in the arm comment.

**Scoped out, with a named refusal:** dynamic-`n` allocas (`DynAlloca`). Byte-
normalising them needs an emitted `IRBinOp(tmp, :mul, n, 8)`, which changes
`DynAlloca` arity expectations in BVM tests. z2ia's corpus witness is static, so
static normalisation closes the measured defect. The dynamic case keeps today's
behaviour and is filed as a residual on `Bennett-z2ia` — **not** silently
inherited.

### 2.6 vbv9 K≥2 (`Bennett-4y0d`) — in scope, one line

`_handle_memcpy_global_src` (`:2191-2209`) sets `dst_ew = 64`; it becomes
`_cell_elem_width(dst, …)`. For K=1 the offset is 0 → cell 0 under either stamp,
so `test_vbv9_arena_memcpy.jl:150-161` stays green byte-identically; for K≥2 on a
gc_alloc dst the offsets become byte-true. It is the same function call as the
other three arms — excluding it would leave a known-wrong arm consulting a
different rule, which is precisely the incoherence this proposal exists to end.

### 2.7 BVM src changes: **NONE**

Explicitly, and verified: F1 (reservation ignores `elem_width`, bumps by `N`),
`ingest_body.jl:495-535` (`IRPtrOffset` divisibility guard is
`offset_bytes % ew_bytes`, trivially satisfied at `ew_bytes == 1`, and negative
offsets already relaxed per `bennettvm-p81t`), and `_alloc_cells(IntrinsicGCAlloc)`
already byte-granular. Everything above is extraction-side. **This should be
confirmed by an E2E probe before the implementer writes any BVM code** — if a
BVM change turns out to be needed, the route is wrong and should be re-reviewed,
not patched.

### 2.8 Commit sequencing

* **C1 (no admission, tree green).** `_cell_tier` + `_cell_elem_width` +
  unit-normalised static reservations + the D4 re-stamp. Closes z2ia. Wall 8
  still stands, but now at (P4b) with an *accurate* message.
* **C2 (admission).** (P4b)/(P4c)/(P5)/emission + vbv9. Wall 8 clears; wall 9
  (37mt arena-src memcpy) becomes the new wall.
* **C3.** The synthetic §4a-debt E2E fixture + marker advances (§4).

C1 is independently valuable and independently revertible — if C2 is rejected in
review, z2ia still closed.

---

## 3. Failure modes and message territory

**Predicted new wall after C2** (from `b05_seq.jl`, re-verified as the scout's
measured order): **wall 9 = the 37mt arena-src memcpy**, message anchored on
`memcpy` / `Bennett-37mt`.

Per-file prediction — the honest split between "must be re-authored" and "must
stay byte-identical":

| file | predicted | why |
|---|---|---|
| `test_9n3y_memheader_gep.jl` | **GREEN, byte-identical** | both fixtures root at a param → tier `:unknown`; literal arm held by the type predicate (8), named arm by its absence (64). The union control. |
| `test_haiy_ptr_cells_store_load_gep.jl`, `test_nd45_*.jl` | **GREEN, byte-identical** | malloc/alloca roots → `:word`; named structs → 64. The C-tier byte-identity obligation. |
| `test_vbv9_arena_memcpy.jl:150-161` | **GREEN** | K=1 → offset 0 → cell 0 under either stamp |
| `test_p06b_aggregate_store.jl` (N3) | **RED — re-author** | asserts the gc_alloc reject fires. Inverts. Also pins the string `9n3y`, a **dangling ID** (§5) — drop it while re-authoring. |
| `test_p06b_aggregate_store.jl` (k) | **RED — re-author** | keep the `!(p06b && _growend!)` body-scope term; **re-point** the `!p06b \|\| gc_alloc_obj` discriminator (it inverts) |
| `test_p06b_aggregate_store.jl` (g4)/(D2)/(D7)/(N2)/(D3) | **at risk** | the whole (P5) surface; each needs a tier-explicit control added, not a deletion |
| `test_foz5_confined_bounds.jl` (W8) | **RED — re-author** | positive `gc_alloc_obj \|\| BYTE-granular`; inverts |
| `test_40ys_*.jl:535,550`, `test_7wsz_*.jl:549,555` | **RED — re-author** | same two-part advanced-wall marker; inverts |
| `test_6bu3:233`, `test_8bys:169`, `test_8g7m:311`, `test_beaw:215`, `test_a70z:987`, `test_583s:330` | **GREEN, but NOT evidence** | tolerant disjunctions that merely mention `gc_alloc_obj`; their greenness proves nothing about this arc |

**What is NOT guarded, stated plainly** (prose-vs-predicate): the shared-stamp
lemma guarantees D4/store/(P5)/vbv9 agreement *by construction*, and (P5)
scans an object's uses only when an aggregate store targets it. An object
addressed at two granularities that **never receives an aggregate store** — e.g.
a `gep i64, ptr %obj, 3` (stamps 64 → cell 3) alongside `gep i8, ptr %obj, 24`
(stamps 8 → cell 24) on a `:word` object — is **not** scanned and would still
mis-map silently. No predicate in this proposal catches it. It is a strictly
pre-existing hole (nothing here widens it), and it should be filed as a residual
rather than implied closed. Closing it needs a per-object use scan at every GEP,
which is not depth-0 and is out of scope.

---

## 4. Test plan

**Unit gates (distilled `.ll`, no corpus dependency)** — the (N3) replacement.
The scout's three-part contract, which I adopt and extend to five:

1. **Byte-tier emission.** `julia.gc_alloc_obj(task, 24, tag)` target, `{ptr,ptr}`
   aggregate store → assert **exactly** `IRPtrOffset(_, obj, 0, 8)` and
   `IRPtrOffset(_, obj, 8, 8)` (constructor-level equality, not `occursin`).
2. **Word-tier negative control.** The same store into `malloc(16)` → `ew == 64`,
   unchanged.
3. **Union control.** A 416r.13-shaped `load ptr, ptr @"jl_global#N"` header GEP
   → still `ew == 8` despite tier `:unknown`.
4. **Class-D agreement.** Byte GEP at +8 **and** `gep {ptr,ptr} 0,1` on the same
   gc_alloc object → assert both emit `ew == 8`, i.e. one cell. This is the
   corpus shape and the one no existing test covers.
5. **z2ia.** `alloca [9 x i64]` + `gep i8 …, 56`, extracted with
   `ptr_cells=true` → assert `IRAlloca(_, 8, ConstOperand(72))`; and the
   **gate-path control**, the same fixture with `ptr_cells=false` → assert
   `IRAlloca(_, 64, ConstOperand(9))` **unchanged** (R6 — this is the assertion
   that keeps the gate backend's 64-bit shadow slots intact). Plus a wire-count
   equality against the pre-change baseline (F2 — the claim that makes the fix
   free, so it must be pinned, not asserted in prose).

**Corpus gate.** `extract_parsed_ir_set_from_julia(_pushbvmd, Tuple{Int64};
ptr_cells=true)` advances to wall 9. Positives disjoined (non-numeral anchors,
Bennett-0ncn): `occursin("memcpy", msg) || occursin("Bennett-37mt", msg)`.

**Marker advances — including the inversion trap.** Load-bearing negatives:

* `!(occursin("Bennett-p06b", msg) && occursin("gc_alloc_obj", msg))` — **the
  inverted (N3)/(k) discriminator.** After bvmd a p06b reject naming
  `gc_alloc_obj` is a regression, not the expected wall.
* `!occursin("BYTE-granular getelementptr", msg)` — (P5) must not be the new
  wall; if it is, the D4 re-stamp was skipped and the arc is a no-op.
* **DROP the blanket `!occursin("Bennett-583s", msg)`** — wall 10 *is* a 583s
  reject in the root body. Replace with the foz5 two-part pattern: body scope
  `!(occursin("Bennett-583s", msg) && occursin("_growend!", msg))` **plus** a
  live-value discriminator anchored on the `udiv exact` shape. **This is bvmd's
  own marker trap, set for it by foz5.**
* Retain `!lgzx`, `!"store of non-integer type"`, `!jbko`, `!iwo9`, `!memmove`.

**Synthetic §4a-debt E2E (BVM side), with the honest note.** The scout's
six-part fixture, adopted unchanged in shape: gc_alloc box (24 B) → decomposed
aggregate store at 0/8 → a class-D read *and* a byte read of the same object →
closure-env alloca written by extracted code and read back through a byte GEP →
a `ptrtoint`/`sub`/`icmp`/`br` confined guard over it. Assertions: (a) forward
run matches a hand-computed oracle; (b) `unstep!` to entry restores the initial
`IState` **exactly** (arena cursor, memory, locals) — the Bennett-1973
invariant; (c) an out-of-bounds input halts at `:__unreachable__`.

**The honest note, which must appear in the commit message and the worklog, not
only here:** this fixture discharges the §4a debt **for the mechanism**, on a
program that has the mechanism. It does **not** discharge it for the corpus.
Walls 9/10/11 and `bennettvm-rxgy` still block corpus runnability, so the bead's
claim that clearing wall 8 "lets the full push! corpus RUN" is **false** —
measured. Assertion (c) is constructible only in the fixture: on the real corpus
`push!` on a fresh `Vector` never takes the `oob` edge, so §4a's residual ("the
throw may be missed, or the halt spurious") stays undischarged by any test this
arc can write. File the follow-up bead gated on 9+10+11+rxgy.

---

## 5. Risks

| # | risk | severity | mitigation |
|---|---|---|---|
| R1 | Implementer normalises inside `_alloca_reservation` → `_p06b_alloca_cells` returns 0 for every alloca → (P4c) blanket reject | **high** | §2.5 states the trap explicitly; unit gate 2 (word-tier control) and the wall-11 marker catch it |
| R2 | Implementer ships the (P4b) widening only (the bead's one-liner) → (P5) becomes the wall → no-op arc | **high** | measured by `b06_p5.jl`; marker `!occursin("BYTE-granular getelementptr")` fails the build |
| R3 | `_cell_tier` replaces rather than unions the type predicate → 416r.13 singletons silently demoted to word | **high** (silent miscompile) | union is structural in `_cell_elem_width`; unit gate 3 is the control |
| R4 | Tier `:unknown` silently defaulted to `:word`, hiding a ptr-phi/select object | medium | `:unknown` is a distinct return; the admission path must not accept it without the type predicate |
| R5 | Over-reservation shifts arena cursor → BVM tests pinning absolute addresses go red | medium | F3 makes it storage-free but **not** address-free; expect churn in address-pinning BVM tests. Grep for literal arena addresses before C1 |
| R6 | `alloca_info` slot-index semantics change under normalisation — **PROBED, CONFIRMED REAL** (`aggregate.jl:261-273` divides by `elem_width`; `_pick_alloca_strategy` sizes the shadow slot) | **high** | resolved in §2.5: normalisation is **gated on `ptr_cells`**, gate path byte-identical. Unit gate 5 pins the wire count; a gate-path control pins `(64, 9)` unchanged |
| R7 | The unguarded two-granularity object with no aggregate store (§3) | low (pre-existing) | file as residual; do not claim closed |
| R8 | Six advanced-wall markers invert across four files; a partial re-author leaves a stale positive that passes vacuously | medium | §3 table enumerates all of them; re-author in the same commit as C2 |
| R9 | `bennettvm-9n3y` dangling-ID claim taken from the scout, **not independently re-verified by me** | low | implementer should confirm against both trackers before deleting the pinned string |

**Biggest risk: R8 (marker churn), now that R6 is closed.** R6 was my largest
open risk; I probed it rather than shipping it as a hunch, and it is **real** —
which is precisely why the normalisation is `ptr_cells`-gated in §2.5. Had it
been left unprobed, an implementer following the un-gated version would have
silently broken 64-bit shadow stores in the gate backend. R8 is now the largest
residual: six load-bearing markers across four files invert together, and a
partial re-author leaves vacuous positives that pass while proving nothing.

---

## 6. Diff shape (touch points only)

**Bennett.jl — `src/extract/instructions.jl`** (all of it; no other src file):

* `+ _cell_tier(v, names, ptr_cells)` — new, ~25 LOC, composes the three shipped
  root walkers. Sited next to `_gc_alloc_root_ref` (`:688`).
* `+ _cell_elem_width(g, names, ptr_cells)` — new, ~10 LOC. The shared stamp.
* `~ :4977` D4 GEP arm — one line; the `% 8` alignment guard gains a `:byte` arm.
* `~ :342-360` `_p06b_alloca_cells` — **untouched** (deliberately, §2.5).
* `~ :386-416` `_p06b_cell_ptr_target_kind` — `+ :gc_alloc` kind.
* `~ :420-468` `_p06b_target_kind_name` — replace the gc_alloc paragraph.
* `~ :578-636` `_p06b_scan_uses` / `_p06b_granularity_violation` — tier
  parameter; the accepting test becomes a stamp comparison. `_p06b_slot_key` /
  `_p06b_alias_group` **unchanged**.
* `~ :5627-5694` (P4b)/(P4c)/(P5) call sites.
* `~ :5749` emission — `ew_store` instead of literal `64`.
* `~ :2191-2209` vbv9 `dst_ew`.
* `~` the `IRAlloca` emission site — unit normalisation (static-`n` only).

**BennettVM.jl:** **none** (§2.7), pending the E2E confirmation probe.

**test/**: 4 files re-authored (`test_p06b_aggregate_store.jl`,
`test_foz5_confined_bounds.jl`, `test_40ys_instanceless_callees.jl`,
`test_7wsz_ptr_sret_fields.jl`); 1 new (`test_bvmd_cell_tier.jl`, the five unit
gates); 1 new BVM-side synthetic E2E.

**Beads:** close `Bennett-z2ia` (static case) with a filed residual for
dynamic-`n`; close `Bennett-4y0d`; file the §3 unguarded-object residual and the
§4 corpus-runnability follow-up (gated on walls 9/10/11 + `bennettvm-rxgy`).

**Nomenclature:** `bennettvm-9n3y` is a **dangling ID in both trackers**
(scout §4, which I did not re-verify). The live filings are `Bennett-zdd6` and
`bennettvm-rxgy`. Do not add new `9n3y` references; drop the one pinned as a
string in `test_p06b_aggregate_store.jl` (N3) while re-authoring it.
