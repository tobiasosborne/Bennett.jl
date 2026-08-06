# Bennett-p06b — PROPOSER B design

**Bead:** Bennett-p06b (P1, `bennettvm-xkl` frontier **wall 6**, extraction side)
**Scope:** decompose a `{ptr,ptr}` aggregate `store` into 64-bit cell stores under `ptr_cells`.
**Role:** PROPOSER B of a CORE 3+1. Nothing in `src/` or `test/` is touched by this document.
**Method:** every IR claim below was produced by a probe run in this session against the REAL
gated path (`extract_parsed_ir_set_from_julia(push!-chain, ptr_cells=true)`) with the extractor's
own pass decision reproduced (`_module_has_sret` ⇒ `["sroa","mem2reg"]`, `src/extract/entry.jl:104-109`).
Verbatim IR is quoted; nothing is reconstructed from memory (Rule 9).

---

## 0. Executive summary of what the probes CORRECTED

Three recorded claims did not survive measurement. All three change the design.

| # | Recorded claim | Measured |
|---|---|---|
| C1 | "TWO live aggregate stores at `_growend!` L93" | `_growend!` has **exactly ONE** live aggregate store (`%L93`). Its second (`%oob`) is in a **Bennett-utzc-pruned dead block** and never reaches the converter. The second and third LIVE aggregate stores are in the **ROOT** `_pushp`, blocks `%top` and `%L16` — a different function with different target provenance. |
| C2 | SSA operand name `%memory_ref15` | My probe reads `%memory_ref12` (and `..._394` / `..._430` / `..._1066` entry manglings across runs). Julia's `_NNN`/`#NN` counters drift per process (Rule 5). **No test or predicate may pin these.** |
| C3 | (implicit) decomposition is a self-contained store-arm change | The `alloca { ptr, ptr }` at ROOT `%L16` emits **NO `IRAlloca`** (measured), and `%"new::Array"` is addressed at **two different cell indices for the same byte offset 8** (measured). Both are hazards the store arm must *refuse*, not inherit. |

---

## 1. Wall verification

### 1.1 The wall, reproduced on the real gated path

```julia
function _pushp(n::Int64); v = Int64[]; push!(v, n); return length(v); end
Bennett.extract_parsed_ir_set_from_julia(_pushp, Tuple{Int64}; ptr_cells=true)
```

```
julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
`#_growend!##0#a7027856`
(callable=Tuple{Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64, Int64, Int64,
 Int64, Int64, Memory{Int64}, MemoryRef{Int64}}}, argtypes=Tuple{})
— ir_extract.jl: store in @julia_#_growend!##0_1066:%L93:
    store { ptr, ptr } %memory_ref12, ptr %1, align 8
  — store of non-integer type LLVM.StructType({ ptr, ptr }) not supported
    (Bennett-lgzx / U114). ...
```

Set-assembly order (`src/extract/julia_set.jl:376-484`) is: throw-leaf partition → **callees** →
**root**. `transitive_callees` yields four keys; `Type{ConcurrencyViolationError}` and
`Type{InexactError}` are dropped as throw leaves (`_is_throw_leaf`, `julia_set.jl:92`), so
`live_callees == [_growend!-closure, throw_inexacterror]`. The closure is extracted first, hence
it is the reported wall. `typeof(Core.throw_inexacterror)` extracts OK (3 blocks, measured).

### 1.2 The POST-pass IR — the live store and its neighbourhood

`_module_has_sret == true` for the closure module ⇒ `sroa`+`mem2reg` DO run. Verbatim
post-pass `%L84`/`%L93` (probe: parse → `_run_passes!(mod, ["sroa","mem2reg"])` → print):

```llvm
L84:                                              ; preds = %L81, %L55
  %53 = getelementptr inbounds i8, ptr %"#self#::#_growend!##0#_growend!##1", i32 56
  %54 = getelementptr inbounds { ptr, ptr }, ptr %1, i32 0, i32 0
  %55 = load ptr, ptr %54, align 8
  %56 = getelementptr inbounds { ptr, ptr }, ptr %1, i32 0, i32 1
  %57 = load ptr, ptr %56, align 8
  %58   = insertvalue { ptr, ptr } zeroinitializer, ptr %55, 0
  %.ref = insertvalue { ptr, ptr } %58, ptr %57, 1
  %.ref.ptr_or_offset = extractvalue { ptr, ptr } %.ref, 0
  %.unbox14 = load i64, ptr %53, align 8
  %coercion = ptrtoint ptr %.ref.ptr_or_offset to i64      ; <- the jbko arm
  %59 = icmp eq i64 %.unbox14, %coercion
  %60 = and i1 true, %59
  %.ref.mem = extractvalue { ptr, ptr } %.ref, 1
  %61 = icmp eq ptr %memoryref_mem30, %.ref.mem            ; <- the 8g7m sibling
  %62 = and i1 %60, %61
  %63 = xor i1 %62, true
  %64 = xor i1 %63, true
  br i1 %64, label %L93, label %L90

L93:                                              ; preds = %L84
  store { ptr, ptr } %memory_ref12, ptr %1, align 8            ; <<<<< THE WALL
  call void (ptr, ...) @julia.write_barrier(ptr %1, ptr %memoryref_mem)
  %memory_ref12.fca.0.extract = extractvalue { ptr, ptr } %memory_ref12, 0
  %memory_ref12.fca.1.extract = extractvalue { ptr, ptr } %memory_ref12, 1
  %67 = getelementptr inbounds i8, ptr %sret_return, i32 0
  store ptr %memory_ref12.fca.0.extract, ptr %67, align 8
  %68 = getelementptr inbounds i8, ptr %return_roots, i32 0
  store ptr %memory_ref12.fca.1.extract, ptr %68, align 8
  %69 = getelementptr inbounds i8, ptr %sret_return, i32 8
  store i64 -1, ptr %69, align 8
  ret void
```

Semantics: this is `v.ref = memory_ref` — the Vector's `MemoryRef` field write-back after the
`_growend!` grow. The three stores after it are the sret return-slot writes the dv1z/7wsz
machinery already synthesises (note the `-1` sentinel documented at `src/extract/sret.jl:132`).

### 1.3 Layout ground truth (`LLVMOffsetOfElement`, never hand-computed)

Measured on the actual `{ ptr, ptr }` type object in the module's datalayout:

```
struct = { ptr, ptr }   literal=true   packed=false   nfields=2   fields=[ptr, ptr]
offsetof(0) = 0    storeSizeOf(field 0) = 8
offsetof(1) = 8    storeSizeOf(field 1) = 8
ABISizeOf(struct) = 16
```

`_is_genericmemory_header_struct` (`src/extract/instructions.jl:218-225`) is **false** for
`{ptr,ptr}` (it requires field 0 to be `i64`), so the byte-granular CW-D4/9n3y stamp does
**not** apply; the word-granular cell stride (`elem_width = 64`) does — matching the two
struct-GEP reads in `%L84` above.

### 1.4 Provenance of the two operands

**Target `%1`.** Definition and the COMPLETE use list (via `LLVM.uses`, not text search):

```
def : %1 = load ptr, ptr %0, align 8
      where %0 = getelementptr inbounds i8, ptr %".roots.#self#", i32 0
      and  %".roots.#self#" is a function ARGUMENT (ptr nocapture readonly)
