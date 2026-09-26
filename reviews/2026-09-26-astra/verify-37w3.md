# Correctness verification — Bennett-37w3 (585bfe0) — 2026-09-26
Status: IN PROGRESS
Verdict: FAIL

## Executed counterexamples (each: fixture, inputs wrong /256, verify result)

### C1 — Selected-pointer header stores keep executing after loop exit (existing upstream activation defect)

LLVM-verified `julia_loop` fixture: initialize a=11,b=22; choose p by input bit 0 before the loop; n=((unsigned(x)>>2)&3)+1. Header phi k starts at zero. Each header evaluation increments `*p`, then exits if k==n. In the body, input bit 1 conditionally stores `40+k` through p; latch increments k. Return a XOR b. The independent oracle executes the actual loop, including precisely n+1 header increments.

| K | Folding | Wrong /256 | Example (input, circuit, oracle) | verify_reversibility | Dirty ancilla inputs |
|---|---|---:|---|---|---:|
| 4 | off/on | 192 | (-128, 16, 19) | true | 0 |
| 6 | off/on | 256 | (-128, 22, 19) | true | 0 |

Cause: `cfg.jl:420` seeds the header from the function-level predicate for every unrolled iteration, and `cfg.jl:542–562` repeats header effects during the convergence pass. `B ∧ P_o` is only as accurate as B; the header B never becomes inactive after exit. This is the existing B-lowering F5 family, expressly acknowledged in both proposals, not evidence that 585bfe0 introduced the defect. Under the requested definition (any executed wrong result), it nevertheless requires **FAIL**. The same fixture with the header increment removed passes all 256 inputs at K=4/6 and folding off/on.

Multiple-exit variant (a body `break` at k=1 under input bit 6) is LLVM-valid but rejected at compile time in all four K/fold combinations by the explicit c6ex “second loop exit ... not supported” check. No circuit exists to simulate or verify. This is a declared pre-existing limitation, not a missing-store-predicate assertion or a 37w3 regression.

## Concerns (non-executed, reasoned)

Verification started after reading CLAUDE.md in full. The task-specific restriction to one report file overrides worklog, beads, commit, and full-suite workflow requirements. All probes will run in memory; no source or test edits.

## Regression run results

Completed bounds-checked targeted regression run, importing `Test, Bennett` as the normal harness does:

| File | Pass / total |
|---|---:|
| test_cb9y_multi_origin_runtime_idx.jl | 77 / 77 |
| test_c6ex_predication_soundness.jl | 115 / 115 |
| test_37w3_selected_pointer_store_predicate.jl | 160 / 160 |
| test_gate_count_regression.jl | 39 / 39 |
| test_lower_store_alloca.jl | 41 / 41 |
| test_shadow_memory.jl | 594 / 594 |
| test_munq_arr_i8_alloca.jl | 69 / 69 |
| test_ixiz_wider_alloca.jl | 53 / 53 |
| **Total** | **1148 / 1148** |

No full suite run. Command: `julia --project --check-bounds=yes --compiled-modules=existing --startup-file=no -e 'using Test, Bennett; for f in files; @testset "$f" begin include(joinpath("test",f)); end; end'`, with `files` equal to the eight rows above.

## Test-file critique

The 346-line test file is registered and passes **160/160**. Its independent bitwise oracles are not defined from circuit outputs, and all successful simulations check ancillae and input preservation. In a separate Julia process I redefined only `_store_origin_guard!` to return `origin_wire` and re-executed exactly the test matrix (replaced `_37w3_check` with a result collector to avoid 50 stack traces). Result: **80 circuits: 30 with 0 wrong, 38 with 64/256 wrong, 12 with 96/256 wrong; all 80 reversibility checks true**. This exactly reproduces **50 failed correctness assertions out of 160 assertions**.

The 30 pre-fix successes are intentional controls: 12 selected loads, 12 entry stores, and 6 pointer-reuse cases. The reuse control overwrites the same selected slot unconditionally with 7, so its output masks the preceding erroneous 9 store: it is vacuous *as an F1 detector*, but useful for detecting accidental restriction of shared provenance. Independent two-condition/two-store probes were added in memory for that gap. The loop regression has K=2 but only **one active body iteration**, so it does not substantiate arbitrary multi-iteration or header-side-effect soundness. No direct sentinel/equal-wire helper assertions, persistent-mode constant-alloca cases, or nested-selects-of-selects cases appear in this file. The opening “every store shape ... 64/256” comment overlooks the nested outer-branch case (96/256).

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

### Independent execution checkpoint 2

