# Worklog chunk 102 — 2026-08-06 — Bennett-bvmd implementation (xkl wall 8 cleared)

Chunk 101 closed at 151 lines; this session's entry would have pushed it to 382, so starting 102 per CLAUDE.md §0 (~280-line cap).

## Session log — 2026-08-06 — Bennett-bvmd: IMPLEMENTER (full 3+1) — wall 8 CLEARED, corpus at wall 9

**Role:** implementer of the full 3+1 (proposers A and B blind, this session
adjudicating + synthesising + implementing; the orchestrator is the reviewer).
Inputs: `docs/design/bvmd/proposal_A.md`, `proposal_B.md`,
`docs/design/bvmd_scout.md`. HEAD `e8b21a4`, sister BennettVM `d44f1c3`.
Serial `julia --project --check-bounds=yes`, one process at a time. **No commit.**

### The shipped invariant

> **(SC)** For every pointer root `R` whose scale is KNOWN, every `IRPtrOffset` /
> `IRVarGEP` derived from `R` must carry `elem_width == 8·scale(R)`.

`elem_width` is not a type width in the cell model — BVM lowers `IRPtrOffset` to
`Define(d, b, :add, off ÷ (ew÷8))`, so it is **exactly the bytes-per-cell scale**
of the object. And that scale is already fixed, per allocator, by BVM code that
ships: `_lower_alloca!` reserves `n` cells and ignores `elem_width` (⇒ scale
`ew÷8`); `_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nb)` (⇒ scale **1**);
`_alloc_cells(::IntrinsicMalloc) = _cell_count(nb)` (⇒ scale **8**). The
extractor now **reads** that table (`_root_scale`) rather than inventing a tier.
This is proposer B's framing and it is the right one: it removes the scout's
main objection to route α ("a new global-ish analysis in a depth-0 extractor")
because there is no analysis, only a lookup.

### Adjudication (four divergences + one that only measurement could settle)

**D1 — enforcement locus: BOTH, and the composition matters.** A's shared
`_cell_elem_width` stamp (checker and emitter call one function ⇒ coherence is a
lemma) for the four sites that CHOOSE a stamp; B's (SC) check over the EMITTED
stream as the drift-proof backstop covering all nine `IRPtrOffset` construction
sites including the six unaudited ones. **Cost:** one reverse `names` map per
function plus a depth-8 walk per offset node — negligible. **Failure mode:** it
runs at the END of the function's conversion, i.e. strictly after every
in-conversion `_ir_error`, so **no existing message territory moves** — it can
only add a loud failure for a program that previously extracted *silently
wrong*. That locus is strictly better than B's own per-site guard at
`instructions.jl:4817`, which would have fired BEFORE p06b's (P5) and relocated
the (g4) message. It also auto-exempts SUPPRESSED sret boxes (they emit nothing),
which is why the four z2ia-shaped `alloca [2 x i64]` + `gep i8 8` fixtures in
`test_416r16` / `test_7wsz` never trip it.

