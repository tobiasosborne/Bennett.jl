# Proposal A — Bennett-37w3 — Conjoin store activation with pointer selection at each use

## 1. Root cause (precise, with file:line; what invariant is violated and by whom)

For a store in block B through origin o to slot k, the visible write must be enabled
by `block_pred[B] ∧ o.predicate_wire ∧ (o.idx_op == k)`. Pointer selection answers
**where** a store would write; the block predicate answers **whether** it executes.
On inputs executing a valid store, exactly one origin is selected. Origins need
not cover inputs on which the pointer's defining block is inactive.

`lower_block_insts!` supplies the actual instruction block at
`src/lowering/driver.jl:561`; `src/lowering/types.jl:280` forwards it to
`lower_store!`. The single-origin branch uses that context, but the multi-origin
loop at `src/lowering/memory.jl:615–648` drops it. All three branches use only
`o.predicate_wire`: static shadow at 624–625, shadow-checkpoint at 632–633,
and generated MUX-EXCH at 647–648. The latter two helpers explicitly let
`extern_pred_wire` override block predication at 878–887 and 1051–1064.
Merely passing `block_label` to those helpers would therefore NOT fix the bug.

The pointer producers are not at fault: `src/lowering/arith.jl:558–568` correctly
combines incoming provenance with select c/¬c; `src/lowering/phi.jl:315–319`
combines it with incoming edge predicates. Neither can anticipate later users'
additional branch conditions. Even a correct pointer phi needs use-site guarding.

Independent reproduction, without source changes: inline Julia probes with
`--project --check-bounds=yes --compiled-modules=existing --startup-file=no -O0`.
The F1-shaped ParsedIR and a freshly constructed, `LLVM.verify`-accepted module
both give **64/256 wrong** with folding off and on: x=-127 returns 9 instead of 11.
Dynamic i8 arrays of N=4 and N=16, and a pointer phi followed by the independent
store branch, each also give 64/256 wrong in both modes. Every full-domain
`simulate` sweep passes its ancilla/input assertions; `verify_reversibility`
also passes. Reversible execution can perfectly undo an incorrectly enabled write.

## 2. Blast radius (every caller/path affected; other symptoms this explains; interactions with recent fixes named in the brief)

| Path | Finding |
| --- | --- |
| Static-index shadow store | Affected: guard omits B; initialized a or b can change on the skipped branch. |
| Dynamic shadow-checkpoint store | Affected: current guard is `P_o ∧ eq_k`, missing B. Independently reproduced at N=16, W=8. |
| Dynamic MUX-EXCH store | Affected for every generated shape: the callee receives P_o, not `B ∧ P_o`. Reproduced at N=4, W=8. |
| Selected-pointer loads | No analogous visible-write bug: they read current state into fresh result/scratch wires. See below. |
| Actual persistent slabs | Multi-origin loads/stores are unsupported and fail loudly, rather than performing this incorrect store. |
| Static allocas with `mem=:persistent` | Still use ordinary shape dispatch, so the same three store paths remain affected. |

All supported multi-origin producers reach this loop: select, non-loop pointer
phi, their nested combinations, and GEP provenance that survives the existing
GEP handlers. Repeated origins of the same alloca, with identical or different
indices, are included; their predicates, not alloca identity, distinguish them.
Normal block lowering, loop header/body/check-pass `_lower_inst!` calls
(`cfg.jl:449`, 487, 562), and recursive callee lowering (`call.jl:97`) reach the
same store dispatcher. Read the predicate from the **current ctx**, including an
iteration-local predicate map; do not use a cached function-level map.

`aggregate.jl:421–470` intentionally merges selected loads using P_o alone.
Static loads copy primal bits; dynamic loads compute an independent per-origin
load and merge its result. Neither changes the visible allocation. On B=0 the
speculative result is irrelevant to a well-formed SSA program: consuming stores
must use their own guards and phi/return merges use the CFG predicates. Probes
`if d: v=*select(c,a,b); return phi(v,33)` pass **all 256 inputs**, fold off/on,
for N=1,4,16, with ancilla/input checks and reversibility. Do not add load gating
as part of this fix; this conclusion concerns supported nonvolatile memory,
not arbitrary trapping or effectful reads.

Actual dynamic-n persistent allocas populate `persistent_info`, not `alloca_info`.
Selected persistent stores fail at `memory.jl:617–619`; loads at
`aggregate.jl:429–431`, before persistent helpers. Both refusals were reproduced.
Single-origin persistent stores already MUX post-state against pre-state using B
(`memory.jl:352–369`, 493–523); their conditional store/load controls pass all 256
inputs in both folding modes. Keep the multi-origin refusal, including mixed
static/persistent origin sets; do not accidentally enable partial slab support.

tzb7 introduced origin fan-out; oio4 guarded single-origin shadow stores; cb9y
extended fan-out with external guards to both dynamic arms. Their composition
missed B. c6ex (`b5f6127`) changed CFG/phi validation/seeding, not memory.jl;
preserve its predicates. Independent loop-header activation/check-pass defects
remain. vscb concerns cost/dispatch priority; leave strategy selection unchanged.

