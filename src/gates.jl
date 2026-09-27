const WireIndex = Int

"""Abstract base type for reversible gates (NOT, CNOT, Toffoli). All are self-inverse."""
abstract type ReversibleGate end

"""NOT gate: flips the target bit. Self-inverse."""
struct NOTGate <: ReversibleGate
    target::WireIndex
    # Bennett-lcye / F13: validate at construction. Wire indices are
    # 1-based; a 0/negative index means a lowering bug and would either
    # alias wire 1 or index out of bounds in `simulate`. Inner
    # constructor (not an outer check) so no code path can build an
    # invalid primitive. Cost is one comparison — this runs ~11M times
    # for a soft-float transcendental, so keep it branch-only.
    function NOTGate(target::WireIndex)
        target >= 1 || throw(ArgumentError(
            "NOTGate: target wire $target is not a valid 1-based wire " *
            "index (Bennett-lcye)"))
        return new(target)
    end
end

"""Controlled-NOT gate: flips target when control is 1. Self-inverse."""
struct CNOTGate <: ReversibleGate
    control::WireIndex
    target::WireIndex
    # Bennett-lcye / F13: `CNOTGate(c,c)` is NOT self-inverse — it
    # implements `b[c] ⊻= b[c]`, zeroing the bit in one application.
    # Reject it (and out-of-range wires) at construction so the defect
    # can never reach `simulate` / `verify_reversibility`.
    function CNOTGate(control::WireIndex, target::WireIndex)
        control >= 1 || throw(ArgumentError(
            "CNOTGate: control wire $control is not a valid 1-based wire " *
            "index (Bennett-lcye)"))
        target >= 1 || throw(ArgumentError(
            "CNOTGate: target wire $target is not a valid 1-based wire " *
            "index (Bennett-lcye)"))
        control != target || throw(ArgumentError(
            "CNOTGate: control == target == $control is not reversible — " *
            "it zeroes the bit (Bennett-lcye)"))
        return new(control, target)
    end
end

"""
Toffoli gate: flips target when both controls are 1. Self-inverse. Universal for classical reversible computation.

Bennett-lcye / F13: the target must differ from both controls — a
self-targeting Toffoli is irreversible and is rejected at construction.

`control1 == control2 == c` is *accepted*: `Toffoli(c, c, target)` is
exactly `CNOT(c, target)`, a legitimate self-inverse permutation. It is
not merely allowed in principle — `lower_mul_wide!` (src/multiplier.jl)
emits it on the diagonal `a[k] == b[i]` when squaring a value (`a === b`),
so rejecting it would break real compilation of `x*x`. Only the
target-equals-a-control case is a defect (and that one no emitter
produces), so the constructor check draws the line there.
"""
struct ToffoliGate <: ReversibleGate
    control1::WireIndex
    control2::WireIndex
    target::WireIndex
    function ToffoliGate(control1::WireIndex, control2::WireIndex, target::WireIndex)
        control1 >= 1 || throw(ArgumentError(
            "ToffoliGate: control1 wire $control1 is not a valid 1-based " *
            "wire index (Bennett-lcye)"))
        control2 >= 1 || throw(ArgumentError(
            "ToffoliGate: control2 wire $control2 is not a valid 1-based " *
            "wire index (Bennett-lcye)"))
        target >= 1 || throw(ArgumentError(
            "ToffoliGate: target wire $target is not a valid 1-based wire " *
            "index (Bennett-lcye)"))
        target != control1 || throw(ArgumentError(
            "ToffoliGate: target == control1 == $target is not reversible " *
            "(Bennett-lcye)"))
        target != control2 || throw(ArgumentError(
            "ToffoliGate: target == control2 == $target is not reversible " *
            "(Bennett-lcye)"))
        return new(control1, control2, target)
    end
end

# Bennett-q7yd: (min, max) wire touched by a gate, used by the
# `ReversibleCircuit` constructor to bound-check the whole gate stream.
_gate_wire_extent(g::NOTGate)     = (g.target, g.target)
_gate_wire_extent(g::CNOTGate)    = (min(g.control, g.target), max(g.control, g.target))
_gate_wire_extent(g::ToffoliGate) = (min(g.control1, g.control2, g.target),
                                     max(g.control1, g.control2, g.target))

