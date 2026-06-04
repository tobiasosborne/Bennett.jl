# ---- SC9 Case A — the `mem=:vm` Vector recogniser, walk + partition half ----
#
# The second half of the Case-A Vector recogniser (ADR 0016; see
# `vector_vm.jl` for the top-of-feature docstring + the structural-recognition
# half). This file builds the GC/Memory SKELETON set, captures the element
# WRITE/READ traffic, and walks the function in program order to emit a
# loop-PRESERVING multi-block `ParsedIR` (D7), dropping skeleton and re-rooting
# element traffic onto a single `DynAlloca`-shaped `IRAlloca(dyn)`.
#
# # CFG simplification (the load-bearing technique for D7)
#
# The Julia GC/Memory allocation spans MANY blocks with its OWN control flow
# (the `n==0` empty-Memory diamond, the GenericMemory-size-overflow throw, the
# Array-wrapper init), and each element access guards a bounds / inexact throw
# diamond. We keep EVERY block but, per block, REWRITE the terminator: a
# successor edge is REROUTED, following only the live (non-throw, non-dead)
# arm, until it reaches the first block that SURVIVES (carries a kept body
# instruction, a φ, or a user terminator). A conditional `br` whose condition
# is a dropped-skeleton value (the size/inexact/bounds guards, the empty-Memory
# test) collapses to its single live successor; a `br` on a SURVIVING condition
# (the loop test) is kept. A throw block (`unreachable` + `j_throw_*`) is an
# absorbing dead sink — an edge into it is impossible at runtime (the guard
# proved in-range) so the OTHER arm is taken. This is the generalisation of
# heap.jl's `_collapse_bounds_diamond` to the whole allocation prelude.
#
# # φ-incomings from dropped predecessor edges are dropped (ADR 0016 D7)
#
# When a φ-join's predecessor block was dropped/rerouted, the φ-incoming for
# that ORIGINAL predecessor is rebound to the rerouted (surviving) predecessor
# label, so the emitted `IRPhi.incoming` names only surviving predecessors —
# the contract the BennettVM ingest's args→params φ-resolution requires.
#
# # Ref: docs/adr/0016-case-a-mem-vm-recognizer.md D2/D5/D6/D7; heap.jl
#   (`_collapse_bounds_diamond`, the partition pattern); CLAUDE.md §1/§2/§11.

# A captured element access: a re-rooted store or load onto the dynamic Vector.
#   kind     — :store | :load
#   inst     — the store/load instruction ref (re-rooted; skipped in the walk).
#   index    — the cell index operand ref (the `mul`'s first operand, %off).
#   value    — :store → the stored value ref; :load → the load result ref
#              (== inst for a load — the load's own SSA dest).
#   width    — element bit width (from the stored value / loaded result type).
struct _VecAccess
    kind::Symbol
    inst::_LLVMRef
    index::_LLVMRef
    value::_LLVMRef
    width::Int
end

