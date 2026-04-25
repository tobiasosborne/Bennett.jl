# Proposer A — M2b: pointer-typed phi / select (path-predicate-first)

**Milestone**: Bennett-cc0 / M2b — Bucket C2.
**Failing targets**: `test/test_memory_corpus.jl` L7c (phi ptr, two-origin static)
and L7d (select ptr, two-origin static), ~lines 361–398.
**Reference approaches to extend**: M2a cross-block `ptr_provenance`
(`src/lower.jl:321–326`, `:601–606` in WORKLOG) and M2c `entry_label`-gated
shadow store (`src/shadow_memory.jl:98`, `src/lower.jl:1916–1927`).
**Contract with co-proposer / implementer**: the invariants in §8 must hold;
the cost estimates in §10 are upper bounds, not lower bounds.

---

## 1. One-line recommendation

Make pointer-typed phi/select a pure metadata operation: in `ir_extract.jl`
special-case the two opcodes **before** `_iwidth` is ever called, emitting a
new `IRPtrPhi` / `IRPtrSelect` IR node carrying one `origin` per incoming
pointer; in `lower.jl` extend the existing `ptr_provenance` Dict's value type
to a `Vector{PtrOrigin}` and make `lower_store!` / `lower_load!` fan out into
N `emit_shadow_store_guarded!` / `emit_shadow_load!` calls, one per origin,
reusing M2c's path-predicate machinery. **No ancilla gates are emitted at the
phi/select itself** — the gates move to the single-site fan-out at the
use. Cost estimate: L7c ≤ 50 Toffoli, L7d ≤ 50 Toffoli, + 8 CNOT for load;
no regression to any existing baseline because the new code paths only
trigger when provenance resolves to ≥2 origins.

## 2. Root cause — the two layers

### Layer 1 — extraction crash

`src/ir_extract.jl:1350` (inside `_type_width`) errors
`"Unsupported LLVM type for width: LLVM.PointerType(ptr)"`. The call chain
on L7c is:

```
_convert_instruction (opc == LLVMPHI, line 687)
  └─ _iwidth(inst)               # line 693 — inst.type == ptr
      └─ _type_width(PointerType) # line 1338 — no branch for ptr → error
```

L7d goes through the `LLVMSelect` branch (line 680) and hits the same
`_iwidth(inst)` on line 684.

Both sites also call `_operand(ops[i], names)` on pointer-typed SSA values;
`_operand` (line 1321) does **not** fail on pointer operands — it just
returns `ssa(names[ref])`, which is fine. So the only IR-extraction crash is
the width query.

### Layer 2 — lowering has no multi-origin representation

`LoweringCtx.ptr_provenance` (`src/lower.jl:64`) is declared

```julia
ptr_provenance::Dict{Symbol, Tuple{Symbol,IROperand}}
```

i.e. exactly **one** `(alloca_dest, element_idx)` per pointer SSA name. There
is no way to represent "this pointer came from alloca `%a` on one path and
alloca `%b` on another". `lower_store!` (`:1854`) and `_lower_store_via_shadow!`
(`:1899`) both dereference this Dict as a single `(alloca_dest, idx_op)` —
they assume a single origin by construction.

Even if we extended the value type, the **store/load primitive is still
single-origin**: `emit_shadow_store!` (`src/shadow_memory.jl:38`) touches
exactly one `primal` slot. For multi-origin we need either (a) a fan-out of
guarded emissions, one per origin, or (b) a copy-to-scratch/dispatch/copy-back
idiom. Approach (a) is strictly cheaper and reuses M2c primitives verbatim —
see §5/§6 below.

## 3. Design: `ir_extract.jl`

### 3.1 Decision: new IR nodes, not a sentinel width

**Option evaluated and rejected**: return `-1` or `0` from `_type_width` for
pointer types. This makes the crash go away but leaves downstream code
(`lower_select!` and `lower_phi!`) doing wire-level CNOT MUX on a
meaningless "width" — the first `allocate!(wa, W)` call in `lower_mux!`
would then allocate zero or negative wires, breaking `WireAllocator`
invariants. CLAUDE.md §1 (fail fast, fail loud) and §7 (bugs are deep) both
argue against this: we should **type-distinguish ptr-phi from int-phi** at
the IR level so dispatch is explicit.

