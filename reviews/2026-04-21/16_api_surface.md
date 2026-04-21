# Bennett.jl — Public API Surface Review

**Reviewer**: API design / stability contract
**Date**: 2026-04-21
**Scope**: exported names, signatures, kwargs, error contract, return shapes, stability, documentation presence
**Posture**: independent, skeptical, harsh

---

## 1. Public API surface enumeration

Taken directly from `src/Bennett.jl` lines 36–48. **71 names exported.** Docstring presence probed via `Base.Docs.Binding` at the module. Test-direct coverage grep over `test/`. "Stability risk" is my subjective forecast of future churn based on code surface and coupling.

| # | Export | Kind | Doc? | Tested directly? | Stability risk | Notes |
|--:|---|---|---|---|---|---|
| 1 | `reversible_compile` | function (3 methods) | **yes** | heavily | HIGH | 3 overloads (varargs / `Type{<:Tuple}` / `Type{Float64}...`), kwarg sets differ; see §3. |
| 2 | `simulate` | function (4 methods) | **NO** | heavily | HIGH | silently accepts wrong-arity tuple — bug §9. |
| 3 | `extract_ir` | function | yes | rare (debug) | MEDIUM | returns `String`; docstring says "kept for debugging/printing". If it's really debug, *why exported?* |
| 4 | `parse_ir` | function | **NO** | `test_parse.jl` only | HIGH (legacy) | regex parser, marked "legacy" in `CLAUDE.md`. Shouldn't be exported. |
| 5 | `extract_parsed_ir` | function | yes | many | MEDIUM | heavy kwargs: `optimize`, `preprocess`, `passes`, `use_memory_ssa`. Only `optimize` is documented on `reversible_compile`. |
| 6 | `extract_parsed_ir_from_ll` | function | yes | 4 tests | MEDIUM | P5 additions; returns `ParsedIR` but `ParsedIR` is *not exported*. |
| 7 | `extract_parsed_ir_from_bc` | function | yes | 3 tests | MEDIUM | same. |
| 8 | `register_callee!` | function | yes | indirect | HIGH | module-global mutable state. §19. |
| 9 | `PersistentMapImpl` | type | yes | tests | HIGH | persistent-DS research surface bleeding through. §2. |
| 10 | `AbstractPersistentMap` | abstract type | yes | tests | HIGH | ditto. |
| 11 | `verify_pmap_correctness` | function | yes | tests | MEDIUM | internal harness. |
| 12 | `pmap_demo_oracle` | function | yes | tests | MEDIUM | literally has "demo" in the name — shouldn't be exported. |
| 13 | `LINEAR_SCAN_IMPL` | const | **NO** | tests | HIGH | singleton impl marker. |
| 14 | `OKASAKI_IMPL` | const | yes | tests | HIGH | same. |
| 15 | `okasaki_pmap_new` / `_set` / `_get` | functions | yes | tests | HIGH | three public ops for one internal impl. |
| 16 | `OkasakiState` | type | yes | tests | HIGH | internal data structure exposed. |
| 17 | `cf_pmap_new` / `_set` / `_get` | functions | yes | tests | HIGH | same pattern for CF impl. |
| 18 | `cf_reroot` | function | yes | tests | HIGH | impl-specific. |
| 19 | `CF_IMPL` | const | **NO** | tests | HIGH | |
| 20 | `HAMT_IMPL` | const | yes | tests | HIGH | |
| 21 | `hamt_pmap_new` / `_set` / `_get` | functions | **NO** | tests | HIGH | |
| 22 | `soft_popcount32` | function | **NO** | tests | MEDIUM | helper exposed without docstring. |
| 23 | `soft_jenkins96` / `_int8` | functions | yes | tests | MEDIUM | hash primitives — research infrastructure. |
| 24 | `soft_feistel32` / `_int8` | functions | yes | tests | MEDIUM | same. |
| 25 | `soft_fadd` … `soft_exp2_julia` | 21 soft-float functions | yes (all) | heavy | MEDIUM | impl primitives; why all exported? |
| 26 | `ReversibleCircuit` | struct | yes | always | MEDIUM | concrete struct with 7 public fields — §5. |
| 27 | `ControlledCircuit` | struct | **NO** | tests | MEDIUM | undocumented exported type. |
| 28 | `controlled` | function | yes | tests | LOW | |
| 29 | `gate_count` | function | **NO** | always | MEDIUM | returns anonymous `NamedTuple` §11. |
| 30 | `ancilla_count` | function | **NO** | always | LOW | |
| 31 | `constant_wire_count` | function | yes | tests | LOW | |
| 32 | `depth` | function | **NO** | tests | MEDIUM | collides with `LinearAlgebra` / generic `depth` semantically. |
| 33 | `t_count` | function | yes | tests | LOW | |
| 34 | `t_depth` | function | yes | tests | MEDIUM | kwargs `decomp` not listed in README example. |
| 35 | `toffoli_depth` | function | yes | tests | LOW | |
| 36 | `peak_live_wires` | function | yes | tests | LOW | |
| 37 | `print_circuit` | function | **NO** | few | LOW | overlaps with `Base.show(::MIME"text/plain")`. |
| 38 | `verify_reversibility` | function | **NO** | always | MEDIUM | returns `true` on success, `error(...)` on failure — asymmetric contract. |
| 39 | `pebbled_bennett` | function | yes | tests | MEDIUM | |
| 40 | `eager_bennett` | function | yes | tests | MEDIUM | |
| 41 | `value_eager_bennett` | function | yes | tests | MEDIUM | |
| 42 | `pebbled_group_bennett` | function | yes | tests | MEDIUM | several fall-back paths silently return `bennett(lr)`. |
| 43 | `checkpoint_bennett` | function | yes | tests | MEDIUM | |

### NOT exported but referenced publicly in docs/README

