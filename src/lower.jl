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

struct LoweringResult
    gates::Vector{ReversibleGate}
    n_wires::Int
    input_wires::Vector{Int}
    output_wires::Vector{Int}
    input_widths::Vector{Int}
    output_elem_widths::Vector{Int}
    constant_wires::Set{Int}       # wires carrying compile-time constants
    gate_groups::Vector{GateGroup} # SSA instruction → gate range mapping
    # P1: if true, the entire gate sequence is a self-cleaning primitive
    # (e.g. Sun-Borissov `lower_mul_qcla_tree!`). `bennett()` honors this
    # by returning the forward gates only — no copy-out, no reverse.
    self_reversing::Bool
end

# Backward-compatible 7-arg constructor (existing call sites still work)
LoweringResult(gates, n_wires, input_wires, output_wires,
               input_widths, output_elem_widths, constant_wires) =
    LoweringResult(gates, n_wires, input_wires, output_wires,
                   input_widths, output_elem_widths, constant_wires, GateGroup[], false)

# 8-arg constructor (legacy, pre-P1)
LoweringResult(gates, n_wires, input_wires, output_wires,
               input_widths, output_elem_widths, constant_wires,
               gate_groups::Vector{GateGroup}) =
    LoweringResult(gates, n_wires, input_wires, output_wires,
                   input_widths, output_elem_widths, constant_wires, gate_groups, false)

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
    use_karatsuba::Bool
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
    # P2/P3: mul-op strategy dispatcher (:auto, :shift_add, :karatsuba, :qcla_tree)
    mul::Symbol
    # Bennett-cc0 M2c: entry (unconditional) block label. Stores in this block
    # use the ungated shadow path (preserves BENCHMARKS.md gate counts).
    # Stores in any other block get path-predicate-guarded shadow writes.
    # Sentinel Symbol("") disables gating entirely (backward-compat for direct
    # `lower_block_insts!` callers).
    entry_label::Symbol
end

# Backward-compatible constructor: existing sites don't need to pass the new fields.
LoweringCtx(gates, wa, vw, preds, branch_info, block_order,
            block_pred, ssa_liveness, inst_counter, use_karatsuba, compact_calls) =
    LoweringCtx(gates, wa, vw, preds, branch_info, block_order,
                block_pred, ssa_liveness, inst_counter, use_karatsuba, compact_calls,
                Dict{Symbol,Tuple{Int,Int}}(),
                Dict{Symbol,Vector{PtrOrigin}}(),
                Ref(0),
                Dict{Symbol,Tuple{Vector{UInt64},Int}}(),
                :auto, :auto, Symbol(""))

# 12-arg constructor for callers that want to pass globals explicitly.
LoweringCtx(gates, wa, vw, preds, branch_info, block_order,
            block_pred, ssa_liveness, inst_counter, use_karatsuba, compact_calls,
            globals::Dict{Symbol,Tuple{Vector{UInt64},Int}}) =
    LoweringCtx(gates, wa, vw, preds, branch_info, block_order,
                block_pred, ssa_liveness, inst_counter, use_karatsuba, compact_calls,
                Dict{Symbol,Tuple{Int,Int}}(),
                Dict{Symbol,Vector{PtrOrigin}}(),
                Ref(0),
                globals,
                :auto, :auto, Symbol(""))

# 13-arg constructor: adds the add-strategy field.
LoweringCtx(gates, wa, vw, preds, branch_info, block_order,
            block_pred, ssa_liveness, inst_counter, use_karatsuba, compact_calls,
            globals::Dict{Symbol,Tuple{Vector{UInt64},Int}}, add::Symbol,
            mul::Symbol=:auto) =
    LoweringCtx(gates, wa, vw, preds, branch_info, block_order,
                block_pred, ssa_liveness, inst_counter, use_karatsuba, compact_calls,
                Dict{Symbol,Tuple{Int,Int}}(),
                Dict{Symbol,Vector{PtrOrigin}}(),
                Ref(0),
                globals,
                add, mul, Symbol(""))

# Dispatched instruction lowering — Julia selects the method by inst type
_lower_inst!(ctx::LoweringCtx, inst::IRPhi, label::Symbol) =
    lower_phi!(ctx.gates, ctx.wa, ctx.vw, inst, label, ctx.preds, ctx.branch_info, ctx.block_order;
               block_pred=ctx.block_pred, ptr_provenance=ctx.ptr_provenance)

_lower_inst!(ctx::LoweringCtx, inst::IRBinOp, ::Symbol) =
    lower_binop!(ctx.gates, ctx.wa, ctx.vw, inst;
                 ssa_liveness=ctx.ssa_liveness, inst_idx=ctx.inst_counter[],
                 use_karatsuba=ctx.use_karatsuba, add=ctx.add, mul=ctx.mul)

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
    error("Unhandled instruction type: $(typeof(inst)) — $(inst)")

# ---- operand resolution ----

function resolve!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                  var_wires::Dict{Symbol,Vector{Int}}, op::IROperand, width::Int;
                  constant_wires::Set{Int}=Set{Int}())
    if op.kind == :ssa
        haskey(var_wires, op.name) || error("Undefined SSA variable: %$(op.name)")
        return var_wires[op.name]
    else
        wires = allocate!(wa, width)
        val = op.value & ((1 << width) - 1)
        for i in 1:width
            if (val >> (i - 1)) & 1 == 1
                push!(gates, NOTGate(wires[i]))
            end
        end
        # Mark as constant — these can be reconstructed without ancillae
        union!(constant_wires, wires)
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

function lower(parsed::ParsedIR; max_loop_iterations::Int=0, use_inplace::Bool=true,
               use_karatsuba::Bool=false, fold_constants::Bool=false, compact_calls::Bool=false,
               add::Symbol=:auto, mul::Symbol=:auto)
    add in (:auto, :ripple, :cuccaro, :qcla) ||
        error("lower: unknown add strategy :$add; supported: :auto, :ripple, :cuccaro, :qcla")
    mul in (:auto, :shift_add, :karatsuba, :qcla_tree) ||
        error("lower: unknown mul strategy :$mul; supported: :auto, :shift_add, :karatsuba, :qcla_tree")
    wa = WireAllocator()
    gates = ReversibleGate[]
    vw = Dict{Symbol,Vector{Int}}()
    input_wires = Int[]
    input_widths = Int[]
    constant_wires = Set{Int}()    # wires carrying compile-time constants
    gate_groups = GateGroup[]      # SSA instruction → gate range mapping

    # Compute SSA liveness for in-place optimization
    ssa_liveness = use_inplace ? compute_ssa_liveness(parsed) : Dict{Symbol,Int}()
    inst_counter = Ref(0)

    # T3b.3 / Bennett-cc0 M2a: ptr_provenance + alloca_info are per-function state,
    # threaded into lower_block_insts! so allocas defined in one block are visible
    # to stores/loads in later blocks. Previously these were re-initialised per
    # block (bug), which hard-errored on branched stores — see L7a/L7b tests.
    alloca_info = Dict{Symbol, Tuple{Int,Int}}()
    ptr_provenance = Dict{Symbol, Vector{PtrOrigin}}()

    for (name, width) in parsed.args
        wires = allocate!(wa, width)
        vw[name] = wires
        append!(input_wires, wires)
        push!(input_widths, width)
    end

    blocks = parsed.blocks
    block_map = Dict(b.label => b for b in blocks)

    # Detect loops (back-edges) and compute acyclic topo order
    back_edges = find_back_edges(blocks)
    order = topo_sort(blocks; ignore_edges=back_edges)

    # If there are loops, we need max_loop_iterations
    if !isempty(back_edges) && max_loop_iterations <= 0
        error("Loop detected in LLVM IR but max_loop_iterations not specified. " *
              "Pass max_loop_iterations=N to reversible_compile.")
    end

    # Build loop info for each header
    loop_headers = Set(dst for (_, dst) in back_edges)

    # track branch conditions and predecessors (for phi / multi-ret resolution)
    branch_info = Dict{Symbol, Tuple{Vector{Int}, Symbol, Symbol}}()
    preds = Dict{Symbol, Vector{Symbol}}()
    block_order = Dict(order[i] => i for i in eachindex(order))

    # Path predicates: 1-bit wire per block, true iff that block is active.
    # Computed during lowering, used for phi resolution.
    block_pred = Dict{Symbol, Vector{Int}}()

    ret_values = Tuple{Vector{Int}, Symbol}[]

    for label in order
        block = block_map[label]

        # Compute block predicate from predecessors
        if label == order[1]
            # Entry block: predicate = 1 (always active)
            _ws = wa.next_wire
            _gs = length(gates) + 1
            pw = allocate!(wa, 1)
            push!(gates, NOTGate(pw[1]))  # set to 1
            block_pred[label] = pw
            if length(gates) >= _gs
                push!(gate_groups, GateGroup(Symbol("__pred_", label),
                      _gs, length(gates), pw, Symbol[], _ws, wa.next_wire - 1))
            end
        elseif !isempty(get(preds, label, Symbol[]))
            # Merge block: OR of incoming predicates
            _ws = wa.next_wire
            _gs = length(gates) + 1
            block_pred[label] = _compute_block_pred!(gates, wa, label, preds,
                                                     branch_info, block_pred)
            if length(gates) >= _gs
                push!(gate_groups, GateGroup(Symbol("__pred_", label),
                      _gs, length(gates), block_pred[label], Symbol[], _ws, wa.next_wire - 1))
            end
        end

        if label in loop_headers
            # Unroll this loop (single group for entire loop body)
            _ws = wa.next_wire
            _gs = length(gates) + 1
            lower_loop!(gates, wa, vw, block, block_map, back_edges,
                        max_loop_iterations, preds, branch_info)
            if length(gates) >= _gs
                push!(gate_groups, GateGroup(Symbol("__loop_", label),
                      _gs, length(gates), Int[], Symbol[], _ws, wa.next_wire - 1))
            end
        else
            lower_block_insts!(gates, wa, vw, block, preds, branch_info, block_order;
                               block_pred, ssa_liveness, inst_counter, gate_groups,
                               use_karatsuba, compact_calls, globals=parsed.globals, add, mul,
                               alloca_info, ptr_provenance, entry_label=order[1])
        end

        # Process terminator (for non-loop blocks AND after loop unrolling)
        term = block.terminator
        if term isa IRRet
            _ws = wa.next_wire
            _gs = length(gates) + 1
            push!(ret_values, (copy(resolve!(gates, wa, vw, term.op, term.width)), label))
            if length(gates) >= _gs
                push!(gate_groups, GateGroup(Symbol("__ret_", label),
                      _gs, length(gates), ret_values[end][1], _ssa_operands(term),
                      _ws, wa.next_wire - 1))
            end
        elseif term isa IRBranch && term.cond !== nothing
            if !(label in loop_headers)  # loop headers handle their own branches
                _ws = wa.next_wire
                _gs = length(gates) + 1
                cw = resolve!(gates, wa, vw, term.cond, 1)
                if length(gates) >= _gs
                    push!(gate_groups, GateGroup(Symbol("__branch_", label),
                          _gs, length(gates), cw, _ssa_operands(term),
                          _ws, wa.next_wire - 1))
                end
                branch_info[label] = (cw, term.true_label, term.false_label)
                push!(get!(preds, term.true_label, Symbol[]), label)
                push!(get!(preds, term.false_label, Symbol[]), label)
            end
        elseif term isa IRBranch
            if !(label in loop_headers)
                push!(get!(preds, term.true_label, Symbol[]), label)
            end
        end
    end

    output_wires = if length(ret_values) == 1
        ret_values[1][1]
    else
        _ws = wa.next_wire
        _gs = length(gates) + 1
        result = resolve_phi_predicated!(gates, wa, collect(ret_values), block_pred,
                                         parsed.ret_width; branch_info)
        if length(gates) >= _gs
            push!(gate_groups, GateGroup(:__multi_ret_merge,
                  _gs, length(gates), result, Symbol[], _ws, wa.next_wire - 1))
        end
        result
    end

    lr = LoweringResult(gates, wire_count(wa), input_wires, output_wires,
                         input_widths, parsed.ret_elem_widths, constant_wires,
                         gate_groups)

    if fold_constants
        lr = _fold_constants(lr)
    end

    return lr
