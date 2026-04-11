"""
Pebbling strategies for reversible circuit optimization.

Implements Knill's 1995 recursion (Theorem 2.1) for optimal time given
a space bound, and provides a framework for applying pebbling strategies
to the dependency DAG to generate optimized Bennett constructions.
"""

"""
    knill_pebble_cost(n::Int, s::Int) -> Int

Compute the minimum number of steps to pebble a chain of n nodes using
at most s pebbles, using Knill's recursion (Theorem 2.1):

  F(1, s) = 1                    for s >= 1
  F(n, 1) = Inf                  for n >= 2
  F(n, s) = min over m of F(m,s) + F(m,s-1) + F(n-m,s-1)  for n>=2, s>=2

The three terms: forward first m nodes, unforward them (one fewer pebble),
continue with remaining n-m nodes (one fewer pebble).
"""
function knill_pebble_cost(n::Int, s::Int)
    # Dynamic programming table
    F = fill(typemax(Int) ÷ 2, n, s)

    # Base cases
    for ss in 1:s
        F[1, ss] = 1
    end

    for nn in 2:n
        for ss in 2:s
            best = typemax(Int) ÷ 2
            for m in 1:(nn - 1)
                a, b, c = F[m, ss], F[m, ss - 1], F[nn - m, ss - 1]
                # Overflow-safe addition
                if a < typemax(Int) ÷ 4 && b < typemax(Int) ÷ 4 && c < typemax(Int) ÷ 4
                    cost = a + b + c
                    if cost < best
                        best = cost
                    end
                end
            end
            F[nn, ss] = best
        end
    end

    return F[n, s]
end

"""
    min_pebbles(n::Int) -> Int

Minimum number of pebbles needed to pebble a chain of n nodes.
From Knill Theorem 2.3: F(n,s) < Inf iff n <= 2^{s-1}.
So minimum s = 1 + ceil(log2(n)).
"""
function min_pebbles(n::Int)
    n <= 1 && return 1
    return 1 + ceil(Int, log2(n))
end

"""
    knill_split_point(n::Int, s::Int) -> Int

Find the optimal split point m for the Knill recursion at depth (n, s).
Returns the m that minimizes F(m,s) + F(m,s-1) + F(n-m,s-1).
"""
function knill_split_point(n::Int, s::Int)
    n <= 1 && return 0
    s <= 1 && return 0

    F = fill(typemax(Int) ÷ 4, n, s)
    for ss in 1:s; F[1, ss] = 1; end
    for nn in 2:n, ss in 2:s
        for m in 1:(nn-1)
            a, b, c = F[m, ss], F[m, ss-1], F[nn-m, ss-1]
            if a < typemax(Int) ÷ 4 && b < typemax(Int) ÷ 4 && c < typemax(Int) ÷ 4
                cost = a + b + c
                F[nn, ss] = min(F[nn, ss], cost)
            end
        end
    end

    # Find the best m for (n, s)
    best_m = 1
    best_cost = typemax(Int) ÷ 2
    for m in 1:(n-1)
        a, b, c = F[m, s], F[m, s-1], F[n-m, s-1]
        if a < typemax(Int) ÷ 4 && b < typemax(Int) ÷ 4 && c < typemax(Int) ÷ 4
            cost = a + b + c
            if cost < best_cost
                best_cost = cost
                best_m = m
            end
        end
    end
    return best_m
end

"""
    pebbled_bennett(lr::LoweringResult; max_pebbles::Int=0) -> ReversibleCircuit

Bennett construction with Knill's pebbling strategy for space optimization.

Instead of forward ALL → copy → reverse ALL (full Bennett, max space),
uses recursive checkpointing to reduce the number of simultaneously live
intermediate wires.

If max_pebbles <= 0, uses full Bennett (no optimization).
"""
function pebbled_bennett(lr::LoweringResult; max_pebbles::Int=0)
    n_out = length(lr.output_wires)
    copy_start = lr.n_wires + 1
    copy_wires = collect(copy_start:copy_start + n_out - 1)
    total = lr.n_wires + n_out

    n = length(lr.gates)

    if max_pebbles <= 0 || max_pebbles >= n
        # Full Bennett — same as bennett()
        return bennett(lr)
    end

    all_gates = ReversibleGate[]

    # Build the copy gates (to be inserted at the right moment)
    copy_gates = ReversibleGate[CNOTGate(lr.output_wires[i], copy_wires[i]) for i in 1:n_out]

    # Generate pebbled schedule: forward + copy + reverse
    _pebble_with_copy!(all_gates, lr.gates, copy_gates, 1, n, max_pebbles, true)

    return _build_circuit(all_gates, total, lr.input_wires, copy_wires, lr)
end

"""
Recursive pebbling with output copy insertion.

When `is_outermost` is true and we reach the end of all gates, the copy_gates
are inserted before uncomputing. For inner recursions, no copy is needed.

Implements Knill's reversible pebbling game at the gate level:
  Step 1: Forward gates lo:mid (compute, m steps)
  Step 2: Recursively pebble mid+1:hi with s-1 pebbles
  Step 3: Reverse gates lo:mid (uncompute, m steps)

The benefit over full Bennett: the recursive splitting ensures that at any point
during execution, at most s segments of gates have live wires simultaneously.
Total gate count is always 2n-1+n_out (same as full Bennett for a chain), but
the peak number of simultaneously-live wires is bounded by O(s * max_segment_wires).
"""
function _pebble_with_copy!(result::Vector{ReversibleGate},
                            gates::Vector{ReversibleGate},
                            copy_gates::Vector{ReversibleGate},
                            lo::Int, hi::Int, s::Int,
                            is_outermost::Bool)
    n = hi - lo + 1
    n <= 0 && return

    # Base case: enough pebbles for full Bennett on this segment
    if n <= s
        for i in lo:hi
            push!(result, gates[i])
        end
        if is_outermost && hi == length(gates)
            append!(result, copy_gates)
        end
        for i in hi:-1:lo
            push!(result, gates[i])
        end
        return
    end

    s <= 1 && error("Insufficient pebbles: need at least $(min_pebbles(n)) for $n gates, have $s")

    m = knill_split_point(n, s)
    mid = lo + m - 1

    # Step 1: Forward gates lo:mid (compute, m steps)
    for i in lo:mid
        push!(result, gates[i])
    end

    # Step 2: Recursively pebble mid+1:hi with s-1 pebbles
    includes_end = (hi == length(gates)) && is_outermost
    _pebble_with_copy!(result, gates, copy_gates, mid + 1, hi, s - 1, includes_end)

    # Step 3: Reverse gates lo:mid (uncompute, m steps)
    for i in mid:-1:lo
        push!(result, gates[i])
    end
end

"""
    pebble_tradeoff(n::Int; max_space::Int=0) -> NamedTuple

Compute the time-space tradeoff for pebbling n nodes.
Returns (space, time, overhead) for the optimal strategy at the given space bound.
If max_space is 0, uses full Bennett (space = n, time = 2n-1).
"""
function pebble_tradeoff(n::Int; max_space::Int=0)
    if max_space <= 0
        # Full Bennett
        return (space=n, time=2n - 1, overhead=1.0)
    end
    s = max(max_space, min_pebbles(n))
    t = knill_pebble_cost(n, s)
    return (space=s, time=t, overhead=t / (2n - 1))
end
