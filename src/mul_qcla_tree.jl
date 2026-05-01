"""
    lower_mul_qcla_tree!(gates, wa, a, b, W) -> Vector{Int}

Sun-Borissov 2026 polylogarithmic-depth multiplier (arXiv:2604.09847).
Produces the state `|a>|b>|ab>|0>` where `|ab>` is the (2W)-bit product.
All intermediate ancillae return to zero — the primitive is self-reversing
(CLAUDE.md principle 13) and does not need an outer Bennett wrap.

Resource costs (Sun-Borissov Table III, asymptotic):
- Toffoli count: O(n²)
- Toffoli-depth: O(log²n)
- Ancilla: O(n²)

Assembly (Algorithm 3 of the paper, slightly rearranged because our
`emit_parallel_adder_tree!` is already self-cleaning):

1. `fast_copy x` — broadcast |x⟩ into n copies
2. broadcast each bit of y into n copies (y_bit_copies)
3. `partial_products` — compute α^{(0,i)} = y_i · x for all i
4. `parallel_adder_tree` — sum the partial products into the result register
5. uncompute step 3 (reverse Toffolis) — α^{(0,i)} back to zero
6. uncompute step 2 (reverse CNOTs) — y_bit_copies back to zero
7. uncompute step 1 (reverse CNOTs) — x_copies back to zero

End state: `a` and `b` unchanged; result register holds `ab`; everything
else back to zero.
"""
function lower_mul_qcla_tree!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                              a::Vector{Int}, b::Vector{Int}, W::Int)
    W >= 1 || throw(ArgumentError("lower_mul_qcla_tree!: W must be >= 1, got $W"))
    length(a) == W || throw(DimensionMismatch("lower_mul_qcla_tree!: |a|=$(length(a)) != W=$W"))
    length(b) == W || throw(DimensionMismatch("lower_mul_qcla_tree!: |b|=$(length(b)) != W=$W"))

    # Step 1: fast_copy x → W copies (including source).
    s1_start = length(gates) + 1
    x_copies = emit_fast_copy!(gates, wa, a, W, W)
    s1_end = length(gates)

    # Step 2: broadcast each bit of y into W copies (y_bit_copies[i] = y_i^⊗W).
    s2_start = length(gates) + 1
    y_bit_copies = Vector{Vector{Int}}()
    for i in 1:W
        yi_reg = allocate!(wa, W)
        for k in 1:W
            push!(gates, CNOTGate(b[i], yi_reg[k]))
        end
        push!(y_bit_copies, yi_reg)
    end
    s2_end = length(gates)

    # Step 3: partial_products → W partial products.
    s3_start = length(gates) + 1
    pp = emit_partial_products!(gates, wa, y_bit_copies, x_copies, W)
    s3_end = length(gates)

    # Step 4: parallel_adder_tree (self-cleaning internally — returns 2W-bit
    # result, leaves pp / x_copies / y_bit_copies intact).
    result = emit_parallel_adder_tree!(gates, wa, pp, W)

    # Step 5: uncompute partial_products (reverse Toffolis). Needs
    # x_copies and y_bit_copies intact.
    for i in s3_end:-1:s3_start
        push!(gates, gates[i])
    end

    # Step 6: uncompute y broadcast (reverse CNOTs). Needs b intact.
    for i in s2_end:-1:s2_start
        push!(gates, gates[i])
    end

    # Step 7: uncompute fast_copy x (reverse CNOTs). Needs a intact.
    for i in s1_end:-1:s1_start
        push!(gates, gates[i])
    end

    return result
end
