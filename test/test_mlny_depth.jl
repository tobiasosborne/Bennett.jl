# Bennett-mlny / U63 — `depth` exported / documented / never tested
#
# `depth(c::ReversibleCircuit)` returns the longest data-dependence chain
# counting NOT/CNOT/Toffoli (per-wire layer tracking).  Until this file
# landed it had a docstring and an export but zero @test coverage.
#
# Test shapes per the bead:
#   - empty circuit → 0
#   - sequential same-wire → N
#   - parallel disjoint → 1
#   - mixed interleaved → max-depth-along-chain (2)
# Plus a regression-shape check vs. the docstring example
# (`reversible_compile(x -> x + Int8(1), Int8) → depth == 19`).

using Test
using Bennett
using Bennett: NOTGate, CNOTGate, ToffoliGate, ReversibleGate, ReversibleCircuit

# Helper to keep tests crisp.  The constructor (Bennett-6azb / U58)
# enforces a valid wire partition; we use input==output for self-reversing
# fake circuits and skip ancillae.
_circuit(n_wires, gates) = ReversibleCircuit(
    n_wires,
    Vector{ReversibleGate}(gates),
    collect(1:n_wires),    # input_wires
    collect(1:n_wires),    # output_wires (overlap with input is legal)
    Int[],                 # ancilla_wires
    fill(1, n_wires),      # input_widths
    [n_wires],             # output_elem_widths
)

@testset "Bennett-mlny / U63 — depth basic shapes" begin

    @testset "empty circuit → 0" begin
        c = _circuit(1, ReversibleGate[])
        @test depth(c) == 0
    end

    @testset "sequential same-wire NOTs → N" begin
        for n in 1:5
            gates = [NOTGate(1) for _ in 1:n]
            c = _circuit(1, gates)
            @test depth(c) == n
        end
    end

    @testset "parallel disjoint NOTs → 1" begin
        for n in 1:8
            gates = [NOTGate(i) for i in 1:n]
            c = _circuit(n, gates)
            @test depth(c) == 1
        end
    end

    @testset "mixed: 2 parallel NOTs then Toffoli → 2" begin
        # NOT(1), NOT(2) live at depth 1 in parallel; Toffoli(1,2,3) waits
        # on both → depth 2.  Wire 3 reaches depth 2 via the Toffoli.
        gates = ReversibleGate[NOTGate(1), NOTGate(2), ToffoliGate(1, 2, 3)]
        c = _circuit(3, gates)
        @test depth(c) == 2
    end

    @testset "CNOT chain — strictly sequential through one wire → N" begin
        # CNOT(1,2), CNOT(1,2), ... — repeated dependence on wires 1+2.
        # Each CNOT advances both wires; depth grows linearly.
        for n in 1:4
            gates = ReversibleGate[CNOTGate(1, 2) for _ in 1:n]
            c = _circuit(2, gates)
            @test depth(c) == n
        end
    end

    @testset "compiled circuit matches docstring example" begin
        # Pinned in src/diagnostics.jl docstring as `depth(c) == 19` for
        # `x -> x + Int8(1)` over Int8.  Regression-anchor it here so a
        # depth-algorithm change can't silently shift the documented number.
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test depth(c) == 19
    end

    @testset "depth ≤ length(c.gates) — invariant" begin
        # Trivially true by construction (every gate adds at most one
        # layer along its longest input chain), but worth pinning.
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test depth(c) <= length(c.gates)
        c2 = reversible_compile(x -> x + Int16(1), Int16)
        @test depth(c2) <= length(c2.gates)
    end
end
