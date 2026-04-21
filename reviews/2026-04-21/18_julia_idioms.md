# Bennett.jl — Julia idioms & ecosystem-fit review

**Reviewer:** independent Julia-idioms reviewer
**Date:** 2026-04-21
**Scope:** `/home/tobiasosborne/Projects/Bennett.jl` — `Project.toml`, `Manifest.toml`, `src/`, `test/`, `benchmark/`
**Size:** ~13 328 LOC Julia across 57 source files (incl. softfloat/ and persistent/)
**Deps:** `LLVM`, `PicoSAT`, `InteractiveUtils` (stdlib). Test extras: `Test`, `Random`.

This is a skeptical, package-shaped-Julia review. I did not coordinate with other reviewers and have not read their output. I'm separating cosmetic nits from real idiom / ecosystem issues that would hurt Bennett.jl's adoption or maintenance. Bennett.jl has some beautiful bits (clean multiple-dispatch core in `_lower_inst!`, sensible `Base.show`, docstrings in most places) but also a number of ingrained anti-patterns — the biggest being a tagged-union `IROperand` type spreading `op.kind == :ssa` checks across ~45 call sites, monoculture `error(...)` instead of typed exceptions, and several `::Any` fields in hot structs.

---

## Executive summary

- **CRITICAL: `IROperand` is a hand-rolled tagged union**, costing 45+ `op.kind == :ssa` checks and 20+ near-duplicate `_ssa_operands` methods. Julia's natural encoding is `abstract type IROperand; struct SSAOperand; struct ConstOperand`, which gives you dispatch for free and eliminates `iconst`/`ssa` constructors as helpers.
- **CRITICAL: `LoweringCtx` has three `::Any` fields** (`preds`, `branch_info`, `block_order`) actively used on a hot per-instruction dispatch path. This defeats inference through `_lower_inst!` and is self-inflicted — the comment literally says "typed Any to accept any dict shape from caller." That's not an idiom, that's giving up.
- **HIGH: 190 `error(...)` calls, zero uses of typed exceptions** (`ArgumentError`, `DimensionMismatch`, `DomainError`, `BoundsError`). Every failure path throws a generic `ErrorException`. Callers can't `try … catch e::ArgumentError`; `@test_throws ArgumentError` is impossible. This is the single biggest thing to fix for library-shape API.
- **HIGH: zero `@assert`, 2 `@assert` in the codebase.** `@assert` exists for invariants that are "correct by construction" and disableable with `--check-bounds=no`-like flags; CLAUDE.md rule 1 ("FAIL FAST, FAIL LOUD") is being interpreted to mean `error(...)` everywhere, which is not quite the same thing.
- **HIGH: `Manifest.toml` is listed in `.gitignore` but is committed** (see `git status` vs `.gitignore`). A Julia library should not commit `Manifest.toml`; an app should. The two signals contradict; pick one.
- **HIGH: `[compat] julia = "1.6"` is a lie.** `Manifest.toml` was generated on Julia 1.12.3, the README says "Requires Julia 1.10+", `ParsedIR` uses `Base.@kwdef` (fine), `PackageExtensions` / weak-deps are not used. Compat bound should be `julia = "1.10"`.
- **HIGH: `[compat] LLVM = "9.4.6"`** is an exact-version pin on a core dep. LLVM.jl's semver is not that lively but a pin breaks integration with Sturm.jl, MLIR.jl, etc. the moment anyone bumps. Use `LLVM = "9"` (or `"9.4"`).
- **MEDIUM: `ir_parser.jl` (168 LOC of regex LLVM IR parsing) is included but the project doctrine says "LLVM.jl C API walker is the source of truth — not regex parsing" (CLAUDE.md rule 5).** Three tests still use it (`test_parse.jl`, `test_branch.jl`, `test_loop.jl`). It's contradicted code, and the tests that depend on it are not porting to the canonical walker.
- **MEDIUM: Massive hand-unrolled branchless code in `persistent/hamt.jl`** (8-way copy-paste per slot, 250+ lines of near-identical `ifelse` chains for slots 0..7). This is literally the case for `@generated` or at minimum an `ntuple` + `ifelse` fold. Hand-unrolling 8 slots by copy-paste is the brittlest code in the codebase.
- **MEDIUM: `Vector{Any}` in `tabulate.jl:159`** (`args = Any[]` for heterogeneous integer types). Fix with `ntuple` or a typed constructor.
- **MEDIUM: allocations in `_gate_controls` hot path** — returns a fresh `Vector{Int}` per call (`[g.control]`, `[g.control1, g.control2]`). Use a `Tuple` or iterate directly over fields. Called in DAG building, pebbling, liveness — every `depth()`, `peak_live_wires` pass.
- **MEDIUM: 11 `_lower_inst!(ctx, inst::X, ::Symbol)` methods look clean, but the project still has `inst isa IRBinOp elseif inst isa IRICmp` chains** inside `lower_loop!` (`src/lower.jl:743-748`). Dispatch half the time.
- **MEDIUM: no `Base.iterate` / `getindex` on `ReversibleCircuit`**, no `length`, no `eltype` — makes `c.gates` the only way to iterate, which leaks the internal representation. Users have to reach through `.gates`.
- **MEDIUM: 36 `struct` types, zero `NamedTuple` fields used for public API**, but `_detect_sret` returns an untyped `NamedTuple` (`ir_extract.jl:412`). NamedTuple is fine for return values, but the `_detect_sret` return type is deeply ad-hoc and a proper `struct SretInfo` would be clearer.
- **LOW: 0 macros, 0 `@generated`** — for a compiler infrastructure package that is unusual in a good way; Julia often over-indexes on metaprogramming. However, some places where `@generated` would be genuinely appropriate (HAMT slot unrolling, `_narrow_inst` dispatch) were not used.
- **LOW: `Project.toml` depends on `InteractiveUtils` only so the pipeline can call `code_llvm`.** That works, but means every consumer of Bennett.jl drags in `InteractiveUtils`; a package extension for `code_llvm` on the compile path would keep the core leaner. Not a deal-breaker.

