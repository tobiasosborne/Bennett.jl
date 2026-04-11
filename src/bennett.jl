"""Compute ancilla wire list: all wires not in input or output sets."""
function _compute_ancillae(total::Int, input_wires, output_wires)
    in_set  = Set(input_wires)
    out_set = Set(output_wires)
    return [w for w in 1:total if !(w in in_set) && !(w in out_set)]
end

"""Build a ReversibleCircuit from gates, input/output wires, and metadata."""
function _build_circuit(all_gates::Vector{ReversibleGate}, total::Int,
                        input_wires::Vector{Int}, output_wires::Vector{Int},
                        lr::LoweringResult)
    ancillae = _compute_ancillae(total, input_wires, output_wires)
    return ReversibleCircuit(total, all_gates, input_wires, output_wires,
                             ancillae, lr.input_widths, lr.output_elem_widths)
end

"""
Bennett's 1973 construction: forward + copy-out + uncompute.

Tracks constant_wires from the lowering result for future optimization
(activity analysis, shared constant allocation).
"""
function bennett(lr::LoweringResult)
    n_out = length(lr.output_wires)
    copy_start = lr.n_wires + 1
    copy_wires = collect(copy_start:copy_start + n_out - 1)
    total = lr.n_wires + n_out

    all_gates = ReversibleGate[]
    sizehint!(all_gates, 2 * length(lr.gates) + n_out)

    append!(all_gates, lr.gates)
    for (i, w) in enumerate(lr.output_wires)
        push!(all_gates, CNOTGate(w, copy_wires[i]))
    end
    for i in length(lr.gates):-1:1
        push!(all_gates, lr.gates[i])
    end

    return _build_circuit(all_gates, total, lr.input_wires, copy_wires, lr)
end
