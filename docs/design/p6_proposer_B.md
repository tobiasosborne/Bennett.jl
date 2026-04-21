# T5-P6 Proposer B — `:persistent_tree` Dispatcher Arm (Callee-as-State MVP)

**Bead:** Bennett-z2dj (T5-P6). Labeled `3plus1,core`.
**Role:** Proposer B under CLAUDE.md §2 3+1 protocol.
**Parent:** Bennett-Memory-T5-PRD.md §10 M5.6.
**Date:** 2026-04-21.
**Status:** design only; no source touched.

---

## 0. One-line recommendation

Extend `_pick_alloca_strategy` with a single new terminal arm
`:persistent_tree` that fires **only** when `n_elems` is dynamic (non-const)
AND the currently-active `mem=:persistent` kwarg was explicitly set (or
will become the default once T5-P7a lands); lower the alloca to a
compile-time-fixed NTuple-of-UInt64 state whose shape is dictated by the
chosen `persistent_impl`'s `max_n`; lower each store/load as an `IRCall`
to that impl's registered `<impl>_pmap_set` / `<impl>_pmap_get` callee.
Keep the dispatcher signature unchanged: thread the chosen impl through
`alloca_info` as an extended tuple, NOT through `_pick_alloca_strategy`'s
arguments. This preserves every `_pick_alloca_strategy` test as an
equality assertion, makes the arm strictly additive to every currently
GREEN path, and routes the already-shipping `linear_scan` callees through
the same `lower_call!` machinery that soft_mux_store_* uses today.

**Default:** `persistent_impl=:linear_scan, hashcons=:none` per the
2026-04-20 sweep finding ("linear_scan beats HAMT/CF/Okasaki at every N
up to 1000"). The `:persistent_tree` arm is NOT triggered automatically
under `mem=:auto` in this MVP — it is gated by explicit `mem=:persistent`.
M5.7 (P7a Pareto-front measurement) will decide whether `:auto` flips
this on for dynamic-n_elems. That decision is out of scope for T5-P6.

---

## 1. Scope

### IN scope (lands in T5-P6)

1. **Dispatcher extension.** `_pick_alloca_strategy((elem_w, n_elems), idx)`
   signature unchanged. A new helper `_pick_alloca_strategy_dynamic_n(ctx,
   inst)` is called from `lower_alloca!` when `inst.n_elems.kind == :ssa`
   — it returns `:persistent_tree` if `ctx.mem == :persistent`, else
   `:unsupported_dynamic_n`.

2. **`lower_alloca!` extension.** Accept `inst.n_elems.kind == :ssa`
   under `ctx.mem == :persistent`. Allocate `state_len(impl)` UInt64
   worth of wires (= `64 * state_len`), initialised by emitting the
   `<impl>_pmap_new` callee once into those wires. Record the alloca's
   strategy + impl in `ctx.alloca_info` via a new extended record type.

3. **Store/load lowering.** New helpers
   `_lower_store_via_persistent!` and `_lower_load_via_persistent!`
   emit an `IRCall` to `<impl>_pmap_set` / `<impl>_pmap_get` with the
   current state wires as arg 1 and the store's idx/val (or load's idx)
   as subsequent args. The call's result wires (for set) rebind
   `ctx.vw[alloca_dest]` — exactly mirroring how `_lower_store_via_mux_*!`
   does version-threading today.

4. **`reversible_compile` kwargs.** Add `mem::Symbol=:auto`,
   `persistent_impl::Symbol=:linear_scan`, `hashcons::Symbol=:none` to
   both the `(f, arg_types)` overload and the `(parsed::ParsedIR)`
   overload. Validate: `mem ∈ (:auto, :persistent)`,
   `persistent_impl ∈ (:linear_scan, :okasaki, :hamt, :cf)`,
   `hashcons ∈ (:none, :naive, :feistel)`. `hashcons=:naive|:feistel`
   returns `:unsupported` with a clear "T5-P6 MVP ships linear_scan
   only" error — the other arms exist in src/persistent/ but their
   wiring into this dispatcher is deferred to a P6-follow-up bead.

5. **GREEN acceptance test** (hand-crafted LLVM IR). A new file
   `test/test_p6_persistent_dispatch.jl` that mirrors the
   `test_universal_dispatch.jl` `_compile_ir` pattern and verifies:

   - `alloca i8, i32 %n` + 3 stores at idx 0, 1, 2 + one load at idx 2
     under `mem=:persistent, persistent_impl=:linear_scan` compiles,
     `verify_reversibility` passes, and output matches a reference
     `Dict{Int8,Int8}` oracle (`pmap_demo_oracle` exists in
     `src/persistent/harness.jl`).
   - A diamond-CFG variant of the same pattern (both arms of an outer
     if-else store into the same persistent alloca at compile-time
     distinct keys, join block loads) — catches false-path
     sensitization per CLAUDE.md §"Phi Resolution".
   - `_pick_alloca_strategy` tests from `test_universal_dispatch.jl`
     are replicated verbatim — equality not inequality — to prove
     monotonicity on the existing arms.

6. **Regression invariants.** All BENCHMARKS.md rows from
   `c5736e0` byte-identical. Specifically:
   - i8 x+1 = 100 gates / 28 Toffoli.
   - i16/32/64 × 2 scaling table intact.
   - `soft_fma = 447,728`, `soft_exp_julia = 3,485,262`.
   - `soft_mux_store_4x8` baseline intact (unchanged callee).
   - All `:mux_exch_{N}x{W}` + `:shadow_checkpoint` + `:shadow` arms
     byte-identical.

### OUT of scope

- TJ1/TJ2 (`jl_array_push` / `jl_dict_setindex_r`) → `ir_extract`
  rejects at `LLVMGlobalAliasValueKind`. Separate work (not T5-P6).
- TJ4 (`Array{Int8}(undef, 256)`) → `thread_ptr` GEP in
  `ir_extract`. Separate bead (cc0.5).
- `okasaki_pmap_*`, `hamt_pmap_*`, `cf_pmap_*` wiring. Their callees
  already exist in src/persistent/ and pass `verify_pmap_correctness`.
  But making them *dispatcher-reachable* under this MVP is deferred —
  `persistent_impl=:okasaki` errors with a clear "linear_scan is
  the only arm wired in T5-P6; file a follow-up bead" message.
- Hash-cons layers (`hashcons_jenkins.jl`, `hashcons_feistel.jl`).
  `hashcons ≠ :none` errors as described above.
- Rust ingest + `extract_parsed_ir_from_ll` correctness (Bennett-i3nj)
  — orthogonal, landed in T5-P5a/b.
- Multi-origin × persistent-DS interaction. If a ptr-phi / ptr-select
  feeds a store/load whose origin is a persistent alloca, HARD-ERROR
  loudly per CLAUDE.md §1. File a P6-follow-up bead for the multi-
  origin × persistent extension.
- Parametric `max_n`. If the user's dynamic allocation exceeds the
  impl's baked `max_n` (known only at runtime), the compiled circuit
  silently clamps per the impl's protocol (linear_scan overwrites the
  last slot). This is documented behavior per `interface.jl` line 26–29,
  NOT a T5-P6 bug. Parametric `max_n` selection based on
  static upper-bound analysis of `%n` is a follow-up (open a bead).

---

## 2. Ground-truth audit — what's actually broken today

Direct inspection of the repo, post-cc0 landed, pre-T5-P6:

| Site | Behavior today | Blocker? |
|---|---|---|
| `lower_alloca!` (src/lower.jl:1949-1952) | `inst.n_elems.kind == :const \|\| error(...)` BEFORE populating `alloca_info`. Dynamic n_elems crashes here. | Yes — must relax to accept `:ssa` under `mem=:persistent`. |
| `_pick_alloca_strategy` (src/lower.jl:2019) | Only receives `(shape::Tuple{Int,Int}, idx::IROperand)`. `n_elems` already coerced to `Int`. | No — dynamic n_elems never reaches this function (crashes earlier). |
| `ctx.alloca_info[dest] = (elem_w, n)` (line 1960) | 2-tuple shape. | Needs a 3rd slot to carry `(:persistent_tree, impl_name)` OR a parallel Dict. |
| `register_callee!(linear_scan_pmap_set/_get/_new)` | **NOT registered** in Bennett.jl:162-209. Only `soft_*` callees registered. | Yes — add calls at the bottom of Bennett.jl's register block. |
| `_lower_store_single_origin!` (src/lower.jl:2098) | Dispatches on `_pick_alloca_strategy(info, idx_op)`. No persistent arm. | Yes — add `:persistent_tree` arm. |
| `_lower_load_via_mux!` (src/lower.jl:1701) | Same — no persistent arm. | Yes — mirror the store-side addition. |
| `reversible_compile` kwargs (Bennett.jl:58-62, 105-108) | No `mem=`. | Yes — add. |
| `lower()` kwargs (src/lower.jl:307-309) | No `mem=`. | Yes — thread through so LoweringCtx can carry it. |
| `LoweringCtx` struct | No `mem` / `persistent_impl` field. | Yes — add. |
| `ptr_provenance[dest]` (line 1966) | Pushed unconditionally. | Yes — persistent alloca's origins need a distinct marker so `lower_ptr_offset!` and `lower_var_gep!` don't try to bump idx on them (the idx is a **data** operand to the persistent callee, not a wire-slice offset). |

