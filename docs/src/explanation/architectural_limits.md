# Architectural Limits: Why the Circuit Is Fixed

*Why Bennett.jl rejects unbounded loops and runtime-sized memory — and why that
is a property of the target, not a gap in the compiler. For readers who have
compiled a few functions and want to understand where the walls are.*

A reversible circuit is a **fixed object**. Bennett's 1973 construction
([IBM J. Res. Dev. 17(6), DOI 10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525))
takes a function `f` and emits a sequence of NOT, CNOT, and Toffoli gates that
maps `(x, 0…) → (x, f(x))` with every ancilla returned to zero. That gate
sequence is laid down once, at compile time. It has no program counter, no
dynamic dispatch, and no data-dependent control flow at run time. The *same*
gates fire in the *same* order for every input; only the bit values flowing
through the wires differ.

```julia
julia> using Bennett

julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> gate_count(c)
(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
```

Those 58 gates are *all* the computation there will ever be. There is no way for
the circuit to "run the adder again" or "skip the multiply" depending on what
`x` turns out to be — a circuit is combinational once you fix its wiring.

This is the lens for everything below. The two headline restrictions —
**loops must be statically bounded** and **memory must be statically sized** —
are not missing features waiting to be implemented. They are the direct
consequence of compiling to a fixed circuit. Anything whose *size* depends on a
run-time value cannot fit into an object whose size was frozen at compile time.
The compiler's job is therefore to detect those cases and **fail loud** rather
than emit a circuit that is silently wrong for some inputs.

The escape hatch is not to weaken the circuit compiler. It is to change targets:
`target=:reversible_vm` compiles to a reversible *interpreter* — a machine with a
program counter and a history tape — which lifts both limits at the cost of
interpretation overhead. We get there at the end (see *Lifting both limits*,
below).

## Loops must be statically bounded

LLVM represents a loop as a **back-edge** in the control-flow graph: a branch
that jumps from a latch block back to a header block it already dominates.
`find_back_edges` (`src/lowering/cfg.jl`) detects these with a DFS three-colouring,
and `lower` (`src/lowering/driver.jl`) refuses to proceed if a back-edge exists
and no iteration bound was given:

```julia
julia> function shift_reduce(x::UInt8)   # popcount by shifting; trip count ≤ 8
           c = UInt8(0)
           while x != UInt8(0)
               c += x & UInt8(1)
               x >>= 1
           end
           return c
       end;

julia> reversible_compile(shift_reduce, UInt8)
ERROR: ArgumentError: lower: loop detected in LLVM IR but max_loop_iterations
not specified. Pass max_loop_iterations=N to reversible_compile.
```

(LLVM's scalar-evolution pass closed-forms many simple counting loops — `sum(1:n)`
becomes a single multiply with no back-edge at all. `shift_reduce` survives
because its trip count is genuinely data-dependent on the bit pattern of `x`.)

To compile the loop you must tell the compiler how many times to unroll it:

```julia
julia> c = reversible_compile(shift_reduce, UInt8; max_loop_iterations=8);

julia> verify_reversibility(c)
true

julia> simulate(c, UInt8(0b10110100))   # four set bits
4

julia> gate_count(c)
(total = 2021, NOT = 330, CNOT = 1263, Toffoli = 428)
```

### Unroll + MUX-freeze + convergence guard

`lower_loop!` (`src/lowering/cfg.jl`) implements the bound in three parts.

1. **Unroll `K` times.** The loop body is lowered `K` times back-to-back, where
   `K = max_loop_iterations`. Each copy is a straight-line block of gates — this
   is what turns a cyclic CFG into the acyclic gate list a circuit requires. The
   gate count therefore grows roughly linearly in `K`; the `K=8` circuit above is
   ~2000 gates, an order of magnitude larger than the single-add baseline.

2. **MUX-freeze the loop-carried values.** Real loops stop early. To model "this
   input only needed 3 of the 8 unrolled iterations", every loop-carried value
   (the `phi` nodes at the header) is gated through a MUX at the end of each
   unrolled iteration: if the exit condition is already true, the MUX *keeps* the
   current frozen value; otherwise it *takes* the next iteration's latch value.
   Iterations past the real exit run, but their results are masked out — the
   frozen value flows through unchanged. This is what makes one fixed circuit
   correct for every input whose true trip count is `≤ K`.

