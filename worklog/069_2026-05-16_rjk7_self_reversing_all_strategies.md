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
