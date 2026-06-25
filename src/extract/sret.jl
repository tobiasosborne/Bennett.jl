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

Detected sret parameter shape for a single function. `param_ref` is the raw
LLVMValueRef of the sret parameter (used to identify direct sret-pointer
references in the function body).

Two shapes (Bennett-dv1z extended the original homogeneous-only struct):

  * **Homogeneous** (`is_hetero == false`): the sret pointee is an LLVM
    `[N x iM]` array. `agg_type` is the `ArrayType`, `n_elems`/`elem_width`/
    `elem_byte_size` describe the uniform element layout, and
    `agg_byte_size == n_elems * elem_byte_size`. `fields === nothing`.

  * **Heterogeneous** (`is_hetero == true`, Bennett-dv1z): the sret pointee is
    an LLVM `StructType` of fixed-width integer fields of possibly DIFFERING
    widths (e.g. `{i64, i8}`). `agg_type` is the `StructType`, and `fields` is
    a `Vector{Tuple{Int,Int}}` of `(byte_offset, width_bits)` per field, in
    field order, derived from the LLVM datalayout (`LLVMOffsetOfElement`).
    `agg_byte_size` is the padded ABI size (`LLVMSizeOfType`) used ONLY for
    GEP bounds-checking — NEVER for the return width, which is `sum(field
    widths)` (the packed bit width, padding dropped). `n_elems == length(fields)`;
    `elem_width`/`elem_byte_size` are set to 0 (meaningless for hetero — any
    code reading them on the hetero path is a bug).
"""
struct SretInfo
    param_index::Int
    param_ref::_LLVMRef
    agg_type::LLVM.LLVMType
    n_elems::Int
    elem_width::Int
    elem_byte_size::Int
    agg_byte_size::Int
    is_hetero::Bool
    fields::Union{Nothing,Vector{Tuple{Int,Int}}}  # per-field (byte_offset, width_bits)
end

"""
    _detect_sret(func) -> Union{Nothing, SretInfo}

Detect the LLVM `sret` parameter attribute on `func`. Returns `nothing` if no
sret parameter is present — the non-sret path is byte-identical to the
pre-fix behaviour, preserving all existing gate-count baselines.

Errors (fail-fast per CLAUDE.md rule 1):
  * multiple sret parameters (LangRef forbids this)
  * sret pointee is neither `[N x iM]` nor a fixed-width-integer struct
  * sret array element / struct field is not an integer type
  * sret element/field width is not in {8, 16, 32, 64}

Bennett-dv1z extended the detection to a 3-way dispatch on the pointee type:
an `ArrayType` is the EXISTING homogeneous arm (byte-identical); a `StructType`
of fixed-width integer fields is the NEW heterogeneous arm (`_sret_struct_fields`);
anything else still rejects loud (the `sret pointee` substring is pinned by
`test_land_ptrfield_struct.jl`).
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
        if ty isa LLVM.ArrayType
            # ---- Homogeneous arm (pre-dv1z, VERBATIM) ----
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
            found = SretInfo(i, p.ref, ty, n, w, elem_bytes, n * elem_bytes,
                             false, nothing)
        elseif ty isa LLVM.StructType
            # ---- Heterogeneous arm (Bennett-dv1z, NEW) ----
            fields, agg_bytes = _sret_struct_fields(ty, func)
            found = SretInfo(i, p.ref, ty, length(fields), 0, 0, agg_bytes,
                             true, fields)
        else
            error(
                "ir_extract.jl: sret pointee is $ty in @$fname; only [N x iM] " *
                "arrays and fixed-width integer bits-structs (e.g. {i64,i8}) " *
                "are supported (Bennett-dv1z)")
        end
    end
    return found
end

