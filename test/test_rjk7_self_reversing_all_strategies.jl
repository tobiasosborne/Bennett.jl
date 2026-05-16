# Bennett-rjk7: extend the self_reversing=true fast-path to ALL 6 strategies.
#
# Pre-rjk7, only DefaultStrategy honored `lr.self_reversing=true` and
# short-circuited to forward-only emission (no copy-out, no reverse).
# EagerStrategy / ValueEagerStrategy / CheckpointStrategy / PebbledStrategy /
# PebbledGroupStrategy ignored the flag, applying their full algorithm and
# producing a wrapped circuit ~2x the gate count. Worse, they ALSO bypassed
# the U03 contract probe (`_validate_self_reversing!`, Bennett-egu6), so a
# forged `self_reversing=true` tag would silently produce a wrapped (but
# possibly correctness-preserving) circuit instead of failing loud — a
# violation of CLAUDE.md §1 (fail-fast-fail-loud) when contrasted with
# DefaultStrategy's behavior.
#
# rjk7 inlines the same 4-line short-circuit (validate + _build_circuit) into
# every `_*_bennett_impl` body. Three properties become universal:
#
#   1. Short-circuit: gate count == bare LR gate count (no wrap).
#   2. Reversibility + oracle correctness preserved (verify_reversibility
#      + exhaustive UInt8 sweep against the function definition).
#   3. Forged-tag rejection via `_validate_self_reversing!` is universal —
#      a producer that lies about self-reversal fails identically across
#      all 6 strategies.
#
# Catalogue: see WORKLOG for rjk7 entry; closes the h0ai future-work comment
# at test/test_h0ai_auto_self_reversing.jl:30.

using Test
using Bennett
using Bennett: LoweringResult, GateGroup, ReversibleGate, NOTGate, bennett,
               lower_tabulate, _build_circuit, _validate_self_reversing!,
               DefaultStrategy, EagerStrategy, ValueEagerStrategy,
               CheckpointStrategy, PebbledStrategy, PebbledGroupStrategy

# Pin the 6 strategies (DefaultStrategy included for cross-strategy
# consistency evidence — its behavior was already correct pre-rjk7).
const _RJK7_STRATEGIES = [
    DefaultStrategy(),
    EagerStrategy(),
    ValueEagerStrategy(),
    CheckpointStrategy(),
    PebbledStrategy(0),       # 0 = no pebbling budget; falls through to bennett(lr) on non-self-reversing input
    PebbledGroupStrategy(0),
]

@testset "Bennett-rjk7: all strategies honor lr.self_reversing" begin
    # ---- Group 1: POSITIVE — self-reversing LR via lower_tabulate ----
    @testset "T1-T6: short-circuit on self-reversing tabulate LR" begin
        f(x::UInt8) = x ⊻ UInt8(0xaa)   # involution; canonical tabulatable
        # Build the bare self-reversing LR once; reuse across strategies.
        # bennett() does not mutate lr.gates (Bennett-nj5r / U200 verified
        # this across all 5 non-default strategies).
        n_bare = length(lower_tabulate(f, Tuple{UInt8}, [8]; out_width=8).gates)

        for strat in _RJK7_STRATEGIES
            @testset "$(nameof(typeof(strat)))" begin
                lr = lower_tabulate(f, Tuple{UInt8}, [8]; out_width=8)
                circuit = bennett(lr, strat)
                # (a) Structural: no wrap means gate count == bare LR gate count.
                @test length(circuit.gates) == n_bare
                # (b) §4: reversibility.
                @test verify_reversibility(circuit)
                # (c) §4: oracle on full UInt8 sweep.
                for x in UInt8(0):UInt8(255)
                    @test simulate(circuit, x) == f(x)
                end
            end
        end
    end

    # ---- Group 2: NEGATIVE REGRESSION — non-self-reversing LR still wraps ----
    @testset "T7-T12: non-self-reversing LR wraps correctly per strategy" begin
        # `x + 1` lowers to multiple gate groups + branch boilerplate, so
        # `_infer_self_reversing` will NOT promote — self_reversing stays false.
        g(x::Int8) = x + Int8(1)
        # Baseline via reversible_compile (DefaultStrategy) for the oracle.
        c_default = reversible_compile(g, Int8)
        @test verify_reversibility(c_default)
        baseline_correct = [simulate(c_default, x) for x in Int8(-128):Int8(127)]

        # Build the LR via the standard pipeline so we can dispatch to any
        # strategy. The reversible_compile entry point doesn't expose the
        # Bennett strategy kwarg, so we go through extract+lower+bennett.
        parsed = Bennett.extract_parsed_ir(g, Tuple{Int8})
        lr = Bennett.lower(parsed)
        @test lr.self_reversing == false   # invariant guard

        for strat in _RJK7_STRATEGIES
            @testset "$(nameof(typeof(strat)))" begin
                circuit = bennett(lr, strat)
                @test verify_reversibility(circuit)
                for (i, x) in enumerate(Int8(-128):Int8(127))
                    @test simulate(circuit, x) == baseline_correct[i]
                end
            end
        end
    end

    # ---- Group 3: FORGED-TAG FAIL-LOUD ----
    @testset "T13-T18: forged self_reversing=true throws via U03 probe" begin
        # Mirrors test_egu6_self_reversing_check.jl T1's forged construction:
        # NOTGate(2) flips wire 2 (an ancilla, since input=[1], output=[3])
        # and never un-flips it. Pre-rjk7, only DefaultStrategy threw on
        # this; the other 5 strategies silently ran their algorithm. Post-
        # rjk7, all 6 throw ArgumentError uniformly per CLAUDE.md §1.
        for strat in _RJK7_STRATEGIES
            @testset "$(nameof(typeof(strat)))" begin
                gates = ReversibleGate[NOTGate(2)]
                lr_forged = LoweringResult(
                    gates, 3, [1], [3], [1], [1],
                    GateGroup[], true,   # self_reversing=true — the forgery
                )
                @test_throws ArgumentError bennett(lr_forged, strat)
            end
        end
    end
end
