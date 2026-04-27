using Test
using Bennett
using Bennett: LoweringResult, GateGroup, bennett, bennett_direct,
    ReversibleGate, NOTGate, CNOTGate, ToffoliGate, WireAllocator,
    allocate!, wire_count, emit_qrom!

# Bennett-cvnb / Sturm.jl-ao1 — surface the existing self_reversing
# fast path with a discoverable name `bennett_direct` so downstream
# library authors (Sturm.jl, future quantum backends) can construct
# self-cleaning primitives and assert the "no Bennett wrap" contract
# at the call site rather than buried in a constructor argument.
@testset "Bennett-cvnb / bennett_direct convenience entry point" begin

    # =========================================================================
    # 1. bennett_direct on a self_reversing=true lr produces the same
    #    circuit as bennett (which already short-circuits).
    # =========================================================================
    @testset "byte-identical to bennett(lr) when self_reversing=true" begin
        # QROM-style hand-built self-reversing circuit.
        gates = ReversibleGate[ToffoliGate(1, 2, 3)]
        lr = LoweringResult(gates, 3, [1, 2], [3], [1, 1], [1],
                            GateGroup[], true)   # self_reversing=true
        c1 = bennett(lr)
        c2 = bennett_direct(lr)
        @test length(c1.gates) == length(c2.gates)
        @test all(c1.gates[i] === c2.gates[i] for i in eachindex(c1.gates))
        @test c1.n_wires == c2.n_wires
        @test c1.input_wires  == c2.input_wires
        @test c1.output_wires == c2.output_wires
        @test verify_reversibility(c2)
    end

    # =========================================================================
    # 2. bennett_direct on a self_reversing=false lr raises ArgumentError
    #    with a precise message that points at the constructor + bennett
    #    fallback. Pre-cvnb the user got silent wrap (which Sturm.jl
    #    actually saw on N=15 Shor mulmod — 4× Toffoli + 6 ancillae).
    # =========================================================================
    @testset "raises ArgumentError on self_reversing=false" begin
        gates = ReversibleGate[CNOTGate(1, 2)]
        lr_not_sr = LoweringResult(gates, 2, [1], [2], [1], [1])  # 6-arg → defaults to false
        @test_throws ArgumentError bennett_direct(lr_not_sr)
        # Verify the message actually names the contract + alternative.
        err = try
            bennett_direct(lr_not_sr); nothing
        catch e; e
        end
        @test err isa ArgumentError
        @test occursin("self_reversing must be true", err.msg)
        @test occursin("bennett(lr)", err.msg)
        @test occursin("Bennett-cvnb", err.msg)
    end

    # =========================================================================
    # 3. The U03 probe battery (_validate_self_reversing!) still runs.
    #    A forged self_reversing circuit (dirty ancilla) MUST be rejected,
    #    matching the bennett(lr; self_reversing=true) contract from
    #    Bennett-egu6.
    # =========================================================================
    @testset "U03 probe rejects forged self_reversing claim" begin
        # NOTGate(3) flips an ancilla and never un-flips → dirty ancilla.
        gates = ReversibleGate[NOTGate(3)]
        lr_forged = LoweringResult(gates, 3, [1], [2], [1], [1],
                                   GateGroup[], true)   # FORGED
        @test_throws ErrorException bennett_direct(lr_forged)
    end

    # =========================================================================
    # 4. End-to-end QROM example matching the bead's expected impact:
    #    a real emit_qrom! lookup constructed self_reversing → fast path.
    # =========================================================================
    @testset "end-to-end QROM lookup via bennett_direct" begin
        W = 4
        n_idx = 2
        # 2^n_idx = 4-entry table.
        table = UInt64[3, 7, 11, 15]
        wa = WireAllocator()
        idx_wires = allocate!(wa, n_idx)
        gates = ReversibleGate[]
        out_wires = emit_qrom!(gates, wa, table, idx_wires, W)
        lr = LoweringResult(gates, wire_count(wa), idx_wires, out_wires,
                            [n_idx], [W],
                            GateGroup[], true)   # self_reversing=true
        c = bennett_direct(lr)
        @test verify_reversibility(c)
        # Every index produces the right table entry.
        for k in 0:3
            @test simulate(c, UInt8(k)) == Int8(table[k+1])
        end
        # Forward-only: gate count equals the raw lr.gates count, NOT 2× + n_out.
        @test length(c.gates) == length(lr.gates)
    end
end