**Chosen**: introduce two new IR node types in `src/ir_types.jl`:

```julia
# NEW — added to src/ir_types.jl
struct IRPtrOrigin
    alloca_dest::Symbol    # the root alloca this pointer-path references
    idx_op::IROperand      # element index within that alloca
end

struct IRPtrPhi <: IRInst
    dest::Symbol
    incoming::Vector{Tuple{IROperand, Symbol}}  # same shape as IRPhi, but no width
end

struct IRPtrSelect <: IRInst
    dest::Symbol
    cond::IROperand        # i1
    true_ptr::IROperand    # ssa pointer
    false_ptr::IROperand   # ssa pointer
end
```

Note: `IRPtrPhi` / `IRPtrSelect` do **not** carry `origins` at extraction
time. Provenance resolution runs at lowering time (it needs access to
`ctx.ptr_provenance` which is populated as instructions are lowered in
order); the IR node only carries the SSA-level topology. This mirrors how
`IRPtrOffset` and `IRVarGEP` carry their base as an `IROperand` and defer
provenance stitching to `lower_ptr_offset!` / `lower_var_gep!` (see
`src/lower.jl:1447–1461` / `:1489–1494`).

### 3.2 Diff sketch — `_convert_instruction`

```julia
# src/ir_extract.jl ~line 679 (select case) — BEFORE
if opc == LLVM.API.LLVMSelect
    ops = LLVM.operands(inst)
    return IRSelect(dest, _operand(ops[1], names),
                    _operand(ops[2], names), _operand(ops[3], names),
                    _iwidth(inst))  # ← crashes for ptr
end

# AFTER
if opc == LLVM.API.LLVMSelect
    ops = LLVM.operands(inst)
    if LLVM.value_type(inst) isa LLVM.PointerType
        return IRPtrSelect(dest, _operand(ops[1], names),
                           _operand(ops[2], names), _operand(ops[3], names))
    end
    return IRSelect(dest, _operand(ops[1], names),
                    _operand(ops[2], names), _operand(ops[3], names),
                    _iwidth(inst))
end
```

Analogous change for phi (~line 687):

```julia
# AFTER
if opc == LLVM.API.LLVMPHI
    incoming = Tuple{IROperand, Symbol}[]
    for (val, blk) in LLVM.incoming(inst)
        push!(incoming, (_operand(val, names), Symbol(LLVM.name(blk))))
    end
    if LLVM.value_type(inst) isa LLVM.PointerType
        return IRPtrPhi(dest, incoming)
    end
    return IRPhi(dest, _iwidth(inst), incoming)
end
```

Total ir_extract.jl delta: **~12 new lines** (the two type guards).
`_iwidth` / `_type_width` remain untouched — they still fail loud for any
other unexpected pointer use (e.g. `alloca` already has its own integer
element-type handling at `:1267`, `load` at `:1106` returns `nothing` for
non-integer results; no other phi-like site uses `_iwidth` on pointer types).

**Justification for new nodes over sentinel width.** A sentinel (e.g.
`width=0` or `PTR_WIDTH=-1`) requires every downstream consumer that reads
`inst.width` (there are ~8 sites in lower.jl, 2 in dep_dag.jl, 1 in
liveness) to check for the sentinel. A type-based split uses Julia's
multiple dispatch: `lower_phi!(ctx, ::IRPtrPhi)` is a **different method**
from `lower_phi!(ctx, ::IRPhi)` and the compiler enforces non-overlap.
CLAUDE.md §1 fail-loud: if any legacy code accidentally gets an `IRPtrPhi`
where an `IRPhi` is expected, dispatch errors with a clear message — no
silent `width=0` corruption. (Proposer B may propose sentinel; orchestrator
should weigh this trade-off with CLAUDE.md §1.)

## 4. Design: `ptr_provenance` multi-origin

### 4.1 Data structure

Change the Dict value type to a vector plus an optional path-predicate wire
per origin:

```julia
# src/ir_types.jl (or co-located with IRPtrOrigin)
struct PtrOrigin
    alloca_dest::Symbol
    idx_op::IROperand
    # Path-predicate wire that indicates "this origin was selected for this
    # pointer SSA name on the actual path taken". Single-wire. For the
    # single-origin case, this is the block-entry predicate of the block
    # that emitted the alloca (so it's trivially 1 at the use site because
    # the pointer's existence implies dominance).
    predicate_wire::Int
end

# src/lower.jl LoweringCtx field change
ptr_provenance::Dict{Symbol, Vector{PtrOrigin}}
```

