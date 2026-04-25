# M3 Design — Proposer B: SAT-pebbled T4 shadow-checkpoint + re-exec

**Issue**: Bennett-cc0 M3 (per `Bennett-Memory-PRD.md` §10)
**Scope**: new T4 tier in `src/lower.jl` dispatcher; integrates `src/sat_pebbling.jl`
(Meuli 2019) with `src/shadow_memory.jl` (T3b) to compact shadow-tape footprint.
**Angle**: SAT-pebble the **store dependency DAG** as a pre-pass; consume the
schedule at store/load lowering time to reuse tape slots under Bennett's
recursive segmentation. Targets MD5 ≤ 27,520 Toff (beat ReVerC 2017).

## 1. One-line recommendation

**Run Meuli 2019 SAT-pebbling as a pre-pass over a per-function
`StoreDepDAG` (nodes = stores, edges = MemorySSA def-use). The pebbler
emits a schedule assigning each store to a tape-slot index; stores whose
live-ranges are disjoint share a slot. `_pick_alloca_strategy` gains a
`:shadow_checkpoint` branch that fires for static-idx allocas whose
total-pebble footprint exceeds a W-scaled budget (default 256 W-bit
slots). T4 stores emit `emit_shadow_store!` against a shared tape pool
sized by the pebbling result; re-execution of the forward prefix is
emitted by the existing `pebbled_group_bennett` / `checkpoint_bennett`
path, which already does Knill recursive segmentation and wire-reuse.
Fall back to Knill (`pebbling.jl`) when the SAT solver times out
(configurable, default 5s). This is additive: T3b is unchanged; T4
activates only above budget.** MD5 64-round is the headline target.

## 2. Scope

**In scope (this milestone):**
- **L10** — `Array{Int8}(undef, 256)` with dynamic index. Static-size,
  large enough that the naïve T3b tape (N·W = 2,048 wires) plus N stores
  blows the 20 kG-per-op budget once the inner computation is factored
  in. With T4 + SAT pebbling the tape collapses to O(log N)·W = 32
  wires (+ re-exec gate overhead).
- **L11** — MD5 compression, 64 rounds, 512-bit block. Gate-count
  headline: **≤ 27,520 Toffoli** to beat ReVerC 2017. Current state:
  ~48 kToff (BENCHMARKS.md:146, linear extrapolation).
- **Budget** — ≤ 20 kGates per memory op per `SURVEY.md` §1.
- **Tape compression** — shared tape pool instead of per-store slots.
- **Guarded stores** — M2c-compatible: pebbled tape slots remain
  compatible with `emit_shadow_store_guarded!` because the guard is a
  read-only wire.

**Out of scope (deferred):**
- **Dynamic-size allocas** — `alloca` with runtime `n_elems`. Still
  errors at `lower_alloca!:1949`. This is T5 territory (Okasaki+Mogensen
  2018 hash-consed arrays), next PRD.
- **Cross-function tape sharing** — each function has its own tape pool;
  we do NOT pebble across `register_callee!` boundaries. Would require a
  second pebbling pass on the inlined super-DAG.
- **Non-shadow T4** — the checkpoint primitive remains the 3W-CNOT
  shadow pattern. We do not mix T4 with T1a MUX EXCH; dynamic-idx stays
  on the T1a path for L2/L3 compatibility.

## 3. Dispatch trigger — when T4 fires vs T3b

`_pick_alloca_strategy` is extended. Current (verbatim from
`src/lower.jl:2011–2027`):

```julia
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand)
    if idx.kind == :const
        return :shadow                 # T3b.2, always
    end
    # ... dynamic-idx MUX EXCH branches ...
end
```

T4 extension (new `:shadow_checkpoint` strategy, fires within the
static-idx branch only):

```julia
function _pick_alloca_strategy(shape::Tuple{Int,Int}, idx::IROperand;
                               store_count::Int=0, tape_budget::Int=256)
    if idx.kind == :const
        # Shadow fast path for small static-idx allocas. Fall to T4
        # when the tape would exceed `tape_budget * W` wires.
        (elem_w, n) = shape
        if store_count * elem_w <= tape_budget * elem_w
            return :shadow             # T3b.2 (unchanged)
        else
            return :shadow_checkpoint  # T4 (new)
        end
    end
    # ... dynamic-idx MUX EXCH branches (unchanged) ...
end
```

**Budget math.** For MD5 64-round compression, the message schedule
stores 16 × Int32 into an alloca, then 64 round-step stores mutate state
Int32s. That's ~80 stores of W=32 bits per round step. Full T3b tape: 80
× 32 = 2,560 wires, comfortably under `tape_budget * W = 256 * 32 =
8,192`. **L11 therefore stays on T3b in the default case.** T4 engages
for larger working sets (L10's 256-entry Int8 array with 256 stores: 256
× 8 = 2,048 wires, under budget; but if we scale to L10b with 1,024
entries × 32-bit width we hit 32,768 wires and trigger T4).

**This forces a design decision.** The MD5 headline can be hit two ways:

1. **T4 forced on for MD5 via user flag** — `reversible_compile(md5; use_shadow_checkpoint=true)`.
   Clean but requires benchmark-level opt-in.
2. **Budget-driven auto-dispatch** — lower `tape_budget` to e.g. 64
   so MD5's inner stores trip T4. Risk: regressing smaller benchmarks.

