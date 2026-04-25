# Bennett-pksz / U98 — `controlled(c)` allocates ctrl_wire at
# `c.n_wires + 1` (and anc_wire at + 2 if any Toffoli exists). That
# choice is safe only if every inner gate references wires within
# `1:c.n_wires`. The `ReversibleCircuit` constructor partitions
# input/output/ancilla to cover that range, but does NOT cross-check
# that gate wire indices stay inside it — a malformed circuit could
# carry a gate referencing a wire beyond n_wires and silently
# collide with our chosen ctrl_wire.
#
# These tests pin:
#   1. Happy path: `controlled(reversible_compile(...))` works
#      end-to-end on the canonical i8 x+1 baseline.
#   2. Rejection path: a `ReversibleCircuit` with a gate index
#      greater than n_wires is rejected by `controlled()` with a
#      clear, attributable error message.

using Test
using Bennett

@testset "Bennett-pksz / U98 — controlled() contiguous-wire invariant" begin

    @testset "happy path: real compiled circuit" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        cc = controlled(c)
        @test cc isa ControlledCircuit
        @test verify_reversibility(cc)

        # ctrl_wire is exactly c.n_wires + 1 — pin it.
        @test cc.ctrl_wire == c.n_wires + 1

        # ctrl=true → f(x); ctrl=false → 0.
        for x in (Int8(0), Int8(5), Int8(-1))
            @test simulate(cc, true,  x) == x + Int8(1)
            @test simulate(cc, false, x) == 0
        end
    end

    @testset "rejection: gate references wire > n_wires" begin
        # Construct a malformed inner ReversibleCircuit. The partition
        # validator covers 1:3 exactly; the gate stream references
        # wire 99 outside that range. The `ReversibleCircuit` inner
        # constructor does NOT cross-check this — only `controlled()`
        # does (Bennett-pksz / U98).
        gates = ReversibleGate[NOTGate(99)]
        bad = ReversibleCircuit(3, gates, [1], [2], [3], [1], [1])

        @test_throws "wire 99 > n_wires=3" controlled(bad)
        # Substring match also catches the bead reference, which we
        # want to be present in the error so a future grep finds it.
        @test_throws "Bennett-pksz" controlled(bad)
    end

    @testset "edge case: empty gates list does not error" begin
        # n_wires=2, identity circuit (no gates), input=output, no anc.
        # The maximum() check would error on an empty collection — the
        # implementation guards against that.
        empty_gates = ReversibleGate[]
        c = ReversibleCircuit(2, empty_gates, [1], [1], [2], [1], [1])
        cc = controlled(c)
        @test cc isa ControlledCircuit
        @test cc.ctrl_wire == 3
    end
end
