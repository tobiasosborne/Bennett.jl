# ---- Mogensen Jenkins-96 reversible hash (T5-P4a, Bennett-gv8g) ----
#
# Reference: Mogensen 2018 NGC 36:203 Fig. 5 p. 217–218. Pure-Julia branchless
# port of the 24-instruction Jenkins reversible mix function.
#
# Original RIL pseudocode (verbatim, from mogensen_hashcons_brief.md §2e):
#
#     begin hash
#     hashA ^= consA
#     hashB ^= consD
#     hashA += hashB + hashC
#     hashA ^= hashC >> 13
#     hashB -= hashC + hashA
#     hashB ^= hashA << 8
#     hashC += hashA + hashB
#     hashC ^= hashB >> 13
#     hashA -= hashB + hashC
#     hashA ^= hashC >> 12
#     hashB += hashC + hashA
#     hashB ^= hashA << 16
#     hashC -= hashA + hashB
#     hashC ^= hashB >> 5
#     hashA += hashB + hashC
#     hashA ^= hashC >> 3
#     hashB -= hashC + hashA
#     hashB ^= hashA << 10
#     hashC += hashA + hashB
#     hashC ^= hashB >> 15
#     end hash
#
# In Mogensen's paper this is the segment-address generator for the hash-cons
# table — the "hash-cons table is itself reversible" novel piece.  We use it
# in T5 as a hash function on persistent-map keys: pre-hash each key, then
# pass the hashed key to the underlying persistent-DS impl.  Effect:
#   - HAMT bitmap index becomes uniformly distributed (vs raw-key aliasing)
#   - Okasaki BST shape becomes random (better amortised balance)
#   - CF semi-persistent: insensitive to key distribution; hash is overhead
#
# REVERSIBILITY: every line is +/-/XOR with one variable on each side; each
# is locally reversible.  Bennett.jl's standard forward+copy+uncompute
# wrapper produces a (consA, consD, 0) → (consA, consD, hash) transformation.
#
# JENKINS MAGIC CONSTANT: 0x9E3779B9 = floor(2^32 / golden_ratio).  Same
# constant Jenkins used in his 1997 public-domain hash; Mogensen p.218 calls
# the initial values "k_a, k_b, k_c" but doesn't fix them.  We follow Jenkins
# convention.  Documented choice; not load-bearing.

const _JENKINS_GOLDEN = UInt32(0x9E3779B9)

"""
    soft_jenkins96(consA::UInt32, consD::UInt32) -> UInt32

Mogensen 2018 Fig 5 Jenkins-96 reversible mix function as a pure-Julia
branchless function.  Returns the third state register (`hashC`) after
24 mix operations.  Compiles via Bennett.jl to a reversible circuit.
"""
@inline function soft_jenkins96(consA::UInt32, consD::UInt32)::UInt32
    hashA = _JENKINS_GOLDEN ⊻ consA
    hashB = _JENKINS_GOLDEN ⊻ consD
    hashC = _JENKINS_GOLDEN

    # The 18 mix operations from Mogensen p.217–218 Fig 5.  (The first two
    # XORs above are lines 1–2; this block covers lines 3–20.)
    hashA += hashB + hashC
    hashA ⊻= hashC >> 13
    hashB -= hashC + hashA
    hashB ⊻= hashA << 8
    hashC += hashA + hashB
    hashC ⊻= hashB >> 13
    hashA -= hashB + hashC
    hashA ⊻= hashC >> 12
    hashB += hashC + hashA
    hashB ⊻= hashA << 16
    hashC -= hashA + hashB
    hashC ⊻= hashB >> 5
    hashA += hashB + hashC
    hashA ⊻= hashC >> 3
    hashB -= hashC + hashA
    hashB ⊻= hashA << 10
    hashC += hashA + hashB
    hashC ⊻= hashB >> 15

    return hashC
end

"""
    soft_jenkins_int8(k::Int8) -> Int8

Convenience wrapper: hash an Int8 key and return Int8.  Uses the key as
both `consA` and `consD` (cheapest seed for a single-input use case).
The output is the low byte of the hash, reinterpreted as Int8.

This is the function used to "layer" Jenkins on top of the persistent-DS
impls in the T5 hash-cons benchmarks.
"""
@inline function soft_jenkins_int8(k::Int8)::Int8
    k_u32 = UInt32(reinterpret(UInt8, k))
    h = soft_jenkins96(k_u32, k_u32)
    return reinterpret(Int8, UInt8(h & UInt32(0xFF)))
end
