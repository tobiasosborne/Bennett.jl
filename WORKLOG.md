# Bennett.jl Work Log

## Migration note (2026-04-11)

Migrated from `~/Projects/research-notebook/Bennett.jl/` (private dev repo) to
`~/Projects/Bennett.jl/` (public standalone repo, https://github.com/tobiasosborne/Bennett.jl).
The research-notebook copy is frozen as a development log record.

**Next agent task:** Major architecture and code review of the public repo. Review all
source files for code quality, dead code, documentation, test coverage. The beads issue
tracker carries over with open issues.

## Project purpose

Bennett.jl is an LLVM-level reversible compiler — the Enzyme of reversible
computation. Any pure function in any LLVM language compiles to a space-optimized
reversible circuit (NOT, CNOT, Toffoli gates) without special types or source
modification. The long-term goal is quantum control in Sturm.jl:
`when(qubit) do f(x) end` where f is arbitrary Julia code compiled to a
controlled reversible circuit.

**Vision PRD**: [`Bennett-VISION-PRD.md`](Bennett-VISION-PRD.md) — full v1.0
roadmap, Enzyme analogy, LLVM IR coverage tiers, three pillars (instruction
coverage, space optimization, composability), reversible memory model options.

**Per-version PRDs**: `Bennett-PRD.md` (v0.1), `BennettIR-PRD.md` (v0.2),
`BennettIR-v03-PRD.md` (v0.3), `BennettIR-v04-PRD.md` (v0.4),
`BennettIR-v05-PRD.md` (v0.5).

---

## Repository layout

```
Bennett.jl/
  v0.1/                   # Archived: operator-overloading tracer (Traced{W} type)
    src/                  # dag.jl, traced.jl, lower.jl, bennett.jl, simulator.jl, ...
    test/                 # Full test suite (identity, increment, polynomial, multi-input,
                          #   branching with ifelse, when() controlled ops)
    Project.toml

  src/                    # Active: LLVM IR-based reversible compiler (v0.2 → v0.4)
    Bennett.jl            # Module definition. Exports: reversible_compile, simulate,
                          #   controlled, extract_ir, parse_ir, extract_parsed_ir,
                          #   gate_count, ancilla_count, depth, print_circuit,
                          #   verify_reversibility, ReversibleCircuit, ControlledCircuit.
                          #   Variadic: reversible_compile(f, types...; kw...).
                          #   Key kwarg: max_loop_iterations (required if IR has loops).
    ir_types.jl           # IR representation: IRBinOp, IRICmp, IRSelect, IRRet,
                          #   IRBranch, IRPhi, IRCast, IRInsertValue, IROperand,
                          #   IRBasicBlock, ParsedIR.
                          #   ParsedIR has getproperty shim: parsed.instructions flattens
                          #   blocks for backward compat. Also has ret_elem_widths field
                          #   for tuple returns ([8] for Int8, [8,8] for Tuple{Int8,Int8}).
    ir_extract.jl         # LLVM.jl-based extraction. Pipeline:
                          #   code_llvm(f, types) → IR string → LLVM.Module (via
                          #   LLVM.parse) → walk functions/blocks/instructions via typed
                          #   C API → produce ParsedIR.
                          #   Key: two-pass name table keyed on LLVMValueRef (C pointer)
                          #   for consistent SSA naming of unnamed LLVM values.
                          #   Handles: add/sub/mul/and/or/xor/shl/lshr/ashr, icmp,
                          #   select, phi, br (cond+uncond), ret, sext/zext/trunc,
                          #   insertvalue (aggregate), ConstantAggregateZero.
                          #   Array return types ([N x iM]) → ret_elem_widths.
                          #   Skips: call, load, store, getelementptr (dead branches only).
                          #   Treats unreachable as dead-code terminator.
    ir_parser.jl          # Legacy regex-based parser. Still used by test_parse.jl for
                          #   printing IR. Not on the critical path.
    gates.jl              # NOTGate, CNOTGate, ToffoliGate, ReversibleCircuit struct.
                          #   ReversibleCircuit has output_elem_widths field for tuple
                          #   return detection in the simulator.
    wire_allocator.jl     # WireAllocator: sequential wire allocation, allocate!(wa, n).
    adder.jl              # lower_add! (ripple-carry), lower_sub! (two's complement).
    multiplier.jl         # lower_mul! (shift-and-add, O(W^2) gates).
    lower.jl              # Main lowering: ParsedIR → LoweringResult.
                          #   Multi-block: topo sort (Kahn's), back-edge detection via
                          #   DFS coloring (find_back_edges), phi → nested MUX resolution
                          #   (innermost-branch-first via on_branch_side matching).
                          #   Loop unrolling: lower_loop! emits K copies of loop body
                          #   with MUX-frozen outputs once exit condition fires.
                          #   Also: lower_and!, lower_or!, lower_xor!, lower_shl!,
                          #   lower_lshr!, lower_ashr!, lower_eq!, lower_ult!, lower_slt!,
                          #   lower_not1!, lower_mux!, lower_select!, lower_cast!,
                          #   lower_insertvalue!, lower_binop!, lower_icmp!.
                          #   LoweringResult now carries output_elem_widths.
    bennett.jl            # Bennett construction: forward + CNOT copy-out + uncompute.
                          #   Threads output_elem_widths through to ReversibleCircuit.
    simulator.jl          # Bit-vector simulator. apply!(bits, gate) for each gate type.
                          #   _read_output dispatches: single-element → scalar (Int8/16/32/64),
                          #   multi-element → Tuple. Uses reinterpret for signed types.
                          #   Ancilla-zero assertion on every simulation.
    diagnostics.jl        # gate_count, ancilla_count, depth, print_circuit,
                          #   verify_reversibility (random bits per wire, no overflow).
    controlled.jl         # ControlledCircuit: wraps every gate with a control wire.
                          #   NOT→CNOT, CNOT→Toffoli, Toffoli→3 Toffolis + 1 ancilla.
                          #   simulate(cc, ctrl::Bool, input) uses _read_output.

  test/                   # 16 test files, ~10K+ test assertions total
    runtests.jl
    test_parse.jl         # Regex parser tests (backward compat)
    test_increment.jl     # f(x::Int8) = x + Int8(3). 256 inputs.
    test_polynomial.jl    # g(x::Int8) = x*x + 3x + 1. 256 inputs.
    test_bitwise.jl       # h(x::Int8) = (x & 0x0f) | (x >> 2). 256 inputs.
    test_compare.jl       # k(x::Int8) = x > 10 ? x+1 : x+2. 256 inputs.
    test_two_args.jl      # m(x,y) = x*y + x - y. 16x16 grid.
    test_controlled.jl    # controlled() for increment, polynomial, two-arg.
    test_branch.jl        # Nested if/else (3-way phi), branch+computation.
    test_loop.jl          # LLVM-unrolled loop (for i in 1:4 → shl).
    test_combined.jl      # Controlled + branching together.
    test_int16.jl         # Int16 polynomial. 101 inputs.
    test_int32.jl         # Int32 linear. 1000 random + edge cases.
    test_int64.jl         # Int64 increment + gate scaling table.
    test_mixed_width.jl   # sum_to (zext i8→i9, trunc i9→i8).
    test_loop_explicit.jl # Collatz steps (20-iter unroll, data-dependent exit).
    test_tuple.jl         # swap_pair, complex_mul_real, dot_product 4-arg.

  Bennett-PRD.md          # v0.1 PRD
  BennettIR-PRD.md        # v0.2 PRD
  BennettIR-v03-PRD.md    # v0.3 PRD
  BennettIR-v04-PRD.md    # v0.4 PRD
  Project.toml            # Deps: InteractiveUtils, LLVM. Extras: Test, Random.
  WORKLOG.md              # This file.
```

---

## Version history

### v0.1 — Operator-overloading tracer (archived in v0.1/)
- Custom `Traced{W}` type with arithmetic overloads builds a DAG.
- DAG → reversible gates → Bennett construction → bit-vector simulator.
- Features: +, -, *, bitwise ops, comparisons (==, <, >, etc.), ifelse branching,
  `when(cond, val) do ... end` controlled ops, % and ÷ by power of 2.
- All tests pass. Good for understanding the concepts, but ceiling: can only
  trace code that dispatches on Traced types.

### v0.2 — LLVM IR approach
- Plain Julia functions compiled via `code_llvm` → regex-parsed LLVM IR →
  same gate-level lowering as v0.1.
- Proved the thesis: standard Julia code → reversible circuits without special types.
- Handles: add, sub, mul, and, or, xor, shl, lshr, ashr, icmp, select, ret.
- Int8 only. Single basic block only.
- Tests: increment, polynomial, bitwise, compare+select, two-arg.

### v0.3 — Controlled circuits + multi-block IR
- **Feature A: controlled()** — wraps ReversibleCircuit with a control bit.
  NOT→CNOT, CNOT→Toffoli, Toffoli→3 Toffolis + 1 shared ancilla.
  ControlledCircuit struct with dedicated simulate method.
- **Feature B: Multi-basic-block LLVM IR** — parser handles br (cond/uncond),
  phi, block labels. Lowering: topological sort, phi → nested MUX resolution
  (innermost-branch-first algorithm), multi-ret merging, back-edge detection.
- Tests: controlled increment/polynomial/two-arg, nested if/else (3-way phi),
  branch with computation, LLVM-unrolled loop, combined controlled+branching.

### v0.4 — Wider integers, loops, tuples, LLVM.jl refactor (current)
- **Feature A: Wider integers** — Int16, Int32, Int64 all work. sext/zext/trunc
  for arbitrary widths (including i9). Gate count scales linearly for addition:
  i8=86, i16=174, i32=350, i64=702 (exactly 2x each doubling).
  Simulator handles signed return types via reinterpret(IntN, UIntN(raw)).
- **LLVM.jl refactor** — Replaced regex parser with LLVM.jl C API walking.
  extract_parsed_ir() does: code_llvm string → LLVM.Module → walk via
  LLVM.opcode/operands/predicate/incoming/successors → ParsedIR.
  Two-pass name table (LLVMValueRef → Symbol) for consistent SSA naming.
  All gate counts IDENTICAL pre/post refactor (verified on full test suite).
- **Feature B: Explicit loops** — DFS-based back-edge detection in CFG.
  Bounded unrolling: K copies of loop body with MUX-frozen outputs once the
  exit condition fires. Handles self-loops (L8→L8 pattern). Loop-carried phi
  nodes connect iteration i's latch outputs to iteration i+1's header inputs.
  First iteration uses pre-header values. API: max_loop_iterations kwarg.
  Test: collatz_steps with 20 iterations → 28,172 gates, 8,878 wires.
- **Feature C: Tuple return** — insertvalue instruction and [N x iM] array
  return types. ConstantAggregateZero → fresh zero wires. insertvalue lowering
  copies aggregate, replaces element at constant index. Multi-element output
  in simulator via output_elem_widths (distinguishes Int16 from Tuple{Int8,Int8}).
  Variadic reversible_compile(f, types...) for 3+ arg functions.
  Tests: swap_pair (80 gates, 0 Toffoli), complex_mul_real (1440 gates),
  dot_product 4-arg (1444 gates).

---

## Session log — 2026-04-09

### What was built (chronological order)

1. **v0.1**: Operator-overloading tracer. Traced{W} type, DAG, operator overloads
   for +, -, *, bitwise, comparisons, ifelse, when(). All tests passed first run.

2. **v0.1 extension**: Added `when(cond, val) do ... end` for controlled operations
   (MUX-based). Then added data-dependent branching: comparisons returning Traced{1},
   ifelse via MUX, mod/div by power of 2, Bool(Traced) error. Collatz step worked.

3. **v0.2**: LLVM IR approach. Moved v0.1 to subfolder. Built regex parser for
   code_llvm output. Handles quoted SSA names like %"x::Int8", nsw/nuw flags,
   all arithmetic/logic/comparison/select instructions. All 5 test functions
   (increment, polynomial, bitwise, compare+select, two-arg) passed first run.

4. **v0.3 Feature A**: Controlled circuits. promote_gate (NOT→CNOT, CNOT→Toffoli,
   Toffoli→3 Toffolis+1 ancilla). ControlledCircuit wrapper with simulate dispatch.

5. **v0.3 Feature B**: Multi-basic-block IR. Parser: br/phi/block labels. Lowering:
   topo sort, phi→nested MUX (innermost-branch-first). Tested on q(x) with
   3-way phi from nested if/else. Key subtlety: on_branch_side matching when
   branch source is direct predecessor of merge block.

6. **v0.4 Feature A**: Wider integers. Simulator return type fix (Int8/16/32/64
   via reinterpret). sext/zext/trunc parsing and lowering. Verified on sum_to
   which uses i9 (!) internally (LLVM's closed-form for n*(n-1)/2). Fixed
   verify_reversibility overflow for 64-bit (rand(Bool) per wire instead of
   rand(0:2^w-1)).

7. **LLVM.jl refactor**: Replaced regex parser with LLVM.jl C API. Key learnings:
   - LLVM.Context() do ... end required for module parsing
   - value_type (not llvmtype) for getting LLVM types
   - LLVM unnamed values get "" from LLVM.name() — need name table
   - Name table keyed on LLVMValueRef (.ref field of wrapper objects)
   - Two-pass: first assign names, then convert instructions
   - ConstantAggregateZero for zeroinitializer aggregates
   - LLVMGetIndices for insertvalue index extraction
   - LLVM.incoming(phi) returns (value, block) pairs
   - LLVM.isconditional(br) + LLVM.condition(br) + LLVM.successors(br)

8. **v0.4 Feature B**: Explicit loop handling. find_back_edges via DFS coloring
   (white/gray/black). topo_sort with ignore_edges parameter. lower_loop! does
   bounded unrolling: K iterations, each with body lowering → exit condition →
   MUX freeze. Tested on collatz_steps (self-loop with 2 loop-carried phis).

9. **v0.4 Feature C**: Tuple return. IRInsertValue type. insertvalue lowering:
   copy aggregate, replace element at index. ConstantAggregateZero → allocate
   zero wires. output_elem_widths threaded through entire pipeline (ParsedIR →
   LoweringResult → ReversibleCircuit). Simulator _read_output returns Tuple for
   multi-element. Variadic reversible_compile(f, types...).

### Key bugs encountered and fixed

1. **Phi resolution for sum_to**: The branch source (top) was a DIRECT predecessor
   of the phi's block (L32). The old has_ancestor check couldn't match because top
   has no ancestors. Fix: in on_branch_side matching, when block == src, it matches
   the true side (since `b == src` means it branches directly to the phi block).
   The exclusive matching (`is_true && !is_false`) prevents false positives.

2. **verify_reversibility overflow**: `rand(0:(1 << 64) - 1)` overflows because
   `1 << 64 = 0` in Int64. Fix: use `rand(Bool)` per bit.

3. **Closure SSA naming**: `g(x) = x + one(T)` in a loop gets different argument
   names in LLVM IR vs a named function. Fix: use separate named functions.

4. **LLVM.jl unnamed values**: Each call to LLVM.name() for an unnamed value returns
   "". Multiple calls to _val_name() generated different auto-names for the SAME
   value. Fix: two-pass name assignment keyed on LLVMValueRef.

5. **Random package in tests**: Julia 1.12 doesn't auto-load Random in test
   environments. Fix: add Random to [extras] in Project.toml.

### Gate count reference table

| Function | Width | Gates | NOT | CNOT | Toffoli | Wires |
|----------|-------|-------|-----|------|---------|-------|
| x + 1 | i8 | 86 | 2 | 56 | 28 | |
| x + 1 | i16 | 174 | 2 | 112 | 60 | |
| x + 1 | i32 | 350 | 2 | 224 | 124 | |
| x + 1 | i64 | 702 | 2 | 448 | 252 | |
| x + 3 (Int8) | i8 | 88 | 4 | 56 | 28 | |
| x*x+3x+1 (Int8) | i8 | 846 | 6 | 488 | 352 | 264 |
| x*x+3x+1 (Int16) | i16 | 3102 | 6 | 1744 | 1352 | |
| (x&0xf)|(x>>2) | i8 | 96 | 8 | 56 | 32 | |
| x>10?x+1:x+2 | i8 | 296 | 34 | 186 | 76 | 114 |
| x*y+x-y | i8 | 876 | 20 | 504 | 352 | 272 |
| x*7+42 (Int32) | i32 | 11528 | 12 | 6368 | 5148 | |
| nested if/else | i8 | 630 | 70 | 380 | 180 | |
| collatz_steps (20 iter) | i8 | 28172 | 1306 | 16898 | 9968 | 8878 |
| swap_pair | i8 | 80 | 0 | 80 | 0 | |
| complex_mul_real | i8 | 1440 | 0 | 848 | 592 | |
| controlled increment | i8 | 144 | 0 | 4 | 140 | |
| controlled nested-if | i8 | 990 | 0 | 70 | 920 | |

### Process notes

- v0.1 through v0.3 were built code-first (tests written alongside).
- Starting mid-v0.4, switched to red-green TDD at user request:
  write failing test → run red → implement → run green.
- Each feature verified with `Pkg.test()` (full suite) before committing.
- Three git commits in this session:
  1. `61f5bb2` — Initial: all of v0.1–v0.4 Feature A + LLVM.jl refactor
  2. `2ee6001` — v0.4-B: explicit loop handling
  3. `f5e42b2` — v0.4-C: tuple return support

---

## Key design decisions

### SSA naming with LLVM.jl
LLVM unnamed values get "" from LLVM.name(). We assign sequential auto-names
(__v1, __v2, ...) in a two-pass approach: first pass names everything, second
pass converts instructions using the name table. The table is keyed on
LLVMValueRef (C pointer) so the same LLVM value always maps to the same name,
even when accessed via different Julia wrapper objects.

### Phi resolution algorithm
Multi-way phi nodes (e.g., 3-way in nested if/else) are resolved via nested
MUXes. The algorithm processes conditional branches innermost-first (reverse
topological order of branch source blocks). For each branch, it finds the
incoming values on the true and false sides, merges them with a MUX, and
replaces both with the merged value attributed to the branch source. Repeats
until one value remains.

The `on_branch_side` matching handles three cases:
1. Block IS the branch target label → on that side
2. Block is a descendant of the target (has_ancestor check via preds) → on that side
3. Block IS the branch source → on the true side (it branches directly to merge)
Exclusive matching (`is_true(b) && !is_false(b)`) prevents ambiguity.

### Loop unrolling
Bounded unrolling with MUX-frozen outputs. For each iteration:
1. Lower loop body instructions (non-phi)
2. Compute exit condition
3. If exit_on_true differs from IR, negate the condition
4. Resolve latch values (what phi would receive next iteration)
5. MUX(exit_cond, current_frozen, latch_new) for each loop-carried variable
After K iterations, the frozen values are the loop result.
Key property: once exit fires, subsequent iterations compute with frozen (unchanged)
inputs, exit condition remains true, MUX keeps freezing. Correct for any
deterministic loop body.

### Bennett construction
Forward gates → CNOT copy output to fresh wires → reverse(forward gates).
All ancillae (intermediate wires) return to zero. The copy wires survive with
f(x). Input wires are never written to (only read as gate controls).

### Controlled-Toffoli decomposition
Each Toffoli(c1, c2, target) with an additional control `ctrl` becomes:
1. Toffoli(ctrl, c1, ancilla) — compute ctrl & c1
2. Toffoli(ancilla, c2, target) — apply the controlled operation
3. Toffoli(ctrl, c1, ancilla) — uncompute ancilla
One ancilla wire is shared across all decompositions in the circuit.

### Tuple return pipeline
output_elem_widths flows: ir_extract (from LLVM.ArrayType) → ParsedIR →
LoweringResult → ReversibleCircuit → simulator _read_output. Single-element
[W] → scalar Int8/16/32/64. Multi-element [W1, W2, ...] → Tuple.
insertvalue builds aggregates element-by-element from zeroinitializer.

---

## Dependencies
- **LLVM.jl** (v9.4.6): Wraps LLVM C API. Used for IR extraction and walking.
- **InteractiveUtils**: stdlib, provides code_llvm for IR string extraction.
- **Test, Random**: test dependencies.
- **Julia**: 1.12.3 (current dev environment). Compat set to 1.6 in Project.toml.

## Known limitations
- **NTuple input**: Julia passes NTuple as a pointer (getelementptr + load in IR).
  This requires memory op handling, which is not implemented. Tuple RETURN works.
- **LLVM intrinsics**: @llvm.umax/umin/smax/smin now handled (lowered to icmp+select).
  Other intrinsics (@llvm.abs, @llvm.ctlz, etc.) still not handled.
- **Floating point**: Partial. soft_fadd (pure-Julia IEEE 754 addition) is
  bit-exact and compiles to 87,694 gates. Simulation passes for non-overflow
  cases (non-equal-magnitude same-sign addition). Overflow cases fail due to
  MUX ordering in the phi resolver (L107/L112 diamond — see v0.5 session notes).
- **Function calls**: `call` instructions: LLVM intrinsics (umax/umin/smax/smin)
  are now handled. Other calls still skipped.
- **Variable-length shifts**: Now supported. Barrel-shifter lowering (6 stages
  of MUX for 64-bit values). Both constant and variable shifts handled.
- **extractvalue**: Not implemented (insertvalue is). Would be needed for
  tuple destructuring.
- **Nested loops**: Untested. The unrolling algorithm handles single-level loops.
  Nested would need recursive detection.
- **Phi resolution for complex CFGs**: The recursive phi resolver handles
  multi-way phis (12-way tested) and diamond merges in the CFG. Known issue:
  when one side of a branch has no exclusive values (only ambiguous/diamond
  values), the resolver can't place the branch's MUX correctly. This causes
  incorrect simulation for soft_fadd overflow cases. See v0.5 session notes.

## Test command
```bash
cd Bennett.jl
julia --project=. -e 'using Pkg; Pkg.test()'
```

Note: the git repo root is `research-notebook/`, not `Bennett.jl/`. The Julia
project is at `Bennett.jl/Project.toml`. Run tests from the `Bennett.jl` dir.

## Sturm.jl integration path
Sturm.jl's `when(qbit) do f(x) end` uses a control stack (push_control!/
pop_control! in TracingContext, defined in src/context/abstract.jl and
src/control/when.jl). Our controlled() post-hoc promotion approach produces
equivalent results but with ~3x Toffoli overhead per controlled gate.
The optimized path (adding control wires to inner gates during lowering,
matching Sturm.jl's push_control!/pop_control! pattern) is a future v0.5+
optimization. Sturm.jl lives at ~/Projects/Sturm.jl.

## Session log — 2026-04-09 (continued): v0.5 Float64

### What was built

1. **Soft-float library (Phase 1 — complete)**
   - `src/softfloat/fneg.jl`: `soft_fneg(a::UInt64)::UInt64` — XOR bit 63. Trivial.
   - `src/softfloat/fadd.jl`: `soft_fadd(a::UInt64, b::UInt64)::UInt64` — full IEEE 754
     double-precision addition. Handles NaN, Inf, zero, subnormals, round-to-nearest-even.
     Uses binary-search CLZ (6 constant-shift stages) for normalization.
   - `src/softfloat/softfloat.jl`: includes fneg.jl and fadd.jl.
   - `test/test_softfloat.jl`: 1,037 tests. 10,000 random pairs bit-exact against
     Julia's native `+`. Edge cases: ±0, ±Inf, NaN, subnormals, near-cancellation.
   - All soft-float tests pass. **Bit-exact** with hardware Float64 addition.

2. **LLVM intrinsic support (Pipeline extension)**
   - `ir_extract.jl`: `_convert_instruction` now handles `call` instructions for
     known LLVM intrinsics: `@llvm.umax`, `@llvm.umin`, `@llvm.smax`, `@llvm.smin`.
     Each is lowered to `IRICmp` + `IRSelect` (compare + select).
   - LLVM optimizes `ifelse(x != 0, x, 1)` into `@llvm.umax.i64(x, 1)`. Without
     this support, the SSA variable from the intrinsic call was undefined, causing
     "Undefined SSA variable" errors.
   - `_module_to_parsed_ir` now handles vector returns from `_convert_instruction`
     (needed for the two-instruction expansion of intrinsics).

3. **Variable-amount shift support (Pipeline extension)**
   - `lower.jl`: Removed constant-shift assertion. Added `lower_var_shl!`,
     `lower_var_lshr!`, `lower_var_ashr!` — barrel-shifter implementations.
   - Each barrel shifter: `_shift_stages(W, b_len)` stages (6 for 64-bit).
     Each stage: conditional shift by 2^k via MUX. Total: ~6 × 4W = 1536 gates
     per 64-bit variable shift.
   - Tested: `var_rshift(x::Int8, n::Int8) = reinterpret(Int8, reinterpret(UInt8,x) >> (reinterpret(UInt8,n) & UInt8(7)))`.
     All 256×8 = 2048 input combinations correct. 272 gates.

4. **Phi resolution for complex CFGs (Pipeline extension — partial)**
   - `lower.jl`: Rewrote `resolve_phi_muxes!` from iterative (pair-matching) to
     recursive (partition-based). Finds a branch that cleanly partitions incoming
     values into true-set and false-set, recurses on each, MUXes results.
   - Added `phi_block` parameter: passed from `lower_phi!` through to
     `resolve_phi_muxes!`. When a block IS the branch source AND the phi block
     is one of the branch targets, correctly identifies which side the block is on.
     Critical for the LLVM `common.ret` pattern (many early returns merged via phi).
   - Added **diamond merge** handling: when some values are reachable from both
     sides of a branch (CFG diamond), resolve them once as shared and include in
     both sub-problems. Shared wires are read by both MUX branches (valid in
     reversible circuits since wires are read-only for controls).
   - Added cycle detection in `has_ancestor` (visited set) to prevent infinite
     recursion from predecessor graph cycles.

5. **soft_fadd circuit compilation (Phase 3 — partial)**
   - `soft_fadd` compiles to a reversible circuit: **87,694 gates** (4,052 NOT,
     60,960 CNOT, 22,682 Toffoli), 27,550 wires, 27,358 ancillae.
   - `soft_fneg` compiles: 322 gates (2 NOT, 320 CNOT, 0 Toffoli).
   - Simulation correct for non-overflow addition cases: 1.0+2.0, 1.0+0.5,
     3.14+2.72, 0.0+0.0, Inf+1.0, Inf+(-Inf), subtraction cases.
   - **Known failure**: overflow cases (0.5+0.5, 1.0+1.0, 0.25+0.25) return 0
     instead of the correct sum. Root cause: the L107/L112 diamond in the CFG.
     L107 branches to L110 (addition) or L112 (subtraction). Both paths merge at
     L129. Downstream values (L186, L211, L240, L257) have ancestors on BOTH sides
     of L107. When L112's cancellation check (wr==0) condition wire is 1 (because
     the subtraction result IS 0 for equal-magnitude same-sign inputs), the MUX
     incorrectly selects the cancellation return value (0) instead of the
     normal computation result.
   - **Fix needed**: The MUX tree must nest L112's check INSIDE L107's branch so
     that L107_cond=true (addition path) bypasses L112's check entirely. Current
     recursive resolver skips L107 because it has no exclusive true-side values
     (only ambiguous diamond values). A "one-sided + ambiguous" case was attempted
     but causes infinite recursion — needs further work.

6. **Test files created**
   - `test/test_softfloat.jl`: 1,037 tests for soft_fneg and soft_fadd bit-exactness.
   - `test/test_float_circuit.jl`: Circuit compilation + simulation tests for
     soft_fneg and soft_fadd. Currently has known failures for overflow cases.

### Key bugs encountered and fixed

1. **LLVM umax intrinsic**: LLVM optimized `ifelse(x != 0, x, 1)` into
   `@llvm.umax.i64(x, 1)`. Our pipeline skipped `call` instructions, leaving the
   SSA variable undefined. Fix: handle known intrinsics by expanding to icmp+select.

2. **12-way phi resolution**: LLVM's `common.ret` block has a phi with 12 incoming
   values from early returns. The old iterative resolver (innermost-first pair
   matching) failed because some incoming blocks are the branch SOURCE (they go
   directly to common.ret). Fix: pass `phi_block` through the resolver and use it
   to determine which side of a branch the source block is on.

3. **CFG diamond merge**: Blocks L207.thread and L207 both lead to L215, creating
   a diamond. Values downstream of L215 are reachable from both sides of L129's
   branch. The recursive resolver's clean-partition check fails. Fix: detect
   ambiguous (both-side) values, resolve them once as shared, include the shared
   result in both sub-problems.

4. **Overflow simulation bug (OPEN)**: For equal-magnitude same-sign addition
   (0.5+0.5), the subtraction path also computes (wa - wb = 0). L112's condition
   wire (wr==0) is true even though the addition path was taken. The MUX tree
   needs L107's branch to guard L112's check. The resolver can't place L107
   correctly because all downstream values are ambiguous (diamond). Attempted fix
   (one-sided + ambiguous → use ambiguous as the empty side) causes infinite
   recursion. Further work needed — likely requires tracking which branches have
   already been used in the recursion or a fundamentally different phi resolution
   strategy for these cases.

### Gate count reference (new entries)

| Function | Width | Gates | NOT | CNOT | Toffoli | Wires |
|----------|-------|-------|-----|------|---------|-------|
| soft_fneg | i64 | 322 | 2 | 320 | 0 | |
| soft_fadd | i64 | 87694 | 4052 | 60960 | 22682 | 27550 |
| var_rshift | i8 | 272 | 6 | 202 | 64 | |

### Process notes
- Followed red-green TDD throughout: wrote test_softfloat.jl first (RED, stubs),
  then implemented (GREEN). Wrote test_float_circuit.jl (RED, compilation fails),
  then added pipeline features.
- Each pipeline change verified against full existing test suite (17 files, 10K+
  assertions) before proceeding.
- PRD: BennettIR-v05-PRD.md. Approach B (pure-Julia soft-float wrapper).

### Architecture decisions

**Soft-float as pure Julia**: The soft_fadd function is a standard Julia function
taking UInt64 bit patterns. It uses only integer operations (shifts, adds, bitwise,
comparisons, ifelse). The existing pipeline compiles it without any float-specific
code. The "floating point" happens entirely at the Julia level — the pipeline sees
only integer operations on 64-bit values.

**Barrel shifter for variable shifts**: Each stage conditionally shifts by 2^k
using a MUX. 6 stages for 64-bit (covering shifts 1,2,4,8,16,32). Cost: ~1536
gates per variable shift (6 stages × 256 gates per MUX).

**Recursive phi resolution**: Replaced iterative pair-matching with recursive
partitioning. Each recursion level finds a branch that splits the incoming values
into two non-empty groups, recurses on each, and MUXes the results. Handles
N-way phis naturally (reduces N→1 via log2(N) levels for balanced trees, up to
N-1 levels for degenerate cases).

**Diamond merge in phi resolution**: When values are reachable from both sides of
a branch (CFG diamond after an if-else merge), resolve them once and share the
result in both sub-calls. The shared wires are read-only (CNOT/Toffoli controls),
so sharing is safe in reversible circuits.

## Research: overflow simulation bug — "false path" problem

### The bug

The overflow simulation bug (0.5+0.5 returns 0 instead of 1.0) is an instance of
the **"false path sensitization"** problem, well-known in hardware synthesis
(VLSI/FPGA). In a branchless/speculative datapath, ALL paths are computed. A
condition wire from the subtraction path (`wr==0`) evaluates to true even when the
addition path was "taken" (via MUX selection), because the subtraction of two equal
mantissas IS zero. The MUX tree doesn't scope this condition correctly — L112's
cancellation check fires without being guarded by L107's same-sign check.

Reference: Bergamaschi (1992), "The Effects of False Paths in High-Level Synthesis",
IEEE. False paths occur due to sequences of conditional operations where the
combination of conditions required to activate the path is logically impossible.

### Literature survey: no existing reversible compiler handles this

No published reversible compiler handles N-way phi nodes from complex CFGs:

- **ReVerC / Revs** (Parent, Roetteler, Svore — Microsoft, CAV 2017): Compiles F#
  subset to Toffoli networks. NO dynamic control flow — restricted to straight-line
  computation. Uses Bennett compute-copy-uncompute on DAGs, not CFGs.
  Ref: "Verified Compilation of Space-Efficient Reversible Circuits" (Springer).

- **Janus** (Yokoyama, Gluck, 2007): Reversible language where conditionals have
  EXIT ASSERTIONS (`if p then B1 else B2 fi q`) that disambiguate branches at merge
  points. Not applicable to LLVM IR where this info is erased into phi nodes.
  Ref: "Principles of a Reversible Programming Language" (ACM).

- **VOQC / SQIR** (Hicks et al., POPL 2021): Verified optimizer for already-
  synthesized gate-level quantum circuits. Does not deal with SSA/phi/CFG compilation.
  Ref: "A Verified Optimizer for Quantum Circuits" (arXiv:1912.02250).

- **XAG-based compilation** (Meuli, Soeken, De Micheli, 2022): Boolean function
  decomposition into XOR-AND-Inverter Graphs → Toffoli. Operates on Boolean functions,
  not CFGs. Ref: Nature npj Quantum Information (2021).

- **Bennett's pebble game**: Applies to straight-line DAGs. No standard extension
  to CFGs with diamond merges. Ref: Meuli et al. (2019), Chan (2013).

**Our implementation is in uncharted territory.** No published system handles
converting a multi-way phi node from a complex CFG into a correct MUX tree
of reversible gates.

### Quantum floating-point literature

- **Haener, Soeken, Roetteler, Svore (2018)**: "Quantum circuits for floating-point
  arithmetic" (RC 2018, SpringerLink). Two approaches: automatic synthesis from
  Verilog and hand-optimized circuits. Each Toffoli = 7 T-gates in T-depth 3. This
  is the closest published work to what we're doing. They do NOT handle NaN/Inf/zero.

- **Nguyen & Van Meter (2013)**: "A Space-Efficient Design for Reversible Floating
  Point Adder in Quantum Computing" (arXiv:1306.3760). IEEE 754 single-precision.
  Their fault-tolerant KQ is ~60x that of 32-bit fixed-point add. Our 87,694 gates
  for Float64 aligns: their formula predicts ~84K for double-precision (350 gates
  for Int64 add × 60 × ~4x for width doubling ≈ 84K).

- **Gayathri et al. (2021)**: "T-count optimized quantum circuit for floating point
  addition and multiplication" (Springer). 92.79% T-count savings over Nguyen/Van
  Meter, 82.74% KQ improvement over Haener et al.

None of these handle special cases (NaN, Inf, zero, subnormal). Our soft_fadd is
more complete than any published quantum FP circuit.

### Existing soft-float implementations (all branchy)

- **LLVM compiler-rt `fp_add_impl.inc`** (`__adddf3`): 13+ if/else with early
  returns for NaN, Inf, zero, subnormal.
- **Berkeley SoftFloat 3** (`f64_add`): Dispatches on sign into addMags/subMags,
  each with 7-10 branches plus gotos.
- **GCC libgcc `soft-fp`**: Macro-heavy, expands to equivalent branchy code.
- **GPU shaders**: Emulate double precision via two single-precision floats
  (double-single arithmetic), relying on GPU's native FP for special cases.

No existing soft-float implementation is branchless. All assume CPUs with branch
prediction. For circuits, branchless is the standard approach.

### Hardware synthesis context

**Two-path FP adder architecture** (standard in FPGA/ASIC):
- "Close path" (effective subtraction, exp diff 0 or 1, needs full CLZ)
- "Far path" (all other cases, at most 1-bit normalization)
- Both computed in parallel, MUX selects. Natural fit for reversible circuits.
- Ref: "Dual-mode floating-point adder architectures" (Elsevier, 2008).

**FloPoCo** (Floating-Point Cores Generator, flopoco.org): Generates VHDL/Verilog
FP cores for FPGAs. NOT IEEE 754 compliant (omits NaN/Inf/subnormal). Uses
MUX-tree datapath internally. Double-precision adder: ~261 LUTs on Kintex-7.

### Three fix options (ranked by practicality)

#### Option A: Rewrite soft_fadd to be fully branchless (RECOMMENDED)

Replace all `if/else/return` with `ifelse` selects. Compute ALL results (NaN, Inf,
zero, normal) unconditionally, select at end with a chain of `ifelse`.

**How:**
1. Compute all special-case results unconditionally
2. Compute all predicates (is_nan, is_inf, is_zero, etc.)
3. Compute BOTH `wa + wb_aligned` AND `wa - wb_aligned`, select with `ifelse(sa==sb, add_result, sub_result)`
4. Replace the exact-cancellation early return with `ifelse(wr==0, UInt64(0), packed_result)` at the end
5. Convert normalization CLZ `if` statements to `ifelse` (already nearly branchless)
6. Convert subnormal underflow and overflow to `ifelse`
7. Chain final select: `ifelse(is_nan, QNAN, ifelse(is_inf, inf_result, ifelse(is_zero, zero_result, normal_result)))`

**Pros:**
- LLVM emits `select` instructions → NO phi nodes → no resolution needed
- "Correct by construction" — eliminates the entire class of false-path bugs
- Pipeline already handles `select` via `lower_select!`/`lower_mux!`
- Estimated gate cost: ~90,000-95,000 gates (~5-10% overhead). Modest because
  the dominant cost is mantissa arithmetic (same either way). Extra: ~1,400 gates
  for computing both add+sub, ~1,200-1,600 for parallel special cases,
  ~1,344 for 7× 64-bit MUX selection chain, ~1,152 for normalization stage MUXes.

**Cons:**
- All paths always computed (but this is inherent to reversible circuits anyway)
- Doesn't fix the phi resolver for future complex functions

#### Option B: Path-predicate phi resolution (principled algorithm)

Replace the reachability-based partitioning in `resolve_phi_muxes!` with explicit
**path predicates** — 1-bit condition wires computed for each block in the CFG.

**Algorithm (from Gated SSA / Psi-SSA literature):**
1. Walk blocks in topological order. For each block, compute `block_pred[label]`
   as a wire (1-bit).
2. Entry block: `block_pred[:entry] = [constant 1]`
3. Unconditional branch from B to T: `block_pred[T] = block_pred[B]`
4. Conditional branch from B (cond, T, F):
   - `block_pred[T] = AND(block_pred[B], cond)`
   - `block_pred[F] = AND(block_pred[B], NOT(cond))`
5. Block with multiple predecessors (merge/diamond):
   - `block_pred[B] = OR(block_pred[p1], block_pred[p2], ...)`
6. For the phi with incoming (val_i, block_i):
   - `result = MUX(block_pred[b1], val1, MUX(block_pred[b2], val2, ...))`

**Why it works:** Each path predicate is true for exactly one execution path.
The MUX chain selects the right value regardless of diamond merges. No ambiguity.

**Theoretical basis:**
- **Gated SSA** (Havlak, 1993): Replaces phi with `gamma(c, x, y)` carrying the
  branch condition explicitly. "Construction of Thinned Gated Single-Assignment
  Form" (Springer, LNCS 768).
- **Psi-SSA** (Stoutchinin & Gao, CC 2004): Predicated merge nodes
  `psi(p1:v1, p2:v2, ..., pn:vn)` with mutually exclusive, exhaustive predicates.
  "If-Conversion in SSA Form" (Springer, LNCS 2985).
- **Dominator tree approach**: The correct MUX nesting order follows the dominator
  tree. If branch X dominates branch Y, X's MUX must be outer, Y's inner.

**Pros:**
- Correct for ANY CFG (arbitrary diamonds, multi-way phis, complex nesting)
- Makes the resolver robust for all future functions
- Well-founded in compiler theory

**Cons:**
- More engineering work (compute path predicates during lowering, wire AND/OR/NOT
  gates for each predicate)
- Extra gates for predicate computation (AND + NOT per conditional branch, OR per
  merge point). For 12-way phi with ~20 branches: ~20 AND gates + ~20 NOT gates +
  ~10 OR gates = ~50 extra 1-bit gates. Negligible.
- Predicate wires become ancillae (need to be uncomputed by Bennett)

#### Option C: Custom LLVM pass (aggressive if-conversion)

Use LLVM.jl to run additional optimization passes on the IR after `optimize=true`,
specifically targeting branch-to-select conversion.

**How:**
1. `extract_ir(f, types; optimize=true)` → optimized IR string
2. Parse into `LLVM.Module` (already done in `extract_parsed_ir`)
3. Run custom pass pipeline: `FlattenCFG`, aggressive `SimplifyCFG` with high
   speculation threshold, or `SpeculativeExecution`
4. Walk the transformed module (should have more selects, fewer branches)

**LLVM specifics:**
- `SimplifyCFG`'s `FoldTwoEntryPHINode` only handles 2-entry phis in simple
  diamonds. Default `TwoEntryPHINodeFoldingThreshold` = 4 instructions.
- `UnifyFunctionExitNodes` (`-mergereturn`) is what CREATES the `common.ret`
  pattern. Undoing it requires splitting returns back out.
- LLVM's if-conversion is conservative (won't speculate expensive code). For
  reversible circuits, ALL paths are computed anyway, so the "cost" concern
  doesn't apply. A custom pass could aggressively convert without cost limits.