**Invariant 1 — at least one origin**: any pointer SSA name present as a
key has `length(ptr_provenance[name]) >= 1`. Zero-origin is invalid (caller
must either error or never insert).

**Invariant 2 — dominance**: for each `PtrOrigin` at pointer SSA name `%p`,
the `predicate_wire` is the AND of the alloca's block-predicate with the
edge predicate(s) required to reach `%p`'s definition site on the path that
selects **this particular origin**. By construction `ptr_provenance[%p]`'s
predicates are pairwise mutually-exclusive (only one incoming edge of the
phi fires per path). This is the same invariant M2c relies on for
`emit_shadow_store_guarded!`.

**Invariant 3 — single-origin backward-compat**: the single-origin case
(everything that worked pre-M2b) is represented as a 1-vector with
`predicate_wire = block_pred[entry_block][1]` (= the global "1" wire
constructed in `lower.jl:370–372` at `NOTGate(pw[1])`). This is the same
wire for every existing non-branchy test, so the fan-out logic in §6
degenerates to a single unguarded-equivalent call. M2c's fast path
(`entry_label`) handles the 3·W CNOT / 0 Toffoli gate-count baseline via
the same mechanism — any origin whose `predicate_wire` is the entry-block
predicate bypasses the Toffoli guard.

### 4.2 Where origins are populated

Four sites touch `ptr_provenance`, with behaviour modifications:

| Site | File:line | Pre-M2b | Post-M2b |
|---|---|---|---|
| `lower_alloca!` | `src/lower.jl:1803` | `ptr_provenance[dest] = (dest, iconst(0))` | `[PtrOrigin(dest, iconst(0), block_pred_wire)]` |
| `lower_ptr_offset!` | `:1459` | `ptr_provenance[dest] = (alloca_dest, new_idx)` | map over origins, bumping each `idx_op` |
| `lower_var_gep!` | `:1493` | `ptr_provenance[dest] = (base.name, inst.index)` | map over origins, replacing each `idx_op` with `inst.index` (index is uniform) |
| `lower_ptrphi!` / `lower_ptrselect!` | **NEW** | — | concat origins from inputs, intersect each with incoming predicate |

Single-origin-preserving fast path: when `length(ptr_provenance[key]) == 1`
**and** the single origin's `predicate_wire` equals
`ctx.block_pred[ctx.entry_label][1]`, `lower_store!` takes the exact same
code path as pre-M2b (3·W CNOT shadow). This is what protects all existing
BENCHMARKS.md numbers (§6.6 invariants in prompt).

## 5. Design: `lower_ptrphi!` / `lower_ptrselect!`

### 5.1 `lower_ptrselect!` (simpler — single block, no predicate OR)

```julia
function lower_ptrselect!(ctx::LoweringCtx, inst::IRPtrSelect)
    # Resolve operands → must both already have provenance
    inst.true_ptr.kind  == :ssa || error("lower_ptrselect!: true_ptr must be ssa, got const")
    inst.false_ptr.kind == :ssa || error("lower_ptrselect!: false_ptr must be ssa, got const")
    t_origins = ctx.ptr_provenance[inst.true_ptr.name]
    f_origins = ctx.ptr_provenance[inst.false_ptr.name]

    # Cond wire (1-bit)
    cw_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.cond, 1)
    cw = cw_wires[1]
    not_cw = _not_wire!(ctx.gates, ctx.wa, cw)   # existing helper at src/lower.jl:~800

    # Fold each incoming origin's predicate with the select condition.
    result = PtrOrigin[]
    for o in t_origins
        push!(result, PtrOrigin(o.alloca_dest, o.idx_op,
              _and_wire!(ctx.gates, ctx.wa, o.predicate_wire, cw)))
    end
    for o in f_origins
        push!(result, PtrOrigin(o.alloca_dest, o.idx_op,
              _and_wire!(ctx.gates, ctx.wa, o.predicate_wire, not_cw)))
    end

    ctx.ptr_provenance[inst.dest] = result
    # NO wires allocated for a "ptr value", NO integer gates for the select itself
    return nothing
end
```

