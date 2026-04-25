# T5-P5a / T5-P5b Proposer B — `.ll` / `.bc` ingest via LLVM.jl memory buffer

*Bennett-lmkb (P5a) + Bennett-f2p9 (P5b). Proposer B, independent design.*

---

## 1. Context

The Bennett compiler today has exactly one ingest path: `extract_parsed_ir(f,
arg_types)` at `src/ir_extract.jl:41–81`. That function calls Julia's
`InteractiveUtils.code_llvm(...; dump_module=true)` to produce an IR *string*,
parses it with `Base.parse(LLVM.Module, ir_string)` (line 68), runs optional
New-PM passes, then hands the `LLVM.Module` to `_module_to_parsed_ir(mod)`
(`src/ir_extract.jl:472–634`) which walks it via the typed LLVM.jl API and
builds a `ParsedIR`.

T5 (`Bennett-Memory-T5-PRD.md`) needs the same pipeline driven from two
additional sources:

- **T5-P5a (Bennett-lmkb):** a raw textual `.ll` file produced by an external
  toolchain (clang, rustc) rather than by Julia. Test fixtures already exist
  (`test/fixtures/c/t5_tc{1,2,3}.c`, `test/fixtures/rust/t5_tr{1,2,3}.rs`) and
  drive RED tests in `test/test_t5_corpus_c.jl` + `test/test_t5_corpus_rust.jl`
  that throw `UndefVarError: extract_parsed_ir_from_ll`.
- **T5-P5b (Bennett-f2p9):** the bitcode (`.bc`) analogue — same pipeline,
  different parser.

Both need a way to select an entry function by *name* (e.g. `"malloc_idx_inc"`,
`"vec_push_sum"`) because a clang-emitted `.ll` is a translation unit that
may contain many functions, and none of them start with `julia_`. And the
existing `_module_to_parsed_ir(mod)` hard-codes `startswith(LLVM.name(f),
"julia_")` at line 478.

A third artefact is needed to make the tests themselves useful: a
`reversible_compile(::ParsedIR)` overload that skips extraction. Every corpus
test writes `parsed = extract_parsed_ir_from_ll(...); c =
reversible_compile(parsed)`, and that second call has no function to inspect —
only a ParsedIR.

This proposal covers all three, plus the refactor to `_module_to_parsed_ir`
that makes entry-function selection parametric without breaking any
Julia-driven caller.

Ground truth consulted (quoted / paraphrased, no hallucination):

1. `CLAUDE.md` §1 (fail-loud), §2 (3+1 you-are-half), §3 (red-green), §5 (LLVM
   instability), §6 (gate-count baselines are regression tests), §7 (bugs are
   interlocked), §10 (skepticism), §11 (PRD-driven), §12 (no duplicated
   lowering).
2. `src/ir_extract.jl:41–81` — canonical string-path entry.
3. `src/ir_extract.jl:472–634` — module walker (sret detection, pass 1 name
   table, pass 2 block conversion, const-globals extraction, switch expansion).
4. `src/Bennett.jl:51–93` — canonical `reversible_compile(f, arg_types)` body.
5. `src/ir_types.jl:167–209` — `ParsedIR` definition and auxiliary
   constructors. Four fields are concrete value types (`Int`,
   `Vector{Tuple{Symbol,Int}}`, `Vector{IRBasicBlock}`, `Vector{Int}`), one is
   a concrete `Dict` of value types, one is `memssa::Any`, and one is a cache
   vector of `IRInst` (all concrete sub-types). **No LLVMRefs live in
   `ParsedIR`**, confirmed field-by-field — important for the context-lifetime
   argument in §6 below.
6. `~/.julia/packages/LLVM/fEIbx/src/core/module.jl:188–203` — `Base.parse(::Type{LLVM.Module},
   ir::String)`: wraps string as memory buffer (no copy), calls
   `API.LLVMParseIRInContext(context(), membuf, out_ref, out_error)`, throws
   `LLVMException` on failure.
7. `~/.julia/packages/LLVM/fEIbx/src/core/module.jl:216–238` — two bitcode-parse
   methods: `parse(::Type{Module}, ::MemoryBuffer)` calls
   `API.LLVMParseBitcodeInContext2` at line 223; `parse(::Type{Module},
   ::Vector)` wraps a `Vector{UInt8}`/`Vector{Int8}` as a buffer and delegates
   to the first.
8. `~/.julia/packages/LLVM/fEIbx/src/buffer.jl:51–63` — `MemoryBufferFile(path::String)`
   calls `API.LLVMCreateMemoryBufferWithContentsOfFile` and throws
   `LLVMException` on I/O failure. Works for both text and binary files.
9. `~/.julia/packages/LLVM/fEIbx/src/core/value/constant.jl:779–783` —
   `isdeclaration(val::GlobalValue)` is the canonical check for
   declaration-only functions. Used in place of `isempty(LLVM.blocks(f))`
   (which also works but is less idiomatic).
10. `~/.julia/packages/LLVM/fEIbx/src/core/value/constant.jl:790` —
    `linkage(val::GlobalValue)` → `API.LLVMGetLinkage`, useful for
    error-message diagnostics when a function is declaration-only.
11. `docs/design/cc07_consensus.md` + `cc04_consensus.md` — doc style
    template (problem → design → decision table → test plan → regression →
    forward-compat → checklist).
12. `WORKLOG.md` — gate-count baselines (cited in §8 below).

---

## 2. API surface

Two new public entry points plus one overload.

### 2.1 `extract_parsed_ir_from_ll`

```julia
extract_parsed_ir_from_ll(path::AbstractString;
                          entry_function::String,
                          preprocess::Bool=false,
                          passes::Union{Nothing,Vector{String}}=nothing,
                          use_memory_ssa::Bool=false) -> ParsedIR
```

Reads a textual LLVM IR file at `path`, parses it, selects the function named
`entry_function`, runs the same walker as `extract_parsed_ir(f, T)`, returns
a `ParsedIR` structurally-equal to the Julia-driven path.

### 2.2 `extract_parsed_ir_from_bc`

```julia
extract_parsed_ir_from_bc(path::AbstractString;
                          entry_function::String,
                          preprocess::Bool=false,
                          passes::Union{Nothing,Vector{String}}=nothing,
                          use_memory_ssa::Bool=false) -> ParsedIR
```

Identical shape; reads binary LLVM bitcode.

### 2.3 Kwarg rationale (kept / dropped)

