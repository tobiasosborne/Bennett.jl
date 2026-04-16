# M3a Consensus — Orchestrator Synthesis

**Milestone**: Bennett-cc0 / M3a — T4 shadow-checkpoint MVP (rescoped from PRD §10 M3).
**Date**: 2026-04-16.
**Input**: `docs/design/m3_proposer_A.md` (MVP straight-line) and
`docs/design/m3_proposer_B.md` (SAT-pebbled).

## Rescoped goal (per user)

**Just get stores working properly.** Toffoli count is not a target.
Focus: unblock static-sized allocations currently rejected by
`_pick_alloca_strategy` (shapes where n·W > 64). L10 GREEN is the
acceptance criterion. MD5 full 64-round may or may not compile/verify
in MVP — explicitly not chasing ReVerC's 27,520 Toff.

This supersedes PRD §6 primary criterion 1 for this milestone.
A separate milestone will address round-function Toffoli optimization
(PRS15 EAGER-style) if/when it becomes a headline target.

## Chosen design: **A's MVP**

Rationale:
- User explicitly deprioritized gate-count optimization → B's SAT-pebbling
  is overkill for this scope.
- A's design reuses existing `emit_shadow_store_guarded!` (M2c landed)
  and mirrors the M2b `_lower_load_multi_origin!` pattern — minimal new code.
- ~120 LOC in `lower.jl`, zero changes to `shadow_memory.jl`.
- Strictly additive to dispatcher — no currently-GREEN path migrates.

## Scope (landing in M3a)

1. New `:shadow_checkpoint` return from `_pick_alloca_strategy` when `n*elem_w > 64`.
2. New `_lower_store_via_shadow_checkpoint!(ctx, inst, alloca_dest, info, idx_op, block_label)`:
   - Resolve dynamic idx → log₂(n)-bit wires.
   - For each slot k ∈ [0, n): `eq_wire = idx == k` AND-tree; guard = `block_pred × eq_wire`; `emit_shadow_store_guarded!(..., pred=guard)`.
   - Entry-block optimization: when `block_label == entry_label`, skip the `block_pred` AND (guard = `eq_wire` directly).
3. New `_lower_load_via_shadow_checkpoint!(ctx, inst, alloca_dest, info, idx_op)`:
   - Allocate fresh W-wire result (zero by WireAllocator invariant).
   - For each slot k: `Toffoli(eq_wire_k, primal_slot_k[i], result[i])` per bit.
4. Dispatch arms in `_lower_store_single_origin!` (~:2083) and `_lower_load_via_mux!` (~:1701).
5. L10 GREEN: `Array{Int8}(undef, 256)` dynamic-idx store + load.

## Acceptance criteria

- L10 flips RED → GREEN: compile + `verify_reversibility` + sampled input sweep (not exhaustive — N=256 is 2^16 = 65k (idx, val) combinations; pick representative subset + edge cases).
- All existing tests pass unchanged.
- BENCHMARKS.md invariants byte-identical:
  - i8=100/28T, i16=204, i32=412, i64=828
  - soft_fma=447,728, soft_exp_julia=3,485,262
  - Shadow W=8 = 24 CNOT
  - All MUX EXCH variants (unguarded + M2d guarded) byte-identical.

## Critical correctness concern (R2 from A)

**False-path sensitization in T4 × diamond CFG.** Per CLAUDE.md
§"Phi Resolution and Control Flow — CORRECTNESS RISK". When a T4 store
sits inside a conditional block, the fan-out must AND the
per-slot `eq_wire` with the block predicate from `ctx.block_pred`.

**Required RED test BEFORE implementation**: L7g —
diamond CFG × dynamic-idx store into a large array. Must verify both
paths (pred=true stores at idx; pred=false leaves array zero).

## Deferred

- L11 MD5 full 64-round benchmark — not required for M3a acceptance.
  If it happens to compile+verify, report it. If it compile-times-out
  or OOMs, defer to a separate benchmarking milestone.
- SAT pebbling (`src/sat_pebbling.jl` wiring) — M3b if needed.
- MemSSA def-use for tape de-duplication — M3b if needed.
- Multi-word MUX EXCH — separate milestone (shape-specific optimization,
  orthogonal to T4 fallback).
- Dynamic-size allocas (`Vector{T}` push!) — T5 per PRD §5.
- Multi-origin × T4 interaction — hard-error with clear message; defer.

## Implementer flow

1. File Bennett-cc0 M3a bd issue.
2. RED: add L7g (diamond CFG × T4 store) to `test/test_memory_corpus.jl`. Watch FAIL.
3. RED: flip L10 from `@test_throws` → `@test verify_reversibility + sweep`. Watch FAIL at extraction/dispatch.
4. Add `:shadow_checkpoint` arm to `_pick_alloca_strategy`.
5. Implement `_lower_store_via_shadow_checkpoint!` and `_lower_load_via_shadow_checkpoint!`.
6. Wire into single-origin dispatcher.
7. Idx-equality helper `_emit_idx_eq_const!` — can lift from softmem.jl soft_mux_load_* pattern.
8. L7g GREEN → L10 GREEN → full suite passes.
9. Regenerate BENCHMARKS.md — verify byte-identical invariants.
10. WORKLOG session entry + banner update.
11. Close M3a bd issue.

Cost estimate: ~120 LOC in `src/lower.jl`, +~30 LOC tests, +~20 LOC docs. One atomic commit.
