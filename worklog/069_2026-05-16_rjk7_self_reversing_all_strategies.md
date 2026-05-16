## Session log — 2026-05-16 — Bennett-ixiz close — wider-element alloca support (3+1, orchestrator-driven, bead-premise-rewritten-in-flight)

**Shipped:** wider-element alloca support across the extract + lowering
pipeline. `alloca i64` (and `[K x i16]`, `[K x i32]`, `[K x i64]`, etc.)
now flow through memcpy/memset/load/store with element-stride correctness.
Five gate sites lifted: G1 in `src/lowering/aggregate.jl:227` (sub-element
fail-loud guard + element-stride formula), G3 in `src/extract/instructions.jl`
at both the `_alloca_elem_width_bits` helper AND a second alloca-conversion
site in `_convert_instruction:2032` (implementer's bonus catch — the bead
description and orchestrator brief both missed this duplicate), G4 in
`_handle_memcpy_arm` (predicate 8 lifted to integer-element check;
predicate 8b added for cross-width reject; predicate 8c for N-not-
multiple-of-ew_bytes), G5 in `_handle_memset_arm` (predicate 12 lifted;
predicate 12b added; new `_broadcast_byte_to_width` helper for byte fill).
Mixed-width store/load (e.g., 32-bit store into i64 slot) stays loud-
rejected by the four unchanged Gate-2 firewall sites in `src/lowering/
memory.jl` (lines 212-213, 245-246, 370-371, 423-424) — both proposers
independently verified those already check `inst.width == elem_w`, NOT
`== 8`, so they correctly admit same-width at any elem_w.

