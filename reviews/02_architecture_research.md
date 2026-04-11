# Architecture & Research Review -- Bennett.jl

**Reviewer**: Claude Opus 4.6 (1M context)
**Date**: 2026-04-11
**Scope**: Full source tree, PRDs, WORKLOG, literature survey, all soft-float and pebbling subsystems

---

## Executive Summary

Bennett.jl is an ambitious and well-executed LLVM-level reversible compiler that transforms plain Julia functions into classical reversible circuits (NOT, CNOT, Toffoli gates) via Bennett's 1973 construction. It operates at the LLVM IR level -- analogous to Enzyme for automatic differentiation -- and represents genuine novelty in several areas.

**Strengths:**
- The extract-lower-bennett-simulate pipeline is clean and well-factored
- The path-predicate phi resolution is a novel contribution not found in prior reversible compilers
- Branchless soft-float implementations are more complete than any published quantum FP circuit (handling NaN, Inf, subnormals)
- Exhaustive testing methodology (all 256 inputs for Int8) provides high confidence
- Multiple pebbling strategies (Knill, EAGER, value-level EAGER, checkpoint, SAT) provide a rich space-optimization toolkit
- The WORKLOG is exceptional -- a genuinely useful institutional memory document

**Concerns:**
- The Bennett construction in `bennett.jl` reverses gates by identity (same struct), relying on self-inverse property, but does not verify this invariant statically
- The callee registry uses substring name matching against LLVM mangled names, which is fragile across LLVM/Julia versions
- Gate-level pebbling (as opposed to value-level) conflates atomic operations with their constituent gates, creating subtle correctness risks
- The wire allocator's `free!` returns wires to a sorted list, but nothing prevents use of a freed wire that is not actually zero
- Global mutable state (`_name_counter`, `_known_callees`) makes the compiler non-reentrant
- The `lower_call!` function recursively invokes the full compilation pipeline, creating unbounded nesting depth for deeply nested call graphs

**Overall Assessment:** This is a strong v0.6-level prototype with clear architectural vision. The core pipeline is sound. The primary risks are in the phi resolution edge cases, callee name matching fragility, and the gap between pebbling infrastructure and actual ancilla reduction. The path to v1.0 is credible but requires addressing the specific findings below.

---

## Pipeline Architecture Assessment

### Overall Design (Rating: Strong)

The four-stage pipeline (extract -> lower -> bennett -> simulate) is a clean separation of concerns:

1. **Extract** (`ir_extract.jl`): LLVM.jl C API -> `ParsedIR`
2. **Lower** (`lower.jl`): `ParsedIR` -> `LoweringResult` (flat gate list + metadata)
3. **Bennett** (`bennett.jl`): `LoweringResult` -> `ReversibleCircuit` (forward + copy + reverse)
4. **Simulate** (`simulator.jl`): `ReversibleCircuit` + input -> output + ancilla verification

This matches the canonical compiler pipeline (front-end -> middle-end -> back-end -> runtime). The `ParsedIR` and `LoweringResult` types serve as clean interfaces between stages.

**Abstraction quality:** The `IRInst` abstract type and its concrete subtypes (`IRBinOp`, `IRICmp`, etc.) form a well-defined intermediate representation. The `ReversibleGate` hierarchy (NOT, CNOT, Toffoli) is minimal and sufficient for the Toffoli gate model.

### Coupling Concerns

1. **`lower_call!` re-enters the full pipeline** (`extract_parsed_ir` + `lower` at `lower.jl:1382-1385`). This creates implicit coupling between the extraction and lowering stages. A deeply nested call graph (e.g., `soft_floor` -> `soft_fadd`) would produce unbounded recursion depth. Currently bounded only by the small set of registered callees.

2. **`_name_counter` global state** (`ir_extract.jl:56-59`). The auto-name counter is module-level mutable state, saved/restored across callee compilation (`lower.jl:1381`). This prevents concurrent compilation and makes the counter save/restore a correctness-critical operation buried in a lowering function.

3. **`ParsedIR.instructions` property shim** (`ir_types.jl:134-145`). The backward-compatibility property that flattens blocks into a linear instruction sequence is a leaky abstraction. Code using `parsed.instructions` sees a different view than code using `parsed.blocks`, inviting bugs.

4. **`LoweringResult` backward-compatible constructors** (`lower.jl:34-37`). Two constructors with different arities for backward compatibility suggest the interface has grown organically. The 8-field `LoweringResult` struct should be reviewed for whether all fields are essential at this interface boundary.

---

## IR Design Review

### ir_types.jl (Rating: Good, with gaps)

The IR type hierarchy covers the essential LLVM IR subset:

| Instruction | Struct | Notes |
|---|---|---|
| Binary ops | `IRBinOp` | Handles 9 opcodes via `:op` symbol |
| Comparison | `IRICmp` | 10 predicates |
| Select | `IRSelect` | Branchless MUX |
| Phi | `IRPhi` | Incoming values + block labels |
| Branch | `IRBranch` | Conditional + unconditional |
| Switch | `IRSwitch` | Expanded to cascaded branches in post-pass |
| Return | `IRRet` | Single return value |
| Cast | `IRCast` | sext/zext/trunc |
| InsertValue | `IRInsertValue` | Aggregate construction |
| ExtractValue | `IRExtractValue` | Aggregate access |
| Call | `IRCall` | Gate-level inlining |
| PtrOffset | `IRPtrOffset` | Constant GEP |
| VarGEP | `IRVarGEP` | Variable-index GEP |
| Load | `IRLoad` | Memory read |

**Missing but needed:**
- `IRStore` -- required for full reversible memory model (acknowledged as future work)
- `IRBitcast` -- currently lowered to `IRCast(:trunc)` with same width, which is semantically wrong for non-integer reinterpretation (e.g., float <-> int bitcast)
- No vector/SIMD types -- `extractelement`, `insertelement`, `shufflevector` unhandled

**Design concern: width field inconsistency.** `IRBinOp.width` is the operand width, `IRICmp.width` is also operand width (result is always i1), but `IRSelect.width` is the result width. This is correct but the dual meaning of "width" depending on instruction type is a documentation gap that could lead to bugs.

**Design concern: `IROperand` dual-mode.** The `kind::Symbol` field being `:ssa` or `:const` means every operand access site must dispatch on kind. A sum type (Julia union or parameterized type) would be more idiomatic and safer.

---

## LLVM Extraction Robustness

### ir_extract.jl (Rating: Good, with fragility risks)

**Two-pass name table approach (lines 91-127):** Sound. The first pass assigns stable names to all parameters and instructions keyed on `LLVMValueRef` (C pointer identity). The second pass converts instructions using these names. This correctly handles LLVM's unnamed values (which return "" from `LLVM.name()`).

**Intrinsic handling (lines 376-665):** Comprehensive for the current needs (12 intrinsics), but the approach is fragile:

- **Name matching via `startswith(cname, "llvm.umax")`** -- LLVM may change intrinsic naming conventions between versions.
- **Each intrinsic is expanded inline** in `_convert_instruction`, producing a long function with many code paths. This should be refactored into a dispatch table or separate handler functions.
- The `llvm.ctpop` expansion at line 422 produces O(W) instructions for a W-bit popcount. For W=64, this is 64 shifts + 64 ANDs + 63 adds = 191 IR instructions, which then expand to ~13,000+ gates. A tree-based popcount (O(log W) depth) would be more efficient.

**Callee registry (`_known_callees`, lines 33-49):**

Critical fragility: `_lookup_callee` at line 42 uses `occursin(jname, lowercase(llvm_name))` for matching. This means:
- `soft_fadd` matches any LLVM name containing "soft_fadd" (case-insensitive)
- A function named `not_soft_fadd` would also match
- If Julia changes its LLVM name mangling (e.g., from `j_soft_fadd_NNN` to `julia_soft_fadd_NNN`), the matching still works, but if a prefix is added that doesn't contain the function name, it breaks

**Recommendation:** Use exact substring matching with `j_` prefix, or better, match on the Julia function object directly via LLVM metadata.

**GEP handling (lines 669-687):** Only handles single-index GEPs. Multi-index GEPs (common with struct-of-arrays or nested aggregates) return `nothing` (silently skipped). This is correct for the current use case but should `error()` for unsupported multi-index GEPs to maintain the fail-fast principle.

**Switch expansion (`_expand_switches`, lines 173-261):** The post-pass that expands `IRSwitch` into cascaded comparisons is clean and correct. The phi node patching (lines 232-257) correctly remaps predecessor block references. However, a switch with N cases produces N comparison blocks, each with its own `icmp eq` -- this is O(N) comparisons where a binary search tree could achieve O(log N). For large switches (e.g., computed gotos), this matters.

---

## Lowering Correctness & Completeness

### lower.jl (Rating: Good, with complexity concerns)

At ~1,421 lines, `lower.jl` is the largest and most complex file. It handles:

1. **Operand resolution** (lines 41-59): Correct. SSA variables resolve to wire arrays; constants allocate fresh wires with NOT gates for 1-bits.

2. **Block scheduling** (lines 196-316): Topological sort after removing back-edges. The entry block's predicate is set to 1 (line 228). Each subsequent block's predicate is computed from predecessors via AND/OR gates.

