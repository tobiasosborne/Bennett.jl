# Worklog chunk 098 — 2026-08-04 — vau9 memmove routing (xkl wall 4)

## Session log — 2026-08-04 — Bennett-jbko: ptr-identity ptrtoint arm (xkl wall 5) — LANDED UNREVIEWED at wind-up; hostile review is Bennett-a8nw

⚠️ **READ THIS FIRST, NEXT AGENT**: the jbko implementation is committed with
full suites green (IMPLEMENTER-run: Bennett 690955 Pass / 3 Broken, 30m20s;
BVM 10379/10379; gate-count 39/39) but the arc's HOSTILE-REVIEW step was NOT
run — the user called wind-up. **Bennett-a8nw (P1) tracks the pending review;
do not close Bennett-jbko until it passes.** The review brief (8 open risks)
is in the implementer report; the top items: the DISJUNCTIVE arm entry widens
jbko's message territory vs the generic iwo9 reject; the `:load` source-kind
arm is broader than the corpus needs (bounded by the use gate); transitive
uses are checked one level deep (phi/select-forwarded icmp conservatively
rejects); the phi-ptr width-0-sentinel negative test is the file's most
load-bearing test.

### What landed (5th bead of the 2026-08-03/04 arc; full 3+1, proposers CONVERGED on mechanism (b))

