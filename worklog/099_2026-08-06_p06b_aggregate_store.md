# Worklog chunk 099 — 2026-08-06 — p06b whole-aggregate store decomposition (xkl wall 6)

## Session log — 2026-08-06 — Bennett-p06b ARC CLOSE (orchestrator): three hostile-review rounds — FAIL → FAIL → PASS-WITH-CONCERNS; landed

Orchestrated serially: 2 blind proposers → implementer → hostile review
(FAIL: D1/D2 P0s, D1b/D3 P1s, D4 P2, D5-D8) → fix cycle 2 (+ the pdqx
escalation, resolved by measurement: a reserved-regions bounds check CANNOT
catch adjacent-allocation clobbers — no region table in BVM, three monotone
cursors; the :load capacity became the DISCLOSED khb2 residual) → re-review
(FAIL: N1 P0 capacity-mirror drift, N2 P1 alias-key defeat by duplicate
GEPs, N3 P1 gc_alloc_obj granularity mismatch) → fix cycle 3 (shared
_alloca_reservation single-source-of-truth; canonical (root, byte-offset)
slot keys; gc_alloc_obj refused) → delta re-review (PASS-WITH-CONCERNS,
one P3 comment fix applied by the orchestrator).

### Arc lessons (bank these)

1. **A fix is a new code path and deserves the same adversarial probing as
   the original** — all three round-2 defects were IN the round-1 fixes.
2. **Half-sharing is not sharing**: N1 happened because the capacity logic
   was MIRRORED next to a docstring claiming single-predicate discipline.
   The fix derives both consumers from one helper (_alloca_reservation),
   differentially proven over 25 shapes × both gate states.
3. **Prose-vs-predicate rule held its weight three rounds running** (also
   banked as a bd memory): every fail-loud message now cites its enforcing
   predicate; the khb2 residual is pinned as a KNOWN-ADMITTED test with a
   flip-don't-delete banner, so closing it is a deliberate red.
4. **optimize=false emits duplicate identical GEPs** (Rule 5 corollary) —
   any use-scan keyed on operand SSA refs is defeated by redundancy;
   canonicalise to (root, total-const-offset) before grouping.

### Gates (arc close)

- FULL Pkg.test, both repos, on the landing tree: Bennett.jl PASSED
  (exit 0; round-2 full run on the near-identical tree: 691487 Pass /
  3 Broken pre-existing, 29m11s); BennettVM PASSED (exit 0). Gate-count
  39/39. test_p06b 624/624; BVM E2E 179/179.

### Beads (arc)

- CLOSED: Bennett-p06b. Filed: Bennett-1zow (P2 alloca silent-skip),
  Bennett-khb2 (P2 :load capacity residual), Bennett-uiqq (P2 alloca count
  discard), Bennett-0si3 (P2 D1b threading pin), Bennett-po93 (P3 runtime-GEP
  key merge); BVM: bennettvm-pdqx (amended — spec wrong for clobbers),
  bennettvm-p4r4 (P3 IRInsertValue agg_dests guard).
- Frontier: wall 6 CLEARED → **Bennett-foz5** (wall 7; heed the a8nw
  ordering note on the bead) and **bennettvm-rxgy** (VM side).

## Session log — 2026-08-06 — Bennett-p06b: `store {ptr,ptr}` decomposes into per-field cell stores (xkl wall 6) — hostile review FAILED, fix cycle landed; pdqx sub-question ESCALATED

CORE 3+1. Two blind proposers (`docs/design/p06b/proposal_A.md`,
`proposal_B.md`) converged on the mechanism; this session is the IMPLEMENTER
half. Orchestrator gates the commit after a hostile review. **Nothing was
committed.**

### What landed

One new arm in `src/extract/instructions.jl`, between the ADR 0020 D3
`PointerType` cell-store arm and the Bennett-lgzx / U114 `IntegerType` reject.
Under `ptr_cells`, `store <S> %agg, ptr %p` (S an unpacked StructType) becomes,
per field k: `IRExtractValue(fk, agg, k, 0, N, fw)` +
`IRPtrOffset(ak, p, LLVMOffsetOfElement(S,k), 64)` + `IRStore(ak, fk, 64)`.
Zero new `IRInst`, zero BVM src changes (sixth bead in a row). BVM E2E
179/179.

