# ---- topological sort + loop detection ----

function branch_targets(br::IRBranch)
    br.false_label !== nothing ? [br.true_label, br.false_label] : [br.true_label]
end

"""
    _canonicalize_same_target_branches(blocks) -> Vector{IRBasicBlock}

Bennett-c6ex: `br i1 %c, label %X, label %X` means the same as `br label %X`.
Both polarities enter X, so the edge predicate is `block_pred[src]`. The
polarity-based predicate code (`_compute_block_pred!` / `_edge_predicate!`)
cannot express that: it would record the predecessor twice (Bennett-p94b
rejection) or AND in `c` and drop the false edge. So such branches are
rewritten to unconditional ones before lowering. They arise from valid IR, e.g.
`_expand_switches` on a switch whose last case targets the default.

Returns `blocks` ITSELF (`===`) when nothing changes, so every other program
is lowered byte-identically.
"""
function _canonicalize_same_target_branches(blocks::Vector{IRBasicBlock})
    _same(t) = t isa IRBranch && t.cond !== nothing && t.true_label === t.false_label
    any(b -> _same(b.terminator), blocks) || return blocks
    return IRBasicBlock[_same(b.terminator) ?
        IRBasicBlock(b.label, b.instructions, IRBranch(nothing, b.terminator.true_label, nothing)) :
        b for b in blocks]
end

"""
    _check_predication_cfg(blocks) -> Set{Symbol}

Bennett-c6ex: establish the structural preconditions of predicated lowering
(CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS RISK") up front, and
return the set of blocks unreachable from the entry. Checks:

  - (V1) every terminator is `IRBranch` or `IRRet`. `IRSwitch` must already be
    expanded: an unhandled terminator contributes no CFG edges, so its
    successors' predicates would silently omit it.
  - (V2) every branch target is a block of this function, or `:__unreachable__`.
  - (V3) the entry block has no predecessors (its predicate is the constant 1).
  - (V4) for every phi at block b:
      - its incoming blocks are CFG predecessors of b; otherwise the edge
        predicate is undefined and used to fall through to an
        over-approximation;
      - every CFG predecessor of b has an incoming; otherwise that path fires
        no edge predicate and the MUX chain silently yields the last value;
      - duplicate incomings from one block carry the same value (LLVM's rule).

The CFG must already be canonicalised (`_canonicalize_same_target_branches`).
"""
function _check_predication_cfg(blocks::Vector{IRBasicBlock})
    isempty(blocks) && error("lower: ParsedIR has no basic blocks")
    labels = Set{Symbol}(b.label for b in blocks)
    length(labels) == length(blocks) ||
        error("lower: duplicate basic-block labels in ParsedIR (Bennett-c6ex)")
    preds = Dict{Symbol,Set{Symbol}}()
    succs = Dict{Symbol,Vector{Symbol}}()
    for b in blocks
        t = b.terminator
        succs[b.label] = Symbol[]
        if t isa IRBranch
            for s in branch_targets(t)
                s === :__unreachable__ && continue
                s in labels || error("lower: block $(b.label) branches to $s, which is not a " *
                    "block of this function — the edge would be silently dropped from " *
                    "path-predicate computation (Bennett-c6ex)")
                push!(get!(preds, s, Set{Symbol}()), b.label)
                push!(succs[b.label], s)
            end
        elseif !(t isa IRRet)
            error("lower: block $(b.label) has terminator $(typeof(t)); only IRBranch/IRRet " *
                  "are lowerable (IRSwitch must be expanded by `_expand_switches` first). An " *
                  "unhandled terminator contributes no CFG edges, so its successors' path " *
                  "predicates would silently omit it (Bennett-c6ex)")
        end
    end
    entry = blocks[1].label
    haskey(preds, entry) && error("lower: entry block $entry has predecessors " *
        "$(sort!(collect(preds[entry]))); the entry path predicate is the constant 1, " *
        "so a loop cannot be headed by the entry block (Bennett-c6ex)")
    for b in blocks, inst in b.instructions
        inst isa IRPhi || continue
        ps = get(preds, b.label, Set{Symbol}())
        seen = Dict{Symbol,IROperand}()
        for (val, blk) in inst.incoming
            blk in ps || error("lower: phi %$(inst.dest) in block $(b.label) has an incoming " *
                "from $blk, which is not a CFG predecessor of $(b.label) (predecessors: " *
                "$(sort!(collect(ps)))) — its edge predicate is undefined (false-path " *
                "sensitisation; Bennett-c6ex)")
            if haskey(seen, blk)
                seen[blk] == val || error("lower: phi %$(inst.dest) in block $(b.label) lists " *
                    "predecessor $blk twice with different values ($(seen[blk]) vs $val) " *
                    "(Bennett-c6ex)")
            else
                seen[blk] = val
            end
        end
        for p in ps
            haskey(seen, p) || error("lower: phi %$(inst.dest) in block $(b.label) has no " *
                "incoming for CFG predecessor $p — control arriving via $p would fire no edge " *
                "predicate and the MUX chain would silently yield the last incoming value " *
                "(Bennett-c6ex)")
        end
    end
    reach = Set{Symbol}([entry]); stack = Symbol[entry]
    while !isempty(stack)
        u = pop!(stack)
        for v in succs[u]
            v in reach || (push!(reach, v); push!(stack, v))
        end
    end
    return setdiff(labels, reach)
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
        throw(AssertionError("lower: cannot topologically sort blocks even after removing back-edges"))
    return result