uses: call void (ptr, ...) @julia.write_barrier(ptr %1, ptr %memoryref_mem)
      store { ptr, ptr } %memory_ref12, ptr %1, align 8
      %56 = getelementptr inbounds { ptr, ptr }, ptr %1, i32 0, i32 1
      %54 = getelementptr inbounds { ptr, ptr }, ptr %1, i32 0, i32 0
```

So `%1` is an **opaque loaded cell** (the GC-rooted `Vector` object address), and **every**
address-forming use of it is a two-index struct GEP on the *same* `{ptr,ptr}` type at field
indices 0 and 1. There is **no** byte-granular `i8` GEP on it. This is the load-bearing fact
for §3.

`%1` IS registered under `ptr_cells`: `load ptr` → `IRLoad(dest, base, 64)`
(`instructions.jl`, ADR-0020-D3 load arm, ~line 4224). `julia.write_barrier` is dropped at
extraction (`instructions.jl:3666-3672`), so it imposes nothing.

**Value `%memory_ref12`.** Definition and COMPLETE use list:

```
def : %memory_ref12 = insertvalue { ptr, ptr } %31, ptr %memoryref_mem, 1
      where %31 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data21, 0
            %memoryref_data21 = getelementptr i8, ptr %memoryref_data, i64 %memoryref_byteoffset
            %memoryref_mem    = phi ptr [ %3, %pass10 ], [ %122, %guard_exit71 ]
uses: %memory_ref12.fca.1.extract   = extractvalue { ptr, ptr } %memory_ref12, 1
      %memory_ref12.fca.0.extract   = extractvalue { ptr, ptr } %memory_ref12, 0
      store { ptr, ptr } %memory_ref12, ptr %"box::GenericMemoryRef"   (block %oob — DEAD)
      store { ptr, ptr } %memory_ref12, ptr %1                          (block %L93 — LIVE)
      %memory_ref12.ptr_or_offset   = extractvalue { ptr, ptr } %memory_ref12, 0
```

The value is a **plain SSA `insertvalue` chain over a `zeroinitializer` base**, already modelled
today: probing the same module shows the walker emits
`IRInsertValue(dest, ZeroAggSentinel(), SSAOperand(...), 0, 0, 2, [64,64])` and
`IRInsertValue(dest, SSAOperand(...), SSAOperand(...), 1, 0, 2, [64,64])` — the Bennett-6bu3
per-field-width shape, with `_struct_field_widths` returning `[64, 64]` under `ptr_cells`
(`instructions.jl:34-90`). Field 1 is **phi-carried** (`%memoryref_mem`); see §3.3.

### 1.5 Dead-block audit (corrects C1)

`_vec_vm_dead_blocks(func)` (`module_walk.jl:426`, Bennett-utzc, ptr_cells-gated) over the
closure, measured per block:

```
AGG STORE in L93  dead=false ::  store { ptr, ptr } %memory_ref12, ptr %1, align 8
AGG STORE in oob  dead=true  ::  store { ptr, ptr } %memory_ref12, ptr %"box::GenericMemoryRef"
```

`%oob`'s body is replaced wholesale by the `:__unreachable__` sink (`module_walk.jl:433-449`).
**`_growend!` therefore has exactly ONE live aggregate store, not two.**

### 1.6 The other TWO live aggregate stores (the ROOT — new information)

`extract_parsed_ir(_pushp, Tuple{Int64}; optimize=false, ptr_cells=true)` — the exact call the
set producer makes at step (4) (`julia_set.jl:478-481`; the set's default is `optimize=false`) —
walls at:

```
ir_extract.jl: store in @julia__pushp_90:%top:
  store { ptr, ptr } %memory_ref, ptr %"new::Array", align 8
  — store of non-integer type LLVM.StructType({ ptr, ptr }) ... (Bennett-lgzx / U114)
```

The root has `_module_has_sret == false`, so **no** `sroa`/`mem2reg` runs, and it carries
**two** live aggregate stores with **two different target provenances**:

```
AGG STORE blk=top dead=false
   store { ptr, ptr } %memory_ref, ptr %"new::Array", align 8
   target = %"new::Array" = call ... ptr @julia.gc_alloc_obj(ptr %current_task, i64 24, ptr %4)
   value  = %memory_ref   = insertvalue { ptr, ptr } %3, ptr %"jl_global#80", 1
AGG STORE blk=L16 dead=false
   store { ptr, ptr } %"new::Array.ref", ptr %0, align 8
   target = %0 = alloca { ptr, ptr }, align 8
   value  = %"new::Array.ref" = insertvalue { ptr, ptr } %10, ptr %9, 1
```

(Both `off(0)=0`, `off(1)=8`, literal, unpacked.) So the corpus presents **three** target
classes, not one: *loaded opaque cell* (growend), *arena object* (root/top), *aggregate alloca*
(root/L16). §2 and §4 handle each explicitly.

### 1.7 Which predicate rejects

`src/extract/instructions.jl:4550-4625`, the store arm, in order:

1. `LLVMGetVolatile == 0` — passes (`align 8`, non-volatile).
2. `ptr_cells` ⇒ `_vm_relaxable_ordering(LLVMGetOrdering(inst))` (Bennett-ares) — passes
   (`NotAtomic`).
3. `if ptr_cells && vt isa LLVM.PointerType` (BVM ADR 0020 D3) — **not taken**: `vt` is
   `LLVM.StructType({ ptr, ptr })`, not `PointerType`.
4. **`vt isa LLVM.IntegerType || _ir_error(...)` — THIS FIRES** (`instructions.jl:4605-4611`).

Note the ordering consequence: because (4) precedes the target-registration guard at
`instructions.jl:4612-4618`, the current message tells us nothing about `%1`'s registration.
Probed separately: `%1` IS in `names` and IS an `IRLoad` dest.

---

## 2. Mechanism

### 2.1 Placement in the cascade

A **new arm**, inserted in `src/extract/instructions.jl` between the D3 `PointerType` arm
(ends ~4603) and the `vt isa LLVM.IntegerType` lgzx reject (~4605). Rationale:

* the D3 arm stays **byte-identical** (disjoint predicate: `PointerType` vs `StructType`);
* the lgzx/U114 reject remains the **final catch-all** for every non-certified value type, its
  message text **unedited** — so every gate-off pin in the suite is untouched (§4.2);
* `ptr_cells == false` never enters the arm ⇒ the circuit path is byte-identical by
  construction, not by inspection.

### 2.2 Certified shape (the predicates, in evaluation order)

Everything below is fail-loud on violation (Rule 1). `st = vt::LLVM.StructType`.

**P0 — gate.** `ptr_cells == true`. Off ⇒ fall through to lgzx, verbatim.

**P1 — target registered.** `haskey(names, ptr.ref)`, with the **existing lgzx message reused
verbatim** ("store target pointer is not a registered SSA name … Bennett-lgzx / U114"). Rule 12:
this is the same condition the integer arm already guards; do not mint new message territory
for it.

**P2 — field types.** `fw = _struct_field_widths(st, inst, ptr_cells)`
(`instructions.jl:34-90`). **Reuse, do not re-implement** (Rule 12). This single call already
fail-louds on: packed structs, empty structs, `i1` fields (`{i64,i1}` overflow/cmpxchg), float
fields, nested-struct fields, vector fields, array fields, and integer widths outside
`{8,16,32,64}` — each with its Bennett-6bu3 message. Pointer fields are admitted as `64`
**only** under `ptr_cells`, which is P0.

**P3 — one cell per field, contiguous, layout-derived.**
```
dl = LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(inst))))
for k in 0:length(fw)-1
    off_k = Int(LLVM.offsetof(dl, st, k))          # LLVMOffsetOfElement — ground truth
    (fw[k+1] == 64 && off_k == 8*k) || _ir_error(... Bennett-p06b ...)
