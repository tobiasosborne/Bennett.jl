# Bennett.jl — Reversible Compilation POC

**STATUS: COMPLETED v0.1** — historical PRD; preserved as the v0.1 milestone reference.

## One-line summary

Trace arbitrary Julia arithmetic into a DAG, apply Bennett's construction to produce a reversible circuit, verify correctness.

---

## 1. Goal

Demonstrate that arbitrary pure Julia functions can be mechanically compiled into reversible circuits via Bennett's 1973 construction. No quantum anything. No Sturm.jl dependency. Just classical reversible computation.

Success criterion: given `f(x) = x^2 + 3x + 1`, produce a reversible circuit that computes `(x, 0) → (x, f(x))` using only NOT, CNOT, Toffoli gates on classical bits, and verify it is correct for all inputs in the domain.

---

## 2. Scope

**In scope:**
- Tracing pure arithmetic Julia functions (integers only, v0.1)
- DAG representation of the traced computation
- Bennett's reversible embedding (forward, copy, uncompute)
- Reversible gate set: NOT, CNOT, Toffoli (all classical, operating on bits)
- Reversible simulator to verify correctness
- Gate count and ancilla count reporting

**Out of scope:**
- Floating point (integer arithmetic is sufficient to prove the concept)
- Quantum anything (this is purely classical reversible computation)
- Pebbling optimisations (use naive O(T) ancillae Bennett for v0.1)
- Enzyme/LLVM integration (use operator overloading for tracing)
- Performance

---

## 3. Design

### 3.1 Tracing via operator overloading

Define a `Traced{W}` integer type (W = bit width) that records every operation into a shared DAG.

```julia
mutable struct Traced{W}
    id::NodeID                # which DAG node produced this value
    dag::DAG                  # shared, all Traced values point to same DAG
end
```

Overload arithmetic so that `Traced` values build the DAG instead of computing eagerly:

```julia
Base.:+(a::Traced{W}, b::Traced{W}) where {W} = add_node!(a.dag, :add, a, b)
Base.:*(a::Traced{W}, b::Traced{W}) where {W} = add_node!(a.dag, :mul, a, b)
Base.:-(a::Traced{W}, b::Traced{W}) where {W} = add_node!(a.dag, :sub, a, b)
# etc.
```

Tracing a function:

```julia
function trace(f::Function, input_width::Int)
    dag = DAG()
    x = Traced{input_width}(add_input!(dag), dag)
    result = f(x)    # builds DAG via operator overloading
    mark_output!(dag, result.id)
    return dag
end
```

### 3.2 The DAG

```julia
struct DAGNode
    op::Symbol                # :input, :const, :add, :sub, :mul, :and, :or, :xor, :not, :shl, :shr
    inputs::Vector{NodeID}    # parent nodes
    width::Int                # bit width of output
    value::Union{Nothing,Int} # only for :const nodes
end

struct DAG
    nodes::Vector{DAGNode}
    input_ids::Vector{NodeID}
    output_ids::Vector{NodeID}
end
```

The DAG is a topologically sorted list. Each node depends only on earlier nodes. No cycles (pure functions only, no mutation, no loops for v0.1).

### 3.3 Lowering: DAG → reversible gate sequence

Each arithmetic DAG node lowers to a sequence of reversible gates operating on bit-vectors. This is the core of the POC.

**Bit-level representation:** every `Traced{W}` value is a vector of W bits (wires). Each DAG node produces W output wires.

**Lowering rules (each produces reversible gates on fresh ancilla wires):**

| DAG op | Reversible implementation |
|--------|--------------------------|
| `:add` | Ripple-carry adder (Cuccaro 2004): in-place `b += a` using CNOT + Toffoli, O(W) gates, O(1) ancillae |
| `:sub` | Reverse of adder: `b -= a` |
| `:mul` | Shift-and-add: O(W²) gates, O(W) ancillae |
| `:and` | Toffoli per bit: O(W) gates, O(W) ancilla wires |
| `:or`  | De Morgan via NOT + AND + NOT |
| `:xor` | CNOT per bit: O(W) gates, 0 ancillae |
| `:not` | NOT per bit: O(W) gates, 0 ancillae |
| `:shl` | Wire permutation (free) |
| `:shr` | Wire permutation (free) |
| `:const` | NOT gates on appropriate wires of a zero-initialised register |

Each lowered operation follows the pattern:
1. Allocate fresh output wires (zero-initialised)
2. Apply reversible gates: `(input_wires, output_wires=0) → (input_wires, output_wires=result)`
3. Input wires are NOT consumed — they remain available

This is critical: every intermediate result gets its own wires. No in-place mutation. This is wasteful (uses O(T·W) ancillae before Bennett uncomputation) but correct.

### 3.4 Bennett's construction

Given the lowered gate sequence for computing `f(x)`:

```
Step 1 (forward):   Compute f(x), keeping all intermediate wires live.
                    State: (x, intermediate_1, intermediate_2, ..., f(x))

Step 2 (copy out):  CNOT the output wires to a fresh clean register.
                    State: (x, intermediate_1, ..., f(x), f(x)_copy)

Step 3 (uncompute): Run the forward gates in reverse order.
                    Each gate is its own inverse (NOT, CNOT, Toffoli are self-inverse).
                    State: (x, 0, 0, ..., 0, f(x)_copy)
```

After step 3, all ancilla wires (intermediates + the original f(x)) are returned to 0. Only the input `x` and the copied output `f(x)_copy` survive. The total circuit implements:

```
(x, 0) → (x, f(x))
```

using only NOT, CNOT, Toffoli. Fully reversible.

### 3.5 Gate representation

```julia
abstract type ReversibleGate end

struct NOTGate <: ReversibleGate
    target::WireIndex
end

struct CNOTGate <: ReversibleGate
    control::WireIndex
    target::WireIndex
end

struct ToffoliGate <: ReversibleGate
    control1::WireIndex
    control2::WireIndex
    target::WireIndex
end
```

A reversible circuit is:

```julia
struct ReversibleCircuit
    n_wires::Int                    # total wire count (input + output + ancillae)
    gates::Vector{ReversibleGate}
    input_wires::Vector{WireIndex}
    output_wires::Vector{WireIndex}
    ancilla_wires::Vector{WireIndex}
end
```

### 3.6 Simulator

A bit-vector simulator. State is a `BitVector` of length `n_wires`. Apply each gate in sequence:

```julia
function simulate(circuit::ReversibleCircuit, input::Int) :: Int
    bits = zeros(Bool, circuit.n_wires)
    # Load input
    for (i, w) in enumerate(circuit.input_wires)
        bits[w] = (input >> (i-1)) & 1
    end
    # Apply gates
    for gate in circuit.gates
        apply!(bits, gate)
    end
    # Verify ancillae are zero (Bennett guarantee)
    for w in circuit.ancilla_wires
        @assert bits[w] == false "Ancilla wire $w not zero — Bennett construction bug"
    end
    # Read output
    result = 0
    for (i, w) in enumerate(circuit.output_wires)
        result |= Int(bits[w]) << (i-1)
    end
    return result
end

apply!(bits, g::NOTGate)     = (bits[g.target] ⊻= true)
apply!(bits, g::CNOTGate)    = (bits[g.target] ⊻= bits[g.control])
apply!(bits, g::ToffoliGate) = (bits[g.target] ⊻= bits[g.control1] & bits[g.control2])
```

### 3.7 The full pipeline

```julia
function reversible_compile(f::Function, input_width::Int) :: ReversibleCircuit
    dag = trace(f, input_width)                # Stage 1: trace
    gates_fwd = lower(dag, input_width)        # Stage 2: lower to reversible gates
    circuit = bennett(gates_fwd, input_width)  # Stage 3: forward + copy + uncompute
    return circuit
end
```

---

## 4. Reference Programs

### 4.1 Identity

```julia
f(x) = x
circuit = reversible_compile(f, 8)
for x in 0:255
    @assert simulate(circuit, x) == x
end
```

### 4.2 Increment

```julia
f(x) = x + 1
circuit = reversible_compile(f, 8)
for x in 0:254
    @assert simulate(circuit, x) == x + 1
end
# x=255 wraps to 0 (mod 256)
@assert simulate(circuit, 255) == 0
```

### 4.3 Polynomial

```julia
f(x) = x^2 + 3x + 1
circuit = reversible_compile(f, 8)
for x in 0:15   # keep x small so x^2 + 3x + 1 < 256
    @assert simulate(circuit, x) == x^2 + 3x + 1
end
```

### 4.4 Multi-input function

```julia
# Two-input function: need to trace with two inputs
function trace(f::Function, widths::NTuple{N,Int}) where N
    dag = DAG()
    inputs = Tuple(Traced{w}(add_input!(dag), dag) for w in widths)
    result = f(inputs...)
    mark_output!(dag, result.id)
    return dag
end

f(x, y) = x * y + x - y
circuit = reversible_compile(f, (8, 8))
for x in 0:15, y in 0:15
    @assert simulate(circuit, (x, y)) == (x * y + x - y) % 256
end
```

### 4.5 Collatz step (branching — stretch goal)

```julia
# This requires tracing if/else as a multiplexer.
# Both branches are computed; output is selected by condition.
# NOT required for v0.1 core — listed as stretch.
f(x) = x % 2 == 0 ? x ÷ 2 : 3x + 1
```

---

## 5. Implementation Plan

**Phase 1: Traced type + DAG**
- [ ] `DAGNode`, `DAG` structs
- [ ] `Traced{W}` type
- [ ] Overload `+`, `-`, `*` on `Traced`
- [ ] `trace(f, width)` function
- [ ] Test: trace `f(x) = x + 1`, inspect DAG has one `:add` node

