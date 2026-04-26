# ---- Reversible-circuit composition (Bennett-qcso / U59) ----
#
# Pipeline composition: `compose(c1, c2)` returns a `ReversibleCircuit`
# whose semantics are `simulate(compose(c1, c2), x) == simulate(c2, simulate(c1, x))`.
#
# # The intermediate-value problem
#
# After c1 runs, c1's outputs hold an intermediate value `y = f(x)`.
# After c2 runs (with c2's inputs aliased to c1's outputs), c2 preserves
# its inputs (Bennett invariant on c2) → c1's output wires still hold
# `y`. But these wires are neither inputs nor outputs of compose →
# Bennett's invariant requires them to be ancillae and zero. They aren't.
#
# Solution: append `reverse(c1.gates)` after c2's gates. Every NOT/CNOT/
# Toffoli gate is self-inverse, so reversing c1's gate sequence undoes
# c1's effect. After the reverse pass:
#   - c1's input wires: hold x (preserved through forward c1, untouched by
#     c2, restored by reverse c1).
#   - c1's outputs (= c2's inputs by alias): zero (reverse-c1 wipes them
#     from `y` back to their pre-c1 state, which was zero).
#   - c1's ancillae: zero (returned to zero by reverse c1).
#   - c2's renumbered outputs: hold `g(y) = g(f(x))` (untouched by reverse c1).
#   - c2's renumbered ancillae: zero (returned to zero by c2 itself; reverse
#     c1 doesn't touch them, since the renumbering kept c2's wires disjoint
#     from c1's except at the alias seam).
#
# # Wire-numbering scheme (compaction)
#
# c2's wires get renumbered so that:
#   - c2.input_wires[k]  → c1.output_wires[k]   (alias onto c1's output)
#   - every other c2 wire → fresh index starting at c1.n_wires + 1
# Total wire count: c1.n_wires + c2.n_wires - m, where m = length(c2.input_wires).
# Without this compaction the ReversibleCircuit constructor's "every wire
# in 1:n_wires must be classified" check would reject the result.
#
# # MVP scope
#
# - Positional aliasing only (c2.input_wires[k] ↔ c1.output_wires[k]).
#   Explicit `wire_map=` is a future kwarg (see I in the design doc).
# - Self-reversing inputs rejected loudly (Sun-Borissov mul, QROM tabulate
#   write outputs back onto input wires; aliasing onto those would race
#   with the reverse-c1 pass). Future bead may add `allow_self_reversing=true`.
# - Width and per-position element-count checks both fail loud.

@inline _renumber_gate(g::NOTGate, m::Vector{Int})     = NOTGate(m[g.target])
@inline _renumber_gate(g::CNOTGate, m::Vector{Int})    = CNOTGate(m[g.control], m[g.target])
@inline _renumber_gate(g::ToffoliGate, m::Vector{Int}) = ToffoliGate(m[g.control1], m[g.control2], m[g.target])

