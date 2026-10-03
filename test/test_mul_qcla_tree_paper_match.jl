using Test
using Bennett
using Bennett: lower_mul_qcla_tree!, WireAllocator, allocate!, wire_count,
    ReversibleGate, CNOTGate, ToffoliGate, NOTGate

# Sun-Borissov 2026 Table III formulas for the full multiplier:
#   Depth         = 3 log²n + 17 log n + 20
#   Toffoli-depth = 3 log²n +  7 log n + 14
#   Toffoli count = 12n² − n log n
#   Total gates   = 26n² + 2n log n
#   Ancilla       = 3n²

_logn(W) = W <= 1 ? 0 : Int(floor(log2(W)))

_paper_total(W) = let L = _logn(W); 26 * W^2 + 2 * W * L end
_paper_tof(W)   = let L = _logn(W); 12 * W^2 - W * L end
_paper_tdep(W)  = let L = _logn(W); 3 * L^2 + 7 * L + 14 end
_paper_depth(W) = let L = _logn(W); 3 * L^2 + 17 * L + 20 end
_paper_anc(W)   = 3 * W^2

function _measure(W)
    wa = WireAllocator()
    a = allocate!(wa, W); b = allocate!(wa, W)
    gates = Vector{ReversibleGate}()
    lower_mul_qcla_tree!(gates, wa, a, b, W)
    nw = wire_count(wa)

    wd = zeros(Int, nw); md = 0
    for g in gates
        ws = g isa NOTGate ? (g.target,) : g isa CNOTGate ? (g.control, g.target) : (g.control1, g.control2, g.target)
        d = maximum(wd[w] for w in ws) + 1
        for w in ws; wd[w] = d; end
        md = max(md, d)
    end
    fd = md

    wd .= 0; md = 0
    for g in gates
        # Bennett-u3b2: NOT/CNOT carry the dependency, only Toffolis add depth.
        ws = Bennett.gate_wires(g)
        d = maximum(wd[w] for w in ws) + (g isa ToffoliGate ? 1 : 0)
        for w in ws; wd[w] = d; end
        md = max(md, d)
    end
    td = md

    return (
        total = length(gates),
        Toffoli = count(g -> g isa ToffoliGate, gates),
        tof_depth = td,
        depth = fd,
        anc = nw - 3W,
    )
end

@testset "X3: resource costs match Sun-Borissov Table III within tolerance" begin
    # Total gates and Toffoli count: paper formulas are tight; we should be
    # within 15% for n >= 8. (W=8 Toffoli is ~10% low; tighter at W=16/32.)
    for W in (8, 16, 32)
        m = _measure(W)
        @test abs(m.total - _paper_total(W)) / _paper_total(W) < 0.15
        @test abs(m.Toffoli - _paper_tof(W)) / _paper_tof(W) < 0.15
    end
end

@testset "X3: depth within 30% of paper formula" begin
    # Depth formula is an upper bound from paper's Schedule B interleaving.
    # Our emission-order depth walks per-wire dependencies strictly, so we
    # often beat the paper's formula. Allow up to 30% above.
    for W in (8, 16, 32)
        m = _measure(W)
        @test m.depth < 1.3 * _paper_depth(W)
    end
end

@testset "X3: Toffoli-depth within 10% of paper formula" begin
    # Paper's 3 log²n + 7 log n + 14 formula assumes Schedule B time-slicing.
    # Bennett-u3b2: this testset used to claim "beats paper, ratio < 0.5"
    # (measured 20/24/28), but the metric skipped CNOTs and so dropped every
    # dependency carried through a CNOT copy. Propagating through all gates
    # gives 56/88/128 vs paper 62/90/124 (ratio 0.90/0.98/1.03).
    for W in (8, 16, 32)
        m = _measure(W)
        @test m.tof_depth < 1.1 * _paper_tdep(W)
    end
end

@testset "X3: ancilla within 3× of paper (unoptimized impl)" begin
    # Paper's 3n² bound requires Schedule-B ancilla recycling via the
    # mid-algorithm fast_copy swap (Algorithm 3 steps 3, 5) + parallel_adder_tree
    # pool recycling. Our X1 assembly skips both — expected ~2.4n² above paper.
    for W in (8, 16, 32)
        m = _measure(W)
        @test m.anc < 3 * _paper_anc(W)
    end
end
