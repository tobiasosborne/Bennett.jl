# Proposer A — T5-P5a + T5-P5b: multi-language `.ll` / `.bc` ingest

**Beads**: Bennett-lmkb (T5-P5a, `extract_parsed_ir_from_ll`) +
Bennett-f2p9 (T5-P5b, `extract_parsed_ir_from_bc`).
**RED targets**: `test/test_t5_corpus_c.jl`, `test/test_t5_corpus_rust.jl`
(6 `@test_throws UndefVarError` on `Bennett.extract_parsed_ir_from_ll`).
**Depends on**: nothing (P5a is pure extractor plumbing); P5b trivially
builds on P5a.
**Blocks**: T5-P6 (`:persistent_tree` arm) cannot flip the C/Rust corpus
GREEN until P5a lands.
**Scope constraint (CLAUDE.md §2 + §11)**: this is a core change to
`ir_extract.jl`. 3+1 is mandatory. Keep the diff small; no drift into
demangling, linkage, or other ABI concerns.

---

## 1. Context

`extract_parsed_ir(f, arg_types)` today is the single path into
`_module_to_parsed_ir`. It runs `code_llvm(...; dump_module=true)` to
produce IR text, parses it via `parse(LLVM.Module, ir_string)` in a
fresh `LLVM.Context()`, optionally runs NPM passes, then dispatches to
`_module_to_parsed_ir(mod)`, which hardcodes `startswith(LLVM.name(f),
"julia_")` + a body check to find the entry.

For the T5 corpus (C, Rust) there is no Julia function — just an `.ll`
or `.bc` dropped by clang / rustc. The entry name is known to the
caller (`"malloc_idx_inc"`, `"vec_push_sum"`, etc.), so the knobs we
need to add are **(a)** an alternative parser input (file text / file
bitcode) and **(b)** an explicit entry-function selector replacing the
hard-coded `julia_*` prefix.

The T5 PRD §M5.5 acceptance bar:

> Regression: 5 existing test programs produce identical `ParsedIR` from
> `extract_parsed_ir(f, T)` and `extract_parsed_ir_from_ll(<.ll dump of f>)`.

That is the load-bearing invariant (§3, §6, §7).

### 1.1 Why `reversible_compile(::ParsedIR)` too

The six corpus GREEN blocks (currently commented out) follow the pattern:

```julia
parsed = Bennett.extract_parsed_ir_from_ll(ll_out; entry_function="malloc_idx_inc")
c = reversible_compile(parsed)   # <-- this overload doesn't exist yet
```

