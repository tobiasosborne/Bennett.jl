using InteractiveUtils: code_llvm
using LLVM

"""
    extract_ir(f, arg_types; optimize=true) -> String

Get the LLVM IR string for a Julia function (kept for debugging/printing).
"""
function extract_ir(f, arg_types::Type{<:Tuple}; optimize::Bool=true)
    return sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize))
end

"""
    DEFAULT_PREPROCESSING_PASSES

Canonical pass pipeline for eliminating allocas/stores before IR extraction.
`sroa` splits aggregates, `mem2reg` promotes remaining allocas to SSA,
`simplifycfg` cleans up CFG artifacts, `instcombine` folds local peepholes.

Verified empirically to take a typical Julia function with 5 allocas / 6 stores
(from array literal construction) down to zero of each.
"""
const DEFAULT_PREPROCESSING_PASSES = ["sroa", "mem2reg", "simplifycfg", "instcombine"]

"""
    extract_parsed_ir(f, arg_types; optimize=true, preprocess=false, passes=nothing) -> ParsedIR

Extract LLVM IR via LLVM.jl's typed API and convert to ParsedIR.
Uses dump_module=true to include function declarations needed for call inlining.

Pass-pipeline control:
- `preprocess=true` runs `DEFAULT_PREPROCESSING_PASSES` (sroa, mem2reg,
  simplifycfg, instcombine) on the parsed module — primarily to eliminate
  store/alloca ahead of the IR walker for memory-model work.
- `passes` is an optional `Vector{String}` of LLVM New-Pass-Manager pipeline
  names to run (e.g. `["licm", "gvn"]`). When both are supplied, default
  passes run first, then the explicit `passes` list.
- When neither is set, no extra passes run — behavior is identical to earlier
  versions.

`ptr_cells=true` (BVM ADR 0020 D3/D4, generalized to the Julia track per ADR
0021 Decision 2) models pointers (Dict/Memory) as opaque 64-bit VM cells — a
`ptr` RETURN type derives `ret_width = 64`, `store ptr`/`load ptr` lower as
64-bit cells, and a two-index struct GEP lowers to `IRPtrOffset`. This is the
SAME gate `extract_parsed_ir_from_ll`/`_from_bc` already expose; the
Julia-function entry was the only core entry omitting it (Bennett-lf14). The
default `false` is byte-identical to every prior caller: ALL the existing
Julia-path fail-louds (U114 store, U16 GEP, U81 void/ptr return) keep firing
unchanged — they protect the circuit / `mem=:heap` models, which the cell
model must NOT silently alias. The gate is the single switch; nothing else in
the walk changes shape.
"""
function extract_parsed_ir(f, arg_types::Type{<:Tuple};
                           optimize::Bool=true,
                           preprocess::Bool=false,
                           passes::Vector{String}=String[],
                           use_memory_ssa::Bool=false,
                           mem::Symbol=:auto,
                           ptr_cells::Bool=false)
    ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))
    return _parsed_ir_from_ir_string(ir_string; preprocess=preprocess, passes=passes,
                                     use_memory_ssa=use_memory_ssa, mem=mem,
                                     ptr_cells=ptr_cells)
end

