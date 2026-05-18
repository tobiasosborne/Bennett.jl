# ---- T1b.3: reversible mutable memory (store/alloca) ----

"""
    lower_alloca!(ctx, inst::IRAlloca)

Allocate the wire range for a fresh reversible array and record it in the
per-compilation alloca_info + ptr_provenance maps. No gates are emitted —
fresh wires are zero by WireAllocator invariant.

Bennett-z2dj / T5-P6 Step 4: dispatcher that splits on whether `inst.n_elems`
is a compile-time constant. Const-n routes to `_lower_alloca_const_n!` (the
byte-identical pre-Step-4 body); dynamic-n routes to `_lower_alloca_dynamic_n!`
which under `mem=:persistent` allocates the persistent-DS state slab and
records the impl in `ctx.persistent_info`.

MVP for const-n: (elem_width, n_elems=iconst(k)) with k >= 1. Dynamic n_elems
under `mem=:auto` errors with a hint to opt in via `mem=:persistent`.
"""
function lower_alloca!(ctx::LoweringCtx, inst::IRAlloca)
    if inst.n_elems isa ConstOperand
        return _lower_alloca_const_n!(ctx, inst)
    else
        return _lower_alloca_dynamic_n!(ctx, inst)
    end
end

"""
    _lower_alloca_const_n!(ctx, inst::IRAlloca)

Bennett-z2dj / T5-P6 Step 4: extracted from former `lower_alloca!` body;
this is the byte-identical const-n branch. Allocates `elem_width * n` zero
wires and registers a single-origin entry-predicate provenance entry.
"""
function _lower_alloca_const_n!(ctx::LoweringCtx, inst::IRAlloca)
    n = inst.n_elems.value
    n >= 1 || throw(ArgumentError("lower_alloca!: non-positive n_elems=$n"))
    inst.elem_width >= 1 || throw(ArgumentError("lower_alloca!: non-positive elem_width=$(inst.elem_width)"))

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

"""
    _lower_alloca_dynamic_n!(ctx, inst::IRAlloca)

Bennett-z2dj / T5-P6 Step 4 (consensus §5). Dynamic-n alloca branch.

Routes via `_pick_alloca_strategy_dynamic_n`, which throws under
`mem=:auto` with a hint pointing to `mem=:persistent`. Under
`mem=:persistent` the strategy is `:persistent_tree`: resolve the impl
via `_resolve_persistent_impl`, allocate `_state_len_bits(impl)` fresh
wires (zero by WireAllocator invariant — `linear_scan_pmap_new()`
returns all-zero, so no `pmap_new` IRCall is emitted; Bennett's reverse
pass uncomputes back to all-zero cleanly per consensus §3), and record
the impl mapping in `ctx.persistent_info[inst.dest]` for the Step 5
store/load helpers + Step 8 GEP guards.

A single-origin entry-predicate `PtrOrigin` is installed in
`ctx.ptr_provenance[inst.dest]` so existing GEP walkers don't crash on
the dynamic-n alloca. Non-entry-block STORE rejection (consensus §3 R1)
lives in Step 5's `_lower_store_via_persistent!`, NOT here — Bennett's
existing `lower_alloca!` historically accepts allocas in any block, and
the spec's R1 guard belongs at the store site.
"""
function _lower_alloca_dynamic_n!(ctx::LoweringCtx, inst::IRAlloca)
    # Validates ctx.mem; throws on :auto with the mem=:persistent hint.
    # Returns :persistent_tree under mem=:persistent.
    strategy = _pick_alloca_strategy_dynamic_n(ctx, inst)
    strategy === :persistent_tree ||
        error("_lower_alloca_dynamic_n!: unsupported strategy :$strategy " *
              "(only :persistent_tree wired today)")
    impl = _resolve_persistent_impl(ctx.persistent_impl, ctx.hashcons)
    # State-slab allocation: fresh wires are zero by WireAllocator invariant.
    # linear_scan_pmap_new() returns all-zero, so no NOT gates needed —
    # Bennett's reverse pass will uncompute cleanly to all-zero (consensus §3).
    n_bits = _state_len_bits(impl)
    wires = allocate!(ctx.wa, n_bits)
    ctx.vw[inst.dest] = wires
    # Record impl mapping so store/load helpers (Step 5) and GEP/PtrOffset
    # guards (Step 8) can dispatch on it.
    ctx.persistent_info[inst.dest] = impl
    # GEP walkers crash on missing provenance; install a single-origin entry-
    # predicate provenance so GEP-of-this-alloca passes the existing
    # multi-origin checks (consensus §5 Step 4 last bullet).
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
        throw(AssertionError("_entry_predicate_wire: ctx has sentinel entry_label; direct " *
              "lower_block_insts! callers must either set entry_label or " *
              "bypass ptr_provenance usage"))
    pw = get(ctx.block_pred, ctx.entry_label, Int[])
    length(pw) == 1 ||
        throw(AssertionError("_entry_predicate_wire: expected single-wire predicate for " *
              "entry block $(ctx.entry_label), got $(length(pw)) wires"))
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
    idx isa ConstOperand && return :shadow
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

