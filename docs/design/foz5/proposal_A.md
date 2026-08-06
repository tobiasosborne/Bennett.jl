# Bennett-foz5 — PROPOSER A

**HEAD:** `ebcebe2`. **Mode:** every claim below is probe-backed under
`julia --project --check-bounds=yes`. No `src/` or `test/` change was made.
**Probes (new, this session):**
`scratchpad/pA_conf.jl` (the predicate, monkey-patched onto HEAD),
`scratchpad/pA_fixtures.jl` (11-fixture gate table),
`scratchpad/pA_head_base.jl` (HEAD baseline for the same table),
`scratchpad/pA_corpus.jl` (real `push!` gated path + marker table),
`scratchpad/pA_inv.jl` (node inventory of the widened `_growend!`).
Scout probes re-run and confirmed: `p04b_root.jl`, `p07_steal.jl`, `p06_next2.jl`.

---

## 0. VERDICT

**Route (a), sharpened — "dead-throw confinement as a SECOND DISJUNCT of the
583s cluster gate, with `_memdata_root` left byte-for-byte untouched."**

I call this **route (a′)**. It differs from the scout's sketch of (a) in one
decisive way: it is **not** a root widening at all. `_memdata_root` is not
edited, the 583s strong (base-cancellation) proof keeps first-refusal on every
shape it already owns, and the new admission is entry-gated on the ptrtoint's
**USE shape**, never on its source's provenance. That single choice
simultaneously (i) makes the jbko steal *structurally impossible* rather than
merely *empirically absent*, (ii) leaves the jbko `_memdata_root(src) === nothing`
pin correct and unmodified (the a8nw note stays literally true, not inverted),
and (iii) keeps `test_583s` gate (5) CROSS_MEM red **unedited** for a reason I
can state in one line.

Measured delta on an 11-fixture table (HEAD vs patched, `pA_head_base.jl` vs
`pA_conf.jl`): **exactly one admission changes.**

| fixture | HEAD | route (a′) |
|---|---|---|
| `CLUSTER_OK` (583s gate 1) | OK, 2 cell-identities | **OK, 2** — unchanged |
| `CROSS_MEM` (583s gate 5) | ERR `Bennett-583s` | **ERR `Bennett-583s`** — unchanged |
| `NON_MEMDATA` (583s gate 4) | ERR `Bennett-iwo9` | **ERR `Bennett-iwo9`** — unchanged |
| `ESCAPE_HASH` (583s gate 2a) | ERR `Bennett-583s` | **ERR `Bennett-583s`** — unchanged |
| `O2_JBKO` (jbko steal pin) | OK, 1 cell-identity | **OK, 1** — unchanged, **no steal** |
| `A_GREEN` (the S1 corpus shape) | ERR `Bennett-583s` | **OK, 2** ← the whole delta |
| `B_NOSINK` (no dead-throw sink) | ERR | **ERR** |
| `C_ESCAPE` (ptrtoint feeds `add`) | ERR | **ERR** (attribution shifts — §3.3) |
| `D_SUBESC` (sub result returned) | ERR | **ERR** |
| `E_SELECT` (i1 feeds `select`) | ERR | **ERR** |
| `F_ZEXT` (i1 `zext`ed to a value) | ERR | **ERR** |

Real corpus (`pA_corpus.jl`): the `_growend!` closure extracts **completely**
(52 blocks) and the set walls at the forecast **wall 8**, the root body's
`gc_alloc_obj` byte-granular aggregate-store refusal. Node inventory
(`pA_inv.jl`) is **byte-identical to the scout's `p08c` inventory** — existing
`IRInst` forms only ⇒ **zero BennettVM `src/` changes**.

---

## 1. Route decision and soundness argument

### 1.1 Why not (b) — cluster elision

Rejected on five grounds, in descending order of weight.

1. **It fails OPEN; confinement fails CLOSED.** Elision replaces a recognised
   cluster with a constant-true branch. If the recognised shape drifts (Rule 5
   — LLVM reassociates the `and`, sinks the `xor`, inserts a `zext`), a
   *confinement* predicate returns `false` and we **reject loudly**; an
   *elision* recogniser either mis-matches (reject, fine) **or partially
   matches and drops a check that was not the one we thought** — which is the
   silent-miscompile direction CLAUDE.md §1 exists to forbid.
2. **It requires proving strictly more.** To constant-fold the branch you must
   prove *the check never fires* — that is exactly `(INV)` (`D = M.data + k`),
   the cross-function, cross-argument fact the scout showed is not derivable
   (scout §4.2, re-verified by `p04b_root.jl`: two roots, two different
   `Argument`s, no SSA edge; the only pairing witness `%93 insertvalue` is dead
   code). Confinement proves the strictly weaker "*if* it fires, we halt",
   which **is** derivable. Elision buys nothing and costs the whole assumption.
3. **It deletes the loud halt.** A genuinely out-of-range program would
   silently proceed. Rule 1 violation by construction.
4. **The cluster is not separable.** In the corpus the bounds `icmp` is `and`ed
   with `%101 = xor i1 %memoryref_ovflw48, true` — the *size-overflow* guard,
   a different, fully in-model check. Eliding the `and` also elides the
   overflow guard; not eliding it means surgery on the i1 algebra to rewrite
   one operand. Fragile, and it *is* a new `IRInst`-emission path.
5. **It is the only route with BVM blast radius.** Elision changes the emitted
   node set and the CFG. Route (a′) emits the identical
   `IRBinOp(dest, :or, SSAOperand, ConstOperand(0), 64)` that 583s already
   emits — measured zero-diff inventory (`pA_inv.jl`).