end
```
This is **stricter** than P2 on purpose. An `{i64,i8}` passes 6bu3 but its field 1 occupies
byte 8 with width 8 — a *sub-cell* write that `IRStore(width 8)` into cell 1 cannot express
without a read-modify-write of the surrounding cell, which is neither modelled nor reversible
here. `off_k == 8*k` is computed from the datalayout and **compared**, never assumed —
so trailing/interior padding, over-aligned fields and packed layouts all reject.

*Why general-N rather than exactly-`{ptr,ptr}`:* the loop is identical for N=2 and N=k, so
general-N costs zero extra code and zero extra reject surface (P3 does all the narrowing).
Restricting to exactly-2-ptr would buy no safety — a `{ptr,ptr,i64}` (a Julia `Array` header
slice) or `{i64,i64}` (a 2-tuple bits-struct) would then need a second bead for a
zero-new-mechanism widening. The *expensive* generalisation (sub-cell packing) is exactly what
P3 defers, and it is deferred **explicitly and loudly**.

**P4 — modelled target base (the "unallocated cell" guard).** MEASURED HAZARD. `names` is
populated for **every** instruction in a pre-pass (`module_walk.jl:311-316`), *independently of
whether the converter emits an `IRInst`*. So P1 does **not** prove the target has a defining
node. Probe (distilled fixture, `ptr_cells=true`):

```llvm
%slot = alloca { ptr, ptr }, align 8
%f0 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 0
store ptr %v0, ptr %f0
```
emits
```
IRPtrOffset(:f0, SSAOperand(:slot), 0, 64)
IRExtractValue(:v0, ...)
IRStore(SSAOperand(:f0), SSAOperand(:v0), 64)
```
— **and no `IRAlloca` for `:slot` at all** (the alloca arm's `elem_ty isa IntegerType ||
return nothing` silent skip, `instructions.jl:4645`). BVM would see a store into an
unallocated cell: precisely the failure the ADR-0020-D5c `alloca ptr` arm exists to prevent
(`instructions.jl:4626-4643`).

Guard: walk the target to its root with the existing `_alloca_root_ref`
(`instructions.jl:~18-33`). If the root is an `alloca` whose allocated type is neither
`IntegerType`, nor `ArrayType`-of-integer, nor (under the gate) `PointerType` — i.e. an alloca
the alloca arm silently skips — **fail loud**, naming Bennett-p06b and the follow-on
`alloca {ptr,ptr}` bead. This is what rejects ROOT `%L16` (§1.6).

**P5 — cell-granularity agreement over the target's OTHER uses.** MEASURED HAZARD. Distilled
probe of the ROOT shape:

```llvm
%obj = call ... ptr @julia.gc_alloc_obj(ptr %tt, i64 24, ptr %ty)
%b8  = getelementptr inbounds i8, ptr %obj, i32 8            ; byte-granular
%s1  = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1   ; word-granular
```
emits
```
IRPtrOffset(:b8, SSAOperand(:obj), 8, 8)     ; BVM cell = 8 ÷ (8÷8)  = 8
IRPtrOffset(:s1, SSAOperand(:obj), 8, 64)    ; BVM cell = 8 ÷ (64÷8) = 1
```
**Two different cells for the same byte offset 8 on the same object.** This is the 9n3y /
CW-D4 granularity split, and it is live in the ROOT today (`%5 = gep i8 %"new::Array", 8` +
`store ptr null, ptr %5` vs `%8 = gep {ptr,ptr} %"new::Array", 0, 1` + `load`). p06b must not
add a *write* through one of two disagreeing maps.

Guard: enumerate `LLVM.uses(ptr)` (typed API). Every use that is a **`getelementptr`** must be
either
  * a two-index struct GEP whose `GEPSourceElementType` is `st` itself, or
  * a 2-op GEP with **constant index 0** (offset 0 maps to cell 0 under every stamping);

any other GEP (an `i8` GEP at a non-zero constant index, a variable-index GEP, a struct GEP on
a *different* struct type) ⇒ **fail loud**, naming Bennett-p06b and the granularity bead.
Non-GEP uses (`store`, `load`, `julia.write_barrier`, a call argument passing the cell) are
accepted — the pointer is cell-opaque there.

Against the corpus: growend `%1` has uses `{write_barrier, the store, gep{ptr,ptr}@0,
gep{ptr,ptr}@1}` ⇒ **certifies**. Root `%"new::Array"` has `gep i8 @8` and `gep i8 @16` ⇒
**rejects**. That is the intended outcome (§4.1, §6).

**P6 — value operand.** Exactly two admitted forms:
  * an SSA value (`LLVM.Instruction` or `LLVM.Argument`) of type `st` ⇒ per-field
    `IRExtractValue`;
  * `LLVM.ConstantAggregateZero` ⇒ per-field `ConstOperand(0)` (the Bennett-beaw null-is-cell-0
    convention, already used by the D3 arm).

`undef` / `poison` / a non-zero `ConstantStruct` / a `GlobalVariable` ⇒ fail loud, Bennett-p06b.
(`undef` in particular must never become a silent 0: a reversible VM cannot manufacture an
arbitrary value and still reverse.)

### 2.3 Emitted `IRInst` sequence

Field-**ascending** (deterministic; and immaterial for correctness, see §3.2):

```julia
out = IRInst[]
base = ssa(names[ptr.ref])
n    = length(fw)
for k in 0:n-1
    off = Int(LLVM.offsetof(dl, st, k))                      # 0, 8, 16, …
    pk  = _auto_name(counter)
    push!(out, IRPtrOffset(pk, base, off, 64))               # 64 = cell stride (see below)
    vk_op = if agg_is_zeroinit
                ConstOperand(0)
            else
                vk = _auto_name(counter)
                push!(out, IRExtractValue(vk, _operand(val, names), k, 0, n, fw))
                ssa(vk)
            end
    push!(out, IRStore(ssa(pk), vk_op, 64))