| kwarg | kept? | rationale |
|---|---|---|
| `entry_function::String` | **required** | No implicit heuristic — clang/rustc don't prefix with `julia_`. Fail-loud on missing/ambiguous (§5). |
| `preprocess::Bool=false` | kept | Same semantics as the Julia path: runs `DEFAULT_PREPROCESSING_PASSES` (`sroa`, `mem2reg`, `simplifycfg`, `instcombine`) on the parsed module. External IR from clang `-O0` has plenty of allocas, so this is actually *more* useful here than for Julia IR. |
| `passes::Union{Nothing,Vector{String}}=nothing` | kept | Exact parity with `extract_parsed_ir`. Downstream NPM pipeline is identical — it operates on an already-parsed `LLVM.Module`, origin-agnostic. |
| `use_memory_ssa::Bool=false` | kept | Same memssa capture path (`_run_memssa_on_ir(ir_string; preprocess)` — see §4.4 for why this still works for bitcode). |
| `optimize::Bool` | **dropped** | N/A: the IR is already compiled. There is no Julia-side `optimize` flag analogue to gate. The user controls optimization at `clang -O0/-O1/...` time, on disk, before handing the file to us. Adding a Julia-side `optimize` flag here would be a footgun — users would expect it to redo the llc-level optimisation, but our only handle is the NPM `passes` list. Keep surface minimal (CLAUDE.md §11). |
| `bit_width::Int` | **dropped** | This is a feature of the Julia path's `_narrow_ir` (`src/Bennett.jl:102`) — it narrows all widths for Julia functions written against `Int8`. External IR from clang/rustc was compiled with a specific target ABI already; narrowing arbitrary C/Rust IR has no sound semantics. Leave to a later tool. |

### 2.4 `reversible_compile(::ParsedIR)` overload

```julia
reversible_compile(parsed::ParsedIR;
                   max_loop_iterations::Int=0,
                   compact_calls::Bool=false,
                   add::Symbol=:auto,
                   mul::Symbol=:auto) -> ReversibleCircuit
```

Mirrors the `lower + bennett` tail of `reversible_compile(f, arg_types)`
(`src/Bennett.jl:91–92`). Drops `optimize` (IR is already parsed), `bit_width`
(no narrow step — ParsedIR widths are concrete), `strategy` (no `:tabulate`
path — tabulate needs a callable `f` to evaluate 2^W times; we have only
ParsedIR). Body:

```julia
function reversible_compile(parsed::ParsedIR;
                            max_loop_iterations::Int=0, compact_calls::Bool=false,
                            add::Symbol=:auto, mul::Symbol=:auto)
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul)
    return bennett(lr)
end
```

Four lines. No `_narrow_ir`, no `_tabulate_*`. Fail-fast on bogus `add`/`mul`
symbols is already done by `lower()` at `src/lower.jl:310–313`.

---

## 3. Refactoring `_module_to_parsed_ir`

Two feasible shapes, per the task statement:

- **(a)** Add a keyword argument: `_module_to_parsed_ir(mod; entry_function=nothing)`.
  Inside, `entry_function === nothing` → existing `startswith("julia_")`
  heuristic; otherwise exact-name lookup.
- **(b)** Split into two: `_find_julia_entry_function(mod) -> LLVM.Function`
  (preserves the current heuristic verbatim) and
  `_module_to_parsed_ir_on_func(mod, func) -> ParsedIR` (the body, parameterised
  on the function). Existing callers use
  `_module_to_parsed_ir_on_func(mod, _find_julia_entry_function(mod))`; the new
  `.ll`/`.bc` entries call `_module_to_parsed_ir_on_func(mod,
  _find_entry_by_name(mod, name))`.

**Pick (b).** Reasons, in descending weight:

1. **Minimum blast radius (CLAUDE.md §7: "bugs are deep and interlocked").**
   Shape (a) changes the signature of a function called from exactly one
   place today but semantically central to every Julia-driven test. If the
   new keyword's default-`nothing` path has the slightest behavioural drift
   — a different error message, a slightly different fallback when multiple
   `julia_` functions exist, a subtle ordering change — every one of the
   ~60 test files in `test/` is at risk. Shape (b) preserves the existing
   call site byte-for-byte; only the internal boundary moves. Baselines
   stay byte-identical by construction, not by inspection.
2. **Testability.** `_find_julia_entry_function` and `_find_entry_by_name` can
   be tested independently against a hand-rolled `LLVM.Module`. A single
   fused function with a `Union{Nothing,String}` kwarg is harder to test
   thoroughly.
3. **Readability.** The function-selection policy (which is where the
   interesting fail-loud logic lives — see §5) is separated from the walker.
4. **Forward compatibility.** T5-P5c (multi-entry-point inlining, if ever)
   can call `_module_to_parsed_ir_on_func` on each chosen function
   independently. Shape (a) would need another kwarg or a different signature.

### 3.1 Resulting internal API

```julia
# src/ir_extract.jl (after refactor)

# Existing callers: UNCHANGED signature, UNCHANGED body. It just delegates.
function _module_to_parsed_ir(mod::LLVM.Module)
    func = _find_julia_entry_function(mod)   # same heuristic, same error
    return _module_to_parsed_ir_on_func(mod, func)
end

# Extracted from the top of the old body (lines 476–486).
function _find_julia_entry_function(mod::LLVM.Module)
    for f in LLVM.functions(mod)
        if startswith(LLVM.name(f), "julia_") && !LLVM.isdeclaration(f)
            return f
        end
    end
    error(
        "ir_extract.jl: no julia_* function found in LLVM module (the " *
        "extractor expects code_llvm(...; dump_module=true) output with at " *
        "least one non-declaration `julia_` or `j_` function)")
end

# New: external entry selection. Fail-loud per §5.
function _find_entry_by_name(mod::LLVM.Module, name::String)
    # ... see §5 ...
end

# The walker — old body lines 487–633 verbatim. Takes the chosen func as input.
function _module_to_parsed_ir_on_func(mod::LLVM.Module, func::LLVM.Function)
    counter = Ref(0)

    # T1c.2: extract compile-time-constant global arrays so lower_var_gep! can
    # dispatch read-only lookups through QROM instead of a MUX-tree.
    globals = _extract_const_globals(mod)

    # Bennett-dv1z: detect sret calling convention. ...
    sret_info = _detect_sret(func)

    # ... everything from line 487 onwards, UNCHANGED ...
end
```

**Note on `isdeclaration(f)` vs `isempty(LLVM.blocks(f))`:** the old code
uses `isempty(LLVM.blocks(f))` at line 478. The canonical LLVM.jl check is
`LLVM.isdeclaration(f)` (`~/.julia/packages/LLVM/fEIbx/src/core/value/constant.jl:779`).
They are semantically identical for C/Rust-emitted IR: a function without a
body is declaration-only by definition. But the refactor **preserves the
original `isempty(...blocks(f))` form** in `_find_julia_entry_function` — no
gratuitous renames in the refactor that's supposed to move code, not edit it.
The new `_find_entry_by_name` uses `isdeclaration` because it's newer code and
the idiomatic check.

---

## 4. Bitcode API

### 4.1 LLVM.jl symbols verified

Cited with file:line from `~/.julia/packages/LLVM/fEIbx/`:

| Symbol | File:line | Role |
|---|---|---|
| `Base.parse(::Type{Module}, ir::String)` | `src/core/module.jl:188` | Parse textual IR. Calls `LLVMParseIRInContext`. |
| `Base.parse(::Type{Module}, ::MemoryBuffer)` | `src/core/module.jl:220` | Parse bitcode. Calls `LLVMParseBitcodeInContext2`. |
| `Base.parse(::Type{Module}, ::Vector)` | `src/core/module.jl:234` | Convenience: wraps `Vector{UInt8}/Int8` as buffer, parses bitcode. |
| `MemoryBuffer(::Vector{UInt8}, name, copy)` | `src/buffer.jl:24` | Wrap in-memory bytes. |
| `MemoryBufferFile(path::String)` | `src/buffer.jl:51` | Read a file into an LLVM `MemoryBuffer` via `LLVMCreateMemoryBufferWithContentsOfFile`. Throws `LLVMException` on I/O error. |
| `dispose(::MemoryBuffer)` | `src/buffer.jl:79` | Free the buffer. |
| `LLVM.Context() do ctx ... end` | `src/interop/base.jl:51, :95` | Scoped context, auto-disposes on block exit. |
| `LLVM.functions(mod)` | `src/core/module.jl` | Iterate functions in a module. (Already used at line 477 in `ir_extract.jl`.) |
| `LLVM.isdeclaration(f)` | `src/core/value/constant.jl:779` | Test whether a global value is declaration-only. |
| `LLVM.linkage(f)` | `src/core/value/constant.jl:790` | Retrieve linkage for diagnostics. |

**Decision: use `MemoryBufferFile(path)` for both `.ll` and `.bc`**, not
`read(path, String)` then `parse(Module, ::String)`. One uniform seam.

For `.ll`: `MemoryBufferFile` reads the file into an LLVM-owned buffer, then
`parse(::Type{LLVM.Module}, ::MemoryBuffer)` — *wait*. Let me re-verify.

Re-reading `~/.julia/packages/LLVM/fEIbx/src/core/module.jl:220–227` carefully:
the `parse(Module, ::MemoryBuffer)` method calls `LLVMParseBitcodeInContext2`
unconditionally. There is **no textual-IR overload on MemoryBuffer**. So for
`.ll` we cannot feed a `MemoryBufferFile` directly — it would be interpreted
as bitcode and fail.

**Correct shapes:**

- `.ll` path: `read(path, String)` → `parse(LLVM.Module, ::String)`. This is
  what `extract_parsed_ir` does today (line 68): `parse(LLVM.Module,
  ir_string)`. Reuse.
- `.bc` path: `MemoryBufferFile(path)` → `parse(LLVM.Module, ::MemoryBuffer)`.
  Must `dispose(membuf)` after (matching the pattern at module.jl:195).

Accepting `Vector{UInt8}` directly in `extract_parsed_ir_from_bc` is tempting
(one could add a method dispatching on `Vector{UInt8}`), but YAGNI — the T5
tests all want file paths. **Keep both functions path-only.** If in-memory
ingestion is ever needed, it's a trivial extension.

### 4.2 Text/bitcode sniffing — not needed

One might consider a single `extract_parsed_ir_from_file(path)` that sniffs
the first 4 bytes (bitcode magic: `BC\xc0\xde` = `0x42 0x43 0xc0 0xde`). **Do
not do this.** Reasons:

1. The file extension already tells the user what they have. Routing by
   extension conflates file naming with parse semantics in a way that invites
   bugs (what does `extract_parsed_ir_from_file("foo.txt")` do?).
2. Sniffing adds a failure mode (partial read, malformed header) that's
   invisible at the API level.
3. Two functions are easier to document, test, and fail-loud from.

Two functions. Explicit is better than implicit.

### 4.3 Bitcode is not guaranteed textual — memssa interaction

`extract_parsed_ir(f, T)` at `src/ir_extract.jl:59` computes memssa via
`_run_memssa_on_ir(ir_string; preprocess)`, which takes an IR *string*. For
bitcode ingest, we need a string first. Two options:

- **(a)** Parse the module, run `LLVM.string(mod)` to get textual IR, hand
  that to `_run_memssa_on_ir`. Works but round-trips through the string
  printer.
- **(b)** Teach `_run_memssa_on_ir` to accept `LLVM.Module` directly.

**Pick (a).** `_run_memssa_on_ir` is unrelated-and-complex code already
(T2a.2 scaffolding); refactoring it is out of scope for P5. The
round-trip cost is O(file size) once per extraction and only when
`use_memory_ssa=true` (which defaults to `false` everywhere — the memssa
path is experimental). If it becomes a perf issue later, that's a follow-on
bead.

### 4.4 Module context lifetime

The existing pattern (`src/ir_extract.jl:67–74`):

```julia
LLVM.Context() do _ctx
    mod = parse(LLVM.Module, ir_string)
    # ... optional passes ...
    result = _module_to_parsed_ir(mod)
    dispose(mod)
end
```

is preserved verbatim in both new entry points. The module is parsed inside
the context, walked (producing a `ParsedIR` built entirely from Julia value
types), disposed, and the context closes on `do`-block exit.

**Why `ParsedIR` is safe to return across the `do` boundary:** auditing
`src/ir_types.jl:167–209` field-by-field:

| `ParsedIR` field | Type | Any LLVMRefs? |
|---|---|---|
| `ret_width` | `Int` | no |
| `args` | `Vector{Tuple{Symbol, Int}}` | no |
| `blocks` | `Vector{IRBasicBlock}` → label::Symbol, insts::Vector{IRInst}, terminator::IRInst | Recurse: all `IRInst` subtypes use `Symbol` for destinations, `IROperand` (a struct of `Symbol`/`Int`) for operands. No `LLVMRef`. |
| `ret_elem_widths` | `Vector{Int}` | no |
| `globals` | `Dict{Symbol, Tuple{Vector{UInt64}, Int}}` | no — `_extract_const_globals` at line 646–678 converts via `LLVMConstIntGetZExtValue` to `UInt64` before storing. |
| `memssa` | `Any` (see `src/memssa.jl`) | need to check |
| `_instructions_cache` | `Vector{IRInst}` | no |

For `memssa`: `parse_memssa_annotations(...)` runs **outside** the main
`LLVM.Context() do` block (line 59–64 of current `extract_parsed_ir`). It
works on the printed annotated-IR string. Result is a Julia value with no
refs. Safe.

**Conclusion:** `ParsedIR` contains zero `LLVMRef`s once constructed. It
survives context teardown with no UAF risk. This isn't a new claim — the
existing `extract_parsed_ir` has always had this property, and the new
entry points inherit it by calling the same walker on the same types.

---

## 5. Function-selection policy — decision table

`_find_entry_by_name(mod::LLVM.Module, name::String) -> LLVM.Function` must
handle every reasonable shape and fail loud otherwise.

| Scenario | Input state | Behaviour | Error message |
|---|---|---|---|
| **Exact match, has body** | One `f` in `LLVM.functions(mod)` with `LLVM.name(f) == name` and `!LLVM.isdeclaration(f)` | Return `f` | — |
| **Name not present** | No `f` with that name | `error(...)` | List available candidates (first 20, alphabetised) |
| **Declaration only** | Exactly one `f` matches but has no body | `error(...)` | Cite linkage; suggest the user compiled without the definition (external link-time symbol) |
| **Multiple exact matches** | >1 function with that name in the module | `error(...)` | List them with their linkages; abort |
| **Rust-mangled mismatch** | User passed `"vec_push_sum"`, module contains `"_ZN7lib_tr11vec_push_sum17hABCDEF0123456789E"` | `error(...)` | Suggest user pass the mangled form; list the near-matches containing the substring |