An "elision-lite" (route the `icmp` to constant true) is just assumption
**A-foz5** with worse failure behaviour. Also rejected.

### 1.2 Why not (c) — certified cross-function pairing

The closed-world machinery that exists is `extract/callgraph.jl`
(`transitive_callees`) and `extract/julia_set.jl` — a **forward callee
discovery** walk producing *independent* `ParsedIR`s per body. There is no
inter-body value model, and `(INV)` needs a **backward**, interprocedural fact
about how the *caller* materialised the `MemoryRef` before splitting it across
the closure env (`+56`) and the GC roots array (`+16`). Building that tier is a
new subsystem for one dead bounds check.

Worse, it would not even be sound in the source language. Julia's own
`ConcurrencyViolationError` guard at `_growend!` `%L84` exists **precisely
because the two halves may disagree** (`p04b_root.jl` shows it in this very
body). `(INV)` is therefore not a theorem of Julia; it is a "no concurrent
mutation" *precondition*. Under a single-threaded VM it holds — but that is an
assumption about BVM's thread model, no more checkable than **A5** below, and
it buys nothing route (a′) does not already give. Rejected.

The **named-assumption** option (scout §4.3, A-foz5) is rejected for the same
reason plus one: it is an *unconditional* admission, so its blast radius is
every cross-object pointer difference in the corpus, forever, with no syntactic
brake. Route (a′)'s admission is capped by a checkable predicate.

### 1.3 Route (a′) — the theorem

**Setting.** `pt = ptrtoint p to i64` inside function `F`, extracted with
`ptr_cells=true`. Let `D = _vec_vm_dead_blocks(F)` — the set of
`unreachable`-terminated blocks (`src/extract/vector_vm_cfg.jl:12`), which is
*by construction* exactly the set the Bennett-utzc pruner empties
(`src/extract/module_walk.jl:426, 455-461`).

**Premises** (all syntactic, all extraction-local, all decided by
`_foz5_confined_dead_bounds`):

* **(C0)** `p` is an `LLVM.Instruction`, `haskey(names, p.ref)`, and
  `p.ref ∉ suppressed_refs`.
* **(C1)** `uses(pt) ≠ ∅`, and every use is a 2-operand `sub` of i64 result
  type whose sibling operand is itself a `ptrtoint`.
* **(C2)** For each such `sub s`: `uses(s) ≠ ∅` and every use is an `icmp`.
* **(C3)** For each such `icmp c`, the transitive use-closure of `c` contains
  only: i1-typed `and`/`or`/`xor` instructions (each with ≥1 use), and
  conditional `br` terminators whose **condition operand** is the value in
  question; and every such `br` has **at least one successor in `D`**.
  Depth-bounded at 8 (the `_memdata_root` / `_param_ptr_root_ref` idiom).

**Contract (the weakened invariant).**

> For every input on which the **native** program returns a value, the
> extracted program either returns the **same** value, or **halts loudly** at
> the `:__unreachable__` sink.

**Proof.** Let `τ` be the set of extracted values transitively derived from
`pt` through (C1)–(C3). By (C1)–(C3), `τ ⊆ {ptrtoint results, subs, icmps,
i1-algebra nodes}`; no member of `τ` is stored, returned, `inttoptr`ed,
`zext`ed, `select`ed on, or `phi`'d. The **only** consumers of `τ` outside `τ`
are the conditional `br`s of (C3). Hence `τ` influences the extracted execution
solely through the successor choice at those `br`s.

Take such a `br c, %T, %F` with (wlog) `%F ∈ D`. The pruner replaces `%F`'s
body with `IRInst[]` and its terminator with `IRBranch(nothing,
:__unreachable__, nothing)`; `_assert_dead_block_no_live_escape`
(`module_walk.jl:89`) has already proved nothing defined in `%F` is used live.
BVM materialises `:__unreachable__` as `UnreachableHalt`
(`BennettVM/src/ir/ingest.jl:327-354, 600-608`), which sets interpreter status
`:error` and raises (`BennettVM/src/interpreter/Interpreter.jl:1861-1885`) — a
loud halt, never a silent continue.

Case on native's behaviour at this branch:

* **Native takes `%T`.** If extracted `c` is true, the successor agrees and the
  trajectory continues identically (everything not in `τ` is computed by the
  pre-existing, already-sound model). If extracted `c` is false, extracted
  halts loudly. Agree-or-halt. ∎
* **Native takes `%F`.** `%F` is `unreachable`-terminated and, by
  `_assert_dead_block_is_throw_skeleton` (`module_walk.jl:109`), is a
  throw-family skeleton — so **native throws**, i.e. native does not return a
  value. Excluded by the contract's hypothesis.

Induct along the extracted trajectory: at the first `br` where the two
trajectories could diverge, one of the two cases applies. Both successors in
`D` is also covered (halt). ∎

**Note on the "arbitrary garbage" strength.** The theorem does **not** assume
the admitted `ptrtoint` value is correct, meaningful, base-cancelling, or even
*deterministic*. It assumes only confinement. This is why it is the right
theorem for a value we provably cannot reason about.

### 1.4 Assumption ledger (klgz discipline)

