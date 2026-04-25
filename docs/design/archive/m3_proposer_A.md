# M3 Proposer A — MVP straight-line T4 shadow-checkpoint (no SAT pebbling)

**Status:** design only; no source files touched.
**Parent:** Bennett-cc0 (Memory PRD §10 M3).
**Role:** Proposer A under CLAUDE.md §2 3+1 protocol.
**Date:** 2026-04-16.

---

## 1. One-line recommendation

Let T4 be a straight-line **per-store tape slot** shadow strategy that
reuses the existing `emit_shadow_store!` / `emit_shadow_store_guarded!`
primitives already landed for M2b/M2c, gated behind a new dispatcher
tier (`:shadow_checkpoint`) triggered when the existing dispatcher would
either reject the shape (multi-word) or when per-store MUX EXCH gate
cost × store-count would exceed a budget. No pebbling, no re-execution,
no recursion — that lands in M3b.

The key observation: **the M2c shadow path IS already a T4 prototype.**
Every shadow store allocates a fresh W-wire tape slot at `lower.jl:2170`.
Bennett's reverse unwinds them automatically. We just need to route more
(N, W) shapes through this path — specifically the multi-word and
beyond-budget shapes — without touching `shadow_memory.jl` at all.

---

## 2. Scope

### Lands in M3 (MVP T4)

1. A new dispatcher tier `:shadow_checkpoint` in `_pick_alloca_strategy`.
2. A `_lower_store_via_shadow_checkpoint!` helper that handles the
   **dynamic-idx** case by building a MUX-fanout of per-slot guarded
   shadow stores (one tape slot per array element × per store, picked
   by index equality to a constant). This is the T4 "shadow tape = one
   slot per dynamic store" construction from `docs/memory/shadow_design.md`
   §4.2.
3. A `_lower_load_via_shadow_checkpoint!` dual that mirrors the existing
   `_lower_load_multi_origin!` fan-out but over the element axis (reading
   from primal with index-equality-guarded Toffolis into a fresh result
   register).
4. L10 GREEN (`Array{Int8}(undef, 256)` dynamic idx) — L10 must compile,
   verify reversible, and pass functional correctness on a sampled sweep.
5. L11 GREEN (MD5 full 64-round compression) — must compile + verify.
   Gate count is **allowed** to exceed the 27.5 kT target; MVP is
   correctness + compilability + stable baseline for M3b.
6. New benchmark `benchmark/bc_md5_full.jl` that exercises L11 and
   prints ToF/wire numbers against the ReVerC headline.
7. Regression pin in BENCHMARKS.md §T3b plus §Head-to-head (adds the new
   MD5 64-round row, flagged "MVP, no pebbling").

### Defers to M3b (separate milestone, NOT this PRD cut)

- SAT pebbling (`src/sat_pebbling.jl` wiring into the tape layout).
- Meuli 2019 segmentation; Knill recursive pebbling.
- MemSSA-def-use-driven tape de-duplication for never-read stores.
- Dynamic-size allocas (`alloca %n`) — that is Bucket B full (T5).

### Out of scope (deferred to post-MD5 PRD)

- Unbounded `Vector{T}` with runtime `push!` (T5 / Okasaki+Mogensen).
- Cross-function pointer escapes without `register_callee!`.
- `atomicrmw` / `cmpxchg`.

---

## 3. Dispatch trigger

Concrete modification to `_pick_alloca_strategy(shape, idx)` at
`src/lower.jl:2011`.

### Current logic

```julia
if idx.kind == :const
    return :shadow
end
(elem_w, n) = shape
if elem_w == 8
    n in (2, 4, 8) && return :mux_exch_{n}x8
elseif elem_w == 16
    n in (2, 4) && return :mux_exch_{n}x16
elseif elem_w == 32
    n == 2 && return :mux_exch_2x32
end
return :unsupported
```

### Proposed extension

Append two new arms **before** the final `:unsupported` return:

