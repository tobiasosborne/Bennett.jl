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
    isempty(pred_list) && error("_compute_block_pred!: block $label has no predecessors for predicate computation")

    # Bennett-p94b / U110: predecessor list must be distinct labels. A
    # duplicate would OR-fold the same predicate twice, breaking the
    # "exactly one fires" guarantee that resolve_phi_predicated! relies on
    # (CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS RISK").
    length(unique(pred_list)) == length(pred_list) ||
        error("_compute_block_pred!: block $label has duplicate predecessors " *
              "$(pred_list); each predecessor must appear at most once " *
              "(Bennett-p94b)")

    contributions = Vector{Int}[]
    for p in pred_list
        haskey(block_pred, p) || continue  # skip if predecessor has no predicate (loop)
        # Bennett-p94b / U110: every block_pred entry is a SINGLE-bit wire.
        # A multi-bit value would have only bit 0 consumed by the AND/OR
        # contribution chain — silent corruption.
        length(block_pred[p]) == 1 ||
            error("_compute_block_pred!: block_pred[$p] has " *
                  "$(length(block_pred[p])) wires; expected 1 (Bennett-p94b)")
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

    isempty(contributions) && error("_compute_block_pred!: no predicate contributions for block $label")

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
    # Bennett-p94b / U110: width-1 invariant. Every block_pred entry is a
    # SINGLE-bit wire — `_and_wire!` / `_not_wire!` both index `[1]`, so
    # a wider value would silently use only bit 0.
    length(block_pred[src_block]) == 1 ||
        error("_edge_predicate!: block_pred[$src_block] has " *
              "$(length(block_pred[src_block])) wires; expected 1 (Bennett-p94b)")
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
    # Bennett-fq8n / U84: validate every incoming wire-vector has the
    # phi's declared width. resolve! does not check SSA widths against
    # its `width` argument, so a mismatched vw[name] silently propagates
    # here and breaks downstream MUX-chain construction.
    for (k, (wires, blk)) in enumerate(incoming)
        length(wires) == inst.width ||
            error("lower_phi!: incoming #$k from block $blk has " *
                  "width=$(length(wires)) but phi %$(inst.dest) " *
                  "declares width=$(inst.width) (Bennett-fq8n)")
    end
    isempty(block_pred) && error("lower_phi!: block_pred is empty during phi resolution for $(inst.dest) — path predicates must be computed before phi lowering")
    vw[inst.dest] = resolve_phi_predicated!(gates, wa, incoming, block_pred, inst.width;
                                            phi_block=phi_block, branch_info)
end

# Bennett-l9az / U69: legacy phi resolver deleted 2026-04-25.
# `has_ancestor`, `on_branch_side`, `_is_on_side`, and the recursive
# `resolve_phi_muxes!` (90 LOC, branch-side-partitioning approach) had
# zero references outside their own definitions; the live dispatcher
# `lower_phi!` (above) routes only to `resolve_phi_predicated!`.  Per
# CLAUDE.md §47-61 (phi resolution is the project's #1 correctness
# risk), having two phi resolvers in the same file invited future
# contributors to extend the wrong path.  Git retains history.

