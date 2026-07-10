# ---- instruction conversion ----

# ---- Bennett-37mt (Bennett-hao Phase 1) memcpy helpers ----

"""
    _alloca_root_ref(val, depth=0) -> Union{Nothing, _LLVMRef}

Walk the producer chain from a pointer SSA value back to its underlying
`alloca` instruction. Returns the alloca's LLVM ref, or `nothing` if the
chain doesn't bottom out in an alloca (e.g. function parameter, global,
ptr-phi, ptr-select).

Recursion bound at depth 8 to defend against pathological IR (LLVM
doesn't usually nest GEPs > 2 in practice).

Used by `_handle_memcpy_arm` to (a) check both pointers are
alloca-backed and (b) detect the same-alloca case (memmove dressed as
memcpy).
"""
function _alloca_root_ref(val::LLVM.Value, depth::Int=0)::Union{Nothing, _LLVMRef}
    depth > 8 && return nothing
    val.ref == C_NULL && return nothing
    if LLVM.API.LLVMIsAAllocaInst(val.ref) != C_NULL
        return val.ref
    end
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 1 || return nothing
        return _alloca_root_ref(gep_ops[1], depth + 1)
    end
    return nothing
end

"""
    _struct_field_widths(st::LLVM.StructType, inst, ptr_cells::Bool) -> Vector{Int}

Bennett-6bu3: extract the per-field bit-width layout of a StructType aggregate
for `insertvalue`/`extractvalue`. Mirrors `_sret_struct_fields`
(src/extract/sret.jl) but returns ONLY the per-field WIDTHS (in field order),
since the aggregate slot model is contiguous (no padding) — the
insert/extract operate on logical field INDEX, not byte offset.

Field rules (CLAUDE.md §1 — every rejection is fail-loud, citing Bennett-6bu3):
  * IntegerType → `LLVM.width`, REQUIRING width ∈ {8,16,32,64}. This is the
    load-bearing guard that keeps `{i64,i1}` (`llvm.*.with.overflow` results,
    `cmpxchg` results) FAILING LOUD — i1 is rejected.
  * PointerType → 64, but ONLY under `ptr_cells` (a pointer is one Int64 VM
    cell, ADR 0018 §A). Without ptr_cells a pointer field fails loud.
  * float / nested-struct / vector / array fields, packed structs, and empty
    structs are all rejected loud.

NOTE: pointer-field widths are computed HERE (constant 64), NOT routed through
`_iwidth`/`_type_width` — those have no PointerType arm and would error.
"""
function _struct_field_widths(st::LLVM.StructType, inst::LLVM.Instruction,
                              ptr_cells::Bool)::Vector{Int}
    LLVM.ispacked(st) && _ir_error(inst,
        "insertvalue/extractvalue on a PACKED StructType $(string(st)) is not " *
        "supported; only unpacked structs of fixed-width integer ({8,16,32,64}) " *
        "or (under ptr_cells) pointer fields are. (Bennett-6bu3)")
    elem_tys = LLVM.elements(st)
    isempty(elem_tys) && _ir_error(inst,
        "insertvalue/extractvalue on an EMPTY StructType $(string(st)) is not " *
        "supported; the aggregate has no fields. (Bennett-6bu3)")
    widths = Int[]
    for (k, fty) in enumerate(elem_tys)
        if fty isa LLVM.IntegerType
            w = LLVM.width(fty)
            w ∈ (8, 16, 32, 64) || _ir_error(inst,
                "StructType field $(k-1) of $(string(st)) has integer width $w " *
                "not in {8,16,32,64}; the bits-struct slot model only supports " *
                "fixed-width integer fields (this REJECTS i1 — `{i64,i1}` " *
                "overflow/cmpxchg structs are out of scope). (Bennett-6bu3)")
            push!(widths, Int(w))
        elseif fty isa LLVM.PointerType
            ptr_cells || _ir_error(inst,
                "StructType field $(k-1) of $(string(st)) is a pointer field, " *
                "which requires ptr_cells=true (a pointer is one Int64 VM cell, " *
                "ADR 0018 §A); on the circuit path pointer fields are not " *
                "supported. (Bennett-6bu3)")
            push!(widths, 64)
        else
            _ir_error(inst,
                "StructType field $(k-1) of $(string(st)) has unsupported type " *
                "$(string(fty)); only fixed-width integer ({8,16,32,64}) or " *
                "(under ptr_cells) pointer fields are supported — float, " *
                "nested-struct, vector, and array fields are rejected. " *
                "(Bennett-6bu3)")
        end
    end
    return widths
end

"""
    _gc_alloc_root_ref(val, depth=0) -> Union{Nothing, _LLVMRef}

Bennett-vbv9 (2026-06): the ARENA analogue of `_alloca_root_ref`. Walk the
producer chain from a pointer SSA value back to its underlying
`julia.gc_alloc_obj` CALL — the closed-world arena allocation (Bennett-r92o /
CW-D3 Lever 2; BennettVM ADR 0021 D3 bump floor). Returns the call's LLVM ref,
or `nothing` if the chain doesn't bottom out in a `julia.gc_alloc_obj` call
(e.g. function parameter, global, ptr-phi, ptr-select, alloca).

Mirrors `_alloca_root_ref`'s const-GEP recursion EXACTLY (same depth-8 bound,
same `LLVMGetElementPtr` opcode walk, same `gep_ops[1]` base step), differing
only in the bottom-out predicate: a Call instruction whose LAST operand (the
callee, per the `cname = LLVM.name(ops[n_ops])` convention used throughout this
file) is named `julia.gc_alloc_obj`.

The real fdict field-init dst-GEP is `getelementptr inbounds i8, ptr %obj,
i32 OFF` (a single-index i8 GEP off the gc_alloc result — empirically verified
Bennett-vbv9 STEP 0c), so the recursion is a single GEP hop to the call.

Used by `_handle_memcpy_global_src` (G3) ONLY under `ptr_cells=true` — an
arena dst makes no sense on the circuit path, which has no gc_alloc cell model.
"""
function _gc_alloc_root_ref(val::LLVM.Value, depth::Int=0)::Union{Nothing, _LLVMRef}
    depth > 8 && return nothing
    val.ref == C_NULL && return nothing
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMCall
        call_ops = LLVM.operands(val)
        n = length(call_ops)
        n >= 1 || return nothing
        # Callee is the LAST operand (file-wide convention). Read its name; a
        # missing/exotic callee name simply means "not our gc_alloc_obj".
        callee_name = try
            LLVM.name(call_ops[n])
        catch e
            e isa InterruptException && rethrow()
            return nothing
        end
        return callee_name == "julia.gc_alloc_obj" ? val.ref : nothing
    end
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 1 || return nothing
        return _gc_alloc_root_ref(gep_ops[1], depth + 1)
    end
    return nothing
end

"""
    _param_ptr_root_ref(val, depth=0) -> Union{Nothing, _LLVMRef}

Bennett-u2kk (2026-06): the POINTER-PARAMETER analogue of `_alloca_root_ref` /
`_gc_alloc_root_ref`. Walk the producer chain from a pointer SSA value back to
its underlying function POINTER PARAMETER — the closed-world caller-supplied
cell (e.g. the `Dict` struct-by-ref param `h::Dict`; BennettVM ADR 0018 §A flat
address space). Returns the parameter's LLVM ref, or `nothing` if the chain
doesn't bottom out in a pointer-typed Argument (e.g. alloca, global, gc_alloc
call, ptr-phi, ptr-select, or an INTEGER argument — never a cell root).

Mirrors `_alloca_root_ref`'s const-GEP recursion EXACTLY (same depth-8 bound,
same `LLVMGetElementPtr` opcode walk, same `gep_ops[1]` base step), differing
only in the bottom-out predicate: an LLVM `Argument` whose `value_type` is a
`PointerType`. (The PointerType guard is deliberate — an integer-typed argument
carries a value, not a cell address, so it is never a memcpy-dst cell root.)

The real rehash! field-init dst-GEP is `getelementptr inbounds i8, ptr
%"h::Dict", i32 OFF` (a single-index i8 GEP off the Dict pointer param, after
the extractor's addrspace-demotion preprocessing folds the p11 addrspacecast),
so the recursion is a single GEP hop to the Argument. The same shape the proven
setindex! field STORES already lower off `h::Dict` (see probe_field_gep).

Used by `_handle_memcpy_global_src` (G3) ONLY under `ptr_cells=true` — a param
cell dst makes no sense on the circuit path, which has no BVM cell model nor a
history tape to reverse the destructive field overwrite (see the reversibility
note at the G4 branch below).
"""
function _param_ptr_root_ref(val::LLVM.Value, depth::Int=0)::Union{Nothing, _LLVMRef}
    depth > 8 && return nothing
    val.ref == C_NULL && return nothing
    if LLVM.API.LLVMIsAArgument(val.ref) != C_NULL &&
       LLVM.value_type(val) isa LLVM.PointerType
        return val.ref
    end
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 1 || return nothing
        return _param_ptr_root_ref(gep_ops[1], depth + 1)
    end
    return nothing
end

# ---- Bennett-583s / CW-D: GenericMemory `.data`-base ptrtoint provenance ----
#
# The `setindex!`/`getindex`/`rehash!` @boundscheck (under --check-bounds=yes)
# lowers to a base-cancelling difference of two `.data`-base pointers:
#
#   %g     = getelementptr {i64,ptr}, ptr %mem, i32 0, i32 1  ; field-1 = .data
#   %data  = load ptr, ptr %g
#   %elem  = getelementptr i8, ptr %data, i64 %off
#   %b     = ptrtoint ptr %data to i64
#   %e     = ptrtoint ptr %elem to i64
#   %d     = sub i64 %e, %b                                   ; == %off (base cancels)
#   %c     = icmp ult i64 %d, %len                            ; dead throw @boundscheck
#
# `_memdata_root` returns the Memory struct-base ref of a `.data`-provenanced
# pointer (its identity); `_verify_memdata_bounds_cluster` proves the ptrtoint
# result NEVER escapes the same-Memory base-cancelling `sub(ptrtoint,ptrtoint)`
# pattern. Both are the SOLE soundness boundary (see the ptrtoint arm below):
# `sub(ptrtoint(base+off), ptrtoint(base)) = off` is base-INDEPENDENT (matches
# the native oracle), but a base-DEPENDENT / escaping address would not.

# Is `gepval` a field-1 GEP of a `{i64,ptr}` GenericMemory struct (`.data`)?
function _is_memdata_field1_gep(gepval)::Bool
    gepval isa LLVM.Instruction || return false
    LLVM.opcode(gepval) == LLVM.API.LLVMGetElementPtr || return false
    ops = LLVM.operands(gepval)
    length(ops) == 3 || return false
    st = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(gepval.ref))
    st isa LLVM.StructType || return false
    els = LLVM.elements(st)
    length(els) == 2 || return false
    (els[1] isa LLVM.IntegerType && LLVM.width(els[1]) == 64) || return false
    els[2] isa LLVM.PointerType || return false
    # indices [0, 1] (field-1)
    (ops[2] isa LLVM.ConstantInt && _const_int_as_int(ops[2]) == 0) || return false
    (ops[3] isa LLVM.ConstantInt && _const_int_as_int(ops[3]) == 1) || return false
    return true
end

# The Memory root ref of a memdata-provenanced pointer value, or `nothing`.
# Seed: `load ptr` of a `{i64,ptr}` field-1 GEP → the struct base ref.
# Propagate through `getelementptr i8` (the elem byte-offset GEP) and identity
# casts. Depth-bounded like `_param_ptr_root_ref` / `_alloca_root_ref`.
function _memdata_root(v, depth::Int=0)::Union{Nothing, _LLVMRef}
    depth > 8 && return nothing
    v isa LLVM.Instruction || return nothing
    opc = LLVM.opcode(v)
    if opc == LLVM.API.LLVMLoad
        LLVM.value_type(v) isa LLVM.PointerType || return nothing
        p = LLVM.operands(v)[1]
        _is_memdata_field1_gep(p) || return nothing
        return LLVM.operands(p)[1].ref                 # the {i64,ptr} struct base
    elseif opc == LLVM.API.LLVMGetElementPtr
        # propagate through the i8 byte-offset GEP only
        st = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(v.ref))
        (st isa LLVM.IntegerType && LLVM.width(st) == 8) || return nothing
        return _memdata_root(LLVM.operands(v)[1], depth + 1)
    elseif opc in (LLVM.API.LLVMAddrSpaceCast, LLVM.API.LLVMBitCast)
        return _memdata_root(LLVM.operands(v)[1], depth + 1)
    end
    return nothing
end

# Same-base gate: EVERY use of the memdata ptrtoint `pt` must be a `sub i64`
# whose sibling operand is a ptrtoint of a SAME-ROOT memdata pointer. A ptrtoint
# with NO uses (`saw == false`), or any use that is not such a same-root sub,
# means the base does not provably cancel → reject (the bennettvm-90l hazard).
function _verify_memdata_bounds_cluster(pt::LLVM.Instruction, src)::Bool
    root = _memdata_root(src)
    root === nothing && return false
    saw = false
    for u in LLVM.uses(pt)
        saw = true
        usr = LLVM.user(u)
        (usr isa LLVM.Instruction && LLVM.opcode(usr) == LLVM.API.LLVMSub) || return false
        ops = LLVM.operands(usr)
        length(ops) == 2 || return false
        sib = ops[1].ref == pt.ref ? ops[2] : ops[1]
        (sib isa LLVM.Instruction && LLVM.opcode(sib) == LLVM.API.LLVMPtrToInt) || return false
        _memdata_root(LLVM.operands(sib)[1]) == root || return false
    end
    return saw
end

"""
    _gc_loaded_dst_elem_ref(gep_val) -> Union{Nothing, Tuple{_LLVMRef,_LLVMRef,Int}}

Bennett-qmv7 (2026-06): the HEAP-Memory analogue of `_gc_alloc_root_ref`, but
for the RUNTIME-INDEXED element store into a Julia `Memory`/`GenericMemory`
cell (the Dict keys/vals backing). Recognises a `setindex!`-style dst pointer

    %d    = call ptr @julia.gc_loaded(ptr %mem, ptr %data)   ; laundered data ptr
    %bo   = mul i64 %off, STRIDE                             ; byte offset = elem_idx * stride
    %addr = getelementptr inbounds i8, ptr %d, i64 %bo       ; single-index i8 GEP

and returns `(gc_loaded_call_ref, raw_element_index_ref, STRIDE)` — where
`raw_element_index_ref` is the PRE-`mul` `%off` (the 0-based ELEMENT index)
and `STRIDE` is the constant byte stride. Returns `nothing` for any other
shape.

  *** eln6 byte/cell contract (Bennett-eln6) — THE LOAD-BEARING REASON ***
The dst GEP is ALWAYS an `i8` GEP whose index is the BYTE offset `%off*STRIDE`
(Julia byte-GEPs into the Memory data region; the i8 source type is NOT the
element width). BVM's `IRVarGEP` lowering is CELL-addressed (stride 1, one
Int64 per cell) and consumes the index operand AS the element index. So
feeding the byte offset `%bo` directly (as the already-lowered
`IRVarGEP(:addr,:d,:bo,8)` would) addresses cell `off*STRIDE` — correct only
for STRIDE==1 (i8 coincidence), an `8×` misaddress for an i64-vals Memory.
This helper splits the `mul` and returns the RAW element index `%off` so the
caller emits a FRESH `IRVarGEP(dst, gc_loaded_base, off, value_ew)` — cell
`off`, correct for EVERY element width. This is the SAME `mul %off, STRIDE`
→ keep-`%off`, drop-`%bo` split the proven `mem=:vm` recogniser performs in
`vector_vm_walk.jl` (the D6/b5x stride pattern), applied at the memcpy-dst
site. NEVER feed the byte offset; NEVER use the i8 GEP type as the width.

Consulted ONLY under `ptr_cells=true` (see `_handle_memcpy_arm`); on the
circuit / `mem=:heap` model a gc_loaded heap cell has no semantics, so the
caller stays at the byte-identical fail-loud.
"""
function _gc_loaded_dst_elem_ref(gep_val::LLVM.Value
                                )::Union{Nothing, Tuple{_LLVMRef, _LLVMRef, Int}}
    gep_val.ref == C_NULL && return nothing
    (gep_val isa LLVM.Instruction &&
     LLVM.opcode(gep_val) == LLVM.API.LLVMGetElementPtr) || return nothing
    gep_ops = LLVM.operands(gep_val)
    # Single-index GEP only: base + exactly one index operand.
    length(gep_ops) == 2 || return nothing
    base = gep_ops[1]
    idx  = gep_ops[2]
    # Base must be a `julia.gc_loaded` call (callee = LAST operand, file-wide
    # convention).
    (base isa LLVM.Instruction &&
     LLVM.opcode(base) == LLVM.API.LLVMCall) || return nothing
    base_ops = LLVM.operands(base)
    nbo = length(base_ops)
    nbo >= 1 || return nothing
    callee_name = try
        LLVM.name(base_ops[nbo])
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    callee_name == "julia.gc_loaded" || return nothing
    # Index must be `mul %off, STRIDE` with STRIDE a positive ConstantInt; the
    # surviving %off is the raw element index (eln6-safe — never the byte off).
    (idx isa LLVM.Instruction &&
     LLVM.opcode(idx) == LLVM.API.LLVMMul) || return nothing
    mul_ops = LLVM.operands(idx)
    length(mul_ops) >= 2 || return nothing
    off    = mul_ops[1]
    stride = mul_ops[2]
    stride isa LLVM.ConstantInt || return nothing
    stride_val = _const_int_as_int(stride)
    stride_val >= 1 || return nothing
    return (base.ref, off.ref, stride_val)
end

"""
    _alloca_elem_width_bits(alloca_ref) -> Int

Returns the alloca's element width in bits, or 0 if the allocated type
is not a Bennett-supported integer-or-integer-array shape (struct, ptr,
nested array, non-integer inner).

Supported shapes:
  - `iN` IntegerType — returns N (Bennett-munq accepted `i8`; ixiz
    extended to arbitrary `iN`, but `iN` already worked via the
    IntegerType branch above).
  - `[K x iN]` ArrayType wrapping an IntegerType — returns N. Bennett-
    munq accepted only `[K x i8]`; Bennett-ixiz (2026-05-16) lifted the
    `LLVM.width(inner) == 8` gate to accept arbitrary integer inner
    widths (`[K x i16]`, `[K x i32]`, `[K x i64]`, ...).

Nested ArrayType (`[K x [M x i8]]`) still returns 0 — the
`inner isa LLVM.IntegerType || return 0` guard rejects the nested case
because the inner of a nested ArrayType is itself ArrayType, not
IntegerType. Future-deferred to a follow-up bead (Bennett-8bys
catch-all).
"""
function _alloca_elem_width_bits(alloca_ref::_LLVMRef)::Int
    elem_ty = LLVM.LLVMType(LLVM.API.LLVMGetAllocatedType(alloca_ref))
    if elem_ty isa LLVM.IntegerType
        return LLVM.width(elem_ty)
    end
    if elem_ty isa LLVM.ArrayType
        inner = LLVM.eltype(elem_ty)
        inner isa LLVM.IntegerType || return 0
        return LLVM.width(inner)
    end
    return 0
end

