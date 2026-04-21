# T5-P6 Proposer A — `:persistent_tree` dispatcher arm

**Bead**: Bennett-z2dj (T5-P6). Labels: `3plus1,core`.
**Author**: Proposer A (independent; has not seen Proposer B).
**Date**: 2026-04-21.
**Scope**: Minimum T5-P6 — add `:persistent_tree` arm to
`_pick_alloca_strategy`, extend `lower_alloca!` / store / load to thread
dynamic-alloca state through a registered persistent-DS callee, and add
the `mem=` / `persistent_impl=` / `hashcons=` user kwargs on
`reversible_compile`. Default impl is `:linear_scan` per the sweep
finding in WORKLOG.md (2026-04-20 "Persistent-DS scaling sweep":
`linear_scan` beats HAMT, CF, Okasaki at every `N` ≤ 1000).

The bead description is aspirational; this doc reflects the real
codebase as of commit `4729656`. Ground-truth corrections from the brief
(TJ3 already GREEN; TJ1/TJ2/TJ4 fail at `ir_extract` not the dispatcher;
`lower_alloca!` itself must change; default must be `:linear_scan`) are
honoured.

---

## 1. Scope statement

### In scope

1. **One new dispatcher arm**: `:persistent_tree` returned from
   `_pick_alloca_strategy` when `n_elems.kind == :ssa` AND no other arm
   claims the shape.
2. **Extended `lower_alloca!`** that accepts dynamic `n_elems` when the
   active `mem=` configuration selects a persistent impl. On dynamic
   n_elems it:
   - records the (elem_width, `:dynamic`) shape in `alloca_info`,
   - allocates a fresh "state bundle" of wires whose size equals the
     statically-known `state_bits` of the configured impl's
     `pmap_new()` NTuple,
   - emits an `IRCall` to the impl's `pmap_new` callee, seeding the
     bundle to all-zero (this is the persistent-DS equivalent of "the
     alloca is zero-initialised by WireAllocator invariant").
3. **New `_lower_store_via_persistent!`** that emits an `IRCall` to
   `<impl>_pmap_set(state, key, value)`, rebinding the alloca bundle to
   the callee's output wires (exactly mirroring the existing
   `_lower_store_via_mux_*!` pattern around line 2419 of `lower.jl`).
4. **New `_lower_load_via_persistent!`** that emits an `IRCall` to
   `<impl>_pmap_get(state, key)` and binds `inst.dest` to the ret value.
5. **New `reversible_compile` kwargs**: `mem::Symbol=:classical`,
   `persistent_impl::Symbol=:linear_scan`,
   `hashcons::Symbol=:none`. Validated up front with clear errors.
   Threaded through `lower` → `LoweringCtx` → the two new lowering
   helpers.
6. **Registration of the new callees** via `register_callee!` in
   `src/Bennett.jl`, keyed on the impl name (only `:linear_scan` is
   wired in the MVP; `:hamt` / `:okasaki` / `:cf` register but are
   accepted by the dispatcher with the same mechanical pattern — the
   MVP's `:hamt` callee path is covered by a RED @test_throws that
   names the bead to follow up under).
7. **RED → GREEN acceptance test** at
   `test/test_t5_p6_persistent_dispatch.jl`, built on the
   `_compile_ir` pattern from `test_universal_dispatch.jl`. Tests both
   the dispatcher picks and the end-to-end hand-crafted `.ll`
   round-trip.
8. **Regression plan**: every existing `_pick_alloca_strategy` test and
   every BENCHMARKS.md row stays byte-identical (verified with a
   dedicated spot-check script).

### Out of scope

- **TJ1/TJ2 / Julia-level `Vector`, `Dict`**: the bead claims these
  flip GREEN but they fail in `ir_extract.jl` at
  `LLVMGlobalAliasValueKind` (WORKLOG §NEXT AGENT). Out of scope.
- **TJ4 / `Array{Int8}(undef, 256)`**: fails at `thread_ptr` GEP
  pre-dispatcher (cc0.5). Out of scope.
- **Rust cross-context parser** (Bennett-i3nj) — disjoint.
- **Multi-origin × persistent-DS**: fail loud with a crisp message
  and a follow-up bead pointer; defer to a future milestone.
- **Parametric `max_n`**: the impl's `max_n` is baked into NTuple size
  at definition (`_LS_MAX_N = 4` for linear_scan). If a dynamic alloca
  needs more, we fail loud at dispatcher time — the user sees
  "persistent impl `:linear_scan` max_n=4 cannot cover this alloca;
  pass `max_n_hint=...` or choose a larger impl".
- **HAMT / Okasaki / CF default wiring**: the impl registrations that
  already exist (`HAMT_IMPL`, `OKASAKI_IMPL`, `CF_IMPL`) are *reachable*
  via `persistent_impl=:hamt|:okasaki|:cf` kwargs, but only
  `:linear_scan` is exercised by the RED→GREEN test. The other three
  get a single each smoke test (compilation succeeds; correctness
  already covered by existing per-impl tests).
- **Bounded-Vector max_n inference**: keep the MVP pure-static. Every
  other tier has a compile-time shape; we require the user (or a
  future IR-level analysis) to size the impl via the kwarg. If their
  program would overflow, the dispatcher errors at the first
  dynamic-bounded alloca, not silently corrupts state.
- **Hashcons**: the kwarg lands with `:none` / `:naive` / `:feistel`
  validated; the non-`:none` arms call
  `_wrap_callee_with_hashcons(impl, mode)` which for the MVP raises
  `error("hashcons=$mode is NYI for persistent_impl=$impl; track in
  Bennett-gv8g / Bennett-7pgw")`. This keeps the signature stable so
  M5.4 can light up the arms without another interface break.

---

## 2. Dispatcher change

### 2.1 Signature decision — keep the current signature

`_pick_alloca_strategy(shape, idx)` today takes `shape::Tuple{Int,Int}`
and `idx::IROperand`. For `:persistent_tree` we need two extra signals:

- **Is this alloca actually dynamic?** `n_elems.kind == :ssa`
  (observable from the shape: we encode a sentinel `n = -1` to signal
  "dynamic" in the shape slot, matching the convention that currently
  can't occur).
- **What persistent impl is configured?** Currently the dispatcher has
  no access to user kwargs.

**Chosen approach**: keep the `(shape, idx)` signature for the callers
that already use it (there are multiple call sites across the load and
store paths, and third-party `test/test_universal_dispatch.jl` pins the
signature). Instead, add a **companion function**:

```julia
"""
    _pick_alloca_strategy_dynamic(elem_width::Int, cfg::PersistentConfig,
                                  idx::IROperand) -> Symbol
"""
function _pick_alloca_strategy_dynamic(elem_width::Int,
                                       cfg::PersistentConfig,
                                       idx::IROperand)::Symbol
    cfg.mem == :classical && return :unsupported_dynamic
    return :persistent_tree
end
```

The load/store paths call `_pick_alloca_strategy` first; if and only if
it returns `:unsupported` AND the shape slot in `alloca_info` is marked
dynamic, they fall through to `_pick_alloca_strategy_dynamic`. That
keeps the existing signature untouched — no cascading churn through
`test_universal_dispatch.jl` — while letting the dispatcher route the
new arm.

Why not a three-value return? Because callers already switch on the
returned symbol with `elseif` cascades; adding a 10th symbol is
mechanically lower-risk than widening the input tuple. The M3a
precedent (adding `:shadow_checkpoint`) did exactly this — a new
symbol, no signature change.

### 2.2 `PersistentConfig` — threaded through `LoweringCtx`

```julia
# src/lower.jl (new struct, declared near LoweringCtx)

"""Bundle of T5-P6 user kwargs passed through `reversible_compile`.

Default `(mem=:classical, impl=:linear_scan, hashcons=:none)` is a
behaviour-preserving no-op: classical mem means every alloca follows
the T0–T4 path exactly as it does today."""
struct PersistentConfig
    mem::Symbol          # :classical | :persistent
    impl::Symbol         # :linear_scan | :hamt | :okasaki | :cf
    hashcons::Symbol     # :none | :naive | :feistel
end

const DEFAULT_PERSISTENT_CONFIG =
    PersistentConfig(:classical, :linear_scan, :none)

function validate_persistent_config(cfg::PersistentConfig)
    cfg.mem in (:classical, :persistent) ||
        error("reversible_compile: mem=:$(cfg.mem) invalid; " *
              "supported: :classical, :persistent")
    cfg.impl in (:linear_scan, :hamt, :okasaki, :cf) ||
        error("reversible_compile: persistent_impl=:$(cfg.impl) invalid; " *
              "supported: :linear_scan (default, winner per sweep), " *
              ":hamt, :okasaki, :cf")
    cfg.hashcons in (:none, :naive, :feistel) ||
        error("reversible_compile: hashcons=:$(cfg.hashcons) invalid; " *
              "supported: :none (default), :naive, :feistel")
    return cfg
end
```

A new field `persistent::PersistentConfig` lands on `LoweringCtx`.
Backward-compat constructors default it to
`DEFAULT_PERSISTENT_CONFIG` so every pre-T5-P6 call site is unaffected.
The config is read only in `lower_alloca!`, `_lower_store_single_origin!`
(and the load analogue), and the two new `_lower_*_via_persistent!`
helpers.

### 2.3 Full decision tree for the combined dispatcher

Pseudocode for the post-T5-P6 combined picker:

```
given (alloca_dest, idx_op, cfg):
  info = alloca_info[alloca_dest]            # now (elem_w, n_or_DYN)
  elem_w, n_slot = info
  is_dynamic = (n_slot == DYNAMIC_N)        # sentinel: -1

  if !is_dynamic:
    return _pick_alloca_strategy((elem_w, n_slot), idx_op)
    # ↑ current arm set: :shadow, :mux_exch_*, :shadow_checkpoint, :unsupported

  # Dynamic n_elems: persistent-DS territory
  if cfg.mem == :classical:
    error("lower_alloca!: dynamic n_elems not supported (legacy behaviour); " *
          "pass `mem=:persistent` to route through the T5 persistent tier")

  # mem == :persistent
  return :persistent_tree
```

Shape-slot encoding: store a dynamic alloca as
`alloca_info[dest] = (elem_w, -1)` (the `DYNAMIC_N` sentinel).
Classical callers that ever see `-1` in `alloca_info` are the old arms
that used to read `n_slot`; they all go through
`_pick_alloca_strategy`, which now handles the sentinel by delegating
to the dynamic path:

```julia
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand)
    if shape[2] == DYNAMIC_N          # T5-P6 sentinel
        return :persistent_tree       # — caller inspects ctx.persistent
                                      # to pick the impl-specific route
    end
    # ... existing body unchanged ...
end
```

This means **the existing tests in `test_universal_dispatch.jl` are
strictly preserved** (the sentinel `-1` is never synthesised by them;
they call with `(8, 4)` / `(16, 8)` / etc.), while any caller routed
here from a dynamic alloca sees the new arm.

**Rationale for the sentinel** (vs. an `alloca_info` value-shape
refactor): the alternative is widening `alloca_info` to
`Dict{Symbol, AllocaShape}` with an abstract type. That's an
`ir_types.jl`-level change, breaks every existing
`Tuple{Int,Int}`-indexed access across `lower.jl` (at least 12 call
sites per grep), and crosses the 3+1 threshold *for the refactor
alone*. The sentinel buys us the same behaviour with a single-line
conditional, and a `const DYNAMIC_N = -1` at module top. Implementer
can search-and-replace the sentinel to a proper enum later.

### 2.4 Dispatcher trigger — full table

| `n_elems.kind` | `elem_w × n_elems` | `idx` | Arm returned |
|---|---|---|---|
| `:const` | any | `:const` | `:shadow` (unchanged) |
| `:const` | `≤ 64 bits`, known | `:ssa` | `:mux_exch_NxW` (unchanged) |
| `:const` | `> 64 bits`, known | `:ssa` | `:shadow_checkpoint` (unchanged) |
| `:ssa` | n/a | any | `:persistent_tree` (**NEW**) |

No existing combination migrates to the new arm; it is strictly
additive. This satisfies the M3a regression invariant.

---

## 3. `lower_alloca!` change

### 3.1 Current body (lines 1949–1969, unchanged context)

```julia
function lower_alloca!(ctx::LoweringCtx, inst::IRAlloca)
    inst.n_elems.kind == :const ||
        error("lower_alloca!: dynamic n_elems not supported (%$(inst.n_elems.name)); " *
              "T3b.3 shadow memory handles static-sized allocas only.")
    n = inst.n_elems.value
    n >= 1 || error("lower_alloca!: non-positive n_elems=$n")
    # ... allocate, record, ptr_provenance ...
end
```

This is the **hard-error site** for TJ4 and for any hand-crafted `.ll`
with `alloca i8, i32 %n`. The T5-P6 change turns the error into a
dispatcher arm.

### 3.2 Post-T5-P6 body

```julia
function lower_alloca!(ctx::LoweringCtx, inst::IRAlloca)
    if inst.n_elems.kind == :const
        # Classical path — unchanged
        n = inst.n_elems.value
        n >= 1 || error("lower_alloca!: non-positive n_elems=$n")
        inst.elem_width >= 1 ||
            error("lower_alloca!: non-positive elem_width=$(inst.elem_width)")
        total_bits = inst.elem_width * n
        wires = allocate!(ctx.wa, total_bits)
        ctx.vw[inst.dest] = wires
        ctx.alloca_info[inst.dest] = (inst.elem_width, n)
        ctx.ptr_provenance[inst.dest] = [PtrOrigin(inst.dest, iconst(0),
                                                   _entry_predicate_wire(ctx))]
        return nothing
    end

    # Dynamic n_elems — T5-P6 persistent-DS path
    ctx.persistent.mem == :persistent ||
        error("lower_alloca!: dynamic n_elems (%$(inst.n_elems.name)) but " *
              "mem=:classical. Pass `mem=:persistent` to reversible_compile " *
              "to route through the T5 persistent tier. (T5-P6 / Bennett-z2dj)")

    impl = _impl_registry(ctx.persistent.impl)
    inst.elem_width == 8 ||
        error("lower_alloca!: T5-P6 MVP supports elem_width=8 only; " *
              "got $(inst.elem_width). File a follow-up bd issue.")
    # NOTE: elem_width=8 matches the linear_scan impl's Int8 K/V; widening
    # is a parametric-impl question tracked as future work.

    state_bits = _impl_state_bits(impl)    # 9 * 64 = 576 for linear_scan
    state_sym = Symbol("__pmap_state_", inst.dest)

    # Allocate a fresh state bundle (all zeros by WireAllocator invariant)
    # and emit a pmap_new call to initialise it. pmap_new returns an NTuple
    # of zeros so the CNOT-copy pattern in lower_call! yields the same
    # zero-init — but we go through the callee explicitly so the state
    # bundle's provenance is a real SSA value, not a raw alloca slice.
    call = IRCall(state_sym, _pmap_new_callee(impl),
                  IROperand[], Int[], state_bits)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    # The alloca's "wire bundle" IS the persistent-state bundle
    ctx.vw[inst.dest]     = ctx.vw[state_sym]
    ctx.alloca_info[inst.dest] = (inst.elem_width, DYNAMIC_N)

    # T5-P6 marker: record the persistent-state SSA name + impl so
    # subsequent store/load lowering can route. No ptr_provenance
    # analogue — the "pointer" to a persistent map is the state bundle
    # itself, not an offset into a concrete wire array.
    ctx.persistent_alloca[inst.dest] =
        PersistentAllocaInfo(state_sym, impl)

    # Still record a 1-origin ptr_provenance entry so downstream GEP /
    # phi plumbing doesn't crash on the unknown key. idx_op is a
    # sentinel "dynamic"; the predicate_wire is the entry-block one.
    ctx.ptr_provenance[inst.dest] = [PtrOrigin(inst.dest,
                                               ssa(Symbol("__dyn")),
                                               _entry_predicate_wire(ctx))]
    return nothing
end
```

### 3.3 New supporting state

Two additions to `LoweringCtx`:

```julia
struct PersistentAllocaInfo
    state_sym::Symbol            # current SSA name for the state bundle
    impl::PersistentMapImpl      # bound at dispatcher time, immutable
end

# Added field on LoweringCtx:
#   persistent::PersistentConfig
#   persistent_alloca::Dict{Symbol, PersistentAllocaInfo}
```

The `state_sym` is **mutable across the lowering of a basic block** —
after each `pmap_set` the state is rebound to a fresh SSA name and
`ctx.persistent_alloca[alloca_dest]` updates. This mirrors the
existing MUX EXCH pattern (around line 2419):

```julia
ctx.vw[alloca_dest] = ctx.vw[res_sym][1:32]   # MUX EXCH, existing
# — our analogue —
ctx.persistent_alloca[alloca_dest] =
    PersistentAllocaInfo(res_sym, impl)
ctx.vw[alloca_dest] = ctx.vw[res_sym]        # rebind the bundle too
```

### 3.4 `_impl_registry` / `_impl_state_bits` / `_pmap_new_callee`

These wrappers keep the per-impl knowledge in one table so the
dispatcher doesn't grow an if-ladder every time a new impl lands:

```julia
const _IMPL_TABLE = Dict{Symbol, PersistentMapImpl}(
    :linear_scan => LINEAR_SCAN_IMPL,
    :okasaki     => OKASAKI_IMPL,
    :cf          => CF_IMPL,
    :hamt        => HAMT_IMPL,
)

function _impl_registry(name::Symbol)::PersistentMapImpl
    haskey(_IMPL_TABLE, name) ||
        error("_impl_registry: impl :$name not registered; " *
              "supported: $(sort(collect(keys(_IMPL_TABLE))))")
    return _IMPL_TABLE[name]
end

"""NTuple{N,UInt64} state ⇒ bit count = N*64."""
function _impl_state_bits(impl::PersistentMapImpl)::Int
    # Inspect pmap_new's return type. For LINEAR_SCAN_IMPL this is
    # NTuple{9, UInt64} ⇒ 576. The type is known statically.
    rt = Base.return_types(impl.pmap_new, Tuple{})[1]
    # rt is NTuple{N, UInt64}. Extract N via rt.parameters[1]; assert UInt64.
    rt <: NTuple{N,UInt64} where {N} ||
        error("_impl_state_bits: impl $(impl.name) pmap_new returns " *
              "$(rt); must be NTuple{N, UInt64}")
    return fieldcount(rt) * 64
end

_pmap_new_callee(impl::PersistentMapImpl) = impl.pmap_new
_pmap_set_callee(impl::PersistentMapImpl) = impl.pmap_set
_pmap_get_callee(impl::PersistentMapImpl) = impl.pmap_get
```

**Caveat** flagged honestly: `Base.return_types` depends on inference
and may be fragile. An alternative is to bake the `state_bits` into
the `PersistentMapImpl` struct at definition time — a two-line
addition to `interface.jl`. The implementer should prefer that: bake
`state_bits::Int` into `PersistentMapImpl`, compute it at the impl-
file level with `sizeof(LinearScanState) * 8`. This is a *mechanical*
change to four files (`interface.jl`, `linear_scan.jl`,
`okasaki_rbt.jl`, `cf_semi_persistent.jl`, `hamt.jl`). The sentinel
`_impl_state_bits` function above is a fallback if that cross-file
change exceeds scope for the implementer.

---

## 4. Store / load lowering

### 4.1 `_lower_store_via_persistent!`

Structurally identical to `_lower_store_via_mux_4x8!` at line 2388: we
build an `IRCall` to `<impl>_pmap_set(state, key, val)` and rebind
both `ctx.vw[alloca_dest]` and `ctx.persistent_alloca[alloca_dest]`.

```julia
"""Bennett-z2dj (T5-P6) — dynamic-alloca store via persistent-DS callee.

The idx operand is the key K; inst.val is the value V. The callee is
`<impl>_pmap_set(state, key, value)` — registered via
`register_callee!` at module init. We pack the inputs into the widths
the callee expects (UInt64 for state words, K/V-width for key/val),
emit the IRCall, and rebind the alloca's wire bundle + persistent-state
SSA symbol to the result."""
function _lower_store_via_persistent!(ctx::LoweringCtx, inst::IRStore,
                                      alloca_dest::Symbol,
                                      info::Tuple{Int,Int},
                                      idx_op::IROperand,
                                      block_label::Symbol)
    pinfo = ctx.persistent_alloca[alloca_dest]
    impl  = pinfo.impl

    # Hashcons guard: non-:none modes are NYI in MVP.
    ctx.persistent.hashcons == :none ||
        error("_lower_store_via_persistent!: hashcons=:$(ctx.persistent.hashcons) " *
              "is NYI for persistent_impl=:$(impl.name); track in " *
              "Bennett-gv8g (naive) / Bennett-7pgw (feistel)")

    elem_w, _ = info
    elem_w == 8 ||
        error("_lower_store_via_persistent!: only elem_width=8 in T5-P6 MVP")
    key_width = 8 * sizeof(impl.K)    # Int8 ⇒ 8
    val_width = 8 * sizeof(impl.V)    # Int8 ⇒ 8

    # Block-guard: match the _lower_store_via_shadow! discipline. Non-entry
    # blocks need path-predicate guarding against false-path sensitisation
    # (CLAUDE.md §"Phi Resolution and Control Flow — CORRECTNESS RISK").
    use_block_guard = !(block_label == Symbol("") ||
                        block_label == ctx.entry_label)
    use_block_guard &&
        error("_lower_store_via_persistent!: non-entry-block store is NYI " *
              "in T5-P6 MVP. Track as follow-up bd: needs guarded " *
              "<impl>_pmap_set variant or a select-based predication " *
              "(old_state, new_state, block_pred).")

    tag = _next_mux_tag!(ctx, "pset", inst.ptr.name)
    new_state_sym = Symbol("__pmap_set_res_", tag)

    call = IRCall(new_state_sym, _pmap_set_callee(impl),
                  [ssa(pinfo.state_sym), idx_op, inst.val],
                  [_impl_state_bits(impl), key_width, val_width],
                  _impl_state_bits(impl))
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    # Rebind: new state becomes the current one.
    ctx.vw[alloca_dest] = ctx.vw[new_state_sym]
    ctx.persistent_alloca[alloca_dest] = PersistentAllocaInfo(new_state_sym, impl)
    return nothing
end
```

The block-guard branch is a fail-loud stub; the implementer can
either (a) add a guarded `<impl>_pmap_set_guarded(state, k, v, pred)`
callee that no-ops when `pred=0`, or (b) emit a select over
(`old_state`, `new_state`) on the block predicate — both are proper
follow-up beads. The MVP's acceptance test does not exercise a
non-entry-block store.

### 4.2 `_lower_load_via_persistent!`

```julia
"""Bennett-z2dj (T5-P6) — dynamic-alloca load via persistent-DS callee."""
function _lower_load_via_persistent!(ctx::LoweringCtx, inst::IRLoad,
                                     alloca_dest::Symbol,
                                     info::Tuple{Int,Int},
                                     idx_op::IROperand)
    pinfo = ctx.persistent_alloca[alloca_dest]
    impl  = pinfo.impl

    ctx.persistent.hashcons == :none ||
        error("_lower_load_via_persistent!: hashcons=:$(ctx.persistent.hashcons) NYI")

    elem_w, _ = info
    elem_w == 8 ||
        error("_lower_load_via_persistent!: only elem_width=8 in MVP")
    W = inst.width
    W == 8 * sizeof(impl.V) ||
        error("_lower_load_via_persistent!: load width=$W doesn't match impl V width")
    key_width = 8 * sizeof(impl.K)

    tag = _next_mux_tag!(ctx, "pget", inst.dest)
    res_sym = Symbol("__pmap_get_res_", tag)

    call = IRCall(res_sym, _pmap_get_callee(impl),
                  [ssa(pinfo.state_sym), idx_op],
                  [_impl_state_bits(impl), key_width],
                  W)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    ctx.vw[inst.dest] = ctx.vw[res_sym][1:W]
    return nothing
end
```

### 4.3 Wiring into the existing dispatch

Add exactly one arm each to `_lower_store_single_origin!` (around
line 2108) and `_lower_load_via_mux!` (around line 1708):

```julia
# In _lower_store_single_origin!, just before the final error:
elseif strategy == :persistent_tree
    _lower_store_via_persistent!(ctx, inst, alloca_dest, info, idx_op, block_label)

# In _lower_load_via_mux!, just before the final error:
elseif strategy == :persistent_tree
    return _lower_load_via_persistent!(ctx, inst, alloca_dest, info, idx_op)
```

The `strategy` value comes through naturally: when
`alloca_info[alloca_dest][2] == DYNAMIC_N`, `_pick_alloca_strategy`
returns `:persistent_tree`. The single-origin path is untouched for
classical shapes; the new arm is only hit for dynamic allocas.

### 4.4 Why `IRCall` instead of direct wire fan-out

The persistent-DS impls (`linear_scan_pmap_set`, `okasaki_pmap_set`,
...) are already registered as callees (they're the exact functions
`test_persistent_*.jl` pass to `reversible_compile`). The compiler's
existing `lower_call!` (line 1865) does everything we need: pre-
compiles the callee, inserts forward-only gates with wire offset,
connects caller inputs via CNOT-copy, binds outputs to the caller's
vw. No new gate types, no new lowering helper beyond the thin `IRCall`
emitter. This is the *same* pattern `_lower_store_via_mux_4x8!` uses
for `soft_mux_store_4x8`.

### 4.5 Ancilla hygiene

Bennett's construction (reverse pass) uncomputes every forward gate.
Because `pmap_set` / `pmap_get` are pure functions (no side effects, no
external callee state), Bennett's post-copy reverse fully restores the
state bundle to zero. The state bundle is allocated per-alloca via
`pmap_new`, which is itself a callee whose reverse pass zeroes its
output — this is exactly why the brief says "the version chain is the
allocation history" (T5-PRD §2).

Verification: the acceptance test `@test verify_reversibility(c)`
catches any ancilla leak. Every existing persistent-DS demo test
(`test_persistent_interface.jl`, `test_persistent_cf.jl`) confirms
Bennett's reverse pass is complete on these callees.

---

## 5. `reversible_compile` kwargs

### 5.1 Full new signature

```julia
# src/Bennett.jl — Julia-function path
function reversible_compile(f, arg_types::Type{<:Tuple};
                            optimize::Bool=true, max_loop_iterations::Int=0,
                            compact_calls::Bool=false, bit_width::Int=0,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            strategy::Symbol=:auto,
                            # T5-P6 NEW:
                            mem::Symbol=:classical,
                            persistent_impl::Symbol=:linear_scan,
                            hashcons::Symbol=:none)
    # ... existing validation up to strategy ...
    cfg = validate_persistent_config(PersistentConfig(mem, persistent_impl, hashcons))
    # ... pass `cfg` into `lower(parsed; persistent=cfg, ...)`
end

# ParsedIR overload — same three kwargs added
function reversible_compile(parsed::ParsedIR;
                            max_loop_iterations::Int=0,
                            compact_calls::Bool=false,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            mem::Symbol=:classical,
                            persistent_impl::Symbol=:linear_scan,
                            hashcons::Symbol=:none)
    cfg = validate_persistent_config(PersistentConfig(mem, persistent_impl, hashcons))
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul, persistent=cfg)
    return bennett(lr)
end

# lower() signature extension
function lower(parsed::ParsedIR;
               max_loop_iterations::Int=0, use_inplace::Bool=true,
               use_karatsuba::Bool=false, fold_constants::Bool=false,
               compact_calls::Bool=false, add::Symbol=:auto, mul::Symbol=:auto,
               persistent::PersistentConfig=DEFAULT_PERSISTENT_CONFIG)
    # ... pass `persistent` into LoweringCtx ...
end
```

### 5.2 Defaults

Per the sweep (WORKLOG 2026-04-20 "Persistent-DS scaling sweep"):

- `mem=:classical` — preserves 100% of pre-T5-P6 behaviour. BENCHMARKS
  byte-identical.
- `persistent_impl=:linear_scan` — winner at every `N ≤ 1000`. HAMT,
  CF, Okasaki are reachable but slower.
- `hashcons=:none` — no compression; the compressed paths are M5.4
  work.

**No user needs to opt into `mem=:persistent` for any existing test
to pass.** The flag exists to unlock dynamic-alloca patterns that
today hard-error.

### 5.3 Validation

`validate_persistent_config` fails fast on unknown symbols.
Additionally: when `mem=:classical` but `persistent_impl` is
non-default, warn (don't error — the user may be pre-setting it for a
later `reversible_compile` invocation). Actually, simpler: silently
honour it; the flag only fires when `mem=:persistent`. Printing a
warning adds noise without value.

Exception: **`mem=:persistent` with `persistent_impl=:hamt|:okasaki|:cf`
in the MVP** — these are wired through the callee-registration table
but the MVP only exercises `:linear_scan` in the acceptance test. For
the non-linear-scan impls, a single smoke test confirms the
dispatcher routes correctly (compilation succeeds on a 3-set + 1-get
demo). If the smoke test reveals a callee-layout mismatch, the
implementer files a follow-up bd issue and flags `:hamt` / `:okasaki`
/ `:cf` as "NYI via dispatcher; use the impl function directly" in
the error message. **This is the tolerated MVP incompleteness**; the
hooks are in place for M5.4 to fill them in.

### 5.4 ParsedIR overload — why it matters

P5a / P5b just landed (WORKLOG 2026-04-21). The C corpus fixtures
(TC1/TC2/TC3 at `test/test_t5_corpus_c.jl`) extract successfully but
fail at `lower` today. They go through
`reversible_compile(parsed::ParsedIR; ...)`. Adding `mem=:persistent`
to that overload is **the mechanism that flips the C corpus GREEN in a
later session** (the acceptance test in this PRD doesn't exercise the
C fixtures, but the plumbing must be there).

---

## 6. RED test (full file content)

Filename: `test/test_t5_p6_persistent_dispatch.jl`. Included from
`test/runtests.jl` via the usual `include` pattern.

```julia
using Test
using Bennett
using LLVM

# T5-P6 (Bennett-z2dj) — `:persistent_tree` dispatcher arm.
#
# RED→GREEN TDD.  First section gates the dispatcher-picker contract
# (pure-function tests — no compilation).  Second section gates the
# end-to-end hand-crafted .ll round-trip through `_compile_ir`, which
# mirrors the existing test_universal_dispatch.jl pattern.

function _compile_ir(ir_string::String; kwargs...)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        parsed = Bennett._module_to_parsed_ir(mod)
        c = reversible_compile(parsed; kwargs...)
        dispose(mod)
    end
    return c
end

@testset "T5-P6 — persistent_tree dispatcher arm" begin

    # ───────────────────────────────────────────────────────────────
    # Section A — dispatcher-picker unit tests
    # ───────────────────────────────────────────────────────────────

    @testset "picker returns :persistent_tree for dynamic n_elems" begin
        # Sentinel -1 in the second slot signals dynamic n_elems.
        # (elem_width=8, dynamic) with any idx kind.
        @test Bennett._pick_alloca_strategy((8, Bennett.DYNAMIC_N), Bennett.ssa(:idx)) ==
              :persistent_tree
        @test Bennett._pick_alloca_strategy((8, Bennett.DYNAMIC_N), Bennett.iconst(3)) ==
              :persistent_tree
    end

    @testset "picker regression: static arms unaffected" begin
        @test Bennett._pick_alloca_strategy((8, 4), Bennett.iconst(2)) == :shadow
        @test Bennett._pick_alloca_strategy((8, 4), Bennett.ssa(:idx)) == :mux_exch_4x8
        @test Bennett._pick_alloca_strategy((8, 100), Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((16, 2), Bennett.ssa(:idx)) == :mux_exch_2x16
    end

    @testset "persistent config validates" begin
        # Good configs
        @test Bennett.validate_persistent_config(
            Bennett.PersistentConfig(:classical, :linear_scan, :none)) isa
            Bennett.PersistentConfig
        @test Bennett.validate_persistent_config(
            Bennett.PersistentConfig(:persistent, :linear_scan, :none)) isa
            Bennett.PersistentConfig

        # Bad symbols fail loud
        @test_throws ErrorException Bennett.validate_persistent_config(
            Bennett.PersistentConfig(:nonsense, :linear_scan, :none))
        @test_throws ErrorException Bennett.validate_persistent_config(
            Bennett.PersistentConfig(:persistent, :bogus_impl, :none))
        @test_throws ErrorException Bennett.validate_persistent_config(
            Bennett.PersistentConfig(:persistent, :linear_scan, :weird))
    end

    # ───────────────────────────────────────────────────────────────
    # Section B — hand-crafted .ll end-to-end
    # ───────────────────────────────────────────────────────────────

    @testset "dynamic alloca + 3 inserts + 1 get, linear_scan impl" begin
        # Hand-crafted IR: the n_elems for the alloca is SSA (dynamic).
        # We insert 3 keys (indices 0, 1, 2) and read back index 2.
        # With linear_scan (max_n=4, overwrite at last slot on overflow),
        # the final state should have v3 at key=2 — so the read returns v3.
        ir = raw"""
        define i8 @julia_persistent_demo_1(i8 %k1, i8 %v1, i8 %k2, i8 %v2,
                                           i8 %k3, i8 %v3, i8 %lookup, i32 %n) {
        top:
          %p  = alloca i8, i32 %n
          %g0 = getelementptr i8, ptr %p, i32 0
          %g1 = getelementptr i8, ptr %p, i32 1
          %g2 = getelementptr i8, ptr %p, i32 2
          ; Static-idx stores into a dynamically-sized alloca — the
          ; dispatcher routes through :persistent_tree because the
          ; alloca's n_elems is dynamic.
          store i8 %v1, ptr %g0
          store i8 %v2, ptr %g1
          store i8 %v3, ptr %g2
          %idx = zext i8 %lookup to i32
          %gvar = getelementptr i8, ptr %p, i32 %idx
          %r = load i8, ptr %gvar
          ret i8 %r
        }
        """

        # RED today: lower_alloca! errors on dynamic n_elems under :classical.
        @test_throws ErrorException _compile_ir(ir)

        # Under :persistent (linear_scan default) — GREEN after T5-P6 lands.
        c = _compile_ir(ir; mem=:persistent, persistent_impl=:linear_scan)
        @test verify_reversibility(c)

        # Semantic check: hand-crafted IR uses STATIC indices 0, 1, 2 for the
        # three stores and a RUNTIME-dynamic `%lookup` for the load. The keys
        # the persistent map sees are the *store offsets* (0, 1, 2, because
        # our GEP-origin plumbing passes `idx_op` as the slot index to
        # `_lower_store_via_persistent!`). The value at slot=2 is %v3.
        #
        # Map semantics (linear_scan):
        #   state.set(k1=?, v1=?) — wait: with static GEP indices, the 3
        #   stores are *writing into slots 0, 1, 2 of the persistent map
        #   using the slot index itself as the key*. That means:
        #       pmap_set(state, key=0, val=v1)
        #       pmap_set(state, key=1, val=v2)
        #       pmap_set(state, key=2, val=v3)
        #   Then the load is pmap_get(state, key=lookup).
        #
        # Reference: Dict{Int8, Int8}.
        function ref(k1, v1, k2, v2, k3, v3, lookup, n)
            d = Dict{Int8, Int8}()
            d[Int8(0)] = v1
            d[Int8(1)] = v2
            d[Int8(2)] = v3
            return get(d, Int8(lookup), Int8(0))
        end

        # Sample a handful of concrete inputs
        for lookup in Int8[0, 1, 2, 3, -1]
            args = (Int8(10), Int8(21),      # k1 (unused), v1
                    Int8(20), Int8(42),      # k2 (unused), v2
                    Int8(30), Int8(99),      # k3 (unused), v3
                    lookup,
                    Int8(8))                 # %n (dynamic alloca size hint)
            got = simulate(c, args)
            expected = ref(args...)
            @test got == expected
        end
    end

    @testset "dynamic alloca under :classical still errors (regression)" begin
        # The *default* kwarg set should NOT silently enable the new arm.
        # A dynamic alloca under :classical must still fail loud.
        ir = raw"""
        define i8 @julia_persistent_demo_2(i8 %v, i8 %lookup, i32 %n) {
        top:
          %p  = alloca i8, i32 %n
          %g0 = getelementptr i8, ptr %p, i32 0
          store i8 %v, ptr %g0
          %idx = zext i8 %lookup to i32
          %gvar = getelementptr i8, ptr %p, i32 %idx
          %r = load i8, ptr %gvar
          ret i8 %r
        }
        """
        # Must error with a message about the persistent kwarg hint.
        try
            _compile_ir(ir)
            @test false  # should not reach here
        catch e
            @test e isa ErrorException
            @test occursin("mem=:persistent", sprint(showerror, e))
        end
    end

    @testset "non-linear-scan impl smoke tests" begin
        # Thin smoke: compile succeeds on the same IR under each alt impl,
        # :hamt / :okasaki / :cf. Each of these has a full-fat test elsewhere
        # (test_persistent_hamt / okasaki / cf). Here we gate only that
        # the dispatcher routes correctly.
        ir = raw"""
        define i8 @julia_persistent_demo_alt(i8 %v, i8 %lookup, i32 %n) {
        top:
          %p  = alloca i8, i32 %n
          %g0 = getelementptr i8, ptr %p, i32 0
          store i8 %v, ptr %g0
          %idx = zext i8 %lookup to i32
          %gvar = getelementptr i8, ptr %p, i32 %idx
          %r = load i8, ptr %gvar
          ret i8 %r
        }
        """
        for impl_name in (:okasaki, :cf)
            c = _compile_ir(ir; mem=:persistent, persistent_impl=impl_name)
            @test verify_reversibility(c)
        end
        # HAMT may be too heavy for a cheap smoke test; wrap in @test_nowarn
        # and bail if the gate count is unreasonable — keep the test fast.
    end

    @testset "non-entry-block store under :persistent — fail loud (MVP limit)" begin
        # Non-entry-block stores need a guarded pmap_set or a select-over-
        # state-predicate, which is outside T5-P6 MVP scope.
        ir = raw"""
        define i8 @julia_persistent_diamond(i1 %cond, i8 %v, i8 %lookup, i32 %n) {
        top:
          %p  = alloca i8, i32 %n
          br i1 %cond, label %L1, label %L2
        L1:
          %g0 = getelementptr i8, ptr %p, i32 0
          store i8 %v, ptr %g0
          br label %join
        L2:
          br label %join
        join:
          %idx = zext i8 %lookup to i32
          %gvar = getelementptr i8, ptr %p, i32 %idx
          %r = load i8, ptr %gvar
          ret i8 %r
        }
        """
        @test_throws ErrorException _compile_ir(ir;
                                                mem=:persistent,
                                                persistent_impl=:linear_scan)
    end
end
```

### 6.1 Notes on the test

1. The **semantics-of-the-store** assumption in the main test
   (static GEP indices become the map key) is a **design
   decision**, not a forced one. When we GEP `ptr %p, i32 0|1|2`, the
   `lower_ptr_offset!` path records `idx_op = iconst(0|1|2)`. That's
   what flows into `_lower_store_via_persistent!` as the key.
   *If the implementer chooses to instead use the stored value itself
   as the key* (which is semantically different, and would map to
   Dict{Int8, Int8}'s "add key=v with value=v"), the expected output
   in the test changes. The design doc commits to: **key = idx_op**,
   which keeps the persistent-DS arm consistent with the MUX EXCH and
   shadow-checkpoint arms, which also use idx_op as the "slot
   selector".

2. The **`_compile_ir` wrapper** forwards kwargs into
   `reversible_compile(parsed::ParsedIR; kwargs...)`. That overload
   is where T5-P6 adds the `mem` / `persistent_impl` / `hashcons`
   kwargs.

3. The **fail-loud test** (dynamic alloca under `:classical`) is the
   direct regression anchor for "the MVP doesn't silently enable the
   new arm".

4. The **diamond-CFG test** is per the PRD §11 R1 requirement ("every
   persistent-DS impl has at least one diamond-CFG test"). In the
   MVP, the test is `@test_throws` — we commit to non-entry-block
   stores being a follow-up. Rationale: a non-entry-block
   persistent-DS store requires a guarded `pmap_set` variant, which
   is a separate impl-level piece of work. Flipping this to GREEN is
   the next milestone.

---

## 7. Regression plan

Concrete list; every row must be byte-identical post-T5-P6.

| Test file | Byte-identical invariant |
|---|---|
| `test/test_increment.jl` | i8 `x+1` = 100 total, 28 Toffoli |
| `test/test_int16.jl` | i16 `x+1` = 204 |
| `test/test_int32.jl` | i32 `x+1` = 412 |
| `test/test_int64.jl` | i64 `x+1` = 828 |
| `test/test_polynomial.jl` | x²+3x+1 i8 = 872 |
| `test/test_universal_dispatch.jl` — "static idx → :shadow" | unchanged |
| `test/test_universal_dispatch.jl` — "dynamic idx → :mux_exch_*" | unchanged |
| `test/test_universal_dispatch.jl` — "N·W > 64 → :shadow_checkpoint" | unchanged |
| `test/test_memory_corpus.jl` — L10 | shadow_checkpoint path unchanged |
| `test/test_persistent_interface.jl` — `_ls_demo` | 436 / 90 Toff baseline |
| `test/test_persistent_cf.jl` — `_cf_demo` | 11,078 total |
| `test/test_persistent_hashcons.jl` — CF+Feistel | 65,198 |
| BENCHMARKS.md row `soft_fma` | 447,728 |
| BENCHMARKS.md row `soft_exp_julia` | 3,485,262 |
| BENCHMARKS.md row `soft_exp2_julia` | 2,697,734 |

**Why these stay byte-identical**: the T5-P6 change is strictly
additive. Every code path for static allocas is gated by
`inst.n_elems.kind == :const`, which is unchanged. The
`_pick_alloca_strategy` sentinel `DYNAMIC_N = -1` cannot be produced
by a classical alloca. The `LoweringCtx.persistent` field defaults to
`DEFAULT_PERSISTENT_CONFIG`. The `persistent_alloca::Dict` is empty
for any program without a dynamic alloca.

**Spot-check script** (implementer runs post-change, diff against
pre-change): `benchmark/run_benchmarks.jl` or a fast
`scripts/gate_count_spot_check.jl` that extracts the 15 numbers
above.

---

## 8. Risk analysis

### R1 — False-path sensitisation (phi-merged pointers + persistent-DS)

**Risk**: per CLAUDE.md §"Phi Resolution and Control Flow —
CORRECTNESS RISK", a `store` inside a non-entry block can fire
without its guard predicate being true, corrupting the persistent
state. The existing shadow and MUX-EXCH paths guard against this via
`block_label` → `block_pred` AND-reduction.

**Mitigation (MVP)**: **fail loud.** Non-entry-block stores under
`:persistent` error with a message pointing to the follow-up bead.
The acceptance test section B includes an explicit
`@test_throws` for this case. A proper fix (guarded
`<impl>_pmap_set_guarded` callee OR a select-over-state-predicate)
is a named follow-up.

**Why this is safe**: the error path means no false-path state
corruption ever lands silently. The CLAUDE.md invariant is upheld
because we refuse to compile, not because we compile wrong.

### R2 — `max_n` overflow

**Risk**: linear_scan has `_LS_MAX_N = 4`. A program that inserts 5
keys writes the 5th at slot 3, overwriting `v4`. If a user's dynamic
alloca is `%n = 100`, they'd expect 100 slots, get 4.

**Mitigation**: at `lower_alloca!` time, if the LLVM IR carries a
const-foldable upper bound on `%n` (not today, but a future analysis
could), we'd pick the right impl. For MVP: we pick the configured
impl unconditionally. **Correctness of the impl is capped at
`max_n`**, which is documented in `interface.jl`.
`verify_pmap_correctness` in `harness.jl` already tests up to
`max_n`; beyond that the impl clamps, which is the documented
"impl-defined behaviour" per protocol.

**Fail-loud alternative**: if a follow-up PRD wants stricter
semantics, the dispatcher could accept a `max_n_hint` kwarg and error
if the user's impl can't cover it. Stub for a future bead.

### R3 — Callee non-registration

**Risk**: `lower_call!` (line 1865) calls `extract_parsed_ir(callee,
arg_types)`. If the user's `persistent_impl=:hamt` but HAMT's
callees aren't registered, we'd crash deep inside ir_extract with a
confusing error.

**Mitigation**: at `validate_persistent_config`-time, check that the
impl's callees are registered:

```julia
function validate_persistent_config(cfg::PersistentConfig)
    # ... symbol checks ...
    if cfg.mem == :persistent
        impl = _impl_registry(cfg.impl)
        for f in (impl.pmap_new, impl.pmap_set, impl.pmap_get)
            is_registered_callee(f) ||
                error("validate_persistent_config: impl=:$(cfg.impl) callee " *
                      "$(nameof(f)) not registered via register_callee!. " *
                      "Check src/Bennett.jl registration block.")
        end
    end
    return cfg
end
```

This means the error surface at kwarg validation is crisp, not
buried at mid-lowering.

### R4 — State bundle size inference (`_impl_state_bits`)

**Risk**: `Base.return_types` is fragile; if Julia's inference doesn't
pin down `NTuple{9, UInt64}` for `linear_scan_pmap_new`, we'd compute
a wrong `state_bits`, misallocate wires, and crash at `lower_call!`
or (worse) silently misalign.

**Mitigation**: bake `state_bits::Int` into the `PersistentMapImpl`
struct at the impl file. Two-line change per impl (4 impls). The
design doc's fallback `_impl_state_bits` is a stopgap; the
implementer should prefer the struct field.

### R5 — Hashcons arm regression

**Risk**: the `hashcons=:none|:naive|:feistel` signature is stable
now, but if M5.4 lands a hashcons layer that silently changes
`pmap_new`'s state shape, BENCHMARKS flags a regression.

**Mitigation**: `hashcons=:none` (the default) is a no-op by
construction in this PRD — it never enters the hashcons wrapper
codepath. M5.4 adds the `:naive` / `:feistel` impls *without*
touching the `:none` path, which is our byte-identical-
default guarantee.

### R6 — Entry-point in `lower_ptr_offset!` for dynamic allocas

**Risk**: `lower_ptr_offset!` (line 1516) propagates ptr_provenance
by bumping `idx_op.value` on const idx. With a dynamic alloca, the
base alloca's origin has `idx_op = ssa(:__dyn)` (from our sentinel in
`lower_alloca!`), and the `const`-check on line 1545 skips
propagation. This means a GEP off a dynamic alloca loses its
provenance, and `_lower_store_single_origin!` errors with "no
provenance for ptr".

**Mitigation**: special-case in `lower_ptr_offset!`:

```julia
# After the existing const-idx provenance fan-out:
if ptr_provenance !== nothing && haskey(ctx.persistent_alloca, inst.base.name)
    # Dynamic-alloca GEP — propagate the persistent-impl link, not
    # the wire-offset view. The "key" is the GEP's byte offset (small
    # ints 0, 1, 2 ...), which we treat as the pmap key.
    pinfo = ctx.persistent_alloca[inst.base.name]
    ctx.persistent_alloca[inst.dest] = pinfo
    ptr_provenance[inst.dest] = [PtrOrigin(inst.base.name,
                                           iconst(inst.offset_bytes),
                                           _entry_predicate_wire(ctx))]
end
```

For `IRVarGEP` (runtime idx), an analogous block: the key is
`inst.index` (an SSA value). Flag: this requires
`lower_ptr_offset!` to take a `ctx` (not just the component
dicts) — a small signature refactor that ripples into 2 call sites.

### R7 — Implementer skips the sentinel refactor

**Risk**: if the implementer chooses the `AllocaShape` abstract-type
refactor instead of the `DYNAMIC_N` sentinel, they cross into a
broader core change that this design scoped out. Scope creep risks
the 3+1 gate for this PRD.

**Mitigation**: the design doc explicitly names the sentinel as the
in-scope approach. The implementer can note the follow-up refactor as
a bead.

---

## 9. Implementation sequence

The implementer follows these steps in order. Each step has a quick
feedback check.

### Step 1 — RED test first (CLAUDE.md §3)

Create `test/test_t5_p6_persistent_dispatch.jl` with the full content
from §6 of this doc. Include it in `test/runtests.jl`.

**Check**: run `julia --project test/test_t5_p6_persistent_dispatch.jl`.
All four testsets RED:

- Section A dispatcher-picker: `DYNAMIC_N` symbol undefined; `:persistent_tree` symbol undefined; `PersistentConfig` undefined.
- Section B: `_compile_ir` errors at `lower_alloca!: dynamic n_elems not supported`.

Record the exact error messages — they become the "before" baseline for the GREEN confirmations later.

### Step 2 — Add `PersistentConfig` + `DYNAMIC_N` + registry

In `src/lower.jl`, near the top of the file (before
`LoweringCtx`):

```julia
const DYNAMIC_N = -1

struct PersistentConfig
    mem::Symbol
    impl::Symbol
    hashcons::Symbol
end

const DEFAULT_PERSISTENT_CONFIG =
    PersistentConfig(:classical, :linear_scan, :none)

# ... validate_persistent_config as in §5.3 ...
```

In `src/persistent/persistent.jl` (or a new file
`src/persistent/registry.jl` included from there), declare
`_IMPL_TABLE` per §3.4.

**Check**: run the dispatcher unit-test section (Section A of the RED
test) — those should now pass. `julia --project -e 'using Bennett;
Bennett.validate_persistent_config(...)'` from the REPL.

### Step 3 — Extend `LoweringCtx`

Add `persistent::PersistentConfig` and
`persistent_alloca::Dict{Symbol, PersistentAllocaInfo}` fields. Add a
backward-compat constructor that defaults both. Pipe through from
`lower(parsed; persistent=...)` (new kwarg, default =
`DEFAULT_PERSISTENT_CONFIG`).

**Check**: `julia --project -e 'using Pkg; Pkg.test()'` — the suite
should still pass. Every `LoweringCtx` instantiation goes through the
backward-compat constructor, which defaults `persistent`; no behaviour
change.

### Step 4 — Extend `_pick_alloca_strategy`

Add the single `DYNAMIC_N` branch at the top:

```julia
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand)
    shape[2] == DYNAMIC_N && return :persistent_tree
    # ... existing body ...
end
```

**Check**: `julia --project test/test_t5_p6_persistent_dispatch.jl`
Section A — all pass.

### Step 5 — Update `lower_alloca!`

Per §3.2: dynamic branch fails loud under `:classical`, calls
`pmap_new` under `:persistent`, populates `persistent_alloca`, records
`(elem_w, DYNAMIC_N)` in `alloca_info`.

**Check**: the "dynamic under :classical" test in Section B should
now fail with the `mem=:persistent` hint. Section A + this one pass;
the other Section B tests still RED.

### Step 6 — Add `_lower_store_via_persistent!` + load analogue

Both functions per §4.1 / §4.2. Arm-registrations per §4.3.

**Check**: full `_compile_ir(ir; mem=:persistent, persistent_impl=:linear_scan)`
end-to-end. The main Section B testset should now compile and
`verify_reversibility`.

### Step 7 — Wire GEP provenance for dynamic allocas

Per R6: add the dynamic-alloca branch to `lower_ptr_offset!` and
`lower_var_gep!` so `%g0, %g1, %g2` get the right `persistent_alloca`
entry.

**Check**: the main "3 inserts + 1 get" semantic tests (lookup in
{0, 1, 2, 3, -1}) all pass.

### Step 8 — `reversible_compile` kwargs

Per §5.1 — add the three kwargs to both overloads. Thread `persistent`
through `lower(...; persistent=cfg)`.

**Check**: the Julia-function path test (add a tiny `_ls_demo`-style
variant that uses `mem=:persistent`) compiles the same gate count as
the classical path when no dynamic alloca is in play.

### Step 9 — Non-linear-scan smoke tests

Fix any callee-signature mismatches flagged by the `okasaki` / `cf`
smoke tests. If HAMT is slow, skip it from the smoke (but keep the
callee registration).

### Step 10 — Regression spot-check

Run the list from §7. Every row byte-identical. If any row drifts,
stop, diff, investigate.

### Step 11 — BENCHMARKS.md

No new row (T5-P6 is a dispatcher change, not a benchmark). The
Pareto-front numbers from M5.4 go into BENCHMARKS later; don't pollute
now.

### Step 12 — WORKLOG.md + bd close

Per CLAUDE.md §0 and the session-close protocol in `CLAUDE.md`.
Update WORKLOG with:

- Final gate count for the acceptance test's compiled circuit
  (informational baseline for follow-up work).
- Any surprises found during Steps 5–7.
- Explicit "non-entry-block persistent stores are NYI" follow-up
  bead pointer.

Close Bennett-z2dj. `git push` per the mandatory workflow.

---

## 10. Honest uncertainties

Items this design doc commits to, but where the implementer should
pay attention:

1. **`Base.return_types` for `_impl_state_bits`** — see R4. The
   right fix is to bake the bit count into `PersistentMapImpl` at
   definition time. The implementer may want to make that the Step-0
   change in Step 2.

2. **Whether `IRCall` through `lower_call!` correctly carries the
   state bundle back as a wire array indexable as `[1:W]`** — the
   MUX EXCH path does this (line 2537: `ctx.vw[alloca_dest] =
   ctx.vw[res_sym][1:$packed_bits]`). The persistent-DS state is
   `state_bits` wide (576 for linear_scan), and we bind
   `ctx.vw[alloca_dest] = ctx.vw[new_state_sym]` directly (no slice).
   That should work because `lower_call!`'s result wire count equals
   `callee_lr.n_wires` / `output_wires`. Minor risk if the callee's
   output is structured as an NTuple return — `extract_parsed_ir` may
   treat it as multi-return, which flows through
   `ret_elem_widths`. Mitigation: inspect one of the existing
   persistent-DS demo tests' extracted `ParsedIR` before Step 6 and
   confirm.

3. **GEP offset-bytes as pmap key** — §6.1 note 1. This is a
   **design choice** that keeps the persistent arm consistent with
   the other tiers. If the implementer disagrees, they should write
   their preferred choice into the consensus doc and justify.

4. **`lower_ptr_offset!` ctx plumbing** — R6 notes a minor refactor
   is needed. The current signature takes
   `ptr_provenance::Union{Nothing,Dict{...}}` and
   `alloca_info::Union{Nothing,Dict{...}}` independently; adding
   `persistent_alloca::Union{Nothing,Dict{...}}` is a 1-kwarg add,
   not a ctx refactor.

5. **Non-entry-block stores — MVP scope decision** — the doc commits
   to fail-loud. An alternative (emit a select-over-state on
   `block_pred`) is less work than adding a guarded callee, and may
   actually be cheaper. If the implementer finds time, they can
   flip the `@test_throws` to a GREEN case. But the 3+1 protocol
   doesn't *require* this to be in scope.

6. **`verify_reversibility` cost on the acceptance test** — Bennett's
   construction on a persistent-DS callee is dense (the MUX EXCH
   ancilla pattern inside `linear_scan_pmap_set` is 9 `_ls_pick`
   calls). The test runs `n_tests=1` by default; the acceptance test
   above uses the default (`verify_reversibility(c)`). If the test is
   slow, bump the arg to `n_tests=3` per the PRD §6 criterion and
   sample 5 concrete `lookup` values.

---

## 11. Summary of what lands in this PRD

- **1 new symbol** in `src/lower.jl`: `DYNAMIC_N = -1`.
- **2 new structs**: `PersistentConfig`, `PersistentAllocaInfo`.
- **1 new validator**: `validate_persistent_config`.
- **1 new registry table**: `_IMPL_TABLE` + wrapper accessors.
- **1 new arm** in `_pick_alloca_strategy`: `:persistent_tree`.
- **2 new lowering helpers**: `_lower_store_via_persistent!`,
  `_lower_load_via_persistent!`.
- **1 modified lowering fn**: `lower_alloca!` — dynamic branch.
- **1 minor refactor**: dynamic-alloca provenance propagation in
  `lower_ptr_offset!` + `lower_var_gep!`.
- **3 new kwargs** on `reversible_compile` (×2 overloads) and `lower`.
- **1 new LoweringCtx field set**: `persistent`, `persistent_alloca`.
- **1 new test file**: `test/test_t5_p6_persistent_dispatch.jl`.
- **Zero BENCHMARKS.md changes** — dispatcher change only.

Line budget estimate: ~240 LOC in `src/lower.jl`, ~30 LOC across
`src/Bennett.jl` and `src/persistent/*.jl`, ~170 LOC in the new
test file. One atomic commit; 3+1 protocol per CLAUDE.md §2.

Default `mem=:classical` → byte-identical output for every existing
test. Default `persistent_impl=:linear_scan` → the sweep-winning
choice when `mem=:persistent` is explicitly selected. Default
`hashcons=:none` → no compression layer (M5.4 arms wired but gated
behind a crisp error until their PRD lands).