**Gates emitted for L7d**: `%p = select i1 %c, ptr %a, ptr %b`:
- `not_cw`: 1 CNOT to allocate `NOT(c)` on a scratch wire.
- Two `_and_wire!` calls: 2 Toffoli (AND).
- **Total ptr-select itself: 1 CNOT + 2 Toffoli.** Independent of W.

The result: `ctx.ptr_provenance[%p]` = `[
  PtrOrigin(%a, iconst(0), and(entry_pred, c)),
  PtrOrigin(%b, iconst(0), and(entry_pred, not_c))
]`. Note entry_pred is the global 1-wire so `and(1, c) = c` after
simplification — we can skip the AND when the input predicate is
`entry_pred` (micro-optimisation; see §7).

### 5.2 `lower_ptrphi!` (cross-block — uses `block_pred` + `branch_info`)

Same as the M2a/M2c predicated-phi machinery in `resolve_phi_predicated!`
(`src/lower.jl:866`), but operates on `PtrOrigin`s instead of wire vectors:

```julia
function lower_ptrphi!(ctx::LoweringCtx, inst::IRPtrPhi, phi_block::Symbol)
    length(inst.incoming) >= 1 || error("IRPtrPhi $(inst.dest): no incoming origins")

    result = PtrOrigin[]
    for (val, blk) in inst.incoming
        val.kind == :ssa || error("IRPtrPhi incoming must be ssa ptr, got $(val.kind)")
        haskey(ctx.ptr_provenance, val.name) ||
            error("IRPtrPhi: no provenance for incoming %$(val.name)")
        origins = ctx.ptr_provenance[val.name]

        # Compute edge predicate from blk to phi_block (same logic as
        # resolve_phi_predicated!)
        edge_pred = _edge_predicate!(ctx.gates, ctx.wa, blk, phi_block,
                                     ctx.block_pred, ctx.branch_info)

        for o in origins
            combined = _and_wire!(ctx.gates, ctx.wa, o.predicate_wire, edge_pred)
            push!(result, PtrOrigin(o.alloca_dest, o.idx_op, combined))
        end
    end

    ctx.ptr_provenance[inst.dest] = result
    return nothing
end
```

Where `_edge_predicate!` is factored out of the existing
`resolve_phi_predicated!` loop (`src/lower.jl:873–892`) — a ~10-line pure
refactor. For L7c the two edges are from L and R, each an unconditional
branch out of a conditional split in `top`; edge predicates degenerate to
`and(block_pred[L], 1)` = `block_pred[L]` which was computed by
`_compute_block_pred!` (`:818`) as `and(entry_pred, c)` and
`and(entry_pred, not_c)` respectively — so the phi's origins pick up
exactly the path conditions M2c already uses.

**Gates emitted for L7c**:
- Entry block predicate: 1 NOT (allocates 1-wire = 1 — existing, already
  counted in every test).
- `block_pred[L]`: 1 AND (Toffoli) + 0 NOT (unconditional branch out of `top`
  has `c` on L-side, so `_compute_block_pred!` emits 1 Toffoli).
- `block_pred[R]`: 1 NOT + 1 AND (2 Toffoli equivalent — see
  `_compute_block_pred!:835`).
- Phi edge predicates: inherited from block_pred (unconditional branch to J,
  no extra AND).
- Per-origin AND with `entry_pred`: can be elided since `entry_pred = 1`.
- **Total ptr-phi machinery itself: 2 Toffoli + 1 NOT.** M2c already emits
  these when the store is in a non-entry block, so if L7c's store were in
  a non-entry block the cost would be shared. In L7c the store is in J (a
  merge block), so the block_pred for J is computed too — another Toffoli
  for the OR. Net: ~4 extra Toffolis over the ungated baseline, all of
  which are already needed for the store fan-out (§6).

## 6. Design: `lower_store!` / `lower_load!` through multi-origin ptr

### 6.1 Store fan-out

For a store through a multi-origin pointer `%p` with origins
`[(A, idx_A, pred_A), (B, idx_B, pred_B), ...]`, emit **one guarded
shadow-store per origin**:

```julia
# src/lower.jl ~line 1854 — modified lower_store!
function lower_store!(ctx::LoweringCtx, inst::IRStore, block_label::Symbol=Symbol(""))
    inst.ptr.kind == :ssa ||
        error("lower_store!: store to a constant pointer is not supported")

    haskey(ctx.ptr_provenance, inst.ptr.name) ||
        error("lower_store!: no provenance for ptr %$(inst.ptr.name)")
    origins = ctx.ptr_provenance[inst.ptr.name]

    # Single-origin fast path — preserves every pre-M2b baseline.
    if length(origins) == 1
        o = origins[1]
        info = get(ctx.alloca_info, o.alloca_dest, nothing)
        info === nothing && error("lower_store!: unknown alloca %$(o.alloca_dest)")
        strategy = _pick_alloca_strategy(info, o.idx_op)
        # Use existing M2c dispatch — block_label + o.predicate_wire in
        # the ctx decide guarded vs ungated emission.
        return _dispatch_store_strategy!(ctx, inst, o.alloca_dest, info,
                                         o.idx_op, strategy, block_label,
                                         o.predicate_wire)
    end

    # Multi-origin fan-out. Each origin gets an independently-guarded store
    # on its own alloca/slot. At runtime exactly one origin's predicate is
    # true, so exactly one primal register changes state — the others are
    # identity-Toffoli'd.
    for o in origins
        info = get(ctx.alloca_info, o.alloca_dest, nothing)
        info === nothing && error("lower_store!: unknown alloca %$(o.alloca_dest)")
        strategy = _pick_alloca_strategy(info, o.idx_op)
        strategy == :shadow ||
            error("lower_store!: multi-origin store with non-static idx NYI")
        _lower_store_via_shadow_guarded!(ctx, inst, o.alloca_dest, info,
                                         o.idx_op, o.predicate_wire)
    end
    return nothing
end
```

The `_lower_store_via_shadow_guarded!` helper is a thin wrapper around
`emit_shadow_store_guarded!` (`src/shadow_memory.jl:98`) with
`pred_wire = o.predicate_wire`. M2c already proves this construct is
reversible and Bennett-compatible (the `pred` is write-once and the
reverse pass unwinds symmetrically).

**Key invariant**: each origin writes to a **physically distinct** primal
slot (different `alloca_dest` → different wire range). So Bennett's
universal-cleanup (reverse pass) on the tape_slot wires cannot
double-count — the tapes are independent per origin. Within one origin
the tape wire is a fresh allocation (caller invariant per
`emit_shadow_store!` docstring) so no cross-origin interference.

### 6.2 Load fan-out

For a load through a multi-origin pointer, the natural reversible
implementation is a **MUX over N shadow-loads**:

```julia
# Pseudo — src/lower.jl _lower_load_via_shadow_multi!
function _lower_load_via_shadow_multi!(ctx::LoweringCtx, inst::IRLoad,
                                       origins::Vector{PtrOrigin})
    W = inst.width
    result = allocate!(ctx.wa, W)  # starts zero
    for o in origins
        info = ctx.alloca_info[o.alloca_dest]
        elem_w, n = info
        inst.width == elem_w ||
            error("_lower_load_via_shadow_multi!: width mismatch with origin $(o.alloca_dest)")
        o.idx_op.kind == :const ||
            error("_lower_load_via_shadow_multi!: dynamic idx multi-origin NYI")

        arr_wires = ctx.vw[o.alloca_dest]
        primal_slot = arr_wires[o.idx_op.value * elem_w + 1 : (o.idx_op.value + 1) * elem_w]

        # Conditional copy: result[i] ⊕= primal_slot[i] ∧ pred
        for i in 1:W
            push!(ctx.gates, ToffoliGate(o.predicate_wire, primal_slot[i], result[i]))
        end
    end
    ctx.vw[inst.dest] = result
    return nothing
end
```

Because exactly one `o.predicate_wire = 1` at runtime, exactly one origin
XORs its slot into `result`; the others no-op. Bennett's reverse pass
unwinds this symmetrically (same pred wires, Toffoli self-inverse).

### 6.3 Concrete gate-count estimate for L7c and L7d (W=8, two origins)

**L7c** (phi, J-block store, J-block load):

