# Branches and loops

*A hands-on tour of how Bennett.jl turns `if`, ternaries, and bounded loops into reversible circuits — for readers who have compiled a straight-line function and want to add control flow.*

In [your first circuit](first_circuit.md) you compiled a function that ran top to
bottom with no decisions. Real code branches and loops. This tutorial walks you
through both: a branchy function (`abs`, then `min`), what LLVM and Bennett.jl do
with the `if`, and finally bounded loops — the `for 1:K` that LLVM unrolls for
free, and the data-dependent `while` that needs you to name a bound. Every code
block below runs as shown; the outputs are real.

Start a session:

```julia
using Bennett
```

## 1. A branchy function: `abs`

Here is integer absolute value, written as a plain Julia ternary:

```julia
absf(x::Int8) = x < 0 ? -x : x

c = reversible_compile(absf, Int8)

gate_count(c)      # => (total = 258, NOT = 60, CNOT = 156, Toffoli = 42)
ancilla_count(c)   # => 100
toffoli_depth(c)   # => 16
```

`gate_count` returns a `NamedTuple`, not a bare integer — `total` plus the
per-type breakdown. Now run it:

```julia
simulate(c, Int8(-7))    # => 7
simulate(c, Int8(7))     # => 7
simulate(c, Int8(-128))  # => -128
```

That last line is not a bug. In two's-complement `Int8`, negating `-128`
overflows back to `-128`, and Julia's own `abs(Int8(-128))` is also `-128`. The
circuit faithfully mirrors Julia/LLVM wraparound semantics rather than inventing
its own. We can confirm the whole input space at once:

```julia
all(simulate(c, Int8(x)) == abs(Int8(x)) for x in -128:127)  # => true
verify_reversibility(c)                                       # => true
```

