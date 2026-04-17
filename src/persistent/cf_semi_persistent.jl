# ---- Conchon-Filliâtre semi-persistent array as reversible persistent map ----
# (T5-P3d) — Track C of Bennett-Memory-T5-PRD.md §10 M5.3
#
# Reference: Conchon & Filliâtre 2007 (ML Workshop), "A Persistent Union-Find
# Data Structure".  See docs/literature/memory/cf_semipersistent_brief.md.
#
# ─── DESIGN ───────────────────────────────────────────────────────────────────
#
# The C-F paper represents a persistent array as:
#
#   type α t = α data ref
#   and α data =
#     | Arr of α array        (* current materialised version *)
#     | Diff of int × α × α t (* (idx, old_val, parent) undo-chain *)
#
# For T5 (K=V=Int8, max_n=4, NTuple-based state), we flatten this into a
# fixed-size NTuple:
#
#   CFState :: NTuple{_CF_STATE_LEN, UInt64}
#
# ─── STATE LAYOUT (max_n = 4) ─────────────────────────────────────────────────
#
#   slot 1:       diff_depth  — current undo-stack depth (0..max_n_diffs)
#   slot 2:       arr_count   — number of live (k,v) pairs in the Arr (0..max_n)
#   slots 3..10:  Arr portion — (key, val) pairs for arr slots 0..3 (8 UInt64s)
#                   slot 3 = arr_k[0], slot 4 = arr_v[0]
#                   slot 5 = arr_k[1], slot 6 = arr_v[1]
#                   slot 7 = arr_k[2], slot 8 = arr_v[2]
#                   slot 9 = arr_k[3], slot 10= arr_v[3]
#   slots 11..22: Diff chain — (arr_slot_idx, old_key, old_val) × 4 (12 UInt64s)
#                   diff entry d (d=0..3):
#                     slot 11+3d = diff_idx[d]  (which Arr slot was overwritten)
#                     slot 12+3d = diff_key[d]  (old key at that slot)
#                     slot 13+3d = diff_val[d]  (old val at that slot)
#
# Total: 2 + 8 + 12 = 22 UInt64s.
#
# ─── SEMANTIC CORRESPONDENCE WITH THE BRIEF ────────────────────────────────────
#
# The Arr portion IS the current materialised array — always up to date.
# The Diff chain IS Baker's undo stack / Bennett's history tape.
#
# `cf_pmap_set`:  (1) records old (k,v) in diff_slot[diff_depth], (2) writes
#                 new (k,v) into Arr at the matching/new slot, (3) increments
#                 diff_depth. O(max_n) branchless scan.
#
# `cf_pmap_get`:  scans Arr for matching key (O(max_n) branchless).
#                 Since Arr is always materialised, get is O(1) amortised —
#                 no Diff traversal needed.
#
# `cf_reroot`:    NOT exposed as a public function — it would only be needed
#                 if we accessed older versions from the Diff chain.  In
#                 Bennett's construction the circuit moves monotonically forward
#                 (build Diff chain) then backward (Bennett uncompute undoes
#                 every set).  See §5 "Correspondence Evaluation" in the code
#                 comment below.
#
# ─── KEY→SLOT MAPPING ─────────────────────────────────────────────────────────
#
# The Arr is a (key, val) store in insertion order, NOT indexed by key value.
# Lookup scans linearly.  This degrades C-F's theoretical strength (O(1)
# amortised) to O(max_n) — but for max_n=4 this is identical in practice and
# matches the linear_scan_stub baseline exactly.  A real impl would use a
# Feistel-hashed slot index for O(1) branchless key→slot.  Documented as a
# known simplification; it does NOT affect correctness.
#
# ─── OVERWRITE SEMANTICS ──────────────────────────────────────────────────────
#
# If the same key is set twice:
#   - First set: a new Arr slot is allocated; the old (sentinel 0, 0) is pushed
#     to Diff.
#   - Second set: the existing Arr slot is found; (old_key=k, old_val=v1) is
#     pushed to Diff; the new value v2 is written into that slot.
# On get after two sets: the Arr always has the latest value — no Diff walk.
#
# ─── CORRESPONDENCE EVALUATION (§5 brief claim) ───────────────────────────────
#
# The brief (§5) claims: "the Diff chain IS Bennett's history tape, and
# `reroot` IS the uncompute pass."
#
# VERDICT: HOLDS at the algorithmic level, with a caveat.
#
# In our implementation the Arr is ALWAYS materialised (the current version).
# Every `set` pushes the OLD (slot, key, val) triple onto the Diff chain.
# Bennett's uncompute pass runs the circuit in reverse — which means it runs
# `cf_pmap_set` in reverse, which pops the Diff chain and restores the Arr.
# This is EXACTLY what C-F's `reroot` does: walk the Diff chain backward,
# restoring each Arr cell to its old value.
#
# Therefore: IF you have Bennett's transform (forward + copy + reverse), you do
# NOT need an explicit `reroot` function.  The reverse pass already implements
# it.  Strategy (b) from the orchestrator's prompt — "rely on Bennett's
# transform for the reverse" — IS CORRECT and IS what we rely on here.
#
# CAVEAT: This equivalence holds ONLY under linear (no-branching) access —
# exactly what Bennett's single-path circuit enforces.  Under full persistence
# (branching version graph), the equivalence breaks: the Diff chain is no
# longer a linear tape and `reroot` would need to handle DAG traversal.
# The semi-persistent variant's `Invalid` node (brief §3a) enforces linearity
# statically.  In our NTuple formulation, linearity is enforced structurally:
# NTuples are values (not references), so there is no aliasing.
#
# IMPLEMENTATION CHOICE: strategy (a) — implement an explicit `cf_reroot`
# for completeness and documentation, but it is NOT called by `cf_pmap_get`.
# The Bennett transform handles the reverse pass.  `cf_reroot` is included
# so the correspondence can be inspected and tested in isolation.

