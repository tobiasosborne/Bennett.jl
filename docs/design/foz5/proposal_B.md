# Bennett-foz5 — PROPOSER B

**Bead:** `Bennett-foz5` (P1) — xkl frontier wall 7.
**HEAD:** `ebcebe2`. **Mode:** full 3+1, proposer B (blind of A).
**Scout re-verified, not re-derived:** `docs/design/foz5_scout.md`.
**Probes (mine, new):** `scratchpad/pB_neutral.jl`, `scratchpad/pB_e2e.jl`.
**Probes (scout's, re-run at HEAD):** `p01_wall.jl`, `p06_next2.jl`, `p07_steal.jl`.
No `src/` or `test/` change was made. Every claim below is probe- or grep-backed
and the evidence is cited inline.

---

## 0. Scout re-verification (what I confirmed before designing)

| Scout claim | Status | Evidence |
|---|---|---|
| Wall reproduces verbatim at HEAD, 583s message, `%idxend41` | **CONFIRMED** | `p01_wall.jl` re-run under `--check-bounds=yes`; SSA number was `%94` this run vs `%98` in the dump — **SSA numbering drifts between processes**, so no design may pin it (Rule 5) |
| `%98`/`%99`/`%100` each have exactly ONE use; `%100`'s sole use is the `icmp ult` | **CONFIRMED** | `grep -n '%100\b' growend.ll` → def + `icmp` only; same for `%98`, `%99` |
| `%93 insertvalue` is DEAD | **CONFIRMED** | `grep -n '%93\b' growend.ll` → def line only |
| `oob57` is `ijl_bounds_error_int` + `unreachable`, utzc-pruned | **CONFIRMED** | `growend.ll:349-362`; `_vec_vm_dead_blocks` returns **16** dead blocks for this function (`pB_neutral.jl`) |
| `_memdata_root` has exactly two live call sites (3826, 3913); **no p06b coupling** | **CONFIRMED** | `grep -rn "_memdata_root" src/` — 3826 and 3913 are the only non-comment call sites |
| The bead's `{ptr,ptr}` field-0 phrasing STEALS jbko's `%L84` witness | **CONFIRMED** | `p07_steal.jl` re-run: `VARIANT-B root = ROOTED … ==> 583s STEALS from jbko`, `cluster ok = false` |
| Wall 8 = root body `_pushfoz5`, p06b `gc_alloc_obj` BYTE-granular store refusal | **CONFIRMED** | `p06_next2.jl` re-run, **and independently by my own `pB_e2e.jl`** (different admission mechanism, same wall) |
| The 583s arm always returns or errors (no fall-through today) | **CONFIRMED** | `instructions.jl:3825-3845` |
| Both ptrtoint arms sit inside `if (opc==PtrToInt \|\| opc==IntToPtr) && ptr_cells` | **CONFIRMED** | `instructions.jl:3785` — circuit path byte-identical by construction |

**One scout framing I depart from.** The scout presents the choice as
(a) dead-throw confinement of a *cell-identity* emission vs (b) whole-cluster
elision. My design is (b), but in a form neither the scout nor the bead
considers: **keep the cluster, neutralise the operands.** It needs no shape
recognition of the surrounding GEP/mul chain (so it pins far less than "cluster
elision"), it needs no widening of `_memdata_root` at all (so the steal is
*structurally impossible*, not merely avoided), and — the decisive point — it
admits a **theorem** rather than an assumption.

---

## 1. Route decision — (b), in the form "monotone zero-cell neutralisation"

### 1.1 The decision in one line

> When a `ptrtoint` fails 583s's base-cancellation proof but is *confined* to an
> unsigned bounds compare whose false edge is a utzc-pruned halt sink, emit the
> **zero cell** — `IRBinOp(dest, :add, iconst(0), iconst(0), 64)` — instead of
> the cell identity. The guard is then computed from zeros, which makes it
> **provably weaker** than the guard it replaces, so the extraction can never
> halt where native does not.

583s's proof stays the **preferred** path and is untouched. Neutralisation is a
strictly-second fallback that only engages when the whole `sub`-component is not
root-equal.

### 1.2 Why not route (a) — dead-throw confinement of a cell identity

Route (a) admits the two `ptrtoint`s as cell identities and argues the resulting
`sub` is harmless because it only steers a guard whose false edge halts. It needs
the scout's **A-foz5 / (INV)**: that in the VM, `D = M.data + 8·i` for the
captured ref. That assumption is:

* **not checkable at extraction** (cross-argument, cross-function — scout §4.2,
  re-verified: `%86 = gep i8 %"#self#…", 56` and `%memoryref_mem44 = load (gep i8
  %".roots.#self#", 16)` share no SSA edge);
* **non-deterministic in its manifestation** — if it fails, the difference of two
  unrelated *arena* offsets is a small-magnitude integer (unlike a real 64-bit
  address difference), so `icmp ult` can go either way depending on allocation
  order. The failure presents as a **flaky VM halt on a correct program**, in a
  build the test suite calls green;
* **untestable** — no assertion can pin "the guard was faithful", because the
  answer depends on `ARENA_BASE` and allocation history.

Route (a)'s advertised guarantee is also weaker than it first reads. The honest
statement is *two*-sided, not one-sided:

* native does not throw, VM guard false → **spurious halt** (route (a) only);
* native throws, VM guard true → **missed throw** (route (a) *and* route (b)).

So **route (b) has a strict subset of route (a)'s failure directions.** Route (a)
buys back "catches the throw when (INV) happens to hold" — a benefit that is not
part of any guarantee and cannot be asserted in a test.

### 1.3 Why not route (c) — closed-world cross-function certification

I took this seriously because the pairing fact *is* in the closed world: the
closure environment is built by `_growend!`, which is itself extracted. It fails
on three independent grounds:

1. **The correspondence is codegen-assigned, not derivable.** Certifying the pair
   means matching *closure-env byte offset 56* to *GC-roots-array slot 16*. The
   roots array is materialised by Julia's calling convention; nothing in the IR
   states that slot 16 holds field 1 of the same `MemoryRef` whose field 0 sits at
   +56. Pinning that mapping is precisely the Rule-5-forbidden class. It would
   replace an unchecked *semantic* assumption with an unchecked *syntactic* one —
   worse, because syntactic assumptions rot silently across LLVM/Julia versions.
2. **`transitive_callees` walks the wrong direction.** `extract/callgraph.jl`
   enumerates callees; the pairing witness lives in the *caller*. There is no
   caller-side analysis in the extractor, and building one is a new subsystem.
3. **Even a perfect route (c) is unnecessary under (b).** (b) discharges the
   obligation without the fact.

Rejected. Worth one sentence in the worklog so the next agent does not re-derive
it.

### 1.4 The soundness argument (klgz discipline)

Fix an LLVM function `F` extracted under `ptr_cells`. Let `pt` be a `ptrtoint`
admitted by the predicate of §2.2, with

* `P` = the `ptrtoint`s in `pt`'s `sub`-connected component,
* `S` = the `sub`s joining them,
* `I` = the `icmp`s consuming `S`,
* `C` = the i1 closure of `I` under `and`/`or`.

Write `σ_nat` for the native execution and `σ_vm` for the extracted program's
execution on BennettVM, on the same input.

**Lemma 1 (operand zeroing).** In `σ_vm`, every `p ∈ P` evaluates to `0`, hence
every `s ∈ S` evaluates to `0 − 0 = 0`.
*Checkable:* yes — this is what the emission does, and it is the a70z
fold-to-zero shape BVM already ingests (`instructions.jl:3423`; BVM
`ingest_body.jl:95-110`).

**Lemma 2 (the bound is faithful).** For each `c ∈ I` of the form `s <u X` (or
its mirror), `X` contains no `ptrtoint` in its transitive operand closure, so
`X_vm = X_nat` by structural induction on the faithfully-modelled integer
operations.
*Checkable:* yes — predicate condition **N4b**, a bounded operand walk.

**Theorem (one-sidedness).** For every `c ∈ I`: `c_nat = true ⟹ c_vm = true`.
*Proof.* `c_nat = true` means `s_nat <u X_nat`. Unsigned comparison gives
`s_nat ≥u 0`, so `X_nat >u 0`. By Lemma 1 `s_vm = 0`; by Lemma 2 `X_vm = X_nat >u 0`;
hence `c_vm = (0 <u X_vm) = true`. For the `≤u` form, `0 ≤u X` holds
unconditionally. ∎

**Corollary (no spurious halt).** `and` and `or` are monotone in the boolean
order and `xor` is excluded from `C` (predicate condition **N5**). Therefore
`v_vm ≥ v_nat` for every `v ∈ C`. Every conditional `br i1 v, T, F` reached from
`C` has `F ∈ dead_blocks` (**N5b**), i.e. the `:__unreachable__` halt sink is the
*false* edge. `v_nat = true ⟹ v_vm = true ⟹ the VM does not take F`. **The
extracted program never halts at a neutralised guard unless the native program
also throws there.** ∎

**The residual, stated exactly.** `v_nat = false ⟹ v_vm` may be true: the VM may
*continue* where native throws. The neutralised guard is not vacuous — it still
fires when `X = 0` (an empty `Memory`, in the corpus) — but it is weaker. This
is the **entire** behavioural delta; nothing else in the program changes,
because by **N1–N5** no value in `P ∪ S ∪ I ∪ C` reaches a `phi`, `select`,
`store`, `ret`, call argument, or address computation.

**Assumption ledger.**

| # | Assumption | Checkable? | Checked by |
|---|---|---|---|
| A1 | Confinement N1–N3 (uses are `sub`s of `ptrtoint`s) | yes, syntactic | `_foz5_sub_component` |
| A2 | Compare polarity N4a (`sub` on the lesser side, unsigned) | yes, syntactic | `_foz5_confined_compare` |
| A3 | Bound `X` is address-free N4b | yes, bounded operand walk | `_foz5_no_ptrtoint_below` |
| A4 | i1 algebra is monotone and lands on a pruned false edge N5 | yes, syntactic + `dead_blocks` | `_foz5_monotone_to_dead_edge` |
| A5 | BVM evaluates `IRBinOp(:add, 0, 0, 64)` to `0` | yes, by precedent | a70z `always0` path, `instructions.jl:3423`; BVM `test_tl1l_a70z_shapes.jl` |
| **A6** | **POLICY: the project accepts that a neutralised guard no longer detects the native throw** | **no — it is a declared scope reduction, not a factual claim** | ADR amendment §1.6 |

**A6 is the only unchecked item, and it is a policy, not a fact about the
program.** Route (a) needs A6 *plus* the unchecked factual (INV). That asymmetry
is the decision.

### 1.5 Reconciling with Bennett-lbot (the strongest objection)

`instructions.jl:3417` already rules, in a shipped message, that

> "A placeholder-0 would route away from the throw the native code takes and is
> UNSOUND. (Bennett-lbot)"

That is the same shape as my proposal and must be answered, not skirted. Three
named differences:

1. **What is declared zero.** lbot would have fabricated the **guard bit** — a
   value with a well-defined source-level meaning ("did this multiply
   overflow?"), computable in principle from in-model `i64` cells, merely
   unimplemented. foz5 declares the **address operands** zero — values that have
   *no* source-level meaning in the VM's own address space (ADR 0018 §A: the VM
   owns its segment bases) — and still computes the bit from them.
2. **Direction.** lbot's placeholder carries no theorem; `bit := 0` could route
   either way relative to native for a given input. foz5 carries the §1.4
   monotonicity theorem: the guard is provably *weaker*, so exactly one direction
   of divergence exists and it is named.
3. **What the continuation does.** After lbot's missed throw, the program
   allocates a memory of a **wrapped, wrong size** and writes into it —
   corruption of modelled data on a *valid* input. After foz5's missed throw, the
   program continues with the same faithfully-computed `IRPtrOffset` element
   pointer it would have used anyway (`%memoryref_data_byteoffset50` is live and
   in-model, `growend.ll:335,364`); the only inputs affected are ones on which
   the source program itself has no value.

If the orchestrator rejects this distinction, the honest fallback is **status
quo: stay walled at wall 7 forever**, because scout §4.2 (re-verified) shows no
extraction-local proof exists. That cost should be stated explicitly in the
review rather than papered over.

### 1.6 ADR amendment (exact text to land in
`BennettVM.jl/docs/adr/0017-closed-world-execution.md`, new subsection after the
§4 throw/`unreachable` clause; lead sign-off required — cross-repo doc change)

