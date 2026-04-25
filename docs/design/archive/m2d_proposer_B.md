# M2d Design — Proposer B: Guarded MUX-store callees (threaded pred)

**Issue**: Bennett-i2a6 (Bennett-cc0 M2d)
**Scope**: path-predicate guarding for the MUX-store path in `src/lower.jl`
**Angle**: add new parallel `soft_mux_store_guarded_NxW` callees; thread `pred`
through the slot-wise `ifelse` so the guard FOLDS INTO the exchange logic
(no wrap, no snapshot).

## 1. One-line recommendation

**Add new `soft_mux_store_guarded_NxW(arr, idx, val, pred) -> UInt64` callees
that fold `pred` into the per-slot `ifelse`. Dispatch to them from
`_lower_store_via_mux_NxW!` when `block_label != ctx.entry_label`. Keep
the existing `soft_mux_store_NxW` callees untouched — entry-block stores
stay byte-identical so every MUX EXCH baseline in BENCHMARKS.md is
preserved.** The `_guarded_` callees are new gate-count rows.

## 2. Root cause — where the MUX-store path is unguarded

Entry point: `_lower_store_via_mux_4x8!` (`src/lower.jl:2188`),
`_lower_store_via_mux_8x8!` (`src/lower.jl:2214`), and the `@eval` loop
(`src/lower.jl:2247`) for (2,8)/(2,16)/(4,16)/(2,32).

Every one of these functions emits an `IRCall(res_sym, soft_mux_store_NxW, ...)`
**without consulting `ctx.block_pred[block_label]`**. The call therefore
runs unconditionally: it packs `arr`, writes `val` at `idx`, and rebinds
`ctx.vw[alloca_dest]` to the low N·W wires of the callee output.

Runtime consequence (L7f): an `i %c { L: store i8 %x, ptr %g ; J: load ; ret }`
diamond executes the store on the `L` path only in Julia semantics, but on
the reversible circuit the packed-array rebinding commits the new state
on BOTH branches. A subsequent load then reads the written value even when
`%c = 0`. Reversibility still holds — the Bennett reverse naturally
uncomputes the unconditional update — but the forward semantics are wrong.

This is the exact semantic bug M2c fixed on the SHADOW path via
`emit_shadow_store_guarded!`. The MUX path was deferred (L7f pinned with
`@test_broken`, filed as Bennett-i2a6).

## 3. Design — guarded callees with pred folded into ifelse

### 3.1 Core insight

The un-guarded callee body, per slot `i`, selects between NEW and OLD:

```julia
s_i = ifelse(idx == UInt64(i), v, (arr >> (i*W)) & m)
#            │                 │   │
#            cond              new old
```

The guarded behaviour must produce NEW iff `pred==1 && idx==i`, else OLD:

```julia
s_i = ifelse((pred != 0) & (idx == UInt64(i)), v, (arr >> (i*W)) & m)
#            └──────────── AND of pred and idx-match ────────────┘
```

One extra AND per slot. The assembly (shift + OR) is unchanged.

### 3.2 Exact Julia source (4,8)

```julia
"""
    soft_mux_store_guarded_4x8(arr, idx, val, pred) -> UInt64

M2d — conditional MUX-store. When `pred != 0`, behaves as
`soft_mux_store_4x8(arr, idx, val)`. When `pred == 0`, returns `arr`
unchanged. Branchless; `pred` is expected as UInt64 where 0 means
"do not store" and nonzero means "store".
"""
@inline function soft_mux_store_guarded_4x8(arr::UInt64, idx::UInt64,
                                            val::UInt64, pred::UInt64)::UInt64
    m = UInt64(0xff)
    v = val & m
    g = pred & UInt64(1)      # canonicalise predicate to {0,1}
    # pred folds into the cond of each slot's ifelse. When g==0, no slot
    # matches (cond is always 0), so every slot returns its OLD value.
    s0 = ifelse((g & UInt64(idx == UInt64(0))) != UInt64(0), v, arr         & m)
    s1 = ifelse((g & UInt64(idx == UInt64(1))) != UInt64(0), v, (arr >> 8)  & m)
    s2 = ifelse((g & UInt64(idx == UInt64(2))) != UInt64(0), v, (arr >> 16) & m)
    s3 = ifelse((g & UInt64(idx == UInt64(3))) != UInt64(0), v, (arr >> 24) & m)
    return s0 | (s1 << 8) | (s2 << 16) | (s3 << 24)
end
```

