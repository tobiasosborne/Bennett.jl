# Bennett-bvmd — DESIGN-VERIFYING SCOUT report

**Bead:** `Bennett-bvmd` (P1) — "xkl frontier wall 8: ROOT body walls at p06b's
`gc_alloc_obj` byte-granular aggregate-store refusal (CW-D4) — byte-stamped
admission needed"
**HEAD at time of scouting:** `e8b21a4` (Bennett-foz5, landed 2026-08-06)
**Sister repo HEAD:** BennettVM.jl `d44f1c3`
**Scope:** verification pass only. **No `src/` or `test/` change was made; no commit.**
**Probes** (all under the session scratchpad
`/tmp/claude-1000/-home-tobiasosborne-Projects-Bennett-jl/4d67df94-…/scratchpad/`):
`b01_wall.jl`, `b02_dump.jl` (→ `root.ll`), `b03_nostore.jl`, `b04_stamps.jl`,
`b05_seq.jl`, `b06_p5.jl`, `b07_uses.jl`, `b08_dead_and_singleton.jl`,
`b09_alloca.jl`, `b10_vbv9k2.jl`.
All runs under `julia --project --check-bounds=yes` (suite mode, per CLAUDE.md §Build).

---

## VERDICT UP FRONT

**UPGRADE to a full 3+1 (CLAUDE.md §2).** All three of the tripwire's named
triggers are *not* what fires — the contested part is worse and is measured
below:

1. The bead's named mechanism ("emit `IRPtrOffset(_,_,8k,8)` per field") is
   **necessary but provably insufficient**. A (P4b)-only widening does not clear
   wall 8: **(P5) fires next, on the real corpus use-shape** (probe `b06_p5.jl`,
   executed). See §5.
2. Making (P5) pass requires **byte-stamping the D4 two-index struct-GEP arm**
   for the same object — a change to the shared Julia/C granularity
   discriminator (`_is_genericmemory_header_struct`), i.e. the fix named in
   **Bennett-zdd6** (the real filing of the dangling "jb6w"). That is a *second*
   core change with C-tier blast radius. See §4, §6.
3. Even with 1+2, the ROOT body contains a **third, larger and independent**
   granularity defect: `alloca [9 x i64]` reserves 9 **word** cells while Julia
   codegen addresses it with `gep i8 …, 56` → cell +56 (probe `b09_alloca.jl`,
   executed). The whole Julia tier is byte-addressed; only its *allocations* are
   word-reserved. See §7. A per-target patch cannot reach this.

So the soundness argument for "byte-stamped admission" **cannot be made rigorous
as a local widening of (P4b)**; it is a *tier-granularity decision* spanning
`instructions.jl`'s GEP arm, the alloca arm, the p06b store arm, the vbv9 memcpy
arm, and BVM's `_alloc_cells`. The design space is genuinely contested (at least
two coherent answers exist — §8). **Two blind proposers are warranted.**

Everything below is delivered so the 3+1 starts from measured ground.

---

## 1. Wall 8 at HEAD, reproduced (probe `b01_wall.jl`)

Gated path, the harness `test_foz5` (W8) / `test_p06b` (k) use:

```julia
_pushbvmd(n::Int64) = begin
    v = Int64[]; push!(v, n); @inbounds v[1]
end
Bennett.extract_parsed_ir_set_from_julia(_pushbvmd, Tuple{Int64}; ptr_cells=true)
```

Verbatim wall:

```
julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
`_pushbvmd#1fc14563` (callable=_pushbvmd, argtypes=Tuple{Int64}) —
ir_extract.jl: store in @julia__pushbvmd_31252:%top:
  store { ptr, ptr } %memory_ref, ptr %"new::Array", align 8