- New arm in instructions.jl (after 583s, pinned disjoint by
  `_memdata_root(src) === nothing`): a `ptrtoint ptr→i64` under ptr_cells is
  admitted as the identity `IRBinOp(:or, src, 0, 64)` IFF the source is a
  CERTIFIED cell-valued ptr SSA (extractvalue of a ptr struct field, or
  load ptr; addrspace 0; NOT phi/select — those carry the cc0-M2b width-0
  sentinel and coercing one silently reads an unmaterialised cell) AND every
  use is `icmp eq/ne` AND the icmp's other side is an SSA cell or zero/null
  (non-zero literals reject). Ordering compares reject NAMING 8g7m — the use
  gate is the ONLY thing preventing an address-magnitude compare laundering
  onto the integer icmp path (8g7m's own guard is type-based).
- Determinism argument (in the arm's comment block): both operands are
  same-trajectory cells of the deterministic injective bump allocator; eq/ne
  is invariant under the address↦cell map; jbko adds ZERO expressive power
  over 8g7m's already-admitted pointer icmp — it only lets the same
  comparison be spelled through a coercion.
- ZERO BVM src changes (fifth in a row). BVM E2E: guard-match runs the ok
  branch, guard-mismatch runs into the ConcurrencyViolationError diamond and
  HALTS at the `:__unreachable__` sink — and `unrun!` STILL returns the exact
  initial state with drained history (a TRAPPED program is fully reversible;
  first time this is pinned anywhere). Allocator injectivity is a runnable
  assertion: first malloc's coerced cell == ARENA_BASE == the captured cell.
- Frontier findings (both proposers, independently, on the REAL gated path):
  the bead's forecast was WRONG — no live sret-reassembly memcpy; the next
  wall is TWO live `store {ptr,ptr}` at L93 (**Bennett-p06b**, wall 6,
  extraction side; the lgzx message fires but lgzx is the closed fail-loud
  bead, not the capability); then the `%idxend` ptrtoint bounds cluster
  rooted at a MemoryRef field-0 load (**Bennett-foz5**, wall 7 — needs a
  583s ROOT extension under its own subtraction proof). **Bennett-kvdv
  CLOSED as stale** (ht_keyindex2 extracts clean in both bounds modes;
  583s subsumed it); test_59zi's check-bounds else-branch is unreachable
  dead code (P3 bead filed).

### Gotchas

1. **Only ONE of the three push!-set wall markers actually tracked this
   frontier advance** — 40ys (I) and 7wsz (J) disjunctions already admitted
   lgzx/U114, so they stayed green; test_vau9 gate (g) was the one that went
   red. A wall marker whose disjunction admits the SUCCESSOR wall stops being
   a marker the moment it lands; the `!occursin` negatives are the only
   load-bearing half (Bennett-0ncn in action).
2. The jbko arm cannot perturb any previously-green extraction BY
   CONSTRUCTION: everything reaching its position previously hit the
   unconditional generic reject (iwo9/583s both return on match) — the diff
   only turns rejects into admissions or changes reject messages.
3. Sandbox note: backgrounded `sleep` does not advance a running Pkg.test
   between tool calls — foreground waits only.

### Gates

- IMPLEMENTER-run (fresh subprocesses, exit 0, summaries captured verbatim):
  Bennett.jl **690955 Pass / 3 Broken (pre-existing)**, 30m19.9s;
  BennettVM **10379/10379**, 4m10.8s; gate-count 39/39.
- Orchestrator re-gate: WAIVED at user wind-up ("do not run full test suite
  again"). The a8nw review should re-gate if it changes anything.


## Session log — 2026-08-04 — Bennett-vau9: variable-size memmove routes to IRCall(:memmove) under ptr_cells; xkl wall 4 cleared; walls 5+6 precisely located

Fourth bead of the 2026-08-03/04 orchestrated arc (40ys → 7wsz → 3vf2 → vau9).
**REDUCED PASS, deliberately**: scout-verify + implementer + hostile review,
NO blind-proposer phase — the design was settled by the Bennett-8bys 3+1
(variable-size memset D5b void-call routing); the scout's job was to verify
the mirror claim held (it did) rather than re-derive the shape. Deviation from
rule 2's full 3+1 ratified by the orchestrator on klgz-style grounds:
the design space was closed by a prior 3+1 on the sibling intrinsic; the
hostile review remained the full independent check and ran a revert-worktree
experiment plus its own adversarial fixtures.

### What landed

- instructions.jl: the unconditional memmove reject (was "memmove ALWAYS
  fails loud → 8bys") becomes a ptr_cells-gated predicate cascade →
  `IRCall(dest, :memmove, [dst,src,nbytes], [64,64,64], 64)` (D5b void-call
  shape). Predicates: p0.p0 prefix, n_ops>=5 (LIVE guard — LLVM's .ll parser
  accepts a 3-arg declaration; without it: BoundsError), vol isa ConstantInt,
  vol==0, BOTH ptr operands SSAOperand (memmove has two, memset one).
  Const-N ALSO routes (no legacy unroll existed to preserve). ptr_cells=false
  keeps the loud reject (message gains a vau9 clause, retains the
  8bys/37mt substrings the lqif/37mt neighbor pins assert).
- BVM: ZERO src changes — fourth bead in a row. IntrinsicMemmove was already
  complete: `_copy_range!` snapshots the WHOLE src range before writing dest,
  so it is overlap-safe in BOTH directions and for self-move BY CONSTRUCTION
  (no direction analysis); reversal is the standard L2 dest-range delta
  (src cells clobbered are a subset of the dest range). `:memmove` already in
  _HEAP_DISPATCH. The self-move asymmetry vs memcpy (which rejects overlap
  incl. identity) is SOUND: C's memcpy contract forbids overlap, memmove's
  permits it.
- Tests: test_vau9_variable_memmove.jl (61) incl. the malformed-arity .ll and
  the "gate genuinely gates" witness (same .ll, same instruction: reject at
  ptr_cells=false, IRCall at true); BVM test_vau9_memmove_vm.jl (267) with
  FORWARD- and BACKWARD-overlap E2E through the real front-end vs hand
  oracles under L2+L3 + per-step inverse. Hostile review added its own
  self-move and 3-cell backward-shift fixtures (both correct+reversible) and
  a revert-worktree experiment proving testsets (a)/(b)/(g) + the 40ys/7wsz
  gate pins genuinely track the arm.

### Frontier: walls 5 and 6 both located

- push! corpus now lands at **Bennett-jbko (wall 5)**: `ptrtoint ptr
  %.ref.ptr_or_offset to i64` from an extractvalue — Julia's MemoryRef
  concurrent-mutation guard (`icmp eq` vs a captured i64) — matching neither
  the iwo9 type-tag arm nor the 583s memdata arm; lands at the generic iwo9
  fail-loud. Needs a genuinely new equality-comparison arm (determinism
  argument required, klgz discipline).
- **bennettvm-rxgy (wall 6, the FIRST BVM src change of the arc)**: the real
  _growend! grow-copy is a JULIA-TIER (byte-granular gc_alloc_obj) program,
  and `_enforce_julia_heap_tier!` fails loud on cell-granular
  IntrinsicMemmove (÷8 would copy an eighth of the range). Needs
  IntrinsicMemmoveBytes (sibling of IntrinsicMemsetBytes). The vau9 E2E
  deliberately uses malloc/C-tier and says so in its header.
- After jbko: L93 success path is an 8-byte sret-reassembly memcpy (plausibly
  already supported post-7wsz) — runway to full _growend! extraction is
  plausibly short but unverified.

### Gotchas

1. **`bennettvm-9n3y` is a DANGLING bead ID** — used pervasively in comments
   across both repos (incl. the `_enforce_julia_heap_tier!` error message and
   CW-D4 comments) but exists in NEITHER tracker. The real bead for the
   byte-tier gap is bennettvm-rxgy (annotated); new vau9 prose was fixed
   pre-commit; the pre-existing references are swept by a filed P3 bead.
   Lesson: error messages that cite bead IDs rot when beads are renamed —
   verify `bd show` resolves before citing one in a message.
2. Two independent byte↔cell conventions coexist on the path and BOTH are
   pinned: GEP byte offsets become CELL offsets upstream; nbytes stays BYTES
   into IntrinsicMemmove (`_cell_count` errors loud on non-multiple-of-8 —
   no silent partial copy).
3. `BennettVM.Define`'s field is `target`, not `dest`.
4. The 37mt/lqif fixture reaches the memmove arm in both gate modes, so one
   .ll doubles as the gate witness (the 8bys memset analogue needed two).

### Gates (orchestrator-run, fresh subprocesses)

- BennettVM full `Pkg.test`: **10183/10183**, 4m01.1s (= 9895 + 267 new + 21 M8.2-scaffold self-tests included by the new file — attributed exactly).
- Bennett.jl full `Pkg.test`: **690874 Pass / 3 Broken (pre-existing)**, 28m56.7s.
- gate-count regression 39/39 byte-identical (implementer + hostile review).
