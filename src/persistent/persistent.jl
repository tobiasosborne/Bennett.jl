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