— aggregate store target is not a CERTIFIED cell pointer — it is a
`julia.gc_alloc_obj` call — the JULIA heap tier, which BennettVM stamps
BYTE-granular (`_byte_cells`, `src/ir/intrinsics.jl:256-257`, CW-D4 /
bennettvm-9n3y). … (Bennett-p06b, predicate `_p06b_cell_ptr_target_kind`)
```

**Marker verification** (probe `b01`, exact `occursin` results):

| marker | fires | role |
|---|---|---|
| `gc_alloc_obj` | **true** | positive (foz5 W8, p06b k, 40ys, 7wsz) |
| `BYTE-granular` | **true** | positive |
| `Bennett-p06b` | **true** | discriminator (p06b k, 7wsz) |
| `GenericMemory` | true | incidental (the (P1) cross-reference in the message) |
| `Bennett-583s` | false | LOAD-BEARING NEGATIVE — wall 7 cleared |
| `base-cancelling` | false | LOAD-BEARING NEGATIVE — wall 7 cleared |
| `Bennett-jbko` | false | LOAD-BEARING NEGATIVE — wall 5 not poached |
| `Bennett-iwo9` | false | LOAD-BEARING NEGATIVE |
| `Bennett-lgzx` | false | LOAD-BEARING NEGATIVE — wall 6 cleared |
| `memcpy` / `Bennett-37mt` | false | (becomes the wall-9 positive, §8) |

The bead text is **accurate** on the wall's identity (unlike foz5's, which was
materially wrong). The one correction: the walled instruction is in the **ROOT**
body `@julia__pushbvmd_*`, block `%top` — not in any callee — so the whole
`_growend!` closure now extracts and *nothing in the set is reached at all*
past this instruction.

### 1.1 Verbatim store provenance (probes `b02_dump.jl` → `root.ll`, `b07_uses.jl`)

`_module_has_sret(mod) == false` for the root, so **no `sroa`/`mem2reg` runs**
(entry.jl:104-108 does not trigger) — the root is walked at raw `optimize=false`.
(Contrast `_growend!`, where sret *does* trigger the prepend. Do not assume the
foz5 pass pipeline here.)

```llvm
top:
  %"jl_global#93"   = load ptr, ptr @"jl_global#93", align 8      ; 416r.13 singleton
  %memory_data_ptr  = getelementptr inbounds { i64, ptr }, ptr %"jl_global#93", i32 0, i32 1
  %memory_data      = load ptr, ptr %memory_data_ptr, align 8
  %3                = insertvalue { ptr, ptr } zeroinitializer, ptr %memory_data, 0
  %memory_ref       = insertvalue { ptr, ptr } %3, ptr %"jl_global#93", 1   ; <- VALUE
  %"+Core.Array#94" = load ptr, ptr @"+Core.Array#94", align 8
  %Array            = ptrtoint ptr %"+Core.Array#94" to i64        ; iwo9 typetag
  %4                = inttoptr i64 %Array to ptr
  %current_task     = getelementptr inbounds i8, ptr %pgcstack, i32 -152
  %"new::Array"     = call noalias nonnull align 8 dereferenceable(24)
                        ptr @julia.gc_alloc_obj(ptr %current_task, i64 24, ptr %4)
  %5                = getelementptr inbounds i8, ptr %"new::Array", i32 8
  store ptr null, ptr %5, align 8
  store { ptr, ptr } %memory_ref, ptr %"new::Array", align 8       ; <-- WALL 8
