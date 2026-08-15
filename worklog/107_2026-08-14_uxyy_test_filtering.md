# Worklog chunk 107 — 2026-08-14 — test-suite speed: measurements + test_args filtering

## Session log — 2026-08-15 — Bennett-0orf: v2 rearch sweep (14 agents) + reimplementation plan (Bennett-V2-PRD.md)

**Trigger:** maintainer (at JuliaCon) called for a sober from-scratch
reconsideration of Bennett.jl on Julia 1.13, assuming code generation is
free. Ran one workflow: 5 sonnet research agents (1.13 changelog,
odd-bit ints, parser/introspection, LLVM shift, ecosystem precedents) +
8 opus reviewers (extraction, lowering, circuit core, softfloat, memory,
API/tests, whole-architecture, worklog lessons-ledger) + 1 completeness
critic. ~3.0M subagent tokens, 748 tool calls, all 14 landed. Reports
archived: `docs/design/rearch-2026-08/` (13 reports + critique).
Synthesis by orchestrator: **Bennett-V2-PRD.md** at root.

**Load-bearing findings (see reports for cites):** (1) 1.13 has NO
native Int2 — PR #61359 merged to master AFTER the 1.13 branch,
arithmetic intrinsics untested upstream (r2). (2) 1.13's real payload:
LLVM 18→20 (undocumented in NEWS.md) + Julia codegen PRs #61535
(cascaded bounds-check CFGs — lands on the phi resolver) and #61394
(memory-attr propagation — lands on the packed-int decoder) (r1, r4).
(3) IRCode substrate empirically WORSE than LLVM (Mooncake ~91-commit
1-minor-version port; Compiler.jl v0.1 a placeholder) (r3, r5).
(4) extract/ = 46% of src/, is a Julia-codegen decompiler; wall
treadmill locally converging, globally diverging (c7 §5c). (5) Verified
v1 bugs found by the sweep: add=:cuccaro aliasing unsound (c2),
strategy layer dead in production + PebbledStrategy provably identity
(c3), compose drops loop_check_wires (c3), MUX-EXCH 15-40x worse than
the arm it preempts (c5), test_doh6 green-asserting the opposite of
truth (c6). (6) c8's meta-lesson: verify_reversibility was tautological
for months — v2's FIRST code must be ancilla-zero-after-FORWARD.

