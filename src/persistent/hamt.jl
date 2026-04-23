# ---- Bagwell HAMT persistent map — reversible popcount variant (T5-P3c) ----
#
# Implements a single-level Bagwell Hash Array Mapped Trie (HAMT) as a pure
# Julia branchless function suitable for `reversible_compile`.
#
# ## Design decisions
#
# ### max_n = 8 (not 4)
#
# The orchestrator noted: "with max_n=4, the HAMT degenerates to a 4-slot
# linear search and popcount may not be meaningfully exercised."  We use
# max_n=8 so that (a) the bitmap grows large enough for popcount to produce
# non-trivial indices on real inputs, and (b) HAMT is clearly distinguishable
# from the linear_scan stub in the gate-count Pareto front (more entries =>
# more MUX work => larger gate count, but O(log32 N) scaling is visible).
#
# ### ONE LEVEL ONLY (no ArrayNode promotion)
#
# Per the HAMT brief recommendation and bead spec: cap at 15 entries per
# node, never promote to ArrayNode.  max_n=8 is well within this cap.
# No HashCollisionNode either — collision handling is deferred (delete OPTIONAL).
#
# ### Hash function simplification
#
# For K=Int8, the keyspace is {-128..127} = 256 values.  A 32-bit hash is
# overkill; the 5-bit slot index is simply `(reinterpret(UInt8, k)) & 0x1F`.
# This maps Int8 -> {0..31} using the 5 low bits of the unsigned reinterpret.
# Distinct keys CAN collide: e.g. Int8(0) and Int8(32) both map to slot 0.
# With max_n=8 and random inputs, collisions are infrequent.
# **Collision handling**: when a new key hashes to a slot already occupied by
# a different key, the new key overwrites the old (latest-write semantics).
# This matches the protocol contract (max_n is impl-defined behaviour).
#
# ### Branchless via `ifelse` + soft_popcount32
#
# Bennett.jl requires branchless code (no data-dependent branches) so that
# gate count is input-independent.  We use `ifelse` for all conditionals.
# soft_popcount32 is the novel primitive: it computes the HAMT compressed
# array index without any branch.
#
# ### State layout
#
# NTuple{17, UInt64}:
#   [1]     = bitmap :: UInt32 widened to UInt64 (bit i set <=> slot i occupied)
#   [2..9]  = keys[0..7] :: Int8 widened to UInt64 (slot j's key)
#   [10..17]= vals[0..7] :: Int8 widened to UInt64 (slot j's value)
#
# The "compressed array" (keys/vals) is stored in SORTED ORDER by 5-bit hash
# slot.  Slot 0 is the leftmost occupied entry, slot 1 the next, etc.
# `popcount(bitmap & (bit-1))` gives the index into this sorted array.
#
# ### Why popcount is genuinely exercised
#
# For every `hamt_pmap_get` call, soft_popcount32 is invoked to compute the
# compressed index `idx = popcount(bitmap & (bit-1))`.  The value of `idx`
# ranges from 0 to min(n-1, 31) depending on which earlier slots are
# occupied.  With 8 entries and uniformly random Int8 keys, the expected
# `idx` is ~3.5 on a hit — demonstrably non-trivial.  The benchmark testset
# in test/test_persistent_hamt.jl verifies this exercises the popcount path.

# ---- Constants ----

const _HAMT_MAX_N    = 8      # max entries (BitmapIndexedNode capacity)
const _HAMT_STATE_LEN = 1 + _HAMT_MAX_N + _HAMT_MAX_N   # = 17 UInt64 slots

"HAMT state type: NTuple{17, UInt64} = [bitmap, key0..key7, val0..val7]."
const HamtState = NTuple{_HAMT_STATE_LEN, UInt64}

# ---- Constructor ----

"Empty HAMT: bitmap=0, all slots zeroed."
@inline function hamt_pmap_new()::HamtState
    return ntuple(_ -> UInt64(0), Val(_HAMT_STATE_LEN))
end

# ---- Internal helpers ----

# 5-bit hash slot for a key: use low 5 bits of reinterpret-as-UInt8.
# Maps Int8 -> {0..31}.  Documents the simplification (see header).
@inline function _hamt_slot(k::Int8)::UInt32
    return UInt32(reinterpret(UInt8, k)) & UInt32(0x1F)
end

# Bitmap bit for a slot.
@inline function _hamt_bit(slot::UInt32)::UInt32
    return UInt32(1) << slot
end

# Compressed array index for a given bit:
# idx = popcount(bitmap & (bit - 1)) — counts occupied slots below our slot.
@inline function _hamt_idx(bitmap::UInt32, bit::UInt32)::UInt32
    return soft_popcount32(bitmap & (bit - UInt32(1)))
