# Make a circuit quantum-controllable

*Goal-first recipe: take a compiled reversible circuit `c` and lift it to a
`ControlledCircuit` that runs `f` only when a control bit is set. For readers
who already have a circuit from `reversible_compile` and want `ctrl ? f(x) : 0`.*

## The recipe

```julia
using Bennett

c  = reversible_compile(x -> x + Int8(1), Int8)
cc = controlled(c)
```

`controlled(c::ReversibleCircuit)` returns a `ControlledCircuit` — every gate
in `c` is rewritten so that it fires only when a dedicated control wire holds
`1`. Both `controlled` and `ControlledCircuit` are exported. The
implementation is `src/controlled.jl`.

## The invariant

A controlled circuit reserves a fresh control wire and a fresh output
register. Its contract is:

```
(ctrl, x, 0)  →  (ctrl, x, ctrl ? f(x) : 0)
```

- The input `x` round-trips unchanged (it is a read-only control of the
  inner gates).
- The control bit `ctrl` round-trips unchanged.
- The output register starts at `0`. When `ctrl == 1` it ends holding
  `f(x)`; when `ctrl == 0` it stays `0`.

The off-branch leaves the output register at **zero**, not at the input — the
gates simply never fire. This is the whole point: an un-selected branch
produces a clean zero ancilla, not garbage.

## Run it: on-branch vs off-branch

Evaluate with `simulate(cc, ctrl::Bool, input)`. It prepends `Int(ctrl)` to
the inputs internally and delegates to the inner circuit's simulator, so the
ancilla-zero and input-preservation assertions all still run.

```jldoctest control; setup = :(using Bennett)
julia> c  = reversible_compile(x -> x + Int8(1), Int8);

julia> cc = controlled(c);

julia> simulate(cc, true,  Int8(42))   # control on:  f(42) = 43
43

julia> simulate(cc, false, Int8(42))   # control off: output register stays 0
0
```

The `false` case returns `0`, the all-zero output value — **not** `42`. The
input wire still carries `42` internally; it is the *output register* that
stays zero because no controlled gate fired.

Check the full Bennett invariant on random `(ctrl, input)` pairs:

```jldoctest control
julia> verify_reversibility(cc)
true
```

`verify_reversibility(cc; n_tests::Int=100)` delegates to the inner
`ReversibleCircuit` probe, which asserts (1) all ancillae return to zero,
(2) every input wire — including the control — is preserved, and (3) the
forward+reverse round trip restores the initial state.

## Gate promotion

`controlled()` rewrites each primitive gate by adding the control bit as an
extra positive control. The promotion rules (`src/controlled.jl`,
`promote_gate!`) are:

| Inner gate | Becomes | Extra wires |
|------------|---------|-------------|
| `NOTGate(t)` | `CNOTGate(ctrl, t)` | none |
| `CNOTGate(c, t)` | `ToffoliGate(ctrl, c, t)` | none |
| `ToffoliGate(c1, c2, t)` | 3 Toffolis: `(ctrl,c1,a)`, `(a,c2,t)`, `(ctrl,c1,a)` | 1 reusable ancilla `a` |

A controlled-Toffoli (a 3-control AND) has no single-gate classical
primitive, so it is decomposed into three Toffolis around one borrowed
ancilla `a`: compute `a = ctrl ∧ c1`, flip the target by `a ∧ c2`, then
uncompute `a`. The control wire is allocated at `n_wires + 1`; the shared
ancilla — allocated only if the inner circuit contains at least one Toffoli —
sits at `n_wires + 2`. `controlled()` asserts on entry that no inner gate
already references a wire beyond `n_wires` (Bennett-pksz / U98), failing loud
if the contiguous-wire assumption is violated.

You can watch the promotion in the gate counts. `gate_count` returns a
`NamedTuple`, so the per-class breakdown is visible:

```jldoctest control
julia> gate_count(c)              # the inner x+1 circuit
(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)

julia> gate_count(cc.circuit)     # after promotion
(total = 82, NOT = 0, CNOT = 6, Toffoli = 76)
```

The arithmetic checks out: the 6 NOTs become 6 CNOTs, the 40 CNOTs become 40
Toffolis, and the 12 Toffolis expand to 36 Toffolis (3 each) — giving
`6` CNOT and `40 + 36 = 76` Toffoli, with no NOTs left.

## Why this exists: Sturm.jl `when(qubit) do … end`

The motivating use case is quantum control in Sturm.jl. A construct like

```julia
when(qubit) do
    f(x)
end
```

should apply `f` to a quantum register conditioned on a control qubit — the
defining move of quantum control flow. `controlled()` is exactly that lift:
compile `f` to a classical reversible circuit once, then wrap it so the whole
oracle runs under a single control qubit. The control wire becomes the
qubit; the `(ctrl, x, 0) → (ctrl, x, ctrl ? f(x) : 0)` invariant is the
semantics `when` needs, with the off-branch guaranteed to leave a clean zero
output rather than an entangled mess.

## Aside: self-reversing primitives and peak-qubit savings

Most circuits are built by Bennett's 1973 construction — run the gates
forward, CNOT-copy each output to a fresh wire, then run the gates in reverse
to clean every intermediate ancilla (`src/bennett_transform.jl`; Bennett,
*Logical Reversibility of Computation*, IBM J. Res. Dev. 17(6):525–532, 1973,
[doi:10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525)). That wrap
roughly doubles the gate count and needs one copy wire per output.

Some primitives — the soft-float kernels and QROM table lookups — are emitted
**self-reversing**: they leave no dirty intermediate ancillae, so the
compiler skips the copy-and-reverse wrap and runs them forward-only. That
lowers `peak_live_wires` (no per-output copy register) and halves their gate
contribution. The self-reversing fast path is honored by all six Bennett
space-time strategies (Bennett-rjk7), not just the default.

`controlled()` is orthogonal to this: it promotes whatever gate stream the
circuit already has, self-reversing or not. Controlling a self-reversing
primitive inherits its lower peak-qubit footprint, since there is no copy
register to control in the first place.

## See also

- [API reference](../reference/api.md) — `controlled`, `ControlledCircuit`,
  `simulate`, `verify_reversibility`, `gate_count`.
- [Compiling a function](../tutorials/first_circuit.md) — producing the
  inner `ReversibleCircuit` you pass to `controlled()`.
- [The Bennett construction](../explanation/bennett_construction.md) — why the
  forward+copy+reverse wrap returns every ancilla to zero.
- [`README.md`](../../../README.md) — project overview and the Sturm.jl quantum
  control roadmap.
