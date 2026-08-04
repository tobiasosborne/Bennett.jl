# Bennett-7wsz — DESIGN PROPOSER B

**Bead:** Bennett-7wsz (P1, CORE 3+1) — ptr-typed sret struct fields under `ptr_cells=true`.
**Repo/HEAD:** Bennett.jl, `main`, `5e3df43` (Bennett-40ys).
**Author:** Proposer B (independent; has NOT read proposal A).
**Date:** 2026-08-03.

> Every claim below that is not a citation of committed source is backed by a probe
> transcript in §1. Nothing here is inferred from documentation alone (Rule 9/10).

---

## 0. Executive summary

Admitting `PointerType` fields in `_sret_struct_fields` is **necessary but not
sufficient**. Probing with a throwaway in-memory monkey-patch (§1.4) shows that a
*second* admission arm is required in the same file — `_try_handle_sret_scalar_store!`
rejects a `store ptr` into an sret field, and that is exactly what Julia emits for
both the `_growend!` closure and every synthetic fixture, after the pipeline's
auto-prepended SROA canonicalises the `alloca`+`memcpy` form.

With **both** arms patched (and nothing else), the following extract cleanly to the
exact value-ABI shape BennettVM's guard-5 already ingests, with **zero** BennettVM
source changes:

| fixture | shape | result under `ptr_cells=true` |
|---|---|---|
| `_mk3c(p::Ptr{Int64}, x::Int64)::P3C` | `sret({ptr,i64})` | `ret_width=128`, `elems=[64,64]` ✅ |
| `_use3c` (consumed box, field read back) | caller side | `IRCall(...,128)` + `IRExtractValue` ✅ |
| `_mk3b(m::Memory)::MemoryRef` | `sret({ptr,ptr})` **+ `return_roots`** | `ret_width=128`, `args=[(:return_roots,64),…]` ✅ |
| `extract_parsed_ir_set_from_julia(_use3c, …)` | closed-world SET | 2 bodies ✅ |

`return_roots` needs **no special handling at all** — it is an ordinary pointer
out-parameter and is already modelled as a 64-bit cell. The evidence for that (and
for why *fusing* it with the sret buffer would be a miscompile-prone guess) is §3.

`push!` then advances to two **named, unrelated** next walls (§5).

---

## 1. Probe transcripts (evidence)

All probes run **strictly serially, one Julia process at a time**; `pgrep -af julia`
clean before the first run. Scratch prefix `p7B_`.

### 1.1 P1 — reproduce the wall at HEAD; which body fails, and why the ROOT

```
=== P1a: extract_parsed_ir_set_from_julia(_push40ys, Tuple{Int64}; ptr_cells=true) ===
ERRTYPE: ErrorException
MSG: julia_set.jl: … extraction FAILED for callee `#_growend!##0#a7027856`
     (callable=Tuple{Base.var"#_growend!##0#_growend!##1"{Vector{Int64},…,MemoryRef{Int64}}},
      argtypes=Tuple{}) — ir_extract.jl: sret struct field 0 has type
      LLVM.PointerType(ptr) in @julia_#_growend!##0_1191; only fixed-width integer
      bits-struct fields are supported (… — Bennett-dv1z).
```

The **SET path fails on the CLOSURE first** (it is extracted before the root in the
registration loop) — via the *callee-side* path (`_detect_sret`, the closure genuinely
*has* an `sret` param).

The root fails too, but through the **other** path — pinned precisely:

```
=== P1c: extract_parsed_ir(_push40ys, Tuple{Int64}; ptr_cells=true) ===
ROOT MSG: ir_extract.jl: sret struct field 0 has type LLVM.PointerType(ptr)
          in @julia__push40ys_2404; only fixed-width integer bits-struct fields …
  @ _sret_struct_fields(st, func)                      at sret.jl:151
  @ _collect_consumed_sret(func, names, counter, ptr_cells, forwarding_suppressed)
                                                        at sret.jl:1224
  @ _module_to_parsed_ir_on_func(…)                     at module_walk.jl:331
```

**Answer to "why does a root returning `Int64` hit an sret wall":** it does *not* have
an sret param. It hits the **caller-side 416r.16 consumed-sret recognizer**, which
validates the *call-site* `sret` pointee of its call to the outlined closure. So
`_sret_struct_fields` is reached from **both** sides, and the fix must be gated on
`ptr_cells` at **both** call sites (plus `_emit_cell_call`'s validation, sret.jl is
called from instructions.jl:2722).

`transitive_callees` for the root (P1b), for reference:

```
typeof(Base.throw_boundserror)  Tuple{Vector{Int64}, Tuple{Int64}}
Type{BoundsError}               Tuple{Any, Tuple{Int64}}
Base.var"#_growend!##0#_growend!##1"{…}   Tuple{}          ← the closure
Type{ConcurrencyViolationError} Tuple{String}
typeof(Core.throw_inexacterror) Tuple{Symbol, Type, Int64}
Type{InexactError}              Tuple{Symbol, Any, Vararg{Any}}
```

### 1.2 P2 — the closure's LLVM form and what it stores

**Optimisation level actually used.** `extract_parsed_ir_set_from_julia` defaults
`optimize=false`, and `extract_parsed_ir_by_sig` → `_parsed_ir_from_ir_string` shares
every pass step with `extract_parsed_ir`. So bodies are walked at **O0**, then
`_parsed_ir_from_ir_string` **auto-prepends `["sroa","mem2reg"]`** whenever
`_module_has_sret(mod)` (entry.jl:96-105). Verified:

```
p7B_closure_optfalse.ll  module_has_sret=true    ← SROA/mem2reg DO run
p7B_root_optfalse.ll     module_has_sret=false   ← they do NOT (only a call-site sret)
```

That asymmetry matters: the **callee** is walked post-SROA, the **caller** on raw O0 IR.

Closure signature (O0, verbatim; 4 params exactly as the bead predicted):

```llvm
define void @"julia_#_growend!##0_986"(
    ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %sret_return,
    ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %return_roots,
    ptr nocapture noundef nonnull readonly align 8 dereferenceable(72) %"#self#::#_growend!##0#_growend!##1",
    ptr nocapture readonly %".roots.#self#") #0
