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

From Cuccaro et al. 2004 (arXiv:quant-ph/0410184), Figure 5, with the
§3.5 high-bit optimisation applied (Bennett-gsxe): the Toffoli at the
W-1 boundary that would compute c_W into the high carry wire is
dropped, the matching Phase-3 uncompute Toffoli is dropped, and ONE
new Toffoli is injected into Phase 2 that XORs the same product
directly into b[W]. Net −1 Toffoli at every W ≥ 2.

Uses MAJ (majority) gates rippling up and UMA (unmajority-and-add)
gates rippling back down. Result s_i overwrites b_i in place.

Gate counts (this implementation, mod 2^W output — no carry-out
emitted; pinned by `test_op6a_cuccaro_gate_count.jl`):
  Toffoli: 2W − 3   (was 2W − 2 pre-Bennett-gsxe)
  CNOT:    4W − 2
  NOT:     0
  Total:   6W − 5   (was 6W − 4 pre-Bennett-gsxe)
  Depth:   2W + O(1)
Only 1 ancilla qubit (X) vs W-1 in traditional ripple-carry.
The "2n NOT" advertised in the original paper appears in the
carry-out variant; this mod-2^W form omits both.

# Wire-state contract (Bennett-gboa / U139)

**Pre:** `a[1:W]` and `b[1:W]` hold the SSA operand bits. The internal
ancilla `X[1]` is freshly allocated (zero by `WireAllocator` invariant).

**Post (by construction; pinned by `test_gboa_dirty_bit_hygiene.jl`):**
- `a[1:W]` unchanged (Phase-3 UMA gates restore each `a[i]`).
- `b[1:W]` holds `(a + b) mod 2^W`.
- `X[1]` returned to `0` by Phase-3's last UMA pair, restoring it to
  the ancilla-zero invariant. No outer Bennett-reverse uncomputation
  is needed for X — the function self-cleans.

**Caller responsibility:** if the caller's liveness analysis decides
to free `b` mid-circuit, it MUST first uncompute the gates emitted
here (or wrap the whole call in Bennett's reverse pass). The function
does NOT track `b`'s dirty-bit lifetime — `b` is overwritten and
holds the result; the original `b` value is gone.

Input: a[1:W], b[1:W] (a unchanged, b overwritten with a+b mod 2^W).
"""
function lower_add_cuccaro!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                            a::Vector{Int}, b::Vector{Int}, W::Int)
    W <= 1 && return lower_add!(gates, wa, a, b, W)  # fallback for 1-bit

    # Allocate single ancilla X (initial carry c_0 = 0)
    X = allocate!(wa, 1)
    # 6W - 5 gates after the Bennett-gsxe §3.5 optimisation (was 6W - 4).
    sizehint!(gates, length(gates) + 6 * W)

    # MAJ gate: CNOT(c,b); CNOT(c,a); Toffoli(a,b,c)
    # Transforms (c_i, b_i, a_i) → (c_i ⊕ a_i, b_i ⊕ a_i, c_{i+1})
    # where c_{i+1} = MAJ(a_i, b_i, c_i) written into position of a_i.
    #
    # Bennett-gsxe / U_: §3.5 trick — the Toffoli that would write c_W
    # into a[W-1] (or a[1] when W=2) and its matching Phase-3 uncompute
    # are both omitted; one new Toffoli in Phase 2 XORs the same MAJ
    # product directly into b[W]. The wires a[W-1] (resp. a[1]) thus
    # retain a_{W-1} (resp. a_1) across the boundary instead of briefly
    # holding c_W.

    if W == 2
        # Phase 1 first MAJ — Toffoli dropped (it would write c_2 into a[1])
        push!(gates, CNOTGate(a[1], b[1]))
        push!(gates, CNOTGate(a[1], X[1]))
        # Phase 2 — inject Toffoli with controls (X[1], b[1])
        push!(gates, CNOTGate(a[W], b[W]))
        push!(gates, CNOTGate(a[W-1], b[W]))
        push!(gates, ToffoliGate(X[1], b[1], b[W]))
        # Phase 3 last UMA — matching Toffoli dropped
        push!(gates, CNOTGate(a[1], X[1]))
        push!(gates, CNOTGate(X[1], b[1]))
        return b
    end

    # W ≥ 3 path.

    # Phase 1: MAJ ripple up (compute carries into a[] wires)
    # First MAJ: inputs (X[1], b[1], a[1])
    push!(gates, CNOTGate(a[1], b[1]))
    push!(gates, CNOTGate(a[1], X[1]))
    push!(gates, ToffoliGate(X[1], b[1], a[1]))

    # Middle MAJs i = 2..W-2 (full)
    for i in 2:(W-2)
        push!(gates, CNOTGate(a[i], b[i]))
        push!(gates, CNOTGate(a[i], a[i-1]))
        push!(gates, ToffoliGate(a[i-1], b[i], a[i]))
    end

    # Phase 1 last middle MAJ at i = W-1 — Toffoli omitted (§3.5).
    # Post-state: a[W-2] = c_{W-1} ⊕ a_{W-1}; b[W-1] = b_{W-1} ⊕ a_{W-1};
    # a[W-1] still holds a_{W-1} (NOT c_W).
    push!(gates, CNOTGate(a[W-1], b[W-1]))
    push!(gates, CNOTGate(a[W-1], a[W-2]))

    # Phase 2: compute s_W into b[W] using the moved Toffoli.
    # s_W = b_W ⊕ a_W ⊕ c_W. The two CNOTs contribute b_W ⊕ a_W ⊕ a_{W-1};
    # the Toffoli adds (a[W-2]·b[W-1]) = MAJ(a_{W-1}, b_{W-1}, c_{W-1}) ⊕ a_{W-1}
    # which combines with the spurious a_{W-1} term to leave c_W.
    push!(gates, CNOTGate(a[W], b[W]))
    push!(gates, CNOTGate(a[W-1], b[W]))
    push!(gates, ToffoliGate(a[W-2], b[W-1], b[W]))

    # Phase 3 first UMA at i = W-1 — Toffoli omitted (§3.5 match).
    # CNOT(a[W-1], a[W-2]) restores a[W-2] = c_{W-1}; the next CNOT
    # computes s_{W-1} into b[W-1].
    push!(gates, CNOTGate(a[W-1], a[W-2]))
    push!(gates, CNOTGate(a[W-2], b[W-1]))

    # Phase 3 middle UMAs i = W-2..2 (full)
    for i in (W-2):-1:2
        push!(gates, ToffoliGate(a[i-1], b[i], a[i]))
        push!(gates, CNOTGate(a[i], a[i-1]))
        push!(gates, CNOTGate(a[i-1], b[i]))
    end

    # Last UMA: (X[1], b[1], a[1]) — full
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