# Bennett-40ys: the TAIL of `extract_parsed_ir`, factored out VERBATIM so the
# by-value entry (`extract_parsed_ir`, above) and the by-signature entry
# (`extract_parsed_ir_by_sig`, below) share every pass-pipeline step, every
# fail-loud and the memssa stamp. ONLY the IR *source* differs between them
# (`code_llvm` vs `_code_llvm_by_sig`), so the two entries cannot drift — which
# is what lets the by-sig path inherit the by-value path's tested behaviour
# wholesale (Rule 12: no duplicated lowering).
function _parsed_ir_from_ir_string(ir_string::AbstractString;
                                   preprocess::Bool=false,
                                   passes::Vector{String}=String[],
                                   use_memory_ssa::Bool=false,
                                   mem::Symbol=:auto,
                                   ptr_cells::Bool=false)
    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    append!(effective_passes, passes)  # no-op when empty (Bennett-s8gs / U206)

    # T2a.2: capture MemorySSA annotations before the main IR walk. Runs in a
    # separate context so stderr capture for the printer doesn't collide with
    # our main extraction.
    memssa = if use_memory_ssa
        annotated = _run_memssa_on_ir(ir_string; preprocess=preprocess)
        parse_memssa_annotations(annotated)
    else
        nothing
    end

    local result::ParsedIR
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        # Bennett-uyf9: auto-canonicalise memcpy-form sret. Under optimize=false
        # Julia emits aggregate returns as `alloca [N x iM]` + llvm.memcpy into
        # the sret pointer, which _collect_sret_writes cannot decompose. SROA
        # decomposes the alloca+memcpy into per-slot scalar stores that the
        # existing sret pre-walk handles natively. Gated on sret presence + SROA
        # not already in the pass list — byte-identical for non-sret functions.
        if !("sroa" in effective_passes) && _module_has_sret(mod)
            prepend!(effective_passes, ["sroa", "mem2reg"])
        end
        if !isempty(effective_passes)
            _run_passes!(mod, effective_passes)
        end
        result = _module_to_parsed_ir(mod; mem=mem, ptr_cells=ptr_cells)
        dispose(mod)
    end
    # Stamp memssa into the result if requested
    if memssa !== nothing
        result = ParsedIR(result.ret_width, result.args, result.blocks,
                          result.ret_elem_widths, result.globals, memssa,
                          result.synth_ptr_provenance)
    end
    return result
end

"""
    extract_parsed_ir_by_sig(sig::Type{<:Tuple}; optimize=false, preprocess=false,
        passes=String[], use_memory_ssa=false, mem=:auto, ptr_cells=false) -> ParsedIR

`extract_parsed_ir` for a callee that cannot be named by a VALUE. `sig` is the
FULL specTypes signature `Tuple{callee_key, argtypes...}` — the un-split form of
a `transitive_callees` pair (`_spectypes_of` reassembles it).

Needed because a closure or functor callee key discovered by the closed-world
walker has no `.instance` to hand `code_llvm`: Julia 1.12 outlines `_growend!`'s
slow path into a closure, so every `push!`-bearing function has one
(Bennett-40ys). See `src/extract/sig_llvm.jl` for why a signature suffices and
for the Rule 5/9 caveat on the internals involved.

Every kwarg, pass-pipeline step and fail-loud is SHARED with `extract_parsed_ir`
via `_parsed_ir_from_ir_string`; only the IR source differs.

`entry_function` selection is deliberately left at `nothing`
(`_find_entry_function`'s "first `julia_*` with a body" rule) — identical to
`extract_parsed_ir`, and correct here: the requested method is emitted first in
its own module, ahead of the `jfptr_*` wrapper (which does not start with
`julia_`) and any co-emitted callee.
"""
function extract_parsed_ir_by_sig(@nospecialize(sig::Type);
                                  optimize::Bool=false,
                                  preprocess::Bool=false,
                                  passes::Vector{String}=String[],
                                  use_memory_ssa::Bool=false,
                                  mem::Symbol=:auto,
                                  ptr_cells::Bool=false)
    ir_string = _code_llvm_by_sig(sig; optimize=optimize, dump_module=true,
                                  debuginfo=:none)
    return _parsed_ir_from_ir_string(ir_string; preprocess=preprocess, passes=passes,
                                     use_memory_ssa=use_memory_ssa, mem=mem,
                                     ptr_cells=ptr_cells)
end

# Shared plumbing for the external-IR entry points. Takes an already-parsed
# module, optionally runs a pass pipeline on it, then walks the selected
# entry function through the core walker.
#
# `mem` (ADR 0013 §D-4) selects the memory-extraction arm and is forwarded
# verbatim to `_module_to_parsed_ir`. The `.ll`/`.bc` entry points expose it
# so a C/Rust (or hand-written) module can request `mem=:vm` just like the
# Julia-function path. Default `:auto` keeps every prior caller byte-identical.
#
# `ptr_cells` (BVM ADR 0020 D3/D4, CW-C2 chunk B) is the C-track
# extraction-mode gate; forwarded verbatim to `_module_to_parsed_ir`. Default
# `false` keeps every prior caller byte-identical (see extract_parsed_ir_from_ll).
function _extract_from_module(mod::LLVM.Module,
                              entry_function::Union{Nothing, AbstractString},
                              effective_passes::Vector{String};
                              mem::Symbol=:auto,
                              ptr_cells::Bool=false)
    # Bennett-uyf9: auto-canonicalise memcpy-form sret (see extract_parsed_ir
    # for rationale). Shared across extract_parsed_ir_from_ll / _from_bc.
    if !("sroa" in effective_passes) && _module_has_sret(mod)
        prepend!(effective_passes, ["sroa", "mem2reg"])
    end
    if !isempty(effective_passes)
        _run_passes!(mod, effective_passes)
    end
    return _module_to_parsed_ir(mod; entry_function=entry_function,
                                mem=mem, ptr_cells=ptr_cells)
