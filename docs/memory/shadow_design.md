# Shadow memory protocol design — T3b.1 (Bennett-oy9e)

**Date:** 2026-04-12
**Status:** Design complete. Reference implementation in T3b.2 (Bennett-2ayo).

## Problem statement

Bennett.jl's current memory story (T1b MUX-EXCH, T1c QROM) handles two ideal
cases: small writable alloca'd arrays (MUX-EXCH, N ≤ 16, W ≤ 8), and
compile-time-constant read-only tables (QROM, any L, any W ≤ 64). Neither
covers the residual **dynamic memory**: arbitrary-size arrays, pointer
escapes, aliased stores, conditional writes to the same location. For that
residual we need a **universal fallback** — a mechanism that handles *any*
LLVM `store`/`load` at the cost of some gate-count inflation.

Shadow memory is the universal fallback. Adapted from Enzyme's AD pattern
(Moses & Churavy 2020, arXiv:2010.01709) to reversibility's stricter
requirement of exact bijection rather than linear-accumulating adjoint.

## Design principles

1. **Strict inversion, not accumulation.** Enzyme can sum derivatives
   (linear adjoint); we cannot. Every store must permute bits, not fold
   values. Where Enzyme uses `+=` on shadow memory, we use exact
   swap-or-replay.

2. **Granularity follows SAT pebbling.** Rather than pre-committing to a
   checkpoint frequency, we expose shadow memory as a **pebbleable
   resource**. The SAT-pebbling solver (Meuli 2019, `src/sat_pebbling.jl`)
   decides which memory states to checkpoint based on the circuit's
   dependency DAG and a user-set ancilla budget.

3. **Opt-in universal fallback.** Not the default lowering path.
   T1b/T1c/T2b are preferred when applicable; shadow memory activates only
   when the allocation-site classifier (T3b.3) rules out the specialized
   strategies.

4. **Shadow allocations return to zero.** Bennett-invariant: all ancillae
   (including shadow allocations) zero at end. Satisfied by running the
   shadow's own Bennett reverse at function end.

## Protocol

### 4.1 Shadow allocation

For each `alloca` `%p` of size `N × W` bits marked "universal fallback" by
the dispatcher (T3b.3), emit a twin allocation of the same size:

- **Primal** (`%p`): the user-visible memory. Lowered as a flat wire array.
- **Shadow** (`%p_shadow`): a second flat wire array of the same shape,
  holding the *last-checkpointed* state of the primal.

The shadow starts all-zero (Bennett's zero-ancilla invariant on entry).

### 4.2 Stores: checkpoint-before-overwrite

```
forward:  store new_val at %p[i]
```

lowers to:

```
1. Read old_val from %p[i] (CNOT-copy into a temp ancilla)
2. XOR new_val into %p[i]  — this works for values as XOR deltas
3. Push old_val onto the shadow tape at a pebble-assigned slot
```

The "shadow tape" is a separate wire array indexed by SSA sequence number of
the store. Each store consumes `W` tape slots.

At function end, the tape contains every overwritten value, in forward order.

### 4.3 Loads: direct CNOT-copy from primal

No shadow involvement. Loads read the primal's current state.

### 4.4 Reverse pass: replay tape backward

Bennett's reverse phase walks the gate list backward. For every store (now
in reverse order):

```
reverse:  XOR old_val from shadow tape back into %p[i]
           → restores pre-store primal state
           → shadow slot returns to zero
```

Net effect: after the full Bennett construction (forward + output-copy +
reverse), primal is back to its initial state and shadow tape is all-zero.

### 4.5 Composition with SAT pebbling

Meuli 2019's SAT pebbling takes a dependency DAG and produces a schedule of
compute/uncompute operations minimizing peak ancilla usage under a wall-clock
budget. Shadow-memory stores are nodes in the DAG: each store depends on its
preceding stores (through the tape) and on the primal's initial state.

The pebbling schedule decides **which tape slots to materialize**. For a
straight-line program, every slot is needed. For loops or repeated
subcomputations, clever checkpointing can skip intermediate slots by
re-executing from an earlier checkpoint.

This is exactly Bennett's recursive segmentation: tape the first half,
re-execute the first half to regenerate state, tape the second half, etc.
With SAT pebbling the segmentation is chosen optimally per-function rather
than with a fixed factor.

### 4.6 Tape compression via T2a MemorySSA

When MemorySSA (T2a) is available, we know which Defs are *read* by which
Uses. Stores whose values are never re-read can be safely taped with a
**bit-skip encoding**: only record bits that differ between consecutive
stores. For sparse stores this shrinks the tape dramatically.

