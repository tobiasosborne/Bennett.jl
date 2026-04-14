"""
    emit_conditional_copy!(gates, wa, y_i_copies, x_copy, target, W)

Sun-Borissov 2026 §II.C. Implements `target[k] = y_i · x[k]` (bitwise) via
`W` Toffoli gates in parallel. The "conditional" is that `target` ends up
with `x` if `y_i=1` and zero otherwise.

`y_i_copies` is a `W`-wire register holding `W` identical copies of the single
bit `y_i` (produced upstream by `emit_fast_copy!` on `|y_i>`). `x_copy` is a
`W`-wire register holding one copy of `|x>`. All three registers must be
disjoint so the W Toffolis can run in one parallel layer (Toffoli-depth 1).

Precondition: `target` is all-zero on entry.
Postcondition: `target[k] = y_i_copies[k] ∧ x_copy[k]` for each bit k.
"""
function emit_conditional_copy!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                y_i_copies::Vector{Int}, x_copy::Vector{Int},
                                target::Vector{Int}, W::Int)
    length(y_i_copies) == W || error("emit_conditional_copy!: y_i_copies has $(length(y_i_copies)) wires, expected W=$W")
    length(x_copy)     == W || error("emit_conditional_copy!: x_copy has $(length(x_copy)) wires, expected W=$W")
    length(target)     == W || error("emit_conditional_copy!: target has $(length(target)) wires, expected W=$W")
    for k in 1:W
        push!(gates, ToffoliGate(y_i_copies[k], x_copy[k], target[k]))
    end
    return target
end

"""
    emit_partial_products!(gates, wa, y_bit_copies, x_copies, W) -> Vector{Vector{Int}}

Sun-Borissov 2026 §II.C (Algorithm 2). Produces all `W` partial products
`α^{(0,i)} = y_i · x` in a single Toffoli layer. Allocates `W` fresh `W`-wire
registers (one per partial product). Toffoli-depth 1, total `W²` Toffolis,
zero CNOTs.

Inputs:
- `y_bit_copies[i]` — a `W`-wire register holding `W` copies of the bit `y_i`.
  Produced upstream by broadcasting each bit of `|y>` (e.g. via `emit_fast_copy!`
  on `|y_i>`).
- `x_copies[i]` — the i-th copy of the `W`-bit register `|x>`. Typically the
  i-th output of `emit_fast_copy!(gates, wa, x, W, W)`.

Returns a length-`W` vector; the i-th entry is the register storing `α^{(0,i)}`.
"""
function emit_partial_products!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                y_bit_copies::Vector{Vector{Int}},
                                x_copies::Vector{Vector{Int}}, W::Int)
    length(y_bit_copies) == W ||
        error("emit_partial_products!: expected $W y_bit_copies entries, got $(length(y_bit_copies))")
    length(x_copies) == W ||
        error("emit_partial_products!: expected $W x_copies entries, got $(length(x_copies))")
    alpha = Vector{Vector{Int}}()
    for i in 1:W
        pp = allocate!(wa, W)
        emit_conditional_copy!(gates, wa, y_bit_copies[i], x_copies[i], pp, W)
        push!(alpha, pp)
    end
    return alpha
end