```julia
# T4 MVP: dynamic idx, any (elem_w, n) with n*elem_w > 64
# (multi-word) OR with store-count × MUX-cost exceeding budget.
# We can only see shape here, not store-count — so the trigger is
# purely shape-based:
if n * elem_w > 64
    return :shadow_checkpoint
end
# NOTE: for shapes ≤64 bits, T1a MUX EXCH is always cheaper per op
# than T4 (which fans out N guarded stores). So we keep the existing
# MUX tiers as first choice.
```

Rationale: T4 and T1a are interchangeable for "small" shapes — T1a wins
per-op-cost, T4 wins only when T1a is unavailable (i.e. N·W > 64). So
the MVP trigger is **"drop here when nothing else works"**. No
store-count threshold yet because `_pick_alloca_strategy` has no view
of store-count; that would need a per-alloca pass before the first
store is lowered. Deferred to M3b.

This keeps the trigger purely a function of `(elem_w, n, idx)`, which is
what the dispatcher already has. Zero semantic change for any currently
GREEN test.

### L10 shape check

`Array{Int8}(undef, 256)` → (elem_w=8, n=256) → n·W = 2048 > 64 →
`:shadow_checkpoint`. Currently returns `:unsupported`; L10 currently
RED. Post-M3: GREEN.

### L11 shape check

MD5 state: 16-entry UInt32 message-schedule array + 4-word state. The
message array is (elem_w=32, n=16) → n·W = 512 > 64 →
`:shadow_checkpoint`. Currently RED if `md5_block` is compiled as a
monolith rather than unrolled into scalars. (In the current `bc2_md5.jl`
benchmark the state is passed as six scalars and the IR never has an
alloca — so MD5-step doesn't hit this path today. A full 64-round
compression held in an array WILL hit it.)

---

## 4. Tape slot allocation

### Policy (MVP)

**One tape slot per *store SSA instance*, **not** per array slot.**

Every store instruction consumes exactly `elem_w` fresh wires from
`ctx.wa.allocate!`. No slot reuse. No MemSSA-driven elimination.

This is identical to the current M2c shadow path (`lower.jl:2170`),
just extended to the dynamic-idx case. The "tape" is the implicit
linear sequence of fresh wires. Bennett's reverse walks `lr.gates` in
reverse order, so every tape slot allocated by forward store #k gets
unwound by the reverse of that exact CNOT pattern — no bookkeeping
needed beyond the existing `emit_shadow_store!` semantics.

### Data structure

**None new.** The `WireAllocator` is the data structure. Each call to
`allocate!(ctx.wa, elem_w)` returns a fresh contiguous W-wire block.
Per-store we make one such call in the unconditional case, and `N`
such calls (one per possible index value) in the dynamic-idx case
(fanned out by idx-equality guarding).

### Slot count bound

For S dynamic-idx stores into an N-slot array of width W:

| Path        | Tape wires |
|-------------|------------|
| T4 MVP      | S × N × W  |
| T4 + SAT    | O(S·W·log S) (Meuli 2019) — M3b |

L10 (256 slots, 3 stores in a loop → unrolled to say 10 stores ×
256 slots × 8 bits) = 20,480 tape wires. Fine.

L11 (MD5: 64 rounds × 1 store into 16-slot schedule × 32 bits) =
32,768 tape wires for the schedule. Plus the 4-slot state array
≈ 64 × 4 × 32 = 8,192 wires. Total ~40k tape wires. At ~3W CNOTs per
store × 64 stores, the shadow mechanism itself is ~6k CNOTs — trivial
next to the Toffoli cost. But the tape **dwarfs** ReVerC's 4,769 qubits
if we're naive.

This is exactly why M3b needs pebbling. M3 MVP prioritises correctness
first — report the tape explosion, eat it, move on.

### Guarantee

Every tape slot is fresh-allocated and participates in exactly one
`emit_shadow_store!`-flavoured CNOT pattern. Bennett reverse unwinds
each pattern; every slot returns to zero; `verify_reversibility`
passes by construction.

---

