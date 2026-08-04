# Bennett-jbko — Design Proposal **B**

**ptrtoint-equality arm: the MemoryRef concurrent-mutation guard (`_growend!` L84)**

Proposer B (blind). Bennett.jl `main` @ `73712d3`; BennettVM.jl `master` @ `572bf70`.
Julia 1.12.3. All probe transcripts below are real, reproduced in this session,
scratch prefix `jB_`.

---

## 0. TL;DR

Adopt **mechanism (b): a use-scoped `ptrtoint` admission**, placed as a third
arm inside the existing `ptr_cells`-gated `ptrtoint`/`inttoptr` block of
`_convert_instruction`, and made **structurally disjoint** from the two arms
above it.

> A `ptrtoint ptr %p to i64` whose source `%p` is an in-model SSA pointer is
> admitted as the width-64 cell identity `IRBinOp(dest, :or, %p, 0, 64)`
> **iff every transitive use of the result is an `icmp eq` / `icmp ne`**
> against another in-model 64-bit value (or the zero cell). Any other use —
> ordering compare, arithmetic, store, return, `inttoptr`, zero uses —
> **fails loud**.

The one-sentence soundness argument: **under `ptr_cells` this admission adds
no expressive power the model does not already have.** Bennett-8g7m (U80)
*already* admits `icmp eq/ne` over **pointer-typed** operands and *already*
rejects ordering compares over them, with exactly this determinism argument
(`instructions.jl:2905-2928`). The jbko arm simply lets the same comparison be
spelled with an explicit integer coercion on one side — which is precisely what
Julia emits when the other side is a *captured* copy of the pointer stored as
an `i64`. What the arm must NOT do is let the coercion become an **escape
hatch around 8g7m's own guard** — and that is the entire job of the use-scoped
gate (§5.1).

Empirically confirmed end-to-end this session (§7.4): with the arm simulated on
the real gated path, the distilled guard extracts, lowers to BennettVM, runs
**correctly in both the match and mismatch case**, and `unrun!` returns the
exact initial state with a drained history — **zero BennettVM source changes**.

Two findings that change the bead's forecast:

* **The next wall is NOT the L93 memcpy.** It is a *live* `store { ptr, ptr }`
  aggregate store (×2) at L93 (Bennett-lgzx / U114) — see §7.3. The 8-byte
  sret-reassembly memcpy behind it *is* clear, as forecast, but it is not
  reached first.
* **Bennett-kvdv is already dead.** The `ht_keyindex2` site it describes now
  extracts cleanly under `--check-bounds=yes` (Bennett-583s subsumed it). It
  never reaches jbko's arm. Recommend closing kvdv (§6.3).

---

## 1. Ground truth — the wall, verified

### 1.1 The wall reproduces exactly as filed

`jB_probe1.jl` (real `_growend!` closure key via the 40ys by-signature entry):

```
instanceless hits: 1
key = Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64, Int64, Int64,
      Int64, Int64, Memory{Int64}, MemoryRef{Int64}}
bytes = 28074
VERSION = 1.12.3
EXTRACT WALL:
ir_extract.jl: ptrtoint in @julia_#_growend!##0_1081:%L84:
  %coercion = ptrtoint ptr %.ref.ptr_or_offset to i64 —
  ptrtoint under ptr_cells whose source is NOT a recognised Julia type-tag
  value (Bennett-iwo9 / CW-D3 Lever 1). ...
```

### 1.2 The block, verbatim (`jB_growend.ll:186-207`)

```llvm
L84:                                              ; preds = %L81, %L55
  %54 = getelementptr inbounds i8, ptr %"#self#::#_growend!##0#..." , i32 56
  %55 = getelementptr inbounds { ptr, ptr }, ptr %2, i32 0, i32 0
  %56 = load ptr, ptr %55, align 8
  %57 = getelementptr inbounds { ptr, ptr }, ptr %2, i32 0, i32 1
  %58 = load ptr, ptr %57, align 8
  %59   = insertvalue { ptr, ptr } zeroinitializer, ptr %56, 0
  %.ref = insertvalue { ptr, ptr } %59, ptr %58, 1
  %.ref.ptr_or_offset = extractvalue { ptr, ptr } %.ref, 0
  %.unbox14 = load i64, ptr %54, align 8            ; <-- the CAPTURED copy
  %coercion = ptrtoint ptr %.ref.ptr_or_offset to i64
  %60 = icmp eq i64 %.unbox14, %coercion            ; <-- the ONLY use
  %61 = and i1 true, %60
  %.ref.mem = extractvalue { ptr, ptr } %.ref, 1
  %62 = icmp eq ptr %memoryref_mem30, %.ref.mem     ; <-- ALREADY OK (8g7m)
  %63 = and i1 %61, %62
  %64 = xor i1 %63, true
  %65 = xor i1 %64, true
  br i1 %65, label %L93, label %L90                 ; L90 = ConcurrencyViolationError
```

Three facts this establishes, each load-bearing:

1. **`%coercion` has exactly one use, and it is an `icmp eq`.** The use-scoped
   gate is not a hypothetical fit — it is an exact fit.
2. **The sibling operand `%.unbox14` is already fully in-model.** It is a plain
   `load i64` at byte offset 56 of the closure `self` pointer. Field layout of
   the 8-field closure: `Vector` ptr @0, five `Int64` @8..40, `Memory` ptr @48,
   `MemoryRef` @56 — so offset 56 **is** the captured `MemoryRef.ptr_or_offset`,
   read back as an integer. Bennett-40ys already pins that captured fields
   decode through `IRPtrOffset` + `IRLoad` as 64-bit cells
   (`test_40ys_instanceless_callees.jl:242-253`). Nothing new is needed for
   the captured side.
