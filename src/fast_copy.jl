"""
    emit_fast_copy!(gates, wa, src, n_copies, W) -> Vector{Vector{Int}}

Sun-Borissov 2026 Algorithm 1: produce `n_copies` identical copies of the
`W`-bit computational-basis register `src` using a doubling broadcast. Each
timestep, every already-populated register simultaneously copies itself onto a
fresh zero register via `W` CNOT gates on disjoint qubits; the population
doubles per timestep.

Returns a length-`n_copies` vector whose first element is `src` and whose
remaining `n_copies-1` entries are newly allocated `W`-wire registers holding
the same basis state as `src`.

Gate complexity: `(n_copies - 1) * W` CNOTs, zero Toffolis. Depth:
`ceil(log2(n_copies))` (0 when `n_copies == 1`).

Used in the Sun-Borissov multiplier to create `n` parallel copies of `|x>` and
`|y>` for the `partial_products` stage (`src/partial_products.jl`).
"""
function emit_fast_copy!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                         src::Vector{Int}, n_copies::Int, W::Int)
    n_copies >= 1 || error("emit_fast_copy!: n_copies must be >= 1, got $n_copies")
    length(src) == W || error("emit_fast_copy!: src has $(length(src)) wires but W=$W")

    populated = Vector{Vector{Int}}([src])
    while length(populated) < n_copies
        new_regs = Vector{Vector{Int}}()
        for src_reg in populated
            length(populated) + length(new_regs) >= n_copies && break
            tgt = allocate!(wa, W)
            for i in 1:W
                push!(gates, CNOTGate(src_reg[i], tgt[i]))
            end
            push!(new_regs, tgt)
        end
        append!(populated, new_regs)
    end
    return populated
end
