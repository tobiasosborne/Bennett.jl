# Bennett-foz5 — DESIGN-VERIFYING SCOUT report

**Bead:** `Bennett-foz5` (P1) — "583s root extension: `%idxend` ptrtoint bounds-cluster
rooted at MemoryRef field-0 load (xkl frontier wall 7)"
**HEAD at time of scouting:** `ebcebe2` (Bennett-p06b, landed 2026-08-06)
**Scope of this document:** verification pass only. No `src/` or `test/` change was made.
**Probes:** all under
`/tmp/claude-1000/-home-tobiasosborne-Projects-Bennett-jl/4d67df94-16ac-439a-adc4-0eedba40476a/scratchpad/`
— `p01_wall.jl`, `p03_dump.jl` (→ `growend.ll`), `p04b_root.jl`, `p05_next.jl`,
`p06_next2.jl`, `p07_steal.jl`, `p08c.jl`.

---

## VERDICT UP FRONT

**The bead's scoping is FALSE, and this work must be UPGRADED to a full 3+1
(CLAUDE.md §2).**

foz5 is described as "a root-recognition widening of 583s *under 583s's own
subtraction proof*". It is measurably not that. 583s's subtraction proof **IS**
root equality (`_verify_memdata_bounds_cluster` line 852:
`_memdata_root(sib) == root`). The corpus cluster that walls has **two
structurally disjoint roots** arriving through **two different function
arguments** (probe `p04b_root.jl`), and there is **no extraction-local
derivation** that connects them. Any admission therefore rests on a *new*
soundness contract (or a named, unverifiable Julia-ABI assumption) — not on
583s's. See §4.

Everything below is still delivered so the 3+1 starts from measured ground
rather than from the bead text (which is materially wrong on the mechanism —
see §1).

---

## 1. The wall at HEAD, reproduced (probe `p01_wall.jl`)

Gated path, exactly the harness used by `test_p06b_aggregate_store.jl` (k) /
`test_vau9_variable_memmove.jl` (g) / `test_40ys` (I) / `test_7wsz` (J):

```julia
_pushfoz5(n::Int64) = begin
    v = Int64[]; push!(v, n); @inbounds v[1]
end
Bennett.extract_parsed_ir_set_from_julia(_pushfoz5, Tuple{Int64}; ptr_cells=true)
```

Verbatim wall (run under `--check-bounds=yes`):

```
julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
`#_growend!##0#a7027856` (callable=Tuple{Base.var"#_growend!##0#_growend!##1"{Vector{Int64},
Int64, Int64, Int64, Int64, Int64, Memory{Int64}, MemoryRef{Int64}}}, argtypes=Tuple{}) —
ir_extract.jl: ptrtoint in @julia_#_growend!##0_1207:%idxend41:
  %94 = ptrtoint ptr %memory_data53 to i64
— ptrtoint of a GenericMemory .data base under ptr_cells whose result is NOT confined to a
same-Memory base-cancelling bounds check (a use is not a same-root sub(ptrtoint,ptrtoint);
e.g. inttoptr-deref, store, hash, or a cross-allocation difference). An escaping
base-dependent address would break oracle match (Bennett-583s / CW-D; CLAUDE.md §1).
```

The reject **does** name 583s territory (the four advanced markers pin exactly
this). Confirmed.

### 1.1 THE BEAD TEXT IS WRONG ABOUT THE MECHANISM

> bead: "`%86 = ptrtoint ptr %memoryref_data_byteoffset36` … so `_memdata_root`
> returns nothing and it falls to the generic iwo9 reject."

Measured (`p01`, `p04b`): the walled instruction is the **other** half — the
`.data` ptrtoint, whose root **IS** recognised — and the reject is **583s's
cluster message, not iwo9's**. `test_p06b` (k) already asserts
`!occursin("Bennett-iwo9", msg)` and passes, which corroborates this. The bead's
`%86`/`%94` SSA numbers are also process-drift (Rule 5); this session saw
`%98`/`%99`.

### 1.2 The full cluster (probe `p03_dump.jl` → `growend.ll`, block `%idxend41`)

```llvm
top:
  %5  = getelementptr inbounds i8, ptr %".roots.#self#", i32 16
  %memoryref_mem44 = load ptr, ptr %5, align 8            ; captured MemoryRef .mem
