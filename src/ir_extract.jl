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
                           passes::Union{Nothing,Vector{String}}=nothing,
                           use_memory_ssa::Bool=false)
    ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

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
                          result.ret_elem_widths, result.globals, memssa)
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
                                    passes::Union{Nothing,Vector{String}}=nothing,
                                    use_memory_ssa::Bool=false)
    isfile(path) || error(
        "ir_extract.jl: extract_parsed_ir_from_ll: file not found: $path")

    ir_string = read(path, String)

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
        mod = parse(LLVM.Module, ir_string)
        try
            result = _extract_from_module(mod, entry_function, effective_passes)
        finally
            dispose(mod)
        end
    end
    if memssa !== nothing
        result = ParsedIR(result.ret_width, result.args, result.blocks,
                          result.ret_elem_widths, result.globals, memssa)
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
                                    passes::Union{Nothing,Vector{String}}=nothing)
    isfile(path) || error(
        "ir_extract.jl: extract_parsed_ir_from_bc: file not found: $path")

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

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

# ---- known callee registry for gate-level inlining ----

const _known_callees = Dict{String, Function}()
# Bennett-7stg / U26: wrap mutations and lookups in a ReentrantLock.
# Multi-threaded compiles (e.g. parallel Pkg.test workers) could race on
# Dict mutation; the lock makes register_callee! / _lookup_callee safe.
# ReentrantLock allows recursive entry — matters for pathological cases
# where _lookup_callee somehow triggers a register during compilation.
const _known_callees_lock = ReentrantLock()

"""Register a Julia function for gate-level inlining when encountered as an LLVM call."""
function register_callee!(f::Function)
    # Get the LLVM name Julia would give this function (j_name_NNN pattern)
    # We match by substring, so just store the Julia function name
    lock(_known_callees_lock) do
        _known_callees[string(nameof(f))] = f
    end
    return nothing
end

# Bennett-ej4n / U48: cache extracted ParsedIR keyed on (callee, arg_types).
# `extract_parsed_ir` does a ~21ms LLVM C-API walk per invocation; a circuit
# with N references to the same callee paid that N times via `lower_call!`.
# Module-scoped because registered callees are stable functions in this
# package — the cache is small (one entry per distinct (callee, arg_types)
# pair) and never grows after warm-up. Avoids worsening the LoweringCtx
# back-compat-constructor sprawl tracked in Bennett-ehoa / U43.
const _parsed_ir_cache = Dict{Tuple{Function, Type}, ParsedIR}()
const _parsed_ir_cache_lock = ReentrantLock()

"""
    _extract_parsed_ir_cached(f, arg_types) -> ParsedIR

Memoised wrapper over `extract_parsed_ir(f, arg_types)`. On a cache hit
returns the previously-extracted `ParsedIR` by identity; on a miss
extracts, stores, and returns. `ParsedIR` is immutable and the lowering
pipeline only reads from it, so sharing across compiles is safe.
"""
function _extract_parsed_ir_cached(f::Function, arg_types::Type{<:Tuple})::ParsedIR
    key = (f, arg_types)
    lock(_parsed_ir_cache_lock) do
        haskey(_parsed_ir_cache, key) && return _parsed_ir_cache[key]
        pir = extract_parsed_ir(f, arg_types)
        _parsed_ir_cache[key] = pir
        return pir
    end
end

"""Empty the `_parsed_ir_cache`. For tests, and as a manual escape hatch
if a callee gets redefined (e.g. under Revise) — registered callees in
this package are otherwise stable across the process lifetime."""
function _clear_parsed_ir_cache!()
    lock(_parsed_ir_cache_lock) do
        empty!(_parsed_ir_cache)
    end
    return nothing
end

function _lookup_callee(llvm_name::String)
    lock(_known_callees_lock) do
        # First: try exact match (for hardcoded lookups like "soft_fcmp_ole")
        haskey(_known_callees, llvm_name) && return _known_callees[llvm_name]

        # Second: LLVM-mangled names follow julia_<funcname>_<NNN> or j_<funcname>_<NNN>.
        # Extract the function name and do exact dict lookup.
        lname = lowercase(llvm_name)
        m = match(r"^(?:julia_|j_)(.+)_(\d+)$", lname)
        if m !== nothing
            fname = m.captures[1]
            haskey(_known_callees, fname) && return _known_callees[fname]
        end
        return nothing
    end
end

# ---- value identity via C pointer ----

const _LLVMRef = LLVM.API.LLVMValueRef

# Auto-name counter (passed as argument, not global state)
function _auto_name(counter::Ref{Int})
    counter[] += 1
    Symbol("__v$(counter[])")
end

# ---- Bennett-cc0.6: standardized error reporting ----
#
# When an unsupported LLVM IR pattern fires an error, the message should
# tell the debugger exactly where to look in the IR: function name, block
# label, and the full stringified instruction. Canonical format:
#
#   ir_extract.jl: <opcode> in @<funcname>:%<blockname>: <serialised> — <reason>
#
# `_ir_error(inst, reason)` raises in this format. Callers that have an
# `inst::LLVM.Instruction` in scope should prefer this helper over a raw
# `error(...)`. Helper-level errors (in `_operand`, `_fold_constexpr_operand`,
# `_resolve_vec_lanes`, etc.) keep their value-scoped messages — the stack
# trace shows the enclosing instruction.

# Opcode-enum → human-readable name. Falls back to `string(opc)`.
const _LLVM_OPCODE_NAMES = Dict(
    LLVM.API.LLVMRet            => "ret",
    LLVM.API.LLVMBr             => "br",
    LLVM.API.LLVMSwitch         => "switch",
    LLVM.API.LLVMIndirectBr     => "indirectbr",
    LLVM.API.LLVMInvoke         => "invoke",
    LLVM.API.LLVMUnreachable    => "unreachable",
    LLVM.API.LLVMAdd            => "add",
    LLVM.API.LLVMFAdd           => "fadd",
    LLVM.API.LLVMSub            => "sub",
    LLVM.API.LLVMFSub           => "fsub",
    LLVM.API.LLVMMul            => "mul",
    LLVM.API.LLVMFMul           => "fmul",
    LLVM.API.LLVMUDiv           => "udiv",
    LLVM.API.LLVMSDiv           => "sdiv",
    LLVM.API.LLVMFDiv           => "fdiv",
    LLVM.API.LLVMURem           => "urem",
    LLVM.API.LLVMSRem           => "srem",
    LLVM.API.LLVMFRem           => "frem",
    LLVM.API.LLVMShl            => "shl",
    LLVM.API.LLVMLShr           => "lshr",
    LLVM.API.LLVMAShr           => "ashr",
    LLVM.API.LLVMAnd            => "and",
    LLVM.API.LLVMOr             => "or",
    LLVM.API.LLVMXor            => "xor",
    LLVM.API.LLVMAlloca         => "alloca",
    LLVM.API.LLVMLoad           => "load",
    LLVM.API.LLVMStore          => "store",
    LLVM.API.LLVMGetElementPtr  => "getelementptr",
    LLVM.API.LLVMTrunc          => "trunc",
    LLVM.API.LLVMZExt           => "zext",
    LLVM.API.LLVMSExt           => "sext",
    LLVM.API.LLVMFPToUI         => "fptoui",
    LLVM.API.LLVMFPToSI         => "fptosi",
    LLVM.API.LLVMUIToFP         => "uitofp",
    LLVM.API.LLVMSIToFP         => "sitofp",
    LLVM.API.LLVMFPTrunc        => "fptrunc",
    LLVM.API.LLVMFPExt          => "fpext",
    LLVM.API.LLVMPtrToInt       => "ptrtoint",
    LLVM.API.LLVMIntToPtr       => "inttoptr",
    LLVM.API.LLVMBitCast        => "bitcast",
    LLVM.API.LLVMAddrSpaceCast  => "addrspacecast",
    LLVM.API.LLVMICmp           => "icmp",
    LLVM.API.LLVMFCmp           => "fcmp",
    LLVM.API.LLVMPHI            => "phi",
    LLVM.API.LLVMCall           => "call",
    LLVM.API.LLVMSelect         => "select",
    LLVM.API.LLVMExtractValue   => "extractvalue",
    LLVM.API.LLVMInsertValue    => "insertvalue",
    LLVM.API.LLVMExtractElement => "extractelement",
    LLVM.API.LLVMInsertElement  => "insertelement",
    LLVM.API.LLVMShuffleVector  => "shufflevector",
    LLVM.API.LLVMFNeg           => "fneg",
    LLVM.API.LLVMFence          => "fence",
    LLVM.API.LLVMFreeze         => "freeze",
)

_llvm_opcode_name(opc) = get(_LLVM_OPCODE_NAMES, opc, string(opc))

# Build the canonical error message for an instruction-scoped failure.
# Each LLVM.* introspection call is wrapped: if the C-API errors on a
# freed/invalid value during error formatting we still want to produce a
# message rather than crash with a different exception. Bennett-uinn / U93:
# narrow each catch to re-raise InterruptException so Ctrl-C still works.
function _ir_error_msg(inst::LLVM.Instruction, reason::AbstractString)::String
    opc_name = try
        _llvm_opcode_name(LLVM.opcode(inst))
    catch e
        e isa InterruptException && rethrow()
        "unknown-opcode"
    end
    bb = try
        LLVM.parent(inst)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    fname = bb === nothing ? "<unknown-fn>" : try
        LLVM.name(LLVM.parent(bb))
    catch e
        e isa InterruptException && rethrow()
        "<unknown-fn>"
    end
    bname = bb === nothing ? "<unknown-block>" : try
        LLVM.name(bb)
    catch e
        e isa InterruptException && rethrow()
        "<unknown-block>"
    end
    inst_str = try
        string(inst)
    catch e
        e isa InterruptException && rethrow()
        "<unprintable-instruction>"
    end
    return "ir_extract.jl: $opc_name in @$fname:%$bname: $inst_str — $reason"
end

# Raise a standardized error for an instruction-scoped failure.
function _ir_error(inst::LLVM.Instruction, reason::AbstractString)
    error(_ir_error_msg(inst, reason))
end

# ---- sret (structure return) support (Bennett-dv1z) ----
#
# LLVM LangRef: `sret(<ty>)` is a parameter attribute that marks a pointer
# parameter as the caller-allocated destination for an aggregate return value.
# The function's LLVM return type is `void`; the callee writes the return
# struct to this pointer. Julia routes tuple returns of >16 bytes (on x86_64
# SysV) through sret. Examples: `(a::UInt32,b::UInt32,c::UInt32)->(a,b,c)`.
#
# The extractor translates sret back to the by-value aggregate-return shape
# that the rest of the pipeline already handles: exclude sret from args,
# derive `ret_elem_widths` from the sret pointee type, suppress the
# sret-targeting stores and their constant-offset GEPs during the block
# walk, and at `ret void` synthesise an IRInsertValue chain + IRRet
# equivalent to what n=2 by-value returns produce directly.

"""
    _detect_sret(func) -> nothing | NamedTuple

Detect the LLVM `sret` parameter attribute on `func`. Returns `nothing` if no
sret parameter is present — the non-sret path is byte-identical to the
pre-fix behaviour, preserving all existing gate-count baselines.

Returns a NamedTuple:
    (param_index::Int, param_ref::LLVMValueRef, agg_type::LLVM.ArrayType,
     n_elems::Int, elem_width::Int, elem_byte_size::Int, agg_byte_size::Int)

Errors (fail-fast per CLAUDE.md rule 1):
  * multiple sret parameters (LangRef forbids this)
  * sret pointee is not `[N x iM]` (heterogeneous struct unsupported — MVP scope)
  * sret element is not an integer type
  * sret element width is not in {8, 16, 32, 64}
"""
function _detect_sret(func::LLVM.Function)
    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
    found = nothing
    for (i, p) in enumerate(LLVM.parameters(func))
        attr = LLVM.API.LLVMGetEnumAttributeAtIndex(func, UInt32(i), kind_sret)
        attr == C_NULL && continue
        fname = LLVM.name(func)
        if found !== nothing
            error("ir_extract.jl: function @$fname has multiple sret parameters " *
                  "(LangRef forbids this); found at parameter indices " *
                  "$(found.param_index) and $i")
        end
        ty = LLVM.LLVMType(LLVM.API.LLVMGetTypeAttributeValue(attr))
        ty isa LLVM.ArrayType || error(
            "ir_extract.jl: sret pointee is $ty in @$fname; only [N x iM] " *
            "aggregates are supported (heterogeneous struct returns like " *
            "Tuple{UInt32,UInt64} are not yet supported — see Bennett-dv1z " *
            "MVP scope)")
        et = LLVM.eltype(ty)
        et isa LLVM.IntegerType || error(
            "ir_extract.jl: sret aggregate element type $et in @$fname is not " *
            "an integer; float/pointer sret aggregates are not supported")
        w = LLVM.width(et)
        w ∈ (8, 16, 32, 64) || error(
            "ir_extract.jl: sret element width $w in @$fname is not in " *
            "{8,16,32,64}; got aggregate $ty")
        n = LLVM.length(ty)
        elem_bytes = w ÷ 8
        found = (param_index = i, param_ref = p.ref, agg_type = ty,
                 n_elems = n, elem_width = w,
                 elem_byte_size = elem_bytes,
                 agg_byte_size = n * elem_bytes)
    end
    return found
end

"""
    _module_has_sret(mod::LLVM.Module) -> Bool

Bennett-uyf9: true iff any function in `mod` (with a body) has a parameter
carrying the `sret` attribute. Used to auto-enable SROA + mem2reg in the pass
pipeline — Julia's no-optimisation codegen emits aggregate returns via
`alloca [N x iM]` + `llvm.memcpy` into the sret buffer, which SROA decomposes
into per-slot scalar stores that `_collect_sret_writes` handles natively.
Byte-identical for non-sret modules (returns false, auto-prepend skipped).
"""
function _module_has_sret(mod::LLVM.Module)::Bool
    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
    for func in LLVM.functions(mod)
        length(LLVM.blocks(func)) == 0 && continue  # declarations
        for (i, _) in enumerate(LLVM.parameters(func))
            attr = LLVM.API.LLVMGetEnumAttributeAtIndex(
                func, UInt32(i), kind_sret)
            attr == C_NULL || return true
        end
    end
    return false
end

