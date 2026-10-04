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

"""
    _immediate_dominators(blocks, unreachable) -> Dict{Symbol,Symbol}

Immediate dominator of every block reachable from the entry (`blocks[1]`),
by the Cooper–Harvey–Kennedy iterative algorithm over reverse postorder. The
entry maps to itself. Blocks in `unreachable` are absent.
"""
function _immediate_dominators(blocks::Vector{IRBasicBlock}, unreachable::Set{Symbol})
    entry = blocks[1].label
    succs = Dict{Symbol,Vector{Symbol}}()
    preds = Dict{Symbol,Vector{Symbol}}(b.label => Symbol[] for b in blocks)
    for b in blocks
        s = b.terminator isa IRBranch ?
            Symbol[t for t in branch_targets(b.terminator) if haskey(preds, t)] : Symbol[]
        succs[b.label] = s
        b.label in unreachable && continue
        for t in s
            push!(preds[t], b.label)
        end
    end
    # Reverse postorder of the reachable blocks (iterative DFS).
    post = Symbol[]
    visited = Set{Symbol}([entry])
    stack = Tuple{Symbol,Int}[(entry, 1)]
    while !isempty(stack)
        u, i = stack[end]
        if i <= length(succs[u])
            stack[end] = (u, i + 1)
            v = succs[u][i]
            v in visited || (push!(visited, v); push!(stack, (v, 1)))
        else
            pop!(stack); push!(post, u)
        end
    end
    rpo = reverse(post)
    num = Dict(l => i for (i, l) in enumerate(rpo))
    idom = Dict{Symbol,Symbol}(entry => entry)
    function intersect(a::Symbol, b::Symbol)
        while a !== b
            while num[a] > num[b]; a = idom[a]; end
            while num[b] > num[a]; b = idom[b]; end
        end
        return a
    end
    changed = true
    while changed
        changed = false
        for n in rpo
            n === entry && continue
            new = nothing
            for p in preds[n]
                haskey(idom, p) || continue
                new = new === nothing ? p : intersect(p, new)
            end
            new === nothing && continue
            if get(idom, n, nothing) !== new
                idom[n] = new; changed = true
            end
        end
    end
    return idom
end

"""
    _reachable_preds(blocks, unreachable) -> Dict{Symbol,Vector{Symbol}}

CFG predecessors of every block, counting only edges whose source is
reachable from the entry (an unreachable block's predicate is identically 0).
"""
function _reachable_preds(blocks::Vector{IRBasicBlock}, unreachable::Set{Symbol})
    preds = Dict{Symbol,Vector{Symbol}}(b.label => Symbol[] for b in blocks)
    for b in blocks
        b.label in unreachable && continue
        b.terminator isa IRBranch || continue
        for t in branch_targets(b.terminator)
            haskey(preds, t) && !(b.label in preds[t]) && push!(preds[t], b.label)
        end
    end
    return preds
end

"""
    _check_natural_loops(blocks, back_edges, unreachable)

Bennett-73gr: the unroller (`lower_loop!`) is sound only for NATURAL loops.
`find_back_edges` classifies by DFS colouring alone, which in an irreducible
region (a cycle with two entries, e.g. entry → H or L; L → H; H → exit or L)
marks L→H a back edge although H does not dominate L; the driver then drops
the entry→L edge and the circuit silently miscomputes (Astra B-lowering F18:
128/256 wrong, `verify_reversibility` passing). Requires, for every back edge
t→h with t reachable from the entry, that h dominates t. A CFG is reducible
iff every DFS retreating edge passes this test, so every irreducible CFG is
rejected whatever the DFS order. Fails loud naming the blocks; emits no
gates, so reducible CFGs lower byte-identically. The single-entry property of
the body the unroller actually walks is checked separately
(`_check_loop_single_entry`).
"""
function _check_natural_loops(blocks::Vector{IRBasicBlock},
                              back_edges::Vector{Tuple{Symbol,Symbol}},
                              unreachable::Set{Symbol})
    isempty(back_edges) && return nothing
    idom = _immediate_dominators(blocks, unreachable)
    entry = blocks[1].label
    function dominates(h::Symbol, n::Symbol)
        while true
            n === h && return true
            n === entry && return false
            n = idom[n]
        end
    end
    for (t, h) in back_edges
        t in unreachable && continue   # predicate ≡ 0; never executes
        dominates(h, t) || error("lower: irreducible CFG — the cycle through back edge " *
            "$t → $h has a side entry: $h does not dominate $t ($t is reachable from " *
            "the entry $entry without passing $h). This is not a natural loop; the " *
            "loop unroller would drop the side-entry edge and silently miscompute. " *
            "Irreducible control flow is not supported (Bennett-73gr)")
    end
    return nothing