| Component | Gate | Count |
|---|---|---|
| Allocas %a, %b | — | 0 gates (wire alloc only) |
| Entry predicate (already exists) | 1 NOT | 1 |
| block_pred[L] = AND(entry, c) | 1 Toffoli | 1 |
| block_pred[R] = AND(entry, NOT c) — NOT + AND | 1 CNOT + 1 Toffoli | 2 |
| block_pred[J] = OR(L_pred, R_pred) | 1 OR = 3 Toffoli (De Morgan) | 3 |
| ptr_phi origin ANDs with entry_pred (trivial; elided) | — | 0 |
| store fan-out: 2 guarded shadows, each 3·W=24 Toffoli | 6·W Toffoli | 48 |
| load fan-out: 2 guarded CNOT-copies, each W Toffoli | 2·W Toffoli | 16 |
| **Total** | | **~71 gates (67 Toffoli + 1 NOT + 1 CNOT)** |

**L7d** (select, straight-line store + load):

| Component | Gate | Count |
|---|---|---|
| Allocas | — | 0 |
| Entry predicate | 1 NOT | 1 |
| `not_cw` for select | 1 CNOT | 1 |
| Select AND(entry, c), AND(entry, NOT c) — both elided since entry=1; direct wire alias ok but we emit 2 Toffoli for uniformity with L7c | 2 Toffoli | 2 |
| Store fan-out | 6·W Toffoli | 48 |
| Load fan-out | 2·W Toffoli | 16 |
| **Total** | | **~68 gates** |

Both comfortably under any reasonable budget and strictly O(N·W) in store
width and number of origins.

### 6.4 No regression path

The single-origin fast path (§6.1 `length(origins) == 1` branch) routes
through the existing `_dispatch_store_strategy!` which is the M2c code
that preserves `i8 adder = 100`, `Shadow W=8 = 24 CNOT / 0 Toffoli`, etc.
The new fan-out code only executes when at least two origins exist, which
before M2b was *impossible* (the IR rejected the phi/select). So all
existing tests take exactly the same gate path with identical counts.
MUX EXCH variants are entirely untouched — their callees (`soft_mux_store_*`)
are only reached via single-origin dynamic-idx strategy, which is
orthogonal to this change.

## 7. Tests exercised — expected simulation results

### L7c (RED → GREEN)

```julia
ir = raw"""
define i8 @julia_f_1(i8 %x, i1 %c) {
top:
  %a = alloca i8, i32 4
  %b = alloca i8, i32 4
  br i1 %c, label %L, label %R
L:
  br label %J
R:
  br label %J
J:
  %p = phi ptr [ %a, %L ], [ %b, %R ]
  store i8 %x, ptr %p
  %v = load i8, ptr %p
  ret i8 %v
}
"""
c = _compile_ir(ir)
@test verify_reversibility(c)
for x in Int8(-8):Int8(2):Int8(8), cbit in (false, true)
    @test simulate(c, (x, cbit)) == x
end
```

Expected: both paths yield `x` — `c=true` stores at `%a[0]` and loads from
`%a[0]`; `c=false` stores at `%b[0]` and loads from `%b[0]`. The
cross-origin no-op branches leave the inactive alloca at zero.
`verify_reversibility` confirms all tape slots and ancillae return to zero.

### L7d (RED → GREEN)

```julia
ir = raw"""
define i8 @julia_f_1(i8 %x, i1 %c) {
top:
  %a = alloca i8, i32 4
  %b = alloca i8, i32 4
  %p = select i1 %c, ptr %a, ptr %b
  store i8 %x, ptr %p
  %v = load i8, ptr %p
  ret i8 %v
}
"""
c = _compile_ir(ir)
@test verify_reversibility(c)
for x in Int8(-8):Int8(2):Int8(8), cbit in (false, true)
    @test simulate(c, (x, cbit)) == x
end
```

Same semantics as L7c but single-block. Faster compile, same correctness.

### Extended corpus (recommended to add — RED regressions pin the design)

- **L7c2**: phi ptr with `store` in `L` (pre-phi) — should not need M2b;
  single-origin still works. Regression test that M2a survives.
- **L7c3**: phi ptr of three origins via chained phi (two phis feeding a
  third). Proposer-A design handles this iff N=2 per phi node (fanout
  compounds). Explicitly **out of scope for M2b** (§9).
