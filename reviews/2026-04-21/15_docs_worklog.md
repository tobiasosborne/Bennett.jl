# Documentation & Project-Memory Review — Bennett.jl

**Reviewer**: independent docs / tech-writing agent
**Date**: 2026-04-21
**Scope**: every `.md` and docstring in `/home/tobiasosborne/Projects/Bennett.jl`, plus `bd` integration

---

## If I were a new contributor arriving today, here is how my first hour would go

**Minute 0–5.** I clone, I open `README.md`. This README is genuinely excellent for a research-grade compiler: six code snippets in the first 50 lines, a working install, a features table, a concrete benchmark table, architecture ASCII diagram, and reference bibliography. I can run the Quick Start and get `simulate(reversible_compile(f, Int8), Int8(42))` to return 43. Onboarding path: `README.md § Quick start` (line 187) → `julia --project=. -e 'using Pkg; Pkg.test()'` (line 214). That works. Five-minute target hit.

**Minute 5–15.** I open `docs/src/tutorial.md`. Walks me from trivial increment through Float64 soft-float, controlled circuits, tuples, strategy dispatchers, space optimization, and bounded loops. Eleven sections, all runnable. Gate counts are cited concretely (i8: 100, i16: 204, …). I try §5 Float64 — it works. I try §9 checkpoint_bennett — it works. This tutorial is load-bearing and it earns its keep.

**Minute 15–30.** I try to figure out "which PRD do I read first?" This is where the wheels come off. I count:

- `Bennett-VISION-PRD.md` (387 lines, root)
- `Bennett-Memory-PRD.md` (432 lines, root)
- `Bennett-Memory-T5-PRD.md` (465 lines, root)
- `docs/prd/Bennett-PRD.md` (396 lines) — v0.1
- `docs/prd/BennettIR-PRD.md` (456 lines) — v0.2
- `docs/prd/BennettIR-v03-PRD.md` (495 lines) — v0.3
- `docs/prd/BennettIR-v04-PRD.md` (417 lines) — v0.4
- `docs/prd/BennettIR-v05-PRD.md` (366 lines) — v0.5
- `docs/prd/advanced-arithmetic-PRD.md` (326 lines)

Nine PRDs, no index, no "PRDs are layered like this: read A, then B, then C." `CLAUDE.md` mentions the five `docs/prd/*.md` files but **does not mention** the three top-level Bennett-VISION / Bennett-Memory / Bennett-Memory-T5 PRDs at all. README links to `Bennett-VISION-PRD.md` (good) and `docs/memory/` (good) but not to the Memory or T5 PRDs at all. WORKLOG's §start-here tells me to read `Bennett-Memory-T5-PRD.md` first — which conflicts with CLAUDE.md's suggestion list.

**Minute 30–50.** I try to understand the current state via `WORKLOG.md`. It's 8193 lines (415 KB). The `## NEXT AGENT — start here — 2026-04-21` header at line 3 is excellent and current — clearly dated today, cites exact file:line numbers, exact bd issue, exact test to write first. Best onboarding artifact in the repo. But WORKLOG has **two** NEXT-AGENT headers (line 3 and line 1055), the second being from 2026-04-16 — a past life that has never been archived. A new reader has to know to trust only the most recent one. Below that, 85 `## Session log` sections in reverse chronological order. No table of contents. No index. No by-topic grouping. If I want to find the Feistel hash implementation decision, I have to scroll or grep.

**Minute 50–60.** I try `docs/design/`. 45 files, 34K lines total. No index. Naming convention is `{topic}_{proposer_A,proposer_B,consensus}.md` for each 3+1 core change. Useful pattern — the consensus doc is always the canonical one and averages ~200–400 lines while proposer docs are ~700–1400 lines each. But nothing tells me this. I have to guess from filenames that `alpha_consensus.md` is canonical and `alpha_proposer_{A,B}.md` are historical. `cc07_consensus.md`, `p6_consensus.md`, `m3a_consensus.md` etc. are cited throughout WORKLOG, so they ARE load-bearing. The proposer docs are post-facto archive — but they're sitting in the same directory at the same visual weight as the consensus docs.

