# Bennett-p06b — Proposal A

**Decomposing a `store {ptr,ptr}` aggregate store into per-field cell stores under `ptr_cells`**

* Bead: `Bennett-p06b` (P1, IN_PROGRESS) — xkl frontier **wall 6**, extraction side
* Repo / HEAD: `Bennett.jl` @ `93ff643` (main); sister `BennettVM.jl` @ `1cf3475` (master, path-dep)
* Role: DESIGN PROPOSER A. **Design document only — no `src/` or `test/` edits were made.**
* Probes (scratchpad, prefix `pA_`), all run one-at-a-time under `--check-bounds=yes`:
  `pA_probe1.jl` (real post-pass IR dump + store census), `pA_probe2.jl` (real gated-path wall
  + set-wide dead-block-aware store census), `pA_probe3.jl` (simulated arm → next wall on the
  REAL gated path), `pA_probe4.jl` (operand provenance + alias-granularity census),
  `pA_probe5.jl` (11-fixture accept/reject matrix), `pA_probe6.jl` (BVM E2E: `lower_vm` /
  `run!` / `unrun!` / per-step inverse), `pA_probe7.jl` (message-territory: 12 at-risk test
  files re-run under the simulated arm), `pA_probe8.jl` (hazard shapes + gate-count),
  `pA_probe9.jl` (datalayout-correct mixed-width structs).
  The simulation vehicle is `pA_patchlib.jl`, which string-patches a COPY of
  `src/extract/instructions.jl` and `@eval Bennett include(...)`s it — the 7wsz/jbko
  monkey-patch convention. **No file under `src/` was modified.**

---

## 0. Summary

**Mechanism chosen: (M1), extractor-side decomposition into an already-admitted field-wise
store sequence.** Alternatives (M2) a new `IRInst`, (M3) packed-bits reuse, (M4) an
insertvalue-chain look-through are rejected with reasons in §6.

> Under `ptr_cells`, `store %S %agg, ptr %p` where `%S` is a StructType is admitted as, for
> each field `k`, the triple
>
> ```
> IRExtractValue(fk, <agg>, k, 0, N, field_widths)
> IRPtrOffset(ak, ssa(<p>), offsetof(S,k), 64)
> IRStore(ssa(ak), ssa(fk), field_widths[k+1])
> ```
>
> **iff**
>
> * **(P1)** `%S` passes `_struct_field_widths` (the Bennett-6bu3 certification: unpacked,
>   non-empty, every field a fixed-width integer in {8,16,32,64} or — under `ptr_cells` — a
>   pointer stamped 64);
> * **(P2)** `%agg` is an **`insertvalue` instruction** — the only aggregate producer BVM's
>   `agg_dests` registry certifies;
> * **(P3)** `%p` is a registered SSA name in addrspace 0 whose producer is a **certified
>   cell-pointer shape** (`load` of a pointer, a `call` returning a pointer, a
>   `getelementptr`, a pointer `Argument`, or an `alloca` the extractor actually models);
> * **(P4)** every field's byte offset from `LLVMOffsetOfElement` is **8-byte (cell) aligned**;
> * **(P5)** `%S` is **not** the literal `{i64,ptr}` GenericMemory header (the CW-D4 / 9n3y
>   byte-granular type — deferred, see §4.4).
>
> Anything else keeps failing loud, with a `Bennett-p06b`-named message.

The construct admitted is *semantically identical to a construct the extractor already
admits*: the field-wise spelling

```llvm
%fk = extractvalue %S %agg, k                    ; Bennett-6bu3 arm, instructions.jl:3480-3486
%ak = getelementptr %S, ptr %p, i32 0, i32 k     ; BVM ADR 0020 D4 arm, instructions.jl:4007-4049
store <Tk> %fk, ptr %ak                          ; Bennett-ares/beaw arm, instructions.jl:4593-4604
```

p06b emits **exactly those three instruction kinds, with exactly those parameters**. It
introduces no new `IRInst` type, no new BVM opcode, and no new emission vocabulary. Like
jbko before it, p06b is a **representation normalisation of an already-admitted operation**,
not a new semantic capability. And the corpus proves the normalisation is the right one: the
very same object `%1` is *read back* through exactly those two `{ptr,ptr}` two-index GEPs in
`%L84` (§3.2, probe 4) — the cells the decomposition writes are provably the cells the
existing GEP arm reads.

### Ground-truth findings (all measured; transcripts in §9)

| # | Finding |
|---|---|
| **F1** | **The bead's "TWO live aggregate stores at L93" is WRONG for the pipeline the converter actually walks.** Pre-SROA there are two (`ptr %2`, `ptr %0`); the converter auto-prepends `["sroa","mem2reg"]` when `_module_has_sret` (entry.jl:104-108), and SROA decomposes the second (the sret staging alloca) into `extractvalue` ×2 + two `store ptr` that the ares/beaw arm ALREADY admits. **Post-pass there is exactly ONE live `store {ptr,ptr}`.** jbko proposal_B's "×2" was read off the RAW dump. |
| **F2** | The other two `store {ptr,ptr}` in the closure (`%oob`, `%oob36`) are in `unreachable`-terminated blocks and are pruned by Bennett-utzc before conversion. The `[1 x ptr]` ArrayType stores (`%L90`, `%L96`) likewise. **No ArrayType aggregate store is live** ⇒ p06b does not need an array arm. |
| **F3** | The store target `%1 = load ptr, ptr %0` (`%0 = gep i8, %".roots.#self#", 0`) has **exactly four uses**: the write barrier (dropped, 416r.12), the aggregate store itself, and TWO word-granular two-index `{ptr,ptr}` GEPs (fields 0 and 1). **The alias-granularity question is closed by measurement, not assumption.** |
| **F4** | **The mechanism clears the wall on the REAL gated path.** With the simulated arm the closure and the full closed-world set both advance past `%L93` and die at `%idxend41`: `%94 = ptrtoint ptr %memory_data53 to i64` → **Bennett-583s** — i.e. **Bennett-foz5**, wall 7, already filed. Verified on BOTH entry points at `ptr_cells=true`. |
| **F5** | **BVM src changes: ZERO** (sixth bead in a row). `IRExtractValue` → slot copy (`ingest.jl:735-800`), `IRPtrOffset` → `Define(dest, base, :add, off÷ew_bytes)` (`ingest_body.jl:478-537`), `IRStore` → `MemoryStore` (`ingest_body.jl:171-185`). Proven E2E: extract → `lower_vm` → `run!` → `:halted` with the oracle → `unrun!` exact + drained history, under L2 and L3, plus `per_step_inverse_check` at K ∈ {1,4}. |
| **F6** | **Message territory, MEASURED** (probe 7): of the 12 test files that pin `Bennett-lgzx`/`U114`/`store of non-integer type`, **nine stay green** (their pins are all at `ptr_cells=false`) and **exactly three go red** — `test_7wsz` gate (J), `test_40ys` gate (I), `test_vau9` gate (g), 2 assertions each. **All three markers track this time** (jbko had only one). |
| **F7** | The failing assertion in all three is the same pair: the blanket negative `@test !occursin("ptrtoint", msg)` (the new wall IS a ptrtoint reject) and the lgzx positive disjunction. The advance must **replace** the blanket ptrtoint negative with `Bennett-iwo9`-scoped + `Bennett-jbko`-scoped negatives and add `Bennett-lgzx` / `store of non-integer type` as the NEW load-bearing negatives. §8 (5). |
| **F8** | **A real hazard the naive `haskey(names, ptr.ref)` guard admits:** `alloca {ptr,ptr}` (StructType allocated type) is **silently skipped** by the alloca arm (`instructions.jl:4671`, `elem_ty isa IntegerType \|\| return nothing`) **while the dest name is still registered** — so a naive p06b arm emits `IRPtrOffset`/`IRStore` against a cell no `IRAlloca` ever reserved (probe 8, fixture H3: measured ACCEPT with **no `IRAlloca(:ps,…)` in the output**). (P3)'s positive target whitelist exists to close this. The underlying silent skip is a pre-existing CLAUDE.md §1 violation and gets its own bead. |
| **F9** | `test_59zi`'s `U114` pin is in the check-bounds `else` branch that Bennett-gsjx already records as unreachable dead code; probe 7 confirms `test_59zi` 547/547 green under the simulated arm. It is NOT message territory p06b has to move. |

---

## 1. Wall verification

### 1.1 How the IR was obtained (Rule 5 / the 3vf2 lesson)

Every claim below is measured on the module the converter actually walks:
`_code_llvm_by_sig(sig; optimize=false, dump_module=true, debuginfo=:none)`
(`src/extract/sig_llvm.jl:163`) followed by the `["sroa","mem2reg"]` prepend that
`_module_has_sret(mod)` triggers at `src/extract/entry.jl:104-108`. `pA_probe1.jl` reproduces
that pipeline verbatim and writes `pA_growend_raw.ll` / `pA_growend_post.ll`.

