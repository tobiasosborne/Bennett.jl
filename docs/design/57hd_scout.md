# Bennett-57hd — DESIGN-VERIFYING SCOUT report

**Bead:** `Bennett-57hd` (P1) — "xkl frontier wall 10: base-cancelling difference
ESCAPES as a live element index via `udiv exact` — a THIRD admission contract"
**HEAD at time of scouting:** `97a188c` (Bennett-sy29, landed 2026-08-07)
**Scope:** verification pass only. **No `src/` or `test/` change was made; no commit.**
**Probes** (session scratchpad, all under `julia --project --check-bounds=yes`,
i.e. suite mode per CLAUDE.md §Build):
`w01_wall.jl` (wall + marker scan), `w03_mod.jl` (→ `rootmod.ll`, the module the
extractor actually parses), `w05_uses2.jl` (exhaustive forward use-closure +
backward provenance), `w06_growend.jl` (→ `growend.ll`), `w07_gecomp.jl`
(env+8 / env+16 sink closure inside `_growend!`), `w08_fromll.jl` + `.ll` surgery
(`root_patched.ll`, `root_q0.ll`, `root_q1.ll` — simulated admissions),
`w09_alpha.jl` (583s / foz5 predicate forensics + p06b slot keys),
`w10_pval.jl` / `w11_nopremise.jl` / `w13_all.jl` (route-α prototype +
premise-flip), `w14_delta.jl` (route-δ′ predicate over every cluster in both
bodies), `w15_markers.jl` (wall-11 / wall-12 marker profiles), `w16_scale.jl`
(`_root_scale` of the header base).

---

## VERDICT UP FRONT

**TRIPWIRE: UPGRADE. Full 3+1 (two blind proposers + implementer + orchestrator
review).** Grounds, each measured rather than argued:

| trigger | verdict | evidence |
|---|---|---|
| a policy-level THIRD admission contract is required | **YES** | §4 — 583s and foz5 both decline for *structural* reasons that no widening removes; the value is neither same-root nor confinable. |
| genuine multi-route contest | **YES** | §5–§8 — **two co-viable routes with opposite trade-offs**: α (rigorous, premise-light, covers **1 of 3** corpus clusters, needs a new GVN-lite analysis) vs δ′ (one syntactic predicate, covers **3 of 3**, but rests on a declared language-level invariant). Both measured; neither dominates. |
| confinement is unavailable, so the safety net foz5 relied on is gone | **YES** | §3.3 — the escaping index reaches `jl_alloc_genericmemory_unchecked`'s **allocation size** and `llvm.memmove`'s **length** inside `_growend!`. There is no halt bound; a wrong value is silent heap corruption. |
| the new contract must compose with foz5 §4a and jbko | **YES** | §9 — foz5's theorem is stated *relative to* "everything outside `τ` is computed by the pre-existing, already-sound model". A third contract that admits an **unproved live** value retroactively voids that clause. This is a hard constraint on the answer and it is exactly what a 3+1 exists to adjudicate. |
| a BVM `src/` change is needed | **NO** (for α / δ′) | §8 — `udiv`/`sub` are already first-class in both extraction (`instructions.jl:5099`) and BVM (`ir/operators.jl:104`, non-injective ⇒ history capture). The 8-commit zero-BVM-change streak survives α and δ′; it does **not** survive route γ. |

**The single sharpest thing this scout found**, and the thing the design question
must be built around: the wall-10 cluster is **not alone**. There are **three**
`sub(ptrtoint, ptrtoint)` clusters of the *same semantic shape* in the root
(`%top`, `%L21`, `%L43`) — measured, `w14`. Route α closes **only the first**;
routes δ′/ε close all three. Any proposal that clears wall 10 without a story for
`%L21`/`%L43` buys **two walls of progress** (§10) and then re-walls on its own
sibling.

---

## 1. Wall 10 at HEAD, reproduced (probe `w01_wall.jl`)

The gated path, exactly as the six advanced markers drive it:

```julia
_push57hd(n::Int64) = begin
    v = Int64[]; push!(v, n); @inbounds v[1]
end
Bennett.extract_parsed_ir_set_from_julia(_push57hd, Tuple{Int64}; ptr_cells=true)
```

Verbatim wall:

```
julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
`_push57hd#4948b802` (callable=_push57hd, argtypes=Tuple{Int64}) —
ir_extract.jl: ptrtoint in @julia__push57hd_32102:%top:
  %12 = ptrtoint ptr %memory_data3 to i64
— ptrtoint of a GenericMemory .data base under ptr_cells whose result is NOT
confined to a same-Memory base-cancelling bounds check … predicate
`_verify_memdata_bounds_cluster` … AND its result is not CONFINED to a
dead-throw bounds check either — predicate `_foz5_confined_dead_bounds`
(Bennett-foz5 / ADR 0017 §4a) …
```

Marker scan on that message (`w01`): `ptrtoint` ✓, `Bennett-583s` ✓,
`base-cancelling` ✓, `Bennett-foz5` ✓, `_foz5_confined_dead_bounds` ✓,
`_verify_memdata_bounds_cluster` ✓, `memory_data` ✓; and **`udiv` ✗** —
confirming the bead's warning that the `udiv exact` discriminator bvmd suggested
is *not constructible* (the `_ir_error` prefix quotes the ptrtoint, not the
cluster). `Bennett-37mt` / `memcpy` / `Bennett-8bys` / `Bennett-p06b` /
`gc_alloc_obj` / `BYTE-granular` / `Bennett-lgzx` / `Bennett-jbko` /
`Bennett-iwo9` / `memmove` / `Bennett-bvmd` all ✗ — walls 3/5/6/7/8/9 stay
cleared. **The bead text is accurate on the wall's identity.**

The same wall reproduces through `extract_parsed_ir_from_ll` on the dumped module
(`w08` on `rootmod.ll`), which is what makes every `.ll`-surgery probe below
legitimate.

---

## 2. The cluster at HEAD, with exact SSA names

`rootmod.ll:32-70` (the module the extractor parses — `code_llvm(…,
dump_module=true, optimize=false)`; addrspaces already stripped, so the SSA
numbering matches the wall message, unlike a plain `code_llvm` dump).

```llvm
top:
  %"jl_global#93"   = load ptr, ptr @"jl_global#93"                    ; empty-Memory singleton
  %memory_data_ptr  = getelementptr inbounds { i64, ptr }, ptr %"jl_global#93", i32 0, i32 1
  %memory_data      = load ptr, ptr %memory_data_ptr                   ; (S) the .data slot
  %3                = insertvalue { ptr, ptr } zeroinitializer, ptr %memory_data, 0
  %memory_ref       = insertvalue { ptr, ptr } %3, ptr %"jl_global#93", 1
  %"new::Array"     = call noalias … ptr @julia.gc_alloc_obj(ptr %current_task, i64 24, ptr %4)
  %5 = getelementptr inbounds i8, ptr %"new::Array", i32 8
  store ptr null, ptr %5                                               ; [8,16)
  store { ptr, ptr } %memory_ref, ptr %"new::Array"                     ; [0,16)  <-- p06b/bvmd
  %"new::Array.size_ptr" = getelementptr inbounds i8, ptr %"new::Array", i32 16
  call void @llvm.memcpy(… %"new::Array.size_ptr", @"_j_const#1", i64 8, …)   ; [16,24)
  %6 = getelementptr inbounds { ptr, ptr }, ptr %"new::Array", i32 0, i32 0
  %7 = load ptr, ptr %6                                                ; ref.ptr_or_offset
  %8 = getelementptr inbounds { ptr, ptr }, ptr %"new::Array", i32 0, i32 1
  %9 = load ptr, ptr %8                                                ; ref.mem
  …
  %memory_data_ptr2 = getelementptr inbounds { i64, ptr }, ptr %9, i32 0, i32 1
  %memory_data3     = load ptr, ptr %memory_data_ptr2                  ; ref.mem.data
  %12 = ptrtoint ptr %memory_data3 to i64                              ; <-- WALL 10
  %13 = ptrtoint ptr %7 to i64
  %memoryref_offset    = sub  i64 %13, %12
  %memoryref_offsetidx = udiv exact i64 %memoryref_offset, 8           ; <-- (C2) fails here
  %14 = add i64 %memoryref_offsetidx, 1
  %15 = add i64 %14, %11                                               ; %11 = size + 1
  %16 = sub i64 %15, 1
  %17 = icmp slt i64 %.unbox, %16
  %18 = xor i1 %17, true
  br i1 %18, label %L18, label %L16
