# Test Coverage Review -- Bennett.jl

**Reviewer**: Claude Opus 4.6 (1M context)
**Date**: 2026-04-11
**Scope**: All source files in `src/` and all test files in `test/`

---

## Executive Summary

Bennett.jl has **strong test coverage for its core compilation pipeline** -- the full compile-simulate-verify loop is tested for Int8 (exhaustive 256-input), Int16/32/64, branching, loops, tuples, soft-float, controlled circuits, and multiple optimization backends. The project follows its own discipline well: `verify_reversibility` is called in virtually every test, and Int8 tests are exhaustive as mandated.

**However, there are notable gaps:**

1. **No negative tests at all** -- no tests verify that unsupported instructions, invalid inputs, or error conditions produce clear error messages.
2. **Several exported functions have zero test coverage**: `soft_fcmp_ole`, `soft_fcmp_une` (only library-level, not circuit-level), `soft_fptosi` (only intrinsic test, not library-level), `soft_sitofp` (not tested anywhere), `soft_floor`/`soft_ceil`/`soft_trunc` (only tested via `test_float_intrinsics.jl` through SoftFloat dispatch, not library-level).
3. **Gate count regressions are not asserted** -- gate counts are printed but never compared against known baselines with `@test`.
4. **Wire allocator has no unit tests** -- allocation/freeing/reuse behavior is only tested implicitly.
5. **Soft-float edge cases (subnormals, overflow boundaries)** are tested for `fadd` and `fmul` but not systematically for `fdiv`, `fsub`, `fptosi`, `sitofp`, `fcmp_ole`, `fcmp_une`, `floor`, `ceil`, `trunc`.

---

## Coverage Matrix (source file -> test files)

| Source File | Test Files Covering It | Coverage Level |
|---|---|---|
| `src/Bennett.jl` (module, exports, `reversible_compile`, `SoftFloat`) | test_increment, test_polynomial, test_float_circuit, test_float_poly, test_float_intrinsics | GOOD -- all entry points exercised, Float64 dispatch tested |
| `src/ir_types.jl` (IR structs) | test_parse, all compilation tests | GOOD -- implicitly tested via every compile |
| `src/ir_extract.jl` (LLVM IR extraction) | All compilation tests, test_intrinsics, test_switch, test_ntuple_input, test_var_gep | GOOD -- extensively exercised through compilation |
| `src/ir_parser.jl` (legacy regex parser) | test_parse, test_branch | MODERATE -- basic parsing tested; not all instruction types covered by regex path |
| `src/gates.jl` (gate types, ReversibleCircuit) | Every test implicitly | GOOD -- data structure used everywhere |
| `src/wire_allocator.jl` (WireAllocator) | **NO UNIT TESTS** | LOW -- only implicitly tested via compilation |
| `src/adder.jl` (ripple-carry, Cuccaro) | test_increment, test_polynomial, test_liveness | GOOD -- Cuccaro in-place tested with wire count assertions |
| `src/multiplier.jl` (shift-and-add, Karatsuba) | test_polynomial, test_karatsuba | GOOD -- Karatsuba correctness + Toffoli count comparison |
| `src/divider.jl` (soft_udiv, soft_urem) | test_division | MODERATE -- tested but only for small input ranges |
| `src/lower.jl` (instruction lowering, phi resolution, loops) | test_increment through test_float_circuit, test_predicated_phi, test_liveness, test_division | GOOD -- most instruction handlers exercised |
| `src/bennett.jl` (Bennett construction) | Every test with `reversible_compile` | GOOD -- core invariant tested everywhere |
| `src/simulator.jl` (bit-vector simulator) | Every test with `simulate` | GOOD -- single/multi-arg, tuple output all covered |
| `src/diagnostics.jl` (gate_count, verify_reversibility, etc.) | test_eager_bennett, test_sha256, test_liveness, test_value_eager, test_pebbled_wire_reuse | MODERATE -- `gate_count`, `verify_reversibility`, `ancilla_count`, `depth`, `t_count`, `t_depth`, `peak_live_wires` all called; `constant_wire_count` **never tested** |
| `src/controlled.jl` (ControlledCircuit) | test_controlled, test_combined | GOOD -- increment, polynomial, two-arg, branching all controlled |
| `src/dep_dag.jl` (DepDAG extraction) | test_dep_dag | LOW -- only basic structural tests, no edge case or correctness verification |
| `src/pebbling.jl` (Knill recursion, pebbled_bennett) | test_pebbling | GOOD -- base cases, tradeoffs, correctness vs full Bennett |
| `src/eager.jl` (EAGER cleanup) | test_eager_bennett | GOOD -- correctness, peak liveness, gate counts |
| `src/value_eager.jl` (value-level EAGER, PRS15) | test_value_eager | GOOD -- gate groups, correctness, peak liveness, SHA-256, Cuccaro combo |
| `src/pebbled_groups.jl` (group-level pebbling) | test_pebbled_wire_reuse | GOOD -- increment, polynomial, SHA-256, wire reduction |
| `src/sat_pebbling.jl` (SAT-based pebbling) | test_sat_pebbling | MODERATE -- linear chain, diamond, chain(5), bad schedule rejection |
| `src/softfloat/fadd.jl` | test_softfloat (basic, edge, random, commutativity), test_float_circuit | EXCELLENT -- 10k random + edge cases + circuit compilation |
| `src/softfloat/fsub.jl` | test_softfsub | GOOD -- basic, edge, 10k random |
| `src/softfloat/fmul.jl` | test_softfmul | EXCELLENT -- basic, edge, subnormals, 10k random, commutativity |
| `src/softfloat/fdiv.jl` | test_softfdiv | GOOD -- basic, edge, 1k random |
| `src/softfloat/fneg.jl` | test_softfloat | GOOD -- basic cases including +/-0, Inf |
| `src/softfloat/fcmp.jl` | test_softfcmp | MODERATE -- olt and oeq tested; **ole and une not library-tested** |
| `src/softfloat/fptosi.jl` | test_intrinsics (fptosi) | LOW -- only through intrinsic test, no dedicated library test |
| `src/softfloat/sitofp.jl` | **NO TESTS** | NONE |
| `src/softfloat/fround.jl` | test_float_intrinsics (floor, trunc) | LOW -- tested only through SoftFloat dispatch, not library-level |

