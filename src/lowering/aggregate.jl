# ---- aggregate operations ----

"""
    lower_divrem!(gates, wa, vw, inst, a, b, W)

Lower udiv/urem/sdiv/srem by widening operands to UInt64, calling the
soft division function via gate-level inlining, and truncating back.

# Bennett-y56a / U118 — division-path canonicalisation

There are three paths through which integer division can reach the
gate stream:

  1. **Native `a ÷ b` / `a % b`** (canonical user-facing): LLVM emits
     `udiv`/`sdiv`/`urem`/`srem` → `IRBinOp` → `lower_binop!` (line ~1535)
     → here. Sign extension, magnitude compute, sign-fix all live here.
     This is the only path with full signed-arithmetic support.

  2. **Direct call to `_soft_udiv_compile` / `_soft_urem_compile`** (rare):
     user calls these private kernels directly. The callee mechanism
     (Bennett.jl:301) routes through `lower_call!`. Unsigned-only —
     no sign handling. The public `soft_udiv` / `soft_urem` (post-salb)
     throw `DivideError` on b=0 and are NOT registered as callees;
     direct user calls to them get inlined by Julia or hit the throw's
     `ijl_throw` benign-prefix allowlist (matching the LLVM-poison-
     equivalent contract documented in salb).

  3. **Unregistered callee** (post-salb: errors loud): pre-salb an
     unregistered callee fell to `return nothing` from
     `_convert_instruction`, silently dropping the call. Post-salb
     (Bennett-bjdg / U80, ir_extract.jl:1751) raises a precise
     "no registered callee handler" message via `_ir_error`.

The "triple redundancy" in the original review was the silent-skip
path 3 plus paths 1 and 2 producing different outputs for the same
operation. Path 3 is gone (now loud). Paths 1 and 2 produce the same
unsigned division output (pinned by `test/test_y56a_division_paths.jl`)
but path 1 wraps it with sign handling for signed types — they are
NOT redundant in the strict sense, just two layers of the same call
graph (path 1 internally invokes path 2 via `lower_call!`).

Architectural choice: keep the callee-mechanism path (path 2) instead
of inlining the kernel directly into `lower_divrem!`. Symmetry with
soft_fadd/soft_fmul/etc. (every soft_* function is registered as a
callee) outweighs the small wire-budget gap for divrem-specific
inlining. If a future workload measures the gap as significant, file
a follow-up against `lower_divrem!` directly.
"""
function lower_divrem!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                       vw::Dict{Symbol,Vector{Int}}, inst::IRBinOp,
                       a::Vector{Int}, b::Vector{Int}, W::Int;
                       callee_opts::LowerOptions=LowerOptions())   # Bennett-0a6f
    # Widen a and b to 64 bits (zero-extend for unsigned, sign-extend for signed)
    signed = inst.op in (:sdiv, :srem)
    a64 = allocate!(wa, 64)
    b64 = allocate!(wa, 64)
    for i in 1:W
        push!(gates, CNOTGate(a[i], a64[i]))
        push!(gates, CNOTGate(b[i], b64[i]))
    end
    if signed
        # Sign-extend: copy MSB to upper bits
        for i in (W+1):64
            push!(gates, CNOTGate(a[W], a64[i]))
            push!(gates, CNOTGate(b[W], b64[i]))
        end
    end
    # Upper bits stay 0 for unsigned (already allocated as 0)

    # For signed: convert to unsigned magnitude, divide, fix sign
    # sdiv(a,b) = sign(a)*sign(b) * udiv(|a|, |b|)
    # srem(a,b) = sign(a) * urem(|a|, |b|)
    if signed
        # Compute |a| and |b| by conditional negate
        a_sign = allocate!(wa, 1)
        b_sign = allocate!(wa, 1)
        push!(gates, CNOTGate(a64[64], a_sign[1]))
        push!(gates, CNOTGate(b64[64], b_sign[1]))

        # |a| = a_sign ? -a : a  (two's complement negate = flip all + add 1)
        _cond_negate_inplace!(gates, wa, a64, a_sign, 64)
        _cond_negate_inplace!(gates, wa, b64, b_sign, 64)
    end

    # Select callee — per Bennett-salb / U119 we use the throw-free `_compile`
    # variants. The public soft_udiv/soft_urem raise DivideError on b=0
    # (matching Base.div), but their LLVM IR contains @ijl_throw which
    # lower_call! cannot extract. Compiled circuits therefore inherit
    # LLVM-poison-equivalent behavior on b=0 / signed typemin÷-1
    # (deterministic but unspecified — see _soft_udiv_compile docstring).
    callee = (inst.op in (:udiv, :sdiv)) ? _soft_udiv_compile : _soft_urem_compile

    # Create IRCall and lower it
    call_dest = Symbol("__div_$(inst.dest)")
    call_inst = IRCall(call_dest, callee,
                       [ssa(Symbol("__div_a64_$(inst.dest)")),
                        ssa(Symbol("__div_b64_$(inst.dest)"))],
                       [64, 64], 64)
    # Register the widened operands in vw
    vw[Symbol("__div_a64_$(inst.dest)")] = a64
    vw[Symbol("__div_b64_$(inst.dest)")] = b64
    lower_call!(gates, wa, vw, call_inst; callee_opts)   # Bennett-0a6f

    result64 = vw[call_dest]

    if signed
        # Fix sign of result
        if inst.op == :sdiv
            # Result sign = XOR of input signs
            result_sign = allocate!(wa, 1)
            push!(gates, CNOTGate(a_sign[1], result_sign[1]))
            push!(gates, CNOTGate(b_sign[1], result_sign[1]))
            _cond_negate_inplace!(gates, wa, result64, result_sign, 64)
        else  # srem
            # Remainder sign follows dividend
            _cond_negate_inplace!(gates, wa, result64, a_sign, 64)
        end
    end

    # Truncate to W bits.
    # Bennett-gboa / U139 wire-state contract: bits [W+1..64] of `result64`
    # retain the high bits of the soft_udiv output (often non-zero for sdiv
    # where signed-extension produces all-ones high bits). They are NOT
    # zeroed in-flight. Bennett's outer reverse pass uncomputes the soft_udiv
    # inlining at simulate time, restoring all 64 result64 wires to zero.
    # `result` is freshly allocated and only receives the low W bits.
    # If a future liveness pass tries to free `result64` mid-circuit it MUST
    # uncompute the full soft_udiv kernel first — NOT just bits 1..W.
    result = allocate!(wa, W)
    for i in 1:W
        push!(gates, CNOTGate(result64[i], result[i]))
    end
    vw[inst.dest] = result