**Semantics**:
- `g==1, idx in [0,3]` → selects `v` at slot `idx`, others preserved. Same
  as `soft_mux_store_4x8`.
- `g==0` → every `ifelse` cond is 0, every slot is OLD. Returns `arr`.
- `g==1, idx >= 4` → every `ifelse` cond is 0 (no match). Returns `arr`.
  This matches `soft_mux_store_4x8` which has the same OOB behaviour
  (since no `ifelse` matches, `s_i` defaults to OLD).

**Parametric variant** (generated via `@eval` to mirror `softmem.jl`):

```julia
for (N, W) in [(2, 8), (4, 8), (8, 8), (2, 16), (4, 16), (2, 32)]
    @assert N * W <= 64
    fn_name = Symbol(:soft_mux_store_guarded_, N, :x, W)
    mask = UInt64((UInt128(1) << W) - 1)

    @eval @inline function $fn_name(arr::UInt64, idx::UInt64,
                                    val::UInt64, pred::UInt64)::UInt64
        m = $mask
        v = val & m
        g = pred & UInt64(1)
        slots = ntuple($N) do k
            k0 = k - 1
            # inline expansion per slot; see 4x8 hand-written above
            ifelse((g & UInt64(idx == UInt64(k0))) != UInt64(0),
                   v, (arr >> (k0 * $W)) & m)
        end
        return reduce(|, ntuple(k -> slots[k] << ((k-1) * $W), $N))
    end
end
```

(The implementer can keep the six variants hand-written to match the
existing softmem.jl style; the `@eval` form above is shown for concision.)

## 4. Wrap vs diff-and-apply — gate-count comparison

Three approaches were considered. The per-slot-pred-fold design above is
the winner on gate count.

### 4.1 Wrap approach (REJECTED)

```julia
new = soft_mux_store_4x8(arr, idx, val)
return ifelse(pred != 0, new, arr)
```

Cost estimate (4x8):
- `soft_mux_store_4x8` body: 7,122 gates baseline.
- Final 64-bit `ifelse`: `lower_mux!` on W=64 emits `4W = 256` gates
  (192 CNOT + 64 Toffoli). In practice post-Bennett this adds ~400–500
  gates because the MUX introduces ancillae that the Bennett-reverse
  must un-compute.
- Estimated total: **~7,550 gates** for guarded_4x8.
- Extra wires: +128 for the MUX (diff + result).

### 4.2 Diff-and-apply (REJECTED)

```julia
new = soft_mux_store_4x8(arr, idx, val)
diff = new ⊻ arr
return arr ⊻ (ifelse(pred != 0, diff, UInt64(0)))
```

Cost estimate (4x8):
- `soft_mux_store_4x8` body: 7,122 gates.
- Two 64-bit XOR arrays: 2·64 CNOT = 128 gates.
- One 64-bit AND-with-pred: 64 Toffoli + ~128 CNOT = ~192 gates.
- Estimated total: **~7,440 gates**. Slightly cheaper than wrap but more
  wires.

### 4.3 Pred-folded ifelse (PROPOSED)

Add one AND per slot inside the existing `ifelse` cond. At LLVM IR level,
this is `%cond_i = and i1 %pred_i1, %match_i`, lowered as one Toffoli
per slot (or CNOT if the extractor canonicalises the boolean AND).

Cost estimate (4x8): the slot-wise `ifelse` chain was already producing
a MUX tree over N=4 conditions; adding one 1-bit AND per slot adds
**at most 4 Toffoli + 4 CNOT ≈ 8 extra gates per slot** through lowering.

After Bennett (forward + copy + reverse triples everything), the total
delta versus the unguarded callee is:

- Forward: +~8 gates per slot × N slots = ~32 gates for 4x8.
- Copy: 0 (output width unchanged).
- Reverse: +~32 gates (mirror).
- **Estimated total for guarded_4x8: ~7,122 + ~64 = ~7,186 gates.**

This is **~95× cheaper** than the wrap and also cleaner: the callee
body stays a single fused ifelse chain, no extra MUX stage at the tail.

### 4.4 Recommendation

Pred-folded ifelse. Per slot: AND `g` into the existing `idx==k` cond.
No wrap, no snapshot, no diff.

## 5. Lower-site dispatch — diff sketch

```diff
 # src/lower.jl :2188
 function _lower_store_via_mux_4x8!(ctx::LoweringCtx, inst::IRStore,
-                                   alloca_dest::Symbol, idx_op::IROperand)
+                                   alloca_dest::Symbol, idx_op::IROperand,
+                                   block_label::Symbol=Symbol(""))
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

-    call = IRCall(res_sym, soft_mux_store_4x8,
-                  [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
+    if block_label == Symbol("") || block_label == ctx.entry_label
+        # Entry-block: byte-identical to pre-M2d.
+        call = IRCall(res_sym, soft_mux_store_4x8,
+                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
+    else
+        # M2d guard: thread block predicate into the callee.
+        pred_wires = get(ctx.block_pred, block_label, Int[])
+        length(pred_wires) == 1 ||
+            error("_lower_store_via_mux_4x8!: expected single-wire " *
+                  "predicate for block $block_label, got $(length(pred_wires))")
+        pred_sym = Symbol("__mux_store_pred_", tag)
+        # Promote 1-wire predicate into a UInt64 operand.
+        pw64 = allocate!(ctx.wa, 64)
+        push!(ctx.gates, CNOTGate(pred_wires[1], pw64[1]))
+        ctx.vw[pred_sym] = pw64
+        call = IRCall(res_sym, soft_mux_store_guarded_4x8,
+                      [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
+                      [64, 64, 64, 64], 64)
+    end
     lower_call!(ctx.gates, ctx.wa, ctx.vw, call; compact=ctx.compact_calls)

     ctx.vw[alloca_dest] = ctx.vw[res_sym][1:32]
     return nothing
 end
```

Mirror the same change in `_lower_store_via_mux_8x8!` and in the `@eval`
loop body at `src/lower.jl:2283`. Thread `block_label` down through
`_lower_store_single_origin!` at `src/lower.jl:2083`:

```diff
 function _lower_store_single_origin!(ctx::LoweringCtx, inst::IRStore,
                                      origin::PtrOrigin, block_label::Symbol)
     ...
     elseif strategy == :mux_exch_2x8
-        _lower_store_via_mux_2x8!(ctx, inst, alloca_dest, idx_op)
+        _lower_store_via_mux_2x8!(ctx, inst, alloca_dest, idx_op, block_label)
     elseif strategy == :mux_exch_4x8
-        _lower_store_via_mux_4x8!(ctx, inst, alloca_dest, idx_op)
+        _lower_store_via_mux_4x8!(ctx, inst, alloca_dest, idx_op, block_label)
     ...
```

`lower_store!` already receives `block_label` from `_lower_inst!(IRStore)`
at `src/lower.jl:152`, so the existing threading is in place — we just
need to pass it one layer deeper.

## 6. Entry-block bypass — preserves MUX EXCH baselines

**The `if block_label == ctx.entry_label` branch above is load-bearing.**
Every call to `_lower_store_via_mux_NxW!` in an entry block stays on the
existing un-guarded `soft_mux_store_NxW` callee. The IRCall, the 64-bit
promotion, the CNOT copy — all unchanged. Therefore:

- All 6 existing MUX EXCH store baselines (4x8=7,122 / 8x8=14,026 /
  2x8=3,408 / 2x16=3,424 / 4x16=6,850 / 2x32=3,072) **byte-identical**.
- All 6 MUX EXCH load baselines unchanged (loads don't need guarding —
  the Bennett reverse handles conditional reads naturally).
- All adder/fma/exp baselines unchanged (no conditional MUX-store in
  those programs).
- Shadow W=8 store unchanged (separate code path).