---

## Untested Exports and Functions

### Exported Functions with No or Minimal Tests

1. **`soft_sitofp`** (exported in `Bennett.jl` line 25, registered as callee line 57): **ZERO tests**. This function converts signed Int64 to Float64 bit pattern. No library test, no circuit test.

2. **`soft_fcmp_ole`** (exported line 25): Only tested via `test_intrinsics.jl` through Float64 `<=` dispatch. **No dedicated library-level test** in `test_softfcmp.jl`.

3. **`soft_fcmp_une`** (exported line 25): Only tested via `test_intrinsics.jl` through Float64 `!=` dispatch. **No dedicated library-level test** in `test_softfcmp.jl`.

4. **`soft_floor`** (registered callee line 59, dispatched via `SoftFloat`): Tested only through `test_float_intrinsics.jl` SoftFloat dispatch. **No library-level test** with raw UInt64 bit patterns.

5. **`soft_ceil`** (registered callee line 60, dispatched via `SoftFloat`): Tested only through `test_float_intrinsics.jl` (but `ceil` test is actually missing from test_float_intrinsics.jl -- only `floor` and `trunc` are there). **ZERO tests**.

6. **`soft_trunc`** (registered callee line 61, dispatched via `SoftFloat`): Tested only through `test_float_intrinsics.jl` SoftFloat dispatch. **No library-level test**.

7. **`constant_wire_count`** (exported line 27, defined in `diagnostics.jl` line 73-101): **ZERO tests**. Never called in any test file.

8. **`print_circuit`** (exported implicitly via `show`): Called in test output but never has its output verified.

### Internal Functions Never Tested Directly

9. **`WireAllocator`** (`wire_allocator.jl`): `allocate!`, `free!`, `wire_count` -- no unit tests.

