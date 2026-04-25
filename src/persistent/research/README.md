# `src/persistent/research/` — preserved-but-deprecated impls

This directory holds reversible persistent-map implementations that have been
**relocated out of the production path** but **deliberately preserved** for
possible future thaw. Files here are *not* loaded when `using Bennett` runs,
not exported from the `Bennett` namespace, and not exercised by the default
test suite. They remain on disk, in git, and compile cleanly in isolation.

> **Pointer:** Bennett-uoem / U54 (2026-04-25 relocation). Empirical basis:
> `worklog/026_2026-04-20_session_log_persistent_ds_scaling_sweep_phase_3_co.md`.
> Original catalogue context: `reviews/2026-04-21/19_persistent_memory.md`,
> `reviews/2026-04-21/UNIFIED_CATALOGUE.md` §U54.

## Why these are not in the production path

The 2026-04-20 scaling sweep measured per-`set` gate cost across persistent-map
implementations at workloads up to `max_n = 1000`. The headline:

| Impl                  | per-`set` cost            | Total at `max_n = 64` (K = max_n inserts) |
| --------------------- | ------------------------- | ----------------------------------------: |
| `linear_scan` (kept)  | **~1,400 gates, constant in `max_n`** |                            89,302 gates |
| `cf_semi_persistent`  | grows ~linearly in `max_n` (≥272,791 at `max_n=64`)  |                       17,458,600 gates |
| `okasaki_rbt`         | 4-case balance + tree-walk; floor in the thousands   |   not parameterised; cost-model implies > LS |
| `hamt`                | popcount alone ≥ 2,782 gates per call                |   not parameterised; cost-model implies > LS |

`linear_scan` is at the floor of what Bennett.jl can produce for the
persistent-map protocol — the "MUX one of N slots into one target with N-1
no-op preserves" pattern compresses to ~constant gates per `set` regardless
of capacity. Tree- and trie-shaped impls strictly *add* work (popcount,
balance dispatch, traversal); their per-`set` lower bound exceeds linear
scan's empirical constant. Hash-cons compression layered on top doesn't
change the verdict: even `cf + feistel` (the cheapest hash atop the
cheapest losing impl) measured 65,198 gates on a 3-set / 1-get demo at
`max_n = 4`, vs `linear_scan = 436` gates at the same workload — a 150×
overhead.

The structural insight, recorded in worklog 026: **structures that fight
against reversibility's natural shape pay huge constant factors**. CPU-cheap
primitives (popcount, pointer deref, tree balance) are gate-expensive. The
"right" reversible DS is one whose per-op pattern matches what Bennett.jl
already compresses well — a single target slot with N-1 no-op preserves.

## Why preserved, not deleted

The implementations encode real algorithmic content (Bagwell HAMT, Okasaki
RBT, Conchon-Filliâtre semi-persistent arrays, Mogensen Jenkins-96 reversible
hash). The cost-model verdict above applies to a single workload class —
"populate to capacity, then read." Other workload shapes may yet surface
where these designs win:

- **K ≪ max_n with random-access reads.** HAMT's log-N asymptotic might
  amortise the popcount overhead over fewer ops. (Worklog 026 deferred
  follow-up #3.)
- **Optimisation pipeline maturity.** Worklog 026 ran with `optimize=false`
  per CLAUDE.md §5. Once `optimize=true` becomes safe end-to-end (gated by
  Bennett-cc0.7 / `InsertElement` and friends), gate counts may drop 3-50×
  and the per-`set` constants may shift. Re-measure before re-deciding.
- **Different cost metric.** The sweep optimised total gate count; if
  Toffoli-depth or peak-live-wires becomes the binding constraint, the
  Pareto front may change.
- **Algorithmic ports of these designs to research protocols** (e.g.
  hash-cons RAM, content-addressed memory). The pieces here are the
  best-studied and most-cited reversible variants, even if they don't lead
  the gate-count Pareto front today.

These are *parked*, not condemned.

## What lives here

| File                         | Origin                                               | Thaw signal                                                                |
| ---------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------- |
| `okasaki_rbt.jl`             | Okasaki 1999 *Purely Functional Data Structures*     | Workload where balance amortisation beats LS's constant per-`set`          |
| `cf_semi_persistent.jl`      | Conchon & Filliâtre 2007/2008 (JFP + reproducibility brief) | Workload with O(1) reroot pattern that aligns with Bennett tape semantics  |
| `hamt.jl` + `popcount.jl`    | Bagwell 2001 *Ideal Hash Trees*                      | Workload with K ≪ max_n random-access reads where log-N asymptotic shows  |
| `hashcons_jenkins.jl`        | Mogensen 2018 *NGC* 36:203 Fig. 5 — 24 reversible mix ops | Need for a non-Feistel reversible hash (e.g. larger codomain, different distribution) |

The intentional kept impls — `linear_scan.jl`, `hashcons_feistel.jl`,
`interface.jl`, `harness.jl` — remain in `src/persistent/`.

## How to load a research impl ad hoc

These files are not loaded by `using Bennett`. To exercise one in a REPL or
a script:

```julia
using Bennett                                   # loads winners + interface + harness
include(joinpath(pkgdir(Bennett),
                 "src/persistent/research/okasaki_rbt.jl"))
# Now `OKASAKI_IMPL`, `okasaki_pmap_new`, etc. are defined in Main (or your
# enclosing module). They satisfy the `PersistentMapImpl` protocol that
# `Bennett.verify_pmap_correctness` and `Bennett.pmap_demo_oracle` consume.
verify_pmap_correctness(OKASAKI_IMPL)
```

The corresponding test files are gated behind the `BENNETT_RESEARCH_TESTS`
environment variable (default off). To run them:

```bash
BENNETT_RESEARCH_TESTS=1 julia --project -e 'using Pkg; Pkg.test()'
```

## Drift policy

Because these files are not loaded by default, they are not exercised on
every `Pkg.test()` run, and so can drift if the surrounding project evolves
(e.g. `interface.jl` changing the `PersistentMapImpl` shape). Two
mitigations:

1. **Periodic re-test under the env-var gate.** Before any thaw decision,
   run `BENNETT_RESEARCH_TESTS=1 julia --project -e 'using Pkg; Pkg.test()'`
   to confirm the research impls still compile and pass.
2. **Interface stability.** `interface.jl` and `harness.jl` are
   load-bearing; treat changes to either as a research-impl breaking
   change and re-run the gated suite.

If a research impl bit-rots beyond easy repair, the canonical version is
in git history (search for the file path before its move date). No content
is ever discarded.

## Cross-references

- `Bennett-uoem` / U54 — this relocation, umbrella bead.
- `Bennett-ph5m` / U75 — namespace cleanup; persistent-map identifiers no
  longer leak top-level after this move.
- `Bennett-Memory-T5-PRD.md` — original Phase-3/Phase-4 design that put
  these impls in the catalogue.
- `worklog/026_2026-04-20_*.md` — sweep that reversed the Phase-3
  conclusion and motivated this relocation.
- `worklog/025_2026-04-17_*.md` — Phase 3 completion log; Pareto data.
- The 12 catalogue beads mooted by this relocation: U20 (Bennett-hmn0),
  U21 (n3z4), U22 (sqtd, partial — Feistel stays), U120 (e89s), U121
  (ivoa), U122 (uxn2), U123 (jvpm), U124 (fa4g), U125 (okvg), U126 (wout),
  U162 (d1io), U207 (tzga). Each is a bug or refactor in code that no
  longer participates in the production path; assess at U54 close.