| # | Assumption | Checkable? | Where |
|---|---|---|---|
| **A1** | (C0)–(C3) hold | **YES**, mechanically | `_foz5_confined_dead_bounds` |
| **A2** | the utzc pruner empties **exactly** `_vec_vm_dead_blocks(F)` and emits `IRBranch(:__unreachable__)` | **YES** — the predicate *calls the same helper*, so lockstep is by construction, satisfying the explicit COUPLING warning at `vector_vm_cfg.jl:44-49` | `module_walk.jl:426,455` |
| **A3** | `UnreachableHalt` is a loud halt (status `:error`), never a silent fall-through | **YES**, read + citable | `BennettVM/src/ir/unreachable_halt.jl`, `Interpreter.jl:1861-1885` |
| **A4** | `p`'s cell was actually materialised (registered **and** not suppressed) | **YES** — `suppressed_refs` is already a `_convert_instruction` kwarg (`instructions.jl:3625`), plumbed from `module_walk.jl:599`. **Zero new plumbing.** | (C0) |
| **A5** | the native program returns a value on the input under test | **NO** — and it is *not a hidden premise*: it is the explicit scope of the contract. Programs that throw natively have no oracle value to match. | the ADR amendment, §1.5 |
| **A6** | `and`/`or`/`xor` is the complete set of i1 combinators that may appear | **YES** — closed whitelist; anything else (incl. `select`, `zext`, `phi`, `call`, `store`, `ret`, `switch`) rejects | (C3) |

**A5 is the only non-checkable item, and it is a scope statement, not a leap of
faith.** That is the whole difference between (a′) and the A-foz5
named-assumption route.

### 1.5 The ADR amendment (drafted verbatim)

This weakening must be *written down*, not left implicit in a code comment. It
belongs as a new subsection of BennettVM `docs/adr/0017-closed-world-execution.md`
(the ADR that owns the `throw`/`unreachable` intrinsic boundary, Decision
item 4, and which the utzc pruner already cites as "ADR 0017 §4").

> ### Amendment (Bennett-foz5, 2026-08-__) — the CONFINED-VALUE contract
>
> **Context.** The `ptr_cells` closed-world extraction contract has so far been
> *oracle match*: every admitted value must provably equal what native
> computes. Julia's `@boundscheck` clusters under `--check-bounds=yes` compute a
> pointer difference across two halves of a **split** captured `MemoryRef` (one
> half in the closure environment, one in the GC-roots array), whose agreement
> is a cross-function property invisible to the extractor. Oracle match is
> therefore not provable for that value, and never will be extraction-locally.
>
> **Decision.** Introduce a *second*, strictly weaker admission contract,
> applicable **only** to values whose entire influence is a dead-throw branch
> condition:
>
> > **CONFINED-VALUE CONTRACT.** A value `v` may be admitted without an
> > oracle-match proof iff every path from `v` to an observable ends at the
> > condition operand of a conditional `br` at least one of whose successors is
> > a utzc-pruned `:__unreachable__` block, traversing only
> > `sub`(of two `ptrtoint`s) → `icmp` → i1-`and`/`or`/`xor`. For such `v` the
> > guarantee is: **for every input on which native returns a value, the
> > extracted program returns the same value or halts at the
> > `:__unreachable__` sink.**
>
> **Explicitly NOT weakened.** (i) Any value with a single non-conforming use is
> still under oracle match. (ii) The oracle-match proof retains **first
> refusal**: where the Bennett-583s base-cancellation proof applies, it is used,
> and the confined contract is never consulted (`||` short-circuit). (iii)
> Determinism (ADR 0018 §A) is untouched — the confined contract does not
> *rely* on determinism, and admits no new nondeterministic producer. The
> Bennett-klgz guard is at the 416r.13 unrecognised-JIT-global reject, fires on
> a `call`/GOT `load`, and is unreachable from this arm.
>
> **Disclosed residual.** A confined value that were nondeterministic could make
> the *halt itself* nondeterministic (halts on run 1, not run 2). This is a
> reproducibility, not a correctness, degradation, and it does not arise under
> ADR 0018 §A's deterministic arena.

### 1.6 Blast radius of the weakening — what else becomes admissible?

Precisely: **any 64-bit `ptrtoint`, of any pointer SSA, whose entire influence
is a dead-throw branch condition through `sub`→`icmp`→i1-algebra.** Enumerated:

* **(N-a) Cross-object pointer differences in a dead bounds check.** The target
  class. Newly admitted (`A_GREEN`). Cross-object differences that *escape*
  (`CROSS_MEM`, `D_SUBESC`) remain rejected — that is the exact predicate line.
* **(N-b) Cross-*tier* differences** (stack alloca ptr − arena ptr). Newly
  admissible in principle; no corpus witness. Under ADR 0018 §A both are
  deterministic Int64s, and even if they were not, the theorem caps the damage
  at "halt".
