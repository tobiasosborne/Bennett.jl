# ---- T5: persistent hash-consed heap (universal-fallback memory tier) ----
#
# Per Bennett-Memory-T5-PRD.md.  Three candidate persistent-DS impls behind
# a common protocol, plus reversible hash-cons compression layers, plus a
# shared correctness/benchmark harness.  Each impl is a pure Julia branchless
# function that Bennett.jl compiles via `register_callee!` — no direct gate
# emission (cf. softmem.jl pattern, NOT feistel.jl/qrom.jl pattern).
#
# Bennett-iwv5 / U90: wrapped in `module Persistent` so internal helpers
# (`_FEISTEL_HALF_W`, `_LS_STATE_LEN`, `_feistel_rotr16`, …) do NOT leak
# into Bennett's top-level namespace. Bennett.jl re-exports the public
# surface via `using .Persistent`.

module Persistent

include("interface.jl")
include("linear_scan.jl")
include("harness.jl")
include("hashcons_feistel.jl")

# Bennett-uoem / U54 — relocated to research/ (preserved, not loaded by
# default; opt-in via include of src/persistent/research/<file>.jl):
#   - okasaki_rbt.jl         (2026-04-25) — promoted out of research-only
#                                            on 2026-05-18 by Bennett-6883
#                                            (wired into _resolve_persistent_impl).
#   - cf_semi_persistent.jl  (2026-04-25)
#   - hashcons_jenkins.jl    (2026-04-25)
#   - hamt.jl + popcount.jl  (2026-04-25; popcount is HAMT-only) — promoted
#                                            out of research-only on 2026-05-20
#                                            by Bennett-d746.

# Bennett-6883 (2026-05-18) — :okasaki persistent_impl arm wired into
# the dispatcher. The file still lives under research/ for blame /
# history continuity but is loaded unconditionally because the impl is
# no longer research-tier once it's reachable from a public kwarg.
include("research/okasaki_rbt.jl")

# Bennett-d746 (2026-05-20) — :hamt persistent_impl arm wired into the
# dispatcher (byte-template duplicate of Bennett-6883's :okasaki wiring).
# popcount.jl MUST load before hamt.jl: hamt.jl's `_hamt_compressed_idx`
# / `hamt_pmap_get` call `soft_popcount32` defined in popcount.jl. Both
# files still live under research/ for blame / history continuity but
# are loaded unconditionally now that :hamt is reachable from a public
# kwarg.
include("research/popcount.jl")
include("research/hamt.jl")

# Public surface. Concrete impl helpers (`linear_scan_pmap_new` etc.) are
# exported because tests (test_ivoa_harness_invariants.jl) reach for them
# as `Bennett.linear_scan_pmap_*` after `using .Persistent` re-exports.
export AbstractPersistentMap, PersistentMapImpl,
       verify_pmap_correctness, verify_pmap_persistence_invariant,
       pmap_demo_oracle,
       LinearScanState, LINEAR_SCAN_IMPL,
       linear_scan_pmap_new, linear_scan_pmap_set, linear_scan_pmap_get,
       OkasakiState, OKASAKI_IMPL,
       okasaki_pmap_new, okasaki_pmap_set, okasaki_pmap_get,
       HamtState, HAMT_IMPL,
       hamt_pmap_new, hamt_pmap_set, hamt_pmap_get,
       soft_feistel32, soft_feistel_int8

end # module Persistent