10. **`_fold_constants`** (`lower.jl` lines 323-416): Tested via `test_constant_fold.jl` but only at the compile-and-verify level; the folding logic itself is not unit-tested.

11. **`extract_dep_dag`** (`dep_dag.jl`): Tested in `test_dep_dag.jl` but only for structural properties (node count > 0, output nodes exist). **No test verifies DAG correctness** (e.g., that predecessor/successor relationships match actual gate dependencies).

---

## Edge Case Analysis

### Int8 Exhaustive Testing (ALL 256 inputs)

The following tests verify all 256 Int8 inputs as mandated:
- test_increment.jl: `x + Int8(3)` -- YES, `typemin:typemax`
- test_polynomial.jl: `x*x + 3*x + 1` -- YES, `typemin:typemax`
- test_bitwise.jl: `(x & 0x0f) | (x >> 2)` -- YES, `typemin:typemax`
- test_compare.jl: `x > 10 ? x+1 : x+2` -- YES, `typemin:typemax`
- test_branch.jl: nested if/else, branch with computation -- YES, `typemin:typemax`
- test_predicated_phi.jl: simple if/else, diamond, three-way -- YES, `typemin:typemax`
- test_controlled.jl: controlled increment -- YES, `typemin:typemax`
- test_combined.jl: controlled nested-if, controlled compare+select -- YES, `typemin:typemax`
- test_intrinsics.jl: ctpop, ctlz, cttz, bitreverse -- YES, `typemin:typemax`

### Int8 Tests NOT Exhaustive (Partial coverage)

- **test_two_args.jl**: Only `Int8(0):Int8(15)` for x,y (256 of 65,536 possible pairs). **MEDIUM gap** -- should test more edge cases for two-arg functions.
- **test_loop.jl**: Only `Int8(0):Int8(63)`. **MEDIUM gap** -- negative values and edge cases not tested.
- **test_mixed_width.jl**: Only `Int8(0):Int8(15)` for sum_to. Reasonable for a closed-form.
- **test_division.jl**: `UInt8(0):UInt8(15)` for a and `UInt8(1):UInt8(15)` for b. Only 225 of 65,536 pairs. **HIGH gap** for a critical operation.
- **test_karatsuba.jl**: `Int8(-10):Int8(10)` for both args. Only 441 of 65,536 pairs. Missing overflow edge cases.

### Wider Types Edge Cases

- **Int16** (`test_int16.jl`): Tested `Int16(-50):Int16(50)` -- 101 values. Includes 0 but **NOT** `typemin`, `typemax`, or overflow boundaries.
- **Int32** (`test_int32.jl`): 1000 random + explicit `0, 1, -1, typemax, typemin`. **GOOD**.
- **Int64** (`test_int64.jl`): `0, 1, -1, 42, -42, typemax, typemin` + 500 random. **GOOD**.

### Gap: Int16 missing typemin/typemax

Int16 test (`test_int16.jl` line 5) tests only `Int16(-50):Int16(50)`. **Missing**: `typemin(Int16)=-32768`, `typemax(Int16)=32767`, and overflow boundary values like `32766, 32767, -32767, -32768`.

---

## Integration Test Assessment

Integration tests that exercise the full pipeline (compile -> simulate -> verify):

**All integration tests follow the pattern:**
```julia
circuit = reversible_compile(f, Type)
for x in inputs
    @test simulate(circuit, x) == f(x)
end
@test verify_reversibility(circuit)
```

This pattern is used in **every test file except** `test_parse.jl` (parsing only), `test_dep_dag.jl` (DAG extraction only), `test_liveness.jl` (liveness analysis + some compilation), and `test_sat_pebbling.jl` (SAT solver only).

**Verdict**: Integration test coverage is EXCELLENT. The full pipeline is tested for:
- Simple arithmetic (Int8 through Int64)
- Bitwise operations
- Comparisons and selects
- Multi-argument functions
- If/else branching (simple, nested, diamond, three-way)
- Loop unrolling (LLVM-auto and explicit bounded)
- Tuple returns
- Controlled circuits
- Soft-float (fadd, fmul, fdiv circuits)
- Float64 polynomial end-to-end
- SHA-256 round function
- Division/remainder
- NTuple input
- Dynamic array indexing (VarGEP)
- LLVM intrinsics (ctpop, ctlz, cttz, bitreverse, bswap, fneg, fabs, bitcast, fptosi, fcmp)

