# Compiling Float64 functions

*A hands-on walk through turning a plain `Float64` polynomial into a reversible
circuit of NOT/CNOT/Toffoli gates — and understanding why the result is so much
bigger than its integer cousin. For readers who have already compiled an integer
function and want to see floating point work end to end.*

Bennett.jl has no hardware floating-point gates. Instead, every IEEE 754
binary64 operation is implemented in **pure integer arithmetic** by a soft-float
library (`src/softfloat/`, the `SoftFloatLib` module). When you compile a
`Float64` function, your arithmetic is rewritten into calls to those integer
primitives, and the rest of the pipeline — lowering, Bennett's construction,
simulation — proceeds exactly as it does for an integer program. The circuit
operates on the raw 64-bit IEEE 754 *bit patterns*.

This tutorial builds one small polynomial and runs it through the whole pipeline.

## 1. Write a plain Julia function

We will evaluate the quadratic `x*x + 3.0*x + 1.0`. Two rules to keep in mind:

- The function must be **generic** — no `::Float64` annotations on the arguments.
  Internally, `reversible_compile` runs your function on a `SoftFloat` wrapper
  (`src/softfloat_dispatch.jl`), and a `::Float64` annotation would refuse that
  wrapper.
- Write the polynomial with **explicit multiplications**, not `^`. We explain why
  in step 6, but the short version is that `*` stays inside the bit-exact core
  while `^` reaches for the transcendental machinery.

```julia
using Bennett

g(x) = x*x + 3.0*x + 1.0
```

## 2. Compile it

```julia
c = reversible_compile(g, Float64)
```

That is the whole call. `reversible_compile(f, Float64)` wraps the argument in a
`SoftFloat`, so `x*x` emits a `call @j_soft_fmul`, `3.0*x` another `soft_fmul`,
and the two `+`s become `soft_fadd`. The extractor recognises these registered
callees and the lowerer inlines each one — itself a branchless integer Julia
function — down to gates.

All the usual keywords still apply on this path (`add`, `mul`, `strategy`,
`fold_constants`, `target`, …); the defaults are fine here.

## 3. Run the circuit

The circuit consumes and produces `Float64` values as their `UInt64` bit
patterns. Use `reinterpret` to cross the boundary in each direction.

```julia
bits_in  = reinterpret(UInt64, 2.0)   # IEEE 754 encoding of 2.0
bits_out = simulate(c, bits_in)       # a UInt64 bit pattern
reinterpret(Float64, bits_out)        # => 11.0
```

`simulate` returns the output register as a `UInt64`; `reinterpret(Float64, …)`
decodes it back to a float. And indeed `g(2.0) = 2·2 + 3·2 + 1 = 11.0`.

Try another input to convince yourself:

```julia
reinterpret(Float64, simulate(c, reinterpret(UInt64, 0.5)))   # => 2.75
```

(`g(0.5) = 0.25 + 1.5 + 1.0 = 2.75`.)

## 4. Verify reversibility

Bennett's construction guarantees that every ancilla returns to zero and the
input is preserved. `verify_reversibility` checks that invariant on random
inputs (100 by default):

```julia
verify_reversibility(c)   # => true
```

This is the test that matters. "It ran without error" is *not* a passing result
for a reversible circuit — the ancillae must come back clean.

## 5. Look at the cost

Now inspect the gate budget. `gate_count` returns a `NamedTuple`, not a single
integer:

```julia
gate_count(c)
# (total = 341476, NOT = 46396, CNOT = 220858, Toffoli = 74222)

ancilla_count(c)   # 235759
```

(Counts are from the build used to write this page; the exact figures move with
the soft-float library, but the order of magnitude — a few hundred thousand
gates — is the point.)

For comparison, the *integer* version of the same polynomial,
`f(x::Int8) = x*x + Int8(3)*x + Int8(1)`, compiles to a circuit with
`gate_count(...).total = 482`. The `Float64` version is roughly a thousand times
larger. That is the cost of IEEE 754: each `soft_fmul`/`soft_fadd` is a full
branchless implementation that handles sign, exponent alignment, mantissa
multiplication, normalisation, round-to-nearest-even, and every special case
(NaN, ±Inf, subnormals, signed zeros) — all unconditionally, with no hardware
help. Floating point is not free here; it is an entire integer subroutine per
arithmetic operation.

