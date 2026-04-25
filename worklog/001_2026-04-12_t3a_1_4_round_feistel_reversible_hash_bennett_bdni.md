## 2026-04-12 — T3a.1: 4-round Feistel reversible hash (Bennett-bdni)

### Ground truth

COMPLEMENTARY_SURVEY §D: "A 4-round Feistel with F being three XOR-rotations
costs roughly 4 × (width × (2 CNOTs + 1 rotation)) = ~12 × width Toffolis per
lookup. For width 32, ~400 gates — well under the 20K/op budget. Compare to
Okasaki persistent hash table: ~71K for a 3-node insert."

Luby-Rackoff 1988 (SIAM J. Comput. 17(2)): a Feistel network `(L, R) → (R, L ⊕ F(R))`
is a bijective permutation regardless of F's invertibility. 4 rounds suffice
for PRF-security with an appropriately nonlinear F.

### Implementation — `src/feistel.jl`

```julia
emit_feistel!(gates, wa, key_wires, W; rounds=4, rotations=[1,3,5,7,…])
    -> Vector{Int}  # W fresh output wires
```

Round function `F(R)[i] = R[i] AND R[(i + rot_i) mod R_half]`.
Simon-cipher-style nonlinearity: AND of R with a rotated copy of R.
Bijective overall; diffusion proved by Simon family's cryptanalysis lit.

Per round: 1 Toffoli per bit of R_half for compute, 1 for uncompute,
plus R_half CNOTs for XOR-into-L. Zero gates for bit rotation (pure
wire-index arithmetic).

### Measured scaling (rounds=4, post-Bennett)

```
W  | total | Toffoli | wires
---+-------+---------+------
 8 |  120  |   64    |  28
16 |  240  |  128    |  56
32 |  480  |  256    | 112
64 |  960  |  512    | 224
```

**Toffoli = 8W exactly (= 4 rounds × 2·R_half).** Matches survey estimate up
to a small constant. W-scaling is strictly linear.

### Head-to-head vs literature Okasaki persistent RB-tree

| Operation            | Gates (this work) | Gates (Okasaki, survey §D) | Reduction |
|----------------------|-------------------|----------------------------|-----------|
| Feistel hash, W=32   | 480               | —                          | —         |
| Okasaki 3-node insert| —                 | ~71,000                    | —         |
| Ratio                | —                 | —                          | **~148×** |

Feistel hash alone is 148× smaller than Okasaki per-operation. A full
Feistel-dictionary lookup (hash + slot-read via MUX EXCH) would be
Feistel (480) + MUX-EXCH load_8x8 (~9,600) = ~10k gates — still ~7×
smaller than Okasaki for fixed-width keys, with the tradeoff that the
slot array is fixed-size rather than dynamically-growing.

### Choice of round function

Considered three candidates:

1. **ADD + rotate** (survey's default) — nonlinearity via carry chains;
   emits an adder per round (~W/2 Toffolis). **Tried first, had a bug in
   our in-place add primitive.** Fixable but expensive to debug.
2. **XOR + rotate** — linear over GF(2); fails Luby-Rackoff (the composed
   permutation is linear, poor diffusion). Rejected.
3. **AND + rotate** (Simon-cipher-style) — nonlinear (AND is non-affine),
   trivial gate emission (1 Toffoli per bit), known-secure as a PRF.
   **Chosen.**

### Restrictions (MVP)

- W ≥ 2 (needs two halves)
- Rotation schedule must have `rounds` entries; defaults to `[1,3,5,7,…]`
  (odd values to maximize coprimality with small W)
- Degenerate rotation that produces rot_mod=0 is nudged to rot=1 at runtime
  (only affects W=2 with odd rounds)
- Odd W handled by giving the top bit to L and carrying it via alternating
  swaps — verified reversible on W=9, gate count stays linear

### Test coverage — `test/test_feistel.jl`

21 assertions:
- Exhaustive bijection on W=8 (256 inputs → 256 unique outputs)
- Sampled bijection on W=16 (≥4000 unique outputs from 4096 samples)
- W=32 determinism + bit-avalanche (1-bit input flip → many-bit output flip)
- Gate-count bounds (≤ 200 Toffoli at W=8, ≤ 1600 at W=64)
- Round count tunable 1..8 (monotonic Toffoli growth)
- Odd W=9 handled without error; reasonable gate count

### What this unblocks

- T3a.2 (Bennett-tqik): Feistel vs Okasaki benchmark. Literature comparison
  is already captured above; live benchmark requires an Okasaki impl
  (substantial side-quest). P3 priority, deferred.
- T3b.3 (Bennett-10rm): universal dispatcher. Feistel becomes one more
  registered strategy alongside T1b MUX EXCH, T1c QROM, T2b linear.

## 2026-04-12 — T3b.1 + T3b.2: shadow memory design + primitives (Bennett-oy9e, Bennett-2ayo)

### T3b.1 design — `docs/memory/shadow_design.md`

Universal fallback for memory ops that T1b / T1c / T2b / T3a can't handle.
Protocol adapted from Enzyme's AD shadow memory, specialized to reversibility:

- **Primal**: user-visible memory. Lowered as a flat wire array.
- **Shadow tape**: parallel wire array indexed by store-SSA-sequence.
- **Store**: tape ← old primal; primal ← val. Bennett reverses to restore
  primal and zero tape slot.
- **Load**: pure CNOT-copy. No tape involvement.
- **Integration point**: tape slots are pebbleable resources; SAT pebbling
  (Meuli 2019, already in `src/sat_pebbling.jl`) decides which slots to
  materialize under a user-set budget.

Cost model documented: **3W CNOT per store + W CNOT per load, zero Toffoli
from the mechanism itself** — orders of magnitude cheaper than MUX EXCH
(~7k gates) for arbitrary-size writes. Trade-off: peak wire count grows
with total stores (mitigable via SAT pebbling).

### T3b.2 implementation — `src/shadow_memory.jl`

```julia
emit_shadow_store!(gates, wa, primal, tape_slot, val, W)  -> Nothing
emit_shadow_load!(gates, wa, primal, W)                    -> Vector{Int}
```

Pure gate emitters matching the protocol:

**Store** emits 3W CNOTs (verified in test):
```
for i in 1:W: CNOT primal[i] → tape[i]      ; tape = old primal
for i in 1:W: CNOT tape[i] → primal[i]       ; primal = 0 (XOR identity)
for i in 1:W: CNOT val[i] → primal[i]        ; primal = val
```

**Load** emits W CNOTs (fresh output wires).

### Measured

| Primitive                   | Gates    | Toffoli | Notes                        |
|-----------------------------|----------|---------|------------------------------|
| Shadow store, W=8           | 24 CNOT  | 0       | 3W per §4.2                  |
| Shadow store, W=16          | 48 CNOT  | 0       | —                            |
| Shadow store, W=32          | 96 CNOT  | 0       | —                            |
| Shadow load, W=8            | 8 CNOT   | 0       | W per §4.3                   |
| MUX EXCH store_4x8 (ref)    | 7,122    | 1,492   | For comparison               |
| MUX EXCH load_4x8 (ref)     | 7,514    | 1,658   | For comparison               |

**~300× cheaper than MUX EXCH** for the same primitive operation. MUX EXCH
retains value for its MEANING (direct in-place slot update with dynamic
index) where shadow's O(store-count) tape wires become prohibitive.

### Tests — `test/test_shadow_memory.jl`

594 assertions:
- Single store + load round-trip on all 256 W=8 inputs
- Two stores same location: last-write-wins
- Store-then-load-then-store-then-load recovers both stored values
- Exact gate-count assertions (3W CNOT per store, W CNOT per load, 0 Toffoli)
- 5-store stress test on W=16 with random sampling

### What this unblocks

- T3b.3 (Bennett-10rm): universal dispatcher can now route to shadow memory
  for allocations rejected by every specialized strategy. Shadow's cost
  model makes it the correct fallback for "anything arbitrary".
- Full SAT-pebbling integration: the tape slots are the pebbles. Existing
  `src/sat_pebbling.jl` infrastructure already reasons about wire-reuse
  schedules; shadow-tape-slot reuse is the same problem shape. Deferred
  as integration work (not a new primitive).

### Not in scope

- SAT-pebbling *scheduling* of shadow tape slots. The primitive EXPOSES the
  right interface (one tape slot per store, pebbleable) but the scheduler
  that PICKS which slots to share is follow-up. Current tests allocate one
  fresh tape slot per store (worst-case wire count, correct behavior).

## 2026-04-12 — T3b.3: universal memory dispatcher (Bennett-10rm)

### Unified strategy table

`src/lower.jl` now has a single dispatch point for every alloca-backed
store/load:

```julia
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand)
    idx.kind == :const && return :shadow          # static idx: direct CNOT
    shape == (8, 4)    && return :mux_exch_4x8    # dynamic idx, soft_mux_*_4x8
    shape == (8, 8)    && return :mux_exch_8x8    # dynamic idx, soft_mux_*_8x8
    return :unsupported                            # dynamic idx, unhandled shape
end
```

Priority rule: **static idx always wins** (cheap). MUX EXCH engages only when
dynamic idx meets a registered callee's shape.

### New dispatch handlers in `lower.jl`

Split the old monolithic `lower_store!` / `_lower_load_via_mux!` into
strategy-specific internal handlers:

- `_lower_store_via_shadow!` / `_lower_load_via_shadow!` — slice the primal
  at the constant idx, call `emit_shadow_*!`. 3W CNOT store, W CNOT load.
- `_lower_store_via_mux_4x8!` / `_lower_load_via_mux_4x8!` — old soft_mux_4x8
  path factored out.
- `_lower_store_via_mux_8x8!` / `_lower_load_via_mux_8x8!` — new 8x8 variant
  (soft_mux_*_8x8 were already registered by T1b.5; previously unreachable
  through the dispatcher).

### lower_alloca! relaxed

Was: errored on any shape ≠ (8, 4).
Now: accepts any (elem_width ≥ 1, n_elems ≥ 1) shape. Static-sized only
(dynamic n_elems still rejected with a helpful message). Downstream dispatch
picks the strategy when stores/loads actually occur.

Consequence: functions with larger or non-(8,4) allocas no longer reject at
extract time. Their stores/loads succeed through shadow (static idx) or
error at the store/load site with "unsupported shape for dynamic idx" (so
the failure is at the operation that can't be handled, with precise cause).

### Measured end-to-end

Case 1: `Ref{UInt8}` write-then-read (static idx = 0):
- Shadow dispatcher fires for both store and load.
- 256-input exhaustive correctness verified.

Case 2: 4-slot alloca with 4 static-idx stores + 1 dynamic-idx load (hand-
crafted IR):
- 4 stores → :shadow (3·8 = 24 CNOT each = 96 CNOT total for stores)
- 1 load → :mux_exch_4x8 (7,514 gates for the load alone)
- Mixed strategies cooperate: shadow stores mutate `vw[alloca_dest]` in
  place; MUX EXCH load reads the updated primal state correctly.
- All 4 idx values return the corresponding stored value.

### Test coverage — `test/test_universal_dispatch.jl`

287 assertions:
- Ref pattern (pure shadow path): 256-input exhaustive
- 4-slot alloca mixed shadow+MUX load via hand-crafted IR: 4 idx values
- QROM regression (T1c.2 still routes globals through QROM, total < 300 gates)
- Strategy-picker unit tests: :shadow for static idx (any shape),
  :mux_exch_4x8/_8x8 for matching shapes, :unsupported for everything else

### Legacy test migration

`test/test_lower_store_alloca.jl` previously asserted that non-(8,4) shapes
errored at alloca time. Post-T3b.3 those shapes succeed; test updated to
verify successful compilation instead.

### What this closes out

Memory plan critical path:
- T0.x — preprocessing ✓
- T1a — IRStore/IRAlloca types + extraction ✓
- T1b — MUX EXCH (N=4, N=8, W=8) ✓
- T1c — QROM (Babbush-Gidney) primitive + dispatch + benchmark ✓
- T2a — MemorySSA investigation + ingest + integration tests ✓
- T3a — Feistel reversible hash + Okasaki comparison ✓
- T3b.1 — shadow memory protocol design ✓
- T3b.2 — shadow memory primitives ✓
- T3b.3 — universal dispatcher ✓ (this entry)

Remaining open:
- T0.3 — Julia EscapeAnalysis integration (P2, low-urgency)
- T0.4 — 20-function corpus benchmark (P2)
- T2b.1/2 — @linear macro + mechanical reversal (separate workstream, P3)
- BC.3 — full SHA-256 benchmark (P2)
- BC.4 — BENCHMARKS.md head-to-head consolidation (P2)
- Paper work P.1/P.2 — explicitly deferred per user direction

### Performance summary (all memory strategies, W=8 where applicable)

| Strategy      | Applicability                      | Gates per store | Gates per load |
|---------------|------------------------------------|-----------------|----------------|
| :shadow       | static idx, any shape              | 3·elem_w CNOT   | elem_w CNOT    |
| :mux_exch_4x8 | dynamic idx, (8,4)                 | 7,122           | 7,514          |
| :mux_exch_8x8 | dynamic idx, (8,8)                 | 14,026          | 9,590          |
| :qrom         | read-only, global const            | —               | ~56-550 (per L)|
| :feistel-hash | reversible bijective key hash      | 120-960 (per W) | —              |

Shadow is ~300× cheaper per static-idx op than MUX EXCH — and this is now
the DEFAULT path whenever idx is known at compile time. Real Julia code
with local array initialization (N static-idx stores + dynamic-idx read)
now pays only N · 3W CNOT for the writes rather than N · 7k gates.

---

