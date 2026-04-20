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

"""Register a Julia function for gate-level inlining when encountered as an LLVM call."""
function register_callee!(f::Function)
    # Get the LLVM name Julia would give this function (j_name_NNN pattern)
    # We match by substring, so just store the Julia function name
    _known_callees[string(nameof(f))] = f
end

function _lookup_callee(llvm_name::String)
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

# ---- value identity via C pointer ----

const _LLVMRef = LLVM.API.LLVMValueRef

# Auto-name counter (passed as argument, not global state)
function _auto_name(counter::Ref{Int})
    counter[] += 1
    Symbol("__v$(counter[])")
end

# No-op for backward compatibility (counter is now local to each compilation)
function _reset_names!() end

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
        if found !== nothing
            error("function has multiple sret parameters (LangRef forbids this); " *
                  "found at parameter indices $(found.param_index) and $i")
        end
        ty = LLVM.LLVMType(LLVM.API.LLVMGetTypeAttributeValue(attr))
        ty isa LLVM.ArrayType || error(
            "sret pointee is $ty; only [N x iM] aggregates are supported " *
            "(heterogeneous struct returns like Tuple{UInt32,UInt64} are not yet " *
            "supported — see Bennett-dv1z MVP scope)")
        et = LLVM.eltype(ty)
        et isa LLVM.IntegerType || error(
            "sret aggregate element type $et is not an integer; " *
            "float/pointer sret aggregates are not supported")
        w = LLVM.width(et)
        w ∈ (8, 16, 32, 64) || error(
            "sret element width $w is not in {8,16,32,64}; got aggregate $ty")
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
    slot_values = Dict{Int, IROperand}()
    suppressed  = Set{_LLVMRef}()
    gep_byte    = Dict{_LLVMRef, Int}()   # sret-derived GEP result → byte offset

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
                    cname = try LLVM.name(ops[n_ops]) catch; "" end
                    if startswith(cname, "llvm.memcpy")
                        if n_ops >= 2 && ops[1].ref === sret_ref
                            error("sret with llvm.memcpy form is not supported. " *
                                  "This pattern is emitted under optimize=false. " *
                                  "Re-compile with optimize=true (the Bennett.jl " *
                                  "default) or set preprocess=true to canonicalise " *
                                  "via SROA/mem2reg.")
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
                        length(ops) == 2 || error(
                            "sret-derived GEP has $(length(ops)-1) indices; only " *
                            "single-index constant-offset GEPs from sret are supported")
                        idx = ops[2]
                        idx isa LLVM.ConstantInt || error(
                            "sret pointer is indexed dynamically; only constant-offset " *
                            "GEPs from sret are supported")
                        src_ty = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(inst))
                        add_bytes = if src_ty isa LLVM.IntegerType && LLVM.width(src_ty) == 8
                            convert(Int, idx)              # byte-indexed GEP (Julia default)
                        elseif src_ty === sret_info.agg_type
                            convert(Int, idx) * eb          # typed GEP on [N x iM]
                        else
                            error("sret GEP source element type $src_ty; expected i8 " *
                                  "(byte-indexed) or $(sret_info.agg_type) (typed element)")
                        end
                        new_off = base_off + add_bytes
                        (0 <= new_off < agg_bytes) || error(
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
                    vt isa LLVM.IntegerType || error(
                        "sret store at byte offset $byte_off has non-integer value " *
                        "type $vt; only integer stores are supported")
                    sw = LLVM.width(vt)
                    sw == ew || error(
                        "sret store at byte offset $byte_off has value width $sw, " *
                        "but aggregate element width is $ew (partial-element writes " *
                        "are not supported)")
                    (byte_off % eb == 0) || error(
                        "sret store at byte offset $byte_off is not aligned to " *
                        "element size $eb (partial-element writes are not supported)")
                    slot = byte_off ÷ eb
                    (0 <= slot < n) || error(
                        "sret store slot $slot is out of range [0, $n)")
                    haskey(slot_values, slot) && error(
                        "sret slot $slot has multiple stores; only a single store " *
                        "per slot is supported in MVP (multi-store / conditional " *
                        "sret coverage is a planned extension)")
                    slot_values[slot] = _operand(val, names)
                    push!(suppressed, inst.ref)
                    continue
                end
            end
        end
    end

    # Every slot must be written before ret void
    for k in 0:(n - 1)
        haskey(slot_values, k) || error(
            "sret slot $k is never written; every element of the aggregate return " *
            "must be stored before ret void")
    end

    return (slot_values = slot_values, suppressed = suppressed)
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
    func === nothing && error("No julia_ function found in LLVM module")

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
                chain, ret_inst = _synthesize_sret_chain(
                    sret_info, sret_writes.slot_values, counter)
                append!(insts, chain)
                terminator = ret_inst
                continue
            end

            ir_inst = _convert_instruction(inst, names, counter, lanes)
            ir_inst === nothing && continue
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

        terminator === nothing && error("Block $label has no terminator")
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
        catch
            nothing
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

    _sw_0: icmp eq val, c1 → br (L1, _sw_1)
    _sw_1: icmp eq val, c2 → br (L2, _sw_2)
    ...
    _sw_N: unconditional br → default

Phi nodes in target blocks are updated to reference the new synthetic blocks
instead of the original switch block.
"""
function _expand_switches(blocks::Vector{IRBasicBlock})
    result = IRBasicBlock[]
    for block in blocks
        if !(block.terminator isa IRSwitch)
            push!(result, block)
            continue
        end

        sw = block.terminator
        orig_label = block.label
        n_cases = length(sw.cases)

        if n_cases == 0
            # Degenerate: just unconditional branch to default
            push!(result, IRBasicBlock(orig_label, block.instructions,
                                       IRBranch(nothing, sw.default_label, nothing)))
            continue
        end

        # Generate synthetic block labels
        syn_labels = [Symbol("_sw_$(orig_label)_$i") for i in 1:n_cases]

        # First block: original block with first comparison
        cmp_dest_1 = Symbol("_sw_cmp_$(orig_label)_1")
        first_cmp = IRICmp(cmp_dest_1, :eq, sw.cond, sw.cases[1][1], sw.cond_width)
        first_br = IRBranch(ssa(cmp_dest_1), sw.cases[1][2],
                            n_cases >= 2 ? syn_labels[2] : sw.default_label)
        push!(result, IRBasicBlock(orig_label,
                                   vcat(block.instructions, [first_cmp]),
                                   first_br))

        # Middle comparison blocks (cases 2..N-1)
        for i in 2:(n_cases - 1)
            cmp_dest = Symbol("_sw_cmp_$(orig_label)_$i")
            cmp = IRICmp(cmp_dest, :eq, sw.cond, sw.cases[i][1], sw.cond_width)
            br = IRBranch(ssa(cmp_dest), sw.cases[i][2], syn_labels[i + 1])
            push!(result, IRBasicBlock(syn_labels[i], [cmp], br))
        end

        # Last comparison block (case N)
        if n_cases >= 2
            cmp_dest_n = Symbol("_sw_cmp_$(orig_label)_$n_cases")
            cmp_n = IRICmp(cmp_dest_n, :eq, sw.cond, sw.cases[n_cases][1], sw.cond_width)
            br_n = IRBranch(ssa(cmp_dest_n), sw.cases[n_cases][2], sw.default_label)
            push!(result, IRBasicBlock(syn_labels[n_cases], [cmp_n], br_n))
        end

        # Update phi nodes: replace references to orig_label with the
        # correct synthetic block that actually branches to the target.
        # For case i → target Li, the branch comes from:
        #   case 1: orig_label, case 2..N: syn_labels[i], default: syn_labels[N]
        phi_remap = Dict{Symbol, Symbol}()  # target_label => source block
        phi_remap[sw.cases[1][2]] = orig_label
        for i in 2:n_cases
            phi_remap[sw.cases[i][2]] = syn_labels[i]
        end
        phi_remap[sw.default_label] = n_cases >= 2 ? syn_labels[n_cases] : orig_label

        # Patch phi nodes in all blocks that reference orig_label
        for j in eachindex(result)
            blk = result[j]
            new_insts = IRInst[]
            changed = false
            for inst in blk.instructions
                if inst isa IRPhi
                    new_incoming = Tuple{IROperand, Symbol}[]
                    for (val, from_block) in inst.incoming
                        if from_block == orig_label
                            # Find which synthetic block branches to this phi's block
                            actual_from = get(phi_remap, blk.label, from_block)
                            push!(new_incoming, (val, actual_from))
                            changed = true
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

    # extractvalue — select one element from an aggregate
    if opc == LLVM.API.LLVMExtractValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        idx_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = unsafe_load(idx_ptr)  # 0-based
        agg_type = LLVM.value_type(agg_val)
        ew = LLVM.width(LLVM.eltype(agg_type))
        ne = LLVM.length(agg_type)
        return IRExtractValue(dest, _operand(agg_val, names), idx, ew, ne)
    end

    # insertvalue
    if opc == LLVM.API.LLVMInsertValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        elem_val = ops[2]
        idxs_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = Int(unsafe_wrap(Array, idxs_ptr, 1)[1])
        agg_type = LLVM.value_type(inst)
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
            cname = try LLVM.name(ops[n_ops]) catch; "" end
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
        return nothing
    end

    # GEP with constant or variable offset
    if opc == LLVM.API.LLVMGetElementPtr
        ops = LLVM.operands(inst)
        base = ops[1]
        # Case A: base is a local SSA value that we've already named
        if haskey(names, base.ref) && length(ops) == 2
            if ops[2] isa LLVM.ConstantInt
                # Constant-index GEP → IRPtrOffset (wire selection from flat array)
                offset = convert(Int, ops[2])
                return IRPtrOffset(dest, ssa(names[base.ref]), offset)
            else
                # Variable-index GEP → IRVarGEP (MUX-tree selection at lowering time)
                idx_op = _operand(ops[2], names)
                src_ty_ref = LLVM.API.LLVMGetGEPSourceElementType(inst)
                src_type = LLVM.LLVMType(src_ty_ref)
                ew = src_type isa LLVM.IntegerType ? LLVM.width(src_type) : 8
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
            ew = src_type isa LLVM.IntegerType ? LLVM.width(src_type) : 8
            if ops[2] isa LLVM.ConstantInt
                # Compile-time index into a constant table — still synthesizable
                # as IRVarGEP with a constant-kind index.
                offset = convert(Int, ops[2])
                return IRVarGEP(dest, ssa(gname), iconst(offset), ew)
            else
                idx_op = _operand(ops[2], names)
                return IRVarGEP(dest, ssa(gname), idx_op, ew)
            end
        end
        return nothing  # GEP with unknown base — skip
    end

    # Load from pointer → IRLoad (CNOT-copy from wire subset)
    if opc == LLVM.API.LLVMLoad
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
            case_int = convert(Int, case_val)
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

    # fptosi/fptoui: float → int conversion via soft_fptosi (actual IEEE 754 decode)
    if opc in (LLVM.API.LLVMFPToSI, LLVM.API.LLVMFPToUI)
        src = LLVM.operands(inst)[1]
        src_w = _iwidth(src)
        dst_w = _iwidth(inst)
        callee = _lookup_callee("soft_fptosi")
        if callee !== nothing && src_w == 64
            # Route through soft_fptosi for Float64→Int64 conversion
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
        else
            error("Unsupported fcmp predicate: $pred_int in $(string(inst))")
        end
        callee === nothing && error("soft_fcmp callee not registered for fcmp predicate $pred_int")
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
        src_w == dst_w || error("bitcast width mismatch: $src_w → $dst_w")
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
    # Skip when the stored value isn't an integer type (matches IRLoad policy).
    if opc == LLVM.API.LLVMStore
        ops = LLVM.operands(inst)
        val = ops[1]
        ptr = ops[2]
        vt = LLVM.value_type(val)
        vt isa LLVM.IntegerType || return nothing
        haskey(names, ptr.ref) || return nothing
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
            iconst(convert(Int, ops[1]))
        elseif !isempty(ops) && haskey(names, ops[1].ref)
            ssa(names[ops[1].ref])
        else
            iconst(1)  # scalar alloca with no explicit count
        end
        return IRAlloca(dest, elem_w, n_elems_op)
    end

    error("Unsupported LLVM opcode: $opc in instruction: $(string(inst))")
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

# Safe vector-type probe. LLVM.value_type errors on unsupported value kinds
# (e.g. LLVMGlobalAlias, see cc0.3). Call-instruction callees hit this path,
# so the dispatcher uses the safe variant. An operand that isn't a plain
# LLVM value is definitely not a vector — treat the exception as "no".
function _safe_is_vector_type(val)::Bool
    try
        return LLVM.value_type(val) isa LLVM.VectorType
    catch
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
    catch
        # Iteration failed partway through. Scan by raw index via the C API,
        # skipping operands that LLVM.jl cannot materialise.
        n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
        for i in 0:(n - 1)
            ref = LLVM.API.LLVMGetOperand(inst.ref, i)
            try
                if _safe_is_vector_type(LLVM.Value(ref))
                    return true
                end
            catch
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
        error("vector with non-integer element type $et is not supported; " *
              "got vector type $vt (Bennett-cc0.7 MVP scope)")
    w = Int(LLVM.width(et))
    w ∈ (1, 8, 16, 32, 64) ||
        error("vector element width $w is not supported; expected 1/8/16/32/64. " *
              "Got vector type $vt")
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
            error("vector lane-count mismatch on $(string(val)): expected " *
                  "$n_expected, got $(length(got))")
        return got
    end
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType ||
        error("_resolve_vec_lanes on non-vector: $(string(val)) :: $vt")
    got_n = Int(LLVM.length(vt))
    got_n == n_expected ||
        error("vector lane-count mismatch: expected $n_expected, got $got_n on $(string(val))")
    # Path B: ConstantDataVector.
    if val isa LLVM.ConstantDataVector
        out = Vector{IROperand}(undef, got_n)
        for i in 0:(got_n - 1)
            elt_ref = LLVM.API.LLVMGetElementAsConstant(val.ref, i)
            elt = LLVM.Value(elt_ref)
            elt isa LLVM.ConstantInt ||
                error("vector constant element at lane $i is not ConstantInt: $(string(elt))")
            out[i + 1] = iconst(convert(Int, elt))
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
    error("cannot resolve vector lanes for $(string(val)) :: $vt — not an " *
          "SSA vector, ConstantDataVector, ConstantAggregateZero, or poison/undef")
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
            error("insertelement with dynamic lane index not supported: $(string(inst))")
        idx = convert(Int, idx_val)
        n = _vector_shape(inst)[1]
        (0 <= idx < n) ||
            error("insertelement lane index $idx outside [0,$n): $(string(inst))")
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
                error("shufflevector mask element $m out of range [0, $(2*n_src))")
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
            error("extractelement with dynamic lane index not supported: $(string(inst))")
        idx = convert(Int, idx_val)
        (0 <= idx < n) ||
            error("extractelement lane index $idx outside [0,$n)")
        lane_op = vec_lanes[idx + 1]
        (lane_op.kind == :const && lane_op.name === :__poison_lane__) &&
            error("extractelement reads poison lane — undefined behaviour")
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
        n_src == n || error("vector cast lane-count mismatch: $n_src vs $n")
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
                error("vector bitcast with lane/width shape change not supported: " *
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
                error("vector→scalar bitcast to non-integer type $dst_vt: $(string(inst))")
            w_to = Int(LLVM.width(dst_vt))
            (w_from == 1 && w_to == n_src) ||
                error("vector→scalar bitcast only supported for <N x i1> → iN " *
                      "(got <$n_src x i$w_from> → i$w_to): $(string(inst))")
            src_lanes = _resolve_vec_lanes(src, lanes, names, n_src)
            # Build: result = OR_k (zext(lane_k, n_src) << k)
            insts = IRInst[]
            shifted = IROperand[]
            for k in 0:(n_src - 1)
                lane = src_lanes[k + 1]
                (lane.kind == :const && lane.name === :__poison_lane__) &&
                    error("vector→scalar bitcast reads poison lane at index $k")
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
        error("unsupported bitcast shape for cc0.7: $(string(inst))")
    end

    error("Unsupported vector opcode $opc in instruction: $(string(inst))")
end

# ---- helpers ----

"""Get the dereferenceable byte count from a pointer parameter, or 0 if unknown."""
function _get_deref_bytes(func::LLVM.Function, param::LLVM.Argument)
    # Find the parameter index (1-based)
    idx = 0
    for p in LLVM.parameters(func)
        idx += 1
        p.ref == param.ref && @goto found_param
    end
    return 0
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
        e isa MethodError || rethrow()
    end
    # Fallback: parse from function definition line
    ir_str = string(func)
    # Match "dereferenceable(N) %paramname" pattern
    pname = LLVM.name(param)
    # Look for dereferenceable(N) near the param name on the define line
    defline = split(ir_str, "\n")[1]
    m = match(r"dereferenceable\((\d+)\)", defline)
    if m !== nothing
        return parse(Int, m.captures[1])
    end
    return 0
end

function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(convert(Int, val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)  # special: zero aggregate
    else
        r = val.ref
        haskey(names, r) || error("Unknown operand ref for: $(string(val))")
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
        error("Unsupported float type: $tp")
    else
        error("Unsupported LLVM type for width: $tp")
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