"""
    _collect_sret_writes(func, sret_info, names) -> NamedTuple

Pre-walk the function body, classifying every instruction that touches the
sret pointer. Returns `(slot_values, suppressed)` where `slot_values` is a
`Dict{Int, IROperand}` (0-based element index → stored value) and
`suppressed` is a `Set{LLVMValueRef}` of instructions the block walk must
skip — the sret stores and their constant-offset GEPs. These materialise
at `ret void` time as a synthetic IRInsertValue chain.

Recognised patterns (optimize=true Julia emits):
  * `store iM %v, ptr %sret_return`                           → slot 0
  * `store iM %v, ptr %gep_from_sret_byte_K`                  → slot K/elem_byte_size
  * `%gep = getelementptr inbounds i8, ptr %sret_return, i64 K` → consumed

Errors (no silent miscompile):
  * `llvm.memcpy` into sret (optimize=false pattern — direct user not to use
    optimize=false, or preprocess=true to canonicalise)
  * dynamic/non-constant-offset GEP from sret
  * GEP offset past aggregate end
  * store with width ≠ element width, or misaligned byte offset
  * duplicate stores to the same slot (MVP: one store per slot)
  * a slot left unwritten before `ret void`
"""
function _collect_sret_writes(func::LLVM.Function, sret_info, names::Dict{_LLVMRef, Symbol})
    slot_values       = Dict{Int, IROperand}()
    suppressed        = Set{_LLVMRef}()
    gep_byte          = Dict{_LLVMRef, Int}()   # sret-derived GEP result → byte offset
    # Bennett-0c8o: vector sret stores reserve slot ranges at pre-walk time;
    # pass-2 hook fills them in from `lanes` when the vector-producer runs.
    pending_vec       = Dict{_LLVMRef, Tuple{Int, Int}}()   # store.ref => (first_slot, n_lanes)
    pending_val_refs  = Dict{_LLVMRef, _LLVMRef}()          # store.ref => val.ref

    sret_ref  = sret_info.param_ref
    eb        = sret_info.elem_byte_size
    n         = sret_info.n_elems
    ew        = sret_info.elem_width
    agg_bytes = sret_info.agg_byte_size

    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            opc = LLVM.opcode(inst)

            # llvm.memcpy into sret → reject (optimize=false form)
            if opc == LLVM.API.LLVMCall
                ops = LLVM.operands(inst)
                n_ops = length(ops)
                if n_ops >= 1
                    cname = try
                        LLVM.name(ops[n_ops])
                    catch e
                        e isa InterruptException && rethrow()
                        ""
                    end
                    if startswith(cname, "llvm.memcpy")
                        if n_ops >= 2 && ops[1].ref === sret_ref
                            _ir_error(inst,
                                "sret with llvm.memcpy form is not supported " *
                                "(emitted under optimize=false). Re-compile with " *
                                "optimize=true (Bennett.jl default) or set " *
                                "preprocess=true to canonicalise via SROA/mem2reg.")
                        end
                    end
                end
            end

            # GEP chained off the sret pointer with a constant offset
            if opc == LLVM.API.LLVMGetElementPtr
                ops = LLVM.operands(inst)
                if length(ops) >= 2
                    base = ops[1]
                    base_off = if base.ref === sret_ref
                        0
                    elseif haskey(gep_byte, base.ref)
                        gep_byte[base.ref]
                    else
                        nothing
                    end
                    if base_off !== nothing
                        length(ops) == 2 || _ir_error(inst,
                            "sret-derived GEP has $(length(ops)-1) indices; only " *
                            "single-index constant-offset GEPs from sret are supported")
                        idx = ops[2]
                        idx isa LLVM.ConstantInt || _ir_error(inst,
                            "sret pointer is indexed dynamically; only constant-offset " *
                            "GEPs from sret are supported")
                        src_ty = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(inst))
                        add_bytes = if src_ty isa LLVM.IntegerType && LLVM.width(src_ty) == 8
                            _const_int_as_int(idx)         # byte-indexed GEP (Julia default)
                        elseif src_ty === sret_info.agg_type
                            _const_int_as_int(idx) * eb    # typed GEP on [N x iM]
                        else
                            _ir_error(inst,
                                "sret GEP source element type $src_ty; expected i8 " *
                                "(byte-indexed) or $(sret_info.agg_type) (typed element)")
                        end
                        new_off = base_off + add_bytes
                        (0 <= new_off < agg_bytes) || _ir_error(inst,
                            "sret GEP byte offset $new_off is outside aggregate " *
                            "range [0, $agg_bytes)")
                        gep_byte[inst.ref] = new_off
                        push!(suppressed, inst.ref)
                        continue
                    end
                end
            end

            # Store targeting the sret buffer (directly or through a tracked GEP)
            if opc == LLVM.API.LLVMStore
                ops = LLVM.operands(inst)
                val = ops[1]
                ptr = ops[2]
                byte_off = if ptr.ref === sret_ref
                    0
                elseif haskey(gep_byte, ptr.ref)
                    gep_byte[ptr.ref]
                else
                    nothing
                end
                if byte_off !== nothing
                    vt = LLVM.value_type(val)
                    # Bennett-0c8o: SLP-emitted vector store into sret GEP.
                    # Reserve slot range with a sentinel; pass 2 fills it in
                    # from `lanes` when the vector-producer runs.
                    if vt isa LLVM.VectorType
                        lane_ty = LLVM.eltype(vt)
                        lane_ty isa LLVM.IntegerType || _ir_error(inst,
                            "sret vector store at byte offset $byte_off has " *
                            "non-integer lane type $lane_ty")
                        lw = Int(LLVM.width(lane_ty))
                        lw == ew || _ir_error(inst,
                            "sret vector store at byte offset $byte_off has lane " *
                            "width $lw but aggregate element width is $ew")
                        (byte_off % eb == 0) || _ir_error(inst,
                            "sret vector store at byte offset $byte_off is not " *
                            "aligned to element size $eb")
                        n_lanes = Int(LLVM.length(vt))
                        first_slot = byte_off ÷ eb
                        (0 <= first_slot && first_slot + n_lanes <= n) || _ir_error(inst,
                            "sret vector store spans slots [$first_slot, " *
                            "$(first_slot + n_lanes - 1)] which exceed aggregate " *
                            "range [0, $n)")
                        for lane in 0:(n_lanes - 1)
                            slot = first_slot + lane
                            haskey(slot_values, slot) && _ir_error(inst,
                                "sret slot $slot already written; vector store " *
                                "(lane $lane) cannot re-write it")
                            slot_values[slot] = IROperand(:const, :__pending_vec_lane__, lane)
                        end
                        pending_vec[inst.ref] = (first_slot, n_lanes)
                        pending_val_refs[inst.ref] = val.ref
                        push!(suppressed, inst.ref)
                        continue
                    end
                    vt isa LLVM.IntegerType || _ir_error(inst,
                        "sret store at byte offset $byte_off has non-integer value " *
                        "type $vt; only integer stores are supported")
                    sw = LLVM.width(vt)
                    sw == ew || _ir_error(inst,
                        "sret store at byte offset $byte_off has value width $sw, " *
                        "but aggregate element width is $ew (partial-element writes " *
                        "are not supported)")
                    (byte_off % eb == 0) || _ir_error(inst,
                        "sret store at byte offset $byte_off is not aligned to " *
                        "element size $eb (partial-element writes are not supported)")
                    slot = byte_off ÷ eb
                    (0 <= slot < n) || _ir_error(inst,
                        "sret store slot $slot is out of range [0, $n)")
                    if haskey(slot_values, slot)
                        prior = slot_values[slot]
                        if prior.kind == :const && prior.name === :__pending_vec_lane__
                            _ir_error(inst,
                                "sret slot $slot was reserved by an earlier " *
                                "vector sret store; scalar re-write unsupported")
                        else
                            _ir_error(inst,
                                "sret slot $slot has multiple stores; only a single " *
                                "store per slot is supported in MVP (multi-store / " *
                                "conditional sret coverage is a planned extension)")
                        end
                    end
                    slot_values[slot] = _operand(val, names)
                    push!(suppressed, inst.ref)
                    continue
                end
            end
        end
    end

    # Every slot must be written before ret void
    fname = LLVM.name(func)
    for k in 0:(n - 1)
        haskey(slot_values, k) || error(
            "ir_extract.jl: sret slot $k in @$fname is never written; every " *
            "element of the aggregate return must be stored before ret void")
    end

    return (slot_values      = slot_values,
            suppressed       = suppressed,
            pending_vec      = pending_vec,
            pending_val_refs = pending_val_refs)
end

"""
    _resolve_pending_vec_for_val!(sret_writes, produced_ref, lanes) -> Nothing

Bennett-0c8o: if `produced_ref` is the stored value of any pending vector sret
store, resolve its per-lane IROperands from the now-populated `lanes` dict and
write them into `sret_writes.slot_values`. Clears the pending entry. No-op if
`produced_ref` is not a pending value.

Called by the pass-2 walker after each successful `_convert_instruction`.
"""
function _resolve_pending_vec_for_val!(sret_writes,
                                        produced_ref::_LLVMRef,
                                        lanes::Dict{_LLVMRef, Vector{IROperand}})
    isempty(sret_writes.pending_vec) && return nothing
    store_ref = nothing
    for (sref, vref) in sret_writes.pending_val_refs
        if vref === produced_ref
            store_ref = sref
            break
        end
    end
    store_ref === nothing && return nothing

    first_slot, n_lanes = sret_writes.pending_vec[store_ref]
    haskey(lanes, produced_ref) || error(
        "ir_extract.jl: pending sret vector store's stored value " *
        "$(produced_ref) was not registered in the vector-lane table " *
        "during pass 2. The producer of the <N x iM> value is an " *
        "instruction whose vector output isn't decomposed by " *
        "_convert_vector_instruction.")
    per_lane = lanes[produced_ref]
    length(per_lane) == n_lanes || error(
        "ir_extract.jl: pending sret vector store expected $n_lanes lanes " *
        "but got $(length(per_lane)) from the vector-lane table")
    for lane in 0:(n_lanes - 1)
        sret_writes.slot_values[first_slot + lane] = per_lane[lane + 1]
    end
    delete!(sret_writes.pending_vec, store_ref)
    delete!(sret_writes.pending_val_refs, store_ref)
    return nothing
end

"""
    _assert_no_pending_vec_stores!(sret_writes) -> Nothing

Bennett-0c8o: fail loud if any pending sret vector store is unresolved by the
time we synthesise the sret chain at `ret void`. Indicates the producer of the
vector value was never converted during pass 2 (dead-code path, or cc0.3-style
skip swallowed it).
"""
function _assert_no_pending_vec_stores!(sret_writes)
    isempty(sret_writes.pending_vec) && return nothing
    refs = collect(keys(sret_writes.pending_vec))
    error("ir_extract.jl: $(length(refs)) pending sret vector store(s) " *
          "remain unresolved at ret void. This means the producer of the " *
          "stored vector value wasn't processed in pass 2 (likely skipped " *
          "by _convert_instruction's cc0.3 catch-block).")
end

"""
    _synthesize_sret_chain(sret_info, slot_values, counter) -> (Vector{IRInst}, IRRet)

Build an `IRInsertValue` chain that reconstructs the aggregate return value
from the per-slot stored values, terminated by an `IRRet`. Structurally
identical to the `insertvalue` chain LLVM emits for n=2 by-value aggregate
returns, so downstream lowering sees no difference.
"""
function _synthesize_sret_chain(sret_info, slot_values::Dict{Int, IROperand},
                                counter::Ref{Int})
    n  = sret_info.n_elems
    ew = sret_info.elem_width
    chain = IRInst[]
    agg_op = IROperand(:const, :__zero_agg__, 0)
    last_dest = Symbol("")
    for k in 0:(n - 1)
        dest = _auto_name(counter)
        push!(chain, IRInsertValue(dest, agg_op, slot_values[k], k, ew, n))
        agg_op = ssa(dest)
        last_dest = dest
    end
    ret_inst = IRRet(ssa(last_dest), n * ew)
    return (chain, ret_inst)
end

# ---- module walking ----

# Find the entry function. When `entry_function === nothing`, pick the first
# `julia_*` function with a body (the legacy heuristic used by
# `extract_parsed_ir(f, T)`). When a name is supplied, do an exact match on
# `LLVM.name(f)`; fail loud if missing / declaration-only / ambiguous.
function _find_entry_function(mod::LLVM.Module,
                              entry_function::Union{Nothing, AbstractString})
    if entry_function === nothing
        for f in LLVM.functions(mod)
            if startswith(LLVM.name(f), "julia_") && !isempty(LLVM.blocks(f))
                return f
            end
        end
        error("ir_extract.jl: no julia_* function found in LLVM module (the " *
              "extractor expects code_llvm(...; dump_module=true) output with " *
              "at least one non-declaration `julia_` or `j_` function)")
    end

    matches = LLVM.Function[]
    for f in LLVM.functions(mod)
        LLVM.name(f) == String(entry_function) && push!(matches, f)
    end
    if isempty(matches)
        names = [LLVM.name(f) for f in LLVM.functions(mod)]
        candidate_blurb = isempty(names) ? "(module has no functions)" :
            "candidates: " * join(names, ", ")
        error("ir_extract.jl: entry function `$entry_function` not found in " *
              "module. $candidate_blurb")
    end
    if length(matches) > 1
        error("ir_extract.jl: entry function `$entry_function` matches " *
              "$(length(matches)) functions in the module (expected 1)")
    end
    f = matches[1]
    isempty(LLVM.blocks(f)) &&
        error("ir_extract.jl: entry function `$entry_function` is a " *
              "declaration (has no body); provide a module that defines it")
    return f
end

# Dispatch wrapper: preserves the historical `_module_to_parsed_ir(mod)`
# behaviour when called with no selector, and routes to the core walker on
# a selected function.
function _module_to_parsed_ir(mod::LLVM.Module;
                              entry_function::Union{Nothing, AbstractString}=nothing)
    func = _find_entry_function(mod, entry_function)
    return _module_to_parsed_ir_on_func(mod, func)
end

