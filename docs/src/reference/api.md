# API Reference

*Dry, exhaustive lookup for the public surface of `Bennett`: the
`reversible_compile` front door and its options, IR extraction, simulation,
circuit metrics, and combinators. For learning-by-doing start with the
[tutorial](../tutorials/first_circuit.md); for the design rationale see the
[explanation pages](../explanation/bennett_construction.md). Every code block below shows
output verified against the library on Julia 1.12.5.*

All names listed here are exported by `using Bennett` unless a row says
otherwise. Signatures and defaults are taken from the source files cited in
each section; paths are relative to the repository root.

---

## `reversible_compile`

The single entry point. It turns a plain Julia function (or a pre-extracted
`ParsedIR`, or a `.ll`/`.bc` module) into a [`ReversibleCircuit`](#circuit-types)
— or, with `target=:reversible_vm`, into a `BennettVM.VMProgram`.

### Overload families

There are four dispatch families plus a `CompileOptions` bundle form
(`src/Bennett.jl`, `src/softfloat_dispatch.jl`):

| Form | Signature | Notes |
|------|-----------|-------|
| Varargs forwarder | `reversible_compile(f, types::Type...; kw...)` | Packs `types` into `Tuple{types...}` and delegates to the Tuple overload. `reversible_compile(f, Int8, Int8)`. |
| Tuple overload | `reversible_compile(f, arg_types::Type{<:Tuple}; kw...)` | The full path: validates kwargs + arg types, runs the tabulate/QROM short-circuits, extracts IR, optionally narrows to `bit_width`, then delegates to the ParsedIR overload. Accepts **all 13** kwargs. |
| ParsedIR overload | `reversible_compile(parsed::ParsedIR; kw...)` | Compiles a pre-extracted `ParsedIR` (from the `.ll`/`.bc`/Julia-set extractors). Skips extraction; **rejects** `optimize`, `bit_width`, `strategy`. Intercepts `target=:reversible_vm` before the compile cache. |
| Float64 overload | `reversible_compile(f, ::Type{Float64}...; kw...)` | 1–3 `Float64` args only. Boxes each arg as the internal `SoftFloat` and routes through the soft-float library. `bit_width` is rejected; `strategy` is restricted to `:auto`/`:expression`. |
| Bundle | `reversible_compile(f, arg_types, opts::CompileOptions)` and `reversible_compile(parsed, opts)` and `reversible_compile(f, ::Type{Float64}..., opts)` | Unpacks `opts` into the kwarg form; raises `ArgumentError` if a field that is invalid on the chosen overload is set off its default. |

The varargs, Tuple, and Float64 paths all funnel into the ParsedIR overload,
which is the single point where the circuit-vs-VM fork happens.

```jldoctest; setup = :(using Bennett)
julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> simulate(c, Int8(5))
6

julia> gate_count(c)
(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)

julia> verify_reversibility(c)
true
```

### Keyword arguments

Thirteen kwargs, all sourced from [`CompileOptions`](#compileoptions). Defaults
come from `CompileOptions()` (`src/Bennett.jl`); accepted value sets are
validated in `src/lowering/driver.jl` and `src/lowering/arith.jl`.

| Kwarg | Type | Default | Accepted values | Meaning |
|-------|------|---------|-----------------|---------|
| `optimize` | `Bool` | `true` | — | Run Julia/LLVM optimization before IR extraction. `false` gives more predictable IR (see [LLVM IR caveat](#caveats)). |
| `max_loop_iterations` | `Int` | `0` | `≥ 0` | Loop-unroll bound. `0` lets the compiler infer a bound; a positive value caps it. |
| `compact_calls` | `Bool` | `false` | — | How registered-callee call sites are emitted. With the default `false`, each call site is emitted as one boxed gate group. |
| `bit_width` | `Int` | `0` | `0` or `1…64` | Narrow the IR to this width before lowering. `0` = infer from `arg_types`. **Tuple overload only.** |
| `add` | `Symbol` | `:auto` | `:auto`, `:ripple`, `:cuccaro`, `:qcla` | Adder strategy. `:auto` **always** resolves to `:ripple` (see note below). |
| `mul` | `Symbol` | `:auto` | `:auto`, `:shift_add`, `:qcla_tree` | Multiplier strategy. `:auto` = `:shift_add` at `target=:gate_count`, `:qcla_tree` at `target=:depth`. `:karatsuba` was removed and now throws. |
| `strategy` | `Symbol` | `:auto` | `:auto`, `:tabulate`, `:expression` (Tuple); `:auto`, `:expression` (Float64) | Compilation strategy. `:tabulate` evaluates `f` on all `2^W` inputs and emits a QROM lookup. **Rejected on the ParsedIR overload.** |
| `fold_constants` | `Bool` | `true` | — | Constant-fold during lowering. |
| `target` | `Symbol` | `:gate_count` | `:gate_count`, `:depth`, `:reversible_vm` | Optimization objective / backend. `:depth` minimizes Toffoli depth; `:reversible_vm` hands off to BennettVM. There is **no** `:circuit` value. |
| `auto_self_reversing` | `Bool` | `true` | — | Infer `self_reversing` and halve gate counts on end-to-end self-cleaning circuits. A kill-switch for benchmarking/regression bisects. |
| `mem` | `Symbol` | `:auto` | `:auto`, `:persistent`, `:heap` | Memory model. `:heap` is an extraction-phase flag (GC/heap-skeleton recogniser); `:persistent` routes dynamic-`n` allocas to the persistent-map dispatcher. |
| `persistent_impl` | `Symbol` | `:linear_scan` | `:linear_scan`, `:okasaki`, `:hamt`, `:cf` | Persistent-map implementation. Only used when `mem=:persistent`. `:linear_scan` is the measured winner at all scales. |
| `hashcons` | `Symbol` | `:none` | `:none` | Hash-consing strategy. Only `:none` is wired today; `:naive`/`:feistel` are follow-up work. |

**`add=:auto` always lowers to ripple-carry** (`src/lowering/arith.jl`,
`_pick_add_strategy`). The earlier "Cuccaro in-place when the second operand is
dead" heuristic was removed; `:auto` is kept pinned to `:ripple` so the
explicit-strategy gate-count baselines stay stable. Pass `add=:cuccaro` or
`add=:qcla` explicitly to opt into the other adders.

### Per-overload kwarg applicability

Different overloads accept different kwargs; a kwarg that is invalid on the
chosen overload raises a scoped `ArgumentError` (not a `MethodError`).

| Kwarg | Tuple | ParsedIR | Float64 |
|-------|:-----:|:--------:|:-------:|
| `optimize` | ✓ | ✗ | ✓ |
| `bit_width` | ✓ | ✗ | ✗ |
| `strategy` | ✓ (`:auto`/`:tabulate`/`:expression`) | ✗ | ✓ (`:auto`/`:expression`) |
| `max_loop_iterations`, `compact_calls`, `add`, `mul`, `fold_constants`, `target`, `auto_self_reversing`, `mem`, `persistent_impl`, `hashcons` | ✓ | ✓ | ✓ |

### Choosing a multiplier

The two real multipliers trade gate count against depth. For a 32×32 multiply:

```julia
c_shift = reversible_compile((x, y) -> x * y, Int32, Int32);             # mul=:auto = :shift_add
toffoli_depth(c_shift)                                                   # => 180

c_tree  = reversible_compile((x, y) -> x * y, Int32, Int32; mul=:qcla_tree);
toffoli_depth(c_tree)                                                    # => 56
```

`add=:qcla` also compiles and verifies on this function. A small polynomial
compiles to a few hundred gates:

```julia
f(x::Int8) = x*x + Int8(3)*x + Int8(1)
c = reversible_compile(f, Int8)
simulate(c, Int8(5))   # => 41
gate_count(c)          # => (total = 482, NOT = 14, CNOT = 300, Toffoli = 168)
verify_reversibility(c)  # => true
```

### The `:reversible_vm` target

`target=:reversible_vm` is shipped (`src/Bennett.jl`, `_REVERSIBLE_VM_BACKEND`).
Bennett.jl does **not** depend on BennettVM (that would be a dependency cycle);
instead BennettVM's `__init__` registers its `lower_vm` entry point at load
time. Until `using BennettVM` runs, a `:reversible_vm` compile raises an error
telling you to load the backend. Once loaded, the ParsedIR overload intercepts
the target before the compile cache and returns a `BennettVM.VMProgram` (not a
`ReversibleCircuit`). BennettVM lives in the sibling repo `../BennettVM.jl`.

### `CompileOptions`

```julia
Base.@kwdef struct CompileOptions
    optimize::Bool            = true
    max_loop_iterations::Int  = 0
    compact_calls::Bool       = false
    bit_width::Int            = 0
    add::Symbol               = :auto
    mul::Symbol               = :auto
    strategy::Symbol          = :auto
    fold_constants::Bool      = true
    target::Symbol            = :gate_count
    auto_self_reversing::Bool = true
    mem::Symbol               = :auto
    persistent_impl::Symbol   = :linear_scan
    hashcons::Symbol          = :none
end
```

Exported. The single source of truth for every `reversible_compile` default —
each overload's kwarg defaults read from `CompileOptions()`. Pass a bundle
instead of loose kwargs when you want to reuse a configuration:

```julia
opts = CompileOptions(add=:cuccaro, fold_constants=false)
c = reversible_compile(x -> x + Int8(1), Tuple{Int8}, opts)
```

The ParsedIR and Float64 bundle overloads raise `ArgumentError` if a
non-applicable field (`optimize`/`bit_width`/`strategy` for ParsedIR;
`bit_width` for Float64) is set off its default.

### Supported argument types

`reversible_compile` accepts (`_SUPPORTED_SCALAR_ARGS`, `src/Bennett.jl`):

- `Int8`, `Int16`, `Int32`, `Int64`
- `UInt8`, `UInt16`, `UInt32`, `UInt64`
- `Float64`
- `Bool`
- a flat concrete `NTuple{N,T}` whose element type is one of the above (the
  common sret aggregate-return pattern)

`Float32` is **rejected**. There are no native f32 arithmetic primitives; f32
in mixed-precision IR is routed `soft_fpext → f64-op → soft_fptrunc`, which
double-rounds and is not bit-exact against hardware. See the soft-float note in
`CLAUDE.md` §13.

> **`NTuple`-as-single-arg.** `NTuple{2,Int8}` *is* `Tuple{Int8,Int8}`, so
> `reversible_compile(f, NTuple{2,Int8})` is read as *two* `Int8` args. If your
> function takes a single tuple argument, wrap it as `Tuple{NTuple{2,Int8}}`;
> the compiler detects the mismatch and emits an actionable `ArgumentError`.

---

## IR extraction

These produce a `ParsedIR` (or a `Vector{Pair{Symbol,ParsedIR}}`) you can feed
to the ParsedIR overload of `reversible_compile`. Source: `src/extract/entry.jl`,
`src/extract/julia_set.jl`. The `preprocess` / `use_memory_ssa` / `passes` /
`ptr_cells` knobs live **here**, not on `reversible_compile`.

| Function | Signature | Returns |
|----------|-----------|---------|
| `extract_ir` | `extract_ir(f, arg_types; optimize=true)` | `String` (raw LLVM IR, for debugging) |
| `extract_parsed_ir` | `extract_parsed_ir(f, arg_types; optimize=true, preprocess=false, passes=String[], use_memory_ssa=false, mem=:auto, ptr_cells=false)` | `ParsedIR` |
| `extract_parsed_ir_from_ll` | `extract_parsed_ir_from_ll(path; entry_function, preprocess=false, passes=String[], use_memory_ssa=false, mem=:auto, ptr_cells=false)` | `ParsedIR` |
| `extract_parsed_ir_from_bc` | `extract_parsed_ir_from_bc(path; entry_function, preprocess=false, passes=String[], mem=:auto, ptr_cells=false)` | `ParsedIR` (no `use_memory_ssa`) |
| `extract_parsed_ir_set_from_ll` | `extract_parsed_ir_set_from_ll(path; preprocess=false, passes=String[], mem=:auto, ptr_cells=false)` | `Vector{Pair{Symbol,ParsedIR}}` (every defined function) |
| `extract_parsed_ir_set_from_julia` | `extract_parsed_ir_set_from_julia(f, argtypes; optimize=false, include_root=true, drop_throw_leaves=true, on_extract_error=:fail_loud, mem=:auto, ptr_cells=false)` | `Vector{Pair{Symbol,ParsedIR}}` (whole call graph) |

Extraction kwargs:

- **`preprocess=true`** runs `DEFAULT_PREPROCESSING_PASSES = ["sroa", "mem2reg",
  "simplifycfg", "instcombine"]` on the parsed module — primarily to eliminate
  `alloca`/`store` ahead of the IR walker.
- **`passes`** is an extra `Vector{String}` of LLVM New-Pass-Manager pipeline
  names (e.g. `["licm", "gvn"]`); when both are set, the default passes run
  first.
- **`use_memory_ssa=true`** captures LLVM MemorySSA annotations for store/load
  alias resolution. Available on the Julia-function and `.ll` paths (the `.bc`
  path does not round-trip to text).
- **`mem`** selects the memory-extraction arm (forwarded to the walker).
- **`ptr_cells=true`** models pointers (`Dict`/`Memory`) as opaque 64-bit VM
  cells: a `ptr` return derives `ret_width = 64`, `store ptr`/`load ptr` lower
  as 64-bit cells, and a two-index struct GEP lowers to `IRPtrOffset`. Default
  `false` keeps all the Julia-path fail-louds firing.

`extract_parsed_ir_from_ll`/`_from_bc` require an exact `entry_function` name —
compile C/Rust fixtures with `extern "C"` / `#[no_mangle]` for a stable symbol.
The `_set_*` producers walk every function and skip `declare`d bodies; they are
the multi-function input shape BennettVM consumes.

---

## Simulation

Bit-vector simulation with Bennett-invariant assertions. Source:
`src/simulator.jl`. `simulate` enforces, in order: loop convergence, then
ancilla-zero, then input-preservation — any violation `error()`s loudly.

| Function | Signature | Returns |
|----------|-----------|---------|
| `simulate` (scalar) | `simulate(c, input::Integer)` | `Integer` — requires a single-input circuit |
| `simulate` (tuple) | `simulate(c, inputs::Tuple{Vararg{Integer}})` | `Integer` for a single output, or a `Tuple` for multi-element (insertvalue) outputs |
| `simulate` (typed) | `simulate(c, ::Type{T}, input)` / `simulate(c, ::Type{T}, inputs::Tuple)` where `T<:Integer` | `T` — type-stable; rejects multi-element outputs and `T` too narrow for the output |
| `simulate!` | `simulate!(buffer::Vector{Bool}, c, inputs)` | mutates `buffer` (length must equal `n_wires`); saves the per-call `zeros()` allocation in sweeps |
| `diagnose_nonzero` | `diagnose_nonzero(c, inputs)` | `NamedTuple` — replays forward **without** throwing |

The untyped `simulate` infers output signedness with a heuristic (defaults to
signed; returns unsigned only when input and output widths align and all inputs
are `Unsigned`). For a guaranteed type, use the typed
`simulate(c, ::Type{T}, x)` overload.

`diagnose_nonzero` returns
`(ancilla_violations, input_violations, loop_violations, output, n_gates,
n_wires)`. `ancilla_violations::Vector{Tuple{Int,Int}}` records
`(wire, gate_idx_first_set)` by bisecting the originating gate — use it to
localise a broken ancilla without the assertion crashing your sweep.

---

## Circuit metrics

Resource counters and the correctness check. Source: `src/diagnostics.jl`. Gate
counts are regression baselines (`CLAUDE.md` §6).

| Function | Signature | Returns | Notes |
|----------|-----------|---------|-------|
| `gate_count` | `gate_count(c)` | **`NamedTuple`** `(total, NOT, CNOT, Toffoli)` | Per-type counts sum to `total`. Not an `Int`. |
| `ancilla_count` | `ancilla_count(c)` | `Int` | `length(c.ancilla_wires)`. |
| `constant_wire_count` | `constant_wire_count(c)` | `Int` | Wires targeted but never data-dependent (assumes the standard Bennett forward/copy/reverse layout). |
| `depth` | `depth(c)` | `Int` | Longest data-dependence chain over **all** gate types. |
| `t_count` | `t_count(c)` | `Int` | `7 × Toffoli` (NOT/CNOT are Clifford, 0 T). |
| `toffoli_depth` | `toffoli_depth(c)` | `Int` | Longest chain of Toffoli gates along a data path. |
| `t_depth` | `t_depth(c; decomp=:ammr)` | `Int` | `toffoli_depth(c) × k`: `:ammr` ⇒ k=1 (Amy–Maslov–Mosca–Roetteler 2013, default), `:nc_7t` ⇒ k=3 (Nielsen–Chuang). Unknown `decomp` throws. |
| `peak_live_wires` | `peak_live_wires(c)` | `Int` | Max simultaneously non-zero wires from an all-zero start; an input-independent space metric. |
| `verify_reversibility` | `verify_reversibility(c; n_tests=100)` | `true` or raises | For `n_tests` random inputs asserts ancilla-zero, input-preservation, and forward+reverse restoration. |
| `print_circuit` | `print_circuit([io,] c)` | prints summary | Also drives `Base.show(::MIME"text/plain", ::ReversibleCircuit)`. |

`gate_count` returns a `NamedTuple` — destructure or index it:

```julia
c = reversible_compile(x -> x + Int8(1), Int8)
gc = gate_count(c)
gc.total      # => 58
gc.Toffoli    # => 12
ancilla_count(c)        # => 25
t_count(c)              # => 84   (= 7 × 12)
toffoli_depth(c)        # => 12
depth(c)                # => 19
verify_reversibility(c) # => true
```

---

## Circuit combinators

Source: `src/controlled.jl`, `src/compose.jl`.

### `controlled`

```julia
controlled(c::ReversibleCircuit) -> ControlledCircuit
```

Lifts a circuit to take an explicit control bit. Evaluate with
`simulate(cc, ctrl::Bool, input)`. When `ctrl` is false the output register
stays **zero** (it does not pass the input through):

```julia
cc = controlled(reversible_compile(x -> x + Int8(1), Int8))
simulate(cc, true,  Int8(42))  # => 43
simulate(cc, false, Int8(42))  # => 0   (off-branch output stays 0)
```

### `compose`

```julia
compose(c1::ReversibleCircuit, c2::ReversibleCircuit) -> ReversibleCircuit
```

Pipeline composition:
`simulate(compose(c1, c2), x) == simulate(c2, simulate(c1, x))`. `c2`'s inputs
are positionally aliased onto `c1`'s outputs, so
`c1.output_elem_widths == c2.input_widths` is required. The result appends
`reverse(c1.gates)` to uncompute the intermediate value. Self-reversing inputs
(Sun–Borissov multiply, QROM tabulate) are rejected loudly.

```jldoctest; setup = :(using Bennett)
julia> c1 = reversible_compile(x -> x + Int8(1), Int8);

julia> c2 = reversible_compile(x -> x + Int8(2), Int8);

julia> c12 = compose(c1, c2);

julia> simulate(c12, Int8(5))
8

julia> verify_reversibility(c12)
true
```

---

## Callee registry

```julia
register_callee!(f::Function) -> Nothing
```

Source: `src/extract/callees.jl`. Records `string(nameof(f))` in the callee
registry; at lowering, an LLVM `call` whose mangled name (`julia_<name>_NNN` /
`j_<name>_NNN`) matches a registered name is inlined gate-for-gate. Over 100
built-in callees (soft-float primitives, integer division, MUX load/store, the
four persistent-map impls) are auto-registered on module load via
`src/callees.jl`.

After registering a callee that may already be baked into a cached circuit,
call `Bennett._clear_compile_cache!()` to invalidate stale entries.

---

## QROM / tabulate

`strategy=:tabulate` (and the `:auto` cost model, when a function is cheap to
enumerate) evaluates `f` on all `2^W` inputs and emits the result as a QROM
lookup — a binary decision tree of Toffolis (Babbush–Gidney 2018). The cost is
`2(L-1)` Toffoli + `O(L·W)` CNOT, with a T-count of `4(L-1)` that is
**independent of the value width**. A 2-bit S-box table is a tiny circuit:

```julia
sbox(x::UInt8) = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))[(x & UInt8(0x3)) + 1]
gate_count(reversible_compile(sbox, UInt8))
# => (total = 114, NOT = 10, CNOT = 96, Toffoli = 8)
```

---

## Circuit types

Exported types referenced above: `ReversibleCircuit`, `ControlledCircuit`,
`ParsedIR`, `LoweringResult`, and the gate primitives `NOTGate`, `CNOTGate`,
`ToffoliGate`, `ReversibleGate`. `ReversibleCircuit` implements the `Base`
collection protocol (`length`, `iterate`, `getindex`) over its gate list, so
`for g in circuit` and `circuit[i]` work directly.

A returned `ReversibleCircuit` is cached and shared by identity — treat it as
**immutable**. Mutating `.gates` or `.input_wires` corrupts every future compile
that hits the same cache key.

---

## Internals (not exported)

These are reachable as `Bennett.<name>` but are deliberately not exported,
because the supported workflow is `reversible_compile`:

- **`Bennett.lower(parsed; ...)`** — `ParsedIR → LoweringResult`. Lives in
  `src/lowering/driver.jl` (`src/lower.jl` is an 18-line include shim over
  `src/lowering/*.jl`).
- **`Bennett.bennett(lr; strategy=DefaultStrategy())`** — applies Bennett's 1973
  construction (forward + CNOT-copy + reverse). The six strategy subtypes are
  exported: `DefaultStrategy`, `EagerStrategy`, `ValueEagerStrategy`,
  `CheckpointStrategy`, `PebbledStrategy(max_pebbles)`,
  `PebbledGroupStrategy(max_pebbles)`. Five legacy alias functions are also
  exported (`eager_bennett`, `value_eager_bennett`, `checkpoint_bennett`,
  `pebbled_bennett`, `pebbled_group_bennett`).
- **`Bennett.SoftFloat`** — the internal `UInt64` bit-pattern wrapper used only
  inside the Float64 `reversible_compile` overload. Not a user type. The
  soft-float primitives themselves (`soft_fadd`, `soft_exp`, …) live in the
  `SoftFloatLib` submodule; the bit-exact ones (`+`, `-`, `*`, `/`, `fma`,
  `sqrt`, comparisons, conversions, rounding) are exact against Julia native,
  while transcendentals are within ≤2 ulp.

<a id="caveats"></a>
> **LLVM IR is not a stable API.** Use `optimize=false` when you want
> predictable IR for testing or for inspecting a single instruction's lowering.
> The C-API walker in `src/extract/` is the source of truth — the project does
> not regex-parse IR.

---

## See also

- [Tutorial](../tutorials/first_circuit.md) — compile your first circuit step by step.
- [How-to: arithmetic strategy](../howto/arithmetic_strategy.md) — choosing
  adders and multipliers; see also [reversible memory](../howto/reversible_memory.md).
- [Architecture](../explanation/architecture.md) and the
  [Bennett construction explainer](../explanation/bennett_construction.md) —
  how the extract → lower → bennett pipeline fits together.
- Bennett, C. H. (1973). *Logical Reversibility of Computation.* IBM J. Res.
  Dev. 17(6), 525–532. [doi:10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525).
- Project rules and invariants: [`README.md`](../../../README.md),
  `CLAUDE.md`.
