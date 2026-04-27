@testset "Bennett-cklf / U128 — resolve! SSA-path width contract" begin

    # Pre-cklf: `resolve!` (src/lower.jl:195) silently discarded the caller's
    # `width` argument on the SSA path, returning `var_wires[op.name]`
    # regardless of length match. A downstream consumer that indexed into
    # the wire vector based on its expected width would either crash with
    # an opaque BoundsError or silently miscompile (using too few/too many
    # wires).
    #
    # Post-cklf: SSA path asserts `length(wires) == width` per CLAUDE.md §1.
    # Pointer-typed operands (width=0) are exempt — pointers carry no width.

    using Bennett: WireAllocator, allocate!, resolve!, ssa, IROperand

    @testset "matched width: returns wires unchanged" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        wires8 = allocate!(wa, 8)
        var_wires = Dict{Symbol, Vector{Int}}(:x => wires8)
        @test resolve!(gates, wa, var_wires, ssa(:x), 8) == wires8
    end

    @testset "width=0 pointer exemption" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        # Pointer SSA: any wire vector should be accepted at width=0.
        ptr_wires = allocate!(wa, 1)  # actual length doesn't matter for ptrs
        var_wires = Dict{Symbol, Vector{Int}}(:p => ptr_wires)
        @test resolve!(gates, wa, var_wires, ssa(:p), 0) == ptr_wires
    end

    @testset "mismatched width: precise error" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        wires8 = allocate!(wa, 8)
        var_wires = Dict{Symbol, Vector{Int}}(:x => wires8)
        # Caller advertises width=16 but x has 8 wires.
        err = try
            resolve!(gates, wa, var_wires, ssa(:x), 16); ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("cklf", err)
        @test occursin("length(wires)=8", err)
        @test occursin("width=16", err)
    end

    @testset "undefined SSA still fails first" begin
        # The undefined-SSA error must precede the length check
        # (otherwise we'd get a KeyError instead of a precise message).
        gates = ReversibleGate[]
        wa = WireAllocator()
        var_wires = Dict{Symbol, Vector{Int}}()
        err = try
            resolve!(gates, wa, var_wires, ssa(:nope), 8); ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("undefined SSA variable", err)
        @test occursin("nope", err)
    end
end