# ---- Bennett-z2dj / T5-P6 Step 3: persistent-tree dispatcher helpers ----
#
# Per `docs/design/p6_consensus.md` §5 Step 3: define the dispatcher sibling
# and four small helpers used by Steps 4 and 9. Step 3 only DEFINES these
# helpers — they are not yet called from `lower_alloca!` (that wiring is
# Step 4). Existing observable behaviour is unchanged.

"""
    _pick_alloca_strategy_dynamic_n(ctx::LoweringCtx, inst::IRAlloca) -> Symbol

Bennett-z2dj / T5-P6 (consensus §5 Step 3). Sibling of
`_pick_alloca_strategy` for the dynamic-n case (`inst.n_elems` not
`ConstOperand`). Today's behaviour: under `mem=:auto` the dynamic-n
arm refuses to silently fall through and instructs the user to opt in
via `mem=:persistent`; under `mem=:persistent` it returns
`:persistent_tree` so Step 4 can route to the persistent-DS lowering.
Any other `ctx.mem` value is defensive — `lower()` already validates
`mem in (:auto, :persistent)`.
"""
function _pick_alloca_strategy_dynamic_n(ctx::LoweringCtx, inst::IRAlloca)::Symbol
    if ctx.mem === :auto
        throw(ArgumentError("dynamic n_elems alloca encountered under mem=:auto; " *
              "the persistent_tree arm is the only correct lowering for dynamic n. " *
              "Re-run reversible_compile(f, ...; mem=:persistent) to enable it."))
    elseif ctx.mem === :persistent
        return :persistent_tree
    else
        throw(ArgumentError("_pick_alloca_strategy_dynamic_n: unexpected mem=:$(ctx.mem)"))
    end
end

"""
    _resolve_persistent_impl(impl::Symbol, hashcons::Symbol)
        -> Bennett.Persistent.PersistentMapImpl

Bennett-z2dj / T5-P6 (consensus §5 Step 3). Single source of truth that
maps the (`persistent_impl`, `hashcons`) kwarg pair to the concrete
`PersistentMapImpl` instance. Only `(:linear_scan, :none)` is wired in
the Step 3 MVP; every other combination throws an `ArgumentError`
pointing at the follow-up beads that will land the missing arms.

Note: no explicit `::PersistentMapImpl` return-type annotation — the
type lives in `Bennett.Persistent`, a submodule loaded AFTER `lower.jl`
(see `Bennett.jl`: lower.jl on line 32, persistent/persistent.jl on
line 58). Annotating the return type would parse-error at include time.
The function bodies execute later and resolve `Bennett.LINEAR_SCAN_IMPL`
lazily via getproperty.
"""
function _resolve_persistent_impl(impl::Symbol, hashcons::Symbol)
    # Validate impl symbol first.
    impl in (:linear_scan, :okasaki, :hamt, :cf) ||
        throw(ArgumentError("_resolve_persistent_impl: unknown persistent_impl :$impl; " *
              "supported: :linear_scan (others NYI)"))
    hashcons in (:none, :naive, :feistel) ||
        throw(ArgumentError("_resolve_persistent_impl: unknown hashcons :$hashcons; " *
              "supported: :none (others NYI)"))

    if impl === :linear_scan
        if hashcons === :none
            return Bennett.LINEAR_SCAN_IMPL
        else
            throw(ArgumentError("_resolve_persistent_impl: hashcons=:$hashcons NYI on " *
                  ":linear_scan; only :none is wired " *
                  "(Bennett-z2dj follow-up beads track :naive, :feistel)"))
        end
    else
        throw(ArgumentError("_resolve_persistent_impl: persistent_impl=:$impl NYI; " *
              "only :linear_scan is wired " *
              "(Bennett-z2dj follow-up beads track :okasaki, :hamt, :cf)"))
    end
end

"""
    _state_len_bits(impl) -> Int

Bennett-z2dj / T5-P6 (consensus §5 Step 3). Total wire count for the
impl's state tuple. Derived generically from a one-shot `impl.pmap_new()`
call: the returned `NTuple{N, T}` has `N * sizeof(T) * 8` bits. Called
once per `lower_alloca!` in Step 4 so performance is irrelevant. For
`LINEAR_SCAN_IMPL` the result is `9 * 64 = 576` bits.

(`impl` is duck-typed — see `_resolve_persistent_impl` for why the type
isn't annotated at parse time.)
"""
function _state_len_bits(impl)::Int
    s = impl.pmap_new()
    s isa NTuple ||
        throw(ArgumentError("_state_len_bits: impl.pmap_new() must return an NTuple; " *
              "got $(typeof(s))"))
    N = length(s)
    T = eltype(s)
    return N * sizeof(T) * 8
end

"""
    _K_bits(impl) -> Int

Bennett-z2dj / T5-P6 (consensus §5 Step 3). Bit-width of the impl's
key type. For `LINEAR_SCAN_IMPL` this is `sizeof(Int8) * 8 = 8`.
"""
_K_bits(impl)::Int = sizeof(impl.K) * 8

"""
    _V_bits(impl) -> Int

Bennett-z2dj / T5-P6 (consensus §5 Step 3). Bit-width of the impl's
value type. For `LINEAR_SCAN_IMPL` this is `sizeof(Int8) * 8 = 8`.
"""
_V_bits(impl)::Int = sizeof(impl.V) * 8

