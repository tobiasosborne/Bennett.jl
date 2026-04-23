mutable struct WireAllocator
    next_wire::Int
    free_list::Vector{Int}   # sorted DESCENDING — pop! gets minimum, O(1)
end

WireAllocator() = WireAllocator(1, Int[])

function allocate!(wa::WireAllocator, n::Int)
    # Bennett-swee / U24: negative-n silently returned `Int[]` under the
    # old `for _ in 1:n` loop (zero-trip), and an empty wire vector
    # propagated downstream into the Bennett construction, blowing up
    # later as a BoundsError far from the root cause. `n == 0` is a
    # legitimate request for zero wires (some loop-unroll corner cases
    # produce it).
    n >= 0 || throw(ArgumentError(
        "WireAllocator.allocate!: n must be >= 0, got $n"))
    wires = Int[]
    for _ in 1:n
        if !isempty(wa.free_list)
            # Reuse freed wire (pop min from descending-sorted list = pop last element)
            push!(wires, pop!(wa.free_list))
        else
            push!(wires, wa.next_wire)
            wa.next_wire += 1
        end
    end
    return wires
end

"""Return wires to the allocator for reuse. Wires MUST be in zero state.

Bennett-swee / U24: `free!` now rejects double-frees. Pre-fix a wire
freed twice appeared in the free list twice, and a later `allocate!`
would hand out the same wire number to two distinct consumers. The
detector is a linear scan of the existing free list per freed wire —
O(N²) worst case, acceptable for Bennett's allocator sizes (typically
< a few thousand wires).
"""
function free!(wa::WireAllocator, wires::Vector{Int})
    for w in wires
        if w in wa.free_list
            throw(ArgumentError(
                "WireAllocator.free!: double-free of wire $w " *
                "(Bennett-swee / U24)"))
        end
        # Insert into descending-sorted list
        idx = searchsortedlast(wa.free_list, w; rev=true) + 1
        insert!(wa.free_list, idx, w)
    end
end

wire_count(wa::WireAllocator) = wa.next_wire - 1
