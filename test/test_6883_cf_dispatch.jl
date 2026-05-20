# Bennett-qi6c — wire :cf persistent_impl arm in _resolve_persistent_impl.
#
# Byte-template duplicate of test/test_6883_okasaki_dispatch.jl and
# test/test_6883_hamt_dispatch.jl. Mirrors test/test_t5_p6_persistent_dispatch.jl
# testset 2 (3-key roundtrip via :linear_scan) but with persistent_impl=:cf
# and the cf_pmap_* callees instead of linear_scan_pmap_*. The CF
# (Conchon-Filliâtre semi-persistent map) impl was loaded into the
# Bennett.Persistent submodule (research/cf_semi_persistent.jl — no extra
# dependency: it uses only PersistentMapImpl + `ifelse`) and its set/get
# callees registered in _CALLEES_PERSISTENT (8-tuple post-qi6c:
# linear_scan_pmap_set/get + okasaki_pmap_set/get + hamt_pmap_set/get +
# cf_pmap_set/get); _resolve_persistent_impl gained the `:cf + :none` arm
# returning Bennett.CF_IMPL.
#
# Per CLAUDE.md §4: every test calls verify_reversibility AND checks an
# oracle. Per consensus / the original z2dj template: 3-key insert + 1-get
# Julia source function uses top-level definitions (not closure) so the
# Julia frontend extracts LLVM IR via the IRCall machinery, threading the
# CFState explicitly through the registered callees (SROA does not bite
# because the state lives in callee returns, not allocas).
#
# COLLISION-FREE (unlike the :hamt sibling): CF's Arr is a (key, val)
# store in INSERTION ORDER, not hash-indexed — lookup is an O(max_n)
# linear scan over the materialised Arr. There is no hash slot and hence
# no mod-32 collision footgun (cf. the _d746_distinct_hamt_keys rejection
# sampler that test_6883_hamt_dispatch.jl needs). pmap_demo_oracle's
# exact-key Dict is therefore a faithful reference for ALL Int8 keys, so
# this test uses plain `rand(Int8)` keys directly — same as the :okasaki
# template. The only caveat (verified GREEN before wiring) is the
# Bennett-n3z4 / U21 reroot-key=0 regression: cf_pmap_set encodes the
# was-allocated flag in bit 63 of the diff index so cf_reroot no longer
# infers it from `old_key == 0` — verify_pmap_correctness(CF_IMPL) passes.

using Test
using Bennett

# Top-level demo function — 3-key insert + 1-get via the cf impl.
# Same shape as test_t5_p6_persistent_dispatch.jl::_z2dj_ls_demo, but
# routed through Bennett.cf_pmap_*.
function _qi6c_cf_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                       k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = Bennett.cf_pmap_new()
    s = Bennett.cf_pmap_set(s, k1, v1)
    s = Bennett.cf_pmap_set(s, k2, v2)
    s = Bennett.cf_pmap_set(s, k3, v3)
    return Bennett.cf_pmap_get(s, lookup)
end

@testset "Bennett-qi6c — :cf persistent_impl dispatcher arm" begin

    @testset "cf impl loaded and conforms to pure-Julia contract" begin
        # Ensure the impl is reachable from Bennett and satisfies the
        # PersistentMapImpl protocol (interface.jl) at the pure-Julia
        # level. Catches loading / export bugs before compilation.
        @test isdefined(Bennett, :CF_IMPL)
        @test isdefined(Bennett, :cf_pmap_new)
        @test isdefined(Bennett, :cf_pmap_set)
        @test isdefined(Bennett, :cf_pmap_get)
        @test Bennett.verify_pmap_correctness(Bennett.CF_IMPL)
    end

    @testset "demo oracle matches direct stub usage" begin
        # CF is collision-free — plain random keys are fine. We still draw
        # 3 distinct keys per trial so the 3-key insert exercises 3 Arr
        # slots (a key repeat would overwrite, which is a separate case
        # covered by the corner cases below).
        for _trial in 1:30
            k1, k2, k3 = rand(Int8), rand(Int8), rand(Int8)
            (k1 == k2 || k1 == k3 || k2 == k3) && continue
            v1, v2, v3 = rand(Int8), rand(Int8), rand(Int8)
            lookup = rand([k1, k2, k3, rand(Int8)])
            expected = Bennett.pmap_demo_oracle(Int8, Int8,
                                                 k1, v1, k2, v2, k3, v3, lookup)
            got      = _qi6c_cf_demo(k1, v1, k2, v2, k3, v3, lookup)
            @test got == expected
        end
    end

    @testset "3-key roundtrip via :cf (compiles, reversible, matches oracle)" begin
        c = reversible_compile(_qi6c_cf_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8;
                               mem=:persistent, persistent_impl=:cf)

        # Reversibility — Bennett's correctness invariant (CLAUDE.md §4).
        @test Bennett.verify_reversibility(c)

        # Concrete corner cases.
        # (a) All zeros: insert 3 zero pairs, lookup zero. Oracle returns V(0).
        #     Also exercises the Bennett-n3z4 reroot-key=0 path under the
        #     Bennett transform's reverse pass.
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
        # (d) OVERWRITE: same key set twice — CF's Arr keeps the latest
        #     value at the matching slot (no Diff walk on get).
        let args = (Int8(5), Int8(50), Int8(5), Int8(51), Int8(7), Int8(70), Int8(5))
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test expected == Int8(51)  # sanity-check the oracle
            @test Bennett.simulate(c, args) == expected
        end

        # Small random sweep. cf max_n=4 — insert exactly 3 distinct keys
        # per trial. CF is collision-free so pmap_demo_oracle's exact-key
        # Dict stays a faithful reference for plain random keys.
        for _trial in 1:10
            k1, k2, k3 = rand(Int8), rand(Int8), rand(Int8)
            (k1 == k2 || k1 == k3 || k2 == k3) && continue
            v1, v2, v3 = rand(Int8), rand(Int8), rand(Int8)
            lookup = rand([k1, k2, k3, rand(Int8)])
            args = (k1, v1, k2, v2, k3, v3, lookup)
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test Bennett.simulate(c, args) == expected
        end

        # Gate-count info for the worklog (NOT pinned). Gate counts will
        # differ from linear_scan / okasaki / hamt because the CF impl
        # maintains a Diff undo-chain in addition to the materialised Arr.
        gc = Bennett.gate_count(c)
        @info "Bennett-qi6c :cf 3-key demo gate count" gates=gc
    end
end