"""
    compose(c1::ReversibleCircuit, c2::ReversibleCircuit) -> ReversibleCircuit

Pipeline composition. Returns a circuit whose semantics are
`simulate(compose(c1, c2), x) == simulate(c2, simulate(c1, x))`. c2's
inputs are positionally aliased to c1's outputs, so
`c1.output_elem_widths == c2.input_widths` is required.

# Wire layout

The result's wire space is `1:(c1.n_wires + c2.n_wires - m)` where
`m = length(c2.input_wires)`. c1's wires keep their indices; c2's
non-input wires (its outputs and ancillae) get fresh indices starting
at `c1.n_wires + 1`; c2's input wires alias onto c1's output wires.

# Gate sequence

`c1.gates ++ renumbered(c2.gates) ++ reverse(c1.gates)`. The trailing
reverse-c1 uncomputes c1's intermediate output `y = f(x)` so that
c1's output wires (which become ancillae of compose) end at zero. This
relies on c2 preserving its inputs (Bennett invariant on c2); the
existing `simulator.jl` input-preservation assertion catches a
violation.

# Preconditions

- `c1.output_elem_widths == c2.input_widths` (per-position width match).
- Neither c1 nor c2 is self-reversing (`input_wires ∩ output_wires == ∅`
  on both). Self-reversing primitives (Sun-Borissov mul, QROM tabulate)
  overwrite their inputs with their outputs — aliasing c2's inputs onto
  c1's outputs in that case races with the reverse-c1 pass.
- Both circuits satisfy the Bennett-pksz / U98 contiguous-wire
  invariant (every gate references wires in `1:n_wires`).

# Example

```jldoctest; setup = :(using Bennett)
julia> c1 = reversible_compile(x -> x + Int8(1), Int8);

julia> c2 = reversible_compile(x -> x + Int8(2), Int8);

julia> c12 = compose(c1, c2);

julia> simulate(c12, Int8(5))
8

julia> verify_reversibility(c12)
true
```
"""
function compose(c1::ReversibleCircuit, c2::ReversibleCircuit)
    # ---- Width / arity preconditions ----
    if c1.output_elem_widths != c2.input_widths
        throw(ArgumentError(
            "compose: c1.output_elem_widths=$(c1.output_elem_widths) does not " *
            "match c2.input_widths=$(c2.input_widths) — c2's inputs must align " *
            "positionally with c1's outputs (Bennett-qcso / U59)"))
    end
    if length(c1.output_wires) != length(c2.input_wires)
        throw(ArgumentError(
            "compose: c1 has $(length(c1.output_wires)) output wires but c2 has " *
            "$(length(c2.input_wires)) input wires — sum-of-widths matched but " *
            "wire counts disagree (likely a malformed circuit)"))
    end

    # ---- Self-reversing rejection ----
    sr1 = intersect(Set(c1.input_wires), Set(c1.output_wires))
    if !isempty(sr1)
        throw(ArgumentError(
            "compose: c1 is self-reversing — input_wires ∩ output_wires = " *
            "$(sort!(collect(sr1))). MVP rejects self-reversing inputs " *
            "(Sun-Borissov mul, QROM tabulate, etc.); the reverse-c1 pass " *
            "would race with c2's reads. A future kwarg may relax this " *
            "(Bennett-qcso / U59 §C)"))
    end
    sr2 = intersect(Set(c2.input_wires), Set(c2.output_wires))
    if !isempty(sr2)
        throw(ArgumentError(
            "compose: c2 is self-reversing — input_wires ∩ output_wires = " *
            "$(sort!(collect(sr2))). MVP rejects self-reversing inputs " *
            "(Bennett-qcso / U59 §C)"))
    end

    # ---- Bennett-pksz / U98 contiguous-wire pre-check ----
    if !isempty(c1.gates)
        max1 = maximum(_gate_max_wire, c1.gates)
        max1 <= c1.n_wires || throw(ArgumentError(
            "compose: c1 references wire $max1 > c1.n_wires=$(c1.n_wires). " *
            "Bennett-pksz / U98 contiguous-wire invariant violated."))
    end
    if !isempty(c2.gates)
        max2 = maximum(_gate_max_wire, c2.gates)
        max2 <= c2.n_wires || throw(ArgumentError(
            "compose: c2 references wire $max2 > c2.n_wires=$(c2.n_wires). " *
            "Bennett-pksz / U98 contiguous-wire invariant violated."))
    end

    # ---- Step 1: build c2's wire renumber map (compacted) ----
    n1 = c1.n_wires
    n2 = c2.n_wires
    m  = length(c2.input_wires)

    wire_renumber = Vector{Int}(undef, n2)
    aliased = falses(n2)
    for (k, w_in) in enumerate(c2.input_wires)
        wire_renumber[w_in] = c1.output_wires[k]
        aliased[w_in] = true
    end
    next_fresh = n1 + 1
    for w in 1:n2
        aliased[w] && continue
        wire_renumber[w] = next_fresh
        next_fresh += 1
    end
    n_total = next_fresh - 1
    @assert n_total == n1 + n2 - m  "compose: wire-budget compaction mismatch"

    # ---- Step 2: build the gate list ----
    new_gates = ReversibleGate[]
    sizehint!(new_gates, 2 * length(c1.gates) + length(c2.gates))
    append!(new_gates, c1.gates)
    for g in c2.gates
        push!(new_gates, _renumber_gate(g, wire_renumber))
    end
    for i in length(c1.gates):-1:1
        push!(new_gates, c1.gates[i])
    end

    # ---- Step 3: assemble result ReversibleCircuit ----
    input_wires        = copy(c1.input_wires)
    input_widths       = copy(c1.input_widths)
    output_wires       = [wire_renumber[w] for w in c2.output_wires]
    output_elem_widths = copy(c2.output_elem_widths)
    ancilla_wires      = _compute_ancillae(n_total, input_wires, output_wires)

    return ReversibleCircuit(n_total, new_gates, input_wires, output_wires,
                             ancilla_wires, input_widths, output_elem_widths)
end
