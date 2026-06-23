# ---- Bit-width narrowing of ParsedIR (Bennett-19g6 extracted from Bennett.jl) ----
#
# Used by `reversible_compile(f, T; bit_width=W)` to compile functions written
# for Int8 as if they operated on W-bit integers. All arithmetic wraps mod 2^W.

"""
    _narrow_ir(parsed::ParsedIR, W::Int) -> ParsedIR

Narrow all widths in a ParsedIR to W bits. This enables compiling
functions written for Int8 as if they operated on W-bit integers.
All arithmetic wraps modulo 2^W.
"""
function _narrow_ir(parsed::ParsedIR, W::Int)
    new_args = [(name, W) for (name, _) in parsed.args]
    new_blocks = IRBasicBlock[]
    for block in parsed.blocks
        new_insts = IRInst[]
        for inst in block.instructions
            push!(new_insts, _narrow_inst(inst, W))
        end
        new_term = _narrow_inst(block.terminator, W)
        push!(new_blocks, IRBasicBlock(block.label, new_insts, new_term))
    end
    return ParsedIR(W, new_args, new_blocks, [W for _ in parsed.ret_elem_widths])
end

# i1 boolean values (from icmp, short-circuit &&/||, boolean ternaries) must
# stay i1 under narrowing — the width is logical, not numeric. Matches the
# IRPhi / IRCast guard.
_narrow_inst(inst::IRBinOp, W::Int) = IRBinOp(inst.dest, inst.op, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRICmp, W::Int) = IRICmp(inst.dest, inst.predicate, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRSelect, W::Int) = inst.width == 0 ? inst :
    IRSelect(inst.dest, inst.cond, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRCast, W::Int) = IRCast(inst.dest, inst.op, inst.operand,
                                             inst.from_width > 1 ? W : 1,
                                             inst.to_width > 1 ? W : 1)
# Bennett-nd45: the void IRRet form (`op === nothing`, the C `ret void` shape)
# carries no value to narrow — pass it through unchanged. The C `ptr_cells`
# path never runs the circuit width-narrowing pass, so this is defensive
# totality, not a reached path.
_narrow_inst(inst::IRRet, W::Int) = inst.op === nothing ? inst : IRRet(inst.op, W)
_narrow_inst(inst::IRPhi, W::Int) = inst.width == 0 ? inst :
    IRPhi(inst.dest, inst.width > 1 ? W : 1, inst.incoming)
_narrow_inst(inst::IRBranch, W::Int) = inst  # branches don't have widths
# Bennett-6bu3: these were broken-but-dead (behind the bit_width>0 narrowing
# path, which is mutually exclusive with the aggregate/StructType path) — the
# pre-6bu3 forms referenced a nonexistent `inst.elem_count` field and called a
# 4-arg IRExtractValue ctor that never existed. Repaired to the real ctors.
# StructType aggregates (non-empty field_widths) are a ptr-cell-only shape that
# the circuit-width narrowing pass never touches; pass field_widths through
# unchanged so a struct node round-trips totally (defensive, not a reached path).
_narrow_inst(inst::IRInsertValue, W::Int) =
    isempty(inst.field_widths) ?
        IRInsertValue(inst.dest, inst.agg, inst.val, inst.index, W, inst.n_elems) :
        inst
_narrow_inst(inst::IRExtractValue, W::Int) =
    isempty(inst.field_widths) ?
        IRExtractValue(inst.dest, inst.agg, inst.index, W, inst.n_elems) :
        inst
_narrow_inst(inst::IRCall, W::Int) = inst  # calls handle their own widths
# IRStore/IRAlloca: preserve i1 widths like the other narrow methods; n_elems
# is a count, not a bit-width, so it passes through.
_narrow_inst(inst::IRStore, W::Int) = IRStore(inst.ptr, inst.val,
                                              inst.width > 1 ? W : 1)
_narrow_inst(inst::IRAlloca, W::Int) = IRAlloca(inst.dest,
                                                inst.elem_width > 1 ? W : 1,
                                                inst.n_elems)
# Bennett-xv0u / bennettvm-b5x: IRPtrOffset has no operand BIT width to
# narrow — `offset_bytes` is a byte offset and `elem_width` is the SOURCE
# element's own bit width (used by BennettVM's element-index recovery), not
# the routine's narrowable wire width. Pass through unchanged. (Closes the
# pre-existing fail-loud-fallback gap for IRPtrOffset noted at Bennett-2unc.)
_narrow_inst(inst::IRPtrOffset, W::Int) = inst
# Bennett-2unc / U85: Fail loud per CLAUDE.md §1. The pre-fix
# fallback `_narrow_inst(inst::IRInst, W::Int) = inst` silently
# passed through any IR node type without an explicit method, which
# meant a function containing IRPtrOffset / IRVarGEP / IRLoad /
# IRSwitch (the four IRInst subtypes still missing explicit methods)
# would narrow to a circuit where those instructions retained their
# pre-narrow widths — producing wire-width mismatches downstream
# with no clear root cause. If you hit this error, add an explicit
# `_narrow_inst(inst::IRYourType, W::Int) = ...` method here.
function _narrow_inst(inst::IRInst, W::Int)
    error("_narrow_inst: no method for $(typeof(inst)) — narrowing is " *
          "not yet supported for this IR node type. Add an explicit " *
          "_narrow_inst handler in src/narrow.jl, or compile without " *
          "the `bit_width` kwarg. (Bennett-2unc / U85)")
end