end

# ---- loop unrolling ----

"""
Compute the loop-body region: all basic blocks reachable from `header`'s
non-exit successors via forward edges, stopping at the exit block and at
latch blocks. Returns a topologically-sorted list (back-edges ignored)
excluding the header itself and excluding the exit block.

Fails loud on:
  - nested loops (a body block that is itself a loop header);
  - early returns inside the body (Bennett-httg / U05);
  - a second loop exit, i.e. a body block branching to the exit (e.g.
    `break` at optimize=false) (Bennett-c6ex). The unroller freezes
    loop-carried state on the HEADER's exit condition only, so iterations
    would silently continue past the break (l5: 96/256 wrong pre-fix).

Multi-latch loops are NOT rejected here. `lower_loop!` rejects a header phi
whose latch incomings carry distinct values (Bennett-c6ex; this docstring
used to claim, wrongly, that multi-latch failed loud here).
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
            t == exit_label && error("lower_loop!: body block $b of loop $hlabel branches " *
                "to the loop exit $t — a second loop exit (e.g. `break` at optimize=false) " *
                "is not supported: the unroller freezes loop-carried state on the HEADER's " *
                "exit condition only, so iterations would silently continue past the break " *
                "(Bennett-c6ex)")
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
    _seed_loop_phi!(gates, wa, vw, dest, pre_ops, width, hlabel, preds, block_pred, branch_info)

Bennett-c6ex: the iteration-1 value of loop-header phi `dest`. If every
pre-header incoming carries the same operand, it is a single `resolve!`, which
is byte-identical to the pre-c6ex path. Otherwise the header has several
pre-header predecessors with distinct values (optimize=false: an if/else
falling straight into a `while` header), and they are merged by edge predicate
into `hlabel`. The merge uses the FUNCTION-LEVEL `block_pred` / `branch_info`:
pre-headers are lowered before the header, which is topologically after them.
"""
function _seed_loop_phi!(gates, wa, vw, dest::Symbol, pre_ops::Vector{Tuple{IROperand,Symbol}},
                         width::Int, hlabel::Symbol, preds, block_pred, branch_info)
    vals = unique(first.(pre_ops))
    length(vals) == 1 && return resolve!(gates, wa, vw, vals[1], width)
    _assert_phi_incoming_preds(dest, pre_ops, hlabel, preds)
    # A block listed twice (switch expansion) carries one value (validated by
    # `_check_predication_cfg`), so dedupe to one edge per block.
    edges = unique(pre_ops)
    wired = [(resolve!(gates, wa, vw, v, width), b) for (v, b) in edges]
    return resolve_phi_predicated!(gates, wa, wired, block_pred, width;
                                   phi_block=hlabel, branch_info, audit_site=:loop_seed)
