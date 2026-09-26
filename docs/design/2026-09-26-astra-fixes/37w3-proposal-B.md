# Proposal B — Bennett-37w3 — Compose store-site activation with pointer selection

## 1. Root cause (precise, with file:line; what invariant is violated and by whom)

For a store in block S, origin o, and element k, the write-enable must be `B(S) ∧ O(o) ∧ (index(o)
== k)`. Origin selection answers *where* to write; the current block predicate answers *whether*
this store executes. Neither predicate generally implies the other.

`src/lowering/driver.jl:545–561` supplies the correct block label and context;
`src/lowering/types.jl:280` forwards them to `lower_store!`. The multi-origin branch at
`src/lowering/memory.jl:607–648` discards the block label:

- Static shadow dispatch passes only `o.predicate_wire` at lines 624–625.
- Shadow-checkpoint dispatch passes a sentinel label and only the origin
  predicate at lines 631–633; the override at 878–887 suppresses block lookup.
- Generated MUX-EXCH dispatch passes only the origin predicate at 647–648;
  lines 1051–1064 select the guarded callee with that incomplete guard.

The provenance producers are not responsible for predicting future uses. Pointer select builds
`old_origin ∧ c` / `old_origin ∧ ¬c` (`arith.jl:558–573`); pointer phi combines origins with
incoming edge predicates (`phi.jl:315–327`). A later store can introduce another branch. Mutual
exclusion of origins does not establish activation of that store.

Independent reproduction, using `julia --project --check-bounds=yes --startup-file=no
--compiled-modules=existing -e '…'`, without fixture files: the named review's ParsedIR and a
separately assembled, LLVM-verified module both produce **64/256 wrong Int8 results**, folding off
and on. For `c=(x&1)!=0; d=(x&2)!=0`, initial `a=11,b=22`, `p=c?a:b`, conditional `*p=9`, and return
`a`, the oracle is `(x&3)==3 ? 9 : 11`. At x=-127 the result is 9 instead of 11. All four circuits
pass `verify_reversibility`; every exhaustive `simulate` also checks ancillae and input
preservation. The defect is functional correctness, not failed undo. Baseline circuit totals for
this exact minimal fixture: 456 unfolded, 154 folded.

## 2. Blast radius (every caller/path affected; other symptoms this explains; interactions with recent fixes named in the brief)

All `IRStore` instructions using multi-origin provenance are affected when origin selection can be
true outside the store block: pointer selects, pointer phis subsequently used in a conditional
block, nested combinations, and GEP-derived origins whose provenance survives propagation. Aliases
into one alloca are also affected; distinct allocation sites are not necessary. The same pointer
used by two stores requires a different conjunction at each site. Both branch polarities and outer
diamond guards matter.

The call chain is `lower` → `lower_block_insts!` → `_lower_inst!` → `lower_store!`; loop header/body
dispatch also uses `_lower_inst!` (`cfg.jl:448–449,482–487`). Callees lowered recursively at
`call.jl:97` inherit the defect for their own local selected pointers.

Additional independent probes (all 256 Int8 inputs; both folding settings unless indicated):

| Path | Observation before fix |
| --- | --- |
| Static shadow, selected pointer | 64 wrong; reversibility passes |
| Dynamic index, 4×i8, generated MUX-EXCH | 64 wrong; reversibility passes |
| Dynamic index, 16×i8, shadow-checkpoint | 64 wrong; reversibility passes |
| Diamond pointer phi, then independently conditional store | 64 wrong; reversibility passes |
| Selected pointer defined before a loop; store in conditional body | 64 wrong; reversibility passes |
| Conditional selected-pointer loads, each of the first three shapes | 0 wrong; reversibility passes |
| Conditional pointer-phi load | 0 wrong; reversibility passes |
| Dynamic persistent slabs, selected-pointer store/load | Both fail compilation with “unknown alloca %a” |
| Dynamic persistent slab, single-origin conditional store/load | 0 wrong; reversibility passes (folding on) |

