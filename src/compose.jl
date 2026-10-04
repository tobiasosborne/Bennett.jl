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
#
# # Loop guards (Bennett-q9pi)
#
# Bennett-s0tn loop-convergence wires (`loop_check_wires`) are carried
# through. c2's guards are renumbered like any other c2 wire. c1's guards
# need care: a c1 guard wire is SET by a gate inside `c1.gates`, so the
# trailing reverse-c1 pass would uncompute it back to 0 — silently turning
# the convergence bit into a clean-looking ancilla (pre-q9pi behaviour:
# an under-unrolled loop in c1 returned garbage through compose). Each c1
# guard bit is therefore CNOT-copied onto a fresh wire between c2 and
# reverse-c1; the copy is the composite's guard, the original wire is an
# ancilla. Cost: +1 wire, +1 CNOT per c1 guard; zero for loop-free c1.
#
# # N-ary pipelines (Bennett-7c5u)
#
# `compose(c1, c2, ..., cn)` generalises the construction: c1 … cn forward
# (each ck's inputs aliased onto c(k-1)'s outputs), then each intermediate
# stage uncomputed ONCE, in reverse order — guard copies of ck immediately
# before reverse(ck), for k = n-1 down to 1. Gates: Σ|ck| + Σ_{k<n}(|ck| +
# guards(ck)), i.e. linear in n. The binary `compose(c1, c2)` is exactly the
# n = 2 case. The composite does not remember its stages, so LEFT-folding
# the binary form (`compose(compose(a, b), c)`) re-embeds the whole left
# composite twice per step: |a|·(2^n − 1) gates for n copies of `a`. Pass
# the stages to one call (or fold from the right) instead.

@inline _renumber_gate(g::NOTGate, m::Vector{Int})     = NOTGate(m[g.target])
@inline _renumber_gate(g::CNOTGate, m::Vector{Int})    = CNOTGate(m[g.control], m[g.target])
@inline _renumber_gate(g::ToffoliGate, m::Vector{Int}) = ToffoliGate(m[g.control1], m[g.control2], m[g.target])

"""
    compose(c1::ReversibleCircuit, c2::ReversibleCircuit, cs::ReversibleCircuit...) -> ReversibleCircuit
    compose(cs::AbstractVector{<:ReversibleCircuit}) -> ReversibleCircuit

Pipeline composition. Returns a circuit whose semantics are
`simulate(compose(c1, c2), x) == simulate(c2, simulate(c1, x))`, and in
general `simulate(compose(c1, …, cn), x) == simulate(cn, … simulate(c1, x))`.
Each stage's inputs are positionally aliased to the previous stage's
outputs, so `ck.output_elem_widths == c(k+1).input_widths` is required.
The vector form is the same builder; a one-element vector returns its
circuit unchanged, an empty one throws.

# Cost of each association (Bennett-7c5u)

Writing `|c|` for `length(c.gates)` and `g(c)` for
`length(c.loop_check_wires)`:

- `compose(c1, …, cn)` / `compose([c1, …, cn])`:
  `Σ_k |ck| + Σ_{k<n} (|ck| + g(ck))` gates — every stage forward once,
  every intermediate stage uncomputed once. LINEAR in n. For n copies of
  `x + Int8(1)` (58 gates): `58·(2n − 1)`.
- Right fold `compose(c1, compose(c2, …))`: the same gate count (linear).
- Left fold `compose(compose(c1, c2), c3)`: the binary form embeds its
  first argument twice, and a composite does not remember its stages, so
  each left-associated step doubles the left composite: `58·(2^n − 1)`
  gates for n stages of `x + 1`. EXPONENTIAL — do not left-fold binary
  `compose` over a pipeline; call the n-ary form (`compose(cs...)` or
  `compose(cs)`) or `foldr(compose, cs)` instead.

# Wire layout

The result's wire space is `1:W` with
`W = c1.n_wires + Σ_{k≥2} (ck.n_wires − mk) + Σ_{k<n} g(ck)`, where
`mk = length(ck.input_wires)`. c1's wires keep their indices; each later
stage's non-input wires (its outputs, ancillae and loop-check wires) get
fresh indices in stage order starting at `c1.n_wires + 1`; its input wires
alias onto the previous stage's (renumbered) output wires; the last
`Σ_{k<n} g(ck)` wires hold copies of the intermediate stages'
loop-convergence bits, in stage order.

# Gate sequence

`c1 ++ c2' ++ … ++ cn' ++ guard_copies(c(n-1)) ++ reverse(c(n-1)') ++ … ++
guard_copies(c1) ++ reverse(c1)`, where `ck'` is ck renumbered and
`guard_copies(ck)` is one CNOT per ck loop guard (empty when ck is
loop-free). For n = 2 this is `c1 ++ c2' ++ guard_copies(c1) ++
reverse(c1)`. Each `reverse(ck')` uncomputes ck's intermediate output so
that ck's output wires (ancillae of the composite) end at zero. This
relies on c(k+1) preserving its inputs (Bennett invariant); the
`simulator.jl` input-preservation assertion catches a violation.

# Loop guards (Bennett-q9pi)

`loop_check_wires` of every stage are preserved, in stage order, so an
input on which any stage's unrolled loop fails to converge makes
`simulate` on the composite throw, naming the EARLIEST failing stage
(the root cause, since its after-K garbage feeds the later stages).

# Preconditions

- `ck.output_elem_widths == c(k+1).input_widths` (per-position width match).
- No stage is self-reversing (`input_wires ∩ output_wires == ∅`).
  Self-reversing primitives (Sun-Borissov mul, QROM tabulate) overwrite
  their inputs with their outputs — aliasing the next stage's inputs onto
  them races with the reverse pass.
- Every stage satisfies the Bennett-pksz / U98 contiguous-wire invariant
  (every gate references wires in `1:n_wires`).

# Example

```jldoctest; setup = :(using Bennett)
julia> c1 = reversible_compile(x -> x + Int8(1), Int8);

julia> c2 = reversible_compile(x -> x + Int8(2), Int8);

julia> c12 = compose(c1, c2);

julia> simulate(c12, Int8(5))
8

julia> verify_reversibility(c12)
true

julia> c121 = compose(c1, c2, c1);   # c1 c2 c1 forward, c2 c1 uncomputed once

julia> simulate(c121, Int8(5)), length(c121.gates)   # 2·58 + 2·54 + 58
(9, 282)
```
"""
compose(c1::ReversibleCircuit, c2::ReversibleCircuit, cs::ReversibleCircuit...) =
    _compose_chain(ReversibleCircuit[c1, c2, cs...])