# ---- Bennett-z2dj / T5-P6 Step 5: persistent store/load helpers ----
#
# Per `docs/design/p6_consensus.md` §5 Step 5: emit one IRCall to the
# impl's `pmap_set` / `pmap_get` per LLVM store/load instruction whose
# pointer resolves (via `ctx.ptr_provenance`) to a persistent alloca.
# The IRCall machinery (Bennett-atf4 in src/lowering/call.jl) derives
# the concrete callee Julia arg-type tuple from `methods(callee)`, so
# the widths we pass in `arg_widths` must match
# `_state_len_bits(impl) / _K_bits(impl) / _V_bits(impl)` exactly.
#
# Step 5 alone defines these helpers; the dispatcher wiring that
# routes `lower_store!` / `lower_load!` into them when the pointer
# targets a persistent slab lands in Step 6. They are therefore
# unreachable from `lower()` after this step — intentional, per
# consensus §5's TDD-friendly slice boundary.

"""
    _lower_store_via_persistent!(ctx, inst::IRStore, alloca_dest, block_label)

Bennett-z2dj / T5-P6 Step 5 (consensus §5). Map an LLVM `store v, ptr`
whose `ptr` resolves through `ctx.ptr_provenance` to a single-origin
`PtrOrigin` over a persistent slab (`alloca_dest` in
`ctx.persistent_info`) into one IRCall to `impl.pmap_set`. After the
call, `ctx.vw[alloca_dest]` is rebound to the post-call state wires
so subsequent loads through the same alloca see the updated state.

**Bennett-smjd (2026-05-18)** — non-entry-block stores no longer refuse.
When `block_label` is a non-entry block, dispatch into
`_lower_store_via_persistent_guarded!` (output-MUX strategy): the IRCall
to `impl.pmap_set` runs unconditionally to produce `post_state`, then a
`lower_mux!` between `post_state` and `pre_state` keyed on the block's
single-wire path predicate yields a `merged` vector that is rebound to
`ctx.vw[alloca_dest]`. When the block predicate is 0 at runtime, the MUX
returns `pre_state` (the IRCall's wires are still allocated but the
visible state is unchanged); Bennett's reverse pass uncomputes both the
IRCall and the MUX self-inversely, leaving all ancillae at zero.

Refusal contracts:
- **Multi-origin pointer** (consensus §R4). A pointer-typed phi/
  select that merges two persistent slabs is NYI; refused loudly.
- **Missing block predicate** (Bennett-smjd). If a non-entry block has
  no `ctx.block_pred` entry (single-wire), refuse with an
  `AssertionError` — the block-pred machinery upstream should have
  populated this. Bennett-p94b invariant: single-wire predicates only.
"""
function _lower_store_via_persistent!(ctx::LoweringCtx, inst::IRStore,
                                      alloca_dest::Symbol, block_label::Symbol)
    # Bennett-smjd: non-entry-block dispatch.
    # Sentinel Symbol("") (direct lower_block_insts! callers without entry-block
    # info) is still treated as entry for backward compatibility, matching the
    # shadow-store convention upstream.
    if block_label === ctx.entry_label || block_label === Symbol("")
        return _emit_persistent_set_unconditional!(ctx, inst, alloca_dest)
    end

    pred_wires = get(ctx.block_pred, block_label, Int[])
    length(pred_wires) == 1 ||
        throw(AssertionError("_lower_store_via_persistent!: expected single-wire " *
              "predicate for non-entry block :$block_label, got " *
              "$(length(pred_wires)) wires — block_pred machinery (Bennett-p94b) " *
              "should have populated this (Bennett-smjd)."))
    return _lower_store_via_persistent_guarded!(ctx, inst, alloca_dest,
                                                 block_label, pred_wires[1])
end