...
idxend:
  %86 = getelementptr inbounds i8, ptr %"#self#::#_growend!##0#_growend!##1", i32 56
...
idxend41:                                          ; preds = %L58
  %memoryref_data43           = load ptr, ptr %86, align 8          ; captured MemoryRef field-0
  %92 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data43, 0
  %93 = insertvalue { ptr, ptr } %92, ptr %memoryref_mem44, 1        ; <-- DEAD, see §4.2
  %memoryref_byteoffset49     = mul i64 %memoryref_offset46, 8
  %memoryref_data_byteoffset50 = getelementptr i8, ptr %memoryref_data43, i64 %memoryref_byteoffset49
  %memory_data_ptr52          = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem44, i32 0, i32 1
  %memory_data53              = load ptr, ptr %memory_data_ptr52, align 8
  %98  = ptrtoint ptr %memory_data53 to i64                 ; <-- WALLED HERE
  %99  = ptrtoint ptr %memoryref_data_byteoffset50 to i64   ; <-- the offending sibling
  %100 = sub i64 %99, %98
  %memoryref_bytelen54    = mul nuw nsw i64 %memory_len51, 8
  %memoryref_isinbounds55 = icmp ult i64 %100, %memoryref_bytelen54
  %101 = xor i1 %memoryref_ovflw48, true
  %"memoryref_isinbounds&notovflw56" = and i1 %101, %memoryref_isinbounds55
  br i1 %"...56", label %idxend62, label %oob57      ; oob57 = ijl_bounds_error_int + unreachable
