# C3 — Gate/circuit data model, Bennett transform + strategies, simulation + metrics

Adversarial architecture review, area C3. Files read in full: `src/gates.jl`,
`src/bennett_transform.jl`, `src/bennett_strategies.jl`, `src/pebble/{pebbling,
eager,value_eager,pebbled_groups}.jl`, `src/dep_dag.jl`, `src/controlled.jl`,
`src/compose.jl`, `src/simulator.jl`, `src/diagnostics.jl`, `src/feistel.jl`;
plus `BENCHMARKS.md`, `src/lowering/types.jl`, `src/lowering/driver.jl`
(callers), `src/lowering/call.jl`, `src/Bennett.jl` (entry points), and the
relevant tests. All measurements below were taken live on this machine with
`julia --project` on the current tree; no repo file was modified.

---

## 1. What this area actually does

**Data model.** Three immutable gate structs (`NOTGate`, `CNOTGate`,
`ToffoliGate`) with `Int` wire indices, under an abstract supertype
`ReversibleGate` (`gates.jl:4-22`). A circuit is a flat `Vector{ReversibleGate}`
plus five wire-index vectors and two width vectors (`gates.jl:81-94`). Wires are
bare `Int`s, globally numbered `1:n_wires`, allocated by a bump allocator during
lowering and *frozen* into the gate list before this area ever sees them. That
last fact drives most of what follows.

The inner constructor (`gates.jl:107-163`) enforces a genuinely good invariant:
the wire space is a **four-class partition** — input / output / ancilla /
loop-check — where ancilla must be disjoint from all others, loop-check disjoint
from all others, input∩output *is* allowed (self-reversing primitives write over
their inputs), and the union must cover exactly `1:n_wires`. This is the single
best piece of design in the area: it makes "which wires must be zero at the end"
a checked structural property rather than a convention.

**Bennett transform.** `_bennett_default` (`bennett_transform.jl:300-362`) is
about 30 lines of real work: allocate `n_out` copy wires past `n_wires`, allocate
one extra wire per loop guard, emit `lr.gates ++ copy CNOTs ++ loop-guard copy
CNOTs ++ reverse(lr.gates)`, and hand the result to `_build_circuit`. The
`self_reversing=true` fast path short-circuits to forward-only emission after
running a four-probe runtime contract check (`_validate_self_reversing!`,
`bennett_transform.jl:122-151`). `_infer_self_reversing`
(`bennett_transform.jl:192-231`) is the auto-detector: three structural
conditions over `GateGroup` producer-tags, then the runtime probe, conservatively
returning `false` on any doubt.

**Strategies.** `bennett_strategies.jl` is a 115-line dispatch shim: six
singleton/struct strategy types, six one-line `bennett(lr, ::Strategy)` methods,
five legacy forwarders. The bodies live in `src/pebble/`. Every one of the five
non-default bodies opens with the same 12-line prologue (self-reversing
short-circuit, loop-guard bail-out to `_bennett_default`, empty-groups bail-out,
`_has_branching` bail-out), then does its own thing.

**Simulation.** `apply!` is three one-line methods on `Vector{Bool}`
(`simulator.jl:1-3`). `_simulate_with_buffer!` (`simulator.jl:171-258`) validates
arity and per-input bit-width, seeds input wires LSB-first, snapshots inputs,
runs every gate in order, then checks loop-convergence wires, then ancilla-zero,
then input-preservation, then decodes the output with a signedness heuristic.
`diagnose_nonzero` is a non-throwing replay that additionally bisects the first
gate index at which each dirty ancilla became 1 — a genuinely useful debugger.

**Metrics.** `gate_count`, `ancilla_count`, `depth`, `toffoli_depth`, `t_count`
(= 7×Toffoli), `t_depth` (= toffoli_depth × table constant), `peak_live_wires`,
`constant_wire_count`, `verify_reversibility` (n random inputs, checks the three
invariants), `print_circuit` (also the `show` method).

**Combinators.** `controlled(c)` promotes every gate one control level
(NOT→CNOT, CNOT→Toffoli, Toffoli→3 Toffolis + shared ancilla). `compose(c1,c2)`
aliases c2's inputs onto c1's outputs, renumbers c2's other wires, and appends
`reverse(c1.gates)` to clean the intermediate.

**The real, as-shipped picture.** `reversible_compile` never passes a strategy
(`Bennett.jl:350,376,506` all call bare `bennett(lr)`), so **DefaultStrategy is
the only construction that runs in production**. Worse: `lower()` defaults
`fold_constants=true`, and `_fold_constants` returns an LR with
`GateGroup[]` (`lowering/driver.jl:508-510` — "Rebuild gate groups (invalidated
by folding — clear them)"). Every group-based strategy bails out on empty groups.
So in the default configuration the entire strategy layer is unreachable, and
even when reached by hand it degrades to `bennett(lr)` for anything with a
branch. Measured on `x^2+3x+1` (Int8, `lower()` defaults, 237 forward gates,
**0 gate groups**):

