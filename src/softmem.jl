# ---- soft_mux_*: reversible memory operations on packed UInt64 arrays ----
#
# These are pure Julia integer functions that model MUX-EXCH on fixed-size,
# bit-packed arrays. They become callees invoked by lower_store!/lower_alloca!
# (T1b.3) via register_callee! (T1b.2), analogous to how soft_fadd is invoked
# from lower_fadd. Branchless — all slots are computed and MUX-selected so the
# compiled reversible circuit has no data-dependent control flow.
#
# Naming convention: soft_mux_<op>_<N>x<W> where N is the element count and
# W is the bit width per element. Shapes covered (all fit in one UInt64):
#
#   W=8:  N ∈ {2, 4, 8}
#   W=16: N ∈ {2, 4}
#   W=32: N ∈ {2}
#
# Constraint: N·W ≤ 64 (single-UInt64 packing). Multi-word shapes (N·W > 64,
# e.g. (8, 16), (16, 8), (32, 8)) are a follow-up (M1b).

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

# --- N=8, W=8 variant (fully fills a UInt64) ---

"""
    soft_mux_store_8x8(arr, idx, val) -> UInt64

Write `val & 0xff` into position `idx ∈ 0:7` of an 8-element, 8-bit array
packed into all 64 bits of `arr`. Branchless; same structure as the 4x8
variant but over 8 slots.
"""
@inline function soft_mux_store_8x8(arr::UInt64, idx::UInt64, val::UInt64)::UInt64
    m = UInt64(0xff)
    v = val & m
    s0 = ifelse(idx == UInt64(0), v, arr         & m)
    s1 = ifelse(idx == UInt64(1), v, (arr >> 8)  & m)
    s2 = ifelse(idx == UInt64(2), v, (arr >> 16) & m)
    s3 = ifelse(idx == UInt64(3), v, (arr >> 24) & m)
    s4 = ifelse(idx == UInt64(4), v, (arr >> 32) & m)
    s5 = ifelse(idx == UInt64(5), v, (arr >> 40) & m)
    s6 = ifelse(idx == UInt64(6), v, (arr >> 48) & m)
    s7 = ifelse(idx == UInt64(7), v, (arr >> 56) & m)
    return s0 | (s1 << 8) | (s2 << 16) | (s3 << 24) |
           (s4 << 32) | (s5 << 40) | (s6 << 48) | (s7 << 56)
end

"""
    soft_mux_load_8x8(arr, idx) -> UInt64

Read position `idx ∈ 0:7` from an 8-element, 8-bit array.
"""
@inline function soft_mux_load_8x8(arr::UInt64, idx::UInt64)::UInt64
    m = UInt64(0xff)
    s0 = arr         & m
    s1 = (arr >> 8)  & m
    s2 = (arr >> 16) & m
    s3 = (arr >> 24) & m
    s4 = (arr >> 32) & m
    s5 = (arr >> 40) & m
    s6 = (arr >> 48) & m
    s7 = (arr >> 56) & m
    return ifelse(idx == UInt64(0), s0,
           ifelse(idx == UInt64(1), s1,
           ifelse(idx == UInt64(2), s2,
           ifelse(idx == UInt64(3), s3,
           ifelse(idx == UInt64(4), s4,
           ifelse(idx == UInt64(5), s5,
           ifelse(idx == UInt64(6), s6, s7)))))))
end

# --- M1 additions: (2,8), (2,16), (4,16), (2,32) ---
# All UInt64-packable (N·W ≤ 64). Structure matches the (4,8)/(8,8) hand-
# written variants; each slot is extracted via shift+mask, selection is a
# branchless ifelse chain, assembly is shift+OR.

"""
    soft_mux_store_2x8(arr, idx, val) -> UInt64

Write `val & 0xff` into position `idx ∈ 0:1` of a 2-element, 8-bit array
packed into the low 16 bits of `arr`.
"""
@inline function soft_mux_store_2x8(arr::UInt64, idx::UInt64, val::UInt64)::UInt64
    m = UInt64(0xff)
    v = val & m
    s0 = ifelse(idx == UInt64(0), v, arr        & m)
    s1 = ifelse(idx == UInt64(1), v, (arr >> 8) & m)
    return s0 | (s1 << 8)
end

"""
    soft_mux_load_2x8(arr, idx) -> UInt64

Read position `idx ∈ 0:1` of a 2-element, 8-bit array.
"""
@inline function soft_mux_load_2x8(arr::UInt64, idx::UInt64)::UInt64
    m = UInt64(0xff)
    s0 = arr        & m
    s1 = (arr >> 8) & m
    return ifelse(idx == UInt64(0), s0, s1)
