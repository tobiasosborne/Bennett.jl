# Master Code Review — Bennett.jl Pre-Sturm.jl Integration

**Date:** 2026-04-11
**Reviewers:** 6 independent agents (Test Coverage, Architecture/Research, Julia Idioms, Knuth, Torvalds, Carmack)
**Scope:** Full codebase (5,599 lines, 30 source files, 47 test files)
**Purpose:** Assess readiness for Sturm.jl integration

---

## Executive Summary

Bennett.jl is a **working, well-tested compiler** that achieves something no published system has done: LLVM-level reversible compilation with path-predicate phi resolution, branchless IEEE 754 soft-float, and multiple space-optimization strategies. The core pipeline (extract -> lower -> bennett -> simulate) is architecturally sound and the Bennett construction itself is 28 lines of provably correct code.

**However, the codebase has accumulated significant technical debt** from rapid feature development across v0.1-v0.8. The primary risks for Sturm.jl integration are:

1. **Silent correctness hazards** — fallback to buggy phi resolver, silent instruction drops, unmapped wire passthrough
2. **Test gaps** — 3 exported functions with zero tests, no gate count regression assertions, no negative tests
3. **Performance bottlenecks** — simulation 50-100x slower than necessary, gates stored as boxed abstract types
4. **Code maintainability** — 1420-line lower.jl, 576-line monolith function, ~150 lines duplicated soft-float code, global mutable state

**Recommendation:** Fix all CRITICAL and HIGH-correctness issues before Sturm.jl integration. The integer path (Int8-Int64) is solid and ship-ready. Float64 works but has performance concerns.

---

## Findings by Severity

### CRITICAL (4 findings) — Must fix before integration

| # | Finding | Source | File |
|---|---------|--------|------|
| C1 | Silent fallback to buggy phi resolver when `block_pred` empty | Torvalds, Arch | `lower.jl:767-776` |
| C2 | Global mutable `_name_counter` — thread-unsafe, manual save/restore in lower_call! | Torvalds, Julia, Arch | `ir_extract.jl:57-63` |
| C3 | `_remap_gate` silently passes through unmapped wires — corruption risk in checkpoint replay | Arch | `pebbled_groups.jl:14` |
| C4 | `pebbled_bennett` doesn't recursively sub-pebble — flat forward/reverse ignores space budget | Knuth | `pebbling.jl:183-195` |

### HIGH — Correctness (6 findings)

| # | Finding | Source | File |
|---|---------|--------|------|
| H1 | Silent instruction drop — no `else error()` in lower_block_insts! dispatch | Torvalds | `lower.jl:449-452` |
| H2 | Bare `try/catch` swallows ALL exceptions including OOM | Torvalds, Julia | `ir_extract.jl:858-859` |
| H3 | Dead `resolve!` call immediately overwritten | Torvalds | `lower.jl:1252` |
| H4 | `@assert` used for core correctness invariants (can be disabled) | Julia | `simulator.jl:31`, `controlled.jl:82,84`, `diagnostics.jl:140` |
| H5 | `lower_call!` accumulates all callee ancillae into caller (108K wires for Float64 poly) | Arch | `lower.jl:1377-1421` |
| H6 | Cuccaro in-place adder correctness depends entirely on liveness analysis — fragile invariant | Knuth | `adder.jl` + `lower.jl:898` |

### HIGH — Testing (6 findings)

| # | Finding | Source | File |
|---|---------|--------|------|
| T1 | `soft_sitofp` — 87 lines, ZERO tests | Test | `softfloat/sitofp.jl` |
| T2 | `soft_ceil` — ZERO tests (missing from test_float_intrinsics.jl) | Test | `softfloat/fround.jl:76-88` |
| T3 | No gate count regression assertions — CLAUDE.md mandates them | Test | All test files |
| T4 | ZERO negative tests in entire suite | Test | — |
| T5 | `soft_fcmp_ole`/`soft_fcmp_une` — no library-level tests | Test | `softfloat/fcmp.jl` |
| T6 | `constant_wire_count` exported, never tested | Test | `diagnostics.jl:73-101` |

