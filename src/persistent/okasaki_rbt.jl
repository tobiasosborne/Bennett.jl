# ---- Okasaki 1999 Red-Black Tree — reversible persistent map (T5-P3b) ----
#
# Reference: Okasaki 1999, JFP 9(4):471–477.
#            Kahrs 2001, JFP 11(4):425–432 (delete — DEFERRED, see below).
#
# State layout: NTuple{3, UInt64}
#
#   s[1]: node 1 (bits  0:23) | node 2 (bits 24:47)
#   s[2]: node 3 (bits  0:23) | node 4 (bits 24:47)
#   s[3]: root_idx (bits 0:2) | next_free_count (bits 3:5)
#
# Node 24-bit encoding:
#   bit   0:     color   (0 = Red,  1 = Black)
#   bits  1:3:   left child index (0 = null/empty, 1..4 = slot index)
#   bits  4:6:   right child index (0 = null/empty, 1..4)
#   bits  7:14:  key as UInt8  (reinterpret Int8 → UInt8)
#   bits 15:22:  value as UInt8 (reinterpret Int8 → UInt8)
#   bit  23:     unused / reserved
#
# next_free_count counts HOW MANY nodes have been allocated (0 initially).
# The next slot to allocate = next_free_count + 1.  Slots 1..4.
#
# Tree design choice: OPTION (a), flat node pool.
#   Node slot indices are stable: node slot i is always stored at slot i.
#   Balance restructures only changes FIELDS (color, left, right) of
#   existing slots, not which slot holds which physical node.
#   This makes the branchless "write all slots" pattern natural.
#
# Branchless design: ALL reads and writes touch all 4 node slots on
# every call.  No data-dependent `if` — only `ifelse`.  Gate count is
# therefore independent of key/value inputs.
#
# Depth bound: with max_n=4 insertions and Okasaki balance, the tree
# height is at most 3.  Lookup traverses at most 3 levels.  Insert
# traverses at most 2 levels (grandparent–parent–child) for balance.
#
# Conformance: satisfies PersistentMapImpl protocol (interface.jl).
#
# ---- DELETE: DEFERRED ----
# Kahrs 2001 delete requires `app` (tree-merge) of O(log n) recursive
# calls and `balleft`/`balright` rebalance — roughly 2× the insert code.
# For this bead (T5-P3b) we implement insert + lookup only.  Delete is
# deferred to a follow-up bead (Bennett-cc0.1).  The pmap_set semantics
# (latest write wins for equal keys, no delete primitive) fully satisfies
# the PersistentMapImpl protocol's semantic contract.
#
# ---- FALSE-PATH SENSITIZATION RISK (CLAUDE.md "Phi Resolution") ----
# The balance step computes ALL four case-specific node values (LL, LR,
# RL, RR) and selects among them via chained `ifelse`.  Each case
# expression uses pointer fields from grandparent + parent + new node.
# The case predicates are MUTUALLY EXCLUSIVE (exactly one of {LL,LR,RL,RR}
# can fire when do_balance is true), so there is no false-path
# sensitization: only the selected branch's result is read out; the
# unused branches' values are computed but immediately discarded.
# The MUX circuit naturally handles this — the discarded branches produce
# ancilla values that are uncomputed by Bennett's reverse pass.
# Risk is LOW.  Verified by exhaustive 3-key (1331 inputs) and 4-key
# (2401 inputs) pure-Julia tests before compilation.

const _RBT_NODE_MASK = (UInt64(1) << 24) - UInt64(1)
const _RBT_RED   = UInt64(0)
const _RBT_BLACK = UInt64(1)
const _RBT_STATE_LEN = 3

"""State type for the Okasaki RBT persistent map."""
const OkasakiState = NTuple{_RBT_STATE_LEN, UInt64}

# ---- Node packing / unpacking (inline helpers) ----

@inline function _rbt_pack(col::UInt64, l::UInt64, r::UInt64,
                            k::UInt64, v::UInt64)::UInt64
    return (col & UInt64(1)) |
           ((l & UInt64(7)) << 1) |
           ((r & UInt64(7)) << 4) |
           ((k & UInt64(0xFF)) << 7) |
           ((v & UInt64(0xFF)) << 15)
end

@inline _rbt_color(n::UInt64)::UInt64 = n & UInt64(1)
@inline _rbt_left(n::UInt64)::UInt64  = (n >> 1) & UInt64(7)
@inline _rbt_right(n::UInt64)::UInt64 = (n >> 4) & UInt64(7)
@inline _rbt_key(n::UInt64)::UInt64   = (n >> 7)  & UInt64(0xFF)
@inline _rbt_val(n::UInt64)::UInt64   = (n >> 15) & UInt64(0xFF)