> ### 4a. Unmodellable guards: monotone neutralisation (Bennett-foz5)
>
> The keep-branch dead-block pruner (§4 / Bennett-utzc) leaves the predecessor's
> conditional branch into a pruned `unreachable` block intact, so that a guard
> which fires at runtime reaches BennettVM's `:__unreachable__` halt sink — a
> faithful reversible throw. **That discipline presumes the guard's condition is
> itself faithfully computed from in-model values.**
>
> A guard whose condition depends on an **inter-allocation address difference**
> is not so computable. The VM owns a deterministic virtual address space
> (ADR 0018 §A) whose segment bases differ from the host's, so the difference of
> two pointers *not provably into the same allocation* is not a source-level
> property. Extraction has three options: reject (status quo), compute it anyway
> from the VM's own cells (unsound in an address-dependent, untestable way), or
> **neutralise**.
>
> **Decision.** Under the closed-world `ptr_cells` gate an extraction MAY
> neutralise such a guard by materialising the offending `ptrtoint` results as
> the ZERO cell, provided a syntactic predicate establishes all of:
> (i) every use of the coerced value is a `sub` of two `ptrtoint`s;
> (ii) every use of each such `sub` is an UNSIGNED compare with the `sub` on the
> lesser side (`sub <u X` / `sub ≤u X`);
> (iii) the compared bound `X` has no `ptrtoint` in its transitive operand
> closure;
> (iv) every use of each such compare is monotone i1 algebra (`and`/`or` only —
> **never `xor`**) terminating in conditional branches whose FALSE edge is a
> §4-pruned dead block.
>
> Under (i)–(iv) the neutralised guard is provably weaker than the guard it
> replaces (`0 <u X` is implied by `s <u X`), and boolean monotonicity lifts this
> to every branch condition derived from it. Consequently:
>
> * **No new halt is ever introduced.** A neutralising extraction halts at
>   `:__unreachable__` on a strict subset of the inputs on which a faithful
>   extraction would.
> * **The declared cost:** a neutralised guard no longer detects the native
>   throw. §4's "faithful reversible throw" holds unchanged for *proved* guards
>   (Bennett-583s base-cancelling clusters are unaffected) and is relaxed to
>   **"no spurious halt; the throw may be missed"** for neutralised ones.
> * Neutralisation is a **fallback, never a preference.** A guard a proof admits
>   is emitted faithfully; the predicate declines whenever the whole
>   `sub`-component is root-equal.
> * A guard satisfying neither the proof nor (i)–(iv) stays **rejected** (Rule 1)
>   with its existing message. Extraction never fabricates a guard *bit* — cf.
>   Bennett-lbot; here the bit is still computed, from operands declared zero.

