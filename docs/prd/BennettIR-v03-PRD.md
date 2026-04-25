# BennettIR.jl v0.3 — Controlled Circuits + Control Flow

**STATUS: COMPLETED v0.3** — historical PRD; preserved as the v0.3 milestone reference.

## One-line summary

Add quantum control to reversible circuits (the `when` primitive), and handle
LLVM IR with multiple basic blocks (branches and loops).

---

## 1. Where we are

v0.2 proved: plain Julia function → LLVM IR → reversible circuit → correct.
Works for single-basic-block IR: straight-line arithmetic, bitwise, compare+select,
multi-argument functions. All ancillae verified zero.

## 2. What v0.3 adds

Two independent features. Either can be built first. Both are needed for the
end goal (Sturm.jl P8: `when(q) do arbitrary_julia end`).

### Feature A: Controlled reversible circuits

Take a `ReversibleCircuit` and produce a `ControlledCircuit` where every gate
has an additional control bit. This is the quantum `when` primitive.

### Feature B: Multi-basic-block LLVM IR

Handle `br`, `phi`, and loops in LLVM IR. This unlocks any Julia function that
compiles to multiple basic blocks — conditionals, for loops, while loops.

---

## 3. Feature A: Controlled Circuits

### 3.1 What it means

Given a reversible circuit C that computes `(x, 0) → (x, f(x))`, produce a
controlled circuit C_ctrl that computes:

```
(ctrl, x, 0) → (ctrl, x, ctrl ? f(x) : 0)
```

When ctrl=1, C executes. When ctrl=0, C is identity. When ctrl is a qubit in
superposition, you get the quantum-controlled version.

### 3.2 Implementation

Every gate gets ctrl as an additional control wire:

```julia
function controlled(circuit::ReversibleCircuit, ctrl_wire::WireIndex) :: ReversibleCircuit
    new_gates = map(circuit.gates) do gate
        promote_gate(gate, ctrl_wire)
    end
    return ReversibleCircuit(
        n_wires = circuit.n_wires + 1,  # one extra for ctrl
        gates = new_gates,
        # ... wire mappings adjusted
    )
end
```

Gate promotion rules:

```julia
function promote_gate(g::NOTGate, ctrl)
    # NOT(t) → CNOT(ctrl, t)
    return CNOTGate(ctrl, g.target)
end

function promote_gate(g::CNOTGate, ctrl)
    # CNOT(a, t) → Toffoli(ctrl, a, t)
    return ToffoliGate(ctrl, g.control, g.target)
end

function promote_gate(g::ToffoliGate, ctrl)
    # Toffoli(a, b, t) → controlled-Toffoli(ctrl, a, b, t)
    # Decompose into elementary gates:
    #   Use one ancilla wire, compute ctrl ∧ a into ancilla,
    #   then Toffoli(ancilla, b, t), then uncompute ancilla.
    # Total: 2 Toffoli + 1 ancilla per original Toffoli.
    return ControlledToffoliDecomposition(ctrl, g.control1, g.control2, g.target)
end
```

The decomposition of controlled-Toffoli into Toffoli + ancilla:

```
ancilla = 0
Toffoli(ctrl, a, ancilla)       # ancilla = ctrl ∧ a
Toffoli(ancilla, b, target)     # target ⊻= (ctrl ∧ a) ∧ b = ctrl ∧ a ∧ b
Toffoli(ctrl, a, ancilla)       # uncompute ancilla → 0
```

This is 3 Toffolis and 1 ancilla per original Toffoli. The ancilla is reusable
across gates (allocate once, reuse for every controlled-Toffoli in the circuit).

### 3.3 Simulator extension

The existing bit-vector simulator already handles NOT, CNOT, Toffoli. Controlled
circuits produce only these gate types (after decomposition). No simulator changes
needed.

### 3.4 Tests

**Test A1: Controlled increment**
```julia
f(x::Int8) = x + Int8(3)
circuit = reversible_compile(f, Int8)
cc = controlled(circuit)

# ctrl=1: circuit executes
for x in typemin(Int8):typemax(Int8)
    @assert simulate(cc, ctrl=true, x) == f(x)
end

# ctrl=0: identity (output is 0, input unchanged)
for x in typemin(Int8):typemax(Int8)
    @assert simulate(cc, ctrl=false, x) == 0
end
```

