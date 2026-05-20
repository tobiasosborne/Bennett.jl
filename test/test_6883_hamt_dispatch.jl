# Bennett-d746 — wire :hamt persistent_impl arm in _resolve_persistent_impl.
#
# Byte-template duplicate of test/test_6883_okasaki_dispatch.jl. Mirrors
# test/test_t5_p6_persistent_dispatch.jl testset 2 (3-key roundtrip via
# :linear_scan) but with persistent_impl=:hamt and the hamt_pmap_*
# callees instead of linear_scan_pmap_*. The hamt impl was loaded into
# the Bennett.Persistent submodule (research/popcount.jl + research/hamt.jl
# — popcount loads first because hamt_pmap_get calls soft_popcount32) and
# its set/get callees registered in _CALLEES_PERSISTENT (6-tuple post-d746:
# linear_scan_pmap_set/get + okasaki_pmap_set/get + hamt_pmap_set/get);
# _resolve_persistent_impl gained the `:hamt + :none` arm returning
# Bennett.HAMT_IMPL.
#
# Per CLAUDE.md §4: every test calls verify_reversibility AND checks an
# oracle. Per consensus / the original z2dj template: 3-key insert + 1-get
# Julia source function uses top-level definitions (not closure) so the
# Julia frontend extracts LLVM IR via the IRCall machinery, threading the
# HamtState explicitly through the registered callees (SROA does not
# bite because the state lives in callee returns, not allocas).
#
# HASH-COLLISION CAVEAT (Bennett-d746): the HAMT impl is a single-level
# BitmapIndexedNode whose hash slot is the low 5 bits of the key
# (`_hamt_slot(k) = reinterpret(UInt8, k) & 0x1F`). Two keys that are
# congruent mod 32 collide into the same slot, and the impl handles
# this with latest-write-wins (no collision node). `pmap_demo_oracle`'s
# Dict uses exact-key semantics, so it is only a faithful oracle for
# HAMT when the 3 inserted keys occupy DISTINCT 5-bit slots. The random
# sweeps below therefore draw collision-free keys (mirrors the
# established convention in test/test_persistent_hamt.jl, which uses
# keys 1..28 to avoid collisions). Collision behaviour is itself a HAMT
# design simplification documented in src/persistent/research/hamt.jl —
# not in scope for the dispatcher-wiring bead.

using Test
using Bennett

# Draw 3 Int8 keys that occupy DISTINCT HAMT 5-bit slots (no hash
# collision under `reinterpret(UInt8, k) & 0x1F`). This keeps the
# pmap_demo_oracle Dict a faithful reference for the HAMT impl.
function _d746_distinct_hamt_keys()
    slot(k) = Int(reinterpret(UInt8, k)) & 0x1F
    while true
        k1, k2, k3 = rand(Int8), rand(Int8), rand(Int8)
        s1, s2, s3 = slot(k1), slot(k2), slot(k3)
        if s1 != s2 && s1 != s3 && s2 != s3
            return k1, k2, k3
        end
    end
end

# Top-level demo function — 3-key insert + 1-get via the hamt impl.
# Same shape as test_t5_p6_persistent_dispatch.jl::_z2dj_ls_demo, but
# routed through Bennett.hamt_pmap_*.
function _d746_hamt_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                         k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = Bennett.hamt_pmap_new()
    s = Bennett.hamt_pmap_set(s, k1, v1)
    s = Bennett.hamt_pmap_set(s, k2, v2)
    s = Bennett.hamt_pmap_set(s, k3, v3)
    return Bennett.hamt_pmap_get(s, lookup)
end

@testset "Bennett-d746 — :hamt persistent_impl dispatcher arm" begin

    @testset "hamt impl loaded and conforms to pure-Julia contract" begin
        # Ensure the impl is reachable from Bennett and satisfies the
        # PersistentMapImpl protocol (interface.jl) at the pure-Julia
        # level. Catches loading / export bugs before compilation.
        @test isdefined(Bennett, :HAMT_IMPL)
        @test isdefined(Bennett, :hamt_pmap_new)
        @test isdefined(Bennett, :hamt_pmap_set)
        @test isdefined(Bennett, :hamt_pmap_get)
        @test Bennett.verify_pmap_correctness(Bennett.HAMT_IMPL)
    end

    @testset "demo oracle matches direct stub usage" begin
        for _trial in 1:30
            k1, k2, k3 = _d746_distinct_hamt_keys()
            v1, v2, v3 = rand(Int8), rand(Int8), rand(Int8)
            lookup = rand([k1, k2, k3, rand(Int8)])
            expected = Bennett.pmap_demo_oracle(Int8, Int8,
                                                 k1, v1, k2, v2, k3, v3, lookup)
            got      = _d746_hamt_demo(k1, v1, k2, v2, k3, v3, lookup)
            @test got == expected
        end
    end

    @testset "3-key roundtrip via :hamt (compiles, reversible, matches oracle)" begin
        c = reversible_compile(_d746_hamt_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8;
                               mem=:persistent, persistent_impl=:hamt)

        # Reversibility — Bennett's correctness invariant (CLAUDE.md §4).
        @test Bennett.verify_reversibility(c)

        # Concrete corner cases.
        # (a) All zeros: insert 3 zero pairs, lookup zero. Oracle returns V(0).
        let args = (Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test Bennett.simulate(c, args) == expected
        end
        # (b) HIT: lookup matches a stored key (the middle one).
        let args = (Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(2))
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test expected == Int8(22)  # sanity-check the oracle
            @test Bennett.simulate(c, args) == expected
        end
        # (c) MISS: lookup matches no stored key.
        let args = (Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(99))
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test expected == Int8(0)  # sanity-check the oracle
            @test Bennett.simulate(c, args) == expected
        end

        # Small random sweep. hamt max_n=8 — insert exactly 3 keys per
        # trial. Keys are drawn collision-free (distinct 5-bit HAMT
        # slots) so pmap_demo_oracle's exact-key Dict stays a faithful
        # reference — see the HASH-COLLISION CAVEAT in the file header.
        for _trial in 1:10
            k1, k2, k3 = _d746_distinct_hamt_keys()
            v1, v2, v3 = rand(Int8), rand(Int8), rand(Int8)
            lookup = rand([k1, k2, k3, rand(Int8)])
            args = (k1, v1, k2, v2, k3, v3, lookup)
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test Bennett.simulate(c, args) == expected
        end

        # Gate-count info for the worklog (NOT pinned). Gate counts will
        # differ from linear_scan / okasaki because the HAMT impl uses a
        # branchless soft_popcount32 compressed-index path.
        gc = Bennett.gate_count(c)
        @info "Bennett-d746 :hamt 3-key demo gate count" gates=gc
    end
end
