"""
EAGER cleanup for Bennett's construction (PRS15 Algorithm 2).

Phase 1: Forward gates. Dead-end wires (never used as control) are
eagerly cleaned immediately after their last modification.

Phase 2: CNOT copy outputs.

Phase 3: Reverse remaining forward gates in reverse gate-index order.
Gates targeting eagerly-cleaned wires are skipped (those wires are
already zero, and no remaining gate reads them as controls).
"""

"""
    compute_wire_mod_paths(gates) -> Dict{Int, Vector{Int}}

For each wire, collect the ordered list of gate indices that target it.
Reversing these gates in reverse order zeros the wire.
"""
function compute_wire_mod_paths(gates::Vector{ReversibleGate})
    paths = Dict{Int, Vector{Int}}()
    for (i, g) in enumerate(gates)
        t = _gate_target(g)
        push!(get!(paths, t, Int[]), i)
    end
    return paths
end

"""
    compute_wire_liveness(gates, output_wires, input_wires) -> Dict{Int, Int}

For each wire, compute the index of the last gate that reads it as a control.
Output wires get last_use = N+1 (survive until CNOT copy phase).
"""
function compute_wire_liveness(gates::Vector{ReversibleGate},
                               output_wires::Vector{Int},
                               input_wires::Vector{Int})
    N = length(gates)
    last_use = Dict{Int, Int}()
    for (i, g) in enumerate(gates)
        for c in _gate_controls(g)
            last_use[c] = i
        end
    end
    for w in output_wires
        last_use[w] = N + 1
    end
    return last_use
end

"""
    eager_bennett(lr::LoweringResult) -> ReversibleCircuit

Bennett construction with EAGER cleanup.
"""
function eager_bennett(lr::LoweringResult)
    gates = lr.gates
    N = length(gates)
    input_set  = Set(lr.input_wires)
    output_set = Set(lr.output_wires)

    mod_paths = compute_wire_mod_paths(gates)
    last_use  = compute_wire_liveness(gates, lr.output_wires, lr.input_wires)

    # Phase 1: Forward gates + clean dead-end wires.
    # A dead-end wire is never used as a control by ANY gate.
    # Safe to clean: no gate reads it, so no reversal needs its value.
    result = ReversibleGate[]
    sizehint!(result, 2 * N)
    eagerly_cleaned = Set{Int}()

    for (i, gate) in enumerate(gates)
        push!(result, gate)
        t = _gate_target(gate)

        # Is this the LAST gate targeting wire t, AND is t a dead-end?
        if !(t in output_set) && !(t in input_set) && !haskey(last_use, t)
            # Dead-end: never used as control. Check if this is the last mod.
            mp = get(mod_paths, t, Int[])
            if !isempty(mp) && mp[end] == i
                # Reverse the full mod path to zero wire t
                for gi in Iterators.reverse(mp)
                    push!(result, gates[gi])
                end
                push!(eagerly_cleaned, t)
            end
        end
    end

    # Phase 2: CNOT copy outputs to fresh wires
    n_out = length(lr.output_wires)
    copy_start = lr.n_wires + 1
    copy_wires = collect(copy_start:copy_start + n_out - 1)
    total = lr.n_wires + n_out

    for (j, w) in enumerate(lr.output_wires)
        push!(result, CNOTGate(w, copy_wires[j]))
    end

    # Phase 3: Reverse remaining forward gates in reverse index order.
    # Skip gates targeting eagerly-cleaned wires.
    for i in N:-1:1
        if !(_gate_target(gates[i]) in eagerly_cleaned)
            push!(result, gates[i])
        end
    end

    return _build_circuit(result, total, lr.input_wires, copy_wires, lr)
end


# NOTE: Wire-level EAGER (cleaning wires after last use as control) was
# attempted but FAILS: cleaned wires appear as zero to Phase 3 reverse
# gates that use them as controls, producing incorrect reversal. The
# existing dead-END cleanup (above) is correct because dead-end wires
# are never used as controls by ANY gate, so the Phase 3 reverse is
# unaffected. PRS15's EAGER works at the MDD level where operations are
# atomic — our gate-level representation breaks this atomicity.
# See WORKLOG for detailed analysis.