end
return out
```

For the corpus store this is exactly six nodes:

```
IRPtrOffset(:%p0, SSAOperand(:1), 0, 64)
IRExtractValue(:%v0, SSAOperand(:memory_ref12), 0, 0, 2, [64,64])
IRStore(SSAOperand(:%p0), SSAOperand(:%v0), 64)
IRPtrOffset(:%p1, SSAOperand(:1), 8, 64)
IRExtractValue(:%v1, SSAOperand(:memory_ref12), 1, 0, 2, [64,64])
IRStore(SSAOperand(:%p1), SSAOperand(:%v1), 64)
```

**The `elem_width` stamp.** Use the *same decision function the D4 struct-GEP arm already
uses* (`instructions.jl:4046`):
`ew = _is_genericmemory_header_struct(st) ? 8 : 64`. Factoring it into a tiny named helper
(`_p06b_cell_stride(st)` or reusing the expression) is what makes store/load agreement a
**structural identity** rather than a coincidence: the loads on the same target go through the
D4 arm, so if the two ever diverge they diverge together. Under P3 (`fw[k] == 64` everywhere)
the GenericMemory-header branch is unreachable — `{i64,ptr}` has `fw == [64,64]` and would
select `8` — so the helper is stated for *future* widening, and P3+P5 keep today's behaviour
pinned at 64. (Design note for the implementer: if you prefer, hard-code `64` and add an
`@assert !_is_genericmemory_header_struct(st)` — but then a `{i64,ptr}` store must reject
explicitly, since its D4 loads would land on byte-cells 0/8 while the store lands on 0/1.)

**Multi-`IRInst` return.** `_convert_instruction` already supports returning a `Vector{IRInst}`
(precedent: the `soft_fcmp` arm, `instructions.jl:4525-4530`), and `counter::Ref{Int}` is in
scope for `_auto_name` (`instructions.jl:3032`).

### 2.4 Downstream: zero BennettVM changes — E2E PROBED, not assumed

The three emitted node types are all already produced under `ptr_cells` today
(`IRPtrOffset` from D4, `IRExtractValue` from 6bu3, `IRStore` from D3). I ran the *equivalent
decomposed program* through the real front end and BennettVM:

```llvm
%buf  = call ptr @malloc(i64 32)
%slot = call ptr @malloc(i64 16)
%a0  = insertvalue {ptr, ptr} zeroinitializer, ptr %buf, 0
%agg = insertvalue {ptr, ptr} %a0, ptr %slot, 1
%f0 = getelementptr {ptr, ptr}, ptr %slot, i32 0, i32 0
%v0 = extractvalue {ptr, ptr} %agg, 0
store ptr %v0, ptr %f0
%f1 = getelementptr {ptr, ptr}, ptr %slot, i32 0, i32 1
%v1 = extractvalue {ptr, ptr} %agg, 1
store ptr %v1, ptr %f1
%r0 = load i64, ptr %f0
%r1 = load i64, ptr %f1
...
```
→ `lower_vm` accepts it, and for `x ∈ {0, 7, -3}` under **both** history regimes
(`compute_must_cache(prog)` and the empty L3 set):

```
status=halted  buf=1099511627776 (= ARENA_BASE = 1<<40)  slot=1099511627780
r0=1099511627776   r1=1099511627780     ; both field values read back exactly
reversed_ok=true   hist_empty=true      ; unrun! returns the EXACT initial state
```

So p06b is an extraction-only bead, like the previous five — and unlike them, that claim here
is backed by an executed round trip rather than by node-type inspection.

---

## 3. Soundness under the arena model (klgz discipline)

### 3.1 Exactness of the decomposition

Let `φ` be the injective map *native address ↦ Int64 VM cell value* implemented by BVM's
deterministic bump allocator (`ARENA_BASE + arena_top`, `ARENA_BASE = 1<<40`; the jbko comment
block at `instructions.jl:292-330` is the canonical statement, and my probe re-confirms
`buf == ARENA_BASE` for the first allocation and `alt ≠ buf` for the second).

An LLVM `store {T0,T1} %a, ptr %p` is *defined* by the datalayout as: for each field `k`, write
the `storeSizeOf(Tk)` bytes of `extractvalue %a, k` at `%p + offsetof(st,k)`. Under P3 each
field is exactly one 8-byte cell at `8k`, and the fields tile `[0, 8n)` with no gaps and no
overlap. The emitted sequence performs literally that: `IRPtrOffset(_, p, 8k, 64)` addresses
cell `p+k` (BVM's rule `cell = offset_bytes ÷ (elem_width÷8)`), and `IRStore(_, _, 64)` writes
one whole cell. So the decomposition is the *definition*, instantiated — not an approximation.

The values written are pointer **cells** copied verbatim from the SSA aggregate. Copying a
pointer cell is `φ`-equivariant (`φ(x)` is *the* value; there is nothing to convert — the jbko
"pure retype" argument), so no address arithmetic and no layout fact enters the program. The
arm therefore admits **no** new class of value; it only re-routes an existing class through an
existing addressing mode.

**Reversibility.** Each `IRStore` is a single-cell overwrite; BVM's L2/L3 machinery records the
prior cell content and the delta reverses it (probed: `unrun!` restores the exact initial state
with a drained history under both regimes). `n` independent single-cell stores reverse as the
reverse-ordered composition of `n` invertible cell writes. No ancilla, no aliasing between the
`n` writes (distinct cells by P3), so the composite is invertible.

### 3.2 Store order is immaterial

Every field value is read from the **SSA aggregate**, never from memory: `IRExtractValue` reads
`%memory_ref12`, which is an `insertvalue` chain in registers. So even in the self-referential
case (target pointer also appearing as a field value — which my BVM probe deliberately
exercises: `%slot` is both the target and field 1) the stores cannot observe each other.
Ascending field order is chosen for determinism and diff-readability only.

### 3.3 Phi-/select-carried field values

Corpus fact: field 1 of `%memory_ref12` is `%memoryref_mem`, a `phi ptr [ %3, %pass10 ],
[ %122, %guard_exit71 ]`. This needs **no** special handling and introduces **no** new
false-path-sensitisation risk (the CLAUDE.md phi warning):

* the phi is resolved by the existing `lowering/phi.jl` path-predicate machinery *before* our
  nodes ever see it — we consume `SSAOperand(:memoryref_mem)`, an already-merged value;
* our arm adds **no** new control flow, no MUX, no new join point. It is straight-line inside
  one basic block (`%L93`), which by construction has a single predecessor here;
* the `insertvalue`/`extractvalue` pair we sit between is already the modelled 6bu3 shape, so
  the aggregate was already crossing the phi boundary before p06b — the store arm does not
  widen that exposure.

`synth_ptr_provenance` (`ir_types.jl:590`, the Bennett-land synthetic-address-bytes tracking) is
keyed on `(global_name, byte_offset, width)` for **constant globals**. No field value here
derives from a global's synthetic address bytes: field 0 is a GEP of a loaded `Memory` data
pointer, field 1 is a phi over `Memory` object cells. The arm introduces no new memcpy-carried
byte path, so the Bennett-land load-escape guard is unaffected. If a future corpus stores a
synthetic-address-bearing field, it arrives as an `IRExtractValue` of an aggregate that the
6bu3 path already had to certify — the guard sits upstream of us, not downstream.

Width-0 / `-1` sentinels: the `-1` visible at `%L93` (`store i64 -1, ptr %69`) is the **sret
slot** sentinel documented at `src/extract/sret.jl:132` ("Read this BEFORE 'fixing' a -1 you see
in an sret slot"). It is a *separate* store into `%sret_return`, not part of our aggregate, and
is untouched.

### 3.4 Aliasing: the target's OTHER accesses agree, cell for cell

Enumerated in §1.4. The complete address-forming use set of `%1` is
`{gep {ptr,ptr} %1, 0, 0 ; gep {ptr,ptr} %1, 0, 1}`, both of which go through the D4 struct-GEP
arm and produce `IRPtrOffset(_, %1, 0, 64)` and `IRPtrOffset(_, %1, 8, 64)` → cells `%1+0` and
`%1+1`. Our stores emit *byte-identical* `IRPtrOffset` nodes (same offsets from the same
`LLVMOffsetOfElement` call, same stride). **The read side and the write side of the same object
are therefore the same two cells, by construction and by measurement** — this is the concrete
content of P5, and it is why P5 is a predicate rather than a comment.

The `%oob` alias (`store {ptr,ptr} %memory_ref12, ptr %"box::GenericMemoryRef"`) writes a
*different* object and lives in a utzc-pruned block; it neither aliases nor executes.

### 3.5 What the soundness argument does NOT cover (Rule 1 honesty)

* A callee that receives the target cell and byte-addresses it. Out of model; the closed-world
  check (`_closed_world_check!`) is the guard, not us.
* The ROOT's `%"new::Array"`, where the two granularities genuinely disagree (§2.2 P5). We
  **refuse** it rather than pick a winner. Picking `64` would be *accidentally* harmless in
  today's root (nothing reads byte-cell 8) — an accident, not an argument.
* Sub-cell field packing (`{i64,i8}`). Refused by P3.

---

## 4. Failure modes

### 4.1 Everything that must KEEP rejecting

| # | Shape | Message (new text in **bold**) | Bead named |
|---|---|---|---|
| F1 | Any store with `ptr_cells == false` | "store of non-integer type $(vt) not supported (Bennett-lgzx / U114). SoftFloat dispatch should reroute…" — **unchanged, byte-identical** | lgzx / U114 |
| F2 | `volatile` store (either gate) | "volatile store not supported (Bennett-4mmt / U14)" | 4mmt / U14 |
| F3 | `AcquireRelease`/`SeqCst` store under gate | existing ares message | ares / CW-D2 |
| F4 | Non-struct, non-ptr, non-integer value type (float, vector, array) | lgzx / U114, **unchanged** | lgzx / U114 |
| F5 | Target not in `names` (global / ConstantExpr / alias) | "store target pointer is not a registered SSA name …(Bennett-lgzx / U114)" — **reused verbatim** | lgzx / U114 |
| F6 | Packed struct `<{ptr,ptr}>` | 6bu3 packed message | 6bu3 |
| F7 | Empty struct `{}` | 6bu3 empty message | 6bu3 |
| F8 | `{i64,i1}` (overflow / cmpxchg result) | 6bu3 i1-width message | 6bu3 |
| F9 | float / nested-struct / array / vector field | 6bu3 unsupported-field message | 6bu3 |
| F10 | Pointer field with `ptr_cells == false` | unreachable (P0 gates first) — F1 fires | lgzx / U114 |
| F11 | Sub-cell field layout (`{i64,i8}`, `{i32,i32}`) | **"aggregate store of $(st) is not decomposable into whole 64-bit cells: field $k has width $w at byte offset $off (expected width 64 at offset $(8k)). Sub-cell field packing would need a read-modify-write of the surrounding cell, which the BennettVM cell model (ADR 0018 §A) does not express. (Bennett-p06b)"** | **p06b** |
| F12 | Target roots at an aggregate/unmodelled `alloca` | **"aggregate store target roots at `alloca $(elem_ty)`, which emits no IRAlloca — BennettVM would see a store into an unallocated cell. Decomposing the store without allocating the slot is unsound. (Bennett-p06b; the aggregate-alloca arm is tracked separately)"** | **p06b** |
| F13 | Target also byte-addressed (`gep i8 %p, K≠0`) or variable-GEP'd | **"aggregate store target is addressed at BOTH word granularity (this store's struct fields, cell stride 8 bytes) and byte granularity (`$(use)`), which map the same byte offset to different VM cells (the CW-D4 / 9n3y split). Refusing to write through one of two disagreeing cell maps. (Bennett-p06b)"** | **p06b** |
| F14 | Value operand is `undef` / `poison` / non-zero `ConstantStruct` / a global | **"aggregate store value $(val) is neither an SSA aggregate nor `zeroinitializer`; an undef/poison field has no cell value a reversible VM can write or restore. (Bennett-p06b)"** | **p06b** |

**Message-hygiene constraints on F11-F14 (deliberate):** none of the new strings may contain
`store of non-integer type`, `ptrtoint`, `memmove`, `Bennett-iwo9`, `not yet lowered to
reversible gates`, or `sret struct field` — every one of those is a *load-bearing negative* in
an existing wall marker (§4.2), and reusing them would make a marker silently pass on the wrong
wall. All four carry the literal `Bennett-p06b` so the next bead's negatives have a handle.

### 4.2 Message-territory analysis

Files matching `lgzx|U114`: `test/runtests.jl`, `test_40ys_instanceless_callees.jl`,
`test_416r17_sret_forward_cell_args.jl`, `test_59zi_sret_call_memcpy.jl`,
`test_7wsz_ptr_sret_fields.jl`, `test_beaw_null_ptr.jl`, `test_d1b_julia_set.jl`,
`test_haiy_ptr_cells_store_load_gep.jl`, `test_lgzx_store_fail_loud.jl`,
`test_nd45_ptr_cells_call_emission_multifn.jl`, `test_utzc_dead_block_pruner.jl`,
`test_vau9_variable_memmove.jl`.

| Site | Assertion | Gate | Prediction | Why |
|---|---|---|---|---|
| `test_lgzx_store_fail_loud.jl:37` | `occursin("Bennett-lgzx", msg)` (float store) | off | **GREEN** | float value type, P0 never entered; message untouched |
| `test_haiy…:116` | `occursin("Bennett-lgzx")`, `occursin("store of non-integer type")` | **off** | **GREEN** | gate-off ⇒ byte-identical |
| `test_haiy…:308` | `occursin("store of non-integer type", get_msg)` (`ht_get`) | **off** | **GREEN** | gate-off |
| `test_nd45…:154-155` | `occursin("U114")`, `occursin("store of non-integer type")` | **off** | **GREEN** | gate-off `alloca ptr` fixture |
| `test_utzc…:313` | `occursin("U114")`, `occursin("store of non-integer type")` | **off** | **GREEN** | explicitly `ptr_cells=false` |
| `test_utzc…:265` | `!occursin("store of non-integer type", fl)` (fdict set, gate ON) | on | **GREEN** | negative can only stay satisfied as more stores are admitted; F11-F14 deliberately avoid the substring |
| `test_beaw…:164` | `_is_null_wall(msg) \|\| occursin("non-integer type")` | **off** | **GREEN** | gate-off |
| `test_d1b…:150-190` | cells-off disjunction + cells-on `skmsg == ""` | both | **GREEN** | fdict set already fully closes under the gate (416r.12); p06b adds no reject to a path that has none |
| `test_416r17…:134-155` | `if htk_i !== nothing … else @info` | on | **GREEN** | structurally branch-robust |
| `test_59zi…:345-355` | `occursin("U114") \|\| (store && structtype)` in the `threw` branch | on | **GREEN (branch not taken)** | **MEASURED**: under `--check-bounds=yes`, `extract_parsed_ir(Base.ht_keyindex2_shorthash!, …; ptr_cells=true)` **succeeds today** (`ret_width == 72`); all five of its `{ptr,ptr}` stores sit in `%oob*` blocks that utzc marks dead. The `else` branch is already unreachable in both bounds modes — the comment there is stale. p06b changes nothing. |
| **`test_vau9…:274` / `:281`** | `!occursin("ptrtoint", msg)` and `occursin("Bennett-lgzx")\|\|…` | on | **RED — must be advanced** | see below |
| **`test_40ys…:497` / `:505`** | `!occursin("ptrtoint", e.msg)` and the landing disjunction | on | **RED — must be advanced** | see below |
| **`test_7wsz…:513` / `:519`** | `!occursin("ptrtoint", msg)` and the landing disjunction incl. `"StructType"` | on | **RED — must be advanced** | see below |
| `test_7wsz…(J2):545` | root marker, `occursin("Bennett-5oyt")\|\|"U15"\|\|"Bennett-lgzx"\|\|"U114"` | on | **GREEN** | it calls `extract_parsed_ir(_push7wsz, Tuple{Int64}; ptr_cells=true)` with the **default `optimize=true`**, which walls at the `movq %fs:0` pgcstack inline asm (Bennett-5oyt) long before any store — probed |

**The three RED markers.** After p06b the set's first wall message is the Bennett-583s reject
(§6), whose text **contains the literal substring `ptrtoint`**. So:

* every `@test !occursin("ptrtoint", msg)` flips RED — *this is the wall-marker working*
  (Bennett-0ncn: the negatives are the load-bearing half; jbko added these very negatives
  precisely so this transition could not pass unnoticed);
* every landing **positive** disjunction also flips RED, because the new message contains none
  of `Bennett-lgzx`, `U114`, `store of non-integer type`, `StructType`, `Bennett-5oyt`, `U15`.

The p06b commit **must** advance all three in the same change: drop the `ptrtoint` negative,
add `!occursin("Bennett-lgzx")` / `!occursin("U114")` / `!occursin("store of non-integer type")`
as the new load-bearing negatives, add `!occursin("Bennett-p06b")` (proving the corpus store was
*admitted*, not merely re-rejected under a new name), and set the positive to
`occursin("Bennett-583s")`. Keep the existing `occursin("_growend!")` pin. Retain
`!occursin("Bennett-iwo9")` and `!occursin("memmove")` — still meaningful, still green.

---

## 5. Test plan

### 5.1 `test/test_p06b_aggregate_store_cells.jl` (new)

Distilled `.ll` fixtures under `test/fixtures/ll/` (`p06b_*.ll`), following the vau9/haiy idiom
(`extract_parsed_ir_from_ll(path; entry_function=…, ptr_cells=…)`), plus the real-corpus gate.

| Gate | What it pins |
|---|---|
| **(a) GREEN `{ptr,ptr}`** | Target = `load ptr` (the growend shape). Exactly 6 instructions, in order: `IRPtrOffset(_, base, 0, 64)`, `IRExtractValue(_, agg, 0, 0, 2, [64,64])`, `IRStore(_, _, 64)`, `IRPtrOffset(_, base, 8, 64)`, `IRExtractValue(_, agg, 1, …)`, `IRStore(_, _, 64)`. Offsets pinned as **values** (0, 8) and independently against `LLVM.offsetof` in the test, so a datalayout change is caught, not baked in. |
| **(b) GREEN general-N** | `{i64,i64,i64}` → offsets 0/8/16, three `IRStore(_,_,64)`. Proves the arm is not `{ptr,ptr}`-shaped. |
| **(c) GREEN zeroinitializer** | `store {ptr,ptr} zeroinitializer, ptr %p` → `ConstOperand(0)` per field, **no** `IRExtractValue`. |
| **(d) GREEN mixed int/ptr cells** | `{ptr,i64}` → offsets 0/8, both `IRStore(_,_,64)`. Deliberately **not** `{i64,ptr}`: that is the GenericMemory-header shape (`_is_genericmemory_header_struct`), whose D4 loads are stamped byte-granular (`elem_width = 8`) — it must get its own gate pinning either an explicit reject or the byte stride, per §2.3's implementer note. Pin that decision here as gate **(d2)**, whichever way the implementer takes it, with a comment naming CW-D4 / 9n3y. |
| **(e) GATE OFF byte-identity** | Same fixture as (a) with `ptr_cells=false` ⇒ the lgzx message with `occursin("Bennett-lgzx")`, `occursin("U114")`, `occursin("store of non-integer type")`, and `!occursin("Bennett-p06b")`. |
| **(f) REJECT sub-cell** | `{i64,i8}` and `{i32,i32}` ⇒ F11; assert `occursin("Bennett-p06b")` and `!occursin("store of non-integer type")`. |
| **(g) REJECT packed / empty / i1 / float / nested** | `<{ptr,ptr}>`, `{}`, `{i64,i1}`, `{double,i64}`, `{{i64,i64},i64}` ⇒ 6bu3 messages (assert `occursin("Bennett-6bu3")`). Proves P2 delegates rather than duplicates. |
| **(h) REJECT unregistered target** | `store {ptr,ptr} %agg, ptr @some_global` ⇒ the **lgzx** registered-SSA message (F5), not a p06b one. |
| **(i) REJECT aggregate-alloca target** | the ROOT `%L16` shape ⇒ F12; also assert **no** `IRStore` was emitted. |
| **(j) REJECT granularity conflict** | the ROOT `%top` shape (`gep i8 %obj, 8` alongside the struct GEPs) ⇒ F13. Positive control: the same fixture **without** the `i8` GEP extracts green. |
| **(k) REJECT undef value** | `store {ptr,ptr} undef, ptr %p` ⇒ F14. |
| **(l) ORDER determinism** | field-ascending emission; and a self-referential fixture (target also stored as a field) extracting identically, pinning §3.2. |
| **(m) volatile / SeqCst still reject under the gate** | 4mmt / ares messages intact for a `{ptr,ptr}` store. |
| **(n) REAL-CORPUS WALL MARKER** | see §5.3. |

Every reject gate asserts both a **positive** substring and the **negatives** that prove it is
not some *other* wall (the jbko/0ncn convention).

### 5.2 `../BennettVM.jl/test/test_p06b_agg_store_vm.jl` (new; ZERO BVM `src/` changes)

Mirrors `test_jbko_ptr_identity_vm.jl`. C/word tier (`malloc`), honest scope boundary stated in
the header: the real `_growend!` store arrives in a JULIA-tier program that still walls at
Bennett-583s upstream, so this file proves the **mechanism**, not the corpus.

1. **Handoff shape** — the ParsedIR BVM receives carries the p06b six-node sequence with
   `IRPtrOffset` offsets 0/8 and `elem_width == 64`.
2. **`lower_vm`** — two cell writes, no new instruction kind.
3. **Oracle** — build `{ptr,ptr}` in the arena via one aggregate store, read both fields back:
   `r0 == buf == ARENA_BASE (1<<40)`, `r1 == slot`, `slot ≠ buf` (allocator injectivity), for
   `x ∈ {0, 7, -3}`, under **L2** (`compute_must_cache(prog)`) **and L3** (empty must-cache).
   *(Pre-verified in this session on the equivalent hand-decomposed IR: `status=halted`,
   `r0=1099511627776`, `r1=1099511627780`.)*
4. **Reversal** — `unrun!` restores the exact initial state, `isempty(s.history)`,
   `s.step_count == 0`, both regimes. *(Pre-verified: `reversed_ok=true`.)*
5. **Per-step inverse** — `per_step_inverse_check` at `K ∈ {1, 4}`, both regimes.
6. **Cell agreement** — write via the aggregate store, read back via *struct GEP loads*, and
   assert the values match: the operational form of §3.4.
7. **Self-reference** — target also stored as a field (§3.2), oracle pinned.

### 5.3 The NEXT wall marker (with load-bearing negatives)

Placed in gate (n) of `test_p06b_aggregate_store_cells.jl`, and mirrored as the advancement of
the three existing markers (§4.2):

```julia
# POSITIVE — MEASURED (patched-IR probe, this design session): the push! set
# advances past %L93 and dies at %idxend on Bennett-583s.
@test occursin("Bennett-583s", msg)
@test occursin("_growend!", msg)          # still the closure that walls

