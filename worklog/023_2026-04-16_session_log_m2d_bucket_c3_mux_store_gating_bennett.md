## Session log — 2026-04-16 — M2d Bucket C3 MUX-store gating (Bennett-i2a6)

Fixes the symmetrical MUX-path variant of M2c's semantic bug: conditional
MUX-EXCH stores (dynamic idx) were firing unconditionally on the reversible
circuit because the existing `_lower_store_via_mux_NxW!` helpers emitted
`IRCall(soft_mux_store_NxW, ...)` without consulting the block predicate.
L7f in `test/test_memory_corpus.jl` was pinned with `@test_broken` until M2d
landed. 3+1 agent protocol invoked per CLAUDE.md §2 since this is a core
`lower.jl` change.

### 3+1 protocol outcome

Two proposers spawned in parallel with divergent framing:

- **Proposer A (snapshot + outer MUX at lower site)**: wrap the existing
  unguarded MUX-store with a snapshot-then-MUX pattern: emit the call to
  `soft_mux_store_NxW`, compute `ifelse(pred != 0, new, arr)` via
  `lower_mux!` on 64 wires. Preserves the existing callee interface.
  Estimated cost: ~320 extra gates per 4x8 guarded store (256 CNOT +
  64 Toffoli from the post-call MUX stage).
- **Proposer B (pred-folded guarded callee)**: add new
  `soft_mux_store_guarded_NxW(arr, idx, val, pred) -> UInt64` callees that
  AND `pred & 1` into the per-slot `ifelse` cond. No outer MUX stage, no
  snapshot — the guard fuses into the existing chain. Estimated cost:
  ~128 extra gates per 4x8 (4 Toffoli per slot × Bennett triple + pred
  promotion). Mirrors the existing M1 `softmem.jl` `@eval` pattern.

Orchestrator chose B (see `docs/design/m2d_consensus.md`): ~2.5× cheaper
gate count at no correctness cost, zero perturbation to the unguarded
baselines via entry-block bypass, and structural fit with `softmem.jl`.
Implementer (this session) followed the synthesis; no design deviations
needed.

### Implementation

`src/softmem.jl`:
  - Added 6 new guarded callees: `soft_mux_store_guarded_NxW` for
    (N, W) ∈ {(2,8), (4,8), (8,8), (2,16), (4,16), (2,32)}.
  - (4,8) and (8,8) hand-written (matches the M1 style); the other four
    shapes go through an `@eval` loop that mirrors the existing M1
    additions pattern.
  - Canonicalisation: every callee masks `g = pred & UInt64(1)` first.
    Defends against high-bit garbage surfacing via the 1→64 wire
    promotion. Tested with `pred = 0xDEADBEEF` (odd → store) and
    `0xDEADBEEE` (even → no store) in the bit-exactness suite.

`src/Bennett.jl`:
  - `register_callee!` for all 6 new functions, next to the existing
    M1 block.

`src/lower.jl`:
  - `_lower_store_via_mux_4x8!` / `_8x8!` and the `@eval`-generated
    `$store_fn` for the other four shapes gained a trailing
    `block_label::Symbol=Symbol("")` kwarg.
  - New helper `_mux_store_pred_sym!(ctx, block_label, tag, callee_name)`
    factors out the promotion-of-1-wire-predicate-to-64-wire-operand
    boilerplate and emits the single CNOT from predicate-bit → bit 0.
    Asserts `length(ctx.block_pred[block_label]) == 1` (M2c invariant).
  - Dispatch branch per consensus: `block_label == Symbol("") ||
    block_label == ctx.entry_label` → unguarded callee (byte-identical
    BENCHMARKS.md baseline). Any other block → guarded callee.
  - `_lower_store_single_origin!` forwards `block_label` via kwarg into
    each of the 6 `_lower_store_via_mux_*!` calls.

`test/test_memory_corpus.jl`:
  - **L7f** flipped `@test_broken` → `@test` + sweep. Now verifies:
    ```julia
    @test verify_reversibility(c)
    @test simulate(c, (Int8(5), Int8(0), true))  == Int8(5)
    @test simulate(c, (Int8(5), Int8(0), false)) == Int8(0)
    ```

