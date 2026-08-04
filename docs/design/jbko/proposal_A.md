# Bennett-jbko — Proposal A

**Identity-use `ptrtoint`: admitting the MemoryRef concurrent-mutation guard**

* Bead: `Bennett-jbko` (P1, IN_PROGRESS) — xkl frontier wall 5
* Repo / HEAD: `Bennett.jl` @ `73712d3` (main); sister `BennettVM.jl` @ `572bf70` (master, path-dep)
* Role: DESIGN PROPOSER A. Design document only — no `src/` or `test/` edits were made.
* Probe scripts (scratchpad, prefix `jA_`): `jA_probe1.jl` (real IR dump), `jA_probe2.jl`
  (use census + monkey-patched next-wall search on the REAL gated path), `jA_probe3.jl`
  (hand-written `.ll` fixture family + BVM E2E), `jA_probe4.jl` (kvdv interaction).

---

## 0. Summary

**Mechanism chosen: (b), an identity-use-scoped `ptrtoint` admission**, with a
*positive source whitelist*. Candidates (a) and (c) are rejected, with reasons, in §6.

> Under `ptr_cells`, `%c = ptrtoint ptr %p to i64` is admitted as the width-64 cell
> identity `IRBinOp(dest, :or, <src>, iconst(0), 64)` **iff**
>
> * **(P1)** source and destination widths are both 64;
> * **(P2)** `%p` is a *certified cell-valued pointer SSA* — an `extractvalue` selecting a
>   `PointerType` field of a `StructType`, or a `load` whose result type is `PointerType`
>   — in address space 0;
> * **(P3)** `%c` has **≥ 1 use** and **every** use is an `icmp` with predicate `eq` or `ne`;
> * **(P4)** for every such use, the sibling operand is not a **non-zero integer constant**.
>
> Anything else keeps the existing fail-loud.

The admitted construct is then *semantically identical to a construct the extractor already
admits*: `icmp eq ptr` under the Bennett-8g7m arm (`instructions.jl:2902-2930`), which
likewise permits only `eq`/`ne` and rejects ordering predicates for exactly the reason
restated in §2. The real corpus proves this: Julia's guard compares **both halves** of the
same `MemoryRef`, and the `.mem` half is *already* admitted as a plain `icmp eq ptr`. Only
the `.ptr_or_offset` half needs a new arm, and only because codegen happens to have read the
captured copy as `i64` rather than as `ptr`. jbko is therefore not a new semantic capability
— it is a **representation normalisation of an already-admitted comparison**.

**Ground-truth findings from the probes (all transcripts in §9):**

| # | Finding |
|---|---|
| F1 | The bead's forecast for the wall after jbko is **wrong**. There is no 8-byte sret-reassembly memcpy on the live path. The real next wall is `store { ptr, ptr } %memory_ref12, ptr %1` in `%L93` → **Bennett-lgzx / U114** ("store of non-integer type"). |
| F2 | There is a **wall N+2** after that, also unforecast: `%86 = ptrtoint ptr %memoryref_data_byteoffset36` in `%idxend`, whose base is a `load ptr` **from the closure capture** and therefore has **no** `_memdata_root`. The 583s arm rejects it. The runway to full `_growend!` extraction is **not** short. |
| F3 | `%coercion`'s use set is **exactly one** `icmp eq`. Verified by an exhaustive `LLVM.uses` census on the post-pass module, not by reading the text. |
| F4 | The failure arm `%L90` **is** in the Bennett-utzc `dead_blocks` set (it is `unreachable`-terminated), so the ConcurrencyViolationError throw is pruned to the `:__unreachable__` sink. No 3vf2 dead-use drop is needed: the `@jl_global#1111` load lives *inside* `%L90`, not hoisted out of it. |
| F5 | **BVM src changes: ZERO.** `IRICmp` → `Define(dest, op1, pred, op2, width)` (`ingest_body.jl:112-119`) and the `:or` identity → `Define`; both already exist. Proven end-to-end: extract → `lower_vm` → `run!` → `:halted` with the right answer → `unrun!` exact, under both L2 and L3 regimes. |
| F6 | **`Bennett-kvdv` is stale.** `ht_keyindex2_shorthash!` extracts cleanly today under `--check-bounds=yes` (`ret_width=72`, 54 blocks) — 583s already cleared it. The jbko patch leaves it byte-identical. Recommend closing kvdv. |
| F7 | Gate (I) of `test_40ys_instanceless_callees.jl` and gate (J) of `test_7wsz_ptr_sret_fields.jl` will **NOT** go red when jbko lands: both landing disjunctions already contain `Bennett-lgzx` / `U114`. The advance must be done by **adding negatives**, not by waiting for red. |

---

## 1. The wall, from the actual IR

### 1.1 How the IR was obtained