"""
    _emit_persistent_set_unconditional!(ctx, inst, alloca_dest)

Bennett-z2dj entry-block fast path (factored out of
`_lower_store_via_persistent!` for clarity once the guarded variant
landed in Bennett-smjd). Emits a single `IRCall` to `impl.pmap_set` and
rebinds `ctx.vw[alloca_dest]` to the post-call state wires. Refuses
multi-origin pointers (consensus §R4) and width-mismatched stores.
"""
function _emit_persistent_set_unconditional!(ctx::LoweringCtx, inst::IRStore,
                                              alloca_dest::Symbol)
    # Multi-origin refusal (consensus §R4). The caller (Step 6 dispatcher)
    # picks one PtrOrigin from the provenance list; we re-derive impl + key +
    # value widths here for self-contained validation.
    haskey(ctx.ptr_provenance, inst.ptr.name) ||
        throw(AssertionError("_emit_persistent_set_unconditional!: no provenance for ptr " *
              "%$(inst.ptr.name); persistent stores must target a known alloca"))
    origins = ctx.ptr_provenance[inst.ptr.name]
    length(origins) == 1 || throw(ArgumentError(
        "_emit_persistent_set_unconditional!: multi-origin pointer (n=$(length(origins))) " *
        "into persistent slab :$alloca_dest is NYI " *
        "(consensus §R4 follow-up bead)."))
    origin = origins[1]

    haskey(ctx.persistent_info, alloca_dest) ||
        throw(AssertionError("_emit_persistent_set_unconditional!: alloca :$alloca_dest has " *
              "no persistent_info entry; dispatcher routed a non-persistent alloca here"))
    impl = ctx.persistent_info[alloca_dest]
    state_w = _state_len_bits(impl)
    k_w     = _K_bits(impl)
    v_w     = _V_bits(impl)

    # Width sanity: the value being stored must match impl.V's width.
    inst.width == v_w ||
        throw(DimensionMismatch("_emit_persistent_set_unconditional!: store width=$(inst.width) " *
              "doesn't match impl V width=$v_w (impl=$(typeof(impl)))"))

    # Fresh synthetic SSA name for the post-call state. Bennett-z2dj uses the
    # existing `ctx.mux_counter[]` monotonic counter (also used by the MUX-EXCH
    # helpers) so synthetic names stay unique across all lowering paths.
    ctx.mux_counter[] += 1
    new_state_dest = Symbol("__persistent_state_", alloca_dest, "_", ctx.mux_counter[])

    # IRCall: callee is impl.pmap_set, args are (state, key, value).
    # The state arg is `SSAOperand(alloca_dest)` — ctx.vw[alloca_dest] already
    # holds the impl's state wires (installed by _lower_alloca_dynamic_n!).
    # The key arg is `origin.idx_op` (the GEP index that selects this slot).
    # The value arg is `inst.val` (the IROperand being stored).
    call = IRCall(new_state_dest, impl.pmap_set,
                  IROperand[SSAOperand(alloca_dest), origin.idx_op, inst.val],
                  [state_w, k_w, v_w],
                  state_w)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call;
                compact=ctx.compact_calls)

    # Rebind alloca's wire map to the post-call state. Subsequent loads through
    # the same alloca pointer see the updated state. (Bennett's reverse pass
    # uncomputes the call gates and cleans up the post-state wires; the old
    # state wires remain in ctx.vw under their original SSA name if anyone
    # captured them.)
    ctx.vw[alloca_dest] = ctx.vw[new_state_dest]
    return nothing
end

"""
    _lower_store_via_persistent_guarded!(ctx, inst, alloca_dest, block_label, pred_wire)

Bennett-smjd (2026-05-18) — non-entry-block persistent store via
output-MUX (Plan Option A). The IRCall to `impl.pmap_set` runs
unconditionally to produce `post_state`; a `lower_mux!` between
`post_state` (selected when `pred_wire == 1`) and `pre_state` (selected
when `pred_wire == 0`) yields a `merged` wire vector that is rebound
to `ctx.vw[alloca_dest]`. Subsequent loads through the same alloca see
the merged state.

Why output-MUX over the rejected alternatives:
- **Option B (input-guarded set)** would have folded `pred_wire` into
  the slab inputs before the call, but `pmap_set`'s branchless impl
  writes to ALL slots — there's no clean way to "skip" the write
  without corrupting the map invariant when `pred=0`.
- **Option C (controlled-IRCall)** would have lifted the entire call
  to a `ControlledCircuit` keyed on `pred_wire`, which works but
  inflates every gate inside `pmap_set` to a guarded variant — much
  larger than a single MUX at the call boundary.

Bennett's reverse pass uncomputes the IRCall and the MUX
self-inversely; all ancillae return to zero.

Refusal contracts: same as `_emit_persistent_set_unconditional!`
(multi-origin / missing persistent_info / width mismatch) plus a
defensive missing-provenance assertion on the predicate wire.
"""
function _lower_store_via_persistent_guarded!(ctx::LoweringCtx, inst::IRStore,
                                              alloca_dest::Symbol,
                                              block_label::Symbol,
                                              pred_wire::Int)
    # Multi-origin refusal (consensus §R4) — same preflight as the
    # unconditional path; kept inline rather than calling a shared helper
    # because we need the impl widths and origin locally for the IRCall.
    haskey(ctx.ptr_provenance, inst.ptr.name) ||
        throw(AssertionError("_lower_store_via_persistent_guarded!: no provenance for ptr " *
              "%$(inst.ptr.name); persistent stores must target a known alloca"))
    origins = ctx.ptr_provenance[inst.ptr.name]
    length(origins) == 1 || throw(ArgumentError(
        "_lower_store_via_persistent_guarded!: multi-origin pointer (n=$(length(origins))) " *
        "into persistent slab :$alloca_dest in non-entry block :$block_label is NYI " *
        "(consensus §R4 + Bennett-smjd: multi-origin × non-entry intersection deferred)."))
    origin = origins[1]

    haskey(ctx.persistent_info, alloca_dest) ||
        throw(AssertionError("_lower_store_via_persistent_guarded!: alloca :$alloca_dest has " *
              "no persistent_info entry; dispatcher routed a non-persistent alloca here"))
    impl = ctx.persistent_info[alloca_dest]
    state_w = _state_len_bits(impl)
    k_w     = _K_bits(impl)
    v_w     = _V_bits(impl)

    inst.width == v_w ||
        throw(DimensionMismatch("_lower_store_via_persistent_guarded!: store width=$(inst.width) " *
              "doesn't match impl V width=$v_w (impl=$(typeof(impl)))"))

    # Capture pre-state wires BEFORE the IRCall (defensive copy — lower_call!
    # rebinds ctx.vw entries and we need a stable snapshot for the MUX).
    pre_state = copy(ctx.vw[alloca_dest])
    length(pre_state) == state_w ||
        throw(AssertionError("_lower_store_via_persistent_guarded!: pre_state has " *
              "$(length(pre_state)) wires, expected $state_w (slab :$alloca_dest)"))

    # Unconditional pmap_set IRCall — emits the post-state into a fresh SSA
    # name so we can MUX it against pre_state without aliasing.
    ctx.mux_counter[] += 1
    new_state_dest = Symbol("__persistent_state_guarded_", alloca_dest, "_",
                            ctx.mux_counter[])
    call = IRCall(new_state_dest, impl.pmap_set,
                  IROperand[SSAOperand(alloca_dest), origin.idx_op, inst.val],
                  [state_w, k_w, v_w],
                  state_w)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call;
                compact=ctx.compact_calls)
    post_state = ctx.vw[new_state_dest]
    length(post_state) == state_w ||
        throw(AssertionError("_lower_store_via_persistent_guarded!: post_state has " *
              "$(length(post_state)) wires, expected $state_w"))

    # MUX-select: pred=1 → post_state, pred=0 → pre_state. lower_mux! takes
    # `cond::Vector{Int}` (single-bit), `tv` (true-value), `fv` (false-value),
    # `W` (width), and returns a freshly-allocated W-wire result.
    merged = lower_mux!(ctx.gates, ctx.wa, [pred_wire], post_state, pre_state, state_w)
    length(merged) == state_w ||
        throw(AssertionError("_lower_store_via_persistent_guarded!: merged has " *
              "$(length(merged)) wires, expected $state_w"))
    ctx.vw[alloca_dest] = merged
    return nothing
