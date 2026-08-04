# Bennett-7wsz — Proposal A (design proposer A, blind)

**Bead**: Bennett-7wsz (P1, CORE 3+1) — ptr-typed sret struct fields under
`ptr_cells=true`. Successor to closed Bennett-dv1z; THE named wall for
`bennettvm-xkl` (P0) after Bennett-40ys.

**Repo state**: Bennett.jl `main` @ `5e3df43`, Julia 1.12.3, LLVM.jl `fEIbx`.
All probes run serially, one Julia process at a time, scratch prefix `p7A_`.

**Author's one-line thesis**: this is a *one-predicate* capability change
(`_sret_struct_fields` admits `PointerType` as a 64-bit cell **under
`ptr_cells=true` only**), plus threading that gate to two store/detect sites.
The scary-looking `return_roots` parameter turns out to need **no new
machinery at all** — probe-proven — and BennettVM needs **zero src changes**.

---

## 0. Executive summary

| Question | Answer (evidence: §1–§3) |
|---|---|
| Mechanism | `_sret_struct_fields(st, func; ptr_cells)` admits `LLVM.PointerType` fields at **width 64** (ADR 0018 §A: a pointer is one Int64 VM cell). Gated; `ptr_cells=false` byte-identical. |
| Callee side | `_detect_sret` gains the gate; `_try_handle_sret_scalar_store!` accepts a `store ptr` into a ptr field at width 64 and resolves the value with `_operand(...; ptr_cells)`. `_synthesize_sret_bits` needs **no change** (it reads `fields[k][2]`). |
| Caller side | `_collect_consumed_sret` needs **only** the gate on its `_sret_struct_fields` call; `_emit_cell_call` likewise. `ret_width` goes 72 → 128 / 192; the ABI discriminator `ret_width == sum(ret_elem_widths)` still holds on both sides. |
| `return_roots` | **NOT dead, NOT specially modelled.** It is an ordinary pointer out-parameter: `_cell_call_args` already carries it as a 64-bit cell, the callee's write is an ordinary `IRStore`, the caller's read an ordinary `IRLoad`. Probe-proven end-to-end (§3.3). The matching sret slot legitimately carries Julia's `i64 -1` sentinel, and modelling that faithfully is *correct*, not a miscompile. |
| BVM impact | **Zero src changes.** guard-5's discriminator is `inst.ret_width == sum(fe.ret_elem_widths)`; 128 == 128. The `IRInsertBits` arm already documents `total_width > 64` as a non-issue (per-field Int64 slot families). One verification item, §6 R4. |
| Next walls (after 7wsz) | ROOT `push!`: U114 `store { ptr, ptr }` aggregate store. Closure body: unrecognized JIT global `@jl_diverror_exception` under `ptr_cells`. Then the scout's forecast (`jl_genericmemory_copy_slice`, alloc). §5. |
| Biggest risk | Accidentally un-gating the circuit path. `_detect_sret` is called **unconditionally** at `module_walk.jl:171` and currently has **no `ptr_cells` parameter** — an ungated patch silently changes `ptr_cells=false` behaviour (probe-demonstrated, §3.4). §7 R1. |

---

## 1. Probe P1 — reproducing the wall, and pinning *which* path fires

Canonical repro (matches `test/test_40ys_instanceless_callees.jl:418`):

```julia
_push40ys(n::Int64) = (v = Int64[]; push!(v, n); @inbounds v[1])
```

`scratchpad/p7A_probe2.jl`:

```
=== P1a: SET, default (fail-loud) ===
WALL: julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
  `#_growend!##0#a7027856` (callable=Tuple{Base.var"#_growend!##0#_growend!##1"{
  Vector{Int64}, Int64, Int64, Int64, Int64, Int64, Memory{Int64}, MemoryRef{Int64}}},
  argtypes=Tuple{}) — ir_extract.jl: sret struct field 0 has type LLVM.PointerType(ptr)
  in @julia_#_growend!##0_1178; only fixed-width integer bits-struct fields are supported
  (pointer/float/nested-struct/vector fields are rejected — Bennett-dv1z).

=== P1c: ROOT alone (no mem kwarg) ===
  ptr_cells=false : WALL: … call to 'julia.get_pgcstack' … (Bennett-5oyt / U15)
  ptr_cells=true  : WALL: ir_extract.jl: sret struct field 0 has type LLVM.PointerType(ptr)
                    in @julia__push40ys_2919; … (Bennett-dv1z)
```

Both bodies wall, as the bead states. **Why the root — which returns an
`Int64` and has no sret parameter of its own — hits an sret wall** was the
open question. Stacktrace (`p7A_probe3.jl`), definitive:

```
 [2] _sret_struct_fields(...)              @ src/extract/sret.jl:151
 [3] _collect_consumed_sret(...)           @ src/extract/sret.jl:1224
 [4] _module_to_parsed_ir_on_func(...)     @ src/extract/module_walk.jl:331
```

So the ROOT fires the **caller-side 416r.16 consumed-sret** path: it makes an
sret-out call to the closure, `_collect_consumed_sret` inspects the *call
site's* `sret` pointee (`{ptr,ptr}`) and routes it through
`_sret_struct_fields`. The CLOSURE fires the **callee-side** path
(`_detect_sret` → `_sret_struct_fields`, `module_walk.jl:171`). Same
predicate, two entry points — which is why the fix is genuinely one-predicate.

Note the ordering: `_collect_consumed_sret` runs at `module_walk.jl:331`,
*before* the block walk, so the root dies before any instruction is converted.
`ptr_cells=false` never reaches it (`_collect_consumed_sret` returns
`_empty_consumed_sret()` on line 1167) and dies earlier at the U15 pgcstack
wall — the existing circuit-path behaviour.

---

## 2. Probe P2 — the closure's actual ABI (Rule 9: probed, not guessed)

### 2.1 Which optimisation level the by-sig path uses

`transitive_callees` harvests edges at `optimize=true` (`callgraph.jl:67`);
**bodies are extracted at `optimize=false`** (`julia_set.jl:331-332`,
`extract_parsed_ir_by_sig(sig; optimize=false)` at `julia_set.jl:460`). Both
levels probed below; the design targets O0, and O2 is used only as
corroboration of semantics.

### 2.2 Callee signature (O0, `_code_llvm_by_sig(Tuple{CT})`)

```llvm
define void @"julia_#_growend!##0_1836"(
    ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %sret_return,
    ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %return_roots,
    ptr nocapture noundef nonnull readonly align 8 dereferenceable(72) %"#self#::#_growend!##0#_growend!##1",
    ptr nocapture readonly %".roots.#self#") #0 {
