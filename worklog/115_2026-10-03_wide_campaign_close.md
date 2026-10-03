# Worklog chunk 115 — 2026-10-03 — wide campaign: session close and handoff

Detail lives in chunks 110 (setup, batches 1–3), 111 (batches 4–6), 112 (batches 7–8, review 1),
113 (batches 9–10), 114 (batches 11–12, full suite, reviews 2 and 3, BennettVM suite).

## Session log — 2026-10-03 (evening) — six-wide short campaign: sharded full suite, review 1 of the final wave — READ FIRST

**Mode.** Same as the day campaign but six slots (`~/Projects/Bennett-slots/s1..s6`, plus `s0` as a
detached snapshot for the suite), Opus workers, one bead each, `gpt-6.1-sol` high for review. The
session was time-boxed by the maintainer, so there was one wave plus two refills.

**Landed (five beads, all closed; each with a new test file, gate-count baselines unmoved):**
- **Bennett-73gr** (06ee828, P1, core `cfg.jl`/`driver.jl`): every DFS back edge must have its header
  dominate its tail and loop bodies must be single-entry; irreducible CFGs are refused loud.
- **Bennett-2glq** (009e606): vector loads with a sub-byte lane width (`<N x i1>`) are refused.
- **Bennett-usly** (880b7a1): `soft_mux_*` index contract documented; no code path changed.
- **Bennett-okcg** (478fc76): `transitive_callees` never returns its root; the set builder registers a
  recursive root as a callee itself (the old duplicate did that by accident). Recursive set
  extraction now works. Julia 1.12 inlines one side of a mutual pair unless both are `@noinline`.
- **Bennett-13xy** (fe3c3aa, P1, core `gates.jl`/`simulator.jl`/`Bennett.jl`): `ReversibleCircuit` has
  a new field `output_elem_unsigned::Union{Nothing,Vector{Bool}}`, recorded from
  `Core.Compiler.return_type` at natural width; `nothing` (raw ParsedIR, Bool, narrowed) keeps the
  zc50 heuristic. **Behaviour change beyond the typed path: untyped `simulate` now returns the
  recorded type** (an `Int8 -> UInt8` function returns `UInt8`). BennettVM has not been run against
  it. Mixed-width tuple returns still fail extraction (Bennett-qmk6).

**Still in flight when this entry was written** (claimed, branch committed in its slot, queued on the
landing lock or coding): Bennett-9fke (s1), Bennett-sy9t (s4), Bennett-0ysp (s6). If `git log` shows
them on main, they landed after the suite snapshot with targeted tests only and their beads still
need closing; if not, the branches `work/9fke`, `work/sy9t`, `work/0ysp` hold the work.

**Filed:** blnv, 0ysp, qu9m, 2hx3, e7l8, 6c9j (review 1); 6atf (suite failure); omnl (signedness on
the narrowed path); rrwj (runtime-index range proof for MUX); 6rx3 (full suite on the final tree).

**Full suite — sharded, and what it covers.** One run, ten shards, on a detached snapshot of main at
**009e606** (so it covers the twelve source commits the day campaign left unverified, plus 73gr and
2glq). Eight shards finished in 7 to 13 minutes of wall time with 1,682,068 passes; two shards
(1 and 2, the `llvm_*_dispatch` soft-float files) were still running, with no failure so far, when
this entry was written — their logs are `~/Projects/Bennett-slots/logs/suite/shard_{1,2}.log`.
- **One real failure: Bennett-6atf (P1).** `test_mrhg_narrow_soundness.jl:621` — the global-store
  rejection case now dies in extraction with the gq1z `jl_global#N.jit` alias refusal (3a036b2)
  instead of the expected `ArgumentError`. It is exactly the cross-file pin class the day campaign
  warned about, and it sits in the catch block 9fke is changing.
- The hygiene file errors in direct mode (no Aqua in the project env) and passed through
  `Pkg.test(test_args=["hygiene_aqua"])`.