## 5. Store lowering

### Unconditional (const idx)

**No change.** Routes through the existing `_lower_store_via_shadow!`
path at `lower.jl:2156`. Already landed in M2c.

### Dynamic idx — new `_lower_store_via_shadow_checkpoint!`

Pseudocode:

```julia
function _lower_store_via_shadow_checkpoint!(ctx, inst, alloca_dest,
                                             info, idx_op, block_label)
    elem_w, n = info
    inst.width == elem_w || error(...)
    arr_wires = ctx.vw[alloca_dest]
    length(arr_wires) == elem_w * n || error(...)
    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, elem_w)

    # Resolve dynamic idx into a log2(n)-bit wire vector
    idx_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, idx_op, 0)
    idx_bits  = max(1, ceil(Int, log2(n)))

    # For each possible slot k ∈ [0, n), synthesise an
    # "idx == k" equality predicate wire using AND-reduction of
    # literal-matched bits, then emit a guarded shadow store with
    # that predicate ANDed with the block predicate.
    block_pred_w = _resolve_block_pred_or_entry(ctx, block_label)

    for k in 0:(n-1)
        eq_wire = _emit_idx_eq_const!(ctx, idx_wires, idx_bits, k)
        guard_w = _and2_wires!(ctx, block_pred_w, eq_wire)  # 1 Toffoli
        slot_wires  = arr_wires[k*elem_w + 1 : (k+1)*elem_w]
        tape        = allocate!(ctx.wa, elem_w)
        emit_shadow_store_guarded!(ctx.gates, ctx.wa,
                                   slot_wires, tape, val_wires,
                                   elem_w, guard_w)
    end
    return nothing
end
```

`_emit_idx_eq_const!` builds an "idx bits match constant k" predicate
wire using standard NOT/Toffoli AND-tree (ceil(log2 n) − 1 Toffolis).
This is a pattern already used in `soft_mux_load_NxW` primitives (see
`src/softmem.jl`), so we lift the idiom rather than inventing one.

### Cost per dynamic-idx store

- Per slot: 1 AND (eq-wire × block-pred), 1 AND-tree per idx match
  (~log n Toffolis), 3W Toffolis for the guarded shadow store itself.
- Total per store: `n × (3W + log₂ n + 1)` Toffolis, `W` tape wires.

For L10 (N=256, W=8): `256 × (24 + 8 + 1) = 8,448` Toffolis per store.
For MD5 message schedule (N=16, W=32): `16 × (96 + 4 + 1) = 1,616`
Toffolis per store × 64 stores = **103,424 Toffoli just for the
stores**. That's already >27.5k. M3 MVP will not hit the headline.
Report this honestly; document it; M3b fixes via SAT pebbling +
shape-aware alternate tiers.

### Why fan-out, not `soft_mux_store_NxW`?

Because `soft_mux_store_NxW` is shape-limited (N·W ≤ 64). The whole
reason we're in T4 is that it doesn't apply. Fanning out N guarded
shadow stores is the universal fallback.

### Entry-label guard bypass (M2c interaction)

If `block_label == Symbol("") || block_label == ctx.entry_label`, we
**still** need per-slot idx-equality guards — they encode the dynamic
index, not the control flow. So the entry-label optimisation does NOT
kick in for T4 dynamic-idx stores. We DO drop the `block_pred × eq`
AND and use the eq wire directly as the guard, saving 1 Toffoli per
slot per store. Same semantic as the existing M2c fast-path.

### What `lower_store!` changes

**Only one line.** In `_lower_store_single_origin!` at
`src/lower.jl:2083`, add an `elseif strategy == :shadow_checkpoint`
arm that dispatches to `_lower_store_via_shadow_checkpoint!`. Multi-
origin fan-out (`lower_store!` top-level, line 2040) also needs an
extra arm mirroring the same dispatch — but that can be phase-2
since multi-origin × T4 is uncommon in MD5 and can initially error
loudly per §12 risk R5.

---

## 6. Load lowering