"""
    _handle_memcpy_arm(cname, inst, names, counter, ops, globals) -> Vector{IRInst}

Bennett-37mt Phase 1 + Bennett-doih (2026-05-16): const-size memcpy.
Two arms post-doih:

  - **Non-global arm (37mt + ixiz):** distinct `alloca iM`-backed src/dst,
    lowered as K element-granular IRPtrOffset+IRLoad+IRStore chunks where
    K = N / ew_bytes and width = dst_ew (8/16/32/64 — same on both sides).
  - **Global-src arm (doih):** src is a constant global from the
    `parsed.globals` dict, dst is a fresh alloca. Lowered as K element-
    granular IRPtrOffset+IRStore(iconst) chunks pulling the value from
    the global's data words. See `_handle_memcpy_global_src` for the
    G1-G9 sub-cascade. DST-as-global is still rejected (writable target
    makes no sense for a constant).

Out-of-scope shapes fail loud with a precise message naming the
appropriate downstream bead (`Bennett-8bys` for the catch-all,
`Bennett-doih-struct` / `Bennett-doih-wide` / `Bennett-doih-vargep` for
the doih follow-up cases).

Predicates checked, in order, so the earliest mismatch produces the
most actionable error:

  1. addrspace 0 only (cname must be `llvm.memcpy.p0.p0.*`)
  2. `isvolatile == false`
  3. N is a `ConstantInt` (≥ 0)
  4. N == 0 → return `IRInst[]` (legal no-op)
  5a. dst operand is NOT a global variable (still rejected)
  5b. if src operand IS a global variable → dispatch to
      `_handle_memcpy_global_src` (doih arm)
  6. both operands trace to an alloca (direct or via const-offset GEP)
  7. distinct alloca roots (rejects `memcpy(p, p, N)` self-copy)
  8. both alloca's element width is 8 bits

The `globals` arg is the ParsedIR globals dict threaded down from
`_module_to_parsed_ir_on_func`; empty for non-doih invocations.
"""
function _handle_memcpy_arm(cname::AbstractString, inst::LLVM.Instruction,
                            names::Dict{_LLVMRef, Symbol}, counter::Ref{Int}, ops,
                            globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}=
                                Dict{Symbol, Tuple{Vector{UInt64}, Int}}();
                            synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}=
                                Set{Tuple{Symbol, Int, Int}}(),
                            synth_ptr_allocas::Set{_LLVMRef}=Set{_LLVMRef}(),
                            ptr_cells::Bool=false)
    # Predicate 1: addrspace 0 on both pointers (encoded in the intrinsic name).
    startswith(cname, "llvm.memcpy.p0.p0.") || _ir_error(inst,
        "$(cname): memcpy with non-default pointer address space is not " *
        "supported. Bennett.jl's wire model is single-address-space; " *
        "cross-space copies need explicit lowering. Tracked in " *
        "Bennett-8bys. (Bennett-37mt Phase 1 — addrspace 0 only)")

    n_ops = length(ops)
    n_ops >= 5 || _ir_error(inst,
        "$(cname): malformed memcpy call (expected 4 args + callee, got " *
        "$(n_ops - 1) args). (Bennett-37mt Phase 1)")

    dst_v = ops[1]
    src_v = ops[2]
    n_v   = ops[3]
    vol_v = ops[4]

    # Predicate 2: isvolatile must be a ConstantInt with value 0.
    vol_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): isvolatile arg is not an i1 immarg constant " *
        "(value=$(string(vol_v))). LangRef requires an immarg here; " *
        "malformed IR. (Bennett-37mt Phase 1)")
    _const_int_as_int(vol_v) == 0 || _ir_error(inst,
        "$(cname): volatile memcpy is not supported. Bennett.jl's " *
        "reversible model has no observable side-effect ordering for " *
        "memory; volatile semantics cannot be honoured. Recompile " *
        "without the volatile attribute, or wait on Bennett-8bys " *
        "(catch-all). (Bennett-37mt Phase 1)")

    # Predicate 3: byte count must be a ConstantInt.
    n_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): memcpy with non-constant byte count is not supported. " *
        "Variable-size memcpy requires runtime-bounded loop unrolling. " *
        "Tracked in Bennett-8bys (Phase 3: variable-size). " *
        "(Bennett-37mt Phase 1 — const-N only)")
    N = _const_int_as_int(n_v)
    N >= 0 || _ir_error(inst,
        "$(cname): negative byte count $N (corrupt IR; LLVM treats the " *
        "size argument as unsigned i64 but the C API returns Int64). " *
        "(Bennett-37mt Phase 1)")

    # Predicate 4: N == 0 is a legal no-op.
    N == 0 && return IRInst[]

    # Predicate 5a (Bennett-doih, 2026-05-16): DST cannot be a global —
    # the global is read-only constant data; writing to it would mutate
    # text-section memory, which Bennett's reversible model has no
    # semantics for. Remains a hard reject; tracked in Bennett-8bys for
    # any future fancy dst-global semantics (e.g. shadow-copy buffer).
    if LLVM.API.LLVMIsAGlobalVariable(dst_v.ref) != C_NULL
        _ir_error(inst,
            "$(cname): memcpy with a global-variable dst pointer is not " *
            "supported — global data is read-only constant memory and " *
            "Bennett's reversible model has no semantics for mutating it. " *
            "Tracked in Bennett-8bys (catch-all, sub-case: \"Global- " *
            "pointer dst memcpy\"). " *
            "(Bennett-doih — global-src memcpy supported; global-dst rejected)")
    end

    # Predicate 5b (Bennett-doih): SRC may be a global — dispatch to
    # the new global-src arm. Two ways src can reach the global:
    #   (i) direct global reference (`memcpy(_, @g, _, _)`)
    #   (ii) const-GEP wrapping a global (`memcpy(_, getelementptr i8,
    #        ptr @g, i32 OFF, _, _)`) — common when the source pointer
    #        is offset into a larger constant.
    # `_global_root_and_offset` handles both forms; if it returns
    # non-nothing we route to the global-src arm. Variable-GEP src
    # (runtime index into a global) is rejected inside that helper
    # with a precise Bennett-doih-vargep breadcrumb.
    if _src_reaches_global(src_v)
        return _handle_memcpy_global_src(cname, inst, names, counter, ops, globals;
                                         synth_ptr_provenance=synth_ptr_provenance,
                                         synth_ptr_allocas=synth_ptr_allocas,
                                         ptr_cells=ptr_cells)
    end

    # Predicate 6: both pointers must trace back to an alloca.
    dst_root = _alloca_root_ref(dst_v)
    src_root = _alloca_root_ref(src_v)

    # Bennett-qmv7 (2026-06): under the closed-world `ptr_cells` gate, a memcpy
    # whose DST is a runtime-indexed element store into a `julia.gc_loaded`
    # heap-Memory cell (the dual of vbv9's const-offset gc_alloc ARENA dst) is a
    # valid VM heap pointer (the Dict keys/vals backing). The src is the
    # alloca-backed value box (the sret `[2 x i64]` field on the fdict root).
    # Route to `_handle_memcpy_gc_loaded`, which recovers the RAW element index
    # (splitting the `mul %off, STRIDE` — eln6-safe) and emits a fresh
    # IRVarGEP+IRLoad+IRStore at the VALUE element width. The circuit path
    # (`ptr_cells=false`) skips this branch entirely → byte-identical fail-loud
    # at the unchanged Predicate-6 reject below.
    if ptr_cells && dst_root === nothing
        heap_dst = _gc_loaded_dst_elem_ref(dst_v)
        if heap_dst !== nothing
            return _handle_memcpy_gc_loaded(cname, inst, names, counter, ops,
                                            heap_dst, src_root)
        end
    end

    dst_root === nothing && _ir_error(inst,
        "$(cname): memcpy dst operand is not alloca-backed (or " *
        "alloca-backed via a const-offset GEP). Bennett's pointer- " *
        "provenance model only covers alloca and GEP-of-alloca; pointer " *
        "phi/select/parameter sources fan out to multiple origins which " *
        "Bennett-37mt does not yet handle. Tracked in Bennett-8bys. " *
        "(Bennett-37mt Phase 1)")
    src_root === nothing && _ir_error(inst,
        "$(cname): memcpy src operand is not alloca-backed (or " *
        "alloca-backed via a const-offset GEP). Same restriction as " *
        "the dst case; tracked in Bennett-8bys. (Bennett-37mt Phase 1)")

    # Predicate 7: src and dst must be distinct allocas (memmove semantics).
    dst_root === src_root && _ir_error(inst,
        "$(cname): memcpy with src and dst rooted at the same alloca is " *
        "semantically memmove (overlapping or in-place copy). " *
        "Reversibility forbids destructive in-place overwrite. Tracked " *
        "in Bennett-8bys. (Bennett-37mt Phase 1 — distinct allocas only)")

    # Predicate 8: both allocas must have a known integer element type.
    # Bennett-ixiz (2026-05-16) lifted the prior `dst_ew == 8 && src_ew == 8`
    # gate; arbitrary equal integer element widths (8/16/32/64) are now
    # accepted. The new predicates 8b (same-width) and 8c (N is multiple of
    # ew_bytes) follow.
    dst_ew = _alloca_elem_width_bits(dst_root)
    src_ew = _alloca_elem_width_bits(src_root)
    if dst_ew == 0 || src_ew == 0
        _ir_error(inst,
            "$(cname): memcpy operand alloca has non-integer element type " *
            "(dst_ew=$dst_ew bits, src_ew=$src_ew bits — 0 indicates a " *
            "struct, ptr, nested-array, or non-integer ArrayType inner). " *
            "Bennett's wire model only supports flat integer-typed " *
            "allocas. Tracked in Bennett-8bys. (Bennett-37mt / Bennett-ixiz)")
    end

    # Predicate 8b (Bennett-ixiz): src and dst must have the same element
    # width. Cross-width memcpy requires implicit pack/unpack lowering and
    # a wider shadow-tape contract; out-of-scope for ixiz.
    dst_ew == src_ew || _ir_error(inst,
        "$(cname): memcpy cross-width src/dst (src=$src_ew bits, " *
        "dst=$dst_ew bits) is out-of-scope for Bennett-ixiz — requires " *
        "implicit pack/unpack lowering. Tracked in Bennett-8bys.")

    # Predicate 8c (Bennett-ixiz): N must be a whole multiple of element-
    # size bytes. Byte-granular tail copy (loading partial elements) is
    # out-of-scope.
    rem(N * 8, dst_ew) == 0 || _ir_error(inst,
        "$(cname): memcpy N=$N bytes is not a multiple of element size " *
        "$(div(dst_ew, 8)) bytes — byte-granular tail copy is " *
        "out-of-scope for Bennett-ixiz. Tracked in Bennett-8bys.")

    # Operand resolution: both operand SSA names must be in the table.
    haskey(names, dst_v.ref) || _ir_error(inst,
        "$(cname): memcpy dst pointer is not a named SSA value. " *
        "(Bennett-37mt Phase 1)")
    haskey(names, src_v.ref) || _ir_error(inst,
        "$(cname): memcpy src pointer is not a named SSA value. " *
        "(Bennett-37mt Phase 1)")
    dst_op = ssa(names[dst_v.ref])
    src_op = ssa(names[src_v.ref])

    # Bennett-land: carry-through tagging. If src alloca was previously
    # tagged as carrying synthetic-address bytes (via a prior memcpy
    # from a struct-with-ptr-field global), propagate the tag to dst.
    # This handles the HashMap::new pattern:
    #   memcpy %_3 ← @anon       (tags %_3 in global-src arm)
    #   memcpy %_2 ← %_3         (this arm: propagates tag to %_2)
    #   memcpy %_0 ← %_2         (this arm: propagates tag to %_0)
    # Without this propagation, a later load through %_2 / %_0 would
    # silently miscompile on the synth-address bytes.
    if src_root in synth_ptr_allocas
        push!(synth_ptr_allocas, dst_root)
    end

    # Expansion (Bennett-ixiz): K element-granular
    # IRPtrOffset+IRPtrOffset+IRLoad+IRStore quads, where
    # K = N / ew_bytes and each load/store is at width = dst_ew.
    ew_bytes = div(dst_ew, 8)
    K = div(N, ew_bytes)
    out = IRInst[]
    sizehint!(out, 4 * K)
    for k in 0:(K - 1)
        src_off = _auto_name(counter)
        dst_off = _auto_name(counter)
        tmp     = _auto_name(counter)
        push!(out, IRPtrOffset(src_off, src_op, k * ew_bytes, dst_ew))
        push!(out, IRPtrOffset(dst_off, dst_op, k * ew_bytes, dst_ew))
        push!(out, IRLoad(tmp, ssa(src_off), dst_ew))
        push!(out, IRStore(ssa(dst_off), ssa(tmp), dst_ew))
    end
    return out
end

# ---- Bennett-qmv7 (2026-06-25, CW-D fdict critical path) ----
"""
    _handle_memcpy_gc_loaded(cname, inst, names, counter, ops, heap_dst, src_root)
        -> Vector{IRInst}

Bennett-qmv7: lower a SINGLE-ELEMENT memcpy whose DST is a runtime-indexed
`julia.gc_loaded` heap-Memory cell store (the `setindex!` value-store into a
Dict's keys/vals `Memory`). The dual of vbv9 (const-offset gc_alloc ARENA dst);
here the dst byte-offset is a RUNTIME SSA (`%off * STRIDE`), so we address by
the RAW element index, never the byte offset (the eln6-safe split done by
`_gc_loaded_dst_elem_ref`).

`heap_dst = (gc_loaded_base_ref, raw_index_ref, stride_bytes)` from
`_gc_loaded_dst_elem_ref`. `src_root` is the src alloca ref (or `nothing`).

Reached ONLY under `ptr_cells=true` (the caller gate). Emission reuses ONLY
existing IR nodes (IRVarGEP/IRLoad/IRStore — Rule 12); no new IR node, no BVM
ingest change for the store itself (the gc_loaded IRCall + its base resolution
are downstream BVM concerns, separate beads).

### Element-width contract (eln6, Rule 1)
The VALUE element width is the Memory element width = `stride_bytes*8` (the byte
stride the index `mul` scales by), NEVER the i8 dst-GEP source type and NEVER a
blind 64. CRUCIALLY it is NOT the src alloca's element width either: on the real
fdict root the src is the `setindex!` sret box (`alloca [2 x i64]`, so
`_alloca_elem_width_bits == 64`) accessed through a const-i8-GEP, but the stored
value is i8 — so the box width would mis-report 64 for an i8 store. The single
authoritative width is `N*8` (the memcpy byte count scaled to bits), which for a
single element equals `stride_bytes*8`. We require `N == stride_bytes` (one
element) so all three agree, and the resulting `value_ew` addresses cell `off`
at the correct width for EVERY Memory element type.

### Fail-loud matrix
  - src not alloca-backed (`src_root === nothing`)            → reject
  - N (memcpy bytes) != stride_bytes (multi-element / sub-elt)→ reject
  - value ew = N*8 ∉ {8,16,32,64}                             → reject
  - gc_loaded base / raw index / src not a named SSA value    → reject
"""
function _handle_memcpy_gc_loaded(cname::AbstractString, inst::LLVM.Instruction,
                                  names::Dict{_LLVMRef, Symbol}, counter::Ref{Int},
                                  ops,
                                  heap_dst::Tuple{_LLVMRef, _LLVMRef, Int},
                                  src_root::Union{Nothing, _LLVMRef})
    dst_v = ops[1]
    src_v = ops[2]
    n_v   = ops[3]
    N     = _const_int_as_int(n_v)   # Predicates 1-4 (caller) already validated.

    gcl_ref, off_ref, stride_bytes = heap_dst

    # The src must be alloca-backed so the IRLoad reads from a valid named SSA
    # value box (the setindex! sret field).
    src_root === nothing && _ir_error(inst,
        "$(cname): gc_loaded heap-Memory memcpy src is not alloca-backed — " *
        "the value box (a setindex! sret field) must root at an alloca. " *
        "(Bennett-qmv7)")

    # Single-element only: a setindex! stores exactly one element, so the memcpy
    # byte count N must equal the Memory's byte stride. A multi-element memcpy
    # (N != stride) into a heap Memory would need per-element cell-stride
    # emission and does not arise on the fdict root. Enforcing N == stride_bytes
    # makes the value width unambiguous (value_ew = N*8 = stride_bytes*8).
    N == stride_bytes || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory memcpy N=$(N) bytes != single " *
        "element size $(stride_bytes) bytes (the byte stride from " *
        "`mul %off, $(stride_bytes)`) — multi-element / sub-element heap-Memory " *
        "memcpy is out of scope (the fdict setindex! root stores exactly one " *
        "element). Tracked in Bennett-qmv7-multi. (Bennett-qmv7)")

    # The value element width = the Memory element width = N*8 bits (== the byte
    # stride scaled to bits). NEVER the i8 dst-GEP type, NEVER the src box width
    # (which is the [2 x i64] sret box = 64, not the i8/i16/... stored value),
    # NEVER a blind 64. This is the single eln6-safe width for the heap cell.
    value_ew = N * 8
    value_ew ∈ (8, 16, 32, 64) || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory memcpy element width $(value_ew) bits " *
        "(= N*8, N=$(N)) ∉ {8,16,32,64} — only byte/half/word/dword heap-cell " *
        "stores are modelled. (Bennett-qmv7)")

    # The gc_loaded base and the raw element index must be named SSA values
    # (they are: the gc_loaded CALL and the `sub %k, 1` index both lower
    # normally before this memcpy in block order — empirically verified).
    haskey(names, gcl_ref) || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory base (julia.gc_loaded result) is " *
        "not a named SSA value. (Bennett-qmv7)")
    haskey(names, off_ref) || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory element index is not a named SSA " *
        "value. (Bennett-qmv7)")
    haskey(names, src_v.ref) || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory memcpy src pointer is not a named " *
        "SSA value. (Bennett-qmv7)")

    base_op = ssa(names[gcl_ref])
    idx_op  = ssa(names[off_ref])
    src_op  = ssa(names[src_v.ref])

    # Emit: fresh element-address GEP at the RAW index (cell `off`, eln6-safe) +
    # load the value out of the alloca-backed src + store it into the heap cell.
    addr = _auto_name(counter)
    tmp  = _auto_name(counter)
    return IRInst[
        IRVarGEP(addr, base_op, idx_op, value_ew),
        IRLoad(tmp, src_op, value_ew),
        IRStore(ssa(addr), ssa(tmp), value_ew),
    ]
end

# ---- Bennett-doih (2026-05-16, Bennett-8bys sub-bead under Bennett-hao Phase 3) ----
# Global-pointer src memcpy: copies bytes from a `[N x iM]` ConstantDataArray
# global into a fresh alloca destination. Lowers to K element-granular
# IRPtrOffset+IRStore(iconst) chunks pulling per-element values from the
# `parsed.globals` dict (extracted in `module_walk.jl::_extract_const_globals`).
#
# Scope (MVP — intentionally narrow per CLAUDE.md §11 / "scope it tight"
# lesson from Bennett-ixiz):
#   - src is either a direct global reference OR a const-GEP `getelementptr
#     i8, ptr @g, i32 OFF` whose base is a global. Variable-GEP src is
#     rejected with `Bennett-doih-vargep`.
#   - global must appear in `parsed.globals` (i.e. be a `ConstantDataArray`
#     of integer elements, post-_extract_const_globals filtering).
#     ConstantStruct globals → `Bennett-doih-struct`. External / opaque
#     initializers → `Bennett-doih-external` / `Bennett-doih-opaque`.
#   - dst is a fresh alloca with the SAME integer element width as the
#     global (mirrors `_handle_memcpy_arm`'s predicate 8b). Cross-width
#     (`alloca i64` dst + `[N x i8]` global, or vice versa) → `Bennett-
#     doih-wide`. The follow-up bead `Bennett-doih-wide` covers byte-
#     packing for cross-width.
#   - N (byte count) must be a multiple of `gw/8` AND fit within the
#     global's available bytes after applying any const-GEP offset.
#   - dst alloca must be FRESH per `_alloca_is_fresh` (closes the 37mt
#     inherited hazard — pre-doih the alloca-i8 memcpy path never had
#     this gate, but doih is the first memcpy variant we're shipping
#     with a constant source-side, so the freshness contract matters
#     for the same §1 reason as Bennett-9nwt's case C).

"""
    _src_reaches_global(val) -> Bool

Cheap predicate: returns `true` iff `val` is a direct global reference
or a ConstantExpr GEP whose base operand is a global. Used by
`_handle_memcpy_arm`'s predicate 5b to decide whether to dispatch to
the doih global-src arm. The full unpacking (global ref + byte offset)
happens in `_global_root_and_offset` once we're inside the doih arm.
"""
function _src_reaches_global(val::LLVM.Value)::Bool
    val.ref == C_NULL && return false
    LLVM.API.LLVMIsAGlobalVariable(val.ref) != C_NULL && return true
    # Const-GEP wrapping a global: kind == ConstantExprValueKind AND
    # the constexpr's opcode is `getelementptr`. Operand 1 of that
    # GEP is the base — recurse one level (defence-in-depth: nested
    # const-GEPs are uncommon but legal).
    if val isa LLVM.ConstantExpr
        opc = LLVM.API.LLVMGetConstOpcode(val.ref)
        if opc == LLVM.API.LLVMGetElementPtr
            gep_ops = LLVM.operands(val)
            length(gep_ops) >= 1 || return false
            return _src_reaches_global(gep_ops[1])
        end
    end
    # Runtime GEP (Instruction) whose base reaches a global. We still
    # route to the doih arm so it can fail-loud with a precise
    # `Bennett-doih-vargep` breadcrumb; falling through to predicate 6
    # would mis-categorise the failure as "not alloca-backed" + 37mt.
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 1 || return false
        return _src_reaches_global(gep_ops[1])
    end
    return false
end