"""
    _sret_struct_fields(st, func) -> (Vector{Tuple{Int,Int}}, Int)

Bennett-dv1z: extract the per-field layout of a heterogeneous integer
bits-struct sret pointee. Returns `(fields, agg_byte_size)` where `fields` is a
`Vector{(byte_offset, width_bits)}` in field order (byte offset from the LLVM
datalayout via `LLVMOffsetOfElement`, NEVER IR-text parsing or `index * width`
— the fields are NOT contiguous when padding is present) and `agg_byte_size` is
the padded ABI size (`LLVMSizeOfType`).

Rejects loud (CLAUDE.md §1) on:
  * packed structs (different layout rules — out of scope)
  * any non-`IntegerType` field (pointer / float / nested struct / vector)
  * any integer field whose width ∉ {8, 16, 32, 64}
"""
function _sret_struct_fields(st::LLVM.StructType, func::LLVM.Function)
    fname = LLVM.name(func)
    LLVM.ispacked(st) && error(
        "ir_extract.jl: sret pointee $st in @$fname is a packed struct; only " *
        "unpacked fixed-width integer bits-struct fields are supported " *
        "(Bennett-dv1z)")
    mod = LLVM.parent(func)
    dl = LLVM.datalayout(mod)
    elem_tys = LLVM.elements(st)
    isempty(elem_tys) && error(
        "ir_extract.jl: sret pointee $st in @$fname is an empty struct; only " *
        "fixed-width integer bits-struct fields are supported (Bennett-dv1z)")
    fields = Tuple{Int,Int}[]
    for (k, fty) in enumerate(elem_tys)
        fty isa LLVM.IntegerType || error(
            "ir_extract.jl: sret struct field $(k-1) has type $fty in @$fname; " *
            "only fixed-width integer bits-struct fields are supported " *
            "(pointer/float/nested-struct/vector fields are rejected — Bennett-dv1z)")
        w = LLVM.width(fty)
        w ∈ (8, 16, 32, 64) || error(
            "ir_extract.jl: sret struct field $(k-1) has width $w in @$fname, " *
            "not in {8,16,32,64}; only fixed-width integer bits-struct fields " *
            "are supported (Bennett-dv1z)")
        off = Int(LLVM.offsetof(dl, st, k - 1))
        push!(fields, (off, Int(w)))
    end
    agg_bytes = Int(LLVM.sizeof(dl, st))
    return (fields, agg_bytes)
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
    SretCallReturn

Bennett-59zi: a recovered "return the aggregate produced by a callee" record for
a block whose return is `memcpy(parent_sret, box, agg); ret void` where `box` is
the sret-out alloca of an in-world CALL. The block is modelled as a single
`IRCall(dest, callee, args, arg_widths, ret_width) → IRRet(ssa(dest), ret_width)`.

`callee` is the resolved Julia `Function` (recursive self-call or any registered
in-set callee) or a `Symbol` (the `.ll` C-track name-only form). `ret_width` is
the PARENT sret packed bit width (`sum(field widths)` — NOT the producing call's
own LLVM return type, which is `void`). `args`/`arg_widths` are the producing
call's integer operands (the ptr sret-out and any pgcstack/ptr args dropped,
exactly like the default `IRCall` arm).
"""
struct SretCallReturn
    dest::Symbol
    callee::Union{Function, Symbol}
    args::Vector{IROperand}
    arg_widths::Vector{Int}
    ret_width::Int
end

"""
    SretWrites

Result bundle from `_collect_sret_writes`.

Bennett-jghk (multi-return-site sret): the per-slot stored values are collected
PER STORE-BEARING BLOCK, not into one global dict. `block_slot_values` maps each
LLVM block ref (the block CONTAINING the sret stores) to that block's
`Dict{Int,IROperand}` of slot ↦ stored value (or a `PendingVecLane` sentinel for
vector stores not yet resolved). The optimised, auto-SROA'd Julia shape for a
multi-arm tuple return emits ONE store-bearing block per branch arm, each
writing every slot, then `br` to a single shared `ret void` block. Synthesis
(in module_walk.jl) turns each such block into its own value-bearing IRRet,
and the downstream `resolve_phi_predicated!` multi-IRRet merge reconciles them.

For the single-return case (one store-bearing block whose own terminator is
`ret void`) `block_slot_values` has exactly one entry and the synthesis is
byte-identical to the pre-jghk single-site path.

`slot_values` (legacy field, RETAINED) is the SINGLE store-bearing block's slot
map when there is exactly one store-bearing block — it aliases that block's dict
so the vector-lane resolution plumbing (`_resolve_pending_vec_for_val!`,
`_assert_no_pending_vec_stores!`), which mutates a single flat dict, stays
byte-identical. When there is MORE than one store-bearing block, `slot_values`
is empty and vector sret stores are rejected loud (multi-return + SLP vector
store is out of MVP scope — Julia never emits it for the hetero/scalar shapes
jghk targets).