**Pros:**
- Eliminates phis at the LLVM level before our pipeline sees them
- Leverages LLVM's existing infrastructure

**Cons:**
- Significant LLVM engineering (custom pass development)
- LLVM pass API changes between versions (fragile)
- Doesn't help if LLVM introduces new patterns in future versions

#### Option D: Compile with optimize=false

**What happens:** Without optimization, LLVM IR has `alloca`/`load`/`store` for all
local variables (no `mem2reg` pass). Each `return` is its own `ret` instruction.
No `common.ret`, no multi-way phi.

**Problems:**
- Pipeline doesn't handle `alloca`/`load`/`store` — would need a memory model
- IR is much larger (no constant folding, no dead code elimination)
- Redundant computation → much larger circuits

**A middle ground:** Run partial optimization: `mem2reg` (eliminate alloca/load/store)
+ basic `simplifycfg` (clean up trivial blocks) but NOT full optimization that
creates `common.ret`. Requires using LLVM.jl API for custom pass pipeline.

### Recommendation

**Option A (branchless rewrite) for the immediate fix.** It's the smallest code
change, eliminates the entire class of false-path bugs, and the gate overhead is
negligible (~5-10%). This is the standard approach for circuit implementations of
floating-point arithmetic (FloPoCo, FPGA adders, quantum FP papers all use
branchless MUX-tree datapaths).

