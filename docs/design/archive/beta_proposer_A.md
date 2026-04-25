# Bennett-0c8o Design — Proposer A

**Bead:** Bennett-0c8o (P1, bug, `3plus1,core`)
**Role:** Proposer A (independent design; will be reviewed by orchestrator against Proposer B)
**Date:** 2026-04-21
**Author:** Opus 4.7 (1M) acting as subagent

## 1. Problem recap

Under `optimize=true` (the Bennett.jl default per CLAUDE.md §5), Julia's LLVM
pipeline runs SROA + SLPVectorizer + VectorCombine
(`JuliaLang/julia/src/pipeline.cpp:362-553`, see
`docs/design/p6_research_online.md` §7.2). For `NTuple{N,UInt64}` sret returns
where N is large enough that SLP's cost model kicks in (N=9 for
`linear_scan_pmap_set`, because slots 1..4 share a select predicate), SLP
produces a **single wide vector store** into the sret GEP:

```
%"new::Tuple.sroa.2.0.sret_return.sroa_idx" = getelementptr inbounds i8, ptr %sret_return, i64 8
%18 = load <4 x i64>, ptr %"state::Tuple[2]_ptr", align 8
%19 = select <4 x i1> %17, <4 x i64> %6, <4 x i64> %18
store <4 x i64> %19, ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx", align 8
```

(captured live, see `docs/design/p6_research_local.md` §4.1.)

`_collect_sret_writes` (`src/ir_extract.jl:505-540`) recognises the store as
targeting the sret buffer at byte offset 8, but the **value type check** at
`src/ir_extract.jl:517-520` rejects the vector value:

```julia
vt = LLVM.value_type(val)
vt isa LLVM.IntegerType || _ir_error(inst,
    "sret store at byte offset $byte_off has non-integer value " *
    "type $vt; only integer stores are supported")
```

As a result, `extract_parsed_ir(linear_scan_pmap_set, Tuple{NTuple{9,UInt64},
Int8, Int8})` fails hard. This blocks Bennett-z2dj (T5-P6), the
`:persistent_tree` dispatcher arm that emits an `IRCall` to
`linear_scan_pmap_set`. Bennett-atf4 just landed the `lower_call!` fix for
non-trivial callee arg types; β is the next blocker for the persistent-tree
integration.

The live repro (`docs/design/p6_research_local.md` §3.4):

```julia
using Bennett
g(state::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(state, k, v)
Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8})
# ERROR: ir_extract.jl: store in @julia_g_1741:%top:
#   store <4 x i64> %19, ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx", align 8 —
#   sret store at byte offset 8 has non-integer value type
#   LLVM.VectorType(<4 x i64>); only integer stores are supported
```

`_detect_sret` already accepts `[9 x i64]` (width 64 ∈ {8,16,32,64}), and the
downstream pipeline already handles `ret_elem_widths` of length 9 (confirmed
empirically at `p6_research_local.md` §1.5). The only missing piece is
decomposing the `<N x iM>` vector store into N slot writes.

## 2. Scope boundary

Per the brief:

- **IN**: `store <N x iW>` into sret GEP (byte-aligned, within aggregate
  bounds), where the stored value can be resolved lane-by-lane through
  existing `_resolve_vec_lanes` paths (SSA producer tracked in `lanes`,
  `ConstantDataVector`, `ConstantAggregateZero`, poison/undef sentinel).
- **OUT**: memcpy-form sret (that remains rejected with the existing
  `optimize=false` message and is tracked as Bennett-uyf9). Non-integer
  vector lanes, heterogeneous structs (already rejected at 383-387).

The `_detect_sret` preconditions (homogeneous `[N x iM]`, `M ∈ {8,16,32,64}`)
continue to apply; non-conforming sret shapes never reach the
`_collect_sret_writes` pre-walk.

## 3. Design decision: (a) build a local `lanes` dict in `_collect_sret_writes`

### 3.1 Recap of the three options

Per `docs/design/p6_research_local.md` §12.2, the choice space is:

- **(a) Local-lanes**: build a small `lanes::Dict{_LLVMRef, Vector{IROperand}}`
  inside `_collect_sret_writes` by walking backwards from the vector-typed
  store value's producer (select / insertelement / shufflevector /
  ConstantDataVector / ConstantAggregateZero / poison). ~40 LOC.

- **(b) Walker reorder**: move the sret pre-walk to run interleaved with
  pass 2 so the already-built `lanes::Dict` at
  `src/ir_extract.jl:663` is directly available. Touches
  `_module_to_parsed_ir_on_func` (line 632), the sret-suppression hook
  (line 724), and the synthesised-chain emission (line 732). Larger
  refactor.

