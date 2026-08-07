# Worklog chunk 105 — 2026-08-07 — Bennett-57hd 3+1: the VALUE-IDENTITY contract (ADR 0017 §4b)

Chunk 104 closed at 146 lines but this session's entry is ~185, which would put
it past the ~280-line cap, so starting 105 per CLAUDE.md §0.

## Session log — 2026-08-07 — Bennett-57hd: 3+1 ADJUDICATION + IMPLEMENTATION — wall 10 CLEARED, ADR 0017 §4b (the THIRD admission contract)

**Role:** implementer in the full 3+1 (two blind proposers A and B, implementer
adjudicates, orchestrator ratifies). Phase 1 adjudication, then Phase 2
implementation. HEAD at start `97a188c`. Serial
`julia --project --check-bounds=yes`. **No commit.**

### THE FINDING (F1) — and it reframed the entire bead

Proposer B's headline claim, which contradicted the scout's central framing,
**verified independently two ways**:

> **`%L21` and `%L43` are ALREADY ADMITTED by the shipped `_foz5_confined_dead_bounds`.**

* predicate level — the shipped §4a predicate returns `true` on **both**
  coercions of both clusters (their `sub` uses are `icmp ult`; clause (iii)
  satisfied exactly);
* end to end — with only the wall-10 cluster admitted and `%L16` excised to
  sidestep walls 11–14, the whole root extracts **`NO WALL`** (19 blocks).

So the true partition is **583s: 2 / foz5 §4a: 3 / new: 1**, and the third
contract covers **1 of 1**, not 1 of 3. The scout's "α covers 1/3, δ′ covers
3/3, neither dominates" came from comparing two *prototypes* against
`_memdata_root`; **nobody ever asked the shipped §4a predicate about those two
clusters.** A CORRECTION ADDENDUM is appended to `docs/design/57hd_scout.md`
(the body is left unmutated), and the corrected table ships as executable gate
**(S)**.

**The methodological rule this yields:** when you claim a shape needs a new
contract, evaluate **every shipped contract's own predicate on it**, not your
prototypes against each other. A table-shaped gate catches this; prose does not.

### BOTH PROPOSERS GOT EXACTLY ONE THING WRONG

* **A**: its §0/§1.7 coverage table prints `foz5 = false` for `%L21`/`%L43`
  (measured **true**), so its whole "defer δ′ until walls 11/12 clear"
  sequencing argument rests on the error. Its `_57hd_disjoint` is also **unsound
  without an ordering rule**: it declares a `noalias` call result disjoint from
  *any* other root, including one derived from that object later.
* **B**: it calls δ′'s 2-cluster overlap "a steal in the exact sense binding
  constraint 2 forbids". Measured: **583s and foz5 already both claim `%L46`
  and `%L58` today**, harmlessly — `||`-disjunct overlap is not the forbidden
  thing; widening `_memdata_root` is. B also wrote that clause (V0) "is not
  load-bearing for the difference theorem". **It is load-bearing for
  soundness** — see below.

Each proposer nevertheless carried something the other lacked, so the merge was
real rather than a pick: **A**'s displacement-zero theorem + the α_k steal
measurement + the entry-pair finding + the correct reading of (V0); **B**'s
attribute-checked premises + the `predates` freshness rule + intra-block-only
scanning + the mandatory non-vacuity VM gate.

### WHAT SHIPPED — ADR 0017 §4b, the VALUE-IDENTITY contract

`_57hd_value_identity_cluster` (`src/extract/instructions.jl`, between the foz5
and jbko blocks; **no existing predicate edited**), as the **third** disjunct of
the ptrtoint arm's ENTRY and ADMISSION. Refusal order 583s → §4a → §4b.

    (V0) certified cell producer (`_foz5_cert_src_kind`), named, unsuppressed
    (V1) every use is a 2-operand i64 `sub` of two ptrtoints, sibling also (V0)
    (V2) both sources in ONE basic block, `_57hd_canon` reduces them to ONE value
    (V3) every forwarded store targets a P06B-CERTIFIED CELL POINTER

**THEOREM:** the difference is `0` in native and `0` in BVM on every input under
**any** map φ from addresses to cell values. 583s needs φ translation-cancelling
within a region; jbko needs φ injective; **§4b needs nothing of φ.** It is the
strongest of the three contracts, so §4a's conditioning clause is **satisfied,
not voided**, and jbko's trajectory correspondence is preserved by construction.
Both columns of the failure matrix are bounded — the ADR section has no
"what is NOT guaranteed" paragraph, and that absence is the point.

### FOUR THINGS THAT ARE NON-OBVIOUS AND COST TIME

