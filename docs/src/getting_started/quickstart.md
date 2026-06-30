# Quickstart

*A five-minute tour for someone who just installed Bennett.jl and wants to see a plain Julia function turn into a reversible circuit — and trust the result.*

Bennett.jl takes an ordinary Julia function on integers (or `Float64`) and compiles it into a classical **reversible** circuit built from only three gate types — NOT, CNOT, and Toffoli — via Bennett's 1973 construction. No special types, no operator overloading: you write `x*x + 3x + 1`, you get a circuit `(x, 0) → (x, f(x))` whose ancillae all return to zero.

This page assumes you have the package available:

```julia
using Bennett
```

Everything below runs as written. The numbers in the `# =>` comments are live outputs (Julia 1.12).

## Compile a polynomial

Start with a small polynomial on `Int8`. Compile it, run it, and check the gate budget:

```julia
f(x::Int8) = x*x + Int8(3)*x + Int8(1)

c = reversible_compile(f, Int8)

simulate(c, Int8(5))   # => 41   (25 + 15 + 1)
```

`reversible_compile(f, Int8)` extracts the function's LLVM IR (via LLVM.jl's C API), lowers each instruction to reversible gates, and wraps the whole thing in Bennett's forward + copy + reverse construction. `simulate` then runs the circuit as a bit-vector and reads back the output register.

Two things are worth knowing up front:

- **`gate_count` returns a `NamedTuple`, not an `Int`.** It breaks the total down by gate type.
- **`simulate` returns an `Integer`** (or a `Tuple` for multi-output functions), reinterpreted to the right width and signedness.

```julia
gate_count(c)   # => (total = 482, NOT = 14, CNOT = 300, Toffoli = 168)

verify_reversibility(c)   # => true
```

`verify_reversibility(c; n_tests=100)` is the one you should always run. For 100 random inputs it asserts three invariants: every ancilla wire returns to zero, every input wire is preserved, and running the gates forward then in reverse restores the initial state. "It ran without erroring" is *not* a passing circuit — this check is. See `src/diagnostics.jl`.

## The increment, measured four ways

The smallest interesting circuit is `x + 1`. It is also the regression baseline pinned in `test/test_gate_count_regression.jl`, so its metrics are stable and worth memorising as a sanity anchor:

```julia
c = reversible_compile(x -> x + Int8(1), Int8)

gate_count(c).total    # => 58   (NOT = 6, CNOT = 40, Toffoli = 12)
ancilla_count(c)       # => 25   scratch wires, all guaranteed to return to 0
t_count(c)             # => 84   = 7 × Toffoli (Clifford NOT/CNOT cost 0 T)
toffoli_depth(c)       # => 12   longest chain of Toffoli gates
```

Each metric answers a different question. `gate_count` is total size; `ancilla_count` is scratch-space cost; `t_count` and `toffoli_depth` are the fault-tolerant-quantum metrics (T-gates dominate the cost of error-corrected execution, and Toffoli depth bounds the circuit's latency). All live in `src/diagnostics.jl`; `depth(c)` (here `19`) gives the longest data-dependence chain over *all* gate types.

These numbers come from the default compile, which is identical to `add=:ripple, fold_constants=true`. (`add=:auto` always resolves to ripple-carry — see [the API reference](../reference/api.md).)

## Make it controllable

A reversible circuit can be lifted to take an explicit **control bit**: when the control is on, it computes `f`; when off, it does nothing. This is the hook that makes Bennett.jl useful for quantum control (`when(qubit) do f(x) end`, the long-term Sturm.jl goal).

```julia
c  = reversible_compile(x -> x + Int8(1), Int8)
cc = controlled(c)                  # ControlledCircuit

simulate(cc, true,  Int8(42))   # => 43   control on:  f(42) = 43
simulate(cc, false, Int8(42))   # => 0    control off: output register stays 0
```

Note the off case returns **`0`, not the input** — when the control bit is low, the output register is never written, so it holds its initial zero value. (The input is still preserved internally; it just isn't copied out.) See `src/controlled.jl`.

## Float64 works too

Floating point goes through a bit-exact soft-float library (`src/softfloat/`, `module SoftFloatLib`): every IEEE 754 `Float64` operation is reimplemented in pure integer arithmetic so it lowers to the same NOT/CNOT/Toffoli gates. `+`, `-`, `*`, `/`, `fma`, `sqrt`, comparisons, conversions and rounding are bit-exact against Julia's native `Float64`:

```julia
c = reversible_compile(x -> x*x - 2.0, Float64)
```

Two honest caveats: the transcendentals (`exp`, `log`, `sin`, `cos`, `pow`, the hyperbolics, …) are accurate to ≤ 2 ulp rather than bit-exact, and **`Float32` is rejected** — there are no native f32 arithmetic primitives to be bit-exact against. See `src/softfloat/fpconv.jl` and the [explanation pages](../explanation/architecture.md) for why.

## Where next

You have now compiled three functions, measured four resource metrics, added a control bit, and touched soft-float. To go deeper:

- **[Your first circuit, step by step](../tutorials/first_circuit.md)** — a slower, learning-by-doing walkthrough of the extract → lower → Bennett → simulate pipeline.
- **[Adders and multipliers](../howto/arithmetic_strategy.md)** — choosing `add ∈ {:ripple, :cuccaro, :qcla}` and `mul ∈ {:shift_add, :qcla_tree}`, and what each trades off (`(x,y)->x*y` on `Int32` drops from Toffoli-depth `180` to `56` under `mul=:qcla_tree`).
- **[Compiling floating point](../tutorials/floats.md)** — how the soft-float path lowers `Float64`, and where the bit-exact contract ends.
- **[Memory and lookup tables](../howto/reversible_memory.md)** — arrays, reversible store/load, and QROM table lookup.
- **[API reference](../reference/api.md)** — every `reversible_compile` keyword (all 13), the `CompileOptions` bundle, the metric functions, and the supported input types.
- **[How it works](../explanation/architecture.md)** — Bennett's construction, phi-resolution, and why the design is the way it is.

If you just want the big picture, the [project README](../../../README.md) is the one-page overview.

---

*Bennett, C. H. (1973). "Logical Reversibility of Computation." IBM J. Res. Dev. 17(6), 525–532. [doi:10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525).*