end

"""
    _lower_load_via_persistent!(ctx, inst::IRLoad, alloca_dest)

Bennett-z2dj / T5-P6 Step 5 (consensus §5). Map an LLVM
`%dest = load ptr` whose `ptr` resolves through `ctx.ptr_provenance`
to a single-origin `PtrOrigin` over a persistent slab into one IRCall
to `impl.pmap_get`. The loaded value wires are installed at
`ctx.vw[inst.dest]` by `lower_call!`.

No non-entry-block guard for loads — loads are read-only and do not
threaten Bennett's reverse-pass invariant. Multi-origin pointers are
refused identically to the store helper.
"""
function _lower_load_via_persistent!(ctx::LoweringCtx, inst::IRLoad,
                                     alloca_dest::Symbol)
    haskey(ctx.ptr_provenance, inst.ptr.name) ||
        throw(AssertionError("_lower_load_via_persistent!: no provenance for ptr " *
              "%$(inst.ptr.name); persistent loads must target a known alloca"))
    origins = ctx.ptr_provenance[inst.ptr.name]
    length(origins) == 1 || throw(ArgumentError(
        "_lower_load_via_persistent!: multi-origin pointer (n=$(length(origins))) " *
        "into persistent slab :$alloca_dest is NYI " *
        "(consensus §R4 follow-up bead)."))
    origin = origins[1]

    haskey(ctx.persistent_info, alloca_dest) ||
        throw(AssertionError("_lower_load_via_persistent!: alloca :$alloca_dest has " *
              "no persistent_info entry; dispatcher routed a non-persistent alloca here"))
    impl = ctx.persistent_info[alloca_dest]
    state_w = _state_len_bits(impl)
    k_w     = _K_bits(impl)
    v_w     = _V_bits(impl)

    # Width sanity: the load width must match impl.V's width.
    inst.width == v_w ||
        throw(DimensionMismatch("_lower_load_via_persistent!: load width=$(inst.width) " *
              "doesn't match impl V width=$v_w (impl=$(typeof(impl)))"))

    # IRCall: callee is impl.pmap_get, args are (state, key); returns the V
    # wires into `inst.dest`. The state arg is `SSAOperand(alloca_dest)` —
    # ctx.vw[alloca_dest] already holds the impl's state wires.
    call = IRCall(inst.dest, impl.pmap_get,
                  IROperand[SSAOperand(alloca_dest), origin.idx_op],
                  [state_w, k_w],
                  v_w)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call;
                compact=ctx.compact_calls)
    # ctx.vw[inst.dest] now holds the V wires (set by lower_call!).
    return nothing
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
    inst.ptr isa SSAOperand ||
        error("lower_store!: store to a constant pointer is not supported")

    haskey(ctx.ptr_provenance, inst.ptr.name) ||
        throw(AssertionError("lower_store!: no provenance for ptr %$(inst.ptr.name); " *
              "store must target an alloca or GEP thereof"))
    origins = ctx.ptr_provenance[inst.ptr.name]
    isempty(origins) &&
        throw(AssertionError("lower_store!: empty origin set for ptr %$(inst.ptr.name)"))

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
            throw(AssertionError("lower_store!: multi-origin ptr references unknown alloca %$(o.alloca_dest)"))
        strategy = _pick_alloca_strategy(info, o.idx_op)
        if strategy == :shadow
            # Const-idx origin: existing M2b path. Single-slot guarded shadow
            # store keyed on the origin's path predicate.
            _emit_store_via_shadow_guarded!(ctx, inst, o.alloca_dest, info, o.idx_op,
                                            o.predicate_wire, val_wires)
        elseif strategy == :shadow_checkpoint
            # Bennett-cb9y (2026-05-01, dnh phase 1b): N·W > 64 multi-origin
            # runtime-idx. The shadow-checkpoint helper accepts an
            # `extern_pred_wire` that is AND'd with each per-slot eq_wire,
            # gating the whole fan-out by the origin's path predicate.
            _lower_store_via_shadow_checkpoint!(ctx, inst, o.alloca_dest, info,
                                                o.idx_op, Symbol("");
                                                extern_pred_wire=o.predicate_wire)
        else
            # Bennett-cb9y (2026-05-01, dnh phase 1b): MUX-EXCH multi-origin
            # runtime-idx. Dispatch to the @eval-generated
            # `_lower_store_via_mux_NxW!` with the per-origin predicate as
            # `extern_pred_wire`. The callee uses `soft_mux_store_guarded_NxW`,
            # which folds the predicate into every per-slot ifelse cond — when
            # the origin's predicate is 0, the entire MUX-EXCH op is a no-op.
            # Mutual exclusion of origin predicates is guaranteed by the
            # producer (ptr-phi/select).
            fn = get(_MUX_EXCH_STORE_DISPATCH, strategy, nothing)
            fn === nothing &&
                error("lower_store!: multi-origin ptr with strategy=$strategy " *
                      "is NYI for origin=$(o.alloca_dest); file a bd issue")
            fn(ctx, inst, o.alloca_dest, o.idx_op;
               extern_pred_wire=o.predicate_wire)
        end
    end
    return nothing
