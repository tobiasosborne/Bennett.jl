# Architecture Guide

How Bennett.jl transforms a Julia function into a reversible circuit.

## Pipeline Overview

```
Julia function          LLVM IR              Parsed IR           Reversible Circuit
-----------------      ---------            ----------          ------------------
f(x::Int8)     -->  code_llvm()  -->  extract_parsed_ir()  -->  lower()  -->  bennett()
                     (LLVM.jl C API)    (two-pass name table)    (gates)       (fwd+copy+rev)
                                                                                  |
                                                                                  v
                                                                            simulate()
                                                                            verify_reversibility()
```

### Stage 1: Extract (`ir_extract.jl`)

`extract_parsed_ir(f, arg_types)` generates LLVM IR via Julia's `code_llvm`, parses it into an `LLVM.Module` via the LLVM.jl C API, and walks the module to produce a `ParsedIR`.

Key design: a **two-pass name table** keyed on `LLVMValueRef` (C pointer) assigns stable SSA names to all LLVM values. The first pass names everything; the second pass converts instructions using those names. This handles LLVM's unnamed values correctly.

**Intrinsic expansion**: LLVM intrinsics like `@llvm.umax`, `@llvm.ctpop`, `@llvm.fshl` are expanded inline into equivalent IR instructions (icmp+select, cascaded shifts, etc.).

**Callee recognition**: Call instructions to registered callees (soft-float functions, user-registered functions) produce `IRCall` instructions for gate-level inlining.

### Stage 2: Lower (`lower.jl`)

`lower(parsed_ir)` converts each IR instruction to reversible gates:

| IR Instruction | Gate Implementation |
|---------------|-------------------|
| `add` | Strategy-dispatched (see below): ripple / Cuccaro / QCLA |
| `sub` | Two's complement: NOT + add + carry-in |
| `mul` | Strategy-dispatched (see below): shift-add / Karatsuba / QCLA-tree |
| `and/or/xor` | Per-bit Toffoli/CNOT |
| `shl/lshr/ashr` | Barrel shifter (6 stages for 64-bit) |
| `icmp` | Modified adder for unsigned, sign-flip for signed |
| `select` | MUX circuit (per-bit Toffoli controlled by condition) |
| `phi` | Path-predicate MUX chain (edge predicates guarantee correctness) |
| `br` | Block predicates computed via AND/OR/NOT gates |
| `sext/zext/trunc` | CNOT copy / wire selection |
| Loops | Bounded unrolling with MUX-frozen outputs |
| `call` | Gate-level inlining via recursive compilation |

**Path predicates**: Each basic block gets a 1-bit predicate wire indicating whether execution reached that block. Phi nodes are resolved via a MUX chain controlled by mutually-exclusive edge predicates. This approach is grounded in Gated SSA / Psi-SSA theory and is correct for any control flow graph, including diamonds and multi-way merges.

**Liveness analysis**: SSA variable liveness determines when the Cuccaro in-place adder can safely overwrite its second operand (saving W-1 ancilla wires per addition).

**Arithmetic strategy dispatch**: `lower_binop!` routes `:add` and `:mul`
through `_pick_add_strategy` and `_pick_mul_strategy` respectively, honoring
the `add=` / `mul=` kwargs threaded from `reversible_compile` through
`LoweringCtx`:

| `add=` | Primitive | Shape |
|--------|-----------|-------|
| `:ripple`  | `lower_add!` (`adder.jl`)          | O(n) depth, out-of-place |
| `:cuccaro` | `lower_add_cuccaro!` (`adder.jl`)  | O(n) depth, in-place, 1 ancilla |
| `:qcla`    | `lower_add_qcla!` (`qcla.jl`)      | O(log n) depth, out-of-place, O(n) ancilla |
| `:auto`    | Cuccaro when op2 dead, ripple otherwise | pre-D1 default |

| `mul=` | Primitive | Shape |
|--------|-----------|-------|
| `:shift_add`  | `lower_mul!` (`multiplier.jl`)         | O(W²) Toffoli, O(W²) Toffoli-depth |
| `:karatsuba`  | `lower_mul_karatsuba!`                  | O(W^log₂3) Toffoli, O(W^log₂5) wires |
| `:qcla_tree`  | `lower_mul_qcla_tree!` (`mul_qcla_tree.jl`) | O(n²) Toffoli, O(log²n) Toffoli-depth, self-reversing |
| `:auto`       | Shift-add (+ Karatsuba via legacy `use_karatsuba`) | pre-P2 default |

The QCLA-tree multiplier composes four sub-primitives — `emit_fast_copy!`,
`emit_conditional_copy!`, `emit_partial_products!`, `emit_parallel_adder_tree!` —
implementing Sun-Borissov 2026's Algorithm 3 end-to-end. The final
`parallel_adder_tree` is itself self-cleaning (see `parallel_adder_tree.jl`):
it tracks `_AdderRecord` per invocation, copies the root into a fresh 2W
register, then replays every adder's gate range in reverse to zero
intermediate levels.

### Stage 3: Bennett Construction (`bennett.jl`)

`bennett(lr)` applies Bennett's 1973 construction:

1. **Forward**: Apply all gates in order (compute `f(x)` plus intermediates)
2. **Copy**: CNOT-copy the output wires to fresh "copy wires"
3. **Reverse**: Apply all gates in reverse order (uncompute intermediates)

After this, input wires hold `x`, copy wires hold `f(x)`, and all intermediate (ancilla) wires are zero. This works because every gate (NOT, CNOT, Toffoli) is self-inverse.