3. **The sibling comparison `%62` is `icmp eq ptr` and already extracts** via
   the Bennett-8g7m arm. The IR is literally asking us to treat the two
   spellings alike; today we admit one and reject the other.

### 1.3 Why neither existing arm matches

* **iwo9 type-tag arm** (`instructions.jl:3013`): requires
  `src.ref in tag_ssa`, i.e. provenance from a `load ptr, ptr @"+Type#N"`.
  `%.ref.ptr_or_offset` is an `extractvalue`. No match.
* **583s memdata arm** (`instructions.jl:3050-3051`): requires
  `_memdata_root(src) !== nothing`. `_memdata_root`
  (`instructions.jl:245-263`) seeds **only** on `load ptr` of a
  `{ i64, ptr }` **field-1** GEP (the GenericMemory header `.data`) and
  propagates through `getelementptr i8` / bitcast / addrspacecast. Our source
  is an `extractvalue` of a `{ ptr, ptr }` **MemoryRef**. Two independent
  mismatches: the opcode, and the struct shape (`{ptr,ptr}` vs `{i64,ptr}`).

---

## 2. Mechanism selection — honest comparison

### (a) Extend `_memdata_root` to see through `extractvalue` — **rejected**

Attractive because it reuses machinery, but it fails on three counts:

1. **Wrong root type.** The 583s recogniser is specifically the *GenericMemory
   header* `{ i64, ptr }`. A MemoryRef is `{ ptr, ptr }`. Teaching
   `_memdata_root` about `{ptr,ptr}` conflates two distinct Julia types and
   directly weakens `_is_genericmemory_header_struct`, whose *literalness* check
   is already carrying a known residual risk (`bennettvm-jb6w`, documented at
   `instructions.jl:211-217`).
2. **The use-gate does not fit.** `_verify_memdata_bounds_cluster`
   (`instructions.jl:269-284`) demands **every** use be a same-root
   `sub i64`. Our use is an `icmp eq` against a `load i64`. Admitting it means
   relaxing 583s's own contract — and 583s's soundness proof is *base
   cancellation in a subtraction*, which says nothing whatever about an
   equality compare. Two different theorems must not share one predicate.
3. **Blast radius.** Every 583s reject message is pinned in
   `test_583s_memdata_bounds.jl`; widening the recogniser risks silently
   changing which message fires.

**Probe evidence that (a) is actively dangerous.** My first monkey-patch
(`jB_probe2.jl`) *replaced* `_memdata_root` with an extractvalue-recognising
version. Result:

```
=== CLOSURE NEXT WALL ===
... %40 = ptrtoint ptr %memory_data to i64 — ptrtoint under ptr_cells whose
source is NOT a recognised Julia type-tag value ...
```

That "next wall" was **an artefact of the patch**: by taking over
`_memdata_root` I destroyed 583s's own recognition of the L58 bounds-check
cluster. Re-run additively (`jB_probe3.jl`) and L58 sails through. This is a
concrete, reproduced demonstration that touching `_memdata_root` breaks a
working arm. Recorded here because a reviewer will otherwise be tempted by (a).

### (c) Pattern-match the whole guard — **rejected**

Would have to recognise `insertvalue`×2 → `extractvalue` → `ptrtoint` →
`icmp eq` → `and i1 true, _` → `xor`/`xor` double-negation → `br`. Every one of
those is a Julia-codegen accident (CLAUDE.md Rule 5 — *LLVM IR is not stable*).
The `and i1 true` and the `xor`/`xor` pair are pure codegen noise that a
different Julia patch release may drop. It also generalises to nothing: a
second concurrent-mutation guard with a different surrounding shape walls again.
Highest fragility, lowest yield.

### (b) Use-scoped `ptrtoint` admission — **chosen**

* It is the **same architectural pattern the project already ratified for
  583s** — admit the coercion, then *prove the coerced value cannot escape*.
  Only the escape-proof changes (all-uses-are-equality, instead of
  all-uses-are-same-root-sub).
* It is **provenance-light and shape-blind**, so it survives Julia re-mangling
  the guard (Rule 5). It does not care that the source is an `extractvalue`.
* It **closes an existing hole** rather than opening one: today, an ordering
  compare on a coerced pointer would slip past 8g7m's *type-based* guard (§5.1).
  Admitting `ptrtoint` without a use gate would make that hole live. The gate is
  therefore mandatory, not decorative.
* Its emission is **byte-identical to the two arms above it**
  (`IRBinOp(dest, :or, src, iconst(0), 64)`), so nothing downstream changes.

---

## 3. The determinism argument (arm comment block, verbatim-ready)