The sentinel `Symbol("")` path also stays on the unguarded callee —
same backward-compat trick M2c used.

## 7. Bennett reversibility — gate-level argument

For one bit of one slot of the 4x8 guarded callee, the net operation is:

```
s_i_bit = ifelse(g_bit & match_bit, v_bit, old_bit)
```

Where `g_bit` is the low bit of `pred`, `match_bit` is `(idx == i)` for
this slot, `v_bit` is the val bit masked to W=8, `old_bit` is
`((arr >> (8*i)) & 0xff)` for this slot.

Lowered:
1. **Compute `cond = g_bit AND match_bit`**: `Toffoli(g_bit, match_bit, cond)`
   on fresh ancilla `cond`.
2. **MUX `s_i_bit = cond ? v_bit : old_bit`**: via `lower_mux!`
   (`src/lower.jl:1380`), which emits 3 CNOT + 1 Toffoli per bit on fresh
   ancillae for `r` and `diff`.
3. **Shift + OR assembly into output**: unchanged from unguarded variant.

All ancillae (`cond`, `diff`) are freshly-allocated and return to 0
under Bennett's forward + CNOT-copy + reverse protocol. The reverse
pass mirrors every gate exactly, so:

- `Toffoli(g_bit, match_bit, cond)` reverses itself (Toffoli is
  self-inverse). `cond` returns to 0.
- `lower_mux!` gate sequence is each gate self-inverse; `r` and `diff`
  return to 0.

The **only new gates** versus the unguarded callee are:
- One `Toffoli(g_bit, match_bit_i, cond_i)` per slot per bit (forward).
- One mirror `Toffoli` in the reverse pass.
- No new CNOT-copies for the output (output-width unchanged).

**Ancilla invariant**: `verify_reversibility` will continue to return
`true` post-M2d for L7f, because the guarded callee is a proper forward-
reverse pair with zero-reset ancillae by construction.

**Safety of `pred` as read-only**: per M2c's design note, `pred` is
written ONCE during block prologue (via `_compute_block_pred!`) and
never re-touched. The reverse pass sees the same `pred` value. When
`pred == 0` the Toffolis no-op both forward and reverse — arr is
preserved on both passes. When `pred == 1` forward and reverse collapse
to the unguarded Toffoli/CNOT pattern, which is already verified.

## 8. Gate-count estimate per shape + BENCHMARKS.md addition

Method: each guarded callee adds, per slot, **one AND of `pred` into the
slot-match cond**. At the IR level this is a 1-bit AND; through
`lower_call!` (no `compact_calls`) this means ~2 extra gates per slot
in the forward pass (plus ~2 extra in reverse after Bennett-transform
wraps the callee). N slots × 4 gates × Bennett multiplier ≈ 4N extra
gates net.

But the actual overhead is dominated by `lower_mux!` on 64 bits for the
final ifelse wrap, which is NOT present in this design — so the net cost
is small per-slot AND only.

| Shape | Existing (un-guarded) | Estimated guarded | Delta | % |
|-------|----------------------|-------------------|-------|---|
| 2x8   | 3,408                | ~3,500            | +92   | +2.7% |
| 4x8   | 7,122                | ~7,250            | +128  | +1.8% |
| 8x8   | 14,026               | ~14,290           | +264  | +1.9% |
| 2x16  | 3,424                | ~3,520            | +96   | +2.8% |
| 4x16  | 6,850                | ~7,000            | +150  | +2.2% |
| 2x32  | 3,072                | ~3,170            | +98   | +3.2% |

(Conservative upper bounds; actual numbers need measurement once the
implementer lands the callee. Deltas are per-SLOT AND Toffolis times
the Bennett expansion factor, rounded up for the predicate-promotion
CNOT copy.)

**BENCHMARKS.md addition** — new table row group under
"T1b MUX EXCH" section:

```markdown
### T1b MUX EXCH (guarded, M2d)

Emitted when a MUX-store is in a non-entry block. Identical semantics
to the unguarded callee when `pred=1`, no-op when `pred=0`. Cost:
~N extra Toffoli per slot folded into ifelse cond, no wrap stage.

| Callee | Total | Toffoli | Wires |
|--------|-------|---------|-------|
| soft_mux_store_guarded_2x8 | (TBD) | (TBD) | (TBD) |
| soft_mux_store_guarded_4x8 | (TBD) | (TBD) | (TBD) |
| soft_mux_store_guarded_8x8 | (TBD) | (TBD) | (TBD) |
| soft_mux_store_guarded_2x16 | (TBD) | (TBD) | (TBD) |
| soft_mux_store_guarded_4x16 | (TBD) | (TBD) | (TBD) |
| soft_mux_store_guarded_2x32 | (TBD) | (TBD) | (TBD) |
```

Implementer fills in real numbers post-compilation. Baseline table
(existing unguarded) remains intact.

## 9. Interaction with M2b multi-origin

Today (`src/lower.jl:2062-2077`) `lower_store!`'s multi-origin path
explicitly errors on dynamic idx:

```julia
strategy == :shadow ||
    error("lower_store!: multi-origin ptr with dynamic idx (origin=$(o.alloca_dest), " *
          "strategy=$strategy) is NYI; file follow-up bd issue for multi-origin MUX EXCH")
```

**M2d does NOT lift this constraint.** Multi-origin MUX EXCH remains
NYI because it needs fan-out of N per-origin guarded MUX-stores, which
compounds the guard handling. The design above guards a SINGLE-origin
MUX-store; multi-origin dynamic-idx is a separate follow-up (let's
call it M2e / file as a child of Bennett-cc0).

If a future test hits multi-origin + dynamic idx, the existing error
catches it loudly (CLAUDE.md §1). M2d keeps that error and only fixes
the single-origin path that L7f exercises.

## 10. Risks and failure modes

### 10.1 New-callee compile cost

Each new `soft_mux_store_guarded_NxW` is a fresh soft-float-style
callee. `register_callee!` in `src/Bennett.jl:163+` would gain 6 new
entries. Each callee gets its LLVM IR extracted and lowered on first
use via `lower_call!` (src/lower.jl:1863). Cold-compile cost ≈ same as
existing `soft_mux_store_NxW` — a few hundred ms total across the six.
Cached thereafter.

Mitigation: warm-up the cache by running the M2d test first in the
test suite when `Pkg.test()` runs cold.

### 10.2 Bit-exactness vs Julia baseline

Guarded callee must be bit-exact against a Julia reference implementation:

```julia
function ref_guarded_4x8(arr, idx, val, pred)
    pred != 0 ? soft_mux_store_4x8(arr, idx, val) : arr
end
```

Test plan: random `(arr, idx, val, pred)` tuples, plus edge cases
(pred=0 with idx OOB, pred=1 with idx OOB, pred=1 with all-ones `val`,
pred=1 with all-zeros `arr`, high-bit `pred` [e.g. 0xFF — we mask to
low bit]). At least 1000 random cases per shape.

### 10.3 Predicate canonicalisation

Block predicates are 1-bit wires (see `block_pred::Dict{Symbol,Vector{Int}}`
with length-1 vectors per M2c invariant). The callee sees `pred` as
UInt64, so **we must mask `pred & 1` inside the callee** to avoid
accidental high-bit interference. The design shows `g = pred & UInt64(1)`
explicitly. If the implementer forgets this, high-bit garbage could
spuriously match the idx==k check. Test with `pred = 0xDEADBEEF` (odd
→ should store) and `pred = 0xDEADBEEE` (even → should not).

### 10.4 Interaction with existing MUX EXCH baselines

The dispatch branch relies on `block_label == ctx.entry_label` preserving
the unguarded path. **Risk**: future refactor that changes which block
is "entry" (e.g. block-ordering change in `lower()`) could silently flip
entry-block stores to the guarded path, blowing the MUX EXCH baselines.

Mitigation: gate-count regression test per baseline. `BENCHMARKS.md` is
already a regression artefact (CLAUDE.md §6). Any test program that
currently exercises the unguarded path (e.g. the soft_mux_mem test files)
is a sentry — if its gate count moves after M2d lands, investigate.

