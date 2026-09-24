# Bennett-stwr — PROPOSER A: make `add=:cuccaro` sound; delete + replace the dead liveness subsystem

> 3+1 protocol, proposer A (independent of B). Produced 2026-09-24 by a read-only
> design agent against HEAD `f7b4bf0`. No repo files modified; the prototype was an
> in-session `@eval` redefinition of `_lower_inst!(::LoweringCtx, ::IRBinOp)`.
> Archived verbatim-in-substance by the orchestrator. Line numbers refer to `f7b4bf0`.

## 0. Summary

The bug is worse than c2-lowering.md A1 says: it is often **silent** (wrong answers,
no error), and the dead `op2_dead` guard would be wrong even if consulted. Proposal:
delete `compute_ssa_liveness`/`ssa_liveness`/`inst_counter`/`inst_idx`; replace with a
small order-free per-block eligibility pass (`_cuccaro_inplace_adds`) plus a lowering-time
wire-exclusivity check; when op2 is not provably dead, **CNOT-copy op2 and run Cuccaro in
place on the copy** ("copy-then-Cuccaro") — no silent ripple fallback, no error.
Prototype: every case below 0 mismatches / 0 exceptions (exhaustive Int8),
`verify_reversibility` true, all existing explicit-`:cuccaro` gate counts byte-identical.

## 1. Reproduction (HEAD f7b4bf0; `add=:cuccaro, optimize=false, fold_constants=false`, exhaustive)

| Function | Current result |
|---|---|
| `(x+y)+y` | 182 gates (NOT 2, CNOT 128, Toffoli 52). **255 silent wrong** (first (-128,-128): got 0, want -128) + **65,280 throws** `input wire 9 changed from true to false — Bennett input-preservation invariant violated` |
| `x+x` (IR `add %x, %x`) | 255/256 throw `input wire 8 changed …` |
| `c ? y : x+y` (return-merge CFG, 2 rets) | **65,280 silent wrong**, 0 exceptions |
| `(c ? x+y : x-y)+y` (diamond + phi) | **130,560 silent wrong** |
| `c ? x+y : y+x` | 65,280 silent wrong |
| `loopf`: `m=n&3; y=x+m; while i<m; s+=y; i+=1; end; s` (K=4) | 25,344 silent wrong + 31,488 loud non-convergence (m clobbered before the loop header reads it) |
| hand-written `.ll`: `%g = gep %p, i8 %j; %s = add %x, %j; %v = load %g` | **49,088 silent wrong** |

`:ripple`/`:qcla` correct on all. `(x,y)->x+y` with `:cuccaro` correct (96 gates, 26 wires):
clobbering input `y` in the forward pass is restored by Bennett's reverse pass.

## 2. Root cause

1. **A1.** `_pick_add_strategy` (arith.jl:20-26) returns `:cuccaro` without consulting `op2_dead`;
   `lower_add_cuccaro!` (adder.jl:64) overwrites and returns `b`, so `vw[dest]` aliases `vw[op2]`.
2. **op1 === op2** ⇒ `a`,`b` same wires ⇒ MAJ/UMA garbage even when x is dead. No precondition check.
3. **A2 — guard wrong even if consulted.** `compute_ssa_liveness` (operand.jl:116-146): terminators
   counted, source order. `inst_counter`: skips terminators, topo order (driver.jl:531), and is bumped per
   unrolled iteration + convergence pass (cfg.jl:281,319,395) ⇒ ~K-fold inflated after a loop ⇒ every
   post-loop value looks dead (unsound direction).
