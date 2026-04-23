using Test
using Bennett: cf_pmap_new, cf_pmap_set, cf_pmap_get, cf_reroot

# Bennett-n3z4 / U21 — `cf_reroot` used `r_key == UInt64(0)` as an
# "empty slot was just allocated" sentinel. Int8(0) is a valid key in
# the PersistentMap protocol, so any sequence that stored key=0 into a
# fresh slot and then overwrote its value produced the wrong reroot
# semantics: count was decremented (as if the allocation itself were
# being undone) even though only the value-overwrite diff should pop.
#
# Fix: encode the "was a new allocation" flag in the diff entry
# explicitly (bit 63 of the stored diff_idx), rather than reading it
# out of the key value.

@testset "Bennett-n3z4 cf_reroot handles key=0 correctly" begin

    # T1 — the exact reviewer reproduction: set(0, 99), set(0, 42), reroot.
    # The second set is an OVERWRITE. Reroot should undo it and leave
    # (0, 99) in the map.
    s = cf_pmap_new()
    s = cf_pmap_set(s, Int8(0), Int8(99))
    @test cf_pmap_get(s, Int8(0)) == Int8(99)
    s = cf_pmap_set(s, Int8(0), Int8(42))
    @test cf_pmap_get(s, Int8(0)) == Int8(42)
    s_after = cf_reroot(s)
    @test cf_pmap_get(s_after, Int8(0)) == Int8(99)

    # T2 — symmetric: reroot the first (allocation) diff too. Now
    # count should actually decrement.
    s2 = cf_reroot(s_after)
    @test cf_pmap_get(s2, Int8(0)) == Int8(0)   # back to empty map

    # T3 — key=0 alongside a non-zero key: overwrite of key=0 must not
    # corrupt key=1's state on reroot.
    s = cf_pmap_new()
    s = cf_pmap_set(s, Int8(0), Int8(10))
    s = cf_pmap_set(s, Int8(1), Int8(20))
    s = cf_pmap_set(s, Int8(0), Int8(30))   # overwrite key=0
    @test cf_pmap_get(s, Int8(0)) == Int8(30)
    @test cf_pmap_get(s, Int8(1)) == Int8(20)
    s = cf_reroot(s)                        # undo the overwrite
    @test cf_pmap_get(s, Int8(0)) == Int8(10)
    @test cf_pmap_get(s, Int8(1)) == Int8(20)

    # T4 — regression: non-zero key overwrites still work (baseline case
    # that the pre-fix code handled correctly).
    s = cf_pmap_new()
    s = cf_pmap_set(s, Int8(5), Int8(99))
    s = cf_pmap_set(s, Int8(5), Int8(42))
    s = cf_reroot(s)
    @test cf_pmap_get(s, Int8(5)) == Int8(99)
end
