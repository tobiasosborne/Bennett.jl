# Bennett.jl Work Log

## Session log — 2026-04-25 — Bennett-uoem / U54 persistent-DS research relocation (5 cycles, GREEN)

**Shipped:** see git log around 4d65381..1d88dbd; six commits across 0–5 cycles
that relocate the four "loser" persistent-map implementations (Okasaki RBT,
Conchon-Filliâtre semi-persistent, Bagwell HAMT + popcount helper, Mogensen
Jenkins-96 reversible hash) from `src/persistent/` to
`src/persistent/research/`. Preserved-not-deleted per user directive: each
file remains on disk with a literate deprecation header pointing at
`src/persistent/research/README.md`. Production-path tests run by default;
research-tier tests opt-in via `BENNETT_RESEARCH_TESTS=1`. Bennett namespace
went from 73 → 56 exports (persistent-related: ~30 → 7).

**Why:** Bennett-uoem / U54 (catalogue-derived bead). The 2026-04-20 scaling
sweep (`worklog/026_*.md`) showed `linear_scan` per-`set` cost is constant in
`max_n` (~1,400 gates) while CF grows quadratically, with HAMT and Okasaki's
cost floors strictly above LS by cost-model. Even cheapest hash + cheapest
loser (CF + Feistel) at `max_n=4` is 150× LS. The persistent subdirectory
had four unmotivated impls in the production path. User directive: do NOT
delete — these encode real algorithmic content (Bagwell HAMT, Okasaki RBT,
CF semi-persistent arrays, Jenkins-96 reversible hash) and may yet shine on
different workload shapes. Park-with-rationale instead.

**Gotchas / Lessons:**

- **Reference graph was exceptionally clean.** Three independent Explore
  agents up-front (file inventory / ref graph / test coverage) all
  converged: only three touch points outside the 5 files —
  `src/Bennett.jl` exports (38–44), `src/persistent/persistent.jl`
  includes (9–17), and one internal cross-dep (`hamt.jl` → `popcount.jl`).
  Zero references in `benchmark/`, `scripts/`, or non-persistent `src/`.
  No `register_callee!` registrations. `harness.jl` is impl-agnostic
  (functions take `PersistentMapImpl` as arg, no hard-coded list). This
  cleanliness is what made the relocation feasible in 5 cycles —
  if there had been transitive deps the cycle count would have ballooned.

- **`popcount.jl` is HAMT-only.** Confirmed via repo-wide grep: the only
  callers of `soft_popcount32` are `hamt.jl:92` and `hamt.jl:246`. The
  research README was originally going to flag it as "ambiguous —
  exported but no live consumer" but the empirical answer is simpler:
  HAMT is its sole consumer, both move together.

- **Function definition vs call-time name resolution.** `_ok_jenkins_demo`
  and friends in `test_persistent_hashcons.jl` reference
  `Bennett.okasaki_pmap_*` in their bodies. Since Julia resolves
  identifiers in function bodies at call time, removing names from the
  Bennett module didn't fail at parse time — only when the layered
  `test_layered_demo("Okasaki+Jenkins", ...)` actually called the demo.
  This delayed-failure mode is why I caught the breakage with regression
  spot-checks rather than load-time errors. Lesson: when removing
  exports, grep for *both* qualified usages (`Bennett.X`) and name
  imports (`using Bennett: X`) and call sites that bind via the export.

- **Test files load research sources via `include(...)`, not module deps.**
  Each gated test file does
  `include(joinpath(pkgdir(Bennett), "src/persistent/research/<file>.jl"))`
  at the top after `using Bennett`. The relocated files are kept as
  bare include lists (no `module` wrapper) — same convention as the
  existing `softfloat/` and pre-relocation `persistent/` directories,
  flagged generally in U90 (Bennett-iwv5) but not addressed here. After
  include, identifiers live in the test's enclosing module (Main when
  run via Pkg.test).

- **Parameter ordering matters: popcount must include before hamt.** In
  test_persistent_hamt.jl and the research-gated hashcons file, the
  `popcount.jl` include line comes first because `hamt.jl` defines
  functions whose body references `soft_popcount32`. Reverse the order
  and you get `UndefVarError: soft_popcount32` at hamt-define time.
  The README documents this dependency.

- **Test pattern: per-cycle RED → GREEN on `test_uoem_research_relocation.jl`.**
  Each cycle's first commit-step extends the relocation invariant test
  with assertions for THIS cycle's impl (file-at-new-path, file-not-at-old,
  symbols-not-in-`names(Bennett)`). The test deliberately fails first
  (RED), then the move makes it pass (GREEN). This caught one case where
  I almost forgot to drop the export from `Bennett.jl` — the relocation
  test surfaced it immediately.

- **U75 (Bennett-ph5m) collapsed without surgery.** The original concern
  was "25+ identifiers leak into top-level Bennett namespace with no
  stable ABI." Cycles 1–4 dropped 23 of those 25+ via the loser
  relocation; the remaining 7 are intentional public API
  (`PersistentMapImpl`, `LINEAR_SCAN_IMPL`, `verify_pmap_correctness`,
  `pmap_demo_oracle`, `AbstractPersistentMap`, `soft_feistel32`,
  `soft_feistel_int8`). Submodule-wrapping these 7 would break every
  existing consumer for marginal gain. U75 deferred with audit
  rationale recorded in bd notes.