### HIGH — Code Quality (4 findings)

| # | Finding | Source | File |
|---|---------|--------|------|
| Q1 | ~150 lines duplicated soft-float code (CLZ, rounding, subnormal) | Torvalds, Julia, Carmack | `fadd.jl`, `fmul.jl`, `fdiv.jl` |
| Q2 | `_convert_instruction` is 576-line monolith | Julia, Torvalds | `ir_extract.jl:265-841` |
| Q3 | `lower_block_insts!` uses 12 sequential `isa` checks (not dispatch) | Julia | `lower.jl:424-459` |
| Q4 | Callee registry substring matching — "add" would match "soft_fadd" | Torvalds, Arch, Carmack | `ir_extract.jl:42-49` |

### HIGH — Performance (4 findings)

| # | Finding | Source | File |
|---|---------|--------|------|
| P1 | Simulation uses `Vector{Bool}` + dynamic dispatch — 50-64x slower than batched UInt64 | Carmack | `simulator.jl` |
| P2 | Gates stored as boxed abstract types — 3-5x memory waste | Carmack | `gates.jl` |
| P3 | Wire allocator `free!` is O(n) insert into sorted list (comment says "min-heap") | Carmack, Torvalds, Julia | `wire_allocator.jl` |
| P4 | `reverse(lr.gates)` allocates full copy of gate vector | Julia, Carmack | `bennett.jl:20` |

### MEDIUM — Correctness (5 findings)

| # | Finding | Source | File |
|---|---------|--------|------|
| M1 | Karatsuba wire count O(W^2.58) — worse in space than schoolbook O(W^2) | Knuth | `multiplier.jl` |
| M2 | `soft_fdiv` sticky bit may shift to wrong position on normalization | Knuth | `fdiv.jl:64-66` |
| M3 | Cuccaro adder + checkpoint optimization mutually exclusive | Arch | `pebbled_groups.jl:225-229` |
| M4 | Constant wires allocated fresh per use (same constant = 3 separate 64-wire encodings) | Arch | `lower.jl:48-58` |
| M5 | Wire allocator `free!` doesn't verify wires are zero before reuse | Knuth, Arch | `wire_allocator.jl` |

### MEDIUM — Code Quality (8 findings)

| # | Finding | Source | File |
|---|---------|--------|------|
| M6 | `lower.jl` is 1420 lines doing 10+ jobs — should be 5 files | Torvalds | `lower.jl` |
| M7 | `ir_parser.jl` is dead code still included and exported | Torvalds, Arch, Julia | `ir_parser.jl` |
| M8 | `ParsedIR.instructions` computed property allocates new array every access | Torvalds, Julia | `ir_types.jl:134-145` |
| M9 | `Vector{Any}` in simulator `_read_output` and lower `phi_info` | Julia | `simulator.jl:42`, `lower.jl:555` |
| M10 | Float64 compile hardcoded to max 3 arguments | Torvalds, Carmack | `Bennett.jl:140` |
| M11 | GateGroup has 3 backward-compat constructors | Torvalds | `lower.jl:19-20` |
| M12 | Ancilla computation pattern duplicated 5 times across bennett variants | Julia | Multiple files |
| M13 | No docstrings on exported types (gates, circuits, IR types) | Julia | Multiple files |

### MEDIUM — Testing (7 findings)

| # | Finding | Source | File |
|---|---------|--------|------|
| M14 | Division tested only on small ranges (225 of 65,536 pairs); srem not tested | Test | `test_division.jl` |
| M15 | Wire allocator has no unit tests | Test | — |
| M16 | `dep_dag.jl` tests purely structural — no edge correctness verification | Test | `test_dep_dag.jl` |
| M17 | Two-arg function tests miss negative values entirely | Test | `test_two_args.jl` |
| M18 | Int16 tests miss typemin/typemax edge cases | Test | `test_int16.jl` |
| M19 | SAT pebbling tested only on tiny DAGs (3-5 nodes) | Test | `test_sat_pebbling.jl` |
| M20 | `soft_fround` functions lack dedicated library tests | Test | — |

### MEDIUM — Performance (3 findings)