```
callees: 4
INSTANCELESS key = Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64, Int64,
                   Int64, Int64, Int64, Memory{Int64}, MemoryRef{Int64}}
raw length = 29811
effective passes = ["sroa", "mem2reg"]
entry fn = julia_#_growend!##0_1138
```

### 1.2 The wall block, verbatim (post-pass — the walked form)

```llvm
L93:                                              ; preds = %L84
  store { ptr, ptr } %memory_ref15, ptr %1, align 8          ; <-- THE WALL
  call void (ptr, ...) @julia.write_barrier(ptr %1, ptr %memoryref_mem)
  %memory_ref15.fca.0.extract = extractvalue { ptr, ptr } %memory_ref15, 0
  %memory_ref15.fca.1.extract = extractvalue { ptr, ptr } %memory_ref15, 1
  %70 = getelementptr inbounds i8, ptr %sret_return, i32 0
  store ptr %memory_ref15.fca.0.extract, ptr %70, align 8    ; already admitted (ares)
  %71 = getelementptr inbounds i8, ptr %return_roots, i32 0
  store ptr %memory_ref15.fca.1.extract, ptr %71, align 8    ; already admitted (ares)
  %72 = getelementptr inbounds i8, ptr %sret_return, i32 8
  store i64 -1, ptr %72, align 8                             ; already admitted (integer)
  ret void
```

**This is finding F1 in one screen.** The bead (and jbko proposal_B §7.3) describe L93 as
carrying **two** live `store {ptr,ptr}`. That is the **raw** (pre-pass) form:

```llvm
L93:                                              ; preds = %L84   [RAW, pA_growend_raw.ll:229-242]
  store { ptr, ptr } %memory_ref15, ptr %2, align 8
  call void (ptr, ...) @julia.write_barrier(ptr %2, ptr %memoryref_mem)
  store { ptr, ptr } %memory_ref15, ptr %0, align 8        ; <-- the sret STAGING alloca
  %71 = getelementptr inbounds i8, ptr %0, i32 0
  %72 = getelementptr inbounds i8, ptr %sret_return, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %72, ptr align 8 %71, i64 8, i1 false)
  ...
```

SROA eliminates the `%0` staging alloca (and the 8-byte memcpy with it). **Only the heap
write survives.** This matters for scope: p06b needs ONE arm for ONE live shape, and the
"reassembly" half of the problem was already solved by the pass pipeline the extractor
prepends. The implementer must not size the work off the raw dump.

### 1.3 Full, dead-block-aware store census of the closed-world set (probe 2)

```
=== callee Base.var"#_growend!##0#…"  (instanceless) ===
ARRAY   dead=true   blk=L90     store [1 x ptr] %68, ptr %"box::ConcurrencyViolationError21"
STRUCT  dead=FALSE  blk=L93     store { ptr, ptr } %memory_ref15, ptr %1          <-- THE WALL
PTR     dead=false  blk=L93     store ptr %memory_ref15.fca.0.extract, ptr %70
PTR     dead=false  blk=L93     store ptr %memory_ref15.fca.1.extract, ptr %71
INT     dead=false  blk=L93     store i64 -1, ptr %72
ARRAY   dead=true   blk=L96     store [1 x ptr] %73, ptr %"box::ConcurrencyViolationError"
STRUCT  dead=true   blk=oob     store { ptr, ptr } %memory_ref, ptr %"box::GenericMemoryRef"
STRUCT  dead=true   blk=oob36   store { ptr, ptr } %memory_ref15, ptr %"box::GenericMemoryRef40"
PTR     dead=true   blk=oob57   store atomic ptr %memoryref_mem44, ptr %101 unordered
INT     dead=false  blk=pass82  store i64 %121, ptr %130
=== callee Type{ConcurrencyViolationError} (constructor) ===
PTR     dead=false  blk=top     store ptr %"msg::String", ptr %1
=== callee typeof(Core.throw_inexacterror) (singleton) ===   (none)
```

Exactly **one live aggregate store in the whole set** (F1), and **no live ArrayType aggregate
store** (F2) — the `[1 x ptr]` boxes are in utzc-pruned throw blocks.

### 1.4 Provenance of the two operands (probe 4)

```
TARGET  %ptr def   = %1 = load ptr, ptr %0, align 8
AGG     %val def   = %memory_ref15 = insertvalue { ptr, ptr } %81, ptr %memoryref_mem, 1
struct: literal=true packed=false genericmemory_header=false
  field 0 ty=ptr offsetof=0
  field 1 ty=ptr offsetof=8
  storesize=16 abisize=16
```

* **Target `%1`** — a `load ptr` off the GC-roots array (`%0 = getelementptr inbounds i8,
  ptr %".roots.#self#", i32 0`). Under `ptr_cells` a `load` with a `PointerType` result is
  `IRLoad(dest, …, 64)` — one cell holding an arena address (the Bennett-ares arm,
  `instructions.jl` load section). It is a **registered SSA name**, and it is the same source
  kind jbko's `_jbko_cell_ptr_src_kind` certifies as `:load` (`instructions.jl:413-414`).
* **Value `%memory_ref15`** — the tail of an `insertvalue` chain built in `%idxend`:
  `%81 = insertvalue {ptr,ptr} zeroinitializer, ptr %memoryref_data24, 0` then
  `%memory_ref15 = insertvalue {ptr,ptr} %81, ptr %memoryref_mem, 1`. Both convert through
  the Bennett-6bu3 StructType arm (`instructions.jl:3508-3517`) to
  `IRInsertValue(dest, …, 0, 2, [64,64])`. So the aggregate is a **real in-model slot family**
  — exactly what BVM's `agg_dests` membership guard (`ingest.jl:783-793`) requires.

### 1.5 What rejects it today, predicate by predicate

`_convert_instruction`'s store arm opens at `src/extract/instructions.jl:4552`. Walking it
with `ptr_cells=true`, `vt = LLVM.StructType({ptr,ptr})`:

| line | predicate | outcome on our store |
|---|---|---|
| 4565 | `LLVMGetVolatile(inst) == 0` | passes (not volatile) |
| 4567-4574 | `ptr_cells` ⇒ `_vm_relaxable_ordering(ordering)` | passes (`NotAtomic`) |
| **4593** | `ptr_cells && vt isa LLVM.PointerType` | **FALSE** — `vt` is a `StructType`, so the Bennett-ares/beaw pointer-cell arm at 4593-4604 is skipped |
| **4608-4611** | `vt isa LLVM.IntegerType \|\| _ir_error(...)` | **FIRES** — the Bennett-lgzx / U114 fail-loud |

Measured on the real gated path (probe 2, `extract_parsed_ir_set_from_julia(_pushp06b,
Tuple{Int64}; ptr_cells=true)`):

```
SET WALL: julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
  `#_growend!##0#a7027856` … — ir_extract.jl: store in @julia_#_growend!##0_1056:%L93:
  store { ptr, ptr } %memory_ref15, ptr %1, align 8 — store of non-integer type
  LLVM.StructType({ ptr, ptr }) not supported (Bennett-lgzx / U114). SoftFloat dispatch
  should reroute Float64 stores to integer wrappers before extraction.
