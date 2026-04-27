# API Reference

## Compilation

### `reversible_compile(f, types...; kw...) -> ReversibleCircuit`

Compile a pure Julia function into a reversible circuit.

```julia
# Single argument
circuit = reversible_compile(f, Int8)

# Multiple arguments
circuit = reversible_compile(f, Int8, Int8)

# Float64 (routes through soft-float)
circuit = reversible_compile(f, Float64)

# With options
circuit = reversible_compile(f, Int8;
    optimize=true,             # Use LLVM optimization (default: true)
    max_loop_iterations=0,     # Max loop unrolling iterations (0 = no loops)
    compact_calls=false,       # Apply Bennett per-callee to limit wire accumulation
    add=:auto,                 # Adder strategy: :auto | :ripple | :cuccaro | :qcla
    mul=:auto,                 # Multiplier strategy: :auto | :shift_add | :qcla_tree
    bit_width=0,               # >0: narrow all widths to bit_width (see _narrow_ir)
)
```

### Strategy kwargs

**`add=` selects the adder lowering:**
- `:auto` (default) — Cuccaro in-place when op2 is dead, else ripple-carry. Preserves pre-dispatcher gate-count baselines.
- `:ripple` — out-of-place ripple-carry (`lower_add!`); `2(W-1)` Toffoli, `W` ancilla carry register.
- `:cuccaro` — in-place, 1 ancilla (`lower_add_cuccaro!`, Cuccaro 2004).
- `:qcla` — Draper-Kutin-Rains-Svore 2004 carry-lookahead, `O(log n)` Toffoli-depth, `O(n)` ancilla.

**`mul=` selects the multiplier lowering:**
- `:auto` (default) — shift-and-add at `target=:gate_count`; promotes to `qcla_tree` at `target=:depth`.
- `:shift_add` — schoolbook (`lower_mul!`), `O(W²)` Toffoli, `O(W)` peak wires.
- `:qcla_tree` — Sun-Borissov 2026 (`lower_mul_qcla_tree!`), `O(log²n)` Toffoli-depth, `O(n²)` Toffoli/ancilla; self-reversing primitive.

(Bennett-tbm6 retired `:karatsuba` 2026-04-27 — the implementation was 1.91-3.49× WORSE Toffoli count than schoolbook at every supported width W ≤ 64; asymptotic crossover sits past W=128 which `ir_extract` cannot lower today.)

Unknown strategy symbols raise an error at `lower()` entry.

**Supported input types**: `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `Float64`, `NTuple{N,T}` (for integer T).

**Requirements**: The function must be pure (no I/O, no mutation of external state) and deterministic (same input always produces same output).

## Simulation

### `simulate(circuit::ReversibleCircuit, input) -> output`

Run bit-vector simulation of a compiled circuit.

```julia
result = simulate(circuit, Int8(42))           # single input
result = simulate(circuit, (Int8(1), Int8(2)))  # multiple inputs
```

Returns the same type as the original function: `Int8`, `Int16`, etc., or a `Tuple` for multi-return functions.

Automatically verifies all ancillae return to zero (the Bennett invariant). Throws an error if any ancilla is non-zero.

### `simulate(cc::ControlledCircuit, ctrl::Bool, input) -> output`

Simulate a controlled circuit with a control bit.

```julia
result = simulate(cc, true, Int8(5))   # applies f
result = simulate(cc, false, Int8(5))  # identity: returns 0
```

## Circuit Analysis

### `gate_count(c::ReversibleCircuit) -> NamedTuple`

```julia
gc = gate_count(circuit)
gc.total    # total gates
gc.NOT      # NOT gate count
gc.CNOT     # CNOT gate count
gc.Toffoli  # Toffoli gate count
```

### `ancilla_count(c::ReversibleCircuit) -> Int`

Number of ancilla wires (intermediate wires that return to zero).

### `depth(c::ReversibleCircuit) -> Int`

Circuit depth (longest chain of dependent gates).

### `t_count(c::ReversibleCircuit) -> Int`

T-gate count in fault-tolerant decomposition. Each Toffoli = 7 T-gates; NOT and CNOT are Clifford (0 T-gates).

### `toffoli_depth(c::ReversibleCircuit) -> Int`

Longest chain of Toffoli gates along a data-dependence path. NOT/CNOT gates
do not advance the count. This is the raw circuit-level metric — it doesn't
assume any specific Toffoli decomposition.

### `t_depth(c::ReversibleCircuit; decomp::Symbol=:ammr) -> Int`

Clifford+T T-depth. Equals `toffoli_depth(c) × k`, where `k` is the per-Toffoli T-layer cost of the chosen decomposition:
- `:ammr` (default) — Amy/Maslov/Mosca/Roetteler 2013, `k=1` (ancilla-assisted, matches Sun-Borissov 2026 formulas)
- `:nc_7t` — Nielsen-Chuang classical 7-T decomposition, `k=3`

The `:ammr` default preserves the pre-M1 semantics (unparameterized `t_depth(c)` returns the same numbers).

### `peak_live_wires(c::ReversibleCircuit) -> Int`

Peak number of simultaneously non-zero wires during simulation. This is the metric that space optimization strategies minimize.

### `constant_wire_count(c::ReversibleCircuit) -> Int`

Number of wires carrying compile-time constant values (independent of input). Uses forward dataflow analysis.

### `verify_reversibility(c; n_tests=100) -> Bool`

Verify that running all gates forward then backward restores the original state, for `n_tests` random inputs.

### `print_circuit(c::ReversibleCircuit)`

Print a summary of the circuit (wire count, gate count, depth).

## Controlled Circuits

### `controlled(circuit::ReversibleCircuit) -> ControlledCircuit`

Wrap every gate with a control bit:
- NOT becomes CNOT (controlled by ctrl)
- CNOT becomes Toffoli (controlled by ctrl)
- Toffoli decomposes into 3 Toffolis + 1 shared ancilla

## Space Optimization

### `bennett(lr::LoweringResult) -> ReversibleCircuit`

Standard Bennett construction: forward + CNOT-copy + reverse. O(T) space.

If `lr.self_reversing == true`, `bennett` short-circuits to forward-only:
the primitive is assumed to already end with clean ancillae and its
`output_wires` hold the result directly. No copy-out, no reverse. Roughly
halves the gate count for self-cleaning primitives like `lower_mul_qcla_tree!`.
Default is `false` — explicit opt-in at `LoweringResult` construction.

### `pebbled_bennett(lr; max_pebbles=0) -> ReversibleCircuit`

Bennett construction with Knill's pebbling strategy. Reduces peak simultaneously-live wires by recursive segment splitting.

### `eager_bennett(lr) -> ReversibleCircuit`

EAGER cleanup: identifies dead-end wires and cleans them up during the reverse phase.

### `value_eager_bennett(lr) -> ReversibleCircuit`

Value-level EAGER (PRS15 Algorithm 2): treats GateGroups as atomic pebble units for per-instruction cleanup.

### `checkpoint_bennett(lr) -> ReversibleCircuit`

Checkpoint-based construction: forward each group, checkpoint result, reverse group (free internals). Reduces peak wires by keeping only checkpoints live.

### `pebbled_group_bennett(lr; max_pebbles) -> ReversibleCircuit`

Group-level pebbled Bennett with wire reuse via WireAllocator.

## Function Inlining

### `register_callee!(f::Function)`

Register a Julia function for gate-level inlining. When the compiler encounters a call to this function in LLVM IR, it compiles the callee into gates and inlines them into the caller's circuit.

```julia
# Already registered: soft_fadd, soft_fmul, soft_fdiv, soft_fsub, soft_fneg,
# soft_fcmp_olt, soft_fcmp_oeq, soft_fcmp_ole, soft_fcmp_une,
# soft_fptosi, soft_sitofp, soft_floor, soft_ceil, soft_trunc,
# soft_udiv, soft_urem