```

* **aggregate type** — literal `{ ptr, ptr }` (a `GenericMemoryRef`:
  `.ptr_or_offset`, `.mem`). **NOT** the `{ i64, ptr }` GenericMemory *header*.
* **value provenance** — a 2-link `insertvalue` chain rooted at
  `zeroinitializer`. (P6)/(P6′) are **satisfied**; they are not the blocker.
* **target provenance** — `%"new::Array"`, the result of
  `julia.gc_alloc_obj(current_task, **i64 24**, +Core.Array)`, i.e. the 24-byte
  boxed `Array` header `{ ref.ptr_or_offset@0, ref.mem@8, size@16 }`.
* (P1)/(P2)/(P3)/(P4a)/(P4c) all pass; (P4b) is the reject. (P5) is **never
  reached today** because (P4b) precedes it (instructions.jl:5627 vs :5684).

`b08` confirms **`oob`, `oob15`, `oob31`, `oob40`, `L40`, `after_noret` are
utzc-pruned dead blocks**, so the two *other* `store {ptr,ptr}` into
`gc_alloc_obj(…, 16, …)` GenericMemoryRef boxes never reach the converter.
**The wall-8 store is the only live gc_alloc_obj aggregate store in the corpus.**

---

## 2. Complete access-class census of `%"new::Array"` (probe `b07_uses.jl`)

BVM reserves `_alloc_cells(IntrinsicGCAlloc) = _byte_cells(24) = **24 cells**`
(`BennettVM/src/ir/intrinsics.jl:256-261`), i.e. one cell per *byte address*,
with a 64-bit value living in exactly **one** cell at its base byte address
(cells +1…+7 are simply never named — the convention already shipped by 416r.13,
9n3y and vbv9). Every use of the object, and where it lands:

| # | class | LLVM shape | sites | emitted node (**measured**, `b04`) | byte-tier cell | agrees? |
|---|---|---|---|---|---|---|
| A | byte field-init store | `gep i8 %obj, 8` → `store ptr null` | 1 (`%top`) | `IRPtrOffset(_,obj,8,8)` | +8 | ✅ |
| B | global-src memcpy **dst** | `gep i8 %obj, 16` → memcpy ← `@"_j_const#1"`, N=8 | 1 (`%top`) | `IRPtrOffset(_,obj,16,8)` + vbv9 `IRPtrOffset(_,·,0,64)` | +16 | ✅ (K=1 only — see §7.3) |
| C | arena-src memcpy **src** | `gep i8 %obj, 16` → memcpy → alloca, N=8 | 3 (`%top`,`L21`,`L31`) | **WALLS** (37mt Phase 1) | (+16) | n/a yet |
| C′ | alloca-src memcpy **dst** | `gep i8 %obj, 16` → memcpy ← `%"new::Tuple"` | 1 (`L18`) | not reached | (+16) | n/a yet |
| D | **two-index struct field load** | `gep {ptr,ptr} %obj, i32 0, i32 k`, k∈{0,1} | **6** (2 each in `%top`,`L21`,`L43`) | `IRPtrOffset(_,obj,offsetof,**64**)` | **+0 / +1** | ❌ **SPLIT** |
| E | whole-aggregate store | `store {ptr,ptr} %memory_ref, ptr %obj` | 1 (`%top`) | **WALL 8** | wants +0/+8 | — |
| F | cell-opaque | `store ptr %obj, ptr %30` (roots array); `j_throw_boundserror_97(%obj, …)` | 2 | pointer value only | n/a | ✅ |

**Class D is the crux and it is not in the bead text.** Measured stamps (probe
`b04_stamps.jl`, a fixture reproducing exactly the corpus shapes):

```
Bennett.IRPtrOffset(:b8, SSAOperand(:obj),  8,  8)   # gep i8 %obj, 8      -> cell obj+8
Bennett.IRPtrOffset(:w1, SSAOperand(:obj),  8, 64)   # gep {ptr,ptr} 0,1   -> cell obj+1
Bennett.IRPtrOffset(:w0, SSAOperand(:obj),  0, 64)   # gep {ptr,ptr} 0,0   -> cell obj+0
Bennett.IRPtrOffset(:b16, SSAOperand(:obj),16,  8)   # gep i8 %obj, 16     -> cell obj+16
```

Byte offset 8 of one object maps to **cell +8** (class A) *and* **cell +1**
(class D). **The CW-D4 split is already live in the ROOT body today,
independently of the aggregate store.** It is latent only because extraction
walls before it can run.

---

## 3. The exact emission the bead asks for — and why it is only step 1

**Byte-stamped decomposition (the (P4b)+emission half).** For an unpacked
StructType `S` with field byte offsets `o₀…o_{N−1}` (`LLVM.offsetof`, never
`index*width`) stored into a **byte-tier** target `p`:

```
IRExtractValue(fk, <agg>, k, 0, N, field_widths)          # unchanged (6bu3 shape)
IRPtrOffset(ak, ssa(p), o_k, 8)                           # ew 8, NOT 64
IRStore(ssa(ak), ssa(fk), 64)                             # unchanged
```

i.e. exactly `ew = byte_tier(p) ? 8 : 64` on the `IRPtrOffset` only. **One
64-bit store per field, not eight single-byte stores.** Grounds:

* BVM `MemoryStore(ptr, value)` (`src/ir/memory_floor.jl:156-168`) carries **no
  width** — it writes one whole `Int64` cell. There is no sub-cell store, so
  8 single-byte stores are not expressible; and they would be *wrong*, because
  every other byte-tier reader (`store ptr null` at +8; the vbv9 memcpy at +16;
  the 416r.13 singleton `length@+0`/`data@+8`) reads the **whole 64-bit value
  from the single cell at the field's base byte address**.
* `IRPtrOffset(_,_,o_k,8)` → `Define(dest, base, :add, o_k÷1)`
  (`BennettVM/src/ir/ingest_body.jl:505-534`); divisibility guard trivially
  satisfied for `ew_bytes == 1`. **Zero BVM src changes for this half.**
* Capacity: fields land at cells `p+o_k`, all `< 24` = the byte-cell
  reservation. (P4c) would need a byte-tier arm:
  `certified_bytes ≥ o_{N−1} + 8`, derived from the `gc_alloc_obj` `nbytes`
  operand — which **is** a compile-time constant here (`i64 24`), unlike the
  `:load` khb2 case. This is a *strengthening* opportunity, not a hole.

**Why this is not sufficient.** The decomposition writes cells `obj+0`, `obj+8`.
Class D reads cells `obj+0`, `obj+**1**`. Cell `obj+1` is never written ⇒ ADR
0018 §E defines an unstored load as `0` ⇒ the `.mem` field reads **0** where
native reads the Memory pointer. That is p06b's own "EXPECTED 42, ACTUAL 0"
witness with the roles reversed. **The store and the reads must be re-stamped
together or not at all.**

---

## 4. The 416r.13 / (P1) finding — **the corpus store is NOT the header write**

Answering item 3 precisely:

* The walled value type is literal **`{ ptr, ptr }`** (GenericMemoryRef body).
  `_is_genericmemory_header_struct` requires literal `{ i64, ptr }` ⇒ **false**.
* Probe `b07` + `b08`: there is **no live `store { i64, ptr }` anywhere** in the
  root; the only other aggregate stores are two `{ptr,ptr}` into
  `gc_alloc_obj(…,16,…)` boxes in **utzc-pruned dead blocks**.

⇒ **(P1) stays intact and is NOT touched by this arc.** The bead's framing
("gated on the 416r.13 singleton-header interaction argument") is inherited from
p06b's residual-risks list and does **not** describe wall 8. The widening
touches **(P4b)'s target granularity**, not (P1)'s value-type refusal.

**However, the 416r.13 interaction is real — it just lives in the D4 GEP arm.**
The byte stamp for the header is *type-based*
(`ew_gep = _is_genericmemory_header_struct(src_type_gep) ? 8 : 64`,
instructions.jl:4977). Probe `b08` confirms the corpus root uses that path for
**10 header GEPs**, including the 416r.13 shape
`gep {i64,ptr}, ptr %"jl_global#93", i32 0, i32 1` — whose base is a **global**
(the singleton-data alias arm emits *no node*, aliasing the dest to the global),
so it has **no `gc_alloc_obj` root**.

⇒ **Any provenance-based discriminator must be a UNION with the existing
type-based one, never a replacement.** A provenance-only rule would silently
demote the 416r.13 singleton headers to word granularity and break the shipped
`length@byte-cell 0 / data-ptr@byte-cell 8` layout — a silent miscompile, and
exactly the interaction the bead asked to have argued. **Stated, and it is a
constraint on the design, not a blocker.**

Nomenclature correction for the implementer: **`bennettvm-9n3y` is a dangling
ID that exists in neither tracker** (BennettVM WORKLOG, `bennettvm-rxgy` NOTES,
2026-08-04). The live filings are **`Bennett-zdd6`** (the literal-`{i64,ptr}`
mis-stamp discriminator, ex-"jb6w") and **`bennettvm-rxgy`** (byte-exact
memmove). Do not create new `9n3y` references.

---

## 5. (P5) coherence verdict — **INCOHERENT as written; must be granularity-parametrised**

Item 4's question, answered by execution. Probe `b06_p5.jl` replicates the corpus
use-shape (byte GEP at +8 **and** two-index `{ptr,ptr}` GEP at 0,1) on a
`malloc` target that (P4b) *does* certify, so the next predicate is exposed:

```
… — aggregate store target is addressed at BOTH the WORD granularity of this
store's struct fields (cell stride 8 bytes) and an incompatible granularity, via
the single-index BYTE-granular getelementptr `%b8 = getelementptr inbounds i8,
ptr %obj, i32 8` (source element type i8). … (Bennett-p06b, predicate
`_p06b_granularity_violation` / `_p06b_alias_group`)
```

**(P5) fires on the real corpus use-shape.** Consequences:

1. A (P4b)-only widening (the bead's literal mechanism) moves the wall from
   (P4b) to (P5) and clears **nothing**. Any implementer who only reads the bead
   will ship a no-op — flag this loudly.
2. (P5) is written as a *one-sided* predicate: it accepts only word-granular
   uses (two-index struct GEP with the stored type + the D2-dropped index-0
   carve-out) and rejects **every** single-index GEP by construction
   (instructions.jl:597-619, D2). Under byte-stamped admission the arm's own
   emission is byte-granular, so the accept/reject sets must **invert**: for a
   byte-tier target, single-index `i8` GEPs are the *agreeing* class and the
   word-stamped two-index struct GEPs become the *violation*.
3. Therefore (P5) must become `_p06b_granularity_violation(pv, st, tier)` and,
   crucially, **the D4 GEP arm must agree with it** — otherwise the only
   byte-tier target that can ever pass (P5) is one with no struct GEPs at all,
   which the corpus object is not.
4. The canonical slot key (`_p06b_slot_key`, root + total **byte** offset) is
   **unaffected** — it already folds every spelling to a byte offset and never
   consults `elem_width`. The alias-group machinery (N2/D3) is reusable
   verbatim. Only the *classification of an agreeing use* changes.
5. The h17-class repro **does** become sound under the new emission (store +0/+8,
   read +0/+8 — the point of the arc), *provided* item 3 (D4 re-stamp) lands.
   Without it, h17 flips from "store word, read byte" to "store byte, read word":
   **still broken, differently**.
6. The OLD word-stamped path must stay refused for genuinely mixed cases. With a
   tier-parametrised (P5), "mixed" is redefined as "uses disagreeing with the
   **target's tier**", which is strictly sharper than today's "any single-index
   GEP". The C tier (`malloc`/`alloca`, `_cell_count` = ÷8) keeps today's
   behaviour byte-identically as long as the tier predicate returns `:word` for
   every non-Julia root — that is the byte-identity obligation to pin.

---

## 6. Blast radius of the D4 re-stamp

The minimal sound change set is **three arms, not one**:

| arm | file:line | change |
|---|---|---|
| p06b store (P4b)+(P5)+emission | `instructions.jl:5550-5752` | admit byte-tier targets; parametrise (P5); `ew = tier == :byte ? 8 : 64` |
| **D4 two-index struct GEP** | `instructions.jl:4936-4978` | `ew_gep` from `type-predicate ∪ provenance` (§4), not type alone |
| **vbv9 arena memcpy** | `instructions.jl:2191-2209` | `IRPtrOffset(_, dst, k*ew_bytes, dst_ew)` is byte-wrong for K ≥ 2 — see §7.3 |

**Tests that pin the current behaviour** (must be re-authored deliberately, not
"fixed"):

* `test/test_p06b_aggregate_store.jl` **(N3)** — asserts the gc_alloc_obj reject
  fires with `gc_alloc_obj` / `BYTE-granular` / `9n3y` markers. This testset
  **inverts** under bvmd. Note it also pins the string `9n3y`, a dangling ID (§4).
* `test/test_p06b_aggregate_store.jl` **(k)** — both foz5 narrowings
  (`!(p06b && _growend!)` body-scope **and** `!p06b || gc_alloc_obj`
  discriminator). The bead's "marker trap" warning is correct; the discriminator
  term must be re-pointed at the *new* wall, and the body-scope term kept.
* `test/test_p06b_aggregate_store.jl` **(g4)/(D2)/(D7)/(N2)/(D3)** — the whole
  (P5) surface; each needs a tier-explicit control.
* `test/test_foz5_confined_bounds.jl` **(W8)** — positive
  `gc_alloc_obj || BYTE-granular`; **inverts**.
* `test/test_40ys_instanceless_callees.jl:535,550` and
  `test/test_7wsz_ptr_sret_fields.jl:549,555` — the same two-part
  advanced-wall marker; **invert**.
* `test/test_9n3y_memheader_gep.jl` — pins `ew == 8` for literal `{i64,ptr}`
  **and** a named-struct control at `ew == 64`. Must stay green **byte-identically**
  (the union constraint of §4).
* `test/test_haiy_ptr_cells_store_load_gep.jl`, `test/test_nd45_*.jl` — the C
  tier's `%struct.ht` word-granular pins. **The C-tier byte-identity obligation.**
* `test/test_vbv9_arena_memcpy.jl:150-161` — pins the K=1 arena memcpy
  `IRPtrOffset(offset 0)` + the byte field-GEP at 24. A K≥2 fix must extend, not
  break, these.
* Tolerant disjunctions that merely mention `gc_alloc_obj` and will silently
  keep passing (`test_6bu3:233`, `test_8bys:169`, `test_8g7m:311`,
  `test_beaw:215`, `test_a70z:987`, `test_583s:330`) — **not** load-bearing;
  do not treat their greenness as evidence.

---

## 7. The finding the bead does not contain: the Julia tier is byte-addressed **everywhere**

### 7.1 Allocas (probe `b09_alloca.jl`, executed)

The ROOT body's own frames:

```llvm
%"new::#_growend!##0#_growend!##1" = alloca [9 x i64], align 8   ; the closure env
%2                                 = alloca ptr, i32 3, align 8  ; the GC roots array
...
%19 = getelementptr inbounds i8, ptr %"new::#…#1", i32 8    ; store i64 %16
%20 = getelementptr inbounds i8, ptr %"new::#…#1", i32 16
%21 = getelementptr inbounds i8, ptr %"new::#…#1", i32 24
%22 = getelementptr inbounds i8, ptr %"new::#…#1", i32 32
%23 = getelementptr inbounds i8, ptr %"new::#…#1", i32 40
%24 = getelementptr inbounds i8, ptr %"new::#…#1", i32 56
%30 = getelementptr inbounds i8, ptr %2, i32 0 / 8 / 16
```

Measured emission:

```
Bennett.IRAlloca(:env,   64, ConstOperand(9))      # BVM reserves 9 cells: env+0..env+8
Bennett.IRPtrOffset(:g56, SSAOperand(:env), 56, 8) # addresses cell env+56  (!!)
Bennett.IRAlloca(:roots, 64, ConstOperand(3))      # reserves 3 cells
Bennett.IRPtrOffset(:r16, SSAOperand(:roots), 16, 8) # addresses cell roots+16 (!!)
```

`_lower_alloca!` (`BennettVM/src/ir/ingest_body.jl:560-605`) reserves exactly
`N` cells and bumps the cursor by `N`. So the closure-env write lands **48 cells
past its own reservation**, inside the next allocation. Store/load through the
same GEP are self-consistent, so a read-back looks fine — the failure mode is
**silent adjacent-allocation clobber**, which `bennettvm-pdqx` explicitly does
*not* catch (p06b's D1 disclosure, verbatim).

This is **live in the corpus root** (walls 9/10 sit in front of it today, §8) and
is **not reachable by any patch to the p06b store arm**. It is the same defect
class as wall 8, one tier up: Julia codegen byte-addresses *every* aggregate —
gc_alloc'd boxes, GenericMemory headers, **and stack frames** — while
`_alloca_reservation`/`_lower_alloca!` reserve word cells.

### 7.2 Why this decides the arc's shape

Two coherent designs exist and they differ materially. That is the definition of
a contested design space:

* **Design α — per-root tier tagging.** Extraction computes a tier for each
  pointer root (`:byte` for `gc_alloc_obj` / GenericMemory / 416r.13 singletons /
  Julia-emitted allocas; `:word` for C `malloc`/`alloca`/named structs) and every
  address-forming arm consults it. Pro: surgical, keeps C byte-identical. Con: a
  new global-ish analysis in an extractor that is deliberately depth-0
  everywhere; the tier must be *provable* per root, and pointer `phi`/`select`
  (the cc0 M2b WIDTH-0 SENTINEL) has no root.
* **Design β — make the reservation match the addressing.** Keep every stamp as
  is and instead make Julia-tier allocas reserve `nbytes` byte-cells
  (`IRAlloca(dest, 8, nbytes)`), so word/byte becomes a *single* convention per
  program. Pro: one rule, and it is BVM's existing `_byte_cells` rule. Con:
  requires a whole-module "is this a Julia-tier program" decision (BVM already
  has `_enforce_julia_heap_tier!`, `intrinsics_genericmemory.jl:192-199`), and
  changes `IRAlloca` emission for the C track unless carefully gated.

A third option — **fail loud at ingest on any object addressed at two
granularities** (Bennett-zdd6's alternative) — clears no walls but converts the
silent class into a crash, and may be the right *first* commit.

Proposers must not be handed this choice pre-made. **This is the upgrade
trigger.**

### 7.3 Latent sibling defect in vbv9 (probe `b10_vbv9k2.jl`, executed)

`_handle_memcpy_global_src` sets `dst_ew = 64` for an arena dst and emits
`IRPtrOffset(dst_off, dst_op, k*8, 64)`. For **K = 1** that is `offset 0` and
correct under any stamp — which is why the shipped fdict/`_j_const#1` cases are
green. For **K = 2** (a 16-byte global-src memcpy into a `gc_alloc_obj` dst):

