# Target the reversible VM

*For the task: you have a Julia function whose loop count or memory size the **input** decides — a `while`, a Collatz orbit, a runtime-sized buffer — and a fixed circuit cannot express it. This recipe compiles such a function to a `BennettVM.VMProgram` instead.*

## When you need this

A `ReversibleCircuit` is a *fixed permutation*: it has no program counter and no
runtime-sized memory, so every loop must be statically bounded (unrolled at
compile time) and every array statically sized. When the trip count or the
allocation size is a function of the input — `while n > 1`, a data-dependent
recursion, a `Dict` that grows at runtime — there is no finite gate network that
covers all inputs. The circuit backend rejects (or cannot bound) these programs.

Bennett.jl's second lowering target closes that gap. `target = :reversible_vm`
hands the lowered program to **BennettVM**, a reversible abstract machine that
*interprets* the program forward and backward instead of flattening it into
gates. Same LLVM-IR frontend, different artifact.

## Recipe

```julia
using Bennett
using BennettVM    # registers the :reversible_vm backend (see "If you forget using BennettVM")

function collatz_steps(n::Int64)
    steps = 0
    while n > 1
        n = iseven(n) ? n ÷ 2 : 3n + 1
        steps += 1
    end
    return steps
end

prog = reversible_compile(collatz_steps, Int64; target = :reversible_vm)
# prog isa BennettVM.VMProgram
```

`reversible_compile(f, T; target = :reversible_vm)` returns a
`BennettVM.VMProgram` — reversible bytecode (basic blocks + a label table), not a
`ReversibleCircuit`. Every other `reversible_compile` keyword still applies; only
the artifact at the end changes.

This is not aspirational: the end-to-end Collatz round-trip is **shipped**
(BennettVM milestone **M13**). BennettVM's own suite compiles `collatz_steps`
through this exact one-liner, runs it forward to the irreversible `Int64` Collatz
oracle, and then `unrun!`s back to the initial state across a battery of inputs
(including the `x = 27` orbit).

### If you forget `using BennettVM`

The VM backend is opt-in. Bennett.jl does **not** depend on BennettVM (the reverse
dependency would be a cycle), so until `using BennettVM` registers the backend a
`:reversible_vm` compile fails loud rather than silently producing a circuit:

```julia
reversible_compile(collatz_steps, Int64; target = :reversible_vm)
# ERROR: reversible_compile(target=:reversible_vm) requires the BennettVM
#        backend to be loaded: `using BennettVM` registers it.
```

The hook lives in `src/Bennett.jl`: a module-scoped `_REVERSIBLE_VM_BACKEND =
Ref{Any}(nothing)` that BennettVM's `__init__` write-registers at load time. The
`:reversible_vm` arm is intercepted in the `ParsedIR` `reversible_compile`
overload before the circuit compile cache, so both the Julia-function route and
the pre-extracted `.ll`/`.bc` route reach the same fork.

## Circuit vs VM at a glance

| | `target = :gate_count` / `:depth` (default) | `target = :reversible_vm` |
|---|---|---|
| **Artifact** | `ReversibleCircuit` (fixed Toffoli network) | `BennettVM.VMProgram` (reversible bytecode) |
| **Loops** | statically bounded — explicit unroll | data-dependent — run to completion |
| **Memory** | statically sized | runtime-sized |
| **Reversibility** | Bennett forward + CNOT-copy + reverse | history tape (checkpoint / replay) |
| **Run it** | `simulate(c, x)` | `run!(s, prog)` / `unrun!(s, prog)` |
| **Use** | quantum oracle / hardware synthesis | terminating classical programs of unknown length |

The default (`target = :gate_count`, or `:depth` for a Toffoli-depth-optimised
network) is unchanged — see the [tutorial](../tutorials/first_circuit.md) and
[API reference](../reference/api.md). There is no `target = :circuit` symbol; the circuit
path is selected by *not* asking for the VM.

## Running the VMProgram

A `VMProgram` is executed by the machine in the sibling repo, not by Bennett.jl.
The driver is a reversible interpreter over an `RState` (the machine's
register/history state):

```julia
run!(s::RState, prog::VMProgram; max_steps = 10_000) -> RState        # forward
unrun!(s::RState, prog::VMProgram; max_unsteps = 10_000) -> RState    # back to step 0
```

`run!` steps until the program halts (or the `max_steps` guard fires — Phase-2
programs may diverge, so the bound is mandatory and errors descriptively).
`unrun!` reverses the interpreter all the way back, asserting the structural exit
invariant `isempty(s.history)`. The defining round-trip property is

```
unrun!(run!(s, prog)) == initial(s)   &&   isempty(s.history)
```

The driver, the instruction set, the `RState` history-tape mechanism, and the
construction of the initial state all live in BennettVM — start at
[`../../../../BennettVM.jl`](../../../../BennettVM.jl) (`run!` is in
`src/interpreter/Interpreter.jl`, `unrun!` in `src/history/Replay.jl`, the state
and its invariants in `src/ir/RState.jl`).

## Honest status: the VM frontier is moving

Scalar, data-dependent control flow (the Collatz case) round-trips today. The
part that is **actively advancing** is extraction of *runtime-sized memory* —
specifically closed-world lowering of Julia `Dict` internals (`setindex!`,
`rehash!`, `ht_keyindex2_shorthash!`) under the `ptr_cells` extraction gate,
where pointers are modelled as 64-bit virtual cells. That work lands wall by wall
on the way to a full `Dict`-backed program through the VM; it is the current P0
critical path and not yet complete. The finest-grained latest state is in the
highest-numbered `worklog/NNN_*.md` chunk; the README's "Project status" section
tracks the same reversible-VM frontier at a higher level.

What you can rely on now: the `target = :reversible_vm` dispatch is shipped and
stable, and a terminating scalar program with a data-dependent loop compiles and
round-trips end-to-end.

## See also

- [BennettVM.jl](../../../../BennettVM.jl) — the machine: its ISA, the
  `run!`/`unrun!` driver, and the history-tape reversibility model.
- [API reference](../reference/api.md) — the full `reversible_compile` keyword set and
  `CompileOptions` bundle.
- [Architecture](../explanation/architecture.md) — where the VM fork sits in the
  extract → lower → bennett → simulate pipeline.
- [Project README](../../../README.md) — the "Two backends, one front door"
  overview.