### The key insight

Loads read the **primal** (`ctx.vw[alloca_dest]`) — never the tape. The
tape is write-only on forward pass and read-only on reverse pass. A
forward load is an `index = k` fan-out over the primal slots.

### New `_lower_load_via_shadow_checkpoint!`

Pseudocode (mirrors `_lower_load_multi_origin!` at `lower.jl:1669`):

```julia
function _lower_load_via_shadow_checkpoint!(ctx, inst, alloca_dest,
                                            info, idx_op)
    elem_w, n = info
    W = inst.width
    W == elem_w || error(...)
    arr_wires = ctx.vw[alloca_dest]

    idx_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, idx_op, 0)
    idx_bits  = max(1, ceil(Int, log2(n)))

    result = allocate!(ctx.wa, W)   # zero by invariant
    for k in 0:(n-1)
        eq_wire = _emit_idx_eq_const!(ctx, idx_wires, idx_bits, k)
        slot_wires = arr_wires[k*elem_w + 1 : (k+1)*elem_w]
        for i in 1:W
            push!(ctx.gates,
                  ToffoliGate(eq_wire, slot_wires[i], result[i]))
        end
    end
    ctx.vw[inst.dest] = result
    return nothing
end
```

Exactly `n·W` Toffolis per load, `W` result wires. The `_emit_idx_eq_const!`
eq-wires ARE re-usable across the n slot iterations for the same load —
but naively we allocate one per slot. Deferred optimisation.

Route through `_lower_load_via_mux!` at `lower.jl:1701` — add arm for
`:shadow_checkpoint`.

### Why not reverse the shadow tape on forward load?

Because the tape is an opaque "undo log"; walking it on forward would
double the work. The tape's job is **to be in scope at reverse time**
so Bennett's reverse unwinds each store back to the primal's previous
state. Reading the primal is a separate thing — it's just "what's
there now," which is exactly what `arr_wires` holds.

---

## 7. Bennett reverse integration

**Zero new code.** The existing `bennett()` at
`src/bennett_transform.jl:23` walks `lr.gates` in reverse order. Every
forward gate is a CNOT or Toffoli (both self-inverse), so reversed-gate
execution restores state: primal returns to pre-store value, tape slot
returns to zero.

The only property we must preserve: **no fresh wires are allocated
inside the reverse walk**. `emit_shadow_store_guarded!` doesn't
allocate — it emits into a pre-allocated `tape_slot`. Same for our
new `_lower_store_via_shadow_checkpoint!`: all allocation happens on
forward pass; reverse is pure gate-replay. Verified against
`test_shadow_memory.jl:86` pattern.

### Ancilla accounting

All tape slots count as ancillae under `_compute_ancillae` at
`src/bennett_transform.jl:2` (any wire not in input or output set).
`verify_reversibility` then samples the ancilla space — tape slots
return to zero ⟹ test passes.

---

## 8. L10 compile path

### L10: `Array{Int8}(undef, 256)` dynamic idx

Shape: (elem_w=8, n=256), n·W = 2048 > 64. Dispatcher returns
`:shadow_checkpoint`. `_lower_store_via_shadow_checkpoint!` fans out
256 guarded shadow stores per IR store.

Gate cost (single store): 256 × (24 + 8 + 1) ≈ **8,448 Toffoli**.
Tape wires per store: `256 × 8 = 2,048`.

If L10 has K stores in a loop, total cost ≈ K × 8,448 Toffoli +
K × 2,048 tape wires. For a trivial L10 (say store + load), K=1 →
~8.5k Toffoli — huge, but within budget for MVP.

### Alternative: multi-word MUX EXCH tier

