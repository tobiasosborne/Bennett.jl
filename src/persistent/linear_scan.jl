# ---- Linear-scan stub persistent map (T5-P3a self-test) ----
#
# Simplest possible conforming impl.  State: NTuple of (key, val) slots
# plus a count.  pmap_set writes the new pair at slot[count]; pmap_get
# scans linearly returning the LATEST matching key's value (so overwrites
# work).  Cost: O(max_n) per op.  Used as the harness's correctness
# self-test target — if the harness can't verify this, it's broken.
#
# State layout (max_n=4, K=V=Int8 packed into UInt64 slots for uniformity):
#
#     state :: NTuple{1+2*max_n, UInt64}
#         state[1] = current count of stored pairs (0..max_n)
#         state[2*i]   = key   of pair i,  i ∈ 1:max_n
#         state[2*i+1] = value of pair i,  i ∈ 1:max_n
#
# K / V are widened to UInt64 in storage; the public interface preserves
# the K, V types via Int8 ↔ UInt64 reinterpret-style narrowing.
#
# Branchless: pmap_set always writes ALL slots (each via `ifelse` on slot
# index); pmap_get always scans ALL slots and reduces via latest-match.

# ---- max_n = 4 demo size for self-test ----
const _LS_MAX_N = 4
const _LS_STATE_LEN = 1 + 2 * _LS_MAX_N    # = 9 UInt64s

const LinearScanState = NTuple{_LS_STATE_LEN, UInt64}

"Empty linear-scan map: count=0, all slots zero."
@inline function linear_scan_pmap_new()::LinearScanState
    return ntuple(_ -> UInt64(0), Val(_LS_STATE_LEN))
end

# Branchless slot-write: if `slot_index == target`, write `new_val`,
# else preserve `old_val`.  `slot_index` is COMPILE-TIME constant; the
# `ifelse` is on the runtime value `target`.
@inline _ls_pick(slot_index::Int, target::UInt64, new_val::UInt64,
                 old_val::UInt64)::UInt64 =
    ifelse(target == UInt64(slot_index), new_val, old_val)

"""
    linear_scan_pmap_set(s, k::Int8, v::Int8)::LinearScanState

Insert (k, v) into the next available slot.  If `count == max_n`, the
new pair is written at slot `max_n` (overwriting the last) — overflow
behaviour is impl-defined per protocol.
"""
@inline function linear_scan_pmap_set(s::LinearScanState, k::Int8, v::Int8)::LinearScanState
    count = s[1]
    # Slot to write into: clamp to max_n (overflow case writes to last slot)
    target = ifelse(count >= UInt64(_LS_MAX_N), UInt64(_LS_MAX_N - 1), count)
    new_count = ifelse(count >= UInt64(_LS_MAX_N), UInt64(_LS_MAX_N), count + UInt64(1))
    k_u = UInt64(reinterpret(UInt8, k))
    v_u = UInt64(reinterpret(UInt8, v))

    # Branchless: write k_u/v_u into slot[target], preserve all others.
    # Manually unrolled for max_n=4 (Bennett.jl needs static unroll for compilation).
    k1 = _ls_pick(0, target, k_u, s[2])
    v1 = _ls_pick(0, target, v_u, s[3])
    k2 = _ls_pick(1, target, k_u, s[4])
    v2 = _ls_pick(1, target, v_u, s[5])
    k3 = _ls_pick(2, target, k_u, s[6])
    v3 = _ls_pick(2, target, v_u, s[7])
    k4 = _ls_pick(3, target, k_u, s[8])
    v4 = _ls_pick(3, target, v_u, s[9])

    return (new_count, k1, v1, k2, v2, k3, v3, k4, v4)
end

"""
    linear_scan_pmap_get(s, k::Int8)::Int8

Scan slots 0..max_n-1.  Return the value of the LATEST slot whose key
matches `k`, or zero(Int8) if no slot matches.  Branchless: every slot
is examined; result is folded via `ifelse(match, slot_v, acc)`.

By-design collision (Bennett-e89s / U120): a stored value of `Int8(0)`
returns `Int8(0)`, the same value as an absent-key lookup.  Callers
that need to distinguish absent-from-stored-zero must use a key or
value sentinel — see `interface.jl` protocol contract.
"""
@inline function linear_scan_pmap_get(s::LinearScanState, k::Int8)::Int8
    k_u = UInt64(reinterpret(UInt8, k))
    count = s[1]

    acc = UInt64(0)
    # Slot 0
    in_use_0 = count > UInt64(0)
    match_0  = in_use_0 & (s[2] == k_u)
    acc = ifelse(match_0, s[3], acc)
    # Slot 1
    in_use_1 = count > UInt64(1)
    match_1  = in_use_1 & (s[4] == k_u)
    acc = ifelse(match_1, s[5], acc)
    # Slot 2
    in_use_2 = count > UInt64(2)
    match_2  = in_use_2 & (s[6] == k_u)
    acc = ifelse(match_2, s[7], acc)
    # Slot 3
    in_use_3 = count > UInt64(3)
    match_3  = in_use_3 & (s[8] == k_u)
    acc = ifelse(match_3, s[9], acc)

    return reinterpret(Int8, UInt8(acc & UInt64(0xff)))
end

"Bundle for harness loop."
const LINEAR_SCAN_IMPL = PersistentMapImpl(
    name     = "linear_scan",
    K        = Int8,
    V        = Int8,
    max_n    = _LS_MAX_N,
    pmap_new = linear_scan_pmap_new,
    pmap_set = linear_scan_pmap_set,
    pmap_get = linear_scan_pmap_get,
)