```
Bennett.IRPtrOffset(:__v4, SSAOperand(:d), 8, 64)   # -> cell d+1
```

Byte-tier truth is cell `d+8`. **Latent** (no K ≥ 2 corpus witness yet), same
class, same fix. Must be in scope or explicitly deferred with a filed bead.

---

## 8. Next walls after bvmd (probe `b05_seq.jl` — successive textual removals from `root.ll`)

Measured, in order, each one real (not an artefact — each instruction is present
unmodified in the untouched `root.ll` and its operand chain is untouched by the
preceding removal):

| # | wall | instruction | owner |
|---|---|---|---|
| 8 | **this bead** | `store {ptr,ptr} %memory_ref, ptr %"new::Array"` | Bennett-p06b (P4b) |
| 9 | **arena-src memcpy** | `memcpy(%"new::Array.size" (alloca), gep i8 %obj,16, 8)` — *"memcpy **src** operand is not alloca-backed … (Bennett-37mt Phase 1)"* | Bennett-37mt / 8bys |
| 10 | **live base-cancelling difference used as a VALUE** | `%12 = ptrtoint %memory_data3` → `%memoryref_offset = sub %13, %12` → `udiv exact …, 8` → `add` | Bennett-583s / foz5 |
| 11 | alloca-target aggregate store | `store {ptr,ptr} %"new::Array.ref", ptr %0` where `%0 = alloca {ptr,ptr}` — p06b's own *silent-skip alloca* residual | Bennett-p06b (P4b) |
| 12+ | the §7.1 alloca-reservation/byte-GEP mismatch (silent, no wall) | `gep i8 %env, 56` off `alloca [9 x i64]` | **unfiled** |