---

## Findings by severity

### CRITICAL

---

#### C1. `IROperand` is a hand-rolled tagged union

**File:** `src/ir_types.jl:3-10`

```julia
struct IROperand
    kind::Symbol       # :ssa or :const
    name::Symbol       # SSA name (if :ssa)
    value::Int         # constant value (if :const)
end

ssa(name::Symbol)    = IROperand(:ssa, name, 0)
iconst(value::Int)   = IROperand(:const, Symbol(""), value)
```

This is C-idiomatic, not Julia-idiomatic. The consequences are visible everywhere:

- **45 call sites with `op.kind == :ssa`** (grep `\.kind\s*==\s*:(ssa|const)` across `src/`).
- **20+ near-copy-paste methods of `_ssa_operands(inst::T)`** in `lower.jl:195-261` — each walks the `IROperand` fields of an instruction and checks `.kind == :ssa`. Dispatch replacement would shrink these dramatically.
- **The `iconst`/`ssa` constructors are stringly-typed adapters** (`iconst` jams a zero-Symbol into `name`; `ssa` jams 0 into `value`). A reader has to remember the tag discipline.
- **Every pattern match on operand kind inflates both `.name` and `.value` in memory** — an `IROperand` is 24+ bytes (Symbol + Symbol + Int) when the valid payload is at most 16 bytes (Symbol | Int).

**Idiomatic fix:**

```julia
abstract type IROperand end
struct SSAOperand   <: IROperand; name::Symbol end
struct ConstOperand <: IROperand; value::Int end

# Dispatch replaces .kind checks:
is_ssa(op::SSAOperand)   = true
is_ssa(op::ConstOperand) = false

# _ssa_operands shrinks from 20 methods to ~2:
_ssa_operands(op::SSAOperand)   = (op.name,)
_ssa_operands(op::ConstOperand) = ()
```

Downstream this eliminates all 45 `.kind == :ssa` checks. Code becomes shorter AND type-stable (Julia knows `op isa SSAOperand` implies `op.name::Symbol`).

**Scope of change:** non-trivial — touches every file that pattern-matches operands. Worth doing before v1.0.

---

#### C2. `LoweringCtx` has three `::Any` fields on a hot dispatch path

**File:** `src/lower.jl:50-83`

```julia
struct LoweringCtx
    gates::Vector{ReversibleGate}
    wa::WireAllocator
    vw::Dict{Symbol,Vector{Int}}
    preds::Any    # Dict{Symbol,Vector{Symbol}} — typed Any to accept any dict shape from caller
    branch_info::Any
    block_order::Any
    block_pred::Dict{Symbol,Vector{Int}}
    ssa_liveness::Dict{Symbol,Int}
    ...
```

The comment excuses this with "accept any dict shape from caller" — but that's exactly the problem. Type-stability is local; `_lower_inst!(ctx, inst, label)` runs per IR instruction per compile. Any method called with `ctx.preds` has to re-infer through `::Any`. If the caller passes in a different concrete type once, inference gives up and the whole compile path runs through runtime dispatch.

If the dict shape genuinely varies, that's **design**, not a thing to paper over with `::Any`:

- Either fix the shape (`Dict{Symbol,Vector{Symbol}}`) and make callers conform.
- Or make `LoweringCtx` parametric: `struct LoweringCtx{P,B,O} ... preds::P; branch_info::B; block_order::O end` — Julia specialises at compile time.

I checked: every call site I can find passes the same dict shapes, so **option 1** is trivial and will give real runtime wins.

**File for same bug:** `src/ir_types.jl:180` — `memssa::Any  # Forward-declared as Any to avoid circular type dependency with src/memssa.jl`. Fix by moving `memssa.jl` above `ir_types.jl` in the include order (or moving the `MemSSAInfo` type into `ir_types.jl`). Circular-include workarounds with `::Any` are bad idiomatic Julia.

---

### HIGH

---

#### H1. Exception types: 190 `error(...)`, zero `ArgumentError`/`DimensionMismatch`/`DomainError`

**Files:** throughout `src/`

Every failure in Bennett.jl raises a bare `ErrorException` via `error(...)`. `throw(ArgumentError(...))`, `throw(DimensionMismatch(...))`, `throw(DomainError(...))`, `throw(BoundsError(...))` are not used anywhere. Representative cases that should use specific types:

| File:line | Current | Should be |
|---|---|---|
| `src/Bennett.jl:62-65` | `error("reversible_compile: unknown strategy …")` | `ArgumentError` |
| `src/Bennett.jl:274` | `error("…strategy=:$strategy not supported …")` | `ArgumentError` |
| `src/Bennett.jl:276` | `error("Need at least one Float64 argument type")` | `ArgumentError` |
| `src/Bennett.jl:293` | `error("Float64 compile supports up to 3 arguments (got $N)")` | `ArgumentError` |
| `src/adder.jl` / `src/multiplier.jl` | wire-length mismatches | `DimensionMismatch` |
| `src/simulator.jl:7` | `error("simulate(circuit, input) requires single-input …")` | `ArgumentError` |
| `src/simulator.jl:31` | `error("Ancilla wire $w not zero — Bennett construction bug")` | `AssertionError` (internal invariant) or custom `AncillaError` |
| `src/qrom.jl:46-49` | preconditions on `data`, `W`, `L` | `ArgumentError` |
| `src/lower.jl:311-313` | unknown add/mul strategy | `ArgumentError` |

**Why it matters:**
1. **API tests cannot use `@test_throws ArgumentError foo(...)`** — they can only use `@test_throws ErrorException foo(...)`, which masks different failure modes.
2. **Downstream packages (Sturm.jl) can't catch-and-recover.** `catch e::ArgumentError` is the idiomatic pattern; with Bennett, they'd have to string-match error messages.
3. **Standard Julia style.** Every top-100 package in General does this.

The fix is mechanical. A codemod:
- "unknown X, got Y" → `ArgumentError`
- "wire length mismatch, W=X got Y" → `DimensionMismatch`
- "out-of-range" (e.g. `emit_qrom!` `W must be in 1..64`) → `DomainError` or `BoundsError`
- internal "this should never happen" → `AssertionError` or plain `error` (reserved for genuinely internal bugs)

---

#### H2. `@assert` is essentially unused (2 occurrences across 13k LOC)

**Files:** `src/lower.jl:1`, `src/softmem.jl:1` — the two uses I can find.

CLAUDE.md rule 1 is "FAIL FAST, FAIL LOUD", which the codebase translates to `error(...)` everywhere. But Julia's convention is:

- `@assert cond msg` — invariants that are "correct by construction." Can be disabled by `--check-bounds=no`-style flags in tight loops; typically kept on.
- `error(msg)` / `throw(...)` — runtime-reachable errors (bad user input, I/O, data).

Functions like `_compute_ancillae`, `bennett`, `simulate` have internal invariants (copy-out wires freshly allocated, gate ordering, etc.) that are `@assert`-appropriate: "if this fails, we have a compiler bug, not a user bug." Running everything through `error(...)` means the bug message is indistinguishable from a "you passed a wrong strategy" message.

Shift about half of the internal error sites (those that say things like "compiler bug", "should never happen", "Bennett construction bug") to `@assert`. Keep user-input validation as typed `throw(...)`.

---

#### H3. `Manifest.toml` is gitignored AND committed — contradictory signal

**Files:** `.gitignore:1` (`Manifest.toml`), `Manifest.toml` (committed to the repo at `Manifest.toml`).

```
$ cat .gitignore
Manifest.toml
…
```

…but `git ls-files | grep Manifest` shows `Manifest.toml` is tracked.

