# T5-P3b — Okasaki RBT persistent map: correctness + reversibility
#
# Mirrors test/test_persistent_interface.jl exactly (5 testsets).
# Reference: Okasaki 1999 JFP 9(4):471–477; Kahrs 2001 (delete deferred).
#
# Implementation: src/persistent/okasaki_rbt.jl
# Protocol: src/persistent/interface.jl
#
# Design note: delete is NOT implemented in this bead (deferred to
# Bennett-cc0.1 per Kahrs 2001 — ~2× the insert complexity).  The
# pmap_set "latest write wins" semantics fully satisfies the protocol.

using Test
using Bennett

# Bennett-uoem / U54 — Okasaki was relocated to src/persistent/research/ on
# 2026-04-25 and is no longer auto-loaded by `using Bennett`.  Pull it in
# explicitly so this gated suite can exercise it.  See
# src/persistent/research/README.md for the rationale.
include(joinpath(pkgdir(Bennett), "src", "persistent", "research", "okasaki_rbt.jl"))

# Top-level demo function (same shape as _ls_demo in test_persistent_interface.jl).
# Three sets + one get.  Must be top-level for clean LLVM IR extraction.
function _ok_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                  k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = okasaki_pmap_new()
    s = okasaki_pmap_set(s, k1, v1)
    s = okasaki_pmap_set(s, k2, v2)
    s = okasaki_pmap_set(s, k3, v3)
    return okasaki_pmap_get(s, lookup)
end

@testset "T5-P3b — Okasaki RBT persistent map" begin

    # ---- Testset 1: Pure-Julia contract ----
    @testset "Pure-Julia contract via verify_pmap_correctness" begin
        @test verify_pmap_correctness(OKASAKI_IMPL)
    end

    # ---- Testset 2: Oracle matches ----
    @testset "50 random oracle matches" begin
        for trial in 1:50
            k1, k2, k3 = rand(Int8, 3)
            v1, v2, v3 = rand(Int8, 3)
            lookup = rand([k1, k2, k3, rand(Int8)])

            expected = pmap_demo_oracle(Int8, Int8, k1, v1, k2, v2, k3, v3, lookup)
            got      = _ok_demo(k1, v1, k2, v2, k3, v3, lookup)
            @test got == expected
        end

        # Deterministic corner cases
        # All same key (latest write wins = v3)
        @test _ok_demo(Int8(1), Int8(10), Int8(1), Int8(20), Int8(1), Int8(30), Int8(1)) == Int8(30)
        # Lookup on missing key → 0
        @test _ok_demo(Int8(1), Int8(10), Int8(2), Int8(20), Int8(3), Int8(30), Int8(99)) == Int8(0)
        # Balanced insert 5,3,1 (triggers LL balance case)
        @test _ok_demo(Int8(5), Int8(50), Int8(3), Int8(30), Int8(1), Int8(10), Int8(3)) == Int8(30)
        # Balanced insert 1,3,5 (triggers RR balance case)
        @test _ok_demo(Int8(1), Int8(10), Int8(3), Int8(30), Int8(5), Int8(50), Int8(3)) == Int8(30)
        # LR balance case: 5, 1, 3
        @test _ok_demo(Int8(5), Int8(50), Int8(1), Int8(10), Int8(3), Int8(30), Int8(3)) == Int8(30)
        # RL balance case: 1, 5, 3
        @test _ok_demo(Int8(1), Int8(10), Int8(5), Int8(50), Int8(3), Int8(30), Int8(3)) == Int8(30)
    end

    # ---- Testset 3: Reversible compilation + verify_reversibility ----
    @testset "reversible_compile + verify_reversibility" begin
        c = reversible_compile(_ok_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        @test c isa ReversibleCircuit
        # n_tests=3 per CLAUDE.md §4 (exhaustive not feasible for 7 Int8 args)
        @test verify_reversibility(c; n_tests=3)
    end

    # ---- Testset 4: Compiled circuit vs oracle ----
    @testset "≥30 random circuit-vs-oracle matches" begin
        c = reversible_compile(_ok_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)

        for trial in 1:30
            args = (rand(Int8), rand(Int8), rand(Int8), rand(Int8),
                    rand(Int8), rand(Int8), rand(Int8))
            expected = _ok_demo(args...)
            got      = simulate(c, args)
            @test got == expected
        end

        # Deterministic corner cases
        @test simulate(c, (Int8(0), Int8(0), Int8(0), Int8(0),
                           Int8(0), Int8(0), Int8(0))) ==
              _ok_demo(Int8(0), Int8(0), Int8(0), Int8(0),
                       Int8(0), Int8(0), Int8(0))
        @test simulate(c, (Int8(1), Int8(11), Int8(2), Int8(22),
                           Int8(3), Int8(33), Int8(2))) == Int8(22)
        @test simulate(c, (Int8(1), Int8(11), Int8(2), Int8(22),
                           Int8(3), Int8(33), Int8(99))) == Int8(0)
        # All balance cases
        @test simulate(c, (Int8(5), Int8(50), Int8(3), Int8(30),
                           Int8(1), Int8(10), Int8(1))) == Int8(10)   # LL
        @test simulate(c, (Int8(1), Int8(10), Int8(3), Int8(30),
                           Int8(5), Int8(50), Int8(5))) == Int8(50)   # RR
        @test simulate(c, (Int8(5), Int8(50), Int8(1), Int8(10),
                           Int8(3), Int8(30), Int8(5))) == Int8(50)   # LR
        @test simulate(c, (Int8(1), Int8(10), Int8(5), Int8(50),
                           Int8(3), Int8(30), Int8(1))) == Int8(10)   # RL
    end

    # ---- Testset 5: Gate count baseline anchor ----
    @testset "Gate count baseline (record, not enforced)" begin
        c = reversible_compile(_ok_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        gc = gate_count(c)
        @info "T5-P3b Okasaki RBT demo gate count" total=gc.total Toffoli=gc.Toffoli NOT=gc.NOT CNOT=gc.CNOT wires=c.n_wires
        # Sanity bounds only (wide — no regression enforcement per PRD §8)
        @test gc.total > 100
        @test gc.Toffoli > 0
    end

end