---

## Is verify_reversibility Called in Every Test?

**Analysis of all test files:**

| Test File | verify_reversibility Called? |
|---|---|
| test_parse.jl | NO -- parsing only, no circuit |
| test_increment.jl | YES |
| test_polynomial.jl | YES |
| test_bitwise.jl | YES |
| test_compare.jl | YES |
| test_two_args.jl | YES |
| test_controlled.jl | YES |
| test_branch.jl | YES |
| test_loop.jl | YES |
| test_combined.jl | YES |
| test_int16.jl | YES |
| test_int32.jl | YES |
| test_int64.jl | YES (but not for the scaling sub-test compilations -- lines 17-26 compile circuits without verify) |
| test_mixed_width.jl | YES (in sum_to testset; widen_mul is in try/catch) |
| test_loop_explicit.jl | YES |
| test_tuple.jl | YES |
| test_softfloat.jl | N/A -- library tests, no circuits |
| test_softfmul.jl | N/A -- library tests |
| test_softfsub.jl | N/A -- library tests |
| test_softfcmp.jl | N/A -- library tests |
| test_softfdiv.jl | N/A -- library tests |
| test_float_circuit.jl | YES |
| test_float_poly.jl | YES |
| test_predicated_phi.jl | YES |
| test_extractvalue.jl | YES |
| test_general_call.jl | YES |
| test_division.jl | YES |
| test_ntuple_input.jl | YES |
| test_ancilla_reuse.jl | YES |
| test_dep_dag.jl | NO -- DAG extraction only |
| test_pebbling.jl | YES |
| test_eager_bennett.jl | YES |
| test_switch.jl | YES |
| test_rev_memory.jl | YES |
| test_sat_pebbling.jl | N/A -- SAT solver tests |
| test_intrinsics.jl | YES |
| test_liveness.jl | YES |
| test_sha256.jl | YES |
| test_value_eager.jl | YES |
| test_pebbled_wire_reuse.jl | YES |
| test_constant_fold.jl | YES |
| test_var_gep.jl | YES |
| test_float_intrinsics.jl | YES |
| test_karatsuba.jl | YES |

**Minor gap in test_int64.jl**: The gate count scaling sub-test (lines 17-26) compiles four circuits (`inc8`, `inc16`, `inc32`, `inc64`) without calling `verify_reversibility` or `simulate` on them. These are only used for gate count printing.

**Verdict**: GOOD. Every circuit-producing test calls `verify_reversibility`.

---

## Missing Negative Tests

**There are ZERO negative tests in the entire test suite.** This is a significant gap. The following error conditions should be tested:

1. **Unsupported LLVM instruction**: Compile a function that uses an instruction the compiler does not handle (e.g., floating-point compare without SoftFloat, exception-throwing paths). Verify `error()` is thrown with a descriptive message.

2. **Loop without max_loop_iterations**: Call `reversible_compile(f, Int8)` on a function with a loop but without specifying `max_loop_iterations`. Should error with "Loop detected in LLVM IR but max_loop_iterations not specified" (lower.jl line 202).

3. **Undefined SSA variable**: Malformed IR with a reference to an undefined SSA name. Should error with "Undefined SSA variable" (lower.jl line 45).

4. **Float64 compile with too many args**: `reversible_compile(f, Float64, Float64, Float64, Float64)` should error with "Float64 compile supports up to 3 arguments" (Bennett.jl line 140).

5. **Float64 compile with zero args**: `reversible_compile(f)` with no types should error.

6. **Invalid ReversibleCircuit simulation**: `simulate` on a circuit with mismatched input count.

7. **Insufficient pebbles**: `pebbled_bennett` with `max_pebbles=1` and a multi-gate circuit should error with "Insufficient pebbles" (pebbling.jl line 173).

8. **Unknown binop**: IRBinOp with an unrecognized op symbol should error (lower.jl line 915).