### 5.1 Rust mangling — fail loud, do not auto-substring

This is a deliberate design choice. There are two ways to handle the Rust
case:

**(i) Substring fallback:** if exact-match fails, look for any function name
*containing* `name` (or `name` as a delimited token, e.g. between `::` in the
Rust mangling scheme). Return that function, perhaps with a warning.

**(ii) Fail loud with a hint.** Report candidates; require the user to pass
the mangled form (or use `#[no_mangle]` in the Rust fixture).

**Pick (ii).** Reasons, in decreasing weight:

1. **CLAUDE.md §1 and §10: fail fast, fail loud; skepticism.** Substring
   matching is a silent dispatch that can misfire. Rust mangles `foo` and
   `fooExt` into different mangled symbols; a substring match on `"foo"`
   could pick either. A compiler with silent name resolution is a compiler
   with silent correctness bugs.
2. **User action is trivial.** The Rust fixtures in
   `test/fixtures/rust/t5_tr*.rs` can be annotated with `#[no_mangle] pub
   extern "C" fn vec_push_sum(...)`. This is already the idiomatic way to
   expose a Rust function for external linking. Adjusting fixtures is a
   one-line change.
3. **Future-proofing.** If a substring fallback is ever needed, it can be
   added as a separate helper or kwarg (`require_exact=false`). Adding
   surface later is always safer than removing it.

The error message for the Rust case must be **helpful**, listing
near-matches. Users of the Rust fixtures should get a message like:

```
extract_parsed_ir_from_ll: entry_function \"vec_push_sum\" not found in
<path>. Did you forget to annotate the Rust fixture with
#[no_mangle]? Candidates containing 'vec_push_sum':
    _ZN9t5_tr1_vec_push12vec_push_sum17h1234567890abcdefE
    (if more than 5, truncated; 17 total)
```

Code sketch (see §7 for the full listing):

```julia
function _find_entry_by_name(mod::LLVM.Module, name::String)
    matches = LLVM.Function[]
    all_names = String[]
    for f in LLVM.functions(mod)
        fname = LLVM.name(f)
        push!(all_names, fname)
        if fname == name
            push!(matches, f)
        end
    end

    if length(matches) == 0
        # Look for substring near-matches for a helpful hint
        near = filter(n -> occursin(name, n), all_names)
        hint = if isempty(near)
            candidate_list = join(first(sort(all_names), 20), "\n    ")
            "No near-matches. Available functions (first 20 alphabetical):\n    $candidate_list"
        else
            "Near-matches (substring containing \"$name\"):\n    " *
            join(first(near, 10), "\n    ") *
            "\nIf the intended target is a Rust symbol, either (a) pass the " *
            "full mangled form, or (b) annotate the Rust source with " *
            "#[no_mangle] and recompile."
        end
        error("ir_extract.jl: entry_function \"$name\" not found in module.\n" * hint)
    elseif length(matches) > 1
        linkages = ["  $(LLVM.name(f)) (linkage=$(LLVM.linkage(f)))" for f in matches]
        error("ir_extract.jl: entry_function \"$name\" is ambiguous — " *
              "$(length(matches)) functions match:\n" * join(linkages, "\n"))
    end

    f = matches[1]
    if LLVM.isdeclaration(f)
        error("ir_extract.jl: entry_function \"$name\" is declaration-only " *
              "(no body). linkage=$(LLVM.linkage(f)). The source IR must " *
              "contain the function definition, not just its declaration.")
    end
    return f
end
```

### 5.2 What about LLVMContextDiagnostic / silent parse failure?

`LLVMParseBitcodeInContext2` does not use the error-out parameter pattern;
the docstring at `src/core/module.jl:224` says "caught by diagnostics handler"
via `@assert !status`. If the bitcode is malformed, the parse fails and Julia
raises the assertion. That's a fail-loud path; no special handling required
beyond our own validation after `parse()` returns.

For textual IR, `parse(Module, ::String)` calls `LLVMParseIRInContext` which
does populate `out_error` and throws `LLVMException` on failure (module.jl:188–203).
That's already caught by the implicit error path.

### 5.3 File-not-found is explicit

Both entry points check `isfile(path)` up front and emit a Bennett-flavoured
error instead of letting the LLVM layer's `LLVMCreateMemoryBufferWithContentsOfFile`
raise a less-legible `LLVMException`. See §7.

---

## 6. Regression guarantee — why existing tests stay byte-identical

Claim: **every currently-GREEN gate-count baseline stays byte-identical after
this refactor.**

Argument:

1. `extract_parsed_ir(f, arg_types; kwargs...)` signature is unchanged. Its
   body calls `_module_to_parsed_ir(mod)` at line 72 with an unchanged
   signature.
2. `_module_to_parsed_ir(mod)` is refactored to delegate to
   `_find_julia_entry_function(mod)` + `_module_to_parsed_ir_on_func(mod,
   f)`. The two delegated helpers together have a body that is **verbatim
   the old `_module_to_parsed_ir(mod)`** — no semantic change, just a
   boundary moved.
3. `reversible_compile(f, arg_types; ...)` is unchanged. The new
   `reversible_compile(::ParsedIR; ...)` is a new method dispatching on a
   different argument type; it cannot affect any existing call site.
4. `lower(::ParsedIR; ...)` and `bennett(...)` are untouched.
5. The LLVM.jl pass-pipeline (`_run_passes!`) is untouched.
6. The `_extract_const_globals` call order inside the walker is preserved
   (same line number in the moved body).

Therefore the gate graph for any Julia-driven compilation is the exact same
walk over the exact same IR, producing the exact same ParsedIR, producing the
exact same lowered circuit, producing the exact same Bennett expansion.

**Baselines that must stay byte-identical** (cited from `WORKLOG.md`):

| Test / fixture | Baseline gate count |
|---|---|
| `soft_fptrunc` | 36,474 |
| `popcount32` | 2,782 |
| HAMT roundtrip | 96,788 |
| CF pmap | 11,078 |
| CF + Feistel | 65,198 |
| i8 add | 98 (from WORKLOG; PRD v0.5 cites 86 pre-Feistel baseline — either way, whichever number is current stays current) |
| i16 add | 202 |
| i32 add | 410 |
| i64 add | 826 |
| TJ3 | 180 |
| ls_demo_16 | 5,218 |

All land on the same walker. No change in output.

The only new Julia-facing artefact is that `reversible_compile(::ParsedIR)`
now exists. It skips `_narrow_ir` and the `:tabulate` strategy. It is only
called from the new corpus tests. Existing callers continue to use
`reversible_compile(f, arg_types)`, which dispatches on a `Function`, not
`ParsedIR`.

### 6.1 Equivalence contract: `extract_parsed_ir(f, T)` ≡ `extract_parsed_ir_from_ll(llfile(f, T))`

Let `llfile(f, T) = sprint(io -> code_llvm(io, f, T; debuginfo=:none,
optimize=true, dump_module=true))` written to a temporary file. Define:

```julia
ir_a = extract_parsed_ir(f, T)                            # string-path
ir_b = extract_parsed_ir_from_ll(llfile(f, T);
           entry_function=_guess_julia_entry_name(f, T))  # file-path
```

Claim: `ir_a == ir_b`.

Two things to check:

1. **Julia value equality on `ParsedIR` fields.** Julia's `==` on mutable
   structs is ref-equality by default, **but** `ParsedIR` is `struct`
   (immutable), so default `==` is fieldwise. Immutable `IRBasicBlock`,
   `IRInst` subtypes, `IROperand`, `Symbol`, `Int`, `Dict`, `Vector` all
   have sensible `==`. For `Any`-typed `memssa`, when both sides are
   `nothing` (default), equality holds trivially. When both are populated
   via `parse_memssa_annotations`, equality depends on that module's
   semantics — out of scope for the equivalence test (ignore or exclude
   from comparison).
2. **Name determinism.** The walker mints SSA names from LLVM names
   (lines 556–557: `isempty(nm) ? _auto_name(counter) : Symbol(nm)`). The
   `_auto_name(counter)` counter is reset at the top of
   `_module_to_parsed_ir_on_func` (`counter = Ref(0)`). Same module → same
   walk order → same auto-names → same ParsedIR.

**Wrinkle: different module shapes.** When `dump_module=true` is used in
`extract_parsed_ir(f, T)`, the entire Julia IR module (including declarations
of runtime helpers, globals, etc.) is emitted. When that string is parsed
back via the `.ll` path, the module contains *exactly* the same bytes, so
the walker sees the same functions in the same order. Exact byte-equality.

**Potential pitfall.** Julia's `code_llvm(..., optimize=true)` output includes
`target triple` and `target datalayout` lines tied to the current host. Those
affect the LLVM.jl module layout slightly but not the walker (which only
reads `LLVM.function_type`, `LLVM.parameters`, etc.). Safe.

**Test implementation.** `test/test_p5a_equivalence.jl` writes `code_llvm`
output to a temp file and compares ParsedIRs using a helper:

```julia
function parsed_ir_equal(a::ParsedIR, b::ParsedIR; ignore_memssa::Bool=true)
    a.ret_width      == b.ret_width      || return false
    a.args           == b.args           || return false
    a.ret_elem_widths == b.ret_elem_widths || return false
    a.globals        == b.globals        || return false
    length(a.blocks) == length(b.blocks) || return false
    for (ba, bb) in zip(a.blocks, b.blocks)
        ba.label == bb.label || return false
        length(ba.instructions) == length(bb.instructions) || return false
        all(x == y for (x, y) in zip(ba.instructions, bb.instructions)) || return false
        ba.terminator == bb.terminator || return false
    end
    ignore_memssa || (a.memssa == b.memssa || return false)
    return true
end
```

---

## 7. Implementation sketch — full listing

All changes in `src/ir_extract.jl` (four new/refactored helpers) and
`src/Bennett.jl` (one new method + export). No other files touched.

### 7.1 `src/ir_extract.jl` additions

Inserted **after** the existing `_run_passes!` helper (`src/ir_extract.jl:92`),
**before** the `_known_callees` block:

```julia
# ---- Entry-function selection (T5-P5a / T5-P5b Bennett-lmkb / Bennett-f2p9) ----

"""
    _find_julia_entry_function(mod::LLVM.Module) -> LLVM.Function

Locate the Julia-emitted entry function in `mod`. Used by `extract_parsed_ir(f,
arg_types)`. Selects the first function whose name starts with `julia_` and
has at least one basic block. Fails loud if none is found.

This is the pre-refactor heuristic, extracted verbatim from the old top of
`_module_to_parsed_ir`.
"""
function _find_julia_entry_function(mod::LLVM.Module)
    for f in LLVM.functions(mod)
        if startswith(LLVM.name(f), "julia_") && !isempty(LLVM.blocks(f))
            return f
        end
    end
    error(
        "ir_extract.jl: no julia_* function found in LLVM module (the " *
        "extractor expects code_llvm(...; dump_module=true) output with at " *
        "least one non-declaration `julia_` or `j_` function)")
end

"""
    _find_entry_by_name(mod::LLVM.Module, name::String) -> LLVM.Function

Locate a function by exact name. Used by `extract_parsed_ir_from_ll` and
`extract_parsed_ir_from_bc` for multi-language IR ingest (clang, rustc, etc.).
Fail-loud on absent, ambiguous, or declaration-only matches. Provides a
helpful hint with near-matches when the name is not found (common for Rust's
mangled symbols — advise `#[no_mangle]` or pass the mangled form).
"""
function _find_entry_by_name(mod::LLVM.Module, name::String)
    matches = LLVM.Function[]
    all_names = String[]
    for f in LLVM.functions(mod)
        fname = LLVM.name(f)
        push!(all_names, fname)
        fname == name && push!(matches, f)
    end

    if isempty(matches)
        near = filter(n -> occursin(name, n), all_names)
        hint = if isempty(near)
            sorted = sort(all_names)
            k = min(20, length(sorted))
            lst = join(sorted[1:k], "\n    ")
            "No near-matches. Available functions (first $k alphabetical):\n    $lst"
        else
            k = min(10, length(near))
            head = join(near[1:k], "\n    ")
            "Near-matches (names containing \"$name\"):\n    $head\n" *
            "If the intended target is a Rust symbol, either (a) pass the " *
            "full mangled form, or (b) annotate the Rust source with " *
            "#[no_mangle] and recompile."
        end
        error("ir_extract.jl: entry_function \"$name\" not found in " *
              "module.\n$hint")
    elseif length(matches) > 1
        lst = join(("  $(LLVM.name(f)) (linkage=$(LLVM.linkage(f)))"
                    for f in matches), "\n")
        error("ir_extract.jl: entry_function \"$name\" is ambiguous — " *
              "$(length(matches)) functions match:\n$lst")
    end

    f = matches[1]
    if LLVM.isdeclaration(f)
        error("ir_extract.jl: entry_function \"$name\" is declaration-only " *
              "(no body). linkage=$(LLVM.linkage(f)). The source IR must " *
              "contain the function definition, not just its declaration.")
    end
    return f
end

"""
    extract_parsed_ir_from_ll(path::AbstractString;
                              entry_function::String,
                              preprocess::Bool=false,
                              passes::Union{Nothing,Vector{String}}=nothing,
                              use_memory_ssa::Bool=false) -> ParsedIR

Parse a textual LLVM IR file at `path` and extract a `ParsedIR` for the
function named `entry_function`. Mirrors the Julia-driven `extract_parsed_ir(f,
arg_types)` path, minus the `optimize` kwarg (IR is already compiled on
disk) and minus the `bit_width` narrowing (external ABIs are fixed).

Fails loud on file-not-found, parse errors, and any of the entry-function
lookup scenarios in `_find_entry_by_name`.