end

"""
    extract_parsed_ir_from_ll(path::String; entry_function::AbstractString,
                              preprocess=false, passes=nothing,
                              use_memory_ssa=false) -> ParsedIR

Parse a raw LLVM IR text file (`.ll`) and walk the named entry function
through the same pipeline as `extract_parsed_ir(f, arg_types)`. Bennett-lmkb
(T5-P5a).

The entry function must match an exact `LLVM.name(f)` in the module. C and
Rust fixtures that want a stable name should be compiled with `extern "C"`
/ `#[no_mangle]`.

`use_memory_ssa=true` runs the MemorySSA printer pass on the loaded IR
text. Available on this path because the input is already text.

`ptr_cells=true` (BVM ADR 0020 D3/D4, CW-C2 chunk B) is the **C-track
extraction-mode gate**. When set, the extractor admits the C heap-pointer
instruction surface as language-neutral 64-bit VM cells:

  - `store ptr`/`load ptr` lower as 64-bit `IRStore`/`IRLoad` (a pointer is
    one Int64 cell in the VM address space — ADR 0018 §A), instead of
    fail-louding at the `Bennett-lgzx`/U114 wall.
  - A `ptr` RETURN type derives `ret_width = 64` instead of hitting the
    `_type_width` "unsupported LLVM type" wall (D3 pointer-return = cell).
  - A two-index struct GEP (`getelementptr %struct.T, ptr %p, i32 0, i32 K`)
    lowers to `IRPtrOffset(offset_bytes, elem_width=64)` with byte offsets
    from the LLVM datalayout (`LLVM.offsetof`), instead of the
    `Bennett-qal5`/U16 reject (D4).

The default (`ptr_cells=false`) is byte-identical to every prior caller: ALL
the existing Julia-path fail-louds (U114 store, U16 GEP, U81 void/ptr
return) keep firing unchanged — they protect the circuit / `mem=:heap`
models, which the C cell model must NOT silently alias. The gate is the
single switch the C track flips; nothing else in the walk changes shape.
"""
function extract_parsed_ir_from_ll(path::AbstractString;
                                    entry_function::AbstractString,
                                    preprocess::Bool=false,
                                    passes::Vector{String}=String[],
                                    use_memory_ssa::Bool=false,
                                    mem::Symbol=:auto,
                                    ptr_cells::Bool=false)
    isfile(path) || throw(ArgumentError(
        "ir_extract.jl: extract_parsed_ir_from_ll: file not found: $path"))

    ir_string = read(path, String)

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    append!(effective_passes, passes)  # no-op when empty (Bennett-s8gs / U206)

    memssa = if use_memory_ssa
        annotated = _run_memssa_on_ir(ir_string; preprocess=preprocess)
        parse_memssa_annotations(annotated)
    else
        nothing
    end

    local result::ParsedIR
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        try
            result = _extract_from_module(mod, entry_function, effective_passes;
                                          mem=mem, ptr_cells=ptr_cells)
        finally
            dispose(mod)
        end
    end
    if memssa !== nothing
        result = ParsedIR(result.ret_width, result.args, result.blocks,
                          result.ret_elem_widths, result.globals, memssa,
                          result.synth_ptr_provenance)
    end
    return result
end

