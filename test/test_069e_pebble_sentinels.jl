# Bennett-069e / U143 — pebbling.jl uses two named sentinels for the
# Knill DP table:
#
#   _PEBBLE_INF          — fill value: "no finite cost yet"
#   _PEBBLE_FINITE_BOUND — gate: cost < this means "real finite cost"
#
# These tests pin the invariants the comment block claims:
#   1. 3 · _PEBBLE_FINITE_BOUND < typemax(Int) — adding three real costs
#      can never overflow Int.
#   2. _PEBBLE_INF >= _PEBBLE_FINITE_BOUND — any cell still holding the
#      init sentinel fails the finite-cost gate.
#
# Plus an end-to-end correctness check: knill_pebble_cost agrees with
# the published F(2, 2) = 3 base case.

using Test
using Bennett

@testset "Bennett-069e / U143 — pebble DP sentinels" begin

    @testset "sentinel arithmetic invariants" begin
        inf_  = Bennett._PEBBLE_INF
        fb    = Bennett._PEBBLE_FINITE_BOUND

        # No-overflow: 3 finite-bound costs sum below typemax(Int).
        @test 3 * Int128(fb) < Int128(typemax(Int))

        # Init sentinel is large enough that the finite-cost gate
        # rejects it, so still-uncomputed cells never participate
        # in the addition.
        @test inf_ >= fb

        # Any realistically small cost (e.g. 1, 100, 10000) is < fb.
        @test 1     < fb
        @test 10^4  < fb
        @test 10^9  < fb
    end

    @testset "knill_pebble_cost: published base cases" begin
        # Base case from Knill 1995 Theorem 2.1:
        #   F(1, s) = 1 for s >= 1
        for s in 1:5
            @test Bennett.knill_pebble_cost(1, s) == 1
        end

        # F(n, 1) = unreachable (only one pebble, can't free + reuse).
        # Implementation returns the _PEBBLE_INF sentinel.
        @test Bennett.knill_pebble_cost(2, 1) == Bennett._PEBBLE_INF
        @test Bennett.knill_pebble_cost(5, 1) == Bennett._PEBBLE_INF

        # F(2, 2) = F(1,2) + F(1,1) + F(1,1) = 1 + 1 + 1 = 3.
        @test Bennett.knill_pebble_cost(2, 2) == 3
    end

    @testset "min_pebbles + knill_split_point sanity" begin
        # min_pebbles(n) >= 1; pebbling needs >= 1 pebble for n >= 1.
        @test Bennett.min_pebbles(1) == 1
        @test Bennett.min_pebbles(2) >= 2
        @test Bennett.min_pebbles(8) >= 4

        # knill_split_point(n, s) returns 0 for trivial cases.
        @test Bennett.knill_split_point(1, 5) == 0
        @test Bennett.knill_split_point(5, 1) == 0

        # For (4, 3) it returns a valid split index in [1, n-1].
        m = Bennett.knill_split_point(4, 3)
        @test 1 <= m <= 3
    end
end
