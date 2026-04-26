# Bennett-fq8n / U84: validate phi mixed-width incoming at lower time.
#
# IRPhi's struct constructor (src/ir_types.jl:221-228) already validates
# `width >= 0` and `!isempty(incoming)`. The remaining gap: an SSA
# incoming whose `vw[name]` width disagrees with the phi's declared
# width is silently propagated by `resolve!`, then breaks downstream in
# `resolve_phi_predicated!` (or worse, silently uses the wrong width).
#
# Per CLAUDE.md §1 (fail loud), `lower_phi!` must assert width
# consistency after resolving each incoming.

using Test
using Bennett
using Bennett: WireAllocator, ReversibleGate, IRPhi, IROperand,
               lower_phi!, allocate!

@testset "Bennett-fq8n / U84: phi mixed-width incoming validation" begin

    @testset "T1: lower_phi! errors on mixed SSA widths" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        # %a is 8 bits in vw; %b is 16 bits.
        vw[:a] = allocate!(wa, 8)
        vw[:b] = allocate!(wa, 16)
        # Phi declared width=8; one incoming has width 16 — mismatch.
        phi = IRPhi(:dest, 8,
                    Tuple{IROperand,Symbol}[
                        (IROperand(:ssa, :a, 0), :BlockA),
                        (IROperand(:ssa, :b, 0), :BlockB),
                    ])
        # Set up minimal block_pred so resolve_phi_predicated! is reached.
        block_pred = Dict{Symbol,Vector{Int}}()
        block_pred[:BlockA] = allocate!(wa, 1)
        block_pred[:BlockB] = allocate!(wa, 1)
        branch_info = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}()
        preds = Dict{Symbol,Vector{Symbol}}()
        block_order = Dict{Symbol,Int}(:BlockA => 1, :BlockB => 2,
                                       :PhiBlock => 3)
        @test_throws ErrorException lower_phi!(gates, wa, vw, phi, :PhiBlock,
                                               preds, branch_info, block_order;
                                               block_pred=block_pred)
    end

    @testset "T2: lower_phi! errors when SSA width is too narrow" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        vw[:a] = allocate!(wa, 4)   # narrower than phi width
        vw[:b] = allocate!(wa, 8)
        phi = IRPhi(:dest, 8,
                    Tuple{IROperand,Symbol}[
                        (IROperand(:ssa, :a, 0), :BlockA),
                        (IROperand(:ssa, :b, 0), :BlockB),
                    ])
        block_pred = Dict{Symbol,Vector{Int}}()
        block_pred[:BlockA] = allocate!(wa, 1)
        block_pred[:BlockB] = allocate!(wa, 1)
        @test_throws ErrorException lower_phi!(gates, wa, vw, phi, :PhiBlock,
                                               Dict{Symbol,Vector{Symbol}}(),
                                               Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}(),
                                               Dict{Symbol,Int}();
                                               block_pred=block_pred)
    end

    @testset "T3: regression — well-formed phi still lowers" begin
        # Both SSA incoming have width 8, matching the phi's declared
        # width 8. Must succeed.
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        vw[:a] = allocate!(wa, 8)
        vw[:b] = allocate!(wa, 8)
        phi = IRPhi(:dest, 8,
                    Tuple{IROperand,Symbol}[
                        (IROperand(:ssa, :a, 0), :BlockA),
                        (IROperand(:ssa, :b, 0), :BlockB),
                    ])
        block_pred = Dict{Symbol,Vector{Int}}()
        block_pred[:BlockA] = allocate!(wa, 1)
        block_pred[:BlockB] = allocate!(wa, 1)
        # Should NOT throw.
        lower_phi!(gates, wa, vw, phi, :PhiBlock,
                   Dict{Symbol,Vector{Symbol}}(),
                   Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}(),
                   Dict{Symbol,Int}();
                   block_pred=block_pred)
        @test haskey(vw, :dest)
        @test length(vw[:dest]) == 8
    end

    @testset "T4: end-to-end — diamond phi (well-formed) still compiles" begin
        # Smoke test that a real Julia function compiling to a phi works.
        f(x::Int8) = x > Int8(0) ? x + Int8(1) : x - Int8(1)
        c = reversible_compile(f, Int8)
        for x in Int8(-3):Int8(3)
            @test simulate(c, x) == f(x)
        end
        @test verify_reversibility(c; n_tests=8)
    end

end
