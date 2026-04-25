"""
Gate range for one adder in the parallel adder tree. Used by
`emit_parallel_adder_tree!` to replay the inverse when uncomputing the
adder. `gs` is inclusive; `ge` is inclusive.
"""
struct _AdderRecord
    gs::Int
    ge::Int
end

"""
    emit_parallel_adder_tree!(gates, wa, pp, W; reuse_pool=Int[]) -> Vector{Int}

Sun-Borissov 2026 §II.D — parallel adder tree producing `xy` from the
partial products `pp` (a vector of `W` `W`-wire registers, each carrying
`α^{(0,i)} = y_i · x`).

At level `d`, computes `α^{(d,r)} = α^{(d-1,2r)} + 2^{2^{d-1}} · α^{(d-1,2r+1)}`.
The root after `⌈log₂ W⌉` levels is the (2W)-bit product.

**A3 uncompute scheme.** After the forward tree computes levels 1..D,
this function replays each non-root adder's gate range in reverse,
**starting from level D-1 and working down to level 1**. See WORKLOG
2026-04-14 for why the paper's "uncompute level d-2 at level d" schedule
is unsafe as-stated (inverse needs level d-3 intact at replay time, which
fails when level d-3 has been zeroed by earlier steps). Uncomputing in
reverse level order has the same total gate count and is correct by
construction.

Bennett-d1ee / U141 — **proof of correctness for the reverse-level
schedule.** Each non-root adder at level d ∈ {1, …, D-1} is recorded
as (gate_start, gate_end) in `records[d]`. Replaying gates[ge..gs] in
reverse is the inverse of `lower_add_qcla!` IFF the inputs to that
adder (left, right pads) still hold their forward-pass values at
replay time. The forward pass writes them at level d via CNOT-copies
from level d-1's outputs (lines 80-87 below); those level-d-1 outputs
are themselves uncomputed at level d-1's replay step. Replaying in
order **D-1, D-2, ..., 1** guarantees that for every adder at level
d, its inputs (level d-1's outputs) are still live when its gates
replay — they get cleaned only at d-1's later replay. Conversely,
the paper's "uncompute level d-2 at level d" schedule would zero the
level d-3 intermediates **before** level d's adder replay needs them,
breaking the inverse contract.

The total uncompute gate count equals the forward gate count for
levels 1..D-1 (every adder's range is replayed once), so the overall
circuit is exactly 2× the forward gate count of those levels plus
the root level D's forward-only contribution.

Implementation uses proposer A's "Strategy α" consensus
(`docs/design/parallel_adder_tree_consensus.md`): black-box
`lower_add_qcla!` on zero-padded operands, one adder per pair, odd
child bubbled up unchanged.

Return value: exactly `2W` wires, result's LSB at index 1. All non-root
wires (pad registers, QCLA ancillae, intermediate partial-sum registers
at levels 1..D-1) return to zero.
"""
function emit_parallel_adder_tree!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                   pp::Vector{Vector{Int}}, W::Int;
                                   reuse_pool::Vector{Int}=Int[])
    W >= 1 || error("emit_parallel_adder_tree!: W must be >= 1, got $W")
    length(pp) == W ||
        error("emit_parallel_adder_tree!: expected $W partial products, got $(length(pp))")
    all(p -> length(p) == W, pp) ||
        error("emit_parallel_adder_tree!: every partial product must have W=$W wires")

    # Trivial: W == 1 — result is just pp[1] padded to 2 wires.
    if W == 1
        out = allocate!(wa, 2)
        push!(gates, CNOTGate(pp[1][1], out[1]))
        return out
    end

    D = ceil(Int, log2(W))
    current = collect(pp)            # shallow copy (we don't mutate pp itself)
    current_w = W

    # Per-level adder records (for uncompute). records[d] lists the adders
    # emitted at level d. Level 1..D-1 records are replayed in reverse.
    records = [_AdderRecord[] for _ in 1:D]

    for d in 1:D
        shift = 1 << (d - 1)
        n = length(current)
        n >= 2 || break

        pad_w = current_w + shift
        next_w = pad_w + 1
        next_level = Vector{Vector{Int}}()

        r = 0
        while 2r + 2 <= n
            left  = current[2r + 1]
            right = current[2r + 2]

            gs = length(gates) + 1

            left_pad = allocate!(wa, pad_w)
            for k in 1:current_w
                push!(gates, CNOTGate(left[k], left_pad[k]))
            end

            right_pad = allocate!(wa, pad_w)
            for k in 1:current_w
                push!(gates, CNOTGate(right[k], right_pad[k + shift]))
            end

            sum_result = lower_add_qcla!(gates, wa, left_pad, right_pad, pad_w)

            ge = length(gates)
            push!(records[d], _AdderRecord(gs, ge))
            push!(next_level, sum_result)
            r += 1
        end

        # Odd child bubble-up: CNOT-copy leftover into fresh width-next_w register.
        if 2r + 1 == n
            gs = length(gates) + 1
            leftover = current[n]
            padded = allocate!(wa, next_w)
            for k in 1:current_w
                push!(gates, CNOTGate(leftover[k], padded[k]))
            end
            ge = length(gates)
            push!(records[d], _AdderRecord(gs, ge))
            push!(next_level, padded)
        end

        current = next_level
        current_w = next_w
    end

    length(current) == 1 ||
        error("emit_parallel_adder_tree!: expected 1 root after $D levels, got $(length(current))")
    root = current[1]

    # Copy the root's low 2W bits to a fresh output register BEFORE uncomputing.
    # This lets us uncompute the top-level adder too (which also holds dirty
    # pad wires copied from level D-1). After uncompute, final_out is the only
    # non-zero register.
    final_out = allocate!(wa, 2W)
    for k in 1:min(length(root), 2W)
        push!(gates, CNOTGate(root[k], final_out[k]))
    end

    # Uncompute all levels 1..D in REVERSE order. Each level's adders read
    # from the previous level (still intact at replay time) and write to the
    # current level (dirty). Replaying inverse zeros the current level's
    # outputs, internal ancillae, AND pad registers. Next iteration
    # uncomputes the now-dirty previous level, which still has intact inputs.
    for d in D:-1:1
        for rec in records[d]
            for i in rec.ge:-1:rec.gs
                push!(gates, gates[i])
            end
        end
    end

    return final_out
end
