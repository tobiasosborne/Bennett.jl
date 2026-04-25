# Bennett-op6a / U140 — `lower_add_cuccaro!`'s docstring previously
# advertised "2n Toffoli, 5n CNOT, 2n negations" for an n-bit adder
# but the implementation emits 2W−2 Toffoli, 4W−2 CNOT, 0 NOT for the
# mod-2^W variant (carry-out absent). Discrepancy traced to the
# original Cuccaro 2004 paper presenting the carry-out form; our impl
# is the carry-suppressed mod-2^W variant.
#
# Docstring corrected. This file regression-anchors the actual gate
# counts at canonical widths so a future drift surfaces immediately.

using Test
using Bennett
using Bennett: lower_add_cuccaro!, WireAllocator, allocate!

@testset "Bennett-op6a / U140 — lower_add_cuccaro! gate counts" begin

    # Measured 2026-04-26 across W ∈ {2, 3, 4, 8, 16, 32}.
    # Formulas: Toffoli = 2W-2, CNOT = 4W-2, NOT = 0, Total = 6W-4.
    for W in (2, 3, 4, 8, 16, 32, 64)
        @testset "W=$W" begin
            gates = ReversibleGate[]
            wa = WireAllocator()
            a = allocate!(wa, W)
            b = allocate!(wa, W)
            lower_add_cuccaro!(gates, wa, a, b, W)

            nots  = count(g -> g isa NOTGate, gates)
            cnots = count(g -> g isa CNOTGate, gates)
            toffs = count(g -> g isa ToffoliGate, gates)

            @test toffs == 2 * W - 2
            @test cnots == 4 * W - 2
            @test nots  == 0
            @test length(gates) == 6 * W - 4
        end
    end

    @testset "W=1 falls back to lower_add!" begin
        # Per the implementation, W <= 1 delegates to lower_add!. So
        # the formulas above don't apply at W=1; just verify the
        # fallback emits SOMETHING and the call doesn't error.
        gates = ReversibleGate[]
        wa = WireAllocator()
        a = allocate!(wa, 1)
        b = allocate!(wa, 1)
        result = lower_add_cuccaro!(gates, wa, a, b, 1)
        @test result isa Vector{Int}
        @test !isempty(gates)  # lower_add! emits at least the result CNOTs
    end
end