`suppressed` is the set of LLVM instructions the block walk must skip
(sret-targeting stores and their constant-offset GEPs). `ret_void_blocks` is the
set of block refs whose terminator is `ret void` AND which contain NO sret
stores of their own — these are dropped at synthesis (their value-bearing
predecessors carry the return). `pending_vec`/`pending_val_refs` let pass 2 fill
in vector-lane values once the producer instruction is walked.
"""
struct SretWrites
    slot_values::Dict{Int, IROperand}                       # legacy: single-block alias
    block_slot_values::Dict{_LLVMRef, Dict{Int, IROperand}} # per store-bearing block
    suppressed::Set{_LLVMRef}
    ret_void_blocks::Set{_LLVMRef}                           # store-free `ret void` blocks
    pending_vec::Dict{_LLVMRef, Tuple{Int, Int}}   # store.ref => (first_slot, n_lanes)
    pending_val_refs::Dict{_LLVMRef, _LLVMRef}     # store.ref => val.ref
    # Bennett-59zi: sret-returning CALL forwarded into the parent sret via a
    # local alloca + whole-aggregate llvm.memcpy. `block_call_returns` maps each
    # such call-return block ref to the recovered call record; `call_return_suppressed`
    # holds the box alloca + the memcpy + the producing call (suppressed in the
    # block walk so the call is re-synthesised once, with ret_width from the
    # PARENT sret packed width — the void producing call has no width of its own).
    block_call_returns::Dict{_LLVMRef, SretCallReturn}
    call_return_suppressed::Set{_LLVMRef}
end

# ---- Per-pattern handlers (Bennett-s92x / U115) -------------------------
# Each `_try_handle_sret_*!` returns `true` iff it consumed the instruction.
# The collector main loop calls them in order; the first to claim wins.

# Triage `llvm.memcpy(sret, ...)` — the whole-aggregate sret copy form.
#
# Two cases, in order:
#   * Bennett-59zi (Wall A): `memcpy(parent_sret, %box, agg_byte_size)` where
#     `%box` is the sret-out alloca of an in-world CALL → recognised: record a
#     `SretCallReturn`, suppress the box / memcpy / producing call. The block
#     becomes a value-bearing `IRCall → IRRet` at synthesis time.
#   * otherwise (an unoptimised sret memcpy whose source is NOT a call's sret-out
#     alloca, e.g. a `[N x iM]` const-init box from raw optimize=false) → the
#     EXISTING loud reject (SROA/mem2reg canonicalises that shape).
#
# Returns true iff it claimed the instruction (Wall A match). A non-match that is
# also not the reject shape (memcpy not targeting parent sret) returns false and
# is left for the regular block walk / padding classifier.
function _try_handle_sret_memcpy_reject!(inst::LLVM.Instruction, sret_ref::_LLVMRef,
                                          sret_info::SretInfo, func::LLVM.Function,
                                          names::Dict{_LLVMRef, Symbol},
                                          block_call_returns::Dict{_LLVMRef, SretCallReturn},
                                          call_return_suppressed::Set{_LLVMRef},
                                          counter::Ref{Int})::Bool
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
    startswith(cname, "llvm.memcpy.") || return false
    # Only a memcpy whose DST is the parent sret param is in scope here; a memcpy
    # into an sret-derived GEP (padding bytes) is the Wall-B classifier's job.
    (n_ops >= 2 && ops[1].ref === sret_ref) || return false

    # ---- Wall A recognition (Bennett-59zi). Each predicate is fail-loud if it
    # "almost matches" — no silent fall-through into a miscompile. ----

    # P1: addrspace 0, exactly 5 operands (dst, src, N, isvolatile, callee).
    startswith(cname, "llvm.memcpy.p0.p0.") || _ir_error(inst,
        "Bennett-59zi: whole-aggregate sret-call memcpy with non-default " *
        "pointer address space ($cname) is not supported")
    n_ops == 5 || _ir_error(inst,
        "Bennett-59zi: malformed whole-aggregate sret memcpy (expected 4 args " *
        "+ callee ⇒ n_ops==5, got $n_ops)")

    # P2: byte count N is a constant equal to the FULL padded aggregate size.
    nbytes_op = ops[3]
    nbytes_op isa LLVM.ConstantInt || _ir_error(inst,
        "Bennett-59zi: whole-aggregate sret memcpy byte count is non-constant; " *
        "variable-size sret copies are not supported")
    N = _const_int_as_int(nbytes_op)
    N == sret_info.agg_byte_size || _ir_error(inst,
        "Bennett-59zi: whole-aggregate sret-call memcpy copies N=$N bytes, not " *
        "the full aggregate ($(sret_info.agg_byte_size) bytes); partial / " *
        "over-size aggregate returns are not modelled")

    # P3: non-volatile.
    vol_op = ops[4]
    vol_op isa LLVM.ConstantInt || _ir_error(inst,
        "Bennett-59zi: whole-aggregate sret memcpy isvolatile flag is non-constant")
    _const_int_as_int(vol_op) == 0 || _ir_error(inst,
        "Bennett-59zi: volatile whole-aggregate sret-call memcpy is not supported")

    # P4: src is a direct local alloca (the producing call's sret-out buffer).
    src_ref = ops[2].ref
    LLVM.API.LLVMIsAAllocaInst(src_ref) != C_NULL || _ir_error(inst,
        "Bennett-59zi: whole-aggregate sret memcpy source is not a local alloca; " *
        "only a call's sret-out alloca is modelled (got $(ops[2]))")

    # P5: bind src ↔ producing CALL by data-flow + call-site `sret` attribute
    # (NOT textual adjacency). Scan THIS block for the unique non-memcpy CALL `C`
    # carrying a call-site `sret` attribute whose sret-out operand === src_ref.
    bb = LLVM.parent(inst)
    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
    producing = nothing
    n_writers = 0
    for cand in LLVM.instructions(bb)
        LLVM.opcode(cand) == LLVM.API.LLVMCall || continue
        cand === inst && continue
        cops = LLVM.operands(cand)
        length(cops) >= 1 || continue
        cn = try
            LLVM.name(cops[length(cops)])
        catch e
            e isa InterruptException && rethrow()
            ""
        end
        startswith(cn, "llvm.memcpy.") && continue  # skip other intrinsics
        # call-site sret attribute at param-index 1 (the sret-out operand).
        a = LLVM.API.LLVMGetCallSiteEnumAttribute(cand, UInt32(1), kind_sret)
        a == C_NULL && continue
        length(cops) >= 1 && cops[1].ref === src_ref || continue
        n_writers += 1
        producing = cand
    end
    n_writers == 0 && _ir_error(inst,
        "Bennett-59zi: whole-aggregate sret memcpy source alloca is not the " *
        "sret-out of any call in this block (no producing sret call found)")
    n_writers == 1 || _ir_error(inst,
        "Bennett-59zi: whole-aggregate sret memcpy source alloca is the sret-out " *
        "of $n_writers calls in this block; only a single producing call is modelled")
    C = producing::LLVM.Instruction

    # P6: the producing call's sret pointee type equals the parent aggregate type.
    aC = LLVM.API.LLVMGetCallSiteEnumAttribute(C, UInt32(1), kind_sret)
    callee_agg = LLVM.LLVMType(LLVM.API.LLVMGetTypeAttributeValue(aC))
    callee_agg == sret_info.agg_type || _ir_error(inst,
        "Bennett-59zi: producing call returns $callee_agg but the parent sret " *
        "aggregate is $(sret_info.agg_type); forwarding a differently-shaped " *
        "aggregate is not supported")

    # P7: the producing call is sret-form (LLVM return type void).
    LLVM.value_type(C) isa LLVM.VoidType || _ir_error(inst,
        "Bennett-59zi: producing sret call has non-void LLVM return type " *
        "$(LLVM.value_type(C)); the sret-out form requires a void return")

    # P8: alias/reuse guard — the box alloca is written ONLY by C and read ONLY
    # by this memcpy (single-writer single-reader). Any other use ⇒ reject loud.
    src_alloca = LLVM.Value(src_ref)
    for u in LLVM.uses(src_alloca)
        user = LLVM.user(u)
        (user === C || user === inst) && continue
        _ir_error(inst,
            "Bennett-59zi: sret-out alloca $(LLVM.name(src_alloca)) is aliased / " *
            "reused (an extra use beyond its single producing call + single " *
            "forwarding memcpy); only single-writer single-reader is modelled")
    end

    # P9: resolve the producing call's callee. Function (registered Julia callee,
    # incl. self-recursion) preferred; else Symbol (the .ll C-track name-only form).
    cn = LLVM.name(LLVM.operands(C)[length(LLVM.operands(C))])
    resolved = _lookup_callee(cn)
    callee_val::Union{Function, Symbol} = if resolved !== nothing
        resolved
    else
        # Only the .ll set/ptr-cells path admits a name-only callee; a missing
        # registration on the Julia path is a hard error (can't inline it later).
        Symbol(cn)
    end

    # Build the args/widths from C's integer operands, dropping the sret-out ptr
    # and any pgcstack/ptr args — identical policy to the default IRCall arm.
    Cops = LLVM.operands(C)
    call_args = IROperand[]
    call_widths = Int[]
    for i in 1:(length(Cops) - 1)
        op = Cops[i]
        ot = LLVM.value_type(op)
        ot isa LLVM.IntegerType || continue   # skip the sret-out ptr + ptr args
        push!(call_args, _operand(op, names))
        push!(call_widths, Int(LLVM.width(ot)))
    end

    # ret_width = the PARENT sret packed bit width. Hetero → sum(field widths);
    # homogeneous [N x iM] → n_elems * elem_width (matches the by-value paths in
    # module_walk.jl:131-141 exactly). NOT the producing call's (void) return.
    ret_width = sret_info.is_hetero ?
        sum(w for (_, w) in sret_info.fields::Vector{Tuple{Int,Int}}) :
        sret_info.n_elems * sret_info.elem_width
    dest = _auto_name(counter)
    bb_ref = bb.ref
    haskey(block_call_returns, bb_ref) && _ir_error(inst,
        "Bennett-59zi: block has $(length(block_call_returns)+1) whole-aggregate " *
        "sret-call memcpys; one call-return per block only")
    block_call_returns[bb_ref] = SretCallReturn(dest, callee_val, call_args,
                                                call_widths, ret_width)
    # Suppress the box alloca, the producing call, and this memcpy.
    push!(call_return_suppressed, src_ref)
    push!(call_return_suppressed, C.ref)
    push!(call_return_suppressed, inst.ref)
    return true
end

# Bennett-59zi (Wall B): classify an sret-derived memcpy whose dst is a GEP off
# the sret param (already recorded in `gep_byte`) — NOT the bare sret param (that
# is Wall A). A copy whose byte range lies ENTIRELY in padding (disjoint from
# every field byte-range) is INERT — the padding bytes never enter the packed
# return — so it is suppressed. A range that OVERLAPS a field is rejected loud
# (a real value-write via memcpy is out of scope). Returns true iff claimed.
function _try_handle_sret_padding_memcpy!(inst::LLVM.Instruction, sret_ref::_LLVMRef,
                                           gep_byte::Dict{_LLVMRef, Int},
                                           sret_info::SretInfo,
                                           suppressed::Set{_LLVMRef})::Bool
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
    startswith(cname, "llvm.memcpy.") || return false
    n_ops >= 3 || return false
    dst_ref = ops[1].ref
    # dst must be an sret-derived GEP (recorded byte offset); the bare-sret case
    # is Wall A and never reaches here.
    haskey(gep_byte, dst_ref) || return false
    off = gep_byte[dst_ref]

    startswith(cname, "llvm.memcpy.p0.p0.") || _ir_error(inst,
        "Bennett-59zi: sret-derived padding memcpy with non-default address " *
        "space ($cname) is not supported")
    nbytes_op = ops[3]
    nbytes_op isa LLVM.ConstantInt || _ir_error(inst,
        "Bennett-59zi: sret-derived padding memcpy byte count is non-constant")
    N = _const_int_as_int(nbytes_op)
    if n_ops >= 4
        vol_op = ops[4]
        if vol_op isa LLVM.ConstantInt && _const_int_as_int(vol_op) != 0
            _ir_error(inst,
                "Bennett-59zi: volatile sret-derived padding memcpy is not supported")
        end
    end
    agg = sret_info.agg_byte_size
    (0 <= off && off + N <= agg) || _ir_error(inst,
        "Bennett-59zi: sret-derived memcpy byte range [$off, $(off+N)) is " *
        "outside the aggregate range [0, $agg)")

    # Padding iff disjoint from every field's byte range. Field k occupies
    # [foff, foff + width/8). Reject loud on any overlap (value-write via memcpy).
    fields = sret_info.is_hetero ? sret_info.fields::Vector{Tuple{Int,Int}} :
        [(k * sret_info.elem_byte_size, sret_info.elem_width) for k in 0:(sret_info.n_elems - 1)]
    for (foff, fw) in fields
        fend = foff + fw ÷ 8
        # ranges [off, off+N) and [foff, fend) overlap iff off < fend && foff < off+N
        if off < fend && foff < off + N
            _ir_error(inst,
                "Bennett-59zi: sret memcpy byte range [$off, $(off+N)) overlaps " *
                "field bytes [$foff, $fend); only padding-only (disjoint-from-all-" *
                "fields) sret memcpys are inert-suppressed (a value write via " *
                "memcpy is out of scope)")
        end
    end
    push!(suppressed, inst.ref)
    return true
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
        # Bennett-dv1z (hostile-review SF-1): the typed-element GEP strides by
        # `eb` (elem_byte_size), which is 0/meaningless on the heterogeneous
        # arm — a typed whole-struct GEP off a hetero sret would SILENTLY compute
        # offset 0 (§1 forbids silent-wrong-arithmetic). Hetero structs only ever
        # see i8 byte-indexed GEPs (opaque-pointer Julia); reject the typed form.
        sret_info.is_hetero && _ir_error(inst,
            "typed-element GEP (source $src_ty) off a heterogeneous-struct sret " *
            "is unsupported — only i8 byte-indexed GEPs (Bennett-dv1z)")
        _const_int_as_int(idx) * eb    # typed GEP on [N x iM] (homogeneous only)
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
#
# Bennett-dv1z: the slot ↦ field resolution differs by aggregate kind:
#   * homogeneous `[N x iM]`: `slot = byte_off ÷ eb` (uniform element stride);
#   * heterogeneous struct:   `slot = findfirst(f -> f[1] == byte_off, fields)`
#     (an EXACT match against the per-field byte offset from the datalayout —
#     NEVER `byte_off ÷ eb`, because hetero fields have differing widths and
#     padding, so byte offset is not `slot * eb`). A store whose byte offset
#     hits no field exactly (padding byte, misalignment, partial-field write)
#     is rejected loud.
function _try_handle_sret_scalar_store!(inst::LLVM.Instruction, byte_off::Int,
                                         val::LLVM.Value, ew::Int, eb::Int, n::Int,
                                         slot_values::Dict{Int, IROperand},
                                         names::Dict{_LLVMRef, Symbol},
                                         suppressed::Set{_LLVMRef},
                                         sret_info::SretInfo)::Bool
    vt = LLVM.value_type(val)
    vt isa LLVM.IntegerType || _ir_error(inst,
        "sret store at byte offset $byte_off has non-integer value " *
        "type $vt; only integer stores are supported")
    sw = LLVM.width(vt)

    local slot::Int
    if sret_info.is_hetero
        fields = sret_info.fields::Vector{Tuple{Int,Int}}
        fidx = findfirst(f -> f[1] == byte_off, fields)
        fidx === nothing && _ir_error(inst,
            "sret store at byte offset $byte_off matches no field in " *
            "heterogeneous bits-struct (field offsets: " *
            "$([f[1] for f in fields])); padding-byte / misaligned / " *
            "partial-field writes are not supported (Bennett-dv1z)")
        fw = fields[fidx][2]
        sw == fw || _ir_error(inst,
            "sret store at byte offset $byte_off has value width $sw, but " *
            "field $(fidx-1) width is $fw (partial-field writes are not " *
            "supported — Bennett-dv1z)")
        slot = fidx - 1
    else
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
    end

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
                              names::Dict{_LLVMRef, Symbol},
                              counter::Ref{Int})::SretWrites
    # Bennett-jghk: per store-bearing block. Each store appends to the dict
    # for the block it lives in, so two arms of a `cond ? A : B` tuple return
    # (each its own store-block) no longer collide on a single global slot 0.
    # The within-a-block duplicate-store reject is UNCHANGED and still loud.
    block_slot_values = Dict{_LLVMRef, Dict{Int, IROperand}}()
    suppressed        = Set{_LLVMRef}()
    ret_void_blocks   = Set{_LLVMRef}()
    gep_byte          = Dict{_LLVMRef, Int}()   # sret-derived GEP result → byte offset
    pending_vec       = Dict{_LLVMRef, Tuple{Int, Int}}()
    pending_val_refs  = Dict{_LLVMRef, _LLVMRef}()
    # Bennett-59zi: sret-returning CALL forwarded via local alloca + memcpy.
    block_call_returns     = Dict{_LLVMRef, SretCallReturn}()
    call_return_suppressed = Set{_LLVMRef}()

    sret_ref  = sret_info.param_ref
    eb        = sret_info.elem_byte_size
    n         = sret_info.n_elems
    ew        = sret_info.elem_width
    agg_bytes = sret_info.agg_byte_size

    # The GEP byte-offset map must be fully populated before the Wall-B padding
    # classifier runs (it keys on gep_byte). The sret-targeting GEPs always
    # dominate their stores/memcpys, and LLVM.blocks/instructions iterate in
    # program order, so a single forward pass suffices — but the memcpy triage
    # is placed AFTER the GEP handler within the loop for exactly this reason.
    for bb in LLVM.blocks(func)
        bb_ref = bb.ref
        for inst in LLVM.instructions(bb)
            # Try each per-pattern handler in order. Each returns `true`
            # iff it claimed the instruction.
            _try_handle_sret_gep!(inst, sret_ref, gep_byte, eb, agg_bytes,
                                  sret_info, suppressed) && continue
            # Bennett-59zi Wall A: sret-call → whole-aggregate memcpy(parent_sret).
            _try_handle_sret_memcpy_reject!(inst, sret_ref, sret_info, func, names,
                                            block_call_returns,
                                            call_return_suppressed, counter) && continue
            # Bennett-59zi Wall B: inert sret-derived padding memcpy (suppressed),
            # or loud reject on a field-overlapping memcpy.
            _try_handle_sret_padding_memcpy!(inst, sret_ref, gep_byte,
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
                    # This store's slot values accumulate in THIS block's dict.
                    slot_values = get!(() -> Dict{Int, IROperand}(),
                                       block_slot_values, bb_ref)
                    # Bennett-dv1z: the SLP vector-store path is homogeneous-only
                    # (it presumes a uniform lane width == element width). A
                    # heterogeneous bits-struct never produces a single vector
                    # store across differing field widths; gate it off so the
                    # hetero path can't divide by the zeroed `eb`.
                    if !sret_info.is_hetero
                        _try_handle_sret_vector_store!(inst, byte_off, val, ew, eb, n,
                                                        slot_values, pending_vec,
                                                        pending_val_refs, suppressed) && continue
                    end
                    _try_handle_sret_scalar_store!(inst, byte_off, val, ew, eb, n,
                                                    slot_values, names, suppressed,
                                                    sret_info) && continue
                end
            end
        end
    end

    fname = LLVM.name(func)

    # Bennett-59zi (R12): a block must be EXACTLY ONE return shape. A block that
    # both stores sret slots AND call-returns the whole aggregate is ambiguous
    # (which value does the return path carry?) — fail loud rather than guess.
    for bb_ref in keys(block_call_returns)
        haskey(block_slot_values, bb_ref) && throw(AssertionError(
            "ir_extract.jl: block in @$fname both stores sret slots AND " *
            "whole-aggregate call-returns; a return path must be exactly one " *
            "shape (Bennett-59zi)."))
    end

    # Bennett-jghk: classify `ret void` blocks. A `ret void` block that has NO
    # sret stores of its own is a SHARED return funnel (the `common.ret` shape):
    # its store-bearing predecessors each carry the value-bearing return, so it
    # is dropped at synthesis. A `ret void` block that DOES contain sret stores
    # (the single-return `top:` shape) keeps its synthesis in-place.
    #
    # Bennett-59zi: a call-return block (L171 shape) is ALSO value-bearing — it
    # synthesises an IRCall → IRRet — so it must NOT be classified as a store-free
    # funnel and dropped. Exclude it from ret_void_blocks (its `ret void` is the
    # block's own terminator, replaced by the synthesised IRRet).
    for bb in LLVM.blocks(func)
        term = LLVM.terminator(bb)
        (LLVM.opcode(term) == LLVM.API.LLVMRet && isempty(LLVM.operands(term))) || continue
        if !haskey(block_slot_values, bb.ref) && !haskey(block_call_returns, bb.ref)
            push!(ret_void_blocks, bb.ref)
        end
    end

    # Every store-bearing block must write EVERY slot (a partial-slot write on a
    # return path returns garbage for the missing slot). This is the per-return-
    # path version of the pre-jghk global "every slot written" assert — stricter
    # and CFG-correct (a slot written on some OTHER path no longer masks an
    # unwritten slot on this one). Vector-lane PendingVecLane sentinels count as
    # written (the lane value is filled in pass 2).
    for (bb_ref, slot_values) in block_slot_values
        for k in 0:(n - 1)
            haskey(slot_values, k) || throw(AssertionError(
                "ir_extract.jl: sret slot $k in @$fname is never written on the " *
                "return path through this block; every element of the aggregate " *
                "return must be stored before the return (Bennett-jghk: " *
                "partial / conditional slot writes are not supported)"))
        end
    end

    # Bennett-59zi: a function whose ONLY return shape is a whole-aggregate
    # call-return (no per-slot store block) is now valid — the aggregate IS
    # materialised, by the producing call. Only error when BOTH are empty.
    (isempty(block_slot_values) && isempty(block_call_returns)) && throw(AssertionError(
        "ir_extract.jl: sret function @$fname has no store-bearing block and no " *
        "whole-aggregate call-return block; the aggregate return is never " *
        "materialised (Bennett-jghk / Bennett-59zi). Likely the return is built " *
        "via an unsupported path (e.g. llvm.memcpy from a const global)."))

    # Bennett-jghk: the legacy `slot_values` field aliases the SINGLE store-
    # bearing block's dict (so the vector-lane plumbing stays byte-identical).
    # With >1 store-bearing block, vector sret stores are unsupported (see the
    # docstring); `slot_values` stays empty and any pending vector store would
    # have a producer the multi-block path never resolves — guard it loud.
    legacy_slot_values = if length(block_slot_values) == 1
        first(values(block_slot_values))
    else
        if !isempty(pending_vec)
            throw(AssertionError(
                "ir_extract.jl: sret function @$fname has $(length(block_slot_values)) " *
                "store-bearing blocks AND an SLP vector sret store; multi-return-" *
                "site combined with vector stores is not supported (Bennett-jghk)."))
        end
        Dict{Int, IROperand}()
    end

    return SretWrites(legacy_slot_values, block_slot_values, suppressed,
                      ret_void_blocks, pending_vec, pending_val_refs,
                      block_call_returns, call_return_suppressed)
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

"""
    _synthesize_sret_bits(sret_info, slot_values, counter) -> (Vector{IRInst}, IRRet)

