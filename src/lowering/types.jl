"""
    GateGroup

Maps one SSA instruction (or infrastructure operation) to its contiguous range
of gates in the flat gate list.  Used by PRS15 value-level EAGER cleanup.
"""
struct GateGroup
    ssa_name::Symbol            # SSA dest, or synthetic like :__pred_entry
    gate_start::Int             # first gate index (1-based, inclusive)
    gate_end::Int               # last gate index (1-based, inclusive)
    result_wires::Vector{Int}   # wires produced by this operation
    input_ssa_vars::Vector{Symbol}  # SSA variables read (dependency edges)
    wire_start::Int             # first wire allocated by this group (inclusive)
    wire_end::Int               # last wire allocated by this group (inclusive; 0 if none)
    cleanup_wires::Vector{Int}  # wires guaranteed zero after forward (can be freed during replay)
end

# Default cleanup_wires to empty
GateGroup(name, gs, ge, rw, ivars, ws, we) = GateGroup(name, gs, ge, rw, ivars, ws, we, Int[])

"""
    _is_pred_group(g::GateGroup) -> Bool

True iff `g` is a synthetic block-predicate group emitted at src/lower.jl:379
and :389. Every non-trivial lowered function produces at least one such
group (the entry-block predicate `__pred_<entry>`), so this predicate alone
does NOT distinguish branching from straight-line code — use
`_has_branching(lr)` for that.
"""
_is_pred_group(g::GateGroup) = startswith(String(g.ssa_name), "__pred_")

"""
    _has_branching(lr::LoweringResult) -> Bool

True iff the lowered IR has a non-trivial control-flow graph, detected by
the presence of two or more `__pred_*` block-predicate groups. Straight-line
code produces exactly one such group (for the entry block); branching code
produces one per merge block beyond the entry.

Strategy-level bennett wrappers (`value_eager_bennett`, `pebbled_bennett`,
`pebbled_group_bennett`, `checkpoint_bennett`) use SSA-level dependency
metadata that does NOT track wire-level cross-deps between `__pred_*`
groups; they must refuse branching `LoweringResult`s and fall back to full
`bennett(lr)`. See Bennett-rggq / U02 and Bennett-prtp / U04.
"""
_has_branching(lr) = count(_is_pred_group, lr.gate_groups) >= 2

struct LoweringResult
    gates::Vector{ReversibleGate}
    n_wires::Int
    input_wires::Vector{Int}
    output_wires::Vector{Int}
    input_widths::Vector{Int}
    output_elem_widths::Vector{Int}
    gate_groups::Vector{GateGroup} # SSA instruction → gate range mapping
    # P1: if true, the entire gate sequence is a self-cleaning primitive
    # (e.g. Sun-Borissov `lower_mul_qcla_tree!`). `bennett()` honors this
    # by returning the forward gates only — no copy-out, no reverse.
    self_reversing::Bool
end

# Bennett-7xng + Bennett-8h41 / U87: 6-arg convenience — gate_groups
# defaults empty, not self-reversing. The 7-arg variant (explicit
# gate_groups + default false self_reversing) was removed; no current
# callers used it. Callers needing explicit gate_groups must pass the
# full 8-arg form (gate_groups, self_reversing) for clarity.
LoweringResult(gates, n_wires, input_wires, output_wires,
               input_widths, output_elem_widths) =
    LoweringResult(gates, n_wires, input_wires, output_wires,
                   input_widths, output_elem_widths, GateGroup[], false)