# Core walker: `mod` provides module-scope globals / constants; `func` is the
# entry point (already picked by `_find_entry_function`).
function _module_to_parsed_ir_on_func(mod::LLVM.Module, func::LLVM.Function)
    counter = Ref(0)

    # T1c.2: extract compile-time-constant global arrays so lower_var_gep! can
    # dispatch read-only lookups through QROM instead of a MUX-tree.
    globals = _extract_const_globals(mod)

    # Bennett-dv1z: detect sret calling convention. When present, the LLVM
    # return type is `void`; the aggregate shape comes from the sret attribute.
    sret_info = _detect_sret(func)

    # Return type derivation — sret overrides the void return with the
    # aggregate described by the sret attribute.
    if sret_info !== nothing
        ret_width       = sret_info.n_elems * sret_info.elem_width
        ret_elem_widths = [sret_info.elem_width for _ in 1:sret_info.n_elems]
    else
        ft = LLVM.function_type(func)
        rt = LLVM.return_type(ft)
        ret_width = _type_width(rt)
        ret_elem_widths = if rt isa LLVM.ArrayType
            [LLVM.width(LLVM.eltype(rt)) for _ in 1:LLVM.length(rt)]
        else
            [ret_width]
        end
    end

    # Build name table: LLVMValueRef → Symbol  (two-pass: name everything first)
    names = Dict{_LLVMRef, Symbol}()
    # Bennett-cc0.7: per-lane side table for vector SSA values. Populated
    # during pass 2 in source order by `_convert_vector_instruction`.
    lanes = Dict{_LLVMRef, Vector{IROperand}}()

    # Name parameters
    args = Tuple{Symbol,Int}[]
    # Track pointer params: map ptr SSA name → (base_sym, byte_size) for GEP/load resolution
    ptr_params = Dict{Symbol, Tuple{Symbol, Int}}()
    for (i, p) in enumerate(LLVM.parameters(func))
        nm = LLVM.name(p)
        sym = isempty(nm) ? _auto_name(counter) : Symbol(nm)
        names[p.ref] = sym
        # sret parameter is an output buffer, not a function input. Name it so
        # sret-targeted stores resolve through `names`, but skip adding it to
        # `args` — otherwise the wire allocator would reserve input wires for
        # a value the caller never supplies.
        if sret_info !== nothing && i == sret_info.param_index
            continue
        end
        ptype = LLVM.value_type(p)
        if ptype isa LLVM.IntegerType
            push!(args, (sym, LLVM.width(ptype)))
        elseif ptype isa LLVM.FloatingPointType
            # Float params are just N-bit values (double=64, float=32)
            push!(args, (sym, _type_width(ptype)))
        elseif ptype isa LLVM.PointerType
            # Pointer arg (e.g., NTuple passed by reference)
            # Try to determine size from dereferenceable attribute or skip (pgcstack)
            deref = _get_deref_bytes(func, p)
            if deref > 0
                # Treat as flat wire array: deref bytes × 8 bits
                w = deref * 8
                push!(args, (sym, w))
                ptr_params[sym] = (sym, deref)
            end
            # pgcstack and other non-dereferenceable ptrs are silently skipped
        end
    end

    # Name all instructions (first pass)
    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            nm = LLVM.name(inst)
            names[inst.ref] = isempty(nm) ? _auto_name(counter) : Symbol(nm)
        end
    end

    # sret pre-walk: classify stores/GEPs that target the sret buffer and
    # record the per-slot stored values. Must run after the naming pass so
    # _operand() can resolve SSA references.
    sret_writes = sret_info === nothing ? nothing :
                  _collect_sret_writes(func, sret_info, names)

    # Convert blocks (second pass)
    blocks = IRBasicBlock[]
    for bb in LLVM.blocks(func)
        label = Symbol(LLVM.name(bb))
        insts = IRInst[]
        terminator = nothing

        for inst in LLVM.instructions(bb)
            # sret hook: suppress instructions already accounted for in the
            # pre-walk (sret-targeting stores and their constant-offset GEPs).
            if sret_writes !== nothing && inst.ref in sret_writes.suppressed
                continue
            end
            # sret hook: at `ret void`, emit the synthetic IRInsertValue chain
            # plus IRRet equivalent to the n=2 by-value aggregate-return path.
            if sret_writes !== nothing &&
               LLVM.opcode(inst) == LLVM.API.LLVMRet &&
               isempty(LLVM.operands(inst))
                # Bennett-0c8o: before synthesising, confirm every pending
                # vector sret store was resolved during pass 2.
                _assert_no_pending_vec_stores!(sret_writes)
                chain, ret_inst = _synthesize_sret_chain(
                    sret_info, sret_writes.slot_values, counter)
                append!(insts, chain)
                terminator = ret_inst
                continue
            end

            # Bennett-cc0.3: skip instructions whose dispatch crashes on
            # Julia runtime artifacts — LLVMGlobalAlias refs (ptr globals
            # like @"jl_global#NNN.jit"), or helper calls that assume
            # integer widths on pointer-typed aggregate members. Skipped
            # instructions leave their SSA dest un-bound; downstream
            # consumers that actually read the dest raise an ErrorException
            # at `_operand` lookup time, which still satisfies the T5 corpus
            # `@test_throws`. User arithmetic (which doesn't touch runtime
            # ptrs) extracts normally.
            #
            # Bennett-g27k / U18: gate each benign-skip on BOTH an exception
            # type AND the expected message pattern. The old code matched
            # substrings against `sprint(showerror, e)` alone, so ANY error
            # whose message happened to contain "PointerType", "Unknown
            # value kind", or "LLVMGlobalAlias" got silently swallowed —
            # including unrelated bugs in our own extractor or in user
            # functions. Narrowed matches:
            #   - ErrorException with "Unknown value kind" → LLVM.jl
            #     `value.jl:20` fallback (e.g. LLVMGlobalAlias)
            #   - ErrorException with "LLVMGlobalAlias" → same family
            #   - MethodError with "PointerType" → LLVM.jl dispatch gap on
            #     pointer-typed aggregate members
            # Bennett's own `_ir_error` uses ErrorException too, but its
            # message always begins with `"ir_extract.jl: "`; gating on that
            # prefix is how we distinguish legitimate fail-loud errors from
            # LLVM.jl's "unknown kind" pass-through.
            ir_inst = try
                _convert_instruction(inst, names, counter, lanes)
            catch e
                e isa InterruptException && rethrow()
                msg = sprint(showerror, e)
                bennett_authored = startswith(msg, "ErrorException(") ?
                    false : occursin("ir_extract.jl:", msg) ||
                            occursin("Bennett-", msg)
                benign = !bennett_authored && (
                    (e isa ErrorException && (
                        occursin("Unknown value kind", msg) ||
                        occursin("LLVMGlobalAlias", msg))) ||
                    (e isa MethodError && occursin("PointerType", msg))
                )
                benign ? nothing : rethrow()
            end
            ir_inst === nothing && continue
            # Bennett-0c8o: after each successful conversion, if `inst` was
            # the producer of a pending sret vector store's stored value,
            # harvest its lanes now.
            if sret_writes !== nothing
                _resolve_pending_vec_for_val!(sret_writes, inst.ref, lanes)
            end
            if ir_inst isa Vector
                for sub in ir_inst
                    push!(insts, sub)
                end
            elseif ir_inst isa IRRet || ir_inst isa IRBranch || ir_inst isa IRSwitch
                terminator = ir_inst
            else
                push!(insts, ir_inst)
            end
        end

        terminator === nothing && error(
            "ir_extract.jl: block in @$(LLVM.name(func)):%$label has no terminator")
        push!(blocks, IRBasicBlock(label, insts, terminator))
    end

    # Post-pass: expand switch terminators into cascaded icmp + branch blocks
    blocks = _expand_switches(blocks)

    return ParsedIR(ret_width, args, blocks, ret_elem_widths, globals)
end

"""
Extract constant-initialized integer-array globals from `mod`.

Returns a dict keyed by global name (Symbol) mapping to `(data, elem_width)` where
`data` is the array contents zero-extended into UInt64 (one entry per element) and
`elem_width` is the per-element bit width from the LLVM type.

Skips non-constant globals, globals without a ConstantDataArray initializer,
non-integer element types, and elements wider than 64 bits.
"""
function _extract_const_globals(mod::LLVM.Module)
    out = Dict{Symbol, Tuple{Vector{UInt64}, Int}}()
    for g in LLVM.globals(mod)
        # Julia emits various globals (type references, aliases, dispatch tables)
        # whose initializers we can't meaningfully materialize. Guard with a
        # try/catch because LLVM.initializer errors for unknown value kinds
        # (e.g. GlobalAlias).
        LLVM.isconstant(g) || continue
        init = try
            LLVM.initializer(g)
        catch e
            # Bennett-uinn / U93: re-raise InterruptException (Ctrl-C).
            e isa InterruptException && rethrow()
            # Bennett-8kno / U95: only swallow LLVM.jl's own
            # "Unknown value kind" / "LLVMGlobalAlias" errors —
            # exactly what the comment above predicts. OutOfMemoryError,
            # StackOverflowError, MethodError, and other unexpected
            # exceptions propagate out so a real bug isn't masked.
            msg = sprint(showerror, e)
            benign = e isa ErrorException && (
                occursin("Unknown value kind", msg) ||
                occursin("LLVMGlobalAlias", msg))
            benign ? nothing : rethrow()
        end
        init === nothing && continue
        init isa LLVM.ConstantDataArray || continue
        ty = LLVM.value_type(init)
        ty isa LLVM.ArrayType || continue
        elem_ty = LLVM.eltype(ty)
        elem_ty isa LLVM.IntegerType || continue
        elem_width = LLVM.width(elem_ty)
        1 <= elem_width <= 64 || continue
        n = Int(LLVM.API.LLVMGetArrayLength(ty.ref))
        data = Vector{UInt64}(undef, n)
        for i in 0:(n-1)
            elt_ref = LLVM.API.LLVMGetElementAsConstant(init.ref, i)
            elt = LLVM.Value(elt_ref)
            data[i+1] = elt isa LLVM.ConstantInt ?
                UInt64(LLVM.API.LLVMConstIntGetZExtValue(elt.ref)) : UInt64(0)
        end
        out[Symbol(LLVM.name(g))] = (data, elem_width)
    end
    return out
end

"""
Expand IRSwitch terminators into cascaded comparison blocks.

switch val, default [c1 → L1, c2 → L2, ...] becomes:

    orig   : icmp eq val, c1 → br (L1, _sw_orig_2)
    _sw_2  : icmp eq val, c2 → br (L2, _sw_orig_3)
    ...
    _sw_N  : icmp eq val, cN → br (LN, default)

Phi nodes in successor blocks are rewritten: each pre-expansion incoming
`(val, orig_switch_label)` is replaced by one incoming per unique
post-expansion predecessor block of the phi's host (a target shared by
several cases is reached from the case-1 slot AND the syn block of every
other case pointing at it; the default may share a syn block with the
last case).

Bennett-u21m / U11 fixes:
  (1) Phi patching runs as a single global sweep AFTER all switches have
      been expanded — the old per-switch sweep missed phis in successor
      blocks that hadn't been appended to `result` yet.
  (2) `pred_map` is keyed by `(orig_switch_label, target_label)` and
      stores the full set of synthetic predecessors, so duplicate targets
      no longer collapse into a single wrong incoming.
"""
function _expand_switches(blocks::Vector{IRBasicBlock})
    # Bennett-t3j0 / U83: defensive collision guard. The synthetic block
    # labels emitted below (`_sw_<orig>_<i>` and `_sw_cmp_<orig>_<i>`) and
    # the `:__unreachable__` sentinel produced by `LLVMUnreachable` are
    # reserved namespaces. If an input block already uses one — which
    # would happen on accidental re-run of `_expand_switches` on its own
    # output, or on a future caller passing crafted blocks — silent
    # shadowing would corrupt phi rewiring and topological order.
    for b in blocks
        s = String(b.label)
        startswith(s, "_sw_") &&
            error("_expand_switches: input block label :$(b.label) collides " *
                  "with the reserved synthetic-block prefix `_sw_*`. " *
                  "Likely a re-run on already-expanded blocks (Bennett-t3j0 / U83).")
        b.label === :__unreachable__ &&
            error("_expand_switches: input block named :__unreachable__ " *
                  "collides with the reserved unreachable-target sentinel " *
                  "(Bennett-t3j0 / U83).")
    end

    result = IRBasicBlock[]
    orig_switches = Set{Symbol}()
    # (orig_switch_label, target_label) → ordered list of unique synthetic
    # predecessors of target_label inherited from this switch.
    pred_map = Dict{Tuple{Symbol, Symbol}, Vector{Symbol}}()

    @inline function _add_pred!(orig_label::Symbol, tgt::Symbol, src::Symbol)
        lst = get!(pred_map, (orig_label, tgt), Symbol[])
        src in lst || push!(lst, src)
        return nothing
    end

    # ── Phase A: expand every switch into cmp blocks; populate pred_map ──
    for block in blocks
        if !(block.terminator isa IRSwitch)
            push!(result, block)
            continue
        end

        sw = block.terminator
        orig_label = block.label
        n_cases = length(sw.cases)

        if n_cases == 0
            # Degenerate: just unconditional branch to default.
            push!(result, IRBasicBlock(orig_label, block.instructions,
                                       IRBranch(nothing, sw.default_label, nothing)))
            push!(orig_switches, orig_label)
            _add_pred!(orig_label, sw.default_label, orig_label)
            continue
        end

        push!(orig_switches, orig_label)
        syn_labels = [Symbol("_sw_$(orig_label)_$i") for i in 1:n_cases]

        # First block — the original block keeps its label so existing
        # predecessors still see it, with the first icmp appended.
        cmp_dest_1 = Symbol("_sw_cmp_$(orig_label)_1")
        first_cmp = IRICmp(cmp_dest_1, :eq, sw.cond, sw.cases[1][1], sw.cond_width)
        first_false = n_cases >= 2 ? syn_labels[2] : sw.default_label
        first_br = IRBranch(ssa(cmp_dest_1), sw.cases[1][2], first_false)
        push!(result, IRBasicBlock(orig_label,
                                   vcat(block.instructions, [first_cmp]),
                                   first_br))
        _add_pred!(orig_label, sw.cases[1][2], orig_label)

        # Middle comparison blocks (cases 2..N-1).
        for i in 2:(n_cases - 1)
            cmp_dest = Symbol("_sw_cmp_$(orig_label)_$i")
            cmp = IRICmp(cmp_dest, :eq, sw.cond, sw.cases[i][1], sw.cond_width)
            br = IRBranch(ssa(cmp_dest), sw.cases[i][2], syn_labels[i + 1])
            push!(result, IRBasicBlock(syn_labels[i], [cmp], br))
            _add_pred!(orig_label, sw.cases[i][2], syn_labels[i])
        end

        # Last comparison block: its false-branch goes to the switch default.
        if n_cases >= 2
            cmp_dest_n = Symbol("_sw_cmp_$(orig_label)_$n_cases")
            cmp_n = IRICmp(cmp_dest_n, :eq, sw.cond, sw.cases[n_cases][1], sw.cond_width)
            br_n = IRBranch(ssa(cmp_dest_n), sw.cases[n_cases][2], sw.default_label)
            push!(result, IRBasicBlock(syn_labels[n_cases], [cmp_n], br_n))
            _add_pred!(orig_label, sw.cases[n_cases][2], syn_labels[n_cases])
            _add_pred!(orig_label, sw.default_label,     syn_labels[n_cases])
        else
            # n_cases == 1: default is reached from orig_label's false-branch.
            _add_pred!(orig_label, sw.default_label, orig_label)
        end
    end

    # ── Phase B: global phi patching ───────────────────────────────────
    # For every phi, an incoming `(val, from)` where `from` is an expanded
    # switch label expands to one incoming per unique synthetic predecessor
    # of the phi's host block inherited from that switch. Multiple cases
    # sharing a target produce multiple incomings; a target reached by
    # both default and a case through the same syn block gets deduped by
    # `_add_pred!` above.
    if !isempty(orig_switches)
        for j in eachindex(result)
            blk = result[j]
            new_insts = IRInst[]
            changed = false
            for inst in blk.instructions
                if inst isa IRPhi
                    new_incoming = Tuple{IROperand, Symbol}[]
                    for (val, from_block) in inst.incoming
                        if from_block in orig_switches
                            preds = get(pred_map, (from_block, blk.label), Symbol[])
                            if isempty(preds)
                                # Defensive: phi cited a switch block that
                                # doesn't actually branch to this block.
                                # Leave the incoming alone rather than
                                # silently dropping it; a downstream phi
                                # resolver will raise if this is malformed.
                                push!(new_incoming, (val, from_block))
                            else
                                for p in preds
                                    push!(new_incoming, (val, p))
                                end
                                changed = true
                            end
                        else
                            push!(new_incoming, (val, from_block))
                        end
                    end
                    push!(new_insts, IRPhi(inst.dest, inst.width, new_incoming))
                else
                    push!(new_insts, inst)
                end
            end
            if changed
                result[j] = IRBasicBlock(blk.label, new_insts, blk.terminator)
            end
        end
    end

    return result
end

# ---- instruction conversion ----