> **Why an equality compare on a coerced pointer is deterministic.**
>
> Under `ptr_cells` a pointer is not an address into a host address space: it
> is one Int64 **VM cell value** (ADR 0018 §A). Every pointer a modelled
> program can hold is produced by BennettVM's **deterministic bump allocator** —
> `IntrinsicMalloc` / `gc_alloc_obj` / `jl_alloc_genericmemory_unchecked` all
> return `ARENA_BASE + s.arena_top` with `ARENA_BASE = Int64(1) << 40` frozen at
> compile time (`BennettVM/src/ir/intrinsics.jl:101,287`;
> `intrinsics_genericmemory.jl:22,86`), and `arena_top` advances by a span
> determined solely by the program text and its inputs. Two runs of the same
> program on the same inputs therefore assign **identical** addresses to
> corresponding allocations. There is no ASLR, no allocator nondeterminism, no
> re-use of a freed range within a trajectory.
>
> `ptrtoint` under this model is a **pure retype, not a computation**: the cell
> already *is* the 64-bit integer. It is emitted as the width-64 identity
> `IRBinOp(:or, src, 0, 64)` for the same reason as the iwo9 and 583s arms —
> so the destination binds through the normal SSA path (iwo9 consensus decision
> 3: real SSA defs, never zero-IR const-prop).
>
> The admitted comparison is `a == b` (or `!=`) between two such cells. Its
> outcome is determined by *whether the two cells denote the same arena
> location*, because the allocator is injective over live allocations within a
> trajectory (a bump cursor never hands the same base out twice). That is
> exactly the predicate the native oracle computes — "is this MemoryRef's data
> pointer still the one I captured?" — and it is **invariant under the choice of
> `ARENA_BASE`**: shifting the whole arena shifts both operands equally and
> leaves `a == b` unchanged. This base-independence is the direct analogue of
> 583s's base-cancellation (`sub(ptrtoint(base+off), ptrtoint(base)) = off`),
> and it is the property that makes the result a *source-level* fact rather
> than a *layout* fact.
>
> **Reversibility** is inherited, not argued specially: the coercion lowers to
> a `Define` (BVM `src/ir/define_instruction.jl` — the lowering target for
> `IRBinOp`), and the comparison lowers to a `Define` carrying the predicate
> (`src/ir/ingest_body.jl:112`). Both are non-destructive SSA creates; L2
> (`compute_must_cache`) and L3 (empty must-cache) reverse them exactly as they
> reverse any other `IRBinOp`/`IRICmp`. No new history record, no new
> uncompute obligation. Verified end-to-end in §7.4: `unrun!` returns the exact
> initial state with a drained history under both regimes.
>
> **What this must NOT permit.** The equality outcome is base-independent; a
> *magnitude* or an *arithmetic result* on the coerced value is not. So:
> ordering predicates (`ult/slt/...`) compare address magnitudes, which depend
> on allocation order and are UB across allocations in C — rejected (this is
> Bennett-8g7m's rule, and the use gate is what stops the coercion from
> laundering a pointer past it). Arithmetic (`add/sub/mul/and/shl/...`) on the
> coerced value exposes `ARENA_BASE` to integer computation and would make the
> program's *value* depend on the arena layout — rejected (583s admits exactly
> one arithmetic form, the same-root cancelling `sub`, under its own proof; this
> arm claims none of it). A `store`, a `ret`, or an `inttoptr` lets the raw
> address escape into memory, into the oracle-visible result, or back into a
> dereference — rejected. Equality against a **non-zero literal** is a test
> against a hard-coded host address, which is layout-dependent by construction —
> rejected; `0` is admitted because null is the zero cell (Bennett-beaw).

---

## 4. The implementation, precisely

### 4.1 New helper — `src/extract/instructions.jl`, inserted at **line 285**

immediately after `_verify_memdata_bounds_cluster` (which ends at line 284) and
before the `_gc_loaded_dst_elem_ref` docstring at line 286.

```julia
# ---- Bennett-jbko / CW-D: pointer-IDENTITY ptrtoint use gate ----------------
#
# The dual of `_verify_memdata_bounds_cluster`. That gate proves a coerced
# address never escapes a base-CANCELLING subtraction; this one proves it never
# escapes an EQUALITY test. Both are "the coerced integer is used only in a way
# whose result is independent of ARENA_BASE" — the sole soundness boundary.
#
# EVERY use of `pt` must be an `icmp` with predicate eq/ne whose SIBLING operand
# is itself an in-model 64-bit value (an SSA instruction or a function argument)
# or the zero cell (null, Bennett-beaw). A ptrtoint with NO uses (`saw == false`)
# is rejected too — dead pointer arithmetic is a surprise, and Rule 1 says
# surprises are loud.
#
# NOT admitted, deliberately: ordering predicates (address MAGNITUDE — the
# Bennett-8g7m rule, which this gate is what prevents laundering around),
# arithmetic, store, ret, inttoptr, phi/select, non-zero literal siblings.
function _verify_ptr_identity_only_uses(pt::LLVM.Instruction)::Bool
    saw = false
    for u in LLVM.uses(pt)
        saw = true
        usr = LLVM.user(u)
        (usr isa LLVM.Instruction &&
         LLVM.opcode(usr) == LLVM.API.LLVMICmp) || return false
        LLVM.predicate(usr) in (LLVM.API.LLVMIntEQ, LLVM.API.LLVMIntNE) ||
            return false
        ops = LLVM.operands(usr)
        length(ops) == 2 || return false
        sib = ops[1].ref == pt.ref ? ops[2] : ops[1]
        ok_sib = (sib isa LLVM.Instruction) || (sib isa LLVM.Argument) ||
                 (sib isa LLVM.ConstantInt && _const_int_as_int(sib) == 0)
        ok_sib || return false
    end
    return saw
end
```

### 4.2 New arm — `src/extract/instructions.jl`, inserted at **line 3071**

between the `end` closing the 583s arm (line 3070) and the generic iwo9
`_ir_error` (currently lines 3071-3078). Dispatch order inside the
`ptr_cells`-gated block becomes: **iwo9 type-tag → 583s memdata → jbko identity
→ generic fail-loud.**

