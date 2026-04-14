using Test
using Bennett
using Bennett: emit_conditional_copy!, emit_partial_products!, emit_fast_copy!,
    WireAllocator, allocate!, wire_count, ReversibleGate, CNOTGate, ToffoliGate, NOTGate

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

function _toffoli_depth(gates, n_wires)
    wd = zeros(Int, n_wires); md = 0
    for g in gates
        g isa ToffoliGate || continue
        ws = (g.control1, g.control2, g.target)
        d = maximum(wd[w] for w in ws) + 1
        for w in ws; wd[w] = d; end
        md = max(md, d)
    end
    return md
end

# Load a W-bit integer into wires.
function _load!(bits, reg, val, W)
    for i in 1:W; bits[reg[i]] = (val >> (i-1)) & 1 == 1; end
end
# Decode W-bit integer from wires.
function _decode(bits, reg, W)
    v = 0
    for i in 1:W; v |= (bits[reg[i]] ? 1 : 0) << (i-1); end
    return v
end

@testset "conditional_copy: single partial product y_i·x (W=8, exhaustive)" begin
    for x in 0:255, yi in 0:1
        wa = WireAllocator()
        # Lay out: x (8), y_i_copies (8 — all copies of the single y_i bit), target (8)
        x_wires   = allocate!(wa, 8)
        y_copies  = allocate!(wa, 8)
        target    = allocate!(wa, 8)

        gates = Vector{ReversibleGate}()
        emit_conditional_copy!(gates, wa, y_copies, x_wires, target, 8)

        bits = zeros(Bool, wire_count(wa))
        _load!(bits, x_wires, x, 8)
        for w in y_copies; bits[w] = (yi == 1); end
        _simulate!(bits, gates)

        expected = (yi == 1 ? x : 0) & 0xff
        @test _decode(bits, target, 8) == expected
        # Gate shape
        @test all(g -> g isa ToffoliGate, gates)
        @test length(gates) == 8
    end
end

@testset "conditional_copy: Toffoli-depth 1" begin
    wa = WireAllocator()
    x_wires  = allocate!(wa, 8)
    y_copies = allocate!(wa, 8)
    target   = allocate!(wa, 8)
    gates = Vector{ReversibleGate}()
    emit_conditional_copy!(gates, wa, y_copies, x_wires, target, 8)
    @test _toffoli_depth(gates, wire_count(wa)) == 1
end

@testset "partial_products: all n² Toffolis in one Toffoli layer (W=4 exhaustive)" begin
    for x in 0:15, y in 0:15
        wa = WireAllocator()
        # Use fast_copy to make n copies of x and n copies of each y_i bit.
        x_src = allocate!(wa, 4)
        y_src = allocate!(wa, 4)

        gates = Vector{ReversibleGate}()
        x_copies = emit_fast_copy!(gates, wa, x_src, 4, 4)   # 4 copies of the 4-bit x

        # For y bits: need n copies of each bit y_i. We make n copies of y,
        # then pick the i-th bit from each copy — but that's equivalent to
        # broadcasting each y_i across 4 ancilla bits. Simpler: broadcast
        # each bit of y into its own length-4 register of copies.
        y_bit_copies = Vector{Vector{Int}}()
        for i in 1:4
            yi_reg = allocate!(wa, 4)  # 4 copies of y_i
            for k in 1:4
                push!(gates, CNOTGate(y_src[i], yi_reg[k]))
            end
            push!(y_bit_copies, yi_reg)
        end

        n_gates_before_pp = length(gates)
        pp_list = emit_partial_products!(gates, wa, y_bit_copies, x_copies, 4)
        n_pp_gates = length(gates) - n_gates_before_pp

        # Exact gate count for partial_products stage
        @test n_pp_gates == 16        # n^2 Toffolis
        @test all(g -> g isa ToffoliGate, gates[n_gates_before_pp+1:end])
        @test length(pp_list) == 4

        bits = zeros(Bool, wire_count(wa))
        _load!(bits, x_src, x, 4)
        _load!(bits, y_src, y, 4)
        _simulate!(bits, gates)

        for i in 1:4
            yi = (y >> (i-1)) & 1
            expected = (yi == 1 ? x : 0) & 0xf
            @test _decode(bits, pp_list[i], 4) == expected
        end

        # Check Toffoli-depth of JUST the partial_products stage
        pp_only = gates[n_gates_before_pp+1:end]
        @test _toffoli_depth(pp_only, wire_count(wa)) == 1
    end
end
