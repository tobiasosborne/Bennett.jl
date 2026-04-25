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
    # Bennett-ivoa / U121: k=0 is included as a STORED key (not just
    # probed as absent below) so impls that special-case key=0 as a
    # slot-unused sentinel — a known anti-pattern — surface here.
    if test_pairs === nothing
        # Pick keys 0..max_n-1 (so K(0) is always among the stored keys),
        # values from V(11) onward.  Capped to typemax(K) on narrow K.
        last_k = K(min(impl.max_n - 1, typemax(K)))
        ks = collect(K, K(0):last_k)
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
    verify_pmap_persistence_invariant(impl::PersistentMapImpl) -> Bool

Verify the persistent contract: `pmap_set` returns a NEW state and the
old snapshot remains unchanged.  Bug class this catches: an impl that
mutates underlying storage (Ref, Vector, Dict) silently breaks
persistence even though `pmap_set` and `pmap_get` look correct in
isolation.

Sequence: insert (k, v_old), snapshot the state, overwrite (k, v_new),
then assert `pmap_get(state_old, k) == v_old`.  Throws on violation,
returns `true` on success.

Filed as Bennett-ivoa / U121 — the original harness exercised the
return value of `pmap_set` (correct) but never checked the input value
(silently buggy in a mutating impl).
"""
function verify_pmap_persistence_invariant(impl::PersistentMapImpl)
    K, V = impl.K, impl.V
    k = K(1)
    v_old = V(11)
    v_new = V(99)

    s0 = impl.pmap_new()
    s1 = impl.pmap_set(s0, k, v_old)
    s2 = impl.pmap_set(s1, k, v_new)

    got_old = impl.pmap_get(s1, k)
    got_old == v_old ||
        error("verify_pmap_persistence_invariant($(impl.name)): old snapshot ",
              "mutated by subsequent pmap_set — got $got_old, expected $v_old. ",
              "Impl is not persistent.")

    got_new = impl.pmap_get(s2, k)
    got_new == v_new ||
        error("verify_pmap_persistence_invariant($(impl.name)): new snapshot ",
              "lookup wrong — got $got_new, expected $v_new.")

    got_empty = impl.pmap_get(s0, k)
    got_empty == zero(V) ||
        error("verify_pmap_persistence_invariant($(impl.name)): empty snapshot ",
              "lookup leaked — got $got_empty, expected $(zero(V)). ",
              "Impl is mutating pmap_new()'s state.")

    return true
end

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
