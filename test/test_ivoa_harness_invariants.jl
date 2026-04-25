using Test
using Bennett

@testset "Bennett-ivoa / U121 — harness persistence + key=0 invariants" begin

    impl = LINEAR_SCAN_IMPL  # the production-path winner per U54

    @testset "verify_pmap_correctness now exercises key=0 as a stored key" begin
        # The new contract: the harness must store K(0) at least once and
        # round-trip its value (catches impls that special-case key=0 as
        # 'unused' — a known anti-pattern in HAMT/ArrayNode designs).
        @test verify_pmap_correctness(impl)
    end

    @testset "verify_pmap_persistence_invariant — old snapshot survives set" begin
        # The persistent contract: pmap_set returns a new state; the OLD
        # state must remain valid and unchanged.  Bug class: an impl that
        # mutates the underlying storage (e.g. via an in-place ifelse on
        # a Ref) would silently fail this.
        @test verify_pmap_persistence_invariant(impl)
    end

    @testset "linear_scan: explicit persistence regression" begin
        # Insert (1, 11), snapshot, then overwrite (1, 99).
        s0 = Bennett.linear_scan_pmap_new()
        s1 = Bennett.linear_scan_pmap_set(s0, Int8(1), Int8(11))
        s2 = Bennett.linear_scan_pmap_set(s1, Int8(1), Int8(99))

        # Old snapshot must still report the original value.
        @test Bennett.linear_scan_pmap_get(s1, Int8(1)) == Int8(11)
        # New snapshot reports the overwrite.
        @test Bennett.linear_scan_pmap_get(s2, Int8(1)) == Int8(99)
        # Empty snapshot reports zero (absent-key contract — see e89s).
        @test Bennett.linear_scan_pmap_get(s0, Int8(1)) == Int8(0)
    end

    @testset "linear_scan: key=0 stores and retrieves" begin
        # Insert (0, 42); look up key=0.  Must NOT collide with the
        # unused-slot zero-key sentinel (linear_scan uses count, not
        # key=0, to mark unused slots — verify the design holds).
        s = Bennett.linear_scan_pmap_new()
        s = Bennett.linear_scan_pmap_set(s, Int8(0), Int8(42))
        @test Bennett.linear_scan_pmap_get(s, Int8(0)) == Int8(42)

        # And key=0 stored after another key still wins on lookup.
        s = Bennett.linear_scan_pmap_new()
        s = Bennett.linear_scan_pmap_set(s, Int8(7), Int8(70))
        s = Bennett.linear_scan_pmap_set(s, Int8(0), Int8(42))
        @test Bennett.linear_scan_pmap_get(s, Int8(0)) == Int8(42)
        @test Bennett.linear_scan_pmap_get(s, Int8(7)) == Int8(70)
    end
end

@testset "Bennett-e89s / U120 — absent-key vs stored-zero collision is by design" begin
    # The branchless persistent-map protocol (interface.jl §22) commits to
    # `pmap_get(pmap_new(), k) == zero(V)`.  This means absent-key and
    # stored-zero are INDISTINGUISHABLE by the protocol's value-only
    # return type.  Replacing it with a (found, value) tuple would break
    # branchlessness and inflate every consumer's gate count for a
    # caller-layer concern.  Pin both halves of the collision so any
    # future contract change surfaces here.

    s_empty = Bennett.linear_scan_pmap_new()
    @test Bennett.linear_scan_pmap_get(s_empty, Int8(5)) == Int8(0)   # absent

    s_zero = Bennett.linear_scan_pmap_set(s_empty, Int8(5), Int8(0))
    @test Bennett.linear_scan_pmap_get(s_zero, Int8(5)) == Int8(0)    # stored zero

    # Callers that need to distinguish must reserve either a key or a
    # value sentinel; that is documented in the protocol contract.
end
