# Bennett-stwr — PROPOSER B: `add=:cuccaro` soundness from first principles

> 3+1 protocol, proposer B (independent of A). Produced 2026-09-24 by a read-only
> design agent against HEAD `f7b4bf0`. No repo files modified; prototype via
> in-memory `@eval Bennett` redefinitions. Archived verbatim-in-substance by the
> orchestrator. Line numbers refer to `f7b4bf0`.

## 0. Summary
Two defects: the picker never consults liveness (and what it would consult is wrong), and
"last use" is the **wrong soundness notion** for this compiler. An in-place adder overwriting
b's wires is sound only if **no other reader of those wires exists anywhere** — lowering is
predicated (every block executes), some Bennett strategies uncompute non-LIFO, and the lowering
aliases wires between SSA names. Proposal: replace index-based liveness with a static,
strategy-independent use-count + exclusive-wire-ownership criterion; in-place target op2 (or op1
by commutativity); otherwise run Cuccaro on a private CNOT copy of op2 (copy-in); fail-loud
aliasing assert in `lower_add_cuccaro!`. In-memory prototype fixes every red case under all six
strategies, fixes silently-wrong `soft_fadd` under `add=:cuccaro`, leaves every pinned `:cuccaro`
count unchanged.

## 1. Reproduction
`(x+y)+y` (`optimize=false, fold_constants=false`): compiles, 182 gates (NOT 2, CNOT 128,
Toffoli 52); 65535/65536 inputs fail. IR `%__v1 = add x, y; %__v2 = add %__v1, y`. `lower()`
emits 20 self-targeting gates, first `CNOTGate(9, 9)`; `output_wires == y's input wires [9..16]`.
The second add gets `a === b`, emitting irreversible `CNOT(w,w)` — why this repro is loud.
**Most instances are silent:** `reversible_compile(Bennett.soft_fadd, UInt64, UInt64; add=:cuccaro)`:
CURRENT 66074 gates, **29/30 random inputs WRONG, 0 simulator errors**; PROTOTYPE 65758 gates, 0/30 wrong.

Failure matrix (bad inputs /65536; `lower(p; add=:cuccaro, fold_constants=false)` then strategies
[Default, ValueEager, Eager, Checkpoint, PebbledGroup(4), Pebbled(40)]):

| case | IR shape | CURRENT | naive fix¹ | PROTOTYPE |
|---|---|---|---|---|
| `(x+y)+y` opt=false | straight-line op2 reuse | all 65535 | 0 | all 0 |
| `lp` (loop, then `t=s+y; t+y`), K=4 | post-loop code | all 65535 | **still broken** (4335 err + 16 wrong, 256×17 subset) | all 0 |
| `d2`: `r = x>0 ? x+y : y; r+y` | diamond + phi uses y | all 65024 | – | all 0 |
| `d3`: `x>0 ? (y⊻3) : (x+y)` | y used in sibling branch emitted later | Default 32512 | – | 0 |
| `h`: `u=y&x; t=x+y; u⊻t` | y read BEFORE the add | **ValueEager 65280**, others 0 | ValueEager still broken | all 0 |
| `d1` opt=true (select) | same as h | ValueEager 65280 | – | all 0 |
| `(x+x)+y` | op1 === op2 | all 65280 | – | all 0 |
| hand-built `%p = phi [%y, entry]; %t = add x,%p; %u = add %t,y` | single-incoming phi aliases y | all 65535 | – | 0 |
| `x+x`, `x+x+x` Int8 | a === b | 255/256 | – | – |

¹ making `_pick_add_strategy` honour the existing `op2_dead`.

## 2. Root cause (A1/A2 correct but incomplete)
- **R1** picker ignores liveness; `lower_add_cuccaro!` returns `b` ⇒ `vw[dest]` aliases `vw[op2]`.
- **R2** index spaces disagree (source order + terminators vs topo order, no terminators), and
  `lower_loop!` increments `inst_counter` per unrolled iteration + convergence re-lowering
  (cfg.jl:281,319,395) ⇒ post-loop code sees inflated `inst_idx` ⇒ live values look dead (`lp` row).
- **R3** last-use liveness is the wrong criterion even with a consistent index space:
  predicated lowering (`d3`: topo order `[top, L5(add), L3(y⊻3)]` — sibling reads y after overwrite;
  CFG dataflow liveness makes the same mistake); **non-LIFO uncompute** (ValueEager Phase 3 reverses
  groups in reverse-topological SSA-DAG order — in `h` the group `u = y&x` is replayed after y was
  overwritten); wire aliasing (`resolve_phi_predicated!` returns `incoming[1][1]` for single-incoming
  phis, phi.jl:146; `lower_loop!` seeds header phis with `resolve!(pre_val)`, cfg.jl:208); deferred
  readers (`branch_info`, `ret_values`, `PtrOrigin.idx_op`); `a === b`/overlap ⇒ `CNOT(w,w)`/`Toffoli(c,w,w)`.
