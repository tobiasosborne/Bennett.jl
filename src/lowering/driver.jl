function lower(parsed::ParsedIR; max_loop_iterations::Int=0, use_inplace::Bool=true,
               fold_constants::Bool=true, compact_calls::Bool=false,
               add::Symbol=:auto, mul::Symbol=:auto,
               target::Symbol=:gate_count)
    add in (:auto, :ripple, :cuccaro, :qcla) ||
        error("lower: unknown add strategy :$add; supported: :auto, :ripple, :cuccaro, :qcla")
    mul in (:auto, :shift_add, :qcla_tree) ||
        error("lower: unknown mul strategy :$mul; supported: :auto, :shift_add, :qcla_tree (Bennett-tbm6: :karatsuba removed 2026-04-27)")
    # Bennett-4fri / U30: `target` selects the objective the `:auto`
    # dispatchers optimise for. `:gate_count` (default) preserves the
    # pre-U30 choices; `:depth` switches `mul=:auto` to `qcla_tree`
    # (O(log² n) T-depth vs shift-and-add's O(n)).
    target in (:gate_count, :depth) || throw(ArgumentError(
        "lower: unknown target :$target; supported: :gate_count, :depth"))
    # Pre-resolve `mul=:auto` when the user asks for depth-optimised
    # output. Downstream sees this as an explicit choice — no ctx field
    # needed and no per-call-site threading beyond the existing `mul`.
    if mul === :auto && target === :depth
        mul = :qcla_tree
    end
    wa = WireAllocator()
    gates = ReversibleGate[]
    vw = Dict{Symbol,Vector{Int}}()
    input_wires = Int[]
    input_widths = Int[]
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
        error("lower: loop detected in LLVM IR but max_loop_iterations not specified. " *
              "Pass max_loop_iterations=N to reversible_compile.")
    end

    # Build loop info for each header
    loop_headers = Set(dst for (_, dst) in back_edges)

    # Bennett-jepw / U05-followup: a body block of an unrolled loop is fully
    # lowered inside lower_loop! (the diamond-in-body fix uses iteration-local
    # block_pred / branch_info dicts). Re-dispatching it at the top level
    # would emit duplicate gates AND trigger phi resolution against block_pred
    # that no longer holds the body-block entries (they live only in the
    # iteration-local dicts). Collect every loop's body region up front and
    # skip those labels in the function-level walk below.
    loop_body_labels = Set{Symbol}()
    for hl in loop_headers
        h = block_map[hl]
        hterm = h.terminator
        (hterm isa IRBranch && hterm.cond !== nothing) || continue
        ll = Set(s for (s, d) in back_edges if d == hl)
        eot = !(hterm.true_label == hl || hterm.true_label in ll)
        elabel = eot ? hterm.true_label : hterm.false_label
        body = _collect_loop_body_blocks(h, block_map, elabel, ll, loop_headers, back_edges)
        union!(loop_body_labels, body)
    end

    # track branch conditions and predecessors (for phi / multi-ret resolution)
    branch_info = Dict{Symbol, Tuple{Vector{Int}, Symbol, Symbol}}()
    preds = Dict{Symbol, Vector{Symbol}}()
    block_order = Dict(order[i] => i for i in eachindex(order))

    # Path predicates: 1-bit wire per block, true iff that block is active.
    # Computed during lowering, used for phi resolution.
    block_pred = Dict{Symbol, Vector{Int}}()

    ret_values = Tuple{Vector{Int}, Symbol}[]

    for label in order
        # Bennett-jepw: body blocks belong to a loop and were fully lowered
        # by lower_loop! when its header was visited earlier in `order`.
        label in loop_body_labels && continue

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
            # Unroll this loop (single group for entire loop body).
            # Bennett-httg / U05: thread the full lowering context so body-block
            # instructions route through the canonical `_lower_inst!` dispatcher.
            _ws = wa.next_wire
            _gs = length(gates) + 1
            lower_loop!(gates, wa, vw, block, block_map, back_edges,
                        max_loop_iterations, preds, branch_info;
                        block_pred, ssa_liveness, inst_counter, gate_groups,
                        compact_calls, globals=parsed.globals, add, mul,
                        alloca_info, ptr_provenance, entry_label=order[1],
                        block_order, loop_headers)
            if length(gates) >= _gs
                push!(gate_groups, GateGroup(Symbol("__loop_", label),
                      _gs, length(gates), Int[], Symbol[], _ws, wa.next_wire - 1))
            end
        else
            lower_block_insts!(gates, wa, vw, block, preds, branch_info, block_order;
                               block_pred, ssa_liveness, inst_counter, gate_groups,
                               compact_calls, globals=parsed.globals, add, mul,
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
                         input_widths, parsed.ret_elem_widths,
                         gate_groups, false)  # self_reversing=false (default)

    if fold_constants
        lr = _fold_constants(lr)
    end

    return lr
end

"""
Constant folding pass: propagate known wire values through the gate list,
eliminating gates whose controls are all constant and simplifying partially-
constant gates.

Single abstract-interpretation pass over `known::Dict{Int,Bool}` (per non-input
wire's compile-time-constant value). Three operator-dispatch arms — `NOTGate`
(flip-then-materialize), `CNOTGate` (constant-control collapses or pass-through),
`ToffoliGate` (one-known-false noop / both-known-true target flip /
one-known-true reduce-to-CNOT). Per Bennett-heup / U127, the "three concerns"
framing in reviews/2026-04-21/12_torvalds.md B10 + 13_carmack.md F8 was
empirically a single concern (constant propagation through reversible gates)
with three operator cases; splitting would duplicate state-update logic.

Default wired to `true` since Bennett-epwy / U28 (2026-04-24): the pass is
strictly safe (only removes / simplifies gates, never adds). Empirical wins
on the canonical benchmarks (live 2026-04-27, post-5qrn peephole layer):
- polynomial `x*x + 3x + 1`  total 848 → 482; Toffoli 352 → 168
- `x*x Int8`                 Toffoli 296 → 144; depth 97 → 89
- `x*3 Int8` (optimize=false) gates ≥ 3× without folding

Contracts pinned by `test/test_heup_fold_constants_contract.jl` (539
assertions): per-arm dispatch witnesses, default-true at every entry point,
self_reversing short-circuit (per Bennett-egu6 / U03), and reduction baselines.
"""
function _fold_constants(lr::LoweringResult)
    # U03 / Bennett-egu6: a self-reversing primitive (e.g. Sun-Borissov
    # mul, tabulate) is a closed sequence whose output lives on primary
    # output wires and whose ancillae are already clean. Folding across
    # it would rewrite the gate list and almost certainly break the
    # self-uncomputing property. Skip it.
    lr.self_reversing && return lr
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
                          lr.input_widths, lr.output_elem_widths)
end

function lower_block_insts!(gates, wa, vw, block, preds, branch_info, block_order;
                           block_pred::Dict{Symbol,Vector{Int}}=Dict{Symbol,Vector{Int}}(),
                           ssa_liveness::Dict{Symbol,Int}=Dict{Symbol,Int}(),
                           inst_counter::Ref{Int}=Ref(0),
                           gate_groups::Vector{GateGroup}=GateGroup[],
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
                      block_pred, ssa_liveness, inst_counter, compact_calls,
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