**EIGHT** fail-loud predicates as shipped (the first draft had six and the
worklog miscounted them as "six" while listing seven rows — corrected here),
in evaluation order (type-shape first, then target, then value — so a
`store {} zeroinitializer` reports the 6bu3 empty-struct reason, not the value
reason). Every row names the predicate that ENFORCES it, per the reviewer's
prose-vs-predicate rule:

| # | guard | enforcing predicate | names |
|---|---|---|---|
| P1 | LITERAL `{i64,ptr}` GenericMemory header | `_is_genericmemory_header_struct` | **Bennett-p06b** |
| P2 | field certification | `_struct_field_widths` (reused verbatim) | Bennett-6bu3 |
| P3 | every field 64 bits at byte offset `8k` | the `fw[k+1]==64 && off_k==8k` loop | **Bennett-p06b** |
| P4a | target is a registered SSA name | `haskey(names, ptr.ref)` | **Bennett-p06b** (was lgzx-verbatim — D5) |
| P4b | target is a CERTIFIED, NON-SUPPRESSED cell pointer | `_p06b_cell_ptr_target_kind` | **Bennett-p06b** |
| P4c | target CERTIFIABLY RESERVES ≥ N cells | `_p06b_alloca_cells` / `_p06b_call_bytes` | **Bennett-p06b** (D1) |
| P5 | no conflicting-granularity use, across sibling re-loads | `_p06b_granularity_violation` / `_p06b_alias_group` | **Bennett-p06b** (D2/D3) |
| P6 | value is an `insertvalue` whose CHAIN ROOT is certified | opcode test + `_p06b_agg_chain_root_violation` | **Bennett-p06b** (D4) |

**(P5) is per-SSA-value plus its sibling-load alias group — NOT object-scoped in
general.** The first draft's worklog described it as if it were object-scoped;
it was per-SSA-value and the reviewer's `probe1_realias` walked straight through
it. What ships now closes the same-slot re-load closure and nothing wider; see
the residual list.

### Adjudications where the two proposals diverged

**Value operand — took A's narrow `insertvalue`-only (P6), rejected B's
"SSA aggregate or zeroinitializer".** BVM's contract is the authority, and it is
narrower than "SSA aggregate": `ingest.jl:521` builds `agg_dests` from
`IRInsertValue.dest` / `IRInsertBits.dest` / value-ABI multiret call tokens
only, and `ingest.jl:784` fails loud on an `IRExtractValue` whose agg is not in
it. MEASURED (probe 3): a `load { ptr, ptr }` is SILENTLY SKIPPED by the load
arm while `module_walk.jl`'s naming pass has already registered its dest — so
B's "SSA aggregate" test would have emitted an extractvalue against a
never-built slot family, loud in the WRONG repo with the WRONG bead name.
`zeroinitializer` additionally needs a DIFFERENT emission (`ConstOperand(0)` per
field, no extractvalue) and has no corpus witness; deferred with a loud named
reject.

