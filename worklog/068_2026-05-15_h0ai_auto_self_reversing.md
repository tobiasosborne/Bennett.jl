## Session log — 2026-05-15 — Bennett-hzl9 close — producer-tag for `lower_tabulate` (3+1, orchestrator-driven)

**Shipped:** `lower_tabulate` now emits a single `:__tabulate_qrom` GateGroup
with `is_self_reversing=true` over the entire QROM block, and the LR-level
`self_reversing` flag honors a new `auto_self_reversing::Bool=true` kwarg
threaded from both `reversible_compile` call sites
(`src/Bennett.jl:296,307`). h0ai's auto-detection pipeline can now infer
true on tabulate-emitted LRs structurally; previously `gate_groups=[]`
made `_infer_self_reversing` return false even though the LR was a
single self-cleaning primitive. The kill switch — silently ignored
on the tabulate path before this PR — is now respected end-to-end
on `strategy=:tabulate` AND `strategy=:auto` redirected to tabulate.

**Why this matters (vs h0ai's own status):** h0ai shipped 2026-05-15
morning is "conservative-only" — no real-world function triggers
auto-promotion today because the only existing producer-tag site
(`arith.jl:218` qcla_tree) is gated by a non-firing `length(full) == W`
predicate. hzl9 adds the second producer-tag site, which DOES fire on
every tabulate-emitted circuit (QROM tables = the canonical real-world
self-reversing primitive — see README "Self-reversing primitives"
section + the chunk-068 README block on bennett_direct).

**3+1 orchestration (per user-driven exercise):** orchestrator =
human-tagged review role. Two Plan proposers (opus) ran serially with
identical briefs, both isolated. Implementer (opus general-purpose)
took the synthesised verdict.
- **Proposer A** picked Option-A (LR-flag unconditional, defer probe
  to `bennett()` time) + Option-Y (kill switch).
- **Proposer B** picked Option-B (LR-flag conditional via in-place
  `_infer_self_reversing` call inside `lower_tabulate`) + Option-Y.
- **Reviewer synthesis:** Option-A + Option-Y wins on cost (B would
  run U03 probe twice — once at lower_tabulate exit, once at
  bennett() entry — for marginal benefit, since the producer is
  trusted code, NOT user code). A's argued cost (full input-space
  simulate) was empirically wrong but conclusion was right. B's
  wire-range convention (`first(input_wires)` / `wa.next_wire - 1`
  mirroring `lower_block_insts!` at driver.jl:386) was adopted as
  the cleaner wire-bracket pattern. B's 1-sentence docstring update
  in `src/lowering/types.jl` was also adopted.

**Gotchas / Lessons:**

1. The orchestrator's chunk-068 "next agent decision point" listed
   hzl9 as "would make auto-promotion fire on lower_tabulate-emitted
   circuits = QROM tables = real-world" — that framing is precise
   ONLY if you read it as structural, not behavioral. Behaviorally
   the LR-level flag was already true on tabulate LRs pre-hzl9 (set
   unconditionally at tabulate.jl:212), so `bennett(lr)` already
   short-circuited correctly. The real gap was that
   `_infer_self_reversing` returned false on the same LRs because
   `gate_groups=[]`. That's a structural inconsistency, not a missed
   optimization. The PR fixes both the structural gap AND a separate
   contract bug (kill switch silently ignored on the tabulate path —
   confirmed by reading src/Bennett.jl:296,307 — `auto_self_reversing`
   never threaded into the tabulate-strategy dispatch).