An explicit `:mux_exch_Nx8_multiword` tier that packs the array into
multiple UInt64 registers and does the MUX dispatch across them would
give a better gate count for L10 (the existing soft-mux uses ~7k Toff
for 4×8; a 32×8 multi-word version would scale to ~60k, competitive
with T4's per-op fan-out at this N).

**My recommendation: defer multi-word MUX to a later milestone
(M3c).** Reason: T4 shadow-checkpoint handles ANY shape including
multi-word arrays, so it's the universal fallback. Optimising
multi-word MUX is a sibling effort. For MVP we send everything with
N·W > 64 to T4 and accept the cost. L10 GREEN by virtue of T4
accepting the shape.

---

## 9. L11 MD5 test harness

### Current state

`benchmark/bc2_md5.jl` compiles individual MD5 **steps** (one round of
the main loop, as a 6-argument pure function). It does NOT allocate an
array — the state is passed as scalar arguments. So the current
benchmark doesn't stress the alloca path at all.

### Proposed L11 harness

New file: `benchmark/bc_md5_full.jl`.

Core idea: compile a Julia function that takes a 16-UInt32 message
block + 4-UInt32 initial state and returns the final 4-UInt32 state
after all 64 rounds. The function body allocates:

- `Vector{UInt32}(undef, 16)` or `Tuple{Vararg{UInt32, 16}}` — the
  message schedule.
- Scalar locals for state A, B, C, D (rotated, not array-indexed).

Dynamic indexing happens inside the 64-round loop via the MD5
message-word-index table `g[i]`. When LLVM unrolls the 64-round loop
with `optimize=false`, the pattern is:

```llvm
%schedule = alloca [16 x i32]
; store words 0..15 (constant indices — T3b shadow)
%g0 = ...      ; runtime-computed index
%gv = getelementptr i32, ptr %schedule, i32 %g0
%w  = load i32, ptr %gv     ; dynamic load
...
```

Without preprocessing that picks up the MD5 constants, the schedule
access is fully dynamic → T4 triggers.

### Harness code sketch (design only, to implement)

```julia
using Bennett
using Bennett: verify_reversibility, gate_count, t_count, ancilla_count

function md5_compression(m::NTuple{16, UInt32},
                         s::NTuple{4, UInt32})::NTuple{4, UInt32}
    # Constants flattened into per-round parameters
    # ...
    # Run 64 rounds, each computing g(i), w = m[g(i)], round update
    # ...
    return (A_final, B_final, C_final, D_final)
end

function measure_md5_full()
    c = reversible_compile(md5_compression,
                           NTuple{16, UInt32}, NTuple{4, UInt32})
    gc = gate_count(c)
    ac = ancilla_count(c)
    ok = verify_reversibility(c; n_tests=3)
    println("MD5 full 64-round: total=$(gc.total) Toff=$(gc.Toffoli) " *
            "wires=$(c.n_wires) ancillae=$(ac) reversible=$ok")
    return (toffoli=gc.Toffoli, wires=c.n_wires)
end

r = measure_md5_full()
println()
println("vs ReVerC 2017 Table 1 (eager): 27,520 Toffoli / 4,769 qubits")
println("Bennett.jl M3 MVP:              $(r.toffoli) Toffoli / $(r.wires) qubits")
```

### Target gate count

**Honest expected range for MVP**: **80k–200k Toffoli**, **30k–60k
wires**. This is **2.9×–7.3× worse than ReVerC** (27.5k Toff). Why:

- 64 message-schedule stores × 16-way fanout × 96 Toff (guarded 3W) =
  98,304 Toff for schedule stores alone.
- 64 loads × 16 × 32 = 32,768 Toff for loads.
- 64 round-body evaluations × ~750 Toff each = 48,000 Toff for the
  round arithmetic (MD5 F + 4 adds + rotate).
- Bennett's reverse doubles all of the above → ~360k Toff raw.
- Outside the memory path we **could** hit 27.5k with EAGER +
  in-place adders already in `src/adder.jl`, but the memory path
  alone eats our budget.

**Implication:** M3 MVP beats nothing. It establishes the baseline.
M3b pebbling + bit-packed tape compresses the memory cost by O(N)
toward parity with ReVerC. That's the publishable milestone.

### Test placement

`test_memory_corpus.jl` L11 entry currently says "tracked in benchmark".
Propose: promote to a unit test that compiles the function, runs
`verify_reversibility` (n_tests=3), AND asserts an upper-bound on
Toffoli count (say ≤200k) so regressions show up. Not a tight
baseline — just a "didn't blow up" guard.

---

## 10. Cost estimate

| File                           | Δlines | Notes                                 |
|--------------------------------|-------:|---------------------------------------|
| `src/lower.jl`                 | ~120   | 2 new helpers + 2 dispatcher arms     |
| `src/shadow_memory.jl`         | 0      | reuses existing primitives            |
| `test/test_memory_corpus.jl`   | +25    | promote L10/L11 from RED to GREEN     |
| `test/test_shadow_memory.jl`   | +40    | unit tests for new helper functions   |
| `benchmark/bc_md5_full.jl`     | +120   | new benchmark                         |
| `benchmark/run_benchmarks.jl`  | +5     | wire bc_md5_full.jl in                |
| `BENCHMARKS.md`                | +15    | new row in §Head-to-head; note in §T3b|
| `WORKLOG.md`                   | +60    | session notes, gate baselines, learnings |
| `docs/design/m3_consensus.md`  | new    | orchestrator-picked design            |
| `docs/memory/t4_implementation.md` | new | optional: spec for M3b                |

**Total: ~385 new/changed lines**, mostly test scaffolding + doc.
Core compiler change is ~120 lines in one file.

---

## 11. What I won't do

- **No SAT pebbling.** `src/sat_pebbling.jl` stays untouched. The T4
  MVP accepts tape size = O(S × N × W).
- **No MemSSA def-use integration for de-duping never-read stores.**
  The MemSSA data is already parsed at `src/memssa.jl` (M2a) but I
  will not wire it into `_pick_alloca_strategy`. That lands in M3b.
- **No dynamic-size allocas.** `lower_alloca!` keeps the
  `n_elems.kind == :const` hard-reject. Unbounded `Vector{T}` requires
  T5.
- **No multi-word MUX EXCH primitive.** Shapes with n·W > 64 that
  COULD be handled by multi-word MUX get the T4 fan-out instead. This
  is strictly worse per-op cost, but universal. Multi-word MUX is a
  separate M3c milestone.
- **No modification to `emit_shadow_store!` / `emit_shadow_store_guarded!`.**
  They already have the right signature.
- **No tape-slot reuse policy.** Fresh wires every store. Deferred.
- **No bit-packed / diff-coded tape.** Per `docs/memory/shadow_design.md`
  §4.6, bit-skip encoding is a T2a/MemSSA integration. Not MVP.
- **No ancilla hygiene review of the ≥8-origin multi-origin path.** T4
  × multi-origin ptr-phi errors loudly; fixed after MD5 headline lands.

---

## 12. Risks

### R1 — Tape size explosion (anticipated)

L11 at MVP ≈ 40k tape wires. This breaks the PRD §11 R1 mitigation
(SAT pebbling) by construction — we said we'd defer it. Impact:
PRD §6 secondary criterion 5 ("gate cost within 2× of theoretical
lower bound") WILL FAIL for L11. Accept this; document it as the
motivation for M3b; report to orchestrator.

**Mitigation in MVP:** add a hard guard in
`_lower_store_via_shadow_checkpoint!` — if the resulting tape budget
exceeds a threshold (say 128k wires per function), `error(...)` with
a clear message pointing at M3b. Prevents silent runaway compilation.

### R2 — False-path sensitisation × T4 fan-out

Critical per CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS
RISK". When the T4 fan-out store is inside a conditional block, each
of the N guarded stores receives `block_pred × idx_eq_k`. If
`block_pred` is a phi over a diamond CFG, the existing M2b
`PtrOrigin.predicate_wire` machinery must be respected — we can't
just AND with `block_pred[block_label]`.

**Mitigation:** the T4 helper must use the **same predicate wire**
that the M2b multi-origin path uses. Concretely: for a T4 store in a
non-entry block, compute the path-predicate via the same
`ctx.block_pred[block_label]` lookup that M2c uses, and AND it with
the idx-eq predicate. For multi-origin pointers into T4 allocas, the
origin's `predicate_wire` takes the role of `block_pred`. Test case:
diamond CFG with T4 store in one branch, load in join block.
**Proposed new unit test: L7g (diamond CFG × T4 store).** Must be
written RED-first before implementation.

### R3 — Interaction with `_lower_store_single_origin!` dispatch

The current single-origin dispatcher hard-errors on `:unsupported`
(see `lower.jl:2108`). Adding `:shadow_checkpoint` means we route
more shapes to a new path — any bug in that path is MUCH more likely
to hit MVP than a bug in the existing (tested) `:mux_exch_*` paths.

**Mitigation:** TDD per CLAUDE.md §3. Write L4 through L10 as a
ladder of increasingly-complex T4 tests before implementing the
helper. Start with N=2, W=8 (which IS covered by `:mux_exch_2x8`)
and have a **secret-knob test** that forces T4 dispatch on that
shape. If T4 produces the same functional answer as T1a, we have
cross-validation. Only then ramp to multi-word shapes.

### R4 — Wire allocator blow-up cascading into downstream tests

If a function pre-existing in BENCHMARKS.md quietly becomes T4-
dispatched (e.g. preprocessing changes reveal an alloca that was
being SROA'd away), the fresh tape wires change ancilla counts and
gate totals across EVERY row in the benchmark.

**Mitigation:** the dispatcher change is **strictly additive** —
shapes that previously returned `:shadow` / `:mux_exch_*` /
`:unsupported` continue to do so. ONLY shapes that previously
returned `:unsupported` (and therefore were uncompilable) get
re-routed. No currently-GREEN function can silently migrate to T4.
Confirm via CI pre/post diff of BENCHMARKS.md §Memory primitives +
core arithmetic rows.

### R5 — Multi-origin × T4 interaction deferred but lurking

Per §5, the multi-origin fan-out in `lower_store!` (line 2062) only
handles `:shadow` today (static idx). If a multi-origin pointer has
dynamic idx AND points to a T4-shape alloca, we error loudly. OK
for MVP. A future test (`L7h — multi-origin ptr × T4`) will pin
this. For now: add a defensive error message pointing at M3b.

### R6 — L11 exceeding compile time budget

MD5 full 64-round with T4 fan-out could produce a circuit with ~300k
wires + ~500k gates. Compilation time (not runtime) might blow past
Julia's reasonable session limit. Test on a warm REPL; if
compilation takes > 5 min, **reduce L11 scope** to 4-round cascade
(one MD5 round group) rather than full 64 rounds. Still a meaningful
benchmark; smaller regression window.

---

## Summary for the orchestrator

- MVP straight-line T4 = **one new dispatcher arm + two new helpers
  in `lower.jl`**, zero changes to `shadow_memory.jl`.
- Trigger: `n·W > 64`. Everything else keeps current dispatch.
- Tape allocation: fresh W wires per store per slot via
  `WireAllocator`. No reuse, no pebbling.
- Loads: fan-out over slots with idx-equality guards. Same shape as
  M2b `_lower_load_multi_origin!`.
- Bennett reverse: free — existing construction unwinds naturally.
- L10 GREEN by construction; L11 GREEN but **significantly over
  ReVerC budget** — this is the MVP baseline for M3b SAT pebbling
  to beat.
- Honest expected MD5 MVP: 80–200k Toff vs 27.5k target. MVP doesn't
  publish the headline; it establishes the handle so M3b can.
- Biggest risk: false-path sensitisation in the T4 × diamond-CFG
  case. Mitigated by writing L7g RED-first and reusing the M2b/M2c
  predicate-wire discipline.

Ship this one if the team wants correctness + compilability in the
smallest possible diff. Ship Proposer B's design if the team wants
to land pebbling in M3 instead of M3b (with all the risk that
implies).
