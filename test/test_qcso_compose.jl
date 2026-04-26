# Bennett-qcso / U59 — `compose(c1, c2)` pipeline composition.
#
# Semantics: `simulate(compose(c1, c2), x) == simulate(c2, simulate(c1, x))`.
# Implementation strategy: c1.gates ++ renumbered(c2.gates) ++ reverse(c1.gates),
# uncomputing c1 after c2 so the alias seam wires return to zero (see
# src/compose.jl docstring for the wire-budget proof).
#
# This bead unblocks the Sturm `when(qubit) do f(x) end` integration
# story (review F49/F50 — composition was an UNCOVERED API).

using Test
using Bennett

@testset "Bennett-qcso / U59 — compose(c1, c2)" begin

    @testset "function composition: g(f(x)) for all i8" begin
        # Ripple add then ripple add. compose should be (x+1)+2 = x+3 mod 256.
        c1 = reversible_compile(x -> x + Int8(1), Int8)
        c2 = reversible_compile(x -> x + Int8(2), Int8)
        c12 = compose(c1, c2)
        @test verify_reversibility(c12)
        for x in Int8(-128):Int8(127)
            @test simulate(c12, x) == (x + Int8(1)) + Int8(2)
        end
        # And the reverse pipeline (x+2)+1 = x+3 (commutativity in the Int8 ring).
        c21 = compose(c2, c1)
        @test verify_reversibility(c21)
        for x in Int8(-128):Int8(127)
            @test simulate(c21, x) == (x + Int8(2)) + Int8(1)
        end
    end

    @testset "function composition: mul ∘ add" begin
        # x → (x+1)*3 mod 256 — exercises both ripple-add and shift-and-add mul.
        c1 = reversible_compile(x -> x + Int8(1), Int8)
        c2 = reversible_compile(x -> x * Int8(3), Int8)
        c12 = compose(c1, c2)
        @test verify_reversibility(c12)
        for x in Int8(-128):Int8(127)
            @test simulate(c12, x) == (x + Int8(1)) * Int8(3)
        end
    end

    @testset "wider widths: i16 add+xor" begin
        # Capturing a loop variable T into the lambda forces ir_extract to
        # treat it as a closure (LLVM emits a Ptr first arg), which breaks
        # extraction. Inline the constant types explicitly.
        c1 = reversible_compile(x -> x + Int16(7),  Int16)
        c2 = reversible_compile(x -> x ⊻ Int16(42), Int16)
        c12 = compose(c1, c2)
        @test verify_reversibility(c12)
        for x in Int16[Int16(-100), Int16(-1), Int16(0), Int16(1), Int16(127),
                        Int16(255), Int16(1024), Int16(typemax(Int16))]
            @test simulate(c12, x) == (x + Int16(7)) ⊻ Int16(42)
        end
    end

    @testset "wider widths: i32 add+xor" begin
        c1 = reversible_compile(x -> x + Int32(7),  Int32)
        c2 = reversible_compile(x -> x ⊻ Int32(42), Int32)
        c12 = compose(c1, c2)
        @test verify_reversibility(c12)
        for x in Int32[Int32(-100), Int32(-1), Int32(0), Int32(1), Int32(127),
                        Int32(255), Int32(1024), Int32(typemax(Int32))]
            @test simulate(c12, x) == (x + Int32(7)) ⊻ Int32(42)
        end
    end

    @testset "associativity (semantic): (c1 ∘ c2) ∘ c3 == c1 ∘ (c2 ∘ c3)" begin
        c1 = reversible_compile(x -> x + Int8(1), Int8)
        c2 = reversible_compile(x -> x * Int8(3), Int8)
        c3 = reversible_compile(x -> x ⊻ Int8(5), Int8)
        # Left-associated and right-associated bracketings:
        left  = compose(compose(c1, c2), c3)
        right = compose(c1, compose(c2, c3))
        @test verify_reversibility(left)
        @test verify_reversibility(right)
        # The two bracketings have different wire layouts but identical
        # observable semantics. Sweep all 256 i8 inputs.
        for x in Int8(-128):Int8(127)
            expected = ((x + Int8(1)) * Int8(3)) ⊻ Int8(5)
            @test simulate(left,  x) == expected
            @test simulate(right, x) == expected
        end
    end

    @testset "wire-budget invariants" begin
        c1 = reversible_compile(x -> x + Int8(1), Int8)
        c2 = reversible_compile(x -> x + Int8(2), Int8)
        c12 = compose(c1, c2)
        m = length(c2.input_wires)
        # Compaction: n_total = c1.n_wires + c2.n_wires - m.
        @test c12.n_wires == c1.n_wires + c2.n_wires - m
        # Compose's inputs are c1's inputs verbatim (no renumber).
        @test c12.input_wires  == c1.input_wires
        @test c12.input_widths == c1.input_widths
        @test c12.output_elem_widths == c2.output_elem_widths
        # Wire-partition is implicit (constructor would have rejected).
        @test issetequal(union(c12.input_wires, c12.output_wires, c12.ancilla_wires),
                         1:c12.n_wires)
        # Gate count: |c1| + |c2| + |c1| (the trailing reverse-c1 uncompute).
        @test length(c12.gates) == 2 * length(c1.gates) + length(c2.gates)
    end

    @testset "compose with controlled (the Sturm pathway)" begin
        c1 = reversible_compile(x -> x + Int8(1), Int8)
        c2 = reversible_compile(x -> x + Int8(2), Int8)
        c12 = compose(c1, c2)
        cc = controlled(c12)
        @test verify_reversibility(cc)
        # ctrl=true → apply the composed function; ctrl=false → identity-zero.
        for x in Int8(-128):Int8(127)
            @test simulate(cc, true,  x) == (x + Int8(1)) + Int8(2)
            @test simulate(cc, false, x) == Int8(0)
        end
    end

    @testset "width mismatch rejected" begin
        c8  = reversible_compile(x -> x + Int8(1),  Int8)
        c16 = reversible_compile(x -> x + Int16(1), Int16)
        @test_throws ArgumentError compose(c8,  c16)
        @test_throws ArgumentError compose(c16, c8)
    end

    @testset "self-reversing rejected (MVP)" begin
        # Hand-build a tiny self-reversing circuit: input wire 1 is also the
        # output wire (a single NOT in place). The constructor accepts this
        # (the input ∩ output overlap is permitted), but compose must reject.
        gates = ReversibleGate[NOTGate(1)]
        sr = ReversibleCircuit(1, gates, [1], [1], Int[], [1], [1])
        c8 = reversible_compile(x -> x + Int8(1), Int8)
        # Width mismatch (1 vs 8) means the width check fires before the
        # self-reversing check. Build width-matched siblings instead.
        @test_throws ArgumentError compose(sr, c8)

        # Width-matched self-reversing pair: 8 wires, input == output.
        gates8 = ReversibleGate[NOTGate(1)]
        sr8 = ReversibleCircuit(8, gates8, collect(1:8), collect(1:8), Int[],
                                [8], [8])
        nonself = reversible_compile(x -> x + Int8(1), Int8)
        @test_throws ArgumentError compose(sr8,    nonself)
        @test_throws ArgumentError compose(nonself, sr8)
    end

    @testset "compose preserves semantics under nested composition" begin
        # Five-stage pipeline: x → x+1 → x*2 → x⊕3 → x+5 → x*7 (mod 256).
        cs = [reversible_compile(x -> x + Int8(1), Int8),
              reversible_compile(x -> x * Int8(2), Int8),
              reversible_compile(x -> x ⊻ Int8(3), Int8),
              reversible_compile(x -> x + Int8(5), Int8),
              reversible_compile(x -> x * Int8(7), Int8)]
        c_chain = foldl(compose, cs)
        @test verify_reversibility(c_chain)
        # Reference oracle: same composition done in Julia.
        oracle(x) = ((((x + Int8(1)) * Int8(2)) ⊻ Int8(3)) + Int8(5)) * Int8(7)
        for x in Int8(-128):Int8(127)
            @test simulate(c_chain, x) == oracle(x)
        end
    end

    @testset "compose exported from Bennett module" begin
        # Static-presence check — catches accidental removal of the export
        # (which would leave callers needing `Bennett.compose` instead).
        @test :compose in names(Bennett)
    end
end