# Build the GC/Memory skeleton set: every instruction that is part of the
# dropped allocation machinery. Seeds (heap.jl pattern) + forward taint, but
# element-access addresses + their cell index are EXCLUDED from the taint (they
# are re-rooted, not dropped). Returns `(skel, accesses)`.
function _vec_vm_skeleton(func::LLVM.Function, vb::_VecBacking)
    inst_by_ref = Dict{_LLVMRef,LLVM.Instruction}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst_by_ref[inst.ref] = inst
    end

    # ---- Capture element accesses: a `gep i8 %d, %bo` where %d is a gc_loaded
    #      result and %bo is `mul %off, STRIDE`. The store/load on that addr is
    #      the element traffic; %off is the surviving cell index (D6). ----
    accesses = _VecAccess[]
    elem_addrs = Set{_LLVMRef}()
    index_ops  = Set{_LLVMRef}()       # the surviving %off cell indices.
    byteoff_muls = Set{_LLVMRef}()     # dead `mul %off, STRIDE` intermediates.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_is_gep(inst) || continue
        base = _heap_operand_ref(inst, 1)
        bi = get(inst_by_ref, base, nothing)
        (bi !== nothing && _vec_vm_is_call(bi, _VEC_VM_GC_LOADED)) || continue
        # operand 2 = byte offset = `mul %off, STRIDE`.
        _heap_num_operands(inst) >= 2 || continue
        bo = _heap_operand_ref(inst, 2)
        mi = get(inst_by_ref, bo, nothing)
        (mi !== nothing && LLVM.opcode(mi) == LLVM.API.LLVMMul) ||
            _vec_vm_error("element GEP byte offset is not a `mul` — " *
                          "unrecognised index arithmetic")
        # D6: the mul constant MUST equal the recovered stride. Hardcoding ÷8
        # would miscompile i8/i32 (the b5x trap).
        k = _heap_operand_ref(mi, 2)
        _heap_ref_is_const_int(k) ||
            _vec_vm_error("element byte-offset `mul` multiplicand is not " *
                          "constant — runtime stride out of scope")
        _heap_const_int_sval(k) == vb.stride ||
            _vec_vm_error("element-index `mul` stride $(_heap_const_int_sval(k)) " *
                          "≠ the recovered Memory byte stride $(vb.stride) — D6 " *
                          "stride cross-check failed; refusing to miscompile")
        off = _heap_operand_ref(mi, 1)
        push!(elem_addrs, inst.ref)
        push!(index_ops, off)
        # The byte-offset `mul %off, STRIDE` is a dead intermediate (its only
        # live consumer is the dropped element-address GEP, replaced by an
        # IRVarGEP with cell stride 1). Mark it dropped so no unused multiply
        # survives. `%off` ITSELF survives (the cell index).
        push!(byteoff_muls, bo)
    end

    # Find the store/load on each element address.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        opc = LLVM.opcode(inst)
        if opc == LLVM.API.LLVMStore && _heap_num_operands(inst) >= 2 &&
           _heap_operand_ref(inst, 2) in elem_addrs
            addr = _heap_operand_ref(inst, 2)
            push!(accesses, _VecAccess(:store, inst.ref,
                _vec_vm_index_of(inst_by_ref, addr),
                _heap_operand_ref(inst, 1), _iwidth(LLVM.operands(inst)[1])))
        elseif opc == LLVM.API.LLVMLoad && _heap_num_operands(inst) >= 1 &&
               _heap_operand_ref(inst, 1) in elem_addrs
            addr = _heap_operand_ref(inst, 1)
            push!(accesses, _VecAccess(:load, inst.ref,
                _vec_vm_index_of(inst_by_ref, addr), inst.ref, _iwidth(inst)))
        end
    end
    isempty(accesses) &&
        _vec_vm_error("no element store/load found on the recognised Vector — " *
                      "the element data must be live (Case A reads it back)")

    # ---- Seeds (heap.jl): allocas, the Memory/wrapper allocs, TLS asm,
    #      memset/memcpy/lifetime + gc allocator calls, gc_loaded, pgcstack,
    #      argument_error/inexact throws, and global-address loads. ----
    skel = Set{_LLVMRef}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        opc = LLVM.opcode(inst)
        if opc == LLVM.API.LLVMAlloca
            push!(skel, inst.ref)
        elseif _heap_is_inline_asm_call(inst)
            _heap_is_allowlisted_tls_asm(inst) ? push!(skel, inst.ref) :
                _vec_vm_error("non-allowlisted inline-asm call " *
                              "$(_heap_vname(inst)) — only the x86-64 TLS read " *
                              "is recognised")
        elseif opc == LLVM.API.LLVMLoad && _heap_num_operands(inst) >= 1 &&
               !_heap_ref_is_instruction(_heap_operand_ref(inst, 1))
            push!(skel, inst.ref)        # global-address Memory-header load
        else
            cn = _heap_callee_name(inst)
            if !isempty(cn) && _vec_vm_is_skel_callee(cn)
                push!(skel, inst.ref)
            end
        end
    end

    # Drop the dead byte-offset multiplies (their result feeds only the dropped
    # element-address GEP; the IRVarGEP uses the cell index `%off` directly).
    union!(skel, byteoff_muls)

    # ---- Forward taint to a fixed point: any instruction whose operand is in
    #      skel folds in — EXCEPT (a) terminators, (b) a captured element LOAD
    #      (its address is skeleton but its DEST survives — feeds the reduce),
    #      and (c) the surviving cell index ops (`%off = sub %i,1`, which depend
    #      only on the loop φ, so are never tainted anyway — belt-and-braces).
    #      An element STORE is left to taint naturally (its address GEP is
    #      skeleton); it lands in skel and is re-emitted as `IRStore`. ----
    keep_loads = Set{_LLVMRef}(a.inst for a in accesses if a.kind == :load)
    changed = true
    while changed
        changed = false
        for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
            inst.ref in skel && continue
            opc = LLVM.opcode(inst)
            (opc == LLVM.API.LLVMRet || opc == LLVM.API.LLVMBr ||
             opc == LLVM.API.LLVMSwitch || opc == LLVM.API.LLVMIndirectBr ||
             opc == LLVM.API.LLVMUnreachable) && continue
            inst.ref in keep_loads && continue     # element load dest survives
            inst.ref in index_ops && continue      # surviving cell index
            tainted = any(r -> r in skel, _heap_operand_refs(inst))
            if tainted
                push!(skel, inst.ref)
                changed = true
            end
        end
    end

    # ---- P-callee (ADR 0016 fail-loud matrix; heap.jl §P-callee, lines ~724) --
    # The forward taint folds ANY tainted instruction into `skel`, and the walker
    # then DROPS every `skel` instruction. For a side-effect-free opcode
    # (arithmetic / gep / cast) dropping is sound. But a tainted user CALL — e.g.
    # the Vector pointer passed to a `@noinline` helper `g!(v)` — would be
    # SILENTLY DROPPED, miscompiling away the callee's effects (a Rule-1 silent
    # miscompile, exactly the P-callee failure ADR 0016 forbids). So, mirroring
    # heap.jl's P-callee discipline (Law 2), re-scan every `skel` CALL and reject
    # loud any callee that is NOT on the recognised allowlist. The allowlisted
    # callees fall in two classes (see `_vec_vm_is_skel_callee`): (1) the
    # GC/Memory MACHINERY proper (`jl_alloc_genericmemory_unchecked`,
    # `julia.gc_loaded`, `julia.gc_alloc_obj`/`ijl_gc_small_alloc`,
    # `julia.get_pgcstack`, `jl_argument_error`,
    # `llvm.memcpy/memset/lifetime/smul.with.overflow/trap`), and (2) the
    # DEAD-THROW helpers Julia parks at the unreachable arm of a collapsed
    # bounds/inexact diamond (`ijl_bounds_error_int`, `jl_throw`,
    # `j_throw_boundserror_NNN`, `j_throw_inexacterror_NNN`, …) — REUSED from the
    # project-wide benign-drop allowlist (instructions.jl §U15). The normal
    # fvec/vsum IR carries `@ijl_bounds_error_int` in exactly such a diamond, so
    # it MUST be accepted (the Bennett-msob over-rejection regression). Anything
    # else that ends up tainted touches element/skeleton values and must error.
    # Ref: docs/adr/0016-case-a-mem-vm-recognizer.md, fail-loud matrix (P-callee);
    #   src/extract/heap.jl §P-callee; CLAUDE.md Rule 1/2. Bead Bennett-msob.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel || continue
        LLVM.opcode(inst) == LLVM.API.LLVMCall || continue
        if _heap_is_inline_asm_call(inst)
            _heap_is_allowlisted_tls_asm(inst) ||
                _vec_vm_error("skeleton-tainted inline-asm call " *
                              "$(_heap_vname(inst)) is not the allowlisted x86-64 " *
                              "TLS read — refusing to silently drop it")
            continue
        end
        cn = _heap_callee_name(inst)
        _vec_vm_is_skel_callee(cn) ||
            _vec_vm_error("skeleton-tainted call to `@$(isempty(cn) ? "?" : cn)` " *
                          "($(_heap_vname(inst))) is not an allowlisted Case-A " *
                          "callee — the Vector pointer / element value escapes " *
                          "into non-skeleton code (e.g. a `@noinline` helper or a " *
                          "`push!`). Dropping it would silently miscompile away " *
                          "the callee's effects; refusing to (ADR 0016 P-callee)")
    end
    return skel, accesses
