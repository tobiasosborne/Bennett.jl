### Cascade surfaced by U01 fix (now visible as test failures)

The strengthened `verify_reversibility` flipped exactly ONE previously-green
test to red: `test/test_value_eager.jl:158` (SHA-256 round via
`value_eager_bennett`). This is **Bennett-rggq / U02** exactly as the
catalogue predicted: value_eager_bennett leaks input state on branching
CFGs (sigma functions branch). Error: `input wire 97 changed from true to
false — Bennett input-preservation violated`. That single assertion is
marked `@test_broken` pending U02; the full suite is otherwise green.

All straight-line `value_eager_bennett` tests (257 incr + 257 poly + 442
two-arg + 516 cuccaro) still pass — confirming U02 is branching-specific
per the catalogue claim.

### Phase 0 status (per `reviews/2026-04-21/CATALOGUE_TO_BEADS.md` §E)

| Bead | U# | Title | Status |
|---|---|---|---|
| Bennett-asw2 | U01 | verify_reversibility tautology | ✓ closed |
| Bennett-rggq | U02 | value_eager_bennett 100% fail on branching | ✓ closed (partial; spawned Bennett-ca0i) |
| Bennett-egu6 | U03 | self_reversing=true unchecked trust | ✓ closed |
| Bennett-xy4j | U06 | soft_fmul subnormal pre-norm (2-line fix) | ✓ closed |
| Bennett-uj6g | U49 | Add CI workflow | ✓ closed |
| Bennett-prtp | U04 | checkpoint/pebbled_group_bennett crash on branching | ✓ closed |
| Bennett-ca0i | U02-followup | value_eager SHA-256 in-place bug | ○ (P2, spawned this session) |
| Bennett-httg | U05 | lower_loop! drops body-block instructions | ✓ closed (partial; 2 follow-ups filed) |
| Bennett-httg-f1 | U05-followup | diamond-in-body needs per-block predicates | ○ (P2, spawned) |
| Bennett-httg-f2 | U05-followup | header-body 4-type cascade dispatch gap | ○ (P3, spawned) |
| Bennett-k286 | U07 | soft_fpext sNaN quieting | ○ next (P1) |

### For U02 (next): what the catalogue says

From `reviews/2026-04-21/09_reversibility_invariants.md` §2 and
UNIFIED_CATALOGUE.md U02:

- **Site:** `src/value_eager.jl:29-137` (esp. 96-135); producers at
  `src/lower.jl:379,389` (`_compute_block_pred!`).
- **Root cause:** Phase-3 Kahn topological uncompute walks
  `input_ssa_vars`; synthetic `__pred_*` groups have
  `input_ssa_vars = Symbol[]`, so predicate-wire cross-group deps are
  invisible to the DAG and the entry-block predicate gets reversed before
  later consumers.
- **Safer fix (pick this first):** Refuse the Phase-3 Kahn path whenever
  any `__pred_*` group exists; fall back to `bennett(lr)`.
- **Harder fix:** Register predicate-to-predicate SSA deps on `__pred_*`
  groups so Kahn respects them.
- **RED test already exists:** `test_value_eager.jl:158` is currently
  `@test_broken`. Unbroken → green after fix.
- **Ground truth to read before coding:** `src/value_eager.jl` full,
  `src/lower.jl:379, 389` (pred producers), the failing test.

---

## NEXT AGENT — start here — 2026-04-21 (mother-of-all code review landed)

**This session spawned 19 independent code-review subagents in parallel; each
wrote a standalone report under `reviews/2026-04-21/`. No source code was
modified. The work of the NEXT session is to read those reports, triage, and
act. T5-P6 (Bennett-z2dj) remains open but is now blocked on deciding which
review findings to absorb before continuing.**

### Do this, in order

1. **Read every report in `reviews/2026-04-21/`** (19 files, ~9,000 lines total).
   They were deliberately NOT read in the spawning session to keep context clean
   for synthesis. Treat them as independent opinions — agents did not see each
   other's output.