```julia
        # Bennett-jbko / CW-D: pointer-IDENTITY coercion. Julia's MemoryRef
        # concurrent-mutation guard (`_growend!` L84) compares a MemoryRef's
        # CURRENT data pointer against a CAPTURED copy of it that was stored as
        # a plain i64 cell:
        #
        #   %e = extractvalue { ptr, ptr } %.ref, 0     ; current data ptr
        #   %c = load i64, ptr %self_plus_56            ; captured copy (a CELL)
        #   %p = ptrtoint ptr %e to i64
        #   %b = icmp eq i64 %c, %p                     ; the ONLY use of %p
        #
        # Admitted as the width-64 cell identity iff EVERY use of the result is
        # an `icmp eq/ne` against an in-model value (`_verify_ptr_identity_only_
        # uses`). See the determinism argument in that helper's header: the cell
        # IS the integer under ptr_cells, the bump allocator is deterministic and
        # injective within a trajectory, and `a == b` is invariant under a shift
        # of ARENA_BASE — so the comparison is a SOURCE-LEVEL fact, matching the
        # native oracle, exactly like the pointer-typed `icmp eq` that
        # Bennett-8g7m (instructions.jl:2905) already admits one block above.
        # THE USE GATE IS LOAD-BEARING: 8g7m's ordering-reject is TYPE-based, so
        # an ungated ptrtoint would launder a pointer into the integer icmp path
        # and slip an address-magnitude compare past it.
        #
        # STRUCTURALLY DISJOINT from the 583s arm above: a memdata-rooted source
        # is 583s's, under 583s's own (subtraction) proof, with 583s's own reject
        # messages. The `_memdata_root(src) === nothing` guard pins that scope
        # independently of arm ordering, so a future reordering cannot silently
        # widen either arm.
        #
        # `LLVMPtrToInt`-only, like 583s: an `inttoptr` of an identity-compared
        # address IS the forbidden escape and falls through to the fail-loud.
        # Inside the `&& ptr_cells` block ⇒ the circuit path is byte-identical.
        if opc == LLVM.API.LLVMPtrToInt && src isa LLVM.Instruction &&
           _memdata_root(src) === nothing && haskey(names, src.ref)
            srt = LLVM.value_type(src)
            drt = LLVM.value_type(inst)
            src_w = srt isa LLVM.PointerType ? 64 : _iwidth(src)
            dst_w = drt isa LLVM.PointerType ? 64 : _iwidth(inst)
            (src_w == 64 && dst_w == 64) || _ir_error(inst,
                "ptrtoint of an in-model pointer at a NON-64-bit width " *
                "(src=$(src_w) dst=$(dst_w)) under ptr_cells — genuine pointer " *
                "arithmetic, not a cell identity (Bennett-jbko / CW-D). Only " *
                "the 64-bit coercion confined to an equality test is modelled " *
                "(a pointer is one Int64 VM cell; CLAUDE.md §1).")
            _verify_ptr_identity_only_uses(inst) || _ir_error(inst,
                "ptrtoint under ptr_cells whose result is NOT confined to a " *
                "pointer-IDENTITY test (Bennett-jbko / CW-D). Every use must " *
                "be an `icmp eq`/`icmp ne` against an in-model value or null; " *
                "a use that is an ORDERING compare, arithmetic, a store, a " *
                "ret, an inttoptr, or a comparison against a non-zero literal " *
                "address would make the result depend on the BVM arena layout " *
                "rather than on a source-level property (the Bennett-8g7m " *
                "address-magnitude rule, which this gate stops a coercion from " *
                "laundering around). Rejected to fail fast (CLAUDE.md §1).")
            return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
        end
```

**Notes on the predicate list.**

* `src isa LLVM.Instruction` — the same guard the iwo9 and 583s arms use. A
  `ptrtoint` of a global, an alias, or a `ConstantExpr` is *not* an in-model
  cell and stays loud.
* `haskey(names, src.ref)` — belt: the source must already be a registered SSA
  name. Without it, `_operand` would fail loud anyway, but with a generic
  message; this keeps the jbko message on the jbko path.
* `_memdata_root(src) === nothing` — the disjointness pin (§4.3).
* `_operand(src, names)` **without** `ptr_cells=true`: the source is required to
  be an `LLVM.Instruction`, so the null→`iconst(0)` lever cannot apply. Matches
  both existing arms exactly.

### 4.3 Interaction with iwo9 / 583s — no regression, by construction

| source shape | arm that owns it | changed by jbko? |
|---|---|---|
| `src ∈ tag_ssa` (type tag) | iwo9, line 3013 | no — checked first, returns |
| `_memdata_root(src) !== nothing` | 583s, line 3050 | no — checked second; jbko's own guard excludes the shape a second time |
| any other in-model SSA pointer, all uses eq/ne | **jbko (new)** | new admission |
| any other in-model SSA pointer, other uses | generic iwo9 fail-loud → **jbko's more specific message** | message changes; §8 R3 |
| non-instruction source (global/alias/constexpr) | generic iwo9 fail-loud | unchanged |
| any `inttoptr` not in `tag_ssa` | generic iwo9 fail-loud | unchanged |

I checked `test_583s_memdata_bounds.jl` for a pinned reject on a memdata
ptrtoint with an `icmp` use — **there is none** (the only `icmp` in that file is
the `@boundscheck` consumer of the `sub`). So arm ordering is not constrained by
a pinned test either way; the explicit `_memdata_root(src) === nothing` guard is
kept anyway so the scope is a property of the arm rather than of its position.

### 4.4 Optional tightening — the non-zero-literal sibling

The `ok_sib` clause in `_verify_ptr_identity_only_uses` is the only predicate
here not forced by the corpus. It rejects `icmp eq i64 %coerced, 140737488355328`
— a test against a hard-coded host address, which is layout-dependent by
construction and would diverge between the native oracle and the VM. Probe
`jbko_litconst` (§7.2) is the fixture; under a patch *without* this clause it
extracts silently, which is the divergence. Cost is four lines; I recommend
keeping it, but it is cleanly separable if the implementer disagrees.

---

## 5. What stays loud, and why it matters

### 5.1 The hole this arm must not open (the single most important point)

Bennett-8g7m's ordering guard is **type-based**:

```julia
if ptr_cells && (LLVM.value_type(ops[1]) isa LLVM.PointerType ||
                 LLVM.value_type(ops[2]) isa LLVM.PointerType)
    pred in (:eq, :ne) || _ir_error(...)   # instructions.jl:2917-2924
