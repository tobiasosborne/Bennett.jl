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
    _alloca_elem_width_bits(alloca_ref) -> Int

Returns the alloca's element width in bits, or 0 if the allocated type
is not a Bennett-supported integer-or-byte-array shape (struct, ptr,
nested array, wider-element ArrayType).

Supported shapes (Bennett-munq, 2026-05-03):
  - `iN` IntegerType — returns N.
  - `[K x i8]` ArrayType wrapping i8 — returns 8 (matches the Rust
    frontend's canonical `alloca [K x i8]` shape; pre-munq this
    returned 0 and gated Phase 1/2 off the t5 corpus entirely).

Wider ArrayType inner widths (`[K x i16]`, `[K x i64]`) and nested
ArrayType (`[K x [M x i8]]`) return 0 and are deferred to
Bennett-ixiz / future follow-ups.
"""
function _alloca_elem_width_bits(alloca_ref::_LLVMRef)::Int
    elem_ty = LLVM.LLVMType(LLVM.API.LLVMGetAllocatedType(alloca_ref))
    if elem_ty isa LLVM.IntegerType
        return LLVM.width(elem_ty)
    end
    if elem_ty isa LLVM.ArrayType
        inner = LLVM.eltype(elem_ty)
        inner isa LLVM.IntegerType && LLVM.width(inner) == 8 || return 0
        return 8
    end
    return 0
end

"""
    _handle_memcpy_arm(cname, inst, names, counter, ops) -> Vector{IRInst}

Bennett-37mt Phase 1: const-size memcpy between two distinct
`alloca i8`-backed pointer ranges, lowered as N byte-granular chunks
(IRPtrOffset src + IRPtrOffset dst + IRLoad width=8 + IRStore width=8).
Out-of-scope shapes fail loud with a precise message naming the
appropriate downstream bead (`Bennett-8bys` for the catch-all,
`Bennett-haod` for global-variable source pointers).

Predicates checked, in order, so the earliest mismatch produces the
most actionable error:

  1. addrspace 0 only (cname must be `llvm.memcpy.p0.p0.*`)
  2. `isvolatile == false`
  3. N is a `ConstantInt` (≥ 0)
  4. N == 0 → return `IRInst[]` (legal no-op)
  5. neither operand is a global variable
  6. both operands trace to an alloca (direct or via const-offset GEP)
  7. distinct alloca roots (rejects `memcpy(p, p, N)` self-copy)
  8. both alloca's element width is 8 bits
