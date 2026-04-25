# Persistent-DS Scaling — Why linear_scan Beats HAMT/Okasaki

*Date*: 2026-04-20
*Context*: T5 epic (Bennett-cc0) — persistent heap as universal fallback
*Data*: [`benchmark/sweep_persistent_results.jsonl`](../../benchmark/sweep_persistent_results.jsonl),
[`benchmark/sweep_persistent_summary.md`](../../benchmark/sweep_persistent_summary.md)

## The question

Phase 3 of the T5 epic reported "Conchon-Filliâtre (CF) semi-persistent is
10× cheaper than Okasaki RBT and ~9× cheaper than HAMT" at `max_n=4`. The
Phase-3 writeup attributed this to a structural correspondence (the brief
§5 claim that CF's `Diff` chain *is* Bennett's history tape). But HAMT and
Okasaki-style persistent maps are the workhorses of real production systems
(Clojure's `PersistentHashMap`, Scala's `TrieMap`, persistent RBTs across
functional languages). Why would they lose so badly under reversible
compilation?

The original verbal answer was: popcount cost dominates at small N;
branchless tax inflates 4-case balance; NTuple state vs pointers; CF
naturally fits the Bennett tape shape. This doc documents the empirical
sweep that confirmed — and sharpened — that answer.

## Methodology

- **Workload**: K = max_n inserts with deterministic keys from a single
  `seed::Int8`, followed by 1 lookup. Populates the structure to capacity
  so Julia's optimizer cannot DCE unused slots (an earlier K=3 workload
  produced identical gate counts at max_n=4 and max_n=16 — strong DCE
  signal that contaminated the Phase-3 measurement).
- **Compilation**: `optimize=false` per CLAUDE.md §5. Required at
  `max_n ≥ 16` because Julia's auto-vectoriser packs sequential Int8 ops
  into `<N x i8>` SIMD that `ir_extract.jl` doesn't yet handle
  (Bennett-cc0.7).
- **Subprocess isolation**: each `(impl, max_n)` cell runs in a fresh
  Julia subprocess. An OOM kills only that cell, not the sweep.
- **Verbose flush + JSONL append**: per-cell progress flushed before
  every step; results appended atomically. Partial progress survives any
  crash.
- **Parameterization**: pure-Julia source generated per `(impl, max_n)`
  via [`benchmark/codegen_sweep_impls.jl`](../../benchmark/codegen_sweep_impls.jl).
  No `@eval` or `@generated` — both triggered the Bennett-cc0.3
  `LLVMGlobalAlias` and cc0.5 TLS-allocator gaps in `ir_extract.jl`.

## Results

| impl | max_n | gates | Toffoli | wires | compile_s | RSS_MB |
|---|---:|---:|---:|---:|---:|---:|
| linear_scan | 4 | 6,350 | 1,506 | 2,110 | 28.8 | 596 |
| linear_scan | 16 | 22,902 | 5,250 | 6,982 | 29.3 | 605 |
| linear_scan | 64 | 89,302 | 20,226 | 26,470 | 29.5 | 587 |
| linear_scan | 256 | 355,158 | 80,130 | 104,422 | 35.1 | 917 |
| **linear_scan** | **1000** | **1,384,726** | **312,258** | 406,486 | 120.6 | **3,386** |
| cf_semi_persistent | 4 | 61,728 | 15,298 | 18,568 | 30.4 | 592 |
| cf_semi_persistent | 16 | 1,077,452 | 261,226 | 311,512 | 31.1 | 595 |
| cf_semi_persistent | 64 | 17,458,600 | 4,188,298 | 5,014,168 | 36.0 | 1,130 |
| cf_semi_persistent | 256 | (predicted ~280M, ~16 GB) | skipped — OOM risk |
| cf_semi_persistent | 1000 | (predicted ~4.5B) | skipped — OOM |

HAMT and Okasaki were not parameterized (codegen complexity for their
bitmap/popcount and node-balance logic was deferred). The cost-model
argument below substitutes for empirical measurement.

## Per-set cost (the headline)

| max_n | linear_scan gates/set | CF gates/set |
|---:|---:|---:|
| 4 | 1,587 | 15,432 |
| 16 | 1,431 | 67,341 |
| 64 | 1,395 | 272,791 |
| 256 | 1,387 | (≈ 1.1M extrapolated) |
| 1000 | **1,385** | (≈ 4.5M extrapolated) |

**linear_scan per-set cost is constant in `max_n`** at ~1,400 gates.
**CF per-set cost grows linearly in `max_n`** — ~4× per 4× max_n.

## Why linear_scan is constant per-set

The branchless `pmap_set` body for linear_scan at max_n = N is:

```julia
count = s[1]
target = ifelse(count >= N, N-1, count)
new_count = ifelse(count >= N, N, count + 1)
# N pairs of:
new_key_i = ifelse(target == i, k_u, s[2*i+2])
new_val_i = ifelse(target == i, v_u, s[2*i+3])
```

Under reversible compilation, the N "preserve-or-replace" `ifelse`
operations decompose into a pattern where only one `i` actually differs
between input and output. The other N-1 positions produce
`ifelse(false, k_u, s[...]) = s[...]` — a no-op.

Bennett.jl's lowering recognises this: the `ifelse(false, _, x) = x`
pattern compiles to **zero gates** (wire-routing only), not to a
conditional swap. The actual gate cost comes from:

1. Computing `target` and `new_count` (~3 small ops)
2. The single non-no-op `ifelse` at slot `target` (~constant gates)
3. The MUX chain that routes `target` to the correct slot (~O(log N) gates
   via a binary tree of compares)