Rule 5 / the 3vf2 lesson ("wall forecasts and IR claims are only valid for the EXACT
pipeline configuration that produced them"). Every claim below is measured on the module the
converter actually walks: `_code_llvm_by_sig(sig; optimize=false, dump_module=true,
debuginfo=:none)` followed by the auto-prepended `["sroa","mem2reg"]` that
`_module_has_sret(mod)` triggers at `entry.jl:104-108`. `jA_probe1.jl` reproduces that
pipeline verbatim and writes `jA_growend_post.ll`.

```
instance-less hits: 1
key = Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64, Int64, Int64,
                                          Int64, Int64, Memory{Int64}, MemoryRef{Int64}}
raw length = 28074
effective passes = ["sroa", "mem2reg"]
```

The closure's signature (post-pass):

```llvm
define void @"julia_#_growend!##0_1105"(
    ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %sret_return,
    ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %return_roots,
    ptr nocapture noundef nonnull readonly align 8 dereferenceable(72) %"#self#::#_growend!##0#_growend!##1",
    ptr nocapture readonly %".roots.#self#") #0 {
top:
  %0  = getelementptr inbounds i8, ptr %".roots.#self#", i32 0
  %1  = load ptr, ptr %0, align 8              ; the LIVE MemoryRef object
  ...
  %4  = getelementptr inbounds i8, ptr %".roots.#self#", i32 16
  %memoryref_mem30 = load ptr, ptr %4, align 8 ; the CAPTURED .mem half
```

### 1.2 The guard block, verbatim

```llvm
L84:                                              ; preds = %L81, %L55
  %53 = getelementptr inbounds i8, ptr %"#self#::#_growend!##0#_growend!##1", i32 56
  %54 = getelementptr inbounds { ptr, ptr }, ptr %1, i32 0, i32 0
  %55 = load ptr, ptr %54, align 8
  %56 = getelementptr inbounds { ptr, ptr }, ptr %1, i32 0, i32 1
  %57 = load ptr, ptr %56, align 8
  %58   = insertvalue { ptr, ptr } zeroinitializer, ptr %55, 0
  %.ref = insertvalue { ptr, ptr } %58, ptr %57, 1
  %.ref.ptr_or_offset = extractvalue { ptr, ptr } %.ref, 0     ; <-- the ptrtoint source
  %.unbox14 = load i64, ptr %53, align 8                       ; <-- the CAPTURED copy
  %coercion = ptrtoint ptr %.ref.ptr_or_offset to i64           ; <-- THE WALL
  %59 = icmp eq i64 %.unbox14, %coercion                        ; <-- the sole use
  %60 = and i1 true, %59
  %.ref.mem = extractvalue { ptr, ptr } %.ref, 1
  %61 = icmp eq ptr %memoryref_mem30, %.ref.mem                 ; <-- ALREADY ADMITTED (8g7m)
  %62 = and i1 %60, %61
  %63 = xor i1 %62, true
  %64 = xor i1 %63, true
  br i1 %64, label %L93, label %L90
```

Three facts that the whole design rests on, and where each is proven:

1. **The source is already a 64-bit cell in the model.** `%.ref.ptr_or_offset` is an
   `extractvalue` of a `{ptr,ptr}` `StructType`. Under `ptr_cells`,
   `_struct_field_widths` (`instructions.jl:55-92`) stamps a `PointerType` field at
   **width 64**, with the comment *"a pointer is one Int64 VM cell, ADR 0018 §A"*. Probe 3
   shows the emitted instruction: `IRExtractValue(:po, SSAOperand(:ref), 0, 0, 2, [64, 64])`.
   The `ptrtoint` is therefore **a no-op re-typing of a value the model already holds as an
   integer** — there is nothing to convert.

2. **The captured side is a plain integer cell.** `%53 = self + 56` and
   `%.unbox14 = load i64, ptr %53`. The closure type's field layout is
   `{Vector, Int64×5, Memory, MemoryRef}` → byte 56 is the first word of the captured
   `MemoryRef{Int64}`, i.e. its `ptr_or_offset`. Under `ptr_cells` an `IRLoad` of an `i64`
   is width 64 like any other. The 40ys design confirms the capture-by-pointer convention:
   *"the captured state arrives as a leading extra argument, and the existing
   `IRPtrOffset`/`IRLoad` machinery already decodes its fields"* (40ys proposal_A §4.2).
   **No new machinery is needed on the captured side.**

3. **The same closure field is read BOTH ways by the same function.** `%53 = self+56`
   (loaded as `i64`, block `%L84`) and `%32 = self+56` (loaded as `ptr` at `%L46`,
   `%memoryref_data29 = load ptr, ptr %32` in `%idxend`). Codegen picks `i64` or `ptr` per
   use site for the *same cell*. This is decisive: the `i64`/`ptr` distinction at this
   boundary is **a codegen artefact, not a semantic one**, and the model that assigns both
   the same 64-bit cell is the correct one.

### 1.3 Where it lands today

`instructions.jl:3010` opens the `ptrtoint`/`inttoptr` arm under `ptr_cells`.
`%.ref.ptr_or_offset` is not in `tag_ssa` (it is not a `load @"+Type#N"`), so the
Bennett-iwo9 arm at `:3013-3034` does not fire. `_memdata_root(src)` returns `nothing`
(probe 2 census, below) because `_memdata_root` (`instructions.jl:245-263`) seeds only on
`load ptr` of a `{i64,ptr}` field-1 GEP and propagates only through `getelementptr i8` and
identity casts — **`extractvalue` is not in its walk**. So the Bennett-583s arm at
`:3050-3070` does not fire either, and control reaches the generic reject at `:3071-3078`.

### 1.4 Exhaustive `ptrtoint` census (probe 2, part (i))

Measured with `LLVM.uses`, on the post-pass module, with the utzc dead-set computed the way
`module_walk.jl:426` computes it.

```
dead (unreachable-terminated) blocks: ["L71", "L90", "L96", "after_throw", "after_noret",
  "fail", "fail9", "after_throw19", "after_noret20", "oob", "oob43", "after_noret51",
  "fail56", "fail61", "fail67"]

ptrtoint %          in L58     src = load ptr %memory_data_ptr26      root=0x2a1a8058  USE: sub    (dead=false)  → 583s ✔
ptrtoint %          in L58     src = getelementptr i8 …byteoffset     root=0x2a1a8058  USE: sub    (dead=false)  → 583s ✔
ptrtoint %coercion  in L84     src = extractvalue { ptr, ptr } %.ref, 0   root=nothing  USE: icmp eq (dead=false)  → THE WALL
ptrtoint %Concurr…16 in L90    src = load @"+Core.ConcurrencyViolationError#447"        USE: inttoptr (dead=true)  → pruned
ptrtoint %Concurr…   in L96    src = load @"+Core.ConcurrencyViolationError#447"        USE: inttoptr (dead=true)  → pruned
ptrtoint %GenericMemoryRef in oob    src = load @"+Core.GenericMemoryRef#444"           USE: inttoptr (dead=true)  → pruned
ptrtoint %          in idxend  src = load ptr %memory_data_ptr38      root=0x2a85c030  USE: sub    (dead=false)  → 583s ✔
ptrtoint %          in idxend  src = getelementptr i8 …byteoffset36   root=NOTHING     USE: sub    (dead=false)  → WALL N+2
ptrtoint %GenericMemoryRef45 in oob43 src = load @"+Core.GenericMemoryRef#444"          USE: inttoptr (dead=true)  → pruned
```

* `%coercion` has **exactly one** use, and it is `icmp eq`. (P3) is satisfiable and is not a
  fiction fitted to a hoped-for shape.
* Every type-tag `ptrtoint`/`inttoptr` pair lives in a **dead** block and is pruned before
  conversion. jbko does not interact with them.
* The `idxend` entry is finding **F2** and is discussed in §5.3.

---

## 2. THE DETERMINISM ARGUMENT

*This section is written to be pasted, near-verbatim, into the arm's comment block. It is the
klgz obligation: the reject this arm carves out exists specifically to protect the
determinism floor, so the carve-out must discharge that obligation explicitly.*

> ### Why `icmp eq/ne` of a coerced in-model pointer is deterministic and reversible
>
> **The representation.** Under `ptr_cells` a pointer is not an address in the host's sense;
> it is one Int64 **VM cell value** (ADR 0018 §A). BennettVM assigns those values with a
> deterministic bump allocator over its arena, so for a fixed program and fixed inputs the
> value stored in every pointer cell is a **pure function of the execution trajectory** —
> the same program, replayed, produces the same cell values in the same order. Copying a
> pointer (a `load`/`store`, an `insertvalue`/`extractvalue`, a call argument) copies the
> cell value verbatim; nothing in the model perturbs it. Therefore:
>
> * **the coerced integer is deterministic** — it is a cell value, not a host address, and
>   the allocator that produced it is deterministic;
> * **the comparison is pure** — `icmp` reads two cells and writes one i1; it touches no
>   memory and has no ordering semantics;
> * **the comparison is reversible on the VM by the ordinary path** — `IRICmp` ingests to
>   `Define(dest, op1, predicate, op2, width)` (`BennettVM/src/ir/ingest_body.jl:112-119`),
>   the standard non-destructive SSA create, reversed under L2/L3 exactly like every other
>   `Define`. Nothing about a pointer operand changes that; the VM never learns the operand
>   was "a pointer".
>
> **Why the value may be compared but not computed with (oracle match).** Write
> `φ : native address ↦ VM cell value` for the (injective) representation map. The extracted
> program must agree with native Julia on every *observable*, and the extractor may therefore
> only admit operations `op` for which `op(φ(x), φ(y)) = op(x, y)`, i.e. operations that are
> **invariant under any injective relabelling of addresses**.
>
> * `eq` / `ne` **are** invariant: `φ(x) = φ(y) ⟺ x = y` for injective φ. Pointer equality is
>   a *location-identity* predicate, and identity survives relabelling. This is the same
>   argument the Bennett-8g7m pointer-`icmp` arm already makes for `icmp eq ptr`
>   (`instructions.jl:2902-2930`), and is why that arm admits `eq`/`ne` and only those.
> * Ordering (`ult`, `slt`, …) is **not** invariant: it compares address *magnitudes*, which
>   are a property of the allocator's layout, not of the source program. φ is injective but
>   emphatically not monotone.
> * Arithmetic is **not** invariant: BVM addressing is *cell*-granular (GEP byte offsets are
>   converted to cell offsets upstream — see the Bennett-vau9 worklog gotcha 2) while native
>   addressing is byte-granular, so φ is not even affine. `φ(x) + 8` denotes nothing.
> * Escape into memory or into a call is **not** invariant: once the coerced value is stored
>   or passed, the extractor loses the ability to prove that its only consumers are
>   φ-invariant, and a later `inttoptr` would dereference an arena-relative integer as if it
>   were an address — precisely the silent-corruption class the generic reject names.
>
> **Why the arm is exactly the invariance condition.** (P3) confines every use of the coerced
> value to `eq`/`ne`. (P4) additionally refuses a non-zero integer literal on the other side,
> because a magic-address constant is not in the image of φ (whereas `0` is, by the
> Bennett-beaw null-cell convention). Together they say: *the coerced integer is used only as
> an identity token, never as a magnitude and never as an operand of arithmetic.* Under that
> restriction the admitted pair `ptrtoint`+`icmp eq` computes the same i1 as `icmp eq ptr`
> would — a construct the extractor has admitted since Bennett-8g7m. The real corpus makes
> this concrete: Julia's guard compares both halves of one `MemoryRef`, and the `.mem` half
> **already** goes through `icmp eq ptr`. jbko admits the other half of the *same*
> comparison.
>
> **Failure mode if the model is nevertheless wrong.** The comparison feeds a branch whose
> false arm is a Julia throw block, which the Bennett-utzc pruner replaces with the
> `:__unreachable__` sink. If the guard ever evaluated the "mutated" way on the VM, the
> program **halts loudly** at the sink; it cannot silently produce a wrong value. That is a
> Rule 1 property of the surrounding shape, and it is why this arm's residual risk is
> bounded (§7, R2).

### 2.1 What the admission must NOT permit — the explicit negative list

| Must not permit | Blocked by |
|---|---|
| Ordering comparison of a coerced pointer (`icmp ult/slt/…`) | (P3) predicate filter. Probe 3 F2 → REJECT. |
| Any arithmetic on the coerced integer (`add`, `sub`, `mul`, `and`, shifts) | (P3) "every use is an icmp". Probe 3 F3 → REJECT. |
| Escape into memory (`store i64 %c, …`) | (P3). Probe 3 F4 → REJECT. |
| Escape into a call argument, a `ret`, a `phi`, a `select`, an `insertvalue` | (P3). |
| Round-trip back to a pointer (`inttoptr`) | (P3) rejects it as a use; and the arm is `LLVMPtrToInt`-only, exactly as 583s is, so an `inttoptr` never reaches it as an *opcode* either. |
| Truncating / widening casts (`ptrtoint ptr → i32`) | (P1) width guard, mirroring iwo9 (`:3025`) and 583s (`:3056`). |
| Comparison against a magic address literal | (P4). |
| `ptrtoint` of a **width-0 sentinel** pointer (a `phi ptr` / `select ptr`) | (P2) source whitelist. **This is the sharpest hazard — see §2.2.** Probe 3 F5 → REJECT. |
| `ptrtoint` of an out-of-model pointer (JIT global, unrecognised call result, addrspace ≠ 0) | (P2) source whitelist. |
| Anything at all on the circuit path | the whole arm sits inside `&& ptr_cells` (§4). Probe 3 F6 → REJECT, unchanged message. |

### 2.2 Why (P2) is load-bearing, not decoration

A hostile reviewer's first question will be *"if a pointer is a cell, why not admit
`ptrtoint` of **any** pointer whose uses are all `icmp eq`?"* Because **not every pointer SSA
value is a 64-bit cell in this model**. Bennett-cc0 M2b deliberately gives pointer-typed
`phi` and `select` a **width-0 sentinel** (`instructions.jl:2937` and `:2971`:
`w = LLVM.value_type(inst) isa LLVM.PointerType ? 0 : _iwidth(inst)`), with routing recorded
in `ptr_provenance` at *lowering* time rather than as a value. A `ptrtoint` of such a value
would emit `IRBinOp(dest, :or, ssa(<width-0 value>), iconst(0), 64)` and read a cell that was
never materialised — a **silent** miscompile, not a loud one. (P2)'s whitelist is what makes
the arm safe by construction: it admits only the two producer shapes that are *certified* to
stamp width 64 —

* `extractvalue` of a ptr field → `_struct_field_widths` stamps **64**
  (`instructions.jl:75-81`), and
* `load` with `PointerType` result under `ptr_cells` → `IRLoad(dest, …, 64)`
  (`instructions.jl:3912`, the Bennett-ares arm: *"ptr→cell width 64"*).

Everything else — including cases that are probably sound, such as a
`julia.gc_alloc_obj` call result — is rejected. Rule 1 prefers a conservative loud reject to
an unverified admission; widening the whitelist is a one-line change *plus a fixture*.

---

## 3. Downstream: what the ParsedIR and the VM actually do

### 3.1 Emitted IR (probe 3, fixture F1, measured)

F1 is the hand-written analogue of `%L84`: build a `{ptr,ptr}`, extract both halves, coerce
one, compare both, `and`, `select`.

```
F1 benign  →  ACCEPT
   block top
      IRInsertValue(:a0,  ZeroAggSentinel(), SSAOperand(:p), 0, 0, 2, [64, 64])
      IRInsertValue(:ref, SSAOperand(:a0),   SSAOperand(:q), 1, 0, 2, [64, 64])
      IRExtractValue(:po, SSAOperand(:ref), 0, 0, 2, [64, 64])
      IRExtractValue(:pm, SSAOperand(:ref), 1, 0, 2, [64, 64])
      IRBinOp(:c, :or, SSAOperand(:po), ConstOperand(0), 64)      <-- the jbko emission
      IRICmp(:eq,  :eq, SSAOperand(:cap), SSAOperand(:c),  64)
      IRICmp(:eq2, :eq, SSAOperand(:q),   SSAOperand(:pm), 64)    <-- the 8g7m arm, unchanged
      IRBinOp(:both, :and, SSAOperand(:eq), SSAOperand(:eq2), 1)
      IRSelect(:sel, SSAOperand(:both), ConstOperand(111), ConstOperand(222), 64)
      term: IRRet(SSAOperand(:sel), 64)
   args=[(:p, 64), (:q, 64), (:cap, 64)] ret_width=64
```

Note the emission is byte-identical in *form* to what iwo9 and 583s already emit —
`IRBinOp(dest, :or, src, iconst(0), 64)` — so no new `IRInst` type, no new BVM opcode, and
the "real SSA def, not const-prop" consensus decision 3 of iwo9 is preserved.

### 3.2 The `icmp` under BVM

`BennettVM/src/ir/ingest_body.jl:112-119`:

```julia
elseif inst isa Bennett.IRICmp
    # IRICmp.width is the OPERAND width (the i1 result is never masked) …
    return Define(inst.dest, _lower_operand(inst.op1), inst.predicate,
                  _lower_operand(inst.op2), inst.width)
```

The operands are `SSAOperand`s naming ordinary 64-bit cells. BVM never learns one of them was
a pointer. **Zero BVM src changes** — the fifth bead in a row on this arc.

### 3.3 End-to-end on the VM (probe 3, measured)

```
BVM E2E on F1
  p=100 q=200 cap=100 [L2] halted=true  sel=111   unrun exact=true hist_empty=true
  p=100 q=200 cap=100 [L3] halted=true  sel=111   unrun exact=true hist_empty=true
  p=100 q=200 cap=999 [L2] halted=true  sel=222   unrun exact=true hist_empty=true
  p=100 q=200 cap=999 [L3] halted=true  sel=222   unrun exact=true hist_empty=true
  p=0   q=0   cap=0   [L2] halted=true  sel=111   unrun exact=true hist_empty=true
  p=0   q=0   cap=0   [L3] halted=true  sel=111   unrun exact=true hist_empty=true
```

Both branches of the guard exercised (equal → 111, unequal → 222), both history regimes,
`unrun!` byte-exact with a drained history in every case.

### 3.4 The branch and the throw arm — already handled, nothing new

`%L90` is `unreachable`-terminated, so it is in the utzc `dead_blocks` set (probe 2 lists it
explicitly). `module_walk.jl:433-452` therefore replaces its body with `IRInst[]` and its
terminator with `IRBranch(nothing, :__unreachable__, nothing)`, keeping the predecessor's
conditional branch. Consequences worth stating because they remove work people will expect:

* The `@jl_global#1111` load, the `j_ConcurrencyViolationError_1108` call, the
  `julia.gc_alloc_obj` and the `ijl_throw` inside `%L90` are **never converted**. The
  Bennett-3vf2 dead-use drop is **not** needed here — 3vf2 exists for loads that codegen
  *hoisted out* of the dead block; this one was not hoisted.
* `_assert_dead_block_is_throw_skeleton` is satisfied (`%L90` contains `ijl_throw`), so the
  "surprising unreachable block" guard does not fire.
* `_assert_dead_block_no_live_escape` is satisfied trivially (`%L90` has no successors).
* At VM run time a guard failure lands on the `:__unreachable__` halt sink — a loud trap.

The i1 algebra after the `icmp` (`and i1 true, …`, `and`, `xor`, `xor`, `br`) needs nothing
new: probe 2 walked straight through all of it to `%L93` once the coercion was admitted.

---

## 4. `ptr_cells` gating and circuit-path byte-identity

* The new arm is placed **inside** the existing `if (opc == LLVMPtrToInt || opc ==
  LLVMIntToPtr) && ptr_cells` block (`instructions.jl:3010`). With `ptr_cells=false` there is
  no arm at all and the opcode falls through to the pre-existing "unsupported LLVM opcode"
  reject — the same argument iwo9 (`:3008-3009`) and 583s (`:3047-3049`) make.
* The two new helpers are **pure predicates over LLVM values**; nothing calls them outside
  the gated arm.
* No `IRInst` type changes, no `lower.jl` changes, no `gates.jl` changes → the circuit path
  cannot observe the diff.
* **Gate-count baseline, measured at HEAD `73712d3` before any change**:

  ```
  $ julia --project --check-bounds=yes test/test_gate_count_regression.jl
  Test Summary:                   | Pass  Total  Time
  Gate count regression baselines |   39     39  8.3s
  ```

  The implementer must re-run this and report **39/39**. Anything else means the arm leaked
  out of the gate.
* Fixture F6 (probe 3) is the *gate-genuinely-gates* witness: the same `.ll`, extracted at
  `ptr_cells=false`, rejects — though note it rejects **earlier**, at the 6bu3 ptr-field
  reject on the `insertvalue`, not at the `ptrtoint`. That is expected (a `{ptr,ptr}`
  aggregate is itself gated) but it means F6 is *not* a witness that the **ptrtoint arm**
  is gated. §8 adds a dedicated fixture for that.

---

## 5. Insertion points, ordering, and interaction with the existing arms

### 5.1 Exact insertion points

**(1) Helpers — `src/extract/instructions.jl`, new block immediately after
`_verify_memdata_bounds_cluster` ends at line 284** (i.e. new code at `:286+`, before the
`_gc_loaded_dst_elem_ref` docstring at `:286`). Placing them here, adjacent to the 583s
provenance helpers, keeps all `ptrtoint` soundness machinery in one place — the same
"pin the coupling next to the oracle" convention 3vf2 used when it put
`_all_uses_in_dead_blocks` next to `_vec_vm_dead_blocks`.

```julia
# ---- Bennett-jbko / CW-D: identity-use ptrtoint (pointer-equality guards) ----
#
#   %po  = extractvalue { ptr, ptr } %ref, 0     ; a CERTIFIED 64-bit cell (6bu3)
#   %c   = ptrtoint ptr %po to i64               ; a no-op re-typing under ptr_cells
#   %eq  = icmp eq i64 %captured, %c             ; the ONLY admitted use shape
#
# <<< the determinism argument of §2 goes here, verbatim >>>

# (P2) Is `v` a pointer SSA value that ptr_cells has CERTIFIED as one 64-bit cell?
# Deliberately a positive whitelist of the two producer shapes that are *proven* to
# stamp width 64, NOT a "is a pointer" test: `phi ptr` / `select ptr` carry the
# Bennett-cc0 M2b WIDTH-0 SENTINEL, and coercing one would read a cell that was never
# materialised (a SILENT miscompile). Depth-0 by design — no chain walk, no recursion.
function _is_cell_valued_ptr(v)::Bool
    v isa LLVM.Instruction || return false
    ty = LLVM.value_type(v)
    ty isa LLVM.PointerType || return false
    LLVM.addrspace(ty) == 0 || return false          # addrspace-0 only (cf. 7wsz)
    opc = LLVM.opcode(v)
    if opc == LLVM.API.LLVMExtractValue
        # width 64 comes from _struct_field_widths' PointerType arm
        return LLVM.value_type(LLVM.operands(v)[1]) isa LLVM.StructType
    elseif opc == LLVM.API.LLVMLoad
        return true                                   # IRLoad(dest, …, 64) under ptr_cells
    end
    return false
end

# (P3)+(P4) Every use of `pt` is an `icmp eq/ne` whose sibling is not a NON-ZERO integer
# literal. Zero IS admitted: it is φ(null) under the Bennett-beaw null-cell convention.
# Zero uses ⇒ false (the 583s / 3vf2 conservatism: a use-less coercion is evidence the
# walker's picture is incomplete, not evidence of a modelled construct).
function _all_uses_are_identity_icmp(pt::LLVM.Instruction)::Bool
    saw = false
    for u in LLVM.uses(pt)
        saw = true
        usr = LLVM.user(u)
        (usr isa LLVM.Instruction &&
         LLVM.opcode(usr) == LLVM.API.LLVMICmp) || return false
        LLVM.predicate(usr) in (LLVM.API.LLVMIntEQ, LLVM.API.LLVMIntNE) || return false
        ops = LLVM.operands(usr)
        length(ops) == 2 || return false
        sib = ops[1].ref == pt.ref ? ops[2] : ops[1]
        if sib isa LLVM.ConstantInt && _const_int_as_int(sib) != 0
            return false
        end
    end
    return saw
end
```

**(2) The arm — `src/extract/instructions.jl:3035`**, i.e. **between** the end of the iwo9
type-tag arm (`:3034`, the closing `end` of `if src isa LLVM.Instruction && src.ref in
tag_ssa`) and the start of the 583s comment block (`:3035`).

```julia
        # Bennett-jbko / CW-D: identity-use ptrtoint. See the helper block above for
        # the determinism argument. LLVMPtrToInt-only (an `inttoptr` of an in-model
        # pointer is the forbidden escape, exactly as in 583s).
        if opc == LLVM.API.LLVMPtrToInt && _is_cell_valued_ptr(src) &&
           _all_uses_are_identity_icmp(inst)
            srt = LLVM.value_type(src); drt = LLVM.value_type(inst)
            src_w = srt isa LLVM.PointerType ? 64 : _iwidth(src)
            dst_w = drt isa LLVM.PointerType ? 64 : _iwidth(inst)
            (src_w == 64 && dst_w == 64) || _ir_error(inst, "…jbko width guard…")
            return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
        end
```

**(3) The generic reject message — `instructions.jl:3071-3078`** gains a jbko clause naming
the two ways a near-miss can fail (`the source is not a certified cell-valued pointer` /
`a use is not an icmp eq/ne`), in the spirit of the "near-miss diagnostics" half of the 3vf2
adjudication. The existing substrings (`Bennett-iwo9`, `type-tag`, `ARENA_BASE`) must be
**retained** — neighbouring tests assert them.

### 5.2 Why jbko goes BEFORE 583s, and why that is provably non-regressive

The two arms are **disjoint on any input with ≥ 1 use**: 583s requires *every* use to be a
`sub`; jbko requires *every* use to be an `icmp`. A value cannot satisfy both unless it has
zero uses, and both arms reject zero uses. Therefore:

* No input that 583s accepts today is diverted to jbko. 583s's contract is untouched.
* Placing jbko **first** additionally lets a `.data`-base `ptrtoint` whose uses are all
  `icmp eq/ne` be admitted rather than hitting 583s's cluster fail-loud — a strict widening
  in the sound direction, since a `load ptr` source satisfies (P2) by the same
  cell-identity argument.
* Placing jbko **after** 583s would *not* achieve that: 583s **errors** rather than falling
  through when its cluster check fails, so it would shadow jbko for memdata-provenanced
  sources.

The iwo9 type-tag arm stays **first** unconditionally: a type-tag value is in `tag_ssa` and
must keep inheriting tag provenance via `push!(tag_ssa, inst.ref)`, which jbko does not do.
(In today's corpus every type-tag `ptrtoint` is inside a pruned block anyway, so the ordering
is belt-and-braces.)

Final dispatch order inside the `ptr_cells` block:

```
iwo9 type-tag round-trip  (src ∈ tag_ssa)          → identity + tag provenance
jbko identity-use         (cell-valued src, all-icmp uses)  → identity            [NEW]
583s memdata base-cancel  (memdata root, all-sub-same-root uses) → identity
generic fail-loud                                                     [message extended]
```

### 5.3 What jbko does NOT clear (deliberately)

* **`%86` in `%idxend` (finding F2).** Its use is a `sub`, so (P3) rejects it; it falls
  through to 583s, whose `_memdata_root` returns `nothing` because the base pointer is
  `%memoryref_data29 = load ptr, ptr %32` with `%32 = self + 56` — a **closure capture**,
  not a `{i64,ptr}` field-1 GEP. This is a genuine, separate gap: 583s's *root* notion needs
  to cover "a `MemoryRef.ptr_or_offset` read out of a capture", and its *same-root* proof
  needs re-deriving for that case (the sibling `%85` roots at the `Memory` header, so the
  bases do **not** cancel in the 583s sense at all). **File as a new bead.** Confusing it
  with jbko would smuggle an unproven base-cancellation past the determinism floor.
* **`Bennett-kvdv`.** Probe 4, under `--check-bounds=yes` (the suite mode), *before* any
  patch:

  ```
  check-bounds mode: 1
  BASELINE:         EXTRACTS OK — ret_width=72 blocks=54
  WITH-JBKO-PATCH:  EXTRACTS OK — ret_width=72 blocks=54
  ```

  kvdv's wall is **already gone** — Bennett-583s cleared it, and the bead (P3, OPEN) is
  stale. jbko changes nothing there (identical `ret_width` and block count). Recommend
  closing kvdv with this transcript, and *not* claiming it as a jbko deliverable.

---

## 6. The alternatives, weighed honestly

### (a) Extend `_memdata_root` to see through `extractvalue`

**Rejected.** Two independent reasons, both fatal:

1. **The provenance is not there.** `_memdata_root` seeds on `load ptr` of a `{i64,ptr}`
   field-1 GEP. `%.ref.ptr_or_offset` traces back through `extractvalue` → `insertvalue`
   chain → `%55 = load ptr, ptr %54` where `%54 = getelementptr { ptr, ptr }, ptr %1, 0, 0`.
   The base `%1` is a `MemoryRef` object loaded out of the GC-roots array — **not** a
   `GenericMemory` header. Making `_memdata_root` return a root here would require it to
   accept `{ptr,ptr}` field-0 GEPs as well as `{i64,ptr}` field-1 GEPs, i.e. to stop meaning
   "the `.data` base of a `GenericMemory`". That is a redefinition of the 583s root, and
   `_memdata_root` is consumed by 583s's **same-root** proof — silently changing what "same
   root" means is exactly the interlocked-bug class of Rule 7.
2. **The use contract does not fit.** `_verify_memdata_bounds_cluster`
   (`instructions.jl:265-284`) requires *"EVERY use of the memdata ptrtoint `pt` must be a
   `sub i64` whose sibling operand is a ptrtoint of a SAME-ROOT memdata pointer."* An
   `icmp eq` use fits none of it. So (a) needs a **new use contract anyway** — it is (b) plus
   a gratuitous perturbation of 583s. Strictly dominated.

*(The (a)-shaped monkey-patch was nevertheless the right probe vehicle: it reaches the
identical emission `IRBinOp(dest,:or,src,iconst(0),64)` through code already on the gated
path, which is what makes the probe-2/3/4 results transferable to (b).)*

### (c) Pattern-match the whole guard and fold it

**Rejected.** The recogniser would have to match `extractvalue` + `insertvalue` chain +
`load i64` from a capture + `ptrtoint` + `icmp eq` + `and i1 true` + a second `icmp eq ptr` +
`and` + `xor` + `xor` + `br` — eleven instructions of pure codegen incident. Rule 5 says LLVM
IR output is not a stable API; a recogniser this shape-specific is a re-break on every Julia
minor release, and its failure mode is a *silent* non-match falling into a confusing generic
reject. It also *hides* the guard rather than modelling it, which means the extracted program
would no longer contain the check — a semantic difference (BVM would not trap if the guard
genuinely failed). (b) keeps the guard as a real, executed, reversible comparison. Two
instructions of new logic beat eleven of pattern.

*One idea from (c) is worth keeping as an optional tightening (§7, R2): additionally
requiring that the `icmp` result reach a branch condition through i1 algebra only. Recommend
**not** taking it in v1 — it is more Julia-version surface for a residual that is already
loud-by-construction.*

---

## 7. Risk register

| # | Risk | Severity | Mitigation / status |
|---|---|---|---|
| **R1** | (P2)'s `load ptr` arm is broader than the corpus needs and admits a coercion of any loaded pointer. | Med | Bounded by (P3)+(P4): the coerced value can only be equality-compared. Documented as the *reason* 583s-provenanced sources also become admissible (§5.2). Adversarial fixtures pin every non-icmp use as REJECT. |
| **R2** | (P4) admits `icmp eq` against a non-constant i64 that is a *genuine integer*, not a φ-image (e.g. a hash compared to an address). | Med | The extractor cannot distinguish these without an inter-procedural "is this integer a pointer" analysis. Accepted residual, with three arguments: (i) such a comparison has no portable meaning in the source language; (ii) in Julia codegen these comparisons are guards whose false arm is a throw block, so a wrong answer *halts loudly* at the `:__unreachable__` sink rather than producing a wrong value; (iii) the tightening lever exists (require the i1 to reach a `br` through i1 algebra only) and can be added without redesigning the arm. **File as a P3 follow-up bead.** |
| **R3** | Julia re-emits the guard in a different shape next release (e.g. `icmp eq ptr` on both halves, or an `inttoptr` on the captured side). | Low | If it becomes `icmp eq ptr`, the arm goes unused and 8g7m handles it — no breakage. If it becomes an `inttoptr`, the arm does not apply and we get a loud reject, not a miscompile. The unit fixtures are hand-written `.ll` and decoupled from `_growend!` (the 3vf2 convention), so only the corpus-landing pins move. |
| **R4** | Someone later widens `_is_cell_valued_ptr` to "any pointer" and reintroduces the `phi ptr` width-0 hazard. | **High if it happens** | The width-0-sentinel rationale must be written into the helper's comment as the *reason for the whitelist* (§5.1 draft does this), and fixture F5 (`ptrtoint` of a `phi ptr` → REJECT) must be a committed regression test, not just a probe. |
| **R5** | The real corpus guard evaluates FALSE on BVM (the captured cell and the live cell disagree because the two write paths represent the pointer differently). | Med, **unverifiable this session** | Blocked behind F1/F2 (two further walls), so it cannot be tested end-to-end yet. Failure is loud (`:__unreachable__` halt), never silent. Must be called out in the bead close notes as an *unverified* downstream property, not asserted. |
| **R6** | Gate (I)/(J) do not go red on landing (finding F7), so the frontier marker silently stops tracking. | Med | Both landing disjunctions already contain `Bennett-lgzx`/`U114`. The advance **must** add `@test !occursin("Bennett-iwo9", msg)` and `@test !occursin("ptrtoint", msg)` — see §8 (5). Without that, jbko lands with a green test that proves nothing. |
| **R7** | The generic reject message loses a substring a neighbouring test asserts. | Low | `test_iwo9_*` / `test_583s_*` / `test_klgz_*` assert on that message. Extend, never rewrite; re-run the whole `ptr_cells` family (§8 (6)). |
| **R8** | The arm accidentally reaches the circuit path. | Low | Structurally impossible (inside `&& ptr_cells`), but pinned by a dedicated gate-witness fixture (§8 (4)) and by 39/39. |

---

## 8. Test plan (RED-GREEN)

New file: `test/test_jbko_identity_use_ptrtoint.jl`, registered in `test/runtests.jl`.
Driver: the 3vf2 `mktempdir` + `extract_parsed_ir_from_ll(path; entry_function=…,
ptr_cells=…)` helper, copied verbatim (Rule 12).

**RED first.** Every fixture below is written and run *before* the arm exists. (1) must fail
with the generic iwo9 message; (2)-(3) must already pass (they are anti-regression, and
passing red is the point); the file must be committed only after (1) flips.

1. **(a) The guard shape → ACCEPT, asserted as VALUES not "no error".**
   Fixture F1 of probe 3. Assert the exact instruction list of §3.1: the
   `IRBinOp(:c, :or, SSAOperand(:po), ConstOperand(0), 64)`, and that the *sibling* half is
   still `IRICmp(:eq2, :eq, …)` from the untouched 8g7m arm. Assert
   `args == [(:p,64),(:q,64),(:cap,64)]`, `ret_width == 64`.

2. **(b) Adversarial rejects — one fixture per forbidden use, all four measured REJECT in
   probe 3.** Ordering `icmp ult` (F2); arithmetic `add i64 %c, 8` (F3); `store i64 %c` (F4);
   zero uses (F7). Plus two the probe did not need but the arm must refuse: `inttoptr i64 %c
   back to ptr`, and `ptrtoint ptr %po to i32` (the width guard). Each asserts the message
   names `Bennett-jbko` **and** retains `Bennett-iwo9`.

3. **(c) The width-0-sentinel hazard — the most important test in the file (R4).**
   Fixture F5: `%pp = phi ptr [...]` → `ptrtoint` → `icmp eq`. Must REJECT, with a comment
   block explaining that admitting it would read an unmaterialised cell. This is the test a
   "simplify the whitelist to any pointer" refactor cannot pass. Companion: the same shape
   with `select ptr`.

4. **(d) Gate witness — the arm genuinely gates.** F6 as written is *not* a witness (probe 3
   shows it rejects earlier, at the 6bu3 ptr-field reject). Use instead a fixture whose only
   `ptr_cells`-dependent construct is the `ptrtoint` itself — a `load ptr` source rather than
   an `extractvalue` source:
   `%p2 = load ptr, ptr %q` → `ptrtoint` → `icmp eq`. Same `.ll`, two modes: ACCEPT at
   `ptr_cells=true`, "unsupported LLVM opcode" reject at `false` (the vau9 one-file
   gate-witness convention).

5. **(e) Corpus advancement pins — ADVANCE, do not delete (finding F7 / R6).**
   * `test/test_40ys_instanceless_callees.jl` gate (I) (`:451`): add
     `@test !occursin("Bennett-iwo9", e.msg)` and `@test !occursin("ptrtoint", e.msg)`,
     and extend the comment block with the jbko paragraph. The landing disjunction already
     admits `Bennett-lgzx`/`U114`, which is where it now lands.
   * `test/test_7wsz_ptr_sret_fields.jl` gate (J) (`:468-505`): the same two negatives.
   * The measured next wall, for the comment block (probe 2, on the REAL gated path, at
     `ptr_cells=true`):

     ```
     SET WALL: julia_set.jl: … extraction FAILED for callee `#_growend!##0#…` —
       ir_extract.jl: store in @julia_#_growend!##0_32430:%L93:
       store { ptr, ptr } %memory_ref12, ptr %1, align 8 —
       store of non-integer type LLVM.StructType({ ptr, ptr }) not supported
       (Bennett-lgzx / U114).
     ```

     **Correct the bead's forecast in the close notes**: there is no 8-byte sret-reassembly
     memcpy on the live path (the only 8-byte `llvm.memcpy` in the function is in `%oob43`,
     a pruned dead block). Next walls are lgzx/U114 at `%L93`, then the `%idxend` ptrtoint
     of finding F2.

6. **(f) Cross-repo BVM E2E — honestly runnable, so run it.** New
   `BennettVM.jl/test/test_jbko_identity_use_ptrtoint_vm.jl`: extract F1 through the real
   front-end, `lower_vm`, then for both branch outcomes × both history regimes assert
   `is_halted`, the exact `result` dict entries, input preservation, `unrun!` exactness and
   `isempty(s.history)`. Probe 3 §3.3 is the measured oracle. Header must state that BVM has
   **zero** src changes and that this file is end-to-end confidence, not a gate on jbko
   (the 3vf2 convention).

7. **(g) Regression re-run set.** `--check-bounds=yes` for all of it (the 2mj3/figa lesson —
   a per-file green claim only counts in suite mode):
   `test_iwo9_*`, `test_583s_*`, `test_klgz_determinism_guard.jl` (shares the reject site),
   `test_8g7m_*` / the ptr-icmp pins, `test_6bu3_*`, `test_utzc_dead_block_pruner.jl`,
   `test_3vf2_dead_use_global_load.jl`, `test_7wsz_ptr_sret_fields.jl`,
   `test_40ys_instanceless_callees.jl`, `test_vau9_variable_memmove.jl`,
   `test_59zi_sret_call_memcpy.jl` (its kvdv-wall assertion may need updating — see F6), and
   `test_gate_count_regression.jl` **which must print 39/39**. Then a full `Pkg.test()` in
   both repos.

8. **(h) Bead hygiene.** Close `Bennett-kvdv` with the probe-4 transcript. File two new
   beads: the `%idxend` capture-rooted `ptrtoint` (F2) and the R2 tightening lever.

---

## 9. Probe transcripts

All scripts are in the session scratchpad with prefix `jA_`. Julia discipline: one process at
a time, `pgrep` verified `CLEAR` before each run; four runs total.

### 9.1 `jA_probe1.jl` — the real post-pass IR

```
instance-less hits: 1
key = Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64, Int64, Int64, Int64, Int64, Memory{Int64}, MemoryRef{Int64}}
raw length = 28074
effective passes = ["sroa", "mem2reg"]
DONE
```

Output: `jA_growend_raw.ll`, `jA_growend_post.ll` (486 lines, 46 blocks). Block order,
which is the order the converter walks and therefore the order walls fire in:

```
top, L8, L9, L12, L13, L20, L25, L46, L55, L56, L58, L62, L71, L73, L74, L76, L77, L78,
L79, L81, L84, L90, L93, L96, after_throw, after_noret, fail, pass, fail9, pass10,
after_throw19, after_noret20, oob, idxend, oob43, idxend48, after_noret51, fail56, pass57,
fail61, pass62, emptymem, nonemptymem, fail67, pass68, retval, guard_pass, guard_exit,
guard_pass70, guard_exit71
```

`%L84` precedes `%L93` precedes `%idxend`, which is why the walls appear in that order.

### 9.2 `jA_probe2.jl` — use census + next wall on the REAL gated path

Part (i) is reproduced in §1.4. Part (ii) applies the monkey-patch (two `@eval Bennett`
redefinitions — **no `src/` file touched**, the 7wsz probe convention) and re-runs the real
entry points:

```
--- closure alone (extract_parsed_ir_by_sig) ---
CLOSURE WALL: ir_extract.jl: store in @julia_#_growend!##0_2495:%L93:
  store { ptr, ptr } %memory_ref12, ptr %1, align 8 — store of non-integer type
  LLVM.StructType({ ptr, ptr }) not supported (Bennett-lgzx / U114). …