```

Four `ptr` params. Only param 1 carries `sret`; **`return_roots` carries no
attribute that distinguishes it from any other pointer out-parameter** (`noalias
nocapture noundef nonnull align 8 dereferenceable(8)` — the same attribute set
a plain out-pointer gets). That is not an accident; §3.3 shows it is not one.

### 2.3 What the callee STORES into the sret buffer — the load-bearing find

O0, block `L93` (the only sret-store block; `p7A_clo_O0.ll:220-233`):

```llvm
L93:
  store { ptr, ptr } %memory_ref12, ptr %2                  ; write-barrier'd store into the Array
  call void (ptr, ...) @julia.write_barrier(ptr %2, ptr %memoryref_mem)
  store { ptr, ptr } %memory_ref12, ptr %0                  ; spill the aggregate to a local
  %68 = getelementptr inbounds i8, ptr %0, i32 0
  %69 = getelementptr inbounds i8, ptr %sret_return, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %69, ptr align 8 %68, i64 8, i1 false)  ; sret field 0
  %70 = getelementptr inbounds i8, ptr %0, i32 8
  %71 = load ptr, ptr %70
  %72 = getelementptr inbounds i8, ptr %return_roots, i32 0
  store ptr %71, ptr %72                                    ; ← the TRACKED ptr goes to return_roots
  %73 = getelementptr inbounds i8, ptr %sret_return, i32 8
  store i64 -1, ptr %73                                     ; ← sret field 1 = SENTINEL -1
  ret void
```

At O2 the same thing, unobscured (`p7A_clo_O2.ll:140-143`):

```llvm
store ptr %memoryref_data21, ptr %sret_return       ; field 0 = the DATA pointer
store ptr %memoryref_mem,    ptr %return_roots      ; the GC-TRACKED mem pointer
%25 = getelementptr inbounds i8, ptr %sret_return, i64 8
store i64 -1, ptr %25                               ; field 1 = -1
```

**Provenance of the fields**: field 0 is a *freshly derived* data pointer
(`getelementptr i8, %memoryref_data, %memoryref_byteoffset` off the possibly-newly-allocated
`Memory`), not a copied-through old pointer. The `mem` pointer is the
GC-tracked object.

### 2.4 What the CALLER does with the box

Root at O0 (`p7A_root_O0.ll:96-99`), and — decisively — the minimal synthetic
`caller_f2` (`p7A_F2-caller_caller_f2.ll`):

```llvm
%sret_box = alloca [2 x i64], align 8
%0        = alloca ptr, align 8
call void @llvm.memset.p0.i64(ptr align 8 %0, i8 0, i64 8, i1 false)
call void @j_mkref_1642(ptr … sret({ ptr, ptr }) %sret_box, ptr … %0, ptr %"v::Array")
%1              = getelementptr inbounds i8, ptr %0, i32 0
%memoryref_mem  = load ptr, ptr %1                 ; ← field 1 read FROM return_roots
%memory_ref_FCA0 = load ptr, ptr %sret_box         ; ← field 0 read FROM the sret box
%2 = insertvalue { ptr, ptr } zeroinitializer, ptr %memory_ref_FCA0, 0
%3 = insertvalue { ptr, ptr } %2, ptr %memoryref_mem, 1     ; ← the aggregate REASSEMBLED
```

The caller literally reconstitutes the `MemoryRef` as
`{sret_box[0], return_roots[0]}`. The `-1` in sret slot 1 is **never read by
anyone**. (In the specific `push!` root, `%sret_box` is never read at all and
the `return_roots` load `%34` is dead — the root re-reads the `Array`'s own
fields afterwards. Verified: `grep '%34'` yields one hit, the definition.)

---

## 3. Probe P3 — minimal synthetic fixtures, and the design they force

### 3.1 F1 — a genuine ptr sret field, **no** `return_roots` (the clean unit)

```julia
struct PB3; p::Ptr{Int64}; a::Int64; b::Int64; end
@noinline mk3(p::Ptr{Int64}, a::Int64) = PB3(p, a, a + 1)
callee_f1(p::Ptr{Int64}, a::Int64) = (r = mk3(p, a); r.a + r.b)
```

`Ptr{Int64}` is a bitstype ⇒ untracked ⇒ **no `return_roots` parameter**.
24 bytes ⇒ forced through sret. Callee and caller (O0):

```llvm
define void @julia_mk3_110(ptr … sret({ ptr, i64, i64 }) align 8 dereferenceable(24) %sret_return,
                           ptr %"p::Ptr", i64 signext %"a::Int64") {
top:
  %"new::PB3" = alloca { ptr, i64, i64 }
  … three stores …
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %sret_return, ptr align 8 %"new::PB3", i64 24, i1 false)
  ret void }

define i64 @julia_callee_f1_280(ptr %"p::Ptr", i64 signext %"a::Int64") {
top:
  %sret_box = alloca [3 x i64]
  call void @j_mk3_282(ptr … sret({ ptr, i64, i64 }) %sret_box, ptr %"p::Ptr", i64 signext %"a::Int64")
  %sret_box.a_ptr = getelementptr inbounds i8, ptr %sret_box, i32 8
  %sret_box.b_ptr = getelementptr inbounds i8, ptr %sret_box, i32 16
  … add … ret }
