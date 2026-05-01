# ---- operand resolution (Bennett-v958 / U68: multi-dispatch on IROperand) ----

function resolve!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                  var_wires::Dict{Symbol,Vector{Int}}, op::SSAOperand, width::Int)
    haskey(var_wires, op.name) || throw(AssertionError("resolve!: undefined SSA variable: %$(op.name)"))
    wires = var_wires[op.name]
    # Bennett-cklf / U128: pre-fix the SSA path silently discarded the
    # caller's `width` arg — `wires` was returned regardless of length
    # mismatch. Mismatches downstream produced opaque wire-index errors
    # far from the root cause. Assert the contract loud per CLAUDE.md §1.
    # Pointer-typed operands (width=0) are exempt: pointers carry no
    # width and the caller passes 0 by convention (cf. lower_phi!,
    # lower_select! handling).
    if width != 0 && length(wires) != width
        throw(DimensionMismatch("resolve!: SSA operand %$(op.name) has length(wires)=$(length(wires)) " *
              "but caller advertised width=$width — width contract violated " *
              "(Bennett-cklf / U128)"))
    end
    return wires
end

function resolve!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                  var_wires::Dict{Symbol,Vector{Int}}, op::ConstOperand, width::Int)
    # Bennett-zmw3 / U111: width must be in [1, 64]. Wider widths
    # need a different storage strategy (multi-UInt64 limbs); the IR
    # parser already rejects them but pin the contract here.
    1 <= width <= 64 || throw(ArgumentError(
        "resolve!: width=$width out of supported range [1, 64] " *
        "(Bennett-zmw3 / U111)"))
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

# Bennett-ibz5 / U96: opaque pointer tripwire. The extractor produces
# OPAQUE_PTR_SENTINEL when a pointer value can't be wrapped (unresolvable
# GlobalAlias chain, ConstantExpr with un-peelable sub-operands). It must
# not silently materialise as a numeric constant. Now type-driven, no
# Symbol pun.
function resolve!(::Vector{ReversibleGate}, ::WireAllocator,
                  ::Dict{Symbol,Vector{Int}}, ::OpaquePtrSentinel, ::Int)
    throw(AssertionError("resolve!: opaque pointer sentinel reached lowering — the " *
          "extractor produced an OPAQUE_PTR_SENTINEL for an unresolvable " *
          "pointer value (likely a GlobalAlias chain that didn't resolve, " *
          "or a ConstantExpr with sub-operands the extractor couldn't " *
          "wrap). Compilation cannot proceed without a concrete pointer " *
          "(Bennett-ibz5 / U96)."))
end

# Catch-all for any other IROperand subtype (PoisonLaneSentinel,
# ZeroAggSentinel, PendingVecLane, plus any future sentinel). These must
# be consumed by their specialised lowering paths before resolve! sees
# them; if one reaches here it's a missing lowering case, not a numeric
# constant. Fail loud per CLAUDE.md §1 (Bennett-v958 / U68).
function resolve!(::Vector{ReversibleGate}, ::WireAllocator,
                  ::Dict{Symbol,Vector{Int}}, op::IROperand, ::Int)
    throw(AssertionError("resolve!: $(typeof(op)) reached lowering — this operand kind " *
          "is an extractor-internal placeholder and must be consumed by " *
          "its specialised lowering path before resolve! sees it " *
          "(Bennett-v958 / U68)."))
end

# ==== SSA-level liveness analysis ====

# Tiny per-operand helper: returns the SSA name carried by an operand, or
# an empty tuple for non-SSA operands. The fallback `::IROperand` covers
# every ConstOperand and every sentinel with one zero-cost method.
@inline _ssa_names(::IROperand)        = ()
@inline _ssa_names(op::SSAOperand)     = (op.name,)

"""
    _ssa_operands(inst::IRInst) -> Vector{Symbol}

Extract all SSA variable names read by an instruction.
"""
_ssa_operands(inst::IRBinOp)       = Symbol[_ssa_names(inst.op1)..., _ssa_names(inst.op2)...]
_ssa_operands(inst::IRICmp)        = Symbol[_ssa_names(inst.op1)..., _ssa_names(inst.op2)...]
_ssa_operands(inst::IRSelect)      = Symbol[_ssa_names(inst.cond)..., _ssa_names(inst.op1)..., _ssa_names(inst.op2)...]
_ssa_operands(inst::IRCast)        = Symbol[_ssa_names(inst.operand)...]
_ssa_operands(inst::IRInsertValue) = Symbol[_ssa_names(inst.agg)..., _ssa_names(inst.val)...]
_ssa_operands(inst::IRExtractValue) = Symbol[_ssa_names(inst.agg)...]
_ssa_operands(inst::IRCall)        = Symbol[n for a in inst.args for n in _ssa_names(a)]
_ssa_operands(inst::IRPhi)         = Symbol[n for (op, _) in inst.incoming for n in _ssa_names(op)]
_ssa_operands(inst::IRRet)         = Symbol[_ssa_names(inst.op)...]
_ssa_operands(inst::IRBranch)      = inst.cond === nothing ? Symbol[] : Symbol[_ssa_names(inst.cond)...]
_ssa_operands(inst::IRPtrOffset)   = Symbol[_ssa_names(inst.base)...]
_ssa_operands(inst::IRVarGEP)      = Symbol[_ssa_names(inst.base)..., _ssa_names(inst.index)...]
_ssa_operands(inst::IRLoad)        = Symbol[_ssa_names(inst.ptr)...]
_ssa_operands(inst::IRStore)       = Symbol[_ssa_names(inst.ptr)..., _ssa_names(inst.val)...]
_ssa_operands(inst::IRAlloca)      = Symbol[_ssa_names(inst.n_elems)...]
_ssa_operands(inst::IRSwitch)      = Symbol[_ssa_names(inst.cond)...,
                                            (n for (case_op, _) in inst.cases for n in _ssa_names(case_op))...]

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