# LOAD-BEARING NEGATIVES — the lgzx wall is CLEARED. Without these the
# positive alone would keep passing if p06b regressed to a differently-worded
# store reject (the Bennett-0ncn lesson).
@test !occursin("Bennett-lgzx", msg)
@test !occursin("U114", msg)
@test !occursin("store of non-integer type", msg)
# ... and p06b's OWN rejects did NOT fire on the corpus store: the store was
# ADMITTED, not re-rejected under a new name. This is the half that would
# catch an over-tight P3/P5.
@test !occursin("Bennett-p06b", msg)
# still-cleared predecessors
@test !occursin("memmove", msg)
@test !occursin("Bennett-iwo9", msg)
```

Deliberately **not** pinned: SSA names (`%memory_ref12` vs `%memory_ref15`), entry manglings
(`_394` / `_430` / `_1066`), block labels — all measured to drift (C2, Rule 5).

### 5.4 Registration

`test/runtests.jl` after `test_vau9_variable_memmove.jl`, with the standard header comment
naming the wall it clears and the wall it exposes.

---

## 6. Frontier forecast — PROBED, not predicted

Method (the jbko lesson: unverified forecasts are wrong): dump the closure's POST-pass IR, patch
**only** the `%L93` aggregate store into the exact six-node decomposition p06b would emit
(`gep {ptr,ptr} … 0,K` + `extractvalue` + `store ptr`), re-run `extract_parsed_ir_from_ll(…;
ptr_cells=true)`, and read the new wall.

```
BASELINE : WALL  store { ptr, ptr } %memory_ref12, ptr %1  — Bennett-lgzx / U114
PATCHED  : WALL  ptrtoint in @julia_#_growend!##0_394:%idxend:
             %85 = ptrtoint ptr %memory_data39 to i64
           — ptrtoint of a GenericMemory .data base under ptr_cells whose result is NOT
             confined to a same-Memory base-cancelling bounds check (a use is not a
             same-root sub(ptrtoint,ptrtoint); e.g. inttoptr-deref, store, hash, or a
             cross-allocation difference). An escaping base-dependent address would
             break oracle match (Bennett-583s / CW-D; CLAUDE.md §1).
