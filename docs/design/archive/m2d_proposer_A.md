# M2d — MUX-store path-predicate guarding (Proposer A)

**Issue**: Bennett-i2a6  
**Sibling**: Bennett-oio4 (M2c, shadow-path guarding) — closed.  
**Test pin**: `test/test_memory_corpus.jl` L7f (`@test_broken`).  
**Scope of this doc**: design only. No source edits.

---

## 1. One-line recommendation

At each `_lower_store_via_mux_NxW!` call site, for non-entry blocks: snapshot
the primal packed wires into a fresh tape slot, run the existing unguarded
`soft_mux_store_NxW` `IRCall` as today, then rebind the primal symbol via
`lower_mux!(block_pred_wire, new_state, snapshot)` so that pred=0 restores the
pre-store state bit-for-bit. Keep the callees (and therefore every MUX EXCH
baseline) untouched; entry-block stores take an unchanged unguarded path.

---

## 2. Root cause — where and why the MUX-store path is unguarded

### Location

`src/lower.jl`:

- `_lower_store_via_mux_4x8!`  — lines 2188–2212
- `_lower_store_via_mux_8x8!`  — lines 2214–2238
- `@eval`-generated parametric variants for (2,8), (2,16), (4,16), (2,32) —
  lines 2247–2309 (the generated `$store_fn` definition is 2283–2307).

All six variants share the same six-line shape (elided):

```julia
ctx.vw[arr_sym] = _wires_to_u64!(ctx, arr_wires)       # pack primal → 64 wires
ctx.vw[idx_sym] = _operand_to_u64!(ctx, idx_op)        # zext idx → 64 wires
ctx.vw[val_sym] = _operand_to_u64!(ctx, inst.val)      # zext val → 64 wires
call = IRCall(res_sym, soft_mux_store_NxW, ...)
lower_call!(...; compact=ctx.compact_calls)            # inline callee forward gates
ctx.vw[alloca_dest] = ctx.vw[res_sym][1:packed_bits]   # rebind primal to new state
```

The `IRCall` is emitted **unconditionally**. Nothing in the `arr_sym`, `idx_sym`,
`val_sym`, `res_sym` construction references `ctx.block_pred[block_label]`.
Whether or not the block's predicate is 1 at runtime, the callee gates fire and
`ctx.vw[alloca_dest]` is re-pointed to the callee's output. L7f proves this:
with `%c = false` the inactive `%L` block's store still mutates state.

### Why M2c's Toffoli-substitution trick does not transplant

M2c fixed the shadow-path bug (`emit_shadow_store_guarded!`) by a
gate-local trick: the pattern is exactly 3·W CNOTs of the form `CNOT(ctrl, tgt)`,
and each one becomes `Toffoli(pred, ctrl, tgt)`. With pred=0 every Toffoli is
identity; with pred=1 each collapses to the original CNOT. The whole pattern
stays pure-CNOT-on-pred=1 / pure-no-op-on-pred=0 and Bennett reverse unwinds
symmetrically because `pred` is write-once.

The MUX-store path has no such structural invariance:

1. `soft_mux_store_NxW` is a **callee** inlined via `lower_call!`. Its gates
   are thousands of CNOT+Toffoli in arbitrary topology — unpack/extract,
   branchless `ifelse`, re-pack, XOR merge. There is no pattern of single
   CNOTs to promote to Toffolis.
2. Even if we hooked `lower_call!` to rewrite every `CNOT(a,b) → Toffoli(pred,a,b)`
   and every `Toffoli(a,b,c) → 4-gate decomp-of-gate-under-guard`, we would
   (a) perturb every MUX EXCH baseline (7,122 → much larger), violating
   CLAUDE.md §6, and (b) need 4-operand AND-gates to guard Toffolis, which
   our gate set does not have (we would synthesize via additional ancillae
   and Toffoli decomposition — costly and error-prone).
3. Even guarding every emitted gate, the **re-pack** step is lossy: when
   pred=0 we want `arr` restored to its pre-store value, but pred=0 only
   stops writes, it does not restore reads. The callee reads `arr`, `idx`,
   `val` via CNOT-copies *before* the guard would bite, and then XORs a
   result back. Gating every write does not prevent an incorrect rebind
   of `ctx.vw[alloca_dest]` onto a "result" wire that — at pred=0 — holds
   some partial computation, not the old primal.

The cleanest fix respects the callee as a semantic black box: let it run,
capture the state before it ran, and overlay a MUX at the end. This is
Design A (the recommended design).

---

## 3. Design — snapshot + MUX at the lower site

### What gets snapshot