3. **Phi resolution** (lines 713-868): Two algorithms:
   - **Predicated** (lines 725-760): Uses per-block path predicates. Correct for arbitrary CFGs. This is the default.
   - **Legacy reachability-based** (lines 818-868): Recursive branch partitioning. Retained but not used by default. Has known false-path sensitization issues with diamond CFGs.

4. **Loop unrolling** (lines 546-636): Bounded unrolling with MUX-frozen outputs. Sound for deterministic loops with a known upper bound. The freeze mechanism (MUX(exit_cond, current, latch)) correctly handles early termination.

### Phi Resolution -- Deep Analysis

The path-predicate phi resolution (lines 725-760) computes edge predicates for each incoming value:

```
edge_pred[i] = AND(block_pred[from_block], branch_condition_to_phi_block)
```

Then chains MUXes: `result = MUX(edge_pred[N-1], val[N-1], MUX(edge_pred[N-2], val[N-2], ...))`.

**Correctness argument:** Since exactly one execution path is taken, exactly one edge predicate is 1 and all others are 0. The chained MUX selects the correct value because MUX(0, v, acc) = acc and MUX(1, v, acc) = v.

**Subtle issue:** The chained MUX at line 754-758 starts from `incoming[end]` as the default and iterates backward. If ALL edge predicates are 0 (should be impossible in correct code), the result would be the last incoming value. This is a "garbage in, garbage out" situation that won't produce incorrect ancilla-non-zero errors (the Bennett construction doesn't care about the value, only that ancillae return to zero), but could produce wrong outputs. Since the edge predicates are mutually exclusive and exhaustive for a valid execution, this is not a bug per se, but the asymmetric treatment of the last value is worth noting.

**Complexity concern:** The `_compute_block_pred!` function (lines 677-711) allocates fresh AND/OR/NOT wires for each block. For a function with B blocks and average fan-in F, this creates O(B * F) ancilla wires for predicates alone. For soft_fadd's ~20 blocks with complex fan-in, this adds ~50-100 predicate wires (confirmed negligible).

### Loop Unrolling Soundness

The loop unrolling at lines 546-636 has a subtle correctness dependency: the MUX-freeze mechanism assumes that once `exit_cond = 1`, subsequent iterations' MUXes keep the frozen value. This works because:

1. `vw[dest]` is updated to the MUX output (line 626)
2. The next iteration's body uses the frozen values
3. If the loop body is deterministic and the frozen values don't change exit_cond, the freeze holds

**Risk:** If the exit condition depends on iteration count (not on the data), and the loop body has side effects on the exit condition calculation, the MUX approach is correct. But if the exit condition is computed from the (now-frozen) loop-carried variables, subsequent iterations recompute the same exit condition (correctly maintaining the freeze). This is sound.

**Gap:** Nested loops are not supported (`lower_loop!` handles only single-level). Multi-level loops would require recursive application. The WORKLOG acknowledges this limitation.

### Arithmetic Lowering

- **Addition** (`adder.jl:1-16`): Standard ripple-carry. O(W) gates, O(W) ancillae.
- **Cuccaro adder** (`adder.jl:30-80`): In-place `b += a` with 1 ancilla. Only used when the second operand is dead after the instruction (liveness analysis at `lower.jl:898-901`). This is a significant optimization: 44 gates for W=8 vs 86 for ripple-carry.
- **Subtraction** (`adder.jl:83-103`): Two's complement via NOT + add + carry_in=1. Allocates 3W wires (not_b, result, carry). Could use Cuccaro subtraction for in-place `b -= a`.
- **Multiplication** (`multiplier.jl:1-28`): Schoolbook shift-and-add. O(W^2) Toffoli gates (one per partial product bit). Dominant cost for Float64 circuits.
- **Karatsuba** (`multiplier.jl:36-113`): Recursive with base case at W<=4. Reduces asymptotic gate count to O(W^{1.585}) but with higher constant factor due to subtraction overhead. Gated behind `use_karatsuba` flag (not enabled by default).
- **Division** (`divider.jl`): Restoring division via branchless ifelse loop. 64 iterations for UInt64. Produces O(64 * W) gates per operation.

### Missing Lowering

