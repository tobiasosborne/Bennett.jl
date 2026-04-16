# M2b Consensus — Orchestrator Synthesis

**Milestone**: Bennett-cc0 / Bennett-tzb7 / M2b — pointer-typed phi/select.
**Date**: 2026-04-16.
**Input**: `docs/design/m2b_proposer_A.md` (path-predicate-first) and
`docs/design/m2b_proposer_B.md` (MemSSA-wired).

## Synthesis

Both proposers converge on the same correctness story:

- phi/select of pointer type emit **zero gates for the routing itself** — metadata only.
- `ptr_provenance` grows to **multi-origin**; each origin carries a predicate wire.
- `lower_store!` and `lower_load!` fan out into N guarded `emit_shadow_store_guarded!` /
  guarded CNOT-copy calls, reusing M2c path-predicate machinery.
- Single-origin fast path preserves every BENCHMARKS.md baseline.

They diverge on:

| Axis | A | B | Consensus |
|---|---|---|---|
| ir_extract representation | new `IRPtrPhi`/`IRPtrSelect` structs | sentinel `width=0` on existing `IRPhi`/`IRSelect` | **B** — smaller blast radius, `IRPhi`/`IRSelect` used at ~6 sites verified by grep |
| ptr_provenance value type | `Vector{PtrOrigin}` (replaces Tuple) | dual maps (`ptr_provenance` + new `ptr_origins`) | **A** — single source of truth |
| per-origin predicate | `predicate_wire::Int` (eager AND) | `guard_wires::Vector{Int}` (lazy AND) | **A** — simpler reasoning; laziness isn't needed for L7c/L7d |
| MemSSA wiring | deferred | advisory stub (line-map TODO) | **Skip entirely** — M2a lesson: MemSSA addresses only 1 of 3 sub-issues; save ~45 LOC and sidestep PRD R2 |
| New IR structs | IRPtrOrigin + IRPtrPhi + IRPtrSelect | PtrOrigin only | **Just `PtrOrigin`** (B) |

## Chosen design

### 1. Extraction (`src/ir_extract.jl`)

Sentinel `width=0` for pointer-typed phi/select. ~12 lines added:

```julia
# select handler ~line 680
if opc == LLVM.API.LLVMSelect
    ops = LLVM.operands(inst)
    rt  = LLVM.value_type(inst)
    w   = rt isa LLVM.PointerType ? 0 : _iwidth(inst)
    return IRSelect(dest, _operand(ops[1], names),
                    _operand(ops[2], names), _operand(ops[3], names), w)
end

# phi handler ~line 687
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

Do NOT touch `_type_width` or `_iwidth` — they remain fail-loud for
unexpected ptr uses elsewhere (`load`, `alloca` have their own paths).

### 2. IR types (`src/ir_types.jl`)

Add one struct:

```julia
struct PtrOrigin
    alloca_dest::Symbol   # which alloca this origin points into
    idx_op::IROperand     # element index within that alloca
    predicate_wire::Int   # path predicate; 1-wire. For the entry-block trivial
                          # case, this is ctx.block_pred[entry_label][1].
end
```

No new IR instruction types. `IRPhi.width = 0` and `IRSelect.width = 0`
are the ptr discriminator.

### 3. LoweringCtx (`src/lower.jl:64`)

Change field type:

```julia
# WAS
ptr_provenance::Dict{Symbol, Tuple{Symbol,IROperand}}
# NOW
ptr_provenance::Dict{Symbol, Vector{PtrOrigin}}
```

No `ptr_origins` second-map. Single source of truth.

Constructor path (line ~576-586): unchanged signature, just the value
type changes. Default initializer is `Dict{Symbol,Vector{PtrOrigin}}()`.

### 4. Provenance producers

All sites that previously stored a single tuple now push a 1-vector.
Single-origin equivalence: the `predicate_wire` is set to
`ctx.block_pred[ctx.entry_label][1]` — the always-1 entry predicate
already used by M2c's fast path.

Sites to update (in order of discovery):

- `lower_alloca!` (~line 1803): `ptr_provenance[dest] = [PtrOrigin(dest, iconst(0), entry_pred_wire)]`.
- `lower_ptr_offset!` (~line 1459): map over `origins`, bumping each `idx_op`.
- `lower_var_gep!` (~line 1493): map over `origins`, replacing each `idx_op` with the GEP index (uniform across origins).

### 5. `lower_phi!` / `lower_select!` — width=0 branch

Both functions branch at the top on `inst.width == 0`:

```julia
function lower_phi!(gates, wa, vw, inst::IRPhi, phi_block::Symbol, ...;
                    ptr_provenance, block_pred, branch_info, ...)
    if inst.width == 0
        # Pointer-typed phi: metadata-only.
        result = PtrOrigin[]
        for (val, src_block) in inst.incoming
            val.kind == :ssa ||
                error("lower_phi!: ptr-phi from non-SSA operand %$(val)")
            haskey(ptr_provenance, val.name) ||
                error("lower_phi!: ptr-phi incoming %$(val.name) has no provenance")
            edge_pred = _edge_predicate!(gates, wa, src_block, phi_block,
                                         block_pred, branch_info)
            for o in ptr_provenance[val.name]
                combined = _and_wire!(gates, wa, o.predicate_wire, edge_pred)
                push!(result, PtrOrigin(o.alloca_dest, o.idx_op, combined))
            end
        end
        isempty(result) &&
            error("lower_phi!: ptr-phi $(inst.dest) produced empty origin set")
        ptr_provenance[inst.dest] = result
        return nothing    # NO wires allocated, NO vw[inst.dest] entry
    end
    # ... existing integer-typed path (unchanged) ...