**Critical bead-premise correction (filed as bd note on Bennett-ixiz):**
the bead description called out "two gate sites" — `aggregate.jl:227` AND
`memory.jl:245-246`. Both proposers verified the source and discovered
the framing was wrong: memory.jl Gate-2 sites are already same-width-
correct and serve as the mixed-width firewall (NOT a blocker). The real
blockers were FOUR sites in extract+lowering, not two. Lifting only G1
(per the bead's narrowest reading) would NOT have flipped the three
existing reject tests because extract bails before lowering ever runs.
Proposer A spotted the memory.jl framing was wrong but didn't propose
the extract lifts (incomplete scope); Proposer B spotted both and
proposed the full 5-gate scope. **Synthesis adopted B's expanded scope
+ A's testing structure clarity.** Per CLAUDE.md §10 (skepticism):
orchestrators should verify bead descriptions against source before
scoping work. This is the second bead in two days where proposer
verification caught a description error (hzl9 yesterday also had a
framing issue around tabulate self_reversing handling).

**Why this matters (vs. ixiz's nominal P3 scope):** ixiz's
description called itself a "non-MVP" lift of memory restrictions.
Empirically it's a substantial scope-expansion enabler for the T5
multi-language LLVM ingest path. Any C/Rust code that uses `alloca i64`
(most non-Julia LLVM-typed code) was hitting these restrictions
pre-ixiz. Three existing reject tests (in test_munq, test_37mt,
test_9nwt — and the implementer caught a fourth, test_lqif, as a
drive-by) flipped from `@test_throws` to positive lowering assertions.

**Pre-ixiz RED-state evidence (T6/T8/T9 fail-loud cases, captured 2026-05-16):**
- T6 (sub-element IRPtrOffset on i64): pre-ixiz, Gate 1's `ew == 8 || continue`
  silently DROPPED the origin, leaving `ptr_provenance[inst.dest]` empty;
  downstream IRStore through that pointer would then fail at the provenance
  assertion (a different error than the new fail-loud DimensionMismatch).
  Post-ixiz, sub-element offsets are caught at the source with a precise
  message naming `alloca_dest` and `ew`.
- T8 (cross-alloca-width memcpy): pre-ixiz, the `dst_ew != 8 || src_ew != 8`
  predicate 8 rejected ANY non-i8 alloca, so a mixed i8/i64 memcpy was
  rejected by a vague "Phase 1 supports byte-granularity only" message.
  Post-ixiz, the new predicate 8b gives a precise "cross-width
  src/dst" message naming both widths.
- T9 (N not multiple of ew_bytes): pre-ixiz, the same blanket predicate 8
  swallowed this case. Post-ixiz, predicate 8c catches it with a precise
  message.

**Orchestration (CLAUDE.md §2 3+1, orchestrator-driven):**
- **Proposer A** (opus, Plan): verified source, picked Q2 (α) "no change to
  memory.jl" — correct. But **scope-incomplete**: A's plan kept the lift to
  `aggregate.jl` only, missing G3/G4/G5 in `extract/instructions.jl`. Would
  have shipped dead code on the memcpy/memset path because extract still
  bails before lowering runs.
- **Proposer B** (opus, Plan, isolated from A): verified source independently,
  ALSO picked Q2 (α), AND caught the extract-layer gates. Proposed the full
  5-gate scope. Flagged subtle issues: memset byte-broadcast semantics for
  later mixed-width loads (now firewalled by Gate-2); cross-alloca-width
  reject; N-not-multiple-of-ew_bytes reject.
- **Reviewer synthesis:** B's full scope adopted. Implementer ALSO caught
  a duplicate `LLVM.width(inner) == 8` gate at `_convert_instruction:2032`
  that both proposers missed — without that lift, IRAlloca wouldn't carry
  the right elem_w and G3/G4 wouldn't actually wire through. Implementer's
  4th catch.

**Gotchas / Lessons:**

1. **The implementer's drive-by lqif test flip was correct and welcome.**
   `test_lqif_memcpy_memmove_reject.jl` had a testset "llvm.memcpy on
   alloca-i64 fails loud" asserting the exact behavior ixiz removes. Without
   flipping it, lqif would have broken. The implementer recognized this
   regression risk and applied the same flip pattern as the 3 named tests.
   **Lesson for future orchestration briefs:** when a bead changes a
   rejection contract, the brief should grep for ALL tests asserting that
   contract, not just the named ones in the bead description. Add a
   "search for `@test_throws` referencing this code path" step to the
   implementer brief template.

2. **The implementer's `_convert_instruction:2032` catch saved a half-shipped
   change.** The orchestrator brief listed G1+G3+G4+G5 (4 gate sites). The
   implementer found a FIFTH: a duplicate `LLVM.width(inner) == 8` gate in
   the alloca-conversion arm of `_convert_instruction`, separate from the
   `_alloca_elem_width_bits` helper. Without the fifth lift, IRAlloca would
   still carry `elem_w=8` for `[K x i16]` allocas, and the lift would be
   silently incorrect (wrong wire count). **Lesson:** when lifting a
   restriction in a helper function, grep the codebase for that exact
   restriction string at OTHER call sites — `git grep "width(inner) == 8"`
   would have caught both sites.

3. **The pre-existing `_pick_alloca_strategy (N=1, W>=64)` gap surfaced as a
   secondary observation during ixiz Explore.** Filed as Bennett-a5ag (P4)
   so it doesn't get lost. Real but rare: single-slot alloca with dynamic
   index would always have idx=0, so the gap mostly matters when LLVM
   optimization reduces a multi-slot pattern to single-slot.

4. **Memset byte-broadcast semantics are a real footgun for future
   mixed-width support.** Post-ixiz, `memset(alloca_i64, 0xAB, 16)` emits
   `IRStore(width=64, val=0xABABABABABABABAB)`. If a future call site then
   loads at width=8 to read a single byte, Gate-2 firewall in memory.jl
   correctly rejects with `DimensionMismatch`. This is *correct* per the
   shadow-tape elem_w granularity invariant — but user code patterns
   commonly do `memset(p, 0, N); ... = p[i]` expecting byte-granular reads
   to work. Filed Bennett-2fue (P3) for the mixed-width support work,
   which requires shadow-tape redesign (not a small task).

**Rejected alternatives:**

- **Lift Gate 2 in memory.jl too** (the bead's literal reading) — rejected
  because Gate 2 is already correct; lifting would silently break the
  mixed-width firewall.
- **Lift only G1 in aggregate.jl** (Proposer A's narrow scope) — rejected
  because the three reject tests would not flip (extract bails before
  lowering). The bead description's "two gate sites" framing led A to this
  conclusion.
- **Drive-by fix the `_pick_alloca_strategy (1, 64)` gap** — rejected per
  senior-engineer rule "keep beads focused." Filed Bennett-a5ag instead.

**Test deltas:**
- New `test/test_ixiz_wider_alloca.jl`: 53/53 pass, 45s. 9 testsets across
  3 positive groups + 4 fail-loud cases (T1 i64 round-trip; T2 [N x i16]
  round-trip; T3 i64 memcpy; T4/T5 i64 memset c=0/c=0xAB; T6 sub-element
  rejection; T7 mixed-width rejection (firewall); T8 cross-alloca-width
  rejection; T9 N-not-multiple-of-ew_bytes rejection).
- Seven new `.ll` fixtures in `test/fixtures/ll/ixiz_*.ll`.
- Two existing fixtures renamed (stripping `_reject` suffix):
  `37mt_memcpy_alloca_i64_reject.ll` → `37mt_memcpy_alloca_i64.ll`;
  `9nwt_memset_alloca_i64_reject.ll` → `9nwt_memset_alloca_i64.ll`.
- Four flipped reject testsets (in test_munq / test_37mt / test_9nwt /
  test_lqif — the lqif flip was the implementer's drive-by catch).
- Peer regressions all green:
  - test_munq_arr_i8_alloca: 69/69
  - test_37mt_memcpy_const_aligned: 86/86
  - test_9nwt_memset_const: 87/87
  - test_lqif_memcpy_memmove_reject: 12/12
  - test_gate_count_regression: 39/39 (§6 explicit-strategy baselines
    unchanged — confirms no Int8 hot path used wider allocas)
  - test_shadow_memory: 594/594
  - test_tfo8_alloca_strategy_tables: 62/62
  - test_lower_store_alloca: 41/41
  - test_store_alloca_extract: 279/279
  - Total: ~1322 asserts green across the alloca/memcpy/memset surface.

**Sibling beads filed (deferred scope):**
- **Bennett-2fue (P3)** — Mixed-width store/load on wider-element allocas
  (requires shadow tape redesign).
- **Bennett-a5ag (P4)** — `_pick_alloca_strategy (N=1, W>=64)` dynamic-
  index gap.

**Next agent starts here:** open-bead count 33 → 32 after ixiz close.
Natural follow-ups within the hao Phase 3 family (now 7 sub-beads):
`xtu9` (variable-size memcpy/memset — directly depends on ixiz, so the
prerequisite is now met), `doih` (global-pointer src memcpy via QROM
fan-out — t5_tr2_hashmap.ll line 153 fails today), `zmry` (non-fresh
dst uncompute), `yxr8` (memmove + alias analysis), `2fue` (mixed-width,
just filed), `6c6f` (QROAM SELECT-SWAP, larger algorithm change).
Bennett-z2dj T5-P6 dispatcher still in_progress as the biggest critical
path. h0ai cluster down to 3 follow-ups (jpa5 needs reframe, pzft P4,
lxk7 P4 — the last two are conditional/optional per their own
descriptions).

---

## Session log — 2026-05-16 — Bennett-rjk7 close — universal `lr.self_reversing` fast-path (3+1, orchestrator-driven)

**Shipped:** the `lr.self_reversing=true` short-circuit fast-path —
previously honored only by `DefaultStrategy` — is now uniformly
respected by all 6 Bennett strategies: `EagerStrategy`,
`ValueEagerStrategy`, `CheckpointStrategy`, `PebbledStrategy`,
`PebbledGroupStrategy`. Each `_*_bennett_impl(lr; ...)` body now
prepends the identical 4-line check (`_validate_self_reversing!(lr)`
+ `return _build_circuit(...)`) mirroring `_bennett_default` at
`bennett_transform.jl:286-294`. Inline-by-design (no helper) — the
5 strategy files stay self-contained for future readers debugging
one strategy in isolation. Docstring at `bennett_transform.jl:247-268`
rewritten to reflect the universal contract; the obsolete future-work
comment at `test/test_h0ai_auto_self_reversing.jl:30` deleted.

**Why this matters (the contract gap that wasn't just a perf cleanup):**
The pre-rjk7 RED-state evidence (captured by the implementer via a
stashed dry-run with strategy edits reverted but tests in place)
revealed a real contract violation, not just a missed optimization:

- **EagerStrategy SILENTLY accepted forged `self_reversing=true` tags
  pre-rjk7** — wrapping the LR with its EAGER algorithm but never
  running the U03 probe. A producer that lied about self-reversal
  would get a (possibly correctness-preserving but un-validated)
  wrapped circuit. The DefaultStrategy threw on the same input.
- The other 4 non-default strategies happened to throw on the forged
  LR, but via INCONSISTENT deep-algorithm checks (input mutation
  catch in PebbledGroup's wire bookkeeping, structural rejects in
  Checkpoint, etc.) — none via the U03 contract probe. So even when
  they threw, the throw site / error class differed by strategy,
  meaning the fail-loud contract wasn't really uniform.
- Post-rjk7: every strategy throws `ArgumentError` via the same
  `_validate_self_reversing!` call site, satisfying CLAUDE.md §1
  (fail-fast-fail-loud) UNIFORMLY across the strategy matrix.

This finding upgrades rjk7 from "P3 perf cleanup" to "real
correctness extension that closes a silently-divergent contract."
Worth keeping in mind when future contract-extension beads are
filed against the strategy axis.

**Pre-rjk7 RED-state evidence (T1-T6 positive tests, captured 2026-05-16):**
- `EagerStrategy` 1 assertion failed (the `length(circuit.gates) == n_bare`
  structural check — Eager wrapped instead of short-circuiting).
- `ValueEagerStrategy` 1 assertion failed (same — wrapping bypassed
  the structural check).
- `CheckpointStrategy` 256 failures (full UInt8 oracle sweep diverged —
  wrap produced different gate count AND simulation results like
  `0xaa == 0x54` / `0x55` indicating the wrap touched output wires
  unexpectedly for this LR shape).
- `PebbledGroupStrategy` 256 failures (same pattern as Checkpoint).
- `PebbledStrategy(0)` ALREADY GREEN pre-rjk7 because its
  `max_pebbles<=0` fallback `return bennett(lr)` re-enters the
  DefaultStrategy method via dispatch — so the fast-path fired
  transitively. The other 4 strategies have no equivalent fallback
  on self-reversing input. Post-rjk7 the fast-path fires directly,
  saving the recursive bennett() call.

**Orchestration (CLAUDE.md §2 3+1, orchestrator = user-driven exercise):**

- **Proposer A** (opus, Plan): picked **helper** in `bennett_transform.jl`
  + **central + per-strategy struct docstrings** + **parametrized loop**
  + **first-position insertion** + full 3+1 ceremony.
- **Proposer B** (opus, Plan, isolated from A): picked **inline** + **central
  docstring only** + **per-strategy testsets** + **first-position insertion**
  + full 3+1 ceremony.
- **Reviewer synthesis:**
  - Q1 helper-vs-inline: **inline** (B). The helper would centralize a
    body that already changes only twice/year and would force every
    strategy reader to cross-file to `bennett_transform.jl` to learn the
    fast-path semantics. Honest 11-line duplication × 5 is more readable.
  - Q3 docstring scope: **central only** (B). Strategies are about
    scheduling policy; `self_reversing` is an LR-input property —
    coupling per-strategy docstrings to LR-tag conventions creates rot
    (future tags like `self_inverse` would need 5 more synchronized
    edits). Central docstring with explicit "all 6 strategies" claim
    suffices.
  - Q4 test parametrization: **parametrized loop + inner `@testset`
    named by strategy type** — synthesis adopting A's DRY pattern with
    B's bisect-clarity refinement. Julia's `@testset` framework prints
    per-iteration results, so the parametrized form gets both wins.
  - Q5 cross-strategy consistency: **include DefaultStrategy in all
    three groups** (B's smart addition) — gives an independent reference
    point so any drift in DefaultStrategy semantics shows up in this
    test file too, not just the unrelated `test_self_reversing.jl`.
  - Order: **test file first → red → strategy edits → green** (B's
    order, matches CLAUDE.md §3 directly).

**Gotchas / Lessons:**

1. **The helper-vs-inline call is genuinely close.** Both proposers
   argued well. The deciding factor was readability under debugging,
   not DRY arithmetic — when a future agent is trying to understand
   `_eager_bennett_impl`'s behavior on a self-reversing LR, having
   the contract inline beats the indirection. Worth remembering for
   future similar 5-strategy mechanical extensions: default to inline
   unless the duplicated body is more than ~10 lines or the contract
   would foreseeably change in lockstep.

2. **Pre-rjk7 PebbledStrategy(0) passed T1-T6 already.** This is a
   subtle dispatch-table fact: `max_pebbles<=0` falls back to
   `bennett(lr)` (1-arg form) which dispatches to DefaultStrategy via
   the method table at `bennett_strategies.jl:93-98`. So PebbledStrategy
   was a "free rider" on DefaultStrategy's fast-path — explains why
   the bead's contract gap was hard to spot pre-rjk7 (some strategies
   "worked" transitively). After rjk7 the fast-path fires directly,
   saving the dispatch hop and matching the per-strategy contract.

3. **Test file's positive-group implementation builds the LR ONCE for
   `n_bare` then rebuilds per iteration** (lines 52-56). The first build
   is a length probe — `bennett()` may not mutate `lr.gates` (Bennett-nj5r
   / U200 confirmed for all strategies), but rebuilding fresh per
   strategy is defensive-by-design. If a future strategy ever does
   mutate, this test's per-iteration freshness catches it.

**Rejected alternatives:**

- **Helper `_short_circuit_self_reversing(lr)` in `bennett_transform.jl`**
  (Proposer A): rejected — see Lesson #1. Centralization would have
  been a small win on lockstep-change but a small loss on readability;
  judgment call went to readability here.
- **Per-strategy docstring sentences in `bennett_strategies.jl`**
  (Proposer A): rejected — coupling scheduling-policy docs to
  LR-input-property conventions creates synchronization debt for any
  future LR-level tag. Central docstring wins.
- **Explicit per-strategy testsets vs. parametrized loop** (Proposer
  B's preference): rejected in favor of the loop + named-inner-testset
  synthesis — DRY + bisect clarity without picking between them.

**Test deltas:**
- New file `test/test_rjk7_self_reversing_all_strategies.jl`: 116
  lines, 18 inner testsets × 3 groups × 6 strategies = 3098 assertions
  (the bulk is the 256-input UInt8 sweep × 6 strategies × 2 oracle
  comparisons = ~3072 oracle asserts + structural/forged-tag overhead).
  All green: 3098 / 3098 pass, 17.9s wall-clock on dev machine.
- `test/runtests.jl`: +1 line registering the new file immediately
  after `test_self_reversing.jl` (topical adjacency).
- `test/test_h0ai_auto_self_reversing.jl`: -2 lines (deleted the
  obsolete future-work comment).
- Peer regressions all green:
  - `test_self_reversing.jl`: 12/12
  - `test_egu6_self_reversing_check.jl`: 264/264
  - `test_h0ai_auto_self_reversing.jl`: 132,428/132,428 (unchanged
    from hzl9 close yesterday)
  - `test_gate_count_regression.jl`: 39/39 baselines unchanged — §6
    explicit-strategy pins all use DefaultStrategy by default so
    no rebaseline.

**Side cleanups (same session):**
- **Bennett-2ebq closed as superseded by Bennett-lx5h.** 2ebq and lx5h
  had byte-identical descriptions ("Float-lane LLVM vector reductions.
  Bennett-pg5 covers the 9 integer reductions; this is the float
  follow-up...") and were both filed 2026-05-15. lx5h shipped the
  dispatch at `src/extract/vectors.jl:246-253`; 2ebq was a residual
  duplicate. No code change, just a `bd close --reason=superseded`.
- **Bennett-jpa5 annotated with rework finding.** Explore'd
  jpa5's premise ("raw IR ingest produces mul with dest=2W via 2-bit-width
  promotion") and found it's not a pattern the current extractor can
  express. `IRBinOp` (src/ir_types.jl) has a single `width::Int` field
  with no operand-vs-dest distinction; the extractor at
  `src/extract/instructions.jl:1407-1413` calls `_iwidth(inst)` which
  reads LLVM result type, so a C-style widening multiply
  (`zext+zext+mul`) arrives as `IRBinOp(:mul, ..., width=64)` with no
  way to recover that operands were narrower. Filed three reframe
  options on the bead (new `IRWidenMul` IRInst type, extractor pattern
  detection of zext+mul, or zext-provenance check at lowering time)
  so the next agent doesn't re-discover. The dead-code predicate at
  `src/lowering/arith.jl:230` (`if length(full) == W`) is structurally
  unreachable today regardless of jpa5 path chosen.

**Next agent starts here:** 4 h0ai follow-ups remain (down from 5 →
4 after hzl9 yesterday, 4 → 3 after rjk7 today — actually 3 remain
since rjk7 closed today): `jpa5` (now annotated, needs triage on
which reframe option to pick before implementation), `pzft` P4
(uncompute high-W qcla_tree wires for the truncating case — related
to jpa5's option (c)), `lxk7` P4 (extend U03 probe to randomised
inputs — natural after rjk7 because rjk7 made the U03 probe
load-bearing across more strategies, so probe robustness now matters
more). The h0ai cluster is winding down.

Other natural pickups per the open-bead breakdown (33 open after
today): T5-P6 dispatcher (`z2dj` IN-PROGRESS — biggest critical
path), `hao` Phase 3 family (8 P3 beads, mechanical), `tzrs` stages
2-5 (god-function split, 3+1 required, deferred per §11). Per the
chunk-068 directive the project is in "structural / LOC refactor"
mode, not bugs-only.
