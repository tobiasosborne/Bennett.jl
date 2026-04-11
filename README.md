# Bennett.jl

**The Enzyme of reversible computation.** An LLVM-level compiler that transforms arbitrary pure functions into reversible circuits (NOT, CNOT, Toffoli gates) via [Bennett's 1973 construction](https://doi.org/10.1137/0218053).

```julia
using Bennett

# Any pure Julia function — no special types, no annotation
f(x::Int8) = x * x + Int8(3) * x + Int8(1)

circuit = reversible_compile(f, Int8)
simulate(circuit, Int8(5))   # => 41
verify_reversibility(circuit) # => true
gate_count(circuit)           # => 872

# Float64 works too (via branchless soft-float, bit-exact with hardware)
g(x::Float64) = x^2 + 3.0*x + 1.0
circuit_f = reversible_compile(g, Float64)
```

## What This Does

Given any pure, deterministic function `f`, Bennett.jl produces a reversible circuit `(x, 0) -> (x, f(x))` using only NOT, CNOT, and Toffoli gates, with all ancillae verified zero. The circuit is correct by construction.

The compiler extracts LLVM IR from plain Julia functions via [LLVM.jl](https://github.com/maleadt/LLVM.jl)'s C API, walks the IR as typed objects, lowers each instruction to reversible gates, and applies Bennett's construction. No operator overloading, no special types -- plain Julia in, reversible circuit out.

## Why

- **Quantum control**: `when(qubit) do f(x) end` -- any classical computation becomes a quantum-controlled operation
- **Reversible hardware synthesis**: direct compilation to Toffoli networks for adiabatic/reversible CMOS
- **Space-optimized quantum oracles**: Grover, phase estimation, QSVT all need reversible implementations of classical functions

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/tobiasosborne/Bennett.jl")
```

Requires Julia 1.10+ and LLVM.jl.

## Features

### Instruction Coverage

34 LLVM opcodes + 12 intrinsics. 30/30 audit functions compile to verified reversible circuits:

| Category | Instructions |
|----------|-------------|
| Integer arithmetic | `add`, `sub`, `mul`, `udiv`, `sdiv`, `urem`, `srem` |
| Bitwise | `and`, `or`, `xor`, `shl`, `lshr`, `ashr` |
| Comparison | `icmp` (all 10 predicates) |
| Control flow | `br`, `switch`, `phi`, `select`, `ret`, `unreachable` |
| Type conversion | `sext`, `zext`, `trunc`, `freeze`, `fptosi`, `sitofp`, `bitcast` |
| Aggregates | `insertvalue`, `extractvalue` |
| Memory (static) | `getelementptr` (const + variable index), `load` |
| Calls | `call` (registered callees, gate-level inlining) |
| Float | `fadd`, `fsub`, `fmul`, `fdiv`, `fneg`, `fcmp` (6 predicates) |

### Space Optimization

Multiple Bennett construction strategies with per-group checkpointing:

| Strategy | SHA-256 round wires | Reduction |
|----------|-------------------|-----------|
| Full Bennett | 2,049 | baseline |
| `checkpoint_bennett` | 1,761 | 14% |
| Cuccaro in-place adder | 1,545 | 25% |

### Wider Types and Composability

- **Int8/16/32/64**: gate count scales linearly (2x per width doubling)
- **Float64**: full IEEE 754 via branchless soft-float (add/sub/mul/div/cmp, bit-exact)
- **Tuple return**: `(new_a, new_e) = sha256_round(a, b, c, d, e, f, g, h, k, w)`
- **NTuple input**: pointer parameters handled via static memory flattening
- **Controlled circuits**: `controlled(circuit)` wraps every gate with a control bit
- **Function inlining**: `register_callee!(f)` enables gate-level inlining of any pure function

## Quick Start

```julia
using Bennett

# Compile a function
circuit = reversible_compile(x -> x + Int8(1), Int8)

# Simulate
simulate(circuit, Int8(42))  # => 43

# Inspect
gate_count(circuit)           # => 100
ancilla_count(circuit)        # => 76
t_count(circuit)              # => 196  (Toffoli * 7)
verify_reversibility(circuit) # => true

# Controlled version (for quantum control)
cc = controlled(circuit)
simulate(cc, true, Int8(42))  # => 43 (control = true)
simulate(cc, false, Int8(42)) # => 42 (control = false)
```

## Build & Test

```bash
cd Bennett.jl
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Architecture

```
Julia function          LLVM IR              Reversible Circuit
-----------------      ---------            ------------------
f(x::Int8)     -->  extract_parsed_ir()  -->  lower()  -->  bennett()
                     (LLVM.jl C API)          (gates)       (fwd + copy + undo)
                                                                |
                                                                v
                                                          simulate(circuit, input)
                                                          verify_reversibility()
```

1. **Extract** -- `extract_parsed_ir(f, arg_types)` uses LLVM.jl C API to walk IR as typed objects
2. **Lower** -- `lower(parsed_ir)` maps each instruction to reversible gates (NOT, CNOT, Toffoli)
3. **Bennett** -- `bennett(lr)` applies forward + CNOT-copy + reverse (all ancillae return to zero)
4. **Simulate** -- `simulate(circuit, input)` runs bit-vector simulation with ancilla verification

## Documentation

- **[Tutorial](docs/src/tutorial.md)** -- compile your first reversible circuit in 10 minutes
- **[API Reference](docs/src/api.md)** -- every exported function with examples
- **[Architecture Guide](docs/src/architecture.md)** -- how the compiler works internally
- **[Vision PRD](Bennett-VISION-PRD.md)** -- the full v1.0 roadmap and Enzyme analogy

## Key References

| Tag | Paper | Key result |
|-----|-------|------------|
| Bennett 1989 | Time/Space Trade-Offs for Reversible Computation | O(T^{1+e}) time, O(S log T) space |
| Knill 1995 | Analysis of Bennett's Pebble Game | Exact pebbling recursion |
| PRS15 | Reversible Circuit Compilation with Space Constraints | EAGER cleanup: 5.3x reduction on SHA-2 |
| Cuccaro 2004 | A New Reversible Carry Look-Ahead Adder | In-place adder: 1 ancilla |
| Reqomp 2024 | Space-constrained Uncomputation | Lifetime-guided: up to 96% reduction |

## License

[AGPL-3.0](LICENSE)