9. **Unknown icmp predicate**: IRICmp with an unrecognized predicate should error (lower.jl line 1043).

---

## Gate Count Regression Gaps

**CRITICAL**: The CLAUDE.md (Principle 6) states "Verified gate counts are regression tests" and lists specific baselines:
- i8 addition = 86 gates
- i16 = 174 gates
- i32 = 350 gates
- i64 = 702 gates

**However, NO test file asserts these gate counts with `@test`.** Gate counts are printed in many tests (e.g., `test_int64.jl` line 22 prints a scaling table, `test_sha256.jl` prints detailed counts) but never verified against expected values.

The closest is `test_karatsuba.jl` line 32: `@test gc_karat.Toffoli < gc_school.Toffoli` -- but this is a relative comparison, not a baseline assertion.

**Recommendation**: Add explicit gate count regression tests:
```julia
@test gate_count(reversible_compile(x -> x + Int8(1), Int8)).total == 86
@test gate_count(reversible_compile(x -> x + Int16(1), Int16)).total == 174
@test gate_count(reversible_compile(x -> x + Int32(1), Int32)).total == 350
@test gate_count(reversible_compile(x -> x + Int64(1), Int64)).total == 702
```

---

## Specific Findings

### Finding 1: CRITICAL -- `soft_sitofp` is completely untested

**File**: `src/softfloat/sitofp.jl` (87 lines of complex branchless CLZ + rounding logic)
**Status**: Exported (Bennett.jl line 25), registered as callee (line 57), but zero test coverage -- no library test, no circuit test.
**Risk**: This function implements signed-integer-to-float conversion with manual CLZ, round-to-nearest-even, and mantissa overflow handling. Any bug here would silently produce wrong circuit outputs.
**Action**: Add a dedicated `test_soft_sitofp.jl` with:
  - Basic values: 0, 1, -1, 2, -2, 100, -100
  - Powers of 2: 2^k for k = 0..62
  - Rounding boundary: 2^53+1, 2^53-1 (where Int64 > 52-bit mantissa)
  - typemin(Int64), typemax(Int64)
  - 10k random Int64 values compared against `reinterpret(UInt64, Float64(reinterpret(Int64, x)))`

### Finding 2: HIGH -- `soft_ceil` has zero tests

**File**: `src/softfloat/fround.jl` lines 76-88
**Status**: Registered as callee (Bennett.jl line 60), dispatched via `SoftFloat` `Base.ceil`, but `test_float_intrinsics.jl` only tests `floor` and `trunc` -- `ceil` is absent.
**Action**: Add `ceil(Float64)` test in `test_float_intrinsics.jl` with cases like `(2.3, 3.0)`, `(-2.3, -2.0)`, `(3.0, 3.0)`, `(-0.5, -0.0)`.

### Finding 3: HIGH -- `soft_fptosi` has no library-level test

**File**: `src/softfloat/fptosi.jl` (57 lines)
**Status**: Tested only through `test_intrinsics.jl` via `unsafe_trunc(Int64, x)` compiled through Float64 dispatch. No direct library test with `soft_fptosi(bits)`.
**Risk**: The intrinsic test (13 values) does not cover edge cases: `typemax(Int64)` as float, subnormals, NaN, Inf, very large negatives, values just above/below integer boundaries.
**Action**: Add `test_soft_fptosi.jl` with comprehensive edge cases.

### Finding 4: HIGH -- `soft_fcmp_ole` and `soft_fcmp_une` lack library tests

**File**: `src/softfloat/fcmp.jl` lines 92-103
**Status**: `test_softfcmp.jl` only tests `olt` and `oeq`. `ole` and `une` are only tested through Float64 dispatch in `test_intrinsics.jl` with 6 and 5 test cases respectively.
**Risk**: Missing NaN behavior, subnormal comparisons, signed zero comparisons.
**Action**: Add `ole` and `une` testsets to `test_softfcmp.jl` with the same rigor as `olt`/`oeq`.

### Finding 5: HIGH -- No gate count regression assertions