This is the T3b equivalent of Enzyme's cache-vs-recompute heuristic.

### 4.7 Loads from aliased pointers

If MemorySSA reports a `MemoryPhi` at a load (two stores from different
branches merge), the load's value is a value-phi of the two stored values.
Emit the value-phi via the existing phi-resolution infrastructure in
`lower.jl`. The phi operand wires are the shadow tape slots written by
the two stores.

## Cost model

For a function with S stores, L loads, all of width W, with shadow tape of
depth D (D ≤ S under full pebbling, D ≤ O(log S) under SAT pebbling):

| Component          | Wires          | Toffoli      | CNOT           |
|--------------------|----------------|--------------|----------------|
| Primal storage     | N·W            | 0            | S·W            |
| Shadow tape        | D·W            | 0            | 2·D·W (push+pop) |
| Store (each)       | 0 (amortized) | 0            | W (XOR into primal) + W (tape push) |
| Load (each)        | 0 (amortized) | 0            | W (CNOT copy)  |
| Reverse replay     | — (uses tape) | 0            | S·W (XOR tape back) |

No Toffolis needed for the shadow-memory mechanism itself. The Toffoli cost
comes from the user's computation that feeds the stored values.

**Comparison vs existing primitives:**

| Mechanism            | Supports              | Cost per op              |
|----------------------|-----------------------|--------------------------|
| T1b MUX EXCH         | writable, N ≤ 16      | ~7500 gates (load_4x8)   |
| T1c QROM             | read-only, const data | 4(L-1) Toffoli + O(L·W) CNOT |
| T2b linear           | linear-type arrays    | ~0 (macro-injected copy) |
| T3a Feistel-dict     | fixed-width keys      | ~480 + slot-read         |
| **T3b shadow** (this)| arbitrary memory      | **W CNOT/store (forward), W CNOT/store (reverse)** |

Shadow memory's per-op cost is **O(W) CNOT**, dramatically cheaper than
MUX-EXCH at small N. The hidden cost is D tape-slot wires, which can grow
to S·W in the worst case.

## Implementation checklist (T3b.2)

- [ ] `src/shadow_memory.jl` module with `emit_shadow_store!` / `emit_shadow_load!` primitives
- [ ] Extend `LoweringCtx` with `shadow_tape::Dict{Symbol, Vector{Int}}` (tape slots per allocation)
- [ ] Hook `lower_store!` to check allocation classification; route universal-fallback stores through shadow path
- [ ] Hook `lower_load!` similarly for reads from universal-fallback allocations
- [ ] Unit tests: shadow-only path on functions that fall through T1b/T1c
- [ ] Integration with `sat_pebbling.jl` — expose tape slots as pebbleable
- [ ] Regression: existing T1b/T1c paths unchanged when classifier says specialized strategy

## Risk register

1. **Tape size explosion.** A function with N stores of width W uses N·W
   tape wires. For small functions this is negligible; for SHA-256 full
   (N~1000) it's 64k wires. Mitigation: SAT pebbling cuts N to O(log N) at
   some time cost. User-tunable budget.
2. **Aliased stores in loops.** A loop that stores to `a[i]` for varying `i`
   produces N tape entries for one loop per iteration — but different iters
   may alias. MemorySSA (T2a) is needed to disambiguate; without it we
   conservatively tape each iteration.
3. **Partial stores.** A store of width W' < alloca_element_width requires
   a partial-store primitive (CNOT only the top W' wires). Easy but
   requires per-store width tracking.

## Non-goals for T3b.2

- Pointer escapes across function boundaries (T3b.3 may handle via
  calling-convention extension; out of scope for shadow primitive itself).
- Dynamic-size allocations (`alloca` with variable n_elems). Shadow tape
  sizing is currently compile-time-constant only. Dynamic sizing = open
  research problem tracked as Bennett-AG13-style linear heap (see §C of
  SURVEY).
- Concurrent stores from multiple threads. Our compiler is single-threaded
  per T1b.3 note.

## Reference

- Moses & Churavy, "Instead of Rewriting Foreign Code for Machine Learning,
  Automatically Synthesize Fast Gradients" (arXiv:2010.01709) — Enzyme's
  shadow memory protocol, §4.
- Meuli, Soeken, Roetteler, Bjørner, Micheli, "SAT-based {CNOT, T}
  Quantum Circuit Synthesis", arXiv:1904.02121 — SAT pebbling used in
  our `src/sat_pebbling.jl`.
- SURVEY.md §2f — reversibility-adapted shadow memory discussion.
- COMPLEMENTARY_SURVEY.md §4 — universal-dispatch classifier interaction.