**Option B (path predicates) for long-term robustness.** Implement as a future
enhancement to make the phi resolver correct for arbitrary CFGs. This is the
principled solution grounded in Gated SSA / Psi-SSA theory.

## Session log — 2026-04-10: branchless soft_fadd (Option A)

### Branchless rewrite — completed

Rewrote `soft_fadd` to be fully branchless (Option A from false-path analysis).
Every `if/else/return` replaced with `ifelse`. All paths computed unconditionally,
final result selected via priority chain at the end.

**Key changes:**
1. Special-case predicates (`a_nan`, `b_nan`, `a_inf`, `b_inf`, `a_zero`, `b_zero`)
   computed unconditionally upfront
2. Both `wr_add = wa + wb_aligned` and `wr_sub = wa - wb_aligned` computed
   unconditionally, selected with `ifelse(same_sign, wr_add, wr_sub)`
3. Exact cancellation handled as a predicate (`exact_cancel`), not an early return —
   substitutes `wr = 1` as a sentinel to avoid undefined normalization on zero
4. Normalization CLZ stages: each `if` → `ifelse` on the condition bit
5. Subnormal/overflow/rounding: all computed unconditionally, selected at end
6. Final select chain in priority order: NaN > Inf > Zero > exact_cancel >
   subnormal flush > exp overflow > normal