end

"""
Constant folding pass: propagate known wire values through the gate list,
eliminating gates whose controls are all constant and simplifying partially-
constant gates.
"""
function _fold_constants(lr::LoweringResult)
    input_set = Set(lr.input_wires)
    # Initialize known values: all non-input wires start at 0
    known = Dict{Int, Bool}()
    for w in 1:lr.n_wires
        w in input_set && continue
        known[w] = false
    end

    folded = ReversibleGate[]
    for gate in lr.gates
        if gate isa NOTGate
            if haskey(known, gate.target)
                known[gate.target] = !known[gate.target]
                # Don't emit — will be materialized at end if needed
            else
                push!(folded, gate)
            end
        elseif gate isa CNOTGate
            c_known = haskey(known, gate.control)
            t_known = haskey(known, gate.target)
            if c_known && known[gate.control] == false
                # XOR with 0 = noop
            elseif c_known && known[gate.control] == true
                # XOR with 1 = NOT target
                if t_known
                    known[gate.target] = !known[gate.target]
                else
                    push!(folded, NOTGate(gate.target))
                end
            else
                # Control is data-dependent — target becomes unknown
                if t_known
                    # Must materialize target's current known value first
                    if known[gate.target]
                        push!(folded, NOTGate(gate.target))
                    end
                    delete!(known, gate.target)
                end
                push!(folded, gate)
            end
        elseif gate isa ToffoliGate
            c1_known = haskey(known, gate.control1)
            c2_known = haskey(known, gate.control2)
            t_known = haskey(known, gate.target)

            c1_val = c1_known ? known[gate.control1] : nothing
            c2_val = c2_known ? known[gate.control2] : nothing

            if (c1_val === false) || (c2_val === false)
                # At least one control is known-false → gate is noop
            elseif c1_val === true && c2_val === true
                # Both controls true → target ^= 1
                if t_known
                    known[gate.target] = !known[gate.target]
                else
                    push!(folded, NOTGate(gate.target))
                end
            elseif c1_val === true
                # Reduce to CNOT(c2, target)
                if t_known
                    if known[gate.target]; push!(folded, NOTGate(gate.target)); end
                    delete!(known, gate.target)
                end
                push!(folded, CNOTGate(gate.control2, gate.target))
            elseif c2_val === true
                # Reduce to CNOT(c1, target)
                if t_known
                    if known[gate.target]; push!(folded, NOTGate(gate.target)); end
                    delete!(known, gate.target)
                end
                push!(folded, CNOTGate(gate.control1, gate.target))
            else
                # Both controls unknown — emit as-is, target becomes unknown
                if t_known
                    if known[gate.target]; push!(folded, NOTGate(gate.target)); end
                    delete!(known, gate.target)
                end
                push!(folded, gate)
            end
        end
    end

    # Materialize remaining known non-zero values
    for (w, v) in known
        if v
            push!(folded, NOTGate(w))
        end
    end

    # Rebuild gate groups (invalidated by folding — clear them)
    return LoweringResult(folded, lr.n_wires, lr.input_wires, lr.output_wires,
                          lr.input_widths, lr.output_elem_widths, lr.constant_wires)
end

function lower_block_insts!(gates, wa, vw, block, preds, branch_info, block_order;
                           block_pred::Dict{Symbol,Vector{Int}}=Dict{Symbol,Vector{Int}}(),
                           ssa_liveness::Dict{Symbol,Int}=Dict{Symbol,Int}(),
                           inst_counter::Ref{Int}=Ref(0),
                           gate_groups::Vector{GateGroup}=GateGroup[],
                           use_karatsuba::Bool=false,
                           compact_calls::Bool=false,
                           globals::Dict{Symbol,Tuple{Vector{UInt64},Int}}=Dict{Symbol,Tuple{Vector{UInt64},Int}}(),
                           add::Symbol=:auto, mul::Symbol=:auto,
                           # Bennett-cc0 M2a: caller-owned per-function memory state.
                           # Defaults to fresh dicts for backward-compat with direct callers.
                           # mux_counter stays block-local — synthetic SSA names embed the
                           # globally-unique hint (inst.dest / inst.ptr.name) so cross-block
                           # counter reset doesn't collide.
                           alloca_info::Dict{Symbol,Tuple{Int,Int}}=Dict{Symbol,Tuple{Int,Int}}(),
                           ptr_provenance::Dict{Symbol,Vector{PtrOrigin}}=Dict{Symbol,Vector{PtrOrigin}}(),
                           # Bennett-cc0 M2c: entry-block label for conditional-store
                           # guarding. Sentinel Symbol("") means "treat all as entry"
                           # (backward-compat for direct callers).
                           entry_label::Symbol=Symbol(""))
    ctx = LoweringCtx(gates, wa, vw, preds, branch_info, block_order,
                      block_pred, ssa_liveness, inst_counter, use_karatsuba, compact_calls,
                      alloca_info, ptr_provenance, Ref(0),
                      globals, add, mul, entry_label)
    for inst in block.instructions
        inst_counter[] += 1
        _ws = wa.next_wire
        _gs = length(gates) + 1

        _lower_inst!(ctx, inst, block.label)

        _ge = length(gates)
        if _ge >= _gs && hasproperty(inst, :dest)
            push!(gate_groups, GateGroup(inst.dest, _gs, _ge,
                  copy(get(vw, inst.dest, Int[])), _ssa_operands(inst),
                  _ws, wa.next_wire - 1))
        end
    end
end

# ---- topological sort + loop detection ----

function branch_targets(br::IRBranch)
    br.false_label !== nothing ? [br.true_label, br.false_label] : [br.true_label]
end

"""Find back-edges via DFS. Returns Vector of (src, dst) pairs."""
function find_back_edges(blocks::Vector{IRBasicBlock})
    block_set = Set(b.label for b in blocks)
    # DFS with coloring: 0=white, 1=gray(on stack), 2=black(done)
    color = Dict(b.label => 0 for b in blocks)
    succs = Dict{Symbol,Vector{Symbol}}()
    for b in blocks
        s = Symbol[]
        if b.terminator isa IRBranch
            for t in branch_targets(b.terminator)
                t in block_set && push!(s, t)
            end
        end
        succs[b.label] = s
    end

    back = Tuple{Symbol,Symbol}[]
    function dfs(u)
        color[u] = 1
        for v in succs[u]
            if color[v] == 1      # gray → back-edge (cycle)
                push!(back, (u, v))
            elseif color[v] == 0
                dfs(v)
            end
        end
        color[u] = 2
    end

    for b in blocks
        color[b.label] == 0 && dfs(b.label)
    end
    return back
end

"""Topological sort ignoring specified edges (e.g. back-edges)."""
function topo_sort(blocks::Vector{IRBasicBlock};
                   ignore_edges::Vector{Tuple{Symbol,Symbol}}=Tuple{Symbol,Symbol}[])
    ignore_set = Set(ignore_edges)
    block_set = Set(b.label for b in blocks)
    succs = Dict{Symbol, Vector{Symbol}}()
    indeg = Dict{Symbol, Int}()
    for b in blocks
        succs[b.label] = Symbol[]
        indeg[b.label] = 0
    end
    for b in blocks
        b.terminator isa IRBranch || continue
        for t in branch_targets(b.terminator)
            t in block_set || continue
            (b.label, t) in ignore_set && continue   # skip back-edges
            push!(succs[b.label], t)
            indeg[t] += 1
        end
    end
    queue = [b.label for b in blocks if indeg[b.label] == 0]
    result = Symbol[]
    while !isempty(queue)
        node = popfirst!(queue)
        push!(result, node)
        for s in succs[node]
            indeg[s] -= 1
            indeg[s] == 0 && push!(queue, s)
        end
    end
    length(result) == length(blocks) ||
        error("Cannot topologically sort blocks even after removing back-edges")
    return result
end

# ---- loop unrolling ----

"""
    lower_loop!(gates, wa, vw, header_block, block_map, back_edges, K, preds, branch_info)

Unroll a loop K times. The header block has phi nodes for loop-carried variables.
Each iteration: lower body → compute exit condition → MUX-freeze outputs.
"""
function lower_loop!(gates, wa, vw, header::IRBasicBlock, block_map,
                     back_edges, K::Int, preds, branch_info)
    hlabel = header.label

    # Find which phi inputs are from the pre-header vs the back-edge (latch)
    latch_labels = Set(src for (src, dst) in back_edges if dst == hlabel)
    pre_header_preds = Symbol[]  # will be filled from phi incoming

    # Separate phi incoming into pre-header (initial) and latch (loop-carried)
    phi_info = Tuple{Symbol, Int, IROperand, IROperand}[]
    for inst in header.instructions
        inst isa IRPhi || continue
        pre_op = nothing; latch_op = nothing
        for (val, blk) in inst.incoming
            if blk in latch_labels || blk == hlabel  # self-loop or latch
                latch_op = (val, blk)
            else
                pre_op = (val, blk)
                blk in pre_header_preds || push!(pre_header_preds, blk)
            end
        end
        pre_op === nothing && error("Phi $(inst.dest) has no pre-header incoming")
        latch_op === nothing && error("Phi $(inst.dest) has no latch incoming")
        push!(phi_info, (inst.dest, inst.width, pre_op[1], latch_op[1]))
    end

    # Register pre-header predecessors
    for p in pre_header_preds
        push!(get!(preds, hlabel, Symbol[]), p)
    end

    # Non-phi instructions in the header (the loop body)
    body_insts = [inst for inst in header.instructions if !(inst isa IRPhi)]

    # The terminator must be a conditional branch (exit vs continue)
    term = header.terminator
    (term isa IRBranch && term.cond !== nothing) || error("Loop header must end with conditional branch, got: $(typeof(term))")

    # Determine which successor is the exit and which is the back-edge
    exit_on_true = !(term.true_label == hlabel || term.true_label in latch_labels)
    exit_label = exit_on_true ? term.true_label : term.false_label
    # exit_cond: when true → exit (if exit_on_true), or when false → exit

    # Initialize phi variables from pre-header values
    for (dest, width, pre_val, _) in phi_info
        vw[dest] = resolve!(gates, wa, vw, pre_val, width)
    end

    # Unroll K iterations
    for _iter in 1:K
        # Lower body instructions (updates vw with new values)
        for inst in body_insts
            if inst isa IRBinOp;    lower_binop!(gates, wa, vw, inst)
            elseif inst isa IRICmp; lower_icmp!(gates, wa, vw, inst)
            elseif inst isa IRSelect; lower_select!(gates, wa, vw, inst)
            elseif inst isa IRCast; lower_cast!(gates, wa, vw, inst)
            end
        end

        # Compute exit condition
        exit_cond_wire = resolve!(gates, wa, vw, term.cond, 1)

        # If exit is on the FALSE side, negate (we want exit_cond=1 means "stop")
        if !exit_on_true
            exit_cond_wire = lower_not1!(gates, wa, exit_cond_wire)
        end

        # Compute latch values (what the phi would receive on the next iteration)
        latch_vals = Vector{Int}[]
        for (_, width, _, latch_op) in phi_info
            push!(latch_vals, resolve!(gates, wa, vw, latch_op, width))
        end

        # MUX: for each phi variable, freeze if exiting, update if continuing
        # exit_cond=1 → keep current (frozen), exit_cond=0 → take latch value
        for (k, (dest, width, _, _)) in enumerate(phi_info)
            current = vw[dest]
            new_val = latch_vals[k]
            # MUX(exit_cond, current, new_val): exit→keep, continue→update
            vw[dest] = lower_mux!(gates, wa, exit_cond_wire, current, new_val, width)
        end
    end

    # After unrolling, record the exit edge as a predecessor of the exit block
    push!(get!(preds, exit_label, Symbol[]), hlabel)

    # Also handle the terminator's branch condition for downstream phi resolution
    # The exit condition was computed; the exit block's phi needs to know about it
    # We treat the loop header as branching to exit_label
    # (The "continue" side loops back, which we've unrolled away)