```

**Semantic content, stated once:** the cluster is
`array.ref.ptr_or_offset − array.ref.mem.data`, i.e. Julia's `memoryrefoffset` —
the byte displacement of the `MemoryRef` inside its `GenericMemory`, converted to
an element index by `udiv exact 8`.

---

## 3. The COMPLETE escape graph (item 1) — measured, not sketched

### 3.1 Forward use-closure (probe `w05_uses2.jl`, exhaustive `LLVM.uses` BFS)

```
%12                    -> {sub}                                   (single use)
%memoryref_offset      -> {udiv exact}                            (single use)
%memoryref_offsetidx   -> {%14 = add …, 1}                        (single use)
%14                    -> {%15 = add %14,%11 ; STORE i64 %14, env+16}
%15                    -> {%16 = sub %15, 1}
%16                    -> {%17 = icmp slt %.unbox, %16 ; STORE i64 %16, env+8}
%17                    -> {%18 = xor %17, true}
%18                    -> {br i1 %18, %L18, %L16}
```

**The complete sink set in the root is therefore three items:**

1. `store i64 %14, ptr env+16`
2. `store i64 %16, ptr env+8`
3. `br i1 %18, label %L18, label %L16`

**Sink 3 is a LIVE branch.** Both successors are ordinary blocks — `%L18`
continues, `%L16` calls `_growend!`. Neither is in the utzc pruned dead set.
This alone refutes any foz5-style confinement: there is no `:__unreachable__`
successor to absorb a wrong choice.

### 3.2 Backward provenance — SAME-OBJECT verdict

`w05` walks both `sub` operands to their roots:

| operand | chain | terminal |
|---|---|---|
| `%13` ← `%7` | `load` ← `gep {ptr,ptr} %"new::Array", 0, 0` | `%"new::Array"` (`gc_alloc_obj`) |
| `%12` ← `%memory_data3` | `load` ← `gep {i64,ptr} %9, 0, 1`; `%9` = `load` ← `gep {ptr,ptr} %"new::Array", 0, 1` | `%"new::Array"` (`gc_alloc_obj`) |

**VERDICT: the two loads denote the two halves of ONE `MemoryRef`, both read out
of ONE freshly `gc_alloc_obj`-ed `Array` header.** They are *not* two unrelated
objects (contrast foz5, where the halves arrive through two different function
`Argument`s with no SSA edge). The bead's phrasing "two distinct `:load` roots"
is right about `_memdata_root` (§4) but understates the situation: there is a
shared syntactic base, and §5/§6 both exploit it.

Going one step further (probe `w10_pval.jl`), the two values are not merely
same-object — in this program they are the **same value**:
`%7` ≡ field 0 of the aggregate store ≡ `%memory_data`; `%9` ≡ field 1 ≡
`%"jl_global#93"`; hence `%memory_data3` is a **reload of the very slot (S)
that `%memory_data` read**. See §5.

### 3.3 How far the value flows — the `_growend!` sink set (probe `w07_gecomp.jl`)

The two env slots are closure fields read by `_growend!`
(`growend.ll`, `julia_#_growend!##0_174`). Exhaustive forward closure from the
`env+8` / `env+16` GEP users (74 and 47 instructions respectively):

| via | reaches | why it matters |
|---|---|---|
| **env+8** | `%"Memory{Int64}[]" = call … @jl_alloc_genericmemory_unchecked(ptls, %127, …)` | the **allocation size** of the new backing memory |
| **env+8** | `call @llvm.smul.with.overflow.i64(i64 %125, i64 8)` + `icmp slt … 0` + `icmp slt 9223372036854775806, %127` | overflow guards on that size |
| **env+8 / env+16** | `call void @llvm.memmove(%memory_ref15.ptr_or_offset, %.unbox66, i64 %50, …)` | the **byte length of the data migration** |
| **env+8 / env+16** | `%38 = sub %37,%36` (`%L46`), `%46 = sub %45,%44` (`%L58`) | the **offset operand of two 583s-PROVED bounds clusters** |
| **env+16** | `call void @ijl_bounds_error_int(…, i64 %value_phi)` | a throw argument |
| **env+16** | `%memoryref_offset = sub i64 %value_phi, 1` (`%L46`) → `mul …, 8` → element addressing | **memory addressing** |
| **env+8** | `store { ptr, ptr } %memory_ref15, ptr %2` / `%0` / `%"box::GenericMemoryRef40"` | the returned `MemoryRef` |

**This is the decisive finding.** The escaping index is not merely "live"; it
determines an **allocation size** and a **memmove length** in the reversible
heap. Under BennettVM's arena (`bennettvm-pdqx`: no region table, three monotone
cursors) a wrong allocation size is an *undetectable* adjacent-allocation
clobber, and ADR 0018 §E reads an unstored load as `0`. **There is no confinement
story available, and no proposal may pretend otherwise.**

It also perturbs `arena_top`, hence **every subsequent pointer cell value** —
which is the substrate jbko's `icmp eq` invariance argument stands on (§9).

