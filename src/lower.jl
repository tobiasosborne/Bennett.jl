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

# Backward-compatible constructors
GateGroup(name, gs, ge, rw, ivars) = GateGroup(name, gs, ge, rw, ivars, 0, -1, Int[])
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
end

# Backward-compatible 7-arg constructor (existing call sites still work)
LoweringResult(gates, n_wires, input_wires, output_wires,
               input_widths, output_elem_widths, constant_wires) =
    LoweringResult(gates, n_wires, input_wires, output_wires,
                   input_widths, output_elem_widths, constant_wires, GateGroup[])

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
               use_karatsuba::Bool=false, fold_constants::Bool=false)
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
                               block_pred, ssa_liveness, inst_counter, gate_groups, use_karatsuba)
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
                           use_karatsuba::Bool=false)
    for inst in block.instructions
        inst_counter[] += 1
        _ws = wa.next_wire
        _gs = length(gates) + 1
        if inst isa IRPhi
            lower_phi!(gates, wa, vw, inst, block.label, preds, branch_info, block_order;
                       block_pred)
        elseif inst isa IRBinOp
            lower_binop!(gates, wa, vw, inst; ssa_liveness, inst_idx=inst_counter[], use_karatsuba)
        elseif inst isa IRICmp
            lower_icmp!(gates, wa, vw, inst)
        elseif inst isa IRSelect
            lower_select!(gates, wa, vw, inst)
        elseif inst isa IRCast
            lower_cast!(gates, wa, vw, inst)
        elseif inst isa IRPtrOffset
            lower_ptr_offset!(gates, wa, vw, inst)
        elseif inst isa IRVarGEP
            lower_var_gep!(gates, wa, vw, inst)
        elseif inst isa IRLoad
            lower_load!(gates, wa, vw, inst)
        elseif inst isa IRExtractValue
            lower_extractvalue!(gates, wa, vw, inst)
        elseif inst isa IRInsertValue
            lower_insertvalue!(gates, wa, vw, inst)
        elseif inst isa IRCall
            lower_call!(gates, wa, vw, inst)
        else
            error("Unhandled instruction type: $(typeof(inst)) — $(inst)")
        end

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
        haskey(block_pred, blk) || error("No predicate for block $blk in phi resolution")
        if haskey(branch_info, blk)
            (cw, tlabel, flabel) = branch_info[blk]
            if tlabel == phi_block
                # True side edge
                push!(edge_preds, _and_wire!(gates, wa, block_pred[blk], cw))
            elseif flabel == phi_block
                # False side edge
                not_cw = _not_wire!(gates, wa, cw)
                push!(edge_preds, _and_wire!(gates, wa, block_pred[blk], not_cw))
            else
                # from_block doesn't branch directly to phi_block — use block pred
                push!(edge_preds, block_pred[blk])
            end
        else
            # Unconditional branch or no branch info — use block predicate
            push!(edge_preds, block_pred[blk])
        end
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
                    block_pred::Dict{Symbol,Vector{Int}}=Dict{Symbol,Vector{Int}}())
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

function lower_binop!(gates, wa, vw, inst::IRBinOp;
                      ssa_liveness::Dict{Symbol,Int}=Dict{Symbol,Int}(),
                      inst_idx::Int=0,
                      use_karatsuba::Bool=false)
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
        if inst.op == :add && !isempty(ssa_liveness) && op2_dead
            lower_add_cuccaro!(gates, wa, a, b, W)
        elseif inst.op == :add; lower_add!(gates, wa, a, b, W)
        elseif inst.op == :sub; lower_sub!(gates, wa, a, b, W)
        elseif inst.op == :mul
            if use_karatsuba && W > 4
                lower_mul_karatsuba!(gates, wa, a, b, W)
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

function lower_select!(gates, wa, vw, inst::IRSelect)
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
                           vw::Dict{Symbol,Vector{Int}}, inst::IRPtrOffset)
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
end

"""
Variable-index GEP: MUX-tree selecting one element by runtime index.

The base pointer's wires are a flattened array of N elements of W bits each.
The index selects which W-bit element to produce, via a binary MUX tree
with ceil(log2(N)) levels.
"""
function lower_var_gep!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                        vw::Dict{Symbol,Vector{Int}}, inst::IRVarGEP)
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
                     vw::Dict{Symbol,Vector{Int}}, inst::IRCall)
    # Pre-compile the callee function
    arg_types = Tuple{(UInt64 for _ in inst.args)...}
    saved_counter = _name_counter[]
    callee_parsed = extract_parsed_ir(inst.callee, arg_types)
    _name_counter[] = saved_counter   # restore caller's name counter

    callee_lr = lower(callee_parsed; max_loop_iterations=64)

    # Wire offset: remap all callee wires into the caller's wire space
    wire_offset = wire_count(wa)
    # Reserve wires in the caller's allocator
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

function _remap_gate(g::NOTGate, offset::Int)
    NOTGate(g.target + offset)
end
function _remap_gate(g::CNOTGate, offset::Int)
    CNOTGate(g.control + offset, g.target + offset)
end
function _remap_gate(g::ToffoliGate, offset::Int)
    ToffoliGate(g.control1 + offset, g.control2 + offset, g.target + offset)
end