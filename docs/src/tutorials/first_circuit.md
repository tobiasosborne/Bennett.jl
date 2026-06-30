# Your first reversible circuit

*A hands-on onramp: compile a one-line Julia function into a reversible
circuit, run it, read its cost metrics, and prove it is correct — in about
five minutes at the REPL.*

You will take the smallest interesting function, `x -> x + Int8(1)`, all the
way through Bennett.jl's pipeline. By the end you will have a
`ReversibleCircuit` built only from NOT, CNOT, and Toffoli gates that computes
`x + 1` on 8-bit integers, you will have checked it against the plain Julia
function on **all 256** inputs, and you will know what every number the
compiler reports actually means.

The only prerequisite is a Julia session with the package available. Start one
with `julia --project` from the repository root, then follow along — every
block below is a real REPL transcript with the real output.

## Step 1 — Compile

`reversible_compile(f, ArgType)` is the single front door. Hand it a plain
Julia function and the concrete type of its argument; it extracts the LLVM IR,
lowers each instruction to reversible gates, and applies Bennett's
construction. The result is a `ReversibleCircuit`.

```jldoctest first_circuit
julia> using Bennett

julia> c = reversible_compile(x -> x + Int8(1), Int8);
```

A note on the literal: writing `Int8(1)` (rather than a bare `1`, which is an
`Int64`) keeps the whole computation in 8-bit arithmetic. If the argument and
the constant disagreed on width, Julia would promote to `Int64` and you would
compile a 64-bit adder by accident. Match your literals to your argument type.