"""
    LoopGuard

Bennett-s0tn: one data-dependent loop's convergence-detection wire.
`wire` holds 1 at end of the forward pass iff the loop reached its exit
condition within `K` unrolled iterations. `header_label` and `K` are
carried only for the fail-loud error message.

Two contexts:
- inside `LoweringResult.loop_guards`, `wire` is the forward-pass
  convergence wire (`conv_w`);
- inside `ReversibleCircuit.loop_check_wires`, `wire` is the post-bennett
  copy-out wire (`conv_copy`) that survives the reverse pass.

Defined here (rather than in `src/lowering/types.jl` alongside
`LoweringResult`) because `gates.jl` loads first and `ReversibleCircuit`
needs `Vector{LoopGuard}` resolvable at struct-definition time.
"""
struct LoopGuard
    wire::Int             # convergence wire; 1 ⇔ loop converged within K
    header_label::Symbol  # loop header block label (diagnostics)
    K::Int                # max_loop_iterations this loop was unrolled to
end

"""
    _first_duplicate_wire(wires) -> Union{WireIndex,Nothing}

Return the first wire position that appears more than once in `wires`,
or `nothing` if all positions are distinct. Bennett-q7yd / F7: the
partition validator's `Set` construction silently erases duplicates, so
a circuit with `input_wires == [1, 1]` slipped through and
`verify_reversibility` certified a preservation check that only ever saw
one physical wire. Called only on the failure path (length mismatch), so
the happy path pays no extra Set.
"""
function _first_duplicate_wire(wires::Vector{WireIndex})
    seen = Set{WireIndex}()
    for w in wires
        w in seen && return w
        push!(seen, w)
    end
    return nothing
end