```

An `icmp ult i64 %coerced, %n` has **no pointer-typed operand**. It falls
through to the plain integer path at line 2929 and is admitted *silently*, with
an address magnitude decided by the bump allocator. Therefore: **admitting
`ptrtoint` without a use gate silently disables 8g7m.** The use gate is the
only thing standing between the jbko arm and a silent miscompile. This must be
stated in the arm's comment (it is, §4.2) and pinned by a test (§7.5 (C)).

### 5.2 Full reject list

| shape | outcome | fixture |
|---|---|---|
| ordering `icmp` on the coerced value | loud (jbko message) | `jbko_ordering` |
| `add`/`sub`/any arithmetic use | loud | `jbko_arith` |
| `store i64 %coerced, ...` | loud | `jbko_store` |
| `ret i64 %coerced` | loud | `jbko_ret` |
| `icmp eq` vs non-zero literal address | loud | `jbko_litconst` |
| `ptrtoint ptr → i32` | loud (width message) | `jbko_narrow` |
| zero uses | loud | design; trivial fixture |
| mixed uses (one `icmp eq` + one `add`) | loud | design |
| `inttoptr` of anything not a tag | loud (generic iwo9, unchanged) | existing |
| `ptrtoint` of a global / alias / constexpr | loud (generic iwo9, unchanged) | existing |
| use is a `phi` or `select` that later feeds an `icmp eq` | **loud** (conservative) | — |

The last row is a deliberate conservatism: transitive-through-phi would need a
fixed-point over the use graph and is not required by any known corpus. If it
ever appears, the message names jbko and the extension is local.

---

## 6. Downstream

### 6.1 BennettVM: zero source changes expected — **verified**

* `IRBinOp` → `Define` (`BennettVM/src/ir/ingest_body.jl`, `define_instruction.jl:6`).
  `:or` is in the accepted op set (`src/ir/operators.jl:100`) and evaluates as
  `(am | bm) & mask` (`arithmetic_assignment.jl:258`) — `x | 0 == x`.
* `IRICmp` → `Define` carrying the predicate (`ingest_body.jl:112-113`);
  `IRICmp.width` is the **operand** width, and jbko emits 64 on both sides.
* Both are non-destructive SSA creates, reversed by the standard L2/L3 machinery.

Confirmed empirically in §7.4 — the E2E ran against unmodified BennettVM
`@572bf70`.

### 6.2 The failure branch (ConcurrencyViolationError) is already discharged

`L90` is `unreachable`-terminated after `call void @ijl_throw`
(`jB_growend.ll:208-219`), so it is collected by the Bennett-utzc keep-branch
pruner (`module_walk.jl:426,444-450`), whose comment *explicitly* names this
construct: *"the U114 `store { ptr, ptr }` box-store; the `[1 x ptr]
@j_AssertionError` ArrayType-return call"* — L90 contains exactly the former.
The body is dropped, the label kept, and the terminator becomes the reserved
`:__unreachable__` branch (a faithful reversible throw). The predecessor's
conditional branch is left untouched, which is exactly what we want: the guard
*is* evaluated, and firing it traps loud.

`L96` and `oob` / `oob43` are the same shape and likewise pruned. **Verified**:
`jB_probe3.jl` walks past L84 → L90 → L93 without touching them.

### 6.3 Bennett-kvdv — already dead, recommend closing

The bead asks what the other corpus `ptrtoint` (`ht_keyindex2_shorthash!` under
`--check-bounds=yes`) does under this arm. Answer: **it never reaches it.**
`jB_kvdv.jl` under `--check-bounds=yes` at HEAD:

```
KVDV SITE OK: blocks=54 ret_width=72
```

Bennett-583s subsumed kvdv (its `%memory_data` ptrtoint is the canonical
base-cancelling cluster). kvdv is still `OPEN` in the tracker; it should be
closed with a pointer to 583s, and `test_59zi_sret_call_memcpy.jl`'s
`--check-bounds=yes` branch — which asserts *"the iwo9 wall"* — is now asserting
a wall that no longer exists and needs re-pointing. Filed as a risk (§8 R5),
not fixed here.

### 6.4 `ptr_cells` gating and circuit-path byte identity

`ptr_cells` defaults `false` on every entry point (`entry.jl:59,78,151,175`,
`module_walk.jl:48,66,141`) and is never set by `reversible_compile`. The whole
jbko arm lives inside the existing `if (... LLVMPtrToInt || ... LLVMIntToPtr)
&& ptr_cells` block, so with the gate off the opcode falls to the pre-existing
"unsupported LLVM opcode" wall exactly as today — **no arm at all**, therefore
no reachable code change on the circuit path.

Gate-count regression baseline **at HEAD**, established this session as the
before-picture:

```
$ julia --project --check-bounds=yes test/test_gate_count_regression.jl
Test Summary:                   | Pass  Total  Time
Gate count regression baselines |   39     39  8.3s
```

The implementer must reproduce 39/39 byte-identically after the change.

---

## 7. Probe transcripts

All probes ran **strictly sequentially**, one Julia process at a time
(`pgrep -a julia` checked clean before each).

### 7.1 The additive monkey-patch (`jB_probe3.jl`)

Rather than editing `src/`, I patched the *real gated path* through its two
existing seams — `_memdata_root` and `_verify_memdata_bounds_cluster` — keeping
their original bodies **verbatim** and adding an `extractvalue` case whose
use-gate is `all uses are icmp eq/ne`. The 583s arm then emits
`IRBinOp(dest, :or, src, iconst(0), 64)` — **the exact instruction jbko's arm
would emit**. This is the 3vf2 lesson applied: measure the real path, not a
sandbox.

### 7.2 Adversarial fixtures (`jB_fixtures.ll` + `jB_probe4.jl`)

```
jbko_green       ptr_cells=true   -> OK  11 insts: IRPtrOffset,IRLoad,IRPtrOffset,
                                    IRLoad,IRInsertValue,IRInsertValue,
                                    IRExtractValue,IRLoad,IRBinOp,IRICmp,IRCast
