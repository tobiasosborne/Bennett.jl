# ---- SC9 Case A — the `mem=:vm` Vector recogniser, CFG helpers ----
#
# CFG-simplification helpers for the Case-A emit (ADR 0016 D7; see
# `vector_vm.jl`). Block classification (dead / prelude), edge rerouting past
# dropped/dead blocks, the surviving-body emitter (with element re-rooting), the
# terminator rewriter (skeleton-diamond collapse + loop-branch preservation),
# and the φ-incoming rebind. CLAUDE.md §1 (fail loud), §2 (reuse heap.jl), §11.

# Dead/throw blocks: `unreachable`-terminated (the size-overflow, inexact, and
# bounds-check throw arms). Edges into them are never taken at runtime (the
# guard proved the access in-range / the value exact), so reroute past them.
function _vec_vm_dead_blocks(func::LLVM.Function)::Set{_LLVMRef}
    dead = Set{_LLVMRef}()
    for bb in LLVM.blocks(func)
        term = LLVM.terminator(bb)
        term === nothing && continue
        # A block with no predecessors (Julia's `after_noret` trap stubs) and an
        # unreachable terminator is also dead.
        LLVM.opcode(term) == LLVM.API.LLVMUnreachable && push!(dead, bb.ref)
    end
    return dead
end

# ---- Bennett-3vf2 / CW-D: DEAD-USE analysis — the dual of the utzc pruner ----
#
# The Bennett-utzc pruner (`module_walk.jl:444-450`) empties every block in
# `dead_blocks`: its body becomes `IRInst[]` and its terminator becomes
# `IRBranch(nothing, :__unreachable__, nothing)`. That gives value flow across
# the live/dead boundary three exhaustive rules:
#
#   defined DEAD, used LIVE  → `_assert_dead_block_no_live_escape` — FAIL LOUD
#                              (the use would dangle after pruning)
#   defined LIVE, used DEAD  → HERE (Bennett-3vf2) — the definition is DROPPABLE:
#                              no emitted IRInst can reference it
#   defined LIVE, used LIVE  → the ordinary path / the 416r.13 reject
#
# **Drop soundness (the theorem).** Let `d` be an instruction in a live block,
# every use of which lies in a block `b ∈ dead_blocks`. The pruner replaces each
# such `b`'s body with `IRInst[]`, so NO `IRInst` in the emitted `ParsedIR`
# references `d`. Emitting nothing for `d` therefore cannot leave a dangling SSA
# operand. If `d` is additionally a non-volatile, non-atomic `load`, it has no
# observable effect either, so the drop is semantics-preserving. ∎
#
# **COUPLING (read before widening `_vec_vm_dead_blocks`).** The theorem is
# parametric in `dead_blocks`: it holds for exactly the set the pruner actually
# EMPTIES. Widening the set above (say, to `llvm.trap`-terminated blocks) widens
# both consistently and stays sound — but if anyone ever makes the pruner KEEP a
# block that is still in `dead_blocks`, the theorem breaks silently. Keep the two
# definitions in lockstep.
#
# **φ corollary (do NOT "fix" this into edge-attribution).** A φ node's use is
# conceptually attributed to its INCOMING EDGE, not to the φ's own block, so a
# naive parent-block test could in principle mis-classify a φ in a live block fed
# from a dead block. That configuration is IMPOSSIBLE here: a block terminated by
# `unreachable` has zero successors, hence is never anybody's predecessor, hence
# never supplies a φ incoming value. So a φ USER in a live block is always a
# genuine live use (→ fail loud) and a φ user in a dead block is a dead use. The
# plain parent-block test is exact.
#
# Conservative in both directions: zero uses ⇒ `false` (a use-less unrecognised
# load is evidence the walker's picture is incomplete, not evidence of a modelled
# construct — refusing costs nothing and CLAUDE.md §1 prefers loud). A non-
# `Instruction` user (no parent block) ⇒ `false`.
function _all_uses_in_dead_blocks(inst::LLVM.Instruction,
                                  dead::Set{_LLVMRef})::Bool
    n = 0
    for u in LLVM.uses(inst)
        n += 1
        usr = LLVM.user(u)
        usr isa LLVM.Instruction || return false
        LLVM.parent(usr).ref in dead || return false
    end
    return n > 0