# ---- State slot accessors (branchless: always read all 4 node slots) ----

@inline function _rbt_get(s::OkasakiState, idx::UInt64)::UInt64
    # idx ∈ {0,1,2,3,4}; idx=0 → empty/null → returns 0
    n1 = s[1] & _RBT_NODE_MASK
    n2 = (s[1] >> 24) & _RBT_NODE_MASK
    n3 = s[2] & _RBT_NODE_MASK
    n4 = (s[2] >> 24) & _RBT_NODE_MASK
    sel12 = ifelse(idx == UInt64(1), n1, n2)
    sel34 = ifelse(idx == UInt64(3), n3, n4)
    sel   = ifelse(idx <= UInt64(2), sel12, sel34)
    return ifelse(idx == UInt64(0), UInt64(0), sel)
end

@inline _rbt_root(s::OkasakiState)::UInt64      = s[3] & UInt64(7)
@inline _rbt_nfcount(s::OkasakiState)::UInt64   = (s[3] >> 3) & UInt64(7)

# ---- Protocol implementation ----

"""
    okasaki_pmap_new() -> OkasakiState

Return an empty Okasaki RBT state.
"""
@inline function okasaki_pmap_new()::OkasakiState
    return (UInt64(0), UInt64(0), UInt64(0))
end

"""
    okasaki_pmap_get(s::OkasakiState, k::Int8) -> Int8

Branchless lookup: traverse at most 3 levels of the RBT.
Returns `zero(Int8)` if `k` is not in the map.
"""
@inline function okasaki_pmap_get(s::OkasakiState, k::Int8)::Int8
    k_u = UInt64(reinterpret(UInt8, k))
    root = _rbt_root(s)

    # Level 0 (root)
    nd0  = _rbt_get(s, root)
    hit0 = (root != UInt64(0)) & (_rbt_key(nd0) == k_u)
    val0 = _rbt_val(nd0)
    # Next index: go left or right; 0 if we hit or if node is null
    nxt1 = ifelse(k_u < _rbt_key(nd0), _rbt_left(nd0), _rbt_right(nd0))
    nxt1 = ifelse((root == UInt64(0)) | (_rbt_key(nd0) == k_u), UInt64(0), nxt1)

    # Level 1
    nd1  = _rbt_get(s, nxt1)
    hit1 = (nxt1 != UInt64(0)) & (_rbt_key(nd1) == k_u)
    val1 = _rbt_val(nd1)
    nxt2 = ifelse(k_u < _rbt_key(nd1), _rbt_left(nd1), _rbt_right(nd1))
    nxt2 = ifelse((nxt1 == UInt64(0)) | (_rbt_key(nd1) == k_u), UInt64(0), nxt2)

    # Level 2
    nd2  = _rbt_get(s, nxt2)
    hit2 = (nxt2 != UInt64(0)) & (_rbt_key(nd2) == k_u)
    val2 = _rbt_val(nd2)

    # Fold: at most one hit in a valid RBT with distinct keys
    acc = UInt64(0)
    acc = ifelse(hit0, val0, acc)
    acc = ifelse(hit1, val1, acc)
    acc = ifelse(hit2, val2, acc)

    return reinterpret(Int8, UInt8(acc & UInt64(0xFF)))
end