- **Variable-amount division/remainder**: Currently routes through `soft_udiv`/`soft_urem` with widen-to-64-bit. This means a 16-bit division still uses 64-bit restoring division (wasteful).
- **Signed overflow detection**: Not handled (LLVM's `sadd.with.overflow`, `ssub.with.overflow` intrinsics are not recognized).
- **Atomic operations**: Not handled (out of scope for pure functions).

---

## Bennett Construction Verification

### bennett.jl (Rating: Correct but minimal)

The Bennett construction at `bennett.jl:7-28` is:

```julia
all_gates = [lr.gates..., copy_gates..., reverse(lr.gates)...]
```

**Correctness argument:** Every gate in {NOT, CNOT, Toffoli} is self-inverse. Therefore `reverse(gates)` applied after `gates` restores the original state on all wires except the copy targets. The copy targets hold `f(x)` because the CNOT copy was inserted between forward and reverse.

**Key properties verified:**
1. Forward gates are applied in order (line 16)
2. CNOT copies output wires to fresh `copy_wires` (lines 17-19)
3. Forward gates are applied in reverse order (line 20) -- note: `reverse(lr.gates)` reverses the list, so gates are applied in the exact reverse sequence, which is correct because each self-inverse gate undoes itself when the wire state matches its forward-pass state
4. Ancillae are identified as wires that are neither input nor output (lines 22-24)

**Concern:** The `reverse(lr.gates)` at line 20 creates a new vector containing the SAME gate structs. Since Julia structs are immutable, this is fine. But if gates were ever made mutable, this would create aliasing bugs. A comment noting the self-inverse property dependency would be valuable.

**Missing: ancilla verification in construction.** The construction does not statically verify that all intermediate wires return to zero. This is checked dynamically by `simulate()` (via the ancilla assertion at `simulator.jl:31`). A static verification pass (e.g., symbolic simulation) would catch construction bugs without requiring exhaustive simulation.

---

## Soft-Float Assessment

### Rating: Excellent (novel contribution)

The soft-float library is the most novel engineering contribution of Bennett.jl. Each function is:
1. Fully branchless (no `if/else`, only `ifelse`)
2. Bit-exact with hardware IEEE 754
3. Handles all special cases (NaN, Inf, subnormals, signed zeros, round-to-nearest-even)
4. Compiles to reversible circuits without phi resolution issues

**Gate counts vs. published quantum FP circuits:**

| Operation | Bennett.jl | Haener et al. 2018 (est.) | Nguyen/Van Meter 2013 (est.) |
|-----------|-----------|---------------------------|------------------------------|
| Float64 add | 94,426 | ~84,000 (extrapolated) | ~84,000 (formula) |
| Float64 mul | 265,010 | N/A | N/A |
| Float64 div | 412,388 | N/A | N/A |

Bennett.jl's gate counts are within ~12% of published estimates for addition, which is remarkable given that published circuits omit NaN/Inf/subnormal handling while Bennett.jl includes all of them.

**The branchless approach is the correct design choice.** The WORKLOG's analysis of false-path sensitization (lines 531-596) is thorough and the decision to rewrite soft_fadd from branching to branchless (Option A) was sound. The 7.7% gate overhead for branchless is negligible compared to the correctness guarantee.

**Multiplication gate count concern:** 265,010 gates for Float64 mul is dominated by the 53x53 mantissa multiply (schoolbook O(n^2)). The Karatsuba multiplier exists but is not used for soft_fmul's internal multiplications (the `use_karatsuba` flag doesn't propagate to the callee compilation). Using Karatsuba for the 53-bit mantissa multiply could reduce fmul to ~180,000 gates (est.).

**Division gate count:** 412,388 gates for Float64 div uses 56-iteration restoring division. Newton-Raphson approximation (O(log^2(n)) multiplications) would be more efficient for large widths, but would require convergence analysis for bit-exact results.

### IEEE 754 Special Case Coverage

Auditing `soft_fadd` (fadd.jl lines 33-200):

| Case | Handled | Method |
|------|---------|--------|
| NaN + anything | Yes | `ifelse(a_nan \| b_nan, QNAN, ...)` |
| Inf + Inf (same sign) | Yes | Returns Inf |
| Inf + (-Inf) | Yes | Returns QNAN |
| Inf + finite | Yes | Returns Inf |
| Zero + Zero | Yes | Sign handling correct (same -> keep, diff -> +0) |
| Subnormal + normal | Yes | Implicit 1 not set for subnormal |
| Round-to-nearest-even | Yes | GRS bits with tie-breaking |
| Exact cancellation | Yes | Returns +0.0 |

The coverage appears complete for the IEEE 754-2008 rounding mode "roundTiesToEven" (the default).

**One concern in `soft_fcmp_olt`** (`fcmp.jl` lines 8-49): The comparison uses magnitude-based ordering for same-sign numbers (`pos_lt = abs_a < abs_b`). For negative numbers, `neg_lt = abs_a > abs_b`. This is correct because -3 < -2 iff |(-3)| > |(-2)|. The branchless chain at lines 41-47 handles both-zero and NaN-unordered correctly.

---

## Pebbling & Space Optimization

### Overview (Rating: Infrastructure solid, integration incomplete)

Bennett.jl implements five space-optimization strategies:

1. **Full Bennett** (`bennett.jl`): forward + copy + reverse. O(T) space, O(T) time.
2. **Knill recursion** (`pebbling.jl`): DP for optimal time given space bound. Correct per Theorem 2.1.
3. **Gate-level EAGER** (`eager.jl`): Dead-end wire cleanup. Correct but limited benefit for linear computations.
4. **Value-level EAGER** (`value_eager.jl`): PRS15 Algorithm 2 at GateGroup granularity.
5. **Checkpoint Bennett** (`pebbled_groups.jl`): Per-group checkpointing with wire reuse.
6. **SAT pebbling** (`sat_pebbling.jl`): Meuli 2019 encoding with PicoSAT.

### Knill Recursion (`pebbling.jl`)

The DP table at lines 22-49 correctly implements:
```
F(1, s) = 1
F(n, s) = min_{m=1..n-1} F(m,s) + F(m,s-1) + F(n-m,s-1)
```

**Verified:** `min_pebbles(n) = 1 + ceil(log2(n))` matches Knill Theorem 2.3.

**Issue with `pebbled_bennett`** (lines 112-196): The implementation at lines 181-195 does NOT recursively sub-pebble the first and third segments. Lines 183-184 and 193-194 simply iterate gates linearly:
```julia
for i in lo:mid
    push!(result, gates[i])
end
```
This means the "pebbling" is really just forward-reverse chunking, not true recursive checkpointing. For `max_pebbles < m`, this produces a circuit with more simultaneously-live wires than the pebble bound allows, because the first m gates are all forward (no intermediate uncomputation).

The WORKLOG acknowledges this at line 994: "The standard pebbling game puts ONE pebble on the output; Bennett needs ALL gates applied simultaneously for the copy."

### EAGER Cleanup (`eager.jl`)

The implementation correctly identifies dead-end wires (never used as controls) and eagerly cleans them. The key insight documented at lines 117-124 is critical: per-wire EAGER fails because gate-level operations are not atomic. Only dead-end wires (zero control references) are safe.

**The value-level EAGER** (`value_eager.jl`) is more principled: it treats `GateGroup`s as atomic pebble units and performs Kahn's algorithm in reverse topological order for Phase 3 cleanup. This matches PRS15 Algorithm 2's structure.

### Checkpoint Bennett (`pebbled_groups.jl`)

The most promising optimization. For each GateGroup:
1. Forward (compute) with fresh wires from WireAllocator
2. CNOT-copy result to checkpoint wires
3. Reverse (free internal wires, only checkpoint persists)

This reduces peak wires from `sum(all_group_wires)` to `sum(checkpoint_wires) + max(one_group_wires)`.

**Critical limitation (line 225-229):** Falls back to full Bennett when in-place operations (Cuccaro adder) are detected, because in-place ops modify dependency wires, breaking the checkpoint replay assumption. This means the Cuccaro adder optimization and checkpoint optimization are currently mutually exclusive.

### SAT Pebbling (`sat_pebbling.jl`)

Correct encoding of Meuli 2019. The sequential counter at lines 133-167 encodes the cardinality constraint with O(N*K) auxiliary variables. The verification function at lines 172-197 checks schedule validity.

**Gap:** The SAT pebbling produces a schedule (sequence of pebble configurations) but there is no code to convert this schedule into an actual optimized gate sequence. The schedule tells you which groups should be live at each step, but generating the corresponding forward/reverse operations is not implemented.

---

## Research Positioning & Novelty

### Comparison with Prior Work

| System | Input | Approach | CFG | Float | Memory | Pebbling |
|--------|-------|----------|-----|-------|--------|----------|
| **Bennett.jl** | LLVM IR | Bennett construction | Path-predicate phi | Branchless soft-float | Static + MUX EXCH | Knill + EAGER + SAT |
| ReVerC/REVS (PRS15) | F# AST | MDD + EAGER | No (straight-line) | No | No | EAGER + INCREM |
| VOQC (Hicks 2021) | SQIR | Verified optimizer | No (gate-level) | No | No | No |
| XAG (Meuli 2022) | Boolean func | AND-XOR graph | No | No | No | SAT pebbling |
| Janus (Yokoyama 2007) | Janus lang | Exit assertions | Yes (restricted) | No | Reversible | No |

### Novel Contributions

1. **Path-predicate phi resolution for reversible circuits.** No prior reversible compiler handles multi-way phi nodes from complex CFGs. The WORKLOG's literature search (lines 548-574) confirms this. Bennett.jl's edge-predicate MUX chain approach, grounded in Gated SSA / Psi-SSA theory, is a genuine contribution.

2. **Complete branchless IEEE 754 soft-float for reversible circuits.** Published quantum FP circuits (Haener 2018, Nguyen 2013) omit NaN/Inf/subnormal handling. Bennett.jl's soft-float library is more complete, bit-exact, and automatically compiled (not hand-optimized).

