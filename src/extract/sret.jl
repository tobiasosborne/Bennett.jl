# ---- sret (structure return) support (Bennett-dv1z + Bennett-s92x / U115) ----
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
#
# Bennett-s92x / U115 (2026-05-01): the `_detect_sret` ad-hoc NamedTuple
# return was promoted to `struct SretInfo`; the `_collect_sret_writes`
# 173-line write-pattern soup was decomposed into per-pattern handlers
# (`_try_handle_sret_memcpy!`, `_try_handle_sret_gep!`,
# `_try_handle_sret_vector_store!`, `_try_handle_sret_scalar_store!`),
# each of which returns `Bool` ("did I handle this instruction?"). The
# collector body shrank to a clean dispatch loop.

"""
    SretInfo

Detected sret parameter shape for a single function. `agg_type` is the
LLVM `[N x iM]` array type; `param_ref` is the raw LLVMValueRef of the
sret parameter (used to identify direct sret-pointer references in the
function body). `agg_byte_size == n_elems * elem_byte_size`.
"""
struct SretInfo
    param_index::Int
    param_ref::_LLVMRef
    agg_type::LLVM.ArrayType
    n_elems::Int
    elem_width::Int
    elem_byte_size::Int
    agg_byte_size::Int
end

"""
    _detect_sret(func) -> Union{Nothing, SretInfo}

Detect the LLVM `sret` parameter attribute on `func`. Returns `nothing` if no
sret parameter is present — the non-sret path is byte-identical to the
pre-fix behaviour, preserving all existing gate-count baselines.

Errors (fail-fast per CLAUDE.md rule 1):
  * multiple sret parameters (LangRef forbids this)
  * sret pointee is not `[N x iM]` (heterogeneous struct unsupported — MVP scope)
  * sret element is not an integer type
  * sret element width is not in {8, 16, 32, 64}
"""
function _detect_sret(func::LLVM.Function)::Union{Nothing, SretInfo}
    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
    found = nothing
    for (i, p) in enumerate(LLVM.parameters(func))
        attr = LLVM.API.LLVMGetEnumAttributeAtIndex(func, UInt32(i), kind_sret)
        attr == C_NULL && continue
        fname = LLVM.name(func)
        if found !== nothing
            throw(AssertionError("ir_extract.jl: function @$fname has multiple sret parameters " *
                  "(LangRef forbids this); found at parameter indices " *
                  "$(found.param_index) and $i"))
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
        found = SretInfo(i, p.ref, ty, n, w, elem_bytes, n * elem_bytes)
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
    SretWrites

Result bundle from `_collect_sret_writes`. `slot_values` maps each
0-based aggregate slot to its stored value (or a `PendingVecLane`
sentinel for vector stores not yet resolved). `suppressed` is the set
of LLVM instructions the block walk must skip (sret-targeting stores
and their constant-offset GEPs). `pending_vec` and `pending_val_refs`
let pass 2 fill in vector-lane values once the producer instruction is
walked.
"""
struct SretWrites
    slot_values::Dict{Int, IROperand}
    suppressed::Set{_LLVMRef}
    pending_vec::Dict{_LLVMRef, Tuple{Int, Int}}   # store.ref => (first_slot, n_lanes)
    pending_val_refs::Dict{_LLVMRef, _LLVMRef}     # store.ref => val.ref
end

# ---- Per-pattern handlers (Bennett-s92x / U115) -------------------------
# Each `_try_handle_sret_*!` returns `true` iff it consumed the instruction.
# The collector main loop calls them in order; the first to claim wins.

# Reject `llvm.memcpy(sret, ...)` — the unoptimised sret form. Optimised
# pipelines lower this through SROA/mem2reg into per-slot scalar stores
# before extraction.
function _try_handle_sret_memcpy_reject!(inst::LLVM.Instruction, sret_ref::_LLVMRef)::Bool
    LLVM.opcode(inst) == LLVM.API.LLVMCall || return false
    ops = LLVM.operands(inst)
    n_ops = length(ops)
    n_ops >= 1 || return false
    cname = try
        LLVM.name(ops[n_ops])
    catch e
        e isa InterruptException && rethrow()
        ""
    end
    startswith(cname, "llvm.memcpy") || return false
    if n_ops >= 2 && ops[1].ref === sret_ref
        _ir_error(inst,
            "sret with llvm.memcpy form is not supported " *
            "(emitted under optimize=false). Re-compile with " *
            "optimize=true (Bennett.jl default) or set " *
            "preprocess=true to canonicalise via SROA/mem2reg.")
    end
    # llvm.memcpy not targeting sret: leave it for the regular block walk
    return false
end

# Track byte offset of an sret-derived constant-offset GEP. Returns true
# iff the GEP chains off the sret pointer (directly or transitively) —
# in which case the GEP is suppressed and its byte offset recorded.
function _try_handle_sret_gep!(inst::LLVM.Instruction, sret_ref::_LLVMRef,
                                gep_byte::Dict{_LLVMRef, Int},
                                eb::Int, agg_bytes::Int,
                                sret_info::SretInfo,
                                suppressed::Set{_LLVMRef})::Bool
    LLVM.opcode(inst) == LLVM.API.LLVMGetElementPtr || return false
    ops = LLVM.operands(inst)
    length(ops) >= 2 || return false
    base = ops[1]
    base_off = if base.ref === sret_ref
        0
    elseif haskey(gep_byte, base.ref)
        gep_byte[base.ref]
    else
        return false
    end
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
    return true
end

# SLP-emitted vector store into an sret GEP — reserves a slot range with
# `PendingVecLane` sentinels; pass 2 fills in real per-lane values.
function _try_handle_sret_vector_store!(inst::LLVM.Instruction, byte_off::Int,
                                          val::LLVM.Value, ew::Int, eb::Int, n::Int,
                                          slot_values::Dict{Int, IROperand},
                                          pending_vec::Dict{_LLVMRef, Tuple{Int, Int}},
                                          pending_val_refs::Dict{_LLVMRef, _LLVMRef},
                                          suppressed::Set{_LLVMRef})::Bool
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType || return false
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
        slot_values[slot] = PendingVecLane(lane)
    end
    pending_vec[inst.ref] = (first_slot, n_lanes)
    pending_val_refs[inst.ref] = val.ref
    push!(suppressed, inst.ref)
    return true
end

# Scalar integer store into an sret GEP.
function _try_handle_sret_scalar_store!(inst::LLVM.Instruction, byte_off::Int,
                                         val::LLVM.Value, ew::Int, eb::Int, n::Int,
                                         slot_values::Dict{Int, IROperand},
                                         names::Dict{_LLVMRef, Symbol},
                                         suppressed::Set{_LLVMRef})::Bool
    vt = LLVM.value_type(val)
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
        if prior isa PendingVecLane
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
    return true
end

"""
    _collect_sret_writes(func, sret_info, names) -> SretWrites