Dynamic-index probes initialize the chosen slot in each array to 11/22, using
`idx=(unsigned(x)>>2)&(N-1)`, independently of c and d. The load control returns `d ? (c ? 11 : 22) :
33` via a scalar phi. The LLVM-verified loop probe has one active body iteration: header i starts at
0, exits at i==1, latch increments i, body condition d gates the store, K=2; no header effects.

**Loads:** `types.jl:276–277` intentionally drops block context; `aggregate.jl:421–470` merges read
results by origin predicate only. Static loads copy memory; dynamic loads compute fresh results via
MUX or shadow-checkpoint (`memory.jl:918–943,989–1012`). None commits memory state. Their
speculative off-path result is immaterial when ordinary SSA uses, phi/return selection, and
side-effect consumers respect activation. Therefore the missing conjunction is not the same
observable bug for these supported loads; do not add load gating. This is not a general claim about
volatile, trapping, or otherwise unsupported LLVM loads.

**Persistent:** `mem=:persistent` does not redirect constant-sized allocas, so the three ordinary
memory arms remain affected under that option. Actual dynamic-sized persistent slabs lack
`alloca_info`; multi-origin store/load fails at `memory.jl:617–619` / `aggregate.jl:429–431`, before
the persistent helpers' advertised multi-origin refusal. Single-origin stores use a block-controlled
pre/post-state MUX (`memory.jl:352–369,516–523`), and persistent loads are read-only. Preserve the
multi-origin refusal; adding persistent multi-origin support is outside this fix.

**History:** tzb7 introduced origin fan-out; oio4 guarded single-origin shadow stores; cb9y extended
origin-only guards to runtime-index arms. The cb9y tests write immediately at the pointer-phi join,
where its origins already imply the block predicate; they miss a later independent guard. Commit
b5f6127 (c6ex, 2026-09-24) changed CFG/phi/driver, not memory.jl. Retain its validated edge
predicates and same-target canonicalization. vscb concerns MUX-EXCH cost/dispatch preference; keep
strategy selection unchanged and fix both backends so a future preference change stays correct.

## 3. Design (the fix, concretely: data structures / predicates / control flow; pseudo-diff for the load-bearing lines)

Keep `PtrOrigin`, CFG computation, load lowering, and allocation strategies unchanged. Compose an
operation-local guard in the store dispatcher, once per origin, before backend dispatch. Never
mutate `ptr_provenance` or cache the guard by pointer name: its lifetime and meaning belong to this
store.

Add one memory-local block-guard resolver returning `Union{Nothing,Int}`; `nothing` means *proven
true*, not *missing information*. Its proof is the real entry label established by CFG validation
(`cfg.jl:77–80`) and the constant-one prologue (`driver.jl:246–252`). Every supplied label must have
exactly one predicate wire. Sentinel labels and missing predicates fail loud. Use the current
context's block map; iteration-local maps need not contain the function entry. Do not call
`_entry_predicate_wire` to form this guard.

```julia
function _store_block_guard(ctx, label)::Union{Nothing,Int}
    label != Symbol("") && ctx.entry_label != Symbol("") ||
        throw(AssertionError("store requires an explicit block context"))
    pw = get(ctx.block_pred, label, Int[])
    length(pw) == 1 || throw(AssertionError("store: missing/invalid predicate for $label"))
    return label == ctx.entry_label ? nothing : pw[1]
end

# lower_store!, after provenance validation, before cardinality dispatch:
block_guard = _store_block_guard(ctx, block_label)
length(origins) == 1 && return _lower_store_single_origin!(ctx, inst, origins[1], block_label)
val_wires = resolve!(...)                 # existing shared value resolution
for o in origins
    effective = if block_guard === nothing || block_guard == o.predicate_wire
        o.predicate_wire                 # true AND o, or o AND o
    else
        _and_wire!(ctx.gates, ctx.wa, [block_guard], [o.predicate_wire])[1]
    end
    # Existing strategy dispatch, replacing all three origin-only arguments:
    # shadow: _emit_store_via_shadow_guarded!(..., effective, val_wires)
    # checkpoint: _lower_store_via_shadow_checkpoint!(..., block_label;
    #                                                 effective_pred_wire=effective)
    # mux: fn(...; block_label=block_label, effective_pred_wire=effective)
end
```