**Plan decisions (committed):** D0 narrow input contract (scope before
substrate — the critique's central move); D2 keep LLVM, kill the
sprint(code_llvm) text round-trip; D3 predicated BIR + hierarchical
Circ (Prim/Seq/Adj/Compute/Ctl/Scope + Call/uncall frames); D4
RegFile{N,W}; D5 one space-budgeted scheduler replacing six strategies;
D6 softfloat port-then-shrink; D7 one CompileSpec; D8 sound oracle
first + bit-sliced simulator + parallel tiers. Open (PRD §8): BennettVM
disposition, gate alphabet/Sturm, repo location, language-neutrality.

**Filed:** epic Bennett-0orf + spikes S1–S6 (Bennett-ctz0, -5vgb,
-vysm, -eis4, -o540, -ctsc). S5 doubles as v1's Bennett-gm83 unblock.

**Gotcha for future agents:** the sweep's three sharpest
recommendations (StructurizeCFG if-conversion, RegFile 10-200x, "1.13
is safe") are UNVERIFIED inferences — the spikes exist to falsify them
BEFORE any v2 commitment. Do not start P1 until S1/S2 land.

**Post-sweep correction (same day):** maintainer reports the
State-of-Julia keynote (Bezanson) said odd-width primitives WILL be in
1.13 — contradicting r2's "1.14-earliest". Re-verified by CONTENT, not
ancestry (r2's git-ancestry test was methodologically weak: backports
are cherry-picks, so "diverged" proves nothing): release-1.13@rc3
builtins.c STILL enforces `(nb & 7) != 0` and no backport PR for
#61359 exists as of 2026-08-15. Unresolved — pre-GA backport vs
keynote speaking ahead of the branch. PRD §0/D0 reworded to a
capability-based trigger (odd-width ARITHMETIC intrinsic tests
upstream, any version); S1 bead amended to re-check the GA build and
to test i2/i3/i63 arithmetic directly if present. Lesson banked: for
"is feature X in release Y", check the release branch's SOURCE, never
merge-commit ancestry.

## Session log — 2026-08-14 — Bennett-uxyy: test_args file filtering in runtests.jl (JuliaCon-prompted test-speed session)

**Trigger:** user at JuliaCon heard about a "hidden Pkg.test flag that stops
cache invalidation". Identified: `Pkg.test(julia_args=["--check-bounds=auto"])`
(the discourse thread "Avoiding recompilation between interactive use and
testing by making testing also checkbounds=auto"). Pkg.test always launches
its child with `--check-bounds=yes`, which keys a SEPARATE precompile-cache
flavor from the `auto` flavor your REPL uses; the flag makes the test child
reuse the REPL flavor.

**Measured on this machine (Julia 1.12.5, laptop) before recommending:**
- One Bennett precompile (one cache flavor) = **104 s**. Warm `using Bennett`
  = **1.4 s** (auto) / **1.6 s** (yes). Each flavor's `.so` is ~30 MB.
- `~/.julia/compiled/v1.12/Bennett/` held **9 flavors**, several rebuilt the
  same morning → real churn exists, likely eviction thrash: the default
  `JULIA_MAX_NUM_PRECOMPILE_FILES` cap is **10** and we sit at 9–10.
- Full suite ~28 min. So the JuliaCon flag's ceiling here is ~104 s of
  28 min — AND it changes semantics: the suite mode is pinned to
  `--check-bounds=yes` (Bennett-2mj3: some tests behave differently).
  **Verdict: not the right lever for Bennett; the cost is serial execution
  of 314 files in one process.** Filed Bennett-gm83 (parallel file runner,
  the real lever) with design constraints (precompile-once-then-spawn to
  respect the concurrent-precompile corruption issue; RAM-aware worker
  count; LPT scheduling off runfile's per-file timings).

**Shipped (Bennett-uxyy, ~40 LOC in test/runtests.jl):** substring file
filters from ARGS. `Pkg.test(test_args=["softfexp"])` or
`julia --project --check-bounds=yes test/runtests.jl softfexp` runs only
matching files **in canonical suite mode** — kills the "per-file green must
match suite mode" foot-gun for daily dev. No ARGS → byte-identical old
behavior (`isempty` short-circuit). Guard rails: yellow FILTERED RUN banner
before AND after (the last line of a filtered run names itself, so a pasted
tail can't masquerade as full-suite green), and a **fail-fast `error()` when
a pattern matches zero files** (a typo'd filter must not report an empty
green — exit code 1, verified).

**Verified:** (1) standalone filtered run, 2 files → 514 asserts in 12 s,
"ran 2, skipped 307"; (2) zero-match → ERROR + exit 1; (3) end-to-end
`Pkg.test(test_args=["test_increment.jl"])` → 257/257, "Testing Bennett
tests passed". Full-suite no-ARGS path not re-run this session (laptop,
28 min) — it is the unchanged code path.

**Gotcha for future agents:** `runfile` call-site count (317) ≠ skip counts
you'll see (307–309 + ran): the delta is the env-gated blocks
(BENNETT_RESEARCH_TESTS default-off etc.) — gated-off files never reach
`runfile`, so they are neither run nor counted as skipped.

**Left open:** Bennett-gm83 (parallel runner). Also worth a cheap try
someday: raising `JULIA_MAX_NUM_PRECOMPILE_FILES` above 10 in the shell
profile to stop flavor eviction thrash (not repo-configurable; user-env
decision, so not a bead).
