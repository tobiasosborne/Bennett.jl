# Bennett.jl — Vision, Scope, and Mission-Drift Review

**Reviewer:** Independent product-engineering auditor
**Scope:** Vision coherence, PRD-vs-reality drift, scope bloat, ossification, dead commitments, research/product tension, roadmap clarity
**Date:** 2026-04-21
**Verdict:** Project is technically very strong, but is suffering from a late-stage case of **"one more primitive before I write the headline"** disease. The original thesis ("plain Julia in, reversible circuit out, then quantum control in Sturm") has been **quietly replaced** by "benchmark arena for reversible compilation primitives." This is not obviously wrong — it may even be the right new thesis — but nobody has written that down, and the README, PRDs, WORKLOG, bd backlog and source tree are now pulling in partially different directions.

---

## Executive summary — the brutal one

- **The north-star feature is not built and has been P3-demoted.** `when(qubit) do f(x) end` / Sturm.jl integration (VISION-PRD §8 success criterion #6; v0.9 line in the version-history table) is tracked as `Bennett-0s0 ● P3 v0.9: Sturm.jl integration`. There is zero code in `src/` that names Sturm. `Grep Sturm src/` returns no hits. The motivating use case has not been exercised.
- **A newer north star has been smuggled in.** The README now headlines Bennett.jl as "the first reversible compiler with full LLVM `store`/`alloca` support" and "benchmarking arena for reversible arithmetic" (`advanced-arithmetic-PRD.md` §1). Memory-PRD §1 goes further: "publishable first-in-literature result ... beats ReVerC 2017 on MD5 (27.5k Toff)." That is an **academic-paper** thesis, not the Sturm.jl quantum-control thesis. Nothing in VISION-PRD §1 says "first reversible compiler." This pivot was never documented.
- **Memory-PRD headline (MD5 ≤27,520 Toff) was not delivered.** Memory-PRD §6.1 commits to "≤27,520 Toff via T4 shadow-checkpoint" as the primary PLDI/ICFP result. BENCHMARKS.md line 120 still shows "~48k Toffoli" (1.75× ReVerC). T4 is shipped (`:shadow_checkpoint` arm landed 2026-04-16), but the headline number was not achieved. Instead of the promised "match or beat ReVerC 27,520," the project pivoted to T5 (universal fallback) and the SHA-256 1,632 vs PRS15 683 gap (2.4×).
- **T5 PRD's central test corpus is RED.** `test/test_t5_corpus_julia.jl` TJ1 (`Vector{Int8}` + `push!`), TJ2 (`Dict{Int8,Int8}`), TJ4 (`Array{Int8}(undef, 256)` dynamic idx) are all still `@test_throws`. T5-Memory-PRD §6.1 explicitly lists these as "primary (correctness, non-negotiable)" success criteria. The PRD is 5 days old (2026-04-17); no unbounded-heap pattern actually reversibly-compiles today.
- **Five (5) persistent-map implementations ship for a feature that doesn't exist yet.** `src/persistent/` contains `linear_scan.jl`, `okasaki_rbt.jl`, `hamt.jl`, `popcount.jl`, `cf_semi_persistent.jl`, `hashcons_jenkins.jl`, `hashcons_feistel.jl`. The 2026-04-20 sweep concluded "linear_scan dominates at every N up to 1000." But the dispatcher arm that would actually pick one of them (`:persistent_tree`) has not yet landed — the 4 losing impls ship anyway, at 739 lines of tests and ~1,500 lines of source. This is **infrastructure for a feature that doesn't dispatch anywhere**.
- **12 days of elapsed wall-clock, ~26,000 lines of code, 111 test files, 415 KB WORKLOG.** First commit in the log is 2026-04-09; last is 2026-04-21. The project compressed what looks like six months of work into two weeks of agent time. The architectural signature of that acceleration is visible: features landed before their callers, infrastructure accreted without removal, and the six different PRDs do not fully agree on what the product is.
- **`src/` has files that no PRD asked for.** `qcla.jl`, `mul_qcla_tree.jl`, `parallel_adder_tree.jl`, `fast_copy.jl`, `partial_products.jl` come from `advanced-arithmetic-PRD.md` — which is the only PRD of the nine that was written **after** implementation started (kickoff 2026-04-14 per WORKLOG:3964). `sat_pebbling.jl` (197 LOC) is present; no PRD commits to it; `bd` has it tracked as `Bennett-fg2 ● P2 SAT solver: replace PicoSAT`. `tabulate.jl` (202 LOC) appeared via `Bennett-cfjx`, never scoped in any PRD.
- **The "research arena" framing collides with the "product stability" principle.** CLAUDE.md §6 says "gate counts are regression baselines" — but advanced arithmetic deliberately **introduces new strategies with different gate counts** as a feature. The `toffoli_depth` baselines for QCLA vs ripple are not in the same comparison class. Two principles now contradict.
- **The 3+1 agent protocol (CLAUDE.md §2) is expensive and is currently gating every change to `lower.jl` / `ir_extract.jl`.** The 2026-04-21 session burned ~12,000 lines of proposer/consensus docs across α, β, γ, δ (plus p6, cc04, m2b, m2d, sret, parallel_adder_tree, qcla, soft_fma). `docs/design/` is 1.6 MB of AI-generated design documents. This is a governance tax on a core that is simultaneously being pushed for "one more feature."
- **Vision-PRD claims v0.6, v0.7, v0.8 "Complete / Partial / Infrastructure (WIP)" — but v0.9 is Sturm.jl, which is P3/open, AND v0.8 pebbling is "infrastructure, optimization WIP" with nothing shipping end-to-end.** The version numbers have drifted from meaningful milestones to status labels attached to a sprawl of workstreams.
- **Exhaustive i8 testing (256 inputs) remains the default.** Fine for adders, soft_fadd, etc. But now that persistent maps, pebbling, SHA-256, MD5, soft_exp, soft_fma, and a QCLA multiplier all exist, the same sweep discipline does not scale — and indeed these tests use tiny i8 inputs for algorithms whose bugs live at wider widths.
- **The PRD for T5 says "correctness primary, gate cost secondary" but the most-cited finding (Phase-3 2026-04-17) was then **reversed** by Phase-3-redo (2026-04-20) based on gate-cost measurements the PRD said were secondary.** CF was briefly "vindicated" at K=3, then "reversed at scale" at K=N=1000. Linear_scan (a stub that P3a self-described as "simplest possible conforming impl") is now the dispatcher-recommended default over three implementations that took three sonnet subagents each.
- **README is the most honest document; the PRDs are the most out-of-date.** The README reports what the code actually does (38 opcodes, 4 memory strategies, 3 adder strategies, 3 mul strategies). VISION-PRD still lists v0.9 as "Sturm integration" and claims v1.0 targets Enzyme-level coverage. Memory-PRD still claims "MD5 ≤27,520" as primary. A new contributor reading VISION-PRD will have the wrong roadmap.
- **The `bd ready` queue has 51 issues with no active blockers, and the top 10 are a mix of P1 epic, P2 post-benchmark chores, P3 research speculation, P3 bug-report, and P3 tactical cleanup.** A new contributor cannot derive "what is next" from this.
- **No PRD for what is obviously the two biggest recent workstreams.** Persistent-DS sweep (3 impls + 2 hash-cons layers + scaling study) and advanced arithmetic both landed after-the-fact PRDs. T5 PRD is mid-flight (drafted 2026-04-17, but P5a/P5b and P6 landed in the same week). The PRD-driven-development principle (CLAUDE.md §11) is being honoured in spirit for the headline work — but the actual development cadence is "ship, then PRD."
- **The "10x Enzyme" framing ("Enzyme of reversible computation") is aspirational hype.** Enzyme has multiple universities of effort across 5+ years and covers C/C++/Rust/Fortran/Julia in production. Bennett.jl has 12 days of real work, no `.bc`/`.ll` examples shipped for C or Rust yet (T5-P5a/b closed 2026-04-21 but the test corpus C / Rust tests remain RED), and rides the LLVM.jl C API with specific LLVM-18-ish version pins (memssa_investigation.md).
- **gpucompiler/ appears in cwd, untracked in git.** It's a checkout of the upstream GPUCompiler.jl package. Unclear whether this is exploratory work, a dependency vendored in, or scratch space. Nothing in the docs mentions it.
- **The soft-float library is a product within a product.** 9 files in `src/softfloat/`, ~2,000 LOC, bit-exact IEEE 754 tested against hardware on 1.2M random pairs. Impressive, but (a) the VISION-PRD treats it as a tactic for Float64 coverage, not a product; (b) this alone is bigger than a typical graduate thesis; (c) it would justify its own repo.
- **Test culture is passing but not protecting the vision.** 1,299 `@test` invocations across 110 files. Vast coverage on soft-float, small coverage on end-to-end scenarios. There is **no integration test** that exercises the full motivation: "compile a classical function, wrap `controlled()`, feed to a quantum simulator, measure." The closest thing is `test_controlled.jl`, which verifies `controlled()` correctness in isolation.
- **Nothing is OUT of scope.** VISION-PRD §4 Tier 4 says "NOTHING IS OUT OF SCOPE. 100% coverage of every LLVM IR opcode." Then §9 lists three non-goals ("not a general-purpose quantum compiler, not a hardware synthesizer, not a replacement for hand-optimized circuits"). Read together, these are contradictory: a project with no out-of-scope opcodes IS growing toward "general purpose."

---

## 1. Vision coherence — where has the north star drifted?

**Stated vision (Bennett-VISION-PRD.md, dated at top of file):**
> "Bennett.jl makes the same argument for reversible computation [as Enzyme for AD]."
> "The long-term goal: quantum control in Sturm.jl via `when(qubit) do f(x) end`" (CLAUDE.md:5)

**Practical vision, as of 2026-04-21 (extrapolated from README + active PRDs + ready queue):**
> "Bennett.jl is the benchmarking arena for reversible compilation techniques. We publish head-to-heads vs ReVerC, PRS15, Meuli, Babbush-Gidney, Sun-Borissov."

These are reconcilable but **not identical**. An Enzyme-of-reversibility product would:
- ship `when(q) do f(x) end` as a headline feature (Bennett-0s0 P3, not shipped)
- be feature-driven by quantum algorithms that need reversible oracles (no such feature request in WORKLOG)
- have a tutorial titled "compile your classical function for Grover's oracle"
- be integrated with a quantum simulator for end-to-end demos

A benchmarking-arena product would:
- ship head-to-heads vs published compilers (README §Benchmark headlines: yes, MD5 row, SHA-256 row)
- ship multiple adder / multiplier / memory strategies user-selectable (yes, `add=:qcla`, `mul=:qcla_tree`)
- target PLDI / ICFP papers (yes, `Bennett-6siy` P.2 Paper outline, referenced in Memory-PRD §M4)
- emphasize reproducible gate counts (yes, BENCHMARKS.md)

**The code has been shaped by the second vision, not the first.** Controlled circuits exist but are treated as a one-off. No Sturm adapter exists. The motivating "quantum oracle" use case is invisible in `src/` and `test/`.

**Finding CRIT-1:** The project-stated vision ("Enzyme of reversibility, for quantum control in Sturm") and the practical vision ("benchmarking arena for reversible compilation") are both live, both pursued, and never reconciled. This is the single biggest source of scope confusion.

---

## 2. PRD-vs-reality drift, per version

### Bennett-PRD (v0.1)

- Scope: Traced{W} operator overloading, DAG, Bennett construction, integer arithmetic, Int8.
- Status: ✓ Archived (VISION-PRD §7 says so).
- Drift: NONE. v0.1 was correctly superseded by v0.2. Clean archive. Good.

### BennettIR-PRD (v0.2)

- Scope: LLVM IR extraction, parser, reversible circuit, Int8 only, no memory, no control flow.
- Status: ✓ Complete.
- Drift: The PRD's "pivot to Julia's `code_typed` SSA IR" contingency plan was never used — LLVM path worked. Clean.

### BennettIR-v03-PRD (v0.3)

- Scope: Controlled circuits + multi-block IR (br, phi).
- Status: ✓ Complete (per VISION-PRD §7).
- Drift: PRD explicitly names Sturm.jl integration (§2) as the motivation. Actual wire-up is not done. **Sturm was the **reason** for v0.3 and it never happened.**

### BennettIR-v04-PRD (v0.4)

- Scope: Wider integers (Int8→Int64), explicit loops (bounded unroll), NTuple/aggregates.
- Status: ✓ Complete.
- Drift: §7 committed a `loops.jl` file and `aggregates.jl` file. They were folded into `lower.jl` instead. Fine. Success criterion #4 ("Tuple element access compiles to zero gates") is now partially violated — insertvalue/extractvalue emit some CNOTs via the soft-mem path.

### BennettIR-v05-PRD (v0.5)

- Scope: Float64 via soft-float, path-predicate phi resolution.
- Status: ✓ Complete.
- Drift: The PRD §3 had three approaches (LLVM soft-float / pure-Julia / direct lowering). Approach B was chosen and shipped. ~2,000 LOC of soft-float library was not in the PRD's "~70K–130K gates for `x*x+3x+1`" estimate — actual is 872 gates (soft-path routing is only for literal Float64 types). §6.6 regression shows soft_fma at 447,728 gates — far beyond the "Large. Correct." §9 estimate of 200k–400k. Gate-count estimates missed by 2×.

### advanced-arithmetic-PRD (post-hoc)

- Scope: QCLA adder (Draper 2004), QCLA-tree multiplier (Sun-Borissov 2026), strategy dispatch framework.
- Status: ✓ Complete (`qcla.jl`, `mul_qcla_tree.jl`, `fast_copy.jl`, `partial_products.jl`, `parallel_adder_tree.jl` shipped).
- Drift: PRD was written **after** workstream kickoff (WORKLOG:3964 shows 2026-04-14 kickoff; PRD has no explicit date but references the 2026-04-14 workstream). This is the first **post-hoc PRD**. It violates CLAUDE.md §11 ("PRD-driven development — every version has a PRD written before implementation").

### Bennett-Memory-PRD (active)

- Scope: Three failure buckets (shape, dataflow, dynamic-size), T4 shadow-checkpoint, MD5 head-to-head ≤27,520 Toff, SHA-256 ≤80,000 Toff.
- Status: **Partial / Slipping.**
- Drift:
  - §6.1 primary criterion (MD5 ≤27,520) **NOT MET**. BENCHMARKS.md line 120 still reads ~48k Toff.
  - §6.2 primary criterion (SHA-256 ≤80,000) **NOT MET**. BENCHMARKS.md line 24 still reads 1,632 Toff per round → 64 rounds = 104,448; close, but the PRD's "~40% reduction via MemorySSA-driven def-use elimination" has not materialized.
  - §6.3 (Bucket A cleared): N ∈ {2,4,8,16,32}, W ∈ {8,16,32,64}. Shipped N·W ≤ 64 only. So N=8,W=16 and larger unsupported. PARTIAL.
  - §6.4 (Bucket C cleared): shipped via MemSSA wiring (M2a–d). GREEN.
  - §6.5 (Bucket B partial, T4 ≤ 2× lower bound): shipped. GREEN.
  - The PRD's M4 ("BennettBench paper draft") is `Bennett-6siy P3 open`. Not started.

### Bennett-Memory-T5-PRD (active, in-flight)

- Scope: Persistent-DS universal fallback for unbounded heap. Three impls behind common interface + two hash-cons compressors + dispatcher arm + multi-language ingest + Pareto front benchmark.
- Status: **Infrastructure present, integration not shipped.**
- Drift:
  - §6.1 primary criterion (every TJ1/TJ2/TJ3/TJ4/TC1/TC2/TC3/TR1/TR2/TR3 passes with `verify_reversibility`) **NOT MET**. TJ1, TJ2, TJ4 still `@test_throws`. TJ3 passes. C / Rust corpus files exist; test status unknown to this reviewer but WORKLOG suggests C extract-green, lower-red.
  - §6.2 primary criterion (multi-language ingest works): T5-P5a/b closed 2026-04-21. GREEN on extract; lower on non-Julia IR not verified at scale.
  - §6.4 (Pareto front published, 144 cells): NOT DONE. 8 cells in `benchmark/sweep_persistent_results.jsonl`; 15% of the promised sweep.
  - §6.5 (default winner identified): DONE, but the winner is linear_scan — which was the reference-stub self-test impl, not a serious candidate. That outcome **obsoletes** §5.1's commitment to "three persistent-DS implementations behind a common interface." The PRD should be amended.

---

## 3. Scope bloat — features no PRD asked for

| File | Size | Origin | PRD that scoped it |
|---|---|---|---|
| `qcla.jl` | 130 LOC | advanced-arithmetic-PRD.md | post-hoc |
| `mul_qcla_tree.jl` | 77 LOC | advanced-arithmetic-PRD.md | post-hoc |
| `parallel_adder_tree.jl` | 141 LOC | advanced-arithmetic-PRD.md | post-hoc |
| `partial_products.jl` | 59 LOC | advanced-arithmetic-PRD.md | post-hoc |
| `fast_copy.jl` | 39 LOC | advanced-arithmetic-PRD.md | post-hoc |
| `feistel.jl` | 124 LOC | Memory-PRD §3 T3a | ✓ scoped |
| `qrom.jl` | 177 LOC | Memory-PRD §3 T1b | ✓ scoped |
| `tabulate.jl` | 202 LOC | Bennett-cfjx | NONE |
| `sat_pebbling.jl` | 197 LOC | VISION-PRD §5 Pillar 2 | vague |
| `pebbled_groups.jl` | 452 LOC | VISION-PRD §5 | vague |
| `pebbling.jl` | 209 LOC | VISION-PRD §5 | vague |
| `eager.jl` | 119 LOC | VISION-PRD §5 | vague |
| `value_eager.jl` | 137 LOC | VISION-PRD §5 | vague |
| `memssa.jl` | 164 LOC | Memory-PRD §3 T2 | ✓ scoped |
| `shadow_memory.jl` | 115 LOC | Memory-PRD §3 T3b | ✓ scoped |
| `softmem.jl` | 305 LOC | Memory-PRD §3 T1a | ✓ scoped |
| `src/persistent/*` (9 files) | 1,648 LOC | T5-PRD | ✓ scoped, but 4 of 5 impls now dominated |

**Finding HIGH-1:** Five source files (advanced-arithmetic primitives) and one (`tabulate.jl`) landed before their PRD. Combined: 548 LOC + 202 LOC = ~750 LOC of scope creep without PRD gating. Small in absolute terms; large as a **principle** breach.

**Finding HIGH-2:** Four of the five persistent-map implementations (`okasaki_rbt.jl`, `hamt.jl`, `popcount.jl`, `cf_semi_persistent.jl`, plus `hashcons_jenkins.jl` and `hashcons_feistel.jl`) are **shipped dead code** pending a dispatcher that doesn't exist yet. After the 2026-04-20 sweep concluded linear_scan dominates at every N up to 1000, the honest action would have been to delete or demote these. Instead, they remain exported and tested as first-class API. Four additional implementations = optionality for a feature no user has requested.

**Finding HIGH-3:** `sat_pebbling.jl` requires a SAT solver (`bd` ticket Bennett-fg2 P2 "replace PicoSAT"). The `Project.toml` dep was added for this. Nothing in the documented "production" API path invokes it. It's a research tile on top of a compiler.

---

## 4. Ossification — where has the code calcified?

The user's cue: "we have reached a point of ossification." I find three sites.

### OSS-1: `LoweringCtx` has six overloaded constructors

`src/lower.jl:50–120` defines `LoweringCtx` with 14 fields, then defines four backward-compatible constructors (11-arg, 12-arg, 13-arg, 14-arg) to accommodate callers written at earlier scope levels. Each Memory-PRD milestone (M1, M2a–d, M3a) added a field; each one kept the prior constructors working. This is the textbook definition of ossification via ABI preservation.

A clean refactor would replace the whole thing with a keyword-constructor: `LoweringCtx(; gates, wa, ..., mem=:auto, persistent_impl=:linear_scan)`. Instead the 3+1 protocol (CLAUDE.md §2) has made that refactor too expensive — it touches `lower.jl` and therefore needs proposer + implementer + reviewer + consensus docs.

### OSS-2: `_pick_alloca_strategy` is a case-by-case explosion

`src/lower.jl:2084–2107`:

```julia
if idx.kind == :const return :shadow
(elem_w, n) = shape
if elem_w == 8
    n == 2 && return :mux_exch_2x8
    n == 4 && return :mux_exch_4x8
    n == 8 && return :mux_exch_8x8
elseif elem_w == 16 ...
elseif elem_w == 32 ...
```

Each (elem_w, n) pair below the ≤64-bit bound is enumerated by hand. Adding e.g. (4, 16) requires: (a) author `soft_mux_store_4x16` + `soft_mux_load_4x16` in `softmem.jl`, (b) `register_callee!` in `Bennett.jl`, (c) extend the case match. Memory-PRD §10 M1 was this work for nine variants. This pattern invites unbounded expansion.

A clean design: parametric MUX EXCH emitter `soft_mux_store(W, N)` that dispatches at compile time. That's a core change, so it's under 3+1, so it doesn't happen.

### OSS-3: `register_callee!` list in `src/Bennett.jl` is 40+ entries and growing

`Bennett.jl:163–208` is a registry of soft-float and soft-mem callees. Every new strategy adds one. Some are "M1 bucket A", some are "M2d bucket C3", some are T5-P4. The registry works, but it's untyped, not grouped, and carries no purpose annotation — you cannot skim it to understand why each entry exists. This is cruft ossifying as API.

---

## 5. Dead PRD commitments — quietly dropped

| PRD | Commitment | Status | Notes |
|---|---|---|---|
| VISION §8.6 | "Sturm.jl integration works end-to-end" | NOT STARTED | Bennett-0s0 P3 open |
| VISION §7 v0.9 | Sturm.jl integration as a release | NOT STARTED | line item in version history |
| VISION §3 | "Pebbling strategy: [future] SAT, [future] EAGER" | Mixed | SAT exists but not wired; EAGER exists (`eager.jl`, `value_eager.jl`, two implementations) |
| Memory-PRD §6.1 | MD5 ≤27,520 Toff | NOT MET | 48k shipped |
| Memory-PRD §6.2 | SHA-256 ≤80,000 Toff | NOT MET | 104k extrapolated |
| Memory-PRD §10 M4 | "BennettBench head-to-head paper" | NOT STARTED | Bennett-6siy P3 open |
| T5-PRD §6.4 | "Pareto front 144 cells in BENCHMARKS.md" | PARTIAL | 8 cells |
| T5-PRD §6.1 | "Every TJ1/TJ2/TJ3/TJ4 passes verify_reversibility" | PARTIAL | TJ1/TJ2/TJ4 RED |
| T5-PRD §7 TR2 | "Rust HashMap insert + get" | NOT MET | RED |
| Advanced-arith §1 | "benchmark/bc6_mul_strategies.jl head-to-head table" | DONE | `benchmark/bc6_mul_strategies.jl` exists |
| v0.4 §8.4 | "Tuple element access compiles to zero gates" | DRIFT | aggregates shipped, exact gate claim not verified |
| v0.5 §10.1 | "soft_fadd bit-exact vs Julia + for 100k random pairs" | DONE (×12) | 1.2M actual, per README |
| Memory-PRD §5 out-of-scope | "T5 Persistent hash-consed array deferred" | RESCOPED | T5-PRD written 1 day after Memory-PRD §5 deferred it. |

**Finding HIGH-4:** Memory-PRD's MD5 headline was the stated first-in-literature result. It was not delivered. The project pivoted to T5 (bigger scope) rather than closing that commitment. No PRD amendment records the pivot; no "headline revised" entry in WORKLOG.

---

## 6. Too many abstractions for "one thing"

The persistent-map shelf is the worst offender.

| Impl | LOC | Status per 2026-04-20 sweep |
|---|---|---|
| `linear_scan.jl` | 110 | **DOMINATES up to N=1000** |
| `okasaki_rbt.jl` | 397 | dominated (depth-2-only; max_n=4; 108k gates) |
| `hamt.jl` + `popcount.jl` | 309 + 72 | dominated (96k gates; popcount alone 2.8k) |
| `cf_semi_persistent.jl` | 385 | **reversed** from "vindicated at K=3" to "O(N²) at K=N" |
| `hashcons_jenkins.jl` | 100 | extra hash layer atop the above |
| `hashcons_feistel.jl` | 77 | extra hash layer atop the above |
| `interface.jl` + `harness.jl` + `persistent.jl` | 80 + 109 + 17 | plumbing |

Total: 1,648 LOC for a feature whose dispatcher isn't wired. 739 LOC of tests exercising all variants independently.

**Finding HIGH-5:** This is research-grade optionality (great for a paper, "we measured 5 implementations") dressed as product-grade infrastructure. The product posture would be: **ship linear_scan only, file the others as `docs/research/*.md` notes with a reproduction script.** Instead all five ship as first-class exports.

The argument against deleting: "they're needed for the Pareto-front benchmark." Then they belong under `benchmark/`, not `src/`. The test-file split (5 `test_persistent_*.jl` files) shows these are treated as product features, not bench fixtures.

---

## 7. Long-term vision coherence — premature architecture?

The `multi-language-llvm-vision` memory is explicit:

> "User stated 2026-04-15: 'must not happen today.' — vision informs design decisions but is explicitly deferred."

But T5-P5a (`extract_parsed_ir_from_ll`) and T5-P5b (`extract_parsed_ir_from_bc`) **were shipped 2026-04-21**. That's six days after "must not happen today." Six days.

T5-PRD §5.3 in-scope includes multi-language LLVM IR ingest as a T5 primary feature. T5-PRD §11 R3 "Multi-language IR variance" risk explicitly flags clang/rustc IR differences. The C corpus `test/fixtures/c/` and Rust corpus `test/fixtures/rust/` are committed. No C or Rust program has round-tripped end-to-end (WORKLOG:3342–3346 notes TC1/TC2/TC3 "GREEN on extract, RED on lower").

**Finding HIGH-6:** The "must not happen today" constraint was **violated within a week** of being stated. T5-P5a/b are now supporting infrastructure for a deferred vision. The ingest code exists; the end-to-end product doesn't. This is premature architecture dressed as a shipped feature.

The practical cost: `extract_parsed_ir_from_ll` and `extract_parsed_ir_from_bc` are now on the public surface (exported in `Bennett.jl:37`). Removing or changing them is a breaking change. The "defer" is locked-out.

---

## 8. Research vs product tension

Bennett.jl is simultaneously:
- a compiler that should ship stable gate counts (CLAUDE.md §6 baselines)
- a research laboratory for reversible-arithmetic techniques (QCLA, Sun-Borissov, SAT pebbling)
- an integration layer for a vision system (Sturm.jl quantum control)

These are not the same project. Symptoms:

- Regression baselines (CLAUDE.md §6: i8=100 total / 28 Toff) protect the legacy shift-and-add adder. Swapping it for QCLA would improve depth but break the regression baseline. Result: QCLA is a user-selectable strategy (`add=:qcla`), not the default. The adder dispatcher carries three strategies because the regression principle won't let the new one win.

- The advanced-arithmetic PRD is explicit that `bd ready` has `Bennett-6xdi ... Bennett-f81j` as the full DAG for 22 issues, but zero of these are in the current `bd ready -n 60` listing — meaning the 22-issue DAG was completed in one workstream burst (2026-04-14) before any validation-in-use. The workstream shipped all of Sun-Borissov before anyone tried to use it for a quantum oracle.

- The SAT pebbling (`sat_pebbling.jl`, 197 LOC) requires an external dependency (`PicoSAT`, now slated for replacement in Bennett-fg2). This is a paper-grade feature that every user has to pay for in build time and dep footprint.

- The soft-float library is 2,000 LOC of production-ready IEEE 754 and also the only way Bennett.jl handles floats. Both a research artifact (worth its own paper on "branchless IEEE 754 in Julia") and production infrastructure. The test file for soft_exp alone is 353 lines.

**Finding MEDIUM-1:** The project would benefit from a principled split. Something like:
- `Bennett.jl` — stable core: extractor + lower + bennett + simulate + Sturm adapter
- `BennettArith.jl` — optional dep: QCLA, Sun-Borissov, Karatsuba, advanced strategies
- `BennettMemory.jl` — optional dep: shadow, MUX EXCH, QROM, Feistel, persistent-maps
- `BennettBench.jl` — benchmark corpora, paper-reproduction scripts, survey data

Not a priority today, but without this split the "what does this project DO" question only gets harder.

---

## 9. Test coverage vision

Exhaustive i8 (256 inputs) is the norm. Good for arithmetic. Less good for:

- **End-to-end quantum oracle.** No test exercises `controlled(reversible_compile(f, T))` and checks something Sturm.jl-shaped. `test_controlled.jl` tests `controlled()` in isolation.
- **Cross-language.** `test_t5_corpus_c.jl` and `test_t5_corpus_rust.jl` exist but depend on clang/rustc being installed (T5-PRD §10 M5.2 "verify in CI" — no evidence this is actually in CI).
- **Wide-width overflow edge cases.** Most tests use i8. SHA-256 tests do use i32. But algorithms like soft_exp_julia (3.4M gates) have no systematic subnormal-output sweep — that's `Bennett-fnxg ● P2` open.
- **Integration with Sturm.** Impossible — no Sturm.jl integration exists.
- **Strategy dispatchers under real loads.** `test_add_dispatcher.jl`, `test_mul_dispatcher.jl`, `test_mul_qcla_tree_paper_match.jl` test correctness but not "does the right strategy fire for W=64 when depth matters."

**Finding MEDIUM-2:** The 256-input exhaustive sweep is load-bearing for correctness, and cheap for i8. But at this project scale, the **coverage vision** needs an update: representative workloads (oracle-for-Grover, phase-estimation unitary, hash round) should be first-class tests that exercise the whole pipeline end-to-end, not just unit correctness of individual primitives.

---

## 10. Roadmap clarity for a new contributor

What a newcomer sees:
- README: Sturm integration "next focus area"
- VISION-PRD §7: v0.9 = Sturm
- bd ready: Sturm = Bennett-0s0 P3
- NEXT AGENT WORKLOG header: T5-P6 dispatcher implementation
- CLAUDE.md "What This Is": "The long-term goal: quantum control in Sturm.jl"
- Memory-PRD: MD5 ≤27,520 Toff headline
- T5-PRD: unbounded heap via persistent map

These do not agree on the single "next step." A newcomer has to triangulate.

**Finding CRITICAL-2:** There is no single authoritative "where are we / what's next" document. WORKLOG.md "NEXT AGENT — start here" (§1) is the most-current source (dated 2026-04-21), but a newcomer has to **know** to read the worklog top-down, not the README or the PRDs. The PRDs are 4–12 days stale relative to the code.

Recommendation: a single `STATUS.md` with:
- Current headline goal (concrete, dated)
- The ONE in-flight PRD (link)
- The ONE in-flight bead (link)
- Explicit "archived / dead / deferred" list

Or: consolidate into VISION-PRD §7 version table with real dates and real blockers.

---

## 11. "One more feature before refactor" disease — DIAGNOSIS

**YES.** Clear symptoms:

- LoweringCtx's 14 fields and 4 backward-compat constructors are a refactor deferred behind four milestones.
- The `_pick_alloca_strategy` case-match is a refactor deferred behind "just one more (elem_w, n)".
- The `register_callee!` growing list is a refactor deferred behind "just one more callee."
- Four dominated persistent-map impls ship because "we'll pick the default in the dispatcher, and we haven't built the dispatcher yet."
- Memory-PRD's MD5 headline was never closed, and the pivot to T5 is "one more tier before the paper."
- The T5 PRD is "one more universal-fallback before T6" (persistent maps → multi-language → dispatcher → paper → ???).
- The 3+1 protocol is **actively protecting** this state: every refactor costs two proposer runs, so incremental expansion is cheaper than correction.

**The tell:** look at the NEXT-AGENT block (WORKLOG:3–130). 127 lines of "here's exactly what to do next and which lines to touch." That level of specificity is great for a newcomer — but it reveals that **the next action is pre-chewed down to 13 numbered sub-steps across specific line numbers**. That's not product development; that's a punch-list for a task whose architectural question is "just one more arm."

---

## 12. Architecture being contorted for a distant vision?

**Mostly NO, surprisingly.** The `extract_parsed_ir_from_ll` / `_from_bc` work (T5-P5a/b) is the one site where "Enzyme-of-reversibility multi-language" is shaping the code today even though it's deferred. The rest is honest: soft-float supports Julia Float64 today, MemorySSA supports Julia-IR aliasing today, QCLA supports quantum-depth-sensitive workloads today.

**Finding LOW-1:** The one "being built for tomorrow" smell is multi-language ingest. I'd recommend either:
- remove it from the public API until the C/Rust end-to-end tests pass (TC1, TR1), OR
- commit publicly to "multi-language is shipped, here's our clang/rustc corpus and versions we support" with the benchmarks to back it.

---

## 13. Prioritized findings

### CRITICAL

**CRIT-1** — *Vision drift*. Two coexisting visions (Sturm integration vs benchmark arena). Reconcile. Pick one as the primary north star. Demote the other to "also supports." Write a single VISION update.

**CRIT-2** — *Roadmap clarity*. A new contributor cannot answer "what ships next" without reading WORKLOG, bd, PRDs, and CLAUDE.md. Consolidate.

**CRIT-3** — *Memory-PRD headline failed silently*. MD5 ≤27,520 Toff was primary. Actual ~48k. No amendment, no retrospective. Decide: close (drop the target), fix (land the T4 optimizations that would get there), or pivot (document the pivot to T5 as the new headline).

### HIGH

**HIGH-1** — *Post-hoc PRDs*. `advanced-arithmetic-PRD.md` and `Bennett-Memory-T5-PRD.md` were written during/after implementation. This violates CLAUDE.md §11. Either rewrite the principle to allow "shipping-plus-PRD" (and explain why), or discipline the workflow.

**HIGH-2** — *Persistent-map shelf of dead optionality*. Four out of five impls are dominated. Delete, demote to `benchmark/`, or ship the dispatcher that selects between them. Current state (all exported, all tested, dispatcher not wired) is the worst of both worlds.

**HIGH-3** — *Sturm.jl integration is P3 but is the stated primary motivation*. Either promote to P1 and scope properly, or remove it from the vision. "v0.9" in VISION-PRD is a label pretending to be a plan.

**HIGH-4** — *Memory-PRD's MD5 headline is a dead commitment*. See CRIT-3.

**HIGH-5** — *T5-PRD primary tests still RED*. TJ1, TJ2, TJ4 have been `@test_throws` since 2026-04-17. PRD §6.1 calls these non-negotiable. Either close them or amend the PRD.

**HIGH-6** — *Multi-language ingest violates "must not happen today"*. T5-P5a/b shipped 2026-04-21, six days after the stated constraint. Either commit to multi-language as a shipped feature (with the public API and versioning that implies) or un-export those entry points until C/Rust end-to-end is green.

### MEDIUM

**MED-1** — *Research vs product split*. Proposal: separate `Bennett.jl` core from `BennettArith.jl` + `BennettMemory.jl` + `BennettBench.jl`. Not urgent, but the single-repo "everything in `src/`" posture is blocking clean versioning.

**MED-2** — *Coverage vision needs update*. Exhaustive i8 sweeps don't protect end-to-end quantum-oracle flow. Add at least one big integration test that exercises `controlled(reversible_compile(f, T))` + simulator round-trip.

**MED-3** — *LoweringCtx and `_pick_alloca_strategy` ossification*. Worth a scheduled refactor with its own 3+1 protocol. Defer as long as it keeps getting bigger and the cost compounds.

**MED-4** — *Non-goal list vs "nothing is out of scope"* (VISION-PRD §4 Tier 4 vs §9). Contradictory. Pick.

**MED-5** — *Gate-count regression baselines prevent default-strategy evolution*. QCLA could replace ripple as default at W ≥ 32 on every axis except baseline-preservation. Reconsider whether "baseline-identical gate counts" is still the right invariant once strategy dispatch is in.

### LOW

**LOW-1** — `gpucompiler/` directory untracked in git, uncommented anywhere. Clean it up or explain it.

**LOW-2** — The `docs/design/` corpus (1.6 MB, 44 files) is design auditing noise once the beads are closed. Move to an archive branch or prune.

**LOW-3** — Memory-PRD §12 external references list papers not all downloaded. T5-PRD §12 same. Close the gap or remove the claim.

**LOW-4** — `Bennett-ponm P3` ("bd dep tracking broken: wisp_dependencies table missing") is a tooling bug that has been open. It's low-impact but visible; fix or escalate.

### NIT

**NIT-1** — Inconsistent capitalization of "Bennett" vs "BennettIR" across PRDs (VISION says `Bennett.jl` throughout, v0.2–v0.5 PRDs say `BennettIR.jl`).

**NIT-2** — CLAUDE.md has TWO "Session Completion" sections (lines ~119 and ~170). The first is shorter; the second is longer and more prescriptive. They contradict mildly. Merge.

**NIT-3** — README §"Project status" (line 273) says "Memory plan critical path complete" but the Memory-PRD critical path (MD5 headline) is not complete. Claim mismatch.

**NIT-4** — `CLAUDE.md:10` "13 principles" — there are 14 numbered items (0 through 13). Off-by-one in the self-description.

---

## 14. Recommendations (brief)

1. **Write a one-page `STATUS.md`.** Rewrite weekly. Include: north star (concrete, dated), in-flight PRD, in-flight bead, last headline claim, last failed headline claim, explicit "dropped / deferred" list.

2. **Reconcile the two north stars.** Either promote Sturm integration to P1 and scope it, or amend VISION-PRD to center the "benchmark arena / publishable compiler" thesis and demote the Sturm angle to a use-case example.

3. **Stop accreting options.** Before adding a sixth persistent-map impl or a fourth multiplier strategy: close-or-delete at least one of the existing ones. "One-in, one-out" discipline.

4. **Amend Memory-PRD.** Document that MD5 ≤27,520 did not ship and T5 is the pivoted headline, OR re-attack the T4 gate-count numbers.

5. **Un-ship or finalize multi-language.** If it's shipped, the C/Rust corpus should be GREEN. If it's deferred, un-export `extract_parsed_ir_from_{ll,bc}`.

6. **Schedule LoweringCtx refactor.** A clean keyword-constructor pattern would eliminate the four shim constructors. Cost: one 3+1 cycle. Savings: easier to add future fields without churn.

7. **Delete dominated persistent-map impls OR move them to `benchmark/fixtures/`.** Keep the `bd remember` note + a WORKLOG entry for the Phase-3 reversal.

8. **Add one integration test** that compiles a Grover-style oracle function, wraps `controlled()`, and verifies output on a small statevector simulator (even if Sturm is mocked). This is the only way to protect the stated vision.

---

## 15. Closing note

Bennett.jl is, despite every criticism above, a genuinely impressive two-week sprint. The soft-float correctness work, the five-tier memory strategy, and the Sun-Borissov multiplier implementation are the kind of output that's normally a team-year.

The concern is not quality; it's **direction**. Without a reconciled north star, the project will keep accreting high-quality primitives — each justified by a local argument, each well-tested, each documented in a PRD written after it was built — and a year from now there will be 40 persistent-map impls, 15 adder strategies, and still no `when(qubit) do f(x) end`.

Pick the one headline. Ship it end-to-end. Delete what isn't needed for it. Promote the rest to research notes. Then pick the next one.

