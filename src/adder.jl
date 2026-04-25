"""Ripple-carry full adder: result = a + b  (mod 2^W)."""
function lower_add!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                    a::Vector{Int}, b::Vector{Int}, W::Int)
    result = allocate!(wa, W)
    carry  = allocate!(wa, W)
    # Bennett-5kio / U109: 3 CNOTs per i + 2 Toffolis for i<W = 5W - 2 gates.
    sizehint!(gates, length(gates) + 5 * W)
    for i in 1:W
        push!(gates, CNOTGate(a[i], result[i]))
        push!(gates, CNOTGate(b[i], result[i]))
        if i < W
            push!(gates, ToffoliGate(a[i], b[i], carry[i + 1]))
            push!(gates, ToffoliGate(result[i], carry[i], carry[i + 1]))
        end
        push!(gates, CNOTGate(carry[i], result[i]))
    end
    return result
end

"""
Cuccaro in-place adder: (a, b, 0) → (a, a+b, 0) using only 1 ancilla.

From Cuccaro et al. 2004 (arXiv:quant-ph/0410184), Figure 5.
Uses MAJ (majority) gates rippling up and UMA (unmajority-and-add)
gates rippling back down. Result s_i overwrites b_i in place.

Gate counts (this implementation, mod 2^W output — no carry-out
emitted; Bennett-op6a / U140 measurement, 2026-04-26):
  Toffoli: 2W − 2
  CNOT:    4W − 2
  NOT:     0
  Total:   6W − 4
  Depth:   2W + O(1)
Only 1 ancilla qubit (X) vs W-1 in traditional ripple-carry.
The "2n NOT" advertised in the original paper appears in the
carry-out variant; this mod-2^W form omits both.

Input: a[1:W], b[1:W] (a unchanged, b overwritten with a+b mod 2^W).
"""
function lower_add_cuccaro!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                            a::Vector{Int}, b::Vector{Int}, W::Int)
    W <= 1 && return lower_add!(gates, wa, a, b, W)  # fallback for 1-bit

    # Allocate single ancilla X (initial carry c_0 = 0)
    X = allocate!(wa, 1)
    # Bennett-5kio / U109: phase-1 MAJ ripple = 3 + 3(W-2) gates; high-bit
    # CNOT pair = 2; phase-3 UMA ripple = 3(W-2) + 3 gates. Total ≈ 6W - 4.
    sizehint!(gates, length(gates) + 6 * W)

    # MAJ gate: CNOT(c,b); CNOT(c,a); Toffoli(a,b,c)
    # Transforms (c_i, b_i, a_i) → (c_i ⊕ a_i, b_i ⊕ a_i, c_{i+1})
    # where c_{i+1} = MAJ(a_i, b_i, c_i) written into position of a_i

    # Phase 1: MAJ ripple up (compute carries into a[] wires)
    # First MAJ: inputs (X[1], b[1], a[1])
    push!(gates, CNOTGate(a[1], b[1]))
    push!(gates, CNOTGate(a[1], X[1]))
    push!(gates, ToffoliGate(X[1], b[1], a[1]))

    # Middle MAJs: inputs (a[i-1], b[i], a[i]) for i = 2..W-1
    for i in 2:(W-1)
        push!(gates, CNOTGate(a[i], b[i]))
        push!(gates, CNOTGate(a[i], a[i-1]))
        push!(gates, ToffoliGate(a[i-1], b[i], a[i]))
    end

    # Last carry: a[W-1] now holds c_W (the overflow carry)
    # For mod 2^W addition, we don't output c_W separately

    # Phase 2: Compute s_{W-1} (high sum bit)
    # s_{W-1} = a_{W-1} ⊕ b_{W-1} ⊕ c_{W-1}
    # At this point: a[W-1] = c_W, b[W-1] = b_{W-1} ⊕ a_{W-1} (from last MAJ's first CNOT? no...)
    # Actually for the last bit we just need CNOT + CNOT:
    push!(gates, CNOTGate(a[W], b[W]))     # b[W] = b_W ⊕ a_W
    push!(gates, CNOTGate(a[W-1], b[W]))   # b[W] = b_W ⊕ a_W ⊕ c_W = s_W

    # Phase 3: UMA ripple back down (compute sums, restore a[], clean carries)
    # UMA gate: Toffoli(a,b,c); CNOT(c,a); CNOT(a,b)
    # Transforms (c_i ⊕ a_i, b_i ⊕ a_i, c_{i+1}) → (c_i, s_i, a_i)

    for i in (W-1):-1:2
        push!(gates, ToffoliGate(a[i-1], b[i], a[i]))
        push!(gates, CNOTGate(a[i], a[i-1]))
        push!(gates, CNOTGate(a[i-1], b[i]))
    end

    # Last UMA: (X[1], b[1], a[1])
    push!(gates, ToffoliGate(X[1], b[1], a[1]))
    push!(gates, CNOTGate(a[1], X[1]))
    push!(gates, CNOTGate(X[1], b[1]))

    return b  # result is in b's wires
end

"""Subtraction via two's complement: result = a - b  (mod 2^W)."""
function lower_sub!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                    a::Vector{Int}, b::Vector{Int}, W::Int)
    not_b = allocate!(wa, W)
    # Bennett-5kio / U109: 2W gates for ~b; carry_in = 1 NOTGate; then
    # adder body 5W - 2 gates ⇒ ~7W total.
    sizehint!(gates, length(gates) + 7 * W + 1)
    for i in 1:W
        push!(gates, CNOTGate(b[i], not_b[i]))
        push!(gates, NOTGate(not_b[i]))
    end
    result = allocate!(wa, W)
    carry  = allocate!(wa, W)
    push!(gates, NOTGate(carry[1]))        # carry_in = 1
    for i in 1:W
        push!(gates, CNOTGate(a[i], result[i]))
        push!(gates, CNOTGate(not_b[i], result[i]))
        if i < W
            push!(gates, ToffoliGate(a[i], not_b[i], carry[i + 1]))
            push!(gates, ToffoliGate(result[i], carry[i], carry[i + 1]))
        end
        push!(gates, CNOTGate(carry[i], result[i]))
    end
    return result
end
