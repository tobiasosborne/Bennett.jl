# Worklog chunk 098 — 2026-08-04 — vau9 memmove routing (xkl wall 4)

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