"""Bundles shared lowering state for instruction dispatch."""
struct LoweringCtx
    gates::Vector{ReversibleGate}
    wa::WireAllocator
    vw::Dict{Symbol,Vector{Int}}
    preds::Any    # Dict{Symbol,Vector{Symbol}} — typed Any to accept any dict shape from caller
    branch_info::Any
    block_order::Any
    block_pred::Dict{Symbol,Vector{Int}}
    ssa_liveness::Dict{Symbol,Int}
    inst_counter::Ref{Int}
    compact_calls::Bool
    # T1b.3: reversible memory (store/alloca) state
    alloca_info::Dict{Symbol, Tuple{Int,Int}}                 # alloca dest → (elem_width, n_elems)
    # Bennett-cc0 M2b: multi-origin ptr provenance. Each pointer SSA name maps
    # to ≥1 PtrOrigins — one per alloca the pointer might dereference at
    # runtime, keyed on the path-predicate wire that selects that origin.
    # Single-origin producers (alloca, GEP of known alloca) push a 1-Vector
    # with `predicate_wire = block_pred[entry_label][1]`.
    ptr_provenance::Dict{Symbol, Vector{PtrOrigin}}
    mux_counter::Ref{Int}                                      # monotonic counter for synthetic SSA names
    # T1c.2: compile-time-constant global arrays (for QROM dispatch)
    globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}          # global name → (data, elem_width)
    # D1: add-op strategy dispatcher (:auto, :ripple, :cuccaro, :qcla)
    add::Symbol
    # P2/P3: mul-op strategy dispatcher (:auto, :shift_add, :qcla_tree).
    # Bennett-tbm6 (2026-04-27): :karatsuba removed — vestigial at every
    # supported width, see src/multiplier.jl:35 for the empirical sweep.
    mul::Symbol
    # Bennett-cc0 M2c: entry (unconditional) block label. Stores in this block
    # use the ungated shadow path (preserves BENCHMARKS.md gate counts).
    # Stores in any other block get path-predicate-guarded shadow writes.
    # Sentinel Symbol("") disables gating entirely (backward-compat for direct
    # `lower_block_insts!` callers).
    entry_label::Symbol
end

# Bennett-tbm6 (2026-04-27): the 11-arg / 12-arg / 13-arg backward-compat
# `LoweringCtx` constructors were removed. Both internal call sites
# (`lower_block_insts!` ~717, `lower_loop!` ~1003) pass the full positional
# argument list; the compat shims had no remaining callers.
# Dispatched instruction lowering — Julia selects the method by inst type
_lower_inst!(ctx::LoweringCtx, inst::IRPhi, label::Symbol) =
    lower_phi!(ctx.gates, ctx.wa, ctx.vw, inst, label, ctx.preds, ctx.branch_info, ctx.block_order;
               block_pred=ctx.block_pred, ptr_provenance=ctx.ptr_provenance)

_lower_inst!(ctx::LoweringCtx, inst::IRBinOp, ::Symbol) =
    lower_binop!(ctx.gates, ctx.wa, ctx.vw, inst;
                 ssa_liveness=ctx.ssa_liveness, inst_idx=ctx.inst_counter[],
                 add=ctx.add, mul=ctx.mul)

_lower_inst!(ctx::LoweringCtx, inst::IRICmp, ::Symbol) =
    lower_icmp!(ctx.gates, ctx.wa, ctx.vw, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRSelect, ::Symbol) =
    lower_select!(ctx.gates, ctx.wa, ctx.vw, inst; ctx=ctx)

_lower_inst!(ctx::LoweringCtx, inst::IRCast, ::Symbol) =
    lower_cast!(ctx.gates, ctx.wa, ctx.vw, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRPtrOffset, ::Symbol) =
    lower_ptr_offset!(ctx.gates, ctx.wa, ctx.vw, inst; ptr_provenance=ctx.ptr_provenance,
                      alloca_info=ctx.alloca_info)

_lower_inst!(ctx::LoweringCtx, inst::IRVarGEP, ::Symbol) =
    lower_var_gep!(ctx.gates, ctx.wa, ctx.vw, inst; ptr_provenance=ctx.ptr_provenance,
                   alloca_info=ctx.alloca_info, globals=ctx.globals)

_lower_inst!(ctx::LoweringCtx, inst::IRLoad, ::Symbol) =
    lower_load!(ctx, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRAlloca, ::Symbol) = lower_alloca!(ctx, inst)
_lower_inst!(ctx::LoweringCtx, inst::IRStore,  label::Symbol) = lower_store!(ctx, inst, label)

_lower_inst!(ctx::LoweringCtx, inst::IRExtractValue, ::Symbol) =
    lower_extractvalue!(ctx.gates, ctx.wa, ctx.vw, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRInsertValue, ::Symbol) =
    lower_insertvalue!(ctx.gates, ctx.wa, ctx.vw, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRCall, ::Symbol) =
    lower_call!(ctx.gates, ctx.wa, ctx.vw, inst; compact=ctx.compact_calls)

_lower_inst!(::LoweringCtx, inst::IRInst, ::Symbol) =
    error("_lower_inst!: unhandled IR instruction type: $(typeof(inst)) — $(inst)")

