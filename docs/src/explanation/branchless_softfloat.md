# Branchless soft-float

*Why Bennett.jl ships its own IEEE 754 binary64 library written in pure
branchless integer arithmetic — and what that buys (and costs) you when you
`reversible_compile` a `Float64` function. For readers who want the design
rationale, not a how-to.*

A reversible circuit is built from `NOT`, `CNOT`, and `Toffoli` gates over
classical bits. There is no floating-point unit at the bottom of that stack —
only wires and bit operations. So before any `Float64` program can become a
circuit, IEEE 754 itself has to be expressed in integer arithmetic. Bennett.jl
does that with a self-contained soft-float library (`src/softfloat/`) that
implements `+ - * / fma sqrt`, all comparisons, every conversion, rounding,
min/max, and the usual transcendentals — all operating on raw `UInt64` bit
patterns. This page explains why that library exists, why every line of it is
*branchless*, and where its accuracy guarantees stop.

## Soft-float as the floating-point standard library

The library is not a separate pipeline stage. It is the set of inlinable
primitives the rest of the compiler already knows how to lower.

`reversible_compile(f, Float64)` (in `src/softfloat_dispatch.jl`) wraps each
argument in a `struct SoftFloat` whose operator overloads make the user's plain
Julia float code emit `call @j_soft_fXXX` instructions in the extracted LLVM IR.
The extractor recognises these registered callees (`src/callees.jl`) and produces
`IRCall` nodes; the lowerer then gate-level-inlines each `soft_*` body — itself a
branchless integer Julia function — into `NOT`/`CNOT`/`Toffoli` gates. After
that, Bennett's construction and the simulator proceed exactly as they would for
any integer program. In other words: the soft-float library is the thing that
turns IEEE 754 semantics into the integer-only IR the pipeline already handles.

```julia
using Bennett

c = reversible_compile(x -> x + x, Float64)

gate_count(c)
# => (total = 63058, NOT = 10304, CNOT = 40266, Toffoli = 12488)

# The circuit operates on UInt64 bit patterns (the IEEE 754 encoding).
reinterpret(Float64, simulate(c, reinterpret(UInt64, 2.5)))
# => 5.0

verify_reversibility(c; n_tests = 50)
# => true
```

A single `Float64` addition expands to tens of thousands of gates because a
full IEEE 754 add is a real algorithm — align exponents, add mantissas,
renormalise, round-to-nearest-even, handle NaN/Inf/subnormals — and all of it
has to run in reversible logic. The cost is honest; floating point is expensive
when you have to build it out of Toffolis.

## Why branchless: phi, select, and false-path sensitization

The non-obvious design decision is that every soft-float primitive is written
*without data-dependent branches*. The special cases that IEEE 754 demands
(NaN, Inf, subnormal, the rounding carry-out) are all computed unconditionally
and then selected with `ifelse`. This is deliberate, and it is about
correctness, not micro-optimisation.

Branching Julia code compiles to LLVM IR with `phi` nodes: a `phi` merges values
that arrived along different control-flow edges at a basic-block join. When the
lowerer turns a `phi` into a reversible circuit it builds a MUX chain controlled
by per-edge path predicates. This machinery is the single most bug-prone part of
the compiler (see the *Phi Resolution and Control Flow* section of
[`CLAUDE.md`](../../../CLAUDE.md)). Its classic failure mode is **false-path
sensitization**: in a diamond CFG where both arms of an outer `if` feed the same
inner `phi`, the MUX condition for one arm can fire even though its guard was
never true. This is a well-known hazard in VLSI circuit verification, and the
v0.5 soft-float overflow bug was a concrete instance of it.

`ifelse` sidesteps the entire class. It compiles to an LLVM `select`, which the
lowerer turns into a per-bit MUX controlled by *one explicit condition wire*.
There is no control-flow merge, so there is nothing for false-path
sensitization to corrupt. By keeping the soft-float kernels branchless, the
correctness of `Float64` programs does not depend on the phi resolver being
right about every diamond — there are simply no diamonds inside the kernels to
get wrong.

This rule is non-negotiable for the library: see the *branchless rationale* note
recorded under `worklog/` and rule 13 in [`CLAUDE.md`](../../../CLAUDE.md).

## Two layers: `module SoftFloatLib` and `struct SoftFloat`

Two similarly named things sit at this boundary, and they are easy to confuse.