```

Only `%sret_return` carries the `sret` attribute. `%return_roots` carries **no
distinguishing attribute** — it is an ordinary pointer parameter as far as LLVM is
concerned.

The return-value block, **pre-SROA** (O0):

```llvm
L93:
  store { ptr, ptr } %memory_ref12, ptr %2, align 8
  call void @julia.write_barrier(ptr %2, ptr %memoryref_mem)
  store { ptr, ptr } %memory_ref12, ptr %0, align 8
  %68 = getelementptr inbounds i8, ptr %0, i32 0
  %69 = getelementptr inbounds i8, ptr %sret_return, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %69, ptr align 8 %68, i64 8, i1 false)   ; ← field 0
  %70 = getelementptr inbounds i8, ptr %0, i32 8
  %71 = load ptr, ptr %70, align 8
  %72 = getelementptr inbounds i8, ptr %return_roots, i32 0
  store ptr %71, ptr %72, align 8                                                       ; ← the GC ROOT
  %73 = getelementptr inbounds i8, ptr %sret_return, i32 8
  store i64 -1, ptr %73, align 8                                                        ; ← SENTINEL
  ret void
```

and the **same block post-`sroa,mem2reg`** (i.e. what the extractor actually walks):

```llvm
L93:
  store { ptr, ptr } %memory_ref12, ptr %1, align 8
  call void @julia.write_barrier(ptr %1, ptr %memoryref_mem)
  %memory_ref12.fca.0.extract = extractvalue { ptr, ptr } %memory_ref12, 0
  %memory_ref12.fca.1.extract = extractvalue { ptr, ptr } %memory_ref12, 1
  %67 = getelementptr inbounds i8, ptr %sret_return, i32 0
  store ptr %memory_ref12.fca.0.extract, ptr %67, align 8     ; ← store PTR into field 0
  %68 = getelementptr inbounds i8, ptr %return_roots, i32 0
  store ptr %memory_ref12.fca.1.extract, ptr %68, align 8     ; ← the GC root, out-param
  %69 = getelementptr inbounds i8, ptr %sret_return, i32 8
  store i64 -1, ptr %69, align 8                              ; ← i64 into a PTR-typed field
  ret void
```

**Two conclusions that shape the whole design:**

1. The memcpy-into-field form (which `_try_handle_sret_padding_memcpy!` would reject
   loud as "overlaps field bytes") **never reaches the collector** — SROA turns it into
   a scalar `store ptr`. So no memcpy work is needed. (Do **not** design for the
   pre-SROA form; it is unreachable on this path.)
2. Julia stores an **`i64` into a `ptr`-typed field** (the `-1` sentinel). Any
   implementation that requires the store's LLVM *type* to match the field's LLVM
   *type* re-walls `push!` immediately. The match must be on **width only**.

**What the CALLER does with the box.** In `_push40ys` (raw O0):

```llvm
%0        = alloca { ptr, ptr }, align 8
%sret_box = alloca [2 x i64], align 8      ← the sret-out box
%1        = alloca ptr,        align 8      ← the return_roots buffer
%2        = alloca ptr, i32 3, align 8      ← the ".roots.#self#" array (3 roots)
…
call void @"j_#_growend!##0_1049"(ptr … sret({ ptr, ptr }) %sret_box,
                                  ptr … %1, ptr … %"new::#_growend!##0…", ptr … %2)
%33 = getelementptr inbounds i8, ptr %1, i32 0
%34 = load ptr, ptr %33, align 8            ← reads return_roots[0] … and %34 is DEAD
```

`grep` over the whole module: `%sret_box` has **exactly two occurrences** (its
`alloca` and the call). The root **never reads the sret box** — it is a write-only
dead buffer. `%34` has exactly one occurrence (its own definition). So the push! root
is the *dead-box* caller sub-case (§2.3(b)).

**The reassembly convention, proven.** The `jfptr_#_growend!##0_987` jlcall wrapper in
the same module shows how a caller that *does* use the value puts it back together:

```llvm
call void @"julia_#_growend!##0_986"(ptr … sret({ptr,ptr}) %sret_box, ptr … %0, …)
%19 = getelementptr inbounds i8, ptr %0, i32 0
%20 = load ptr, ptr %19, align 8                                  ; ← from return_roots
%"box::GenericMemoryRef" = call … @julia.gc_alloc_obj(…, i64 16, …)
%22 = getelementptr inbounds i8, ptr %sret_box, i32 0
%23 = getelementptr inbounds i8, ptr %"box::GenericMemoryRef", i32 0
call void @llvm.memcpy.p0.p0.i64(ptr align 8 %23, ptr align 8 %22, i64 8, i1 false)  ; field 0 ← sret+0
%24 = getelementptr inbounds i8, ptr %"box::GenericMemoryRef", i32 8
store atomic ptr %20, ptr %24 unordered, align 8                  ; field 1 ← return_roots[0]
ret ptr %"box::GenericMemoryRef"
```