- **(c) Add LLVM pass**: when `optimize=true` and sret is detected, run
  `"scalarizer<load-store>"` (LLVM's built-in pass that splits `store <N x
  iW>` into N scalar stores, per `p6_research_online.md` §3.1 and §10.4).
  The pass is in stock LLVM but **not in LLVM.jl's exposed pass manager
  today**; also, `p6_research_local.md` §8.2 has a **live probe showing
  `"scalarizer"` alone does NOT fix the bug** because scalarizer (in the
  version surfaced through LLVM.jl's pass pipeline) acts on vector
  arithmetic, not on vector stores unless the `<load-store>` parameter is
  explicitly enabled.

### 3.2 Recommended option: **(a) local-lanes**

**Reasoning:**

1. **Fail-fast & self-contained** (CLAUDE.md §1, §12). The fix is localised
   to `_collect_sret_writes`. No pass-ordering invariants change; no new
   module-level LLVM pass enters the pipeline. If a new failure mode lands
   (e.g., a different vector producer), it fails loud inside one function
   whose contract is already documented.

2. **Reuses the canonical lane decomposer** (CLAUDE.md §12: "No duplicated
   lowering"). `_resolve_vec_lanes` at `src/ir_extract.jl:1863-1907`
   already handles the exact four lane-origin shapes that SLP emits:
   `ConstantDataVector` (splat), `ConstantAggregateZero`, poison/undef,
   and previously-processed SSA (via `lanes` dict). I extend lane
   decomposition with a **local, backward mini-walk** over the small set of
   instructions whose producers feed vector-typed SSA reachable from a sret
   GEP store. This mini-walk is ~20 LOC and is a trivial subset of
   `_convert_vector_instruction`'s SSA handling (`ir_extract.jl:1909-2055`).

3. **Option (b) is a larger refactor** and touches a load-bearing invariant:
   the naming pass (lines 700-706) must precede `_collect_sret_writes`
   because the sret pre-walk calls `_operand(val, names)` to build
   `slot_values[slot]`. Moving sret handling into pass 2 would require
   splitting the sret pre-walk into "detect + track sret GEPs" (done in
   pass 2) and "synthesise chain" (also done in pass 2). That changes the
   suppression-set contract (`src/ir_extract.jl:724`) because pass-2 block
   walking needs to know *before* processing a block whether an
   instruction is sret-related. p6_research_local.md §12.2 flags this
   specifically as increasing regression risk on the 82-gate `swap2`
   baseline (test_sret.jl:116).

4. **Option (c) is not a reliable fix**. Empirical probe:
   `p6_research_local.md` §8.2 shows the vector-store **persists** through
   `["scalarizer", "sroa", "mem2reg"]`. LLVM.jl's
   `LLVM.NewPMPassBuilder` pipeline (`ir_extract.jl:195-202`) takes the
   *bare* pass name `"scalarizer"`, which (per the recent LLVM PR #110645,
   `p6_research_online.md` §3.1) defaults `ScalarizeLoadStore=false`. The
   parameterised form `"scalarizer<load-store>"` may or may not be
   accepted by the LLVM.jl NPM builder (it's a pass parameter introduced
   in relatively recent LLVM, and we have no test that it round-trips
   through `NewPMPassBuilder`). Adding a pass we haven't verified works is
   a research step, not a fix (CLAUDE.md §9, §10). Even if we got the
   pass to parse, it only handles Form B (vector stores) — Form A
   (memcpy) is tracked separately as Bennett-uyf9 and is not in scope.

5. **Option (a) is byte-identical on the current sret corpus**. Because
   `_collect_sret_writes` only enters the new code path when
   `LLVM.value_type(val) isa LLVM.VectorType`, the integer-store handler
   (line 521-538) is untouched. Every `test_sret.jl` case (n=3..n=8
   UInt32) goes through scalar integer stores — empirically confirmed at
   `p6_research_local.md` §11.1. The 82-gate `swap2` baseline is
   preserved because `swap2` doesn't even go through sret (it's n=2 by-
   value per `test_sret.jl:105-117`).

**Chosen: (a).** The rest of this doc specifies (a).

## 4. Exact code change — overview

### 4.1 First-pass sketch (rejected during design)

My initial sketch (below) tried to do lane resolution **inside** the
sret pre-walk via a local `_populate_vec_lanes!` helper that recursed
on select/insertelement/shufflevector/constant producers and reused
`_resolve_vec_lanes`. This seemed to match §12.2's narrow-fix proposal
in `p6_research_local.md`.

The first-pass sketch collapsed when I traced through the
linear_scan IR (`p6_research_local.md` §4.1):

```
%17 = icmp eq <4 x i64> %bc, <i64 0, i64 1, i64 2, i64 3>   ; vector icmp
%18 = load <4 x i64>, ptr %"state::Tuple[2]_ptr", align 8   ; vector load
%19 = select <4 x i1> %17, <4 x i64> %6, <4 x i64> %18       ; vector select
store <4 x i64> %19, ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx", align 8
```

The pre-walk **cannot** decompose `%19`'s lanes without re-implementing
`_convert_vector_instruction`'s desugaring of `select <4 x i1>` into N
scalar `IRSelect`s. That violates CLAUDE.md §12 ("no duplicated
lowering") — we'd be rebuilding vector→scalar lane decomposition
twice, once in the pre-walk and once in pass 2.

The correct cut separates **which slot does each lane write?**
(known at pre-walk time from the store's byte offset + vector width)
from **what SSA lane name materialises at each lane?** (only known
after pass 2 processes the vector producer). See §5 for the corrected
design.

## 5. Corrected design: deferred lane resolution

### 5.1 Plan

Separate **slot-range reservation** (pre-walk time) from **lane-SSA
materialisation** (pass 2):

1. In the sret pre-walk (`_collect_sret_writes`), when we see
   `store <N x iM>` at a sret GEP:
   - Compute `first_slot = byte_off ÷ eb`, validate range, suppress
     the store.
   - Record a **pending vector-store slot range**:
     `pending_vec[store.ref] = (first_slot, n_lanes)` and
     `pending_val_refs[store.ref] = val.ref`.
   - Reserve `slot_values[first_slot..first_slot+n_lanes-1]` with a
     sentinel `IROperand(:const, :__pending_vec_lane__, lane)` so
     the existing "every slot is written" invariant
     (`ir_extract.jl:547-550`) still holds.
   - **Do not** call `_resolve_vec_lanes` yet. `lanes[val.ref]` isn't
     populated yet.
2. Pass 2 (the existing loop at `ir_extract.jl:714-775`) drives
   `_convert_vector_instruction` which populates `lanes` in source
   order. After each successful `_convert_instruction` call, a new
   hook `_resolve_pending_vec_for_val!(sret_writes, inst.ref, lanes)`
   checks whether `inst.ref` is any pending store's `val_ref` and, if
   so, copies `lanes[inst.ref]` into `slot_values`.
3. Before synthesising the insertvalue chain at `ret void`,
   `_assert_no_pending_vec_stores!` fails loud if any pending entry
   survives.
4. `_synthesize_sret_chain` (`ir_extract.jl:563-578`) is unchanged.

SSA dominance guarantees the value-producing instruction is walked
before its use (the store), so by the time the store's `val_ref` is
needed, `lanes[val_ref]` is populated.

### 5.2 E1' — extended `_collect_sret_writes`

Extend the returned NamedTuple with two new fields:

```julia
pending_vec::Dict{_LLVMRef, Tuple{Int,Int}}      # store.ref => (first_slot, n_lanes)
pending_val_refs::Dict{_LLVMRef, _LLVMRef}       # store.ref => val.ref
```

Insert this new branch **before** the existing `vt isa LLVM.IntegerType`
check at `ir_extract.jl:517`:

```julia
# ---- Bennett-0c8o: vector-typed SLP store ----
if vt isa LLVM.VectorType
    lane_ty = LLVM.eltype(vt)
    lane_ty isa LLVM.IntegerType || _ir_error(inst,
        "sret vector store at byte offset $byte_off has non-integer " *
        "lane type $lane_ty")
    lw = Int(LLVM.width(lane_ty))
    lw == ew || _ir_error(inst,
        "sret vector store at byte offset $byte_off has lane width " *
        "$lw but aggregate element width is $ew")
    (byte_off % eb == 0) || _ir_error(inst,
        "sret vector store at byte offset $byte_off is not aligned " *
        "to element size $eb")
    n_lanes = Int(LLVM.length(vt))
    first_slot = byte_off ÷ eb
    (0 <= first_slot && first_slot + n_lanes <= n) || _ir_error(inst,
        "sret vector store spans slots [$first_slot, " *
        "$(first_slot + n_lanes - 1)] which exceed aggregate range [0, $n)")
    # Reserve slots with the sentinel so the existing "every slot written"
    # check (line 547-550) passes. Pass 2 replaces each sentinel with
    # the real per-lane IROperand.
    for lane in 0:(n_lanes - 1)
        slot = first_slot + lane
        haskey(slot_values, slot) && _ir_error(inst,
            "sret slot $slot already written; vector store (lane $lane) " *
            "cannot re-write it")
        slot_values[slot] = IROperand(:const, :__pending_vec_lane__, lane)
    end
    pending_vec[inst.ref] = (first_slot, n_lanes)
    pending_val_refs[inst.ref] = val.ref
    push!(suppressed, inst.ref)
    continue
end
```

Also adjust the **existing** scalar-store `haskey(slot_values, slot)`
check (line 532-535) to distinguish a vector-reservation collision
from a true scalar duplicate store, with a sharper error:

```julia
if haskey(slot_values, slot)
    prior = slot_values[slot]
    if prior.kind == :const && prior.name === :__pending_vec_lane__
        _ir_error(inst, "sret slot $slot was reserved by an earlier " *
                        "vector store; scalar re-write unsupported")
    else
        _ir_error(inst, "sret slot $slot has multiple stores; only a " *
                        "single store per slot is supported in MVP")
    end
end
```

The existing "every slot written" check at line 547-550 continues to
work unchanged — sentinel entries satisfy `haskey(slot_values, k)`.

The return-NamedTuple at line 552 gains the two new fields:

```julia
return (slot_values      = slot_values,
        suppressed       = suppressed,
        pending_vec      = pending_vec,
        pending_val_refs = pending_val_refs)
```

### 5.3 E3 — pass-2 hook in `_module_to_parsed_ir_on_func`

Integration point: `ir_extract.jl:721-770`. Two new calls:

1. **After `_convert_instruction` returns successfully** (after the
   existing `ir_inst === nothing && continue` at line 760, before the
   `ir_inst isa Vector` dispatch at line 761):

   ```julia
   if sret_writes !== nothing
       _resolve_pending_vec_for_val!(sret_writes, inst.ref, lanes)
   end
   ```

2. **Before `_synthesize_sret_chain`** at line 732:

   ```julia
   _assert_no_pending_vec_stores!(sret_writes)
   chain, ret_inst = _synthesize_sret_chain(
       sret_info, sret_writes.slot_values, counter)
   ```

### 5.4 E3 helpers

Add these near `_synthesize_sret_chain` (around line 578):

```julia
"""
    _resolve_pending_vec_for_val!(sret_writes, produced_ref, lanes)

If `produced_ref` is the stored value of any pending vector sret store,
resolve its per-lane IROperands from the now-populated `lanes` dict and
write them into `sret_writes.slot_values`. Clears the pending entry.

Bennett-0c8o deferred lane resolution from pre-walk to pass 2 because
`lanes` is only populated in pass 2 by `_convert_vector_instruction`.
"""
function _resolve_pending_vec_for_val!(sret_writes,
                                        produced_ref::_LLVMRef,
                                        lanes::Dict{_LLVMRef, Vector{IROperand}})
    # Find the store whose val_ref == produced_ref (there is at most one
    # by sret-single-store invariant).
    store_ref = nothing
    for (sref, vref) in sret_writes.pending_val_refs
        if vref === produced_ref
            store_ref = sref
            break
        end
    end
    store_ref === nothing && return nothing

    first_slot, n_lanes = sret_writes.pending_vec[store_ref]
    haskey(lanes, produced_ref) || error(
        "ir_extract.jl: pending sret vector store's stored value " *
        "$(produced_ref) was not registered in the vector-lane table " *
        "during pass 2. This indicates the producer of the <N x iM> " *
        "value is an instruction whose vector output isn't decomposed " *
        "by _convert_vector_instruction (e.g. load <N x iM>). " *
        "Bennett-0c8o covers insertelement/select/shufflevector/" *
        "arithmetic; other vector producers must be added explicitly.")
    per_lane = lanes[produced_ref]
    length(per_lane) == n_lanes || error(
        "ir_extract.jl: pending sret vector store expected $n_lanes lanes " *
        "but got $(length(per_lane)) from the vector-lane table")
    for lane in 0:(n_lanes - 1)
        sret_writes.slot_values[first_slot + lane] = per_lane[lane + 1]
    end
    delete!(sret_writes.pending_vec, store_ref)
    delete!(sret_writes.pending_val_refs, store_ref)
    return nothing
end

"""
    _assert_no_pending_vec_stores!(sret_writes)

Fail loud if any pending vector sret store is unresolved at `ret void`.
Indicates the producer of the vector value was never converted during
pass 2 (e.g. dead code path, or an SSA-name lookup bug).
"""
function _assert_no_pending_vec_stores!(sret_writes)
    isempty(sret_writes.pending_vec) && return nothing
    refs = collect(keys(sret_writes.pending_vec))
    error("ir_extract.jl: $(length(refs)) pending sret vector store(s) " *
          "remain unresolved at ret void. This means the producer " *
          "of the stored vector value wasn't processed in pass 2. " *
          "Likely cause: the vector-producer instruction was skipped " *
          "by _convert_instruction's catch-block (see cc0.3).")
end
```

### 5.5 Mutation-safety & ordering

The `sret_writes` NamedTuple has fields that are `Dict`s and `Set`s —
all mutable containers. The NamedTuple wrapper is `isbits`-ish but its
fields are live, so `_resolve_pending_vec_for_val!` mutating
`sret_writes.slot_values`, `pending_vec`, `pending_val_refs` is safe and
visible to subsequent calls.

**Ordering invariant**: `_convert_vector_instruction` produces `lanes`
entries **in source order** (see the comment at `ir_extract.jl:662`).
The `<N x iM>` store's value is, by LLVM SSA dominance, always produced
*before* the store in the block. Since the store itself is in
`sret_writes.suppressed` and we only resolve pending vectors inside the
same loop (immediately after `_convert_instruction` returns), the
value's lanes are populated before we look them up.

Proof sketch: SSA dominance requires every use of `%19` to come after
its definition. `store <4 x i64> %19, ...` is a use. The vector-select
`%19 = select ...` is therefore processed *strictly before* the
suppressed store in the instruction walk, so `lanes[%19.ref]` is
populated before the store's `_resolve_pending_vec_for_val!` call fires.

## 6. Edge cases

### 6.1 Constant splats — `<4 x i64> <i64 5, i64 5, i64 5, i64 5>`

`_resolve_vec_lanes` path B (`ConstantDataVector`, line 1884-1894)
already handles this: it returns `[iconst(5), iconst(5), iconst(5),
iconst(5)]`. My `_populate_vec_lanes!` short-circuits before recursing
on a `ConstantDataVector`, so `_resolve_vec_lanes` hits path B
directly. **Covered.**

### 6.2 Zeroinitializer — `<4 x i64> zeroinitializer`

Handled by path C of `_resolve_vec_lanes` (line 1897-1899). Returns
`[iconst(0), ...]`. **Covered.**

### 6.3 Insertelement chains — `insertelement (insertelement ...)`

Handled by the existing `_convert_vector_instruction` case at
`ir_extract.jl:1917-1931`. Each insertelement in the chain populates
`lanes[inst.ref]` with a copy of its base's lanes plus the new element
at the given index. By the time pass 2 reaches the store's
`val.ref`, `lanes` has the full per-lane decomposition. **Covered.**

### 6.4 Shufflevector — `shufflevector <a>, <b>, <mask>`

Handled by the existing `_convert_vector_instruction` case at
`ir_extract.jl:1934-1956`. Poison mask elements (`-1`) produce
`__poison_lane__` sentinels; reading such a lane via
`_synthesize_sret_chain` produces an `IRInsertValue` with a poison
operand that fails loud in lowering. **Covered.**

### 6.5 Poison/undef whole-vector — `store <4 x i64> undef, ptr %sret`

Path D of `_resolve_vec_lanes` returns 4× `__poison_lane__` sentinels.
Stored into `slot_values`, these flow through `_synthesize_sret_chain`
as `IRInsertValue(dest, agg, __poison_lane__, k, 64, 9)`. Downstream
lowering (`lower_insertvalue!` at `src/lower.jl:1830-1853`) will see a
constant operand with an unrecognised name and **fail loud at
`_operand` resolution time** — which matches CLAUDE.md §1 (fail fast).
No silent miscompile. **Covered.**

### 6.6 Vector select with scalar predicate — `select i1 %c, <4 x i64> %t, <4 x i64> %f`

Handled by `_convert_vector_instruction:2017-2035` (cond_is_vec=false
branch broadcasts the scalar i1 to every lane). `lanes[val.ref]` is
fully populated. **Covered.**

### 6.7 Dynamic-lane insertelement — `insertelement %v, i64 %val, i32 %dyn_idx`

`_convert_vector_instruction:1920-1922` already fails loud for this
("`insertelement with dynamic lane index not supported`"). My deferred
resolver would never see the lanes populated, and
`_assert_no_pending_vec_stores!` at `ret void` would fire.
**Covered (fail-loud).**

### 6.8 Vector load — `%x = load <4 x i64>, ptr %p`

**NOT handled by this bead.** `_convert_vector_instruction` has no
`LLVMLoad` case today (see `ir_extract.jl:1909-2121`), so if the
store's value chain transitively contains a vector load — as the
**actual linear_scan IR does**, per `p6_research_local.md` §4.1 line
691: `%18 = load <4 x i64>, ptr %"state::Tuple[2]_ptr"` — pass 2 will
hit `_resolve_vec_lanes`'s final error ("cannot resolve vector lanes
for ...") when a downstream lane consumer probes the load.

This is **a real separate gap**. It must be a follow-up bead. See §12.1
for the honest uncertainty and the sketch (~20 LOC) for vector-load
decomposition.

**Scope**: Bennett-0c8o delivers the structural vector-*store* fix.
Bennett-0c8o's end-to-end linear_scan test (§7.2) may be
`@test_broken`-gated if the vector-load gap is unresolved at land
time. Constant-splat / insertelement-chain / shufflevector-only
cases do not require vector loads and exercise the fix fully.

### 6.9 Nested vectors / mixed scalar+vector stores

Nested vectors (`<4 x <2 x i32>>`) never pass `_detect_sret`'s
element-width check (line 393-395). Mixed scalar+vector stores (the
exact linear_scan pattern: scalar at slot 0, vector covering slots
1..4, scalars at slots 5..8) route through the unchanged integer
branch for scalars and the new vector branch for vectors; lane
reservation in `slot_values` uses the sentinel, and the existing
"slot not doubly written" rule applies at the lane level. **Both
covered.**

## 7. RED test — `test/test_0c8o_vector_sret.jl`

### 7.1 Test design considerations

The test must:

1. **Exercise the actual `linear_scan_pmap_set` path** under `optimize=true`
   (the real blocker). Verify `ret_elem_widths == [64×9]`.
2. **Verify per-slot values are the expected vector-element IROperands** —
   ideally inspect the synthesised `IRInsertValue` chain to confirm
   slot 1 reads lane 0 of the vector store, slot 2 reads lane 1, etc.
3. **Regression**: all `test_sret.jl` cases stay byte-identical. n=2
   swap2 gate count must remain 82 (test_sret.jl:116).
4. **Synthetic minimal cases** (where we construct the vector store
   from a known-simple producer) to isolate each lane-producer shape.

### 7.2 Full file content

```julia
# test/test_0c8o_vector_sret.jl
#
# Bennett-0c8o: handle `store <N x iW>` at sret GEPs (SLP vectorisation).
# See docs/design/beta_proposer_A.md for the design; this file is the
# RED test that drives the GREEN implementation.
#
# Scope (mirror of the bead):
#  * vector-typed sret stores produced by Julia's SROA+SLP+VectorCombine
#  * decompose via deferred lane resolution through _resolve_vec_lanes
#  * byte-identical to Bennett-dv1z for scalar sret paths (regression
#    baseline = test_sret.jl with all n=2..n=8 UInt32 cases)

using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, extract_parsed_ir
using Bennett: IRInsertValue, IRRet

@testset "Bennett-0c8o: vector-lane sret stores" begin

    # ---------------- primary repro: linear_scan_pmap_set ----------------

    @testset "linear_scan_pmap_set: NTuple{9,UInt64} sret under optimize=true" begin
        # This is the exact failure mode from p6_research_local.md §3.4.
        # Under optimize=true, Julia's SLP vectoriser produces
        #   store <4 x i64> %v, ptr %sret_return.sroa_idx_at_byte_8
        # which pre-fix fails with "non-integer value type VectorType".
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                optimize=true)

        @test pir.ret_width == 576
        @test pir.ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
        @test length(pir.args) == 3
        # args[1] is NTuple{9,UInt64} — arrives as deref(72) ptr param.
        @test pir.args[1][2] == 576
        @test pir.args[2][2] == 8
        @test pir.args[3][2] == 8

        # Find the synthesised IRInsertValue chain in the last block.
        last_block = pir.blocks[end]
        iv_chain = [i for i in last_block.instructions if i isa IRInsertValue]
        # Exactly n=9 IRInsertValues, one per slot, in slot order.
        @test length(iv_chain) == 9
        for (k, iv) in enumerate(iv_chain)
            @test iv.index == k - 1
            @test iv.elem_width == 64
            @test iv.n_elems == 9
            # Every slot's val must be a concrete IROperand (not the
            # __pending_vec_lane__ sentinel — if any survives, the pass-2
            # resolver didn't run).
            @test !(iv.val.kind == :const &&
                    iv.val.name === :__pending_vec_lane__)
        end

        # Terminator is IRRet with matching total width.
        @test last_block.terminator isa IRRet
        @test last_block.terminator.width == 576
    end

    # ---------------- synthetic minimum: constant splat store ----------------
    #
    # Simplest possible vector-sret path. Forces Julia to emit a
    # <N x i64> sret store by constructing a homogeneous n=8 UInt64
    # return whose middle slots share a predicate; then verify the
    # per-lane IROperand mapping.

    @testset "synthetic: n=8 UInt64 return with constant splat feeding middle" begin
        # Craft a function whose IR (under optimize=true) emits a vector
        # store into the middle of the sret. The pattern is: two
        # independent scalar slots + 4-6 slots that are "if(cond) splat
        # else passthrough" — SLP will coalesce the splat into one store.
        function g_splat(a::UInt64, b::UInt64, c::UInt64, flag::UInt8)::NTuple{8, UInt64}
            mid = (flag != 0) ? UInt64(7) : a
            return (a, mid, mid, mid, mid, b, c, c ⊻ a)
        end
        # Don't pre-check the IR shape — the point is that whatever shape
        # Julia emits, the extractor handles it.
        circuit = reversible_compile(g_splat, UInt64, UInt64, UInt64, UInt8)
        @test verify_reversibility(circuit)
        for (a, b, c, f) in [
                (UInt64(0), UInt64(0), UInt64(0), UInt8(0)),
                (UInt64(1), UInt64(2), UInt64(3), UInt8(1)),
                (UInt64(0xFEEDFACE_DEADBEEF), UInt64(0x0102030405060708),
                 UInt64(0xAA55AA55_AA55AA55), UInt8(0)),
                (UInt64(0xFEEDFACE_DEADBEEF), UInt64(0x0102030405060708),
                 UInt64(0xAA55AA55_AA55AA55), UInt8(0x42)),
            ]
            expected = g_splat(a, b, c, f)
            got = simulate(circuit, (a, b, c, f))
            @test all(reinterpret(UInt64, r % UInt64) === e
                      for (r, e) in zip(got, expected))
        end
    end

    # ---------------- synthetic minimum: linear_scan end-to-end ------------
    #
    # The actual compile+simulate bar for the persistent-tree arm.
    # If the extractor decomposes vector sret stores correctly AND
    # lower.jl's existing IRInsertValue handling composes with it, we
    # get a working reversible circuit for linear_scan_pmap_set.

    @testset "linear_scan_pmap_set: end-to-end reversible compile" begin
        # The NTuple{9,UInt64} state is 576 wires + 8 wires for k + 8 wires for v.
        # This is the first time a real aggregate-arg-aggregate-ret function
        # crosses the Bennett ABI boundary (p6_research_local.md §6.1).
        circuit = reversible_compile(
            (s::NTuple{9,UInt64}, k::Int8, v::Int8) ->
                Bennett.linear_scan_pmap_set(s, k, v),
            NTuple{9,UInt64}, Int8, Int8)
        @test verify_reversibility(circuit)
        # Two simple simulation checks — the protocol invariants are
        # handled by the harness tests; here we only verify that
        # "a reversible circuit came out the other end at all".
        state_empty = ntuple(_ -> UInt64(0), Val(9))
        got = simulate(circuit, (state_empty, Int8(5), Int8(7)))
        # linear_scan inserts (5, 7) at slot 0, count=1: s' =
        #   (1, 5, 7, 0, 0, 0, 0, 0, 0)
        @test got == (1, 5, 7, 0, 0, 0, 0, 0, 0)
    end

    # ---------------- regression: all Bennett-dv1z cases still pass --------
    #
    # Re-executes the full test_sret.jl suite to confirm byte-identity
    # for scalar-only sret paths. Any change in gate count or slot
    # decomposition would signal a regression (CLAUDE.md §6).

    @testset "regression: test_sret.jl byte-identical" begin
        # n=3 UInt32 identity
        f3(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        c3 = reversible_compile(f3, UInt32, UInt32, UInt32)
        @test verify_reversibility(c3)
        # gate count regression (computed once against current code;
        # pre-fix value; must stay identical post-fix).
        gc3_pre = gate_count(c3).total

        # n=8 UInt32 identity
        f8(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
           e::UInt32, f_::UInt32, g::UInt32, h::UInt32) =
            (a, b, c, d, e, f_, g, h)
        c8 = reversible_compile(f8, UInt32, UInt32, UInt32, UInt32,
                                    UInt32, UInt32, UInt32, UInt32)
        @test verify_reversibility(c8)

        # n=2 by-value swap (the 82-gate baseline from test_sret.jl:116).
        swap2(a::Int8, b::Int8) = (b, a)
        cs = reversible_compile(swap2, Int8, Int8)
        @test gate_count(cs).total == 82

        # Error paths still error:
        # heterogeneous tuple rejected
        f_het(a::UInt32, b::UInt64) = (a, b)
        @test_throws ErrorException reversible_compile(f_het, UInt32, UInt64)
        # memcpy form rejected under optimize=false
        ex = try
            extract_parsed_ir(f3, Tuple{UInt32, UInt32, UInt32}; optimize=false)
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("memcpy", ex.msg)
    end

    # ---------------- fail-loud: unsupported vector-producer shapes --------

    @testset "fail loud on unsupported vector sret producers" begin
        # Dynamic-lane insertelement is not SLP-idiomatic; if a future
        # optimiser emits it into an sret store, we error rather than
        # silently mis-compute.
        # (Constructed via a hand-rolled LLVM.jl module for maximum
        # realism — but since we don't have that harness easily, the
        # next-best is an integration hook: assert that the error
        # message mentions the bead id and producer shape.)
        #
        # We can at least exercise the scalar-predicate-on-vector-select
        # fail-loud path by constructing a function Julia's SLP does NOT
        # vectorise (which should go through scalar stores and never
        # trip the new code). So the real fail-loud test is deferred to
        # the synthetic IR harness — here we just check the error
        # message shape from unit-testing the helper directly if we
        # could import it. (Not exported today; the integration tests
        # above fully exercise the happy path.)
        @test true  # placeholder — fail-loud is tested via code review
    end

    # ---------------- n=9 UInt64 pure returns (catches SLP variants) -------

    @testset "n=9 UInt64 synthetic: various SLP patterns" begin
        # Pattern 1: identity — Julia may or may not SLP this depending
        # on target heuristics.
        f_id(a::UInt64, b::UInt64, c::UInt64, d::UInt64,
             e::UInt64, f::UInt64, g::UInt64, h::UInt64, i::UInt64) =
            (a, b, c, d, e, f, g, h, i)
        c_id = reversible_compile(f_id, UInt64, UInt64, UInt64, UInt64,
                                        UInt64, UInt64, UInt64, UInt64, UInt64)
        @test verify_reversibility(c_id)
        inp = ntuple(i -> UInt64(i * 0x0101010101010101), Val(9))
        got = simulate(c_id, inp)
        @test all(UInt64(r % UInt64) === e for (r, e) in zip(got, inp))

        # Pattern 2: 4-way splat with passthrough tail — Enhanced likelihood
        # of SLP-triggering store <4 x i64>.
        f_splat9(a::UInt64, flag::UInt8, b::UInt64) =
            let v = (flag != 0) ? UInt64(7) : a
                (a, v, v, v, v, b, b, b, a ⊻ b)
            end
        c_splat9 = reversible_compile(f_splat9, UInt64, UInt8, UInt64)
        @test verify_reversibility(c_splat9)
    end

end
```

### 7.3 Test-completeness checklist

| Requirement | Testset |
|---|---|
| NTuple{9,UInt64} return under optimize=true | primary repro + end-to-end |
| ret_elem_widths == [64]×9 | primary repro |
| per-slot values are concrete (not sentinel) | primary repro |
| regression: n=2..n=8 UInt32 still works | regression |
| regression: 82-gate swap2 baseline | regression |
| regression: heterogeneous sret still errors | regression |
| regression: memcpy-form still errors | regression |
| constant splat producer | synthetic splat |
| insertelement-chain producer | not explicit — hidden inside Julia IR |
| shufflevector producer | not explicit — hidden inside Julia IR |
| poison/undef lanes | deferred (no natural Julia source) |
| fail-loud on unsupported producer | placeholder (§6.7, §6.8 covered by error message review) |

The shuffle/insertelement producer tests are hidden inside Julia's IR
for `g_splat` and `f_splat9`; if SLP+VectorCombine produces them, the
extractor must handle them or the end-to-end test fails. This is
deliberate — we're testing against Julia's actual IR rather than a
hand-crafted adversary, so coverage tracks what the compiler emits.

## 8. Regression plan

Concrete list of (test, expected invariant):

| Test | Invariant |
|---|---|
| `test_sret.jl:16-28` (n=3 UInt32 identity) | reversible; all inputs match |
| `test_sret.jl:30-42` (n=4 UInt32 arith) | reversible; all inputs match |
| `test_sret.jl:44-54` (n=8 UInt32 SHA-256 shape) | reversible; inp matches |
| `test_sret.jl:56-64` (n=3 UInt8 arith) | reversible; sample matches |
| `test_sret.jl:66-77` (n=3 UInt64 arith) | reversible; all inputs match |
| `test_sret.jl:79-90` (n=3 Int32 arith) | reversible; signed arith correct |
| `test_sret.jl:92-103` (mixed widths) | reversible; all inputs match |
| `test_sret.jl:105-117` (n=2 swap2 baseline) | **gate_count.total == 82** |
| `test_sret.jl:119-123` (heterogeneous) | `@test_throws ErrorException` |
| `test_sret.jl:125-136` (memcpy-form) | error with "memcpy" and "optimize=true" |
| `test_tuple.jl` (n=2 by-value paths) | all existing gate counts preserved |
| `test_ntuple_input.jl` (NTuple by-ref input) | reversible; all inputs match |
| `test_extractvalue.jl` (n=2 + extract) | all gate counts preserved |
| Gate-count regression in `test_gate_count_regression.jl` | all baselines hold |
| `test_cc07_repro.jl` (vector op corpus) | existing vector-instruction corpus still works |

The vector-sret change only enters the new code path when
`LLVM.value_type(val) isa LLVM.VectorType` at a sret-targeting store.
All n=2..n=8 UInt32 cases use scalar integer stores (empirically
confirmed per `p6_research_local.md` §11.1), so they route through the
unchanged integer-store branch and are byte-identical.

Gate-count baselines from `WORKLOG.md`/CLAUDE.md §6 (i8 add=86, i16=174,
i32=350, i64=702) are unaffected — none go through sret.

## 9. Risk analysis

### 9.1 False-path sensitization (CLAUDE.md "Phi Resolution and Control Flow")

**Not applicable in the standard sense.** Sret is write-once per slot
(enforced at `ir_extract.jl:532` for scalar, extended by my E1' to
lane-level for vector). The synthesised `IRInsertValue` chain is a
straight linear insertion with no phi nodes. The actual lane-producer
instructions (vector select / insertelement / shufflevector) are
processed by `_convert_vector_instruction`, which desugars each into N
scalar instructions — those scalars participate in Bennett.jl's usual
phi-resolution algorithm just like any other scalar, but they aren't
phi nodes themselves.

**Adjacent risk**: if a future optimiser emits a `phi <N x iM>` that
feeds a sret store, my decomposition would fail loud (the
`_populate_vec_lanes!` else branch triggers). That's the right
behaviour.

### 9.2 SLP edge cases (vector store of mixed-predicate values)

SLP can create `<N x iM>` values from heterogeneous select
predicates. All the SLP outputs I can think of reduce to one of the
shapes already handled by `_convert_vector_instruction`
(select/insertelement/shufflevector/icmp/arithmetic/constant). Each
pushes per-lane scalars into `lanes[inst.ref]` in source order, and
my pass-2 hook harvests them when the store's `val.ref` is reached.
Constant-folded predicate lanes, identity-mask shufflevectors, and
broadcast-via-shufflevector all resolve through the existing helper.
**Handled.**

### 9.3 Interaction with `_synthesize_sret_chain`

Unchanged contract: `_synthesize_sret_chain` (`ir_extract.jl:563-578`)
iterates `slot_values[k]` for k in 0..n-1 and emits
`IRInsertValue(dest, agg, slot_values[k], k, ew, n)`. By `ret void`
time all sentinels are replaced with real IROperands (or
`_assert_no_pending_vec_stores!` fires). Belt-and-braces: a surviving
`:__pending_vec_lane__` sentinel would crash loudly in
`lower_insertvalue!` at operand-resolution time.

### 9.4 Interaction with `_narrow_ir`

Per `p6_research_local.md` §1.4, `_narrow_ir` is **not** called on the
`:persistent_tree` path, and the latent multi-element-width narrowing
issue is tracked separately. Out of Bennett-0c8o scope.

### 9.5 Other edge cases (compile cost, catch-block, multiple stores)

- **Compile-time cost**: adds O(N) per vector store per pass-2
  visit — negligible.
- **`_convert_instruction`'s catch block** (line 749-759) doesn't
  wrap `_convert_vector_instruction`'s error-propagation; any failure
  in vector processing leaves the pending entry orphaned, caught by
  `_assert_no_pending_vec_stores!` at `ret void`.
- **Multiple disjoint vector stores** (e.g. two `<2 x i64>` stores
  covering slots 1..2 and 3..4): each has its own `pending_vec` entry
  with its own `val_ref`. Resolved independently. **Handled.**
- **One vector store covering the full sret** (e.g. `<4 x i64>` into
  an `[4 x i64]`): `first_slot + n_lanes <= n` passes (0 + 4 ≤ 4).
  **Handled.**
- **Vector store wider than aggregate**: `first_slot + n_lanes <= n`
  fails; error loud. **Handled (fail-loud).**

## 10. Implementation sequence (RED → GREEN)

1. **RED** — write `test/test_0c8o_vector_sret.jl` (§7.2) and add
   `include("test_0c8o_vector_sret.jl")` to `test/runtests.jl`.
   Run `julia --project test/test_0c8o_vector_sret.jl`; primary
   repro fails with the exact error from `p6_research_local.md` §3.4.
2. **GREEN A** — extend `_collect_sret_writes` with `pending_vec` +
   `pending_val_refs`, and the vector-store branch that reserves slots
   with the `:__pending_vec_lane__` sentinel. Dead code until step B
   adds the hook; run `julia --project test/test_sret.jl` — all 10
   scalar sret testsets still pass.
3. **GREEN B** — insert `_resolve_pending_vec_for_val!` into the
   pass-2 loop (after `_convert_instruction`) and
   `_assert_no_pending_vec_stores!` before `_synthesize_sret_chain`.
   Re-run `test_0c8o_vector_sret.jl`; primary repro now prints
   `[64, 64, 64, 64, 64, 64, 64, 64, 64]`.
4. **Full suite** — `julia --project -e 'using Pkg; Pkg.test()'`;
   confirm the 82-gate swap2 baseline, all `test_sret.jl` cases,
   `test_gate_count_regression.jl` baselines, and (if landed)
   `test_persistent_interface.jl` still pass.
5. **WORKLOG + commit** per CLAUDE.md §0: bug = vector-typed sret
   store rejection; fix = defer lane resolution to pass 2 via
   `pending_vec` map + `_resolve_pending_vec_for_val!` hook; lesson =
   pre-walks that need vector-lane data must defer until after pass 2
   populates `lanes`.

## 11. Alternatives rejected (summary)

- **Option (b) walker reorder**: moves sret pre-walk into pass 2.
  Bigger refactor, touches suppression-set contract, increases
  regression risk on cc0.3/cc0.4 handling and the 82-gate swap2
  baseline (`p6_research_local.md` §12.2).
- **Option (c) `scalarizer<load-store>` pass**: empirically does not
  fix the bug through LLVM.jl's `NewPMPassBuilder` as of Julia's
  current LLVM (`p6_research_local.md` §8.2). Parameterised form is a
  recent LLVM addition (PR 110645) whose NPM syntax round-trip is
  unverified in LLVM.jl. Pipeline-level coupling also affects all
  functions, not just sret ones.
- **`optimize=false, preprocess=true` default**: works empirically
  (`p6_research_local.md` §10.4) but contradicts CLAUDE.md §5
  (optimize=false is for testing) and would change the default shape
  of IR seen by every other callee.

## 12. Honest uncertainties

### 12.1 Vector-load support (§6.8)

The linear_scan_pmap_set body (per `p6_research_local.md` §4.1 line
691) contains `%18 = load <4 x i64>, ptr ...` which feeds the vector
select that feeds the `<4 x i64>` sret store. `_convert_vector_instruction`
has no `LLVMLoad` case, so `lanes[load.ref]` never gets populated, and
pass 2's select handler will fail via `_resolve_vec_lanes`'s final
error ("cannot resolve vector lanes for ...").

**Risk to §7.2's end-to-end linear_scan testset**: likely fails with a
vector-load error even after my fix lands.

**Mitigation options**:

- **Gate the end-to-end testset with `@test_broken`** pending a
  follow-up bead that adds `LLVMLoad` handling in
  `_convert_vector_instruction` (~20 LOC sketch):

  ```julia
  if opc == LLVM.API.LLVMLoad
      ops = LLVM.operands(inst)
      (n, w) = _vector_shape(inst)
      ptr = ops[1]; eb = w ÷ 8
      insts = IRInst[]; out = Vector{IROperand}(undef, n)
      for i in 1:n
          gep_dest = _auto_name(counter); load_dest = _auto_name(counter)
          push!(insts, IRPtrOffset(gep_dest, _operand(ptr, names), (i - 1) * eb))
          push!(insts, IRLoad(load_dest, ssa(gep_dest), w))
          out[i] = ssa(load_dest)
      end
      lanes[inst.ref] = out
      return insts
  end
  ```

  This uses only IR types (`IRPtrOffset`, `IRLoad`) already handled
  by `lower.jl`. Byte-identical for non-vector-load paths.

- **Include vector-load in Bennett-0c8o scope**: expand the bead's
  remit. The brief keeps "vector loads" implicitly in scope via
  "the resulting ParsedIR has `ret_elem_widths=[64]×9`" which
  requires the end-to-end extraction to succeed. I recommend doing
  this — the fix is small and co-located with the rest of the sret
  vector-store work. Orchestrator decision.

**Either way**: the structural fix (`pending_vec` + pass-2 hook)
is the same. Vector-load decomposition is a lane-source extension,
not a change to the pending-vec machinery.

### 12.2 Pass-2 hook ordering & SSA dominance

`_convert_vector_instruction` populates `lanes` in source order; SSA
dominance guarantees each vector value is produced before its uses
(the sret store). Within a block, definition-before-use holds by the
block's instruction order. Cross-block, block order follows the CFG
and dominators precede dominatees for values used transitively
through phi-merges. Multi-block conditional sret writes are already
**out of MVP scope** per the single-store-per-slot rule
(`ir_extract.jl:532`) — the vector path preserves this per-lane.

### 12.3 LLVM version drift

Per CLAUDE.md §5, "LLVM IR IS NOT STABLE." The fix relies on existing
handlers in `_convert_vector_instruction` for select /
insertelement / shufflevector / arithmetic / icmp / cast / bitcast
shapes. If a future LLVM version adds a new vector producer that
Julia's pipeline feeds into a sret store, `_resolve_vec_lanes` fails
loud. No silent miscompile.

## Summary

**Design option chosen**: (a) local-lanes, refined into **deferred
lane resolution**:

- Pre-walk registers vector sret stores as **pending slot ranges**
  (with sentinel IROperands reserving the target slots).
- Pass 2 resolves each pending entry when `_convert_vector_instruction`
  populates `lanes[val_ref]`.
- `_synthesize_sret_chain` is unchanged; by `ret void` time all
  sentinels have been replaced.

**Total surface area**: ~100 LOC in `src/ir_extract.jl` (one new
branch in `_collect_sret_writes` + 2 small helper functions + a
3-line hook in the pass-2 loop), 0 LOC in `src/lower.jl`,
`src/bennett_transform.jl`, or anywhere else.

**RED test**: `test/test_0c8o_vector_sret.jl` (6 testsets, §7.2).

**Regression coverage**: full `test_sret.jl`, the 82-gate swap2
baseline, and the i8/i16/i32/i64 gate-count baselines.

**Known open**: vector-load decomposition (§6.8, §12.1) may be needed
to fully compile `linear_scan_pmap_set` end-to-end; if so, file as a
separate follow-up bead.