end

"""
    _check_loop_single_entry(hlabel, body, preds)

Bennett-73gr: every block of the loop body the unroller walks
(`_collect_loop_body_blocks`) must have all its reachable predecessors inside
the loop (`hlabel` ∪ `body`); only the header may be entered from outside.
The unroller predicates body blocks solely from in-loop edges, so an outside
predecessor's edge would be silently dropped. Implied by
`_check_natural_loops` for well-formed natural loops; asserted here against
the region actually lowered.
"""
function _check_loop_single_entry(hlabel::Symbol, body::Vector{Symbol},
                                  preds::Dict{Symbol,Vector{Symbol}})
    inloop = Set{Symbol}(body); push!(inloop, hlabel)
    for n in body, p in preds[n]
        p in inloop || error("lower: irreducible CFG — loop $hlabel has a side entry: " *
            "body block $n has predecessor $p outside the loop. Only the loop header " *
            "may be entered from outside (Bennett-73gr)")
    end
    return nothing
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
    _loop_and!(gates, wa, w::Int, active::Union{Nothing,Int}) -> Int

Bennett-i5zn: a block predicate conjoined with the loop's iteration-active
("not yet exited") wire. `active === nothing` means "no active predicate yet"
— iteration 1, and only iteration 1, where entering the loop is by definition
active — and returns `w` unchanged, so the guard itself costs no gate there
(the one NOT that seeds `active_2` is emitted at the (c)/(e) step instead).
`w == active` returns `w` (a Toffoli with the same control twice is malformed
and would XOR 0).
"""
function _loop_and!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                    w::Int, active::Union{Nothing,Int})
    active === nothing && return w
    active == w && return w
    return _and_wire!(gates, wa, [w], [active])[1]
end

# Bennett-i5zn: instruction types whose result is a pure function of their SSA
# operands' wires. A header value built only from these (and from header phis
# and loop-invariant values) is recomputed IDENTICALLY by every post-exit
# replay of the header, because the phis are frozen. Anything else — an
# IRLoad above all, which reads memory a later header store has changed — is a
# taint source. Unlisted types are tainted by default (conservative).
const _LOOP_PURE_INSTS = Union{IRBinOp, IRICmp, IRSelect, IRCast, IRExtractValue,
                               IRInsertValue, IRInsertBits, IRPtrOffset, IRVarGEP,
                               IRCall}

_loop_inst_dest(inst::IRInst) = hasfield(typeof(inst), :dest) ? getfield(inst, :dest) : nothing

"""
    _loop_header_hold_set(header, body_labels, block_map) -> Vector{Symbol}

Bennett-i5zn: the header's non-phi SSA values that must be HELD at their
exit-visit value. The unroller re-lowers the header on every remaining
unrolled iteration and in the s0tn check-only pass, into the same `vw`, so
after the loop `vw[d]` is the value of the LAST replay, not of the header
visit that actually exited. That is harmless for a value that is a pure
function of the (frozen) phis and loop invariants — the replay recomputes it
bit-for-bit — but not for one that depends on a header load: after exit the
replayed load reads the post-exit memory (e.g. a load above a store in the
header sees the value that store wrote). So a header value is held iff it is
(a) used outside the loop region and (b) tainted by a non-pure instruction
(see `_LOOP_PURE_INSTS`). Pure loops therefore keep their gates byte-identical.