```

Note what the rejecting predicate is **not**: it is not a soundness check. It is a
`vt isa IntegerType` type test written when the only stores in scope were scalar integers.
Everything the aggregate store needs — the field layout, the field values, the cell
addressing — is already modelled elsewhere in the file. That is the whole shape of this bead.

---

## 2. Mechanism

### 2.1 Placement in the handler cascade

**One new arm, inserted at `src/extract/instructions.jl:4605`** — i.e. **between** the end of
the Bennett-ares/beaw pointer-cell arm (`:4604`) and the Bennett-lgzx `vt isa IntegerType`
reject (`:4605-4611`). Rationale:

* It must be **after** the pointer arm: a `PointerType` value type is not a `StructType`, so
  the two are disjoint, but keeping the corpus-ordered cascade (scalar ptr → aggregate →
  integer) makes the arm read as "the next widening", which is what it is.
* It must be **before** the `vt isa IntegerType` reject, which is the unconditional throw the
  aggregate store currently hits.
* It sits **inside** the store arm's existing `ptr_cells`-agnostic body but is itself gated on
  `ptr_cells &&`. With `ptr_cells=false` there is no arm at all and control falls to the
  byte-identical lgzx reject (§4).

**Two new helpers**, placed immediately after `_struct_field_widths` ends at
`instructions.jl:92` — adjacent to the 6bu3 certification they extend, mirroring the way
jbko put `_jbko_cell_ptr_src_kind` next to the 583s provenance helpers:

* `_p06b_cell_ptr_target_kind(v, ptr_cells) -> Symbol` — (P3), the positive target whitelist.
* `_p06b_agg_producer_ok(v) -> Bool` — (P2), the aggregate producer certification.

Plus **one behaviour-preserving extraction**: the alloca arm's "is this allocated type
modelled?" test becomes a named predicate `_alloca_type_is_modelled(elem_ty, ptr_cells)`
called from BOTH `instructions.jl:4641/4660/4671` and `_p06b_cell_ptr_target_kind`. See §7 R5
for why the alternative (a mirrored copy) is worse.

### 2.2 The certified shape — and why this scope

**(P1) The struct type — reuse `_struct_field_widths`, add nothing.**
`_struct_field_widths(vt, inst, ptr_cells)` (`instructions.jl:55-92`) is the *existing* 6bu3
certification used by `insertvalue`/`extractvalue`. Calling it here means p06b inherits its
entire reject surface verbatim: packed structs (`:57-60`), empty structs (`:62-64`), integer
widths outside {8,16,32,64} — **including the load-bearing i1 reject** that keeps
`{i64,i1}` overflow/cmpxchg results out (`:69-73`), pointer fields without `ptr_cells`
(`:76-80`), and float / nested-struct / vector / array fields (`:83-88`). **p06b therefore
opens NO new field-type message territory**: every field-shape reject is a 6bu3 message that
existing tests already pin. Measured (probe 5): `{i64,i1}` → 6bu3 i1 reject; `<{ptr,ptr}>` →
6bu3 packed reject; `{ {ptr,ptr}, ptr }` → 6bu3 nested reject. All four unchanged at both
gate values.

**Scope decision: general N-field structs, not "exactly 2 ptr fields".** The bead asks the
question explicitly. I choose the general form, for three reasons:

1. *It is not actually more code.* `_struct_field_widths` already returns an N-vector; the arm
   is a `for k in 0:N-1` loop either way. A `length(fw) == 2 && all(==(64), fw)` guard would be
   **extra** code that adds a reject with **new** message territory, for no soundness gain.
2. *The soundness argument is per-field and does not depend on N* (§3). Each field is an
   independent, cell-aligned, in-model value written to an independently-addressed cell.
3. *The narrow guard would not be the binding constraint anyway.* The binding constraints are
   (P4) cell alignment and (P1) field certification, both of which are needed regardless. A
   `{ptr,ptr}`-only guard would be decoration that a future widening deletes without adding a
   fixture — the worst kind of guard (cf. jbko R4: a guard is only worth having if a mutation
   test can prove it load-bearing).

Measured N-field behaviour (probe 9, explicit `target datalayout`): `{ptr, ptr, i64}` →
three triples at offsets 0/8/16; `{i8, i64}` → widths [8,64] at offsets 0/8; `{i32,i32}` →
REJECT at (P4).

**(P2) The aggregate value must be an `insertvalue` instruction.** This is the p06b analogue
of jbko's (P2) positive source whitelist, and it is **forced by BVM's own contract**:
`ingest.jl:783-793` fails loud unless `IRExtractValue.agg` names a value in `agg_dests`, which
is populated **only** from `IRInsertValue.dest`. Any other aggregate producer is either:

* already loud upstream — a struct-typed `phi` reaches `_type_width` and hits
  **Bennett-qmk6 / U82** (`"StructType … reached scalar _type_width"`, probe 5 fixture G8); a
  struct-returning `call` hits the ADR 0020 D5 chunk-C return-type reject (probe 8 fixture H2);
* or **silently skipped with the name still registered** — `load {ptr,ptr}` (probe 8 fixture
  H1). Without (P2), that would emit an `IRExtractValue` against a never-built slot family:
  loud at BVM lower time rather than silent, but loud *in the wrong repo, with the wrong bead
  name*. Rule 1 says fail at the earliest point that knows why.
* or a constant — `store {ptr,ptr} zeroinitializer, ptr %p` (probe 5 fixture G9) rejects,
  since a `ConstantAggregateZero` is not an `insertvalue`. Admitting it (as N `iconst(0)`
  stores) is a plausible future widening with a real corpus need; it has none today, so it
  gets a bead, not an arm.

**(P3) The target pointer must be a *certified cell pointer*, not merely a registered name.**
This is where the naive form of the arm is unsound, and finding F8 is the proof. The existing
scalar `store ptr` arm at `:4593-4597` only asks `haskey(names, ptr.ref)`, which is
sufficient *there* because its targets in the C corpus are allocas the extractor models. It is
**not** sufficient for an aggregate store, because the natural LLVM target for one is
`alloca {ptr,ptr}` — and the alloca arm **silently returns `nothing`** for a StructType
allocated type (`instructions.jl:4671`) while `module_walk` has already registered the dest
symbol. Probe 8 fixture H3 measured the consequence: ACCEPT, with `IRPtrOffset(:__v5,
SSAOperand(:ps), 0, 64)` and two `IRStore`s referring to `:ps` — and **no `IRAlloca(:ps, …)`
anywhere in the emitted IR**. That is a dangling cell reference handed to BVM.

So (P3) is a *positive* whitelist of producer kinds, each of which is certified to leave a
real cell address in `locals`:

| producer | why it is a cell | corpus / fixture |
|---|---|---|
| `load` with `PointerType` result | `IRLoad(dest, …, 64)`, Bennett-ares | **the corpus target `%1`** |
| `call` returning a pointer | `IRCall` ret_width 64 — `malloc` (D5), `julia.gc_alloc_obj` (r92o) | probe 6 E2E fixture |
| `getelementptr` | `IRPtrOffset` / `IRVarGEP`, both SSA-named cell pointers | (BVM `ingest_body.jl:499`) |
| pointer `Argument` | stamped "one VM address cell", `module_walk.jl:306` | probe 8 fixture H5 |
| `alloca` whose allocated type `_alloca_type_is_modelled` | emits a real `IRAlloca` | probe 6 |

Everything else rejects, **including `phi ptr` and `select ptr`**: those carry the
Bennett-cc0 M2b **width-0 sentinel** (`instructions.jl:2937`, `:2971`) with routing recorded
in `ptr_provenance` at lowering time rather than as a value. This is the same hazard class
jbko's §2.2 identifies for `ptrtoint`, and the same answer: a positive whitelist, not an
"is a pointer" test. Also required: `LLVM.addrspace(LLVM.value_type(ptr)) == 0` (the 7wsz
convention — Julia's GC-tracked addrspace 10/11 is not a flat arena cell,
`src/extract/sret.jl:239-241`).

**(P4) Every field offset must be cell-aligned.** Offsets come from
`LLVM.offsetof(datalayout, st, k)` → `LLVMOffsetOfElement` — the dv1z/7wsz discipline, never
IR-text parsing, never `index * width` (`src/extract/sret.jl:185`,
`instructions.jl:3995`). The guard `offset_bytes % 8 == 0` is **verbatim the guard the D4
struct-GEP arm already applies** (`instructions.jl:4028-4033`): "the BVM cell discipline
(ADR 0018) requires every struct member to land on a 64-bit cell boundary". Without it,
`{i32,i32}` would decompose into two cell stores where native writes one 8-byte word — two
cells for one word, a silent miscompile. Probe 9 measures the reject.

*Implementer gotcha (probe 9):* a hand-written `.ll` with **no** `target datalayout` gets
LLVM's default layout, in which `i64` has ABI alignment **4** — so `{i8,i64}` lands field 1 at
offset **4** and (P4) rejects it. Fixtures that mean to exercise the Julia layout **must**
declare a datalayout (`"e-p:64:64:64-i64:64-n8:16:32:64-S128"` works; the long x86-64 string
with `p270:0:32` is rejected by this LLVM as "Invalid pointer size of 0 bytes").

**(P5) The GenericMemory header `{i64,ptr}` is REJECTED, deliberately.** `IRPtrOffset` carries
`(offset_bytes, elem_width)` and BVM recovers the cell as `offset_bytes ÷ (elem_width÷8)`
(`ingest_body.jl:530-537`). The D4 GEP arm stamps `elem_width = 8` — **byte** granularity —
for exactly one type, the literal `{i64,ptr}` GenericMemory header, because that field is read
through *both* a word-shaped field-1 GEP and a byte-shaped `gep i8, %m, 8`
(`instructions.jl:4034-4048`, CW-D4 / bennettvm-9n3y). Any p06b arm MUST agree with whatever
the GEP arm does for the same struct, or the store and the load land on different cells.
Two ways to agree:

* mirror the stamp (`ew = _is_genericmemory_header_struct(vt) ? 8 : 64`) — measured working in
  probe 5 (fixture G3 ACCEPTs); **or**
* refuse the header outright and stamp 64 unconditionally.

I choose **refuse**. There is no live `store {i64,ptr}` in the corpus (§1.3), a whole-header
aggregate store additionally interacts with the 416r.13 singleton-header model that p06b has
not verified, and Rule 1 prefers a conservative loud reject to an unverified admission
(jbko's §2.2 reasoning verbatim). The reject message must **name the byte-granularity reason**
so the future widener knows which stamp to use. Bead filed (§8 (8)).

### 2.3 The emitted sequence, exactly

```julia
# instructions.jl:4605  — Bennett-p06b / CW-D: aggregate store → per-field cell stores
if ptr_cells && vt isa LLVM.StructType
    # (P5) then (P1): reject the byte-granular header, then certify the field layout.
    _is_genericmemory_header_struct(vt) && _ir_error(inst, "…p06b (P5)…")
    fw = _struct_field_widths(vt, inst, ptr_cells)              # 6bu3 reject surface, reused
    # (P2) the aggregate must be an in-model insertvalue slot family.
    _p06b_agg_producer_ok(val) || _ir_error(inst, "…p06b (P2)…")
    # (P3) the target must be a certified cell pointer, addrspace 0, registered.
    tk = _p06b_cell_ptr_target_kind(ptr, ptr_cells)
    (tk !== :none && haskey(names, ptr.ref)) || _ir_error(inst, "…p06b (P3)…")
    dl  = LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(inst))))
    out = IRInst[]
    for k in 0:(length(fw) - 1)
        off = Int(LLVM.offsetof(dl, vt, k))                     # LLVMOffsetOfElement
        off % 8 == 0 || _ir_error(inst, "…p06b (P4)…")          # cell discipline, cf. D4
        fname = _auto_name(counter)
        push!(out, IRExtractValue(fname, _operand(val, names), k, 0, length(fw), fw))
        aname = _auto_name(counter)
        push!(out, IRPtrOffset(aname, ssa(names[ptr.ref]), off, 64))
        push!(out, IRStore(ssa(aname), ssa(fname), fw[k + 1]))
    end
    return out
