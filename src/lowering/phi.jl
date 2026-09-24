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

Bennett-c6ex preconditions (every violation is an `AssertionError`, never a
silently dropped OR-term):
  - every recorded predecessor already carries a predicate. `preds` is filled
    lazily from already-lowered terminators, so a back-edge latch is never in
    `preds[label]` when `label`'s predicate is computed, and entry-unreachable
    blocks record no edges at all (`lower`, driver.jl). Their predicate is
    identically 0, so leaving them out is exact;
  - a conditional predecessor branches to `label` on exactly one side.
    Same-target branches (`br c, X, X`) are rewritten by
    `_canonicalize_same_target_branches` before lowering.
"""
function _compute_block_pred!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                              label::Symbol, preds::Dict{Symbol,Vector{Symbol}},
                              branch_info::Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}},
                              block_pred::Dict{Symbol,Vector{Int}})
    pred_list = get(preds, label, Symbol[])
    isempty(pred_list) && throw(AssertionError("_compute_block_pred!: block $label has no predecessors for predicate computation"))

    # Bennett-p94b / U110: predecessor list must be distinct labels. A
    # duplicate would OR-fold the same predicate twice, breaking the
    # "exactly one fires" guarantee that resolve_phi_predicated! relies on
    # (CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS RISK").
    length(unique(pred_list)) == length(pred_list) ||
        throw(AssertionError("_compute_block_pred!: block $label has duplicate predecessors " *
              "$(pred_list); each predecessor must appear at most once " *
              "(Bennett-p94b)"))

    contributions = Vector{Int}[]
    for p in pred_list
        # Bennett-c6ex: was `haskey(block_pred, p) || continue`, which silently
        # dropped p's OR-term and so under-approximated block_pred[label].
        haskey(block_pred, p) ||
            throw(AssertionError("_compute_block_pred!: predecessor $p of block $label has " *
                  "no path predicate; omitting its OR-term would silently " *
                  "under-approximate block_pred[$label]. Every recorded predecessor must " *
                  "already be lowered (topological order; entry-unreachable blocks record " *
                  "no edges) (Bennett-c6ex; CLAUDE.md 'Phi Resolution')"))
        # Bennett-p94b / U110: every block_pred entry is a SINGLE-bit wire.
        # A multi-bit value would have only bit 0 consumed by the AND/OR
        # contribution chain — silent corruption.
        length(block_pred[p]) == 1 ||
            throw(AssertionError("_compute_block_pred!: block_pred[$p] has " *
                  "$(length(block_pred[p])) wires; expected 1 (Bennett-p94b)"))
        if haskey(branch_info, p)
            (cw, tlabel, flabel) = branch_info[p]
            tlabel === flabel &&
                throw(AssertionError("_compute_block_pred!: block $p ends in a conditional " *
                      "branch whose two targets are both $tlabel; AND(pred, cond) would drop " *
                      "the false edge. `_canonicalize_same_target_branches` must run before " *
                      "lowering (Bennett-c6ex)"))
            if tlabel == label
                # True side: AND(pred[p], cond)
                push!(contributions, _and_wire!(gates, wa, block_pred[p], cw))
            elseif flabel == label
                # False side: AND(pred[p], NOT(cond))
                not_cw = _not_wire!(gates, wa, cw)
                push!(contributions, _and_wire!(gates, wa, block_pred[p], not_cw))
            else
                # Bennett-c6ex: was a silent no-op (p's contribution vanished).
                throw(AssertionError("_compute_block_pred!: $p is recorded as a predecessor " *
                      "of $label but its conditional branch targets ($tlabel, $flabel); " *
                      "preds and branch_info disagree (Bennett-c6ex)"))
            end
        else
            # Unconditional branch: just propagate
            push!(contributions, block_pred[p])
        end
    end

    isempty(contributions) && throw(AssertionError("_compute_block_pred!: no predicate contributions for block $label"))

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
- No `branch_info` entry: edge_pred = block_pred[src_block]. This is exact
  for an unconditional branch src_block → phi_block, for a loop header seen
  from its exit block (the unrolled loop leaves through the header exactly
  once; non-convergence is caught by the `LoopGuard`), and for a return block
  in the multi-return merge (`phi_block === Symbol("")`).

Bennett-c6ex: a conditional src_block that targets neither side of phi_block,
or both sides, is an `AssertionError`. Before c6ex it fell through to
`block_pred[src_block]`, which over-approximates the edge predicate
(false-path sensitisation). Callers establish that the edge exists:
`lower_phi!` asserts incoming ⊆ registered predecessors, and `lower` runs
`_check_predication_cfg` up front.

Returns a Vector{Int} (1-wire) for AND-reduction compatibility with the
existing MUX chain.
"""
function _edge_predicate!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                          src_block::Symbol, phi_block::Symbol,
                          block_pred::Dict{Symbol,Vector{Int}},
                          branch_info::Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}})
    haskey(block_pred, src_block) ||
        throw(AssertionError("_edge_predicate!: no predicate for block $src_block in phi resolution"))
    # Bennett-p94b / U110: width-1 invariant. Every block_pred entry is a
    # SINGLE-bit wire — `_and_wire!` / `_not_wire!` both index `[1]`, so
    # a wider value would silently use only bit 0.
    length(block_pred[src_block]) == 1 ||
        throw(AssertionError("_edge_predicate!: block_pred[$src_block] has " *
              "$(length(block_pred[src_block])) wires; expected 1 (Bennett-p94b)"))
    if haskey(branch_info, src_block)
        (cw, tlabel, flabel) = branch_info[src_block]
        tlabel === flabel &&
            throw(AssertionError("_edge_predicate!: block $src_block ends in a conditional " *
                  "branch whose two targets are both $tlabel; AND(pred, cond) would drop the " *
                  "false edge. `_canonicalize_same_target_branches` must run before lowering " *
                  "(Bennett-c6ex)"))
        if tlabel == phi_block
            return _and_wire!(gates, wa, block_pred[src_block], cw)
        elseif flabel == phi_block
            not_cw = _not_wire!(gates, wa, cw)
            return _and_wire!(gates, wa, block_pred[src_block], not_cw)
        end
        throw(AssertionError("_edge_predicate!: block $src_block ends in a conditional " *
              "branch to ($tlabel, $flabel), neither of which is $phi_block. There is no " *
              "edge $src_block → $phi_block; returning block_pred[$src_block] would " *
              "over-approximate the edge predicate (false-path sensitisation, CLAUDE.md " *
              "'Phi Resolution'). The phi cites a non-predecessor: malformed IR, or a CFG " *
              "rewrite (e.g. `_expand_switches`) did not patch it (Bennett-c6ex)"))
    end
    # No branch_info: unconditional edge, loop header → its exit, or a return
    # block in the multi-return merge (see docstring). That the edge exists is
    # the caller's obligation (Bennett-c6ex: `_assert_phi_incoming_preds`).
    return block_pred[src_block]