```

**Wall 7 = Bennett-583s at `%idxend`.** Root cause, read off the IR: `%idxend` cancels two
`ptrtoint`s whose bases have **different syntactic roots** —

```llvm
%memoryref_data29          = load ptr, ptr %32     ; %32 = gep i8 %"#self#…", 56  (closure field)
%memoryref_data_byteoffset36 = getelementptr i8, ptr %memoryref_data29, i64 %…
%memory_data_ptr38 = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem30, i32 0, i32 1
%memory_data39     = load ptr, ptr %memory_data_ptr38
%85 = ptrtoint ptr %memory_data39 to i64
%86 = ptrtoint ptr %memoryref_data_byteoffset36 to i64
%87 = sub i64 %86, %85
```

`_memdata_root` (`instructions.jl:245-262`) seeds only on "`load ptr` of a `{i64,ptr}` field-1
GEP", so `%memoryref_data_byteoffset36`'s root resolves through the **closure-field** load and
never matches `%memory_data39`'s `%memoryref_mem30` root — hence "not a same-root sub". The
*structurally identical* check at `%L58` **does** pass today, because there both sides root at
`%memoryref_mem`. So wall 7 is a **root-recognition widening** of 583s (teach `_memdata_root`
the closure-captured `MemoryRef.ptr_or_offset` seed), not a new capability class. This matches
the pre-existing note in `BennettVM.jl/test/test_jbko_ptr_identity_vm.jl:68` ("a further 583s
coverage gap at `%idxend` behind it") — now measured rather than suspected.

**Secondary frontier (the ROOT).** With p06b as designed, the root's `%top` aggregate store is
**refused by P5** (F13: `%"new::Array"` is byte-addressed at 8 and 16 *and* struct-addressed at
fields 0/1 — §2.2). This costs the frontier **nothing**, measured: patching the root's `%top`
store away by hand advances the root only two instructions, to

```
llvm.memcpy.p0.p0.i64(ptr %"new::Array.size", ptr %"new::Array.size_ptr1", i64 8, i1 false)
  — memcpy src operand is not alloca-backed … (Bennett-37mt Phase 1 / Bennett-8bys)