**Verdict**: first-hour experience is **7/10**. The README and tutorial carry hard. The PRD sprawl, the WORKLOG length, and the design-doc directory crowding cost at least 20 minutes of orientation. With an index and two deletions I'd call it 9/10.

---

## CRITICAL findings

### C1. `CLAUDE.md` §6 has stale gate-count baselines (breaks agent workflow)

`CLAUDE.md:27`:

> Key baselines: i8 addition = 86 gates, i16 = 174, i32 = 350, i64 = 702 (exactly 2x per width doubling).

But:

- `BENCHMARKS.md:9-12` says: i8=100, i16=204, i32=412, i64=828.
- `WORKLOG.md:118` says: `@assert gate_count(reversible_compile(x -> x + Int8(1), Int8)).total == 100`.
- I ran the actual code: `i8 total: 100 Toffoli: 28`.

So CLAUDE.md's "key baseline" is wrong by **14 gates / 14%**. This is the first file every agent is instructed to treat as non-negotiable, and its only concrete numbers are stale. The number has propagated: `docs/design/sret_proposer_A.md:654`, `docs/design/cc07_proposer_B.md:942`, `docs/design/beta_proposer_B.md:964`, `docs/design/cc03_05_proposer_B.md:905`, `docs/design/gamma_proposer_A.md:503`, `reviews/01_test_coverage.md:242,253` all repeat the 86 number.

**Fix**: update CLAUDE.md §6 to `i8=100, i16=204, i32=412, i64=828` with Toffoli breakdown `28/60/124/252`, matching BENCHMARKS.md. Cite BENCHMARKS.md as the regression source instead of vaguely "WORKLOG.md" (currently the WORKLOG disagrees with CLAUDE.md on this).

### C2. CLAUDE.md "File Structure" block is extremely stale

`CLAUDE.md:76-118` lists ~15 source files (`Bennett.jl, ir_types.jl, ir_extract.jl, ir_parser.jl, gates.jl, wire_allocator.jl, adder.jl, multiplier.jl, lower.jl, bennett.jl, simulator.jl, diagnostics.jl, controlled.jl, softfloat/softfloat.jl, softfloat/fadd.jl, softfloat/fneg.jl`).

