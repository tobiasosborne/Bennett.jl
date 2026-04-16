# M2b Proposer B — MemorySSA-wired pointer-phi/select support

*Bennett-cc0 Memory epic, Milestone M2b. Bucket C2.*
*Proposer B — MemorySSA-authoritative design.*

---

## 1. One-line recommendation

**Land MemSSA wiring as the authoritative def-use source for pointer-typed phi/select**, with a thin `ptr_origins` side-map in `LoweringCtx` that stores a *multi-origin* `(alloca, idx)` set per ptr SSA name; `lower_store!` / `lower_load!` dispatch over the set, path-guarding each origin by the guard predicate that selected it (reusing M2c's `emit_shadow_store_guarded!` machinery). MemSSA is **consulted** where it is available; when MemSSA is absent (`_compile_ir` textual path, `use_memory_ssa=false`) a local dataflow fallback computes the same multi-origin set by walking phi/select statically. L7c and L7d compile with either path.

---

## 2. Root cause — two layers

### Layer 1: extraction (ir_extract.jl)

At `src/ir_extract.jl:1350`, `_type_width(tp)` rejects `LLVM.PointerType` with
`"Unsupported LLVM type for width: LLVM.PointerType(ptr)"`.

Calls that trigger it for L7c/L7d:

- `src/ir_extract.jl:684` — `_iwidth(inst)` inside the **select** handler (`opc == LLVM.API.LLVMSelect`), building an `IRSelect` with `width=_iwidth(inst)`.
- `src/ir_extract.jl:693` — `_iwidth(inst)` inside the **phi** handler, building an `IRPhi` with `width=_iwidth(inst)`.

Both instructions are legal LLVM (pointer-typed phi/select is common post-`mem2reg`). The extractor is over-strict.

### Layer 2: lowering (lower.jl)

Even if we accept pointer-typed IR, the downstream data structures can't represent the fact that a single ptr SSA name has two (or more) possible origins. The relevant state is in `LoweringCtx`:

```julia
ptr_provenance::Dict{Symbol, Tuple{Symbol,IROperand}}  # src/lower.jl:64
```

That map is **single-valued**: exactly one `(alloca_dest, element_idx)` per ptr SSA. `lower_store!` (src/lower.jl:1854–1886) and `_lower_load_via_mux!` (src/lower.jl:1546–1569) do `ctx.ptr_provenance[inst.ptr.name]` and proceed to a single strategy. No representation for the L7c case where `%p = phi [%a, %L], [%b, %R]` resolves to *either* `(alloca=%a, idx=0)` *or* `(alloca=%b, idx=0)` depending on the runtime path.

### Also relevant: `lower_phi!` and `lower_select!` both emit `lower_mux!`

`lower_phi!` (src/lower.jl:905) and `lower_select!` (src/lower.jl:1284) resolve operand wires and emit a MUX circuit that produces a single result wire vector for `inst.dest`. **For pointer results this is semantically wrong**: you cannot MUX pointers as bit-vectors because the downstream consumer (a store or load) wants a *routing decision*, not a blended value. We must bypass the MUX and attach multi-origin metadata instead.

---

## 3. Design — ir_extract.jl (unblock L7c/L7d construction)

**Pick: bypass `_type_width` in the phi/select handlers for pointer-typed results.** Pointer "width" is not a meaningful bit count in our IR — pointers are not lowered to wires, they're resolved via `ptr_provenance`/`ptr_origins`. Extending `_type_width` to return something for `PointerType` invites misuse (some caller might treat 64 as "64 wires please").

**Rationale**: Julia + LLVM target-independent IR often has opaque `ptr`. Returning 64 (x86_64 pointer width in bits) is wrong on 32-bit targets and would produce phantom wires. A sentinel value (`0`? `-1`?) would leak into arithmetic paths. Cleanest is to detect pointer type at the call site and pick a pointer-specific IR construction that carries `width=0` and a `kind=:ptr` tag.

### Diff sketch — select handler (around `src/ir_extract.jl:679`)

```julia
if opc == LLVM.API.LLVMSelect
    ops = LLVM.operands(inst)
    rt  = LLVM.value_type(inst)
    if rt isa LLVM.PointerType
        # Pointer-typed select: width=0 sentinel, lowering routes via ptr_origins.
        return IRSelect(dest, _operand(ops[1], names),
                        _operand(ops[2], names), _operand(ops[3], names), 0)
    end
    return IRSelect(dest, _operand(ops[1], names),
                    _operand(ops[2], names), _operand(ops[3], names),
                    _iwidth(inst))
end
```

### Diff sketch — phi handler (around `src/ir_extract.jl:687`)

```julia
if opc == LLVM.API.LLVMPHI
    incoming = Tuple{IROperand, Symbol}[]
    for (val, blk) in LLVM.incoming(inst)
        push!(incoming, (_operand(val, names), Symbol(LLVM.name(blk))))
    end
    rt = LLVM.value_type(inst)
    w  = rt isa LLVM.PointerType ? 0 : _iwidth(inst)
    return IRPhi(dest, w, incoming)
end
```

**Why `width=0` and not a new `IRPtrPhi` / `IRPtrSelect` struct?** Two reasons:

1. Every consumer of `IRPhi`/`IRSelect` already has a code path (`inst.width`). Adding a new struct forces surgery in `dep_dag.jl`, liveness analysis, `_ssa_operands`, `_lower_inst!` dispatch, gate-group bookkeeping — dozens of sites. A `width=0` sentinel is detectable with a single `inst.width == 0` check at the one place that matters (`lower_phi!` / `lower_select!`).
2. If later we want dedicated types for clarity, the refactor from `width=0` to `IRPtrPhi` is mechanical (search-replace with type narrowing) and can happen when a second reason arises.

**Failure mode this creates**: if a future handler accidentally treats a `width=0` phi as "the thing has zero bits" and emits zero gates, verify_reversibility still catches it (the output wires map is empty → simulate can't return anything, fails). But to make fail-fast explicit (CLAUDE.md §1), add an assertion at the top of `lower_phi!`/`lower_select!`: if `inst.width == 0`, dispatch to the pointer handler; if no handler is configured, `error()` with context.

---

## 4. Design — MemSSA → LoweringCtx wiring

### ParsedIR already carries MemSSA

`src/ir_types.jl:159` declares `memssa::Any` in `ParsedIR`. It's populated by `extract_parsed_ir(…; use_memory_ssa=true)` and stays `nothing` otherwise. **No ParsedIR change needed.**

### LoweringCtx gains a reference

Add one optional field to `LoweringCtx`:

```julia
# src/lower.jl:78 (after entry_label)
memssa::Any                     # MemSSAInfo or nothing
```

Plus a `ptr_origins` field that replaces/augments `ptr_provenance`:

```julia
# Multi-origin ptr provenance. Each entry maps a ptr SSA to ≥1 alternatives:
#   (alloca_dest, idx_op, guard_pred_wires, block_of_def)
# guard_pred_wires is a 1-wire vector (or empty for unconditional origin).
ptr_origins::Dict{Symbol, Vector{PtrOrigin}}
```

Where:

```julia
struct PtrOrigin
    alloca_dest::Symbol         # which alloca this origin points into
    idx_op::IROperand           # element index into that alloca
    guard_wires::Vector{Int}    # path predicate wires (AND of these is "this origin active")
                                # EMPTY = unconditional / single-origin
    src_block::Symbol           # defining block (for debugging / phi-block lookup)
end
```

### Backward-compat: keep `ptr_provenance` as a narrowed view

Not all uses of `ptr_provenance` are phi-related. `lower_alloca!`, `lower_ptr_offset!`, `lower_var_gep!` populate it and expect single-valued lookups. We keep `ptr_provenance` as the **fast single-origin path** and add `ptr_origins` as the **multi-origin path**.

Invariant:
- If a ptr has exactly one origin, it lives in `ptr_provenance` **and** its vector in `ptr_origins` has length 1 (empty guards).
- If a ptr has >1 origin, it lives **only** in `ptr_origins`. `ptr_provenance` does not have an entry.

Maintenance: `lower_alloca!`, `lower_ptr_offset!`, `lower_var_gep!` write to both maps on single-origin creation. `lower_phi!`/`lower_select!` for pointer-typed results write only to `ptr_origins`.

Dispatch sites (`lower_store!`, `_lower_load_via_mux!`) check `ptr_origins` first; if `length == 1` and `guard_wires` is empty, fall through to the existing single-origin path. Otherwise use the multi-origin fan-out path described in §6–§7.

### Wiring diff sketch

```julia
# src/lower.jl — LoweringCtx struct
struct LoweringCtx
    # … existing 18 fields …
    entry_label::Symbol
    memssa::Any                 # NEW: MemSSAInfo | nothing
    ptr_origins::Dict{Symbol, Vector{PtrOrigin}}  # NEW
end

# lower() in src/lower.jl:302 — allocate once per compilation, next to ptr_provenance
ptr_origins = Dict{Symbol, Vector{PtrOrigin}}()
# and thread through lower_block_insts! kwargs alongside alloca_info/ptr_provenance.

# lower() also reads parsed.memssa and passes through:
memssa = parsed.memssa   # nothing if use_memory_ssa=false
```

`lower_block_insts!` grows two kwargs: `memssa::Any=nothing`, `ptr_origins=Dict{…}()`. Constructor of `LoweringCtx` is extended (back-compat via a new arity; the 13-arg path still defaults both to `nothing`/empty). Approximately 4 new lines in `lower()`, 2 new kwargs in `lower_block_insts!`, ~3 lines in constructors.

---

## 5. Design — ptr_provenance ↔ MemSSA: augment (not replace)

### Why augment

1. **Textual IR path**: `test/test_memory_corpus.jl:_compile_ir` calls `_module_to_parsed_ir` directly — **no MemSSA run**. L7c/L7d tests won't get MemSSA. So we MUST also work without MemSSA. The local dataflow fallback (described below) computes the same `ptr_origins` map.
2. **Cost**: MemSSA runs another LLVM pass on the function; for the i8 adder benchmark we do NOT want to pay that cost. MemSSA stays opt-in.
3. **Regression invariants**: BENCHMARKS.md gate counts are byte-identical today. MemSSA should augment, not substitute — touching zero code when MemSSA is `nothing`.

### MemSSA's role

When `ctx.memssa !== nothing`, we use `MemSSAInfo` **as a correctness cross-check** and **to prune spurious multi-origin sets**. Specifically:

1. At a pointer-typed phi, `MemSSAInfo.phis` may tell us that a downstream load's `MemoryUse(N)` is dominated by a single `MemoryDef`, in which case we can collapse the multi-origin set to one origin (saves gates).
2. At a store through a multi-origin ptr, MemSSA tells us which prior `MemoryDef` clobbers this store — informing the guarded-write strategy.

**Decision**: MemSSA is used for **optimization and cross-check**; the correctness path for L7c/L7d runs purely on local dataflow. This is deliberately conservative — it sidesteps the MemSSA text-parse fragility risk (PRD R2) for the correctness-critical path and preserves fail-fast when MemSSA disagrees.

### Local dataflow fallback (authoritative for correctness)

In `lower_block_insts!` (or a new pass `_collect_ptr_origins!` run before the instruction walk), statically fold pointer phi/select transitively:

```
for inst in block in topological order (already what we do):
    if inst is IRAlloca:           ptr_origins[dest] = [PtrOrigin(dest, iconst(0), [], block)]
    if inst is IRPtrOffset/IRVarGEP: propagate each origin through the offset/GEP
    if inst is IRPhi, width=0:
        merged = PtrOrigin[]
        for (val, src_block) in inst.incoming:
            if val is SSA and val.name in ptr_origins:
                guard = block_pred[src_block]   # the predicate under which src_block was active
                for o in ptr_origins[val.name]:
                    push!(merged, PtrOrigin(o.alloca_dest, o.idx_op,
                                            vcat(o.guard_wires, guard), src_block))
        ptr_origins[inst.dest] = merged
    if inst is IRSelect, width=0:
        cond_wires = resolve!(…, inst.cond, 1)
        tv_origins = ptr_origins[inst.op1.name]
        fv_origins = ptr_origins[inst.op2.name]
        merged = PtrOrigin[]
        for o in tv_origins:
            push!(merged, PtrOrigin(o.alloca_dest, o.idx_op,
                                    vcat(o.guard_wires, cond_wires), block))
        # op2 is the false value; guard = NOT(cond). Materialize once.
        not_cond = _not_wire!(gates, wa, cond_wires)
        for o in fv_origins:
            push!(merged, PtrOrigin(o.alloca_dest, o.idx_op,
                                    vcat(o.guard_wires, not_cond), block))
        ptr_origins[inst.dest] = merged
```

**Guard wires are a conjunction**: when we fan out a store or load, the guard for a given origin is AND-of-its-wires. We materialize the AND lazily at the store/load site (see §7).

**Crucially**, for L7c, `block_pred[%L]` is already the 1-wire predicate for being on the L-path, computed by M2c's `_compute_block_pred!`. We reuse it verbatim. This is the hinge that makes §7 cheap.

---

## 6. Design — `lower_phi!` / `lower_select!` for ptr results

### Metadata-only, zero gates

When `inst.width == 0` (pointer-typed), **emit no gates**. `vw[inst.dest]` is **not** set (no wires — pointers don't materialize as wires). Only `ptr_origins[inst.dest]` is populated per §5.

### Diff sketch — `lower_phi!`

```julia
function lower_phi!(gates, wa, vw, inst::IRPhi, phi_block::Symbol,
                    preds, branch_info, block_order;
                    block_pred::Dict{Symbol,Vector{Int}}=Dict{Symbol,Vector{Int}}(),
                    ptr_origins::Dict{Symbol,Vector{PtrOrigin}}=Dict{Symbol,Vector{PtrOrigin}}())
    if inst.width == 0
        # Pointer-typed phi: merge origins, no gates, no vw entry.
        merged = PtrOrigin[]
        for (val, src_block) in inst.incoming
            val.kind == :ssa ||
                error("lower_phi!: pointer phi from non-SSA operand is unsupported")
            haskey(ptr_origins, val.name) ||
                error("lower_phi!: pointer phi incoming %$(val.name) has no origin")
            g_wires = get(block_pred, src_block, Int[])
            for o in ptr_origins[val.name]
                push!(merged, PtrOrigin(o.alloca_dest, o.idx_op,
                                        vcat(o.guard_wires, g_wires), src_block))
            end
        end
        isempty(merged) &&
            error("lower_phi!: pointer phi $(inst.dest) produced empty origin set")
        ptr_origins[inst.dest] = merged
        return nothing
    end
    # ... existing integer-typed phi path (unchanged) ...
end
```

Dispatcher update in `_lower_inst!`: pass `ctx.ptr_origins` through.

### Diff sketch — `lower_select!`

```julia
function lower_select!(gates, wa, vw, inst::IRSelect; ctx=nothing)
    if inst.width == 0
        ctx !== nothing ||
            error("lower_select!: pointer select requires ctx for ptr_origins threading")
        cond_wires = resolve!(gates, wa, vw, inst.cond, 1)
        merged = PtrOrigin[]
        for (side, guard) in ((inst.op1, cond_wires),
                              (inst.op2, _not_wire_single!(gates, wa, cond_wires)))
            side.kind == :ssa || error("lower_select!: constant pointer unsupported")
            haskey(ctx.ptr_origins, side.name) ||
                error("lower_select!: select operand %$(side.name) has no origin")
            for o in ctx.ptr_origins[side.name]
                push!(merged, PtrOrigin(o.alloca_dest, o.idx_op,
                                        vcat(o.guard_wires, guard), Symbol("__select__")))
            end
        end
        ctx.ptr_origins[inst.dest] = merged
        return nothing
    end
    # ... existing integer-typed select path (unchanged) ...
end
```

`_not_wire_single!` allocates one wire, copies + inverts (2 gates). This is the "NOT cond" guard wire for the false-side.

### Why this is correct

The semantics of pointer phi/select are "routing decision": at runtime, exactly one origin's guard predicate is true. Each origin's guard is the AND of its incoming path predicate plus all its ancestor guards. No information is lost; no gates spent on fictional "ptr-bit merging".

---

## 7. Design — `lower_store!` / `lower_load!` through a multi-origin ptr

### Disambiguated case: MemSSA reveals a single dominating def

If `ctx.memssa !== nothing` and the load/store's `use_at_line`/`def_at_line` entry maps to a single alloca origin (verified by cross-referencing the Def's instruction's alloca provenance), collapse the origin set to that one — emit the existing single-origin shadow or MUX path. No new gates. This is the SHA-256 "40% drop" path hinted in PRD §6, but is secondary to correctness for L7c/L7d.

### Multi-origin case: path-guarded fan-out

Shared structure for both store and load:

1. Materialize a **per-origin guard wire** `g_i = AND(guard_wires[i]...)`. For L7c each origin has a single guard wire (the `block_pred` of L or R), so `g_i` is just that one wire — **zero new gates** for a single-wire guard. For deeper phi chains `g_i` is an O(k) Toffoli AND-reduction. **Enforcement** of mutual exclusion is **not emitted** — we rely on the invariant that each origin's guard is a path predicate, and at most one path predicate is 1 at runtime. This invariant is established by M2c's `_compute_block_pred!` + `resolve_phi_predicated!`.

2. **Store fan-out**: for each origin `i`, emit `emit_shadow_store_guarded!(ctx.gates, ctx.wa, primal_slot_i, tape_i, val_wires, W, g_i)`. Each origin writes into its own alloca, guarded by its own path wire. Because guards are mutually exclusive and the invariant holds, exactly one write fires.

3. **Load fan-out**: for each origin `i`, emit a guarded CNOT-copy of `primal_slot_i` into a **single** shared result-wire block. The guard ensures only the active origin contributes bits. This is the same pattern as `emit_shadow_store_guarded!` but in the load direction:

```julia
result = allocate!(ctx.gates, W)
for i in origins:
    for bit in 1:W:
        push!(gates, ToffoliGate(g_i, primal_slot_i[bit], result[bit]))
ctx.vw[inst.dest] = result
```

**Mutual exclusion is load-bearing**: if two origins' guards fire simultaneously, the load ToffoliGates XOR their contributions instead of selecting one. M2c already guarantees this at the block-predicate level for diamonds (`block_pred[L] ∧ block_pred[R] = 0` by construction). For pointer-select, the per-side cond/NOT-cond guards are trivially mutually exclusive.

### CLAUDE.md §Phi Resolution risk acknowledged

The false-path-sensitization gotcha is exactly the one §Phi Resolution warns about. Mitigation is that we **reuse M2c's block_pred path predicates** rather than inventing new guards. M2c already did the diamond-CFG analysis for conditional shadow stores; we piggyback. For L7c the outer guards are `block_pred[%L]` (= cond) and `block_pred[%R]` (= NOT cond) — mutual exclusion is immediate. For L7d the select's own cond/NOT-cond likewise. Nested pointer phi cases would compose via `vcat(guard_wires, …)` and AND-reduction — still mutually exclusive by construction.

### Diff sketch — `lower_store!`

```julia
function lower_store!(ctx::LoweringCtx, inst::IRStore, block_label::Symbol=Symbol(""))
    inst.ptr.kind == :ssa || error("lower_store!: constant pointer unsupported")

    # Multi-origin path takes priority.
    if haskey(ctx.ptr_origins, inst.ptr.name)
        origins = ctx.ptr_origins[inst.ptr.name]
        if length(origins) == 1 && isempty(origins[1].guard_wires)
            # Single unconditional origin → existing fast path via ptr_provenance.
            @goto legacy_path
        end
        return _lower_store_multi!(ctx, inst, origins, block_label)
    end
    @label legacy_path
    # ... existing single-origin dispatch (src/lower.jl:1858 onward) ...
end

function _lower_store_multi!(ctx, inst, origins, block_label)
    # For each origin, resolve the primal slot and emit a guarded store.
    val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, inst.width)
    for o in origins
        info = ctx.alloca_info[o.alloca_dest]
        (elem_w, n) = info
        inst.width == elem_w ||
            error("_lower_store_multi!: origin $(o.alloca_dest) width mismatch ($(inst.width) vs $elem_w)")
        o.idx_op.kind == :const ||
            error("_lower_store_multi!: dynamic idx through pointer phi not yet supported")
        0 <= o.idx_op.value < n ||
            error("_lower_store_multi!: idx=$(o.idx_op.value) out of range")
        primal = ctx.vw[o.alloca_dest][o.idx_op.value*elem_w+1 : (o.idx_op.value+1)*elem_w]
        tape = allocate!(ctx.wa, elem_w)
        g = _reduce_and!(ctx.gates, ctx.wa, o.guard_wires)
        emit_shadow_store_guarded!(ctx.gates, ctx.wa, primal, tape, val_wires, elem_w, g)
    end
    return nothing
end
```

### Diff sketch — `lower_load!`

```julia
function lower_load!(ctx::LoweringCtx, inst::IRLoad)
    if inst.ptr.kind == :ssa && haskey(ctx.ptr_origins, inst.ptr.name)
        origins = ctx.ptr_origins[inst.ptr.name]
        if length(origins) > 1 || !isempty(origins[1].guard_wires)
            return _lower_load_multi!(ctx, inst, origins)
        end
    end
    # ... existing dispatch (src/lower.jl:1538 onward) ...
end

function _lower_load_multi!(ctx, inst, origins)
    W = inst.width
    result = allocate!(ctx.wa, W)  # zero by WireAllocator invariant
    for o in origins
        info = ctx.alloca_info[o.alloca_dest]
        (elem_w, n) = info
        W == elem_w || error("_lower_load_multi!: width mismatch")
        o.idx_op.kind == :const || error("_lower_load_multi!: dynamic idx deferred")
        primal = ctx.vw[o.alloca_dest][o.idx_op.value*elem_w+1 : (o.idx_op.value+1)*elem_w]
        g = _reduce_and!(ctx.gates, ctx.wa, o.guard_wires)
        for bit in 1:W
            push!(ctx.gates, ToffoliGate(g, primal[bit], result[bit]))
        end
    end
    ctx.vw[inst.dest] = result
    return nothing
end
```

### MemSSA disambiguation (optimization layer)

Before `_lower_store_multi!` / `_lower_load_multi!` dispatch, add a `_memssa_collapse_origins!(ctx, inst, origins)` check:

```julia
function _memssa_collapse_origins!(ctx, inst, origins)
    ctx.memssa === nothing && return origins
    # Locate this inst's line in the annotated IR (one-pass map built at ctx creation).
    line = get(ctx.inst_line_map, inst, 0)
    line == 0 && return origins  # not annotated — conservative
    if inst isa IRLoad
        def = get(ctx.memssa.use_at_line, line, nothing)
        def === nothing && return origins
        # If the single dominating Def corresponds to one alloca, collapse to it.
        collapsed = filter(o -> _memssa_def_reaches(ctx.memssa, def, o), origins)
        length(collapsed) == 1 && return collapsed
    end
    return origins
end
```

This is a pure optimization: if it returns the original list, correctness is unchanged. For L7c/L7d without MemSSA, this is a no-op — the fan-out path handles correctness on its own.

**Defer**: `_memssa_def_reaches` requires annotated-IR line ↔ IRInst mapping, which is not trivial given our two-pass LLVM-then-ParsedIR flow (instruction order is preserved but line numbering depends on the printer format). Ship M2b with MemSSA disambiguation as a TODO stub (MemSSA is consulted but `origins` is returned unchanged); file a follow-up issue to wire the line-map. This preserves correctness and defers the risky text-parse plumbing.

---

## 8. Cost for L7c / L7d — gate-count estimate

### L7c (pointer-phi, diamond CFG)

```
top:  %a = alloca i8×4          — 0 gates
      %b = alloca i8×4          — 0 gates
      br i1 %c, label L, R      — cond wire resolved (1 existing wire)
L:    br J                       — block_pred[L] = AND(entry_pred, %c) = %c (1 AND = 0 gates extra if entry is always-1)
R:    br J                       — block_pred[R] = AND(entry_pred, NOT %c) = NOT %c (1 NOT = 2 gates)
J:    %p = phi ptr [%a, L], [%b, R]  — 0 gates (metadata-only)
      store i8 %x, ptr %p       — emit_shadow_store_guarded! × 2:
                                   per origin: tape = W wires, 3W Toffoli (M2c path)
                                   W = 8 → 24 Toffoli per origin × 2 = 48 Toffoli
                                   + 2 tape allocations = 16 wires
      %v = load i8, ptr %p      — 2 × 8 Toffoli = 16 Toffoli (guarded CNOT-copy)
                                 + 8 result wires
      ret i8 %v                 — existing return handling
```

**Approximate total**: ~48 Toffoli (store) + ~16 Toffoli (load) + ~2 gates (NOT cond) ≈ **66 Toffoli + a handful of CNOT**. Small constant factor over a single-origin shadow store (~3·8 = 24 Toffoli), due to the fan-out × 2. Well within budget.

### L7d (pointer-select, single block)

Same structure but without block_pred AND-ing. The select emits `NOT %c` once (2 gates: CNOT + NOT, or 1 wire + 1 NOT if we reuse `_not_wire_single!`).

**Approximate total**: 48 Toffoli (store) + 16 Toffoli (load) + 2 gates (NOT) ≈ **66 Toffoli + NOT**.

### verify_reversibility

Bennett's construction undoes forward gates, so the guarded-store tape returns to zero. The shared result-wire allocation for loads is on fresh (zero) wires; the CNOT fan-out XORs at most one origin's bits in (by mutual exclusion). When the Bennett reverse replays, each guarded Toffoli inverts cleanly because `g_i` is a path predicate wire whose value at reverse time matches forward time. **Reversibility holds** by the same argument that makes M2c's guarded shadow store reversible.

### Regression

- **Single-origin pointers**: `ptr_origins[ptr].length == 1 && isempty(guard_wires)` → goto legacy path. Byte-identical to today. **i8 adder = 100 gates** preserved.
- **i16 / i32 / i64 adders**: no pointer phi/select, no `ptr_origins` entries, legacy path. Preserved.
- **soft_fma, soft_exp_julia**: soft-float has no pointer phi/select (inputs are i64-packed by-value through the call boundary). Preserved.
- **MUX EXCH W=8**: single-origin load, preserved.

---

## 9. Fallback — when MemSSA is OFF

**Path**: `_compile_ir` in `test_memory_corpus.jl` uses `_module_to_parsed_ir` directly. `parsed.memssa === nothing`. `ctx.memssa === nothing`.

**Behavior**: §5's local dataflow (the authoritative correctness path) runs regardless. `_memssa_collapse_origins!` returns `origins` unchanged. Store/load fan-out emits guarded primitives. L7c/L7d compile and verify identically to the MemSSA-ON case.

**This is why MemSSA is "optimization + cross-check" rather than "authoritative"**: the correctness layer must work with textual-IR tests that don't run MemSSA, and we must not force `use_memory_ssa=true` as a prerequisite (cost + R2 brittleness).

**When MemSSA IS on (e.g. for SHA-256, future opt-in)**: collapse-to-single-origin optimization fires, potentially reducing Toffoli count on larger programs. This is the PRD's secondary headline (40% SHA-256 drop).

---

## 10. Risks and failure modes

### R-A: MemSSA text-parse brittleness (PRD R2)

**Mitigation**: MemSSA disambiguation is optimization-only. Correctness does not depend on the parse. Ship M2b with MemSSA consulted but origins never collapsed (TODO stub); file a follow-up to wire the line-map with a regression fixture per `docs/memory/memssa_investigation.md` §R1.

### R-B: LLVM version drift in opaque pointers

**Mitigation**: `rt isa LLVM.PointerType` is a stable LLVM.jl type check, documented since LLVM.jl 9.0. If a future LLVM.jl renames `PointerType`, the ir_extract handler throws loudly at the first test run; the fix is to update one `isa` check.

### R-C: False-path sensitization (CLAUDE.md §Phi Resolution)

This is the central correctness worry. Two cases:

1. **Guard wires not mutually exclusive**: would cause double-writes or XOR-blended loads. Invariant: per-origin guards are conjunctions of path predicates. M2c's `_compute_block_pred!` guarantees `block_pred[L] ∧ block_pred[R] = 0` for diamond branches via OR-of-incoming semantics. For select: `cond ∧ NOT cond = 0` trivially.

2. **Nested pointer phi through non-diamond CFGs**: a loop-back-edge phi, or a phi-of-phi. M2b scope: **reject with fail-fast error**. Check in `lower_phi!` (pointer case): if any incoming block is a loop header OR the `block_pred` is empty (implies unresolved predecessor), `error()` with "nested pointer phi across non-diamond CFG is deferred to M4+".

**Test**: add a corpus case L7f (RED → @test_throws) for nested ptr phi, so we don't silently regress when M4 lands.

### R-D: Dominance correctness

Pointer phi in L7c: is `%a` definitely live at J (where `%p` is used)? Yes — `%a = alloca` is in `top`, which dominates J. If someone writes pathological IR where an alloca is defined *inside* a branch arm, our extractor sees the IRAlloca in that arm and `ptr_origins[alloca]` has `guard_wires` from that arm's predicate, propagating correctly. The sole bad case is "alloca used before defined" (illegal LLVM IR) — we fail at `ctx.alloca_info` lookup.

### R-E: Multi-origin fan-out scale

For a pointer phi with N incoming values each carrying M origins (N·M total), store fan-out is N·M guarded writes. For deeply nested phi chains this explodes. M2b scope is L7c/L7d (N=2, M=1 each). Add an assert: `length(origins) ≤ 8` → error("ptr phi fan-out $L exceeds M2b budget; file a bd issue"). Future work can introduce a MUX-tree to collapse fan-out.

### R-F: `ptr_origins` lifetime

Same gotcha as M2a's `ptr_provenance` — must be per-function not per-block. Allocate in `lower()` (adjacent to `ptr_provenance`), thread through `lower_block_insts!` kwargs. This is literally the same pattern M2a already established, so the risk is just "don't forget to do it".

---

## 11. What I won't do (explicit deferrals)

- **Do NOT MUX pointers as bit-vectors.** Tempting (reuse `lower_mux!`), wrong (pointers aren't wires in our IR).
- **Do NOT extend `_type_width` to handle pointer types.** Keeps a sharp boundary between "widthful" and "routing-decision" operands.
- **Do NOT materialize pointer values on wires.** Pointers remain metadata-only in `ptr_origins`. Any attempt to `resolve!` a pointer operand errors loudly.
- **Do NOT implement nested pointer phi / phi-of-phi across non-diamond CFGs.** Hard-error with message. M4 scope.
- **Do NOT implement pointer phi with a non-alloca origin** (e.g. global ptr, ptr parameter). Hard-error. L7c/L7d use only alloca origins.
- **Do NOT wire MemSSA line-map in this milestone.** Ship with MemSSA consulted but not-yet-collapsing. File follow-up.
- **Do NOT replace `ptr_provenance` entirely.** Leave as fast single-origin path. Avoids regressions.
- **Do NOT handle dynamic-idx through pointer phi.** `o.idx_op.kind == :const` required. Dynamic-idx fan-out is a doubly-quadratic blowup (N origins × M MUX-EXCH variants); defer.
- **Do NOT attempt cross-function pointer-phi resolution** (e.g. pointer passed into a callee). Out of scope; the IRCall lowering handles by-value only.

---

## 12. Cost estimate — lines changed

| File | Lines changed | Description |
|---|---:|---|
| `src/ir_types.jl` | +8 | New `PtrOrigin` struct |
| `src/ir_extract.jl` | ~12 | Pointer-typed phi/select: return IRPhi/IRSelect with `width=0` |
| `src/memssa.jl` | ~30 | `inst_line_map` builder (TODO stub for M2b; full wire-up post-M2b) |
| `src/lower.jl` — LoweringCtx | +3 fields, +1 constructor arity | `memssa`, `ptr_origins`, constructor |
| `src/lower.jl` — `lower()` + `lower_block_insts!` | ~10 | Allocate/thread `ptr_origins` + `memssa` |
| `src/lower.jl` — `lower_phi!` | +25 | Pointer-phi branch with origin merge |
| `src/lower.jl` — `lower_select!` | +25 | Pointer-select branch |
| `src/lower.jl` — `lower_store!` + `_lower_store_multi!` | +40 | Multi-origin dispatch + fan-out |
| `src/lower.jl` — `lower_load!` + `_lower_load_multi!` | +30 | Multi-origin dispatch + fan-out |
| `src/lower.jl` — `_reduce_and!`, `_not_wire_single!` helpers | +15 | Guard-wire utilities (AND-of-k, NOT-single) |
| `src/lower.jl` — `lower_alloca!`, `lower_ptr_offset!`, `lower_var_gep!` | ~6 | Mirror updates to `ptr_origins` |
| `src/lower.jl` — `_memssa_collapse_origins!` | +15 | MemSSA optimization layer (stub for M2b) |
| `test/test_memory_corpus.jl` — L7c, L7d | ~40 replace | Flip `@test_throws` to GREEN: verify_reversibility + exhaustive-sweep |
| `test/test_memory_corpus.jl` — L7f (new) | +20 | Nested pointer phi RED regression pin |

**Total**: ~250 lines of net change across 4 source files + 1 test file, plus follow-up-issue filing for MemSSA line-map. Firmly in "one focused session" per memssa_investigation.md sizing.

---

## Appendix — decision summary

| Question | Decision | Reason |
|---|---|---|
| Extend `_type_width` or bypass? | Bypass at call site with `width=0` sentinel | Pointer width is not a real bit count; sentinel detected once in `lower_phi!`/`lower_select!` |
| New IR structs for ptr-phi/ptr-select? | No — `width=0` sentinel on existing `IRPhi`/`IRSelect` | Avoids surgery across 15+ consumer sites |
| Replace `ptr_provenance` with `ptr_origins`? | Augment (both coexist) | Backward-compat + single-origin fast path preserves gate counts |
| MemSSA authoritative or advisory? | Advisory (optimization + cross-check) | Correctness must work on textual-IR tests with MemSSA off |
| Pointer phi/select emit gates? | No — metadata only | Pointers are routing decisions, not wire-materialized values |
| Multi-origin store strategy? | Path-guarded fan-out, reusing M2c primitives | Mutual exclusion of path predicates makes fan-out safe; no new reversibility proof needed |
| Multi-origin load strategy? | Per-origin guarded CNOT-copy into shared result | Symmetric with fan-out store; zero-initialized result ensures clean XOR accumulation |
| Fallback when MemSSA off? | Local dataflow (authoritative) | Required for `_compile_ir` textual tests; simpler, version-stable |
| Scope for non-diamond nested ptr phi? | Fail-fast error | CLAUDE.md §Phi Resolution warns on this; M2b stays within diamond safety envelope |
