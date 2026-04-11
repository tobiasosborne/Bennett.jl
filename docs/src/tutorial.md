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

# Circuit depth (longest gate chain)
depth(circuit)  # => 50

# T-gate count (for fault-tolerant quantum computing)
t_count(circuit)  # => 196  (each Toffoli = 7 T-gates)
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

## 8. Space Optimization

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

## 9. Loops

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

## 10. What's Next

- **Sturm.jl integration**: use Bennett.jl circuits as quantum-controlled operations
- **Custom callees**: `register_callee!(my_function)` for gate-level inlining
- **NTuple input**: pass fixed-size arrays as flat wire arrays

See the [API Reference](api.md) for the full function list, and the [Architecture Guide](architecture.md) for how the compiler works internally.
