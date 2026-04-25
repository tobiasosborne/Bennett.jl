# Bennett.jl — Reversible Circuit Compiler

## What This Is

A Julia compiler that takes plain Julia functions on plain integers (and Float64 via soft-float) and compiles them into classical reversible circuits (NOT, CNOT, Toffoli gates) via Bennett's 1973 construction. The long-term goal: quantum control in Sturm.jl via `when(qubit) do f(x) end`.

Full PRDs: `Bennett-PRD.md` (v0.1), `BennettIR-PRD.md` (v0.2), `BennettIR-v03-PRD.md` (v0.3), `BennettIR-v04-PRD.md` (v0.4), `BennettIR-v05-PRD.md` (v0.5).

**Backend: LLVM.jl from v0.2.** The compiler extracts LLVM IR from plain Julia functions via LLVM.jl's C API, walks the IR as typed objects, lowers each instruction to reversible gates, and applies Bennett's construction. No operator overloading, no special types — plain Julia in, reversible circuit out.

## Implementation Principles

These are NON-NEGOTIABLE. Every agent, every session, every commit.

0. **MAINTAIN THE WORKLOG.** Every step, every session: prepend a `## Session log — YYYY-MM-DD — ...` block to the **current top chunk** under `worklog/` (today: `worklog/038_*.md`; the highest-numbered file is always the most recent). When that file passes ~280 lines, start a new chunk with the next sequential `NNN_` prefix and prepend there. The root `WORKLOG.md` is now a thin **index** (sharded out of a 9,774-line monolith per Bennett-fyni / U70). Capture gotchas, learnings, surprising decisions, LLVM IR quirks, test failures and their root causes — anything a future agent would wish it knew, that's not derivable from the diff. This is the project's institutional memory. If you hit something non-obvious, write it down before moving on. Re-run `python3 scripts/shard_worklog.py` if structure drifts.

1. **FAIL FAST, FAIL LOUD.** Assertions, not silent returns. Crashes, not corrupted state. `error()` with a clear message, not a quiet `nothing`. If a wire is unmapped, if an SSA name is missing, if an instruction is unsupported — crash immediately with context.

2. **CORE CHANGES REQUIRE 3+1 AGENTS.** Any change to the core pipeline (`ir_extract.jl`, `lower.jl`, `bennett_transform.jl`), gate types (`gates.jl`, `ir_types.jl`), or the phi resolution algorithm requires: 2 proposer subagents (independent designs), 1 implementer. The orchestrating agent is the reviewer (+1). Proposers must not see each other's output. The implementer picks the better design (or synthesises). The orchestrator reviews for correctness, ancilla hygiene, and test coverage before accepting.

3. **RED-GREEN TDD.** Write the test first. Watch it fail (red). Write the minimum code to make it pass (green). Then refactor. This is the primary development workflow — adopted from v0.4 onward because it works. Tests live in `test/`. Every change needs tests. Use `@testset` and `@test`. For Int8 functions, test all 256 inputs. For wider types, test representative inputs plus edge cases.

4. **EXHAUSTIVE VERIFICATION.** Bennett's construction has a correctness invariant: all ancillae must return to zero. Every test must call `verify_reversibility` or check ancilla values explicitly. "Runs without errors" is not a passing test. The test must verify the actual output against a known-correct answer for every input.

5. **LLVM IR IS NOT STABLE.** LLVM IR output is not a stable API. Never assume specific IR formatting, instruction ordering, or naming conventions. The LLVM.jl C API walker (`ir_extract.jl`) is the source of truth — not regex parsing. When LLVM changes its output, `ir_extract.jl` must adapt. Always use `optimize=false` for predictable IR when testing.

6. **GATE COUNTS ARE REGRESSION BASELINES.** Verified gate counts (documented in `worklog/` chunks and pinned in `test/test_gate_count_regression.jl`) are regression tests. If a change alters gate counts for a known function, that is a signal — investigate whether it's an improvement or a bug. Key baselines (post-U27 `add=:auto`→`:ripple` + U28 `fold_constants=true`): i8 `x+1` = 58 gates, i16 = 114, i32 = 226, i64 = 450; each doubling obeys `total(2W) == 2·total(W) - 2`. Toffoli counts: 12/28/60/124 (each doubling obeys `T(2W) == 2·T(W) + 4`). See `test/test_gate_count_regression.jl` for the pinned assertions.

7. **BUGS ARE DEEP AND INTERLOCKED.** Never assume a bug is shallow. Phi resolution bugs, LLVM naming bugs, false-path sensitization — these are subtle and interconnected. Investigate root causes. A fix that passes one test but breaks the invariant elsewhere is not a fix.