```

### 1.3 Provenance chain, both operands (probe `p04b_root.jl`, exhaustive over
every `ptrtoint` in the body)

| ptrtoint | source | `_memdata_root` | cluster |
|---|---|---|---|
| `[L46] %36` | `load` of field-1 GEP off `%memoryref_mem` | `%memoryref_mem` (phi) | **true** |
| `[L46] %37` | `gep i8` off that same `.data` | `%memoryref_mem` | **true** |
| `[L58] %44` | `load` of field-1 GEP off `%memoryref_mem` | `%memoryref_mem` | **true** |
| `[L58] %45` | `gep i8` chain off that `.data` | `%memoryref_mem` | **true** |
| `[L84] %coercion` | `extractvalue {ptr,ptr} %.ref, 0` | NOTHING | false → **jbko admits (corpus witness)** |
| `[idxend41] %98` | `load` of field-1 GEP off `%memoryref_mem44` | **`%memoryref_mem44`** | **false** |
| `[idxend41] %99` | `gep i8` off `%memoryref_data43` | **NOTHING** | false |

The two operands of `%100`:

* `%98` ← `%memoryref_mem44` ← `load ptr, (gep i8 %".roots.#self#", 16)`
  — the **GC-roots-array** argument.
* `%99` ← `%memoryref_data43` ← `load ptr, (gep inbounds i8 %"#self#…", 56)`
  — the **closure-environment struct** argument.

Two loads, from two *different function arguments*, with no SSA edge between
them. Julia's codegen split the captured `MemoryRef{Int64}` in half: the
GC-tracked `.mem` was hoisted into the roots array; the `.ptr_or_offset` stayed
inline in the closure at byte offset 56.

The earlier `L46` / `L58` clusters pass precisely because there both operands
descend from **one** `.data` `load`.

---

## 2. The 583s arm's contract, read in full

Source: `src/extract/instructions.jl`

* **Helpers** `756-855`: `_is_genericmemory_header_struct` (789),
  `_is_memdata_field1_gep` (799), `_memdata_root` (816),
  `_verify_memdata_bounds_cluster` (840).
* **Arm** `3825-3845`, inside the `(opc == PtrToInt || opc == IntToPtr) && ptr_cells`
  block, positioned **after** the iwo9 type-tag arm and **before** the jbko arm.
* **Call sites of `_memdata_root` outside its own recursion: exactly two** —
  `3826` (583s entry) and `3913` (jbko pin). `p06b` does **not** use it (grep;
  item 3's second half is therefore vacuous — see §3.4).

### 2.1 What "root" means today

`_memdata_root(v)`:
* **Seed:** `load` with `PointerType` result whose pointer operand is a
  `getelementptr` with source element type = a **literal, unnamed** `{i64, ptr}`
  struct at constant indices `[0, 1]`. Returns **the GEP's base operand ref**
  (the `GenericMemory` header object).
* **Propagate:** through `getelementptr` whose *source element type is `i8`*
  (the element byte-offset GEP), and through `addrspacecast` / `bitcast`.
* Depth-bounded at 8. Everything else → `nothing`.

It does **not** follow: `insertvalue`/`extractvalue` (a8nw probe P10),
`phi`/`select`, struct-typed GEPs other than the `{i64,ptr}` field-1 one,
byte-GEPs used as *field* accessors, `Argument`s.

### 2.2 The subtraction proof

`sub(ptrtoint(base + off), ptrtoint(base)) = off`. It is proved **syntactically**:
`_verify_memdata_bounds_cluster` requires *every* use of the coerced value to be
a `sub` whose sibling is a `ptrtoint` of a value with the **identical root ref**
(`==` on `_LLVMRef`). Because both descend from the *same* `.data` SSA value up
to `i8` GEPs, the difference is the sum of the GEP offsets under **any**
assignment of an integer to that cell. No model assumption, no ABI assumption.
Base-independence is *derived*, not *assumed*.

### 2.3 Reject surface

* width ≠ 64 on either side → error, message contains `"Bennett-583s"`,
  `"NON-64-bit width"`;
* cluster gate false (a use is not a same-root
  `sub(ptrtoint, ptrtoint)`, **or the ptrtoint has no uses at all**) → error,
  message contains `"Bennett-583s / CW-D"`, `"base-cancelling"`;
* `LLVMPtrToInt` only — `inttoptr` of a `.data` base is the forbidden escape and
  falls to the iwo9 reject.
* **The arm always returns or errors. There is no fall-through today.**

### 2.4 What new root shape(s) foz5 would have to add — enumerated from the
measured corpus, not from the bead

Exactly **one** new source shape is needed, and it is **not** the "`{ptr,ptr}`
field-0 GEP load" the bead names:

> **S1 — closure-captured MemoryRef data half.**
> `load ptr, ptr %g` where `%g = getelementptr inbounds i8, ptr %ARG, i32 K`,
> `%ARG` a **function `Argument`** (the closure environment `#self#`), `K` a
> constant byte offset (56 in this corpus).

That is the *only* body in the whole `push!` closed-world set that needs it:
probe `p06_next2.jl` (which seeds `_memdata_root` on exactly this shape *and*
drops root equality) clears the entire `_growend!` closure and moves the wall to
a **different callee** (§5.3).

A widening to "`load` of a `{ptr,ptr}` field-0 GEP" (the bead's phrasing) is
**both insufficient** (it does not match `%86`, which is an `i8` GEP off an
argument) **and actively harmful** (§3.2).

---

## 3. THE ORDERING HAZARD (a8nw note) — analysis

### 3.1 Does the widening introduce a fall-through?

**Only under one of the two candidate designs, and in that design the a8nw note
is inverted.**

* **Design A — widen `_memdata_root` only, keep the arm terminating.**
  No fall-through. The jbko pin `_memdata_root(src) === nothing` stays
  *redundant*, exactly as a8nw described. **But this design has a different,
  worse failure — the STEAL, §3.2.**
* **Design B — give 583s a fall-through** (newly-rooted source whose cluster gate
  fails → fall through to jbko instead of erroring).
  Then the pin does **not** become a load-bearing *guard*; it becomes a
  **BLOCKER**. `_memdata_root(src) === nothing` is *false* for exactly the values
  that were meant to fall through, so the jbko arm is unreachable for them and
  they hit the generic iwo9 reject instead. **In Design B the pin must be
  DELETED**, not kept — the opposite of the a8nw note's literal instruction.
  a8nw's underlying concern (re-check the ordering) is correct; its prescription
  ("keep it, it becomes load-bearing") is not.

### 3.2 THE STEAL — the real hazard, and it is empirically demonstrated

Probe `p07_steal.jl` implements the bead's own phrasing (root shape = `load` of a
`{ptr,ptr}` field-0 GEP, plus `insertvalue`/`extractvalue` chasing so the shape
can actually be reached) and evaluates it on the real `growend.ll`:

```
[L84] %coercion = ptrtoint ptr %.ref.ptr_or_offset to i64
   VARIANT-B root = ROOTED -> %2 = load ptr, ptr %1, align 8  ==> 583s STEALS from jbko
   cluster ok = false
```

`%coercion` is **the jbko corpus witness** (`_growend!` `%L84`, the
`ConcurrencyViolationError` guard). Today `_memdata_root` returns `nothing` for
it, so 583s declines and jbko admits it. Under the bead's phrasing of the
widening, 583s **claims** it, its cluster gate fails (the use is an `icmp eq`,
not a `sub`), and 583s **errors** — the jbko arm never runs. Result: **the push!
chain regresses to a wall at `%L84`, EARLIER than wall 7**, and
`test_jbko_ptr_identity_icmp.jl` gate (O)'s intent is inverted.

This is the single most important finding for the implementer. It is *why* the
root shape must be S1 (§2.4) and must **not** chase `insertvalue`/`extractvalue`.
Probe `p06_next2.jl` confirms S1 does **not** steal: with S1 seeded, extraction
walks past `%L84` entirely.

### 3.3 The probe the bead asks for ("BOTH new-root-matched and jbko-shaped —
which arm wins, and is that the right answer?")

`p07_steal.jl` **is** that probe, on the real corpus rather than a synthetic
fixture. Answer: **583s wins, and that is the WRONG answer** — the value is
soundly admissible under jbko's equality contract and is inadmissible under
583s's subtraction contract, so 583s winning turns a working admission into a
reject. Whatever design lands, this must be pinned (§6, gate O2).

### 3.4 p06b's `_memdata_root`-adjacent assumptions

None. `grep -n "_memdata_root" src/` yields call sites at 3826 and 3913 only.
`_p06b_cell_ptr_target_kind` / `_p06b_slot_key` / `_p06b_alias_group` are
independent of memdata rooting. **No p06b interaction.**

---

## 4. The subtraction proof under the new root — SOUNDNESS STATUS

### 4.1 The claim that would have to hold

For `%100 = sub(ptrtoint(D + byteoff), ptrtoint(M.data))` to be base-independent,
we need

> **(INV)** `D = M.data + k` for some `k` the model computes,

i.e. the closure-captured `ptr_or_offset` points **into** the `.data` block of
the `GenericMemory` that arrived, separately, through the roots array.

### 4.2 Why it is NOT derivable extraction-locally

* `D` and `M` descend from **two different `Argument`s** (`#self#` and
  `.roots.#self#`). There is no SSA edge, no dominance relation, no GEP chain
  linking them (probe `p04b_root.jl`).
* The only in-body syntactic witness pairing them is
  `%93 = insertvalue {ptr,ptr} %92, ptr %memoryref_mem44, 1` — and **`%93` is
  DEAD** (probe: `grep "%93" growend.ll` shows the def and no use). Building a
  soundness gate on a dead instruction that only survives because we extract at
  `optimize=false` is a direct Rule 5 violation.