jbko_green       ptr_cells=false  -> REJECT: getelementptr ... 2 index(es) ...
jbko_ordering    ptr_cells=true   -> REJECT: ptrtoint ... result is NOT confined ...
jbko_ordering    ptr_cells=false  -> REJECT: getelementptr ...
jbko_arith       ptr_cells=true   -> REJECT: ptrtoint ... NOT confined ...
jbko_store       ptr_cells=true   -> REJECT: ptrtoint ... NOT confined ...
jbko_ret         ptr_cells=true   -> REJECT: ptrtoint ... NOT confined ...
jbko_litconst    ptr_cells=true   -> OK  7 insts   <-- needs §4.4's ok_sib clause
jbko_narrow      ptr_cells=true   -> REJECT: ... NON-64-bit width (src=64 dst=32) ...
```

(The reject messages carry 583s's wording because the probe rides 583s's seam;
in the real arm they carry jbko's wording from §4.2.)

Two readings:

* **Green** decomposes exactly as designed — the `ptrtoint` becomes an
  `IRBinOp` (`:or` identity) immediately followed by the `IRICmp`.
* **`jbko_litconst` extracts** under the probe patch, because the probe does not
  implement §4.4's `ok_sib` clause. That is the empirical case *for* keeping it.
* **Gate-off**: every fixture walls at the earlier two-index struct GEP, which is
  precisely the precedent `test_583s_memdata_bounds.jl:361-373` accepts as a
  gate-off witness ("*a `ptr_cells`-gated wall — either proves the gate is
  OFF*").

### 7.3 The real corpus: next wall (`jB_probe3.jl`, then `jB_probe5.jl`)

With the arm simulated, the closure advances past L84, past the pruned L90, into
L93:

```
=== CLOSURE NEXT WALL ===
ir_extract.jl: store in @julia_#_growend!##0_1180:%L93:
  store { ptr, ptr } %memory_ref12, ptr %1, align 8 —
  store of non-integer type LLVM.StructType({ ptr, ptr }) not supported
  (Bennett-lgzx / U114). ...
```

**This contradicts the bead's forecast.** The forecast said *"L93 success path
is an 8-byte sret-reassembly memcpy (plausibly already supported post-7wsz) —
runway plausibly SHORT"*. In fact L93 is:

```llvm
L93:
  store { ptr, ptr } %memory_ref12, ptr %2, align 8      ; <-- WALL (live, U114)
  call void (ptr, ...) @julia.write_barrier(ptr %2, ptr %memoryref_mem)
  store { ptr, ptr } %memory_ref12, ptr %0, align 8      ; <-- WALL (live, U114)
  %68 = getelementptr inbounds i8, ptr %0, i32 0
  %69 = getelementptr inbounds i8, ptr %sret_return, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %69, ptr align 8 %68, i64 8, i1 false)
  ...
  ret void
```

Two **live** `{ ptr, ptr }` aggregate stores precede the memcpy — the very
construct the utzc pruner is allowed to *drop* when it sits in a dead throw
block, but here on the success path. The first writes the new MemoryRef into
the `Vector`'s `ref` field on the heap (note the `julia.write_barrier`); the
second stages it in the local `{ptr,ptr}` alloca for the sret reassembly.

**Look-ahead (`jB_probe5.jl`).** I hand-lowered those two aggregate stores in a
copy of the real `.ll` into what an aggregate-store arm would plausibly emit
(`extractvalue` ×2 + two-index struct GEPs + two `store ptr`), and re-ran the
real extractor:

```
=== LOOK-AHEAD: aggregate stores hand-lowered to cell stores ===
WALL: ir_extract.jl: ptrtoint in @julia_#_growend!##0_1022:%idxend:
  %85 = ptrtoint ptr %memory_data39 to i64 —
  ptrtoint of a GenericMemory .data base under ptr_cells whose result is NOT
  confined to a same-Memory base-cancelling bounds check ... (Bennett-583s)