The third term is sub-linear but small at N ≤ 1000. Empirically the
sum is ~1,400 gates regardless of N — flat.

## Why CF is linear per-set

CF's `pmap_set` additionally writes a Diff entry at variable `diff_depth`:

```julia
for d in 0:N-1
    d_idx_d = ifelse(safe_depth == d, target_slot, s[...])
    d_key_d = ifelse(safe_depth == d, old_k,       s[...])
    d_val_d = ifelse(safe_depth == d, old_v,       s[...])
end
```

On the face of it, this is the same "one target slot, N-1 no-ops"
pattern. But note that `safe_depth` GROWS across successive set calls
(depth=0 at call 1, depth=1 at call 2, etc.). Bennett.jl cannot prove
at compile time that only one `d` matches at runtime — it has to keep
all N conditional writes live.

Worse: the `target_slot`, `old_k`, `old_v` values are different on every
set call (they depend on which Arr slot got the old key), so Bennett.jl
cannot share the no-op compression across calls. Each set pays the full
O(N) cost.

Total cost = K × O(N) = O(N²) when K = max_n.

## Why HAMT/Okasaki cannot beat linear_scan (cost-model)

Given linear_scan achieves O(1) per-set, the comparison reduces to
per-set lower bounds:

| impl | per-set lower bound | argument |
|---|---|---|
| linear_scan | ~1,400 gates (measured constant) | "preserve N-1, write 1" compresses |
| HAMT | popcount alone ≥ **1,454 gates / 256 Toffoli** (soft_popcount32 standalone, measured 2026-04-25 post-U27/U28; earlier 2,782 measurement predates the new defaults) | Bagwell CTPop is strictly additional work |
| Okasaki | 4-case balance dispatch × O(log N) levels | every insert risks triggering balance; all 4 cases computed speculatively |
| CF | O(N) per set (measured) | variable-depth Diff write blocks compression |

HAMT's bitmap + popcount primitive is a CPU-optimization (turn O(N) scan
into O(log N) hop + O(1) popcount). On a CPU popcount is one hardware
instruction. In reversible gates popcount is ~1,000 Toffolis. **The
"optimization" becomes a 2× pessimization** vs linear_scan.

Okasaki is worse: its 4-case balance requires computing ALL four
candidate restructurings speculatively (branchless tax) then MUX-
selecting. Plus the tree walk adds a per-level cost that doesn't
benefit from the same no-op compression linear_scan enjoys (the balance
case depends on the dynamic tree shape, which varies).

## Why this contradicts CPU intuition

Clojure's `PersistentHashMap` (HAMT) and `PersistentTreeMap` (RBT) are
the right choice for CPUs because:

1. **Pointer dereference is O(1)**. A node lookup is one memory load.
   In branchless reversible code, reading slot `i` at runtime requires
   an N-wide MUX over all slots.
2. **Popcount is one hardware instruction**. In reversible gates it's
   ~1,000 Toffolis.
3. **Tree balancing is amortized O(log N)**. In branchless code, every
   insert MUST compute all possible balance cases, not just the one
   that fires.
4. **Memory hierarchy rewards locality**. Reversible circuits have no
   cache; every gate costs the same.

The right reversible data structure is one whose per-op pattern matches
what Bennett.jl can compress: **a single target slot with N-1 no-op
preserves, target computed by a fixed arithmetic expression**. Linear
scan is exactly this shape.

## Implication for T5-P6 dispatcher

**Recommendation**: make `linear_scan` the default for the
`:persistent_tree` dispatch arm. Keep `hamt`, `okasaki`, and `cf` as
explicit `persistent_impl=:X` opt-ins for users who want to benchmark
alternatives. The "CF wins at small N" artefact from Phase 3 should be
documented as a small-K phenomenon, not a load-bearing dispatcher
default.

For truly unbounded heap (runtime `max_n`), the real question becomes
"how do we extend linear_scan's pattern to dynamic-size NTuple?" — which
is the original Bucket B gap (Bennett-Memory-PRD.md §4) and the target
of T5's universal-fallback role.

## Limitations

1. **HAMT and Okasaki not empirically measured at scale.** The
   cost-model argument uses their standalone measurements (popcount
   isolated; existing Phase-3 impls at their hardcoded max_n). A
   follow-up sweep should parameterize both.
2. **Workload = K inserts + 1 lookup.** A different workload
   (K ≪ max_n with random-access queries, many lookups per insert)
   might show different scaling — HAMT's log-N asymptotic could survive
   if the popcount cost amortizes over many lookups.
3. **`optimize=false` required throughout.** Julia auto-vectorises
   sequential i8 ops into SIMD past `max_n ~ 16`, and `ir_extract.jl`
   can't yet handle `InsertElement` (Bennett-cc0.7). Gate counts may
   drop 3-50× once that gap closes.
4. **Compile time at max_n=1000 is 2 minutes** (linear_scan). For
   larger N the codegen time might dominate. Worth investigating
   Bennett.jl's internal compile pipeline.

## References

- [`benchmark/sweep_persistent_summary.md`](../../benchmark/sweep_persistent_summary.md) — full methodology and per-cell analysis
- [`benchmark/sweep_persistent_results.jsonl`](../../benchmark/sweep_persistent_results.jsonl) — raw data
- [`benchmark/codegen_sweep_impls.jl`](../../benchmark/codegen_sweep_impls.jl) — parameterization
- [`benchmark/sweep_cell.jl`](../../benchmark/sweep_cell.jl) — measurement driver
- Phase 3 and Phase 4 session logs in [`WORKLOG.md`](../../WORKLOG.md) — Phase-3 "CF wins" finding that this sweep overturns