---

## 4. Predicate forensics — exactly why 583s and foz5 decline (probe `w09_alpha.jl`)

Measured, by calling the shipped predicates directly:

```
_memdata_root(%memory_data3)                     = %9 = load ptr, ptr %8
_memdata_root(%7)                                = nothing
_verify_memdata_bounds_cluster(%12, %memory_data3) = false
_foz5_cert_src_kind(%memory_data3)               = :load
_foz5_cert_src_kind(%7)                          = :load
```

* **583s (`instructions.jl:1504-1519`)** requires `_memdata_root(sib) == root`.
  `%7` is a `load` of a `{ptr,ptr}` **field-0** GEP; `_is_memdata_field1_gep`
  demands a literal `{i64,ptr}` at indices `[0,1]`, so `_memdata_root(%7)` is
  `nothing`. The comparison is `nothing == %9` ⇒ `false`. **Not a near miss:
  583s's root notion has no concept of "the other half of a MemoryRef".**
* **foz5 (`instructions.jl:1774-1818`)**: (C0) **passes** for both sides
  (`:load`, named, unsuppressed); (C1) **passes** (single use, 2-operand i64
  `sub`, sibling is a `ptrtoint`); (C2) **fails** at `:1811-1812` — the sub's
  sole use is `udiv exact`, not `LLVMICmp`.

