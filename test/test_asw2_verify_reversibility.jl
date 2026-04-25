# Bennett-asw2 / U01: verify_reversibility is tautological — never checks
# ancilla-zero. This file is the red-green gate for the fix.
#
# Pre-fix behaviour (src/diagnostics.jl:145-161 + src/controlled.jl:89-107):
#   run `gates` forward, then run them reversed, assert bits return.
#   Since NOT/CNOT/Toffoli are each self-inverse, this round-trip is a
#   mathematical tautology regardless of ancilla state or input preservation.
#   The real ancilla-zero check lived only in `simulate` (src/simulator.jl:30-32),
#   not in the 256 call sites that use `verify_reversibility` in isolation.
#
# Post-fix behaviour: for each of `n_tests` random inputs, assert
#   (1) ancilla wires are zero after forward pass (Bennett's ancilla-clean invariant),
#   (2) input wires are unchanged after forward pass (Bennett's input-preservation),
#   (3) forward+reverse returns to start (retained as a cheap self-consistency check).
#
# Source reports: #03 F1, #05 F1, #09 F1, #13 implicit, #16 F14 (contract asymmetry).
# Catalogue anchor: reviews/2026-04-21/UNIFIED_CATALOGUE.md U01 (Bennett-asw2).

using Test
using Bennett
using Bennett: ReversibleCircuit, ReversibleGate, NOTGate, CNOTGate, ToffoliGate,
               ControlledCircuit, controlled,
               verify_reversibility, simulate, reversible_compile

@testset "Bennett-asw2 / U01: verify_reversibility catches Bennett invariant violations" begin

    @testset "T1: dirty ancilla is caught (the headline tautology)" begin
        # 3 wires: input=[1], output=[2], ancilla=[3].
        # NOTGate(3) flips ancilla and never un-flips it.
        # CNOTGate(1,2) copies input to output.
        # Post-forward pass: ancilla wire 3 is 1 (dirty). Bennett invariant violated.
        # `simulate` already catches this; `verify_reversibility` must too.
        gates = ReversibleGate[NOTGate(3), CNOTGate(1, 2)]
        c = ReversibleCircuit(3, gates, [1], [2], [3], [1], [1])
        # Ground-truth confirmation: simulate catches the violation.
        @test_throws ErrorException simulate(c, 0)
        # The fix: verify_reversibility must also catch it.
        @test_throws ErrorException verify_reversibility(c; n_tests=4)
    end

    @testset "T2: minimal dirty-ancilla circuit (1 gate)" begin
        # Even a 1-gate dirty circuit was passing the old tautology.
        gates = ReversibleGate[NOTGate(3)]
        c = ReversibleCircuit(3, gates, [1], [2], [3], [1], [1])
        @test_throws ErrorException verify_reversibility(c; n_tests=1)
    end

    @testset "T3: input-preservation violation is caught" begin
        # wires: input=[1], output=[2], ancilla=[3].
        # Gate sequence: CNOT copies input to output; NOTGate(1) then corrupts
        # the input wire. Round-trip tautology still holds (NOT self-inverse),
        # so the old check greenlit this. Bennett's input-preservation says
        # no — input wires must be unchanged post-forward.
        gates = ReversibleGate[CNOTGate(1, 2), NOTGate(1)]
        c = ReversibleCircuit(3, gates, [1], [2], [3], [1], [1])
        @test_throws ErrorException verify_reversibility(c; n_tests=4)
    end

    @testset "T4: real compiled circuit stays green" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test verify_reversibility(c; n_tests=32) == true
    end

    @testset "T5: two-arg compiled circuit stays green" begin
        c = reversible_compile((x, y) -> x + y, Int8, Int8)
        @test verify_reversibility(c; n_tests=32) == true
    end

    @testset "T6: ControlledCircuit mirrors the fix — dirty ancilla caught" begin
        # Mirror the T1 broken circuit and wrap via `controlled`.
        # The ControlledCircuit's verify_reversibility shares the same tautology
        # bug (src/controlled.jl:89-107) and must also catch dirty ancillae.
        gates = ReversibleGate[NOTGate(3), CNOTGate(1, 2)]
        inner = ReversibleCircuit(3, gates, [1], [2], [3], [1], [1])
        cc = controlled(inner)
        # Bennett-g0jb / U-: n_tests must be > 4 for the dirty-ancilla violation
        # (NOTGate(3) flips wire 3 only when ctrl=1) to fire reliably. Random
        # ctrl ~ Bernoulli(0.5); P(all n_tests trials pick ctrl=0) = 0.5^n_tests.
        # n_tests=4 → 6.25% flake rate (caught in chunk-042 wlf6 Pkg.test).
        # n_tests=20 → ~10⁻⁶, well below atomic-decay timescales.
        @test_throws ErrorException verify_reversibility(cc; n_tests=20)
    end

    @testset "T7: ControlledCircuit of a real circuit stays green" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        cc = controlled(c)
        @test verify_reversibility(cc; n_tests=32) == true
    end
end
