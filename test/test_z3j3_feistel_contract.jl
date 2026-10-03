using Test
using Bennett
using Bennett: emit_feistel!, WireAllocator, allocate!, wire_count,
               ReversibleGate, LoweringResult, bennett, verify_reversibility,
               simulate
using Random

# Bennett-z3j3 — `emit_feistel!` must compute the permutation its docstring
# states, checked input-by-input against an independent integer reference.
#
# Pre-fix: (1) after an odd number of rounds the output wires came back in
# physical order, not the logical (L, R) order, so W=8 rounds=1 mapped 0x12
# to 0x12 instead of 0x21; (2) for odd W the extra bit of L was never mixed
# (W=9: bit 4 was the identity for every input at every round count).
# The old test_feistel.jl only checked "outputs distinct" and "one flipped
# input bit changes the output", which any bijection — including the
# identity — satisfies.

_z3j3_mask(n) = (UInt64(1) << n) - 1

# Integer reference for the documented contract. x packs L in the low
# ceil(W/2) bits and R in the remaining high bits. Round r with rotation k:
#   F(R)[i] = R[i mod |R|] & R[(i + k') mod |R|]   for i in 0:|L|-1,
#   k' = mod(k, |R|), bumped to 1 when it is 0;
#   (L, R) <- (R, L xor F(R))      (widths swap when W is odd).
# Output packs the final L in the low |L| bits and R above it.
function _z3j3_ref(x::Integer, W::Int, rotations::Vector{Int})
    nL = cld(W, 2); nR = W - nL
    L = UInt64(x) & _z3j3_mask(nL)
    R = (UInt64(x) >> nL) & _z3j3_mask(nR)
    for k in rotations
        km = mod(k, nR); km == 0 && (km = 1)
        F = UInt64(0)
        for i in 0:nL-1
            F |= (((R >> (i % nR)) & (R >> ((i + km) % nR))) & 1) << i
        end
        L, R, nL, nR = R, L ⊻ F, nR, nL
    end
    return L | (R << nL)
end
_z3j3_ref(x, W, rounds::Int) = _z3j3_ref(x, W, Int[2i - 1 for i in 1:rounds])

function _z3j3_circuit(W::Int; rounds::Int=4, rotations::Vector{Int}=Int[])
    wa = WireAllocator()
    gates = ReversibleGate[]
    key = allocate!(wa, W)
    out = emit_feistel!(gates, wa, key, W; rounds, rotations)
    return bennett(LoweringResult(gates, wire_count(wa), key, out, [W], [W]))
end

# Output of the circuit for input x, as a W-bit unsigned value.
_z3j3_run(c, x, W) = (simulate(c, UInt64(x)) % UInt64) & _z3j3_mask(W)

# Exhaustive circuit table (index x+1 -> output), mismatches vs reference.
function _z3j3_table(c, W, rot)
    T = Vector{UInt64}(undef, 1 << W)
    bad = Tuple{Int,UInt64,UInt64}[]
    for x in 0:(1 << W) - 1
        T[x + 1] = _z3j3_run(c, x, W)
        r = _z3j3_ref(x, W, rot)
        T[x + 1] == r || length(bad) >= 5 || push!(bad, (x, T[x + 1], r))
    end
    isempty(bad) || @info "Bennett-z3j3 mismatches (x, circuit, reference)" W bad
    return T, bad
end

# Mean output Hamming distance per single-bit input flip, and the fraction
# of (input bit, output bit) pairs where some input makes the output bit
# depend on the input bit.
function _z3j3_avalanche(T, W)
    hd = 0; dep = falses(W, W)
    for x in 0:(1 << W) - 1, k in 0:W-1
        d = T[x + 1] ⊻ T[(x ⊻ (1 << k)) + 1]
        hd += count_ones(d)
        for j in 0:W-1
            ((d >> j) & 1) == 1 && (dep[k + 1, j + 1] = true)
        end
    end
    return hd / ((1 << W) * W), count(dep) / W^2
end

@testset "Bennett-z3j3 emit_feistel! contract" begin

    @testset "bead witness: W=8 rounds=1, 0x12 -> 0x21" begin
        c = _z3j3_circuit(8; rounds=1)
        @test verify_reversibility(c)
        @test _z3j3_run(c, 0x12, 8) == 0x21
    end

    @testset "W=$W exhaustive vs reference, rounds=$r" for W in (2, 3, 8, 9), r in 1:5
        c = _z3j3_circuit(W; rounds=r)
        @test verify_reversibility(c)
        T, bad = _z3j3_table(c, W, Int[2i - 1 for i in 1:r])
        @test isempty(bad)
        @test length(unique(T)) == 1 << W            # bijection on all inputs
    end

    @testset "W=9: the extra bit is mixed (bead witness)" begin
        for r in (1, 4)
            c = _z3j3_circuit(9; rounds=r)
            @test count(x -> ((_z3j3_run(c, x, 9) ⊻ x) >> 4) & 1 == 1, 0:511) > 0
        end
    end

    @testset "custom rotations match the reference" begin
        rot = [2, 5, 0, 3]                           # 0 exercises the bump-to-1 rule
        c = _z3j3_circuit(8; rounds=4, rotations=rot)
        @test verify_reversibility(c)
        _, bad = _z3j3_table(c, 8, rot)
        @test isempty(bad)
    end

    @testset "W=16 rounds=4: exhaustive bijection, reference, avalanche" begin
        c = _z3j3_circuit(16; rounds=4)
        @test verify_reversibility(c)
        T, bad = _z3j3_table(c, 16, 4)
        @test isempty(bad)
        @test length(unique(T)) == 1 << 16
        hd, depfrac = _z3j3_avalanche(T, 16)
        @info "Bennett-z3j3 W=16 rounds=4 avalanche" hd depfrac
        # Identity: hd 1.0, depfrac 1/16. One round: 1.5, 1/8. Two rounds:
        # 2.25. Measured 4 rounds: 3.13, 0.72. Not near the ideal 8.0 — this
        # round function is a cheap mixer, not a PRF.
        @test hd > 2.75
        @test depfrac > 0.6
    end

    @testset "W=16 rounds=8: every output bit depends on every input bit" begin
        c = _z3j3_circuit(16; rounds=8)
        @test verify_reversibility(c)
        T, bad = _z3j3_table(c, 16, 8)
        @test isempty(bad)
        hd, depfrac = _z3j3_avalanche(T, 16)
        @test depfrac == 1.0
        @test hd > 4.0                               # measured 4.35
    end

    @testset "W=$W rounds=$r sampled vs reference" for W in (32, 33), r in (3, 4)
        c = _z3j3_circuit(W; rounds=r)
        @test verify_reversibility(c)
        rng = MersenneTwister(0x3a3)
        xs = vcat(UInt64[0, 1, _z3j3_mask(W), UInt64(0x12345678) & _z3j3_mask(W)],
                  [rand(rng, UInt64) & _z3j3_mask(W) for _ in 1:300])
        bad = [(x, _z3j3_run(c, x, W), _z3j3_ref(x, W, r)) for x in xs
               if _z3j3_run(c, x, W) != _z3j3_ref(x, W, r)]
        isempty(bad) || @info "Bennett-z3j3 sampled mismatches" W r first(bad, 5)
        @test isempty(bad)
    end
end