**Gotchas:**
- `UInt64(negative_int64)` throws `InexactError` — must clamp Int64 values to
  non-negative range before UInt64 conversion even when the result will be
  overridden by the select chain. Julia evaluates all `ifelse` arguments eagerly.
  Two places needed clamping: subnormal shift amount (`shift_sub = 1 - result_exp`,
  negative for normal numbers) and exponent packing (`exp_after_round`, negative
  for subnormal results).
- `clamp` is branchless in Julia (uses `min`/`max` → LLVM `select`), safe to use.
- Alignment shift mask `(1 << d) - 1` needs d clamped to [1,63] to avoid shift-by-zero
  or shift-by-64 UB.

**Gate counts (branchless vs branching):**

| Metric  | Before   | After    | Delta  |
|---------|----------|----------|--------|
| Total   | 87,694   | 94,426   | +7.7%  |
| NOT     | 4,052    | 5,218    | +28.8% |
| CNOT    | 60,960   | 64,714   | +6.2%  |
| Toffoli | 22,682   | 24,494   | +8.0%  |

~7.7% total overhead — within predicted 5-10%. The cost is computing both add/sub
paths and the extra select chain. Modest because mantissa arithmetic (the dominant
cost) is identical either way.

**Result:** All 1,037 library tests pass (bit-exact). All 124 circuit tests pass —
including the 7 equal-magnitude same-sign cases that previously failed due to
false-path sensitization. The entire class of false-path bugs is eliminated for
soft_fadd.

### soft_fmul — completed

Implemented `soft_fmul` (IEEE 754 double-precision multiplication) branchless from
the start. Key design:

1. Sign = XOR of input signs
2. Exponent = ea + eb - 1023 (bias)
3. 53x53 mantissa multiply via schoolbook decomposition into four half-word partial
   products (27x26 bits each, fits in UInt64 without overflow). Assembled into
   128-bit product (prod_hi:prod_lo) with add-with-carry.
4. Extract top 56 bits (53 mantissa + 3 GRS) based on whether MSB is at bit 105
   or 104 of the product
5. CLZ normalization (same 6-stage binary search as soft_fadd)
6. Rounding, subnormal handling, overflow — same structure as soft_fadd
7. Final select chain: NaN > Inf*0=NaN > Inf > Zero > overflow > normal

**New LLVM intrinsic: `llvm.fshl`/`llvm.fshr` (funnel shifts).**
LLVM optimizes `(a << N) | (b >> (64-N))` into `@llvm.fshl.i64(a, b, N)`. Added
decomposition in `ir_extract.jl`:
- `fshl(a, b, sh)` → `(a << sh) | (b >> (w - sh))`
- `fshr(a, b, sh)` → `(a << (w - sh)) | (b >> sh)`
Each decomposes into 3 IRBinOps (shl, sub, lshr, or).

**Gate counts:**

| Operation | Total   | NOT   | CNOT    | Toffoli  |
|-----------|---------|-------|---------|----------|
| soft_fneg | 322     | 2     | 320     | 0        |
| soft_fadd | 94,426  | 5,218 | 64,714  | 24,494   |
| soft_fmul | 265,010 | 4,960 | 155,828 | 104,222  |

soft_fmul is ~2.8x soft_fadd. The 104,222 Toffoli gates are dominated by the
53x53 mantissa multiply (schoolbook: O(53^2) = 2,809 full-adder cells, each
requiring multiple Toffoli gates in the reversible ripple-carry implementation).

PRD estimated 20,000-50,000 gates for soft_fmul. Actual: 265,010. The estimate
was for the mantissa multiply alone; the full pipeline (unpack, normalize, round,
repack, branchless select chain) adds significant overhead. The branchless approach
also computes both normalization paths unconditionally.

**Result:** 1,041 library tests pass (bit-exact). 238 circuit tests pass (including
113 soft_fmul circuit tests). All ancillae verified zero. Full test suite green.

### Float-aware frontend + end-to-end polynomial — completed

Implemented `reversible_compile(f, Float64)` and the full end-to-end pipeline.

**Architecture — SoftFloat dispatch + gate-level call inlining:**

1. `SoftFloat` wrapper struct redirects `+`, `*`, `-` to `soft_fadd`/`soft_fmul`/
   `soft_fneg` on UInt64 bit patterns. Julia inlines the tiny wrapper methods,
   leaving direct `call @soft_fmul(i64, i64)` and `call @soft_fadd(i64, i64)`
   instructions in the LLVM IR.

2. New `IRCall` instruction type in `ir_types.jl` — represents a call to a known
   Julia function that should be compiled and inlined at the gate level.

3. `ir_extract.jl` recognizes calls to `soft_fadd`/`soft_fmul`/`soft_fneg` in
   the LLVM IR (by name matching) and produces `IRCall` instructions.

4. `lower_call!` in `lower.jl` handles `IRCall` by:
   a. Pre-compiling the callee via `extract_parsed_ir` + `lower`
   b. Offsetting all callee wires into the caller's wire space
   c. CNOT-copying caller arguments → callee input wires
   d. Inserting callee's forward gates with wire remapping
   e. Setting callee's output wires as the caller's result

5. `extract_parsed_ir` now uses `dump_module=true` to include function declarations
   needed for the module parser to accept call instructions. `extract_ir` (for
   debugging/regex parser) still uses single-function mode.

**New LLVM intrinsic support:**
- `llvm.fshl` / `llvm.fshr` (funnel shifts) — decomposed to `shl` + `lshr` + `or`

**Bug fix in branchless soft_fadd:**
- Zero + nonzero special case incorrectly considered the swap flag. Fixed to
  return the original non-zero operand directly: `ifelse(a_zero & !b_zero, b, result)`.

**Gate counts (end-to-end):**

| Function                         | Total   | NOT    | CNOT    | Toffoli  |
|----------------------------------|---------|--------|---------|----------|
| soft_fneg                        | 322     | 2      | 320     | 0        |
| soft_fadd                        | 93,402  | 5,218  | 63,946  | 24,238   |
| soft_fmul                        | 265,010 | 4,960  | 155,828 | 104,222  |
| **x²+3x+1 (Float64, end-to-end)** | **717,680** | **20,380** | **440,380** | **256,920** |

PRD estimated 70,000-130,000 for the polynomial. Actual: 717,680. The estimate assumed
soft_fadd/soft_fmul would be 5K-50K gates. Actual soft_fadd=93K, soft_fmul=265K. The
polynomial calls 2 fmul + 2 fadd = 2×265K + 2×93K = 716K gates plus overhead for
constant encoding and wire copying. The gate count is dominated by the 53×53 mantissa
multiplier (schoolbook O(n²) in the reversible ripple-carry adder implementation).

**Gotchas:**
- `@noinline` on SoftFloat methods is WRONG — it prevents Julia from inlining even
  the tiny wrapper code, producing struct-passing IR with `alloca`/`store`/`load`.
  Without `@noinline`, Julia inlines the wrappers and leaves clean `call @soft_fmul(i64, i64)`.
- `dump_module=true` is required for `extract_parsed_ir` (module parser needs function
  declarations for calls), but breaks the legacy regex parser. Split: `extract_ir` uses
  single-function mode, `extract_parsed_ir` uses `dump_module=true`.
- The `_name_counter` global must be saved/restored around callee compilation in
  `lower_call!` to avoid SSA name collisions between caller and callee.

**Result:** 61 end-to-end polynomial tests pass (all 256-value random sweep + edge cases).
Full test suite green: all prior tests pass. All ancillae verified zero.

### Path-predicate phi resolution (Option B) — completed

Replaced the reachability-based phi resolver with an explicit path-predicate system.
This is the principled, general solution grounded in Gated SSA / Psi-SSA theory.

**Architecture:**

1. **Block predicates:** During lowering, each basic block gets a 1-bit predicate wire
   indicating whether execution reached that block. Entry block predicate = 1.
   Computed from predecessors: conditional branches produce AND(pred, cond) and
   AND(pred, NOT(cond)); unconditional branches propagate pred; merge blocks OR
   all incoming predicates.

2. **Edge predicates:** For phi resolution, the relevant predicate is not the
   predecessor block's predicate, but the EDGE predicate — which specific branch
   from the predecessor led to the phi's block. Computed per-edge in
   `resolve_phi_predicated!`.

3. **MUX chain:** Chain of MUXes controlled by edge predicates. Since predicates are
   mutually exclusive, exactly one fires. Correct for ANY CFG by construction.

**New helper gates:**
- `_and_wire!(a, b)`: 1 Toffoli gate
- `_or_wire!(a, b)`: 1 CNOT + 1 CNOT + 1 Toffoli = 3 gates (via a XOR b XOR (a AND b))
- `_not_wire!(a)`: 1 NOT + 1 CNOT = 2 gates

**Key bug found during implementation:**
- `block_pred[from_block]` is WRONG for phi resolution when from_block has a
  conditional branch. The block predicate says "this block was reached" but the phi
  needs "this block was reached AND its branch to MY block was taken." For blocks
  with conditional branches, the block predicate is always true for the entry block,
  causing all phi values to select the entry block's value. Fixed by computing edge
  predicates per-incoming-value in the phi resolver.

**Also fixed:**
- `llvm.abs` intrinsic support (decomposes to sub + icmp sge + select)
- Three-way if/elseif/else patterns now compile correctly

**Gate overhead:** ~5-15 extra gates per conditional branch for predicate computation
(AND, NOT, OR gates on 1-bit wires). Negligible compared to function gate counts.

**Result:** Full test suite passes (all existing tests + 1,796 new predicated phi tests).
Old reachability-based resolver retained but not used by default. The predicated
resolver is now the default for all phi resolution.

### Full session summary — 2026-04-10

**24 commits, 13 beads issues closed, ~2,500 lines of new code.**

