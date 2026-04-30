# ---- T1b.3: reversible mutable memory (store/alloca) ----

"""
    lower_alloca!(ctx, inst::IRAlloca)

Allocate the wire range for a fresh reversible array and record it in the
per-compilation alloca_info + ptr_provenance maps. No gates are emitted —
fresh wires are zero by WireAllocator invariant.

MVP: only (elem_width=8, n_elems=iconst(4)) is accepted. Anything else errors
loudly; T1b.5 adds wider shapes.
"""
function lower_alloca!(ctx::LoweringCtx, inst::IRAlloca)
    inst.n_elems.kind == :const ||
        error("lower_alloca!: dynamic n_elems not supported (%$(inst.n_elems.name)); " *
              "T3b.3 shadow memory handles static-sized allocas only.")
    n = inst.n_elems.value
    n >= 1 || error("lower_alloca!: non-positive n_elems=$n")
    inst.elem_width >= 1 || error("lower_alloca!: non-positive elem_width=$(inst.elem_width)")

    total_bits = inst.elem_width * n
    wires = allocate!(ctx.wa, total_bits)       # zero by invariant
    ctx.vw[inst.dest] = wires
    ctx.alloca_info[inst.dest] = (inst.elem_width, n)
    # Bennett-cc0 M2b: single-origin provenance with the entry predicate as
    # the guard wire. The trivial "always-1" entry predicate lets downstream
    # multi-origin merges (lower_phi!/lower_select!) AND edge predicates with
    # the origin's guard uniformly, and keeps the single-origin fast path
    # byte-identical to pre-M2b (the entry predicate is always 1 at runtime).
    ctx.ptr_provenance[inst.dest] = [PtrOrigin(inst.dest, iconst(0),
                                               _entry_predicate_wire(ctx))]
    return nothing
end

"""Return the entry-block's single-wire path predicate (always 1).

Every `lower()` run installs a `NOTGate(pw[1])` on a fresh wire in the
entry block, so `ctx.block_pred[ctx.entry_label]` is a 1-vector whose only
wire is 1 at runtime. This is the default `predicate_wire` for single-
origin `PtrOrigin`s (alloca, GEP of known alloca): it satisfies the
multi-origin type shape without actually emitting a guard.

Fail-fast if called with the sentinel `entry_label = Symbol("")` (direct
`lower_block_insts!` callers that didn't go through `lower()`). In that
case the caller should supply the predicate explicitly.
"""
function _entry_predicate_wire(ctx::LoweringCtx)
    ctx.entry_label == Symbol("") &&
        error("_entry_predicate_wire: ctx has sentinel entry_label; direct " *
              "lower_block_insts! callers must either set entry_label or " *
              "bypass ptr_provenance usage")
    pw = get(ctx.block_pred, ctx.entry_label, Int[])
    length(pw) == 1 ||
        error("_entry_predicate_wire: expected single-wire predicate for " *
              "entry block $(ctx.entry_label), got $(length(pw)) wires")
    return pw[1]
end

"""
    _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand) -> Symbol

T3b.3 universal dispatcher: select the cheapest correct lowering for a
store/load into an alloca-backed region, given the (elem_width, n_elems)
shape and the runtime index operand.

Strategies:
  :shadow            — static idx (const), any shape. Cheap direct CNOT pattern.
  :mux_exch_NxW      — dynamic idx. N·W ≤ 64 (single-UInt64 packed).
                       M1: N ∈ {2,4,8}×W=8, N ∈ {2,4}×W=16, N=2×W=32.
  :shadow_checkpoint — Bennett-cc0 M3a (Bennett-jqyt) T4 MVP fallback.
                       Dynamic idx on ANY shape with N·W > 64. Fans out
                       N per-slot idx-equality-guarded shadow stores /
                       per-slot Toffoli-copy loads. Gate cost is O(N·W)
                       per op — universal correctness, not optimised.
  :unsupported       — dynamic idx on any shape that doesn't match the
                       above (currently none: T4 catches N·W > 64).
                       Reserved for future additions.

Priority rule: static idx ALWAYS dispatches to :shadow. MUX EXCH is
preferred for shapes with N·W ≤ 64 (cheaper per-op cost). T4 shadow-
checkpoint is the universal fallback for N·W > 64.
"""
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand)
    idx.kind == :const && return :shadow
    sym = get(_MUX_EXCH_STRATEGY, shape, nothing)
    sym === nothing || return sym
    # Bennett-cc0 M3a — T4 shadow-checkpoint MVP. Triggers for ANY shape
    # where the packed bits exceed a single UInt64, which is the only
    # shape class no MUX EXCH callee covers. Strictly additive — shapes
    # already returning :shadow or :mux_exch_* above are unaffected.
    elem_w, n = shape
    n * elem_w > 64 && return :shadow_checkpoint
    return :unsupported
