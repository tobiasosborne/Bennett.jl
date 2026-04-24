# Bennett-egu6 / U03: self_reversing=true is an unchecked trust boundary.
#
# `bennett()` short-circuits when `lr.self_reversing == true`, returning
# forward gates with NO copy-out, NO reverse, NO ancilla-zero assertion, and
# NO input-preservation assertion (src/bennett_transform.jl:27-30).
# An honest bug in a "self-reversing" primitive would silently poison the
# compiler with dirty ancillae or corrupted inputs.
#
# Fix: `bennett()` runs a fixed, deterministic probe battery before accepting
# a self_reversing primitive. Probes forward-execute on a few canonical input
# vectors using `apply!`, then assert (1) every ancilla is zero and (2)
# every input wire is preserved. On violation, raise loud with context. No
# fallback — the primitive author must fix the bug or drop the flag.
#
# 3+1 protocol (CLAUDE.md §2) applied: 2 independent proposer designs at
# docs/design/egu6_proposer_{A,B}.md (summaries in WORKLOG). Implementer
# synthesized 4 probes (all-zero, all-one, walking-1 first-lane,
# walking-1 last-lane), ancilla-zero + input-preservation assertions.
#
# Catalogue: reviews/2026-04-21/UNIFIED_CATALOGUE.md U03. Reports: #09 F3,
# #14 F8.

using Test
using Bennett
using Bennett: ReversibleGate, NOTGate, CNOTGate, ToffoliGate, GateGroup,
               LoweringResult, bennett, simulate, verify_reversibility,
               lower_tabulate, reversible_compile

@testset "Bennett-egu6 / U03: bennett() validates self_reversing=true contracts" begin

    @testset "T1: forged dirty-ancilla self-reversing circuit is rejected" begin
        # 3 wires: input=[1], output=[2], ancilla={3}.
        # NOTGate(3) flips the ancilla and never un-flips it — clean violation
        # of Bennett's ancilla-clean invariant. Pre-fix: bennett() silently
        # returns a broken circuit. Post-fix: the probe catches it.
        gates = ReversibleGate[NOTGate(3)]
        lr = LoweringResult(gates, 3, [1], [2], [1], [1],
                            Set{Int}(), GateGroup[], true)
        @test_throws ErrorException bennett(lr)
    end

    @testset "T2: error message identifies the violating invariant" begin
        gates = ReversibleGate[NOTGate(3)]
        lr = LoweringResult(gates, 3, [1], [2], [1], [1],
                            Set{Int}(), GateGroup[], true)
        err = try
            bennett(lr); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("self_reversing", err.msg)
        @test occursin("ancilla", err.msg) || occursin("wire 3", err.msg)
    end

    @testset "T3: forged input-corrupting self-reversing circuit is rejected" begin
        # NOTGate(1) flips the input wire itself — violates Bennett's
        # input-preservation invariant. Round-trip tautology holds, so the
        # old path (and the old verify_reversibility) greenlit this.
        gates = ReversibleGate[NOTGate(1)]
        lr = LoweringResult(gates, 2, [1], [2], [1], [1],
                            Set{Int}(), GateGroup[], true)
        @test_throws ErrorException bennett(lr)
    end

    @testset "T4: real lower_tabulate QROM primitive still compiles (positive)" begin
        # `lower_tabulate` sets self_reversing=true legitimately. The QROM
        # lookup (x, 0^W) → (x, f(x)) leaves inputs untouched and ancillae
        # clean by construction. The probe battery MUST NOT false-positive.
        f(x::Int8) = x ⊻ Int8(0x5A)  # XOR stays in Int8 range for all 256 inputs
        lr = lower_tabulate(f, Tuple{Int8}, [8]; out_width=8)
        c  = bennett(lr)                 # must not raise
        @test verify_reversibility(c; n_tests=16)
        # Exhaustive Int8 oracle.
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == f(x)
        end
    end

    @testset "T5: gate counts unchanged (validator reads only, never mutates)" begin
        # Regression barrier: if the probe ever touches lr.gates, gate_count
        # drifts. Run full pipeline and pin the baseline Int8 x+1 total.
        # Post-U27/U28: 58/12 (was 100/28 pre-U27 Cuccaro default).
        c = reversible_compile(x -> x + Int8(1), Int8)
        gc = gate_count(c)
        @test gc.total == 58
        @test gc.Toffoli == 12
    end
end
