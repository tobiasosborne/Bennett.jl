# T5-P3d — Conchon-Filliâtre semi-persistent array as reversible persistent map
#
# Mirrors test/test_persistent_interface.jl exactly (5 testsets).
# Reference: docs/literature/memory/cf_semipersistent_brief.md
# Bead: Bennett-6thy
#
# The CF semi-persistent map keeps a materialised Arr (always current version)
# plus a Diff undo-stack.  get is O(max_n) scan of Arr; set is O(max_n)
# branchless scan + Diff push.  reroot pops the Diff stack (not called by get,
# but tested here for correspondence verification).
#
# See §5 of the brief and the correspondence evaluation in cf_semi_persistent.jl
# for the Bennett-tape / Diff-chain equivalence argument.

using Test
using Bennett

# ── Top-level demo function (Bennett.jl needs top-level for LLVM extraction) ──

function _cf_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                  k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = Bennett.cf_pmap_new()
    s = Bennett.cf_pmap_set(s, k1, v1)
    s = Bennett.cf_pmap_set(s, k2, v2)
    s = Bennett.cf_pmap_set(s, k3, v3)
    return Bennett.cf_pmap_get(s, lookup)
end

# ── Helper: reroot test (explicit uncompute correspondence) ───────────────────

# Demo function that sets 2 values then peeks at the intermediate version via
# reroot (undoing the second set) — verifies the Diff chain is correct.
function _cf_reroot_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8)::Int8
    s  = Bennett.cf_pmap_new()
    s1 = Bennett.cf_pmap_set(s,  k1, v1)
    s2 = Bennett.cf_pmap_set(s1, k2, v2)
    # Undo the second set by rerooting once
    s3 = Bennett.cf_reroot(s2)
    # After reroot: s3 should look like s1 (only k1→v1 stored)
    return Bennett.cf_pmap_get(s3, k1)
end

