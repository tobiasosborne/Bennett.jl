# Worklog chunk 115 — 2026-10-03 — wide campaign: session close and handoff

Detail lives in chunks 110 (setup, batches 1–3), 111 (batches 4–6), 112 (batches 7–8, review 1),
113 (batches 9–10), 114 (batches 11–12, full suite, reviews 2 and 3, BennettVM suite).

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