- Nested selects of selects (four origins), pointer phi with both incoming predecessors themselves branching, one selected pointer stored through in two separately conditional blocks, a post-dominating store, and repeated identical pointer operands (`select(c,a,a)` nested again): **20 circuits** across folding off/on × mem auto/persistent. All **0/256 wrong**, reversibility true, zero dirty ancillae. Initial four cells 11/22/33/44 are XOR-observed; the oracle updates the independently selected cell only on the actual taken path.
- Ordinary body-store loops with 1–4 active iterations passed K=4/6 × folding off/on: **4 circuits**, all 0/256 wrong, clean ancillae, reversibility true. Header effects are the counterexample above, not ordinary iteration-local body guarding.

### Independent execution checkpoint 3 — scaling and Julia reachability

Fan-out tests use a balanced binary tree of selects over separately initialized scalar allocas, independently guard the store with bit 3, and XOR-observe every cell. All accepted current-guard circuits below pass all 256 inputs and reversibility with zero dirty ancillae. Instrumentation counted exactly m calls taking the fresh-AND branch for m origins.

| Origins | Gates off/on | Wires | `peak_live_wires` off/on | Old-guard gates off / wires |
|---:|---:|---:|---:|---:|
| 2 | 708 / 232 | 286 | 39 / 38 | 704 / 284 |
| 4 | 1032 / 372 | 392 | 62 / 61 | 1024 / 388 |
| 8 | 1682 / 640 | 608 | 108 / 108 | 1666 / 600 |

The exact marginal cost is **m wires and 2m full-circuit gates**, bounded by 8 wires/16 gates per store. A 16-origin tree fails loudly at the producer's pre-existing fan-out cap, in both fold modes. Repeating an 8-origin store 1/8/32 times gave 608/1168/3088 wires and library peaks 108/133/217; growth is linear in the number of emitted stores, not a runaway per-origin allocation. “Never freed” means retained for Bennett reverse, not left nonzero after it. The library peak metric simulates zero input only; it is not an exhaustive maximum.

The old guard gives 128/256 wrong on these XOR-observed fan-out tests, despite clean ancillae and passing reversibility. F1 direct measurements confirm 456→460 gates unfolded, 154→158 folded for observing a. Observing b is 456→460 and 158→162. The +4 delta is **not exclusive to F1**: other non-entry fan-outs also pay 2m gates even if previously semantically correct. No memory pin covers that case: the `nj6c` pins use a single-origin entry store. Its additional targeted regression passed **129/129**, bringing executed regression assertions to **1277/1277**.

Real Julia probes:

- Ordinary `Ref{Int8}` selected-store and nested-selected-store functions agree with the independent imperative oracle on all 256 native executions. Extraction rejects both before memory lowering: `julia.get_pgcstack` at optimize=false, inline assembly for a thread pointer at optimize=true. These are existing frontend limitations; they provide no evidence about guard correctness.
- A Julia `Base.llvmcall` function containing the minimal selected-pointer store **does** survive optimize=true extraction as three IRStores and one pointer IRSelect. Both folded/unfolded circuits pass all 256 inputs, explicit zero-ancilla checks, and reversibility (574/224 gates, 227 wires). At optimize=false its unregistered LLVM helper call is rejected. This is an executed Julia entry point, but it uses embedded LLVM rather than ordinary Ref source.
- An independently constructed ParsedIR with two stores through the same p under independent bits 1 and 2 passes folding off/on × compact_calls off/on: **four circuits, 0/256 wrong, clean ancillae, reversibility true** (680/254 gates). Its oracle uses the second store's 7 when taken, otherwise the first store's 9 when taken, otherwise the initial value.

---
## Orchestrator adjudication (2026-09-26, after the session was cut off by the codex usage limit)

The verifier's FAIL is triggered by C1: a selected-pointer store placed in a LOOP HEADER keeps
executing after loop exit (192/256 wrong at K=4, 256/256 at K=6, reversibility passes). The
verifier itself attributes this to the header-activation defect described in both proposals —
that is Bennett-lowering F5 = **Bennett-i5zn** (loop-header side effects after exit, filed P1,
CORE → 3+1), which 37w3 explicitly did not attempt to fix. The 37w3 guard is `B ∧ P_o`; when the
header's B is itself wrong after exit, the conjunction inherits that error. Every probe aimed at
the 37w3 change proper passed: mixed origins, folding on/off, `compact_calls` on/off, constant-
size allocas under `mem=:persistent`, loops with up to four active iterations (ancillae zero
after the full circuit), and eight regression files (1,148 assertions).

**Adjudicated verdict for Bennett-37w3: PASS-WITH-CONCERNS** (the concern is i5zn, not 37w3).
The C1 fixture is a ready-made RED test for i5zn and is recorded on that bead.
