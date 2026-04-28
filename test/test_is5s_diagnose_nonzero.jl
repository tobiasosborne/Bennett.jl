# Bennett-is5s / U131 — diagnose_nonzero(circuit, inputs).
#
# Runs the circuit forward without throwing on Bennett-invariant
# violations; returns a structured report listing every violating
# wire + the gate index where each ancilla first became 1. Useful
# when simulate(c, x) threw and you need to see ALL the violations.

@testset "Bennett-is5s / U131 — diagnose_nonzero" begin
    @testset "clean circuit produces empty violations" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        r = diagnose_nonzero(c, Int8(5))
        @test isempty(r.ancilla_violations)
        @test isempty(r.input_violations)
        @test r.output == Int8(6)
        @test r.n_gates == length(c.gates)
        @test r.n_wires == c.n_wires
    end

    @testset "tuple-input form" begin
        c = reversible_compile((x, y) -> x + y, Int8, Int8)
        r = diagnose_nonzero(c, (Int8(3), Int8(4)))
        @test isempty(r.ancilla_violations)
        @test isempty(r.input_violations)
        @test r.output == Int8(7)
    end

    @testset "single-input arity assertion" begin
        c = reversible_compile((x, y) -> x + y, Int8, Int8)
        @test_throws ArgumentError diagnose_nonzero(c, Int8(5))
    end

    @testset "tuple-arity mismatch raises" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test_throws ArgumentError diagnose_nonzero(c, (Int8(3), Int8(4)))
    end

    @testset "ancilla-violation surfaces with first-set gate index" begin
        # Construct a deliberately-broken ReversibleCircuit by hand: an
        # ancilla wire that gets a NOTGate applied but no uncompute.
        gates = Bennett.ReversibleGate[
            Bennett.NOTGate(2),  # flips ancilla wire 2 — never undone
        ]
        # n_wires=2: input wire 1, ancilla wire 2 (no output of meaning).
        c = Bennett.ReversibleCircuit(2, gates,
                                       [1],   # input wires
                                       [1],   # output wires (echo input)
                                       [2],   # ancilla wires
                                       [1],   # input widths
                                       [1])   # output elem widths
        r = diagnose_nonzero(c, true)
        @test length(r.ancilla_violations) == 1
        wire, gate_idx = r.ancilla_violations[1]
        @test wire == 2
        @test gate_idx == 1   # NOTGate at gate index 1 first set wire 2
        @test isempty(r.input_violations)
    end

    @testset "input-mutation surfaces in input_violations" begin
        # Hand-built circuit that flips its single input wire and never
        # restores it — violates the Bennett-6azb input-preservation invariant.
        gates = Bennett.ReversibleGate[
            Bennett.NOTGate(1),  # flips input wire
        ]
        c = Bennett.ReversibleCircuit(1, gates,
                                       [1], [1], Int[],
                                       [1], [1])
        r = diagnose_nonzero(c, false)
        @test length(r.input_violations) == 1
        v = r.input_violations[1]
        @test v.input_index == 1
        @test v.wire_index  == 1
        @test v.expected    == false
        @test v.got         == true
    end
end
