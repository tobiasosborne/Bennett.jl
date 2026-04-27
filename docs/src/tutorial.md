# Tutorial: Bennett.jl in 10 Minutes

This tutorial walks you through compiling Julia functions into reversible circuits. No quantum computing background required -- just basic Julia.

## 1. Your First Circuit

```julia
using Bennett

# Write a plain Julia function -- no special types needed
f(x::Int8) = x + Int8(3)

# Compile it to a reversible circuit
circuit = reversible_compile(f, Int8)

# Simulate with an input
simulate(circuit, Int8(10))  # => 13

# The circuit is verified reversible: all ancillae return to zero
verify_reversibility(circuit)  # => true
```

That's it. `reversible_compile` takes any pure Julia function on integers and produces a reversible circuit made of NOT, CNOT, and Toffoli gates.

## 2. Inspecting Circuits

```julia
# How many gates?
gc = gate_count(circuit)
println("Total: $(gc.total), NOT: $(gc.NOT), CNOT: $(gc.CNOT), Toffoli: $(gc.Toffoli)")
# Total: 102, NOT: 6, CNOT: 68, Toffoli: 28

# How many ancilla wires?
ancilla_count(circuit)  # => 76

# Circuit depth (longest gate chain, strict per-wire dependencies)
depth(circuit)  # => 77

# Toffoli-depth: longest chain of Toffoli gates only (CNOTs don't advance it).
# This is the key metric for fault-tolerant quantum cost.
toffoli_depth(circuit)  # => 28

# T-gate count (classical AMMR decomposition: each Toffoli = 7 T-gates)
t_count(circuit)  # => 196

# T-depth under different Toffoli decompositions:
t_depth(circuit)                    # => 28 (AMMR, default, 1 T-layer per Toffoli)
t_depth(circuit; decomp=:nc_7t)     # => 84 (Nielsen-Chuang 7-T, 3 T-layers per Toffoli)
```

## 3. Wider Types

Bennett.jl handles Int8, Int16, Int32, and Int64. Gate counts scale linearly:

```julia
for T in [Int8, Int16, Int32, Int64]
    c = reversible_compile(x -> x + one(T), T)
    println("$T: $(gate_count(c).total) gates")
end
# Int8:  100 gates
# Int16: 204 gates
# Int32: 412 gates
# Int64: 828 gates
```

## 4. Complex Functions

Any deterministic integer function works -- polynomials, bitwise operations, comparisons, branches:

```julia
# Polynomial
poly(x::Int8) = x * x + Int8(3) * x + Int8(1)
c_poly = reversible_compile(poly, Int8)
simulate(c_poly, Int8(5))  # => 41

# Branching (if/else compiles to MUX circuits)
clamp8(x::Int8) = x > Int8(10) ? Int8(10) : (x < Int8(0) ? Int8(0) : x)
c_clamp = reversible_compile(clamp8, Int8)
simulate(c_clamp, Int8(15))  # => 10
simulate(c_clamp, Int8(-3))  # => 0

# Multi-argument
add_mul(x::Int8, y::Int8) = x * y + x - y
c_2arg = reversible_compile(add_mul, Int8, Int8)
simulate(c_2arg, (Int8(3), Int8(4)))  # => 11
```

## 5. Float64 Support

Float64 functions compile via branchless soft-float (bit-exact with hardware):

```julia
# Float64 polynomial
g(x) = x * x + 3.0 * x + 1.0
c_float = reversible_compile(g, Float64)

# Simulate with UInt64 bit pattern
bits_in = reinterpret(UInt64, 2.0)
bits_out = simulate(c_float, bits_in)
result = reinterpret(Float64, reinterpret(UInt64, Int64(bits_out)))
println(result)  # => 11.0

verify_reversibility(c_float)  # => true
```

Float64 circuits are large (~700K gates for a polynomial) because IEEE 754 arithmetic is complex. The soft-float library handles all special cases: NaN, Inf, subnormals, signed zeros.

## 6. Controlled Circuits

For quantum control (`when(qubit) do f(x) end`), wrap any circuit with a control bit:

```julia
f(x::Int8) = x + Int8(1)
circuit = reversible_compile(f, Int8)
cc = controlled(circuit)

# Control = true: apply f
simulate(cc, true, Int8(5))   # => 6

# Control = false: identity (output is 0, not input)
simulate(cc, false, Int8(5))  # => 0

verify_reversibility(cc)  # => true
```

