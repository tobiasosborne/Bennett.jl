# ---- SC9 Case A — the `mem=:vm` Vector recogniser, terminator + φ rebind ----
#
# The terminator rewriter and φ-incoming rebind for the Case-A emit (ADR 0016
# D7; see `vector_vm.jl`). A kept block's terminator is rewritten so each
# successor edge is rerouted past dropped/dead blocks (`_vec_vm_reroute`); a
# conditional `br` on a SKELETON condition collapses to its single live arm,
# while a `br` on a SURVIVING condition (the loop test) is kept. φ-incomings
# from dropped/prelude predecessors are rebound onto the surviving predecessor
# (the synthetic entry), and incomings from dead arms are dropped.
# CLAUDE.md §1 (fail loud), §11.

# Rewrite the terminator of `bb` into an `IRBranch` / `IRRet`, rerouting edges.
function _vec_vm_emit_terminator(bb::LLVM.BasicBlock, func::LLVM.Function,
                                 names::Dict{_LLVMRef,Symbol},
                                 skel::Set{_LLVMRef}, dead::Set{_LLVMRef},
                                 prelude_set::Set{_LLVMRef},
                                 exit::LLVM.BasicBlock)::IRInst
    term = LLVM.terminator(bb)
    term === nothing &&
        _vec_vm_error("block %$(LLVM.name(bb)) has no terminator")
    opc = LLVM.opcode(term)

    if opc == LLVM.API.LLVMRet
        ops = LLVM.operands(term)
        isempty(ops) &&
            _vec_vm_error("surviving `ret void` — Case A expects a value return")
        return IRRet(_operand(ops[1], names), _iwidth(ops[1]))
    elseif opc == LLVM.API.LLVMUnreachable
        _vec_vm_error("surviving `unreachable` in a kept block " *
                      "%$(LLVM.name(bb)) — a throw block was not collapsed")
    elseif opc == LLVM.API.LLVMSwitch || opc == LLVM.API.LLVMIndirectBr
        _vec_vm_error("surviving multi-way branch in %$(LLVM.name(bb)) — out " *
                      "of Case-A scope")
    end
    # `br` — unconditional or conditional.
    if !LLVM.isconditional(term)
        succs = LLVM.successors(term)
        dst = _vec_vm_reroute(succs[1], func, skel, dead, prelude_set, exit)
        return IRBranch(nothing, dst, nothing)
    end
    cond = LLVM.condition(term)
    succs = LLVM.successors(term)          # [true, false]
    # A constant-folded condition (`br i1 false/true, A, B`, e.g. the
    # already-collapsed bounds check `br i1 false`) takes ONE fixed arm.
    if cond isa LLVM.ConstantInt
        taken = _const_int_as_int(cond) != 0 ? succs[1] : succs[2]
        dst = _vec_vm_reroute(taken, func, skel, dead, prelude_set, exit)
        return IRBranch(nothing, dst, nothing)
    end
    t_dead = succs[1].ref in dead
    f_dead = succs[2].ref in dead
    cond_skel = _heap_ref_is_instruction(cond.ref) && cond.ref in skel
    if cond_skel || t_dead || f_dead
        # Collapse to the single live arm (the throw/skeleton diamond). Both
        # arms dead is impossible (the block itself would be dead).
        if t_dead && f_dead
            _vec_vm_error("both arms of %$(LLVM.name(bb)) are dead")
        end
        # The collapsible case is a guard with exactly ONE dead (throw) arm —
        # the bounds / inexact / size-overflow diamond. Its surviving sibling is
        # the in-range path; route to it. A skeleton-conditioned branch whose
        # BOTH arms are LIVE in a KEPT block is a genuine, unrecognised skeleton
        # diamond: we cannot prove which direction the surviving slice should
        # take, and silently picking `succs[1]` would emit the WRONG branch
        # direction for a more complex Vector program (a Rule-1 silent miscompile
        # — the exact failure ADR 0016's fail-loud matrix forbids). The
        # collapsing prelude diamonds (the empty/nonempty Memory test) live in
        # `prelude_set` and are rewritten by `_vec_vm_reroute`, never reaching a
        # KEPT terminator, so this fallthrough means the skeleton taint reached a
        # surviving block — fail loud.
        # Ref: docs/adr/0016-case-a-mem-vm-recognizer.md, fail-loud matrix
        #   ("any instruction the closed-world partition can't classify");
        #   CLAUDE.md Rule 1 (fail loud, never silent-accept). Bead Bennett-bal6.
        if t_dead
            live = succs[2]
        elseif f_dead
            live = succs[1]
        else
            _vec_vm_error("kept block %$(LLVM.name(bb)) ends in a skeleton-" *
                          "conditioned branch (`$(_heap_vname(cond))`) whose " *
                          "BOTH arms are live — an unrecognised skeleton diamond " *
                          "in a surviving block. Cannot prove the branch " *
                          "direction; refusing to guess (would emit the wrong " *
                          "arm for a more complex Vector program)")
        end
        dst = _vec_vm_reroute(live, func, skel, dead, prelude_set, exit)
        return IRBranch(nothing, dst, nothing)
    end
    # Surviving (user / loop) condition — keep the 2-way branch.
    t = _vec_vm_reroute(succs[1], func, skel, dead, prelude_set, exit)
    f = _vec_vm_reroute(succs[2], func, skel, dead, prelude_set, exit)
    return IRBranch(_operand(cond, names), t, f)
end

# Build an `IRPhi` for a surviving join block, rebinding each incoming's
# predecessor label onto the surviving (rerouted) predecessor and dropping
# incomings whose predecessor edge is dead/impossible.
function _vec_vm_phi(inst::LLVM.Instruction, func::LLVM.Function,
                     names::Dict{_LLVMRef,Symbol}, dead::Set{_LLVMRef},
                     prelude_set::Set{_LLVMRef}, exit::LLVM.BasicBlock,
                     entry_label::Symbol)::IRPhi
    dest = names[inst.ref]
    incoming = Tuple{IROperand,Symbol}[]
    for (val, blk) in LLVM.incoming(inst)
        blk.ref in dead && continue            # impossible edge — drop.
        pred = (blk.ref in prelude_set || blk === exit) ?
               entry_label : Symbol(LLVM.name(blk))
        # An `undef`/`poison` φ incoming marks a value that is provably NOT
        # live on this edge (Julia's O0 dead-arm placeholder — the loop guard
        # routes away before it is read). Substitute a placeholder `0`; any
        # value is sound since the consumer never observes it on this path.
        op = (val isa LLVM.UndefValue || val isa LLVM.PoisonValue) ?
             iconst(0) : _operand(val, names)
        push!(incoming, (op, pred))
    end
    isempty(incoming) &&
        _vec_vm_error("φ $(_heap_vname(inst)) has no surviving incoming edge")
    w = LLVM.value_type(inst) isa LLVM.PointerType ? 0 : _iwidth(inst)
    return IRPhi(dest, w, incoming)
end