end
```

Notes on the constructors:

* `IRExtractValue(dest, agg, index, elem_width=0, n_elems=N, field_widths=fw)` — the 6bu3
  StructType discriminator: `elem_width == 0` sentinel, `n_elems == length(field_widths)`
  (`src/ir_types.jl:363-383`). This is byte-identical in *form* to what the `extractvalue` arm
  emits at `instructions.jl:3485-3486`.
* `IRPtrOffset(dest, base, offset_bytes, elem_width=64)` — byte-valued offset plus the
  Bennett-xv0u element-width field, byte-identical in form to the D4 arm's emission at
  `instructions.jl:4049`. **Field 0 gets `IRPtrOffset(…, 0, 64)`, not a bare base alias** — a
  zero-offset `IRPtrOffset` is exactly what the D4 arm emits for `…, i32 0, i32 0`
  (measured: `%57` in `%L84`), so uniformity here *is* the consistency argument. BVM lowers it
  to `Define(dest, base, :add, 0)`.
* `IRStore(ptr, val, width)` — `width` is the field width from `fw`, matching what the scalar
  store arm passes (`LLVM.width(vt)` for integers, 64 for pointer cells). BVM's `MemoryStore`
  ignores the width (whole-cell write, `ingest_body.jl:185`); the width is carried for the
  circuit backend and for narrowing (`src/narrow.jl`).
* `_auto_name(counter)` (`src/extract/callees.jl:165-168`) produces `__vN`. Multi-instruction
  returns from `_convert_instruction` are the established convention (e.g. the fcmp arm,
  `instructions.jl:4526-4529`).

### 2.4 SSA naming: how the field values are obtained

The bead asks this directly. **The field values are obtained by emitting our own
`IRExtractValue` per field — we do not look through the producer.**

The corpus makes the temptation concrete: `%L93` *already contains*
`%memory_ref15.fca.0.extract` and `%memory_ref15.fca.1.extract` (SROA created them for the
sret half), and `%memory_ref15` is *itself* an `insertvalue` chain whose inserted values
(`%memoryref_data24`, `%memoryref_mem`) are already in `names`. Either could be reused. Both
are rejected:

* Reusing the sibling `.fca.N.extract` values is **name-pattern matching on incidental SROA
  output** — a Rule 5 violation whose failure mode is a silent non-match on the next LLVM
  release.
* Walking the `insertvalue` chain (§6, M4) is structural but partial: a chain need not be
  complete (`insertvalue` of a `phi`-carried aggregate), and re-deriving the "current" value of
  field k requires a lattice walk the extractor does not have.

Emitting `IRExtractValue` costs N extra `Define`s (pure, non-destructive, reversible by the
standard L2/L3 machinery) and is **exactly** the instruction the extractor would have emitted
had codegen spelled the store field-wise. Measured emission, probe 6:

```
Bennett.IRInsertValue(:a0,  ZeroAggSentinel(), SSAOperand(:buf), 0, 0, 2, [64, 64])
Bennett.IRInsertValue(:ref, SSAOperand(:a0),   SSAOperand(:alt), 1, 0, 2, [64, 64])
Bennett.IRExtractValue(:__v5, SSAOperand(:ref), 0, 0, 2, [64, 64])     <-- p06b
Bennett.IRPtrOffset(:__v6, SSAOperand(:slot), 0, 64)                   <-- p06b
Bennett.IRStore(SSAOperand(:__v6), SSAOperand(:__v5), 64)              <-- p06b
Bennett.IRExtractValue(:__v7, SSAOperand(:ref), 1, 0, 2, [64, 64])     <-- p06b
Bennett.IRPtrOffset(:__v8, SSAOperand(:slot), 8, 64)                   <-- p06b
Bennett.IRStore(SSAOperand(:__v8), SSAOperand(:__v7), 64)              <-- p06b
Bennett.IRPtrOffset(:f0, SSAOperand(:slot), 0, 64)     <-- the PRE-EXISTING D4 GEP arm
Bennett.IRPtrOffset(:f1, SSAOperand(:slot), 8, 64)     <-- ... identical parameters
```

The last two lines are the point: the cells p06b writes are literally the cells the existing
GEP arm addresses, with the same `(offset_bytes, elem_width)` pair.

---

## 3. Soundness (the klgz determinism obligation)

*This section is written to be pasted, near-verbatim, into the arm's comment block.*

> ### Why decomposing an aggregate store is exact under the arena model
>
> **The representation.** Under `ptr_cells` a pointer is not a host address; it is one Int64
> **VM cell value** (ADR 0018 §A) handed out by BennettVM's deterministic, injective bump
> allocator. Write `φ : native address ↦ VM cell value` for that (injective) representation
> map, and let `κ(p, off) = φ(p) + off÷8` be the cell the model assigns to byte offset `off`
> from pointer `p` under the word-granular stamp. The oracle-match obligation is that every
> admitted construct commutes with `φ`.
>
> **The theorem.** For an unpacked StructType `S` with fields `T₀…T_{N-1}` at byte offsets
> `o₀…o_{N-1}`, LLVM's `store S %agg, ptr %p` is *defined* to be the field-wise sequence
> `store Tₖ (extractvalue %agg, k), (getelementptr S, ptr %p, 0, k)` for every `k`, together
> with an unspecified write to the padding bytes. p06b emits exactly that sequence, so the
> decomposition is **exact on the fields** by LLVM's own semantics. Three conditions make it
> exact **in the cell model** as well:
>
> 1. **Every field gets its own cell, and the right one.** (P4) requires `oₖ % 8 == 0`, so
>    `κ(p, oₖ) = φ(p) + oₖ÷8` is an integer cell index, and distinct fields of an unpacked
>    struct with cell-aligned offsets occupy distinct cells (offsets are strictly increasing
>    and 8-separated). No two field stores alias.
> 2. **The cells agree with every other way the object is addressed.** The only other
>    admitted addressing of a struct-typed object is the D4 two-index GEP, which emits
>    `IRPtrOffset(base, LLVMOffsetOfElement(S,k), ew)` with the **same** `LLVMOffsetOfElement`
>    call and the same `ew`. p06b copies the D4 stamp exactly, and (P5) removes the one type
>    (`{i64,ptr}`) where D4 uses a different (byte) granularity. **This is measured on the
>    corpus, not assumed**: probe 4 shows the store target `%1` has exactly two other uses,
>    both `getelementptr inbounds {ptr,ptr}, ptr %1, i32 0, i32 {0,1}` in `%L84`, i.e. cells
>    `φ(%1)+0` and `φ(%1)+1` — the two cells the decomposition writes.
> 3. **Padding is not observable.** The bytes the native store writes into inter-field padding
>    are `undef` in LLVM's own model. Under the cell model no admitted GEP can name them:
>    D4 rejects a member at a non-cell-aligned offset (`:4028-4033`), and a whole-cell
>    `MemoryStore` overwrites the cell a field owns, which is the only cell that field's value
>    can be read from. (The residual two-granularity hazard — a byte-shaped `gep i8` on the
>    same object mapping to a *different* cell than the word-shaped GEP — is
>    **bennettvm-jb6w**, pre-existing, shared verbatim with the D4 arm, and not widened by
>    p06b; §7 R3.)
>
> **Determinism.** Nothing in the decomposition introduces a value that is not already in the
> model. The field values are `extractvalue` slot copies of an `insertvalue`-built family
> ((P2)); the addresses are constant offsets from a cell pointer ((P3)); the widths come from
> the datalayout. For a fixed program and fixed inputs, every cell written is a pure function
> of the execution trajectory, exactly as before. **p06b adds no expressive power over the
> field-wise spelling the extractor already admits** — it only lets that spelling be written
> as one LLVM instruction.
>
> **Reversibility.** All three emitted instruction kinds already reverse: `IRExtractValue` →
> `Define` (non-destructive slot copy), `IRPtrOffset` → `Define(dest, base, :add, idx)`,
> `IRStore` → `MemoryStore` (the L2/L3-logged heap write). Measured: exact `unrun!` with a
> drained history under both regimes, and `per_step_inverse_check` green at K ∈ {1,4} (§9.5).

### 3.1 Interaction with `ptr_provenance` / the width-0 sentinels

Bennett-cc0 M2b gives pointer-typed `phi` and `select` a **width-0 sentinel**
(`instructions.jl:2937`, `:2971`) with routing recorded in `ptr_provenance` at lowering time.
Two places this could bite p06b, and how each is closed:

* **A phi/select-carried TARGET.** Closed by (P3): the whitelist admits `load` / `call` /
  `getelementptr` / `Argument` / modelled-`alloca` producers only. A `phi ptr` target would
  make `IRPtrOffset`'s base a value that was never materialised as a cell.
* **A phi/select-carried FIELD VALUE.** *Cannot arise.* A field value reaches p06b only
  through `IRExtractValue` of an `insertvalue`-built family ((P2)), and the corresponding
  `IRInsertValue` was itself emitted by the 6bu3 arm, which stamps every pointer field at
  width **64** via `_struct_field_widths` (`:75-81`) — a real value, not a sentinel. If the
  *inserted* operand were a `phi ptr`, the failure is at the `insertvalue`, upstream of p06b,
  and is pre-existing.
* **A phi/select-carried AGGREGATE.** Rejected twice over: the struct `phi` itself fails loud
  at `_type_width` (**Bennett-qmk6 / U82**, measured probe 5 G8), and (P2) would reject it
  anyway.

`synth_ptr_provenance` (the dv1z sret machinery) is untouched: p06b emits no sret write and
does not participate in the sret pre-walk.

---

## 4. Failure modes — what must KEEP rejecting

### 4.1 The reject matrix (all measured, probe 5 / 8 / 9)

| # | shape | disposition | message names |
|---|---|---|---|
| 1 | `store [2 x ptr] %a, ptr %p` (ArrayType aggregate) | REJECT, **both gates** | `Bennett-lgzx / U114` (unchanged — the arm is `StructType`-only) |
| 2 | `store {i64,i1}` | REJECT | **Bennett-6bu3** i1 field reject |
| 3 | `store <{ptr,ptr}>` (packed) | REJECT | **Bennett-6bu3** packed reject |
| 4 | `store { {ptr,ptr}, ptr }` (nested) | REJECT | **Bennett-6bu3** unsupported field type |
| 5 | `store {}` (empty struct) | REJECT | **Bennett-6bu3** empty struct |
| 6 | `store {i32,i32}` (field 1 at offset 4) | REJECT | **Bennett-p06b (P4)** cell alignment |
| 7 | `store {i64,ptr}` (GenericMemory header) | REJECT | **Bennett-p06b (P5)** byte-granularity |
| 8 | aggregate is a `phi {ptr,ptr}` | REJECT (upstream) | **Bennett-qmk6 / U82** `_type_width` |
| 9 | aggregate is `load {ptr,ptr}` | REJECT | **Bennett-p06b (P2)** |
| 10 | aggregate is a struct-returning `call` | REJECT (upstream) | **ADR 0020 D5 / chunk C** |
| 11 | aggregate is `zeroinitializer` | REJECT | **Bennett-p06b (P2)** |
| 12 | target is a global / ConstantExpr / alias | REJECT | **Bennett-p06b (P3)**, retaining `Bennett-lgzx / U114` |
| 13 | target is `alloca {ptr,ptr}` (silent-skip hole, F8) | REJECT | **Bennett-p06b (P3)** |
| 14 | target is `phi ptr` / `select ptr` (cc0 M2b sentinel) | REJECT | **Bennett-p06b (P3)** |
| 15 | target in addrspace 10/11 | REJECT | **Bennett-p06b (P3)** (cf. 7wsz) |
| 16 | anything at all on the circuit path (`ptr_cells=false`) | REJECT | `Bennett-lgzx / U114`, **byte-identical** |
| 17 | `volatile` / strong-ordering aggregate store | REJECT | **Bennett-4mmt / U14** (guards precede the arm at `:4565`, `:4567`) |

Rows 12 and 16 are where p06b touches existing message text; everything else either names a
bead p06b does not own (6bu3, qmk6, lgzx, 4mmt) or is new p06b territory.

### 4.2 Message-territory analysis (Bennett-0ncn discipline) — MEASURED

`grep -rln "store of non-integer type\|Bennett-lgzx\|U114" test/` returns **12 files**. Probe 7
re-ran all of them (plus `test_jbko_ptr_identity_icmp.jl`) under the simulated arm, in suite
mode. Results:

| file | pins | gate | verdict |
|---|---|---|---|
| `test_lgzx_store_fail_loud.jl:37` | `Bennett-lgzx` (float store) | n/a | **4/4 green** |
| `test_haiy_ptr_cells_store_load_gep.jl:115-117, 308-309` | all three substrings | **`ptr_cells=false`** | **26/26 green** |
| `test_nd45_ptr_cells_call_emission_multifn.jl:154-155` | `U114`, `store of non-integer type` | **gate-off** | **39/39 green** |
| `test_beaw_null_ptr.jl:164` | `non-integer type` (disjunct) | `cells=false` | **16/16 green** |
| `test_utzc_dead_block_pruner.jl:265, 312-313` | negative + positive | `ptr_cells=false` (d2); dead-block (a) | **31/31 green** |
| `test_59zi_sret_call_memcpy.jl:345` | `U114` disjunct | `ptr_cells=true`, **dead branch** (Bennett-gsjx) | **547/547 green** |
| `test_d1b_julia_set.jl:165` | comment only | — | **33/34 green + 1 broken (pre-existing)** |
| `test_416r17_sret_forward_cell_args.jl:134` | comment only | — | not re-run (comment) |
| `runtests.jl:393,407,559,569,636,877` | comments only | — | comments to update |
| **`test_7wsz_ptr_sret_fields.jl:515,516`** | gate (J) | `ptr_cells=true` | **RED — 97/99** |
| **`test_40ys_instanceless_callees.jl:497,504`** | gate (I) | `ptr_cells=true` | **RED — 119/121** |
| **`test_vau9_variable_memmove.jl:274,279`** | gate (g) | `ptr_cells=true` | **RED — 61/63** |

**All three wall markers track this advance** — an improvement on jbko, where 40ys (I) and
7wsz (J) stayed green because their disjunctions already admitted the successor. The reason
they track now is the *negative* half: `@test !occursin("ptrtoint", msg)`.

**And that same negative is the one that must be retired.** The successor wall (F4) is
`Bennett-583s`, whose message contains the word `ptrtoint`. A blanket `!occursin("ptrtoint")`
is no longer expressible. The replacement negatives, per Bennett-0ncn ("design the NEXT wall's
marker so its `!occursin` negatives are the load-bearing half"):

```julia
# CLEARED by vau9 — the memmove wall
@test !occursin("memmove", msg)
@test !occursin("not yet lowered to reversible gates", msg)
# CLEARED by jbko — the %L84 identity-use ptrtoint. NARROWED from the blanket
# !occursin("ptrtoint") because the SUCCESSOR wall is itself a ptrtoint reject:
# scope the negative to the ARM that was cleared, not to the opcode.
@test !occursin("Bennett-iwo9", msg)
@test !occursin("Bennett-jbko", msg)
@test !occursin("type-tag", msg)
# CLEARED by p06b — the %L93 aggregate store. THE NEW LOAD-BEARING NEGATIVES.
@test !occursin("Bennett-lgzx", msg)
@test !occursin("U114", msg)
@test !occursin("store of non-integer type", msg)
@test !occursin("Bennett-p06b", msg)
# POSITIVE: the successor is the %idxend41 583s bounds-cluster wall (Bennett-foz5).
@test occursin("Bennett-583s", msg) ||
      occursin("base-cancelling", msg) ||
      occursin("Bennett-foz5", msg)
