using Test
using Bennett
using Bennett: LoweringResult, GateGroup, bennett, lower_mul_qcla_tree!,
    WireAllocator, allocate!, wire_count,
    ReversibleGate, CNOTGate, ToffoliGate, NOTGate

# Build a LoweringResult wrapping the given gate list, input/output wires
# and the optional self_reversing flag.
function _mk_lr(gates, n_wires, input_wires, output_wires, input_widths, output_elem_widths;
                self_reversing::Bool=false)
    return LoweringResult(gates, n_wires, input_wires, output_wires,
                          input_widths, output_elem_widths,
                          GateGroup[], self_reversing)
end

@testset "P1: self_reversing=false keeps current Bennett wrap (gate count doubles)" begin
    # A tiny 1-gate LR. With the standard Bennett wrap: forward (1 gate) +
    # copy-out (n_out CNOTs) + reverse (1 gate) = 2 + n_out total gates.
    gates = ReversibleGate[ToffoliGate(1, 2, 3)]
    lr = _mk_lr(gates, 3, [1, 2], [3], [1, 1], [1]; self_reversing=false)
    c = bennett(lr)
    @test length(c.gates) == 2 + 1  # 2 copies of the Toffoli + 1 copy-out CNOT
    @test c.n_wires == 4            # 3 + 1 copy register
    @test c.output_wires != [3]     # output is the COPY wire, not the original
end

@testset "P1: self_reversing=true skips copy-out and reverse" begin
    gates = ReversibleGate[ToffoliGate(1, 2, 3)]
    lr = _mk_lr(gates, 3, [1, 2], [3], [1, 1], [1]; self_reversing=true)
    c = bennett(lr)
    @test length(c.gates) == 1      # forward only
    @test c.gates[1] === gates[1]   # exact same gate, no extras
    @test c.n_wires == 3            # no copy register
    @test c.output_wires == [3]     # output IS the original result wire
end

@testset "P1: self_reversing halves gate count for lower_mul_qcla_tree!" begin
    # Build lr from lower_mul_qcla_tree! directly. With self_reversing=true,
    # bennett() returns forward-only; with false, the full Bennett wrap
    # emits forward + copy-out + reverse, ~2× gates.
    W = 4
    wa = WireAllocator()
    a = allocate!(wa, W); b = allocate!(wa, W)
    gates = Vector{ReversibleGate}()
    result = lower_mul_qcla_tree!(gates, wa, a, b, W)
    bare = length(gates)

    lr_sr  = _mk_lr(gates, wire_count(wa), vcat(a, b), result, [W, W], [2W]; self_reversing=true)
    lr_nsr = _mk_lr(gates, wire_count(wa), vcat(a, b), result, [W, W], [2W]; self_reversing=false)

    c_sr  = bennett(lr_sr)
    c_nsr = bennett(lr_nsr)

    @test length(c_sr.gates)  == bare
    @test length(c_nsr.gates) == 2 * bare + length(result)   # 2× forward + copy-out
    @test verify_reversibility(c_sr)
    @test verify_reversibility(c_nsr)
end

@testset "P1: backward compat — LoweringResult without self_reversing defaults to false" begin
    # Construct LoweringResult via the 6-arg convenience (no gate_groups,
    # no self_reversing). The Bennett wrap should behave as pre-P1.
    gates = ReversibleGate[CNOTGate(1, 2)]
    lr6 = LoweringResult(gates, 2, [1], [2], [1], [1])
    c6 = bennett(lr6)
    @test length(c6.gates) == 2 + 1  # 2 CNOTs + 1 copy-out = standard wrap
end