| strategy | gates | wires | ancillae | peak_live | build time |
|---|---|---|---|---|---|
| Default | 482 | 265 | 249 | 8 | 0.0001 s |
| Eager | 482 | 265 | 249 | 4 | 0.32 s |
| ValueEager | 482 | 265 | 249 | 8 | 0.33 s (identical gate list to Default) |
| Checkpoint | 482 | 265 | 249 | 8 | 0.65 s (identical gate list to Default) |
| Pebbled(8) | — | — | — | — | **throws** `insufficient pebbles — need at least 9 for 230 gates, have 1` |

Nothing reduces `n_wires`. That is the metric that matters for a quantum backend,
and no strategy moves it in the default pipeline.

---

## 2. Antipatterns, tech debt, accidental complexity

### 2.1 Genuine bugs (verified by running them)

**(a) `compose` silently deletes loop-overflow detection.** `compose.jl:182-185`
builds the result with `_compute_ancillae(n_total, input_wires, output_wires)`
and the 7-arg `ReversibleCircuit` constructor — no `loop_check_wires`. The
trailing `reverse(c1.gates)` also un-does the loop-guard copy-out CNOT, so the
convergence wire ends at 0, gets classified as an ancilla, and passes the
ancilla-zero check. Verified:

```
c1 = reversible_compile(countdown, Int8; optimize=false, max_loop_iterations=8)
c1.loop_check_wires        # => [LoopGuard(1206, :L2, 8)]
c12 = compose(c1, c2)
c12.loop_check_wires       # => []   ← detection gone
simulate(c12, Int8(3))     # => 4    ← no error even if the loop had overflowed
```

An input needing more than K iterations now yields a silently wrong answer
through `compose`. This is a direct CLAUDE.md §1 violation introduced by a
combinator that predates the loop work and was never revisited.

**(b) `controlled` is unusable on any loop circuit.** `controlled.jl:106-110`
*does* propagate `loop_check_wires` — but the whole point of a controlled circuit
is that with `ctrl=0` nothing fires, so the convergence wire stays 0 and
`simulate` throws a bogus "loop did not converge" error. Verified:

```
cc = controlled(c1); simulate(cc, false, Int8(3))
# ERROR: simulate: data-dependent loop with header block :L2 did not converge …
```

Two combinators, two opposite handling choices, both wrong. The underlying cause
is that `loop_check` is a *conditional* postcondition ("must be 1 if the circuit
ran") that the wire-partition model treats as unconditional.

**(c) `PebbledStrategy(k)` throws for almost every k.** `pebbled_groups.jl:349`
clamps `s = max(max_pebbles, min_pebbles(n_groups))`; `pebbling.jl` has no such
clamp and instead throws at `pebbling.jl:221` after recursing `s` down to 1. So
`PebbledStrategy(8)` on 230 gates is an error, while `PebbledGroupStrategy(8)`
silently clamps. Same concept, two behaviours.

**(d) `peak_live_wires` measures the all-zero input.** `diagnostics.jl:206-220`
starts from `zeros(Bool, c.n_wires)` and **never seeds the input wires**. It is
reporting live-wire counts on the single input `x = 0`, on which most Toffolis
never fire. This number is printed by `show` for every circuit
(`diagnostics.jl:111`) and is the "Peak Live" column in BENCHMARKS.md. It is not
a circuit metric; it is a one-sample trace.

**(e) `_read_int` silently truncates >64-bit outputs.** `simulator.jl:424-435`
accumulates into a `UInt64`; `raw |= UInt64(bit) << i` for `i ≥ 64` is a no-op in
Julia. No assertion guards `width ≤ 64`. Latent today (all shipped
`output_elem_widths` are ≤ 64), lethal the day a 128-bit product is an output.

### 2.2 The structural antipattern: "forward half = (n − n_out) ÷ 2"

Two places reconstruct circuit structure by *arithmetic guess* over the flat gate
list:

- `dep_dag.jl:31-34`: `n_forward = (n_total - n_out) ÷ 2`, then it scans
  positions `n_forward+1 : n_forward+n_out` assuming those are exactly the copy
  CNOTs.
- `diagnostics.jl:171`: the identical expression in `constant_wire_count`.

This is only true for `DefaultStrategy` on a non-self-reversing, loop-free LR. On
an eager/checkpoint/pebbled circuit, a self-reversing circuit (where the gate
list is *just* the forward pass), a loop circuit (extra copy CNOTs), a composed
circuit, or a controlled circuit, the arithmetic silently produces a wrong split
and both functions return garbage with no error. This is the canonical symptom of
**structure that was thrown away and is being re-derived by pattern-matching**.
`dep_dag.jl` has no consumer other than its own test file, and
`constant_wire_count` has no consumer at all beyond the export list
(`Bennett.jl:98`) — both are dead code carrying a wrong assumption.

### 2.3 Six independent per-gate-type dispatch families

Every module that needs to touch a gate's wires re-derives the same three-arm
dispatch:

| function | file:line | purpose |
|---|---|---|
| `apply!` | `simulator.jl:1-3` | evaluate |
| `_gate_target` / `_gate_controls` | `gates.jl:184-190` | project |
| `gate_wires` | `diagnostics.jl:38-40` | project (again, as a tuple of all wires) |
| `_gate_max_wire` | `controlled.jl:49-51` | project (again, as a max) |
| `_renumber_gate` | `compose.jl:45-47` | map wires through a Vector |
| `_remap_gate_wmap` | `pebbled_groups.jl:19-29` | map wires through a Dict |
| `_remap_gate_offset` | `lowering/call.jl:174+` | map wires through an offset |
| `promote_gate!` | `controlled.jl:114-127` | lift control level |

Seven families, three arms each, all mechanical. One `map_wires(f, gate)` plus
one `wires(gate)` would collapse the lot. This is the direct cost of modelling a
gate as three distinct nominal types instead of one record with a kind tag; it is
*not* justified by the domain, because the domain has exactly one operation
shape (`target ^= AND(controls)`).

### 2.4 The strategy layer is research residue wearing a dispatch table

- **`PebbledStrategy` is provably a no-op.** Read `_pebble_with_copy!`
  (`pebbling.jl:199-239`): it emits `forward[lo..mid]`, recurses on
  `[mid+1..hi]`, then `reverse[mid..lo]`. Unrolled, that is *exactly*
  `forward(1..n) ++ copy ++ reverse(n..1)` — the same gate sequence
  `_bennett_default` emits, with the same wire indices. There are no fresh wire
  allocations anywhere in the file. Knill's theorem buys space only when
  un-pebbling *frees storage for reuse*; here the wire indices were baked in by
  the lowering pass, so there is nothing to free. The docstring at
  `pebbling.jl:194-197` even admits "Total gate count is always 2n-1+n_out (same
  as full Bennett)" and then claims a peak-live bound that the construction
  cannot deliver. BENCHMARKS.md agrees: "SHA-256 Round / Pebbled (s=7): 1545
  wires, 1161 ancillae" — byte-identical to Full Bennett.