2. **Triage into a consolidated punch list.** Expect heavy overlap between
   reviewers (e.g. `verify_reversibility` tautology flagged by #03, #05, #09,
   #16; `_convert_instruction` god function by #01, #06, #12; `lower.jl` size
   by #01, #06, #12, #13; dead `ir_parser.jl` by #01, #06, #10, #18;
   `LoweringCtx::Any` fields by #12, #13, #18; Manifest/Project.toml drift
   by #15, #16, #18). Deduplicate, rank by (severity × reach), file a bd bead
   per kept item.
3. **Decide the order of operations.** Several reviewers agree the highest-
   leverage single change is fixing `verify_reversibility` so the CI-style
   invariant check is no longer tautological; this reveals latent bugs the
   rest of the triage depends on. Do not jump to T5-P6 until the review debt
   is at least mentally sequenced.

### The 19 reviewer agents

| # | Slug | Focus |
|---|---|---|
| 01 | `structure_callgraph` | Module layout, includes, god-funcs, dead code |
| 02 | `vision_scope` | PRD vs reality, scope bloat, ossification sites |
| 03 | `test_coverage` | Orphan tests, vacuous assertions, coverage matrix |
| 04 | `edge_cases` | Adversarial inputs; overflow / NaN / subnormals |
| 05 | `integration_tests` | Feature × feature interaction coverage |
| 06 | `antipatterns` | God funcs, primitive obsession, flag sprawl |
| 07 | `arithmetic_bugs` | Off-by-one, width, sign, IEEE 754 compliance |
| 08 | `error_handling` | Fail-loud discipline, try/catch, error types |
| 09 | `reversibility_invariants` | Ancilla-zero, Bennett construction correctness |
| 10 | `llvm_ir_robustness` | value-kind / opcode coverage, silent drops |
| 11 | `softfloat` | Bit-exactness vs native, NaN payload, rounding |
| 12 | `torvalds` | Taste, simplicity, dead code, what to rip out |
| 13 | `carmack` | Measured perf, data flow, debuggability |
| 14 | `knuth` | Algorithmic elegance, proof obligations, citations |
| 15 | `docs_worklog` | Doc drift, onboarding path, WORKLOG hygiene |
| 16 | `api_surface` | Export list, kwarg design, stability, arity checks |
| 17 | `performance` | Gate-count baselines (live), compile time, type stab |
| 18 | `julia_idioms` | Dispatch, const, compat, ecosystem fit |
| 19 | `persistent_memory` | 5-impl audit; EoL recommendations |

### Agent executive-summary highlights (for triage orientation, not action)

These are the agent-reported headlines — **verify before acting**, since
agents' summaries describe what they intended to find, not necessarily the
ground truth. Expect some to be false alarms (see Sturm note below).

- **#03 / #05 / #09 all flagged `verify_reversibility` as tautological.** It
  only checks `gates + reverse(gates) == identity`, which is trivially true
  for any sequence of self-inverse gates. Real ancilla-zero check lives in
  `simulate`. If confirmed, this is the single most load-bearing fix.
- **#09 claims `value_eager_bennett` produces non-zero ancillae on every
  branching function** (256/256 inputs fail on a minimal `x > 0 ? x+1 : x-1`).
  Root cause alleged: Kahn's topo-order blind to cross-`__pred_*` deps.
- **#10 lists five CRITICAL `ir_extract` bugs** — i128 silent truncation,
  extractvalue on StructType crashes, switch phi-patching incomplete, GEP
  offset/index confusion, IRVarGEP elem_width default.
- **#11 `soft_fmul` subnormal precision bug** — missing `_sf_normalize_to_bit52`
  pre-normalisation; ~11–20% of normal×subnormal pairs off by 1–2 ULP. 2-line
  fix.
- **#04 `lower_loop!` drops body-block instructions** under `optimize=false`;
  `max_loop_iterations` is effectively a no-op.
- **#04 NaN sign/payload not preserved** across fadd/fsub/fmul/fdiv/fma/fsqrt
  (canonicalised to `0x7FF8...`). Violates CLAUDE.md §13 bit-exact claim.
- **#04 / #18 `soft_feistel_int8` is not a bijection** despite docstring claim;
  256 → 207 distinct images.
- **#17 performance review reproduced every WORKLOG/BENCHMARKS gate-count
  baseline exactly.** Zero regression drift.
- **#17 `:auto` add dispatcher strictly worse than `:ripple`** on i32+ (410
  vs 350 gates, T-depth 124 vs 64). Silent pessimisation.