---

## 2. Mechanism

### 2.1 Arm placement (three edits, one file)

`src/extract/instructions.jl`, all inside the existing
`if (opc == PtrToInt || opc == IntToPtr) && ptr_cells` block (`:3785`):

```
  iwo9 type-tag arm                     [~3790-3810]  UNCHANGED
  583s arm                              [~3825-3845]  ONE inserted branch
      root test                                       unchanged
      width guard                                     unchanged, same message
      if _verify_memdata_bounds_cluster(...)          unchanged emission
          return IRBinOp(dest, :or, src, 0, 64)
      end
+     if _foz5_neutralisable(inst, dead_blocks)       NEW  (proof failed → try neutralise)
+         return IRBinOp(dest, :add, iconst(0), iconst(0), 64)
+     end
      _ir_error(inst, <583s message>)                 unchanged, verbatim
+ foz5 arm                              [NEW, ~12 LOC, between 583s and jbko]
+     if opc == PtrToInt && src isa Instruction && _foz5_neutralisable(inst, dead_blocks)
+         width 64/64 guard (else fall through to the existing messages)
+         return IRBinOp(dest, :add, iconst(0), iconst(0), 64)
+     end
  jbko arm                              [~3846-3960]  UNCHANGED, pin KEPT
```

The 583s branch handles `%98` (memdata-rooted, proof fails on the foreign
sibling). The new arm handles `%99` (`_memdata_root === nothing`). Order between
them is irrelevant: they are decided by disjoint entry conditions and emit the
same node. **`_memdata_root` is not touched.**

### 2.2 The predicate

New helpers next to `_verify_memdata_bounds_cluster` (after `instructions.jl:855`).
`_foz5_neutralisable(pt, dead_blocks) :: Bool`:

* **N0** `pt` is `PtrToInt`, result width 64.
* **N1 (component)** BFS: `P = {pt}`; for each `p ∈ P`, `p` has ≥1 use and *every*
  use is a 2-operand `sub i64` **both** of whose operands are `ptrtoint`
  instructions; add both to `P`, add the `sub` to `S`. Bound `|P| ≤ 16`.
  *(The component, not the single instruction, is the unit — otherwise a
  `ptrtoint` shared between a proved sub and an unproved one could be zeroed on
  one side and identity-emitted on the other, producing `0 − address` and a
  spurious halt. This is a real hazard route (a) also has and does not address.)*
* **N2 (has uses)** a use-less `ptrtoint` is rejected (mirrors 583s's `saw`).
* **N3 (yield to the proof)** if **every** `s ∈ S` has `_memdata_root` equal and
  non-`nothing` on both operands, **decline** — 583s owns the whole component and
  its behaviour is byte-identical to HEAD.
* **N4a (polarity)** every use of every `s ∈ S` is an `icmp` with
  `(op1 == s && pred ∈ {ult, ule})` or `(op2 == s && pred ∈ {ugt, uge})`.
  Anything else — `eq`/`ne`, signed, wrong side — rejects.
* **N4b (address-free bound)** the other operand `X` has no `ptrtoint` in its
  transitive operand closure (depth ≤ 12).
* **N5 (monotone to a pruned false edge)** i1 closure `C` from `I` through `and`
  and `or` **only**; every use of every `c ∈ C` is either another `and`/`or` or a
  **conditional** `br`; for every such `br`, `successors(br)[2]` (the FALSE
  target) is in `dead_blocks`. Bound `|C| ≤ 16`.

`dead_blocks` is **already a kwarg of `_convert_instruction`** (threaded from
`module_walk.jl:609` for Bennett-3vf2, `ptr_cells`-gated, computed once at
`:426`). **Zero new plumbing.** The two non-`module_walk` callers (`heap.jl`,
`vector_vm_cfg.jl`) forward neither `ptr_cells` nor `dead_blocks`, so the arm is
unreachable from them — byte-identical.

### 2.3 Measured behaviour of the predicate (probe `pB_neutral.jl`)

Run on the real `growend.ll` and on the three fixtures that matter:

```
-- @julia_#_growend!##0_469   dead_blocks=16
  [L46]      %36  memdata=rooted  583s-admits=true   foz5=false  (583s already proves the whole component)
  [L46]      %37  memdata=rooted  583s-admits=true   foz5=false  (583s already proves the whole component)
  [L58]      %44  memdata=rooted  583s-admits=true   foz5=false  (583s already proves the whole component)
  [L58]      %45  memdata=rooted  583s-admits=true   foz5=false  (583s already proves the whole component)
  [L84]  %coercion memdata=NOTHING 583s-admits=false foz5=false  (use of ptrtoint is not a sub: icmp eq)   <-- jbko witness SAFE
  [idxend41] %98  memdata=rooted  583s-admits=false  foz5=TRUE   |P|=2 |S|=1 |I|=1
  [idxend41] %99  memdata=NOTHING 583s-admits=false  foz5=TRUE   |P|=2 |S|=1 |I|=1
  [oob*/L90/L96]  … all inttoptr-consumed          foz5=false  (use of ptrtoint is not a sub)
FIXTURE NON_MEMDATA  %d   foz5=false  (use of ptrtoint is not a sub: ret i64 %d)
FIXTURE CROSS_MEM    %b   foz5=false  (use of sub is not an icmp: ret i64 %d)
FIXTURE CROSS_MEM    %e   foz5=false  (use of sub is not an icmp: ret i64 %d)
FIXTURE JBKO_ICMP_EQ %c   foz5=false  (use of ptrtoint is not a sub: icmp eq)
```

Reading, line by line:

* **583s's own corpus is inert.** `L46`/`L58` decline at **N3** — the design is
  byte-identical on every cluster 583s already proves (`setindex!`, `rehash!`,
  `ht_keyindex2!`, `fdict`).
* **Both halves of the foz5 cluster are claimed together**, `|P| = 2`, so the
  operand-zeroing is symmetric and the `0 − address` hazard cannot arise.
* **CROSS_MEM (test_583s gate 5) stays red, unedited**, and the rejecting
  condition is named: **N4a** (`use of sub is not an icmp` — it `ret`s). Note
  this is a *stronger* reason than root inequality.
* **NON_MEMDATA (gate 4) stays on the iwo9 wall** — rejected at **N1**.
* **The jbko `%L84` witness is untouchable**: its use is `icmp eq`, which **N1**
  rejects. This is **predicate disjointness, not arm ordering** — see §2.5.

### 2.4 End-to-end on the real gated path (probe `pB_e2e.jl`)

`pB_e2e.jl` re-implements HEAD's `_memdata_root` / `_verify_memdata_bounds_cluster`
verbatim as `orig_root` / `orig_cluster`, wires my predicate into the two
decision points, and runs the real `extract_parsed_ir_set_from_julia(_pushfoz5,
Tuple{Int64}; ptr_cells=true)` under `--check-bounds=yes`:

```
NEXT WALL: … extraction FAILED for callee `_pushfoz5#1eb3deec` … store in
@julia__pushfoz5_40644:%top:  store { ptr, ptr } %memory_ref, ptr %"new::Array"
— aggregate store target is not a CERTIFIED cell pointer — `julia.gc_alloc_obj`
— BYTE-granular … (Bennett-p06b, predicate `_p06b_cell_ptr_target_kind`)

--- marker probes ---
Bennett-583s      false      Bennett-p06b   true
base-cancelling   false      gc_alloc_obj   true
_growend!         false      BYTE-granular  true
Bennett-jbko      false      Bennett-iwo9   false
ConcurrencyViolation false   L84            false
```

Wall 7 is cleared; the `_growend!` closure extracts completely; the next wall is
the **root body**'s p06b `gc_alloc_obj` refusal — identical to the scout's
`p06_next2.jl` forecast, reached by a **different mechanism**, which is
independent corroboration. `Bennett-jbko` / `L84` / `ConcurrencyViolation` are
all absent: **the jbko chain was not poached on the real corpus.**

### 2.5 Disposition of the three mandated interactions

**(i) The jbko `_memdata_root(src) === nothing` pin — KEEP, UNCHANGED.**
The a8nw note is neither followed nor inverted; it is *rendered moot*. My
"fall-through" is **internal to the 583s block** (proof → neutralise → error), so
the 583s arm still always returns or errors and nothing memdata-rooted reaches
jbko. The pin stays exactly as redundant as it is today, and the comment block at
`:3885` stays literally true. I would add one sentence to that comment recording
that foz5 landed *without* creating the fall-through it anticipated.

Stronger than that: the new arm and the jbko arm are **provably disjoint,
independent of ordering**. N1 requires *every* use of the `ptrtoint` to be a
`sub`; jbko requires *every* use to be an `icmp eq`/`ne`; a `ptrtoint` with ≥1
use cannot satisfy both, and one with 0 uses fails N2. A future agent may
reorder the arms freely.

**(ii) The jbko corpus witness (`_growend!` `%L84`) — UNTOUCHED.**
Measured twice: `pB_neutral.jl` shows `foz5=false` on `%coercion` with the reason
printed, and `pB_e2e.jl` shows the real-path message contains no `Bennett-jbko` /
`L84` / `ConcurrencyViolation` substring. The steal `p07_steal.jl` demonstrates
is a consequence of *widening `_memdata_root`*; this design does not widen it.

**(iii) The p06b arm — NO COUPLING, verified.**
`grep -rn "_memdata_root" src/` → live call sites 3826 and 3913 only.
`_p06b_cell_ptr_target_kind` / `_p06b_slot_key` / `_p06b_alias_group` are
independent. p06b is not read, not written, not reordered.

### 2.6 What BennettVM sees — zero source changes, by precedent

The emitted node is `IRBinOp(dest, :add, ConstOperand(0), ConstOperand(0), 64)`.
This is **the exact shape Bennett-a70z already emits** on its `always0` fold path
(`instructions.jl:3423`), chosen there for the same reason — a70z's D3 note
explicitly rejects `IRICmp(ConstOperand, ConstOperand)` as "an out-of-repo shape
this repo cannot verify" and prefers the `IRBinOp` const-const `add`. BVM lowers
it via `ingest_body.jl:95-110` to a `Define` with `_lower_bool_operand`, which at
`width == 64` is the identity on an `Int64` constant
(`ingest_operands.jl:51-54`). Downstream BVM coverage already exists
(`test_tl1l_a70z_shapes.jl`, `test_a70z_dict64_roundtrip.jl`).

The `sub`, the `icmp`, the `and`, and the `br` are all emitted **verbatim by the
existing generic paths** — I change no arm for them. The node inventory of the
widened `_growend!` extraction is therefore the scout's `p08c.jl` inventory
(`IRBinOp, IRBranch, IRCall, IRCast, IRExtractValue, IRICmp, IRInsertBits,
IRInsertValue, IRLoad, IRPhi, IRPtrOffset, IRRet, IRSelect, IRStore, IRVarGEP`)
with **no new kinds**. **Zero BVM `src/` changes.**

*(Note the elision variants the scout sketched — dropping the `sub`/`icmp`
outright, or rewriting the `icmp` to a constant — would each need either the
`suppressed_refs` machinery or an `IRICmp`-arm change and would hit exactly the
a70z D3 out-of-repo-shape objection. Operand zeroing avoids both.)*

### 2.7 A deliberately-rejected sharpening (record it, don't build it)

The guard could be made sharper than `0 <u X` by recognising
`pt_e = ptrtoint(gep i8 %B, %K)` and emitting `pt_e := K`, `pt_b := 0`, so
`s_vm = K` (the modelled byte displacement) rather than `0`. That recovers real
throw detection — **but only under the unchecked assumption `B ≥u A`** (the
captured pointer is at-or-after the base); if it fails, `K` can exceed `X` while
the true difference does not, and we get a **spurious halt**. Trading a
zero-assumption theorem for a one-assumption sharper check is the wrong trade for
the landing design. File it as a P3 follow-up with the assumption named.

---

## 3. Failure modes and message territory

### 3.1 New reject text: **none**

The design adds an **admission path only**. Every reject message in the ptrtoint
region is untouched:

* memdata-rooted + proof fails + not neutralisable → **583s's original message,
  verbatim** (gates 2a, 2b, 3, 5, and jbko gate O all keep their pins);
* not memdata-rooted + not neutralisable → falls to jbko, then iwo9, unchanged;
* width ≠ 64 → the existing 583s / jbko width messages, unchanged.

Consequently **no existing message assertion can break by wording.** Only
*wall-location* assertions move, and only the four already-known marker files.

### 3.2 Per-file prediction (grep-complete over
`grep -rln "Bennett-583s|base-cancelling|Bennett-foz5|Bennett-jbko|memdata" test/`)

| File | Pins | Prediction | Why |
|---|---|---|---|
| `test_583s_memdata_bounds.jl` (1)(2a)(2b)(3)(4)(5)(6)(7) | the whole 583s contract | **GREEN, ZERO EDITS** | (1) `CLUSTER_OK` is root-equal → N3 declines → identical `IRBinOp(:or,…,0,64)`; (2a) hash → N1; (2b) `inttoptr` → arm is PtrToInt-only; (3) width; (4) → N1 (`ret`); (5) → N4a (`ret`), **measured** in `pB_neutral.jl`; (6) `setindex!` root-equal → unchanged; (7) gate-off + seed unchanged |
| `test_jbko_ptr_identity_icmp.jl` (A)–(O) | jbko contract, incl. (O) 583s inertness | **GREEN, ZERO EDITS** | `JBKO_MEMDATA_ICMP`'s use is `icmp eq` → N1 rejects → 583s's original message fires → `Bennett-583s` + `base-cancelling` both present, `Bennett-jbko` absent. Verified on the isomorphic `JBKO_ICMP_EQ` fixture in `pB_neutral.jl` |
| `test_59zi_sret_call_memcpy.jl:350` `!occursin("583s / CW-D")` | fdict/`setindex!` path | **GREEN** | that path's clusters are root-equal → N3 declines → byte-identical to HEAD |
| `test_p06b_aggregate_store.jl` **(k)** | `!occursin("Bennett-p06b")`, `occursin("_growend!")`, 583s disjunction | **RED — must be advanced (3 assertions)** | wall 8 message contains `Bennett-p06b`, is in `_pushfoz5`, and contains no 583s text |
| `test_vau9_variable_memmove.jl` **(g)** (`:294`, `:299-304`) | same three | **RED — must be advanced (3 assertions)** | same |
| `test_40ys_instanceless_callees.jl` (`:522`, `:530-533`) | `!occursin("Bennett-p06b")` + 583s disjunction | **RED — must be advanced (2 assertions)** | same (no `_growend!` positive here) |
| `test_7wsz_ptr_sret_fields.jl` (`:536-541`) | `!occursin("Bennett-p06b")` + 583s disjunction | **RED — must be advanced (2 assertions)** | same |
| `test_beaw_null_ptr.jl:204`, `test_416r17_…:134` | comments only | **GREEN, no edit** | grep-verified: no assertion |
| `test/runtests.jl:550-562, 634-635, 658` | registration commentary | **GREEN**; prose update only | the `:658` note "advances to the `%idxend41` Bennett-583s ptrtoint wall (bead Bennett-foz5)" is now stale |

### 3.3 The marker advance — narrow, don't delete (the scout's trap)

The `!occursin("Bennett-p06b", msg)` negative exists to catch an **over-tight
p06b store reject inside the closure**. Wall 8 *is* a p06b store reject, so a
blanket negative cannot survive — but deleting it loses the intent. The
narrowing that preserves it exactly, using the fact that wall 8 is in a
*different body*:

```julia
# NARROWED (Bennett-foz5): p06b must not reject anything in the CLOSURE body.
# Wall 8 IS a p06b reject — but in the ROOT body (`_pushfoz5`), on the
# `julia.gc_alloc_obj` box store, which p06b's own message flags as a future
# widening. Scoping the negative by body keeps the original intent live.
@test !(occursin("Bennett-p06b", msg) && occursin("_growend!", msg))
```

This recycles the retired `occursin("_growend!", msg)` positive as the negative's
scope term, so nothing is thrown away. The positive becomes the wall-8 marker,
plus a **new** load-bearing negative proving wall 7 is cleared:

```julia
# POSITIVE: wall 8 — the ROOT body's byte-granular gc_alloc_obj store target
# (Bennett-p06b P4b / CW-D4 / bennettvm-9n3y).
@test occursin("gc_alloc_obj", msg) || occursin("BYTE-granular", msg)
# LOAD-BEARING NEGATIVE: wall 7 is CLEARED (Bennett-foz5).
@test !occursin("base-cancelling", msg)
@test !occursin("Bennett-583s", msg)
# unchanged predecessors
@test !occursin("Bennett-jbko", msg)
@test !occursin("Bennett-iwo9", msg)
@test !occursin("memmove", msg)
@test !occursin("Bennett-lgzx", msg)
@test !occursin("store of non-integer type", msg)
```

All eight substrings are **measured** in `pB_e2e.jl`'s marker table. For `40ys`
and `7wsz` (which have no `_growend!` positive today) the narrowed negative uses
the same form; both files' surrounding comments already name the body, so the
scoping term is honest there too.

### 3.4 Drift behaviour (Rule 5) — degrade to the wall, never to admission

The predicate is a **conjunction of positive requirements**. Any IR the design
did not anticipate — a `select` instead of a `br`, an `xor` in the i1 chain, a
signed compare, an inverted branch polarity, an extra use of the `sub`, a
`ptrtoint` shared with a non-`sub` consumer — fails some N-condition and the
value falls back to the **existing** fail-loud wall. There is no path on which
drift produces a silent admission. That is the design's answer to "what happens
when the shape drifts": you get wall 7 back, loudly, with the message you have
today.

---

## 4. Test plan

New file `test/test_foz5_neutralised_bounds_guard.jl`, registered in
`runtests.jl` **immediately after** `test_583s_memdata_bounds.jl` (so a 583s
regression is seen first). Helper idiom: `_extract_ll` from
`test_583s_memdata_bounds.jl`; positive node-shape helper analogous to
`_memdata_or`, plus a new `_foz5_zero(pir, dest)` returning the
`IRBinOp(dest, :add, ConstOperand(0), ConstOperand(0), 64)` node or `nothing`
(Rule 4: no-throw ≠ pass).

All fixtures carry
`target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"` (the
`test_7wsz` / `test_59zi` / `test_416r16` idiom) — required because the corpus
shape is byte-offset-GEP based. Every per-file green claim is under
`julia --project --check-bounds=yes test/…`.