* **(N-c) Null / unmaterialised pointers.** Blocked by (C0) A4.
* **(N-d) The whole of jbko's residual risk (Bennett-sku0).** *Not* newly
  admitted, but worth flagging as the strongest corroboration of this route:
  the jbko arm comment at `instructions.jl:940-943` **already relies on this
  exact confinement argument informally** ("in Julia codegen these comparisons
  guard a throw block, which the Bennett-utzc pruner replaces with the
  `:__unreachable__` sink — so a wrong answer HALTS LOUDLY … (Rule 1 property
  of the surrounding shape)"), and Bennett-sku0's candidate fix **(b)** is
  verbatim my (C3): *"requiring the resulting i1 to reach a `br` through i1
  algebra only"*. Route (a′) therefore **builds the predicate sku0 needs**, and
  converts jbko's "property of the corpus shape, not something this gate
  enforces" into an enforceable one. That is a reuse win (CLAUDE.md §12), not a
  new liability. **(Out of foz5 scope — file as a follow-on.)**

### 1.7 Is the weakened invariant still what `verify_reversibility` needs?

**Yes, vacuously — and this should be pinned rather than argued.**
`verify_reversibility` is the *circuit-tier* invariant (all ancillae return to
zero). The entire arm sits inside the `&& ptr_cells` block, and `ptr_cells`
defaults to `false` on the circuit path, so the circuit lowering is
**byte-identical**. The invariant this amendment touches is the **BVM
oracle-match harness**, not `verify_reversibility`. Gate (7) below pins the
byte-identity.

At the BVM tier: `UnreachableHalt` lives in `src/history/Injective.jl:277`, i.e.
it is history-layer injective — a halt is a reversible event. Reversibility of
the admitted `IRBinOp(:or, …, 0, 64)` is inherited from 583s unchanged.

---

## 2. Mechanism

### 2.1 The one-line architectural claim

> **Admission becomes a disjunction of two proofs; the ENTRY becomes a
> disjunction of the old root test and the new use test; `_memdata_root` is not
> touched.**

```julia
# instructions.jl ~3825 — the 583s arm, ENTRY (edit: add the second disjunct)
if opc == LLVM.API.LLVMPtrToInt && src isa LLVM.Instruction &&
   (_memdata_root(src) !== nothing ||
    _foz5_confined_dead_bounds(inst, names, suppressed_refs))
    ... width check (reworded, §2.4) ...
    # ADMISSION (edit: add the second disjunct; `||` gives 583s FIRST REFUSAL)
    (_verify_memdata_bounds_cluster(inst, src) ||
     _foz5_confined_dead_bounds(inst, names, suppressed_refs)) || _ir_error(inst,
        "... EXISTING Bennett-583s / CW-D message, extended per §3.2 ...")
    return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
end
```

Everything else in the arm is unchanged. The arm **still always returns or
errors** — because entry-via-confinement implies admission-via-confinement (the
same pure predicate on the same `inst`). Therefore:

* **jbko pin disposition: KEEP, VERBATIM, UNMODIFIED.** `_memdata_root(src)
  === nothing` at `instructions.jl:3913` retains its exact current meaning
  (`_memdata_root` is unedited) and its exact current status: **redundant
  today, load-bearing the moment 583s grows a fall-through**. The a8nw note at
  `instructions.jl:3885-3889` stays **literally correct** and needs no edit.
  The scout's "Design B ⇒ delete the pin" hazard **does not arise**, because
  (a′) introduces no fall-through.
* **jbko corpus witness disposition: UNTOUCHED, and unstealable by
  construction.** See §2.3.
* **p06b arm disposition: UNTOUCHED.** Re-verified: `_memdata_root`'s only
  non-recursive call sites are `3826` and `3913`
  (`grep -n "_memdata_root" src/`), and I edit neither the function nor those
  call sites' semantics. `_p06b_cell_ptr_target_kind` / `_p06b_slot_key` /
  `_p06b_alias_group` are independent. The only p06b *contact* is a **read** of
  the already-plumbed `suppressed_refs` kwarg (§2.2 C0) — a strengthening, not
  a coupling.

### 2.2 The new predicate (one new helper block, `instructions.jl` ~857, i.e.
immediately after `_verify_memdata_bounds_cluster`)

```julia
const _FOZ5_I1ALG = (LLVM.API.LLVMAnd, LLVM.API.LLVMOr, LLVM.API.LLVMXor)

_foz5_is_i1(v)  # value_type isa IntegerType && width == 1

# (C3) — reuses `_vec_vm_dead_blocks`'s CRITERION, not a re-derivation:
# `bb ∈ dead_blocks ⟺ terminator(bb) is `unreachable``  (vector_vm_cfg.jl:12).
# Prefer calling `_vec_vm_dead_blocks(LLVM.parent(LLVM.parent(pt)))` once and
# threading the Set, to satisfy the COUPLING warning at vector_vm_cfg.jl:44-49
# by construction (a memo keyed on the Function ref keeps it O(blocks) once).
_foz5_i1_confined(v, dead, depth=0)::Bool
_foz5_confined_dead_bounds(pt, names, suppressed_refs)::Bool   # (C0)+(C1)+(C2)
```

Measured behaviour of exactly this predicate is the table in §0. Probe source:
`scratchpad/pA_conf.jl` lines 1-100 (the predicate is copy-pasteable; the
`_memdata_root` monkey-patch below it exists only to *simulate the entry
disjunct* without editing `_convert_instruction`, and is not part of the
proposal).

**Reuse note (CLAUDE.md §12).** `_foz5_i1_confined` is the generic
"i1 reaches only dead-edge branches" walker. Name it and document it as such,
not as a foz5-private helper — Bennett-sku0's fix (b) will call it verbatim.

### 2.3 Steal impossibility — a STRUCTURAL theorem, not an empirical one

> **Claim.** No `ptrtoint` can satisfy both the foz5 entry gate and the jbko
> entry gate. Ordering between the two arms is therefore **irrelevant**.
>
> **Proof.** foz5 (C1) requires `uses(pt) ≠ ∅` and *every* use to be a `sub`.
> jbko's `_jbko_identity_use_violation` (`instructions.jl:1028-1040`) requires
> every use to be an `icmp` with predicate `eq`/`ne`. `sub ≠ icmp`, so no
> non-empty use set satisfies both; and (C1) rejects the empty use set. ∎

This is *strictly stronger* than the property jbko documents today ("disjoint
**over the shapes `_memdata_root` recognises**", `instructions.jl:3870-3871`),
and it is what makes the bead's own phrasing of the widening safe to abandon.

Contrast, measured: the bead's phrasing (root = `{ptr,ptr}` field-0 GEP load +
`insertvalue`/`extractvalue` chasing) **does** steal — `p07_steal.jl`, re-run
this session:

```
[L84] %coercion = ptrtoint ptr %.ref.ptr_or_offset to i64
   VARIANT-B root = ROOTED -> %2 = load ptr, ptr %1, align 8  ==> 583s STEALS from jbko
   cluster ok = false
```

Under (a′), `O2_JBKO` (a fixture that is *simultaneously* S1-source-shaped and
jbko-use-shaped) extracts **identically on HEAD and patched**: `OK, 1
cell-identity` — and on the real corpus the marker table shows
`ConcurrencyViolation → false`, `Bennett-jbko → false`, i.e. the `%L84` witness
was never poached.

### 2.4 Emitted IR and arm placement

* **Emitted node:** `IRBinOp(dest, :or, SSAOperand(src), ConstOperand(0), 64)`
  — the identical 583s cell identity. **No new `IRInst` kind, no new
  intrinsic.** Measured inventory of the fully-extracted `_growend!` closure
  (`pA_inv.jl`, 52 blocks): `IRBinOp 205, IRBranch 51, IRCall 3, IRCast 1,
  IRExtractValue 7, IRICmp 91, IRInsertBits 2, IRInsertValue 12, IRLoad 36,
  IRPhi 5, IRPtrOffset 34, IRRet 1, IRSelect 69, IRStore 4, IRVarGEP 3` —
  **byte-identical to the scout's `p08c` inventory**. ⇒ **zero BennettVM `src/`
  changes.**
* **Arm placement:** unchanged. Still after iwo9, before jbko. The steal
  theorem (§2.3) means placement is no longer load-bearing, but *do not move
  it* — the current order is what the four advanced markers and gate (O) pin.
* **Width message:** the existing width reject (`instructions.jl:3830-3836`)
  says "ptrtoint of a **GenericMemory .data base** at a NON-64-bit width". Under
  the new entry disjunct a *non*-memdata source can reach it, making the wording
  a false assertion (the a8nw review-D5 defect class, which jbko already fixed
  for itself). **Reword to a source-agnostic statement** while keeping the
  substrings gate (3) pins: `"583s"` and `"width"`-or-`"64"`
  (`test_583s_memdata_bounds.jl:255-256`). Suggested: *"ptrtoint under
  ptr_cells at a NON-64-bit width (src=… dst=…) — genuine pointer arithmetic,
  not a cell identity (Bennett-583s / CW-D; Bennett-foz5)."*

---

## 3. Failure modes and message territory

### 3.1 Grep-verified inventory of tests pinning 583s / jbko / p06b substrings

| File | Pin | Predicted |
|---|---|---|
| `test_583s_memdata_bounds.jl` (1)-(7) | the whole contract | **GREEN, ZERO EDITS.** Measured: `CLUSTER_OK` OK/2, `CROSS_MEM` ERR-583s, `NON_MEMDATA` ERR-iwo9, `ESCAPE_HASH` ERR-583s, `WIDTH_I32` ERR-583s (substrings `"583s"` + `"width"` preserved by the §2.4 reword). Gate (6) `Base.setindex!` is a same-root cluster ⇒ 583s first refusal ⇒ unchanged. |
| `test_jbko_ptr_identity_icmp.jl` (O) `MEMDATA_ICMP`, (C), (L) | jbko/583s boundary | **GREEN, ZERO EDITS.** `_memdata_root` unedited ⇒ gate (O)'s "a memdata `.data` source stays on the 583s arm" is *definitionally* preserved. Its meaning does **not** need restating (contrast the scout's Design B). |
| `test_p06b_aggregate_store.jl` (k) | wall-7 marker | **RED — advance, §3.4** |
| `test_vau9_variable_memmove.jl` (g) | wall-7 marker | **RED — advance** |
| `test_40ys_instanceless_callees.jl:497-533` | wall-7 marker | **RED — advance** |
| `test_7wsz_ptr_sret_fields.jl:522-542` | wall-7 marker | **RED — advance** |
| `test_59zi_sret_call_memcpy.jl:350` (`!occursin("583s / CW-D")`) | fdict/`setindex!` path | **GREEN.** That path's cluster is same-root ⇒ 583s first refusal ⇒ no 583s error. Re-run to confirm. |
| `test_3vf2_dead_use_global_load.jl:37,279` | comments naming `_growend!` | none |
| `test_beaw_null_ptr.jl:204`, `test_416r17_…:134`, `test_6bu3…:233`, `test_yd4f…:266` | comments / `gc_alloc_obj` disjuncts | none |
| `runtests.jl:550-562, 634-635, 658` | registration commentary | **update the wall-7/wall-8 note** (prose only) |

### 3.2 The 583s reject message

Keep the existing text (gate (5) pins `"583s"` and
`"bounds"|"escap"|"base-"`), and **append** the second-proof clause so the
message describes both refusals:

> "… (a use is not a same-root sub(ptrtoint,ptrtoint); e.g. inttoptr-deref,
> store, hash, or a cross-allocation difference), **AND its result is not
> CONFINED to a dead-throw bounds check either — a use escapes the
> `sub`→`icmp`→i1-algebra→`br`-with-an-unreachable-edge chain (Bennett-foz5).**
> …"

Measured: `CROSS_MEM` still reports through this path with `st === :err` and the
`Bennett-583s` tag. **No `test_583s` assertion is edited.**

### 3.3 The one message-territory *shift* (disclose it; do not paper over it)

