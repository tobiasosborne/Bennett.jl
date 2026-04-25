# ---- Controlled reversible circuits ----

"""
    ControlledCircuit

A reversible circuit lifted to take an explicit control bit. Built by
`controlled(c::ReversibleCircuit)`, which promotes every gate
(NOT → CNOT, CNOT → Toffoli, Toffoli → 3 Toffolis + 1 reusable ancilla).
The control wire is `ctrl_wire`, classified internally as the inner
circuit's first input wire (Bennett-6azb / U58 — required so the inner
`ReversibleCircuit`'s wire-partition invariant covers every wire).

Behavioural invariant: `(ctrl, x, 0) → (ctrl, x, ctrl ? f(x) : 0)`.
Evaluate with `simulate(cc, ctrl::Bool, input)`; check the contract on
random `(ctrl, input)` pairs with `verify_reversibility(cc)`, which
delegates to the inner circuit's probe.

# Fields
- `circuit::ReversibleCircuit` — inner circuit with promoted gates
- `ctrl_wire::WireIndex` — index of the dedicated control wire

# Example
```jldoctest; setup = :(using Bennett)
julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> cc = controlled(c);

julia> simulate(cc, true,  Int8(5))
6

julia> simulate(cc, false, Int8(5))
0
```
"""
struct ControlledCircuit
    circuit::ReversibleCircuit
    ctrl_wire::WireIndex
end

# Bennett-pksz / U98: contiguous-wire-allocation invariant.
# `controlled()` chooses `ctrl_wire = circuit.n_wires + 1` (and
# `anc_wire = + 2`) on the assumption that no inner gate already
# references wires beyond `circuit.n_wires`. The
# `ReversibleCircuit` constructor partitions input/output/ancilla
# to cover exactly `1:n_wires`, but it does NOT cross-check that
# the gate stream stays within that range — a malformed circuit
# with `gates = [NOTGate(n_wires + 1)]` would silently collide
# with our chosen `ctrl_wire`. Assert it here, fail loud.
_gate_max_wire(g::NOTGate)     = g.target
_gate_max_wire(g::CNOTGate)    = max(g.control, g.target)
_gate_max_wire(g::ToffoliGate) = max(g.control1, g.control2, g.target)

"""
    controlled(circuit::ReversibleCircuit) -> ControlledCircuit

Wrap every gate with a control bit: NOT→CNOT, CNOT→Toffoli,
Toffoli→decomposed controlled-Toffoli (3 Toffolis + 1 reusable ancilla).

Result: `(ctrl, x, 0) → (ctrl, x, ctrl ? f(x) : 0)`.

Assumes contiguous wire allocation: every gate in `circuit.gates`
references wire indices in `1:circuit.n_wires`. Asserts this on
entry — a malformed inner circuit collides with the new control /
ancilla wires we allocate at `n_wires + 1` / `+ 2`.
"""
function controlled(circuit::ReversibleCircuit)
    # Bennett-pksz / U98: cross-check the contiguous-wire invariant
    # before allocating ctrl_wire / anc_wire.
    if !isempty(circuit.gates)
        max_inner = maximum(_gate_max_wire, circuit.gates)
        max_inner <= circuit.n_wires || error(
            "controlled: inner circuit references wire $max_inner > " *
            "n_wires=$(circuit.n_wires). The controlled-circuit construction " *
            "allocates ctrl_wire at n_wires+1, which would collide. " *
            "(Bennett-pksz / U98)")
    end

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

    # Bennett-6azb / U58: classify `ctrl_wire` as an input of the inner
    # `ReversibleCircuit`. It's caller-provided, must round-trip
    # unchanged, and satisfies all input-wire invariants. Without this
    # the partition-assert in `ReversibleCircuit`'s inner constructor
    # rejects the wire as unclassified. The public `simulate(cc, ctrl,
    # input)` / `verify_reversibility(cc)` API still takes `ctrl`
    # separately — we just prepend it internally.
    inner_input_wires  = pushfirst!(copy(circuit.input_wires), ctrl_wire)
    inner_input_widths = pushfirst!(copy(circuit.input_widths), 1)

    inner = ReversibleCircuit(total, new_gates,
                              inner_input_wires, circuit.output_wires,
                              new_anc, inner_input_widths,
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

"""
    simulate(cc::ControlledCircuit, ctrl::Bool, input::Integer) -> Integer
    simulate(cc::ControlledCircuit, ctrl::Bool, inputs::Tuple{Vararg{Integer}}) -> Integer | Tuple

Simulate a controlled circuit. Returns `f(input)` when `ctrl == true`,
otherwise the all-zero output value of the appropriate type/shape (since
the controlled gates fire only when `ctrl == 1`). Internally prepends
`Int(ctrl)` to the inputs tuple and delegates to
`simulate(cc.circuit, …)`, so the same arity check, per-input bit-width
guard, ancilla-zero assertion, and input-preservation assertion (now
including `ctrl_wire`) all apply.

# Example
```jldoctest; setup = :(using Bennett)
julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> cc = controlled(c);

julia> simulate(cc, true,  Int8(5))
6

julia> simulate(cc, false, Int8(5))
0
```
"""
function simulate(cc::ControlledCircuit, ctrl::Bool, input::Integer)
    # Bennett-6azb / U58: the inner `ReversibleCircuit` now carries
    # ctrl as its first input. User-facing f still takes its own
    # inputs; check against `length(c.input_widths) - 1` here.
    length(cc.circuit.input_widths) == 2 || error(
        "simulate(cc, ctrl, input) requires single-f-input circuit, got " *
        "$(length(cc.circuit.input_widths) - 1) f-inputs " *
        "($(length(cc.circuit.input_widths)) total including ctrl)")
    return _simulate_ctrl(cc, ctrl, (input,))
end

function simulate(cc::ControlledCircuit, ctrl::Bool, inputs::Tuple{Vararg{Integer}})
    return _simulate_ctrl(cc, ctrl, inputs)
end

function _simulate_ctrl(cc::ControlledCircuit, ctrl::Bool, inputs::Tuple)
    c = cc.circuit
    # Bennett-6azb / U58: ctrl is now input_widths[1] of the inner.
    # Synthesise the full input tuple and delegate to `_simulate`,
    # which already handles per-input arity + fit checks AND the new
    # input-preservation invariant. Ctrl preservation falls out for
    # free — it's just input_wires[1].
    length(inputs) + 1 == length(c.input_widths) || throw(ArgumentError(
        "simulate(ControlledCircuit, …): expected " *
        "$(length(c.input_widths) - 1) f-inputs, got $(length(inputs)) " *
        "(inner input_widths = $(c.input_widths), first is ctrl)"))
    return _simulate(c, (Int(ctrl), inputs...))
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
    # Bennett-6azb / U58: ctrl is now `cc.circuit.input_wires[1]`, so
    # delegating to the `ReversibleCircuit` probe covers all three
    # invariants — ancilla-zero, input-preservation (which now
    # includes ctrl), and forward+reverse self-consistency — without
    # duplicating the probe logic.
    return verify_reversibility(cc.circuit; n_tests)
end