**Test A2: Controlled polynomial**
```julia
g(x::Int8) = x * x + Int8(3) * x + Int8(1)
circuit = reversible_compile(g, Int8)
cc = controlled(circuit)

for x in Int8(0):Int8(15)
    @assert simulate(cc, ctrl=true, x) == g(x)
    @assert simulate(cc, ctrl=false, x) == 0
end
```

**Test A3: Controlled two-arg**
```julia
m(x::Int8, y::Int8) = x * y + x - y
circuit = reversible_compile(m, Int8, Int8)
cc = controlled(circuit)

for x in Int8(0):Int8(15), y in Int8(0):Int8(15)
    @assert simulate(cc, ctrl=true, (x, y)) == m(x, y)
    @assert simulate(cc, ctrl=false, (x, y)) == 0
end
```

**Test A4: Ancillae still zero after controlled execution**
```julia
# Both ctrl=true and ctrl=false must leave all ancillae at zero.
# This is the Bennett guarantee, and it must hold for the controlled version too.
```

**Test A5: Gate count overhead**
```julia
# Print gate counts for original vs controlled.
# Expected: controlled has ~3x the Toffoli count (each Toffoli → 3),
# CNOT count increases (each NOT → 1 CNOT, each CNOT → 1 Toffoli),
# plus a small number of ancillae for the Toffoli decomposition.
```

---

## 4. Feature B: Multi-Basic-Block LLVM IR

### 4.1 What this unlocks

Single basic block handles: straight-line arithmetic, comparisons, select (ternary).

Multiple basic blocks handle:
- `if/else` (two blocks merging via phi)
- `for` loops (back-edge, induction variable via phi)
- `while` loops (conditional back-edge)
- Nested control flow

### 4.2 LLVM IR structure for branches

Julia's `code_llvm` for a function with if/else:

```julia
function p(x::Int8)
    if x > Int8(10)
        return x + Int8(1)
    else
        return x + Int8(2)
    end
end
```

Produces IR roughly like:

```llvm
define i8 @julia_p(i8 signext %0) {
entry:
  %1 = icmp sgt i8 %0, 10
  br i1 %1, label %then, label %else

then:
  %2 = add i8 %0, 1
  br label %merge

else:
  %3 = add i8 %0, 2
  br label %merge

merge:
  %4 = phi i8 [ %2, %then ], [ %3, %else ]
  ret i8 %4
}
```

### 4.3 Key new LLVM instructions to parse

| Instruction | Format | Meaning |
|---|---|---|
| `br i1 %cond, label %T, label %F` | Conditional branch | Jump to %T if cond=1, %F if cond=0 |
| `br label %dest` | Unconditional branch | Jump to %dest |
| `phi type [val1, %bb1], [val2, %bb2]` | Phi node | SSA merge: value depends on which predecessor block we came from |

### 4.4 Reversible compilation of branches

Same approach as Bennett.jl's branching: compute both branches, mux the output.

```
1. Compute condition (icmp → 1-bit wire)
2. Enter "then" block: lower all instructions unconditionally
3. Enter "else" block: lower all instructions unconditionally
4. At phi node: emit mux selecting between the two values based on condition
5. Bennett uncomputes everything as usual
```

The phi node is the key: `phi i8 [%2, %then], [%3, %else]` means "if we came
from %then, use %2; if from %else, use %3." In the reversible circuit, both
values exist on wires. The phi becomes a mux (same as `select`).

### 4.5 Reversible compilation of bounded loops

```julia
function s(x::Int8)
    acc = Int8(0)
    for i in Int8(1):Int8(4)
        acc += x
    end
    return acc
end
```

LLVM IR will have a back-edge: a `br` that jumps to a previous basic block,
and a `phi` for the loop variable.

**Strategy: rely on LLVM to unroll.**

Use `code_llvm` with optimisations enabled. For small constant bounds, LLVM
will unroll the loop entirely, producing straight-line code with no back-edges.
This is the simplest approach and handles the most common case.