### The NOT-a-blocker clarifications

- `LoweringCtx` field addition is NOT a phi-resolution change. Its
  backward-compat 11/12/13-arg constructors need trivial updates.
- The dispatcher signature preserving `Tuple{Int,Int}` × `IROperand`
  means every test in `test_universal_dispatch.jl` (lines 90-115) stays
  a pure equality assertion. No test gets broken by changing what
  _pick_alloca_strategy returns for the existing inputs.
- Persistent-DS impls are already `register_callee!`-able in principle:
  they are `@inline` branchless Julia functions with concrete UInt64
  I/O (see src/persistent/linear_scan.jl:29,47,76). We register three
  of them and the existing `lower_call!` path Just Works.

---

## 3. Dispatcher design

### 3.1 Signature decision — UNCHANGED

I considered three options:

| Option | Signature | Cost |
|---|---|---|
| A | `_pick_alloca_strategy(shape, idx)` unchanged | existing tests stay equality; dynamic-n path splits into a sibling picker |
| B | `_pick_alloca_strategy(shape, idx; mem=:auto)` kwarg | existing tests stay equality (ignoring default kwarg); picker body grows |
| C | `_pick_alloca_strategy(ctx, info_ext, idx)` full refactor | every existing call site changes; tests need rewriting |

**Chosen: Option A (signature unchanged).** Dynamic-n_elems is a
structurally different world from the (Int, Int) shape world — it has
no `n`, no `elem_w * n` bit-budget concept, and a completely different
callee. Conflating them into one function makes neither job simpler.

Concrete plan:

```julia
# src/lower.jl — UNCHANGED
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand)
    ...  # existing body preserved verbatim
    return :unsupported
end

# NEW SIBLING, called only from lower_alloca! when n_elems is :ssa
function _pick_alloca_strategy_dynamic_n(ctx::LoweringCtx, inst::IRAlloca)
    ctx.mem == :persistent ||
        error("lower_alloca!: dynamic n_elems for %$(inst.dest) requires " *
              "mem=:persistent (got mem=:$(ctx.mem)). Pass mem=:persistent to " *
              "reversible_compile, or make n_elems compile-time constant.")
    impl = _resolve_persistent_impl(ctx.persistent_impl, ctx.hashcons)
    return (:persistent_tree, impl)
end

# NEW HELPER — single source of truth for impl selection
function _resolve_persistent_impl(impl_kw::Symbol, hashcons_kw::Symbol)
    hashcons_kw == :none ||
        error("T5-P6 MVP: hashcons=:$hashcons_kw is NYI. " *
              "src/persistent/hashcons_{jenkins,feistel}.jl exist but are " *
              "not wired into the dispatcher yet. Use hashcons=:none.")
    impl_kw === :linear_scan && return LINEAR_SCAN_IMPL
    error("T5-P6 MVP: persistent_impl=:$impl_kw is NYI. " *
          "OKASAKI_IMPL / HAMT_IMPL / CF_IMPL exist in src/persistent/ " *
          "but aren't wired to the dispatcher yet. Use :linear_scan.")
end
```

**Why keep the two pickers separate.** Every existing test on
`_pick_alloca_strategy` stays pure equality. Adding a kwarg would mean
pre-M3a tests like line 91 (`@test _pick_alloca_strategy((8, 4),
iconst(2)) == :shadow`) stay identical, but dispatcher audits by future
agents would have to read through a kwarg-only branch to know that
dynamic-n is NEVER hit from this entry point. Two functions, two
purposes — matches CLAUDE.md §1 (fail fast).

### 3.2 Decision tree (post-T5-P6)

Given an `IRAlloca` inst with `(elem_w, n_elems, idx_op_of_first_access)`:

```
lower_alloca!(ctx, inst):
    if inst.n_elems.kind == :const:
        n = inst.n_elems.value
        populate ctx.alloca_info[dest] = (elem_w, n)     # same as today
        populate ctx.ptr_provenance[dest] = [normal PtrOrigin]
    elif inst.n_elems.kind == :ssa:
        # NEW (T5-P6): persistent-tree tier
        strategy, impl = _pick_alloca_strategy_dynamic_n(ctx, inst)
        assert strategy == :persistent_tree
        allocate 64*state_len(impl) fresh wires as the state
        inline the impl.pmap_new() callee into those wires (emits zero-init)
        populate ctx.alloca_info[dest] = (:persistent_tree, impl, <state bookkeeping>)
        populate ctx.ptr_provenance[dest] = [PersistentOrigin(dest, impl, <pred_wire>)]
```

On subsequent IRStore / IRLoad:

```
lower_store!(ctx, inst, block_label):
    origins = ctx.ptr_provenance[inst.ptr.name]
    for each origin:
        if origin is a normal PtrOrigin:
            info = ctx.alloca_info[origin.alloca_dest]
            if info[1] is Int:          # existing (elem_w, n) shape
                strategy = _pick_alloca_strategy((info[1], info[2]), origin.idx_op)
                # existing dispatch unchanged
            elif info[1] === :persistent_tree:
                _lower_store_via_persistent!(ctx, inst, origin, info[2], block_label)
```

### 3.3 Trigger table

| `inst.n_elems.kind` | `ctx.mem` | Result |
|---|---|---|
| `:const` | `:auto` | existing dispatcher (shadow / mux / checkpoint) |
| `:const` | `:persistent` | existing dispatcher (shadow / mux / checkpoint) — **user kwarg does NOT override const-n_elems** |
| `:ssa`   | `:auto`   | hard-error: "mem=:persistent required for dynamic n_elems" |
| `:ssa`   | `:persistent` | `:persistent_tree` arm |

Note the second row: `mem=:persistent` does NOT force persistent-DS on
const-sized allocas. Forcing it would break regression rule #6 on
BENCHMARKS.md. Under this MVP `mem=:persistent` is a permission, not a
request. A future milestone (M5.7+) can add `mem=:force_persistent` if a
benchmark demands it.

---

## 4. `lower_alloca!` change

### 4.1 New `alloca_info` record

The current 2-tuple `(elem_w, n_elems)` isn't expressive enough. Two
options:

- **A**: extend to `Union{Tuple{Int,Int}, Tuple{Symbol,PersistentMapImpl,Int}}`
  where the `Symbol` tag discriminates (`:shape` vs `:persistent_tree`).
- **B**: parallel Dict `ctx.persistent_info::Dict{Symbol, PersistentMapImpl}`
  keyed on alloca dest, sentinel-checked in the dispatcher.

**Chosen: B.** Every existing reader of `ctx.alloca_info` assumes
`(Int, Int)`. Changing to a Union would ripple through ~15 call sites
(`_emit_store_via_shadow_guarded!`, `_lower_load_multi_origin!`,
`lower_ptr_offset!`, `lower_var_gep!`, etc.). A parallel Dict is
strictly additive; readers that don't care never touch it.

```julia
# LoweringCtx additions (T5-P6):
mutable struct LoweringCtx  # (already a struct, not mutable; keep struct)
    ...
    # NEW — T5-P6 Bennett-z2dj
    mem::Symbol                                          # :auto | :persistent
    persistent_impl::Symbol                              # :linear_scan | ...
    hashcons::Symbol                                     # :none | :naive | :feistel
    persistent_info::Dict{Symbol, PersistentMapImpl}     # alloca_dest → impl
end
```

(For actual code a new immutable `struct` version bump to 16-arg is
acceptable; add backward-compat constructors matching the existing
11/12/13 pattern. This is still a *core* change per CLAUDE.md §2 but
strictly additive.)