end

"""
Conditionally negate a value in-place: if cond=1, val = -val (two's complement).

# Wire-state contract (Bennett-gboa / U139)

**Pre:** `val[1:W]` and `cond[1]` hold SSA values; carry wires freshly
allocated (zero by `WireAllocator` invariant).

**Post (pinned by `test_gboa_dirty_bit_hygiene.jl`):**
- `cond[1]` unchanged.
- `val[1:W]` ← `(-val) mod 2^W` if `cond[1] == 1`, else unchanged.
- The W+1 carry wires (`carry` + W `next_carry`) are NOT cleaned up by
  this function; they are uncomputed by Bennett's outer reverse pass
  (gates are self-inverse). See "Wire budget" note below.

# Wire budget — Bennett-3of2 / U112 (investigated, left as-is)

This function allocates W+1 carry wires per call (`carry` + W `next_carry`)
and never `free!`'s them. The wires ARE returned to zero by Bennett's outer
reverse pass at simulate time (gates are self-inverse so the reverse
naturally uncomputes carries) — they just stay allocated, contributing
~3·(W+1) wires per `lower_divrem!` (3 calls per signed div, ~195 wires at
W=64).

A Cuccaro-based rewrite that uses `free!` to return cond_padded wires to
the allocator was investigated and found to break correctness — the freed
wires get reused by `lower_call!`'s soft_udiv inlining, and Bennett's
outer reverse pass operates on the gate sequence assuming wire state at
points in the timeline that no longer match (verify_reversibility passes
because ancilla-zero + input-preservation hold; but the result wires hold
the negation of the expected output). See Bennett-vt0a for the foundational
"Bennett-aware free!" redesign needed to make wire-budget reductions safe
at this layer.

Per measurement, this leak accounts for <0.1% of `sdiv` total wire count
(279,416 wires for Int8 sdiv; this leak contributes ~195). The dominant
source is `soft_udiv` inlining via `lower_call!` (Bennett-3of2 close
note: deferred for that reason).
"""
function _cond_negate_inplace!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                               val::Vector{Int}, cond::Vector{Int}, W::Int)
    # Two's complement negate = flip all bits + add 1
    # Conditional flip: CNOT(cond, val[i]) for each bit
    for i in 1:W
        push!(gates, CNOTGate(cond[1], val[i]))
    end
    # Conditional add 1: ripple carry adding cond[1] to val
    carry = allocate!(wa, 1)
    push!(gates, CNOTGate(cond[1], carry[1]))  # carry starts as cond
    for i in 1:W
        # val[i] += carry; new_carry = val[i] AND carry (before add)
        next_carry = allocate!(wa, 1)
        push!(gates, ToffoliGate(val[i], carry[1], next_carry[1]))
        push!(gates, CNOTGate(carry[1], val[i]))
        carry = next_carry
    end
end

_is_zero_operand(op::IROperand) = op isa ConstOperand && op.value == 0

# Index bits the alloca dispatchers read for an n-element allocation
# (`max(1, ceil(log2 n))`, cf. `_lower_load_via_shadow_checkpoint!`).
_gep_index_bits(n::Int) = max(1, 64 - leading_zeros(UInt64(max(n - 1, 0))))

# Bennett-rrop: width of every composed (runtime) GEP index — a residue mod
# 2^W (see the invariant in `_compose_gep_index!`): one spare bit above the
# dispatchers' index bits. A persistent slab has no `n`; its caller passes the
# pmap key width `_K_bits(impl)` instead (the key the pmap callee reads).
_gep_compose_width(n::Int) = _gep_index_bits(n) + 1

# Bennett-dx9w / Bennett-xjt9: facts about a persistent slab kept in the
# per-function `persistent_info` dict under synthetic keys no IR name takes
# (IR pointer names map to the impl; these map to Ints): the slab's element
# width, and the upper bound of each composed key.
_pslab_ew_key(slab::Symbol) = Symbol("__pslab_ew_", slab)
_pkey_max_key(tag::Symbol) = Symbol("__pkey_max_", tag)

"""
    _pkey_max(persistent_info, vw, op) -> Int128

Bennett-xjt9: upper bound on the signed element address `op` holds on a
persistent slab — a constant's value; a composed key's recorded bound (the sum
of its parts' bounds); a raw IR index's `2^(w-1) - 1` (LLVM sign-extends GEP
indices). A key is the address mod 2^k (k = pmap key width), so it names one
slot exactly when every in-bounds address it can hold is below 2^k.
"""
function _pkey_max(persistent_info, vw::Dict{Symbol,Vector{Int}}, op::IROperand)::Int128
    op isa ConstOperand && return Int128(op.value)
    op isa SSAOperand ||
        throw(ArgumentError("persistent GEP index: unsupported operand kind $(typeof(op)) " *
                            "(Bennett-xjt9)"))
    hi = get(persistent_info, _pkey_max_key(op.name), nothing)
    hi === nothing || return hi
    return (Int128(1) << (length(vw[op.name]) - 1)) - 1
end

