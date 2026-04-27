"""Shift-and-add multiplier: result = a * b  (mod 2^W)."""
function lower_mul!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                    a::Vector{Int}, b::Vector{Int}, W::Int)
    return lower_mul_wide!(gates, wa, a, b, W, W)
end

"""
Shift-and-add widening multiplier: result = a * b with `result_width` bits.

When result_width == W: standard mod 2^W multiplication.
When result_width == 2W: full product without truncation.
"""
function lower_mul_wide!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                         a::Vector{Int}, b::Vector{Int}, W::Int, result_width::Int)
    accum = allocate!(wa, result_width)
    # Bennett-5kio / U109: each outer iter pushes ≤W Toffolis (partial-prod
    # AND-tree) + lower_add! (~5*result_width gates). Total upper bound:
    # W*(W + 5*result_width). Avoids O(log²) reallocations as the gate
    # vector grows from ~0 to multi-thousand on Int32+ multiplies.
    sizehint!(gates, length(gates) + W * (W + 5 * result_width))
    for i in 1:W
        shift = i - 1
        pp = allocate!(wa, result_width)
        for k in 1:W
            dest = k + shift
            dest > result_width && break
            push!(gates, ToffoliGate(a[k], b[i], pp[dest]))
        end
        new_accum = lower_add!(gates, wa, accum, pp, result_width)
        accum = new_accum
    end
    return accum
end

# Karatsuba multiplier removed 2026-04-27 (Bennett-tbm6). The implementation
# was vestigial: at every supported width (W ≤ 64) the ancilla cost (Θ(W^log₂5)
# = ~W^2.32) dominated the Toffoli savings (Θ(W^log₂3) vs schoolbook Θ(W²)),
# producing Karatsuba:schoolbook Toffoli ratios from 3.49 (W=8) down to 1.91
# (W=64) — never crossing 1. The asymptotic crossover sits past W=128, beyond
# what `ir_extract` lowers. See Bennett-tbm6 for the empirical sweep and
# decision context.