end

"""
    soft_mux_store_2x16(arr, idx, val) -> UInt64

Write `val & 0xffff` into position `idx ∈ 0:1` of a 2-element, 16-bit array
packed into the low 32 bits of `arr`.
"""
@inline function soft_mux_store_2x16(arr::UInt64, idx::UInt64, val::UInt64)::UInt64
    m = UInt64(0xffff)
    v = val & m
    s0 = ifelse(idx == UInt64(0), v, arr         & m)
    s1 = ifelse(idx == UInt64(1), v, (arr >> 16) & m)
    return s0 | (s1 << 16)
end

"""
    soft_mux_load_2x16(arr, idx) -> UInt64

Read position `idx ∈ 0:1` of a 2-element, 16-bit array.
"""
@inline function soft_mux_load_2x16(arr::UInt64, idx::UInt64)::UInt64
    m = UInt64(0xffff)
    s0 = arr         & m
    s1 = (arr >> 16) & m
    return ifelse(idx == UInt64(0), s0, s1)
end

"""
    soft_mux_store_4x16(arr, idx, val) -> UInt64

Write `val & 0xffff` into position `idx ∈ 0:3` of a 4-element, 16-bit array
filling all 64 bits of `arr`.
"""
@inline function soft_mux_store_4x16(arr::UInt64, idx::UInt64, val::UInt64)::UInt64
    m = UInt64(0xffff)
    v = val & m
    s0 = ifelse(idx == UInt64(0), v, arr         & m)
    s1 = ifelse(idx == UInt64(1), v, (arr >> 16) & m)
    s2 = ifelse(idx == UInt64(2), v, (arr >> 32) & m)
    s3 = ifelse(idx == UInt64(3), v, (arr >> 48) & m)
    return s0 | (s1 << 16) | (s2 << 32) | (s3 << 48)
end

"""
    soft_mux_load_4x16(arr, idx) -> UInt64

Read position `idx ∈ 0:3` of a 4-element, 16-bit array.
"""
@inline function soft_mux_load_4x16(arr::UInt64, idx::UInt64)::UInt64
    m = UInt64(0xffff)
    s0 = arr         & m
    s1 = (arr >> 16) & m
    s2 = (arr >> 32) & m
    s3 = (arr >> 48) & m
    return ifelse(idx == UInt64(0), s0,
           ifelse(idx == UInt64(1), s1,
           ifelse(idx == UInt64(2), s2, s3)))
end

"""
    soft_mux_store_2x32(arr, idx, val) -> UInt64

Write `val & 0xffffffff` into position `idx ∈ 0:1` of a 2-element, 32-bit
array filling all 64 bits of `arr`.
"""
@inline function soft_mux_store_2x32(arr::UInt64, idx::UInt64, val::UInt64)::UInt64
    m = UInt64(0xffffffff)
    v = val & m
    s0 = ifelse(idx == UInt64(0), v, arr         & m)
    s1 = ifelse(idx == UInt64(1), v, (arr >> 32) & m)
    return s0 | (s1 << 32)
end

"""
    soft_mux_load_2x32(arr, idx) -> UInt64

Read position `idx ∈ 0:1` of a 2-element, 32-bit array.
"""
@inline function soft_mux_load_2x32(arr::UInt64, idx::UInt64)::UInt64
    m = UInt64(0xffffffff)
    s0 = arr         & m
    s1 = (arr >> 32) & m
    return ifelse(idx == UInt64(0), s0, s1)
end

# ---- M2d additions: guarded MUX store callees (Bennett-cc0 / Bennett-i2a6) ----
#
# Each `soft_mux_store_guarded_NxW(arr, idx, val, pred)` behaves exactly like
# the matching `soft_mux_store_NxW(arr, idx, val)` when `pred & 1 == 1`, and
# returns `arr` unchanged when `pred & 1 == 0`. The low bit of `pred` carries
# the path predicate (block guard); high bits are explicitly masked off to
# defend against high-bit garbage surfacing via the 1→64 wire promotion.
#
# Design: fold `pred & 1` into the per-slot `ifelse` cond. When the predicate
# is 0, no slot matches, every slot returns its OLD value, and the packed
# output equals `arr` bit-for-bit. Branchless; semantically identical to the
# (wrap-with-outer-mux) pattern but ~2.5× cheaper in reversible gates
# (see docs/design/m2d_consensus.md).