## 3. Design (the fix, concretely: data structures / predicates / control flow; pseudo-diff for the load-bearing lines)

Keep `PtrOrigin` unchanged. Add a checked block-predicate lookup and conjunction
helper in `memory.jl`. Compute one guard per origin **at each store**. Never replace
shared provenance: that would restrict later uses to an earlier store's branch.

Reject sentinel labels, absent entry identity, and missing/non-single-wire
predicates. Only the real entry may omit the AND after successful lookup:
`driver.jl:245–252` establishes its wire as constant 1; c6ex forbids entry
predecessors. For other blocks, reuse identical wires (`p ∧ p = p`), otherwise
allocate the conjunction with `_and_wire!`. No context fields change.

```julia
# New private helpers (schematic error strings must identify the store block).
function _store_block_wire(ctx, label)
    label != Symbol("") && ctx.entry_label != Symbol("") ||
        throw(AssertionError("store requires explicit block/entry context"))
    pw = get(ctx.block_pred, label, Int[])
    length(pw) == 1 ||
        throw(AssertionError("store block $label requires one predicate wire"))
    return only(pw)
end
function _store_origin_guard!(ctx, label, bw, ow)
    label == ctx.entry_label && return ow  # checked real entry: B = 1
    bw == ow && return ow
    return only(_and_wire!(ctx.gates, ctx.wa, [bw], [ow]))
end

# lower_store!, after the single-origin return and fan-out limit check:
+ bw = _store_block_wire(ctx, block_label)
  val_wires = resolve!(ctx.gates, ctx.wa, ctx.vw, inst.val, inst.width)
  for o in origins
      # Existing origin/shape checks and strategy choice remain.
+     guard = _store_origin_guard!(ctx, block_label, bw, o.predicate_wire)
      if strategy == :shadow
-         _emit_store_via_shadow_guarded!(..., o.predicate_wire, val_wires)
+         _emit_store_via_shadow_guarded!(..., guard, val_wires)
      elseif strategy == :shadow_checkpoint
-         _lower_store_via_shadow_checkpoint!(..., o.idx_op, Symbol("");
-                                             extern_pred_wire=o.predicate_wire)
+         _lower_store_via_shadow_checkpoint!(..., o.idx_op, block_label;
+                                             extern_pred_wire=guard)
      else
-         fn(ctx, inst, o.alloca_dest, o.idx_op; extern_pred_wire=o.predicate_wire)
+         fn(ctx, inst, o.alloca_dest, o.idx_op;
+            block_label=block_label, extern_pred_wire=guard)
      end
  end
```

Retain the helpers' override behavior, but correct their documentation at
`memory.jl:689`, 850, 876, 1024: `extern_pred_wire` is a **complete store-enable**,
already including the current block predicate, not merely origin selection.
Keep the real label in calls for diagnostics. Resolve/conjoin exactly once at
the fan-out boundary, not redundantly in each backend or once per array slot.
Single-origin dispatch and its established entry fast paths are unchanged.

## 4. Why it is sound (argue the invariant is restored on ALL paths; ancilla hygiene; no false-path sensitisation; effect on gate counts — say whether explicit-strategy baselines in test/test_gate_count_regression.jl can move and why)

For each emitted origin write, G=B∧P_o. If B=0, all G are zero: guarded shadow
leaves both primal and tape unchanged; shadow-checkpoint uses G∧eq_k, also zero;
guarded MUX-EXCH returns its input array for every slot. If B=1, G=P_o and
existing one-origin/one-slot semantics are preserved. Additional outer guards,
false branch edges, nested selects, and phi edge conditions remain conjuncts;
none can be discarded. Entry uses G=P_o because its checked B is identically 1.
Aliased origins remain mutually exclusive on active inputs, so sequential fan-out
does not apply two writes. Refused persistent or malformed-context paths return
no circuit; they do not fall through to an unguarded write.

The AND targets a fresh zero wire and reads stable predicates. Keep it allocated
through the forward computation; never free/uncompute it while consumers use it.
Bennett's reverse undoes consumers before the AND, cleaning guards and tapes.
Output checks remain essential: ancilla checks could not detect the original bug.

Cost before folding: at most one fresh bit and one forward Toffoli per origin
(≤8 per store), doubled to two gates in default Bennett construction. Entry
multi-origin stores keep their previous gate sequence. Some already-correct
non-entry phi stores can gain redundant conjunctions; record that memory cost
rather than claiming universal count identity. Folding can remove constants.
**The explicit-strategy pins in `test/test_gate_count_regression.jl` must not
move**: they cover scalar arithmetic, not this fan-out. Do not refresh those
numbers. No strategy/default changes are proposed; vscb remains separate.

## 5. Alternatives considered and rejected (at least one, with the reason)

- Guard the pointer producer: its own block cannot encode a later store's d;
  modifying shared provenance at the first store also poisons later uses.