end

"""Single-origin store dispatch (Bennett-cc0 M2b). Pulled out of the old
`lower_store!` body so the fast path stays byte-identical to pre-M2b."""
function _lower_store_single_origin!(ctx::LoweringCtx, inst::IRStore,
                                     origin::PtrOrigin, block_label::Symbol)
    alloca_dest = origin.alloca_dest
    idx_op = origin.idx_op

    # Bennett-z2dj T5-P6 / consensus §5 Step 6: persistent-slab early-out.
    # Persistent allocas populate ctx.persistent_info (not ctx.alloca_info)
    # so the alloca_info lookup below would mistakenly diagnose them as
    # unknown. Route persistent stores to the dedicated helper which emits
    # an IRCall to impl.pmap_set instead of the MUX-EXCH / shadow paths.
    if haskey(ctx.persistent_info, alloca_dest)
        return _lower_store_via_persistent!(ctx, inst, alloca_dest, block_label)
    end

    info = get(ctx.alloca_info, alloca_dest, nothing)
    info === nothing &&
        throw(AssertionError("lower_store!: provenance points to unknown alloca %$alloca_dest"))

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
        throw(DimensionMismatch("_emit_store_via_shadow_guarded!: store width=$(inst.width) doesn't match alloca elem_width=$elem_w"))
    idx_op isa ConstOperand ||
        error("_emit_store_via_shadow_guarded!: non-const idx not supported in multi-origin path")
    0 <= idx_op.value < n ||
        throw(ArgumentError("_emit_store_via_shadow_guarded!: idx=$(idx_op.value) out of range [0, $n)"))

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        throw(DimensionMismatch("_emit_store_via_shadow_guarded!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)"))

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
        throw(DimensionMismatch("_lower_store_via_shadow!: store width=$(inst.width) doesn't match alloca elem_width=$elem_w"))
    0 <= idx_op.value < n ||
        throw(ArgumentError("_lower_store_via_shadow!: idx=$(idx_op.value) out of range [0, $n)"))

    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        throw(DimensionMismatch("_lower_store_via_shadow!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)"))

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
            throw(AssertionError("_lower_store_via_shadow!: expected single-wire predicate for block $block_label, got $(length(pred_wires)) wires"))
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
    idx_bits >= 1 || throw(ArgumentError("_emit_idx_eq_const!: idx_bits must be >= 1, got $idx_bits"))
    length(idx_wires) >= idx_bits ||
        throw(DimensionMismatch("_emit_idx_eq_const!: idx_wires has $(length(idx_wires)) < idx_bits=$idx_bits"))

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
# Bennett-cb9y (2026-05-01, dnh phase 1b): added `extern_pred_wire` kwarg
# for the multi-origin × runtime-idx path on N·W > 64 shapes. When set,
# overrides `block_label` and is AND'd with each per-slot eq_wire — the
# multi-origin store loop in `lower_store!` passes `o.predicate_wire`
# here so the entire shadow-checkpoint fan-out is gated by the origin's
# path predicate.
function _lower_store_via_shadow_checkpoint!(ctx::LoweringCtx, inst::IRStore,
                                             alloca_dest::Symbol, info::Tuple{Int,Int},
                                             idx_op::IROperand, block_label::Symbol;
                                             extern_pred_wire::Union{Nothing,Int}=nothing)
    elem_w, n = info
    inst.width == elem_w ||
        throw(DimensionMismatch("_lower_store_via_shadow_checkpoint!: store width=$(inst.width) doesn't match alloca elem_width=$elem_w"))
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        throw(DimensionMismatch("_lower_store_via_shadow_checkpoint!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)"))

    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, elem_w)
    # resolve! with width=0 returns the existing SSA wires (may be wider than
    # log2(n)). We only care about the low idx_bits — upper bits are assumed
    # zero by construction (e.g. zext from i8 to i32 for an n=256 array).
    idx_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, idx_op, 0)
    idx_bits = max(1, ceil(Int, log2(n)))
    length(idx_wires) >= idx_bits ||
        throw(DimensionMismatch("_lower_store_via_shadow_checkpoint!: idx SSA has $(length(idx_wires)) wires, need at least $idx_bits"))

    # Determine the outer guard. Priority: extern_pred_wire (multi-origin
    # path) > block_label (single-origin non-entry) > none (entry block).
    use_outer_guard, outer_pred_wire = if extern_pred_wire !== nothing
        (true, extern_pred_wire)
    elseif !(block_label == Symbol("") || block_label == ctx.entry_label)
        pw = get(ctx.block_pred, block_label, Int[])
        length(pw) == 1 ||
            throw(AssertionError("_lower_store_via_shadow_checkpoint!: expected single-wire predicate for block $block_label, got $(length(pw)) wires"))
        (true, pw[1])
    else
        (false, 0)
    end

    for k in 0:(n - 1)
        eq_wire = _emit_idx_eq_const!(ctx, idx_wires, idx_bits, k)
        guard_w = if use_outer_guard
            _and_wire!(ctx.gates, ctx.wa, [outer_pred_wire], [eq_wire])[1]
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
        throw(DimensionMismatch("_lower_load_via_shadow_checkpoint!: load width=$W doesn't match alloca elem_width=$elem_w"))
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n ||
        throw(DimensionMismatch("_lower_load_via_shadow_checkpoint!: primal has $(length(arr_wires)) wires, expected $(elem_w*n)"))

    idx_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, idx_op, 0)
    idx_bits = max(1, ceil(Int, log2(n)))
    length(idx_wires) >= idx_bits ||
        throw(DimensionMismatch("_lower_load_via_shadow_checkpoint!: idx SSA has $(length(idx_wires)) wires, need at least $idx_bits"))

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