@test occursin("_growend!", msg)
```

Two notes for the implementer. (i) `!occursin("U114", msg)` is a **bare numeral** and
Bennett-0ncn (P3, OPEN) already flags bare `U15`/`U114` numerals as false-match-prone; prefer
the two spelled-out negatives and keep `U114` only if the orchestrator wants belt-and-braces.
(ii) The three files' comment blocks each contain a "MEASURED" paragraph naming the current
wall; those must be rewritten, not just the assertions — a stale comment is how a marker stops
being read.

### 4.3 What p06b provably cannot perturb

Every input that reaches `instructions.jl:4605` today hits the unconditional `_ir_error` two
lines later. The new arm is inserted immediately above that throw and either (a) returns a
decomposition, or (b) throws a p06b-named error, or (c) falls through unchanged (non-Struct
`vt`, or `ptr_cells=false`). **No currently-green extraction can change behaviour.** This is
the same structural argument as jbko gotcha 2 (worklog/098), and it is why the only red tests
are wall markers.

### 4.4 Circuit-path byte-identity

* The arm is inside `if ptr_cells && …`; with the gate off, control reaches the pre-existing
  lgzx reject with the identical message (probe 5: every fixture at `ptr_cells=false` rejects
  with either the lgzx text or the upstream 6bu3 text, unchanged).
* No `IRInst` type changes, no `lower.jl` changes, no `gates.jl` changes ⇒ the circuit backend
  cannot observe the diff.
* **Gate-count baseline, measured under the simulated arm** (probe 8):
  `Gate count regression baselines | 39 39 12.3s`. The implementer must reproduce **39/39**.
* Gate-witness fixture: probe 5 `G1` at `ptr_cells=false` rejects — but note it rejects
  **earlier**, at the 6bu3 pointer-field reject on the `insertvalue`, so it is *not* a witness
  that the **store arm** is gated. §8 (4) specifies a dedicated all-integer-field fixture
  (`{i64,i64}`) whose only gate-dependent construct is the aggregate store itself.

---

## 5. Test plan (RED-GREEN)

New file **`test/test_p06b_aggregate_store.jl`**, registered in `test/runtests.jl` next to the
`ptr_cells` family. Driver: the `mktempdir` + `extract_parsed_ir_from_ll(path;
entry_function=…, ptr_cells=…)` helper copied from `test_vau9_variable_memmove.jl:60-73`
(Rule 12). **Every fixture carries an explicit `target datalayout`** (probe 9 gotcha).

**RED first.** Write (a) and watch it fail with the *lgzx* message. Do not proceed until it is
red for the right reason.

1. **(a) The corpus shape → ACCEPT, asserted as VALUES.** The `{ptr,ptr}` store to a
   `load ptr` target. Assert the exact 6-instruction emission of §2.4 — both
   `IRExtractValue(_, SSAOperand(:ref), k, 0, 2, [64,64])`, both
   `IRPtrOffset(_, SSAOperand(:slot), {0,8}, 64)`, both `IRStore(_, _, 64)` — **and** that the
   downstream read-back `IRPtrOffset`s emitted by the untouched D4 arm carry the *identical*
   `(offset_bytes, elem_width)` pairs. That last assertion is the cell-agreement theorem
   (§3, condition 2) as a test.
2. **(b) N-field generality.** `{ptr,ptr,i64}` → three triples at 0/8/16 (probe 9 K3);
   `{i8,i64}` → widths `[8,64]`, `IRStore(…, 8)` on cell 0 (probe 9 K1). These are the tests a
   "restrict to exactly two ptr fields" refactor cannot pass.
3. **(c) The (P4) cell-alignment reject.** `{i32,i32}` → REJECT naming `Bennett-p06b`.
   **Mutation-provable**: deleting the `% 8 == 0` guard makes it emit two cell stores for one
   native word.
4. **(d) The (P3) whitelist — the most load-bearing tests in the file (R1).**
   * `alloca {ptr,ptr}` target → REJECT. Companion assertion that the pre-fix behaviour would
     have emitted stores against a name with **no** `IRAlloca` (finding F8). This is the test a
     "just use `haskey(names, …)`" simplification cannot pass.
   * `phi ptr` target and `select ptr` target → REJECT, with a comment stating that admitting
     them would address a cell that was never materialised (cc0 M2b width-0 sentinel).
   * global / ConstantExpr target → REJECT, message retains `Bennett-lgzx` **and** `U114`.
   * addrspace(11) target → REJECT.
   * modelled-`alloca` and pointer-`Argument` targets → ACCEPT (the whitelist is not vacuous).
5. **(e) The (P2) producer certification.** `load {ptr,ptr}` aggregate → REJECT;
   `zeroinitializer` aggregate → REJECT; struct-`phi` aggregate → REJECT naming
   `Bennett-qmk6`/`U82` (an upstream reject we must not shadow).
6. **(f) The 6bu3 reject surface is inherited unchanged.** `{i64,i1}`, `<{ptr,ptr}>`,
   `{ {ptr,ptr}, ptr }`, `{}` → REJECT, each asserting the message still names
   **`Bennett-6bu3`** (i.e. p06b did not annex their territory).
7. **(g) (P5) header reject.** `{i64,ptr}` literal → REJECT naming `Bennett-p06b` and the
   byte-granularity reason. Companion: a **named** `%struct.T = type {i64, ptr}` (non-literal)
   → ACCEPT, pinning that `_is_genericmemory_header_struct`'s literalness discriminator is the
   thing being tested (mirrors the haiy/nd45 C-tier pins).
8. **(h) ArrayType stays rejected.** `store [2 x ptr]` → REJECT at both gates with the
   **unchanged** lgzx text.
9. **(i) Gate witness.** An all-integer-field `{i64,i64}` fixture whose only
   `ptr_cells`-dependent construct is the aggregate store: ACCEPT at `true`, lgzx reject at
   `false`, same `.ll` (the vau9 one-file gate-witness convention).
10. **(j) Corpus wall-marker advance — ADVANCE, do not delete (F6/F7).** The three gates of
    §4.2, each with the negative set rewritten as shown and the comment block rewritten with
    the measured successor:

    ```
    SET WALL: … extraction FAILED for callee `#_growend!##0#a7027856` … —
      ir_extract.jl: ptrtoint in @julia_#_growend!##0_40949:%idxend41:
      %94 = ptrtoint ptr %memory_data53 to i64 — ptrtoint of a GenericMemory .data base
      under ptr_cells whose result is NOT confined to a same-Memory base-cancelling
      bounds check … (Bennett-583s / CW-D; CLAUDE.md §1).
    ```

    **Verify the marker actually tracks**: temporarily revert the negatives and confirm the
    gates would have stayed green — the jbko R6 lesson.

**BVM E2E** — new `BennettVM.jl/test/test_p06b_aggregate_store_vm.jl`, header stating **zero
BVM src changes**, following `test_jbko_ptr_identity_vm.jl` exactly:

* (1) the handoff shape: the ParsedIR BVM receives carries the six p06b instructions with the
  exact parameters, and the D4 read-back GEPs with identical parameters;
* (2) `lower_vm`: two `Define`s (slot copies), two `Define(_, base, :add, {0,1})`, two
  `MemoryStore`s;
* (3) **the store→load round trip through cells** (probe 6): the fixture writes the aggregate,
  reads both fields back through the *word-granular* GEP, compares each to the original
  pointer, and branches. Result `x+1` iff both match. **Non-vacuous**: if both fields landed in
  the same cell, last-write-wins would make field 0's comparison fail and the oracle would be
  `x+100`;
* (4) allocator injectivity pinned operationally (`buf`, `alt`, `slot` at distinct arena
  offsets 0 / 4 / 8);
* (5) `unrun!` exact + `isempty(history)` + `step_count == 0` under **L2 and L3**;
* (6) `per_step_inverse_check` at K ∈ {1,4} under both regimes.

Measured transcript in §9.5 — all of the above already passes with the simulated arm.

**Regression re-run set** (all `--check-bounds=yes`, the 2mj3/figa suite-mode rule):
`test_lgzx_store_fail_loud`, `test_haiy_ptr_cells_store_load_gep`, `test_nd45_*`,
`test_beaw_null_ptr`, `test_utzc_dead_block_pruner`, `test_59zi_sret_call_memcpy`,
`test_d1b_julia_set`, `test_7wsz_ptr_sret_fields`, `test_40ys_instanceless_callees`,
`test_vau9_variable_memmove`, `test_jbko_ptr_identity_icmp`, `test_583s_*`, `test_iwo9_*`,
`test_klgz_determinism_guard`, `test_416r*`, and `test_gate_count_regression` **which must
print 39/39**. Then full `Pkg.test()` in both repos.

---

## 6. Alternatives weighed

**(M2) A new `IRInst` — `IRAggStore(ptr, agg, field_widths, offsets)`.** Rejected. It forces a
BVM ingest arm (breaking the zero-BVM-change streak for no capability), forks every
`isa IRStore` consumer (the Law 2 / `IRCallByName` argument in `ir_types.jl:378-385`), and
gains nothing: the decomposition is *already* expressible in the existing vocabulary, and
expressing it there is what makes the cell-agreement theorem (§3.2) a syntactic identity with
the D4 arm rather than a claim about two different code paths.

**(M3) Reuse the dv1z packed-bits representation (`IRInsertBits`).** Rejected. `IRInsertBits`
packs fields at **contiguous bit offsets**, deliberately dropping padding
(`ir_types.jl:175-181`), which is the right model for an sret *value* and the wrong model for
a *memory object*: the same `{ptr,ptr}` would then be one 128-bit packed value under sret and
two cells under GEP — precisely the two-representations-for-one-object failure the CW-D4
granularity work exists to prevent.

**(M4) Look through the `insertvalue` chain and store the inserted values directly.**
Rejected. It saves N `Define`s (a rounding error) and buys a partiality problem: the chain may
start from a non-constant aggregate, may be interrupted by a `phi`, and may not define every
field. The failure mode is a *silent* wrong field value. Emitting `IRExtractValue` delegates
that question to BVM's slot model, which is total.

**(M5) Restrict to exactly-2-pointer-field literal structs.** Rejected — see §2.2. The guard
would not be mutation-provable (no fixture can show it prevents a wrong answer that (P1)+(P4)
do not already prevent), and it adds message territory that a future widening deletes.

**(M6) Admit the GenericMemory header by mirroring the byte-granular stamp.** Considered and
measured working (probe 5 G3), but **deferred** — see (P5) in §2.2. Recorded here so the
future widener knows the mechanism is one line (`ew = _is_genericmemory_header_struct(vt) ? 8
: 64`) and that the missing piece is the 416r.13 singleton-header interaction argument, not
the code.

---

## 7. Risk register

| # | Risk | Severity | Mitigation / status |
|---|---|---|---|
| **R1** | (P3)'s whitelist is the only thing standing between the arm and the `alloca {ptr,ptr}` dangling-cell hole (F8). Someone "simplifies" it to `haskey(names, …)`. | **High if it happens** | The width-0-sentinel and silent-skip rationales must be written into the helper as the *reason* for the whitelist, and §8 (4)'s reject fixtures must be committed regression tests. **Mutation-provable**: relaxing the predicate makes the `alloca {ptr,ptr}` fixture emit `IRStore` against a name with no `IRAlloca`. |
| **R2** | The `alloca {ptr,ptr}` silent skip is a live CLAUDE.md §1 violation *independent* of p06b: it registers a name and emits nothing. Some other arm may already be walking into it. | Med | Not p06b's to fix (fixing it would change gate-off behaviour). **File a P2 bead**: `alloca` with an unmodelled allocated type must fail loud, or must not register the dest. |
| **R3** | The two-granularity hazard (bennettvm-jb6w): a byte-shaped `gep i8, %obj, K` on the same object maps to cell `K`, not cell `K÷8`. | Med, **pre-existing** | Shared verbatim with the D4 GEP arm; p06b copies D4's stamp, so it cannot *widen* the hazard. (P5) removes the one type where the two granularities are known to coexist. Probe 4 shows the corpus object `%1` has **no** byte-shaped GEP use. Note it in the arm comment and on jb6w. |
| **R4** | `_struct_field_widths` does **not** check field **addrspace** — a `{ptr addrspace(10), ptr}` field is stamped 64. | Med | Pre-existing 6bu3 gap, inherited not created. p06b guards the *target*'s addrspace (P3) but must not annex 6bu3's field territory. **File a P3 bead** against 6bu3. |
| **R5** | Extracting `_alloca_type_is_modelled` out of the alloca arm touches a live arm (Rule 7 interlock). | Med | Behaviour-preserving: a pure predicate, control flow unchanged, pinned by the existing `test_haiy`/`test_nd45`/`test_munq`/`test_ixiz` alloca tests plus a new mirroring fixture per admitted/skipped allocated type. The alternative (a duplicated mirror predicate) **will** drift — that is the interlock Rule 7 actually warns about. |
| **R6** | The successor wall (Bennett-foz5) may reshape once its 583s root extension lands, invalidating the new marker positives. | Low | Positives are a disjunction (`Bennett-583s` ∨ `base-cancelling` ∨ `Bennett-foz5`); the negatives are the load-bearing half and are opcode-independent. |
| **R7** | LLVM/Julia re-emits the store differently next release (e.g. SROA also eliminates the heap store, or codegen emits two `store ptr`). | Low | Then the arm goes unused and the corpus advances anyway; unit fixtures are hand-written `.ll`, decoupled from `_growend!` (the 3vf2 convention). Only the three corpus-landing pins move. |
| **R8** | The arm reaches the circuit path. | Low | Structurally impossible (inside `&& ptr_cells`), pinned by §8 (9)'s dedicated gate witness and by gate-count 39/39 (measured under the simulated arm). |
| **R9** | `_auto_name` collisions between the 3N synthesized names and later names. | Low | `_auto_name` is the file-wide counter every multi-instruction arm uses (fcmp, memcpy, overflow fusion); measured `__v4…__v10` in probes 5/6/9 with no collision. |
| **R10** | Whole-cell `MemoryStore` semantics mean a width-8 field store zaps the whole cell. | Low | Sound because (P4) gives each field its own cell and padding is unobservable (§3, condition 3). Pinned by fixture (b) (`{i8,i64}` round trip). Escalates only if a future arm admits sub-cell fields — which (P4) forbids. |

---

## 8. Implementation checklist

1. Write `test/test_p06b_aggregate_store.jl` fixtures (a)-(i). Watch (a) go **RED** with the
   lgzx message. Do not proceed until it is red for the right reason.
2. Extract `_alloca_type_is_modelled(elem_ty, ptr_cells)` from the alloca arm
   (`instructions.jl:4641/4660/4671`); re-run the alloca test family to prove byte-identity.
3. Add `_p06b_agg_producer_ok` and `_p06b_cell_ptr_target_kind` after `_struct_field_widths`
   (`instructions.jl:92`), with §3's determinism argument as the comment header and the F8
   silent-skip rationale attached to the whitelist.
4. Add the arm at `instructions.jl:4605`, between the ares/beaw pointer arm and the lgzx
   reject. Do **not** rewrite the lgzx message; the arm returns or throws before reaching it.
5. Green (a)-(i). Confirm (c)-(g) reject and name the right bead in each case.
6. Advance the three wall markers (§4.2), rewriting both the assertions and the MEASURED
   comment paragraphs. Verify the markers would have stayed green without the change.
7. Add the BVM E2E file; confirm **zero** BVM `src/` changes.
8. Run the §5 regression set under `--check-bounds=yes`; `test_gate_count_regression` must
   print **39/39**. Then full `Pkg.test()` in both repos.
9. Worklog: prepend a session block to the highest-numbered chunk (`ls worklog/ | sort -r |
   head -1` — `098_2026-08-04_vau9_memmove_routing.md` is at 225 lines, so it may need
   chunk `099`). Record **F1** (the raw-vs-post-SROA store count — it corrects the bead and
   jbko proposal_B), **F7** (the blanket-`ptrtoint`-negative retirement), **F8** (the
   `alloca <struct>` silent-skip hole) and the probe-9 datalayout gotcha.
10. Beads: file (i) `alloca` with an unmodelled allocated type silently registers a dangling
    name (P2, R2); (ii) admit the `{i64,ptr}` GenericMemory-header aggregate store under the
    byte-granular stamp (P3, M6/P5); (iii) `_struct_field_widths` ignores field addrspace
    (P3, R4); (iv) admit `store <S> zeroinitializer` as N zero-cell stores (P3, P2). Bundle
    the dolt-cache churn into the source commit.

---

## 9. Probe transcripts

All scripts are in the session scratchpad with prefix `pA_`. Julia discipline: one process at
a time, verified clear before each run; nine runs total. No `src/` file was modified — the
simulation vehicle string-patches a **copy** and `@eval Bennett include`s it.

### 9.1 `pA_probe1.jl` / `pA_probe2.jl` — the real IR and the real wall

Reproduced in §1.1-§1.3. Block order of the post-pass closure (the order walls fire in):
`top … L81, L84, L90, L93, L96, …, oob, idxend, …, oob36, idxend41, …` — hence `%L84` (jbko,
wall 5) → `%L93` (p06b, wall 6) → `%idxend41` (foz5, wall 7).

### 9.2 `pA_probe3.jl` — the mechanism clears the wall on the REAL gated path

```
PATCH APPLIED