function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Symbol},
                              counter::Ref{Int},
                              lanes::Dict{_LLVMRef, Vector{IROperand}}=Dict{_LLVMRef, Vector{IROperand}}())
    opc = LLVM.opcode(inst)
    dest = names[inst.ref]

    # Bennett-cc0.7: SLP-vectorised IR. `<N x iM>` SSA is modelled as N scalar
    # per-lane IROperands in `lanes`; vector ops desugar into N scalar IRInsts.
    # See `docs/design/cc07_consensus.md`. Entire mechanism is contained in
    # this file — `lower.jl` never sees a vector.
    #
    # `_any_vector_operand` catches pre-existing cc0.3 (LLVMGlobalAlias) errors
    # that fire during operand iteration for call instructions (LLVM.jl's
    # LLVM.Value wrapper refuses to materialise GlobalAlias values). Callees
    # are never vectors, so treat iterator exceptions as "no".
    is_vec_result = _safe_is_vector_type(inst)
    if is_vec_result || _any_vector_operand(inst)
        return _convert_vector_instruction(inst, names, lanes, counter)
    end

    # binary arithmetic/logic
    if opc in (LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul,
               LLVM.API.LLVMAnd, LLVM.API.LLVMOr,  LLVM.API.LLVMXor,
               LLVM.API.LLVMShl, LLVM.API.LLVMLShr, LLVM.API.LLVMAShr)
        ops = LLVM.operands(inst)
        return IRBinOp(dest, _opcode_to_sym(opc),
                       _operand(ops[1], names), _operand(ops[2], names),
                       _iwidth(inst))
    end

    # icmp
    if opc == LLVM.API.LLVMICmp
        ops = LLVM.operands(inst)
        return IRICmp(dest, _pred_to_sym(LLVM.predicate(inst)),
                      _operand(ops[1], names), _operand(ops[2], names),
                      _iwidth(ops[1]))
    end

    # select
    if opc == LLVM.API.LLVMSelect
        ops = LLVM.operands(inst)
        # Bennett-cc0 M2b: pointer-typed select uses width=0 sentinel.
        # Pointers don't materialize as wires — routing is recorded in
        # ptr_provenance at lowering time. _type_width stays fail-loud
        # for any other unexpected pointer use (load, binop, etc.).
        w = LLVM.value_type(inst) isa LLVM.PointerType ? 0 : _iwidth(inst)
        return IRSelect(dest, _operand(ops[1], names),
                        _operand(ops[2], names), _operand(ops[3], names), w)
    end

    # phi
    if opc == LLVM.API.LLVMPHI
        incoming = Tuple{IROperand, Symbol}[]
        for (val, blk) in LLVM.incoming(inst)
            push!(incoming, (_operand(val, names), Symbol(LLVM.name(blk))))
        end
        # Bennett-cc0 M2b: pointer-typed phi uses width=0 sentinel.
        w = LLVM.value_type(inst) isa LLVM.PointerType ? 0 : _iwidth(inst)
        return IRPhi(dest, w, incoming)
    end

    # casts
    # division and remainder
    if opc in (LLVM.API.LLVMUDiv, LLVM.API.LLVMSDiv, LLVM.API.LLVMURem, LLVM.API.LLVMSRem)
        opname = opc == LLVM.API.LLVMUDiv ? :udiv :
                 opc == LLVM.API.LLVMSDiv ? :sdiv :
                 opc == LLVM.API.LLVMURem ? :urem : :srem
        ops = LLVM.operands(inst)
        return IRBinOp(dest, opname, _operand(ops[1], names), _operand(ops[2], names), _iwidth(inst))
    end

    if opc in (LLVM.API.LLVMSExt, LLVM.API.LLVMZExt, LLVM.API.LLVMTrunc)
        opname = opc == LLVM.API.LLVMSExt ? :sext :
                 opc == LLVM.API.LLVMZExt ? :zext : :trunc
        src = LLVM.operands(inst)[1]
        return IRCast(dest, opname, _operand(src, names), _iwidth(src), _iwidth(inst))
    end

    # branch
    if opc == LLVM.API.LLVMBr && inst isa LLVM.BrInst
        succs = LLVM.successors(inst)
        if LLVM.isconditional(inst)
            return IRBranch(_operand(LLVM.condition(inst), names),
                            Symbol(LLVM.name(succs[1])),
                            Symbol(LLVM.name(succs[2])))
        else
            return IRBranch(nothing, Symbol(LLVM.name(succs[1])), nothing)
        end
    end

    # ret
    if opc == LLVM.API.LLVMRet
        ops = LLVM.operands(inst)
        return IRRet(_operand(ops[1], names), _iwidth(ops[1]))
    end

    # extractvalue — select one element from an aggregate.
    # Bennett-tu6i / U10: only ArrayType aggregates are supported (homogeneous,
    # scalar-element). StructType aggregates ({iN, i1}, mixed-width tuples,
    # .with.overflow intrinsics, cmpxchg results) need field-wise width
    # tracking that IRExtractValue doesn't carry. Fail loud on StructType —
    # without this guard, `LLVM.eltype(struct_type)` raises a raw UndefRefError
    # deep in the LLVM.jl bindings with no Bennett context.
    if opc == LLVM.API.LLVMExtractValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        idx_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = unsafe_load(idx_ptr)  # 0-based
        agg_type = LLVM.value_type(agg_val)
        agg_type isa LLVM.ArrayType || _ir_error(inst,
            "extractvalue on StructType aggregates not supported; " *
            "only homogeneous ArrayType aggregates are. Source type: " *
            string(agg_type))
        ew = LLVM.width(LLVM.eltype(agg_type))
        ne = LLVM.length(agg_type)
        return IRExtractValue(dest, _operand(agg_val, names), idx, ew, ne)
    end

    # insertvalue — same ArrayType-only restriction as extractvalue.
    if opc == LLVM.API.LLVMInsertValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        elem_val = ops[2]
        idxs_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = Int(unsafe_wrap(Array, idxs_ptr, 1)[1])
        agg_type = LLVM.value_type(inst)
        agg_type isa LLVM.ArrayType || _ir_error(inst,
            "insertvalue on StructType aggregates not supported; " *
            "only homogeneous ArrayType aggregates are. Destination type: " *
            string(agg_type))
        ew = LLVM.width(LLVM.eltype(agg_type))
        ne = LLVM.length(agg_type)
        return IRInsertValue(dest, _operand(agg_val, names),
                             _operand(elem_val, names), idx, ew, ne)
    end

    # unreachable — dead code
    if opc == LLVM.API.LLVMUnreachable
        return IRBranch(nothing, :__unreachable__, nothing)
    end

    # call instructions: handle known LLVM intrinsics, skip the rest
    if opc == LLVM.API.LLVMCall
        ops = LLVM.operands(inst)
        n_ops = length(ops)
        if n_ops >= 1
            cname = try
                LLVM.name(ops[n_ops])
            catch e
                e isa InterruptException && rethrow()
                ""
            end
            if startswith(cname, "llvm.umax")
                cmp_dest = _auto_name(counter)
                w = _iwidth(ops[1])
                return [
                    IRICmp(cmp_dest, :uge, _operand(ops[1], names), _operand(ops[2], names), w),
                    IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
                ]
            end
            if startswith(cname, "llvm.umin")
                cmp_dest = _auto_name(counter)
                w = _iwidth(ops[1])
                return [
                    IRICmp(cmp_dest, :ule, _operand(ops[1], names), _operand(ops[2], names), w),
                    IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
                ]
            end
            if startswith(cname, "llvm.smax")
                cmp_dest = _auto_name(counter)
                w = _iwidth(ops[1])
                return [
                    IRICmp(cmp_dest, :sge, _operand(ops[1], names), _operand(ops[2], names), w),
                    IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
                ]
            end
            if startswith(cname, "llvm.smin")
                cmp_dest = _auto_name(counter)
                w = _iwidth(ops[1])
                return [
                    IRICmp(cmp_dest, :sle, _operand(ops[1], names), _operand(ops[2], names), w),
                    IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
                ]
            end
            # llvm.abs.iN(x, is_int_min_poison) = x >= 0 ? x : 0 - x
            if startswith(cname, "llvm.abs")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                neg_dest = _auto_name(counter)
                cmp_dest = _auto_name(counter)
                return [
                    IRBinOp(neg_dest, :sub, iconst(0), x_op, w),
                    IRICmp(cmp_dest, :sge, x_op, iconst(0), w),
                    IRSelect(dest, ssa(cmp_dest), x_op, ssa(neg_dest), w),
                ]
            end
            # llvm.ctpop.iN(x) = popcount(x)
            # Expand: sum of individual bits via cascaded add
            if startswith(cname, "llvm.ctpop")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                result = IRInst[]
                # Extract each bit: bit_i = (x >> i) & 1
                # Then sum them up: result = bit_0 + bit_1 + ... + bit_{W-1}
                prev = _auto_name(counter)
                push!(result, IRBinOp(prev, :and, x_op, iconst(1), w))
                for i in 1:(w - 1)
                    shifted = _auto_name(counter)
                    bit = _auto_name(counter)
                    acc = _auto_name(counter)
                    push!(result, IRBinOp(shifted, :lshr, x_op, iconst(i), w))
                    push!(result, IRBinOp(bit, :and, ssa(shifted), iconst(1), w))
                    push!(result, IRBinOp(acc, :add, ssa(prev), ssa(bit), w))
                    prev = acc
                end
                # Rename last accumulator to dest
                push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
                return result
            end
            # llvm.ctlz.iN(x, is_zero_poison) = count leading zeros
            # Expand: cascade LSB→MSB so highest set bit wins (overwrites last)
            if startswith(cname, "llvm.ctlz")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                result = IRInst[]
                prev = _auto_name(counter)
                push!(result, IRBinOp(prev, :add, iconst(w), iconst(0), w))  # default: W (all zeros)
                for i in 0:(w - 1)  # LSB to MSB; last match = highest bit = correct clz
                    shifted = _auto_name(counter)
                    bit = _auto_name(counter)
                    is_set = _auto_name(counter)
                    new_val = _auto_name(counter)
                    push!(result, IRBinOp(shifted, :lshr, x_op, iconst(i), w))
                    push!(result, IRBinOp(bit, :and, ssa(shifted), iconst(1), w))
                    push!(result, IRICmp(is_set, :ne, ssa(bit), iconst(0), w))
                    push!(result, IRSelect(new_val, ssa(is_set), iconst(w - 1 - i), ssa(prev), w))
                    prev = new_val
                end
                push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
                return result
            end
            # llvm.cttz.iN(x, is_zero_poison) = count trailing zeros
            # Cascade MSB→LSB so lowest set bit wins (overwrites last)
            if startswith(cname, "llvm.cttz")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                result = IRInst[]
                prev = _auto_name(counter)
                push!(result, IRBinOp(prev, :add, iconst(w), iconst(0), w))
                for i in (w - 1):-1:0  # MSB to LSB; last match = lowest bit = correct ctz
                    shifted = _auto_name(counter)
                    bit = _auto_name(counter)
                    is_set = _auto_name(counter)
                    new_val = _auto_name(counter)
                    push!(result, IRBinOp(shifted, :lshr, x_op, iconst(i), w))
                    push!(result, IRBinOp(bit, :and, ssa(shifted), iconst(1), w))
                    push!(result, IRICmp(is_set, :ne, ssa(bit), iconst(0), w))
                    push!(result, IRSelect(new_val, ssa(is_set), iconst(i), ssa(prev), w))
                    prev = new_val
                end
                push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
                return result
            end
            # llvm.bitreverse.iN(x) = reverse bit order
            # Expand: for each bit, shift to mirrored position and OR together
            if startswith(cname, "llvm.bitreverse")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                result = IRInst[]
                # bit_i → position (W-1-i): shift right by i, mask, shift left by (W-1-i)
                prev = _auto_name(counter)
                # First bit
                shifted0 = _auto_name(counter)
                push!(result, IRBinOp(shifted0, :lshr, x_op, iconst(0), w))
                push!(result, IRBinOp(prev, :and, ssa(shifted0), iconst(1), w))
                shl0 = _auto_name(counter)
                push!(result, IRBinOp(shl0, :shl, ssa(prev), iconst(w - 1), w))
                prev = shl0
                for i in 1:(w - 1)
                    shifted = _auto_name(counter)
                    bit = _auto_name(counter)
                    placed = _auto_name(counter)
                    acc = _auto_name(counter)
                    push!(result, IRBinOp(shifted, :lshr, x_op, iconst(i), w))
                    push!(result, IRBinOp(bit, :and, ssa(shifted), iconst(1), w))
                    push!(result, IRBinOp(placed, :shl, ssa(bit), iconst(w - 1 - i), w))
                    push!(result, IRBinOp(acc, :or, ssa(prev), ssa(placed), w))
                    prev = acc
                end
                push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
                return result
            end
            # llvm.bswap.iN(x) = reverse byte order (N must be multiple of 16)
            if startswith(cname, "llvm.bswap")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                n_bytes = w ÷ 8
                result = IRInst[]
                # Extract each byte, shift to swapped position, OR together
                prev = _auto_name(counter)
                byte0 = _auto_name(counter)
                push!(result, IRBinOp(byte0, :and, x_op, iconst(255), w))
                push!(result, IRBinOp(prev, :shl, ssa(byte0), iconst((n_bytes - 1) * 8), w))
                for b in 1:(n_bytes - 1)
                    shifted = _auto_name(counter)
                    byte_val = _auto_name(counter)
                    placed = _auto_name(counter)
                    acc = _auto_name(counter)
                    push!(result, IRBinOp(shifted, :lshr, x_op, iconst(b * 8), w))
                    push!(result, IRBinOp(byte_val, :and, ssa(shifted), iconst(255), w))
                    push!(result, IRBinOp(placed, :shl, ssa(byte_val), iconst((n_bytes - 1 - b) * 8), w))
                    push!(result, IRBinOp(acc, :or, ssa(prev), ssa(placed), w))
                    prev = acc
                end
                push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
                return result
            end
            # llvm.fshl.i64(a, b, shift) = (a << shift) | (b >> (64 - shift))
            if startswith(cname, "llvm.fshl")
                w = _iwidth(ops[1])
                a_op = _operand(ops[1], names)
                b_op = _operand(ops[2], names)
                sh_op = _operand(ops[3], names)
                shl_dest = _auto_name(counter)
                lshr_dest = _auto_name(counter)
                if sh_op.kind == :const
                    # Constant-fold: w - const is const (no runtime sub needed)
                    return [
                        IRBinOp(shl_dest, :shl, a_op, sh_op, w),
                        IRBinOp(lshr_dest, :lshr, b_op, iconst(w - sh_op.value), w),
                        IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
                    ]
                else
                    rsh_amount = _auto_name(counter)
                    return [
                        IRBinOp(shl_dest, :shl, a_op, sh_op, w),
                        IRBinOp(rsh_amount, :sub, iconst(w), sh_op, w),
                        IRBinOp(lshr_dest, :lshr, b_op, ssa(rsh_amount), w),
                        IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
                    ]
                end
            end
            # llvm.fshr.i64(a, b, shift) = (a << (64 - shift)) | (b >> shift)
            if startswith(cname, "llvm.fshr")
                w = _iwidth(ops[1])
                a_op = _operand(ops[1], names)
                b_op = _operand(ops[2], names)
                sh_op = _operand(ops[3], names)
                shl_dest = _auto_name(counter)
                lshr_dest = _auto_name(counter)
                if sh_op.kind == :const
                    # Constant-fold: w - const is const
                    return [
                        IRBinOp(shl_dest, :shl, a_op, iconst(w - sh_op.value), w),
                        IRBinOp(lshr_dest, :lshr, b_op, sh_op, w),
                        IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
                    ]
                else
                    shl_amount = _auto_name(counter)
                    return [
                        IRBinOp(shl_amount, :sub, iconst(w), sh_op, w),
                        IRBinOp(shl_dest, :shl, a_op, ssa(shl_amount), w),
                        IRBinOp(lshr_dest, :lshr, b_op, sh_op, w),
                        IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
                    ]
                end
            end
            # llvm.fabs: clear sign bit (AND with ~sign_bit)
            if startswith(cname, "llvm.fabs")
                w = _iwidth(ops[1])
                mask = w == 64 ? typemax(Int64) : Int((1 << (w - 1)) - 1)
                return IRBinOp(dest, :and, _operand(ops[1], names), iconst(mask), w)
            end
            # llvm.copysign: (x AND ~sign_bit) OR (y AND sign_bit)
            if startswith(cname, "llvm.copysign")
                w = _iwidth(ops[1])
                mag_mask = w == 64 ? typemax(Int64) : Int((1 << (w - 1)) - 1)
                sign_bit = w == 64 ? typemin(Int64) : Int(1 << (w - 1))
                x_op = _operand(ops[1], names)
                y_op = _operand(ops[2], names)
                mag = _auto_name(counter)
                sgn = _auto_name(counter)
                return [
                    IRBinOp(mag, :and, x_op, iconst(mag_mask), w),
                    IRBinOp(sgn, :and, y_op, iconst(sign_bit), w),
                    IRBinOp(dest, :or, ssa(mag), ssa(sgn), w),
                ]
            end
            # llvm.floor / llvm.ceil / llvm.trunc / llvm.rint / llvm.round
            if startswith(cname, "llvm.floor") || startswith(cname, "llvm.ceil") ||
               startswith(cname, "llvm.trunc") || startswith(cname, "llvm.rint") ||
               startswith(cname, "llvm.round")
                # Route through soft_floor/ceil/trunc via SoftFloat dispatch
                # These are handled by the callee registry (registered soft_floor etc.)
                # At the LLVM level, these operate on native floats — but in the
                # SoftFloat wrapper path, Julia dispatches to our SoftFloat methods
                # which call soft_floor/ceil/trunc on UInt64. Those are registered
                # callees, so ir_extract picks them up via _lookup_callee.
                # Skip: let the standard callee path handle it.
            end
            # llvm.minnum / llvm.maxnum / llvm.minimum / llvm.maximum
            if startswith(cname, "llvm.minnum") || startswith(cname, "llvm.minimum")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                y_op = _operand(ops[2], names)
                cmp = _auto_name(counter)
                return [
                    IRICmp(cmp, :slt, x_op, y_op, w),
                    IRSelect(dest, ssa(cmp), x_op, y_op, w),
                ]
            end
            if startswith(cname, "llvm.maxnum") || startswith(cname, "llvm.maximum")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                y_op = _operand(ops[2], names)
                cmp = _auto_name(counter)
                return [
                    IRICmp(cmp, :sgt, x_op, y_op, w),
                    IRSelect(dest, ssa(cmp), x_op, y_op, w),
                ]
            end
        end
        # Known Julia function calls → IRCall for gate-level inlining
        if n_ops >= 1
            callee = _lookup_callee(cname)
            if callee !== nothing
                # Operands: first n_ops-1 are arguments, last is the callee
                # Skip pgcstack arg (first operand in swiftcc)
                call_args = IROperand[]
                call_widths = Int[]
                for i in 1:(n_ops - 1)
                    op = ops[i]
                    ot = LLVM.value_type(op)
                    ot isa LLVM.IntegerType || continue  # skip ptr args (pgcstack)
                    push!(call_args, _operand(op, names))
                    push!(call_widths, LLVM.width(ot))
                end
                ret_w = _iwidth(inst)
                return IRCall(dest, callee, call_args, call_widths, ret_w)
            end
        end

        # Bennett-5oyt / U15: falling through here means no intrinsic
        # handler matched and no callee is registered. Without this guard
        # the instruction was silently dropped, leaving its dest SSA
        # undefined and later references crashing with "Undefined SSA
        # variable" far from the root cause. Explicit allowlist of benign
        # LLVM intrinsics (memory-range annotations, optimizer hints, debug
        # info, noalias scope decls) that are correctness-neutral to drop;
        # everything else — including inline assembly — errors loud.
        benign_prefixes = (
            "llvm.lifetime.",
            "llvm.assume",
            "llvm.dbg.",
            "llvm.experimental.noalias.scope.decl",
            "llvm.invariant.start",
            "llvm.invariant.end",
            "llvm.sideeffect",
            # llvm.memset appears in Julia IR for GC-frame zeroing etc.;
            # reversible pipeline treats allocations separately.
            "llvm.memset",
            # llvm.memcpy's sret-specific path is handled upstream via
            # auto-SROA (Bennett-uyf9 / γ); non-sret forms are rare in
            # our corpus and route through the same benign-drop gate.
            "llvm.memcpy",
            "llvm.memmove",
            # `llvm.trap` is Julia's unreachable-code marker (produced by
            # type-conservative codegen for branches the compiler can't
            # prove dead). Same unreachability argument as `j_throw_*`:
            # silent drop matches pre-fix behaviour; reachable traps on
            # valid input would be a compilation bug upstream.
            "llvm.trap",
            "llvm.debugtrap",
            # Julia runtime throw helpers. For pure-bit-op functions on
            # UInt64 (the soft-float kernels) these are unreachable dead
            # code that Julia's type-conservative codegen emits anyway.
            # Silent drop matches pre-fix behaviour; see U15 note: any
            # function whose throw path IS reachable on valid input would
            # silently produce garbage, which is the same gap as before.
            "j_throw_",
            "ijl_throw",
            "jl_throw",
            "ijl_bounds_error",
            "jl_bounds_error",
            # Julia meta-ops (GC safepoint, pointer_from_objref, etc.).
            "julia.safepoint",
            "julia.gc_",
            "julia.pointer_from_objref",
            "julia.push_gc_frame",
            "julia.pop_gc_frame",
            "julia.get_gc_frame_slot",
        )
        if any(p -> startswith(cname, p), benign_prefixes)
            return nothing
        end
        # Inline asm: the callee operand is not a named function value.
        is_inline_asm = n_ops == 0 || LLVM.API.LLVMIsAInlineAsm(ops[n_ops]) != C_NULL
        is_inline_asm && _ir_error(inst,
            "inline-asm call is not supported (Bennett-5oyt / U15)")
        # Unregistered callee or unrecognised intrinsic.
        _ir_error(inst,
            "call to '$(cname)' has no registered callee handler or " *
            "intrinsic pattern; register via `register_callee!` or " *
            "extend the LLVMCall arm in ir_extract.jl " *
            "(Bennett-5oyt / U15)")
    end

    # GEP with constant or variable offset
    if opc == LLVM.API.LLVMGetElementPtr
        ops = LLVM.operands(inst)
        base = ops[1]
        # Case A: base is a local SSA value that we've already named
        if haskey(names, base.ref) && length(ops) == 2
            if ops[2] isa LLVM.ConstantInt
                # Constant-index GEP → IRPtrOffset (wire selection from flat array).
                # Bennett-vz5n / U12: `IRPtrOffset.offset_bytes` is consumed at
                # `lower.jl:1691` as `bit_offset = offset_bytes * 8`. The raw
                # GEP index must be scaled by the source element's byte stride
                # before being stored — for `gep i32, ptr %p, i64 1` the raw
                # index is 1 but the actual byte offset is 4. Reading
                # LLVMGetGEPSourceElementType and multiplying by `width÷8`
                # keeps the consumer semantics (`offset_bytes * 8 == bit_offset`)
                # correct for every integer stride.
                # Non-integer source types (struct/array/float/vector) fall
                # through to the pre-existing raw-index behaviour — their
                # correctness gap is tracked separately under U16
                # (multi-index struct GEPs). For integer strides the fix
                # here is unconditional; other paths are unchanged.
                raw_idx = _const_int_as_int(ops[2])
                src_ty_ref_const = LLVM.API.LLVMGetGEPSourceElementType(inst)
                src_type_const = LLVM.LLVMType(src_ty_ref_const)
                offset = if src_type_const isa LLVM.IntegerType
                    stride_bytes = LLVM.width(src_type_const) ÷ 8
                    stride_bytes >= 1 || _ir_error(inst,
                        "constant-index GEP with sub-byte source element " *
                        "width $(LLVM.width(src_type_const)) bits not " *
                        "supported (Bennett-vz5n / U12)")
                    raw_idx * stride_bytes
                else
                    # Struct / array / float / vector base: legacy raw-index
                    # behaviour. Silent-pass, tracked in U16.
                    raw_idx
                end
                return IRPtrOffset(dest, ssa(names[base.ref]), offset)
            else
                # Variable-index GEP → IRVarGEP (MUX-tree selection at lowering time)
                # Bennett-plb7 / U13: fail loud when the source element isn't
                # an integer. The old `? LLVM.width : 8` default silently turned
                # a `gep double, ptr %p, i64 %i` (stride 64) into an
                # `elem_width = 8` GEP, selecting bit 2 instead of double 2.
                idx_op = _operand(ops[2], names)
                src_ty_ref = LLVM.API.LLVMGetGEPSourceElementType(inst)
                src_type = LLVM.LLVMType(src_ty_ref)
                src_type isa LLVM.IntegerType || _ir_error(inst,
                    "variable-index getelementptr with non-integer source " *
                    "element type $(src_type) not supported; cannot infer " *
                    "a bit-exact elem_width (Bennett-plb7 / U13)")
                ew = LLVM.width(src_type)
                return IRVarGEP(dest, ssa(names[base.ref]), idx_op, ew)
            end
        end
        # Case B: base is a global constant (T1c.2). Emit IRVarGEP carrying the
        # global's LLVM name as the base symbol; lower_var_gep! looks this up
        # in parsed.globals and dispatches to QROM.
        if base isa LLVM.GlobalVariable && LLVM.isconstant(base) && length(ops) == 2
            gname = Symbol(LLVM.name(base))
            src_ty_ref = LLVM.API.LLVMGetGEPSourceElementType(inst)
            src_type = LLVM.LLVMType(src_ty_ref)
            # Same guard as above (Bennett-plb7 / U13).
            src_type isa LLVM.IntegerType || _ir_error(inst,
                "getelementptr on global with non-integer source element " *
                "type $(src_type) not supported; cannot infer elem_width " *
                "(Bennett-plb7 / U13)")
            ew = LLVM.width(src_type)
            if ops[2] isa LLVM.ConstantInt
                # Compile-time index into a constant table — still synthesizable
                # as IRVarGEP with a constant-kind index.
                offset = _const_int_as_int(ops[2])
                return IRVarGEP(dest, ssa(gname), iconst(offset), ew)
            else
                idx_op = _operand(ops[2], names)
                return IRVarGEP(dest, ssa(gname), idx_op, ew)
            end
        end
        # Bennett-qal5 / U16: anything that reaches here is either a
        # multi-index GEP (`length(ops) > 2`, e.g. `getelementptr
        # [N x iM], ptr %p, i64 0, i64 %i`) or a GEP whose base is
        # neither a named local SSA nor a constant global. Full support
        # needs type-walking byte-offset accumulation (via
        # `LLVMOffsetOfElement`), which is out of scope for the U-series
        # Phase 0 hardening. Fail loud so the missing handler surfaces
        # immediately instead of leaving dest SSA undefined and crashing
        # downstream with "Undefined SSA variable".
        n_idx = length(ops) - 1
        _ir_error(inst,
            "getelementptr with $(n_idx) index(es) or unsupported base " *
            "shape is not handled; supported forms are 2-op GEPs on a " *
            "local SSA value or on a constant GlobalVariable " *
            "(Bennett-qal5 / U16)")
    end

    # Load from pointer → IRLoad (CNOT-copy from wire subset)
    if opc == LLVM.API.LLVMLoad
        # Bennett-4mmt / U14: reject atomic / volatile loads. Reversible
        # circuit compilation has no semantics for ordering guarantees;
        # silently producing a plain IRLoad would erase the source
        # program's atomic contract and turn a correctness bug into a
        # perf "feature".
        LLVM.API.LLVMGetVolatile(inst) == 0 || _ir_error(inst,
            "volatile load not supported (Bennett-4mmt / U14)")
        LLVM.API.LLVMGetOrdering(inst) == LLVM.API.LLVMAtomicOrderingNotAtomic ||
            _ir_error(inst,
                "atomic load not supported (Bennett-4mmt / U14)")
        ops = LLVM.operands(inst)
        ptr = ops[1]
        if haskey(names, ptr.ref)
            rt = LLVM.value_type(inst)
            if rt isa LLVM.IntegerType
                return IRLoad(dest, ssa(names[ptr.ref]), LLVM.width(rt))
            end
        end
        return nothing  # non-integer load — skip
    end

    # switch → IRSwitch (expanded to cascaded branches in post-pass)
    # Operand layout: [condition, default_bb, case_val1, case_bb1, ...]
    if opc == LLVM.API.LLVMSwitch && inst isa LLVM.SwitchInst
        ops = LLVM.operands(inst)
        cond_val = ops[1]
        cond_op = _operand(cond_val, names)
        cond_w = _iwidth(cond_val)
        default_ref = LLVM.API.LLVMGetSwitchDefaultDest(inst)
        default_label = Symbol(unsafe_string(LLVM.API.LLVMGetBasicBlockName(default_ref)))
        n_cases = (length(ops) - 2) ÷ 2
        cases = Tuple{IROperand, Symbol}[]
        for i in 0:(n_cases - 1)
            case_val = ops[3 + 2*i]     # ConstantInt
            case_bb  = ops[4 + 2*i]     # BasicBlock
            case_int = _const_int_as_int(case_val)
            case_op = IROperand(:const, Symbol(string(case_int)), case_int)
            target_label = Symbol(LLVM.name(case_bb))
            push!(cases, (case_op, target_label))
        end
        return IRSwitch(cond_op, cond_w, default_label, cases)
    end

    # freeze: identity (removes poison/undef, no-op for reversible circuits)
    if opc == LLVM.API.LLVMFreeze
        src = LLVM.operands(inst)[1]
        w = _iwidth(src)
        return IRBinOp(dest, :add, _operand(src, names), iconst(0), w)
    end

    # fptosi/fptoui: float → int conversion via soft_fptosi / soft_fptoui.
    # Bennett-b1vp / U31: fptoui must NOT route through fptosi — the signed
    # converter sign-reinterprets in-range values that require the high bit
    # of an unsigned 64-bit integer (e.g. 1e19). Dispatch per opcode.
    if opc in (LLVM.API.LLVMFPToSI, LLVM.API.LLVMFPToUI)
        src = LLVM.operands(inst)[1]
        src_w = _iwidth(src)
        dst_w = _iwidth(inst)
        callee_name = opc == LLVM.API.LLVMFPToUI ? "soft_fptoui" : "soft_fptosi"
        callee = _lookup_callee(callee_name)
        if callee !== nothing && src_w == 64
            # Route through the signed/unsigned softfloat callee for Float64 → iN.
            call_result = IRCall(dest, callee, [_operand(src, names)], [src_w], dst_w)
            if dst_w == src_w
                return call_result
            else
                # Need to truncate the 64-bit result to the target width
                trunc_dest = dest
                call_dest = _auto_name(counter)
                return [
                    IRCall(call_dest, callee, [_operand(src, names)], [src_w], 64),
                    IRCast(dest, :trunc, ssa(call_dest), 64, dst_w),
                ]
            end
        end
        # Fallback: treat as width conversion (for non-Float64 or when callee not registered)
        return IRCast(dest, dst_w < src_w ? :trunc : (dst_w > src_w ? :zext : :trunc), _operand(src, names), src_w, dst_w)
    end

    # sitofp/uitofp: int → float conversion via soft_sitofp (actual IEEE 754 encode)
    if opc in (LLVM.API.LLVMSIToFP, LLVM.API.LLVMUIToFP)
        src = LLVM.operands(inst)[1]
        src_w = _iwidth(src)
        dst_w = _iwidth(inst)
        callee = _lookup_callee("soft_sitofp")
        if callee !== nothing && dst_w == 64
            if src_w == 64
                return IRCall(dest, callee, [_operand(src, names)], [src_w], dst_w)
            else
                # Widen source to 64-bit first, then convert
                widen_dest = _auto_name(counter)
                cast_op = opc == LLVM.API.LLVMSIToFP ? :sext : :zext
                return [
                    IRCast(widen_dest, cast_op, _operand(src, names), src_w, 64),
                    IRCall(dest, callee, [ssa(widen_dest)], [64], 64),
                ]
            end
        end
        # Fallback
        return IRCast(dest, dst_w > src_w ? :zext : (dst_w < src_w ? :trunc : :trunc), _operand(src, names), src_w, dst_w)
    end

    # fcmp: floating-point comparison. Route through soft_fcmp_* functions.
    if opc == LLVM.API.LLVMFCmp
        ops = LLVM.operands(inst)
        pred = LLVM.predicate(inst)
        op1 = _operand(ops[1], names)
        op2 = _operand(ops[2], names)
        w = _iwidth(ops[1])
        # Map LLVM FCmp predicates to soft_fcmp functions
        # LLVM predicates: OEQ=1, OGT=2, OGE=3, OLT=4, OLE=5, ONE=6, ORD=7, UNO=8, UEQ=9, UGT=10, UGE=11, ULT=12, ULE=13, UNE=14
        pred_int = Int(pred)
        if pred_int == 4  # OLT: a < b
            callee = _lookup_callee("soft_fcmp_olt")
        elseif pred_int == 1  # OEQ: a == b
            callee = _lookup_callee("soft_fcmp_oeq")
        elseif pred_int == 5  # OLE: a <= b
            callee = _lookup_callee("soft_fcmp_ole")
        elseif pred_int == 14  # UNE: a != b or NaN
            callee = _lookup_callee("soft_fcmp_une")
        elseif pred_int == 2  # OGT: a > b → olt(b, a)
            callee = _lookup_callee("soft_fcmp_olt")
            op1, op2 = op2, op1  # swap
        elseif pred_int == 3  # OGE: a >= b → ole(b, a)
            callee = _lookup_callee("soft_fcmp_ole")
            op1, op2 = op2, op1  # swap
        # Bennett-d77b / U132: 6 new direct predicates + 2 more swap-derived
        elseif pred_int == 6  # ONE: ordered not-equal
            callee = _lookup_callee("soft_fcmp_one")
        elseif pred_int == 7  # ORD: neither NaN
            callee = _lookup_callee("soft_fcmp_ord")
        elseif pred_int == 8  # UNO: at least one NaN
            callee = _lookup_callee("soft_fcmp_uno")
        elseif pred_int == 9  # UEQ: unordered equal
            callee = _lookup_callee("soft_fcmp_ueq")
        elseif pred_int == 10  # UGT: a > b unordered → ult(b, a)
            callee = _lookup_callee("soft_fcmp_ult")
            op1, op2 = op2, op1  # swap
        elseif pred_int == 11  # UGE: a >= b unordered → ule(b, a)
            callee = _lookup_callee("soft_fcmp_ule")
            op1, op2 = op2, op1  # swap
        elseif pred_int == 12  # ULT: unordered less-than
            callee = _lookup_callee("soft_fcmp_ult")
        elseif pred_int == 13  # ULE: unordered less-than-or-equal
            callee = _lookup_callee("soft_fcmp_ule")
        else
            _ir_error(inst, "unsupported fcmp predicate $pred_int")
        end
        callee === nothing && _ir_error(inst,
            "soft_fcmp callee not registered for fcmp predicate $pred_int")
        # soft_fcmp returns UInt64 (0 or 1), but fcmp result is i1.
        # Use IRCall with ret_width=1 and let lowering truncate.
        call_dest = _auto_name(counter)
        return [
            IRCall(call_dest, callee, [op1, op2], [w, w], w),
            IRCast(dest, :trunc, ssa(call_dest), w, 1),
        ]
    end

    # bitcast: reinterpret bits as different type (same width). Zero gates — wire aliasing.
    if opc == LLVM.API.LLVMBitCast
        src = LLVM.operands(inst)[1]
        src_w = _iwidth(src)
        dst_w = _iwidth(inst)
        # Same width: identity (just alias the wires). Different width shouldn't happen per LLVM spec.
        src_w == dst_w || _ir_error(inst, "bitcast width mismatch: $src_w → $dst_w")
        return IRCast(dest, :trunc, _operand(src, names), src_w, dst_w)
    end

    # fneg: floating-point negation. XOR the sign bit.
    if opc == LLVM.API.LLVMFNeg
        src = LLVM.operands(inst)[1]
        w = _iwidth(src)
        # Sign bit is bit w-1. For w=64, 1<<63 overflows Int64, so use negative literal.
        sign_bit = w == 64 ? typemin(Int64) : Int(1 << (w - 1))
        return IRBinOp(dest, :xor, _operand(src, names), iconst(sign_bit), w)
    end

    # store: `store ty val, ptr p` -> IRStore (no dest — void in LLVM).
    if opc == LLVM.API.LLVMStore
        # Bennett-4mmt / U14: reject atomic / volatile stores — same
        # reasoning as the load guard above.
        LLVM.API.LLVMGetVolatile(inst) == 0 || _ir_error(inst,
            "volatile store not supported (Bennett-4mmt / U14)")
        LLVM.API.LLVMGetOrdering(inst) == LLVM.API.LLVMAtomicOrderingNotAtomic ||
            _ir_error(inst,
                "atomic store not supported (Bennett-4mmt / U14)")
        ops = LLVM.operands(inst)
        val = ops[1]
        ptr = ops[2]
        vt = LLVM.value_type(val)
        # Bennett-lgzx / U114: was `vt isa LLVM.IntegerType || return nothing`
        # — silent drop violated CLAUDE.md §1. Error loud with the
        # actual stored-value type so the user can debug.
        vt isa LLVM.IntegerType || _ir_error(inst,
            "store of non-integer type $(vt) not supported " *
            "(Bennett-lgzx / U114). SoftFloat dispatch should reroute " *
            "Float64 stores to integer wrappers before extraction.")
        # Bennett-lgzx / U114: was `haskey(names, ptr.ref) || return nothing`
        # — silent drop. Error loud naming the pointer so the user can
        # trace the missing SSA registration.
        haskey(names, ptr.ref) || _ir_error(inst,
            "store target pointer is not a registered SSA name " *
            "(value=$(ptr)) — likely an unsupported pointer source " *
            "such as a global, ConstantExpr, or alias (Bennett-lgzx / U114).")
        return IRStore(ssa(names[ptr.ref]),
                       _operand(val, names),
                       LLVM.width(vt))
    end

    # alloca: `%dest = alloca ty[, i32 N]` -> IRAlloca. Only integer element
    # types are lowered; float / aggregate / pointer element types are skipped
    # (matches IRLoad policy — SoftFloat dispatch maps Float64 to UInt64
    # before IR extraction, so float allocas are rare in practice).
    # n_elems is :const if the operand is a ConstantInt, else :ssa (dynamic —
    # lowering currently rejects :ssa).
    if opc == LLVM.API.LLVMAlloca
        elem_ty = LLVM.LLVMType(LLVM.API.LLVMGetAllocatedType(inst.ref))
        elem_ty isa LLVM.IntegerType || return nothing
        elem_w = LLVM.width(elem_ty)
        ops = LLVM.operands(inst)
        n_elems_op = if !isempty(ops) && ops[1] isa LLVM.ConstantInt
            iconst(_const_int_as_int(ops[1]))
        elseif !isempty(ops) && haskey(names, ops[1].ref)
            ssa(names[ops[1].ref])
        else
            iconst(1)  # scalar alloca with no explicit count
        end
        return IRAlloca(dest, elem_w, n_elems_op)
    end

    _ir_error(inst, "unsupported LLVM opcode")
