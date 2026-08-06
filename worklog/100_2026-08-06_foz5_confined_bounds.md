# Worklog chunk 100 — 2026-08-06 — foz5 confined-value contract (xkl wall 7)

## Session log — 2026-08-06 — Bennett-foz5: the CONFINED-VALUE contract clears wall 7 (full 3+1, IMPLEMENTER half)

Chunk 099 closed at 459 lines; starting 100 per CLAUDE.md §0.

**Arc shape:** design-verifying scout → **UPGRADE to full 3+1** → 2 blind
proposers → implementer adjudication (Phase 1) → orchestrator ratification →
implementation (Phase 2, this entry). Nothing committed by me; orchestrator
gates the commit.

### The scout upgrade — why the bead's scoping was false

`Bennett-foz5` was filed as "a root-recognition widening of 583s **under 583s's
own subtraction proof**", which would have been a reduced pass. It is
measurably not that. 583s's subtraction proof **IS** syntactic root equality
(`_verify_memdata_bounds_cluster` demands `_memdata_root(sib) == root`), and
the walling cluster has **two structurally disjoint roots arriving through two
different function `Argument`s**: Julia codegen splits a closure-captured
`MemoryRef` in half — `.ptr_or_offset` stays inline in the closure env at byte
+56, the GC-tracked `.mem` is hoisted into the roots array at +16. No SSA edge
joins them. Any admission therefore rests on a **new soundness contract**, not
on 583s's. That is CLAUDE.md §2 territory.

**Two bead-text corrections worth banking** (both were wrong in ways that would
have produced a regression if implemented literally):

1. The bead named the wrong instruction. The walled ptrtoint is the `.data`
   half, whose root **IS** recognised; what fails is the *sibling*. The reject
   is 583s's cluster message, not iwo9's.
2. The bead's proposed root shape (`load` of a `{ptr,ptr}` field-0 GEP, with
   `insertvalue`/`extractvalue` chasing) **STEALS jbko's `%L84` corpus
   witness** — probe `p07_steal.jl`: 583s claims it, its cluster gate fails
   (the use is an `icmp eq`, not a `sub`), 583s **errors**, and the chain
   regresses to a wall EARLIER than wall 7. Measured, not theorised.

### The adjudication — and the one thing each proposal got wrong

Two credible, materially different routes came back:

* **A — route (a′):** dead-throw *confinement* as a second disjunct of the 583s
  cluster gate, emitting the same `:or` cell identity. `_memdata_root`
  untouched; the gate is on the ptrtoint's **USE SHAPE**.
* **B — route (b-variant):** monotone *zero-cell neutralisation* — emit
  `IRBinOp(:add, 0, 0, 64)` for the unprovable ptrtoints, with a crisp
  monotonicity theorem ("the VM never halts where native does not").

**Behaviour matrix, which is what decided it.**

| | native returns | native throws |
|---|---|---|
| **A** guard true | oracle match (proved) | missed throw — *unproven, expected absent* |
| **A** guard false | spurious loud halt — *unproven, expected absent* | faithful throw |
| **B** guard true (always, unless `X==0`) | oracle match (proved) | **missed throw — PROVED to occur on every OOB input** |
| **B** guard false | impossible (proved) | only when `X==0` |

So B does **not** have "a strict subset of A's failure directions" in any useful
sense: it converts two *possibilities* into one *certainty*. That framing is the
decisive one and is worth reusing whenever a route offers to trade an unproven
risk for a proven weakening.

