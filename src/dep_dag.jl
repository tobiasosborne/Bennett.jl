"""
Dependency DAG extraction from a reversible circuit's forward gates.

Each gate becomes a node in the DAG. Edges connect a gate to all gates
that use the same wire as a target (producer → consumer dependency).
Used for pebbling analysis and liveness-guided uncomputation.
"""

struct DAGNode
    gate_idx::Int            # index into original gate list
    preds::Vector{Int}       # predecessor node indices (dependencies)
    succs::Vector{Int}       # successor node indices (dependents)
    target_wire::Int         # wire this gate writes to
end

struct DepDAG
    nodes::Vector{DAGNode}
    output_nodes::Vector{Int}    # nodes whose target wires are outputs
    input_wires::Set{Int}        # input wire set
end

"""
    extract_dep_dag(circuit::ReversibleCircuit) -> DepDAG

Build a dependency DAG from the FORWARD gates of a reversible circuit.
The forward gates are the first half (before the CNOT copy + reverse).
"""
function extract_dep_dag(circuit::ReversibleCircuit)
    # The forward gates are the first (n_gates - n_out) / 2 gates
    n_out = length(circuit.output_wires)
    n_total = length(circuit.gates)
    n_forward = (n_total - n_out) ÷ 2

    forward_gates = circuit.gates[1:n_forward]
    input_set = Set(circuit.input_wires)

    # Map: wire → last gate index that targeted it
    wire_producer = Dict{Int, Int}()

    nodes = DAGNode[]

    for (i, gate) in enumerate(forward_gates)
        target = _gate_target(gate)
        controls = _gate_controls(gate)

        # Find predecessors: any gate that produced a wire we read
        preds = Int[]
        for c in controls
            if haskey(wire_producer, c)
                push!(preds, wire_producer[c])
            end
        end
        # Also depend on previous gate that targeted same wire (WAW)
        if haskey(wire_producer, target)
            push!(preds, wire_producer[target])
        end
        preds = unique(preds)

        push!(nodes, DAGNode(i, preds, Int[], target))
        wire_producer[target] = i
    end

    # Build successor lists from predecessor lists
    for (i, node) in enumerate(nodes)
        for p in node.preds
            push!(nodes[p].succs, i)
        end
    end

    # Find output nodes: gates whose target wires are circuit outputs
    # (accounting for the CNOT copy — output wires are the copy wires,
    #  but the gates that produce the values feeding the copy are the
    #  ones whose target wires are the original output wires before copy)
    # Actually, in the circuit the forward gates feed into the copy gates.
    # The "output" of the forward computation is the wires that get copied.
    # These are the wires that the CNOT copy reads from.
    output_set = Set{Int}()
    # The copy gates are at positions n_forward+1 to n_forward+n_out
    for i in (n_forward + 1):(n_forward + n_out)
        gate = circuit.gates[i]
        if gate isa CNOTGate
            push!(output_set, gate.control)  # CNOT copies FROM control
        end
    end
    output_nodes = [i for (i, n) in enumerate(nodes) if n.target_wire in output_set]

    return DepDAG(nodes, output_nodes, input_set)
end

# Bennett-mg6u / U201: _gate_target / _gate_controls moved to src/gates.jl
# (the natural home for gate-type accessors), so both this file and
# src/eager.jl can use them without an inter-file dep.