- **L7d2**: select ptr inside a conditional block — tests cross-block
  provenance + select interaction.
- **L7d3**: select ptr followed by GEP(ptr, const_offset). Tests
  `lower_ptr_offset!` correctly maps over the origin vector per §4.2.

## 8. Risks and failure modes

### 8.1 False-path sensitization (CLAUDE.md §"Phi Resolution")

**Risk**: in a diamond CFG (L7c is one), the multi-origin fan-out must NOT
fire the guard for the "dead" side. With the proposed design, origin's
`predicate_wire` is `block_pred[blk] AND edge_pred` — both of which were
computed by M2c's machinery that has already been diamond-tested (see
`test/test_branch.jl`, WORKLOG §M2c). Specifically:

- `_compute_block_pred!` OR-reduces only over predecessors with known
  predicates (`haskey(block_pred, p)` guard at `:827`).
- `resolve_phi_predicated!` uses AND(block_pred, edge_cond) — identical to
  what `lower_ptrphi!` does.

So false-path sensitization for the **predicate** cannot occur by
construction. The remaining risk is one level deeper:

**Sub-risk: predicate wire lifetime**. If the alloca-block's predicate
wire is freed/reused before the use site, the guard breaks. Mitigation:
M2c established that block-predicate wires live for the entire compilation
(they're allocated via `wa` and never freed). Same invariant here — we
never call `free!` on origin predicate wires. CLAUDE.md §1 fail-loud:
add an assertion in `lower_ptrphi!` / `lower_ptrselect!` that each
origin's `predicate_wire` is `> 0` and is still in `ctx.block_pred` or is
an output of an `_and_wire!` call.

### 8.2 Dominance violations

**Risk**: a store through a ptr-phi fires before the phi's originating
alloca is declared. By LLVM SSA dominance rules this is impossible at the
IR level — the alloca dominates its uses, and the phi's incoming block
dominates the incoming pointer value. So as long as we lower blocks in
topological order (which `lower()` does at `:340`), origin wires are
always available by the time the phi is lowered.

**Assertion**: at the top of `lower_ptrphi!` check
`haskey(ctx.ptr_provenance, val.name)` for every incoming — hard-error if
violated (CLAUDE.md §1). This catches the LLVM-bug or front-end-bug case.

### 8.3 Bennett reverse correctness across multi-origin

**Risk**: reverse pass might un-store more than it stored. Mitigation:
each origin's guarded store is self-inverse (M2c proof: pred=0 is Toffoli
no-op, pred=1 is inverse of CNOT). Reverse applies each gate in reverse
order, same pred wires → each origin symmetrically unwinds on whichever
path was taken. Cross-origin independence: different `alloca_dest`s
→ different primal wire ranges → tape slots don't alias.

**Sub-risk**: if two origins share the same `alloca_dest` (pathological —
phi of `%a` with itself), then the two guarded stores both write to `%a`
with mutually-exclusive predicates; exactly one fires. Bennett reverse is
still correct. But this case should be compile-time simplified (dedupe
origins by `(alloca_dest, idx_op)` and OR their predicates) — optional
optimisation, **deferred to follow-up**.

### 8.4 Gate-count regression

**Risk**: any change to `lower_store!`'s signature or fast path perturbs
MUX EXCH or shadow baselines. Mitigation: the single-origin branch calls
the same primitive with the same arguments as pre-M2b. Regression test
harness: re-run `benchmark/run_benchmarks.jl` and assert
- `i8 adder = 100 gates, 28 Toff`
- `i16 = 204, 60 Toff`
- `soft_fma = 447,728`
- `soft_exp_julia = 3,485,262`
- `Shadow W=8 = 24 CNOT / 0 Toff`
- all MUX EXCH variants byte-identical.

These are CLAUDE.md §6 regression baselines. If ANY changes, stop and
investigate (M2c experience confirms this is the right guard).

### 8.5 Interaction with `_lower_store_via_mux_*!` (dynamic idx)

**Risk**: dynamic-idx + multi-origin pointer → we explicitly error
(§6.1 `strategy == :shadow || error(... NYI)`). The L7c/L7d corpus uses
static idx 0 so this is fine. Broader coverage is the M2b+x follow-up
(§9). M2d / Bennett-i2a6 is already filed for single-origin dynamic-idx
guarding; multi-origin dynamic-idx is strictly harder and explicitly
deferred.