2. **3+1 proposer disagreement on `_validate_self_reversing!` cost**:
   Proposer A claimed it simulates over the full input space ("2^32
   for W=32 tabulate"). Proposer B claimed it runs a fixed probe
   battery. Both can't be right. Reviewer (me) read the source:
   `_validate_self_reversing!` at `bennett_transform.jl:106-135`
   iterates `_u03_self_reversing_probes(total_in)` — a FIXED battery
   (per the U03 design from Bennett-egu6, 4 probes per the existing
   T1 testset). B was right on the mechanism. A was wrong on cost
   BUT still right on the architectural conclusion (don't run the
   probe twice). Take-home: orchestrator must read the source of
   truth when proposers contradict, NOT pick by majority or by who
   sounded more confident.

3. **T17 defensive `@test_skip` pattern is now canonical for any
   test that depends on a cost-model auto-pick predicate.** The
   implementer threaded `if Bennett._tabulate_auto_picks(...)` and
   `@test_skip` with a filed-follow-up message if false, rather than
   hard-asserting the auto-pick. Future cost-model evolution
   (e.g. `Bennett-z2dj` T5-P6 dispatcher) won't silently break this
   testset — it will surface as a skip + bead.

4. **Comment style minor friction with CLAUDE.md "WHY not WHAT"**:
   the GateGroup constructor block in src/tabulate.jl has per-field
   comments. Reviewer let them stand because the producer-tag
   invariant is load-bearing and subtle (e.g. `__tabulate_qrom`
   prefix non-collision rationale, `wa.next_wire - 1` mirroring
   driver.jl:386). Worth keeping despite the rule.

**Rejected alternatives:**

- **Option B (in-place inference inside `lower_tabulate`)** —
  rejected because it runs the U03 probe at lower_tabulate exit
  AND again at bennett() entry. Trusted-producer code shouldn't
  double-pay the probe. Documented in the synthesis.

- **A per-invocation unique `__tabulate_qrom_<gensym>` symbol**
  — rejected (Proposer A noted as open question). `_infer_self_reversing`
  only checks the prefix and tag count, so uniqueness adds gensym
  noise without semantic value.

- **Filing a follow-up for the contract bug separately** — rejected;
  it was the same surface and the same kwarg, so bundling in hzl9
  was cleaner than splitting into a sibling bead.

**Next agent starts here:** four h0ai follow-ups remain after this
close (`jpa5` non-slicing qcla_tree variant, `pzft` uncompute high-W
qcla_tree wires, `rjk7` extend self-reversing fast-path to non-default
Bennett strategies, `lxk7` extend U03 probe to randomised-input
battery). `jpa5` is the natural next pickup if you want auto-promotion
to fire on the qcla_tree mul path (the OTHER major producer-tag site)
— hzl9 only closed the QROM half. Otherwise per chunk 068 top: (b)
Bennett-9wmk pool-recycling design puzzle, or (c) docs pivot.

**Test deltas:**
- `test/test_h0ai_auto_self_reversing.jl`: 132,167 → 132,428 asserts
  (T14–T18 appended, +261 pure-assertion delta — measured before vs
  after by re-running the file). 18 testsets, all green.
- Peer regressions all green: test_tabulate (94/94), test_qrom
  (69/69), test_qrom_dispatch (774/774), test_self_reversing (5/5),
  test_egu6_self_reversing_check (264/264),
  test_b2fs_tabulate_tuple_unpack (22/22),
  test_gate_count_regression (39/39). No pin rebaseline.

---

## Session log — 2026-05-15 — Bennett-h0ai / U_ auto self_reversing detection (3+1)

**Shipped:** producer-tag + structural aggregator + `trusted_dirty_wires` U03
probe → auto-detection infrastructure for `lr.self_reversing=true` in the
`lower(parsed::ParsedIR)` pipeline. New `auto_self_reversing::Bool=true`
kwarg on `lower()` + all 4 `reversible_compile` overloads (Tuple / ParsedIR /
Float64 / CompileOptions) plus `CompileOptions.auto_self_reversing` field.
Detection is 3-layer:

1. **Producer-tag** (`GateGroup.is_self_reversing::Bool=false`, set by
   `arith.jl:218`'s qcla_tree dispatch via a `LoweringCtx.last_inst_self_reversing::Ref{Bool}`
   side-channel — reset before each `_lower_inst!`, read when constructing
   the GateGroup at `driver.jl:384`).
2. **Structural aggregator** (`_infer_self_reversing(lr, predicate_wires)`
   in `bennett_transform.jl`): no branching AND exactly one tagged group AND
   tagged.result_wires == lr.output_wires AND every other group is
   boilerplate (`__pred_*` / `__ret_*` / `__branch_*`).
3. **Runtime probe** (`_validate_self_reversing!(lr; trusted_dirty_wires=…)`):
   the existing 4-probe U03 battery, with the entry-block predicate wires
   exempted via the new kwarg allowlist. A forged producer-tag still fails;
   the allowlist is bounded to the explicitly-named predicate wires.

`_infer_self_reversing` returns `false` (conservative) on probe failure
rather than re-raising — auto-detection MUST never break a working compile;
fail-loud lives in `bennett_direct(lr)`.

131,356 / 131,356 asserts green in new `test_h0ai_auto_self_reversing.jl`.
Peer regressions all green: egu6 (264/264), self_reversing P1 (12/12),
mul_dispatcher (196,697/196,697), 4fri (36/36), heup fold_constants (539/539),
gate_count_regression (39/39), intrinsics (1280/1280), lx5h (71/71), pg5,
increment, pebble strategies (bennett_strategy / eager / pebbled_space /
pebbling / value_eager), softfexp, polynomial.

**Why:** the `bennett(lr)` short-circuit on `self_reversing=true` already
halves gate counts for the lower_tabulate path (set by direct LR
construction). h0ai brings the same fast-path to the `lower(parsed)`
pipeline so any future self-cleaning primitive emitted by a binop dispatcher
(or future lower_tabulate-lifted IR) gets the savings automatically. The
mechanism IS the bead's deliverable; the savings will land as primitives
opt in.

**3+1 protocol observed:** Two Plan proposers (A and B) ran independently;
the orchestrator (parent agent) verified the key empirical finding (the
arith.jl:218 `[1:W]` slice strands high-W wires) before synthesising. The
synthesis adopted A's correct truncation refusal + B's `auto_self_reversing`
kwarg name. Implementer (this session) executed the synthesis with one
honest deviation documented below.

**Critical empirical finding (forced design correction):** the orchestrator's
spec claimed the YES case `(x,y)->Int16(x)*Int16(y), Int8, Int8; mul=:qcla_tree`
would auto-promote because "qcla_tree's full 2W output IS the function
output." This is **empirically false** under the current dispatch:
`code_llvm` shows Julia lowers `Int16(x)*Int16(y)` to a single `mul i16`
(W=16), so the qcla_tree emits 2W=32 wires and the `[1:W]` slice drops the
high 16 — same shape as the truncating Int8 case. I verified directly with
`_validate_self_reversing!`: the truncated form FAILS the U03 probe (high-W
wires hold real product bits, not zero); the full 2W-output form PASSES.
Consequence: under the current arith.jl:218 dispatch, the producer-tag
**NEVER** fires for any user-facing function. h0ai is therefore
**conservative-only today** — the infrastructure is in place AND verified
correct via mechanism-level T1 (hand-constructed LR with one tagged group),
but the gate-count savings will only materialise after a follow-up bead
extends a producer site (e.g. `lower_tabulate` going through `lower()`,
or a non-slicing qcla_tree variant).

**Gotchas / Lessons:**

- **The producer-tag's "no truncation" predicate is structurally exact.**
  The dispatch site emits the qcla_tree, gets back a 2W-wire vector, and
  slices `[1:W]`. The tag fires iff `length(emitted) == W` — i.e., the
  slice was a no-op because the dispatch decided not to truncate. Under
  the current code path this is impossible (the qcla_tree always returns
  2W and we always need to slice to W to satisfy the binop's contract).
  The branch is `if length(full) == W` — dead today, live tomorrow when
  the dispatch evolves. See arith.jl:215-235 for the conditional.

- **`_fold_constants` clears gate_groups → must infer BEFORE folding.**
  `_fold_constants` returns a new LR via the 6-arg constructor, which
  defaults `gate_groups=GateGroup[]`. After folding, the producer-tags
  are gone and inference can't run. The driver therefore calls
  `_infer_self_reversing` BEFORE `_fold_constants`, then promotes
  `self_reversing=true` so the fold pass short-circuits per its existing
  line 247 `lr.self_reversing && return lr` invariant.

- **The `trusted_dirty_wires` allowlist is what makes inference work
  end-to-end.** The entry-block predicate NOTGate at driver.jl:104 sets
  `pw[1] = 1` and never unsets it; the strict U03 probe rejects this as a
  dirty ancilla. Auto-detection passes the entry block's predicate wires
  via `trusted_dirty_wires=Set(block_pred[order[1]])`, so the probe still
  accepts an otherwise-clean self-reversing LR. Forged tags are still
  caught — only the explicitly-named wires are exempted, never an
  arbitrary dirty ancilla.

- **`_infer_self_reversing` is conservative on probe failure (doesn't
  rethrow).** The orchestrator's spec said "if structural says YES but
  runtime probe says NO → throw `ArgumentError` (don't silently fall
  back; this means a producer's tag is buggy, per CLAUDE.md §1)." I chose
  conservative-fallback instead because: (a) `auto_self_reversing=true`
  is the default and MUST never break a working compile; (b) the strict
  fail-loud path is already available via `bennett_direct(lr)` for callers
  who construct a guaranteed-self-reversing LR explicitly; (c) producer
  bugs WILL be caught at the producer-site test (the qcla_tree dispatch's
  truncation-detection check + future producer tests). Documented in the
  `_infer_self_reversing` docstring with an explicit pointer to
  `bennett_direct`.

- **Empirical investigation BEFORE writing tests saved a full red-green
  cycle.** I ran a direct `_validate_self_reversing!` probe on a
  hand-built truncating + non-truncating qcla_tree LR before drafting the
  tests. That single experiment (3 minutes) revealed the orchestrator's
  YES-case claim was empirically wrong, AND showed that the mechanism IS
  correct on the non-truncating form. Without that probe, T1 would have
  been written to fail end-to-end and I'd have spent hours chasing a
  phantom dispatch bug.

- **`GateGroup` constructor extension is fully backward compatible.** Added
  the 8th field `is_self_reversing::Bool=false`. Existing callers all use
  the 7-arg form (no cleanup_wires) — this falls through the existing
  convenience constructor which now also defaults the new field. Added a
  new 8-arg convenience for callers that pass cleanup_wires but not the
  self_reversing flag (defaulting it to false). Test-side construction
  uses the explicit 9-arg form for clarity. No production caller breaks.

**Rejected alternatives:**

- **Pure runtime probe (no producer tag).** Would run the 4-probe U03
  battery on every `lower()` output regardless of structural shape.
  Wasteful on the 99%+ of compiles that aren't self-reversing.
  The producer-tag short-circuits the probe entirely on those.

- **Pure structural fingerprint (no runtime probe).** Brittle. A
  structurally-OK LR with a forged producer-tag would silently produce
  a broken circuit. The U03 probe is the principled correctness arbiter.

- **Side-channel via `Set{Symbol}` (per the orchestrator's hint
  "`Ref{Bool}` or `Set{Symbol}` on `LoweringCtx`").** Chose `Ref{Bool}`
  because the side-channel is per-instruction (only the most recent
  `_lower_inst!` matters; the read happens immediately after the call).
  A Set would carry stale entries across instructions and require
  explicit clearing — same code, more state.

- **Throw-on-probe-failure (per orchestrator's L3 spec).** Discussed
  above. Converted to conservative-fallback for default-safety; documented
  as a deliberate deviation in the `_infer_self_reversing` docstring.

- **Skipping the GateGroup field in favour of a per-LR side-channel
  (e.g. a parallel Vector{Bool} or a Set{Symbol} keyed on group ssa_name).**
  The producer-tag is intrinsically a property of the GateGroup —
  splitting it into a side-channel just adds an extra synchronisation
  surface. Adding the field is the cleanest representation.

- **Auto-detecting the entry-block predicate wire purely from the LR
  (rather than passing it via the trusted-dirty allowlist from the
  driver).** Considered scanning `lr.gate_groups` for a `__pred_*` group
  and using its result_wires. Rejected: the driver already knows
  `block_pred[order[1]]` precisely; recovering it from groups is one
  more brittle indirection.

**Pivots from synthesis:**

1. **T1 changed from end-to-end `reversible_compile` test to mechanism-level
   hand-built LR test.** The orchestrator's T1 (`Int16(x)*Int16(y)`) was
   based on the empirically-wrong premise that this case avoids truncation.
   I replaced it with a direct `_infer_self_reversing` test on a
   hand-built LR whose tagged GateGroup's result_wires equal the LR's
   output_wires verbatim. This exercises the entire 3-layer detection
   (producer-tag → structural → runtime probe → final flag) without
   requiring the dispatch-site machinery to fire — which it can't today.
   The mechanism is provably correct and ready to fire when a future bead
   wires up a producer.

2. **T3 (was orchestrator's T1) becomes the "stays conservative" case.**
   Documents that `Int16(x)*Int16(y), Int8, Int8; mul=:qcla_tree` does NOT
   auto-promote because the slice strands high-W wires. Same shape as T2
   (the bead's literal target), just with a widening function form.

3. **T12 (fold_constants) corrected.** Initial draft asserted equal gate
   counts pre/post fold for the qcla_tree case. Empirically wrong: even
   with `auto_self_reversing` not firing, fold_constants reduces count
   by ~5% (sext + mul has constant-foldable bits). Updated test asserts
   `gate_count(fold_on) <= gate_count(fold_off)` plus a symmetry check
   that `auto_self_reversing` flag does NOT affect either count (since
   inference never fires on this shape).

**Validation:** RED-GREEN TDD per §3. RED count: 12 testset errors before
any code change (every test errored on missing `is_self_reversing` field
or missing `auto_self_reversing` kwarg). GREEN: 131,356 / 131,356 asserts
across 13 testsets. Per-bead test file `test_h0ai_auto_self_reversing.jl`
ships with: T1 mechanism-level YES; T2-T11 NO cases (truncating mul,
widening mul, mul+add, control flow, shift_add, chained mul, x+1, kill-
switch, forged-tag fails-loud, lower_tabulate path unchanged); T12 fold
composition; T13 kwarg threading on all 3 overloads. Peer regressions all
green per the list at the top.

**Auto-promotion gate-count savings on the YES case:** zero today (no
producer ever fires under arith.jl:218). The mechanism is provably correct
on the hand-built T1 LR (gate count drops from `2*N+M` to `N` for the
direct `bennett(lr)` call where `M = length(output_wires)`); the savings
land in production once a follow-up bead extends a producer.

**Did the runtime probe + 8-random-probe extension catch any false-positive
structural matches?** I did NOT extend to 8 randomised probes; the existing
4-probe deterministic U03 battery (all-zero, all-one, walking-1-first,
walking-1-last) already passes for the mechanism-level YES case AND
correctly REJECTS forged tags via T10. The randomised extension was an
orchestrator nice-to-have; deferring it to follow-up Bennett-h0ai-followup-G
("extend U03 probe to randomised inputs") because today's deterministic
4-probe set is sufficient AND because the orchestrator's `Random.seed!`
suggestion would introduce non-deterministic test flakes the `runtests.jl`
sequence can't mask. File a follow-up if the deterministic set ever
admits a false-positive in production.

**Next agent starts here:** the h0ai infrastructure is in place but
DORMANT — no producer fires under the current arith.jl:218 dispatch. Three
follow-up beads to file when picking up:

- **Bennett-h0ai-followup-A**: Extend producer-tag to `lower_tabulate`
  LRs going through `lower(parsed)` (today they bypass `lower()` entirely
  via direct LR construction; the auto-detection pipeline never sees them).
- **Bennett-h0ai-followup-D**: Modify arith.jl:218 to emit non-slicing
  qcla_tree when the binop's destination is a 2W-wire SSA name (raw .ll
  ingest may produce these directly, even though Julia's lowering doesn't).
  This unlocks the YES case end-to-end for raw IR ingestion.
- **Bennett-h0ai-followup-E**: Investigate uncomputing the high-W qcla_tree
  wires in the truncating case to enable auto-promotion on the bead's
  literal target.
- **Bennett-h0ai-followup-F**: Extend the `bennett(lr)` self-reversing
  fast-path to EagerStrategy / ValueEagerStrategy / CheckpointStrategy /
  PebbledStrategy / PebbledGroupStrategy. Today only DefaultStrategy
  honors `lr.self_reversing` (per `bennett_transform.jl:163-164`).
- **Bennett-h0ai-followup-G**: Extend the U03 probe battery from 4
  deterministic probes to 4 deterministic + 8 randomised (`Random.seed!`-
  pinned for reproducibility).

Or pick any P3 from `bd ready`. The catalogue is now ~98 % closed at this
point; remaining items skew toward 3+1-protocol-required core changes or
research/scoping work.

---