"""
    _gep_runtime_shift(gep_ew, ew, dest) -> Int

Bennett-gw0r: a runtime GEP index counts `gep_ew`-bit elements; the origin
alloca counts `ew`-bit elements. The index converts exactly iff `gep_ew` is a
power-of-two multiple of `ew` (shift left by log2 of the ratio). A narrower
GEP element (e.g. a byte GEP on an i16 alloca) would need the runtime index to
be a whole number of alloca elements, which nothing proves — refuse loudly.
"""
function _gep_runtime_shift(gep_ew::Int, ew::Int, dest::Symbol)
    (gep_ew >= ew && gep_ew % ew == 0 && ispow2(gep_ew ÷ ew)) ||
        throw(ArgumentError("GEP %$dest: runtime index over $(gep_ew)-bit elements into an " *
            "alloca of $(ew)-bit elements is not a whole (power-of-two) number of alloca " *
            "elements; the displacement is not representable (Bennett-gw0r)"))
    return trailing_zeros(gep_ew ÷ ew)
end

# Bennett-gw0r / Bennett-rrop: `sext(op) << shift` reduced mod 2^W — the
# operand is sign-extended FIRST (bit k of the result is source bit k-shift,
# clamped to the sign bit), then shifted, then cut to W bits; that is the exact
# residue of LLVM's sign-extended, scaled index for any operand width (wider
# operands are truncated, which is also exact mod 2^W). A runtime operand
# already W bits wide with no shift is used as-is (lower_add! only reads it);
# otherwise fresh wires take CNOT copies.
function _gep_index_wires!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                           vw::Dict{Symbol,Vector{Int}}, op::IROperand, W::Int, shift::Int)
    op isa ConstOperand && return resolve!(gates, wa, vw, iconst(op.value << shift), W)
    src = vw[op.name]
    w = length(src)
    shift == 0 && w == W && return src
    dst = allocate!(wa, W)
    for k in (shift + 1):W
        push!(gates, CNOTGate(src[min(k - shift, w)], dst[k]))
    end
    return dst
end

"""
    _compose_gep_index!(gates, wa, vw, base_idx, delta, n, tag; shift=0, W) -> IROperand

Bennett-jkf0 / Bennett-gw0r: element index of a GEP whose base carries
provenance — `base_idx + (delta << shift)`, both in the origin alloca's
element units (`shift` converts a runtime GEP index whose element is wider
than the alloca's; a constant `delta` is converted by the caller). Every index
operand is a signed two's-complement value (LLVM sign-extends GEP indices).

Constant/zero cases fold with no gates; a zero-base, unshifted runtime index
that already has the `_gep_index_bits(n)` the dispatchers read is passed
through unchanged (alloca-direct GEPs keep their pre-jkf0 operand and gate
count). Otherwise the sum is computed modulo `2^_gep_compose_width(n)` by a
ripple adder under the synthetic name `tag` (invariant and proof at the
width rule below). Pre-gw0r W was the runtime operand's width, truncating
`255 + i` into a 257-element alloca (R3); gw0r's `max(index_bits+1, operand
widths)` re-sign-extended a composed value, which is wrong once a shifted or
summed intermediate leaves the signed range of its width (Bennett-rrop: i4
index 6 scaled ×2 is 12, read back as -4, so `+ (-12)` gave -16, not 0).
"""
function _compose_gep_index!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                             vw::Dict{Symbol,Vector{Int}},
                             base_idx::IROperand, delta::IROperand,
                             n::Union{Nothing,Int}, tag::Symbol; shift::Int=0,
                             W::Int=_gep_compose_width(n))
    (base_idx isa Union{SSAOperand,ConstOperand} && delta isa Union{SSAOperand,ConstOperand}) ||
        throw(ArgumentError("GEP-on-GEP index composition: unsupported operand kinds " *
                            "($(typeof(base_idx)), $(typeof(delta))) (Bennett-jkf0)"))
    if delta isa ConstOperand
        delta = iconst(delta.value << shift)
        shift = 0
    end
    base_idx isa ConstOperand && delta isa ConstOperand &&
        return iconst(base_idx.value + delta.value)
    need = n === nothing ? 0 : _gep_index_bits(n)
    _is_zero_operand(base_idx) && shift == 0 && length(vw[delta.name]) >= need &&
        return delta
    _is_zero_operand(delta) && return base_idx
    # Bennett-rrop — INVARIANT. Let D be the exact element displacement LLVM
    # computes for an origin (B + sum of sext(index_j) * gep_ew_j/ew over the
    # chain; LLVM's own pointer arithmetic is this mod 2^64). Every origin
    # index is one of: (a) a constant equal to D; (b) a raw IR index operand
    # (the passthrough above, or a base kept by a zero delta) whose SIGNED
    # value is D; (c) a composed value of exactly W wires (W fixed per
    # alloca: `_gep_compose_width(n)`, or the pmap key width) holding D mod 2^W. Raw operands narrower than W are only kind (b).
    # PROOF (induction over the chain, any length): constants fold exactly in
    # Int64. Otherwise `_gep_index_wires!` maps each operand to its residue
    # mod 2^W — kind (b): sext/truncate of its signed value; kind (c): already
    # W wires, identity (never re-sign-extended, which was the bug); constant:
    # resolve! masks mod 2^W — and the shift and the W-bit ripple add are ring
    # operations mod 2^W, so the result holds (D_base + D_delta) mod 2^W: kind
    # (c) again, however far an intermediate address strayed. USE: a final
    # D in [0, n) reads as unsigned D from every kind — (b) has a clear sign
    # bit; (c) since D < n <= 2^(W-1) — so the MUX path's zero-extension and
    # the shadow path's low-index_bits read both see D. A constant final stays
    # exact, so the consumers' `0 <= idx < n` check still rejects it. The spare
    # bit keeps every out-of-range (c) final D in [-n, 2n) distinct from all
    # valid slots, so a bounds check on these wires (Bennett-usly) can see it.
    b = _gep_index_wires!(gates, wa, vw, delta, W, shift)
    vw[tag] = _is_zero_operand(base_idx) ? b :
        lower_add!(gates, wa, _gep_index_wires!(gates, wa, vw, base_idx, W, 0), b, W)
    return ssa(tag)