**Wall 10 deserves the implementer's attention now**: it is *not* a bounds check.
The `sub` feeds `udiv exact …, 8` and its result is the element index —
a base-cancelling difference that **escapes as a live value**. foz5's §4a
confined-value contract requires clause (iii) "every use of each such `sub` is an
`icmp`", which is false here. So wall 10 needs a *third* admission contract
(or an oracle-match proof that byte-cell differences equal native byte
differences — which, note, is *exactly the premise §4a declined to prove*).

The bead's forecast candidates were "the 5oyt pgcstack wall" and "the 37mt/8bys
memcpy wall B". **Measured answer: 37mt is wall 9; there is no pgcstack wall
(`julia.get_pgcstack` extracts as an `IRCall` and `gep i8 %pgcstack, -152`
lowers via the p81t negative-offset relaxation — probe `b04`).**

---

## 9. The foz5 §4a validation-debt gate — **cannot be discharged by bvmd**

The bead states clearing wall 8 "lets the full push! corpus RUN on BVM". **That
is false, measured.** Walls 9, 10 and 11 still block *extraction* of the ROOT,
and `bennettvm-rxgy` (byte-exact `IntrinsicMemmoveBytes`) still blocks
`_growend!`'s grow-copy at BVM `lower_vm`. **No amount of bvmd work produces a
runnable `push!` corpus.** An implementer who accepts the bead's framing will
either fake the gate or blow the arc's scope. Say so in the commit message.