- `ParsedIR` — returned from `extract_parsed_ir*`, constructor used in `_narrow_ir`; used in docs as `parsed.memssa`, but **type itself isn't exported**. Users writing `::ParsedIR` annotations must type `Bennett.ParsedIR`. Leak.
- `LoweringResult` — returned from `lower`, argument to `bennett`, in `docs/src/api.md`. Not exported. Users writing `bennett(lower(parsed))` use opaque values — but `docs/src/tutorial.md` calls `Bennett.extract_parsed_ir(...)` and `Bennett.lower(...)` with the module prefix, making this visible.
- `lower` — not exported, but used in tutorial examples (prefixed).
- `bennett` — not exported, but *exposed* via `docs/src/api.md` heading "### `bennett(lr::LoweringResult)`". Docs lie about its exposure.
- `lower_add!`, `lower_add_cuccaro!`, `lower_add_qcla!`, `lower_mul!`, `lower_mul_karatsuba!`, `lower_mul_qcla_tree!` — documented in `api.md` ("Arithmetic primitive functions") but **not exported**. Doc lies.
- `WireIndex` — alias for `Int`; not exported but used in documented struct field types.
- `ReversibleGate` — abstract parent type of gates; not exported. Any user writing `::Vector{ReversibleGate}` needs the prefix. But `gate_count` etc. use this type.
- `NOTGate`, `CNOTGate`, `ToffoliGate` — docs/src/api.md says "### `NOTGate(target::Int)`" etc., but **they are not exported**. A user following the docs will get `UndefVarError`. **Documentation bug.**

I tried: `julia --project=. -e 'using Bennett; NOTGate(1)'` → fails. Confirmed.

---

## 2. Internal accidentally-public (exports that should be internal)

**Count: ~35 of the 71 exports should be internal.**

The persistent-DS experimental surface is utterly leaked:

- `AbstractPersistentMap`, `PersistentMapImpl`, the 4 `*_IMPL` sentinels, the 12 `*_pmap_*` functions, `OkasakiState`, `cf_reroot`, `verify_pmap_correctness`, `pmap_demo_oracle`, `soft_popcount32`, `soft_jenkins*`, `soft_feistel*` — this is 25+ exports of **research scaffolding** for the T5 epic, a feature the README describes as "in progress" and whose WORKLOG says was found not to beat linear_scan.

These should live under `Bennett.Persistent` as a sub-module (or stay un-exported and accessed via `Bennett.okasaki_pmap_set(...)` in tests). Dumping them into the top-level namespace means every downstream package's `names(Bennett)` list is polluted, and *any* rename or signature change to `cf_reroot` is a semver-breaking change.

The soft-float internals are similar: `soft_fadd` .. `soft_exp2_julia` (21 functions) are implementation details of Float64 support. They're useful to test directly, but they don't need to be public. Exporting them commits Bennett.jl to stable ABIs for `soft_fptrunc(UInt64) -> UInt64` forever, even though the *intended* Float64 story is `reversible_compile(f, Float64)`.

No sub-module exports found — the entire surface lives in the flat `Bennett` module.

---

## 3. Keyword argument design — `reversible_compile`

Documented kwargs (README / api.md) vs. actual signatures:

### `reversible_compile(f, arg_types::Type{<:Tuple}; …)` (src/Bennett.jl:58)

```
optimize::Bool = true
max_loop_iterations::Int = 0
compact_calls::Bool = false
bit_width::Int = 0
add::Symbol = :auto
mul::Symbol = :auto
strategy::Symbol = :auto
```

### `reversible_compile(parsed::ParsedIR; …)` (src/Bennett.jl:105)

```
max_loop_iterations::Int = 0
compact_calls::Bool = false
add::Symbol = :auto
mul::Symbol = :auto
```

(No `optimize`, no `bit_width`, no `strategy` — *silently different kwarg surface*.)

### `reversible_compile(f, float_types::Type{Float64}...; …)` (src/Bennett.jl:268)

```
optimize::Bool = true
max_loop_iterations::Int = 0
compact_calls::Bool = false
strategy::Symbol = :auto
```

(No `bit_width`, no `add`, no `mul`.)

### Findings

- **CRITICAL — divergent kwarg surfaces.** Three `reversible_compile` overloads accept three different kwarg sets. Passing `add=:qcla` to the `Float64` path gives a `MethodError`. Passing `bit_width=32` to the `Float64` path gives a `MethodError`. But from the user's POV, all three are spelled `reversible_compile(f, T)`. See probe §12 — `reversible_compile(x -> x, Float64; bit_width=32)` dies on MethodError. **Fix: push all three through one implementation with consistent kwarg names, reject unsupported ones explicitly with a sane message, or split the API into `reversible_compile_int` vs `reversible_compile_float`.**

- **HIGH — `extract_parsed_ir` kwargs are undocumented at the `reversible_compile` entry point.** `extract_parsed_ir` accepts `preprocess::Bool`, `passes::Vector{String}`, `use_memory_ssa::Bool`. None of these are reachable from `reversible_compile`. If a user wants SROA+memssa ingest, they must drop to `extract_parsed_ir` + `lower` + `bennett` manually — violating the "one call compiles it" framing.

- **HIGH — `lower` has 7 kwargs; only 4 are exposed through `reversible_compile`.** `lower` accepts `use_inplace::Bool=true`, `use_karatsuba::Bool=false`, `fold_constants::Bool=false` — all unreachable from the public entry. `use_inplace` flipping to `false` changes liveness analysis; `use_karatsuba=true` is *legacy* (superseded by `mul=:karatsuba`). Dead kwargs that nobody can reach means they can't rot-detect. Dead code, not API.

- **MEDIUM — strategy-set validation.** `reversible_compile` checks `strategy in (:auto, :tabulate, :expression)` → good. `lower` checks `add ∈ (…)`, `mul ∈ (…)` → good. But **`bit_width`, `max_loop_iterations` are not validated.** Probe §14 shows `bit_width=-5` is silently accepted and produces a 26-wire circuit that returns `1` on input `0`. **Violates the "FAIL FAST, FAIL LOUD" principle in `CLAUDE.md`.** The `_narrow_ir(parsed, -5)` code path is undefined-behaviour input.