function compose(cs::AbstractVector{<:ReversibleCircuit})
    isempty(cs) && throw(ArgumentError(
        "compose: empty pipeline — need at least one circuit (Bennett-7c5u)"))
    length(cs) == 1 && return cs[1]
    return _compose_chain(ReversibleCircuit[c for c in cs])
end

# Precondition checks for one stage pair / one stage; `k` is the 1-based
# stage index used in the error messages ("c1", "c2", ...).
function _compose_check_seam(a::ReversibleCircuit, b::ReversibleCircuit, k::Int)
    if a.output_elem_widths != b.input_widths
        throw(ArgumentError(
            "compose: c$k.output_elem_widths=$(a.output_elem_widths) does not " *
            "match c$(k+1).input_widths=$(b.input_widths) — c$(k+1)'s inputs must " *
            "align positionally with c$k's outputs (Bennett-qcso / U59)"))
    end
    if length(a.output_wires) != length(b.input_wires)
        throw(ArgumentError(
            "compose: c$k has $(length(a.output_wires)) output wires but c$(k+1) " *
            "has $(length(b.input_wires)) input wires — sum-of-widths matched but " *
            "wire counts disagree (likely a malformed circuit)"))
    end
end

function _compose_check_stage(c::ReversibleCircuit, k::Int)
    sr = intersect(Set(c.input_wires), Set(c.output_wires))
    if !isempty(sr)
        throw(ArgumentError(
            "compose: c$k is self-reversing — input_wires ∩ output_wires = " *
            "$(sort!(collect(sr))). MVP rejects self-reversing inputs " *
            "(Sun-Borissov mul, QROM tabulate, etc.); the reverse pass " *
            "would race with the next stage's reads. A future kwarg may " *
            "relax this (Bennett-qcso / U59 §C)"))
    end
    if !isempty(c.gates)
        mx = maximum(_gate_max_wire, c.gates)
        mx <= c.n_wires || throw(ArgumentError(
            "compose: c$k references wire $mx > c$k.n_wires=$(c.n_wires). " *
            "Bennett-pksz / U98 contiguous-wire invariant violated."))
    end
end