`reversible_compile` today has two methods: `(f, arg_types::Type{<:Tuple})`
and `(f, float_types::Type{Float64}...)`. Both start with
`extract_parsed_ir(f, ...)`. A caller who already holds a `ParsedIR`
should be able to skip that and run `lower + bennett` directly — cleaner
than asking callers to import `Bennett.lower` and `Bennett.bennett` (which
aren't exported). This overload is tiny and gives the corpus its
`reversible_compile(parsed)` call.

---

## 2. API surface

### 2.1 `extract_parsed_ir_from_ll`

```julia
"""
    extract_parsed_ir_from_ll(path::AbstractString; entry_function::AbstractString,
                              preprocess::Bool=false,
                              passes::Union{Nothing,Vector{String}}=nothing,
                              use_memory_ssa::Bool=false) -> ParsedIR

Parse a raw textual LLVM IR file (`.ll`) and extract the function named
`entry_function` into a `ParsedIR`. The `.ll` is read from disk, passed to
LLVM.jl's text parser (`parse(LLVM.Module, ir_string)`), and walked by the
same visitor used by `extract_parsed_ir(f, T)`.

Arguments mirror `extract_parsed_ir`, *minus* `optimize` (IR has already
been compiled by an external toolchain — LLVM has no knob to re-decide
which passes to run at text-parse time). `preprocess`, `passes`, and
`use_memory_ssa` work identically.

`entry_function` is matched against LLVM-level function names as they
appear in the module. Name mangling (e.g. Rust's `_ZN…_foo…E`) is the
caller's responsibility — see §4 and §5.

Throws `ErrorException` when:
  * `path` does not exist or is not readable;
  * the file is not valid textual LLVM IR (LLVM.jl's parser raises
    `LLVMException`, which this entry point re-wraps with the `path` prefix);
  * no function named `entry_function` exists in the module (the error
    message lists the first N defined function names found);
  * the named function is a declaration (has no body).
"""
function extract_parsed_ir_from_ll(path::AbstractString;
                                   entry_function::AbstractString,
                                   preprocess::Bool=false,
                                   passes::Union{Nothing,Vector{String}}=nothing,
                                   use_memory_ssa::Bool=false)
    ...
end
```

### 2.2 `extract_parsed_ir_from_bc`

```julia
"""
    extract_parsed_ir_from_bc(path::AbstractString; entry_function::AbstractString,
                              preprocess::Bool=false,
                              passes::Union{Nothing,Vector{String}}=nothing,
                              use_memory_ssa::Bool=false) -> ParsedIR

Parse an LLVM bitcode file (`.bc`) and extract the function named
`entry_function` into a `ParsedIR`. Identical semantics to
`extract_parsed_ir_from_ll`; only the parser differs (bitcode, not text).

Bitcode parsing uses `LLVM.MemoryBufferFile(path)` +
`parse(LLVM.Module, membuf)`, which internally calls
`LLVM.API.LLVMParseBitcodeInContext2`.

Throws `ErrorException` on the same set of conditions as
`extract_parsed_ir_from_ll` (file not found, invalid bitcode, entry
function missing / a declaration).
"""
function extract_parsed_ir_from_bc(path::AbstractString;
                                   entry_function::AbstractString,
                                   preprocess::Bool=false,
                                   passes::Union{Nothing,Vector{String}}=nothing,
                                   use_memory_ssa::Bool=false)
    ...
end
```

### 2.3 Kwarg table (both entry points)

| Kwarg              | Type                             | Default | Behaviour                                                                  |
|--------------------|----------------------------------|---------|----------------------------------------------------------------------------|
| `entry_function`   | `AbstractString` (required)      | —       | Name of function to extract. Exact match against LLVM-level name. §4.      |
| `preprocess`       | `Bool`                           | `false` | Run `DEFAULT_PREPROCESSING_PASSES` before the walker (same as existing).   |
| `passes`           | `Union{Nothing,Vector{String}}`  | `nothing` | Explicit NPM pipeline (same as existing).                                |
| `use_memory_ssa`   | `Bool`                           | `false` | MemorySSA annotations (same as existing; §7.5).                            |

`optimize` is deliberately absent — the caller supplies an `.ll` / `.bc`
that is already the output of whatever optimisation pipeline they chose at
compile time. `preprocess=true` stays available for the downstream
alloca-elimination chore that `lower.jl` assumes.

### 2.4 `reversible_compile(parsed::ParsedIR; ...)` overload

```julia
"""
    reversible_compile(parsed::ParsedIR; max_loop_iterations=0,
                        compact_calls=false, add=:auto, mul=:auto,
                        strategy::Symbol=:expression) -> ReversibleCircuit

Compile a pre-extracted `ParsedIR` (typically from
`extract_parsed_ir_from_ll` or `extract_parsed_ir_from_bc`) through
`lower + bennett`. The extraction step is skipped.

Scope:
  * `strategy` must be `:expression` or `:auto`; `:tabulate` is disallowed
    here because tabulation operates on the *Julia* function, not a
    `ParsedIR` (we cannot evaluate the source function classically when
    all we have is LLVM IR).
  * `bit_width` narrowing is *not* supported in this overload; the
    `ParsedIR` already carries the widths the caller intends. Keeping the
    overload minimal is CLAUDE.md §11 (PRD-driven) — the T5 corpus has no
    narrowing use case.
  * `optimize` is not supported (meaningful only before extraction).
"""
function reversible_compile(parsed::ParsedIR;
                            max_loop_iterations::Int=0,
                            compact_calls::Bool=false,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            strategy::Symbol=:expression)
    strategy in (:auto, :expression) ||
        error("reversible_compile(::ParsedIR): only :expression (or :auto) " *
              "is supported; got :$strategy. :tabulate requires the Julia " *
              "function value, not a ParsedIR.")
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul)
    return bennett(lr)
end
```

This method lives in `src/Bennett.jl` immediately after the existing
`(f, arg_types)` method (lines 49–93). It does not need a `register_callee!`
pass or a `narrow_ir` pass — those are keyed off the Julia function or
explicit `bit_width` respectively, both N/A here.

### 2.5 Export list

All three names go in the module's `export` line (src/Bennett.jl:36):

```julia
export reversible_compile, simulate, extract_ir, parse_ir, extract_parsed_ir,
       extract_parsed_ir_from_ll, extract_parsed_ir_from_bc,
       register_callee!
```

The corpus tests currently call `Bennett.extract_parsed_ir_from_ll(...)`
(fully-qualified — `@test_throws Union{UndefVarError,MethodError,ErrorException}`
allows either exported or unexported). Either works. We export for
consistency with `extract_parsed_ir`.

---

## 3. `_module_to_parsed_ir` refactor — exact diff sketch

### 3.1 Shape choice

Two candidates:

**(a)** add a kwarg: `_module_to_parsed_ir(mod; entry_function=nothing)`
where `nothing` means "first `julia_*` function with a body" (current
behaviour).

**(b)** split into a function-locator helper + a core walker:
  * `_module_to_parsed_ir(mod; entry_function=nothing)` — **dispatcher**,
    locates the `LLVM.Function` and delegates.
  * `_module_to_parsed_ir_on_func(mod, func)` — **core**, walks a
    pre-selected function.

**Decision: option (b), the split.**

Rationale:
1. The locator has two distinct search strategies (prefix match for
   `julia_*` vs exact match for arbitrary names). Keeping these cleanly
   named is more readable than a chain of `if entry_function === nothing`
   branches.
2. Future work (Enzyme-style cross-module IR, or a multi-function
   extraction mode) will want to reuse the core walker with a
   `LLVM.Function` it already has in hand. The split makes this trivial;
   the kwarg approach forces a second locator call.
3. `_module_to_parsed_ir_on_func(mod, func)` is almost the current body of
   `_module_to_parsed_ir` with one name change — minimal churn.

### 3.2 The locator (new private function)

```julia
# ir_extract.jl — new private helper, added near _module_to_parsed_ir

"""
Find the entry function to extract from a module.

Modes:
  * `entry_function === nothing`: select the first function whose LLVM
    name starts with `"julia_"` AND has at least one basic block. This is
    the canonical Julia case and matches the pre-existing behaviour.
  * `entry_function::AbstractString`: select the function whose LLVM name
    matches *exactly*. Must have at least one basic block.

On failure, errors with a message including the module's defined-function
names (up to 20) to aid debugging.
"""
function _find_entry_function(mod::LLVM.Module,
                              entry_function::Union{Nothing, AbstractString})
    if entry_function === nothing
        for f in LLVM.functions(mod)
            if startswith(LLVM.name(f), "julia_") && !isempty(LLVM.blocks(f))
                return f
            end
        end
        error("ir_extract.jl: no julia_* function found in LLVM module " *
              "(the extractor expects code_llvm(...; dump_module=true) " *
              "output with at least one non-declaration `julia_` or `j_` " *
              "function). Defined functions: " *
              _format_defined_function_list(mod))
    else
        # Exact LLVM-level name match.
        name = String(entry_function)
        for f in LLVM.functions(mod)
            LLVM.name(f) == name || continue
            if isempty(LLVM.blocks(f))
                error("ir_extract.jl: entry_function=\"$name\" matches a " *
                      "declaration in the module (no function body). " *
                      "Ensure the .ll/.bc contains the *definition* of " *
                      "the function, not just an extern declaration.")
            end
            return f
        end
        error("ir_extract.jl: entry_function=\"$name\" not found in module. " *
              "Defined functions: " * _format_defined_function_list(mod))
    end
end

# Helper: human-readable list of defined function names for error messages.
# Skips declarations (bodyless); truncates at 20 names.
function _format_defined_function_list(mod::LLVM.Module)
    names = String[]
    for f in LLVM.functions(mod)
        isempty(LLVM.blocks(f)) && continue   # skip pure declarations
        push!(names, LLVM.name(f))
        length(names) >= 20 && (push!(names, "..."); break)
    end
    isempty(names) ? "(none)" : "[" * join(names, ", ") * "]"
end
```

### 3.3 Splitting `_module_to_parsed_ir`

The existing function is 163 lines (`ir_extract.jl:472-634`). The split
is mechanical:

```julia
# BEFORE  (ir_extract.jl:472)
function _module_to_parsed_ir(mod::LLVM.Module)
    counter = Ref(0)

    # Find the julia_ function with a body
    func = nothing
    for f in LLVM.functions(mod)
        if startswith(LLVM.name(f), "julia_") && !isempty(LLVM.blocks(f))
            func = f
            break
        end
    end
    func === nothing && error(
        "ir_extract.jl: no julia_* function found in LLVM module (the " *
        "extractor expects code_llvm(...; dump_module=true) output with at " *
        "least one non-declaration `julia_` or `j_` function)")

    # T1c.2: extract compile-time-constant global arrays so lower_var_gep! can
    # dispatch read-only lookups through QROM instead of a MUX-tree.
    globals = _extract_const_globals(mod)
    ...
    return ParsedIR(ret_width, args, blocks, ret_elem_widths, globals)
end

# AFTER
"""
Walk `mod` and return a `ParsedIR` for the entry function.

  * `entry_function === nothing` (default, back-compat): first
    `julia_*`-prefixed function with a body, matching pre-P5a behaviour.
  * `entry_function::AbstractString`: exact LLVM-level function name.
"""
function _module_to_parsed_ir(mod::LLVM.Module;
                              entry_function::Union{Nothing, AbstractString}=nothing)
    func = _find_entry_function(mod, entry_function)
    return _module_to_parsed_ir_on_func(mod, func)
end

# Core walker — operates on a pre-selected function. Everything from the
# original `_module_to_parsed_ir` body from "counter = Ref(0)" through
# "return ParsedIR(...)", minus the (now-hoisted) entry selection.
function _module_to_parsed_ir_on_func(mod::LLVM.Module, func::LLVM.Function)
    counter = Ref(0)

    # T1c.2: extract compile-time-constant global arrays so lower_var_gep! can
    # dispatch read-only lookups through QROM instead of a MUX-tree.
    globals = _extract_const_globals(mod)

    # (rest of the existing body unchanged)
    ...

    return ParsedIR(ret_width, args, blocks, ret_elem_widths, globals)
end
```

That is the entire refactor — ~30 lines moved, zero lines changed in the
walker body itself.

### 3.4 Call-site update inside `extract_parsed_ir(f, T)`

```julia
# BEFORE  (ir_extract.jl:72)
result = _module_to_parsed_ir(mod)

# AFTER  (unchanged because the default kwarg keeps the same meaning)
result = _module_to_parsed_ir(mod)
```

**No change needed.** The `entry_function=nothing` default preserves
pre-P5a behaviour bit-for-bit.

### 3.5 Why not add `entry_function` as a kwarg to `extract_parsed_ir(f, T)`

It's tempting to unify: `extract_parsed_ir(f, T; entry_function=...)`. But
when the caller has `(f, T)`, the Julia name is whatever `code_llvm`
produces (typically `julia_f_<hash>`), which is not stable across Julia
versions — callers cannot reasonably predict it. The existing "first
julia_* with a body" heuristic is correct for the Julia path and
shouldn't be second-guessed by a caller-supplied string. Keeping
`entry_function` exclusive to the P5a/P5b entry points is clearer.

---

## 4. Bitcode API specifics (T5-P5b)

### 4.1 Symbols verified in LLVM.jl v21 (installed at `~/.julia/packages/LLVM/fEIbx/`)

| What                              | Location                                                     | Notes                                                         |
|-----------------------------------|--------------------------------------------------------------|---------------------------------------------------------------|
| `parse(::Type{Module}, ::MemoryBuffer)` | `src/core/module.jl:215-227`                            | The bitcode parser entry. Wraps `LLVMParseBitcodeInContext2`. |
| `LLVM.MemoryBufferFile(path)`     | `src/buffer.jl:51-63`                                        | Read bitcode from disk. Calls `LLVMCreateMemoryBufferWithContentsOfFile`. |
| `LLVM.MemoryBuffer(data, name, copy)` | `src/buffer.jl:24-33`                                     | Wrap an in-memory byte vector (fallback if we want IO-buffering). |
| `LLVM.API.LLVMParseBitcodeInContext2` | `lib/17/libLLVM.jl:225-227` (and equivalents in 15,16,18,19,20) | `(Ctx, MemBuf, OutModule) -> LLVMBool`. Status `true` = error. Diagnostics handler catches them. |
| `dispose(membuf)`                 | `src/buffer.jl:79`                                           | Must dispose memory buffer (LLVMDisposeMemoryBuffer).         |
| `parse(::Type{Module}, ::String)` | `src/core/module.jl:183-203`                                 | Textual parser. Used by P5a. Wraps `LLVMParseIRInContext`.    |

Key lines in `src/core/module.jl`:

```julia
# lines 215-227 (bitcode parser)
function Base.parse(::Type{Module}, membuf::MemoryBuffer)
    out_ref = Ref{API.LLVMModuleRef}()
    status = API.LLVMParseBitcodeInContext2(context(), membuf, out_ref) |> Bool
    @assert !status # caught by diagnostics handler
    mark_alloc(Module(out_ref[]))
end

# lines 183-203 (textual parser)
function Base.parse(::Type{Module}, ir::String)
    data = unsafe_wrap(Vector{UInt8}, ir)
    membuf = MemoryBuffer(data, "", false)
    out_ref = Ref{API.LLVMModuleRef}()
    out_error = Ref{Cstring}()
    status = API.LLVMParseIRInContext(context(), membuf, out_ref, out_error) |> Bool
    mark_dispose(membuf)
    if status
        error = unsafe_message(out_error[])
        throw(LLVMException(error))
    end
    mark_alloc(Module(out_ref[]))
end
```

Both use `context()`, which is the currently-active context from
`LLVM.Context() do _ctx ... end`. So our entry points look like:

```julia
LLVM.Context() do _ctx
    # .ll:
    mod = parse(LLVM.Module, read(path, String))

    # .bc:
    @dispose membuf = LLVM.MemoryBufferFile(path) begin
        mod = parse(LLVM.Module, membuf)
    end
end
```

For the bitcode case I prefer `MemoryBufferFile(path)` (file-backed) over
loading all bytes into a `Vector{UInt8}` and wrapping that — the former
uses LLVM's mmap'd `LLVMCreateMemoryBufferWithContentsOfFile` and has
better error messages when the file is unreadable. See §8.3.

### 4.2 Why the `@dispose membuf = ... begin ... end` pattern

`src/buffer.jl:35-42` provides a closure form of `MemoryBuffer`:

```julia
function MemoryBuffer(f::Core.Function, args...; kwargs...)
    membuf = MemoryBuffer(args...; kwargs...)
    try
        f(membuf)
    finally
        dispose(membuf)
    end
end
```

but `MemoryBufferFile` (the file-reader we want) does not ship a closure
form. `@dispose` (from LLVM.jl's core) does: see
`/home/tobias/.julia/packages/LLVM/fEIbx/src/LLVM.jl` for the macro,
defined as roughly `try body; finally dispose(buf); end`. Same RAII
safety, no double-free risk.

### 4.3 Does bitcode parsing produce a `LLVMException` on malformed input?

`LLVMParseBitcodeInContext2` returns a status (0=ok, 1=error). LLVM.jl's
wrapper asserts `!status`, but the `@assert` fires *only* if a
diagnostics handler didn't already raise. In practice: a corrupted `.bc`
raises `LLVMException("...")` via LLVM.jl's installed diagnostic handler
(set up in `src/diagnostics.jl`). We catch both — `AssertionError` AND
`LLVMException` — and re-wrap with the path and a fail-loud message.

---

## 5. Decision table — entry-function lookup

| Mode                                             | Winner?           | Rationale                                                                                                                                                             |
|--------------------------------------------------|-------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Exact match on LLVM-level name** (MVP choice)  | ✔                | Simplest; matches what the T5 corpus already does (`entry_function="malloc_idx_inc"`). C functions have unchanged names at `-O0`; Rust's mangled name is what LLVM contains. |
| Substring match                                  | ✗                | Ambiguous — `"foo"` could match `"foo"`, `"foobar"`, `"_ZN3foo…"` all at once. Fail-loud requires exact matches.                                                       |
| Automatic demangling (itanium ABI)               | Deferred (§9)    | Would require pulling in `cxxfilt` or re-implementing demangling. Rust's name-mangling scheme is v0 (itanium-like) but changed between 1.59 and 1.79. Brittle; not MVP. |
| Prefix match (`startswith`)                      | ✗                | Behaves acceptably for `julia_` but ambiguous for anything else. Keep the prefix strategy *only* for the nothing-default path.                                        |
| Search all functions and pick the "most likely"  | ✗                | Violates CLAUDE.md §1 (fail loud). Magic guesses are exactly the class of bug that hurts us later.                                                                    |
| Regex match                                      | ✗                | Over-engineered for a string comparison.                                                                                                                              |

### 5.1 Rust name-mangling reality check

I verified via `Grep` that each T5 Rust fixture already uses
`#[no_mangle] pub fn <name>(...)`:

```
test/fixtures/rust/t5_tr1_vec_push.rs:16  #[no_mangle]
test/fixtures/rust/t5_tr1_vec_push.rs:17  pub fn vec_push_sum(x: i8) -> i8 {
test/fixtures/rust/t5_tr2_hashmap.rs:19   #[no_mangle]
test/fixtures/rust/t5_tr2_hashmap.rs:20   pub fn hashmap_roundtrip(k: i8, v: i8) -> i8 {
test/fixtures/rust/t5_tr3_box_list.rs:22  #[no_mangle]
test/fixtures/rust/t5_tr3_box_list.rs:23  pub fn box_list(x: i8) -> i8 {
```

`#[no_mangle]` makes the LLVM-level function name exactly the Rust
identifier — no `_ZN…E` wrapping. Every `entry_function="<name>"` in
`test_t5_corpus_rust.jl` will match exactly. **No fixture changes
needed**; the convention is already in place.

A one-paragraph note in `test/fixtures/rust/README.md` documents this so
future fixtures keep the convention (see §10.5).

### 5.2 C name-mangling

C has no mangling. `clang -O0 -emit-llvm -S` produces LLVM functions
whose names exactly match the C identifier. The T5 C fixtures use plain
identifiers (`malloc_idx_inc`, `realloc_buf`, `malloc_list`) — no
trouble. Inline / static-linkage modifiers may change the LLVM-level
linkage (internal vs external) but not the name.

---

## 6. Implementation sketch (actual Julia code)

### 6.1 Shared helper: `_parse_and_walk`

The two entry points differ only in the parser call. Factor out the
common plumbing:

```julia
# ir_extract.jl — new internal helper, co-located with extract_parsed_ir.

"""
Shared plumbing for `extract_parsed_ir_from_ll` and `…_from_bc`. Takes a
pre-created `LLVM.Module` (inside an active `LLVM.Context()`), optionally
runs NPM passes, walks the entry function, and returns the `ParsedIR`.
"""
function _extract_from_module(mod::LLVM.Module,
                              entry_function::AbstractString;
                              preprocess::Bool,
                              passes::Union{Nothing,Vector{String}},
                              memssa)
    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end
    if !isempty(effective_passes)
        _run_passes!(mod, effective_passes)
    end
    result = _module_to_parsed_ir(mod; entry_function=entry_function)
    # Stamp memssa into the result if requested (same logic as existing path)
    if memssa !== nothing
        result = ParsedIR(result.ret_width, result.args, result.blocks,
                          result.ret_elem_widths, result.globals, memssa)
    end
    return result
end
```

### 6.2 `extract_parsed_ir_from_ll`

```julia
function extract_parsed_ir_from_ll(path::AbstractString;
                                   entry_function::AbstractString,
                                   preprocess::Bool=false,
                                   passes::Union{Nothing,Vector{String}}=nothing,
                                   use_memory_ssa::Bool=false)
    isfile(path) || error("ir_extract.jl: extract_parsed_ir_from_ll: " *
                          "file not found: $(repr(path))")

    # Read the .ll as a String. UTF-8 by convention; LLVM IR is ASCII in practice.
    ir_string = try
        read(path, String)
    catch e
        rethrow(ErrorException("ir_extract.jl: failed to read $(repr(path)): " *
                               sprint(showerror, e)))
    end

    memssa = if use_memory_ssa
        annotated = _run_memssa_on_ir(ir_string; preprocess=preprocess)
        parse_memssa_annotations(annotated)
    else
        nothing
    end

    local result::ParsedIR
    LLVM.Context() do _ctx
        mod = try
            parse(LLVM.Module, ir_string)
        catch e
            if e isa LLVM.LLVMException
                rethrow(ErrorException("ir_extract.jl: failed to parse " *
                                       "$(repr(path)) as textual LLVM IR: " *
                                       e.msg))
            else
                rethrow()
            end
        end
        try
            result = _extract_from_module(mod, entry_function;
                                          preprocess, passes, memssa)
        finally
            dispose(mod)
        end
    end
    return result
end
```

### 6.3 `extract_parsed_ir_from_bc`

```julia
function extract_parsed_ir_from_bc(path::AbstractString;
                                   entry_function::AbstractString,
                                   preprocess::Bool=false,
                                   passes::Union{Nothing,Vector{String}}=nothing,
                                   use_memory_ssa::Bool=false)
    isfile(path) || error("ir_extract.jl: extract_parsed_ir_from_bc: " *
                          "file not found: $(repr(path))")

    # MemorySSA path: bitcode → disassemble → textual IR → run printer.
    # Only applicable when use_memory_ssa=true, which the T5 corpus doesn't use.
    # If needed, we'd round-trip through textual IR. For MVP, raise if requested.
    if use_memory_ssa
        error("ir_extract.jl: extract_parsed_ir_from_bc does not yet support " *
              "use_memory_ssa=true. Workaround: llvm-dis $(repr(path)) to " *
              ".ll first and use extract_parsed_ir_from_ll.")
    end

    local result::ParsedIR
    LLVM.Context() do _ctx
        mod = try
            @dispose membuf = LLVM.MemoryBufferFile(path) begin
                parse(LLVM.Module, membuf)
            end
        catch e
            if e isa LLVM.LLVMException
                rethrow(ErrorException("ir_extract.jl: failed to parse " *
                                       "$(repr(path)) as LLVM bitcode: " *
                                       e.msg))
            elseif e isa AssertionError
                # LLVMParseBitcodeInContext2 returned non-zero; wrap as error.
                rethrow(ErrorException("ir_extract.jl: failed to parse " *
                                       "$(repr(path)) as LLVM bitcode " *
                                       "(LLVMParseBitcodeInContext2 returned " *
                                       "error status; check file integrity)"))
            else
                rethrow()
            end
        end
        try
            result = _extract_from_module(mod, entry_function;
                                          preprocess, passes, memssa=nothing)
        finally
            dispose(mod)
        end
    end
    return result
end
```

### 6.4 Why not a single `extract_parsed_ir_from_file(path; from=:auto)`

Rejected: (a) the bead / PRD name the two entry points separately and
the corpus tests use them by name; (b) extension-based format inference
is a footgun (a `.ll` renamed to `.txt` would silently route to the
bitcode parser); (c) symmetry with `extract_ir` / `extract_parsed_ir`
(one name per input flavour).
  * Format inference is a footgun — a `.ll` written to `foo.txt` would
    silently route to the bitcode parser.
  * Symmetry with `extract_ir` / `extract_parsed_ir` (the Julia entry
    points) — one name per input flavour.

So we keep them separate, with minimal shared plumbing in
`_extract_from_module`.

### 6.5 The `reversible_compile(::ParsedIR)` overload

`src/Bennett.jl`, inserted immediately after the two-method group around
line 93 (before `_narrow_ir`). Full body already shown in §2.4; the
inserted text is verbatim from that listing.

### 6.6 Total diff footprint

| Area                                                      | Lines added | Lines changed |
|-----------------------------------------------------------|------------:|--------------:|
| `src/ir_extract.jl`: `_find_entry_function` + helper      |         ~45 |             0 |
| `src/ir_extract.jl`: split `_module_to_parsed_ir`         |         ~15 |          ~14  |
| `src/ir_extract.jl`: `_extract_from_module`               |         ~22 |             0 |
| `src/ir_extract.jl`: `extract_parsed_ir_from_ll`          |         ~35 |             0 |
| `src/ir_extract.jl`: `extract_parsed_ir_from_bc`          |         ~38 |             0 |
| `src/Bennett.jl`: export line                             |           0 |             1 |
| `src/Bennett.jl`: `reversible_compile(::ParsedIR)`        |         ~17 |             0 |
| **Subtotal**                                              |        ~172 |           ~15 |
| Corpus test flips (see §7.3)                              |         ~30 |           ~12 |
| **Grand total**                                           |        ~202 |           ~27 |

Single atomic commit for the source changes; corpus test flips happen in
the same commit to keep tests in sync (CLAUDE.md §3).

---

## 7. Test plan

### 7.1 Unit test — `test_p5a_unit.jl`

Hand-written `.ll` with one function `foo(i8) -> i8` that adds 3. Parses
via `extract_parsed_ir_from_ll`, runs `reversible_compile(parsed)`,
sweeps all 256 inputs against the Julia reference.

```julia
using Test
using Bennett

@testset "T5-P5a: extract_parsed_ir_from_ll — hand-written .ll" begin
    # Minimal .ll that any LLVM 15+ can parse. No attributes, no metadata,
    # no datalayout (context supplies a default).
    ll = """
    define i8 @foo(i8 %x) {
    entry:
      %r = add i8 %x, 3
      ret i8 %r
    }
    """
    path = joinpath(mktempdir(), "foo.ll")
    write(path, ll)

    parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="foo")
    @test parsed isa Bennett.ParsedIR
    @test parsed.ret_width == 8
    @test length(parsed.args) == 1
    @test parsed.args[1][2] == 8    # i8

    c = reversible_compile(parsed)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, Int8(x)) == Int8(x + 3)
    end
    @test verify_reversibility(c; n_tests=3)
end
```

### 7.2 Equivalence test — `test_p5a_equivalence.jl`

For each of 5 existing Julia test programs, dump `code_llvm(f, T;
debuginfo=:none, optimize=true, dump_module=true)` to a temp file, parse
the file via `extract_parsed_ir_from_ll` (entry name recovered by regex
on the IR string: `^define[^@\n]+@(julia_[A-Za-z0-9_]+)\(`), and
structurally compare the resulting `ParsedIR` against
`extract_parsed_ir(f, T)`. Also assert `gate_count` equality after
compiling both.

Programs (cross-section of the existing test suite):

  1. `x -> x + Int8(3)` (trivial add — `test_increment.jl`).
  2. `x -> x*x + Int8(3)*x + Int8(1)` on Int8 (polynomial — `test_polynomial.jl`).
  3. `(a, b) -> a + b` on Int16 (two-arg — `test_two_args.jl`).
  4. `x -> x < Int8(0) ? -x : x` on Int8 (branch — `test_branch.jl`).
  5. `(a, b) -> (a * b, a + b)` on Int8 (tuple — `test_tuple.jl`).

Structural equality helper (strict field-by-field compare, ignoring
`memssa` which is `nothing` for both sides when `use_memory_ssa=false`):

```julia
function parsed_ir_equal(a::Bennett.ParsedIR, b::Bennett.ParsedIR)
    a.ret_width == b.ret_width || return false
    a.args == b.args || return false
    a.ret_elem_widths == b.ret_elem_widths || return false
    a.globals == b.globals || return false
    length(a.blocks) == length(b.blocks) || return false
    for (ba, bb) in zip(a.blocks, b.blocks)
        ba.label == bb.label          || return false
        ba.instructions == bb.instructions || return false
        ba.terminator == bb.terminator   || return false
    end
    return true
end
```

**Why this works**: `extract_parsed_ir(f, T)` internally does exactly
`sprint(io -> code_llvm(…; dump_module=true))` + `parse(LLVM.Module, …)`
+ `_module_to_parsed_ir(…)`. The `.ll` path does `read(path, String)` +
`parse(LLVM.Module, …)` + `_module_to_parsed_ir(…; entry_function=…)`.
If the file and the in-memory string are byte-identical (and they are —
the dump writes the string, the test reads the same string), the
`LLVM.Module` parsed from each is structurally identical, and the
walker produces byte-identical `ParsedIR`. The test asserts that.

**Edge** — `optimize=true` matches `extract_parsed_ir`'s default.
Extending to `optimize=false` adds zero new test logic (parameterise the
harness).

### 7.3 Corpus flip — `test_t5_corpus_c.jl` + `test_t5_corpus_rust.jl`

After P5a lands, the `@test_throws UndefVarError` lines flip to:

```julia
# BEFORE (TC1):
@test_throws Union{UndefVarError,MethodError,ErrorException} Bennett.extract_parsed_ir_from_ll(ll_out; entry_function="malloc_idx_inc")

# AFTER (TC1 post-P5a, pre-P6):
parsed = Bennett.extract_parsed_ir_from_ll(ll_out; entry_function="malloc_idx_inc")
@test parsed isa Bennett.ParsedIR
# `reversible_compile(parsed)` still throws — lowering can't handle the
# malloc + dynamic-idx pattern until T5-P6 (:persistent_tree) lands.
@test_throws ErrorException reversible_compile(parsed)
```

All six corpus tests (TC1/TC2/TC3 × TR1/TR2/TR3) flip identically. Two
`@test`s per TC: parse succeeds, lower fails. When P6 lands, the second
line flips to the full commented-out GREEN block (verify all 256 inputs,
reversibility, print gate count).

**Critical caveat on the second line**: `reversible_compile(parsed)`
might also throw inside *extraction-adjacent* helpers like
`compute_ssa_liveness` if, e.g., an Rust `.ll` contains unsupported call
conventions or instructions that slip past `_convert_instruction`. That
still satisfies `@test_throws ErrorException` — it's the right error
class. The test stays descriptive (not a tautology) because (a) the
parse-success line explicitly asserts `parsed isa ParsedIR`, and (b) the
follow-up downstream throws a bucket-B error ("dynamic n_elems not
supported" or a lowering gap), which is the expected class until P6. The
WORKLOG entry documents the *specific* exception type for each TC so
future agents aren't surprised.

Under P6, the test flips to the full GREEN block. The P5a → P6 hand-off
is thus: "P5a lands, each TC has 2 asserts (parse-OK, lower-throws); P6
lands, each TC has ~260 asserts (parse-OK, lower-OK, all-inputs-match,
reversibility)".

### 7.4 Error-path test — `test_p5a_errors.jl`

Fail-loud contracts exercised explicitly (six cases):

| # | Case | Assertion |
|---|---|---|
| 1 | `.ll` file not found | `@test_throws ErrorException` on nonexistent path |
| 2 | Malformed `.ll` (garbage bytes written to file) | `@test_throws ErrorException` |
| 3 | Entry function not found | `catch; sprint(showerror)` contains `"\"bar\" not found"` AND `"[foo]"` (candidate listed) |
| 4 | Entry function is a declaration (`declare i8 @foo(i8)` in module) | error contains `"declaration"` |
| 5 | `.bc` file not found | `@test_throws ErrorException` |
| 6 | Malformed `.bc` | `@test_throws ErrorException` |

Each case is a 3–5 line block: build an input (temp file + `write(...)`),
invoke the entry point, assert. The harness matches the pattern used in
existing error tests (`test/test_cc06_error_context.jl`). Runs in <1 s
on all current LLVM versions. The candidate-listing assertion (case 3)
pins the error-message format from §3.2 and is the main regression guard
on that format.

### 7.5 MemorySSA interaction

`use_memory_ssa=true` support is only wired into the `.ll` path (the
`.bc` path explicitly errors with a llvm-dis workaround). The
equivalence test (§7.2) does not set `use_memory_ssa`, matching the
default. A separate `test_p5a_memssa.jl` could verify that
`extract_parsed_ir_from_ll(path; entry_function=…, use_memory_ssa=true)`
returns a `ParsedIR` with non-nothing `memssa` — but only if the caller
provides a `.ll` (not a `.bc`). For MVP: defer unless a caller asks.

---

## 8. Regression argument

### 8.1 Byte-identical baselines for existing `extract_parsed_ir(f, T)`

The existing `extract_parsed_ir(f, T)` path is modified in exactly one
place: the call to `_module_to_parsed_ir(mod)` becomes
`_module_to_parsed_ir(mod)` (same call, new kwarg with identical
default). The walker body (`_module_to_parsed_ir_on_func`) is a rename
of the existing body with zero code changes. Therefore:

**Invariant**: every Julia call to `extract_parsed_ir(f, T)` produces the
same `ParsedIR` bytes as before.

From this, every gate-count regression baseline is preserved:

| Baseline                        | Expected gates | Source            |
|---------------------------------|---------------:|-------------------|
| `x + Int8(1)` (i8 increment)    |             98 | WORKLOG principle §6 |
| i16 add                         |            202 | principle §6      |
| i32 add                         |            410 | principle §6      |
| i64 add                         |            826 | principle §6      |
| soft_fptrunc                    |         36,474 | WORKLOG §NEXT     |
| popcount32                      |          2,782 | WORKLOG §NEXT     |
| HAMT demo max_n=8               |         96,788 | WORKLOG §NEXT     |
| CF demo max_n=4                 |         11,078 | WORKLOG §NEXT     |
| CF+Feistel                      |         65,198 | WORKLOG §NEXT     |
| ls_demo_16                      |          5,218 | WORKLOG cc0.7     |
| TJ3 (linked list, cc0.4)        |            180 | WORKLOG cc0.4     |

The regression argument has two components:

**(a) Locator correctness at default.** The old locator was:

```julia
for f in LLVM.functions(mod)
    if startswith(LLVM.name(f), "julia_") && !isempty(LLVM.blocks(f))
        return f
    end
end
func === nothing && error("…no julia_* function found…")
```

The new locator at `entry_function === nothing` is byte-identical in
behaviour (same iteration order from `LLVM.functions(mod)`, same
prefix match, same body-guard). The error message is extended to list
candidate names (additive — a `.match` on `"no julia_* function found"`
still passes, per CLAUDE.md §6 baselines don't pin error messages).

**(b) Walker unchanged.** The body of `_module_to_parsed_ir_on_func` is
the body that was `_module_to_parsed_ir`, byte-for-byte. No local
variables renamed, no order of operations changed.

Combining (a) + (b): the extraction phase produces the same `ParsedIR`
for the same `(f, T)` input. `lower` and `bennett` are unchanged.
`reversible_compile(f, T)` thus produces the same `ReversibleCircuit`.
Gate counts are preserved.

### 8.2 No test running today will start failing

The corpus tests at HEAD are the only ones that refer to
`extract_parsed_ir_from_ll`, and they flip in lock-step (§7.3). All other
tests don't touch the new symbols. `test_p5a_unit.jl`,
`test_p5a_equivalence.jl`, `test_p5a_errors.jl` are *new* and entirely
RED until the source changes land.

### 8.3 What could break the regression — three places audited

  1. **`LLVM.functions(mod)` iteration order.** Insertion-ordered, not
     sorted. Deterministic on any given LLVM version. First `julia_*`
     with a body remains unambiguous (Julia emits exactly one per
     `code_llvm` dump).
  2. **`_extract_const_globals` iteration.** Unchanged body; returns a
     `Dict`, so key order is not observable downstream.
  3. **Context lifetime / `ParsedIR` aliasing.** `ParsedIR` fields are
     pure Julia: `Int`, `Symbol`, `Tuple{Symbol,Int}`, `IRBasicBlock`,
     `IRInst`, `Dict{Symbol, Tuple{Vector{UInt64}, Int}}`. No field
     stores an `LLVM.Value` / `LLVM.Function` / `LLVM.Module` / `_LLVMRef`.
     Safe to `dispose(mod)` before returning. Already implicit in
     `extract_parsed_ir(f, T)`; preserved.

### 8.4 Multi-language regression hook

PRD §R3 asks for ≥5 cross-language regressions. The §7.2 equivalence
test covers Julia → `.ll` → `.ll-parse` for 5 programs. C and Rust
coverage comes via the corpus `.ll` files at post-P6 GREEN time (per
TC/TR test sweeps — the harness is already in place in
`test_t5_corpus_*.jl`).

### 8.5 Additivity summary

The `.ll` / `.bc` entry points are **purely additive** — new public
names, no rename. The `_module_to_parsed_ir` split has a
zero-behaviour-change default. The `reversible_compile(::ParsedIR)`
overload is a new method dispatch, not a redefinition. Therefore the
change set *cannot* regress any existing test semantically.

---

## 9. Deferred / follow-up

Explicitly *not* in scope; each is a future bead on demand. Per
CLAUDE.md §11 (PRD-driven), none of these are in the T5 PRD.

  1. **Itanium / Rust-v0 demangling kwarg.** MVP is exact-match. Future
     `demangle::Bool=false` calling `cxxfilt` + Rust-v0 detection.
  2. **Multi-function extraction** (`Dict{String, ParsedIR}`) for
     foreign-library callee registration.
  3. **Cross-module linking** via `LLVM.Linker` (declaration-to-body
     resolution). MVP errors on declarations.
  4. **Triple / datalayout preflight** — warn if IR's pointer width
     differs from the host context's `LLVM.datalayout(mod)`.
  5. **Bitcode + MemorySSA** — round-trip via `LLVMPrintModuleToString`
     → textual → `_run_memssa_on_ir` → re-parse. Cheap; defer.
  6. **`.bc.gz` / compressed bitcode.** Not in PRD.
  7. **LLVM version compatibility.** `LLVMParseBitcodeInContext2` is in
     every LLVM 3.8+ and every LLVM.jl v21 backend (15–20 confirmed via
     `lib/{15,16,17,18,19,20}/libLLVM.jl`). No version-gated paths.
  8. **Case-insensitive entry match.** Exact only, per §5.
  9. **Non-Julia walker quirks.** `_detect_sret` recognises Julia's
     by-ref aggregate convention; clang/rustc IR may need extra cases
     at lowering time. Irrelevant for P5a/P5b (the corpus tests throw
     at lowering until P6); a walker-coverage bead if it bites.

---

## 10. Patch inventory — what the implementer touches

The paste-ready code for each source-level patch is already given in §3
(refactor), §6 (new entry points + overload), and §7 (tests). This
section is the explicit file-by-file inventory so the implementer can
work through it end-to-end without re-hunting.

### 10.1 `src/ir_extract.jl` — source patches

| Patch | Location | Kind | Reference |
|---|---|---|---|
| `_find_entry_function` + `_format_defined_function_list` | prepend before `_module_to_parsed_ir` (current `:472`) | new helpers | §3.2 |
| `_module_to_parsed_ir` → dispatcher | replace `:472-487` | refactor (kwarg + delegate) | §3.3 |
| `_module_to_parsed_ir_on_func` | new; body lifted from `:472-634` | pure move | §3.3 |
| `_extract_from_module` | after `extract_parsed_ir` (after `:92`) | new helper | §6.1 |
| `extract_parsed_ir_from_ll` | after `_extract_from_module` | new public entry | §6.2 |
| `extract_parsed_ir_from_bc` | after `extract_parsed_ir_from_ll` | new public entry | §6.3 |

### 10.2 `src/Bennett.jl` — source patches

| Patch | Location | Kind | Reference |
|---|---|---|---|
| Add two names to `export` | line 36 | additive | §2.5 |
| `reversible_compile(parsed::ParsedIR; …)` method | after line 93 (before `_narrow_ir`) | new method | §6.5 |

### 10.3 `test/` — test patches

| File | Change | Reference |
|---|---|---|
| `test/test_t5_corpus_c.jl` | flip 3× `@test_throws UndefVarError` to parse-OK + lower-throws-OK | §7.3 |
| `test/test_t5_corpus_rust.jl` | flip 3× `@test_throws UndefVarError` to parse-OK + lower-throws-OK | §7.3 |
| `test/test_p5a_unit.jl` | new — hand-written `.ll`, 256 sweep, reversibility | §7.1 |
| `test/test_p5a_equivalence.jl` | new — 5 programs × Julia vs `.ll` parsed-IR equality | §7.2 |
| `test/test_p5a_errors.jl` | new — 6 fail-loud contracts | §7.4 |
| `test/runtests.jl` | `include("test_p5a_unit.jl")` + `_equivalence` + `_errors` | — |

### 10.4 `test/fixtures/rust/README.md` — doc patch (non-code)

Append a short note documenting the `#[no_mangle]` convention that the
fixtures already use:

```
## Entry-function names and #[no_mangle]

Every Rust fixture defines its entry function as
`#[no_mangle] pub fn <name>(…) -> …`. Without `#[no_mangle]` the
LLVM-level name would be Rust's mangled form (`_ZN…E`), which the T5
corpus's `entry_function="…"` cannot match.

If you add a new Rust fixture, keep this convention to preserve the
exact-match contract that `extract_parsed_ir_from_ll` expects (see
docs/design/p5_proposer_A.md §5).
```

### 10.5 Implementer sequence (recommended red-green rhythm)

Per CLAUDE.md §3 (RED-GREEN TDD) and §8 (fast feedback):

1. **Confirm RED**: run the corpus tests once; verify all six
   `@test_throws UndefVarError` PASS on the current HEAD.
2. **Add unit / equivalence / errors tests** from §7.1–§7.4 to `test/`.
   Run `julia --project test/test_p5a_unit.jl` — all three RED.
3. **Land the refactor** (`_find_entry_function`, `_module_to_parsed_ir`
   split). Run full test suite — byte-identical baselines preserved.
4. **Land `_extract_from_module` + `extract_parsed_ir_from_ll`**. Run
   `test_p5a_unit.jl` — GREEN. Run `test_p5a_equivalence.jl` — GREEN.
   Run `test_p5a_errors.jl` — GREEN on the 4 `.ll` cases.
5. **Land `reversible_compile(::ParsedIR)` overload**. Re-run
   `test_p5a_unit.jl` (uses the overload) — GREEN.
6. **Land `extract_parsed_ir_from_bc`**. Run the two `.bc` cases in
   `test_p5a_errors.jl` — GREEN.
7. **Flip the corpus tests** (`test_t5_corpus_c.jl`,
   `test_t5_corpus_rust.jl`) per §7.3. Run them — parse-OK GREEN,
   lower-throws-OK GREEN.
8. **Full suite + benchmark spot-check**. Run `Pkg.test()` + verify the
   WORKLOG baselines (§8.1) are byte-identical.
9. **WORKLOG + commit**. CLAUDE.md §0 mandatory.

---

## 11. Summary — why this design

- **Split, don't branch**: `_module_to_parsed_ir` splits into a locator
  dispatcher + a pre-located core walker. Zero-behaviour-change default
  preserves every existing gate-count baseline byte-for-byte (§8).
- **Exact entry-function match**: simplest correct rule; fails loud
  with a name listing when the match misses. No demangling magic in
  MVP (§5). Rust fixtures use `#[no_mangle]` (a one-line convention,
  documented in the fixtures README).
- **Textual and bitcode paths share `_extract_from_module`**: 90% of
  the logic is identical; the two entry points differ only in the
  LLVM.jl parser they call (`parse(::Type{Module}, ::String)` vs
  `parse(::Type{Module}, ::MemoryBuffer)`). The bitcode symbol is
  verified at `src/core/module.jl:215-227`; it wraps
  `LLVM.API.LLVMParseBitcodeInContext2`.
- **`ParsedIR` is context-free**: every field is a pure Julia type;
  `dispose(mod)` after extraction is safe. This was already implicit in
  `extract_parsed_ir(f, T)` and is preserved (§8.3).
- **`reversible_compile(::ParsedIR)` overload is tiny**: `lower |>
  bennett`, plus a `:tabulate` rejection. 17 lines. Enables the
  corpus's `parsed = …; c = reversible_compile(parsed)` pattern.
- **Fail-loud at every boundary**: file-not-found, malformed IR,
  entry-function-not-found (with name listing), entry-function-is-a-
  declaration. Per CLAUDE.md §1. No magic recovery.
- **Zero changes to `lower.jl`, `bennett.jl`, `ir_types.jl`**: scope is
  walled off to `ir_extract.jl` + a 17-line overload in `Bennett.jl`
  + corpus test flips. Small diff, small blast radius, small review
  burden.
- **Regression safety is structural**, not empirical: the walker body
  is unchanged; only the entry-selection step acquires an (optional)
  kwarg. Every path that previously produced `ParsedIR(X)` still
  produces `ParsedIR(X)`.