end

"""
    PredAuditRecord

Bennett-c6ex debug-mode audit record: one per predicated merge emitted by
`resolve_phi_predicated!` while `PRED_AUDIT` is active. The merge is live iff
every wire in `active_pos` is 1. Soundness (P4) requires that on every input the
number of DISTINCT `srcs` whose `edge_wires` read 1 is exactly 1 when the merge
is live and 0 otherwise. `site` is one of `:phi`, `:multi_ret`, `:loop_seed`.
"""
struct PredAuditRecord
    site::Symbol
    phi_block::Symbol
    active_pos::Vector{Int}
    srcs::Vector{Symbol}
    edge_wires::Vector{Int}
end

"""
    PRED_AUDIT

Bennett-c6ex debug-mode mutual-exclusion auditor. Off by default (`nothing`).
Under `Base.ScopedValues.with(PRED_AUDIT => recs) do lower(...) end`, every
predicated merge pushes a `PredAuditRecord` into `recs`, holding the forward
wires of its edge predicates. A test oracle then simulates the forward gates
(`fold_constants=false`, so wire indices are stable) and checks exclusion and
coverage. Emits zero gates whether on or off.
"""
const PRED_AUDIT = Base.ScopedValues.ScopedValue{Union{Nothing,Vector{PredAuditRecord}}}(nothing)