**Distilled `.ll` gates**

* **(A) GREEN — the corpus shape.** `define void @f(ptr %env, ptr %roots)`;
  `%m = load ptr, (gep i8 %roots, 16)`; `%d = load ptr, (gep inbounds i8 %env, 56)`;
  `%e = gep i8 %d, %off`; `%b = ptrtoint (load ptr, (gep {i64,ptr} %m, 0, 1))`;
  `%x = ptrtoint %e`; `%s = sub %x, %b`; `%c = icmp ult %s, %len`;
  `%v = and i1 %nov, %c`; `br i1 %v, %ok, %oob`; `%oob:` ends `unreachable`.
  Assert **both** ptrtoints produce `_foz5_zero`, **neither** produces
  `_memdata_or`, and the `icmp`/`sub`/`and`/`br` are emitted **unchanged**
  (the `IRICmp` node is present with predicate `:ult`).
* **(B1) RED — no dead-throw sink.** As (A) but `%oob` `ret`s. Must reject with
  583s's message (the N5b pin).
* **(B2) RED — inverted branch polarity.** `br i1 %v, %oob, %ok` with `%oob`
  `unreachable`. Must reject. *(This gate is load-bearing: it pins that
  `LLVM.successors(br)[2]` is the FALSE target. My probe establishes the ordering
  empirically on the corpus; a fixture must make it a contract.)*