end

# ---- Bennett-cc0.7: vector SSA scalarisation ----
#
# LLVM's SLP pass vectorises sequential same-type ops into `<N x iM>` SIMD.
# Bennett has no native vector lowering. We scalarise at the extractor:
# every vector SSA ref maps to N per-lane IROperands in `lanes`; vector ops
# desugar into N independent scalar IRInsts. insertelement / shufflevector
# are pure SSA plumbing (emit nothing, mutate `lanes`). extractelement renames
# via `IRBinOp(:add, lane, 0, w)` — known ~W+2 gates per extract, acceptable
# MVP cost (see `docs/design/cc07_consensus.md` §Choice 4).

# ---- Bennett-cc0.3: LLVMGlobalAlias handling ----
#
# LLVM.jl has no Julia wrapper for LLVMGlobalAliasValueKind (enum 6) — its
# `identify` function raises when `LLVM.Value(ref)` is called on such a ref.
# Julia's runtime emits GlobalAliases liberally for JIT-loaded global slots
# (@"jl_global#NNN.jit") that user code can't meaningfully read. We resolve
# the aliasee via raw C API when possible; otherwise fall back to a sentinel
# that flows through ParsedIR and is rejected fail-loud at lowering time.
# See `docs/design/cc03_05_consensus.md`.