end

"""
    lower_store!(ctx, inst::IRStore)

Reversible write: dispatch to `soft_mux_store_4x8` via IRCall. The callee is
64-bit; we zero-extend the 32-bit packed array, idx, and val to 64 wires.
After the call, `vw[alloca_dest]` is rebound to the low 32 wires of the
callee's output — subsequent loads see the post-store state.

MVP: ptr must resolve via ptr_provenance to a (4, 8) alloca. Store width must
be 8. All other cases error loudly.
"""
function lower_store!(ctx::LoweringCtx, inst::IRStore, block_label::Symbol=Symbol(""))
    inst.ptr.kind == :ssa ||
        error("lower_store!: store to a constant pointer is not supported")

    haskey(ctx.ptr_provenance, inst.ptr.name) ||
        error("lower_store!: no provenance for ptr %$(inst.ptr.name); " *
              "store must target an alloca or GEP thereof")
    origins = ctx.ptr_provenance[inst.ptr.name]
    isempty(origins) &&
        error("lower_store!: empty origin set for ptr %$(inst.ptr.name)")

    # Bennett-cc0 M2b: single-origin fast path preserves every BENCHMARKS.md
    # baseline. Multi-origin (pointer phi/select) fans out to N guarded shadow
    # stores, one per origin, keyed on its path-predicate wire.
    if length(origins) == 1
        return _lower_store_single_origin!(ctx, inst, origins[1], block_label)
    end

    # Multi-origin fan-out. Each origin writes into its own alloca slot under
    # its own path-predicate guard. At runtime exactly one predicate is true
    # (mutual exclusion is guaranteed by the producer: ptr-phi/ptr-select
    # compose edge predicates that are pairwise-exclusive by construction).
    length(origins) <= 8 ||
        error("lower_store!: multi-origin fan-out of $(length(origins)) > 8 " *
              "origins exceeds M2b budget; file a bd issue for MUX-tree " *
              "collapse of deep ptr-phi chains")
    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, inst.width)
    for o in origins
        info = get(ctx.alloca_info, o.alloca_dest, nothing)
        info === nothing &&
            error("lower_store!: multi-origin ptr references unknown alloca %$(o.alloca_dest)")
        strategy = _pick_alloca_strategy(info, o.idx_op)
        strategy == :shadow ||
            error("lower_store!: multi-origin ptr with dynamic idx (origin=$(o.alloca_dest), " *
                  "strategy=$strategy) is NYI; file follow-up bd issue for multi-origin MUX EXCH")
        _emit_store_via_shadow_guarded!(ctx, inst, o.alloca_dest, info, o.idx_op,
                                        o.predicate_wire, val_wires)
    end
    return nothing
end

"""Single-origin store dispatch (Bennett-cc0 M2b). Pulled out of the old
`lower_store!` body so the fast path stays byte-identical to pre-M2b."""
function _lower_store_single_origin!(ctx::LoweringCtx, inst::IRStore,
                                     origin::PtrOrigin, block_label::Symbol)
    alloca_dest = origin.alloca_dest
    idx_op = origin.idx_op
    info = get(ctx.alloca_info, alloca_dest, nothing)
    info === nothing &&
        error("lower_store!: provenance points to unknown alloca %$alloca_dest")

    strategy = _pick_alloca_strategy(info, idx_op)

    if strategy == :shadow
        _lower_store_via_shadow!(ctx, inst, alloca_dest, info, idx_op, block_label)
    elseif strategy == :shadow_checkpoint
        _lower_store_via_shadow_checkpoint!(ctx, inst, alloca_dest, info, idx_op, block_label)
    else
        fn = get(_MUX_EXCH_STORE_DISPATCH, strategy, nothing)
        fn === nothing &&
            error("lower_store!: unsupported (elem_width=$(info[1]), n_elems=$(info[2])) for dynamic idx")
        fn(ctx, inst, alloca_dest, idx_op; block_label=block_label)
    end
    return nothing