The **pre-call primal wires** — `arr_wires = ctx.vw[alloca_dest]` as read at
line 2192 / 2218 / 2287 (i.e. the N·W bit-packed unary representation of the
alloca, not the 64-wire `arr_sym` u64 copy and not the `res_sym` post-call
wires).

Rationale:

- The packed `arr_sym` is already a CNOT-copy into 64 fresh wires; it is no
  cheaper to re-snapshot from the same source.
- The primal wires `ctx.vw[alloca_dest]` hold the canonical state the
  downstream loaders see. Snapshotting them guarantees that the MUX output
  at the end is a drop-in replacement — we rebind `ctx.vw[alloca_dest]` to
  the MUX's output wires and no other code site needs to know anything
  changed.
- Snapshot cost is N·W CNOTs (one per primal wire), independent of callee
  internals.

### Where the snapshot lives post-call

On a fresh `snap_wires = allocate!(ctx.wa, N*W)` block. These are ancilla
wires in the outer LoweringResult. After Bennett reverse fires (reversing
the forward gate list), the snapshot wires return to zero because every
gate writing to them is its own inverse and gets replayed in reverse order.
Bennett does not need to know anything special — it already handles
arbitrary ancilla-producing gate sequences.

### How MUX is emitted

Reuse `lower_mux!(gates, wa, cond, tv, fv, W)` (src/lower.jl:1380).
Signature: `r = MUX(cond=1 ? tv : fv)`. Allocates `W` output wires + `W`
scratch `diff` wires per W-bit slice.

For MUX-store N·W ≤ 64, one call: `lower_mux!(g, wa, [pred_wire], new_wires,
snap_wires, N*W)` where:

- `pred_wire = ctx.block_pred[block_label][1]` — the guard wire.
- `tv = new_wires = ctx.vw[res_sym][1:N*W]` — the post-call "with-write" state.
- `fv = snap_wires` — the pre-call "no-write" state.
- Output wires get assigned to `ctx.vw[alloca_dest]`.

Cost per guarded store: **N·W CNOT (snapshot) + 2·N·W CNOT + N·W Toffoli (MUX)**.

Breakdown of `lower_mux!`'s W-bit gate pattern (lines 1383–1388, per output bit):

```
CNOT(fv[i], r[i])          # r[i] = fv[i]
CNOT(tv[i], diff[i])       # diff[i] = tv[i]
CNOT(fv[i], diff[i])       # diff[i] = tv[i] XOR fv[i]
Toffoli(cond, diff[i], r[i])  # r[i] = fv[i] XOR cond*(tv XOR fv)  = cond ? tv : fv
```

So for N·W=32 (4x8 case), added gates are:

- Snapshot:  32 CNOT
- MUX:       3·32 = 96 CNOT + 32 Toffoli

**Total overhead over an unguarded 4x8 store: 128 CNOT + 32 Toffoli.**

(The proposer-brief said "+32 CNOT + 64 Toffoli" — that was the rough estimate.
My count below is more precise because `lower_mux!` uses CNOT-dominated rather
than Toffoli-dominated mux — only the final combine-with-guard is Toffoli.)

### Concrete diff sketch

I introduce **one** new helper and a **one-line routing switch** at each of
the six MUX-store sites. The parametric `@eval` loop absorbs the switch into
the generated body; the hand-written 4x8 and 8x8 variants each get the same
three-line insertion.

```julia
# src/lower.jl — NEW helper, placed immediately before _lower_store_via_mux_4x8!

"""
    _emit_mux_store_guarded!(ctx, inst, alloca_dest, idx_op, block_label, callee) -> Nothing

M2d — snapshot + MUX guard wrapper around the existing soft_mux_store_NxW
callees. Entry blocks route through the unguarded wrapper instead
(preserves every MUX EXCH gate-count baseline).

Shape:
  1. Snapshot primal wires into fresh ancillae.
  2. Invoke the unguarded callee exactly as today (rebinds ctx.vw[alloca_dest]
     to the res_sym[1:packed_bits] slice).
  3. MUX(block_pred, new_wires, snap_wires) → rebind ctx.vw[alloca_dest] to
     the MUX output.
"""
function _emit_mux_store_guarded!(unguarded::Function,
                                  ctx::LoweringCtx, inst::IRStore,
                                  alloca_dest::Symbol, idx_op::IROperand,
                                  block_label::Symbol, packed_bits::Int)
    # Entry (or sentinel) → unchanged path. Baselines preserved.
    if block_label == Symbol("") || block_label == ctx.entry_label
        return unguarded(ctx, inst, alloca_dest, idx_op)
    end

    # Non-entry path: snapshot, run, MUX.
    pred_wires = get(ctx.block_pred, block_label, Int[])
    length(pred_wires) == 1 ||
        error("_emit_mux_store_guarded!: expected single-wire predicate " *
              "for block $block_label, got $(length(pred_wires)) wires")
    pred_wire = pred_wires[1]

    primal = ctx.vw[alloca_dest]
    length(primal) == packed_bits ||
        error("_emit_mux_store_guarded!: primal wires for $alloca_dest have " *
              "$(length(primal)) bits, expected $packed_bits")

    # 1. Snapshot.
    snap = allocate!(ctx.wa, packed_bits)
    for i in 1:packed_bits
        push!(ctx.gates, CNOTGate(primal[i], snap[i]))
    end

    # 2. Run the unguarded callee (rebinds ctx.vw[alloca_dest] = res[1:packed_bits]).
    unguarded(ctx, inst, alloca_dest, idx_op)
    new_wires = ctx.vw[alloca_dest]
    length(new_wires) == packed_bits ||
        error("_emit_mux_store_guarded!: post-call primal width drift " *
              "(got $(length(new_wires)), expected $packed_bits)")

    # 3. MUX — pred=1 chooses new_wires, pred=0 chooses snap.
    muxed = lower_mux!(ctx.gates, ctx.wa, [pred_wire], new_wires, snap, packed_bits)
    ctx.vw[alloca_dest] = muxed
    return nothing
end
```