end

function lower_select!(gates, wa, vw, inst::IRSelect; ctx=nothing)
    if inst.width == 0
        ctx !== nothing ||
            error("lower_select!: ptr-select requires ctx for ptr_provenance threading")
        cw = resolve!(gates, wa, vw, inst.cond, 1)[1]
        not_cw = _not_wire!(gates, wa, cw)
        result = PtrOrigin[]
        for (side, guard) in ((inst.op1, cw), (inst.op2, not_cw))
            side.kind == :ssa || error("lower_select!: ptr-select non-SSA side")
            haskey(ctx.ptr_provenance, side.name) ||
                error("lower_select!: ptr-select side %$(side.name) has no provenance")
            for o in ctx.ptr_provenance[side.name]
                combined = _and_wire!(gates, wa, o.predicate_wire, guard)
                push!(result, PtrOrigin(o.alloca_dest, o.idx_op, combined))
            end
        end
        ctx.ptr_provenance[inst.dest] = result
        return nothing
    end
    # ... existing integer-typed path ...
end
```

Factor `_edge_predicate!` out of `resolve_phi_predicated!`'s existing
loop (pure refactor; cleanest co-located).

### 6. `lower_store!` / `lower_load!` — multi-origin fan-out

Single-origin fast path (preserves every BENCHMARKS.md baseline):

```julia
function lower_store!(ctx::LoweringCtx, inst::IRStore, block_label::Symbol=Symbol(""))
    inst.ptr.kind == :ssa || error("lower_store!: constant pointer unsupported")
    haskey(ctx.ptr_provenance, inst.ptr.name) ||
        error("lower_store!: no provenance for ptr %$(inst.ptr.name)")
    origins = ctx.ptr_provenance[inst.ptr.name]

    if length(origins) == 1
        # Fast path — byte-identical to pre-M2b. Entry-block guard bypass
        # (M2c's entry_label check) still applies.
        o = origins[1]
        return _lower_store_single_origin!(ctx, inst, o, block_label)
    end

    # Multi-origin: N guarded shadow-stores, one per origin.
    for o in origins
        info = get(ctx.alloca_info, o.alloca_dest, nothing)
        info === nothing && error("lower_store!: unknown alloca %$(o.alloca_dest)")
        strategy = _pick_alloca_strategy(info, o.idx_op)
        strategy == :shadow ||
            error("lower_store!: multi-origin ptr with dynamic idx NYI (filed as Bennett-M2b-x)")
        _lower_store_via_shadow_guarded!(ctx, inst, o.alloca_dest, info,
                                         o.idx_op, o.predicate_wire)
    end
    return nothing
end
```

Where `_lower_store_single_origin!` wraps the existing
pre-M2b logic (dispatch on strategy, respect entry_label for guard bypass).

Load analogue — single-origin fast path, multi-origin uses a fresh
zero-initialised result wire block and emits
`ToffoliGate(o.predicate_wire, primal_slot[i], result[i])` per origin per bit.

### 7. Narrowing guard (`src/Bennett.jl:115`, `:120`)

`_narrow_inst(IRPhi/IRSelect, W)` is called to narrow widths inside
whole-function primitive compilation. Since `inst.width = 0` for
ptr-phi/select, add an explicit guard:

```julia
_narrow_inst(inst::IRSelect, W::Int) = inst.width == 0 ? inst :
    IRSelect(inst.dest, inst.cond, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRPhi, W::Int) = inst.width == 0 ? inst :
    IRPhi(inst.dest, inst.width > 1 ? W : 1, inst.incoming)
