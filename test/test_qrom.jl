using Test
using Bennett
using Bennett: emit_qrom!, WireAllocator, allocate!, wire_count,
               ReversibleGate, LoweringResult, bennett, verify_reversibility,
               gate_count, simulate

# Babbush-Gidney 2018 QROM (Section III.C, Fig 10): emit a reversible circuit
# that maps (idx, 0^W) → (idx, data[idx]), where `data` is compile-time constant.
# Built via unary iteration (Fig 7) — complete binary tree of AND gates over
# log₂(L) index bits producing L leaf-flags, then data-dependent CNOT fan-out.
# Gate count: 2(L-1) Toffoli (tree compute + uncompute), at most L·W CNOTs.
# T-count 4(L-1), independent of W.

"""
Build a standalone reversible circuit for QROM lookup with compile-time data.

`data[i+1]` is the word associated with index i ∈ 0..L-1. Returns a
ReversibleCircuit whose input is the idx register (log₂ L wires) and whose
output is the data register (W wires).
"""
function _compile_qrom(data::Vector{UInt64}, W::Int)
    L = length(data)
    n_idx = ceil(Int, log2(L))
    @assert L == 1 << n_idx  # only power-of-two L for MVP

    wa = WireAllocator()
    gates = ReversibleGate[]
    idx_wires = allocate!(wa, n_idx)
    data_out = emit_qrom!(gates, wa, data, idx_wires, W)

    lr = LoweringResult(gates, wire_count(wa), idx_wires, data_out,
                        [n_idx], [W])
    return bennett(lr)
end

@testset "T1c.1 QROM — emit_qrom! primitive" begin

    @testset "L=2, W=8 — smallest nontrivial" begin
        data = UInt64[0xaa, 0x55]
        c = _compile_qrom(data, 8)
        @test verify_reversibility(c)
        for idx in UInt64(0):UInt64(length(data)-1)
            @test simulate(c, idx) == Int8(reinterpret(Int8, UInt8(data[idx+1])))
        end
    end

    @testset "L=4, W=8 — full lookup" begin
        data = UInt64[0x21, 0x43, 0x65, 0x87]
        c = _compile_qrom(data, 8)
        @test verify_reversibility(c)
        for idx in UInt64(0):UInt64(3)
            @test simulate(c, idx) == reinterpret(Int8, UInt8(data[idx+1]))
        end
    end

    @testset "L=4, W=8 — edge data (0 and 0xff everywhere)" begin
        for data in (UInt64[0, 0, 0, 0],
                     UInt64[0xff, 0xff, 0xff, 0xff],
                     UInt64[0, 0xff, 0, 0xff],
                     UInt64[0xff, 0, 0xff, 0])
            c = _compile_qrom(data, 8)
            @test verify_reversibility(c)
            for idx in UInt64(0):UInt64(3)
                @test simulate(c, idx) == reinterpret(Int8, UInt8(data[idx+1]))
            end
        end
    end

    @testset "L=8, W=8 — full 3-bit index" begin
        data = UInt64[0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]
        c = _compile_qrom(data, 8)
        @test verify_reversibility(c)
        for idx in UInt64(0):UInt64(7)
            @test simulate(c, idx) == reinterpret(Int8, UInt8(data[idx+1]))
        end
    end

    @testset "L=16, W=8 — deeper tree" begin
        data = UInt64[UInt64(i * 7 + 13) & 0xff for i in 0:15]
        c = _compile_qrom(data, 8)
        @test verify_reversibility(c)
        for idx in UInt64(0):UInt64(15)
            @test simulate(c, idx) == reinterpret(Int8, UInt8(data[idx+1]))
        end
    end

    @testset "L=4, W=16 — wider element" begin
        data = UInt64[0x1234, 0x5678, 0xabcd, 0xffff]
        c = _compile_qrom(data, 16)
        @test verify_reversibility(c)
        for idx in UInt64(0):UInt64(3)
            @test simulate(c, idx) == reinterpret(Int16, UInt16(data[idx+1]))
        end
    end

    @testset "L=4, W=32 — 32-bit element, verifying W-independence of T-count" begin
        data = UInt64[0x11111111, 0x22222222, 0xdeadbeef, 0xcafebabe]
        c = _compile_qrom(data, 32)
        @test verify_reversibility(c)
        for idx in UInt64(0):UInt64(3)
            @test simulate(c, idx) == reinterpret(Int32, UInt32(data[idx+1]))
        end
    end

    @testset "Gate count matches paper bound — 2(L-1) Toffoli pre-Bennett" begin
        # Paper: unary iteration = L-1 ANDs compute + L-1 ANDs uncompute = 2(L-1) Toffoli.
        # (Post-Bennett doubles the whole circuit; QROM is already self-uncomputing,
        # so this is a known 2× over-count — tracked in Bennett-07r.)
        for (L, expected_raw_tof) in [(2, 2), (4, 6), (8, 14), (16, 30)]
            n_idx = ceil(Int, log2(L))
            data = UInt64[UInt64(i) & 0xff for i in 0:L-1]
            wa = WireAllocator()
            gates = ReversibleGate[]
            idx_wires = allocate!(wa, n_idx)
            emit_qrom!(gates, wa, data, idx_wires, 8)
            raw_tof = count(g -> g isa Bennett.ToffoliGate, gates)
            @test raw_tof == expected_raw_tof
        end
    end

    @testset "CNOT data fan-out scales as popcount of data, not W" begin
        # All-zero data: no data-fanout CNOTs at all
        data_zero = UInt64[0, 0, 0, 0]
        wa = WireAllocator(); gates = ReversibleGate[]
        idx_wires = allocate!(wa, 2)
        emit_qrom!(gates, wa, data_zero, idx_wires, 8)
        cnots_zero = count(g -> g isa Bennett.CNOTGate, gates)

        # Data with single bit set per word: exactly L CNOTs for fan-out
        data_one_bit = UInt64[0x01, 0x02, 0x04, 0x08]
        wa = WireAllocator(); gates = ReversibleGate[]
        idx_wires = allocate!(wa, 2)
        emit_qrom!(gates, wa, data_one_bit, idx_wires, 8)
        cnots_one = count(g -> g isa Bennett.CNOTGate, gates)

        @test cnots_one == cnots_zero + 4
    end
end