--- closure alone (extract_parsed_ir_by_sig, ptr_cells=true) ---
CLOSURE WALL: ir_extract.jl: ptrtoint in @julia_#_growend!##0_1849:%idxend41:
  %94 = ptrtoint ptr %memory_data53 to i64 — ptrtoint of a GenericMemory .data base
  under ptr_cells whose result is NOT confined to a same-Memory base-cancelling bounds
  check … (Bennett-583s / CW-D; CLAUDE.md §1).

--- full closed-world set (real gated path) ---
SET WALL: julia_set.jl: … extraction FAILED for callee `#_growend!##0#a7027856` … —
  ir_extract.jl: ptrtoint in @julia_#_growend!##0_40949:%idxend41:
  %94 = ptrtoint ptr %memory_data53 to i64 — … (Bennett-583s / CW-D; CLAUDE.md §1).
```

Both entry points agree, both at `ptr_cells=true` (the 7wsz lesson: an ungated forecast is
worthless). The successor is **Bennett-foz5**, already filed — its bead names
`%memoryref_data_byteoffset36` in `%idxend`; the message here names the *sibling* `%94` in
`%idxend41`. Same cluster, same root cause (`_memdata_root` returns `nothing` for the
capture-rooted half), and it confirms foz5's scope rather than adding a new wall.

### 9.3 `pA_probe4.jl` — provenance and alias granularity

Reproduced in §1.4. The decisive lines:

```
--- ALL uses of the store TARGET pointer (%1) ---
  call void (ptr, ...) @julia.write_barrier(ptr %1, ptr %memoryref_mem)   [dropped, 416r.12]
  store { ptr, ptr } %memory_ref15, ptr %1, align 8                       [THE WALL]
  %59 = getelementptr inbounds { ptr, ptr }, ptr %1, i32 0, i32 1   GEP src ty = { ptr, ptr }
  %57 = getelementptr inbounds { ptr, ptr }, ptr %1, i32 0, i32 0   GEP src ty = { ptr, ptr }
