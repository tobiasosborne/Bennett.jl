# Bennett-8403 / U159 — per-source-file unit-test home for `src/lower.jl`.
#
# `src/lower.jl` is now (post-Bennett-vdlg / U40) a 12-line module loader
# that includes 9 files under `src/lowering/`. Per-arm lowering tests
# (binop, icmp, select, phi, alloca, store, load, call, etc.) live in
# the existing feature-oriented `test_<topic>.jl` suites — each lowers
# representative IR patterns end-to-end and pins gate-count baselines.
#
# This stub covers the `lower(parsed::ParsedIR; ...)` entry-point
# dispatch surface (kwarg validation, strategy-dispatch routing, error
# messages), independent of which arm gets invoked.

using Test
using Bennett

@testset "src/lower.jl unit tests" begin

    @testset "lower() rejects unknown add strategy" begin
        parsed = extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
        @test_throws ArgumentError Bennett.lower(parsed; add=:cuckoo)
    end

    @testset "lower() rejects unknown mul strategy" begin
        parsed = extract_parsed_ir((a, b) -> a * b, Tuple{Int8, Int8})
        @test_throws ArgumentError Bennett.lower(parsed; mul=:fft)
    end

    @testset "lower() rejects unknown target" begin
        parsed = extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
        @test_throws ArgumentError Bennett.lower(parsed; target=:wire_count)
    end

    @testset "lower() :auto + target=:depth pre-resolves mul to qcla_tree" begin
        # Per Bennett-4fri / U30, `target=:depth` rewrites `mul=:auto` to
        # `:qcla_tree` before dispatch. End-to-end visible via gate count.
        parsed = extract_parsed_ir((a, b) -> a * b, Tuple{Int8, Int8})
        lr_gc    = Bennett.lower(parsed; target=:gate_count)
        lr_depth = Bennett.lower(parsed; target=:depth)
        # qcla_tree has more Toffolis than shift_add at W=8 — must differ.
        nT_gc    = count(g -> g isa Bennett.ToffoliGate, lr_gc.gates)
        nT_depth = count(g -> g isa Bennett.ToffoliGate, lr_depth.gates)
        @test nT_gc != nT_depth
    end

    @testset "lower(parsed; max_loop_iterations) demands explicit unroll for loops" begin
        # Collatz-style loop — LLVM cannot fold to straight-line because
        # the `if-even` branch makes the iteration count data-dependent.
        # The back-edge survives into ParsedIR.
        f = function (x::Int8)
            val = x
            steps = Int8(0)
            while val > Int8(1) && steps < Int8(20)
                val = val % Int8(2) == Int8(0) ? val >> Int8(1) : Int8(3) * val + Int8(1)
                steps += Int8(1)
            end
            steps
        end
        parsed = extract_parsed_ir(f, Tuple{Int8})
        # No max_loop_iterations → fail loud (Bennett-httg contract;
        # post-vpch this is ArgumentError, was ErrorException pre-2026-05-01).
        @test_throws ArgumentError Bennett.lower(parsed)
        # With max_loop_iterations set → succeeds.
        lr = Bennett.lower(parsed; max_loop_iterations=20)
        @test !isempty(lr.gates)
    end
end