1. **CLAUSE (iv) IS MINE, AND IT CLOSES A HOLE BOTH PROPOSALS LEFT OPEN.**
   §4a clause (i)'s own disclosure says it "does not provide sentinel-freedom
   for load-sourced values". That hole is one hop up for a copy analysis: the
   walk could "prove" a copy step through a store the extraction never
   materialises as cells. Requiring `_p06b_cell_ptr_target_kind(root) !== :none`
   on every forwarded store closes it. Measured corpus-satisfied:
   `%"new::Array"` certifies `(:gcalloc, 24)`.

2. **(V0) IS LOAD-BEARING FOR SOUNDNESS, NOT HYGIENE.** The reachable hazard is
   the ASYMMETRIC pair. A ptr `phi` carries the cc0 M2b WIDTH-0 SENTINEL, so
   coercing it reads a NEVER-MATERIALISED cell (ADR 0018 §E ⇒ `0`). If the walk
   forwards the *other* side's load to that same phi, `canon` agrees while one
   cell holds `φ(p)` and the other holds `0`: native `p − p = 0`, VM
   `0 − φ(p) ≠ 0`. A SILENT MISCOMPILE. `x − x = 0` is a statement about the
   THEOREM and says nothing about two cells. Gate (M).

3. **α_k (the "obvious" generalisation) STEALS, and gains nothing.** Stripping
   `getelementptr i8` chains and canonicalising the bases claims **both**
   clusters 583s owns (`%L46`, `%L58`) and is still `false` on `%L21`/`%L43` —
   the barrier is the CALL, not the displacement. Displacement zero is the
   design. Recorded as a NON-GOAL in the arm docstring and in the ADR.

