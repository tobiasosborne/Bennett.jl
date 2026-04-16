# M2d Consensus — Orchestrator Synthesis

**Milestone**: Bennett-cc0 / Bennett-i2a6 / M2d — conditional MUX-store guarding.
**Date**: 2026-04-16.
**Input**: `docs/design/m2d_proposer_A.md` (snapshot+MUX at lower site) and
`docs/design/m2d_proposer_B.md` (pred-folded guarded callees).

## Chosen design: **B** (pred-folded guarded callees)

Rationale:

- **Gate cost**: B adds ~128 gates per 4x8 guarded store vs A's ~320 — **~2.5× cheaper**. At MD5/SHA-256 scale (PRD §6 headline), this compounds.
- **Structural fit**: B mirrors the existing `soft_mux_store_NxW` pattern exactly. Same `@eval` loop idiom in `softmem.jl`. New callees register via the existing `register_callee!` infrastructure.
- **Reversibility**: one extra `Toffoli(pred_bit, match_bit_k, cond_k)` per slot, fresh ancilla per slot, same Bennett forward/reverse invariants as the unguarded callees. `pred` is write-once/read-only (M2c invariant).
- **A's skepticism correction acknowledged**: A's rough estimate (+32 CNOT + 64 Toffoli) turned out to be ~+256 CNOT + 64 Toffoli once `lower_mux!`'s CNOT-dominated MUX pattern was factored in. Confirms A is pricier than B.
- **B's skepticism correction**: B's claim of "~95× cheaper than wrap" is exaggerated — actual ratio is ~4× vs naive wrap (128 vs 500). Still dominates A. Does not change the choice.

### What we adopt from B

- New `soft_mux_store_guarded_NxW(arr, idx, val, pred) -> UInt64` callees for the 6 supported shapes (2x8, 4x8, 8x8, 2x16, 4x16, 2x32). Each folds `pred & 1` into the per-slot `ifelse` cond.
- Entry-block dispatch: `block_label == Symbol("") || block_label == ctx.entry_label` → existing unguarded callee (byte-identical baselines). Otherwise → guarded callee.
- `_lower_store_single_origin!` threads `block_label` through to each `_lower_store_via_mux_NxW!`.
- Predicate canonicalisation inside callee: `g = pred & UInt64(1)` explicitly, defends against high-bit garbage.
- Bit-exactness tests vs Julia reference (`ref_guarded_NxW(arr, idx, val, pred) = pred != 0 ? soft_mux_store_NxW(arr, idx, val) : arr`).
- Gate-count delta per shape: ~1.8-3.2% overhead vs unguarded, to be measured and pinned in BENCHMARKS.md after implementation.

### What we do NOT adopt from A

- Snapshot+MUX wrapping at the lower site — discarded. 2.5× more expensive and semantically redundant (we can fold the guard at a lower level).

### What we do NOT adopt from B

- B's `@eval` loop for the guarded callees uses `ntuple(...) do k` — this is fine for compact source, but the implementer should follow existing `softmem.jl` style: hand-written (4,8) and (8,8), then `@eval` loop for the other four. Consistency with the M1 pattern keeps diffs small.
- B's suggestion of a parametric test sweep is good but not required — L7f flip is sufficient for M2d acceptance. Richer sweeps can be added by follow-up.

## 1. Extraction / dispatch changes

### `src/softmem.jl` (+~120 lines)

Hand-write `soft_mux_store_guarded_4x8` and `soft_mux_store_guarded_8x8` following the existing hand-written style. Then `@eval` loop for (2,8), (2,16), (4,16), (2,32) mirrors the M1 addition pattern.

Template (4x8):

```julia
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
```

### `src/lower.jl` (+~40 lines)

In `_lower_store_via_mux_4x8!` and `_lower_store_via_mux_8x8!`, and in the `@eval` loop body (~line 2283), add the block_label dispatch:

```julia
# BEFORE
call = IRCall(res_sym, soft_mux_store_4x8,
              [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)

# AFTER
if block_label == Symbol("") || block_label == ctx.entry_label
    call = IRCall(res_sym, soft_mux_store_4x8,
                  [ssa(arr_sym), ssa(idx_sym), ssa(val_sym)], [64, 64, 64], 64)
else
    pred_wires = get(ctx.block_pred, block_label, Int[])
    length(pred_wires) == 1 ||
        error("_lower_store_via_mux_4x8!: expected single-wire predicate " *
              "for block $block_label, got $(length(pred_wires))")
    pred_sym = Symbol("__mux_store_pred_", tag)
    pw64 = allocate!(ctx.wa, 64)
    push!(ctx.gates, CNOTGate(pred_wires[1], pw64[1]))   # promote 1→64 via low bit
    ctx.vw[pred_sym] = pw64
    call = IRCall(res_sym, soft_mux_store_guarded_4x8,
                  [ssa(arr_sym), ssa(idx_sym), ssa(val_sym), ssa(pred_sym)],
                  [64, 64, 64, 64], 64)
end
```