**Proposer B's recommendation: auto-dispatch based on `store_count *
elem_w > TOTAL_BUDGET_DEFAULT`.** Default the total budget at ~16,384
wires (256 × 64). MD5's raw state + schedule is ~3,000 wires (under) —
so T4 does NOT auto-trigger for MD5 in the default budget. **The MD5 win
does not come from T4 activation per se — it comes from extending T4's
SAT-pebbling pre-pass to ALSO run when T3b is picked, so T3b's tape pool
is compacted.** Rename the strategy to `:shadow_pebbled` and make it the
default for all static-idx stores once `store_count ≥ 4` — SAT-pebble
small tapes too. Keeps M3 strictly additive vs M2c on the ≤4-store fast
path.

## 4. Dependency DAG — input to the pebbler

### 4.1 What `src/sat_pebbling.jl` accepts

API (verbatim from `sat_pebbling.jl:26`):

```julia
function sat_pebble(adj::Dict{Int, Vector{Int}}, outputs::Vector{Int};
                    max_pebbles::Int, max_steps::Int=0, timeout_steps::Int=100)
    # returns Vector{Set{Int}} — pebble configurations P_0..P_K
```

**This solves the pebble game on a gate-level DAG, not a store-level
DAG.** Nodes are integers; edges are predecessor lists. The schedule is
a sequence of pebble configurations. Each pebble = one live ancilla wire.
The PRD's framing of "tape slot pebbling" maps cleanly onto this: each
store is a node, an edge exists from store S_j to S_i iff S_i reads
from S_j's location (MemorySSA def-use), and a pebble on S_i means
"the shadow tape slot that holds S_i's old value is still live". We
need **W-wire-granularity pebbles**, not 1-wire pebbles; the pebbler
output is a slot-assignment (tape-slot index per store) rather than an
"allocate/free" gate-level schedule. That translation is straightforward:
two stores in the same pebbled time-step get distinct tape slots; two
stores whose live-ranges are disjoint (one pebbled-then-unpebbled before
the other is pebbled) can share a slot.

### 4.2 StoreDepDAG — new type

```julia
# src/shadow_checkpoint.jl (new file)
"""
    StoreDepDAG

Per-function dependency DAG over shadow stores, derived from MemorySSA
and the ptr_provenance map. Each node is a single static store; edges
connect store S_j → S_i when S_i may observe S_j's value via an
intervening load (MemorySSA def-use) or S_i is a CLOBBERING re-store to
the same slot. Control-flow guards are abstracted: two stores guarded by
mutually-exclusive predicates get a `mutex_group_id` tag so the pebbler
can model them as a single time-step (they never both materialise).

Fields:
  - `nodes::Vector{StoreNode}` — parallel to the stores of the function
  - `adj::Dict{Int, Vector{Int}}` — pebbler-ready adjacency
  - `outputs::Vector{Int}` — "output" stores: those whose tape-slot is
    still live at function return (empty for the usual case where all
    tape slots are uncomputed by Bennett reverse)
  - `mutex_groups::Dict{Int, Int}` — node → mutex-group-id (M2c guards)
"""
struct StoreNode
    gate_group::Symbol       # the GateGroup name of this store
    alloca_dest::Symbol      # which alloca is written
    idx::Int                 # static-index within alloca
    W::Int                   # element width
    block_label::Symbol      # predicate source (M2c guard)
    predicate_wire::Int      # guard wire (M2c); 0 if unguarded/entry
end

struct StoreDepDAG
    nodes::Vector{StoreNode}
    adj::Dict{Int, Vector{Int}}
    outputs::Vector{Int}
    mutex_groups::Dict{Int, Int}
end
```

### 4.3 Reuse of `src/dep_dag.jl`?

**No.** `dep_dag.jl:28` builds a DAG over **gates** (`extract_dep_dag`
walks the forward half of a finished `ReversibleCircuit`). Three reasons
a new `StoreDepDAG` is needed:

1. **Granularity**: dep_dag.jl treats each gate as a node. We want one
   node per IR-level store (coarse-grained, N-node DAG for N stores).
2. **Timing**: `extract_dep_dag` runs *after* `lower()`; we need the DAG
   *during* `lower()` (or in a pre-pass) so the lowering consumes the
   schedule. Walking gates after lowering is backwards.
3. **MemorySSA integration**: store-to-store edges come from MemorySSA
   def-use, not from wire-WAW. dep_dag.jl has no notion of MemorySSA.

### 4.4 Building StoreDepDAG

Build pass runs **before** `lower()`'s main instruction walk, during a
new "planning" phase. For each `IRStore` in parsed IR order:

1. Resolve `inst.ptr` via `ptr_provenance` + `alloca_info` → (alloca, idx).
2. Find the MemorySSA `MemoryDef` for this store (via `MemSSAInfo`).
3. For each `MemoryUse` that is clobbered by this Def (reverse lookup in
   `MemSSAInfo.use_at_line`), record the Def → Use edge. For each
   subsequent `MemoryDef` that clobbers this Def, add a WAW edge.
4. Classify block predicate:
   - Entry block: `predicate_wire = 0` (sentinel for "unguarded").
   - Non-entry: `block_pred[label][1]`.
5. Tag mutex-groups: stores guarded by mutually-exclusive predicates
   (e.g. `c` vs `!c` from the same if/else) get the same `mutex_group_id`.

**Without MemorySSA** (no `preprocess=true`, or LLVM version drift): fall
back to conservative ptr_provenance-based def-use — every static-idx
store targeting the same `(alloca, idx)` becomes a WAW chain. This over-
approximates dependencies but is safe (more dependencies → more pebbles,
costs time but not correctness).

## 5. SAT pebbling integration

### 5.1 Calling `sat_pebble`

```julia
# src/shadow_checkpoint.jl
function pebble_store_dag(dag::StoreDepDAG; max_pebbles::Int=0,
                          timeout_seconds::Float64=5.0)
    # Default pebble budget: sqrt(N) for N stores (Bennett 1989 tradeoff).
    N = length(dag.nodes)
    P = max_pebbles > 0 ? max_pebbles : max(min_pebbles(N), ceil(Int, sqrt(N)))

    # Outputs: stores whose value is live at return (typically none — all
    # tape slots uncomputed by Bennett reverse).
    outputs = dag.outputs

    t0 = time()
    schedule = sat_pebble(dag.adj, outputs;
                          max_pebbles=P, timeout_steps=max(50, 4*N))
    if schedule === nothing || time() - t0 > timeout_seconds
        # Fall back to Knill recursive segmentation on a serialized chain
        return knill_fallback_schedule(dag, P)
    end

    return schedule