- Verified non-issues: casts, shifts, identity peephole, `lower_mux!`, loads, extractvalue, call
  results return fresh wires; `_cond_negate_inplace!` touches private copies; memory stores write alloca
  primal wires but loads copy out; callees lowered with `add=:auto` and CNOT-copied args (call.jl:97,138);
  loop contexts already force `:ripple` with empty liveness (cfg.jl:258,384).

## 3. Soundness condition
Lowering `z = a + b` overwriting `B = wires(b)` is sound iff
- **S1** `B ∩ wires(a) = ∅`, no duplicate wires in `B`;
- **S2 (exclusive reader)** for every SSA value v (args, IR values, lowering-internal names) whose wires
  intersect B, the ONLY reader of v in the whole forward gate sequence is this add — counting all blocks,
  phi incomings, br/switch/ret operands, deferred readers, and dynamic multiplicity (an operand of an
  instruction the unroller lowers K+1 times is read K+1 times). S2 (not "no later reader") makes it sound
  under EVERY strategy: every uncompute schedule reverses the add's group before b's defining group, and no
  other group needs B to hold b;
- **S3** B's prior content is a function input (restored by the reverse pass), fresh constant wires, or a
  value defined by an earlier group.

Static sufficient check — operand `op` is an **in-place target** iff `op isa ConstOperand`, or `op = %v` with
(i) exactly ONE operand occurrence of %v in the whole ParsedIR (all instructions + terminators; implies
op1 ≢ op2); (ii) %v is a function argument or defined by
`_INPLACE_FRESH_DEFS = Union{IRBinOp, IRCast, IRSelect, IRICmp, IRCall, IRExtractValue, IRLoad}` (lowerings
that return fresh wires owned only by %v); `IRPhi` EXCLUDED (aliasing), ptr/alloca defs excluded;
(iii) not in a loop-unrolling context (`iter_ctx`/`conv_ctx` get an empty set).
Sufficiency: every deferred reader is initiated by an IR operand ⇒ (i); every alias is created by a use of %v
(forbidden by (i)) or by %v's own def (forbidden by (ii)); (iii) handles dynamic multiplicity.

## 4. Fix
**operand.jl**
```julia
const _INPLACE_FRESH_DEFS = Union{IRBinOp, IRCast, IRSelect, IRICmp, IRCall, IRExtractValue, IRLoad}

function compute_ssa_use_counts(parsed::ParsedIR)::Dict{Symbol,Int}
    uses = Dict{Symbol,Int}()
    for blk in parsed.blocks
        for inst in blk.instructions, v in _ssa_operands(inst); uses[v] = get(uses, v, 0) + 1; end
        for v in _ssa_operands(blk.terminator); uses[v] = get(uses, v, 0) + 1; end
    end
    return uses   # OCCURRENCES: `add %x, %x` ⇒ uses[x] >= 2
end

function compute_inplace_targets(parsed::ParsedIR)::Set{Symbol}
    uses = compute_ssa_use_counts(parsed)
    t = Set{Symbol}()
    for (n, _) in parsed.args; get(uses, n, 0) == 1 && push!(t, n); end
    for blk in parsed.blocks, inst in blk.instructions
        inst isa _INPLACE_FRESH_DEFS && get(uses, inst.dest, 0) == 1 && push!(t, inst.dest)
    end
    return t
end
```
Add `_ssa_operands` for `IRMapInsert`/`IRMapGet`/`IRMapDelete`. Delete `compute_ssa_liveness`
(rewrite test_liveness.jl §1–5 in the same commit) — preferred over keeping it with a "NOT used" docstring.

**types.jl** `LoweringCtx`/`BlockLoweringOpts`: replace `ssa_liveness` + `inst_counter` (no other consumer)
with `inplace_targets::Set{Symbol}`; `_lower_inst!(ctx, ::IRBinOp)` passes it.

**driver.jl** lazily: `inplace_targets = (use_inplace && add === :cuccaro) ? compute_inplace_targets(parsed) : Set{Symbol}()`;
remove `inst_counter`.

**cfg.jl** `iter_ctx`/`conv_ctx` get `Set{Symbol}()`; drop the three increments; keep `:ripple` override,
comment the real reason (an IR use in the loop is lowered K+1 times).

**arith.jl**
```julia
_pick_add_strategy(user_choice::Symbol, W::Int)
@inline _inplace_ok(::ConstOperand, ::Set{Symbol}) = true
@inline _inplace_ok(op::SSAOperand, t::Set{Symbol}) = op.name in t
@inline _inplace_ok(::IROperand, ::Set{Symbol})     = false
# in lower_binop!:
if strat === :cuccaro
    if W > 1
        ok2 = _inplace_ok(inst.op2, inplace_targets); ok1 = _inplace_ok(inst.op1, inplace_targets)
        if !ok2 && ok1
            a, b = b, a                             # add commutes: write into op1's wires
        elseif !ok2
            b = _emit_copy_out!(gates, wa, b, W)    # copy-in
        end
    end
    lower_add_cuccaro!(gates, wa, a, b, W)
```
**adder.jl** `lower_add_cuccaro!` after W≤1: assert `length(a) == W == length(b)`, `isdisjoint(a, b)`
(ArgumentError "… operand wire vectors alias … (Bennett-stwr)"), `allunique(a) && allunique(b)`.
**Docs**: `reversible_compile`/`CompileOptions` `add=:cuccaro` text; pebbled_groups.jl:235; comment in
value_eager.jl on the S2 invariant; phi.jl:146 comment (why IRPhi excluded); `lower_cast!` note (a future
slice-returning trunc must leave `_INPLACE_FRESH_DEFS`); worklog; BENCHMARKS note.