* **(B3) RED — `xor` in the i1 chain.** `%n = xor i1 %c, true; br i1 %n, %oob, %ok`.
  Must reject — this is the monotonicity premise, and it is the *one* shape that
  would silently invert the theorem if admitted.
* **(C) RED — escape.** The captured-half `ptrtoint` additionally feeds an `add`.
  Must reject (N1).
* **(D) RED — wrong compare polarity.** `icmp ugt %s, %len`. Must reject (N4a).
* **(E) RED — address-derived bound.** `%len2 = ptrtoint %something; icmp ult %s, %len2`.
  Must reject (N4b) — the Lemma-2 pin.
* **(F) RED — mixed component.** A `ptrtoint` used by **two** subs, one
  root-equal and one foreign. Must reject *or* neutralise **both** subs; assert
  that no `IRBinOp(:or, …)` and `_foz5_zero` coexist in the same component.
  *(This is the `0 − address` spurious-halt hazard; it is the gate that proves
  the component closure is doing its job.)*
* **(G) INERT — 583s's own cluster.** `CLUSTER_OK` verbatim from
  `test_583s_memdata_bounds.jl`: assert `_memdata_or` present and `_foz5_zero`
  **absent** (the N3 yield-to-the-proof pin).
* **(H) BYTE-IDENTITY — gate off.** (A) at `ptr_cells=false` still fails loud.

