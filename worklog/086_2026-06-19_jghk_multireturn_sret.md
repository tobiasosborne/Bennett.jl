# 086 — 2026-06-19 — Bennett-jghk — multi-return-site sret extraction

**Bead:** `Bennett-jghk` (P1, on the `bennettvm-7xa` fdict critical path via
`bennettvm-416r.11`). CORE change (`src/extract/module_walk.jl` terminator path
+ `src/extract/sret.jl`) — done via the **3+1 protocol** (2 proposers + 1
implementer + orchestrator review). Lands the multi-return-site sret capability.

## What landed
Before: `_collect_sret_writes` folded every sret store into ONE global
`slot_values` dict and synthesised the aggregate-return chain ONCE at the single
`ret void`. A function that builds its >16-byte tuple on multiple branches tripped
the per-slot "multiple stores" reject on the 2nd arm.

After: stores are collected **per store-bearing block** (`SretWrites.block_slot_values`),
and synthesis emits a value-bearing `IRRet` **per store block**, dropping the
store-free `ret void` funnel. The single-store-block path is byte-identical
(legacy `slot_values` aliases the one block's dict; same `counter`; gate-count
39/39 unchanged).

## The load-bearing learning (Rule 5 / Law 1 saved us)
Both 3+1 proposers independently mis-modeled the IR: they assumed stores live in
(or reach via dominance) the per-`ret void` blocks, and proposed a hand-rolled
dominator tree / reaching-definitions merge. **The live probe showed otherwise.**
For the synthetic two-arm tuple AND `ht_keyindex2_shorthash!`, the auto-SROA'd O0
IR emits **one store-bearing block PER branch arm** (each writing *every* slot),
all `br`-ing to a **single store-free `ret void` funnel** (`common.ret`). So:
- There is only ONE `ret void` site; the stores are in its predecessors.
- The right mechanism is **per-store-BLOCK synthesis**, NOT per-ret-void-site.
- Each store block becomes its own `IRRet`; the existing
  `driver.jl` `resolve_phi_predicated!` multi-IRRet merge (the same one every
  ordinary `cond ? a : b` function uses) reconciles them — **no new dominator
  tree**. The implementer explicitly rejected the proposers' dominator-tree
  designs as the false-path-sensitization hazard CLAUDE.md's phi section warns
  about, and converted their "shared-predecessor SUPPORTED" tests into fail-loud
  **REJECT** tests. Moral: design from probed IR, not from a plausible CFG model.

## Fail-loud scoping (no silent miscompile)
- Within-a-single-block duplicate store → still loud (unchanged, just per-block).
- "Every slot written" assert is now **per store-bearing block** (stricter: an
  unwritten slot on one return path can no longer be masked by another path).
- Shared-predecessor / split-slot writes (a slot written only in a dominating
  predecessor) → **fail loud** (not supported; reaching-def merge deferred).
- Conditional branch out of a store block (fork-after-store) → fail loud.
- **Reviewer hardening (orchestrator +1):** an sret store block's *unconditional*
  `br` must target the store-free `ret void` funnel (verified via
  `LLVM.successors` ∈ `ret_void_blocks`). Without this, a store-block→store-block
  chain (S→T) would, after cutting S's edge, orphan T and let
  `resolve_phi_predicated!` silently return S's stale/overwritten values — a
  Rule-1 hole. Now rejected loudly (reject test added).

## Wall advanced, not cleared
`ht_keyindex2_shorthash!(Dict{Int8,Int8},Int8)` no longer trips the jghk
multi-store reject; it now advances to the **Bennett-59zi** wall — a recursive
sret-returning self-call into a `%sret_box` alloca followed by
`llvm.memcpy(%sret_return, %sret_box, 16)` (caught by `_try_handle_sret_memcpy_reject!`).
So jghk does NOT make the fdict closure extract end-to-end: the `test_d1b_julia_set.jl`
GATE E `@test_broken` (`:skip` set ≥4) stays broken (root still hits
`julia.get_pgcstack` [Bennett-6x2w]; `setindex!`/`rehash!` hit the ptr-return wall
[Bennett-lf14]; `ht_keyindex2` hits 59zi). The stale GATE-E comment claiming "all
three Dict helpers hit ptr-width" was corrected to the probed reality.

## Verification (orchestrator, --check-bounds=yes)
- `test_jghk_multireturn_sret.jl` 43/43 (homogeneous [3×i64] + hetero {i64,i8}
  two-arm with exhaustive simulate + `verify_reversibility`; 4 fail-loud rejects).
- `test_gate_count_regression.jl` 39/39 **byte-identical** (single-return untouched).
- `test_sret.jl` 4195/4195; `test_dv1z_hetero_sret.jl` 142/142; `test_d1b_julia_set.jl`
  30 pass + 1 broken (expected).

## Next on the fdict runway
`Bennett-59zi` (recursive sret self-call + memcpy) is the next `ht_keyindex2`
wall; `Bennett-lf14` (ptr-return cell model) unblocks `setindex!`/`rehash!`;
`Bennett-6x2w` (get_pgcstack/GC-frame) gates the root. All three + CW-D2/D3 + 90l
remain before `bennettvm-7xa`.
