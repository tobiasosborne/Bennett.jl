using Test
using Bennett
using Bennett: emit_parallel_adder_tree!, emit_fast_copy!, emit_partial_products!,
    WireAllocator, allocate!, wire_count,
    ReversibleGate, CNOTGate, ToffoliGate, NOTGate

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

function _load!(bits, reg, val, W)
    for i in 1:W; bits[reg[i]] = (val >> (i-1)) & 1 == 1; end
end
function _decode(bits, reg)
    v = UInt64(0)
    for i in 1:length(reg); v |= (bits[reg[i]] ? UInt64(1) : UInt64(0)) << (i-1); end
    return v
end

# Compose full multiplier for testing: fast_copy of x and each y_i, then
# partial_products, then parallel_adder_tree. This drives A2's correctness
# via the same data flow as the final X1 assembly (minus uncompute).
function _mul_via_tree(W, xv, yv)
    wa = WireAllocator()
    x_src = allocate!(wa, W)
    y_src = allocate!(wa, W)

    gates = Vector{ReversibleGate}()
    x_copies = emit_fast_copy!(gates, wa, x_src, W, W)

    y_bit_copies = Vector{Vector{Int}}()
    for i in 1:W
        yi_reg = allocate!(wa, W)
        for k in 1:W
            push!(gates, CNOTGate(y_src[i], yi_reg[k]))
        end
        push!(y_bit_copies, yi_reg)
    end

    pp = emit_partial_products!(gates, wa, y_bit_copies, x_copies, W)
    result = emit_parallel_adder_tree!(gates, wa, pp, W)

    bits = zeros(Bool, wire_count(wa))
    _load!(bits, x_src, xv, W)
    _load!(bits, y_src, yv, W)
    _simulate!(bits, gates)

    return _decode(bits, result)
end

@testset "parallel_adder_tree: W=1 trivial" begin
    # For W=1, xy is 1-bit; the tree has nothing to do except pass pp[1] through.
    for x in 0:1, y in 0:1
        @test _mul_via_tree(1, x, y) == UInt64(x * y)
    end
end

@testset "parallel_adder_tree: W=2 correctness (exhaustive)" begin
    for x in 0:3, y in 0:3
        got = _mul_via_tree(2, x, y)
        @test got == UInt64(x * y)
    end
end

@testset "parallel_adder_tree: W=4 correctness (exhaustive, 256 pairs)" begin
    for x in 0:15, y in 0:15
        got = _mul_via_tree(4, x, y)
        @test got == UInt64(x * y)
    end
end

@testset "parallel_adder_tree: W=8 correctness (sampled, random + edges)" begin
    # Use Int arithmetic for expected values — UInt8*UInt8 wraps mod 256,
    # but the tree produces the full (2W)-bit mathematical product.
    edges = [(0,0), (255,255), (255,1), (1,255), (85, 170), (128,128), (0, 255)]
    for (x, y) in edges
        @test _mul_via_tree(8, x, y) == UInt64(Int(x) * Int(y))
    end
    for _ in 1:50
        x = rand(0:255); y = rand(0:255)
        @test _mul_via_tree(8, x, y) == UInt64(Int(x) * Int(y))
    end
end

@testset "parallel_adder_tree: return register is 2W wires" begin
    wa = WireAllocator()
    x_src = allocate!(wa, 4)
    y_src = allocate!(wa, 4)
    gates = Vector{ReversibleGate}()
    x_copies = emit_fast_copy!(gates, wa, x_src, 4, 4)
    y_bit_copies = Vector{Vector{Int}}()
    for i in 1:4
        yi_reg = allocate!(wa, 4)
        for k in 1:4; push!(gates, CNOTGate(y_src[i], yi_reg[k])); end
        push!(y_bit_copies, yi_reg)
    end
    pp = emit_partial_products!(gates, wa, y_bit_copies, x_copies, 4)
    result = emit_parallel_adder_tree!(gates, wa, pp, 4)
    @test length(result) == 8
end

@testset "parallel_adder_tree: input partial products unchanged" begin
    # pp entries must be read-only: after emit_parallel_adder_tree!, the
    # values in the pp wires match what the partial_products stage produced.
    for x in (0, 5, 10, 15), y in (0, 3, 7, 15)
        wa = WireAllocator()
        x_src = allocate!(wa, 4); y_src = allocate!(wa, 4)
        gates = Vector{ReversibleGate}()
        x_copies = emit_fast_copy!(gates, wa, x_src, 4, 4)
        y_bit_copies = Vector{Vector{Int}}()
        for i in 1:4
            yi_reg = allocate!(wa, 4)
            for k in 1:4; push!(gates, CNOTGate(y_src[i], yi_reg[k])); end
            push!(y_bit_copies, yi_reg)
        end
        pp = emit_partial_products!(gates, wa, y_bit_copies, x_copies, 4)

        # Expected pp values after partial_products stage (α^{(0,i)} = y_i * x, 4 bits)
        expected_pp = [((y >> (i-1)) & 1) == 1 ? (x & 0xf) : 0 for i in 1:4]

        gates_before_tree = length(gates)
        emit_parallel_adder_tree!(gates, wa, pp, 4)

        bits = zeros(Bool, wire_count(wa))
        _load!(bits, x_src, x, 4); _load!(bits, y_src, y, 4)
        _simulate!(bits, gates)

        for i in 1:4
            @test _decode(bits, pp[i]) == UInt64(expected_pp[i])
        end
    end
end