The controlled version promotes every gate: NOT becomes CNOT, CNOT becomes Toffoli, Toffoli decomposes into 3 Toffolis + 1 shared ancilla.

## 7. Tuple Return

Functions can return tuples:

```julia
swap(x::Int8, y::Int8) = (y, x)
c_swap = reversible_compile(swap, Int8, Int8)
simulate(c_swap, (Int8(3), Int8(7)))  # => (7, 3)
```

## 8. Strategy Dispatchers for Arithmetic

Different circuit shapes trade gate count against depth and ancilla. Pick a
strategy per operation via kwargs:

```julia
f(x, y) = x * y

# Default: shift-and-add multiplier, O(n²) Toffolis, O(n) Toffoli-depth.
c_default = reversible_compile(f, Int32, Int32)
toffoli_depth(c_default)  # => 190

# Karatsuba: O(n^log₂3) ≈ O(n^1.585) Toffolis — shallower at large W.
c_kara = reversible_compile(f, Int32, Int32; mul=:karatsuba)
toffoli_depth(c_kara)  # => 132

# Sun-Borissov 2026 QCLA-tree multiplier: O(log²n) Toffoli-depth.
c_qcla = reversible_compile(f, Int32, Int32; mul=:qcla_tree)
toffoli_depth(c_qcla)  # => 56
```

The same pattern works for addition via `add=`:

```julia
g(x, y) = x + y

# Default: auto-picks Cuccaro (in-place, 1 ancilla) when operand is dead.
c_def = reversible_compile(g, Int32, Int32)

# Draper QCLA: O(log n) Toffoli-depth instead of O(n).
c_qcla = reversible_compile(g, Int32, Int32; add=:qcla)
toffoli_depth(c_qcla)  # logarithmic
```

Supported strategies:
- `mul = :auto | :shift_add | :karatsuba | :qcla_tree`
- `add = :auto | :ripple | :cuccaro | :qcla`

When to use what:

| Caller constraint                | Best choice                 |
|---------------------------------|-----------------------------|
| Classical reversible CMOS       | `:shift_add`, `:ripple`    |
| Ancilla-constrained NISQ        | `:shift_add`, `:cuccaro`   |
| Depth-limited FTQC              | `:qcla_tree`, `:qcla`      |

See [BENCHMARKS.md](../../BENCHMARKS.md) for the headline numbers.

(Bennett-tbm6, 2026-04-27: `:karatsuba` removed — vestigial at every
supported width. The asymptotic O(W^log₂3) Toffoli savings never crossed
schoolbook's O(W²) at W ≤ 64, and `ir_extract` cannot lower W=128 today.)

## 9. Space Optimization

The default Bennett construction uses O(T) ancillae. For large circuits, use checkpoint strategies:

```julia
f(x::Int8) = x * x + Int8(3) * x + Int8(1)
parsed = Bennett.extract_parsed_ir(f, Tuple{Int8})
lr = Bennett.lower(parsed)

# Default: full Bennett
c_full = bennett(lr)
println("Full Bennett: $(c_full.n_wires) wires")

# Checkpoint: per-group checkpointing with wire reuse
c_ckpt = checkpoint_bennett(lr)
println("Checkpoint:   $(c_ckpt.n_wires) wires")

# Both produce the same correct result
for x in typemin(Int8):typemax(Int8)
    @assert simulate(c_full, x) == simulate(c_ckpt, x)
end
```

## 10. Loops

Functions with bounded loops compile via loop unrolling:

```julia
function collatz_steps(x::Int8)
    n = x; steps = Int8(0)
    while n > Int8(1) && steps < Int8(5)
        n = ifelse(n & Int8(1) == Int8(0), n >> 1, Int8(3) * n + Int8(1))
        steps += Int8(1)
    end
    return steps
end

# Specify max iterations for the unroller
c = reversible_compile(collatz_steps, Int8; max_loop_iterations=20)
simulate(c, Int8(6))  # => 5 (6 -> 3 -> 10 -> 5 -> 16 -> 8, 5 steps capped)
```

## 11. What's Next

- **Sturm.jl integration**: use Bennett.jl circuits as quantum-controlled operations
- **Custom callees**: `register_callee!(my_function)` for gate-level inlining
- **NTuple input**: pass fixed-size arrays as flat wire arrays

See the [API Reference](api.md) for the full function list, and the [Architecture Guide](architecture.md) for how the compiler works internally.