# ─── CONSTANTS ────────────────────────────────────────────────────────────────

const _CF_MAX_N      = 4    # maximum distinct keys
const _CF_MAX_DIFFS  = 4    # maximum depth of Diff undo-stack (= max_n sets)
const _CF_ARR_LEN    = 2 * _CF_MAX_N     # 8 UInt64s: alternating (key, val) pairs
const _CF_DIFF_LEN   = 3 * _CF_MAX_DIFFS # 12 UInt64s: (slot_idx, old_key, old_val) × 4
# Layout: [diff_depth, arr_count, arr_k0, arr_v0, arr_k1, arr_v1, arr_k2, arr_v2,
#           arr_k3, arr_v3, diff0_idx, diff0_key, diff0_val, diff1_idx, ..., diff3_val]
const _CF_STATE_LEN  = 2 + _CF_ARR_LEN + _CF_DIFF_LEN   # = 22

# Slot offsets (1-based Julia indexing)
const _CF_OFF_DEPTH  = 1    # diff_depth
const _CF_OFF_COUNT  = 2    # arr_count
const _CF_OFF_ARR    = 3    # first arr slot (key of arr pair 0)
const _CF_OFF_DIFF   = 11   # first diff entry (slot_idx of diff 0)

const CFState = NTuple{_CF_STATE_LEN, UInt64}

# ─── HELPERS ──────────────────────────────────────────────────────────────────

"Return the 1-based index of arr key slot i (i = 0-based)."
@inline _cf_arr_key_idx(i::Int) = _CF_OFF_ARR + 2*i
"Return the 1-based index of arr val slot i (i = 0-based)."
@inline _cf_arr_val_idx(i::Int) = _CF_OFF_ARR + 2*i + 1
"Return the 1-based index of diff slot_idx field for diff entry d (0-based)."
@inline _cf_diff_idx_idx(d::Int) = _CF_OFF_DIFF + 3*d
"Return the 1-based index of diff old_key field for diff entry d (0-based)."
@inline _cf_diff_key_idx(d::Int) = _CF_OFF_DIFF + 3*d + 1
"Return the 1-based index of diff old_val field for diff entry d (0-based)."
@inline _cf_diff_val_idx(d::Int) = _CF_OFF_DIFF + 3*d + 2

# ─── API ──────────────────────────────────────────────────────────────────────

"Empty CF state: diff_depth=0, arr_count=0, all slots zero."
@inline function cf_pmap_new()::CFState
    ntuple(_ -> UInt64(0), Val(_CF_STATE_LEN))
end