T5-P5a (Bennett-lmkb).
"""
function extract_parsed_ir_from_ll(path::AbstractString;
                                   entry_function::String,
                                   preprocess::Bool=false,
                                   passes::Union{Nothing,Vector{String}}=nothing,
                                   use_memory_ssa::Bool=false)
    isfile(path) || error(
        "extract_parsed_ir_from_ll: file not found: $path")

    ir_string = read(path, String)
    return _extract_from_parsed_ir_string(ir_string;
        entry_function, preprocess, passes, use_memory_ssa)
end

"""
    extract_parsed_ir_from_bc(path::AbstractString;
                              entry_function::String,
                              preprocess::Bool=false,
                              passes::Union{Nothing,Vector{String}}=nothing,
                              use_memory_ssa::Bool=false) -> ParsedIR

Parse an LLVM bitcode (`.bc`) file at `path` and extract a `ParsedIR` for the
function named `entry_function`. Behaviour matches
`extract_parsed_ir_from_ll` except for the parser.

T5-P5b (Bennett-f2p9).
"""
function extract_parsed_ir_from_bc(path::AbstractString;
                                   entry_function::String,
                                   preprocess::Bool=false,
                                   passes::Union{Nothing,Vector{String}}=nothing,
                                   use_memory_ssa::Bool=false)
    isfile(path) || error(
        "extract_parsed_ir_from_bc: file not found: $path")

    # Convert bitcode → textual IR string once, then share the text-path
    # extraction. This keeps a single authoritative code path for the walker,
    # the memssa annotation pass, and the context lifetime, at the cost of
    # one round-trip through LLVM.string(mod) per bitcode ingest.
    local ir_string::String
    LLVM.Context() do _ctx
        membuf = LLVM.MemoryBufferFile(path)
        try
            mod = parse(LLVM.Module, membuf)
            try
                ir_string = LLVM.string(mod)
            finally
                dispose(mod)
            end
        finally
            dispose(membuf)
        end
    end

    return _extract_from_parsed_ir_string(ir_string;
        entry_function, preprocess, passes, use_memory_ssa)
end

# Shared tail for both P5a and P5b. Parses `ir_string`, runs optional passes,
# selects the entry function by name, walks the module. Matches the `LLVM.Context
# do ... dispose(mod)` discipline of `extract_parsed_ir`.
function _extract_from_parsed_ir_string(ir_string::String;
                                        entry_function::String,
                                        preprocess::Bool,
                                        passes::Union{Nothing,Vector{String}},
                                        use_memory_ssa::Bool)
    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
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
            # Re-raise with our own cite, so the caller sees an
            # ir_extract.jl-flavoured message.
            rethrow(ErrorException(
                "ir_extract.jl: failed to parse LLVM IR (T5-P5a/P5b): " *
                sprint(showerror, e)))
        end
        if !isempty(effective_passes)
            _run_passes!(mod, effective_passes)
        end
        func = _find_entry_by_name(mod, entry_function)
        result = _module_to_parsed_ir_on_func(mod, func)
        dispose(mod)
    end
    if memssa !== nothing
        result = ParsedIR(result.ret_width, result.args, result.blocks,
                          result.ret_elem_widths, result.globals, memssa)
    end
    return result
end
```

Replace the existing `_module_to_parsed_ir(mod)` body (lines 472–634) with:

```julia
function _module_to_parsed_ir(mod::LLVM.Module)
    func = _find_julia_entry_function(mod)
    return _module_to_parsed_ir_on_func(mod, func)
end

function _module_to_parsed_ir_on_func(mod::LLVM.Module, func::LLVM.Function)
    counter = Ref(0)

    # T1c.2: extract compile-time-constant global arrays so lower_var_gep! can
    # dispatch read-only lookups through QROM instead of a MUX-tree.
    globals = _extract_const_globals(mod)

    # Bennett-dv1z: detect sret calling convention. ...
    sret_info = _detect_sret(func)

    # ... VERBATIM body from old lines 496–633 ...
end
```

### 7.2 `src/Bennett.jl` additions

Immediately after the `reversible_compile(f, arg_types::Type{<:Tuple}; ...)`
method at line 93, add:

```julia
"""
    reversible_compile(parsed::ParsedIR; ...) -> ReversibleCircuit

Compile a pre-extracted `ParsedIR` into a reversible circuit. Skips extraction;
runs `lower` + `bennett` only. Used by T5 corpus tests that ingest IR from
external toolchains via `extract_parsed_ir_from_ll` / `extract_parsed_ir_from_bc`.