--- full closed-world set (the real corpus path) ---
SET WALL: julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
  `#_growend!##0#a7027856` … ir_extract.jl: store in @julia_#_growend!##0_32430:%L93:
  store { ptr, ptr } %memory_ref12, ptr %1, align 8 — store of non-integer type
  LLVM.StructType({ ptr, ptr }) not supported (Bennett-lgzx / U114). …
```

Both entry points agree, and both are `ptr_cells=true` — the gate value is stated, per the
7wsz lesson that an ungated monkey-patch forecast is worthless.

### 9.3 `jA_probe3.jl` — fixture family + BVM E2E

```
F1 benign             →  ACCEPT   (instruction list in §3.1)
F2 ordering-icmp      →  REJECT   "…result is NOT confined to a same-Memory base-cancelling
                                   bounds check (a use is not a same-root sub…)"
F3 arithmetic         →  REJECT   (same)
F4 store-of-coerced   →  REJECT   (same)
F5 ptr-phi source     →  REJECT   "…source is NOT a recognised Julia type-tag value
                                   (Bennett-iwo9 / CW-D3 Lever 1)…"
F6 F1 @ ptr_cells=false → REJECT  "…StructType field 0 of { ptr, ptr } is a pointer field,
                                   which requires ptr_cells=true … (Bennett-6bu3)"
