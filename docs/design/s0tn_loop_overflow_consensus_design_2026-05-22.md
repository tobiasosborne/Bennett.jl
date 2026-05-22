# Consensus Design — Bennett-s0tn: fail-loud loop-overflow detection

**Date:** 2026-05-22 · **Protocol:** 3+1 (2 proposers + implementer + orchestrator-reviewer)
**Bead:** Bennett-s0tn (P1, bug). Core-pipeline change → 3+1 per CLAUDE.md §2.

## Problem

`lower_loop!` (`src/lowering/cfg.jl` ~152-356) unrolls a data-dependent loop to
exactly `K = max_loop_iterations` MUX-guarded body copies, then STOPS. No check
that the loop's exit condition is satisfied after iteration K. If an input needs
K+1+ iterations, the circuit silently returns the after-K state — a wrong answer.
Violates CLAUDE.md §1 (fail loud).

## The Bennett-reverse trap

`simulate` runs the POST-Bennett circuit: `_bennett_default` =
`[lr.gates ; copy-out CNOTs ; reverse(lr.gates)]`. The reverse pass uncomputes
every non-output ancilla back to 0. So `exit_cond_wire`, computed in the forward
pass, reads 0 at end-of-circuit for EVERY circuit. A naive end-of-`simulate`
check is useless.

**Resolution:** copy the convergence bit out into a dedicated wire *parallel to
Bennett's existing output copy-out* — it survives the reverse pass exactly as
`f(x)` does. This new wire is a **fourth wire-partition class** (`loop_check`),
disjoint from input / output / ancilla.

## Mechanism (consensus of proposer A + B)

1. In `lower_loop!`, after the iteration-K MUX, allocate one fresh 1-bit
   convergence wire `conv_w` and emit `CNOTGate(exit_cond_wire[1], conv_w)` into
   `lr.gates` (forward block). `exit_cond_wire[1]` already has "1 = loop exited /
   done" semantics (it is the post-`lower_not1!` wire feeding the MUX at
   cfg.jl:350) — **no negation needed**. `conv_w == 1` ⇔ loop converged within K.
2. `bennett` copy-out is extended: after copying output wires, emit
   `CNOT(conv_w → conv_copy)` for each loop into a fresh post-bennett wire.
   The reverse pass uncomputes `conv_w` back to 0; `conv_copy` is frozen.
3. `simulate` checks each `conv_copy`: if 0, the loop overflowed → `error()`.

### Polarity decision
Direct copy of `exit_cond_wire` (converged=1, healthy circuit ends with
`conv_copy == 1`). `simulate` throws when `conv_copy == 0`. Costs +2 gates/loop
post-bennett (1 fwd CNOT + 1 copy-out CNOT). Chosen over the negate-to-overflow
variant (+3 gates/loop): `conv_copy` is a fourth-class wire, not an ancilla, so
the "0=healthy ancilla" convention does not apply — simplicity wins.

## Data structures

### `LoopGuard` — new struct in `src/lowering/types.jl` (alongside `GateGroup`)
```julia
"""
    LoopGuard

Bennett-s0tn: one data-dependent loop's convergence-detection wire.
`wire` holds 1 at end of the forward pass iff the loop reached its exit
condition within `K` unrolled iterations. `header_label` and `K` are
carried only for the fail-loud error message.
"""
struct LoopGuard
    wire::Int             # convergence wire; 1 ⇔ loop converged within K
    header_label::Symbol  # loop header block label (diagnostics)
    K::Int                # max_loop_iterations this loop was unrolled to
end
```
Named struct (not a tuple) — consistent with the existing `GateGroup` struct.

### `LoweringResult` — new field `loop_guards::Vector{LoopGuard}`
Append as the last field. ALL existing constructors gain a defaulted
`loop_guards = LoopGuard[]` (empty = no data-dependent loops = every existing
test). `wire` here is the forward-pass `conv_w`.

### `BlockLoweringOpts` — new field `loop_guards::Vector{LoopGuard}`
Default `LoopGuard[]`. This is the accumulator: `lower()` constructs ONE
`BlockLoweringOpts` with a fresh `loop_guards` vector and reuses that same
instance across all blocks (do NOT reconstruct per-block). `lower_loop!`
does `push!(opts.loop_guards, LoopGuard(conv_w, hlabel, K))`.

### `ReversibleCircuit` — new field `loop_check_wires::Vector{LoopGuard}`
Append as the last field. Here `wire` is the post-bennett `conv_copy`.
The inner-constructor partition invariant (Bennett-6azb) becomes a **four-set
partition**: `covered = input ∪ output ∪ ancilla ∪ loop_check == 1:n_wires`,
with `loop_check` disjoint from all three others. Assert each disjointness
loud. `_compute_ancillae` MUST exclude `loop_check` wires from the ancilla set.

