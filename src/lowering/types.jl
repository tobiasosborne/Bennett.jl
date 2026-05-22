"""
    GateGroup

Maps one SSA instruction (or infrastructure operation) to its contiguous range
of gates in the flat gate list.  Used by PRS15 value-level EAGER cleanup.

# Bennett-h0ai (auto self_reversing detection)

The `is_self_reversing` field is the producer-tag for auto-detection. A
group sets it to `true` when its emitted gate sub-sequence is itself a
closed self-cleaning primitive — `result_wires` carry the primitive's
output, all internal ancillae return to zero by the end of the group,
and the input wires read by the group are preserved. Producers known
to satisfy this contract (e.g. the qcla_tree mul dispatch when no
truncation is applied, and `lower_tabulate`'s `:__tabulate_qrom` group
over the entire QROM block) tag their emitted group; the LR-level
structural aggregator (`_infer_self_reversing`) checks the surrounding
context and the U03 runtime probe before promoting `lr.self_reversing=true`.

Producers MUST NOT set `is_self_reversing=true` on a group whose
emitted output is later sliced/truncated by the dispatch site — the
discarded wires become stranded ancillae that violate Bennett's
clean-ancilla invariant. (See `src/lowering/arith.jl:218` — the
qcla_tree mul dispatch slices `[1:W]` and therefore leaves the tag
`false`; future work in Bennett-h0ai-followup-D may emit a non-slicing
variant when the function shape allows it.)
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
    is_self_reversing::Bool     # Bennett-h0ai: producer-tag for auto self_reversing inference
end

# Default cleanup_wires to empty AND is_self_reversing to false
GateGroup(name, gs, ge, rw, ivars, ws, we) =
    GateGroup(name, gs, ge, rw, ivars, ws, we, Int[], false)
GateGroup(name, gs, ge, rw, ivars, ws, we, cleanup) =
    GateGroup(name, gs, ge, rw, ivars, ws, we, cleanup, false)

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

# Bennett-s0tn: `LoopGuard` is defined in src/gates.jl (loaded before
# this file) because `ReversibleCircuit` there carries a
# `Vector{LoopGuard}` field — the struct-definition-time field type must
# resolve. It is re-used here as `LoweringResult.loop_guards`.

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
    # Bennett-s0tn: one LoopGuard per data-dependent loop header. `wire`
    # is the forward-pass convergence wire. Empty ⇔ no data-dependent
    # loops (every non-loop function).
    loop_guards::Vector{LoopGuard}
end

# Bennett-7xng + Bennett-8h41 / U87: 6-arg convenience — gate_groups
# defaults empty, not self-reversing. The 7-arg variant (explicit
# gate_groups + default false self_reversing) was removed; no current
# callers used it. Callers needing explicit gate_groups must pass the
# full 8-arg form (gate_groups, self_reversing) for clarity.
# Bennett-s0tn: loop_guards defaults empty in every convenience form.
LoweringResult(gates, n_wires, input_wires, output_wires,
               input_widths, output_elem_widths) =
    LoweringResult(gates, n_wires, input_wires, output_wires,
                   input_widths, output_elem_widths, GateGroup[], false,
                   LoopGuard[])

LoweringResult(gates, n_wires, input_wires, output_wires,
               input_widths, output_elem_widths, gate_groups, self_reversing) =
    LoweringResult(gates, n_wires, input_wires, output_wires,
                   input_widths, output_elem_widths, gate_groups,
                   self_reversing, LoopGuard[])

"""Bundles shared lowering state for instruction dispatch."""
struct LoweringCtx
    gates::Vector{ReversibleGate}
    wa::WireAllocator
    vw::Dict{Symbol,Vector{Int}}
    # Bennett-ehoa / U43: concretized from `::Any` 2026-05-01. Every
    # caller already builds these as the documented dict shapes; the
    # `::Any` was defensive (no caller exercised the looseness) and
    # forced type-unstable dispatch on every `_lower_inst!` field
    # access. Concrete types let Julia inline through ctx reads.
    preds::Dict{Symbol,Vector{Symbol}}                          # block label → predecessor labels
    branch_info::Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}  # block label → (cond_wires, true_label, false_label)
    block_order::Dict{Symbol,Int}                                # block label → topological order index
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
    # Bennett-h0ai: producer-tag side-channel. The most recent
    # `_lower_inst!` call writes `true` here iff its emitted gate
    # sequence is a self-cleaning primitive whose result_wires equal
    # the binop's destination wire vector (no truncation, no
    # post-processing). `lower_block_insts!` reads-then-resets this
    # flag when constructing the GateGroup, transferring the tag to
    # `GateGroup.is_self_reversing`. Default-false on every dispatch;
    # only the qcla_tree non-truncating arm sets it today.
    last_inst_self_reversing::Ref{Bool}
    # Bennett-z2dj / T5-P6 (Step 2): persistent_tree dispatcher arm
    # kwargs. Plumbed through `lower(parsed; ...)` for Steps 3-9 to
    # consume. Step 2's contract: every kwarg defaulted, behavior
    # unchanged — these are pure wiring fields whose handlers light up
    # in later steps (Step 4 alloca dispatch, Step 9 validation).
    mem::Symbol                                                  # :auto / :persistent
    persistent_impl::Symbol                                      # :linear_scan / :okasaki / :hamt / :cf
    hashcons::Symbol                                             # :none / :naive / :feistel
    # Per-function state: which allocas got `:persistent_tree` and which
    # impl they're using. Values are `Bennett.Persistent.PersistentMapImpl`
    # (typed as `Any` here because src/lowering/types.jl loads BEFORE
    # src/persistent/persistent.jl in Bennett.jl — see include order at
    # src/Bennett.jl:32 vs :58). Step 9 will add a `validate_persistent_config`
    # pass that type-checks each value as `PersistentMapImpl`.
    persistent_info::Dict{Symbol, Any}
    # Bennett-s0tn: shared loop-guard accumulator (same vector as
    # `BlockLoweringOpts.loop_guards`). `lower_call!` appends remapped
    # callee loop guards here when inlining a callee with a data-dependent
    # loop, so an inner-function loop overflow is never silently dropped.
    loop_guards::Vector{LoopGuard}
end

# Bennett-tbm6 (2026-04-27): the 11-arg / 12-arg / 13-arg backward-compat
# `LoweringCtx` constructors were removed. Both internal call sites
# (`lower_block_insts!` ~717, `lower_loop!` ~1003) pass the full positional
# argument list; the compat shims had no remaining callers.

"""
    BlockLoweringOpts