"""
function _handle_memcpy_arm(cname::AbstractString, inst::LLVM.Instruction,
                            names::Dict{_LLVMRef, Symbol}, counter::Ref{Int}, ops)
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

    # Predicate 5: globals out of scope. The Bennett-8bys catch-all
    # explicitly enumerates "Global-pointer src memcpy" as a sub-case
    # (see its description). The bead body for 37mt mentions a
    # placeholder "haod" sub-bead, but it was never filed; users should
    # track this under 8bys.
    if LLVM.API.LLVMIsAGlobalVariable(dst_v.ref) != C_NULL ||
       LLVM.API.LLVMIsAGlobalVariable(src_v.ref) != C_NULL
        which = LLVM.API.LLVMIsAGlobalVariable(dst_v.ref) != C_NULL ? "dst" : "src"
        _ir_error(inst,
            "$(cname): memcpy with a global-variable pointer ($(which) " *
            "operand) is not yet supported. Constant-source memcpy needs " *
            "QROM-style fan-out for the read side. Tracked in Bennett-8bys " *
            "(catch-all, sub-case: \"Global-pointer src memcpy\"). " *
            "(Bennett-37mt Phase 1 — alloca-backed pointers only)")
    end

    # Predicate 6: both pointers must trace back to an alloca.
    dst_root = _alloca_root_ref(dst_v)
    src_root = _alloca_root_ref(src_v)
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

    # Predicate 8: both allocas must have element width 8 bits.
    dst_ew = _alloca_elem_width_bits(dst_root)
    src_ew = _alloca_elem_width_bits(src_root)
    if dst_ew != 8 || src_ew != 8
        _ir_error(inst,
            "$(cname): memcpy operand alloca has element width " *
            "(dst=$(dst_ew == 0 ? "non-integer" : string(dst_ew)) bits, " *
            "src=$(src_ew == 0 ? "non-integer" : string(src_ew)) bits); " *
            "Bennett-37mt Phase 1 supports byte-granularity (`alloca i8, " *
            "i32 N`) only. Wider-element allocas need extended " *
            "ptr_provenance propagation in src/lowering/aggregate.jl " *
            "(currently `ew == 8 || continue` at line 227) and a wider " *
            "shadow-store path in src/lowering/memory.jl. Tracked in " *
            "Bennett-8bys. (Bennett-37mt Phase 1)")
    end

    # Operand resolution: both operand SSA names must be in the table.
    haskey(names, dst_v.ref) || _ir_error(inst,
        "$(cname): memcpy dst pointer is not a named SSA value. " *
        "(Bennett-37mt Phase 1)")
    haskey(names, src_v.ref) || _ir_error(inst,
        "$(cname): memcpy src pointer is not a named SSA value. " *
        "(Bennett-37mt Phase 1)")
    dst_op = ssa(names[dst_v.ref])
    src_op = ssa(names[src_v.ref])

    # Expansion: N byte-granular IRPtrOffset+IRPtrOffset+IRLoad+IRStore quads.
    out = IRInst[]
    sizehint!(out, 4 * N)
    for k in 0:(N - 1)
        src_off = _auto_name(counter)
        dst_off = _auto_name(counter)
        tmp     = _auto_name(counter)
        push!(out, IRPtrOffset(src_off, src_op, k))
        push!(out, IRPtrOffset(dst_off, dst_op, k))
        push!(out, IRLoad(tmp, ssa(src_off), 8))
        push!(out, IRStore(ssa(dst_off), ssa(tmp), 8))
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
    _handle_memset_arm(cname, inst, names, counter, ops) -> Vector{IRInst}

Bennett-9nwt Phase 2: const-c const-N memset on alloca-i8-backed
destination. Two green cases:

  - Case A (c == 0, any dst): silent drop (`IRInst[]`). Preserves
    pre-9nwt benign-allowlist behaviour for Julia GC-frame zeroing
    patterns. NO alloca/freshness check on this path; tightening would
    risk regressing unaudited Julia frontend output. Acknowledged §1
    hazard for c=0 on non-fresh dst — tracked under
    Bennett-8bys-uncompute.

  - Case C (c != 0, fresh alloca-i8 dst): emit N byte-granular
    `IRPtrOffset + IRStore(ConstOperand(c), 8)` pairs.

All other shapes fail loud naming Bennett-8bys (catch-all) or
Bennett-8bys-uncompute (non-fresh dst with c≠0).

Predicate cascade (earliest mismatch → most actionable error):

  1. addrspace 0 — `llvm.memset.p0.*` or `llvm.memset.inline.p0.*`
  2. operand count >= 5 (4 args + callee)
  3. isvolatile (4th op) is `i1` ConstantInt 0
  4. fill byte c (2nd op) is ConstantInt
  5. byte count N (3rd op) is ConstantInt
  6. N >= 0
  7. N == 0 → return `IRInst[]` (LangRef no-op)
  8. c == 0 → return `IRInst[]` (case A — preserve broad tolerance)
  9. dst is named SSA in `names`
 10. dst is not a global variable
 11. dst alloca-rooted via `_alloca_root_ref`
 12. alloca elem_w == 8
 13. dst alloca is fresh per `_alloca_is_fresh` (option γ)
"""
function _handle_memset_arm(cname::AbstractString, inst::LLVM.Instruction,
                            names::Dict{_LLVMRef, Symbol}, counter::Ref{Int}, ops)
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

    # Predicate 3: isvolatile must be a ConstantInt with value 0.
    vol_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): isvolatile arg is not an i1 immarg constant " *
        "(value=$(string(vol_v))). LangRef requires an immarg here; " *
        "malformed IR. (Bennett-9nwt Phase 2)")
    _const_int_as_int(vol_v) == 0 || _ir_error(inst,
        "$(cname): volatile memset is not supported. Bennett.jl's " *
        "reversible model has no observable side-effect ordering for " *
        "memory; volatile semantics cannot be honoured. Recompile " *
        "without the volatile attribute, or wait on Bennett-8bys " *
        "(catch-all). (Bennett-9nwt Phase 2)")

    # Predicate 4: fill byte must be a ConstantInt.
    c_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): memset with non-constant fill byte is not supported. " *
        "Variable c needs runtime broadcasting that the byte-granular " *
        "IRStore-of-ConstOperand path cannot express. Tracked in " *
        "Bennett-8bys. (Bennett-9nwt Phase 2 — const-c only)")

    # Predicate 5: byte count must be a ConstantInt.
    n_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): memset with non-constant byte count is not supported. " *
        "Variable-size memset requires runtime-bounded loop unrolling, " *
        "same gap as variable-size memcpy. Tracked in Bennett-8bys. " *
        "(Bennett-9nwt Phase 2 — const-N only)")
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

    # Predicate 12: alloca element width must be 8 bits.
    dst_ew = _alloca_elem_width_bits(dst_root)
    dst_ew == 8 || _ir_error(inst,
        "$(cname): memset dst alloca has element width " *
        "$(dst_ew == 0 ? "non-integer" : string(dst_ew)) bits; " *
        "Bennett-9nwt Phase 2 supports byte-granularity (`alloca i8, " *
        "i32 N`) only. Wider-element allocas need a wider shadow-store " *
        "path in src/lowering/memory.jl, same gap as memcpy on " *
        "alloca-i64. Tracked in Bennett-8bys. (Bennett-9nwt Phase 2)")

    # Predicate 13: freshness (intra-block sweep). Non-fresh dst would
    # XOR-overlay c onto existing data instead of cleanly setting it,
    # producing wrong results that `verify_reversibility` doesn't catch.
    _alloca_is_fresh(dst_root, inst) || _ir_error(inst,
        "$(cname): memset dst alloca has prior IR-visible writes within " *
        "this basic block (non-fresh dst). Reversibility forbids " *
        "destructive overwrite without first uncomputing the existing " *
        "slot bits via CNOT-uncompute. Tracked in " *
        "Bennett-8bys-uncompute. (Bennett-9nwt Phase 2 — fresh-dst only)")

    # Case C expansion: N byte-granular IRPtrOffset+IRStore pairs at width=8.
    dst_op = ssa(names[dst_v.ref])
    out = IRInst[]
    sizehint!(out, 2 * N)
    for k in 0:(N - 1)
        dst_off = _auto_name(counter)
        push!(out, IRPtrOffset(dst_off, dst_op, k))
        push!(out, IRStore(ssa(dst_off), iconst(c_int), 8))
    end
    return out