The trailing `;` suppresses display — a `ReversibleCircuit` prints its full
summary when shown (that is [Step 5](#Step-5-—-Peek-at-the-gates)).

Supported argument types are `Int8/16/32/64`, `UInt8/16/32/64`, `Float64`,
`Bool`, and flat concrete `NTuple`s of those. `Float32` is rejected — see the
note in `src/softfloat/fpconv.jl` for why.

## Step 2 — Simulate

A `ReversibleCircuit` is not a Julia function you can call directly; you
*simulate* it. `simulate(c, x)` runs the gate list forward on a zeroed
bit-vector with `x` loaded into the input wires, and reads the output wires
back as an integer.

```jldoctest first_circuit
julia> simulate(c, Int8(5))
6

julia> simulate(c, Int8(41))
42
```

One value proves nothing. The point of compiling a *circuit* is that it must
agree with the source function on **every** input. `Int8` has only 256 values,
so check them all against the Julia function it was built from:

```jldoctest first_circuit
julia> all(simulate(c, x) == x + Int8(1) for x in typemin(Int8):typemax(Int8))
true
```

That includes the wrap-around at the top of the range: `simulate(c,
Int8(127))` returns `-128`, exactly as `Int8(127) + Int8(1)` does in Julia.
Two's-complement overflow is preserved because the compiled adder *is* the
two's-complement adder — there is no separate semantics to drift.

Exhaustive checks like this are the project's house style. For widths beyond
`Int8`, where `2^W` is too large to sweep, test representative values plus the
edge cases (`0`, `typemin`, `typemax`, and the carry boundaries).

## Step 3 — Inspect the cost

A reversible circuit has a *cost*, and the cost is the whole point: it tells
you how expensive this computation would be to run on reversible or quantum
hardware. The metrics live in `src/diagnostics.jl`. Here are the five you will
reach for most often.

```jldoctest first_circuit
julia> gate_count(c)
(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)

julia> ancilla_count(c)
25

julia> t_count(c)
84

julia> toffoli_depth(c)
12

julia> depth(c)
19
```

What each one means:

- **`gate_count`** returns a *NamedTuple*, not a single integer. `total` is the
  length of the gate list; `NOT`, `CNOT`, and `Toffoli` are the per-type counts
  and always sum to `total`. These are the only three gate types Bennett.jl
  emits — they are universal for classical reversible logic. Access a field
  with `gate_count(c).Toffoli`. These counts are pinned as regression baselines
  (`test/test_gate_count_regression.jl`): for the explicit `add=:ripple` strategy
  (which the default `add=:auto` resolves to), `x + Int8(1)` is `58` total, and
  each doubling of width follows `total(2W) == 2·total(W) − 2`.

- **`ancilla_count`** is the number of scratch wires — `25` here. Ancillae hold
  intermediate values (carries, partial sums) during the forward pass. Bennett's
  construction guarantees every one of them returns to zero by the end; that
  guarantee is what [Step 4](#Step-4-—-Verify-reversibility) checks.

- **`t_count`** counts T-gates in the fault-tolerant (Clifford+T) decomposition.
  NOT and CNOT are Clifford gates and cost nothing here; each Toffoli decomposes
  to 7 T-gates, so `t_count == 7 × Toffoli` — `7 × 12 == 84`. On error-corrected
  quantum hardware the T-gates dominate the resource budget, which is why this
  number gets its own function.

- **`toffoli_depth`** is the longest chain of Toffoli gates along a
  data-dependence path — `12`. NOT and CNOT do not advance it. It is a latency
  proxy: gates off the critical path can run in parallel, so depth, not raw
  count, bounds how fast the circuit can finish. `t_depth(c)` scales this by a
  per-Toffoli layer cost (`1` for the default `:ammr` decomposition, `3` for
  `:nc_7t`).

- **`depth`** is the same longest-chain measure but over *all* gate types —
  `19`. It is always at least `toffoli_depth`.

## Step 4 — Verify reversibility

`simulate` already asserts Bennett's invariants on every call, but
`verify_reversibility` makes the check explicit and exhaustive across random
inputs. It is the function you put in a test.

```jldoctest first_circuit
julia> verify_reversibility(c)
true
```

It returns `true` or it raises an error with context — there is no quiet
failure. For each of `n_tests` random inputs (default `100`), after running the
gates forward it asserts three things:

1. **Ancilla-clean** — every wire in `c.ancilla_wires` is back to zero. A
   leaked ancilla means the construction did not uncompute its scratch space,
   which on real hardware would leave entangled garbage behind.
2. **Input-preserved** — every input wire still holds its original value. The
   forward pass writes the answer to *fresh* output wires; it must not clobber
   the input.
3. **Round-trip** — running the gate list in reverse restores the initial
   bit-vector exactly.

Be honest about what carries the weight here: check (3) is mathematically
automatic for any sequence of self-inverse gates (and NOT, CNOT, Toffoli are
all self-inverse), so it mostly catches harness bugs. The real teeth are (1)
and (2) — an earlier version of this function checked only (3) and silently
missed every ancilla-leak and input-corruption bug (Bennett-asw2 / U01). Tune
the coverage with `verify_reversibility(c; n_tests=1000)`.

## Step 5 — Peek at the gates

`print_circuit` gives a one-screen summary. It is also the `Base.show` method,
so just evaluating a circuit at the REPL (without the `;`) prints the same
thing.

```jldoctest first_circuit
julia> print_circuit(c)
ReversibleCircuit:
  Wires:     41
  Input:     8 wires [8]
  Output:    8 wires
  Ancillae:  25
  Gates:     58 (NOT=6, CNOT=40, Toffoli=12)
  Depth:     19
  Peak live: 4
```

Reading it: `41` total wires partition into `8` input, `8` output, and `25`
ancilla (`8 + 8 + 25 = 41`). The gate line and depth echo the metrics from
Step 3. `Peak live` is new — it is the maximum number of simultaneously
non-zero wires during the run (`4`), i.e. the working width of the
state-vector, the quantity that space-minimizing strategies try to shrink. See
[`peak_live_wires`](../reference/autodocs.md).

A `ReversibleCircuit` is also iterable, so you can walk the individual gates
when you want to see them — `for g in c; @show g; end`, or `c[1]` for the
first.

## What just happened

That one `reversible_compile` call ran three stages (see `Bennett.jl`'s module
docstring and `src/Bennett.jl`):

1. **Extract** — `extract_parsed_ir` walks the function's LLVM IR through
   LLVM.jl's C API and builds a typed `ParsedIR`. The IR walker is the single
   source of truth; there is no regex parsing of IR text.
2. **Lower** — `lower` maps each IR instruction to reversible gates. The `+`
   here became a ripple-carry adder (the default `add=:auto` resolves to
   `:ripple`), and because
   `fold_constants=true` the `+ 1` was specialized to an increment rather than a
   general two-operand add.
3. **Bennett** — `bennett` applies the 1973 construction: run the lowered
   computation **forward**, **CNOT-copy** the result onto the output wires, then
   run the computation **in reverse** to wipe every ancilla back to zero. That
   forward-copy-reverse sandwich is why the circuit is reversible and why the
   25 ancillae all return to zero. (Bennett, *Logical Reversibility of
   Computation*, IBM J. Res. Dev. **17**(6), 1973,
   [doi:10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525).)

The defaults you got — `add=:auto` (which selects ripple-carry),
`fold_constants=true`, and the rest — are the values of a `CompileOptions` struct. You can override any of them as
keyword arguments, e.g. `reversible_compile(f, Int32, Int32; mul=:qcla_tree)`
to pick a different multiplier.

## Where to go next

- Try a richer function: `f(x) = x*x + Int8(3)*x + Int8(1)` compiles to `482`
  gates (`168` Toffoli) and `simulate(c, Int8(5))` gives `41` — verify the
  whole sweep yourself.
- The full keyword-argument surface (`add`, `mul`, `strategy`, `mem`,
  `target=:reversible_vm`, and the `CompileOptions` bundle) is in the
  [API reference](../reference/autodocs.md) and `src/Bennett.jl`.
- The pipeline and the Bennett construction are explained in depth in the
  [architecture notes](../explanation/architecture.md).
- For the bigger picture and project rules, see the
  [README](../../../README.md).
