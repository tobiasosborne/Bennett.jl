# Bennett-2jny / U101 — ReversibleCircuit implements the standard
# collection protocols (length, iterate, eltype, getindex, first/lastindex)
# delegating to the underlying gate vector.

using Test
using Bennett

@testset "Bennett-2jny / U101 — ReversibleCircuit collection API" begin
    circuit = reversible_compile(x -> x + Int8(1), Int8)

    @testset "length" begin
        @test length(circuit) == length(circuit.gates)
        @test length(circuit) == 58  # canonical i8 x+1 baseline (CLAUDE.md §6)
    end

    @testset "iterate" begin
        # iterate the circuit; total count + types should match c.gates
        n_iter = 0
        for g in circuit
            @test g isa ReversibleGate
            n_iter += 1
        end
        @test n_iter == length(circuit.gates)
    end

    @testset "eltype" begin
        @test eltype(typeof(circuit)) === ReversibleGate
        @test eltype(circuit) === ReversibleGate
    end

    @testset "indexing" begin
        @test circuit[1] === circuit.gates[1]
        @test circuit[end] === circuit.gates[end]
        @test circuit[length(circuit)] === circuit.gates[end]
        @test firstindex(circuit) == firstindex(circuit.gates)
        @test lastindex(circuit) == lastindex(circuit.gates)
    end

    @testset "interop with collect / count / map" begin
        gs = collect(circuit)
        @test gs == circuit.gates  # same gates, in order
        @test count(g -> g isa ToffoliGate, circuit) == 12  # Toffoli baseline
        @test count(g -> g isa CNOTGate,    circuit) == 40
        @test count(g -> g isa NOTGate,     circuit) == 6
    end
end