"""
    extract_parsed_ir_set_from_ll(path::String; ptr_cells=false,
                                  preprocess=false, passes=String[],
                                  mem=:auto) -> Vector{Pair{Symbol,ParsedIR}}

Parse a raw LLVM IR text file (`.ll`) and walk EVERY defined (non-declaration)
function in the module, returning a `Vector{Pair{Symbol,ParsedIR}}` keyed by
function name (BVM ADR 0020 D6, CW-C2 chunk C). This is the multi-function
producer the BennettVM closed-world C-track consumes: the output is the exact
input shape of BVM's multi-function `lower_vm(::Vector{<:Pair{Symbol,ParsedIR}})`
(ADR 0019 §2). Each function is walked through the SAME single-function
pipeline as `extract_parsed_ir_from_ll`; the per-function `ptr_cells` /
`mem` / pass behaviour is identical.

`declare`d functions (libc `malloc` / `free`, no body) are SKIPPED — their
calls are emitted as `Symbol`-callee `IRCall`s (D5) that BVM routes through
`_HEAP_DISPATCH`, not lowered as in-module functions. Fails loud on a module
with zero defined functions (Rule 1).

Unlike `extract_parsed_ir_from_ll`, there is no `entry_function` selector
(every function is walked) and no `use_memory_ssa` (the MemorySSA printer is a
single-entry probe). `ptr_cells=true` is the C-track extraction-mode gate (see
`extract_parsed_ir_from_ll`).
"""
function extract_parsed_ir_set_from_ll(path::AbstractString;
                                       preprocess::Bool=false,
                                       passes::Vector{String}=String[],
                                       mem::Symbol=:auto,
                                       ptr_cells::Bool=false)
    isfile(path) || throw(ArgumentError(
        "ir_extract.jl: extract_parsed_ir_set_from_ll: file not found: $path"))

    ir_string = read(path, String)

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    append!(effective_passes, passes)

    local result::Vector{Pair{Symbol,ParsedIR}}
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        try
            # Mirror _extract_from_module's sret auto-canonicalisation so the
            # set walker matches the single-function path's pass handling.
            if !("sroa" in effective_passes) && _module_has_sret(mod)
                prepend!(effective_passes, ["sroa", "mem2reg"])
            end
            if !isempty(effective_passes)
                _run_passes!(mod, effective_passes)
            end
            result = _module_to_parsed_ir_set(mod; mem=mem, ptr_cells=ptr_cells)
        finally
            dispose(mod)
        end
    end
    return result
end

"""
    extract_parsed_ir_from_bc(path::String; entry_function::AbstractString,
                              preprocess=false, passes=nothing) -> ParsedIR

Parse a raw LLVM bitcode file (`.bc`) and walk the named entry function.
Bennett-f2p9 (T5-P5b). Otherwise identical to `extract_parsed_ir_from_ll`,
including the `ptr_cells` C-track gate (BVM ADR 0020 D3/D4, Bennett-haiy),
which is forwarded with the same default (`false` = Julia-path fail-louds
byte-identical).

`use_memory_ssa` is not exposed on this path: the MemorySSA printer
operates on textual IR and we do not round-trip bitcode → text here. If
you need MemorySSA on a bitcode input, convert with `llvm-dis` first and
use `extract_parsed_ir_from_ll`.
"""
function extract_parsed_ir_from_bc(path::AbstractString;
                                    entry_function::AbstractString,
                                    preprocess::Bool=false,
                                    passes::Vector{String}=String[],
                                    mem::Symbol=:auto,
                                    ptr_cells::Bool=false)
    isfile(path) || throw(ArgumentError(
        "ir_extract.jl: extract_parsed_ir_from_bc: file not found: $path"))

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    append!(effective_passes, passes)  # no-op when empty (Bennett-s8gs / U206)

    local result::ParsedIR
    LLVM.Context() do _ctx
        @dispose membuf = LLVM.MemoryBufferFile(String(path)) begin
            mod = parse(LLVM.Module, membuf)
            try
                result = _extract_from_module(mod, entry_function, effective_passes;
                                              mem=mem, ptr_cells=ptr_cells)
            finally
                dispose(mod)
            end
        end
    end
    return result
end

# Run LLVM New-Pass-Manager passes on `mod` in order. Pass names must be the
# canonical NPM strings LLVM accepts (e.g. "sroa", "mem2reg", "simplifycfg").
function _run_passes!(mod::LLVM.Module, passes::Vector{String})
    pipeline = join(passes, ",")
    @dispose pb = LLVM.NewPMPassBuilder() begin
        LLVM.add!(pb, pipeline)
        LLVM.run!(pb, mod)
    end
    return nothing
end