Values defined in BODY blocks (latch included) cannot be live after the loop:
the only exit edge leaves from the header (`_collect_loop_body_blocks` rejects
a body→exit edge), so the header→exit path bypasses every body block and no
body definition dominates a use outside the loop. Hand-written IR that does
use one is rejected loud — the unroller holds no such value, and `vw` would
silently give the last unrolled iteration's (possibly inactive) value.
"""
function _loop_header_hold_set(header::IRBasicBlock, body_labels::Vector{Symbol},
                               block_map::Dict{Symbol,IRBasicBlock})
    hlabel = header.label
    region = Set{Symbol}(body_labels)
    push!(region, hlabel)

    header_defs = Symbol[]
    tainted = Set{Symbol}()
    for inst in header.instructions
        inst isa IRPhi && continue
        d = _loop_inst_dest(inst)
        d === nothing && continue
        push!(header_defs, d)
        if !(inst isa _LOOP_PURE_INSTS) || any(in(tainted), _ssa_operands(inst))
            push!(tainted, d)
        end
    end

    body_defs = Dict{Symbol,Symbol}()
    for b in body_labels, inst in block_map[b].instructions
        d = _loop_inst_dest(inst)
        d === nothing || (body_defs[d] = b)
    end

    live_out = Set{Symbol}()
    for (lbl, blk) in block_map
        lbl in region && continue
        for item in Iterators.flatten((blk.instructions, (blk.terminator,)))
            for s in _ssa_operands(item)
                haskey(body_defs, s) && throw(AssertionError(
                    "lower_loop!: %$s is defined in body block $(body_defs[s]) of loop " *
                    "$hlabel but used outside the loop (in $lbl); the loop exits only from " *
                    "its header, so no body definition dominates a use after the loop — " *
                    "the unroller cannot hold such a value at its exit-visit value " *
                    "(Bennett-i5zn)"))
                push!(live_out, s)
            end
        end
    end
    return Symbol[d for d in header_defs if d in tainted && d in live_out]
end

"""
    _loop_hold!(gates, wa, vw, held, hold_set, active, hlabel; ptr_provenance, held_ptr)

Bennett-i5zn: fold the header values just (re-)lowered into `held` iff this
header visit really happened: `held[d] = active ? vw[d] : held[d]`. `active ===
nothing` is iteration 1 (always active), which seeds `held` with no gate.

Bennett-cohv: a held name that carries pointer provenance is held through
`_loop_hold_ptr!` into `held_ptr` instead — its value wires are not what a
load / store through it reads.
"""
function _loop_hold!(gates, wa, vw, held::Dict{Symbol,Vector{Int}},
                     hold_set::Vector{Symbol}, active::Union{Nothing,Int}, hlabel::Symbol;
                     ptr_provenance::Dict{Symbol,Vector{PtrOrigin}},
                     held_ptr::Dict{Symbol,Vector{Tuple{Symbol,Union{ConstOperand,Vector{Int}},Int}}})
    for d in hold_set
        if haskey(ptr_provenance, d)
            _loop_hold_ptr!(gates, wa, vw, held_ptr, d, ptr_provenance[d], active, hlabel)
            continue
        end
        haskey(held_ptr, d) && throw(AssertionError(
            "lower_loop!: header pointer %$d of loop $hlabel lost its provenance on a " *
            "later unrolled iteration (Bennett-cohv)"))
        haskey(vw, d) || throw(AssertionError(
            "lower_loop!: header value %$d of loop $hlabel is used after the loop and " *
            "depends on a load, but has no wires (a pointer-typed value?) — it cannot " *
            "be held at its exit-visit value (Bennett-i5zn)"))
        fresh = vw[d]
        if active === nothing
            held[d] = fresh
        else
            length(fresh) == length(held[d]) || throw(AssertionError(
                "lower_loop!: header value %$d of loop $hlabel changed width across " *
                "unrolled iterations ($(length(held[d])) → $(length(fresh))) (Bennett-i5zn)"))
            held[d] = lower_mux!(gates, wa, [active], fresh, held[d], length(fresh))
        end
    end
    return nothing
end

"""
    _loop_hold_ptr!(gates, wa, vw, held_ptr, d, origins, active, hlabel)