### 4.2 `lower_alloca!` body (post-T5-P6)

```julia
function lower_alloca!(ctx::LoweringCtx, inst::IRAlloca)
    if inst.n_elems.kind == :const
        # === existing path — unchanged byte-identical ===
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

    # === NEW — T5-P6 persistent-tree path ===
    inst.n_elems.kind == :ssa ||
        error("lower_alloca!: unexpected n_elems kind :$(inst.n_elems.kind) " *
              "for %$(inst.dest); expected :const or :ssa.")

    strategy, impl = _pick_alloca_strategy_dynamic_n(ctx, inst)
    strategy === :persistent_tree ||
        error("lower_alloca!: dynamic n_elems dispatcher returned :$strategy; " *
              "only :persistent_tree is wired in T5-P6.")

    inst.elem_width == impl.K |> _bits_of ||
        @warn "lower_alloca!: elem_width=$(inst.elem_width) for %$(inst.dest) " *
              "differs from impl.K=$(impl.K) size=$(sizeof(impl.K)*8) bits; " *
              "the callee will narrow at its ABI boundary"

    # Allocate state_len UInt64 slots worth of wires, zero by invariant.
    slen = _state_len_bits(impl)   # = 64 * length(impl-returned NTuple)
    state_wires = allocate!(ctx.wa, slen)

    # NOTE: we don't need to explicitly emit `pmap_new()` because a fresh
    # WireAllocator range is zero-initialised, which matches the pmap_new
    # contract (count=0, all slots zero) for linear_scan. Other impls may
    # need a non-zero initial state (e.g. a sentinel-height marker in an
    # RBT root) — those would need a pmap_new IRCall here; linear_scan
    # skips it for a free gate-count win.
    ctx.vw[inst.dest] = state_wires

    # Sentinel record — NOT a normal (Int, Int) shape.
    ctx.persistent_info[inst.dest] = impl

    # Register a single-origin provenance marker. PersistentOrigin is a
    # new variant so lower_ptr_offset! / lower_var_gep! can skip the
    # normal idx-offset-bump logic (the idx is a *value operand* to the
    # callee, not a wire-slice offset). See §5.3.
    ctx.ptr_provenance[inst.dest] = [PtrOrigin(inst.dest, iconst(0),
                                               _entry_predicate_wire(ctx))]
    return nothing
end
```

### 4.3 `_state_len_bits` helper

```julia
"Return total UInt64 slots (×64 = bit-width) in impl's packed NTuple state."
function _state_len_bits(impl::PersistentMapImpl)
    # Call pmap_new once, at compile time, to learn the state tuple length.
    # This is Julia code executed by the compiler, not gate emission.
    template = impl.pmap_new()
    template isa Tuple || error("impl.pmap_new() must return an NTuple")
    return 64 * length(template)
end
```

For `LINEAR_SCAN_IMPL`: `_state_len_bits = 64 * 9 = 576` wires. That's
the size of the initial alloca wire range. This is a regression-safe
number: shadow-checkpoint for `(8, 256) = 2048` wires is larger; we're
within budget.

### 4.4 Uncertainty: `pmap_new` for non-zero initial states

For `linear_scan` and `hamt` and `cf`, `pmap_new()` returns an
all-zeros NTuple, so WireAllocator's zero invariant gives us pmap_new
for free. For `okasaki` with a sentinel black-height root, pmap_new
might return a non-zero NTuple. In that case we'd need to emit
NOTGates on the wires corresponding to the non-zero bits.

The MVP ships with `linear_scan` only where this is a non-issue.
Document this as a known constraint in WORKLOG.md. When
`persistent_impl=:okasaki` lands in a follow-up, add an emit-pmap_new
IRCall.

---

## 5. Store / load lowering

### 5.1 Call-shape derivation

Each impl's protocol in `interface.jl`:
- `pmap_new() :: NTuple{slen, UInt64}`
- `pmap_set(state, k, v) :: NTuple{slen, UInt64}`
- `pmap_get(state, k) :: V`

For linear_scan with max_n=4:
- State is `NTuple{9, UInt64}` = 576 bits.
- Set takes (state, k::Int8, v::Int8) → NTuple{9, UInt64}.
  LLVM ABI: 9 i64 args + 1 i8 arg + 1 i8 arg → 9 i64 return. Hoisted
  through SRET.
- Get takes (state, k::Int8) → Int8.