```

### 8. ir_parser.jl (legacy regex)

`src/ir_parser.jl:100`, `:113` — leave untouched. It's legacy
(CLAUDE.md `ir_parser.jl` = legacy regex, ir_extract.jl is source of truth).
A ptr-phi pattern appearing through the parser path would fail upstream
on width parsing; not in scope for M2b.

### 9. Tests

Flip `test/test_memory_corpus.jl`:
- L7c `@test_throws Exception` → GREEN sweep:
  ```julia
  c = _compile_ir(ir, ["i8", "i1"])
  @test verify_reversibility(c)
  for x in Int8(-8):Int8(2):Int8(8), cbit in (false, true)
      @test simulate(c, (x, cbit)) == x
  end
  ```
- L7d same.
- Optionally pin a regression L7c2 single-origin ptr-phi for
  the fast-path invariant.

### 10. Cost estimate

| File | Net LOC |
|---|---:|
| `src/ir_types.jl` | +8 |
| `src/ir_extract.jl` | +10 |
| `src/lower.jl` — LoweringCtx + producers | +30 |
| `src/lower.jl` — `lower_phi!` / `lower_select!` ptr branch | +60 |
| `src/lower.jl` — `lower_store!` / `lower_load!` fan-out + helpers | +70 |
| `src/Bennett.jl` — `_narrow_inst` guards | +2 |
| `test/test_memory_corpus.jl` — L7c/L7d flip | +20 |
| **Total** | **~200** |

### 11. Invariants (non-negotiable, CLAUDE.md §6)

After implementation, the following must still be byte-identical:
- i8 adder = 100 gates / 28 Toff
- i16 = 204 / 60 Toff
- i32 = 412 / 124 Toff
- i64 = 828 / 252 Toff
- soft_fma = 447,728 / 148,340 Toff
- soft_exp_julia = 3,485,262 / 1,195,196 Toff
- Shadow W=8 = 24 CNOT / 0 Toff
- All `soft_mux_*` variants byte-identical to BENCHMARKS.md.

Test runner must pass the entire existing suite unchanged.

### 12. What this does NOT do (explicit deferrals)

- MemSSA wiring — file follow-up `bd` issue.
- Multi-origin dynamic-idx (`strategy != :shadow` with >1 origin) —
  file follow-up issue (hard-errors clearly).
- N ≥ 3 origin chains — design handles N structurally but corpus
  covers N=2 only. Add a guard `length(origins) ≤ 8` with error.
- Nested pointer-phi across non-diamond CFG (loop-back ptr-phi) —
  hard-error with message pointing at follow-up issue.
- Pointer arithmetic across phi boundaries with non-const offset —
  hard-error. Non-trivial; defer.

### 13. Implementer flow

1. RED: flip L7c to GREEN sweep — should fail at extraction.
2. Add `PtrOrigin` to `ir_types.jl`.
3. Extraction fix (width=0 sentinel). Re-run L7c — should now fail in
   `lower.jl` with "no provenance for ptr" or similar, meaning
   extraction passed but lowering isn't wired yet.
4. Change `LoweringCtx.ptr_provenance` value type + thread through
   `lower()` + `lower_block_insts!` constructors.
5. Update `lower_alloca!` / `lower_ptr_offset!` / `lower_var_gep!` to
   populate Vector{PtrOrigin}.
6. Refactor `_edge_predicate!` out of `resolve_phi_predicated!`.
7. Add ptr branch to `lower_phi!` and `lower_select!`.
8. Add `_lower_store_single_origin!` (wraps existing logic) and
   multi-origin store fan-out.
9. Add load multi-origin fan-out.
10. `_narrow_inst` guards.
11. L7c GREEN. L7d GREEN. `verify_reversibility` passes.
12. Full test suite: `julia --project -e 'using Pkg; Pkg.test()'`.
13. Regenerate BENCHMARKS.md — diff against committed — must be
    byte-identical for the invariants in §11.
14. Update WORKLOG.md per CLAUDE.md §0.
15. Commit as one atomic change per CLAUDE.md Pattern 4 ("Commit + push
    per milestone").