* The alternative witness is the **byte-offset convention** ("closure field +56
  is field 0 of the captured `MemoryRef`; roots slot +16 is its field 1"). That
  is a Julia ABI/codegen layout fact of exactly the class CLAUDE.md Rule 5
  forbids relying on.
* (INV) itself additionally depends on how the *caller* materialised the
  `MemoryRef` — a **cross-function** fact, invisible to this body.
* Julia itself does not assume the two halves agree: the `%L84`
  `ConcurrencyViolationError` guard in this very function exists to compare them.

**So: the argument CANNOT be made rigorous as a subtraction/base-cancellation
proof.** Per the klgz discipline and the scout brief, this is the trigger to
upgrade.

### 4.3 The assumption, if one nevertheless chooses to name it

> **A-foz5.** For a closure-captured `MemoryRef{T}` whose `.ptr_or_offset` half is
> read from the environment struct and whose `.mem` half is read from the GC
> roots array, the BVM cell values satisfy `D = M.data + 8·i` for the ref's own
> index `i`, because the caller constructed the ref by `ptr_offset` off that same
> `.data` cell.

*Checkable?* **Not at extraction time** (cross-function, cross-argument).
**Partially at VM runtime, by the bounds check itself** — see §4.4.

### 4.4 A DIFFERENT proof that IS rigorous (and is the reason this needs a 3+1)

There is a sound admission argument available, but it is **not 583s's**:

> **Dead-throw confinement.** If (i) every use of the coerced value is a `sub`;
> (ii) each such `sub`'s only use is an `icmp ult` against an in-model value;
> (iii) that `icmp`'s transitive uses are i1-algebra only and terminate in a `br`
> one of whose edges is a **utzc-pruned dead block**; then the extracted program
> either **agrees with native on the observable (the taken edge)** or **halts
> loudly at the `:__unreachable__` sink**. It never silently miscompiles.

Every premise is extraction-locally checkable, and all three hold in the corpus:
`%100`'s sole use is the `icmp ult` (probe: only `%100` occurrences are the def
and that icmp); the icmp feeds `and` → `br`; the false edge `%oob57` is
`unreachable`-terminated and is emptied to `IRBranch(:__unreachable__)` by the
utzc pruner (`src/extract/module_walk.jl:422-460`).

But this **weakens the contract from "oracle match" to "oracle match or loud
halt"** for a class of values, which is an ADR-0017/0018-level policy change, not
a helper widening. It is also only one of at least two credible routes — the
other being **cluster elision** (recognise the whole dead `@boundscheck` cluster
and drop the ptrtoints entirely, emitting the branch as unconditionally taken).
Two credible, materially different designs with a policy trade-off between them
is precisely the CLAUDE.md §2 situation.

### 4.5 STATUS

**CANNOT make the 583s subtraction argument rigorous under the new root →
UPGRADE TO FULL 3+1.** The two proposers should be briefed on routes
§4.4-confinement and §4.4-elision, plus §4.3-named-assumption as the explicit
"do it anyway, disclosed" option, and must both address the §3.2 steal.

---

## 5. Blast radius

### 5.1 Tests that pin 583s messages / shapes (grep-verified)

| File | What it pins | Effect of foz5 |
|---|---|---|
| `test/test_583s_memdata_bounds.jl` (1)-(7) | the whole contract | **(5) CROSS_MEM is the direct encoding of root equality.** Any relaxation must keep (5) red — the carve must distinguish "two `{i64,ptr}` GenericMemory roots" (still reject) from "one memdata root + one S1 captured-ref root" (admit). (4) NON_MEMDATA (`ptrtoint` of a plain ptr `Argument`) must stay on the iwo9 wall — S1 seeds on a *load through* an argument GEP, not on an argument itself, so it is safe, but pin it. |
| `test/test_jbko_ptr_identity_icmp.jl` (O) | "a memdata `.data` source stays on the 583s arm" | Intact under Design A. Under Design B (fall-through) this gate's meaning changes and must be restated. |
| `test/test_p06b_aggregate_store.jl` (k) | 583s/`_growend!` marker | **MOVES — and breaks non-trivially, see §5.2** |
| `test/test_vau9_variable_memmove.jl` (g) | same marker | MOVES |
| `test/test_40ys_instanceless_callees.jl` (~526-531) | same marker | MOVES |
| `test/test_7wsz_ptr_sret_fields.jl` (~538-539) | same marker | MOVES |
| `test/test_59zi_sret_call_memcpy.jl:350` | `!occursin("583s / CW-D", msg)` on the **fdict/`setindex!`** path | Must stay green — that path is untouched by S1. Verify. |
| `test/test_beaw_null_ptr.jl:204`, `test/test_416r17_…:134` | comments only | none |
| `test/runtests.jl:550-562, 634-635, 658` | registration commentary | update the wall-7 note |