## 6. Bit-exact arithmetic, approximate transcendentals

The soft-float library splits into two tiers with **different correctness
contracts**, and knowing which tier you are in tells you what to expect.

**Bit-exact tier (matches Julia's native result bit for bit).** Addition,
subtraction, multiplication, division, `fma`, `sqrt`, negation, all comparisons,
all conversions (`fptosi`/`fptoui`/`sitofp`/`fpext`/`fptrunc`), rounding
(`floor`/`ceil`/`trunc`/`round`) and `min`/`max` are bit-exact against hardware,
checked across extensive random bit-pattern sweeps plus the IEEE edge cases
(±0, ±Inf, NaN, subnormals) in the test suite. If your function only uses these,
the compiled circuit reproduces Julia's floating-point answer *exactly*.

**Transcendental tier (≤ 2 ulp, not bit-exact).** `exp`, `log`, `sin`, `cos`,
`tan`, `pow`, `atan`, the hyperbolics, and friends are faithful ports of the
musl / Arm Optimized Routines and FreeBSD/SunPro kernels. They target within
about 2 units in the last place of `Base`, but they are **not** guaranteed
bit-identical. Reach for these only when you need them, and do not assume a
round-trip will match Julia to the last bit.

This is exactly why step 1 told you to write `x*x` instead of `x^2`. The `^`
operator on `SoftFloat` routes to `soft_pow_julia` (`src/softfloat/fpow_julia.jl`)
— part of the transcendental tier — which is both far larger and outside the
bit-exact contract. Plain `*` and `+` keep your polynomial entirely inside the
bit-exact core, so the circuit's output equals Julia's `g(x)` to the bit.

## 7. Float32 is rejected — on purpose

You might expect `Float32` to "just work" at half the width. It does not:

```julia
reversible_compile(g, Float32)
# ERROR: ArgumentError: reversible_compile: arg_types[1] = Float32 is not
# supported; expected one of (Int8, Int16, Int32, Int64, UInt8, UInt16,
# UInt32, UInt64, Float64, Bool) or an NTuple of those
```

The reason is **double rounding**. There are no native 24-bit-mantissa f32
arithmetic primitives in the library. The only way a single-precision operation
could be evaluated is by widening to f64, doing the f64 op, and narrowing back —
`soft_fpext` (f32 → f64) → f64 op → `soft_fptrunc` (f64 → f32). That rounds
*twice*: once when the f64 result is formed, and again at the `fptrunc`.
Hardware f32 rounds exactly *once*, at the single-precision mantissa boundary.
On sticky-bit-edge cases the two disagree by up to 1 ulp, which would silently
break the bit-exact contract that the f64 path upholds.

Rather than ship a path that is *almost* right, Bennett.jl refuses `Float32`
outright (CLAUDE.md §13; Bennett-3rph). Native single-precision support is future
work. If you have single-precision data, convert it to `Float64`, compile, and
convert the result back.

## What you learned

- `reversible_compile(f, Float64)` compiles a generic Julia float function to
  integer gates via branchless soft-float; the circuit runs on `UInt64` bit
  patterns (encode/decode with `reinterpret`).
- `gate_count` returns a `NamedTuple`; `simulate` returns the output register;
  `verify_reversibility` is the test that actually matters.
- Float64 circuits are large because every arithmetic op is a full integer
  IEEE 754 subroutine.
- Arithmetic, comparison, conversion, rounding and min/max are **bit-exact**;
  transcendentals are **≤ 2 ulp**. Prefer `*` over `^` for exact polynomials.
- `Float32` is rejected to avoid double-rounding error.

## See also

- The soft-float sources: `src/softfloat/` (the `SoftFloatLib` module) and the
  user-facing wrapper in `src/softfloat_dispatch.jl`.
- [API reference](../reference/api.md) for the full `reversible_compile`,
  `simulate`, `gate_count`, and `verify_reversibility` signatures.