end
```

**Interpreting the schedule.** `schedule::Vector{Set{Int}}` is a sequence
of pebble-sets. For step `i` to `i+1`, the symmetric-difference gives
the pebbles added (allocations) and removed (frees). For our purposes we
want a **slot-assignment table** mapping store-id → tape-slot-id, such
that two stores S_j, S_i with overlapping liveness get different slots.
Post-process:

```julia
function schedule_to_slot_map(schedule, dag)
    # Greedy interval coloring: walk the schedule, assign each
    # pebble-entering-step to the lowest-numbered free slot; release the
    # slot at pebble-leaving-step.
    slot_of = Dict{Int, Int}()  # node_id → tape-slot
    free_slots = Int[]          # min-heap of unused slot numbers
    next_slot = 1
    live = Set{Int}()
    for t in 1:(length(schedule)-1)
        added = setdiff(schedule[t+1], schedule[t])
        removed = setdiff(schedule[t], schedule[t+1])
        # Free slots of pebbles removed
        for node in removed
            push!(free_slots, slot_of[node])
            delete!(live, node)
        end
        # Assign slots to pebbles added
        for node in added
            slot = isempty(free_slots) ? (next_slot += 1; next_slot - 1) : popfirst!(free_slots)
            slot_of[node] = slot
            push!(live, node)
        end
    end
    peak_slots = maximum(values(slot_of))
    return (slot_of, peak_slots)
end
```

Peak slots = peak concurrent pebbles = **the shared tape pool size we
need to allocate**.

### 5.2 Per-width tape pools

Shadow stores have a width `W` per store. Two stores of different widths
cannot share a slot (different wire counts). Solution: partition the DAG
**by element width** before pebbling. Run `sat_pebble` once per distinct
width, allocate one tape pool per width. MD5 uses only W=32, so this is
one pool. SHA-256 compression ditto.

### 5.3 Integration into `lower()`

Add a new planning pass inserted before the instruction walk. Pseudocode:

```julia
function lower(parsed::ParsedIR; ..., use_shadow_checkpoint::Bool=true)
    # Pass 1 — existing liveness, block_pred, etc.
    # ...

    # Pass 1.5 (new) — shadow-checkpoint pre-pass
    if use_shadow_checkpoint
        dag_by_width = build_store_dep_dag(parsed, ptr_provenance, alloca_info, memssa_info)
        slot_maps = Dict{Int, Dict{Int,Int}}()  # W → (store_id → slot)
        pool_sizes = Dict{Int, Int}()            # W → peak-slot count
        for (W, dag) in dag_by_width
            length(dag.nodes) <= 1 && continue  # 1-store case: T3b direct
            schedule = pebble_store_dag(dag)
            slot_of, peak = schedule_to_slot_map(schedule, dag)
            slot_maps[W] = slot_of
            pool_sizes[W] = peak
        end
    else
        slot_maps = Dict(); pool_sizes = Dict()
    end

    # Pass 2 — existing instruction-walk lowering, now with access to
    # `ctx.tape_pools` (pre-allocated shared pools) and
    # `ctx.store_slot_of` (per-store tape slot).

    # ...
end
```

## 6. Schedule consumption — lower_store! / lower_load!

### 6.1 New ctx fields

Extend `LoweringCtx` (additive — new fields with defaults, 13-arg
constructor unchanged for callers that don't use T4):

```julia
struct LoweringCtx
    # ... existing fields ...
    # M3: shadow-checkpoint tape pools, one per element width.
    tape_pools::Dict{Int, Vector{Int}}        # W → allocated wire pool
    # M3: per-store slot-within-pool, keyed by store site-id.
    store_slot_of::Dict{Symbol, Int}          # site_id → slot-index (1-based)
    # M3: per-store "should-reexec-prefix" — if this store's tape slot is
    # reused by a later store, the old value must be recomputed via
    # forward re-execution before the reverse pass can uncompute.
    store_reexec_info::Dict{Symbol, ReexecPlan}
    # M3: total tape-pool wire counts (debug / gate-count accounting).
    tape_peak::Dict{Int, Int}
