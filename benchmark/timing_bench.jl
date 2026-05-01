#!/usr/bin/env julia
"""
Bennett-sa39 / U211 — BenchmarkTools-based compile-time benchmarks.

Run with the benchmark-local project:

    julia --project=benchmark benchmark/timing_bench.jl

Three timing classes:

1. **Tiny** — `x + 1` at Int8 / Int64. Should be sub-second cold.
2. **Medium** — Cuccaro adder Int32. Includes loop unrolling at depth.
3. **Heavy** — full SHA-256 round (BC.5 path) + soft_fadd Float64.
   Both cross-check known-stable compile times that have shifted
   under refactors before (worklog/048 qxg9 33× speedup is the
   regression-prevention motivation).

Each measurement uses `@benchmark` with a small sample size (`samples=3,
seconds=120` ceiling) — compile time benchmarks are slow per sample,
so a small N with a generous wall-clock cap matches what
PkgBenchmark.jl + GitHub Actions style regressions would do.

The `bc{1..6}_*.jl` files in this directory measure GATE-COUNT
metrics (Toffoli, ancillae, depth) rather than wall time; they're
complementary, not redundant. Compile-time changes are invisible to
the gate-count benchmarks but BenchmarkTools catches them.
"""

using BenchmarkTools
using Bennett

# Force a single representative compile up front so the @benchmark
# samples below measure steady-state cost, not first-time IR-extract
# cache-warming.
println("--- Warming caches ---")
warmup = reversible_compile(x -> x + Int8(1), Int8)
println("warmup gate count: ", gate_count(warmup))
println()

println("=== Tiny: x + 1 ===")

bench_inc_i8 = @benchmark reversible_compile(x -> x + Int8(1), Int8) samples=5 seconds=30
display(bench_inc_i8); println()

bench_inc_i64 = @benchmark reversible_compile(x -> x + Int64(1), Int64) samples=3 seconds=60
display(bench_inc_i64); println()

println("=== Medium: Cuccaro adder Int32 (a + b) ===")

bench_add_i32 = @benchmark reversible_compile((a, b) -> a + b, Int32, Int32; add=:cuccaro) samples=3 seconds=60
display(bench_add_i32); println()

println("=== Heavy: soft_fadd Float64 ===")

bench_softfadd = @benchmark reversible_compile(Bennett.soft_fadd, UInt64, UInt64) samples=3 seconds=120
display(bench_softfadd); println()

println("=== Done ===")
