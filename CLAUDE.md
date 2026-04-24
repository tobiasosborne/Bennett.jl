# Bennett.jl — Reversible Circuit Compiler

## What This Is

A Julia compiler that takes plain Julia functions on plain integers (and Float64 via soft-float) and compiles them into classical reversible circuits (NOT, CNOT, Toffoli gates) via Bennett's 1973 construction. The long-term goal: quantum control in Sturm.jl via `when(qubit) do f(x) end`.

Full PRDs: `Bennett-PRD.md` (v0.1), `BennettIR-PRD.md` (v0.2), `BennettIR-v03-PRD.md` (v0.3), `BennettIR-v04-PRD.md` (v0.4), `BennettIR-v05-PRD.md` (v0.5).

**Backend: LLVM.jl from v0.2.** The compiler extracts LLVM IR from plain Julia functions via LLVM.jl's C API, walks the IR as typed objects, lowers each instruction to reversible gates, and applies Bennett's construction. No operator overloading, no special types — plain Julia in, reversible circuit out.

## Implementation Principles

These are NON-NEGOTIABLE. Every agent, every session, every commit.

0. **MAINTAIN THE WORKLOG.** Every step, every session: update `WORKLOG.md` with gotchas, learnings, surprising decisions, LLVM IR quirks, test failures and their root causes, anything a future agent would wish it knew. This is the project's institutional memory. If you hit something non-obvious, write it down before moving on.

1. **FAIL FAST, FAIL LOUD.** Assertions, not silent returns. Crashes, not corrupted state. `error()` with a clear message, not a quiet `nothing`. If a wire is unmapped, if an SSA name is missing, if an instruction is unsupported — crash immediately with context.

2. **CORE CHANGES REQUIRE 3+1 AGENTS.** Any change to the core pipeline (`ir_extract.jl`, `lower.jl`, `bennett.jl`), gate types (`gates.jl`, `ir_types.jl`), or the phi resolution algorithm requires: 2 proposer subagents (independent designs), 1 implementer. The orchestrating agent is the reviewer (+1). Proposers must not see each other's output. The implementer picks the better design (or synthesises). The orchestrator reviews for correctness, ancilla hygiene, and test coverage before accepting.

3. **RED-GREEN TDD.** Write the test first. Watch it fail (red). Write the minimum code to make it pass (green). Then refactor. This is the primary development workflow — adopted from v0.4 onward because it works. Tests live in `test/`. Every change needs tests. Use `@testset` and `@test`. For Int8 functions, test all 256 inputs. For wider types, test representative inputs plus edge cases.

4. **EXHAUSTIVE VERIFICATION.** Bennett's construction has a correctness invariant: all ancillae must return to zero. Every test must call `verify_reversibility` or check ancilla values explicitly. "Runs without errors" is not a passing test. The test must verify the actual output against a known-correct answer for every input.

5. **LLVM IR IS NOT STABLE.** LLVM IR output is not a stable API. Never assume specific IR formatting, instruction ordering, or naming conventions. The LLVM.jl C API walker (`ir_extract.jl`) is the source of truth — not regex parsing. When LLVM changes its output, `ir_extract.jl` must adapt. Always use `optimize=false` for predictable IR when testing.

6. **GATE COUNTS ARE REGRESSION BASELINES.** Verified gate counts (documented in WORKLOG.md) are regression tests. If a change alters gate counts for a known function, that is a signal — investigate whether it's an improvement or a bug. Key baselines: i8 addition = 86 gates, i16 = 174, i32 = 350, i64 = 702 (exactly 2x per width doubling).

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
Bennett.jl/
  Project.toml
  src/
    Bennett.jl            # module definition, exports, reversible_compile entry point
    ir_types.jl           # IR representation: IRBinOp, IRICmp, IRSelect, IRPhi, etc.
    ir_extract.jl         # LLVM IR extraction via LLVM.jl C API (two-pass name table)
    ir_parser.jl          # legacy regex parser (backward compat)
    gates.jl              # NOTGate, CNOTGate, ToffoliGate, ReversibleCircuit
    wire_allocator.jl     # sequential wire allocation
    adder.jl              # ripple-carry adder and subtraction
    multiplier.jl         # shift-and-add multiplier
    lower.jl              # LLVM IR -> reversible gates (phi resolution, MUX, loops)
    bennett.jl            # Bennett construction: forward + copy + uncompute
    simulator.jl          # bit-vector simulator
    diagnostics.jl        # gate_count, ancilla_count, depth, verify_reversibility
    controlled.jl         # ControlledCircuit wrapper (NOT->CNOT, CNOT->Toffoli, Toffoli->decomp)
    softfloat/
      softfloat.jl        # module definition
      fadd.jl             # IEEE 754 soft-float addition
      fneg.jl             # IEEE 754 soft-float negation
  test/
    runtests.jl
    test_increment.jl     # f(x) = x + 3, all 256 inputs
    test_polynomial.jl    # f(x) = x^2 + 3x + 1, all 256 inputs
    test_bitwise.jl       # &, |, ^, ~
    test_compare.jl       # icmp + select
    test_two_args.jl      # multi-argument functions
    test_controlled.jl    # controlled circuits
    test_branch.jl        # if/else via br + phi
    test_loop.jl          # LLVM-unrolled loops
    test_combined.jl      # controlled + branching
    test_int16.jl         # Int16 arithmetic
    test_int32.jl         # Int32 arithmetic
    test_int64.jl         # Int64 arithmetic
    test_mixed_width.jl   # sext/zext/trunc
    test_loop_explicit.jl # bounded loop unrolling
    test_tuple.jl         # tuple return via insertvalue
    test_softfloat.jl     # soft-float library (1,037 tests)
    test_float_circuit.jl # soft-float circuit compilation
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

## Session Completion

When ending a work session:

1. **Update WORKLOG.md** with session learnings, gotchas, gate counts, bugs found
2. **Run the full test suite** — all tests must pass
3. **Commit and push** — work is not complete until pushed


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
