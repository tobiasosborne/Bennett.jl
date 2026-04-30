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
        error("lower: cannot topologically sort blocks even after removing back-edges")
    return result
end

# ---- loop unrolling ----

"""
Compute the loop-body region: all basic blocks reachable from `header`'s
non-exit successors via forward edges, stopping at the exit block and at
latch blocks. Returns a topologically-sorted list (back-edges ignored)
excluding the header itself and excluding the exit block.

Fails loud on nested loops (a body block that is itself a loop header),
multi-latch configurations, and early returns inside the body. See
Bennett-httg / U05.
"""
function _collect_loop_body_blocks(header::IRBasicBlock, block_map::Dict{Symbol,IRBasicBlock},
                                   exit_label::Symbol, latch_labels::Set{Symbol},
                                   loop_headers::Set{Symbol}, back_edges::Vector{Tuple{Symbol,Symbol}})
    hlabel = header.label
    term = header.terminator
    # Seed frontier with header's non-exit successors.
    frontier = Symbol[]
    for s in branch_targets(term)
        s == exit_label && continue
        s == hlabel && continue  # rare: self-loop with only header; no body
        push!(frontier, s)
    end

    back_set = Set(back_edges)
    seen = Set{Symbol}([hlabel, exit_label])
    body = Symbol[]
    while !isempty(frontier)
        b = popfirst!(frontier)
        b in seen && continue
        push!(seen, b)
        push!(body, b)
        b in loop_headers && b != hlabel &&
            error("lower_loop!: nested loop header $b inside body of $hlabel — nested loops not supported (Bennett-httg / U05 scope)")
        bblock = block_map[b]
        bterm = bblock.terminator
        if bterm isa IRRet
            error("lower_loop!: IRRet in loop body at $b — early return inside a loop not supported")
        end
        bterm isa IRBranch || continue
        for t in branch_targets(bterm)
            (b, t) in back_set && continue       # latch / back-edge
            t == exit_label && continue          # don't descend into exit block
            t in seen && continue
            push!(frontier, t)
        end
    end

    # Topo-sort (back-edges ignored). Build subgraph of {hlabel} ∪ body.
    sub_blocks = [block_map[l] for l in vcat([hlabel], body)]
    sub_labels = Set(l.label for l in sub_blocks)
    back_vec = Tuple{Symbol,Symbol}[(s, d) for (s, d) in back_edges
                                    if s in sub_labels && d in sub_labels]
    ordered = topo_sort(sub_blocks; ignore_edges=back_vec)
    return filter(l -> l != hlabel, ordered)
end