- **`test_persistent_hashcons.jl` straddled two coverage modes.** It had
  6 layered demos all touching loser DS impls, plus a Jenkins standalone
  test (loser hash) AND a Feistel standalone test (winner hash). Cycles
  1–4 progressively gated the file as each impl moved; Cycle 5 then
  extracted the winner-side Feistel block into a new
  `test/test_hashcons_feistel.jl` on the default path. Net loss for
  default test coverage during cycles 1–4: 4 Feistel assertions
  (restored in Cycle 5).

- **Bead "moots" list not yet acted on.** U54 lists 12 mooted sub-bugs
  (U20 hmn0, U21 n3z4, U22 sqtd partial, U120 e89s, U121 ivoa, U122
  uxn2, U123 jvpm, U124 fa4g, U125 okvg, U126 wout, U162 d1io, U207
  tzga). These bugs now live in research-tier code, no longer in the
  production path. They're not yet closed because (a) some bugs still
  apply if the impls are ever thawed, (b) a few bead-tagged regression
  tests still exist gated under `BENNETT_RESEARCH_TESTS`. Future
  cleanup: walk through each bead, decide close-vs-defer-vs-lower-priority.

**Rejected alternatives:**

- **Option A: outright deletion.** Bead's first option, recommended by
  the original reviewer. User explicitly rejected: "DO NOT DELETE."
  These impls encode real algorithmic content; cost-model verdict is
  workload-class-specific (populate-to-capacity reads). May yet win on
  K ≪ max_n random reads, post-`optimize=true` maturity, or different
  cost metrics.

- **Wrap each research file in a module (`module Okasaki ... end`).**
  Considered for namespace cleanliness — would let consumers say
  `Bennett.Persistent.Research.Okasaki.OKASAKI_IMPL`. Rejected because:
  (a) requires editing each relocated file with `module/end` wrappers,
  (b) test files would need three-segment access paths, (c) the
  `include(...)` pattern is simpler and matches existing
  `softfloat/`/`persistent/` conventions.

- **Don't load research files at module init at all.** Considered for
  maximum production-path cleanliness. This is what I shipped — research
  files are *not* part of the `Bennett` module, only loaded via explicit
  `include()` from gated test files or ad-hoc REPL sessions. Trade-off:
  no automatic drift detection (research code can rot if `interface.jl`
  changes). Mitigation: README documents the periodic
  `BENNETT_RESEARCH_TESTS=1 Pkg.test()` regimen before any thaw decision.

- **Wrap the surviving 7 persistent exports in a `Bennett.Persistent`
  submodule (Cycle 6 / U75).** Considered, rejected. Original U75
  concern was scale (25+ leaks); post-cycles-1-4 scale is 7 names of
  intentional public API. Submodule wrapping breaks every consumer for
  marginal gain. Deferred to a broader public-API audit if/when it
  matters.

- **Move test files into `test/research/` subdirectory.** Considered
  for visual symmetry with `src/persistent/research/`. Rejected because
  (a) requires updating `test/runtests.jl` paths and dotest convention,
  (b) the env-var gate already segregates them clearly, (c) one fewer
  layer of indirection is preferable.

**Next agent starts here:** U54 file relocation is complete; bead can
close. Outstanding follow-ups (separate work):

1. **Walk the U54 mooted list** (12 sub-bugs above): close, defer, or
   lower-priority each. Bugs that only manifest in research-tier code
   are not blocking the production path; their priority should reflect
   that.

2. **Decide on the gated regression tests' priority.** The two
   bead-tagged regressions that ride under `BENNETT_RESEARCH_TESTS`
   (`test_hmn0_hamt_overflow.jl`, `test_n3z4_cf_reroot_key_zero.jl`)
   are correctness regressions for code that's no longer on the hot
   path. Keeping them gated is fine; the question is whether to also
   close their parent beads (U20 hmn0, U21 n3z4) or keep them open as
   "fixed in research-tier code."

3. **U75 / Bennett-ph5m** sits at deferred-with-rationale; reassess if
   the persistent-related export count grows above ~10 again, or as
   part of a broader exports-vs-public-docs audit (U51 / Bennett-qcse).

4. **Final Pkg.test baseline:** GREEN with `BENNETT_RESEARCH_TESTS`
   unset (default). To verify research-tier code still compiles, run
   `BENNETT_RESEARCH_TESTS=1 julia --project -e 'using Pkg; Pkg.test()'`
   periodically.

5. The next agent can pick from the catalogue P2 ready list (35
   remaining) — U72 (Bennett-5p1c, gpucompiler/ gitignore) and U74
   (Bennett-awon, BENCHMARKS.md MD5 stale) are fast doc-snacks; U64
   (Bennett-bq5m, optimize=true default contradicts CLAUDE.md §5) is
   a small principled fix.
