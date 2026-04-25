# Bennett.jl Work Log

## Session log — 2026-04-25 (afternoon) — catalogue grind, 13 P2 beads cleared

**Shipped:** see git log around `8972540..b427c8c` (`bd: sync dolt cache (close U72/...)` through the most recent push). Thirteen catalogue P2s closed/deferred plus a CLAUDE.md §14 cleanup.

| Bead | What |
|---|---|
| **U72** Bennett-5p1c | `gpucompiler/` confirmed third-party (JuliaGPU GPUCompiler.jl clone), gitignored with comment. |
| **cc0** | Memory epic closed-as-superseded — T0/T1/T2/T3/T4 + T5-P1..P5 all shipped per worklog 020-024 + 027-032. T5-P6 continues as Bennett-z2dj. |
| **U75** Bennett-ph5m | Formally `bd defer`d to 2026-10-25. Audit rationale: persistent-related Bennett exports went 30→7 via U54; remaining 7 are intentional public API. Submodule wrap unnecessary. |
| **U74** Bennett-awon | BENCHMARKS.md MD5 headline 48k→43,520 Toffoli (1.58× ReVerC, was 1.75×). Re-measured via `julia --project benchmark/bc2_md5.jl`. Memory plan critical-path block extended to T4 + T5-P1..P5 + T5-P6 in_progress + T5-P7 future. Memory-PRD §6.1 status block added. |
| **U73** Bennett-ihhk | STATUS headers on 6 versioned PRDs in docs/prd/. VISION-PRD §4 Tier 4 walked back from "100% coverage / NOTHING IS OUT OF SCOPE" overclaim — split into (a) targets-with-real-lowering vs (b) clear-error refusals (va_arg, callbr) per CLAUDE.md §1 fail-fast. |
| **U71** Bennett-dmsm | `docs/design/` reorg: 30 frozen proposer/research files → `docs/design/archive/`. Top level now 14 *_consensus.md + INDEX.md + archive/. INDEX.md has stale-numbers warning header. |
| **U64** Bennett-bq5m | Deferred to 2026-08-01 — flipping `optimize=true` default would re-baseline every pinned gate-count regression + force re-measurement of every BENCHMARKS entry. Multi-hour coordinated workstream, not a doc-snack. |
| **U49** Bennett-uj6g | Re-close-as-superseded note. **`.github/workflows/test.yml` deleted** (59 lines) — the U49 close on 2026-04-24 had violated CLAUDE.md §14 (added afterwards on grounds of "failure-email noise is worse than zero signal"). Workflow had been spamming user. The intended quality gate is local: scripts/pre-push hook running Pkg.test() before push. |
| **U63** Bennett-mlny | `test/test_mlny_depth.jl` added — 22 assertions: empty=0, sequential same-wire (n=1..5)=N, parallel disjoint (n=1..8)=1, mixed (NOT‖NOT then Toffoli)=2, CNOT chain (n=1..4)=N, regression-anchor `x+Int8(1)→19` from docstring example, depth ≤ length(c.gates) on i8/i16. |
| **U67** Bennett-6l2h + **U66** Bennett-xmdx | One file, two beads — `test/test_6l2h_branching_callee.jl`. Exhaustive Int8 sweep on `_abs_i8` (sign-bit branch) and `_piecewise_i8` (branch + arithmetic) under (a) `compact_calls=true` and (b) `controlled()` wrapping with ctrl=0/1. 772/772 + 1026/1026 GREEN. The bead's claimed risk ("MUX × controlled may leak ancillae when ctrl=0") did NOT materialise. |
| **U42** Bennett-cs2f | `src/ir_parser.jl` deleted (-168 LOC). 8 `parse_ir()` callsites in test_parse / test_branch / test_loop ported to `extract_parsed_ir()`. `_reset_names!()` empty stub at ir_extract.jl:266 also deleted. `parse_ir` export removed (56→55). CLAUDE.md §5 violation cleared. |
| **U51** Bennett-qcse | 6 documented-public types now exported: NOTGate, CNOTGate, ToffoliGate, ReversibleGate, ParsedIR, LoweringResult. Soft-float and persistent-DS submodule-wrap suggestions deferred under U75. |
| **U69** Bennett-l9az | `src/lower.jl` -90 LOC: `has_ancestor`, `on_branch_side`, `_is_on_side`, `resolve_phi_muxes!` deleted. Verified zero external references via repo-wide grep before deletion. Live phi dispatcher routes only to `resolve_phi_predicated!`. lower.jl now ~2,572 LOC (still U40 territory). |