"""
    lower_loop!(gates, wa, vw, header_block, block_map, back_edges, K, preds, branch_info; <ctx kwargs>)

Unroll a loop K times. The header block has phi nodes for loop-carried
variables. Each iteration:
  1. (iter 1 only) seed header phis from pre-header values.
  2. Lower the loop body: header's non-phi instructions, then every body
     block in topological order, each instruction dispatched through the
     canonical `_lower_inst!` (Bennett-httg / U05).
  3. Compute the exit condition.
  4. MUX-freeze header phis: keep current value on exit, take latch value
     on continue.
"""
function lower_loop!(gates, wa, vw, header::IRBasicBlock, block_map,
                     back_edges, K::Int, preds, branch_info;
                     block_pred::Dict{Symbol,Vector{Int}}=Dict{Symbol,Vector{Int}}(),
                     ssa_liveness::Dict{Symbol,Int}=Dict{Symbol,Int}(),
                     inst_counter::Ref{Int}=Ref(0),
                     gate_groups::Vector{GateGroup}=GateGroup[],
                     compact_calls::Bool=false,
                     globals::Dict{Symbol,Tuple{Vector{UInt64},Int}}=Dict{Symbol,Tuple{Vector{UInt64},Int}}(),
                     add::Symbol=:auto, mul::Symbol=:auto,
                     alloca_info::Dict{Symbol,Tuple{Int,Int}}=Dict{Symbol,Tuple{Int,Int}}(),
                     ptr_provenance::Dict{Symbol,Vector{PtrOrigin}}=Dict{Symbol,Vector{PtrOrigin}}(),
                     entry_label::Symbol=Symbol(""),
                     block_order=Symbol[],
                     loop_headers::Set{Symbol}=Set{Symbol}())
    hlabel = header.label

    # Find which phi inputs are from the pre-header vs the back-edge (latch)
    latch_labels = Set(src for (src, dst) in back_edges if dst == hlabel)
    pre_header_preds = Symbol[]

    # Separate phi incoming into pre-header (initial) and latch (loop-carried)
    phi_info = Tuple{Symbol, Int, IROperand, IROperand}[]
    for inst in header.instructions
        inst isa IRPhi || continue
        pre_op = nothing; latch_op = nothing
        for (val, blk) in inst.incoming
            if blk in latch_labels || blk == hlabel
                latch_op = (val, blk)
            else
                pre_op = (val, blk)
                blk in pre_header_preds || push!(pre_header_preds, blk)
            end
        end
        pre_op === nothing && error("lower_loop!: phi $(inst.dest) has no pre-header incoming")
        latch_op === nothing && error("lower_loop!: phi $(inst.dest) has no latch incoming")
        push!(phi_info, (inst.dest, inst.width, pre_op[1], latch_op[1]))
    end

    for p in pre_header_preds
        push!(get!(preds, hlabel, Symbol[]), p)
    end

    # Non-phi instructions in the header (may be empty for multi-block bodies).
    header_body_insts = [inst for inst in header.instructions if !(inst isa IRPhi)]

    term = header.terminator
    (term isa IRBranch && term.cond !== nothing) ||
        error("lower_loop!: loop header $hlabel must end with conditional branch, got: $(typeof(term))")

    exit_on_true = !(term.true_label == hlabel || term.true_label in latch_labels)
    exit_label = exit_on_true ? term.true_label : term.false_label

    # Bennett-httg / U05: collect body blocks (all basic blocks between
    # header successors and the exit that are NOT the header itself).
    body_block_order = _collect_loop_body_blocks(header, block_map, exit_label,
                                                 latch_labels, loop_headers, back_edges)
    @debug "lower_loop! body_block_order" hlabel body_block_order

    # Bennett-jepw: the function-level pass (src/lower.jl ~437) populates
    # block_pred[hlabel] before calling lower_loop!. We rely on this for
    # body-block predicate computation below. Verify the contract.
    haskey(block_pred, hlabel) ||
        error("lower_loop!: block_pred[$hlabel] must be populated by the " *
              "function-level pass before lower_loop! is called " *
              "(Bennett-jepw contract)")

    # Seed header phis from pre-header values (iter 1).
    for (dest, width, pre_val, _) in phi_info
        vw[dest] = resolve!(gates, wa, vw, pre_val, width)
    end

    # Track SSA dests added during each iteration (excluding header phi
    # destinations, which live in vw across iterations via MUX-freeze). At
    # the end of each iteration we delete these entries so the next
    # iteration's re-lowering allocates fresh wires instead of in-place
    # mutating the previous iteration's result wires.
    phi_dests = Set(dest for (dest, _, _, _) in phi_info)

    for _iter in 1:K
        vw_snapshot = Set(keys(vw))

        # (a) Per-iteration LOCAL ctx for instruction dispatch. Mirrors the
        # body-block ctx that pre-y986 lived inside the body-block loop,
        # hoisted here to deduplicate header-body and body-block dispatch
        # paths (Bennett-y986 / U05-followup-2).
        #
        # Pre-y986 the header had a hard-coded 4-type cascade
        # (IRBinOp / IRICmp / IRSelect / IRCast) with no `else`; any
        # IRCall / IRStore / IRLoad / IRAlloca / IRPtrOffset / IRVarGEP
        # / IRExtractValue / IRInsertValue / non-loop-carried IRPhi in
        # the header was silently dropped. The U05 body-block path already
        # used `_lower_inst!` (the 12-type dispatcher) — y986 lifts that
        # same dispatch to the header. Fail-loud guarantee comes from
        # `_lower_inst!`'s catch-all method (lower.jl:190) per CLAUDE.md §1.
        #
        # Iteration-LOCAL guards (preserved from the pre-y986 body-block ctx):
        # * `Dict{Symbol,Int}()` ssa_liveness — caller's populated liveness
        #   would mark phi-destination operands as "dead" (no cross-iter
        #   re-read modelled), letting Cuccaro's in-place adder corrupt
        #   loop-carried accumulators. Empty dict ⇒ no operand looks dead.
        # * `Ref(0)` inst_counter — the function-level counter is meaningless
        #   across an unroll iteration.
        # * `add=:ripple` — belt-and-braces. Post-U27 `_pick_add_strategy(:auto)`
        #   returns `:ripple` regardless, so this is byte-identical to the
        #   pre-y986 cascade for fast-path types. Override also defends
        #   against an explicit caller-passed `add=:cuccaro`.
        # * Iteration-LOCAL `iter_block_pred` / `iter_branch_info` /
        #   `iter_preds` (Bennett-jepw): function-level dicts would only
        #   see the last iteration's view of body-block wires — useless
        #   to any consumer.
        iter_block_pred = Dict{Symbol,Vector{Int}}()
        iter_block_pred[hlabel] = block_pred[hlabel]
        iter_branch_info = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}()
        iter_preds = Dict{Symbol,Vector{Symbol}}()

        iter_ctx = LoweringCtx(gates, wa, vw, iter_preds, iter_branch_info,
                               block_order, iter_block_pred,
                               Dict{Symbol,Int}(), Ref(0),
                               compact_calls,
                               alloca_info, ptr_provenance, Ref(0),
                               globals, :ripple, mul, entry_label)

        # (a1) Lower header's non-phi instructions through the canonical
        # dispatcher. `header_body_insts` is in source order (collected at
        # line 901); phis are filtered out and the terminator lives in
        # `header.terminator`, never in `header.instructions`.
        for inst in header_body_insts
            inst_counter[] += 1
            _lower_inst!(iter_ctx, inst, hlabel)
        end

        # (a2) Resolve the header's exit condition ONCE — reused at (c).
        # Lives between (a1) and (b) so any header-body inst that produces
        # the cond's SSA operand has executed first (pre-y986 IRCall in
        # header was dropped, masking this dependency).
        raw_cond_wire = resolve!(gates, wa, vw, term.cond, 1)

        if !isempty(body_block_order)
            iter_branch_info[hlabel] = (raw_cond_wire, term.true_label, term.false_label)
            # Seed: header → body successors (skip the exit and self-loops).
            for s in branch_targets(term)
                (s == exit_label || s == hlabel) && continue
                push!(get!(iter_preds, s, Symbol[]), hlabel)
            end

            # (b) Lower body blocks in topo order, reusing iter_ctx. For
            # each, compute its path predicate from in-region predecessors
            # BEFORE dispatching its instructions, so any IRPhi in the body
            # can resolve via `_edge_predicate!` (Bennett-jepw).
            for blabel in body_block_order
                bblock = block_map[blabel]

                # Compute this body block's path predicate from already-
                # walked in-region predecessors. _compute_block_pred!
                # silently skips predecessors absent from iter_block_pred,
                # which doesn't apply here because iter_preds[blabel] only
                # contains predecessors we have already lowered (header or
                # earlier body blocks in topological order).
                if !isempty(get(iter_preds, blabel, Symbol[]))
                    iter_block_pred[blabel] =
                        _compute_block_pred!(gates, wa, blabel, iter_preds,
                                             iter_branch_info, iter_block_pred)
                end

                for inst in bblock.instructions
                    inst_counter[] += 1
                    _lower_inst!(iter_ctx, inst, blabel)
                end

                # Capture this body block's branch into the iteration-local
                # branch_info / preds for downstream body blocks.
                bterm = bblock.terminator
                if bterm isa IRBranch && bterm.cond !== nothing
                    cw = resolve!(gates, wa, vw, bterm.cond, 1)
                    iter_branch_info[blabel] = (cw, bterm.true_label, bterm.false_label)
                    bterm.true_label == hlabel ||
                        push!(get!(iter_preds, bterm.true_label, Symbol[]), blabel)
                    if bterm.false_label !== nothing && bterm.false_label != hlabel
                        push!(get!(iter_preds, bterm.false_label, Symbol[]), blabel)
                    end
                elseif bterm isa IRBranch
                    bterm.true_label == hlabel ||
                        push!(get!(iter_preds, bterm.true_label, Symbol[]), blabel)
                end
            end
        end

        # (c) Exit condition — always reuses the wire computed at (a2).
        exit_cond_wire = raw_cond_wire
        if !exit_on_true
            exit_cond_wire = lower_not1!(gates, wa, exit_cond_wire)
        end

        # (d) Resolve latch values (what the phi would receive on next iter).
        latch_vals = Vector{Int}[]
        for (_, width, _, latch_op) in phi_info
            push!(latch_vals, resolve!(gates, wa, vw, latch_op, width))
        end

        # (e) MUX: exit=1 → keep current, exit=0 → take latch value.
        for (k, (dest, width, _, _)) in enumerate(phi_info)
            current = vw[dest]
            new_val = latch_vals[k]
            vw[dest] = lower_mux!(gates, wa, exit_cond_wire, current, new_val, width)
        end

    end

    push!(get!(preds, exit_label, Symbol[]), hlabel)
end