"""
    ReversibleCircuit

A reversible circuit: a sequence of NOT/CNOT/Toffoli gates operating on wires.
Produced by `reversible_compile` or `bennett`. The circuit satisfies the Bennett
invariant: all ancilla wires return to zero after execution.

# Storage layout decision (Bennett-jc0y / 59jj cut, investigated 2026-04-27)

`gates::Vector{ReversibleGate}` is intentionally typed with the abstract
supertype rather than a tagged-union or struct-of-arrays encoding. Empirical
measurement (`test/test_jc0y_gate_storage_contract.jl`):

  - Memory: boxed layout adds ~26% overhead vs a flat 32-byte tagged union
    (live: UInt64 `(a*b)+(c*d)*(a+b)` at 85k gates → 3.7 MB boxed vs 2.7 MB
    flat). Modest savings.

  - Simulate hot loop: bounded-allocation regardless of gate count.
    `_simulate` (src/simulator.jl) drives `for gate in c.gates; apply!(bits,
    gate); end`; Julia's union-splitting on the three concrete subtypes
    (NOTGate / CNOTGate / ToffoliGate) eliminates per-gate boxing inside the
    compiled function. A 28k-gate circuit allocates < 200 KiB total —
    n_wires-scaling, NOT n_gates-scaling.

  - Refactor blast radius: 24+ sites (every `lower_*!` helper, all strategy
    variants, bennett_transform, simulator) take `Vector{ReversibleGate}` as
    a parameter type. A storage-layout change must touch all of them and
    must NOT shift the 39 pinned gate-count baselines.

The trade-off favours the current shape until a real workload OOMs. The
contract test pins the empirical baselines so a future agent can measure
the shift before committing to the refactor.
"""
struct ReversibleCircuit
    n_wires::Int
    gates::Vector{ReversibleGate}
    input_wires::Vector{WireIndex}
    output_wires::Vector{WireIndex}
    ancilla_wires::Vector{WireIndex}
    input_widths::Vector{Int}
    output_elem_widths::Vector{Int}  # e.g. [8] for Int8, [8,8] for Tuple{Int8,Int8}
    # Bennett-s0tn: fourth wire-partition class — one LoopGuard per
    # data-dependent loop. `wire` holds the post-bennett convergence
    # copy-out; `simulate` errors loud if it reads 0 (loop overflowed
    # max_loop_iterations). Disjoint from input/output/ancilla. Empty
    # for every loop-free circuit (all pinned gate-count baselines).
    loop_check_wires::Vector{LoopGuard}

    # Bennett-6azb / U58: validate the wire partition at construction
    # time. `ancilla ∩ input` or `ancilla ∩ output` would make the
    # ancilla-zero check in `simulate` fire on an input/output value
    # (false positive or -negative). `input ∩ output` overlap IS
    # permitted — self-reversing primitives (soft-float, QROM tabulate)
    # legitimately write results back onto input wires. `union` must
    # cover `1:n_wires` so no wire escapes classification.
    #
    # Bennett-s0tn: the partition is now a FOUR-set partition — the
    # `loop_check` class must be disjoint from input, output, AND
    # ancilla, or the convergence check would alias a data wire.
    function ReversibleCircuit(n_wires::Int, gates::Vector{ReversibleGate},
                               input_wires::Vector{WireIndex},
                               output_wires::Vector{WireIndex},
                               ancilla_wires::Vector{WireIndex},
                               input_widths::Vector{Int},
                               output_elem_widths::Vector{Int},
                               loop_check_wires::Vector{LoopGuard}=LoopGuard[])
        in_set = Set(input_wires)
        out_set = Set(output_wires)
        anc_set = Set(ancilla_wires)
        lc_set  = Set(lg.wire for lg in loop_check_wires)

        # Bennett-q7yd / F7: the Set-based checks below erase duplicate
        # positions, so `input_wires == [1, 1]` survived construction and
        # `verify_reversibility` certified preservation of one physical
        # wire while the caller declared two independent inputs. Compare
        # each class's Set size to its list length — equality holds iff
        # the list is duplicate-free (and, combined with the cross-class
        # intersections, iff every position is classified exactly once).
        # Within-class duplicates are never legitimate: two output bits
        # of one result must live on distinct wires. `input ∩ output`
        # overlap (self-reversing soft-float / QROM circuits writing their
        # result back onto the input wires) is a *cross-class* alias and
        # remains permitted — it is checked by the intersections below,
        # not here.
        for (wires, wset, name) in ((input_wires, in_set, "input_wires"),
                                    (output_wires, out_set, "output_wires"),
                                    (ancilla_wires, anc_set, "ancilla_wires"))
            length(wset) == length(wires) || throw(ArgumentError(
                "ReversibleCircuit: $name contains duplicate wire position " *
                "$(_first_duplicate_wire(wires)); every position must be " *
                "classified exactly once (Bennett-q7yd)"))
        end
        length(lc_set) == length(loop_check_wires) || throw(ArgumentError(
            "ReversibleCircuit: loop_check_wires contains a duplicate wire " *
            "position; each data-dependent loop needs its own guard wire " *
            "(Bennett-q7yd)"))

        # Bennett-q7yd / F7: cross-check the declared element widths
        # against the physical wire lists. `sum(input_widths)` must equal
        # `length(input_wires)` — otherwise a logical input is never
        # randomized (width 0) or two inputs collapse onto one wire, and
        # `verify_reversibility` can return true on a malformed fixture.
        n_wires >= 0 || throw(ArgumentError(
            "ReversibleCircuit: n_wires=$n_wires must be >= 0 (Bennett-q7yd)"))
        for (k, w) in enumerate(input_widths)
            w > 0 || throw(ArgumentError(
                "ReversibleCircuit: input_widths[$k] = $w must be positive " *
                "(Bennett-q7yd)"))
        end
        for (k, w) in enumerate(output_elem_widths)
            w > 0 || throw(ArgumentError(
                "ReversibleCircuit: output_elem_widths[$k] = $w must be " *
                "positive (Bennett-q7yd)"))
        end
        sum(input_widths) == length(input_wires) || throw(ArgumentError(
            "ReversibleCircuit: sum(input_widths)=$(sum(input_widths)) != " *
            "length(input_wires)=$(length(input_wires)) (Bennett-q7yd)"))
        sum(output_elem_widths) == length(output_wires) || throw(ArgumentError(
            "ReversibleCircuit: sum(output_elem_widths)=$(sum(output_elem_widths)) " *
            "!= length(output_wires)=$(length(output_wires)) (Bennett-q7yd)"))

        # Bennett-q7yd / Bennett-pksz: every gate wire must lie in
        # 1:n_wires. Pre-fix only `controlled()` cross-checked this; a
        # circuit carrying a gate on wire 99 of 3 constructed cleanly and
        # could collide with `controlled()`'s freshly-allocated wires.
        # Linear in the gate count (the only O(gates) work in this
        # constructor); measured 0.061 s for an 11,033,736-gate soft-float
        # `sin` circuit whose lowering took ~50 s — ~0.1% overhead.
        for (i, g) in enumerate(gates)
            lo, hi = _gate_wire_extent(g)
            lo >= 1 || throw(ArgumentError(
                "ReversibleCircuit: gate $i ($(typeof(g))) references wire " *
                "$lo < 1 (Bennett-q7yd)"))
            hi <= n_wires || throw(ArgumentError(
                "ReversibleCircuit: gate $i ($(typeof(g))) references wire " *
                "$hi > n_wires=$n_wires (Bennett-q7yd)"))
        end

        bad_in_anc = intersect(in_set, anc_set)
        isempty(bad_in_anc) || throw(AssertionError(
            "ReversibleCircuit: ancilla wires $(sort!(collect(bad_in_anc))) " *
            "overlap input wires — the ancilla-zero check in `simulate` " *
            "would fire on input values"))

        bad_out_anc = intersect(out_set, anc_set)
        isempty(bad_out_anc) || throw(AssertionError(
            "ReversibleCircuit: ancilla wires $(sort!(collect(bad_out_anc))) " *
            "overlap output wires — the ancilla-zero check in `simulate` " *
            "would depend on f(x)"))

        # Bennett-s0tn: loop-check class disjoint from all three others.
        bad_lc_in = intersect(lc_set, in_set)
        isempty(bad_lc_in) || throw(AssertionError(
            "ReversibleCircuit: loop-check wires $(sort!(collect(bad_lc_in))) " *
            "overlap input wires — the loop-convergence check in `simulate` " *
            "would alias an input value (Bennett-s0tn)"))
        bad_lc_out = intersect(lc_set, out_set)
        isempty(bad_lc_out) || throw(AssertionError(
            "ReversibleCircuit: loop-check wires $(sort!(collect(bad_lc_out))) " *
            "overlap output wires — the loop-convergence check would alias " *
            "f(x) (Bennett-s0tn)"))
        bad_lc_anc = intersect(lc_set, anc_set)
        isempty(bad_lc_anc) || throw(AssertionError(
            "ReversibleCircuit: loop-check wires $(sort!(collect(bad_lc_anc))) " *
            "overlap ancilla wires — the ancilla-zero check would fire on a " *
            "loop-check value (Bennett-s0tn)"))

        covered = union(in_set, out_set, anc_set, lc_set)
        expected = Set(1:n_wires)
        missing_wires = setdiff(expected, covered)
        isempty(missing_wires) || throw(AssertionError(
            "ReversibleCircuit: wires $(sort!(collect(missing_wires))) are " *
            "not classified as input, output, ancilla, or loop-check " *
            "(n_wires=$n_wires)"))

        stray = setdiff(covered, expected)
        isempty(stray) || throw(AssertionError(
            "ReversibleCircuit: wire indices $(sort!(collect(stray))) exceed " *
            "n_wires=$n_wires"))

        return new(n_wires, gates, input_wires, output_wires, ancilla_wires,
                   input_widths, output_elem_widths, loop_check_wires)
    end