Rename the two backend kwargs `extern_pred_wire` → `effective_pred_wire` and document their
contract: a complete store-site-and-origin guard, with the backend adding only element selection.
Update all references; the source search found no callers outside memory.jl. Retain the override
mechanism, with its precondition explicit, instead of composing twice.

Use the same resolver for all block-derived backend guards, replacing the sentinel-as-entry tests at
`memory.jl:358,753,878–887,1051–1064`:

```julia
# checkpoint / generated MUX store:
guard = effective_pred_wire === nothing ? _store_block_guard(ctx, block_label) : effective_pred_wire
# checkpoint per slot:
guard_w = guard === nothing ? eq_wire : _and_wire!(ctx.gates, ctx.wa, [guard], [eq_wire])[1]
# MUX: guard===nothing → existing unguarded callee;
# otherwise existing guarded callee + _mux_store_pred_sym_from_wire!(ctx, guard, tag).
# static single-origin shadow and persistent: derive guard with the resolver;
# guard===nothing → existing unconditional emitter, otherwise existing guarded emitter.
```

This validates even the single-origin entry fast path without adding gates. Private callers needing
unconditional stores must supply a valid entry context; absence of context must not be treated as
evidence of activation. Retain width, bounds, fan-out, unknown-allocation, and persistent refusals.
Update comments that currently promise “exactly one origin fires” to “one when this store is active;
none when inactive.”

## 4. Why it is sound (argue the invariant is restored on ALL paths; ancilla hygiene; no false-path sensitisation; effect on gate counts — say whether explicit-strategy baselines in test/test_gate_count_regression.jl can move and why)

If B=0, every effective guard is zero: static shadow leaves primal/tape unchanged; checkpoint has
zero guard at every slot; MUX-EXCH returns the old array. If B=1, effective guards equal the
original mutually exclusive origin guards, so precisely the selected origin/slot receives the value.
The argument also holds for overlapping origins into one allocation. Do not substitute the pointer
producer's block or a local branch condition for B; only the full current block predicate includes
outer guards.

Single-origin stores retain their existing block guard. For valid dominating SSA provenance with one
origin, that origin is necessarily the target on every active use; no origin-choice fan-out exists.
Do not extend this fast path by dropping false-looking origins or deduplicating origins without
preserving their disjunction. Unsupported persistent fan-out remains loud.

`_and_wire!` allocates a fresh zero wire and emits one Toffoli. Preserve this wire until Bennett
uncomputation; never free it while live. Guards remain read-only, so reverse execution undoes store
gates before undoing their conjunctions. Tape, index-equality, MUX promotion, and call temporaries
keep their existing cleanup. Folding on/off must both satisfy the invariant.

For m nontrivial origin conjunctions, the raw forward delta is m wires and m Toffolis; ordinary
Bennett adds 2m gates/Toffolis. Constant folding can remove redundant constant controls; measure
actual deltas. Entry multi-origin stores add no conjunction gates, and single-origin successful
paths emit the same gates. Existing explicit arithmetic baselines in
`test/test_gate_count_regression.jl` **must not move**: this proposal changes neither their
strategies nor arithmetic lowering. Non-entry multi-origin memory counts may increase, including
already-correct phi-at-join programs; that is the bounded cost of a uniform correctness guard, not a
vscb strategy change.

## 5. Alternatives considered and rejected (at least one, with the reason)

- Guard pointer select/phi at definition: insufficient for later conditional
  stores, and would incorrectly bind reusable provenance to one use site.
- Use only the store block predicate: loses origin selection and writes every
  candidate array. Keep both predicates.
- Repair only the dynamic override helpers: leaves static shadow incorrect;
  per-slot composition also needlessly repeats the origin/block conjunction.

## 6. Tests (RED-first: the exact test file/cases to add; for Int8 all 256 inputs; verify_reversibility or explicit ancilla checks on every case; which existing test files must be re-run)

