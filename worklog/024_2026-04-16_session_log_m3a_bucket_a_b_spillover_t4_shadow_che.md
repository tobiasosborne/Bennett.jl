## Session log — 2026-04-16 — M3a Bucket A/B-spillover T4 shadow-checkpoint MVP (Bennett-jqyt)

Extends the dynamic-idx alloca dispatcher with a universal fallback for
shapes where `n*elem_w > 64` (no MUX EXCH callee fits). Previously
`_pick_alloca_strategy` returned `:unsupported` for these; tests L10 /
L7g were RED (hard-error at dispatch). After M3a both are GREEN via the
new `:shadow_checkpoint` arm that fans out N guarded shadow stores +
per-slot Toffoli-copy loads.

**User rescope**: Toffoli count is NOT a target for M3a. Focus is
correctness only. PRD §6 primary criterion 1 (MD5 Toffoli-parity with
ReVerC's 27,520 Toff) is superseded for this milestone — see
`docs/design/m3a_consensus.md` §Rescoped goal. Gate cost is allowed to
be O(N·W) per op.

### 3+1 protocol outcome

Two proposers spawned in parallel under CLAUDE.md §2:

- **Proposer A (`docs/design/m3_proposer_A.md`)**: MVP straight-line
  shadow-checkpoint. Reuses `emit_shadow_store_guarded!` (M2c) and
  mirrors the `_lower_load_multi_origin!` (M2b) fan-out pattern. One
  new dispatcher arm, two new helpers in `lower.jl`. Zero changes to
  `shadow_memory.jl`. Explicitly DEFERS SAT pebbling / MemSSA tape
  de-dup. Tape cost: O(S × N × W) wires per function. Estimated
  ~120 LOC in `src/lower.jl`. Fails ReVerC MD5 budget by ~3–7×.
- **Proposer B (SAT pebbling — per consensus doc)**: integrate
  `src/sat_pebbling.jl` (Meuli 2019) into the tape layout so tape wires
  compress to O(S·W·log S). Larger implementation surface; hits the
  27.5k Toffoli headline.

Orchestrator picked A given the user rescope (see
`docs/design/m3a_consensus.md`). B remains filed as the M3b follow-up
if MD5-parity becomes a headline target. Implementer (this session)
followed A's design exactly — no deviations.

### Implementation

`src/lower.jl`:
  - `_pick_alloca_strategy` — added one arm before the final
    `:unsupported` return: `if n * elem_w > 64; return :shadow_checkpoint; end`.
    Strictly additive — no shape currently returning `:shadow` or
    `:mux_exch_*` migrates.
  - New `_emit_idx_eq_const!(ctx, idx_wires, idx_bits, k) -> Int`. For
    each of the `idx_bits` low bits: if k's bit is 1 use `idx_wires[i]`
    directly; else NOT-copy into a fresh wire. AND-reduce pairwise via
    `_and_wire!` (Toffoli tree). Returns a single wire that is 1 iff
    `idx == k` at runtime. Cost: up to `idx_bits` NOT-wires + `idx_bits-1`
    Toffolis per call.
  - New `_lower_store_via_shadow_checkpoint!(ctx, inst, alloca_dest,
    info, idx_op, block_label)`. Resolves val + idx, computes
    `use_block_guard = block_label ∉ {Symbol(""), entry_label}`. For
    each slot k ∈ [0, n): build `eq_wire_k`; if guarded, AND with
    `block_pred[block_label][1]` via `_and_wire!`; allocate W-wire tape
    slot; call `emit_shadow_store_guarded!`.
  - New `_lower_load_via_shadow_checkpoint!(ctx, inst, alloca_dest,
    info, idx_op)`. Fresh W-wire result (zero by invariant); for each
    slot k: `Toffoli(eq_wire_k, primal_slot[i], result[i])` per bit.
    Load is unconditional w.r.t. block predicate — UB if out of the
    dominating branch.
  - `_lower_store_single_origin!` and `_lower_load_via_mux!` each gained
    an `elseif strategy == :shadow_checkpoint` arm. Multi-origin fan-out
    still errors loudly (multi-origin × T4 deferred per consensus).

`test/test_universal_dispatch.jl`:
  - Renamed the final sub-testset from ":unsupported for dynamic idx on
    uncovered shapes" to ":shadow_checkpoint for dynamic idx on N·W > 64
    shapes". 4 assertions updated to expect `:shadow_checkpoint`. All
    other assertions (static-idx → `:shadow`, N·W ≤ 64 → `:mux_exch_*`)
    unchanged, reflecting the strictly-additive dispatch change.

`test/test_memory_corpus.jl`:
  - **L7g (new)**: diamond CFG × dynamic-idx store into `alloca i8, i32 256`.
    Pins the false-path-sensitisation concern (CLAUDE.md §"Phi Resolution
    and Control Flow — CORRECTNESS RISK"). Verifies:
    ```julia
    simulate(c, (Int8(7), Int8(0), true))  == Int8(7)
    simulate(c, (Int8(7), Int8(0), false)) == Int8(0)  # pred=false: untouched
    simulate(c, (Int8(7), Int8(5), true))  == Int8(0)  # stored to idx=5, load idx=0
    simulate(c, (Int8(7), Int8(5), false)) == Int8(0)
    ```
  - **L10**: flipped from `@test_throws Exception` to `@test +
    verify_reversibility + sampled sweep`. Uses `alloca i8, i32 256`
    (n·W = 2048 > 64) — dispatcher routes to `:shadow_checkpoint`. Tests
    4 val × 4 idx combos (including idx=0, idx=last, negative x, zero,
    typemax). Full 65k sweep deemed too slow; representative subset
    adequate for MVP.

### Gate counts (informational; L10 single store+load)

- L10 total: 48,090 gates (NOT 4,098 / CNOT 16,360 / Toffoli 27,632)
- L10 ancillae: 13,849 wires
- Correctness: verify_reversibility = true, all sweep cases pass

Per-op cost breakdown: 256 slots × (idx_eq_k AND-tree ≤ 8 Toffolis + 1
block-pred AND + 3W = 24 Toffolis for guarded shadow store) ≈ 8.4k
Toffolis per store. Load is 256 × 8 = 2,048 Toffolis + eq-wire setup.
Bennett doubles both. Consistent with proposer A §5/§6 estimates.

### BENCHMARKS.md diff

Regenerated via `julia --project benchmark/run_benchmarks.jl`: byte-
identical to committed version. All acceptance-criteria invariants
preserved:
- i8=100/28T, i16=204, i32=412, i64=828
- soft_fma = 447,728, soft_exp_julia = 3,485,262
- Shadow W=8 = 24 CNOT
- All MUX EXCH rows (unguarded + guarded) unchanged.

This confirms proposer A §12 R4 mitigation ("strictly additive" —
no currently-GREEN shape silently migrates to T4).

### Test state

- `test/test_memory_corpus.jl`: 582 / 582 pass (L7g new, L10 flipped).
- `test/test_universal_dispatch.jl`: 293 / 293 pass (4 assertions
  updated to expect `:shadow_checkpoint`).
- Full suite `using Pkg; Pkg.test()`: GREEN end-to-end.

### Gotchas

- **Multi-origin × T4 deferred**: `lower_store!` top-level multi-origin
  fan-out (the `length(origins) > 1` branch at `lower.jl:~2065`) still
  hard-errors when an origin's `_pick_alloca_strategy` returns anything
  other than `:shadow`. That error message now fires for T4-shape
  origins of multi-origin pointers. Consensus §Deferred pins this as
  a separate follow-up — not in M3a scope.
- **Block-predicate single-wire invariant**: `_lower_store_via_shadow_checkpoint!`
  asserts `length(ctx.block_pred[block_label]) == 1`, matching the M2c
  / M2d pattern. Multi-wire block predicates (if/when `_compute_block_pred!`
  starts emitting those) would need AND-reduction before the guarded
  primitive — same limitation as M2c.
- **Idx-bits padding**: `_emit_idx_eq_const!` uses `idx_bits = max(1, ceil(log2(n)))`.
  For n=256 → idx_bits=8. The idx operand from `zext i8 %i to i32` has
  32 wires but only the low 8 are semantically meaningful (upper 24 are
  zero by zext). We only look at the low idx_bits, which is safe by
  that construction.
- **L10 store-before-load slot mutation**: Unlike the MUX-EXCH path
  which swaps the primal slice in-place via the soft_mux_store callee,
  the T4 path guards each primal slot with `eq_wire_k`. After an idx=k
  store the primal slot k is mutated (via Toffoli ControlledBits);
  loading idx=k thereafter reads the updated value. Order-of-ops matches
  the MUX path at source-language level: store first, then load, both
  on the same dynamic idx.
- **Eq-wire re-computation**: Each slot allocates a fresh `eq_wire_k`
  per call to `_emit_idx_eq_const!`. No caching across store or across
  load. Deferred optimisation (M3b eq-wire memoization).

### Files changed

- `src/lower.jl` (+~145 LOC): dispatcher arm, two helpers, bit-match utility.
- `test/test_memory_corpus.jl`: L7g new, L10 flipped RED → GREEN.
- `test/test_universal_dispatch.jl`: 4 assertions re-expected to
  `:shadow_checkpoint`.
- `WORKLOG.md`: this entry + banner update.
- `BENCHMARKS.md`: regenerated, byte-identical to prior commit.

### Next

M3b (if needed): SAT pebbling / MemSSA tape de-dup for shrinking T4
gate cost toward ReVerC MD5 parity. T5 (separate): unbounded
`Vector{T}` dynamic-size allocas (`alloca %n`). M4: BennettBench paper
outline. Per user rescope M3b is only justified if a benchmark makes
T4 gate cost a headline number again.

---