**Phase 2: Lowering to reversible gates**
- [ ] `NOTGate`, `CNOTGate`, `ToffoliGate` structs
- [ ] Wire allocator (tracks which wires are allocated, hands out fresh ones)
- [ ] Lower `:add` → ripple-carry adder (Cuccaro 2004)
- [ ] Lower `:mul` → shift-and-add
- [ ] Lower `:sub` → reverse adder
- [ ] Lower `:const` → NOT gates on zero register
- [ ] Lower `:xor`, `:and`, `:or`, `:not`
- [ ] Test: lower `x + 1` to gates, manually verify gate sequence

**Phase 3: Bennett construction**
- [ ] `bennett(forward_gates, input_width)` → `ReversibleCircuit`
- [ ] Copy-out stage: CNOT output wires to fresh register
- [ ] Uncompute stage: reverse gate list
- [ ] Verify ancilla count = expected

**Phase 4: Simulator + verification**
- [ ] `simulate(circuit, input)` bit-vector simulator
- [ ] Ancilla-zero assertion after simulation
- [ ] Test all reference programs (§4.1–4.4)
- [ ] Report: gate count, ancilla count, wire count for each

**Phase 5: Diagnostics**
- [ ] `gate_count(circuit)` — total and by type (NOT, CNOT, Toffoli)
- [ ] `ancilla_count(circuit)`
- [ ] `depth(circuit)` — longest gate chain
- [ ] `print_circuit(circuit)` — text visualisation
- [ ] `verify_reversibility(circuit)` — run forward then backward on random inputs, assert identity

---

## 6. File structure

```
Bennett.jl/
├── Project.toml
├── src/
│   ├── Bennett.jl              # module definition, exports
│   ├── dag.jl                  # DAGNode, DAG
│   ├── traced.jl               # Traced{W}, operator overloads
│   ├── trace.jl                # trace(f, width) entry point
│   ├── wire_allocator.jl       # fresh wire allocation
│   ├── gates.jl                # NOTGate, CNOTGate, ToffoliGate
│   ├── lower.jl                # DAG → forward gate sequence
│   ├── adder.jl                # ripple-carry adder (Cuccaro 2004)
│   ├── multiplier.jl           # shift-and-add multiplier
│   ├── bennett.jl              # Bennett construction: forward + copy + uncompute
│   ├── simulator.jl            # bit-vector simulator
│   └── diagnostics.jl          # gate_count, depth, print_circuit
└── test/
    ├── runtests.jl
    ├── test_trace.jl
    ├── test_lower.jl
    ├── test_bennett.jl
    ├── test_identity.jl
    ├── test_increment.jl
    ├── test_polynomial.jl
    └── test_multi_input.jl
```

---

## 7. Key Technical Notes

### 7.1 The ripple-carry adder

The Cuccaro (2004) adder computes `b += a` in-place using `2n + 1` Toffoli gates and 1 ancilla for an n-bit addition. It is reversible: running the gates in reverse computes `b -= a`.

For the POC, a simpler textbook ripple-carry adder is fine: `O(n)` Toffoli + CNOT gates, `O(n)` ancillae for carries. Optimise later.

### 7.2 Multiplication via shift-and-add

For `W`-bit inputs, `c = a * b` decomposes into `W` conditional additions (if bit `i` of `b` is set, add `a << i` to accumulator). Each conditional addition is a controlled adder (Toffoli-based). Total: `O(W²)` gates, `O(W)` ancillae.

### 7.3 The self-inverse property

NOT, CNOT, and Toffoli are all self-inverse:
- NOT: `x ⊻= 1` applied twice = identity
- CNOT: `a ⊻= b` applied twice = identity  
- Toffoli: `a ⊻= (b ∧ c)` applied twice = identity

This is why Bennett's uncompute step works: just replay the forward gates in reverse order. Each gate undoes itself.

### 7.4 Constants

A constant `c` in the computation is loaded by applying NOT gates to the appropriate bits of a zero-initialised register. During uncomputation, the same NOT gates return it to zero. No special handling needed.

### 7.5 What does NOT work (known limitations for v0.1)

- **Data-dependent branching** (`if x > 0`): requires computing both branches and multiplexing. Not in v0.1 scope. Stretch goal in §4.5.
- **Loops with data-dependent iteration count**: must be unrolled or bounded. Not in v0.1 scope.
- **Division**: integer division with remainder is reversible but requires a restoring division circuit. Add in a later phase if needed.
- **Non-pure functions**: anything with side effects (I/O, mutation of external state) cannot be reversibilised. The tracer must reject these.

---

## 8. Success Criteria

The POC succeeds when:

1. `f(x) = x^2 + 3x + 1` compiles to a reversible circuit
2. The circuit produces correct output for all 8-bit inputs where the result fits in 8 bits
3. All ancillae are verified zero after every simulation
4. Gate count and ancilla count are printed and are polynomial in input width
5. Running the circuit forward then backward produces the identity (reversibility check)