Add `test/test_37w3_store_site_predication.jl`, registered in `test/runtests.jl`. Before
implementation, observe the 64/256 failures of the minimal F1 ParsedIR and its LLVM equivalent; use
`LLVM.verify` and the C-API walker on an in-memory module, without optimization or textual-output
matching. For every circuit, sweep all `typemin(Int8):typemax(Int8)`, compare an explicit oracle,
and call `verify_reversibility`. `simulate` checks zero ancillae and preserved inputs on **every**
enumerated input (`simulator.jl:195–234`).

- F1 with folding false/true; observe a and b independently. Expected values:
  `a = d&&c ? 9 : 11`, `b = d&&!c ? 9 : 22`. This catches both origin arms.
- Same matrix for 4×i8 MUX and 16×i8 checkpoint using the independent index
  formula above. Check unselected slots as well, initialized to distinct
  sentinels; loop over observed slots. Exercise `compact_calls=false/true` for 4×i8.
- Cover every generated `(N,W)` in `_MUX_SHAPES_NW`: derive bounded index
  `(unsigned(x)>>2)%N`, initialize both target slots, use positive 11/22/9 values,
  return W-bit observations; input remains Int8 with all 256 values.
- Replace select by a diamond pointer phi, then branch independently on d.
  Add an outer guard from bit 6 with true/false-arm stores and nested selects;
  expected memory is unchanged whenever any dominating guard is false.
- Reuse p across successive conditional stores (9 under d, 7 under !d),
  including a select between two offsets of the same allocation. This
  exposes accidental mutation of provenance or incorrect origin deduplication.
- Entry-block unconditional selected stores, single-origin conditional stores,
  constant true/false branch conditions, and same-target branch controls.
  Run the verified one-iteration loop shape from §2 at K=1 and K=2 to check
  iteration-local predicate lookup without introducing header side effects.
- Load-only controls with the oracle from §2 for static/MUX/checkpoint and
  phi pointers; include a guarded store consuming the loaded result.
- `mem=:persistent`: repeat static-sized F1; assert dynamic-sized multi-origin
  load/store refusal; exhaustively check single-origin conditional controls
  with at most two stores per slab (avoid the unrelated capacity defect).
- Internal guard-contract tests: sentinel/missing/multiwire block predicates
  throw; an explicit zero non-entry predicate makes every store a no-op;
  equal block/origin wire avoids duplicate-control conjunction; entry control
  preserves gate counts. Use complete circuits and exhaustive checks for
  successful cases. Compile-time rejection cases have no circuit to verify.

Re-run individual existing files with `--project --check-bounds=yes`: `test_memory_corpus.jl`,
`test_cb9y_multi_origin_runtime_idx.jl`, `test_lower_store_alloca.jl`, `test_universal_dispatch.jl`,
`test_nj6c_extended_mux_shapes.jl`, `test_shadow_memory.jl`, `test_soft_mux_mem_guarded.jl`,
`test_t5_p6_persistent_dispatch.jl`, `test_c6ex_predication_soundness.jl`,
`test_p94b_predicate_asserts.jl`, `test_jepw_diamond_in_body.jl`,
`test_y986_loop_header_dispatch.jl`, and `test_gate_count_regression.jl` (all under `test/`; supply
Test/Bennett imports when a file expects the runtests harness). No full suite was run.

## 7. Risks / open questions for the implementer

The soundness claim assumes B correctly represents execution. Existing loop header-after-exit
effects (review F5) require a separate iteration-active fix; this conjunction cannot repair an
already-wrong block predicate. Likewise, do not absorb GEP provenance loss, persistent history
overflow, or missing store gate-group metadata into this patch.

c6ex deliberately leaves entry-unreachable blocks without predicates while still lowering their
instructions (`driver.jl:257–260`). The proposed check will reject a multi-origin store there,
replacing current unsound acceptance; single-origin stores there already reject. Do not silently
treat missing as true or zero. Supporting those blocks requires an explicit dead-block contract
(skip effects or supply a proven-zero guard) as a separate coordinated change.

Sentinel rejection intentionally tightens the internal API; no store-helper callers outside
memory.jl were found in src/test. Only this proposal was written; independent designs were not read.
