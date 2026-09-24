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

# ==== SSA operand occurrences + in-place (Cuccaro) eligibility ====

# Tiny per-operand helper: returns the SSA name carried by an operand, or
# an empty tuple for non-SSA operands. The fallback `::IROperand` covers
# every ConstOperand and every sentinel with one zero-cost method.
@inline _ssa_names(::IROperand)        = ()
@inline _ssa_names(op::SSAOperand)     = (op.name,)

"""
    _ssa_operands(inst::IRInst) -> Vector{Symbol}

Extract all SSA variable names read by an instruction — one entry per
operand OCCURRENCE (`add %x, %x` yields `[:x, :x]`).
"""
_ssa_operands(inst::IRBinOp)       = Symbol[_ssa_names(inst.op1)..., _ssa_names(inst.op2)...]
_ssa_operands(inst::IRICmp)        = Symbol[_ssa_names(inst.op1)..., _ssa_names(inst.op2)...]
_ssa_operands(inst::IRSelect)      = Symbol[_ssa_names(inst.cond)..., _ssa_names(inst.op1)..., _ssa_names(inst.op2)...]
_ssa_operands(inst::IRCast)        = Symbol[_ssa_names(inst.operand)...]
_ssa_operands(inst::IRInsertValue) = Symbol[_ssa_names(inst.agg)..., _ssa_names(inst.val)...]
_ssa_operands(inst::IRInsertBits)  = Symbol[_ssa_names(inst.agg)..., _ssa_names(inst.val)...]
_ssa_operands(inst::IRExtractValue) = Symbol[_ssa_names(inst.agg)...]
_ssa_operands(inst::IRCall)        = Symbol[n for a in inst.args for n in _ssa_names(a)]
_ssa_operands(inst::IRPhi)         = Symbol[n for (op, _) in inst.incoming for n in _ssa_names(op)]
_ssa_operands(inst::IRRet)         = inst.op === nothing ? Symbol[] :
                                     Symbol[_ssa_names(inst.op)...]  # void form (nd45 review nit 1): total, not MethodError
_ssa_operands(inst::IRBranch)      = inst.cond === nothing ? Symbol[] : Symbol[_ssa_names(inst.cond)...]
_ssa_operands(inst::IRPtrOffset)   = Symbol[_ssa_names(inst.base)...]
_ssa_operands(inst::IRVarGEP)      = Symbol[_ssa_names(inst.base)..., _ssa_names(inst.index)...]
_ssa_operands(inst::IRLoad)        = Symbol[_ssa_names(inst.ptr)...]
_ssa_operands(inst::IRStore)       = Symbol[_ssa_names(inst.ptr)..., _ssa_names(inst.val)...]
_ssa_operands(inst::IRAlloca)      = Symbol[_ssa_names(inst.n_elems)...]
_ssa_operands(inst::IRSwitch)      = Symbol[_ssa_names(inst.cond)...,
                                            (n for (case_op, _) in inst.cases for n in _ssa_names(case_op))...]
# Bennett-stwr: the SC9 Case B map ops (VM-only; the gate backend rejects
# them in `_lower_inst!`) — defined so `compute_ssa_use_counts` is total over
# every IRInst subtype instead of dying with a MethodError on a VM ParsedIR.
_ssa_operands(inst::IRMapInsert)   = Symbol[_ssa_names(inst.key)..., _ssa_names(inst.value)...]
_ssa_operands(inst::IRMapGet)      = Symbol[_ssa_names(inst.key)...]
_ssa_operands(inst::IRMapDelete)   = Symbol[_ssa_names(inst.key)...]

"""
    compute_ssa_use_counts(parsed::ParsedIR) -> Dict{Symbol,Int}

Bennett-stwr. For every SSA name, the number of operand OCCURRENCES of it in
the whole function: every non-terminator instruction of every block plus
every terminator (`br` conditions, `switch` conditions, `ret` operands). An
instruction that reads a name twice (`add %x, %x`) contributes 2. Names with
no occurrence are absent (`get(counts, v, 0)`).

This is deliberately order-free and path-insensitive: the lowering is
predicated (every basic block's gates execute, whichever path the input
takes), loop bodies are re-lowered K+1 times, and several Bennett strategies
uncompute groups non-LIFO — so "last use" in any single index space is NOT a
sound notion of "no other reader" (it is what the deleted
`compute_ssa_liveness` got wrong; see `compute_inplace_targets`).
"""
function compute_ssa_use_counts(parsed::ParsedIR)::Dict{Symbol,Int}
    uses = Dict{Symbol,Int}()
    for blk in parsed.blocks
        for inst in blk.instructions, v in _ssa_operands(inst)
            uses[v] = get(uses, v, 0) + 1
        end
        for v in _ssa_operands(blk.terminator)
            uses[v] = get(uses, v, 0) + 1
        end
    end
    return uses
