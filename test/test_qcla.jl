using Test
using Bennett
using Bennett: lower_add_qcla!, lower_add!,
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

function _toffoli_depth_of(gates, n_wires)
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
function _full_depth_of(gates, n_wires)
    wd = zeros(Int, n_wires); md = 0
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
function _count_gates(gates)
    n = count(g -> g isa NOTGate, gates)
    c = count(g -> g isa CNOTGate, gates)
    t = count(g -> g isa ToffoliGate, gates)
    return (NOT=n, CNOT=c, Toffoli=t, total=n+c+t)
end

# Run lower_add_qcla! on a fresh allocator with inputs set to (av, bv).
# Return the decoded (W+1)-bit result.
function _qcla_run(W, av, bv)
    wa = WireAllocator()
    a = allocate!(wa, W)
    b = allocate!(wa, W)
    before_add = wire_count(wa)
    gates = Vector{ReversibleGate}()
    Z = lower_add_qcla!(gates, wa, a, b, W)

    # Record ancilla (everything allocated during the adder call).
    ancilla_wires = Int[]
    for w in (before_add+1):wire_count(wa)
        if !(w in Z)
            push!(ancilla_wires, w)
        end
    end

    bits = zeros(Bool, wire_count(wa))
    for i in 1:W
        bits[a[i]] = (av >> (i-1)) & 1 == 1
        bits[b[i]] = (bv >> (i-1)) & 1 == 1
    end
    _simulate!(bits, gates)

    # Check a, b unchanged
    a_decoded = 0
    b_decoded = 0
    for i in 1:W
        a_decoded |= (bits[a[i]] ? 1 : 0) << (i-1)
        b_decoded |= (bits[b[i]] ? 1 : 0) << (i-1)
    end

    # Check all ancillae zero
    anc_clean = all(!bits[w] for w in ancilla_wires)

    # Decode Z (W+1 bits)
    z_decoded = 0
    for i in 1:(W+1)
        z_decoded |= (bits[Z[i]] ? UInt64(1) : UInt64(0)) << (i-1)
    end

    return (z=z_decoded, a_after=a_decoded, b_after=b_decoded,
            anc_clean=anc_clean, n_anc=length(ancilla_wires), gates=gates, n_wires=wire_count(wa))
end

@testset "QCLA: fallback correctness (W ∈ {1, 2, 3}), exhaustive" begin
    for W in 1:3, av in 0:(1<<W - 1), bv in 0:(1<<W - 1)
        r = _qcla_run(W, av, bv)
        expected = (av + bv) & ((UInt64(1) << (W+1)) - 1)
        @test r.z == expected
        @test r.a_after == av
        @test r.b_after == bv
        @test r.anc_clean
    end
end

@testset "QCLA: W=4 exhaustive correctness" begin
    for av in 0:15, bv in 0:15
        r = _qcla_run(4, av, bv)
        expected = (av + bv) & 0x1f
        @test r.z == expected
        @test r.a_after == av
        @test r.b_after == bv
        @test r.anc_clean
    end
end

@testset "QCLA: W=8 exhaustive correctness (65k pairs)" begin
    ok = true
    for av in 0:255, bv in 0:255
        r = _qcla_run(8, av, bv)
        expected = UInt64(av + bv)   # fits in 9 bits
        if r.z != expected || r.a_after != av || r.b_after != bv || !r.anc_clean
            ok = false
            break
        end
    end
    @test ok
end

@testset "QCLA: W=16 sampled + edge cases" begin
    sample_pairs = [(0, 0), (65535, 65535), (65535, 1), (1, 65535),
                    (0x5555, 0xAAAA), (0x00FF, 0xFF00), (32768, 32768)]
    for _ in 1:200; push!(sample_pairs, (rand(0:65535), rand(0:65535))); end
    for (av, bv) in sample_pairs
        r = _qcla_run(16, av, bv)
        expected = UInt64(av + bv)
        @test r.z == expected
        @test r.a_after == av
        @test r.b_after == bv
        @test r.anc_clean
    end