end

"""GEP with constant offset: record that dest points to base + offset_bytes."""
function lower_ptr_offset!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                           vw::Dict{Symbol,Vector{Int}}, inst::IRPtrOffset;
                           ptr_provenance::Union{Nothing,Dict{Symbol,Vector{PtrOrigin}}}=nothing,
                           alloca_info::Union{Nothing,Dict{Symbol,Tuple{Int,Int}}}=nothing,
                           persistent_info::Union{Nothing,Dict{Symbol,Any}}=nothing)
    # Bennett-z2dj T5-P6 / consensus §5 Step 8: persistent-slab early-return.
    # Must come BEFORE the `vw[inst.base.name]` lookup below — persistent slabs
    # *do* have a `vw` entry (the slab wires), but the flat-byte-slice path is
    # wrong for them (the slab is opaque to byte-offset GEPs).
    if persistent_info !== nothing && ptr_provenance !== nothing &&
       haskey(persistent_info, inst.base.name)
        # MVP: const-offset GEPs into a persistent slab are only meaningful for
        # offset 0 (i.e. an alias for the slab itself). Any non-zero offset is
        # operating on slab-internal layout, which the persistent helpers do not
        # model. Refuse loudly; future bead extends this.
        inst.offset_bytes == 0 ||
            throw(ArgumentError("lower_ptr_offset!: non-zero const offset $(inst.offset_bytes)B " *
                "into persistent slab '$(inst.base.name)' is NYI (Bennett-z2dj Step 8 MVP). " *
                "Persistent slabs are opaque to byte-offset GEPs — file a bd issue for " *
                "intra-slab offset support."))
        persistent_info[inst.dest] = persistent_info[inst.base.name]
        base_origins = get(ptr_provenance, inst.base.name, PtrOrigin[])
        isempty(base_origins) &&
            throw(AssertionError("lower_ptr_offset!: persistent base '$(inst.base.name)' " *
                "has no ptr_provenance entry — _lower_alloca_dynamic_n! should have installed one."))
        # Bennett-jkf0: a zero offset is an alias of the base pointer — keep
        # the base's index (pre-fix this reset it to 0, so `p1 + 0` read slot 0).
        new_origins = [PtrOrigin(o.alloca_dest, o.idx_op, o.predicate_wire)
                       for o in base_origins]
        ptr_provenance[inst.dest] = new_origins
        return
    end

    has_prov = _ptr_offset_provenance!(gates, wa, vw, inst, ptr_provenance, alloca_info)

    # Legacy view (pointer params / NTuple inputs): a slice of the base's
    # flat wire array at the byte offset; the legacy IRLoad copies from it.
    # Bennett-jkf0: a provenance-carrying pointer's loads/stores never read
    # this view, so when the base has none (ptr-select/phi results) or the
    # offset leaves it (e.g. a negative offset off a dynamic-GEP snapshot),
    # skip it instead of crashing on the slice.
    bit_offset = inst.offset_bytes * 8
    if haskey(vw, inst.base.name) && 0 <= bit_offset <= length(vw[inst.base.name])
        vw[inst.dest] = vw[inst.base.name][(bit_offset + 1):end]
    elseif !has_prov
        throw(AssertionError("lower_ptr_offset!: GEP base $(inst.base.name) has no pointer " *
            "provenance and no in-range variable wires (offset $(inst.offset_bytes)B)"))
    end
    return nothing
end

"""
Bennett-cc0 M2b / Bennett-jkf0: provenance for a constant-offset GEP. Returns
true iff `ptr_provenance[inst.dest]` was recorded (i.e. the base has
provenance).
"""
function _ptr_offset_provenance!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                  vw::Dict{Symbol,Vector{Int}}, inst::IRPtrOffset,
                                  ptr_provenance, alloca_info)
    # Bennett-cc0 M2b: propagate pointer provenance per-origin. For each
    # origin of the base (typically 1 pre-M2b; >1 after a ptr-phi/select),
    # bump the element index by `offset_bytes / ew_bytes` — i.e. the GEP
    # byte offset is converted to an element-count stride. Preserves the
    # predicate_wire per origin (the GEP is a pure index map, not a
    # control-flow merge).
    #
    # Bennett-ixiz (2026-05-16): the prior `ew == 8 || continue` silent-
    # skip is replaced by per-origin element-stride arithmetic
    # (`div(offset_bytes * 8, ew)`) so arbitrary integer element widths
    # (8/16/32/64) are supported. Sub-element offsets (byte offset not a
    # whole multiple of ew/8) are rejected fail-loud — intra-slot offsets
    # are not representable in the shadow-tape model. The rem-guard is
    # placed PER-ORIGIN because a ptr-phi over allocas of differing
    # element type can have different `alloca_dest`/ew per origin.
    if ptr_provenance !== nothing && alloca_info !== nothing
        base_origins = if haskey(ptr_provenance, inst.base.name)
            ptr_provenance[inst.base.name]
        else
            PtrOrigin[]
        end
        new_origins = PtrOrigin[]
        for (k, o) in enumerate(base_origins)
            # Bennett-jkf0: pre-fix, runtime-index origins (`p = &a[x & 3]`)
            # and unknown allocas were silently skipped (`continue`), so the
            # dest lost its provenance and `load q` copied a pre-store
            # snapshot. Every origin must now carry over or fail loud.
            info = get(alloca_info, o.alloca_dest, nothing)
            info === nothing &&
                throw(AssertionError("lower_ptr_offset!: origin of %$(inst.base.name) points " *
                    "at unknown alloca %$(o.alloca_dest) (Bennett-jkf0)"))
            ew, n = info
            # Bennett-ixiz sub-element guard: a byte offset that doesn't
            # divide the element width cleanly cannot be represented as
            # an element-count bump.
            rem(inst.offset_bytes * 8, ew) == 0 ||
                throw(DimensionMismatch("IRPtrOffset off=$(inst.offset_bytes)B " *
                    "is sub-element on alloca '$(o.alloca_dest)' (elem_w=$ew bits); " *
                    "intra-slot offsets are not representable in the shadow-tape " *
                    "model. Bennett-ixiz."))
            new_idx = _compose_gep_index!(gates, wa, vw, o.idx_op,
                                          iconst(div(inst.offset_bytes * 8, ew)), n,
                                          Symbol("__jkf0_idx_", inst.dest, "_", k))
            push!(new_origins, PtrOrigin(o.alloca_dest, new_idx, o.predicate_wire))
        end
        if !isempty(new_origins)
            ptr_provenance[inst.dest] = new_origins
            return true
        end
    end
    return false