`verify_reversibility` is the non-negotiable check: it confirms every ancilla
returns to zero (Bennett's invariant). "It ran" is never enough — see
[the Bennett construction](../explanation/bennett_construction.md).

## 2. How `if` becomes a phi, and a phi becomes a MUX

When you compile a branch, LLVM lowers the two arms into separate basic blocks
that rejoin at a **phi node** — a pseudo-instruction at the join point that says
"the value here is `-x` if we came from the then-block, or `x` if we came from
the else-block." Bennett.jl turns that phi into a **multiplexer (MUX)**: a small
reversible circuit that, controlled by a condition bit, copies one of the two
candidate values into a fresh register. The primitive lives in
`src/lowering/arith.jl` as `lower_mux!` and costs four gates per bit (three
CNOTs and one Toffoli).

The subtle part is *which* condition controls each MUX. Bennett.jl does not use
the raw branch condition; it uses a **path predicate** — a one-bit wire that is
true exactly when control actually reaches that incoming edge. For a value
arriving on the true edge of a branch the predicate is `AND(reached_this_block,
cond)`; on the false edge it is `AND(reached_this_block, NOT cond)`. These edge
predicates are constructed to be **mutually exclusive**, so for any input exactly
one MUX in the chain fires. The resolver is `resolve_phi_predicated!` in
`src/lowering/phi.jl`.

Why all this care? Because the **#1 correctness risk in the whole compiler** is
*false-path sensitization*: a MUX condition firing when its guarding branch
condition was not actually taken — a value leaking in from a path control never
followed. This is a classic VLSI-verification hazard, and a diamond-shaped CFG
(both arms of an outer `if` feeding the same inner phi) is exactly where it
bites. Mutually-exclusive edge predicates are the defense: each predicate is a
single-bit wire and predecessors are required to be distinct, so "exactly one
fires" provably holds (`src/lowering/phi.jl`). You get this for free — but it is
why the phi file is the most carefully guarded code in the project.

A second branchy example, `min` of two arguments, exercises the same machinery
with two inputs:

```julia
minf(x::Int8, y::Int8) = x < y ? x : y

cm = reversible_compile(minf, Int8, Int8)

gate_count(cm)                       # => (total = 216, NOT = 28, CNOT = 142, Toffoli = 46)
simulate(cm, (Int8(3), Int8(9)))     # => 3
simulate(cm, (Int8(9), Int8(3)))     # => 3
verify_reversibility(cm)             # => true
```

Note the calling conventions: multiple argument types are passed as separate
positional `Type`s (`reversible_compile(minf, Int8, Int8)`), and multiple inputs
to `simulate` are passed as a **tuple** (`simulate(cm, (Int8(3), Int8(9)))`).

## 3. Bounded loops LLVM resolves for you

A loop whose trip count is a compile-time constant — the textbook `for i in
1:K` — never reaches Bennett.jl as a loop at all. LLVM fully unrolls it during
its own optimization passes, and the compiler sees straight-line code:

```julia
function sumto(x::Int8)
    s = Int8(0)
    for i in 1:4
        s += x
    end
    s
end

cs = reversible_compile(sumto, Int8)   # no max_loop_iterations needed

gate_count(cs)            # => (total = 22, NOT = 2, CNOT = 20, Toffoli = 0)
simulate(cs, Int8(5))     # => 20
verify_reversibility(cs)  # => true
```

Four additions, no branches, no Toffolis — exactly what `4 * x` should cost.
Because the loop count is fixed, there is no back-edge in the IR, so you do not
pass `max_loop_iterations` at all.

## 4. Data-dependent loops need a bound

Now a loop whose iteration count depends on the *value* of the input — counting
how many times you can halve `n` before reaching 1 (an integer `log2`):

```julia
function ilog2(n::Int8)
    c = Int8(0)
    while n > Int8(1)
        n = n >> 1
        c += Int8(1)
    end
    c
end
```

A reversible circuit is a fixed piece of hardware: it has no runtime loop. So a
data-dependent loop has to be **unrolled to a fixed bound** at compile time, and
you must supply that bound. Forget it, and the compiler refuses — loudly:

```julia
reversible_compile(ilog2, Int8)
# ERROR: ArgumentError: lower: loop detected in LLVM IR but
#   max_loop_iterations not specified. Pass max_loop_iterations=N to
#   reversible_compile.
```

Give it a bound large enough for the worst case. For `Int8`, the largest input
(127) needs six halvings, so `K = 8` has headroom for every input:

```julia
c8 = reversible_compile(ilog2, Int8; max_loop_iterations=8)

gate_count(c8)            # => (total = 2039, NOT = 386, CNOT = 1243, Toffoli = 410)
ancilla_count(c8)         # => 939
simulate(c8, Int8(100))   # => 6
simulate(c8, Int8(1))     # => 0
simulate(c8, Int8(-5))    # => 0   (n > 1 false immediately)

# every Int8 input converges within 8 iterations:
all(simulate(c8, Int8(x)) ==
        (m = Int(x); k = 0; while m > 1; m >>= 1; k += 1; end; Int8(k))
    for x in -128:127)    # => true
```

### The convergence guard: too small a `K` raises, never lies

The dangerous failure mode would be a `K` too small for some input: the unrolled
circuit stops early and returns the half-finished state. Bennett.jl makes that
**impossible to miss**. Every data-dependent loop emits a *convergence guard* — a
wire that holds 1 only if the loop actually finished within `K` iterations
(`src/lowering/cfg.jl`, checked in `src/simulator.jl`). If an input needs more,
`simulate` errors instead of returning a wrong answer.

Compile with a deliberately small `K = 4` and feed it an input that needs more:

```julia
c4 = reversible_compile(ilog2, Int8; max_loop_iterations=4)

simulate(c4, Int8(16))    # => 4   (16 → 8 → 4 → 2 → 1, fits in K)

simulate(c4, Int8(100))
# ERROR: simulate: data-dependent loop with header block :L6 did not
#   converge within max_loop_iterations=4 for this input ((100,)). The
#   compiled circuit unrolls the loop to exactly 4 iterations; this input
#   needs more. Recompile with a larger max_loop_iterations (e.g.
#   max_loop_iterations=8).
```

That is the whole contract: **if the answer would be wrong, you get a crash with
the fix in the message, not a silent wrong number.** Choose `K` to cover your
worst-case input, with headroom, and verify exhaustively (as we did at `K = 8`
above) for the input range you care about.

> **A surprise worth knowing.** The default `optimize=true` runs LLVM's
> optimizer first, and it will sometimes *close a simple loop into a formula*
> before Bennett.jl ever sees a back-edge. A plain `while n > 0; n -= 1; end`,
> for instance, gets folded away — so it compiles with no `max_loop_iterations`
> at all. `ilog2` (counting halvings) is one the optimizer keeps as a real loop.
> If you are unsure whether your loop survives, just try compiling without `K`:
> if it succeeds, LLVM closed it; if it raises the `ArgumentError` above, it is
> genuinely data-dependent.

## 5. What is rejected

Two loop shapes are out of scope and are rejected loud, not mishandled:

- **Nested loops.** A loop header inside another loop's body is refused while
  collecting the loop body (`src/lowering/cfg.jl`). The exact error text depends
  on how LLVM happened to structure the IR, but you will always get a crash, not
  a circuit.
- **Early `return` inside a loop body.** An `IRRet` reached inside a loop is
  rejected for the same reason — the single-exit assumption the unroller relies
  on no longer holds.

These are deliberate scope limits, consistent with the project's fail-fast rule:
better to refuse than to emit a circuit that quietly violates the
return-to-zero invariant.

## Where to go next

Bounded unrolling covers loops with a known worst-case iteration count. For
**genuinely unbounded** computation — loops with no static bound, where you do
not want to commit to any `K` — Bennett.jl can target a reversible *virtual
machine* instead of a fixed circuit:

```julia
reversible_compile(f, Int8; target=:reversible_vm)  # requires `using BennettVM`
```

This returns a `BennettVM.VMProgram` whose interpreter is itself reversible, so a
data-dependent loop runs to completion at execution time rather than being
unrolled at compile time (an end-to-end Collatz iteration round-trips today). See
the how-to: [compile to the reversible VM](../howto/reversible_vm.md).

From here you might also explore:

- [Choosing arithmetic strategies](../howto/arithmetic_strategy.md) — `add`,
  `mul`, and the depth-vs-gate-count trade-off behind the Toffoli counts above.
- [The Bennett construction](../explanation/bennett_construction.md) — why every
  ancilla must return to zero, and how the forward/copy/reverse sandwich
  guarantees it.
- [Why soft-float is branchless](../explanation/branchless_softfloat.md) — the
  same false-path-sensitization hazard from §2, and how the IEEE-754 library
  sidesteps it with `select` instead of branches.
- [API reference](../reference/api.md) — the full `reversible_compile` keyword
  set and every metric used on this page.
