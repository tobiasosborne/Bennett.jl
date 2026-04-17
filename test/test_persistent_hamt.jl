# T5-P3c — Bagwell HAMT persistent map + reversible popcount
#
# Tests:
#   1. soft_popcount32 standalone correctness (1000 random UInt32 vs Base.count_ones)
#   2. soft_popcount32 reversible compilation + verify_reversibility
#   3. HAMT pure-Julia protocol contract (via harness verify_pmap_correctness)
#   4. HAMT demo oracle matches direct usage
#   5. HAMT compiled circuit matches oracle on sampled inputs
#   6. Gate count baseline (regression anchor)
#
# max_n = 8 (not 4): see src/persistent/hamt.jl header for rationale — ensures
# soft_popcount32 is genuinely exercised with non-trivial compressed indices.
#
# Hash simplification: for K=Int8, hash slot = low 5 bits of reinterpret(UInt8, k).
# Keys in range 1..28 are used for non-collision tests (each maps to a distinct slot).
# Key collision behaviour is tested explicitly in testset 3.

using Test
using Bennett

# Top-level demo function — LLVM IR extraction requires top-level (not closure)
# definitions per CLAUDE.md §5.
function _hamt_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                    k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = Bennett.hamt_pmap_new()
    s = Bennett.hamt_pmap_set(s, k1, v1)
    s = Bennett.hamt_pmap_set(s, k2, v2)
    s = Bennett.hamt_pmap_set(s, k3, v3)
    return Bennett.hamt_pmap_get(s, lookup)
end

@testset "T5-P3c — HAMT + reversible popcount" begin

    # ---- Testset 1: soft_popcount32 standalone correctness ----
    @testset "soft_popcount32 correctness (1000 random + edge cases)" begin
        # Edge cases
        for (x, expected) in [
                (UInt32(0),          UInt32(0)),
                (UInt32(1),          UInt32(1)),
                (UInt32(7),          UInt32(3)),
                (UInt32(0xFFFFFFFF), UInt32(32)),
                (UInt32(0x55555555), UInt32(16)),
                (UInt32(0xAAAAAAAA), UInt32(16)),
                (UInt32(0x0F0F0F0F), UInt32(16)),
            ]
            @test soft_popcount32(x) == expected
        end

        # 1000 random UInt32 inputs vs Base.count_ones
        rng_seed = 42
        xs = let
            # Deterministic pseudo-random without a separate Random import:
            # Use a simple LCG seeded at 42 to avoid Random module import.
            # (CLAUDE.md §5: minimize external state in test files.)
            # Actually we can just use rand after seeding.
            import Random; Random.seed!(rng_seed)
            rand(UInt32, 1000)
        end
        for x in xs
            @test soft_popcount32(x) == UInt32(count_ones(x))
        end
    end

    # ---- Testset 2: soft_popcount32 reversible compilation ----
    @testset "soft_popcount32 reversible compilation" begin
        c = reversible_compile(soft_popcount32, UInt32)
        @test c isa ReversibleCircuit
        @test verify_reversibility(c; n_tests=5)

        gc = gate_count(c)
        @info "T5-P3c popcount gate count" gates=gc
        # Correctness spot check via simulate
        @test simulate(c, (UInt32(0),))          == UInt32(0)
        @test simulate(c, (UInt32(1),))          == UInt32(1)
        @test simulate(c, (UInt32(0xFFFFFFFF),)) == UInt32(32)
        @test simulate(c, (UInt32(0x55555555),)) == UInt32(16)

        # Sanity bounds on gate count (measured 2026-04-17: 2782 total / 1004 Toffoli)
        @test 500 < gc.total < 50_000
        @test gc.Toffoli > 100
    end

    # ---- Testset 3: Pure-Julia protocol contract ----
    @testset "Pure-Julia contract — HAMT impl" begin
        @test verify_pmap_correctness(HAMT_IMPL)

        # Additional: explicit overwrite test
        s = hamt_pmap_new()
        s = hamt_pmap_set(s, Int8(5), Int8(50))
        s = hamt_pmap_set(s, Int8(5), Int8(99))
        @test hamt_pmap_get(s, Int8(5)) == Int8(99)   # latest-write wins

        # Miss returns zero
        @test hamt_pmap_get(hamt_pmap_new(), Int8(42)) == Int8(0)

        # Hash collision: key 0 and key 32 both map to slot 0 (5-bit hash = 0)
        # Latest write overwrites the slot.
        sc = hamt_pmap_new()
        sc = hamt_pmap_set(sc, Int8(0), Int8(7))
        sc = hamt_pmap_set(sc, Int8(32), Int8(13))
        @test hamt_pmap_get(sc, Int8(32)) == Int8(13)   # slot now holds key=32
        @test hamt_pmap_get(sc, Int8(0))  == Int8(0)    # key=0 displaced, returns miss
    end

    # ---- Testset 4: Demo oracle matches direct usage ----
    @testset "Demo oracle matches direct HAMT usage" begin
        # Use keys in 1..28 to avoid hash collisions (each has distinct 5-bit slot)
        for trial in 1:50
            k1, k2, k3 = rand(Int8(1):Int8(9), 3)
            v1, v2, v3 = rand(Int8, 3)
            lookup = rand([k1, k2, k3, Int8(100)])  # Int8(100) is a likely miss

            expected = pmap_demo_oracle(Int8, Int8, k1, v1, k2, v2, k3, v3, lookup)
            got      = _hamt_demo(k1, v1, k2, v2, k3, v3, lookup)
            @test got == expected
        end
    end

    # ---- Testset 5: Compiled circuit matches oracle ----
    @testset "Compiled HAMT circuit matches oracle on sampled inputs" begin
        c = reversible_compile(_hamt_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        @test c isa ReversibleCircuit
        @test verify_reversibility(c; n_tests=3)

        # Sample 20 random inputs (keys in 1..9 to avoid collisions)
        for trial in 1:20
            k1, k2, k3 = rand(Int8(1):Int8(9), 3)
            v1, v2, v3 = rand(Int8, 3)
            lookup      = rand([k1, k2, k3, Int8(100)])

            args     = (k1, v1, k2, v2, k3, v3, lookup)
            expected = _hamt_demo(args...)
            got      = simulate(c, args)
            @test got == expected
        end

        # Deterministic corner cases
        @test simulate(c, (Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(2))) == Int8(22)
        @test simulate(c, (Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(99))) == Int8(0)
        @test simulate(c, (Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))) ==
              _hamt_demo(Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
    end

    # ---- Testset 6: Gate count baseline (regression anchor) ----
    @testset "Gate count baseline" begin
        c = reversible_compile(_hamt_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        gc = gate_count(c)
        @info "T5-P3c HAMT demo gate count" gates=gc
        # Sanity bounds.  Measured 2026-04-17: 96788 total / 25576 Toffoli at max_n=8.
        # Wide bounds: HAMT is large; we want to catch regressions without blocking
        # valid optimisations.
        @test 10_000 < gc.total < 1_000_000
        @test gc.Toffoli > 1_000
    end

end
