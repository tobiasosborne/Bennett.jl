# ---- SC9 Case A — the `mem=:vm` Vector recogniser, emit half (ParsedIR) ----
#
# The third part of the Case-A Vector recogniser (ADR 0016; see `vector_vm.jl`
# for the feature docstring, `vector_vm_walk.jl` for the skeleton + element-
# traffic capture). This file assembles the loop-PRESERVING multi-block
# `ParsedIR` (D7): a synthetic ENTRY block carrying the single `DynAlloca`-
# shaped `IRAlloca(dyn)` + the surviving loop-bound setup, then EVERY user /
# loop block walked in program order with skeleton dropped, element traffic
# re-rooted onto the alloca, and throw diamonds collapsed.
#
# # The prelude collapse (the load-bearing CFG decision)
#
# Julia's GC/Memory allocation spans `top … retval` with its own skeleton
# control flow (the `n==0` empty-Memory diamond, the size-overflow throw, the
# Array-wrapper init). The ELEMENT-COUNT operand `%n` is the source argument
# (always live), and the only USER values the prelude computes are the
# loop-bound `icmp`/`xor` in the wrapper block (the block that allocates the
# `julia.gc_alloc_obj` Array object and BRANCHES INTO the loop). So the whole
# prelude COLLAPSES to one synthetic entry block = [IRAlloca(dyn)] + [that
# wrapper block's SURVIVING body instructions] + [its terminator, rerouted past
# throw blocks]. Every prelude predecessor is dropped (an entry has none).
#
# # Ref: docs/adr/0016-case-a-mem-vm-recognizer.md D2/D5/D6/D7; CLAUDE.md §1/§11.

"""
    _vec_vm_extract(func, names, counter, args, ret_width, ret_elem_widths,
                    globals, synth_ptr_provenance) -> ParsedIR

The `mem=:vm` Case-A Vector recogniser entry point. Recognises the single
dynamic `Vector` backing (`vector_vm.jl`), builds the GC/Memory skeleton +
element traffic (`vector_vm_walk.jl`), and emits a loop-preserving multi-block
`ParsedIR`. FAILS LOUD (Rule 1) per the ADR 0016 fail-loud matrix.
"""
function _vec_vm_extract(func::LLVM.Function,
                         names::Dict{_LLVMRef,Symbol},
                         counter::Ref{Int},
                         args::Vector{Tuple{Symbol,Int}},
                         ret_width::Int,
                         ret_elem_widths::Vector{Int},
                         globals::Dict{Symbol,Tuple{Vector{UInt64},Int}},
                         synth_ptr_provenance::Set{Tuple{Symbol,Int,Int}})::ParsedIR
    _assert_memory_layout()
    vb = _vec_vm_recognise(func)
    skel, accesses = _vec_vm_skeleton(func, vb)

    # The synthetic alloca base + the n_operand (the source-arg element count).
    base_sym = Symbol("_vecvm_base#", counter[]); counter[] += 1
    haskey(names, vb.n_arg) ||
        _vec_vm_error("the element-count operand is unnamed — cannot bind the " *
                      "DynAlloca size operand")
    n_sym = names[vb.n_arg]
    W = accesses[1].width
    for a in accesses
        a.width == W ||
            _vec_vm_error("mixed element widths ($(a.width) vs $W) — a " *
                          "non-uniform element type is out of Case-A scope")
    end
    # Re-rooted element accesses, indexed by the store/load instruction ref.
    access_by_inst = Dict{_LLVMRef,_VecAccess}(a.inst => a for a in accesses)

    # Throw / dead blocks (unreachable-terminated) — absorbing sinks; reroute
    # edges past them to the live arm.
    dead = _vec_vm_dead_blocks(func)

    # The prelude-exit (wrapper) block — collapses the whole allocation prelude.
    prelude_exit = _vec_vm_prelude_exit(func, vb)
    prelude_set = _vec_vm_prelude_blocks(func, prelude_exit)

    out = IRBasicBlock[]
    entry_label = Symbol(LLVM.name(first(LLVM.blocks(func))))

    # ---- Synthetic entry block (collapsed prelude). ----
    entry_body = IRInst[IRAlloca(base_sym, W, SSAOperand(n_sym))]
    _vec_vm_emit_body!(entry_body, prelude_exit, func, names, counter, skel,
                       access_by_inst, base_sym, W)
    entry_term = _vec_vm_emit_terminator(prelude_exit, func, names, skel, dead,
                                         prelude_set, prelude_exit)
    push!(out, IRBasicBlock(entry_label, entry_body, entry_term))

    # ---- Every user / loop block (skip prelude + dead). ----
    for bb in LLVM.blocks(func)
        bb === prelude_exit && continue
        bb.ref in dead && continue
        bb.ref in prelude_set && continue
        body = IRInst[]
        # φ-nodes first (block params): rebind incomings from dropped/dead/
        # prelude predecessors onto the surviving (rerouted) predecessor label.
        for inst in LLVM.instructions(bb)
            LLVM.opcode(inst) == LLVM.API.LLVMPHI || continue
            inst.ref in skel && continue
            push!(body, _vec_vm_phi(inst, func, names, dead, prelude_set,
                                    prelude_exit, entry_label))
        end
        _vec_vm_emit_body!(body, bb, func, names, counter, skel,
                           access_by_inst, base_sym, W)
        term = _vec_vm_emit_terminator(bb, func, names, skel, dead, prelude_set,
                                       prelude_exit)
        push!(out, IRBasicBlock(Symbol(LLVM.name(bb)), body, term))
    end

    return ParsedIR(ret_width, args, out, ret_elem_widths, globals, nothing,
                    synth_ptr_provenance)
end
