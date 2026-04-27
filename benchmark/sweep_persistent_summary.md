# Persistent-DS Scaling Sweep

## 2026-04-27 refresh — pipeline-wide ~3-4× gate improvement; 5qrn peephole delta < 1%

**Bennett-1xub** re-ran the eight 2026-04-20 cells (linear_scan: max_n ∈ {4,16,64,256,1000}; cf: max_n ∈ {4,16,64}) at HEAD (post-5qrn peephole, post-many cc0/U-series fixes). Two passes per cell where applicable: peephole stubbed via `_try_identity_peephole!` early-return, then restored.

### Total-cost refresh — HEAD (2026-04-27, peephole on) vs 2026-04-20

| impl | max_n | 2026-04-20 gates | 2026-04-27 gates | factor |
|---|---:|---:|---:|---:|
| linear_scan | 4    |       6,350 |     1,810 | 3.5× |
| linear_scan | 16   |      22,902 |     6,642 | 3.4× |
| linear_scan | 64   |      89,302 |    26,522 | 3.4× |
| linear_scan | 256  |     355,158 |   106,284 | 3.3× |
| linear_scan | 1000 |   1,384,726 |   414,028 | 3.3× |
| cf          | 4    |      61,728 |    15,084 | 4.1× |
| cf          | 16   |   1,077,452 |   292,528 | 3.7× |
| cf          | 64   |  17,458,600 | 6,206,464 | 2.8× |

linear_scan per-set drops from ~1,400 to ~414 gates/set (3.3× across the entire range, asymptotically constant). The headline scaling shape is unchanged: linear_scan O(max_n), cf O(max_n²). The ~3-4× factor is shared across cells and is NOT 5qrn-specific — it accumulates from the post-2026-04-20 commits (cc0.x ConstantExpr / SLP / pointer / phi work, fold_constants default flip, sret + callee infrastructure, Bennett-y986 loop dispatch, Bennett-jepw diamond phi, etc.).

### 5qrn peephole delta (HEAD with vs without peephole)

`_try_identity_peephole!` stubbed at entry to isolate 5qrn's impact:

| impl | max_n | peephole off | peephole on |   Δ | Δ % |
|---|---:|---:|---:|---:|---:|
| linear_scan | 4    |   1,828 |   1,810 |    -18 | 1.0% |
| linear_scan | 16   |   6,708 |   6,642 |    -66 | 1.0% |
| linear_scan | 64   |  26,780 |  26,522 |   -258 | 1.0% |
| cf          | 4    |  15,174 |  15,084 |    -90 | 0.6% |
| cf          | 16   | 294,034 | 292,528 | -1,506 | 0.5% |

