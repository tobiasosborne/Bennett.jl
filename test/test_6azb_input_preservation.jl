using Test
using Bennett

# Bennett-6azb / U58: the simulator was only checking one half of
# Bennett's invariant: `bits[ancilla_wires]` all zero after the run.
# The other half — that *inputs* come out bit-identical to what went
# in — was implicit, never verified. A circuit that silently mutated
# an input wire but produced the correct output passed every existing
# test.
#
# Also: `ReversibleCircuit`'s ancilla set was computed by set-
# difference without asserting the partition. A mis-built circuit
# could have an ancilla wire that overlapped input or output, silently
# feeding the ancilla-zero check an input/output value.
#
# This pins:
#   1. `simulate` snapshots input wires and errors with specific
#      (wire, before, after) context if any input is mutated.
#   2. `ReversibleCircuit`'s inner constructor asserts the covering
#      union `input ∪ output ∪ ancilla == 1:n_wires` and rejects
#      ancilla-overlaps-input or ancilla-overlaps-output.
#   3. Well-formed circuits from `reversible_compile` continue to
#      pass (no false positives on the shipped pipeline).
@testset "Bennett-6azb / U58: simulator input-preservation + partition" begin

    @testset "regression guard: every shipped circuit still simulates cleanly" begin
        # The pipeline's own output must not trip the new assertion.
        c1 = reversible_compile(x -> x + Int8(3), Int8)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c1, x) == x + Int8(3)
        end
        # Multi-arg
        c2 = reversible_compile((a, b) -> a + b, Int8, Int8)
        for a in Int8.(-5:5), b in Int8.(-5:5)
            @test simulate(c2, (a, b)) == a + b
        end
        # Tuple-return sret
        c3 = reversible_compile((a, b) -> (b, a), Int8, Int8)
        @test simulate(c3, (Int8(7), Int8(-3))) == (Int8(-3), Int8(7))
    end

    @testset "detects input mutation: synthetic broken circuit" begin
        # Build a ReversibleCircuit by hand that forward-passes correctly
        # but then toggles input_wires[1] at the end. Bennett's construction
        # would never produce this (the reverse pass uncomputes any mutation),
        # but a buggy lowering could. Post-U58, `simulate` must error.
        #
        # Shape: n_wires=3. wire 1 = input, wire 2 = output, wire 3 = ancilla.
        # Gates: CNOT(1 -> 2) to copy input to output, then NOT(1) — a
        # stray mutation the Bennett uncompute forgot.
        gates = Bennett.ReversibleGate[
            Bennett.CNOTGate(1, 2),
            Bennett.NOTGate(1),   # <-- mutates input wire — must be caught
        ]
        broken = Bennett.ReversibleCircuit(
            3, gates,
            [1],        # input_wires
            [2],        # output_wires
            [3],        # ancilla_wires
            [1],        # input_widths  (1 bit)
            [1],        # output_elem_widths
        )

        err = try
            simulate(broken, 0)
            nothing
        catch e
            e
        end
        @test err !== nothing
        # Message must name the input wire AND the before/after values
        # so a user can bisect which lowering stage produced the mutation.
        @test occursin("input wire", lowercase(sprint(showerror, err)))
    end

    @testset "ReversibleCircuit constructor rejects ancilla overlapping input" begin
        # ancilla_wires overlapping input_wires makes the ancilla-zero
        # check fire spuriously on the input value. Must fail loudly.
        err = try
            Bennett.ReversibleCircuit(
                3, Bennett.ReversibleGate[],
                [1],       # input
                [2],       # output
                [1, 3],    # ancilla — 1 overlaps input
                [1], [1],
            )
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("ancilla", lowercase(sprint(showerror, err)))
    end

    @testset "ReversibleCircuit constructor rejects ancilla overlapping output" begin
        err = try
            Bennett.ReversibleCircuit(
                3, Bennett.ReversibleGate[],
                [1], [2], [2, 3],      # ancilla includes output wire 2
                [1], [1],
            )
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("ancilla", lowercase(sprint(showerror, err)))
    end

    @testset "ReversibleCircuit constructor rejects incomplete wire coverage" begin
        # n_wires=4, but wire 3 isn't in input, output, or ancilla.
        err = try
            Bennett.ReversibleCircuit(
                4, Bennett.ReversibleGate[],
                [1], [2], [4],
                [1], [1],
            )
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("wire", lowercase(sprint(showerror, err)))
    end

    @testset "self-reversing identity: input == output overlap is allowed" begin
        # Self-reversing primitives (soft-float, QROM tabulate) may write
        # the result back onto the input wires. `input ∩ output ≠ ∅` is
        # legitimate; only ancilla disjointness is enforced.
        c = Bennett.ReversibleCircuit(
            2, Bennett.ReversibleGate[],
            [1],        # input
            [1],        # output == input (identity shape)
            [2],        # ancilla
            [1], [1],
        )
        @test c.n_wires == 2   # constructor did not throw
    end
end