`C_ESCAPE` (the S1 element-side `ptrtoint` additionally feeds an `add`):
HEAD reports `%pb` under `Bennett-583s`; route (a′) reports `%pe` under
`Bennett-iwo9`. **Cause:** `%pb` is *legitimately* confined (its own sub→icmp→br
chain is clean) and is now admitted, so the *first failing instruction* moves to
`%pe`, which enters neither arm (its uses include an `add`, so foz5 (C1) is
false; `_memdata_root` is `nothing`; jbko's use gate rejects) and lands on the
generic iwo9 reject.

This is a **reporting-order** effect, not a contract change — the program still
rejects loudly. But it means a foz5-shaped near-miss can surface under an
iwo9-named message. Two options for the implementer:

* **(i) Accept and pin.** Write gate (C) as `st === :err` plus
  `occursin("Bennett-iwo9", msg) || occursin("Bennett-583s", msg)` with a
  comment citing this section. Zero code.
* **(ii) Add a foz5 near-miss diagnostic** (the jbko disjunctive-entry idiom,
  `instructions.jl:3899-3906`): extend the entry with a weak
  `_foz5_entry_shape(inst)` (= (C1) alone) so a ptrtoint whose uses are all
  `sub`s but whose (C2)/(C3) fail gets a foz5-named message instead of the 583s
  one. **I recommend (i)** — (ii) widens the entry surface for a diagnostic-only
  gain, and every 3+1 lesson in this file says keep the entry narrow.

### 3.4 Marker advances — measured, not forecast

Real gated path under route (a′) (`pA_corpus.jl`). Wall-8 message verbatim
prefix: *"extraction FAILED for callee `_pushfoz5#…` — ir_extract.jl: store in
@julia__pushfoz5_…:%top: `store { ptr, ptr } %memory_ref, ptr %"new::Array"` —
aggregate store target is not a CERTIFIED cell pointer — it is a
`julia.gc_alloc_obj` call …"*. Marker table:

| substring | present? | consequence for the 4 marker files |
|---|---|---|
| `Bennett-583s` | **false** | the wall-7 positive disjunction FLIPS ⇒ **retarget** |
| `base-cancelling` | **false** | ditto — and it becomes the **new load-bearing negative** |
| `Bennett-foz5` | false | do **not** add it to the new positive |
| `_growend!` | **false** | `@test occursin("_growend!", msg)` FLIPS ⇒ **drop** |
| `Bennett-p06b` | **true** | `@test !occursin("Bennett-p06b", msg)` FLIPS ⇒ **narrow, do not delete** |
| `gc_alloc_obj` / `BYTE-granular` / `9n3y` | **true** | the new positive |
| `granularity` | **false** (the message says "granularit**ies**") | do not use it |
| `Bennett-iwo9`, `type-tag`, `memmove`, `not yet lowered…`, `Bennett-lgzx`, `store of non-integer type`, `ptrtoint`, `ConcurrencyViolation` | **false** | every existing load-bearing negative stays **GREEN, unedited** |

**The narrowing (all four files).** Preserve the negative's exact intent —
"p06b's own rejects did NOT fire on the `%L93` `MemoryRef` write-back this gate
is about" — while tolerating the *different* p06b reject at wall 8:

```julia
# NARROWED (Bennett-foz5): p06b's reject DOES now fire — but on the ROOT
# body's `julia.gc_alloc_obj`-backed store (wall 8), NOT on the %L93
# MemoryRef write-back this gate is about. Pin the DISCRIMINATOR so a
# re-rejection of %L93 under a new p06b name still turns this red.
@test !occursin("Bennett-p06b", msg) || occursin("gc_alloc_obj", msg)
```

**The retarget (all four files).**

```julia
# POSITIVE: the NEW wall is the ROOT body's byte-granular aggregate-store
# target refusal (Bennett-p06b P4b / CW-D4 / bennettvm-9n3y) — the first
# wall in this chain that is NOT in a callee and NOT an extraction-shape
# recognition wall. Bead: <wall-8 bead id>.
@test occursin("gc_alloc_obj", msg) || occursin("BYTE-granular", msg) ||
      occursin("9n3y", msg)
# NEW LOAD-BEARING NEGATIVE: wall 7 (the %idxend41 memdata bounds cluster)
# is CLEARED by Bennett-foz5.
@test !occursin("base-cancelling", msg)
@test !occursin("Bennett-583s", msg)
# `occursin("_growend!", msg)` is DROPPED: the wall moved to the ROOT body
# (`_pushNNNN`), so the closure name is legitimately absent. Do not replace
# it with `occursin("_push")` — which body of the set fails first is
# registration/iteration order, not a contract (the existing disjunction
# rationale, applied to the positive's subject too).
```

Note `test_p06b_aggregate_store.jl`'s `_P06B_FORBIDDEN` tuple
(`"store of non-integer type"`, `"Bennett-lgzx"`, `"U114"`, `"ptrtoint"`,
`"memmove"`, `"Bennett-iwo9"`, `"not yet lowered to reversible gates"`,
`"sret struct field"`, `"Bennett-dv1z"`) is **all-false** against the wall-8
message — if the implementer wants a single reusable negative bundle for gate
(k), that tuple already works verbatim.

---

## 4. Test plan

New file **`test/test_foz5_confined_bounds.jl`**, registered in `runtests.jl`
**immediately after** `test_583s_memdata_bounds.jl` (line ~562). Helper idiom:
`_extract_ll` / `_all_insts` / `_memdata_or` copied from
`test_583s_memdata_bounds.jl:153-190`. Every fixture carries
`target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"` (the
`test_7wsz` / `test_59zi` / `test_416r16` idiom) because S1 is byte-offset-GEP
shaped. All per-file green claims under
`julia --project --check-bounds=yes test/test_foz5_confined_bounds.jl`.

Fixture sources are ready-to-lift from `scratchpad/pA_fixtures.jl`.

**Positive / negative gates** (all eleven already executed — §0 table):

* **(A) GREEN — the S1 corpus shape.** Two structurally disjoint roots (env
  arg `+56` load, roots arg `+16` load → `{i64,ptr}` field-1 load), `sub` →
  `icmp ult` → `xor`/`and` → `br` with an `unreachable` false edge carrying a
  `jl_bounds_error_int` call. Assert `:ok`, **and** that *both* ptrtoints
  produce the `IRBinOp(:or, …, 0, 64)` cell identity (`_memdata_or`) — Rule 4:
  no-throw ≠ pass. Measured: OK, 2 identities.
* **(B) RED — no dead-throw sink.** (A) with the false edge `ret`ing. Pins
  premise (C3); **this is the gate that proves the confinement is doing the
  work.** Measured: ERR.
* **(C) RED — ptrtoint escape.** The element-side ptrtoint also feeds an `add`.
  Assert `:err` + `occursin("Bennett-iwo9") || occursin("Bennett-583s")`, with
  the §3.3 comment. Measured: ERR.
* **(D) RED — sub-result escape.** The `sub` result is returned on the live
  edge. **This is the predicate line that keeps CROSS_MEM red** — state that in
  the comment. Measured: ERR.
* **(E) RED — i1 feeds a `select`.** Value leak. Measured: ERR.
* **(F) RED — i1 `zext`ed.** Value leak. Measured: ERR.
* **(G) RED — genuine cross-object escape.** Two different env pointers, sub
  returned. (Structurally = CROSS_MEM with the S1 root shape.) Measured pattern
  identical to (D).
* **(H) BYTE-IDENTITY — `ptr_cells=false`.** Fixture (A) with `cells=false`
  must still fail loud (the arm does not exist). Pins §1.7 / the
  `verify_reversibility` non-interaction.

**Inertness gates (NO EDITS PERMITTED to the pinned files):**

* **(I) INERT — `test_583s_memdata_bounds.jl` re-run in full, unchanged.**
  Gate (5) CROSS_MEM and gate (4) NON_MEMDATA in particular. *If any assertion
  in that file has to be edited, the widening is too broad and this design is
  wrong.* Measured: all four re-checked fixtures byte-identical to HEAD.
* **(J) INERT — `test_jbko_ptr_identity_icmp.jl` re-run in full, unchanged.**

**Ordering / steal-prevention gates (mandatory):**

* **(O1)** `test_jbko_ptr_identity_icmp.jl` gate (O) `MEMDATA_ICMP` green,
  unedited.
* **(O2) NEW — the steal pin, as a UNIT test of the theorem.** Fixture
  `O2_JBKO`: source is S1-shaped (`load ptr` of a constant i8 byte-GEP off an
  argument), sole use is `icmp eq` against an i64 argument. Assert `:ok` **and
  exactly 1 cell identity**, with a comment recording the §2.3 structural
  argument *by name*: "foz5 requires every use to be a `sub`; jbko requires
  every use to be `icmp eq/ne`; the sets are disjoint, so arm ORDER is not
  load-bearing here." Measured: OK/1 on both HEAD and patched.
* **(O3) NEW — the corpus anti-steal.** On the real gated path assert
  `!occursin("Bennett-jbko", msg)` and
  `!occursin("ConcurrencyViolation", msg)`. Measured: both false ⇒ green.
* **(O4)** *Not needed.* Route (a′) introduces no fall-through, so the jbko
  `_memdata_root(src) === nothing` pin stays load-bearing-in-waiting and
  unedited. **Instead**, add a one-line unit assertion that the pin is still
  present and still redundant — i.e. re-run `test_jbko` gate (O) — plus a
  comment in `instructions.jl:3885-3889` updating "which is exactly what a ROOT
  extension would introduce (relevant to Bennett-foz5)" to record that foz5
  landed **without** a root extension and the note therefore still holds.

**Marker advances (4 files, per §3.4):** `test_p06b_aggregate_store.jl` (k),
`test_vau9_variable_memmove.jl` (g), `test_40ys_instanceless_callees.jl`
(~497-533), `test_7wsz_ptr_sret_fields.jl` (~522-542).

**BVM E2E:** **not required.** `pA_inv.jl` shows the widened `_growend!`
extraction uses only pre-existing `IRInst` forms, byte-identical to the scout's
`p08c` inventory. The Bennett-side node-shape assertion in gate (A) plus the
corpus marker table is sufficient evidence. A BVM E2E of the whole `push!` chain
would still wall at wall 8 in the root body and therefore proves nothing extra.
*Do* add the BVM-side citation (`unreachable_halt.jl`,
`Interpreter.jl:1861-1885`) to the arm comment as the A3 receipt.

**Suite:** full `Pkg.test()` before the commit (Rule 8 / §14 — no CI).

---

## 5. Risks

| # | Risk | Severity | Probe status | Mitigation |
|---|---|---|---|---|
| R1 | **The `dead_blocks` coupling drifts.** If anyone widens `_vec_vm_dead_blocks` (e.g. to `llvm.trap` blocks) or makes the pruner KEEP a block still in the set, premise (C3)→A2 breaks *silently*. The explicit warning is already at `vector_vm_cfg.jl:44-49`. | **HIGH** | structural | **Call `_vec_vm_dead_blocks` itself** rather than re-deriving "terminator is unreachable". Then the two are the same function and cannot drift. Add a cross-reference comment at `vector_vm_cfg.jl:44` naming foz5 as a third consumer. |
| R2 | **`suppressed_refs` gap.** A `load ptr` whose ref is registered but suppressed (sret write-back / consumed-sret) would yield an SSA operand for a cell never materialised — the p06b D1b defect class. **This gap exists at HEAD in the 583s arm too**; foz5 widens the exposure. | MED | not corpus-witnessed | (C0) consults `suppressed_refs`, already a `_convert_instruction` kwarg (`instructions.jl:3625`). Zero plumbing. **Consider filing a companion bead to add the same check to the HEAD 583s entry** — out of foz5 scope, but the reviewer should decide. |
| R3 | **Shape drift in the i1 algebra.** LLVM emits `select i1 %a, i1 %b, i1 false` instead of `and i1 %a, %b` in some pipelines. (C3) would reject ⇒ **loud wall, not a miscompile** — but the corpus would regress. | MED | corpus green at `optimize=false` (Rule 5 mandate) | Fails closed. Widening (C3) to `select` **with all three operands i1** is sound under the same proof (it is i1 algebra) but must be a separate, witnessed change — do not pre-emptively add it. |
| R4 | **`switch` on a confined value.** Not in the whitelist ⇒ reject. If a future Julia lowers a bounds cluster to a `switch`, we wall. | LOW | none | Fails closed. Note it in the helper docstring. |
| R5 | **Nondeterministic halt** (§1.5 disclosed residual). | LOW | none under ADR 0018 §A | Disclosed in the ADR amendment; not a correctness issue. |
| R6 | **A5 misread as a proof.** A future agent reads "oracle match or loud halt" as "oracle match". | MED | — | The contract is written into the ADR *and* must appear verbatim in the arm comment. The gate (B) test is the executable statement of it. |
| R7 | **Message attribution shift** (§3.3). | LOW | measured (`C_ESCAPE`) | Pin it in gate (C) with a comment. Do not "fix" it by widening the entry. |
| R8 | **Reviewer scope creep into Bennett-sku0.** (N-d) makes it tempting to fix jbko's residual in the same diff. | MED | — | **Do not.** File a follow-on bead pointing `_foz5_i1_confined` at sku0's fix (b). One bead per commit. |

---

## 6. Diff shape

**Bennett.jl `src/` — one file.**

* `src/extract/instructions.jl`
  * **+ new helper block** after `_verify_memdata_bounds_cluster` (~line 856):
    `_FOZ5_I1ALG`, `_foz5_is_i1`, `_foz5_i1_confined`,
    `_foz5_confined_dead_bounds`, plus the CONFINED-VALUE contract statement
    and the A1-A6 ledger as the block's header comment (the 583s/jbko house
    style). ~120 LOC, mostly comment.
  * **~ entry condition** at 3825-3826: add the `|| _foz5_confined_dead_bounds(…)`
    disjunct.
  * **~ admission** at 3837: add the `|| _foz5_confined_dead_bounds(…)` disjunct
    (**after** `_verify_memdata_bounds_cluster`, so 583s keeps first refusal).
  * **~ width message** at 3830-3836: source-agnostic reword (§2.4), keeping
    `"583s"` + `"width"`.
  * **~ cluster-reject message** at 3837-3844: append the second-proof clause
    (§3.2), keeping `"583s"` + `"base-"`.
  * **~ comment** at 3885-3889: record that foz5 landed *without* a root
    extension, so the jbko pin note still holds.
  * **UNCHANGED:** `_memdata_root` (816-838), `_verify_memdata_bounds_cluster`
    (840-855), the jbko arm entry (3913) and body, arm ordering.
