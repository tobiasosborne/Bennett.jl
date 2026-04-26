# Bennett.jl

A Julia → reversible circuit compiler. Plain Julia functions on integers
(and `Float64` via soft-float) compile down to NOT / CNOT / Toffoli gates
via Bennett's 1973 forward + copy + uncompute construction.

Long-term goal: quantum control in
[Sturm.jl](https://github.com/tobiasosborne/Sturm.jl) via
`when(qubit) do f(x) end`.

## Quick start

```julia
using Bennett

c = reversible_compile(x -> x + Int8(1), Int8)
simulate(c, Int8(5))         # => 6
gate_count(c)                # => (total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
verify_reversibility(c)      # => true
```

## Pages

- **[Tutorial](tutorial.md)** — compile your first function in 10 minutes.
- **[API Reference](api.md)** — curated reference, organised by topic.
- **[Reference (autogen)](reference.md)** — docstrings rendered straight
  from source; the `jldoctest` fences here are executed by `make.jl`.
- **[Architecture](architecture.md)** — pipeline internals: extract →
  lower → bennett → simulate.

## Building these docs locally

```
cd docs
julia --project -e 'using Pkg; Pkg.develop(path=".."); Pkg.instantiate()'
julia --project make.jl
```

Per [CLAUDE.md §14](https://github.com/tobiasosborne/Bennett.jl/blob/main/CLAUDE.md)
there is no GitHub Actions CI; doctests run via the local `make.jl`
invocation above. A doctest drift surfaces as a build failure with the
expected/actual diff inline.

## Repository

Source: <https://github.com/tobiasosborne/Bennett.jl>.