- **`module SoftFloatLib`** (`src/softfloat/softfloat.jl`) is the library of
  primitives. It wraps ~34 op files and exports **60** public `soft_*` symbols.
  All the internal helpers (`_add128`, `_sf_normalize_to_bit52`, the lookup
  tables) and bit-pattern constants (`EXP_MASK`, `IMPLICIT`, `INDEF`, `QNAN`)
  stay module-private, so they do not leak into Bennett's top-level namespace.
  Bennett re-exports the public surface via `using .SoftFloatLib`.

- **`struct SoftFloat`** (`src/softfloat_dispatch.jl`, *not* inside
  `softfloat/`) is the user-facing dispatch shim — a one-field `UInt64` wrapper
  whose `Base` operator overloads route `+ - * / < == sqrt exp floor ceil trunc
  round min max ^ abs copysign` to the corresponding `soft_*` primitive. This is
  what `reversible_compile(f, Float64)` wraps your arguments in so that a generic
  `f(x)` emits `soft_*` calls when run on `SoftFloat` values.

The module is named `SoftFloatLib` precisely so it does not clash with the
`SoftFloat` struct. The `@inline` on the compile wrapper forces Julia to inline
through `f → SoftFloat./ → soft_fdiv`, which eliminates the struct-passing ABI
and produces clean integer IR with direct `call @j_soft_fdiv` instructions the
callee registry recognises.

The 60 exported primitives break down as: 6 binary arithmetic
(`fadd`/`fsub`/`fmul`/`fma`/`fdiv`/`fsqrt`) plus `fneg`; 10 `fcmp` predicates;
5 conversions (`fpext`/`fptrunc`/`fptosi`/`fptoui`/`sitofp`); 5 rounding
(`round`/`round_away`/`floor`/`ceil`/`trunc`); 6 min/max; and 27 transcendentals
(`exp`/`log`/`pow`/`sin`/`cos`/`tan`/`atan`/inverse-trig/hyperbolic/`log1p`/`expm1`
and their variants). (The in-file comment that still says "32 primitives" and
the "39" figure in older docs both predate the transcendental and min/max
additions — count the `export` block, not the comment.)

## The accuracy contract: bit-exact core vs ≤2-ulp transcendentals

The library makes two *different* promises, and conflating them is the most
common documentation error.

**Bit-exact vs Julia native** — this holds for the algebraic core:
`+`, `-`, `*`, `/`, `neg`, `fma`, `sqrt`, **all** comparisons, **all** conversions
(`fptosi`/`fptoui`/`sitofp`/`fpext`/`fptrunc`), **all** rounding modes, and **all**
min/max variants. These are correctly-rounded by construction (restoring
division and digit-by-digit sqrt with sticky-bit round-to-nearest-even, etc.) and
are tested across roughly 1.2M random raw-bit pairs aggregated over the
`test/test_softf*.jl` suite, covering subnormals, NaN payloads and signs, Inf,
signed zero, and overflow boundaries.

```julia
a, b = reinterpret(UInt64, 0.1), reinterpret(UInt64, 0.2)

soft_fadd(a, b) == reinterpret(UInt64, 0.1 + 0.2)   # => true
soft_fmul(a, b) == reinterpret(UInt64, 0.1 * 0.2)   # => true
soft_fsqrt(reinterpret(UInt64, 2.0)) == reinterpret(UInt64, sqrt(2.0))  # => true
```

**≤ 2 ulp, not bit-exact** — this is the weaker contract for the
transcendentals (`exp`, `log`, `pow`, `sin`, `cos`, `tan`, `atan`, the inverse
trig and hyperbolic family, `log1p`, `expm1`). These are faithful ports of
established libm implementations: the exp/log/pow kernels track the musl / Arm
Optimized Routines (Wilhelm & Sibidanov 2018; musl reference accuracy is around
0.5 ulp), and sin/cos/`rem_pio2` track FreeBSD/SunPro 1993 (Cody-Waite plus
Payne-Hanek range reduction). They aim for ≤ 2 ulp against `Base`, and
`soft_sin`/`soft_cos` are bit-exact against the system libm `ccall` on Linux —
but they are *not* promised bit-exact against `Base`. Many inputs happen to land
exactly (`soft_exp_julia(1.0)` matches `Base.exp(1.0)` to the bit), but you must
not rely on that across the range.

