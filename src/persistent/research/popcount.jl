# ---- Bagwell CTPop — reversible-friendly branchless popcount (T5-P3c) ----
#
# RESEARCH-TIER: relocated from src/persistent/ on 2026-04-25 per
# Bennett-uoem / U54.  Not loaded by `using Bennett`; not exported.
# Sole live consumer was hamt.jl (also relocated).  See
# src/persistent/research/README.md for the literate deprecation
# rationale and thaw conditions.
#
# Translates Bagwell 2001 Fig. 2 p. 3 verbatim into pure Julia.
# Original C:
#
#   const unsigned int SK5  = 0x55555555;  // alternating bits (0101...)
#   const unsigned int SK3  = 0x33333333;  // alternating pairs (0011...)
#   const unsigned int SKF0 = 0x0F0F0F0F; // alternating nibbles (00001111...)
#   const unsigned int SKFF = 0xFF00FF;   // alternating bytes (unused in Julia port)
#
#   int CTPop(int Map) {
#     Map -= ((Map >> 1) & SK5);
#     Map = (Map & SK3) + ((Map >> 2) & SK3);
#     Map = (Map & SKF0) + ((Map >> 4) & SKF0);
#     Map += Map >> 8;
#     return (Map + (Map >> 16)) & 0x3F;
#   }
#
# The five lines implement the Hamming-weight / popcount algorithm via
# parallel prefix summation (Wegner 1960 / Kernighan):
#
#   Line 1: parallel 2-bit popcount — each adjacent pair of bits is replaced
#           by the count of set bits in that pair.
#           SK5 = 0x55555555 (binary: 0101...0101) is the even-bit mask.
#           The subtraction trick avoids a second AND: if pair is 00→0, 01→1,
#           10→10-01=01, 11→11-01=10. All results fit in 2 bits, no overflow.
#
#   Line 2: merge adjacent 2-bit counts into 4-bit counts.
#           SK3 = 0x33333333 (binary: 0011...0011) selects low 2 bits of each
#           4-bit group.
#
#   Line 3: merge adjacent 4-bit counts into 8-bit counts.
#           SKF0 = 0x0F0F0F0F (binary: 00001111...00001111) selects low 4 bits.
#           Note: Bagwell writes "0xF0F0F0F" which is the same value (8 hex digits
#           with leading zero dropped: 0x0F0F0F0F).
#
#   Line 4: merge adjacent byte counts into 16-bit counts.
#           No masking needed — counts are at most 8 (4 bits), so no overflow
#           when adding two 8-bit counts (max 16, fits in 5 bits).
#
#   Line 5: final merge of two 16-bit counts and mask to 6 bits.
#           Max popcount of 32 bits = 32, which fits in 6 bits (0x3F).
#
# Bennett-d1ee / U141 — gate-cost annotation. When `soft_popcount32` is
# compiled via `reversible_compile(soft_popcount32, UInt32)` it produces
# a circuit whose Toffoli count is dominated by the four `+` operations
# (lines 1, 2, 3, 4 of the algorithm: each is a 32-bit unsigned add via
# the ripple-carry `lower_add!` since the operands are not dead-on-use).
# At post-U27 `add=:auto→:ripple` defaults: ~2(W-1) Toffolis per add ×
# 4 adds = ~248 Toffolis on UInt32, plus ~5×32 CNOTs for the masks/
# shifts and ~32 for the final 0x3F mask. Exact baseline lives in
# `test/test_persistent_hamt.jl` (under BENNETT_RESEARCH_TESTS=1).
#
# REVERSIBILITY NOTE: This function is NOT a bijection (32^2 → {0..32}).
# It is used inside Bennett's forward pass as a pure combinational function;
# its intermediate values are cleaned up by the uncompute pass. Bennett's
# construction handles non-injective functions correctly.
#
# STANDALONE VALIDATION: exhaustively tested vs. Base.count_ones on 1000+
# random UInt32 inputs. See test/test_persistent_hamt.jl.

"Bagwell 2001 Fig 2 CTPop emulation — branchless 32-bit popcount."
const _POPCOUNT_SK5  = UInt32(0x55555555)
const _POPCOUNT_SK3  = UInt32(0x33333333)
const _POPCOUNT_SKF0 = UInt32(0x0F0F0F0F)

@inline function soft_popcount32(x::UInt32)::UInt32
    SK5  = _POPCOUNT_SK5
    SK3  = _POPCOUNT_SK3
    SKF0 = _POPCOUNT_SKF0

    # Line 1: parallel 2-bit popcount (subtraction trick)
    x = x - ((x >> 1) & SK5)
    # Line 2: merge into 4-bit counts
    x = (x & SK3) + ((x >> 2) & SK3)
    # Line 3: merge into 8-bit counts
    x = (x & SKF0) + ((x >> 4) & SKF0)
    # Line 4: merge into 16-bit counts
    x = x + (x >> 8)
    # Line 5: final merge + mask to 6 bits
    return (x + (x >> 16)) & UInt32(0x3F)
end