`%sret_box+8` — the slot holding the `-1` sentinel — is **never read**. This is the
ground truth for §3.

### 1.3 P3 — synthetic minimal fixtures that wall identically at HEAD

```julia
struct P3A; p::Ptr{Int64}; a::Int64; b::Int64; end
@noinline _mk3a(x::Int64)  = P3A(Ptr{Int64}(x), x + 1, x + 2)
_use3a(x::Int64)           = (r = _mk3a(x); r.a + r.b)
@noinline _mk3b(m::Memory{Int64}) = memoryref(m, 1)
_use3b(m::Memory{Int64})   = (r = _mk3b(m); @inbounds r[])
```

emitted signatures:

```
mk3a  define void @julia__mk3a_91(ptr … sret({ ptr, i64, i64 }) … %sret_return, i64 signext %"x::Int64")
mk3b  define void @julia__mk3b_138(ptr … sret({ ptr, ptr }) … %sret_return,
                                   ptr … %return_roots, ptr … %"m::GenericMemory")
```

and at HEAD, all four wall on the **identical** message:

```
mk3a  ERR: … sret struct field 0 has type LLVM.PointerType(ptr) … Bennett-dv1z
use3a ERR: … sret struct field 0 has type LLVM.PointerType(ptr) … Bennett-dv1z
mk3b  ERR: … sret struct field 0 has type LLVM.PointerType(ptr) … Bennett-dv1z
use3b ERR: … sret struct field 0 has type LLVM.PointerType(ptr) … Bennett-dv1z
```

`ptr_cells=false` control (proves the gate is meaningful — a *different* wall):

```
mk3a  (ptr_cells=false) ERR: … Bennett-dv1z                      (unchanged)
use3a (ptr_cells=false) ERR: call to 'j__mk3a_465' has no registered callee handler
                              … (Bennett-5oyt / U15)             ← never reaches sret at all
```

`_mk3a` turned out to be a *poor* fixture: `Ptr{Int64}(x)` emits
`inttoptr i64 %x to ptr`, which walls at the pre-existing **Bennett-iwo9** guard once
the sret arms are patched (§1.4). The **fixed** fixture takes the pointer as a
parameter, so no `inttoptr` appears:

```julia
struct P3C; p::Ptr{Int64}; a::Int64; end
@noinline _mk3c(p::Ptr{Int64}, x::Int64) = P3C(p, x + 1)
_use3c(p::Ptr{Int64}, x::Int64)          = (r = _mk3c(p, x); r.a + 1)
```

```
mk3c  define void @julia__mk3c_72(ptr … sret({ ptr, i64 }) … %sret_return,
                                  ptr %"p::Ptr", i64 signext %"x::Int64")
        store ptr %"p::Ptr", ptr %1
        store i64 %0,        ptr %2
        call void @llvm.memcpy(… %sret_return, … %"new::P3C", i64 16, i1 false)
```

`_mk3c`/`_use3c` is the **exit-criterion fixture** — see §6. Note the pointer is never
dereferenced, so its VM cell value is arbitrary and the native oracle
(`_use3c(Ptr{Int64}(0), 5) == 7`) is exactly reproducible on the VM.

### 1.4 P4 — next walls, via throwaway in-memory monkey-patch

Two `@eval Bennett` redefinitions in a scratch session (**no `src/` file touched**):
`_sret_struct_fields` (ptr → 64) and `_try_handle_sret_scalar_store!` (ptr value → 64).

```
=== with ONLY _sret_struct_fields patched ===
CLOSURE ERR: sret store at byte offset 0 has non-integer value type
             LLVM.PointerType(ptr); only integer stores are supported
   @ _try_handle_sret_scalar_store!   at sret.jl:647     ← the SECOND arm, proven necessary
ROOT ERR:    store { ptr, ptr } %memory_ref, ptr %"new::Array" — store of non-integer
             type LLVM.StructType({ ptr, ptr }) not supported (Bennett-lgzx / U114)

=== with BOTH arms patched ===
mk3c   OK ret_width=128 elems=[64, 64] args=[(p::Ptr,64), (x::Int64,64)]
use3c  OK ret_width=64  elems=[64]
mk3b   OK ret_width=128 elems=[64, 64] args=[(:return_roots,64), (m::GenericMemory,128)]
use3b  OK ret_width=64  elems=[64]
mk3a   ERR: inttoptr … not a recognised Julia type-tag value (Bennett-iwo9)   ← fixture artefact
root_push ERR: store { ptr, ptr } … (Bennett-lgzx / U114)
CLOSURE   ERR: load of an UNRECOGNIZED Julia JIT global `@"jl_diverror_exception"`
               … (bennettvm-416r.13)
SET use3c OK:  _use3c#ed42daaf (ret 64) + _mk3c#c354b10f (ret 128, elems=[64,64])
```

Extracted ParsedIR for the three key fixtures (verbatim):