"""
    soft_mux_store_guarded_4x8(arr, idx, val, pred) -> UInt64

M2d — conditional MUX-store. When `pred & 1 != 0`, behaves as
`soft_mux_store_4x8(arr, idx, val)`. When `pred & 1 == 0`, returns `arr`
unchanged. Branchless; `pred` is the block-predicate wire promoted to
UInt64 (low bit carries the 1-bit path predicate; high bits ignored).
"""
@inline function soft_mux_store_guarded_4x8(arr::UInt64, idx::UInt64,
                                            val::UInt64, pred::UInt64)::UInt64
    m = UInt64(0xff)
    v = val & m
    g = pred & UInt64(1)
    s0 = ifelse((g & UInt64(idx == UInt64(0))) != UInt64(0), v, arr         & m)
    s1 = ifelse((g & UInt64(idx == UInt64(1))) != UInt64(0), v, (arr >> 8)  & m)
    s2 = ifelse((g & UInt64(idx == UInt64(2))) != UInt64(0), v, (arr >> 16) & m)
    s3 = ifelse((g & UInt64(idx == UInt64(3))) != UInt64(0), v, (arr >> 24) & m)
    return s0 | (s1 << 8) | (s2 << 16) | (s3 << 24)
end

"""
    soft_mux_store_guarded_8x8(arr, idx, val, pred) -> UInt64

M2d — conditional MUX-store for 8-element, 8-bit array filling a UInt64.
Semantics and masking match `soft_mux_store_guarded_4x8`.
"""
@inline function soft_mux_store_guarded_8x8(arr::UInt64, idx::UInt64,
                                            val::UInt64, pred::UInt64)::UInt64
    m = UInt64(0xff)
    v = val & m
    g = pred & UInt64(1)
    s0 = ifelse((g & UInt64(idx == UInt64(0))) != UInt64(0), v, arr         & m)
    s1 = ifelse((g & UInt64(idx == UInt64(1))) != UInt64(0), v, (arr >> 8)  & m)
    s2 = ifelse((g & UInt64(idx == UInt64(2))) != UInt64(0), v, (arr >> 16) & m)
    s3 = ifelse((g & UInt64(idx == UInt64(3))) != UInt64(0), v, (arr >> 24) & m)
    s4 = ifelse((g & UInt64(idx == UInt64(4))) != UInt64(0), v, (arr >> 32) & m)
    s5 = ifelse((g & UInt64(idx == UInt64(5))) != UInt64(0), v, (arr >> 40) & m)
    s6 = ifelse((g & UInt64(idx == UInt64(6))) != UInt64(0), v, (arr >> 48) & m)
    s7 = ifelse((g & UInt64(idx == UInt64(7))) != UInt64(0), v, (arr >> 56) & m)
    return s0 | (s1 << 8) | (s2 << 16) | (s3 << 24) |
           (s4 << 32) | (s5 << 40) | (s6 << 48) | (s7 << 56)
end

# Parametric guarded-store generation for the other four M1 shapes.
# Structure matches the corresponding unguarded `soft_mux_store_NxW`:
# extract each slot via shift+mask, select with a pred-folded `ifelse`,
# re-assemble via shift+OR. N·W ≤ 64 invariant per M1.
for (N, W) in [(2, 8), (2, 16), (4, 16), (2, 32)]
    @assert N * W <= 64 "shape ($N, $W) exceeds UInt64 packing"
    fn_name = Symbol(:soft_mux_store_guarded_, N, :x, W)
    mask    = UInt64((UInt128(1) << W) - UInt128(1))

    @eval begin
        """
            $($(QuoteNode(fn_name)))(arr, idx, val, pred) -> UInt64

        M2d — conditional MUX-store for $($N)×$($W)-bit packed array. Behaves
        as `soft_mux_store_$($N)x$($W)(arr, idx, val)` when `pred & 1 != 0`;
        returns `arr` unchanged when `pred & 1 == 0`. Branchless; high bits
        of `pred` are masked off.
        """
        @inline function $fn_name(arr::UInt64, idx::UInt64,
                                  val::UInt64, pred::UInt64)::UInt64
            m = $mask
            v = val & m
            g = pred & UInt64(1)
            slots = ntuple($N) do k
                k0 = UInt64(k - 1)
                ifelse((g & UInt64(idx == k0)) != UInt64(0),
                       v, (arr >> (Int(k0) * $W)) & m)
            end
            return reduce(|, ntuple(k -> slots[k] << ((k - 1) * $W), $N))
        end
    end
end