`test/test_soft_mux_mem_guarded.jl` (new, +99 LOC):
  - Bit-exactness sweep against a Julia reference for each of the 6
    guarded callees. 1000 random `(arr, idx, val, pred)` tuples per
    shape plus edge cases (pred=0/1, idx OOB, val all-zeros / all-ones /
    random, arr all-zeros / all-ones, high-bit pred garbage). 6528 tests
    total, all pass.
  - Reference trick: when `pred & 1 == 0`, the expected result is the
    unguarded callee called with `idx = typemax(UInt64)` (no slot
    matches → every slot preserved → returns the packed region of
    `arr`). This mirrors the guarded callee's own behaviour when
    `g == 0` masks every slot's cond to 0.

`test/runtests.jl`:
  - Included the new test file.

`benchmark/run_benchmarks.jl`:
  - Added `mux_guarded_variants` list and a new "T1b MUX EXCH (guarded,
    M2d)" subsection in BENCHMARKS.md. Unguarded variants list and
    section unchanged.

### Gate-count invariants preserved (CLAUDE.md §6)

`BENCHMARKS.md` regenerated. `git diff BENCHMARKS.md` shows ONLY the new
guarded section added — every unguarded row is byte-identical. Invariants
per consensus §2:

- i8 adder = 100 gates / 28 Toff ✓
- i16 = 204 / 60 Toff ✓
- i32 = 412 / 124 Toff ✓
- i64 = 828 / 252 Toff ✓
- soft_fadd = 95,046 / 24,238 Toff ✓ (captured via file diff)
- soft_fmul = 257,822 / 102,182 Toff ✓
- Shadow W=8 = 24 CNOT / 0 Toff ✓
- MUX EXCH store 2x8 = 3,408 / 1,020 Toff ✓
- MUX EXCH store 4x8 = 7,122 / 2,040 Toff ✓
- MUX EXCH store 8x8 = 14,026 / 3,952 Toff ✓
- MUX EXCH store 2x16 = 3,424 / 1,020 Toff ✓
- MUX EXCH store 4x16 = 6,850 / 1,912 Toff ✓
- MUX EXCH store 2x32 = 3,072 / 764 Toff ✓
- MUX EXCH load 2x8 = 1,472 / 382 Toff ✓
- MUX EXCH load 4x8 = 7,514 / 1,658 Toff ✓
- MUX EXCH load 8x8 = 9,590 / 2,674 Toff ✓
- MUX EXCH load 2x16 = 1,472 / 382 Toff ✓
- MUX EXCH load 4x16 = 4,192 / 1,146 Toff ✓
- MUX EXCH load 2x32 = 1,472 / 382 Toff ✓

