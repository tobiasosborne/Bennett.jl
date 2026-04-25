"""
SAT-based reversible pebbling.

Reference: Giulia Meuli, Mathias Soeken, Martin Roetteler, Nikhil Bhatia,
Thomas Häner, "Reversible Pebbling Game for Quantum Memory Management",
2019 Design, Automation & Test in Europe Conference & Exhibition (DATE),
pp. 288–291, 2019.  DOI: 10.23919/DATE.2019.8715092.

Encodes the reversible pebbling game (Bennett 1989; see `pebbling.jl`)
as a SAT problem:
- Variables: p[v,i] = node v is pebbled at step i
- Initial: all unpebbled
- Final: outputs pebbled, intermediates unpebbled
- Move: pebble/unpebble v only if all predecessors pebbled at both i and i+1
- Cardinality: at most P pebbles per step (Sinz 2005, see `_add_at_most_k!`).

Uses PicoSAT as the SAT solver.
"""

using PicoSAT

"""
    sat_pebble(adj, outputs; max_pebbles, max_steps=0, timeout_steps=100)

Find a minimum-length pebbling strategy for the given DAG.

- adj: Dict{Int, Vector{Int}} — node => list of predecessor nodes
- outputs: Vector{Int} — output nodes (must be pebbled at end)
- max_pebbles: maximum simultaneous pebbles
- Returns: Vector{Set{Int}} — pebble configurations P_0, P_1, ..., P_K
"""
function sat_pebble(adj::Dict{Int, Vector{Int}}, outputs::Vector{Int};
                    max_pebbles::Int, max_steps::Int=0, timeout_steps::Int=100)
    nodes = sort(collect(keys(adj)))
    N = length(nodes)
    node_idx = Dict(v => i for (i, v) in enumerate(nodes))
    output_set = Set(outputs)

    # If max_steps not specified, start from minimum and increment
    K_start = max_steps > 0 ? max_steps : 2 * N - 1
    K_end = max_steps > 0 ? max_steps : timeout_steps

    for K in K_start:K_end
        result = _solve_pebbling(nodes, node_idx, adj, output_set, K, max_pebbles)
        if result !== nothing
            return result
        end
    end

    return nothing  # no solution found within timeout
end

function _solve_pebbling(nodes, node_idx, adj, output_set, K, P)
    N = length(nodes)

    # Variable mapping: p[v,i] → SAT variable index (1-based)
    # v ∈ 1:N (node index), i ∈ 0:K (time step)
    var(v, i) = (v - 1) * (K + 1) + i + 1

    clauses = Vector{Int}[]

    # 1. Initial clauses: all unpebbled at time 0
    for v in 1:N
        push!(clauses, [-var(v, 0)])
    end

    # 2. Final clauses: outputs pebbled, intermediates unpebbled at time K
    for (i, node) in enumerate(nodes)
        if node in output_set
            push!(clauses, [var(i, K)])   # output must be pebbled
        else
            push!(clauses, [-var(i, K)])  # intermediate must be unpebbled
        end
    end

    # 3. Move clauses: if node v changes pebble state between i and i+1,
    #    then all predecessors must be pebbled at both i and i+1.
    #    Encoding: (p[v,i] XOR p[v,i+1]) → (p[u,i] AND p[u,i+1]) for each pred u
    #    Equivalently: for each pred u of v:
    #      ¬(p[v,i] XOR p[v,i+1]) OR (p[u,i] AND p[u,i+1])
    #    Which is: (p[v,i] ↔ p[v,i+1]) OR (p[u,i] AND p[u,i+1])
    #    In CNF: ¬change(v,i) OR p[u,i], AND ¬change(v,i) OR p[u,i+1]
    #    Where change(v,i) = p[v,i] XOR p[v,i+1]
    #
    #    Direct CNF (without auxiliary): for each pred u of v, for each step i:
    #      (¬p[v,i] OR p[v,i+1] OR p[u,i])     — if v goes from 1→0, u must be 1 at i
    #      (¬p[v,i] OR p[v,i+1] OR p[u,i+1])   — if v goes from 1→0, u must be 1 at i+1
    #      (p[v,i] OR ¬p[v,i+1] OR p[u,i])     — if v goes from 0→1, u must be 1 at i
    #      (p[v,i] OR ¬p[v,i+1] OR p[u,i+1])   — if v goes from 0→1, u must be 1 at i+1
    for (vi, node) in enumerate(nodes)
        preds = adj[node]
        for pred in preds
            ui = node_idx[pred]
            for i in 0:(K - 1)
                push!(clauses, [-var(vi, i),  var(vi, i+1), var(ui, i)])
                push!(clauses, [-var(vi, i),  var(vi, i+1), var(ui, i+1)])
                push!(clauses, [ var(vi, i), -var(vi, i+1), var(ui, i)])
                push!(clauses, [ var(vi, i), -var(vi, i+1), var(ui, i+1)])
            end
        end
    end

    # 4. Cardinality constraints: at most P pebbles at each step.
    #    Use sequential counter encoding for ∑ p[v,i] ≤ P.
    #    Each time step needs unique auxiliary variable range.
    n_pebble_vars = N * (K + 1)
    aux_per_step = N * (P + 1)  # N × (K_card + 1) where K_card = P
    for i in 0:K
        base = n_pebble_vars + i * aux_per_step
        _add_at_most_k!(clauses, [var(v, i) for v in 1:N], P, base)
    end

    # Solve
    result = PicoSAT.solve(clauses)
    if result == :unsatisfiable
        return nothing
    end

    # Decode: extract pebble sets for each step
    schedule = Set{Int}[]
    for i in 0:K
        pebbled = Set{Int}()
        for (vi, node) in enumerate(nodes)
            v_idx = var(vi, i)
            if v_idx <= length(result) && result[v_idx] > 0
                push!(pebbled, node)
            end
        end
        push!(schedule, pebbled)
    end

    return schedule