# Sentinel `IROperand` for pointer values the extractor cannot materialise as
# a concrete wire reference. Produced when GlobalAlias resolution fails or
# when a ConstantExpr's sub-operands can't be wrapped. Consumers that treat
# it as user arithmetic fail loud in `lower.jl`'s `resolve!`.
const OPAQUE_PTR_SENTINEL = IROperand(:const, :__opaque_ptr__, 0)

# Follow a GlobalAlias chain via raw C API (LLVM.jl has no `aliasee`
# accessor). Returns the terminal non-alias ref, or nothing on cycles,
# depth overflow, or NULL. Depth cap 16 is well beyond anything Julia emits.
function _resolve_aliasee(ref::_LLVMRef)::Union{_LLVMRef, Nothing}
    ref == C_NULL && return nothing
    seen = Set{_LLVMRef}()
    cur = ref
    for _ in 1:16
        cur in seen && return nothing         # cycle guard
        push!(seen, cur)
        kind = LLVM.API.LLVMGetValueKind(cur)
        kind == LLVM.API.LLVMGlobalAliasValueKind || return cur
        next = LLVM.API.LLVMAliasGetAliasee(cur)
        next == C_NULL && return nothing
        cur = next
    end
    return nothing                            # exceeded depth
end

# Iterate an instruction's operands via raw C API, returning a vector of
# `Union{LLVM.Value, Nothing}`. `nothing` slots represent unresolvable
# GlobalAlias operands or operand kinds LLVM.jl refuses to wrap. Use this
# instead of `LLVM.operands(inst)` at sites where a pointer operand could
# be a GlobalAlias — the regular iterator crashes on alias refs.
function _safe_operands(inst::LLVM.Instruction)::Vector{Union{LLVM.Value, Nothing}}
    n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
    out = Vector{Union{LLVM.Value, Nothing}}(undef, n)
    for i in 0:(n - 1)
        ref = LLVM.API.LLVMGetOperand(inst.ref, i)
        resolved = _resolve_aliasee(ref)
        out[i + 1] = resolved === nothing ? nothing : try
            LLVM.Value(resolved)
        catch e
            e isa InterruptException && rethrow()
            nothing
        end
    end
    return out
end

# `_operand` variant that accepts an optional `Nothing` (from `_safe_operands`)
# and emits the opaque-pointer sentinel for unresolvable operands.
function _operand_safe(val::Union{LLVM.Value, Nothing},
                       names::Dict{_LLVMRef, Symbol})::IROperand
    val === nothing && return OPAQUE_PTR_SENTINEL
    return _operand(val, names)
end

# ---- Bennett-cc0.4 helpers: ConstantExpr operand folding ----
#
# `optimize=true` folds `isnothing()` checks on `Union{T,Nothing}` fields to
# `select i1 icmp eq (ptr @TypeA, ptr @TypeB), ..., ...` — the condition is a
# LLVM.ConstantExpr, which `_operand` otherwise doesn't recognise. MVP scope:
# `icmp eq/ne` on pointer operands that resolve (via cc0.3's `_resolve_aliasee`
# + trivial-cast peeling) to named globals or null. Fold to `iconst(0/1)`;
# consumer width is inferred at lowering time just like `ConstantInt` literals.
# Every other ConstantExpr shape fails loud with a cc0.4 breadcrumb.

# Map ConstantExpr opcode → human-readable name for error messages.
const _CONSTEXPR_OPCODE_NAMES = Dict(
    LLVM.API.LLVMICmp          => "icmp",
    LLVM.API.LLVMBitCast       => "bitcast",
    LLVM.API.LLVMAddrSpaceCast => "addrspacecast",
    LLVM.API.LLVMPtrToInt      => "ptrtoint",
    LLVM.API.LLVMIntToPtr      => "inttoptr",
    LLVM.API.LLVMGetElementPtr => "getelementptr",
    LLVM.API.LLVMSelect        => "select",
    LLVM.API.LLVMTrunc         => "trunc",
    LLVM.API.LLVMZExt          => "zext",
    LLVM.API.LLVMSExt          => "sext",
    LLVM.API.LLVMAdd           => "add",
    LLVM.API.LLVMSub           => "sub",
    LLVM.API.LLVMMul           => "mul",
    LLVM.API.LLVMAnd           => "and",
    LLVM.API.LLVMOr            => "or",
    LLVM.API.LLVMXor           => "xor",
    LLVM.API.LLVMShl           => "shl",
    LLVM.API.LLVMLShr          => "lshr",
    LLVM.API.LLVMAShr          => "ashr",
)

_constexpr_opcode_name(opc) =
    get(_CONSTEXPR_OPCODE_NAMES, opc, sprint(show, opc))

# Canonical pointer identity. Julia-JIT emits GlobalAliases whose aliasees
# are `inttoptr (i64 K to ptr)` — literal runtime addresses of type
# descriptors. So a ref-based equality check isn't enough: we must follow
# aliases, peel trivial address-preserving casts, and recognise
# inttoptr-of-const as a numeric address.
#
# Returns a canonical identity tag:
#   (:addr,  K::UInt64)    — absolute address from `inttoptr (i64 K to ptr)`
#   (:named, r::_LLVMRef)  — named global (Function / GlobalVariable / IFunc)
#   (:null,  UInt64(0))    — null pointer
#   nothing                — undecidable (caller fails loud)
function _ptr_identity(ref::_LLVMRef)::Union{Tuple{Symbol, UInt64}, Tuple{Symbol, _LLVMRef}, Nothing}
    ref == C_NULL && return nothing
    cur = ref
    for _ in 1:16
        kind = LLVM.API.LLVMGetValueKind(cur)
        if kind == LLVM.API.LLVMFunctionValueKind ||
           kind == LLVM.API.LLVMGlobalIFuncValueKind ||
           kind == LLVM.API.LLVMGlobalVariableValueKind
            return (:named, cur)
        elseif kind == LLVM.API.LLVMConstantPointerNullValueKind
            return (:null, UInt64(0))
        elseif kind == LLVM.API.LLVMGlobalAliasValueKind
            next = LLVM.API.LLVMAliasGetAliasee(cur)
            next == C_NULL && return nothing
            cur = next
            continue
        elseif kind == LLVM.API.LLVMConstantExprValueKind
            inner_opc = LLVM.API.LLVMGetConstOpcode(cur)
            if inner_opc == LLVM.API.LLVMBitCast ||
               inner_opc == LLVM.API.LLVMAddrSpaceCast
                Int(LLVM.API.LLVMGetNumOperands(cur)) == 1 || return nothing
                inner = LLVM.API.LLVMGetOperand(cur, 0)
                inner == C_NULL && return nothing
                cur = inner
                continue
            elseif inner_opc == LLVM.API.LLVMIntToPtr
                # `inttoptr (i64 K to ptr)` — Julia JIT's typetag aliasee.
                Int(LLVM.API.LLVMGetNumOperands(cur)) == 1 || return nothing
                inner = LLVM.API.LLVMGetOperand(cur, 0)
                inner == C_NULL && return nothing
                inner_val = try
                    LLVM.Value(inner)
                catch e
                    e isa InterruptException && rethrow()
                    return nothing
                end
                inner_val isa LLVM.ConstantInt || return nothing
                return (:addr, UInt64(_const_int_as_int(inner_val) % UInt64))
            else
                return nothing   # ptrtoint / gep / … not handled
            end
        else
            return nothing       # unexpected kind (Argument, Instruction, …)
        end
    end
    return nothing                # chase-depth exhausted