end
```

### 6.2 Site-id

Each store needs a stable identifier across the planning pass and the
instruction-walk pass. Use `Symbol("store_", inst_idx)` where `inst_idx`
is the global instruction count from `ctx.inst_counter`. The planning
pass assigns site-ids in parsed-IR order; the instruction walk
increments `inst_counter` in lock-step with the planning order.

### 6.3 `_lower_store_via_shadow_pebbled!` — new helper

```julia
function _lower_store_via_shadow_pebbled!(ctx::LoweringCtx, inst::IRStore,
                                          alloca_dest::Symbol, info::Tuple{Int,Int},
                                          idx_op::IROperand, block_label::Symbol)
    elem_w, n = info
    site_id = _store_site_id(ctx, inst)
    arr_wires = ctx.vw[alloca_dest]
    primal_slot = arr_wires[idx_op.value * elem_w + 1 : (idx_op.value + 1) * elem_w]

    # Get pre-assigned tape slot from the planner
    pool = get!(ctx.tape_pools, elem_w) do
        # First touch: allocate the full pool from the wire allocator.
        allocate!(ctx.wa, ctx.tape_peak[elem_w] * elem_w)
    end
    slot_idx = ctx.store_slot_of[site_id]
    tape_slot = pool[(slot_idx - 1) * elem_w + 1 : slot_idx * elem_w]

    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, elem_w)

    if block_label == Symbol("") || block_label == ctx.entry_label
        emit_shadow_store!(ctx.gates, ctx.wa, primal_slot, tape_slot, val_wires, elem_w)
    else
        pred_wires = ctx.block_pred[block_label]
        emit_shadow_store_guarded!(ctx.gates, ctx.wa, primal_slot, tape_slot,
                                   val_wires, elem_w, pred_wires[1])
    end

    # Mark the GateGroup for this store with its pool-pebbling metadata so
    # `bennett_transform.jl` / `pebbled_group_bennett` can honor the
    # pebbled schedule during Bennett forward/reverse.
    _tag_gate_group!(ctx, site_id, slot_idx, elem_w)
    return nothing
end
```

**Critical correctness invariant.** When two stores S_a, S_b share a
tape slot (S_b's pebble evicts S_a's), we must ensure S_a's tape value is
uncomputed before S_b writes its tape. The standard Bennett reverse pass
guarantees this *if* the gate order matches the pebbling schedule. The
orchestrator MUST insert the re-execution gates at the right places —
this is the novel part covered in §7.

### 6.4 `_lower_load_via_shadow!` — unchanged

Loads read from the **primal** (live array), not the tape. The pebbling
never affects primals. `_lower_load_via_shadow!` at `lower.jl:1728` is
untouched. The tape-pool reuse is a pure *reverse-pass* optimization;
forward loads see current primal state uniformly.

## 7. Checkpoint + re-exec emission — the novel part

This is where T4 earns its name. Bennett's construction is
forward + copy-output + reverse. The reverse runs gates in reverse order;
the standard reverse pass assumes every tape slot S_i still holds S_i's
old-primal value when we reach S_i's reverse. **Tape-slot reuse breaks
this assumption.** If S_b reused S_a's slot, by the time we reverse-walk
to S_a, the slot contains S_b's old-primal, not S_a's.

The fix: insert **re-execution of the forward prefix up to S_a** at the
right point in the reverse walk. This is classical Bennett 1989 /
Meuli 2019 recursion.

### 7.1 Worked tiny example — 3 stores, 2-pebble budget

```
Program:
  p = alloca i8, 4
  store S1: p[0] = f(x)
  store S2: p[1] = g(x)         // reads p[0]? no — independent
  store S3: p[0] = h(x, p[1])   // reads p[1]; clobbers S1's slot
  ret p[0]