"""
    _global_root_and_offset(val) -> Union{Nothing, Tuple{_LLVMRef, Int}}

Walk a pointer SSA value back to its underlying global, accumulating
any const-GEP byte offsets along the way. Returns `(global_ref,
byte_offset)` or `nothing` if the chain doesn't bottom out in a global
or if a variable-index GEP is encountered.

Currently handles:
  - direct global reference → (ref, 0)
  - const-GEP `getelementptr i8, ptr @g, i32 OFF` → (ref, OFF)
  - const-GEP through nested ConstantExpr — recurses

Variable-index GEPs (any GEP index that isn't a ConstantInt) return
`nothing`; the caller (`_handle_memcpy_global_src`) fails loud with a
`Bennett-doih-vargep` breadcrumb. Multi-index GEPs through a `[N x iM]`
ArrayType are flattened: the element index is multiplied by the element
byte width.
"""
function _global_root_and_offset(val::LLVM.Value, depth::Int=0
                                 )::Union{Nothing, Tuple{_LLVMRef, Int}}
    depth > 8 && return nothing
    val.ref == C_NULL && return nothing
    if LLVM.API.LLVMIsAGlobalVariable(val.ref) != C_NULL
        return (val.ref, 0)
    end
    if val isa LLVM.ConstantExpr &&
       LLVM.API.LLVMGetConstOpcode(val.ref) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 2 || return nothing
        base = gep_ops[1]
        # Pointee type of the GEP — accessed via the opaque-ptr GEP
        # source-element-type API. For `getelementptr i8, ptr @g, ...`
        # this is i8 (so per-index stride = 1 byte). For `getelementptr
        # [N x i32], ptr @g, i32 0, i32 K` this is the array type
        # (first index is 0 stepping past the whole array; second
        # index K * 4 bytes).
        srcty = try
            LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(val.ref))
        catch e
            e isa InterruptException && rethrow()
            return nothing
        end
        # Compute byte offset from index operands.
        idx_off = 0
        for i in 2:length(gep_ops)
            iv = gep_ops[i]
            iv isa LLVM.ConstantInt || return nothing  # variable GEP
            ival = Int(LLVM.API.LLVMConstIntGetSExtValue(iv.ref))
            if i == 2
                # First index strides over `srcty`. We accept either:
                # (a) `srcty` is integer iM → stride = M/8 (e.g.
                #     `getelementptr i8, ptr @g, i32 4` → 4 bytes).
                # (b) `srcty` is ArrayType — first index must be 0
                #     (stepping past the whole array doesn't make
                #     sense for a memcpy source). Non-zero outer
                #     index → reject (multi-array GEP exotica).
                if srcty isa LLVM.IntegerType
                    stride = div(LLVM.width(srcty), 8)
                    idx_off += ival * stride
                elseif srcty isa LLVM.ArrayType
                    ival == 0 || return nothing
                else
                    return nothing
                end
            else
                # Second+ index: must be into the inner (array) element.
                if srcty isa LLVM.ArrayType
                    inner = LLVM.eltype(srcty)
                    inner isa LLVM.IntegerType || return nothing
                    stride = div(LLVM.width(inner), 8)
                    idx_off += ival * stride
                else
                    return nothing
                end
            end
        end
        sub = _global_root_and_offset(base, depth + 1)
        sub === nothing && return nothing
        (gref, gbase_off) = sub
        return (gref, gbase_off + idx_off)
    end
    return nothing
end

"""
    _handle_memcpy_global_src(cname, inst, names, counter, ops, globals) -> Vector{IRInst}

Bennett-doih global-src memcpy arm. Pre-conditions verified by
`_handle_memcpy_arm` (predicates 1-4 and 5a). This arm runs G1-G9:

  G1. dst SSA must be in the names table
  G2. dst is NOT a global (defensive — caller's 5a already covers)
  G3. dst traces to an alloca via `_alloca_root_ref` — OR, under the
      closed-world `ptr_cells` gate, to a `julia.gc_alloc_obj` ARENA call via
      `_gc_alloc_root_ref` (Bennett-vbv9; sets `is_arena`), OR to a pointer
      PARAMETER cell via `_param_ptr_root_ref` (Bennett-u2kk; sets `is_param`).
  G4. dst alloca elem_w is a non-zero integer (ALLOCA only; ARENA/PARAM → cell
      width 64, ADR 0018 §A — G4 is SKIPPED)
  G5. src reaches a global; that global is in `globals` dict
  G6. dst_ew == global_ew (no cross-width packing in MVP — for the ARENA/PARAM
      dst this constrains the src global to 64-bit: a non-64-bit global into a
      64-bit cell FAILS LOUD here)
  G7. src byte offset and N are multiples of ew_bytes (cell-aligned for ARENA/PARAM)
  G8. N + src_byte_off ≤ available global bytes
  G9. dst alloca is fresh per `_alloca_is_fresh` (ALLOCA only; ARENA → SKIPPED,
      gc_alloc zero-inits + distinct field offsets, STEP 0c; PARAM → SKIPPED,
      destructive live-field overwrite reversed by BVM's history tape, not by
      freshness — Bennett-u2kk REVERSIBILITY JUSTIFICATION at the G4 branch)

Emission shape (mirror of Bennett-9nwt case C; IDENTICAL for ALLOCA/ARENA/PARAM):
K element-granular `IRPtrOffset + IRStore(iconst, dst_ew)` pairs where each
iconst is the k-th element of the global at the requested byte offset,
K = N / ew_bytes. For the ARENA/PARAM dst, dst_ew=64 ⇒ K=N/8 cell-granular stores.
"""
function _handle_memcpy_global_src(cname::AbstractString, inst::LLVM.Instruction,
                                   names::Dict{_LLVMRef, Symbol},
                                   counter::Ref{Int}, ops,
                                   globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}};
                                   synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}=
                                       Set{Tuple{Symbol, Int, Int}}(),
                                   synth_ptr_allocas::Set{_LLVMRef}=Set{_LLVMRef}(),
                                   ptr_cells::Bool=false)
    dst_v = ops[1]
    src_v = ops[2]
    n_v   = ops[3]
    N = _const_int_as_int(n_v)  # already validated to be ConstantInt>=0 by caller

    # G1: dst SSA must be in the names table.
    haskey(names, dst_v.ref) || _ir_error(inst,
        "$(cname): memcpy dst pointer is not a named SSA value. " *
        "(Bennett-doih)")

    # G2: dst not a global (defensive — caller's 5a already rejected).
    LLVM.API.LLVMIsAGlobalVariable(dst_v.ref) == C_NULL || _ir_error(inst,
        "$(cname): internal — dst is a global but caller's 5a should " *
        "have rejected it already. (Bennett-doih internal invariant)")

    # G3: dst must trace to an alloca (direct or const-GEP) — OR, under the
    # closed-world `ptr_cells` gate (Bennett-vbv9), to a `julia.gc_alloc_obj`
    # ARENA allocation (the Julia typed-GC bump cell — BennettVM ADR 0021 D3).
    # The arena root is consulted ONLY under ptr_cells: on the circuit path a
    # non-alloca dst stays FAIL-LOUD with the UNCHANGED doih message (byte-
    # identical to pre-vbv9), because the circuit model has no gc_alloc cell.
    dst_root = _alloca_root_ref(dst_v)
    arena_root = (dst_root === nothing && ptr_cells) ?
        _gc_alloc_root_ref(dst_v) : nothing
    # Bennett-u2kk (2026-06): the THIRD G3 root — a const-offset GEP off a
    # function POINTER PARAMETER cell (the Dict struct-by-ref param `h::Dict`).
    # Consulted ONLY when both alloca and arena roots miss, and ONLY under
    # ptr_cells (the BVM cell model — see the reversibility note at G4).
    param_root = (dst_root === nothing && arena_root === nothing && ptr_cells) ?
        _param_ptr_root_ref(dst_v) : nothing
    if dst_root === nothing && arena_root === nothing && param_root === nothing
        _ir_error(inst,
            "$(cname): memcpy dst operand is not alloca-backed (or " *
            "alloca-backed via a const-offset GEP) on the global-src path. " *
            "Pointer phi/select/parameter dst not handled. Tracked in " *
            "Bennett-8bys. (Bennett-doih)")
    end
    is_arena = arena_root !== nothing
    is_param = param_root !== nothing

    # G4: dst element width. ARENA dst → fixed cell width 64 (ADR 0018 §A: a
    # gc_alloc'd cell is one Int64 VM cell). The arena branch SKIPS the
    # alloca-specific `_alloca_elem_width_bits` probe (there is no
    # LLVMGetAllocatedType for a call result) and the G9 freshness check below
    # (gc_alloc zero-inits the object and the 5 fdict field-init memcpys hit
    # DISTINCT, non-overlapping byte offsets — empirically verified
    # Bennett-vbv9 STEP 0c — so no destructive overwrite is possible; a precise
    # freshness guard for the general arena case is deferred to a follow-up
    # bead). ALLOCA dst → unchanged G4/G9 path below.
    #
    # PARAM dst (Bennett-u2kk) → ALSO fixed cell width 64 (ADR 0018 §A: a
    # caller-supplied pointer-param cell is one Int64 VM cell), and ALSO SKIPS
    # the alloca-specific `_alloca_elem_width_bits` probe (no
    # LLVMGetAllocatedType for an Argument) and the G9 freshness gate. But the
    # reasoning is DIFFERENT and worth pinning, because the freshness skip is
    # NOT vbv9's STEP-0c "fresh dst" argument:
    #
    #   *** REVERSIBILITY JUSTIFICATION (the crux) ***
    #   The param-field write is a DESTRUCTIVE OVERWRITE of a LIVE field — the
    #   caller's Dict already holds a value at `idxfloor`/`ndel`/`maxprobe`, so
    #   the dst is NOT fresh and vbv9's freshness argument does NOT apply (do
    #   NOT claim it). It is nevertheless reversible UNDER ptr_cells because the
    #   BVM (`target=:reversible_vm`) logs every cell store on its Bennett-1973
    #   history tape `(cell, pre-image)` and undoes it on reversal. Freshness is
    #   a CIRCUIT-MODEL artifact (the circuit path has no tape, so it cannot
    #   reverse a destructive overwrite) — which is exactly why G9 is skipped
    #   here AND why the `ptr_cells=false` circuit path KEEPS failing loud at the
    #   G3 "not alloca-backed" wall above (param_root is ptr_cells-gated). This
    #   memcpy lowers to the IDENTICAL `IRPtrOffset + IRStore` shape that the
    #   proven plain `IRStore`-into-param-field path (setindex! field stores)
    #   already produces under ptr_cells with NO freshness guard — it adds ZERO
    #   new reversibility surface over what already works.
    if is_arena || is_param
        dst_ew = 64
    else
        # G4: dst alloca must have a non-zero integer element width.
        dst_ew = _alloca_elem_width_bits(dst_root)
        dst_ew == 0 && _ir_error(inst,
            "$(cname): memcpy dst alloca has non-integer element type " *
            "(dst_ew=0 indicates struct, ptr, nested-array, or non-integer " *
            "ArrayType inner). Tracked in Bennett-8bys. (Bennett-doih)")
    end

    # G5: src reaches a global, and the global is in the globals dict.
    src_unpacked = _global_root_and_offset(src_v)
    src_unpacked === nothing && _ir_error(inst,
        "$(cname): memcpy src reaches a global via a variable-index " *
        "GEP (runtime indexing) or an exotic GEP shape. doih MVP " *
        "supports only direct globals and const-byte-offset GEPs of " *
        "globals. Tracked in Bennett-doih-vargep follow-up " *
        "(Bennett-ui4f). (Bennett-doih)")
    (src_gref, src_byte_off) = src_unpacked
    src_byte_off >= 0 || _ir_error(inst,
        "$(cname): memcpy src const-GEP yields a negative byte offset " *
        "($src_byte_off) — out-of-bounds read on the global. (Bennett-doih)")
    gname = Symbol(LLVM.name(LLVM.Value(src_gref)))
    haskey(globals, gname) || _ir_error(inst,
        "$(cname): memcpy src global @$gname is not extractable as a " *
        "constant integer byte stream. Likely causes: (a) the " *
        "initializer is a ConstantStruct with a non-materialisable " *
        "field — Bennett-zxhg-ptrfield covers the FloatType / " *
        "VectorType / opaque / IntegerType-wider-than-64 residuals; " *
        "ptr-typed fields now materialise as synthetic 64-bit " *
        "compile-time addresses (Bennett-land), so a ptr field per " *
        "se no longer hits this branch — but the new " *
        "Bennett-land-ptrload escape guard fails loud downstream if " *
        "any loaded byte traces back to such synthetic-address bytes. " *
        "Bennett-land also still rejects ptr fields with non-zero " *
        "addrspace (Bennett-land-addrspace), inttoptr-of-const " *
        "operands (Bennett-land-inttoptr), and undef/unresolvable " *
        "ptr identity. (b) the global is an external declaration " *
        "with no initializer — tracked in Bennett-doih-external " *
        "(covered by Bennett-zxhg); (c) the initializer is an opaque " *
        "kind (GlobalAlias, ConstantVector, etc.) — tracked in " *
        "Bennett-doih-opaque (covered by Bennett-zxhg). Check " *
        "`parsed.globals` to see what was extracted. (Bennett-doih)")
    (gdata, gw) = globals[gname]

    # G6: same-width invariant. Cross-width packing deferred to
    # Bennett-doih-wide.
    dst_ew == gw || _ir_error(inst,
        "$(cname): memcpy cross-width src/dst (global @$gname is " *
        "[N x i$gw], dst alloca is i$dst_ew). doih MVP requires " *
        "matching element widths; byte-packing wider globals into " *
        "narrower dst (or vice versa) is deferred to " *
        "Bennett-doih-wide (Bennett-epfe). (Bennett-doih)")

    # G7: byte-offset and N must be multiples of ew_bytes.
    ew_bytes = div(dst_ew, 8)
    ew_bytes >= 1 || _ir_error(inst,
        "$(cname): internal — dst_ew=$dst_ew bits gives ew_bytes=0. " *
        "(Bennett-doih internal invariant)")
    rem(src_byte_off, ew_bytes) == 0 || _ir_error(inst,
        "$(cname): memcpy src const-GEP byte offset $src_byte_off is " *
        "not a multiple of element size $ew_bytes bytes — sub-element " *
        "alignment not supported. Tracked in Bennett-doih-wide " *
        "(Bennett-epfe). (Bennett-doih)")
    rem(N, ew_bytes) == 0 || _ir_error(inst,
        "$(cname): memcpy N=$N bytes is not a multiple of element " *
        "size $ew_bytes bytes — byte-granular tail copy on the " *
        "global-src path is out of scope. Tracked in " *
        "Bennett-doih-wide (Bennett-epfe). (Bennett-doih)")

    # G8: N + src_byte_off must fit within the global's bytes.
    avail_bytes = length(gdata) * ew_bytes
    src_byte_off + N <= avail_bytes || _ir_error(inst,
        "$(cname): memcpy reads $N bytes starting at offset $src_byte_off " *
        "from global @$gname which has only $avail_bytes available " *
        "bytes ($(length(gdata)) elements × $ew_bytes bytes). " *
        "Out-of-bounds read. (Bennett-doih)")

    # G9: dst alloca must be fresh (no prior IR-visible writes within
    # the same basic block). Reuses the Bennett-9nwt helper. SKIPPED for the
    # arena dst (Bennett-vbv9): gc_alloc zero-inits the object and the fdict
    # field-init memcpys hit distinct, non-overlapping byte offsets (STEP 0c),
    # so no destructive overwrite is possible; `_alloca_is_fresh` is also
    # alloca-specific (it walks back to an alloca root, which an arena dst
    # lacks). A precise arena-freshness guard is deferred to a follow-up bead.
    # SKIPPED for the PARAM dst too (Bennett-u2kk): the write IS a destructive
    # overwrite of a live field, but it is reversed by BVM's history tape, not
    # by a freshness precondition (see the REVERSIBILITY JUSTIFICATION at G4);
    # and `_alloca_is_fresh` is alloca-specific (it walks to an alloca root,
    # which a param dst lacks).
    if !is_arena && !is_param
        _alloca_is_fresh(dst_root, inst) || _ir_error(inst,
            "$(cname): memcpy dst alloca has prior IR-visible writes within " *
            "this basic block (non-fresh dst) on the global-src path. " *
            "Reversibility forbids destructive overwrite without first " *
            "uncomputing the existing slot bits. Tracked in " *
            "Bennett-8bys-uncompute. (Bennett-doih)")
    end

    # ---- Bennett-land: tag dst alloca if any synth-ptr provenance ----
    # If the source global has any synth_ptr_provenance entries, mark
    # the dst alloca as "carries synthetic-address bytes" so the
    # downstream load-escape guard at `_handle_load` can fail loud
    # (`Bennett-land-ptrload`) when those bytes are read back as a
    # pointer/integer for arithmetic, comparison, or dereference. The
    # MVP guard is alloca-level coarse (any load from this alloca that
    # isn't piped into another memcpy fails loud); byte-precise overlap
    # analysis is tracked in `Bennett-land-precise-escape`. SKIPPED for the
    # arena dst (Bennett-vbv9): the synth-ptr-alloca set keys on alloca refs;
    # arena bytes are tracked under the BennettVM cell model, not this set.
    # SKIPPED/REJECTED for the PARAM dst (Bennett-u2kk): the `synth_ptr_allocas`
    # set keys on ALLOCA refs, so it CANNOT track a param-cell field. Rather than
    # silently drop the load-escape guard (which would let synthetic-address
    # bytes flow into a param cell undetected), FAIL LOUD — conservative per
    # Rule 1. (`_j_const#N` are plain integers, so rehash! never trips this; but
    # the guard must not be silently weakened.)
    if is_param
        any(p -> p[1] === gname, synth_ptr_provenance) && _ir_error(inst,
            "$(cname): synth-address bytes (from global @$gname) into a " *
            "param-cell field cannot be tracked by the alloca-keyed land " *
            "guard (synth_ptr_allocas keys on alloca refs, not param cells). " *
            "Tracked in Bennett-land-param / 8bys follow-up. (Bennett-u2kk)")
    elseif !is_arena && any(p -> p[1] === gname, synth_ptr_provenance)
        push!(synth_ptr_allocas, dst_root)
    end

    # ---- Emission: K element-granular IRPtrOffset + IRStore(iconst) ----
    # K = N / ew_bytes; each iconst is the source element at index
    # (src_byte_off / ew_bytes + k). Cast UInt64 → Int via reinterpret
    # to preserve the bit pattern for high-bit-set values (e.g. signed
    # i64 negative constants stored unsigned in the globals dict).
    dst_op = ssa(names[dst_v.ref])
    K = div(N, ew_bytes)
    src_elem_off = div(src_byte_off, ew_bytes)
    out = IRInst[]
    sizehint!(out, 2 * K)
    for k in 0:(K - 1)
        dst_off = _auto_name(counter)
        word = gdata[src_elem_off + k + 1]  # 1-based indexing
        # Cast to signed Int via reinterpret (preserves bit pattern).
        ival = reinterpret(Int64, word) % Int
        push!(out, IRPtrOffset(dst_off, dst_op, k * ew_bytes, dst_ew))
        push!(out, IRStore(ssa(dst_off), iconst(ival), dst_ew))
    end
    return out
end

# ---- Bennett-9nwt (Bennett-hao Phase 2) memset helpers ----

"""
    _alloca_is_fresh(alloca_ref, memset_inst) -> Bool

Conservative intra-block freshness check (Bennett-9nwt, option γ).
Returns `true` iff, walking forward through the basic block from the
alloca instruction to (but not including) `memset_inst`, no intervening
instruction writes through a pointer that traces back to `alloca_ref`.

Returns `false` (conservative non-fresh) when:
  - `alloca_ref` is in a different basic block from `memset_inst`
    (cross-block freshness needs dominance analysis we don't have)
  - any `Store` between alloca and memset has a pointer operand whose
    `_alloca_root_ref` chain reaches `alloca_ref`
  - any `Store` whose pointer operand has no resolvable alloca root
    (pointer phi/select/parameter — we can't prove non-aliasing, so
    treat as a possible write to `alloca_ref`)
  - any `Call` to `llvm.memcpy.*` / `llvm.memset.*` / `llvm.memmove.*`
    whose dst arg traces back to `alloca_ref`
  - any `Call` to a non-benign function with `alloca_ref`'s pointer
    (or a GEP thereof) appearing in any argument position

This is the predicate-12 gate for the c≠0 path in
`_handle_memset_arm`. The c==0 path takes a separate fast-track that
preserves pre-9nwt benign-allowlist behaviour for unaudited Julia
frontend code paths (acknowledged §1 hazard for c=0 non-fresh; tracked
under Bennett-8bys-uncompute).
"""
function _alloca_is_fresh(alloca_ref::_LLVMRef, memset_inst::LLVM.Instruction)::Bool
    alloca_inst = LLVM.Instruction(alloca_ref)
    LLVM.parent(alloca_inst) === LLVM.parent(memset_inst) || return false

    seen_alloca = false
    for inst in LLVM.instructions(LLVM.parent(memset_inst))
        if !seen_alloca
            inst === alloca_inst && (seen_alloca = true)
            continue
        end
        inst === memset_inst && return true
        opc = LLVM.opcode(inst)

        if opc == LLVM.API.LLVMStore
            ptr_v = LLVM.operands(inst)[2]
            root = _alloca_root_ref(ptr_v)
            root === nothing && return false      # opaque ptr — assume aliases
            root === alloca_ref && return false   # writes our slot
            continue
        end

        if opc == LLVM.API.LLVMCall
            call_ops = LLVM.operands(inst)
            n_call_ops = length(call_ops)
            n_call_ops >= 1 || continue
            cname = try LLVM.name(call_ops[n_call_ops]) catch; "" end
            if startswith(cname, "llvm.memcpy.") ||
               startswith(cname, "llvm.memset.") ||
               startswith(cname, "llvm.memmove.")
                root = _alloca_root_ref(call_ops[1])
                root === alloca_ref && return false
                continue
            end
            # Pure / annotation intrinsics with no memory effect: skip.
            if startswith(cname, "llvm.lifetime.") ||
               startswith(cname, "llvm.dbg.") ||
               startswith(cname, "llvm.assume") ||
               startswith(cname, "llvm.experimental.noalias.scope.decl") ||
               startswith(cname, "llvm.invariant.")
                continue
            end
            # Unknown call: if any arg traces to our alloca, conservatively reject.
            for i in 1:(n_call_ops - 1)
                root = _alloca_root_ref(call_ops[i])
                root === alloca_ref && return false
            end
            continue
        end
        # Loads, GEPs, arithmetic, casts: pure with respect to memory writes.
    end
    return false