No `optimize` kwarg (IR is already parsed), no `bit_width` (narrowing requires
a Julia callable), no `strategy` (`:tabulate` needs a callable `f`).
"""
function reversible_compile(parsed::ParsedIR;
                            max_loop_iterations::Int=0,
                            compact_calls::Bool=false,
                            add::Symbol=:auto,
                            mul::Symbol=:auto)
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul)
    return bennett(lr)
end
```

And update the existing export line (line 36):

```julia
export reversible_compile, simulate, extract_ir, parse_ir, extract_parsed_ir,
       extract_parsed_ir_from_ll, extract_parsed_ir_from_bc, register_callee!
```

(Splitting onto two lines for readability; no semantic change.)

### 7.3 Test files

Four new test files; two existing test files updated.

#### `test/test_p5a_ll_ingest.jl` (new)

```julia
using Test
using Bennett

# T5-P5a — textual .ll ingest via LLVM.jl. Hand-rolled minimal fixture.
# A single function `add_const(i8) -> i8` that returns x + 3.
# Verifies the full extract-from-string path end-to-end without any C or
# Rust toolchain dependency.

@testset "T5-P5a — .ll ingest" begin
    ll = """
    define i8 @add_const(i8 %x) {
    entry:
      %r = add i8 %x, 3
      ret i8 %r
    }
    """
    path = tempname() * ".ll"
    write(path, ll)
    try
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="add_const")
        @test parsed.ret_width == 8
        @test length(parsed.args) == 1
        @test parsed.args[1][2] == 8     # i8 input

        c = reversible_compile(parsed)
        for x in typemin(Int8):typemax(Int8)
            expected = Int8(x + Int8(3))
            @test simulate(c, Int8(x)) == expected
        end
        @test verify_reversibility(c; n_tests=3)
    finally
        isfile(path) && rm(path)
    end

    # Fail-loud: wrong entry_function name
    @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
        path; entry_function="not_there")

    # Fail-loud: file-not-found
    @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
        tempname() * "_missing.ll"; entry_function="add_const")
end
```

#### `test/test_p5a_equivalence.jl` (new)

```julia
using Test
using Bennett
using InteractiveUtils: code_llvm

# T5-P5a — byte-structural equivalence.
# For a Julia function f, extract_parsed_ir(f, T) and
# extract_parsed_ir_from_ll(tempfile_of(code_llvm(f,T))) must produce
# structurally-equal ParsedIRs.

function _parsed_ir_equal(a::ParsedIR, b::ParsedIR)
    a.ret_width == b.ret_width || return false
    a.args == b.args || return false
    a.ret_elem_widths == b.ret_elem_widths || return false
    a.globals == b.globals || return false
    length(a.blocks) == length(b.blocks) || return false
    for (ba, bb) in zip(a.blocks, b.blocks)
        ba.label == bb.label || return false
        length(ba.instructions) == length(bb.instructions) || return false
        for (ia, ib) in zip(ba.instructions, bb.instructions)
            ia == ib || return false
        end
        ba.terminator == bb.terminator || return false
    end
    return true
end

function _julia_entry_name(f, T)
    # Mirror _find_julia_entry_function: scan the module and return the first
    # julia_-prefixed function name.
    ir = sprint(io -> code_llvm(io, f, T; debuginfo=:none, dump_module=true))
    for line in eachsplit(ir, '\n')
        m = match(r"^define [^@]*@(julia_[A-Za-z0-9_]+)\b", line)
        m !== nothing && return String(m.captures[1])
    end
    error("no julia_ function found in IR")
end

@testset "T5-P5a — equivalence with extract_parsed_ir(f, T)" begin
    cases = [
        (x -> x + Int8(3),              Tuple{Int8}),
        (x -> (x * Int8(2)) + Int8(1), Tuple{Int8}),
        ((a, b) -> a + b,               Tuple{Int8, Int8}),
    ]
    for (f, T) in cases
        ir = sprint(io -> code_llvm(io, f, T; debuginfo=:none, dump_module=true))
        path = tempname() * ".ll"
        write(path, ir)
        try
            entry = _julia_entry_name(f, T)
            ir_a = extract_parsed_ir(f, T; optimize=true)
            ir_b = Bennett.extract_parsed_ir_from_ll(
                path; entry_function=entry)
            @test _parsed_ir_equal(ir_a, ir_b)
        finally
            isfile(path) && rm(path)
        end
    end
end
```

#### `test/test_p5b_bc_ingest.jl` (new)

```julia
using Test
using Bennett
using LLVM

# T5-P5b — bitcode ingest. Emits bitcode via LLVM.jl's convert(Vector, mod)
# path, writes to disk, parses back through extract_parsed_ir_from_bc.

@testset "T5-P5b — .bc ingest" begin
    ll = """
    define i8 @add_const(i8 %x) {
    entry:
      %r = add i8 %x, 5
      ret i8 %r
    }
    """

    bc_path = tempname() * ".bc"
    try
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ll)
            try
                bytes = convert(Vector{UInt8}, mod)  # LLVMWriteBitcodeToMemoryBuffer
                write(bc_path, bytes)
            finally
                dispose(mod)
            end
        end

        parsed = Bennett.extract_parsed_ir_from_bc(bc_path; entry_function="add_const")
        @test parsed.ret_width == 8
        @test length(parsed.args) == 1

        c = reversible_compile(parsed)
        for x in typemin(Int8):typemax(Int8)
            expected = Int8(x + Int8(5))
            @test simulate(c, Int8(x)) == expected
        end
        @test verify_reversibility(c; n_tests=3)
    finally
        isfile(bc_path) && rm(bc_path)
    end

    # Fail-loud: path not found
    @test_throws ErrorException Bennett.extract_parsed_ir_from_bc(
        tempname() * "_missing.bc"; entry_function="add_const")
end
```

#### `test/test_p5_fail_loud.jl` (new)

Covers the ambiguous / declaration-only / near-match paths:

```julia
using Test
using Bennett

@testset "T5-P5 — fail-loud entry selection" begin
    # declaration-only: function present, no body
    ll_decl = """
    declare i8 @ext_fn(i8)
    """
    path = tempname() * ".ll"
    write(path, ll_decl)
    try
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="ext_fn")
    finally
        isfile(path) && rm(path)
    end

    # near-match hint: user asks for "foo", module has "foo_mangled"
    ll_near = """
    define i8 @foo_mangled(i8 %x) { ret i8 %x }
    """
    write(path, ll_near)
    try
        err = try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="foo")
            "no error"
        catch e
            sprint(showerror, e)
        end
        @test occursin("foo_mangled", err)
        @test occursin("Near-matches", err)
    finally
        isfile(path) && rm(path)
    end
end
```

#### `test/test_t5_corpus_c.jl` (updated)

The existing `@test_throws Union{UndefVarError,MethodError,ErrorException}`
lines stay, but the reason text is updated (the `UndefVarError` goes away once
P5a lands). The comment blocks in the file say the failure mode shifts from
"`UndefVarError`" to "hard-error inside the lowering pipeline" once P5a lands.
After P5 but before P6, the test expects `ErrorException` from the lowering
phase. The single-error test changes:

```julia
# Pre-P5a: @test_throws Union{UndefVarError,MethodError,ErrorException} …
# Post-P5a, pre-P6:
@test_throws ErrorException begin
    parsed = Bennett.extract_parsed_ir_from_ll(ll_out; entry_function="malloc_idx_inc")
    reversible_compile(parsed)   # dynamic n_elems not supported → T5-P6
end
```

Per CLAUDE.md §3: the RED marker stays RED, but the error class is now the
specific lowering error (not the stand-in `UndefVarError`). The commented-out
GREEN block is untouched; P6 unlocks it.

Same update to `test/test_t5_corpus_rust.jl`.

### 7.4 Implementer's checklist

1. **Edit `src/ir_extract.jl`:**
   - Add `_find_julia_entry_function`, `_find_entry_by_name`,
     `extract_parsed_ir_from_ll`, `extract_parsed_ir_from_bc`,
     `_extract_from_parsed_ir_string` (new helpers, after `_run_passes!`).
   - Refactor `_module_to_parsed_ir` into a 2-line delegator + extract body as
     `_module_to_parsed_ir_on_func`.
2. **Edit `src/Bennett.jl`:**
   - Add `reversible_compile(::ParsedIR; ...)` method.
   - Add the two new symbols to `export`.
3. **Add new tests:** `test/test_p5a_ll_ingest.jl`,
   `test/test_p5a_equivalence.jl`, `test/test_p5b_bc_ingest.jl`,
   `test/test_p5_fail_loud.jl`.
4. **Update the corpus tests:** adjust `@test_throws` narrowing to
   `ErrorException` (from the lowering pipeline); preserve the commented-out
   GREEN blocks.
5. **Register the new tests in `test/runtests.jl`.**
6. **Run full suite — all currently-GREEN tests must stay GREEN; all
   baselines byte-identical.**
7. **Update `WORKLOG.md`:** new baselines for `.ll`-ingested add_const (8 i8
   gates), .bc-ingested add_const (8 i8 gates — should match); equivalence-test
   gate counts for the 3 cases (same as their native Julia baselines).
8. **Commit + push + close beads Bennett-lmkb, Bennett-f2p9.**

---

## 8. Regression risks and mitigations

### 8.1 What could go wrong

1. **`_module_to_parsed_ir` body drift during the copy-paste refactor.** If a
   line is dropped or reordered when moving from `_module_to_parsed_ir`'s old
   body into `_module_to_parsed_ir_on_func`, baselines fail. **Mitigation:**
   the refactor is literally a cut-paste with a signature change (first arg
   becomes explicit). Reviewer runs the full `Pkg.test()` suite; any
   baseline drift is visible within a test cycle.
2. **Memssa bitcode path.** The round-trip through `LLVM.string(mod)` after
   parsing bitcode could in principle produce IR that the memssa annotation
   pass handles differently. **Mitigation:** `use_memory_ssa=false` is the
   default; most tests won't hit this. Any memssa test that wants to use the
   bitcode path gets a dedicated regression (gate counts stay identical with
   the text path). P5 doesn't land any memssa-driven tests — the default
   path is untouched.
3. **LLVM IR-string parser rejecting Julia output.** `parse(LLVM.Module,
   ::String)` is what `extract_parsed_ir` already uses (line 68). Every
   Julia-emitted IR string has already gone through this parser. No new
   failure mode.
4. **`isdeclaration` vs `isempty(blocks)` drift.** The old Julia-path
   heuristic uses `isempty(LLVM.blocks(f))`. The new `_find_entry_by_name`
   uses `isdeclaration`. For any well-formed LLVM module these agree
   (a declaration has no blocks). **Mitigation:** the old heuristic is kept
   untouched in `_find_julia_entry_function`; no change in Julia-driven
   behaviour.
5. **Bitcode version skew.** Clang 18 → LLVM 18 → LLVM.jl binding version.
   If the toolchain and LLVM.jl disagree on bitcode format, parse fails.
   **Mitigation:** fail-loud on parse failure (§7.1 rethrow with citation).
   This is a real operational concern but not a regression — it affects
   only P5-driven tests and is documented in the fail-loud error.

### 8.2 Gate-count invariance argument (summary)

| Risk surface | Guarantee | Proof |
|---|---|---|
| Julia-driven `reversible_compile(f, T)` gate counts | Byte-identical | `_module_to_parsed_ir(mod)` signature unchanged; body moved to a helper with a verbatim body (§3.1, §7.1). |
| Julia-driven `extract_parsed_ir(f, T)` ParsedIR | Byte-identical | Same line-67 entry, same pass pipeline, same walker body. |
| Julia-driven memssa path | Byte-identical | `use_memory_ssa` kwarg semantics unchanged; no shared state between the Julia and `.ll`/`.bc` memssa calls. |
| `lower`, `bennett`, `simulate` | Byte-identical | Not touched. |

Concretely: `soft_fptrunc` stays at 36,474 gates; `popcount32` at 2,782;
HAMT at 96,788; CF at 11,078; CF+Feistel at 65,198; i8/i16/i32/i64 add at
98/202/410/826; TJ3 at 180; ls_demo_16 at 5,218.

---

## 9. Fail-loud contracts — error message catalogue

| Condition | Error class | Message template |
|---|---|---|
| Path missing | `ErrorException` | `extract_parsed_ir_from_{ll,bc}: file not found: <path>` |
| IR parse failed (text) | `ErrorException` wrapping `LLVMException` | `ir_extract.jl: failed to parse LLVM IR (T5-P5a/P5b): <orig>` |
| Bitcode parse failed | `AssertionError` from LLVM.jl | Native LLVM.jl diagnostics (bitcode failure is asserted, not raised — matches LLVM.jl's own convention) |
| Entry name not present | `ErrorException` | `ir_extract.jl: entry_function "<name>" not found in module.\n<hint>` where `<hint>` is near-matches or first-20 alphabetical candidates |
| Entry name ambiguous | `ErrorException` | `ir_extract.jl: entry_function "<name>" is ambiguous — <N> functions match:\n  <name> (linkage=<linkage>)\n  ...` |
| Entry is declaration-only | `ErrorException` | `ir_extract.jl: entry_function "<name>" is declaration-only (no body). linkage=<linkage>. The source IR must contain the function definition, not just its declaration.` |
| Bad `add`/`mul` kwarg in `reversible_compile(::ParsedIR)` | `ErrorException` | Delegated to `lower()` (`src/lower.jl:310–313`); message already cites supported values |

No silent returns. No `nothing` propagation. No `try/catch` swallow except
the parse-error rethrow, which preserves the underlying message and adds our
own cite.

---

## 10. Deferred (explicitly out of scope)

- **T5-P5c multi-entry selection** (extract several `ParsedIR`s from one
  module, link them via call-inlining). Not requested by the T5 PRD. Trivial
  to add later — call `_module_to_parsed_ir_on_func` once per chosen function.
- **In-memory bitcode ingest** (`extract_parsed_ir_from_bc(::Vector{UInt8})`).
  Tests all use file paths; adding a `Vector{UInt8}` method is three lines
  when needed.
- **Substring / fuzzy entry-function matching.** Explicitly rejected in
  §5.1. Could be added behind a `require_exact=false` kwarg if a future
  PRD demands it.
- **Bit-width narrowing for external IR.** No sound semantics without a
  language-specific contract; external C/Rust ABIs are not Julia's abstract
  widths. Not requested.
- **`strategy=:tabulate`** for the `ParsedIR` overload. `:tabulate` needs a
  callable `f` to evaluate 2^W times; we have only `ParsedIR`. The overload
  is deliberately a narrow `lower + bennett` shim.
- **`optimize` kwarg on the external ingestors.** Users control optimisation
  at compile time (`clang -O0/-O1/...`). Our `passes::Vector{String}` kwarg
  is the correct post-parse knob if they want to re-run transforms.
- **Reading `.bc` via `parse(LLVM.Module, bytes::Vector{UInt8})` directly**
  (skipping `MemoryBufferFile`). Equivalent, slightly shorter, but introduces
  a read-whole-file-then-parse step that `MemoryBufferFile` does in one
  LLVM-owned allocation. Either shape works; chose `MemoryBufferFile` for
  symmetry with how LLVM.jl expects bitcode to arrive.

---

## 11. Summary

Three tightly scoped changes:

1. **Refactor.** Split `_module_to_parsed_ir(mod)` into
   `_find_julia_entry_function(mod)` + `_module_to_parsed_ir_on_func(mod,
   func)`. Zero behaviour change for Julia-driven callers.
2. **Two new public ingest entry points.** `extract_parsed_ir_from_ll(path;
   entry_function, ...)` reads text IR; `extract_parsed_ir_from_bc(path;
   entry_function, ...)` reads bitcode. Both funnel through
   `_extract_from_parsed_ir_string`, which owns the pass pipeline and context
   lifetime. Both reuse the same walker.
3. **One new `reversible_compile` method.** Dispatches on `::ParsedIR`,
   skipping extraction. Four lines. Drops `optimize`, `bit_width`,
   `strategy`.

Fail-loud at every boundary (file not found, parse error, entry absent /
ambiguous / declaration-only). Helpful hints for the Rust mangling case.
Gate-count invariance preserved by construction — the refactor only moves a
boundary, does not edit the walker.

Test plan covers: unit (hand-rolled minimal `.ll`), equivalence (Julia →
`.ll` → ParsedIR ≡ Julia → ParsedIR directly), bitcode (hand-rolled minimal
`.bc` via LLVM.jl's bitcode writer), fail-loud paths (name not present,
declaration-only, near-matches). Corpus tests flip from UndefVarError to a
narrower `ErrorException` from the lowering phase (P6 will take them fully
green).

Total new surface: ~180 lines of Julia in `src/ir_extract.jl` + 12 lines in
`src/Bennett.jl` + 4 new test files. No changes to `lower.jl`, `bennett.jl`,
`simulator.jl`, `gates.jl`, or any of the persistent / pebbled / QROM
subsystems.

