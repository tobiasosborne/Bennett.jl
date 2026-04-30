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
                       a::Vector{Int}, b::Vector{Int}, W::Int)
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
    lower_call!(gates, wa, vw, call_inst)

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

"""GEP with constant offset: record that dest points to base + offset_bytes."""
function lower_ptr_offset!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                           vw::Dict{Symbol,Vector{Int}}, inst::IRPtrOffset;
                           ptr_provenance::Union{Nothing,Dict{Symbol,Vector{PtrOrigin}}}=nothing,
                           alloca_info::Union{Nothing,Dict{Symbol,Tuple{Int,Int}}}=nothing)
    # The base operand should be a flat wire array (from ptr param)
    if !haskey(vw, inst.base.name)
        error("lower_var_gep!: GEP base $(inst.base.name) not found in variable wires")
    end
    base_wires = vw[inst.base.name]
    # PtrOffset just records a view into the base array at byte offset
    # Store as a synthetic entry: (base_wires, byte_offset)
    # For simplicity, slice the wire array
    bit_offset = inst.offset_bytes * 8
    # Store a reference — the IRLoad will do the actual copy
    vw[inst.dest] = base_wires[(bit_offset + 1):end]

    # Bennett-cc0 M2b: propagate pointer provenance per-origin. For each
    # origin of the base (typically 1 pre-M2b; >1 after a ptr-phi/select),
    # bump the element index by offset_bytes (MVP: elem_width = 8). Preserves
    # the predicate_wire per origin — the GEP is a pure index map, not a
    # control-flow merge.
    if ptr_provenance !== nothing && alloca_info !== nothing
        base_origins = if haskey(ptr_provenance, inst.base.name)
            ptr_provenance[inst.base.name]
        else
            PtrOrigin[]
        end
        new_origins = PtrOrigin[]
        for o in base_origins
            o.idx_op.kind == :const || continue  # non-const base idx: skip
            info = get(alloca_info, o.alloca_dest, nothing)
            info === nothing && continue
            ew = first(info)
            ew == 8 || continue  # non-MVP; skip this origin
            new_idx = iconst(o.idx_op.value + inst.offset_bytes)
            push!(new_origins, PtrOrigin(o.alloca_dest, new_idx, o.predicate_wire))
        end
        if !isempty(new_origins)
            ptr_provenance[inst.dest] = new_origins
        end
    end
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
                        globals::Union{Nothing,Dict{Symbol,Tuple{Vector{UInt64},Int}}}=nothing)
    # T1c.2: constant global table → QROM
    if globals !== nothing && haskey(globals, inst.base.name)
        data, gw = globals[inst.base.name]
        gw == inst.elem_width ||
            error("lower_var_gep!: elem_width=$(inst.elem_width) disagrees with global $(inst.base.name) elem_width=$gw")
        vw[inst.dest] = _emit_qrom_from_gep!(gates, wa, vw, data, inst.index, inst.elem_width)
        return
    end

    # Bennett-cc0 M2b: if base is an alloca, record provenance per-origin so
    # lower_store!/lower_load! can route through the right callee. The dynamic
    # index is uniform across origins — each origin gets the same `inst.index`
    # with its existing `predicate_wire`.
    if ptr_provenance !== nothing && alloca_info !== nothing &&
       haskey(alloca_info, inst.base.name)
        # Single-origin producer path — use the entry predicate as the guard.
        # (lower_alloca! already registers this origin; this branch handles
        # the case where the base is a raw alloca reference, not itself an
        # SSA name carrying multi-origin provenance.)
        base_origins = get(ptr_provenance, inst.base.name, PtrOrigin[])
        if !isempty(base_origins)
            new_origins = PtrOrigin[]
            for o in base_origins
                push!(new_origins, PtrOrigin(o.alloca_dest, inst.index, o.predicate_wire))
            end
            ptr_provenance[inst.dest] = new_origins
        end
    end

    haskey(vw, inst.base.name) ||
        error("lower_var_gep!: base $(inst.base.name) not found in variable wires")
    base_wires = vw[inst.base.name]
    W = inst.elem_width
    N = length(base_wires) ÷ W
    N >= 1 || error("lower_var_gep!: base has $(length(base_wires)) wires but elem is $W bits")

    # Resolve index — may be wider than needed (e.g., i64 for a 4-element array)
    idx_wires = resolve!(gates, wa, vw, inst.index, 0)
    idx_bits = max(1, ceil(Int, log2(N)))

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
    if inst.ptr.kind == :ssa && haskey(ctx.ptr_provenance, inst.ptr.name)
        origins = ctx.ptr_provenance[inst.ptr.name]
        isempty(origins) &&
            error("lower_load!: empty origin set for ptr %$(inst.ptr.name)")
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
            error("_lower_load_multi_origin!: unknown alloca %$(o.alloca_dest)")
        elem_w, n = info
        W == elem_w ||
            error("_lower_load_multi_origin!: load width=$W vs origin $(o.alloca_dest) elem_width=$elem_w")
        o.idx_op.kind == :const ||
            error("_lower_load_multi_origin!: multi-origin ptr with dynamic idx is NYI")
        0 <= o.idx_op.value < n ||
            error("_lower_load_multi_origin!: idx=$(o.idx_op.value) out of range [0, $n)")

        arr_wires = ctx.vw[o.alloca_dest]
        length(arr_wires) == elem_w * n ||
            error("_lower_load_multi_origin!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

        primal_slot = arr_wires[o.idx_op.value * elem_w + 1 : (o.idx_op.value + 1) * elem_w]
        for i in 1:W
            push!(ctx.gates, ToffoliGate(o.predicate_wire, primal_slot[i], result[i]))
        end
    end
    ctx.vw[inst.dest] = result
    return nothing
end

function _lower_load_via_mux!(ctx::LoweringCtx, inst::IRLoad, origin::PtrOrigin)
    alloca_dest = origin.alloca_dest
    idx_op = origin.idx_op
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
        error("_lower_load_via_shadow!: load width=$(inst.width) doesn't match elem_width=$elem_w")
    0 <= idx_op.value < n ||
        error("_lower_load_via_shadow!: idx=$(idx_op.value) out of range [0, $n)")

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        error("_lower_load_via_shadow!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

    primal_slot = arr_wires[idx_op.value * elem_w + 1 : (idx_op.value + 1) * elem_w]
    ctx.vw[inst.dest] = emit_shadow_load!(ctx.gates, ctx.wa, primal_slot, elem_w)
    return nothing
end

function _lower_load_via_mux_4x8!(ctx::LoweringCtx, inst::IRLoad,
                                   alloca_dest::Symbol, info::Tuple{Int,Int},
                                   idx_op::IROperand)
    inst.width == 8 ||
        error("_lower_load_via_mux_4x8!: load width must be 8, got $(inst.width)")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == 32 ||
        error("_lower_load_via_mux_4x8!: expected 32-wire packed array at alloca $alloca_dest; got $(length(arr_wires))")

    tag = _next_mux_tag!(ctx, "ld", inst.dest)
    arr_sym = Symbol("__mux_load_arr_", tag)
    idx_sym = Symbol("__mux_load_idx_", tag)
    tmp_sym = Symbol("__mux_load_u64_", tag)

    ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
    ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)

    call = IRCall(tmp_sym, soft_mux_load_4x8,
                  [ssa(arr_sym), ssa(idx_sym)], [64, 64], 64)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[inst.dest] = ctx.vw[tmp_sym][1:8]
    return nothing
end

function _lower_load_via_mux_8x8!(ctx::LoweringCtx, inst::IRLoad,
                                   alloca_dest::Symbol, info::Tuple{Int,Int},
                                   idx_op::IROperand)
    inst.width == 8 ||
        error("_lower_load_via_mux_8x8!: load width must be 8, got $(inst.width)")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == 64 ||
        error("_lower_load_via_mux_8x8!: expected 64-wire packed array at alloca $alloca_dest")

    tag = _next_mux_tag!(ctx, "ld", inst.dest)
    arr_sym = Symbol("__mux_load_arr_", tag)
    idx_sym = Symbol("__mux_load_idx_", tag)
    tmp_sym = Symbol("__mux_load_u64_", tag)

    ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
    ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)

    call = IRCall(tmp_sym, soft_mux_load_8x8,
                  [ssa(arr_sym), ssa(idx_sym)], [64, 64], 64)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[inst.dest] = ctx.vw[tmp_sym][1:8]
    return nothing