end

"""
Sequential counter encoding for at-most-K constraint.

Reference: Carsten Sinz, "Towards an Optimal CNF Encoding of Boolean
Cardinality Constraints", in Principles and Practice of Constraint
Programming — CP 2005, LNCS 3709, Springer, pp. 827–831, 2005.
DOI: 10.1007/11564751_73.  The auxiliary variables `s[i,j]` encode
"at least j of vars[1:i] are true"; clauses propagate the count and
forbid the (K+1)-th true literal.

Uses O(N*K) auxiliary variables and O(N*K) clauses.
"""
function _add_at_most_k!(clauses, vars, K, base_var_count)
    N = length(vars)
    K >= N && return  # trivially satisfied

    # Auxiliary variables: s[i,j] = "at least j of vars[1:i] are true"
    # s[i,j] for i ∈ 1:N, j ∈ 1:K+1
    # Variable index: base + (i-1)*(K+1) + j
    s(i, j) = base_var_count + (i - 1) * (K + 1) + j

    # s[1,1] ↔ vars[1]
    push!(clauses, [-vars[1], s(1, 1)])
    push!(clauses, [vars[1], -s(1, 1)])
    # s[1,j] = false for j > 1
    for j in 2:(K + 1)
        push!(clauses, [-s(1, j)])
    end

    for i in 2:N
        # s[i,1] = s[i-1,1] OR vars[i]
        push!(clauses, [-s(i-1, 1), s(i, 1)])
        push!(clauses, [-vars[i], s(i, 1)])
        push!(clauses, [s(i-1, 1), vars[i], -s(i, 1)])

        for j in 2:(K + 1)
            # s[i,j] = s[i-1,j] OR (s[i-1,j-1] AND vars[i])
            push!(clauses, [-s(i-1, j), s(i, j)])
            push!(clauses, [-s(i-1, j-1), -vars[i], s(i, j)])
            push!(clauses, [s(i-1, j), s(i-1, j-1), -s(i, j)])
            push!(clauses, [s(i-1, j), vars[i], -s(i, j)])
        end
    end

    # At most K: s[N, K+1] must be false
    push!(clauses, [-s(N, K + 1)])
end

"""
Verify a pebbling schedule is valid.
"""
function verify_pebble_schedule(adj::Dict{Int, Vector{Int}}, outputs::Vector{Int},
                                schedule::Vector{Set{Int}})
    output_set = Set(outputs)
    K = length(schedule) - 1

    # Check initial: empty
    isempty(schedule[1]) || return false

    # Check final: outputs pebbled, others not
    schedule[end] == output_set || return false

    # Check moves: each pebble/unpebble has all predecessors pebbled
    for i in 1:K
        prev = schedule[i]
        curr = schedule[i + 1]
        changed = symdiff(prev, curr)
        for v in changed
            preds = get(adj, v, Int[])
            for u in preds
                (u in prev && u in curr) || return false
            end
        end
    end

    return true
end