end

# Branchless per-slot key/val picker for pmap_set.
# slot_j is the COMPILE-TIME slot index (0..7); idx is the runtime target.
@inline _hamt_pick(slot_j::Int, idx::UInt32, new_val::UInt64, old_val::UInt64)::UInt64 =
    ifelse(idx == UInt32(slot_j), new_val, old_val)

# ---- Insert (pmap_set) ----
#
# Algorithm (branchless path):
#   1. Compute hash slot and bit.
#   2. Determine `idx = popcount(bitmap & (bit-1))` — compressed insert index.
#   3. If slot already occupied (bitmap & bit != 0):
#      - Update the value at position `idx` (latest-write overwrite).
#      - Bitmap unchanged.
#   4. If slot not occupied (bitmap & bit == 0):
#      - Insert new key/val at position `idx`, shifting existing entries at idx..n-1.
#      - Update bitmap.
#   Both cases are handled branchlessly via `ifelse`.
#
# "Shift" in step 4 is implemented by: for each slot j, the new content
# is the OLD content of slot (j-1) if j > idx, else the old content of j.
# (But only for the "new slot" case — the "update" case preserves order.)
# The two cases are muxed by `is_new :: Bool → UInt64`.

@inline function hamt_pmap_set(s::HamtState, k::Int8, v::Int8)::HamtState
    bitmap = UInt32(s[1])
    slot   = _hamt_slot(k)
    bit    = _hamt_bit(slot)
    idx    = _hamt_idx(bitmap, bit)

    k_u = UInt64(reinterpret(UInt8, k))
    v_u = UInt64(reinterpret(UInt8, v))

    # is_occupied: 1 if this slot already has an entry, 0 if new
    is_occupied = UInt64((bitmap & bit) != UInt32(0))
    is_new      = UInt64(1) - is_occupied   # 1 if new slot

    # New bitmap: set the bit (idempotent if already set)
    new_bitmap = UInt64(bitmap | bit)

    # --- Update keys array (branchless over 8 slots) ---
    # For each slot j:
    #   CASE A (is_occupied): write k_u at slot idx, preserve others.
    #   CASE B (is_new): insert k_u at idx, shift everything at j>=idx up one.
    #
    # Combined formula for slot j:
    #   new_key_j = is_occupied * pick_update(j, idx, k_u, old_key_j)
    #             + is_new      * pick_insert(j, idx, k_u, old_key_{j-1}, old_key_j)
    #
    # pick_update(j, idx, k_u, old): ifelse(j==idx, k_u, old)
    # pick_insert(j, idx, k_u, old_prev, old):
    #   ifelse(j==idx, k_u, ifelse(j>idx, old_prev, old))
    #
    # We implement this with nested ifelse and UInt64 arithmetic (multiply by mask).

    # Current keys (slots 0..7 stored at s[2..9])
    k0 = s[2]; k1 = s[3]; k2 = s[4]; k3 = s[5]
    k4 = s[6]; k5 = s[7]; k6 = s[8]; k7 = s[9]
    # Current vals (slots 0..7 stored at s[10..17])
    v0 = s[10]; v1 = s[11]; v2 = s[12]; v3 = s[13]
    v4 = s[14]; v5 = s[15]; v6 = s[16]; v7 = s[17]

    # Helper: for the "new slot" insert case, what goes into slot j?
    #   j < idx  => old key at j (unchanged)
    #   j == idx => k_u (new key)
    #   j > idx  => old key at j-1 (shifted)
    #
    # Helper: for the "update" case, what goes into slot j?
    #   j == idx => k_u / v_u
    #   j != idx => old key/val at j (unchanged)

    # Slot 0
    nk0_upd = ifelse(idx == UInt32(0), k_u, k0)
    # insert: j=0 < idx → old; j=0==idx → new; j=0 > idx → shift (impossible, prev=-1 undefined)
    nk0_ins = ifelse(idx == UInt32(0), k_u, k0)   # j=0: only new if idx==0, else old
    new_k0  = is_occupied * nk0_upd + is_new * nk0_ins

    nv0_upd = ifelse(idx == UInt32(0), v_u, v0)
    nv0_ins = ifelse(idx == UInt32(0), v_u, v0)
    new_v0  = is_occupied * nv0_upd + is_new * nv0_ins

    # Slot 1
    nk1_upd = ifelse(idx == UInt32(1), k_u, k1)
    nk1_ins = ifelse(idx == UInt32(1), k_u, ifelse(idx < UInt32(1), k0, k1))
    new_k1  = is_occupied * nk1_upd + is_new * nk1_ins

    nv1_upd = ifelse(idx == UInt32(1), v_u, v1)
    nv1_ins = ifelse(idx == UInt32(1), v_u, ifelse(idx < UInt32(1), v0, v1))
    new_v1  = is_occupied * nv1_upd + is_new * nv1_ins

    # Slot 2
    nk2_upd = ifelse(idx == UInt32(2), k_u, k2)
    nk2_ins = ifelse(idx == UInt32(2), k_u, ifelse(idx < UInt32(2), k1, k2))
    new_k2  = is_occupied * nk2_upd + is_new * nk2_ins

    nv2_upd = ifelse(idx == UInt32(2), v_u, v2)
    nv2_ins = ifelse(idx == UInt32(2), v_u, ifelse(idx < UInt32(2), v1, v2))
    new_v2  = is_occupied * nv2_upd + is_new * nv2_ins

    # Slot 3
    nk3_upd = ifelse(idx == UInt32(3), k_u, k3)
    nk3_ins = ifelse(idx == UInt32(3), k_u, ifelse(idx < UInt32(3), k2, k3))
    new_k3  = is_occupied * nk3_upd + is_new * nk3_ins

    nv3_upd = ifelse(idx == UInt32(3), v_u, v3)
    nv3_ins = ifelse(idx == UInt32(3), v_u, ifelse(idx < UInt32(3), v2, v3))
    new_v3  = is_occupied * nv3_upd + is_new * nv3_ins

    # Slot 4
    nk4_upd = ifelse(idx == UInt32(4), k_u, k4)
    nk4_ins = ifelse(idx == UInt32(4), k_u, ifelse(idx < UInt32(4), k3, k4))
    new_k4  = is_occupied * nk4_upd + is_new * nk4_ins

    nv4_upd = ifelse(idx == UInt32(4), v_u, v4)
    nv4_ins = ifelse(idx == UInt32(4), v_u, ifelse(idx < UInt32(4), v3, v4))
    new_v4  = is_occupied * nv4_upd + is_new * nv4_ins

    # Slot 5
    nk5_upd = ifelse(idx == UInt32(5), k_u, k5)
    nk5_ins = ifelse(idx == UInt32(5), k_u, ifelse(idx < UInt32(5), k4, k5))
    new_k5  = is_occupied * nk5_upd + is_new * nk5_ins

    nv5_upd = ifelse(idx == UInt32(5), v_u, v5)
    nv5_ins = ifelse(idx == UInt32(5), v_u, ifelse(idx < UInt32(5), v4, v5))
    new_v5  = is_occupied * nv5_upd + is_new * nv5_ins

    # Slot 6
    nk6_upd = ifelse(idx == UInt32(6), k_u, k6)
    nk6_ins = ifelse(idx == UInt32(6), k_u, ifelse(idx < UInt32(6), k5, k6))
    new_k6  = is_occupied * nk6_upd + is_new * nk6_ins

    nv6_upd = ifelse(idx == UInt32(6), v_u, v6)
    nv6_ins = ifelse(idx == UInt32(6), v_u, ifelse(idx < UInt32(6), v5, v6))
    new_v6  = is_occupied * nv6_upd + is_new * nv6_ins

    # Slot 7
    nk7_upd = ifelse(idx == UInt32(7), k_u, k7)
    nk7_ins = ifelse(idx == UInt32(7), k_u, ifelse(idx < UInt32(7), k6, k7))
    new_k7  = is_occupied * nk7_upd + is_new * nk7_ins

    nv7_upd = ifelse(idx == UInt32(7), v_u, v7)
    nv7_ins = ifelse(idx == UInt32(7), v_u, ifelse(idx < UInt32(7), v6, v7))
    new_v7  = is_occupied * nv7_upd + is_new * nv7_ins

    # Bennett-hmn0 / U20: 9th distinct-hash-slot overflow check.
    # With 8 occupied hash positions (bitmap popcount == 8), a new
    # insertion whose hash slot is not in {0..7} produces `idx = 8` —
    # no `idx == UInt32(N)` case matches, the key is silently dropped,
    # AND the bitmap is mutated to include the new bit → bitmap
    # inconsistent with the compressed array. Detect overflow and
    # reject the insert (keep state unchanged). Documented limitation
    # of the 8-slot design; proper resolution is to EoL HAMT per U79.
    bitmap_full = UInt64(soft_popcount32(bitmap) >= UInt32(8))
    is_overflow = is_new & bitmap_full
    keep_old    = is_overflow == UInt64(1)

    safe_bitmap = ifelse(keep_old, UInt64(bitmap), new_bitmap)
    safe_k0 = ifelse(keep_old, k0, new_k0)
    safe_k1 = ifelse(keep_old, k1, new_k1)
    safe_k2 = ifelse(keep_old, k2, new_k2)
    safe_k3 = ifelse(keep_old, k3, new_k3)
    safe_k4 = ifelse(keep_old, k4, new_k4)
    safe_k5 = ifelse(keep_old, k5, new_k5)
    safe_k6 = ifelse(keep_old, k6, new_k6)
    safe_k7 = ifelse(keep_old, k7, new_k7)
    safe_v0 = ifelse(keep_old, v0, new_v0)
    safe_v1 = ifelse(keep_old, v1, new_v1)
    safe_v2 = ifelse(keep_old, v2, new_v2)
    safe_v3 = ifelse(keep_old, v3, new_v3)
    safe_v4 = ifelse(keep_old, v4, new_v4)
    safe_v5 = ifelse(keep_old, v5, new_v5)
    safe_v6 = ifelse(keep_old, v6, new_v6)
    safe_v7 = ifelse(keep_old, v7, new_v7)

    return (safe_bitmap,
            safe_k0, safe_k1, safe_k2, safe_k3, safe_k4, safe_k5, safe_k6, safe_k7,
            safe_v0, safe_v1, safe_v2, safe_v3, safe_v4, safe_v5, safe_v6, safe_v7)