Routing at the dispatcher (`_lower_store_single_origin!`, lines 2093–2109
today). M2c threaded `block_label` into the shadow call; M2d must do the same
for the MUX calls:

```julia
# BEFORE (today)
elseif strategy == :mux_exch_4x8
    _lower_store_via_mux_4x8!(ctx, inst, alloca_dest, idx_op)

# AFTER
elseif strategy == :mux_exch_4x8
    _emit_mux_store_guarded!(_lower_store_via_mux_4x8!, ctx, inst,
                             alloca_dest, idx_op, block_label, 32)
```

And likewise for `:mux_exch_2x8`, `:mux_exch_8x8`, `:mux_exch_2x16`,
`:mux_exch_4x16`, `:mux_exch_2x32` with `packed_bits` = 16, 64, 32, 64, 64
respectively.

**No change is needed inside `_lower_store_via_mux_4x8!` / `_lower_store_via_mux_8x8!`
/ the `@eval` loop.** They keep their current unguarded behaviour and simply
become the `unguarded` argument of the new wrapper. This is what preserves the
MUX EXCH baselines: when entry-block stores dispatch through the wrapper, the
wrapper's first branch calls the unguarded variant directly and emits zero
extra gates.

### Alternative considered: reuse snapshot slot across Bennett passes

The snapshot slot is allocated via `allocate!(ctx.wa, packed_bits)` — a
fresh ancilla block, not reused. Bennett's reverse pass will unwind the
snapshot CNOTs automatically, so the slot is zeroed at the end of `bennett()`.
No manual cleanup required.

One could be tempted to reuse the shadow-store tape machinery here, but
that is a mis-match: shadow tape stores one element's worth of bits,
while MUX-store snapshot needs the whole N·W packed-array state.
Keeping the allocations separate is clearer and leaves the shadow
tape ownership model intact.

---

## 4. Entry-block bypass — baseline preservation

M2c's routing rule: `block_label == Symbol("")` (direct-caller sentinel) or
`block_label == ctx.entry_label` → unguarded path.

M2d adopts exactly this rule in `_emit_mux_store_guarded!`. For any function
whose stores all live in the entry block, every MUX store fires through
the legacy unguarded call with zero additional gates, exactly matching
today's BENCHMARKS.md numbers:

| Callee               | Current gates | After M2d (entry block) | After M2d (non-entry) |
|----------------------|---------------|-------------------------|------------------------|
| soft_mux_store_2x8   | 3,408         | 3,408 (unchanged)       | 3,408 + 16 + 48 CNOT + 16 Toff |
| soft_mux_store_4x8   | 7,122         | 7,122 (unchanged)       | 7,122 + 32 + 96 CNOT + 32 Toff |
| soft_mux_store_8x8   | 14,026        | 14,026 (unchanged)      | 14,026 + 64 + 192 CNOT + 64 Toff |
| soft_mux_store_2x16  | 3,424         | 3,424 (unchanged)       | 3,424 + 32 + 96 CNOT + 32 Toff |
| soft_mux_store_4x16  | 6,850         | 6,850 (unchanged)       | 6,850 + 64 + 192 CNOT + 64 Toff |
| soft_mux_store_2x32  | 3,072         | 3,072 (unchanged)       | 3,072 + 64 + 192 CNOT + 64 Toff |

Load variants (3,408 / 7,514 / 9,590 / 1,472 / 4,192) are untouched — M2d
only touches the store path.

