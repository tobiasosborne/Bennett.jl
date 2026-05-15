# Bennett-op6a / U140 — `lower_add_cuccaro!`'s docstring previously
# advertised "2n Toffoli, 5n CNOT, 2n negations" for an n-bit adder
# but the implementation emits the carry-suppressed mod-2^W variant.
# Discrepancy traced to the original Cuccaro 2004 paper presenting the
# carry-out form; our impl is the carry-suppressed mod-2^W variant.
#
# Bennett-gsxe / U_ (2026-05-15) — §3.5 high-bit optimisation applied:
# the Toffoli at the W-1 boundary that would compute c_W into the high
# carry wire is dropped, the matching Phase-3 uncompute Toffoli is
# dropped, and ONE new Toffoli is injected into Phase 2 with the same
# two controls but writing directly into b[W]. Net change: −1 Toffoli
# and −1 total gate at every W ≥ 2. New formulas: Toffoli = 2W−3,
# CNOT = 4W−2, NOT = 0, Total = 6W−5.
#
# This file regression-anchors the actual gate counts at canonical
# widths so a future drift surfaces immediately.

using Test
using Bennett
using Bennett: lower_add_cuccaro!, WireAllocator, allocate!

@testset "Bennett-op6a / U140 — lower_add_cuccaro! gate counts" begin

    # Post-Bennett-gsxe formulas: Toffoli = 2W-3, CNOT = 4W-2, NOT = 0,
    # Total = 6W-5. Verified across W ∈ {2, 3, 4, 8, 16, 32, 64}.
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

            @test toffs == 2 * W - 3
            @test cnots == 4 * W - 2
            @test nots  == 0
            @test length(gates) == 6 * W - 5
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
