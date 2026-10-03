# Bennett-ui55: every strategy's self_reversing fast path must reject a
# non-empty `lr.loop_guards`, exactly as DefaultStrategy does (Bennett-s0tn).
#
# Pre-ui55, `_bennett_default` asserted `isempty(lr.loop_guards)` inside its
# self_reversing branch, but the five Bennett-rjk7 fast-path copies in
# src/pebble/*.jl ran `_validate_self_reversing!` + `_build_circuit` BEFORE
# their loop-guard fallback. A self_reversing LR carrying a LoopGuard (a
# contradictory LR — a data-dependent loop cannot be self-cleaning) was
# returned as a clean circuit with zero loop_check_wires: the U03 probe
# accepts the convergence wire (0 after the forward pass) as a clean ancilla,
# so a loop that never converged would be reported as a valid result.
#
# Fix: one shared `_self_reversing_circuit(lr)` builder that every strategy's
# fast path calls; the loop-guard contradiction check lives there.

using Test
using Bennett
using Bennett: LoweringResult, GateGroup, CNOTGate, LoopGuard, bennett,
               lower_tabulate, bennett_direct, eager_bennett, value_eager_bennett,
               checkpoint_bennett, pebbled_bennett, pebbled_group_bennett,
               DefaultStrategy, EagerStrategy, ValueEagerStrategy,
               CheckpointStrategy, PebbledStrategy, PebbledGroupStrategy

const _UI55_STRATEGIES = [
    DefaultStrategy(),
    EagerStrategy(),
    ValueEagerStrategy(),
    CheckpointStrategy(),
    PebbledStrategy(0),
    PebbledStrategy(2),
    PebbledGroupStrategy(0),
    PebbledGroupStrategy(2),
]

# Astra B-circuit-core F8 witness: out = x via one CNOT; wire 3 is a
# LoopGuard convergence wire that stays 0 (loop "never converged").
_ui55_witness() = LoweringResult([CNOTGate(1, 2)], 3, [1], [2], [1], [1],
                                 GateGroup[], true, [LoopGuard(3, :L, 1)])

@testset "Bennett-ui55: self_reversing fast paths reject loop guards" begin
    @testset "$(strat)" for strat in _UI55_STRATEGIES
        err = try
            bennett(_ui55_witness(), strat)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test err !== nothing && occursin("Bennett-s0tn", sprint(showerror, err))
        @test err !== nothing && occursin("loop_guards", sprint(showerror, err))
    end

    @testset "legacy aliases reject too" begin
        @test_throws ErrorException eager_bennett(_ui55_witness())
        @test_throws ErrorException value_eager_bennett(_ui55_witness())
        @test_throws ErrorException checkpoint_bennett(_ui55_witness())
        @test_throws ErrorException pebbled_bennett(_ui55_witness(); max_pebbles=2)
        @test_throws ErrorException pebbled_group_bennett(_ui55_witness(); max_pebbles=2)
        @test_throws ErrorException bennett_direct(_ui55_witness())
    end

    # The guard must not disturb the legitimate fast path: a self_reversing
    # LR with no loop guards still short-circuits under every strategy.
    @testset "positive: guard-free self_reversing LR still short-circuits" begin
        f(x::UInt8) = x ⊻ UInt8(0x5c)
        n_bare = length(lower_tabulate(f, Tuple{UInt8}, [8]; out_width=8).gates)
        for strat in _UI55_STRATEGIES
            c = bennett(lower_tabulate(f, Tuple{UInt8}, [8]; out_width=8), strat)
            @test length(c.gates) == n_bare
            @test isempty(c.loop_check_wires)
            @test verify_reversibility(c)
            @test all(x -> simulate(c, x) == f(x), typemin(UInt8):typemax(UInt8))
        end
    end

    # Witness without the contradictory guard is a valid self_reversing LR.
    @testset "positive: witness minus guard compiles to identity" begin
        lr = LoweringResult([CNOTGate(1, 2)], 3, [1], [2], [1], [1],
                            GateGroup[], true)
        for strat in _UI55_STRATEGIES
            c = bennett(lr, strat)
            @test verify_reversibility(c)
            @test simulate(c, false) == false
            @test simulate(c, true) == true
        end
    end
end