```

So the runway after jbko is (in extractor order):

1. **wall 6′ — live `store { ptr, ptr }`** at L93 ×2, plus the
   `@julia.write_barrier` void call (which the look-ahead shows *does* convert).
   Bennett-lgzx / U114. **New; no bead exists.**
2. **wall 7 — a 583s coverage gap at `%idxend`.** The second bounds-check
   cluster's element pointer is rooted at a **MemoryRef `{ptr,ptr}` field-0
   load** (`%memoryref_data29 = load ptr, ptr %33`), not at the GenericMemory
   `{i64,ptr}` field-1 `.data` load, so `_memdata_root` returns `nothing` for
   the `sub`'s sibling and the same-root check fails. The base *does* still
   cancel (both trace to `%memoryref_mem30`), but proving it needs
   `_memdata_root` to pair a MemoryRef's field-0 data with its field-1 mem.
   **New; no bead exists.** *(This is where option (a) would have to be done
   properly and for the right reason — as a 583s extension under 583s's
   subtraction proof, not as a vehicle for jbko.)*
3. then `bennettvm-rxgy` (byte-tier `IntrinsicMemmoveBytes`) on the BVM side,
   as already filed.

The memcpy itself, and the `store i64 -1` sret sentinel, and the `return_roots`
write, all convert — the forecast was right about the memcpy, wrong that it is
next.

### 7.4 Cross-repo E2E — **honestly runnable, and green** (`jB_probe6.jl`)

The real `_growend!` cannot yet run E2E (walls 6′/7 remain), so I distilled the
L84 guard onto the C/word tier — the same honest-scope move
`test_vau9_memmove_vm.jl` documents. The capture is created the way Julia
creates it: `store ptr %buf, ptr %cap` then `load i64, ptr %cap` (no second
`ptrtoint` needed — the cell is the cell). Two variants: capture matches the
current data pointer, and capture is a **different allocation**.

```
=== guard_match ===
  x=0   halted=true  result=1   ;  unrun exact=true  history drained=true
  x=7   halted=true  result=8   ;  unrun exact=true  history drained=true
  x=-3  halted=true  result=-2  ;  unrun exact=true  history drained=true
=== guard_mismatch ===
  x=0   halted=true  result=-1  ;  unrun exact=true  history drained=true
  x=7   halted=true  result=-1  ;  unrun exact=true  history drained=true
  x=-3  halted=true  result=-1  ;  unrun exact=true  history drained=true