```julia
ir = sprint(code_llvm, s, (Int8,); optimize=true)
# LLVM will likely unroll: acc = x + x + x + x
# Result: single basic block, no loops, already handled by v0.2
```

**If LLVM doesn't unroll** (loop bound too large or not a constant):

For v0.3, detect the back-edge and error with a clear message:
"Loop detected in LLVM IR. BennettIR.jl v0.3 requires LLVM to unroll loops.
Try a smaller loop bound, or use `@fastmath` / `@simd` hints."

Explicit loop handling (unroll in our code, emit N copies of the loop body
with muxed exit conditions) is a v0.4 feature.

### 4.6 Parser extensions

The parser needs to handle:
1. **Basic block labels**: lines ending with `:` (e.g., `then:`, `else:`, `merge:`)
2. **Branch instructions**: `br i1 %cond, label %T, label %F` and `br label %dest`
3. **Phi nodes**: `%x = phi i8 [ %a, %bb1 ], [ %b, %bb2 ]`
4. **Multiple basic blocks**: track which block each instruction belongs to

Internal representation:

```julia
struct IRBasicBlock
    label::Symbol
    instructions::Vector{IRInst}
    terminator::Union{IRBranch, IRRet}
end

struct IRBranch <: IRInst
    conditional::Bool
    cond::Union{IROperand, Nothing}  # nothing for unconditional
    true_label::Symbol
    false_label::Union{Symbol, Nothing}
end

struct IRPhi <: IRInst
    dest::Symbol
    width::Int
    incoming::Vector{Tuple{IROperand, Symbol}}  # (value, from_block) pairs
end

struct IRFunction
    name::Symbol
    args::Vector{Tuple{Symbol, Int}}  # (name, width) pairs
    blocks::Vector{IRBasicBlock}
end
```

### 4.7 Lowering multi-block IR to gates

```
For each basic block in topological order (entry first, merge blocks last):
    For each instruction in the block:
        If it's a regular instruction (add, mul, etc.):
            Lower as before (v0.2 lowering, unchanged)
        If it's a phi node:
            Emit mux: select between incoming values based on the
            branch condition that determined which predecessor was taken
        If it's a conditional branch:
            Lower the condition (it's already an i1 wire from icmp)
            Record which condition wire controls entry to which successor
        If it's an unconditional branch:
            No gates needed (just continue with the target block)
        If it's ret:
            Mark output wires
```

The tricky part: connecting phi nodes to the correct branch condition. Each phi
incoming edge corresponds to a predecessor block. The condition that selects
between predecessors is the `br i1 %cond` in the dominating block. The lowerer
must track which condition wire controls each block transition.

For v0.3, support the simple case: one conditional branch splitting into two
blocks that merge at one phi. This covers `if/else`. Nested branches work by
structural induction (inner branches are handled first, their phi outputs feed
into outer branches).

### 4.8 Tests

**Test B1: Simple if/else**
```julia
function p(x::Int8)
    if x > Int8(10)
        return x + Int8(1)
    else
        return x + Int8(2)
    end
end

circuit = reversible_compile(p, Int8)
for x in typemin(Int8):typemax(Int8)
    @assert simulate(circuit, x) == p(x)
end
```

**Test B2: Nested if/else**
```julia
function q(x::Int8)
    if x > Int8(100)
        if x > Int8(120)
            return x + Int8(3)
        else
            return x + Int8(2)
        end
    else
        return x + Int8(1)
    end
end

circuit = reversible_compile(q, Int8)
for x in typemin(Int8):typemax(Int8)
    @assert simulate(circuit, x) == q(x)
end
```

**Test B3: Loop (LLVM-unrolled)**
```julia
function s(x::Int8)
    acc = Int8(0)
    for i in Int8(1):Int8(4)
        acc += x
    end
    return acc
end

# Expect LLVM to unroll this with optimize=true
circuit = reversible_compile(s, Int8)
for x in Int8(0):Int8(63)  # keep small to avoid overflow
    @assert simulate(circuit, x) == s(x)
end
```

**Test B4: Ternary (already works but verify via branch path, not select)**

Some Julia ternaries compile to `select`, others to `br`+`phi` depending on
complexity. Test a case that LLVM compiles to `br`+`phi`:

```julia
function t(x::Int8)
    if x > Int8(0)
        y = x * x
    else
        y = x + x
    end
    return y + Int8(1)
end

circuit = reversible_compile(t, Int8)
for x in typemin(Int8):typemax(Int8)
    @assert simulate(circuit, x) == t(x)
end
```

**Test B5: All ancillae zero**
All above tests must verify ancillae are zero after simulation.

---

## 5. Implementation Plan

### Phase 1: Controlled circuits (Feature A)
- [ ] `promote_gate(gate, ctrl_wire)` for NOT → CNOT, CNOT → Toffoli
- [ ] Controlled-Toffoli decomposition (3 Toffolis + 1 ancilla)
- [ ] `controlled(circuit)` function returning new `ReversibleCircuit`
- [ ] `simulate(cc, ctrl, inputs)` — set ctrl wire, run simulator
- [ ] Test A1–A5
- [ ] Print gate count comparison: original vs controlled

### Phase 2: Parser extensions (Feature B, parsing only)
- [ ] Parse basic block labels
- [ ] Parse `br i1 %cond, label %T, label %F`
- [ ] Parse `br label %dest`
- [ ] Parse `phi i8 [ %a, %bb1 ], [ %b, %bb2 ]`
- [ ] `IRFunction` struct with multiple `IRBasicBlock`s
- [ ] Test: parse IR of `p(x::Int8)` (if/else), verify block structure
- [ ] Detect back-edges (loops). Error with clear message if found and not unrolled.

### Phase 3: Multi-block lowering (Feature B, gate emission)
- [ ] Topological sort of basic blocks
- [ ] Track branch condition wires → successor block mapping
- [ ] Lower phi nodes as mux (reuse existing mux lowering from v0.2 `select`)
- [ ] Bennett construction: no changes (still forward + copy + uncompute)
- [ ] Test B1–B5
- [ ] Print gate counts for branching functions

### Phase 4: Combined test — controlled branching function
- [ ] Compile a function with branches, then wrap in `controlled()`
- [ ] Verify correctness for ctrl=true and ctrl=false
- [ ] Verify all ancillae zero in both cases
- [ ] This is the full pipeline: Julia function with control flow → LLVM IR →
  reversible circuit → controlled circuit → verified

---

## 6. File structure changes

```
BennettIR.jl/
├── src/
│   ├── ... (existing v0.2 files)
│   ├── controlled.jl           # NEW: promote_gate, controlled()
│   ├── ir_types.jl             # MODIFIED: add IRBasicBlock, IRBranch, IRPhi, IRFunction
│   ├── ir_parser.jl            # MODIFIED: parse basic blocks, br, phi
│   └── lower.jl                # MODIFIED: multi-block lowering, phi → mux
└── test/
    ├── ... (existing v0.2 tests)
    ├── test_controlled.jl      # NEW: Tests A1–A5
    ├── test_branch.jl          # NEW: Tests B1–B2, B4
    ├── test_loop.jl            # NEW: Test B3
    └── test_combined.jl        # NEW: Phase 4 combined test
```

---

## 7. Success criteria

1. `controlled(reversible_compile(f, Int8))` produces correct results for
   ctrl=true and ctrl=false, for all test functions including polynomial
2. A Julia function with `if/else` compiles to a correct reversible circuit
   via the `br`+`phi` path (not just `select`)
3. A Julia function with a small constant loop compiles correctly via LLVM unrolling
4. The combined pipeline works: function with branches → reversible → controlled →
   correct for both ctrl values
5. All ancillae zero in all cases

## 8. Constraints

- Do NOT modify existing v0.2 tests. They must all still pass.
- Do NOT attempt explicit loop unrolling in our code. Rely on LLVM for v0.3.
  If LLVM doesn't unroll, error clearly.
- The controlled-Toffoli decomposition uses the standard 3-Toffoli construction
  with 1 ancilla. Do NOT attempt more sophisticated decompositions.
- Keep the mux approach for branches (compute both sides, select). Do NOT
  attempt the controlled-computation optimisation (adding control wires to
  inner gates of branches). That's a v0.4 optimisation.