**File**: All test files
**Status**: As detailed in the Gate Count Regression Gaps section above.
**Action**: Create `test_gate_count_regression.jl` or add `@test` assertions to existing files for the documented baselines.

### Finding 6: HIGH -- `constant_wire_count` is exported but never tested

**File**: `src/diagnostics.jl` lines 73-101
**Status**: Exported, contains non-trivial forward dataflow analysis logic, but zero test calls.
**Action**: Add tests verifying `constant_wire_count` for functions with known constant patterns (e.g., `x + 3` has constant wires from the literal 3).

### Finding 7: MEDIUM -- Wire allocator has no unit tests

**File**: `src/wire_allocator.jl` (31 lines)
**Status**: `WireAllocator`, `allocate!`, `free!`, `wire_count` are core infrastructure used throughout lowering and pebbling. No dedicated tests.
**Risk**: The `free!` function uses sorted-insert for a min-heap; incorrect freeing could cause wire collisions that corrupt circuit state. The Cuccaro in-place adder relies on correct wire reuse.
**Action**: Add unit tests:
  - Allocate N wires, verify sequential indices
  - Free wires and re-allocate, verify reuse (min index first)
  - Interleave allocate/free, verify no duplicates

### Finding 8: MEDIUM -- `dep_dag.jl` tests are purely structural

**File**: `test_dep_dag.jl` (29 lines)
**Status**: Tests only verify `length(dag.nodes) > 0` and `!isempty(dag.output_nodes)`. No test verifies that predecessor/successor relationships are correct.
**Action**: Add tests that verify specific DAG edges for a known simple circuit, e.g., for `x + 1`, verify that the carry gates depend on input wire gates.

### Finding 9: MEDIUM -- Division tested only on small ranges

**File**: `test_division.jl`
**Status**: `udiv` and `urem` test `UInt8(0):UInt8(15)` for a and `UInt8(1):UInt8(15)` for b (225 pairs out of 65,536). `sdiv` tests only 16 values for a and 6 for b (96 pairs). Missing:
  - Full `UInt8(0):UInt8(255)` exhaustive test (only 65k pairs)
  - Boundary cases: `div(255, 1)`, `div(255, 255)`, `div(128, 127)`
  - Division by 1 (identity)
  - `srem` is not tested at all (only sdiv)
**Action**: Test all 255*255 pairs for udiv/urem, add srem testset.

### Finding 10: MEDIUM -- `soft_fround.jl` functions lack dedicated library tests

**File**: `src/softfloat/fround.jl`
**Status**: `soft_trunc`, `soft_floor`, `soft_ceil` are complex branchless implementations. They are tested only through SoftFloat dispatch in `test_float_intrinsics.jl` with small test sets (4-7 values each). No random testing, no subnormal/Inf/NaN testing.
**Action**: Add `test_soft_fround.jl` with:
  - All three functions against `trunc(Float64)`, `floor(Float64)`, `ceil(Float64)`
  - Edge cases: 0.0, -0.0, Inf, -Inf, NaN, subnormals, very large integers (> 2^52)
  - Random 1000+ pairs

### Finding 11: MEDIUM -- Two-arg function tests have limited input space

**File**: `test_two_args.jl`
**Status**: Tests `x*y + x - y` for `Int8(0):Int8(15)` both args (256 of 65,536 possible pairs). Missing negative values entirely.
**Action**: At minimum add edge cases: `(typemin, typemin)`, `(typemin, typemax)`, `(typemax, typemin)`, `(typemax, typemax)`, `(-1, -1)`, `(0, 0)`, `(-128, 1)`.

### Finding 12: MEDIUM -- `test_loop.jl` misses negative inputs

**File**: `test_loop.jl`
**Status**: Tests `s(x)` (sum via loop) only for `Int8(0):Int8(63)`. The function `s(x)` computes `4*x` (loop adds x four times), which should work for negative values too. Loop unrolling correctness for negative inputs is untested.
**Action**: Extend to `typemin(Int8):typemax(Int8)`.

### Finding 13: MEDIUM -- Int16 edge cases missing