```
===== mk3c =====   ret_width=128 elems=[64,64] args=[(p::Ptr,64),(x::Int64,64)]
 [top]
   IRBinOp(:__v1, :add, ssa(x::Int64), Const(1), 64)
   IRInsertBits(:__v5, ZERO_AGG,   ssa(p::Ptr), 0,  64, 128)
   IRInsertBits(:__v6, ssa(:__v5), ssa(:__v1),  64, 64, 128)
   TERM: IRRet(ssa(:__v6), 128)

===== use3c =====  ret_width=64 elems=[64]
 [top]
   IRCall(:__v1, :j__mk3c_4839, [ssa(p::Ptr), ssa(x::Int64)], [64,64], 128)
   IRExtractValue(:sret_box.a_ptr.unbox, ssa(:__v1), 1, 0, 2, [64,64])
   IRBinOp(:__v2, :add, ssa(:sret_box.a_ptr.unbox), Const(1), 64)
   TERM: IRRet(ssa(:__v2), 64)

===== mk3b =====   ret_width=128 elems=[64,64] args=[(:return_roots,64),(m::GenericMemory,128)]
 [idxend]
   IRExtractValue(:memory_ref3.fca.0.extract, ssa(:memory_ref3), 0, 0, 2, [64,64])
   IRExtractValue(:memory_ref3.fca.1.extract, ssa(:memory_ref3), 1, 0, 2, [64,64])
   IRPtrOffset(:__v18, ssa(:return_roots), 0, 8)
   IRStore(ssa(:__v18), ssa(:memory_ref3.fca.1.extract), 64)      ← return_roots, verbatim
   IRInsertBits(:__v23, ZERO_AGG,    ssa(:memory_ref3.fca.0.extract), 0,  64, 128)
   IRInsertBits(:__v24, ssa(:__v23), Const(-1),                       64, 64, 128)  ← sentinel
   TERM: IRRet(ssa(:__v24), 128)
```

`use3c`'s shape is **exactly** the value ABI BennettVM's guard-5 ingests
(`IRCall.ret_width == sum(callee.ret_elem_widths)` — 128 == 64+64). `mk3b` shows the
`return_roots` split modelled verbatim, with no special handling.

---

## 2. The design

### 2.1 Admission arm 1 — `_sret_struct_fields`, gated

Add a `ptr_cells::Bool=false` keyword and factor the per-field width decision into one
total classifier:

```
_sret_field_width(fty, k, fname, dl, ptr_cells) -> Int
  IntegerType, width ∈ {8,16,32,64}      → that width
  PointerType && ptr_cells               → 64          (ADR 0018 §A: one address cell)
  everything else                        → the EXISTING error text, VERBATIM
```

Non-negotiables of this arm:

* **Message preservation.** Under `ptr_cells=false` the emitted string is
  byte-identical to today's (`"only fixed-width integer bits-struct fields are
  supported (pointer/float/nested-struct/vector fields are rejected — Bennett-dv1z)"`).
  Five test files pin it and all five call the extractor **without** `ptr_cells`
  (§7.2), so they stay green with zero edits.
* **Under `ptr_cells=true`, only `PointerType` is newly admitted.** Float, vector,
  nested-struct and bad-width integer fields keep the same message with an added
  clause naming that pointer fields *are* admitted under the gate (so a future agent
  reading the message knows the gate exists). `test_xrd6`'s three reject fixtures
  (`{i64,float}`, `{i7}`, `{half,i8}`) run **with** `ptr_cells=true` and must stay red
  — none of them uses a pointer field, verified (§7.2).
* **Address space check (Rule 1).** Reject `PointerType` with a non-zero address space
  loud, naming the space. Every sret pointee observed in the corpus prints as plain
  `ptr` (addrspace 0); admitting `addrspace(10)`/`(11)` — Julia's GC-tracked spaces —
  would be a guess about a shape we have not seen.
* **Pointer size asserted, never assumed (Rule 5/10).** The 64 comes from the VM cell
  model, but the *target* must agree: assert the module datalayout's pointer size is 8
  bytes and fail loud otherwise. On a 32-bit datalayout the field offsets computed by
  `LLVMOffsetOfElement` would no longer be 8-byte-strided and a hardcoded 64 would
  silently mis-pack.

The homogeneous `[N x iM]` arm (`_detect_sret` lines 93-106) is **left untouched** —
`[N x ptr]` still rejects. Deliberate: no corpus evidence for it (all four probed
shapes are `StructType`), and Rule 9 forbids speculative admission. Documented as such
so it does not read as an oversight.

### 2.2 Admission arm 2 — `_try_handle_sret_scalar_store!`, gated (PROVEN NECESSARY)

Thread `ptr_cells` from `_collect_sret_writes` (which already has it) into the scalar
store handler, and widen the value-type triage:

```
vt isa IntegerType                → sw = width(vt)
vt isa PointerType && ptr_cells   → sw = 64
otherwise                         → the EXISTING message, VERBATIM
```

Then, **critically**, keep the existing field match on **width only** (`sw == fw`) and
add a comment explaining *why* a type match would be wrong: Julia stores
`i64 -1` into a `ptr`-typed field as the GC-root placeholder (§1.2, §3). A type-equality
check re-walls `push!` on the very next instruction.

Operand resolution: under the gate use `_operand(val, names; ptr_cells=true)` so a
`store ptr null` becomes the zero cell (the `test_beaw_null_ptr` precedent) rather
than crashing; under `ptr_cells=false` keep the current call byte-identical.

The SLP vector-store arm is already gated off for heterogeneous structs (sret.jl:788)
— unchanged.

### 2.3 Caller side — no structural change, three sub-cases enumerated

`_collect_consumed_sret` (416r.16) already carries `ptr_cells`; it needs only to pass
it to `_sret_struct_fields`. Probes confirm every downstream computation already does
the right arithmetic for 64-bit ptr fields:

* `field_widths = [w for (_,w) in fields]` → `[64,64]`;
* `ret_width = sum(field_widths)` → **128** (was 72 for `{i64,i8}`);
* `module_walk.jl:181-182` derives `ret_elem_widths=[64,64]`, `ret_width=128` for the
  callee — so caller and callee agree, which is precisely guard-5's discriminator.