```

At HEAD both wall **identically** to `push!`:

```
F1-callee mk3        ptr_cells=true  : WALL: sret struct field 0 has type LLVM.PointerType(ptr) … Bennett-dv1z
F1-caller callee_f1  ptr_cells=true  : WALL: sret struct field 0 has type LLVM.PointerType(ptr) … Bennett-dv1z
```

so F1 is a faithful, `push!`-independent unit fixture for **both** sides
(§8 T1/T2). It is also honestly VM-runnable: `mk3` never dereferences `p`, so
the cell value passes through and the observable result is `2a+1`.

### 3.2 F2 — the `{ptr,ptr}` MemoryRef shape with `return_roots`

```julia
@noinline mkref(v::Vector{Int64}) = Base.memoryref(v.ref, 1)
caller_f2(v::Vector{Int64})       = (r = mkref(v); @inbounds r[])
```

`mkref` emits *exactly* the closure's 2-param prefix
(`sret({ptr,ptr}) %sret_return, ptr … %return_roots, …`) and `caller_f2` the
call-site shape of §2.4. Both wall identically at HEAD. **Caveat**: `mkref`'s
*callee body* has a follow-on `ptrtoint`-of-`GenericMemory`-`.data` wall
(Bennett-iwo9/klgz, §5), so F2's callee half is a *wall-advance* fixture, not
an extract-clean one. F2's **caller** half extracts clean (§3.3).

### 3.3 The hand-built `.ll` that settles `return_roots` (the decisive probe)

`p7A_probe6.jl` writes a minimal two-function module mirroring §2.3/§2.4
exactly — sret `{ptr,ptr}` with the `-1` sentinel, a `return_roots` out-pointer,
and a caller that reads all three places — and extracts it with the admission
patch applied in-memory:

```llvm
define void @rr_callee(ptr … sret({ ptr, ptr }) align 8 dereferenceable(16) %sret_return,
                       ptr … dereferenceable(8) %return_roots, ptr %data, ptr %mem) {
top:
  store ptr %data, ptr %sret_return
  store ptr %mem,  ptr %return_roots
  %g = getelementptr inbounds i8, ptr %sret_return, i64 8
  store i64 -1, ptr %g
  ret void }

define i64 @rr_caller(ptr %data, ptr %mem) {
top:
  %box = alloca [2 x i64]
  %rr  = alloca ptr
  call void @rr_callee(ptr … sret({ ptr, ptr }) %box, ptr … %rr, ptr %data, ptr %mem)
  %f0 = load i64, ptr %box
  %g1 = getelementptr inbounds i8, ptr %box, i64 8
  %f1 = load i64, ptr %g1
  %r0 = load i64, ptr %rr
  %s  = add i64 %f0, %r0
  %s2 = add i64 %s, %f1
  ret i64 %s2 }
```

Result:

```
rr_callee ptr_cells=true  : OK ret_width=128 rew=[64, 64] args=[(:return_roots, 64), (:data, 64), (:mem, 64)]
      IRStore(SSAOperand(:return_roots), SSAOperand(:mem), 64)
      IRInsertBits(:__v5, ZERO_AGG,       SSAOperand(:data),  0, 64, 128)
      IRInsertBits(:__v6, SSAOperand(:__v5), ConstOperand(-1), 64, 64, 128)
      TERM IRRet(SSAOperand(:__v6), 128)

rr_caller ptr_cells=true  : OK ret_width=64 rew=[64] args=[(:data, 64), (:mem, 64)]
      IRAlloca(:rr, 64, ConstOperand(1))
      IRCall(:__v1, :rr_callee, [SSAOperand(:rr), SSAOperand(:data), SSAOperand(:mem)], [64, 64, 64], 128)
      IRExtractValue(:f0, SSAOperand(:__v1), 0, 0, 2, [64, 64])
      IRExtractValue(:f1, SSAOperand(:__v1), 1, 0, 2, [64, 64])
      IRLoad(:r0, SSAOperand(:rr), 64)
      IRBinOp(:s, :add, :f0, :r0, 64)
      IRBinOp(:s2, :add, :s, :f1, 64)
      TERM IRRet(SSAOperand(:s2), 64)

