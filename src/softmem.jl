# ---- soft_mux_*: reversible memory operations on packed UInt64 arrays ----
#
# These are pure Julia integer functions that model MUX-EXCH on fixed-size,
# bit-packed arrays. They become callees invoked by lower_store!/lower_alloca!
# (T1b.3) via register_callee! (T1b.2), analogous to how soft_fadd is invoked
# from lower_fadd. Branchless — all slots are computed and MUX-selected so the
# compiled reversible circuit has no data-dependent control flow.
#
# Naming convention: soft_mux_<op>_<N>x<W> where N is the element count and
# W is the bit width per element. Currently covers (N=4, W=8) as the
# minimum viable variant; T1b.5 scales to N=8,16,32,64.

"""
    soft_mux_store_4x8(arr, idx, val) -> UInt64

Write `val & 0xff` into position `idx ∈ 0:3` of a 4-element, 8-bit-per-element
array packed into the low 32 bits of `arr`. Returns the updated array.
Other slots are preserved. Branchless.
"""
@inline function soft_mux_store_4x8(arr::UInt64, idx::UInt64, val::UInt64)::UInt64
    m = UInt64(0xff)
    v = val & m
    s0 = ifelse(idx == UInt64(0), v, arr & m)
    s1 = ifelse(idx == UInt64(1), v, (arr >> 8)  & m)
    s2 = ifelse(idx == UInt64(2), v, (arr >> 16) & m)
    s3 = ifelse(idx == UInt64(3), v, (arr >> 24) & m)
    return s0 | (s1 << 8) | (s2 << 16) | (s3 << 24)
end

"""
    soft_mux_load_4x8(arr, idx) -> UInt64

Read position `idx ∈ 0:3` of a 4-element, 8-bit-per-element array packed into
the low 32 bits of `arr`. Returns the 8-bit slot value zero-extended to UInt64.
Branchless.
"""
@inline function soft_mux_load_4x8(arr::UInt64, idx::UInt64)::UInt64
    m = UInt64(0xff)
    s0 = arr & m
    s1 = (arr >> 8)  & m
    s2 = (arr >> 16) & m
    s3 = (arr >> 24) & m
    return ifelse(idx == UInt64(0), s0,
           ifelse(idx == UInt64(1), s1,
           ifelse(idx == UInt64(2), s2, s3)))
end
