## Session log — 2026-04-13 — BC.3 full SHA-256 + sret support

### Delivered

| Task | Issue | Commit | Deliverable |
|------|-------|--------|-------------|
| sret support | Bennett-dv1z | d1bb5fd | `ir_extract.jl` handles LLVM sret calling convention (tuple returns > 16 bytes) |
| BC.3 full SHA-256 | Bennett-xy75 | b2716f2 | Full 64-round compression compiles, verifies "abc" test vector |
| filed follow-up | Bennett-s4b4 | (new) | test_negative.jl bounded-collatz no longer errors (LLVM version drift) |

### BC.3 results

Full SHA-256 compression of a 512-bit block (metaprogrammed unrolled form;
LLVM dead-code-eliminates unused schedule extensions for n_rounds < 64):

```
Total gates:  501,096  (NOT 6,084  CNOT 359,428  Toffoli 135,584)
T-count:      949,088
peak_live:    28,133   ← quantum-relevant qubit count
n_wires:      105,272  (total allocated over time)
Ancillae:     104,248
Compile:      ~2s warm
Test vector:  SHA-256("abc") = ba7816bf 8f01cfea 414140de 5dae2223 ...  MATCHES ✓
Reversibility: ✓
```

vs PRS15 Table II per-round scaled ×64 (upper bound):

| Metric | Bennett.jl | PRS15×64 | Ratio |
|--------|-----------:|---------:|------:|
| peak_live | 28,133 | 45,056 | **0.62× ✓** |
| n_wires   | 105,272 | 45,056 | 2.34× |
| Toffoli   | 135,584 | 43,712 | 3.10× |

**Peak live qubits beats the PRS15 Bennett projection** — by the quantum-
hardware metric (simultaneous live qubits), we hold fewer than PRS15's
per-round × 64 upper bound. n_wires and Toffoli are above 2× because
SSA-form plus the Bennett forward+reverse cost doubles adder Toffolis
vs in-place schemes. Closing the Toffoli gap requires Bennett-07r
(Cuccaro self-reversing) and Bennett-gsxe (2n-3 Cuccaro); those are
separately tracked.

### sret (Bennett-dv1z) — root cause and fix

Julia's x86_64 SysV ABI routes aggregate returns > 16 bytes through
LLVM's `sret` parameter attribute: the function's LLVM return type
becomes `void` and the caller passes a pointer to a caller-allocated
destination struct. For BC.3 we need 8-tuple UInt32 = 32 bytes, which
triggers sret; previously `_type_width(VoidType)` crashed.

Fix is contained in `src/ir_extract.jl` (no changes to lower.jl,
bennett.jl, gates.jl, ir_types.jl, simulator.jl — all existing tests
gate-count-byte-identical). Approach:

1. `_detect_sret(func)` uses LLVM C API
   (`LLVMGetEnumAttributeKindForName("sret",4)` +
   `LLVMGetEnumAttributeAtIndex` + `LLVMGetTypeAttributeValue`) to
   find the sret attribute and read the pointee type `[N x iM]`.
2. `_collect_sret_writes` pre-walks the body, classifying stores
   targeting sret (directly or via constant-offset GEP from sret),
   recording per-slot stored values, and collecting instruction refs
   to suppress in the block walk.
3. In the block walk, suppressed instructions are skipped and
   `ret void` is replaced with a synthetic `IRInsertValue` chain +
   `IRRet` — structurally identical to the n=2 by-value path.

MVP scope (fail-fast on anything else):
- `[N x iM]` (ArrayType) homogeneous only; StructType rejected
- optimize=true direct-store form only; memcpy form rejected with a
  pointer to optimize=true or preprocess=true
- single store per slot (conditional sret via phi-SSA transparently
  supported; multi-store not)
- every slot must be written before ret void