### 5.2 A marker collision the implementer WILL hit

`test_p06b_aggregate_store.jl` (k) currently asserts, as *load-bearing
negatives*, `@test !occursin("Bennett-p06b", msg)` and, as a positive,
`@test occursin("_growend!", msg)`.

After foz5 **both flip** (§5.3): the next wall is in the **root** body
(`_pushfoz5`, so `"_growend!"` is absent) and its message **does** contain
`"Bennett-p06b"` (it is p06b's own `julia.gc_alloc_obj` byte-granular target
refusal). The (k) negative was written to catch an *over-tight* p06b store
reject; it must be **narrowed** (e.g. to `!occursin("aggregate value", msg)` /
`!occursin("granularity", msg)`) rather than deleted, or its intent is lost.
Same care for `test_vau9` (g), `test_40ys`, `test_7wsz`.

### 5.3 THE NEXT WALL (probe `p06_next2.jl`, patched-IR on the real gated path)

With S1 seeded and root equality relaxed, the `_growend!` closure extracts
**completely** (52 blocks, probe `p08c.jl`) and the wall moves to a **different
callee — the root `_pushfoz5` itself**:

```
extraction FAILED for callee `_pushfoz5#…` — ir_extract.jl: store in @julia__pushfoz5_…:%top:
  store { ptr, ptr } %memory_ref, ptr %"new::Array", align 8
— aggregate store target is not a CERTIFIED cell pointer — it is a `julia.gc_alloc_obj` call
— the JULIA heap tier, which BennettVM stamps BYTE-granular (`_byte_cells`,
src/ir/intrinsics.jl:256-257, CW-D4 / bennettvm-9n3y). … Byte-stamped admission is a future
widening. … (Bennett-p06b, predicate `_p06b_cell_ptr_target_kind`).
```

**Forecast wall 8 = the p06b (P4b) `julia.gc_alloc_obj` byte-granular target
refusal**, which p06b's own message already flags as "a future widening". Note
this is the first wall in the chain that is in the **root** body rather than a
callee, and the first that lands on the **BennettVM cell-granularity** boundary
(`bennettvm-9n3y` / CW-D4) rather than on extraction shape recognition.

### 5.4 BennettVM

Zero BVM source changes expected. Probe `p08c.jl` dumps the widened
`_growend!` extraction's node inventory — **only pre-existing `IRInst` forms**:

```
IRBinOp 205, IRBranch 51, IRCall 3, IRCast 1, IRExtractValue 7, IRICmp 91,
IRInsertBits 2, IRInsertValue 12, IRLoad 36, IRPhi 5, IRPtrOffset 34,
IRRet 1, IRSelect 69, IRStore 4, IRVarGEP 3
```

The admitted ptrtoint lowers to the same `IRBinOp(dest, :or, SSAOperand,
ConstOperand(0), 64)` cell identity 583s already emits. No new node kind, no new
intrinsic.

---

## 6. Test plan for the implementer

Fixtures: hand-built `.ll`, hermetic (Rule 5), **with**
`target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"` (the
`test_7wsz` / `test_59zi` / `test_416r16` idiom) — needed because S1 is
byte-offset-GEP shaped. Helper idiom: `_extract_ll` from
`test_583s_memdata_bounds.jl`. New file `test/test_foz5_captured_memref_bounds.jl`,
registered in `runtests.jl` immediately after `test_583s_memdata_bounds.jl`.

**Distilled `.ll` gates**

* **(A) GREEN — the corpus shape.** `define void @f(ptr %env, ptr %roots)`;
  `%m = load ptr, (gep i8 %roots, 16)`; `%d = load ptr, (gep inbounds i8 %env, 56)`;
  `%e = gep i8 %d, %off`; `%b = ptrtoint (load ptr, (gep {i64,ptr} %m, 0, 1))`;
  `%x = ptrtoint %e`; `%s = sub %x, %b`; `%c = icmp ult %s, %len`;
  `br %c, %ok, %oob` with `%oob` = `unreachable`. Assert both ptrtoints produce
  the `IRBinOp(:or, …, 0, 64)` cell identity (reuse `_memdata_or`).
