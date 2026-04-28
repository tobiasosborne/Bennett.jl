# ---- Precompile workload (Bennett-19g6 extracted from Bennett.jl) ----
#
# Bennett-w0fc / U52: precompile workload.
#
# Without this block the FIRST call to `reversible_compile` after
# `using Bennett` paid ~20s of latency-to-first-execution (LLVM.jl
# C-API walk + per-opcode dispatch + type-stable specialisation of
# the lowering machinery, all hit cold).  Subsequent calls were
# ~10× faster (1-2s).  The workload below pays that 20s once at
# package precompile time so the user's first call is fast.
#
# Cost: precompile time grows by the wall-clock of these workloads
# (~25-30s on this hardware).  Acceptable trade — package precompile
# happens once per environment / package upgrade, TTFX hits every
# fresh REPL session.
#
# Coverage rationale: each workload exercises a distinct lowering
# path so the specialisation cache covers the common entry points.
#   * Int8 add — narrowest, tiny circuit, exercises the basic shift+add
#   * Int32 mul — widening multiplication path
#   * Int64 add — widest integer path
#   * Float64 add — soft-float dispatch + UInt64 wrapper compile
using PrecompileTools

PrecompileTools.@compile_workload begin
    reversible_compile(x -> x + Int8(1),    Int8)
    reversible_compile(x -> x * Int32(3),   Int32)
    reversible_compile(x -> x + Int64(7),   Int64)
    reversible_compile(x -> x + 1.0,        Float64)
end
