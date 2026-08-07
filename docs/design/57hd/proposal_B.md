# Bennett-57hd — PROPOSER B

**Bead:** `Bennett-57hd` (P1) — xkl frontier wall 10, the third admission contract.
**Input:** `docs/design/57hd_scout.md` (read in full), `bd show Bennett-57hd`,
ADR 0017 §4 / §4a, worklogs 100–103.
**HEAD:** `97a188c`. **Sister:** BennettVM.jl. **No `src/` or `test/` change; no commit.**
**Probes** (session scratchpad, all `julia --project --check-bounds=yes`, serial):
scout probes re-run (`w01`, `w03`, `w13`, `w14`, `w16`, `w08` on
`root_patched.ll` / `root_q0.ll` / `root_q1.ll`) plus **six new ones of mine**:
`b17_foz5_all.jl` (shipped 583s/foz5 predicates over EVERY cluster in both
bodies), `b_alpha_w11.ll` / `b_alpha_w11_w12.ll` / `b_alpha_w11_w12_w13.ll` /
`root_q1_w12.ll` / `root_q1_w12_w13.ll` (α-vs-δ′ wall-sequence surgery),
`b_alpha_skipL16.ll` (the `NO WALL` fixture), `b18_attrs.jl` (LLVM attribute
retrievability), `b19_alpha_checked.jl` (the hardened, checked-premise α
prototype), `b20_flip.jl` (premise flip).

---

## 0. VERDICT UP FRONT

**Route α, alone, hardened so that BOTH of its premises become CHECKED rather
than declared. δ′ is REJECTED — not deferred. ε and γ are disposed of below.**