3+1 agent workflow: 2 proposers (`docs/design/sret_proposer_{A,B}.md`)
+ implementer (orchestrator/same agent). Both proposers converged on
extract-time synthesis; A's wrapper-around-`_convert_instruction`
approach (no walker-loop patch) was chosen over B's walker-loop
refactor to minimise surface area.

### Gotchas learned

1. **Julia's ABI aggregate-return threshold is 16 bytes on x86_64 SysV.**
   n=2 Int8 (2 bytes), n=2 Int64 (16 bytes), n=4 Int32 (16 bytes) all
   go by-value. n=3 Int32 (12 bytes) goes by-value too — threshold is
   really "fits in 2 integer registers". n=3 UInt32 (12 bytes) actually
   goes SRET in Julia's emitted IR because Julia's codegen is
   conservative; check real `code_llvm` output per case. For this
   session, the failure happened at n≥3 UInt32.
2. **`LLVM.parameter_attributes(f, i)`** (higher-level LLVM.jl API)
   throws a MethodError on iteration in our LLVM.jl version. Use the
   C API directly:
   `LLVM.API.LLVMGetEnumAttributeAtIndex(func, UInt32(i), kind)`.
3. **sret GEP has `i8` source element type** in optimize=true Julia
   emissions — byte-offset GEPs, not typed-index GEPs. The offset's
   ConstantInt value *is* the byte offset (no scaling). A typed GEP
   (`getelementptr [N x iM], ptr, i32 0, i32 k`) would scale by
   `elem_byte_size`; we handle both but the byte-indexed form is what
   Julia produces.
4. **`test_negative.jl` bounded-collatz** was broken on main before
   this session (LLVM now unrolls `while n > 1 && steps < 5` —
   bounded — completely, leaving no back-edge for lower.jl to detect).
   Tracked as Bennett-s4b4; test temporarily skipped.
5. **`peak_live_wires` is the PRS15-comparable metric**, not `n_wires`.
   PRS15 reports qubit counts (simultaneous-live), which maps to
   `peak_live_wires()`. `n_wires` counts total allocations over the
   circuit's lifetime and is much larger in SSA form. Always report
   both when comparing to published reversible-compiler benchmarks.
6. **Julia multi-assignment `(a, b, c) = (x, y, z)`** works in Bennett
   compilation — LLVM emits direct SSA updates with no tuple alloca in
   optimize=true mode. This made the metaprogrammed SHA-256 body
   compile cleanly.
7. **LLVM DCE is aggressive**: in `_sha256_body(n)` with n<64, the
   `_SHA256_K[i]` entries for i>n are not referenced, and the unused
   schedule extensions W16..W_{n+14} are DCE'd. 8-round compile has
   52,924 gates (not 64,000 linear), because late-schedule ops fold
   away.

### Files changed

- `src/ir_extract.jl` — +250 LOC for sret helpers + `_module_to_parsed_ir` integration
- `test/test_sret.jl` — NEW, 4,190 assertions (n=3,4,8 UInt32; mixed widths; error boundaries)
- `test/test_sha256_full.jl` — NEW, 2/8/64-round progression
- `test/runtests.jl` — wire new tests; skip test_negative.jl with bd-s4b4 reference
- `benchmark/bc5_sha256_full.jl` — NEW, 5-variant comparison with PRS15 projection
- `BENCHMARKS.md` — SHA-256 full row + dedicated comparison table
- `docs/design/sret_proposer_{A,B}.md` — NEW, 3+1 agent workflow designs

### Next candidates (per VISION priorities)

1. **Bennett-07r** (P2) — Cuccaro self-reversing. Halves Toffoli count
   on adder-heavy benchmarks including SHA. Would drop BC.3 Toffoli
   ratio from 3.1× toward 1.5×. Architectural `bennett.jl` change
   (3+1 agents required).
2. **Bennett-utt** (P2) — soft_fdiv sticky bit shift bug.
3. **MemorySSA into lower_load!** (not yet filed) — turns T2a
   infrastructure functional. ~100 LOC, improves conditional-store
   handling.

---

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

