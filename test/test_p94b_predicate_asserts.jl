# Bennett-p94b / U110: defensive assertions in `_compute_block_pred!` and
# `_edge_predicate!`.
#
# Two structural invariants must hold for the path-predicate machinery to
# be sound (CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS RISK"):
#
# 1. A block's predecessor list MUST contain distinct labels — duplicate
#    predecessors would OR-fold the same predicate twice, breaking the
#    "exactly one fires" guarantee that `resolve_phi_predicated!` relies
#    on.
#
# 2. Every `block_pred[label]` is a SINGLE-bit wire (a 1-element
#    `Vector{Int}`). `_edge_predicate!` assumes this when it indexes
#    `block_pred[p][1]` indirectly via `_and_wire!`. A multi-bit
#    block_pred would silently use only bit 0.
#
# Pre-fix: neither invariant is enforced; a buggy caller produces silent
# corruption. Per CLAUDE.md §1 (fail loud, fail fast), invariant violations
# must crash with context.

using Test
using Bennett
using Bennett: WireAllocator, ReversibleGate, _compute_block_pred!,
               _edge_predicate!, allocate!

@testset "Bennett-p94b / U110: predicate-machinery defensive asserts" begin

    @testset "T1: _compute_block_pred! errors on duplicate predecessors" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        # Build a tiny block_pred + preds dict with a duplicate predecessor.
        block_pred = Dict{Symbol,Vector{Int}}()
        block_pred[:A] = allocate!(wa, 1)
        # :B has TWO incoming from :A — structurally invalid.
        preds = Dict{Symbol,Vector{Symbol}}(:B => [:A, :A])
        branch_info = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}()
        @test_throws ErrorException _compute_block_pred!(gates, wa, :B,
                                                         preds, branch_info,
                                                         block_pred)
    end

    @testset "T2: _edge_predicate! errors on multi-bit block_pred" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        # Allocate a 2-bit "predicate" — invalid; predicates are 1-bit.
        block_pred = Dict{Symbol,Vector{Int}}()
        block_pred[:A] = allocate!(wa, 2)
        branch_info = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}()
        @test_throws ErrorException _edge_predicate!(gates, wa, :A, :B,
                                                     block_pred, branch_info)
    end

    @testset "T3: _compute_block_pred! errors on multi-bit block_pred predecessor" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        block_pred = Dict{Symbol,Vector{Int}}()
        block_pred[:A] = allocate!(wa, 3)  # 3-bit "predicate" — invalid
        preds = Dict{Symbol,Vector{Symbol}}(:B => [:A])
        branch_info = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}()
        @test_throws ErrorException _compute_block_pred!(gates, wa, :B,
                                                         preds, branch_info,
                                                         block_pred)
    end

    @testset "T4: regression — happy path (well-formed CFG) still works" begin
        # Two distinct predecessors, both with 1-bit predicates, one
        # conditional, one unconditional. _compute_block_pred! should
        # return a 1-bit Vector{Int} representing OR of the contributions.
        gates = ReversibleGate[]
        wa = WireAllocator()
        block_pred = Dict{Symbol,Vector{Int}}()
        block_pred[:A] = allocate!(wa, 1)
        block_pred[:B] = allocate!(wa, 1)
        preds = Dict{Symbol,Vector{Symbol}}(:C => [:A, :B])
        # :A branches conditionally to :C (true side) and elsewhere
        cond_wire = allocate!(wa, 1)
        branch_info = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}(
            :A => (cond_wire, :C, :D))
        # :B branches unconditionally to :C
        result = _compute_block_pred!(gates, wa, :C, preds, branch_info, block_pred)
        @test length(result) == 1
        @test result[1] isa Int
    end

    @testset "T5: regression — _edge_predicate! happy path" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        block_pred = Dict{Symbol,Vector{Int}}()
        block_pred[:A] = allocate!(wa, 1)
        cond_wire = allocate!(wa, 1)
        branch_info = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}(
            :A => (cond_wire, :B, :C))
        # :A → :B is the true side
        result = _edge_predicate!(gates, wa, :A, :B, block_pred, branch_info)
        @test length(result) == 1
        @test result[1] isa Int
    end

    @testset "T6: end-to-end — diamond CFG still compiles + verifies" begin
        # Smoke test that the new asserts don't fire on real code.
        function _p94b_diamond(x::Int8)
            return x > Int8(0) ? x + Int8(1) : x - Int8(1)
        end
        c = reversible_compile(_p94b_diamond, Int8)
        for x in Int8(-5):Int8(5)
            @test simulate(c, x) == _p94b_diamond(x)
        end
        @test verify_reversibility(c; n_tests=8)
    end
end