end

# ---- path-predicate computation ----

"""Compute AND of two 1-bit wires on a fresh output wire."""
function _and_wire!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                    a::Vector{Int}, b::Vector{Int})
    result = allocate!(wa, 1)
    push!(gates, ToffoliGate(a[1], b[1], result[1]))
    return result
end

"""Compute OR of two 1-bit wires on a fresh output wire.
   OR(a, b) = a XOR b XOR (a AND b)."""
function _or_wire!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                   a::Vector{Int}, b::Vector{Int})
    result = allocate!(wa, 1)
    push!(gates, CNOTGate(a[1], result[1]))       # result = a
    push!(gates, CNOTGate(b[1], result[1]))       # result = a XOR b
    push!(gates, ToffoliGate(a[1], b[1], result[1]))  # result = a XOR b XOR (a AND b) = a OR b
    return result
end

"""Compute NOT of a 1-bit wire on a fresh output wire."""
function _not_wire!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                    a::Vector{Int})
    result = allocate!(wa, 1)
    push!(gates, NOTGate(result[1]))               # result = 1
    push!(gates, CNOTGate(a[1], result[1]))        # result = 1 XOR a = NOT(a)
    return result
end

"""Compute the path predicate for a block from its predecessors.

For each predecessor p:
  - If p branches conditionally and label is the true target: AND(pred[p], cond[p])
  - If p branches conditionally and label is the false target: AND(pred[p], NOT(cond[p]))
  - If p branches unconditionally: pred[p]

Block predicate = OR of all incoming contributions.
"""
function _compute_block_pred!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                              label::Symbol, preds::Dict{Symbol,Vector{Symbol}},
                              branch_info::Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}},
                              block_pred::Dict{Symbol,Vector{Int}})
    pred_list = get(preds, label, Symbol[])
    isempty(pred_list) && error("Block $label has no predecessors for predicate computation")

    contributions = Vector{Int}[]
    for p in pred_list
        haskey(block_pred, p) || continue  # skip if predecessor has no predicate (loop)
        if haskey(branch_info, p)
            (cw, tlabel, flabel) = branch_info[p]
            if tlabel == label
                # True side: AND(pred[p], cond)
                push!(contributions, _and_wire!(gates, wa, block_pred[p], cw))
            elseif flabel == label
                # False side: AND(pred[p], NOT(cond))
                not_cw = _not_wire!(gates, wa, cw)
                push!(contributions, _and_wire!(gates, wa, block_pred[p], not_cw))
            end
        else
            # Unconditional branch: just propagate
            push!(contributions, block_pred[p])
        end
    end

    isempty(contributions) && error("No predicate contributions for block $label")

    # OR all contributions together
    result = contributions[1]
    for i in 2:length(contributions)
        result = _or_wire!(gates, wa, result, contributions[i])
    end
    return result
end

# ---- phi resolution (predicated) ----

"""
Bennett-cc0 M2b — compute the edge predicate wire from `src_block` into
`phi_block`. Extracted verbatim from the original `resolve_phi_predicated!`
loop so pointer-typed phi can share the same logic (pure refactor).

- Conditional branch where phi_block is the true target:
  edge_pred = AND(block_pred[src_block], cond_wire).
- Conditional branch where phi_block is the false target:
  edge_pred = AND(block_pred[src_block], NOT(cond_wire)).
- Unconditional branch or src_block doesn't directly branch to phi_block:
  edge_pred = block_pred[src_block] (propagated unchanged).

Returns a Vector{Int} (1-wire) for AND-reduction compatibility with the
existing MUX chain.
"""
function _edge_predicate!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                          src_block::Symbol, phi_block::Symbol,
                          block_pred::Dict{Symbol,Vector{Int}},
                          branch_info::Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}})
    haskey(block_pred, src_block) ||
        error("_edge_predicate!: no predicate for block $src_block in phi resolution")
    if haskey(branch_info, src_block)
        (cw, tlabel, flabel) = branch_info[src_block]
        if tlabel == phi_block
            return _and_wire!(gates, wa, block_pred[src_block], cw)
        elseif flabel == phi_block
            not_cw = _not_wire!(gates, wa, cw)
            return _and_wire!(gates, wa, block_pred[src_block], not_cw)
        end
    end
    # Unconditional / indirect — propagate block pred as-is.
    return block_pred[src_block]
end

"""Resolve phi node using path predicates.

For each incoming (wires, from_block), compute the **edge predicate** — the
probability that control flowed from from_block to the phi's block via the
specific edge. This is AND(block_pred[from], branch_condition) for conditional
branches, or block_pred[from] for unconditional branches.

Chain MUXes controlled by edge predicates — since they are mutually exclusive,
exactly one fires. Correct for arbitrary CFGs.
"""
function resolve_phi_predicated!(gates, wa, incoming, block_pred, W;
                                 phi_block::Symbol=Symbol(""),
                                 branch_info::Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}=Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}())
    length(incoming) == 1 && return incoming[1][1]

    # Compute edge predicates for each incoming value
    edge_preds = Vector{Int}[]
    for (_, blk) in incoming
        push!(edge_preds, _edge_predicate!(gates, wa, blk, phi_block,
                                           block_pred, branch_info))
    end

    # Chain MUXes: start from last, each edge pred selects its value
    result = incoming[end][1]
    for i in (length(incoming) - 1):-1:1
        (wires, _) = incoming[i]
        result = lower_mux!(gates, wa, edge_preds[i], wires, result, W)
    end
    return result
end

# ---- phi resolution (legacy reachability-based) ----

function lower_phi!(gates, wa, vw, inst::IRPhi, phi_block::Symbol,
                    preds, branch_info, block_order;
                    block_pred::Dict{Symbol,Vector{Int}}=Dict{Symbol,Vector{Int}}(),
                    ptr_provenance::Union{Nothing,Dict{Symbol,Vector{PtrOrigin}}}=nothing)
    # Bennett-cc0 M2b: pointer-typed phi (width=0 sentinel from ir_extract.jl).
    # Metadata-only routing — emits NO wires, NO gates for the phi itself
    # beyond the edge-predicate ANDs that fold each origin's predicate with
    # its incoming edge. Store/load through the resulting multi-origin
    # pointer fan out via emit_shadow_store_guarded! / multi-origin load.
    if inst.width == 0
        ptr_provenance === nothing &&
            error("lower_phi!: ptr-phi %$(inst.dest) requires ptr_provenance threading")
        isempty(block_pred) &&
            error("lower_phi!: ptr-phi %$(inst.dest) needs block_pred for edge predicates")
        merged = PtrOrigin[]
        for (val, src_block) in inst.incoming
            val.kind == :ssa ||
                error("lower_phi!: ptr-phi %$(inst.dest) incoming from non-SSA operand $(val)")
            haskey(ptr_provenance, val.name) ||
                error("lower_phi!: ptr-phi %$(inst.dest) incoming %$(val.name) has no provenance")
            edge_pred = _edge_predicate!(gates, wa, src_block, phi_block,
                                         block_pred, branch_info)
            for o in ptr_provenance[val.name]
                combined = _and_wire!(gates, wa, [o.predicate_wire], edge_pred)
                push!(merged, PtrOrigin(o.alloca_dest, o.idx_op, combined[1]))
            end
        end
        isempty(merged) &&
            error("lower_phi!: ptr-phi %$(inst.dest) produced empty origin set")
        length(merged) <= 8 ||
            error("lower_phi!: ptr-phi %$(inst.dest) fan-out $(length(merged)) > 8 " *
                  "exceeds M2b budget; file a bd issue")
        ptr_provenance[inst.dest] = merged
        return  # no vw[inst.dest] — pointers don't materialize as wires
    end

    incoming = [(resolve!(gates, wa, vw, val, inst.width), blk)
                for (val, blk) in inst.incoming]
    isempty(block_pred) && error("block_pred is empty during phi resolution for $(inst.dest) — path predicates must be computed before phi lowering")
    vw[inst.dest] = resolve_phi_predicated!(gates, wa, incoming, block_pred, inst.width;
                                            phi_block=phi_block, branch_info)
end

"""Check if `ancestor` is an ancestor of `block` in the CFG."""
function has_ancestor(block::Symbol, ancestor::Symbol, preds,
                      visited::Set{Symbol}=Set{Symbol}())
    block == ancestor && return true
    block in visited && return false
    push!(visited, block)
    for p in get(preds, block, Symbol[])
        has_ancestor(p, ancestor, preds, visited) && return true
    end
    return false
end

"""Check if `block` is on the branch side rooted at `target_label`."""
function on_branch_side(block::Symbol, target_label::Symbol,
                        src_block::Symbol, preds)
    block == target_label && return true
    has_ancestor(block, target_label, preds) && return true
    # branch source itself → matches the side whose target it reaches directly
    # (handles case where branch source is a direct predecessor of the merge block)
    block == src_block && return false  # ambiguous — resolved by exclusive matching
    return false
end

"""Check if block `b` is on the side rooted at `target` of a branch from `src`."""
function _is_on_side(b::Symbol, target::Symbol, src::Symbol,
                     phi_block::Symbol, preds)
    b == target && return true
    has_ancestor(b, target, preds) && return true
    if b == src
        return phi_block != Symbol("") && phi_block == target
    end
    return false
end

"""Reduce N incoming (wires, block) pairs to one via nested MUXes.

Recursively finds a branch that cleanly partitions the incoming values into
true-side and false-side groups, resolves each group, and MUXes them.
"""
function resolve_phi_muxes!(gates, wa, incoming, preds, branch_info, block_order, W;
                            phi_block::Symbol=Symbol(""))
    length(incoming) == 1 && return incoming[1][1]

    # Try each branch (topological order, outermost first) to find a clean partition
    sorted = sort(collect(keys(branch_info)), by=b -> get(block_order, b, 0))

    for src in sorted
        (cond_wire, tlabel, flabel) = branch_info[src]

        true_set  = Tuple{Vector{Int}, Symbol}[]
        false_set = Tuple{Vector{Int}, Symbol}[]
        ambig     = Tuple{Vector{Int}, Symbol}[]

        for (w, b) in incoming
            on_t = _is_on_side(b, tlabel, src, phi_block, preds)
            on_f = _is_on_side(b, flabel, src, phi_block, preds)
            if on_t && !on_f
                push!(true_set, (w, b))
            elseif on_f && !on_t
                push!(false_set, (w, b))
            else
                push!(ambig, (w, b))
            end
        end

        if !isempty(true_set) && !isempty(false_set)
            if isempty(ambig)
                # Clean partition — no diamond
                tv = resolve_phi_muxes!(gates, wa, true_set, preds,
                                        branch_info, block_order, W; phi_block)
                fv = resolve_phi_muxes!(gates, wa, false_set, preds,
                                        branch_info, block_order, W; phi_block)
                return lower_mux!(gates, wa, cond_wire, tv, fv, W)
            else
                # Diamond merge: resolve ambiguous once, include in both branches
                shared = resolve_phi_muxes!(gates, wa, ambig, preds,
                                            branch_info, block_order, W; phi_block)
                sb = ambig[1][2]
                tv = resolve_phi_muxes!(gates, wa, vcat(true_set, [(shared, sb)]),
                                        preds, branch_info, block_order, W; phi_block)
                fv = resolve_phi_muxes!(gates, wa, vcat(false_set, [(shared, sb)]),
                                        preds, branch_info, block_order, W; phi_block)
                return lower_mux!(gates, wa, cond_wire, tv, fv, W)
            end
        end
    end

    blocks_left = [b for (_, b) in incoming]
    error("Cannot resolve phi node: no branch cleanly partitions $(length(incoming)) incoming values from blocks: $blocks_left")
