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
"""
function extract_parsed_ir(f, arg_types::Type{<:Tuple};
                           optimize::Bool=true,
                           preprocess::Bool=false,
                           passes::Vector{String}=String[],
                           use_memory_ssa::Bool=false)
    ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))

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
        result = _module_to_parsed_ir(mod)
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

# Shared plumbing for the external-IR entry points. Takes an already-parsed
# module, optionally runs a pass pipeline on it, then walks the selected
# entry function through the core walker.
function _extract_from_module(mod::LLVM.Module,
                              entry_function::Union{Nothing, AbstractString},
                              effective_passes::Vector{String})
    # Bennett-uyf9: auto-canonicalise memcpy-form sret (see extract_parsed_ir
    # for rationale). Shared across extract_parsed_ir_from_ll / _from_bc.
    if !("sroa" in effective_passes) && _module_has_sret(mod)
        prepend!(effective_passes, ["sroa", "mem2reg"])
    end
    if !isempty(effective_passes)
        _run_passes!(mod, effective_passes)
    end
    return _module_to_parsed_ir(mod; entry_function=entry_function)
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
"""
function extract_parsed_ir_from_ll(path::AbstractString;
                                    entry_function::AbstractString,
                                    preprocess::Bool=false,
                                    passes::Vector{String}=String[],
                                    use_memory_ssa::Bool=false)
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
            result = _extract_from_module(mod, entry_function, effective_passes)
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
    extract_parsed_ir_from_bc(path::String; entry_function::AbstractString,
                              preprocess=false, passes=nothing) -> ParsedIR

Parse a raw LLVM bitcode file (`.bc`) and walk the named entry function.
Bennett-f2p9 (T5-P5b). Otherwise identical to `extract_parsed_ir_from_ll`.

`use_memory_ssa` is not exposed on this path: the MemorySSA printer
operates on textual IR and we do not round-trip bitcode → text here. If
you need MemorySSA on a bitcode input, convert with `llvm-dis` first and
use `extract_parsed_ir_from_ll`.
"""
function extract_parsed_ir_from_bc(path::AbstractString;
                                    entry_function::AbstractString,
                                    preprocess::Bool=false,
                                    passes::Vector{String}=String[])
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
                result = _extract_from_module(mod, entry_function, effective_passes)
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