```

StoreDepDAG:
- nodes: {S1, S2, S3}
- adj: S2 → Ø, S1 → Ø, S3 → [S1 (WAW), S2 (def-use via load of p[1])]
- outputs: [] (all tape slots must be uncomputed by function end)

With 2 pebbles, SAT-pebbling schedule:

```
t=0:  {}        (initial — no pebbles)
t=1:  {S1}      (place S1 — forward S1)
t=2:  {S1,S2}   (place S2)
t=3:  {S2}      (remove S1 — reverse S1, freeing tape slot)
t=4:  {S2,S3}   (place S3 — reuses S1's slot)
t=5:  {S3}      (remove S2 — reverse S2)
t=6:  {}        (remove S3 — reverse S3)
```

Slot assignment:
- S1 → slot 1 at t=1; free at t=3
- S2 → slot 2 at t=2; free at t=5
- S3 → slot 1 at t=4 (reused); free at t=6

### 7.2 Gate emission plan

The pebble schedule above doesn't map 1-to-1 onto Bennett's
forward/reverse bisection. Instead, the forward-computation gates of S1
are emitted at t=1 (pebble place), reversed at t=3 (pebble remove),
re-executed at... never (in a 2-pebble budget for 3 stores, S1's
recompute lives entirely inside the interval [t=1, t=3]). **In the
general case**, un-pebble-then-re-pebble requires *re-executing S1's
forward gates* before the re-pebble, because S1's tape slot is now
holding S3's primal-old-value (not zero).

**Mapping to Bennett's structure.** The emitted gate list for the
worked example is:

```
[F_S1]              // forward S1: p[0] = f(x), tape[slot1] = old_p[0]
[F_S2]              // forward S2: p[1] = g(x), tape[slot2] = old_p[1]
[R_S1]              // reverse S1: tape[slot1] XOR'd back to p[0]; slot1 = 0
                    // Now slot1 is free.
[F_S3]              // forward S3: p[0] = h(x, p[1]), tape[slot1] = f(x)
<copy outputs>
[R_S3]              // reverse S3
[F_S1 again]        // RE-EXECUTE S1 (recomputes f(x) into p[0])
                    // Now slot1's old owner matches the tape.
                    // But wait — tape[slot1] is already zero after R_S3,
                    // so R_S1 needs tape[slot1] = f(x) to XOR back.
                    // We re-execute S1 BEFORE R_S1.
[R_S2]              // reverse S2: uses tape[slot2] (always live in schedule)
[R_S1 again]        // now tape[slot1] = f(x), p[0] = f(x), XOR clears
```

**Hmm — the symmetry is subtle.** Standard Bennett emits forward then
reverse in *reverse order*. For a pebbled/re-executed schedule, the
forward-then-reverse bisection no longer works; each un-pebble pairs
with exactly one forward emission (original or re-exec) and one reverse
emission.

**Existing infrastructure handles this.** `pebbled_group_bennett` in
`src/pebbled_groups.jl` already implements Knill recursive segmentation
with `_replay_forward!` + `_replay_reverse!` + wire reuse. The trick is
to **express the StoreDepDAG-derived schedule as a GateGroup sequence**
so `pebbled_group_bennett` can consume it. Each store is already
wrapped in a GateGroup (via the M2 path: `lower_store!` adds a
GateGroup; see `pebbled_groups.jl:275`). The SAT-pebbling schedule,
post-processing, emits a sequence of (group-id, direction ∈ {forward,
reverse, re-exec-forward}) tuples. The re-exec-forward arm is the only
new primitive — it calls `_replay_forward!` with the same group but
FRESH wire mappings, emitting duplicate forward gates.

### 7.3 Gate-count accounting

For N stores with P-pebble SAT schedule of length K steps:
- Each **place** event → one forward emission (3W CNOT per store,
  or re-exec-forward-of-upstream-gates if the tape-slot was reused).
- Each **remove** event → one reverse emission (3W CNOT per store).

Upper bound: K forward + K reverse emissions = 2K × (3W CNOT + upstream
forward gates). Knill's recursion gives K ≈ N^{log_2 3} ≈ N^{1.585} for
P=log₂N pebbles. For MD5 with ~1,000 total stores (64 rounds × ~16
stores/round), P=10 pebbles, K ≈ 10,000 emissions. **Each "re-exec"
emits the dependency closure of the target store**, not the whole
program — this is the savings.

### 7.4 MD5-specific re-exec analysis

MD5 round-step structure:
```
a_new = b + rotl32(F(b,c,d) + a + k + w, s)
// then rotate: (a,b,c,d) ← (d, a_new, b, c)
```
The "rotate" is done via 4 stores into a state-alloca (a, b, c, d as
Int32 slots). Each round produces 4 stores. Across 64 rounds = 256
stores. Dependency structure: round i's stores read from round i-1's
stores (linear chain of length 64 × 4 = 256 nodes, mostly linear with
4-wide parallel segments).

For a linear chain of 256 nodes with P pebbles:
- P = 256 (full Bennett): 256 forward + 256 reverse = 512 shadow-store
  emissions × 3W CNOT = 512 × 96 = 49,152 CNOT. (Not counting Toff from
  user computation — which is the MD5 F/G/H/I + adds.)
- P = 32 (sqrt(256)): K ≈ 256 × (256/32) = 2,048 emissions. More gates
  but fewer wires.
- P = 9 (log₂256 + 1): K ≈ 256^log₂3 ≈ 1,048 × 3 = 3,144 emissions,
  **but only 9 × 32 = 288 tape wires** vs 256 × 32 = 8,192.

**The MD5 win:** The ReVerC 27,520 Toff comes from Toffoli gates inside
F/G/H/I rounds, NOT from memory-management CNOTs. Our current ~48 kToff
includes round-step overhead from the multi-store-alloca pattern (each
store triggers ~3 × the slot-swap). T4 with pebbling drops the
*ancilla/wire cost* by O(N/P) but doesn't directly reduce Toffoli. The
Toffoli win comes from:
  a) **Avoiding re-computation** via checkpoint_bennett's approach:
     pool-reuse means intermediate state CAN be thrown away by Bennett
     reverse without the full 2×gate overhead when per-group checkpoints
     are shared.
  b) **MemorySSA-driven dead-store elimination**: M2 delivered this (def-
     use graph in hand); M3 consumes it to prune stores whose values are
     never read. SHA-256 and MD5 have many dead schedule stores.
  c) **Guarded-store elision** in M2c: stores on un-reached branches
     still emit Toffolis; T4 + MemorySSA can prune any Def with no Use.

Target accounting:
- ~16 state + 16 schedule Int32 = 32 primal wires × 32 bits = 1,024 wires.
- ~256 stores, SAT-pebbled to P = 16: tape pool = 16 × 32 = 512 wires.
- Net: 1,536 memory wires for full MD5 (pre-Bennett ancillae for round
  computation add on top).
- Round Toffolis from existing bc2_md5.jl: md5_step_F ~ 750 Toff; ×64 ≈
  48,000 Toff. **To hit 27,520 we need to cut round-step Toffoli by 43%.**
  T4 tape-pool doesn't directly do this — but if round-step stores emit
  shadow_store at 3W CNOT / 0 Toff **instead of** being forced through
  some MUX-EXCH-like path, we save Toffoli. Current MD5 round at W=32 on
  static idx already takes T3b (0 Toff). So the 48k number is inflated
  by round-arithmetic Toff, not memory Toff. **T4's MD5 contribution is
  therefore SECONDARY — the primary MD5 win is already present in T3b.**
  The remaining gap is closed by M2 (MemorySSA def-use elimination of
  dead stores) + round-function sharing.

**Conclusion on the budget**: T4 unlocks L10 (memory size) cleanly. For
L11 (MD5), the headline win requires T4 + MemorySSA-driven dead-store
pruning + tape-pool reuse working together. T4 alone won't hit 27,520.

## 8. L11 MD5 harness

### 8.1 Where MD5 code lives

Currently: `benchmark/bc2_md5.jl` compiles only *one round step*, not
the full 64-round compression. **M3 adds `benchmark/bc_md5_full.jl`** —
a new file that compiles the full MD5 block function via `reversible_compile`.

MD5 compression code (Julia reference, to be translated to the
benchmark):
```julia
function md5_compress(state::NTuple{4,UInt32}, block::NTuple{16,UInt32})::NTuple{4,UInt32}
    a, b, c, d = state
    # 64 rounds, grouped in four sets of 16
    # ... K constants, shift constants, F/G/H/I dispatch ...
    # Must be inlined so Julia produces one big LLVM function with
    # constant indexing into K[] and S[] (both become QROM lookups).
    for i in 0:63
        f, g = if i < 16
            md5_F(b, c, d), i
        elseif i < 32
            md5_G(b, c, d), (5i + 1) & 15
        elseif i < 48
            md5_H(b, c, d), (3i + 5) & 15
        else
            md5_I(b, c, d), (7i) & 15
        end
        k = MD5_K[i + 1]
        s = MD5_S[i + 1]
        new_b = b + rotl32(f + a + k + block[g + 1], s)
        a, b, c, d = d, new_b, b, c
    end
    return (a, b, c, d)
end
```

### 8.2 Test harness

```julia
# test/test_md5_full.jl (new file)
@testset "L11 — MD5 full 64-round compression (GREEN, bucket —, M3)" begin
    state = (UInt32(0x67452301), UInt32(0xefcdab89),
             UInt32(0x98badcfe), UInt32(0x10325476))
    block = ntuple(i -> UInt32(i), 16)  # test vector
    expected = md5_compress(state, block)

    c = reversible_compile(md5_compress, typeof(state), typeof(block);
                           optimize=true)
    @test verify_reversibility(c; n_tests=3)

    # Semantic: simulate produces the reference output
    # (Pack state+block into a flat input vector per simulate's contract.)
    got = simulate(c, (state..., block...))
    @test got == expected

    # Gate-count target
    gc = gate_count(c)
    println("  MD5 full 64-round: total=$(gc.total) Toff=$(gc.Toffoli) wires=$(c.n_wires)")
    @test gc.Toffoli <= 27_520  # beats ReVerC 2017 eager
    @test c.n_wires <= 4_769    # and matches their qubit count
end
```

Adopt the benchmark measurement row into `BENCHMARKS.md §Head-to-head`:
```
| MD5 full (64 steps) | <actual> Toff, <actual> wires | 27,520 Toff, 4,769 wires (ReVerC 2017) | <ratio>× |
```

## 9. M2c interaction — path-predicate guarding on pebbled tape slots

**Correctness question**: can two guarded stores share a tape slot?

The M2c invariant (`emit_shadow_store_guarded!` at `shadow_memory.jl:98`):
each CNOT of the 3W pattern becomes a Toffoli(pred, ctrl, tgt). When
pred=0 the Toffoli no-ops; when pred=1 it collapses to the CNOT.
Reverse is self-inverse per-Toffoli.

**Case A — same pred, sequential**: two stores S_a, S_b guarded by the
same `pred`. If they share a tape slot, at runtime (pred=1) S_a writes
tape[slot] = old_primal_a; after reverse, tape[slot] = 0; then S_b
writes tape[slot] = old_primal_b. Fine.

**Case B — mutex preds (if/else)**: S_a under `pred_L`, S_b under
`pred_R`, `pred_L ⊕ pred_R = 1`. At runtime exactly one is taken; the
other's Toffolis no-op. **Crucially, a no-op'd store leaves its tape
slot at zero**, so the reverse pass's Toffoli(pred_*=0, tape_slot=0,
primal) is also no-op. Sharing a slot is safe.

**Case C — overlapping preds (nested if/else)**: `pred_L` = (`cond1 &
cond2`), `pred_M` = (`cond1 & !cond2`). If both stores are in the same
`cond1=1` basin, exactly one fires per run; sharing tape is safe by
Case B reasoning.

**Case D — unrelated preds**: `pred_X` and `pred_Y` are not mutex
(pred_X can be 1 regardless of pred_Y). Then both stores may fire in
one run, and sharing a tape slot is **NOT safe** — S_b would corrupt
S_a's slot before S_a's reverse.

**Rule**: the pebbler must treat stores with non-mutex predicates as
having an implicit edge (they cannot share live-ranges unless their
gate-order already enforces one-before-the-other). Add this to
`build_store_dep_dag`:
```julia
for store_i in stores, store_j in stores
    i == j && continue
    !mutex(pred_i, pred_j) && push!(dag.adj[node_of(j)], node_of(i))
end
```
`mutex(p, q)` — structural: walk the dominator tree, check if one's
block dominates the other's with a branching ancestor whose edges select
both. Straightforward with existing `branch_info` in LoweringCtx.

### 9.1 Guard predicates are write-once

The guard wire is written once in the block prologue, read-only
thereafter. Pebbling the *tape* doesn't affect the guard wire. Guards
are not pebbled — they live in their own dedicated wires allocated by
`_compute_block_pred!`. This is additive: M3 inherits M2c's guard
lifecycle unchanged.

## 10. Fallback to Knill

**When the SAT solver is slow**, fall back to Knill recursion in
`src/pebbling.jl`. Trigger conditions:

1. **Timeout** (default 5s) in `sat_pebble`. The SAT encoding has
   O(N × K × P) variables; for N ≥ ~50 nodes and deep DAGs the SAT call
   can exceed budget. Measured timing: Meuli 2019 reports 52% ancilla
   reduction on benchmarks up to ~100 nodes in seconds; above that it
   can blow up.

2. **DAG size threshold**: `length(dag.nodes) > 128`. Skip SAT, go
   direct to Knill. Knill has exponential time in `n`-pebble search but
   a closed-form DP for `knill_pebble_cost` / `knill_split_point` in
   `src/pebbling.jl:22`.

3. **PicoSAT unavailable**: `using PicoSAT` already imported at
   `sat_pebbling.jl:14`. If the solver is unhealthy (e.g. on an
   unsupported platform), rescue via Knill.

Knill recursion is already wired into `pebbled_group_bennett`
(`pebbled_groups.jl:273`) — T4 can lean on it for the fallback case
by simply emitting ungated GateGroups for each store and calling
`pebbled_group_bennett` with the right `max_pebbles` budget.

```julia
function knill_fallback_schedule(dag::StoreDepDAG, P::Int)
    # Serialize the DAG into a chain (topological sort), then apply
    # Knill recursive segmentation. This over-approximates (the chain
    # has more dependencies than the DAG) so P may need to be larger.
    chain = topo_sort(dag.adj)
    N = length(chain)
    P_knill = max(P, min_pebbles(N))
    # Generate the same Set{Int} schedule as sat_pebble, but via Knill
    # recursion. Details: walk knill_split_point(N, P_knill), emit
    # alternating place/remove events.
    return _knill_emit_schedule(chain, P_knill)
end
```

## 11. Cost estimate

| File | Change | LoC |
|------|--------|-----|
| `src/shadow_checkpoint.jl` | NEW. `StoreNode`, `StoreDepDAG`, `build_store_dep_dag`, `pebble_store_dag`, `schedule_to_slot_map`, `_lower_store_via_shadow_pebbled!`, `knill_fallback_schedule`. | ~450 |
| `src/lower.jl` | Extend `LoweringCtx` with tape_pools, store_slot_of, store_reexec_info, tape_peak. Extend `_pick_alloca_strategy` (add `:shadow_pebbled`). Add dispatch branch in `_lower_store_via_shadow!` → `_lower_store_via_shadow_pebbled!` when strategy is `:shadow_pebbled`. Insert Pass 1.5 (planning) into `lower()`. | +80, modified ~30 |
| `src/Bennett.jl` | `include("shadow_checkpoint.jl")` after `include("shadow_memory.jl")`. | +1 |
| `src/bennett_transform.jl` | Add a new `pebbled_shadow_bennett(lr)` path that consumes `lr.gate_groups` + `lr.shadow_pebble_schedule` (to be added to LoweringResult) to emit a schedule-aware forward/reverse. **Optionally reuse `checkpoint_bennett` + `pebbled_group_bennett` if their existing replay logic handles tape-slot GateGroups cleanly.** (see §7.2 for why this is likely) | +60 |
| `src/lower.jl` LoweringResult | Add `shadow_pebble_schedule::Union{Nothing, Vector{Set{Int}}}` field (defaulted nothing for backward-compat). | +5 |
| `test/test_shadow_checkpoint.jl` | NEW — unit tests for StoreDepDAG construction, schedule_to_slot_map correctness, SAT pebble small DAGs, fallback to Knill triggers on size/timeout. | ~250 |
| `test/test_memory_corpus.jl` | Flip L10 from `@test_throws` to `@test` + sweep. Add L11 line noting benchmark lives in bc_md5_full.jl. | +30 |
| `test/test_md5_full.jl` | NEW — L11 semantic + gate-count test per §8.2. | ~80 |
| `benchmark/bc_md5_full.jl` | NEW — full MD5 64-round compile, gate-count table, head-to-head vs ReVerC row. | ~150 |
| `BENCHMARKS.md` | Update `§Head-to-head` with MD5 full row; add `§Memory primitives — T4 shadow-checkpoint` section. | +40 |
| `docs/memory/shadow_checkpoint_implementation.md` | NEW — M3 implementation notes per PRD deliverable. | ~200 |
| `WORKLOG.md` | Session entry per CLAUDE.md rule 0. | +60 |

**Grand total: ~1,400 LoC across ~10 files.** Matches PRD §10 M3 "~2-3
weeks". The `@eval`-heavy parts are small; the bulk is `shadow_checkpoint.jl`
and the bennett_transform wiring.

## 12. Risks

### R1 — SAT solver performance on MD5-scale DAGs

**Risk**: PicoSAT chokes on 256-node DAGs with P ≥ 10 pebbles.
Meuli 2019 tests top out at ~100 nodes with reasonable wallclock.

**Mitigation**:
- Timeout-then-Knill fallback (§10).
- Solve the pebbling problem *per width-partition*: MD5 has ~256 W=32
  stores; split into 4 round-groups of 64 (mutex + independent via
  the state-rotation pattern) for smaller SAT instances.
- Cache schedules: if the same function is compiled twice (common in
  JIT-style dev workflows), memoize by IR hash.

### R2 — Schedule-consumption bug from site-id drift

**Risk**: the planning pass assigns site-ids based on parsed-IR
iteration order; the instruction walk must iterate in the same order,
or slot-assignments mismatch silently. A phi resolution change that
reorders blocks could desync.

**Mitigation**:
- Use `ctx.inst_counter` as the shared cursor. Planning pass reads it;
  instruction walk increments it. Assert `inst_counter[] == expected_id`
  in `_lower_store_via_shadow_pebbled!`.
- Regression test that pins site-id assignment for a known IR.
- Fail-fast if the lookup misses: `error("_lower_store_via_shadow_pebbled!: no slot assignment for site_id=$site_id — planning pass / walk order desync")`.

### R3 — Re-exec correctness: forward gates mutate input wires

**Risk**: some forward groups mutate their input wires (Cuccaro in-place
adder — already flagged in `pebbled_groups.jl:239–265` as a fallback
trigger). Re-executing such a group twice corrupts state.

**Mitigation**:
- **This is the exact same issue pebbled_group_bennett already handles.**
  It falls back to `bennett(lr)` when in-place results are detected
  (`pebbled_groups.jl:282`). T4 inherits this. If MD5 uses any
  in-place adder, T4 degrades to no-tape-reuse (full-tape T3b).
- Forbid re-exec through Cuccaro groups in `pebble_store_dag`: any
  GateGroup flagged `in_place` becomes a single un-divisible atom;
  pebbling treats it as P=1 at its boundaries.

### R4 — Interaction with `gate_group` tracking

**Risk**: M3 adds a new layer of GateGroups for each shadow store. These
GateGroups now have tape-slot metadata. `pebbled_group_bennett`'s
existing `_replay_forward!` doesn't know about tape slots.

**Mitigation**:
- Extend `GateGroup` with an optional `tape_slot::Int = 0` field.
  `_replay_forward!` checks this: if nonzero, the *tape-slot portion*
  of the group's wire range is NOT part of the group's ancilla pool —
  it's shared via `ctx.tape_pools`. This is additive to the existing
  struct.
- Key property: tape slots are **shared wires**, not group-private
  ancillae. `_replay_reverse!` must NOT `free!` tape-slot wires. Flag
  this explicitly in GateGroup, or return `shared_wires::Vector{Int}`
  from `_replay_forward!`.
- Regression test: run `checkpoint_bennett` on a T4 function and verify
  wire-count accounting matches hand-traced math.

### R5 — Dominance-violating tape sharing (CLAUDE.md §"Phi Resolution")

**Risk**: the same phi false-path sensitization failure mode warned of
in CLAUDE.md. If two stores in diamond-CFG branches share a tape slot,
and the pebbler schedules them in the "both live" region, a guard
collapse could XOR a non-zero value into a slot that should be zero
under the inactive branch.

**Mitigation**:
- §9's mutex rule: non-mutex-guarded stores get forced into a pebbling
  dependency, so they never overlap live-range.
- Diamond-CFG test in the corpus (L7 already exists; add L7g with
  multiple conditional stores sharing pebble pool).
- Verify `verify_reversibility` passes for **all** corpus levels after
  T4 lands — not just L10/L11.

### R6 — Gate-count regression on existing corpus

**Risk**: activating T4 by default (`:shadow_pebbled`) changes
gate counts for L0, L1, L7a–L7f, SHA-256, and every soft-float
baseline that uses static-idx stores.

**Mitigation**:
- `:shadow_pebbled` fires only when `store_count >= 4` AND a net
  benefit is demonstrable. For ≤ 3 static stores, stay on T3b (tape
  pool = store_count, no reuse possible anyway).
- Pin core arithmetic gate counts in CI per CLAUDE.md §6. Any T4-
  triggered regression on `x+1` or `soft_fma` fails the build.
- MD5 + L10 measured against `@test`-hardcoded budgets.

### R7 — Debug complexity

**Risk**: the interaction between planning pass, site-id assignment,
instruction walk, GateGroup tracking, and pebbled Bennett is hard to
debug in isolation.

**Mitigation**:
- Instrumentation flag: `BENNETT_DEBUG_SHADOW_CHECKPOINT=1` emits the
  planning schedule as a human-readable table (one row per store,
  columns: site-id, alloca, idx, W, tape-slot, pebble-place-step,
  pebble-remove-step, re-exec-count).
- Dump the DAG as DOT before and after pebbling (small, easy to visualize).
- Hand-traceable worked example in `docs/memory/shadow_checkpoint_implementation.md`
  using the §7.1 3-store function.

---

**Ready for orchestrator review.** Note explicitly: the MD5 27,520
target is likely NOT achievable by T4 alone — see §7.4. Hitting that
headline requires T4 + MemorySSA dead-store elimination (M2 consumer
wiring) + round-function callee-sharing together. If the orchestrator
judges that out of M3 scope, MD5 should be classified as an "M4
integration milestone" and M3's gate-count acceptance criterion should
be "L10 under budget + no regression on SHA-256 Toff". Flag this before
implementation starts.