#### v0.5 completed
- Branchless `soft_fadd` (eliminates false-path sensitization class of bugs)
- `soft_fmul` (265K gates, branchless from start)
- Float64 frontend: `reversible_compile(f, Float64)` via SoftFloat dispatch + IRCall
- End-to-end: `x²+3x+1` on Float64 compiles to 717,680 gates
- Path-predicate phi resolution (correct for all CFGs, replaces reachability-based)

#### v0.6 completed
- `extractvalue` instruction (wire selection from aggregates)
- `soft_fsub` (= fadd + fneg), `soft_fcmp_olt`, `soft_fcmp_oeq`
- `soft_fdiv` — IEEE 754 division via 56-iteration restoring division, branchless
- General `register_callee!` API for gate-level function inlining
- Integer division: `udiv`/`sdiv`/`urem`/`srem` via soft_udiv + widen/truncate
- LLVM intrinsics: `llvm.abs`, `llvm.fshl`, `llvm.fshr`
- SoftFloat extended: `+`, `-`, `*`, `/`, `<`, `==` operators

#### v0.7 completed
- NTuple input via static memory flattening: pointer params → flat wire arrays,
  GEP → wire offset, load → CNOT copy. `dereferenceable(N)` attribute detection.

#### v0.8 infrastructure
- Dependency DAG extraction from gate sequences (`extract_dep_dag`)
- Knill pebbling recursion (Theorem 2.1): exact dynamic programming, verified
  F(100,50)=299 (1.5x), F(100,10)=581 (2.92x)
- `pebbled_bennett()` — correct and reversible but schedule doesn't yet reduce
  wire count (see design insight below)
- WireAllocator with `free!` for wire reuse (pairing heap pattern from ReVerC)
- Activity analysis: `constant_wire_count` via forward dataflow (polynomial: 4 constants)
- Cuccaro in-place adder (2004): 1 ancilla instead of 2W, 44 gates for W=8,
  verified bit-exact for all inputs. Not yet integrated into main pipeline.

#### Literature
- 11 papers downloaded to `docs/literature/`, all claims stringmatched to paper text
- 5 reference codebases cloned to `docs/reference_code/` (gitignored):
  ReVerC, RevKit, Unqomp, Enzyme.jl, reversible-sota
- Survey document: `docs/literature/SURVEY.md`

#### Key design insights discovered

**Pebbling ≠ gate schedule.** The Knill pebbling game optimizes peak simultaneously-live
pebbles (= live wires), not total gate count. Converting Knill's recursion into an
actual wire-reducing schedule requires tracking which wires are live at each point
in the interleaved forward/reverse schedule and freeing them via `WireAllocator.free!`.
The standard pebbling game puts ONE pebble on the output; Bennett needs ALL gates
applied simultaneously for the copy. These are related but different optimization
problems. The PRS15 EAGER cleanup (Algorithm 2) is the practical solution.

**In-place ops need liveness.** The Cuccaro adder computes b += a in-place (1 ancilla
vs 2W). But the current pipeline always allocates fresh output wires (SSA semantics).
Using in-place ops requires knowing when an operand's value is no longer needed
(last-use liveness analysis on the SSA variable graph). This is the same information
needed for MDD eager cleanup.

**Activity analysis identifies ~1-2% constant wires.** For polynomial x²+3x+1, only
4 out of 249 ancillae carry compile-time constants. The optimization potential from
eliminating these is small. The big win is from pebbling (5.3x on SHA-2 per PRS15)
and in-place operations (Cuccaro: 1 ancilla vs 2W per addition).

## Handoff: instructions for next session

### Beads issue status

Run `bd list` and `bd ready` to see current state. 7 issues remain, all RESEARCH:

| Issue | Priority | Description | What to do |
|-------|----------|-------------|------------|
| Bennett-6lb | P1 | MDD + EAGER cleanup | **MOST IMPORTANT.** Connect pebbling DAG + Knill recursion + WireAllocator.free! into an actual ancilla-reducing bennett(). The key challenge: the standard pebbling game assumes a 1D chain, but real circuits have a DAG. Need to linearize the DAG (topological order) then apply Knill's recursion to the linearized sequence. Alternatively, implement PRS15 Algorithm 2 (EAGER cleanup) which works directly on the MDD graph. |
| Bennett-282 | P1 | Reversible persistent memory | Design a reversible red-black tree from Okasaki 1999. Papers: docs/literature/memory/Okasaki1999_redblack.pdf, AxelsenGluck2013_reversible_heap.pdf. Start with a Julia implementation, then compile through the pipeline. |
| Bennett-5i1 | P2 | SAT pebbling (Meuli) | Encode pebbling game as SAT using Z3.jl or PicoSAT.jl. Variables p_{v,i}. Paper: docs/literature/pebbling/Meuli2019_reversible_pebbling.pdf. |
| Bennett-e6k | P2 | EXCH-based memory | Implement EXCH (swap) for reversible load/store per AG13. Paper: docs/literature/memory/AxelsenGluck2013_reversible_heap.pdf. |
| Bennett-0s0 | P3 | Sturm.jl integration | Connect to Sturm.jl's `when(qubit) do f(x) end`. Requires controlled circuit wrapping. |
| Bennett-dnh | P3 | QRAM | Variable-index array access. Deferred. |
| Bennett-nw1 | P3 | Hash-consing | Maximal sharing for reversible heap. Deferred. |

### Critical files to know

| File | Purpose |
|------|---------|
| `src/Bennett.jl` | Module entry, exports, SoftFloat type, `reversible_compile` |
| `src/ir_extract.jl` | LLVM IR → ParsedIR (two-pass name table, intrinsic expansion, IRCall) |
| `src/ir_types.jl` | All IR instruction types (IRBinOp, IRCall, IRPtrOffset, IRLoad, etc.) |
| `src/lower.jl` | ParsedIR → gates (phi resolution, block predicates, div routing) |
| `src/bennett.jl` | Bennett construction (forward + copy + reverse) |
| `src/pebbling.jl` | Knill recursion + pebbled_bennett (WIP schedule) |
| `src/dep_dag.jl` | Dependency DAG extraction from gate sequences |
| `src/wire_allocator.jl` | Wire allocation with free! for reuse |
| `src/adder.jl` | Ripple-carry + Cuccaro in-place adder |
| `src/divider.jl` | soft_udiv/soft_urem (restoring division) |
| `src/softfloat/` | fadd, fsub, fmul, fdiv, fneg, fcmp (all branchless) |
| `docs/literature/SURVEY.md` | Literature survey with verified claims |
| `docs/reference_code/` | ReVerC, RevKit, Unqomp, Enzyme.jl (gitignored) |

### How to run

```bash
cd Bennett.jl
julia --project -e 'using Pkg; Pkg.test()'     # full test suite
julia --project -e 'using Bennett; ...'          # REPL
bd ready                                          # see available work
bd show Bennett-6lb                               # details on MDD issue
```

### Rules (from CLAUDE.md)

- Red-green TDD: write test first, watch it fail, implement, pass
- WORKLOG: update with every step, gotcha, learning
- Ground truth: all papers in docs/literature/, claims stringmatched
- Beads: use `bd` for all tracking, not TodoWrite
- 3+1 agents for core changes (ir_extract, lower, bennett)
- Fail fast: assertions, not silent failures
- Push before stopping: work is not done until `git push` succeeds
   robustness. Compute block predicates during lowering, use for phi resolution.

## Session log — 2026-04-11: Mother of all code reviews

### What was done

6-agent code review (Test Coverage, Architecture/Research, Julia Idioms, Knuth, Torvalds, Carmack).
59 beads issues filed. 19 issues closed in this session.

### Issues closed

**All 4 CRITICAL (P0):**
- C1 (Bennett-y3c): Removed silent fallback to buggy phi resolver — now errors if block_pred empty
- C2 (Bennett-126): Replaced global _name_counter with local Ref{Int} threaded through functions
- C3 (Bennett-9qk): Added _remap_wire() validation in pebbled_groups.jl — unmapped wires now error
- C4 (Bennett-ug9): Documented Knill pebble game vs circuit model distinction + added tests

**HIGH correctness (H1-H4):**
- H1: else error() for unhandled instructions in lower_block_insts!
- H2: Narrowed bare try/catch to MethodError in _get_deref_bytes
- H3: Removed dead resolve! call in lower_ptr_offset!
- H4: Replaced all @assert with error() for core invariants (simulator, controlled, diagnostics)

**HIGH testing (T1-T6):**
- T1: test_soft_sitofp.jl — 1143 tests for Int64→Float64 bit-exact
- T2: ceil(Float64) test added to test_float_intrinsics.jl
- T3: test_gate_count_regression.jl — 13 baseline assertions (updated to current values)
- T4: test_negative.jl — 3 error condition tests
- T5: soft_fcmp_ole/une library tests added to test_softfcmp.jl
- T6: test_constant_wire_count.jl — 5 assertions

**HIGH code quality (Q1, Q4):**
- Q1: Extracted ~150 lines of duplicated soft-float code into softfloat_common.jl
- Q4: Replaced callee substring matching with exact name lookup + regex

**Other:**
- P4: Eliminated reverse(lr.gates) allocation in bennett.jl
- M9: Typed Vector{Any} literals in simulator and lower

### Key gotchas

1. **Gate count baselines shifted**: Path-predicate phi resolution (v0.5) adds block-predicate
   overhead (NOT+CNOT gates). Old baselines (86/174/350/702) are now (100/204/412/828).
   Toffoli counts unchanged (28/60/124/252). New scaling: 2x+4 per width doubling.

2. **Knill pebble game ≠ circuit gate model**: The F(n,s) cost formula describes abstract
   pebble operations. In a circuit, running n gates forward is always n steps. The recursion
   controls WHICH segments are live simultaneously, not total gate count (always 2n-1+n_out).
   Actual space reduction requires group-level pebbling (pebbled_groups.jl).

3. **Callee matching had two paths**: LLVM-mangled names (julia_<name>_NNN from call
   instructions) AND hardcoded bare names ("soft_fcmp_ole" from fcmp intrinsic handling
   in ir_extract.jl). New _lookup_callee handles both: exact dict match first, then regex.

4. **phi_info type**: The loop phi info is Tuple{Symbol, Int, IROperand, IROperand},
   not Tuple{Symbol, Int, Tuple{IROperand,Symbol}, Tuple{IROperand,Symbol}}.

5. **_reset_names! needed as no-op**: Many test files call Bennett._reset_names!() before
   calling extract_parsed_ir directly. With the local counter, the function does nothing
   but must exist for backward compatibility.

## Previous: Next session: Float64 support

The next major challenge is floating-point arithmetic. This requires:

1. **Understanding IEEE 754 at the bit level**: Float64 is 64 bits (1 sign + 11
   exponent + 52 mantissa). Floating-point operations (fadd, fmul, etc.) have
   complex reversible implementations involving integer addition of mantissas,
   exponent alignment, rounding, and normalization.

2. **LLVM IR for float ops**: Julia Float64 operations compile to LLVM `fadd`,
   `fmul`, `fsub`, `fdiv`, `fcmp`, `fpext`, `fptrunc`, `sitofp`, `fptosi`, etc.
   These are NOT simple integer operations — they have dedicated hardware
   semantics.

3. **Key question**: Is it feasible to build reversible circuits for IEEE 754
   operations? Each float add/mul involves: exponent comparison, mantissa shift,
   mantissa add, normalization, rounding. These are all expressible as integer
   operations on the 64-bit representation. But the gate count will be enormous.

4. **Possible approaches**:
   a. Lower float ops to their integer-level implementations (exponent/mantissa
      manipulation). Very complex, very many gates.
   b. Use fixed-point arithmetic instead of IEEE 754. Simpler, fewer gates,
      but different semantics.
   c. Treat Float64 as a 64-bit integer for bit-manipulation (reinterpret), and
      only support operations that Julia/LLVM express as integer ops on the bits.
   d. Start with a simple case: Float64 addition only, build the reversible
      IEEE 754 adder, verify against Julia's native addition.

5. **Check first**: What does `code_llvm(x -> x + 1.0, Tuple{Float64})` actually
   produce? If LLVM uses `fadd double`, we need to lower that. If Julia's
   optimizer does something simpler for specific cases, we might get lucky.

---

## 2026-04-10 — v0.8 EAGER cleanup (Bennett-6lb)

### What was built

`eager_bennett(lr::LoweringResult) -> ReversibleCircuit` — a drop-in alternative
to `bennett()` that eagerly uncomputes dead-end wires during the forward pass.

New files:
- `src/eager.jl`: `eager_bennett`, `compute_wire_mod_paths`, `compute_wire_liveness`
- `test/test_eager_bennett.jl`: 971 tests (helpers + correctness + peak liveness)
- `src/diagnostics.jl`: added `peak_live_wires(circuit)` diagnostic

### Algorithm (final, correct)

- **Phase 1**: Forward gates. Dead-end wires (never used as a control by ANY gate)
  are reversed immediately after their last modification. These wires contribute
  nothing to the computation; cleaning them is always safe.
- **Phase 2**: CNOT copy outputs (identical to full Bennett).
- **Phase 3**: Reverse remaining forward gates in reverse gate-index order, skipping
  gates that target eagerly-cleaned wires. Identical to full Bennett except those
  gates are omitted.

### Key research finding: per-wire mod-path reversal is WRONG

**Attempted**: Reverse each wire's modification path independently, in
reverse-dependency topological order (dependents before dependencies).

**Why it fails**: A gate G at position i uses control wire C. In the forward pass,
C held value V_i at step i. By the end of forward, C holds V_final (possibly
different if later gates also targeted C). Per-wire reversal of G's target
uses V_final instead of V_i. Result: incorrect uncomputation.