## 9. What I won't do in M2b

- **N > 2 origins via chained phi/select.** The design handles N>=2
  structurally (fan-out is a loop), but the test corpus only covers N=2.
  If the implementer finds a real-world N≥3 case in the broader regression
  suite, they should add a test; otherwise leave deeper coverage to a
  follow-up.
- **Multi-origin dynamic idx (`strategy ≠ :shadow`).** Hard-errors with a
  clear message pointing at M2d/Bennett-i2a6 for the guarding work, plus
  a new issue (Bennett-M2b-x) for the multi-origin extension.
- **Origin dedup / CSE.** If two origins have identical `(alloca_dest,
  idx_op)` the fan-out emits two guarded stores that happen to cancel;
  correctness is preserved, gate count is wasteful. Dedup is a pure
  optimisation, deferred.
- **Pointer arithmetic across phi boundaries with non-const offsets.** A
  GEP with a runtime index applied to a multi-origin pointer changes
  shape: we'd need to carry the `idx_op` as the result of a MUX over the
  two incoming index values, which gets hairy when the element type
  changes (it can't for the L7c/L7d corpus). Deferred.
- **MemorySSA integration.** PRD §10 M2 originally mentioned MemSSA; we
  use ptr_provenance directly for M2b and leave MemSSA integration to a
  future milestone (the WORKLOG analysis at `:536–542` endorses this
  split).
- **Refactor `ptr_provenance` Dict value type in a separate commit.**
  Suggested ordering for the implementer: single PR that lands the
  Vector<PtrOrigin> change + fan-out + extraction guards + L7c/L7d tests
  in one atomic commit, to keep the correctness story self-contained.
  Splitting across commits leaves an intermediate state where
  ptr_provenance is vectorised but stores still assume single-origin,
  which could mask a latent bug if a later commit doesn't land.

## 10. Cost estimate (lines changed)

| File | Lines added | Lines removed | Notes |
|---|---:|---:|---|
| `src/ir_types.jl` | ~25 | 0 | `IRPtrOrigin`, `IRPtrPhi`, `IRPtrSelect`, `PtrOrigin` |
| `src/ir_extract.jl` | ~12 | 0 | ptr-type guards in select/phi cases |
| `src/lower.jl` | ~150 | ~30 | `LoweringCtx.ptr_provenance` type change; `lower_alloca!` / `lower_ptr_offset!` / `lower_var_gep!` updated to Vector; new `lower_ptrphi!` / `lower_ptrselect!`; `lower_store!` fan-out; new `_lower_load_via_shadow_multi!`; factor out `_edge_predicate!` (pure refactor of existing resolve_phi_predicated loop) |
| `src/Bennett.jl` | ~4 | 0 | Export `IRPtrPhi`, `IRPtrSelect` if needed for tests |
| `test/test_memory_corpus.jl` | ~30 | ~6 | L7c, L7d flip from `@test_throws Exception` to GREEN sweeps; add L7c2, L7d2 regressions |
| **Total** | **~220** | **~36** | |

**Implementer checklist**:
1. Red: add L7c GREEN sweep (should fail at extraction).
2. Extract-layer fix: new IR nodes + guards. Run L7c — should now fail in
   `lower.jl` with "Unhandled instruction type: IRPtrPhi".
3. Lower-layer plumbing: new `lower_ptrphi!` / `lower_ptrselect!` dispatch
   entries. Vector-ise `ptr_provenance`. Touch `lower_alloca!` /
   `lower_ptr_offset!` / `lower_var_gep!` first (they populate provenance).
4. Fan-out: new `lower_store!` single/multi split + new
   `_lower_load_via_shadow_multi!`.
5. L7c GREEN. Green-pin with `verify_reversibility` + 16-input sweep.
6. L7d GREEN.
7. Full suite: `julia --project -e 'using Pkg; Pkg.test()'`.
8. BENCHMARKS.md regenerate + diff against committed baselines — must be
   byte-identical for §6.6 keys.
9. WORKLOG.md entry per CLAUDE.md §0.

Throughout: fail-fast asserts (CLAUDE.md §1), test incrementally (§8), no
shortcuts in origin-predicate calculation (§R3 false-path sensitization).