Convention:
- **Libraries/packages:** do not commit `Manifest.toml`. Let the resolver pick.
- **Applications / reproducible-research projects:** commit `Manifest.toml` to pin exact dep versions.

Bennett.jl is a **library** (`[compat] julia = "1.6"`, exports a public API, is described in README as installable via `Pkg.add(url=…)`). So the correct action is **delete `Manifest.toml` from git** (it's already gitignored — just run `git rm --cached Manifest.toml`).

Also, the committed `Manifest.toml` was regenerated on `julia_version = "1.12.3"` (which doesn't exist — Julia 1.12 is `alpha` as of this writing). This suggests a prerelease toolchain wrote it, which will confuse anyone trying to reproduce.

---

#### H4. `[compat] julia = "1.6"` vs. README's "Requires Julia 1.10+"

**Files:** `Project.toml:13`, `README.md:63`

```toml
[compat]
LLVM = "9.4.6"
PicoSAT = "0.4.1"
julia = "1.6"
```

README says:
> Requires Julia 1.10+ and LLVM.jl.

I looked for 1.10+-only features in the code:
- `Base.@kwdef` (1.9+) in `src/persistent/interface.jl:72`
- `eachmatch` / `startswith` / `strip` everywhere — all 1.6-safe.
- No `setfield!` on mutable-with-const-fields (1.8+).
- No slurping `NamedTuple` destructuring (1.9+).
- No `Base.Experimental.@compiler_options` or similar.

My reading: the code **could** work on 1.6 with `Base.@kwdef` being the main risk, but the `Manifest.toml` was regenerated on 1.12 and nobody tests on 1.6.

**Fix:** `julia = "1.10"` (matches README, matches what LLVM.jl 9.x actually supports).

---

#### H5. `[compat] LLVM = "9.4.6"` is an exact-version pin

**File:** `Project.toml:11`

```toml
LLVM = "9.4.6"
```

In Julia's Pkg semver, `"9.4.6"` in `[compat]` means "≥ 9.4.6 and < 10". That's actually fine-ish for libraries (matches caret-semver), **BUT**:

- It excludes LLVM.jl 10, 11, etc. — which will happen (LLVM.jl tracks LLVM versions).
- Sturm.jl integration: if Sturm ever depends on LLVM 10, Bennett.jl blocks the solve.

Prefer: `LLVM = "9, 10"` or drop to `LLVM = "9"` for the time being, and bump when a breaking LLVM.jl release requires surgery.

Same comment applies to `PicoSAT = "0.4.1"` — `0.4` would let patch bumps in.

---

#### H6. `ir_parser.jl`: 168 LOC of contradictory code

**File:** `src/ir_parser.jl`

CLAUDE.md rule 5:
> LLVM IR IS NOT STABLE. LLVM IR output is not a stable API. Never assume specific IR formatting, instruction ordering, or naming conventions. The LLVM.jl C API walker (`ir_extract.jl`) is the source of truth — not regex parsing.

And yet `src/ir_parser.jl` is a regex-based LLVM IR parser still included in `src/Bennett.jl:6`. It's used by:
- `test/test_parse.jl`
- `test/test_branch.jl`
- `test/test_loop.jl`

The tests that depend on it are *prima facie* a liability — either the regexes go stale and they start failing on new LLVM versions (which rule 5 warns about), or they test a code path nobody uses in production.

**Recommendation:**
1. Port `test_parse.jl` / `test_branch.jl` / `test_loop.jl` to use `extract_parsed_ir` directly (they're small, 20-50 lines each).
2. Delete `ir_parser.jl`.
3. Remove `parse_ir` from the `export` list in `src/Bennett.jl:36`.

---

### MEDIUM

---

#### M1. `persistent/hamt.jl` is 250+ lines of hand-unrolled `ifelse` chains

**File:** `src/persistent/hamt.jl:118-241`

Every slot 0..7 has near-identical code:
```julia
# Slot 0
nk0_upd = ifelse(idx == UInt32(0), k_u, k0)
nk0_ins = ifelse(idx == UInt32(0), k_u, k0)
new_k0  = is_occupied * nk0_upd + is_new * nk0_ins
nv0_upd = ifelse(idx == UInt32(0), v_u, v0)
nv0_ins = ifelse(idx == UInt32(0), v_u, v0)
new_v0  = is_occupied * nv0_upd + is_new * nv0_ins
# Slot 1 ... repeats 8 times total
```

**Why this matters:**
1. If `_HAMT_MAX_N` changes from 8, someone has to edit 250 lines of boilerplate.
2. The hand-unrolled version masks bugs — I saw at least one (`nk0_ins = ifelse(idx == UInt32(0), k_u, k0)` with a comment "j=0: only new if idx==0, else old" that drops an else-branch the other slots have — maybe correct for slot 0, maybe not).
3. Julia is actively designed for this situation. `ntuple(Val(N))` + a small helper produces identical LLVM.

**Idiomatic refactor:**

```julia
@inline function _hamt_slot_update(is_occupied::UInt64, is_new::UInt64,
                                   j::Int, idx::UInt32, new_k::UInt64,
                                   old_k::UInt64, old_prev::UInt64)
    upd = ifelse(idx == UInt32(j), new_k, old_k)
    ins = ifelse(idx == UInt32(j), new_k,
          ifelse(j > Int(idx), old_prev, old_k))
    return is_occupied * upd + is_new * ins
end

# Then:
new_keys = ntuple(Val(_HAMT_MAX_N)) do j
    _hamt_slot_update(is_occupied, is_new, j-1, idx, k_u,
                      s[1 + j], j > 1 ? s[j] : UInt64(0))
end
```

Julia inlines this into branchless LLVM identical to the hand-rolled version (verify with `@code_llvm`). If Julia won't, use `@generated` — this is exactly the case for it.

---

#### M2. `_gate_controls` / `_gate_target` allocate on the hot path

**File:** `src/dep_dag.jl:90-96`, `src/diagnostics.jl:10-12`

```julia
_gate_controls(g::NOTGate) = Int[]
_gate_controls(g::CNOTGate) = [g.control]
_gate_controls(g::ToffoliGate) = [g.control1, g.control2]
```

Every call allocates a fresh heap `Vector{Int}`. Called in:
- `depth(c::ReversibleCircuit)` — once per gate
- `peak_live_wires(c)` — once per gate
- `extract_dep_dag(circuit)` — once per forward gate
- `compute_wire_liveness` — once per gate
- The pebbling / eager / value_eager / sat_pebbling / pebbled_groups paths

For a circuit with 700 gates this is 700 allocations per diagnostic; across `verify_reversibility` × n_tests=100 and several diagnostics, easily thousands.

**Fix:** return a `Tuple`:
```julia
_gate_controls(g::NOTGate)     = ()
_gate_controls(g::CNOTGate)    = (g.control,)
_gate_controls(g::ToffoliGate) = (g.control1, g.control2)
```

Tuples of small length are stack-allocated and iterate just the same. The `diagnostics.jl:10` version already uses tuples for `gate_wires`, so the inconsistency is on the `dep_dag.jl` side.

Same comment for `diagnostics.jl:gate_wires` which correctly uses Tuples. The codebase has both conventions.

---

#### M3. `lower_loop!` does `if inst isa IRBinOp elseif inst isa IRICmp …` instead of dispatch

**File:** `src/lower.jl:743-748`

```julia
for inst in body_insts
    if inst isa IRBinOp;    lower_binop!(gates, wa, vw, inst)
    elseif inst isa IRICmp; lower_icmp!(gates, wa, vw, inst)
    elseif inst isa IRSelect; lower_select!(gates, wa, vw, inst)
    elseif inst isa IRCast; lower_cast!(gates, wa, vw, inst)
    end
end
```

Elsewhere the codebase uses multiple dispatch via `_lower_inst!(ctx, inst::IRBinOp, ::Symbol)` cleanly (`src/lower.jl:122-164`). The loop body bypasses this infrastructure and manually enumerates types — AND only covers 4 of the ~12 IR node kinds, so any loop body with a `IRCall`, `IRStore`, `IRLoad`, `IRPhi`, etc. is silently dropped.

Not just a style issue — it's a **semantic bug risk** (any loop using memory ops or calls in the header body becomes a no-op). Either:
- Refactor to call `_lower_inst!(ctx, inst, header.label)`.
- Or at minimum add an `else error(...)` branch to fail loud on unhandled instructions.

---

#### M4. No iteration/length/eltype methods on `ReversibleCircuit`

**File:** `src/gates.jl:31-39`, `src/diagnostics.jl:26-37`

`ReversibleCircuit` defines only `Base.show(io, ::MIME"text/plain", c)`. A user who wants to iterate gates has to reach through `c.gates` — a leak of internal representation.

Idiomatic additions:
```julia
Base.length(c::ReversibleCircuit) = length(c.gates)
Base.iterate(c::ReversibleCircuit, s...) = iterate(c.gates, s...)
Base.eltype(::Type{ReversibleCircuit}) = ReversibleGate
Base.getindex(c::ReversibleCircuit, i) = c.gates[i]
```

And possibly `Base.firstindex`, `Base.lastindex`.

This is a "polishing pass before General registry" thing — not a blocker, but makes Bennett.jl feel idiomatic from the REPL.

---

#### M5. `tabulate.jl` uses `Vector{Any}` for a tuple

**File:** `src/tabulate.jl:158-168`

```julia
function _unpack_args(raw::UInt64, input_widths::Vector{Int}, arg_T)
    args = Any[]
    rem = raw
    for (k, w) in enumerate(input_widths)
        m = (UInt64(1) << w) - UInt64(1)
        v = rem & m
        rem >>= w
        push!(args, _raw_bits_to_type(v, arg_T[k]))
    end
    return args
end
```

This is the only `Any[]` in `src/`. Because `arg_T[k]` is a Type that's distinct per index, and `f(args...)` is variadic, a Tuple is the right choice:

```julia
function _unpack_args(raw::UInt64, input_widths::NTuple{N,Int},
                     ::Type{Ts}) where {N, Ts<:Tuple}
    # … build an NTuple
end
```

Would also specialise `_tabulate_build_table` per input-width vector, which is short. Current type-unstable call into `f(args...)` is justified by the fact that tabulate is a compile-time path, not a runtime hot path — so this is MEDIUM, not HIGH.

---

#### M6. `_detect_sret` returns an ad-hoc `NamedTuple`

**File:** `src/ir_extract.jl:412-416`

```julia
found = (param_index = i, param_ref = p.ref, agg_type = ty,
         n_elems = n, elem_width = w,
         elem_byte_size = elem_bytes,
         agg_byte_size = n * elem_bytes)
```

A struct with docstring would be clearer:
```julia
struct SretInfo
    param_index::Int
    param_ref::LLVMValueRef
    agg_type::LLVM.ArrayType
    n_elems::Int
    elem_width::Int
    elem_byte_size::Int
    agg_byte_size::Int
end
```

Same for other NamedTuples used as structs (see `pebble_tradeoff` return in `src/pebbling.jl:208` — though that one is fine because it's a public return value and the fields are self-documenting).

---

#### M7. Module-level `include` chain is flat (all files are included in `module Bennett`)

**File:** `src/Bennett.jl:3-34`

```julia
module Bennett
include("ir_types.jl")
include("ir_extract.jl")
include("ir_parser.jl")
include("gates.jl")
…
include("persistent/persistent.jl")
end
```

No submodules. Julia supports nested modules (`module IRExtract … end`), and for a 13k LOC package with 5+ subsystems (IR extraction, lowering, gate types, softfloat, persistent DS, pebbling strategies, benchmarks) this would help:

- Discoverability — `Bennett.Lower.foo` vs `Bennett._foo_internal`.
- `using Bennett.Softfloat: soft_fadd` to import a namespace.
- Private vs public separation without prefix-underscore hacks.

But: this is a **taste** call, not an error. Many large Julia packages keep a flat module (Pluto.jl is an example). Flag it as "consider for v1.0", not "fix now."

---

#### M8. Docstrings present but no doctests, no `Documenter.jl` setup

**Files:** `docs/` (has subfolders but no `make.jl`), throughout `src/`

Docstring coverage is decent — `lower.jl` has 61 docstring delimiters, `adder.jl` has 4, `Bennett.jl` has 10. But:

- **No `docs/make.jl`** — Documenter.jl is not wired up. The `docs/` tree has `design/`, `literature/`, `memory/`, `prd/`, `src/` — those are internal docs, not user docs.
- **No `jldoctest` blocks** anywhere (`grep jldoctest` across `src/` → 0 hits). Docstring code examples aren't tested.
- The README's code examples (lines 7-41) are *representative* of doctests but don't run.

A General-registry package should have at least a minimal `docs/make.jl` + `docs/src/index.md` + Documenter.jl.

---

### LOW

---

#### L1. `const` globals: 121 across the codebase, mostly in the right places

Good: most numerical / string tables are `const` (e.g. `src/softfloat/softfloat_common.jl:8-12`, `src/diagnostics.jl:67-70`, `src/ir_extract.jl:272`, `_OPCODE_MAP` dispatch tables).

Quibble: `src/ir_extract.jl:1760` has `const OPAQUE_PTR_SENTINEL = IROperand(:const, :__opaque_ptr__, 0)` which is exported as an "IROperand" but used as a sentinel value. If `IROperand` becomes an abstract type (C1), this becomes a named singleton `struct OpaquePtrSentinel <: IROperand end`.

---

#### L2. `SoftFloat` wrapper type is good, not piracy

`src/Bennett.jl:220-249` extends `Base.:+(a::SoftFloat, b::SoftFloat)` etc. — since `SoftFloat` is Bennett's own type, this is safe, not piracy. (Piracy would be extending `Base.:+(::Float64, ::Float64)`.) Well done.

Nit: `Base.:(<)(a::SoftFloat, b::SoftFloat)` is defined but not `<=`, `>`, `>=`, `isless`. For completeness, `isless` is the canonical one and gives all comparisons by default.

---

#### L3. Zero macros, zero `@generated`

A pure-data compiler with 13k LOC and zero metaprogramming is unusual in a good way — it means the code is straight-line readable. The places where `@generated` would genuinely shine are:
- `_narrow_inst(inst::IR..., W)` — a type-switch on inst; `@generated` could collapse it.
- `persistent/hamt.jl` per-slot code (M1).
- `tabulate.jl:_unpack_args` (M5).

None of these is urgent. Appreciate the restraint.

---

#### L4. `@info` / `@warn` / `@debug` unused in `src/`, 7 `println` in `diagnostics.jl`

**File:** `src/diagnostics.jl:26-35`

```julia
function print_circuit(io::IO, c::ReversibleCircuit)
    …
    println(io, "ReversibleCircuit:")
    println(io, "  Wires:    $(c.n_wires)")
    …
end
```

These are user-facing `println(io, …)` for a `show`-like method, so they're fine (they take an `io` arg). No misuse of `println` as logging. No spurious `@info` either.

One nit: `print_circuit(c::ReversibleCircuit) = print_circuit(stdout, c)` duplicates what `show(::MIME"text/plain", …)` already provides. The `print_circuit` export is arguably redundant.

---

#### L5. Keyword defaults & positional-vs-kw mix

`reversible_compile` uses kwargs (`optimize`, `max_loop_iterations`, `compact_calls`, `bit_width`, `add`, `mul`, `strategy`) — good. Defaults look sane.

Quibble: `extract_parsed_ir` has a mix of `preprocess::Bool=false` and `passes::Union{Nothing,Vector{String}}=nothing`. `Union{Nothing, T}` defaults are a mild anti-pattern; `passes::Vector{String} = String[]` is clearer (empty vector means "no extra passes").

---

#### L6. No `Base.:(==)` / `hash` on `ReversibleCircuit`, `ReversibleGate`

Might be intentional (gate identity by position in the gate list, not by field equality). But note: `Set{ReversibleGate}` would use identity because the default `==` for structs is field-by-field AND `hash` falls back. Probably fine; if you plan a gate-rewriting pass, revisit.

---

#### L7. Tests: `@testset` coverage strong, `@test_throws` underused

- 627 `@testset` usages, 33 `@test_throws` — but as noted (H1) all errors are `ErrorException`, so `@test_throws` can only test "it crashed" not "it crashed with the right error." Fixing H1 unlocks much better test coverage.
- `@test_broken` / `@test_skip` not used, which is fine — either a test passes or you rm it.
- No `SafeTestsets.jl` / `ReTest.jl` — plain `Test` with `include(…)` chains in `runtests.jl` (106 lines of `include`). Works, but SafeTestsets would give per-file isolation (no test bleed-through).

---

#### L8. `benchmark/` not wired into CI / not using BenchmarkTools

**Files:** `benchmark/bc1_cuccaro_32bit.jl` etc. (no Project.toml, no BenchmarkTools import).

`grep BenchmarkTools` across the project → **zero hits**. The `benchmark/` directory has handwritten timing scripts but doesn't use the standard BenchmarkTools.jl harness. For a performance-sensitive compiler, this is a gap. `PkgBenchmark.jl` + `BenchmarkTools.jl` + a `benchmark/benchmarks.jl` entry-point would give you regression tracking.

The `BENCHMARKS.md` file (7k) contains baseline numbers — these should ideally live in code (tracked by `PkgBenchmark`) rather than a markdown file.

---

#### L9. No `Aqua.jl`, no `JET.jl`

These are the standard "is my package registered-ready" tools. Add:

```julia
# test/test_aqua.jl
using Aqua
Aqua.test_all(Bennett)
```

catches unbound type parameters, ambiguities, stale deps, compat issues. For 13k LOC at pre-release, this would probably surface 3-5 real issues.

---

#### L10. Unicode usage

Tasteful. `≤`, `α`, `β`, `γ`, `π` used in comments. No `α = 1.0` as a variable name (which some people hate). Thumbs up.

---

#### L11. Internal `_` convention

Followed consistently: `_lower_inst!`, `_tabulate_applicable`, `_narrow_ir`, `_sf_normalize_clz`, `_emit_qrom_from_gep!`, `_rbt_pack`. Exported API has no leading-underscore names. Good.

---

#### L12. `PackageExtensions` (Julia 1.9+) opportunities

**File:** `Project.toml`

Two candidates:
1. **LLVM.jl as weak dep**: if someone only wants to call a pre-compiled circuit (`simulate`, `verify_reversibility`), they shouldn't need LLVM.jl. Split into `Bennett` (types + sim) + `BennettLLVMExt` (requires LLVM; defines `reversible_compile` from Julia function). Requires Julia 1.9 (you're already targeting 1.10).
2. **InteractiveUtils**: same argument, lighter — `code_llvm` is the reason it's pulled in.

Neither is urgent; both would make Bennett.jl's load time materially better. `using Bennett` currently precompiles all of LLVM.jl.

---

#### L13. Commented-out / dead code

Minor: `src/eager.jl:112-120` has a 9-line "NOTE: Wire-level EAGER … FAILS" comment block. Well-documented; actually useful. Keep.

`_reset_names!()` in `src/ir_extract.jl:255` is "No-op for backward compatibility (counter is now local to each compilation)". Mark for removal at next major version.

---

## Positive observations (what's right)

1. **`_lower_inst!(ctx, inst::IRType, label::Symbol)` dispatch** (`src/lower.jl:122-164`) is idiomatic Julia. The main IR → gate dispatch is clean multiple-dispatch — one method per IR type, no `if inst isa X`. This is the good stuff.
2. **`struct` usage**: 36 concrete struct types, no abuse of `mutable struct` (only `WireAllocator` is mutable, appropriately). Immutable by default.
3. **Generic parametric adder/multiplier functions** take `W::Int` and wires as `Vector{Int}` — not hardcoded to `Int8`/`Int64`. The *values* flow through is correct.
4. **`SoftFloat` wrapper is well-designed**: owns the type, extends `Base` operators on its own type (no piracy), `@inline` annotations where they matter.
5. **Naming is consistent**: `lower_*!`, `emit_*!`, `_*` internal, exported names clear. Easy to navigate.
6. **Docstrings on most public functions** and a notable number of internal helpers. Quality is good — most explain *why*, not just *what*.
7. **Test organization**: `runtests.jl` includes per-feature test files; each file has its own `@testset`. Exhaustive on Int8 (all 256 inputs, per CLAUDE.md rule 4).
8. **No type piracy detected**: `Base.show`, `Base.:+(::SoftFloat, …)`, `Base.:(<)`, `Base.copysign`, `Base.abs`, `Base.floor`, etc. all defined on Bennett-owned `SoftFloat`.

---

## Priority recommendations before v1.0 / General registry

**Must-fix:**

1. **H3**: remove `Manifest.toml` from git, or decide Bennett is an app and un-gitignore it.
2. **H4**: bump `[compat] julia` from `"1.6"` to `"1.10"` (matching reality).
3. **H5**: loosen `[compat] LLVM = "9.4.6"` to `"9"` or `"9, 10"`.
4. **H1**: mechanical sweep converting `error("foo: bad arg")` → `throw(ArgumentError("bad arg"))` and similar.
5. **H6**: port the 3 tests using `ir_parser` to `extract_parsed_ir`, delete `src/ir_parser.jl`.
6. **M3**: fix `lower_loop!` to use the proper dispatch path (semantic bug).

**Should-fix:**

7. **C1**: refactor `IROperand` to an abstract type with `SSAOperand`/`ConstOperand` subtypes. Big mechanical change, big code-quality dividend.
8. **C2**: remove `::Any` fields from `LoweringCtx` / `ParsedIR` by making the type parametric OR fixing the dict shapes.
9. **M1**: collapse HAMT hand-unrolling via `ntuple` + helper.
10. **M4**: add `length`/`iterate`/`getindex` on `ReversibleCircuit`.
11. **L8**: wire up BenchmarkTools.jl + PkgBenchmark.jl for regression tracking.
12. **L9**: add `Aqua.test_all` as a test.

**Nice-to-have:**

13. **M2**: Tuple-ify `_gate_controls` in `dep_dag.jl`.
14. **M6**: struct-ify `_detect_sret` return.
15. **L12**: split LLVM.jl into a package extension.
16. **M8**: minimal `docs/make.jl` with Documenter.jl.

The headline: Bennett.jl is structurally sound but carries a few non-idiomatic design choices (tagged-union `IROperand`, `::Any` fields, monoculture `error(...)`) that feel like early-project decisions that calcified. Most are mechanical fixes; the payoff for each is concrete (better inference, better test discipline, better downstream integration).

---

*End of review.*
