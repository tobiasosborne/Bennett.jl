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

"""
    verify_reversibility(cc::ControlledCircuit; n_tests::Int=100) -> true

Verify Bennett's invariants on a controlled circuit across `n_tests` random
(ctrl, input) pairs. After running `cc.circuit.gates` forward, asserts:
  (1) every wire in `ancilla_wires` is zero;
  (2) every wire in `input_wires` holds its initial value;
  (3) `cc.ctrl_wire` holds its initial value (control must pass through
      unchanged);
  (4) the reverse pass restores the initial state.

Returns `true` on success; raises `ErrorException` with context on any
violation. Replaces an earlier tautological round-trip check. See
Bennett-asw2 / U01.
"""
function verify_reversibility(cc::ControlledCircuit; n_tests::Int=100)
    c = cc.circuit
    for t in 1:n_tests
        bits = zeros(Bool, c.n_wires)
        orig_ctrl = rand(Bool)
        bits[cc.ctrl_wire] = orig_ctrl
        offset = 0
        for w in c.input_widths
            for i in 1:w
                bits[c.input_wires[offset + i]] = rand(Bool)
            end
            offset += w
        end
        orig_input_values = [bits[w] for w in c.input_wires]
        orig = copy(bits)

        for g in c.gates; apply!(bits, g); end

        for w in c.ancilla_wires
            bits[w] && error("verify_reversibility[ctrl] (test $t): ancilla wire $w not zero after forward pass — Bennett ancilla-clean invariant violated")
        end

        for (k, w) in pairs(c.input_wires)
            bits[w] == orig_input_values[k] ||
                error("verify_reversibility[ctrl] (test $t): input wire $w changed from $(orig_input_values[k]) to $(bits[w]) — Bennett input-preservation violated")
        end

        bits[cc.ctrl_wire] == orig_ctrl ||
            error("verify_reversibility[ctrl] (test $t): control wire $(cc.ctrl_wire) changed from $orig_ctrl to $(bits[cc.ctrl_wire])")

        for g in Iterators.reverse(c.gates); apply!(bits, g); end
        bits == orig || error("verify_reversibility[ctrl] (test $t): $(sum(bits .!= orig)) wires differ after forward+reverse — self-consistency check failed")
    end
    return true
end