Bennett-dv1z: build an `IRInsertBits` chain that packs each heterogeneous
bits-struct field into a `W = sum(field widths)`-bit value, terminated by an
`IRRet(_, W)`. The fields are packed at CONTIGUOUS bit offsets IN FIELD ORDER
(`bit += w` after each field) — i.e. field 0 occupies the lowest bits, field 1
the next, and so on. The LLVM byte offsets / ABI padding are deliberately
DROPPED: the packed value is `W` bits wide (NOT the padded ABI byte size), and
the downstream `_read_output` consumes `ret_elem_widths` contiguously in the
same order, so element `k` reads back exactly field `k` (field0-low/field1-high).

`slot_values[k]` is the value stored to field `k` (0-based), populated by
`_try_handle_sret_scalar_store!` using the exact-byte-offset → field-index map.
"""
function _synthesize_sret_bits(sret_info::SretInfo, slot_values::Dict{Int, IROperand},
                               counter::Ref{Int})
    fields = sret_info.fields::Vector{Tuple{Int,Int}}
    W = sum(w for (_, w) in fields)
    chain = IRInst[]
    agg_op = ZERO_AGG
    last_dest = Symbol("")
    bit = 0
    for k in 0:(length(fields) - 1)
        w = fields[k + 1][2]
        dest = _auto_name(counter)
        push!(chain, IRInsertBits(dest, agg_op, slot_values[k], bit, w, W))
        agg_op = ssa(dest)
        last_dest = dest
        bit += w
    end
    ret_inst = IRRet(ssa(last_dest), W)
    return (chain, ret_inst)
end