**Peephole impact on this workload: 0.5–1.0%, NOT the catalogue's estimated 20-40%.** Reason: the slot-preserve pattern in `sweep_ls_pmap_set/get` and `cf` lowers to `ifelse`/select chains, not `x+0` / `x*1`. The catalogue's H-2 estimate (review #17) modelled "preserve N-1 slots" as arithmetic identities; in practice it's branchless select. The peephole fires only on a few constant-folded perimeter ops (NOT-count differs by 18-258), not on the bulk of the lowered slot-write logic.

The Bennett-5qrn micro-benchmark numbers (`x*Int8(1)` 692 → 26 gates, 26.6×) ARE real — but for THIS workload the 5qrn impact is negligible. Other peepholes (selecting away the `ifelse(cond, x, x)` redundancy, or eliminating two-wire AND-with-self) would target this workload more directly; not currently filed.

### Compile-time anomaly: cf @ max_n=64

| max_n | 2026-04-20 cf compile_s | 2026-04-27 cf compile_s | factor |
|---:|---:|---:|---:|
| 4  |  30.4 |    3.3 | 9.3× faster |
| 16 |  31.1 |    5.1 | 6.1× faster |
| 64 |  36.0 | **1213.5** | **33.7× SLOWER** |

Linear_scan compile time scales gracefully (3-76 s for max_n 4..1000); cf compile time was effectively constant in 2026-04-20 (30-36 s) but is now super-linear at max_n ≥ 64. Hypothesis: a phi/select resolution path that was cheap pre-cc0 series is now O(max_n²) or worse on cf's diff-bookkeeping pattern. Filed as a follow-up bead by 1xub. Not in scope for the BENCHMARKS.md refresh.

### Methodology notes

- All cells `optimize=false` (per CLAUDE.md §5 + Bennett-cc0.7).
- Subprocess-isolated via `benchmark/sweep_cell.jl <impl> <max_n>`.
- Peephole-off measurements performed by inserting `return nothing` as the first statement of `_try_identity_peephole!` in `src/lower.jl`; restored verbatim via `git checkout HEAD -- src/lower.jl`.
- All cells `verified=true` in both passes.

---

# Persistent-DS Scaling Sweep — 2026-04-20

## Question

When does HAMT/Okasaki overtake linear_scan as max_n grows? Is N=1000 reachable?

## Methodology

- **Workload**: K = max_n inserts (deterministic keys derived from a single
  Int8 `seed`), then 1 lookup. Populates the structure to its full declared
  capacity so the optimizer cannot DCE unused slots.
- **Compilation**: `optimize=false` per CLAUDE.md §5 (and required to avoid
  Julia's auto-vectorisation tripping the InsertElement gap, Bennett-cc0.7).
- **Subprocess isolation**: each (impl, max_n) cell runs in a fresh Julia
  process so an OOM kills only that cell, not the sweep.
- **Verbose flush + JSONL append**: per-cell output flushed before/after
  every step; results appended atomically to `sweep_persistent_results.jsonl`.

## Cells run

| impl | max_n | gates | Toffoli | wires | compile_s | RSS_MB | verified |
|---|---:|---:|---:|---:|---:|---:|---|
| linear_scan | 4 | 6,350 | 1,506 | 2,110 | 28.8 | 596 | ✓ |
| linear_scan | 16 | 22,902 | 5,250 | 6,982 | 29.3 | 605 | ✓ |
| linear_scan | 64 | 89,302 | 20,226 | 26,470 | 29.5 | 587 | ✓ |
| linear_scan | 256 | 355,158 | 80,130 | 104,422 | 35.1 | 917 | ✓ |
| linear_scan | 1000 | **1,384,726** | **312,258** | 406,486 | 120.6 | 3,386 | ✓ |
| cf_semi_persistent | 4 | 61,728 | 15,298 | 18,568 | 30.4 | 592 | ✓ |
| cf_semi_persistent | 16 | 1,077,452 | 261,226 | 311,512 | 31.1 | 595 | ✓ |
| cf_semi_persistent | 64 | 17,458,600 | 4,188,298 | 5,014,168 | 36.0 | 1,130 | ✓ |
| cf_semi_persistent | 256 | ~280M (predicted) | — | — | — | ~16 GB | not run (OOM risk) |
| cf_semi_persistent | 1000 | ~4.5B (predicted) | — | — | — | OOM | not run |
| HAMT | * | not parameterized — using Phase-3 baseline at max_n=8 (3-set + 1-get, optimize=true) | | | | | |
| Okasaki | * | not parameterized — using Phase-3 baseline at max_n=4 | | | | | |

## Per-set cost (the headline)

| max_n | LS gates/set | CF gates/set |
|---:|---:|---:|
| 4 | 1,587 | 15,432 |
| 16 | 1,431 | 67,341 |
| 64 | 1,395 | 272,791 |
| 256 | 1,387 | (≈1.1M) |
| 1000 | **1,385** | (≈4.5M) |

**linear_scan per-set cost is constant in max_n**: ~1,400 gates regardless
of N. **CF per-set cost grows linearly in max_n**: ~4× per 4× max_n.

## Total-cost scaling

- **linear_scan: O(max_n) total** — Bennett.jl's lowering compresses the
  branchless "preserve all-but-one slot" pattern into ~constant gates per
  set. The "branchless tax" does NOT apply uniformly; it depends on the
  structural form of the branchless code.
- **CF: O(max_n²) total** — Diff bookkeeping writes at variable
  `diff_depth` and the per-slot operations are not structurally identical
  across the K calls, so Bennett.jl can't compress them.

## Implications for the original "CF wins" finding

**The Phase-3 finding was a small-K artefact.** With K=3 fixed inserts on
max_n=4, CF ranked cheapest because it had 3 Diff entries to manage vs LS's
3 slot writes. With K = max_n, CF's quadratic blowup makes it the WORST
viable impl.

The Phase-0 brief §5 correspondence claim ("Diff chain IS Bennett's tape")
holds STRUCTURALLY but does NOT translate to a gate-count win at scale —
because the Diff-write at variable depth is exactly the kind of dynamic-
indexing pattern Bennett.jl can't compress.

## Why HAMT/Okasaki should NOT overtake linear_scan (cost-model argument)

Given LS achieves O(1) per-set, the asymptotic comparison becomes:

| Impl | per-set lower bound |
|---|---|
| linear_scan | ~1,400 gates (measured constant) |
| HAMT | popcount alone ≥ 2,782 gates (measured standalone) |
| Okasaki | 4-case balance + multi-level traversal ≥ thousands of gates per set |
| CF | scan + Diff write at variable depth ≥ O(N) per set |

**HAMT/Okasaki cannot be cheaper per-set than LS** because their per-set
work strictly includes more arithmetic (popcount, balance dispatch, tree
walks). And in our measurement, LS's per-set is already at the floor of
what Bennett.jl can do for this protocol.

## Paper-relevant conclusion

**For the dispatcher's `:persistent_tree` arm (T5-P6), use linear_scan as
the default**. The asymptotic argument from the original Phase-3 finding
("CF correspondence pays off") is wrong at scale; the compress-the-no-op
optimisation in Bennett.jl flattens linear_scan's per-set cost to a
constant, defeating any log-factor win from tree-shaped DSes.

For unbounded heap (truly N → ∞), linear_scan also wins because no other
impl can match its O(1) per-set under reversible compilation. The right
question becomes "how do we extend the compilation pattern to truly
dynamic-size linear_scan?" — which is the original Bucket B gap and the
target of T5's universal-fallback role.

## Limitations of this sweep

1. **HAMT and Okasaki not parameterized** — the codegen complexity for
   their state layouts (popcount + bitmap for HAMT, recursive node+balance
   for Okasaki) was deferred. The cost-model argument above is the
   substitute. A follow-up sweep should parameterize both to confirm.

2. **K = max_n workload** — measures the cost of populating the structure
   to capacity. A different workload (K << max_n with random-access
   queries) might show different scaling, especially if HAMT's log-N
   asymptotic survives at large N.

3. **`optimize=false`** required throughout — `optimize=true` triggers
   Julia auto-vectorisation past max_n ~16, and ir_extract.jl can't yet
   handle InsertElement (Bennett-cc0.7). Numbers may drop 3-50× under
   `optimize=true` once that gap closes.

4. **Compile time at max_n=1000** is 2 minutes (LS) — manageable. CF at
   max_n=64 already took 36s. Larger CF cells would be both compile-slow
   and likely OOM.