The reason the split exists is intrinsic: correctly-rounded transcendentals are
an unsolved-in-general problem (the table-maker's dilemma), and a faithful
≤ 2 ulp libm port is the honest, achievable target. The algebraic operations have
no such excuse, so they are held to the bit.

## Float32 is rejected (double rounding)

`reversible_compile(f, Float32)` is rejected. There are no native 24-bit-mantissa
`f32` arithmetic primitives — `soft_f32_fadd` and friends do not exist. When an
`f32` `fadd`/`fsub`/`fmul`/`fdiv` shows up inside mixed-precision IR (which can
only happen via a `Float64` entry point), the lowering emits the round-trip
`soft_fpext → soft_fXXX (f64) → soft_fptrunc`. That **double-rounds**: hardware
`f32` arithmetic rounds once, at the `f32` mantissa boundary; this lowering
rounds twice, once at the implicit `f64` result and again at `fptrunc`. The two
agree for the vast majority of inputs but diverge on sticky-bit-edge cases by up
to ~1 ulp. Because the bit-exact contract cannot be honoured, single-precision
entry is refused rather than silently approximated.

The rejection is enforced two ways. Structurally, only
`reversible_compile(f, ::Type{Float64}...)` overloads exist (for one to three
arguments), so a `Float32` type argument has no matching float method. Explicitly,
`src/extract/instructions.jl` errors on width-32/16 `llvm.sqrt`/`llvm.exp`/etc.
intrinsics, citing rule 13 of [`CLAUDE.md`](../../../CLAUDE.md). Native f32 paths
are tracked as future work; the docstring header of `src/softfloat/fpconv.jl` is
the canonical writeup. See [`soft_fpext` / `soft_fptrunc`](../reference/autodocs.md) for
the conversion primitives themselves, which *are* bit-exact (only the
back-to-back composition double-rounds).

## `Base.exp` routes to `soft_exp_julia`, not `soft_exp`

A subtlety worth stating plainly because it is a frequent source of confusion:
when your Julia float code calls `exp`, it does **not** call `soft_exp`. The
`SoftFloat` overload routes `Base.exp` to `soft_exp_julia`, and `^(SoftFloat,
SoftFloat)` routes to `soft_pow_julia` (see `src/softfloat_dispatch.jl` lines
40 and 52). The non-`_julia` musl variants (`soft_exp`, `soft_pow`) are reserved
for the *other* ingest path: raw `.ll`/`.bc` from C/Rust frontends and direct
`llvm.exp`/`llvm.pow` intrinsics. So a claim that "Julia float code uses
`soft_exp`" is simply wrong about which function runs.

## The subnormal-output testing convention

Every transcendental must ship a `@testset "subnormal-output range"` that sweeps
the inputs `x` for which `Base.<func>(x)` is *subnormal*, stepping finely enough
(typically 0.25 or 0.5) to populate every binade, asserting bit-exact or ≤ 1 ulp
equality against `Base`. This is codified in rule 13 of
[`CLAUDE.md`](../../../CLAUDE.md); the reference implementations live at
`test/test_softfexp.jl:135` and `test/test_softfexp_julia.jl:182`.

The convention exists because of a specific scar. The `soft_exp` post-mortem
(Bennett-wigl) traced a garbage-output bug in the input window `x ∈ [-708.4,
-745]` — exactly the region where `exp(x)` produces subnormal Float64 results
and then flushes toward zero. The bug survived the initial random testing
because that sweep ran on `[-50, 50]` and never visited the subnormal-output
region at all. The mandatory subnormal-output sweep makes that blind spot
un-missable: any new transcendental is tested precisely where its output decays
into the subnormal range, catching the whole garbage-output bug class up front
rather than in production.

## See also

- [Architecture](../explanation/architecture.md) — where soft-float sits in the
  extract → lower → Bennett → simulate pipeline.
- [API reference](../reference/api.md) and [Reference](../reference/autodocs.md) — signatures for
  the `soft_*` primitives and `reversible_compile`.
- [Tutorial](../tutorials/first_circuit.md) — a runnable first compile.
- `src/softfloat_dispatch.jl`, `src/softfloat/softfloat.jl`, `src/callees.jl` —
  the dispatch shim, the library module, and callee registration.
- Bennett, *Logical Reversibility of Computation*, IBM J. Res. Dev. 17(6), 1973
  ([doi:10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525)) — the
  construction every one of these gates feeds into.
