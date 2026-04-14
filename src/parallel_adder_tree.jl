"""
    emit_parallel_adder_tree!(gates, wa, pp, W; reuse_pool=Int[]) -> Vector{Int}

Sun-Borissov 2026 §II.D — parallel adder tree producing `xy` from the
partial products `pp` (a vector of `W` `W`-wire registers, each carrying
`α^{(0,i)} = y_i · x`).

At level `d`, computes `α^{(d,r)} = α^{(d-1,2r)} + 2^{2^{d-1}} · α^{(d-1,2r+1)}`.
The root after `⌈log₂ W⌉` levels is the (2W)-bit product.

**This is A2 — forward-only.** Adder tree computes the sum but does NOT
uncompute intermediate partial sums. The `pp` input registers and every
level's intermediate output registers remain dirty after this function
returns. A3 will add uncompute-in-flight.

Implementation uses proposer A's "Strategy α" consensus
(`docs/design/parallel_adder_tree_consensus.md`): black-box
`lower_add_qcla!` on zero-padded operands, one adder per pair, odd
child bubbled up unchanged.

Return value: exactly `2W` wires, result's LSB at index 1.
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

    for d in 1:D
        shift = 1 << (d - 1)
        n = length(current)
        n >= 2 || break

        # Adder takes two current_w-bit operands with the right shifted by `shift`.
        # Padded-operand width = current_w + shift. QCLA returns one extra bit
        # for carry-out — we keep all output bits so next level has the full
        # paper-bound width.
        pad_w = current_w + shift
        next_w = pad_w + 1
        next_level = Vector{Vector{Int}}()

        r = 0
        while 2r + 2 <= n
            left  = current[2r + 1]
            right = current[2r + 2]

            left_pad = allocate!(wa, pad_w)
            for k in 1:current_w
                push!(gates, CNOTGate(left[k], left_pad[k]))
            end

            right_pad = allocate!(wa, pad_w)
            for k in 1:current_w
                push!(gates, CNOTGate(right[k], right_pad[k + shift]))
            end

            sum_result = lower_add_qcla!(gates, wa, left_pad, right_pad, pad_w)
            push!(next_level, sum_result)  # next_w = pad_w + 1 wires
            r += 1
        end

        # Odd child bubble-up: unchanged width.
        if 2r + 1 == n
            # Extend the leftover operand to the new width by CNOT-copying into
            # a fresh pad. This keeps the invariant that every entry at the
            # current level has the same width.
            leftover = current[n]
            padded = allocate!(wa, next_w)
            for k in 1:current_w
                push!(gates, CNOTGate(leftover[k], padded[k]))
            end
            push!(next_level, padded)
        end

        current = next_level
        current_w = next_w
    end

    length(current) == 1 ||
        error("emit_parallel_adder_tree!: expected 1 root after $D levels, got $(length(current))")
    root = current[1]

    # Result width is >= 2W; truncate to exactly 2W. The top bits above 2W are
    # guaranteed zero by the paper's Claim 2 (max xy < 2^{2W}). Truncation
    # leaks zero-valued wires that the outer Bennett wrap will zero anyway.
    if length(root) < 2W
        extras = allocate!(wa, 2W - length(root))
        return vcat(root, extras)
    end
    return root[1:2W]
end