"""Resolve phi node using path predicates.

For each incoming (wires, from_block), compute the **edge predicate** — the
condition that control flowed from from_block to the phi's block via the
specific edge. This is AND(block_pred[from], branch_condition) for conditional
branches, or block_pred[from] for unconditional branches.

Chain MUXes controlled by edge predicates. Since the edge predicates are
mutually exclusive, exactly one fires.

Preconditions (Bennett-c6ex), without which exclusion and coverage fail:
  - the CFG is canonicalised (no same-target conditional branches);
  - `_check_predication_cfg` passed: phi incomings ⊆ CFG predecessors, every
    predecessor has an incoming, and duplicate incomings agree;
  - loops are single-exit (`_collect_loop_body_blocks`);
  - loops are single-latch, or every latch carries the same value (`lower_loop!`).
"""
function resolve_phi_predicated!(gates, wa, incoming, block_pred, W;
                                 phi_block::Symbol=Symbol(""),
                                 branch_info::Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}=Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}(),
                                 audit_site::Symbol=:phi)
    # Single incoming: the phi dest ALIASES the incoming value's wires (no
    # copy). This is why `IRPhi` is excluded from `_INPLACE_FRESH_DEFS`
    # (Bennett-stwr): an in-place adder overwriting a phi dest would also
    # overwrite the incoming name, which may still be read elsewhere.
    length(incoming) == 1 && return incoming[1][1]

    # Compute edge predicates for each incoming value
    edge_preds = Vector{Int}[]
    for (_, blk) in incoming
        push!(edge_preds, _edge_predicate!(gates, wa, blk, phi_block,
                                           block_pred, branch_info))
    end

    # Bennett-c6ex: debug-mode audit (records wires only; emits no gates).
    rec = PRED_AUDIT[]
    if rec !== nothing
        is_ret = phi_block === Symbol("")
        pos = is_ret ? Int[] : [block_pred[phi_block][1]]
        push!(rec, PredAuditRecord(is_ret ? :multi_ret : audit_site, phi_block, pos,
                                   Symbol[b for (_, b) in incoming],
                                   Int[e[1] for e in edge_preds]))
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

"""
    _assert_phi_incoming_preds(dest, incoming, phi_block, preds)

Bennett-c6ex invariant I2: every phi incoming block is a REGISTERED predecessor
of `phi_block` in `preds`. That is the function-level dict, or `lower_loop!`'s
iteration-local `iter_preds` for a phi in a loop body. Given I2, and the fact
that `preds` and `branch_info` are written from the same terminator, a
conditional incoming block always targets `phi_block`, so the edge predicate
is exact. Without I2 a phi citing a non-predecessor got `block_pred[src]`
silently. That happened both through the conditional arm (CE3: 127/256 wrong)
and through the no-`branch_info` fall-through (CE3u: 127/256 wrong).
"""
function _assert_phi_incoming_preds(dest::Symbol, incoming, phi_block::Symbol, preds)
    plist = get(preds, phi_block, Symbol[])
    for (_, blk) in incoming
        blk in plist || throw(AssertionError(
            "lower_phi!: phi %$dest in block $phi_block has an incoming from block " *
            "$blk, which is not a registered predecessor of $phi_block (registered: " *
            "$plist). Either the IR is malformed (the phi cites a non-predecessor), or " *
            "$blk is entry-unreachable (dead blocks record no edges), or it is a loop " *
            "block that lower_loop! does not model as an edge into $phi_block " *
            "(Bennett-c6ex; CLAUDE.md 'Phi Resolution')"))
    end
    return nothing
end

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
            throw(AssertionError("lower_phi!: ptr-phi %$(inst.dest) requires ptr_provenance threading"))
        isempty(block_pred) &&
            throw(AssertionError("lower_phi!: ptr-phi %$(inst.dest) needs block_pred for edge predicates"))
        _assert_phi_incoming_preds(inst.dest, inst.incoming, phi_block, preds)   # Bennett-c6ex
        merged = PtrOrigin[]
        for (val, src_block) in inst.incoming
            val isa SSAOperand ||
                throw(ArgumentError("lower_phi!: ptr-phi %$(inst.dest) incoming from non-SSA operand $(val)"))
            haskey(ptr_provenance, val.name) ||
                throw(AssertionError("lower_phi!: ptr-phi %$(inst.dest) incoming %$(val.name) has no provenance"))
            edge_pred = _edge_predicate!(gates, wa, src_block, phi_block,
                                         block_pred, branch_info)
            for o in ptr_provenance[val.name]
                combined = _and_wire!(gates, wa, [o.predicate_wire], edge_pred)
                push!(merged, PtrOrigin(o.alloca_dest, o.idx_op, combined[1]))
            end
        end
        isempty(merged) &&
            throw(AssertionError("lower_phi!: ptr-phi %$(inst.dest) produced empty origin set"))
        length(merged) <= 8 ||
            throw(ArgumentError("lower_phi!: ptr-phi %$(inst.dest) fan-out $(length(merged)) > 8 " *
                  "exceeds M2b budget; file a bd issue"))
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
            throw(DimensionMismatch("lower_phi!: incoming #$k from block $blk has " *
                  "width=$(length(wires)) but phi %$(inst.dest) " *
                  "declares width=$(inst.width) (Bennett-fq8n)"))
    end
    # Bennett-c6ex: after the fq8n width loop so a width mismatch still reports
    # as DimensionMismatch first.
    _assert_phi_incoming_preds(inst.dest, inst.incoming, phi_block, preds)
    isempty(block_pred) && throw(AssertionError("lower_phi!: block_pred is empty during phi resolution for $(inst.dest) — path predicates must be computed before phi lowering"))
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

