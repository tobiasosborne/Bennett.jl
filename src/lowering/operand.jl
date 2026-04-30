# ---- operand resolution ----

function resolve!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                  var_wires::Dict{Symbol,Vector{Int}}, op::IROperand, width::Int)
    if op.kind == :ssa
        haskey(var_wires, op.name) || error("resolve!: undefined SSA variable: %$(op.name)")
        wires = var_wires[op.name]
        # Bennett-cklf / U128: pre-fix the SSA path silently discarded the
        # caller's `width` arg — `wires` was returned regardless of length
        # mismatch. Mismatches downstream produced opaque wire-index errors
        # far from the root cause. Assert the contract loud per CLAUDE.md §1.
        # Pointer-typed operands (width=0) are exempt: pointers carry no
        # width and the caller passes 0 by convention (cf. lower_phi!,
        # lower_select! handling).
        if width != 0 && length(wires) != width
            error("resolve!: SSA operand %$(op.name) has length(wires)=$(length(wires)) " *
                  "but caller advertised width=$width — width contract violated " *
                  "(Bennett-cklf / U128)")
        end
        return wires
    else
        # Bennett-ibz5 / U96: the OPAQUE_PTR_SENTINEL (`IROperand(:const,
        # :__opaque_ptr__, 0)`) is the placeholder `_operand_safe` returns
        # when a pointer value can't be wrapped (unresolvable GlobalAlias
        # chain, ConstantExpr with un-peelable sub-operands). Its value
        # field is 0, so it would otherwise pass through this path and
        # silently materialise as a zero-valued integer constant —
        # treating an opaque pointer as the literal numeric 0. Trip-wire
        # by name (the canonical empty-name `:const` extractor produces
        # uses Symbol("")).
        op.name === :__opaque_ptr__ && error(
            "resolve!: opaque pointer sentinel reached lowering — the " *
            "extractor produced an OPAQUE_PTR_SENTINEL operand for an " *
            "unresolvable pointer value (likely a GlobalAlias chain " *
            "that didn't resolve, or a ConstantExpr with sub-operands " *
            "the extractor couldn't wrap). Compilation cannot proceed " *
            "without a concrete pointer (Bennett-ibz5 / U96).")
        # Bennett-zmw3 / U111: width must be in [1, 64]. Wider widths
        # need a different storage strategy (multi-UInt64 limbs); the IR
        # parser already rejects them but pin the contract here.
        1 <= width <= 64 || error(
            "resolve!: width=$width out of supported range [1, 64] " *
            "(Bennett-zmw3 / U111)")
        wires = allocate!(wa, width)
        # Bennett-zmw3 / U111: previously `op.value & ((1 << width) - 1)`,
        # which at width=64 gave the right answer ONLY because Julia's
        # shift saturation makes `1 << 64 == 0` so `0 - 1 == -1` (all-ones).
        # Replace with the explicit mask helper to remove the
        # shift-saturation reliance — bit-exact at every supported width.
        val = unsigned(op.value) & _wmask(width)
        for i in 1:width
            if (val >> (i - 1)) & UInt64(1) == UInt64(1)
                push!(gates, NOTGate(wires[i]))
            end
        end
        return wires
    end
end

# ==== SSA-level liveness analysis ====

"""
    _ssa_operands(inst::IRInst) -> Vector{Symbol}

Extract all SSA variable names read by an instruction.
"""
function _ssa_operands(inst::IRBinOp)
    ops = Symbol[]
    inst.op1.kind == :ssa && push!(ops, inst.op1.name)
    inst.op2.kind == :ssa && push!(ops, inst.op2.name)
    return ops
end
function _ssa_operands(inst::IRICmp)
    ops = Symbol[]
    inst.op1.kind == :ssa && push!(ops, inst.op1.name)
    inst.op2.kind == :ssa && push!(ops, inst.op2.name)
    return ops
end
function _ssa_operands(inst::IRSelect)
    ops = Symbol[]
    inst.cond.kind == :ssa && push!(ops, inst.cond.name)
    inst.op1.kind == :ssa && push!(ops, inst.op1.name)
    inst.op2.kind == :ssa && push!(ops, inst.op2.name)
    return ops
end
function _ssa_operands(inst::IRCast)
    inst.operand.kind == :ssa ? [inst.operand.name] : Symbol[]
end
function _ssa_operands(inst::IRInsertValue)
    ops = Symbol[]
    inst.agg.kind == :ssa && push!(ops, inst.agg.name)
    inst.val.kind == :ssa && push!(ops, inst.val.name)
    return ops
end
function _ssa_operands(inst::IRExtractValue)
    inst.agg.kind == :ssa ? [inst.agg.name] : Symbol[]
end
function _ssa_operands(inst::IRCall)
    [a.name for a in inst.args if a.kind == :ssa]
end
function _ssa_operands(inst::IRPhi)
    [op.name for (op, _) in inst.incoming if op.kind == :ssa]
end
function _ssa_operands(inst::IRRet)
    inst.op.kind == :ssa ? [inst.op.name] : Symbol[]
end
function _ssa_operands(inst::IRBranch)
    inst.cond !== nothing && inst.cond.kind == :ssa ? [inst.cond.name] : Symbol[]
end
function _ssa_operands(inst::IRPtrOffset)
    inst.base.kind == :ssa ? [inst.base.name] : Symbol[]
end
function _ssa_operands(inst::IRVarGEP)
    ops = Symbol[]
    inst.base.kind == :ssa && push!(ops, inst.base.name)
    inst.index.kind == :ssa && push!(ops, inst.index.name)
    return ops
end
function _ssa_operands(inst::IRLoad)
    inst.ptr.kind == :ssa ? [inst.ptr.name] : Symbol[]
end
function _ssa_operands(inst::IRStore)
    ops = Symbol[]
    inst.ptr.kind == :ssa && push!(ops, inst.ptr.name)
    inst.val.kind == :ssa && push!(ops, inst.val.name)
    return ops
end
function _ssa_operands(inst::IRAlloca)
    inst.n_elems.kind == :ssa ? [inst.n_elems.name] : Symbol[]
end
function _ssa_operands(inst::IRSwitch)
    inst.cond.kind == :ssa ? [inst.cond.name] : Symbol[]
end

"""
    compute_ssa_liveness(parsed::ParsedIR) -> Dict{Symbol, Int}

For each SSA variable (including function arguments), compute the global
instruction index of its last use as an operand. Variables not used by any
instruction get last_use = 0.

Instruction indices are 1-based, counting all instructions across all blocks
in block order (non-terminator instructions first, then terminator).
"""
function compute_ssa_liveness(parsed::ParsedIR)
    last_use = Dict{Symbol, Int}()

    # Initialize: every argument and instruction dest starts at 0
    for (name, _) in parsed.args
        last_use[name] = 0
    end

    # Walk all instructions in block order, assign global indices
    idx = 0
    for block in parsed.blocks
        for inst in block.instructions
            idx += 1
            # Record that this instruction defines a variable
            if hasproperty(inst, :dest)
                get!(last_use, inst.dest, 0)
            end
            # Record uses
            for var in _ssa_operands(inst)
                last_use[var] = idx
            end
        end
        # Terminator
        idx += 1
        for var in _ssa_operands(block.terminator)
            last_use[var] = idx
        end
    end

    return last_use
end

# ==== main lowering entry point ====