end

# ---- binary-op dispatch ----

"""
    _pick_add_strategy(user_choice, W, op2_dead, liveness_enabled) -> Symbol

Resolve an `add=:auto|:ripple|:cuccaro|:qcla` user choice into one of the
three concrete strategies. `:auto` preserves the pre-D1 default:
Cuccaro when in-place is safe (liveness available AND op2 is dead), ripple
otherwise. Explicit choices bypass the heuristic.
"""
function _pick_add_strategy(user_choice::Symbol, W::Int, op2_dead::Bool, liveness_enabled::Bool)
    user_choice === :ripple  && return :ripple
    user_choice === :cuccaro && return :cuccaro
    user_choice === :qcla    && return :qcla
    user_choice === :auto || error("_pick_add_strategy: unknown choice :$user_choice")
    (liveness_enabled && op2_dead) ? :cuccaro : :ripple
end

"""
    _pick_mul_strategy(user_choice, W, use_karatsuba) -> Symbol

Resolve `mul=:auto|:shift_add|:karatsuba|:qcla_tree` into a concrete
strategy. `:auto` preserves the pre-P2 default: Karatsuba when the legacy
`use_karatsuba` kwarg is set AND W > 4, else shift-and-add. Explicit
choices bypass the heuristic.
"""
function _pick_mul_strategy(user_choice::Symbol, W::Int, use_karatsuba::Bool)
    user_choice === :shift_add && return :shift_add
    user_choice === :karatsuba && return :karatsuba
    user_choice === :qcla_tree && return :qcla_tree
    user_choice === :auto || error("_pick_mul_strategy: unknown choice :$user_choice")
    (use_karatsuba && W > 4) ? :karatsuba : :shift_add
end

function lower_binop!(gates, wa, vw, inst::IRBinOp;
                      ssa_liveness::Dict{Symbol,Int}=Dict{Symbol,Int}(),
                      inst_idx::Int=0,
                      use_karatsuba::Bool=false,
                      add::Symbol=:auto, mul::Symbol=:auto)
    a = resolve!(gates, wa, vw, inst.op1, inst.width)
    W = inst.width

    result = if inst.op in (:shl, :lshr, :ashr)
        if inst.op2.kind == :const
            k = inst.op2.value
            if inst.op == :shl;   lower_shl!(gates, wa, a, k, W)
            elseif inst.op == :lshr; lower_lshr!(gates, wa, a, k, W)
            else                      lower_ashr!(gates, wa, a, k, W)
            end
        else
            b = resolve!(gates, wa, vw, inst.op2, inst.width)
            if inst.op == :shl;   lower_var_shl!(gates, wa, a, b, W)
            elseif inst.op == :lshr; lower_var_lshr!(gates, wa, a, b, W)
            else                      lower_var_ashr!(gates, wa, a, b, W)
            end
        end
    else
        b = resolve!(gates, wa, vw, inst.op2, inst.width)
        # Use Cuccaro in-place adder when op2 is dead after this instruction.
        # Constants are always safe (their wires are freshly allocated by resolve!).
        # SSA vars are safe when this is their last use (liveness[name] <= inst_idx).
        op2_dead = inst.op2.kind == :const ||
                   (inst.op2.kind == :ssa && get(ssa_liveness, inst.op2.name, 0) <= inst_idx)
        if inst.op == :add
            strat = _pick_add_strategy(add, W, op2_dead, !isempty(ssa_liveness))
            if strat == :cuccaro
                lower_add_cuccaro!(gates, wa, a, b, W)
            elseif strat == :qcla
                lower_add_qcla!(gates, wa, a, b, W)[1:W]   # drop carry-out
            else
                lower_add!(gates, wa, a, b, W)
            end
        elseif inst.op == :sub; lower_sub!(gates, wa, a, b, W)
        elseif inst.op == :mul
            mstrat = _pick_mul_strategy(mul, W, use_karatsuba)
            if mstrat == :karatsuba
                lower_mul_karatsuba!(gates, wa, a, b, W)
            elseif mstrat == :qcla_tree
                lower_mul_qcla_tree!(gates, wa, a, b, W)[1:W]   # mod 2^W
            else
                lower_mul!(gates, wa, a, b, W)
            end
        elseif inst.op == :and; lower_and!(gates, wa, a, b, W)
        elseif inst.op == :or;  lower_or!(gates, wa, a, b, W)
        elseif inst.op == :xor; lower_xor!(gates, wa, a, b, W)
        elseif inst.op in (:udiv, :urem, :sdiv, :srem)
            lower_divrem!(gates, wa, vw, inst, a, b, W)
        else error("Unknown binop: $(inst.op)")
        end
    end

    vw[inst.dest] = result
end

# ---- bitwise ----

function lower_and!(g, wa, a, b, W)
    r = allocate!(wa, W)
    for i in 1:W; push!(g, ToffoliGate(a[i], b[i], r[i])); end
    return r
end

function lower_or!(g, wa, a, b, W)
    r = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], r[i]))
        push!(g, CNOTGate(b[i], r[i]))
        push!(g, ToffoliGate(a[i], b[i], r[i]))
    end
    return r
end

function lower_xor!(g, wa, a, b, W)
    r = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], r[i]))
        push!(g, CNOTGate(b[i], r[i]))
    end
    return r
end

# ---- shifts (constant amount only) ----

function lower_shl!(g, wa, a, k, W)
    r = allocate!(wa, W)
    for i in (k + 1):W; push!(g, CNOTGate(a[i - k], r[i])); end
    return r
end

function lower_lshr!(g, wa, a, k, W)
    r = allocate!(wa, W)
    for i in 1:(W - k); push!(g, CNOTGate(a[i + k], r[i])); end
    return r
end

function lower_ashr!(g, wa, a, k, W)
    r = allocate!(wa, W)
    for i in 1:(W - k); push!(g, CNOTGate(a[i + k], r[i])); end
    for i in (W - k + 1):W; push!(g, CNOTGate(a[W], r[i])); end
    return r
end

# ---- variable-amount shifts (barrel shifter) ----

_shift_stages(W, b_len) = min(b_len, W <= 1 ? 0 : ceil(Int, log2(W)))

function lower_var_lshr!(g, wa, a, b, W)
    result = allocate!(wa, W)
    for i in 1:W; push!(g, CNOTGate(a[i], result[i])); end
    for k in 0:_shift_stages(W, length(b))-1
        s = 1 << k
        s >= W && break
        shifted = allocate!(wa, W)
        for i in 1:W
            src = i + s
            src <= W && push!(g, CNOTGate(result[src], shifted[i]))
        end
        result = lower_mux!(g, wa, [b[k+1]], shifted, result, W)
    end
    return result
end

function lower_var_shl!(g, wa, a, b, W)
    result = allocate!(wa, W)
    for i in 1:W; push!(g, CNOTGate(a[i], result[i])); end
    for k in 0:_shift_stages(W, length(b))-1
        s = 1 << k
        s >= W && break
        shifted = allocate!(wa, W)
        for i in 1:W
            src = i - s
            src >= 1 && push!(g, CNOTGate(result[src], shifted[i]))
        end
        result = lower_mux!(g, wa, [b[k+1]], shifted, result, W)
    end
    return result
end

function lower_var_ashr!(g, wa, a, b, W)
    result = allocate!(wa, W)
    for i in 1:W; push!(g, CNOTGate(a[i], result[i])); end
    for k in 0:_shift_stages(W, length(b))-1
        s = 1 << k
        s >= W && break
        shifted = allocate!(wa, W)
        for i in 1:W
            src = i + s
            if src <= W
                push!(g, CNOTGate(result[src], shifted[i]))
            else
                push!(g, CNOTGate(result[W], shifted[i]))
            end
        end
        result = lower_mux!(g, wa, [b[k+1]], shifted, result, W)
    end
    return result
end

# ---- comparison (icmp) ----

function lower_icmp!(gates, wa, vw, inst::IRICmp)
    a = resolve!(gates, wa, vw, inst.op1, inst.width)
    b = resolve!(gates, wa, vw, inst.op2, inst.width)
    W = inst.width; p = inst.predicate

    result = if p == :eq;  lower_eq!(gates, wa, a, b, W)
    elseif p == :ne;       lower_not1!(gates, wa, lower_eq!(gates, wa, a, b, W))
    elseif p == :ult;      lower_ult!(gates, wa, a, b, W)
    elseif p == :ugt;      lower_ult!(gates, wa, b, a, W)
    elseif p == :ule;      lower_not1!(gates, wa, lower_ult!(gates, wa, b, a, W))
    elseif p == :uge;      lower_not1!(gates, wa, lower_ult!(gates, wa, a, b, W))
    elseif p == :slt;      lower_slt!(gates, wa, a, b, W)
    elseif p == :sgt;      lower_slt!(gates, wa, b, a, W)
    elseif p == :sle;      lower_not1!(gates, wa, lower_slt!(gates, wa, b, a, W))
    elseif p == :sge;      lower_not1!(gates, wa, lower_slt!(gates, wa, a, b, W))
    else error("Unknown icmp predicate: $p")
    end
    vw[inst.dest] = result
end

function lower_eq!(g, wa, a, b, W)
    diff = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], diff[i]))
        push!(g, CNOTGate(b[i], diff[i]))
    end
    if W == 1
        r = allocate!(wa, 1)
        push!(g, CNOTGate(diff[1], r[1])); push!(g, NOTGate(r[1]))
        return r
    end
    or = allocate!(wa, W - 1)
    push!(g, CNOTGate(diff[1], or[1]))
    push!(g, CNOTGate(diff[2], or[1]))
    push!(g, ToffoliGate(diff[1], diff[2], or[1]))
    for k in 2:(W - 1)
        push!(g, CNOTGate(or[k - 1], or[k]))
        push!(g, CNOTGate(diff[k + 1], or[k]))
        push!(g, ToffoliGate(or[k - 1], diff[k + 1], or[k]))
    end
    r = allocate!(wa, 1)
    push!(g, CNOTGate(or[W - 1], r[1])); push!(g, NOTGate(r[1]))
    return r
end

function lower_ult!(g, wa, a, b, W)
    nb = allocate!(wa, W)
    for i in 1:W; push!(g, CNOTGate(b[i], nb[i])); push!(g, NOTGate(nb[i])); end
    carry = allocate!(wa, W + 1)
    push!(g, NOTGate(carry[1]))
    axnb = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], axnb[i])); push!(g, CNOTGate(nb[i], axnb[i]))
        push!(g, ToffoliGate(a[i], nb[i], carry[i + 1]))
        push!(g, ToffoliGate(axnb[i], carry[i], carry[i + 1]))
    end
    r = allocate!(wa, 1)
    push!(g, CNOTGate(carry[W + 1], r[1])); push!(g, NOTGate(r[1]))
    return r
end

function lower_slt!(g, wa, a, b, W)
    af = allocate!(wa, W); bf = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], af[i])); push!(g, CNOTGate(b[i], bf[i]))
    end
    push!(g, NOTGate(af[W])); push!(g, NOTGate(bf[W]))
    return lower_ult!(g, wa, af, bf, W)
end

function lower_not1!(g, wa, w::Vector{Int})
    r = allocate!(wa, 1)
    push!(g, CNOTGate(w[1], r[1])); push!(g, NOTGate(r[1]))
    return r
end

# ---- select (mux) ----