**(a) Box read back** (`_use3c`, `setindex!`): the existing path. Field reads become
`IRExtractValue(dest, ssa(agg), k, 0, 2, [64,64])`. Proven in §1.4.

**(b) Box never read** (the `push!` root — `%sret_box` has zero reader uses): the
use-walk records no `field_reads`, so `_consumed_sret_active` is false and the
`_apply_consumed_sret_loads!` post-pass no-ops — but `call_rewrites` *is* still applied
unconditionally (`module_walk.jl:496`) and the box `alloca` is suppressed. Net effect:
the call becomes `IRCall(dest, callee, …, ret_width=128)` whose 2-slot family nothing
reads. This is **correct and should be kept as-is** (dead slot-family Defines are
harmless and reversible), but it is a shape no test currently pins — §7.1 test 6 pins
it with a `.ll` fixture, because it is the shape the P0 chain actually hits.

**(c) Forwarding** (`_try_handle_sret_memcpy_reject!`, Wall A/B): no corpus instance of
a forwarded ptr-field aggregate, and no change needed — the Wall-B padding classifier's
field-range math (`foff … foff + fw ÷ 8`) is correct for `fw = 64`, and the Wall-A
`ret_width` already uses `sum(field widths)`. Left untouched; covered by a `.ll`
regression fixture (§7.1 test 9) so it cannot silently rot.

### 2.4 Gate threading

`_sret_struct_fields` is reached from exactly three sites; all three must pass the gate
explicitly (no global, no default-true):

| site | file:line | gate value |
|---|---|---|
| `_detect_sret(func)` | sret.jl:109 ← module_walk.jl:171 | thread a new `ptr_cells` kwarg through `_detect_sret` from `_module_to_parsed_ir_on_func` |
| `_collect_consumed_sret` | sret.jl:1224 | already in scope |
| `_emit_cell_call` | instructions.jl:2722 | literal `true` (the function is the `ptr_cells` cell-ABI arm by construction) |

Every new keyword defaults to `false`. `_collect_sret_writes` already takes
`ptr_cells::Bool=false` positionally — pass it down to the store handler.

---

## 3. `return_roots` — verdict, with evidence

**Verdict: model it verbatim as an ordinary 64-bit pointer out-parameter. No
detection, no fusion, no rejection.**

### What it actually is (§1.2)

When a returned aggregate contains a GC-tracked field, Julia's codegen splits the
return in two:

* the **sret buffer** carries the untracked words, and the slot corresponding to each
  tracked field is filled with the literal sentinel `i64 -1`;
* the **`return_roots` buffer** (an ordinary `ptr` param with no attribute) receives
  the tracked object pointers;
* **the caller reassembles.** Proven by the jlcall wrapper: field 0 of the boxed
  `GenericMemoryRef` is memcpy'd from `sret_box+0`, field 1 is `store`d from
  `load return_roots[0]`, and `sret_box+8` (the `-1`) is never read.

### Why "do nothing" is the *correct* model, not a compromise

Because the caller's own IR performs the reassembly, modelling both halves verbatim is
**exact**. The VM's sret aggregate genuinely holds `-1` in that slot — so does the real
machine. The VM's `return_roots` cell genuinely holds the root — so does the real
machine. Nothing is lost.

P6 proves it works with zero code: `mk3b` extracts with
`args=[(:return_roots, 64), …]` and emits `IRStore(IRPtrOffset(return_roots,0), …, 64)`
— an ordinary cell store, because under `ptr_cells` a `ptr` param *is* a cell and
`store ptr` *is* a 64-bit cell store (ADR 0020 D3/D4). No new machinery at all.

### Why fusion is rejected (Rule 9)

The tempting "fix" is to recognise the split and replace the `-1` in sret slot *k* with
`return_roots[j]`. The IR provides **no explicit k↔j mapping** — it would have to be
inferred from sentinel-store detection plus roots-store ordering. That is a heuristic
sitting directly on a returned-pointer value; getting it backwards is a silent
miscompile of a pointer. Explicitly out of scope, and §7.1 test 5 pins the *unfused*
shape so a future agent's "helpful" fusion turns a test red.

### Residual hazard, stated honestly

A consumer that reads the sentinel field of a consumed sret box gets `-1`. This is
faithful (the machine reads `-1` too), so it is not a miscompile — but it is
surprising. Mitigation is documentation + the pinning test, **not** a guard: any guard
would have to guess which fields are sentinels, which is the same guess as fusion.

### The other two closure params

`#self#` (the captured-state struct) and `.roots.#self#` (the GC-root array) are
ordinary readonly pointer params, already carried as cells (`_cell_call_args`) and
already read via `IRPtrOffset` + `IRLoad`. No 7wsz work. Confirmed by `mk3b`'s clean
extraction and by the closure advancing past all four params to a body wall (§5).

---

## 4. Semantics on the VM, and determinism

**What a ptr sret field carries.** The same thing every other pointer cell carries: a
64-bit arena address in the BennettVM model (ADR 0018 §A) — or the `-1` sentinel
constant, or a pointer parameter forwarded through unchanged. This is not a new value
class; it is an existing value class in a new *position* (a return slot rather than an
argument, a load result, or a store operand).

**Determinism (the klgz floor), argued explicitly.**

1. *Provenance.* A returned pointer's value is produced by machinery whose determinism
   is already the standing assumption for ptr cells: the arena allocator, a forwarded
   parameter, or a constant. Returning it neither creates addresses nor observes them.
