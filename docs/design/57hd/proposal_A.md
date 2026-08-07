# Bennett-57hd — PROPOSER A

**HEAD:** `97a188c`. **Mode:** every claim below is probe-backed under
`julia --project --check-bounds=yes` (suite mode, CLAUDE.md §Build). **No `src/`
or `test/` change was made; no commit.**

**Scout probes re-run and confirmed at HEAD** (session scratchpad):
`w01_wall.jl` (the wall + 22-marker scan), `w13_all.jl` (α over every
`sub(ptrtoint,ptrtoint)` in the root **and**, new here, in `_growend!`),
`w14_delta.jl` (δ′ over both bodies), `w15_markers.jl` (wall-11 profile),
`w16_scale.jl`.

**New probes, this session (mine):**

| probe | what it measures | why it exists |
|---|---|---|
| `w20_alphak.jl` | α **with i8-GEP stripping** (`α_k`) vs α **at displacement 0** (`α₀`), over both bodies | **α_k STEALS both of 583s's clusters. α₀ steals nothing.** §1.4 — this is the decisive route-shaping measurement and it is not in the scout. |
| `a01_only12.ll` + `a04_msg.jl` | `.ll` surgery admitting **only** `%12`, leaving `%13` | proves the contract must be a disjunct of the **arm ENTRY**, not only of the admission — §2.5 |
| `a03_noalias2.jl` | callsite `noalias` return attribute, every call in the root | **(P-α1) is CHECKABLE FROM THE IR**, not declared — §1.6 |
| `a05_alloca.jl` | every `alloca`'s use set + `nocapture` at callsite vs on the declaration | the callsite-only `nocapture` check is **insufficient** (`memcpy` carries it on the *declaration*) — a prose-vs-predicate trap, §2.3 |

---

## 0. VERDICT UP FRONT

**Route α₀ — the VALUE-IDENTITY (SAME-CELL) contract, at displacement ZERO,
shipped as ADR 0017 §4b.**

Four things decide it, each measured rather than argued:

1. **α₀ is the only route on the table that is an ORACLE-MATCH contract, and it
   is the strongest of the four contracts in the file.** 583s's difference is
   invariant under base translation; jbko's `eq`/`ne` is invariant under
   *injective* relabellings φ; α₀'s difference is `0` and is therefore invariant
   under **any** relabelling, injective or not. It carries **no representation
   premise at all** (§1.2). Consequently the scout §9 composition rule is
   **satisfied, not negotiated**: §4a's and jbko's theorems are not downgraded,
   because nothing unproved is placed outside `τ` (§1.5).
2. **The §3.3 escape objection EVAPORATES under α₀ rather than being confined.**
   `sub ≡ 0` ⇒ `udiv exact 8 ≡ 0` ⇒ `%14 ≡ 1` ⇒ `%16 ≡ %11` (`= size+1`). The
   allocation size handed to `jl_alloc_genericmemory_unchecked` and the length
   handed to `llvm.memmove` are then pure functions of the array size — **no
   arena-dependent quantity ever enters the escaping chain.** That is why α₀
   needs no confinement story: it removes the layout dependence instead of
   bounding its damage.
3. **α₀'s 1-of-3 coverage costs ZERO frontier progress today.** Measured by
   `.ll` surgery (§1.7): admitting `%top` lands on wall 11 (`Bennett-37mt` /
   `8bys`) and then wall 12 (`Bennett-p06b` / `1zow`). The `%L21` / `%L43`
   clusters that δ′ would additionally cover sit **behind both**. δ′'s extra 2/3
   is unrealisable until `8bys` and `1zow` land, and it is bought with a
   declared premise whose failure mode is a silent wrong heap. **That is a bad
   trade taken now and a fine trade taken later, with runtime evidence in hand.**