- **Not covered by the run:** usly 880b7a1, okcg 478fc76, 13xy fe3c3aa and anything later. 13xy is
  the one that matters (core, and it changes untyped `simulate`'s return type). Bennett-6rx3 tracks
  the full run on the final tree; do it first next session, then the BennettVM suite.

**Review 1 (Sol, high) over `c443621..3a036b2 -- src`** — the five final-wave refusal commits of the
day campaign that had no review. Eight findings, every witness executed by the reviewer:
- Wrong result, P1 **Bennett-blnv**: the iffz splat refusal does not look through Base wrappers —
  `g(x::Float64)=signbit(x); g(x)=!signbit(x); f(x)=Base.splat(g)((x,))` returns 1 for 1.0, native 0.
- Unsound acceptance, P1 **Bennett-0ysp**: u9cc's immutability rule is enforced on `:expression`
  only; `strategy=:tabulate` freezes a mutable callable's field.
- Silent skip: a `MethodError` bypasses gq1z's certificate (`extractvalue [1 x ptr] [blockaddress]`)
  — this is Bennett-9fke.
- Rejects-valid: **Bennett-qu9m** (P2, xjt9 width test ignores bounds proven by mask/zext),
  **Bennett-2hx3** (P3, `__pslab_ew_<slab>` metadata lives in the SSA namespace), **Bennett-e7l8**
  (P3, dx9w stride test refuses a zero displacement), **Bennett-6c9j** (P3, iffz refuses every
  `@generated` method and every differing splat signature).
So "they only add refusals, the risk is rejects-valid" (the day campaign's claim) was half right:
five rejects-valid, but also two holes left open NEXT TO the new refusals.

**Maintainer decisions (delegated to the orchestrator; "do not start v2 yet").** Recorded on the beads:
sl4h — keep the koi8 refusal, no lowering-parameter redesign, 3d1k is the cheap partial; armp —
route `llvm.pow` through `soft_pow_julia` once bie9 is fixed, documented exception until then;
2op8 — callable-struct fields and Fix1/Fix2 follow the closure-capture rule (bind immutable isbits,
reject the rest); usly — out-of-range runtime index is undefined-by-contract (landed). V2-PRD D0 and
the class-1 recogniser beads stay parked. Deleting `wip/i5zn-loop-header-effects` (local + origin)
was blocked by the permission classifier — the maintainer has to run it.

**Learnings.**
- A full suite does not have to be serial. `runtests.jl`'s substring filters (Bennett-uxyy) take
  exact file names, so N processes each given every N-th `runfile` name run the whole suite in
  suite mode (`julia --project=. --check-bounds=yes test/runtests.jl <files…>`). The hygiene file
  needs Aqua and therefore `Pkg.test(test_args=["hygiene_aqua"])`. Run it on a detached snapshot
  worktree so landings are not blocked. Scripts: `~/Projects/Bennett-slots/suite.sh` (not in the
  repo). This is most of Bennett-gm83 without the shared-depot spike (o540).
- Round-robin sharding is unbalanced: the `llvm_*_dispatch` soft-float files are registered at
  the same stride, so with ten shards several got one heavy file each at the same time. Shard by
  measured per-file time next time (the `✓ file  12.3s` lines in the shard logs give the weights).
- Six slots pre-warm in two minutes (one serially, five in parallel) and six concurrent workers
  plus a ten-shard suite stayed under 12 GB used on this box.
- The landing lock is the bottleneck at the end of a wave: every landing after the first one
  rebases and re-tests under the lock (about two to three minutes each), so six workers finishing
  together queue for a quarter of an hour. Stagger bead sizes, or re-test outside the lock.
- 73gr: a CFG is reducible exactly when every DFS retreating edge passes the dominance test, so
  the dominance check alone refuses every irreducible CFG whatever the DFS order; the single-entry
  check is kept as an assertion. A reducible loop with a `break` is still refused by c6ex's
  "second loop exit" (Bennett-8nfb scope). `test/test_loop_explicit.jl` has no `using Test,
  Bennett` and cannot run standalone.
- 2glq: only i1 reaches the new guard (`_vector_shape` already limits lanes to 1/8/16/32/64);
  vector stores outside sret already fail loud. A hand-written `define void` witness dies in
  `_type_width` before the instruction under test — give witnesses a non-void return.
- usly: a constant index never reaches the MUX callees (`_pick_alloca_strategy` sends every
  `ConstOperand` index to `:shadow`, which range-checks). The MUX decode compares the full 64-bit
  index; a cheaper low-bits decode would alias out-of-range indices, which the contract allows.

## Session log — 2026-10-03 — SESSION CLOSE: 50 beads landed, 3 reviews, 1 full suite; handoff — READ FIRST

**State.** `main` = origin at the commit that adds this file; last source commit 3a036b2
(Bennett-gq1z). 69 commits today before this one; 107 source and test files changed, +11,008 / −639. Tracker:
846 beads, 219 open (P1 21, P2 71, P3 112, P4 15), 615 closed. Today: 53 closed (50 landed by
workers + 6r3e, ero9, keu4 closed as side effects), 76 filed. Still in progress and untouched:
5viz, tzrs.

**What is verified, and what is not — do not overstate this.**
- The one full suite of the session ran at **d3d7ba1**: 1,789,592 pass / 2 fail / 4 error /
  7 broken, 61 min. Both failing files (4eu, 5qrn) were fixed and are green in targeted runs.
- **Twelve source commits landed after that run** — seven review-2 / suite fixes and five
  refuse-only fixes for review 3 — and are covered by targeted runs and landing-queue checks only.
- The five final-wave commits (44d1444, 10953a0, 01f70ac, 72ac0a5, 3a036b2) have had **no
  independent review**. They only add refusals, so the risk is rejects-valid, not wrong-result.
- BennettVM suite: 11,481 / 11,481 at Bennett c443621, i.e. before the final wave.
- Today's record on targeted testing: it missed four wrong-result or unsound-acceptance bugs
  (found by reviews) and four cross-file pin/message regressions (two found by workers by
  accident, two by the full suite). **First job next session: a full suite on the final tree,
  on a quiet machine** — that run also gives the clean wall-time needed to judge the 4ddk cache
  invalidation (Bennett-f69x, review-1 R6); today's 61 min was taken alongside compiling workers.

**Decisions waiting on the maintainer** (each is recorded on the bead named):
- Bennett-sl4h (P1): `bit_width` narrowing of optimised IR — narrow from unoptimised IR, keep
  refusing folded shapes (today's koi8 rule; every Int8 ordering at W < 8 is refused under
  `optimize=true`), or make it a lowering parameter as V2-PRD §D0 proposes. Bennett-3d1k is the
  cheap partial alternative (pass argument signedness).
- Bennett-armp (P1): `soft_pow` is within 2 ULP of `Base.:^`, not bit-exact (rule 13) — route
  `llvm.pow` through `soft_pow_julia` or document the exception. Bennett-vke7 (P1): `soft_atan2`
  1 ULP off on `atan(2.5, -1.0)`.
- Bennett-2op8 (P2): callable-struct fields and `Base.Fix2` still become circuit inputs (closure
  captures are now bound or rejected) — bind, reject, or keep.
- Bennett-usly (P2): an out-of-range runtime index into a MUX load returns the last slot — what
  should it mean, given a circuit cannot throw.
- V2-PRD D0 for the twelve class-1 recogniser beads (7v22, bc2m, po36, o6ge, q5hc, …): not
  touched today. Several fail-loud fixes in their neighbourhood did land (08xz, n4di, gq1z).
- Bennett-bnfk / i15z: under the corrected `toffoli_depth` (u3b2) the QCLA-tree multiplier
  roughly matches the paper (56/88/128 vs 62/90/124) instead of beating it, `target=:depth` picks
  a deeper multiplier than shift-and-add at W=32 (256 vs 190), and BENCHMARKS.md's depth columns
  are stale. BENCHMARKS.md was not edited today.
- `wip/i5zn-loop-header-effects` (local and origin) is superseded by cb8f65b + def89bc and can be
  deleted. BennettVM's CLAUDE.md rule 6 still describes 3+1 and per-change reviewer gating: the
  orchestrator's edit there was blocked by the permission classifier.
- `.beads/embeddeddolt/.../noms/vvvv…` grew 76.6 → 84 MB today (GitHub hard limit 100 MB);
  Bennett-amah.

**Next session, in order.** (1) Full suite on the final tree, quiet machine; BennettVM suite
after it. (2) One review over the five unreviewed final-wave commits (`c443621..3a036b2 -- src`).
(3) Open P1s with witnesses and a stated fix: 9fke (PointerType skip), 13xy (circuit output
signedness), 73gr then n9o8 (cfg.jl is now free; n9o8 has a ready witness from i5zn), xzsb and
jzhh are L-size. (4) The maintainer decisions above.

**What the wide mode cost and bought (for whoever orchestrates next).**
- Throughput: 50 beads in about five and a half hours with four Opus workers, Sonnet for triage,
  bookkeeping, witness execution and three quick fixes, gpt-6.1-sol (high) for three reviews.
  Claude weekly quota 41 % → 47 % (daily allowance ~13.5 %), Fable weekly 45 % → 46 %, Codex 1 %.
- Worker context: single small beads finished at 70–110 k tokens; paired beads and the hard ones
  (jkf0, 8aes, m11m+6p8j, i5zn, rrop, koi8) at 135–175 k. Pairing two beads per worker is not a
  saving.
- Batched review worked as a net and is not optional in this mode: 20 findings over three
  reviews, every executed witness confirmed, 19 fixed the same day. But fixes written against
  one witness seeded the next review's findings twice over (jkf0 → gw0r → rrop on GEP index
  composition is the clearest chain). What ended the chain was (a) fix briefs that demand a stated
  invariant plus a GENERATED test over the dimensions of the changed code, and (b) restricting
  the last wave to refusals.
- A worker's "related tests" are the users of the function it changed; nothing in a targeted run
  catches a test that pins a global count, an error message or an entry-point behaviour. The
  landing queue (own test files + gate-count baselines under the lock) removed re-test round
  trips but not this gap.
- The orchestrator's own diagnoses were wrong twice and corrected by the agents told to verify
  first (a captured `Type{T}` is an 8-byte pointer field, not a zero-size singleton; restoring a
  skip to fix a message reopened a silent drop). Keep the "confirm the diagnosis or stop" clause
  in every quick-fix brief.
- Mechanics that are easy to get wrong: `codex exec` from a background shell needs
  `< /dev/null`; the codex default model is not the reviewer; `Manifest.toml` is untracked and
  must be copied into each worktree; one flag set per worktree keeps the precompile cache from
  thrashing; `pgrep -f` wait loops match themselves.