### No new gate type
Copy-out reuses `CNOTGate`. The check is a `simulate` post-pass loop. An
`AssertGate` was considered and rejected: it would make `apply!` non-pure and
break `reverse(lr.gates)`. Satisfies CLAUDE.md §12 (no duplicated lowering).

## Thread-through chain

1. **`lower_loop!` (`cfg.jl`)** — after the `for _iter in 1:K` loop closes,
   before `push!(preds, ...)`: allocate `conv_w`, emit the CNOT, push a
   `LoopGuard` onto `opts.loop_guards`.
   **CRITICAL Julia-scope pitfall (proposer A's catch):** `exit_cond_wire` is
   assigned *inside* the `for` body — in Julia it does NOT survive the loop.
   The implementer MUST hoist it: pre-declare `exit_cond_wire` (or a
   `last_exit::Vector{Int}` captured each iteration) in the enclosing scope
   before the `for`, so the post-loop code reads iteration K's value.
   Assert `!isempty(exit_cond_wire)` (fail-loud; K≥1 always since K=0 throws
   earlier at driver.jl:80).
2. **`lower()` (`driver.jl`)** — construct the single shared `BlockLoweringOpts`
   with a fresh `loop_guards`. After the block loop, thread `opts.loop_guards`
   into BOTH `LoweringResult` builds (initial + self-reversing re-wrap).
3. **`_fold_constants` (`driver.jl`)** — does NOT renumber wires (only
   deletes/simplifies gates; `n_wires` preserved), so `conv_w` indices stay
   valid. Its rebuilt `LoweringResult` MUST carry `lr.loop_guards` through
   (switch to the new constructor arity). Add a contract test: `loop_guards`
   survives folding.
4. **`_bennett_default` (`bennett_transform.jl`)** — allocate
   `length(lr.loop_guards)` extra wires after the output copy wires; after
   `_emit_copy_gates!` for outputs, emit `CNOT(conv_w → conv_copy)` per loop
   (reuse `_emit_copy_gates!`). Reverse pass unchanged (reverses only
   `lr.gates`). `_build_circuit` passes `loop_check_wires` =
   `[LoopGuard(conv_copy, lbl, K) for ...]`. `_compute_ancillae` excludes them.
   **Self-reversing fast-path:** assert `isempty(lr.loop_guards)` (a
   self-reversing primitive cannot contain an unrolled data-dependent loop —
   contradiction → `error()`).
5. **Alternate strategies** (`eager.jl`, `value_eager.jl`, `pebble/*`,
   `bennett_strategies.jl`) — all already fall back to `_bennett_default` for
   branching LRs, and a loop LR always branches. Add an explicit one-line guard
   `isempty(lr.loop_guards) || return _bennett_default(lr)` co-located with each
   branching fallback, so loop-guard plumbing has exactly one implementation
   site.
6. **`simulate` / `_simulate_with_buffer!` (`simulator.jl`)** — new post-pass,
   placed BEFORE the ancilla-zero check (loop overflow is the user-actionable
   root cause): iterate `circuit.loop_check_wires`, `bits[lg.wire] || error(...)`.
   Extend `verify_reversibility` and `diagnose_nonzero` (`diagnostics.jl`) in
   lockstep — they must (a) exclude `loop_check` wires from the `bits == orig`
   self-consistency comparison, (b) surface a convergence failure on a probed
   input rather than crash on a downstream check.
7. **`call.jl` nested-call inlining (RISKIEST point)** — `lower_call!` inlines a
   callee via `lower(callee; max_loop_iterations=64)`. If the callee has a
   data-dependent loop, its `LoweringResult.loop_guards` reference wires in the
   callee's numbering. `lower_call!` MUST remap each `LoopGuard.wire` through the
   same callee→caller wire-offset map it already uses for the callee's other
   wires, and append the remapped `LoopGuard`s to the caller's accumulator.
   Never silently drop them. Needs a dedicated nested-call-with-loop test.
8. **`controlled.jl`** — `ControlledCircuit` must propagate (re-index if it
   shifts wires) `loop_check_wires`. Check and handle.

## Multiple / nested loops
One `LoopGuard` per loop header (`lower_loop!` is called once per header). No
aggregation — `simulate` checks each, throws on the first failure, naming that
specific header label. Nested loops: each nested `lower_loop!` invocation pushes
its own guard onto the shared `opts.loop_guards`. Implementer: verify the
nested-loop unrolling model in `_collect_loop_body_blocks` / `opts.loop_headers`
— if nested loops are not currently independently unrolled, the design degrades
gracefully (one guard per top-level loop) and still never fails silently.

## Error message (exact wording)
```
simulate: data-dependent loop with header block :<label> did not converge
within max_loop_iterations=<K> for this input (<inputs>). The compiled circuit
unrolls the loop to exactly <K> iterations; this input needs more. Recompile
with a larger max_loop_iterations (e.g. max_loop_iterations=<2K>).
```

## TDD plan
New file `test/test_s0tn_loop_overflow.jl`, registered in `runtests.jl`.

**RED first** — `countdown(x::Int8)` (deterministic iteration count == x;
chosen over Collatz because the convergence bound is exactly predictable):
```julia
function countdown(x::Int8)
    n = x; steps = Int8(0)
    while n > Int8(0); n -= Int8(1); steps += Int8(1); end
    return steps
end
```
- `c = reversible_compile(countdown, Int8; max_loop_iterations=4)`:
  `simulate(c, Int8(4)) == 4`; `@test_throws ErrorException simulate(c, Int8(5))`
  and `Int8(10)`; assert the error message contains `max_loop_iterations=4` and
  `did not converge`.
- Watch the RED test FAIL first (current code returns a wrong integer, so
  `@test_throws` fails) before writing production code.

**GREEN regression** — `max_loop_iterations=20`: `simulate(c, x) == countdown(x)`
for `x in 0:20`; `verify_reversibility(c)`.

**Collatz** — reuse `collatz_steps` from `test_loop_explicit.jl`:
`max_loop_iterations=3` → `@test_throws` for `Int8(27)`; `=20` → correct.

**Contract tests** — `loop_guards` non-empty on a loop LR before & after
`_fold_constants`; `loop_check_wires` non-empty on the circuit; the four-set
partition invariant accepts a loop-check-bearing circuit and rejects one where
a loop-check wire overlaps input/output/ancilla.

**Nested-call test** — outer fn calls an inner fn containing a data-dependent
loop; small `max_loop_iterations` → `simulate` throws. Pins the `call.jl` remap.

**Multi-block** — extend `test/test_httg_loop_multiblock.jl` with one
undersized-K `@test_throws` sub-case.

## Risks / interactions
- **Phi resolution:** untouched — `conv_w` reads an already-resolved wire with
  one extra CNOT after all phi MUX-freezes; no new join point. Low risk.
- **Self-reversing:** loop LRs never promoted (branching). Fast-path assert is a
  contradiction backstop.
- **Gate-count baselines (CLAUDE.md §6):** all pinned baselines
  (`test/test_gate_count_regression.jl`) are loop-FREE → `loop_guards` empty →
  ZERO gates added → baselines untouched. Loop circuits gain +2 gates/loop +
  1 wire/loop — document the delta in BENCHMARKS.md, do NOT touch baselines.
- **`call.jl:82` hardcoded `max_loop_iterations=64`:** the check works (K=64
  appears in the message). The hardcoding itself is a separate smell — file a
  follow-up bead if confirmed.
- **`diagnose_nonzero`:** must learn loop-check wires or it mis-reports them.

## Files touched (LOC scale; no time estimates)
| File | Change | Scale |
|---|---|---|
| `src/lowering/types.jl` | `LoopGuard` struct; `loop_guards` on `LoweringResult` + `BlockLoweringOpts` + defaulted ctors | small |
| `src/lowering/cfg.jl` | `lower_loop!`: hoist `exit_cond_wire`, alloc `conv_w`, emit CNOT, push guard | small |
| `src/lowering/driver.jl` | shared `BlockLoweringOpts`; thread into both LR builds + `_fold_constants` | small |
| `src/gates.jl` | `loop_check_wires` field; four-set partition invariant | small-medium |
| `src/bennett_transform.jl` | `_bennett_default` guard copy-out; `_build_circuit`/`_compute_ancillae`; self-rev assert | medium |
| `src/bennett_strategies.jl` + `eager.jl` + `value_eager.jl` + `pebble/*` | one-line `isempty` fallback guard each | small |
| `src/simulator.jl` | guard post-check in `_simulate_with_buffer!` | small |
| `src/diagnostics.jl` | `verify_reversibility` + `diagnose_nonzero` exclude/report loop-check wires | small |
| `src/lowering/call.jl` | remap callee `LoopGuard.wire`, append to caller accumulator | medium |
| `src/controlled.jl` | propagate `loop_check_wires` | small |
| `test/test_s0tn_loop_overflow.jl` | new RED+GREEN+contract+nested-call tests | medium |
| `test/runtests.jl` | register | trivial |
| `test/test_httg_loop_multiblock.jl` | one undersized-K `@test_throws` | small |
| `BENCHMARKS.md` | document +2 gates/loop delta | small |

**Overall: medium.** Mechanism is small and local; cost is the breadth of the
thread-through and the `call.jl` remap (the one genuinely subtle piece).