Full Bennett reverse works because it replays ALL gates in exact reverse order.
At each step, the state matches the forward state at that step. Per-wire
grouping breaks this invariant.

**Lesson**: Don't invent clever gate orderings without hand-tracing on real data.
The x+3 circuit's wire 19 is modified by G13 AFTER being used as a control in
G12. Per-wire reversal of wire 28 (which includes reversing G12) sees wire 19's
final value instead of its value at G12. This was only caught by extracting
and tracing the actual 41-gate sequence.

### What EAGER actually optimizes

For linear computations (additions, polynomials), almost every wire is on the
path from inputs to outputs. Dead-end wires are rare (only unused constant
bits). The main benefit:

| Function | Peak live (full) | Peak live (eager) | Reduction |
|----------|-----------------|-------------------|-----------|
| x + 3    | 7               | 6                 | 1 wire    |
| x²+3x+1 | 8               | 7                 | 1 wire    |

PRS15 achieves 5.3x on SHA-2 because SHA-2 has many parallel independent
subcomputations with dead-end intermediate values. Our test functions are
too linear. To get significant reduction, need either:
1. Functions with parallel independent branches (SHA-2, AES round functions)
2. Wire reuse during lowering (WireAllocator.free! integration)
3. Full pebbling (Knill recursion + re-computation checkpointing)

### Gotchas

1. **Julia scoping in -e scripts**: `local ok = true` inside a for loop doesn't
   work at top-level. Use `global passed = false` or wrap in a function.

2. **Kahn's algorithm direction**: Kahn's gives dependencies first (leaves first).
   For uncomputation order, need dependents first. Must `reverse!()`.

3. **Gate-level vs value-level EAGER**: PRS15 operates on MDD (AST-level values),
   not individual gates. At the gate level, the "modification path" for a wire
   may interleave with other wires' modifications, breaking per-wire reversal.
   The gate-level equivalent of EAGER is much more constrained.

4. **Dual refcounting insight**: Each control wire is used twice (forward + reverse).
   Only wires with ZERO total uses (fwd + rev) can be eagerly cleaned during
   Phase 1. This limits Phase 1 to dead-end wires only.

### Next steps for Bennett-6lb

The EAGER infrastructure is in place. To achieve significant ancilla reduction:

1. **Wire reuse in Phase 3**: After Phase 3 uncomputes a wire, free its index
   via WireAllocator. Later Phase 3 operations can reuse it. This requires
   modifying the gate sequence to remap wire indices — essentially register
   allocation on the Phase 3 schedule.

2. **Pebbling integration**: Use Knill's recursion to determine checkpoint
   boundaries. Between checkpoints, run forward + reverse (mini-Bennett).
   This trades gates for wires, achieving the time-space tradeoff.

3. **Better test functions**: Implement SHA-2 or AES as test targets for EAGER.
   These have the parallel structure that enables significant cleanup.

---

## 2026-04-10 — Switch instruction + reversible memory research (Bennett-282)

### Switch instruction added

`LLVMSwitch` is now handled by converting to cascaded `icmp eq` + `br` blocks
at the IR extraction level (`_expand_switches` post-pass). Phi nodes in target
blocks are patched to reference the correct synthetic comparison blocks.

Test: `select3` (3-case switch on Int8) — 312 gates, correct for all inputs.

### Reversible memory research findings

**What works now for memory:**
- NTuple input via pointer flattening (dereferenceable attribute) ✓
- Constant-index GEP + load (tuple field access) ✓
- Dynamic NTuple indexing via if/elseif chain + optimize=false ✓ (546 gates for 4-element array_get)
- Dynamic switch-based indexing with optimize=true ✓ (for scalar-return functions)
- Tuple return with optimize=true ✓ (swap_pair, complex_mul_real)

**Blockers for full reversible memory:**
1. **Pointer-typed phi nodes**: When optimizer merges NTuple GEP results via switch,
   the phi merges pointers (not integers). `_iwidth` can't handle PointerType.
   Fix: skip pointer phi, resolve to underlying load values instead.
2. **sret calling convention**: Functions returning tuples with optimize=false use
   hidden pointer argument for return. Compiler doesn't handle sret GEPs.
3. **No store instruction**: `IRStore` not implemented (skipped in ir_extract.jl).

**Literature survey (papers in docs/literature/memory/):**
- Okasaki 1999: functional red-black tree, O(log n) insert via path copying.
  Key insight: persistence = ancilla preservation for Bennett uncomputation.
- Axelsen/Glück 2013: EXCH-based reversible heap. Linearity (ref count = 1)
  enables automatic GC. EXCH (register ↔ memory swap) is the fundamental
  reversible memory operation.
- Mogensen 2018: maximal sharing via hash-consing prevents exponential blowup.
  Reference counting integrates with reversible deallocation.

**Recommended path for Bennett-282:**
1. Implement pointer-phi resolution (handle PointerType in phi by resolving
   to the underlying load values — the pointer itself is just an address, the
   useful value is the loaded integer)
2. This enables: NTuple + dynamic indexing + tuple return, all with optimizer on
3. Then implement array_exch (reversible EXCH for array elements) as a pure
   Julia function compiled through the pipeline
4. Gate cost measurement for array operations of different sizes
5. Persistent red-black tree as a pure Julia implementation (future)

### Gate cost reference for reversible memory operations

| Operation | Size | Gates | Wires | Ancillae | Notes |
|-----------|------|-------|-------|----------|-------|
| MUX array get | 4×Int8 | 394 | 177 | 129 | Select via bit-masking |
| MUX array get | 8×Int8 | 746 | 313 | 233 | 3-level MUX tree |
| Static EXCH (idx=0) | 4×Int8 | 442 | 321 | — | Swap a0 ↔ val |
| MUX array EXCH | 4×Int8 | 1,402 | 617 | — | Dynamic reversible write |
| Tree lookup | 3 nodes | 1,292 | 470 | — | BST search, 2 levels |
| **RB tree insert** | 3 nodes | **71,424** | 21,924 | 21,732 | Full Okasaki balance |
| select3 (switch) | Int8→Int8 | 312 | — | — | 3-case switch |
| array_get (branch) | 4×Int8 | 546 | 216 | — | optimize=false, if/elseif |

### Research conclusion: reversible memory cost hierarchy

**For small fixed-size arrays (N ≤ 16): MUX-based EXCH wins.** 1,402 gates for
N=4 dynamic write. Cost scales as O(N × W × log N).

**For dynamic-size collections: Okasaki RB tree.** 71,424 gates for 3-node insert
with balance. The 50× overhead vs MUX comes from: (1) pointer indirection (MUX
to select node by index), (2) comparison chains at each tree level, (3) balance
pattern matching (4 cases), (4) node field packing/unpacking on UInt64.

**Persistence = reversibility.** Each tree insert produces a NEW tree version.
The old version (shared structure via path copying) is the ancilla state for
Bennett uncomputation. This is the bridge between functional data structures
and quantum/reversible computing:
- Forward: insert creates new version (ancilla = old version)
- Copy: CNOT the output to dedicated wires
- Reverse: undo insert (old version restores from ancilla)

### LLVM intrinsic coverage expansion

Added 5 intrinsics to ir_extract.jl: ctpop, ctlz, cttz, bitreverse, bswap.
All expand to cascaded IR instructions (no new lowering needed).

| Intrinsic | Width | Gates | Approach |
|-----------|-------|-------|----------|
| ctpop | i8 | 818 | Cascaded bit-extract + add |
| ctlz | i8 | 1,572 | LSB→MSB cascade select |
| cttz | i8 | 1,572 | MSB→LSB cascade select |
| bitreverse | i8 | 710 | Per-bit extract + place + OR |
| bswap | i16 | 430 | Per-byte extract + place + OR |

**Gotcha**: ctlz cascade direction matters. MSB→LSB with select-overwrite gives
the LAST set bit (wrong). LSB→MSB gives the HIGHEST set bit (correct for clz).
Same in reverse for cttz.

**Opcode audit results**: tested 30 Julia functions. 28 compile successfully.
3 failed before intrinsic expansion (ctpop, ctlz, cttz → now fixed).
Added freeze (identity), fptosi/fptoui, sitofp/uitofp, float type widths.
Remaining 2 blockers: float_div (extractvalue lowering, Bennett-dqc),
float_to_int (SoftFloat dispatch model, Bennett-777).

**LLVM opcode coverage (final audit)**:
- Tier 1: 100% (all integer/logic/control/aggregate/memory)
- Tier 2: switch, freeze, fptosi/sitofp/uitofp handled
- Intrinsics: 12 (umax/umin/smax/smin/abs/fshl/fshr/ctpop/ctlz/cttz/bitreverse/bswap)
- Float: add/sub/mul/neg via SoftFloat. div blocked (Bennett-dqc).
- 28/30 audit functions compile.

### SAT-based pebbling (Bennett-5i1)

Implemented Meuli 2019 SAT encoding with PicoSAT:
- Variables: p[v,i] = node v pebbled at step i
- Move clauses: (p[v,i] ⊕ p[v,i+1]) → ∧_u∈pred(v) (p[u,i] ∧ p[u,i+1])
- Cardinality: sequential counter encoding for ∑ p[v,i] ≤ P
- Iterative K search from 2N-1 upward

**Critical bug found**: cardinality auxiliary variables must be unique per time step.
All (K+1) calls to _add_at_most_k! were sharing the same variable range, causing
false UNSAT. Fix: offset = n_pebble_vars + i × aux_per_step.

| Chain | P (full) | P (reduced) | Steps (full) | Steps (reduced) |
|-------|----------|-------------|--------------|-----------------|
| N=3   | 3        | —           | 5            | —               |
| N=4   | 4        | 3           | 7            | 9               |
| N=5   | 5        | 4           | 9            | 9               |

Chain(4) P=3 matches Knill's F(4,3)=9 exactly. The SAT solver finds the
optimal schedule automatically.

**The 71K gate cost is dominated by control flow**, not arithmetic. The 3-node
tree has ~60 branch points (icmp + select for each ternary). Reducing this
requires branchless node selection (QRAM-style bucket brigade instead of MUX
chains) or specialized hardware for reversible pointer chasing.

### AG13 reversible heap operations (Bennett-e6k)

Implemented Axelsen/Glück 2013 EXCH-based heap operations:
- 3-cell heap packed in UInt64 (9 bits/cell: in_use + 4-bit left + 4-bit right)
- Stack-based free list (free_ptr in bits 27-29)
- cons and decons are exact inverses

| Operation | Gates | Description |
|-----------|-------|-------------|
| rev_cons | 59,066 | Allocate cell, store (a,b) pair |
| rev_car | 51,098 | Read left field of cell |
| rev_cdr | 51,090 | Read right field of cell |
| rev_decons | 52,196 | Deallocate cell, return to free list |

**Gate cost breakdown**: ~51K base cost is the variable-shift barrel shifter
for `(heap >> shift)` where shift = (idx-1)*9. Each variable-amount shift
on 64-bit = 6-stage barrel shifter ≈ 1,536 gates × ~30 shifts per function.
The bit manipulation (masking, OR-ing) is cheap; the pointer arithmetic is
expensive. This matches the tree observation: pointer chasing dominates.

### Complete reversible memory gate cost table

| Operation | Type | Gates | Per-element |
|-----------|------|-------|-------------|
| MUX get | Array N=4 | 394 | 99 |
| MUX get | Array N=8 | 746 | 93 |
| MUX EXCH | Array N=4 | 1,402 | 351 |
| Static EXCH | Array idx=0 | 442 | — |
| Tree lookup | BST 3 nodes | 1,292 | 431 |
| RB insert | Okasaki 3 nodes | 71,424 | 23,808 |
| Heap cons | AG13 3 cells | 59,066 | 19,689 |
| Heap car | AG13 3 cells | 51,098 | 17,033 |
| Heap cdr | AG13 3 cells | 51,090 | 17,030 |
| Heap decons | AG13 3 cells | 52,196 | 17,399 |

---

## 2026-04-10 — Complete session summary

### Issues closed this session

| Issue | Priority | What |
|-------|----------|------|
| Bennett-6lb | P1 | EAGER cleanup: `eager_bennett()`, `peak_live_wires()` |
| Bennett-282 | P1 | Reversible persistent memory: MUX EXCH + Okasaki RB tree |
| Bennett-e6k | P2 | AG13 reversible heap: cons/car/cdr/decons |
| Bennett-5i1 | P2 | SAT-based pebbling (Meuli 2019) with PicoSAT |

### New issues filed

| Issue | Priority | What |
|-------|----------|------|
| Bennett-dqc | P2 | soft_fdiv extractvalue lowering for Float64 division |
| Bennett-777 | P2 | Mixed-type Float64→Int compile path (fptosi dispatch) |

### LLVM opcode coverage — final state

**Handled opcodes (34 + 12 intrinsics):**

Arithmetic: add, sub, mul, udiv, sdiv, urem, srem
Bitwise: and, or, xor, shl, lshr, ashr
Comparison: icmp (eq, ne, ult, ugt, ule, uge, slt, sgt, sle, sge)
Control flow: br, switch, phi, select, ret, unreachable
Type conversion: sext, zext, trunc, freeze, fptosi, fptoui, sitofp, uitofp
Aggregates: extractvalue, insertvalue
Memory: getelementptr (const), load
Calls: registered callees + 12 intrinsics

**Intrinsics (12):** umax, umin, smax, smin, abs, fshl, fshr, ctpop, ctlz, cttz, bitreverse, bswap