end

"""
    _broadcast_byte_to_width(c::Int, ew::Int) -> Int

Bennett-ixiz: replicate the low 8 bits of `c` across `ew` bits, so an
ew-bit IRStore with the returned constant has the same byte-wise effect
as `memset(_, c, ew/8, _)`. E.g. `_broadcast_byte_to_width(0xAB, 64)
→ 0xABABABABABABABAB` packed into an Int.

`ew` must be a power-of-2 multiple of 8 (8/16/32/64). The returned Int
holds the low `ew` bits; for `ew == 64` the result may be negative
when the high bit is set (e.g. c=0xAB gives 0xABABABABABABABAB which is
-0x5454545454545455 as a signed Int64 — that is the correct in-memory
bit pattern and round-trips via simulate).
"""
function _broadcast_byte_to_width(c::Int, ew::Int)::Int
    c_u8 = UInt8(c & 0xff)
    out = UInt64(0)
    for k in 0:(div(ew, 8) - 1)
        out |= UInt64(c_u8) << (k * 8)
    end
    if ew >= 64
        return reinterpret(Int64, out) % Int
    end
    return Int(out & ((UInt64(1) << ew) - UInt64(1)))
end

"""
    _handle_memset_arm(cname, inst, names, counter, ops) -> Vector{IRInst}

Bennett-9nwt Phase 2: const-c const-N memset on alloca-i8-backed
destination. Two green cases:

  - Case A (c == 0, any dst): silent drop (`IRInst[]`). Preserves
    pre-9nwt benign-allowlist behaviour for Julia GC-frame zeroing
    patterns. NO alloca/freshness check on this path; tightening would
    risk regressing unaudited Julia frontend output. Acknowledged §1
    hazard for c=0 on non-fresh dst — tracked under
    Bennett-8bys-uncompute. Also covers *volatile* c=0 memsets
    (Bennett-8su4): Julia's heap-allocating frontend zero-inits the GC
    frame with a volatile c=0 memset, which drops here as a no-op.

  - Case C (c != 0, fresh alloca-i8 dst): emit N byte-granular
    `IRPtrOffset + IRStore(ConstOperand(c), 8)` pairs.

All other shapes fail loud naming Bennett-8bys (catch-all) or
Bennett-8bys-uncompute (non-fresh dst with c≠0).

Predicate cascade (earliest mismatch → most actionable error):

  1. addrspace 0 — `llvm.memset.p0.*` or `llvm.memset.inline.p0.*`
  2. operand count >= 5 (4 args + callee)
  3. isvolatile (4th op) is a ConstantInt (malformed-IR guard)
  4. fill byte c (2nd op) is ConstantInt
  5. byte count N (3rd op) is ConstantInt
  6. N >= 0
  7. N == 0 → return `IRInst[]` (LangRef no-op)
  8. c == 0 → return `IRInst[]` (case A — preserve broad tolerance)
  8b. isvolatile value == 0 (volatile c!=0 rejected; volatile c=0
      already dropped at step 8 — Bennett-8su4)
  9. dst is named SSA in `names`
 10. dst is not a global variable
 11. dst alloca-rooted via `_alloca_root_ref`
 12. alloca elem_w == 8
 13. dst alloca is fresh per `_alloca_is_fresh` (option γ)
"""
function _handle_memset_arm(cname::AbstractString, inst::LLVM.Instruction,
                            names::Dict{_LLVMRef, Symbol}, counter::Ref{Int}, ops,
                            dest::Symbol, ptr_cells::Bool=false)
    # Predicate 1: addrspace 0 (accept both `memset.p0.` and `memset.inline.p0.`).
    is_p0 = startswith(cname, "llvm.memset.p0.") ||
            startswith(cname, "llvm.memset.inline.p0.")
    is_p0 || _ir_error(inst,
        "$(cname): memset with non-default pointer address space is not " *
        "supported. Bennett.jl's wire model is single-address-space; " *
        "cross-space writes need explicit lowering. Tracked in " *
        "Bennett-8bys. (Bennett-9nwt Phase 2 — addrspace 0 only)")

    n_ops = length(ops)
    n_ops >= 5 || _ir_error(inst,
        "$(cname): malformed memset call (expected 4 args + callee, got " *
        "$(n_ops - 1) args). (Bennett-9nwt Phase 2)")

    dst_v = ops[1]
    c_v   = ops[2]
    n_v   = ops[3]
    vol_v = ops[4]

    # Predicate 3: isvolatile must be a ConstantInt (malformed-IR guard).
    # The volatile *value* check is relocated below, after the c==0/N==0
    # drop (Bennett-8su4) — but this constant-shape guard must stay early:
    # it fails loud on malformed IR (§1) and must dominate the relocated
    # `_const_int_as_int(vol_v)` call.
    vol_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): isvolatile arg is not an i1 immarg constant " *
        "(value=$(string(vol_v))). LangRef requires an immarg here; " *
        "malformed IR. (Bennett-9nwt Phase 2)")

    # Predicate 4: fill byte must be a ConstantInt.
    c_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): memset with non-constant fill byte is not supported. " *
        "Variable c needs runtime broadcasting that the byte-granular " *
        "IRStore-of-ConstOperand path cannot express. Tracked in " *
        "Bennett-8bys. (Bennett-9nwt Phase 2 — const-c only)")

    # Predicate 5: byte count must be a ConstantInt.
    if !(n_v isa LLVM.ConstantInt)
        # Bennett-8bys / CW-D (ADR 0017): under ptr_cells, a VARIABLE-size memset
        # routes to IRCall(:memset,[dst,byte,nbytes]) → BVM's reversible
        # IntrinsicMemset (ingest_call.jl :memset→IntrinsicMemset, :memset ∈
        # _HEAP_DISPATCH; its L2 delta reverses fresh-absent OR stale, so no
        # freshness proof is needed here). The byte is passed RAW — BVM's
        # IntrinsicMemset.forward does its own cell-broadcast; pre-broadcasting
        # here would double-broadcast. A VOLATILE variable-N memset still fails
        # loud (Rule 1). Const-N keeps the unroll; ptr_cells=false keeps the
        # reject — both byte-identical. `vol_v` is proven ConstantInt at
        # predicate 3 above, so `_const_int_as_int(vol_v)` is safe.
        if ptr_cells && _const_int_as_int(vol_v) == 0
            dst_op = _operand(dst_v, names; ptr_cells=true)   # .data ptr → Int64 cell
            dst_op isa SSAOperand || _ir_error(inst,
                "$(cname): variable-size memset dst is not an SSA pointer cell " *
                "(got $(dst_op)); BVM IntrinsicMemset needs an SSA dst. (Bennett-8bys)")
            return IRCall(dest, :memset,
                IROperand[dst_op, _operand(c_v, names), _operand(n_v, names)],
                Int[64, 8, 64], 64)
        end
        _ir_error(inst,
            "$(cname): memset with non-constant byte count is not supported. " *
            "Variable-size memset requires runtime-bounded loop unrolling, " *
            "same gap as variable-size memcpy. Tracked in Bennett-8bys. " *
            "(Bennett-9nwt Phase 2 — const-N only)")
    end
    N = _const_int_as_int(n_v)
    N >= 0 || _ir_error(inst,
        "$(cname): negative byte count $N (corrupt IR; LLVM treats the " *
        "size argument as unsigned i64 but the C API returns Int64). " *
        "(Bennett-9nwt Phase 2)")

    # Predicate 7: N == 0 is a legal no-op regardless of c, dst, freshness.
    N == 0 && return IRInst[]

    # Predicate 8: c == 0 → case A. Silent drop, preserves pre-9nwt benign
    # behaviour. Intentionally NO alloca / freshness check here —
    # tightening risks regressing unaudited Julia frontend output, and the
    # benign-list it replaces also did no such check. The c=0 non-fresh
    # silent miscompile is an acknowledged hazard tracked in
    # Bennett-8bys-uncompute.
    c_int = _const_int_as_int(c_v) & 0xFF
    c_int == 0 && return IRInst[]

    # Predicate 8b: volatile value check (relocated here from before
    # predicate 4 — Bennett-8su4). A c==0 or N==0 memset is already
    # dropped above (predicates 7/8) and emits zero IRInsts regardless of
    # volatility, so volatility is moot for it — this lets Julia's
    # volatile c=0 GC-frame zero-init memset through. Control only
    # reaches here when c!=0, so volatile c!=0 still fails loud.
    _const_int_as_int(vol_v) == 0 || _ir_error(inst,
        "$(cname): volatile memset is not supported. Bennett.jl's " *
        "reversible model has no observable side-effect ordering for " *
        "memory; volatile semantics cannot be honoured. Recompile " *
        "without the volatile attribute, or wait on Bennett-8bys " *
        "(catch-all). (Bennett-9nwt Phase 2)")

    # ---- c != 0 path: requires alloca-i8-backed fresh dst ----

    # Predicate 9: dst SSA must be in the names table.
    haskey(names, dst_v.ref) || _ir_error(inst,
        "$(cname): memset dst pointer is not a named SSA value. " *
        "(Bennett-9nwt Phase 2)")

    # Predicate 10: globals out of scope.
    if LLVM.API.LLVMIsAGlobalVariable(dst_v.ref) != C_NULL
        _ir_error(inst,
            "$(cname): memset of a global-variable destination is not " *
            "yet supported. Constant-target memset against a global " *
            "would mutate read-only data. Tracked in Bennett-8bys " *
            "(catch-all, sub-case: \"Global-pointer memset\"). " *
            "(Bennett-9nwt Phase 2 — alloca-backed dst only)")
    end

    # Predicate 11: dst must trace to an alloca (direct or const-offset GEP).
    dst_root = _alloca_root_ref(dst_v)
    dst_root === nothing && _ir_error(inst,
        "$(cname): memset dst operand is not alloca-backed (or " *
        "alloca-backed via a const-offset GEP). Bennett's pointer- " *
        "provenance model only covers alloca and GEP-of-alloca; pointer " *
        "phi/select/parameter sources fan out to multiple origins which " *
        "Bennett-9nwt does not yet handle. Tracked in Bennett-8bys. " *
        "(Bennett-9nwt Phase 2)")

    # Predicate 12: alloca element type must be integer.
    # Bennett-ixiz (2026-05-16) lifted the prior `dst_ew == 8` gate;
    # arbitrary integer element widths are now accepted, with the fill
    # byte c broadcast across the element width (see _broadcast_byte_to_width).
    dst_ew = _alloca_elem_width_bits(dst_root)
    dst_ew == 0 && _ir_error(inst,
        "$(cname): memset dst alloca has non-integer element type " *
        "(struct, ptr, nested-array, or non-integer ArrayType inner). " *
        "Bennett's wire model only supports flat integer-typed allocas. " *
        "Tracked in Bennett-8bys. (Bennett-9nwt / Bennett-ixiz)")

    # Predicate 12b (Bennett-ixiz): N must be a whole multiple of element-
    # size bytes. Byte-granular tail set (setting partial element bytes)
    # is out-of-scope.
    rem(N * 8, dst_ew) == 0 || _ir_error(inst,
        "$(cname): memset N=$N bytes is not a multiple of element size " *
        "$(div(dst_ew, 8)) bytes — byte-granular tail set is out-of-scope " *
        "for Bennett-ixiz. Tracked in Bennett-8bys.")

    # Predicate 13: freshness (intra-block sweep). Non-fresh dst would
    # XOR-overlay c onto existing data instead of cleanly setting it,
    # producing wrong results that `verify_reversibility` doesn't catch.
    _alloca_is_fresh(dst_root, inst) || _ir_error(inst,
        "$(cname): memset dst alloca has prior IR-visible writes within " *
        "this basic block (non-fresh dst). Reversibility forbids " *
        "destructive overwrite without first uncomputing the existing " *
        "slot bits via CNOT-uncompute. Tracked in " *
        "Bennett-8bys-uncompute. (Bennett-9nwt Phase 2 — fresh-dst only)")

    # Case C expansion (Bennett-ixiz): K element-granular IRPtrOffset+IRStore
    # pairs at width = dst_ew, where K = N / ew_bytes. The byte fill c is
    # broadcast across the full element width (e.g. c=0xAB → 0xABABABABABABABAB
    # for ew=64) via _broadcast_byte_to_width.
    ew_bytes = div(dst_ew, 8)
    K = div(N, ew_bytes)
    c_broadcast = _broadcast_byte_to_width(c_int, dst_ew)
    dst_op = ssa(names[dst_v.ref])
    out = IRInst[]
    sizehint!(out, 2 * K)
    for k in 0:(K - 1)
        dst_off = _auto_name(counter)
        push!(out, IRPtrOffset(dst_off, dst_op, k * ew_bytes, dst_ew))
        push!(out, IRStore(ssa(dst_off), iconst(c_broadcast), dst_ew))
    end
    return out
end