end

# Decide whether two pointer refs denote the same link-time address.
# Returns `nothing` if either identity is undecidable (caller fails loud).
function _ptr_addresses_equal(a::_LLVMRef, b::_LLVMRef)::Union{Bool, Nothing}
    ia = _ptr_identity(a)
    ib = _ptr_identity(b)
    (ia === nothing || ib === nothing) && return nothing
    return ia == ib
end

# Fold a ConstantExpr operand into an IROperand. MVP scope:
#   icmp eq/ne on pointer operands → iconst(0/1)
# Everything else fails loud with a cc0.4 breadcrumb.
function _fold_constexpr_operand(ce::LLVM.ConstantExpr,
                                 names::Dict{_LLVMRef, Symbol})::IROperand
    opc = LLVM.API.LLVMGetConstOpcode(ce.ref)

    if opc == LLVM.API.LLVMPtrToInt || opc == LLVM.API.LLVMIntToPtr
        error("ir_extract.jl: Bennett-cc0.4/cc0.6: ConstantExpr<" *
              "$(_constexpr_opcode_name(opc))> in operand position requires " *
              "ptrtoint/inttoptr handling (cc0.6 scope). Operand: $(string(ce)).")
    end

    if opc != LLVM.API.LLVMICmp
        error("ir_extract.jl: Bennett-cc0.4: unhandled ConstantExpr opcode " *
              "`$(_constexpr_opcode_name(opc))` in operand position. " *
              "Operand: $(string(ce)). File a new bead extending cc0.4 with " *
              "a minimal repro.")
    end

    pred = LLVM.API.LLVMGetICmpPredicate(ce.ref)
    pred in (LLVM.API.LLVMIntEQ, LLVM.API.LLVMIntNE) ||
        error("ir_extract.jl: Bennett-cc0.4: ConstantExpr<icmp $pred> with " *
              "ordering predicate is not foldable at extraction time (pointer " *
              "address ordering is allocator-dependent). Operand: $(string(ce)). " *
              "File a new bead extending cc0.4 if this arises in real code.")

    n = Int(LLVM.API.LLVMGetNumOperands(ce.ref))
    n == 2 ||
        error("ir_extract.jl: Bennett-cc0.4: ConstantExpr<icmp> with $n operands " *
              "(expected 2): $(string(ce))")

    a_raw = LLVM.API.LLVMGetOperand(ce.ref, 0)
    b_raw = LLVM.API.LLVMGetOperand(ce.ref, 1)

    eq = _ptr_addresses_equal(a_raw, b_raw)
    eq === nothing && error(
        "ir_extract.jl: Bennett-cc0.4: ConstantExpr<icmp eq/ne> cannot be " *
        "statically decided — one or both operands did not resolve to a " *
        "canonical pointer identity (named global, null, or `inttoptr " *
        "(i64 K to ptr)`). Operand: $(string(ce)). File a new bead extending " *
        "cc0.4 with a minimal repro.")

    result_true = (pred == LLVM.API.LLVMIntEQ) ? eq : !eq
    return iconst(result_true ? 1 : 0)
end

# ---- Bennett-cc0.7 helpers ----

# Safe vector-type probe. LLVM.value_type errors on unsupported value kinds
# (e.g. LLVMGlobalAlias, see cc0.3). Call-instruction callees hit this path,
# so the dispatcher uses the safe variant. An operand that isn't a plain
# LLVM value is definitely not a vector — treat the exception as "no".
function _safe_is_vector_type(val)::Bool
    try
        return LLVM.value_type(val) isa LLVM.VectorType
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

# Check whether any operand of `inst` is vector-typed. LLVM.jl raises from
# within `iterate(LLVM.operands(...))` when the operand's value kind is
# unsupported (e.g. LLVMGlobalAlias callees on call instructions — cc0.3).
# Fall back to an index-based scan using the raw C API on iteration failure.
function _any_vector_operand(inst::LLVM.Instruction)::Bool
    try
        return any(_safe_is_vector_type(o) for o in LLVM.operands(inst))
    catch e
        e isa InterruptException && rethrow()
        # Iteration failed partway through. Scan by raw index via the C API,
        # skipping operands that LLVM.jl cannot materialise.
        n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
        for i in 0:(n - 1)
            ref = LLVM.API.LLVMGetOperand(inst.ref, i)
            try
                if _safe_is_vector_type(LLVM.Value(ref))
                    return true
                end
            catch e2
                e2 isa InterruptException && rethrow()
                continue
            end
        end
        return false
    end
end

# Returns (n_lanes, elem_width) for <N x iM>; `nothing` for non-vectors.
# Errors on non-integer lanes or unsupported widths.
function _vector_shape(val)::Union{Nothing, Tuple{Int, Int}}
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType || return nothing
    et = LLVM.eltype(vt)
    et isa LLVM.IntegerType ||
        error("ir_extract.jl: vector with non-integer element type $et is not " *
              "supported; got vector type $vt (Bennett-cc0.7 MVP scope)")
    w = Int(LLVM.width(et))
    w ∈ (1, 8, 16, 32, 64) ||
        error("ir_extract.jl: vector element width $w is not supported; " *
              "expected 1/8/16/32/64. Got vector type $vt")
    return (Int(LLVM.length(vt)), w)
end

# Decode a value's N lanes into IROperands. Handles already-populated SSA
# vectors (via `lanes`), ConstantDataVector, ConstantAggregateZero, and
# UndefValue/PoisonValue (poison-sentinel lanes that crash if ever read).
function _resolve_vec_lanes(val::LLVM.Value,
                            lanes::Dict{_LLVMRef, Vector{IROperand}},
                            names::Dict{_LLVMRef, Symbol},
                            n_expected::Int)::Vector{IROperand}
    # Path A: previously-processed SSA vector → read from `lanes`.
    if haskey(lanes, val.ref)
        got = lanes[val.ref]
        length(got) == n_expected ||
            error("ir_extract.jl: vector lane-count mismatch on $(string(val)): " *
                  "expected $n_expected, got $(length(got))")
        return got
    end
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType ||
        error("ir_extract.jl: _resolve_vec_lanes on non-vector: " *
              "$(string(val)) :: $vt")
    got_n = Int(LLVM.length(vt))
    got_n == n_expected ||
        error("ir_extract.jl: vector lane-count mismatch: expected $n_expected, " *
              "got $got_n on $(string(val))")
    # Path B: ConstantDataVector.
    if val isa LLVM.ConstantDataVector
        out = Vector{IROperand}(undef, got_n)
        for i in 0:(got_n - 1)
            elt_ref = LLVM.API.LLVMGetElementAsConstant(val.ref, i)
            elt = LLVM.Value(elt_ref)
            elt isa LLVM.ConstantInt ||
                error("ir_extract.jl: vector constant element at lane $i is " *
                      "not ConstantInt: $(string(elt))")
            out[i + 1] = iconst(_const_int_as_int(elt))
        end
        return out
    end
    # Path C: zeroinitializer.
    if val isa LLVM.ConstantAggregateZero
        return [iconst(0) for _ in 1:got_n]
    end
    # Path D: poison / undef — sentinel lanes. Reading crashes fail-loud.
    if val isa LLVM.UndefValue || val isa LLVM.PoisonValue
        return [IROperand(:const, :__poison_lane__, 0) for _ in 1:got_n]
    end
    error("ir_extract.jl: cannot resolve vector lanes for $(string(val)) :: " *
          "$vt — not an SSA vector, ConstantDataVector, ConstantAggregateZero, " *
          "or poison/undef")
end