Per-function lowering context bundle (Bennett-x2iw / U88). Threads the
shared optional state through `lower_block_insts!` and `lower_loop!` so
their kwarg surfaces stop bleeding 11 individually-passed dicts.

Each field defaults to a fresh empty container (or sentinel) — so a bare
`BlockLoweringOpts()` is the "trivial inputs, no globals, no alloca, all
defaults" call. The fields whose default-empty form changes externally-
visible behaviour are:

- `entry_label = Symbol("")` — sentinel "treat all blocks as entry"
  (disables Bennett-cc0 M2c per-block store gating). The real top-level
  driver passes `order[1]`.
- `add = :auto`, `mul = :auto` — strategy dispatchers.
- `compact_calls = false` — emit each callee site as 1 boxed gate group.
"""
Base.@kwdef struct BlockLoweringOpts
    block_pred::Dict{Symbol,Vector{Int}}             = Dict{Symbol,Vector{Int}}()
    ssa_liveness::Dict{Symbol,Int}                    = Dict{Symbol,Int}()
    inst_counter::Ref{Int}                            = Ref(0)
    gate_groups::Vector{GateGroup}                    = GateGroup[]
    compact_calls::Bool                               = false
    globals::Dict{Symbol,Tuple{Vector{UInt64},Int}}    = Dict{Symbol,Tuple{Vector{UInt64},Int}}()
    add::Symbol                                        = :auto
    mul::Symbol                                        = :auto
    alloca_info::Dict{Symbol,Tuple{Int,Int}}            = Dict{Symbol,Tuple{Int,Int}}()
    ptr_provenance::Dict{Symbol,Vector{PtrOrigin}}      = Dict{Symbol,Vector{PtrOrigin}}()
    entry_label::Symbol                                 = Symbol("")
    loop_headers::Set{Symbol}                           = Set{Symbol}()
    # Bennett-s0tn: shared accumulator for loop convergence guards.
    # `lower()` constructs ONE BlockLoweringOpts with a fresh vector and
    # reuses that instance across all blocks; `lower_loop!` pushes onto it.
    loop_guards::Vector{LoopGuard}                       = LoopGuard[]
    # Bennett-z2dj / T5-P6 (Step 2): persistent_tree dispatcher arm.
    # Forwarded from `lower(parsed; mem=..., ...)` and into each
    # `LoweringCtx(...)`. Step 2 wires only; handlers land in Steps 3-9.
    mem::Symbol                                         = :auto
    persistent_impl::Symbol                             = :linear_scan
    hashcons::Symbol                                    = :none
    # Per-function state: values are `Bennett.Persistent.PersistentMapImpl`
    # (typed `Any` because of include order — see types.jl LoweringCtx note).
    persistent_info::Dict{Symbol, Any}                   = Dict{Symbol, Any}()
end

# Dispatched instruction lowering — Julia selects the method by inst type
_lower_inst!(ctx::LoweringCtx, inst::IRPhi, label::Symbol) =
    lower_phi!(ctx.gates, ctx.wa, ctx.vw, inst, label, ctx.preds, ctx.branch_info, ctx.block_order;
               block_pred=ctx.block_pred, ptr_provenance=ctx.ptr_provenance)

_lower_inst!(ctx::LoweringCtx, inst::IRBinOp, ::Symbol) =
    lower_binop!(ctx.gates, ctx.wa, ctx.vw, inst;
                 ssa_liveness=ctx.ssa_liveness, inst_idx=ctx.inst_counter[],
                 add=ctx.add, mul=ctx.mul,
                 last_inst_self_reversing=ctx.last_inst_self_reversing)

_lower_inst!(ctx::LoweringCtx, inst::IRICmp, ::Symbol) =
    lower_icmp!(ctx.gates, ctx.wa, ctx.vw, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRSelect, ::Symbol) =
    lower_select!(ctx.gates, ctx.wa, ctx.vw, inst; ctx=ctx)

_lower_inst!(ctx::LoweringCtx, inst::IRCast, ::Symbol) =
    lower_cast!(ctx.gates, ctx.wa, ctx.vw, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRPtrOffset, ::Symbol) =
    lower_ptr_offset!(ctx.gates, ctx.wa, ctx.vw, inst; ptr_provenance=ctx.ptr_provenance,
                      alloca_info=ctx.alloca_info, persistent_info=ctx.persistent_info)

_lower_inst!(ctx::LoweringCtx, inst::IRVarGEP, ::Symbol) =
    lower_var_gep!(ctx.gates, ctx.wa, ctx.vw, inst; ptr_provenance=ctx.ptr_provenance,
                   alloca_info=ctx.alloca_info, globals=ctx.globals,
                   persistent_info=ctx.persistent_info)

_lower_inst!(ctx::LoweringCtx, inst::IRLoad, ::Symbol) =
    lower_load!(ctx, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRAlloca, ::Symbol) = lower_alloca!(ctx, inst)
_lower_inst!(ctx::LoweringCtx, inst::IRStore,  label::Symbol) = lower_store!(ctx, inst, label)

_lower_inst!(ctx::LoweringCtx, inst::IRExtractValue, ::Symbol) =
    lower_extractvalue!(ctx.gates, ctx.wa, ctx.vw, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRInsertValue, ::Symbol) =
    lower_insertvalue!(ctx.gates, ctx.wa, ctx.vw, inst)

_lower_inst!(ctx::LoweringCtx, inst::IRCall, ::Symbol) =
    lower_call!(ctx.gates, ctx.wa, ctx.vw, inst; compact=ctx.compact_calls,
                loop_guards=ctx.loop_guards)   # Bennett-s0tn

_lower_inst!(::LoweringCtx, inst::IRInst, ::Symbol) =
    error("_lower_inst!: unhandled IR instruction type: $(typeof(inst)) — $(inst)")