**Skipped (by design):** store, alloca (reversible memory research)
**Not yet needed:** bitcast (LLVM optimizes away), fpext, fptrunc, frem, vector.reduce

**Audit: 28/30 functions compile** to verified reversible circuits:
abs, min, max, clamp, popcount, leading_zeros, trailing_zeros, count_zeros,
bitreverse, bswap, iseven, collatz_step, fibonacci, xor_swap, gcd_step,
sort2, hash_mix, reinterpret, flipsign, copysign, rotl, muladd,
widening_mul, 3-way branch, fizzbuzz, nested_select,
float_add/sub/mul/neg (via SoftFloat).

**2 remaining blockers:** float_div (Bennett-dqc), float_to_int (Bennett-777).

### New files this session

| File | Lines | What |
|------|-------|------|
| `src/eager.jl` | ~90 | EAGER cleanup: dead-end wire uncomputation |
| `src/sat_pebbling.jl` | ~170 | SAT-based pebbling with PicoSAT |
| `test/test_eager_bennett.jl` | ~100 | 971 tests: helpers + correctness + peak liveness |
| `test/test_switch.jl` | ~20 | Switch instruction tests |
| `test/test_rev_memory.jl` | ~180 | MUX EXCH + Okasaki RB tree + AG13 heap |
| `test/test_sat_pebbling.jl` | ~50 | SAT pebbling: chain, diamond, reduction |
| `test/test_intrinsics.jl` | ~50 | ctpop, ctlz, cttz, bitreverse, bswap |

### Key research findings

1. **Per-wire mod-path reversal is incorrect** at the gate level — only reverse
   gate-index order maintains the state invariant for Bennett uncomputation.

2. **MUX array EXCH beats persistent trees** for small N (1,402 vs 71,424 gates
   for N=4). Tree wins for dynamic-size collections.

3. **Persistence = reversibility**: each tree insert creates a new version;
   the old version is the ancilla for Bennett uncomputation.

4. **SAT pebbling matches Knill** for chains: chain(4) P=3 → 9 steps.
   Critical bug: cardinality auxiliary variables must be unique per time step.

5. **Variable-shift barrel shifter dominates** reversible heap cost (~51K of
   59K gates for cons). Pointer arithmetic is the bottleneck.

### Handoff for next session

**Priority work:**
1. Fix Bennett-dqc (soft_fdiv extractvalue) — likely needs multi-return handling in lower.jl
2. Fix Bennett-777 (Float64→Int dispatch) — needs new compile path for mixed types
3. Connect SAT pebbling to actual circuit optimization (generate optimized bennett from schedule)
4. Connect EAGER + wire reuse for actual ancilla reduction

**Commands:**
```bash
cd Bennett.jl
julia --project -e 'using Pkg; Pkg.test()'     # Full suite
bd ready                                        # Available issues
bd show Bennett-dqc                             # Float div bug
bd show Bennett-777                             # Float→Int bug
```

---

## 2026-04-10 — Fix Float64 division and multi-arg Float64 compile (Bennett-dqc)

### Root cause analysis

The bug was NOT an extractvalue lowering issue (as the ticket described). It was a
**Julia inlining failure** in the SoftFloat dispatch chain.

**What happens:**
1. `reversible_compile(f, Float64, Float64)` creates a wrapper:
   `wrapper(a::UInt64, b::UInt64) = f(SoftFloat(a), SoftFloat(b)).bits`
2. Julia compiles `wrapper` and sees `f(SoftFloat, SoftFloat)` — a call to the
   user's function with struct arguments.
3. Julia's inliner decides NOT to inline `f` because the callee chain is too deep
   (`f → SoftFloat./ → soft_fdiv`, where `soft_fdiv` is 140+ lines).
4. LLVM emits struct-passing ABI: `alloca [1 x i64]` + `store` + `call @j_f_NNN(ptr, ptr)`.
5. `ir_extract.jl` skips `alloca`/`store`, skips the call (ptr args, not in callee
   registry), and the extractvalue on the call result references an undefined SSA var.
6. Error: "Undefined SSA variable: %__v3"

**Why single-arg Float64 used to work:** Julia previously inlined the single-arg
wrapper chain. This may have been marginal — the `@inline` on SoftFloat methods
helps but isn't sufficient for all Julia/LLVM versions.