function lower_select!(gates, wa, vw, inst::IRSelect; ctx::Union{Nothing,LoweringCtx}=nothing)
    # Bennett-cc0 M2b: pointer-typed select (width=0 sentinel). Metadata-only
    # routing: merge origins from both sides, guarded by cond / NOT(cond).
    if inst.width == 0
        ctx === nothing &&
            error("lower_select!: ptr-select %$(inst.dest) requires ctx for ptr_provenance threading")
        inst.op1.kind == :ssa ||
            error("lower_select!: ptr-select %$(inst.dest) true-side is non-SSA ($(inst.op1))")
        inst.op2.kind == :ssa ||
            error("lower_select!: ptr-select %$(inst.dest) false-side is non-SSA ($(inst.op2))")
        haskey(ctx.ptr_provenance, inst.op1.name) ||
            error("lower_select!: ptr-select %$(inst.dest) true-side %$(inst.op1.name) has no provenance")
        haskey(ctx.ptr_provenance, inst.op2.name) ||
            error("lower_select!: ptr-select %$(inst.dest) false-side %$(inst.op2.name) has no provenance")

        cond = resolve!(gates, wa, vw, inst.cond, 1)
        not_cond = _not_wire!(gates, wa, cond)

        merged = PtrOrigin[]
        for o in ctx.ptr_provenance[inst.op1.name]
            combined = _and_wire!(gates, wa, [o.predicate_wire], cond)
            push!(merged, PtrOrigin(o.alloca_dest, o.idx_op, combined[1]))
        end
        for o in ctx.ptr_provenance[inst.op2.name]
            combined = _and_wire!(gates, wa, [o.predicate_wire], not_cond)
            push!(merged, PtrOrigin(o.alloca_dest, o.idx_op, combined[1]))
        end
        length(merged) <= 8 ||
            error("lower_select!: ptr-select %$(inst.dest) fan-out $(length(merged)) > 8 " *
                  "exceeds M2b budget; file a bd issue")
        ctx.ptr_provenance[inst.dest] = merged
        return  # no vw[inst.dest] — pointers don't materialize as wires
    end

    cond = resolve!(gates, wa, vw, inst.cond, 1)
    tv   = resolve!(gates, wa, vw, inst.op1, inst.width)
    fv   = resolve!(gates, wa, vw, inst.op2, inst.width)
    vw[inst.dest] = lower_mux!(gates, wa, cond, tv, fv, inst.width)
end

function lower_mux!(g, wa, cond, tv, fv, W)
    r    = allocate!(wa, W)
    diff = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(fv[i], r[i]))
        push!(g, CNOTGate(tv[i], diff[i]))
        push!(g, CNOTGate(fv[i], diff[i]))
        push!(g, ToffoliGate(cond[1], diff[i], r[i]))
    end
    return r
end

# ---- casts (sext, zext, trunc) ----

function lower_cast!(gates, wa, vw, inst::IRCast)
    src = resolve!(gates, wa, vw, inst.operand, inst.from_width)
    F = inst.from_width
    T = inst.to_width
    r = allocate!(wa, T)

    if inst.op == :zext
        for i in 1:F; push!(gates, CNOTGate(src[i], r[i])); end
    elseif inst.op == :sext
        for i in 1:F; push!(gates, CNOTGate(src[i], r[i])); end
        for i in F+1:T; push!(gates, CNOTGate(src[F], r[i])); end
    elseif inst.op == :trunc
        for i in 1:T; push!(gates, CNOTGate(src[i], r[i])); end
    else
        error("Unknown cast op: $(inst.op)")
    end

    vw[inst.dest] = r
end

# ---- aggregate operations ----

"""
    lower_divrem!(gates, wa, vw, inst, a, b, W)

Lower udiv/urem/sdiv/srem by widening operands to UInt64, calling the
soft division function via gate-level inlining, and truncating back.
"""
function lower_divrem!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                       vw::Dict{Symbol,Vector{Int}}, inst::IRBinOp,
                       a::Vector{Int}, b::Vector{Int}, W::Int)
    # Widen a and b to 64 bits (zero-extend for unsigned, sign-extend for signed)
    signed = inst.op in (:sdiv, :srem)
    a64 = allocate!(wa, 64)
    b64 = allocate!(wa, 64)
    for i in 1:W
        push!(gates, CNOTGate(a[i], a64[i]))
        push!(gates, CNOTGate(b[i], b64[i]))
    end
    if signed
        # Sign-extend: copy MSB to upper bits
        for i in (W+1):64
            push!(gates, CNOTGate(a[W], a64[i]))
            push!(gates, CNOTGate(b[W], b64[i]))
        end
    end
    # Upper bits stay 0 for unsigned (already allocated as 0)

    # For signed: convert to unsigned magnitude, divide, fix sign
    # sdiv(a,b) = sign(a)*sign(b) * udiv(|a|, |b|)
    # srem(a,b) = sign(a) * urem(|a|, |b|)
    if signed
        # Compute |a| and |b| by conditional negate
        a_sign = allocate!(wa, 1)
        b_sign = allocate!(wa, 1)
        push!(gates, CNOTGate(a64[64], a_sign[1]))
        push!(gates, CNOTGate(b64[64], b_sign[1]))

        # |a| = a_sign ? -a : a  (two's complement negate = flip all + add 1)
        _cond_negate_inplace!(gates, wa, a64, a_sign, 64)
        _cond_negate_inplace!(gates, wa, b64, b_sign, 64)
    end

    # Select callee
    callee = (inst.op in (:udiv, :sdiv)) ? soft_udiv : soft_urem

    # Create IRCall and lower it
    call_dest = Symbol("__div_$(inst.dest)")
    call_inst = IRCall(call_dest, callee,
                       [ssa(Symbol("__div_a64_$(inst.dest)")),
                        ssa(Symbol("__div_b64_$(inst.dest)"))],
                       [64, 64], 64)
    # Register the widened operands in vw
    vw[Symbol("__div_a64_$(inst.dest)")] = a64
    vw[Symbol("__div_b64_$(inst.dest)")] = b64
    lower_call!(gates, wa, vw, call_inst)

    result64 = vw[call_dest]

    if signed
        # Fix sign of result
        if inst.op == :sdiv
            # Result sign = XOR of input signs
            result_sign = allocate!(wa, 1)
            push!(gates, CNOTGate(a_sign[1], result_sign[1]))
            push!(gates, CNOTGate(b_sign[1], result_sign[1]))
            _cond_negate_inplace!(gates, wa, result64, result_sign, 64)
        else  # srem
            # Remainder sign follows dividend
            _cond_negate_inplace!(gates, wa, result64, a_sign, 64)
        end
    end

    # Truncate to W bits
    result = allocate!(wa, W)
    for i in 1:W
        push!(gates, CNOTGate(result64[i], result[i]))
    end
    vw[inst.dest] = result
end

"""Conditionally negate a value in-place: if cond=1, val = -val (two's complement)."""
function _cond_negate_inplace!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                               val::Vector{Int}, cond::Vector{Int}, W::Int)
    # Two's complement negate = flip all bits + add 1
    # Conditional flip: CNOT(cond, val[i]) for each bit
    for i in 1:W
        push!(gates, CNOTGate(cond[1], val[i]))
    end
    # Conditional add 1: ripple carry adding cond[1] to val
    carry = allocate!(wa, 1)
    push!(gates, CNOTGate(cond[1], carry[1]))  # carry starts as cond
    for i in 1:W
        # val[i] += carry; new_carry = val[i] AND carry (before add)
        next_carry = allocate!(wa, 1)
        push!(gates, ToffoliGate(val[i], carry[1], next_carry[1]))
        push!(gates, CNOTGate(carry[1], val[i]))
        carry = next_carry
    end
end

"""GEP with constant offset: record that dest points to base + offset_bytes."""
function lower_ptr_offset!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                           vw::Dict{Symbol,Vector{Int}}, inst::IRPtrOffset;
                           ptr_provenance::Union{Nothing,Dict{Symbol,Vector{PtrOrigin}}}=nothing,
                           alloca_info::Union{Nothing,Dict{Symbol,Tuple{Int,Int}}}=nothing)
    # The base operand should be a flat wire array (from ptr param)
    if !haskey(vw, inst.base.name)
        error("GEP base $(inst.base.name) not found in variable wires")
    end
    base_wires = vw[inst.base.name]
    # PtrOffset just records a view into the base array at byte offset
    # Store as a synthetic entry: (base_wires, byte_offset)
    # For simplicity, slice the wire array
    bit_offset = inst.offset_bytes * 8
    # Store a reference — the IRLoad will do the actual copy
    vw[inst.dest] = base_wires[(bit_offset + 1):end]

    # Bennett-cc0 M2b: propagate pointer provenance per-origin. For each
    # origin of the base (typically 1 pre-M2b; >1 after a ptr-phi/select),
    # bump the element index by offset_bytes (MVP: elem_width = 8). Preserves
    # the predicate_wire per origin — the GEP is a pure index map, not a
    # control-flow merge.
    if ptr_provenance !== nothing && alloca_info !== nothing
        base_origins = if haskey(ptr_provenance, inst.base.name)
            ptr_provenance[inst.base.name]
        else
            PtrOrigin[]
        end
        new_origins = PtrOrigin[]
        for o in base_origins
            o.idx_op.kind == :const || continue  # non-const base idx: skip
            info = get(alloca_info, o.alloca_dest, nothing)
            info === nothing && continue
            ew = first(info)
            ew == 8 || continue  # non-MVP; skip this origin
            new_idx = iconst(o.idx_op.value + inst.offset_bytes)
            push!(new_origins, PtrOrigin(o.alloca_dest, new_idx, o.predicate_wire))
        end
        if !isempty(new_origins)
            ptr_provenance[inst.dest] = new_origins
        end
    end
end

"""
Variable-index GEP: MUX-tree selecting one element by runtime index.

The base pointer's wires are a flattened array of N elements of W bits each.
The index selects which W-bit element to produce, via a binary MUX tree
with ceil(log2(N)) levels.

T1c.2: when the base is a compile-time-constant global (present in `globals`),
dispatch to QROM (Babbush-Gidney unary iteration) instead — O(L) Toffolis and
W-independent, vs MUX's O(L·W). See `emit_qrom!`.
"""
function lower_var_gep!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                        vw::Dict{Symbol,Vector{Int}}, inst::IRVarGEP;
                        ptr_provenance::Union{Nothing,Dict{Symbol,Vector{PtrOrigin}}}=nothing,
                        alloca_info::Union{Nothing,Dict{Symbol,Tuple{Int,Int}}}=nothing,
                        globals::Union{Nothing,Dict{Symbol,Tuple{Vector{UInt64},Int}}}=nothing)
    # T1c.2: constant global table → QROM
    if globals !== nothing && haskey(globals, inst.base.name)
        data, gw = globals[inst.base.name]
        gw == inst.elem_width ||
            error("VarGEP elem_width=$(inst.elem_width) disagrees with global $(inst.base.name) elem_width=$gw")
        vw[inst.dest] = _emit_qrom_from_gep!(gates, wa, vw, data, inst.index, inst.elem_width)
        return
    end

    # Bennett-cc0 M2b: if base is an alloca, record provenance per-origin so
    # lower_store!/lower_load! can route through the right callee. The dynamic
    # index is uniform across origins — each origin gets the same `inst.index`
    # with its existing `predicate_wire`.
    if ptr_provenance !== nothing && alloca_info !== nothing &&
       haskey(alloca_info, inst.base.name)
        # Single-origin producer path — use the entry predicate as the guard.
        # (lower_alloca! already registers this origin; this branch handles
        # the case where the base is a raw alloca reference, not itself an
        # SSA name carrying multi-origin provenance.)
        base_origins = get(ptr_provenance, inst.base.name, PtrOrigin[])
        if !isempty(base_origins)
            new_origins = PtrOrigin[]
            for o in base_origins
                push!(new_origins, PtrOrigin(o.alloca_dest, inst.index, o.predicate_wire))
            end
            ptr_provenance[inst.dest] = new_origins
        end
    end

    haskey(vw, inst.base.name) ||
        error("VarGEP base $(inst.base.name) not found in variable wires")
    base_wires = vw[inst.base.name]
    W = inst.elem_width
    N = length(base_wires) ÷ W
    N >= 1 || error("VarGEP: base has $(length(base_wires)) wires but elem is $W bits")

    # Resolve index — may be wider than needed (e.g., i64 for a 4-element array)
    idx_wires = resolve!(gates, wa, vw, inst.index, 0)
    idx_bits = max(1, ceil(Int, log2(N)))

    # Extract element slices
    candidates = [base_wires[((k-1)*W+1):(k*W)] for k in 1:N]

    # Pad to next power of 2 (replicate last element)
    N_padded = 1 << idx_bits
    while length(candidates) < N_padded
        push!(candidates, candidates[end])
    end

    # Binary MUX tree: each level halves the candidates using one index bit
    for level in 0:(idx_bits - 1)
        bit = idx_wires[level + 1]  # LSB first
        next = Vector{Int}[]
        for j in 1:2:length(candidates)
            # bit=0 → candidates[j], bit=1 → candidates[j+1]
            muxed = lower_mux!(gates, wa, [bit], candidates[j+1], candidates[j], W)
            push!(next, muxed)
        end
        candidates = next
    end

    # Store the selected W-bit value — subsequent IRLoad will CNOT-copy from it
    vw[inst.dest] = candidates[1]
