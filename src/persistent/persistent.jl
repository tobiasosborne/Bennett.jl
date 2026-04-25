# ---- T5: persistent hash-consed heap (universal-fallback memory tier) ----
#
# Per Bennett-Memory-T5-PRD.md.  Three candidate persistent-DS impls behind
# a common protocol, plus reversible hash-cons compression layers, plus a
# shared correctness/benchmark harness.  Each impl is a pure Julia branchless
# function that Bennett.jl compiles via `register_callee!` — no direct gate
# emission (cf. softmem.jl pattern, NOT feistel.jl/qrom.jl pattern).

include("interface.jl")
include("linear_scan.jl")
include("harness.jl")
include("popcount.jl")
include("hamt.jl")
include("hashcons_jenkins.jl")
include("hashcons_feistel.jl")

# Bennett-uoem / U54 — relocated to research/ (preserved, not loaded by
# default; opt-in via include of src/persistent/research/<file>.jl):
#   - okasaki_rbt.jl         (2026-04-25)
#   - cf_semi_persistent.jl  (2026-04-25)