rr_callee ptr_cells=false : WALL: store of non-integer type LLVM.PointerType(ptr) … (Bennett-lgzx / U114)
rr_caller ptr_cells=false : WALL: call to 'rr_callee' has no registered callee handler … (U15)
```

Everything the design needs is visible here:

* **`return_roots` needs no machinery.** It is excluded from nothing and
  special-cased nowhere: the callee sees it as arg 1 of its `args` list (the
  sret param having been excluded), writes it with a plain `IRStore(…, 64)`;
  the caller allocates it with a plain `IRAlloca(:rr, 64, 1)`, passes it as a
  plain 64-bit cell arg, and reads it back with a plain `IRLoad(…, 64)`. The
  existing `_cell_call_args` (ADR 0018 §A) already does all of it.
* **Caller/callee arg lists agree exactly**: caller passes
  `[rr, data, mem]`; callee params are `[return_roots, data, mem]`.
* **The ABI discriminator holds**: caller `ret_width=128`, callee
  `sum(ret_elem_widths) = 64+64 = 128`.
* **The `-1` sentinel is modelled faithfully** as `ConstOperand(-1)` in field 1.
* **`ptr_cells=false` rejects, loudly, unchanged.**

### 3.4 The counter-probe that proves the gate is mandatory

The in-memory patch in `p7A_probe5.jl` was deliberately **ungated**. Result:

```
F1-callee mk3   ptr_cells=false: OK nblk=1 ret_width=192     ← REGRESSION: must stay a reject
```

An ungated `_sret_struct_fields` silently admits ptr sret fields into the
**circuit** path, where a pointer has no cell semantics and pointer args are
*dropped* from `ParsedIR.args`. This is exactly the class of silent-wrong the
project forbids. **The gate is not stylistic; it is a correctness requirement.**
(See §7 R1.)

---

## 4. The design

### 4.1 D1 — the admission predicate (`src/extract/sret.jl`)

```julia
function _sret_struct_fields(st::LLVM.StructType, func::LLVM.Function;
                             ptr_cells::Bool=false)
    …unchanged packed / empty rejects…
    for (k, fty) in enumerate(elem_tys)
        w = if fty isa LLVM.IntegerType
                Int(LLVM.width(fty))
            elseif ptr_cells && fty isa LLVM.PointerType
                # Bennett-7wsz: under the cell gate a pointer IS one 64-bit VM
                # cell (ADR 0018 §A) — the same model ptr params / ptr returns /
                # ptr loads+stores already use. Reject a non-default address
                # space: the cell model is flat addrspace-0 only.
                LLVM.addrspace(fty) == 0 || _error(…"addrspace $(…)"… "Bennett-7wsz")
                64
            else
                error(<EXISTING dv1z message>, plus, when !ptr_cells and
                      fty isa PointerType, the clause:
                      "pointer fields are admitted as 64-bit cells only under
                       ptr_cells=true (Bennett-7wsz)")
            end
        w ∈ (8,16,32,64) || error(<EXISTING width message>)
        push!(fields, (Int(LLVM.offsetof(dl, st, k-1)), w))
    end
    …
```

Non-negotiable: the **existing message substrings stay byte-identical** on the
`ptr_cells=false` path — `"only fixed-width integer bits-struct fields"` and
`"Bennett-dv1z"` are pinned by four test files (§8).

Byte offsets remain LLVM-datalayout ground truth (`LLVM.offsetof`), never
`index * width` — a `{ptr, i8, i64}` has padding just like `{i64, i8}`.

### 4.2 D2 — gate plumbing (three call sites, all already have or can get it)

| Site | Today | Change |
|---|---|---|
| `_detect_sret(func)` → `sret.jl:109` | **no** `ptr_cells` param; called unconditionally at `module_walk.jl:171` | add `ptr_cells::Bool=false` param; `module_walk.jl:171` passes the in-scope `ptr_cells` |
| `_collect_consumed_sret` → `sret.jl:1224` | already takes `ptr_cells`; early-returns when false | pass `; ptr_cells=ptr_cells` (literally `true` there, but pass it explicitly) |
| `_emit_cell_call` → `instructions.jl:2722` | reached **only** under `ptr_cells` (both call sites at `instructions.jl:3168`/`3208` gate it) | pass `; ptr_cells=true`, with a comment naming the structural gate |

### 4.3 D3 — callee-side write collection

`_try_handle_sret_scalar_store!` (`sret.jl:640`) gains `ptr_cells::Bool`
(threaded from `_collect_sret_writes`, which already receives it at
`module_walk.jl:319`). Two edits:

```julia
sw = if vt isa LLVM.IntegerType
         Int(LLVM.width(vt))
     elseif ptr_cells && vt isa LLVM.PointerType
         64                                    # Bennett-7wsz
     else
         _ir_error(inst, <EXISTING non-integer-store message>)
     end
…
slot_values[slot] = _operand(val, names; ptr_cells=ptr_cells)   # was: _operand(val, names)
```

The `_operand` kwarg is **load-bearing, not cosmetic**: a `store ptr null`
into an sret field (the C/Julia field-init idiom) resolves to `iconst(0)`
only under `ptr_cells` (Bennett-beaw, `helpers.jl:187-197`); without the kwarg
it hits the U80 `ConstantPointerNull` fail-loud. `ptr_cells=false` passes
`false` ⇒ byte-identical.

**Deliberately UNCHANGED** (scope control):

* the **homogeneous** `[N x iM]` arm of `_detect_sret` — LLVM has no
  `[N x ptr]` Julia sret shape in the corpus; leaving it rejecting is free.
* `_try_handle_sret_vector_store!` — already gated off for hetero
  (`sret.jl:788`).
* `_try_handle_sret_padding_memcpy!` — the overlap reject stays **strict**.
  Its field byte-ranges come from `sret_info.fields`, so ptr fields
  automatically occupy 8 bytes; no code change. The O0 8-byte
  `memcpy(sret+0, %0+0, 8)` of §2.3 *does* overlap field 0 and *would* reject —
  but the Bennett-uyf9 auto-SROA prepend (`entry.jl:98-105`, fires because
  `_module_has_sret(mod)`) canonicalises it into a `store ptr` first.
  **Probe-confirmed**: both the closure and `mk3` (whose O0 form is a 24-byte
  whole-aggregate memcpy) produced clean `IRInsertBits` chains, §5.

### 4.4 D4 — caller-side (416r.16) consumed / forwarded sret

No structural change beyond D2. What *changes numerically*:

* `field_widths = [w for (_, w) in fields]` now contains 64s for ptr fields.
* `ret_width = sum(field_widths)`: 72 (`{i64,i8}`) → **128** (`{ptr,ptr}`) or
  **192** (`{ptr,i64,i64}`).
* `_apply_consumed_sret_loads!`'s width assertion
  (`inst.width == field_widths[fidx+1]`) still holds: under `ptr_cells` a
  `load ptr` lowers to `IRLoad(…, 64)` (ADR 0020 D3/D4), and a `load i64` off a
  ptr field is also 64. Both forms probe-confirmed (`caller_f2` uses
  `load ptr, ptr %sret_box`; `rr_caller` uses `load i64`).
* **Zero-field-read boxes are already handled.** The `push!` root's `%sret_box`
  is never read (§2.4). `field_reads` stays empty for it, `call_rewrites` is
  non-empty, the box alloca is suppressed, and the block walk substitutes the
  value-ABI `IRCall` at `module_walk.jl:496`. `_consumed_sret_active` is false
  ⇒ the post-pass is a no-op, which is correct (there is nothing to rewrite and
  `keys(field_reads)` is empty so the dangling guard would iterate nothing
  anyway). **No change; do not "fix" the predicate** — it would be inert and
  is blast radius for nothing.

The **forwarding** recognizer (`_try_handle_sret_memcpy_reject!`, Bennett-59zi)
needs no edit: its `ret_width` derivation already branches on
`sret_info.is_hetero` and sums `fields`. Its P6 predicate compares
`callee_agg == sret_info.agg_type` — LLVM type identity, unaffected.

### 4.5 D5 — `return_roots`: modelled as an ordinary out-pointer. VERDICT + EVIDENCE

**Verdict: no special handling. Not dropped, not rejected, not part of the
return aggregate.**

The reasoning, with the evidence chain:

1. `return_roots` carries **no `sret` attribute** (§2.2), so
   `_detect_sret` never claims it, `_collect_consumed_sret` never claims the
   caller's `%rr` alloca (it only scans calls whose *param-index-1* operand
   carries `sret`), and `_cell_call_args`'s `skip_sret` elision (which is
   attribute-driven, Rule 5) never elides it.
2. Under `ptr_cells` it is therefore just another `PointerType` operand ⇒ one
   64-bit cell (`_cell_call_args`, `instructions.jl:2480-2483`).
3. The callee's write is a plain `store ptr %v, ptr %return_roots` — an ordinary
   `IRStore(…, 64)` on the D3/D4 cell path. The caller's read is a plain
   `IRLoad(…, 64)`. **Probe-proven in §3.3.**
4. **The `i64 -1` in the matching sret slot is faithful, not lossy.** The
   hardware puts `-1` there; every real caller reconstitutes the tracked field
   from `return_roots` (§2.4 shows Julia doing exactly that). Emitting
   `IRInsertBits(…, ConstOperand(-1), 64, 64, 128)` reproduces the machine
   semantics exactly. A design that tried to "repair" slot 1 from
   `return_roots` would be *less* faithful and would require cross-module
   knowledge the caller does not have (the caller sees only
   `declare void @f(ptr sret({ptr,ptr}), ptr, ptr, ptr)` — nothing in the LLVM
   tells it which sret slot is the sentinel one; the trackedness lives in Julia
   types, not in the emitted IR, and the addrspace is 0 for all four params).
   **This is the design's single most important negative decision.**
5. `.roots.#self#` (param 4) is the mirror image on the *input* side — a
   caller-allocated `alloca ptr, i32 3` GC-root buffer that the callee reads
   with const-offset GEPs. Same treatment: an ordinary cell arg, ordinary
   loads. Nothing in 7wsz touches it. (It is *not* dead: the closure reads its
   `a` / `ref` / `mem` pointers out of it — `p7A_clo_O0.ll:29-34`. Under the
   cell/arena model those loads read cells the caller wrote, which is the
   correct data-flow.)

**Falsification test** (§8 T5): a fixture where the sret slot's `-1` *is*
read back would expose an unfaithful model. `rr_caller` does exactly that
(`%f1 = load i64, ptr %g1`) and yields `IRExtractValue(:f1, agg, 1, …)` ⇒ the
VM value must be `-1`. Pin it.

### 4.6 D6 — downstream widths

`_synthesize_sret_bits` is unchanged and already correct: it packs
`fields[k][2]`-bit fields at contiguous bit offsets, `W = sum(widths)`.
Probe output for `mk3`:

```
IRInsertBits(:__v6, ZERO_AGG,     SSAOperand("p::Ptr"),  0, 64, 192)
IRInsertBits(:__v7, ssa(:__v6),   SSAOperand("a::Int64"),64, 64, 192)
IRInsertBits(:__v8, ssa(:__v7),   SSAOperand(:__v1),    128, 64, 192)
IRRet(ssa(:__v8), 192)
```

ascending-contiguous, ZERO_AGG-rooted — exactly the invariant BVM's
`IRInsertBits` arm asserts (`ingest.jl:801-855`).

---

## 5. Probe P4 — what the NEXT wall is (enumerated, not fixed)

With the admission patched in-memory (`p7A_probe5.jl`, ungated — so ignore its
`ptr_cells=false` rows, see §3.4):

| Body | Outcome with ptr sret fields admitted |
|---|---|
| `mk3` (F1 callee) | **extracts clean** — `ret_width=192`, `rew=[64,64,64]`, 1 block |
| `callee_f1` (F1 caller) | **extracts clean** — `ret_width=64`, consumed-sret rewrite fires |
| `caller_f2` (F2 caller, `{ptr,ptr}` + return_roots) | **extracts clean** — `ret_width=64` |
| `rr_callee` / `rr_caller` (hand-built `.ll`) | **extract clean**, §3.3 |
| **ROOT `_push40ys`** | advances; next wall = `store { ptr, ptr } %memory_ref, ptr %"new::Array"` — *"store of non-integer type LLVM.StructType({ ptr, ptr }) not supported (**Bennett-lgzx / U114**)"* |
| **CLOSURE body** (by-sig) | advances; next wall = `load ptr, ptr @jl_diverror_exception` — *"load of an **UNRECOGNIZED Julia JIT global** `@"jl_diverror_exception"` (a `constant ptr` whose load returns a pointer) under ptr_cells"* (the 416r.13 wall; klgz classifier recognises only `+<Type>#N` type tags and `jl_global#N` empty-GenericMemory singletons) |
| **full SET on `push!`** | fails at the closure with the same `@jl_diverror_exception` wall |
| `mkref` (F2 callee) | `ptrtoint` of a `GenericMemory` `.data` base under ptr_cells (**Bennett-iwo9 / klgz** determinism guard) |

**Next-wall list for the bead's "advances to the next named wall" criterion,
in dependency order:**

1. **W1** — closure: `@jl_diverror_exception` unrecognized JIT global
   (`constant ptr` load) under `ptr_cells`. *This is what `push!` lands on.*
2. **W2** — root: U114 `store { ptr, ptr }` (whole-aggregate store of a
   `MemoryRef` into the `Array` object).
3. **W3** — (forecast, beyond W1/W2) `jl_genericmemory_copy_slice` /
   `jl_alloc_genericmemory_unchecked` / `llvm.memmove` / `gc_preserve_begin`
   inside the closure body — the scout's 2026-08-03 forecast; the closure's
   `declare` set confirms all four are present.
4. **W4** — `ptrtoint` of a `GenericMemory` `.data` base (Bennett-iwo9/klgz)
   — hit by `mkref`, likely also by the closure once W1/W3 clear.

**None of these are in 7wsz's scope.** File them; do not fix them.

---

## 6. BennettVM impact: ZERO src changes (one verification item)

* **guard-5** (`src/ir/ingest_body.jl:395-420`) discriminates purely on
  `inst.ret_width == sum(fe.ret_elem_widths)`. Callee `ret_elem_widths=[64,64]`
  ⇒ 128; caller `IRCall.ret_width=128`. Lands the multi-key
  `_agg_slot_name` family. The historical `64 ≠ 72` failure mode was a
  *mismatch*, never a width cap.
* **`IRInsertBits`** (`src/ir/ingest.jl:801-855`) explicitly documents
  `total_width > 64` as a non-issue: "each field lives in its OWN Int64 cell …
  the packed value is NEVER materialised". 128/192 are fine.
* **`IRExtractValue`** slot-copy arm (`ingest.jl:780-800`) reads
  `_agg_slot_name(agg, k)` — index-driven, width-agnostic.
* **`FunctionEntry.ret_elem_widths`** is copied verbatim from
  `parsed.ret_elem_widths` by `ingest_multi.jl`; `returns` arity 2/3 ⇒ the
  multi-key path.
* **`return_roots`** rides as an ordinary SSA cell arg; ADR 0023 already removed
  the `allunique(args)` guard, and `CallEnter` COPY-read semantics carry it.
* **`IRAlloca(:rr, 64, ConstOperand(1))`** contributes to `frame_size` like any
  other static alloca.

**R4 (must verify, cheap)**: the callee's `IRInsertBits` field-1 value is a
`ConstOperand(-1)`, not an SSA name. BVM lowers it as
`Define(_agg_slot_name(dest, k), _lower_operand(inst.val), :add, 0)`;
`_lower_operand(::ConstOperand) -> Int64` (`ingest_operands.jl:29-30`) and
`Define`'s source is `Union{Symbol,Int64}`, so this *should* be a plain
const-create. **Verify with an actual `rr_callee` VM round-trip before
claiming zero-BVM-change** (§8 T7). If it does not hold, the front-end
mitigation is local and known: materialise the sentinel via a synthetic
const-create instruction before the `IRInsertBits`, mirroring
`_call_const_arg_name` (`ingest.jl:855+`) — but do that in **BVM**, not by
distorting the Bennett.jl emission.

---

## 7. Semantics, determinism, reversibility

**What value does a ptr sret field carry on the VM?** The same thing every
other pointer cell carries: an **arena address** in BennettVM's flat,
deterministic bump-allocated address space (ADR 0018 §A). A ptr sret field is
not a new kind of value — it is the identical value class as (a) a `ptr`
function *argument* (`_cell_call_args`, long-established), (b) a `ptr`
*return* (`ret_width = 64`, ADR 0020 D3, `module_walk.jl:190-200`), and (c) a
`ptr` load/store (D3/D4). 7wsz merely lets that value class appear in a *field*
of an aggregate return, where it previously could appear only as the whole
return.

**Determinism (the klgz floor), argued explicitly rather than assumed.** The
determinism floor (ADR 0015 Decision 3; `constexpr.jl:178-210`) is about values
whose *bit pattern depends on the host allocator*, e.g. `objectid` hashing a
real heap address. BVM's arena is a **deterministic bump allocator**: for a
fixed program and fixed inputs, the sequence of allocations — and therefore
every address value — is a pure function of the execution history. So an
address *returned* by a function is deterministic, replayable, and safe to
compare/store. Returning it in a struct field does not change that: the field
is a copy of a cell that was already deterministic.

The klgz/iwo9 guards remain intact and are *not* weakened by this bead: they
fire on `ptrtoint` of a `GenericMemory` `.data` base escaping into arithmetic,
and on identity-hash GOT stubs — both are about *consuming* an address as
data. 7wsz never introduces a `ptrtoint`; it moves an already-modelled cell
through an aggregate. Probe corroboration: `mkref` still walls at exactly the
iwo9 `ptrtoint` guard *after* the admission (§5), i.e. the guard is untouched.

**Reversibility.** The emitted shapes are ones BVM already reverses: an
`IRInsertBits` slot family is a set of non-injective `Define` copies reversed by
L3 checkpoint-replay (documented at `ingest.jl:818-830`); `IRExtractValue` is a
slot copy; `IRStore`/`IRLoad` on cells are the existing memory model;
`CallEnter`/`ReturnExit` are unchanged. No new irreversible primitive is
introduced. The `ConstOperand(-1)` const-create is the same idiom φ-incoming
constants and alloca pointers already use.

---

## 8. Test plan (RED-GREEN, CLAUDE.md Rule 3)

### 8.1 Bennett.jl — new file `test/test_7wsz_ptr_sret_fields.jl` (register in `runtests.jl`)

All fixtures are LOCAL — none depends on `Base.var"#_growend!##..."` naming.

| # | Test | RED at HEAD | GREEN after |
|---|---|---|---|
| **T1** | `mk3` (F1 callee) `extract_parsed_ir(...; ptr_cells=true)` ⇒ `ret_width == 192`, `ret_elem_widths == [64,64,64]`, terminator `IRRet(_, 192)`, the `IRInsertBits` chain is ZERO_AGG-rooted ascending-contiguous with `bit_offset ∈ (0,64,128)` | walls `Bennett-dv1z` | extracts |
| **T2** | `callee_f1` (F1 caller) ⇒ one `IRCall(_, _, _, _, 192)`, two `IRExtractValue(_, agg, 1|2, 0, 3, [64,64,64])`, box alloca absent from every block | walls `Bennett-dv1z` | extracts |
| **T3** | **GATE (the load-bearing negative)**: `mk3` and `callee_f1` with `ptr_cells=false` still throw, message `occursin("only fixed-width integer bits-struct fields")` **and** `occursin("Bennett-dv1z")` | passes (reject) | **must still pass** |
| **T4** | hand-built `.ll` `rr_callee` (§3.3) via `extract_parsed_ir_from_ll(...; ptr_cells=true)` ⇒ `ret_width==128`, `rew==[64,64]`, `args==[(:return_roots,64),(:data,64),(:mem,64)]`, contains `IRStore(ssa(:return_roots), ssa(:mem), 64)`, field 1 is `ConstOperand(-1)` | walls | extracts |
| **T5** | hand-built `rr_caller` ⇒ `IRCall(…, [rr,data,mem], [64,64,64], 128)`; `IRExtractValue(:f0,…,0,…)` **and** `IRExtractValue(:f1,…,1,…)` (the sentinel IS readable); `IRLoad(:r0, ssa(:rr), 64)` present; **caller arg names == callee param names** | walls | extracts |
| **T6** | fail-loud preservation under `ptr_cells=true`: `.ll` fixtures with a **float** field, an **i7** field, a **nested-struct** field, a **vector** field, an **addrspace(11) ptr** field, and a **packed** `<{ptr,i8}>` — each still errors with its named breadcrumb (`Bennett-dv1z` / `Bennett-7wsz`) | new | new |
| **T7** | `store ptr null` into an sret ptr field (`.ll`) ⇒ field value `ConstOperand(0)` under `ptr_cells=true` (pins the `_operand(...; ptr_cells)` thread of D3); still rejects under `ptr_cells=false` | new | new |
| **T8** | **wall-advance marker** (the bead's exit criterion): `extract_parsed_ir_set_from_julia(_push7wsz, Tuple{Int64}; ptr_cells=true)` throws, and the message does **NOT** contain `"Bennett-dv1z"`/`"sret struct field"`, and **DOES** name the closure key and one of the W1/W2/W3 markers (`occursin`-disjunction: `"jl_diverror_exception"` \|\| `"UNRECOGNIZED Julia JIT global"` \|\| `"StructType"` \|\| `"genericmemory"` \|\| `"memmove"`). Comment it as a wall marker that flips green-to-different-green as later beads land. | asserts `dv1z` today | flips |

### 8.2 Existing tests — audited, with the flip list

Grepped for the pinned message text across `test/`:

| File | Uses | Verdict |
|---|---|---|
| `test_dv1z_hetero_sret.jl:105` "reject sret({i64, ptr}) — pointer field" | `extract_parsed_ir_from_ll(path; entry_function=…)` — **`ptr_cells` defaults to false** (`entry.jl:230`) | **GREEN unchanged** (the gate) |
| `test_0zsk_core_error_paths.jl:140-158` non-integer sret struct field | same, default `ptr_cells=false` | **GREEN unchanged** |
| `test_land_ptrfield_struct.jl:298-310` (T5 Rust `HashMap::new`) | `from_ll`, default false; accepts `:dv1z_sret_reject` | **GREEN unchanged** — its comment even anticipates the flip ("Flips to `:compiled` when ptr-field-struct sret support lands"). **Do not flip it in this bead**; the T5 corpus is a `ptr_cells=false` path. |
| `test_xrd6_sret_consumed_call.jl:188-247` bad sret pointee shapes **under ptr_cells** | float / i7 / half / bare-i64 pointee — **no ptr-field case** | **GREEN unchanged**; T6 extends the same style with the new arms |
| `test_40ys_instanceless_callees.jl:418-431` gate (I) | asserts `occursin("sret", e.msg) && occursin("Bennett-dv1z", e.msg)` | **MUST FLIP** — update to the W1/W2 disjunction, keeping the "not an `UndefRefError`" and "names the closure key" assertions. The file's own header (lines 62-71) documents this as the intended signal. |
| `test_40ys_instanceless_callees.jl:460-475` `:skip` known-gap testset | expects 2 walled bodies | re-check: the count should be unchanged (both still wall, at W1/W2) — **verify, do not assume** |
| `test_sret.jl`, `test_jghk`, `test_59zi`, `test_0c8o`, `test_q04a` | homogeneous / integer-hetero shapes only | **GREEN unchanged** |

### 8.3 Mandatory re-runs (the u2kk lesson: any `ptr_cells` extraction change must re-run these)

* `test/test_lf14_ptr_return_cells.jl` — pins per-wall LANDING messages for
  `setindex!(Dict{Int8,Int8},…)` and `Base.rehash!` under `ptr_cells=true` via
  `occursin`-disjunctions. Those callees' sret box is `{i64,i8}` (no ptr
  fields) so the landing should be unchanged (`ptrtoint`/iwo9) — **verify**,
  and widen the disjunction only if a landing genuinely moves.
* `test/test_u2kk_param_memcpy.jl`, `test/test_haiy_ptr_cells_store_load_gep.jl`,
  `test/test_nd45_ptr_cells_call_emission_multifn.jl`,
  `test/test_klgz_determinism_guard.jl`, `test/test_d1b_julia_set.jl`.
* `test/test_gate_count_regression.jl` — must be **byte-identical** (39/39).
  The gate makes this structurally true (`ptr_cells=false` untouched), but
  Rule 6 says run it.
* Full `Pkg.test()` — baseline 690653 Pass / 3 Broken (worklog 097).

### 8.4 BennettVM.jl — new file `test/test_7wsz_ptr_sret_vm.jl`, **zero src changes**

Cross-repo E2E on the `rr_callee` / `rr_caller` `.ll` pair (or the `mk3` /
`callee_f1` Julia pair, whichever the implementer finds cleaner to register):

* T-VM1: ingest the 2-function set; assert the callee `FunctionEntry` has
  `returns` arity 2 and `ret_elem_widths == [64,64]`; assert guard-5 does not
  fire (this is the `64 ≠ 72` regression's positive counterpart).
* T-VM2: run to the native oracle value; `unrun!` to exact initial state, empty
  history, **L2 and L3**, per-step inverse (the Bennett-40ys / `test_40ys_closure_callee_vm.jl` pattern).
* T-VM3: assert the sentinel slot's VM value is exactly `-1` (the §4.5
  falsification test) — this is what discharges R4.
* Full BVM `Pkg.test()`: baseline 9631/9631.

---

## 9. Scope control and exit criterion

**IN scope.** One predicate (`_sret_struct_fields`) + its gate plumbing (3 call
sites) + the callee-side scalar-store admission + `_operand` ptr_cells thread.
Roughly 40 changed lines across `src/extract/sret.jl`,
`src/extract/module_walk.jl` (one argument), `src/extract/instructions.jl`
(one kwarg).

**OUT of scope, fail loud unchanged**: `ptr_cells=false` anything; the
homogeneous `[N x iM]` arm; float/nested-struct/vector/packed sret fields;
non-addrspace-0 ptr fields; vector sret stores on the hetero arm;
field-overlapping sret memcpys; W1–W4 (§5); any BVM src change.

**Exit criterion (all four):**

1. **Capability proven** on the P3 synthetic fixtures at extraction level
   (T1/T2/T4/T5) and, for at least one of them, **VM round-trip + `unrun!`**
   (T-VM2/T-VM3).
2. **`push!` advances** to a named W1/W2 wall, with `Bennett-dv1z` absent from
   the message (T8).
3. **`ptr_cells=false` byte-identical**: T3 green, the four legacy reject tests
   green, gate-count regression 39/39, full `Pkg.test()` at 690653/3-Broken.
4. **BVM 9631+ green with zero src changes**, or — if R4 bites — one *named,
   reviewed* BVM change confined to the `IRInsertBits` const-operand path.

---

## 10. Risk register

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| **R1** | **Un-gated admission leaks into the circuit path.** `_detect_sret` has no `ptr_cells` parameter today and is called unconditionally (`module_walk.jl:171`); the obvious "just delete the IntegerType check" patch silently admits ptr sret fields at `ptr_cells=false`. **Probe-demonstrated** (§3.4: `mk3` extracted at `ptr_cells=false` with `ret_width=192`). Under the circuit ABI pointer args are *dropped* from `ParsedIR.args` ⇒ a ptr sret field would reference a nonexistent operand or silently mis-lower. | **CRITICAL** | The gate is the design (D2). T3 is the tripwire. Reviewer: check `_detect_sret`'s new parameter is threaded and that `test_dv1z_hetero_sret.jl` / `test_0zsk` / `test_land_ptrfield_struct` are re-run **unchanged**. |
| **R2** | **Over-repairing the `-1` sentinel.** A well-meaning implementer "fixes" sret slot 1 from `return_roots`, producing a model that disagrees with the machine and requires cross-module trackedness knowledge the caller provably does not have (§4.5 point 4). | HIGH | §4.5 is the written decision; T5 pins the sentinel as *readable and equal to -1*. Reviewer: reject any patch that special-cases `return_roots` inside `sret.jl`. |
| **R3** | **Padding-memcpy overlap reject fires on real Julia O0 shapes** if auto-SROA does not run (e.g. a caller passes an explicit `passes=[...]` that already contains `"sroa"`, or a future `_module_has_sret` miss). | MEDIUM | Probe shows SROA canonicalises both the 8-byte and 24-byte forms. Add a fixture that extracts a *whole-aggregate-memcpy* sret callee to pin the auto-SROA dependency, and keep the overlap reject strict (a real value-write via memcpy must stay out of scope). |
| **R4** | **BVM `IRInsertBits` with a `ConstOperand` value** may not be a path exercised today (all existing bits-struct fields come from SSA stores). | MEDIUM | §6 R4; discharged by T-VM3. Mitigation is BVM-local and known. |
| **R5** | **`ret_width` growth breaks an unnoticed width consumer.** 72 → 128/192 crosses no cap we found, but Bennett-40ys's gotcha 5 already flagged an inert caller/callee width-metadata mismatch (BVM ingest currently drops `ParsedIR.args` widths). | MEDIUM | Sweep for `ret_width`/`ret_elem_widths` consumers in both repos before landing; T-VM1 asserts the `FunctionEntry` widths explicitly rather than relying on the drop. |
| **R6** | **`lf14` / real-fn landing messages move** for `setindex!`/`rehash!` and are not caught. | MEDIUM | §8.3 mandatory re-run list (the u2kk lesson). Expected no-change (`{i64,i8}` box, no ptr fields) — **verify, do not assume**. |
| **R7** | **Julia-version fragility of the fixtures.** The `{ptr,ptr}` + `return_roots` shape is 1.12 codegen; the `_growend!` outlining is a 1.12 decision (40ys R1). | LOW | Unit fixtures T1/T2/T4/T5 are local structs and hand-built `.ll` — version-independent. Only T8 touches `Base` internals and asserts *shape*, not names. |
| **R8** | **Multi-return-site sret with ptr fields** (jghk) untested — every store-bearing block must write every slot, including ptr slots. | LOW | Add one `.ll` fixture with two return arms each writing both a ptr and an int field; the existing per-block completeness assert (`sret.jl:837-845`) should catch a partial write loudly. |

---

## Appendix — probe inventory (scratchpad `p7A_*`)

| File | Purpose |
|---|---|
| `p7A_probe1.jl` | first repro attempt (with `mem=:vm`) — showed the `:vm` recogniser wall masks the sret wall; use plain kwargs |
| `p7A_probe2.jl` | P1 canonical repro: root + closure + SET + `:skip` + `transitive_callees` key list |
| `p7A_probe3.jl` | P1 stacktrace pinning `_collect_consumed_sret` for the ROOT; dumps `p7A_root_O0.ll`, `p7A_clo_O0.ll`, `p7A_clo_O2.ll` |
| `p7A_probe4.jl` | P3 synthetic fixtures F1/F2, IR dumps + HEAD walls at both `ptr_cells` settings |
| `p7A_patch.jl` | the in-memory admission monkey-patch (probe only; **no src edited**) |
| `p7A_probe5.jl` | P4 next-wall enumeration + the un-gated-regression counter-probe |
| `p7A_probe6.jl` | ParsedIR shape dumps + the hand-built `return_roots` `.ll` (the decisive §3.3 evidence) |

Julia discipline observed: one process at a time, strictly sequential;
`pgrep -af julia` clean before the first run. No file under `src/` or `test/`
was modified by this proposal.
