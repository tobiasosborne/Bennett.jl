# ---- Persistent map shared correctness + benchmark harness (T5-P3a) ----
#
# Two responsibilities:
#   1. `verify_pmap_correctness(impl)` — run the protocol's semantic
#      contract (interface.jl) on a pure-Julia level.  Compares against a
#      Julia `Dict{K,V}` reference.  No Bennett.jl compilation.  Catches
#      impl bugs before they hit the reversibilisation pipeline.
#   2. `compile_and_verify_pmap(impl)` — compile a representative demo
#      function (set 3 keys, get 1) via `reversible_compile`.  Verify
#      `verify_reversibility`.  Return gate count.  This is the cell that
#      goes into the Pareto front (T5-P7a).
#
# Each impl lives in its own file under src/persistent/ and provides a
# `<NAME>_IMPL :: PersistentMapImpl` binding the three protocol functions.
# The harness loops over registered impls.

"""
    verify_pmap_correctness(impl::PersistentMapImpl;
                            test_pairs = nothing) -> Bool

Pure Julia self-test: runs a sequence of `pmap_set` + `pmap_get` ops on
the impl, compares against a `Dict{K,V}` reference.  Returns `true` if
all checks pass; throws otherwise.

Default `test_pairs`: enumerate all distinct (k, v) pairs with k, v in
the K/V range, capped at impl.max_n insertions.  Latest-write semantics.

Use this BEFORE attempting Bennett.jl compilation — many impl bugs
surface here at zero gate cost.
"""
function verify_pmap_correctness(impl::PersistentMapImpl;
                                 test_pairs::Union{Nothing,Vector{<:Tuple}}=nothing)
    K, V = impl.K, impl.V

    # Default test sequence: a few inserts + an overwrite + lookups.
    if test_pairs === nothing
        # Pick keys/values inside K/V range, capped at max_n
        ks = collect(K, K(1):K(min(impl.max_n, typemax(K))))
        vs = collect(V, V(11):V(11+length(ks)-1))
        test_pairs = collect(zip(ks, vs))
    end

    # Reference impl
    ref = Dict{K, V}()
    state = impl.pmap_new()

    # Insert phase
    for (k, v) in test_pairs
        ref[k] = v
        state = impl.pmap_set(state, k, v)
    end

    # Lookup phase: every inserted key must round-trip
    for (k, expected) in pairs(ref)
        got = impl.pmap_get(state, k)
        got == expected ||
            error("verify_pmap_correctness($(impl.name)): get($k) = $got, expected $expected")
    end

    # Overwrite check (if room)
    if length(test_pairs) >= 1 && length(test_pairs) < impl.max_n
        k, _ = test_pairs[1]
        new_v = V(99)
        ref[k] = new_v
        state2 = impl.pmap_set(state, k, new_v)
        got = impl.pmap_get(state2, k)
        got == new_v ||
            error("verify_pmap_correctness($(impl.name)): overwrite get($k) = $got, expected $new_v")
    end

    # Empty-key lookup: pick a K value not yet inserted
    used = Set(first.(test_pairs))
    candidate = nothing
    for k in K(0):typemax(K)
        if !(k in used)
            candidate = k
            break
        end
    end
    if candidate !== nothing
        got = impl.pmap_get(state, candidate)
        got == zero(V) ||
            error("verify_pmap_correctness($(impl.name)): get($candidate) on missing key = $got, expected $(zero(V))")
    end

    return true
end

# NOTE: there is no factory for "demo function" — Bennett.jl extracts
# LLVM IR best from top-level (not closure) function definitions per
# CLAUDE.md §5.  Each per-impl test file defines its OWN top-level demo
# function (3 sets + 1 get) using its impl's protocol functions.  See
# test/test_persistent_interface.jl `_ls_demo` for the template.

"""
    pmap_demo_oracle(K, V, k1, v1, k2, v2, k3, v3, lookup) -> V

Pure-Julia reference for the demo function: simulate the 3-insert + 1-get
using a Dict{K,V}.  Used by the harness to verify the compiled circuit's
output matches.
"""
function pmap_demo_oracle(::Type{K}, ::Type{V},
                          k1, v1, k2, v2, k3, v3, lookup) where {K, V}
    d = Dict{K, V}()
    d[K(k1)] = V(v1)
    d[K(k2)] = V(v2)
    d[K(k3)] = V(v3)
    return get(d, K(lookup), zero(V))
end