**Target — synthesised: A's positive whitelist AND B's granularity guard.** (The
first draft said "both NARROWED"; that overclaimed — B's granularity guard was
adopted as-is and then *widened* by the D3 sibling-load extension, while only
A's whitelist was narrowed. Corrected.) B's granularity finding is real and A did not cover it: A's (P5)
only refuses the `{i64,ptr}` header, but the measured split is on a `{ptr,ptr}`
object (`%"new::Array"` is byte-addressed at 8/16 AND struct-addressed at fields
0/1), which A's whitelist ADMITS via its `:call` entry. So both guards ship.
Then I narrowed A's whitelist on two further hazards A did not cover:

* **`:call` is a NAME whitelist, not "a call returning a pointer".** The
  `julia.gc_*` benign-prefix drop (`instructions.jl:~3815`) returns `nothing`
  for e.g. `julia.gc_loaded` while its dest name stays registered — the same
  dangling-cell class as F8. Admitted set: `_M4_C_ALLOCATOR_NAMES`
  (malloc/calloc/realloc) ∪ `julia.gc_alloc_obj`.
* **`:load` requires its OWN pointer operand to be registered.** A
  `load ptr, ptr @"jl_global#N"` (bennettvm-416r.13 singleton) emits NOTHING and
  ALIASES the dest name to the global; a load off an unregistered pointer is
  silently skipped. Both would leave a dangling cell.
* **`getelementptr` and pointer `Argument` DROPPED from A's whitelist.** A GEP
  target means the aggregate is nested inside a larger object, and then (P5)'s
  use scan over the GEP RESULT says nothing about the PARENT's addressing —
  a hazard A's §3 condition 2 does not close. A pointer Argument has TWO models
  in `module_walk.jl` (`dereferenceable(N)>0` = flat wire array; `deref==0` =
  ADR 0020 D2 opaque cell) plus the dv1z-claimed sret param. Both refused with
  named deferrals rather than discriminated on no corpus witness.

**Sub-cell fields — took B's `fw[k]==64 && off==8k`, rejected A's "any
certified field width".** A would admit `{i8,i64}` and emit `IRStore(…, 8)`.
BVM's `MemoryStore` writes a WHOLE cell, so that is only sound modulo "padding
is never read" — an argument about what NO OTHER access may name, which this arm
cannot check outside its own function. Under B's rule the fields TILE `[0,8N)`
with no padding at all and the exactness argument is unconditional. `{ptr,ptr}`
(corpus) and `{i64,i64}` (gate witness) both pass; `{i32,i32}`, `{i64,i8}`,
`{i8,i64}` are loud p06b rejects.

**Placement — no real divergence**; both put the arm between D3 and the lgzx
reject, which is what makes `ptr_cells=false` byte-identical BY CONSTRUCTION
rather than by inspection. Kept.

**General N, not `{ptr,ptr}`-only** — both proposals agreed and both were right:
the loop is identical for N=2 and N=k, and (P3) does all the narrowing. A
`length(fw)==2` guard would be extra message territory that no mutation test can
prove load-bearing.

### `_alloca_type_is_modelled` — the one live-arm touch

p06b needs "is this alloca's allocated type modelled?" and the alloca arm needs
the same predicate. A duplicated mirror WILL drift (proposal_A R5). Extracted it
as a named predicate and wired it into the alloca arm as ONE short-circuit line
at the top: `_alloca_type_is_modelled(elem_ty, ptr_cells) || return nothing`.
**Provably behaviour-preserving** — every type it short-circuits already fell
through to a `return nothing` below (nested ArrayType at the `inner isa
IntegerType` test; PointerType-with-gate-off / float / struct at the
`elem_ty isa IntegerType` test). Re-ran the whole alloca family
(munq 69/69, ixiz 53/53, haiy 26/26, nd45 39/39) to pin byte-identity.

### GOTCHAS worth writing down

1. **The bead's "TWO live aggregate stores at L93" is WRONG for the pipeline the
   converter walks** (both proposers found this independently; measured again
   here). Post-`["sroa","mem2reg"]` — which `_module_has_sret` prepends at
   `entry.jl:104-108` — `_growend!` has EXACTLY ONE live aggregate store. SROA
   eliminates the sret staging alloca and its 8-byte memcpy; the `%oob*`
   siblings are in Bennett-utzc-pruned dead blocks; the `[1 x ptr]` boxes are
   too, so **no ArrayType aggregate store is live** and this arm is
   StructType-only. **Size the work off the POST-pass dump, never the raw one.**

2. **The blanket `!occursin("ptrtoint", msg)` wall-marker negative is now
   UNEXPRESSIBLE and has been RETIRED in all three markers.** The successor wall
   (Bennett-583s) message CONTAINS the word `ptrtoint`. Replaced by ARM-scoped
   negatives (`Bennett-iwo9`, `type-tag`) — what jbko actually cleared — plus the
   new p06b load-bearing negatives (`Bennett-lgzx`, `store of non-integer type`,
   `Bennett-p06b`). **Design the negative around the ARM you cleared, not the
   OPCODE.** All three markers (vau9 g, 40ys I, 7wsz J) went RED on landing and
   were advanced in the same change — the first time all three tracked at once.

3. **`!occursin("Bennett-p06b", msg)` is the load-bearing half nobody would think
   to add.** It proves the corpus store was ADMITTED, not re-rejected under a new
   name — the assertion that catches an over-tight (P3)/(P4)/(P5)/(P6). Every
   new p06b message is checked mechanically against a `_P06B_FORBIDDEN` tuple of
   every substring that is some OTHER marker's load-bearing negative, so a new
   reject cannot silently satisfy another marker.

4. **Fixture datalayout gotcha (proposal_A probe 9, reconfirmed).** A hand-written
   `.ll` with NO `target datalayout` gets LLVM's default, where `i64` has ABI
   alignment **4** — so mixed-width structs land fields at the wrong offsets and
   offset assertions test the wrong layout. Declare
   `"e-p:64:64:64-i64:64-n8:16:32:64-S128"`. The long x86-64 string with
   `p270:0:32` is REJECTED by this LLVM ("Invalid pointer size of 0 bytes").

5. **The gate witness must have ALL-INTEGER fields.** A `{ptr,ptr}` fixture at
   `ptr_cells=false` rejects EARLIER, at the 6bu3 pointer-field guard on the
   `insertvalue`, so it does NOT witness that the STORE arm is gated.
   `@p06b_2x64_gate` (`{i64,i64}`) is the correct witness: its `insertvalue`s
   certify at both gate settings, so the store is the only gate-dependent
   construct.

6. **`ptrtoint ptr %malloc_result` is NOT admissible in a BVM E2E fixture.**
   jbko's source whitelist is `extractvalue`-of-struct-ptr-field or `load ptr`
   only, so a `call`-produced pointer rejects. Compare pointers with
   `icmp eq ptr` (the Bennett-8g7m arm) instead — which is also the better test,
   since it reads the fields back through the D3 pointer-load arm.

### The new frontier: wall 7 = Bennett-foz5

MEASURED on the real gated path after the arm landed (both proposers forecast
this and both were right):

```
SET WALL: … extraction FAILED for callee `#_growend!##0#a7027856` …
  — ir_extract.jl: ptrtoint in @julia_#_growend!##0_1048:%idxend41:
    %94 = ptrtoint ptr %memory_data53 to i64
  — ptrtoint of a GenericMemory .data base under ptr_cells whose result is NOT
    confined to a same-Memory base-cancelling bounds check … (Bennett-583s / CW-D)
```

Root cause (proposal_B §6, read off the IR): `%idxend41` cancels two
`ptrtoint`s whose bases have DIFFERENT syntactic roots — `_memdata_root`
(`instructions.jl:245`) seeds only on "`load ptr` of a `{i64,ptr}` field-1 GEP",
so the CLOSURE-CAPTURED `MemoryRef.ptr_or_offset` half never matches. The
structurally identical check at `%L58` passes today because both sides root at
`%memoryref_mem`. **Wall 7 is a root-RECOGNITION widening of 583s, not a new
capability class** — Bennett-foz5 as filed.

### Follow-on beads for the orchestrator to file

1. **`alloca` with an unmodelled allocated type silently registers a dangling
   name** (P2). `_alloca_type_is_modelled` now names the set; the arm still
   `return nothing`s instead of failing loud, which is a live CLAUDE.md §1
   violation independent of p06b. Fixing it changes gate-OFF behaviour, so it is
   deliberately not in this bead.
2. **Admit the `{i64,ptr}` GenericMemory-header aggregate store** under the
   byte-granular stamp (P3). Mechanism is one line
   (`ew = _is_genericmemory_header_struct(vt) ? 8 : 64`); the missing piece is
   the 416r.13 singleton-header interaction argument.
3. **Admit `store <S> zeroinitializer`** as N zero-cell stores (P3) — needs the
   `ConstOperand(0)`-per-field emission path, not the extractvalue path.
4. **Widen the p06b target whitelist to GEP-rooted and pointer-ARGUMENT targets**
   (P3) — each needs its own hazard argument (parent-object granularity for GEP;
   the deref-buffer / sret-param three-way discrimination for arguments).
5. **`_struct_field_widths` ignores field ADDRSPACE** (P3) — a
   `{ptr addrspace(10), ptr}` field is stamped 64. Pre-existing 6bu3 gap,
   inherited not created; p06b guards only the TARGET's addrspace.
6. **Sub-cell aggregate stores** (`{i64,i8}` read-modify-write) (P3) — refused by
   (P3) today with a message that states the reason.

### Verification (all `--check-bounds=yes`, ONE process at a time)

Bennett.jl: p06b 348/348 · vau9 66/66 · 40ys 124/124 · 7wsz 102/102 ·
jbko 73/73 · 583s 28/28 · 6bu3 161/161 · ares 56/56 · zf5v 16/16 ·
lf14 22/22 · nd45 39/39 · 59zi 547/547 · haiy 26/26 · beaw 16/16 ·
utzc 31/31 · lgzx 4/4 · munq 69/69 · ixiz 53/53 · d1b 33/34 +1 broken
(pre-existing) · 416r.12 25/25 · 416r.13 16/16 · 416r.16 40/40 ·
416r.17 28/28 · **gate-count regression 39/39**.
BennettVM.jl: p06b 179/179 · jbko 175/175 · vau9 267/267. **ZERO BVM src
changes.**

Full `Pkg.test()` in both repos is the orchestrator's gate, not run here.


---

## Session log — 2026-08-06 (later) — Bennett-p06b hostile review: FAIL → fix cycle

Reviewer verdict: the four narrowings were verified faithful and sound; the
holes were one level up. **Two guarantees were asserted in error text and in
this worklog that were not predicates at all** — and both proposals shared the
gap, so neither proposer would have caught it. That is the lesson worth banking:

> **PROSE-VS-PREDICATE.** A fail-loud message states a guarantee. If no line of
> code checks that guarantee, the message is a lie that reads like a proof, and
> it is worse than silence because it stops the next reader from looking. Every
> new reject in this arm now cites the predicate that enforces it.

### D1 (P0, SILENT MISCOMPILE) — capacity was never checked

(P4) certified that the target's producer *would emit an `IRAlloca`*, never that
it *reserves ≥ N cells at width 64*. Executed witness (scratchpad `e2e2.jl`):
`alloca i64` (ONE cell) + a decomposed 2-field store clobbers the next
`StackAlloca` — **EXPECTED 999, ACTUAL 42, no error**; `e2e3.jl` shows the same
on the malloc tier. Fixed statically by `_p06b_alloca_cells` /
`_p06b_call_bytes` (P4c): `:alloca` needs `elem_width == 64` and a
**ConstantInt** count ≥ N; `:call` needs a ConstantInt size ≥ 8N. A runtime
count, a non-constant allocator size, and `[K x i8]` (BYTE cells, not word
cells) all certify capacity 0 ⇒ reject.

**The `:load` half did NOT get fixed and is ESCALATED — see below.**

### D1b — certification must consult what the walk EMITTED

`module_walk.jl` names every instruction, but the emission loop `continue`s past
`sret_writes.suppressed` / `.call_return_suppressed` /
`consumed_sret.suppressed`. A target rooted at a suppressed box alloca therefore
certified under the type rules with **no `IRAlloca` ever emitted**. Fixed by
threading the union of those three sets into `_convert_instruction` as
`suppressed_refs` and refusing any target in it. Gotcha for future arms: **in
this extractor, "registered SSA name" is not evidence of anything.** Three
separate defects in this bead (F8, D1b, and the `:call`/`:load` drop cases) are
all instances of that one mistake.

### D2 — the index-0 GEP carve-out was a hole, not a carve-out

The accepted 2-op index-0 GEP emits `IRPtrOffset(_, _, 0, 8)` — a **fresh
BYTE-granular base** the one-level use scan never followed — so
`gep i8, ptr %g0, 8` off it re-derived byte-cell 8 while the store wrote cell 1:
exactly the 9n3y split (P5) exists to refuse (`probe2_gep_of_gep`). My own
measurement already said refusing costs zero frontier progress, so the carve-out
bought nothing. **Dropped entirely.** Verified: the corpus target's uses are
3-op struct GEPs, unaffected, and the wall still clears.

### D3 — the granularity scan was SSA-scoped, not object-scoped

Two `load ptr, ptr %root` of the same slot give two SSA names; the scan over one
never saw the other's byte GEP (`probe1_realias` / `probe25`). This is the
canonical **GC reload-after-safepoint** shape, i.e. live corpus territory.
`_p06b_alias_group` now extends the scan to every other pointer-result `load` in
the function with the same pointer-operand ref. **Honest limit, stated in the
arm and not more:** that closes the same-slot re-load closure and nothing wider.

### D4 — (P6) checked only the outermost `insertvalue`

`insertvalue %loaded_agg, …` was admitted (`probe14`), and since BennettVM's
`IRInsertValue` has **no `agg_dests` guard of its own** (only `IRExtractValue`
does), it died as a contextless `KeyError` in the wrong repo.
`_p06b_agg_chain_root_violation` now walks the chain and requires a
`zeroinitializer` / `undef` / `poison` root. **Measured while writing the
fixture:** an `undef`-rooted chain never reaches p06b at all — the 6bu3
insertvalue arm resolves its aggregate through `_operand`, whose Bennett-bjdg /
U80 guard rejects `undef` first. So the only *reachable* certified root is
`zeroinitializer`; the test pins that reality rather than the predicate's
nominal set.

### D5 — the lgzx-verbatim P4a reuse was reachable

Rule 12 said "don't mint new message territory"; it was the wrong call here.
The reuse is reachable **on p06b shapes**, it escaped the (h) hygiene sweep *by
construction*, and the three advanced wall markers use `!occursin("Bennett-lgzx")`
as a **load-bearing negative** — so a P4a firing on the corpus would have been
misattributed to the store-type wall. Now p06b-named, and the cross-reference is
worded WITHOUT the literal `lgzx` / `U114` substrings (containing them would
trip the very negatives the change exists to protect). (h) extended to cover it.

### THE ESCALATION — `:load` capacity and what `bennettvm-pdqx` can actually do

Orchestrator chose option (b): land the VM bounds check so the statically
unprovable `:load` extent becomes a loud runtime error. **Measured before
building it, and it does not hold.** All three D1 repros clobber an **ADJACENT
LIVE ALLOCATION**, not unreserved space:

```
e2e2 (STACK): StackAlloca bases [1,2]; live window [1,2]; store wrote [1,2]
              → a "target cell ∈ live reserved region" check ADMITS BOTH
e2e3 (ARENA): arena_top 2; live window [ARENA_BASE, ARENA_BASE+2);
              slot=+0 other=+1; store wrote [+0,+1]
              → ADMITS BOTH
```

So a region-membership predicate — which is what the bead specifies and what the
allocator's cursors can support — catches accesses that leave **all** live
reservations, but **not** cross-allocation clobbers. Rejecting the latter needs
**pointer provenance** (knowing which region the pointer *came from*, not just
which region the address *lands in*), and neither repo has it: BVM locals are
plain `Int64` with no region tag, and a check on the address-arithmetic `Define`
would false-reject every small-integer add in the stack tier `[1, 2^40)`.

**No BennettVM src change was made.** The `:load` capacity remains uncertified
and is now DISCLOSED in the arm, in the test header, and here — as a limitation,
not a guarantee. Options for the orchestrator, unchanged: interprocedural extent
analysis; provenance-tagged pointers in BVM; or drop `:load` and accept that
p06b stops clearing the corpus wall.

### Verification after the fix cycle

Corpus wall **unchanged** — still `Bennett-583s` at `%idxend41` after all five
tightenings, so none of them cost frontier progress.


---

## Session log — 2026-08-06 (round 3) — p06b hostile review round 2: three defects IN THE FIXES

Round-2 verdict: FAIL but converging — all D1-D8 fixes verified genuine, full
Bennett suite green (691487/3B), corpus wall and markers verified independently.
All three new defects were found by **probing the round-1 fixes themselves**,
which is the lesson: *a fix is a new code path and deserves the same adversarial
treatment as the original*.

### N1 (P0) — the capacity predicate MIRRORED the alloca arm and drifted immediately

`_p06b_alloca_cells` read the ArrayType **count operand** that the alloca arm
**discards**. `alloca [1 x i64], i32 4` therefore reserved ONE cell and
certified FOUR; executed clobber (`h1_e2e.jl`) EXPECTED 999 ACTUAL 42.

The bitter part: round 1's own docstring said *"Keeping ONE predicate is what
stops the two from drifting apart"* — and then mirrored anyway, because
`_alloca_type_is_modelled` shared only the **type** test, not the **count**
logic. **Half-sharing is not sharing.** Fixed properly: `_alloca_reservation`
now returns the exact `(elem_width, n_elems)` pair the arm passes to `IRAlloca`,
and BOTH the arm and p06b consume it — the arm body is now three lines. p06b
additionally refuses ArrayType `N != 1` outright rather than trusting the arm's
under-reservation, filed separately as **Bennett-uiqq** (P2) and deliberately
NOT fixed here (it would change gate-off behaviour).

### N2 (P1) — the alias key was SYNTACTIC, so redundant GEPs defeated it

`_p06b_alias_group` keyed on the load's pointer-operand SSA *ref*. Two
**identical** `getelementptr i8, ptr %root, i64 0` instructions give two refs ⇒
two keys ⇒ the group never linked the loads ⇒ the byte GEP went unseen
(`hostile2.ll h14_redundant_gep`: ADMITTED, VM returned 0 where LLVM says 42).
And `optimize=false` — which this extractor **mandates** (Rule 5) — emits
redundant GEPs routinely, so this was not exotic. `_p06b_slot_key` now folds
all-constant-index GEP chains to `(root_ref, total_byte_offset)`. Verified:
h14/h15 reject, h7 still admits, and the **corpus alias group stays size 1**
with the wall still clearing.

### N3 (P1) — `julia.gc_alloc_obj` is BYTE-granular in BVM

Admitted at WORD granularity while BennettVM stamps that tier byte-granular
(`_byte_cells`, `BennettVM/src/ir/intrinsics.jl:256-257`, CW-D4 / 9n3y). A
Julia-idiom field read at byte offset 8 lands on cell `base+8` while p06b wrote
`base+1` — `h17_e2e.jl`: EXPECTED 42, ACTUAL 0. **Dropped from the allocator
whitelist**, for exactly the reason (P1) already refuses the byte-granular
GenericMemory header STRUCT. No corpus witness and no fixture used it, so the
cost is zero. The inconsistency is the tell: p06b refused a byte-granular
*type* while admitting a byte-granular *allocator*.

### Gotcha worth banking (cost a test cycle)

```julia
cond && return
    "a long string" * ...
```
In Julia the newline **ends the `return`** — this returns `nothing`, and a
`::String` annotation then throws a `MethodError` far from the cause.
Parenthesise `return (` … `)` when the value starts on the next line.

### Pins added

* **D1b had no test.** A full `.ll` reaching consumed-sret suppression is
  impractical to hand-write, so this is a **unit test** on
  `_p06b_cell_ptr_target_kind` with a CONSTRUCTED suppressed set — the same
  thing `module_walk.jl` hands it. Pins `(:alloca, 2)` when absent and
  `(:none, 0)` plus the SUPPRESSED wording when present.
* **Bennett-khb2 pinned as a KNOWN-ADMITTED witness** (`p06b_khb2_loadclobber`)
  with a banner saying that this testset going red means someone CLOSED khb2 —
  a deliberate flag, not a regression. Mirrored as a KNOWN-CLOBBER note in the
  BVM E2E header so nobody reads that file as evidence of safety.

### Residual list, consolidated in the arm (N4)

The `:451` cross-reference dangled; the arm's RESIDUAL RISKS block is now the
complete contract — khb2 (`:load` has no capacity proof, the corpus shape),
(P5)'s same-slot-only alias closure and its three named escapes, jb6w, uiqq,
6bu3 addrspace, the unmodelled-alloca silent skip, and the `gc_alloc_obj`
byte-stamped future widening. `runtests.jl` corrected six → eight predicates (N5).