- **And it is expensive.** `knill_split_point` (`pebbling.jl:88-122`) rebuilds
  the *entire* n×s DP table on every call, and `_pebble_with_copy!` calls it once
  per recursion level (`pebbling.jl:223`). That is O(n²s) per call, O(n) calls →
  O(n³s) to compute a schedule that is provably identical to the trivial one. The
  0.32–0.65 s build times in my table above versus 0.0001 s for Default are this
  cost on a 230-gate circuit.
- **`EagerStrategy`'s own trailing comment documents that it cannot work**
  (`eager.jl:126-133`): "Wire-level EAGER … FAILS … PRS15's EAGER works at the MDD
  level where operations are atomic — our gate-level representation breaks this
  atomicity." What remains is dead-*end* cleanup only, which cannot reduce
  `n_wires` (again: indices are frozen) and only moves the broken
  `peak_live_wires` number.
- **`ValueEagerStrategy` / `CheckpointStrategy` / `PebbledGroupStrategy` are dead
  by default** because `_fold_constants` erases `gate_groups`. `CheckpointStrategy`
  is the *only* one with a real mechanism (it re-plays groups through a
  `WireAllocator` and genuinely recycles wires, `pebbled_groups.jl:380-501`), and
  it is gated behind three fallbacks — empty groups, `_has_branching`, in-place
  (Cuccaro) results — of which the second alone disqualifies essentially every
  interesting program.
- Even the *tests* are fooled: `test/test_bennett_strategy.jl:15` builds its
  fixture with plain `Bennett.lower(...)`, i.e. with folded constants and zero
  groups, so "CheckpointStrategy parity" is comparing two `bennett(lr)`
  fallbacks against each other.

The five-line prologue duplicated across `pebbling.jl:144-151`,
`eager.jl:64-75`, `value_eager.jl:37-44`, `pebbled_groups.jl:281-288` and
`pebbled_groups.jl:386-393` (self-reversing short-circuit + loop-guard bail) is a
symptom: five copies of a precondition that should live once, at the dispatch
boundary.

### 2.5 The algebra of circuits is not an algebra

- `compose` is semantically associative but not cost-associative. Measured on
  three Int8 increments: `|a|=58`, `|(a∘b)∘d| = 404`, `|a∘(b∘d)| = 288`, same
  answer, same wire count. Left-nesting multiplies the first operand's gate count
  by 2^k. That is because `compose` re-wraps an *already Bennett-wrapped* circuit:
  `compose(A,B) = 2|A| + |B|` where `|A|` is itself `2·forward`.
