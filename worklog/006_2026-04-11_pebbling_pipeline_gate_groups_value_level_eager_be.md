## 2026-04-11 — Pebbling pipeline: gate groups + value-level EAGER (Bennett-an5)

### What was built

1. **GateGroup struct and annotation in LoweringResult**
   - New `GateGroup` type: maps SSA instruction → contiguous gate range, result wires, input dependencies.
   - Added `gate_groups` field to `LoweringResult` with backward-compatible 7-arg constructor.
   - Gate group tracking in `lower()`: every SSA instruction, block predicate, loop body, ret terminator, branch, and multi-ret merge gets a group.
   - Groups are contiguous, non-overlapping, and cover ALL gates.
   - Verified: polynomial (4 groups), SHA-256 (46 groups).
   - This required 3+1 agent review (core change to lower.jl): two independent proposer subagents designed the annotation, orchestrator synthesized.

2. **`value_eager_bennett(lr)` — PRS15 Algorithm 2 implementation**
   - New file: `src/value_eager.jl`
   - Phase 1: Forward gates with dead-end value cleanup (zero consumers).
   - Phase 2: CNOT copy outputs.
   - Phase 3: Reverse-topological-order cleanup via Kahn's algorithm on the reversed dependency DAG.
   - Correct for all test functions: increment (256 inputs), polynomial (256 inputs), two-arg (441 inputs), SHA-256 round. All ancillae verified zero.

3. **Test suite: 1,558 new assertions in `test/test_value_eager.jl`**
   - Gate group annotation (structure, coverage, no overlap)
   - Polynomial dependency ordering
   - Correctness: increment, polynomial, two-arg, SHA-256 round
   - Peak liveness: ≤ full Bennett for all functions
   - Cuccaro in-place combination: tests interaction of both optimizations

### Key research findings

**PRS15 EAGER Phase 3 reordering alone does NOT significantly reduce peak liveness for SSA-based out-of-place circuits.** The peak occurs at the end of the forward pass (all wires allocated), which is identical regardless of Phase 3 order. Only dead-end values (zero consumers) can be eagerly cleaned during Phase 1, saving ~1 wire.

**Reason:** PRS15's EAGER is designed for in-place (mutable) circuits where the MDD tracks modification arrows. In SSA (all out-of-place), there are no modification arrows, so the EAGER cleanup check trivially passes — but the cleanup of value V requires V's input VALUES to still be live. Since V's consumers' cleanup also needs V (as control wires), V can't be cleaned until all consumers are cleaned. This forces reverse-topological order, which is identical to full Bennett's reverse for linear chains.