All BENCHMARKS.md arithmetic baselines (i8 adder 100, i16 204, i32 412,
i64 828, soft_fma 447,728, soft_exp_julia 3,485,262, Shadow W=8 = 24 CNOT)
are byte-identical because none of those tests contain a non-entry-block
MUX store.

---

## 5. Bennett reversibility argument

### Forward gate order inside a guarded store

```
[G1]  snapshot[i] ← primal[i]              (N·W CNOTs)
[G2]  (callee gates inlined: soft_mux_store_NxW forward sequence ≈ several thousand gates)
       — internally allocates u64-pack wires, writes res_sym, leaves intermediate
         state on ancillae; rebinds ctx.vw[alloca_dest] := res_sym[1:packed_bits]
[G3]  MUX gates (lower_mux!):
       For each i in 1..packed_bits:
         CNOT(snap[i], muxed[i])           # muxed[i] := snap[i]
         CNOT(new[i],  diff[i])
         CNOT(snap[i], diff[i])            # diff[i] := new XOR snap
         Toffoli(pred, diff[i], muxed[i])  # muxed[i] := pred ? new : snap
[rebind] ctx.vw[alloca_dest] := muxed
```

### Reverse gate order (Bennett)

Bennett's `bennett()` builds `all_gates = forward ++ copy-out ++ reverse(forward)`
(src/bennett_transform.jl:40–46). The reverse pass plays every forward gate
backward, in reverse order. NOT, CNOT, Toffoli are all involutions, so each
gate is its own inverse.

- The MUX gates unwind first (in reverse order). At pred=1: `muxed` was
  `new`, `diff` was `new XOR snap`; reverse zeros diff and muxed. At pred=0:
  `muxed` was `snap`, `diff` was `new XOR snap`; reverse zeros diff and
  muxed. Both paths end with `muxed = 0`, `diff = 0` (the scratch wires are
  properly cleaned).
- The callee gates unwind next, restoring all packer/unpacker ancillae and
  `res_sym`'s wires to zero. Specifically the res_sym wires that we formerly
  bound to `alloca_dest` are zero after reverse; this is where the M2c
  argument applies — same inputs (arr, idx, val) re-entered in reverse,
  same callee body, invertibility is structural.
- The snapshot CNOTs (G1) unwind last: each `CNOT(primal[i], snap[i])` is
  its own inverse. Since `primal[i]` has since been mutated by the callee
  forward (which wrote into res_sym, not primal — the original primal wires
  are untouched by the callee, they are only CNOT-copied into arr_sym) the
  reverse sees the same primal values and zeros snap.

### Critical: primal wires are immutable during a guarded store

The callee never writes to `primal = ctx.vw[alloca_dest]` pre-call — it
writes to `arr_sym` (a fresh u64 copy) and returns on `res_sym`. The only
mutation of `primal` would be the final `ctx.vw[alloca_dest] = ...` rebind,
which is a symbol-table rewrite, not a gate emission. Therefore:

- Forward: snapshot CNOT reads primal (stable); callee ignores primal;
  MUX reads snap and new — never primal; primal's wires remain exactly
  what they were before the store.
- Reverse: snapshot CNOTs read the same primal values; snap wires zero out.

The original primal wires are left untouched across the whole
forward+reverse pair. This is the key invariant that makes the
reversibility argument clean: **we never mutate primal; we just rebind
which wires the next load will read from**. Bennett's reverse cleans up
the *ancillae* (snap, new, diff, and everything inside the callee)
because every gate targeting them is played backward. The primal wires
themselves are the function's alloca slab — they are not ancillae and
are not touched.

### Reverse-order sensitivity

Reverse order matters for ancilla cleanup only. The forward order I
proposed is:

```
snapshot → call → MUX
```

so reverse is:

```
MUX_rev → call_rev → snapshot_rev
```

This is the **correct** order because:

- MUX_rev needs `snap`, `new`, and `pred` to be in their forward-final
  values — they are, because call_rev has not fired yet and `pred` is
  write-once (block-prologue wire).
- call_rev needs `arr_sym`, `idx_sym`, `val_sym` in their forward-final
  state — MUX_rev does not touch these wires (MUX operates only on
  `snap`, `new`, `diff`, `muxed`), so call_rev sees identical inputs
  and cleans res_sym / arr_sym / idx_sym / val_sym correctly.
- snapshot_rev needs `primal` to still hold its original value — it does,
  because neither call_rev nor MUX_rev wrote to primal.

If I reversed the snapshot/call order (call first, snapshot second), the
snapshot would snapshot post-store state, defeating the purpose. If I put
MUX in the middle of the call, I would need to slice `ctx.vw[alloca_dest]`
mid-call with no rebind target. Only the **snapshot → call → MUX** order
works; it is naturally imposed by the data flow.