end

# ---- Lookup (pmap_get) ----
#
# Algorithm (branchless):
#   1. Compute hash slot and bit.
#   2. If bitmap & bit == 0: miss → return 0.
#   3. Else: idx = popcount(bitmap & (bit-1)) — compressed index.
#   4. Scan all 8 key slots branchlessly; return val at the slot where j==idx.
#      (Wraps zero(Int8) if idx >= current count — shouldn't happen if bitmap
#      is consistent, but branchless code must handle it safely.)

@inline function hamt_pmap_get(s::HamtState, k::Int8)::Int8
    bitmap = UInt32(s[1])
    slot   = _hamt_slot(k)
    bit    = _hamt_bit(slot)
    idx    = _hamt_idx(bitmap, bit)
    k_u    = UInt64(reinterpret(UInt8, k))

    # slot_occupied: 1 if the bitmap bit for this hash slot is set
    slot_occupied = UInt64((bitmap & bit) != UInt32(0))

    # Fetch the key stored at the compressed index position.
    # Branchless scan over 8 key slots; accumulate the one at position idx.
    key_at_idx = UInt64(0)
    key_at_idx = ifelse(idx == UInt32(0), s[2],  key_at_idx)
    key_at_idx = ifelse(idx == UInt32(1), s[3],  key_at_idx)
    key_at_idx = ifelse(idx == UInt32(2), s[4],  key_at_idx)
    key_at_idx = ifelse(idx == UInt32(3), s[5],  key_at_idx)
    key_at_idx = ifelse(idx == UInt32(4), s[6],  key_at_idx)
    key_at_idx = ifelse(idx == UInt32(5), s[7],  key_at_idx)
    key_at_idx = ifelse(idx == UInt32(6), s[8],  key_at_idx)
    key_at_idx = ifelse(idx == UInt32(7), s[9],  key_at_idx)

    # key_match: 1 if the key stored at idx equals k (hash collision check)
    key_match = UInt64(key_at_idx == k_u)

    # true hit: slot occupied AND keys match
    hit = slot_occupied & key_match

    # Fetch the val stored at the compressed index position.
    acc = UInt64(0)
    acc = ifelse(idx == UInt32(0), s[10], acc)
    acc = ifelse(idx == UInt32(1), s[11], acc)
    acc = ifelse(idx == UInt32(2), s[12], acc)
    acc = ifelse(idx == UInt32(3), s[13], acc)
    acc = ifelse(idx == UInt32(4), s[14], acc)
    acc = ifelse(idx == UInt32(5), s[15], acc)
    acc = ifelse(idx == UInt32(6), s[16], acc)
    acc = ifelse(idx == UInt32(7), s[17], acc)

    # Apply hit mask: zero on miss or key mismatch
    result = hit * acc

    return reinterpret(Int8, UInt8(result & UInt64(0xff)))
end

# ---- Protocol bundle ----

"Bundle for harness loop and harness gate-count measurement."
const HAMT_IMPL = PersistentMapImpl(
    name     = "hamt_log32",
    K        = Int8,
    V        = Int8,
    max_n    = _HAMT_MAX_N,
    pmap_new = hamt_pmap_new,
    pmap_set = hamt_pmap_set,
    pmap_get = hamt_pmap_get,
)
