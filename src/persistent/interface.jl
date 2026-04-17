# ---- Persistent map protocol (T5-P3a) ----
#
# Each persistent-DS implementation (Okasaki RBT, HAMT, Conchon-Filliâtre)
# provides three pure Julia functions matching this convention:
#
#     <impl>_pmap_new()                          :: PMapState
#     <impl>_pmap_set(s::PMapState, k::K, v::V) :: PMapState
#     <impl>_pmap_get(s::PMapState, k::K)       :: V
#
# Where:
#   * `K`, `V` are concrete signed/unsigned integer types (Int8, UInt16, ...)
#   * `PMapState` is a fully-typed NTuple of UInt64 (or similar bit-shaped
#     value) — must be lowerable by Bennett.jl, so no Vectors / Refs /
#     dynamic types.  The NTuple size baked at type-construction time
#     determines the impl's static `max_n`.
#   * "branchless" means: gate count is independent of input data — uses
#     `ifelse` and arithmetic, not data-dependent `if`.
#
# Semantic contract (any conforming impl must satisfy):
#
#     pmap_get(pmap_new(), k)            == zero(V)            for all k
#     pmap_get(pmap_set(s, k, v), k)     == v
#     pmap_get(pmap_set(s, k, v2), k)    == v2     # latest write wins
#     pmap_get(pmap_set(s, k1, v), k2)   == pmap_get(s, k2)   for k1 ≠ k2
#
# After max_n distinct keys have been inserted, behaviour is impl-defined:
#   * Okasaki may rebalance into deeper tree
#   * HAMT may demote a BitmapIndexedNode → ArrayNode
#   * Linear-scan stub (this file's companion) clamps to most-recent max_n
#
# The shared harness (`harness.jl`) verifies the contract by exhaustive
# input sweep against a Julia `Dict{K,V}` reference.  Each impl picks its
# concrete K/V/max_n at definition site and registers a "demo function"
# the harness can `reversible_compile`.
#
# This file defines the abstract protocol type for documentation +
# helpers; concrete impls do NOT subtype it (Julia function-as-interface
# pattern is more compositional than abstract-type dispatch here).

"""
Marker type for persistent-map implementations.  Subtype only for
documentation purposes; the protocol is enforced by the harness, not by
Julia dispatch.

Usage in an impl file:
```
struct OkasakiPMap <: AbstractPersistentMap end
const PMAP_NAME = "okasaki_rbt"
```
"""
abstract type AbstractPersistentMap end

"""
Bundle a single persistent-map impl into a single value the harness can
loop over.  An impl registers itself like:

```
const LINEAR_SCAN_IMPL = PersistentMapImpl(
    name      = "linear_scan",
    K         = Int8,
    V         = Int8,
    max_n     = 4,
    pmap_new  = linear_scan_pmap_new,
    pmap_set  = linear_scan_pmap_set,
    pmap_get  = linear_scan_pmap_get,
)
```

Then the harness can do `verify_pmap_correctness(LINEAR_SCAN_IMPL)` and
`measure_pmap_gates(LINEAR_SCAN_IMPL)` uniformly.
"""
Base.@kwdef struct PersistentMapImpl{F_NEW, F_SET, F_GET, K_T, V_T}
    name::String
    K::Type{K_T}
    V::Type{V_T}
    max_n::Int
    pmap_new::F_NEW
    pmap_set::F_SET
    pmap_get::F_GET
end