| # | Finding | Source | File |
|---|---------|--------|------|
| M21 | `peak_live_wires` simulates entire circuit for diagnostics | Arch, Carmack | `diagnostics.jl:110-125` |
| M22 | Callee compilation not cached (same function re-compiled on each call) | Carmack | `lower.jl:1377` |
| M23 | `popfirst!` on sorted Vector is O(n) in wire allocator | Julia | `wire_allocator.jl:12` |

### LOW (12 findings)

| # | Finding | Source |
|---|---------|--------|
| L1 | Controlled circuits not tested with loops, tuples, wider types, Float64 | Test |
| L2 | Loop test misses negative inputs | Test |
| L3 | `soft_fsub` edge cases lighter than `fadd` | Test |
| L4 | `pebble_tradeoff` return value not verified against knill_pebble_cost | Test |
| L5 | Missing `@inline` on simulation apply! methods | Julia |
| L6 | `collect(LLVM.parameters)` allocates unnecessarily | Julia |
| L7 | Unused enumerate loop variable pattern | Julia |
| L8 | No gate cancellation pass (adjacent self-inverse pairs) | Arch |
| L9 | No incremental circuit composition API (compose, parallel) | Carmack |
| L10 | No resource estimation before compilation | Carmack |
| L11 | `max_loop_iterations` footgun — no detection of incomplete unrolling | Carmack |
| L12 | `_read_output` type-unstable return (inherent but undocumented) | Julia |

---

## Cross-Reviewer Consensus

These findings were flagged independently by 3+ reviewers:

1. **lower.jl too large** (Torvalds, Julia, Knuth, Carmack) — unanimous
2. **Soft-float code duplication** (Torvalds, Julia, Carmack) — unanimous
3. **Global mutable _name_counter** (Torvalds, Julia, Architecture) — 3/6
4. **Callee substring matching fragile** (Torvalds, Architecture, Carmack) — 3/6
5. **Wire allocator not a real heap** (Torvalds, Julia, Carmack) — 3/6
6. **Legacy parser is dead code** (Torvalds, Architecture, Julia) — 3/6

---

## Novel Contributions (Positive Findings)

The reviewers also identified genuine strengths:

1. **Path-predicate phi resolution** — no prior reversible compiler handles multi-way phi from complex CFGs (Architecture, Knuth)
2. **Branchless IEEE 754 soft-float** — more complete than any published quantum FP circuit (Architecture, Carmack, Knuth)
3. **LLVM-level reversible compilation** — first system to operate at LLVM IR level for reversibility (Architecture)
4. **Bennett construction is 28 lines of provably correct code** (Torvalds, Carmack, Knuth)
5. **Exhaustive Int8 testing** — gold standard approach (Carmack, Test)
6. **Exceptional WORKLOG** as institutional memory (Architecture)

---

## Ship Readiness for Sturm.jl

**Integer path (Int8-Int64): READY** after fixing C1-C4 and H1-H4.

**Float64 path: FUNCTIONAL but needs optimization.** 265K gates per fmul means a simple Float64 expression generates millions of gates. Karatsuba multiplier (already implemented, disabled by default) would help. Constant folding (implemented, disabled) would help.

**Minimum viable integration:**
1. Fix CRITICAL findings (C1-C4)
2. Fix HIGH correctness findings (H1-H6)
3. Add gate count regression tests (T3)
4. Add negative tests for error paths (T4)
5. Replace `@assert` with `error()` for core invariants (H4)
6. Ship integer path to Sturm.jl
7. Follow up with performance and Float64 optimization

---

## Individual Reports

- [01_test_coverage.md](01_test_coverage.md) — 18 findings, 424 lines
- [02_architecture_research.md](02_architecture_research.md) — 10 findings, ~400 lines
- [03_julia_idioms.md](03_julia_idioms.md) — 36 findings, ~500 lines
- [04_knuth_review.md](04_knuth_review.md) — 32 findings, ~800 lines
- [05_torvalds_review.md](05_torvalds_review.md) — 18 findings, ~400 lines
- [06_carmack_review.md](06_carmack_review.md) — 15 findings, ~450 lines