# Register your own:
my_helper(x::UInt64) = x & UInt64(0xFF)
register_callee!(my_helper)
```

## Gate Types

### `NOTGate(target::Int)`

Flips the target bit. Self-inverse.

### `CNOTGate(control::Int, target::Int)`

Flips target when control is 1. Self-inverse.

### `ToffoliGate(control1::Int, control2::Int, target::Int)`

Flips target when both controls are 1. Self-inverse. Universal for classical reversible computation.

### `ReversibleCircuit`

A sequence of gates with metadata:
- `n_wires::Int` -- total wire count
- `gates::Vector{ReversibleGate}` -- gate list
- `input_wires::Vector{Int}` -- input wire indices
- `output_wires::Vector{Int}` -- output wire indices
- `ancilla_wires::Vector{Int}` -- ancilla wire indices (verified zero)
- `input_widths::Vector{Int}` -- bit width of each input argument
- `output_elem_widths::Vector{Int}` -- bit width of each output element

### `LoweringResult`

Intermediate result between `lower(parsed)` and `bennett(lr)`. Fields:
- `gates`, `n_wires`, `input_wires`, `output_wires`, `input_widths`, `output_elem_widths` — as above
- `constant_wires::Set{Int}` — wires carrying compile-time constants
- `gate_groups::Vector{GateGroup}` — SSA instruction → gate range mapping
- `self_reversing::Bool` — opt-in flag telling `bennett()` to skip the copy-out + reverse pass. Set when the primitive already ends with clean ancillae (e.g. Sun-Borissov multiplier). Default `false`; backward-compatible 7/8-arg constructors preserved.

## Arithmetic primitive functions

These are the per-strategy emitters called by the dispatcher. Useful for
direct circuit construction outside the `reversible_compile` pipeline.

### `lower_add!(gates, wa, a, b, W) -> Vector{Int}`

Out-of-place ripple-carry adder. Returns a fresh `W`-wire result register.

### `lower_add_cuccaro!(gates, wa, a, b, W) -> Vector{Int}`

In-place Cuccaro 2004 adder. Returns `b` (overwritten with `a + b mod 2^W`).

### `lower_add_qcla!(gates, wa, a, b, W) -> Vector{Int}`

Out-of-place Draper-Kutin-Rains-Svore 2004 QCLA. Returns a fresh `W+1`-wire register (low `W` bits = sum, top bit = carry-out). O(log n) Toffoli-depth. All internal ancillae self-cleaned.

### `lower_mul!(gates, wa, a, b, W) -> Vector{Int}`

Shift-and-add multiplier, returns `W`-bit result (`a * b mod 2^W`).

### `lower_mul_karatsuba!(gates, wa, a, b, W) -> Vector{Int}`

Recursive Karatsuba, returns `W`-bit result.

### `lower_mul_qcla_tree!(gates, wa, a, b, W) -> Vector{Int}`

Sun-Borissov 2026 polylogarithmic-depth multiplier. Returns a fresh `2W`-wire register holding the full product `a * b`. Self-cleaning (all ancillae zero on exit). Composes `emit_fast_copy!`, `emit_partial_products!`, and `emit_parallel_adder_tree!`.