2. *Observability.* An address only becomes non-deterministic *data* if it enters
   integer arithmetic or hashing. Both routes are already walled:
   `ptrtoint`/`inttoptr` outside the type-tag round-trip is rejected (Bennett-iwo9 /
   6bu3 — fired live on `_mk3a`, §1.4), and identity hashing of an allocation address
   is the klgz floor's named non-deterministic construct. Neither is reachable *through*
   this change; 7wsz adds no new escape route.
3. *Control flow.* No new branch depends on a returned address. (`mk3b`'s bounds
   comparisons are on pointer *differences* through the pre-existing ptr-cell path, not
   new to this bead.)

**Reversibility.** BennettVM lowers each aggregate field to its own Int64 slot via
non-injective `Define` copies, reversed by L3 checkpoint-replay — its own source says
so for the `{i64,i8}` case, and the mechanism is width-independent (§5.2). A 128-bit
aggregate is two such slots. No new reversibility obligation; the contract is the one
`{i64,i8}` already carries.

**One genuinely new VM behaviour** (flagged, not proven by these probes): with
`return_roots`, a callee **stores through a caller-provided pointer cell**, so the
callee's write must be visible to the caller after `ReturnExit` and must `unrun!`
correctly. Arena stores are already reversible in BVM, and the Dict corpus already
mutates callee-visible state through a passed cell — but this specific shape is
untested. It is a **risk item (R5)**, and the exit criterion deliberately does *not*
depend on it: the E2E fixture (`_mk3c`/`_use3c`) has no `return_roots` at all.

---

## 5. Next walls (P4) — enumerated, not fixed

Measured with both arms patched (§1.4). None of these is in 7wsz's scope.

1. **`push!` ROOT** — `store { ptr, ptr } %memory_ref, ptr %"new::Array"`:
   whole-struct store, **Bennett-lgzx / U114**. From `Array` construction (writing the
   `MemoryRef` into the Array header), entirely unrelated to sret.
2. **`_growend!` CLOSURE** — `load ptr, ptr @jl_diverror_exception`: unrecognised Julia
   JIT global under `ptr_cells`, **bennettvm-416r.13**. Comes from the `div` in the
   growth-factor computation.
3. **Forecast beyond those** (scout, 2026-08-03; not reached by these probes):
   `jl_genericmemory_copy_slice` / allocation intrinsics inside the closure body.
4. **Fixture trap, not a product wall** — `Ptr{Int64}(x)` emits `inttoptr` and walls at
   **Bennett-iwo9**. Any 7wsz fixture must take its pointer as a *parameter*
   (`_mk3c`), not construct one from an integer.

Consequence for the bead's success criterion: after 7wsz, `push!` still does not
extract — it advances from *one* wall to *two named different* walls, which is exactly
the wall-by-wall progression the xkl chain has been following (xrd6 → u2kk → 8g7m).

---

## 6. Scope and exit criterion

**In scope**
1. `_sret_struct_fields`: ptr field → 64-bit cell, gated on `ptr_cells=true`.
2. `_try_handle_sret_scalar_store!`: `store ptr` into an sret field, same gate.
3. Threading `ptr_cells` into `_detect_sret` / `_collect_sret_writes` / the store
   handler; `true` at `_emit_cell_call`.
4. Address-space and pointer-size assertions.

**Out of scope (fails loud, unchanged)**
homogeneous `[N x ptr]`; float/vector/nested-struct/bad-width fields; non-zero
addrspace; the pre-SROA memcpy-into-field form (unreachable — §1.2); any `return_roots`
fusion; every wall in §5.

**Exit criterion**

* **E1 (extraction, PROVEN reachable by P6).**
  `extract_parsed_ir_set_from_julia(_use3c, Tuple{Ptr{Int64},Int64}; ptr_cells=true)`
  returns 2 bodies: `_use3c` (`ret_width=64`) and `_mk3c` (`ret_width=128`,
  `ret_elem_widths=[64,64]`), with the exact `IRInsertBits` / `IRExtractValue` shapes
  in §1.4 pinned.
* **E2 (VM round-trip, honestly runnable).** That set lowers and runs on BennettVM to
  the native oracle `_use3c(Ptr{Int64}(0), 5) == 7`, `unrun!`s to the exact initial
  state with empty history, at L2 **and** L3, with per-step inverse — the
  `test_40ys_closure_callee_vm.jl` template. Runnable because the pointer is never
  dereferenced, so its cell value is arbitrary and arena-independent.
* **E3.** `push!` advances to the §5 walls; `test_40ys` gate (I) flips to the new names.
* **E4.** `ptr_cells=false` byte-identical: gate-count regression **39/39**, full
  `Pkg.test()` green with the pre-existing 3 Broken unchanged.
* **E5.** Zero BennettVM `src/` changes (§8).

---

## 7. Test plan (RED-GREEN)

### 7.1 New — Bennett.jl `test/test_7wsz_ptr_sret_fields.jl`

Write these **before** the implementation and watch each go red.

1. **Callee-side admission.** `_mk3c` under `ptr_cells=true` →
   `ret_width == 128`, `ret_elem_widths == [64,64]`, and the exact 2-link
   `IRInsertBits(ZERO_AGG→…, bit_offsets 0,64, val_widths 64,64, total 128)` chain.
   *(RED at HEAD: dv1z message.)*
2. **Caller-side admission.** `_use3c` under `ptr_cells=true` → one
   `IRCall(…, ret_width=128)` + `IRExtractValue(dest, ssa(agg), 1, 0, 2, [64,64])`,
   original load dest name preserved.
