using Test
using Random
using Bennett
using Bennett: ReversibleGate, NOTGate, CNOTGate, ToffoliGate, ReversibleCircuit

# Bennett-u3b2: `toffoli_depth` used to skip NOT/CNOT gates entirely
# (`gate isa ToffoliGate || continue`), so a dependency carried from one
# Toffoli to the next through a CNOT was dropped and the two Toffolis were
# counted as parallel. The fix propagates per-wire depth through every gate
# and increments only on Toffolis.

# Metrics-only circuit: every wire is an ancilla (satisfies the U58 partition).
_mk(n::Int, gates) = ReversibleCircuit(n, Vector{ReversibleGate}(gates),
    Int[], Int[], collect(1:n), Int[], Int[])

_wires(g::NOTGate)     = (g.target,)
_wires(g::CNOTGate)    = (g.control, g.target)
_wires(g::ToffoliGate) = (g.control1, g.control2, g.target)

# Independent brute-force reference: longest Toffoli-weighted path through
# the gate DAG in which gate j depends on every earlier gate i that touches
# a common wire (all pairs, not just the last writer). O(n_gates^2).
function _ref_toffoli_depth(gates)
    n = length(gates)
    best = zeros(Int, n)   # max Toffoli count on a path ending at gate j
    for j in 1:n
        wj = _wires(gates[j])
        acc = 0
        for i in 1:j-1
            isempty(intersect(_wires(gates[i]), wj)) && continue
            acc = max(acc, best[i])
        end
        best[j] = acc + (gates[j] isa ToffoliGate ? 1 : 0)
    end
    return n == 0 ? 0 : maximum(best)
end

@testset "Bennett-u3b2: toffoli_depth propagates through CNOT/NOT" begin
    @testset "bead witness: Toffoli → CNOT → Toffoli" begin
        gs = ReversibleGate[ToffoliGate(1,2,3), CNOTGate(3,4), ToffoliGate(4,5,6)]
        c = _mk(6, gs)
        @test toffoli_depth(c) == 2
        @test t_depth(c) == 2
        @test t_depth(c; decomp=:nc_7t) == 6
        @test depth(c) == 3
        @test _ref_toffoli_depth(gs) == 2
    end

    @testset "hand-built shapes" begin
        # Dependency carried through a CNOT chain and a NOT.
        gs = ReversibleGate[ToffoliGate(1,2,3), CNOTGate(3,4), NOTGate(4),
                            CNOTGate(4,5), ToffoliGate(5,6,7)]
        @test toffoli_depth(_mk(7, gs)) == 2
        # CNOT whose *target* is the first Toffoli's output: the control wire
        # is scheduled after the CNOT, so the next Toffoli on that wire waits.
        gs = ReversibleGate[ToffoliGate(1,2,3), CNOTGate(4,3), ToffoliGate(4,5,6)]
        @test toffoli_depth(_mk(6, gs)) == 2
        # Three Toffolis chained only through CNOTs → 3.
        gs = ReversibleGate[ToffoliGate(1,2,3), CNOTGate(3,4), ToffoliGate(4,5,6),
                            CNOTGate(6,7), ToffoliGate(7,8,9)]
        @test toffoli_depth(_mk(9, gs)) == 3
        # CNOT on unrelated wires does not link two disjoint Toffolis → 1.
        gs = ReversibleGate[ToffoliGate(1,2,3), CNOTGate(7,8), ToffoliGate(4,5,6)]
        @test toffoli_depth(_mk(8, gs)) == 1
        # CNOTs alone never add Toffoli depth.
        gs = ReversibleGate[CNOTGate(1,2), CNOTGate(2,3), NOTGate(3)]
        @test toffoli_depth(_mk(3, gs)) == 0
    end

    @testset "random circuits agree with brute-force reference" begin
        rng = MersenneTwister(0x75b2)
        for _ in 1:500
            n = rand(rng, 3:8)
            gs = ReversibleGate[]
            for _ in 1:rand(rng, 0:30)
                k = rand(rng, 1:3)
                ws = randperm(rng, n)[1:k]
                push!(gs, k == 1 ? NOTGate(ws[1]) :
                          k == 2 ? CNOTGate(ws[1], ws[2]) :
                                   ToffoliGate(ws[1], ws[2], ws[3]))
            end
            c = _mk(n, gs)
            @test toffoli_depth(c) == _ref_toffoli_depth(gs)
            @test t_depth(c; decomp=:nc_7t) == 3 * _ref_toffoli_depth(gs)
        end
    end

    @testset "compiled circuits agree with brute-force reference" begin
        for (f, T) in ((x -> x + Int8(1), Tuple{Int8}), (x -> x * x, Tuple{Int8}),
                       ((x, y) -> x * y + x, Tuple{Int8,Int8}),
                       (x -> x < Int8(0) ? -x : x, Tuple{Int8}))
            c = reversible_compile(f, T; add=:ripple)
            @test verify_reversibility(c)
            @test toffoli_depth(c) == _ref_toffoli_depth(c.gates)
        end
        # Pin: the branchy abs from docs/src/tutorials/control_flow_and_loops.md
        # was reported as 16 by the CNOT-skipping metric.
        c = reversible_compile(x -> x < Int8(0) ? -x : x, Int8)
        @test toffoli_depth(c) == 30
    end
end