end

# Diagnostic companion: the label of the first use-site block that is NOT dead
# (i.e. the one that disqualified the drop), or `nothing` if every use is dead /
# there are no uses. Used only to make the 416r.13 reject name the live block.
function _first_live_use_block(inst::LLVM.Instruction,
                               dead::Set{_LLVMRef})::Union{Nothing,String}
    for u in LLVM.uses(inst)
        usr = LLVM.user(u)
        usr isa LLVM.Instruction || return "<non-instruction user>"
        blk = LLVM.parent(usr)
        blk.ref in dead || return LLVM.name(blk)
    end
    return nothing
end

# The prelude-exit block: the LAST allocation-skeleton block, which branches
# INTO the loop. Identified ROBUSTLY (independent of which/how-many GC boxes
# codegen emits) by the loop-bound test it contains: a Julia `for i in 1:n`
# emits a `icmp sle/sgt i64 1, %n` comparing the CONSTANT 1 to the source-arg
# element count `vb.n_arg` (the `1:n` UnitRange start test) in this block, then
# branches to the loop preheader. The block containing that exact icmp is the
# prelude exit. (`icmp slt %value_phi, 1` in the loop body compares a φ, not the
# arg, so it does not match.)
function _vec_vm_prelude_exit(func::LLVM.Function, vb::_VecBacking)::LLVM.BasicBlock
    hit::Union{Nothing,LLVM.BasicBlock} = nothing
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMICmp || continue
        _heap_num_operands(inst) >= 2 || continue
        a = _heap_operand_ref(inst, 1); b = _heap_operand_ref(inst, 2)
        # one operand is the source-arg count, the other is the constant 1.
        is_bound = (a === vb.n_arg && _heap_ref_is_const_int(b) &&
                    _heap_const_int_sval(b) == 1) ||
                   (b === vb.n_arg && _heap_ref_is_const_int(a) &&
                    _heap_const_int_sval(a) == 1)
        is_bound || continue
        hit === nothing ||
            _vec_vm_error("two loop-bound `icmp(1, n)` tests — ambiguous loop " *
                          "preheader (a non-`for i in 1:n` loop shape?)")
        hit = bb
    end
    hit === nothing &&
        _vec_vm_error("no loop-bound `icmp(1, n)` test found — the recognised " *
                      "Vector program is not a `for i in 1:n` write/read loop " *
                      "(out of Case-A scope)")
    return hit
end

# The prelude block set: every block reachable from entry WITHOUT passing
# through `exit` — i.e. the allocation skeleton that collapses into the
# synthetic entry. Computed as forward reachability from entry with `exit` as a
# barrier (its successors enter the user CFG). `exit` itself is NOT included.
function _vec_vm_prelude_blocks(func::LLVM.Function,
                                exit::LLVM.BasicBlock)::Set{_LLVMRef}
    entry = first(LLVM.blocks(func))
    pre = Set{_LLVMRef}()
    work = LLVM.BasicBlock[entry]
    while !isempty(work)
        bb = pop!(work)
        bb === exit && continue
        bb.ref in pre && continue
        push!(pre, bb.ref)
        term = LLVM.terminator(bb)
        term === nothing && continue
        for s in LLVM.successors(term)
            s === exit || push!(work, s)
        end
    end
    delete!(pre, exit.ref)
    return pre
end