8. **GET FEEDBACK FAST.** Run `julia --project -e 'using Bennett; ...'` or the test suite after every non-trivial change. Don't code blind for 500 lines then check. Check every 50 lines. For quick single-test feedback:
   ```bash
   julia --project test/test_increment.jl
   ```

9. **RESEARCH STEPS ARE EXPLICIT.** If you don't know how LLVM represents a construct, mark it as a research step. Don't guess. Don't hallucinate IR patterns. Extract actual IR with `code_llvm` and study it.

10. **SKEPTICISM.** Be skeptical of everything: subagent output, previous agent work, your own assumptions, LLVM documentation. Verify. Test. Reproduce. Especially skeptical of LLVM IR assumptions — extract and inspect actual IR before implementing a handler.

11. **PRD-DRIVEN DEVELOPMENT.** Every version has a PRD written before implementation. The PRD defines scope, success criteria, and test cases. Don't implement features not in the current PRD. Don't skip success criteria.

12. **NO DUPLICATED LOWERING.** Before implementing a new instruction handler, check what `lower.jl` already supports. Check `adder.jl`, `multiplier.jl` for arithmetic patterns. If a lowering exists, use it. If it doesn't, add it in the right place with proper documentation.

13. **SOFT-FLOAT MUST BE BIT-EXACT.** The soft-float library (`src/softfloat/`) implements IEEE 754 operations in pure integer arithmetic. Every soft-float function must be bit-exact against Julia's native floating-point operations. Test with random inputs AND edge cases (0, -0, Inf, NaN, subnormals, overflow boundaries).
   - **Transcendental subnormal-output convention (Bennett-fnxg / U_).** Every transcendental (`soft_exp`, `soft_log`, `soft_sin`, `soft_cos`, `soft_sinh`, `soft_tanh`, `soft_atan`, ...) MUST include a `@testset "subnormal-output range"` (or equivalent) in its bit-level test file that sweeps inputs `x` where `Base.<func>(x)` is subnormal, in steps fine enough to populate every binade (typically 0.25 or 0.5), asserting bit-exact equality (or ≤1 ulp tol) vs `Base.<func>`. Filed from the `soft_exp` post-mortem (Bennett-wigl): the `x ∈ [-708.4, -745]` garbage-output bug survived initial Bennett-cel testing because the random sweep ran on `[-50, 50]` and never visited the subnormal-output region. This catches the garbage-bug class up-front. Existing reference implementations: `test/test_softfexp.jl:135` and `test/test_softfexp_julia.jl:182`.

14. **NO GITHUB CI, NO REMOTE AUTOMATION.** Quality checks run LOCALLY via `Pkg.test()`, `bd`, and git hooks — never via GitHub Actions, workflows, scheduled runs, or any service that sends email on failure. The user has explicitly rejected automated CI: the failure-email noise is worse than zero signal. Do NOT create `.github/workflows/`, do NOT propose "add CI" beads, do NOT reference external build/test services. When the catalogue or a review mentions CI, treat it as out-of-scope and substitute local gates (pre-push git hook, `Pkg.test()` on every commit per rule 8, `bd` tracking per the Beads section). If a future agent re-proposes CI, point them at this rule.

## Phi Resolution and Control Flow — CORRECTNESS RISK

**CRITICAL FOR ALL AGENTS**: The phi resolution algorithm in `lower.jl` is the most complex and bug-prone part of the compiler. Phi nodes from LLVM IR represent value merging at control flow join points. The lowering converts them to nested MUX circuits (select via condition bits).

**Known failure mode: false-path sensitization.** When a phi node merges values from a diamond CFG (both branches of an outer if feed into the same inner phi), the MUX condition for one branch can fire without its guard condition being true. This is a well-known problem in VLSI circuit verification. The v0.5 soft-float overflow bug is an instance of this.

**Rules for phi resolution changes:**
1. Never modify the phi resolution algorithm without understanding the full CFG topology
2. Test with diamond CFGs, not just simple if/else
3. Verify that MUX conditions are properly guarded by their dominating branch conditions
4. When in doubt, draw the CFG and trace values through by hand

## Pipeline Architecture

```
Julia function          LLVM IR              Reversible Circuit
─────────────────      ─────────            ──────────────────
f(x::Int8)     ──►  extract_parsed_ir()  ──►  lower()  ──►  bennett()
                     (LLVM.jl C API)          (gates)       (fwd + copy + undo)
                                                                │
                                                                ▼
                                                          simulate(circuit, input)
                                                          verify_reversibility()
```