"""
    cf_pmap_set(s::CFState, k::Int8, v::Int8) -> CFState

Insert or overwrite key `k` with value `v`.

Algorithm (branchless, O(max_n)):
  1. Scan Arr for an existing slot matching `k`.  If found, use that slot.
     If not found, allocate slot at arr_count (clamped to max_n-1).
  2. Record (slot_idx, old_key, old_val) in diff[diff_depth].
  3. Write (k, v) into Arr slot.
  4. Update arr_count (if new slot) and diff_depth.

All branches expressed via `ifelse`.
"""
@inline function cf_pmap_set(s::CFState, k::Int8, v::Int8)::CFState
    k_u = UInt64(reinterpret(UInt8, k))
    v_u = UInt64(reinterpret(UInt8, v))

    # ── Step 1: find the target Arr slot ────────────────────────────────────
    # Scan all 4 arr slots for a matching key.  Track the "first match" index
    # and whether we found any match.  If no match, use arr_count as new slot.
    count   = s[_CF_OFF_COUNT]

    # For each slot i: in_use(i) = (count > i), match(i) = (in_use & key==k)
    ku0 = s[_cf_arr_key_idx(0)]
    ku1 = s[_cf_arr_key_idx(1)]
    ku2 = s[_cf_arr_key_idx(2)]
    ku3 = s[_cf_arr_key_idx(3)]

    in_use0 = count > UInt64(0)
    in_use1 = count > UInt64(1)
    in_use2 = count > UInt64(2)
    in_use3 = count > UInt64(3)

    match0 = in_use0 & (ku0 == k_u)
    match1 = in_use1 & (ku1 == k_u)
    match2 = in_use2 & (ku2 == k_u)
    match3 = in_use3 & (ku3 == k_u)

    any_match = match0 | match1 | match2 | match3

    # "first match" index: priority-encode.  If match0, use 0; elif match1, 1; etc.
    # We want the LOWEST index that matched.
    first_match_idx =
        ifelse(match0,
            UInt64(0),
            ifelse(match1,
                UInt64(1),
                ifelse(match2,
                    UInt64(2),
                    UInt64(3))))

    # New slot if no match: use arr_count, clamped to max_n-1
    new_slot_idx = ifelse(count >= UInt64(_CF_MAX_N),
                          UInt64(_CF_MAX_N - 1),
                          count)

    # Target slot: match wins over new
    target_slot = ifelse(any_match, first_match_idx, new_slot_idx)

    # ── Step 2: record old (k, v) into diff[diff_depth] ─────────────────────
    depth = s[_CF_OFF_DEPTH]
    # Clamp depth so we never overflow diff storage
    safe_depth = ifelse(depth >= UInt64(_CF_MAX_DIFFS),
                        UInt64(_CF_MAX_DIFFS - 1),
                        depth)

    # Old key/val at target_slot (branchless read via ifelse):
    old_k = ifelse(target_slot == UInt64(0), ku0,
             ifelse(target_slot == UInt64(1), ku1,
             ifelse(target_slot == UInt64(2), ku2,
                                              ku3)))
    old_v = ifelse(target_slot == UInt64(0), s[_cf_arr_val_idx(0)],
             ifelse(target_slot == UInt64(1), s[_cf_arr_val_idx(1)],
             ifelse(target_slot == UInt64(2), s[_cf_arr_val_idx(2)],
                                              s[_cf_arr_val_idx(3)])))

    # Write diff entries: for each diff slot d, write if d == safe_depth
    d_idx0 = ifelse(safe_depth == UInt64(0), target_slot, s[_cf_diff_idx_idx(0)])
    d_key0 = ifelse(safe_depth == UInt64(0), old_k,       s[_cf_diff_key_idx(0)])
    d_val0 = ifelse(safe_depth == UInt64(0), old_v,       s[_cf_diff_val_idx(0)])

    d_idx1 = ifelse(safe_depth == UInt64(1), target_slot, s[_cf_diff_idx_idx(1)])
    d_key1 = ifelse(safe_depth == UInt64(1), old_k,       s[_cf_diff_key_idx(1)])
    d_val1 = ifelse(safe_depth == UInt64(1), old_v,       s[_cf_diff_val_idx(1)])

    d_idx2 = ifelse(safe_depth == UInt64(2), target_slot, s[_cf_diff_idx_idx(2)])
    d_key2 = ifelse(safe_depth == UInt64(2), old_k,       s[_cf_diff_key_idx(2)])
    d_val2 = ifelse(safe_depth == UInt64(2), old_v,       s[_cf_diff_val_idx(2)])

    d_idx3 = ifelse(safe_depth == UInt64(3), target_slot, s[_cf_diff_idx_idx(3)])
    d_key3 = ifelse(safe_depth == UInt64(3), old_k,       s[_cf_diff_key_idx(3)])
    d_val3 = ifelse(safe_depth == UInt64(3), old_v,       s[_cf_diff_val_idx(3)])

    # ── Step 3: write new (k, v) into Arr at target_slot ────────────────────
    new_ku0 = ifelse(target_slot == UInt64(0), k_u, ku0)
    new_vu0 = ifelse(target_slot == UInt64(0), v_u, s[_cf_arr_val_idx(0)])
    new_ku1 = ifelse(target_slot == UInt64(1), k_u, ku1)
    new_vu1 = ifelse(target_slot == UInt64(1), v_u, s[_cf_arr_val_idx(1)])
    new_ku2 = ifelse(target_slot == UInt64(2), k_u, ku2)
    new_vu2 = ifelse(target_slot == UInt64(2), v_u, s[_cf_arr_val_idx(2)])
    new_ku3 = ifelse(target_slot == UInt64(3), k_u, ku3)
    new_vu3 = ifelse(target_slot == UInt64(3), v_u, s[_cf_arr_val_idx(3)])

    # ── Step 4: update metadata ──────────────────────────────────────────────
    # arr_count only increases when we used a new slot (not a match)
    new_count = ifelse(any_match | (count >= UInt64(_CF_MAX_N)),
                       count,
                       count + UInt64(1))
    # diff_depth always increments (clamped)
    new_depth = ifelse(depth >= UInt64(_CF_MAX_DIFFS),
                       UInt64(_CF_MAX_DIFFS),
                       depth + UInt64(1))

    return (new_depth,
            new_count,
            new_ku0, new_vu0,
            new_ku1, new_vu1,
            new_ku2, new_vu2,
            new_ku3, new_vu3,
            d_idx0, d_key0, d_val0,
            d_idx1, d_key1, d_val1,
            d_idx2, d_key2, d_val2,
            d_idx3, d_key3, d_val3)
