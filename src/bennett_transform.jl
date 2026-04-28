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
Build the canonical U03 probe battery for a self_reversing contract check:
four fixed deterministic input bit-vectors (all-zero, all-one, walking-1 on
the first input wire, walking-1 on the last input wire). Coverage rationale:
all-zero detects unconditional ancilla flips; all-one activates every Toffoli
control simultaneously; the walking-1 probes catch per-lane leakage that a
fully quiescent or fully active input would miss. Deterministic — CLAUDE.md
§4 and §6 both favour reproducible failures over randomised sweeps.
"""
function _u03_self_reversing_probes(total_in::Int)
    probes = Tuple{String,Vector{Bool}}[]
    push!(probes, ("all-zero",  falses(total_in)))
    push!(probes, ("all-one",   trues(total_in)))
    if total_in >= 1
        p = falses(total_in); p[1] = true
        push!(probes, ("walking-1-first-lane", p))
    end
    if total_in >= 2
        p = falses(total_in); p[end] = true
        push!(probes, ("walking-1-last-lane",  p))
    end
    return probes
end

"""
Bennett-egu6 / U03: runtime check that an `lr` with `self_reversing=true`
actually keeps Bennett's invariants. For each probe vector, forward-execute
`lr.gates` on a fresh bit array seeded from the probe, then assert
  (1) every ancilla wire is zero after the forward pass, and
  (2) every input wire holds its original probe bit.
Raises `ErrorException` with probe/wire/expected/actual context on violation.
Reuses `apply!` (src/simulator.jl:1-3) and `_compute_ancillae` — CLAUDE.md
§13 (no duplicated lowering).
"""
function _validate_self_reversing!(lr::LoweringResult)
    total_in = sum(lr.input_widths)
    ancilla_set = _compute_ancillae(lr.n_wires, lr.input_wires, lr.output_wires)
    for (name, probe_bits) in _u03_self_reversing_probes(total_in)
        bits = zeros(Bool, lr.n_wires)
        offset = 0
        for w in lr.input_widths
            for i in 1:w
                bits[lr.input_wires[offset + i]] = probe_bits[offset + i]
            end
            offset += w
        end
        snapshot = [bits[w] for w in lr.input_wires]

        for g in lr.gates
            apply!(bits, g)
        end

        for w in ancilla_set
            bits[w] && error("bennett(): self_reversing=true contract violated — ancilla wire $w is 1 after forward pass under probe '$name' (n_wires=$(lr.n_wires), n_gates=$(length(lr.gates))). Fix the producer or drop the self_reversing flag.")
        end
        for (k, w) in pairs(lr.input_wires)
            bits[w] == snapshot[k] ||
                error("bennett(): self_reversing=true contract violated — input wire $w changed from $(snapshot[k]) to $(bits[w]) under probe '$name' (n_wires=$(lr.n_wires), n_gates=$(length(lr.gates))). Fix the producer or drop the self_reversing flag.")
        end
    end
    return nothing
end

"""
    bennett(lr::LoweringResult) -> ReversibleCircuit

Bennett's 1973 construction: forward + copy-out + uncompute.

Reference: Charles H. Bennett, "Logical Reversibility of Computation",
IBM Journal of Research and Development, 17(6):525–532, 1973.
DOI: 10.1147/rd.176.0525.  The paper proves that any computation can be
made reversible at the cost of additional auxiliary memory by recording
intermediate results, copying out the final answer, and then running
the forward computation in reverse to clear the record.  The whole
codebase is named after this paper.

# Pre-reversed primitives (`self_reversing=true`)

When `lr.self_reversing` is `true`, the lowering result is already a
self-cleaning gate sequence — its ancillae end zero AND its result lives
on the primary output wires WITHOUT any wrap. Examples:

- `lower_tabulate(f, ...)` — QROM lookup `(x, 0^W) → (x, f(x))`, see
  src/tabulate.jl:208-212 for the canonical caller.