end

# Recover the cell index operand (%off) for an element address (`gep i8 %d,%bo`
# where %bo = `mul %off, STRIDE`).
function _vec_vm_index_of(inst_by_ref::Dict{_LLVMRef,LLVM.Instruction},
                          addr::_LLVMRef)
    gep = inst_by_ref[addr]
    bo = _heap_operand_ref(gep, 2)
    mul = inst_by_ref[bo]
    return _heap_operand_ref(mul, 1)
end

# True iff `cn` is a recognised dropped-skeleton callee (ADR 0016 allowlist).
#
# Two classes of legitimately-dropped callee are accepted:
#
#   (1) the Case-A GC/Memory MACHINERY proper — the Memory allocator, the
#       `julia.gc_loaded` data-pointer launder, the GC-frame allocator/pgcstack,
#       and the benign `llvm.memset/memcpy/lifetime/smul.with.overflow/trap`
#       intrinsics. These are the skeleton this recogniser is built to strip.
#
#   (2) the DEAD-THROW / bounds-error / argument-error helpers Julia emits at
#       the dead arm of a COLLAPSED bounds / inexact diamond. On a recognised
#       in-range access the throwing arm is provably unreachable, so the call
#       never executes; it is dropped, not silently miscompiled. The NORMAL
#       fvec/vsum/fvec32 IR carries `call void @ijl_bounds_error_int(ptr
#       %"box::GenericMemoryRef", i64 %off)` inside exactly such a collapsed
#       diamond — the original (Bennett-msob) allowlist omitted it and
#       OVER-rejected the normal Vector path (it only matched the optimised
#       `j_throw_boundserror_NNN` / `j_throw_inexacterror_NNN` mangled forms,
#       not the unmangled `@ijl_bounds_error_int` / `@jl_throw` runtime entry
#       points). REUSE (Law 2) the project-wide canonical benign-drop allowlist
#       — the throw/bounds prefixes in `_convert_instruction`'s `benign_prefixes`
#       (src/extract/instructions.jl §U15) — verbatim, rather than re-deriving a
#       narrower set here. `_vec_vm_is_dead_throw_callee` is shared with M2/M3.
#
# A genuine user escape (a `@noinline` helper `g!(v)`, a `push!`, a Dict
# `setindex!`) matches NEITHER class and is still rejected loud (P-callee).
# Ref: src/extract/instructions.jl §U15 benign_prefixes; heap.jl §P-callee.
#   Bennett-msob (over-rejection regression fix).
function _vec_vm_is_skel_callee(cn::AbstractString)
    cn in (_VEC_VM_MEM_ALLOC, _VEC_VM_GC_LOADED, _VEC_VM_GC_ALLOC_OBJ,
           _VEC_VM_GC_ALLOC_OBJ2, _VEC_VM_PGCSTACK, _VEC_VM_ARGERR) && return true
    startswith(cn, "llvm.memset.") && return true
    startswith(cn, "llvm.memcpy.") && return true
    startswith(cn, "llvm.lifetime.") && return true
    startswith(cn, "llvm.smul.with.overflow.") && return true
    startswith(cn, "llvm.trap") && return true
    _vec_vm_is_dead_throw_callee(cn) && return true
    return false
