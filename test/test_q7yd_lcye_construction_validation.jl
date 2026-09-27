using Test
using Bennett

# Bennett-q7yd + Bennett-lcye — malformed circuits and irreversible
# gates must be rejected AT CONSTRUCTION, not merely caught (or missed)
# by `verify_reversibility`.
#
# Astra review B-circuit-core (2026-09-26), findings:
#   F13 / Bennett-lcye: `CNOTGate(c,c)` is accepted; it is not
#     self-inverse — `apply!` zeroes the bit in one application. A
#     Toffoli whose target is one of its controls has the same defect.
#     The constructor never validated wire bounds either.
#   F7 / Bennett-q7yd: `ReversibleCircuit`'s Set-based partition checks
#     erase duplicate positions, so `input_wires=[1,1]` bypasses the
#     input-preservation check while `verify_reversibility` still
#     returns true. Width totals were never cross-checked against the
#     wire lists either (a width-0 input, or an output list longer than
#     `output_elem_widths` sums to, both verified true).
#
# The witnesses below are copied verbatim from the two bead
# descriptions / the verification report.
@testset "Bennett-q7yd/lcye: construction-time gate + circuit validation" begin

    @testset "Bennett-lcye: gate primitives reject self-control + bad wires" begin
        # Irreversible self-controlled gates (F13 witness is CNOTGate(1,1)).
        @test_throws ArgumentError CNOTGate(1, 1)
        @test_throws ArgumentError ToffoliGate(1, 2, 1)   # target == control1
        @test_throws ArgumentError ToffoliGate(1, 2, 2)   # target == control2
        # Wire indices are 1-based at the primitive boundary.
        @test_throws ArgumentError NOTGate(0)
        @test_throws ArgumentError NOTGate(-1)
        @test_throws ArgumentError CNOTGate(0, 1)
        @test_throws ArgumentError CNOTGate(1, 0)
        @test_throws ArgumentError CNOTGate(-1, 2)
        @test_throws ArgumentError ToffoliGate(0, 2, 3)
        @test_throws ArgumentError ToffoliGate(1, 0, 3)
        @test_throws ArgumentError ToffoliGate(1, 2, 0)
        # Accepted primitives still construct and keep their fields.
        @test NOTGate(3).target == 3
        @test CNOTGate(1, 2).control == 1 && CNOTGate(1, 2).target == 2
        @test ToffoliGate(1, 2, 3).control1 == 1
        @test ToffoliGate(1, 2, 3).control2 == 2
        @test ToffoliGate(1, 2, 3).target == 3
        # control1 == control2 is a legitimate reversible gate (equivalent
        # to CNOT); `lower_mul_wide!` emits it when squaring, so it must
        # NOT be rejected. Verified as a permutation below.
        dupe = ToffoliGate(1, 1, 2)
        @test dupe.control1 == dupe.control2 == 1 && dupe.target == 2
    end

    @testset "Bennett-lcye: accepted primitives are permutations/self-inverse" begin
        # Oracle: the mathematical gate action, written independently of
        # src/simulator.jl's `apply!`. Every accepted gate must be an
        # involution on its local bits (hence a permutation), exhaustively.
        # Bit i (1-based) is the (i-1)-th bit of `m`.
        ref_bits(m, n) = Bool[(m >> (i - 1)) & 1 == 1 for i in 1:n]
        cases = (
            (NOTGate(1), 1, b -> (r = copy(b); r[1] ⊻= true; r)),
            (CNOTGate(1, 2), 2, b -> (r = copy(b); r[2] ⊻= b[1]; r)),
            (ToffoliGate(1, 2, 3), 3, b -> (r = copy(b); r[3] ⊻= b[1] & b[2]; r)),
            # control1 == control2: must behave as CNOT(1, 2), not zero it.
            (ToffoliGate(1, 1, 2), 2, b -> (r = copy(b); r[2] ⊻= b[1]; r)),
        )
        for (g, n, oracle) in cases
            seen = Int[]
            for m in 0:(2^n - 1)
                b = ref_bits(m, n)
                after = copy(b)
                Bennett.apply!(after, g)
                @test after == oracle(b)
                push!(seen, sum((after[i] ? 1 : 0) << (i - 1) for i in 1:n))
                Bennett.apply!(after, g)   # involution restores the input
                @test after == b
            end
            # permutation: every local configuration is hit exactly once.
            @test sort(seen) == collect(0:(2^n - 1))
        end
    end

    @testset "Bennett-q7yd: F7 witnesses throw at construction" begin
        # Witness 1: duplicate logical input positions.
        @test_throws ArgumentError ReversibleCircuit(
            2, ReversibleGate[CNOTGate(1, 2)], [1, 1], [2], Int[], [1, 1], [1])
        # Witness 2: output list longer than sum(output_elem_widths);
        # wire 3 is permanently dirty yet classified as an unread output.
        @test_throws ArgumentError ReversibleCircuit(
            3, ReversibleGate[NOTGate(3)], [1], [2, 3], Int[], [1], [1])
        # Witness 3: zero-width input is never randomised but verified true.
        @test_throws ArgumentError ReversibleCircuit(
            2, ReversibleGate[CNOTGate(1, 2)], [1], [2], Int[], [0], [1])
    end

    @testset "Bennett-q7yd: remaining metadata invariants" begin
        # duplicate positions within output / ancilla / loop-check.
        @test_throws ArgumentError ReversibleCircuit(
            3, ReversibleGate[NOTGate(3)], [1], [2, 2], Int[], [1], [1, 1])
        @test_throws ArgumentError ReversibleCircuit(
            3, ReversibleGate[NOTGate(3)], [1], [2], [3, 3], [1], [1])
        @test_throws ArgumentError ReversibleCircuit(
            3, ReversibleGate[], [1], [2], Int[], [1], [1],
            Bennett.LoopGuard[Bennett.LoopGuard(3, :h, 4), Bennett.LoopGuard(3, :h, 4)])
        # zero / negative widths.
        @test_throws ArgumentError ReversibleCircuit(
            2, ReversibleGate[CNOTGate(1, 2)], [1], [2], Int[], [-1], [1])
        @test_throws ArgumentError ReversibleCircuit(
            2, ReversibleGate[CNOTGate(1, 2)], [1], [2], Int[], [1], [0])
        # sum(input_widths) != length(input_wires).
        @test_throws ArgumentError ReversibleCircuit(
            3, ReversibleGate[CNOTGate(1, 2)], [1, 2], [3], Int[], [1], [1])
        # sum(output_elem_widths) != length(output_wires).
        @test_throws ArgumentError ReversibleCircuit(
            4, ReversibleGate[CNOTGate(1, 2)], [1], [3, 4], [2], [1], [1])
        # gate wire index beyond n_wires (pksz / U98 invariant, now checked
        # here rather than only in `controlled`).
        @test_throws ArgumentError ReversibleCircuit(
            3, ReversibleGate[NOTGate(99)], [1], [2], [3], [1], [1])
    end

    @testset "Bennett-q7yd: legitimate circuits still construct + verify" begin
        # Self-reversing identity: input ∩ output is legal (cross-class).
        c_id = ReversibleCircuit(2, ReversibleGate[], [1], [1], [2], [1], [1])
        @test c_id.n_wires == 2
        @test verify_reversibility(c_id)

        # Tuple output: every logical output bit has a distinct wire, and
        # the widths must sum to the wire count.
        c_swap = reversible_compile((a, b) -> (b, a), Int8, Int8)
        @test simulate(c_swap, (Int8(7), Int8(-3))) == (Int8(-3), Int8(7))
        @test verify_reversibility(c_swap)

        # Exhaustive Int8 oracle: the shipped pipeline's own circuits must
        # survive the new constructor checks unchanged.
        inc3 = reversible_compile(x -> x + Int8(3), Int8)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(inc3, x) == x + Int8(3)
        end
        add = reversible_compile((a, b) -> a + b, Int8, Int8)
        for a in Int8.(-8:7), b in Int8.(-8:7)
            @test simulate(add, (a, b)) == a + b
        end
        @test verify_reversibility(inc3)
        @test verify_reversibility(add)
    end
end