# Bennett-tzrs / U41 (first-cut, 2026-04-27): the LLVM-intrinsic prefix
# dispatch was lifted out of `_convert_instruction`'s 836-line body into
# this helper. Order of `if startswith(cname, "...")` branches is LOAD-
# BEARING — `llvm.minnum` / `llvm.minimum` and `llvm.maxnum` / `llvm.maximum`
# share handlers via prefix-match, and the floor/ceil/trunc/rint
# branch is INTENTIONALLY a no-op (it lets the registered-callee path in
# `_convert_instruction` pick up `soft_floor` / `soft_ceil` / etc. via
# the SoftFloat dispatch). `llvm.round.` and `llvm.roundeven.` have
# explicit dispatch arms (Bennett-mq6f) because they semantically
# diverge — `llvm.round` is round-half-AWAY (`soft_round_away`) while
# `llvm.roundeven` is banker's (`soft_round`). Returns `nothing` if no intrinsic matched —
# the call site then proceeds to the registered-callee lookup and the
# benign-allowlist guard. Per CLAUDE.md §2 this is part of the 3+1-mandated
# tzrs refactor (proposers: A and B; orchestrator: tobias 2026-04-27).
function _handle_intrinsic(cname::AbstractString, inst::LLVM.Instruction,
                           names::Dict{_LLVMRef, Symbol}, counter::Ref{Int},
                           dest::Symbol, ops,
                           globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}=
                               Dict{Symbol, Tuple{Vector{UInt64}, Int}}();
                           synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}=
                               Set{Tuple{Symbol, Int, Int}}(),
                           synth_ptr_allocas::Set{_LLVMRef}=Set{_LLVMRef}(),
                           ptr_cells::Bool=false)
    if startswith(cname, "llvm.umax.")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :uge, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.umin.")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :ule, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.smax.")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :sge, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.smin.")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :sle, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    # llvm.abs.iN(x, is_int_min_poison) = x >= 0 ? x : 0 - x
    if startswith(cname, "llvm.abs.")
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
    if startswith(cname, "llvm.ctpop.")
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
    if startswith(cname, "llvm.ctlz.")
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
    if startswith(cname, "llvm.cttz.")
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
    if startswith(cname, "llvm.bitreverse.")
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
    if startswith(cname, "llvm.bswap.")
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
    if startswith(cname, "llvm.fshl.")
        w = _iwidth(ops[1])
        a_op = _operand(ops[1], names)
        b_op = _operand(ops[2], names)
        sh_op = _operand(ops[3], names)
        shl_dest = _auto_name(counter)
        lshr_dest = _auto_name(counter)
        if sh_op isa ConstOperand
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
    if startswith(cname, "llvm.fshr.")
        w = _iwidth(ops[1])
        a_op = _operand(ops[1], names)
        b_op = _operand(ops[2], names)
        sh_op = _operand(ops[3], names)
        shl_dest = _auto_name(counter)
        lshr_dest = _auto_name(counter)
        if sh_op isa ConstOperand
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
    if startswith(cname, "llvm.fabs.")
        w = _iwidth(ops[1])
        mask = w == 64 ? typemax(Int64) : Int((1 << (w - 1)) - 1)
        return IRBinOp(dest, :and, _operand(ops[1], names), iconst(mask), w)
    end
    # llvm.copysign: (x AND ~sign_bit) OR (y AND sign_bit)
    if startswith(cname, "llvm.copysign.")
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
    # Bennett-mq6f: `llvm.roundeven.f64` is IEEE 754 roundToIntegralTiesToEven
    # (banker's rounding) — bit-exactly equivalent to our `soft_round` (which
    # is also banker's, matching `Base.round(::Float64)` per Bennett-2hhx).
    # Native dispatch closes the kh6n future-work stub.
    #
    # Bennett-kh6n's earlier explicit reject (since removed) incorrectly
    # claimed `soft_round` was round-half-AWAY; in fact `soft_round` IS
    # banker's, and the silent miscompile direction is reversed — see the
    # `llvm.round.` arm below for the actual round-half-AWAY dispatch.
    if startswith(cname, "llvm.roundeven.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.roundeven: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-mq6f)")
        return IRCall(dest, soft_round, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-mq6f: `llvm.round.f64` is IEEE 754 roundToIntegralTiesToAway
    # (round-half-AWAY-from-zero) per LLVM langref — DISTINCT from
    # `llvm.roundeven.f64` (banker's). Pre-Bennett-mq6f this arm fell
    # through to the no-op `floor/ceil/trunc/rint/round` block below and
    # then hit the callee-registry path which (correctly) dispatches
    # `soft_round` for the SoftFloat-typed `Base.round` — but `soft_round`
    # is banker's, so raw `.ll` ingest of `llvm.round.f64` silently
    # miscompiled at every `±N.5` tie. Native dispatch to the new
    # `soft_round_away` primitive closes the gap.
    if startswith(cname, "llvm.round.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.round: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-mq6f)")
        return IRCall(dest, soft_round_away, [_operand(ops[1], names)], [w], w)
    end
    # llvm.floor / llvm.ceil / llvm.trunc / llvm.rint
    # Intentionally NO return: the registered-callee path in
    # `_convert_instruction` picks these up via SoftFloat dispatch
    # (`soft_floor` / `soft_ceil` / `soft_trunc` are registered callees).
    # Falling through to the next `if` keeps the original semantics.
    # Bennett-mq6f: `llvm.round.` and `llvm.roundeven.` are no longer
    # part of this no-op arm — both have explicit dispatch above (with
    # different rounding modes). `llvm.rint.` defaults to round-to-nearest-
    # ties-to-even per IEEE 754; the callee registry serves that via
    # `soft_round` (banker's).
    if startswith(cname, "llvm.floor.") || startswith(cname, "llvm.ceil.") ||
       startswith(cname, "llvm.trunc.") || startswith(cname, "llvm.rint.")
        # No-op: handled by callee registry
    end
    # Bennett-p19b: native dispatch for IEEE 754-2019 minimumNumber /
    # maximumNumber (LLVM 19+ `llvm.minimumnum.*` / `llvm.maximumnum.*`).
    # Semantically NaN-absorbing with the ±0 tie-break SPECIFIED
    # (-0.0 < +0.0 in min, +0.0 > -0.0 in max). Our `soft_fmin` /
    # `soft_fmax` already chose the specified ±0 behavior (matches
    # `Base.min` / `Base.max`), so `soft_minimumnum` / `soft_maximumnum`
    # are aliased thin wrappers over them — see src/softfloat/fmin.jl.
    # Both arms appear BEFORE the shorter `llvm.minimum.` / `llvm.maximum.`
    # arms below (defense in depth: trailing-`.` already prevents the
    # shorter prefix from matching `*num`, but longest-first ordering
    # is robust to future prefix-discipline drift). Closes the third
    # and final Bennett-kh6n future-work stub (after k2w6 + mq6f).
    if startswith(cname, "llvm.minimumnum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.minimumnum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-p19b)")
        return IRCall(dest, soft_minimumnum,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if startswith(cname, "llvm.maximumnum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.maximumnum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-p19b)")
        return IRCall(dest, soft_maximumnum,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    # llvm.minnum / llvm.maxnum / llvm.minimum / llvm.maximum
    # Trailing-`.` discipline (Bennett-kh6n): without it, `llvm.minimum`
    # silently swallows `llvm.minimumnum.*` and `llvm.maximum` swallows
    # `llvm.maximumnum.*` (handled by the explicit Bennett-p19b arms above).
    #
    # Bennett-k2w6: native dispatch for all four float min/max variants.
    # Two semantic pairs:
    #   - llvm.minnum  / llvm.maxnum   ≡ IEEE 754 minNum/maxNum, NaN-absorbing.
    #   - llvm.minimum / llvm.maximum  ≡ IEEE 754-2008 minimum/maximum,
    #                                    NaN-propagating (matches Julia
    #                                    Base.min/max bit-exactly).
    # f32 rejected per CLAUDE.md §13 (Bennett-3rph). The original
    # IRICmp(:slt)/(:sgt) integer-compare path that pre-Bennett-kh6n
    # silently dispatched float operands is removed — it was always wrong
    # for f64 (mishandles +0/-0 and NaN), and llvm.minnum/minimum/maxnum/
    # maximum are float-only intrinsics per LLVM langref so the integer
    # path was pure dead code.
    if startswith(cname, "llvm.minnum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.minnum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-k2w6)")
        return IRCall(dest, soft_fmin,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if startswith(cname, "llvm.maxnum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.maxnum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-k2w6)")
        return IRCall(dest, soft_fmax,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if startswith(cname, "llvm.minimum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.minimum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-k2w6)")
        return IRCall(dest, soft_fminimum,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if startswith(cname, "llvm.maximum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.maximum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-k2w6)")
        return IRCall(dest, soft_fmaximum,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    # Bennett-1pb: direct dispatch for transcendental intrinsics. The Julia
    # frontend normally routes these through SoftFloat dispatch
    # (`Base.sqrt(::SoftFloat) = SoftFloat(soft_fsqrt(x.bits))`), so the IR
    # call site is `@j_soft_fsqrt_NNN` rather than `@llvm.sqrt.f64`. But IR
    # can still arrive at the extractor with raw `llvm.sqrt.f64` etc. when
    # the user calls `Core.Intrinsics.sqrt_llvm` directly, uses `@fastmath`
    # on a raw Float64, or — looking ahead to Bennett-xkv — feeds in
    # `.ll`/`.bc` from C/Rust where no SoftFloat wrapper exists. The bit
    # pattern of the f64 operand is treated as a 64-bit wire (LLVM bitcasts
    # adjacent to the call site already turn raw double SSA into integer
    # wires). Width-32/16 forms are rejected per CLAUDE.md §13 (Float32 not
    # bit-exact; native f32 paths tracked in Bennett-e283).
    #
    # `llvm.exp2.*` is checked before `llvm.exp.*` because both share the
    # `llvm.exp` prefix; the order is load-bearing.
    if startswith(cname, "llvm.sqrt.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.sqrt: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-1pb)")
        return IRCall(dest, soft_fsqrt, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.exp2.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.exp2: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-1pb)")
        return IRCall(dest, soft_exp2, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-h6f: fused multiply-add. `soft_fma` is a bit-exact IEEE 754
    # binary64 FMA (single rounding via 106-bit intermediate product;
    # Bennett-0xx3, 2026-04-16). `llvm.fmuladd` is allowed by LangRef to
    # be split into fmul+fadd by the lowerer, but Bennett deliberately
    # routes both `fma` and `fmuladd` to `soft_fma` — the alternative
    # would mean fmuladd produces a different last-ulp answer than fma
    # on the same inputs, which is a class of "silent disagreement" bug
    # CLAUDE.md §1 (fail loud) + §13 (bit-exact f64) explicitly avoid.
    if startswith(cname, "llvm.fma.") || startswith(cname, "llvm.fmuladd.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.fma/fmuladd: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-h6f)")
        return IRCall(dest, soft_fma,
                      [_operand(ops[1], names),
                       _operand(ops[2], names),
                       _operand(ops[3], names)],
                      [w, w, w], w)
    end
    # Trailing `.` per Bennett-7goc / 0ulc discipline: prevents
    # `startswith("llvm.exp")` from silently swallowing
    # `llvm.expm1.f64` (which is dispatched in a separate arm
    # below at the C2 transcendental section per Bennett-o7cy).
    if startswith(cname, "llvm.exp.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.exp: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-1pb)")
        return IRCall(dest, soft_exp, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-582: direct dispatch for the LLVM logarithm intrinsic family.
    # Like the exp dispatch above, the Julia frontend normally routes log
    # through SoftFloat (`Base.log(::SoftFloat) = SoftFloat(soft_log_julia(x.bits))`
    # — when wired). Raw `llvm.log.f64` arrives via @fastmath, Core.Intrinsics,
    # or .ll/.bc ingest (Bennett-xkv multi-language path).
    #
    # Order is load-bearing: `llvm.log10.*` and `llvm.log2.*` must be checked
    # BEFORE `llvm.log.*` because `startswith("llvm.log")` matches all three.
    # f64 only — f32 rejected per CLAUDE.md §13 (Bennett-3rph / U137).
    #
    # Trailing `.` discipline (Bennett-7goc): each prefix has a trailing
    # `.` so it doesn't accidentally swallow another intrinsic with a
    # longer name. Pre-Bennett-0ulc the `llvm.log` arm was untightened
    # and silently swallowed `llvm.log1p.f64` — same class of bug as
    # the pre-7goc `llvm.atan` swallowing `llvm.atan2.f64`. Tightened
    # all three log-family prefixes here.
    if startswith(cname, "llvm.log10.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log10: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log10, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.log2.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log2: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log2, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-0ulc: `llvm.log1p.f64` → `soft_log1p`. MUST come before
    # the `llvm.log.` arm because position-9 of `llvm.log1p.f64` is `1`,
    # not `.`. With the trailing-`.` discipline applied to `llvm.log.`,
    # ordering is no longer strictly required — but kept for clarity
    # and to mirror the trig family's discipline.
    if startswith(cname, "llvm.log1p.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log1p: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-0ulc)")
        return IRCall(dest, soft_log1p, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.log.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-emv: direct dispatch for llvm.pow / llvm.powi.
    # `llvm.powi.f64.i32` has a different signature than llvm.pow — base is
    # f64, exponent is i32 — so it routes to soft_powi (binary squaring),
    # not soft_pow. Order is load-bearing again: `llvm.powi.*` checked
    # before `llvm.pow.*` because both share the `llvm.pow` prefix.
    if startswith(cname, "llvm.powi.")
        w_base = _iwidth(ops[1])
        w_exp  = _iwidth(ops[2])
        w_base == 64 || _ir_error(inst,
            "llvm.powi: only f64 base supported (got width=$w_base); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-emv)")
        w_exp == 32 || _ir_error(inst,
            "llvm.powi: only i32 exponent supported (got width=$w_exp); " *
            "Bennett supports the standard `llvm.powi.f64.i32` form. " *
            "(Bennett-emv)")
        return IRCall(dest, soft_powi,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w_base, w_exp], w_base)
    end
    if startswith(cname, "llvm.pow.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.pow: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-emv)")
        return IRCall(dest, soft_pow,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    # Bennett-3mo: direct dispatch for the LLVM trigonometric intrinsics.
    # `soft_sin` / `soft_cos` are full-Payne-Hanek ports of musl `sin.c` /
    # `cos.c` / `__rem_pio2_large.c`, ≤2 ULP vs `Base.sin` / `Base.cos`
    # across the full Float64 input range. f32 rejected per §13.
    # Trailing `.` in the prefix is load-bearing: it prevents
    # `startswith("llvm.sin")` from matching `"llvm.sinh.f64"` (which we
    # don't support yet) and accidentally dispatching to soft_sin.
    # Same fix applied to cos/tan/atan/asin/acos below — see Bennett-7goc
    # for the silent-miscompile root cause (`startswith("llvm.atan")`
    # matched `"llvm.atan2.f64"` and dropped the second operand).
    if startswith(cname, "llvm.sin.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.sin: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-3mo)")
        return IRCall(dest, soft_sin, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-hao Phase 1 (Bennett-37mt): const-size memcpy between two
    # distinct alloca-i8-backed pointer ranges lowers to byte-granular
    # IRPtrOffset+IRPtrOffset+IRLoad+IRStore quads. Out-of-scope shapes
    # fall through to a precise fail-loud naming Bennett-8bys (catch-all
    # for byte-granularity / variable-size / overlap / wider-elem-w
    # allocas) or Bennett-haod (deferred sub-bead for global-variable
    # source pointers). memmove ALWAYS fails loud → 8bys (overlap is
    # unreachable in the reversible model regardless of pointer
    # disjointness). The Phase 0 (Bennett-lqif) blanket fail-loud is
    # superseded by this arm.
    #
    # Why byte-granular chunks (rather than the bead's "(N/8) at 64-bit
    # granularity" wording): the existing `lower_ptr_offset!`
    # (src/lowering/aggregate.jl:227) only propagates ptr_provenance for
    # `ew == 8`, and `_lower_store_via_shadow!` requires
    # `inst.width == elem_w`. The single-Phase-1 chunk shape that lands
    # cleanly through the existing memory.jl pipeline is therefore
    # `alloca i8` + width=8 IRLoad/IRStore. Wider-element allocas and
    # 64-bit chunks are deferred to 8bys (which is also where memory.jl
    # itself can grow multi-byte spans). With byte-granular chunks the
    # bead's "N is multiple of 8 bytes" wording becomes moot — any
    # positive N works.
    if startswith(cname, "llvm.memmove.")
        _ir_error(inst,
            "$(cname): memmove is not yet lowered to reversible gates. " *
            "Memmove permits src/dst overlap and reversibility forbids " *
            "destructive in-place overwrite, so static disjointness is " *
            "required and Bennett.jl has no alias analysis to prove it. " *
            "Tracked in Bennett-8bys (Phase 3: byte-granularity / " *
            "variable-size / overlap / memmove). " *
            "(Bennett-37mt Phase 1 — memmove deferred to Bennett-8bys)")
    end
    if startswith(cname, "llvm.memcpy.")
        return _handle_memcpy_arm(cname, inst, names, counter, ops, globals;
                                  synth_ptr_provenance=synth_ptr_provenance,
                                  synth_ptr_allocas=synth_ptr_allocas,
                                  ptr_cells=ptr_cells)
    end
    # Bennett-hao Phase 2 (Bennett-9nwt): const-c const-N memset on
    # alloca-i8-backed dst lowers to byte-granular IRPtrOffset+IRStore
    # pairs with ConstOperand(c) at width=8. c=0 takes a separate
    # silent-drop fast path that preserves pre-9nwt benign behaviour.
    if startswith(cname, "llvm.memset.")
        return _handle_memset_arm(cname, inst, names, counter, ops, dest, ptr_cells)
    end
    if startswith(cname, "llvm.cos.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.cos: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-3mo)")
        return IRCall(dest, soft_cos, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-s1zl: `llvm.tan.f64` → `soft_tan` (musl __tan port reusing
    # the rem_pio2 infrastructure; ≤2 ULP vs `Base.tan` across the full
    # Float64 range). f32 rejected per §13. First close in Tier C1 trig
    # completion (Bennett-Enzyme-Parity-NorthStar.md §C1).
    if startswith(cname, "llvm.tan.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.tan: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-s1zl)")
        return IRCall(dest, soft_tan, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-m2bv: `llvm.tanh.f64` → `soft_tanh` (regime-split port of
    # Julia stdlib `Base.tanh`: degree-10 polynomial in x² for |x| ≤ 0.5,
    # `1 - 2/(exp(2|x|)+1)` for medium |x|, ±1 saturation for |x| ≥ 22.
    # ONE soft_exp_fast call total. ≤2 ULP vs `Base.tanh` across the full
    # Float64 range; subnormal-input preserved bit-exactly via the
    # polynomial branch (CLAUDE.md §13). f32 rejected per §13.
    # Tier C1.6 in the Enzyme parity north-star — first hyperbolic close.
    # MUST come AFTER the `llvm.tan.` arm even though the trailing `.`
    # already prevents `startswith("llvm.tan.")` from matching
    # `"llvm.tanh.f64"` (defence-in-depth against future prefix relaxation).
    if startswith(cname, "llvm.tanh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.tanh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-m2bv)")
        return IRCall(dest, soft_tanh, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-m2bv: libm-style `@tanh(double)` external call — what
    # clang/rustc emit when the math intrinsic is disabled or LLVM <18.
    # Same lowering as the intrinsic form. f32 variant `@tanhf` rejected
    # per §13.
    if cname == "tanh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@tanh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-m2bv)")
        return IRCall(dest, soft_tanh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "tanhf"
        _ir_error(inst,
            "@tanhf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-m2bv)")
    end
    # Bennett-ky5n: `llvm.sinh.f64` → `soft_sinh` (regime-split port
    # adapting Julia stdlib `Base.sinh` to use ONE soft_exp_fast call
    # via the unified exp-form `(0.5·E·E - 0.5/(E·E))` with `E = exp(|x|/2)`,
    # plus a degree-8 polynomial in z=x² for `|x| ≤ 1.0` (Julia stdlib
    # minimax coefficients). ≤2 ULP vs `Base.sinh`; subnormal-input
    # preserved bit-exactly via the polynomial branch (CLAUDE.md §13).
    # f32 rejected per §13. Tier C1.7 — second hyperbolic close after
    # Bennett-m2bv (tanh).
    # Defence-in-depth placement: the trailing `.` on `llvm.sin.` already
    # prevents `startswith("llvm.sinh.f64", "llvm.sin.")` from matching
    # (position 8 is `h`, not `.`), so order between sin and sinh arms
    # is semantically free — placed here to group with hyperbolics.
    if startswith(cname, "llvm.sinh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.sinh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-ky5n)")
        return IRCall(dest, soft_sinh, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-ky5n: libm-style `@sinh(double)` external call — what
    # clang/rustc emit when the math intrinsic is disabled or LLVM <18.
    # Same lowering as the intrinsic form. f32 variant `@sinhf` rejected
    # per §13.
    if cname == "sinh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@sinh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-ky5n)")
        return IRCall(dest, soft_sinh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "sinhf"
        _ir_error(inst,
            "@sinhf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-ky5n)")
    end
    # Bennett-bybh: `llvm.cosh.f64` → `soft_cosh` (regime-split port
    # of Julia stdlib `Base.cosh` — even function, polynomial for
    # |x| ≤ 1.0, `(E + 1/E)/2` for medium (no cancellation), `(0.5·E)·E`
    # for huge. ONE soft_exp_fast call total. ≤2 ULP vs `Base.cosh`;
    # subnormal input → 1.0 exactly. f32 rejected per §13.
    # Tier C1.8 — third hyperbolic close after Bennett-m2bv (tanh) and
    # Bennett-ky5n (sinh).
    # Defence-in-depth placement: trailing `.` on `llvm.cos.` already
    # prevents `startswith("llvm.cos.", "llvm.cosh.f64")` from matching
    # (position 8 is `h`, not `.`). Order between cos/cosh arms is
    # semantically free; placed here to group with other hyperbolics.
    if startswith(cname, "llvm.cosh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.cosh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-bybh)")
        return IRCall(dest, soft_cosh, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-bybh: libm-style `@cosh(double)` external call.
    if cname == "cosh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@cosh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-bybh)")
        return IRCall(dest, soft_cosh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "coshf"
        _ir_error(inst,
            "@coshf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-bybh)")
    end
    # Bennett-sfx9: `llvm.asinh.f64` → `soft_asinh` (regime-split port
    # adapting Julia stdlib `Base.asinh` with `log1p` substituted by an
    # extended polynomial regime since Bennett.jl lacks `soft_log1p`).
    # ≤2 ULP vs `Base.asinh`; subnormal-input bit-exact via the
    # polynomial branch. f32 rejected per §13. Tier C1.9 — fourth
    # hyperbolic close.
    if startswith(cname, "llvm.asinh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.asinh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-sfx9)")
        return IRCall(dest, soft_asinh, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-sfx9: libm-style `@asinh(double)` external call.
    if cname == "asinh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@asinh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-sfx9)")
        return IRCall(dest, soft_asinh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "asinhf"
        _ir_error(inst,
            "@asinhf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-sfx9)")
    end
    # Bennett-eq9p: `llvm.acosh.f64` → `soft_acosh` (regime-split port).
    # Domain-restricted (x < 1 → NaN). polynomial via s²-substitution
    # for x ∈ [1, 1.05]; log-based for medium; log+ln2 for huge.
    # f32 rejected per §13. Tier C1.10 — fifth hyperbolic close.
    if startswith(cname, "llvm.acosh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.acosh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-eq9p)")
        return IRCall(dest, soft_acosh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "acosh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@acosh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-eq9p)")
        return IRCall(dest, soft_acosh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "acoshf"
        _ir_error(inst,
            "@acoshf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-eq9p)")
    end
    # Bennett-g82n: `llvm.atanh.f64` → `soft_atanh`. Domain |x| ≤ 1
    # (|x| > 1 → NaN). atanh is ODD. Three regimes: domain / K=25
    # polynomial / log-formula. ONE soft_log + ONE soft_fdiv.
    # Tier C1.11 — FINAL hyperbolic, completes Tier C1 11/11.
    if startswith(cname, "llvm.atanh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.atanh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-g82n)")
        return IRCall(dest, soft_atanh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "atanh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@atanh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-g82n)")
        return IRCall(dest, soft_atanh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "atanhf"
        _ir_error(inst,
            "@atanhf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-g82n)")
    end
    # Bennett-0ulc: libm `@log1p` external call. The intrinsic
    # `llvm.log1p.f64` arm is up at line 824 (placed beside the
    # `llvm.log` family for the trailing-`.` ordering rationale).
    if cname == "log1p"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@log1p (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-0ulc)")
        return IRCall(dest, soft_log1p, [_operand(ops[1], names)], [w], w)
    end
    if cname == "log1pf"
        _ir_error(inst,
            "@log1pf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-0ulc)")
    end
    # Bennett-o7cy: `llvm.expm1.f64` → `soft_expm1`. Tier C2.2 — second
    # C2 transcendental, symmetric to log1p (Bennett-0ulc). expm1(x) =
    # exp(x) - 1 accurate for small x. Three-regime branchless: tiny
    # (|x|<2^-54) → x; polynomial (|x|≤0.5) K=15 Taylor; medium (|x|>0.5)
    # → exp(x)-1 directly. f32 rejected per §13.
    if startswith(cname, "llvm.expm1.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.expm1: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-o7cy)")
        return IRCall(dest, soft_expm1, [_operand(ops[1], names)], [w], w)
    end
    if cname == "expm1"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@expm1 (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-o7cy)")
        return IRCall(dest, soft_expm1, [_operand(ops[1], names)], [w], w)
    end
    if cname == "expm1f"
        _ir_error(inst,
            "@expm1f (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-o7cy)")
    end
    # Bennett-7goc: `llvm.atan2.f64` → `soft_atan2` (musl atan2.c port
    # built on soft_atan; ≤2 ULP vs `Base.atan(y, x)`). Tier C1.5 in the
    # Enzyme parity north-star. MUST come before the `llvm.atan.` arm:
    # before Bennett-7goc the (untightened) `startswith("llvm.atan")`
    # silently matched `"llvm.atan2.f64"` and dispatched to soft_atan
    # with just the y operand, dropping x and producing wrong results
    # outside the (y>0, x>0) quadrant. f32 rejected per §13.
    if startswith(cname, "llvm.atan2.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.atan2: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-7goc)")
        return IRCall(dest, soft_atan2,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    # Bennett-7goc: libm-style `@atan2(double, double)` external call —
    # what clang/rustc emit for raw .ll/.bc when the math intrinsic is
    # disabled or LLVM <18. Same lowering as the intrinsic form. The f32
    # variant `@atan2f` is rejected per §13.
    if cname == "atan2"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@atan2 (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-7goc)")
        return IRCall(dest, soft_atan2,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if cname == "atan2f"
        _ir_error(inst,
            "@atan2f (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-7goc)")
    end
    # Bennett-qpke: `llvm.atan.f64` → `soft_atan` (musl atan.c branchless
    # port, ≤2 ULP vs `Base.atan` across the full Float64 range). Self-
    # contained — no dependency on `_rp_rem_pio2`. f32 rejected per §13.
    # Tier C1.2 in the Enzyme parity north-star.
    if startswith(cname, "llvm.atan.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.atan: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-qpke)")
        return IRCall(dest, soft_atan, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-ckvj: `llvm.asin.f64` → `soft_asin` (musl asin.c branchless
    # port, ≤2 ULP vs `Base.asin` across [-1, 1]). Shares the rational
    # `_asin_R(z)` helper with `soft_acos` (Bennett-bd7f). f32 rejected
    # per §13. Tier C1.3 in the Enzyme parity north-star.
    if startswith(cname, "llvm.asin.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.asin: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-ckvj)")
        return IRCall(dest, soft_asin, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-bd7f: `llvm.acos.f64` → `soft_acos` (musl acos.c branchless
    # port; reuses `_asin_R(z)` helper from fasin.jl per CLAUDE.md §12).
    # ≤2 ULP vs `Base.acos` across [-1, 1]. f32 rejected per §13.
    # Tier C1.4 in the Enzyme parity north-star.
    if startswith(cname, "llvm.acos.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.acos: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-bd7f)")
        return IRCall(dest, soft_acos, [_operand(ops[1], names)], [w], w)
    end
    return nothing
end

# Bennett-ares — CW-D2 lever 1: VM-relaxable atomic ordering predicate.
#
# Bennett-4mmt / U14 made EVERY atomic load/store fail loud because reversible
# CIRCUIT compilation has no semantics for ordering. That stays correct for the
# circuit path. But under the closed-world / BennettVM cell model (`ptr_cells=
# true`, sole setter module_walk.jl) the consumer is deterministic, single-
# threaded and history-reversible: there is no concurrent observer, so a
# RELAXED-consistency ordering contract is vacuous and the access can fall
# through to the existing IRLoad/IRStore lowering (no new lowering — the guard
# simply stops throwing).
#
# Accepted band (LLVM AtomicOrdering enum):
#   NotAtomic(0), Unordered(1), Monotonic(2), Acquire(4), Release(5).
# STILL fail-loud (even under the gate):
#   AcquireRelease(6), SequentiallyConsistent(7) — a load/store under one of
#   these is asking for a synchronisation edge the VM model does not provide;
#   relaxing it would silently weaken the source contract. (6 is in fact
#   unconstructible on a plain load/store — LLVM only permits it on atomicrmw/
#   cmpxchg/fence — so its rejection here is defensive for any future reuse.)
# `volatile` is handled by a SEPARATE check above each guard and is NOT relaxed
# under either gate: it is an I/O-effect contract, not an ordering one.
@inline _vm_relaxable_ordering(ord) =
    ord == LLVM.API.LLVMAtomicOrderingNotAtomic   ||
    ord == LLVM.API.LLVMAtomicOrderingUnordered   ||
    ord == LLVM.API.LLVMAtomicOrderingMonotonic   ||
    ord == LLVM.API.LLVMAtomicOrderingAcquire     ||
    ord == LLVM.API.LLVMAtomicOrderingRelease

# Bennett-q04a / 59jj-cut: this function returns a Union of 16 IRInst
# subtypes plus `Nothing` (skip) plus `Vector{IRInst}` (cc0.7 vector
# expansion) — 18 arms, beyond Julia's union-splitting threshold. The
# call site in `_walk_function!` (~line 1003-1018) dispatches via four
# isa-checks: `=== nothing`, `isa Vector`, `isa IRRet||IRBranch||IRSwitch`,
# else. Investigated 2026-04-27 (worklog/047, q04a entry):
#   - Empirical extraction cost: ~1.93 KiB / 7-instruction fn; the per-
#     instruction box from this Union contributes ~5% of the total.
#   - Extraction is one-shot per compile — NOT a runtime hot path.
#   - Splitting into `_convert_instruction_single::IRInst` +
#     `_convert_instruction_expand!(out::Vector{IRInst}, ...)` would
#     eliminate the Vector + Nothing arms but still leaves an abstract-
#     IRInst return (16 concrete subtypes — Julia handles this fine).
#     Refactor blast radius: the function body (1252-2200) plus the
#     caller dispatch — substantial churn for ~5% extraction speedup.
# Decision: doc-only. Contract pinned by `test/test_q04a_convert_instruction_contract.jl`
# (9 assertions): IRInst subtype count = 16, Union arm count bounded
# 10-22, caller dispatch shape pinned, extraction allocation linear in
# instruction count. Re-measure if a workload OOMs during extraction.

# Bennett-xrd6 (Rule 12): the closed-world cell-ABI argument-carry loop, shared
# by the registered-callee `ptr_cells` branch (consumed-call path) AND the
# unregistered C-call arm of the LLVMCall handler. Iterates the operands
# `1:(n_ops-1)` (the last operand is the callee value), carrying every
# `IntegerType` operand at its own bit width and every `PointerType` operand as
# one 64-bit VM cell (ADR 0018 §A — a pointer/sret-out box ptr is one address
# cell). The Julia swiftcc GC-frame synthetic (`ptr nonnull swiftself
# %pgcstack`) is a synthetic frame arg with no VM meaning — identified by its
# call-site `swiftself` attribute (NOT by name, Rule 5) and SKIPPED. This is a
# no-op for genuine C calls (ccall / in-module `.ll` callees carry no swiftself
# attribute), so the C-call arm's behaviour is unchanged for the C-track corpus.
# Any other operand type (float, vector, struct-by-value, token) fails loud
# (CLAUDE.md §1). Pointer/integer constants resolve via `_operand(...;
# ptr_cells=true)` so a `ptr null` arg becomes the zero cell rather than
# crashing — both call sites are already `ptr_cells`-gated.
function _cell_call_args(inst::LLVM.Instruction, ops, n_ops::Int,
                         names::Dict{_LLVMRef, Symbol};
                         skip_sret::Bool=false)
    kind_swiftself = LLVM.API.LLVMGetEnumAttributeKindForName("swiftself", 9)
    # Bennett-416r.17: on the sret-forwarding path (skip_sret=true) the producing
    # call's sret-out box is a local temporary whose aggregate IS the enclosing
    # block's IRRet — NOT a callee value argument. Identify it by its call-site
    # `sret` attribute (Rule 5, never by position) and SKIP it. LangRef permits
    # at most one sret parameter, so exactly one operand is elided. Default
    # (skip_sret=false) never queries the attribute ⇒ existing callers are
    # byte-identical (the consumed-call path carries the box as a genuine cell).
    kind_sret = skip_sret ? LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4) : UInt32(0)
    args = IROperand[]
    widths = Int[]
    for i in 1:(n_ops - 1)
        # Skip the swiftcc GC-frame synthetic (call-site swiftself attribute at
        # this operand's param index). For C calls this is always C_NULL ⇒ no-op.
        LLVM.API.LLVMGetCallSiteEnumAttribute(inst, UInt32(i), kind_swiftself) == C_NULL ||
            continue
        # Bennett-416r.17: elide the sret-out box operand on the forwarding path.
        if skip_sret
            LLVM.API.LLVMGetCallSiteEnumAttribute(inst, UInt32(i), kind_sret) == C_NULL ||
                continue
        end
        op = ops[i]
        ot = LLVM.value_type(op)
        if ot isa LLVM.IntegerType
            push!(args, _operand(op, names; ptr_cells=true))
            push!(widths, Int(LLVM.width(ot)))
        elseif ot isa LLVM.PointerType
            # Pointer ARG = 64-bit cell-address value (ADR 0018 §A).
            push!(args, _operand(op, names; ptr_cells=true))
            push!(widths, 64)
        else
            _ir_error(inst,
                "call argument $(i) has unsupported type $(ot) under ptr_cells; " *
                "only integer and pointer (cell) args are modelled " *
                "(Bennett-xrd6 / BVM ADR 0020 D5)")
        end
    end
    return (args, widths)
end

# Bennett-lbot / CW-D (ADR 0017): fuse an `extractvalue` off an overflow-arith
# intrinsic (`llvm.{smul,umul,sadd,uadd}.with.overflow.iN`, result `{iN,i1}`)
# into a scalar IRInst. The `{iN,i1}` aggregate is never modeled; both fields are
# re-derived directly from the intrinsic call's operands `[a, b, callee]`:
#   - idx 0 (wrapped product/sum) → IRBinOp(dest, :mul|:add, a, b, N)
#   - idx 1 (overflow bit)        → IRBinOp(dest, :add, iconst(0), iconst(0), 1)
#     ONLY when the op is PROVABLY no-overflow, else FAIL LOUD.
#
# CRITICAL fold predicate: the provably-no-overflow constant set for MUL is
# `{0,1}` ONLY — NOT `{-1,0,1}`. Signed `smul(x,-1) = -x` overflows at x = INT_MIN
# (`-2^(N-1) * -1 = 2^(N-1)` is unrepresentable), so `-1` is NOT admitted. For ADD
# the set is `{0}` (x+0 never overflows). A wrong placeholder-0 would route away
# from the throw the native code takes on overflow — UNSOUND — so anything else
# fails loud (CLAUDE.md §1) rather than guessing.
function _fuse_overflow_extractvalue(call, cn, idx, dest, inst, names)
    idx in (0, 1) || _ir_error(inst,
        "extractvalue index $idx out of range for overflow intrinsic $cn " *
        "(only 0=result, 1=overflow-bit). (Bennett-lbot)")
    cops = LLVM.operands(call)            # [a, b, callee]
    a, b = cops[1], cops[2]
    N  = _iwidth(a)
    op = (startswith(cn, "llvm.smul") || startswith(cn, "llvm.umul")) ? :mul : :add
    if idx == 0
        # Wrapped product/sum: the scalar iN arithmetic (N-bit two's-complement
        # wrap matches the intrinsic's low-N-bits result field).
        return IRBinOp(dest, op, _operand(a, names), _operand(b, names), N)
    end
    # idx == 1: overflow bit — iconst(0) ONLY when provably no-overflow.
    ca = a isa LLVM.ConstantInt ? _const_int_as_int(a) : nothing
    cb = b isa LLVM.ConstantInt ? _const_int_as_int(b) : nothing
    provably_zero = op === :mul ? (ca in (0, 1) || cb in (0, 1)) :   # x*0, x*1 never overflow
                                  (ca == 0 || cb == 0)               # x+0 never overflows
    provably_zero || _ir_error(inst,
        "overflow bit of $cn is not provably zero (operands $(string(a)), $(string(b))); " *
        "general overflow-bit computation is future work — a placeholder-0 would route away " *
        "from the throw the native code takes and is UNSOUND. (Bennett-lbot)")
    # The overflow bit is field 1 of `{iN,i1}` — an i1. `_iwidth(inst)` == 1.
    return IRBinOp(dest, :add, iconst(0), iconst(0), _iwidth(inst))   # bit = 0 (i1)
end

function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Symbol},
                              counter::Ref{Int},
                              lanes::Dict{_LLVMRef, Vector{IROperand}}=Dict{_LLVMRef, Vector{IROperand}}();
                              globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}=
                                  Dict{Symbol, Tuple{Vector{UInt64}, Int}}(),
                              synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}=
                                  Set{Tuple{Symbol, Int, Int}}(),
                              synth_ptr_allocas::Set{_LLVMRef}=Set{_LLVMRef}(),
                              # BVM ADR 0020 D3/D4 (CW-C2 chunk B): C-track gate.
                              # When true, `store ptr`/`load ptr` lower as 64-bit
                              # cell IRStore/IRLoad and a two-index struct GEP
                              # lowers to IRPtrOffset(elem_width=64). Default false
                              # keeps the U114 store / U16 GEP fail-louds firing
                              # byte-identically (they guard the circuit/:heap
                              # models). The C cell model must not silently alias
                              # those paths — `module_walk.jl` is the sole setter.
                              ptr_cells::Bool=false,
                              # Bennett-iwo9 / CW-D3 Lever 1: extraction-local
                              # type-tag interning. `tag_ids` maps a canonical
                              # type path ("Main.Base.Dict") → dense Int64 id
                              # (first-seen walk order, deterministic). `tag_ssa`
                              # records the SSA dests that carry a type-tag value
                              # (provenance), so a downstream ptrtoint/inttoptr
                              # whose source is a tag is recognised as the sound
                              # type-tag round-trip. Both threaded from
                              # `module_walk.jl` (the sole owner) and mutated in
                              # place. Only consulted under `ptr_cells=true`.
                              tag_ids::Dict{String, Int64}=Dict{String, Int64}(),
                              tag_ssa::Set{_LLVMRef}=Set{_LLVMRef}())
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
        ops  = LLVM.operands(inst)
        pred = _pred_to_sym(LLVM.predicate(inst))
        # Bennett-8g7m / CW-D: pointer-typed icmp under the closed-world
        # `ptr_cells` gate. A ptr operand is one Int64 VM cell (ADR 0018 §A,
        # width 64); a `ptr null` lowers to the zero cell via
        # `_operand(...; ptr_cells=true)` (Bennett-beaw — the helper already
        # does null->iconst(0) under the gate). Only eq/ne is deterministic
        # over cell ADDRESSES; an ordering compare is an address-MAGNITUDE
        # comparison whose result depends on the BVM allocation layout (UB
        # across allocations in C) — FAIL LOUD (Rule 1). Mirrors the ret/store
        # beaw arms. Gate defaults false, so the circuit / Julia paths keep the
        # byte-identical integer path below (`_iwidth(ops[1])`); the guard is
        # the gate AND the PointerType operand check, so a non-pointer integer
        # icmp (e.g. `icmp slt i32`) is never caught here.
        if ptr_cells && (LLVM.value_type(ops[1]) isa LLVM.PointerType ||
                         LLVM.value_type(ops[2]) isa LLVM.PointerType)
            pred in (:eq, :ne) || _ir_error(inst,
                "icmp predicate :$pred over pointer operands under ptr_cells — " *
                "only :eq/:ne are deterministic over VM cell addresses; " *
                "ordering predicates compare address magnitudes, which depend " *
                "on the BVM allocation layout (not a source-level property) and " *
                "risk a silent miscompile. (Bennett-8g7m / U80)")
            return IRICmp(dest, pred,
                          _operand(ops[1], names; ptr_cells=true),
                          _operand(ops[2], names; ptr_cells=true), 64)
        end
        return IRICmp(dest, pred,
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
            # Bennett-yd4f / U80 / CW-D (ADR 0017): under the closed-world
            # `ptr_cells` gate ONLY, an INTEGER `undef` in phi-INCOMING position
            # is LLVM's compiler-proven don't-care on a dynamically-dead edge
            # (LangRef: undef as a phi operand). BennettVM resolves phis by the
            # TAKEN predecessor edge (BennettVM/src/ir/ingest_phi.jl:84), so a
            # `0` placeholder on a dead incoming is never materialised at
            # runtime. Model it as the zero cell `iconst(0)` (mirrors the beaw
            # ptr-null lever, helpers.jl:184, and the existing vec_vm dead-edge
            # substitution at vector_vm_term.jl:112). Gated HERE, not in
            # `_operand`, because undef→0 is position-DEPENDENT (sound only in
            # phi-incoming); every other operand position keeps `_operand`'s
            # undef fail-loud (helpers.jl:167). PoisonValue is a DISTINCT LLVM.jl
            # type (sibling of UndefValue, not a subtype), so it is NOT caught
            # here and stays fail-loud; a non-integer undef falls through to
            # `_operand` and stays fail-loud. `ptr_cells=false` (circuit/:heap)
            # is byte-identical fail-loud.
            op = (ptr_cells && val isa LLVM.UndefValue &&
                  LLVM.value_type(val) isa LLVM.IntegerType) ?
                 iconst(0) : _operand(val, names)
            push!(incoming, (op, Symbol(LLVM.name(blk))))
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

    # Bennett-iwo9 / CW-D3 Lever 1: ptrtoint / inttoptr — model ONLY the Julia
    # type-tag round-trip under the closed-world `ptr_cells` gate. The cluster
    # the fdict root hits is
    #
    #   %tag  = load ptr, ptr @"+Main.Base.Dict#148"   ; → tag_ssa (load arm)
    #   %Dict = ptrtoint ptr %tag to i64               ; src ∈ tag_ssa
    #   %1    = inttoptr i64 %Dict to ptr              ; src ∈ tag_ssa
    #
    # Each link is a width-64 identity `IRBinOp(dest, :or, <src>, iconst(0), 64)`
    # so the dest binds through the normal SSA path (consensus decision 3 —
    # real SSA defs, not zero-IR const-prop). If the source SSA is a recognised
    # type tag (`∈ tag_ssa`) the dest inherits tag provenance; OTHERWISE fail
    # loud — a genuine pointer↔int round-trip (casting a real arena pointer,
    # `ptrtoint ptr→i32`, etc.) is NOT modelled (it would expose
    # ARENA_BASE-relative addresses to integer arithmetic). Under
    # `ptr_cells=false` there is NO arm: the opcode falls through to the
    # existing "unsupported LLVM opcode" fail-loud → circuit path byte-identical.
    if (opc == LLVM.API.LLVMPtrToInt || opc == LLVM.API.LLVMIntToPtr) && ptr_cells
        src = LLVM.operands(inst)[1]
        opname = opc == LLVM.API.LLVMPtrToInt ? "ptrtoint" : "inttoptr"
        if src isa LLVM.Instruction && src.ref in tag_ssa
            # Width guard: the type-tag round-trip is a 64-bit VM-cell identity
            # (ADR 0018 §A — a tag is one Int64 cell). A cast to/from a NON-64-bit
            # width (e.g. `ptrtoint ptr %tag to i32`) is NOT this round-trip — it
            # is genuine pointer arithmetic that would truncate/extend the cell
            # value. It can't occur in the real fdict cluster (tags are always
            # 64-bit round-trips), but a core extractor arm must not hardcode a
            # width it didn't verify. PointerType has no integer width → 64 (cell).
            srt = LLVM.value_type(src)
            drt = LLVM.value_type(inst)
            src_w = srt isa LLVM.PointerType ? 64 : _iwidth(src)
            dst_w = drt isa LLVM.PointerType ? 64 : _iwidth(inst)
            (src_w == 64 && dst_w == 64) || _ir_error(inst,
                "$(opname) under ptr_cells on a type-tag value at a NON-64-bit " *
                "width (src=$(src_w), dst=$(dst_w)) (Bennett-iwo9 / CW-D3 " *
                "Lever 1). Only the 64-bit type-tag round-trip is modelled (a " *
                "type tag is one Int64 VM cell); a narrower pointer↔integer cast " *
                "is genuine pointer arithmetic that truncates/extends the cell " *
                "value and is rejected to fail fast (CLAUDE.md §1).")
            push!(tag_ssa, inst.ref)
            return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
        end
        # Bennett-583s / CW-D: `ptrtoint ptr %memory_data to i64` — the Julia
        # GenericMemory `.data` base pointer — admitted as a width-64 cell
        # identity BUT ONLY when confined to a same-Memory base-cancelling bounds
        # check (`sub(ptrtoint(P_elem), ptrtoint(P_base))` where both operands
        # trace to the SAME Memory `.data` root). Soundness (ADR 0017 CW-D): the
        # base cancels in `sub(ptrtoint(base+off), ptrtoint(base)) = off`, so the
        # net effect is base-INDEPENDENT → matches the native oracle; the `oob`
        # block is a dead `@boundscheck` throw. Any escaping / base-DEPENDENT use
        # (inttoptr-back-to-deref, store-of-int, hash, cross-allocation diff,
        # width≠64) would break oracle match (the bennettvm-90l hazard) and stays
        # fail-loud. `inttoptr` of a `.data` base is itself the forbidden escape,
        # so this arm is `LLVMPtrToInt`-only — an `inttoptr` falls through to the
        # iwo9 fail-loud below. Sits inside the `&& ptr_cells` block, so the
        # circuit path is byte-identical (no arm at all → the ptrtoint opcode
        # hits the pre-existing "unsupported LLVM opcode" wall).
        if opc == LLVM.API.LLVMPtrToInt && src isa LLVM.Instruction &&
           _memdata_root(src) !== nothing
            srt = LLVM.value_type(src)
            drt = LLVM.value_type(inst)
            src_w = srt isa LLVM.PointerType ? 64 : _iwidth(src)
            dst_w = drt isa LLVM.PointerType ? 64 : _iwidth(inst)
            (src_w == 64 && dst_w == 64) || _ir_error(inst,
                "ptrtoint of a GenericMemory .data base at a NON-64-bit width " *
                "(src=$(src_w) dst=$(dst_w)) — genuine pointer arithmetic, not a " *
                "cell identity (Bennett-583s / CW-D). Only the 64-bit .data-base " *
                "round-trip confined to a base-cancelling bounds check is modelled " *
                "(CLAUDE.md §1).")
            _verify_memdata_bounds_cluster(inst, src) || _ir_error(inst,
                "ptrtoint of a GenericMemory .data base under ptr_cells whose " *
                "result is NOT confined to a same-Memory base-cancelling bounds " *
                "check (a use is not a same-root sub(ptrtoint,ptrtoint); e.g. " *
                "inttoptr-deref, store, hash, or a cross-allocation difference). " *
                "An escaping base-dependent address would break oracle match " *
                "(Bennett-583s / CW-D; CLAUDE.md §1).")
            return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
        end
        _ir_error(inst,
            "$(opname) under ptr_cells whose source is NOT a recognised Julia " *
            "type-tag value (Bennett-iwo9 / CW-D3 Lever 1). Only the type-tag " *
            "round-trip `load @\"+Type#N\" → ptrtoint → inttoptr` is modelled — " *
            "a genuine pointer↔integer round-trip (e.g. casting a real arena " *
            "pointer, or `ptrtoint ptr→i32`) would expose ARENA_BASE-relative " *
            "addresses to integer arithmetic and is rejected to fail fast " *
            "(CLAUDE.md §1).")
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
        # BVM ADR 0020 D3 (CW-C2 chunk B): under the C-track `ptr_cells` gate, a
        # `ret ptr %p` returns a pointer VALUE that is one Int64 VM cell (ADR
        # 0018 §A) — width 64. The function-level return-WIDTH derivation in
        # `module_walk.jl` already maps the `ptr` return type to `ret_width = 64`;
        # this handles the matching TERMINATOR (`IRRet`'s `width`), whose operand
        # `%p` is a ptr value with no scalar `_type_width`. Gate defaults false,
        # so the Julia paths keep the byte-identical `_iwidth(ops[1])` behaviour
        # below. (`ret void` carries no operand and is NOT handled here — it is
        # chunk C / D5, see the return-width note in module_walk.jl.)
        if ptr_cells && !isempty(ops) &&
           LLVM.value_type(ops[1]) isa LLVM.PointerType
            # Bennett-beaw / CW-D: thread `ptr_cells` so a `ret ptr null`
            # operand (ConstantPointerNull) lowers to the zero cell iconst(0)
            # rather than the U80 fail-loud (the cell model: null = address 0).
            return IRRet(_operand(ops[1], names; ptr_cells=true), 64)
        end
        # BVM ADR 0020 D5b (CW-C2 chunk C): `ret void` under the C-track gate.
        # A void return carries NO operand (`isempty(ops)`) and NO width. The
        # value-bearing `IRRet(op, w)` requires `op::IROperand` + `width >= 1`,
        # so void is the dedicated `IRRet()` void FORM (`op === nothing`,
        # `width == 0`) — a terminator (so the block-builder's no-terminator
        # AssertionError never fires), but one BVM maps to
        # `EndInstruction(routine, Symbol[])` (empty returns) and
        # `_declared_returns` ⇒ `Symbol[]` (the C void-callee shape: empty
        # `CallEnter.targets`). The function-level `ret_width = 0` /
        # `ret_elem_widths = Int[]` derivation (module_walk.jl, void arm) is the
        # matching half. Gate-off: `ret void`'s function-level VoidType
        # derivation still hits the U81 wall UPSTREAM (module_walk.jl), so this
        # arm is never reached for the Julia paths; the guard is the gate.
        if ptr_cells && isempty(ops)
            return IRRet()
        end
        return IRRet(_operand(ops[1], names), _iwidth(ops[1]))
    end

    # extractvalue — select one element from an aggregate.
    # Bennett-tu6i / U10: homogeneous ArrayType aggregates (scalar element).
    # Bennett-6bu3: StructType aggregates ({ptr,ptr} GenericMemoryRef bodies,
    # mixed-width integer tuples) are now supported via per-field widths — see
    # `_struct_field_widths`. Fields are restricted to fixed-width integers
    # ({8,16,32,64}) or (under ptr_cells) pointers; i1 (`{i64,i1}` overflow/
    # cmpxchg), float, nested-struct, vector, and array fields stay FAIL-LOUD
    # there. Anything that is neither Array nor Struct (vector/scalar) still
    # falls to the final loud reject below.
    if opc == LLVM.API.LLVMExtractValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        idx_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = Int(unsafe_load(idx_ptr))  # 0-based
        # Bennett-lbot / CW-D (ADR 0017): an extractvalue whose aggregate is an
        # overflow-arith intrinsic call (`llvm.{smul,umul,sadd,uadd}.with.overflow`)
        # is FUSED into a scalar IRInst, re-deriving the value from the CALL's
        # operands — the `{iN,i1}` aggregate is never modeled (its i1 field would
        # trip the 6bu3 StructType i1-field reject via `_struct_field_widths`
        # below). The producing call emits nothing (Spot 1, CALL arm). Placed
        # BEFORE the StructType/ArrayType dispatch so the aggregate type is never
        # inspected. ptr_cells-gated ⇒ byte-identical when off.
        if ptr_cells && agg_val isa LLVM.Instruction &&
           LLVM.opcode(agg_val) == LLVM.API.LLVMCall
            cn = _heap_callee_name(agg_val)   # heap.jl: guards opcode==Call
            if startswith(cn, "llvm.smul.with.overflow.") ||
               startswith(cn, "llvm.umul.with.overflow.") ||
               startswith(cn, "llvm.sadd.with.overflow.") ||
               startswith(cn, "llvm.uadd.with.overflow.")
                return _fuse_overflow_extractvalue(agg_val, cn, idx, dest, inst, names)
            end
        end
        agg_type = LLVM.value_type(agg_val)
        if agg_type isa LLVM.ArrayType
            ew = LLVM.width(LLVM.eltype(agg_type))
            ne = LLVM.length(agg_type)
            return IRExtractValue(dest, _operand(agg_val, names), idx, ew, ne)
        elseif agg_type isa LLVM.StructType
            fw = _struct_field_widths(agg_type, inst, ptr_cells)
            0 <= idx < length(fw) || _ir_error(inst,
                "extractvalue index $idx out of range for StructType $(string(agg_type)) " *
                "with $(length(fw)) fields. (Bennett-6bu3)")
            return IRExtractValue(dest, _operand(agg_val, names), idx,
                                  0, length(fw), fw)
        else
            _ir_error(inst,
                "extractvalue on $(string(agg_type)) is not supported; only " *
                "homogeneous ArrayType and (Bennett-6bu3) fixed-width " *
                "StructType aggregates are.")
        end
    end

    # insertvalue — same Array/Struct support as extractvalue.
    if opc == LLVM.API.LLVMInsertValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        elem_val = ops[2]
        idxs_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = Int(unsafe_wrap(Array, idxs_ptr, 1)[1])
        agg_type = LLVM.value_type(inst)
        if agg_type isa LLVM.ArrayType
            ew = LLVM.width(LLVM.eltype(agg_type))
            ne = LLVM.length(agg_type)
            return IRInsertValue(dest, _operand(agg_val, names),
                                 _operand(elem_val, names), idx, ew, ne)
        elseif agg_type isa LLVM.StructType
            fw = _struct_field_widths(agg_type, inst, ptr_cells)
            0 <= idx < length(fw) || _ir_error(inst,
                "insertvalue index $idx out of range for StructType $(string(agg_type)) " *
                "with $(length(fw)) fields. (Bennett-6bu3)")
            # Pass `ptr_cells` to `_operand` for the INSERTED value so a
            # `ptr null` field lowers to the zero cell (iconst(0)) per Bennett-beaw.
            return IRInsertValue(dest, _operand(agg_val, names),
                                 _operand(elem_val, names; ptr_cells=ptr_cells),
                                 idx, 0, length(fw), fw)
        else
            _ir_error(inst,
                "insertvalue on $(string(agg_type)) is not supported; only " *
                "homogeneous ArrayType and (Bennett-6bu3) fixed-width " *
                "StructType aggregates are.")
        end
    end

    # unreachable — dead code
    if opc == LLVM.API.LLVMUnreachable
        return IRBranch(nothing, :__unreachable__, nothing)
    end

    # Bennett-4eu: indirectbr is a Bennett hard stop, like atomicrmw /
    # invoke / landingpad. The static-CFG model that Bennett's phi
    # resolution and loop unrolling depend on requires block targets
    # known at compile time. `indirectbr` defers target resolution to
    # runtime via a block-address pointer — incompatible with Bennett's
    # discipline. A future implementation could lower the *constant*
    # special case (computed goto whose address is a phi/select over
    # blockaddress(@f, %bb) constants) by tracking block-address IDs
    # through pointer ops and emitting cascaded conditional branches,
    # but that's a substantial workstream and no Julia / C / Rust
    # idiom Bennett currently targets emits indirectbr (Julia never;
    # `goto *ptr` in C is a GCC extension uncommon in numerical code;
    # Rust never). Fail loud here rather than the generic
    # unsupported-opcode error so the user gets actionable context.
    if opc == LLVM.API.LLVMIndirectBr
        _ir_error(inst,
            "indirectbr (computed goto) is not supported. Bennett's " *
            "static-CFG model requires compile-time-known branch " *
            "targets — phi resolution, loop unrolling, and the Bennett " *
            "construction itself depend on it. If you reached this " *
            "from C `goto *ptr` or similar, restructure the source as " *
            "a switch over an explicit integer dispatch index. " *
            "(Bennett-4eu hard stop)")
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
            # Bennett-tzrs / U41 first cut: dispatch the LLVM-intrinsic
            # prefix block to `_handle_intrinsic` (helper above). Returns
            # nothing if no intrinsic matched; we then fall through to the
            # registered-callee path.
            handled = _handle_intrinsic(cname, inst, names, counter, dest, ops, globals;
                                        synth_ptr_provenance=synth_ptr_provenance,
                                        synth_ptr_allocas=synth_ptr_allocas,
                                        ptr_cells=ptr_cells)
            handled === nothing || return handled
        end
        # Known Julia function calls → IRCall for gate-level inlining
        if n_ops >= 1
            callee = _lookup_callee(cname)
            if callee !== nothing
                if ptr_cells
                    # Bennett-xrd6: closed-world cell ABI for a registered callee
                    # whose result is CONSUMED locally (read back from an sret-out
                    # box, or used as a returned cell) — NOT gate-inlined. Carries
                    # pointer args (incl. the sret-out box ptr as arg 1) as 64-bit
                    # VM cells so the read-back loads of the box resolve, and uses
                    # the void/ptr → 64 ret_width SENTINEL: an sret-convention call
                    # has a `void` LLVM return, and a Dict-returning call a `ptr`
                    # return — neither has a scalar width of its own. The Function
                    # callee is kept (clean nameof for closed-world linkage); the
                    # IRCall shape is identical to the C-track / isolation D5 form
                    # BennettVM already consumes.
                    #
                    # Fail-loud (CLAUDE.md §1): if this is an sret-convention call,
                    # validate the sret pointee is a fixed-width integer bits-struct
                    # (reusing the Bennett-dv1z `_sret_struct_fields` rules: reject
                    # non-StructType pointee, packed structs, non-integer fields,
                    # widths ∉ {8,16,32,64}) BEFORE trusting the read-back machinery
                    # to unpack the box. A genuinely-unsupported sret shape rejects
                    # here, never silently miscompiles.
                    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
                    asret = LLVM.API.LLVMGetCallSiteEnumAttribute(inst, UInt32(1), kind_sret)
                    if asret != C_NULL
                        pointee = LLVM.LLVMType(LLVM.API.LLVMGetTypeAttributeValue(asret))
                        pointee isa LLVM.StructType || _ir_error(inst,
                            "sret-convention call to '$(cname)' has pointee " *
                            "$(pointee); only fixed-width integer bits-struct sret " *
                            "pointees (e.g. {i64,i8}) are modelled on the " *
                            "consumed-call path (Bennett-xrd6)")
                        # Side-effecting validation (return discarded): rejects
                        # packed / non-integer / bad-width fields loud (Bennett-dv1z).
                        _sret_struct_fields(pointee, LLVM.parent(LLVM.parent(inst)))
                    end
                    cell_args, cell_widths = _cell_call_args(inst, ops, n_ops, names)
                    rt = LLVM.value_type(inst)
                    ret_w = if rt isa LLVM.VoidType || rt isa LLVM.PointerType
                        64                       # void sret call / ptr-returning call
                    elseif rt isa LLVM.IntegerType
                        Int(LLVM.width(rt))
                    elseif rt isa LLVM.ArrayType
                        _type_width(rt)          # NTuple [N x iM] wide return
                    else
                        _ir_error(inst,
                            "registered call to '$(cname)' has unsupported return " *
                            "type $(rt) under ptr_cells; only void, integer, " *
                            "pointer (cell), and [N x iM] aggregate returns are " *
                            "modelled (Bennett-xrd6). A by-value StructType return " *
                            "must use the sret convention.")
                    end
                    return IRCall(dest, callee, cell_args, cell_widths, ret_w)
                end
                # gate-inlining ABI (circuit path, ptr_cells=false): integer args
                # ONLY — pointers (pgcstack, by-ref aggregates) are skipped because
                # `lower_call!` re-extracts the callee body and inlines it. Byte-
                # identical to pre-xrd6 (the gate-count regression baselines pin it).
                #
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

        # BVM ADR 0020 D5 (CW-C2 chunk C): call emission on a `_lookup_callee`
        # MISS, under the C-track `ptr_cells` gate. A `.ll` call whose callee is
        # not a registered Julia `Function` is, in the closed-world C model,
        # either a libc heap intrinsic or an in-module `define`d function — both
        # carried to BVM as an `IRCall` with a `Symbol` callee (the name-only
        # form; BVM resolves it: `_HEAP_DISPATCH` for the libc whitelist, the
        # guard-5 function table for an in-module callee). The callee VALUE is
        # the LAST operand (`ops[n_ops]`); it is an `LLVM.Function`. NOTE
        # (nd45 review nit 2): the code deliberately does NOT branch on
        # `isdeclaration` — declarations and in-module bodies both emit the
        # same Symbol-callee IRCall, and BVM disambiguates by name. A
        # non-whitelisted EXTERNAL (e.g. printf) is therefore NOT rejected at
        # U15 under gate-ON; it flows to BVM and rejects at the SoftCall
        # allowlist (still fail-loud, different site). Gate-off (the Julia
        # paths) this whole block is
        # skipped — a `_lookup_callee` miss falls straight through to the benign-
        # prefix allowlist / U15 fail-loud below, byte-identically.
        if ptr_cells && n_ops >= 1
            callee_val = ops[n_ops]
            if callee_val isa LLVM.Function
                # Bennett-zf5v / CW-D2: GC-rooting bookkeeping intrinsics. At
                # optimize=false the closed-world producer's bodies wall here on
                # `llvm.julia.gc_preserve_begin` (return type `token`) — the
                # ptr_cells C-call arm's TokenType reject (~below). These two
                # intrinsics carry NO value semantics in the deterministic,
                # single-threaded, history-reversible VM cell model: they only
                # extend GC roots for the live preserved pointers between
                # _begin and _end. The preserved-pointer args live independently
                # in their own SSA values (consumed by the real ops in between);
                # the only thing _begin PRODUCES is the rooting `token`, which is
                # consumed SOLELY by gc_preserve_end (also dropped) — so dropping
                # both leaves NO dangling SSA reference. Placed at the TOP of the
                # arm (BEFORE the variadic-arg loop AND the return-type check)
                # because gc_preserve_begin is variadic (`call token (...)`): a
                # lower placement would hit the arg-carry / TokenType error
                # first. Exact-name-scoped (Rule 1): any OTHER token-returning
                # call still walls at the TokenType reject below.
                if cname == "llvm.julia.gc_preserve_begin" ||
                   cname == "llvm.julia.gc_preserve_end"
                    return nothing
                end
                # CW-D2 / 416r.12: julia.write_barrier is GC card-marking with NO
                # VM value semantics (void, dest auto-named + never consumed, like
                # gc_preserve/safepoint). Drop BEFORE the generic C-call void arm
                # (which would emit a Symbol IRCall BVM has no home for). The
                # benign_prefixes list is UNREACHABLE for Function callees under
                # ptr_cells, so the drop must go here. Exact-name-scoped (Rule 1).
                if cname == "julia.write_barrier"
                    return nothing
                end
                # Bennett-r92o / CW-D3 Lever 2 (consensus decision 4): the Julia
                # typed-GC allocation `julia.gc_alloc_obj`. Un-drop it under the
                # closed-world `ptr_cells` gate, modelling it as a Symbol-callee
                # IRCall (Bennett-k3ej) the BennettVM arena floor (Lever 3,
                # ADR 0021 D3) ingests as a bump alloc. Placed at the TOP of this
                # arm — BEFORE the generic C-call arg loop — for two reasons:
                #   (1) The generic loop carries the `task` pointer arg
                #       (`ops[1]`), but `task` is a %pgcstack GEP with NO VM
                #       meaning and MUST be dropped (decision 4). We want
                #       exactly [size, tag], not [task, size, tag].
                #   (2) The generic loop would set the callee to the full dotted
                #       name `Symbol("julia.gc_alloc_obj")`; BennettVM dispatches
                #       on the canonical `:gc_alloc_obj` (`_HEAP_DISPATCH`).
                # LLVM operand layout (verified empirically): for
                # `call ptr @julia.gc_alloc_obj(ptr %task, i64 %size, ptr %tag)`,
                # `ops = [task, size, tag, callee]` (callee is the LAST operand,
                # matching the `cname = LLVM.name(ops[n_ops])` convention above).
                # So 3 args ⇔ `n_ops == 4`. FAIL LOUD (CLAUDE.md §1) on any other
                # arity — gc_alloc_obj's signature is fixed at (task, size, tag).
                # Gate-off (ptr_cells=false): this whole arm is skipped, so
                # gc_alloc_obj falls through to the broad `julia.gc_` benign drop
                # below, byte-identically to pre-r92o.
                if cname == "julia.gc_alloc_obj"
                    n_ops == 4 || _ir_error(inst,
                        "julia.gc_alloc_obj expected 3 args (task, size, tag) " *
                        "⇒ n_ops == 4 (callee is the last operand), got " *
                        "n_ops == $(n_ops). The Julia typed-GC alloc signature " *
                        "is fixed; an unexpected arity is not modelled " *
                        "(Bennett-r92o / CW-D3 Lever 2)")
                    # Drop ops[1] (task / %pgcstack GEP). Carry [size, tag] as the
                    # two Int64 VM cells; BennettVM ignores the tag's value
                    # (ADR 0021 D3 floor: tag stored but structurally unread).
                    size_op = _operand(ops[2], names)
                    tag_op = _operand(ops[3], names)
                    return IRCall(dest, :gc_alloc_obj,
                                  IROperand[size_op, tag_op], Int[64, 64], 64)
                end
                # Bennett-lbot / CW-D (ADR 0017): overflow-arith intrinsics
                # (`llvm.{smul,umul,sadd,uadd}.with.overflow.iN`, result
                # `{iN,i1}`). The `{iN,i1}` aggregate is NEVER modeled — an i1
                # struct field hits the 6bu3 i1-field reject on BOTH repos. The
                # two `extractvalue`s re-derive the scalars (wrapped product/sum
                # + overflow bit) DIRECTLY from THIS call's operands (fused at the
                # extractvalue handler, `_fuse_overflow_extractvalue`). So the
                # call itself emits NOTHING: its `dest` is bound to no IRInst and
                # its ref is consumed ONLY by those two extractvalues (any OTHER
                # consumer would fail loud at `_operand` — no dest binding). Placed
                # BEFORE the generic C-call arm to pre-empt the D5 `{iN,i1}`
                # return-type reject below. Auto-gated (inside the `ptr_cells` arm)
                # ⇒ byte-identical when off. `return nothing` skips the inst
                # (module_walk.jl `ir_inst === nothing && continue`).
                if startswith(cname, "llvm.smul.with.overflow.") ||
                   startswith(cname, "llvm.umul.with.overflow.") ||
                   startswith(cname, "llvm.sadd.with.overflow.") ||
                   startswith(cname, "llvm.uadd.with.overflow.")
                    return nothing
                end
                # A C `ptr` arg/return is one Int64 VM cell (ADR 0018 §A): every
                # operand (integer OR pointer) is carried at the cell width — a
                # ptr arg as 64, an integer arg at its own width. The C closed-
                # world model has no synthetic frame arg; the shared helper's
                # swiftself skip is therefore a no-op here (Bennett-xrd6, Rule 12 —
                # the carry loop is now shared with the registered-callee branch).
                c_args, c_widths = _cell_call_args(inst, ops, n_ops, names)
                rt = LLVM.value_type(inst)
                cn = Symbol(cname)
                if rt isa LLVM.VoidType
                    # D5b void CALL (`call void @free` / `@ht_put`): IRCall.dest
                    # is mandatory (`::Symbol`) and `ret_width >= 1`, so a void
                    # call carries the auto-named never-read `dest` (the naming
                    # pass already assigned one — line ~207) plus a `ret_width=64`
                    # SENTINEL. The dest is NEVER consumed: BVM routes a void
                    # callee to `IntrinsicFree` (takes no dest) or guard-5 with
                    # `isempty(fe.returns)` ⇒ EMPTY targets, so neither the dest
                    # nor the sentinel width is read. 64 (not a smaller value) so
                    # the IR-level invariant `ret_width == cell-width` holds for
                    # every C call, void or not — a uniform shape, no special 0.
                    return IRCall(dest, cn, c_args, c_widths, 64)
                elseif rt isa LLVM.IntegerType
                    return IRCall(dest, cn, c_args, c_widths, LLVM.width(rt))
                elseif rt isa LLVM.PointerType
                    # Pointer RETURN (`malloc` / `ht_new`) = 64-bit cell.
                    return IRCall(dest, cn, c_args, c_widths, 64)
                else
                    _ir_error(inst,
                        "C call to '$(cname)' has unsupported return type " *
                        "$(rt) under ptr_cells; only void, integer, and pointer " *
                        "(cell) returns are modelled (BVM ADR 0020 D5 / chunk C)")
                end
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
            # llvm.memset is now handled explicitly by `_handle_memset_arm`
            # above (Bennett-9nwt). The c=0 case takes a fast-path silent
            # drop that matches the previous benign-list behaviour for
            # Julia GC-frame zeroing; c≠0 cases lower to byte-granular
            # IRStore-of-ConstOperand. NOT in this list anymore.
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
                # `offset` is the byte offset (circuit-backend semantics);
                # `elem_bits` is the source element bit width threaded into the
                # additive IRPtrOffset.elem_width field so the cell-addressed
                # BennettVM can recover the element index (Bennett-xv0u /
                # bennettvm-b5x). For the integer branch it is the true element
                # width; for the legacy non-integer branch (U16 out of scope)
                # offset is the raw index, so 8 is its raw-index unit (1 byte).
                offset, elem_bits = if src_type_const isa LLVM.IntegerType
                    stride_bytes = LLVM.width(src_type_const) ÷ 8
                    stride_bytes >= 1 || _ir_error(inst,
                        "constant-index GEP with sub-byte source element " *
                        "width $(LLVM.width(src_type_const)) bits not " *
                        "supported (Bennett-vz5n / U12)")
                    (raw_idx * stride_bytes, Int(LLVM.width(src_type_const)))
                else
                    # Struct / array / float / vector base: legacy raw-index
                    # behaviour. Silent-pass, tracked in U16. elem_width=8 is
                    # the legacy raw-index unit (offset is the raw index, U16
                    # out of scope — BennettVM only receives the integer-source
                    # `mem=:vm` GEPs, never this branch).
                    (raw_idx, 8)
                end
                return IRPtrOffset(dest, ssa(names[base.ref]), offset, elem_bits)
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
        # Case C: two-index ARRAY GEP (bennettvm-416r.4 + Bennett-dzd). A
        # runtime-indexed array element access compiles to
        # `getelementptr [N x iM], ptr BASE, i64 0, i64 IDX` — base + TWO
        # indices (`length(ops) == 3`): the leading constant-0 steps over the
        # (single) array at BASE, IDX selects element IDX. This is semantically
        # IDENTICAL to the single-index `iM, ptr BASE, i64 IDX` form (Case A /
        # Case B above) once the leading 0 is stripped, so it lowers to the SAME
        # node — `IRVarGEP(dest, base_sym, idx, elem_width)` — which
        # `lower_var_gep!` (circuit) / BVM's `VarGEP` already handle for the
        # single-index shape. ONE shared arm covers BOTH bases:
        #   * a constant global array (`const uint8_t rom[8]`; name ∈ globals) —
        #     the bennettvm-416r.4 acceptance case (`rom[i & 7]`), lowered like
        #     Case B (base symbol = the global's LLVM name, resolved via
        #     `parsed.globals` downstream);
        #   * a named local (an alloca-backed C stack array `uint8_t a[8]`;
        #     `haskey(names, base.ref)`) — the Bennett-dzd closure, lowered like
        #     Case A (base symbol = the alloca's SSA name).
        #
        # FAIL LOUD (keeping the Bennett-qal5 / U16 breadcrumb) on every shape
        # this arm does NOT model: a non-integer array element (float / pointer /
        # nested `[K x [M x iN]]` array — no bit-exact elem_width), a first index
        # that is not the constant 0 (a non-plain array-base step), or > 3
        # operands (a genuine multi-dim GEP), which falls through to the U16 wall
        # below. Only fires when the GEP source element type is an ArrayType AND
        # the base is a recognised global-or-local — a two-index STRUCT GEP
        # (StructType source) is NOT an ArrayType, so it skips this arm and hits
        # the struct arm below unchanged.
        if length(ops) == 3
            src_ty_ref_arr = LLVM.API.LLVMGetGEPSourceElementType(inst)
            src_type_arr = LLVM.LLVMType(src_ty_ref_arr)
            if src_type_arr isa LLVM.ArrayType
                is_global_arr = base isa LLVM.GlobalVariable &&
                                LLVM.isconstant(base) &&
                                haskey(globals, Symbol(LLVM.name(base)))
                is_local_arr = haskey(names, base.ref)
                if is_global_arr || is_local_arr
                    elem_ty_arr = LLVM.eltype(src_type_arr)
                    elem_ty_arr isa LLVM.IntegerType || _ir_error(inst,
                        "two-index array getelementptr with non-integer array " *
                        "element type $(elem_ty_arr) is not supported; cannot " *
                        "infer a bit-exact elem_width (float / pointer / nested " *
                        "array are out of scope) (Bennett-qal5 / U16; " *
                        "bennettvm-416r.4)")
                    (ops[2] isa LLVM.ConstantInt &&
                     _const_int_as_int(ops[2]) == 0) || _ir_error(inst,
                        "two-index array getelementptr first index must be the " *
                        "constant 0 (the single-array base step); got a " *
                        "non-zero / non-constant first index (Bennett-qal5 / " *
                        "U16; bennettvm-416r.4)")
                    ew_arr = LLVM.width(elem_ty_arr)
                    base_sym_arr = is_local_arr ? names[base.ref] :
                                   Symbol(LLVM.name(base))
                    idx_op_arr = ops[3] isa LLVM.ConstantInt ?
                        iconst(_const_int_as_int(ops[3])) :
                        _operand(ops[3], names)
                    return IRVarGEP(dest, ssa(base_sym_arr), idx_op_arr, ew_arr)
                end
            end
        end
        # BVM ADR 0020 D4 (CW-C2 chunk B): two-index struct GEP under the
        # C-track `ptr_cells` gate. A C struct-field access compiles to
        # `getelementptr %struct.T, ptr %p, i32 0, i32 K` — base + TWO constant
        # indices (`length(ops) == 3`): index 0 steps over the (single) struct
        # at `%p`, index K selects member K. This lowers to
        # `IRPtrOffset(dest, base, offset_bytes, elem_width=64)` where
        # `offset_bytes` is the member's byte offset from the LLVM datalayout
        # (`LLVM.offsetof` → `LLVMOffsetOfElement`; NEVER IR-text parsing,
        # Bennett.jl Rule 5/8). `elem_width=64` is the cell width: every struct
        # member BVM addresses is a 64-bit cell (ADR 0018 §A).
        #
        # FAIL LOUD (still — the gate ADDS one accepted shape, it does not
        # weaken any reject) on every other two-index shape: first index ≠ 0,
        # > 2 indices, non-struct pointee, or a member offset not 8-byte aligned
        # (the BVM cell discipline — `offset_bytes % 8 == 0` per ADR 0018; a
        # packed/sub-cell struct fails loud rather than mis-addressing). The
        # `qal5`/U16 array-GEP case (`[N x iM], ptr %p, i64 0, i64 %i`,
        # variable index, non-struct pointee) is NOT a struct GEP and falls
        # through to the U16 wall below, gate or no gate.
        if ptr_cells && haskey(names, base.ref) && length(ops) == 3
            src_ty_ref_gep = LLVM.API.LLVMGetGEPSourceElementType(inst)
            src_type_gep = LLVM.LLVMType(src_ty_ref_gep)
            src_type_gep isa LLVM.StructType || _ir_error(inst,
                "two-index getelementptr with non-struct source element type " *
                "$(src_type_gep) is not handled under ptr_cells; only " *
                "`%struct.T, ptr %p, i32 0, i32 K` struct-member GEPs lower " *
                "to IRPtrOffset (BVM ADR 0020 D4 / chunk B; gate-off this shape " *
                "hits the Bennett-qal5 / U16 reject)")
            (ops[2] isa LLVM.ConstantInt && _const_int_as_int(ops[2]) == 0) ||
                _ir_error(inst,
                    "two-index struct getelementptr first index must be the " *
                    "constant 0 (single-struct step); got a non-zero / " *
                    "non-constant first index (BVM ADR 0020 D4 / chunk B)")
            ops[3] isa LLVM.ConstantInt || _ir_error(inst,
                "two-index struct getelementptr member index must be a " *
                "compile-time constant; a runtime member index is not a valid " *
                "struct access (BVM ADR 0020 D4 / chunk B)")
            member_k = _const_int_as_int(ops[3])
            dl_gep = LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(inst))))
            offset_bytes = Int(LLVM.offsetof(dl_gep, src_type_gep, member_k))
            offset_bytes % 8 == 0 || _ir_error(inst,
                "two-index struct getelementptr member $(member_k) is at byte " *
                "offset $(offset_bytes), which is not 8-byte (cell) aligned " *
                "— the BVM cell discipline (ADR 0018) requires every struct " *
                "member to land on a 64-bit cell boundary; a packed / sub-cell " *
                "struct is out of scope (BVM ADR 0020 D4 / chunk B)")
            return IRPtrOffset(dest, ssa(names[base.ref]), offset_bytes, 64)
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
        #
        # Bennett-ares — CW-D2 lever 1: under the closed-world / BennettVM cell
        # model (`ptr_cells=true`) a RELAXED-consistency ordering is vacuous
        # (deterministic single-threaded reversible VM — no concurrent observer),
        # so the relaxable band {NotAtomic,Unordered,Monotonic,Acquire,Release}
        # falls through to the existing IRLoad lowering (ptr→cell width 64,
        # integer→width N — no new lowering). Strong orderings (AcquireRelease,
        # SequentiallyConsistent) and `volatile` (an I/O-effect contract, not an
        # ordering one) stay fail-loud. The else-arm (`ptr_cells=false`) is the
        # original U14 guard VERBATIM — circuit-path behaviour is byte-identical
        # (test_4mmt pins the text). The whole ordering check is gated because
        # the integer IRLoad fall-through is itself gate-independent.
        LLVM.API.LLVMGetVolatile(inst) == 0 || _ir_error(inst,
            "volatile load not supported (Bennett-4mmt / U14)")
        if ptr_cells
            _vm_relaxable_ordering(LLVM.API.LLVMGetOrdering(inst)) || _ir_error(inst,
                "atomic load not supported (Bennett-4mmt / U14): the ordering " *
                "is a strong synchronisation edge (AcquireRelease / " *
                "SequentiallyConsistent) that the BennettVM cell model cannot " *
                "honour; only the relaxable band {NotAtomic, Unordered, " *
                "Monotonic, Acquire, Release} is accepted under ptr_cells " *
                "(Bennett-ares / CW-D2 lever 1)")
        else
            LLVM.API.LLVMGetOrdering(inst) == LLVM.API.LLVMAtomicOrderingNotAtomic ||
                _ir_error(inst,
                    "atomic load not supported (Bennett-4mmt / U14)")
        end
        ops = LLVM.operands(inst)
        ptr = ops[1]

        # Bennett-land: load-escape guard. If the load source traces
        # back to an alloca tagged as carrying synthetic-address bytes
        # (via a prior memcpy from a struct-with-ptr-field global),
        # the only safe consumer pattern is to pipe the result into
        # another `llvm.memcpy.*` (i.e. continue carrying the bytes
        # forward, the Rust panic-Location ABI shape). ANY other use —
        # arithmetic, comparison, dereference, return — would
        # silently miscompile because the synthetic 64-bit address is
        # not the real allocator address of the pointee. Fail loud
        # here so the user gets a precise breadcrumb at the load
        # site rather than a garbage simulation result downstream.
        if !isempty(synth_ptr_allocas)
            load_root = _alloca_root_ref(ptr)
            if load_root !== nothing && load_root in synth_ptr_allocas
                # Walk uses; require every use to be an `llvm.memcpy.*`
                # intrinsic call. Anything else fails loud.
                all_memcpy = true
                n_uses = 0
                for use in LLVM.uses(inst)
                    n_uses += 1
                    user_inst = LLVM.user(use)
                    if user_inst isa LLVM.CallInst || (user_inst isa LLVM.Instruction &&
                                                       LLVM.opcode(user_inst) == LLVM.API.LLVMCall)
                        # Last operand of a call is the callee.
                        call_ops = LLVM.operands(user_inst)
                        callee_name = try
                            LLVM.name(call_ops[end])
                        catch e
                            e isa InterruptException && rethrow()
                            ""
                        end
                        if startswith(callee_name, "llvm.memcpy.")
                            continue
                        end
                    end
                    all_memcpy = false
                    break
                end
                if !all_memcpy || n_uses == 0
                    _ir_error(inst,
                        "load through pointer rooted at an alloca that " *
                        "received synthetic-address bytes from a " *
                        "ptr-field ConstantStruct global (via " *
                        "`llvm.memcpy.*` from a Bennett-land-materialised " *
                        "global). The synthetic address (high nibble " *
                        "0x1) is NOT the real allocator address of the " *
                        "pointee; loading these bytes back and using " *
                        "them as an integer / pointer / index would " *
                        "silently miscompile. The only safe consumer " *
                        "pattern is to pipe the load result into " *
                        "another `llvm.memcpy.*` (continue carrying " *
                        "the bytes forward — the Rust panic-Location " *
                        "ABI shape). Got $(n_uses == 0 ? "zero uses" : " " *
                        "a non-memcpy use") instead. (Bennett-land-ptrload)")
                end
            end
        end

        # Bennett-iwo9 / CW-D3 Lever 1: a `load ptr, ptr @"+Type#N"` reading a
        # Julia type-tag global. Recognise BY NAME (never the JIT address in the
        # initializer), mint/look-up a deterministic dense id for the canonical
        # type path, and lower to `IRBinOp(dest, :or, iconst(id), iconst(0), 64)`
        # — a width-64 constant identity (consensus decisions 1+3). Record `dest`
        # in `tag_ssa` so the downstream ptrtoint/inttoptr round-trip is
        # recognised as the sound type-tag pattern. ptr_cells-gated; the pointer
        # operand is a `GlobalVariable` (not a registered SSA name), so this must
        # run BEFORE the `haskey(names, ptr.ref)` block and the generic 64-bit
        # IRLoad / `return nothing` fall-throughs. The `return IRBinOp(...)` here
        # is itself the "no silent fall-through" protection: once a load is
        # recognised as a type-tag-named global it ALWAYS emits the minted
        # identity and never reaches the generic IRLoad. (`_canonical_type_path`
        # supplies the only fail-loud on this path — a malformed `+`-name lacking
        # the `#N` suffix.)
        if ptr_cells && ptr isa LLVM.GlobalVariable
            pname = LLVM.name(ptr)
            if _is_type_tag_global_name(pname)
                canon = _canonical_type_path(pname)   # fail-loud on malformed `+`-names
                id = get!(tag_ids, canon) do
                    Int64(length(tag_ids))            # dense, first-seen order
                end
                push!(tag_ssa, inst.ref)
                return IRBinOp(dest, :or, iconst(Int(id)), iconst(0), 64)
            end
        end

        if haskey(names, ptr.ref)
            rt = LLVM.value_type(inst)
            if rt isa LLVM.IntegerType
                return IRLoad(dest, ssa(names[ptr.ref]), LLVM.width(rt))
            end
            # BVM ADR 0020 D3 (CW-C2 chunk B): under the C-track `ptr_cells`
            # gate, a `load ptr` reads a pointer VALUE = one Int64 VM cell (ADR
            # 0018 §A) — model it as a 64-bit IRLoad. This admits the C
            # heap-pointer surface (`%2 = load ptr, ptr %t`). The gate defaults
            # false, so for the circuit/:heap models a non-integer load keeps the
            # pre-existing silent-skip (`return nothing`) behaviour below — the C
            # cell model never aliases those paths.
            if ptr_cells && rt isa LLVM.PointerType
                return IRLoad(dest, ssa(names[ptr.ref]), 64)
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
            case_op = iconst(case_int)
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
        #
        # Bennett-ares — CW-D2 lever 1: under the closed-world / BennettVM cell
        # model (`ptr_cells=true`) the relaxable band {NotAtomic,Unordered,
        # Monotonic,Acquire,Release} falls through to the existing IRStore
        # lowering (ptr→cell width 64, integer→width N — no new lowering).
        # Strong orderings (AcquireRelease, SequentiallyConsistent) and
        # `volatile` stay fail-loud. The else-arm (`ptr_cells=false`) is the
        # original U14 guard VERBATIM — circuit-path behaviour is byte-identical
        # (test_4mmt pins the text). See the load guard above for the full
        # rationale; both guards are gated identically.
        LLVM.API.LLVMGetVolatile(inst) == 0 || _ir_error(inst,
            "volatile store not supported (Bennett-4mmt / U14)")
        if ptr_cells
            _vm_relaxable_ordering(LLVM.API.LLVMGetOrdering(inst)) || _ir_error(inst,
                "atomic store not supported (Bennett-4mmt / U14): the ordering " *
                "is a strong synchronisation edge (AcquireRelease / " *
                "SequentiallyConsistent) that the BennettVM cell model cannot " *
                "honour; only the relaxable band {NotAtomic, Unordered, " *
                "Monotonic, Acquire, Release} is accepted under ptr_cells " *
                "(Bennett-ares / CW-D2 lever 1)")
        else
            LLVM.API.LLVMGetOrdering(inst) == LLVM.API.LLVMAtomicOrderingNotAtomic ||
                _ir_error(inst,
                    "atomic store not supported (Bennett-4mmt / U14)")
        end
        ops = LLVM.operands(inst)
        val = ops[1]
        ptr = ops[2]
        vt = LLVM.value_type(val)
        # BVM ADR 0020 D3 (CW-C2 chunk B): under the C-track `ptr_cells` gate, a
        # `store ptr %v, ptr %p` stores a pointer VALUE that is one Int64 VM cell
        # (ADR 0018 §A) — model it as a 64-bit IRStore. This admits the C
        # heap-pointer surface (`store ptr %t, ptr %t.addr`, `store ptr %call,
        # ptr %keys`) WITHOUT touching the Julia paths: the gate defaults false,
        # so the Bennett-lgzx / U114 fail-loud below still fires byte-identically
        # for the circuit/:heap models it protects. Width is the cell width (64),
        # not `LLVM.width(vt)` (PointerType has no integer width). The store
        # target `%p` must still be a registered SSA name — same guard as below.
        if ptr_cells && vt isa LLVM.PointerType
            haskey(names, ptr.ref) || _ir_error(inst,
                "store target pointer is not a registered SSA name " *
                "(value=$(ptr)) — likely an unsupported pointer source " *
                "such as a global, ConstantExpr, or alias (Bennett-lgzx / U114).")
            # Bennett-beaw / CW-D: thread `ptr_cells` so a `store ptr null, ptr
            # %obj` field-init (ConstantPointerNull stored value) lowers to the
            # zero cell iconst(0) rather than the U80 fail-loud (null = address
            # 0, one Int64 VM cell).
            return IRStore(ssa(names[ptr.ref]),
                           _operand(val, names; ptr_cells=true), 64)
        end
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
        # Bennett-munq (2026-05-03) accepted `[K x i8]` ArrayType allocas
        # alongside `iN` IntegerType, mapping `alloca [K x i8]` to
        # `IRAlloca(dest, elem_w=8, n_elems=K)`. Bennett-ixiz (2026-05-16)
        # lifted the `LLVM.width(inner) == 8` gate to accept any integer
        # inner width, e.g. `[K x i16]` → `IRAlloca(_, 16, iconst(K))`.
        # Nested ArrayType (`[K x [M x i8]]`) is still silently dropped
        # because the inner of a nested ArrayType is itself ArrayType,
        # not IntegerType (the `inner isa LLVM.IntegerType` guard rejects
        # the nested case). Future-deferred to Bennett-8bys catch-all.
        if elem_ty isa LLVM.ArrayType
            inner = LLVM.eltype(elem_ty)
            inner isa LLVM.IntegerType || return nothing
            n_arr = LLVM.length(elem_ty)
            return IRAlloca(dest, LLVM.width(inner), iconst(n_arr))
        end
        # BVM ADR 0020 D5c (CW-C2 chunk C): `alloca ptr` under the C-track gate.
        # The C local-pointer idiom is `%t.addr = alloca ptr; store ptr %t, ptr
        # %t.addr` — a one-cell slot holding a pointer VALUE. Without this arm
        # the extractor returns `nothing` for the pointer-typed alloca (the
        # silent-skip below), so the matching `store ptr`/`load ptr` (D3) would
        # target a dest with NO prior `IRAlloca` and BVM would see a store to an
        # unallocated cell (worklog-079 / the Bennett-haiy chunk-C assumption).
        # Emit `IRAlloca(dest, 64, 1)` — exactly one 64-bit cell (a pointer is
        # one Int64 VM cell, ADR 0018 §A). An `alloca ptr, i32 N` (a pointer
        # ARRAY) carries the constant/SSA count through the same `n_elems_op`
        # logic as the integer arm. Gate-off: a pointer-typed alloca keeps the
        # pre-existing silent-skip (`return nothing`) — the C cell model never
        # aliases the circuit/:heap alloca paths.
        if ptr_cells && elem_ty isa LLVM.PointerType
            ops = LLVM.operands(inst)
            n_elems_op = if !isempty(ops) && ops[1] isa LLVM.ConstantInt
                iconst(_const_int_as_int(ops[1]))
            elseif !isempty(ops) && haskey(names, ops[1].ref)
                ssa(names[ops[1].ref])
            else
                iconst(1)
            end
            return IRAlloca(dest, 64, n_elems_op)
        end
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

    # Bennett-3ptu — CW-D2 lever: DROP `fence` under the closed-world / BennettVM
    # cell model (`ptr_cells=true`). A `fence` is a pure memory-ordering barrier
    # with NO data effect — it constrains the visibility ordering of OTHER memory
    # ops across threads, but produces no value and mutates no state. In the
    # single-threaded, deterministic, history-reversible BennettVM there is no
    # concurrent observer for the barrier to order against, so the fence is a
    # genuine no-op: dropping it changes nothing and is trivially reversible.
    # `return nothing` is the established "emit no IR for this instruction" signal
    # here (same as the gc_preserve drop above and the silent-skip allocas/loads).
    # Every Julia callee in the fdict closed-world path emits 2 such fences (GC
    # safepoint / write-barrier fences), so this unblocks setindex!/rehash!/
    # ht_keyindex2_shorthash! extraction. Gate-off (`ptr_cells=false`) the fence
    # falls through to the existing "unsupported LLVM opcode" fail-loud below —
    # the circuit path is byte-identical and does NOT silently drop the fence
    # (CLAUDE.md §1). Exact-opcode-scoped: only `fence` is admitted (mirrors the
    # exact-name scoping of the gc_preserve drop in Bennett-zf5v).
    if opc == LLVM.API.LLVMFence
        if ptr_cells
            return nothing
        end
        # ptr_cells=false → fall through to the fail-loud below (no change to
        # circuit-path behaviour).
    end

    _ir_error(inst, "unsupported LLVM opcode")
end

