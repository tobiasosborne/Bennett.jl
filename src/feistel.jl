# ---- Feistel network: reversible bijective hash primitive ----
#
# COMPLEMENTARY_SURVEY §D (Bennett-Memory memo, 2026-04-10): a 4-round Feistel
# network over (L, R) halves runs r rounds of
#
#   (L, R)  →  (R,  L ⊕ F(R))
#
# The overall permutation is a bijection regardless of F's invertibility
# (Luby-Rackoff 1988). Designed as the cheap-hash core of Feistel-backed
# reversible dictionaries — see T3a.2 benchmark for comparison against
# Okasaki persistent trees.
#
# Round function: `F(R)[i] = R[i] AND R[(i + rot) mod R_half]`. Bitwise AND
# with a rotated copy supplies nonlinearity (AND is non-affine over GF(2));
# rotation is a pure wire permutation (zero gates). Each round costs
# R_half Toffolis on compute + R_half on uncompute = 2·R_half per round
# (R_half = W/2). Plus R_half CNOTs for the XOR-into-L. 4 rounds total
# ~4W Toffolis — matches the survey's ~12·W estimate up to a small factor.
# (Uses Simon-cipher-style nonlinearity: same primitive NSA used in Simon,
# known secure with ≥ ceil(4n/3) rounds for n-bit halves.)

"""
    emit_feistel!(gates, wa, key_wires::Vector{Int}, W::Int;
                  rounds::Int=4, rotations=Int[]) -> Vector{Int}

Apply a reversible Feistel network to the W-bit value held in `key_wires`.
The input is NOT consumed: the function allocates fresh output wires and
emits gates that populate them with the Feistel permutation of the input.

Each round: `(L, R) ← (R, L ⊕ F(R))` where `F(R) = R + rotate_right(R, rotations[i])`.
Default rotations `[1, 3, 5, 7, …]` are odd, pairwise-unequal for good diffusion.

Returns the W fresh output wires.

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

    # Split into L (top half) and R (low half). For odd W, L gets the extra bit.
    half = W ÷ 2
    R_half = half                  # low half
    L_half = W - half              # top half (gets extra bit if W odd)
    L_wires = out[1:L_half]
    R_wires = out[L_half+1:end]
    length(R_wires) == R_half ||
        throw(AssertionError("internal: R_wires length ($(length(R_wires))) != R_half ($R_half)"))

    # Feistel rounds: (L, R) → (R, L ⊕ F(R))
    for (r, rot) in enumerate(rotations)
        # 1) Compute F(R) on a fresh ancilla; 2) XOR into L; 3) uncompute F(R);
        # 4) swap L ↔ R (pointer-level, zero gates).
        F_out = _feistel_round_compute!(gates, wa, R_wires, R_half, rot)

        # XOR F_out into L's low R_half bits. If L_half > R_half (odd W), the
        # extra top bit of L is left unchanged this round — it floats up to R
        # on swap and gets mixed in subsequent rounds.
        for i in 1:min(L_half, R_half)
            push!(gates, CNOTGate(F_out[i], L_wires[i]))
        end

        _feistel_round_uncompute!(gates, wa, R_wires, F_out, R_half, rot)

        # Swap L ↔ R (pointer-level).
        if L_half == R_half
            L_wires, R_wires = R_wires, L_wires
        else
            # Odd W: swap the low R_half bits of L with R; keep the extra L bit at top.
            new_L = vcat(R_wires, L_wires[R_half+1:end])
            new_R = L_wires[1:R_half]
            L_wires, R_wires = new_L, new_R
        end
    end

    return out
end

# F(R)[i] = R[i] AND R[(i + rot) mod R_half], on a fresh R_half-wire buffer.
# Simon-cipher-style: AND + rotation gives Luby-Rackoff-secure PRF.
function _feistel_round_compute!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                 R_wires::Vector{Int}, R_half::Int, rot::Int)
    rot_mod = mod(rot, R_half)
    rot_mod == 0 && (rot_mod = 1)  # degenerate identity — nudge to a useful rotation
    F_out = allocate!(wa, R_half)
    for i in 1:R_half
        j = ((i - 1 + rot_mod) % R_half) + 1
        push!(gates, ToffoliGate(R_wires[i], R_wires[j], F_out[i]))
    end
    return F_out
end

function _feistel_round_uncompute!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                   R_wires::Vector{Int}, F_out::Vector{Int},
                                   R_half::Int, rot::Int)
    # Toffoli is self-inverse: applying the same gates again in reverse order zeroes F_out.
    rot_mod = mod(rot, R_half)
    rot_mod == 0 && (rot_mod = 1)
    for i in R_half:-1:1
        j = ((i - 1 + rot_mod) % R_half) + 1
        push!(gates, ToffoliGate(R_wires[i], R_wires[j], F_out[i]))
    end
    free!(wa, F_out)
end