- The same defect exists inside the compiler: `lowering/call.jl:102` calls
  `bennett(callee_lr)` and then inlines the whole wrapped circuit into the
  caller's gate stream, which the caller's own Bennett wrap will then double
  again. Nested Bennett wraps are the classic exponential; the only reason it
  doesn't bite is that `compact_calls` defaults to `false`.
- `controlled` promotes *every* gate, including the uncompute half. Measured on
  `x+1` (Int8): 58 gates / T-count 84 → 82 gates / **T-count 532**, a 6.3×
  T-count blow-up. But the inner circuit is already a Bennett circuit whose
  outputs are fresh copy wires initialised to zero. The textbook construction is
  therefore: run forward *uncontrolled*, control only the `n_out` copy-out CNOTs
  (turning them into Toffolis), run uncompute *uncontrolled*. Cost: `n_out`
  Toffolis, i.e. 8 extra Toffolis instead of 64 promoted ones — and the ancilla
  wire disappears. For the stated long-term goal (`when(qubit) do f(x) end` in
  Sturm.jl) this is *the* hot path, and the shipped implementation is ~6× more
  expensive than necessary. `controlled` also never checks
  `input_wires ∩ output_wires == ∅`, so its stated contract
  `(ctrl,x,0) → (ctrl,x,ctrl ? f(x) : 0)` is simply false for self-reversing
  circuits.

### 2.6 Verification hygiene

- `verify_reversibility` (`diagnostics.jl:239-279`) uses bare `rand(Bool)` with no
  seed and no RNG parameter. Failures are not reproducible. This directly
  contradicts the reasoning written two files away at `bennett_transform.jl:76-78`
  ("Deterministic — CLAUDE.md §4 and §6 both favour reproducible failures over
  randomised sweeps"). Two components in the same area disagree about the
  project's own testing philosophy.
- Its check (3), forward-then-reverse restores the state, is acknowledged in its
  own docstring as tautological for self-inverse gates. It costs 2× the runtime
  of the meaningful checks and catches only harness bugs.
- The name is a category error: it verifies *Bennett's invariants*, never that
  the circuit computes `f`. Functional correctness is checked ad hoc in each test
  file against a Julia oracle. There is no single `verify_against(f, c)` entry
  point, which is why every one of the 320 test files re-writes the sweep loop.
- `_validate_self_reversing!`'s four-probe battery (all-zero, all-one, two
  walking-1s) is a reasonable smoke test, but it is being used as an *acceptance
  gate for a load-bearing optimisation* — a forged tag that happens to survive
  four probes silently halves the circuit and corrupts everything downstream.
  Four probes is not a proof.

### 2.7 Performance of the data model

Measured on `(a,b) -> a*b` at UInt64 (28,044 gates, 12,545 wires):

| | value |
|---|---|
| `Base.summarysize(c.gates)` | 496,640 B = 17.7 B/gate |
| distinct gate objects | 14,054 of 28,044 (forward/reverse halves share boxes) |
| `simulate` throughput | 330 Mgate/s |
| boxed `apply!` loop, isolated | 140 Mgate/s |
| flat 16-byte struct + `@inbounds`, isolated | 277 Mgate/s (**2.0×**) |

Notes:
- The memory number is only tolerable *by accident*: `_bennett_default` pushes
  the *same* `ReversibleGate` objects into the reverse half
  (`bennett_transform.jl:356-358`), so half the boxes are shared. Nothing
  documents or tests this; a strategy that reconstructs gates (e.g.
  `_remap_gate_wmap`) loses it silently.
- Extrapolated to the ~11 M-gate `soft_sin` circuit (worklog 055): ~195 MB for
  the gate vector alone, on top of the LR's own copy — i.e. the peak during
  `bennett()` is roughly 3× the forward gate list.
- `apply!` has no `@inbounds`. Under `Pkg.test()`'s `--check-bounds=yes` every one
  of the ~692k assertions' simulate calls pays three bounds checks per gate. That
  is a meaningful slice of the 28-minute suite.

### 2.8 Complexity that IS justified

To be fair, several things that look baroque are earning their keep:

- The four-class wire partition and its five distinct error messages
  (`gates.jl:119-159`). Verbose, but each message names the exact failure mode and
  the bead that motivated it. Keep.
- Input-preservation checking (`simulator.jl:202,234-240`). The worklog is
  explicit that circuits used to silently mutate inputs and still pass. Keep.
- The `LoopGuard` convergence bit. Making "did the unrolled loop actually
  converge" a *value carried out of the circuit* rather than a compile-time
  assumption is exactly right, and it is the only fail-loud mechanism available
  for an unrollable-but-unbounded loop. Keep, and propagate it through every
  combinator.