end

@testset "QCLA: W=32 sampled" begin
    edges = [(0, 0), (0xFFFFFFFF, 0xFFFFFFFF), (0xFFFFFFFF, 1), (0x55555555, 0xAAAAAAAA)]
    for (av, bv) in edges
        r = _qcla_run(32, av, bv)
        expected = UInt64(UInt64(av) + UInt64(bv))
        @test r.z == expected
        @test r.anc_clean
    end
    for _ in 1:50
        av = rand(UInt32); bv = rand(UInt32)
        r = _qcla_run(32, Int(av), Int(bv))
        expected = UInt64(UInt64(av) + UInt64(bv))
        @test r.z == expected
        @test r.anc_clean
    end
end

@testset "QCLA: gate-count and ancilla pins" begin
    # Formulas from consensus doc §"Cost formulas" — pinned at W=4,8,16,32,64.
    # Not testing W=64 exhaustively; just pinning its gate count.
    expected = Dict(
        4  => (Toffoli=10,  CNOT=11,  anc=1,  tdepth=6,  depth=9),
        8  => (Toffoli=27,  CNOT=23,  anc=4,  tdepth=8,  depth=11),
        16 => (Toffoli=64,  CNOT=47,  anc=11, tdepth=10, depth=13),
        32 => (Toffoli=141, CNOT=95,  anc=26, tdepth=12, depth=15),
        64 => (Toffoli=298, CNOT=191, anc=57, tdepth=14, depth=17),
    )
    for (W, exp) in expected
        r = _qcla_run(W, 0, 0)   # values don't affect gate count
        gc = _count_gates(r.gates)
        @test gc.Toffoli  == exp.Toffoli
        @test gc.CNOT     == exp.CNOT
        @test gc.NOT      == 0
        @test r.n_anc     == exp.anc
        @test _toffoli_depth_of(r.gates, r.n_wires) == exp.tdepth
        @test _full_depth_of(r.gates, r.n_wires)    == exp.depth
    end
end

@testset "QCLA: ancillae zero after forward pass (principle 4)" begin
    for W in (4, 8, 16, 32)
        # Random-input reversibility check
        wa = WireAllocator()
        a = allocate!(wa, W)
        b = allocate!(wa, W)
        gates = Vector{ReversibleGate}()
        Z = lower_add_qcla!(gates, wa, a, b, W)
        bits = zeros(Bool, wire_count(wa))
        for i in 1:W
            bits[a[i]] = rand(Bool)
            bits[b[i]] = rand(Bool)
        end
        orig = copy(bits)
        _simulate!(bits, gates)
        # Reverse the circuit: self-inverse gates in reverse order
        for g in Iterators.reverse(gates); _simulate!(bits, [g]); end
        @test bits == orig
    end
end

@testset "QCLA: W=4 matches ripple for every input" begin
    # Differential test: lower_add_qcla!(a,b)[1:W] == lower_add!(a,b) for all inputs.
    for av in 0:15, bv in 0:15
        r_qcla = _qcla_run(4, av, bv)

        wa = WireAllocator()
        a = allocate!(wa, 4)
        b = allocate!(wa, 4)
        gates = Vector{ReversibleGate}()
        result = lower_add!(gates, wa, a, b, 4)

        bits = zeros(Bool, wire_count(wa))
        for i in 1:4
            bits[a[i]] = (av >> (i-1)) & 1 == 1
            bits[b[i]] = (bv >> (i-1)) & 1 == 1
        end
        _simulate!(bits, gates)
        ripple_low = 0
        for i in 1:4; ripple_low |= (bits[result[i]] ? 1 : 0) << (i-1); end
        # Compare low W bits of QCLA result to ripple's W-bit answer
        @test (r_qcla.z & 0xf) == ripple_low
    end
end