Two measurements I made drive this, and both **contradict the scout's central
framing** (§11's "α covers 1/3, δ′ covers 3/3, neither dominates"):

> **F1. The `%L21` and `%L43` clusters are ALREADY ADMITTED by the shipped
> foz5 §4a contract.** Measured two independent ways (probe `b17_foz5_all.jl`
> calling the shipped `_foz5_confined_dead_bounds` with the real
> `_vec_vm_dead_blocks` set, and end-to-end on `b_alpha_skipL16.ll` where the
> whole root extracts **`NO WALL`**). The scout never asked the shipped foz5
> predicate about those two clusters — §4 evaluates it only on the wall-10
> cluster, and §5.4/§6.2 compare the two *prototypes* against each other and
> against `_memdata_root`, never against `_foz5_confined_dead_bounds`.
>
> The true partition of the corpus is therefore **583s: 2 (both in `_growend!`)
> / foz5 §4a: 3 (`%idxend41` + `%L21` + `%L43`) / NEW: 1 (`%top`)**. Route α
> covers **1 of 1** of what actually needs a third contract.

> **F2. δ′'s extra "coverage" buys ZERO frontier progress — measured over FOUR
> successive walls.** By `.ll` surgery I advanced the frontier past wall 11
> (37mt/8bys `.mem` src memcpy), wall 12 (p06b `alloca {ptr,ptr}`), wall 13 (a
> second 37mt/8bys memcpy) and wall 14 (a bvmd `_check_scale_coherence!`
> violation on the 9×i64 closure alloca) — under **α-only** admission and under
> **δ′ (all-three)** admission, and the reject text is **byte-identical at every
> one of the four**. The clusters δ′ would additionally claim are never the wall,
> because a contract already owns them (F1).

Consequently δ′ is not "wider reach at the cost of a declared premise". It is
**the same reach**, at the cost of a declared premise, **plus a measured overlap
with foz5 on two live corpus clusters** — i.e. exactly the steal class binding
constraint 2 exists to forbid, which scout §6.2 missed because its non-steal
probe covered only `%idxend41`.

| | α (this proposal) | δ′ |
|---|---|---|
| clusters needing a new contract that it closes | **1 / 1** | 1 / 1 |
| clusters it claims that another contract already owns | **0** (measured, both bodies) | **2** (`%L21`, `%L43`) |
| frontier walls unlocked | 4 (measured) | 4 (measured — identical) |
| guarantee | **oracle match, both matrix columns** | oracle match **iff** (P-δ1) |
| failure mode | none authorised; analysis failure ⇒ existing loud wall | **silent wrong heap** |
| premises | 2, both **CHECKED** (§1.3) | 1 **declared**, 1 checked |
| `bennettvm-jb6w` | untouched | amplified |
| BVM `src/` | none | none |

---

## 1. ROUTE AND SOUNDNESS

### 1.1 What is admitted

A `ptrtoint` whose result is consumed **only** by base-cancelling `sub`s in which
the two coerced pointers are proved to be **copies of one and the same pointer
value**, so the difference is `0` — in the native world and in the VM world alike,
under **any** assignment of an integer to the pointer cell.

This is 583s's own proof discipline at displacement 0 (`foz5_scout.md §2.2`:
"the difference is the sum of the GEP offsets under any assignment of an integer
to that cell. No model assumption, no ABI assumption. Base-independence is
derived, not assumed."). 583s derives it from *syntactic SSA identity* of the two
bases. **α derives it from value identity through memory**, which is the same
proof reached one hop further back.

Corpus witness (probe `b19_alpha_checked.jl`, verbatim):

```
CLUSTER %memoryref_offset = sub i64 %13, %12  [blk=top]
   583s root-eq        : false
   cert(A)/cert(B)     : load / load
   ALPHA-CHECKED val-eq: true
      FORWARD %7  <= field 0 of store { ptr, ptr } %memory_ref, ptr %"new::Array"
      FORWARD %9  <= field 1 of store { ptr, ptr } %memory_ref, ptr %"new::Array"
      RELOAD  %memory_data3 == %memory_data
```

`pval(%7) = pval(%memory_data3) = %memory_data` ⇒ `%memoryref_offset ≡ 0` ⇒
`udiv exact 0, 8 = 0`. Native agrees: `memoryrefoffset` of a freshly built
`Array`'s ref into the empty-`Memory` singleton is `0`.

### 1.2 THEOREM (state it exactly; this is the §4a-idiom banner text)

> **VALUE-IDENTITY CONTRACT.** Let `pt = ptrtoint p` and let every use of `pt`
> be a two-operand **i64** `sub` whose sibling operand is `pt' = ptrtoint q`,
> with `p` and `q` both **certified materialised cells** (`_foz5_cert_src_kind`,
> named, unsuppressed), and with the analysis of §2 returning the SAME canonical
> value ref for `p` and for `q`.
>
> Then, on every input:
>
> 1. **Native.** `p` and `q` hold the same address, so each such `sub` yields `0`.
> 2. **VM.** Under `ptr_cells` a pointer is one Int64 cell value and every copy
>    step the analysis traverses (an aggregate `store` decomposed per field by
>    p06b, a same-slot reload, an `insertvalue` field extraction) copies that
>    cell value **verbatim** — ADR 0018 §A, the same copy argument Bennett-jbko
>    is built on. Both certified cells therefore hold one and the same value
>    `φ(v)`, and the emitted `IRBinOp(:sub)` yields `0`.
>
> Hence the difference **equals the native oracle**, and it does so **under any
> map φ from addresses to cell values, injective or not**: `x − x = 0` needs no
> property of φ whatsoever.
>
> **GUARANTEE: full ORACLE MATCH for the difference and for everything derived
> from it.** The value may escape freely — into `udiv exact`, into a live
> branch, into closure-env stores that become an allocation size and a memmove
> length — because it is *correct*, not merely *confined*.

**Native-returns × native-throws matrix** (deliver (a) of the scout's soundness
obligations):

| | native RETURNS a value | native THROWS |
|---|---|---|
| **extracted program** | returns the SAME value (the admitted difference is oracle-exact; every downstream guard sees oracle-exact operands) | throws identically — the guards that decide the throw are computed from oracle-exact operands, so no throw is missed and none is spurious |
| **what is NOT guaranteed** | nothing is downgraded by *this* contract. It does not repair any other contract's undischarged premise: a program that also contains a §4a-admitted guard keeps §4a's unproven columns for **that** guard | same |

Contrast §4a's banner, which had to say "the throw may be MISSED, and the halt may
be SPURIOUS; neither direction is authorised; both are UNBOUNDED by the theorem."
**This contract has no such paragraph, and that difference is the whole point.**

The residual risk is not in the theorem, it is in the **analysis**: if §2's walker
ever returns "same value" for two different values, the theorem's hypothesis is
false. §1.3 is therefore the real soundness surface, and every entry in it is a
CHECK rather than a declaration.

### 1.3 A-LEDGER — every premise, labelled, with the probe that shows it load-bearing

The scout's α ledger had two **declared** premises. I convert both into **checked**
ones by reading LLVM's own attributes instead of a hardcoded callee-name table.

| # | premise | status | how it is discharged | load-bearing? |
|---|---|---|---|---|
| **A1** | an intervening `call` writes no memory the walker must model | **CHECKED** | the callee's `memory` (MemoryEffects) attribute, read via `LLVMGetCallSiteEnumAttribute` at the function index, falling back to the callee declaration. Admitted only when `ArgMem` and `Other` are both non-`Mod`. `InaccessibleMem` is by definition not IR-visible. **No attribute retrievable ⇒ `:unknown` ⇒ blocked.** | **YES** — probe `b20_flip.jl` (`_writes_nothing ≡ false`): `BLOCKED reload … unknown-effect: %"new::Array" = call noalias … @julia.gc_alloc_obj`, `val-eq: false`. |
| **A2** | `llvm.memcpy` / `memmove` / `memset` write exactly `[dst, dst+n)` | **CHECKED + DECLARED (narrow)** | the *extent* is checked (`memory(argmem: …)` ⇒ no `Other` writes; `n` must be a `ConstantInt`, else `:unknown`). The *identification* of the three LLVM intrinsics by name is a declared premise about LLVM's own intrinsic semantics — the same premise the shipped 37mt/vau9/sy29 memcpy arms already make. | YES (same flip) |
| **A3** | a `noalias`-returning allocator call names a FRESH object | **CHECKED** | the `noalias` **return** attribute, present on both the call site and the declaration for `julia.gc_alloc_obj` (probe `b18_attrs.jl`). Not a callee-name table. Combined with a definition-ORDER rule: a root defined *before* the allocation cannot be a copy of it. | YES |
| **A4** | an `alloca` is disjoint from roots not derived from it | **CHECKED** | a non-escape scan: every use is a `load`/`store` **address** operand, a GEP with the same property, or a call argument at a `nocapture` parameter position (call site attribute, falling back to the callee declaration). | **YES** — with the callee-declaration fallback omitted the corpus witness goes **`val-eq: false`** (`may-alias(unproven-disjoint): llvm.memcpy(… %"new::Array.size" …)`). Measured while hardening `b19`. |
| **A5** | a same-root byte-range non-overlap judgement transports to the VM's cells | **CHECKED** | `_root_scale(root, names, ptr_cells)[1] == 1` is *required* for any same-root non-overlap decision; anything else is treated as a clobber. Measured `_root_scale(%"new::Array") = (1, 24, "a julia.gc_alloc_obj BYTE-cell reservation of 24 cell(s)")` (probe `w16_scale.jl`, re-run). This is bvmd's own predicate, and `_check_scale_coherence!` already runs on this path. | YES for the corpus witness (the `memcpy` to `new::Array.size_ptr` at `[16,24)` must be shown not to touch `[0,8)`/`[8,16)`) |
| **A6** | LLVM attributes in the input module are TRUTHFUL | **DECLARED** | the only genuinely undischarged premise. It is of the *IR well-formedness* class — the same class as "the `Sub` opcode means subtraction". It is **not** the ABI/codegen-layout class Rule 5 forbids, and it is not a Julia-specific claim: a wrong `noalias` or a wrong `memory(…)` would miscompile under LLVM's own optimiser. Failure direction is conservative in one respect (a *missing* attribute always rejects) and unsound only if an attribute is present and *false*. | — |
| **A7** | ADR 0018 §A cell-copy fidelity: load/store/insertvalue copy a cell value verbatim | **DECLARED, PRE-EXISTING** | not new. This is the substrate Bennett-jbko's shipped contract already stands on (`instructions.jl:1836-1839`). α adds no new weight to it. | — |

**`julia.get_pgcstack` is the honest test of A1**, and it passes it: probe
`b18_attrs.jl` shows the declaration `declare ptr @julia.get_pgcstack()` carries
**no attribute group at all**, so my rule classifies it `:unknown`. The scout's
declared table asserted it "writes nothing outside its result object"; my design
refuses to assert that, and — measured — the corpus witness survives anyway,
because the `get_pgcstack` call lies outside every clobber-scan range.

### 1.4 COMPOSITION RULE — why §4a's conditionality is NOT voided

Scout §9 states the constraint: `_foz5_confined_dead_bounds`'s theorem is
conditional on the clause *"everything outside `τ` is computed by the
pre-existing, already-sound model"* (`instructions.jl:1586-1588`), so admitting
an **unproved live** value places an unsound producer outside `τ` and
retroactively voids §4a's theorem — and, via `arena_top`, jbko's trajectory
correspondence.

> **This contract's value is PROVED, not declared.** The admitted difference
> equals the native oracle on every input (§1.2), so the value joins "the
> pre-existing, already-sound model" rather than sitting outside it. §4a's
> conditional clause is **satisfied**, not voided. jbko's trajectory
> correspondence is likewise preserved: the branch condition `%18` is computed
> from an oracle-exact index, so the VM takes the same successor native takes,
> and `arena_top` advances exactly as it would.

Two further couplings, measured rather than hand-waved:

* **The escaping index is the offset operand of two 583s-PROVED clusters**
  (`%38` at `%L46`, `%46` at `%L58`, scout §3.3). 583s is a *relative*-correctness
  proof and inherits any upstream unsoundness. Under α it inherits **soundness**:
  those clusters now receive an oracle-exact offset. δ′ would leave them
  inheriting a declared invariant.
* **The wall-10 index feeds `jl_alloc_genericmemory_unchecked`'s allocation size
  and `llvm.memmove`'s length** (scout §3.3). Under α those are oracle-exact, so
  the `bennettvm-pdqx` "no region table, three monotone cursors" hazard is not
  engaged at all. This is the single strongest reason to prefer a *proof* here
  over any declared invariant: the sink set has no halt bound, so the only
  acceptable contract for it is one whose failure mode is **not** a wrong heap.

**Placement rule (satisfies binding constraint 2).** The new disjunct goes
**THIRD** — after 583s and after foz5 — in both the entry and the admission
condition. 583s keeps first refusal; foz5 keeps second. Because all three
predicates are **pure**, entry-via-α implies admission-via-α, so the arm still
always returns or errors and the jbko `_memdata_root(src) === nothing` pin keeps
its exact current (redundant) meaning. `_memdata_root` is **not touched** —
`p07_steal.jl`'s regression stays impossible by construction.

**Non-steal is measured, both bodies** (deliver obligation (c)):

| body | cluster | blk | 583s | foz5 §4a | **α** |
|---|---|---|---|---|---|
| root | `%memoryref_offset` | `%top` | false | false | **TRUE ← wall 10** |
| root | `%45` | `%L21` | false | **true** | false |
| root | `%59` | `%L43` | false | **true** | false |
| `_growend!` | `%38` | `%L46` | **true** | true | false |
| `_growend!` | `%46` | `%L58` | **true** | true | false |
| `_growend!` | `%100` | `%idxend41` | false | **true** | false |

α claims exactly one cluster, and it is the only cluster no shipped contract
claims. (Rows 2–6 for foz5 are probe `b17_foz5_all.jl`; the α column is
`b19_alpha_checked.jl` over both `rootmod.ll` and `growend.ll`.)

The non-steal is **structural, not accidental**: α admits only when the two
coerced pointers are the same value, i.e. only when the difference is
**identically zero**. Every 583s and foz5 corpus cluster differences a pointer
against the *same pointer plus a runtime byte offset*, which α's canonicaliser
cannot and does not collapse (`pval(A)` is a `getelementptr` in all five rows).
Even in the hypothetical where two contracts both returned `true`, no harm
follows: all three are `||`-disjuncts of the same expression in both the entry
and the admission condition, so no arm can claim-then-reject.

### 1.5 Disposal of the other routes (each explicitly, as required)

* **δ′ — REJECTED**, on F1/F2 above plus three independent grounds:
  (i) its 2-cluster overlap with a shipped contract is a steal in the exact
  sense constraint 2 forbids, and it *replaces a PROVED confinement with a
  DECLARED invariant* on those clusters;
  (ii) its failure mode is a silent wrong allocation size / memmove length,
  against a sink set with no halt bound (§3.3) — the one place this project has
  measured that it cannot detect the damage (`bennettvm-pdqx`, ADR 0018 §E);
  (iii) it amplifies `bennettvm-jb6w` by recognising an unnamed literal
  `{ptr,ptr}` as "a MemoryRef", and **the very next wall the frontier hits is
  itself a jb6w-class two-granularity violation made loud** (wall 14, measured:
  `_check_scale_coherence!` on the 9×i64 closure alloca). Widening the jb6w
  recognition surface immediately before walking into jb6w's own guard is the
  wrong order of operations.
* **ε (interprocedural α) — DEFERRED, with a bead.** It would discharge (P-δ1)
  inductively over `transitive_callees` (`extract/callgraph.jl`, CW-D1a). There
  is **nothing left in this corpus for it to prove** (F1), so paying for the
  extractor's first interprocedural analysis plus a call-effect summary now is
  unjustified. File it as the escalation path for the day a cluster appears that
  α's intra-block scope cannot reach. Honest cost, stated as the scout demands:
  a call-effect summary that cannot be computed must produce the **existing loud
  wall**, never an admission — which is exactly what α's `:unknown` footprint
  already does at the intraprocedural boundary, so ε is a strict extension of
  this design rather than a replacement for it.
* **γ (runtime-checkable admission) — REJECTED as unnecessary.** γ exists to
  upgrade a declared invariant to "oracle match **or** loud halt". α supplies
  **oracle match**, so there is nothing to upgrade. Both sub-variants also carry
  costs this bead should not pay: γ-a would make extraction synthesise control
  flow for the first time (blast radius: ADR 0022 phi-edge binding, the utzc dead
  set — which `instructions.jl:1628-1631` explicitly warns must stay one set by
  construction — `lower.jl`'s topo sort and back-edge detection); γ-b breaks the
  nine-commit zero-BVM-change streak. And the scout's own honest limit stands: a
  range/alignment check catches only gross violations.
* **β (confinement) — already refuted** by scout §3.3 (a live branch, an
  allocation size, a memmove length). Not re-proposed.

### 1.6 ADR AMENDMENT — full text

An amendment **is** needed, but it is a different *kind* of amendment from §4a's:
§4a introduced a weaker contract and had to write down a downgrade. §4b
introduces a contract at the **existing** strength and must say so, and must
correct §4a's own "explicitly NOT weakened (a)" list, which enumerates the
oracle-match contracts by name.

Insert into `BennettVM.jl/docs/adr/0017-closed-world-execution.md`, immediately
after §4a:

> ### 4b. Value identity: oracle match through memory (Bennett-57hd, 2026-08-07)
>
> **Context.** §4a's confined-value contract deliberately says nothing about
> values that ESCAPE. Julia's `push!` root computes
> `array.ref.ptr_or_offset − array.ref.mem.data` — the `MemoryRef`'s byte
> displacement inside its `GenericMemory` — converts it to an element index with
> `udiv exact 8`, and lets that index escape into a live grow-or-not branch and
> into two closure-environment slots that `_growend!` reads as
> `jl_alloc_genericmemory_unchecked`'s **allocation size** and `llvm.memmove`'s
> **length**. Bennett-583s declines (the two `.data` bases are not syntactically
> the same SSA value). §4a declines, and correctly: clause (iii) requires every
> use of the `sub` to be an `icmp`, and there is no dead-throw sink to confine
> an escaping index into. Under the arena model (`bennettvm-pdqx`: no region
> table, three monotone cursors; ADR 0018 §E: an unstored load reads `0`) a wrong
> allocation size is an undetectable adjacent-allocation clobber, so **no
> confinement-class contract is available for this shape, and none may be
> invented.**
>
> **Decision.** Admit such a coercion under a contract at the **existing**
> (oracle-match) strength, never a weaker one:
>
> > **VALUE-IDENTITY CONTRACT.** A `ptrtoint` `pt = ptrtoint p` may be admitted
> > iff a syntactic analysis establishes all of:
> > (i) `p` is a **certified cell producer** in the §4a clause-(i) sense
> > (`_foz5_cert_src_kind`), named by the emission walk and not suppressed;
> > (ii) `pt` has at least one use, and **every** use is a two-operand **i64**
> > `sub` whose sibling operand is a `ptrtoint pt' = ptrtoint q` with `q` also
> > satisfying (i); and
> > (iii) for every such `sub`, `p` and `q` reduce to the **same canonical value**
> > under a straight-line, single-basic-block copy analysis consisting of
> > aggregate-store field forwarding through an `insertvalue` chain, same-slot
> > reload, and a no-clobber scan over the byte range, where:
> >   * an intervening `call` is treated as writing unknown memory **unless** its
> >     LLVM `memory` (MemoryEffects) attribute proves it writes neither argument
> >     memory nor other memory, or it is `llvm.memcpy`/`memmove`/`memset` with a
> >     compile-time-constant length;
> >   * two roots are disjoint only when one is a `noalias`-returning allocation
> >     (or a non-escaping `alloca`, proved by a `nocapture`-attribute use scan)
> >     and the other provably predates it or is another such fresh object;
> >   * a same-root non-overlap decision is taken only when `_root_scale(root)`
> >     is the **byte tier** (1 byte per cell), so that a native byte-range
> >     disjointness transports to VM cell disjointness.
> >
> > **Guarantee.** For every input, each such `sub` yields `0` in the extracted
> > program and `0` in native, under **any** map from addresses to cell values.
> > The value therefore matches the native oracle exactly, and may escape without
> > restriction.
>
> **Why the guarantee is unconditional where §4a's is conditional.** §4a admits a
> value it cannot prove; §4b admits a value it *can*. `x − x = 0` requires no
> property of the address-to-cell map — not injectivity, not affineness, not the
> byte tier. This contract makes **no** claim about the `MemoryRef` type
> invariant (that field 0 points into field 1's data region); a proposal resting
> on that invariant was considered and rejected, because its failure mode is a
> silently wrong allocation size rather than a halt, and because it was measured
> to claim two clusters §4a already owns.
>
> **What this relaxes: NOTHING.** Decision item 4's "faithful reversible throw"
> is retained unchanged. §4a's downgrade is **not extended**: a value admitted
> under §4b is proved, so it satisfies §4a's conditioning clause "everything
> outside `τ` is computed by the pre-existing, already-sound model" rather than
> violating it. The Bennett-jbko trajectory-correspondence argument is likewise
> preserved — the grow-or-not branch is decided by an oracle-exact index, so
> `arena_top` advances as native's heap would.
>
> **Amendment to §4a.** §4a's "Explicitly NOT weakened (a)" names the
> oracle-match contracts that retain first refusal: *Bennett-583s
> base-cancellation, Bennett-jbko pointer identity, Bennett-8g7m*. Add
> **Bennett-57hd value identity** to that list. Order of refusal is
> 583s → §4a → §4b; §4b is consulted last precisely so that no cluster an
> existing contract owns can change hands.
>
> **Explicitly NOT weakened.**
> (a) `_memdata_root` is untouched; 583s keeps first refusal.
> (b) Nothing is fabricated (Bennett-lbot, reaffirmed): the `sub`, the
>     `udiv exact`, the `add`s, the `icmp`, the `xor` and the `br` are emitted
>     verbatim by the ordinary paths, and the coercion emits the same
>     `IRBinOp(:or, src, 0, 64)` cell-identity node the other two contracts emit.
> (c) Determinism (ADR 0018 §A) is untouched; no new nondeterministic producer.
> (d) The circuit tier is untouched — the admission lives inside the `ptr_cells`
>     gate, `false` on the circuit path. `verify_reversibility` and every gate
>     count are byte-identical.
>
> **Disclosed residual.** The analysis reads LLVM `noalias` / `nocapture` /
> `memory` attributes and trusts them. This is an *IR well-formedness* premise,
> not an ABI or layout premise: a false attribute would miscompile under LLVM's
> own optimiser. A **missing** attribute always rejects. Scope boundary: the
> analysis is intraprocedural and single-block, so a copy chain crossing a call
> with unknown effects, or crossing a basic-block boundary, is refused — it
> degrades to the pre-existing loud wall, never to an admission. The
> interprocedural extension is tracked separately.

---

## 2. MECHANISM

### 2.1 New predicates (all in `src/extract/instructions.jl`, after the foz5 block)

```
_57HD_DEPTH        = 8      # the _memdata_root / _FOZ5_DEPTH idiom
_57HD_SCAN_CAP     = 512    # instructions examined per clobber scan (Rule 1 surprise guard)
_57HD_ESCAPE_DEPTH = 4      # alloca non-escape GEP recursion

_57hd_mem_effects(call)        -> Union{Nothing,Int}   # call site, then callee decl
_57hd_writes_no_ir_memory(me)  -> Bool                 # ArgMem and Other both non-Mod
_57hd_has_noalias_ret(call)    -> Bool
_57hd_nocapture_arg(call, i)   -> Bool                 # call site, then callee decl
_57hd_alloca_noescape(a)       -> Bool                 # (A4)
_57hd_fresh_object(v)          -> Bool                 # alloca | noalias-ret call
_57hd_predates(r, f)           -> Bool                 # same-block definition order
_57hd_roots_disjoint(a, b)     -> Bool                 # (A3)+(A4)
_57hd_write_footprint(i)       -> :unknown | Vector{Tuple{_LLVMRef,Int,Int}}
_57hd_clobbered(root, lo, hi, seq, p1, p2, names, ptr_cells) -> Bool
_57hd_pval(v, blk, seq, order, names, ptr_cells, memo, depth) -> _LLVMRef
_57hd_same_value_cluster(pt, names, suppressed_refs, ptr_cells) -> Bool
```

**Reused, not reimplemented** (CLAUDE.md §12): `_p06b_slot_key` (canonical
`(root, byte-offset)` address key — the N2 hostile-review fix that collapses
redundant `optimize=false` GEP spellings), `_root_scale` (bvmd's byte-tier
predicate), `_foz5_cert_src_kind` (§4a clause (i), including its
`GlobalVariable`-address refusal and its recursive GEP-base discipline),
`_alloca_reservation` via `_root_scale`.

**`_p06b_alias_group` is deliberately NOT reused.** It is function-scoped and
would reintroduce the cross-block reasoning §2.2 refuses. `_57hd_pval`'s
same-slot reload rule is the intra-block specialisation of the same idea; the
shared machinery is `_p06b_slot_key`, which is the part that matters.

### 2.2 `_57hd_pval` — the canonicaliser, and the three ways it is TIGHTER than the scout's prototype

Returns the canonical value ref that `v` provably equals.

1. non-`Instruction` (Argument / Global / constant) ⇒ itself;
2. an instruction **not in `blk`** ⇒ itself — **INTRA-BLOCK ONLY**;
3. a pointer-typed `load` in `blk` at position `p`:
   a. `(root, off) = _p06b_slot_key(addr)`, then canonicalise `root` recursively;
   b. **store-forward**: the latest prior `store` in `blk` whose canonicalised
      slot covers `[off, off+8)`; if the stored type is a `StructType` and the
      stored value is an `insertvalue` chain, extract the field at the right
      `offsetof`; if it is a scalar pointer at relative offset 0, take it
      directly; run `_57hd_clobbered` over the intervening range; recurse;
   c. **same-slot reload**: otherwise, the latest prior pointer-`load` in `blk`
      with the same canonical slot key and no clobber between; recurse;
4. anything else ⇒ itself.

Three deliberate tightenings over the scout's `w10`/`w13` prototypes, each of
which I re-measured to confirm the corpus witness survives:

| tightening | why | measured |
|---|---|---|
| **intra-block scan** (`w13` concatenated ALL blocks in layout order and scanned "between positions" — unsound across a branch or a back edge) | a straight-line range within one block is the only range whose "no write happened in between" is a statement about *execution*, not about *layout*. Also correct under a loop: the store re-executes each iteration. | the whole corpus chain lives in `%top`; `b19` is block-scoped and still returns `val-eq: true` |
| **attribute-driven footprints** (the prototype matched callee NAMES) | converts A1 from declared to checked, and makes drift fail *loud*: an unattributed callee is `:unknown` | `julia.get_pgcstack` has no attribute group at all ⇒ `:unknown`, and the witness survives regardless |
| **`_root_scale == 1` gate on same-root non-overlap** | a byte-range disjointness is a claim about VM cells; only the byte tier makes byte offsets *be* cell offsets. This is the jb6w hazard, pre-empted rather than amplified | `_root_scale(%"new::Array") = (1, 24, …)` |

Both walkers are depth-bounded (`_57HD_DEPTH`), scan-capped (`_57HD_SCAN_CAP`),
memoised per cluster, and **pure** in `names` / `suppressed_refs` /
`dead_blocks` — satisfying binding constraint 3 and 6.

A note the implementer must keep in the docstring: **equality of two canonical
refs is meaningful across blocks even though the walker is not.** If `p ∈ B1` and
`q ∈ B2`, each canonicalises within its own block, so a non-trivial match forces
either `B1 == B2` or a canonical value that is not an instruction. No extra check
is required, and none should be added — but a reader must be told why.

### 2.3 `_57hd_same_value_cluster` — the arm predicate

```
(V0) `_foz5_cert_src_kind(src) !== :none`, `haskey(names, src.ref)`,
     `src.ref ∉ suppressed_refs`.
(V1) `pt` has >= 1 use; EVERY use is a two-operand `sub` of i64 WIDTH,
     whose sibling is a `ptrtoint` also satisfying (V0).
(V2) for each such `sub`: `_57hd_pval(src_of_pt) == _57hd_pval(src_of_sib)`.
```

* **(V0) is not load-bearing for the difference theorem** (`x − x = 0` holds even
  for an unmaterialised cell, which ADR 0018 §E reads as `0` on both sides). It
  **is** load-bearing for the emitted `IRBinOp(:or, src, 0, 64)` reading a cell
  that was actually defined, and it keeps the three disjuncts uniform. Rule 1
  prefers the conservative reject; say so in the docstring rather than leaving a
  reader to wonder why the check is there.
* **(V1)'s i64 width check is load-bearing**, and for the same reason foz5's is
  (hostile review D3): without it a `trunc`-then-`sub i32` cluster differences
  truncated cell values while satisfying the prose.
* **The `sub`'s uses are UNCONSTRAINED, deliberately.** That is the entire
  content of the contract: an oracle-exact value needs no confinement. This must
  be stated in the docstring next to a pointer at §4a's banner, because a reader
  arriving from §4a will expect a (C2)/(C3) clause and its absence is a design
  decision, not an oversight.
* **Explicit NON-GOAL:** α does not propagate through `getelementptr i8` to admit
  a *nonzero* constant displacement. That generalisation would overlap 583s
  without covering anything new, and the corpus has no witness. If one appears,
  it is an additive change to `_57hd_pval` plus a fixture — file it, do not
  pre-build it.

### 2.4 Arm placement and emitted IR

`src/extract/instructions.jl:5187-5227`, the 583s/foz5 block. Entry:

```julia
if opc == LLVM.API.LLVMPtrToInt && src isa LLVM.Instruction &&
   (_memdata_root(src) !== nothing ||
    _foz5_confined_dead_bounds(inst, names, suppressed_refs, dead_blocks) ||
    _57hd_same_value_cluster(inst, names, suppressed_refs, ptr_cells))
```

Admission (`:5209-5210`), the same third disjunct appended. The width guard at
`:5200` is unchanged and already source-agnostic (a8nw review D5) — no reword
needed, but its message text must gain the third predicate name (the p06b arc's
prose-vs-predicate rule).

**Emitted IR: `return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)` —
byte-identical to what both existing disjuncts emit.** The `sub`, the
`udiv exact`, the two `add`s, the `sub`, the `icmp slt`, the `xor` and the `br`
are all emitted by the ordinary paths (binding constraint 4: nothing fabricated).

**BennettVM `src/`: ZERO changes, and this is measured, not assumed.**
`sub`/`udiv` are already first-class on both sides (`instructions.jl:5099-5100`;
`BennettVM/src/ir/operators.jl:104`, with non-injective-op history capture at
`ir/arithmetic_assignment.jl:265`). The `udiv exact` costs history, not
capability. The zero-BVM-change streak reaches **ten**. If the implementer finds
they need a BVM node, that is a late-firing upgrade trigger — stop and escalate
(sy29 §11.3 discipline).

**Circuit tier byte-identical** (binding constraint 5): the whole block is inside
`&& ptr_cells`, which is `false` on the circuit path.

---

## 3. FAILURE MODES AND MESSAGE TERRITORY

### 3.1 Failure modes of the ARM (the theorem has none; the analysis does)

| failure | direction | consequence |
|---|---|---|
| walker cannot decide (unknown call effect, cross-block, non-constant memcpy length, non-byte-tier root, depth/scan cap hit) | **conservative** | `false` ⇒ falls to the existing `_ir_error` — the wall the corpus has today. Never an admission. |
| an LLVM attribute is present and FALSE (A6) | unsound | would require Julia codegen (or clang) to emit a lying `noalias` / `memory(…)`; LLVM's own optimiser would miscompile the same program. Disclosed in the ADR. |
| `_p06b_slot_key` drift | shared | the key is already the single source of truth for p06b's (P5)/(N2)/(D3) surface; a change there is caught by `test_p06b_aggregate_store.jl` (617 assertions) before it reaches here. Note the coupling in both docstrings. |
| `_root_scale` drift | conservative | a scale that stops being `1` turns the same-root judgement into a clobber ⇒ reject ⇒ existing wall. |

### 3.2 New reject text (grep-pinned)

The existing message at `:5211-5225` gains a third paragraph. Anchors that must
survive any reword, because tests pin them: `Bennett-583s` and `width`/`64` (gate
(3) of `test_583s_memdata_bounds.jl`); `_verify_memdata_bounds_cluster`;
`Bennett-foz5`; `_foz5_confined_dead_bounds`. Added:

```
… AND its two coerced pointers are not PROVED to be COPIES OF ONE VALUE
either — predicate `_57hd_same_value_cluster` (Bennett-57hd / ADR 0017 §4b):
every use must be an i64 sub(ptrtoint, ptrtoint) whose two sources reduce to
the SAME canonical value under the single-block copy analysis (aggregate-store
field forwarding, same-slot reload, and a no-clobber scan whose call effects
come from the LLVM `memory` attribute and whose disjointness comes from
`noalias` / `nocapture`), so that the difference is IDENTICALLY ZERO in both
worlds and may escape freely (CLAUDE.md §1).
```

New anchors introduced: `Bennett-57hd`, `_57hd_same_value_cluster`,
`COPIES OF ONE VALUE`. Every existing anchor is preserved (verified by grep over
`test/` for `_verify_memdata_bounds_cluster`, `_foz5_confined_dead_bounds`,
`base-cancelling`).

### 3.3 THE SIX-MARKER ADVANCE — and the identical-text trap

The six sites at HEAD, each verified present by grep:

| file | lines | flipping assertions |
|---|---|---|
| `test_bvmd_root_scale.jl` | 677–707 | `:685` positive, `:688` `!37mt` |
| `test_p06b_aggregate_store.jl` | 765–791 | `:787` positive, `:790` `!37mt` |
| `test_foz5_confined_bounds.jl` | 855–872 | `:876` positive, `:879` `!37mt` |
| `test_40ys_instanceless_callees.jl` | 542–558 | `:558` positive, `:561` `!37mt` (note: `e.msg`, not `msg`) |
| `test_7wsz_ptr_sret_fields.jl` | 551–560 | `:564` positive, `:567` `!37mt` |
| `test_vau9_variable_memmove.jl` | 316–336 | `:332` positive, `:336` `!37mt` |

Wall 11, measured verbatim (probe `w08_fromll.jl` on `root_patched.ll`, which is
`rootmod.ll` with only the wall-10 cluster's two `ptrtoint`s rewritten to
`add i64 0, 0` — the α-admission simulation):

```
ir_extract.jl: call in @julia__push57hd_91:%L16:
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %23, ptr align 8 %"new::Array.ref.mem", i64 8, i1 false)
— llvm.memcpy.p0.p0.i64: memcpy src operand is not alloca-backed (or
alloca-backed via a const-offset GEP). Same restriction as the dst case;
tracked in Bennett-8bys. (Bennett-37mt Phase 1)
```

**THE TRAP, restated so it cannot be missed: this reject text is IDENTICAL to
wall 9's.** Wall 9 was the same 37mt Predicate-6 reject at the same
`(Bennett-37mt Phase 1)` tail; the only textual difference is the **operand name
quoted in the `_ir_error` prefix** — wall 9 quoted `%"new::Array.size_ptr1"`,
wall 11 quotes `%"new::Array.ref.mem"`. Per the sy29 lesson
(`worklog/103:265-275` — "check that your suggested discriminator appears in the
MESSAGE TEXT before recommending it"), I checked every candidate discriminator
against the actual message, not against the IR:

| candidate | in wall-11 msg | usable? |
|---|---|---|
| `Bennett-37mt` | ✓ | positive, but ALSO true at wall 9 |
| `src operand` | ✓ | ALSO true at wall 9 (wall 9 was the src half too) |
| `Bennett-8bys` | ✓ | ALSO true at wall 9 |
| `memcpy` | ✓ | ALSO true at wall 9 |
| **`new::Array.ref.mem`** | ✓ | **THE discriminator** |
| **`new::Array.size_ptr`** | ✗ | **the negative half of the discriminator** |
| `udiv` | ✗ | not constructible (the prefix quotes the ptrtoint, not the cluster) — the bead's own warning, re-confirmed |

Replacement for all six sites, in the foz5/sy29 two-part idiom, non-numeral
anchors only (Bennett-0ncn):

```julia
# BODY SCOPE — unchanged intent: wall 7 was the CLOSURE's `%idxend41` cluster,
# cleared by Bennett-foz5. Keep verbatim.
@test !(occursin("Bennett-583s", msg) && occursin("_growend!", msg))
# NEW LOAD-BEARING NEGATIVES — wall 10 is CLEARED by Bennett-57hd (ADR 0017
# §4b). A 583s/foz5 reject in the ROOT body is now a REGRESSION, not the
# expected wall. (Replaces the sy29-era positive, which asserted exactly this.)
@test !occursin("base-cancelling", msg)
@test !occursin("_foz5_confined_dead_bounds", msg)
@test !occursin("_57hd_same_value_cluster", msg)
# POSITIVE, wall 11 — the loaded-`ptr` (.mem) memcpy SRC class, corpus site #4.
@test occursin("Bennett-37mt", msg) && occursin("src operand", msg)
# DISCRIMINATOR vs WALL 9 — READ THIS BEFORE EDITING. Wall 11's reject TEXT is
# IDENTICAL to wall 9's; the ONLY thing that distinguishes progress from a
# wall-9 regression is WHICH operand the `_ir_error` prefix quotes. Wall 9:
# `%"new::Array.size_ptr1"`. Wall 11: `%"new::Array.ref.mem"`. Neither
# `Bennett-37mt` nor `src operand` nor `Bennett-8bys` can tell them apart, and
# the `udiv exact` discriminator is NOT constructible (the prefix quotes the
# ptrtoint, not the cluster). Do not "simplify" these two lines away.
@test occursin("new::Array.ref.mem", msg)
@test !occursin("new::Array.size_ptr", msg)
```

Assertions that stay **verbatim** at all six sites (each measured still-true on
the wall-11 message, probe `w15_markers.jl` on `root_patched.ll`):
`!(Bennett-p06b && gc_alloc_obj)`, `!"BYTE-granular getelementptr"`,
`!Bennett-bvmd`, `!Bennett-jbko`, `!Bennett-iwo9`, `!Bennett-lgzx`, `!memmove`,
`!"store of non-integer type"`, `!ConcurrencyViolation`.

`test_jbko_ptr_identity_icmp.jl:554-555` asserts `Bennett-583s` /
`base-cancelling` positively **on its own fixture, not the corpus** — untouched.

**Note for whoever clears wall 11** (write it into the replaced blocks, per the
p06b/bvmd/sy29 convention): wall 12 is the p06b `alloca { ptr, ptr }`
silent-skip reject at `%L16` — measured LOUD; the message names `Bennett-p06b`,
`_p06b_cell_ptr_target_kind` and the phrase `SILENTLY SKIPS`, and it does **not**
contain the string `Bennett-1zow`, so a marker written against that bead tag
would never fire; wall 13 is a **second** 37mt/8bys memcpy in `%L16`
(`memcpy operand alloca has non-integer element type`); wall 14 is a bvmd
`_check_scale_coherence!` violation on the 9×i64 closure alloca. **The `%L21` /
`%L43` clusters are NOT future walls** — they are already admitted under §4a
(F1). The bvmd b05 forecast that wall 11 is `Bennett-1zow` is wrong by one
position, as the scout established; that correction still stands.

---

## 4. TEST PLAN

**RED FIRST (CLAUDE.md §3).** Every gate below is written and watched fail
before the predicate exists.

### 4.1 `test/test_57hd_value_identity.jl` — distilled `.ll` gates

Hand-written `.ll` fixtures (not `code_llvm` captures — Rule 5), each run through
`extract_parsed_ir_from_ll(...; ptr_cells=true)`.

| gate | fixture | expectation |
|---|---|---|
| **(A) POSITIVE, corpus-shaped** | `{ptr,ptr}` built by an `insertvalue` chain, stored whole into a `noalias` `gc_alloc_obj(24)` box, both fields reloaded, field 1 GEP'd `{i64,ptr}`+1 and reloaded, the two reloads coerced and subtracted | ADMITTED; the emitted stream contains `IRBinOp(:or, …, 0, 64)` for BOTH coercions and an `IRBinOp(:sub)`; **no** new node kind |
| **(B) CROSS-ALLOCATION reject** | two independent `gc_alloc_obj` boxes, one field from each | REJECTED, message names `_57hd_same_value_cluster` |
| **(C) CLOBBER reject** | (A) plus an intervening `store ptr %other, ptr %box` overlapping the reloaded slot | REJECTED — this is the gate that proves the no-clobber scan is not decorative |
| **(D) UNKNOWN-EFFECT reject** | (A) plus an intervening `call void @opaque(ptr %box)` with **no** `memory` attribute | REJECTED. **This is the A1 premise-flip made permanent**, and it is the fixture a future widener will hit first |
| **(E) LYING-FREE control** | (A) with `noalias` **removed** from the allocator call | REJECTED — A3 pinned |
| **(F) `nocapture` fallback** | (A) with the `nocapture` attribute present only on the callee DECLARATION, not on the call site | ADMITTED — pins the fallback I measured to be load-bearing (A4) |
| **(G) NON-BYTE-TIER reject** | (A) with the box replaced by `malloc(24)` (word tier, `_root_scale == 8`) where a same-root non-overlap decision is required | REJECTED — A5 pinned, and this is the jb6w gate |
| **(H) C-TIER control (jb6w)** | a clang-shaped `struct { void *a; void *b; }` spill: a NAMED `%struct.T` plus a literal `{ptr,ptr}` register-coercion spill, differencing the two fields | REJECTED. α rejects it for a *structural* reason — the two fields are different values, so `pval` differs — which is why α does not need δ′'s "is this really a MemoryRef?" question at all. Pinned as the executable statement that this contract does not widen the jb6w surface |
| **(I) CROSS-BLOCK scope boundary** | (A) with the reload moved into a successor block | REJECTED, **pinned as a SCOPE BOUNDARY, not a bug**, with a comment naming the ε bead. (The scout asked for the `_growend!`-in-between fixture; this is its distilled form plus the honest generalisation) |
| **(J) CALL-IN-BETWEEN scope boundary** | (A) with a `j_#_growend!##0`-shaped opaque call between the store and the reload | REJECTED, same pinning. Mirrors the real `%L21`/`%L43` blockage exactly |
| **(K) ESCAPE reject** | (A) but one use of the `ptrtoint` is a `store i64` | REJECTED by (V1) — the coerced pointer's own value must not escape, only the difference may |
| **(L) WIDTH reject** | (A) with `trunc`-then-`sub i32` | REJECTED — the D3 lesson, inherited |
| **(M) `ptr_cells=false` byte identity** | (A) at `ptr_cells=false` | the pre-existing "unsupported LLVM opcode" wall, byte-identical. Plus a circuit-tier control: `reversible_compile(x -> x + Int8(1), Int8)` gate count unchanged |

### 4.2 Corpus gate

In the same file: `_push57hd` through `extract_parsed_ir_set_from_julia(...;
ptr_cells=true)`, asserting the wall-11 message and its discriminator (§3.3), so
the corpus advance is pinned in **one** owning file as well as in the six markers.

### 4.3 Steal probe — obligation (c), reproduced as an executable gate

Port `b17_foz5_all.jl` + `b19_alpha_checked.jl` into a testset that runs the
three shipped predicates plus the new one over **both** corpus bodies and asserts
the §1.4 table cell-for-cell. This is `p07_steal.jl`'s idiom, and F1 is precisely
the finding a table-shaped gate catches and a prose claim does not.

### 4.4 INERT re-runs — re-measured baselines at HEAD `97a188c`

All ten measured green under `--check-bounds=yes`, individually, per the scout.
**Re-run and DIFF; do not assume.**

| file | baseline | why it is exposed |
|---|---|---|
| `test_583s_memdata_bounds.jl` | 28/28 | first-refusal must not move |
| `test_foz5_confined_bounds.jl` | 63/63 | **the most exposed file.** Gate (B) is the executable refutation of the "oracle match" misreading; gates (C1)/(C2)/(N)/(B1)/(B3)/(C6) pin (C0)'s refusals, and §4b **reuses `_foz5_cert_src_kind`**. All must stay byte-identical |
| `test_jbko_ptr_identity_icmp.jl` | 73/73 | §1.4's indirect coupling |
| `test_bvmd_root_scale.jl` | 84/84 | marker site + `_root_scale`, which A5 consumes |
| `test_p06b_aggregate_store.jl` | 617/617 | marker site + `_p06b_slot_key`, the reuse-regression surface |
| `test_sy29_arena_src_memcpy.jl` | 91/91 | wall 9's arm; wall 11 is its sibling — do NOT edit here |
| `test_37mt_memcpy_const_aligned.jl` | 86/86 | the file wall 11 will edit next — keep byte-identical here |
| `test_vau9_variable_memmove.jl` | 69/69 | marker site |
| `test_40ys_instanceless_callees.jl` | 128/128 | marker site |
| `test_7wsz_ptr_sret_fields.jl` | 106/106 | marker site |

Then the full `Pkg.test()`, captured with
`grep -E "tests passed|tests failed|Test Failed|Got exception|Error During|^ERROR"`.

### 4.5 BennettVM E2E — what runtime evidence THIS contract's premise gets

The bvmd byte-tier gate is the precedent (`BennettVM/test/test_bvmd_byte_tier_vm.jl`,
354 lines, gates (1)…(6)). `test_57hd_value_identity_vm.jl`, same shape:

1. **the handoff shape** — the `ParsedIR` carries the coercion pair and the `sub`;
2. **zero new instruction kinds** — assert the lowered kind SET is a subset of
   `{Define, IntrinsicGCAlloc, MemoryLoad, MemoryStore, StackAlloca}`, so a future
   change reaching for a new node turns it red;
3. **the difference is EXECUTED and is ZERO** — not asserted about the IR, run on
   the VM. **This is the runtime evidence the premise gets**, and it is a
   *stronger* leg than bvmd's: bvmd could only show that the byte tier maps
   cleanly; here the claim under test (`d == 0`) is directly observable;
4. **the escape is exercised** — the computed index must reach a `udiv exact`, an
   allocation-size operand and a length operand, and the run must be oracle-exact
   against native `push!` semantics for that index;
5. **both history regimes (L2 / L3) with exact `unrun!`**, plus per-step inverse;
6. **non-vacuity as an assertion, not a comment** (the sy29 discipline): assert
   the two coerced cells are non-zero and equal, so that a collapse to
   never-written cells (ADR 0018 §E reads them as `0`, and `0 − 0 = 0` too) cannot
   masquerade as a pass. **This gate is mandatory**: without it the E2E test would
   pass for the wrong reason.

Gate 6 is the one a hostile reviewer will ask for. It is in the plan because I
noticed the theorem's own failure mode is degenerate agreement.

---

## 5. RISKS

| # | risk | severity | mitigation | pinned by |
|---|---|---|---|---|
| R1 | an LLVM attribute is present and FALSE (A6) | **HIGH if it happened** | not reachable without LLVM itself miscompiling; a *missing* attribute always rejects; disclosed in the ADR | gates (D), (E) |
| R2 | the new walker admits two values that are not equal (an analysis bug) | **HIGH** | intra-block only; every disjointness and every effect is attribute-derived; every same-root judgement is byte-tier-gated; depth- and scan-capped; `:unknown` defaults everywhere | gates (B), (C), (D), (G) |
| R3 | `_p06b_slot_key` or `_root_scale` drift under a future bead | MED | both are shipped single-sources-of-truth with large owning suites; add a coupling note to both docstrings naming §4b as a new consumer (the `vector_vm_cfg.jl` precedent) | `test_p06b` 617, `test_bvmd` 84 |
| R4 | the wall-11 marker replacement mistakes a wall-9 REGRESSION for progress | **HIGH — this is the sy29 lesson** | the `new::Array.ref.mem` / `!new::Array.size_ptr` discriminator pair, with the reason written into the test comment | §3.3, all six sites |
| R5 | a reader treats §4b as §4a-shaped and reintroduces a confinement clause "for safety", or conversely reads §4a as now-proved | MED | the ADR text says "What this relaxes: NOTHING" explicitly, and the arm docstring says why the `sub`'s uses are unconstrained | ADR §4b; docstring |
| R6 | the analysis is a genuine new capability (~200 LOC) in a file the project treats as core | MED | full 3+1 (this document); no new node kinds; all reuse is of already-hostile-reviewed predicates; scope boundaries are pinned as fixtures (I)/(J) rather than left implicit | gates (I), (J) |
| R7 | scope regret: someone later needs `%L21`-class clusters and finds α cannot reach them | **LOW** | F1 — they are already admitted. If a genuinely new one appears, ε is the filed escalation and it is a strict extension of this design | §1.5 |
| R8 | `nocapture` is spelled `captures(none)` on a newer LLVM | LOW | the fallback is already two-step (call site → declaration); add a third: absence ⇒ `false` ⇒ reject, which is the safe direction. Note it in the docstring | gate (F) |

---

## 6. DIFF SHAPE

| file | change | ~LOC |
|---|---|---|
| `src/extract/instructions.jl` | 11 new `_57hd_*` predicates + 3 constants, placed after the foz5 block | ~200 |
| " | contract header: theorem, the native-returns × native-throws matrix, the A-ledger, the "what is NOT guaranteed" banner (which here says *nothing is*), the non-goal, the scope boundary, the jb6w note | ~110 comment |
| " | third disjunct in the arm's ENTRY (`:5187-5189`) and ADMISSION (`:5209-5210`) | 2 |
| " | third paragraph in the reject message (`:5211-5225`); predicate name added to the width message | ~10 |
| " | coupling notes on `_p06b_slot_key` and `_root_scale` naming §4b as a consumer | ~8 comment |
| `test/test_57hd_value_identity.jl` | gates (A)–(M) + the corpus gate + the steal-probe table | ~450 |
| `test/runtests.jl` | one registration line | 1 |
| six marker files | the §3.3 replacement block | ~14 each |
| `BennettVM.jl/docs/adr/0017-closed-world-execution.md` | §4b + the one-line amendment to §4a(a) | ~70 |
| `BennettVM.jl/test/test_57hd_value_identity_vm.jl` | gates 1–6 | ~300 |
| `BennettVM.jl/src/` | **NOTHING** — streak reaches ten | 0 |
| worklog top chunk | session log | — |
| beads | file ε (interprocedural value identity); file the α non-goal (nonzero constant displacement); note on `Bennett-8bys` that wall 11 is corpus site #4 | — |

Bennett.jl `src/` touch: **one file**, the same file foz5 and bvmd touched, in
the same place, with the same emission.

---

## 7. WHAT I WOULD TELL THE IMPLEMENTER IN ONE PARAGRAPH

Build the canonicaliser intra-block and attribute-driven from the start — the
scout's prototype is a proof of concept for the *idea*, and its cross-block scan
and callee-name tables are exactly the two things that must not ship. Reuse
`_foz5_cert_src_kind`, `_p06b_slot_key` and `_root_scale` verbatim; write the
`:unknown` default before you write any accept path; and run the steal table
(§4.3) *first*, because it is the gate that discovered that two of the three
clusters this bead was scoped around were never anyone's to take.