end

"""
    cf_pmap_get(s::CFState, k::Int8) -> Int8

Look up key `k` in the materialised Arr.

C-F property: the Arr is ALWAYS the current version, so `get` is O(max_n)
branchless scan — no Diff traversal needed (no `reroot` required).
Returns zero(Int8) if `k` is not found.
"""
@inline function cf_pmap_get(s::CFState, k::Int8)::Int8
    k_u = UInt64(reinterpret(UInt8, k))
    count = s[_CF_OFF_COUNT]

    # Scan Arr slots; return the latest matching value.
    # (For distinct keys, there is at most one match.  For overwrite scenarios,
    # the Arr always has the latest value at the target slot.)
    in_use0 = count > UInt64(0)
    in_use1 = count > UInt64(1)
    in_use2 = count > UInt64(2)
    in_use3 = count > UInt64(3)

    match0 = in_use0 & (s[_cf_arr_key_idx(0)] == k_u)
    match1 = in_use1 & (s[_cf_arr_key_idx(1)] == k_u)
    match2 = in_use2 & (s[_cf_arr_key_idx(2)] == k_u)
    match3 = in_use3 & (s[_cf_arr_key_idx(3)] == k_u)

    acc = UInt64(0)
    acc = ifelse(match0, s[_cf_arr_val_idx(0)], acc)
    acc = ifelse(match1, s[_cf_arr_val_idx(1)], acc)
    acc = ifelse(match2, s[_cf_arr_val_idx(2)], acc)
    acc = ifelse(match3, s[_cf_arr_val_idx(3)], acc)

    return reinterpret(Int8, UInt8(acc & UInt64(0xff)))
end