- `_assert_input_fits` (`simulator.jl:13-26`) with the signed-or-unsigned dual
  range. Fiddly, but the alternative is silent truncation.
- `diagnose_nonzero`'s second replay pass to find the first-set gate index. Costs
  a second simulation, saves hours of bisection.
- The `t_depth` decomposition table (`diagnostics.jl:144-147`). Small, cited,
  honest about being an estimate.
- `feistel.jl` is clean, self-contained, correctly uncomputes its round function,
  cites Luby–Rackoff, and is the only file here with no structural debt. It is
  also not core — it is a library primitive that happens to live at top level.

---

## 3. Version coupling (Julia 1.12 / LLVM)

This area is almost LLVM-free — it consumes `LoweringResult` and never touches
IR. The coupling that exists is to the *Julia compiler's optimiser behaviour*,
not to its API:

1. **Union-splitting of `apply!`.** The entire storage-layout decision
   (`gates.jl:55-79`) rests on Julia devirtualising the three-arm `apply!`
   dispatch inside `_simulate`'s loop. `test/test_jc0y_gate_storage_contract.jl`
   pins this as `@allocated simulate(c2, …) < 200_000` and `< 8 B/gate`. That is
   a *compiler-behaviour* test, not a semantics test. It will not break on 1.13,
   but it could shift, and if it ever regresses the failure mode is a 10× slowdown
   with no correctness signal.
2. **`sizeof(NOTGate)==8 / CNOTGate==16 / ToffoliGate==24`** are pinned in the
   same file. Stable, but they encode "wire index is a machine `Int`", which is a
   design choice worth revisiting (Int32 halves every gate).
3. **`Base.summarysize`** is used as a memory contract; its accounting of shared
   boxes is an implementation detail.
4. **`--check-bounds=yes`** under `Pkg.test()` interacts with the un-annotated
   hot loop, as above.
5. **`objectid`-keyed compile cache** (`Bennett.jl:500`) means circuit identity
   depends on GC/hashing behaviour. Not in my files, but it determines whether
   `c1 === c2` for repeat compiles, which several of my area's tests assume.

Nothing here breaks on 1.13. What 1.13 *offers* this area:

- `Memory{T}` as the array primitive → a genuinely flat, resizable gate tape with
  no `Array` indirection.
- Better escape analysis / stack allocation for small immutables → a `Gate`
  record type passed by value through `map_wires` costs nothing.
- `public` declarations → the current 15-symbol `export` line
  (`Bennett.jl:98-100`) exports `constant_wire_count` (dead) and five legacy
  `*_bennett` aliases (residue); 1.13 lets the surface be curated without
  breaking `using`.
- `@assume_effects` / improved const-prop → `apply!` and the bit-sliced kernel
  below can be made allocation-free and vectorisable with less hand-holding.
- Static compilation (`juliac`/`--trim`) → a standalone simulator binary is
  plausible in v2, which matters if 11 M-gate circuits ever need to be checked
  outside a REPL session.

**Verdict on version coupling: near zero.** This area is the *least* exposed part
of the compiler and should not be a factor in the rewrite decision — but it is
also where a rewrite buys the most, because none of its debt is forced by LLVM.

---

## 4. From-scratch verdict

### KEEP (port verbatim or near-verbatim)

1. **The four-class wire partition invariant** (`gates.jl:107-163`), including its
   error messages. Reimplement the check with a `BitVector`/`Memory{UInt8}` class
   map instead of four `Set{Int}` + `union` + `setdiff` (which allocates an
   `n_wires`-entry hash set on every circuit construction — ~64 MB of temporaries
   for a 2 M-wire soft-float circuit).
2. **All three simulate-time invariants**: ancilla-zero, input-preservation,
   loop-convergence — and the ordering (loop check *before* ancilla check, so the
   actionable diagnosis wins). `simulator.jl:208-240` is right.
3. **`LoopGuard` as a first-class wire class.** Extend: it must be a *conditional*
   postcondition so `controlled` can suppress it, and it must be propagated by
   every combinator.
4. **`diagnose_nonzero`'s first-set-gate bisection.** Generalise it into a proper
   differential debugger over the v2 IR (report the *IR node*, not the gate
   index).
5. **The Knill DP itself** (`knill_pebble_cost`, `min_pebbles`, `pebble_tradeoff`,
   `pebbling.jl:39-80,248-256`) as a **cost model / analysis function**. It is
   correct, cited, and cheap. Discard the scheduler that uses it.
6. **The compute–copy–uncompute-per-group idea** from `_checkpoint_bennett_impl`.
   This is the only strategy with a real space win; it must be re-hosted where it
   can actually allocate wires.
