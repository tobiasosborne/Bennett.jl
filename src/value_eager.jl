"""
PRS15 Algorithm 2: Value-level EAGER cleanup.

Two optimizations over full Bennett:
1. Dead-end values (zero consumers, not output) are eagerly cleaned during the
   forward pass, reducing peak live wires.
2. Phase 3 uncomputes values in reverse topological order of the SSA dependency
   DAG. Each value's gates are reversed as a unit, enabling future wire reuse.

Values with consumers cannot be eagerly cleaned during forward because their
wires are needed by consumers' cleanup gates in Phase 3. Only dead-end values
(whose wires are never read as controls) are safe to clean during Phase 1.

Reference: Parent/Roetteler/Svore 2015, "Reversible circuit compilation
with space constraints", Algorithm 2.
"""

"""
    value_eager_bennett(lr::LoweringResult) -> ReversibleCircuit

Bennett construction with PRS15 value-level EAGER cleanup.

Phase 1: Forward gates with eager cleanup of dead-end values (zero consumers).
Phase 2: CNOT copy outputs to fresh wires.
Phase 3: Uncompute remaining values in reverse topological order of the DAG.

Falls back to full Bennett if gate_groups is empty.
"""
function value_eager_bennett(lr::LoweringResult)
    groups = lr.gate_groups
    if isempty(groups)
        return bennett(lr)
    end

    # Bennett-rggq / U02: Phase-3 Kahn walks `input_ssa_vars`, but `__pred_*`
    # block-predicate groups (lower.jl:379,389) carry empty input_ssa_vars —
    # their wire-level cross-deps on OTHER `__pred_*` groups are invisible to
    # the DAG, so reverse-topo becomes wrong and predicate wires get reversed
    # out of order. Fall back to full Bennett on any branching CFG (≥2
    # `__pred_*` groups). Straight-line code has only the entry predicate and
    # retains the PRS15 Phase-3 peak-live savings.
    if _has_branching(lr)
        return bennett(lr)
    end

    gates = lr.gates
    output_set = Set(lr.output_wires)
    n_groups = length(groups)

    # --- Build dependency info ---
    name_to_idx = Dict{Symbol, Int}()
    for (i, g) in enumerate(groups)
        name_to_idx[g.ssa_name] = i
    end

    # Consumer count: how many groups read each group's output
    consumer_count = zeros(Int, n_groups)
    for (i, g) in enumerate(groups)
        for dep in g.input_ssa_vars
            j = get(name_to_idx, dep, 0)
            if j > 0
                consumer_count[j] += 1
            end
        end
    end

    # Output groups get +1 implicit consumer (the copy phase)
    is_output_group = falses(n_groups)
    for (i, g) in enumerate(groups)
        if any(w in output_set for w in g.result_wires)
            is_output_group[i] = true
            consumer_count[i] += 1
        end
    end

    # --- Phase 1: Forward with eager cleanup of dead-end values ---
    result = ReversibleGate[]
    sizehint!(result, 2 * length(gates) + length(lr.output_wires))
    cleaned = falses(n_groups)

    for (i, g) in enumerate(groups)
        # Forward this group's gates
        for gi in g.gate_start:g.gate_end
            push!(result, gates[gi])
        end

        # Dead-end value: zero consumers AND not an output → clean immediately
        # Safe because no gate reads these wires as controls (dead-end).
        if consumer_count[i] == 0 && !is_output_group[i]
            for gi in g.gate_end:-1:g.gate_start
                push!(result, gates[gi])
            end
            cleaned[i] = true
        end
    end

    # --- Phase 2: CNOT copy outputs to fresh wires ---
    n_out = length(lr.output_wires)
    copy_start = lr.n_wires + 1
    copy_wires = collect(copy_start:copy_start + n_out - 1)
    total = lr.n_wires + n_out

    for (j, w) in enumerate(lr.output_wires)
        push!(result, CNOTGate(w, copy_wires[j]))
    end

    # --- Phase 3: Reverse remaining values in reverse topological order ---
    # Release implicit consumer for output groups
    for i in 1:n_groups
        if is_output_group[i] && !cleaned[i]
            consumer_count[i] -= 1
        end
    end

    # Kahn's algorithm on reversed dependency DAG (consumers first)
    queue = Int[]
    for i in 1:n_groups
        if !cleaned[i] && consumer_count[i] == 0
            push!(queue, i)
        end
    end

    while !isempty(queue)
        idx = popfirst!(queue)
        if cleaned[idx]
            continue
        end
        cleaned[idx] = true

        g = groups[idx]
        for gi in g.gate_end:-1:g.gate_start
            push!(result, gates[gi])
        end

        # Decrement consumer count for this group's dependencies
        for dep in g.input_ssa_vars
            j = get(name_to_idx, dep, 0)
            if j > 0 && !cleaned[j]
                consumer_count[j] -= 1
                if consumer_count[j] == 0
                    push!(queue, j)
                end
            end
        end
    end

    return _build_circuit(result, total, lr.input_wires, copy_wires, lr)
end