4. **THE ENTRY DISJUNCT IS LOAD-BEARING AND IT WAS MEASURED.** `.ll` surgery
   admitting only `%12` walls immediately on `%13` in the **jbko** arm ("found a
   use that is a `sub`, not an icmp"), because `%13`'s source has
   `_memdata_root === nothing` and fails §4a clause (iii). A cluster is a PAIR.
   Gate (P).

### GOTCHAS MEASURED THIS SESSION (each cost a cycle)

* **LLVM AUTO-POPULATES INTRINSIC ATTRIBUTES.** Deleting `nocapture` from
  `declare void @llvm.memcpy…` in a fixture has **NO EFFECT** — the parsed
  declaration has it back. The `nocapture` call-site-vs-declaration gate must be
  put on an ORDINARY callee. Gates (F2)/(F3)/(F4).
* **A PROBE THAT REGISTERS ONLY NON-EMPTY LLVM NAMES MEASURES A DIFFERENT
  PROGRAM.** The corpus's `%13` coerces `%7`, an UNNAMED instruction whose
  `LLVM.name` is `""`. Filtering on `isempty(n)` makes `haskey(names, …)` false
  and reports `vi = false` for the very cluster the pipeline admits. The
  emission walk registers EVERY instruction (`_auto_name`). This silently broke
  gate (S) until found.
* **`julia.get_pgcstack` HAS NO ATTRIBUTE GROUP AT ALL**, so the attribute-driven
  effect table classifies it `:unknown` — and the corpus witness survives anyway,
  because it lies outside every clobber window. The design refuses to *assert*
  that it writes nothing, which is the honest position.
* **`julia.gc_alloc_obj` really does carry `memory(argmem: read,
  inaccessiblemem: readwrite)`** (encoded `0b001101`) and `noalias` on both call
  site and declaration, so both premises are genuinely CHECKED. `llvm.memcpy`
  carries `memory` on the DECLARATION only — the two-step fallback is required
  for both attributes, not just `nocapture`.
* **A SEVENTH MARKER SITE.** `test_sy29_arena_src_memcpy.jl` gate (i) carries a
  corpus-advance assertion the scout's six-site list omits, and its
  `!occursin("Bennett-37mt")` negative FLIPS — because **wall 11 is also a 37mt
  reject**, word for word the one sy29 cleared at wall 9. Only the quoted
  operand differs (`%"new::Array.ref.mem"` vs `%"new::Array.size_ptr1"`). sy29's
  own lesson, applied to sy29's own gate.

### THE ONE UNSOUNDNESS THIS ARC FOUND BY REVIEW, NOT BY PROBE

`_p06b_slot_key` deliberately stops at a VARIABLE index and makes that GEP its
own root — sound for the KEY (two runtime-indexed addresses cannot be proven
equal), but a **disaster for DISJOINTNESS** if taken literally. A
`getelementptr i8, ptr %a, i64 %i` store into a NON-ESCAPING `alloca %a` gets
the GEP as its footprint root, and the `:alloca` + non-escape rule then declares
that write **DISJOINT FROM `%a`** — skipping a write straight into the tracked
object. Both proposals had this. **MEASURED RED** on the distilled fixture
before the fix: `PRE-FIX a => true`, `b => true` (i.e. ADMITTED). Closed by
`_57hd_underlying` (walks GEP / bitcast / addrspacecast bases): two roots with
the same underlying object are **never** disjoint, whatever their spellings.
Gate (C2). The general lesson: **a canonicalisation tuned for EQUALITY is not
automatically valid for DISJOINTNESS** — the two use the same key in opposite
directions, and "stops the walk" is conservative for one and permissive for the
other.

### O-1 — THE RISK NEITHER PROPOSAL NAMED, AND ITS MITIGATION

The `memory` attribute's value is a **raw packed integer** whose encoding is
LLVM-internal and NOT a stable API (Rule 5). A future re-encoding that decoded
to "writes nothing" would be **silently unsound**. Mitigations, ratified as
mandatory: `_57hd_writes_no_ir_memory` **fails closed on any bit outside the
three locations LLVM 18 defines** (`0b111111`), and two DECODE CANARIES that
must move in OPPOSITE directions — gate (D2) `memory(argmem: readwrite)` must
REJECT, gate (D3) `memory(none)` must ADMIT. A decoder that fails closed on
everything passes (D)/(D2) and fails (D3); one that reads "writes nothing" for
everything passes (D3) and fails (D2). Attribute kind ids are looked up by name
on every call rather than `const`-cached, so precompilation cannot bake one LLVM
build's numbering into the `.ji`.

### WALL SEQUENCE, MEASURED FOUR DEEP

11 = `Bennett-37mt`/`8bys` `.mem` src memcpy (corpus site #4) — **the new wall**;
12 = `Bennett-p06b` `alloca { ptr, ptr }` silent-skip, LOUD, and its message
does **NOT** contain the string `Bennett-1zow` (a marker written against that
bead tag would never fire — write it against `SILENTLY SKIPS` /
`_p06b_cell_ptr_target_kind`); 13 = a second 37mt/8bys memcpy (non-integer
element type); 14 = `Bennett-bvmd` `SCALE-COHERENCE` on the 9×i64 closure
alloca. **`%L21`/`%L43` are NOT future walls** (F1).

### RESULTS

* `test/test_57hd_value_identity.jl` — **84/84**, gates (A)(A2)(P)(B)(C)(C2)
  (D)(D2)(D3)(E)(F2)(F3)(F4)(G)(G2)(H)(H2)(I)(J)(K)(L)(M)(N)(O)(Z)(S)(W), all
  RED-first (C2's red measured by temporarily disabling the one-line fix).
* `BennettVM/test/test_57hd_value_identity_vm.jl` — **107/107**. `d == 0`
  EXECUTED, non-vacuity mandatory (both coerced cells non-zero, equal, and equal
  to the address the aggregate store wrote; the other header field different),
  the escape live into an `IntrinsicGCAlloc` **size** operand and a `VarGEP`
  address, oracle-exact, L2+L3, exact `unrun!`, per-step inverse.
  **Zero BennettVM `src/` change — the streak reaches ten.**
* **FULL SUITES, implementer-run, verbatim.**
  `Bennett       | 691943       3  691946  28m49.6s` / `Testing Bennett tests passed`
  (baseline at HEAD `97a188c` was `691832  3  691835`; **delta +111 Pass**,
  which reconciles EXACTLY: 84 new-file gates + 27 marker-site additions
  = foz5 4 + bvmd 4 + p06b 4 + vau9 4 + 40ys 4 + 7wsz 4 + sy29 3. The 3 Broken
  are pre-existing.)
  `BennettVM     | 10963  10963  4m26.3s` / `Testing BennettVM tests passed`
  (baseline at sy29 was `10835  10835`; **delta +128**, which also reconciles
  exactly: 107 gates in the new file + 21 from ONE more re-run of the M8.2
  `test_per_step_inverse.jl` scaffold self-tests. That scaffold is `include`d
  unguarded by six BVM test files already — the house convention, and the
  source of the `Method definition … overwritten` warnings — so the new file
  follows it rather than inventing a guard.)
* Eleven exposed files re-run and diffed: 583s 28→28, jbko 73→73, 37mt 86→86
  (byte-identical); foz5 63→67, bvmd 84→88, p06b 617→621, vau9 69→73,
  40ys 128→132, 7wsz 106→110, sy29 91→94 (marker advance, +4/+3 each).