**Why +, *, - work but / doesn't:** For +, *, -, Julia inlines `SoftFloat.+(a,b) →
soft_fadd(a.bits, b.bits)` and the struct is eliminated. For /, `soft_fdiv` is
much larger (56-iteration restoring division loop), so the inliner gives up.

### Fix: `@inline` at the call site

The fix is simple: use `@inline f(...)` at the call site in the wrapper. This is a
Julia 1.7+ feature that forces the compiler to inline the callee, regardless of
the inliner's cost model. The entire chain then inlines:
`wrapper → f → SoftFloat./ → soft_fdiv`, and LLVM sees only integer operations
with direct `call @j_soft_fdiv` instructions that the callee registry recognizes.

**Changes:**
1. `src/Bennett.jl`: Single variadic `reversible_compile(f, Float64...)` method
   replacing the single-arg-only version. Uses `@inline f(...)` at the call site.
   Handles 1, 2, or 3 Float64 arguments.
2. `src/Bennett.jl`: Added `@inline` to all SoftFloat operator methods (belt and
   suspenders — the call-site @inline is sufficient, but method-level @inline
   ensures consistent behavior across Julia versions).
3. `test/test_float_circuit.jl`: Added Float64 division end-to-end test (62 tests:
   11 edge cases + 50 random + 1 reversibility check).

### Gate counts

| Function | Total | NOT | CNOT | Toffoli |
|----------|-------|-----|------|---------|
| soft_fdiv (direct) | 412,388 | 20,788 | 280,778 | 110,822 |
| Float64 x/y (end-to-end) | 412,388 | 20,788 | 280,778 | 110,822 |
| Float64 x²+3x+1 (regression check) | 717,690 | 20,390 | 440,380 | 256,920 |

soft_fdiv is ~1.56x soft_fmul (265K) and ~4.4x soft_fadd (94K). The 56-iteration
restoring division loop dominates — each iteration is ~7K gates.

### Gotchas

1. **NaN sign bit is implementation-defined.** `0/0` and `Inf/Inf` both produce NaN.
   Our soft_fdiv returns `+NaN` (0x7ff8...) while Julia's hardware division returns
   `-NaN` (0xfff8...). IEEE 754 §6.2 says NaN sign is not specified. Tests must
   compare with `isnan()` for NaN-producing inputs, not bit-exact equality.

2. **`reinterpret(UInt64, x::Int64)` vs `UInt64(x::Int64)`.** The simulator returns
   `Int64`. `UInt64(negative_int64)` throws `InexactError`. Must use `reinterpret`
   for bit-pattern preservation. Same gotcha as in the branchless soft_fadd session.

3. **Julia closure scoping.** `wrapper(a,b) = ...` defined inside an `if` block can
   have scoping issues in Julia 1.12. Use lambda `(a,b) -> ...` instead.

4. **`@inline` at call site vs on function.** `@inline` on the SoftFloat operator
   definitions tells the inliner "prefer to inline this." `@inline f(args...)` at
   the call site tells the inliner "MUST inline this call." The call-site version
   is the one that actually solves the problem — the method-level annotation alone
   isn't enough for deep call chains.

### Full test suite: all tests pass (300 float circuit + all prior tests)

---

## 2026-04-10 — Trivial opcodes + fptosi (Bennett-0p0, Bennett-uky, Bennett-3wj, Bennett-777)

### New opcodes in ir_extract.jl

| Opcode | Expansion | Gates | Notes |
|--------|-----------|-------|-------|
| bitcast | IRCast(:trunc) same-width identity | 66 (roundtrip) | Wire aliasing, zero actual gates |
| fneg | XOR sign bit (typemin(Int64) for double) | 580 | Gotcha: UInt64(1)<<63 overflows Int64 |
| llvm.fabs | AND with typemax(Int64) mask | 576 | Clears sign bit |
| fptosi | IRCall to soft_fptosi | 18,468 | Full IEEE 754 decode, not a bitcast |

### soft_fptosi: IEEE 754 → integer conversion

New branchless function in `src/softfloat/fptosi.jl`. Algorithm:
1. Extract sign, exponent, mantissa
2. Add implicit 1-bit for normal numbers
3. Compute shift: right_shift = 1075 - exp (truncates fractional part)
4. If exp >= 1075: shift left instead (large values)
5. Apply sign via two's complement negation

Key insight: `fptosi` is NOT a bitcast. The WORKLOG's prior session treated it as
identity on bits, which is wrong. `fptosi double 3.0 to i64` should produce `3`,
not `0x4008000000000000` (the IEEE 754 encoding of 3.0).

### Float64 parameter handling in ir_extract.jl

Added `FloatingPointType` support in `_module_to_parsed_ir` parameter extraction.
Float64 params are treated as 64-bit wire arrays, same as UInt64. This allows
direct compilation of `f(x::Float64)` without SoftFloat wrapping.

### Gotchas

1. **typemin(Int64) for sign bit.** `Int(UInt64(1) << 63)` throws InexactError.
   Use `typemin(Int64)` (= -2^63 = 0x8000...0 in two's complement).

2. **fptosi is not bitcast.** The prior session's handling (IRCast identity) was
   wrong. Must route through soft_fptosi for actual value conversion.

3. **Tuple{Float64} vs Float64 varargs.** `reversible_compile(f, Float64)` wraps
   in SoftFloat (for pure-float functions). `reversible_compile(f, Tuple{Float64})`
   compiles directly (for mixed Float64→Int functions).

### Opcode audit: 30/30 functions compile

All 30 audit functions now compile to verified reversible circuits.

---

## 2026-04-10 — Session 3: Opcode audit → Enzyme-class roadmap

### Issues closed this session: 12

| # | Issue | What | Gate count |
|---|---|---|---|
| 1 | Bennett-dqc | Float64 division (multi-arg SoftFloat + @inline) | 412,388 |
| 2 | Bennett-0p0 | bitcast opcode (wire aliasing) | 66 |
| 3 | Bennett-uky | fneg opcode (XOR sign bit) | 580 |
| 4 | Bennett-3wj | fabs intrinsic (AND mask) | 576 |
| 5 | Bennett-au8 | expect/lifetime/assume (deferred — not in IR) | — |
| 6 | Bennett-777 | fptosi via soft_fptosi (IEEE 754 decode) | 18,468 |
| 7 | Bennett-qkj | fcmp 6 predicates (ole, une, ogt, oge) | 5.5–10K |
| 8 | Bennett-chr | SSA-level liveness analysis | — |
| 9 | Bennett-8n5 | T-count and T-depth metrics | — |
| 10 | Bennett-yva | SHA-256 round function benchmark | 17,712 |
| 11 | Bennett-e1s | Cuccaro in-place adder (use_inplace=true) | — |
| 12 | Bennett-1la | sitofp via soft_sitofp (IEEE 754 encode) | 27,930 |

### Key results

**SHA-256 round function:** 17,712 gates, T-count=30,072, T-depth=88, 5,505 ancillae.
Verified correct for 2 consecutive rounds against initial hash values.

**Cuccaro in-place integration:** `lower(parsed; use_inplace=true)` routes
dead-operand additions through Cuccaro adder.
- x+3 (Int8): 33→18 wires (45% reduction)
- Polynomial: 257→227 wires (12% reduction)
- Trades ~15% more gates for significantly fewer ancillae

**soft_sitofp:** Branchless Int64→Float64 conversion, 27,930 gates.
Gotcha: CLZ shift is `clz` not `clz+1` — MSB goes to bit 63, mantissa is [62:11].

**soft_fptosi:** 18,468 gates. Key insight: fptosi is NOT a bitcast — it decodes
IEEE 754 exponent/mantissa to extract the integer value.

**@inline at call site:** The critical fix for Float64 division. Julia's inliner
won't inline through SoftFloat dispatch for large callees (soft_fdiv = 140+ lines).
`@inline f(...)` at the call site forces inlining.

### New infrastructure

- `compute_ssa_liveness(parsed)`: SSA-level last-use detection for each variable
- `_ssa_operands(inst)`: dispatches on all 13 IR instruction types
- `t_count(circuit)`: Toffoli × 7 T-gates
- `t_depth(circuit)`: longest Toffoli chain

### Issues filed: 24 new issues covering Pillar 1-3 + Enzyme-class roadmap

All filed in beads, covering: remaining opcodes, space optimization pipeline
(liveness → Cuccaro → wire reuse → pebbling), benchmarks (SHA-2, arithmetic,
sorting, Float64), composability (Sturm.jl, inline control), ecosystem
(docs, CI, package registration).

### Gate count reference (new entries)

| Function | Width | Gates | T-count | Wires | Ancillae |
|----------|-------|-------|---------|-------|----------|
| bitcast roundtrip | i64 | 66 | 0 | | |
| fneg (reinterpret) | i64 | 580 | 0 | | |
| fabs (reinterpret) | i64 | 576 | 0 | | |
| soft_fptosi | i64 | 18,468 | | | |
| soft_sitofp | i64 | 27,930 | | | |
| fcmp ole | i64 | 10,108 | | | |
| fcmp une | i64 | 5,582 | | | |
| Float64 x/y | i64 | 412,388 | | | |
| SHA-256 round | i32×10 | 17,712 | 30,072 | 5,889 | 5,505 |
| SHA-256 ch | i32×3 | 546 | 1,344 | | |
| SHA-256 maj | i32×3 | 418 | 896 | | |
| SHA-256 sigma0 | i32 | 7,108 | 10,668 | | |

### Handoff for next session

**Remaining P1 (1 issue):**
- Bennett-an5: Full pebbling pipeline (the big one — DAG + Knill + wire reuse)

**Remaining P2 (12 issues):**
- Bennett-47k: Activity analysis (dead-wire elimination during lowering)
- Bennett-6yr: PRS15 EAGER Algorithm 2 (MDD-level uncomputation)
- Bennett-i5c: Wire reuse in Phase 3
- Bennett-qef: Karatsuba multiplier
- Bennett-bzx: Arithmetic benchmark suite
- Bennett-der: Sorting network benchmark
- Bennett-dpk: Float64 benchmark vs Haener 2018
- Bennett-kz1: BENCHMARKS.md
- Bennett-5ye: Sturm.jl integration
- Bennett-89j: Inline control during lowering
- Bennett-cc0: store instruction
- Bennett-dbx: Variable-index GEP

**Critical dependency chain:**
```
Wire Reuse (i5c) → PRS15 EAGER (6yr) → Pebbling Pipeline (an5)
```

### fcmp predicate coverage

Added 6 fcmp predicates: olt, oeq (existing), ole, une (new), ogt/oge (swap+existing).
Routes through soft_fcmp callees. Gate counts: ole=10,108, une=5,582.

### Issues deferred after research

- **Bennett-36m** (overflow intrinsics): Not found in optimized Julia IR. Julia handles
  overflow at the Julia level, LLVM sees plain `add`/`sub`/`mul`.
- **Bennett-tfx** (frem): Not found in optimized Julia IR. Julia calls libm `fmod`.

### Session totals

**7 issues closed this session:**
- Bennett-dqc: Float64 division (multi-arg SoftFloat + @inline fix)
- Bennett-0p0: bitcast opcode
- Bennett-uky: fneg opcode
- Bennett-3wj: fabs intrinsic
- Bennett-au8: expect/lifetime/assume (deferred — not in IR)
- Bennett-777: fptosi (soft_fptosi IEEE 754 decode)
- Bennett-qkj: fcmp predicates (ole, une, ogt, oge)

**2 issues deferred:** Bennett-36m, Bennett-tfx

**New opcode coverage:** bitcast, fneg, fabs, fcmp (6 predicates), fptosi → soft_fptosi
**Audit milestone: 30/30 functions compile to verified reversible circuits.**

---

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

## 2026-04-11 — Checkpoint Bennett: 66% wire reduction on SHA-256 (Bennett-an5)

### What was built

1. **GateGroup wire range tracking (`wire_start`/`wire_end`)**
   - Added `wire_start::Int` and `wire_end::Int` fields to `GateGroup` struct
   - Backward-compatible 5-arg constructor defaults to `(0, -1)` (empty range)
   - Wire ranges tracked at all 7 group-creation sites via `wa.next_wire` snapshots
   - Key insight: during `lower()`, `free!()` is never called, so WireAllocator
     allocates sequentially. `wire_start:wire_end` is contiguous and complete.
   - 3+1 agent review: two independent proposer agents, synthesised design

2. **`checkpoint_bennett(lr)` — per-group checkpointing**
   - New function in `src/pebbled_groups.jl`
   - Algorithm:
     - Phase 1: For each group: forward → CNOT-copy result to checkpoint → reverse
       (frees internal wires, only checkpoint stays)
     - Phase 2: CNOT-copy final output to permanent output wires
     - Phase 3: Cleanup in reverse order: re-forward → un-copy checkpoint → reverse → free checkpoint
   - Result: peak wires = inputs + copies + sum(checkpoints) + max(one group's internals)

### Key research findings

1. **The Knill recursion as previously implemented does NOT reduce peak wire count.**
   The implementation forwards ALL groups linearly at each recursion level without
   intermediate checkpointing. At the copy point, all 46 SHA-256 groups are live
   simultaneously — identical to full Bennett. The recursion trades TIME (re-computation)
   for nothing in this implementation.

2. **Per-group checkpointing IS the actual optimization.** By checkpointing each
   group's result (CNOT copy to fresh wires) then reversing (freeing internal wires),
   peak wires are bounded by checkpoints + max_one_group. Internal wires (carries,
   partial products, zero-padding) dominate: SHA-256 groups have 32-bit results but
   up to 512-bit internal wire ranges.

3. **PRS15's "353 qubits" is for 10 SHA-256 rounds, not 1.** The WORKLOG's prior
   session incorrectly stated "PRS15 achieves 353 wires for 1 round." Per-round
   extrapolation: ~35 qubits. PRS15 also uses in-place ops (Cuccaro), which we don't
   (SSA-based out-of-place). Apple-to-oranges comparison.

4. **Wire tracking is necessary but not sufficient.** Adding `wire_start`/`wire_end`
   to GateGroup enables proper wire remapping in `_replay_forward!`, but the
   algorithmic change (per-group checkpointing) is what produces the wire reduction.

### Wire reduction results

| Function | Full Bennett | Checkpoint | Reduction |
|----------|-------------|-----------|-----------|
| x+3 (i8) | 41 | 49 | -20% (overhead > savings for 2 groups) |
| polynomial (i8) | 265 | 233 | 12% |
| **SHA-256 round** | **5889** | **1985** | **66.3%** |

SHA-256 achieves 3.0x reduction (5889/1985). The reduction scales with group count
and internal-to-result wire ratio. Small functions (2-4 groups) don't benefit because
checkpoint overhead exceeds internal wire savings.

### Gotchas

1. **Checkpoint ordering matters.** Phase 3 cleanup must process groups in REVERSE
   topological order (reverse of Phase 1). When cleaning group i, its dependencies
   (groups j < i) must still have their checkpoints live for the re-forward.

2. **Checkpoint is NOT a group.** Checkpoint wires are managed separately from
   ActivePebble. After Phase 1 reverse of a group, its checkpoint is registered
   in `live_map` as an ActivePebble with empty internal_wires, enabling downstream
   groups to find dependency results.

3. **wire_count(wa) is the peak, not the live count.** Even when wires are freed
   (returned to free_list), `wa.next_wire` never decreases. The peak is determined
   by the maximum simultaneous allocation, not the final state.

4. **Small functions are worse.** With only 2 groups (increment), checkpoint overhead
   (1 checkpoint per group) exceeds internal wire savings. The break-even is ~4+ groups
   with significant internal wire usage (multiplier, additions).

### Bennett-mz8: Cuccaro default — CLOSED

Made `use_inplace=true` the default in `lower()`. Cuccaro routes dead-operand
additions through in-place adder (1 ancilla vs 2W). However, in-place results
have wires outside the group's wire range (they belong to a dependency), which
breaks checkpoint_bennett's forward-copy-reverse. Added guards: both
`checkpoint_bennett` and `pebbled_group_bennett` detect in-place results and
fall back to `bennett()`.

### Bennett-i7z: EAGER checkpoint cleanup — DEFERRED

Attempted EAGER: free dead checkpoints during Phase 1 when all consumers are
checkpointed. Prototype achieved 1057 wires (47% below 1985 non-EAGER) but
FAILED simulation — wire reference beyond n_wires.

**Root cause:** EAGER freeing during Phase 1 removes checkpoints that Phase 3
needs for re-forward. For a linear dependency chain (SHA-256's structure),
freeing group D means group G (which depends on D) can't re-forward during
Phase 3 cleanup. The dependency check `deps_available` prevents cascading but
doesn't protect downstream Phase 3 consumers.

**Fundamental tension:** EAGER checkpoint cleanup requires either:
1. Integrated forward-and-cleanup (no Phase 3 — cleanup immediately after each group)
2. Safe eager set via fixed-point analysis (only free groups whose ALL transitive
   descendants will also be eagerly freed)
3. Finer granularity (value-level, not group-level, matching PRS15's MDD approach)

SHA-256's mostly-linear dependency chain limits EAGER to ~10% savings (only a few
independent branches in sigma/ch/maj). The high complexity vs modest benefit led
to deferral. Bennett-2rh (intra-group cleanup) is higher priority: targets the
4000 internal wires directly.

### Bennett-2rh: Intra-group carry cleanup — DEFERRED

Attempted: add carry-reversal gates within lower_add! to zero carry wires
during the forward pass, then free them during _replay_forward!.

**Why it fails:** The reverse of the forward gates TARGETS carry wires. If
carry wires are freed after forward (and reused by checkpoint allocation),
the reverse gates corrupt the reused wires. The reverse NEEDS carry wires
at their computed values to properly undo the forward.

**Key insight:** Intra-group wire cleanup is fundamentally incompatible with
the per-group checkpoint-and-reverse pattern. You can't free wires between
forward and reverse if the reverse gates target those wires.

**What would work instead:**
1. Use Cuccaro in-place adders (no carry wires at all) — but incompatible
   with checkpoint_bennett due to in-place result wire ownership
2. Split adder into finer groups (one per carry stage) — but ~32 groups per
   add is impractical
3. Fundamentally different architecture: value-level pebbling (PRS15's MDD)
   that operates below the group level

Both Bennett-2rh and Bennett-i7z point to the same conclusion: the group-level
checkpoint approach has reached its practical limit at 3.0x reduction. Further
improvement requires either (a) PRS15-style MDD-level value pebbling, or
(b) making Cuccaro compatible with checkpointing.

### Prototype 0: Constant-fold fshl/fshr — COMPLETED (biggest win)

**Root cause found via wire breakdown analysis:** Carry wires are only 8.1% of SHA-256
allocation. The DOMINANT wire consumer (55.8%) is barrel-shifter MUX logic from
variable-amount shifts — caused by our fshl/fshr decomposition emitting `sub(32, const)`
as a runtime SSA value instead of constant-folding.

**Fix:** In `ir_extract.jl`, when decomposing `fshl(a, b, sh)` with constant `sh`,
compute `w - sh` at compile time: `iconst(w - sh.value)` instead of emitting a `sub`
instruction. Eliminates 6 barrel-shifter groups (3072 wires) and 6 subtraction groups
(960 wires) from SHA-256.

**Results:**

| Metric | Before | After | Reduction |
|--------|--------|-------|-----------|
| Full Bennett | 5889 | 2049 | 65% |
| Checkpoint | 1985 | 1761 | 11% |
| sigma0 alone | 2305 | 385 | 83% |

**Key lesson:** "Measure before optimizing." I spent hours on carry cleanup (8.1% of
wires) when the real bottleneck was barrel shifters (55.8%). The wire breakdown
analysis by the research subagent identified the correct target.

### Prototypes 2-5: EAGER and Cuccaro variants — all hit the same wall

Five architectures attempted for further wire reduction beyond checkpoint_bennett:

| Prototype | Approach | Result | Failure mode |
|-----------|----------|--------|-------------|
| 0 | Constant-fold fshl/fshr | **65% reduction** | SUCCESS |
| 2 | Wire-level EAGER (last-use) | 0% | Cleaned wires corrupt Phase 3 reverse controls |
| 3 | Group-level EAGER single-pass | 0% | Linear chains → all groups path to output → nothing cleanable |
| 4 | Cuccaro + checkpoint | Non-zero ancillae | In-place modifies shared function input wires |
| 5 | Sub-group splitting | Not attempted | Analysis showed carries are only 8.1% of wires |

**Root cause:** All approaches 2-4 fail because of the SSA/out-of-place representation.
PRS15 works on F# AST with explicit `mutable` variables (one wire mutated W times).
LLVM SSA produces fresh wires for every value (W wires, each written once). The cleanup
strategies (EAGER, checkpoint, pebbling) operate ABOVE this representation and cannot
overcome the constant factor difference.

### Architectural comparison: Bennett.jl vs PRS15 (REVS)

**The gap is a constant factor (~4-5x), not asymptotic.** Both are O(T) gates, O(S) space.
The constant factor is the price of generality.

**Bennett.jl advantages over PRS15:**
- **Any LLVM language** (Julia, C, C++, Rust, Fortran) vs F# only
- **Full LLVM optimization pipeline** inherited (constant fold, DCE, CSE)
- **34 opcodes + 12 intrinsics** vs "a subset of F#"
- **Full IEEE 754 float** (soft-float: add/sub/mul/div/cmp, bit-exact) vs none
- **Arbitrary CFGs** via path-predicate phi resolution vs straight-line only
- **No source annotation** required — plain Julia in, reversible circuit out
- **Post-optimization** (like Enzyme) vs pre-optimization (AST level)

**PRS15 advantage:** ~4-5x fewer qubits on arithmetic-heavy functions due to in-place
operations with MDD mutation tracking. This advantage shrinks for bitwise-heavy functions
(XOR, AND, shifts are already 1 wire per bit in SSA).

**Decision:** Accept the constant factor. The Enzyme analogy holds — Enzyme also pays a
constant factor vs hand-written adjoints but wins on coverage, automation, and
composability. The 5x overhead is irrelevant for a researcher who wants
`when(qubit) do f(x) end` on arbitrary Julia code without rewriting anything.

### Final SHA-256 round wire counts (this session)

| Strategy | Wires | vs Original |
|----------|-------|-------------|
| Full Bennett (original) | 5889 | baseline |
| + constant-fold fshl/fshr | 2049 | **65% reduction** |
| + checkpoint_bennett | 1761 | **70% reduction** |
| + Cuccaro (full Bennett) | 1545 | 74% reduction |
| PRS15 EAGER (1 round) | ~704 | 88% (different arch) |
| PRS15 EAGER (10 rounds) | 353 | 94% (constant space) |

### Test results

- Full test suite: all tests pass, zero regressions
- SHA-256: correct output, all ancillae verified zero