**The measurement that broke the tie** (mine, `scratchpad/adj1.ll`): a byte GEP
lowers to `IRVarGEP(_, _, _, 8)` — elem_width 8 bits, i.e. **one cell per
byte** — and BennettVM stamps the Julia tier byte-granular (`_byte_cells`,
`BennettVM/src/ir/intrinsics.jl`). Therefore `D_vm − M.data_vm = byteoff`
**exactly**, provided the closure slot was written by extracted code — which is
precisely what the closed-world gate guarantees. **(INV) is not provable
extraction-locally (the scout is right) but it is a consequence of the
closed-world byte-granular arena, not a Julia-ABI layout fact.** A's admitted
value is therefore expected *faithful*, not garbage, which defused B's central
charge ("a flaky VM halt on a correct program, in a build the test suite calls
green").

**What a missed throw actually costs, measured by this project already:** the
p06b arc's pdqx escalation established that *"a reserved-regions bounds check
CANNOT catch adjacent-allocation clobbers — no region table in BVM, three
monotone cursors"* (chunk 099), and ADR 0018 §E defines an unstored load as `0`.
So a missed `_growend!` bounds throw is an **undetectable adjacent-allocation
clobber**. That is Bennett-lbot's harm class exactly.

**Each proposal had exactly one materially wrong claim. Bank both.**

* **B's lbot distinction #2 is factually false.** B argued lbot's `bit := 0`
  "carries no theorem; could route either way relative to native". It cannot:
  `bit := 0` means "no overflow", which routes **deterministically away from
  the throw** — the *same single direction* B claims as its distinguishing
  feature. And B's distinction #3 ("after foz5's missed throw the program
  continues with a faithfully-computed element pointer, unlike lbot's
  corrupting continuation") is refuted by pdqx above. Only distinction #1
  partially survives, and the byte-granular finding undercuts its premise. **The
  lbot ruling does not reach A** (A fabricates nothing) **but it does reach B.**
* **A's (C0) was a P0 hole that neither proposer flagged.** A gated the source
  on `haskey(names, src.ref)` — which is *exactly* the test the jbko block
  warns is insufficient: a PointerType `phi`/`select` carries the Bennett-cc0
  M2b **WIDTH-0 SENTINEL** (routing lives in `ptr_provenance` at LOWERING time,
  not as a value), so coercing one emits an `:or` identity over a cell that was
  **never materialised** — a SILENT miscompile class. Fixed by a positive
  certified-source whitelist (`_foz5_cert_src_kind`). **`_jbko_cell_ptr_src_kind`
  could not be reused verbatim**: it is `load`/`extractvalue` only and would
  refuse the corpus's `getelementptr`-sourced element half. Two whitelists,
  deliberately different sizes, for deliberately different contracts.

Also refuted: **B's R3 charge that "route (a) has the mixed-component hazard
too"**. A emits the *same* node on both disjuncts, so no per-component
consistency obligation exists; the `0 − address` hazard is self-inflicted by B's
second emission shape. And **B's N4b is not the checked premise its ledger
claims** — an operand-closure walk does not traverse loads, so an address
laundered through memory would pass; it is saved only by the ambient rule that a
ptrtoint with a `store` use is rejected upstream, an argument B never makes.

### What landed (ratified: A′ hardened)

**One src file.** `src/extract/instructions.jl`:

* `_FOZ5_I1ALG` / `_FOZ5_DEPTH` / `_FOZ5_CLOSURE_CAP`, `_foz5_is_i1`,
  `_foz5_cert_src_kind`, `_foz5_i1_confined`, `_foz5_confined_dead_bounds`
  (+ ~110 lines of contract, theorem, ledger and the "what is NOT guaranteed"
  banner) after `_verify_memdata_bounds_cluster`.
* The 583s arm's **entry** and **admission** each gain `|| _foz5_…`, with 583s
  keeping **first refusal** (`||` short-circuits).
* Both 583s messages reworded **source-agnostic** (a non-memdata source now
  reaches them — the a8nw review-D5 defect class) and each now **names its
  enforcing predicate** (the p06b arc's prose-vs-predicate rule).

Plus a comment-only coupling note in `vector_vm_cfg.jl` (three consumers of
`_vec_vm_dead_blocks` now, and foz5's is the one whose theorem breaks in the
**silent** direction if the two definitions ever drift).

**Three mechanics taken from proposal B** (the synthesis half — B lost the
route but won these):

1. Consume the **already-threaded `dead_blocks` kwarg** rather than calling
   `_vec_vm_dead_blocks` per instruction. Same helper, same set, O(1), and it
   satisfies the `vector_vm_cfg.jl` COUPLING warning *by construction*.
2. Gate **(B2)** (inverted branch polarity) — which under A is **GREEN**, and
   therefore pins that this contract is **polarity-agnostic** and carries none
   of B's `successors(br)[2] == false-target` LLVM.jl API premise.
3. Gate **(Q)** `CROSS_MEM_CONFINED` and B's shared-machinery re-run list.

### Gotchas that cost cycles

1. **A dead-block fixture needs a throw-family call.**
   `_assert_dead_block_is_throw_skeleton` refuses to prune an `unreachable`
   block that has a predecessor but no throw/`llvm.trap` call ("a SURPRISING
   unreachable block whose halt reason is unmodelled"). A bare `unreachable`
   fixture fails loud for the *wrong reason* and looks like a predicate bug.
2. **`runfile` is `Base.include(@__MODULE__, path)` — every test file shares ONE
   module namespace.** An unprefixed `_extract_ll(name, ir, entry; cells)` in a
   new file would silently OVERWRITE `test_583s_memdata_bounds.jl`'s method of
   the identical signature. All helpers here are `_foz5_`-prefixed.
3. **RED-first paid for itself immediately.** Gate (G)'s message disjunction was
   wrong: both its sources are `load ptr` values, which **are** certified by
   `_jbko_cell_ptr_src_kind`, so the *jbko* arm's entry fires and its use gate
   rejects — a jbko-named message, which my disjunction did not admit. Only the
   RED run surfaced it.
4. **A wall-clearing bead moves KNOWN-GAP pins, not just wall markers.**
   `test_40ys` gate (J) (Bennett-9tg3, `:skip` silently drops the ROOT) asserted
   `length(out) == 2`. foz5 clears the closure's wall, so the closure now
   extracts completely and joins the set → **3**. The gap is unchanged; the
   surrounding facts moved, and the demonstration got *sharper* (the set now
   contains a 52-block body with `IRCall`s, so it looks even more like a
   successful extraction while the entry is still missing). Retired the "no body
   calls any other" evidence for the stronger invariant "no member of the set is
   the entry". **Grep for KNOWN-GAP pins, not just marker files, when a wall
   falls.**

### The marker narrowing — take BOTH forms

Wall 8 **is** a p06b reject, so the four marker files' blanket
`!occursin("Bennett-p06b")` cannot survive; deleting it would retire the
over-tight-reject alarm the negative exists for. Neither narrowing alone is
enough, so all four files now carry both:

```julia
# BODY SCOPE — preserves the original intent verbatim, recycling the retired
# `occursin("_growend!")` POSITIVE as the negative's scope term.
@test !(occursin("Bennett-p06b", msg) && occursin("_growend!", msg))
# DISCRIMINATOR — fails LOUD if the tolerated p06b reject changes SHAPE, which
# the body scope alone would absorb.
@test !occursin("Bennett-p06b", msg) || occursin("gc_alloc_obj", msg)
```

Positives use **non-numeral anchors only** (`gc_alloc_obj` / `BYTE-granular`,
not `9n3y`) per the Bennett-0ncn lesson. New load-bearing negatives
`!occursin("Bennett-583s")` + `!occursin("base-cancelling")` prove wall 7 is
cleared. `occursin("_growend!")` is dropped as a positive (the wall moved to the
root body) but survives as the body-scope term — retired from one role, reused
in another.

### The validation debt — say it out loud

**No runtime evidence about either unproven direction can exist until wall 8
clears** (`Bennett-bvmd`), because the corpus still walls in the ROOT body
before BennettVM can execute it. The soundness case rests entirely on the
theorem plus the byte-granular lowering measurement. Both proposers' "BVM E2E
not required" conclusions are correct but for a weaker reason than they gave: it
is not that an E2E would add nothing, it is that **an E2E is not yet
constructible**. Disclosed in the arm's doc block, in the (Q) gate banner, and
in ADR 0017 §4a.

### Gates (all serial, `--check-bounds=yes`)

* NEW `test_foz5_confined_bounds.jl`: **RED 26P/9F/2E at HEAD → GREEN 47/47**;
  then, for the fix cycle, a second RED taken by reverting ONLY the D1/D2/D3
  hunks and keeping the landed arm (a HEAD stash is the wrong baseline — it
  deletes the predicate and yields Errors, not RED): **53P/9F → GREEN 62/62**.
  HR1-HR4 fail 2/2 each; HR5 passes in both states (it is a scope-boundary pin,
  not a fix pin); HR6 fails 1/3 — its extraction outcome is unchanged, only the
  predicate assertion flips.
* INERT, **zero edits**: `test_583s` (incl. (5) CROSS_MEM and (4) NON_MEMDATA),
  `test_jbko` (incl. (O) MEMDATA_ICMP), `test_59zi`, `test_iwo9` — all green.
  `test_iwo9` re-run specifically because D1 changes attribution for
  global-load shapes; its pins are unaffected (30/30).
* Shared machinery (`_vec_vm_dead_blocks` read-only): `test_utzc`,
  `test_jfw6`, `test_d1b`, `test_3vf2` — green.
* 4 marker files advanced to wall 8 — green. Gate-count regression 39/39.
* BennettVM E2E: `test_p06b_aggregate_store_vm`, `test_jbko_ptr_identity_vm`,
  `test_vau9_memmove_vm`, `test_utzc_unreachable_sink`, `test_tl1l_a70z_shapes`
  — green. **Zero BennettVM `src/` changes** (the admitted node is the identical
  `IRBinOp(:or, …, 0, 64)` 583s already emits).

### Hostile review — PASS-WITH-CONCERNS, and the fix cycle

The reviewer's verdict was *conditionally fit to commit, but NOT with ADR §4a as
written*: clauses (i) and (b) claimed more than `_foz5_cert_src_kind` delivered.
Three code defects, all in the ONE predicate the implementer added in review
(the p06b arc lesson "a fix is a new code path and deserves the same adversarial
probing as the original", applied to a hardening):

* **D1 — the `:load` arm certified a value that is never materialised.** The
  bennettvm-416r.13 / CW-D3 Lever 2 **singleton-data alias arm** intercepts
  `load ptr, ptr @"jl_global#N"`, emits **NO IRInst at all**, and aliases the
  result NAME to the global symbol. `_p06b_suppressed_refs` holds only sret
  boxes, so neither `haskey(names, …)` nor the suppressed check in (C0) sees it.
  MEASURED: `IRBinOp(:b, :or, SSAOperand(Symbol("jl_global#77")),
  ConstOperand(0), 64)` — an `:or` cell identity over a **global base symbol**.
  Fixed by refusing a `load` whose pointer operand `isa LLVM.GlobalVariable`.
  **This is the THIRD time in two beads that "registered SSA name" was mistaken
  for "materialised cell"** (p06b D1b was the first two). The lesson is not
  learned until the *predicate* encodes it.
* **D2 — the sentinel refusal was depth-0, and one instruction bypassed it.**
  `%pg = getelementptr i8, ptr %ph, i64 %off` over a PointerType `phi` (fixture
  B1), the same over a `select` (C6), and a `load` through such an address (B2)
  ALL ADMITTED, with the WIDTH-0 SENTINEL sitting in the emitted chain. Fixed by
  making the GEP arm **recursive on its base** — a GEP is an offset from its
  base, so it is a cell only if its base is. **Index constness is deliberately
  NOT required**, unlike `_p06b_slot_key`'s canonicalising walk: the corpus's
  own element GEP has a variable index, and the sentinel question is about the
  BASE, not the displacement.
  The `load` arm stays **depth-0 on purpose** and this is now written down in
  three places rather than papered over: the value a load produces is a fresh
  cell whatever its address was, so the address-sentinel question belongs to
  the **load arm** — the `IRLoad` reading the sentinel address is emitted with
  or without a following coercion, so foz5 adds nothing to that hazard. Pinned
  as KNOWN-ADMITTED gate (HR5) with a flip-don't-delete banner.
* **D3 — the `sub` width was prose, not predicate.** Added the i64 check. The
  extraction outcome is unchanged (the arm's own width guard already rejects,
  and it runs after the entry condition), so this is defence-in-depth **for the
  Bennett-sku0 reuse**, which will call the predicate with no width guard in
  front of it. The gate therefore asserts the PREDICATE, not the message.

**Two fixture bugs worth banking, both found by RED-first and both of the same
species — a gate that passes for the wrong reason.** (1) A
`trunc`-then-`sub i32` fixture does NOT exercise the width check: the
ptrtoint's use is then the `trunc`, which (C1) already refuses as "not a
`sub`". (2) Making the coercions i32 is still not enough if the `sub` is
`zext`ed before the compare — the `sub`'s use is then the `zext`, refused by
(C2). The chain must be **i32 end to end**: coercions, `sub` AND `icmp`. Both
drafts went green pre-fix, i.e. would have shipped as decoration. **When a new
guard's gate passes before the guard exists, the fixture is wrong, not the
guard redundant.**

Also renamed the six new gates to an `HR*` prefix: the natural names collided
with existing labels, and `_FOZ5_B2` was momentarily bound twice in one file
(the inverted-polarity fixture and the sentinel-load fixture) — a genuine
redefinition bug that a linear read would not have caught.

### The ratified contract, as SHIPPED (verbatim `BennettVM.jl/docs/adr/0017-closed-world-execution.md`)

Quoted in full deliberately: the adjudication summary above is the *reasoning*, but the
ADR text is the *contract*, and a future agent must be able to read it without a
cross-repo checkout. This is the post-hostile-review wording (defect D2 forced clauses
(i) and (b) to be rewritten so they are LITERALLY TRUE of the shipped predicate — the
original draft claimed depth-∞ sentinel refusal, which `_foz5_cert_src_kind` does not
deliver for load-sourced values).

```markdown
### 4a. Confined values: admission without an oracle-match proof (Bennett-foz5, 2026-08-06)

**Context.** The keep-branch dead-block pruner (Decision item 4 / Bennett-utzc) leaves the predecessor's conditional branch into a pruned `unreachable` block intact, so a guard that fires at runtime reaches BennettVM's `:__unreachable__` halt sink — described in `module_walk.jl` as "a faithful reversible throw". That description presumes the guard's condition is computed from values admitted under **oracle match**: every admitted value provably equals what native computes.

Julia's `@boundscheck` cluster under `--check-bounds=yes` computes a pointer difference across the two halves of a **split captured `MemoryRef`** — the `.ptr_or_offset` half read from the closure environment struct, the `.mem` half read from the GC-roots array. The two halves arrive through different function arguments with no SSA edge between them, and the only in-body pairing witness is a dead `insertvalue` that survives solely because extraction runs at `optimize=false`. Oracle match is therefore **not provable extraction-locally**, and never will be. (It is nevertheless expected to *hold* at runtime, because BennettVM's Julia tier is byte-granular (`_byte_cells`) and the closure slot is written by extracted code — but that is a property of the closed world, not a theorem the extractor can check.)

**Decision.** Introduce a *second*, strictly weaker admission contract, applicable **only** to values whose entire influence on the program is a dead-throw branch condition:

> **CONFINED-VALUE CONTRACT.** A value `v` may be admitted without an oracle-match proof iff a syntactic predicate establishes all of:
> (i) `v`'s source pointer is a **certified cell producer**, and is neither unnamed nor suppressed by the emission walk. "Certified cell producer" is exactly the positive whitelist below. Its depth discipline differs per arm, and is written out here because the guarantee is only as strong as it:
>   * an `extractvalue` of a StructType pointer field;
>   * a `load` of a pointer **whose pointer operand is not a `GlobalVariable`** — that shape is intercepted by the singleton-data alias arm, which emits no node at all and aliases the result name to a global symbol, so it is *registered without being materialised*. This arm is **depth-0 with respect to the loaded value's address**: the value a load produces is a fresh cell whatever its address was. A load *through* a WIDTH-0-SENTINEL address is therefore certified here, deliberately — the address question belongs to the load arm, whose node is emitted with or without a following coercion. **Clause (i) consequently does not provide sentinel-freedom for load-sourced values.**
>   * a `getelementptr` **whose base chain terminates in one of the above**. This arm is recursive precisely so that an interposed GEP cannot launder a PointerType `phi`/`select` — the Bennett-cc0 M2b WIDTH-0 SENTINEL, whose routing lives in `ptr_provenance` at lowering time rather than as a value — into a certified source. Index constness is not required (the corpus GEP has a variable index).
>
>   A PointerType `phi`/`select` is thus never certified **as a source, nor as a GEP base**. It may still appear as the *address* of a certified `load`, per the arm above;
> (ii) `v` has at least one use, and **every** use is a two-operand **i64** `sub` whose sibling operand is itself a `ptrtoint`;
> (iii) every use of each such `sub` is an `icmp`;
> (iv) the transitive use-closure of each such `icmp` contains only i1-typed `and`/`or`/`xor` instructions, each with at least one use, and conditional `br` terminators consuming the value as their **condition operand**; and every such `br` has at least one successor in the Decision-item-4 pruned dead-block set.
>
> For such `v` the guarantee is: **for every input on which the native program returns a value, the extracted program returns the same value or halts at the `:__unreachable__` sink.**

**What this relaxes, stated exactly.** Decision item 4's "faithful reversible throw" is retained **unchanged for guards admitted under a proof** (Bennett-583s base-cancellation, Bennett-jbko pointer identity, Bennett-8g7m). For a guard whose condition depends on a confined value it is downgraded from *proved faithful* to **unproved**: the throw may be missed, or the halt may be spurious, on inputs where the unprovable premise fails. Neither direction is *authorised* — both are *unbounded by the theorem*.

**Explicitly NOT weakened.**
(a) **Oracle-match proofs retain first refusal.** Where Bennett-583s's base-cancellation proof applies, it is used; the confined contract is consulted only after it fails (`||` short-circuit). A value with a single non-conforming use stays under oracle match and stays rejected.
(b) **No guard bit is ever fabricated.** Extraction never substitutes a constant, a zero cell, or any other placeholder for an operand of an unmodellable guard, and never rewrites or elides the compare or the branch: the `sub`, the `icmp`, the i1 algebra and the `br` are all emitted verbatim by the ordinary paths, and the coercion emits the same cell-identity node the base-cancellation proof emits. The bit is therefore *computed*, from operands the extraction has emitted defining nodes for — which is a claim about **provenance, not about correctness**. It is not a claim that those operands equal the native values (that is exactly what the contract declines to prove), nor, per clause (i)'s load arm, that every cell they transitively read was itself materialised. Emitting a placeholder that provably weakens a guard remains **UNSOUND** — the Bennett-lbot ruling is reaffirmed, not narrowed: under BennettVM's arena model there is no region table and three monotone cursors (`bennettvm-pdqx`), so a missed throw is an *undetectable* adjacent-allocation clobber, and ADR 0018 §E defines an unstored load as `0`.
(c) **Determinism (ADR 0018 §A) is untouched.** The contract neither relies on nondeterminism nor admits any new nondeterministic producer; the Bennett-klgz guard sits at the unrecognised-JIT-global reject and is unreachable from this admission.
(d) **The circuit tier is untouched.** The admission lives inside the `ptr_cells` gate, which is `false` on the circuit path; `verify_reversibility` and gate counts are byte-identical.

**Disclosed residual.** A confined value that were nondeterministic could make the *halt itself* nondeterministic. This is a reproducibility, not a correctness, degradation, and does not arise under ADR 0018 §A's deterministic arena.
```

### Arc lessons (bank these)

1. **"Which failure directions?" beats "how many?"** A route with two unproven
   failure directions can strictly dominate one with a single *proved* one.
   Count certainties, not possibilities.
2. **A proposal's distinguishing argument against a precedent is the first thing
   to re-derive.** B's whole case rested on three named differences from
   Bennett-lbot; two collapsed under a five-minute read of lbot's actual text
   and the project's own pdqx measurement.
3. **Gate on USE SHAPE, not on source provenance, when you want disjointness to
   be structural.** Widening `_memdata_root` would have made foz5/jbko
   disjointness an empirical accident; gating on uses makes it a theorem
   (`sub` ≠ `icmp`), and arm ordering stops being load-bearing.
4. **When you cannot prove a value is right, prove it cannot matter.** Then
   write down, in the ADR and in the arm comment, exactly which column of the
   behaviour matrix you did *not* cover — the misreading of "oracle match or
   loud halt" as "oracle match" is the contract's chief hazard.

### Beads

Filed by the orchestrator (do not re-file): **Bennett-bvmd** (wall 8: p06b
`gc_alloc_obj` BYTE-granular aggregate-store target, ROOT body, CW-D4 /
`bennettvm-9n3y`; carries the validation-debt note); **Bennett-sku0** annotated
with the `_foz5_i1_confined` linkage — its candidate fix (b) is this predicate
verbatim, which converts the jbko arm's *informal* confinement reliance ("a
Rule 1 property of the surrounding shape, not something this gate enforces")
into an enforceable one. Deliberately NOT folded into this diff (one bead per
commit). The `Bennett-foz5` description is corrected by the orchestrator at
close.
