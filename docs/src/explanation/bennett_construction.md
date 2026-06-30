# Bennett's 1973 construction

*Why a one-way computation can be run backwards without keeping a journal of every
intermediate value — the idea the whole compiler is named after, and how Bennett.jl
implements it.*

This page is the *why*. If you want to compile a function and read off its gate
count, start with the [tutorial](../tutorials/first_circuit.md); if you want the
exact signatures, see the [API reference](../reference/api.md). Here we explain the
single theorem that makes everything else possible, the wire bookkeeping that keeps
it honest, and — equally important — the parts of the literature this codebase does
*not* implement.

## The problem: classical logic erases information

A two-input AND gate is not reversible. From the output `0` you cannot recover the
inputs — three of the four input combinations produce it. Every irreversible gate
throws away information, and a circuit built from them cannot be run backwards.
That is fatal for the project's north star: using a compiled classical oracle as
the body of a quantum-controlled operation (`when(qubit) do f(x) end` in Sturm.jl).
Quantum mechanics is unitary; the oracle has to be reversible, and it has to leave
no scratch behind — any ancilla that ends in a non-zero state stays entangled with
the work register and silently corrupts interference.

So we need two things at once: a circuit made only of *reversible* primitives
(Bennett.jl uses NOT, CNOT, and Toffoli — Toffoli alone is universal for classical
reversible logic), and a guarantee that every scratch wire it allocated returns to
`0`. Bennett's 1973 paper gives both, for *any* computation, mechanically.

> Charles H. Bennett, **"Logical Reversibility of Computation"**, *IBM Journal of
> Research and Development* **17**(6):525–532, 1973.
> DOI [10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525).

(The repository README historically linked this to the SIAM DOI `10.1137/0218053`;
that is the *1989* "Time/Space Trade-Offs" paper, a different result discussed at
the bottom of this page. The 1973 construction is `10.1147/rd.176.0525`.)

## The construction: forward, copy-out, reverse

Bennett's trick is almost embarrassingly simple. Take the irreversible computation,
make each step reversible by writing its result onto a *fresh* scratch wire instead
of overwriting an input (a reversible step never erases), and run it forward. You
now hold the answer — but also a mountain of intermediate scratch values you would
like to throw away, except throwing them away is exactly the irreversible erasure
we are forbidden. Bennett's answer: don't throw them away, **un-compute** them.

Three phases:

1. **Forward.** Run the reversible gate sequence. The output lands on a set of
   output wires; every intermediate value sits on an ancilla wire.
2. **Copy-out.** CNOT each output wire into a brand-new copy wire. CNOT is
   reversible, and copying a value out does not disturb the source.
3. **Reverse.** Apply the forward gate sequence again, in reverse order. Because
   every primitive (NOT, CNOT, Toffoli) is its own inverse, the reverse pass is the
   exact mathematical inverse of the forward pass. It runs the computation
   *backwards*, driving every ancilla — and the original output wires — back to the
   values they held before phase 1, i.e. back to `0`.

The copy made in phase 2 survives, because the reverse pass never touches the copy
wires. The net effect is `(x, 0…0) ↦ (x, f(x))`: inputs preserved, answer on the
copy wires, **every ancilla returned to zero**. That last clause is the whole point,
and it is true *by construction* — the reverse pass is literally the forward pass
undone, so whatever the forward pass wrote, the reverse pass un-writes.

In Bennett.jl this is `_bennett_default` in `src/bennett_transform.jl`. The shape of
the emitted gate list is exactly the three phases:

```julia
append!(all_gates, lr.gates)                       # forward
_emit_copy_gates!(all_gates, lr.output_wires, ...)  # CNOT copy-out
for i in length(lr.gates):-1:1                      # reverse
    push!(all_gates, lr.gates[i])
end
```