end

"""
Variable-index GEP: MUX-tree selecting one element by runtime index.

The base pointer's wires are a flattened array of N elements of W bits each.
The index selects which W-bit element to produce, via a binary MUX tree
with ceil(log2(N)) levels.

T1c.2: when the base is a compile-time-constant global (present in `globals`),
dispatch to QROM (Babbush-Gidney unary iteration) instead — O(L) Toffolis and
W-independent, vs MUX's O(L·W). See `emit_qrom!`.
"""
function lower_var_gep!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                        vw::Dict{Symbol,Vector{Int}}, inst::IRVarGEP;
                        ptr_provenance::Union{Nothing,Dict{Symbol,Vector{PtrOrigin}}}=nothing,
                        alloca_info::Union{Nothing,Dict{Symbol,Tuple{Int,Int}}}=nothing,
                        globals::Union{Nothing,Dict{Symbol,Tuple{Vector{UInt64},Int}}}=nothing,
                        persistent_info::Union{Nothing,Dict{Symbol,Any}}=nothing)
    # T1c.2: constant global table → QROM
    if globals !== nothing && haskey(globals, inst.base.name)
        data, gw = globals[inst.base.name]
        gw == inst.elem_width ||
            throw(DimensionMismatch("lower_var_gep!: elem_width=$(inst.elem_width) disagrees with global $(inst.base.name) elem_width=$gw"))
        vw[inst.dest] = _emit_qrom_from_gep!(gates, wa, vw, data, inst.index, inst.elem_width)
        return
    end

    # Bennett-z2dj T5-P6 / consensus §5 Step 8: persistent-slab early-return.
    # A GEP off a persistent slab installs provenance pointing at the slab plus
    # the runtime index, and tags `persistent_info[inst.dest]` with the same impl
    # so chained GEPs (rare but possible) carry the tag. The wire-slab indexing
    # below is skipped — the persistent helpers (Step 5) consume the slab wires
    # via `ctx.vw[alloca_dest]` directly and use the per-origin `idx_op` as the
    # pmap_set/get key, so `vw[inst.dest]` must NOT alias a slice of the slab.
    if persistent_info !== nothing && ptr_provenance !== nothing &&
       haskey(persistent_info, inst.base.name)
        persistent_info[inst.dest] = persistent_info[inst.base.name]
        # Carry the base's predicate_wire through. For an alloca-direct base, the
        # base's single PtrOrigin (installed by _lower_alloca_dynamic_n!) supplies
        # the entry predicate.
        base_origins = get(ptr_provenance, inst.base.name, PtrOrigin[])
        if isempty(base_origins)
            throw(AssertionError("lower_var_gep!: persistent base '$(inst.base.name)' " *
                "has no ptr_provenance entry — _lower_alloca_dynamic_n! should have " *
                "installed one. (Bennett-z2dj Step 8)"))
        end
        new_origins = PtrOrigin[]
        for (k, o) in enumerate(base_origins)
            # Bennett-dx9w: the persistent path does no element-unit
            # conversion, so the GEP must step in the slab's own elements
            # (pre-fix an i16 GEP off an i8 slab used key i for byte 2i).
            ew = get(persistent_info, _pslab_ew_key(o.alloca_dest), nothing)
            ew === nothing &&
                throw(AssertionError("lower_var_gep!: persistent slab %$(o.alloca_dest) has no " *
                    "recorded element width (Bennett-dx9w)"))
            inst.elem_width == ew ||
                throw(ArgumentError("GEP %$(inst.dest): $(inst.elem_width)-bit elements into " *
                    "persistent slab %$(o.alloca_dest) of $(ew)-bit elements; the persistent " *
                    "path keys the map by slab element and converts no stride (Bennett-dx9w)"))
            # The slab's "alloca_dest" is itself; the new origin's idx is the
            # base's idx + the GEP's index (Bennett-jkf0: pre-fix it overwrote
            # the base idx, so `&p1[0]` read slot 0); predicate_wire inherited.
            # Bennett-rrop: a composed key is a residue at the pmap key width.
            # Bennett-xjt9: that residue is the address only while the address
            # is < 2^k — record the composed key's upper bound; the load/store
            # (`_check_persistent_key`) refuses a key whose bound reaches 2^k.
            tag = Symbol("__jkf0_idx_", inst.dest, "_", k)
            hi = _pkey_max(persistent_info, vw, o.idx_op) + _pkey_max(persistent_info, vw, inst.index)
            new_idx = _compose_gep_index!(gates, wa, vw, o.idx_op, inst.index, nothing, tag;
                                          W=_K_bits(persistent_info[inst.base.name]))
            new_idx isa SSAOperand && new_idx.name === tag &&
                (persistent_info[_pkey_max_key(tag)] = hi)
            push!(new_origins, PtrOrigin(o.alloca_dest, new_idx, o.predicate_wire))
        end
        ptr_provenance[inst.dest] = new_origins
        return
    end

    # Bennett-dm9r: a constant index is the constant byte offset
    # `index * elem_width/8` — lower it as that `IRPtrOffset` (provenance in
    # alloca-element units, with the sub-element guard, plus the legacy
    # slice). Pre-fix the MUX tree below resolved the constant at width 0 and
    # crashed ("resolve!: width=0"); the extractor emits this node for the
    # two-index array GEP `gep [N x iM], ptr %a, i64 0, i64 K`.
    if inst.index isa ConstOperand
        inst.elem_width % 8 == 0 ||
            throw(ArgumentError("lower_var_gep!: constant-index GEP %$(inst.dest) with " *
                "sub-byte elem_width=$(inst.elem_width) has no byte offset (Bennett-dm9r)"))
        return lower_ptr_offset!(gates, wa, vw,
            IRPtrOffset(inst.dest, inst.base, inst.index.value * (inst.elem_width ÷ 8),
                        inst.elem_width);
            ptr_provenance, alloca_info, persistent_info)
    end

    # Bennett-cc0 M2b: if the base carries provenance, record it per-origin so
    # lower_store!/lower_load! can route through the right callee. Each origin
    # keeps its `predicate_wire`; its index becomes base idx + `inst.index`.
    # Bennett-jkf0: pre-fix only a raw-alloca base was handled (and its idx
    # overwritten), so a GEP off a GEP result had no provenance and its load
    # copied the stale MUX snapshot below.
    if ptr_provenance !== nothing && alloca_info !== nothing &&
       !isempty(get(ptr_provenance, inst.base.name, PtrOrigin[]))
        new_origins = PtrOrigin[]
        for (k, o) in enumerate(ptr_provenance[inst.base.name])
            info = get(alloca_info, o.alloca_dest, nothing)
            info === nothing &&
                throw(AssertionError("lower_var_gep!: origin of %$(inst.base.name) points " *
                    "at unknown alloca %$(o.alloca_dest) (Bennett-jkf0)"))
            # Bennett-gw0r: the base idx counts alloca elements, `inst.index`
            # counts GEP elements — convert before composing, also when the
            # base idx is zero (pre-fix that path recorded the GEP index
            # unconverted: `gep i16, %p0, 1` on an i8 alloca moved one byte).
            ew, n = info
            new_idx = _compose_gep_index!(gates, wa, vw, o.idx_op, inst.index, n,
                                          Symbol("__jkf0_idx_", inst.dest, "_", k);
                                          shift=_gep_runtime_shift(inst.elem_width, ew, inst.dest))
            push!(new_origins, PtrOrigin(o.alloca_dest, new_idx, o.predicate_wire))
        end
        ptr_provenance[inst.dest] = new_origins
        # A GEP-derived base's wires are a snapshot, not the array: the legacy
        # MUX view below would be dead (provenance-routed loads/stores never
        # read it) and may not even be formable. Only raw allocas keep it.
        haskey(alloca_info, inst.base.name) || return nothing
    end

    haskey(vw, inst.base.name) ||
        throw(AssertionError("lower_var_gep!: base $(inst.base.name) not found in variable wires"))
    base_wires = vw[inst.base.name]
    W = inst.elem_width
    N = length(base_wires) ÷ W
    N >= 1 || throw(DimensionMismatch("lower_var_gep!: base has $(length(base_wires)) wires but elem is $W bits"))

    # Resolve index — may be wider than needed (e.g., i64 for a 4-element array)
    idx_wires = resolve!(gates, wa, vw, inst.index, 0)
    idx_bits = max(1, ceil(Int, log2(N)))
    # Bennett-gw0r: an index narrower than the view's MUX levels cannot drive
    # this tree; a provenance-carrying pointer never reads it, so skip it.
    if length(idx_wires) < idx_bits && ptr_provenance !== nothing &&
       haskey(ptr_provenance, inst.dest)
        return nothing
    end

    # Extract element slices
    candidates = [base_wires[((k-1)*W+1):(k*W)] for k in 1:N]

    # Pad to next power of 2 (replicate last element)
    N_padded = 1 << idx_bits
    while length(candidates) < N_padded
        push!(candidates, candidates[end])
    end

    # Binary MUX tree: each level halves the candidates using one index bit
    for level in 0:(idx_bits - 1)
        bit = idx_wires[level + 1]  # LSB first
        next = Vector{Int}[]
        for j in 1:2:length(candidates)
            # bit=0 → candidates[j], bit=1 → candidates[j+1]
            muxed = lower_mux!(gates, wa, [bit], candidates[j+1], candidates[j], W)
            push!(next, muxed)
        end
        candidates = next
    end

    # Store the selected W-bit value — subsequent IRLoad will CNOT-copy from it
    vw[inst.dest] = candidates[1]