F7 zero-use           →  REJECT   (same as F2)
```

Reject *messages* are the monkey-patch's (583s / iwo9), not the final arm's; the shipped arm
must name `Bennett-jbko`. What the probe establishes is the **decision** in each case, which
is exactly the (P1)-(P4) predicate. F6's early rejection is the caveat noted in §4.

BVM E2E transcript in §3.3.

### 9.4 `jA_probe4.jl` — kvdv interaction, under `--check-bounds=yes`

```
check-bounds mode: 1
BASELINE:        EXTRACTS OK — ret_width=72 blocks=54
WITH-JBKO-PATCH: EXTRACTS OK — ret_width=72 blocks=54
DONE
```

### 9.5 Gate-count baseline at HEAD, pre-change

```
$ julia --project --check-bounds=yes test/test_gate_count_regression.jl
Test Summary:                   | Pass  Total  Time
Gate count regression baselines |   39     39  8.3s
```

---

## 10. Implementation checklist

1. Write `test/test_jbko_identity_use_ptrtoint.jl` fixtures (a)-(d). Watch (a) go **RED**
   with the generic iwo9 message. Do not proceed until it is red for the right reason.
2. Add `_is_cell_valued_ptr` + `_all_uses_are_identity_icmp` at `instructions.jl:286`, with
   the §2 determinism argument as the comment header and the §2.2 width-0 rationale attached
   to the whitelist.
3. Add the arm at `instructions.jl:3035`, **before** the 583s comment block. Extend the
   generic reject message at `:3071-3078` with the jbko near-miss clause, retaining every
   existing substring.
4. Green (a)-(d). Confirm (b)/(c) still reject and now name `Bennett-jbko`.
5. Advance gate (I) and gate (J) with the two negatives each (§8 (5)). Verify they would have
   gone red had the negatives been present before the change — the marker must actually track.
6. Add the BVM E2E file. Confirm **zero** BVM `src/` changes.
7. Run the §8 (7) regression set under `--check-bounds=yes`; `test_gate_count_regression.jl`
   must print 39/39. Then full `Pkg.test()` in both repos.
8. Worklog: prepend a session block to the highest-numbered chunk under `worklog/`
   (`ls worklog/ | sort -r | head -1`). Record findings F1, F2, F6, F7 — every one of them is
   a "future agent would wish it knew" item, and F1/F7 in particular correct a written
   forecast and a test that would otherwise have lied.
9. Beads: close `Bennett-kvdv` (F6); file the `%idxend` capture-rooted `ptrtoint` bead (F2)
   and the R2 tightening bead. Bundle the dolt-cache churn into the source commit.