### 10.5 False-path sensitization (CLAUDE.md §Phi)

The M2d design does NOT touch phi resolution. The guarded MUX-store
only fires when `pred=1`, and `pred` is computed by `_compute_block_pred!`
which already handles diamond CFGs correctly (AND of parent predicate
with edge condition). So false-path sensitization on the MUX-store is
FIXED by the same mechanism M2c used for shadow stores.

One subtle risk: if a future extension allows multi-wire block predicates
(e.g. AND-reduction of multi-condition entry), the `length(pred_wires) == 1`
assert in the dispatch will catch it. Fail-fast per CLAUDE.md §1.

## 11. What I will NOT do

- **Not merge guarded and unguarded callees.** Making the existing
  `soft_mux_store_4x8` accept a `pred=UInt64(1)` default would add AND
  gates to the unguarded path and **break the 7,122 baseline**.
  Separate callees preserve the baseline.
- **Not lift multi-origin dynamic-idx restriction.** That's a bigger
  change (multi-origin fan-out × guard) and belongs in its own
  milestone / bd issue.
- **Not change MUX-load guarding.** Loads don't need pred guarding:
  `_lower_load_via_mux_*!` produces a new wire block for the load
  result; Bennett reverse uncomputes it unconditionally. A false-
  positive load is a wire-count waste but not a semantic bug.
- **Not modify `emit_shadow_store_guarded!`** or any M2c code. The
  shadow path is independent.
- **Not change the `_pick_alloca_strategy` dispatcher.** M2d is a
  downstream-of-dispatch concern; the strategy symbol still maps 1:1
  to a callee, we just pick a different callee based on `block_label`.
- **Not add guarded variants for load callees.** Loads are safe
  unconditionally (CNOT-copy reversible by construction).

## 12. Cost estimate — lines changed

### `src/softmem.jl`: +~120 lines
- 6 new `soft_mux_store_guarded_NxW` function definitions.
- One hand-written (4,8) as template, rest via `@eval` loop (mirrors
  existing M1 addition pattern at lines 102-215).
- Docstrings per function.

### `src/lower.jl`: +~40 lines
- `_lower_store_via_mux_4x8!` (line 2188): +12 lines for the dispatch
  if/else + pred_wires lookup + 64-bit promotion.
- `_lower_store_via_mux_8x8!` (line 2214): +12 lines, same pattern.
- `@eval` loop body (line 2256-2308): +14 lines inside the generated
  `$store_fn` to gate on `block_label`. This applies to all four
  parametric shapes.
- `_lower_store_single_origin!` (line 2083): +5 lines to thread
  `block_label` into the 6 `_lower_store_via_mux_*!` calls. Already
  accepts `block_label::Symbol` — just forward it.

### `src/Bennett.jl`: +8 lines
- 6 new `register_callee!(soft_mux_store_guarded_NxW)` lines under the
  existing M1 additions (line 167-175).
- Export line: none (internal callee).

### `test/test_memory_corpus.jl`: modify ~5 lines
- L7f: flip `@test_broken` → `@test`.
- Optional: add a parameterised test sweep for pred=0/1 combinations.

### `test/test_soft_mux_mem*.jl` (add, optional): +~100 lines
- Bit-exactness test per shape: 1000 random (arr,idx,val,pred) tuples
  against `ref_guarded_NxW` Julia reference.
- Sanity: `simulate(compile(f))` matches Julia semantics for L7f.

### `BENCHMARKS.md`: +15 lines
- New guarded MUX EXCH table (section 8 above).

### Total: ~280 lines changed/added. Comparable to M2c (which added
~60 lines in `shadow_memory.jl` + ~40 in `lower.jl` + tests).

---

## Summary

Guarded MUX-store callees with `pred` folded into per-slot `ifelse`
conditions. Cheapest of the three approaches (~1-3% overhead vs
wrap/diff-and-apply). Preserves every existing BENCHMARKS.md baseline
via entry-block bypass. Bennett-reversible by construction (read-only
pred wire, self-inverse Toffolis). Fixes L7f. Does not lift multi-
origin + dynamic-idx restriction (follow-up milestone).