end

# Bennett-2jny / U101: standard collection protocols, delegating to the
# underlying gate vector. Lets callers write `for g in circuit`,
# `length(circuit)`, `circuit[i]`, `eltype(typeof(circuit))` etc.
Base.length(c::ReversibleCircuit)               = length(c.gates)
Base.iterate(c::ReversibleCircuit)              = iterate(c.gates)
Base.iterate(c::ReversibleCircuit, state)       = iterate(c.gates, state)
Base.eltype(::Type{ReversibleCircuit})          = ReversibleGate
Base.getindex(c::ReversibleCircuit, i::Integer) = c.gates[i]
Base.firstindex(c::ReversibleCircuit)           = firstindex(c.gates)
Base.lastindex(c::ReversibleCircuit)            = lastindex(c.gates)


# ==== Gate-type accessors (Bennett-mg6u / U201) ====
# Common (target, controls) projection used by dep_dag.jl + eager.jl. Lives
# here in gates.jl so both consumers can use it without depending on each
# other. Bennett-348q / U108: controls returned as tuples (isbits, stack-
# allocated) — both call sites only iterate, so a Tuple is transparent.

_gate_target(g::NOTGate)     = g.target
_gate_target(g::CNOTGate)    = g.target
_gate_target(g::ToffoliGate) = g.target

_gate_controls(g::NOTGate)     = ()
_gate_controls(g::CNOTGate)    = (g.control,)
_gate_controls(g::ToffoliGate) = (g.control1, g.control2)