end

"""
Provenance-aware lower_load! entry point (T1b.3). If the ptr was produced by
a GEP off a known alloca, route through soft_mux_load_4x8 so we read the
current post-store state rather than a stale slice-alias of vw[ptr].
Otherwise delegate to the legacy load path (pointer parameters, NTuple input).
"""
function lower_load!(ctx::LoweringCtx, inst::IRLoad)
    if inst.ptr.kind == :ssa && haskey(ctx.ptr_provenance, inst.ptr.name)
        origins = ctx.ptr_provenance[inst.ptr.name]
        isempty(origins) &&
            error("lower_load!: empty origin set for ptr %$(inst.ptr.name)")
        if length(origins) == 1
            _lower_load_via_mux!(ctx, inst, origins[1])
        else
            _lower_load_multi_origin!(ctx, inst, origins)
        end
    else
        lower_load!(ctx.gates, ctx.wa, ctx.vw, inst)
    end
end

"""Bennett-cc0 M2b — multi-origin pointer load. Allocate a fresh W-wire
result (zero by WireAllocator invariant); per origin, emit
`ToffoliGate(origin.predicate_wire, primal[i], result[i])` for each bit.
At runtime exactly one predicate is 1, so exactly one origin XORs its
slot bits into the zero-initialised result — yielding the selected value.
Bennett's reverse pass unwinds symmetrically (Toffoli is self-inverse;
predicate wires are write-once).
"""
function _lower_load_multi_origin!(ctx::LoweringCtx, inst::IRLoad,
                                   origins::Vector{PtrOrigin})
    length(origins) <= 8 ||
        error("_lower_load_multi_origin!: fan-out of $(length(origins)) > 8 " *
              "origins exceeds M2b budget; file a bd issue")
    W = inst.width
    result = allocate!(ctx.wa, W)  # zero by WireAllocator invariant
    for o in origins
        info = get(ctx.alloca_info, o.alloca_dest, nothing)
        info === nothing &&
            error("_lower_load_multi_origin!: unknown alloca %$(o.alloca_dest)")
        elem_w, n = info
        W == elem_w ||
            error("_lower_load_multi_origin!: load width=$W vs origin $(o.alloca_dest) elem_width=$elem_w")
        o.idx_op.kind == :const ||
            error("_lower_load_multi_origin!: multi-origin ptr with dynamic idx is NYI")
        0 <= o.idx_op.value < n ||
            error("_lower_load_multi_origin!: idx=$(o.idx_op.value) out of range [0, $n)")

        arr_wires = ctx.vw[o.alloca_dest]
        length(arr_wires) == elem_w * n ||
            error("_lower_load_multi_origin!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

        primal_slot = arr_wires[o.idx_op.value * elem_w + 1 : (o.idx_op.value + 1) * elem_w]
        for i in 1:W
            push!(ctx.gates, ToffoliGate(o.predicate_wire, primal_slot[i], result[i]))
        end
    end
    ctx.vw[inst.dest] = result
    return nothing
end

function _lower_load_via_mux!(ctx::LoweringCtx, inst::IRLoad, origin::PtrOrigin)
    alloca_dest = origin.alloca_dest
    idx_op = origin.idx_op
    info = ctx.alloca_info[alloca_dest]

    strategy = _pick_alloca_strategy(info, idx_op)

    if strategy == :shadow
        return _lower_load_via_shadow!(ctx, inst, alloca_dest, info, idx_op)
    elseif strategy == :mux_exch_2x8
        return _lower_load_via_mux_2x8!(ctx, inst, alloca_dest, info, idx_op)
    elseif strategy == :mux_exch_4x8
        return _lower_load_via_mux_4x8!(ctx, inst, alloca_dest, info, idx_op)
    elseif strategy == :mux_exch_8x8
        return _lower_load_via_mux_8x8!(ctx, inst, alloca_dest, info, idx_op)
    elseif strategy == :mux_exch_2x16
        return _lower_load_via_mux_2x16!(ctx, inst, alloca_dest, info, idx_op)
    elseif strategy == :mux_exch_4x16
        return _lower_load_via_mux_4x16!(ctx, inst, alloca_dest, info, idx_op)
    elseif strategy == :mux_exch_2x32
        return _lower_load_via_mux_2x32!(ctx, inst, alloca_dest, info, idx_op)
    else
        error("_lower_load_via_mux!: unsupported (elem_width=$(info[1]), n_elems=$(info[2])) for dynamic idx")
    end
end

# T3b.3 shadow-memory load for static idx: just CNOT-copy the target slot.
function _lower_load_via_shadow!(ctx::LoweringCtx, inst::IRLoad,
                                  alloca_dest::Symbol, info::Tuple{Int,Int},
                                  idx_op::IROperand)
    elem_w, n = info
    inst.width == elem_w ||
        error("_lower_load_via_shadow!: load width=$(inst.width) doesn't match elem_width=$elem_w")
    0 <= idx_op.value < n ||
        error("_lower_load_via_shadow!: idx=$(idx_op.value) out of range [0, $n)")

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        error("_lower_load_via_shadow!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

    primal_slot = arr_wires[idx_op.value * elem_w + 1 : (idx_op.value + 1) * elem_w]
    ctx.vw[inst.dest] = emit_shadow_load!(ctx.gates, ctx.wa, primal_slot, elem_w)
    return nothing
end

function _lower_load_via_mux_4x8!(ctx::LoweringCtx, inst::IRLoad,
                                   alloca_dest::Symbol, info::Tuple{Int,Int},
                                   idx_op::IROperand)
    inst.width == 8 ||
        error("_lower_load_via_mux_4x8!: load width must be 8, got $(inst.width)")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == 32 ||
        error("_lower_load_via_mux_4x8!: expected 32-wire packed array at alloca $alloca_dest; got $(length(arr_wires))")

    tag = _next_mux_tag!(ctx, "ld", inst.dest)
    arr_sym = Symbol("__mux_load_arr_", tag)
    idx_sym = Symbol("__mux_load_idx_", tag)
    tmp_sym = Symbol("__mux_load_u64_", tag)

    ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
    ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)

    call = IRCall(tmp_sym, soft_mux_load_4x8,
                  [ssa(arr_sym), ssa(idx_sym)], [64, 64], 64)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[inst.dest] = ctx.vw[tmp_sym][1:8]
    return nothing
end

function _lower_load_via_mux_8x8!(ctx::LoweringCtx, inst::IRLoad,
                                   alloca_dest::Symbol, info::Tuple{Int,Int},
                                   idx_op::IROperand)
    inst.width == 8 ||
        error("_lower_load_via_mux_8x8!: load width must be 8, got $(inst.width)")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == 64 ||
        error("_lower_load_via_mux_8x8!: expected 64-wire packed array at alloca $alloca_dest")

    tag = _next_mux_tag!(ctx, "ld", inst.dest)
    arr_sym = Symbol("__mux_load_arr_", tag)
    idx_sym = Symbol("__mux_load_idx_", tag)
    tmp_sym = Symbol("__mux_load_u64_", tag)

    ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
    ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)

    call = IRCall(tmp_sym, soft_mux_load_8x8,
                  [ssa(arr_sym), ssa(idx_sym)], [64, 64], 64)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[inst.dest] = ctx.vw[tmp_sym][1:8]
    return nothing
end

"""Load from pointer/GEP: CNOT-copy W bits from the wire array."""
function lower_load!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                     vw::Dict{Symbol,Vector{Int}}, inst::IRLoad)
    if !haskey(vw, inst.ptr.name)
        # Load from unknown pointer — skip (may be pgcstack safepoint load)
        return
    end
    src_wires = vw[inst.ptr.name]
    W = inst.width
    if length(src_wires) < W
        error("Load of $W bits from $(inst.ptr.name) but only $(length(src_wires)) wires available")
    end
    result = allocate!(wa, W)
    for i in 1:W
        push!(gates, CNOTGate(src_wires[i], result[i]))
    end
    vw[inst.dest] = result
end

function lower_extractvalue!(gates, wa, vw, inst::IRExtractValue)
    total_w = inst.elem_width * inst.n_elems
    agg_wires = resolve!(gates, wa, vw, inst.agg, total_w)

    # Select the wires for the requested element — zero gates (wire aliasing)
    offset = inst.index * inst.elem_width
    result = allocate!(wa, inst.elem_width)
    for i in 1:inst.elem_width
        push!(gates, CNOTGate(agg_wires[offset + i], result[i]))
    end
    vw[inst.dest] = result
end

function lower_insertvalue!(gates, wa, vw, inst::IRInsertValue)
    total_w = inst.elem_width * inst.n_elems
    val_wires = resolve!(gates, wa, vw, inst.val, inst.elem_width)

    # Resolve or create the aggregate
    if inst.agg.kind == :const && inst.agg.name == :__zero_agg__
        agg_wires = allocate!(wa, total_w)  # all zero already
    else
        agg_wires = resolve!(gates, wa, vw, inst.agg, total_w)
    end

    # Copy aggregate, replacing element at `index`
    result = allocate!(wa, total_w)
    iv_offset = inst.index * inst.elem_width  # 0-based index
    for i in 1:total_w
        if i > iv_offset && i <= iv_offset + inst.elem_width
            push!(gates, CNOTGate(val_wires[i - iv_offset], result[i]))
        else
            push!(gates, CNOTGate(agg_wires[i], result[i]))
        end
    end

    vw[inst.dest] = result
end

# ---- function call inlining ----

"""
    lower_call!(gates, wa, vw, inst::IRCall)

Inline a function call by pre-compiling the callee into a sub-circuit and
inserting its forward gates with wire remapping. The callee's inputs are
connected via CNOT-copy from the caller's argument wires, and the callee's
output wires become the caller's result wires.
"""
function lower_call!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                     vw::Dict{Symbol,Vector{Int}}, inst::IRCall;
                     compact::Bool=false)
    # Pre-compile the callee function
    arg_types = Tuple{(UInt64 for _ in inst.args)...}
    callee_parsed = extract_parsed_ir(inst.callee, arg_types)
    callee_lr = lower(callee_parsed; max_loop_iterations=64)

    if compact
        # Apply Bennett to callee: forward + copy output + reverse.
        # This frees all intermediate wires, keeping only the output.
        callee_circuit = bennett(callee_lr)

        wire_offset = wire_count(wa)
        allocate!(wa, callee_circuit.n_wires)

        # Connect caller arguments → callee input wires (CNOT copy)
        for (i, arg_op) in enumerate(inst.args)
            caller_wires = resolve!(gates, wa, vw, arg_op, inst.arg_widths[i])
            w = inst.arg_widths[i]
            callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)
            for bit in 1:w
                callee_wire = callee_circuit.input_wires[callee_start + bit] + wire_offset
                push!(gates, CNOTGate(caller_wires[bit], callee_wire))
            end
        end

        # Insert ALL callee gates (forward + copy + reverse) with wire offset
        for g in callee_circuit.gates
            push!(gates, _remap_gate(g, wire_offset))
        end

        # The callee's output wires (remapped) are the Bennett copy wires
        result_wires = [w + wire_offset for w in callee_circuit.output_wires]
        vw[inst.dest] = result_wires
    else
        # Original behavior: insert only forward gates, caller's Bennett handles cleanup
        wire_offset = wire_count(wa)
        allocate!(wa, callee_lr.n_wires)

        # Connect caller arguments → callee input wires (CNOT copy)
        for (i, arg_op) in enumerate(inst.args)
            caller_wires = resolve!(gates, wa, vw, arg_op, inst.arg_widths[i])
            w = inst.arg_widths[i]
            callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)
            for bit in 1:w
                callee_wire = callee_lr.input_wires[callee_start + bit] + wire_offset
                push!(gates, CNOTGate(caller_wires[bit], callee_wire))
            end
        end

        # Insert callee's forward gates with wire offset
        for g in callee_lr.gates
            push!(gates, _remap_gate(g, wire_offset))
        end

        # The callee's output wires (remapped) become the result
        result_wires = [w + wire_offset for w in callee_lr.output_wires]
        vw[inst.dest] = result_wires
    end