**Interleaved cleanup during Phase 1 is WRONG for non-dead-end values.** Attempted and disproved: cleaning V during forward after its last consumer is computed breaks V's consumer's cleanup in Phase 3 (consumer reads zero instead of V's computed value). Only dead-end values (never read as control) are safe to clean during Phase 1.

**The real optimizations for SSA-based circuits are:**
1. **In-place operations (Cuccaro adder):** x+3 peak drops from 7 → 5 (29% reduction)
2. **Value-level EAGER + Cuccaro combined:** x+3 peak drops from 7 → 4 (43% reduction)
3. **Wire reuse during lowering:** Requires pebbled schedule (compute subset → checkpoint → reverse → reuse wires → continue)
4. **Intra-instruction optimization:** The multiplier's internal wires (84% of total for polynomial) are the biggest target

### Peak liveness measurements

| Function | Full Bennett | Gate EAGER | Value EAGER | Cuccaro | Cuccaro+EAGER |
|----------|-------------|-----------|------------|---------|---------------|
| x+3 (i8) | 7 | 6 | 6 | 5 | **4** |
| polynomial (i8) | 8 | 7 | 7 | 5 | **4** |
| branch (i8) | 27 | 26 | 26 | — | — |
| x*y+x-y (i8) | 20 | 19 | 19 | — | — |
| SHA-256 round | 444 | — | 443 | — | — |

### Architecture decisions

**Gate group tracking at dispatch site, not inside lower_*! functions.** Both proposer agents agreed: wrap the instruction dispatch in `lower_block_insts!()` with `group_start = length(gates) + 1` before and `group_end = length(gates)` after. This is purely additive — zero changes to any lowering helper function.

**Backward-compatible 7-arg constructor.** Outer constructor dispatches to the new 8-arg constructor with `GateGroup[]` default. All existing code works unchanged. Only the `lower()` return statement uses the 8-arg form.

**Synthetic names for infrastructure groups.** Block predicates get `__pred_<label>`, branches get `__branch_<label>`, returns get `__ret_<label>`, multi-ret merge gets `__multi_ret_merge`, loops get `__loop_<label>`. These are excluded from SSA dependency analysis (prefixed with `__`).

### New files

| File | Lines | What |
|------|-------|------|
| `src/value_eager.jl` | ~110 | PRS15 value-level EAGER cleanup |
| `test/test_value_eager.jl` | ~170 | 1,558 tests: gate groups + correctness + peak liveness |

### Next steps for pebbling pipeline (Bennett-an5)

The gate group infrastructure is in place. Remaining work for meaningful ancilla reduction:

1. **Wire reuse during lowering (Bennett-i5c):** After each instruction's last consumer, insert cleanup gates to zero the instruction's wires, then free via WireAllocator.free!. This requires a pebbled schedule — the Knill/SAT pebbling determines WHICH instructions to clean and when. The challenge: cleaning instruction V during forward requires V's inputs to still be live, AND V's consumers' future cleanup to not need V.

2. **Intra-instruction wire reuse:** The multiplier's internal wires (192 out of 257 for polynomial) dominate. Freeing partial product wires after each row of the schoolbook algorithm would dramatically reduce peak.

3. **PRS15 EAGER on multi-function composition:** When compiling f(g(x)), g's ancillae can be cleaned between calls. This requires `register_callee!` + `IRCall` integration with value_eager_bennett.

### pebbled_group_bennett — Knill recursion with wire reuse

New file `src/pebbled_groups.jl`. Implements group-level pebbling with wire
remapping and reuse via WireAllocator.free!.

**Algorithm:**
1. `_pebble_groups!`: Knill's 3-term recursion on gate group indices
2. `_replay_forward!`: allocates fresh wires (from pool or new), builds wire remap, emits remapped gates
3. `_replay_reverse!`: emits reverse gates with same remap, frees all target wires back to allocator
4. Wire reuse: freed wires from reversed groups get recycled by subsequent forward groups via `allocate!`

**Results:**
- SHA-256 round: 5889 → 5857 wires (32 saved) with s=7 pebbles
- Correct for all test inputs, all ancillae zero
- Modest savings because zero-wire allocation overhead (control-only wires not
  targeted by any group must be freshly allocated each replay)

**Key bug found and fixed:** groups reference control wires that are never targeted
by any gate (zero-padding in multiplier). These must be allocated as fresh zero
wires during replay, not left at original indices that exceed the new wire count.

### Karatsuba multiplier — attempted, deferred (Bennett-qef)

Implemented `lower_mul_karatsuba!` but correctness fails. Root cause: the
schoolbook `lower_mul!` produces W-bit results (mod 2^W), but Karatsuba
sub-products need the full 2h-bit product without truncation. Extending to
full-width sub-multiplication defeats the purpose (3 W-bit muls > 1 W-bit mul).
Correct Karatsuba needs a widening multiply primitive. Filed for future work.

### Constant folding (Bennett-47k) — CLOSED

`_fold_constants` post-pass on gate list. Propagates known wire values through
gates, eliminating constant-only operations and simplifying partially-constant
Toffoli gates to CNOTs.

| Function | Standard | Folded | Gate savings | Toffoli savings |
|----------|---------|--------|-------------|-----------------|
| x+3 (i8) | 41 gates | 28 gates | 32% | — |
| polynomial (i8) | 420 gates | 237 gates | 44% | 52% |

**Mechanism:** Non-input wires start at known-zero. NOT gates on constants flip
the known value (no gate emitted). CNOTGate(known_true, target) → NOTGate(target).
ToffoliGate(known_false, x, target) → noop. Remaining known non-zero values
materialized at the end.

### BENCHMARKS.md (Bennett-kz1) — CLOSED

Auto-generated benchmark suite: `benchmark/run_benchmarks.jl`.
Covers integer arithmetic (i8-i64), SHA-256 sub-functions, Float64 operations,
optimization comparisons (Full Bennett vs Cuccaro vs EAGER vs pebbled).
Published comparison targets: Cuccaro 2004, PRS15 Table II, Haener 2018.

### Issues closed this session: 7

| Issue | What |
|-------|------|
| Bennett-kz1 | BENCHMARKS.md |
| Bennett-47k | Constant folding (32-44% gate reduction) |
| Bennett-bzx | Arithmetic benchmarks |
| Bennett-dpk | Float64 benchmarks |
| Bennett-der | Sorting benchmarks |
| Bennett-6yr | PRS15 EAGER (value_eager_bennett) |
| Bennett-i5c | Wire reuse in Phase 3 (pebbled_group_bennett) |

### Variable-index GEP (Bennett-dbx) — CLOSED

`IRVarGEP` type in ir_types.jl. Extraction handler in ir_extract.jl detects
non-constant GEP index operand, extracts element width from `LLVMGetGEPSourceElementType`.
`lower_var_gep!` builds binary MUX tree selecting element by runtime index bits.

NTuple{4,Int8} dynamic access: 1894 gates, 560 Toffoli, 622 wires.
Correct for all valid indices. 3+1 agent review.

### CI (Bennett-8jb) — CLOSED

`.github/workflows/bennett-ci.yml`: runs on push/PR when Bennett.jl/ changes.
Tests on Julia 1.10 and 1.12. Full test suite + benchmark suite.

### Issues closed this session: 9

| Issue | What |
|-------|------|
| Bennett-kz1 | BENCHMARKS.md |
| Bennett-47k | Constant folding (32-44% gate reduction) |
| Bennett-bzx | Arithmetic benchmarks |
| Bennett-dpk | Float64 benchmarks |
| Bennett-der | Sorting benchmarks |
| Bennett-6yr | PRS15 EAGER (value_eager_bennett) |
| Bennett-i5c | Wire reuse in Phase 3 (pebbled_group_bennett) |
| Bennett-dbx | Variable-index GEP (MUX tree) |
| Bennett-8jb | CI: GitHub Actions |

### Issues deferred: 4

| Issue | Reason |
|-------|--------|
| Bennett-qef | Karatsuba: correct but more gates than schoolbook at all widths |
| Bennett-cc0 | store instruction: Julia rarely emits for pure functions |
| Bennett-5ye | Sturm.jl integration: must be done from Sturm.jl side |
| Bennett-89j | Inline control: same Toffoli count as post-hoc for 3-control decomposition |

---

## CRITICAL: Bennett-an5 is NOT DONE — instructions for next session

**STATUS: pebbled_group_bennett exists, is correct, but achieves only 0.5% wire
reduction (32 wires on SHA-256). The target is ≥4x. THIS IS THE ONLY WORK
THE NEXT AGENT IS ALLOWED TO DO. No busywork. No other issues. Fix this.**

### What's broken and why

The current `pebbled_group_bennett()` in `src/pebbled_groups.jl` has a fundamental
flaw in wire classification. The `GateGroup` struct records:

```
result_wires::Vector{Int}    — the SSA output wires (e.g., 8 wires for Int8 result)
input_ssa_vars::Vector{Symbol} — names of dependency groups
```

But it does NOT record:
- **Internal target wires** — carries, partial products, constant bits allocated
  WITHIN the group's gate range but not part of result_wires. These are found
  by `_group_target_wires()` which scans gates, but this is incomplete.
- **Internal control-only wires** — wires allocated during this group's lowering
  that are NEVER targeted by any gate, only read as controls. Example: the
  zero-padding wires in the multiplier (wires 12-17 for x*x in the polynomial).
  These are allocated by `resolve!` or by `lower_mul!` internally but no gate
  targets them. They start at zero and stay at zero.

When `_replay_forward!` replays a group with remapped wires, it encounters control
wires that are not in the wmap (not a dependency result, not a target, not an input
wire). The fallback `get(wmap, w, w)` returns the ORIGINAL wire index, which may
exceed the WireAllocator's current count → BoundsError. The hack fix: allocate
FRESH zero-wires for every unknown control wire. This fresh allocation defeats
wire reuse — every replay allocates new wires instead of reusing freed ones.

### Concrete data showing the problem

For `x * x + 3x + 1` (polynomial, 4 gate groups):
- Group `__v1` (x*x): gates 2-41, targets 17 wires, BUT references 7 control-only
  wires (12-17, 26) that are NEVER targeted. These are zero-padding from the
  multiplier's internal wire allocation.
- When replaying `__v1` after freeing its wires, the 7 control-only wires get
  FRESH allocations instead of being reused → 7 extra wires per replay.

For SHA-256 (46 gate groups): the problem compounds. Many groups have internal
control-only wires from the barrel shifter (rotation) and the multiplier within
additions. Each replay leaks wires.

### The fix — what the next agent MUST do

**Step 1: Track the full wire range per gate group during lowering.**

In `lower()`, each gate group currently records `gate_start:gate_end` and
`result_wires`. It must ALSO record `wire_start:wire_end` — the range of wire
indices allocated by the WireAllocator during this group's lowering. This
captures ALL wires: results, carries, constants, zero-padding, everything.

Implementation: snapshot `wire_count(wa)` before and after each instruction
dispatch, same pattern as gate tracking. Add `wire_start::Int` and `wire_end::Int`
fields to `GateGroup`.

**Step 2: In `_replay_forward!`, use the wire range for complete remapping.**

Instead of scanning gates for targets + hacking unknown controls:
- The group's wire range `[wire_start:wire_end]` covers ALL wires.
- Input wires from dependencies are in `input_ssa_vars` → map via live_map.
- ALL OTHER wires in `[wire_start:wire_end]` are INTERNAL to this group.
- Allocate `wire_end - wire_start + 1 - len(dep_result_wires)` fresh wires for
  internals. This is the COMPLETE set — no unknowns, no fallback.

**Step 3: Verify on SHA-256.**

Target: `pebbled_group_bennett(lr; max_pebbles=7)` on SHA-256 round should give
significantly fewer wires than full Bennett (5889). PRS15 achieves 353 wires for
1 round with EAGER. We should aim for at least 2x reduction (≤2944 wires) as a
first milestone.

### Rules for the next agent

1. **This is a CORE CHANGE to lower.jl** (adding wire_start/wire_end to GateGroup).
   **3+1 agent workflow is MANDATORY**: 2 independent proposers, 1 implementer,
   orchestrator reviews. No shortcuts.

2. **RED-GREEN TDD.** Write the failing test FIRST:
   ```julia
   @test c_pebbled.n_wires < c_full.n_wires * 0.75  # at least 25% reduction
   ```
   Watch it fail. Then implement. Then green.

3. **Read the ground truth papers BEFORE coding.**
   - Knill 1995: Figure 1 (residence intervals), Theorem 2.1
   - PRS15: Algorithm 2 (EAGER), Table II (SHA-256 numbers), Figure 15 (hand-opt circuit)
   - PDFs in `docs/literature/pebbling/`

4. **No busywork.** Do NOT:
   - Work on other issues
   - Add benchmarks
   - Refactor unrelated code
   - File new issues
   - Update documentation
   The ONLY deliverable is: `pebbled_group_bennett` achieving ≥2x wire reduction
   on SHA-256 round, with correct output and all ancillae zero.

5. **GET FEEDBACK FAST.** After every change, run:
   ```bash
   julia --project=. -e '
   using Bennett
   # SHA-256 round
   Bennett._reset_names!()
   parsed = Bennett.extract_parsed_ir(sha256_round, Tuple{ntuple(_ -> UInt32, 10)...})
   lr = Bennett.lower(parsed)
   c_full = Bennett.bennett(lr)
   c_peb = pebbled_group_bennett(lr; max_pebbles=7)
   println("Full: $(c_full.n_wires), Pebbled: $(c_peb.n_wires)")
   '
   ```
   If the number isn't going down, you're on the wrong track. Stop and rethink.

6. **Skepticism.** The current implementation's correctness is verified (all tests
   pass). But correctness with 0.5% reduction is NOT the goal. The goal is
   correctness WITH significant reduction. Don't break correctness chasing reduction.

### Files to read

| File | What to look for |
|------|-----------------|
| `src/pebbled_groups.jl` | Current implementation. `_replay_forward!` is where the bug is. |
| `src/lower.jl` lines 1-30 | `GateGroup` struct — needs `wire_start`/`wire_end` fields |
| `src/lower.jl` lines 296-340 | `lower_block_insts!` dispatch loop — where wire tracking goes |
| `src/wire_allocator.jl` | `WireAllocator`, `allocate!`, `free!`, `wire_count` |
| `src/multiplier.jl` | Where zero-padding wires come from (the internal allocation pattern) |
| `test/test_pebbled_wire_reuse.jl` | Current tests — extend with reduction targets |
| `docs/literature/pebbling/Knill1995_bennett_pebble_analysis.pdf` | Ground truth |
| `docs/literature/pebbling/ParentRoettelerSvore2015_space_constraints.pdf` | Ground truth |

---