3. **THE GATE.** Both fixtures with `ptr_cells=false` must **still** throw with
   `"only fixed-width integer bits-struct fields"` **and** `"Bennett-dv1z"`
   (byte-identical message). This is the Rule-6 firewall.
4. **Still-rejected shapes under `ptr_cells=TRUE`** (inline `.ll`, `_xrd6_reject`
   style): `{i64,float}`, `{i64,<2 x i32>}`, `{i64,{i8,i8}}`, `{i7}` — each keeps the
   dv1z breadcrumb. Plus `{ptr addrspace(10), i64}` → the new addrspace message.
5. **ANTI-FUSION PIN (`return_roots`).** `_mk3b` under `ptr_cells=true` →
   `:return_roots` appears in `pir.args` at width 64; the block contains an `IRStore`
   through it; and the sret chain contains
   `IRInsertBits(_, _, ConstOperand(-1), 64, 64, 128)`. Comment: *this test exists so a
   future "helpful" fusion of return_roots into the sret aggregate goes red.*
6. **Dead-box caller** (the `push!`-root shape, `.ll` fixture): an sret-out call whose
   box has no reader uses still rewrites to `ret_width = Σ field widths` and suppresses
   the box alloca.
7. **Width-only field match.** `store i64 -1` into a `ptr`-typed field is ACCEPTED;
   `store i32 %x` into a `ptr`-typed field REJECTS with the partial-field message.
8. **Null ptr field.** `store ptr null` into a ptr field resolves to the zero cell
   (`_operand(…; ptr_cells=true)`), not a crash.
9. **Forwarding regression.** A `.ll` fixture forwarding an sret `{ptr,i64}` through a
   parent sret keeps `ret_width = 128` and the Wall-B padding classifier unchanged.
10. **Set path (E1).** `extract_parsed_ir_set_from_julia(_use3c, …; ptr_cells=true)`
    yields exactly the two expected canonical keys.

### 7.2 Existing tests — audit result

**Stay green with no edit** (all call the extractor *without* `ptr_cells`, so the gate
keeps them on the reject path — verified by reading each call site):

| file | site | why unaffected |
|---|---|---|
| `test_dv1z_hetero_sret.jl:104` | `_dv1z_reject("ret_ptr_field", sret({i64,ptr}))` via `extract_parsed_ir_from_ll` (no kwarg) | `ptr_cells=false` |
| `test_0zsk_core_error_paths.jl:157` | `sret_ptr_field` `.ll` via `extract_parsed_ir_from_ll` (no kwarg) | `ptr_cells=false` |
| `test_land_ptrfield_struct.jl:299` | Rust `HashMap::new` via `extract_parsed_ir_from_ll` (no kwarg) | `ptr_cells=false` |
| `test_xrd6_sret_consumed_call.jl:194-222` | three rejects **with `ptr_cells=true`** | fields are `float` / `i7` / `half` — **no pointer field**, so still red |
| `test_sret.jl`, `test_0c8o_vector_sret.jl`, `test_59zi_*`, `test_q04a_*` | circuit path | `ptr_cells=false` |

**Must FLIP (do not delete — the file says so itself):**

* `test_40ys_instanceless_callees.jl` gate **(I)** (≈ lines 418-432) asserts
  `occursin("sret", msg) && occursin("Bennett-dv1z", msg)` for the `push!` set. It goes
  red by design. Replace with an **occursin-disjunction over BOTH §5 walls**
  (`"lgzx"`/`"U114"` for the root, `"416r.13"`/`"jl_diverror_exception"` for the
  closure) — **not** a single message, because which body fails first depends on the
  registration/iteration order, which is not a contract (this is the `test_lf14`
  landing-message convention).
* `test_40ys_instanceless_callees.jl` gate **(J)** (the `:skip` known-gap, ≈ lines
  466-480) asserts `length(out) == 2` and two specific throw helpers. Both bodies still
  wall (at different walls), so the count likely holds — but it **must be re-derived by
  running it**, never assumed.

**Must be RE-RUN (the u2kk lesson / the standing `cwd-ptr-cells-rerun-lf14` rule)** —
any `ptr_cells` extraction change can shift which wall a real function lands on:
`test_lf14_ptr_return_cells.jl` (its occursin-disjunctions are the most fragile),
then the ptr_cells real-fn set — `test_xrd6`, `test_416r16`, `test_416r17`,
`test_416r12`, `test_416r13`, `test_59zi`, `test_d1b_julia_set`, `test_klgz`,
`test_iwo9`, `test_6bu3`, `test_tu6i`, `test_nd45`, `test_haiy`, `test_8g7m`,
`test_beaw`, `test_yd4f`, `test_u2kk` (33 files reference `ptr_cells`; run all of them).

**Gates:** full `Pkg.test()` (expect ~690 k Pass / 3 Broken, ~29 min under
`JULIA_NUM_THREADS=32`) + gate-count regression **39/39** + BennettVM full `Pkg.test()`.

### 7.3 New — BennettVM.jl `test/test_7wsz_ptr_sret_vm.jl`

Mirrors `test_40ys_closure_callee_vm.jl` exactly: ingest the `_use3c`/`_mk3c` set,
`lower_vm`, run to the native oracle, `unrun!` to exact initial state, empty history,
L2 **and** L3, per-step inverse. Plus a static assertion that the callee's
`FunctionEntry` has `ret_elem_widths == [64,64]` and `length(returns) == 2` (the
guard-5 discriminator). **Expect zero BennettVM `src/` changes** — if a BVM src edit
becomes necessary, that is a signal the front-end shape drifted from the value ABI, not
a licence to patch BVM.