end

function _remap_gate(g::NOTGate, offset::Int)
    NOTGate(g.target + offset)
end
function _remap_gate(g::CNOTGate, offset::Int)
    CNOTGate(g.control + offset, g.target + offset)
end
function _remap_gate(g::ToffoliGate, offset::Int)
    ToffoliGate(g.control1 + offset, g.control2 + offset, g.target + offset)
end

# ---- T1b.3: reversible mutable memory (store/alloca) ----

"""
    lower_alloca!(ctx, inst::IRAlloca)

Allocate the wire range for a fresh reversible array and record it in the
per-compilation alloca_info + ptr_provenance maps. No gates are emitted —
fresh wires are zero by WireAllocator invariant.

MVP: only (elem_width=8, n_elems=iconst(4)) is accepted. Anything else errors
loudly; T1b.5 adds wider shapes.
"""
function lower_alloca!(ctx::LoweringCtx, inst::IRAlloca)
    inst.n_elems.kind == :const ||
        error("lower_alloca!: dynamic n_elems not supported (%$(inst.n_elems.name)); " *
              "T3b.3 shadow memory handles static-sized allocas only.")
    n = inst.n_elems.value
    n >= 1 || error("lower_alloca!: non-positive n_elems=$n")
    inst.elem_width >= 1 || error("lower_alloca!: non-positive elem_width=$(inst.elem_width)")

    total_bits = inst.elem_width * n
    wires = allocate!(ctx.wa, total_bits)       # zero by invariant
    ctx.vw[inst.dest] = wires
    ctx.alloca_info[inst.dest] = (inst.elem_width, n)
    # Bennett-cc0 M2b: single-origin provenance with the entry predicate as
    # the guard wire. The trivial "always-1" entry predicate lets downstream
    # multi-origin merges (lower_phi!/lower_select!) AND edge predicates with
    # the origin's guard uniformly, and keeps the single-origin fast path
    # byte-identical to pre-M2b (the entry predicate is always 1 at runtime).
    ctx.ptr_provenance[inst.dest] = [PtrOrigin(inst.dest, iconst(0),
                                               _entry_predicate_wire(ctx))]
    return nothing
end

"""Return the entry-block's single-wire path predicate (always 1).

Every `lower()` run installs a `NOTGate(pw[1])` on a fresh wire in the
entry block, so `ctx.block_pred[ctx.entry_label]` is a 1-vector whose only
wire is 1 at runtime. This is the default `predicate_wire` for single-
origin `PtrOrigin`s (alloca, GEP of known alloca): it satisfies the
multi-origin type shape without actually emitting a guard.

Fail-fast if called with the sentinel `entry_label = Symbol("")` (direct
`lower_block_insts!` callers that didn't go through `lower()`). In that
case the caller should supply the predicate explicitly.
"""
function _entry_predicate_wire(ctx::LoweringCtx)
    ctx.entry_label == Symbol("") &&
        error("_entry_predicate_wire: ctx has sentinel entry_label; direct " *
              "lower_block_insts! callers must either set entry_label or " *
              "bypass ptr_provenance usage")
    pw = get(ctx.block_pred, ctx.entry_label, Int[])
    length(pw) == 1 ||
        error("_entry_predicate_wire: expected single-wire predicate for " *
              "entry block $(ctx.entry_label), got $(length(pw)) wires")
    return pw[1]
end

"""
    _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand) -> Symbol

T3b.3 universal dispatcher: select the cheapest correct lowering for a
store/load into an alloca-backed region, given the (elem_width, n_elems)
shape and the runtime index operand.

Strategies:
  :shadow          — static idx (const), any shape. Cheap direct CNOT pattern.
  :mux_exch_NxW    — dynamic idx. N·W ≤ 64 (single-UInt64 packed).
                     M1: N ∈ {2,4,8}×W=8, N ∈ {2,4}×W=16, N=2×W=32.
  :unsupported     — dynamic idx on any shape with N·W > 64, or any shape
                     outside the covered set; caller must error.

Priority rule: static idx ALWAYS dispatches to :shadow. MUX EXCH only
engages when idx is dynamic and the shape matches a soft_mux_*_NxW callee
registered in Bennett.jl.
"""
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand)
    if idx.kind == :const
        return :shadow
    end
    (elem_w, n) = shape
    if elem_w == 8
        n == 2 && return :mux_exch_2x8
        n == 4 && return :mux_exch_4x8
        n == 8 && return :mux_exch_8x8
    elseif elem_w == 16
        n == 2 && return :mux_exch_2x16
        n == 4 && return :mux_exch_4x16
    elseif elem_w == 32
        n == 2 && return :mux_exch_2x32
    end
    return :unsupported
end

"""
    lower_store!(ctx, inst::IRStore)

Reversible write: dispatch to `soft_mux_store_4x8` via IRCall. The callee is
64-bit; we zero-extend the 32-bit packed array, idx, and val to 64 wires.
After the call, `vw[alloca_dest]` is rebound to the low 32 wires of the
callee's output — subsequent loads see the post-store state.

MVP: ptr must resolve via ptr_provenance to a (4, 8) alloca. Store width must
be 8. All other cases error loudly.
"""
function lower_store!(ctx::LoweringCtx, inst::IRStore, block_label::Symbol=Symbol(""))
    inst.ptr.kind == :ssa ||
        error("lower_store!: store to a constant pointer is not supported")

    haskey(ctx.ptr_provenance, inst.ptr.name) ||
        error("lower_store!: no provenance for ptr %$(inst.ptr.name); " *
              "store must target an alloca or GEP thereof")
    origins = ctx.ptr_provenance[inst.ptr.name]
    isempty(origins) &&
        error("lower_store!: empty origin set for ptr %$(inst.ptr.name)")

    # Bennett-cc0 M2b: single-origin fast path preserves every BENCHMARKS.md
    # baseline. Multi-origin (pointer phi/select) fans out to N guarded shadow
    # stores, one per origin, keyed on its path-predicate wire.
    if length(origins) == 1
        return _lower_store_single_origin!(ctx, inst, origins[1], block_label)
    end

    # Multi-origin fan-out. Each origin writes into its own alloca slot under
    # its own path-predicate guard. At runtime exactly one predicate is true
    # (mutual exclusion is guaranteed by the producer: ptr-phi/ptr-select
    # compose edge predicates that are pairwise-exclusive by construction).
    length(origins) <= 8 ||
        error("lower_store!: multi-origin fan-out of $(length(origins)) > 8 " *
              "origins exceeds M2b budget; file a bd issue for MUX-tree " *
              "collapse of deep ptr-phi chains")
    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, inst.width)
    for o in origins
        info = get(ctx.alloca_info, o.alloca_dest, nothing)
        info === nothing &&
            error("lower_store!: multi-origin ptr references unknown alloca %$(o.alloca_dest)")
        strategy = _pick_alloca_strategy(info, o.idx_op)
        strategy == :shadow ||
            error("lower_store!: multi-origin ptr with dynamic idx (origin=$(o.alloca_dest), " *
                  "strategy=$strategy) is NYI; file follow-up bd issue for multi-origin MUX EXCH")
        _emit_store_via_shadow_guarded!(ctx, inst, o.alloca_dest, info, o.idx_op,
                                        o.predicate_wire, val_wires)
    end
    return nothing
end

"""Single-origin store dispatch (Bennett-cc0 M2b). Pulled out of the old
`lower_store!` body so the fast path stays byte-identical to pre-M2b."""
function _lower_store_single_origin!(ctx::LoweringCtx, inst::IRStore,
                                     origin::PtrOrigin, block_label::Symbol)
    alloca_dest = origin.alloca_dest
    idx_op = origin.idx_op
    info = get(ctx.alloca_info, alloca_dest, nothing)
    info === nothing &&
        error("lower_store!: provenance points to unknown alloca %$alloca_dest")

    strategy = _pick_alloca_strategy(info, idx_op)

    if strategy == :shadow
        _lower_store_via_shadow!(ctx, inst, alloca_dest, info, idx_op, block_label)
    elseif strategy == :mux_exch_2x8
        _lower_store_via_mux_2x8!(ctx, inst, alloca_dest, idx_op; block_label=block_label)
    elseif strategy == :mux_exch_4x8
        _lower_store_via_mux_4x8!(ctx, inst, alloca_dest, idx_op; block_label=block_label)
    elseif strategy == :mux_exch_8x8
        _lower_store_via_mux_8x8!(ctx, inst, alloca_dest, idx_op; block_label=block_label)
    elseif strategy == :mux_exch_2x16
        _lower_store_via_mux_2x16!(ctx, inst, alloca_dest, idx_op; block_label=block_label)
    elseif strategy == :mux_exch_4x16
        _lower_store_via_mux_4x16!(ctx, inst, alloca_dest, idx_op; block_label=block_label)
    elseif strategy == :mux_exch_2x32
        _lower_store_via_mux_2x32!(ctx, inst, alloca_dest, idx_op; block_label=block_label)
    else
        error("lower_store!: unsupported (elem_width=$(info[1]), n_elems=$(info[2])) for dynamic idx")
    end
    return nothing
end