- **MEDIUM — `strategy=:tabulate` error is cute but surprising.** "strategy=:tabulate not supported for Float64 (2^64 table would be absurd)" — good message. But `strategy=:expression` is listed as supported for Float64 even though there's no difference from `:auto` there (only tabulate is branched). Either remove the `:expression` knob from the Float64 path, or document it does nothing.

- **MEDIUM — `compact_calls::Bool`** is a flat bool on a non-orthogonal dimension. When off, the compiler inlines callees as gate sequences that share the outer wire budget. When on, each callee becomes its own Bennett-wrapped block. This is a lowering-strategy choice, not a boolean tag. It belongs in a `CompileConfig` struct or under an `inline_strategy::Symbol` enum like `:inline | :compact`.

- **LOW — orthogonal kwargs → should be a struct.** 7 kwargs on a first-argument dispatch is right at the limit of reasonable. Propose a `CompileOptions` struct for kwargs that mostly stay at their defaults:

  ```julia
  struct CompileOptions
      optimize::Bool
      max_loop_iterations::Int
      compact_calls::Bool
      bit_width::Int
      add::Symbol
      mul::Symbol
      strategy::Symbol
      preprocess::Bool       # from extract_parsed_ir
      passes::Vector{String}
      use_memory_ssa::Bool
      decomp::Symbol         # Toffoli→T decomp for t_depth
  end
  ```

  Then `reversible_compile(f, T; opts=CompileOptions())`. Adding a new knob becomes a struct-field add, not a public signature change.

---

## 4. Function signature stability

`reversible_compile` history according to PRDs and `src/Bennett.jl`:

- v0.1: `reversible_compile(f, T)` — single type, `Int8` only.
- v0.2: LLVM.jl backend; same outward signature.
- v0.3–v0.4: kwargs `optimize`, `max_loop_iterations` added (non-breaking). Varargs overload `reversible_compile(f, T1, T2, ...)` added.
- v0.5 (P5): `reversible_compile(parsed::ParsedIR; ...)` overload added (src/Bennett.jl:105).
- Post-P5: `add`, `mul`, `bit_width`, `strategy`, `compact_calls` kwargs added.

No migration notes anywhere in-tree. The version in `Project.toml` has been `0.4.0` since the initial import commit (`bf432fa Initial import`). **`Project.toml` version has not tracked any of these API additions.** That's not a lie-by-omission, it's a lie of commission: the package declares v0.4.0 while claiming to implement v0.5 PRD features.

---

## 5. Type aliases / exported types

### Exported type surface

- `ReversibleCircuit` — concrete struct with 7 public fields. **Public field access is load-bearing**: `c.gates`, `c.n_wires`, `c.input_wires`, `c.output_wires`, `c.ancilla_wires`, `c.input_widths`, `c.output_elem_widths`. Every field is an ABI commitment. Adding an 8th field is non-breaking; renaming one is breaking. Given the construct's centrality, OK — but no semver contract is actually documented.

- `ControlledCircuit` — concrete struct, 2 fields: `circuit::ReversibleCircuit`, `ctrl_wire::WireIndex`. No docstring, no `Base.show` method (unlike `ReversibleCircuit`). Users who `print(cc)` get the raw default struct dump.

- `NOTGate`, `CNOTGate`, `ToffoliGate`, `ReversibleGate` — **NOT exported**. But `docs/src/api.md` §"Gate Types" documents them as public. Any user following the docs tries `using Bennett; NOTGate(1)` → `UndefVarError`. **Doc bug confirmed by probe.**

- `ParsedIR`, `LoweringResult` — **NOT exported** but are return types of exported functions. A user storing them must write `Bennett.ParsedIR`. `LoweringResult` has a documented mutable `self_reversing` field in api.md, but the type itself is inaccessible without the prefix.

### Internal leakage through exported types

- `ReversibleCircuit.gates::Vector{ReversibleGate}` — field type is *not exported*. Users writing `Vector{ReversibleGate}` need `Bennett.ReversibleGate`. Fix: export `ReversibleGate`, `NOTGate`, `CNOTGate`, `ToffoliGate`, `ParsedIR`, `LoweringResult`. They're already documented as public.

- `OkasakiState` (export) — exposes an implementation's entire internal rep.

- `PersistentMapImpl` — an abstract marker type; implementations are singletons. The "API" here is a confused mix of traits and values. See §2 for the recommendation to wall this off.

### ABI stability

No explicit "@experimental" or "@unstable" markers. No SemVer-level communication of which exports are frozen. **Everything defaults to "stable if users start depending on it"**, which is the worst possible position for a research compiler.

---

## 6. Naming conventions

Julia convention: `foo!` for mutating functions that modify a first argument; pure functions no bang.

### Violations / ambiguities

- `register_callee!(f)` — **has `!` but doesn't mutate an argument**; it mutates a module-global `_known_callees::Dict`. The `!` suffix by convention means "mutates *the first argument*". More Julian would be `register_callee(f)` (no bang) with a doc-comment that warns about global state, OR the function should take the registry explicitly: `register_callee!(registry, f)`. **Current spelling is misleading Julia convention.**

- `*_pmap_set` / `*_pmap_new` — named like C APIs. Julian would be `PMap(...)` constructor + `setindex!` method, i.e. conform to `AbstractDict` protocol (which `AbstractPersistentMap` could subtype). The current split of `pmap_set` across 3 different namespaces (`okasaki_pmap_set`, `cf_pmap_set`, `hamt_pmap_set`) is an anti-pattern: each implementation should dispatch on the instance type, not on the function name.

- `checkpoint_bennett`, `pebbled_bennett`, `eager_bennett`, `value_eager_bennett`, `pebbled_group_bennett` — 5 variants of `bennett` all with different prefixes, none exported as methods of a common function. They should dispatch on a strategy tag: `bennett(lr; strategy=:checkpoint)`. Current 5-name approach gives users 5 top-level names that are really one function with a selector.

- `lower_add!`, `lower_mul!`, `lower_add_cuccaro!` etc. are gate-appending mutation helpers — their bang is correct and first-arg is mutated. But **they're not exported**, even though `docs/src/api.md` §"Arithmetic primitive functions" documents them as public. Doc lies again.