Pre-walk the function body, classifying every instruction that touches the
sret pointer via the `_try_handle_sret_*!` per-pattern handlers. The
collected `SretWrites` materialises at `ret void` time as a synthetic
IRInsertValue chain.

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
function _collect_sret_writes(func::LLVM.Function, sret_info::SretInfo,
                              names::Dict{_LLVMRef, Symbol})::SretWrites
    slot_values       = Dict{Int, IROperand}()
    suppressed        = Set{_LLVMRef}()
    gep_byte          = Dict{_LLVMRef, Int}()   # sret-derived GEP result → byte offset
    pending_vec       = Dict{_LLVMRef, Tuple{Int, Int}}()
    pending_val_refs  = Dict{_LLVMRef, _LLVMRef}()

    sret_ref  = sret_info.param_ref
    eb        = sret_info.elem_byte_size
    n         = sret_info.n_elems
    ew        = sret_info.elem_width
    agg_bytes = sret_info.agg_byte_size

    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            # Try each per-pattern handler in order. Each returns `true`
            # iff it claimed the instruction.
            _try_handle_sret_memcpy_reject!(inst, sret_ref) && continue
            _try_handle_sret_gep!(inst, sret_ref, gep_byte, eb, agg_bytes,
                                  sret_info, suppressed) && continue

            # Store targeting the sret buffer? Resolve byte offset first,
            # then dispatch to the vector or scalar handler.
            if LLVM.opcode(inst) == LLVM.API.LLVMStore
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
                    _try_handle_sret_vector_store!(inst, byte_off, val, ew, eb, n,
                                                    slot_values, pending_vec,
                                                    pending_val_refs, suppressed) && continue
                    _try_handle_sret_scalar_store!(inst, byte_off, val, ew, eb, n,
                                                    slot_values, names, suppressed) && continue
                end
            end
        end
    end

    # Every slot must be written before ret void
    fname = LLVM.name(func)
    for k in 0:(n - 1)
        haskey(slot_values, k) || throw(AssertionError(
            "ir_extract.jl: sret slot $k in @$fname is never written; every " *
            "element of the aggregate return must be stored before ret void"))
    end

    return SretWrites(slot_values, suppressed, pending_vec, pending_val_refs)
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
    haskey(lanes, produced_ref) || throw(AssertionError(
        "ir_extract.jl: pending sret vector store's stored value " *
        "$(produced_ref) was not registered in the vector-lane table " *
        "during pass 2. The producer of the <N x iM> value is an " *
        "instruction whose vector output isn't decomposed by " *
        "_convert_vector_instruction."))
    per_lane = lanes[produced_ref]
    length(per_lane) == n_lanes || throw(DimensionMismatch(
        "ir_extract.jl: pending sret vector store expected $n_lanes lanes " *
        "but got $(length(per_lane)) from the vector-lane table"))
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
    throw(AssertionError("ir_extract.jl: $(length(refs)) pending sret vector store(s) " *
          "remain unresolved at ret void. This means the producer of the " *
          "stored vector value wasn't processed in pass 2 (likely skipped " *
          "by _convert_instruction's cc0.3 catch-block)."))
end

"""
    _synthesize_sret_chain(sret_info, slot_values, counter) -> (Vector{IRInst}, IRRet)

Build an `IRInsertValue` chain that reconstructs the aggregate return value
from the per-slot stored values, terminated by an `IRRet`. Structurally
identical to the `insertvalue` chain LLVM emits for n=2 by-value aggregate
returns, so downstream lowering sees no difference.
"""
function _synthesize_sret_chain(sret_info::SretInfo, slot_values::Dict{Int, IROperand},
                                counter::Ref{Int})
    n  = sret_info.n_elems
    ew = sret_info.elem_width
    chain = IRInst[]
    agg_op = ZERO_AGG
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