end

"""Bennett-cc0 M2b — emit a guarded shadow store for one origin of a
multi-origin pointer. `pred_wire` is the origin's path predicate; at
runtime exactly one origin's predicate is 1, so exactly one primal slot
receives the value.

`val_wires` must be the pre-resolved value wires — passed in so the fan-out
shares one resolution across all origins (avoids re-allocating the value
wire per origin).
"""
function _emit_store_via_shadow_guarded!(ctx::LoweringCtx, inst::IRStore,
                                         alloca_dest::Symbol, info::Tuple{Int,Int},
                                         idx_op::IROperand, pred_wire::Int,
                                         val_wires::Vector{Int})
    elem_w, n = info
    inst.width == elem_w ||
        error("_emit_store_via_shadow_guarded!: store width=$(inst.width) doesn't match alloca elem_width=$elem_w")
    idx_op.kind == :const ||
        error("_emit_store_via_shadow_guarded!: non-const idx not supported in multi-origin path")
    0 <= idx_op.value < n ||
        error("_emit_store_via_shadow_guarded!: idx=$(idx_op.value) out of range [0, $n)")

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        error("_emit_store_via_shadow_guarded!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

    primal_slot = arr_wires[idx_op.value * elem_w + 1 : (idx_op.value + 1) * elem_w]
    tape = allocate!(ctx.wa, elem_w)
    emit_shadow_store_guarded!(ctx.gates, ctx.wa, primal_slot, tape, val_wires,
                               elem_w, pred_wire)
    return nothing
end

# T3b.3 shadow-memory store: idx is compile-time constant, so we touch only
# the W wires of the target slot directly.
#
# Gate cost depends on block_label:
#   - Entry block (unconditional): 3W CNOT, 0 Toffoli — via emit_shadow_store!
#   - Any other block: 3W Toffoli gated by block predicate — via
#     emit_shadow_store_guarded!  (Bennett-cc0 M2c / Bennett-oio4)
#
# The entry-block fast path preserves all existing BENCHMARKS.md gate counts
# while fixing the conditional-store semantic bug. Sentinel Symbol("") matches
# no block → treats as entry (backward-compat for direct lower_store! callers).
function _lower_store_via_shadow!(ctx::LoweringCtx, inst::IRStore,
                                  alloca_dest::Symbol, info::Tuple{Int,Int},
                                  idx_op::IROperand, block_label::Symbol=Symbol(""))
    elem_w, n = info
    inst.width == elem_w ||
        error("_lower_store_via_shadow!: store width=$(inst.width) doesn't match alloca elem_width=$elem_w")
    0 <= idx_op.value < n ||
        error("_lower_store_via_shadow!: idx=$(idx_op.value) out of range [0, $n)")

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        error("_lower_store_via_shadow!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

    primal_slot = arr_wires[idx_op.value * elem_w + 1 : (idx_op.value + 1) * elem_w]
    tape = allocate!(ctx.wa, elem_w)
    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, elem_w)

    # M2c guard: store is unconditional iff we're in the entry block (or the
    # sentinel Symbol("") signals "no gating info"). Otherwise gate on block
    # predicate. Assumes single-wire predicates; multi-wire would need
    # AND-reduction first (not currently produced by _compute_block_pred!).
    if block_label == Symbol("") || block_label == ctx.entry_label
        emit_shadow_store!(ctx.gates, ctx.wa, primal_slot, tape, val_wires, elem_w)
    else
        pred_wires = get(ctx.block_pred, block_label, Int[])
        length(pred_wires) == 1 ||
            error("_lower_store_via_shadow!: expected single-wire predicate for block $block_label, got $(length(pred_wires)) wires")
        emit_shadow_store_guarded!(ctx.gates, ctx.wa, primal_slot, tape, val_wires, elem_w, pred_wires[1])
    end
    return nothing
end

# Bennett-cc0 M3a (Bennett-jqyt) — T4 shadow-checkpoint helpers.
#
# The MVP universal fallback for dynamic-idx store/load when no MUX EXCH
# callee covers the shape (N·W > 64). Follows `docs/memory/shadow_design.md`
# §4.2 "shadow tape = one slot per dynamic store".
#
# Contract:
# - Store: allocate a fresh W-wire tape slot PER possible target slot k ∈ 0:n-1.
#   Emit a guarded shadow-store into primal[k*W+1:(k+1)*W] with guard =
#   (block_pred & idx == k). At runtime exactly one k matches so exactly
#   one primal slot is mutated; all other tape slots remain zero (the
#   Toffoli with guard=0 is a no-op).
# - Load: allocate a fresh W-wire result (zero by invariant), then for each
#   slot k emit Toffoli(idx_eq_k, primal[k*W+i], result[i]) per bit. Exactly
#   one slot XORs its value into result.
# - Bennett's reverse unwinds every CNOT/Toffoli self-inversely — tape
#   slots return to zero, primal returns to pre-store state.
#
# Gate cost: O(N·W) Toffolis per store/load (not competitive with MUX EXCH
# for small N·W; universal for large N·W).

"""
    _emit_idx_eq_const!(ctx, idx_wires, idx_bits, k) -> Int

Synthesise a single 1-bit wire holding `(idx == k)` at runtime. The
returned wire is freshly allocated via `ctx.wa` (zero-initialised, then
raised to 1 via an AND-tree over the matched idx bits).

`idx_wires` is the raw wire vector (LSB first). `idx_bits` is the number
of low bits to match (bits above `idx_bits` are assumed zero — i.e. the
idx was produced by `zext i8 %i to i32` on an `n_elems ≤ 2^idx_bits`
array). `k` is the constant slot index ∈ 0:(2^idx_bits - 1).

Implementation: build a vector of "bit-match" wires (one per idx bit),
where bit i is `idx_wires[i+1]` if `(k>>i)&1 == 1` else `NOT(idx_wires[i+1])`.
AND-reduce them into a single output wire via Toffoli tree. Total cost:
`idx_bits - 1` Toffolis + up to `idx_bits` NOT-wire allocations per call.
"""
function _emit_idx_eq_const!(ctx::LoweringCtx, idx_wires::Vector{Int},
                             idx_bits::Int, k::Int)::Int
    idx_bits >= 1 || error("_emit_idx_eq_const!: idx_bits must be >= 1, got $idx_bits")
    length(idx_wires) >= idx_bits ||
        error("_emit_idx_eq_const!: idx_wires has $(length(idx_wires)) < idx_bits=$idx_bits")

    # Build one bit-match wire per idx bit. If k's bit is 1: use idx_wires[i]
    # directly. If 0: use NOT(idx_wires[i]) on a fresh wire.
    bit_matches = Int[]
    for i in 0:(idx_bits - 1)
        want = (k >> i) & 1
        if want == 1
            push!(bit_matches, idx_wires[i + 1])
        else
            not_w = _not_wire!(ctx.gates, ctx.wa, [idx_wires[i + 1]])
            push!(bit_matches, not_w[1])
        end
    end

    # AND-reduce to single output wire.
    if length(bit_matches) == 1
        # Single idx bit; return the bit-match directly. Note: the caller
        # must not mutate the returned wire (it may alias idx_wires).
        return bit_matches[1]
    end

    # Iterative AND-tree: fold pairwise into fresh output wires.
    acc = _and_wire!(ctx.gates, ctx.wa, [bit_matches[1]], [bit_matches[2]])
    for i in 3:length(bit_matches)
        acc = _and_wire!(ctx.gates, ctx.wa, acc, [bit_matches[i]])
    end
    return acc[1]
end

"""
    _lower_store_via_shadow_checkpoint!(ctx, inst, alloca_dest, info, idx_op, block_label)

Bennett-cc0 M3a T4 MVP — dynamic-idx store into an alloca of shape
`(elem_w, n)` where `n·elem_w > 64` (no MUX EXCH callee available).
Fans out into `n` guarded shadow stores, each keyed on an idx-equality
predicate. If `block_label` is a non-entry block, ANDs the eq_wire with
the block path predicate (critical for false-path sensitisation;
CLAUDE.md §"Phi Resolution and Control Flow — CORRECTNESS RISK").

Per-slot cost: 1 idx-eq AND-tree (≤ idx_bits - 1 Toffolis, plus NOTs),
optional 1 Toffoli to AND with block_pred, and 3W Toffolis for the
guarded shadow store itself.
"""
function _lower_store_via_shadow_checkpoint!(ctx::LoweringCtx, inst::IRStore,
                                             alloca_dest::Symbol, info::Tuple{Int,Int},
                                             idx_op::IROperand, block_label::Symbol)
    elem_w, n = info
    inst.width == elem_w ||
        error("_lower_store_via_shadow_checkpoint!: store width=$(inst.width) doesn't match alloca elem_width=$elem_w")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        error("_lower_store_via_shadow_checkpoint!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, elem_w)
    # resolve! with width=0 returns the existing SSA wires (may be wider than
    # log2(n)). We only care about the low idx_bits — upper bits are assumed
    # zero by construction (e.g. zext from i8 to i32 for an n=256 array).
    idx_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, idx_op, 0)
    idx_bits = max(1, ceil(Int, log2(n)))
    length(idx_wires) >= idx_bits ||
        error("_lower_store_via_shadow_checkpoint!: idx SSA has $(length(idx_wires)) wires, need at least $idx_bits")

    # Determine the block guard. Entry-block stores (or the sentinel
    # Symbol("")) skip the block-pred AND — the eq_wire itself is the guard.
    # Non-entry blocks AND the block's 1-wire path predicate with each
    # per-slot eq_wire.
    use_block_guard = !(block_label == Symbol("") || block_label == ctx.entry_label)
    block_pred_wire = if use_block_guard
        pw = get(ctx.block_pred, block_label, Int[])
        length(pw) == 1 ||
            error("_lower_store_via_shadow_checkpoint!: expected single-wire predicate for block $block_label, got $(length(pw)) wires")
        pw[1]
    else
        0  # unused
    end

    for k in 0:(n - 1)
        eq_wire = _emit_idx_eq_const!(ctx, idx_wires, idx_bits, k)
        guard_w = if use_block_guard
            _and_wire!(ctx.gates, ctx.wa, [block_pred_wire], [eq_wire])[1]
        else
            eq_wire
        end
        primal_slot = arr_wires[k * elem_w + 1 : (k + 1) * elem_w]
        tape = allocate!(ctx.wa, elem_w)
        emit_shadow_store_guarded!(ctx.gates, ctx.wa, primal_slot, tape,
                                   val_wires, elem_w, guard_w)
    end
    return nothing
end

"""
    _lower_load_via_shadow_checkpoint!(ctx, inst, alloca_dest, info, idx_op)

Bennett-cc0 M3a T4 MVP — dynamic-idx load from an alloca of shape
`(elem_w, n)` where `n·elem_w > 64`. Mirrors `_lower_load_multi_origin!`
but fans out over the element axis instead of multiple origins. Allocates
a fresh W-wire result (zero by WireAllocator invariant) and for each slot
emits `Toffoli(idx_eq_k, primal[k][i], result[i])` per bit.

Load is always unconditional w.r.t. block predicate — a load outside its
dominating branch would be undefined behaviour in source, so we don't
need a block guard here. (The store's block guard takes care of the
false-path-sensitisation concern.)
"""
function _lower_load_via_shadow_checkpoint!(ctx::LoweringCtx, inst::IRLoad,
                                            alloca_dest::Symbol, info::Tuple{Int,Int},
                                            idx_op::IROperand)
    elem_w, n = info
    W = inst.width
    W == elem_w ||
        error("_lower_load_via_shadow_checkpoint!: load width=$W doesn't match alloca elem_width=$elem_w")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        error("_lower_load_via_shadow_checkpoint!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)")

    idx_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, idx_op, 0)
    idx_bits = max(1, ceil(Int, log2(n)))
    length(idx_wires) >= idx_bits ||
        error("_lower_load_via_shadow_checkpoint!: idx SSA has $(length(idx_wires)) wires, need at least $idx_bits")

    result = allocate!(ctx.wa, W)  # zero by WireAllocator invariant
    for k in 0:(n - 1)
        eq_wire = _emit_idx_eq_const!(ctx, idx_wires, idx_bits, k)
        primal_slot = arr_wires[k * elem_w + 1 : (k + 1) * elem_w]
        for i in 1:W
            push!(ctx.gates, ToffoliGate(eq_wire, primal_slot[i], result[i]))
        end
    end
    ctx.vw[inst.dest] = result
    return nothing