4. **α₀'s runtime leg is payable IMMEDIATELY**, and partly pre-paid. Its VM-side
   premise (P-α3) is exactly the fact `BennettVM/test/test_bvmd_byte_tier_vm.jl`
   gate (2) already **executes** ("the class-A byte read and the class-D struct
   read of the SAME field return the SAME pointer, and it is the one the
   aggregate store wrote"). foz5's validation debt had to wait for a wall to
   clear; α₀'s does not (§4.4).

**Disposed of explicitly:** δ′ (§7.1 — declined *now*, with the sequencing
argument and the follow-up bead), γ-a / γ-b (§7.2), ε (§7.3), β (§7.4 —
already refuted, not re-proposed).

**Coverage, measured over both corpus bodies (`w20_alphak.jl`):**

| body | cluster | blk | 583s | foz5 §4a | **α₀** | α_k (rejected) | δ′ |
|---|---|---|---|---|---|---|---|
| root | `%memoryref_offset` | `%top` | false | false | **TRUE** ← wall 10 | true | true |
| root | `%45` | `%L21` | false | false | false | false | true |
| root | `%59` | `%L43` | false | false | false | false | true |
| `_growend!` | `%38` | `%L46` | **true** | — | false | **true ← STEAL** | false |
| `_growend!` | `%46` | `%L58` | **true** | — | false | **true ← STEAL** | false |
| `_growend!` | `%100` | `%idxend41` | false | **true** | false | false | false |

**α₀ claims exactly one cluster in the entire two-body corpus, and it is wall
10.** The non-steal is structural (§1.4), not ordering-dependent.

---

## 1. Route and the full soundness argument

### 1.1 The claim, in one sentence

`%13 = ptrtoint ptr %7` and `%12 = ptrtoint ptr %memory_data3` coerce **the same
pointer value under two SSA names**, so `%memoryref_offset = sub %13, %12` is
identically `0` in the native program *and* in BennettVM, on every input, under
any assignment of integers to pointer cells.

Measured (`w13_all.jl`, verbatim trace at HEAD):

```
CLUSTER %memoryref_offset = sub i64 %13, %12  [blk=top]
   583s root-eq : false
   alpha val-eq : true   (pval=%memory_data vs %memory_data)
     FORWARD %7 = load ptr, ptr %6 <= field 0 of store { ptr, ptr } %memory_ref, ptr %"new::Array"  ==> %memory_data
     FORWARD %9 = load ptr, ptr %8 <= field 1 of store { ptr, ptr } %memory_ref, ptr %"new::Array"  ==> %"jl_global#93"
     RELOAD  %memory_data3 = load ptr, ptr %memory_data_ptr2 == %memory_data   [no clobber between]
```

Every instruction in that derivation lives in the **single basic block `%top`**
(`rootmod.ll:17-63`; verified by direct inspection this session — the block
`L16:` does not begin until 12 instructions after `%memoryref_offset`). §2.2
turns that observation into a hard predicate precondition.

### 1.2 THE THEOREM (the arm's docstring form)

> **Definitions.** Let `pt` be a `ptrtoint ptr %S to i64` under `ptr_cells`.
> Write `canon(v)` for the value-identity canonicaliser of §2.4 — a
> **single-basic-block**, depth- and scan-capped walk that rewrites a
> pointer-result `load` to the value provably last written to the same canonical
> slot, forwarding through `insertvalue` chains of aggregate stores and through
> same-slot reloads, and that returns the value itself whenever it cannot prove
> a unique writer.
>
> **`_57hd_value_identity_cluster(pt)` holds iff:**
>
> * **(A0)** `%S` is a **certified materialised cell** — `_foz5_cert_src_kind(%S) !== :none`
>   — and is a named, non-suppressed instruction. *(Verbatim reuse of foz5 (C0);
>   see §1.4 for why it is load-bearing rather than decorative.)*
> * **(A1)** `pt` has ≥ 1 use and **every** use is a 2-operand `sub` of **i64**
>   type whose sibling operand is itself a `ptrtoint` whose source `%T` also
>   satisfies (A0).
> * **(A2)** for every such sibling, `canon(%S) === canon(%T)`, with `canon`
>   evaluated in the basic block containing both `%S` and `%T` — i.e. all of
>   `%S`, `%T` and every instruction the walk inspects lie in one basic block.
>
> **THEOREM (oracle match, unconditional in the representation).** Let `φ` be
> *any* map from native addresses to BennettVM pointer-cell values — injective
> or not, affine or not, byte-scaled or not.
>
> By (A2), `%S` and `%T` denote one pointer value `p` on every execution that
> reaches the `sub`: the canonicaliser's only inference steps are
> (i) "the value loaded from slot `k` equals the value the uniquely-reaching
> store wrote into slot `k`" and (ii) "two loads of slot `k` with no intervening
> writer to `k` return the same value" — both valid statements about *values*
> once established in straight-line code, hence valid wherever the `sub` sits.
>
> Natively the `sub` therefore evaluates `p − p = 0`. In BennettVM the two
> coercions read the two cells holding `φ(p)`, so the `sub` evaluates
> `φ(p) − φ(p) = 0`. **The two agree for every `φ`, hence for BennettVM's, hence
> on every input.** ∎
>
> Consequently the value is not merely *confined* — it is **layout-independent**.
> `udiv exact i64 0, 8 = 0` (the `exact` flag is satisfied, no poison), and every
> downstream consumer of the difference — including the two closure-env stores
> that reach `jl_alloc_genericmemory_unchecked`'s allocation size and
> `llvm.memmove`'s length inside `_growend!` (scout §3.3) — receives a value
> computed from the array size alone.
>
> ```
> >>> GUARANTEE: the admitted cluster computes, on every input, the SAME
> >>> INTEGER the native program computes. Decision item 4's "faithful
> >>> reversible throw" is RETAINED UNCHANGED for every guard downstream of
> >>> this admission; ADR 0017 §4a's conditionality clause is NOT invoked.
> ```

**Where α₀ sits among the three existing pointer contracts** — the sharpest way
to see that it is the strongest, and the one-line answer to the "which oracle
argument?" question:

| contract | the invariance it needs of `φ` | premise class |
|---|---|---|
| Bennett-583s | `φ` affine with slope 1 **within one allocation** (the base cancels; the residual is the GEP displacement) | region-local byte tier |
| Bennett-jbko | `φ` **injective** (`eq`/`ne` survives relabelling) | deterministic bump allocator |
| **Bennett-57hd (α₀)** | **none — `0 = 0` for any `φ` whatsoever** | *(none)* |
| foz5 §4a | *n/a* — declines to prove oracle match; confines instead | halt-guaranteed only |

### 1.3 FAILURE-DIRECTION MATRIX (the §4a idiom — what is NOT guaranteed, as loudly as what is)

| | native RETURNS a value | native THROWS |
|---|---|---|
| **α₀ admits** | extracted returns the **same** value. α₀ introduces no divergence channel: the admitted computation is the constant `0` in both worlds, so no downstream value differs from what the pre-existing model would have produced had the coercion been expressible without a ptrtoint. | extracted takes the **same** branch at every downstream guard, because those guards' operands are oracle-exact. A pruned throw block is reached exactly when native throws ⇒ Decision item 4's **proved-faithful** reversible throw, not §4a's downgraded one. |
| **α₀ declines** | the existing loud wall (`_ir_error`) — extraction fails; nothing is emitted. | same. |
| **(P-α1)/(P-α2)/(P-α3) violated** (see the A-ledger) | the difference may be non-zero in the VM ⇒ a wrong element index ⇒ a wrong allocation size / memmove length, **silently**. This is the same worst-case class δ′ carries; the difference is that α₀'s premises are *checkable-from-IR* or *executable*, and δ′'s (P-δ1) is neither. | throw missed or spurious. |

**Read the bottom row.** α₀ is not premise-free — it is premise-**light**, and
its premises are of a class that can be checked or executed. The third row is
stated at the same volume as the first because §4a's chief hazard was readers
taking "oracle match or loud halt" for "oracle match".

### 1.4 THE STEAL ARGUMENT — why displacement ZERO, and not the obvious generalisation

The natural generalisation `α_k` — strip `getelementptr i8` chains, canonicalise
the *bases*, and conclude `sub ≡ Σ(displacements)` — looks strictly better. It
is not. **Measured (`w20_alphak.jl`, both bodies):**

```
### GROWEND ###
CLUSTER %38 = sub i64 %37, %36  [blk=L46]
   583s root-eq : true
   alphaK val-eq: true   (%memoryref_data vs %memoryref_data)     <-- STEAL
   alpha0 val-eq: false
CLUSTER %46 = sub i64 %45, %44  [blk=L58]
   583s root-eq : true
   alphaK val-eq: true   (%memoryref_data vs %memoryref_data)     <-- STEAL
   alpha0 val-eq: false
```

`α_k` **claims both clusters 583s owns.** Under the `||` short-circuit 583s
still decides them first, so behaviour would not change — but the non-steal
would become *ordering-dependent* rather than *structural*, which is exactly the
discipline foz5 established and binding constraint 2 demands ("Gate on
use/provenance shape instead, so the non-steal is **structural**, not
accidental"). `α_k` also silently re-acquires 583s's residual-displacement
dependence on the byte tier, deleting the "no representation premise" property
that is α₀'s entire case.

And it buys **nothing**: `α_k` is measured `false` on `%L21` and `%L43` too (the
`_growend!` call blocks the canonicaliser, not the displacement). **`α_k` costs
the theorem and gains zero clusters.** Displacement 0 is not a limitation
accepted grudgingly; it is the design.

*(Non-steal against the other two contracts is likewise structural: α₀ is
measured `false` on foz5's `%idxend41`, and it cannot fire on jbko's `%L84` at
all — (A1) demands every use be a `sub`, `_jbko_identity_use_violation` demands
every use be an `icmp eq`/`ne`, and a non-empty use set cannot satisfy both.
That is verbatim the argument `instructions.jl:1558-1563` makes for foz5.)*

### 1.5 THE COMPOSITION RULE — why THIS contract does not void §4a's conditionality

Scout §9 states the constraint: §4a's theorem is conditional on *"everything
outside `τ` is computed by the pre-existing, already-sound model"*
(`instructions.jl:1586-1588`), so **admitting an unproved live value places an
unsound producer outside `τ` and retroactively voids §4a's theorem and, via
`arena_top`, jbko's trajectory correspondence.**

**α₀ satisfies the clause rather than weakening it, for a reason that is a
theorem and not a hope:**

1. The clause asks that values outside `τ` be *computed by an already-sound
   model*. α₀'s admission is an **oracle-match** admission by §1.2 — the emitted
   nodes compute, on every input, the integer native computes. So the admitted
   producer **is** part of the sound model. No clause is invoked.
2. The `arena_top` coupling scout §9 identifies is *the* reason δ′ would be
   dangerous here: a wrong element index ⇒ a wrong
   `jl_alloc_genericmemory_unchecked` size ⇒ a perturbed `arena_top` ⇒ every
   subsequent pointer-cell value differs from the trajectory jbko's argument
   presumes. Under α₀ the index is provably `0 + 1 = 1` and the size is provably
   `size + 1`; **`arena_top` advances exactly as it would have.** jbko's
   trajectory correspondence is preserved *by construction*, not by declaration.
3. §4a is not textually amended. §4b is written as a **sibling** of §4a with the
   explicit statement "this is an oracle-match contract; §4a's downgrade of
   Decision item 4 does **not** extend to guards downstream of a §4b
   admission" — see the ADR text at §1.8.

**This is the crux of the α-vs-δ′ decision.** δ′ cannot make claim (1) — its
conclusion holds only *given* (P-δ1) — so a δ′ ADR would be obliged to write
"§4a's and jbko's guarantees are now conditional on the MemoryRef invariant"
into the record. That is a real, permanent widening of the project's
undischarged-premise surface, taken to buy coverage of two clusters that are
**two walls away and therefore unreachable today** (§1.7).

### 1.6 THE A-LEDGER (every premise I decline to prove, labelled)

| # | premise | class | evidence it is load-bearing / discharged |
|---|---|---|---|
| **P-α1** | A `julia.gc_alloc_obj` result does not alias any pointer already visible at the call. | **CHECKABLE FROM IR.** Measured (`a03_noalias2.jl`): the callsite carries the `noalias` **return** attribute — `julia.gc_alloc_obj → true` (×3), and `llvm.memcpy`, `j_#_growend!##0_95`, `j_throw_boundserror_97`, `julia.gc_loaded`, `ijl_bounds_error_int`, `llvm.trap` all `false`. The predicate **reads the attribute**; it does not pattern-match the callee name alone. Residual: we trust LLVM's `noalias` semantics — an *LLVM-language* premise, not a Julia-ABI/codegen one, so **not** the class Rule 5 forbids. |
| **P-α2** | The write footprint of each whitelisted intrinsic: `memcpy`/`memmove`/`memset` write exactly `[dst, dst+n)` for **constant** `n`; `julia.gc_alloc_obj` / `julia.get_pgcstack` / `julia.gc_loaded` write nothing outside their own result object. | **DECLARED** — and a *sharpening* of ADR 0017 Decision item 4, which already fixes exactly this whitelist ("`malloc`/`calloc`/`realloc`/`free`, `memcpy`/`memmove`/`memset`, `jl_alloc_genericmemory`, `gc_alloc_obj`, throw/`unreachable` — gets hand-written reversible semantics … Everything outside the whitelist fails loud"). §4b makes the *footprint* half explicit, which item 4 does not. **MEASURED LOAD-BEARING** (`w11_nopremise.jl`): reclassify `gc_alloc_obj` as unknown-effect and the lemma collapses (`BLOCKED reload … unknown-effect`, `EQUAL ⇒ false`). Fail-closed: any callee outside the whitelist, and any variable-size `memmove`, ⇒ `:unknown` ⇒ reject. |
| **P-α3** | BennettVM round-trips a pointer through an aggregate store and a field load into the **same cell** — i.e. the model is faithful on the loads/stores the walk reasons about. | **EXECUTABLE, AND PARTLY PRE-PAID.** This is precisely `BennettVM/test/test_bvmd_byte_tier_vm.jl` gate (2), which already *runs*: "the class-A byte read and the class-D struct read of the SAME field return the SAME pointer, and it is the one the aggregate store wrote. NON-VACUOUS: field 0 holds a DIFFERENT pointer." `_check_scale_coherence!` (`module_walk.jl:688-696`) fails loud on the two-granularity drift that would break it. §4.4 adds the wall-10-shaped E2E that closes the remainder. |
| **P-α4** | An `alloca` that never escapes cannot be aliased by a pointer loaded from a pre-existing object. | **CHECKABLE, with a measured trap.** Needed because the corpus scan window `[%memory_data … %memory_data3]` contains `memcpy(%"new::Array.size", %"new::Array.size_ptr1", 8)` whose destination root is an `alloca`. `a05_alloca.jl` measured the trap: `nocapture` is **absent at the callsite** for `llvm.memcpy`/`llvm.memset` and **present on the declaration's parameter** (`declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, ptr noalias nocapture readonly, i64, i1 immarg)`). A callsite-only check therefore *rejects the corpus*. §2.3 states the predicate to match. |

**No premise here is Julia-ABI or codegen-layout shaped.** That is the Rule 5
line foz5's (P) crossed and δ′'s (P-δ1) approaches; α₀ stays on the far side of
it.

### 1.7 WHAT `%top` ALONE UNLOCKS — measured, not asserted

`.ll` surgery (rewrite the cluster's `ptrtoint`s to `add i64 0, 0`, which
preserves LLVM's unnamed-value numbering and reproduces α₀'s downstream value
flow exactly, since α₀ also makes the difference `0`):

| step | wall | reject | bead |
|---|---|---|---|
| HEAD | 10 | 583s + foz5 on `%12` | **this bead** |
| +α₀ | **11** | `Bennett-37mt` Predicate-6 **src** half, `src operand`, quoting `%"new::Array.ref.mem"` | `Bennett-8bys` |
| +8bys | **12** | `Bennett-p06b` — `alloca { ptr, ptr }` store target, "SILENTLY SKIPS" | `Bennett-1zow` (loud) |
| +1zow | 13 / 14 | `%L21` / `%L43` — the **same wall-10 message again** | the follow-up bead, §8 |

My own re-measurement of step 2 (`w15_markers.jl` on `root_patched.ll`, this
session, exactly reproducing the scout):

```
Bennett-583s false | base-cancelling false | Bennett-foz5 false
Bennett-37mt  TRUE | Bennett-8bys     TRUE | memcpy TRUE | src operand TRUE
new::Array.ref.mem TRUE | new::Array.size_ptr FALSE
Bennett-p06b false | gc_alloc_obj false | BYTE-granular false | Bennett-bvmd false
Bennett-jbko false | Bennett-iwo9 false | Bennett-lgzx false | memmove false
```

**α₀ therefore buys the full two walls of frontier progress that are available
to be bought.** δ′'s additional coverage cannot be cashed until `8bys` and
`1zow` land. This is the sequencing argument in one table.

### 1.8 ADR AMENDMENT — the text IN FULL

To be inserted in `BennettVM.jl/docs/adr/0017-closed-world-execution.md`
immediately after §4a, in §4a's own register.

---

> ### 4b. Value identity: oracle match for a base-cancelling difference through memory (Bennett-57hd, 2026-08-07)
>
> **Context.** `push!`'s closed-world ROOT computes Julia's `memoryrefoffset` —
> `array.ref.ptr_or_offset − array.ref.mem.data`, converted to an element index
> by `udiv exact 8`. Unlike §4a's cluster, this difference is **not confined**:
> it steers a live grow-or-not branch and is stored into two closure-environment
> slots that `_growend!` reads as `jl_alloc_genericmemory_unchecked`'s
> **allocation size** and `llvm.memmove`'s **length**. Under the arena model
> (`bennettvm-pdqx`: no region table, three monotone cursors) a wrong allocation
> size is an undetectable adjacent-allocation clobber, and ADR 0018 §E reads an
> unstored load as `0`. **There is no confinement available and §4a's contract
> must not be widened to reach it** — clause (iii) declines it correctly.
>
> Bennett-583s also declines, but for a reason that is an artefact of its proof
> technique rather than of the program: `_memdata_root` establishes base
> cancellation by **syntactic SSA equality** of the two `.data` loads. Here the
> two operands are the two halves of **one `MemoryRef`**, both read out of one
> freshly `julia.gc_alloc_obj`-ed `Array` header, and — in this program — they
> are literally the same pointer, related through **one aggregate store and one
> same-slot reload** rather than through one SSA name.
>
> **Decision.** Introduce a *third* admission contract, **stronger** than §4a
> and stronger than either existing oracle-match proof, applicable to a
> `ptrtoint` whose every use is a pointer **difference of two provably identical
> pointers**:
>
> > **VALUE-IDENTITY CONTRACT.** A `ptrtoint ptr %S to i64` (`pt`) may be
> > admitted as a width-64 cell identity iff a syntactic, single-basic-block
> > predicate establishes all of:
> > (i) `%S` is a **certified materialised cell** in the §4a clause-(i) sense,
> > and is neither unnamed nor suppressed by the emission walk;
> > (ii) `pt` has at least one use, and **every** use is a two-operand **i64**
> > `sub` whose sibling operand is itself a `ptrtoint` of a source `%T` also
> > satisfying (i); and
> > (iii) for every such sibling, `%S` and `%T` **canonicalise to one value**
> > under a walk confined to the single basic block containing them, whose only
> > inference steps are: forwarding a pointer-result `load` to the value written
> > by the uniquely-reaching store to the same canonical slot (through the
> > `insertvalue` chain of an aggregate store), and equating two loads of one
> > canonical slot across a window containing no writer to that slot. Writers are
> > determined by a **fail-closed** effect table: a `store` writes its target
> > slot's storage size; `memcpy`/`memmove`/`memset` write `[dst, dst+n)` for
> > **constant** `n`; the ADR-item-4 allocator/no-effect intrinsics write nothing
> > outside their own result object; **every other instruction with an
> > unmodelled effect terminates the walk unsuccessfully.** Two objects are
> > treated as disjoint only when one of them is a call result carrying LLVM's
> > `noalias` **return** attribute, or a non-escaping `alloca`.
> >
> > For such `pt` the guarantee is: **each admitted `sub` evaluates to `0` in
> > the native program and to `0` in BennettVM, on every input, under any map
> > from native addresses to pointer-cell values.**
>
> **Why this is an ORACLE-MATCH contract and §4a is not.** §4a admits a value it
> *cannot* prove equals native's, and buys safety by proving the value's only
> influence is a halting branch. §4b proves the *equality itself*, and needs no
> claim about the value's influence — the admitted difference is the constant
> `0`, so it carries no information about the address representation at all.
> Formally: 583s's proof needs the representation map `φ` to be translation-
> cancelling within a region, jbko's needs `φ` injective, and §4b needs
> **nothing of `φ`**, since `φ(p) − φ(p) = 0 = p − p` for every function `φ`.
>
> **What this does NOT relax — the composition statement, given first refusal in
> this ADR because it is the reason the contract was written this way.**
> §4a's theorem is stated relative to the clause "everything outside `τ` is
> computed by the pre-existing, already-sound model". A §4b admission is an
> oracle-match admission, so the admitted producer **belongs to** that model:
> **§4a's downgrade of Decision item 4 from *proved faithful* to *unproved* does
> NOT extend to any guard downstream of a §4b admission**, and Bennett-jbko's
> trajectory-correspondence argument — which rests on `arena_top` advancing by a
> span determined solely by the program text and its inputs — is likewise
> **preserved by construction**: the element index this contract admits is
> provably the native one, so the allocation sizes derived from it, and hence
> `arena_top`, are provably the native ones. Had this value been admitted under a
> *declared* premise instead, §4a's and jbko's guarantees would both have become
> conditional on that declaration, and this ADR would have had to say so.
>
> **Explicitly NOT weakened.**
> (a) **583s and §4a retain first and second refusal.** The predicate is the
> **third** disjunct of both the arm's entry and its admission (`||`
> short-circuit). `_memdata_root` is left byte-for-byte untouched: probe
> `p07_steal.jl` measured that widening it makes the 583s arm claim jbko's
> `%L84` witness and then error. Non-steal is **structural** and measured: the
> predicate is `false` on both 583s clusters and on §4a's `%idxend41`, and it
> cannot fire on jbko's witness, because (ii) demands every use be a `sub` while
> jbko demands every use be an `icmp eq`/`ne`.
> (b) **Nothing is fabricated** (Bennett-lbot, reaffirmed). The `sub`, the
> `udiv exact`, the `add`s, the `icmp`, the `xor` and the `br` are emitted
> verbatim by the ordinary paths; the coercion emits the same cell-identity node
> 583s emits. No branch is folded, no cluster elided, no constant substituted —
> the difference is *proved* to be zero, never *assumed* or *written* to be.
> (c) **Determinism (ADR 0018 §A) is untouched.** No new nondeterministic
> producer; the Bennett-klgz unrecognised-JIT-global reject is unreachable from
> this admission. Note that the singleton empty `Memory` (`@"jl_global#93"`) the
> corpus derivation passes through is a **recognised** JIT global, handled by the
> CW-D3 Lever-2 singleton-data alias arm.
> (d) **The circuit tier is untouched.** The admission lives inside the
> `ptr_cells` gate, which is `false` on the circuit path; `verify_reversibility`
> and every gate count are byte-identical.
>
> **Declared premises (the A-ledger).** (P-α1) LLVM's `noalias` return-attribute
> semantics — read from the IR, not assumed from a callee name. (P-α2) the write
> footprint of the Decision-item-4 intrinsic whitelist, which item 4 fixes as a
> *set* and this section makes explicit as a *footprint*; measured load-bearing
> (reclassify `gc_alloc_obj` as unknown-effect and the corpus lemma collapses).
> (P-α3) BennettVM's pointer store/load round-trip fidelity, which
> `test_bvmd_byte_tier_vm.jl` gate (2) already executes and
> `test_57hd_value_identity_vm.jl` extends to this contract's exact shape.
> (P-α4) non-escaping-`alloca` disjointness, checked from `nocapture` on the
> callsite **or the callee declaration** (the corpus requires the latter).
>
> **Disclosed scope boundary, not a defect.** The walk is intraprocedural and
> single-block. It therefore stops at the first call with an unmodelled effect —
> in the corpus, at the `_growend!` call that separates the header write from the
> `%L21` / `%L43` reloads of the same shape. Those two clusters remain a loud
> wall, deliberately, and `test_57hd_value_identity.jl` pins the rejection so a
> later reader knows it is a boundary and not a bug. Extending the class
> (a same-`MemoryRef` provenance-pair predicate resting on a declared Julia
> language invariant, or an interprocedural discharge of that invariant over
> `transitive_callees`) is tracked separately and is **not** authorised by this
> section.

---

## 2. Mechanism

All new code lands in `src/extract/instructions.jl`, in one contiguous helper
block placed **after** the foz5 block (ending ~line 1818) and **before** the
jbko block (starting ~line 1820), so file order mirrors arm order — the
convention foz5 established. `_memdata_root`, `_verify_memdata_bounds_cluster`,
`_foz5_*` and `_jbko_*` are **not edited**.

### 2.1 Constants (the `_FOZ5_DEPTH` idiom, binding constraint 6)

```julia
const _57HD_DEPTH     = 8     # canonicaliser recursion cap (the _memdata_root idiom)
const _57HD_SCAN_CAP  = 512   # instructions inspected per clobber scan (surprise guard, Rule 1)
const _57HD_USE_CAP   = 32    # alloca use-set cap for the escape check
```

### 2.2 Single-block confinement — a correction to the prototype

**The scout's `w13_all.jl` prototype linearises *all* blocks and scans by
position in that list.** Position in a linearised instruction list is not
execution order across basic blocks, so that scan is **unsound in general** (a
"reaching store" in block `A` need not execute before a load in block `B`). It
happens to be harmless on the corpus because the only cluster it admits is
entirely within `%top` — the `w10_pval.jl` prototype, which used
`first(LLVM.blocks(fn))` only, proves the same lemma.

**The production predicate is confined to one basic block**: `%S`, `%T`, every
store/load the walk forwards through, and every instruction in every clobber
window must belong to the block containing `%S`. Straight-line reasoning is then
valid without dominance or memory-SSA machinery. Verified corpus-sufficient by
direct inspection of `rootmod.ll:17-63`: `%memory_data`, the `insertvalue`
chain, `julia.gc_alloc_obj`, both stores, both `memcpy`s, `%6`–`%9`,
`%memory_data_ptr2`, `%memory_data3`, `%12`, `%13` and `%memoryref_offset` are
all in `top:`; `L16:` begins afterwards.

*(A dominance-based generalisation is deliberately future work: it would need
`_57hd_*` to consume a dominator tree the extractor does not currently build,
and it buys nothing on the corpus.)*

### 2.3 The effect table and the disjointness test

```julia
# Returns a Vector{Tuple{_LLVMRef,Int,Int}} of written (root, lo, hi) byte
# ranges, or :unknown. FAIL-CLOSED: :unknown terminates the walk.
_57hd_write_footprint(i::LLVM.Instruction)
```

* `store` → `[(root, off, off + storage_size(valtype))]` via `_p06b_slot_key`.
* `call` to `llvm.memcpy` / `llvm.memmove` / `llvm.memset` with a
  **`ConstantInt` length** → `[(root, off, off + n)]`; a **variable** length →
  `:unknown` (this is where the vau9 shape lands, correctly).
* `call` to a **Decision-item-4 allocator** (`julia.gc_alloc_obj`,
  `jl_alloc_genericmemory*`, `malloc`/`calloc`/`realloc`) **AND** carrying the
  `noalias` return attribute → `[]`.
* `call` to a declared no-effect intrinsic (`julia.get_pgcstack`,
  `julia.gc_loaded`, `llvm.lifetime.*`, `llvm.assume`) → `[]`.
* **anything else** — every other call, `invoke`, `atomicrmw`, `cmpxchg`,
  `fence`, `va_arg` — → `:unknown`.

```julia
_57hd_obj_kind(r::_LLVMRef)::Symbol   # :fresh | :local | :other
_57hd_disjoint(a, b)::Bool = a !== b && (kind(a) in (:fresh,:local) ||
                                         kind(b) in (:fresh,:local))
```

* `:fresh` — a `call` whose **callsite** carries `noalias` at
  `LLVMAttributeReturnIndex` **and** whose callee is in the item-4 allocator
  whitelist. Measured (`a03_noalias2.jl`): true for all three
  `julia.gc_alloc_obj` calls in the root, false for `llvm.memcpy` (×8),
  `j_#_growend!##0_95`, `j_throw_boundserror_97`, `julia.gc_loaded` (×2),
  `ijl_bounds_error_int` (×4), `llvm.trap` (×2).
* `:local` — an `alloca` all of whose uses, transitively through
  all-constant-index GEPs and capped at `_57HD_USE_CAP`, are: a `load`; a
  `store` in which it is the **pointer** operand (never the value operand); or a
  call argument at an index carrying `nocapture` **at the callsite OR on the
  called function's parameter**.

  > **PROSE-VS-PREDICATE TRAP, MEASURED (`a05_alloca.jl`).** A callsite-only
  > `nocapture` check **rejects the corpus**. `llvm.memcpy` / `llvm.memset`
  > carry `nocapture` on the *declaration*
  > (`declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, …)`)
  > and not at the callsite, and the corpus scan window contains
  > `memcpy(%"new::Array.size", %"new::Array.size_ptr1", 8)` whose destination
  > root is exactly such an `alloca`. The predicate must consult both, and the
  > docstring must say "callsite or declaration" — not "the callsite".

* `:other` — everything else, including a pointer loaded from a global (e.g.
  `%"jl_global#93"`). Two `:other` roots are **never** treated as disjoint.

### 2.4 The canonicaliser

```julia
_57hd_canon(v::LLVM.Value, blk, memo, budget)::_LLVMRef
```

1. Not an `Instruction`, or not in `blk`, or not a **pointer-result `load`** →
   return `v.ref`.
2. `(root0, off) = _p06b_slot_key(operands(v)[1])`; `root = _57hd_canon(root0, …)`.
   *(This is the one missing step the scout identified at §4: `_p06b_slot_key`
   gives `(%"jl_global#93", 8)` and `(%9, 8)` — identical offsets, different
   roots, and the roots differ only because `%9` has not been canonicalised.)*
3. **Store-forward.** Among instructions of `blk` strictly before `v`, take the
   **last** `store` whose canonical slot `(root, soff)` covers `[off, off+8)`.
   If the window `(store, v)` is clobber-free:
   * struct-typed stored value → find the field index `j` with
     `offsetof(sty, j) == off − soff` and field storage size 8; walk the
     `insertvalue` chain outermost-inward for index `j` (outermost = last
     writer, so the first match is the correct one) and recurse on the inserted
     operand. If the chain does not yield an operand for `j` — e.g. the
     aggregate came from a `load`, a `call` or a `phi` — **give up** (return
     `v.ref`).
   * `off == soff` and a pointer-typed stored value → recurse on it.
4. **Same-slot reload.** Otherwise, among pointer-result `load`s of `blk`
   strictly before `v` whose canonical slot key equals `(root, off)`, take the
   last one whose window to `v` is clobber-free, and recurse on it.
5. Otherwise return `v.ref`.

**Clobber scan.** For a window `(p₁, p₂)` in `blk` and a tracked range
`(root, lo, hi)`: for each instruction strictly between, take
`_57hd_write_footprint`; `:unknown` ⇒ clobbered; each written `(r, l, h)` is
skipped iff `_57hd_disjoint(r, root)`, and — when `r === root` — iff
`h ≤ lo || l ≥ hi`. Anything else ⇒ clobbered. **Any root that is neither equal
nor provably disjoint clobbers.** Budget-capped by `_57HD_SCAN_CAP`.

### 2.5 Arm placement — and why the ENTRY disjunct is LOAD-BEARING

```julia
if opc == LLVM.API.LLVMPtrToInt && src isa LLVM.Instruction &&
   (_memdata_root(src) !== nothing ||
    _foz5_confined_dead_bounds(inst, names, suppressed_refs, dead_blocks) ||
    _57hd_value_identity_cluster(inst))                         # + 1 line
    …width guard (unchanged)…
    (_verify_memdata_bounds_cluster(inst, src) ||
     _foz5_confined_dead_bounds(inst, names, suppressed_refs, dead_blocks) ||
     _57hd_value_identity_cluster(inst)) ||                     # + 1 line
        _ir_error(inst, …extended message, §3.2…)
    return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
end
```

**The entry disjunct is not symmetry — it is required, and I measured why.**
`.ll` surgery admitting **only** `%12` (`a01_only12.ll`, a one-line rewrite of
`rootmod.ll`) walls immediately on `%13`, whose source `%7` has
`_memdata_root(%7) === nothing` and fails foz5 (C2), so it falls through to the
**jbko** arm:

```
ir_extract.jl: ptrtoint in @julia__push57hd_91:%top:   %13 = ptrtoint ptr %7 to i64
— ptrtoint under ptr_cells whose result is NOT confined to a pointer-IDENTITY
test (Bennett-jbko / CW-D) — found a use that is a `sub`, not an icmp. …
```

The scout's surgery rewrote **both** `ptrtoint`s at once and could not see this.
Without the entry disjunct the bead clears nothing.

**Binding-constraint check.**
* *(2) 583s first refusal* — `||` short-circuit; `_memdata_root` untouched;
  non-steal structural (§1.4). ✓
* *(3) the arm always returns or errors; the predicate is pure in
  `names`/`suppressed_refs`/`dead_blocks`* — `_57hd_value_identity_cluster`
  reads only LLVM structure, so entry-via-α ⇒ admission-via-α: **no
  fall-through is introduced**, and jbko's `_memdata_root(src) === nothing` pin
  keeps its exact current meaning and status. ✓
* *(4) nothing fabricated* — the `sub`, `udiv exact`, `add`s, `icmp`, `xor` and
  `br` all emit verbatim by the ordinary paths (`udiv` at
  `instructions.jl:5099`; BVM `:udiv` at `ir/operators.jl:104`, with
  non-injective-op history capture at `ir/arithmetic_assignment.jl:265`). ✓
* *(5) circuit tier byte-identical* — inside the `ptr_cells` gate. ✓
* *(6) fail-loud on drift* — depth/scan/use caps; `:unknown` default; every
  undecidable shape degrades to the **existing** wall text plus one clause. ✓

### 2.6 Emitted IR — zero BennettVM `src/` change

Two extra `IRBinOp(:or, src, 0, 64)` cell identities (`%12`, `%13`); the `sub`,
`udiv`, two `add`s, one `sub`, one `icmp slt`, one `xor` and the `br` are the
ordinary emissions. No new `IRInst` form. The `udiv exact` costs BVM *history*
(non-injective op), not *capability*. **If the implementer finds a BVM node is
needed, that is a late-firing upgrade trigger — stop and escalate** (sy29 §11.3;
the zero-BVM-`src/`-change streak is not a target to protect, but breaking it
silently is a defect).

---

## 3. Failure modes and message territory

### 3.1 What each failure looks like

| shape | α₀ behaviour | why |
|---|---|---|
| unknown-effect call in the window (`_growend!`) | `false` ⇒ existing wall | `:unknown` footprint. **This is the `%L21`/`%L43` scope boundary; pinned as a test, §4.1.** |
| variable-length `memmove` in the window | `false` ⇒ existing wall | non-constant `n` ⇒ `:unknown` |
| genuinely different pointers (cross-allocation diff) | `false` ⇒ existing wall | canonical forms differ |
| aggregate came from a `load`/`call`/`phi` | `false` ⇒ existing wall | `insertvalue` chain does not yield |
| store in one block, load in another | `false` ⇒ existing wall | single-block confinement (§2.2) |
| WIDTH-0-SENTINEL pointer `phi`/`select` source | `false` ⇒ existing wall | **(A0)** — `_foz5_cert_src_kind` refuses `phi`/`select`. Without (A0) this is a **silent** miscompile: the coercion would emit an `:or` identity over a never-materialised cell (ADR 0018 §E reads it as `0`) on one side and a real cell on the other, so the difference would be non-zero in the VM while α₀ claimed `0`. **(A0) is load-bearing, not decorative** — it is the only clause that closes the sentinel hole. |
| ptrtoint also feeds an `add`/`store`/`ret`/`inttoptr` | `false` ⇒ existing wall | **(A1)** — the coerced address must not escape as a magnitude |
| the *sub result* escapes (the corpus!) | `true` ⇒ **admit** | intended: the escaping value is provably `0`, hence layout-independent (§1.2) |

**The jb6w obligation (scout §6.4), answered.** δ′ must confront
`bennettvm-jb6w` because it *recognises a literal `{ptr,ptr}` as "a MemoryRef"*.
**α₀ has no type-shape recogniser at all** — it never asks whether a struct is a
`MemoryRef`, a `GenericMemory` header, or a clang SysV register-coercion spill.
It asks only "are these the same value?", and that question has the same correct
answer on every language tier. A C `struct { void *a; void *b; }` whose two
fields hold **different** pointers is rejected (the canonical forms differ); one
whose two fields hold the **same** pointer is admitted, and that admission is
**correct** — the difference really is `0`. The jb6w collision class is
structurally absent, and §4.1 ships the fixture that pins both directions.

**No byte-tier gate, and that is deliberate — a prose-vs-predicate note the
implementer must carry into the docstring.** The scout's δ′ obligation (ii)
requires `_root_scale(P)[1] == 1`. α₀ requires no such gate, because `0 = 0`
holds at any scale. A reader who expects the gate must find the sentence saying
why it is absent; §4.1 ships a **word-tier positive** fixture so the absence is
executable, not merely asserted.

### 3.2 The reject message — territory checked against every live pin

Appended as a third sentence to the existing 583s/foz5 reject:

> `… AND its two operands are not provably ONE POINTER VALUE either — predicate `_57hd_value_identity_cluster` (Bennett-57hd / ADR 0017 §4b): every use must be an i64 sub of two ptrtoints whose sources canonicalise, within a single basic block and through aggregate-store field forwarding and same-slot reloads, to one value — so that the difference is 0 in both worlds under any address representation. A call with an unmodelled effect, a variable-length copy, or a cross-block window terminates the walk and lands here (CLAUDE.md §1).`

Grepped against every negative pin live in the six marker files plus
`test_583s` / `test_foz5` / `test_jbko`:

| pinned negative | present in the new clause? |
|---|---|
| `Bennett-37mt`, `Bennett-8bys`, `Bennett-p06b`, `Bennett-bvmd`, `Bennett-jbko`, `Bennett-iwo9`, `Bennett-lgzx`, `Bennett-sy29`, `Bennett-1zow` | **no** |
| `gc_alloc_obj`, `memmove`, `BYTE-granular getelementptr`, `store of non-integer type`, `_growend!`, `ConcurrencyViolation`, `alloca { ptr, ptr }`, `SILENTLY SKIPS` | **no** |
| `Bennett-583s`, `base-cancelling`, `Bennett-foz5`, `_foz5_confined_dead_bounds` | **yes — in the pre-existing two sentences, unchanged.** The clause is appended, so wall-10-shaped rejects elsewhere keep their current text and `test_583s` gate (3)'s `"583s"` + `"width"`/`"64"` substrings are untouched. |
| new strings introduced | `Bennett-57hd`, `_57hd_value_identity_cluster`, `ONE POINTER VALUE`, `single basic block` — none collides with any live pin (grepped across `test/`). |

*(Deliberately avoided: the words `variable-size memmove` — `memmove` alone is a
live negative in four marker files. "variable-length copy" carries the same
meaning with no collision.)*

### 3.3 The six-marker advance, and the wall-11 identical-text trap

The six sites (verified present at HEAD by direct read this session):
`test_bvmd_root_scale.jl:677-707`, `test_p06b_aggregate_store.jl:765-791`,
`test_foz5_confined_bounds.jl:855-872`, `test_40ys_instanceless_callees.jl:542-558`,
`test_7wsz_ptr_sret_fields.jl:551-560`, `test_vau9_variable_memmove.jl:316-336`.

Measured on the **real** wall-11 message (`w15_markers.jl` on
`root_patched.ll`, this session):

| assertion at HEAD | wall-11 truth | action |
|---|---|---|
| `occursin("Bennett-583s") \|\| occursin("Bennett-foz5")` | false / false | **FLIPS — replace** |
| `!occursin("Bennett-37mt")` | `Bennett-37mt` true | **FLIPS — replace** |
| `!(occursin("Bennett-583s") && occursin("_growend!"))` | both false | keep verbatim |
| `!(occursin("Bennett-p06b") && occursin("gc_alloc_obj"))` | both false | keep |
| `!occursin("BYTE-granular getelementptr")` | false | keep |
| `!occursin("Bennett-bvmd")` | false | keep |
| `!occursin("Bennett-jbko" / "Bennett-iwo9" / "Bennett-lgzx" / "memmove" / "store of non-integer type")` | all false | keep |

Replacement, in the foz5/sy29 two-part idiom, non-numeral anchors only
(Bennett-0ncn):

```julia
# BODY SCOPE — unchanged intent: wall 7 was the CLOSURE's `%idxend41` cluster.
@test !(occursin("Bennett-583s", msg) && occursin("_growend!", msg))
# NEW LOAD-BEARING NEGATIVES — wall 10 is CLEARED by Bennett-57hd (ADR 0017
# §4b, the VALUE-IDENTITY contract). A 583s/foz5 reject in the ROOT body is now
# a REGRESSION, not the expected wall. (Replaces the sy29 positive.)
@test !occursin("base-cancelling", msg)
@test !occursin("_foz5_confined_dead_bounds", msg)
# POSITIVE, wall 11 — the loaded-`ptr` (.mem) memcpy SRC class, corpus site #4
# of sy29 §1.1, tracked in Bennett-8bys.
@test occursin("Bennett-37mt", msg) && occursin("src operand", msg)
# ===================== THE IDENTICAL-TEXT DISCRIMINATOR =====================
# WALL 11'S REJECT TEXT IS THE SAME REJECT AS WALL 9'S — same bead tags
# (37mt/8bys), same "src operand", same "memcpy". The ONLY thing that
# distinguishes them is WHICH OPERAND is quoted: wall 9 quoted
# `%"new::Array.size_ptr1"`, wall 11 quotes `%"new::Array.ref.mem"`. Without
# both lines below these markers CANNOT TELL A WALL-9 REGRESSION FROM WALL-11
# PROGRESS — the sy29 lesson: check the discriminator against the MESSAGE TEXT,
# not against the IR. (`new::Array.size_ptr` is a prefix of wall 9's
# `new::Array.size_ptr1`, so the negative catches it.)
@test occursin("new::Array.ref.mem", msg)
@test !occursin("new::Array.size_ptr", msg)
```

`test_jbko_ptr_identity_icmp.jl:554-555` asserts `Bennett-583s` /
`base-cancelling` **positively on its own fixture, not the corpus** — untouched.

---

## 4. Test plan (RED FIRST, CLAUDE.md §3)

### 4.1 `test/test_57hd_value_identity.jl` — new, distilled `.ll` fixtures

Every fixture is a hand-written `.ll` string driven through
`extract_parsed_ir_from_ll(...; ptr_cells=true)` (the idiom
`test_foz5_confined_bounds.jl` uses), asserting the **known node inventory** on
green and the **exact reject substring** on red — never "didn't throw"
(Rule 4).

| # | fixture | expect | pins |
|---|---|---|---|
| **G1** | **corpus-shaped positive** — `load` a `{i64,ptr}` field-1 `.data`; two `insertvalue`s into `{ptr,ptr}`; `gc_alloc_obj` (with `noalias`); aggregate `store`; two field `load`s; nested `{i64,ptr}` field-1 `load`; two `ptrtoint`s; `sub`; `udiv exact 8`; `store` the result | **extracts** | 2 `IRBinOp(:or,…,64)` + `:sub` + `:udiv`; **exactly** the wall-10 shape |
| **G2** | G1 with the two `ptrtoint`s **swapped** in the `sub` | extracts | the walk is symmetric; the sibling side also needs (A0) |
| **G3** | G1 at the **WORD tier** (an `alloca`-rooted header, `_root_scale ≠ 1`) | **extracts** | §3.1 — α₀ deliberately has **no** byte-tier gate; makes the absence executable |
| **G4** | **C tier**: named `%struct.Pair = type { ptr, ptr }`, both fields written from **one** pointer | extracts | jb6w: α₀ is language-agnostic and **correct** here |
| **R1** | **C tier, two DIFFERENT pointers** into the two fields | reject `Bennett-57hd` | the jb6w hostile fixture; the direction δ′ would get wrong |
| **R2** | **cross-allocation**: two unrelated `gc_alloc_obj` headers | reject | canonical forms differ |
| **R3** | **unknown-effect call between** the header write and the reload (the `_growend!` shape) | reject `Bennett-57hd` | **THE SCOPE BOUNDARY — comment it as a boundary, not a bug** (scout §5.4) |
| **R4** | **clobbering store** to the tracked slot inside the window | reject | the clobber scan |
| **R5** | **variable-length `memmove`** inside the window | reject | `:unknown` footprint; the vau9 shape |
| **R6** | **cross-block**: store in `%entry`, load in `%next` | reject | single-block confinement, §2.2 |
| **R7** | **sentinel source**: a pointer-typed `phi` feeding one `ptrtoint` | reject | **(A0)** — the silent-miscompile hole, §3.1 |
| **R8** | **escape**: the `ptrtoint` also feeds an `add i64` | reject | (A1) |
| **R9** | the aggregate stored is a `load` of a `{ptr,ptr}`, not an `insertvalue` chain | reject | the chain-does-not-yield arm |
| **R10** | allocator call **without** the `noalias` return attribute | reject | (P-α1) is read from the IR, not from the name |
| **N1** | `ptr_cells=false` on G1 | **byte-identical** to HEAD (the pre-existing "unsupported LLVM opcode" wall); a circuit-tier `reversible_compile` + `verify_reversibility` + `gate_count` control | binding constraint 5 |

### 4.2 Steal probe (obligation (c), `p07_steal.jl` idiom)

A testset that runs the shipped predicate over **both** corpus bodies
(`rootmod.ll`, `growend.ll` regenerated in-test from Julia, as
`test_sy29_arena_src_memcpy.jl` does) and asserts the §0 table **exactly**:
`_57hd_value_identity_cluster` true on `%top`'s cluster and **false on all five
others**, while `_verify_memdata_bounds_cluster` stays true on `%38`/`%46` and
`_foz5_confined_dead_bounds` stays true on `%idxend41`. Plus the α_k
counter-measurement (§1.4) recorded as a comment with the numbers, so a future
agent tempted by the generalisation finds the reason it was declined.

### 4.3 Corpus gate + INERT re-runs

* **Corpus gate.** `extract_parsed_ir_set_from_julia(_push57hd, Tuple{Int64}; ptr_cells=true)`
  must now wall at **wall 11** with the §3.3 marker profile.
* **INERT, re-run and diffed — never assumed.** Baselines **re-measured by me**
  at HEAD `97a188c` under `--check-bounds=yes`, all green and all matching the
  scout: `test_583s_memdata_bounds` **28/28**, `test_foz5_confined_bounds`
  **63/63**, `test_jbko_ptr_identity_icmp` **73/73**, `test_bvmd_root_scale`
  **84/84**, `test_p06b_aggregate_store` **617/617**. The remaining five
  (`test_sy29_arena_src_memcpy` 91, `test_vau9_variable_memmove` 69,
  `test_40ys_instanceless_callees` 128, `test_7wsz_ptr_sret_fields` 106,
  `test_37mt_memcpy_const_aligned` 86) carry the scout's HEAD measurement; the
  implementer re-runs all ten and diffs.
  `test_foz5_confined_bounds` gates (B)/(C1)/(C2)/(N)/(B1)/(B3)/(C6) must stay
  **byte-identical** — a change there means §4a was widened by accident.
  `test_37mt_memcpy_const_aligned.jl` is **not** edited here; it is wall 11's file.
* Full `Pkg.test()` before the commit (§8 rule, no CI — CLAUDE.md §14).

### 4.4 BennettVM E2E — the runtime evidence THIS contract's premise gets

`BennettVM.jl/test/test_57hd_value_identity_vm.jl`, **zero BVM `src/` change**,
built as a hand-assembled `ParsedIR` in the `test_bvmd_byte_tier_vm.jl` idiom
(that file is the precedent: 39 `@test`s, five numbered gates, "This file is the
proof, not the assertion").

| gate | what it executes |
|---|---|
| (1) **HANDOFF SHAPE** — the `ParsedIR` carries two `IRBinOp(:or, _, 0, 64)` cell identities, the `:sub`, and the `:udiv` | the emission is what §2.6 claims |
| (2) **THE §4b PREMISE, EXECUTED** — a pointer is written through an aggregate store into a byte-tier `IntrinsicGCAlloc` object, read back through a struct-field load **and** through a nested header load, and the `sub` of the two coercions is asserted **`== 0`**. NON-VACUOUS: field 0 and field 1 hold **different** pointers, so a shared or mis-stamped cell makes the difference non-zero. | This is (P-α3), and it is the **direct extension** of `test_bvmd_byte_tier_vm.jl` gate (2), which already executes the store/load round-trip half. |
| (3) **THE ESCAPE IS HARMLESS** — the quotient `udiv exact 8` feeds an `IntrinsicGCAlloc` **size** operand and the run allocates the same number of cells as an oracle run with the size computed directly. | the executable form of §1.2's "no arena-dependent quantity enters the escaping chain" — the §3.3 objection, refuted at runtime |
| (4) **ORACLE** under both L2 and L3 history regimes | |
| (5) **EXACT `unrun!`** — memory, locals, arena cursor and pc restored bit-for-bit with a drained history | the `udiv` is non-injective, so this is where its history capture is checked |

**This is constructible today** — it does not wait for walls 11/12, because it is
a hand-built `ParsedIR`, not the corpus. That is a concrete advantage of α₀ over
δ′, whose (P-δ1) has no executable form at all.

---

## 5. Risks

| # | risk | severity | mitigation / residual |
|---|---|---|---|
| **R-1** | **New analysis machinery in the extractor's most safety-critical arm.** ~200 LOC of GVN-lite. A bug in the clobber scan admits a *false* identity ⇒ the difference is non-zero in the VM while §4b claims `0` ⇒ **silent** wrong allocation size. | **HIGH** | single-block confinement (§2.2) removes all CFG reasoning; `:unknown` is the default for every unmodelled effect; two `:other` roots never disjoint; depth/scan/use caps; **and gate (2) of the BVM E2E executes the exact shape**. Residual: the effect table is a whitelist and a whitelist can be wrong — but wrong *in the closed direction* for every omission. |
| **R-2** | **Coverage 1/3.** `%L21`/`%L43` re-wall with this bead's own message. | MEDIUM | Measured zero frontier cost today (§1.7): both sit behind walls 11 and 12. Pinned as fixture **R3** so the boundary is legible. Bead filed (§8). Accepted explicitly, per the design question's instruction. |
| **R-3** | **Rule 5 — IR shape sensitivity.** If `-O0` codegen stops emitting the aggregate store / field-load shape, α₀ returns `false`. | LOW | Fails **closed** to the existing wall. Unlike foz5's refused witness, α₀'s witness (the `insertvalue` chain feeding the aggregate store) is **LIVE** — used by that store — so foz5 §4.2's Rule-5 objection to a dead `insertvalue` does not transfer. Measured: the chain's consumer is `store { ptr, ptr } %memory_ref, ptr %"new::Array"`. |
| **R-4** | **(A0) is subtle and could be "simplified away".** Dropping it reopens the WIDTH-0-SENTINEL hole *silently*. | MEDIUM | Fixture **R7** is the pin; the docstring must carry §3.1's paragraph verbatim (the `instructions.jl:5245-5249` "THE USE GATE IS LOAD-BEARING" idiom). |
| **R-5** | **Marker mis-advance.** Wall 11's text is identical to wall 9's. | MEDIUM | §3.3's two-line discriminator, measured on the real message. If the implementer's wall-11 message differs from `root_patched.ll`'s, **stop** — the surgery model has diverged from the arm. |
| **R-6** | **`_p06b_slot_key` reuse regression.** α₀ consumes it; `test_p06b_aggregate_store.jl` is 617 assertions of exposure. | LOW | α₀ only *calls* it; no edit. Re-run and diff. |
| **R-7** | An implementer "improves" α₀ to α_k. | MEDIUM | §1.4 with the measured steal, reproduced as a comment in the steal-probe testset. |

---

## 6. Diff shape

| file | change | size |
|---|---|---|
| `src/extract/instructions.jl` | **+1 helper block** after the foz5 block: 3 constants, `_57hd_write_footprint`, `_57hd_obj_kind`, `_57hd_local_alloca`, `_57hd_disjoint`, `_57hd_canon`, `_57hd_value_identity_cluster`; plus the §1.2 theorem / A-ledger / scope-boundary comment header in the foz5 register. **+2 lines** in the ptrtoint arm (entry + admission disjuncts) and **+1 clause** in the reject string. **No existing predicate edited.** | ~200 LOC code + ~130 lines comment; 3 lines touched in the arm |
| `test/test_57hd_value_identity.jl` | **new** — 14 fixtures (§4.1) + steal probe (§4.2) + corpus gate (§4.3) | ~500 LOC |
| `test/runtests.jl` | +1 registration | 1 line |
| 6 marker files | §3.3 replacement | ~10 lines each |
| `BennettVM.jl/docs/adr/0017-closed-world-execution.md` | **new §4b** (§1.8 verbatim) | ~70 lines |
| `BennettVM.jl/test/test_57hd_value_identity_vm.jl` | **new** E2E, 5 gates | ~220 LOC |
| `BennettVM.jl/test/runtests.jl` | +1 registration | 1 line |
| `worklog/104_2026-08-07_57hd_scout.md` (current top chunk) | session log prepended | — |
| **`BennettVM.jl/src/`** | **ZERO** | — |

---

## 7. Disposition of the other routes

### 7.1 δ′ — same-MemoryRef base cancellation: **DECLINED NOW, NOT REFUTED**

δ′ is a good contract at the wrong time. Three reasons, in weight order:

1. **Its extra coverage is unrealisable today.** `%L21`/`%L43` sit behind walls
   11 and 12 (§1.7, measured). δ′ buys **the same two walls of progress α₀
   buys**, at the price of a declared premise.
2. **Its price is permanent and structural.** (P-δ1) is a *declared* premise
   whose failure mode is a silent wrong heap, and — by the scout §9 composition
   rule — a δ′ ADR is obliged to record that **§4a's and jbko's guarantees are
   now conditional on it**. Once written, that sentence does not come back out.
3. **Its premise has no executable form.** (P-δ1) is a claim about how *Julia*
   materialises `MemoryRef`s; no BVM fixture can witness it. α₀'s (P-α3) can be
   executed today (§4.4), and (P-α1) can be read off the IR.

Deferring is also *strictly better for δ′*: by the time walls 11 and 12 clear,
the corpus executes, and the δ′ decision can be made **with runtime evidence
about the MemoryRef invariant in hand** instead of by declaration. That is the
sequencing bvmd used to pay foz5's debt, applied one bead earlier.

**Not taken as a hybrid.** "α₀ now + δ′ for the barrier-blocked clusters" is a
worse version of δ′-alone: it pays δ′'s full ADR price *now* for coverage that
cannot be exercised *now*, and it makes the §4b theorem two-tiered (one clause
oracle-match, one clause declared) — precisely the "read 'oracle match or loud
halt' as 'oracle match'" hazard §4a spent a hostile review closing.

### 7.2 γ-a / γ-b — runtime-checkable admission: **DECLINED**

* **γ-a (extraction-side CFG synthesis).** Extraction would synthesise control
  flow for the first time. `instructions.jl:1628-1631` states the coupling that
  makes this dangerous — the `dead_blocks` set is *threaded from*
  `module_walk.jl` and "the two must stay one set by construction, not by
  agreement"; a synthesised branch into `:__unreachable__` creates an edge that
  set never saw. Blast radius: ADR 0022 phi-edge binding, the utzc pruned set,
  `lower.jl`'s topo sort and back-edge detection.
* **γ-b (BVM assert node).** Breaks the zero-BVM-`src/`-change streak and needs a
  reversible semantics for a halting assert.
* **Both fail on the merits regardless**, and the scout says so: a range /
  alignment check (`0 ≤ d < len·8`, `d % 8 == 0`) catches the *gross* violation
  and not a subtle one. **γ upgrades a failure mode; it does not supply oracle
  match.** α₀ supplies oracle match outright, so γ has nothing to add to it.

### 7.3 ε — interprocedural α: **DECLINED FOR THIS BEAD, RECOMMENDED AS THE SUCCESSOR**

ε is the *right* long answer — it would discharge (P-δ1) inductively over
`transitive_callees` (`extract/callgraph.jl`, CW-D1a) and prove the whole class.
But it is the extractor's **first interprocedural analysis** plus a call-effect
summary discipline, in a bead whose frontier value is fully captured by α₀
(§1.7). Scoping ε in here would put a new analysis *architecture* and a new
*contract* in one change, in the pipeline CLAUDE.md §2 protects.

**Cost, stated honestly for the successor bead:** a per-callee write-summary
(which slots of which parameter-reachable objects a callee may write), computed
over the CW-D1a call graph with a fixpoint for recursion, a `:unknown` bottom
for any callee whose IR is unavailable, and a degradation rule that produces the
**existing loud wall** — never an admission — when a summary cannot be computed.
That summary would turn α₀'s `:unknown`-at-`_growend!` into a precise footprint
and close `%L21`/`%L43` **under α₀'s premise-free theorem** rather than under
δ′'s declared one. If ε lands, δ′ is never needed.

### 7.4 β — confinement: **already refuted; not re-proposed**

Scout §3.3: the sink set is a **live** branch, an **allocation size** and a
**memmove length**. There is no `:__unreachable__` successor to absorb a wrong
choice and no halt bound. I re-read the forward use-closure and agree; I add only
that α₀ makes the question moot rather than answering it — the escaping value is
provably `0`, so there is nothing to confine.

---

## 8. The bead this proposal files

> **`Bennett-<new>` (P1) — xkl frontier walls 13/14: the `%L21`/`%L43`
> same-shape `sub(ptrtoint,ptrtoint)` clusters behind the `_growend!`
> unknown-effect barrier.**
>
> Bennett-57hd cleared wall 10 under ADR 0017 §4b (value identity). §4b's walk
> is intraprocedural and single-block, so it stops at the `_growend!` call that
> separates the `Array` header write from the `%L21` / `%L43` reloads
> (measured: `w13_all.jl`, `BLOCKED reload … unknown-effect`). Those two
> clusters carry the **identical** wall-10 message and sit **behind walls 11
> (`Bennett-8bys`) and 12 (`Bennett-1zow`)**, so they block nothing until both
> land — which is why 57hd deliberately did not reach them.
>
> Two candidate routes, both scouted under 57hd and both still open:
> **route ε** (interprocedural write summaries over CW-D1a `transitive_callees`
> — proves the class, keeps §4b's premise-free theorem, recommended) and
> **route δ′** (a same-`MemoryRef` provenance-pair predicate resting on the
> **declared** Julia MemoryRef invariant — one predicate, 3/3 coverage,
> measured to steal nothing, but its failure mode is a silent wrong heap and it
> would make §4a's and jbko's guarantees conditional on the declaration).
> **Decide this bead only after walls 11/12 clear**, so the corpus executes and
> δ′'s premise can be measured instead of declared.
> Baseline tables to reproduce: `docs/design/57hd/proposal_A.md` §0 and §1.4.
> Fixture `R3` in `test/test_57hd_value_identity.jl` is the pinned scope
> boundary; it must **flip to green**, not be deleted.

---

## 9. Answers to the four soundness obligations, indexed

| obligation | where |
|---|---|
| (a) THEOREM with a native-returns × native-throws matrix, §4a idiom | §1.2 (theorem) + §1.3 (matrix, including the premise-violated row) |
| (b) A-ledger, each premise *checkable* / *declared*, with the probe showing it load-bearing | §1.6 — P-α1 checkable (`a03_noalias2.jl`), P-α2 declared + measured load-bearing (`w11_nopremise.jl`), P-α3 executable (`test_bvmd_byte_tier_vm.jl` gate 2 today, §4.4 gate 2 for this shape), P-α4 checkable with the measured callsite-vs-declaration trap (`a05_alloca.jl`) |
| (c) steal probe in the `p07_steal.jl` idiom over both bodies | §0 table (measured, `w20_alphak.jl`) + §4.2 (the shipped testset) + §1.4 (the α_k counter-measurement) |
| (d) wall-11 marker replacement with the `new::Array.ref.mem` vs `new::Array.size_ptr` discriminator | §3.3, measured on the real wall-11 message this session |