function _convert_vector_instruction(inst::LLVM.Instruction,
                                     names::Dict{_LLVMRef, Symbol},
                                     lanes::Dict{_LLVMRef, Vector{IROperand}},
                                     counter::Ref{Int})
    opc = LLVM.opcode(inst)
    dest = names[inst.ref]

    # insertelement — pure SSA plumbing, emit no IR.
    if opc == LLVM.API.LLVMInsertElement
        ops = LLVM.operands(inst)
        base_vec = ops[1]; elem = ops[2]; idx_val = ops[3]
        idx_val isa LLVM.ConstantInt ||
            _ir_error(inst, "insertelement with dynamic lane index not supported")
        idx = _const_int_as_int(idx_val)
        n = _vector_shape(inst)[1]
        (0 <= idx < n) ||
            _ir_error(inst, "insertelement lane index $idx outside [0,$n)")
        base_lanes = _resolve_vec_lanes(base_vec, lanes, names, n)
        new_lanes = copy(base_lanes)
        new_lanes[idx + 1] = _operand(elem, names)
        lanes[inst.ref] = new_lanes
        return nothing
    end

    # shufflevector — pure SSA plumbing.
    if opc == LLVM.API.LLVMShuffleVector
        ops = LLVM.operands(inst)
        v1 = ops[1]; v2 = ops[2]
        n_src = _vector_shape(v1)[1]
        n_result = Int(LLVM.API.LLVMGetNumMaskElements(inst.ref))
        v1_lanes = _resolve_vec_lanes(v1, lanes, names, n_src)
        v2_lanes = _resolve_vec_lanes(v2, lanes, names, n_src)
        out = Vector{IROperand}(undef, n_result)
        for i in 0:(n_result - 1)
            m = Int(LLVM.API.LLVMGetMaskValue(inst.ref, i))
            if m == -1                       # poison mask element
                out[i + 1] = IROperand(:const, :__poison_lane__, 0)
            elseif 0 <= m < n_src
                out[i + 1] = v1_lanes[m + 1]
            elseif n_src <= m < 2 * n_src
                out[i + 1] = v2_lanes[m - n_src + 1]
            else
                _ir_error(inst, "shufflevector mask element $m out of range [0, $(2*n_src))")
            end
        end
        lanes[inst.ref] = out
        return nothing
    end

    # extractelement — rename via add-zero (see consensus §Choice 4).
    if opc == LLVM.API.LLVMExtractElement
        ops = LLVM.operands(inst)
        vec = ops[1]; idx_val = ops[2]
        n = _vector_shape(vec)[1]
        vec_lanes = _resolve_vec_lanes(vec, lanes, names, n)
        idx_val isa LLVM.ConstantInt ||
            _ir_error(inst, "extractelement with dynamic lane index not supported")
        idx = _const_int_as_int(idx_val)
        (0 <= idx < n) ||
            _ir_error(inst, "extractelement lane index $idx outside [0,$n)")
        lane_op = vec_lanes[idx + 1]
        (lane_op.kind == :const && lane_op.name === :__poison_lane__) &&
            _ir_error(inst, "extractelement reads poison lane — undefined behaviour")
        w = Int(LLVM.width(LLVM.value_type(inst)))
        return IRBinOp(dest, :add, lane_op, iconst(0), w)
    end

    # Vector arithmetic / bitwise / shift — N scalar IRBinOps.
    if opc in (LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul,
               LLVM.API.LLVMAnd, LLVM.API.LLVMOr,  LLVM.API.LLVMXor,
               LLVM.API.LLVMShl, LLVM.API.LLVMLShr, LLVM.API.LLVMAShr)
        ops = LLVM.operands(inst)
        (n, w) = _vector_shape(inst)
        a_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        b_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
        sym = _opcode_to_sym(opc)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            lane_dest = _auto_name(counter)
            push!(insts, IRBinOp(lane_dest, sym, a_lanes[i], b_lanes[i], w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector icmp — N scalar IRICmps producing <N x i1>.
    if opc == LLVM.API.LLVMICmp
        ops = LLVM.operands(inst)
        (n, _) = _vector_shape(inst)
        (_, op_w) = _vector_shape(ops[1])
        pred = _pred_to_sym(LLVM.predicate(inst))
        a_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        b_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            lane_dest = _auto_name(counter)
            push!(insts, IRICmp(lane_dest, pred, a_lanes[i], b_lanes[i], op_w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector select — N scalar IRSelects. Condition may be scalar i1 (broadcast)
    # or <N x i1> (per-lane).
    if opc == LLVM.API.LLVMSelect
        ops = LLVM.operands(inst)
        (n, w) = _vector_shape(inst)
        cond = ops[1]
        cond_is_vec = LLVM.value_type(cond) isa LLVM.VectorType
        cond_lanes = cond_is_vec ? _resolve_vec_lanes(cond, lanes, names, n) : nothing
        t_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
        f_lanes = _resolve_vec_lanes(ops[3], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            c_op = cond_is_vec ? cond_lanes[i] : _operand(cond, names)
            lane_dest = _auto_name(counter)
            push!(insts, IRSelect(lane_dest, c_op, t_lanes[i], f_lanes[i], w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector casts — N scalar IRCasts.
    if opc in (LLVM.API.LLVMSExt, LLVM.API.LLVMZExt, LLVM.API.LLVMTrunc)
        opname = opc == LLVM.API.LLVMSExt ? :sext :
                 opc == LLVM.API.LLVMZExt ? :zext : :trunc
        ops = LLVM.operands(inst)
        (n, w_to) = _vector_shape(inst)
        (n_src, w_from) = _vector_shape(ops[1])
        n_src == n || _ir_error(inst, "vector cast lane-count mismatch: $n_src vs $n")
        src_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            lane_dest = _auto_name(counter)
            push!(insts, IRCast(lane_dest, opname, src_lanes[i], w_from, w_to))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector bitcast — two supported shapes:
    #   (a) vector → same-shape vector: identity alias.
    #   (b) <N x i1> → scalar iN: bit-position pack (lane i → bit i). Common
    #       after a vector icmp that LLVM wants to reduce to a single mask byte.
    if opc == LLVM.API.LLVMBitCast
        src = LLVM.operands(inst)[1]
        src_shape = _vector_shape(src)
        dst_shape = _vector_shape(inst)
        if src_shape !== nothing && dst_shape !== nothing
            (n, w_to) = dst_shape
            (n_src, w_from) = src_shape
            (n_src == n && w_from == w_to) ||
                _ir_error(inst,
                    "vector bitcast with lane/width shape change not supported: " *
                    "<$n_src x i$w_from> → <$n x i$w_to>")
            src_lanes = _resolve_vec_lanes(src, lanes, names, n)
            lanes[inst.ref] = copy(src_lanes)
            return nothing
        end
        if src_shape !== nothing && dst_shape === nothing
            # vector → scalar: must be <N x i1> → iN (bit-pack).
            (n_src, w_from) = src_shape
            dst_vt = LLVM.value_type(inst)
            dst_vt isa LLVM.IntegerType ||
                _ir_error(inst, "vector→scalar bitcast to non-integer type $dst_vt")
            w_to = Int(LLVM.width(dst_vt))
            (w_from == 1 && w_to == n_src) ||
                _ir_error(inst,
                    "vector→scalar bitcast only supported for <N x i1> → iN " *
                    "(got <$n_src x i$w_from> → i$w_to)")
            src_lanes = _resolve_vec_lanes(src, lanes, names, n_src)
            # Build: result = OR_k (zext(lane_k, n_src) << k)
            insts = IRInst[]
            shifted = IROperand[]
            for k in 0:(n_src - 1)
                lane = src_lanes[k + 1]
                (lane.kind == :const && lane.name === :__poison_lane__) &&
                    _ir_error(inst, "vector→scalar bitcast reads poison lane at index $k")
                zext_dest = _auto_name(counter)
                push!(insts, IRCast(zext_dest, :zext, lane, 1, n_src))
                if k == 0
                    push!(shifted, ssa(zext_dest))
                else
                    shl_dest = _auto_name(counter)
                    push!(insts, IRBinOp(shl_dest, :shl, ssa(zext_dest), iconst(k), n_src))
                    push!(shifted, ssa(shl_dest))
                end
            end
            acc = shifted[1]
            for i in 2:length(shifted)
                or_dest = (i == length(shifted)) ? dest : _auto_name(counter)
                push!(insts, IRBinOp(or_dest, :or, acc, shifted[i], n_src))
                acc = ssa(or_dest)
            end
            if length(shifted) == 1
                # Single-lane corner: copy via add-0.
                push!(insts, IRBinOp(dest, :add, shifted[1], iconst(0), n_src))
            end
            return insts
        end
        _ir_error(inst, "unsupported bitcast shape for cc0.7")
    end

    # Bennett-0c8o: vector load — decompose `%v = load <N x iW>, ptr %p` into
    # N scalar `IRPtrOffset` + `IRLoad` pairs at lane byte offsets, and record
    # per-lane IROperands in `lanes[inst.ref]`. Uses only primitives already
    # handled by lower.jl.
    if opc == LLVM.API.LLVMLoad
        shape = _vector_shape(inst)
        shape === nothing &&
            _ir_error(inst, "vector load return type is not a vector")
        n, w = shape
        ptr = LLVM.operands(inst)[1]
        eb = w ÷ 8
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            gep_dest = _auto_name(counter)
            load_dest = _auto_name(counter)
            push!(insts, IRPtrOffset(gep_dest, _operand(ptr, names), (i - 1) * eb))
            push!(insts, IRLoad(load_dest, ssa(gep_dest), w))
            out[i] = ssa(load_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    _ir_error(inst, "unsupported vector opcode $opc")
end

# ---- helpers ----

"""Get the dereferenceable byte count from a pointer parameter, or 0 if no
`dereferenceable(N)` attribute is present on the parameter's slot.

Bennett-8b2f / U17: the IR-string fallback previously did
`match(r"dereferenceable\\((\\d+)\\)", defline)` — function-wide,
returning the FIRST N on the `define` line regardless of which
parameter was being queried. On multi-ptr functions where the params
had different dereferenceable counts (or where some had none), every
call returned the same first-found value → phantom input-wire widths
for non-matching params. Fix: anchor the fallback regex to the specific
`%paramname`, matching `dereferenceable\\((\\d+)\\)[^,)]*%NAME\\b` which
walks within a single param slot (bounded by `,` / `)`).

Bennett-zyjn / U94: previously returned 0 for THREE distinct outcomes
— (a) param not in func, (b) defline malformed, (c) param has no
`dereferenceable(N)` attribute — collapsing two caller-side / format-
mismatch BUGS into the same silent value as the legitimate "no attr"
case. Now (a) and (b) `error()` with attribution; only (c) returns 0.
"""
function _get_deref_bytes(func::LLVM.Function, param::LLVM.Argument)
    # Bennett-zyjn / U94: this function used to return 0 for THREE
    # distinct outcomes — (a) param not in func, (b) defline missing
    # `(...)` parameter list, (c) param found but has no
    # `dereferenceable(N)` attribute on its slot. Bugs (a) and (b) now
    # error() with attribution; only (c) — the legitimate "no attr"
    # case — returns 0. Caller's `deref > 0` check is unchanged.

    # Find the parameter index (1-based)
    idx = 0
    for p in LLVM.parameters(func)
        idx += 1
        p.ref == param.ref && @goto found_param
    end
    error("_get_deref_bytes: parameter $(LLVM.name(param)) is not in " *
          "func=@$(LLVM.name(func)) parameter list (caller-side miswiring; " *
          "Bennett-zyjn / U94)")
    @label found_param
    # Check parameter attributes for dereferenceable(N)
    try
        for attr in LLVM.parameter_attributes(func, idx)
            s = string(attr)
            m = match(r"dereferenceable\((\d+)\)", s)
            if m !== nothing
                return parse(Int, m.captures[1])
            end
        end
    catch e
        e isa InterruptException && rethrow()
        e isa MethodError || rethrow()
    end
    # Fallback: walk the param slot list on the `define` line and read
    # `dereferenceable(N)` only from the slot whose `%NAME` matches.
    # Regex is fragile here because Julia mangled names arrive as
    # `%"t::Tuple"` with quotes — a simple `%NAME\b` won't match.
    # Slice by parameter, then look for both `%NAME` and `%"NAME"`.
    ir_str = string(func)
    defline = split(ir_str, "\n")[1]
    pname = LLVM.name(param)
    # Extract the (...) parameter list. A missing or out-of-order pair is
    # an LLVM.jl format mismatch — fail loud rather than silently returning 0.
    lp = findfirst('(', defline)
    rp = findlast(')', defline)
    (lp === nothing || rp === nothing || lp >= rp) && error(
        "_get_deref_bytes: malformed `define` line for func=@$(LLVM.name(func)); " *
        "could not locate the parameter list `(...)`. " *
        "LLVM.jl `string(func)` may have changed format. (Bennett-zyjn / U94)\n  " *
        "defline: $defline")
    param_list = defline[lp+1:rp-1]
    # Split on top-level commas. Paren nesting within a slot (e.g.
    # `sret([2 x i64])`, `dereferenceable(16)`) must not split the slot.
    slots = String[]
    depth = 0
    slot_start = 1
    for (i, c) in pairs(param_list)
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
        elseif c == ',' && depth == 0
            push!(slots, param_list[slot_start:prevind(param_list, i)])
            slot_start = nextind(param_list, i)
        end
    end
    push!(slots, param_list[slot_start:end])
    # Find the slot containing our %NAME (quoted or bare).
    needle_q = "%\"" * pname * "\""
    needle_b = "%" * pname
    for slot in slots
        has_q = occursin(needle_q, slot)
        has_b = !has_q && (occursin(" " * needle_b, slot) ||
                           startswith(strip(slot), needle_b))
        if has_q || has_b
            m = match(r"dereferenceable\((\d+)\)", slot)
            return m === nothing ? 0 : parse(Int, m.captures[1])
        end
    end
    return 0
end

"""
    _const_int_as_int(v::LLVM.ConstantInt) -> Int

Bennett-l9cl / U09: LLVM.jl's `convert(Int, ::ConstantInt)` uses the C API
`LLVMConstIntGetSExtValue`, which returns only the low 64 bits; any wider
constant is silently truncated (`i128 2^127` → 0). IROperand.value is Int64,
so there is no safe place for a >64-bit constant to go. Fail loud until
IROperand widens to Int128/BigInt (tracked in U09 bead).
"""
@inline function _const_int_as_int(v::LLVM.ConstantInt)
    w = LLVM.width(LLVM.value_type(v))
    w > 64 && error(
        "ir_extract.jl: ConstantInt with width $w bits encountered (>64); " *
        "LLVM.jl `convert(Int, ::ConstantInt)` silently truncates to the low " *
        "64 bits and IROperand.value is Int64 — widen IROperand to " *
        "Int128/BigInt before enabling i128+ constants (Bennett-l9cl / U09)." *
        "\n  Source constant: $(string(v))")
    return convert(Int, v)
end

function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(_const_int_as_int(val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)  # special: zero aggregate
    elseif val isa LLVM.ConstantExpr
        # Bennett-cc0.4: fold statically-decidable ConstantExprs (today:
        # pointer-typed icmp eq/ne between named globals) to i1 literals.
        return _fold_constexpr_operand(val, names)
    elseif val isa LLVM.ConstantFP
        # Bennett-bjdg / U80: floating-point constant in operand position.
        # Bennett.jl extracts integer values and routes Float64 arithmetic
        # through the SoftFloat dispatcher (src/Bennett.jl:380+); raw
        # ConstantFP operands have no canonical integer encoding here.
        # Pre-bjdg this fell through to the misleading "unknown operand
        # ref ... producing instruction was skipped" error.
        error("ir_extract.jl: ConstantFP operand not supported: " *
              "$(string(val)) — Bennett.jl does not lower raw " *
              "floating-point constants. Wrap in `SoftFloat(...)` at the " *
              "call site, or change the function to take/return integer " *
              "types. See src/Bennett.jl:380+ for the SoftFloat dispatch " *
              "path. (Bennett-bjdg / U80)")
    elseif val isa LLVM.PoisonValue
        # Bennett-bjdg / U80: poison operand. Per LLVM LangRef poison is
        # undefined behavior on observation; reading it is never legal.
        error("ir_extract.jl: PoisonValue operand: $(string(val)) — " *
              "reading poison is undefined behavior per LLVM LangRef. " *
              "This usually means a prior instruction produced poison " *
              "(integer overflow flagged with `nsw`/`nuw`, divide by " *
              "zero, etc.) and the result is being consumed without a " *
              "guard. Bennett.jl rejects poison operands to fail fast. " *
              "(Bennett-bjdg / U80)")
    elseif val isa LLVM.UndefValue
        # Bennett-bjdg / U80: undef operand (UndefValue, not the
        # PoisonValue subclass — the latter caught above). Implementation-
        # defined per LLVM LangRef; Bennett.jl rejects to fail fast per
        # CLAUDE.md §1.
        error("ir_extract.jl: UndefValue operand: $(string(val)) — " *
              "reading undef is implementation-defined per LLVM LangRef. " *
              "Bennett.jl rejects undef operands to fail fast " *
              "(CLAUDE.md §1). (Bennett-bjdg / U80)")
    else
        # Bennett-bjdg / U80: precise check for ConstantPointerNull
        # (LLVM.jl doesn't expose a Julia-level type for it, so use the
        # value-kind C API). Anything else still in this branch is a
        # genuinely-unknown SSA ref — the original error message applies.
        r = val.ref
        if r != C_NULL
            kind = LLVM.API.LLVMGetValueKind(r)
            if kind == LLVM.API.LLVMConstantPointerNullValueKind
                error("ir_extract.jl: ConstantPointerNull operand: " *
                      "$(string(val)) — null-pointer dereference. " *
                      "Bennett.jl does not currently lower null-pointer " *
                      "operands. (Bennett-bjdg / U80)")
            end
        end
        haskey(names, r) || error(
            "ir_extract.jl: unknown operand ref for: $(string(val)) — the " *
            "producing instruction was skipped or is not yet supported; " *
            "check the cc0.x gaps in the extractor")
        return ssa(names[r])
    end
end

function _iwidth(val)
    tp = LLVM.value_type(val)
    _type_width(tp)
end

function _type_width(tp)
    if tp isa LLVM.IntegerType
        return LLVM.width(tp)
    elseif tp isa LLVM.ArrayType
        return LLVM.length(tp) * _type_width(LLVM.eltype(tp))
    elseif tp isa LLVM.FloatingPointType
        # IEEE 754: half=16, float=32, double=64
        tp isa LLVM.LLVMDouble && return 64
        tp isa LLVM.LLVMFloat  && return 32
        tp isa LLVM.LLVMHalf   && return 16
        error("ir_extract.jl: unsupported float type for width query: $tp")
    elseif tp isa LLVM.VectorType
        # Bennett-qmk6 / U82: precise error for vector-typed values reaching
        # the scalar width-query path. Vector lanes have their own dedicated
        # extractors (`_vector_shape`, `_resolve_vec_lanes`) used by the
        # cc0.7 vector-handling code; if a value is asking for a scalar
        # width when its type is a vector, the caller is on the wrong path.
        error("ir_extract.jl: VectorType $(tp) reached scalar _type_width — " *
              "vectors are extracted via `_vector_shape` / `_resolve_vec_lanes` " *
              "(Bennett-cc0.7 MVP). If you got here from a vector return type, " *
              "Bennett.jl does not yet support vector-valued returns. " *
              "(Bennett-qmk6 / U82)")
    elseif tp isa LLVM.StructType
        # Bennett-qmk6 / U82 (related): struct-typed values can't be encoded
        # as a single width. They're handled either via sret (the caller
        # passes a pointer to the struct as an extra argument) or via
        # `extractvalue` / `insertvalue` after extraction. A bare struct
        # arriving at scalar _type_width means the surrounding dispatch
        # missed the aggregate case.
        error("ir_extract.jl: StructType $(tp) reached scalar _type_width — " *
              "structs are aggregate values; pass via sret or unpack with " *
              "extractvalue. (Bennett-qmk6 / U82)")
    elseif tp isa LLVM.VoidType
        # Bennett-dq8l / U81: void return type reaching _type_width means a
        # void-returning instruction is being treated as a value-producing
        # instruction. Likely a void call or store handler missed its
        # branch. Pre-fix this fell through to the generic message.
        error("ir_extract.jl: VoidType reached _type_width — caller is " *
              "querying the width of a void value (likely a void-returning " *
              "call or a store/branch instruction). Void instructions don't " *
              "produce SSA values; the surrounding dispatch should special-case " *
              "them upstream. (Bennett-dq8l / U81)")
    else
        error("ir_extract.jl: unsupported LLVM type for width query: $tp")
    end
end

const _OPCODE_MAP = Dict(
    LLVM.API.LLVMAdd  => :add,  LLVM.API.LLVMSub  => :sub,
    LLVM.API.LLVMMul  => :mul,  LLVM.API.LLVMAnd  => :and,
    LLVM.API.LLVMOr   => :or,   LLVM.API.LLVMXor  => :xor,
    LLVM.API.LLVMShl  => :shl,  LLVM.API.LLVMLShr => :lshr,
    LLVM.API.LLVMAShr => :ashr,
)
_opcode_to_sym(opc) = _OPCODE_MAP[opc]

const _PRED_MAP = Dict(
    LLVM.API.LLVMIntEQ  => :eq,  LLVM.API.LLVMIntNE  => :ne,
    LLVM.API.LLVMIntULT => :ult, LLVM.API.LLVMIntUGT => :ugt,
    LLVM.API.LLVMIntULE => :ule, LLVM.API.LLVMIntUGE => :uge,
    LLVM.API.LLVMIntSLT => :slt, LLVM.API.LLVMIntSGT => :sgt,
    LLVM.API.LLVMIntSLE => :sle, LLVM.API.LLVMIntSGE => :sge,
)
_pred_to_sym(pred) = _PRED_MAP[pred]