function _compose_chain(cs::Vector{ReversibleCircuit})
    n = length(cs)
    @assert n >= 2 "_compose_chain: need ≥ 2 stages, got $n"

    # ---- Preconditions (every seam first, then every stage) ----
    for k in 1:n-1
        _compose_check_seam(cs[k], cs[k+1], k)
    end
    for k in 1:n
        _compose_check_stage(cs[k], k)
    end

    # ---- Step 1: per-stage wire renumber maps (compacted) ----
    # Stage 1 keeps its indices (identity map). Stage k ≥ 2: inputs alias
    # onto stage k-1's renumbered outputs; every other wire is fresh.
    maps = Vector{Vector{Int}}(undef, n)
    maps[1] = collect(1:cs[1].n_wires)
    next_fresh = cs[1].n_wires + 1
    for k in 2:n
        c, prev = cs[k], cs[k-1]
        mp = Vector{Int}(undef, c.n_wires)
        aliased = falses(c.n_wires)
        for (j, w_in) in enumerate(c.input_wires)
            mp[w_in] = maps[k-1][prev.output_wires[j]]
            aliased[w_in] = true
        end
        for w in 1:c.n_wires
            aliased[w] && continue
            mp[w] = next_fresh
            next_fresh += 1
        end
        # A loop-check wire is disjoint from the stage's inputs (four-set
        # partition in the ReversibleCircuit constructor), so never aliased.
        for lg in c.loop_check_wires
            @assert !aliased[lg.wire] "compose: c$k loop-check wire $(lg.wire) aliases a c$k input"
        end
        maps[k] = mp
    end
    @assert next_fresh - 1 ==
            cs[1].n_wires + sum(cs[k].n_wires - length(cs[k].input_wires) for k in 2:n) "compose: wire-budget compaction mismatch"

    # ---- Step 1b (Bennett-q9pi): loop-guard wires ----
    # An intermediate stage's guard is SET by a gate inside that stage, so
    # its trailing reverse pass uncomputes it back to 0; each such guard bit
    # is CNOT-copied onto a fresh wire before that stage's reverse pass. The
    # original wire then ends at 0 and is classified as an ancilla (checked
    # clean); the fresh copy is the composite's guard. The LAST stage is
    # never reversed, so its guards are simply renumbered. Stage order is
    # kept so an overflow is reported at the earliest (root-cause) stage.
    guard_copies = [Int[] for _ in 1:n]
    loop_check_wires = LoopGuard[]
    for k in 1:n-1
        for lg in cs[k].loop_check_wires
            push!(guard_copies[k], next_fresh)
            push!(loop_check_wires, LoopGuard(next_fresh, lg.header_label, lg.K))
            next_fresh += 1
        end
    end
    for lg in cs[n].loop_check_wires
        push!(loop_check_wires, LoopGuard(maps[n][lg.wire], lg.header_label, lg.K))
    end
    n_total = next_fresh - 1

    # ---- Step 2: gate list: forward c1..cn, then reverse c(n-1)..c1 ----
    new_gates = ReversibleGate[]
    sizehint!(new_gates, sum(c -> length(c.gates), cs) +
                         sum(k -> length(cs[k].gates) + length(guard_copies[k]), 1:n-1))
    append!(new_gates, cs[1].gates)
    for k in 2:n, g in cs[k].gates
        push!(new_gates, _renumber_gate(g, maps[k]))
    end
    for k in n-1:-1:1
        c, mp = cs[k], maps[k]
        for (lg, w_copy) in zip(c.loop_check_wires, guard_copies[k])
            push!(new_gates, CNOTGate(mp[lg.wire], w_copy))
        end
        for i in length(c.gates):-1:1
            push!(new_gates, _renumber_gate(c.gates[i], mp))
        end
    end

    # ---- Step 3: assemble result ReversibleCircuit ----
    c_first, c_last = cs[1], cs[n]
    input_wires        = copy(c_first.input_wires)
    input_widths       = copy(c_first.input_widths)
    output_wires       = [maps[n][w] for w in c_last.output_wires]
    output_elem_widths = copy(c_last.output_elem_widths)
    ancilla_wires      = _compute_ancillae(n_total, input_wires, output_wires,
                                           loop_check_wires)

    return ReversibleCircuit(n_total, new_gates, input_wires, output_wires,
                             ancilla_wires, input_widths, output_elem_widths,
                             loop_check_wires;
                             # Bennett-13xy: the composite returns the last stage's output.
                             output_elem_unsigned=c_last.output_elem_unsigned)
end