end

"""
    lower_loop!(gates, wa, vw, header_block, block_map, back_edges, K, preds, branch_info; <ctx kwargs>)

Unroll a loop K times. The header block has phi nodes for loop-carried
variables. Each iteration:
  1. (iter 1 only) seed header phis from pre-header values (merged by edge
     predicate when several pre-headers carry distinct values — Bennett-c6ex).
  2. Lower the loop body: header's non-phi instructions, then every body
     block in topological order, each instruction dispatched through the
     canonical `_lower_inst!` (Bennett-httg / U05).
  3. Compute the exit condition.
  4. MUX-freeze header phis: keep current value on exit, take latch value
     on continue.
"""
# Bennett-x2iw / U88: optional state bundled in `opts::BlockLoweringOpts`
# (loop_headers field is consumed by `lower_loop!`; lower_block_insts!
# ignores it). `block_order` stays positional — every real caller passes
# the function-level Dict{Symbol,Int} from `lower()`.
function lower_loop!(gates, wa, vw, header::IRBasicBlock, block_map,
                     back_edges, K::Int, preds, branch_info, block_order;
                     opts::BlockLoweringOpts = BlockLoweringOpts())
    hlabel = header.label

    # Find which phi inputs are from the pre-header vs the back-edge (latch)
    latch_labels = Set(src for (src, dst) in back_edges if dst == hlabel)

    # Separate phi incoming into pre-header (initial) and latch (loop-carried).
    # Bennett-c6ex: keep EVERY incoming. The pre-fix loop overwrote a single
    # `pre_op` / `latch_op`, so only the LAST pre-header and the LAST latch
    # value survived. That was a silent miscompile for an if/else falling
    # straight into a `while` header at optimize=false (pre2: 1143/2304 wrong)
    # and for multi-latch loops (H6: 256/256 wrong).
    phi_info = Tuple{Symbol, Int, Vector{Tuple{IROperand,Symbol}}, IROperand}[]
    for inst in header.instructions
        inst isa IRPhi || continue
        pre_ops = Tuple{IROperand,Symbol}[]
        latch_ops = Tuple{IROperand,Symbol}[]
        for (val, blk) in inst.incoming
            if blk in latch_labels || blk == hlabel
                push!(latch_ops, (val, blk))
            else
                push!(pre_ops, (val, blk))
            end
        end
        isempty(pre_ops) && throw(AssertionError("lower_loop!: phi $(inst.dest) has no pre-header incoming"))
        isempty(latch_ops) && throw(AssertionError("lower_loop!: phi $(inst.dest) has no latch incoming"))
        # The MUX-freeze at (e) carries ONE latch value per phi. Several latch
        # incomings are sound only if they all carry the same operand (e.g. a
        # latch ending in `br c, H, H`, or two latches forwarding one value).
        # Distinct values would need a per-iteration latch-edge merge. optimize=true
        # loop-simplify guarantees one latch and Julia `continue` lowers through a
        # merge block, so this arises only from hand-written IR: fail loud.
        latch_vals = unique(first.(latch_ops))
        length(latch_vals) == 1 || throw(AssertionError(
            "lower_loop!: phi %$(inst.dest) in loop header $hlabel has distinct values " *
            "on $(length(latch_ops)) latch incomings $(last.(latch_ops)); multi-latch " *
            "loops with distinct latch values are not supported — the MUX-freeze " *
            "carries ONE latch value per iteration (Bennett-c6ex)"))
        (inst.width == 0 && length(unique(first.(pre_ops))) > 1) && throw(AssertionError(
            "lower_loop!: pointer-typed header phi %$(inst.dest) in $hlabel has distinct " *
            "values on several pre-header incomings $(last.(pre_ops)); a predicated " *
            "pointer seed is not supported (Bennett-c6ex)"))
        push!(phi_info, (inst.dest, inst.width, pre_ops, latch_vals[1]))
    end
    # Bennett-c6ex: the pre-fix code re-pushed every pre-header into
    # preds[hlabel] here. block_pred[hlabel] has already been computed from
    # preds[hlabel] by the function-level pass, and nothing reads preds[hlabel]
    # afterwards, so the push was dead. It also produced duplicate entries that
    # Bennett-p94b would reject if they were ever read. Removed.

    # Non-phi instructions in the header (may be empty for multi-block bodies).
    header_body_insts = [inst for inst in header.instructions if !(inst isa IRPhi)]

    term = header.terminator
    (term isa IRBranch && term.cond !== nothing) ||
        throw(AssertionError("lower_loop!: loop header $hlabel must end with conditional branch, got: $(typeof(term))"))

    exit_on_true = !(term.true_label == hlabel || term.true_label in latch_labels)
    exit_label = exit_on_true ? term.true_label : term.false_label

    # Bennett-httg / U05: collect body blocks (all basic blocks between
    # header successors and the exit that are NOT the header itself).
    body_block_order = _collect_loop_body_blocks(header, block_map, exit_label,
                                                 latch_labels, opts.loop_headers, back_edges)
    @debug "lower_loop! body_block_order" hlabel body_block_order

    # Bennett-jepw: the function-level pass (src/lower.jl ~437) populates
    # block_pred[hlabel] before calling lower_loop!. We rely on this for
    # body-block predicate computation below. Verify the contract.
    haskey(opts.block_pred, hlabel) ||
        throw(AssertionError("lower_loop!: block_pred[$hlabel] must be populated by the " *
              "function-level pass before lower_loop! is called " *
              "(Bennett-jepw contract)"))

    # Seed header phis from pre-header values (iter 1).
    for (dest, width, pre_ops, _) in phi_info
        vw[dest] = _seed_loop_phi!(gates, wa, vw, dest, pre_ops, width, hlabel,
                                   preds, opts.block_pred, branch_info)
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
        # * `Set{Symbol}()` inplace_targets (Bennett-stwr) — every IR
        #   instruction in a loop region is lowered K+1 times, so an operand
        #   with ONE static occurrence here is read K+1 times dynamically;
        #   the function-level exclusive-reader set is unsound inside the
        #   unroll. Empty set ⇒ no loop operand is ever overwritten in place.
        # * `add=:ripple` — belt-and-braces. Post-U27 `_pick_add_strategy(:auto)`
        #   returns `:ripple` regardless, so this is byte-identical to the
        #   pre-y986 cascade for fast-path types. Override also defends
        #   against an explicit caller-passed `add=:cuccaro` (NOTE: this
        #   silently swaps the adder family for loop-region adds under an
        #   explicit `add=:cuccaro`/`:qcla` — tracked as a follow-up).
        # * Iteration-LOCAL `iter_block_pred` / `iter_branch_info` /
        #   `iter_preds` (Bennett-jepw): function-level dicts would only
        #   see the last iteration's view of body-block wires — useless
        #   to any consumer.
        iter_block_pred = Dict{Symbol,Vector{Int}}()
        iter_block_pred[hlabel] = opts.block_pred[hlabel]
        iter_branch_info = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}()
        iter_preds = Dict{Symbol,Vector{Symbol}}()

        iter_ctx = LoweringCtx(gates, wa, vw, iter_preds, iter_branch_info,
                               block_order, iter_block_pred,
                               Set{Symbol}(),   # Bennett-stwr: no in-place in loops
                               opts.compact_calls,
                               opts.alloca_info, opts.ptr_provenance, Ref(0),
                               opts.globals, :ripple, opts.mul, opts.entry_label,
                               Ref(false),   # Bennett-h0ai producer-tag
                               # Bennett-z2dj / T5-P6 (Step 2): persistent_tree
                               # dispatcher state — shared across iterations via
                               # the same opts.persistent_info dict.
                               opts.mem, opts.persistent_impl, opts.hashcons,
                               opts.persistent_info,
                               # Bennett-s0tn: shared loop-guard accumulator so
                               # an IRCall in a loop body whose callee itself
                               # has a data-dependent loop still records its
                               # guard. (Nested while-loops are rejected by
                               # _collect_loop_body_blocks; this path is for
                               # a callee-with-loop inlined inside a loop body.)
                               opts.loop_guards)

        # (a1) Lower header's non-phi instructions through the canonical
        # dispatcher. `header_body_insts` is in source order (collected at
        # line 901); phis are filtered out and the terminator lives in
        # `header.terminator`, never in `header.instructions`.
        for inst in header_body_insts
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
                # walked in-region predecessors. iter_preds[blabel] only
                # contains predecessors we have already lowered (header or
                # earlier body blocks in topological order); every body block
                # is reached from one of them (Bennett-c6ex: was a silent
                # `if`, leaving the block without a predicate).
                isempty(get(iter_preds, blabel, Symbol[])) && throw(AssertionError(
                    "lower_loop!: body block $blabel of loop $hlabel has no in-region " *
                    "predecessor recorded before it (Bennett-c6ex)"))
                iter_block_pred[blabel] =
                    _compute_block_pred!(gates, wa, blabel, iter_preds,
                                         iter_branch_info, iter_block_pred)

                for inst in bblock.instructions
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
        # `exit_cond_wire[1]` has "1 = loop exited / done" semantics; it
        # feeds the MUX at (e). Bennett-s0tn: the convergence check is NOT
        # this wire — see the post-loop (K+1)-th check-only pass below.
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

    # Bennett-s0tn: fail-loud loop-overflow detection.
    #
    # DEVIATION FROM CONSENSUS DESIGN (reported to orchestrator): the
    # design claimed iteration K's `exit_cond_wire` already holds the
    # convergence bit. It does NOT — `exit_cond_wire` from iteration K is
    # the exit condition evaluated at the START of iteration K, on the
    # post-(K-1) loop-carried state. The unrolled K-iteration circuit is
    # CORRECT iff the loop would have exited AFTER iteration K — i.e. the
    # exit condition is true on the POST-K state. Example: countdown(4)
    # with K=4 runs n: 4→3→2→1→0; iteration 4's start condition (n=1>0) is
    # "not done" yet the loop genuinely converged. Convergence must be
    # checked on the post-K phi-frozen values.
    #
    # Fix: run ONE more "check-only" evaluation of the header-body
    # instructions + the header's exit condition AFTER the K-th MUX, using
    # the frozen phi values. No body, no latch, no MUX — this is the
    # (K+1)-th condition check. Its result is the true convergence bit.
    conv_block_pred = Dict{Symbol,Vector{Int}}()
    conv_block_pred[hlabel] = opts.block_pred[hlabel]
    conv_ctx = LoweringCtx(gates, wa, vw, Dict{Symbol,Vector{Symbol}}(),
                           Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}(),
                           block_order, conv_block_pred,
                           Set{Symbol}(),   # Bennett-stwr: no in-place in loops
                           opts.compact_calls,
                           opts.alloca_info, opts.ptr_provenance, Ref(0),
                           opts.globals, :ripple, opts.mul, opts.entry_label,
                           Ref(false),
                           opts.mem, opts.persistent_impl, opts.hashcons,
                           opts.persistent_info, opts.loop_guards)
    for inst in header_body_insts
        _lower_inst!(conv_ctx, inst, hlabel)
    end
    postk_cond = resolve!(gates, wa, vw, term.cond, 1)
    # `postk_cond[1]==1` ⇔ header branch would take the body again.
    # Convergence ⇔ branch would take the EXIT instead.
    conv_cond = exit_on_true ? postk_cond : lower_not1!(gates, wa, postk_cond)

    # Copy the convergence bit into a fresh dedicated wire `conv_w`
    # (forward block). `bennett`'s copy-out then copies `conv_w` into a
    # fourth-class loop-check wire that survives the reverse pass;
    # `simulate` errors loud when it reads 0 (overflow).
    conv_w = allocate!(wa, 1)[1]
    push!(gates, CNOTGate(conv_cond[1], conv_w))
    push!(opts.loop_guards, LoopGuard(conv_w, hlabel, K))

    push!(get!(preds, exit_label, Symbol[]), hlabel)
end