**Steal-prevention / ordering gates (mandatory, from scout §3.2)**

* **(O1)** `test_jbko_ptr_identity_icmp.jl` (O) `MEMDATA_ICMP` unchanged and
  green — re-run, no edit.
* **(O2) NEW — the hybrid.** A fixture whose `ptrtoint` source is *both*
  S1-shaped (`load ptr` of a constant-offset `i8` GEP off an `Argument`) *and*
  jbko-shaped (sole use `icmp eq` against an `i64` argument) — the
  `JBKO_ICMP_EQ` fixture in `pB_neutral.jl`. Assert **by name** that jbko admits
  it and that the message, if any, contains **no** `Bennett-583s` /
  `Bennett-foz5`. This is the permanent record that the arms are
  use-disjoint.
* **(O3) NEW — corpus anti-steal.** On the real gated path: `@test
  !occursin("Bennett-jbko", msg)` and `@test !occursin("ConcurrencyViolation", msg)`.
  Measured false in `pB_e2e.jl`.
* **(O4) NEW — the pin is still redundant.** A unit gate asserting the jbko arm's
  entry condition **still** carries `_memdata_root(src) === nothing` (a source
  grep assertion, or equivalently gate (O) staying green), with a comment citing
  §2.5(i): foz5 landed *without* the fall-through a8nw anticipated, so the note
  is moot rather than inverted.

**CROSS_MEM preservation**

* **(P) INERT** — re-run `test_583s_memdata_bounds.jl` **entirely unedited**. If
  any assertion in it needs a change, the widening is too broad and the design is
  wrong. Gate (5) `CROSS_MEM` in particular must stay red; `pB_neutral.jl`
  measures the rejecting condition as N4a.