end

# Bennett-cc0 M2d: MUX-store dispatch is guarded when the store lives in a
# non-entry block. `block_label == ctx.entry_label` (or the sentinel
# Symbol("")) routes to the unguarded soft_mux_store_NxW callee — entry-block
# stores therefore keep the byte-identical BENCHMARKS.md gate counts. Any
# other block promotes the 1-wire block predicate into a 64-wire operand and
# calls soft_mux_store_guarded_NxW, folding `pred` into the per-slot
# `ifelse` cond. When `pred == 0` every slot returns OLD → `arr` unchanged.
function _lower_store_via_mux_4x8!(ctx::LoweringCtx, inst::IRStore,
                                   alloca_dest::Symbol, idx_op::IROperand;
                                   block_label::Symbol=Symbol(""))
    inst.width == 8 ||
        error("_lower_store_via_mux_4x8!: store width must be 8, got $(inst.width)")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == 32 ||
        error("_lower_store_via_mux_4x8!: expected 32-wire packed array")

    tag = _next_mux_tag!(ctx, "st", inst.ptr.name)
    arr_sym = Symbol("__mux_store_arr_", tag)
    idx_sym = Symbol("__mux_store_idx_", tag)
    val_sym = Symbol("__mux_store_val_", tag)
    res_sym = Symbol("__mux_store_res_", tag)

    ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
    ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)
    ctx.vw[val_sym] = _operand_to_u64!(ctx, inst.val)

    if block_label == Symbol("") || block_label == ctx.entry_label
        call = IRCall(res_sym, soft_mux_store_4x8,
                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
    else
        pred_sym = _mux_store_pred_sym!(ctx, block_label, tag,
                                        "_lower_store_via_mux_4x8!")
        call = IRCall(res_sym, soft_mux_store_guarded_4x8,
                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
                      [64, 64, 64, 64], 64)
    end
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[alloca_dest] = ctx.vw[res_sym][1:32]
    return nothing
end

function _lower_store_via_mux_8x8!(ctx::LoweringCtx, inst::IRStore,
                                   alloca_dest::Symbol, idx_op::IROperand;
                                   block_label::Symbol=Symbol(""))
    inst.width == 8 ||
        error("_lower_store_via_mux_8x8!: store width must be 8, got $(inst.width)")
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == 64 ||
        error("_lower_store_via_mux_8x8!: expected 64-wire packed array")

    tag = _next_mux_tag!(ctx, "st", inst.ptr.name)
    arr_sym = Symbol("__mux_store_arr_", tag)
    idx_sym = Symbol("__mux_store_idx_", tag)
    val_sym = Symbol("__mux_store_val_", tag)
    res_sym = Symbol("__mux_store_res_", tag)

    ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
    ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)
    ctx.vw[val_sym] = _operand_to_u64!(ctx, inst.val)

    if block_label == Symbol("") || block_label == ctx.entry_label
        call = IRCall(res_sym, soft_mux_store_8x8,
                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
    else
        pred_sym = _mux_store_pred_sym!(ctx, block_label, tag,
                                        "_lower_store_via_mux_8x8!")
        call = IRCall(res_sym, soft_mux_store_guarded_8x8,
                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
                      [64, 64, 64, 64], 64)
    end
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[alloca_dest] = ctx.vw[res_sym]
    return nothing
end

# M1 — Bennett-cc0 parametric MUX EXCH helpers.
# Generated via @eval over the shape list. Each (N, W) pair produces a
# _lower_load_via_mux_NxW! and a _lower_store_via_mux_NxW!, both following
# the same structure as the hand-written (4,8)/(8,8) variants: validate
# width + packed-array size, pack operands into UInt64, emit IRCall to the
# matching soft_mux_*_NxW callee, slice the low N·W bits back into the
# primal wire list.
for (N, W) in [(2, 8), (2, 16), (4, 16), (2, 32)]
    @assert N * W <= 64 "shape ($N, $W) exceeds UInt64 packing"
    load_fn           = Symbol(:_lower_load_via_mux_, N, :x, W, :!)
    store_fn          = Symbol(:_lower_store_via_mux_, N, :x, W, :!)
    soft_load         = Symbol(:soft_mux_load_, N, :x, W)
    soft_store        = Symbol(:soft_mux_store_, N, :x, W)
    soft_store_guard  = Symbol(:soft_mux_store_guarded_, N, :x, W)
    packed_bits = N * W
    name_tag = string(N, "x", W)

    @eval begin
        function $load_fn(ctx::LoweringCtx, inst::IRLoad,
                          alloca_dest::Symbol, info::Tuple{Int,Int},
                          idx_op::IROperand)
            inst.width == $W ||
                error($("_lower_load_via_mux_$(name_tag)!: load width must be $W, got "), inst.width)
            arr_wires = ctx.vw[alloca_dest]
            length(arr_wires) == $packed_bits ||
                error($("_lower_load_via_mux_$(name_tag)!: expected $(packed_bits)-wire packed array at alloca "),
                      alloca_dest, "; got ", length(arr_wires))

            tag = _next_mux_tag!(ctx, "ld", inst.dest)
            arr_sym = Symbol("__mux_load_arr_", tag)
            idx_sym = Symbol("__mux_load_idx_", tag)
            tmp_sym = Symbol("__mux_load_u64_", tag)

            ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
            ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)

            call = IRCall(tmp_sym, $soft_load,
                          [ssa(arr_sym), ssa(idx_sym)], [64, 64], 64)
            lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

            ctx.vw[inst.dest] = ctx.vw[tmp_sym][1:$W]
            return nothing
        end

        # Bennett-cc0 M2d: same block_label-dispatch pattern as the hand-written
        # (4,8)/(8,8) helpers. Entry-block → unguarded callee, byte-identical to
        # pre-M2d. Any other block → guarded callee with block-predicate folded
        # into the per-slot ifelse cond.
        function $store_fn(ctx::LoweringCtx, inst::IRStore,
                           alloca_dest::Symbol, idx_op::IROperand;
                           block_label::Symbol=Symbol(""))
            inst.width == $W ||
                error($("_lower_store_via_mux_$(name_tag)!: store width must be $W, got "), inst.width)
            arr_wires = ctx.vw[alloca_dest]
            length(arr_wires) == $packed_bits ||
                error($("_lower_store_via_mux_$(name_tag)!: expected $(packed_bits)-wire packed array"))

            tag = _next_mux_tag!(ctx, "st", inst.ptr.name)
            arr_sym = Symbol("__mux_store_arr_", tag)
            idx_sym = Symbol("__mux_store_idx_", tag)
            val_sym = Symbol("__mux_store_val_", tag)
            res_sym = Symbol("__mux_store_res_", tag)

            ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
            ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)
            ctx.vw[val_sym] = _operand_to_u64!(ctx, inst.val)

            if block_label == Symbol("") || block_label == ctx.entry_label
                call = IRCall(res_sym, $soft_store,
                              [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
            else
                pred_sym = _mux_store_pred_sym!(ctx, block_label, tag,
                                                $("_lower_store_via_mux_$(name_tag)!"))
                call = IRCall(res_sym, $soft_store_guard,
                              [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
                              [64, 64, 64, 64], 64)
            end
            lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

            ctx.vw[alloca_dest] = ctx.vw[res_sym][1:$packed_bits]
            return nothing
        end
    end
end

# ---- Bennett-tfo8 / U113: alloca-MUX strategy tables ---------------------
#
# Single source of truth for the (elem_w, n_elems) → :mux_exch_NxW shape
# set and the strategy → load/store dispatch.  Before tfo8 the shape set
# was duplicated as if/elseif chains in `_pick_alloca_strategy`,
# `_lower_load_via_mux!`, and `_lower_store_single_origin!` — adding a
# new shape required edits in all three or it would silently route to
# `:unsupported`.
#
# The hand-written (4,8)/(8,8) load/store helpers and the @eval-generated
# (2,8)/(2,16)/(4,16)/(2,32) helpers are unified at the dispatch level
# here; the underlying duplication of their bodies is tracked separately
# by Bennett-lm3x / U56.
const _MUX_EXCH_STRATEGY = Dict{Tuple{Int,Int}, Symbol}(
    (8,  2) => :mux_exch_2x8,
    (8,  4) => :mux_exch_4x8,
    (8,  8) => :mux_exch_8x8,
    (16, 2) => :mux_exch_2x16,
    (16, 4) => :mux_exch_4x16,
    (32, 2) => :mux_exch_2x32,
)

const _MUX_EXCH_LOAD_DISPATCH = Dict{Symbol, Function}(
    :mux_exch_2x8  => _lower_load_via_mux_2x8!,
    :mux_exch_4x8  => _lower_load_via_mux_4x8!,
    :mux_exch_8x8  => _lower_load_via_mux_8x8!,
    :mux_exch_2x16 => _lower_load_via_mux_2x16!,
    :mux_exch_4x16 => _lower_load_via_mux_4x16!,
    :mux_exch_2x32 => _lower_load_via_mux_2x32!,
)

const _MUX_EXCH_STORE_DISPATCH = Dict{Symbol, Function}(
    :mux_exch_2x8  => _lower_store_via_mux_2x8!,
    :mux_exch_4x8  => _lower_store_via_mux_4x8!,
    :mux_exch_8x8  => _lower_store_via_mux_8x8!,
    :mux_exch_2x16 => _lower_store_via_mux_2x16!,
    :mux_exch_4x16 => _lower_store_via_mux_4x16!,
    :mux_exch_2x32 => _lower_store_via_mux_2x32!,
)

# ---- helpers for T1b.3 store/load dispatch ----

_next_mux_tag!(ctx::LoweringCtx, op::String, hint) =
    (ctx.mux_counter[] += 1; string(op, "_", hint, "_", ctx.mux_counter[]))

# Bennett-cc0 M2d helper: promote a 1-wire block predicate into a 64-wire
# operand suitable for the guarded soft_mux_store_guarded_NxW callees. Looks
# up the predicate via `ctx.block_pred[block_label]`, asserts it is a single
# wire (M2c invariant, same as `_lower_store_via_shadow!`), CNOT-copies that
# wire into bit 0 of a fresh 64-wire block, and registers the resulting SSA
# name in `ctx.vw`. Returns the symbol for use in `ssa(pred_sym)`.
# Caller supplies `tag` (for unique naming) and `callee_name` (for error text).
function _mux_store_pred_sym!(ctx::LoweringCtx, block_label::Symbol, tag::String,
                              callee_name::AbstractString)::Symbol
    pred_wires = get(ctx.block_pred, block_label, Int[])
    length(pred_wires) == 1 ||
        error(callee_name, ": expected single-wire predicate for block ",
              block_label, ", got ", length(pred_wires), " wires")
    pred_sym = Symbol("__mux_store_pred_", tag)
    pw64 = allocate!(ctx.wa, 64)
    push!(ctx.gates, CNOTGate(pred_wires[1], pw64[1]))  # promote 1→64 via low bit
    ctx.vw[pred_sym] = pw64
    return pred_sym
end

# Zero-extend a wire vector to 64 wires by CNOT-copying into the low bits of
# a fresh 64-wire block (high bits stay zero). Leaves the source wires
# untouched so they can still be read elsewhere.
function _wires_to_u64!(ctx::LoweringCtx, src::Vector{Int})
    length(src) <= 64 ||
        error("_wires_to_u64!: source has $(length(src)) wires > 64")
    dst = allocate!(ctx.wa, 64)
    for i in eachindex(src)
        push!(ctx.gates, CNOTGate(src[i], dst[i]))
    end
    return dst
end

# Resolve an IROperand to exactly 64 wires. For :const, materialize the value
# with NOT gates. For :ssa, zero-extend via CNOT-copy.
function _operand_to_u64!(ctx::LoweringCtx, op::IROperand)
    if op.kind == :const
        dst = allocate!(ctx.wa, 64)
        v = UInt64(op.value)  # narrow to 64 bits
        for i in 1:64
            if ((v >> (i - 1)) & UInt64(1)) == UInt64(1)
                push!(ctx.gates, NOTGate(dst[i]))
            end
        end
        return dst
    else
        haskey(ctx.vw, op.name) ||
            error("_operand_to_u64!: undefined SSA %$(op.name)")
        return _wires_to_u64!(ctx, ctx.vw[op.name])
    end
end