# Bennett-cc0 M1 + Bennett-lm3x / U56: parametric MUX EXCH helpers.
# Generated via @eval over the shape list. Each (N, W) pair produces a
# `_lower_load_via_mux_NxW!` and a `_lower_store_via_mux_NxW!`, both following
# the same structure: validate width + packed-array size, pack operands into
# UInt64, emit IRCall to the matching `soft_mux_*_NxW` callee, slice the low
# N·W bits back into the primal wire list.
#
# Bennett-cc0 M2d: MUX-store dispatch is guarded when the store lives in a
# non-entry block. `block_label == ctx.entry_label` (or the sentinel
# Symbol("")) routes to the unguarded `soft_mux_store_NxW` callee — entry-block
# stores therefore keep the byte-identical BENCHMARKS.md gate counts. Any
# other block promotes the 1-wire block predicate into a 64-wire operand and
# calls `soft_mux_store_guarded_NxW`, folding `pred` into the per-slot `ifelse`
# cond. When `pred == 0` every slot returns OLD → `arr` unchanged.
#
# Bennett-lm3x / U56 (2026-05-01): the (4,8) and (8,8) shapes were previously
# hand-written in aggregate.jl + memory.jl with bodies textually identical to
# what this loop produces. Folded into the loop to eliminate the duplication
# and the implicit second copy of the shape set. The single source of truth
# for valid shapes is `_MUX_SHAPES_NW` below; `_MUX_EXCH_STRATEGY` derives
# from it.
const _MUX_SHAPES_NW = [(2, 8), (4, 8), (8, 8), (2, 16), (4, 16), (2, 32),
                        # Bennett-nj6c (2026-05-01, dnh phase 1a): fill the
                        # gaps in the N·W ≤ 64 lattice. Closes the
                        # `:unsupported` arm at line 84-95 for these shapes;
                        # parametric @eval loop above auto-generates the
                        # `_lower_load_via_mux_NxW!` / `_lower_store_via_mux_NxW!`
                        # helpers from this list, so adding shapes here is
                        # sufficient on the lowering side. soft_mux_*_NxW
                        # callees are registered in src/callees.jl.
                        (3, 8), (5, 8), (6, 8), (7, 8), (3, 16)]