end

"""
Provenance-aware lower_load! entry point (T1b.3). If the ptr was produced by
a GEP off a known alloca, route through soft_mux_load_4x8 so we read the
current post-store state rather than a stale slice-alias of vw[ptr].
Otherwise delegate to the legacy load path (pointer parameters, NTuple input).
"""
function lower_load!(ctx::LoweringCtx, inst::IRLoad)
    if inst.ptr isa SSAOperand && haskey(ctx.ptr_provenance, inst.ptr.name)
        origins = ctx.ptr_provenance[inst.ptr.name]
        isempty(origins) &&
            throw(AssertionError("lower_load!: empty origin set for ptr %$(inst.ptr.name)"))
        if length(origins) == 1
            _lower_load_via_mux!(ctx, inst, origins[1])
        else
            _lower_load_multi_origin!(ctx, inst, origins)
        end
    else
        _lower_load_legacy!(ctx.gates, ctx.wa, ctx.vw, inst)
    end
end

"""Bennett-cc0 M2b — multi-origin pointer load. Allocate a fresh W-wire
result (zero by WireAllocator invariant); per origin, emit
`ToffoliGate(origin.predicate_wire, primal[i], result[i])` for each bit.
At runtime exactly one predicate is 1, so exactly one origin XORs its
slot bits into the zero-initialised result — yielding the selected value.
Bennett's reverse pass unwinds symmetrically (Toffoli is self-inverse;
predicate wires are write-once).
"""
function _lower_load_multi_origin!(ctx::LoweringCtx, inst::IRLoad,
                                   origins::Vector{PtrOrigin})
    length(origins) <= 8 ||
        error("_lower_load_multi_origin!: fan-out of $(length(origins)) > 8 " *
              "origins exceeds M2b budget; file a bd issue")
    W = inst.width
    result = allocate!(ctx.wa, W)  # zero by WireAllocator invariant
    for o in origins
        info = get(ctx.alloca_info, o.alloca_dest, nothing)
        info === nothing &&
            throw(AssertionError("_lower_load_multi_origin!: unknown alloca %$(o.alloca_dest)"))
        elem_w, n = info
        W == elem_w ||
            throw(DimensionMismatch("_lower_load_multi_origin!: load width=$W vs origin $(o.alloca_dest) elem_width=$elem_w"))

        if o.idx_op isa ConstOperand
            # Const-idx origin: existing M2b path. Direct Toffoli of the
            # known slot into result, gated by the origin's predicate.
            0 <= o.idx_op.value < n ||
                throw(ArgumentError("_lower_load_multi_origin!: idx=$(o.idx_op.value) out of range [0, $n)"))
            arr_wires = ctx.vw[o.alloca_dest]
            length(arr_wires) == elem_w * n ||
                throw(DimensionMismatch("_lower_load_multi_origin!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)"))
            primal_slot = arr_wires[o.idx_op.value * elem_w + 1 : (o.idx_op.value + 1) * elem_w]
            for i in 1:W
                push!(ctx.gates, ToffoliGate(o.predicate_wire, primal_slot[i], result[i]))
            end
        else
            # Bennett-cb9y (2026-05-01, dnh phase 1b): runtime-idx origin.
            # Synthesise an IRLoad with a fresh dest, route through the
            # single-origin dispatcher (`_lower_load_via_mux!`) which
            # allocates a fresh W-wire group via the soft_mux_load_NxW
            # callee, then Toffoli-merge those wires into `result` gated
            # by the origin's predicate. The synthetic load's ptr is a
            # dummy — `_lower_load_via_mux!` only reads `dest` and `width`
            # from the instruction. Bennett's reverse pass uncomputes the
            # synthetic load's ancillae symmetrically.
            synth_dest = Symbol("__cb9y_load_", o.alloca_dest, "_",
                                _next_mux_tag!(ctx, "mo", o.alloca_dest))
            synth_inst = IRLoad(synth_dest, ssa(o.alloca_dest), W)
            _lower_load_via_mux!(ctx, synth_inst, o)
            value_wires = ctx.vw[synth_dest]
            length(value_wires) == W ||
                throw(AssertionError("_lower_load_multi_origin!: synthetic load produced $(length(value_wires)) wires, expected $W"))
            for i in 1:W
                push!(ctx.gates, ToffoliGate(o.predicate_wire, value_wires[i], result[i]))
            end
        end
    end
    ctx.vw[inst.dest] = result
    return nothing