**Why:** continuation of 2026-04-25 morning's doc-work batch + the afternoon's U54 close. User: "keep working on code review catalog. just grind through the issues one by one and clear the catalogue." So that's what happened — straight grind through the P2 ready list, one bead at a time, RED-GREEN where applicable, push every 3-5 commits to amortize the 5-min Pkg.test pre-push hook.

**Gotchas / Lessons:**

- **`.github/workflows/test.yml` was a §14 violation.** The U49 close on 2026-04-24 had added it; CLAUDE.md §14 was added afterwards explicitly banning GitHub CI on the grounds that "the failure-email noise is worse than zero signal." The workflow had been spamming the user with failure emails. **Future agent**: never propose CI; never re-add `.github/workflows/`. Local gates only (scripts/pre-push hook runs Pkg.test).

- **Catalogue claims sometimes lie.** Three caught today:
  - **`Bennett-cc0`** had "cc0.1..cc0.7" sub-references in worklog/notes, but only `Bennett-cc0.5` is actually a separate bead (`bd search cc0`). The others are sub-tags inside the parent bead's narrative.
  - **`Bennett-awon`** claimed MD5 headline at "~48k Toffoli (1.75× ReVerC)" — actual measurement today is 43,520 Toffoli (1.58×). The post-Cuccaro-self-reversing improvements brought it down.
  - **`Bennett-uoem` U54 mooted-list** claimed `Bennett-e89s` (U120 linear_scan absent-key collision) and `Bennett-ivoa` (U121 harness gaps) were mooted by the relocation — but linear_scan and harness are WINNERS (kept on production path), so those bugs still apply. Notes on both corrected this morning.
  - **General lesson**: cross-check every catalogue claim against current code/measurements before acting on it. Memory entry `feedback_doc_work_mode.md` already says this; reconfirmed twice today.

- **Working-directory drift in the Bash tool bit me twice.** Bash sessions persist `pwd` between commands. After `cd docs/design && git mv ...` I forgot to `cd -` and a subsequent `git add docs/design/INDEX.md` resolved relative to the new pwd, missing the file. Worked around with explicit `cd /home/tobiasosborne/Projects/Bennett.jl && ...`. Future agent: prefer absolute paths in `git mv`/`git add` to avoid the trap, OR always cd back to repo root after any subdir cd.

- **Function-body name resolution in Julia is at call time, not parse time.** When I removed loser persistent-map exports during U54, test files defined functions whose bodies referenced `Bennett.okasaki_pmap_*` — those compiled fine. The `UndefVarError` only surfaced when the *layered demo functions* were called. So `using Bennett` + `using/import` lines at the top of a test file fail at load time, but `Bennett.<unexported>` references inside function bodies are silent until exercised. Useful when staging a multi-cycle relocation, but don't trust load-time-green to mean migration-complete.

- **Per-bead-per-commit + push every 3-5 commits.** The pre-push hook runs `Pkg.test()` (~5 min cold). One push per cycle = ~30 min of pure hook waits across this session. Batching to ~3-5 commits per push amortised that, while keeping the per-bead commit history clean for `git log` review. The `bd: sync dolt cache (close ...)` separator commits keep code commits and bd-state commits visually distinct in `git log`.

- **`bd defer` vs prose-only deferral.** Earlier I deferred Bennett-ph5m by writing prose in `bd update --notes` but didn't change status. The bead kept showing in `bd ready`. Formal `bd defer <id> --until=<date>` is what removes it from the ready queue. Same for `bd close --reason="..."` — the reason string ends up in `bd show` and `git log` (via the close-out commit), so write it to be useful when re-read months later.

- **Catalogue mooting is workflow-sensitive.** U54 originally listed 12 mooted sub-bugs assuming Option A (deletion). User chose Option B (relocation). Under Option B, bugs in research-tier code stay technically present but are no longer on the production path. The right action wasn't to close those 12; it was to add a one-line bd note flagging "research-tier-only since 2026-04-25" so a future agent knows the priority should drop, not that the bug is fixed. Done for 11 of 12 (sqtd is winner-side, not mooted).

**Rejected alternatives:**

- **Move root PRDs (Bennett-VISION-PRD.md, Bennett-Memory-PRD.md, Bennett-Memory-T5-PRD.md) to `docs/prd/`** as U73 suggested. Rejected: CLAUDE.md File Structure block (refreshed today via Bennett-vlab) deliberately distinguishes ACTIVE scope-specific PRDs at root vs VERSIONED-HISTORICAL PRDs in `docs/prd/`. Same content split, different categories.

- **Flip `optimize=true` default in U64.** Rejected: 35 explicit `optimize=true` test sites + ~67k assertions in tests that don't pass `optimize=` at all. Flipping = re-baseline `test_gate_count_regression.jl` + every `BENCHMARKS.md` entry + audit downstream consumers. Multi-hour coordinated workstream. Deferred to 2026-08-01.

