# Correctness verification — Bennett-37w3 (585bfe0) — 2026-09-26
Status: IN PROGRESS
Verdict: pending execution

## Executed counterexamples (each: fixture, inputs wrong /256, verify result)

None recorded yet.

## Concerns (non-executed, reasoned)

Verification started after reading CLAUDE.md in full. The task-specific restriction to one report file overrides worklog, beads, commit, and full-suite workflow requirements. All probes will run in memory; no source or test edits.

## Regression run results

Pending.

## Test-file critique

Pending whole-diff inspection and pre-fix guard emulation.

## What is sound

Pending independent exhaustive probes.

### Inspection checkpoint

- Read the entire `585bfe0` diff (174-line memory change, all 346 lines of the new test, and registration), both proposals, and the F1 review evidence. Working HEAD is `fb18a0e`; the memory implementation and new test match `585bfe0` exactly. Later unrelated changes exist, including simulator input-range checks; no checkout was made.
- The source forms `B ∧ P_o` at each store and passes the complete guard to all three backends. Provenance is not mutated. The equal-wire fast path avoids an invalid duplicate-control Toffoli.
- `driver.jl` computes a predicate before lowering each reachable ordinary block. `cfg.jl` computes iteration-local body predicates before dispatch and supplies the header predicate separately. Entry-unreachable blocks deliberately lack predicates but still have instructions lowered; the new check rejects multi-origin stores there.
- Repository search found no production caller explicitly passing a sentinel store label: the sole IRStore dispatcher passes the real label; single-origin and fan-out helper calls forward it. The default arguments still permit sentinel calls, and single-origin static shadow/persistent stores still interpret it as unconditional. Comments in `types.jl` and `memory.jl:1029` overstate the old sentinel behavior.
- Initial regression harness omitted `using Bennett`, which `test_cb9y_multi_origin_runtime_idx.jl` expects from its caller (three harness errors, no circuit executed). Restarted with `using Test, Bennett`; this is not a compiler counterexample.

### Independent execution checkpoint 1

All successful independent probes use `LLVM.verify` on in-memory `julia_*` modules, then `_module_to_parsed_ir`. Every circuit is swept over all 256 Int8 values with a separate imperative oracle. `simulate!` buffers are inspected explicitly for zero ancillae after the complete circuit, in addition to its input-preservation checks; `verify_reversibility` is called per circuit.

- Mixed origins: scalar alloca versus another alloca's constant GEP; scalar versus dynamic GEP (N=4 MUX, N=16 checkpoint); two aliasing origins into one N=4 alloca. All slots are initialized to distinct values and included in the XOR observation. Each of these four fixtures passed folding off/on × compact_calls off/on with `mem=:persistent`: **16 circuits, 0/256 wrong each, no dirty ancillae, reversibility true**. Constant-sized persistent-mode allocas exercise the ordinary store backends as intended. Gate totals respectively: static 1154/356; N=4 dynamic 5090/1568 (compact 8364/2266); N=16 dynamic 4322/1592; alias N=4 5090/1580 (compact 8364/2310), unfolded/folded.
- Multi-iteration body store: a pre-loop selected pointer, data-dependent 1–4 active iterations, store value `40+k` under an independent input bit, K=4, folding off: **0/256 wrong, reversibility true, no dirty ancillae**, 2361 gates/705 wires. Remaining loop configurations are running.
- Required cb9y regression file: **77/77 pass**.