- `lower_mul_qcla_tree!` — Sun-Borissov polylogarithmic-depth
  multiplier, src/mul_qcla_tree.jl.

For these, this function short-circuits to forward-only emission — no
copy-out, no reverse pass — typically halving the gate count and saving
`n_out` ancillae. The U03 contract probe (`_validate_self_reversing!`,
Bennett-egu6) catches forged self_reversing claims at compile time.

Construction sites that produce a self-reversing `lr` MUST set the flag
explicitly via the 8-arg `LoweringResult` constructor (the 6-arg + 7-arg
convenience forms default `self_reversing=false`):

```julia
lr = LoweringResult(gates, n_wires, input_wires, output_wires,
                    input_widths, output_elem_widths,
                    GateGroup[], true)   # ← self_reversing=true
```

For downstream users (e.g. Sturm.jl) who construct a guaranteed-self-
reversing primitive AND want to assert that contract loud, see
[`bennett_direct`](@ref).
"""
function bennett(lr::LoweringResult)
    # P1: self-reversing primitives (e.g. Sun-Borissov multiplier, QROM
    # tabulate) already end with ancillae clean and the result in
    # lr.output_wires. Skip the copy-out + reverse pass — it would just
    # double the gate count. Bennett-egu6 / U03: validate the primitive's
    # contract before trusting it; silent acceptance of a broken
    # self_reversing primitive would poison every downstream circuit.
    if lr.self_reversing
        _validate_self_reversing!(lr)
        # Bennett-nj5r / U200: pass lr.gates directly. ReversibleCircuit
        # stores the array but does not mutate it; no caller mutates
        # lr.gates after bennett() returns (verified across src/eager.jl,
        # src/value_eager.jl, src/pebbling.jl, etc.). Skipping the
        # defensive copy saves O(n_gates) allocation on every
        # self_reversing circuit (lower_tabulate, mul_qcla_tree).
        return _build_circuit(lr.gates, lr.n_wires, lr.input_wires,
                              lr.output_wires, lr)
    end

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

"""
    bennett_direct(lr::LoweringResult) -> ReversibleCircuit

Forward-only path for already-reversible `lr`. Asserts
`lr.self_reversing == true` (errors loud otherwise) and delegates to
[`bennett`](@ref), which short-circuits the wrap. Convenience entry
point for downstream library authors (Sturm.jl, future quantum
backends) who construct a self-cleaning primitive and want to make the
"no Bennett wrap" assumption load-bearing at the call site instead of
buried in a constructor argument.

The contract is identical to `bennett(lr)` with `self_reversing=true`:
the U03 probe battery (`_validate_self_reversing!`) runs, and a forged
claim — dirty ancillae or input mutation — raises a precise error
naming the offending wire (Bennett-egu6 / U03).

If `lr.self_reversing == false`, this raises `ArgumentError` rather
than silently wrapping. Use `bennett(lr)` if you want the conditional
behavior.

# Example
```julia
# Self-cleaning primitive (e.g. QROM lookup):
gates = ReversibleGate[]
out_wires = emit_qrom!(gates, wa, table, idx_wires, W)
lr = LoweringResult(gates, wire_count(wa), idx_wires, out_wires,
                    [length(idx_wires)], [W],
                    GateGroup[], true)   # self_reversing=true
c = bennett_direct(lr)   # forward-only, ~½ the gates of bennett-with-wrap
```

(Bennett-cvnb / Sturm.jl-ao1 — surfaces the existing `self_reversing`
fast path with a discoverable name.)
"""
function bennett_direct(lr::LoweringResult)
    lr.self_reversing || throw(ArgumentError(
        "bennett_direct: lr.self_reversing must be true. The 6-arg and " *
        "7-arg LoweringResult convenience constructors default it to " *
        "false; pass `true` as the 8th positional arg, or use `bennett(lr)` " *
        "if you want the standard forward + copy-out + uncompute wrap " *
        "(Bennett-cvnb / Sturm.jl-ao1)."))
    return bennett(lr)
end