end

"""Legacy direct load worker: CNOT-copy W bits from the wire array.
Called only from `lower_load!(ctx, inst)` when no ptr_provenance entry exists
(pointer parameters, NTuple input). Not a public dispatcher."""
function _lower_load_legacy!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                             vw::Dict{Symbol,Vector{Int}}, inst::IRLoad)
    if !haskey(vw, inst.ptr.name)
        # Load from unknown pointer — skip (may be pgcstack safepoint load)
        return
    end
    src_wires = vw[inst.ptr.name]
    W = inst.width
    if length(src_wires) < W
        error("_lower_load_legacy!: load of $W bits from $(inst.ptr.name) but only $(length(src_wires)) wires available")
    end
    result = allocate!(wa, W)
    for i in 1:W
        push!(gates, CNOTGate(src_wires[i], result[i]))
    end
    vw[inst.dest] = result
end

function lower_extractvalue!(gates, wa, vw, inst::IRExtractValue)
    total_w = inst.elem_width * inst.n_elems
    agg_wires = resolve!(gates, wa, vw, inst.agg, total_w)

    # Select the wires for the requested element — zero gates (wire aliasing)
    offset = inst.index * inst.elem_width
    result = allocate!(wa, inst.elem_width)
    for i in 1:inst.elem_width
        push!(gates, CNOTGate(agg_wires[offset + i], result[i]))
    end
    vw[inst.dest] = result
end

function lower_insertvalue!(gates, wa, vw, inst::IRInsertValue)
    total_w = inst.elem_width * inst.n_elems
    val_wires = resolve!(gates, wa, vw, inst.val, inst.elem_width)

    # Resolve or create the aggregate
    if inst.agg.kind == :const && inst.agg.name == :__zero_agg__
        agg_wires = allocate!(wa, total_w)  # all zero already
    else
        agg_wires = resolve!(gates, wa, vw, inst.agg, total_w)
    end

    # Copy aggregate, replacing element at `index`
    result = allocate!(wa, total_w)
    iv_offset = inst.index * inst.elem_width  # 0-based index
    for i in 1:total_w
        if i > iv_offset && i <= iv_offset + inst.elem_width
            push!(gates, CNOTGate(val_wires[i - iv_offset], result[i]))
        else
            push!(gates, CNOTGate(agg_wires[i], result[i]))
        end
    end

    vw[inst.dest] = result
end