* **(B) RED — no dead-throw sink.** Same, but the false edge returns instead of
  being `unreachable`. Must reject (this is the §4.4 premise (iii) pin; skip only
  if the 3+1 picks the §4.3 named-assumption route).
* **(C) RED — escape.** The captured-half ptrtoint additionally feeds an `add`.
  Must reject.
* **(D) RED — genuine cross-object.** Two *different* env pointers. Must reject.
* **(E) INERT — `test_583s` (5) CROSS_MEM stays red**, verbatim. Re-run the
  whole `test_583s_memdata_bounds.jl` unchanged: **no assertion in it may be
  edited.** If one has to be, the widening is too broad.
* **(F) INERT — `test_583s` (4) NON_MEMDATA** stays on the iwo9 wall.

**Ordering-pin gate (from §3.2 — mandatory)**

* **(O1)** `test_jbko_ptr_identity_icmp.jl` (O) `MEMDATA_ICMP` unchanged and green.
* **(O2) NEW — the steal pin.** A fixture whose ptrtoint source is *both*
  S1-shaped *and* jbko-shaped (a `load ptr` of a byte-GEP off an argument, whose
  only use is `icmp eq` against an i64 argument). Assert the resulting behaviour
  **explicitly and by name**, so a future widening cannot silently flip which arm
  owns it. Under Design A this must document that 583s claims-and-rejects; under
  Design B, that it falls through to jbko and is admitted. Either way the gate is
  the record of the decision.
* **(O3) NEW — the corpus anti-steal.** Assert on the real gated path that the
  message, if any, does **not** mention `%L84` / the
  `ConcurrencyViolationError` guard — i.e. the jbko witness was not poached.
  Cheap proxy: `@test !occursin("Bennett-jbko", msg)`.
* **(O4)** If Design B is chosen: a unit gate asserting the jbko arm's entry
  condition no longer carries `_memdata_root(src) === nothing` (§3.1), with a
  comment citing this document — otherwise the fall-through is dead code.

**Marker advances (4 files, per §5.2)**

`test_p06b_aggregate_store.jl` (k), `test_vau9_variable_memmove.jl` (g),
`test_40ys_instanceless_callees.jl`, `test_7wsz_ptr_sret_fields.jl`:
retarget the positive from `"Bennett-583s" || "base-cancelling" || "Bennett-foz5"`
to the wall-8 marker (`"gc_alloc_obj"` / `"BYTE-granular"`), drop
`occursin("_growend!", msg)` (the wall moves to the root body), and **narrow
rather than delete** the `!occursin("Bennett-p06b", msg)` negative. Add
`!occursin("base-cancelling", msg)` as the new load-bearing negative proving
wall 7 is cleared.

**BVM E2E**

Expect **zero** `BennettVM.jl/src` changes (§5.4). A shape assertion in the
Bennett-side test (node kinds present in the widened `_growend!` extraction) is
sufficient evidence; a BVM E2E is optional and would in any case still wall at
wall 8 in the root body.

**Suite mode**

Every per-file green claim must be under
`julia --project --check-bounds=yes test/<file>.jl` — the whole `@boundscheck`
cluster this bead is about only exists in that mode.

---

## 7. Recommendation to the orchestrator

1. **Upgrade Bennett-foz5 to a full 3+1** (§4.5). Reduced-pass ratification rested
   on "settled by 583s's prior 3+1"; §4.2 shows that premise does not hold.
2. Brief both proposers with: the measured cluster (§1.2/§1.3), the S1 shape
   (§2.4), the **steal probe** (§3.2), and the three candidate soundness routes
   (§4.3 named-assumption, §4.4 dead-throw confinement, §4.4 cluster elision).
3. Correct the bead description — its stated mechanism (`_memdata_root` returns
   nothing → iwo9 reject) and its stated root shape (`{ptr,ptr}` field-0 load)
   are both wrong, and the second is the shape that causes the regression.
4. File a follow-up bead for **wall 8** (§5.3): p06b `julia.gc_alloc_obj`
   byte-granular aggregate-store target, root body, CW-D4 / `bennettvm-9n3y`
   territory.