**D3 — (P5): A's tier-parametrisation, NOT B's skip.** B's subsumption claim is
**true for coverage** and I verified it: for a scale-known root, (SC) sees every
node derived from the root at any GEP depth, a strict superset of (P5)'s
direct-use scan — with ONE corner, variable-index GEPs, which emit `IRVarGEP`
rather than `IRPtrOffset`. **CORRECTION (hostile review D1):** the first revision
claimed to have closed that corner by extending (SC) to `IRVarGEP`. It did not —
the arm was **dead code**. The vacuity exemption computed
`cell_emitted = cell_meant = -1` for every `IRVarGEP`, so `continue` fired on all
of them, and a `gep i64, ptr %obj, i64 %i` off a byte-tier `gc_alloc` box
extracted SILENTLY at `elem_width = 64` while BVM strides an `IRVarGEP` by one
cell per index unit — an 8x misaddress (reviewer probe `r01_vargep.jl`). Fixed
by guarding the exemption with `node isa IRPtrOffset &&`; for an `IRVarGEP` the
predicate is bare stamp equality, since a runtime index has no constant cell to
be vacuous about. Both directions are now permanent gates ((V) in
`test_bvmd_root_scale.jl`), with a coherent control so the arm is discriminating
rather than a blanket `IRVarGEP` refusal. But
*skipping* (P5) for scale-known roots RELOCATES the message: `p06b_granularity`,
the (g4) fixture, targets `malloc(16)` — scale-KNOWN — so under B's split it
would have failed with the (SC) message and lost `Bennett-p06b`. A's stamp
comparison achieves the same accept/reject sets with **zero** relocation. Shipped
shape: (P5) is retained for ALL roots; for `ew_store == 64` it is today's rule
**verbatim** (word tier byte-identical), for `ew_store == 8` it becomes a stamp
comparison against `_cell_elem_width_struct_gep` / `_const_gep_stamp` — the
emitter's own functions. B's genuinely-unique insight is kept: (P5) must NOT be
deleted, because for a scale-UNKNOWN root (`_growend!`'s `%1 = load ptr, ptr %0`
off a `dereferenceable(0)` arg) (SC) is silent and (P5) is the only guard.
Measured: the whole (D2)/(D7)/(N2)/(D3)/(g4) surface stayed green untouched.

**D4 — the `!583s` / `!base-cancelling` negatives: B is right, KEEP them.**
Measured on the new wall-9 message: both `false`. The scout's drop-instruction
was one bead early — wall 10 (the escaping base-cancelling difference) sits
BEHIND four memcpys. Left a comment at each site naming the trap for whoever
clears wall 9: they must replace these with the foz5 two-part pattern (body
scope + a `udiv exact` live-value discriminator).

**D2 (z2ia) — the one measurement overturned, twice.** My first adjudication was
**B** (refuse loudly), on a counter-example neither proposer had: A's blanket
`ptr_cells`-gated normalisation `(w,n) → (8, (w÷8)n)` is **unsound composed with
(SC)** — `alloca i32, i32 8` + `gep i32 …, 3` is coherent TODAY at scale 4 and
becomes a violation at scale 1, and the same argument kills `alloca i64, i32 4`
+ `gep i64 …, 2`, i.e. the entire C tier. A probed the gate-backend hazard (R6)
but never composed normalisation with the invariant.