end

# True iff `cn` is a dead-throw / bounds-error / argument-error helper that
# Julia emits at the (provably unreachable) throwing arm of a collapsed bounds
# or inexact diamond. The prefixes/regexes are REUSED verbatim from the
# project-wide canonical benign-drop allowlist
# (`_convert_instruction`'s `benign_prefixes`, src/extract/instructions.jl §U15)
# plus the M2 mangled-form regexes. Matching the `j_throw_*` prefix subsumes
# both `_GC_THROW_BOUNDSERROR_RE` (`j_throw_boundserror_NNN`) and
# `_VEC_VM_INEXACT_RE` (`j_throw_inexacterror_NNN`); the unmangled
# `ijl_bounds_error*` / `jl_bounds_error*` / `ijl_throw` / `jl_throw` runtime
# entry points are the ones the unoptimised normal Vector path actually emits.
function _vec_vm_is_dead_throw_callee(cn::AbstractString)
    startswith(cn, "j_throw_")        && return true
    startswith(cn, "ijl_throw")       && return true
    startswith(cn, "jl_throw")        && return true
    startswith(cn, "ijl_bounds_error") && return true
    startswith(cn, "jl_bounds_error")  && return true
    startswith(cn, "ijl_argument_error") && return true
    startswith(cn, "jl_argument_error")  && return true
    return false
end