```

No byte-shaped `gep i8` on `%1`; both readers are word-granular two-index struct GEPs.

### 9.4 `pA_probe5.jl` / `pA_probe8.jl` / `pA_probe9.jl` — the decision matrix

```
G1  {ptr,ptr} benign        cells=true  → ACCEPT   (6-instruction emission, §2.4)
G1                          cells=false → REJECT   6bu3 pointer-field (upstream of the store)
G3  {i64,ptr} header        cells=true  → ACCEPT   [simulated arm had NO (P5); §2.2 rejects it]
G4  {i64,i1}                both        → REJECT   Bennett-6bu3 i1 field
G5  <{ptr,ptr}> packed      both        → REJECT   Bennett-6bu3 packed
G6  nested struct           both        → REJECT   Bennett-6bu3 unsupported field type
G7  {i32,i32}               cells=true  → REJECT   (P4) field 1 byte offset 4 not cell-aligned
G8  phi {ptr,ptr}           cells=true  → REJECT   Bennett-qmk6 / U82 (_type_width)
G9  zeroinitializer         cells=true  → REJECT   (P2)
G10 [2 x ptr]               both        → REJECT   Bennett-lgzx / U114 (UNCHANGED)
G11 global target           cells=true  → REJECT   (P3)
H1  load {ptr,ptr} agg      cells=true  → REJECT   (P2)
H2  call-returning-struct   cells=true  → REJECT   ADR 0020 D5 chunk C (upstream)
H3  alloca {ptr,ptr} target cells=true  → ACCEPT with a DANGLING :ps — finding F8, closed by (P3)
H4  {i8,i64} (no datalayout)cells=true  → REJECT   (P4) offset 4 — the datalayout gotcha
H5  ptr Argument target     cells=true  → ACCEPT
K1  {i8,i64}  (datalayout)  cells=true  → ACCEPT   widths [8,64], offsets 0/8
K2  {i32,i32} (datalayout)  cells=true  → REJECT   (P4)
K3  {ptr,ptr,i64}           cells=true  → ACCEPT   three triples at 0/8/16
Gate count regression baselines | 39  39  12.3s
```

### 9.5 `pA_probe6.jl` — BVM end-to-end, zero BVM changes

```
lower_vm OK; blocks=5
  [L2] x=0  halted=true r=1  e1=1 e2=1 buf=0 alt=4 slot=8 l0==buf:true l1==alt:true unrun_exact=true hist_empty=true
  [L2] x=7  halted=true r=8  e1=1 e2=1 buf=0 alt=4 slot=8 l0==buf:true l1==alt:true unrun_exact=true hist_empty=true
  [L2] x=-3 halted=true r=-2 e1=1 e2=1 buf=0 alt=4 slot=8 l0==buf:true l1==alt:true unrun_exact=true hist_empty=true
  [L3] x=0  halted=true r=1  … unrun_exact=true hist_empty=true
  [L3] x=7  halted=true r=8  … unrun_exact=true hist_empty=true
  [L3] x=-3 halted=true r=-2 … unrun_exact=true hist_empty=true
  per_step_inverse K=1 L3 → true      per_step_inverse K=1 L2 → true
  per_step_inverse K=4 L3 → true      per_step_inverse K=4 L2 → true