Same pattern in the parametric `@eval` loop body. Thread `block_label` through `_lower_store_single_origin!` at line 2083.

Signatures: `_lower_store_via_mux_NxW!` gains a trailing `block_label::Symbol=Symbol("")` kwarg. Default keeps backward compatibility for any direct callers (the sentinel routes to unguarded, same as M2c).

### `src/Bennett.jl` (+6 lines)

Six `register_callee!(soft_mux_store_guarded_NxW)` calls alongside existing M1 lines.

## 2. Invariants to preserve (CLAUDE.md §6)

Non-negotiable regression check after M2d lands:
- i8 adder = 100 gates / 28 Toff
- i16 = 204 / 60 Toff
- i32 = 412 / 124 Toff
- i64 = 828 / 252 Toff
- soft_fma = 447,728 / 148,340 Toff
- soft_exp_julia = 3,485,262 / 1,195,196 Toff
- Shadow W=8 = 24 CNOT / 0 Toff
- All UN-GUARDED MUX EXCH store variants byte-identical: 4x8=7,122 / 8x8=14,026 / 2x8=3,408 / 2x16=3,424 / 4x16=6,850 / 2x32=3,072.
- All MUX EXCH load variants byte-identical: 4x8=7,514 / 8x8=9,590 / 2x8=1,472 / 4x16=4,192.

The entry-block bypass protects all of these.

## 3. Tests

- **L7f** flip `@test_broken` → `@test`:
  ```julia
  c = _compile_ir(ir)
  @test verify_reversibility(c)
  # pred=true path: write at idx 0 then read → val
  @test simulate(c, (Int8(5), Int8(0), true)) == Int8(5)
  # pred=false path: no write, read defaults to 0
  @test simulate(c, (Int8(5), Int8(0), false)) == Int8(0)
  ```

- **Bit-exactness test** (new file or append to `test/test_soft_mux_mem.jl`): 1000 random `(arr, idx, val, pred)` tuples per shape verify guarded callee matches `ref_guarded_NxW`:
  ```julia
  ref(arr, idx, val, pred) = pred != 0 ? unguarded_callee(arr, idx, val) : arr
  ```

## 4. What this does NOT do (deferrals)

- **Multi-origin dynamic idx** — existing error at `src/lower.jl:~2072` remains. File follow-up if needed.
- **MUX-load guarding** — loads emit into fresh wires; no semantic bug without guarding (just wasted wires on inactive path). Not in M2d.
- **Merging guarded + unguarded callees into one** — would perturb baselines. Separate callees preserve.
- **Shadow path** — unchanged (M2c already handles).

## 5. Implementer flow

1. **RED**: L7f flipped to `@test` + sweep. Should fail (pred=false still returns 5 not 0).
2. Add `soft_mux_store_guarded_4x8` and `_8x8` to `softmem.jl`, hand-written.
3. Add `@eval` loop for (2,8), (2,16), (4,16), (2,32) guarded variants.
4. Export / register all 6 via `register_callee!` in `src/Bennett.jl`.
5. **Bit-exactness** test: 1000 random tuples per shape vs Julia reference. Must pass before proceeding.
6. Update `_lower_store_via_mux_4x8!` and `_lower_store_via_mux_8x8!` with the dispatch branch. Add `block_label::Symbol=Symbol("")` kwarg.
7. Update `@eval` loop body in `lower.jl` (generated `$store_fn`) with same dispatch.
8. Thread `block_label` through `_lower_store_single_origin!` to each `_lower_store_via_mux_*!` call.
9. L7f GREEN. `verify_reversibility` passes on both `pred=true` and `pred=false`.
10. Full suite passes. Investigate any regression (CLAUDE.md §7).
11. Regenerate BENCHMARKS.md. Verify unguarded baselines byte-identical. Add new guarded rows.
12. Update WORKLOG.md per CLAUDE.md §0 with session entry + banner update.
13. Close Bennett-i2a6 via `bd`.

## 6. Estimated cost

~280 LOC total across `softmem.jl`, `lower.jl`, `Bennett.jl`, `test/`, `BENCHMARKS.md`. One atomic commit.
