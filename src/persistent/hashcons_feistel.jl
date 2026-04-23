# ---- Feistel-perfect-hash-cons (T5-P4b, Bennett-7pgw) ----
#
# Reference: Luby & Rackoff 1988; Bennett.jl src/feistel.jl (gate-level
# emit_feistel!).  This file is the pure-Julia branchless callee that
# Bennett.jl reversibilises via the standard pipeline — distinct from
# feistel.jl which emits gates directly.
#
# 4-round Feistel network on 32-bit input split into two 16-bit halves.
# Per round: (L, R) → (R, L XOR F(R)) where F(R)[i] = R[i] AND R[(i+rot) mod 16].
# After 4 rounds the result is a bijection (Luby-Rackoff theorem).
# Rotations [1, 3, 5, 7] are odd, pairwise-unequal — matches the gate-level
# emitter in src/feistel.jl.
#
# Pre-hash for persistent-map keys.  `soft_feistel32` is a bijection on
# UInt32 → UInt32 (Luby-Rackoff).  `soft_feistel_int8` wraps it for Int8
# keys by zero-extending to UInt32, hashing, and truncating the low byte
# — which is NOT a bijection on Int8 → Int8 (Bennett-sqtd / U22). The
# zero-extend-then-truncate loses information: of the 256 Int8 inputs,
# only 207 distinct low-byte outputs are produced, with max collision
# count 5. For HAMT hash-slot distribution this is still a very low-
# collision hash; docstrings are honest about the non-bijection.
#
# Cost prediction: ~8W Toffoli per evaluation (W=16 per half, 4 rounds).
# Compared to Jenkins-96: fewer total ops (~5 per round vs 24 total).

const _FEISTEL_HALF_W = 16
const _FEISTEL_HALF_MASK = UInt32(0xFFFF)
const _FEISTEL_ROTATIONS = (UInt32(1), UInt32(3), UInt32(5), UInt32(7))

"Branchless 16-bit rotate-right of a UInt32 value, masked to the low 16 bits."
@inline function _feistel_rotr16(x::UInt32, rot::UInt32)::UInt32
    masked = x & _FEISTEL_HALF_MASK
    inv_rot = UInt32(_FEISTEL_HALF_W) - rot
    return ((masked >> rot) | (masked << inv_rot)) & _FEISTEL_HALF_MASK
end

"""
    soft_feistel32(x::UInt32) -> UInt32

4-round Feistel bijective hash on UInt32.  Splits input into 16-bit
halves (L, R), runs 4 rounds of `(L, R) → (R, L XOR (R AND rotr(R, rot)))`
with rotations 1, 3, 5, 7.  Result is a bijection — perfect hash.
"""
@inline function soft_feistel32(x::UInt32)::UInt32
    L = (x >> _FEISTEL_HALF_W) & _FEISTEL_HALF_MASK
    R = x & _FEISTEL_HALF_MASK

    # Round 1
    F = R & _feistel_rotr16(R, _FEISTEL_ROTATIONS[1])
    L = L ⊻ F
    L, R = R, L

    # Round 2
    F = R & _feistel_rotr16(R, _FEISTEL_ROTATIONS[2])
    L = L ⊻ F
    L, R = R, L

    # Round 3
    F = R & _feistel_rotr16(R, _FEISTEL_ROTATIONS[3])
    L = L ⊻ F
    L, R = R, L

    # Round 4
    F = R & _feistel_rotr16(R, _FEISTEL_ROTATIONS[4])
    L = L ⊻ F
    L, R = R, L

    return (L << _FEISTEL_HALF_W) | R
end

"""
    soft_feistel_int8(k::Int8) -> Int8

Low-collision 8-bit hash. Zero-extends to UInt32, runs `soft_feistel32`,
truncates the low byte, reinterprets as Int8.

**Not a bijection** (Bennett-sqtd / U22): the zero-extend→Feistel→low-byte
pipeline loses information since Feistel is bijective on UInt32 but only
256 of the 2³² outputs are reachable from 8-bit inputs, and their low
bytes collide. Measured image set size: 207 distinct values / 256 inputs
(max collision count 5, 49 unreachable outputs). Adequate as a HAMT
hash-slot pre-mixer; insufficient if strict bijection is required —
widen to UInt16 or UInt32 codomain in that case (see `soft_feistel32`).
"""
@inline function soft_feistel_int8(k::Int8)::Int8
    k_u32 = UInt32(reinterpret(UInt8, k))
    h = soft_feistel32(k_u32)
    return reinterpret(Int8, UInt8(h & UInt32(0xFF)))
end
