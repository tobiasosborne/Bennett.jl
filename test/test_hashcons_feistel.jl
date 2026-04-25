# T5-P4b — Feistel-perfect-hash standalone reversibility + image-size sanity
#
# Winner-side coverage extracted out of test_persistent_hashcons.jl during
# Bennett-uoem / U54 cycle 5 (2026-04-25).  The hashcons file as a whole
# rides under BENNETT_RESEARCH_TESTS=1 because 6/6 layered demos pair a
# hash with a research-tier persistent-DS impl, and the Jenkins standalone
# test exercises a research-tier hash.  This file restores Feistel-only
# coverage to the default test path.
#
# Note: a finer-grained collision-baseline regression for `soft_feistel_int8`
# lives in test_sqtd_feistel_not_bijection.jl (Bennett-sqtd / U22) — pinned
# at exact image size 207/256.  This file's image-size sanity is a coarse
# check that the bijection-on-Int8 image at least clears 200/256.

using Test
using Bennett

@testset "T5-P4b — soft_feistel32 standalone reversibility + bijection sanity" begin
    c = reversible_compile(soft_feistel32, UInt32)
    @test c isa ReversibleCircuit
    @test verify_reversibility(c; n_tests=3)
    gc = gate_count(c)
    @info "T5-P4b soft_feistel32 standalone gate count" total=gc.total Toffoli=gc.Toffoli
    @test gc.total > 100

    # Bijection sanity: every Int8 key maps to a distinct image.
    # (Feistel is a bijection on UInt32 → UInt32; the low byte after
    # zero-extending Int8 input may collide, but at least within the
    # 256-key Int8 image we expect very few collisions in practice.)
    images = Set{Int8}()
    for k in -128:127
        push!(images, soft_feistel_int8(Int8(k)))
    end
    # Not strictly bijective on Int8 (low-byte truncation can collide),
    # but should hit far more than 1 image.  ~250 distinct out of 256
    # is what to expect from a good hash; test_sqtd_*.jl pins the exact
    # image size at 207/256.
    @test length(images) > 200
end