"""Bennett-cc0 M2b — emit a guarded shadow store for one origin of a
multi-origin pointer. `pred_wire` is the origin's path predicate; at
runtime exactly one origin's predicate is 1, so exactly one primal slot
receives the value.

`val_wires` must be the pre-resolved value wires — passed in so the fan-out
shares one resolution across all origins (avoids re-allocating the value
wire per origin).
"""
function _emit_store_via_shadow_guarded!(ctx::LoweringCtx, inst::IRStore,
                                         alloca_dest::Symbol, info::Tuple{Int,Int},
                                         idx_op::IROperand, pred_wire::Int,
                                         val_wires::Vector{Int})
    elem_w, n = info
    inst.width == elem_w ||
        error("_emit_store_via_shadow_guarded!: store width=$(inst.width) doesn't match alloca elem_width=$elem_w")
    idx_op.kind == :const ||
        error("_emit_store_via_shadow_guarded!: non-const idx not supported in multi-origin path")
    0 <= idx_op.value < n ||
        error("_emit_store_via_shadow_guarded!: idx=$(idx_op.value) out of range [0, $n)")

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        error("_emit_store_via_shadow_guarded!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

    primal_slot = arr_wires[idx_op.value * elem_w + 1 : (idx_op.value + 1) * elem_w]
    tape = allocate!(ctx.wa, elem_w)
    emit_shadow_store_guarded!(ctx.gates, ctx.wa, primal_slot, tape, val_wires,
                               elem_w, pred_wire)
    return nothing
end

# T3b.3 shadow-memory store: idx is compile-time constant, so we touch only
# the W wires of the target slot directly.
#
# Gate cost depends on block_label:
#   - Entry block (unconditional): 3W CNOT, 0 Toffoli — via emit_shadow_store!
#   - Any other block: 3W Toffoli gated by block predicate — via
#     emit_shadow_store_guarded!  (Bennett-cc0 M2c / Bennett-oio4)
#
# The entry-block fast path preserves all existing BENCHMARKS.md gate counts
# while fixing the conditional-store semantic bug. Sentinel Symbol("") matches
# no block → treats as entry (backward-compat for direct lower_store! callers).
function _lower_store_via_shadow!(ctx::LoweringCtx, inst::IRStore,
                                  alloca_dest::Symbol, info::Tuple{Int,Int},
                                  idx_op::IROperand, block_label::Symbol=Symbol(""))
    elem_w, n = info
    inst.width == elem_w ||
        error("_lower_store_via_shadow!: store width=$(inst.width) doesn't match alloca elem_width=$elem_w")
    0 <= idx_op.value < n ||
        error("_lower_store_via_shadow!: idx=$(idx_op.value) out of range [0, $n)")

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        error("_lower_store_via_shadow!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

    primal_slot = arr_wires[idx_op.value * elem_w + 1 : (idx_op.value + 1) * elem_w]
    tape = allocate!(ctx.wa, elem_w)
    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, elem_w)

    # M2c guard: store is unconditional iff we're in the entry block (or the
    # sentinel Symbol("") signals "no gating info"). Otherwise gate on block
    # predicate. Assumes single-wire predicates; multi-wire would need
    # AND-reduction first (not currently produced by _compute_block_pred!).
    if block_label == Symbol("") || block_label == ctx.entry_label
        emit_shadow_store!(ctx.gates, ctx.wa, primal_slot, tape, val_wires, elem_w)
    else
        pred_wires = get(ctx.block_pred, block_label, Int[])
        length(pred_wires) == 1 ||
            error("_lower_store_via_shadow!: expected single-wire predicate for block $block_label, got $(length(pred_wires)) wires")
        emit_shadow_store_guarded!(ctx.gates, ctx.wa, primal_slot, tape, val_wires, elem_w, pred_wires[1])
    end
    return nothing
end

# Bennett-cc0 M2d: MUX-store dispatch is guarded when the store lives in a
# non-entry block. `block_label == ctx.entry_label` (or the sentinel
# Symbol("")) routes to the unguarded soft_mux_store_NxW callee — entry-block
# stores therefore keep the byte-identical BENCHMARKS.md gate counts. Any
# other block promotes the 1-wire block predicate into a 64-wire operand and
# calls soft_mux_store_guarded_NxW, folding `pred` into the per-slot
# `ifelse` cond. When `pred == 0` every slot returns OLD → `arr` unchanged.
function _lower_store_via_mux_4x8!(ctx::LoweringCtx, inst::IRStore,
                                   alloca_dest::Symbol, idx_op::IROperand;
                                   block_label::Symbol=Symbol(""))
    inst.width == 8 ||
        error("_lower_store_via_mux_4x8!: store width must be 8, got $(inst.width)")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == 32 ||
        error("_lower_store_via_mux_4x8!: expected 32-wire packed array")

    tag = _next_mux_tag!(ctx, "st", inst.ptr.name)
    arr_sym = Symbol("__mux_store_arr_", tag)
    idx_sym = Symbol("__mux_store_idx_", tag)
    val_sym = Symbol("__mux_store_val_", tag)
    res_sym = Symbol("__mux_store_res_", tag)

    ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
    ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)
    ctx.vw[val_sym] = _operand_to_u64!(ctx, inst.val)

    if block_label == Symbol("") || block_label == ctx.entry_label
        call = IRCall(res_sym, soft_mux_store_4x8,
                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
    else
        pred_sym = _mux_store_pred_sym!(ctx, block_label, tag,
                                        "_lower_store_via_mux_4x8!")
        call = IRCall(res_sym, soft_mux_store_guarded_4x8,
                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
                      [64, 64, 64, 64], 64)
    end
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[alloca_dest] = ctx.vw[res_sym][1:32]
    return nothing
end

function _lower_store_via_mux_8x8!(ctx::LoweringCtx, inst::IRStore,
                                   alloca_dest::Symbol, idx_op::IROperand;
                                   block_label::Symbol=Symbol(""))
    inst.width == 8 ||
        error("_lower_store_via_mux_8x8!: store width must be 8, got $(inst.width)")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == 64 ||
        error("_lower_store_via_mux_8x8!: expected 64-wire packed array")

    tag = _next_mux_tag!(ctx, "st", inst.ptr.name)
    arr_sym = Symbol("__mux_store_arr_", tag)
    idx_sym = Symbol("__mux_store_idx_", tag)
    val_sym = Symbol("__mux_store_val_", tag)
    res_sym = Symbol("__mux_store_res_", tag)

    ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
    ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)
    ctx.vw[val_sym] = _operand_to_u64!(ctx, inst.val)

    if block_label == Symbol("") || block_label == ctx.entry_label
        call = IRCall(res_sym, soft_mux_store_8x8,
                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
    else
        pred_sym = _mux_store_pred_sym!(ctx, block_label, tag,
                                        "_lower_store_via_mux_8x8!")
        call = IRCall(res_sym, soft_mux_store_guarded_8x8,
                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
                      [64, 64, 64, 64], 64)
    end
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[alloca_dest] = ctx.vw[res_sym]
    return nothing
end

# M1 — Bennett-cc0 parametric MUX EXCH helpers.
# Generated via @eval over the shape list. Each (N, W) pair produces a
# _lower_load_via_mux_NxW! and a _lower_store_via_mux_NxW!, both following
# the same structure as the hand-written (4,8)/(8,8) variants: validate
# width + packed-array size, pack operands into UInt64, emit IRCall to the
# matching soft_mux_*_NxW callee, slice the low N·W bits back into the
# primal wire list.
for (N, W) in [(2, 8), (2, 16), (4, 16), (2, 32)]
    @assert N * W <= 64 "shape ($N, $W) exceeds UInt64 packing"
    load_fn           = Symbol(:_lower_load_via_mux_, N, :x, W, :!)
    store_fn          = Symbol(:_lower_store_via_mux_, N, :x, W, :!)
    soft_load         = Symbol(:soft_mux_load_, N, :x, W)
    soft_store        = Symbol(:soft_mux_store_, N, :x, W)
    soft_store_guard  = Symbol(:soft_mux_store_guarded_, N, :x, W)
    packed_bits = N * W
    name_tag = string(N, "x", W)

    @eval begin
        function $load_fn(ctx::LoweringCtx, inst::IRLoad,
                          alloca_dest::Symbol, info::Tuple{Int,Int},
                          idx_op::IROperand)
            inst.width == $W ||
                error($("_lower_load_via_mux_$(name_tag)!: load width must be $W, got "), inst.width)
            arr_wires = ctx.vw[alloca_dest]
            length(arr_wires) == $packed_bits ||
                error($("_lower_load_via_mux_$(name_tag)!: expected $(packed_bits)-wire packed array at alloca "),
                      alloca_dest, "; got ", length(arr_wires))

            tag = _next_mux_tag!(ctx, "ld", inst.dest)
            arr_sym = Symbol("__mux_load_arr_", tag)
            idx_sym = Symbol("__mux_load_idx_", tag)
            tmp_sym = Symbol("__mux_load_u64_", tag)

            ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
            ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)

            call = IRCall(tmp_sym, $soft_load,
                          [ssa(arr_sym), ssa(idx_sym)], [64, 64], 64)
            lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

            ctx.vw[inst.dest] = ctx.vw[tmp_sym][1:$W]
            return nothing
        end

        # Bennett-cc0 M2d: same block_label-dispatch pattern as the hand-written
        # (4,8)/(8,8) helpers. Entry-block → unguarded callee, byte-identical to
        # pre-M2d. Any other block → guarded callee with block-predicate folded
        # into the per-slot ifelse cond.
        function $store_fn(ctx::LoweringCtx, inst::IRStore,
                           alloca_dest::Symbol, idx_op::IROperand;
                           block_label::Symbol=Symbol(""))
            inst.width == $W ||
                error($("_lower_store_via_mux_$(name_tag)!: store width must be $W, got "), inst.width)
            arr_wires = ctx.vw[alloca_dest]
            length(arr_wires) == $packed_bits ||
                error($("_lower_store_via_mux_$(name_tag)!: expected $(packed_bits)-wire packed array"))

            tag = _next_mux_tag!(ctx, "st", inst.ptr.name)
            arr_sym = Symbol("__mux_store_arr_", tag)
            idx_sym = Symbol("__mux_store_idx_", tag)
            val_sym = Symbol("__mux_store_val_", tag)
            res_sym = Symbol("__mux_store_res_", tag)

            ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
            ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)
            ctx.vw[val_sym] = _operand_to_u64!(ctx, inst.val)

            if block_label == Symbol("") || block_label == ctx.entry_label
                call = IRCall(res_sym, $soft_store,
                              [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
            else
                pred_sym = _mux_store_pred_sym!(ctx, block_label, tag,
                                                $("_lower_store_via_mux_$(name_tag)!"))
                call = IRCall(res_sym, $soft_store_guard,
                              [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
                              [64, 64, 64, 64], 64)
            end
            lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

            ctx.vw[alloca_dest] = ctx.vw[res_sym][1:$packed_bits]
            return nothing
        end
    end
end

# ---- helpers for T1b.3 store/load dispatch ----

_next_mux_tag!(ctx::LoweringCtx, op::String, hint) =
    (ctx.mux_counter[] += 1; string(op, "_", hint, "_", ctx.mux_counter[]))

# Bennett-cc0 M2d helper: promote a 1-wire block predicate into a 64-wire
# operand suitable for the guarded soft_mux_store_guarded_NxW callees. Looks
# up the predicate via `ctx.block_pred[block_label]`, asserts it is a single
# wire (M2c invariant, same as `_lower_store_via_shadow!`), CNOT-copies that
# wire into bit 0 of a fresh 64-wire block, and registers the resulting SSA
# name in `ctx.vw`. Returns the symbol for use in `ssa(pred_sym)`.
# Caller supplies `tag` (for unique naming) and `callee_name` (for error text).
function _mux_store_pred_sym!(ctx::LoweringCtx, block_label::Symbol, tag::String,
                              callee_name::AbstractString)::Symbol
    pred_wires = get(ctx.block_pred, block_label, Int[])
    length(pred_wires) == 1 ||
        error(callee_name, ": expected single-wire predicate for block ",
              block_label, ", got ", length(pred_wires), " wires")
    pred_sym = Symbol("__mux_store_pred_", tag)
    pw64 = allocate!(ctx.wa, 64)
    push!(ctx.gates, CNOTGate(pred_wires[1], pw64[1]))  # promote 1→64 via low bit
    ctx.vw[pred_sym] = pw64
    return pred_sym
end

# Zero-extend a wire vector to 64 wires by CNOT-copying into the low bits of
# a fresh 64-wire block (high bits stay zero). Leaves the source wires
# untouched so they can still be read elsewhere.
function _wires_to_u64!(ctx::LoweringCtx, src::Vector{Int})
    length(src) <= 64 ||
        error("_wires_to_u64!: source has $(length(src)) wires > 64")
    dst = allocate!(ctx.wa, 64)
    for i in eachindex(src)
        push!(ctx.gates, CNOTGate(src[i], dst[i]))
    end
    return dst
end

# Resolve an IROperand to exactly 64 wires. For :const, materialize the value
# with NOT gates. For :ssa, zero-extend via CNOT-copy.
function _operand_to_u64!(ctx::LoweringCtx, op::IROperand)
    if op.kind == :const
        dst = allocate!(ctx.wa, 64)
        v = UInt64(op.value)  # narrow to 64 bits
        for i in 1:64
            if ((v >> (i - 1)) & UInt64(1)) == UInt64(1)
                push!(ctx.gates, NOTGate(dst[i]))
            end
        end
        return dst
    else
        haskey(ctx.vw, op.name) ||
            error("_operand_to_u64!: undefined SSA %$(op.name)")
        return _wires_to_u64!(ctx, ctx.vw[op.name])
    end
end