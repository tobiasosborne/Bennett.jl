"""
Quantum Carry-Lookahead Adder (out-of-place).

From Draper, Kutin, Rains, Svore 2004, §4.1
(arXiv:quant-ph/0406142; `docs/literature/arithmetic/draper-kutin-rains-svore-2004.pdf`).

Computes `Z = a + b` producing a `W+1`-bit result. Low `W` bits are
`(a + b) mod 2^W`; top bit is the carry-out. `a` and `b` are unchanged on
exit. All internal ancillae return to zero — the primitive is
self-contained and correct regardless of outer Bennett wrap.

Cost formulas (W ≥ 4):
- Toffoli: `5W − 3·w(W) − 3·⌊log₂ W⌋ − 1`
- CNOT:    `3W − 1`
- Ancilla: `W − w(W) − ⌊log₂ W⌋`
- Total depth: `⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 7`
- Toffoli-depth: `⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 4`

QCLA has MORE Toffolis than ripple-carry `lower_add!` at every width (ripple
is 2(W-1) Toffolis). Its win is **depth**: QCLA is `O(log W)` while ripple
is `O(W)`. Use QCLA when Toffoli-depth dominates the caller's cost model;
use `lower_add!` or `lower_add_cuccaro!` when gate count or ancilla count
matters more.

Phases emitted strictly in paper's canonical §4.1 order:
  1. init G: `Z[k+1] ⊕= a[k] · b[k]` (W Toffolis)
  2. init P: `b[k] ⊕= a[k]` for `k = 2..W` (W-1 CNOTs)
  3. carry tree (§3): P-rounds, G-rounds, C-rounds, P⁻¹-rounds
  4. form s:  `Z[k] ⊕= b[k]` for `k = 1..W` (W CNOTs)
  5. restore: `CNOT(a[1], Z[1])`, `CNOT(a[k], b[k])` for k ≥ 2 (W CNOTs)

See `docs/design/qcla_consensus.md` for the full design rationale.
"""
function lower_add_qcla!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                         a::Vector{Int}, b::Vector{Int}, W::Int)
    W >= 1 || error("lower_add_qcla!: W must be >= 1, got $W")
    length(a) == W || error("lower_add_qcla!: |a|=$(length(a)) != W=$W")
    length(b) == W || error("lower_add_qcla!: |b|=$(length(b)) != W=$W")

    T = W >= 2 ? floor(Int, log2(W)) : 0      # highest P level used = T - 1
    popW = count_ones(W)
    n_anc = W >= 4 ? W - popW - T : 0         # Xflat empty at small W

    Z = allocate!(wa, W + 1)
    Xflat = n_anc > 0 ? allocate!(wa, n_anc) : Int[]

    p_offsets = _qcla_level_offsets(W, T)     # 0-based block starts per level
    Ptm = (t, m) -> Xflat[p_offsets[t] + m]

    # Phase 1: init G. Z[k+1] = a[k] AND b[k].
    for k in 1:W
        push!(gates, ToffoliGate(a[k], b[k], Z[k + 1]))
    end

    # Phase 2: init P. b[k] becomes p[k-1, k] for k >= 2. b[1] untouched.
    for k in 2:W
        push!(gates, CNOTGate(a[k], b[k]))
    end

    # Phase 3a: P-rounds. P_t[m] = P_{t-1}[2m] AND P_{t-1}[2m+1].
    # P_0[k] aliases b[k+1]. P_t[m] for t>=1 lives at Ptm(t, m).
    for t in 1:(T - 1)
        for m in 1:((W >> t) - 1)
            c1 = t == 1 ? b[2m + 1] : Ptm(t - 1, 2m)
            c2 = t == 1 ? b[2m + 2] : Ptm(t - 1, 2m + 1)
            push!(gates, ToffoliGate(c1, c2, Ptm(t, m)))
        end
    end

    # Phase 3b: G-rounds. G[2^t·m + 2^t] XOR= G[2^t·m + 2^(t-1)] AND P_{t-1}[2m+1].
    # G[j] aliases Z[j+1].
    for t in 1:T
        for m in 0:((W >> t) - 1)
            g_tgt  = Z[(m << t) + (1 << t) + 1]
            g_ctrl = Z[(m << t) + (1 << (t - 1)) + 1]
            p_ctrl = t == 1 ? b[2m + 2] : Ptm(t - 1, 2m + 1)
            push!(gates, ToffoliGate(g_ctrl, p_ctrl, g_tgt))
        end
    end

    # Phase 3c: C-rounds. G[2^t·m + 2^(t-1)] XOR= G[2^t·m] AND P_{t-1}[2m].
    # Iterate t from T_C down to 1. For W <= 2, T_C <= 0 so loop is empty.
    T_C = W >= 3 ? floor(Int, log2((2 * W) ÷ 3)) : 0
    for t in T_C:-1:1
        m_max = (W - (1 << (t - 1))) >> t
        for m in 1:m_max
            g_tgt  = Z[(m << t) + (1 << (t - 1)) + 1]
            g_ctrl = Z[(m << t) + 1]
            p_ctrl = t == 1 ? b[2m + 1] : Ptm(t - 1, 2m)
            push!(gates, ToffoliGate(g_ctrl, p_ctrl, g_tgt))
        end
    end

    # Phase 3d: P^{-1}-rounds. Replay 3a in reverse order to zero Xflat.
    for t in (T - 1):-1:1
        for m in ((W >> t) - 1):-1:1
            c1 = t == 1 ? b[2m + 1] : Ptm(t - 1, 2m)
            c2 = t == 1 ? b[2m + 2] : Ptm(t - 1, 2m + 1)
            push!(gates, ToffoliGate(c1, c2, Ptm(t, m)))
        end
    end

    # Phase 4: form s. Z[k] XOR= b[k] for k = 1..W.
    for k in 1:W
        push!(gates, CNOTGate(b[k], Z[k]))
    end

    # Phase 5: restore b, finalize s_0.
    push!(gates, CNOTGate(a[1], Z[1]))
    for k in 2:W
        push!(gates, CNOTGate(a[k], b[k]))
    end

    return Z
end

"""
Compute the 0-based start offsets of each P_t block inside Xflat. For
t = 1..T-1, block length is `⌊W/2^t⌋ - 1`. Returned vector has length
`max(T, 1)`; entries at t = 1..T-1 are meaningful.
"""
function _qcla_level_offsets(W::Int, T::Int)
    offs = zeros(Int, max(T, 1))
    acc = 0
    for t in 1:(T - 1)
        offs[t] = acc
        acc += (W >> t) - 1
    end
    return offs
end