The construction is 28 lines of code and is provably correct under two invariants:
- Every gate is an involution (self-inverse)
- Input wires are never targeted by any gate (read-only controls)

**Self-reversing short-circuit**: when `lr.self_reversing == true`,
`bennett` returns forward-gates-only. This applies to primitives like
`lower_mul_qcla_tree!` that already end with clean ancillae — the standard
copy + reverse pass would just double the gate count without changing the
output. Default is `false`; opt-in at `LoweringResult` construction.

### Stage 4: Simulate (`simulator.jl`)

`simulate(circuit, input)` runs bit-vector simulation:
- Initialize a `Bool` vector for all wires
- Load input bits
- Apply each gate sequentially
- Verify all ancilla wires are zero
- Read and return output bits

## File Map

```
src/
  Bennett.jl            Module definition, SoftFloat dispatch, reversible_compile
  ir_types.jl           IR instruction types (IRBinOp, IRPhi, IRCall, etc.)
  ir_extract.jl         LLVM IR -> ParsedIR (two-pass name table, intrinsic expansion)
  ir_parser.jl          Legacy regex parser (backward compat)
  gates.jl              NOTGate, CNOTGate, ToffoliGate, ReversibleCircuit
  wire_allocator.jl     Sequential wire allocation with free/reuse
  adder.jl              Ripple-carry + Cuccaro in-place adder
  qcla.jl               Draper-Kutin-Rains-Svore 2004 carry-lookahead adder
  multiplier.jl         Shift-and-add + Karatsuba multiplier
  fast_copy.jl          Sun-Borissov doubling-broadcast primitive
  partial_products.jl   conditional_copy + partial_products primitives
  parallel_adder_tree.jl  Binary tree of QCLA adders (self-cleaning)
  mul_qcla_tree.jl      Sun-Borissov 2026 polylogarithmic-depth multiplier
  divider.jl            Restoring division (soft_udiv, soft_urem)
  lower.jl              IR -> gates (phi resolution, loops, all instruction handlers)
  bennett.jl            Bennett construction (forward + copy + reverse)
  simulator.jl          Bit-vector simulation
  diagnostics.jl        gate_count, depth, t_count, verify_reversibility, etc.
  controlled.jl         ControlledCircuit wrapper (NOT->CNOT->Toffoli promotion)
  dep_dag.jl            Dependency DAG extraction for pebbling
  pebbling.jl           Knill recursion + pebbled_bennett
  eager.jl              Gate-level EAGER cleanup
  value_eager.jl        Value-level EAGER (PRS15 Algorithm 2)
  pebbled_groups.jl     Group-level pebbling with wire reuse
  sat_pebbling.jl       SAT-based pebbling (Meuli 2019)
  softfloat/
    softfloat_common.jl Shared IEEE 754 helpers (CLZ, rounding, subnormal)
    fadd.jl             Branchless Float64 addition
    fsub.jl             Float64 subtraction (fadd + fneg)
    fmul.jl             Branchless Float64 multiplication
    fdiv.jl             Branchless Float64 division (restoring)
    fneg.jl             Float64 negation (XOR sign bit)
    fcmp.jl             Float64 comparison (olt, oeq, ole, une)
    fptosi.jl           Float64 -> Int64 conversion
    sitofp.jl           Int64 -> Float64 conversion
    fround.jl           Branchless floor/ceil/trunc
```

## Key Design Decisions

### Why LLVM IR?

Operating at the LLVM level means any language that compiles to LLVM (Julia, C, Rust, etc.) can use Bennett.jl -- analogous to how Enzyme does automatic differentiation at the LLVM level. No operator overloading, no custom types, no source modification.

### Why Branchless Soft-Float?

IEEE 754 floating-point operations involve complex control flow (NaN, Inf, subnormal, rounding). Branching code produces phi nodes in LLVM IR, which can cause false-path sensitization in the reversible circuit (a MUX condition from one branch fires even when the other branch was "taken"). Branchless implementations using `ifelse` produce `select` instructions instead of `phi`, eliminating this entire class of bugs.

### Why Path Predicates?

LLVM's phi nodes merge values from different control flow paths. The original reachability-based phi resolver had known bugs with diamond CFGs. Path predicates (1-bit wires per block, computed from branch conditions) provide a correct-by-construction resolution for any CFG topology. The approach is grounded in Gated SSA / Psi-SSA theory.

### Why Bennett + Pebbling?

Bennett's construction is simple and correct but uses O(T) ancillae (one per intermediate value). For real programs, this is wasteful. The pebbling strategies (Knill recursion, EAGER, checkpoint) trade increased gate count for reduced peak wire usage. The group-level checkpoint approach reduces SHA-256 wires by 14-25%.

### Why Strategy Dispatchers?

Reversible arithmetic isn't one algorithm per op — it's a cost surface.
Classical CMOS cares about gate count; NISQ cares about ancilla;
fault-tolerant quantum cares about Toffoli-depth (T-depth). The
dispatchers let callers pick per-op strategy without touching the compiler
internals: `reversible_compile(f, T; mul=:qcla_tree)` routes every `mul` in
`f` through the O(log²n) Sun-Borissov multiplier at the cost of 5× more
Toffolis and 8× more ancillae.

The framework is additive: new strategies (e.g. Cuccaro-2n-3 tightening,
Schöenhage-Strassen for very large W) plug into `_pick_{add,mul}_strategy`
without reshuffling the dispatcher call site.
