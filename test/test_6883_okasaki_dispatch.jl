# Bennett-6883 — wire :okasaki persistent_impl arm in _resolve_persistent_impl.
#
# Mirrors test/test_t5_p6_persistent_dispatch.jl testset 2 (3-key roundtrip
# via :linear_scan) but with persistent_impl=:okasaki and the
# okasaki_pmap_* callees instead of linear_scan_pmap_*. The okasaki impl
# was loaded into the Bennett.Persistent submodule (research/okasaki_rbt.jl)
# and its set/get callees registered in _CALLEES_PERSISTENT (4-tuple
# post-6883: linear_scan_pmap_set/get + okasaki_pmap_set/get); _resolve_persistent_impl
# gained the `:okasaki + :none` arm returning Bennett.OKASAKI_IMPL.
#
# Per CLAUDE.md §4: every test calls verify_reversibility AND checks an
# oracle. Per consensus / the original z2dj template: 3-key insert + 1-get
# Julia source function uses top-level definitions (not closure) so the
# Julia frontend extracts LLVM IR via the IRCall machinery, threading the
# NTuple state explicitly through the registered callees (SROA does not
# bite because the state lives in callee returns, not allocas).

using Test
using Bennett

# Top-level demo function — 3-key insert + 1-get via the okasaki impl.
# Same shape as test_t5_p6_persistent_dispatch.jl::_z2dj_ls_demo, but
# routed through Bennett.okasaki_pmap_*.
function _6883_ok_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                       k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = Bennett.okasaki_pmap_new()
    s = Bennett.okasaki_pmap_set(s, k1, v1)
    s = Bennett.okasaki_pmap_set(s, k2, v2)
    s = Bennett.okasaki_pmap_set(s, k3, v3)
    return Bennett.okasaki_pmap_get(s, lookup)
end

@testset "Bennett-6883 — :okasaki persistent_impl dispatcher arm" begin

    @testset "okasaki impl loaded and conforms to pure-Julia contract" begin
        # Ensure the impl is reachable from Bennett and satisfies the
        # PersistentMapImpl protocol (interface.jl) at the pure-Julia
        # level. Catches loading / export bugs before compilation.
        @test isdefined(Bennett, :OKASAKI_IMPL)
        @test isdefined(Bennett, :okasaki_pmap_new)
        @test isdefined(Bennett, :okasaki_pmap_set)
        @test isdefined(Bennett, :okasaki_pmap_get)
        @test Bennett.verify_pmap_correctness(Bennett.OKASAKI_IMPL)
    end

    @testset "demo oracle matches direct stub usage" begin
        for _trial in 1:30
            k1, k2, k3 = rand(Int8), rand(Int8), rand(Int8)
            v1, v2, v3 = rand(Int8), rand(Int8), rand(Int8)
            lookup = rand([k1, k2, k3, rand(Int8)])
            expected = Bennett.pmap_demo_oracle(Int8, Int8,
                                                 k1, v1, k2, v2, k3, v3, lookup)
            got      = _6883_ok_demo(k1, v1, k2, v2, k3, v3, lookup)
            @test got == expected
        end
    end

    @testset "3-key roundtrip via :okasaki (compiles, reversible, matches oracle)" begin
        c = reversible_compile(_6883_ok_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8;
                               mem=:persistent, persistent_impl=:okasaki)

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

        # Small random sweep. okasaki max_n=4 — insert exactly 3 distinct
        # keys per trial. Random `rand(Int8)` draws may collide; that's
        # a valid edge case under the oracle (latest-write semantics).
        for _trial in 1:10
            k1, k2, k3 = rand(Int8), rand(Int8), rand(Int8)
            v1, v2, v3 = rand(Int8), rand(Int8), rand(Int8)
            lookup = rand([k1, k2, k3, rand(Int8)])
            args = (k1, v1, k2, v2, k3, v3, lookup)
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test Bennett.simulate(c, args) == expected
        end

        # Gate-count info for the worklog (NOT pinned). Gate counts will
        # differ from linear_scan because the Okasaki impl has a deeper
        # branchless tree of ifelse selectors.
        gc = Bennett.gate_count(c)
        @info "Bennett-6883 :okasaki 3-key demo gate count" gates=gc
    end
end