- `extract_ir` vs `extract_parsed_ir` vs `extract_parsed_ir_from_ll` vs `extract_parsed_ir_from_bc` — 4 flavors. `extract_ir` returns a `String`. `extract_parsed_ir` returns `ParsedIR`. The `_from_ll` / `_from_bc` pair differ only in input format. Naming is OK but the surface is sprawling.

- `simulate` vs `verify_reversibility` vs `_simulate` — bonus internal `_simulate` (simulator.jl:14) is private but its behavior (ancilla-zero assertion) is observably different from the public `simulate(c, input)` in that it raises on ancilla non-zero. Arguably should be `simulate_safe` vs `simulate_unchecked` or gated by a kwarg.

- `print_circuit` — overlaps completely with `Base.show(io, ::MIME"text/plain", ::ReversibleCircuit)` (src/diagnostics.jl:37). Two ways to print the same thing. Delete `print_circuit`; document `show`.

- `depth` — name collision risk. Julia's `LinearAlgebra`/`DataStructures` might introduce a `depth`. And the name is semantic-overloaded: "depth" in circuit theory is Toffoli-depth vs gate-depth vs T-depth. Consider `gate_depth` for clarity. Keep the export but rename.

---

## 7. Return value consistency

### `gate_count`
Returns `NamedTuple{(:total, :NOT, :CNOT, :Toffoli), NTuple{4, Int}}`. Field access via dot is nice. **Not documented as a NamedTuple** in the docstring (there isn't one); the api.md example shows dot access but doesn't state the type. Stable.

### `simulate`
- Single output: returns `Int8`, `Int16`, `Int32`, `Int64` for widths 8/16/32/64; else `Int`. **Always `Int*`, never `UInt*`**. Probe §: `reversible_compile(x -> x + UInt8(3), UInt8)` → `simulate` returns `Int8`. **This is wrong.** A user inputs `UInt8`, expects `UInt8` out. Sign lost.
- Multi-output (tuple/insertvalue): returns `Tuple{Int64, Int64, ...}` regardless of per-element width. `(Int8(1), Int8(2))` input to a `(a,b) -> (b,a)` circuit returns `(2, 1)::Tuple{Int64,Int64}`. **Width information discarded.**

Both return-type bugs live in `_read_int` (src/simulator.jl:57–68). The `_read_output` helper acknowledges "return type is inherently unstable" (a code comment in simulator.jl:41), but that doesn't excuse losing the sign/width distinction. **At minimum: use `reinterpret(UInt8, …)` for unsigned inputs if the original type is preserved.** But currently no type info about signedness is retained from the input types, because the compile pipeline reduces everything to a width. This is a deeper deficiency: `ReversibleCircuit` should remember the original `Type` per input and output slot, not just width.

### `verify_reversibility`
Returns `true` on success, **raises `error(...)` on failure** (diagnostics.jl:158). Asymmetric. A caller can never get `false`. So `if verify_reversibility(c) …` is a tautology.  The honest signature is `verify_reversibility(c)::Nothing` and raise on failure, or `verify_reversibility(c)::Bool` and return `false` on mismatch. Currently it's both — confusing.

### `depth`, `t_count`, `toffoli_depth`, `peak_live_wires`, `ancilla_count`, `constant_wire_count`
All return `Int`. Consistent. LOW risk.

---

## 8. Error contract

Mix of `error()` (→ `ErrorException`) and `MethodError`:

| Site | Raises |
|---|---|
| unknown `strategy` | `ErrorException` (nice message) |
| unknown `add` / `mul` | `ErrorException` via `lower`, deep in the pipeline |
| unknown `decomp` to `t_depth` | `ErrorException` |
| `bit_width = -5` | **nothing** — silent acceptance |
| `bit_width = 200` on Int8 | **nothing** — silent acceptance |
| `String` argument type | `ErrorException` from `ir_extract.jl` after IR walk |
| `Float64` + `bit_width=…` | `MethodError` — a stack dump |
| `Float64` + `add=:qcla` | `MethodError` — stack dump |
| `Float32` input | `ErrorException` "unsupported LLVM opcode" — wrong frame |
| single-arg circuit, 2-tuple `simulate` | **none** — returns a nonsense value |
| single-arg circuit, single-int `simulate` | passes |
| 2-arg circuit, single-int `simulate` | `ErrorException` (fine) |

**Inconsistency**: the kwarg-set mismatch between Int and Float64 paths surfaces as `MethodError` — a raw Julia reflection error — rather than a user-facing "this kwarg is for integer compilation only". Users will frequently hit this.

**Silent bugs**: `bit_width=-5`, oversized `bit_width`, mismatched `simulate` tuple arity all accept bad input without comment. Violates `CLAUDE.md` principle 1 (FAIL FAST, FAIL LOUD).

---

## 9. Error messages — user-facing quality

From probes:

| Input | Message | Verdict |
|---|---|---|
| `strategy=:nonsense` | `reversible_compile: unknown strategy :nonsense; supported: :auto, :tabulate, :expression` | **good** |
| `add=:fancy` | `lower: unknown add strategy :fancy; supported: :auto, :ripple, :cuccaro, :qcla` | frame is `lower:`, not `reversible_compile:` — minor leak |
| `String` | `ir_extract.jl: unsupported LLVM type for width query: LLVM.PointerType(ptr)` | **bad**: user doesn't know what `LLVM.PointerType(ptr)` means or why a `String` produces it |
| `Vector{Int8}` | `Loop detected in LLVM IR but max_loop_iterations not specified.` | **misleading**: the real issue is that `Vector` isn't supported, not that a loop is present |
| kwarg typo `optmize` | Julia's own MethodError — OK, legible |
| `Float64; bit_width=32` | MethodError listing 3 method candidates | legible but weird — user sees `Float64` and `Int`-Tuple signatures both, has to figure out which they wanted |
| `Float32` | `ir_extract.jl: fadd in @julia_#23_11778:%top: %0 = fadd float %"x::Float32" — unsupported LLVM opcode` | **bad**: root cause is "Float32 isn't supported", not an LLVM opcode issue |
| `simulate(c_single, (x,y))` | **no error, returns garbage** | **CRITICAL** |
| `register_callee!(non_function)` | accepts any Function, no validation — fine |

### Recommendation (HIGH)

Add an early type-table at `reversible_compile` entry:

```julia
_SUPPORTED_SCALAR_TYPES = (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float64)
function _validate_arg_types(arg_types)
    for (i, T) in enumerate(arg_types.parameters)
        T <: Tuple && continue  # handled separately
        T in _SUPPORTED_SCALAR_TYPES || throw(ArgumentError(
            "reversible_compile: argument $i has type $T; supported: $(_SUPPORTED_SCALAR_TYPES)"))
    end
end
```

Fail at entry with a type-level message, not 200 lines deep in `ir_extract.jl`.

---

## 10. Overloads / dispatch

3 overloads of `reversible_compile`:

```
reversible_compile(f, types::Type...; kw...)                    # varargs
  └→ reversible_compile(f, Tuple{types...}; kw...)
reversible_compile(f, arg_types::Type{<:Tuple}; kw...)          # tuple
reversible_compile(parsed::ParsedIR; kw...)                     # from-IR
reversible_compile(f::F, float_types::Type{Float64}...; kw...)  # Float64 varargs (added later)
```

- **MEDIUM — Float64 varargs vs Int varargs shadowing.** `reversible_compile(f, Float64)` hits the Float64 method (more specific). `reversible_compile(f, Int8)` hits the tuple method via `Tuple{types...}`. But what about `reversible_compile(f, Float64, Float64, Int8)` — a mix? Answer: no dispatch matches because `Type{Float64}...` demands all-Float64. **Graceful fallback missing.** Currently the user gets a MethodError. At minimum this case should be explicitly rejected with a "mixed-type compile not supported" message.

- **MEDIUM — ParsedIR overload kwarg surface silently smaller.** The `ParsedIR` entry drops `optimize`, `bit_width`, `strategy`. If a user migrates from `reversible_compile(f, T; bit_width=32)` to `reversible_compile(parsed; bit_width=32)` (because they want to cache `parsed`), they get a MethodError. **Add a wrapper that translates or explicitly rejects.**

- **MEDIUM — varargs call pattern `reversible_compile(f, T1, T2, ...)` splats into `Tuple{T1, T2, ...}`.** That's fine, but `reversible_compile(f)` (no types) falls into the `Float64` varargs method (because `float_types::Type{Float64}...` accepts empty), which then errors with `"Need at least one Float64 argument type"` — probe §2. **Misleading error** for users who forgot the type argument and never intended Float64.

- **LOW — `f::F where F`** (Float64 path only) vs unspecialized `f` (integer path). Specialization asymmetry. Doesn't affect correctness but causes inconsistent compile-time cost.

---

## 11. Public diagnostics API

All 10 diagnostics exported. `gate_count` returns `NamedTuple`; others return `Int`. **Shape OK.**

But:

- `gate_count(c).total` is redundant with `length(c.gates)`; exposing both invites drift.
- `depth(c)` and `toffoli_depth(c)` use different algorithms (per-wire max vs. Toffoli-filter max) — neither caches. For large circuits this is O(n_wires + n_gates) per call; calling all diagnostics on a 1M-gate circuit will repeat the scan 5 times.
- `t_depth(c; decomp=:ammr)` and `t_count(c)` are not aligned: `t_count = 7 * Toffoli_count` (hard-coded 7, ignoring decomp), while `t_depth` accepts `decomp=:ammr|:nc_7t`. Inconsistent — the ratio of T-count to T-depth is decomposition-dependent. User computes `t_count/t_depth` expecting a well-defined ratio and gets garbage.

---

## 12. Public simulation API

- `simulate(c, x::Integer)` — single input.
- `simulate(c, xs::Tuple{Vararg{Integer}})` — multiple.
- `simulate(cc, ctrl::Bool, x::Integer)` — controlled single.
- `simulate(cc, ctrl::Bool, xs::Tuple{Vararg{Integer}})` — controlled tuple.

### Gaps

- **CRITICAL — silent wrong-arity** (probe §7): single-input circuit + `(Int8(1), Int8(2))` tuple → no error, reads the first element of the tuple as the input, returns garbage. The single-element check at simulator.jl:6 doesn't apply because the dispatch landed on the tuple overload which never checks arity. **Fix: check `length(inputs) == length(circuit.input_widths)` at the top of `_simulate`.**

- **HIGH — NTuple input has no `simulate` coverage.** Probe §10 shows `reversible_compile(xs -> xs[1] + xs[2], NTuple{2, Int8})` fails at compile time with "no unique matching method found for the specified argument types" — the NTuple input path that the README claims is supported is broken at the public entry. WORKLOG notes an NTuple-input simulate gap; confirmed present.

- **HIGH — widths > 64 bits** not supported — `_read_int` returns `Int(raw & ...)` only for width ≤ 64; `simulate` stores input bits via `(v >> (i - 1))` which relies on Julia's `>>` on the host integer type. A `BigInt` input would… probably work for the input-write but fail on output-read. Untested, undocumented.

- **MEDIUM — single-input `simulate` requires exactly 1 input_width**: error message is correct and legible. But the 2-arg version doesn't symmetrically check — `simulate(c_2arg, (Int8(1),))` (tuple of 1) would be accepted then explode on `inputs[2]` indexing. Confirmed by reading simulator.jl:18–25: `for (k, w) in enumerate(circuit.input_widths)` iterates `k=1:2` but `inputs` is length-1 → `BoundsError`. **Not a clean error.**

- **MEDIUM — no batch simulation.** `simulate(c, batch::AbstractVector)` doesn't exist; users loop manually. Given the package's "test all 256 Int8 inputs" idiom, this is worth offering.

- **LOW — no `simulate!` in-place variant.** For tight loops, allocating `zeros(Bool, n_wires)` per call is wasteful. A `simulate!(buf, c, input)` would help.

---

## 13. Composition API

**`compose(c1, c2)` / `c1 * c2` — does not exist.** No tests search-hit for `compose` in a circuit sense.

For a reversible-circuit library this is a glaring gap. Users can't combine two compiled circuits except by:
1. Manually concatenating `gates` fields — but wire namespaces collide. No helper to remap.
2. Recompiling a larger function that calls both — heavyweight.

**Recommendation (HIGH):** define `compose(c1::ReversibleCircuit, c2::ReversibleCircuit)::ReversibleCircuit` with documented wire-mapping semantics. Export it. A reversible-circuit library without composition is incomplete.

---

## 14. Inverse API

**`inverse(c)` — does not exist as a public function.** However, the implementation pattern is trivial (every gate is self-inverse, so reversing gate order is the inverse), and `verify_reversibility` does this internally.

Given that Bennett's construction is *built on* the inverse concept and several downstream users (quantum libs) will need the uncompute half of a circuit, not exporting `inverse(c)::ReversibleCircuit` is **odd**. Not critical — users can slap one together — but the omission is notable.

---

## 15. ControlledCircuit API

- `controlled(circuit)` — good.
- `simulate(cc, ctrl, x)` — good.
- No `uncontrolled(cc) -> (inner, ctrl_wire)`.
- No `controlled(controlled(c))` (multi-controlled) — single-level only.
- `ControlledCircuit` struct is exported but **undocumented**.

Sturm.jl integration story (`when(qubit) do f(x) end`) needs:
1. `controlled(c)` with explicit `ctrl_wire` position — currently appended at `n_wires + 1`. No way to specify wire position.
2. A way to compose a controlled circuit with an uncontrolled one — blocked on §13.
3. Mutual-exclusion between controls (quantum "if-else") — not addressed.

**Recommendation**: Expose `controlled(c; ctrl_wire=nothing)` with wire-position control, add `uncontrolled`, document the Sturm integration pathway.

---

## 16. Persistence / serialization

**No `save(c, path)`, no `load(path)`, no `serialize`/`deserialize` protocol.** `ReversibleCircuit` is a plain struct — it should work under Julia's `Serialization` stdlib by default, but there's no documented guarantee and no round-trip test.

Given compile times of minutes for large circuits (SHA-256, soft-float polynomials), **not having a save/load is a real productivity hole**. A user recompiles every REPL session.

Tactical fix: add `save_circuit(c, path)` / `load_circuit(path)` using `Serialization`. Long-term: stable on-disk format.

---

## 17. Stdout / logging contract

Searching for `@info` / `@warn` / `@debug` / bare `println` in `src/`:

<details>
<summary>checks</summary>
(not done here; would probe with `Grep`)
</details>

From reading the top-level `reversible_compile` flow (src/Bennett.jl:58–94), **no logging or prints in the happy path** — good. `print_circuit` / `show` are opt-in. OK.

---

## 18. Argument-type inference

`reversible_compile(f)` — no types given — **hits the Float64 varargs path with zero types**, which then errors with `"Need at least one Float64 argument type"`. Misleading. A user who just forgot to say `Int8` is told "you need Float64".

Julia doesn't infer argument types of an anonymous function without specimens, so fully-automatic inference is impractical, but at minimum the missing-type case should produce "reversible_compile requires explicit argument types; usage: reversible_compile(f, Int8) or reversible_compile(f, Int8, Int8)".

Tactical: add a 0-arg-type method that throws that message.

---

## 19. Thread-safety / parallelism

### Shared mutable state found

- `_known_callees::Dict{String, Function}` (src/ir_extract.jl:220) — module-global mutable registry. `register_callee!` mutates it without locks. **Not thread-safe.** Two threads calling `register_callee!(f)` race.

- Load-time `register_callee!(soft_fadd)` etc. (src/Bennett.jl:163–208) populate this dict at module init. Since `using Bennett` is single-threaded, this is fine.

- But a user who has thread 1 compile `f` that uses a globally-registered `g`, while thread 2 calls `register_callee!(h)` and `reversible_compile(k)` — the two compiles may race on the dict if `_lookup_callee` happens concurrently with dict insertion. **Sharp bug potential.**

- No other globals found in top-level pipeline files (diagnostics.jl, simulator.jl, controlled.jl are pure).

### Recommendation

Either:
1. Lock `_known_callees` access with a `ReentrantLock`.
2. Make it a thread-local or a `CompileContext` field.
3. Document that `register_callee!` must be called single-threaded at package init.

Option 3 is fine for research code but needs to be written down.

---

## 20. Versioning story

### Project.toml

```
name = "Bennett"
version = "0.4.0"
[compat]
julia = "1.6"
```

### README

> Requires Julia 1.10+ and LLVM.jl.

### PRD inventory

`CLAUDE.md` lists PRDs for v0.1, v0.2, v0.3, v0.4, v0.5.

### Findings

- **CRITICAL — `julia = "1.6"` contradicts the README's "Julia 1.10+".** If either is correct, the other is wrong. LLVM.jl 9.x ships for 1.9+, so 1.6 is factually wrong. Pick one: fix Project.toml to `julia = "1.10"`.

- **CRITICAL — `version = "0.4.0"` has never moved.** v0.5 PRD has been implemented. Every non-trivial kwarg addition (`add`, `mul`, `bit_width`, `strategy`, `compact_calls`) and every new `reversible_compile` overload is a minor bump in semver. No bumps ever.

- **MEDIUM — no `CHANGELOG.md`.** `WORKLOG.md` exists but it's a dev log, not a user-facing changelog. Consumers can't tell which kwargs were added in which version.

- **MEDIUM — no `@experimental` or `@unstable` markers.** All 71 exports look equally public. Users who depend on `cf_pmap_set` have no signal that it's research surface.

---

## Prioritized findings

### CRITICAL

1. **`simulate(c_single_arg, (x, y))` silently returns garbage.** Arity check is missing on the tuple overload. Fix: assert `length(inputs) == length(circuit.input_widths)` at top of `_simulate` (src/simulator.jl:14). *Same bug applies to `_simulate_ctrl`.*

2. **Documented gate types (`NOTGate`, `CNOTGate`, `ToffoliGate`) are not exported.** `docs/src/api.md` §"Gate Types" tells users to construct these; `using Bennett; NOTGate(1)` fails. Either export them, or remove them from public docs. The former is correct — they're documented *constructors*.

3. **`Project.toml` lies about the Julia version (1.6 vs README's 1.10+) and the package version (still `0.4.0` after v0.5 PRD shipped).** These are published metadata.

4. **Divergent kwarg surfaces across `reversible_compile` overloads.** `bit_width` and `add`/`mul` accepted on Int path, rejected (MethodError) on Float64 path. Either harmonize or document the asymmetry with proper `ArgumentError`s.

5. **`bit_width` accepts negative values, oversized values, and produces bogus circuits** (probe §: `bit_width=-5` → 26-wire circuit returning `1` on any input). Violates project principle 1.

6. **`register_callee!` mutates module-global state without synchronization.** Will race on multi-threaded compile.

### HIGH

7. **`simulate` returns `Int*` for `UInt*` inputs** (probe §: `UInt8` in → `Int8` out). Loses signedness.

8. **Tuple return widths are all widened to `Int64`** regardless of original element types (probe §: tuple-of-`Int8` returns `Tuple{Int64, Int64}`). Type information is destroyed.

9. **`ParsedIR` and `LoweringResult` are not exported but are return types of exported functions and appear in public docs.** Users must prefix with `Bennett.` to annotate them.

10. **Documented "Arithmetic primitive functions" (`lower_add!`, `lower_mul_karatsuba!`, …) in `docs/src/api.md` are not exported.** Doc lies. Either export them (they're documented public) or remove the section.

11. **NTuple input compile path broken at `reversible_compile` entry.** `reversible_compile(xs -> ..., NTuple{2, Int8})` errors with an opaque "no unique matching method found" — this is a README-advertised feature.

12. **No `compose(c1, c2)` API.** Core composition primitive missing from a reversible-circuit library.

13. **`verify_reversibility` contract is asymmetric**: returns `true` on success, raises on failure. Either always raise (return `Nothing`) or always return `Bool` (return `false` on mismatch).

14. **Error messages for unsupported input types point at LLVM internals** rather than at the user's call site. A `String` input produces `ir_extract.jl: unsupported LLVM type for width query: LLVM.PointerType(ptr)` — actionable to a compiler dev, inscrutable to a user.

### MEDIUM

15. **Persistent-DS surface (`*_pmap_*`, `*_IMPL`, `OkasakiState`, `cf_reroot`, `verify_pmap_correctness`, `pmap_demo_oracle`) bleeds 25+ experimental names into the top-level namespace.** Should live under a `Bennett.Persistent` sub-module or stay unexported.

16. **Soft-float primitives (21 exports, `soft_fadd` … `soft_exp2_julia`) are implementation details.** They're useful for tests but users shouldn't lean on them. Move to `Bennett.SoftFloat` sub-module.

17. **`ControlledCircuit` is exported but undocumented.** No docstring, no `show` method, struct fields not explained.

18. **`depth`, `gate_count`, `ancilla_count`, `simulate`, `verify_reversibility`, `print_circuit`, `ControlledCircuit`, and several persistent/soft-float exports lack docstrings.** 9 undocumented exports that appear in user-facing examples.

19. **`register_callee!` name breaks Julia convention** (bang implies first-arg mutation). More Julian: `register_callee(f)`.

20. **Five variants of `*_bennett` (pebbled, eager, value_eager, pebbled_group, checkpoint) are 5 separate exports.** Better: `bennett(lr; strategy=...)` dispatching.

21. **`reversible_compile(f)` with no types misroutes to the Float64 varargs overload** and emits "Need at least one Float64 argument type" — misleading.

22. **`use_inplace`, `use_karatsuba`, `fold_constants` kwargs on `lower` are unreachable from `reversible_compile`** — either expose or delete.

23. **`t_count` ignores decomposition choice** while `t_depth` honors it — inconsistent. Either thread `decomp` through `t_count` or hard-code `decomp=:ammr` and document.

24. **Widths > 64 bits are not supported in `simulate`** (WORKLOG-noted).

25. **No `save`/`load` for compiled circuits.** Long compile times make this a productivity hole.

### LOW / NIT

26. `print_circuit` duplicates `Base.show(::MIME"text/plain", ::ReversibleCircuit)`. Remove one.

27. `extract_ir` returns a raw IR `String` — docstring admits it's for debugging. Should not be exported.

28. `parse_ir` is the legacy regex parser (`ir_parser.jl`). Per `CLAUDE.md` it's kept for backward compat. Should be de-exported or explicitly deprecated.

29. No `CHANGELOG.md`.

30. No `@experimental` / `@unstable` annotations.

31. `CompileOptions` struct (§3 last item) would fold 10+ orthogonal kwargs into one stable argument.

32. `depth` name is semantically overloaded (circuit depth vs Toffoli-depth vs T-depth). Consider `gate_depth`.

33. Input-type dispatch uses `Type{<:Tuple}` for int path and `Type{Float64}...` varargs for float path; a mixed `(Float64, Int8)` call falls through both with MethodError. Document the restriction or route through a common entry.

34. `lower` method exposed via `Bennett.lower(...)` in tutorials but not exported. Same for `bennett`. Tutorials use prefixed form; api.md sometimes does and sometimes doesn't. Inconsistent.

---

## Proposed minimal-surface API

If I were designing v1.0 from scratch, the exported surface would be ~15 names:

```julia
# Types
export ReversibleCircuit, ControlledCircuit, ReversibleGate,
       NOTGate, CNOTGate, ToffoliGate

# Compile
export reversible_compile, CompileOptions

# Run
export simulate

# Inspect
export gate_count, depth, toffoli_depth, peak_live_wires,
       verify_reversibility

# Transform
export controlled, inverse, compose   # inverse + compose are new
```

Everything else moves to one of:

- `Bennett.Persistent` — sub-module for pmap/Okasaki/CF/HAMT/hashcons research (25 names)
- `Bennett.SoftFloat` — sub-module for soft-float primitives (21 names)
- `Bennett.Internal` / no export — for `extract_ir`, `parse_ir`, `extract_parsed_ir*`, `register_callee!`, `print_circuit`, `t_count`, `t_depth`, `constant_wire_count`, `ancilla_count`, and the `*_bennett` variants (which collapse under a `strategy=` kwarg of `bennett(lr; strategy=:checkpoint)`).

Then **freeze the 15**. Add `@experimental` to anything new added outside them. Bump the Project.toml version to match reality (at minimum `0.5.0-dev`).

---

## Concrete renames & signature changes (if not doing a big rewrite)

1. Remove exports for `parse_ir`, `extract_ir`, `pmap_demo_oracle`, `verify_pmap_correctness`, `LINEAR_SCAN_IMPL`, `OKASAKI_IMPL`, `CF_IMPL`, `HAMT_IMPL`, `OkasakiState`, `soft_popcount32`.

2. Add exports for `NOTGate`, `CNOTGate`, `ToffoliGate`, `ReversibleGate`, `ParsedIR`, `LoweringResult` (all already documented as public).

3. Rename `register_callee!` → `register_callee` (no bang).

4. Collapse `pebbled_bennett` / `eager_bennett` / `value_eager_bennett` / `pebbled_group_bennett` / `checkpoint_bennett` into `bennett(lr; strategy::Symbol=:full)`. Keep old names as deprecated aliases for one minor version.

5. Fix `simulate` to: (a) check arity, (b) preserve signedness, (c) return width-matched tuple elements. Introduce `simulate(c, x)::T where T matches the circuit-declared output type`.

6. Add `ArgumentError` checks for `bit_width::Int` (must be 0 or in `{8,16,32,64,...}`), `max_loop_iterations::Int` (must be ≥ 0).

7. Bump Project.toml to `0.5.0`, fix `julia = "1.10"`.

8. Stop exporting the 21 soft-float primitives; add a `Bennett.SoftFloat` sub-module and re-export through it for tests.

9. Stop exporting the 25 pmap/persistent names; move to `Bennett.Persistent` sub-module.

10. Add `compose(c1, c2)`, `inverse(c)` exports with simple implementations and tests.

11. Add `CHANGELOG.md`.

---

## Summary verdict

The Bennett.jl public API has real signal value — `reversible_compile` is a crisp entry point, `gate_count` returns a clean NamedTuple, the `controlled`/`simulate` pairing works. The *core* design (5 exports: `reversible_compile`, `simulate`, `controlled`, `gate_count`, `verify_reversibility`) is defensible.

But the *surrounding* export surface is a research whiteboard dumped into the top-level namespace: 35+ of 71 exports are implementation scaffolding for experiments (persistent DS, soft-float primitives, strategy variants of Bennett) that should be either hidden or walled off in sub-modules.

Three issues rise to **CRITICAL**:

1. `simulate` silently accepts wrong-arity input and returns nonsense.
2. `NOTGate`/`CNOTGate`/`ToffoliGate` are documented as public but not exported (doc-reality divergence).
3. `Project.toml` lies about both the package version (0.4.0 since forever) and the Julia compat (1.6 vs reality 1.10+).

Four issues rise to **HIGH**:

- Signedness/width loss in `simulate` return types.
- `ParsedIR`/`LoweringResult` unexported but documented as public.
- No `compose`/`inverse` API (gap for a reversible-circuit library).
- `bit_width` accepts garbage values silently.

The fastest way to halve this list: enforce at the `reversible_compile` entry a small `_validate_input_types` + `_validate_kwargs` stanza that raises `ArgumentError` with specific, user-framed messages; fix `simulate` arity + signedness; export the documented gate types; bump the version number; write a `CHANGELOG.md`. That's two days of work and cuts the API's behavioral mystery in half.

---

**Files referenced (absolute paths):**

- `/home/tobiasosborne/Projects/Bennett.jl/src/Bennett.jl` — exports, `reversible_compile` overloads, `SoftFloat` wrapper
- `/home/tobiasosborne/Projects/Bennett.jl/src/simulator.jl` — `simulate`, `_read_int` (signedness/width loss, missing arity check)
- `/home/tobiasosborne/Projects/Bennett.jl/src/controlled.jl` — `ControlledCircuit` (no docstring), `simulate(cc,…)` (same arity hole)
- `/home/tobiasosborne/Projects/Bennett.jl/src/diagnostics.jl` — `gate_count` NamedTuple, `verify_reversibility` asymmetric return, `depth`/`t_count`/`t_depth` inconsistency, `print_circuit` duplication with `Base.show`
- `/home/tobiasosborne/Projects/Bennett.jl/src/gates.jl` — exported `ReversibleCircuit` struct (7 public fields), unexported `NOTGate`/`CNOTGate`/`ToffoliGate`/`ReversibleGate`
- `/home/tobiasosborne/Projects/Bennett.jl/src/ir_extract.jl` — `register_callee!` global-dict state, `extract_parsed_ir` kwargs unreachable from `reversible_compile`
- `/home/tobiasosborne/Projects/Bennett.jl/src/lower.jl` — `lower` with 7 kwargs, 4 unreachable from public entry; strategy validation
- `/home/tobiasosborne/Projects/Bennett.jl/src/bennett_transform.jl` — `bennett` entry, `self_reversing` short-circuit
- `/home/tobiasosborne/Projects/Bennett.jl/Project.toml` — `version = "0.4.0"`, `julia = "1.6"` (stale / wrong)
- `/home/tobiasosborne/Projects/Bennett.jl/docs/src/api.md` — documents un-exported `NOTGate`/`CNOTGate`/`ToffoliGate` and the `lower_*!` primitives
- `/home/tobiasosborne/Projects/Bennett.jl/docs/src/tutorial.md` — uses `Bennett.extract_parsed_ir` / `Bennett.lower` (prefixed) inconsistent with exported-is-public framing
- `/home/tobiasosborne/Projects/Bennett.jl/README.md` — "Requires Julia 1.10+" contradicts Project.toml