- **#15 CLAUDE.md §6 gate-count baselines stale** — cites 86/174/350/702;
  actual 100/204/412/828. (BENCHMARKS.md agrees with live numbers.)
- **#15 CLAUDE.md references `bennett.jl` which no longer exists** — renamed
  to `bennett_transform.jl`; doc never updated. Same rename missed in
  `docs/src/architecture.md`.
- **#01 `lower.jl` at 2,662 LOC / 93 top-level defs** — unanimous split
  recommendation from #01, #06, #12, #13.
- **#16 `simulate(c_single_arg, (x, y))` silently returns garbage** — arity
  check missing in `src/simulator.jl:10–14`.
- **#16 `NOTGate`/`CNOTGate`/`ToffoliGate` documented as public but not
  exported** — following docs produces `UndefVarError`.
- **#16 `Project.toml` version = 0.4.0** despite v0.5 PRD implemented;
  `julia = "1.6"` contradicts README's 1.10+.
- **#19 `hamt_pmap_set` silently drops data at 9th distinct-hash key**;
  `cf_reroot` breaks on key=Int8(0); both untested.
- **Multiple reviewers: delete `ir_parser.jl`** — regex LLVM parser, dead,
  CLAUDE.md §5 explicit violation, still exported.

### ⚠️ Known false alarm in the reports: Sturm integration

Several reviewers (#02 most prominently) flagged missing Sturm.jl integration
(`when(qubit) do f(x) end`) as an unfulfilled vision commitment with "zero
code in src/." **This is a nothingburger.** The integration is already done
on the Sturm.jl side — Bennett.jl doesn't need to host it. The VISION-PRD's
phrasing made this ambiguous. Ignore any finding that implies Bennett.jl must
grow Sturm-facing code. If you file a bead for "Sturm integration," close it
as wontfix with a link to this note.

### What this session did NOT do

- **Did not read the reports** — deliberately, to keep synthesis for the next
  session with a fresh context. All 19 reports were written by independent
  subagents; this session only saw each agent's ~15-line return summary.
- **Did not modify any source code.** No src/ changes. No test/ changes.
- **Did not verify any of the claimed bugs.** All bullets above are
  agent-reported; treat as hypotheses until triaged.
- **Did not close any beads.** T5-P6 (Bennett-z2dj) remains claimed; the bead
  should be updated with "review debt queued" before next work.

### How to run the review factory again

The prompt template used to spawn reviewers lives implicitly in this
session's message history (git-visible via the Claude Code transcript, if
enabled). The recipe:

1. One orchestrator pre-creates `reviews/<date>/` and lists files.
2. Launch N agents in parallel, each with a self-contained brief that names
   (a) the output path, (b) its jurisdiction, (c) CLAUDE.md + WORKLOG pointers,
   (d) format (executive summary + CRITICAL/HIGH/MEDIUM/LOW/NIT).
3. Each agent has Glob / Grep / Read / Bash; no Write except for its own
   report.
4. Orchestrator never reads full outputs; only each agent's return summary.
5. Next session reads the reports cold.

### Previous NEXT AGENT header (T5-P6 unblock — still valid, but now
gated on review triage)

Preserved below for continuity. The α/β/γ infrastructure landings from this
session stand; T5-P6 implementation remains the next forward-progress work
once review debt is triaged.

---

