using Test
using Bennett
using Bennett: emit_fast_copy!, WireAllocator, allocate!, wire_count, ReversibleGate, CNOTGate, ToffoliGate, NOTGate

# Simulate a gate list on a given bit vector.
function _simulate!(bits::Vector{Bool}, gates::Vector{<:ReversibleGate})
    for g in gates
        if g isa CNOTGate
            bits[g.target] ⊻= bits[g.control]
        elseif g isa ToffoliGate
            bits[g.target] ⊻= bits[g.control1] & bits[g.control2]
        elseif g isa NOTGate
            bits[g.target] ⊻= true
        end
    end
    return bits
end

# Compute the max-layer depth of a gate list relative to a given wire count.
function _gate_list_depth(gates::Vector{<:ReversibleGate}, n_wires::Int)
    wd = zeros(Int, n_wires)
    md = 0
    for g in gates
        ws = g isa NOTGate    ? (g.target,) :
             g isa CNOTGate   ? (g.control, g.target) :
                                (g.control1, g.control2, g.target)
        d = maximum(wd[w] for w in ws) + 1
        for w in ws; wd[w] = d; end
        md = max(md, d)
    end
    return md
end

@testset "fast_copy: n_copies=1 is a no-op" begin
    wa = WireAllocator()
    src = allocate!(wa, 4)
    gates = Vector{ReversibleGate}()
    result = emit_fast_copy!(gates, wa, src, 1, 4)
    @test length(result) == 1
    @test result[1] == src
    @test isempty(gates)
end

@testset "fast_copy: n_copies=2, W=4 — one layer, 4 CNOTs" begin
    wa = WireAllocator()
    src = allocate!(wa, 4)
    gates = Vector{ReversibleGate}()
    result = emit_fast_copy!(gates, wa, src, 2, 4)
    @test length(result) == 2
    @test result[1] == src
    @test length(result[2]) == 4
    @test all(g -> g isa CNOTGate, gates)
    @test length(gates) == 4  # 1 copy × W CNOTs
    @test _gate_list_depth(gates, wire_count(wa)) == 1
end

@testset "fast_copy: n_copies=8, W=3 — 3 layers, 7*W CNOTs" begin
    wa = WireAllocator()
    src = allocate!(wa, 3)
    gates = Vector{ReversibleGate}()
    result = emit_fast_copy!(gates, wa, src, 8, 3)
    @test length(result) == 8
    @test all(g -> g isa CNOTGate, gates)
    @test length(gates) == 7 * 3   # 7 copies × W CNOTs
    @test _gate_list_depth(gates, wire_count(wa)) == 3  # ceil(log2(8))
end

@testset "fast_copy: correctness (exhaustive W=4, n=4)" begin
    for val in 0:15
        wa = WireAllocator()
        src = allocate!(wa, 4)
        gates = Vector{ReversibleGate}()
        result = emit_fast_copy!(gates, wa, src, 4, 4)

        # Set src to val, all copies start at 0
        bits = zeros(Bool, wire_count(wa))
        for i in 1:4; bits[src[i]] = (val >> (i-1)) & 1 == 1; end

        _simulate!(bits, gates)

        # Every copy should equal val
        for (j, reg) in enumerate(result)
            decoded = 0
            for i in 1:4; decoded |= (bits[reg[i]] ? 1 : 0) << (i-1); end
            @test decoded == val
        end
    end
end

@testset "fast_copy: n_copies=3 (non-power-of-2)" begin
    wa = WireAllocator()
    src = allocate!(wa, 4)
    gates = Vector{ReversibleGate}()
    result = emit_fast_copy!(gates, wa, src, 3, 4)
    @test length(result) == 3
    @test length(gates) == 2 * 4  # 2 copies × W CNOTs
    @test _gate_list_depth(gates, wire_count(wa)) == 2  # ceil(log2(3))

    # Correctness on one input
    bits = zeros(Bool, wire_count(wa))
    for i in 1:4; bits[src[i]] = (13 >> (i-1)) & 1 == 1; end
    _simulate!(bits, gates)
    for reg in result
        decoded = 0
        for i in 1:4; decoded |= (bits[reg[i]] ? 1 : 0) << (i-1); end
        @test decoded == 13
    end
end

@testset "fast_copy: T-depth is 0 (pure CNOT)" begin
    wa = WireAllocator()
    src = allocate!(wa, 8)
    gates = Vector{ReversibleGate}()
    emit_fast_copy!(gates, wa, src, 8, 8)
    @test !any(g -> g isa ToffoliGate, gates)
end