end

function _lower_load_via_mux!(ctx::LoweringCtx, inst::IRLoad, origin::PtrOrigin)
    alloca_dest = origin.alloca_dest
    idx_op = origin.idx_op

    # Bennett-z2dj T5-P6 / consensus §5 Step 6: persistent-slab early-out.
    # Persistent allocas populate ctx.persistent_info (not ctx.alloca_info)
    # so the ctx.alloca_info[alloca_dest] lookup below would KeyError.
    # Route persistent loads to the dedicated helper which emits an IRCall
    # to impl.pmap_get instead of the MUX-EXCH / shadow paths.
    if haskey(ctx.persistent_info, alloca_dest)
        return _lower_load_via_persistent!(ctx, inst, alloca_dest)
    end

    info = ctx.alloca_info[alloca_dest]

    strategy = _pick_alloca_strategy(info, idx_op)

    if strategy == :shadow
        return _lower_load_via_shadow!(ctx, inst, alloca_dest, info, idx_op)
    elseif strategy == :shadow_checkpoint
        return _lower_load_via_shadow_checkpoint!(ctx, inst, alloca_dest, info, idx_op)
    end
    fn = get(_MUX_EXCH_LOAD_DISPATCH, strategy, nothing)
    fn === nothing &&
        error("_lower_load_via_mux!: unsupported (elem_width=$(info[1]), n_elems=$(info[2])) for dynamic idx")
    return fn(ctx, inst, alloca_dest, info, idx_op)
end

# T3b.3 shadow-memory load for static idx: just CNOT-copy the target slot.
function _lower_load_via_shadow!(ctx::LoweringCtx, inst::IRLoad,
                                  alloca_dest::Symbol, info::Tuple{Int,Int},
                                  idx_op::IROperand)
    elem_w, n = info
    inst.width == elem_w ||
        throw(DimensionMismatch("_lower_load_via_shadow!: load width=$(inst.width) doesn't match elem_width=$elem_w"))
    0 <= idx_op.value < n ||
        throw(ArgumentError("_lower_load_via_shadow!: idx=$(idx_op.value) out of range [0, $n)"))

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        throw(DimensionMismatch("_lower_load_via_shadow!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)"))

    primal_slot = arr_wires[idx_op.value * elem_w + 1 : (idx_op.value + 1) * elem_w]
    ctx.vw[inst.dest] = emit_shadow_load!(ctx.gates, ctx.wa, primal_slot, elem_w)
    return nothing
end

# Bennett-lm3x / U56 (2026-05-01): hand-written `_lower_load_via_mux_4x8!`
# and `_lower_load_via_mux_8x8!` were folded into the @eval loop in
# src/lowering/memory.jl. Their bodies were textually identical to what
# the loop generates; the only "specialness" was that they pre-dated the
# parametric loop by one milestone (M1 vs M2a). Both definitions now come
# from `_MUX_SHAPES_NW` in memory.jl.