* `src/extract/vector_vm_cfg.jl` — comment only: add foz5 to the COUPLING
  note's consumer list (~line 44).

**Bennett.jl `test/` — five files.**

* **+ `test/test_foz5_confined_bounds.jl`** (gates A-H, O2, O3) + one
  `runfile` line and a registration comment in `runtests.jl` (~562).
* **~ 4 marker files** (`test_p06b_aggregate_store.jl` (k),
  `test_vau9_variable_memmove.jl` (g), `test_40ys_instanceless_callees.jl`,
  `test_7wsz_ptr_sret_fields.jl`): 3 assertion edits + 2 additions each,
  per §3.4.
* **~ `runtests.jl`** prose at 550-562 / 634-635 / 658 (wall-7 → wall-8 note).

**BennettVM.jl — documentation only.**

* `docs/adr/0017-closed-world-execution.md`: **+ the Amendment of §1.5.**
* **Zero `src/` changes** (measured, `pA_inv.jl`).

**Beads.**

* Correct the `Bennett-foz5` description (mechanism and root shape are both
  wrong in it — the scout's item 3).
* **File wall 8:** p06b `julia.gc_alloc_obj` byte-granular aggregate-store
  target, **root body**, CW-D4 / `bennettvm-9n3y`. First wall in this chain in
  the root body and the first on the BVM cell-granularity boundary rather than
  on extraction shape recognition.
* **File the sku0 follow-on:** point Bennett-sku0's candidate fix (b) at
  `_foz5_i1_confined` (§1.6 N-d).
* Worklog entry in the top `worklog/NNN_*.md` chunk (check
  `ls worklog/ | sort -r | head -1`), capturing: the steal theorem, the
  CROSS_MEM-preserving predicate line, the `granularit**ies**` substring trap,
  and the C_ESCAPE attribution shift.