### Predicate wire write-once property (inherited from M2c)

`pred_wire` is established in the block's prologue via `_compute_block_pred!`
(src/lower.jl:823–845). It is read-only thereafter within the block.
Bennett's reverse pass reads `pred_wire` again during Toffoli replay, and
it still holds the same value — this is what makes the M2c Toffoli guard
work and is inherited verbatim by the MUX here.

---

## 6. Gate-count estimate for L7f

L7f IR:

```llvm
define i8 @f(i8 %x, i8 %i, i1 %c) {
top: %p = alloca i8, i32 4; br i1 %c, label %L, label %R
L:   %idx = zext i8 %i to i32; %g = gep i8, ptr %p, i32 %idx
     store i8 %x, ptr %g; br label %J
R:   br label %J
J:   %gr = gep i8, ptr %p, i32 0; %v = load i8, ptr %gr; ret i8 %v
}
```

Shape: (N=4, W=8) alloca → strategy `:mux_exch_4x8`. The store sits in
block `%L`, which is *not* the entry block.

Forward gate count for the guarded MUX store (M2d):

| Component                                     | Gates |
|-----------------------------------------------|-------|
| Snapshot (4·8 = 32 CNOT)                      | 32    |
| `soft_mux_store_4x8` callee forward           | 2,040 CNOT + 337 Toff = 2,377 baseline fwd (from BENCHMARKS: 7,122 total is Bennett-wrapped; forward-only ≈ 1/2, i.e. ≈3,561 — more precisely the wrapped 7,122 includes forward + copy-out + reverse) |
| `lower_mux!` for 32 bits                      | 3·32 CNOT + 32 Toff = 128 |
| **Total forward**                             | 32 + fwd(4x8) + 128 |

Bennett wrap of the whole compiled function doubles forward and adds a
copy-out CNOT for each output bit (8), so the forward+reverse+copy of
the top-level circuit is approximately:

`2 · (forward_total) + 8`