"""
    okasaki_pmap_set(s::OkasakiState, k::Int8, v::Int8) -> OkasakiState

Branchless insert / overwrite.  Implements Okasaki 1999 insert with
Kahrs 4-case balance.  All four balance cases are computed speculatively
(branchless), then the correct one is selected via `ifelse`.

If `k` already exists, its value is overwritten (dict semantics).
If `k` is new and `next_free_count == 4`, behaviour is impl-defined
(the new key overwrites the 4th slot's previous contents).  In practice
this cannot be reached via the 3-key demo compiled by the harness.
"""
@inline function okasaki_pmap_set(s::OkasakiState, k::Int8, v::Int8)::OkasakiState
    k_u = UInt64(reinterpret(UInt8, k))
    v_u = UInt64(reinterpret(UInt8, v))

    root_idx  = _rbt_root(s)
    nf_count  = _rbt_nfcount(s)

    # Read all 4 raw node slots up front (branchless — always touch all 4)
    raw1 = s[1] & _RBT_NODE_MASK
    raw2 = (s[1] >> 24) & _RBT_NODE_MASK
    raw3 = s[2] & _RBT_NODE_MASK
    raw4 = (s[2] >> 24) & _RBT_NODE_MASK

    # Branchless slot read (no nested functions — inline the select)
    @inline function gr(idx::UInt64)::UInt64
        s12 = ifelse(idx == UInt64(1), raw1, raw2)
        s34 = ifelse(idx == UInt64(3), raw3, raw4)
        ss  = ifelse(idx <= UInt64(2), s12, s34)
        return ifelse(idx == UInt64(0), UInt64(0), ss)
    end

    # ---- Trace insert path (depth 0, 1, 2) ----

    # Depth 0: root
    nd0 = gr(root_idx)
    k0 = _rbt_key(nd0); v0 = _rbt_val(nd0)
    c0 = _rbt_color(nd0); l0 = _rbt_left(nd0); r0 = _rbt_right(nd0)
    hit0  = (root_idx != UInt64(0)) & (k0 == k_u)
    gl0   = k_u < k0   # go-left at depth 0
    nxt1  = ifelse(hit0 | (root_idx == UInt64(0)), UInt64(0),
                   ifelse(gl0, l0, r0))

    # Depth 1
    nd1 = gr(nxt1)
    k1 = _rbt_key(nd1); v1 = _rbt_val(nd1)
    c1 = _rbt_color(nd1); l1 = _rbt_left(nd1); r1 = _rbt_right(nd1)
    hit1  = (nxt1 != UInt64(0)) & (k1 == k_u)
    gl1   = k_u < k1
    nxt2  = ifelse(hit1 | (nxt1 == UInt64(0)), UInt64(0),
                   ifelse(gl1, l1, r1))

    # Depth 2
    nd2 = gr(nxt2)
    k2 = _rbt_key(nd2); v2 = _rbt_val(nd2)
    c2 = _rbt_color(nd2); l2 = _rbt_left(nd2); r2 = _rbt_right(nd2)
    hit2  = (nxt2 != UInt64(0)) & (k2 == k_u)

    # ---- Classify insert position ----
    key_exists = hit0 | hit1 | hit2
    ins_at_0   = root_idx == UInt64(0)                              # empty tree
    ins_at_1   = !ins_at_0 & !hit0 & (nxt1 == UInt64(0))          # child of root
    ins_at_2   = !ins_at_0 & !hit0 & !ins_at_1 & !hit1 & (nxt2 == UInt64(0)) # grandchild

    # Slot for the new/updated node
    existing_slot = ifelse(hit0, root_idx, ifelse(hit1, nxt1, nxt2))
    alloc_slot    = nf_count + UInt64(1)   # allocate next slot (1-indexed)
    new_slot      = ifelse(key_exists, existing_slot, alloc_slot)

    # New next_free_count
    new_nf = ifelse(key_exists, nf_count, nf_count + UInt64(1))

    # Fields of the new node:
    # If overwriting: preserve color + child ptrs, update val
    ow_color = ifelse(hit0, c0, ifelse(hit1, c1, c2))
    ow_left  = ifelse(hit0, l0, ifelse(hit1, l1, l2))
    ow_right = ifelse(hit0, r0, ifelse(hit1, r1, r2))
    nn_color = ifelse(key_exists, ow_color, _RBT_RED)
    nn_left  = ifelse(key_exists, ow_left,  UInt64(0))
    nn_right = ifelse(key_exists, ow_right, UInt64(0))
    new_node = _rbt_pack(nn_color, nn_left, nn_right, k_u, v_u)

    # ---- Step 1: write new/updated node into its slot ----
    u1 = ifelse(new_slot == UInt64(1), new_node, raw1)
    u2 = ifelse(new_slot == UInt64(2), new_node, raw2)
    u3 = ifelse(new_slot == UInt64(3), new_node, raw3)
    u4 = ifelse(new_slot == UInt64(4), new_node, raw4)

    # ---- Step 2: update parent's child pointer ----
    # parent of the new node:
    #   ins_at_0: no parent (new node IS the root)
    #   ins_at_1: parent = root (root_idx)
    #   ins_at_2: parent = nxt1
    par_idx   = ifelse(ins_at_1, root_idx, nxt1)
    n_goes_l  = ifelse(ins_at_1, gl0, gl1)   # direction from parent to new node

    # Read parent from the updated slots
    par_nd = ifelse(par_idx == UInt64(1), u1,
              ifelse(par_idx == UInt64(2), u2,
               ifelse(par_idx == UInt64(3), u3, u4)))
    par_c  = _rbt_color(par_nd)
    par_l  = _rbt_left(par_nd)
    par_r  = _rbt_right(par_nd)
    par_k  = _rbt_key(par_nd)
    par_v  = _rbt_val(par_nd)
    new_pl = ifelse(n_goes_l,  new_slot, par_l)
    new_pr = ifelse(!n_goes_l, new_slot, par_r)
    par_upd = _rbt_pack(par_c, new_pl, new_pr, par_k, par_v)
    do_par  = (ins_at_1 | ins_at_2) & !key_exists
    par_fin = ifelse(do_par, par_upd, par_nd)

    u1 = ifelse(par_idx == UInt64(1), par_fin, u1)
    u2 = ifelse(par_idx == UInt64(2), par_fin, u2)
    u3 = ifelse(par_idx == UInt64(3), par_fin, u3)
    u4 = ifelse(par_idx == UInt64(4), par_fin, u4)

    # ---- Step 3: Okasaki balance (depth-2 inserts only) ----
    #
    # Balance fires when: ins_at_2 & !key_exists & parent_is_Red.
    # At this point GP=root (root_idx), P=nxt1, N=new_slot.
    # Parent's color before the insert = c1 (from nd1).
    # GP direction toward P: gl0 (gp_goes_left).
    # P direction toward N:  gl1 (p_goes_left).
    #
    # 4 Okasaki cases and their node-slot results:
    #
    # Case LL (ggl=true,  pgl=true):
    #   new-root = P slot, left = N slot (Black), right = GP slot (Black)
    #   GP slot ← Black(left=p_r,   right=r0,         key=k0, val=v0)
    #   P  slot ← Red  (left=N_slot, right=GP_slot,   key=k1, val=v1)
    #   N  slot ← Black(left=0,      right=0,          key=k_u, val=v_u)
    #
    # Case LR (ggl=true,  pgl=false):
    #   new-root = N slot, left = P slot (Black), right = GP slot (Black)
    #   GP slot ← Black(left=0,      right=r0,         key=k0, val=v0)
    #   P  slot ← Black(left=l1,     right=0,          key=k1, val=v1)
    #   N  slot ← Red  (left=P_slot, right=GP_slot,    key=k_u, val=v_u)
    #
    # Case RL (ggl=false, pgl=true):
    #   new-root = N slot, left = GP slot (Black), right = P slot (Black)
    #   GP slot ← Black(left=l0,     right=0,          key=k0, val=v0)
    #   P  slot ← Black(left=0,      right=r1,         key=k1, val=v1)
    #   N  slot ← Red  (left=GP_slot, right=P_slot,    key=k_u, val=v_u)
    #
    # Case RR (ggl=false, pgl=false):
    #   new-root = P slot, left = GP slot (Black), right = N slot (Black)
    #   GP slot ← Black(left=l0,     right=l1,         key=k0, val=v0)
    #   P  slot ← Red  (left=GP_slot, right=N_slot,   key=k1, val=v1)
    #   N  slot ← Black(left=0,       right=0,         key=k_u, val=v_u)
    #
    # All right-hand sides in all 4 cases follow from Okasaki §2d.

    gp_slot = root_idx
    p_slot  = nxt1
    n_slot  = new_slot
    ggl     = gl0    # direction from grandparent to parent
    pgl     = gl1    # direction from parent to new node

    do_balance = ins_at_2 & !key_exists & (c1 == _RBT_RED)

    # Balanced GP slot
    gp_bal_ll = _rbt_pack(_RBT_BLACK, r1,         r0,        k0, v0)  # left=p.right, right=gp.right
    gp_bal_lr = _rbt_pack(_RBT_BLACK, UInt64(0),  r0,        k0, v0)  # left=0,       right=gp.right
    gp_bal_rl = _rbt_pack(_RBT_BLACK, l0,         UInt64(0), k0, v0)  # left=gp.left, right=0
    gp_bal_rr = _rbt_pack(_RBT_BLACK, l0,         l1,        k0, v0)  # left=gp.left, right=p.left
    gp_bal = ifelse(ggl & pgl,    gp_bal_ll,
              ifelse(ggl & !pgl,  gp_bal_lr,
               ifelse(!ggl & pgl, gp_bal_rl,
                gp_bal_rr)))

    # Balanced P slot
    p_bal_ll = _rbt_pack(_RBT_RED,   n_slot,       gp_slot,   k1, v1)  # root: left=N, right=GP
    p_bal_lr = _rbt_pack(_RBT_BLACK, l1,           UInt64(0), k1, v1)  # left child
    p_bal_rl = _rbt_pack(_RBT_BLACK, UInt64(0),    r1,        k1, v1)  # right child
    p_bal_rr = _rbt_pack(_RBT_RED,   gp_slot,      n_slot,    k1, v1)  # root: left=GP, right=N
    p_bal = ifelse(ggl & pgl,    p_bal_ll,
             ifelse(ggl & !pgl,  p_bal_lr,
              ifelse(!ggl & pgl, p_bal_rl,
               p_bal_rr)))

    # Balanced N slot
    n_bal_ll = _rbt_pack(_RBT_BLACK, UInt64(0),   UInt64(0), k_u, v_u) # left leaf
    n_bal_lr = _rbt_pack(_RBT_RED,   p_slot,      gp_slot,   k_u, v_u) # root: left=P, right=GP
    n_bal_rl = _rbt_pack(_RBT_RED,   gp_slot,     p_slot,    k_u, v_u) # root: left=GP, right=P
    n_bal_rr = _rbt_pack(_RBT_BLACK, UInt64(0),   UInt64(0), k_u, v_u) # right leaf
    n_bal = ifelse(ggl & pgl,    n_bal_ll,
             ifelse(ggl & !pgl,  n_bal_lr,
              ifelse(!ggl & pgl, n_bal_rl,
               n_bal_rr)))

    # New root after balance (the "middle" node becomes local root)
    bal_root = ifelse(ggl & pgl,    p_slot,   # LL: P becomes root
                ifelse(ggl & !pgl,  n_slot,   # LR: N becomes root
                 ifelse(!ggl & pgl, n_slot,   # RL: N becomes root
                  p_slot)))                    # RR: P becomes root

    # Apply balance overrides to the 4 slots (branchless MUX)
    f1 = ifelse(do_balance & (gp_slot == UInt64(1)), gp_bal,
          ifelse(do_balance & (p_slot  == UInt64(1)), p_bal,
           ifelse(do_balance & (n_slot  == UInt64(1)), n_bal, u1)))
    f2 = ifelse(do_balance & (gp_slot == UInt64(2)), gp_bal,
          ifelse(do_balance & (p_slot  == UInt64(2)), p_bal,
           ifelse(do_balance & (n_slot  == UInt64(2)), n_bal, u2)))
    f3 = ifelse(do_balance & (gp_slot == UInt64(3)), gp_bal,
          ifelse(do_balance & (p_slot  == UInt64(3)), p_bal,
           ifelse(do_balance & (n_slot  == UInt64(3)), n_bal, u3)))
    f4 = ifelse(do_balance & (gp_slot == UInt64(4)), gp_bal,
          ifelse(do_balance & (p_slot  == UInt64(4)), p_bal,
           ifelse(do_balance & (n_slot  == UInt64(4)), n_bal, u4)))

    # ---- Step 4: determine final root ----
    final_root = ifelse(do_balance, bal_root,
                  ifelse(ins_at_0,  new_slot,
                   root_idx))

    # ---- Step 5: makeBlack (Okasaki §2c: root is always forced Black) ----
    root_nd = ifelse(final_root == UInt64(1), f1,
               ifelse(final_root == UInt64(2), f2,
                ifelse(final_root == UInt64(3), f3, f4)))
    root_blk = root_nd | UInt64(1)   # set color bit → Black
    f1 = ifelse(final_root == UInt64(1), root_blk, f1)
    f2 = ifelse(final_root == UInt64(2), root_blk, f2)
    f3 = ifelse(final_root == UInt64(3), root_blk, f3)
    f4 = ifelse(final_root == UInt64(4), root_blk, f4)

    # ---- Pack and return ----
    new_s1 = f1 | (f2 << 24)
    new_s2 = f3 | (f4 << 24)
    new_s3 = (final_root & UInt64(7)) | ((new_nf & UInt64(7)) << 3)

    return (new_s1, new_s2, new_s3)
end

# ---- Protocol bundle ----

"Okasaki RBT persistent-map impl bundle for harness."
const OKASAKI_IMPL = PersistentMapImpl(
    name     = "okasaki_rbt",
    K        = Int8,
    V        = Int8,
    max_n    = 4,
    pmap_new = okasaki_pmap_new,
    pmap_set = okasaki_pmap_set,
    pmap_get = okasaki_pmap_get,
)