3. **Guard convergence.** After the `K`-th MUX, `lower_loop!` runs one extra
   *check-only* evaluation of the header's exit condition on the post-`K` frozen
   state and CNOTs the result into a fresh `conv_w` wire, recording a
   `LoopGuard(conv_w, header, K)`. (Subtlety, documented in `cfg.jl` under
   Bennett-s0tn: the convergence bit is *not* iteration `K`'s exit condition — a
   countdown that reaches zero at exactly iteration `K` has a "not done" start
   condition on its final iteration. Convergence must be checked on the state
   *after* `K` iterations.) At run time, `simulate` reads that guard wire and
   **errors loud** if the input needed more than `K` iterations:

```julia
julia> c3 = reversible_compile(shift_reduce, UInt8; max_loop_iterations=3);

julia> simulate(c3, UInt8(0b00000100))   # high bit at position 2 → 3 iterations
1

julia> simulate(c3, UInt8(0b10000000))   # high bit at position 7 → needs 8
ERROR: simulate: data-dependent loop with header block :L7 did not converge
within max_loop_iterations=3 for this input ((0x80,)). The compiled circuit
unrolls the loop to exactly 3 iterations; this input needs more. Recompile
with a larger max_loop_iterations (e.g. max_loop_iterations=6).
```

`verify_reversibility` (`src/diagnostics.jl`) raises the same error when a random
probe overshoots the bound. This is the design choice that matters: an
under-bounded loop never returns a *wrong* answer quietly. It refuses. There is a
deep honesty here — for a genuinely unbounded loop (Collatz total stopping time,
say), *no* finite `K` is correct across the whole input domain, and the guard
will keep firing. That is the correct behaviour, not a bug to be tuned away. If
your loop has no static trip-count bound, the circuit target is the wrong tool;
see the VM target below.

### Nested loops are rejected

A loop body that contains another loop header is rejected outright.
`_collect_loop_body_blocks` (`src/lowering/cfg.jl`) walks the body region and
errors the moment it reaches a nested header:

> `lower_loop!: nested loop header … inside body of … — nested loops not supported (Bennett-httg / U05 scope)`

The single-loop unroller has one frozen loop-carried state and one convergence
guard; a nested loop would need a guard per level and a product of unroll
factors, which the current lowering does not model. Depending on the exact CFG
LLVM produces (loop rotation, preheaders, undef-initialised carries), a nested
loop may instead trip a neighbouring fail-loud assertion in `lower_loop!` or an
`undef`-operand rejection during extraction — but it always fails loud, never
miscompiles. Restructuring the inner loop into a registered helper function
(which is inlined with its own bounded unroll) is the supported workaround.

## Memory must be statically sized

The same principle governs mutable memory. Bennett.jl lowers stack allocations
(`alloca`), stores, and loads into reversible store/load circuits — but the
*shape* of every region, `(elem_width, n_elems)`, must be a compile-time
constant. `_pick_alloca_strategy` (`src/lowering/memory.jl`) dispatches on that
constant shape:

| Access pattern | Strategy | Cost |
| --- | --- | --- |
| constant index, any shape | `:shadow` | 3·W CNOT per store, W CNOT per load, 0 Toffoli |
| runtime index, `N·W ≤ 64` | `:mux_exch_NxW` | packed single-word MUX exchange |
| runtime index, `N·W > 64` | `:shadow_checkpoint` | O(N·W) per op, universal fallback |

A constant lookup table compiles to a QROM (Babbush–Gidney 2018) via
`lower_var_gep!` on the constant global — `2·(L−1)` Toffoli for an `L`-entry
table, a T-count of `4·(L−1)`, *independent of the element width*:

```julia
julia> sbox(x::UInt8) = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))[(x & UInt8(0x3)) + 1];

julia> gate_count(reversible_compile(sbox, UInt8))
(total = 114, NOT = 10, CNOT = 96, Toffoli = 8)
```