"""
    cf_reroot(s::CFState) -> CFState

Walk the Diff chain backward, restoring the Arr to a previous version.
Pops ONE diff entry (decrements diff_depth by 1, restores the arr slot).

This is the explicit implementation of C-F's `reroot` step for
documentation and testing.  In Bennett's construction, the reverse
pass runs `cf_pmap_set` backward, which achieves the same effect.
Calling `cf_reroot` N times undoes the last N `cf_pmap_set` calls.

Branchless: uses `ifelse` throughout.
"""
@inline function cf_reroot(s::CFState)::CFState
    depth = s[_CF_OFF_DEPTH]
    # Pop the top diff entry (depth-1, 0-based)
    pop_d = ifelse(depth == UInt64(0), UInt64(0), depth - UInt64(1))

    # Read the diff entry at pop_d
    # (Branchless: read all 4 entries, select by pop_d)
    r_idx = ifelse(pop_d == UInt64(0), s[_cf_diff_idx_idx(0)],
             ifelse(pop_d == UInt64(1), s[_cf_diff_idx_idx(1)],
             ifelse(pop_d == UInt64(2), s[_cf_diff_idx_idx(2)],
                                        s[_cf_diff_idx_idx(3)])))
    r_key = ifelse(pop_d == UInt64(0), s[_cf_diff_key_idx(0)],
             ifelse(pop_d == UInt64(1), s[_cf_diff_key_idx(1)],
             ifelse(pop_d == UInt64(2), s[_cf_diff_key_idx(2)],
                                        s[_cf_diff_key_idx(3)])))
    r_val = ifelse(pop_d == UInt64(0), s[_cf_diff_val_idx(0)],
             ifelse(pop_d == UInt64(1), s[_cf_diff_val_idx(1)],
             ifelse(pop_d == UInt64(2), s[_cf_diff_val_idx(2)],
                                        s[_cf_diff_val_idx(3)])))

    # Restore Arr at slot r_idx
    new_ku0 = ifelse(r_idx == UInt64(0), r_key, s[_cf_arr_key_idx(0)])
    new_vu0 = ifelse(r_idx == UInt64(0), r_val, s[_cf_arr_val_idx(0)])
    new_ku1 = ifelse(r_idx == UInt64(1), r_key, s[_cf_arr_key_idx(1)])
    new_vu1 = ifelse(r_idx == UInt64(1), r_val, s[_cf_arr_val_idx(1)])
    new_ku2 = ifelse(r_idx == UInt64(2), r_key, s[_cf_arr_key_idx(2)])
    new_vu2 = ifelse(r_idx == UInt64(2), r_val, s[_cf_arr_val_idx(2)])
    new_ku3 = ifelse(r_idx == UInt64(3), r_key, s[_cf_arr_key_idx(3)])
    new_vu3 = ifelse(r_idx == UInt64(3), r_val, s[_cf_arr_val_idx(3)])

    # arr_count decreases if old_key was zero (sentinel for "empty slot")
    # — i.e., if we're undoing an allocation into a previously empty slot.
    count = s[_CF_OFF_COUNT]
    new_count = ifelse(depth == UInt64(0),
                       count,    # nothing to undo
                       ifelse(r_key == UInt64(0),
                              ifelse(count > UInt64(0), count - UInt64(1), UInt64(0)),
                              count))  # overwrite undo: slot stays allocated

    # Decrement depth (if > 0)
    new_depth = ifelse(depth == UInt64(0), UInt64(0), depth - UInt64(1))

    return (new_depth,
            new_count,
            new_ku0, new_vu0,
            new_ku1, new_vu1,
            new_ku2, new_vu2,
            new_ku3, new_vu3,
            s[_cf_diff_idx_idx(0)], s[_cf_diff_key_idx(0)], s[_cf_diff_val_idx(0)],
            s[_cf_diff_idx_idx(1)], s[_cf_diff_key_idx(1)], s[_cf_diff_val_idx(1)],
            s[_cf_diff_idx_idx(2)], s[_cf_diff_key_idx(2)], s[_cf_diff_val_idx(2)],
            s[_cf_diff_idx_idx(3)], s[_cf_diff_key_idx(3)], s[_cf_diff_val_idx(3)])
end

# ─── IMPL BUNDLE ──────────────────────────────────────────────────────────────

"Bundle for harness loop (T5-P3d)."
const CF_IMPL = PersistentMapImpl(
    name     = "cf_semi_persistent",
    K        = Int8,
    V        = Int8,
    max_n    = _CF_MAX_N,
    pmap_new = cf_pmap_new,
    pmap_set = cf_pmap_set,
    pmap_get = cf_pmap_get,
)