---

## 8. BennettVM impact: what BVM sees, and why no src change

After this bead BVM receives, for a ptr-field sret callee:

```
ParsedIR.ret_width       = 128
ParsedIR.ret_elem_widths = [64, 64]
callee body: IRInsertBits(ZERO_AGG, v0, 0, 64, 128) → IRInsertBits(agg, v1, 64, 64, 128) → IRRet(_, 128)
caller body: IRCall(dest, callee, args, widths, 128) → IRExtractValue(dest, ssa(agg), k, 0, 2, [64,64])
```

Every consumer already handles it, checked in BVM source:

* `ingest_multi.jl` `_declared_returns` keys on `length(parsed.ret_elem_widths)` → 2 →
  the `_agg_slot_name` family. Arity, not width.
* `ingest_body.jl` guard-5 discriminator is `inst.ret_width == sum(fe.ret_elem_widths)`
  → `128 == 128` → value ABI, slot family lands. (The failure branch is the
  *unreconciled sret_box* message — not reached.)
* `ingest.jl` `IRInsertBits` lowering states it outright: *"Each field lives in its OWN
  Int64 cell, so `total_width > 64` (72 here) is a NON-issue: the packed value is NEVER
  materialised, only the per-field scalars are."* 128 = 2 × 64 is the same case as 72 =
  64 + 8. It also enforces ZERO_AGG-rooted ascending-contiguous chains, which
  `_synthesize_sret_bits` produces unchanged.
* `IRInsertBits` with a `ConstOperand(-1)` value (the sentinel) goes through
  `_lower_operand`, which handles constants.
* Bennett-side `IRInsertBits`'s only width invariant is
  `bit_offset + val_width <= total_width` (ir_types.jl:192) — `64 + 64 <= 128` holds.

So the two-bead streak of **zero BVM src changes** (416r.16, 40ys) is preserved
honestly, not by contortion.

---

## 9. Risk register

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| **R1** | **Fusion temptation** — a later agent "fixes" the `-1` sentinel by splicing `return_roots` into the sret aggregate, guessing the slot pairing. Silent pointer miscompile. | **High** | §7.1 test 5 pins the unfused shape; a `# SEMANTICS` block in sret.jl records the jfptr-wrapper evidence; §3 states the rejection and why. |
| **R2** | Gate leakage into `ptr_cells=false` — `_detect_sret` gains a kwarg threaded from module_walk; a missed default flips the circuit path. | High | Every new kwarg defaults `false`; §7.1 test 3 is the firewall; gate-count 39/39 is the tripwire. |
| **R3** | Only arm 1 implemented (the bead text names only `_sret_struct_fields`) → `push!` re-walls one instruction later at the store handler, and the bead ships "done" but broken. | **High** | §1.4 proves arm 2 is required; §7.1 test 1 fails without it. **This is the single most likely way to get 7wsz wrong.** |
| **R4** | Type-equality field match instead of width-only → `store i64 -1` into a `ptr` field rejects, re-walling `push!`. | High | §7.1 test 7 pins both directions. |
| **R5** | `return_roots` write-through-caller-cell across a VM call is untested (visibility after `ReturnExit`; `unrun!`). | Medium | Exit criterion deliberately uses the roots-free `_mk3c` fixture; the roots fixture is extraction-only. File a successor bead for the VM half. |
| **R6** | `test_40ys` gate (I) re-pinned to a single message; the first-failing body depends on iteration order → flaky. | Medium | Pin an occursin-**disjunction** over both §5 walls (the `test_lf14` convention). |
| **R7** | Dead-box caller (push! root) emits a 128-bit aggregate dest nothing reads; untested on the VM. | Medium | §7.1 test 6 pins the extraction shape; BVM behaviour is dead Defines (harmless), noted not proven. |
| **R8** | Hardcoded 64 wrong on a non-64-bit datalayout; field offsets from `LLVMOffsetOfElement` would disagree. | Low | Assert datalayout pointer size == 8 bytes, fail loud (§2.1). |
| **R9** | Non-zero addrspace pointer fields appear later and now reject where they might be legitimate. | Low | Accepted: fail loud > silent. Message names the addrspace so the successor bead is obvious. |
| **R10** | `[N x ptr]` homogeneous asymmetry reads as an oversight to a future agent. | Low | Explicit docstring note + a reject test with the rationale in the comment. |
| **R11** | `test_lf14` occursin-disjunctions no longer cover a shifted landing message. | Low | Standing rule: re-run lf14 + the 33 `ptr_cells` files (§7.2). |

---

## 10. What I would tell the implementer in one paragraph

Thread a `ptr_cells` gate into `_detect_sret` and `_collect_sret_writes`, admit
`PointerType` sret fields as 64-bit cells in `_sret_struct_fields` **and** `store ptr`
into an sret field in `_try_handle_sret_scalar_store!` — both arms, or `push!` walls one
instruction later. Match stores to fields on **width only** (Julia stores `i64 -1` into
a `ptr` field). Touch nothing on the `return_roots` path: it is an ordinary pointer
out-parameter and already works. Keep the `ptr_cells=false` error strings byte-identical
so the five files pinning them need no edit. Prove it on `_mk3c`/`_use3c` end-to-end
(extraction here, VM round-trip in BennettVM), then re-point `test_40ys` gate (I) at the
two new walls with a disjunction, and re-run `test_lf14` plus every `ptr_cells` file.