* **(Q) NEW — the honest carve.** `CROSS_MEM_CONFINED`: two genuinely different
  `Memory` roots whose difference *is* confined to a dead-throw bounds check.
  This **is admitted** under the design. Assert it explicitly, with a comment
  saying so and citing §1.6 — a gate that documents a deliberate scope choice is
  worth more than one that hides it. *(A reviewer who finds this unacceptable is
  rejecting the route, not the implementation — say so in the gate's comment.)*

**Marker advances (4 files, per §3.3)** — `test_p06b_aggregate_store.jl` (k),
`test_vau9_variable_memmove.jl` (g), `test_40ys_instanceless_callees.jl`,
`test_7wsz_ptr_sret_fields.jl`.

**Corpus gate** — in the new file, the `_pushfoz5` gated path, asserting the wall
message satisfies the §3.3 marker set. Written as a disjunction on the positive
(which body fails first is registration order, not a contract — the `test_lf14`
convention) and as strict negatives on the cleared walls.

**BVM E2E** — **not required**; the shape argument (§2.6) plus a `@test` on the
emitted node kinds is sufficient evidence. A BVM round-trip would still wall at
wall 8 in the root body, so it would prove nothing about this bead. Do run
BennettVM's `test_tl1l_a70z_shapes.jl` once as the standing witness that the
emitted const-const `IRBinOp` ingests.

**Shared-machinery re-runs** (worklog 093's rule — `_vec_vm_dead_blocks` is
touched read-only): `test_utzc_dead_block_pruner.jl`, `test_jfw6_vec_vm_extract.jl`,
`test_d1b_julia_set.jl`, `test_3vf2_dead_use_global_load.jl`, all under
`--check-bounds=yes`.

---

## 5. Risks

| # | Risk | Severity | Mitigation / status |
|---|---|---|---|
| R1 | **A6 is a real policy change.** A neutralised guard no longer detects the native `BoundsError`. | High — needs lead sign-off | §1.6 ADR amendment; gate (Q) makes the scope explicit; §1.5 distinguishes it from Bennett-lbot on three named grounds. If rejected → status quo (stay walled), which §1.3/scout §4.2 show is permanent |
| R2 | **Branch-successor ordering.** N5b reads `successors(br)[2]` as the FALSE edge. Empirically right (probe passes on `br %v, %idxend62, %oob57`), but it is an LLVM.jl API convention. | Medium | Gate (B2) turns it into a contract; if the convention flips, (B2) goes red loudly and (A) stops admitting — the safe direction |
| R3 | **Mixed component** (`ptrtoint` in both a proved and an unproved sub) → `0 − address` → spurious halt. | Medium | Prevented by the component closure (N1) — the unit of decision is the component, not the instruction. Pinned by gate (F). *Route (a) has this hazard too and does not address it* |
| R4 | **Shape drift** (Rule 5) — Julia/LLVM emits a `select`, a signed compare, an inverted `and`. | Low | Predicate is a conjunction of positives ⇒ drift degrades to the existing wall, never to admission (§3.4). SSA numbering drift is already handled: nothing is pinned by number (confirmed — this session saw `%94` where the dump has `%98`) |
| R5 | **Future widening consumes the zeroed cell.** | Low | The cell holds `0`, not an address, so no 8g7m-style address laundering is possible — strictly safer than route (a)'s cell identity. The predicate re-derives per `ptrtoint`, so a new use shape rejects |
| R6 | **`_vec_vm_dead_blocks` is shared machinery** with the Case-A recogniser and the utzc pruner. | Low | Read-only use; §4's shared-machinery re-run list |
| R7 | **Gate (Q) admits genuinely-cross-object confined differences** — a deliberate widening beyond root equality. | Medium | Explicitly gated and documented rather than hidden; the value is never observable (Theorem §1.4) |
| R8 | **Marker churn in 4 files** could mask a real p06b regression if narrowed carelessly. | Low | §3.3's body-scoped narrowing preserves the original intent exactly |
| R9 | Wall 8 lands on **BennettVM cell granularity** (CW-D4 / `bennettvm-9n3y`), a different kind of boundary from every previous wall. | Informational | File the follow-up bead now (scout §7.4); expect it to be cross-repo |

---

## 6. Diff shape

**`src/extract/instructions.jl`** — the only source file.

* **+~110 LOC** of new helpers after `_verify_memdata_bounds_cluster` (`:855`),
  with a doc block stating the theorem of §1.4 and pointing at this document:
  `_foz5_no_ptrtoint_below`, `_foz5_sub_component`, `_foz5_confined_compare`,
  `_foz5_monotone_to_dead_edge`, `_foz5_neutralisable`.
* **+5 LOC** inside the 583s arm (`~:3837`): one `if` between the cluster gate
  and the `_ir_error`. **No existing line changes.**
* **+~12 LOC** new arm between the 583s block (`:3845`) and the jbko block
  (`:3846`).
* **+~8 lines of comment** in the jbko `_memdata_root === nothing` pin block
  (`:3885`) recording §2.5(i).
* **0 LOC** of plumbing — `dead_blocks` is already a kwarg (`:3648`), already
  forwarded (`module_walk.jl:609`), already `ptr_cells`-gated.

**`test/`**

* **new** `test_foz5_neutralised_bounds_guard.jl` (~15 gates: A, B1–B3, C–H,
  O2–O4, Q, corpus).
* **edit** `runtests.jl` — one `runfile` after `test_583s_memdata_bounds.jl`;
  refresh the wall-7 prose at `:550-562` and `:658`.
* **edit, marker advance only** `test_p06b_aggregate_store.jl` (k, 3 assertions),
  `test_vau9_variable_memmove.jl` (g, 3), `test_40ys_instanceless_callees.jl` (2),
  `test_7wsz_ptr_sret_fields.jl` (2).
* **unedited, must stay green** `test_583s_memdata_bounds.jl`,
  `test_jbko_ptr_identity_icmp.jl`, `test_59zi_sret_call_memcpy.jl`.

**Docs / process**

* `BennettVM.jl/docs/adr/0017-closed-world-execution.md` — §4a amendment (§1.6).
  Cross-repo, doc-only, **requires lead sign-off before the code lands**.
* `worklog/099_2026-08-06_p06b_aggregate_store.md` (current top chunk, verified
  `ls worklog/ | sort -r | head -1`) — prepend the session log; record the
  route-(c) rejection so it is not re-derived, the SSA-drift observation, and the
  Bennett-lbot reconciliation.
* Beads: correct `Bennett-foz5`'s description (its stated mechanism and root
  shape are both wrong — scout §7.3); file the wall-8 follow-up
  (p06b `gc_alloc_obj` byte-granular target, root body, CW-D4 / `bennettvm-9n3y`);
  file the P3 offset-substitution sharpening (§2.7).

**Not touched:** `_memdata_root`, `_verify_memdata_bounds_cluster`, the jbko
arm's entry condition, `lower.jl`, `bennett_transform.jl`, gates, any
`BennettVM.jl/src` file.
