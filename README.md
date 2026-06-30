# Bennett.jl

[![License](https://img.shields.io/badge/License-AGPL_3.0-7aa2f7.svg?style=flat-square)](LICENSE)
[![Julia](https://img.shields.io/badge/Julia-1.10%2B-9558B2.svg?style=flat-square)](https://julialang.org/)
[![Backend](https://img.shields.io/badge/backend-LLVM.jl-f24f4f.svg?style=flat-square)](https://github.com/maleadt/LLVM.jl)
[![Gates](https://img.shields.io/badge/gates-NOT_·_CNOT_·_Toffoli-2ea043.svg?style=flat-square)](#what-this-does)

**Compile any pure Julia function into a classical reversible circuit — NOT, CNOT,
Toffoli — with every ancilla provably returned to zero, correct by construction.**

A classical computation throws information away. `x ↦ x & 1` forgets which `x` you
started with, and that forgetting is exactly what makes it irreversible — and, by
Landauer's principle, what dissipates heat. [Bennett's 1973
construction](https://doi.org/10.1147/rd.176.0525) buys the information back: run the
computation, **copy out** the answer, then run the computation **backwards** to erase
every intermediate, leaving every scratch wire clean. Bennett.jl does this
automatically, at the **LLVM IR level**, for plain Julia functions on plain integers
(and `Float64` via branchless soft-float) — no special types, no operator overloading,
no annotations. Plain Julia in, reversible circuit out.

```julia
using Bennett

# Any pure Julia function — no special types, no annotations.
f(x::Int8) = x*x + Int8(3)*x + Int8(1)

c = reversible_compile(f, Int8)     # extract LLVM IR → lower to gates → Bennett-ize
simulate(c, Int8(5))                # => 41          (= 25 + 15 + 1)
verify_reversibility(c)             # => true        (ancillae 0, input preserved, run reverses)
gate_count(c)                       # => (total = 482, NOT = 14, CNOT = 300, Toffoli = 168)
```

![The Bennett.jl pipeline: extract → lower → bennett](docs/src/assets/pipeline.svg)

The compiler extracts LLVM IR from a Julia function via [LLVM.jl](https://github.com/maleadt/LLVM.jl)'s
C API, walks the IR as typed objects, lowers each instruction to reversible gates, and
applies Bennett's construction. No tracing, no operator overloading — the same IR a C or
Rust frontend emits goes through the same pipeline.

## Why this exists

The long game is **quantum control**. A quantum computer can run a classical function
*conditioned on a qubit* — `when(qubit) do f(x) end` — but only if `f` is expressed as a
reversible circuit of Toffoli gates. Bennett.jl is the classical-oracle core of that
toolchain (the motivation for integration with
[Sturm.jl](https://github.com/tobiasosborne/Sturm.jl)). Along the way it is useful
wherever a classical function must become a reversible permutation:

- **Quantum oracles** — Grover, phase estimation, QSVT, and amplitude amplification all
  need a reversible implementation of a classical predicate or arithmetic kernel.
- **Reversible / adiabatic hardware** — direct synthesis to Toffoli networks for
  energy-recovering CMOS.
- **A reversible-computation laboratory** — space–time trade-offs (pebbling, eager
  uncomputation, checkpointing), carry-lookahead arithmetic, and QROM table lookup, all
  measured against the published literature in [`BENCHMARKS.md`](BENCHMARKS.md).

## Two backends, one front door

A reversible **circuit** is a *fixed permutation* — the right artifact for a quantum
oracle, but it has no program counter and no runtime-sized memory, so every loop must be
statically bounded and every array statically sized. For computations whose length the
*input* decides — a data-dependent `while`, a Collatz orbit — Bennett.jl has a second
lowering target: **[BennettVM](../BennettVM.jl)**, a reversible abstract machine that
*interprets* the lowered program forward and backward. Both targets share the same
LLVM-IR frontend and are selected by one keyword:

```julia
reversible_compile(f, Int64)                       # → ReversibleCircuit  (target = :gate_count, default)
reversible_compile(f, Int64; target = :depth)      # → ReversibleCircuit  (optimised for Toffoli-depth)

using BennettVM                                     # registers the VM backend (target=:reversible_vm fork)
reversible_compile(collatz_steps, Int64; target = :reversible_vm)   # → BennettVM.VMProgram
```

| | `target = :gate_count` / `:depth` (default) | `target = :reversible_vm` |
|---|---|---|
| **Artifact** | `ReversibleCircuit` (fixed Toffoli network) | `BennettVM.VMProgram` (reversible bytecode) |
| **Loops** | statically bounded (explicit unroll) | data-dependent, run to completion |
| **Memory** | statically sized | runtime-sized |
| **Use** | quantum oracle / hardware synthesis | terminating classical programs of unknown length |
| **Reversibility** | Bennett forward+copy+reverse | history tape (injectivity / min-cut delta / checkpoint) |

`target = :reversible_vm` is **shipped** — end-to-end Collatz round-trips through the VM
today (BennettVM milestone M13). It is opt-in: until `using BennettVM` registers the
backend, a `:reversible_vm` compile raises a clear "requires `using BennettVM`" error
rather than silently producing a circuit. See [BennettVM.jl](../BennettVM.jl) for the
machine itself.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/tobiasosborne/Bennett.jl")
```

Requires Julia 1.10+ and LLVM.jl (tested on Julia 1.12). For the reversible-VM target,
also `Pkg.add` the sibling [BennettVM.jl](../BennettVM.jl).

## What this does

Given any pure, deterministic `f`, Bennett.jl produces a reversible circuit
`(x, 0…) ↦ (x, f(x))` over only NOT, CNOT, and Toffoli gates, with **all ancillae
verified zero** after execution. The circuit is correct by construction, and
`verify_reversibility` checks the invariant — ancilla-clean, input-preserved, and
forward-then-reverse restores the initial state — on random inputs, not just "runs
without error".

```julia
c = reversible_compile(x -> x + Int8(1), Int8)

simulate(c, Int8(42))      # => 43
gate_count(c)              # => (total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
ancilla_count(c)           # => 25
t_count(c)                 # => 84     (= 12 Toffoli × 7 T each)
toffoli_depth(c)           # => 12
verify_reversibility(c)    # => true

# Lift to a quantum-controlled operation: fire only when the control bit is set.
cc = controlled(c)
simulate(cc, true,  Int8(42))   # => 43   (control on  → compute f)
simulate(cc, false, Int8(42))   # => 0    (control off → output register stays 0)
```

> **Reading the metrics.** `gate_count` returns a `NamedTuple`
> `(total, NOT, CNOT, Toffoli)`; the other metrics return plain `Int`s. `t_count` is
> `7 × Toffoli` (each Toffoli decomposes to 7 T gates); `toffoli_depth` is the longest
> chain of Toffolis on a data-dependence path (the FTQC-relevant depth). A controlled
> circuit's *off* branch returns the **all-zero** output value, not the input — the
> output register is simply never written.

## Features

### LLVM instruction coverage

Bennett.jl lowers essentially everything a pure, deterministic Julia (or C / Rust)
function produces after `optimize=false` codegen:

| Category | Coverage |
|----------|----------|
| **Integer arithmetic** | `add` `sub` `mul` `udiv` `sdiv` `urem` `srem` `shl` `lshr` `ashr` `and` `or` `xor` (13/13) |
| **Float arithmetic** | `fadd` `fsub` `fmul` `fdiv` (branchless soft-float), `fneg` (sign-bit XOR) |
| **Comparison** | `icmp` (all 10 predicates), `fcmp` (all 14 predicates) |
| **Conversion** | `sext` `zext` `trunc` `bitcast`; `fptosi` `fptoui` `sitofp` `uitofp` `fpext` `fptrunc` (soft-float) |
| **Control flow** | `phi` `select` `freeze` `br` `switch` (cascaded), `unreachable`; statically-bounded loops |
| **Aggregates** | `insertvalue` `extractvalue` (sret tuple returns) |
| **Vectors** | `insertelement` `shufflevector` `extractelement` (constant lane, scalarised) |
| **Memory** | `alloca` `load` `store` `getelementptr` |
| **Intrinsics** | ~35 `llvm.*`: `umax/umin/smax/smin` `abs` `ctpop` `ctlz` `cttz` `bitreverse` `bswap` `fshl/fshr`, rounding, min/max, and the **transcendentals** `sqrt` `exp/exp2` `log/log2/log10` `pow` `sin/cos/tan` `asin/acos/atan` `sinh/cosh/tanh` … → soft-float |
| **Calls** | `call` to registered callees (gate-level inlining) |

**Out of scope** (filed, not on the critical path): exception handling
(`invoke`, `landingpad`, `catchpad`), `va_arg`, `frem`, `addrspacecast`. Pointer casts
(`ptrtoint`/`inttoptr`), `fence`, and atomics are rejected fail-loud on the default
circuit path but **supported** under the closed-world `ptr_cells` mode that feeds the
reversible-VM backend.

### Arithmetic strategy dispatchers

`reversible_compile(f, T; add=…, mul=…, target=…)` selects the lowering per operation:

| Operation | Strategy | Cost | Paper |
|-----------|----------|------|-------|
| `add=:ripple` *(auto default)* | out-of-place ripple-carry | `2(W-1)` Toffoli, O(W) depth | — |
| `add=:cuccaro` | in-place, 1 ancilla | `2W-3` Toffoli, `4W-2` CNOT | Cuccaro 2004 |
| `add=:qcla` | carry-lookahead | O(log W) **Toffoli-depth** | Draper–Kutin–Rains–Svore 2004 |
| `mul=:shift_add` *(auto default)* | schoolbook | O(W²) Toffoli | — |
| `mul=:qcla_tree` | QCLA adder tree | O(log²W) **Toffoli-depth** | Sun–Borissov 2026 |

`add=:auto` always lowers to ripple (its tight Toffoli count is the regression baseline);
`mul=:auto` is `:shift_add` at `target=:gate_count` and `:qcla_tree` at `target=:depth`.
Head-to-head on `(x,y) -> x*y` at `Int32`: `:qcla_tree` reaches **Toffoli-depth 56**
versus schoolbook's **180** (≈ 3× shallower), trading more Toffolis for depth — the right
call under fault-tolerant cost models.

```julia
c_qcla = reversible_compile((x, y) -> x*y, Int32, Int32; mul = :qcla_tree)
toffoli_depth(c_qcla)                                          # => 56   (Sun–Borissov 2026)
toffoli_depth(reversible_compile((x, y) -> x*y, Int32, Int32)) # => 180  (schoolbook)
```

> The recursive Karatsuba multiplier was **retired** (2026-04-27): its `Θ(W^1.58)`
> Toffoli savings were swamped by `Θ(W^2.32)` ancilla growth at every `W ≤ 64`, so it
> lost to schoolbook everywhere it could actually be lowered.

### Reversible memory

Mutable state (`Ref`, arrays, dynamic indexing) is reversibilised per access site. Five
strategies, reached by **different dispatch paths**, not one switch:

| Strategy | When | Cost | Paper |
|----------|------|------|-------|
| **Shadow** | static index, any shape (`_pick_alloca_strategy`) | `3W` CNOT / store · `W` CNOT / load, 0 Toffoli | Enzyme-adapted (Moses–Churavy 2020) |
| **MUX-EXCH** | dynamic index, `N·W ≤ 64` packed shape | branchless `ifelse` over slots | — |
| **Shadow-checkpoint** | dynamic index, `N·W > 64` (universal fallback) | O(N·W) per op | — |
| **QROM** | read of a compile-time-constant global table (GEP path) | `2(L-1)` Toffoli + O(L·W) CNOT — **T-count `4(L-1)`, W-independent** | Babbush–Gidney 2018 |
| **Persistent-DS** | runtime-unbounded map, opt-in `mem=:persistent` | ~414 gates/set (linear-scan, flat in N) | — |

```julia
# A constant lookup table compiles to a Babbush–Gidney QROM, not a giant MUX tree.
sbox(x::UInt8) = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))[(x & 0x3) + 1]
gate_count(reversible_compile(sbox, UInt8))   # => (total = 114, NOT = 10, CNOT = 96, Toffoli = 8)
```

A reversible Feistel permutation (`emit_feistel!`, ~`4W` Toffoli, Luby–Rackoff 1988) is
provided as a bijective-hash building block; it is not auto-dispatched.

### The persistent-DS finding (counterintuitive)

For runtime-unbounded mutable memory (`mem=:persistent`), Bennett.jl ships four backing
maps — `:linear_scan` (default), `:okasaki`, `:hamt`, `:cf` — and **the trivial linear
scan wins every measured cell.** Its per-set cost is *constant in the map size* (~414
gates/set, even at `max_n = 1000` → 414 028 gates total), while a Conchon–Filliâtre
semi-persistent array is O(N) per set (O(N²) total).

**Why this contradicts CPU intuition:** the branchless "preserve N−1 slots, write 1"
pattern decomposes into `ifelse(false, _, x) = x` for the untouched slots, which
Bennett.jl lowers to **zero gates** (pure wire-routing). The CPU-cheap primitives the
"clever" structures rely on are gate-*expensive*: a `popcount` is one hardware
instruction but ~256 Toffoli reversibly; pointer dereference becomes an N-wide MUX; tree
rebalancing must compute all branches speculatively. The right reversible data structure
is the one whose per-op shape matches what Bennett already compresses. Full methodology in
[`docs/memory/persistent_ds_scaling.md`](docs/memory/persistent_ds_scaling.md).

### Wider types, Float64, and composability

- **Integers** `Int8/16/32/64`, `UInt8/16/32/64`, and **`Bool`** — gate count scales
  ~2× per width doubling (`total(2W) = 2·total(W) − 2`).
- **Float64** — full IEEE 754 in pure integer gates (`module SoftFloatLib`, 60 exported
  `soft_*` primitives). **Bit-exact** with hardware on `+ − × ÷ √ fma`, all comparisons,
  all conversions, rounding, and min/max (verified over ~1.2M random raw-bit pairs across
  subnormal, NaN, Inf, signed-zero, and overflow regions). The **transcendentals**
  (`exp log sin cos pow …`, faithful musl / FreeBSD ports) target **≤ 2 ulp** vs Base —
  accurate, not bit-exact.
- **Float32** is **not** a supported argument type: there are no native f32 primitives, so
  mixed-precision f32 arithmetic is routed `soft_fpext → f64 → soft_fptrunc`, which
  double-rounds. `reversible_compile(f, Float32)` is rejected.
- **Tuple returns** (`(a, e) = round(a, …, w)`), **NTuple inputs**, **`Ref`** mutable
  scalars, **mutable arrays**, **controlled circuits** (`controlled`), **circuit
  composition** (`compose`), and **gate-level function inlining** (`register_callee!`).
- **Multi-language ingest** — `extract_parsed_ir_from_ll(path)` /
  `extract_parsed_ir_from_bc(path)` accept `.ll` / `.bc` from any LLVM frontend (C via
  `clang -emit-llvm`, Rust via `rustc --emit=llvm-ir`); the pipeline is language-agnostic
  at the IR level.

### Space–time trade-offs

`bennett(lr; strategy = …)` schedules uncomputation differently for the same lowered
program — six pluggable strategies behind one abstract `BennettStrategy`:

| Strategy | Idea | Paper |
|----------|------|-------|
| `DefaultStrategy` | forward + copy + reverse | Bennett 1973 |
| `EagerStrategy` | gate-level dead-end cleanup | PRS15 |
| `ValueEagerStrategy` | value-level EAGER + reverse-topological uncompute | PRS15 Algorithm 2 |
| `CheckpointStrategy` | periodic snapshots, replay between them | — |
| `PebbledStrategy(k)` | bounded-pebble space–time game | Knill 1995 |
| `PebbledGroupStrategy(k)` | group-level pebbling with wire reuse | Knill 1995 + PRS15 |

**Self-reversing primitives** (QROM tabulate, the Sun–Borissov multiplier) already end
with clean ancillae on the output wires; constructed with `self_reversing=true` they skip
the forward+copy+reverse wrap entirely (validated by the U03 probe battery so a forged
claim is rejected). This is how a downstream backend cuts peak qubits — e.g. 28 → ~22 on
Sturm.jl's N=15 Shor `mulmod`.

## Benchmark headlines

From [`BENCHMARKS.md`](BENCHMARKS.md) (every circuit verified reversible):

| Benchmark | Bennett.jl | Baseline | |
|-----------|-----------:|---------:|---|
| QROM lookup, L=8, W=8 | 14 Toffoli | MUX tree O(L·W²) | **W-independent** |
| Shadow store, W=8 | 24 CNOT, 0 Toffoli | MUX-EXCH 7 122 gates | **≈300× smaller** |
| Persistent set (linear-scan, W=8) | ~414 gates | CF semi-persistent O(N²) | **flat in N** |
| SHA-256 round | 1 632 Toffoli | PRS15 hand-opt 683 | 2.4× |

QROM's T-count is exactly `4(L-1)` and independent of `W` (the Babbush–Gidney bound; the
raw Toffoli count is `2(L-1)`). Shadow memory is exactly `3W` / `W` CNOT with zero
Toffolis from the mechanism itself.

## Architecture

```
 Julia / C / Rust         LLVM IR              Parsed IR            Reversible artifact
 ───────────────       ───────────         ──────────────       ────────────────────
  f(x::Int8)   ──►   code_llvm()  ──►  extract_parsed_ir() ──►  lower()  ──►  bennett()
                     (LLVM.jl C API)          │                    │             │
                                              │              strategy            ▼
                                         preprocess           dispatch      ReversibleCircuit
                                         sroa / mem2reg     ┌──────────┐         │
                                         simplifycfg        │ shadow   │         ├──► simulate()
                                         instcombine        │ mux-exch │         ├──► verify_reversibility()
                                                            │ qrom     │         ├──► gate_count / toffoli_depth
                                      (target=:reversible_vm)│ persist. │         └──► controlled()
                                              │             └──────────┘
                                              ▼
                                       BennettVM.lower_vm  ──►  VMProgram  (reversible interpreter)
```

1. **Extract** — `extract_parsed_ir(f, arg_types)` walks LLVM IR as typed objects into a
   `ParsedIR`. The walker lives in [`src/extract/`](src/extract/) (instruction dispatch,
   intrinsics, sret, vectors, callees, …); `src/ir_extract.jl` is a thin include shim.
2. **Lower** — `lower(parsed)` maps each instruction to gates, in
   [`src/lowering/`](src/lowering/) (`driver`, `cfg`, `phi`, `arith`, `aggregate`,
   `call`, `memory`); `src/lower.jl` is a thin include shim. Memory ops dispatch to
   shadow / MUX-EXCH / QROM / persistent per site.
3. **Bennett** — `bennett(lr; strategy=…)` makes the program reversible (forward + copy +
   reverse, or forward-only for self-reversing primitives).
4. **Simulate** — `simulate(circuit, input…)` runs a bit-vector simulation and *enforces*
   the Bennett invariants (ancilla-zero, input-preserved, loop-converged) — never a silent
   wrong answer.

Full walkthrough: [`docs/src/explanation/architecture.md`](docs/src/explanation/architecture.md).

## Architectural limits

The circuit target compiles to a **fixed gate sequence** — the same constraint every
quantum oracle has. Two consequences, both fail-loud, never silently wrong:

- **Loops must be statically bounded.** Compile-time trip counts (`for i in 1:4`) are
  resolved by LLVM before Bennett sees them. Data-dependent loops (`while n > 0`, Collatz)
  need `max_loop_iterations = K`; the body is unrolled `K` times with a MUX-frozen
  loop-carried state and a **convergence guard** wire — if an input needs more than `K`
  iterations, `simulate` raises an error naming the bound, it does not return garbage.
  Nested loops are rejected at compile time.
- **Memory must be statically sized.** Every `alloca` / `Vector` / persistent-map has a
  known shape; a `Dict{K,V}` or a runtime-sized `Array(undef, n)` is rejected at
  extraction with a precise signpost.

**Both limits are lifted by `target = :reversible_vm`** (see [BennettVM.jl](../BennettVM.jl)):
a `while` loop simply runs as many times as the input demands, and memory can be
runtime-sized — the reversible interpreter carries a history tape instead of a fixed
circuit.

## Build & test

```bash
julia --project -e 'using Pkg; Pkg.test()'        # full suite (~28 min cold)
julia --project test/test_increment.jl            # a single file
```

The suite runs ~690 000 assertions across **297** test files under
`JULIA_NUM_THREADS=32`. Every test calls `verify_reversibility` or checks ancilla values
explicitly — "runs without error" is not a passing test. Environment gates:
`BENNETT_HEAVY_TESTS=0` skips the 17 transcendental LLVM-dispatch files (the bulk of
wall-time), `BENNETT_T5_TESTS=0` skips the multi-language corpus, `BENNETT_RESEARCH_TESTS=1`
adds the research persistent-DS impls, and `BENNETT_CI=1` promotes missing-toolchain skips
to hard errors. Quality gates run **locally only** — there is no GitHub CI by design.

## Documentation

Full docs are a [Diátaxis](https://diataxis.fr)-structured site under
[`docs/src/`](docs/src/) — plain Markdown you can read on GitHub, or build with
`julia --project=docs docs/make.jl`.

- **Learn** — [install](docs/src/getting_started/install.md) ·
  [quick start](docs/src/getting_started/quickstart.md) ·
  [your first circuit](docs/src/tutorials/first_circuit.md) ·
  [control flow & loops](docs/src/tutorials/control_flow_and_loops.md) ·
  [floats & transcendentals](docs/src/tutorials/floats.md)
- **Do** — [choose an arithmetic strategy](docs/src/howto/arithmetic_strategy.md) ·
  [reversible memory](docs/src/howto/reversible_memory.md) ·
  [compile C / Rust](docs/src/howto/other_languages.md) ·
  [target the reversible VM](docs/src/howto/reversible_vm.md) ·
  [quantum control](docs/src/howto/quantum_control.md)
- **Understand** — [architecture](docs/src/explanation/architecture.md) ·
  [Bennett's construction](docs/src/explanation/bennett_construction.md) ·
  [why branchless soft-float](docs/src/explanation/branchless_softfloat.md) ·
  [architectural limits](docs/src/explanation/architectural_limits.md)
- **Look up** — [API reference](docs/src/reference/api.md) ·
  [strategies](docs/src/reference/strategies.md) ·
  [bibliography](docs/src/reference/bibliography.md)

Also: [`BENCHMARKS.md`](BENCHMARKS.md) (head-to-head tables vs published compilers),
[`WORKLOG.md`](WORKLOG.md) (the development log), and the per-version
[PRDs](docs/prd/).

## Key references

| Tag | Result |
|-----|--------|
| **Bennett 1973** — *Logical Reversibility of Computation* ([10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525)) | the forward + copy + reverse construction |
| **Bennett 1989** — *Time/Space Trade-Offs* ([10.1137/0218053](https://doi.org/10.1137/0218053)) | O(T^{1+ε}) time, O(S·log T) space |
| **Knill 1995** — *Analysis of Bennett's Pebble Game* | exact pebbling recursion |
| **Cuccaro 2004** — *A New Quantum Ripple-Carry Adder* | in-place adder, 1 ancilla |
| **Draper–Kutin–Rains–Svore 2004** — *Logarithmic-Depth Carry-Lookahead* | QCLA: O(log n) Toffoli-depth |
| **Sun–Borissov 2026** — *Polylogarithmic-Depth Quantum Multiplier* | QCLA-tree multiplier: O(log²n) T-depth |
| **Luby–Rackoff 1988** — *How to Construct Pseudorandom Permutations* | 4-round Feistel = bijection |
| **PRS15** — Parent/Roetteler/Svore, *Reversible Circuit Compilation* | EAGER uncomputation |
| **Babbush–Gidney 2018** — *Encoding Electronic Spectra with Linear T* | QROM: 4L−4 T, W-independent |
| **Moses–Churavy 2020** — *Enzyme* | LLVM-level AD — inspiration for shadow memory |

All papers are in [`docs/literature/`](docs/literature/), claims checked against the text.

## Project status

**The memory plan is complete** (2026-05-20): all five memory strategies, the universal
dispatcher, MemorySSA ingest, and full SHA-256 shipped; the T5 persistent-DS epic closed
with `:linear_scan` as the winning default.

**The active frontier (mid-2026) is the reversible-VM path.** Bennett.jl is extracting
the *internals* of Julia's `Dict` (the closed-world `fdict` workstream, under the
`ptr_cells` pointer-cell mode) to feed the [BennettVM.jl](../BennettVM.jl) backend, which
already round-trips end-to-end Collatz via `target = :reversible_vm`. Recent landings
advance that extraction wall-by-wall (ptr-typed `icmp`, param-cell `memcpy`,
sret-convention calls). The `lower.jl` and `ir_extract.jl` monoliths have been split into
`src/lowering/` and `src/extract/`.

**Direction** (per [`Bennett-VISION-PRD.md`](Bennett-VISION-PRD.md) and
[`Bennett-ReversibleVM-PRD.md`](Bennett-ReversibleVM-PRD.md)): Sturm.jl quantum control,
and Bennett.jl + BennettVM as the classical-oracle core of a taint-driven quantum
compiler.

## Contributing

Bennett.jl uses [`bd` (beads)](https://github.com/ksdgg/beads) for issue tracking (issues
live in the project's Dolt store, not GitHub Issues). Start with `CLAUDE.md` — the
non-negotiable development protocols (fail-loud assertions, red-green TDD, exhaustive
`verify_reversibility`, gate-count regression baselines).

```bash
bd ready                       # issues ready to work, no blockers
bd show Bennett-<id>           # full description + linked sites
bd update Bennett-<id> --claim # mark in-progress
```

Changes to the core pipeline (`src/extract/`, `src/lowering/`, `src/bennett_transform.jl`,
`src/gates.jl`, `src/ir_types.jl`, or the phi-resolution algorithm) follow the **3+1
agent protocol**: two independent design proposers, one implementer, one reviewer — the
discipline that keeps the phi-resolution / false-path-sensitization bug class out of the
compiler. Quality gates are **local** (`Pkg.test()`, the `scripts/pre-push` hook, and
`benchmark/regression_check.jl`); the project deliberately has **no GitHub CI**.

## Citation

```bibtex
@software{Bennett.jl,
  title  = {Bennett.jl: Compiling Julia to Reversible Circuits},
  author = {Tobias Osborne},
  url    = {https://github.com/tobiasosborne/Bennett.jl},
  year   = {2025--2026}
}
```

## License

[AGPL-3.0](LICENSE)