Bennett-cohv: hold a load-tainted header POINTER `d` that is used after the
loop. A load / store through a provenance-carrying pointer never reads
`vw[d]`; it follows `ptr_provenance[d]`, per origin an alloca, an element
index OPERAND (resolved lazily against `vw` at the use) and a selection
predicate WIRE. After the loop both are the last replay's — the post-exit
address (review 2 S2: the exit-block load used the index the exit visit had
already advanced). So hold, per origin, the index WIRES the operand names now
(`vw[name]` at this header visit; a constant index is fixed) and the predicate
wire, each as `active ? fresh : held`. A wire that is the same on every visit
(a loop-invariant index, an alloca's own predicate) costs no gate. The origin
list itself — count, allocas, constant-vs-runtime index — is fixed by the
header's static instructions, so a replay that changes it is an internal
error. `_loop_publish_ptr!` installs the held provenance after the loop.
"""
function _loop_hold_ptr!(gates, wa, vw, held_ptr, d::Symbol,
                         origins::Vector{PtrOrigin}, active::Union{Nothing,Int},
                         hlabel::Symbol)
    fresh = Tuple{Symbol,Union{ConstOperand,Vector{Int}},Int}[]
    for o in origins
        idx = if o.idx_op isa ConstOperand
            o.idx_op
        elseif o.idx_op isa SSAOperand && haskey(vw, o.idx_op.name)
            vw[o.idx_op.name]
        else
            throw(AssertionError("lower_loop!: header pointer %$d of loop $hlabel has an " *
                "origin in %$(o.alloca_dest) whose index $(o.idx_op) has no wires — it " *
                "cannot be held at its exit-visit address (Bennett-cohv)"))
        end
        push!(fresh, (o.alloca_dest, idx, o.predicate_wire))
    end
    if active === nothing || !haskey(held_ptr, d)
        active === nothing || throw(AssertionError(
            "lower_loop!: header pointer %$d of loop $hlabel gained provenance after " *
            "the first unrolled iteration (Bennett-cohv)"))
        held_ptr[d] = fresh
        return nothing
    end
    old = held_ptr[d]
    length(old) == length(fresh) || throw(AssertionError(
        "lower_loop!: header pointer %$d of loop $hlabel changed its origin count across " *
        "unrolled iterations ($(length(old)) → $(length(fresh))) (Bennett-cohv)"))
    for k in eachindex(fresh)
        (a0, i0, p0) = old[k]
        (a1, i1, p1) = fresh[k]
        same_kind = i0 isa ConstOperand ? (i1 isa ConstOperand && i1.value == i0.value) :
                    (i1 isa Vector{Int} && length(i1) == length(i0))
        (a0 == a1 && same_kind) || throw(AssertionError(
            "lower_loop!: origin $k of header pointer %$d of loop $hlabel changed across " *
            "unrolled iterations (%$a0[$(i0 isa ConstOperand ? i0.value : "$(length(i0)) wires")] → " *
            "%$a1[$(i1 isa ConstOperand ? i1.value : "$(length(i1)) wires")]) (Bennett-cohv)"))
        idx = (i0 isa ConstOperand || i1 == i0) ? i0 :
              lower_mux!(gates, wa, [active], i1, i0, length(i1))
        pred = p1 == p0 ? p0 : lower_mux!(gates, wa, [active], [p1], [p0], 1)[1]
        old[k] = (a0, idx, pred)
    end
    return nothing
end

"""
    _loop_publish_ptr!(vw, ptr_provenance, held_ptr, d)

Bennett-cohv: after the loop, make `ptr_provenance[d]` name the held index
wires (under fresh `__cohv_idx_<d>_<k>` names, so no later re-definition of
the original index name can move the address) and the held predicate wires.
`vw[d]` — at most a legacy MUX snapshot of the element, which no
provenance-routed load or store reads — is the last replay's, so it is
dropped rather than left behind stale: any reader of it now fails loud.
"""
function _loop_publish_ptr!(vw, ptr_provenance::Dict{Symbol,Vector{PtrOrigin}},
                            held_ptr, d::Symbol)
    published = PtrOrigin[]
    for (k, (a, idx, pred)) in enumerate(held_ptr[d])
        if idx isa ConstOperand
            push!(published, PtrOrigin(a, idx, pred))
        else
            tag = Symbol("__cohv_idx_", d, "_", k)
            vw[tag] = idx
            push!(published, PtrOrigin(a, ssa(tag), pred))
        end
    end
    ptr_provenance[d] = published
    delete!(vw, d)
    return nothing
end

"""
    _loop_header_always_reached(hlabel, block_map, entry_label) -> Bool

Bennett-n9o8: true iff every path from the entry that RETURNS passes through
loop header `hlabel`, so its path predicate is identically 1 and gating the
s0tn convergence guard by it would be the identity. Walks the CFG from the
entry without entering `hlabel`; reaching an `IRRet` block means some execution
skips the loop. Edges to `:__unreachable__` are not completing paths (no
lowered predicate either). Conservative: an unknown entry (the
`Symbol("")` sentinel) or an unrecognised terminator returns false, which
merely keeps the (always sound) gating.
"""
function _loop_header_always_reached(hlabel::Symbol, block_map, entry_label::Symbol)
    haskey(block_map, entry_label) || return false
    entry_label === hlabel && return true
    seen = Set{Symbol}([entry_label])
    stack = Symbol[entry_label]
    while !isempty(stack)
        t = block_map[pop!(stack)].terminator
        t isa IRRet && return false
        t isa IRBranch || return false
        for s in branch_targets(t)
            (s === :__unreachable__ || s === hlabel || s in seen) && continue
            haskey(block_map, s) || return false
            push!(seen, s); push!(stack, s)
        end
    end
    return true
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

Bennett-i5zn — iteration-active ("not yet exited") predicate. Every
observable effect of iteration k runs under `active_k` (see the block below):
the header's non-phi instructions (so a load / increment / store in the
header stops firing once the source loop exited), every body block (their
path predicates are derived from the header's), the loop-carried phi MUX
select, and the Bennett-s0tn check-only pass. After the first exit all
observable state is frozen, so the answer no longer depends on K. Pre-i5zn
only the phis were frozen, and the answer DID depend on K: a header store
replayed on every unrolled iteration, silently (verify_reversibility passed).
Freezing effects is not enough for header VALUES: each replay re-lowers the
header into `vw`, and a replayed load reads the post-exit memory. Header values
used after the loop that depend on a load are therefore held at their
exit-visit value (`_loop_header_hold_set` / `_loop_hold!`), the check-only
pass's values folded in only under `active_{K+1}`.
"""
# Bennett-x2iw / U88: optional state bundled in `opts::BlockLoweringOpts`
# (loop_headers field is consumed by `lower_loop!`; lower_block_insts!
# ignores it). `block_order` stays positional — every real caller passes
# the function-level Dict{Symbol,Int} from `lower()`.
function lower_loop!(gates, wa, vw, header::IRBasicBlock, block_map,
                     back_edges, K::Int, preds, branch_info, block_order;
                     opts::BlockLoweringOpts = BlockLoweringOpts())
    hlabel = header.label

    # Bennett-i5zn: K >= 1 is a precondition of the iteration-active
    # recurrence (`active_{k+1}` is what the convergence pass below reads).
    # `lower()` already refuses max_loop_iterations <= 0 for a looping IR.
    K >= 1 || throw(AssertionError("lower_loop!: max_loop_iterations=$K is not a " *
          "valid unroll bound for loop header $hlabel — the Bennett-i5zn " *
          "iteration-active recurrence needs at least one unrolled iteration"))

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

    # Bennett-i5zn: header values that must be held at their exit-visit value
    # (live after the loop AND load-tainted) — see `_loop_header_hold_set`.
    hold_set = _loop_header_hold_set(header, body_block_order, block_map)
    held = Dict{Symbol,Vector{Int}}()
    # Bennett-cohv: held pointers — per origin (alloca, index, predicate wire).
    held_ptr = Dict{Symbol,Vector{Tuple{Symbol,Union{ConstOperand,Vector{Int}},Int}}}()

    # Bennett-jepw: the function-level pass (src/lower.jl ~437) populates
    # block_pred[hlabel] before calling lower_loop!. We rely on this for
    # body-block predicate computation below. Verify the contract.
    haskey(opts.block_pred, hlabel) ||
        throw(AssertionError("lower_loop!: block_pred[$hlabel] must be populated by the " *
              "function-level pass before lower_loop! is called " *
              "(Bennett-jepw contract)"))
    # Bennett-p94b: every block_pred entry is a SINGLE-bit wire. Bennett-i5zn
    # conjoins this one wire with the iteration-active wire, so a multi-bit
    # predicate would silently use only bit 0.
    length(opts.block_pred[hlabel]) == 1 ||
        throw(AssertionError("lower_loop!: block_pred[$hlabel] has " *
              "$(length(opts.block_pred[hlabel])) wires; expected 1 (Bennett-p94b)"))
    header_pred::Int = opts.block_pred[hlabel][1]

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

    # ---- Bennett-i5zn: the iteration-active ("not yet exited") predicate ----
    #
    # `iter_active` is `nothing` for iteration 1 (entering the loop for the
    # first time is always active) and a 1-bit wire from iteration 2 on,
    # holding 1 iff the SOURCE loop had not exited before this iteration
    # started. It is conjoined into the header's non-phi instructions, into
    # the iteration-local header path predicate (from which every BODY block
    # predicate is derived, since `_compute_block_pred!` ANDs the predicates
    # of the in-region predecessors), into the loop-carried phi MUX select
    # (as `stopped_k = NOT(active_{k+1})`), and into the s0tn check-only pass.
    # Once the source loop exits, `iter_active` stays 0 and every remaining
    # unrolled iteration is effect-free.
    #
    # `stopped` = 1 ⇔ the loop stopped after the iteration just lowered
    # ⇔ NOT(active_{k+1}). On iteration 1 the MUX select is the historical
    # `exit_cond_wire` (no gate added to the select); the ONLY addition on
    # iteration 1 is the single NOT at (c) that seeds `active_2`.
    iter_active::Union{Nothing,Int} = nothing
    stopped::Int = 0

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
        # Bennett-i5zn: the header's own effects (a load / increment / store
        # before the exit test) are gated by the iteration-active predicate.
        # Every body block below inherits it through `_compute_block_pred!`.
        iter_block_pred[hlabel] = [_loop_and!(gates, wa, header_pred, iter_active)]
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
                               opts.loop_guards,
                               opts.persistent_writes)   # Bennett-9378

        # (a1) Lower header's non-phi instructions through the canonical
        # dispatcher. `header_body_insts` is in source order (collected at
        # line 901); phis are filtered out and the terminator lives in
        # `header.terminator`, never in `header.instructions`.
        for inst in header_body_insts
            _lower_inst!(iter_ctx, inst, hlabel)
        end
        _loop_hold!(gates, wa, vw, held, hold_set, iter_active, hlabel;   # Bennett-i5zn
                    ptr_provenance=opts.ptr_provenance, held_ptr)            # Bennett-cohv

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
        # `exit_cond_wire[1]` has "1 = loop exited / done" semantics;
        # `cont_wire[1]` is its complement ("1 = the loop continues"), which
        # is what seeds `active_{k+1}`. One NOT total, whichever polarity
        # `exit_on_true` needs, so the pre-i5zn gate sequence is preserved up
        # to that single NOT. Bennett-s0tn: the convergence check is NOT
        # this wire — see the post-loop (K+1)-th check-only pass below.
        if exit_on_true
            exit_cond_wire = raw_cond_wire
            cont_wire = lower_not1!(gates, wa, raw_cond_wire)
        else
            cont_wire = raw_cond_wire
            exit_cond_wire = lower_not1!(gates, wa, raw_cond_wire)
        end

        # (d) Resolve latch values (what the phi would receive on next iter).
        latch_vals = Vector{Int}[]
        for (_, width, _, latch_op) in phi_info
            push!(latch_vals, resolve!(gates, wa, vw, latch_op, width))
        end

        # (e) MUX: keep the current value unless this iteration was still
        # active AND the exit condition did not fire.
        # Bennett-i5zn: `active_{k+1} = active_k ∧ continue_k`, so
        # `stopped_k = NOT(active_{k+1})` is exactly the freeze condition. On
        # iteration 1 that is the historical `exit_cond_wire`; from iteration 2
        # on it ALSO freezes an iteration that was already inactive, where
        # `exit_cond_wire` is garbage.
        cont = _loop_and!(gates, wa, cont_wire[1], iter_active)
        stopped = iter_active === nothing ? exit_cond_wire[1] :
                  lower_not1!(gates, wa, [cont])[1]
        iter_active = cont
        for (k, (dest, width, _, _)) in enumerate(phi_info)
            current = vw[dest]
            new_val = latch_vals[k]
            vw[dest] = lower_mux!(gates, wa, [stopped], current, new_val, width)
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
    #
    # Bennett-i5zn: this pass models the source loop's (K+1)-th header
    # VISIT, which happens iff the loop was still running after iteration K.
    # Its instructions therefore run under `active_{K+1}` — pre-i5zn they ran
    # under the constant function-level header predicate and REPLAYED header
    # effects (a store!) on an already-exited path, which is what made a
    # header-side-effecting loop's answer depend on K.
    iter_active === nothing &&
        throw(AssertionError("lower_loop!: the (K+1)-th check-only pass of loop " *
              "$hlabel has no iteration-active wire; K=$K produced no iteration " *
              "(Bennett-i5zn)"))
    conv_block_pred = Dict{Symbol,Vector{Int}}()
    conv_block_pred[hlabel] = [_loop_and!(gates, wa, header_pred, iter_active)]
    conv_ctx = LoweringCtx(gates, wa, vw, Dict{Symbol,Vector{Symbol}}(),
                           Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}(),
                           block_order, conv_block_pred,
                           Set{Symbol}(),   # Bennett-stwr: no in-place in loops
                           opts.compact_calls,
                           opts.alloca_info, opts.ptr_provenance, Ref(0),
                           opts.globals, :ripple, opts.mul, opts.entry_label,
                           Ref(false),
                           opts.mem, opts.persistent_impl, opts.hashcons,
                           opts.persistent_info, opts.loop_guards,
                           opts.persistent_writes)
    for inst in header_body_insts
        _lower_inst!(conv_ctx, inst, hlabel)
    end
    # Bennett-i5zn: the (K+1)-th visit is real iff `active_{K+1}` — the source
    # loop may exit exactly there (trip count K), and then ITS header values
    # are the ones the exit block reads. Fold them in under that predicate,
    # then publish the held values in place of the last replay's.
    _loop_hold!(gates, wa, vw, held, hold_set, iter_active, hlabel;
                ptr_provenance=opts.ptr_provenance, held_ptr)
    postk_cond = resolve!(gates, wa, vw, term.cond, 1)
    for d in hold_set
        if haskey(held_ptr, d)
            _loop_publish_ptr!(vw, opts.ptr_provenance, held_ptr, d)   # Bennett-cohv
        else
            vw[d] = held[d]
        end
    end
    # `postk_cond[1]==1` ⇔ header branch would take the body again.
    # Convergence ⇔ branch would take the EXIT instead.
    conv_exit = exit_on_true ? postk_cond : lower_not1!(gates, wa, postk_cond)
    # Bennett-i5zn: converged ⇔ the loop stopped within the K unrolled
    # iterations (`stopped` = NOT(active_{K+1}); pre-i5zn the check-only pass
    # saw the frozen state, whose exit condition equals the one that stopped
    # the loop, so this term is the same value in the pure-SSA case) OR this
    # (K+1)-st header visit would itself have exited.
    conv_cond = _or_wire!(gates, wa, [stopped], conv_exit)

    # Copy the convergence bit into a fresh dedicated wire `conv_w`
    # (forward block). `bennett`'s copy-out then copies `conv_w` into a
    # fourth-class loop-check wire that survives the reverse pass;
    # `simulate` errors loud when it reads 0 (overflow).
    #
    # Bennett-n9o8: the guard may fire only on an execution that REACHES the
    # header. When `header_pred` = 0 (the loop sits in an untaken arm) the
    # unrolled body still ran — branchlessly — on its seed values, so
    # `conv_cond` is garbage there. Report converged := ¬header_pred ∨ conv_cond
    # = 1 ⊕ header_pred ⊕ (header_pred ∧ conv_cond), written straight into
    # `conv_w` (3 gates, no ancilla). When every returning path from the entry
    # passes through the header, `header_pred` is identically 1 and the gating
    # is the identity, so it is skipped and such loops keep their gate counts
    # (see `_loop_header_always_reached`). (The values leaving a skipped loop
    # are already masked by the header's edge predicates in the exit-block phi
    # resolution.)
    conv_w = allocate!(wa, 1)[1]
    if _loop_header_always_reached(hlabel, block_map, opts.entry_label)
        push!(gates, CNOTGate(conv_cond[1], conv_w))
    else
        push!(gates, NOTGate(conv_w))
        push!(gates, CNOTGate(header_pred, conv_w))
        push!(gates, ToffoliGate(header_pred, conv_cond[1], conv_w))
    end
    push!(opts.loop_guards, LoopGuard(conv_w, hlabel, K))

    push!(get!(preds, exit_label, Symbol[]), hlabel)
end