What *can* be built, and should be, as the arc's required deliverable:

**Gate design — "byte-tier round-trip with a confined guard" (synthetic E2E, BVM side).**
A hand-written `.ll` fixture (the `test_p06b_aggregate_store_vm.jl` /
`test_vbv9_arena_memcpy.jl` pattern) that reproduces the *shape* §4a is about,
with everything else already supported:

1. `julia.gc_alloc_obj(task, 24, tag)` → a 24-byte box (byte tier, 24 cells).
2. The **decomposed aggregate store** at fields 0/8 (the bvmd emission).
3. A **byte** field read at +8 and a **struct** field read at 0/1 of the *same*
   object — the class-D shape — asserting both land on the same cells.
4. A closure-env **alloca** written by extracted code and read back through a
   byte GEP (the §4a (INV) premise's actual mechanism).
5. A `ptrtoint`/`sub`/`icmp`/`br`-into-pruned-block guard over (4), i.e. a
   confined value in foz5's exact sense.
6. **Assertions:** (a) forward run matches a hand-computed oracle on in-bounds
   inputs; (b) `unstep!` to entry restores the initial `IState` exactly
   (arena cursor, memory, locals) — the Bennett-1973 invariant; (c) an
   out-of-bounds input **halts at `:__unreachable__`** rather than returning a
   wrong value.

**What (c) can and cannot show.** Constructing an out-of-bounds probe requires
driving the guard's operands to a failing combination. In the fixture that is
constructible (feed the length cell a value the index exceeds) and is worth
pinning. On the **real** corpus it is *not* constructible from the Julia source
— `push!` on a freshly allocated `Vector` never takes the `oob` edge — which is
precisely why §4a's residual ("the throw may be missed, or the halt spurious")
stays **undischarged by any test this arc can write**. Document that explicitly
rather than implying the fixture closes it.

**Honest status to record:** the fixture discharges the §4a debt *for the
mechanism* (byte-granular cells + closure slot written by extracted code ⇒ the
subtraction is faithful) on a program with that mechanism. It does **not**
discharge it for the corpus. File a follow-up bead gated on walls 9+10+11+rxgy.

---

## 10. Marker design for the arc's own gates

Load-bearing **negatives** (each fails for a distinct reason; none is redundant):

* `!occursin("Bennett-lgzx", msg)` and `!occursin("store of non-integer type", msg)`
  — wall 6 stays cleared.
* `!occursin("Bennett-583s", msg)` **must be DROPPED as a blanket negative** —
  wall 10 *is* a 583s reject, in the ROOT body. Replace with the foz5 pattern:
  `!(occursin("Bennett-583s", msg) && occursin("_growend!", msg))` (body scope)
  **plus** a discriminator `!occursin("Bennett-583s", msg) || occursin("udiv", msg)`
  or an equivalent anchor on the *live-value* shape. **This is bvmd's own marker
  trap and it is exactly the trap foz5 set for bvmd.**
* `!occursin("Bennett-jbko", msg)`, `!occursin("Bennett-iwo9", msg)`,
  `!occursin("memmove", msg)` — walls 3/5 stay cleared.
* `!(occursin("Bennett-p06b", msg) && occursin("gc_alloc_obj", msg))` — **the
  inverted (N3)/(k) discriminator**: after bvmd, a p06b reject naming
  `gc_alloc_obj` is a REGRESSION, not the expected wall.
* `!occursin("BYTE-granular getelementptr", msg)` — (P5) must not be the new
  wall (it would mean the D4 re-stamp was skipped).

Load-bearing **positives**: non-numeral anchors only (Bennett-0ncn), disjoined
because *which* set member fails first is iteration order, not contract —
`occursin("memcpy", msg) || occursin("Bennett-37mt", msg)` for wall 9.

**Unit-level positives that do not depend on the corpus** (the (N3)-replacement):
a fixture asserting the byte-tier emission is *exactly*
`IRPtrOffset(_, obj, o_k, 8)` for every k, plus a **negative control** that the
same store into a `malloc` target still emits `ew == 64`, plus the §4
**union control** that a 416r.13 `load ptr, ptr @"jl_global#N"`-based header GEP
still stamps 8. Those three together are the whole contract; message greps alone
are not.

---

## 11. TRIPWIRE ASSESSMENT — **UPGRADE**

**Grounds, in the tripwire's own terms:**

| trigger | verdict | evidence |
|---|---|---|
| the corpus store IS the header write | **NO** — (P1) intact, widening touches (P4b) only | §4, probes `b01`/`b07`/`b08` |
| byte/word cell-map agreement cannot be made exact | **YES** — not by the named mechanism. Exactness requires re-stamping the **D4 GEP arm** (a shared Julia/C discriminator, Bennett-zdd6) *and* confronting the alloca-reservation mismatch (§7.1) | §3, §6, §7, probes `b04`/`b09`/`b10` |
| (P5) coherence breaks | **YES** — (P5) fires on the corpus use-shape and its accept/reject sets must invert for byte-tier targets | §5, probe `b06` (executed) |

Two of three fire, and a fourth, unlisted condition fires hardest: the ROOT body
contains a **third granularity defect that no patch to the p06b arm can reach**,
with **two materially different coherent designs** (α per-root tier tagging vs β
byte-cell reservations, §7.2) plus a fail-loud-first option. Under CLAUDE.md §2
this is a core change to `ir_extract.jl`'s instruction dispatch **and** the
gate/predicate layer, so a 3+1 is mandatory anyway; the design contest makes the
two **blind** proposers substantive rather than ceremonial.

**Recommended proposer brief:** "Make the Julia tier's cell granularity coherent
across allocation, addressing and aggregate stores, keeping the C tier
byte-identical and the 416r.13 singleton headers byte-stamped. Corpus witness:
`docs/design/bvmd_scout.md` §2 and §7.1. You may propose a fail-loud-only first
commit." Proposers must be told **not** to treat the bead's
"`IRPtrOffset(_,_,8k,8)` per field" as the answer — it is one line of a
three-arm change, and on its own it clears no wall (§5).