# Reroute a successor block to the first block that SURVIVES emission (not in
# `prelude_set`, not `dead`). A skipped block is a dropped skeleton block: its
# terminator is unconditional, or conditional on a skeleton value — follow the
# single live (non-dead) arm. Returns the surviving block's label Symbol.
function _vec_vm_reroute(start::LLVM.BasicBlock, func::LLVM.Function,
                         skel::Set{_LLVMRef}, dead::Set{_LLVMRef},
                         prelude_set::Set{_LLVMRef},
                         exit::LLVM.BasicBlock)::Symbol
    seen = Set{_LLVMRef}()
    bb = start
    while true
        bb.ref in seen &&
            _vec_vm_error("CFG reroute cycle through dropped skeleton blocks " *
                          "(%$(LLVM.name(bb))) — unrecognised allocation CFG")
        push!(seen, bb.ref)
        # A surviving block: the prelude-exit becomes the synthetic ENTRY block,
        # so route to entry's label; any non-prelude, non-dead block survives.
        if bb === exit
            return Symbol(LLVM.name(first(LLVM.blocks(func))))
        end
        if !(bb.ref in prelude_set) && !(bb.ref in dead)
            return Symbol(LLVM.name(bb))
        end
        # Skipped skeleton block — follow its single live successor.
        term = LLVM.terminator(bb)
        term === nothing &&
            _vec_vm_error("dropped block %$(LLVM.name(bb)) has no terminator")
        live = LLVM.BasicBlock[s for s in LLVM.successors(term)
                               if !(s.ref in dead)]
        length(live) == 1 ||
            _vec_vm_error("dropped skeleton block %$(LLVM.name(bb)) has " *
                          "$(length(live)) live successors — a non-collapsible " *
                          "skeleton diamond (expected exactly one live arm)")
        bb = live[1]
    end
end

# Emit the surviving body instructions of `bb` in program order: drop skel,
# re-root element store/load to `IRVarGEP` + `IRStore`/`IRLoad` onto the alloca
# base, convert everything else via the generic `_convert_instruction`.
function _vec_vm_emit_body!(body::Vector{IRInst}, bb::LLVM.BasicBlock,
                            func::LLVM.Function, names::Dict{_LLVMRef,Symbol},
                            counter::Ref{Int}, skel::Set{_LLVMRef},
                            access_by_inst::Dict{_LLVMRef,_VecAccess},
                            base_sym::Symbol, W::Int)
    for inst in LLVM.instructions(bb)
        opc = LLVM.opcode(inst)
        # Terminators handled separately; φ handled by the caller.
        (opc == LLVM.API.LLVMRet || opc == LLVM.API.LLVMBr ||
         opc == LLVM.API.LLVMSwitch || opc == LLVM.API.LLVMIndirectBr ||
         opc == LLVM.API.LLVMUnreachable || opc == LLVM.API.LLVMPHI) && continue
        if haskey(access_by_inst, inst.ref)
            _vec_vm_emit_access!(body, access_by_inst[inst.ref], func, names,
                                 counter, base_sym, W)
            continue
        end
        inst.ref in skel && continue
        ir = _convert_instruction(inst, names, counter)
        ir === nothing && continue
        if ir isa Vector
            append!(body, ir)
        elseif ir isa IRRet || ir isa IRBranch || ir isa IRSwitch
            _vec_vm_error("surviving terminator-class instruction " *
                          "$(_heap_vname(inst)) reached the body emitter")
        else
            push!(body, ir)
        end
    end
    return nothing
end

# Re-root one element access: `IRVarGEP(gep, base, index=%off, W)` then the
# `IRStore`/`IRLoad`. The load keeps its ORIGINAL dest so `ret`/reduce resolve.
function _vec_vm_emit_access!(body::Vector{IRInst}, a::_VecAccess,
                             func::LLVM.Function, names::Dict{_LLVMRef,Symbol},
                             counter::Ref{Int}, base_sym::Symbol, W::Int)
    gep_sym = Symbol("_vecvm_gep#", counter[]); counter[] += 1
    idx_v = _heap_value_for_ref(func, a.index)
    idx_v === nothing &&
        _vec_vm_error("element cell-index operand is unresolved")
    push!(body, IRVarGEP(gep_sym, SSAOperand(base_sym),
                         _operand(idx_v, names), W))
    if a.kind == :store
        val_v = _heap_value_for_ref(func, a.value)
        val_op = val_v === nothing ? _operand(LLVM.Value(a.value), names) :
                 _operand(val_v, names)
        push!(body, IRStore(SSAOperand(gep_sym), val_op, W))
    else
        push!(body, IRLoad(names[a.inst], SSAOperand(gep_sym), W))
    end
    return nothing
end