- Only pass `block_label`: external guards currently override it in both dynamic
  backends, and the static backend takes only a raw predicate wire.
- Backend-specific conjunction or controlling every generated gate duplicates
  policy and adds unnecessary control/scratch cost to large MUX callees.
- Replace MUX-EXCH with shadow-checkpoint: may address vscb's cost complaint but
  leaves the same missing B in shadow fan-out; it is not a semantic repair.

## 6. Tests (RED-first: the exact test file/cases to add; for Int8 all 256 inputs; verify_reversibility or explicit ancilla checks on every case; which existing test files must be re-run)

Add `test/test_37w3_multi_origin_store_predication.jl`, registered in
`test/runtests.jl`. First run the new semantic regressions on unmodified lowering
and observe their failures, then implement. Use the named review's ParsedIR and
this minimal in-memory LLVM fixture; `LLVM.verify` before C-API extraction, with
no optimization passes or textual IR matching:

```llvm
define i8 @store_selected(i8 %x) {
entry:
  %a = alloca i8
  %b = alloca i8
  store i8 11, ptr %a
  store i8 22, ptr %b
  %m1 = and i8 %x, 1
  %c = icmp ne i8 %m1, 0
  %m2 = and i8 %x, 2
  %d = icmp ne i8 %m2, 0
  %p = select i1 %c, ptr %a, ptr %b
  br i1 %d, label %write, label %exit
write:
  store i8 9, ptr %p
  br label %exit
exit:
  %r = load i8, ptr %a
  ret i8 %r
}
```

For **every accepted Int8 fixture and folding mode**, sweep -128:127 against an
independent oracle. After each `simulate!`, explicitly check the retained buffer's
ancillae are zero and input bits unchanged. Also call `verify_reversibility(c)`
per circuit; its API has `n_tests`, not an exhaustive-input keyword.

1. Base fixture: oracle `(x & 3)==3 ? 9 : 11`; RED 64/256 in each mode.
   Also return b, or both cells, to catch false-arm stores (b oracle is 9 iff
   `(x & 3)==2`, otherwise 22). Test both branch polarities.
2. Dynamic i8 origins, N=4/16, `i=(reinterpret(UInt8,x)>>2)&(N-1)`:
   initialize a[i]=11,b[i]=22 before selecting their GEPs. Same oracle and RED
   counts. Check nonselected slots against initialized sentinels as well.
3. Replace select with `entry→left/right→join`, pointer phi at join, then
   branch on independent d to write. Repeat all three shapes. Add an outer
   branch e from bit 6 and assert writes only under e∧d∧P_o, including a
   pointer select defined inside that outer branch and nested selects.
4. Alias origins: select(a,a), select(a[i],a[j]), and mixed static/dynamic
   origins. Independent branch/index bits and nonzero initial values expose
   duplicate writes, wrong slot updates, and accidental removal of P_o.
5. Reuse p after the join: a conditional store followed by unconditional
   `*p=7` must return a=7 iff c, otherwise 11 (currently GREEN). Also keep
   entry-store controls and single-origin conditional stores GREEN.
6. Conditional selected loads with phi fallback 33, N=1,4,16: keep GREEN.
   Persistent single-origin store/load controls remain GREEN; selected actual
   slabs and mixed slab/static origins must refuse. Static allocas under
   `mem=:persistent` must get the repaired ordinary-memory behavior.
7. Direct helper/context negatives: sentinel/missing/wide block predicates
   fail loudly, never default to true; equal-wire conjunction is valid.
   A known entry-unreachable multi-origin store must not silently write.

Re-run with bounds checks: `test_memory_corpus.jl`, `test_cb9y_multi_origin_runtime_idx.jl`,
`test_lower_store_alloca.jl`, `test_shadow_memory.jl`, `test_soft_mux_mem_guarded.jl`,
`test_nj6c_extended_mux_shapes.jl`, `test_t5_p6_persistent_dispatch.jl`,
`test_c6ex_predication_soundness.jl`, `test_predicated_phi.jl`, `test_gate_count_regression.jl`.
These are implementation checks; this proposal session ran inline probes only.

## 7. Risks / open questions for the implementer

- c6ex intentionally omits predicates for entry-unreachable blocks but still
  lowers their instructions (`driver.jl:257–260`). The minimal design refuses a
  multi-origin store there, matching existing single-origin missing-predicate
  behavior. This can change acceptance of dead-store IR. If preserving acceptance
  is required, elide stores only using the explicit `entry_unreachable` proof;
  never infer deadness (or unconditional execution) merely from a missing entry.
- Loop contexts lack the function-entry predicate in their local map. Only
  look up the actual store block; do not call `_entry_predicate_wire` for every
  conjunction. This patch cannot make incorrect upstream loop activation correct.
- Store GateGroup coverage (review F6) and GEP provenance loss (F2) are independent;
  this fix does not repair them. New guards share their stores' scheduling contract.
- Keep persistent controls at ≤4 writes/slab to avoid the independent history overflow.