```

`l0==buf` **and** `l1==alt` simultaneously true is the non-vacuity witness: the two fields
landed in **different** cells and round-tripped through the word-granular GEP.

### 9.6 `pA_probe7.jl` — message territory, 12 files re-run under the simulated arm

```
test_lgzx_store_fail_loud                 4/4      test_59zi_sret_call_memcpy   547/547
test_haiy_ptr_cells_store_load_gep       26/26     test_d1b_julia_set            33/34 (+1 broken, pre-existing)
test_nd45_ptr_cells_call_emission_multifn 39/39    test_jbko_ptr_identity_icmp   73/73
test_beaw_null_ptr                       16/16
test_utzc_dead_block_pruner              31/31
test_7wsz_ptr_sret_fields                97/99   FAIL :515 (!occursin "ptrtoint"), :516 (lgzx disjunction)
test_40ys_instanceless_callees          119/121  FAIL :497 (!occursin "ptrtoint"), :504 (lgzx disjunction)
test_vau9_variable_memmove               61/63   FAIL :274 (!occursin "ptrtoint"), :279 (lgzx disjunction)
```

---

## 10. Estimated diff shape

*Touch points only — no time estimates (per the user's `feedback_no_time_estimates` memory).*

**`Bennett.jl/src/extract/instructions.jl`** — three edits:
* `:92+` — two new helpers (`_p06b_agg_producer_ok`, `_p06b_cell_ptr_target_kind`) plus the
  §3 determinism comment block, adjacent to `_struct_field_widths` which they extend.
  Roughly the footprint of the jbko helper block at `:336-490`.
* `:4641/4660/4671` — extract `_alloca_type_is_modelled` from the alloca arm's three type
  tests (behaviour-preserving; call sites unchanged in effect).
* `:4605` — the new arm, ~25 lines including the (P1)-(P5) guards and the emission loop, plus
  its comment header. No existing line is rewritten; the lgzx reject at `:4608-4611` is
  untouched.

**`Bennett.jl/test/`** — one new file `test_p06b_aggregate_store.jl` (~10 testsets per §5),
one `runtests.jl` registration + the stale `U114` frontier comments at `:559/:569/:636`, and
three wall-marker advances: `test_vau9_variable_memmove.jl` (g) `:268-284`,
`test_40ys_instanceless_callees.jl` (I) `:488-507`, `test_7wsz_ptr_sret_fields.jl` (J)
`:505-520` — assertions **and** their MEASURED comment paragraphs.

**`BennettVM.jl/`** — `src/`: **nothing** (F5, sixth consecutive bead). `test/`: one new file
`test_p06b_aggregate_store_vm.jl` + its `runtests.jl` registration.

**`worklog/`** — one session block on the top chunk (or a new `099_` chunk; `098` is at 225
lines and the ~280-line threshold is close).

**`.beads/`** — four new beads (§8 (10)), `Bennett-p06b` closed, dolt-cache churn bundled into
the source commit.
