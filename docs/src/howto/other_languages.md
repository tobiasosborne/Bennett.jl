# Compile C and Rust (any LLVM front end)

*Goal-oriented recipe for feeding LLVM IR produced by clang or rustc into Bennett.jl. Assumes you already know how to compile a Julia function — see the [tutorial](../tutorials/first_circuit.md) first.*

Bennett.jl is language-agnostic below the IR level. The pipeline is

```
front end  ──►  LLVM IR  ──►  extract_parsed_ir*  ──►  reversible_compile  ──►  circuit
(clang/rustc)   (.ll/.bc)      (ParsedIR)              (lower + bennett)
```

The Julia entry point (`extract_parsed_ir(f, T)`) only differs in *where the IR comes from*: it runs `code_llvm` on a Julia function. Once you have a `.ll` or `.bc` file, the rest of the compiler does not care which front end produced it. The walker (`src/extract/`) is the sole source of truth — there is no regex parser and no language-specific path.

## The ingest entry points

Three exported functions read a foreign module and return a `ParsedIR` (or a vector of them). All live in `src/extract/entry.jl`.

```julia
extract_parsed_ir_from_ll(path; entry_function,
                          preprocess=false, passes=String[],
                          use_memory_ssa=false, mem=:auto, ptr_cells=false) -> ParsedIR

extract_parsed_ir_from_bc(path; entry_function,
                          preprocess=false, passes=String[],
                          mem=:auto, ptr_cells=false) -> ParsedIR

extract_parsed_ir_set_from_ll(path;
                          preprocess=false, passes=String[],
                          mem=:auto, ptr_cells=false) -> Vector{Pair{Symbol,ParsedIR}}
```

- `_from_ll` parses a textual `.ll` file and walks the **one** function whose LLVM name equals `entry_function` exactly.
- `_from_bc` does the same for a `.bc` bitcode file (via `LLVM.MemoryBufferFile`). It does **not** accept `use_memory_ssa` — the MemorySSA printer needs textual IR, so convert with `llvm-dis` and use `_from_ll` if you need that.
- `_from_ll_set` walks **every** defined (non-`declare`) function in the module and returns name → `ParsedIR` pairs. Body-less declarations (libc `malloc`/`free`, …) are skipped; calls to them become `Symbol`-callee `IRCall`s.

Then hand the `ParsedIR` to the dedicated overload:

```julia
reversible_compile(parsed::ParsedIR; add=:auto, mul=:auto,
                   fold_constants=true, max_loop_iterations=0, ...) -> ReversibleCircuit
```

> This overload skips IR extraction, so the Julia-only kwargs do not apply: passing `optimize`, `bit_width`, or `strategy` here raises `ArgumentError`.

## Recipe: C via clang

