# T5-P3a — Persistent map protocol + harness self-test
#
# Verifies:
#   1. The shared interface compiles and exports correctly
#   2. The linear-scan stub satisfies the protocol contract (pure Julia)
#   3. The stub is reversible-compilable end-to-end via Bennett.jl
#   4. The compiled circuit's output matches the pmap_demo_oracle
#
# This file is the GREEN target for T5-P3a (Bennett-isab).  Subsequent
# tracks (T5-P3b/c/d) reuse the same harness against their respective
# impls.

using Test
using Bennett

# Top-level demo function — Bennett.jl extracts LLVM IR best from
# top-level (not closure) definitions, per CLAUDE.md §5.
function _ls_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                  k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = Bennett.linear_scan_pmap_new()
    s = Bennett.linear_scan_pmap_set(s, k1, v1)
    s = Bennett.linear_scan_pmap_set(s, k2, v2)
    s = Bennett.linear_scan_pmap_set(s, k3, v3)
    return Bennett.linear_scan_pmap_get(s, lookup)
end

@testset "T5-P3a — Persistent map protocol + harness" begin

    @testset "Pure-Julia contract — linear scan stub" begin
        @test verify_pmap_correctness(LINEAR_SCAN_IMPL)
    end

    @testset "Demo oracle matches direct stub usage" begin
        for trial in 1:50
            k1, k2, k3 = rand(Int8, 3)
            v1, v2, v3 = rand(Int8, 3)
            # Pick lookup randomly: half the time pick a stored key, half a fresh one
            lookup = rand([k1, k2, k3, rand(Int8)])

            expected = pmap_demo_oracle(Int8, Int8, k1, v1, k2, v2, k3, v3, lookup)
            got      = _ls_demo(k1, v1, k2, v2, k3, v3, lookup)
            @test got == expected
        end
    end

    @testset "Reversible compilation of stub demo" begin
        # Compile the demo: 7 Int8 args, returns Int8.
        c = reversible_compile(_ls_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        @test c isa ReversibleCircuit
        @test verify_reversibility(c; n_tests=3)
    end

    @testset "Compiled circuit matches oracle on sampled inputs" begin
        c = reversible_compile(_ls_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        # Sample 30 random inputs.  Full exhaustive sweep is 2^56 — out
        # of reach.  Random sample plus the corner cases below catches
        # most regressions.
        for trial in 1:30
            args = (rand(Int8), rand(Int8), rand(Int8), rand(Int8),
                    rand(Int8), rand(Int8), rand(Int8))
            expected = _ls_demo(args...)
            got      = simulate(c, args)
            @test got == expected
        end

        # Corner cases: all zeros, lookup = stored key, lookup = miss
        @test simulate(c, (Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))) ==
              _ls_demo(Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
        @test simulate(c, (Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(2))) == Int8(22)
        @test simulate(c, (Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(99))) == Int8(0)
    end

    @testset "Gate count baseline (regression anchor)" begin
        c = reversible_compile(_ls_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        gc = gate_count(c)
        @info "T5-P3a stub demo gate count" gates=gc
        # Sanity bounds.  Measured 2026-04-17: 436 total / 90 Toffoli at
        # max_n=4.  Bounds are wide so naive optimisation tweaks don't
        # spuriously trip the regression.
        @test 100 < gc.total < 100_000
        @test gc.Toffoli > 0
    end
end