The wrapped circuit therefore has roughly `2 · (number of forward gates) + n_out`
gates and `n_out` extra copy wires — the cost of reversibility is a doubling of
gates plus one ancilla per output bit. (A finer space/time accounting, and how to
trade gates for wires, is the [space-time strategies](#space-time-strategies)
section below.)

### A worked invariant: `x + 1`

The smallest non-trivial example is an 8-bit increment. `gate_count` returns a
`NamedTuple` — not a bare integer — breaking the total out by primitive:

```julia
using Bennett
c = reversible_compile(x -> x + Int8(1), Int8)

gate_count(c)            # (total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
ancilla_count(c)         # 25
t_count(c)               # 84          (= 7 × Toffoli)
toffoli_depth(c)         # 12
depth(c)                 # 19
verify_reversibility(c)  # true
```

`verify_reversibility(c; n_tests=100)` is the operational form of the invariant: it
simulates the circuit and asserts, for each test input, that the output is correct
*and* that every ancilla wire ends at `0`. "Runs without error" is not a passing
test in this project (CLAUDE.md §4); the ancilla-zero check is.

The construction scales the same way for arbitrarily complex bodies — a quadratic,
for instance, just has a much longer forward pass:

```julia
f(x::Int8) = x*x + Int8(3)*x + Int8(1)
c = reversible_compile(f, Int8)

simulate(c, Int8(5))  # 41          (= 5² + 3·5 + 1, as an Int)
gate_count(c)         # (total = 482, NOT = 14, CNOT = 300, Toffoli = 168)
verify_reversibility(c)  # true
```

The `total` for the explicit ripple-carry increment obeys a clean doubling law
across widths — `total(2W) == 2·total(W) − 2`, so i8 `= 58` grows to i16, i32, i64
in lockstep. Those numbers are pinned as regression baselines in
`test/test_gate_count_regression.jl`; if a change moves them, that is a signal to
investigate, not a number to quietly re-bless (CLAUDE.md §6).

## The wire partition

Reversibility is only meaningful if you know which wires are *supposed* to end at
zero. Bennett.jl makes that explicit: every wire in a `ReversibleCircuit` is
classified into exactly one of four sets, and the inner constructor in
`src/gates.jl` validates the partition at construction time (Bennett-6azb, Bennett-s0tn):

| Class | Meaning |
| --- | --- |
| `input_wires` | hold the function arguments; preserved end-to-end |
| `output_wires` | the copy wires that carry `f(x)` out |
| `ancilla_wires` | scratch; **must** return to `0` — this is what `verify_reversibility` checks |
| `loop_check_wires` | one `LoopGuard` per data-dependent loop; holds a convergence bit that legitimately ends at `1` |

The constructor enforces that `ancilla` is disjoint from `input`, `output`, and
`loop_check`, that `loop_check` is disjoint from everything, and that the union
covers exactly `1:n_wires` (no wire escapes classification, none exceeds the wire
count). Any violation throws an `AssertionError` immediately — fail fast, fail loud
(CLAUDE.md §1).

One subtlety worth stating plainly, because the older docs got it wrong: **`input ∩
output` overlap is permitted.** A self-reversing primitive (next section) writes its
result back onto the input wires, so the same physical wire can be both an input and
an output. The invariant that always holds is *ancilla / loop-check disjointness* —
not the tempting-but-false claim that "input wires are never targeted by any gate".

The `loop_check` class exists because a circuit that unrolls a data-dependent loop
to a fixed bound `K` needs to record whether the loop actually converged within `K`
iterations. That convergence bit is copied out parallel to the output (so the
reverse pass leaves it frozen) and ends at `1` on a healthy run; `simulate` errors
loud if it reads `0`. It is deliberately *not* an ancilla, so the ancilla-zero check
does not trip on it.

## The self-reversing fast path

Some primitives are *already* reversible and self-cleaning: their gate sequence ends
with the ancillae at zero and the result sitting on the output wires, with no wrap
needed. A QROM table lookup (`lower_tabulate`, `(x, 0^W) ↦ (x, f(x))`) and the
Sun-Borissov polylogarithmic-depth multiplier (`lower_mul_qcla_tree!`) are the two
canonical examples. Wrapping them in the full forward/copy/reverse construction
would just *double* their gate count and waste `n_out` ancillae for nothing.

When the lowering result carries `self_reversing = true`, every strategy
short-circuits to **forward-only** emission. But — fail-fast, fail-loud — the
compiler does not take that flag on trust. Before skipping the wrap it runs the
**U03 probe battery** (`_validate_self_reversing!`, Bennett-egu6 in
`src/bennett_transform.jl`): it forward-executes the gate sequence under four
deterministic input vectors and asserts the invariants hold each time. The four
probes are chosen for coverage, not randomness (CLAUDE.md §4/§6 favour reproducible
failures):

- **all-zero** — catches an ancilla that flips unconditionally;
- **all-one** — activates every Toffoli control simultaneously;
- **walking-1 on the first input wire** and
- **walking-1 on the last input wire** — catch per-lane leakage that a fully
  quiescent or fully active input would mask.

If any probe finds a dirty ancilla or a mutated input, the build throws an
`ArgumentError` naming the offending wire — a forged `self_reversing` tag fails
loudly rather than poisoning every downstream circuit. The fast path is
*strategy-independent*: since Bennett-rjk7, all six space-time strategies honor the
flag and run the same probe (before that, only the default strategy did, and the
others silently bypassed the check). A self-reversing primitive may never carry a
loop guard — a closed self-cleaning sequence cannot contain a data-dependent loop —
and that contradiction is a hard error.

Downstream callers who *know* they are handing over a self-cleaning primitive and
want the "no wrap" assumption load-bearing at the call site can use
`Bennett.bennett_direct(lr)`, which asserts `self_reversing == true` and then runs
the same probe.

## Space-time strategies

The default construction is generous with wires: it keeps every intermediate value
live until the reverse pass un-computes it, so peak wire usage is essentially the
whole forward trace. For a deep computation that is a lot of ancillae. The classic
escape is to **recompute** some intermediates instead of storing them — trading more
gates (time) for fewer live wires (space). Bennett.jl exposes this as a pluggable
`strategy` at the `bennett` stage:

```julia
bennett(lr::LoweringResult; strategy::BennettStrategy = DefaultStrategy())
```

There are six concrete strategies (all `<: BennettStrategy`, defined in
`src/bennett_strategies.jl`):

| Strategy | Idea | Source |
| --- | --- | --- |
| `DefaultStrategy` | canonical forward + CNOT-copy + reverse | `src/bennett_transform.jl` |
| `EagerStrategy` | gate-level dead-end cleanup: uncompute a wire as soon as it is never used again as a control | `src/pebble/eager.jl` |
| `ValueEagerStrategy` | PRS15 Algorithm 2 — group/value-level eager cleanup + Kahn reverse-topological uncompute over the SSA DAG | `src/pebble/value_eager.jl` |
| `CheckpointStrategy` | per-group checkpoint-and-free | `src/pebble/pebbled_groups.jl` |
| `PebbledStrategy(max_pebbles)` | Knill 1995 gate-level recursive pebbling | `src/pebble/pebbling.jl` |
| `PebbledGroupStrategy(max_pebbles)` | group-level pebbling with wire reuse | `src/pebble/pebbled_groups.jl` |

`bennett` and `bennett_direct` are *not* exported — reach them as `Bennett.bennett`
or `using Bennett: bennett`. The six strategy types **are** exported, as are five
legacy alias forwarders (`eager_bennett`, `value_eager_bennett`,
`checkpoint_bennett`, `pebbled_bennett`, `pebbled_group_bennett`). (Note that
`reversible_compile` has its own `strategy` kwarg — `:auto`, `:tabulate`,
`:expression` — which selects an *IR-level lowering* path and is a different axis
entirely from the space-time `BennettStrategy` here.)

### The pebble game

The theory under the pebbling strategies is Knill's 1995 analysis of the *reversible
pebble game* on a chain of `n` computation steps with `s` pebbles (available
ancillae). His Theorem 2.1 recursion (in `src/pebble/pebbling.jl`) is

```
F(1, s) = 1                                        for s ≥ 1
F(n, 1) = ∞                                         for n ≥ 2
F(n, s) = min over m of  F(m, s) + F(m, s−1) + F(n−m, s−1)
```

read as: pebble the first `m` nodes, un-pebble them with one fewer pebble, then
continue with the remaining `n − m` nodes — also with one fewer pebble. The three
terms are forward / unforward / continue, which is Bennett's forward/reverse idea
applied recursively. Theorem 2.3 gives the space frontier: `F(n, s)` is finite iff
`n ≤ 2^(s−1)`, so the minimum number of pebbles to compute a chain of length `n` at
all is `1 + ⌈log₂ n⌉`. The DP table (`knill_pebble_cost`, `min_pebbles`,
`pebble_tradeoff`) is the space-vs-time accountant; full Bennett is the `s = n`
extreme (maximum space, minimum recomputation), and tighter pebble bounds buy space
back at a `gate-count` premium.

The eager strategies (`PRS15` = Parent–Roetteler–Svore 2015, *Reversible circuit
compilation with space constraints*) attack the same trade-off from the other end:
rather than scheduling a global pebble game, they uncompute each intermediate *as
early as the dataflow allows*, freeing its wire the moment no later gate reads it.

A couple of honest caveats live in the code. `EagerStrategy` is gate-level *dead-end*
cleanup — only wires that are never again used as a control get uncomputed eagerly;
true wire-level eager uncompute was tried and fails at gate granularity, so the
genuine PRS15 Algorithm 2 lives in `ValueEagerStrategy` at group granularity. And
every non-default strategy *refuses branching control flow*: when a lowering result
contains two or more predicate groups (a real `if`/`else`), the pebbling and eager
strategies fall back to the default `bennett(lr)` because the cross-branch wire
dependencies are invisible to their DAG. `PebbledStrategy(0)` and
`PebbledGroupStrategy(0)` (the zero default) likewise degrade gracefully to full
Bennett rather than erroring.

## What this codebase does *not* implement

Being precise about the literature matters as much as implementing it.

- **Bennett 1989** — *Time/Space Trade-Offs for Reversible Computation*, SIAM J.
  Comput. **18**(4), DOI [10.1137/0218053](https://doi.org/10.1137/0218053) — proves
  the `O(T^{1+ε})` time / `O(S log T)` space frontier. It is referenced in the
  README, but **no strategy implements the 1989 construction.** The space-time
  variants here implement Knill 1995's analysis of the pebble game, which is a
  related but distinct result. Do not cite the 1989 SIAM DOI for the *1973*
  construction; they are different papers solving different problems.

- **Meuli 2019 SAT-based pebbling** — also **not implemented.** An earlier
  `src/sat_pebbling.jl` (211 LOC) and its PicoSAT dependency were *removed*
  (Bennett-u2yp): the file was never wired into any strategy dispatcher, so it was
  dead weight. A modern-SAT-solver replacement is tracked as future work
  (Bennett-fg2), but as of today no strategy uses SAT pebbling, and any
  documentation that labels `pebbled_group_bennett` as "Meuli 2019 SAT pebbling" is
  stale — that strategy is Knill 1995 + PRS15 with wire reuse.

The construction that *is* the foundation of every compile is the 1973 one: forward,
copy-out, reverse, with the reverse pass un-doing the forward pass so that every
ancilla returns to zero. Everything else — the strategies, the wire partition, the
self-reversing fast path — is bookkeeping and optimization layered on top of that
one guarantee.

## See also

- [Architecture overview](architecture.md) — where the `bennett`
  stage sits in the extract → lower → bennett → simulate pipeline.
- [API reference](../reference/api.md) — exact signatures for `bennett`, the
  `BennettStrategy` types, `verify_reversibility`, and the metrics functions.
- [Project README](../../../README.md) — the one-paragraph pitch and the long-term
  quantum-control goal.