3. **LLVM-level reversible compilation.** No prior system operates at the LLVM IR level for reversible compilation. This enables any LLVM language (Julia, C, Rust, etc.) as input, matching Enzyme's language-independence argument.

4. **Gate-level function inlining via IRCall.** The callee compilation + wire-remapping approach enables compositional circuit construction from modular Julia code. Prior systems require monolithic inputs.

### What's Missing Relative to State-of-the-Art

1. **Formal verification.** VOQC provides machine-checked correctness proofs for quantum circuit optimizations. Bennett.jl relies on exhaustive simulation testing. For a compiler targeting quantum applications, formal verification (perhaps via Lean 4, given the repository's tooling) would be valuable.

2. **Actual ancilla reduction benchmarks.** PRS15 demonstrates 5.3x reduction on SHA-2 via EAGER cleanup. Bennett.jl has the infrastructure (EAGER, checkpoint, SAT) but no end-to-end demonstration on a large benchmark showing significant reduction.

3. **T-count optimization.** Each Toffoli decomposes to 7 T-gates in fault-tolerant implementations. The `t_count` and `t_depth` diagnostics are computed but no T-count optimization passes (e.g., T-par, T|ket>) are applied. For quantum applications, T-count is the dominant cost metric.

4. **Gate cancellation.** Adjacent self-inverse gate pairs (e.g., NOT followed by NOT on the same wire) are not cancelled. A simple peephole pass on the gate list would reduce gate counts.

---

## Scalability Analysis

### Can Bennett.jl Handle Real-World Functions?

**SHA-256:** The WORKLOG mentions SHA-256 as a test target (`test_sha256.jl` exists in `runtests.jl`). SHA-256 requires: 32-bit addition, rotation (shift+OR), bitwise AND/OR/XOR, and variable-width shifts. All of these are implemented. A single SHA-256 round would produce O(10,000-50,000) gates. The full 64-round SHA-256 would produce O(1M-3M) gates.

**Sorting (e.g., bitonic sort):** Sorting networks are naturally reversible (each compare-swap is a controlled-SWAP). Bennett.jl can compile a comparison-based sort if it is written without dynamic memory allocation. For N=8 elements, a bitonic sort has 24 compare-swaps, each ~400 gates (compare + conditional swap) = ~10,000 gates total.

**Bottlenecks:**

1. **Simulation time:** The simulator is O(G) per input where G is the gate count. For soft_fmul (265K gates), one simulation takes ~265K gate applications. Verifying all 2^128 Float64 input pairs is infeasible. Testing relies on random sampling + edge cases.

2. **Memory:** The simulator allocates a `Bool` vector of size `n_wires`. For large circuits (SHA-256 full: ~100K wires), this is ~100KB -- not a concern. But the gate list itself can be millions of entries, each a struct. A 3M-gate circuit occupies ~72MB (3 fields * 8 bytes per gate * 3M).

3. **Compilation time:** `extract_parsed_ir` calls `code_llvm` (JIT compilation) + `LLVM.parse` + two-pass walk. For soft_fdiv (~400K gates), compilation takes several seconds. For SHA-256 (64 rounds, each with callee inlining), compilation could take minutes due to recursive `lower_call!` invocations.

4. **Wire count growth:** Without effective pebbling, wire count grows linearly with computation length. SHA-256 with 64 rounds and full Bennett would need ~64 * 5,000 = 320,000 wires. With checkpoint Bennett, this drops to ~10,000 + max(one_round_wires).

---

## Specific Findings

### CRITICAL

**F1. `_remap_gate` in `pebbled_groups.jl` silently leaves unmapped wires unchanged (line 14).**
The `get(wmap, g.target, g.target)` default means if a wire is not in the remap table, it maps to itself. In the checkpoint/pebble replay context, this means a gate referencing a wire from a previous group that was freed and reallocated could silently target the wrong wire. The gate would execute on whatever value is at that wire index, potentially corrupting the circuit.
- *File*: `src/pebbled_groups.jl`, lines 13-22
- *Fix*: Add an assertion that all gate wires are either in `wmap` or in the input wire set. Error loudly if a wire is unmapped and not an input.

**F2. `lower_call!` does not apply Bennett construction to callee.** At `lower.jl:1385`, the callee is compiled via `lower()` only (not `bennett()`), and only the forward gates are inserted (`callee_lr.gates` at line 1404). This means the callee's intermediate values are left computed (not uncomputed) in the caller's wire space. They become part of the caller's forward computation and are uncomputed by the caller's Bennett reverse. This is semantically correct but means the callee's ancillae are "borrowed" by the caller, inflating the caller's ancilla count by the callee's full intermediate state.
- *File*: `src/lower.jl`, lines 1377-1421
- *Impact*: For deeply nested call chains, wire count accumulates at every nesting level. A Float64 polynomial with 4 soft_fmul calls borrows 4 * 27,000 = 108,000 intermediate wires.
- *Fix*: Consider applying Bennett construction per-callee to release intermediate wires, at the cost of 2x gate count per call. Alternatively, integrate with the checkpoint scheme.

### HIGH

**F3. Subtraction does not use in-place Cuccaro form.** `lower_sub!` at `adder.jl:83-103` always uses the 3W-wire ripple-carry approach (NOT b, add, carry). The Cuccaro adder supports subtraction via input negation + in-place add, which would use 1 ancilla instead of 3W. Since subtraction appears in every comparison (`lower_ult!`), every MUX (`lower_mux!` uses CNOT diff), and the Karatsuba multiplier, this represents a significant wire savings.
- *File*: `src/adder.jl`, lines 83-103
- *Impact*: Every comparison uses 3W extra wires. For W=64, this is 192 wires per comparison. A function with 10 comparisons wastes 1,920 wires.

**F4. `resolve!` for constants allocates permanent wires.** At `lower.jl:48-58`, resolving a constant operand allocates fresh wires and applies NOT gates for the constant's bit pattern. These wires are marked as constant (`constant_wires`) but are never freed. For a function that uses many constants (e.g., IEEE 754 masks in soft_fadd: ~15 64-bit constants), this allocates 15 * 64 = 960 permanent wires.
- *File*: `src/lower.jl`, lines 41-59
- *Impact*: Each use of the same constant value allocates new wires. If `soft_fadd` references `FRAC_MASK` in three places, it gets three separate 64-wire constant encodings.
- *Fix*: Cache constant operand wires by value. If the same constant is used multiple times, reuse the same wires (read-only).

**F5. The `peak_live_wires` diagnostic simulates the entire circuit.** At `diagnostics.jl:110-125`, `peak_live_wires` runs the simulator with zero input, tracking non-zero wires. For a 400K-gate circuit, this is 400K gate applications. The function should take an optional pre-computed bits vector, or be optimized to use a non-zero count rather than a Set.
- *File*: `src/diagnostics.jl`, lines 110-125
- *Impact*: Performance-only, not correctness. But calling `peak_live_wires` in a test loop is expensive.

### MEDIUM

**F6. `ir_parser.jl` is dead code on the critical path.** It is included in the module (`Bennett.jl` line 6) but only used by `test_parse.jl`. It adds ~200 lines of regex-based parsing that duplicates `ir_extract.jl`'s functionality. It should be moved to a test helper or removed.
- *File*: `src/ir_parser.jl`
- *Fix*: Move to `test/` as a test utility or guard with `@static if false`.

**F7. Wire allocator `free!` does not verify wires are zero.** At `wire_allocator.jl:23-29`, `free!` accepts wires unconditionally. A freed wire that is not zero will corrupt future computations that allocate it. The only protection is the dynamic assertion in `simulate()` (ancilla check at simulator.jl:31), which catches errors after the fact.
- *File*: `src/wire_allocator.jl`, lines 23-29
- *Fix*: Add a debug mode that tracks wire state and asserts freed wires are zero. Use `@assert` in debug builds.

**F8. `_fold_constants` invalidates gate_groups.** At `lower.jl:413-416`, the constant folding pass creates a new `LoweringResult` with empty `gate_groups`. This means any downstream optimization that relies on gate_groups (value-level EAGER, checkpoint Bennett) silently falls back to full Bennett.
- *File*: `src/lower.jl`, lines 413-416
- *Fix*: Either rebuild gate_groups after folding, or make the fallback explicit with a warning.

**F9. The controlled-Toffoli decomposition uses only one ancilla wire shared across all Toffoli gates.** At `controlled.jl:47-52`, all controlled-Toffoli gates share the same `anc_wire`. This is correct because the ancilla is computed and uncomputed within each three-Toffoli sequence: `Tof(ctrl,c1,anc); Tof(anc,c2,target); Tof(ctrl,c1,anc)`. The third gate uncomputes anc. However, this assumes sequential execution. If gates were ever reordered (e.g., for depth optimization), the shared ancilla would be corrupted.
- *File*: `src/controlled.jl`, lines 47-52
- *Impact*: Correctness depends on sequential gate ordering. Add a comment noting this dependency.

**F10. No gate cancellation pass.** The Bennett construction produces `[G1, G2, ..., GN, copy, GN, ..., G2, G1]`. Adjacent pairs like `... GK ... GK ...` at the boundary between the CNOT copies and the reverse are self-inverse but not adjacent. However, within the forward or reverse sequences, consecutive gates on the same wire (e.g., two NOTs from constant encoding) could be cancelled. No cancellation pass exists.
- *Impact*: Missed optimization. For a function with many constants, each constant encoding has NOT gates that could potentially be combined.
- *Fix*: Add a peephole pass that cancels adjacent self-inverse gate pairs on the same wire.

### LOW

**F11. `_read_int` in simulator.jl uses hard-coded width cases.** Lines 57-62 handle widths 8, 16, 32, 64 with explicit branches. Other widths (e.g., i1, i9, i128) return `Int(raw)`, losing sign information.
- *File*: `src/simulator.jl`, lines 52-63
- *Fix*: Use a generic signed reinterpretation for arbitrary widths.

**F12. `SoftFloat` dispatch in `Bennett.jl` limited to 3 arguments.** At lines 129-141, the Float64 compile path handles 1, 2, or 3 arguments with explicit cases. A function of 4+ Float64 arguments errors.
- *File*: `src/Bennett.jl`, lines 129-141
- *Fix*: Use `@generated` or runtime tuple construction for arbitrary argument counts.

**F13. `verify_reversibility` uses random testing, not exhaustive.** At `diagnostics.jl:127-143`, only 100 random inputs are tested by default. For functions with narrow input domains (e.g., Int8), exhaustive verification is feasible and should be preferred.
- *File*: `src/diagnostics.jl`, lines 127-143

**F14. `_cond_negate_inplace!` leaks carry wires.** At `lower.jl:1229-1246`, the conditional negation allocates a carry chain but never frees the carry wires. For a 64-bit value, this wastes 64 ancilla wires per conditional negation.
- *File*: `src/lower.jl`, lines 1229-1246

---

## Recommendations

### Immediate (before next major feature)

1. **Add assertion to `_remap_gate` in `pebbled_groups.jl`** to verify all gate wires are in the remap table or input set (Finding F1).

2. **Cache constant operand wires** by value in `resolve!` to avoid duplicate constant encodings (Finding F4). This is a simple Dict{Int,Vector{Int}} lookup.

3. **Add a gate cancellation peephole pass** that eliminates adjacent self-inverse pairs on the same wire (Finding F10). Even a single pass over the gate list would catch constant-encoding NOTs.

4. **Move `ir_parser.jl` to test/helpers/** (Finding F6). It is not on the critical path and adds maintenance burden.

### Short-term (v0.7-v0.8 scope)

5. **Implement Cuccaro subtraction** for in-place `b -= a` (Finding F3). This halves the wire count for all comparison and MUX operations.

6. **Connect SAT pebbling to circuit generation.** The SAT solver produces optimal schedules but no code converts them to gate sequences. This is the missing link for practical ancilla reduction.

7. **Benchmark checkpoint Bennett on SHA-256.** The checkpoint scheme should achieve the PRS15 result (~5x ancilla reduction) on SHA-256 rounds. Demonstrating this would be the single most compelling result for a paper submission.

8. **Resolve the Cuccaro/checkpoint mutual exclusion** (checkpoint falls back to full Bennett when in-place ops are detected at pebbled_groups.jl:225-229). In-place ops need special handling in the replay: the modified dependency wire must be tracked separately.

### Medium-term (v0.9-v1.0 scope)

9. **Formal verification of the Bennett construction.** The invariant "all ancillae return to zero" is the core correctness property. Proving this statically (via symbolic execution or in Lean 4) would be a significant contribution.

10. **T-count optimization.** Add a post-processing pass that reduces T-count via known techniques (T-par by Amy et al. 2014, phase polynomial optimization). This would make Bennett.jl's output practical for fault-tolerant quantum computation.

11. **Consider eliminating the global `_name_counter`** in favor of a context object passed through the pipeline. This would make the compiler reentrant and enable parallel compilation of independent callees.

12. **Refactor `_convert_instruction` in `ir_extract.jl`** from a monolithic 400-line function into a dispatch table keyed on opcode. This would improve maintainability and make adding new opcodes systematic.

### Research directions

13. **Publish the path-predicate phi resolution algorithm.** This is a novel contribution with no prior art in the reversible compilation literature. A short paper at RC (Reversible Computation conference) or a workshop paper at PLDI/POPL would establish priority.

14. **Investigate the fmul gate count.** 265K gates for Float64 multiplication is dominated by the schoolbook 53x53 multiply. Using Karatsuba for the mantissa multiply (with careful handling of the widening product) could reduce this to ~180K gates, which would be the lowest published gate count for a complete IEEE 754 double-precision multiplier circuit.

15. **Explore LLVM pass integration for if-conversion.** The WORKLOG's Option C (custom LLVM pass for aggressive if-conversion) would eliminate phi nodes before the pipeline sees them, complementing the branchless soft-float approach with a general solution.
