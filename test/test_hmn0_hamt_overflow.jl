using Test
using Bennett
using Bennett: hamt_pmap_new, hamt_pmap_set, hamt_pmap_get

# Bennett-hmn0 / U20 — `hamt_pmap_set` silently lost the 9th
# distinct-hash key. With 8 hash slots filled (bitmap popcount == 8),
# any insertion whose `_hamt_slot(k)` fell outside the 8 occupied
# positions computed `idx = popcount(bitmap & (bit-1)) == 8` — no
# `idx == UInt32(N)` case for N in 0..7 matched. The key was silently
# dropped WHILE the bitmap was mutated to include the new bit, leaving
# the bitmap inconsistent with the compressed key/value array.
#
# Fix: detect overflow (is_new & popcount(bitmap) >= 8) and fall back
# to the unchanged state. Bitmap stays consistent; 9th insertion is a
# no-op (documented limitation of the 8-slot design).

@testset "Bennett-hmn0 HAMT 9th-key overflow consistency" begin

    # Construct 8 distinct-hash keys. _hamt_slot uses low 5 bits of
    # reinterpret-as-UInt8. Pick k=0, 1, 2, ..., 7 — all distinct hash
    # slots.
    s = hamt_pmap_new()
    for i in 0:7
        s = hamt_pmap_set(s, Int8(i), Int8(100 + i))
    end
    # All 8 keys should be retrievable.
    for i in 0:7
        @test hamt_pmap_get(s, Int8(i)) == Int8(100 + i)
    end

    # Try to insert a 9th distinct-hash key (k=8, hash slot 8 — not in
    # {0..7}). Pre-fix: state becomes corrupt (new key lost, bitmap
    # updated). Post-fix: overflow is rejected, state unchanged.
    before_bitmap = s[1]
    s9 = hamt_pmap_set(s, Int8(8), Int8(99))

    # The original 8 keys must still read correctly after the rejected
    # 9th insertion.
    for i in 0:7
        @test hamt_pmap_get(s9, Int8(i)) == Int8(100 + i)
    end

    # The 9th key read must NOT return the inserted value (it was
    # rejected).  Either it returns 0 (default miss) or the collision-
    # overwritten old value — the important invariant is that the
    # state is self-consistent.
    #
    # Key invariant: bitmap popcount stays at 8 after a rejected 9th
    # insert — the bit for the new hash slot must NOT be set.
    @test s9[1] == before_bitmap
end