Then the refusal was measured and it **broke live functionality**:
`test_40ys` (K) — real Julia source, `Pair40ys` boxed into `alloca [2 x i64]`
and byte-addressed — walls. That fixture **extracts, runs and reverses on the VM
today** (`../BennettVM.jl/test/test_40ys_closure_callee_vm.jl`). Trading a latent
hole for a functional regression inside one bead is the wrong trade, and neither
proposal had this datum (B's blast-radius sweep saw `test_qmv7` and stopped).

Shipped answer — **the synthesis**: A's byte-normalisation as the ADMISSION,
made sound by making it **use-directed** instead of blanket. An
`IRAlloca(d, 64, ConstOperand(n))` is rewritten to `IRAlloca(d, 8, 8n)` iff
**every** emitted offset off that root is byte-stamped **and** at least one of
them genuinely disagrees. A genuinely MIXED object (byte *and* word accesses) is
normalised by nothing and refused loudly — that is `bennettvm-jb6w`'s hazard,
made loud. The typed-array tier and the whole C tier are untouched **by
construction**, because they are never all-byte.

  * wire-count-neutral (A's F2, now pinned as an assertion not prose:
    `64·9 == 8·72 == 576` bits in `_lower_alloca_const_n!`);
  * BVM-change-free (A's F1: `_lower_alloca!` reserves `n` cells, "`elem_width`
    (in bits) does NOT enter the address");
  * storage-free (A's F3: `IState.memory` is a sparse `Dict` with zero-init);
  * `ptr_cells`-gated, which is also what keeps it off the gate backend where it
    would NOT be neutral (A's probed R6: `lowering/aggregate.jl:261-273` computes
    a `PtrOrigin` slot index in ELEMENT units, so a normalised `ew` turns slot
    7-of-9-×64 into slot 56-of-72-×8). Both directions of the gate are pinned.

**D5 — `test_qmv7`: NO fixture re-authoring.** B's find is real (`alloca
[2 x i64]` + `gep i8 …, 8` = cell +8 in a 2-cell reservation, z2ia already
committed in a green fixture), but under the use-directed normalisation the
reservation widens to 16 byte cells and the fixture is admitted unchanged.
35/35 green, untouched. Dynamic-`n` allocas are NOT normalised (it would need an
emitted `IRBinOp(:mul, n, 8)` and changes `DynAlloca` arity in BVM) — named
refusal, filed on `Bennett-z2ia`, not silently inherited.

### The two findings this session added

**F-a. The VACUOUS DISAGREEMENT, and why it is not p06b's D2 carve-out.**
`gep i8 %obj, 0` off a word-tier alloca stamps 8 against scale 8 — but byte
offset 0 is cell +0 under EVERY stamp. Without an exemption `test_40ys`
(G)/(H)/(K) go red on an offset of ZERO, and `gep i8 %x, 0` is a routine Julia
codegen shape (GC-roots slots, `%".roots.#self#"` re-bases). The exemption is
`cell_emitted == cell_meant`, i.e. "this node's own step lands on the same cell
either way". This is **not** p06b's dropped D2 index-0 carve-out returning: D2's
hazard was that the carved-out GEP's RESULT becomes a fresh byte-granular base
whose deeper offsets were never re-scanned, because `_p06b_scan_uses` is ONE
LEVEL DEEP. The stream check walks the FULL const-GEP chain to the allocation
root at EVERY node, so `gep i8 %g0, 8` off such a base is checked independently
and still fires. Pinned as gate (G2) with a `bvmd_chain_mixed` fixture whose byte
leg is two GEPs deep behind an offset-0 hop.

**F-b. `Bennett-4y0d` was an ADDRESS/VALUE conflation, not an offset bug.**
`_handle_memcpy_global_src` used one `dst_ew` for both the width of the value
each store writes (64 for an arena cell — must NOT change) and the stamp on the
`IRPtrOffset` (the scale BVM divides the byte offset by — must be 8 for an arena
dst). Split into `dst_ew` and `ptr_ew`. For an ALLOCA dst the two coincide by
construction (same reservation) and for a scale-unknown PARAM dst the fallback is
64, so this is byte-identical everywhere except the arena dst. `test_vbv9`'s K=1
pin literally asserted `elem_width == 64`; re-authored to 8 **plus** an explicit
`offset ÷ (ew÷8) == 0` assertion, because the CELL is what the pin was really
protecting and the cell is unchanged — which is precisely why that pin stayed
green over a latent K≥2 defect.

### Gotchas for the next agent

* `IState` has **no `locals` field** (it is `pc`/`frames`/`status`/`memory`/
  `revmap`/`heap_top`/`arena_top`/`stack_top`/`globals`), and `pc` is an `Int64`,
  not a `(block, idx)` pair. Use `BennettVM.result(s)` for values and
  `status === :error` + `!is_halted(s)` for the `:__unreachable__` sink (the
  `test_utzc` gate-2 idiom).
* `test_cb9y_multi_origin_runtime_idx.jl` has no `using Test` — it only runs
  under `runtests.jl`. A standalone `UndefVarError: @testset` from it is
  PRE-EXISTING, not a regression.
* `_p06b_target_kind_name`'s `julia.gc_alloc_obj` paragraph is now **unreachable**
  and was retired; it also pinned `bennettvm-9n3y`, a **dangling ID in both
  trackers** (live filings: `Bennett-zdd6`, `bennettvm-rxgy`). The string was NOT
  reintroduced in the re-authored (N3). (P1)'s message keeps `9n3y` untouched —
  requirement was "(P1) INTACT" — with an appended prose-vs-predicate note, since
  under a provenance-first D4 stamp its "two cell maps" sentence now describes
  only the scale-UNKNOWN root.
* (P4c) is now compared **in the target's own cells**: capacity comes back in
  byte cells for `gc_alloc`, word cells for `malloc`/`alloca`, and the
  requirement is `(o_last + 8) ÷ scale`. For the word tier that is EXACTLY
  `length(fw)` — byte-identical, verified.

### Marker advances — the two-point RED table

Each assertion evaluated against the OLD wall-8 message (HEAD `e8b21a4`) and the
NEW wall-9 message. The third column is the same string as wall-8, read as *"a
hypothetical post-bvmd regression in which p06b re-rejects the gc_alloc target"*.

```
assertion                                     wall8(HEAD)  wall9(now)  regression
POSITIVE old  : gc_alloc_obj || BYTE-granular PASS         FAIL        PASS
POSITIVE new  : memcpy || Bennett-37mt        FAIL         PASS        FAIL
DISCRIM  old  : !p06b || gc_alloc_obj         PASS         PASS        PASS
DISCRIM  new  : !(p06b && gc_alloc_obj)       FAIL         PASS        FAIL
NEGATIVE      : !Bennett-583s                 PASS         PASS        PASS
NEGATIVE      : !base-cancelling              PASS         PASS        PASS
NEGATIVE new  : !BYTE-granular getelementptr  PASS         PASS        PASS
```

Read it honestly, row by row:

* the four POSITIVE sites (`test_foz5` W8, `test_40ys` I, `test_7wsz` J,
  `test_vau9` g, `test_p06b` k) are a genuine RED→GREEN: the old disjunction
  fails at wall 9.
* the DISCRIMINATOR inversion is **not** RED at either wall — both forms pass on
  the wall-9 message. That is precisely the point: the OLD form passes in ALL
  THREE columns, i.e. it had become **vacuous**, while the new form is the only
  one that distinguishes wall 9 from a p06b regression. A "RED-verify" claim for
  this row would be false; the evidence is the regression column.
* `!BYTE-granular getelementptr` is likewise not RED at either measured point.
  It guards the **counterfactual** the scout executed in `b06_p5.jl`: a
  (P4b)-only widening moves the reject to (P5), whose message contains that
  string. It is a no-op-arc detector, not a wall marker.
* the two `583s` negatives pass in every column, which is exactly why keeping
  them is right — and why they will genuinely go RED at wall 10.

### Measured results

Wall 8 → **wall 9** (`Bennett-37mt` Phase 1: `memcpy` src `gep i8
%"new::Array", 16` is not alloca-backed). Marker table at wall 9:
`memcpy`/`Bennett-37mt` **true**; `gc_alloc_obj`, `BYTE-granular`,
`Bennett-p06b`, `9n3y`, `Bennett-583s`, `base-cancelling`, `Bennett-jbko`,
`Bennett-iwo9`, `Bennett-lgzx`, `memmove`, `udiv`, `_growend!` **all false**.

Green (serial, `--check-bounds=yes`): `test_bvmd_root_scale` 68/68 (new),
`test_p06b` 617/617, `test_foz5` 63/63, `test_40ys` 128/128, `test_7wsz`
106/106, `test_vau9` 69/69, `test_qmv7` 35/35, `test_vbv9` 19/19, `test_9n3y`
8/8, `test_vz5n` 4+12, `test_haiy` 26/26, `test_munq` 69/69, `test_ixiz` 53/53,
`test_37mt` 86/86, `test_u2kk` 14/14, `test_583s` 28/28 (INERT), `test_jbko`
73/73 (INERT), gate-count regression **39/39**, plus `test_416r16` 40,
`test_416r17` 28, `test_nd45` 39, `test_6bu3` 161, `test_8bys` 28, `test_9nwt`
87, `test_store_alloca_extract` 279, `test_lower_store_alloca` 41, `test_zf5v`
16, `test_jfw6` 23.

**BennettVM: ZERO src changes** — eighth in a row. New `test_bvmd_byte_tier_vm.jl`
95/95, and every upstream-consuming BVM test green: `test_p06b_..._vm` 179,
`test_40ys_closure_callee_vm` 183 (the byte-normalised `Pair40ys` box round-trips
unchanged — A's F1/F3 hold and the arena cursor shift caused no churn),
`test_jbko_..._vm` 175, `test_vau9_memmove_vm` 267, `test_7wsz_..._vm` 160,
`test_a70z_dict64` 347, `test_c_hashtable_e2e` 73, `test_cwd4_genericmemory` 50,
`test_p81t_pgcstack` 29, `test_jlglobal_singleton` 28, `test_dict_roundtrip` 34,
`test_vec_vm_roundtrip` 141, `test_3vf2` 104, `test_416r12` 26, `test_5m1t` 51,
`test_tl1l` 1149, `test_x3t0` 20.

### The §4a-debt gate, and its HONEST scope

`../BennettVM.jl/test/test_bvmd_byte_tier_vm.jl` builds the scout's six-leg
fixture on one function: a 24-byte `gc_alloc_obj` box; the decomposed aggregate
store at byte cells 0/8; a class-A `gep i8 %obj, 8` **and** a class-D
`gep {ptr,ptr} %obj, 0, 1` read of the same field (the CW-D4 split, executed —
both return the stored pointer, and field 0 holds a *different* pointer so the
witness is non-vacuous); a closure-env `alloca [9 x i64]` byte-normalised to
`IRAlloca(:env, 8, 72)`, written and read back at byte 56 **by extracted code**;
a `ptrtoint`/`sub`/`icmp`/`br` guard over that value with a pruned throw
skeleton on the false edge; oracle under L2 and L3, exact `unrun!` (whole-state
equality + drained history + `step_count == 0`), per-step inverse at K ∈ {1,4},
and an out-of-bounds index halting at `:__unreachable__`.

**This discharges the foz5 §4a debt FOR THE MECHANISM, not for the corpus.** The
bead's premise that clearing wall 8 "lets the full push! corpus RUN" is FALSE,
measured: walls 9, 10 and 11 still block extraction and `bennettvm-rxgy` still
blocks `_growend!` at `lower_vm`. Wall 10 deserves the next agent's attention —
it is *not* a bounds check: the `sub` feeds `udiv exact …, 8` and the result is a
live ELEMENT INDEX, so §4a clause (iii) ("every use of the `sub` is an `icmp`")
is false and a THIRD contract is needed. And gate (6) is constructible only in
the fixture: on the real corpus `push!` on a fresh `Vector` never takes the `oob`
edge, so §4a's residual ("the throw may be missed, or the halt spurious") stays
undischarged by any test this arc can write.

### Hostile-review fix cycle (same session, after PASS-WITH-CONCERNS)

**D1 — the `IRVarGEP` arm was dead code.** See the corrected D3 paragraph above.
One-token fix (`node isa IRPtrOffset &&` on the vacuity exemption) plus three
permanent gates. RED evidence is the reviewer's own probe: pre-fix `r01` printed
`msg = ""` with `IRVarGEP elem_width=64` off a scale-1 root; post-fix both
directions raise, and the coherent control stays silent.

**D2 — the admission escaped into the circuit backend, and the docstring lied
about why it could not.** `ptr_cells` is an EXTRACTION flag, and
`ptr_cells=true` + `lower()` is a live combination (`test_59zi`, `test_lf14`), so
nothing this pass writes is hidden from the gate path. Measured (`r04`): the
byte-normalised `IRAlloca(8, 32)` reached `_lower_store_via_shadow!` and threw
(store width 64 vs alloca elem_width 8) where HEAD lowered fine.

**Route taken: (ii), the reviewer's fail-loud — but only after (iii) was built,
measured and REJECTED.** The sequence is worth recording, because the rejected
route looks strictly better on paper and is wrong for a reason no proposal, the
scout, or the review anticipated.

*(iii), attempted first.* `lower_ptr_offset!` (`src/lowering/aggregate.jl:195-280`)
slices by `offset_bytes * 8` and bumps the `PtrOrigin` index by
`div(offset_bytes * 8, ew)` with `ew` from `alloca_info` — it **never reads
`IRPtrOffset.elem_width`**. So re-stamping the ACCESSES
(`IRPtrOffset(_,R,off,8) → (_,R,off,8·scale(R))`) instead of widening the
RESERVATION is provably invisible to the gate backend, and `r04` confirmed it:
`ptr_cells` true and false both lowered to gate_count 322 / ancillae 385,
identical. All 83 upstream gates green.

*Why it is WRONG.* **The access re-stamp is not closed under function
boundaries.** `_check_scale_coherence!` runs PER FUNCTION. In a caller, a boxed
capture's byte GEPs get re-stamped to word cells; in the CALLEE the very same
object arrives as a pointer PARAMETER, whose scale is UNKNOWN, so its byte GEPs
are left alone. Caller writes cell +1, callee reads cell +8. Executed witness:
`../BennettVM.jl/test/test_40ys_closure_callee_vm.jl` gate (g) went **155/183
with wrong ANSWERS — 30 where the oracle says 42, 0 where it says 7**. Reverted.

Widening the RESERVATION has no such hazard **by construction**: it changes the
allocation's SIZE, never anyone's addressing, so every function that
byte-addresses the object continues to agree with every other. That is the
property that decides the route, and it is worth more than (iii)'s free lunch on
the gate path.

*So (ii) it is, in the reviewer's exact terms.* `lower()` now refuses a
byte-normalised ParsedIR loudly via `_bvmd_reject_normalised_alloca!`
(`src/lowering/driver.jl`). The message names the predicate, says WHY the rewrite
exists (Julia byte-addresses its own stack frames while the alloca arm
word-reserves them), gives the workaround (`ptr_cells=false` for the circuit
target), and names the (i) path as the fix — relax the shadow-tape width checks
to span `width ÷ elem_width` consecutive slots, which is sound because the bit
range is already identical (`64·n == 8·8n`, and byte offset `o` selects bits
`8o…8o+63` under either stamp). **This does convert a previously-working
combination into a loud error**, and that is stated in the message rather than
hidden.

Detection keys on the ACTUAL incompatibility — a byte-element alloca through
which a store or load WIDER than 8 bits is addressed — never on the reservation's
shape. A genuine `alloca [N x i8]` with 8-bit traffic (Bennett-munq's whole tier)
is untouched, and gate (R4) pins that control alongside the refusal.

**Raw-index exclusion (reviewer's cheap-if-small item — TAKEN).** A 2-op GEP
whose source element type is not an integer emits
`IRPtrOffset(dest, base, RAW_INDEX, 8)` (the legacy U16 branch,
`instructions.jl:4810-4815`), where `offset_bytes` is **not a byte offset** and
`8` is a placeholder unit. (SC) is *unevaluable* on such a node, and the reviewer
showed one faking a disagreement that rewrote a reservation 4→32. The guard is
one predicate (resolve `node.dest` through the reverse-names map; is it a 2-op
GEP with a non-integer source element type?), so it was taken: such nodes are
excluded from the re-stamp trigger AND from enforcement. The underlying
raw-index blind spot is untouched and separately filed.

**Reverse-names tie-break comment corrected.** "the naming pass is injective in
practice" was contradicted by the 416r.13 singleton arm at `:5669`, which
DELIBERATELY aliases a `load ptr, ptr @"jl_global#N"` dest to the global's name.
The truth, now stated at the site: every collider in that class is a ROOTLESS
load, so `_root_scale` returns `nothing` for all of them and first-wins is
arbitrary but harmless *for that class* — and would not be for a collider with
differing roots, of which none exists today.

**Test (D) scope corrected.** "the CW-D4 split is GONE" now reads: gone for this
object and for every object whose allocation root this function can see;
rootless / scale-unknown pointers remain constrained only by p06b's (P5), and
only where an aggregate store targets them.

**D5 folded in.** The re-authored `test_vbv9` K=1 "cell is unchanged" assertion
was a tautology (filter `offset_bytes == 0`, then divide it). Deleted, with a
comment saying why and pointing at `test_bvmd_root_scale` (H) for the real K≥2
property — and replaced with a **load-bearing** assertion on the fixture's other
node, the field GEP at byte 24, which must resolve to arena cell **+24** (byte
tier) and not word cell +3.

### Residuals (bead recommendations)

* `Bennett-z2ia` — re-scope, do not close: the STATIC case is closed by the
  use-directed normalisation; **dynamic-`n` allocas** are still refused (needs an
  emitted `IRBinOp(:mul, n, 8)` + `DynAlloca` arity work in BVM).
* `Bennett-4y0d` — closable (K≥2 arena memcpy is byte-true; gate (H)).
* NEW — **the gate-backend refusal.** `lower()` now refuses a byte-normalised
  ParsedIR (`_bvmd_reject_normalised_alloca!`). Removing it means relaxing the
  shadow-tape width checks in `_lower_store_via_shadow!`,
  `_emit_store_via_shadow_guarded!`, `_lower_store_via_shadow_checkpoint!`,
  `_lower_load_via_shadow!`, `_lower_load_multi_origin!` and
  `_pick_alloca_strategy` to span `width ÷ elem_width` consecutive slots. Sound
  (the bit range is already identical) but a core gate-backend change with its
  own gate-count obligations — file it.
* NEW — **cross-function scale coherence.** `_check_scale_coherence!` is
  per-function, so nothing in it constrains a pointer that crosses a call
  boundary; the callee sees a scale-UNKNOWN parameter. That is exactly why the
  access re-stamp failed and the reservation widening did not, and it means the
  `bennettvm-jb6w` "callee word-addresses a byte-tier cell" hazard remains
  wholly with the closed-world check. Disclosed, not closed.
* NEW — **(SC) capacity half.** The stream check enforces scale agreement ALONE;
  it only REPORTS the reservation size. An in-scale but out-of-reservation access
  is untouched, and enforcing it would fire on `Bennett-uiqq`'s alloca
  under-reservation. File separately.
* NEW — **scale-unknown roots.** A root reached through memory (pointer stored
  and re-loaded), a `phi`/`select` pointer, or a `julia.gc_loaded` launder yields
  `nothing` and (SC) is silent. Same residual class as `_p06b_alias_group`'s
  same-slot closure. This is why (P5) had to be retained, not skipped.
* `Bennett-zdd6` — the union rule closes the `bennettvm-jb6w` clang-spill hazard
  **where the spill has a provable root** (provenance beats the literal-struct
  type predicate); re-scope to the rootless case rather than leave it open as
  stated.
* `bennettvm-9n3y` — dangling in both trackers. **CORRECTION (hostile review):**
  an earlier draft of this entry said "the last pinned string in `test_p06b` is
  gone". FALSE — only the (N3) pin went with the retired reject text.
  `test_p06b_aggregate_store.jl:275` (testset (d), the (P1) header reject) and
  `:374` (testset (g4), the (P5) granularity reject) still pin `occursin("9n3y",
  msg) || …`, and (P1)'s own message still carries the string. Those pins are
  deliberately NOT touched here — (P1) was required to stay intact, and
  re-pointing a live marker at `Bennett-zdd6` is a separate, reviewable edit.
  Purge in a doc pass.