"""Legacy direct load worker: CNOT-copy W bits from the wire array.
Called only from `lower_load!(ctx, inst)` when no ptr_provenance entry exists
(pointer parameters, NTuple input). A pointer with no wire binding is an
error (Bennett-sy9t), never a silent skip. Not a public dispatcher."""
function _lower_load_legacy!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                             vw::Dict{Symbol,Vector{Int}}, inst::IRLoad)
    # Bennett-sy9t: a load whose pointer has no wires (no ptr_provenance entry
    # AND no vw binding) is refused — never skipped. The old silent `return`
    # ("may be pgcstack safepoint load") left `vw[dest]` unbound, so a used
    # result failed later as an unrelated undefined-SSA error and a dead one
    # vanished. No allowlist: an empirical sweep (~50 test files incl. memory,
    # sret/tuple, loop, soft-float, GC/heap) never reached this branch — the
    # extractor already drops pgcstack/safepoint traffic before lowering.
    inst.ptr isa SSAOperand ||
        error("_lower_load_legacy!: load into %$(inst.dest) (width $(inst.width)) " *
              "from non-SSA pointer operand $(inst.ptr) — no wires to read " *
              "(Bennett-sy9t: unknown-pointer loads are refused, not skipped)")
    if !haskey(vw, inst.ptr.name)
        error("_lower_load_legacy!: load into %$(inst.dest) (width $(inst.width)) " *
              "from unknown pointer %$(inst.ptr.name) — the pointer has no " *
              "ptr_provenance entry and no wire binding (not an alloca/GEP " *
              "provenance, pointer parameter or NTuple input) " *
              "(Bennett-sy9t: unknown-pointer loads are refused, not skipped)")
    end
    src_wires = vw[inst.ptr.name]
    W = inst.width
    if length(src_wires) < W
        throw(DimensionMismatch("_lower_load_legacy!: load of $W bits from $(inst.ptr.name) but only $(length(src_wires)) wires available"))
    end
    result = allocate!(wa, W)
    for i in 1:W
        push!(gates, CNOTGate(src_wires[i], result[i]))
    end
    vw[inst.dest] = result
end

function lower_extractvalue!(gates, wa, vw, inst::IRExtractValue)
    # Bennett-6bu3: empty field_widths ⇒ HOMOGENEOUS (existing path, byte-
    # identical — total_w = elem_width*n_elems, fixed-width-element offset/width).
    # Non-empty ⇒ STRUCTTYPE — contiguous per-field layout: total = Σ widths,
    # offset = Σ widths[1:index] (0-based running sum), field width = widths[index+1].
    if isempty(inst.field_widths)
        total_w = inst.elem_width * inst.n_elems
        offset = inst.index * inst.elem_width
        w = inst.elem_width
    else
        total_w = sum(inst.field_widths)
        offset = sum(@view inst.field_widths[1:inst.index])  # 0-based index
        w = inst.field_widths[inst.index + 1]
    end
    agg_wires = resolve!(gates, wa, vw, inst.agg, total_w)

    # Select the wires for the requested field — zero gates (wire aliasing)
    result = allocate!(wa, w)
    for i in 1:w
        push!(gates, CNOTGate(agg_wires[offset + i], result[i]))
    end
    vw[inst.dest] = result
end

function lower_insertvalue!(gates, wa, vw, inst::IRInsertValue)
    # Bennett-6bu3: same homogeneous/StructType discriminator as extractvalue.
    if isempty(inst.field_widths)
        total_w = inst.elem_width * inst.n_elems
        iv_offset = inst.index * inst.elem_width  # 0-based index
        w = inst.elem_width
    else
        total_w = sum(inst.field_widths)
        iv_offset = sum(@view inst.field_widths[1:inst.index])  # 0-based index
        w = inst.field_widths[inst.index + 1]
    end
    val_wires = resolve!(gates, wa, vw, inst.val, w)

    # Resolve or create the aggregate
    if inst.agg === ZERO_AGG
        agg_wires = allocate!(wa, total_w)  # all zero already
    else
        agg_wires = resolve!(gates, wa, vw, inst.agg, total_w)
    end

    # Copy aggregate, replacing the field span at `index`
    result = allocate!(wa, total_w)
    for i in 1:total_w
        if i > iv_offset && i <= iv_offset + w
            push!(gates, CNOTGate(val_wires[i - iv_offset], result[i]))
        else
            push!(gates, CNOTGate(agg_wires[i], result[i]))
        end
    end

    vw[inst.dest] = result
end

# Bennett-dv1z: lower an IRInsertBits node — splice a `val_width`-bit value
# into a `total_width`-bit packed aggregate at an arbitrary BIT offset. Same
# gate class as `lower_insertvalue!` (CNOT aliasing into a fresh result group),
# so it introduces NO new gate kinds and cannot perturb the gate-count
# baselines of existing (homogeneous / non-sret) functions, which never emit an
# IRInsertBits. The only difference from IRInsertValue is that the spliced span
# is `(bit_offset, bit_offset+val_width]` (an arbitrary bit window) rather than
# `index * elem_width` (a fixed-width-element slot).
function lower_insertbits!(gates, wa, vw, inst::IRInsertBits)
    val_wires = resolve!(gates, wa, vw, inst.val, inst.val_width)

    # Resolve or create the aggregate. ZERO_AGG ⇒ a fresh all-zero group.
    agg_wires = inst.agg === ZERO_AGG ?
        allocate!(wa, inst.total_width) :
        resolve!(gates, wa, vw, inst.agg, inst.total_width)

    result = allocate!(wa, inst.total_width)
    for i in 1:inst.total_width
        if i > inst.bit_offset && i <= inst.bit_offset + inst.val_width
            push!(gates, CNOTGate(val_wires[i - inst.bit_offset], result[i]))
        else
            push!(gates, CNOTGate(agg_wires[i], result[i]))
        end
    end

    vw[inst.dest] = result
end