Bennett.jl already compiles aggregate NTuple-of-UInt64 returns through
`lower_call!` (the soft_mux_store_* callees do exactly this — see
`_lower_store_via_mux_4x8!` in src/lower.jl:2388 where it does
`ctx.vw[alloca_dest] = ctx.vw[res_sym][1:32]` to slice the callee's
UInt64 return into the alloca's low 32 bits). The persistent path slices
all 576 bits back, not just a prefix.

### 5.2 `_lower_store_via_persistent!`

```julia
"""
    _lower_store_via_persistent!(ctx, inst, origin, impl, block_label)

Bennett-z2dj T5-P6 MVP — dynamic-n_elems store via a persistent-DS
callee.  The current state (576-bit NTuple for linear_scan) is passed
as an aggregate; the callee returns the new state and we rebind
ctx.vw[alloca_dest] to the result — exactly as _lower_store_via_mux_4x8!
does for its 32-bit packed array.

Per CLAUDE.md §"Phi Resolution": when block_label is a non-entry
block, wrap the set in a conditional-set (only apply if block_pred
is 1). For the MVP we achieve this by passing the guard wire as an
extra i1 arg that the callee's last ifelse folds in.

Actually — simpler MVP design for T5-P6: if block_label is non-entry,
ERROR with a clear "multi-block persistent store not yet supported in
T5-P6; use :shadow_checkpoint for that shape, or file a follow-up bead
for block_pred-guarded persistent stores." This matches the scope
statement. Diamond-CFG tests must use distinct allocas per arm, or join
the phi BEFORE the store. (The RED diamond-CFG acceptance test in §8
documents this by storing at different keys per arm.)
"""
function _lower_store_via_persistent!(ctx::LoweringCtx, inst::IRStore,
                                      origin::PtrOrigin,
                                      impl::PersistentMapImpl,
                                      block_label::Symbol)
    alloca_dest = origin.alloca_dest

    # Entry-block path ONLY in MVP. Non-entry stores hard-error.
    if block_label != Symbol("") && block_label != ctx.entry_label
        error("_lower_store_via_persistent!: MVP does not support " *
              "persistent stores in non-entry blocks (block=$block_label). " *
              "File a P6-follow-up bead for block-predicate-guarded " *
              "persistent stores.  Alternatively, refactor the source to " *
              "join the ptr phi BEFORE the store.")
    end

    # The key is the GEP offset of ptr relative to alloca_dest. For our
    # corpus pattern (`%gN = getelementptr i8, ptr %p, i32 %k`), the GEP
    # produces a PtrOrigin with idx_op = %k. The key IS idx_op.
    k_op = origin.idx_op
    k_op.kind != :const || (k_op.kind == :const && _can_use_iconst_as_key(impl)) ||
        error("_lower_store_via_persistent!: MVP requires SSA key operand")

    # Sanity-check the state width.
    state_wires = ctx.vw[alloca_dest]
    slen_bits = _state_len_bits(impl)
    length(state_wires) == slen_bits ||
        error("_lower_store_via_persistent!: state has " *
              "$(length(state_wires)) wires, expected $slen_bits " *
              "for impl $(impl.name)")

    # Emit IRCall with aggregate state + scalar k + scalar v.
    # The callee's ABI unpacks the NTuple at its boundary; lower_call!
    # handles the CNOT-copy of each arg to the callee's input wires.
    tag = _next_mux_tag!(ctx, "pset", inst.ptr.name)
    state_sym = Symbol("__pset_state_", tag)
    k_sym     = Symbol("__pset_k_", tag)
    v_sym     = Symbol("__pset_v_", tag)
    res_sym   = Symbol("__pset_res_", tag)

    # Wire-aliasing: state flows in as the SAME wires (no copy — we're
    # about to replace them). The callee is a pure function that reads
    # its inputs into fresh wires anyway via lower_call!'s CNOT-copy
    # protocol, so safe.
    ctx.vw[state_sym] = state_wires
    ctx.vw[k_sym] = _operand_to_w_wires!(ctx, k_op, _K_bits(impl))
    ctx.vw[v_sym] = _operand_to_w_wires!(ctx, inst.val, _V_bits(impl))

    arg_widths = [slen_bits, _K_bits(impl), _V_bits(impl)]
    ret_width  = slen_bits
    call = IRCall(res_sym, impl.pmap_set,
                  [ssa(state_sym), ssa(k_sym), ssa(v_sym)],
                  arg_widths, ret_width)
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    # Rebind alloca to the post-set state. Same pattern as
    # `ctx.vw[alloca_dest] = ctx.vw[res_sym][1:32]` in _lower_store_via_mux_4x8!.
    ctx.vw[alloca_dest] = ctx.vw[res_sym]
    return nothing
end
```

### 5.3 `_lower_load_via_persistent!`

Symmetric:

```julia
function _lower_load_via_persistent!(ctx::LoweringCtx, inst::IRLoad,
                                     origin::PtrOrigin,
                                     impl::PersistentMapImpl)
    alloca_dest = origin.alloca_dest
    k_op = origin.idx_op

    state_wires = ctx.vw[alloca_dest]
    slen_bits = _state_len_bits(impl)
    length(state_wires) == slen_bits ||
        error("_lower_load_via_persistent!: state width mismatch")

    tag = _next_mux_tag!(ctx, "pget", inst.dest)
    state_sym = Symbol("__pget_state_", tag)
    k_sym     = Symbol("__pget_k_", tag)
    res_sym   = Symbol("__pget_res_", tag)

    ctx.vw[state_sym] = state_wires
    ctx.vw[k_sym]     = _operand_to_w_wires!(ctx, k_op, _K_bits(impl))

    call = IRCall(res_sym, impl.pmap_get,
                  [ssa(state_sym), ssa(k_sym)],
                  [slen_bits, _K_bits(impl)], _V_bits(impl))
    lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

    # Result wires are the load's output. Width must match inst.width.
    inst.width == _V_bits(impl) ||
        error("_lower_load_via_persistent!: load width=$(inst.width) " *
              "doesn't match impl V-bits=$(_V_bits(impl))")
    ctx.vw[inst.dest] = ctx.vw[res_sym]
    return nothing
end
```

### 5.4 Dispatcher wiring

In `_lower_store_single_origin!` (src/lower.jl:2098):

```julia
function _lower_store_single_origin!(ctx::LoweringCtx, inst::IRStore,
                                     origin::PtrOrigin, block_label::Symbol)
    alloca_dest = origin.alloca_dest

    # NEW: persistent-tree arm (T5-P6). Checked BEFORE alloca_info lookup.
    if haskey(ctx.persistent_info, alloca_dest)
        impl = ctx.persistent_info[alloca_dest]
        return _lower_store_via_persistent!(ctx, inst, origin, impl, block_label)
    end

    # === existing body unchanged ===
    info = get(ctx.alloca_info, alloca_dest, nothing)
    info === nothing && error("...")
    strategy = _pick_alloca_strategy(info, origin.idx_op)
    if strategy == :shadow
        _lower_store_via_shadow!(...)
    elseif strategy == :mux_exch_2x8
        ...
    end
    return nothing
end
```

Mirror in `_lower_load_via_mux!` (src/lower.jl:1701) — early-return
the persistent path before any `strategy = _pick_alloca_strategy(...)`
call.

### 5.5 GEP / PtrOffset interaction

`lower_ptr_offset!` (src/lower.jl:1516) bumps `o.idx_op` by
`inst.offset_bytes` for each origin, assuming the alloca is a flat
wire slab. For a persistent alloca the "idx" is a *key into a map*, not
an offset — bumping it would produce garbage.

Solution: add an early-out in `lower_ptr_offset!` and `lower_var_gep!`:

```julia
function lower_ptr_offset!(..., ptr_provenance, alloca_info, persistent_info)
    if ptr_provenance !== nothing && persistent_info !== nothing
        base_origins = get(ptr_provenance, inst.base.name, PtrOrigin[])
        for o in base_origins
            if haskey(persistent_info, o.alloca_dest)
                # NEW: static GEP into a persistent alloca is a compile-
                # time-constant key. For the MVP we only support GEP off
                # the alloca itself (idx = 0) — offset_bytes must be 0
                # because the persistent state isn't a flat-addressable
                # slab.
                inst.offset_bytes == 0 ||
                    error("lower_ptr_offset!: non-zero offset_bytes=" *
                          "$(inst.offset_bytes) into persistent alloca " *
                          "%$(o.alloca_dest) is NYI in T5-P6 MVP. " *
                          "Use a dynamic-idx GEP instead (lower_var_gep!).")
                push!(new_origins, PtrOrigin(o.alloca_dest, iconst(0),
                                             o.predicate_wire))
                continue
            end
            # existing body
        end
    end
    # existing tail
end
```

For `lower_var_gep!` (src/lower.jl:1570): treat the dynamic idx as the
key. Currently lines 1588-1602 register `PtrOrigin(o.alloca_dest,
inst.index, o.predicate_wire)` — for persistent allocas this is
exactly what we want (the dynamic GEP idx IS the map key).

The only addition to `lower_var_gep!` is skipping the wire-slicing at
line 1606-1638 when the base is a persistent alloca (there's no flat
wire slab to slice). Guard: `if haskey(persistent_info, inst.base.name)
return end` — the provenance recording at lines 1588-1601 already
happened, and the store/load dispatcher will pick up `ctx.vw[inst.dest]`
via the PtrOrigin chain alone (no materialised dest wires needed because
no concrete IRLoad will dereference it without the origin lookup).

UNCERTAINTY: this "return early before materialising dest wires" path
needs to be validated. It's possible the caller downstream expects
`ctx.vw[inst.dest]` to exist. If so, we allocate a zero-wire dummy and
proceed. The GREEN test will expose which behavior is right — if
verify_reversibility fails with "dest not in vw", switch to dummy.

---

## 6. `reversible_compile` kwargs

### 6.1 New signature

```julia
# src/Bennett.jl — REPLACES lines 58-94 and 105-111.

function reversible_compile(f, arg_types::Type{<:Tuple};
                            optimize::Bool=true, max_loop_iterations::Int=0,
                            compact_calls::Bool=false, bit_width::Int=0,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            strategy::Symbol=:auto,
                            # === T5-P6 additions (Bennett-z2dj) ===
                            mem::Symbol=:auto,
                            persistent_impl::Symbol=:linear_scan,
                            hashcons::Symbol=:none)
    # Existing validation
    strategy in (:auto, :tabulate, :expression) ||
        error("reversible_compile: unknown strategy :$strategy")

    # T5-P6 validation
    mem in (:auto, :persistent) ||
        error("reversible_compile: unknown mem=:$mem; supported: :auto, :persistent")
    persistent_impl in (:linear_scan, :okasaki, :hamt, :cf) ||
        error("reversible_compile: unknown persistent_impl=:$persistent_impl; " *
              "supported: :linear_scan (MVP-ready), :okasaki/:hamt/:cf (NYI)")
    hashcons in (:none, :naive, :feistel) ||
        error("reversible_compile: unknown hashcons=:$hashcons; " *
              "supported: :none (MVP-ready), :naive/:feistel (NYI)")

    # Existing tabulate path UNCHANGED
    if strategy === :tabulate
        ok, reason = _tabulate_applicable(arg_types, bit_width)
        ok || error("reversible_compile: strategy=:tabulate not applicable — $reason")
        widths = _tabulate_input_widths(arg_types, bit_width)
        out_width = bit_width > 0 ? bit_width : sizeof(arg_types.parameters[1]) * 8
        lr = lower_tabulate(f, arg_types, widths; out_width)
        return bennett(lr)
    end

    parsed = extract_parsed_ir(f, arg_types; optimize)

    if strategy === :auto && _tabulate_auto_picks(parsed, arg_types, bit_width)
        widths = _tabulate_input_widths(arg_types, bit_width)
        out_width = bit_width > 0 ? bit_width : sizeof(arg_types.parameters[1]) * 8
        lr = lower_tabulate(f, arg_types, widths; out_width)
        return bennett(lr)
    end

    if bit_width > 0
        parsed = _narrow_ir(parsed, bit_width)
    end
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul,
               mem, persistent_impl, hashcons)  # <-- threaded through
    return bennett(lr)
end

function reversible_compile(parsed::ParsedIR;
                            max_loop_iterations::Int=0, compact_calls::Bool=false,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            mem::Symbol=:auto,
                            persistent_impl::Symbol=:linear_scan,
                            hashcons::Symbol=:none)
    mem in (:auto, :persistent) ||
        error("reversible_compile: unknown mem=:$mem")
    # ... same validation as above ...
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul,
               mem, persistent_impl, hashcons)
    return bennett(lr)
end
```

### 6.2 `lower()` threading

```julia
# src/lower.jl:307 — extend kwargs
function lower(parsed::ParsedIR; max_loop_iterations::Int=0, use_inplace::Bool=true,
               use_karatsuba::Bool=false, fold_constants::Bool=false, compact_calls::Bool=false,
               add::Symbol=:auto, mul::Symbol=:auto,
               # T5-P6 additions
               mem::Symbol=:auto, persistent_impl::Symbol=:linear_scan,
               hashcons::Symbol=:none)
    ...
    # Construct LoweringCtx with the new fields (plus persistent_info dict)
    ctx = LoweringCtx(..., mem, persistent_impl, hashcons,
                      Dict{Symbol,PersistentMapImpl}())
    ...
end
```

### 6.3 SoftFloat overload

Add `mem=:auto, persistent_impl=:linear_scan, hashcons=:none` to the
three-arg wrapper (Bennett.jl:268-295). Thread through to each
`reversible_compile(w, UInt64, ...)` call.

### 6.4 Float64 overload behavior

For Float64 functions (which run through soft_fadd / soft_fmul etc.),
the persistent path is orthogonal — Float64 code doesn't allocate
dynamic-n arrays. The kwargs thread through but don't fire. OK.

---

## 7. Callee registration

### 7.1 `src/Bennett.jl` — register_callee! additions

After line 209 (end of M2d guarded-MUX registrations), add:

```julia
# T5-P6 (Bennett-z2dj) — persistent-DS callees for dispatcher arm.
# Only linear_scan is wired through the dispatcher in the MVP, but we
# register all four so a user can experiment via direct IRCall IR.
register_callee!(linear_scan_pmap_new)
register_callee!(linear_scan_pmap_set)
register_callee!(linear_scan_pmap_get)

# These exist for parity — NOT dispatcher-reachable in T5-P6 MVP.
# Uncomment when the corresponding arm lands in a follow-up bead.
# register_callee!(okasaki_pmap_new)
# register_callee!(okasaki_pmap_set)
# register_callee!(okasaki_pmap_get)
# register_callee!(hamt_pmap_new)
# register_callee!(hamt_pmap_set)
# register_callee!(hamt_pmap_get)
# register_callee!(cf_pmap_new)
# register_callee!(cf_pmap_set)
# register_callee!(cf_pmap_get)
```

### 7.2 Soundness of `register_callee!(linear_scan_pmap_*)`

Verification checklist:

1. **Branchless.** `linear_scan_pmap_{set,get}` use only `ifelse` /
   arithmetic / `&` / `==` — no `if` on data. ✓ (inspected
   src/persistent/linear_scan.jl).
2. **Concrete I/O types.** `set: (NTuple{9,UInt64}, Int8, Int8) ->
   NTuple{9,UInt64}`, `get: (NTuple{9,UInt64}, Int8) -> Int8`. ✓.
3. **Already lowered.** `test_persistent_interface.jl` shows a 7-arg
   demo at line 48 compiles + `verify_reversibility` passes at 436
   gates / 90 Toffoli. The compile path already handles these
   callees. ✓.
4. **No register_callee! yet.** They're called from a top-level Julia
   demo function, so `ir_extract` sees them as regular calls and Julia's
   optimizer may inline. For T5-P6 we want them INLINED at the
   LLVM level when dispatched from `lower_store!`'s IRCall — matches
   how `soft_mux_store_4x8` is handled. `register_callee!` is the
   mechanism. ✓.

---

## 8. RED test — `test/test_p6_persistent_dispatch.jl`

Full file content (drop into `test/`, add to `runtests.jl`):

```julia
using Test
using Bennett
using LLVM

# T5-P6 (Bennett-z2dj) — dynamic n_elems dispatcher arm via persistent
# linear_scan callee.  Hand-crafted LLVM IR mirrors
# `test/test_universal_dispatch.jl`'s `_compile_ir` pattern.

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

@testset "T5-P6 persistent-tree dispatcher arm" begin

    @testset "dispatcher-level: dynamic n_elems requires mem=:persistent" begin
        # With mem=:auto, _pick_alloca_strategy_dynamic_n must hard-error.
        ir = raw"""
        define i8 @julia_p6_basic(i8 %n, i8 %k, i8 %v, i8 %lookup) {
        top:
          %nz = zext i8 %n to i32
          %p  = alloca i8, i32 %nz
          %kz = zext i8 %k to i32
          %gset = getelementptr i8, ptr %p, i32 %kz
          store i8 %v, ptr %gset
          %lz = zext i8 %lookup to i32
          %gget = getelementptr i8, ptr %p, i32 %lz
          %r = load i8, ptr %gget
          ret i8 %r
        }
        """
        # mem=:auto: RED
        @test_throws Exception _compile_ir(ir)
        # mem=:persistent: GREEN compile
        c = _compile_ir(ir; mem=:persistent)
        @test c isa ReversibleCircuit
        @test verify_reversibility(c)
    end

    @testset "3-key insert + 1 lookup round-trip" begin
        # Dynamic n_elems alloca; 3 distinct keys stored via dynamic-idx
        # GEPs; 1 lookup.  Semantics match Dict{Int8,Int8}.
        ir = raw"""
        define i8 @julia_p6_roundtrip(i8 %n,
                                       i8 %k1, i8 %v1,
                                       i8 %k2, i8 %v2,
                                       i8 %k3, i8 %v3,
                                       i8 %lookup) {
        top:
          %nz = zext i8 %n to i32
          %p  = alloca i8, i32 %nz

          %k1z = zext i8 %k1 to i32
          %g1 = getelementptr i8, ptr %p, i32 %k1z
          store i8 %v1, ptr %g1

          %k2z = zext i8 %k2 to i32
          %g2 = getelementptr i8, ptr %p, i32 %k2z
          store i8 %v2, ptr %g2

          %k3z = zext i8 %k3 to i32
          %g3 = getelementptr i8, ptr %p, i32 %k3z
          store i8 %v3, ptr %g3

          %lz = zext i8 %lookup to i32
          %gl = getelementptr i8, ptr %p, i32 %lz
          %r = load i8, ptr %gl
          ret i8 %r
        }
        """
        c = _compile_ir(ir; mem=:persistent, persistent_impl=:linear_scan)
        @test verify_reversibility(c)

        # Concrete semantics: insert (0,10), (1,20), (2,30); lookup idx=2 → 30
        # Reference via pmap_demo_oracle.
        for trial in 1:30
            n = rand(Int8(1):Int8(4))
            k1, k2, k3 = rand(Int8, 3)
            v1, v2, v3 = rand(Int8, 3)
            lookup = rand([k1, k2, k3, rand(Int8)])
            expected = Bennett.pmap_demo_oracle(Int8, Int8,
                                                k1, v1, k2, v2, k3, v3, lookup)
            got = simulate(c, (n, k1, v1, k2, v2, k3, v3, lookup))
            @test got == expected
        end

        # Corner cases
        got_zeros = simulate(c, (Int8(4),
                                 Int8(0), Int8(0),
                                 Int8(0), Int8(0),
                                 Int8(0), Int8(0),
                                 Int8(0)))
        @test got_zeros == Int8(0)

        # Insert (1,11), (2,22), (3,33); lookup key 2 → 22
        got_hit = simulate(c, (Int8(4),
                               Int8(1), Int8(11),
                               Int8(2), Int8(22),
                               Int8(3), Int8(33),
                               Int8(2)))
        @test got_hit == Int8(22)

        # Insert (1,11), (2,22), (3,33); lookup key 99 → 0 (miss)
        got_miss = simulate(c, (Int8(4),
                                Int8(1), Int8(11),
                                Int8(2), Int8(22),
                                Int8(3), Int8(33),
                                Int8(99)))
        @test got_miss == Int8(0)
    end

    @testset "diamond CFG stores at compile-time distinct keys (false-path sensitization)" begin
        # Per CLAUDE.md §"Phi Resolution and Control Flow": a diamond CFG
        # where both arms store into the same persistent alloca must NOT
        # let the false-path store leak. In the MVP, non-entry persistent
        # stores HARD-ERROR — this test pins that behavior.
        ir = raw"""
        define i8 @julia_p6_diamond(i1 %c, i8 %n, i8 %k1, i8 %v1, i8 %k2, i8 %v2, i8 %lookup) {
        top:
          %nz = zext i8 %n to i32
          %p  = alloca i8, i32 %nz
          br i1 %c, label %t, label %f
        t:
          %k1z = zext i8 %k1 to i32
          %g1 = getelementptr i8, ptr %p, i32 %k1z
          store i8 %v1, ptr %g1
          br label %j
        f:
          %k2z = zext i8 %k2 to i32
          %g2 = getelementptr i8, ptr %p, i32 %k2z
          store i8 %v2, ptr %g2
          br label %j
        j:
          %lz = zext i8 %lookup to i32
          %gl = getelementptr i8, ptr %p, i32 %lz
          %r = load i8, ptr %gl
          ret i8 %r
        }
        """
        # MVP: non-entry persistent store is hard-errored. RED asserted
        # literally — when M5.7+ extends the arm to non-entry blocks,
        # flip this to @test verify_reversibility.
        @test_throws Exception _compile_ir(ir; mem=:persistent)
    end

    @testset "pick_alloca_strategy regression (all existing arms byte-identical)" begin
        # Every row from test_universal_dispatch.jl:90-115 replicated
        # verbatim. Passes the original picker is unchanged.
        @test Bennett._pick_alloca_strategy((8, 4), Bennett.iconst(2)) == :shadow
        @test Bennett._pick_alloca_strategy((8, 16), Bennett.iconst(0)) == :shadow
        @test Bennett._pick_alloca_strategy((16, 4), Bennett.iconst(0)) == :shadow

        @test Bennett._pick_alloca_strategy((8, 4), Bennett.ssa(:idx)) == :mux_exch_4x8
        @test Bennett._pick_alloca_strategy((8, 8), Bennett.ssa(:idx)) == :mux_exch_8x8
        @test Bennett._pick_alloca_strategy((8, 2),  Bennett.ssa(:idx)) == :mux_exch_2x8
        @test Bennett._pick_alloca_strategy((16, 2), Bennett.ssa(:idx)) == :mux_exch_2x16
        @test Bennett._pick_alloca_strategy((16, 4), Bennett.ssa(:idx)) == :mux_exch_4x16
        @test Bennett._pick_alloca_strategy((32, 2), Bennett.ssa(:idx)) == :mux_exch_2x32

        @test Bennett._pick_alloca_strategy((8, 100), Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((16, 8),  Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((32, 4),  Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((64, 2),  Bennett.ssa(:idx)) == :shadow_checkpoint
    end

    @testset "mem=:persistent with const n_elems does NOT override existing dispatch" begin
        # mem=:persistent is a permission for dynamic-n, not a forcing.
        # Const-n allocas still pick shadow / mux / checkpoint.
        ir = raw"""
        define i8 @julia_p6_const_n(i8 %x, i8 %i) {
        top:
          %p  = alloca i8, i32 4
          %g0 = getelementptr i8, ptr %p, i32 0
          store i8 %x, ptr %g0
          %iz = zext i8 %i to i32
          %gl = getelementptr i8, ptr %p, i32 %iz
          %r = load i8, ptr %gl
          ret i8 %r
        }
        """
        c = _compile_ir(ir; mem=:persistent)
        @test verify_reversibility(c)
        # The circuit should use MUX EXCH (4x8) for the dynamic load,
        # not a persistent callee. Verify via gate count: MUX EXCH 4x8
        # load is known-small (~4k gates); a 576-bit persistent_get
        # would be ~20k+. Upper-bound the gate count.
        gc = gate_count(c)
        @test gc.total < 10_000   # MUX EXCH regime
    end

    @testset "persistent_impl=:okasaki errors clearly (MVP coverage)" begin
        ir = raw"""
        define i8 @julia_p6_notyet(i8 %n, i8 %k, i8 %v) {
        top:
          %nz = zext i8 %n to i32
          %p  = alloca i8, i32 %nz
          %kz = zext i8 %k to i32
          %g = getelementptr i8, ptr %p, i32 %kz
          store i8 %v, ptr %g
          %r = load i8, ptr %g
          ret i8 %r
        }
        """
        @test_throws Exception _compile_ir(ir; mem=:persistent, persistent_impl=:okasaki)
        @test_throws Exception _compile_ir(ir; mem=:persistent, hashcons=:naive)
    end
end
```

**RED→GREEN sequencing:**

1. Add file. Run. Test 1 (`dispatcher-level`) fails at extract (no
   `mem` kwarg). RED.
2. Add kwargs to `reversible_compile`. Test 1 still fails at
   `_pick_alloca_strategy_dynamic_n` not defined. RED.
3. Add `_pick_alloca_strategy_dynamic_n` + `_resolve_persistent_impl`.
   Test 1 `mem=:auto` arm (the `@test_throws`) now GREEN; `mem=:persistent`
   arm still fails at `lower_alloca!` rejecting dynamic n_elems.
4. Rewrite `lower_alloca!`. Test 1 `mem=:persistent` arm still fails at
   missing `_lower_store_via_persistent!`. RED.
5. Add store/load helpers + dispatcher arm. Test 2 (roundtrip) compiles
   but semantics may fail — GREEN iff callee registration correct.
6. Add `register_callee!(linear_scan_pmap_*)`. Test 2 GREEN.
7. Test 3 (diamond) expects `@test_throws` — should pass as soon as
   non-entry-block guard is in place. GREEN.
8. Tests 4 (regression) + 5 (mem-permission-not-forcing) + 6 (NYI errors)
   GREEN by construction.

---

## 9. Regression plan

Concrete list of assertions, each must be byte-identical to `main` at
`c5736e0` (or the current main SHA at T5-P6 merge time):

| Test | Expected baseline |
|---|---|
| `test_increment.jl` — i8 x+1 | gate_count.total == 100, Toffoli == 28 |
| `test_int16.jl` — i16 x+1 | total == 204, Toffoli == 60 |
| `test_int32.jl` — i32 x+1 | total == 412, Toffoli == 124 |
| `test_int64.jl` — i64 x+1 | total == 828, Toffoli == 252 |
| `test_softfma.jl` — soft_fma | total == 447,728 |
| `test_softfexp_julia.jl` — soft_exp_julia | total == 3,485,262 |
| `test_softfexp_julia.jl` — soft_exp2_julia | total == 2,697,734 |
| `test_shadow_memory.jl` — W=8 shadow store | 24 CNOT |
| `test_soft_mux_mem.jl` — all `soft_mux_store_NxW` | byte-identical callee gate counts |
| `test_soft_mux_mem_guarded.jl` — all M2d `soft_mux_store_guarded_NxW` | byte-identical |
| `test_universal_dispatch.jl` — all `_pick_alloca_strategy` lines 90-115 | byte-identical output symbols |
| `test_memory_corpus.jl` L0-L10, L7a-L7g | all GREEN, circuits byte-identical |
| `test_persistent_interface.jl` — T5-P3a `_ls_demo` | gate_count == 436 total / 90 Toffoli per existing comment at line 81 |
| `test_t5_corpus_julia.jl` TJ3 | GREEN (already closed as of 2026-04-21) |
| `test_t5_corpus_julia.jl` TJ1, TJ2, TJ4 | remain RED (out of scope — TJ1/TJ2 fail at ir_extract, TJ4 at thread_ptr GEP) |

Verification: run `julia --project test/runtests.jl` before + after
T5-P6 lands; diff the output line-by-line excluding timing.

---

## 10. Risk analysis

### R1 — False-path sensitization (CLAUDE.md phi resolution)

**Risk:** A `lower_store_via_persistent!` in a non-entry block could
corrupt state on the false path — the callee emits a full state
rewrite, and if the block_pred isn't folded in, the store happens
regardless of CFG activation.

**Mitigation (MVP):** HARD-ERROR on non-entry persistent stores. The
RED diamond-CFG test pins this. A follow-up bead (documented below)
extends to block-pred-guarded persistent stores by inserting a
`_lower_store_via_persistent_guarded!` that conditionally overwrites:
`if pred then new_state else old_state`. That's a MUX between
`res_sym` and `state_sym` on all `slen_bits` wires — cheap, but out of
scope for MVP.

### R2 — `max_n` overflow silent clamp

**Risk:** Linear scan's `max_n=4` means the 5th distinct key silently
overwrites slot 3 (per interface.jl:26-29 impl-defined behavior). Users
expect a `Dict{Int8,Int8}` semantics at unbounded n.

**Mitigation:** Document in reversible_compile's docstring and in
WORKLOG.md. The impl's `max_n` is visible via `LINEAR_SCAN_IMPL.max_n`.
For benchmarks beyond n=4 the follow-up bead wires `:hamt` (max_n up to
32 per brief). For T5-P6 MVP, tests respect max_n=4 by construction
(only 3 inserts per test).

### R3 — Callee not registered / mis-registered

**Risk:** If `register_callee!(linear_scan_pmap_set)` is missed, the
`IRCall` emitted by `_lower_store_via_persistent!` will fall through to
`lower_call!`'s generic `extract_parsed_ir(inst.callee, ...)` path —
which recompiles the callee per call. Not incorrect, just slow + may
fail if the callee's arg types don't match what the generic path expects
(ours do pass UInt64 aggregates: see `_operand_to_u64!` pattern used for
soft_mux_*).

**Mitigation:** Explicit `register_callee!` calls in Bennett.jl for all
three linear_scan functions. Acceptance test gate count must match
`test_persistent_interface.jl`'s 436 total / 90 Toffoli baseline for the
same demo pattern, proving the callee registry is actually caching the
compiled sub-circuit.

### R4 — Multi-origin pointer with persistent alloca

**Risk:** A `phi ptr` or `select ptr` produces a PtrOrigin fan-out.
`lower_store!` at src/lower.jl:2082 iterates over origins and picks a
strategy per origin. If one origin is a persistent alloca and the
other is a normal alloca, the mixed-strategy path is undefined.

**Mitigation:** Hard-error in `_lower_store_single_origin!`'s dispatch
when `haskey(ctx.persistent_info, alloca_dest)` is true but `length(origins) != 1`:

```julia
length(origins) == 1 ||
    error("lower_store!: multi-origin ptr with persistent-DS origin is " *
          "NYI; all origins are $(collect(keys(ctx.persistent_info)))")
```

The RED test corpus does not exercise multi-origin × persistent.
Follow-up bead.

### R5 — State wire aliasing across Bennett's reverse pass

**Risk:** `ctx.vw[alloca_dest] = state_wires` aliases the callee's input
wires to the alloca's state. After `lower_call!` runs, `state_wires`
(the PRE-set wires) are still in `ctx.vw[state_sym]` (aliased). If
Bennett's reverse pass uncomputes the callee, the state_sym wires
return to zero — but `ctx.vw[alloca_dest]` now points at the RESULT
wires, which also get uncomputed by Bennett. Everything should return
to zero naturally. But aliasing makes me nervous.

**Mitigation:** Write a targeted verifier: after the first
`_lower_store_via_persistent!`, check that `ctx.vw[alloca_dest]` and
`ctx.vw[state_sym]` do NOT share wire ids (they shouldn't after the
IRCall completes — lower_call! returns fresh wires). Add an assert in
the implementation; delete after the GREEN test ships.

### R6 — GEP provenance for dynamic idx

**Risk:** `lower_var_gep!` at src/lower.jl:1588-1601 records
`PtrOrigin(o.alloca_dest, inst.index, o.predicate_wire)` but then at
line 1606-1638 builds a MUX-tree over `base_wires`. For persistent
allocas, `base_wires = state_wires` has no slot structure — slicing it
produces garbage.

**Mitigation:** Early-return in `lower_var_gep!` when base is a
persistent alloca (§5.5). The provenance recording at lines 1595-1601
happens first; the MUX-tree construction at 1606+ is skipped. If
downstream needs `ctx.vw[inst.dest]`, allocate a dummy — but the
persistent lower_load!/store! dispatch goes through `ptr_provenance`,
not `vw`, so the dummy is unused.

### R7 — `optimize=true` vs `optimize=false` IR divergence

**Risk:** Julia's LLVM optimizer sometimes folds allocas entirely
(SROA / mem2reg). A dynamic-n alloca followed by a few stores/loads
may get turned into direct SSA registers, bypassing the dispatcher
arm.

**Mitigation:** The RED tests use hand-crafted IR via `_compile_ir`
(no Julia optimizer pass). For end-to-end Julia-function tests that
hit the persistent arm, we'd need `optimize=false` — or a source shape
the optimizer can't fold. Out of scope for T5-P6 MVP.

### R8 — test_persistent_interface.jl gate count regression

**Risk:** The T5-P3a `_ls_demo` test at 436 total / 90 Toffoli compiles
via the regular callee path (direct Julia function calls, no dispatcher
arm). After T5-P6 lands, the same function compiled with
`mem=:persistent` might produce DIFFERENT gate count — because it's now
going through `_lower_store_via_persistent!`'s IRCall wrapper, not
directly. If `test_persistent_interface.jl` picks up the new arm
accidentally (because its demo stores through a GEP — it doesn't, but
subtly), the 436 baseline shifts.

**Mitigation:** `_ls_demo` calls `linear_scan_pmap_set(s, k, v)` DIRECTLY
without going through alloca+store. There is NO alloca in the demo —
it uses a top-level `s = pmap_new()` Julia local, which Julia emits as
direct SSA (no alloca). So the dispatcher arm is never hit. Verify by
inspection of `@code_llvm _ls_demo(...)` during implementation. If
SROA doesn't fold it, we're fine. If it does fold to an alloca + store
chain, the 436 baseline shifts — file a regression note.

### R9 — Wire-count blow-up for small arrays

**Risk:** Linear scan's state is 576 bits. For a benchmark where the
user's dynamic n is actually 4 (known at runtime, not compile time),
the persistent arm uses 576 bits vs shadow-checkpoint's 32 bits.
14.4× wire bloat.

**Mitigation:** Document. Users who know their dynamic-n is small
should `@check_bounds` the allocation or make n const. Not a T5-P6 bug.

---

## 11. Implementation sequence

One atomic-ish commit — 3+1 protocol. Implementer follows this order.

### Step 1. RED acceptance tests

1.1. Create `test/test_p6_persistent_dispatch.jl` per §8 verbatim.
1.2. Add `include("test_p6_persistent_dispatch.jl")` to
     `test/runtests.jl` (if it's using explicit includes).
1.3. Run: `julia --project test/test_p6_persistent_dispatch.jl`.
     Watch: ALL tests RED, most at `reversible_compile got unsupported
     kwarg :mem`.

### Step 2. Extend `LoweringCtx` and `lower()` kwargs

2.1. Add 4 new fields to `LoweringCtx` (§4.1): `mem::Symbol`,
     `persistent_impl::Symbol`, `hashcons::Symbol`,
     `persistent_info::Dict{Symbol,PersistentMapImpl}`.
2.2. Add a 17-arg constructor. Keep 11/12/13/14-arg backward-compat
     constructors working by defaulting the new fields.
2.3. Extend `lower(parsed; ...)` at src/lower.jl:307 to accept
     `mem::Symbol=:auto, persistent_impl::Symbol=:linear_scan,
     hashcons::Symbol=:none` and thread to the `LoweringCtx`
     constructor.
2.4. Run test_p6. Should now fail at `_pick_alloca_strategy_dynamic_n`
     not defined.

### Step 3. Dispatcher helpers

3.1. Add `_pick_alloca_strategy_dynamic_n(ctx, inst)` and
     `_resolve_persistent_impl(impl, hashcons)` below
     `_pick_alloca_strategy` in src/lower.jl:2019.
3.2. Add helper types/functions `_state_len_bits`,
     `_K_bits`, `_V_bits`, `_operand_to_w_wires!`
     (the last may already exist — check; otherwise it's a
     width-parametric version of `_operand_to_u64!`).
3.3. Run test_p6. Should now fail at `lower_alloca!` rejecting
     dynamic n_elems.

### Step 4. Extend `lower_alloca!`

4.1. Rewrite src/lower.jl:1949-1969 per §4.2 verbatim. Preserve
     the const-n_elems branch byte-identical (it's the first `if`).
4.2. Run test_p6 test 1. Should now fail at
     `_lower_store_via_persistent!` not defined.

### Step 5. Store + load helpers

5.1. Add `_lower_store_via_persistent!` per §5.2 and
     `_lower_load_via_persistent!` per §5.3, at the end of the
     `T5-P6` block in src/lower.jl.
5.2. Run test_p6 test 1. Should fail at
     `_lower_store_single_origin!` not routing to the persistent
     arm.

### Step 6. Dispatcher wiring

6.1. Modify `_lower_store_single_origin!` per §5.4 — add the
     early-out `if haskey(ctx.persistent_info, alloca_dest)` at
     the top.
6.2. Mirror in `_lower_load_via_mux!` (src/lower.jl:1701).
6.3. Run test_p6 tests 1 and 2. Both should now compile. Test 2
     will likely fail on semantics if register_callee! is missing.

### Step 7. Callee registration

7.1. Add three `register_callee!(linear_scan_pmap_*)` calls at the
     end of the register block in src/Bennett.jl (after line 209).
7.2. Run test_p6 test 2 (roundtrip). Should now GREEN on the
     30-trial random sweep.

### Step 8. Hard-error guards

8.1. Add the non-entry-block guard in `_lower_store_via_persistent!`
     per §5.2 (the `if block_label != Symbol("") && block_label !=
     ctx.entry_label ... error` clause).
8.2. Add the multi-origin guard per R4.
8.3. Run test_p6 test 3 (diamond). Should now hard-error as asserted.

### Step 9. GEP / PtrOffset interaction

9.1. Guard `lower_ptr_offset!` per §5.5 (skip bump for persistent
     base).
9.2. Guard `lower_var_gep!` per §5.5 (skip wire-slicing for
     persistent base; preserve provenance recording).
9.3. Run test_p6 test 2 again to confirm no regressions.

### Step 10. `reversible_compile` kwargs

10.1. Add the kwargs to both overloads in src/Bennett.jl per §6.1.
10.2. Add SoftFloat-overload threading per §6.3.
10.3. Run test_p6 test 1 all variants.

### Step 11. `lower()` kwarg threading

11.1. Extend `lower()` kwargs (§6.2) — should already be done in
      Step 2. Confirm.

### Step 12. Full regression

12.1. Run `julia --project test/runtests.jl`. Every test must pass.
12.2. Regenerate BENCHMARKS.md via the existing benchmark script.
      Verify byte-identical to `c5736e0` on all rows listed in §9.
12.3. If any row shifts, STOP and investigate. Per CLAUDE.md §6,
      any gate-count change is a signal.

### Step 13. Session close

13.1. WORKLOG.md session entry: shape of the arm, gate-count
      baseline for the new T5-P6 demo, any surprises.
13.2. Close Bennett-z2dj with a reference to the commit SHA and the
      matching test name.
13.3. File follow-up beads:
      - "T5-P6 extend: non-entry-block persistent stores via block-pred-
        guarded set"
      - "T5-P6 extend: wire :okasaki / :hamt / :cf arms"
      - "T5-P6 extend: wire :naive / :feistel hashcons"
      - "T5-P6 extend: parametric max_n from static upper-bound analysis"
      - "T5-P6 extend: multi-origin × persistent interaction"
13.4. `git commit` per CLAUDE.md session-close protocol. Push.

**Estimated LOC:** ~250 LOC in src/lower.jl (bulk of the new arm),
~30 LOC in src/Bennett.jl (kwargs + registrations), ~300 LOC new test
file. Total ~580 LOC added. One atomic commit.

---

## 12. Deliberate uncertainties (per CLAUDE.md §9)

- **Whether `lower_call!` handles an NTuple-of-UInt64 input
  correctly.** The soft_mux_store_* callees pass a single UInt64
  (not a tuple), so `lower_call!` may have never been exercised with
  a 576-bit aggregate input. The test_persistent_interface.jl's
  `_ls_demo` works because the NTuple is STRUCTURAL in the Julia
  source (SSA-level), not aggregate-passed through
  `extract_parsed_ir`'s CNOT-copy. This is the #1 risk to T5-P6 MVP —
  if LLVM emits `call @linear_scan_pmap_set(<9 x i64> %state, i8 %k,
  i8 %v)` as a vector arg, `lower_call!` may need extension.

  **Mitigation path:** Extract IR of a Julia wrapper first:
  ```julia
  g(state::NTuple{9,UInt64}, k::Int8, v::Int8) = linear_scan_pmap_set(state, k, v)
  parsed = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8})
  ```
  If `parsed.args` shows `(:state, 576)` we're fine. If it shows 9
  separate i64 args, the IRCall arg-list needs restructuring. RESEARCH
  STEP — must be verified before Step 7.

- **Whether `ctx.vw[alloca_dest] = ctx.vw[res_sym]` is a shallow
  rebind or deep copy.** In src/lower.jl:2419 (`_lower_store_via_mux_4x8!`)
  it appears to be a rebind (direct reference share) and WORKS. Our
  path does the same. If it turns out mutation of `res_sym`'s vector
  elsewhere aliases into `alloca_dest`, that's a latent bug. Current
  reading: `ctx.vw` is a `Dict{Symbol, Vector{Int}}` — the `Vector{Int}`
  is shared reference; any mutation would affect both. None of the
  callers mutate; fine.

- **Block-predicate guarding of persistent store.** The MVP hard-errors
  on non-entry blocks. A follow-up could mux the state: `new_state =
  ifelse(pred, pmap_set(old, k, v), old)`. This costs ~576 extra CNOTs
  (one MUX per state bit). Cheaper than extending the callee ABI to
  accept a guard wire. Flagged for the follow-up bead.

- **Whether `optimize=true` preserves the alloca IR pattern.** The
  hand-crafted `_compile_ir` path bypasses Julia's optimizer, so the
  test is safe. But any future Julia-source GREEN test (e.g.,
  `reversible_compile(f, Int8, ...; mem=:persistent)` on a Julia
  function that uses `Vector{Int8}` directly) will fight SROA /
  mem2reg. That's TJ1/TJ2 scope (blocked on cc0.3 `jl_array_push`
  extraction) — not T5-P6.

---

## 13. What makes this proposal independent

Compared to what I'd expect Proposer A to write (I haven't read it):
the key differentiators I'd call out on review:

1. **Separate `_pick_alloca_strategy_dynamic_n` helper** rather than
   extending the existing picker's signature. Keeps the existing
   arity+args stable — zero risk to the byte-identical `:mux_exch_*`
   paths. If A refactored the picker, this proposal is the safer
   rollback.

2. **Parallel `persistent_info` Dict** rather than a tagged Union on
   `alloca_info`. Readers of `alloca_info` don't care about persistent —
   keeps the blast radius small.

3. **Hard-error on non-entry-block persistent stores in MVP**, rather
   than trying to get block-pred-guarded persistent stores in T5-P6.
   Matches CLAUDE.md §1 (fail fast) — known-unsupported patterns crash
   with a clear message instead of producing a circuit that might
   silently leak state.

4. **`mem=:persistent` as permission, not forcing** for const-n allocas.
   Keeps every BENCHMARKS.md row byte-identical even when a user passes
   `mem=:persistent` on a function that also has static arrays.

5. **linear_scan only in MVP, with explicit errors for the other
   impls**. Minimises surface area. The WORKLOG's "linear_scan beats
   all at n≤1000" finding supports this as both the default AND the
   only-arm-in-scope.

6. **GEP/PtrOffset early-returns** rather than deep integration — the
   persistent alloca isn't a flat wire slab, so the existing GEP
   machinery doesn't apply. Early-return leaves the existing tests on
   GEP-of-const-alloca byte-identical.

---

## 14. Open design questions (flag for reviewer)

1. **Q:** Should `mem=:auto` eventually flip to `:persistent` for
   dynamic-n allocas, or should dynamic-n always require explicit
   opt-in?
   **Proposed answer:** MVP requires opt-in. M5.7 (P7a Pareto-front
   measurement) decides whether `:auto` flips it on by default.

2. **Q:** What's the right UX when a user passes `mem=:persistent` but
   the program has no dynamic-n allocas?
   **Proposed answer:** No warning. The kwarg is a permission; if it
   goes unused, fine.

3. **Q:** Should `hashcons=:naive|:feistel` be validated at
   `reversible_compile` entry, or at dispatcher time?
   **Proposed answer:** Dispatcher time — the error site is where the
   user will see it in a stack trace. Pre-validate at the
   `reversible_compile` entry is also OK but less informative.

4. **Q:** Naming — `:persistent_tree` vs `:persistent_map`? The bead
   text says `:persistent_tree` but linear_scan is not a tree.
   **Proposed answer:** Rename to `:persistent_map`. Matches
   `PersistentMapImpl` type name. Breaks no existing test.

---

End of proposer B design.