- **Submodule-wrap remaining 7 persistent + 21 soft-float exports** (U75 / Bennett.Persistent + Bennett.SoftFloat). Rejected: original "25+ leak" concern is gone (post-U54 it's 7 + 21 = 28 names, all intentional public API). Submodule wrap forces every consumer prefix-bump for marginal cleanliness gain. Deferred under Bennett-ph5m.

- **Refactor portion of U67** (factor compact/non-compact arms in `lower_call!` into `_splice_callee_gates!`). Rejected: kept the bead's commit scope-tight to test coverage; can refile if it matters.

- **Aqua.jl / JET.jl gates** — not on this session's path; tracked under U210 (Bennett-gk1h, P4) and would require careful review against §14.

**Next agent starts here:**

1. **Branch state at session-end**: `b427c8c` on main, up to date with origin. Worklog top is this chunk (`worklog/038_*.md`, 175 lines pre-this-entry, prepend the next session's log here until the file passes ~280 lines then start `worklog/039_*.md`). All tests GREEN on the default path; research-tier path verified separately under `BENNETT_RESEARCH_TESTS=1`.

2. **DO NOT re-add `.github/workflows/`** under any circumstance (CLAUDE.md §14, reinforced today). Local gates only: `scripts/pre-push` runs `Pkg.test()`. If a future bead/review proposes CI, treat as out-of-scope and substitute the local hook.

3. **The catalogue ready list has shifted to deeper work.** ~30 P2s remain ready. The doc-snack tail is largely cleared today. Next-batch character:

   - **Real bugs (1-3h each, root-cause investigations):**
     - `Bennett-jepw` U05-followup — `lower_loop!` body blocks need per-block path predicates for diamond-in-body.
     - `Bennett-ca0i` U02-followup — `value_eager_bennett` leaks on SHA-256-style in-place arithmetic.

   - **God-file refactors (3+1 protocol per CLAUDE.md §2, multi-session each):**
     - `Bennett-vdlg` U40 — `src/lower.jl` is 2,572 LOC / 93 top-level defs (was 2,662; -90 from U69 today).
     - `Bennett-tzrs` U41 — `_convert_instruction` is a 649-line opcode god-function.
     - `Bennett-ehoa` U43 — `LoweringCtx` has 3 `::Any` hot-path fields + 4 back-compat constructors.

   - **Test-coverage gaps that may surface bugs:**
     - `Bennett-25dm` U62 — T5 corpus (TJ1/TJ2/TJ4; TC1-3; TR1-3) still `@test_throws`. Real fixes needed in `ir_extract.jl`.
     - `Bennett-9x75` U61 — soft-float fuzzing narrowly in [-100,100]; expand to subnormals/NaN/extreme exponents.
     - `Bennett-0zsk` U46 — many `error()` sites in core have no `@test_throws` coverage.

   - **Refactor-with-care:**
     - `Bennett-v958` U68 — IROperand primitive-obsession tagged union.
     - `Bennett-5qrn` U57 — trivial-identity peepholes (x+0, x*1, x|0). Bounded but can shift baselines.

   - **Live in_progress (already on someone's plate):**
     - `Bennett-z2dj` T5-P6 dispatcher — needs 3+1 protocol, U54 unblocked it.
     - `Bennett-cc0.5` T5-P6.3 thread_ptr GEP — narrow ir_extract gap.

4. **Velocity drop expected on next batch.** Today's pace was 13 P2s in ~3h on the doc-snack tail. The next batch is qualitatively different — expect 3-5× slower per bead because each requires real investigation (bugs) or 3+1 agent dispatch (refactors).

5. **The 12 U54-mooted sub-beads need a walk-through.** I tagged 11 of them with "code now in research-tier per U54" notes (skipped sqtd because Feistel is winner-side; e89s/ivoa got correction notes because they're winner-side bugs the bead mistakenly listed). Future cleanup: read each, decide close-as-research-tier-only vs lower-priority vs keep-open. Worth a single 30-min triage block.

6. **Catalogue clearance ~45%** of the original 173. The remaining ~95 P2/P3/P4 will not all close — some are deliberate non-actions (e.g. CI ones), some are vision-tier / paper-target (Bennett-ktt8 / Bennett-2uas / Bennett-6siy) that need actual benchmarks run first.

7. **bd .beads permissions warning** appears on every bd command (`Warning: /home/tobiasosborne/Projects/Bennett.jl/.beads has permissions 0755 (recommended: 0700)`). Suggested fix per the warning: `chmod 700 /home/tobiasosborne/Projects/Bennett.jl/.beads`. I did not do this autonomously (touches user-owned filesystem permissions); the user can run it whenever the noise becomes annoying.

---

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