for (N, W) in _MUX_SHAPES_NW
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
                throw(DimensionMismatch(string($("_lower_load_via_mux_$(name_tag)!: load width must be $W, got "), inst.width)))
            arr_wires = ctx.vw[alloca_dest]
            length(arr_wires) == $packed_bits ||
                throw(DimensionMismatch(string($("_lower_load_via_mux_$(name_tag)!: expected $(packed_bits)-wire packed array at alloca "),
                      alloca_dest, "; got ", length(arr_wires))))

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
        # Bennett-cc0 M2d: same block_label-dispatch pattern as the hand-
        # written (4,8)/(8,8) helpers. Entry-block → unguarded callee,
        # byte-identical to pre-M2d. Any other block → guarded callee
        # with block-predicate folded into the per-slot ifelse cond.
        #
        # Bennett-cb9y (2026-05-01, dnh phase 1b): added `extern_pred_wire`
        # kwarg for the multi-origin × runtime-idx case. When supplied,
        # bypasses the block_label dispatch and uses the caller-provided
        # wire (typically a per-origin path predicate) as the guard. The
        # multi-origin store loop in `lower_store!` passes
        # `o.predicate_wire` here so each origin's contribution fires only
        # when its alloca was selected at runtime.
        function $store_fn(ctx::LoweringCtx, inst::IRStore,
                           alloca_dest::Symbol, idx_op::IROperand;
                           block_label::Symbol=Symbol(""),
                           extern_pred_wire::Union{Nothing,Int}=nothing)
            inst.width == $W ||
                throw(DimensionMismatch(string($("_lower_store_via_mux_$(name_tag)!: store width must be $W, got "), inst.width)))
            arr_wires = ctx.vw[alloca_dest]
            length(arr_wires) == $packed_bits ||
                throw(DimensionMismatch($("_lower_store_via_mux_$(name_tag)!: expected $(packed_bits)-wire packed array")))

            tag = _next_mux_tag!(ctx, "st", inst.ptr.name)
            arr_sym = Symbol("__mux_store_arr_", tag)
            idx_sym = Symbol("__mux_store_idx_", tag)
            val_sym = Symbol("__mux_store_val_", tag)
            res_sym = Symbol("__mux_store_res_", tag)

            ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)
            ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)
            ctx.vw[val_sym] = _operand_to_u64!(ctx, inst.val)

            if extern_pred_wire !== nothing
                pred_sym = _mux_store_pred_sym_from_wire!(ctx, extern_pred_wire, tag)
                call = IRCall(res_sym, $soft_store_guard,
                              [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
                              [64, 64, 64, 64], 64)
            elseif block_label == Symbol("") || block_label == ctx.entry_label
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

# ---- Bennett-tfo8 / U113 + Bennett-lm3x / U56: alloca-MUX strategy tables ----
#
# Single source of truth for the (elem_w, n_elems) → :mux_exch_NxW shape set
# and the strategy → load/store dispatch. Before tfo8 the shape set was
# duplicated as if/elseif chains in `_pick_alloca_strategy`,
# `_lower_load_via_mux!`, and `_lower_store_single_origin!` — adding a new
# shape required edits in all three or it would silently route to
# `:unsupported`. lm3x (2026-05-01) further unified the body-level
# duplication: the hand-written (4,8)/(8,8) helpers were folded into the
# @eval loop above, so all three tables and all 12 lowering functions now
# derive from the single `_MUX_SHAPES_NW` list.
const _MUX_EXCH_STRATEGY = Dict{Tuple{Int,Int}, Symbol}(
    (W, N) => Symbol(:mux_exch_, N, :x, W) for (N, W) in _MUX_SHAPES_NW
)

const _MUX_EXCH_LOAD_DISPATCH = Dict{Symbol, Function}(
    Symbol(:mux_exch_, N, :x, W) =>
        getfield(@__MODULE__, Symbol(:_lower_load_via_mux_, N, :x, W, :!))
    for (N, W) in _MUX_SHAPES_NW
)

const _MUX_EXCH_STORE_DISPATCH = Dict{Symbol, Function}(
    Symbol(:mux_exch_, N, :x, W) =>
        getfield(@__MODULE__, Symbol(:_lower_store_via_mux_, N, :x, W, :!))
    for (N, W) in _MUX_SHAPES_NW
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
        throw(AssertionError(string(callee_name, ": expected single-wire predicate for block ",
              block_label, ", got ", length(pred_wires), " wires")))
    return _mux_store_pred_sym_from_wire!(ctx, pred_wires[1], tag)
end

# Bennett-cb9y / U—: variant of `_mux_store_pred_sym!` that takes the
# predicate wire directly instead of looking it up by block label. Used by
# the multi-origin × runtime-idx store path, where each origin already
# carries its own `predicate_wire` from `ptr_provenance`. Identical 1→64
# promotion via CNOT into the low bit of a fresh 64-wire block.
function _mux_store_pred_sym_from_wire!(ctx::LoweringCtx, pred_wire::Int,
                                        tag::String)::Symbol
    pred_sym = Symbol("__mux_store_pred_", tag)
    pw64 = allocate!(ctx.wa, 64)
    push!(ctx.gates, CNOTGate(pred_wire, pw64[1]))
    ctx.vw[pred_sym] = pw64
    return pred_sym
end

# Zero-extend a wire vector to 64 wires by CNOT-copying into the low bits of
# a fresh 64-wire block (high bits stay zero). Leaves the source wires
# untouched so they can still be read elsewhere.
function _wires_to_u64!(ctx::LoweringCtx, src::Vector{Int})
    length(src) <= 64 ||
        throw(DimensionMismatch("_wires_to_u64!: source has $(length(src)) wires > 64"))
    dst = allocate!(ctx.wa, 64)
    for i in eachindex(src)
        push!(ctx.gates, CNOTGate(src[i], dst[i]))
    end
    return dst
end

# Resolve an IROperand to exactly 64 wires. For ConstOperand, materialize the
# value with NOT gates. For SSAOperand, zero-extend via CNOT-copy.
function _operand_to_u64!(ctx::LoweringCtx, op::IROperand)
    if op isa ConstOperand
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
            throw(AssertionError("_operand_to_u64!: undefined SSA %$(op.name)"))
        return _wires_to_u64!(ctx, ctx.vw[op.name])
    end
end