## 5. Policy: copy-in
Error rejected (ordinary code and all soft-float become uncompilable under `:cuccaro`; rule 1 forbids
silent corruption, which copy-in does not produce). Ripple fallback rejected (silently swaps algorithm per
add ⇒ explicit-strategy counts become a hidden mix; strictly worse on wires: ripple 2W wires/2W−2 Toffoli vs
copy-in Cuccaro W+1 wires/2W−3 Toffoli). Copy-in: every add still `lower_add_cuccaro!`; forward 7W−5 gates /
W+1 wires vs in-place 6W−5 / 1. `use_inplace=false` ⇒ always copy-in except constants
(`x+y` Int8 44 → 52 forward).

## 6. Gate-count impact
Unaffected: test_gate_count_regression (no `:cuccaro` pins); test_op6a; test_add_dispatcher `x+Int8(1)` 98 /
Toffoli 26; test_spa8 `x+y` Int16/32/64 = 200/408/824, T-depth 58/122/250; test_add_mul_cross 554 (op1 swap
avoids copies); test_y986 506; test_fidj/test_liveness/test_value_eager/test_pebbled_wire_reuse (`:auto`);
BENCHMARKS Cuccaro rows; timing_bench. Changes only when neither operand is const/exclusive single-use:
+W CNOT/+W wires forward (+2W gates post-Bennett). `d1` 169→177, `h` 68→76 (correct-by-luck under Default);
`soft_fadd` 66074→65758 and becomes correct.

Prototype forward counts (fold_constants=false) gates/wires:

| fn | add=:cuccaro | ripple | use_inplace=false |
|---|---|---|---|
| `(x+y)+y` | 87/19 | 77/49 | 103/35 |
| `(x+x)+y` | 95/27 | – | 103/35 |
| `d2` | 213/106 | 187/120 | – |
| `h` | 76/42 | 63/49 | – |
| `d3` | 177/112 | 164/119 | – |
| `x+y` | 44/18 | 39/33 | 52/26 |

## 7. Red-green test plan
New `test/test_stwr_cuccaro_soundness.jl`. Helper: `parsed = extract_parsed_ir(...)`,
`lr = lower(parsed; add=:cuccaro, fold_constants=false)`; assert `lr.n_wires < ripple n_wires` (Cuccaro
fired); for each of the six strategies `bennett(lr; strategy=S)` exhaustive Int8×Int8 `nbad == 0` +
`verify_reversibility`; also end-to-end `reversible_compile(...; add=:cuccaro)` default fold.
Cases (red today, green in prototype): (1) `(x+y)+y`; (2) `(x+x)+y`, `x+x`, `x+x+x`; (3) `d2`; (4) `d3`
(assert topo order `[top, L5, L3]`); (5) `lp` K=4; (6) pre-loop value used once inside loop
(`t=x⊻y; while i<3; a+=t; …`); (7) `h` (red only for ValueEager ⇒ sweep all strategies);
(8) hand-built phi-alias ParsedIR, reference `x+2y`; (9) `soft_fadd` under `add=:cuccaro`, bit-exact vs `x+y`
on ~50 seeded randoms + ±0, ±Inf, NaN, subnormals, overflow.
Unit: `compute_inplace_targets` (`x+y` ⇒ {x,y,…}; `(x+y)+y` ⇒ y∉, x∈; `x+x` ⇒ x∉; no IRPhi dest; no
IRAlloca/IRPtrOffset/IRVarGEP dest); `lower_add_cuccaro!` aliasing `@test_throws ArgumentError`; W=1 unchanged;
policy pins (exact forward counts above). Strengthen misnamed `test_cuccaro_safety.jl` with
`add=:cuccaro, optimize=false` variants.

## 8. Risks
Whitelist drift (future aliasing lowering of a whitelisted type silently reopens the hole; isdisjoint only
catches a/b overlap; optional test-only ownership audit O(|vw|·W)/add); conservatism (values read BEFORE the
add pay +W even under Default — deliberate, LR is strategy-agnostic); pre-existing: adds inside loops still
silently ripple under `:cuccaro` (follow-up bead); follow-up hardening in gates.jl: reject `CNOTGate(c,c)` and
Toffoli target==control at construction (perf check needed); test churn (test_liveness rewrite; `_pick_add_strategy`
signature appears only in comments + test_f6qa prefix list). Rule-2 core change.
