# ---- Feistel network: reversible bijective hash primitive ----
#
# COMPLEMENTARY_SURVEY §D (Bennett-Memory memo, 2026-04-10): a Feistel
# network over (L, R) halves runs r rounds of
#
#   (L, R)  →  (R,  L ⊕ F(R))
#
# Each round is a bijection regardless of F's invertibility (it is undone by
# (L, R) → (R ⊕ F(L), L)), so the whole network is a permutation of the
# W-bit key. Designed as the cheap-hash core of Feistel-backed reversible
# dictionaries — see T3a.2 benchmark for comparison against Okasaki
# persistent trees.
#
# Round function: `F(R)[i] = R[i mod |R|] AND R[(i + rot) mod |R|]`, one bit
# per bit of L. Bitwise AND with a rotated copy supplies nonlinearity (AND is
# non-affine over GF(2)); rotation is a pure wire permutation (zero gates).
# Each round costs |L| Toffolis on compute + |L| on uncompute, plus |L|
# CNOTs for the XOR-into-L; 4 rounds at even W are 4W Toffolis before the
# Bennett wrap. This is a cheap mixer, NOT a pseudorandom permutation: at
# W=16, 4 rounds flip ~3.1 of 16 output bits per flipped input bit and leave
# 28% of (input bit, output bit) pairs independent; 8 rounds reach full
# dependency (Bennett-z3j3, test/test_z3j3_feistel_contract.jl).

"""
    emit_feistel!(gates, wa, key_wires::Vector{Int}, W::Int;
                  rounds::Int=4, rotations=Int[]) -> Vector{Int}

Apply a reversible Feistel network to the W-bit value held in `key_wires`
(`key_wires[1]` is bit 0). The input is NOT consumed: the function allocates
fresh output wires, copies the key onto them and permutes the copy in place.
All round-function ancillae are returned to zero.

Bit layout: `L` is the low `cld(W, 2)` bits of the key, `R` the remaining
high `fld(W, 2)` bits. Round `r` with rotation `k = rotations[r]` computes

    F(R)[i] = R[i mod |R|] & R[(i + k′) mod |R|]   for i in 0:|L|-1,
    k′ = mod(k, |R|), replaced by 1 when it is 0
    (L, R) ← (R, L ⊻ F(R))

For odd W the halves differ by one bit and swap widths each round
(alternating unbalanced Feistel), so every key bit is mixed. The returned
wires hold the final logical `(L, R)` with `L` in the low bits, i.e. bit
`j` of the result is `out[j+1]`. Default `rotations` are `[1, 3, 5, 7, …]`.
For W ≤ 3 the one-bit half makes `F` linear (`R & R = R`).

Returns the W output wires.

# References
- COMPLEMENTARY_SURVEY.md §D (docs/literature/memory/)
- Luby, Rackoff (1988), "How to Construct Pseudorandom Permutations from
  Pseudorandom Functions", SIAM J. Comput. 17(2).
"""
function emit_feistel!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                       key_wires::Vector{Int}, W::Int;
                       rounds::Int=4,
                       rotations::Vector{Int}=Int[])
    length(key_wires) == W ||
        throw(DimensionMismatch("emit_feistel!: key_wires has $(length(key_wires)) wires, W=$W"))
    W >= 2 || throw(ArgumentError("emit_feistel!: W must be ≥ 2 (got $W)"))
    rounds >= 1 || throw(ArgumentError("emit_feistel!: rounds must be ≥ 1"))

    if isempty(rotations)
        rotations = Int[(2*i - 1) for i in 1:rounds]
    end
    length(rotations) == rounds ||
        throw(DimensionMismatch("emit_feistel!: rotations has $(length(rotations)) entries, expected $rounds"))

    # Copy input onto fresh output wires. Feistel runs on the copy; original is preserved.
    out = allocate!(wa, W)
    for i in 1:W
        push!(gates, CNOTGate(key_wires[i], out[i]))
    end

    # L = low cld(W, 2) bits, R = high fld(W, 2) bits.
    L_wires = out[1:cld(W, 2)]
    R_wires = out[cld(W, 2)+1:end]

    # Feistel rounds: (L, R) → (R, L ⊕ F(R))
    for rot in rotations
        # 1) Compute F(R) (|L| bits) on fresh ancillae; 2) XOR into L;
        # 3) uncompute F(R); 4) swap L ↔ R (pointer-level, zero gates —
        # for odd W the widths swap too).
        F_out = _feistel_round_compute!(gates, wa, R_wires, length(L_wires), rot)
        for i in eachindex(L_wires)
            push!(gates, CNOTGate(F_out[i], L_wires[i]))
        end
        _feistel_round_uncompute!(gates, wa, R_wires, F_out, rot)
        L_wires, R_wires = R_wires, L_wires
    end

    # Logical (L, R) order, not the physical `out` order (Bennett-z3j3: after
    # an odd round count, or at odd W, the two differ).
    return vcat(L_wires, R_wires)
end

# Index pairs (i, j) with F[i] = R[i] AND R[j], 1-based, for an n_out-bit F
# from an n_in-bit R: i ↦ R[(i-1) mod n_in], j = i rotated by `rot`.
function _feistel_round_pairs(n_in::Int, n_out::Int, rot::Int)
    rot_mod = mod(rot, n_in)
    rot_mod == 0 && (rot_mod = 1)  # degenerate identity — nudge to a useful rotation
    return [(((k - 1) % n_in) + 1, ((k - 1 + rot_mod) % n_in) + 1) for k in 1:n_out]
end

# F(R) on a fresh n_out-wire buffer (one Toffoli per bit).
function _feistel_round_compute!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                 R_wires::Vector{Int}, n_out::Int, rot::Int)
    F_out = allocate!(wa, n_out)
    for (k, (i, j)) in enumerate(_feistel_round_pairs(length(R_wires), n_out, rot))
        push!(gates, ToffoliGate(R_wires[i], R_wires[j], F_out[k]))
    end
    return F_out
end

function _feistel_round_uncompute!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                   R_wires::Vector{Int}, F_out::Vector{Int}, rot::Int)
    # Toffoli is self-inverse: applying the same gates again in reverse order zeroes F_out.
    pairs = _feistel_round_pairs(length(R_wires), length(F_out), rot)
    for k in length(F_out):-1:1
        i, j = pairs[k]
        push!(gates, ToffoliGate(R_wires[i], R_wires[j], F_out[k]))
    end
    free!(wa, F_out)
end