```

`guard_match` takes the `ok` branch (`x+1`); `guard_mismatch` takes the `bad`
branch (`-1`). This is the determinism argument made operational: the VM's bump
allocator gives `%buf` and `%alt` distinct arena addresses, the equality
distinguishes them, and the branch outcome matches what the native oracle would
decide. **Zero BennettVM source changes.** Note also the `_agg_a0_slot*` /
`_agg_a1_slot*` locals in the result — the `{ptr,ptr}` insert/extract chain
already round-trips through BVM.

### 7.5 Test plan (RED-GREEN)

**RED first.** Every fixture below must be written and watched fail against
`73712d3` before the arm exists — the green ones with the generic iwo9 message,
the reject ones with the *generic* message rather than jbko's.

New file `test/test_jbko_ptr_identity_cmp.jl`, modelled on
`test_8g7m_ptr_icmp_cells.jl` (its gate map (A)-(F) is the right template) and
`test_583s_memdata_bounds.jl` (its gate-off testset (7) is the right precedent).
Hand-written `.ll` fixtures go in `test/fixtures/ll/jbko_*.ll`, locally named
per the D1b collision lesson.

| # | claim | fixture | assertion |
|---|---|---|---|
| (A) | **GREEN, node shape** — the guard extracts | `jbko_green` | exactly one `IRBinOp(:or, ssa, ConstOperand(0), 64)` whose dest is the coercion, immediately consumed by `IRICmp(:eq, _, _, 64)`; full inst-type sequence pinned |
| (B) | GREEN, `ne` too | `jbko_green_ne` | same shape, `:ne` |
| (C) | **THE 8g7m HOLE** — ordering compare on the coerced value | `jbko_ordering` | `:err`, message contains `"jbko"` and `"8g7m"` and `"ordering"`. *This is the arm's reason to exist; if it ever goes green the model is silently miscompiling.* |
| (D) | arithmetic use | `jbko_arith` | `:err`, `"jbko"` |
| (E) | store use (escape into memory) | `jbko_store` | `:err`, `"jbko"` |
| (F) | ret use (escape to the oracle boundary) | `jbko_ret` | `:err`, `"jbko"` |
| (G) | non-zero literal sibling | `jbko_litconst` | `:err`, `"jbko"` (drop with §4.4 if the implementer declines the tightening) |
| (H) | mixed uses (one `icmp eq` **and** one `add`) | `jbko_mixed` | `:err` — the gate is *every* use, not *some* use |
| (I) | zero uses | `jbko_deaduse` | `:err` |
| (J) | width | `jbko_narrow` (`ptr→i32`) | `:err`, `"NON-64-bit"` |
| (K) | `inttoptr` untouched | `jbko_inttoptr` | `:err`, generic iwo9 message (substring `"type-tag"`), **not** jbko's |
| (L) | **583s inertness** | reuse `CLUSTER_OK` from `test_583s_memdata_bounds.jl` | still lowers to the `:or` identity via 583s; `test_583s_memdata_bounds.jl` and `test_iwo9_typetag.jl` both still fully green |
| (M) | **8g7m inertness** | reuse the 8g7m fixtures | `icmp ult ptr` still rejects with the 8g7m message |
| (N) | **gate-off byte identity** | `jbko_green` at `ptr_cells=false` | `:err` at a `ptr_cells`-gated wall (GEP / opcode) — precedent `test_583s_memdata_bounds.jl:361` |
| (O) | **corpus advancement pin** | the real `_growend!` closure via `extract_parsed_ir_set_from_julia(_push, Tuple{Int64}; ptr_cells=true)` | NEGATIVE on `"ptrtoint"`; POSITIVE on the *named* next wall — `"store of non-integer type"` ∧ `"lgzx"`. Written as the 40ys (I) idiom: *when this goes red, that is the signal to advance it, not to delete it.* |
| (P) | gate-count regression | `test/test_gate_count_regression.jl` | 39/39, byte-identical |

Cross-repo: `BennettVM.jl/test/test_jbko_ptr_identity_vm.jl` — the §7.4 fixture
promoted, asserting (i) the handoff shape (`Define` with `:or`; `Define` with
the `:eq` predicate), (ii) `guard_match` → `ok` arm / `guard_mismatch` → `bad`
arm vs a hand oracle, (iii) `unrun!` exact + drained history under **both** L2
(`compute_must_cache`) and L3 (empty must-cache), (iv)
`per_step_inverse_check` at K ∈ {1,4}. Header must state the honest scope
boundary: C/word tier, because the real `_growend!` still has walls 6′/7 (§7.3).

Beads to file alongside: **wall 6′** (live `store { ptr, ptr }` at L93,
U114/lgzx) and **wall 7** (583s MemoryRef-rooted bounds cluster at `%idxend`);
plus close **Bennett-kvdv** (§6.3) and re-point
`test_59zi_sret_call_memcpy.jl`'s `--check-bounds=yes` branch.

---

## 8. Risk register

| # | risk | severity | mitigation |
|---|---|---|---|
| **R1** | **The use gate is the only thing preserving 8g7m.** A future "simplification" that drops it silently admits address-magnitude compares — a silent miscompile, the worst failure class in this project. | **high** | Test (C) asserts the ordering reject *and names 8g7m in the message*. The arm comment says it in capitals. Both must land together. |
| **R2** | Transitive-use analysis is only one level deep: a coerced value flowing through a `phi`/`select` into an `icmp eq` rejects (conservative), but a *future* relaxation that follows phis must re-prove the escape argument over the whole use graph. | medium | Documented as deliberate in §5.2; the reject message names jbko so the extension is discoverable. |
| **R3** | The generic iwo9 message currently fires for shapes that will now get jbko's message. Any test asserting the *generic* message on such a shape goes red. | medium | Grep for `"type-tag round-trip"` assertions before landing; the `_growend!` advancement pin (test (O)) is the one I know of and is *supposed* to move. |
| **R4** | Julia version fragility: 1.12.3 emits the guard through `insertvalue`/`extractvalue`. If 1.13 loads the pointer directly, a shape-matching arm would wall again. | low **for (b)** | This is why (c) was rejected. Mechanism (b) is shape-blind — it only asks "is the source an in-model SSA pointer" and "are all uses equality". |
| **R5** | `Bennett-kvdv` is stale-open and `test_59zi_sret_call_memcpy.jl` asserts a wall that no longer exists under `--check-bounds=yes` (§6.3). Not caused by jbko, but adjacent and will confuse the implementer. | low | File/close as part of the session; do not silently fix inside the jbko commit. |
| **R6** | `LLVM.Argument` in the `ok_sib` clause: an i64 *argument* compared against an arena address is deterministic given the input, but oracle match then depends on the caller passing a corresponding cell. | low | Inherent to the whole `ptr_cells` model (every pointer argument has this property); not introduced here. Noted so it is not mistaken for a new hazard. |
| **R7** | The look-ahead in §7.3 rode a hand-edited `.ll`. Wall 7 is therefore *conditional* on an aggregate-store arm emitting roughly what I hand-wrote. | low | Wall 6′ is unconditional (observed on the unmodified real IR). Wall 7 is labelled a forecast, and its root cause (`_memdata_root` not seeing MemoryRef field-0) is verified by reading the IR directly, independent of the patch. |

---

## 9. Files touched (implementer's checklist)

* `src/extract/instructions.jl` — helper at **line 285**; arm at **line 3071**.
  Nothing else. No new file, no change to `lower.jl`, no change to any BVM file.
* `test/test_jbko_ptr_identity_cmp.jl` (new) + `test/fixtures/ll/jbko_*.ll` (new)
  + registration in `test/runtests.jl`.
* `BennettVM.jl/test/test_jbko_ptr_identity_vm.jl` (new) + registration.
* `worklog/098_*.md` (or `099_*` if 098 passes ~280 lines — it is at 82).

Gates before accepting: `test_jbko_*` green; `test_583s_memdata_bounds.jl`,
`test_iwo9_typetag.jl`, `test_8g7m_ptr_icmp_cells.jl`, `test_vau9_*`,
`test_40ys_*`, `test_7wsz_*`, `test_3vf2_*` all still green;
`test_gate_count_regression.jl` **39/39**; full `Pkg.test()` both repos.

---

### Probe artefacts (scratchpad, `jB_` prefix)

`jB_probe1.jl` (wall repro + IR dump) · `jB_growend.ll` (28 074 B, the real
closure IR) · `jB_probe2.jl` (destructive patch — kept as the evidence *against*
mechanism (a)) · `jB_probe3.jl` (additive patch, next wall) · `jB_fixtures.ll` +
`jB_probe4.jl` (adversarial matrix) · `jB_growend_patched.ll` + `jB_probe5.jl`
(look-ahead past wall 6′) · `jB_probe6.jl` (cross-repo E2E) · `jB_kvdv.jl`.
