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

    in_set   = Set(lr.input_wires)
    out_set  = Set(copy_wires)
    ancillae = [w for w in 1:total if !(w in in_set) && !(w in out_set)]

    return ReversibleCircuit(total, all_gates, lr.input_wires, copy_wires,
                             ancillae, lr.input_widths, lr.output_elem_widths)
end