end

# Bennett-tzrs / U41 (first-cut, 2026-04-27): the LLVM-intrinsic prefix
# dispatch was lifted out of `_convert_instruction`'s 836-line body into
# this helper. Order of `if startswith(cname, "...")` branches is LOAD-
# BEARING — `llvm.minnum` / `llvm.minimum` and `llvm.maxnum` / `llvm.maximum`
# share handlers via prefix-match, and the floor/ceil/trunc/rint/round
# branch is INTENTIONALLY a no-op (it lets the registered-callee path in
# `_convert_instruction` pick up `soft_floor` / `soft_ceil` / etc. via
# the SoftFloat dispatch). Returns `nothing` if no intrinsic matched —
# the call site then proceeds to the registered-callee lookup and the
# benign-allowlist guard. Per CLAUDE.md §2 this is part of the 3+1-mandated
# tzrs refactor (proposers: A and B; orchestrator: tobias 2026-04-27).
function _handle_intrinsic(cname::AbstractString, inst::LLVM.Instruction,
                           names::Dict{_LLVMRef, Symbol}, counter::Ref{Int},
                           dest::Symbol, ops)
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
    if startswith(cname, "llvm.fshr")
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
    # Intentionally NO return: the registered-callee path in
    # `_convert_instruction` picks these up via SoftFloat dispatch
    # (`soft_floor` / `soft_ceil` / `soft_trunc` are registered callees).
    # Falling through to the next `if` keeps the original semantics.
    if startswith(cname, "llvm.floor") || startswith(cname, "llvm.ceil") ||
       startswith(cname, "llvm.trunc") || startswith(cname, "llvm.rint") ||
       startswith(cname, "llvm.round")
        # No-op: handled by callee registry
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
    if startswith(cname, "llvm.sqrt")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.sqrt: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-1pb)")
        return IRCall(dest, soft_fsqrt, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.exp2")
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
    if startswith(cname, "llvm.fma") || startswith(cname, "llvm.fmuladd")
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
    if startswith(cname, "llvm.exp")
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
    if startswith(cname, "llvm.log10")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log10: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log10, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.log2")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log2: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log2, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.log")
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
    if startswith(cname, "llvm.powi")
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
    if startswith(cname, "llvm.pow")
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
    if startswith(cname, "llvm.memmove")
        _ir_error(inst,
            "$(cname): memmove is not yet lowered to reversible gates. " *
            "Memmove permits src/dst overlap and reversibility forbids " *
            "destructive in-place overwrite, so static disjointness is " *
            "required and Bennett.jl has no alias analysis to prove it. " *
            "Tracked in Bennett-8bys (Phase 3: byte-granularity / " *
            "variable-size / overlap / memmove). " *
            "(Bennett-37mt Phase 1 — memmove deferred to Bennett-8bys)")
    end
    if startswith(cname, "llvm.memcpy")
        return _handle_memcpy_arm(cname, inst, names, counter, ops)
    end
    # Bennett-hao Phase 2 (Bennett-9nwt): const-c const-N memset on
    # alloca-i8-backed dst lowers to byte-granular IRPtrOffset+IRStore
    # pairs with ConstOperand(c) at width=8. c=0 takes a separate
    # silent-drop fast path that preserves pre-9nwt benign behaviour.
    if startswith(cname, "llvm.memset")
        return _handle_memset_arm(cname, inst, names, counter, ops)
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
            handled = _handle_intrinsic(cname, inst, names, counter, dest, ops)
            handled === nothing || return handled
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
        # Bennett-munq (2026-05-03): accept `[K x i8]` ArrayType allocas
        # in addition to `iN` IntegerType. Maps `alloca [K x i8]` to
        # `IRAlloca(dest, elem_w=8, n_elems=K)` — same downstream shape
        # as `alloca i8, i32 K`, which the existing memory pipeline
        # already supports. Other ArrayType inner widths (`[K x i16]`,
        # etc.) and nested ArrayType (`[K x [M x i8]]`) still return
        # nothing and are deferred to Bennett-ixiz / future follow-ups.
        if elem_ty isa LLVM.ArrayType
            inner = LLVM.eltype(elem_ty)
            inner isa LLVM.IntegerType && LLVM.width(inner) == 8 || return nothing
            n_arr = LLVM.length(elem_ty)
            return IRAlloca(dest, 8, iconst(n_arr))
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

    _ir_error(inst, "unsupported LLVM opcode")
end