Concretely, the unguarded L7f today (today's broken behavior) compiles
to approximately the 4x8 baseline wrapping (7,122) plus a few framing
gates for the alloca zeroing, the `zext`, the load, the return-MUX, and
the block-predicate wire — but critically **no** snapshot/MUX overhead.

Under M2d, L7f adds:
- Forward overhead: 32 + 128 = 160 gates (128 CNOT + 32 Toff)
- Reverse mirrors forward: +160 gates (128 CNOT + 32 Toff)
- No new copy-out gates (MUX output wires are not in the top-level
  output set — only `ret i8 %v` is, which is 8 wires from the
  load's CNOT copy).

**Total M2d overhead per guarded 4x8 store (Bennett-wrapped): 320 extra
gates (256 CNOT + 64 Toffoli).**

Per-shape overhead summary (Bennett-wrapped, forward+reverse):

| Shape | N·W  | Snap+MUX fwd | ×2 for rev  | Notes                              |
|-------|------|--------------|--------------|------------------------------------|
| 2x8   | 16   | 16+48 C + 16 T = 80 | 160         | L7f-analog at width 2              |
| 4x8   | 32   | 32+96 C + 32 T = 160 | **320**     | **L7f target**                     |
| 8x8   | 64   | 64+192 C + 64 T = 320 | 640         |                                    |
| 2x16  | 32   | 32+96 C + 32 T = 160 | 320         |                                    |
| 4x16  | 64   | 64+192 C + 64 T = 320 | 640         |                                    |
| 2x32  | 64   | 64+192 C + 64 T = 320 | 640         |                                    |

These overheads only apply to **non-entry-block** MUX stores. All tests
that store in the entry block (the current MUX EXCH workload) see zero
change.

---

## 7. Interaction with M2b multi-origin

M2b (Bennett-tzb7) handles multi-origin pointers via fan-out in
`lower_store!` (src/lower.jl:2062–2077). Critically, for multi-origin:

```julia
strategy = _pick_alloca_strategy(info, o.idx_op)
strategy == :shadow ||
    error("lower_store!: multi-origin ptr with dynamic idx (origin=$(o.alloca_dest), " *
          "strategy=$strategy) is NYI; file follow-up bd issue for multi-origin MUX EXCH")
```

So **today, multi-origin × dynamic-idx is an explicit error** — the fan-out
code path never reaches the MUX-store helpers. M2d does not need to
interact with multi-origin; it only touches the single-origin dynamic-idx
dispatch.

### If multi-origin × dynamic-idx is lifted later

Suppose a future M2e lifts the error and wants fan-out to dispatch MUX-store
per origin. Then for each origin:

- `origin.predicate_wire` is the path predicate for that origin.
- The correct guard for the MUX-store is `AND(block_pred[block], origin.predicate_wire)`,
  not just `block_pred[block]`.

M2d as designed passes only `block_label` to the wrapper, and the wrapper
looks up `ctx.block_pred[block_label][1]`. To support multi-origin fan-out,
one would extend the wrapper to accept an **explicit pred wire** (like
`_emit_store_via_shadow_guarded!` does — see line 2122 which takes
`pred_wire::Int` directly). The design is compositional: today's M2d takes
the block predicate; M2e can AND it with the origin predicate before
passing.

I will NOT implement M2e. M2d keeps the explicit error for multi-origin ×
dynamic-idx and only fixes the single-origin case.

---

## 8. Risks / failure modes

### False-path sensitization (CLAUDE.md §Phi Resolution warning)

The wrapper gates all mutation on `block_pred[block_label][1]`. This wire
is computed by `_compute_block_pred!`, which recursively ANDs dominating
branch conditions (src/lower.jl:823–845). As long as that function is
correct — which M2c already relies on for the shadow path — the MUX-store
guard cannot fire on a false path. No new risk introduced here.

Specifically: M2c's argument carries over. If `_compute_block_pred!`
returns a correct AND-chain predicate that is 1 iff the block executes
at runtime, then the MUX output matches the shadow-store output
semantically (both are `cond ? new : old`). The only difference is
*which* "cond" wire is used — the same block_pred wire in both cases.

### Ancilla hygiene

New ancillae: `snap` (N·W wires), `muxed` (N·W, from `lower_mux!`),
`diff` (N·W, from `lower_mux!`). Bennett reverse zeroes all three
classes of wires. No leaks.

Potential issue: the callee itself (`lower_call!`, non-compact mode)
inlines forward gates only, relying on the outer Bennett reverse to
clean up. `lower_call!`'s inlined wires — arr_sym, idx_sym, val_sym,
and all res_sym bits *above* `packed_bits` (if any) — must all be
cleaned by the top-level Bennett reverse. This is identical to today's
unguarded MUX-store; M2d does not introduce new ancilla leakage.

`verify_reversibility` in L7f must pass: the test harness sweeps all
input combinations and asserts ancillae return to zero after
forward+reverse. If my design is correct, this passes automatically
because every new gate I emit is involutary.

### Ancilla-counter drift between forward and reverse

Concern: if the forward path allocates `snap` wires but the reverse
path (built by `bennett()` as `reverse(forward)`) does not "un-allocate"
them, does the circuit reference wires that are never freed?

Answer: **no drift risk.** `wire_count` is a forward-only counter. Bennett
emits forward gates, then reverse-order forward gates — no new allocations
during reverse. The snap wires stay allocated for the whole circuit;
they just happen to be zero at the end because the snapshot CNOTs are
played back. This is how every other ancilla in the codebase works,
including M2c's tape slot.

### Pred-wire flipping by callee

I need to confirm: does `soft_mux_store_NxW` ever touch `pred_wire` as
a side effect? The callee is inlined via `lower_call!`, which CNOT-copies
the three args (arr, idx, val) into the callee's input wires and remaps
gates by wire offset. The callee sees only `arr_sym`, `idx_sym`, `val_sym`
(the 64-wire packed copies), never the block predicate. `pred_wire` is
in the **outer** function's wire range, untouched by callee gates.
Confirmed safe.

### Guard wire = 0 semantics for snap rebinding

At pred=0, the MUX output equals `snap`, and we rebind
`ctx.vw[alloca_dest] = muxed`. Subsequent loads read from `muxed`, which
is a CNOT-copy of `snap` at pred=0 and `new` at pred=1. This is exactly
what we want: "if this block did not execute, subsequent loads see the
pre-store state."

But wait — `snap` is itself a CNOT-copy of the old `primal`. When a
downstream load fires, it reads from `muxed` (the newest primal). If
pred=0, `muxed[i] = snap[i] = old_primal[i]`. Correct.

### Ordering with multi-store within the same block

If a block has TWO MUX stores to the same alloca, both guarded:

```
store A: snap_A = primal_0; call_A; primal_1 = MUX(pred, res_A, snap_A)
store B: snap_B = primal_1; call_B; primal_2 = MUX(pred, res_B, snap_B)
```

At runtime pred=1: `primal_2 = res_B(res_A, val_B, idx_B)` — both stores fire.
At runtime pred=0: `primal_2 = snap_B = primal_1 = snap_A = primal_0` —
neither fires. Correct.

No issue — each store's snapshot captures the post-previous-store state,
not the pre-block state, which is the desired sequential semantic.

### Block_pred lookup failure

If `ctx.block_pred` does not contain `block_label` (shouldn't happen —
`lower()` pre-populates it for every block), the wrapper errors with a
clear message. Fail-fast (CLAUDE.md §1).

If `pred_wires` has >1 entry (multi-wire predicate), the wrapper errors —
currently M2c has the same restriction. If this ever fires, AND-reduce
first, same as M2c would. For M2d's scope this is an error.

---

## 9. What I will not do

1. **Modify `soft_mux_store_NxW` callees.** Byte-identical BENCHMARKS.md
   baselines depend on zero callee changes.
2. **Modify `lower_call!`.** The callee-inlining mechanism is shared with
   softfloat and many other callees; no need to perturb it.
3. **Multi-origin dynamic-idx MUX-store.** Deferred; M2b's explicit error
   remains.
4. **Fan-out collapse / MUX tree optimization.** Not in M2d scope.
5. **Fall back to a shadow store for dynamic-idx.** A shadow store for
   dynamic idx would need N parallel Toffoli-guarded CNOT writes per
   element (N·3·W Toffolis) or a QROM + writeback pattern — much more
   expensive and a semantic change. Out of scope.
6. **Add a new `soft_mux_store_guarded_NxW` callee.** The alternative
   design would move the guard into the Julia callee as an `ifelse(pred,
   new_state, old_state)`. That perturbs the callee's gate pattern and
   the BENCHMARKS.md baselines. Rejected — violates the "keep callees
   untouched" directive in the proposer brief.
7. **Refactor the parametric `@eval` loop.** The existing generated
   variants keep their bodies; the `@eval` loop's `store_fn` still
   dispatches identically. M2d only changes the caller (the dispatcher in
   `_lower_store_single_origin!`).

---

## 10. Cost estimate

### Lines changed in `src/lower.jl`

- **Added**: one helper `_emit_mux_store_guarded!`, ~40 lines (including
  the docstring).
- **Modified**: six call sites in `_lower_store_single_origin!`
  (lines ~2095–2106). Each changes from a direct call
  `_lower_store_via_mux_NxW!(ctx, inst, alloca_dest, idx_op)` to
  `_emit_mux_store_guarded!(_lower_store_via_mux_NxW!, ctx, inst,
   alloca_dest, idx_op, block_label, packed_bits)`.

Total line delta: ~+40 new, ~6 modified (one per shape). Under 50 lines
touched in `lower.jl`.

### No other files touched

- `src/shadow_memory.jl` — untouched (shadow path is M2c's domain).
- `src/softmem.jl` — untouched (callees frozen).
- `src/bennett_transform.jl` — untouched.
- `test/test_memory_corpus.jl` — flip L7f from `@test_broken` to `@test`
  and add the corresponding input sweep (same pattern as M2c did for
  L7e). Roughly 5 line delta in the test file.

### Verification path

- `julia --project test/test_memory_corpus.jl` — L7f flips from errored-
  broken to green.
- `julia --project -e 'using Pkg; Pkg.test()'` — full suite passes.
- Regenerate `BENCHMARKS.md` — all MUX EXCH store counts byte-identical
  (entry-block only), all arithmetic baselines identical.
- New test ideas worth filing as follow-up (not required by M2d):
  - `L7f_2x8`, `L7f_8x8`, `L7f_4x16` — non-entry MUX stores at other
    shapes to cover all six parametric variants.
  - diamond CFG with MUX store in each branch of an outer if, inner
    phi on the alloca value (stresses false-path sensitization — the
    exact same risk M2c + M2b cover for shadow stores).
  - MUX store with a multi-wire block predicate (currently an error;
    future extension).

### Helper search invariant (CLAUDE.md §12 — NO DUPLICATED LOWERING)

- `lower_mux!`: reused as-is (no new copy).
- `allocate!`: reused.
- `CNOTGate` push pattern for snapshot: pattern identical to
  `emit_shadow_store!`'s first loop — but the shadow helper conflates
  snap with a tape slot to support the XOR-swap semantics it needs.
  Factoring a "snapshot" primitive would reuse one loop of 3
  across two call sites with slightly different semantics and not
  simplify anything. Keep it inline.
- `block_pred` lookup: pattern matches `_lower_store_via_shadow!` almost
  verbatim. Could factor into `_guard_pred_wire(ctx, block_label)` shared
  between shadow and MUX paths — a nice-to-have cleanup, not required
  by M2d. Leave for a follow-up if the reviewer agrees.

---

## Appendix A — worked reversibility trace (N=4, W=8, L7f)

State just before guarded store, pred=1 (block L active, idx=0, val=5):

- primal = [x_0..x_31]  (alloca zero-initialized ⇒ all x_k=0)
- block_pred = 1

Forward:

1. `snap[0..31] ← primal[0..31]` via 32 CNOTs → snap = [0, 0, …, 0]
2. Callee runs: arr_sym ← primal (zext), idx_sym ← 0 (idx=0), val_sym ← 5.
   Callee computes `soft_mux_store_4x8(0, 0, 5) = 5` (low byte). res_sym
   bits [1..8] = bits-of(5) = 1,0,1,0,0,0,0,0; res_sym[9..64] = 0.
3. ctx.vw[alloca_dest] := res_sym[1..32] = [1,0,1,0,0,0,0,0, 0,…,0] (24 zeros).
4. MUX: for each i in 1..32, compute `muxed[i] = snap[i] XOR pred·(new[i] XOR snap[i])`.
   pred=1 → muxed = new = [1,0,1,0,0,0,0,0, 0,…,0] (24 zeros).
5. ctx.vw[alloca_dest] := muxed. Downstream load from idx 0 sees bits 1,0,1,0,…
   = value 5. Correct.

Now pred=0 (block R taken, L skipped, idx=don't-care, val=don't-care):

1. `snap[0..31] ← primal[0..31]` via 32 CNOTs → snap = [0,…,0] (same as above).
2. Callee runs unconditionally. It computes *some* state based on arbitrary
   idx_sym / val_sym values (coming from whatever wires happen to hold them —
   they're still valid UInt64s because wires are always valid bits, just
   garbage from L7f's perspective). res_sym[1..32] = some garbage G.
3. ctx.vw[alloca_dest] := G (wrong — this is the pre-M2d bug).
4. MUX: pred=0 → muxed = snap = [0,…,0]. Correct!
5. ctx.vw[alloca_dest] := muxed = [0,…,0]. Downstream load from idx 0 sees
   value 0. **L7f's assertion `simulate(c, (5, 0, false)) == 0` now passes.**

Reverse (Bennett):

1. MUX gates play back: muxed, diff zero out.
2. Callee gates play back: arr_sym, idx_sym, val_sym, res_sym, and all
   internal ancillae zero out.
3. Snapshot CNOTs play back: snap zeros out (primal unchanged).

All ancillae clean. `verify_reversibility(c)` passes.

End of worked trace.

---

## Appendix B — alternative designs considered and rejected

### B1. New guarded-variant callee

Add `soft_mux_store_NxW_guarded(arr, idx, val, pred) = pred==1 ? soft_mux_store(arr,idx,val) : arr`.

**Rejected**: Changes callee gate count. `soft_mux_store_4x8` goes from
7,122 to ≈ 7,122 + 32 extra Toffolis (MUX on output) — perturbs
BENCHMARKS.md. Also requires re-registering each callee and threading
the pred wire through `IRCall` arg-passing, which currently takes
width-per-arg vectors.

### B2. Guard-inside the callee via a Julia `ifelse` on pred

Add `pred::UInt64` as a 1-bit arg, and write
`return ifelse(pred & 1 == 1, soft_mux_store_4x8(...), arr)`.

**Rejected** for the same reason as B1 — callee gate count changes. Also,
the `ifelse` inside Julia lowers to a final MUX inside the callee's gate
list, which is strictly more expensive than doing it in one place at the
lower site (because the callee's intermediates would still fire and then
get MUX-ignored, wasting gates).

### B3. Conditionally skip the IRCall emission based on pred

**Rejected**: `pred` is a runtime wire, not compile-time known. You
cannot skip gate emission based on a runtime value — the circuit is
static.

### B4. Pebble-based snapshot via shadow_memory tape

Reuse `emit_shadow_store!` to pack-and-save primal, then reverse.

**Rejected**: shadow_store is semantically a WRITE primitive (it writes
val into primal and records old-primal onto tape). Using it for snapshot
would require a zero val, which would zero primal, requiring further
MUX to restore at pred=0 — strictly more gates than the direct CNOT
snapshot + lower_mux! design.

### B5. Wire-level guarding via Toffoli-replay of callee gates

Scan the callee's forward gate list and replace each `CNOT(c,t) →
Toffoli(pred,c,t)` / `Toffoli(a,b,c) → 4-op decomp-of-guarded-Toffoli`.

**Rejected**: (a) Toffoli-under-guard requires a 4-operand primitive
that we don't have (we would need to decompose into multiple Toffolis
via ancillae); (b) each gate's cost ≈ doubles or triples, blowing up
baselines by 2-3× for non-entry-block stores; (c) as noted in §2, even
with every write guarded the callee reads arr_sym and propagates garbage
to res_sym at pred=0, so the final rebind would still be wrong unless
we MUX on the output — which is back to Design A plus heavy callee
perturbation.

Design A is the cleanest.
