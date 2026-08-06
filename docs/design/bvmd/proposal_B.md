# Bennett-bvmd — PROPOSER B

**Bead:** `Bennett-bvmd` (P1) — xkl frontier wall 8, the ROOT body's
`julia.gc_alloc_obj` byte-granular aggregate-store refusal.
**HEAD:** `e8b21a4`. **Sister:** BennettVM.jl `d44f1c3`.
**Written blind of `proposal_A.md`** (not opened). Scout report
`docs/design/bvmd_scout.md` was read and every load-bearing claim in it was
**re-executed**, not inherited.

**Probes** (session scratchpad `…/scratchpad/pB/`): `validator.jl` (post-hoc
root-scale checker), `patch.jl` (the demonstrative source patch, applied via
`@eval Bennett include(...)` — **no file under `src/` or `test/` was modified**;
`git status` shows `src/` and `test/` clean), `run1.jl`, `run2.jl`, `run3.jl`,
`run4.jl`, `runtests_patched.jl`, `e2e_bvm.jl`. All Bennett runs under
`julia --project --check-bounds=yes` (suite mode); the BVM E2E under
`--project` in `BennettVM.jl` with the same flag. **No commits.**

---

## 0. VERDICT UP FRONT

**Route α′ — ROOT-SCALE COHERENCE.** A refinement of the scout's α that removes
its main objection ("a new global-ish analysis in a deliberately depth-0
extractor"). The tier is **not an invented tag**. It is a *ratio that BennettVM
already fixes, per allocator, in shipped code*: `scale(R) = bytes per cell`.
The extractor does not decide the tier — it **reads** it off the same allocator
table BVM's `_alloc_cells` implements, exactly as `_alloca_reservation` is
already the "single source of truth" shared between the alloca arm and
`_p06b_alloca_cells`.

Executed results, all four in this document:

| claim | status |
|---|---|
| the route clears wall 8 and advances the corpus to **wall 9** (`Bennett-37mt` memcpy) | **MEASURED** (`run2.jl`) |
| every access class on the corpus object lands on **one** cell map | **MEASURED**, 0 violations (`run4.jl`) |
| BennettVM runs it, oracle-matches, and `unrun!` restores the entry `IState` exactly | **MEASURED**, **zero BVM src changes** (`e2e_bvm.jl`) |
| blast radius on the pinned surface is *only* the intended marker inversion | **MEASURED**, 17 files (`runtests_patched.jl`) |

**β is rejected** and the rejection is structural, not aesthetic — see §1.3.
**Fail-loud-first is not rejected**: it is adopted as *commit 1 of 2*.

---

## 1. Route decision and the coherence argument

### 1.1 The invariant

BennettVM is cell-addressed: one `Int64` per cell, and a pointer *is* a cell
index. `IRPtrOffset(dest, base, offset_bytes, elem_width)` lowers to
`Define(dest, base, :add, offset_bytes ÷ (elem_width ÷ 8))`
(`BennettVM/src/ir/ingest_body.jl:534`). So **`elem_width` is nothing but the
bytes→cells scale factor**, and an object's cell map is fixed by two numbers:
the scale its addresses use, and the number of cells its allocation reserved.

Both numbers are already determined, per allocation shape, by code that ships
today:

| root shape | `scale` (bytes/cell) | `cap` (cells) | authority (verified) |
|---|---|---|---|
| `IRAlloca(d, ew, n)` | `ew ÷ 8` | `n` | `_lower_alloca!` reserves `n` cells and states "`elem_width` (in bits) does **NOT** enter the address" — `BennettVM/src/ir/ingest_body.jl:581-586` |
| `julia.gc_alloc_obj(_, nb, _)` | **1** | `nb` | `_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nb)` — `BennettVM/src/ir/intrinsics.jl:256-257` |
| GenericMemory alloc | **1** | `16 + nb` | `_alloc_cells(::IntrinsicGenericMemoryAlloc)` — `intrinsics.jl:259-261` |
| `malloc` / `calloc` / `realloc` | **8** | `nb ÷ 8` | `_alloc_cells(::IntrinsicMalloc) = _cell_count(nb)` — `intrinsics.jl:246` |
| pointer param, global, `phi`/`select` ptr, `julia.gc_loaded` | **UNKNOWN** | — | no reservation exists *in this function* |

> **(SC) — the scale-coherence invariant.** For every pointer root `R` whose
> scale is known, every `IRPtrOffset` derived from `R` must carry
> `elem_width == 8 · scale(R)`, and its **total** byte offset divided by
> `scale(R)` must be `< cap(R)`.

(SC) is a single sentence that subsumes the whole granularity discipline: wall
8, the CW-D4 class-D split, `Bennett-z2ia`, `Bennett-4y0d`, and the
`bennettvm-jb6w` clang-spill hazard are **all** instances of it. It is also
*mechanically checkable*, which §4 exploits.

### 1.2 The coherence table — MEASURED, not derived

`run4.jl` extracts a distilled fixture carrying every access class the scout's
§2 census found on `%"new::Array"` — the byte field-init store, the whole-
aggregate store, both two-index struct GEPs, the `+16` byte access — on **one**
`julia.gc_alloc_obj(_, i64 24, _)` object, plus the 416r.13 singleton header GEP
(whose base is a **global**, so it has no `gc_alloc` root). Emitted IR, verbatim:

| class | LLVM shape | emitted node | cell | agrees? |
|---|---|---|---|---|
| A — byte field-init | `gep i8 %obj, 8` | `IRPtrOffset(:b8, obj, 8, 8)` | **+8** | ✅ |
| E — aggregate store, field 0 | `store {ptr,ptr} … , ptr %obj` | `IRPtrOffset(:__v6, obj, 0, 8)` | **+0** | ✅ |
| E — aggregate store, field 1 | *(same store)* | `IRPtrOffset(:__v8, obj, 8, 8)` | **+8** | ✅ |
| D — two-index struct GEP `0,0` | `gep {ptr,ptr} %obj, i32 0, i32 0` | `IRPtrOffset(:w0, obj, 0, 8)` | **+0** | ✅ |
| D — two-index struct GEP `0,1` | `gep {ptr,ptr} %obj, i32 0, i32 1` | `IRPtrOffset(:w1, obj, 8, 8)` | **+8** | ✅ |
| B — `+16` byte access | `gep i8 %obj, 16` | `IRPtrOffset(:b16, obj, 16, 8)` | **+16** | ✅ |
| 416r.13 singleton header | `gep {i64,ptr} @jl_global#93, 0, 1` | `IRPtrOffset(:hdr, g93, 8, 8)` | **+8** | ✅ (type fallback) |

```
--- DISTILLED CORPUS OBJECT under proposer-B patch : 0 scale-violation(s), 0 out-of-reservation
```

Field 1 is **written** at cell +8 by class E and **read** at cell +8 by *both*
class A and class D. Max cell touched is 16, inside the 24-cell reservation.
Compare HEAD, where the same fixture yields `IRPtrOffset(:w1, obj, 8, **64**)`
→ cell **+1** (probe `b04`, re-executed and reproduced verbatim; §3.1).

The 416r.13 row is the load-bearing one for the scout's §4 constraint: its base
is a global, so provenance is **unknown**, and the byte stamp survives only
because the rule is a **union** — provenance where known, the existing
`_is_genericmemory_header_struct` type predicate where not.

### 1.3 Why β is rejected

β ("make the reservation match the addressing") comes in two forms and both fail:

* **Gated β** — byte-reserve only *Julia-tier* allocas. This still needs a
  per-root tier classifier to know which allocas are Julia-tier, **and** still
  needs the D4 arm re-stamped (a `gc_alloc`'d `{ptr,ptr}` GEP must be 8 while a
  `malloc`'d `%struct.T` GEP must be 64). So gated β **is α′ plus an extra
  emission change to `IRAlloca`** — strictly larger, with strictly more
  byte-identity risk, for zero extra coverage.
* **Universal β** — one byte convention for the whole program. This requires
  changing BVM's `_alloc_cells(::IntrinsicMalloc)`, breaks every C-tier pin
  (`test_haiy` / `test_nd45` assert `elem_width == 64`), multiplies every
  program's cell footprint by 8, and would need its own 3+1. Out of scope by a
  wide margin.

α′ keeps the C tier byte-identical **by construction**: for `malloc` the scale
is 8, so `8·scale = 64` — precisely the stamp those arms already emit. Measured
in §3.2: `test_haiy`, `test_nd45`, `test_vz5n`, `test_9n3y` all stay green.

### 1.4 Fail-loud-first is adopted as commit 1

The arc splits cleanly into two commits, and the first is exactly the scout's
"fail-loud-only" option:

* **Commit 1 — the (SC) guard.** Detect and refuse scale disagreement. Clears no
  wall; converts `Bennett-z2ia` and the class-D split from silent miscompiles
  into loud rejects. Independently valuable, independently reviewable.
* **Commit 2 — byte-stamped admission.** Re-stamp D4, admit the byte tier in
  p06b, advance the corpus to wall 9.

Commit 1 first is not ceremony: it is what makes commit 2's soundness argument
*checkable* rather than asserted, and it is the only ordering in which the
z2ia-class fixture defect in `test_qmv7` (§3.3 — a genuine find) surfaces before
anything depends on it.

---

## 2. Mechanism

### 2.1 The shared predicate

One new helper, sited beside `_alloca_reservation` (`instructions.jl:~342`) and
following its "shared, never mirrored" discipline verbatim:

```julia
_root_scale(v, names, ptr_cells, depth=0) -> Union{Nothing, Tuple{Int,Int}}
```

Walks the const-GEP producer chain to a root (depth-8 bound, `gep_ops[1]` base
step — **the exact recursion `_gc_alloc_root_ref` / `_param_ptr_root_ref` /
`_alloca_root_ref` already use**, so it introduces no new walker shape), then
returns `(scale_bytes, cap_cells)` from the §1.1 table, or `nothing`. It calls
`_alloca_reservation` for the alloca case rather than re-deriving it — the N1
drift lesson.

### 2.2 Per-arm disposition

| arm | file:line (HEAD) | change |
|---|---|---|
| **D4 two-index struct GEP** | `instructions.jl:4977` | `ew_gep = rs === nothing ? (_is_genericmemory_header_struct(src_type_gep) ? 8 : 64) : 8 * rs[1]` — the **union**: provenance wins where known, the type predicate fills in where the root is a global/param (the 416r.13 case) |
| **single-index const GEP** | `instructions.jl:4817` | **(SC) guard only**, no restamp. `ptr_cells`-**GATED** (§3.3). Refuses `gep i8` off a word-tier root → closes `Bennett-z2ia` |
| **p06b (P4b)** | `instructions.jl:406` | `_p06b_cell_ptr_target_kind` gains a `:gcalloc` branch returning `(:gcalloc, nbytes)` — **byte** cells |
| **p06b (P4c)** | `instructions.jl:5670` | already correct: for the corpus object `cap = 24 ≥ 2` fields. The byte-tier arm the scout suggested (`cap ≥ o_{N-1} + 8`) is a strict strengthening and should land |
| **p06b (P5)** | `instructions.jl:5684` | see §2.3 |
| **p06b emission** | `instructions.jl:5749` | `IRPtrOffset(aname, base_p06b, offs_p06b[k+1], 8 * scale)` — one 64-bit store per field, **not** eight byte stores (BVM's `MemoryStore` carries no width, `memory_floor.jl:156-168`) |
| **vbv9 global-src memcpy** | `instructions.jl:2206` | `dst_ew` from `_root_scale(dst)` — closes `Bennett-4y0d` (K≥2) |
| **p06b (P1)** | `instructions.jl:5563` | **UNTOUCHED.** Re-verified: the corpus store's value type is literal `{ptr,ptr}`, so `_is_genericmemory_header_struct` is `false` and (P1) never fires on it |

### 2.3 (P5) disposition — retained, not inverted

The scout proposes inverting (P5)'s accept/reject sets per tier. I propose
something sharper, and it falls out of (SC):

* For a **scale-KNOWN** root, (SC) already enforces agreement *globally* — over
  every use in the function, including ones (P5)'s alias closure cannot see
  (`_p06b_alias_group` links only same-slot re-loads; the residual-risks block
  at `instructions.jl:252-259` lists what it misses). So for known roots (P5) is
  **subsumed**: skip it and let (SC) carry the obligation. Strictly stronger.
* For a **scale-UNKNOWN** root, (SC) says nothing, and (P5) is the **only**
  guard — so it is **retained verbatim**, word-granular semantics and all.

This is not a corner case. **Both regimes are live in the corpus**: wall 8's
ROOT-body target is `gc_alloc`-rooted (scale known → (SC)); `_growend!`'s own
store target is `%1 = load ptr, ptr %0` off a `dereferenceable(0)` argument
(`tcells == -1`, scale unknown → (P5)). Keeping both is required, and it means
the whole (D2)/(D7)/(N2)/(D3) surface stays green unchanged — measured, §3.2.

`_p06b_slot_key` needs **no** change: it already folds every spelling to a byte
offset and never consults `elem_width`. The scout is right about this.

### 2.4 z2ia disposition — CLOSED by the guard, not by a reservation change

`Bennett-z2ia` needs no `IRAlloca` change. Under (SC), `gep i8 %env, 56` off
`alloca [9 x i64]` (scale 8, cap 9) is a disagreement, and the message can quote
both cell numbers because both are computable:

```
constant-index getelementptr stamps elem_width=8 but its allocation ROOT
reserves cells of 8 byte(s) (scale mismatch: BennettVM would address cell
base+56 where the reservation means cell base+7). (…/Bennett-z2ia)
```

Measured verbatim from the probe. This is a **refusal**, not a fix: the program
still cannot compile. But it converts the scout's §7.1 finding — a *silent
adjacent-allocation clobber that `bennettvm-pdqx` does not catch* — into a
crash, which is CLAUDE.md Rule 1's requirement. Making such programs *work*
(byte-reserving Julia-tier allocas) stays filed under `Bennett-z2ia`.

### 2.5 BVM src changes — NONE. Verified by E2E, not assumed.

`e2e_bvm.jl` builds a `gc_alloc_obj(_, 24, _)` box, stores a two-field aggregate
through the decomposition, and reads field 1 back through **both** the class-A
byte GEP and the class-D struct GEP, then reverses:

```
class-A byte read   rA = 777    (oracle: y = 777)
class-D struct read rD = 777    (oracle: y = 777)
field-0 read        rE = 4242   (oracle: x = 4242)
AGREE = true
step_count=0
unrun! -> pc=true memory=true frames=true arena_top=true
REVERSIBLE = true
```

Run against BennettVM `d44f1c3` **unmodified**. The reason there is nothing to
change: `IRPtrOffset(_, _, o, 8)` lowers to `Define(dest, base, :add, o ÷ 1)`,
whose divisibility guard is trivially satisfied, and `_alloc_cells` already
byte-reserves the gc_alloc tier. The byte tier was always BVM's model; only
Bennett's stamps disagreed with it.

---

## 3. Failure modes and message territory

### 3.1 The wall advances — measured

`run2.jl`, patched extractor on the untouched corpus `root.ll`:

```
ir_extract.jl: call in @julia__pushbvmd_91:%top:
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Array.size", …)
— memcpy src operand is not alloca-backed … (Bennett-37mt Phase 1)
```

Wall 8 → **wall 9**, exactly the scout's `b05_seq` prediction. `run3.jl`
confirms wall 10 (the `Bennett-583s` ptrtoint escape) sits behind all four
memcpys, unchanged by their removal.

### 3.2 Blast radius — 17 files, measured under the patch

Green, unchanged (the **C-tier byte-identity obligation, discharged**):

| file | result |
|---|---|
| `test_9n3y_memheader_gep.jl` | 8/8 ✅ |
| `test_vz5n_gep_offset_bytes.jl` | 16/16 ✅ |
| `test_haiy_ptr_cells_store_load_gep.jl` | 26/26 ✅ |
| `test_nd45_ptr_cells_call_emission_multifn.jl` | 39/39 ✅ |
| `test_vbv9_arena_memcpy.jl` | 18/18 ✅ |
| `test_37mt_memcpy_const_aligned.jl` | 86/86 ✅ |
| `test_u2kk_param_memcpy.jl` | 14/14 ✅ |
| `test_ixiz_wider_alloca.jl` | 53/53 ✅ |
| `test_munq_arr_i8_alloca.jl` | 69/69 ✅ |
| `test_583s_memdata_bounds.jl` | 28/28 ✅ |
| `test_6bu3_struct_aggregate.jl` | 161/161 ✅ |
| `test_lgzx_store_fail_loud.jl` | 4/4 ✅ |
| `test_zf5v_gc_preserve.jl` | 16/16 ✅ |
| `test_416r16_consumed_sret_reconcile.jl` | 40/40 ✅ |
| `test_8bys_variable_memset.jl` | 28/28 ✅ |
| `test_9nwt_memset_const.jl` | 87/87 ✅ |
| `test_cb9y_multi_origin_runtime_idx.jl` | 77/77 ✅ |
| `test_lower_store_alloca.jl` | 41/41 ✅ |
| `test_store_alloca_extract.jl` | 279/279 ✅ |

`test_vz5n` deserves a note: its `elem_width = source element bit width`
contract (`Bennett-xv0u`) is stated on GEPs off **function parameters** — roots
with no reservation. Under (SC) those are scale-unknown, so the contract is
untouched. `alloca i32, i32 8` + `gep i32 … 3` is *also* coherent (scale 4,
stamp 32) and stays green: (SC) is not a byte-vs-word binary, it is per-root
agreement, which is why the typed-array tier survives it.

**Intentional inversions — 10 assertions, 5 files.** Every one is the
`gc_alloc_obj || BYTE-granular` wall marker or the p06b gc_alloc reject:

| file | testset | count |
|---|---|---|
| `test_p06b_aggregate_store.jl` | (N3) ×4, (h) ×1, (k) ×1 | 6 |
| `test_foz5_confined_bounds.jl` | (W8) | 1 |
| `test_40ys_instanceless_callees.jl` | (I) | 1 |
| `test_7wsz_ptr_sret_fields.jl` | (J) | 1 |
| `test_vau9_variable_memmove.jl` | (g) | 1 |

`test_p06b` scores **620 pass / 6 fail of 626** — the (D2)/(D7)/(D3)/(N2)/(g2b)/
(g3)/(g5)/(D4)/(c2)/(i) surface is entirely untouched, which is the measured
confirmation of §2.3's "retain (P5) for unknown roots".

### 3.3 The finding that changes the arc: `test_qmv7` contains a live z2ia

`test_qmv7_gc_loaded_memcpy.jl`'s fixtures (`GCL_I8`, `GCL_I64`) contain:

```llvm
%fld = alloca [2 x i64], align 8
%sp  = getelementptr inbounds i8, ptr %fld, i32 8
```

A **word-tier** 2-cell reservation addressed at byte offset 8 → cell `fld+8`,
six cells past its own reservation. The intent is plainly "second word" = cell
`fld+1`. This is `Bennett-z2ia` **already committed in a green test fixture**,
not merely in the corpus root. The (SC) guard finds it (gates (a), (c), (e) —
4 assertions), and closing z2ia therefore costs a **fixture re-authoring** in
that one file (`gep i64, ptr %fld, i32 1`, which is coherent). This is a real
scope item the bead does not contain, and the reviewer should decide it
explicitly rather than discover it.

**The same measurement produced a hard design constraint.** Ungated, the (SC)
guard also fired on the **circuit** path: `test_qmv7` gate (b) and `test_40ys`
(H2) ×3 both compile with `ptr_cells=false`, where `elem_width` is inert (the
circuit backend ignores the field — `test_vz5n`'s own comment says so). Gating
the guard on `ptr_cells` restored all four (`test_40ys`: 99/103 with only the
intended (I) inversion left). **The (SC) guard MUST be `ptr_cells`-gated**;
this was measured, not reasoned.

### 3.4 Marker plan — one correction to the scout

Positives for the new wall 9, non-numeral anchors, disjoined
(`Bennett-0ncn`): `occursin("memcpy", msg) || occursin("Bennett-37mt", msg)`.

Negatives — full census taken on the patched corpus wall-9 message:

| marker | at wall 9 | disposition |
|---|---|---|
| `gc_alloc_obj`, `BYTE-granular`, `Bennett-p06b` | **false** | become the **inverted** negatives: after bvmd, a p06b reject naming `gc_alloc_obj` is a REGRESSION |
| `Bennett-583s`, `base-cancelling` | **false** | **KEEP as blanket negatives** |
| `Bennett-jbko`, `Bennett-iwo9`, `Bennett-lgzx`, `memmove` | **false** | keep — walls 3/5/6 stay cleared |
| `memcpy`, `Bennett-37mt`, `Bennett-8bys` | **true** | the new positive |
| `udiv`, `_growend!` | **false** | — |

**Correction to the scout §10.** The scout instructs that
`!occursin("Bennett-583s")` "**must be DROPPED** as a blanket negative, because
wall 10 IS a 583s reject". Measured: at bvmd the next wall is **9**, not 10, and
its message contains neither `Bennett-583s` nor `base-cancelling`. The blanket
negative is **still true and still load-bearing** (it is what proves wall 7 stays
cleared), and pre-emptively weakening it buys nothing while giving up real
signal. The trap is real but it fires **one bead later**, at the wall-9 arc.
Correct action: **keep** the blanket negative here, and leave a comment naming
the trap for whoever clears wall 9.

Prose-vs-predicate: every new message cites its enforcing predicate by name
(`_root_scale`), and the (SC) guard's message asserts only the two cell numbers
it actually computes — no capacity or provenance guarantee is claimed beyond
what the walk proves.

---

## 4. Test plan

**Unit — the (SC) contract (new `test/test_bvmd_root_scale.jl`).** Distilled
`.ll` fixtures, extraction-shape assertions, not message greps:

1. **Byte-tier emission** — the §1.2 fixture; assert *exactly*
   `IRPtrOffset(_, obj, o_k, 8)` for every class, i.e. the full coherence table
   as a pinned `Set` of `(offset_bytes, elem_width)`.
2. **Negative control (C tier)** — the same store shape into a `malloc(24)`
   target still emits `elem_width == 64` on every node.
3. **Union control (416r.13)** — a header GEP whose base is
   `load ptr, ptr @"jl_global#N"` still stamps 8, proving the type predicate is
   a union member and not dead code.
4. **Typed-array control** — `alloca i32, i32 8` + `gep i32 … 3` stays
   `(12, 32)`; (SC) is per-root agreement, not a byte/word binary.
5. **z2ia refusal** — `alloca [9 x i64]` + `gep i8 … 56` fails loud with both
   cell numbers; and the **`ptr_cells=false` control** that the same fixture is
   byte-identically unaffected (§3.3 — this control is load-bearing).
6. **4y0d** — a K=2 global-src memcpy into a `gc_alloc` dst emits
   `IRPtrOffset(_, d, 8, 8)`, not `(8, 64)`; K=1 pins in
   `test_vbv9_arena_memcpy.jl:150-161` extended, not broken.

**Corpus gate.** `extract_parsed_ir_set_from_julia(_pushbvmd, Tuple{Int64};
ptr_cells=true)` still walls, at wall 9, with the §3.4 marker table asserted in
full — positives *and* every negative, including the two the scout would have
dropped.

**Synthetic §4a-debt E2E (BVM side).** The scout's design, built and already
passing in `e2e_bvm.jl` for legs (1)(2)(3)(6a)(6b): gc_alloc box + decomposed
store + class-A *and* class-D reads of the same field + oracle match + exact
`unrun!` restoration of `pc`/`memory`/`frames`/`arena_top`. Legs still to add:
(4) a closure-env alloca written by extracted code and read back — **note this
must use a scale-coherent GEP**, since (SC) now refuses the incoherent spelling
the corpus actually emits; and (5) a `ptrtoint`/`sub`/`icmp`/`br` confined guard
with (6c) an OOB input halting at `:__unreachable__`.

**Honest status, to go in the commit message verbatim.** Clearing wall 8 does
**not** make the `push!` corpus runnable — walls 9, 10 and 11 still block
extraction and `bennettvm-rxgy` still blocks `_growend!` at `lower_vm`. The
fixture discharges the foz5 §4a debt *for the mechanism*, on a program with that
mechanism. It does **not** discharge it for the corpus, and the OOB probe (leg
6c) is constructible only in the fixture — `push!` on a fresh `Vector` never
takes the `oob` edge. The bead's "lets the full push! corpus RUN" premise is
false and must not be repeated.

**Marker advances to re-author deliberately** (not "fix"): `test_p06b` (N3)(h)(k)
— (N3) also pins the string `9n3y`, a **dangling ID in both trackers**; retire
it in favour of `Bennett-zdd6`. `test_foz5` (W8), `test_40ys` (I), `test_7wsz`
(J), `test_vau9` (g) — all the same two-part advanced-wall marker.
`test_qmv7` gates (a)(c)(e) — fixture re-authoring per §3.3.

---

## 5. Risks

| # | risk | severity | mitigation | evidence |
|---|---|---|---|---|
| R1 | (SC) guard fires on green circuit-path programs | **HIGH — OCCURRED** | `ptr_cells`-gate the guard | measured: `test_qmv7` (b), `test_40ys` (H2)×3 went green on gating |
| R2 | z2ia refusal breaks committed fixtures | **MEDIUM — OCCURRED** | re-author `test_qmv7`'s two `.ll` fixtures; scope decision for the reviewer | §3.3, 4 assertions |
| R3 | provenance rule demotes the 416r.13 singleton headers to word granularity (silent miscompile) | HIGH | the rule is a **union**, never a replacement; pinned by test 3 | `test_9n3y` 8/8 green; §1.2 last row |
| R4 | C tier drifts off byte-identity | HIGH | scale 8 ⇒ `8·scale = 64`, the stamp those arms already emit | `test_haiy`/`test_nd45`/`test_vz5n` green |
| R5 | root walk misses a use ⇒ (SC) passes vacuously | MEDIUM | depth-8 const-GEP only, same bound as the three shipped walkers; `phi`/`select`/memory round-trips yield `nothing` and fall back to (P5). **Stated, not closed** — same residual class as `_p06b_alias_group` | `instructions.jl:252-259` |
| R6 | a callee receives a byte-tier cell and word-addresses it | MEDIUM | out of model; the closed-world guard owns it, as it already does for `bennettvm-jb6w` | inherited, not created |
| R7 | `_p06b_call_bytes` returns -1 for a non-constant `gc_alloc` size | LOW | `cap = 0` ⇒ (P4c) refuses; the corpus size is the constant `i64 24` | `root.ll:112-113` |
| R8 | six other `IRPtrOffset` construction sites (`heap.jl` ×2, `vectors.jl`, `instructions.jl:1690/1691/2524`) are unaudited | MEDIUM | out of scope for the stamp change, but **in scope for the guard** — (SC) is enforced downstream of all of them, so they are covered without being touched | 9 sites enumerated |

**R8 is the architectural payoff and deserves emphasis.** Because (SC) is a
property of the *emitted* `IRPtrOffset` stream, a single check covers all nine
construction sites — including ones no one has audited — without a nine-site
patch. That is why the guard, not the restamp, is the load-bearing half of this
proposal.

**Biggest risk: R2/R3 as a pair.** The provenance rule must strengthen the byte
stamp without ever weakening it, and the only proof of that is the 416r.13 union
control plus the C-tier pins — all green, but all *fixture* evidence. The corpus
has exactly one shape (the singleton header) exercising the union arm.

---

## 6. Diff shape (touch points only)

**`src/extract/instructions.jl`** — one new helper + six one-to-few-line sites:

| site | line (HEAD `e8b21a4`) | change |
|---|---|---|
| new `_root_scale` | ~342, beside `_alloca_reservation` | ~28 LOC, mirrors `_gc_alloc_root_ref`'s recursion |
| `_p06b_cell_ptr_target_kind` | 406 | `:gcalloc` branch |
| `_p06b_target_kind_name` | 448-455 | the `gc_alloc_obj` reject text becomes unreachable — retire it, keep the shape for non-constant sizes |
| single-index GEP | 4817 | (SC) guard, `ptr_cells`-gated |
| D4 struct GEP | 4977 | union stamp |
| vbv9 memcpy dst | 2206 | `dst_ew` from `_root_scale` |
| p06b (P5) | 5684 | skip for scale-known roots; retain verbatim otherwise |
| p06b emission | 5749 | `8 * scale` |
| p06b (P4c) | 5670 | byte-tier capacity arm (strengthening) |
| p06b residual-risks block | 274-277 | the "`gc_alloc_obj` targets are REFUSED" bullet inverts |

**`test/`** — 1 new file (`test_bvmd_root_scale.jl`), 6 edited
(`test_p06b_aggregate_store.jl`, `test_foz5_confined_bounds.jl`,
`test_40ys_instanceless_callees.jl`, `test_7wsz_ptr_sret_fields.jl`,
`test_vau9_variable_memmove.jl`, `test_qmv7_gc_loaded_memcpy.jl`), 1 extended
(`test_vbv9_arena_memcpy.jl`), plus `test/runtests.jl` registration.

**`BennettVM.jl/src/`** — **nothing.** Verified E2E (§2.5), not assumed.

**Beads** — close `Bennett-bvmd`; close or re-scope `Bennett-z2ia` (guard lands,
byte-reservation does not); close `Bennett-4y0d`; retire the dangling
`bennettvm-9n3y` string in favour of `Bennett-zdd6`; the `bennettvm-jb6w`
clang-spill hazard is **closed by the union rule** where the spill has a known
root, and should be re-scoped rather than left open.

**Commit split:** (1) `_root_scale` + (SC) guard + `test_qmv7` fixture
re-authoring + z2ia/4y0d pins — no wall moves. (2) D4 union stamp + p06b
byte-tier admission + emission + marker advances + the BVM E2E — wall 8 → 9.