7. **Tests worth porting verbatim:** `test_gate_count_regression.jl` (the 39
   pinned baselines are the project's most valuable artefact), `test_6azb_*`
   (input preservation), `test_s0tn_loop_overflow.jl`, `test_pksz_*`
   (contiguous-wire), `test_rjk7_*` (self-reversing honoured uniformly),
   `test_qcso_compose.jl` semantics (but not its cost expectations), and every
   exhaustive-Int8 oracle sweep.

### DISCARD

1. `src/dep_dag.jl` — dead, and built on the wrong forward-half heuristic.
2. `constant_wire_count` — dead, same heuristic.
3. `PebbledStrategy` and `_pebble_with_copy!` — provably emits the Bennett
   sequence at O(n³s) cost.
4. `EagerStrategy` — its own comment explains why gate-level EAGER cannot work.
5. `ValueEagerStrategy` — unreachable by default, subsumed by a real scheduler.
6. The five legacy `*_bennett` forwarders and the `BennettStrategy` dispatch
   table as such.
7. `peak_live_wires` in its current form (all-zero-input trace).
8. `controlled`'s whole-circuit gate promotion.
9. `compose` at the circuit level.
10. `Vector{ReversibleGate}` with an abstract element type.
11. The unseeded `rand` in `verify_reversibility`.

### REDESIGN — the design I would choose today

**(i) One gate record, one tape.**

```julia
struct Gate                    # 16 bytes, isbits
    kind::UInt8                # NOT | CNOT | TOF (room for MCX-k, SWAP later)
    _pad::UInt8; _pad2::UInt16
    a::Int32; b::Int32; t::Int32
end
```

Wire indices as `Int32` (4 G wires is plenty). Store as `Memory{Gate}` or a
struct-of-arrays `(kinds::Memory{UInt8}, a,b,t::Memory{Int32})` — measure, but the
16-byte AoS already gave 2× over the status quo in my microbenchmark. One
`map_wires(f, g)` and one `wires(g)`; the seven dispatch families collapse to two
functions.

**(ii) Hierarchical circuit IR with adjoint as structure — this is the big one.**

```julia
abstract type Circ end
struct Prim   <: Circ; tape::UnitRange{Int} end        # slice of a shared gate arena
struct Seq    <: Circ; kids::Vector{Circ} end
struct Adj    <: Circ; kid::Circ end                   # uncompute — NOT materialised
struct Compute<: Circ; body::Circ; outs::Vector{Wire} end  # Bennett node: body ; copy ; Adj(body)
struct Ctl    <: Circ; ctrl::Wire; kid::Circ end
struct Scope  <: Circ; ancillae::Int; kid::Circ end    # allocate/free a wire region
```

Consequences, all of which fix a defect above:

- `gate_count(Adj(c)) = gate_count(c)` — a closed form. No 11 M-gate
  materialisation to count gates. Metrics become folds.
- Memory for `soft_sin` drops from ~195 MB (materialised, both halves) to ~90 MB
  (forward only) — and the interpreter walks the `Adj` node backwards over the
  same arena.
- `Compute` makes "ancillae return to zero" *structurally true*: the node's
  contract is enforced by construction, exactly as Quipper's `with_computed`,
  Q#'s `within/apply`, and Silq's implicit uncompute do. Simulation stops being
  the proof.
- `Ctl(ctrl, Compute(body, outs))` rewrites to
  `Seq(body, Ctl-copy(outs), Adj(body))` — the cheap controlled construction —
  as a *rewrite rule on the IR*, not a hand-written promoter. The 6.3× T-count
  penalty disappears.
- `compose` becomes `Seq` at the IR level with the intermediate `Compute` node
  fused, so `(a∘b)∘c` and `a∘(b∘c)` produce the same tape. Cost-associativity is
  restored for free.
- `dep_dag`'s "which gates are the forward half" question disappears: the answer
  is a field.

**(iii) Wire allocation must move under the scheduler, not above it.** The single
root cause of "four of six strategies do nothing" is that `lower()` freezes wire
indices before any strategy runs. In v2, lowering emits `Circ` over *symbolic*
wires (SSA-ish `Wire` handles with scoped lifetimes, à la PRS15's ancilla heap);
a **placement pass** then assigns physical indices under a space budget, using the
Knill DP to choose where to insert `Compute` checkpoints. That pass is the *only*
"strategy" v2 needs: one scheduler with a `max_wires` parameter, replacing six
strategy types. Everything the current strategies gesture at (EAGER, pebbling,
checkpointing) is expressible as choices inside it, and unlike today it can
actually reduce `n_wires`.

**(iv) Simulation: bit-sliced, 64 inputs per pass.** Replace `Vector{Bool}` with
`Memory{UInt64}` of length `n_wires`, each word holding the same wire's value
across 64 independent inputs. `apply!` becomes `w[t] ⊻= w[a] & w[b]` — identical
code, 64× the work per instruction. Exhaustive Int8 verification becomes 4 passes
instead of 256; a 2^16 sweep becomes 1024 passes instead of 65,536. Ancilla-zero
becomes `w[anc] == 0` over all 64 lanes at once. Given that the current suite is
28 minutes and dominated by sweep loops over multi-million-gate transcendental
circuits, this is plausibly the highest-ROI single change in the whole rewrite,
and it is ~50 lines. Keep the scalar path only for `diagnose_nonzero`.

**(v) Verification: three tiers, not one.**

- *Tier 0 — by construction.* `Compute`/`Scope` nodes make ancilla-cleanliness a
  type-level property. Only hand-written primitives (`self_reversing` producers:
  QROM, Sun-Borissov mul, soft-float kernels) need runtime probing, and those get
  a real contract check, not four probes.
- *Tier 1 — property-based, reproducible.* A single
  `verify(f, c; rng=StableRNG(seed), n)` that checks *functional equivalence
  against the Julia oracle* plus the invariants, with a fixed seed printed in the
  failure message and input shrinking. Replaces both `verify_reversibility` and
  the 320 hand-rolled sweep loops.
- *Tier 2 — algebraic / exhaustive-in-one-pass.* Two options, both worth
  prototyping: (a) **symbolic simulation over ANF/BDD** — run the circuit once
  with each input bit as a symbolic variable; every wire ends holding a Boolean
  polynomial, and the ancilla-zero property becomes "polynomial ≡ 0", which is
  exhaustive over *all* inputs in one pass (Toffoli-heavy circuits blow up in
  degree, so this is for kernels, not for `soft_sin`); (b) **miter equivalence
  checking against the source semantics** — bit-blast the LLVM IR's semantics and
  the emitted circuit into one CNF and ask a SAT solver for a differing input.
  The project already flirted with SAT (`pebble/sat_pebbling.jl`, dropped in
  Bennett-u2yp) — the right use of a solver here is *verification*, not pebbling.
  Note CLAUDE.md §14 forbids remote CI, not local solvers.
- Keep exhaustive Int8 sweeps as the cheap always-on smoke test; with bit-slicing
  they cost 4 passes.

**(vi) Metrics as IR folds.** `gate_count`, `t_count`, `toffoli_depth` computed
over `Circ` without materialisation. Fix `depth` to model control reads as
commuting (two gates sharing only a control are parallel; the current
`diagnostics.jl:63-73` serialises them and over-reports depth). Replace
`peak_live_wires` with `max_live_wires`, computed statically from `Scope`
lifetimes — a real, input-independent space metric.

---

## 5. Specific questions

### (a) Flat gate vectors at 11 M gates — does v2 need a hierarchical IR?

**Yes, and the argument is memory and metrics, not simulation speed.**

Measured: 17.7 B/gate today (helped by accidental box sharing between the
forward and reverse halves), 330 Mgate/s for `simulate`. An 11 M-gate `soft_sin`
circuit is therefore ~195 MB resident and ~33 ms per simulated input — the speed
is *fine*; a 1000-input accuracy sweep is 33 s, and bit-slicing would take it to
~0.5 s. The problem is that (1) `bennett()` peaks at roughly 3× the forward gate
list because it holds `lr.gates` and appends both halves into a new vector, (2)
every metric (`gate_count`, `depth`, `t_count`) is an O(n) scan over a list whose
second half is definitionally the mirror of its first, and (3) nothing can query
"what was the forward half?" without the `(n − n_out) ÷ 2` guess.

A hierarchical IR with `Adj` as a node fixes all three: half the memory, closed-
form metrics, structural answers. Materialise a flat `Memory{Gate}` tape *only*
at the export boundary (writing OpenQASM, feeding Sturm.jl), and even then stream
it rather than building it. Concretely I would target: `Gate` = 16 B isbits,
`Memory{Gate}` arena, `Circ` tree referencing arena slices, one `foreach_gate`
iterator that walks the tree (forward or reversed) without allocating. Simulation
runs off that iterator; the 2× win from `@inbounds` + flat records comes along
for free.

### (b) Which of the six strategies are load-bearing?

- **`DefaultStrategy`: load-bearing.** It is the only one `reversible_compile`
  ever uses, and all 39 gate-count baselines are pinned to it.
- **`CheckpointStrategy`: the only one with a real idea** (per-group
  compute–copy–uncompute with wire recycling via `WireAllocator`). Currently
  unreachable in the default pipeline. Port the *idea*, not the code.
- **`PebbledGroupStrategy`: half-residue.** Its interesting path immediately
  delegates to `_checkpoint_bennett_impl` (`pebbled_groups.jl:317-319`); the rest
  is fallbacks.
- **`PebbledStrategy`: pure residue**, and actively harmful (throws on
  reasonable inputs, O(n³s) to reproduce the trivial schedule).
- **`EagerStrategy`: residue**, disproven by its own trailing comment.
- **`ValueEagerStrategy`: residue**, dead by default.

Verdict: **one strategy plus one scheduler.** v2 should expose `bennett(circ)`
and `schedule(circ; max_wires)`, not a six-member type hierarchy. Keep the Knill
DP as the scheduler's cost model.

### (c) `simulate` / `verify_reversibility` as the correctness oracle

**Strengths.** It is fast (330 Mgate/s), it is exact (no floating point, no
sampling error in the *semantics*), it checks three real invariants with precise
error messages, and it made a genuine class of bugs impossible after
Bennett-6azb added input-preservation. For Int8 it is *exhaustive*, which is the
strongest possible statement. `diagnose_nonzero` turns a failure into a gate
index. This is a better oracle than most compiler projects have.

**Weaknesses.** (1) It verifies invariants, never `f` — functional correctness is
re-implemented per test file. (2) `verify_reversibility`'s randomness is
unseeded, so failures aren't reproducible, contradicting the project's own stated
preference. (3) Its round-trip check is tautological. (4) Coverage is
input-space-sampled: the worklog's own `soft_exp` post-mortem (CLAUDE.md §13) is
exactly a case where a 100-sample sweep missed a whole input regime — and the fix
was a hand-written convention ("sweep every binade") rather than a structural
one. (5) At 11 M gates the oracle is the bottleneck for any thorough sweep.

**What should replace/augment it in v2:** the three tiers in §4(v) — structural
guarantee for the Bennett wrap (removing ~90% of what is currently simulated),
seeded property-based testing with shrinking as the default tier, and
ANF/BDD-symbolic or SAT-miter equivalence for kernels where exhaustive coverage
actually matters (adders, soft-float primitives, QROM). Plus bit-sliced
simulation so the sweeps that remain are 64× cheaper. Concretely: replace
`verify_reversibility(c)` with `verify(c; against=f, rng, n)` and make `against`
mandatory unless the caller explicitly asks for invariants-only.

### (d) Is the algebra of circuits coherent?

**No.** There are four combinators (`bennett`, `controlled`, `compose`, callee
inlining) and they do not form a consistent algebra:

- **Not cost-associative.** `|(a∘b)∘c| = 404` vs `|a∘(b∘c)| = 288` for the same
  function.
- **Not idempotent under wrapping.** `compose` and `compact_calls` inlining both
  apply Bennett to already-Bennett circuits, doubling per level.
- **Metadata is not preserved uniformly.** `compose` drops `loop_check_wires`
  (silently disabling overflow detection); `controlled` keeps them (breaking
  `ctrl=0`); neither handles `output_elem_widths` beyond a positional copy;
  neither supports non-positional wiring.
- **Preconditions are inconsistent.** `compose` rejects self-reversing circuits
  loudly (`compose.jl:114-130`); `controlled` accepts them and silently violates
  its own documented contract.
- **Identity and inverse are missing.** There is no `identity_circuit`, no
  `adjoint(c)`, no `tensor(c1, c2)` (parallel composition on disjoint wires) —
  yet `adjoint` is the operation the entire construction is built on, and it
  exists only as an inlined `for i in n:-1:1` loop in five different files.

In v2 the algebra should be the IR: `Seq`, `Adj`, `Ctl`, `Par`, `Scope`,
`Compute`, with laws that hold by construction (`Adj(Adj(c)) = c`,
`Adj(Seq(a,b)) = Seq(Adj(b),Adj(a))`, `Ctl(k, Compute(b,o)) → Seq(b, Ctl-copy(o),
Adj(b))`), a single metadata record (`inputs, outputs, ancillae, guards`) that
every combinator is *required* to transform, and property tests asserting the
laws. That is a few hundred lines, and it subsumes `controlled.jl`, `compose.jl`,
`bennett_transform.jl`, all of `src/pebble/`, and `dep_dag.jl` — roughly 1,900
lines today.

---

## Appendix: measurement provenance

All figures from `julia --project` on the current tree, single process, no
concurrent test runs (`pgrep julia` empty beforehand, per the project memory):

- `(a,b)->a*b :: UInt64` → 28,044 gates / 12,545 wires; `summarysize(c.gates)` =
  496,640 B; 14,054 distinct gate objects; `simulate` 330 Mgate/s; isolated
  boxed-`apply!` loop 140 Mgate/s; isolated flat-16-byte + `@inbounds` loop 277
  Mgate/s.
- `x -> x+Int8(1)` → 58 gates / T-count 84; `controlled` → 82 gates / T-count 532
  / 43 wires.
- `x -> x+Int8(1)`, `+2`, `+3` composed: 58 / 170 / 404 (left) / 288 (right).
- `x^2+3x+1 :: Int8` via `lower()` defaults: 237 forward gates, **0 gate
  groups**; strategy table in §1.
- `countdown :: Int8`, `optimize=false, max_loop_iterations=8`: loop-check wire
  1206; `compose` drops it; `controlled` + `ctrl=false` throws a spurious
  non-convergence error.