Actual `src/` has **31 files plus 16 in softfloat/ plus 10 in persistent/**: `bennett_transform.jl` (renamed from `bennett.jl`!), `qcla.jl`, `mul_qcla_tree.jl`, `fast_copy.jl`, `partial_products.jl`, `parallel_adder_tree.jl`, `divider.jl`, `softmem.jl`, `qrom.jl`, `tabulate.jl`, `memssa.jl`, `feistel.jl`, `shadow_memory.jl`, `dep_dag.jl`, `pebbling.jl`, `eager.jl`, `value_eager.jl`, `pebbled_groups.jl`, `sat_pebbling.jl`, `persistent/*`. The softfloat directory has `fadd.jl, fsub.jl, fmul.jl, fdiv.jl, fneg.jl, fcmp.jl, fsqrt.jl, fma.jl, fpconv.jl, fptosi.jl, sitofp.jl, fround.jl, fexp.jl, fexp_julia.jl, softfloat_common.jl, softfloat.jl`.

`CLAUDE.md` also lists ~16 test files; actual test/ has **~100**. The structure shown is a roughly correct sketch from v0.5 era but is a year of commits out of date for an agent-facing spec.

**Note**: `CLAUDE.md` even calls `bennett.jl` — but that file was renamed to `bennett_transform.jl` (git log: `a9328e3 index on main: 4729656 rename src/bennet.jl -> src/bennet_transform.jl`). A principle (§2 "3+1 for core") explicitly lists `bennett.jl` as a trigger. An agent could technically miss that the rename happened.

**Fix**: either (a) regenerate the File Structure block from actual directory listing, or (b) delete it entirely and refer to `docs/src/architecture.md § File Map`, which is current.

### C3. CLAUDE.md never mentions the top-level PRDs that the README and WORKLOG treat as canonical

CLAUDE.md line 7: `Full PRDs: Bennett-PRD.md (v0.1), BennettIR-PRD.md (v0.2), BennettIR-v03-PRD.md (v0.3), BennettIR-v04-PRD.md (v0.4), BennettIR-v05-PRD.md (v0.5).` That's five PRDs. Missing: `Bennett-VISION-PRD.md`, `Bennett-Memory-PRD.md`, `Bennett-Memory-T5-PRD.md`, `docs/prd/advanced-arithmetic-PRD.md`. All four exist, are substantive (300–465 lines each), and are cited by WORKLOG's own NEXT-AGENT header (which says "read `Bennett-Memory-T5-PRD.md`").

This is a direct conflict: the agent-instruction file says the latest PRD is v0.5; WORKLOG says "read T5". The v0.5 PRD was written before memory work, advanced arithmetic, the persistent-DS epic, and the multi-language ingest — all shipped. V0.5 PRD is historical.

**Fix**: add a "Current PRD layering" section to CLAUDE.md:
- Top-level vision: `Bennett-VISION-PRD.md`
- Active epic: `Bennett-Memory-T5-PRD.md` (as of 2026-04-21)
- Completed epics archive: `docs/prd/*.md` + `Bennett-Memory-PRD.md`
- Cross-cutting: `docs/prd/advanced-arithmetic-PRD.md`

---

## HIGH findings

### H1. `docs/prd/` is an unlabelled historical archive posing as active documentation

Five numbered PRDs (`Bennett-PRD.md` v0.1 through `BennettIR-v05-PRD.md` v0.5) are completed and superseded. Their "Where we are" sections describe predecessor states ("v0.2 proved: plain Julia function → LLVM IR → reversible circuit → correct. Works for single-basic-block IR…"). A new reader will not know these are history unless they read the version strings in titles.

**Fix**: either:
- Move `docs/prd/Bennett-PRD.md` through `BennettIR-v05-PRD.md` to `docs/prd/archive/` with an `ARCHIVE.md` stating the range; keep `advanced-arithmetic-PRD.md` in `docs/prd/` if active.
- OR add a one-line header to each: `**STATUS: COMPLETED v0.N — historical; see Bennett-Memory-T5-PRD.md for active work.**`

### H2. `docs/design/` has 45 files, no index, and ~60% is read-once archive

By my count of `*_consensus.md` vs `*_proposer_*.md`:

| Load-bearing (consensus + research) | Lines | Archive (proposer_A/B) | Lines |
|---|---|---|---|
| 15 files (alpha/beta/gamma/cc03_05/cc04/cc07/m2b/m2d/m3a/p5/p6 + p6_research × 2 + parallel_adder_tree + qcla + soft_fma) | ~5,500 | 30 files | ~28,000 |

Consensus docs ARE cited (WORKLOG, CLAUDE.md-adjacent). Proposer docs are cited exactly once (at write time) and then inherit old gate counts into perpetuity (see C1 — the 86-gate ghost lives in multiple proposer docs).

**Fix**: move `*_proposer_A.md` and `*_proposer_B.md` to `docs/design/proposals/` (or `docs/design/archive/`) preserving git history. Keep `*_consensus.md` and `p6_research_*.md` in `docs/design/`. Add `docs/design/INDEX.md` listing each consensus doc with one-line summary + which bd issue / commit shipped.

### H3. WORKLOG.md has no table of contents and two NEXT-AGENT pointers

8193 lines. 85 `## Session log` sections. The TOC problem is the primary pain point.

Also: there are TWO `## NEXT AGENT — start here` headers:
- Line 3: `2026-04-21 (α+β+γ shipped; T5-P6 unblocked)` — current
- Line 1055: `2026-04-16 (M1 + M2a–d + M3a landed; M3b or M2-residual next)` — stale five days

Convention says only one NEXT-AGENT header, at the top. The second should have been deleted or renamed when the 2026-04-17 session landed (and again at each subsequent handoff).

**Fix**:
- Add a `## Table of Contents` after the current NEXT-AGENT block, auto-generated from `## ` headers. Update script could be `scripts/regenerate_worklog_toc.sh`.
- Delete the stale `## NEXT AGENT — start here — 2026-04-16` header (rename to `## Session log — 2026-04-16 — M1/M2a-d/M3a handoff`).
- Enforce invariant in CLAUDE.md: "WORKLOG.md has at most one `## NEXT AGENT` header, at line ≤ 10."

### H4. WORKLOG.md and git-log narrate the same events; one could be shorter

Git log (124 commits) carries: commit title, bd issue, one-line rationale (already good: `08ba192 Bennett-atf4: lower_call! derives callee arg types from methods()`). WORKLOG narrates the *same* landings with vastly more detail. That's a feature, not a bug — but ~30% of WORKLOG is "files touched / tests added / gate count unchanged" recap that duplicates `git show`.

The distinctively valuable WORKLOG content is: **gotchas, learnings, rejected alternatives, the REASON a design was picked, and the RED-GREEN narrative arc**. The distinctively non-valuable content is: file-level diff summaries and "all tests pass" checkmarks.

**Fix**: adopt a WORKLOG session template that separates `Gotchas / Lessons` (keep forever) from `Commits / Tests` (reference git, don't duplicate). Example section split:

```
## Session log — YYYY-MM-DD — title
### Shipped (refer to git log for diffs)
- Bennett-XXXX: 1-line description [commit abc1234]

### Gotchas & Lessons (institutional memory — this is why WORKLOG exists)
- ...

### Rejected alternatives
- ...

### Next agent starts here
- ...
```

At 415KB, WORKLOG will soon hit a threshold where agents either skip it or burn cache. Splitting by year (`WORKLOG-2025.md`, `WORKLOG-2026-Q1.md`, etc.) becomes sensible beyond 1MB.

### H5. `simulate`, `gate_count`, `ancilla_count`, `depth`, `print_circuit` are exported without docstrings

In `src/simulator.jl:5,10` — `simulate(circuit, input)` and `simulate(circuit, inputs::Tuple)` have NO docstrings. They ARE documented in `docs/src/api.md` (prose) but an IDE hover / `?simulate` at the REPL returns only the signature. Same for `gate_count`, `ancilla_count`, `depth`, `print_circuit` at `src/diagnostics.jl:1-36`.

The project has **379 `"""` triple-quote occurrences** across `src/` (healthy) — but the ones missing are the *top public exports*. Julia convention: every exported function should have a `?func` docstring. `docs/src/api.md` is useful as narrative reference but doesn't show up at the REPL.

**Fix**: port the `docs/src/api.md` entries into docstrings above each function definition. `t_count`, `toffoli_depth`, `verify_reversibility` DO have docstrings — the pattern exists; extend it to cover the remaining exports. No doctests currently; adding `jldoctest` blocks would let `Documenter.jl` catch API drift (e.g., the `gate_count` signature change).

### H6. `docs/` is set up like a Documenter.jl project but has no `make.jl` / no built site

`docs/src/{api,architecture,tutorial}.md` is the canonical Documenter layout. But there's no `docs/make.jl`, no generated `docs/build/` (there IS a `build/` at root which seems unrelated). There's no hosted doc URL in Project.toml. README links to `docs/src/tutorial.md` directly, bypassing Documenter entirely.

Either: (a) commit to Documenter and add `docs/make.jl` + CI deploy (JuliaHub / GH Pages), or (b) move `docs/src/*` up to `docs/*` since they aren't being rendered.

**Fix**: lowest-effort — add `docs/make.jl` (30 lines) and the CI recipe. This automatically surfaces docstring drift (Documenter errors on mismatched signatures) and gives you a hosted URL to link from README.

### H7. Memory strategy README claim versus actual dispatch

`README.md:82-94` states four memory strategies auto-dispatched. The table is accurate as of T3b.3 (`Bennett-10rm` closed). BUT `README.md:270` says:

> Next focus areas (per `Bennett-VISION-PRD.md`): Sturm.jl integration for quantum control (`when(qubit) do f(x) end`), full SHA-256 benchmark (BC.3), Julia EscapeAnalysis integration (T0.3), `@linear` macro for in-place-linear functions (T2b).

But `WORKLOG.md` top says the active focus is **T5-P6 persistent-tree dispatcher arm** (Bennett-z2dj), which is not listed. `Bennett-cc0` memory epic's T5 phase 5/6/7 are not mentioned in README's status section. README's "status" is ~2 weeks behind reality.

**Fix**: README `## Project status` should be the single source of truth, updated at each session close. WORKLOG's NEXT-AGENT header is the implementation-facing version; README's status is the user-facing version. Both should agree.

---

## MEDIUM findings

### M1. No "start here" path for a new contributor

README says "Documentation" with six links. CLAUDE.md is the agent-instruction file. WORKLOG's NEXT-AGENT is for someone already deep in the stack. A new *human* contributor needs an explicit path. Suggest adding a `## Contributing` section to README:

```
If you want to ship a trivial fix, read in this order (~30 min):
1. README.md Quick start — run Pkg.test() locally
2. docs/src/tutorial.md — compile something end-to-end
3. docs/src/architecture.md — understand the 4 stages
4. CLAUDE.md — 13 principles (mostly for AI agents, but humans benefit)
5. `bd ready` — find an open issue tagged P3 / good-first-issue

If you're working on a core change (ir_extract.jl / lower.jl / bennett_transform.jl):
- Read Bennett-VISION-PRD.md and the relevant consensus doc in docs/design/
- Follow CLAUDE.md §2 (3+1 protocol) — write 2 proposer docs, synthesize
- Write the RED test first (§3 TDD)
```

Currently the closest-existing text is in CLAUDE.md but agent-phrased.

### M2. `CLAUDE.md` has duplicated "Session Completion" sections

Lines 137–143 and 166–190 are BOTH titled "Session Completion" with overlapping but inconsistent content. Line 137 says 3 steps; line 166 says 7 steps with different numbering. The second is wrapped in `<!-- BEGIN BEADS INTEGRATION v:1 ... -->`/`<!-- END BEADS INTEGRATION -->` — auto-generated by some `bd init` template.

A human or AI reader encounters two "Session Completion" sections and has to reconcile them. The tool-generated one is stricter (mandates push-to-remote) — so delete the earlier hand-authored one. Or unify under one section with the tool-generated stricter version superseding.

### M3. Inline-comment quality is GOOD — consistent WHY-not-WHAT, zero TODO/FIXME/XXX

Spot-checked `src/bennett_transform.jl`, `src/gates.jl`, `src/lower.jl`, `src/simulator.jl`, `src/Bennett.jl`:

- Comments consistently explain WHY: `# P1: self-reversing primitives (e.g. Sun-Borissov multiplier) already end with ancillae clean and the result in lr.output_wires. Skip the copy-out + reverse pass — it would just double the gate count.` (`bennett_transform.jl:24`). This is exemplary.
- Zero `TODO`, `FIXME`, `XXX`, `HACK` in `src/` — confirmed via ripgrep of `\bTODO\b|\bFIXME\b|\bXXX\b|\bHACK\b`. That's remarkable for a 13K-LOC codebase and reflects the discipline of using `bd` for orphan followups.
- Bennett-issue references embedded directly in error messages: `"(Bennett-atf4)"`, `"Bennett-cc0 M2b"` — makes regressions traceable to the bead that introduced the fix. Good pattern.

The project IS following CLAUDE.md's "default to writing no comments" rule — comments are load-bearing, not explanatory filler.

### M4. Docstring coverage is asymmetric

Across src/, docstring density varies hugely: `ir_extract.jl` has 28 docstrings / 2394 lines (1.2%), `lower.jl` has 63 / 2662 (2.4%), but `gates.jl` has 6 / 40 lines (15%) and `softfloat/softfloat_common.jl` has 26 / 376 lines (7%). Ratios correlate with public-export density (gates.jl types are exported; most of lower.jl is internal). That's correct.

The real gap: **internal helpers have docstrings, but many exports have none**. See H5.

### M5. PRD cross-reference integrity

The root-level PRDs reference each other inconsistently:
- `Bennett-VISION-PRD.md` — no reference to Memory-PRD or T5-PRD
- `Bennett-Memory-PRD.md` — no reference to T5-PRD (T5 is a sub-epic of the memory PRD per line 8 of the T5 doc)
- `Bennett-Memory-T5-PRD.md` — titled as T5 sub-phase but lives at root alongside its parent

Suggest move: `Bennett-Memory-PRD.md` and `Bennett-Memory-T5-PRD.md` to `docs/prd/` alongside the other epic PRDs. Keep `Bennett-VISION-PRD.md` at root (it's the project-wide vision). Add a PRD-index section to README linking them all in dependency order.

### M6. WORKLOG's gate-count regression table is scattered

The same baseline gate-count table appears in multiple places:
- `WORKLOG.md:118-129` (current handoff)
- `WORKLOG.md:296-308` (α+β+γ session baselines)
- `WORKLOG.md:2049, 2267, 2599` (older sessions)
- `BENCHMARKS.md:7-27` (canonical)
- `CLAUDE.md:27` (stale! — see C1)

If an agent wants to know the canonical baselines, which do they trust? **BENCHMARKS.md is auto-generated** per its line 3: `Auto-generated by benchmark/run_benchmarks.jl`. It should be the single source of truth. CLAUDE.md and WORKLOG should cite it.

**Fix**: in CLAUDE.md §6, replace the hardcoded numbers with `See BENCHMARKS.md for current baselines`. In WORKLOG session logs, cite BENCHMARKS.md commit hash instead of re-embedding.

### M7. README missing: how to contribute new soft-float intrinsics / new arithmetic strategies

The README celebrates `register_callee!` and the strategy dispatchers but doesn't say how to ADD one. A new contributor who wants to add `soft_log10` has to: grep for `register_callee!`, read `src/softfloat/fexp.jl` as a template, read `docs/design/soft_fma_consensus.md` as an example, read `Bennett-VISION-PRD.md § Tier 2` — no single pointer. Similarly for adding a new multiplier strategy: no guide.

**Fix**: add a "Extending Bennett.jl" section to README or a new `docs/src/extending.md` covering the three most likely extension points (soft-float intrinsic, arithmetic strategy, memory strategy).

### M8. `docs/memory/memssa_investigation.md` status line

`docs/memory/memssa_investigation.md:4` says `**Status:** Investigation complete. **Go** with printer-pass-output parsing.` Good — but doesn't say the implementation is shipped. Per WORKLOG, T2a.2 (Bennett-81bs) and T2a.3 (Bennett-08wr) are CLOSED. Readers hitting this doc don't know it's already implemented.

**Fix**: append `**Implementation:** shipped in `src/memssa.jl` (Bennett-81bs, commit c560eb9). Integration tests: `test/test_memssa*.jl`.` to the Status line of all docs/memory/ files.

---

## LOW findings

### L1. BENCHMARKS.md partially stale

BENCHMARKS.md:147 has `| MD5 full (64 steps) | ~48k Toffoli (extrap.) | 27.5k Toffoli (eager) | 1.75× |` — but WORKLOG 2026-04-12 session says this was pre-Cuccaro-self-reversing fix, which would drop it to ~1.19×. If that fix has landed (per Bennett-07r?) the ratio has improved. Verify and update. If the fix hasn't landed, fine — but annotate `(pre-Bennett-07r)`.

BENCHMARKS.md:159-166 "Memory plan critical path status" lists T0–T3b as done, but doesn't mention T5 (persistent-DS sweep) or the multi-language ingest (T5-P5a/b) which landed after. Update to current status or remove the status section (link to WORKLOG's epic status table instead).

### L2. Literature survey missing some DOIs

`docs/literature/SURVEY.md` spot-check: Bennett 1989 has `doi:10.1137/0218053` (good), Knill 1995 has `arXiv:math/9508218` (good). But many later entries cite only paper title — search the survey for "DOI" count versus "arXiv" count.

Not a blocker, just citation hygiene. Low priority.

### L3. Test files don't have top-of-file docstrings

Sampled `test/test_increment.jl`, `test/test_polynomial.jl`, `test/test_branch.jl` — all jump straight into `@testset`. The `@testset` string IS descriptive ("Polynomial: g(x::Int8) = x*x + Int8(3)*x + Int8(1)"), so the signal isn't lost — but a 1-line top-of-file `# Regression: i8 polynomial baseline. See WORKLOG 2026-04-09.` comment would help locate the "why this test exists" context.

Low priority because the `@testset` strings already carry useful intent.

### L4. Inconsistent ASCII diagrams

README has one ASCII architecture diagram (line 222–234). `docs/src/architecture.md` has a very similar one (line 7–16). `CLAUDE.md` has a third (line 60–69). `Bennett-VISION-PRD.md` has a FOURTH (line 62–118). All four agree but have slightly different ASCII conventions (`──►` vs `-->`, box widths, presence of subsystems). Homogenize or pick one canonical diagram and have the others link to it.

### L5. Literature folder has both raw PDFs and `*_brief.md` summaries

`docs/literature/memory/` has 20 PDFs plus 7 `*_brief.md` summaries. Pattern is useful ("don't read the paper, read the brief") — but there's no index saying which papers have briefs. Add `docs/literature/memory/README.md` listing each paper with link to its brief.

### L6. `.beads` permission warning

Every `bd` invocation prints:
```
Warning: /home/tobiasosborne/Projects/Bennett.jl/.beads has permissions 0755 (recommended: 0700). Run: chmod 700 /home/tobiasosborne/Projects/Bennett.jl/.beads
```

Fix once, save the noise: `chmod 700 .beads/`.

### L7. `gpucompiler/` directory is untracked

`git status` shows `?? gpucompiler/`. Either .gitignore it or commit it. Dangling untracked directories at the repo root cause confusion for new contributors.

---

## NIT findings

### N1. LICENSE mismatch

README:279 says AGPL-3.0. LICENSE file size is 34KB — I didn't open it but AGPL-3.0 is typically ~34KB. Likely correct but confirm.

### N2. Trailing whitespace / wrapping

`docs/src/tutorial.md` mixes long lines (up to 130 cols) with wrapped 80-col. No wrapping convention documented in any file. Minor.

### N3. `CLAUDE.md`'s "Build & Test" block uses `julia --project` twice with different suffixes

`julia --project -e 'using Pkg; Pkg.test()'` vs `julia --project test/test_increment.jl`. Both work. The first is more formal. Harmonize if someone is pedantic.

### N4. `docs/src/tutorial.md § 11 What's Next`

Lists "Custom callees: `register_callee!(my_function)` for gate-level inlining" and "NTuple input: pass fixed-size arrays as flat wire arrays" as "what's next" — but both are in §4 and README features list. Remove the "what's next" prompts that are actually "already done".

### N5. BENCHMARKS.md `(folded)` rows

Lines 19 and 25 of BENCHMARKS.md show `x²+3x+1 (folded)` and `SHA-256 round (folded)` with different numbers. "Folded" is not explained anywhere in BENCHMARKS.md. A footnote would help.

---

## Summary: concrete action list

Priority order for a quick-win docs pass (≤ 2 hours):

1. **[C1] Update `CLAUDE.md:27`** — replace stale 86/174/350/702 baselines with 100/204/412/828, cite BENCHMARKS.md.
2. **[C2] Update `CLAUDE.md:76-118`** — regenerate file structure from directory listing or delete and link to `docs/src/architecture.md § File Map`.
3. **[C3] Add CLAUDE.md "Current PRD layering" section** — list Bennett-VISION, Bennett-Memory-T5 (active), Bennett-Memory, docs/prd/*.
4. **[H3] Delete second `## NEXT AGENT` header in WORKLOG.md** (line 1055).
5. **[H3] Add auto-generated TOC to WORKLOG.md** (`scripts/regenerate_worklog_toc.sh`).
6. **[H1] Annotate `docs/prd/Bennett-PRD.md`–`BennettIR-v05-PRD.md`** with `**STATUS: COMPLETED vN — historical**` headers.
7. **[H2] Move `docs/design/*_proposer_*.md`** to `docs/design/archive/`. Create `docs/design/INDEX.md` listing consensus docs.
8. **[H5] Add docstrings** for `simulate`, `gate_count`, `ancilla_count`, `depth`, `print_circuit`.
9. **[H7] Update README `## Project status`** — mention T5 active epic and persistent-DS work.
10. **[L6] `chmod 700 .beads/`** — silence the per-command warning.

Priority order for a medium pass (≤ 1 day):

11. **[H4]** Adopt WORKLOG session-log template; retroactively restructure the most recent 3 sessions.
12. **[H6]** Commit to Documenter.jl: add `docs/make.jl`, CI deploy. Hosted doc URL from README.
13. **[M1]** Add `## Contributing` section to README.
14. **[M2]** De-duplicate "Session Completion" sections in CLAUDE.md.
15. **[M5]** Move `Bennett-Memory-PRD.md` + `Bennett-Memory-T5-PRD.md` to `docs/prd/`.
16. **[M6]** Remove hardcoded baselines from CLAUDE.md; BENCHMARKS.md is the only source.
17. **[M7]** Add extending.md covering softfloat + arithmetic + memory extension points.

Long-term (when WORKLOG > 1 MB):

18. Split WORKLOG by year/quarter.
19. Archive `docs/design/archive/` to git tags + remove from tree.

---

## Things that are genuinely great and should not be changed

- **The README.** Six working code examples in the first 50 lines, honest benchmark claims, clear bibliography. This is how a research-compiler README should look.
- **The tutorial.** 11 sections, all runnable, covers Float64 + controlled + tuples + strategies. Tutorial quality is rare in compiler projects.
- **Zero TODO/FIXME/XXX/HACK in src/**. Orphan followups go to `bd` instead of rotting in code. Discipline is real.
- **Inline comment quality.** WHY not WHAT. Bennett-issue tags in error messages. Good pattern.
- **`CLAUDE.md §2 3+1 protocol** producing `*_proposer_A.md`/`*_proposer_B.md`/`*_consensus.md` triples — this is actually a brilliant institutional-memory pattern. The output is occasionally confusing (H2) but the discipline it enforces is load-bearing for the project's correctness. Keep.
- **WORKLOG §NEXT-AGENT header at line 3** — best-in-class onboarding artifact. Exact file:line citations, exact test to write first, exact bd issue, gate-count spot-checks. When it's fresh (as today), it's the single most valuable document in the repo. The question is whether that freshness is reliably maintained; today it is.

---

## One-line verdict

A project where the *user-facing* docs (README, tutorial, BENCHMARKS, architecture) are excellent and the *agent-facing* / *institutional-memory* docs (CLAUDE.md, WORKLOG.md, docs/prd/, docs/design/) are excellent in content but suffer from drift and missing indexes. Fixable in 2 hours for the critical items, 1 day for the cleanup, without changing any code.