Write a plain integer function. Keep the ABI simple — fixed-width integer parameters and return value, no pointers, no floats (see [Limits](#limits)).

```c
/* add3.c */
signed char add3(signed char x) { return x + 3; }
```

Emit textual IR. Use `-O1` (or higher) so the parameter lives in a register instead of an `alloca`/`store`/`load` triple:

```bash
clang -O1 -emit-llvm -S -o add3.ll add3.c
```

The result is a clean module with a single `@add3` symbol (real clang output also carries `dso_local` and parameter attributes — elided here for clarity):

```llvm
define i8 @add3(i8 %0) {
  %2 = add i8 %0, 3
  ret i8 %2
}
```

Plain C does not mangle names, so `entry_function` is just `"add3"`. (If you compile **C++**, wrap the function in `extern "C"` to suppress mangling; otherwise the symbol becomes something like `@_Z4add3a` and you must pass that.)

Now compile and verify:

```julia
using Bennett

parsed = extract_parsed_ir_from_ll("add3.ll"; entry_function="add3")
c = reversible_compile(parsed)

simulate(c, Int8(5))          # => 8     (5 + 3)
verify_reversibility(c)       # => true
gate_count(c)                 # NamedTuple: (total, NOT, CNOT, Toffoli)
```

`gate_count` returns a `NamedTuple`, not an `Int`; index it as `gate_count(c).total` or `gate_count(c).Toffoli`. `simulate` returns a plain `Integer` (a `Tuple` for multi-output functions).

If you must work from `-O0` output (which carries `alloca`/`store`/`load`), let Bennett run the cleanup passes for you instead of bumping the optimisation level:

```julia
parsed = extract_parsed_ir_from_ll("add3.ll"; entry_function="add3", preprocess=true)
```

`preprocess=true` runs `DEFAULT_PREPROCESSING_PASSES` = `["sroa", "mem2reg", "simplifycfg", "instcombine"]` before the walk, scalarising stack slots into SSA registers. Pass your own list via `passes=[...]` to append extra LLVM New-Pass-Manager passes.

## Recipe: Rust via rustc

Mark the function `#[no_mangle]` so its symbol is the bare name, and `extern "C"` for a stable integer ABI. Use wrapping arithmetic — a plain `x + 3` compiles to an overflow check that branches into a `panic`, which is not a clean integer function.

```rust
// add3.rs
#[no_mangle]
pub extern "C" fn add3(x: i8) -> i8 {
    x.wrapping_add(3)
}
```

Emit IR (library crate, optimised so the panic-free body is a single block):

```bash
rustc --emit=llvm-ir --crate-type=lib -O -o add3.ll add3.rs
```

`-C panic=abort` or `#[inline]` are sometimes useful to keep the body branch-free; inspect the `.ll` to confirm the entry function is the clean `@add3` you expect. Then the Julia side is identical to the C recipe:

```julia
parsed = extract_parsed_ir_from_ll("add3.ll"; entry_function="add3")
c = reversible_compile(parsed)

simulate(c, Int8(5))      # => 8
verify_reversibility(c)   # => true
```

## Multi-function modules

A real `.ll` file usually defines several functions. `extract_parsed_ir_set_from_ll` walks all of them at once:

```julia
set = extract_parsed_ir_set_from_ll("mymodule.ll")   # Vector{Pair{Symbol,ParsedIR}}

for (name, parsed) in set
    c = reversible_compile(parsed)
    println(name, " => ", gate_count(c).total, " gates")
end
```

`declare`d-only functions (no body — e.g. `malloc`, `free`) are skipped; their call sites survive as `Symbol`-callee `IRCall`s, which is exactly the shape the BennettVM closed-world C-track consumes (`lower_vm(::Vector{<:Pair{Symbol,ParsedIR}})`). There is a matching Julia-side producer, `extract_parsed_ir_set_from_julia`, that walks a Julia entry's transitive call graph into the same vector shape.

## Bitcode instead of text

If your build only emits `.bc`, point `_from_bc` at it — the API is identical apart from the missing `use_memory_ssa`:

```julia
parsed = extract_parsed_ir_from_bc("add3.bc"; entry_function="add3")
c = reversible_compile(parsed)
```

clang writes bitcode with `-emit-llvm -c` (drop the `-S`); rustc with `--emit=llvm-bc`.

## Driving the two stages by hand

`reversible_compile(parsed)` is just `lower` followed by `bennett`. If you want the intermediate `LoweringResult` (to inspect gates, or to apply a non-default Bennett [strategy](../reference/autodocs.md)), call them directly. Neither is exported, so qualify with `Bennett.`:

```julia
lr = Bennett.lower(parsed)                       # ParsedIR -> LoweringResult
c  = Bennett.bennett(lr)                          # default construction
c2 = Bennett.bennett(lr; strategy=PebbledStrategy(8))   # space-bounded variant
```

`lower` lives in `src/lowering/driver.jl`; `bennett` and its six `BennettStrategy` subtypes (`DefaultStrategy`, `EagerStrategy`, `ValueEagerStrategy`, `CheckpointStrategy`, `PebbledStrategy`, `PebbledGroupStrategy`) live in `src/bennett_strategies.jl`.

## Limits

The IR-level pipeline is genuinely language-agnostic, but the *content* of the IR still has to be something Bennett can lower. Watch for:

- **Integer widths only, by default.** Parameters and return values must be `i8`/`i16`/`i32`/`i64` (signed or unsigned), `i1` (`Bool`), or a flat aggregate of those. A `Float32` surface is rejected.
- **Floating point is not free.** Only `fneg` is handled as a native LLVM opcode (it lowers to a sign-bit `xor`). A foreign module containing native `fadd`/`fsub`/`fmul`/`fdiv` on `double` hits `unsupported LLVM opcode`. Float64 works from *Julia* only because the `SoftFloat` overloads reroute those ops into `call soft_*` (handled as `IRCall`s to registered soft-float callees) before `code_llvm` ever emits a native float instruction. clang/rustc emit the native opcodes directly, so a hand-written float function from those front ends will not currently lower.
- **Pointers and memory need the C-track gate.** By default `ptr_cells=false`, and any pointer-typed `store`/`load`/`getelementptr`/return fails loud — this is intentional, to keep the circuit and `mem=:heap` models from silently aliasing a pointer surface. The `ptr_cells=true` gate (plus BennettVM as the backend) admits 64-bit pointer cells for the closed-world C track; see the architecture notes for that workstream.
- **`entry_function` must match the LLVM name exactly.** Name mangling (C++ without `extern "C"`, Rust without `#[no_mangle]`) changes the symbol. `grep '^define' your.ll` to see the real names before guessing.
- **Keep bodies branch-free where you can.** Overflow checks, bounds checks, and panics expand into extra control flow that the phi-resolution stage must lower as MUX trees. Wrapping arithmetic and `-O1`/`-O2` keep the IR small and predictable.

## See also

- [Tutorial](../tutorials/first_circuit.md) — the Julia-function path, end to end.
- [Reference](../reference/autodocs.md) — full `reversible_compile` kwarg table and metric signatures.
- [Architecture](../explanation/architecture.md) — the extract → lower → bennett → simulate pipeline.
- [README](../../../README.md) — opcode coverage matrix and project overview.