1. **Extract** — `extract_parsed_ir(f, arg_types)` uses LLVM.jl C API to walk IR as typed objects
2. **Lower** — `lower(parsed_ir)` maps each instruction to reversible gates (NOTGate, CNOTGate, ToffoliGate)
3. **Bennett** — `bennett(lr)` applies forward + CNOT-copy + reverse (all ancillae return to zero)
4. **Simulate** — `simulate(circuit, input)` runs bit-vector simulation with ancilla verification

## File Structure

```
Bennett.jl/                         # Project root. PRDs and CLAUDE.md live alongside Project.toml.
  Project.toml                      # deps: LLVM.jl; extras: InteractiveUtils, Test, Random, Pkg, PicoSAT
  Manifest.toml
  CLAUDE.md                         # this file — non-negotiable project rules
  README.md                         # public-facing intro
  WORKLOG.md                        # thin index pointing at sharded chunks under worklog/ (per §0)
  worklog/                          # 38 sharded session-log files, ~200-300 lines each, NNN_YYYY-MM-DD_<slug>.md
                                    #   highest NNN = most recent; prepend new sessions to the top chunk
  BENCHMARKS.md                     # canonical gate-count + Toffoli-depth baselines (T5 Pareto front)
  Bennett-VISION-PRD.md             # long-term v1.0 roadmap (Enzyme analogy)
  Bennett-Memory-PRD.md             # reversible mutable memory plan
  Bennett-Memory-T5-PRD.md          # T5 persistent-DS workstream

  src/                              # 30 included src/*.jl + softfloat/ (17) + persistent/ (10)
    Bennett.jl                      # module: 3 reversible_compile overloads (Tuple / ParsedIR / Float64), SoftFloat dispatch, callee registry

    # ---- IR extraction & representation ----
    ir_types.jl                     # IR struct hierarchy: IRBinOp, IRICmp, IRSelect, IRPhi, IRCall, IRStore, IRAlloca, IRSwitch, ...
    ir_extract.jl                   # LLVM.jl C-API walk → ParsedIR; callee registry; sret + vector + switch + intrinsic handling (~2.7k LOC; 3+1 split pending — Bennett-tzrs / U41)
    ir_parser.jl                    # legacy regex parser (backward compat; mostly used by test_parse.jl)

    # ---- Lowering: ParsedIR → gates ----
    lower.jl                        # per-opcode dispatch, loop unrolling, PHI-MUX resolution, load/store/alloca, strategy dispatchers (~2.9k LOC; 3+1 split pending — Bennett-vdlg / U40)
    wire_allocator.jl               # bump-allocator + free-list for ancilla wire slots

    # ---- Gate primitives & Bennett construction ----
    gates.jl                        # NOTGate, CNOTGate, ToffoliGate; ReversibleCircuit (with wire-partition-validation invariant — Bennett-6azb / U58)
    bennett_transform.jl            # bennett(lr): forward + CNOT-copy + reverse; self-reversing short-circuit (Bennett-egu6 / U03)
    controlled.jl                   # ControlledCircuit: lifts a circuit to take an explicit control bit

    # ---- Simulation & metrics ----
    simulator.jl                    # bit-vector simulate; ancilla-zero + input-preservation assertions; signedness inference (Bennett-zc50 / U100)
    diagnostics.jl                  # gate_count, ancilla_count, depth, t_count, t_depth, toffoli_depth, peak_live_wires, verify_reversibility, print_circuit

    # ---- Adders & multipliers ----
    adder.jl                        # ripple-carry full adder + Cuccaro in-place
    qcla.jl                         # Draper-Kutin-Rains-Svore 2004 quantum carry-lookahead adder
    multiplier.jl                   # shift-and-add + Karatsuba multiplier
    mul_qcla_tree.jl                # Sun-Borissov 2026 polylogarithmic-depth multiplier (self-reversing; arXiv:2604.09847)
    partial_products.jl             # emit_partial_products! / emit_conditional_copy! (Sun-Borissov §II.C building blocks)
    parallel_adder_tree.jl          # binary tree of QCLA adders; self-cleaning via _AdderRecord replay
    divider.jl                      # soft_udiv / soft_urem (registered as callees)

    # ---- Bennett strategy variants ----
    pebbling.jl                     # Knill 1995 (Theorem 2.1) — pebbled_bennett
    pebbled_groups.jl               # group-level pebbling with wire reuse + checkpoint_bennett
    eager.jl                        # PRS15 EAGER cleanup (gate-level)
    value_eager.jl                  # PRS15 Algorithm 2 value-level EAGER
    sat_pebbling.jl                 # Meuli et al. 2019 SAT-based optimal pebbling (PicoSAT)
    dep_dag.jl                      # gate dependency graph extraction

    # ---- Memory: reversible store/load primitives ----
    softmem.jl                      # soft_mux_*: reversible MUX-store/load on packed UInt64 arrays (registered callees)
    shadow_memory.jl                # universal reversible store/load via CNOT-copy pattern
    fast_copy.jl                    # Sun-Borissov 2026 Algorithm 1: reversible n-fold broadcast
    qrom.jl                         # Babbush-Gidney 2018 QROM via binary decision tree of Toffolis
    tabulate.jl                     # classical eval of f on all 2^W inputs → emit as QROM lookup
    memssa.jl                       # parse LLVM MemorySSA annotations for store/load alias resolution

    # ---- Crypto / hash ----
    feistel.jl                      # reversible Feistel network for bijective hashing

    softfloat/                      # 17 files: IEEE 754 binary64 in pure integer arithmetic (bit-exact vs Julia native)
      softfloat.jl                  # loader
      softfloat_common.jl           # shared branchless helpers (CLZ, round-to-nearest-even, ...)
      fadd.jl, fsub.jl, fmul.jl, fma.jl, fdiv.jl, fsqrt.jl, fneg.jl, fcmp.jl
      fpconv.jl, fptosi.jl, fptoui.jl, sitofp.jl, fround.jl
      fexp.jl                       # branchless integer exp / exp2
      fexp_julia.jl                 # Julia-idiom exp / exp2 variants

    persistent/                     # 10 files: persistent-map data structures (T5 workstream)
      persistent.jl                 # loader
      interface.jl                  # AbstractPersistentMap protocol
      harness.jl                    # correctness + benchmark harness (pmap_demo_oracle)
      linear_scan.jl                # brute-force baseline (winner at all measured scales — see worklog/026_2026-04-20_*.md)
      okasaki_rbt.jl                # Okasaki 1999 red-black tree
      hamt.jl                       # Bagwell HAMT
      cf_semi_persistent.jl         # Conchon-Filliâtre semi-persistent map
      hashcons_jenkins.jl           # Mogensen Jenkins-96 reversible hash
      hashcons_feistel.jl           # Feistel-based hash for hash-consing
      popcount.jl                   # pure-integer popcount (HAMT helper)

  test/                             # 143 test/*.jl files / ~67k assertions / ~200 testsets / ~5 min cold Pkg.test
    runtests.jl                     # canonical registration order
                                    # Conventions:
                                    #   test_<beadid>_*.jl    per-bead regression file (~50 files)
                                    #   test_<topic>.jl       pipeline / feature / metrics tests
                                    # Set BENNETT_T5_TESTS=0 to skip the multi-language corpus subset
                                    # (Julia / C via clang / Rust via rustc; clang+rustc self-skip if absent)

  benchmark/                        # bc{1..6}_*.jl + sweep + run_benchmarks scripts; outputs feed BENCHMARKS.md
  scripts/
    pre-push                        # git hook: runs Pkg.test() before push (per §14, replaces GitHub CI)
    install-hooks.sh                # installs pre-push into .git/hooks/
    fetch_t5_springer.mjs           # fetches T5 multi-language test corpus from Springer
    shard_worklog.py                # re-shards WORKLOG.md → worklog/*.md if structure drifts (Bennett-fyni / U70)
  build/                            # T5 corpus .ll/.bc fixtures (NOT a build-artifact directory)
  docs/
    prd/                            # versioned per-version PRDs (Bennett-PRD v0.1, BennettIR-PRD v0.2, ...)
    src/                            # Documenter-shaped source (no docs/make.jl yet — Bennett-doh6 / U158)
    design/                         # 3+1 proposer outputs + consensus docs (historical snapshots — do not mutate)
    literature/                     # SURVEY.md + paper PDFs (memory tier, multiplication, arithmetic)
    memory/                         # T1/T2/T3 design docs for the memory plan
  reviews/                          # frozen audit snapshots (e.g. 2026-04-21/19-agent review → UNIFIED_CATALOGUE.md)
```

## Build & Test

```bash
# Run full test suite
julia --project -e 'using Pkg; Pkg.test()'

# Run a single test file
julia --project test/test_increment.jl

# Quick REPL check
julia --project -e 'using Bennett; c = reversible_compile(x -> x + Int8(1), Int8); println(gate_count(c))'

# Activate and develop
julia --project
]test
```

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