@testset "T5-P3d — Conchon-Filliâtre semi-persistent map" begin

    # ── 1. Pure-Julia contract ────────────────────────────────────────────────

    @testset "Pure-Julia contract — CF semi-persistent" begin
        @test verify_pmap_correctness(CF_IMPL)
    end

    # ── 2. Demo oracle matches direct stub usage ──────────────────────────────

    @testset "Demo oracle matches CF impl" begin
        for trial in 1:50
            k1, k2, k3 = rand(Int8, 3)
            v1, v2, v3 = rand(Int8, 3)
            lookup = rand([k1, k2, k3, rand(Int8)])

            expected = pmap_demo_oracle(Int8, Int8, k1, v1, k2, v2, k3, v3, lookup)
            got      = _cf_demo(k1, v1, k2, v2, k3, v3, lookup)
            @test got == expected
        end

        # Corner cases
        @test _cf_demo(Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0)) ==
              pmap_demo_oracle(Int8, Int8, Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
        @test _cf_demo(Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(2)) == Int8(22)
        @test _cf_demo(Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(99)) == Int8(0)

        # Overwrite: latest value wins
        s = cf_pmap_new()
        s = cf_pmap_set(s, Int8(5), Int8(50))
        s = cf_pmap_set(s, Int8(5), Int8(99))   # overwrite same key
        @test cf_pmap_get(s, Int8(5)) == Int8(99)

        # Distinct keys don't interfere
        s = cf_pmap_new()
        s = cf_pmap_set(s, Int8(7), Int8(70))
        s = cf_pmap_set(s, Int8(8), Int8(80))
        @test cf_pmap_get(s, Int8(7)) == Int8(70)
        @test cf_pmap_get(s, Int8(8)) == Int8(80)
        @test cf_pmap_get(s, Int8(9)) == Int8(0)   # miss
    end

    # ── 3. Reroot / Diff-chain correspondence test ────────────────────────────
    #
    # Bennett-tape correspondence (brief §5): the Diff chain IS Bennett's tape;
    # cf_reroot IS the uncompute step.  We verify this at the pure-Julia level:
    # calling cf_reroot once undoes exactly one cf_pmap_set.

    @testset "Reroot / Diff-chain (Bennett-tape correspondence)" begin
        # After 3 sets, reroot×3 should restore the empty state
        s = cf_pmap_new()
        s = cf_pmap_set(s, Int8(1), Int8(10))
        s = cf_pmap_set(s, Int8(2), Int8(20))
        s = cf_pmap_set(s, Int8(3), Int8(30))
        @test s[1] == UInt64(3)   # diff_depth == 3

        # Undo one set
        s2 = cf_reroot(s)
        @test s2[1] == UInt64(2)  # depth decreased
        @test cf_pmap_get(s2, Int8(3)) == Int8(0)   # slot 3 gone
        @test cf_pmap_get(s2, Int8(1)) == Int8(10)  # earlier slots intact
        @test cf_pmap_get(s2, Int8(2)) == Int8(20)

        # Undo all the way back
        s3 = cf_reroot(s2)
        s4 = cf_reroot(s3)
        @test s4[1] == UInt64(0)  # depth == 0 (fully unwound)
        @test cf_pmap_get(s4, Int8(1)) == Int8(0)
        @test cf_pmap_get(s4, Int8(2)) == Int8(0)

        # Overwrite + reroot: restore previous value for same key
        s = cf_pmap_new()
        s = cf_pmap_set(s, Int8(42), Int8(7))
        s = cf_pmap_set(s, Int8(42), Int8(99))  # overwrite
        @test cf_pmap_get(s, Int8(42)) == Int8(99)
        s_rewound = cf_reroot(s)
        @test cf_pmap_get(s_rewound, Int8(42)) == Int8(7)  # restored

        # _cf_reroot_demo: reroot restores k1's value from before k2 was set
        @test _cf_reroot_demo(Int8(3), Int8(30), Int8(7), Int8(70)) == Int8(30)
        @test _cf_reroot_demo(Int8(0), Int8(1), Int8(2), Int8(3)) == Int8(1)
    end

    # ── 4. Reversible compilation ─────────────────────────────────────────────

    @testset "Reversible compilation of CF demo" begin
        c = reversible_compile(_cf_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        @test c isa ReversibleCircuit
        @test verify_reversibility(c; n_tests=3)
    end

    # ── 5. Compiled circuit matches oracle on sampled inputs ──────────────────

    @testset "Compiled circuit matches oracle (sampled)" begin
        c = reversible_compile(_cf_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)

        for trial in 1:30
            args = (rand(Int8), rand(Int8), rand(Int8), rand(Int8),
                    rand(Int8), rand(Int8), rand(Int8))
            expected = _cf_demo(args...)
            got      = simulate(c, args)
            @test got == expected
        end

        # Corner cases
        @test simulate(c, (Int8(0), Int8(0), Int8(0), Int8(0),
                           Int8(0), Int8(0), Int8(0))) ==
              _cf_demo(Int8(0), Int8(0), Int8(0), Int8(0),
                       Int8(0), Int8(0), Int8(0))
        @test simulate(c, (Int8(1), Int8(11), Int8(2), Int8(22),
                           Int8(3), Int8(33), Int8(2))) == Int8(22)
        @test simulate(c, (Int8(1), Int8(11), Int8(2), Int8(22),
                           Int8(3), Int8(33), Int8(99))) == Int8(0)
    end

    # ── 6. Gate count baseline ────────────────────────────────────────────────

    @testset "Gate count baseline (regression anchor)" begin
        c = reversible_compile(_cf_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        gc = gate_count(c)
        @info "T5-P3d CF demo gate count" gates=gc
        # Broad sanity bounds (regression anchor).  Measured on first GREEN run;
        # actual value logged above via @info.
        @test 100 < gc.total < 500_000
        @test gc.Toffoli > 0
    end

end