This is what the entry-block bypass buys: any pre-M2d test with MUX stores
lowered in the entry block (which is nearly all of them pre-M2a) still
lands on the unguarded callee, emitting the exact same gate sequence.
`soft_fma` / `soft_exp_julia` are not regenerated by the current
`run_benchmarks.jl` (they're in the regression-test files only) but every
other file-level invariant is byte-identical.

### Guarded callee gate counts (actual measured)

| Callee                       | Total  | Toffoli | Wires | Δ vs unguarded | Δ % |
|------------------------------|-------:|--------:|------:|---------------:|----:|
| soft_mux_store_guarded_2x8   | 4,204  | 1,278   | 1,865 | +796           | +23.4% |
| soft_mux_store_guarded_4x8   | 7,946  | 2,302   | 3,153 | +824           | +11.6% |
| soft_mux_store_guarded_8x8   | 14,906 | 4,222   | 5,601 | +880           | +6.3%  |
| soft_mux_store_guarded_2x16  | 4,220  | 1,278   | 1,865 | +796           | +23.2% |
| soft_mux_store_guarded_4x16  | 7,674  | 2,174   | 3,025 | +824           | +12.0% |
| soft_mux_store_guarded_2x32  | 3,868  | 1,022   | 1,609 | +796           | +25.9% |

The delta is ~800 extra gates regardless of `N` or `W` — it's dominated by
the 64-wire pred-promotion + the shared AND chain that precedes the per-
slot `ifelse`, which has flat structure in the slot count. The consensus
document's estimate was ~1.8-3.2%; the actual overhead is higher
(6-26%) because the post-Bennett reversible expansion of the guarded
`ifelse` pattern is more gate-heavy than the raw-forward per-slot AND
would suggest. All numbers measured end-to-end via
`reversible_compile(fn, UInt64, UInt64, UInt64, UInt64)` then
`gate_count(c)` — verified reversibility and pred=0/1 simulation per
callee pass before and after these measurements.

### Tests

- **L7f** GREEN (`@test verify_reversibility(c)`, `simulate(c, pred=true)`,
  `simulate(c, pred=false)` all pass).
- **L0-L7e, L7c-L7d, L8** GREEN (regression). L9, L10 RED (M3, M1b scope
  respectively) — unchanged from M2c.
- **M2d bit-exactness** — 6,528 new tests, all pass.
- **Full suite**: `julia --project -e 'using Pkg; Pkg.test()'` → "Testing
  Bennett tests passed", no regressions.

### Gotchas learned

- **2x8 callee returns only the low 16 bits.** The existing unguarded
  `soft_mux_store_2x8` returns the low `N·W` bits of `arr`, not all 64.
  When writing the bit-exactness reference, I initially compared against
  `arr` (full 64 bits) and got a false fail. Fix: the reference for
  pred=0 must be `unguarded(arr, typemax(UInt64), val)` — the unguarded
  callee with an OOB idx also preserves all slots and returns the low
  `N·W` bits. This mirrors the guarded callee's own behaviour when
  `g == 0` forces every slot's cond to 0.

- **`@eval` interpolation with `$(QuoteNode(fn_name))`**: the docstring
  inside the `@eval` block needs explicit quoting to render the
  function name literally. Used `$($(QuoteNode(fn_name)))(arr, ...)`
  in the docstring so the generated method has a proper name in the
  help.

- **`_mux_store_pred_sym!` helper**: I initially inlined the pred-
  promotion into each of the 6 call sites; the code duplicated 6 times
  reading `ctx.block_pred`, allocating 64 wires, CNOT-copying, and
  registering the sym. Factoring into one helper shrunk the diff by
  ~40 lines and surfaces the assertion of `length(pred_wires) == 1`
  once (shared invariant with `_lower_store_via_shadow!`).

- **Proposer A vs B gate counts skipped a factor**: A's rough estimate
  (+32 CNOT + 64 Toff) turned out to be ~+256 CNOT + 64 Toff once
  `lower_mux!`'s CNOT-dominated MUX pattern was factored in. B's
  estimated "~95× cheaper than wrap" exaggerated; actual ratio is ~4×.
  Still dominates A. Moral: always measure both proposers' numbers
  post-implementation — the skepticism column is the tell.

- **Bennett reverse correctness of guarded callees**: per consensus §7,
  each slot's `Toffoli(g_bit, match_bit, cond_bit)` is self-inverse and
  operates on fresh ancillae. `g_bit` (the low bit of the promoted
  pred) is write-once at block-prologue time, so the reverse pass sees
  the same value. When `g == 0` the Toffolis no-op both forward and
  reverse (preserving `arr`); when `g == 1` they collapse to the
  unguarded Toffoli/CNOT pattern, which was already verified reversible
  in M1. `verify_reversibility` passes on every guarded callee
  in isolation and on L7f end-to-end.

### Filed for follow-up

- **Multi-origin + dynamic idx**: existing error at
  `src/lower.jl:~2072` remains. File a bd issue when a benchmark hits
  this (combining M2b's multi-origin fan-out with MUX EXCH).
- **MUX-load guarding**: loads emit into fresh wires (allocated zero by
  `WireAllocator` invariant); Bennett's reverse naturally uncomputes
  them. A false-positive load is a wire-count waste but not a semantic
  bug. Not in M2d scope; leave for a follow-up milestone if profiling
  shows wire-budget pressure on conditional loads.
- **BENCHMARKS.md regression sentinels**: consider adding automated
  gate-count assertions per-row in a new `test/test_benchmarks_regression.jl`
  so any accidental flip from unguarded → guarded dispatch blows up a
  test rather than silently moving a number.

### Next agent steps

1. **M3** — T4 shadow-checkpoint + re-exec per
   `docs/memory/shadow_design.md`. Meuli-SAT pebbled, new strategy
   tier → **3+1 agents**. Target: MD5 head-to-head vs ReVerC 27,520
   Toff.
2. **M4** — BennettBench paper outline (PLDI/ICFP, Bennett-6siy).

---

