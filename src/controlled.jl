# ---- Controlled reversible circuits ----

struct ControlledCircuit
    circuit::ReversibleCircuit
    ctrl_wire::WireIndex
end

"""
    controlled(circuit::ReversibleCircuit) -> ControlledCircuit

Wrap every gate with a control bit: NOT→CNOT, CNOT→Toffoli,
Toffoli→decomposed controlled-Toffoli (3 Toffolis + 1 reusable ancilla).

Result: `(ctrl, x, 0) → (ctrl, x, ctrl ? f(x) : 0)`.
"""
function controlled(circuit::ReversibleCircuit)
    has_toff = any(g -> g isa ToffoliGate, circuit.gates)
    ctrl_wire = circuit.n_wires + 1
    anc_wire  = has_toff ? circuit.n_wires + 2 : 0
    n_extra   = 1 + (has_toff ? 1 : 0)

    new_gates = ReversibleGate[]
    sizehint!(new_gates, 3 * length(circuit.gates))  # upper bound
    for gate in circuit.gates
        promote_gate!(new_gates, gate, ctrl_wire, anc_wire)
    end

    total = circuit.n_wires + n_extra
    new_anc = copy(circuit.ancilla_wires)
    has_toff && push!(new_anc, anc_wire)

    inner = ReversibleCircuit(total, new_gates,
                              circuit.input_wires, circuit.output_wires,
                              new_anc, circuit.input_widths,
                              circuit.output_elem_widths)
    return ControlledCircuit(inner, ctrl_wire)
end

function promote_gate!(out, g::NOTGate, ctrl, _anc)
    push!(out, CNOTGate(ctrl, g.target))
end

function promote_gate!(out, g::CNOTGate, ctrl, _anc)
    push!(out, ToffoliGate(ctrl, g.control, g.target))
end

function promote_gate!(out, g::ToffoliGate, ctrl, anc)
    # controlled-Toffoli via 3 Toffolis + 1 shared ancilla
    push!(out, ToffoliGate(ctrl, g.control1, anc))     # anc = ctrl ∧ c1
    push!(out, ToffoliGate(anc, g.control2, g.target))  # target ⊻= anc ∧ c2
    push!(out, ToffoliGate(ctrl, g.control1, anc))     # uncompute anc
end

# ---- simulate for ControlledCircuit ----

function simulate(cc::ControlledCircuit, ctrl::Bool, input::Integer)
    length(cc.circuit.input_widths) == 1 || error("simulate(cc, ctrl, input) requires single-input circuit, got $(length(cc.circuit.input_widths)) inputs")
    return _simulate_ctrl(cc, ctrl, (input,))
end

function simulate(cc::ControlledCircuit, ctrl::Bool, inputs::Tuple{Vararg{Integer}})
    return _simulate_ctrl(cc, ctrl, inputs)
end

function _simulate_ctrl(cc::ControlledCircuit, ctrl::Bool, inputs::Tuple)
    c = cc.circuit
    bits = zeros(Bool, c.n_wires)
    bits[cc.ctrl_wire] = ctrl

    offset = 0
    for (k, w) in enumerate(c.input_widths)
        v = inputs[k]
        for i in 1:w
            bits[c.input_wires[offset + i]] = (v >> (i - 1)) & 1 == 1
        end
        offset += w
    end

    for gate in c.gates; apply!(bits, gate); end

    for w in c.ancilla_wires
        bits[w] && error("Ancilla wire $w not zero — controlled circuit bug")
    end
    bits[cc.ctrl_wire] == ctrl || error("Control wire changed from $ctrl to $(bits[cc.ctrl_wire])")

    return _read_output(bits, c.output_wires, c.output_elem_widths)
end

function verify_reversibility(cc::ControlledCircuit; n_tests::Int=100)
    c = cc.circuit
    for _ in 1:n_tests
        bits = zeros(Bool, c.n_wires)
        bits[cc.ctrl_wire] = rand(Bool)
        offset = 0
        for (_, w) in enumerate(c.input_widths)
            for i in 1:w
                bits[c.input_wires[offset + i]] = rand(Bool)
            end
            offset += w
        end
        orig = copy(bits)
        for g in c.gates; apply!(bits, g); end
        for g in Iterators.reverse(c.gates); apply!(bits, g); end
        bits == orig || error("Controlled reversibility check failed: $(sum(bits .!= orig)) wires differ")
    end
    return true
end