What is rejected is anything whose *size* is a run-time value. A `Dict`, a
`Vector` of run-time length, or a variable-size `memcpy` cannot be given a wire
count at compile time, so there is no circuit to emit. These fail loud at
extraction (`src/extract/instructions.jl`, e.g. *"memcpy with non-constant byte
count is not supported. Variable-size memcpy requires runtime-bounded loop
unrolling."*) or, for a stack allocation whose element count is itself an SSA
value, at lowering. `_pick_alloca_strategy_dynamic_n` (`src/lowering/memory.jl`)
refuses to guess:

> `dynamic n_elems alloca encountered under mem=:auto; the persistent_tree arm is the only correct lowering for dynamic n. Re-run reversible_compile(f, ...; mem=:persistent) to enable it.`

The `mem=:persistent` opt-in routes dynamic-`n` allocations to a persistent-map
data structure (the T5 workstream; only `persistent_impl=:linear_scan` is wired
today). It widens what compiles, but it does not change the underlying truth: a
fixed circuit can only address a fixed number of cells. Reaching for genuinely
unbounded, run-time-addressed memory means leaving the circuit target.

## Lifting both limits: `target=:reversible_vm`

Both walls — the bounded loop and the statically-sized heap — come from one
source: a circuit has no notion of *time*. Every gate exists simultaneously; the
object cannot grow while it runs.

A **reversible virtual machine** removes that constraint by adding exactly the
machinery a circuit lacks. Instead of compiling `f` into gates, you compile it
into a program for a small reversible interpreter that has:

- a **program counter**, so the same instructions can be re-executed — a true
  run-time loop, with no compile-time unroll bound; and
- a **history tape**, the reversible-computing analogue of a stack of pebbles,
  which records enough information at each step to run the computation backwards
  and keep every ancilla clean. This is Bennett's 1989 time/space trade-off
  ([SIAM J. Comput., DOI 10.1137/0218053](https://doi.org/10.1137/0218053)): you
  spend tape (space) to buy unbounded, reversible time.

With a program counter, a loop runs as long as its data says to — no
`max_loop_iterations`. With a writable, run-time-addressed tape, memory is sized
at run time — no static-shape requirement. The price is interpretation overhead:
the VM is a general machine, where the circuit was a bespoke one.

The target is shipped. `reversible_compile` exposes it through the same `target=`
kwarg; the default is `target=:gate_count` (or `:depth`), and `:reversible_vm` is
the third value. Bennett.jl does **not** depend on the VM backend — that would be
a dependency cycle — so the backend registers itself when you load it:

```julia
julia> reversible_compile(x -> x + Int8(1), Int8; target=:reversible_vm)
ERROR: reversible_compile(target=:reversible_vm) requires the BennettVM backend
to be loaded: `using BennettVM` registers it. (Bennett.jl does not depend on
BennettVM — the VM backend plugs in.)
```

After `using BennettVM`, the backend writes itself into the
`Bennett._REVERSIBLE_VM_BACKEND` hook (`src/Bennett.jl`) and a `:reversible_vm`
compile returns a `BennettVM.VMProgram` instead of a `ReversibleCircuit`. The
backend lives in the sibling repository **`BennettVM.jl`** (on disk at
`../BennettVM.jl`); an end-to-end Collatz example round-trips through it today.
Note that there is no `target=:circuit` — the circuit *is* the default, and an
unknown target fails loud:

```julia
julia> reversible_compile(x -> x + Int8(1), Int8; target=:circuit)
ERROR: ArgumentError: lower: unknown target :circuit; supported: :gate_count, :depth
```

## In one sentence

The circuit target trades generality for a gate-exact, ancilla-clean object, and
that trade *requires* static loop bounds and static memory sizes; when your
problem genuinely needs run-time iteration or run-time memory, that is the signal
to compile to the reversible VM, not to fight the circuit compiler.

## See also

- [`docs/src/api.md`](../reference/api.md) — the `reversible_compile` kwargs, including
  `max_loop_iterations`, `mem`, and `target`.
- [`docs/src/architecture.md`](../explanation/architecture.md) — the
  extract → lower → bennett → simulate pipeline these limits live in.
- [`README.md`](../../../README.md) — project overview and the VM-target roadmap.
- `BennettVM.jl` (sibling repository) — the reversible-interpreter backend for
  `target=:reversible_vm`.