Widening foz5 clause (iii) to admit `udiv` is **not** a candidate. It would
delete the confinement theorem's premise: `τ` would then contain a value that is
stored, and §3.3 shows the store's consumer allocates memory. `docs/design/foz5/`
and `instructions.jl:1597-1604` already name that misreading ("do NOT read
'oracle match or loud halt' as 'oracle match'") as the arm's chief hazard.

**p06b slot keys** (the canonicaliser a route-α design would reuse):

```
_p06b_slot_key(%memory_data_ptr)  = (%"jl_global#93", 8)
_p06b_slot_key(%memory_data_ptr2) = (%9,              8)
```

Identical offsets, different roots — *and the roots differ only because `%9` has
not been canonicalised to `%"jl_global#93"`.* That one missing step is route α.

---

## 5. ROUTE α — value-identity (the same-slot-reload lemma). **FEASIBILITY: PROVEN, SCOPE: 1 of 3**

### 5.1 The claim

If the two `ptrtoint` operands can be shown to be **copies of the same pointer
value**, then `sub ≡ 0` in *both* worlds, under **any** assignment of an integer
to that cell. This is 583s's own proof discipline at displacement 0 — quoting
`foz5_scout.md §2.2`: *"the difference is the sum of the GEP offsets under any
assignment of an integer to that cell. No model assumption, no ABI assumption.
Base-independence is derived, not assumed."* Route α extends the *derivation*
from **syntactic SSA identity** to **value identity through memory**.

### 5.2 The prototype, and what it needed (probe `w10_pval.jl`)

A ~110-line `_pval` canonicaliser was written and run against the real corpus
module. Trace, verbatim:

```
FORWARD %7            <= field 0 of  store { ptr, ptr } %memory_ref, ptr %"new::Array"  ==> %memory_data
FORWARD %9            <= field 1 of  store { ptr, ptr } %memory_ref, ptr %"new::Array"  ==> %"jl_global#93"
RELOAD  %memory_data3 == %memory_data   [no clobber between]

pval(A) = %memory_data
pval(B) = %memory_data
EQUAL ⇒ sub ≡ 0 : true
```

Ingredients, and where each already lives:

| ingredient | status |
|---|---|
| canonical address key `(root, byte_offset)` | **exists** — `_p06b_slot_key` (`instructions.jl:1035`) |
| "the same slot under two SSA names" idea | **exists** — `_p06b_alias_group` (`:1076`), the GC RELOAD-AFTER-SAFEPOINT shape hostile review D3 already forced |
| aggregate-store field forwarding through an `insertvalue` chain | **NEW** (~40 LOC) |
| same-slot reload with a no-clobber scan | **NEW** (~40 LOC) |
| write-footprint of each intervening instruction | **NEW**, needs an intrinsic effect table |
| object disjointness (`alloca` / `noalias` call vs anything) | **NEW**, one predicate |

### 5.3 The premises, enumerated, and one of them measured LOAD-BEARING

* **(P-α1) `noalias` on `julia.gc_alloc_obj`** — a fresh allocation does not
  overlap the singleton `Memory`. Native side: a Julia-codegen-asserted LLVM
  attribute. VM side: a *theorem* of ADR 0018 §A's deterministic bump allocator.
* **(P-α2) the intrinsic write-footprint table** — `julia.gc_alloc_obj` and
  `julia.get_pgcstack` write nothing outside their own result object;
  `memcpy`/`memset`/`memmove` write exactly `[dst, dst+n)`.
  This is *the same declaration* ADR 0017 Decision item 4 already makes for the
  bounded intrinsic boundary.

  **Measured load-bearing** (probe `w11_nopremise.jl`): reclassify
  `julia.gc_alloc_obj` as unknown-effect and the lemma collapses —
  `BLOCKED reload for %memory_data3: unknown-effect: %"new::Array" = call noalias
  … @julia.gc_alloc_obj`, `EQUAL ⇒ false`. The premise is not decoration.

**Crucially, α's witness is a LIVE instruction.** The `insertvalue` chain feeding
the aggregate store is *used by that store*. foz5 §4.2 refused to build on a
**dead** `insertvalue` that "survives solely because extraction runs at
`optimize=false`" — a direct Rule 5 violation. α does not inherit that objection.

### 5.4 What α does NOT reach — the load-bearing limitation (probe `w13_all.jl`)

Run over **every** `sub(ptrtoint,ptrtoint)` in the root:

| cluster | blk | 583s root-eq | **α val-eq** |
|---|---|---|---|
| `%memoryref_offset = sub %13, %12` | `%top` | false | **TRUE** |
| `%45 = sub %44, %43` | `%L21` | false | **false** |
| `%59 = sub %58, %57` | `%L43` | false | **false** |

Reason, verbatim from the trace:

```
BLOCKED store-forward for %memoryref_mem: unknown-effect:
  call void @"j_#_growend!##0_95"(ptr … sret({ ptr, ptr }) %sret_box …)
BLOCKED reload      for %memoryref_mem: unknown-effect: (same call)
```

The `_growend!` call sits between the header write and the `%L21` / `%L43`
reloads, and it *does* rewrite the header. **α is intraprocedural and therefore
stops at the first call that touches the object.** Wall 10 clears; walls 13/14
(the same shape, two walls further on — §10) do not.

---

## 6. ROUTE δ′ — same-MemoryRef base cancellation. **SCOPE: 3 of 3, PREMISE: 1 declared**

### 6.1 The predicate (prototyped in `w14_delta.jl`)

A provenance-pair test, structurally a sibling of
`_verify_memdata_bounds_cluster`. Define `refrole(v)` by a depth-bounded walk
that propagates through `getelementptr i8` (the element byte-offset GEP) and
seeds on:

* `load ptr` of `gep({ptr,ptr} P, 0, 0)` ⇒ `(P, :data_half)`
* `load ptr` of `gep({i64,ptr} M, 0, 1)` where `M` = `load ptr` of
  `gep({ptr,ptr} P, 0, 1)` ⇒ `(P, :mem_data)`

δ′ admits a `sub` iff its two `ptrtoint` operands yield roles
`(P, :data_half)` and `(P, :mem_data)` with the **same** `P`. The conclusion is
583s's: the `.data` base cancels and the difference is the accumulated `i8`-GEP
byte displacement.

### 6.2 Measured coverage — and NO STEAL

`w14` over **both** bodies, every `sub(ptrtoint,ptrtoint)`:

| body | cluster | blk | 583s root-eq | **δ′** |
|---|---|---|---|---|
| root | `%memoryref_offset` | `%top` | false | **TRUE** ← wall 10 |
| root | `%45` | `%L21` | false | **TRUE** |
| root | `%59` | `%L43` | false | **TRUE** |
| `_growend!` | `%38` | `%L46` | **true** (583s owns it) | false |
| `_growend!` | `%46` | `%L58` | **true** (583s owns it) | false |
| `_growend!` | `%100` | `%idxend41` | false | false ← **foz5 §4a owns it** |

This is a **clean three-way partition of the corpus**, and it is the strongest
architectural argument in this document:

| contract | provenance shape | proof status |
|---|---|---|
| **583s** | both operands off the SAME `.data` load | pure syntax; no model assumption |
| **δ′ (new)** | the two halves of ONE in-body `MemoryRef` header | syntax + the checked byte tier + **one declared language invariant** |
| **foz5 §4a** | the two halves of a SPLIT captured ref (two `Argument`s) | no oracle proof; confinement only |

δ′ steals nothing from 583s (measured `false` on both 583s clusters), nothing
from foz5 (measured `false` on `%idxend41` — the split-ref case has no in-body
`{ptr,ptr}` header, so it *cannot* match), and nothing from jbko (whose uses are
`icmp eq`/`ne`, never a `sub`). The `p07_steal.jl`-style probe foz5 was forced to
write is still owed by the implementer, but the shape says the steal is
structurally impossible, exactly as foz5 arranged for itself.

### 6.3 The premise, stated as honestly as §4a's A-ledger demands

> **(P-δ1) the MemoryRef invariant.** For a Julia `MemoryRef{T}` materialised as
> a literal `{ptr,ptr}`, field 0 (`ptr_or_offset`) points **into** field 1
> (`mem`)'s data region.

Native side: a **Julia language/type invariant** — not an ABI fact, not a codegen
layout convention, and therefore *not* the class Rule 5 forbids relying on (which
is what foz5's premise was: "closure field +56 is field 0 of the captured ref").
VM side: transported by the ordinary oracle-match induction hypothesis.

> **(P-δ2) the byte tier.** Within one allocation, φ(p + k bytes) = φ(p) + k.

**Checkable**, and it is already checked: `_root_scale(%"new::Array")` measures
`(1, 24, "a julia.gc_alloc_obj BYTE-cell reservation of 24 cell(s)")` (probe
`w16_scale.jl`) — scale **1 byte per cell**, so a VM pointer cell *is* a byte
address and a same-region difference is byte-exact. `_check_scale_coherence!`
(`module_walk.jl:688-696`) already runs on this path (sy29 §5, probe `s09`). bvmd
supplied the first runtime evidence for it. **A δ′ arm MUST be gated on
`_root_scale(P)[1] == 1`, both to keep the premise true and for §6.4.**

### 6.4 The hazard a hostile reviewer will go for first

δ′ recognises an **unnamed literal `{ptr,ptr}`** as "a MemoryRef". That is a
direct amplification of the `bennettvm-jb6w` residual risk already disclosed in
`_is_genericmemory_header_struct`'s docstring (clang's SysV register-coercion
spill of a by-value `struct {long; void*;}` emits a literal `{i64,ptr}`). A C
`struct { void *a; void *b; }` is *far* more common than `{i64,ptr}`, and a C
pointer difference across two such fields would be wrongly admitted — **silently**.

Mitigations available, all measurable: (i) the conjunction is already
Julia-specific (δ′ needs a literal `{ptr,ptr}` **whose field 1 is loaded and then
GEP'd as a literal `{i64,ptr}`** — the nested pair is a strong Julia marker);
(ii) the `_root_scale == 1` byte-tier gate excludes the C tier by construction;
(iii) `_is_genericmemory_header_struct` is already the discriminator of record.
**A proposer that does not address jb6w explicitly should be sent back.**

---

## 7. Routes that were considered and are CLOSED, with the measurement that closes them

### β — confine the escaping index some other way
**CLOSED by §3.3.** The bead's own formulation ("used ONLY as an `IRVarGEP` index
+ a §4a-confined guard operand") does not describe the corpus: the sinks are a
**live** branch, an **allocation size**, and a **memmove length**. Any
"confinement" whose damage bound is "a wrong branch ⇒ a loud halt" is false here;
the damage bound is "a wrong heap". A variant that pushes the obligation onto
`IRVarGEP` faithfulness is circular — `IRVarGEP` is faithful *iff* the index is.

### foz5 clause-(iii) widening (`udiv` added to the `icmp` whitelist)
**CLOSED by §4 + §3.3.** It deletes the theorem's premise rather than extending
its reach, and `instructions.jl:1597-1604` pre-emptively names the misreading.

### 583s `_memdata_root` widening to a new ROOT shape
**CLOSED, historically and structurally.** foz5's probe `p07_steal.jl` measured
that widening `_memdata_root` makes the 583s arm CLAIM jbko's `%L84` witness and
then ERROR — regressing the chain to a wall *earlier* than wall 7
(`instructions.jl:1554-1557`). δ′ deliberately leaves `_memdata_root`
byte-for-byte untouched and gates on the **use/provenance pair**, which is the
mechanism that made foz5's non-steal structural rather than accidental.

---

## 8. Routes that remain OPEN as alternatives to α / δ′

### γ — runtime-checkable admission
Admit under δ′'s premise **and emit a check that the premise held**, so the
guarantee is restored to a theorem of the foz5 family ("oracle match **or** loud
halt"). Two sub-variants, honestly costed:

* **γ-a (extraction-side CFG synthesis)** — emit `icmp` + `br` to the existing
  `IRBranch(:__unreachable__)` sink. **Zero BVM `src/` change.** But extraction
  would, for the first time, *synthesise control flow*. Blast radius: ADR 0022
  (phi-edge binding), the utzc dead-block set, `lower.jl`'s topo sort and back-edge
  detection, and every reversibility invariant downstream. This is not obviously
  compatible with the `dead_blocks` coupling note at `instructions.jl:1628-1631`
  ("Never re-derive … the two must stay one set by construction").
* **γ-b (BVM assert node)** — cleaner, but **breaks the 8-commit zero-BVM-change
  streak** and needs a reversible semantics for a halting assert.

**Honest limit of γ, and a proposer must state it:** a range/alignment check
(`0 ≤ d < len·8`, `d % 8 == 0`) catches the *gross* violation (a cross-allocation
difference) and **not** a subtle mismatch. γ upgrades the failure mode; it does
not by itself supply oracle match. It is best read as a *complement* to δ′, not a
substitute.

### ε — interprocedural α
Discharge (P-δ1) **inductively** over the closed world: every `{ptr,ptr}`
MemoryRef constructed anywhere in the transitive callee set satisfies
field 0 = field 1's `.data` + k·elsz. The callee set is already available
(`extract/callgraph.jl`, CW-D1a `transitive_callees`). This would make the whole
class *proved*, α and δ′ both. **Cost: the first interprocedural analysis in the
extractor**, plus a call-effect summary. A proposer choosing ε must show how it
degrades — a summary that cannot be computed must produce the *existing* loud
wall, never an admission.

### Failure-direction matrix (bvmd adjudication style)

| route | native RETURNS | native THROWS | corpus coverage | BVM `src/` |
|---|---|---|---|---|
| **α** | same value (**proved**: difference ≡ 0 in both worlds under any cell assignment) | unaffected — every downstream guard sees oracle-exact operands | **1 / 3** | none |
| **δ′** | same value **iff (P-δ1)**; otherwise wrong allocation size / memmove length ⇒ **silent** heap corruption | throw missed **or** spurious; unbounded, as §4a | **3 / 3** | none |
| **β** | — | — | closed (§7) | — |
| **γ-a** | same value **or loud halt**, for the violations the check covers | same, plus a new spurious-halt channel | 3 / 3 | none, but CFG synthesis |
| **γ-b** | as γ-a | as γ-a | 3 / 3 | **yes — streak broken** |
| **ε** | same value (**proved**) | unaffected | 3 / 3 + subsumes (P-δ1) | none |

**α is the only row with both columns bounded and no new premise class — and the
only row that does not clear the corpus.** That tension *is* the design question.

---

## 9. Contract-interaction audit (item 4) — the composition rule

Measured (`w07_gecomp.jl`, `w14_delta.jl`):

* **Does the escaping value reach foz5's §4a-confined `sub`?** **NO.** The
  `%idxend41` cluster's offset is `%memoryref_offset46 = sub %.unbox45, 1` with
  `%.unbox45 = load i64, ptr env+32`, and `env+32` is written in the root by
  `memcpy(env+32, %"new::Array.size", 8)` — the array size, not our index. The
  third contract does **not** have to compose with §4a on this path.
* **Does it reach jbko's `%L84` `icmp eq`?** **NO** directly — that compare reads
  `env+56` (the ref's `ptr_or_offset` half) against `%coercion`. **But see below.**
* **Does it reach 583s-proved clusters?** **YES** — it is the *offset operand* of
  `%38` (`%L46`) and `%46` (`%L58`). 583s's base-cancellation theorem is
  *base*-independent and survives a wrong offset; what does not survive is oracle
  match, which 583s never claimed for the offset. **583s is a relative-correctness
  proof and inherits any upstream unsoundness.**
* **Indirect jbko coupling (state it, do not hand-wave it).** Via `env+8` the
  value sets `jl_alloc_genericmemory_unchecked`'s size, hence `arena_top`, hence
  **every subsequent pointer cell value**. jbko's admission rests on "for a fixed
  program and fixed inputs, the value in every pointer cell is a pure function of
  the execution trajectory" (`instructions.jl:1833-1839`) and on `eq`/`ne` being
  invariant under *any* injective relabelling. Injectivity survives a wrong size;
  **trajectory correspondence with native does not.**

> **COMPOSITION RULE (the constraint the 3+1 must respect).**
> `_foz5_confined_dead_bounds`'s theorem is stated *relative to* the clause
> "everything outside `τ` is computed by the pre-existing, already-sound model"
> (`instructions.jl:1586-1588`). Admitting an **unproved live** value places an
> unsound producer *outside* `τ`, which **retroactively voids ADR 0017 §4a's
> theorem and, by the arena-layout coupling, jbko's**. Therefore the third
> contract must be an **oracle-match** contract (α / δ′ / ε class) or a
> **halt-guaranteed** one (γ). A "third confinement" is not available, and a
> route that merely *declares* the value correct must say, in the ADR, that §4a's
> and jbko's guarantees are now conditional on the same declaration.

---

## 10. Blast radius (item 5)

### 10.1 Wall ordering after admission — measured by `.ll` surgery

Simulated admission = rewrite the cluster's `ptrtoint`s to `add i64 0, 0`
(preserves LLVM's unnamed-value numbering, removes the coercion, keeps the
`sub`/`udiv`). Successive walls, each re-measured (`w08` + `w15`):

| wall | site | reject |
|---|---|---|
| **11** | `%L16`: `memcpy(env+40, %"new::Array.ref.mem", 8)` | `Bennett-37mt` Predicate-6 **src** half — "memcpy src operand is not alloca-backed … tracked in Bennett-8bys". This is **corpus site #4** of sy29 §1.1 (the loaded/`extractvalue`-`ptr` `.mem` src class). |
| **12** | `%L16`: `store { ptr, ptr } %"new::Array.ref", ptr %0` | `Bennett-p06b` — "aggregate store target … is an `alloca { ptr, ptr }`, whose allocated type the alloca arm **SILENTLY SKIPS**" (`_p06b_cell_ptr_target_kind`) |
| 13 / 14 | `%L21` / `%L43` clusters | the **same** wall-10 message again, unless the chosen route is δ′/ε |

**CORRECTION to the bvmd b05 forecast** (which the bead repeats): wall 11 is
**not** the `alloca {ptr,ptr}` silent-skip / `Bennett-1zow`. That is **wall 12**,
and it is **loud** (a p06b reject naming the silent skip), not silent — a silent
skip by definition produces no wall at all. Both are measured; the ordering is
`37mt/8bys` **then** `p06b/1zow`.

### 10.2 The six marker sites, and the wall-11 replacement

The six advanced at sy29 (verified present at HEAD by grep):
`test_bvmd_root_scale.jl:677-707`, `test_p06b_aggregate_store.jl:765-791`,
`test_foz5_confined_bounds.jl:855-872`, `test_40ys_instanceless_callees.jl:542-558`,
`test_7wsz_ptr_sret_fields.jl:551-560`, `test_vau9_variable_memmove.jl:316-336`.

Each pins the same three-part shape. What happens to each at wall 11 — measured
`occursin` results on the real wall-11 message (`w15_markers.jl`):

| assertion at HEAD | wall-11 truth | action |
|---|---|---|
| `occursin("Bennett-583s") \|\| occursin("Bennett-foz5")` | **false / false** | **FLIPS — must be replaced** |
| `!occursin("Bennett-37mt")` | `Bennett-37mt` = **true** | **FLIPS — must be replaced** |
| `!(occursin("Bennett-583s") && occursin("_growend!"))` | both false | still true, **keep verbatim** |
| `!(occursin("Bennett-p06b") && occursin("gc_alloc_obj"))` | both false | still true, keep |
| `!occursin("BYTE-granular getelementptr")` | false | still true, keep |
| `!occursin("Bennett-bvmd")` | false | still true, keep |
| `!occursin("Bennett-jbko" / "Bennett-iwo9" / "Bennett-lgzx" / "memmove" / "store of non-integer type")` | all false | still true, keep |

**THE SY29 LESSON APPLIED — check the discriminator against the MESSAGE TEXT, not
the IR.** The wall-11 message is *textually the same reject* as wall 9's, which
the six markers must never silently re-accept. Measured discriminators available
in the wall-11 message: `Bennett-8bys` ✓, `src operand` ✓, `memcpy` ✓, and
crucially **`new::Array.ref.mem` ✓** while **`new::Array.size_ptr` ✗** (wall 9
quoted `%"new::Array.size_ptr1"`). Recommended replacement, in the foz5/sy29
two-part idiom, non-numeral anchors only (Bennett-0ncn):

```julia
# BODY SCOPE — unchanged intent: wall 7 was the CLOSURE's `%idxend41` cluster.
@test !(occursin("Bennett-583s", msg) && occursin("_growend!", msg))
# NEW LOAD-BEARING NEGATIVE — wall 10 is CLEARED; a 583s/foz5 reject in the ROOT
# body is now a REGRESSION, not the expected wall. (Replaces the sy29 positive.)
@test !occursin("base-cancelling", msg)
@test !occursin("_foz5_confined_dead_bounds", msg)
# POSITIVE, wall 11 — the loaded-`ptr` (.mem) memcpy SRC class, corpus site #4.
@test occursin("Bennett-37mt", msg) && occursin("src operand", msg)
# DISCRIMINATOR vs WALL 9 — wall 9 quoted `%"new::Array.size_ptr1"`; wall 11
# quotes `%"new::Array.ref.mem"`. Same reject TEXT, different site: without this
# the marker cannot tell a wall-9 regression from wall-11 progress.
@test occursin("new::Array.ref.mem", msg)
@test !occursin("new::Array.size_ptr", msg)
```

`test_jbko_ptr_identity_icmp.jl:554-555` asserts `Bennett-583s` /
`base-cancelling` positively **on its own fixture, not the corpus** — untouched.

### 10.3 INERT expectations — green baselines re-measured at HEAD

Run individually under `--check-bounds=yes` (suite mode):

| file | baseline | exposure |
|---|---|---|
| `test_583s_memdata_bounds.jl` | **28/28** | its own fixtures. δ′ must not steal any of them — re-run and diff, do not assume. |
| `test_foz5_confined_bounds.jl` | **63/63** | gate (B) is the executable refutation of the "oracle match" misreading; gates (C1)/(C2)/(N)/(B1)/(B3)/(C6) pin (C0)'s refusals. **All must stay byte-identical** — a third contract that changes any of them has widened §4a by accident. |
| `test_jbko_ptr_identity_icmp.jl` | **73/73** | §9's indirect coupling; the fixture pins are inert but the ADR text is not. |
| `test_bvmd_root_scale.jl` | **84/84** | marker site (I) + `_root_scale`, which a δ′ tier gate would consume. |
| `test_p06b_aggregate_store.jl` | **617/617** | marker site (k); route α would reuse `_p06b_slot_key`/`_p06b_alias_group`, so this is the reuse-regression surface. |
| `test_sy29_arena_src_memcpy.jl` | **91/91** | wall 9's own arm; wall 11 is its SRC-half sibling — do not edit it here. |
| `test_vau9_variable_memmove.jl` | **69/69** | marker site, the one the bead's "four" misses. |
| `test_40ys_instanceless_callees.jl` | **128/128** | marker site. |
| `test_7wsz_ptr_sret_fields.jl` | **106/106** | marker site (J). |
| `test_37mt_memcpy_const_aligned.jl` | **86/86** | not this bead's arm, but the one **wall 11** will edit next — keep it byte-identical here. |

All ten measured green at HEAD `97a188c` under `--check-bounds=yes`
(1345 assertions total across the ten files).

### 10.4 BennettVM

Expected **zero `src/` change** for α and δ′, and this is measured rather than
assumed: `udiv`/`sub` are already first-class on both sides
(`instructions.jl:5099-5100`; `BennettVM/src/ir/operators.jl:104`, with the
non-injective-op history capture at `ir/arithmetic_assignment.jl:265`). The
admission emits ordinary `IRBinOp` nodes on existing cells; the `udiv exact`
costs history, not capability. **If a proposer's design needs a BVM node, that is
a late-firing upgrade trigger — stop and escalate** (sy29 §11.3 discipline).

What BennettVM **is** owed regardless of route: an E2E fixture that *executes*
the wall-10 cluster and asserts the computed index equals native's, under both
history regimes with exact `unrun!`. That is the runtime leg (P-δ2) has been
missing since foz5 disclosed the validation debt (`instructions.jl:1619-1626`),
and bvmd's byte-tier fixture is the first place it can now be paid.

---

## 11. TRIPWIRE: **UPGRADE** — and the design question for the blind proposers

Grounds are in the VERDICT table. The question below is written to the standard
of `foz5_scout.md §4`: name the routes, the binding constraints, the
soundness-argument obligations, and what makes each route FAIL.

---

> ### DESIGN QUESTION — Bennett-57hd (for two independent proposers; do not confer)
>
> `push!`'s closed-world ROOT computes `array.ref.ptr_or_offset −
> array.ref.mem.data`, converts it to an element index with `udiv exact 8`, and
> lets that index **escape**: into a live grow-or-not branch, and into two
> closure-env slots that `_growend!` reads as an **allocation size** and a
> **memmove length**. Bennett-583s declines (the two `.data` roots are not
> syntactically equal); Bennett-foz5 §4a declines (clause (iii) — the sub's sole
> use is the `udiv`), and *correctly so*, because there is no dead-throw sink to
> confine the value into.
>
> **Design the third admission contract.** Deliver: the predicate, its exact
> soundness statement, its A-ledger of undischarged premises, its ADR text, its
> arm placement and short-circuit order, and its test plan.
>
> **The two candidate routes, both measured viable, neither dominant:**
>
> * **α — VALUE IDENTITY.** Prove the two `ptrtoint` operands are copies of one
>   pointer, so the difference is `0` in both worlds under any cell assignment
>   (583s's own proof at displacement 0). Needs a GVN-lite: aggregate-store field
>   forwarding through `insertvalue`, same-slot reload with a no-clobber scan,
>   an intrinsic write-footprint table, object disjointness.
>   **Prototyped and PROVEN on the corpus** (scout §5.2). Premises: `noalias` on
>   `gc_alloc_obj`, and the ADR-0017-item-4 intrinsic effect table (the latter
>   **measured load-bearing**, §5.3).
>   **It fails if:** you cannot answer §5.4 — α closes `%top` and **not**
>   `%L21`/`%L43`, because the `_growend!` call blocks the forward. Two walls
>   later the same shape re-walls. A proposal choosing α must either accept that
>   (and say so in the bead it files) or extend to ε.
>
> * **δ′ — SAME-MEMORYREF BASE CANCELLATION.** One provenance-pair predicate:
>   admit `sub(ptrtoint(a), ptrtoint(b))` when `a` is (an `i8`-GEP off) the
>   field-0 load of a literal `{ptr,ptr}` header `P`, and `b` is the `.data` load
>   of the `{i64,ptr}` reached through `P`'s field 1. **Measured to cover 3/3 root
>   clusters, to steal nothing from 583s, foz5 or jbko** (scout §6.2), yielding a
>   clean three-way partition of the corpus.
>   **It fails if:** (i) you cannot defend **(P-δ1)**, the MemoryRef invariant, as
>   a *language-level* premise distinct from the ABI/codegen class Rule 5 forbids —
>   and say plainly, in ADR terms, that its failure mode is a **silent wrong heap**,
>   not a halt; (ii) you do not gate on the byte tier (`_root_scale(P)[1] == 1`,
>   `_check_scale_coherence!`); (iii) you do not confront **`bennettvm-jb6w`** —
>   recognising an unnamed literal `{ptr,ptr}` as "a MemoryRef" is exactly the
>   clang-spill collision class, amplified (scout §6.4).
>
> **Also on the table, and you must dispose of each explicitly:**
> **γ** (emit a runtime check so the guarantee returns to "oracle match or loud
> halt" — γ-a synthesises CFG into the existing `:__unreachable__` sink with zero
> BVM change but a large ADR-0022/utzc/lowering blast radius; γ-b adds a BVM
> node and breaks the zero-BVM-change streak; **and neither, by itself, supplies
> oracle match** — a range/alignment check catches gross violations only);
> **ε** (discharge (P-δ1) inductively over `transitive_callees` — proves the whole
> class, at the cost of the extractor's first interprocedural analysis);
> **β** (confinement) — **already refuted**, scout §3.3/§7; a proposal that
> re-proposes it has not read the sink set.
>
> **BINDING CONSTRAINTS — a proposal violating any of these is rejected:**
>
> 1. **The composition rule (§9).** foz5 §4a's theorem is conditional on
>    "everything outside `τ` is computed by the pre-existing, already-sound
>    model". Admitting an unproved **live** value voids it, and — via
>    `arena_top` — jbko's trajectory correspondence too. Either supply oracle
>    match / a halt guarantee, or **write the downgrade of §4a and jbko into the
>    ADR explicitly**. Silence here is the failure mode this bead exists to
>    prevent.
> 2. **583s keeps first refusal** (`||` short-circuit, as foz5 arranged). Do not
>    widen `_memdata_root`: `p07_steal.jl` measured that widening steals jbko's
>    `%L84` witness and regresses the chain *behind* wall 7
>    (`instructions.jl:1554-1557`). Gate on use/provenance shape instead, so the
>    non-steal is **structural**, not accidental.
> 3. **The arm still always returns or errors.** No fall-through into the jbko
>    arm; the predicate must be **pure** in `names`/`suppressed_refs`/`dead_blocks`
>    so it may be called in both the entry and admission conditions
>    (`instructions.jl:1769-1773`).
> 4. **Nothing is fabricated** (Bennett-lbot, reaffirmed at
>    `instructions.jl:1606-1617`). The `sub`, the `udiv`, the `icmp`, the i1
>    algebra and the `br` are emitted verbatim by the ordinary paths.
> 5. **Circuit tier byte-identical.** The admission lives inside the `ptr_cells`
>    gate; `verify_reversibility` and every gate count must not move.
> 6. **Fail-loud on drift** (Rule 1). Every walker depth-bounded and
>    closure-capped in the `_FOZ5_DEPTH` / `_FOZ5_CLOSURE_CAP` idiom; any shape
>    the predicate cannot decide degrades to the **existing** loud wall.
>
> **SOUNDNESS-ARGUMENT OBLIGATIONS (deliver all four, in the arm's docstring and
> in the ADR):**
> (a) a THEOREM with an explicit **native-returns × native-throws** matrix, in the
> §4a idiom, saying what is *not* guaranteed as loudly as what is;
> (b) an **A-ledger**: every premise you decline to prove, each labelled
> *checkable* / *declared*, with the probe that shows it load-bearing (α's
> intrinsic-footprint premise is already measured — `w11_nopremise.jl`);
> (c) a **steal probe** in the `p07_steal.jl` idiom, run over both corpus bodies,
> showing the new arm claims nothing 583s / foz5 / jbko claims (scout §6.2 is the
> baseline table to reproduce);
> (d) the **wall-11 marker replacement** of scout §10.2, with the
> `new::Array.ref.mem` vs `new::Array.size_ptr` discriminator — because wall 11's
> reject text is *identical* to wall 9's, and without that discriminator the six
> markers cannot tell a wall-9 regression from wall-11 progress.
>
> **RED FIRST (CLAUDE.md §3).** `test/test_57hd_*.jl` with, at minimum: the
> corpus-shaped positive; a cross-allocation reject (two unrelated headers);
> a **C-tier** literal-`{ptr,ptr}` reject (the jb6w fixture); a
> `_root_scale != 1` reject; a `ptr_cells=false` byte-identity control; and — if
> α or ε — the `_growend!`-call-in-between fixture that must REJECT (scout §5.4),
> pinned so a later reader knows it is a scope boundary and not a bug.

---

## 12. Corrections to the bead text

* **"the difference becomes the ELEMENT INDEX and escapes into two closure-env
  stores (env+8, env+16) that `_growend!` reads"** — correct, and *understated*.
  Measured (§3.3): those slots become an **allocation size** and a **memmove
  length**. The bead's framing invites a confinement proposal; the sink set
  forbids one.
* **"Neither 583s (root equality fails — two distinct `:load` roots) …"** —
  more precisely, `_memdata_root(%7)` is **`nothing`**, not a second root: `%7`
  is a `{ptr,ptr}` field-0 load, a shape `_memdata_root` does not recognise at
  all. And the two loads *do* share a syntactic base (`%"new::Array"`), which is
  what both surviving routes exploit.
* **"wall 11 = alloca `{ptr,ptr}` silent-skip = Bennett-1zow"** (quoting the bvmd
  b05 sequence) — **measured wrong by one position**. Wall 11 is the `%L16`
  memcpy whose src is the loaded/`extractvalue` `.mem` pointer (37mt Predicate-6
  src half / Bennett-8bys, corpus site #4). The p06b `alloca {ptr,ptr}` reject is
  **wall 12**, and it is **loud**, not silent (§10.1).
* **"a THIRD contract that either proves oracle-equality for the escaping value
  or confines it some other way"** — the disjunction's second arm is **empty**
  (§3.3/§7). The real choice is *which* oracle-equality argument, and how many of
  the corpus's **three** same-shape clusters it reaches (§5.4 vs §6.2).
* The bead lists the wall-10 cluster in isolation. There are **three** in the
  root body; `%L21` and `%L43` sit two walls behind and are the same shape.

---

## CORRECTION ADDENDUM — 2026-08-07, appended by the Bennett-57hd 3+1 implementer

**Do not read §5.4, §6.2, §8, §10.1, §11 or §12's last bullet without this
section.** The scout's central framing — *"route α covers 1 of 3 corpus
clusters, route δ′ covers 3 of 3, neither dominates"* — is **WRONG**, and the
design question it produced was therefore built on a false premise. The error is
not in any measurement the scout took; it is in a measurement the scout **never
took**.

### The finding (F1), verified independently two ways during adjudication

**`%L21` and `%L43` are ALREADY ADMITTED by the shipped Bennett-foz5 §4a
contract.** They were never candidates for a third contract.

* **Predicate level.** Calling the *shipped* `_foz5_confined_dead_bounds` — with
  the real `_vec_vm_dead_blocks` set and every instruction registered in `names`
  — returns **`true` on both coercions of both clusters**. Their `sub` uses are
  `icmp ult`, i.e. §4a clause (iii) is satisfied exactly.
* **End to end.** With only the wall-10 cluster admitted (`.ll` surgery
  rewriting its two `ptrtoint`s to `add i64 0, 0`) and `%L16` removed to
  sidestep walls 11–14, the whole root extracts with **`NO WALL`**.

**Why the scout missed it.** §4 evaluates `_foz5_confined_dead_bounds` **only on
the wall-10 cluster**. §5.4 (`w13_all.jl`) and §6.2 (`w14_delta.jl`) compare the
two *prototypes* against each other and against `_memdata_root` — never against
the shipped §4a predicate. The δ′ column of §6.2's table is measured; the
missing column is the one that decides the question.

### The corrected partition

| body | cluster | 583s | foz5 §4a | needs a NEW contract |
|---|---|---|---|---|
| root | `%top` (`%memoryref_offset`) | false | **false** | **YES — and only this one** |
| root | `%L21` (`%45`) | false | **TRUE** | no |
| root | `%L43` (`%59`) | false | **TRUE** | no |
| `_growend!` | `%L46` (`%38`) | **TRUE** | TRUE | no |
| `_growend!` | `%L58` (`%46`) | **TRUE** | TRUE | no |
| `_growend!` | `%idxend41` (`%100`) | false | **TRUE** | no |

Route α therefore covers **1 of 1**, not 1 of 3. δ′'s "3 of 3" is 1 of 1 plus a
**two-cluster overlap with a shipped contract**.

### Consequences for the rest of the document

* **§5.4's "load-bearing limitation" is not load-bearing.** α's intraprocedural
  boundary at the `_growend!` call blocks nothing that needs unblocking.
* **§10.1's rows "13 / 14 — `%L21` / `%L43` — the same wall-10 message again"
  are WRONG.** Those clusters are not future walls. Measured wall sequence after
  the §4b admission: 11 = `Bennett-37mt`/`8bys` `.mem` src memcpy; 12 =
  `Bennett-p06b` `alloca { ptr, ptr }` silent-skip (LOUD — and its message does
  **not** contain the string `Bennett-1zow`, so a marker written against that
  bead tag would never fire); 13 = a second 37mt/8bys memcpy (non-integer
  element type); 14 = a `Bennett-bvmd` `SCALE-COHERENCE` violation on the 9×i64
  closure alloca.
* **§12's final bullet is withdrawn.** The bead was right to list the wall-10
  cluster in isolation.
* **§6's route δ′ was REJECTED**, not deferred: it covers nothing extra, its
  failure mode is a silently wrong heap rather than a halt, and it amplifies
  `bennettvm-jb6w` immediately before the frontier walks into wall 14, which is
  itself a jb6w-class guard. Recorded in the NON-GOAL paragraph of ADR 0017 §4b.
* One argumentative correction in the other direction, for the record: an
  overlap between `||`-disjuncts is **not** what binding constraint 2 forbids.
  583s and §4a *already* both claim `%L46` and `%L58` today, harmlessly.
  Constraint 2 forbids **widening `_memdata_root`**, which §4b does not do.

### Probes

`adj_f1.jl` (end-to-end extraction of the α-admitted, `%L16`-skipped root),
`b17_foz5_all.jl` (shipped predicates over every cluster in both bodies),
`b_alpha_skipL16.ll`, `adj_markers.jl` (the wall-11/12 message-text marker
scan), `adj_p06b.jl` (`_p06b_cell_ptr_target_kind` over every store target).
The executable form of the corrected table ships as gate **(S)** of
`test/test_57hd_value_identity.jl` — a table-shaped gate catches this class of
error and a prose claim does not.

**The methodological lesson, stated plainly for the next scout:** when you claim
a shape "needs a new contract", evaluate **every shipped contract's own
predicate** on it, not your prototypes against each other. Two of the three
clusters this bead was scoped around were never anyone's to take.

### One further correction, from implementation review

`_p06b_slot_key`'s variable-index stop rule (§4's "the canonicaliser a route-α
design would reuse") is sound as an EQUALITY key and **unsound if reused for
DISJOINTNESS**: a variable-index GEP store into a non-escaping `alloca` gets the
GEP as its footprint root, and an `:alloca` non-escape rule then calls that
write disjoint from the very object it writes. Measured ADMITTED pre-fix on a
distilled fixture. Both 3+1 proposals inherited it from the scout's prototypes.
Closed by an underlying-object walk; pinned as gate (C2). A canonicalisation
tuned for equality is not automatically valid in the other direction.