4. **Per-path SSA liveness is the wrong notion for a flattened circuit (every block executes).** Deferred readers:
   - `ret` operands captured at the terminator (driver.jl:309), read by the final multi-ret merge MUX / copy-out
     (`c ? y : x+y`: the L3 add is y's last use in any index space, yet the merge reads y at the end);
   - branch conditions in `branch_info` (i1; Cuccaro W≤1 falls back to ripple anyway);
   - `ptr_provenance`: `lower_var_gep!` stores the SSA *index operand* in `PtrOrigin.idx_op`
     (aggregate.jl:330,350) and every later load/store re-resolves it (memory.jl:871,929,1005); the load's
     `_ssa_operands` lists only `ptr` ⇒ invisible to use-list analysis;
   - wire aliasing across SSA names: single-incoming phi returns incoming wires (phi.jl:146); `lower_ptr_offset!`
     slices the base (aggregate.jl:235); `vw[alloca]` rebinding (memory.jl:432,1068); mux-load `tmp` slice
     (memory.jl:1011); the Cuccaro result itself. Hand-built `p = phi[y]; s = x + p; t = s xor y`: even perfect
     SSA deadness + in-place ⇒ 65,280 silent wrong; the exclusivity check fixes it;
   - loops (back-edges, K-fold re-lowering, freeze MUX) — loop context already forces `:ripple` (cfg.jl:237-261).

## 3. Investigation facts

- `:auto` never selects Cuccaro; `target=:depth` affects only `mul`; callees lowered with default `add`
  (call.jl:96); loop context forces `:ripple`. Cuccaro is reached only by explicit `add=:cuccaro` on non-loop blocks.
- Tests touching `:cuccaro`: test_add_dispatcher (x+1), test_spa8 (x+y ≠ ripple; depth ≥1.5× auto),
  test_add_mul_cross (`x*y+x+y`), test_y986 T5 (loop ⇒ ripple), test_op6a / test_gboa (primitive-level).
  `test_cuccaro_safety.jl` never passes `add=:cuccaro` (no teeth). `test_liveness.jl` calls
  `compute_ssa_liveness`. test_fidj / test_value_eager / test_pebbled_wire_reuse / benchmarks pass `use_inplace=`.
- No pinned baseline covers explicit-`:cuccaro` with an SSA op2 at an exact count.
- Clobbering an INPUT wire is sound under all current strategies (tested `x+y`, `x*y+x+y`, `(x+1)+(y+2)`,
  `x+y+x`, `(x+y)+y` fold_constants=false under Default/Eager/ValueEager/Checkpoint/Pebbled(40,200)/
  PebbledGroup(4)): in-place group detected (07r path) ⇒ fallback to plain Bennett; reverse restores input.
  `PebbledStrategy(4)` throws "insufficient pebbles" (unrelated).

## 4. Fix

### 4a. `src/lowering/operand.jl`
Delete `compute_ssa_liveness` (lines 73, 106-146). Add:

```julia
"""
    _cuccaro_inplace_adds(parsed::ParsedIR) -> Set{Symbol}
Bennett-stwr. Dest names of IRBinOp(:add) whose SSA op2 = v may be overwritten in place.
v qualifies iff (1) v is not also op1; (2) every operand occurrence of v lies in the add's own
block at position <= the add's, exactly one at the add; (3) no terminator reads v (recorded at
typemax(Int)); (4) v is not an IRVarGEP index / IRAlloca n_elems (ptr_provenance re-resolves it).
Wire aliasing is decided at lowering time by `_cuccaro_op2_exclusive`. Loop bodies never consult this.
"""
function _cuccaro_inplace_adds(parsed::ParsedIR)
    uses   = Dict{Symbol, Vector{Tuple{Symbol,Int}}}()
    pinned = Set{Symbol}()
    for blk in parsed.blocks
        for (pos, inst) in enumerate(blk.instructions)
            for v in _ssa_operands(inst)
                push!(get!(() -> Tuple{Symbol,Int}[], uses, v), (blk.label, pos))
            end
            inst isa IRVarGEP && inst.index   isa SSAOperand && push!(pinned, inst.index.name)
            inst isa IRAlloca && inst.n_elems isa SSAOperand && push!(pinned, inst.n_elems.name)
        end
        for v in _ssa_operands(blk.terminator)
            push!(get!(() -> Tuple{Symbol,Int}[], uses, v), (blk.label, typemax(Int)))
        end
    end
    ok = Set{Symbol}()
    for blk in parsed.blocks, (pos, inst) in enumerate(blk.instructions)
        (inst isa IRBinOp && inst.op === :add && inst.op2 isa SSAOperand) || continue
        v = inst.op2.name
        v in pinned && continue
        (inst.op1 isa SSAOperand && inst.op1.name === v) && continue
        us = uses[v]
        count(==((blk.label, pos)), us) == 1 || continue
        all(u -> u[1] === blk.label && u[2] <= pos, us) || continue
        push!(ok, inst.dest)
    end
    return ok
end
```
Optional: `_ssa_operands` methods for `IRMapInsert`/`IRMapGet`/`IRMapDelete` (missing today; VM-only).

### 4b. `src/lowering/arith.jl`
`_pick_add_strategy(user_choice::Symbol, W::Int)` (drop dead args). `lower_binop!`: replace
`ssa_liveness`/`inst_idx` kwargs with `cuccaro_inplace::Set{Symbol}=Set{Symbol}()`; delete `op2_dead`;
Cuccaro branch → `_lower_add_cuccaro_dispatch!(gates, wa, vw, inst, a, b, W, cuccaro_inplace)`:

```julia
_cuccaro_op2_exclusive(vw, v::Symbol, b::Vector{Int}) =
    !any(k !== v && !isdisjoint(ws, b) for (k, ws) in vw)

function _lower_add_cuccaro_dispatch!(gates, wa, vw, inst::IRBinOp, a, b, W, inplace_ok::Set{Symbol})
    W <= 1 && return lower_add_cuccaro!(gates, wa, a, b, W)
    target = if inst.op2 isa ConstOperand
        b
    elseif inst.dest in inplace_ok && _cuccaro_op2_exclusive(vw, inst.op2.name, b)
        delete!(vw, inst.op2.name)   # consumed: later by-name read fails loud in resolve!
        b
    else
        _emit_copy_out!(gates, wa, b, W)   # +W CNOT, +W wires, same Toffolis
    end
    return lower_add_cuccaro!(gates, wa, a, target, W)
end
```

### 4c. `src/adder.jl` `lower_add_cuccaro!`
After the W≤1 fallback: `isdisjoint(a, b) || throw(ArgumentError("lower_add_cuccaro!: operand registers alias (a ∩ b ≠ ∅) … (Bennett-stwr)"))`. Rewrite "Caller responsibility".

### 4d. `src/lowering/types.jl`
`LoweringCtx` / `BlockLoweringOpts`: replace `ssa_liveness` + `inst_counter` with `cuccaro_inplace::Set{Symbol}`;
document the contract (any lowering that stores an operand for a deferred read must record the alias in `vw`
or be pinned in `_cuccaro_inplace_adds`). `_lower_inst!(ctx, ::IRBinOp)` passes it.

### 4e. `src/lowering/driver.jl`
`cuccaro_inplace = (add === :cuccaro && use_inplace) ? _cuccaro_inplace_adds(parsed) : Set{Symbol}()`;
thread it; drop the `inst_counter` increment (line 531). Keep `use_inplace` (meaning: `false` ⇒ always copy).

### 4f. `src/lowering/cfg.jl`
Loop ctxs (lines 258, 387) get `Set{Symbol}()`; delete increments at 281/319/395; keep `:ripple` override; fix comment.

### 4g. Docs
pebbled_groups.jl:235 comment; docs/src/reference/strategies.md (`:cuccaro` ancilla "1, +W when op2 must be
preserved"); howto/arithmetic_strategy.md:49; reference/api.md; explanation/architecture.md:119.

## 5. Policy: copy-then-Cuccaro
Rule 1: correct circuit, no corrupt state; only loud failure left is the real aliasing invariant. Rule 6:
explicit `:cuccaro` keeps one meaning — every add is MAJ/UMA, exactly 2W−3 Toffolis, same depth; only CNOT/wire
counts vary by exactly +W per copied add, deterministically. Rejected: ripple fallback (mixes adder families,
silent override); loud error (rejects valid programs; under optimize=true LLVM chooses operand order, e.g.
`x*y+x+y` → `(y+1)*x + y`).

## 6. Delete and replace, not repair
A correct global last-use index must model topo emission + K+1 loop re-lowering, deferred terminator reads,
phi joins, back-edges/freeze MUX, `ptr_provenance` points-to, cross-name wire aliasing — each a silent-unsoundness
site, for an opt-in strategy `:auto` never picks. Block-local criterion + vw exclusivity scan is order-free.
Cost: lost opportunities when other uses are in other blocks (`loopg`: 2067 correct-by-accident → 2099).

## 7. Gate-count impact
All pinned baselines unchanged (`:auto`/`:ripple`/`:qcla`/mul byte-identical — analysis does not run).
Verified identical explicit-`:cuccaro`: `x+y` Int8/16/32/64 = 96/200/408/824 total, Toffoli 26/58/122/250,
wires 26/50/98/194, T-depth 26/58/122/250; `x+1` = 98/202/410/826; `x*y+x+y` (mul auto/shift_add/qcla_tree)
= 554/554/3198. Changes only for non-dead/aliased SSA op2: +2W gates post-Bennett, +W wires per add.
`(x+y)+y` opt=false 182 (wrong) → 198, 35 wires; `x+x` 96 (wrong) → 112, 26 wires; `x+y+x` stays 182/27;
`x+y` use_inplace=false → 112 / 34 wires.

## 8. Red-green test plan
New `test/test_stwr_cuccaro_soundness.jl`. Helper `_sweep(c, f, dom)` counts mismatches + exceptions;
`@test nbad == 0`, `@test verify_reversibility(c)`; compile `add=:cuccaro, optimize=false, fold_constants=false`;
each test asserts its IR shape (rule 5).
RED: (1) `(x+y)+y`; (2) `x+x` (assert op1==op2 in IR); (3) `x+x+x`; (4) `c ? y : x+y` (≥2 IRRet, 131,072 inputs);
(5) `(c ? x+y : x-y)+y` (assert IRPhi); (6) `c ? x+y : y+x`; (7) `loopf` K=4; (8) hand-built phi-alias ParsedIR;
(9) hand-written `.ll` VarGEP case via `_module_to_parsed_ir`; (10) `@test_throws ArgumentError` aliased registers;
(11) unit tests of `_cuccaro_inplace_adds`; (12) make `test_cuccaro_safety.jl` actually pass `add=:cuccaro`;
(13) pins: `(x+y)+y` 198/Toffoli 52; `x+x` 112/Toffoli 26.
GREEN guards: (14) in-place still fires (`x+y` 96/200/408/824, `x+1` 98, `x+y+x` 182/27 wires);
(15) `use_inplace=false` `x+y` 112/34; (16) `loopg` correct; (17) all six strategies on `x+y+x`, `(x+y)+y`;
(18) `:auto` byte-identical to `:ripple`.
Edit: test_liveness.jl (drop 5 `compute_ssa_liveness` testsets; retitle misnamed Cuccaro testsets).

## 9. Risks / follow-ups
Unenumerated deferred readers (mitigated by contract comment, exclusivity scan, `delete!`); positional
`LoweringCtx` constructor (3 call sites); follow-up A: loop context silently forces `:ripple` for explicit
`:cuccaro`/`:qcla` (cfg.jl:259,389); follow-up B: `lower_call!` ignores caller's explicit `add`;
A1's "fails loud" claim is wrong for CFG/loop/memory cases.
