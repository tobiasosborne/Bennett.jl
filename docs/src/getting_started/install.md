# Installation

*How to add Bennett.jl, confirm it works, optionally wire up the reversible-VM
backend, build the docs, and run the test suite. Practical and short.*

## Requirements

- **Julia 1.10 or newer.** The compat bound in `Project.toml` is `julia = "1.10"`;
  day-to-day development and the verified numbers in these docs are on Julia 1.12.
- **[LLVM.jl](https://github.com/maleadt/LLVM.jl)** (compat `LLVM = "9, 10"`), pulled
  in automatically as a dependency. Bennett.jl extracts LLVM IR from your Julia
  function through LLVM.jl's C API — it is the backend, not an optional extra.

There is nothing else to install: the soft-float library, the adders/multipliers,
and Bennett's construction are all pure Julia inside the package.

## Install

Bennett.jl is not registered; install it from the GitHub URL:

```julia
using Pkg
Pkg.add(url = "https://github.com/tobiasosborne/Bennett.jl")
```

## Verify your install

Compile a one-line increment, run it, and check the invariant:

```julia
using Bennett

c = reversible_compile(x -> x + Int8(1), Int8)

simulate(c, Int8(42))        # => 43
gate_count(c)                # => (total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
verify_reversibility(c)      # => true
```

Two things worth noting from this output:

- `gate_count` returns a **NamedTuple** `(total, NOT, CNOT, Toffoli)`, not a bare
  `Int`. The scalar metrics — `ancilla_count`, `t_count`, `toffoli_depth`, `depth` —
  do return `Int`.
- `verify_reversibility(c)` is the real test. It confirms every ancilla returns to
  zero, the input wires are preserved, and forward-then-reverse restores the initial
  state, on random inputs (`n_tests = 100` by default). "Runs without error" is not a
  passing check; this is.

If all three lines produce the values above, your install is good. From here, the
[quick start](quickstart.md) walks through the API and the
[first-circuit tutorial](../tutorials/first_circuit.md) builds one end to end.

## Optional: the reversible-VM backend (`target = :reversible_vm`)

The default circuit backend produces a fixed circuit, so loop bounds and memory sizes
must be known at compile time. The sibling project **BennettVM.jl** lifts that
restriction with a second lowering target: `reversible_compile(f, T; target = :reversible_vm)`
returns a `BennettVM.VMProgram` (a reversible interpreter carrying a history tape)
instead of a `ReversibleCircuit`.

Bennett.jl ships the dispatch arm and a registration hook
(`_REVERSIBLE_VM_BACKEND`, see `src/Bennett.jl`), but does **not** depend on
BennettVM.jl — that would be a dependency cycle. Until the backend registers itself,
`target = :reversible_vm` errors with a message telling you to load BennettVM. To
enable it, add the sibling checkout and `using` it:

```julia
using Pkg
Pkg.develop(path = "../BennettVM.jl")   # sibling repo

using Bennett
using BennettVM                         # __init__ registers lower_vm into Bennett

# collatz here is your own Julia function; the call returns a VMProgram, not a circuit
prog = reversible_compile(collatz, Int64; target = :reversible_vm)  # ::BennettVM.VMProgram
```

Loading `BennettVM` is what populates the backend hook; without it the
`:reversible_vm` arm stays inert. This is an opt-in path — the circuit backend needs
nothing beyond Bennett.jl itself.

## Building the docs

The documentation is plain Markdown you can read on GitHub, and also builds into an
HTML site with [Documenter.jl](https://documenter.juliadocs.org). The build lives in
its own environment under `docs/`:

```bash
# one-time setup: make the in-tree Bennett package available to the docs env
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'

# build
julia --project=docs docs/make.jl
```

`docs/make.jl` runs with `doctest = true`, so every ```jldoctest fence is executed
during the build and a drifted output fails the build with a diff — the same
regression surface a CI doctest job would give, run locally. Output HTML is written
under `docs/build/`.

## Running the tests

```bash
julia --project -e 'using Pkg; Pkg.test()'     # full suite
julia --project test/test_increment.jl         # a single file
```

The suite is large: **297** `test_*.jl` files, roughly **690,000** assertions,
about **28 minutes** cold under `JULIA_NUM_THREADS=32`. Every test calls
`verify_reversibility` or checks ancilla values explicitly (per the project's
exhaustive-verification rule), so a green run means the reversibility invariant
holds, not merely that nothing threw.

One subtlety when running a single file: `Pkg.test()` passes
`--check-bounds=yes`, which forces every `@boundscheck` on. A per-file "green" claim
is only comparable to the suite if you match that flag:

```bash
julia --project --check-bounds=yes test/test_increment.jl
```

### The four `BENNETT_*` environment gates

The suite has tiers you can switch on or off without editing code:

| Variable                  | Default | Effect when set off-default                                                                 |
| ------------------------- | ------- | ------------------------------------------------------------------------------------------- |
| `BENNETT_HEAVY_TESTS`     | `1` (on)  | `=0` skips the 17 transcendental LLVM-dispatch files — the bulk of wall-time.              |
| `BENNETT_T5_TESTS`        | `1` (on)  | `=0` skips the multi-language T5 corpus (Julia / C / Rust; C and Rust self-skip if `clang`/`rustc` are absent). |
| `BENNETT_RESEARCH_TESTS`  | `0` (off) | `=1` adds the relocated research persistent-DS impls (Okasaki RBT, HAMT, Conchon-Filliâtre, Jenkins). |
| `BENNETT_CI`              | off       | `=1` promotes missing-toolchain self-skips into hard errors. Despite the name there is **no** GitHub CI. |

For example, to iterate quickly while skipping the slow transcendental tier:

```bash
BENNETT_HEAVY_TESTS=0 julia --project -e 'using Pkg; Pkg.test()'
```

## No GitHub CI — local gates only

By explicit project policy there is no GitHub Actions, no scheduled runs, and no
remote automation. Quality is enforced **locally** by three mechanisms:

- **`Pkg.test()`** — the full suite above, run before committing.
- **The `scripts/pre-push` git hook** — runs the test suite before every `git push`.
  Install it once with `scripts/install-hooks.sh`; use `SKIP_PUSH_TESTS=1 git push`
  for an explicit docs-only or WIP escape hatch.
- **`bd` (beads)** issue tracking — for task state, in place of CI dashboards.

If you are looking for a CI badge or a workflow file, there isn't one, and that is
intentional. See the [README](../../../README.md) for the rationale and the rest of
the project layout.