**File**: `test_int16.jl`
**Status**: Tests polynomial for `Int16(-50):Int16(50)`. Missing `typemin(Int16)`, `typemax(Int16)`, and overflow boundary values.
**Action**: Add: `@test simulate(circuit, typemin(Int16)) == f(typemin(Int16))` and similar.

### Finding 14: MEDIUM -- `sat_pebbling.jl` tested only on tiny DAGs

**File**: `test_sat_pebbling.jl`
**Status**: Tests chains of 3 and 5 nodes, and a diamond of 4 nodes. Does not test anything compiled from an actual Bennett circuit.
**Action**: Add integration test: extract DepDAG from a real compiled circuit, run SAT pebbling on it, verify the schedule.

### Finding 15: LOW -- Controlled circuits not tested with loops or complex types

**File**: `test_controlled.jl`, `test_combined.jl`
**Status**: Controlled circuits tested with increment, polynomial, two-arg, nested-if, compare+select. Not tested with:
  - Loop-containing functions
  - Tuple-returning functions
  - Multi-width (Int16/32/64) functions
  - Float64 circuits
**Action**: Add at least one controlled test for a wider type and for a tuple return.

### Finding 16: LOW -- `ir_parser.jl` coverage is thin

**File**: `test_parse.jl`
**Status**: Tests only `extract_ir` + `parse_ir` for basic functions. Does not test error cases (malformed IR), switch instruction parsing, phi node parsing, or cast instruction parsing via the regex path.
**Mitigation**: The regex parser is legacy (LLVM.jl C API is primary). Low priority.

### Finding 17: LOW -- `soft_fsub` edge case coverage lighter than `fadd`

**File**: `test_softfsub.jl`
**Status**: Edge cases section has only 8 entries vs fadd's comprehensive set. Missing: subnormals (`5.0e-324 - 0.0`), overflow boundary (`-1.7976931348623157e308 - 1.7976931348623157e308`), near-cancellation with nextfloat.
**Action**: Add the missing edge cases from the fadd test pattern.

### Finding 18: LOW -- No test for `pebble_tradeoff` return value correctness

**File**: `test_pebbling.jl`
**Status**: `pebble_tradeoff` is tested but only asserts `result.time >= 2n-1` and `result.space >= min_pebbles(n)`. Does not verify that `result.time == knill_pebble_cost(n, result.space)`.
**Action**: Add: `@test result.time == Bennett.knill_pebble_cost(n, result.space)`.

---

## Recommendations

### Priority 1 (Critical/High -- should be done before any release)

1. **Add `test_soft_sitofp.jl`**: Comprehensive test for `soft_sitofp` with all edge cases and 10k random. Finding 1.
2. **Add `ceil` test to `test_float_intrinsics.jl`**: Finding 2.
3. **Add gate count regression assertions**: Create `@test` lines for the documented baselines (86/174/350/702 gates). Finding 5.
4. **Add library tests for `soft_fptosi`**: Finding 3.
5. **Add `ole`/`une` testsets to `test_softfcmp.jl`**: Finding 4.
6. **Add `constant_wire_count` tests**: Finding 6.

### Priority 2 (Medium -- should be done in the next development cycle)

7. **Add wire allocator unit tests**: Finding 7.
8. **Expand division tests to exhaustive UInt8 + add srem**: Finding 9.
9. **Add `test_soft_fround.jl`** with random + edge cases: Finding 10.
10. **Add negative tests for error conditions**: At least 5-6 tests verifying error messages for unsupported instructions, missing loop count, invalid arguments. Section on Missing Negative Tests.
11. **Expand two-arg tests with negative edge cases**: Finding 11.
12. **Expand Int16 tests with typemin/typemax**: Finding 13.
13. **Expand loop test to negative inputs**: Finding 12.
14. **Improve dep_dag tests with edge verification**: Finding 8.

### Priority 3 (Low -- nice to have)

15. **Add controlled circuit tests for wider types and tuples**: Finding 15.
16. **SAT pebbling integration with real circuits**: Finding 14.
17. **Expand `soft_fsub` edge cases**: Finding 17.
18. **Add `pebble_tradeoff` return value verification**: Finding 18.