```

So the root's own wall is **Bennett-37mt/8bys** either way. Refusing the granularity-split store
converts a would-be silent cell-map disagreement into a named bead at zero frontier cost. The
root's `%L16` aggregate-alloca store (F12) sits behind that same memcpy wall and is likewise
unreachable today.

**Order note.** Because the set producer runs callees before the root (`julia_set.jl:438` then
`:473`), the set-level `:fail_loud` message after p06b names **growend / 583s**. The root's
walls only surface via a direct `extract_parsed_ir(…; optimize=false, ptr_cells=true)` or via
`on_extract_error=:skip` diagnostics.

**Follow-on beads this design should file:**
1. **583s `%idxend` root widening** — wall 7 (P1, immediate successor).
2. **Aggregate-typed `alloca` arm** (`alloca {ptr,ptr}` → `IRAlloca(dest, 64, n_fields)`) — F12.
3. **Cell-granularity reconciliation for `gc_alloc_obj` Julia-tier objects** (the 9n3y split
   generalised beyond `{i64,ptr}`) — F13.
4. **Sub-cell aggregate stores** (`{i64,i8}` read-modify-write) — F11.

---

## 7. Risks

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| R1 | The three existing wall markers (vau9 g / 40ys I / 7wsz J) go RED on landing and a hurried implementer *deletes* them instead of advancing them. | **High** | §4.2 lists them with predicted flip and the exact new assertions; the p06b commit is not complete until all three are advanced. CLAUDE.md §0/0ncn discipline. |
| R2 | P5 (granularity) is judged "over-tight", dropped, and the root store is admitted at stride 64 — a silent cell-map disagreement on a live Julia object. | **High** | §6 measures that admitting it buys **zero** frontier progress (37mt memcpy wall two instructions later). §2.2 P5 shows the two-cells-for-one-offset probe output. Gate (j) pins both the reject and the positive control. |
| R3 | P4 (alloca root) is dropped; a `{ptr,ptr}` store lands on a slot with no `IRAlloca` and BVM writes an unallocated cell. | **High** | Probe in §2.2 P4 shows the missing `IRAlloca` today. Gate (i) pins it. Note `haskey(names, …)` is NOT a proxy — `module_walk.jl:311-316` names every instruction. |
| R4 | `elem_width` stamp diverges from the D4 struct-GEP arm in a later edit ⇒ read/write cell disagreement. | **High** | Share one decision expression/helper with `instructions.jl:4046`; gate (a) pins the store's `IRPtrOffset` and a struct-GEP load's `IRPtrOffset` to the **same** `(offset, elem_width)` in one assertion. BVM gate 6 checks it operationally. |
| R5 | The new arm is placed *before* the D3 `PointerType` arm and perturbs `store ptr` emission. | Med | §2.1 fixes placement after D3, before the lgzx integer check; predicates are disjoint by value type. A `store ptr`-shape byte-identity assertion belongs in gate (e). |
| R6 | A new reject string accidentally contains `ptrtoint` / `store of non-integer type` / `memmove`, silently satisfying another marker's negative. | Med | §4.1 states the forbidden substrings explicitly; add a meta-assertion in gate (f)/(i)/(j) that the p06b message contains **none** of them. |
| R7 | Corpus drift: a Julia patch release changes the closure's block structure or the number of live aggregate stores. | Med | Gate (n) is version-observational by construction (no name/label pins); the distilled fixtures (a)-(m) carry the contract independently of Julia's codegen. |
| R8 | `_struct_field_widths` is later relaxed (e.g. to admit `i1`) and P3 silently inherits the relaxation. | Med | P3 re-checks `fw[k] == 64` itself; it does not trust P2's width set. |
| R9 | `undef`-valued aggregate store appears in a future corpus and F14 blocks it, tempting a "just store 0" fix. | Low | F14's message states the reversibility reason. A reversible VM cannot restore a value it invented. |
| R10 | Sub-cell reject (F11) blocks a `{i64,i8}` sret-adjacent store some other bead needs. | Low | Measured: no such store exists in the push! set. Bead filed (§6.4). |
| R11 | Emitting an `IRPtrOffset(_, base, 0, 64)` for field 0 adds a node where the base would do. | Low | Uniformity beats one node; BVM probe confirms offset-0 `IRPtrOffset` round-trips exactly. |

---

## 8. Estimated diff shape (touch points only — no time estimates)

**`src/extract/instructions.jl`** — the only `src/` file.
* `~4603-4605`: the new arm, between the D3 `PointerType` store arm and the lgzx `IntegerType`
  check. ~70-90 lines including the comment block (the arm's determinism/soundness rationale
  belongs *in the source*, in the style of the jbko block at `:292-330`).
* `~218-225` neighbourhood: one small helper for the cell stride shared with the D4 struct-GEP
  arm at `~4046` (or a comment cross-reference if the implementer prefers no new function).
* No change to `_struct_field_widths` (`:34-90`), reused as-is.
* No change to the lgzx message text (`:4605-4618`).

**No change** to: `src/extract/sret.jl`, `src/extract/module_walk.jl`, `src/ir_types.jl`,
`src/lowering/*` (no new `IRInst` type), `src/extract/entry.jl`.

**`test/`**
* new `test/test_p06b_aggregate_store_cells.jl` (gates a-n);
* new fixtures `test/fixtures/ll/p06b_*.ll` (~10 small files);
* `test/runtests.jl`: one `runfile(...)` + header comment;
* **advance** the three wall markers: `test_vau9_variable_memmove.jl` (~268-283),
  `test_40ys_instanceless_callees.jl` (~493-507), `test_7wsz_ptr_sret_fields.jl` (~509-521).

**`../BennettVM.jl/`**
* new `test/test_p06b_agg_store_vm.jl`; registration in its `runtests.jl`;
* **zero** `src/` changes (E2E-probed, §2.4).

**`worklog/`** — prepend a session block to the highest-numbered chunk (currently
`worklog/098_2026-08-04_vau9_memmove_routing.md`; re-check `ls worklog/ | sort -r | head -1`
before writing, per CLAUDE.md §0). Record at minimum: C1/C2/C3 (the three corrected claims),
the `names`-is-populated-for-every-instruction gotcha, the two-cells-for-one-byte-offset
measurement, and the stale `test_59zi` else-branch.