end

"""
    _INPLACE_FRESH_DEFS

Bennett-stwr. Instruction types whose lowering binds `vw[dest]` to wires that
are owned by `dest` ALONE — freshly allocated by the lowering (or the private
CNOT-copied / callee-output wires of an inlined call), never a slice or alias
of an operand's wires and never also registered under another IR-visible
name. Verified per type against its lowering:

- `IRBinOp`   — `lower_binop!`: every arm allocates its result (identity
  peephole copies out; shifts, and/or/xor, ripple / QCLA adders, sub, mul,
  qcla_tree, `lower_divrem!` truncation copy). The Cuccaro arm returns an
  operand's register, but only one that is itself an exclusive in-place
  target (its `vw` entry is deleted) or a fresh copy/constant — ownership
  transfers to `dest`.
- `IRCast`    — `lower_cast!`: fresh `r` for sext/zext/trunc.
- `IRSelect`  — `lower_mux!` fresh `r` (width-0 pointer selects bind no wires).
- `IRICmp`    — `lower_eq!` / `lower_ult!` / `lower_slt!` / `lower_not1!`: fresh.
- `IRCall`    — `lower_call!`: callee wires are a fresh allocation; args are
  CNOT-copied in; `dest` gets the callee's output wires.
- `IRExtractValue` — `lower_extractvalue!`: CNOT-copy into fresh `result`.
- `IRLoad`    — every path allocates or takes a callee result: legacy /
  shadow / shadow-checkpoint / multi-origin allocate; persistent loads bind a
  call result; the MUX-EXCH loads bind a slice of a callee result that is
  also held under a synthetic `__mux_load_u64_*` name no IR operand reads (the
  lowering-time exclusivity scan in `lower_binop!` then conservatively
  copies-in rather than trusting it).

`IRPhi` is EXCLUDED: `resolve_phi_predicated!` returns the incoming wires
unchanged for a single-incoming phi, and `lower_loop!` seeds header phis with
the pre-header value's wires — a phi dest can alias another live name.
Pointer defs (`IRAlloca`, `IRPtrOffset`, `IRVarGEP`) are excluded: they slice
or alias the alloca / base registers. Any future lowering of a listed type
that returns an operand slice (e.g. a zero-gate `trunc`) MUST drop that type
from this list.
"""
const _INPLACE_FRESH_DEFS = Union{IRBinOp, IRCast, IRSelect, IRICmp, IRCall,
                                  IRExtractValue, IRLoad}

"""
    compute_inplace_targets(parsed::ParsedIR) -> Set{Symbol}

Bennett-stwr. The SSA names an in-place adder (`add=:cuccaro`) may overwrite.
`%v` is a target iff

1. `%v` has exactly ONE operand occurrence in the whole ParsedIR
   (`compute_ssa_use_counts`) — so the add reading it is its only reader
   anywhere: no sibling branch, phi, `br`/`switch`/`ret` operand, VarGEP index
   re-resolved by a later load, or second operand of the same add; and
2. `%v` is a function argument or is defined by an `_INPLACE_FRESH_DEFS`
   instruction — so no other name aliases its wires.

Soundness (the "exclusive reader" condition S2 of docs/design/stwr/): if an
add is the only reader of `B = wires(%v)`, then overwriting `B` with the sum
is invisible to every other group, under every Bennett strategy — any
uncompute schedule reverses the add's group (restoring `%v` in `B`) before
`%v`'s defining group, and no other group ever needs `B` to hold `%v`.
Function-argument registers are restored by the reverse pass.

Loop-unrolling contexts (`lower_loop!`) must NOT consult this set: a single
static occurrence inside a loop body is read K+1 times dynamically. The
lowering-time wire-exclusivity scan in `lower_binop!` backs this analysis up
against whitelist drift.
"""
function compute_inplace_targets(parsed::ParsedIR)::Set{Symbol}
    uses = compute_ssa_use_counts(parsed)
    targets = Set{Symbol}()
    for (name, _) in parsed.args
        get(uses, name, 0) == 1 && push!(targets, name)
    end
    for blk in parsed.blocks, inst in blk.instructions
        inst isa _INPLACE_FRESH_DEFS || continue
        get(uses, inst.dest, 0) == 1 && push!(targets, inst.dest)
    end
    return targets
end

# ==== main lowering entry point ====

