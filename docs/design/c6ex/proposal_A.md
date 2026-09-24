# Bennett-c6ex — PROPOSER A (verbatim hand-back, 2026-09-24)

## Bennett-c6ex design proposal (Proposer A): phi predicate invariants

### Summary
I checked both claims in finding A3 against the code and against measured circuits.

- **Site 1 (`phi.jl:58`, `haskey(block_pred,p) || continue`) is not a bug as described.** The skip only ever fires when the predecessor is unreachable from entry. That predecessor's predicate is identically 0, so leaving its term out of the OR is exact. The `# (loop)` comment is also wrong: this line never runs for a loop latch. The line is still an unguarded silent path, so the proposal turns it into an assert that checks this invariant. There is a second silent drop in the same function that the review missed (a predecessor with `branch_info` where neither target is `label`).
- **Site 2 (`phi.jl:120-130`) is a real silent miscompile, but only for malformed IR.** "Malformed" here means a phi that cites a block which is not a CFG predecessor. That includes the A11 escape hatch in `_expand_switches`. The review's proposed fix is incomplete. The same over-approximation also happens through the no-`branch_info` fallthrough (an unconditional non-predecessor), and the review didn't flag that path. The fix that closes both is a predecessor-membership invariant checked in `lower_phi!`.
- **New and more serious: a third silent drop, reachable from plain Julia at `optimize=false`.** `lower_loop!` (`cfg.jl:162-177`) keeps only the last pre-header incoming of each loop-header phi, and only the last latch incoming. An if/else that falls straight into a `while` loop miscompiles:
  - `pre2`: 1143/2304 outputs wrong.
  - `pre4`: 2268/2304 outputs wrong.
  - A hand-written two-latch loop: 48/119 wrong.
  - The `_collect_loop_body_blocks` docstring says multi-latch "fails loud"; it does not.

**Test coverage of the patch.** I applied every proposed change in-session (`@eval` / `include_string`; no repo files touched). Gate counts were identical on 14 functions, and the multi-preheader path fired in no existing test. 29 existing test files pass, except one unit-test fixture in `test_fq8n_phi_mixed_widths.jl` T3, which needs a one-line update (below).

The pinned gate counts include diamond, nested diamond, switch, multi-ret and loops, at `optimize=false` and `optimize=true`.

The 29 files are: `test_branch`, `test_switch`, `test_predicated_phi`, `test_jepw_diamond_in_body`, `test_httg_loop_multiblock`, `test_loop_explicit`, `test_loop`, `test_u21m_switch_phi_patching`, `test_combined`, `test_negative`, `test_6l2h_branching_callee`, `test_prtp_pebbled_branching`, `test_s0tn_loop_overflow`, `test_t3j0_switch_label_collision`, `test_rggq_value_eager_branching`, `test_general_call`, `test_p94b_predicate_asserts`, `test_jghk_multireturn_sret`, `test_0zsk_core_error_paths`, `test_k0bg_compile_validation`, `test_lower`, `test_q9pi_compose_controlled_guards`, `test_xlsz_kwargs_unified`, `test_y56a_division_paths`, `test_bennett`, `test_y986_loop_header_dispatch`, `test_gate_count_regression`, `test_stwr_cuccaro_soundness`.

---

### 1. How predicates get populated
All in `src/lowering/driver.jl` (`lower`) and `src/lowering/cfg.jl`.

- `order = topo_sort(blocks; ignore_edges=find_back_edges(blocks))`. The DFS starts at `blocks[1]`, the entry.
- **`preds` is filled lazily.** A block's terminator pushes it into its successors' `preds` only when that block is processed (`driver.jl:318-336`), which happens after its own predicate is computed. Blocks that are processed but push nothing:
  - Loop-body blocks are skipped entirely (`driver.jl:235`, `loop_body_labels`), so they never push into function-level `preds`.
  - A loop header pushes only `preds[exit_label] ← hlabel`, at the end of `lower_loop!` (`cfg.jl:409`), and never gets function-level `branch_info`.
- **Inside `lower_loop!`**, iteration-local `iter_preds`/`iter_branch_info` are used. The header seeds its non-exit successors, and body blocks push every target except `hlabel` (`cfg.jl:328-335`). Latch→header edges are never registered.
- **Consequence for back edges.** A latch is lowered after its header, both at function level (topo order) and in-loop (the push is suppressed). So a back-edge predecessor is never in `preds[h]` when `h`'s predicate is computed. The `continue` is unreachable for loops.

### 2. Site 1: reachability and proof that it is benign

**Theorem (function level).** If `p ∈ preds[label]` and `p ∉ block_pred`, then `p` is unreachable from entry.

Proof sketch:
1. `p` was processed, is not `order[1]`, and had `preds[p]` empty. This follows from the `elseif !isempty(...)` at `driver.jl:251`.
2. Take any forward edge q→p. The predecessor q comes earlier in topo order, and in every case either q pushed p or p is not a function-level block:
   - q is a normal processed block: it pushes p.
   - q is a loop header: its non-exit successors are loop-body blocks and would be skipped, and the exit gets `hlabel` pushed.
   - q is a body block: its successors are body blocks, its own header (a back edge), or `exit_label` (which gets `hlabel`).
3. So `p` has no forward predecessors at all.
4. If `p` were reachable, its DFS tree-parent edge would be a forward edge (a tree edge is never a back edge). That is a contradiction, so `p` is unreachable.
5. An unreachable block's predicate is identically 0, so `OR(..., 0)` is exact.

**Loop level.** Every body block is added via a non-back edge from the header or an earlier body block, and that edge pushes into `iter_preds`. The topo sort of the sub-region orders it after its predecessor. So the skip never fires in-loop, and the `if !isempty(get(iter_preds, ...))` guard at `cfg.jl:312` never takes its false branch.

**Measurements.**

| Case | Result |
|---|---|
| Instrumented run over 29 test files and ~20 probe functions (opt f/t) | 0 hits of the skip; 0 non-entry blocks without predecessors |
| Scan of all `test/fixtures/**/*.ll` | 0 dead blocks |
| CE1: dead block `dead: br %B` into a live diamond arm | Skip fires, 0/256 wrong, 320 gates. Benign, and identical after the patch. |
| CE1b: phi cites the dead block | Throws `_edge_predicate!: no predicate for block dead` (loud) |
| CE1c: `dead0→dead1→B` | Throws `no predicate contributions for block dead1`, a loud false rejection. Compiles correctly after the patch (0/256 wrong). |

**The extra silent path in `_compute_block_pred!` the review missed (lines 65-74).** If `branch_info[p]` exists and neither target equals `label`, nothing is pushed and nothing is raised. It is unreachable today, because `preds` and `branch_info` are written from the same terminator. It should still become an assert.

### 3. Site 2: reachability, counterexamples, and why the review's fix is incomplete
`_edge_predicate!` is called from `resolve_phi_predicated!` (via `lower_phi!`, both at function level and in-loop), from the ptr-phi path, and from the multi-ret merge (`phi_block=Symbol("")`, where ret blocks never have `branch_info`).

**Valid IR never reaches the "neither" branch.** Observed across all probes. For valid LLVM, a phi's incoming blocks are predecessors, and `_expand_switches` Phase B rewrites every switch-cited incoming through `pred_map`. The legitimate no-`branch_info` sources are:
- an unconditional-branch predecessor;
- a loop header seen from its `exit_label` at function level. Its edge predicate `block_pred[hlabel]` is correct because the unrolled loop exits exactly once, and non-convergence is caught loudly by the `LoopGuard`;
- a ret block in the multi-ret merge.

**Malformed IR is silently miscompiled.** Bennett runs no LLVM verifier on `.ll` input or hand-built ParsedIR.

| Case | Incoming involved | Wrong outputs |
|---|---|---|
| CE3: A11 stale switch incoming (`phi [9,%S],...`, where `S`'s switch does not target `M`) | `S` has `branch_info` → neither branch | 127/256 |
| CE3c: phi cites conditional `top`, which is not a predecessor | neither branch | 256/256 |
| CE3u: phi cites unconditional `A→A2`, which is not a predecessor | **no-`branch_info` fallthrough** | 127/256 |

CE3u shows why throwing only in the neither branch (the review's proposal) is insufficient.

**Precise invariant (I2).** Every phi incoming block `S` is in `preds[phi_block]` (function-level or `iter_preds`). Given I2 and the fact that `preds`/`branch_info` are written from the same terminator: if `branch_info[S]` exists then `phi_block ∈ {tl, fl}`. With p94b's distinct-predecessor check, also `tl ≠ fl`. So the fallthrough becomes truly unreachable and can throw.

**Related, loud but valid-IR rejections (separate follow-ups, not c6ex).**
- CE2: a switch whose last case targets the default dest becomes `br c,T,T`, and p94b throws on the duplicate predecessor.
- A valid 2-entry phi for a multi-edge switch expands to 4 duplicate incomings. It is correct but costs +20 gates (412 vs 392).

**Do not add a distinct-incoming assertion** unless `_expand_switches` dedupes first.

### 4. The new silent drop in `lower_loop!` header phis (I3)
`cfg.jl:166-173` overwrites `pre_op` and `latch_op` in the loop, so only the last one survives:
```julia
function pre2(x::Int8, n::Int8)
    if x > Int8(0); a = Int8(1); else; a = Int8(-1); end
    while n > Int8(0); a += x; n -= Int8(1); end
    a
end
```
At `optimize=false`, header `L5` has phi `[(1,:L3),(__v9,:L9),(-1,:L4)]`, i.e. two pre-headers. The seed takes `-1` always.

| Function | Original | Patched |
|---|---|---|
| `pre2`, K=8, x∈Int8, n∈0:8 | 1143/2304 wrong, 3391 gates | 0/2304 wrong, 3501 gates |
| `pre4` (3-way if/elseif/else, then loop) | 2268/2304 wrong, 5129 gates | 0/2304 wrong, 5427 gates |
| Two-latch hand IR | 48/119 wrong | throws |

At `optimize=true`, loop-simplify gives a single preheader and single latch, so the default path is not affected. Julia's `continue` goes through a merge block, so there is one latch.

### 5. Proposed changes (exact code; all gate-neutral for currently-correct programs)

**5a. `src/lowering/phi.jl`, `_compute_block_pred!`.** Add a kwarg, replace line 58, and add an `else`:
```julia
function _compute_block_pred!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                              label::Symbol, preds::Dict{Symbol,Vector{Symbol}},
                              branch_info::Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}},
                              block_pred::Dict{Symbol,Vector{Int}};
                              unreachable::AbstractSet{Symbol}=Set{Symbol}())
    # ... existing p94b empty/duplicate checks unchanged ...
    for p in pred_list
        if !haskey(block_pred, p)
            # Bennett-c6ex: preds are registered lazily from already-lowered
            # terminators, so a back-edge latch is never in pred_list when its
            # header's predicate is computed (lower_loop! also never registers
            # latch→header). The only predecessor that can lack a predicate is
            # one unreachable from entry, whose predicate is identically 0:
            # omitting its OR-term is exact. Anything else would weaken the
            # predicate — fail loud.
            p in unreachable || throw(AssertionError(
                "_compute_block_pred!: predecessor $p of block $label has no path " *
                "predicate but is reachable from the entry block; omitting its " *
                "OR-term would under-approximate block_pred[$label] " *
                "(Bennett-c6ex; CLAUDE.md 'Phi Resolution')"))
            continue
        end
        # ... existing width-1 check ...
        if haskey(branch_info, p)
            (cw, tlabel, flabel) = branch_info[p]
            if tlabel == label
                push!(contributions, _and_wire!(gates, wa, block_pred[p], cw))
            elseif flabel == label
                not_cw = _not_wire!(gates, wa, cw)
                push!(contributions, _and_wire!(gates, wa, block_pred[p], not_cw))
            else
                throw(AssertionError(
                    "_compute_block_pred!: predecessor $p of block $label ends in a " *
                    "conditional branch to ($tlabel, $flabel), neither of which is " *
                    "$label — preds and branch_info disagree (Bennett-c6ex)"))
            end
        else
            push!(contributions, block_pred[p])
        end
    end
    # ... rest unchanged ...
```

**5b. `_edge_predicate!`.** Replace the `branch_info` arm, and rewrite the docstring bullet "or src_block doesn't directly branch to phi_block", which describes the bug:
```julia
    if haskey(branch_info, src_block)
        (cw, tlabel, flabel) = branch_info[src_block]
        tlabel == flabel && throw(AssertionError(
            "_edge_predicate!: block $src_block branches conditionally to $tlabel on " *
            "both arms; AND(pred, cond) would drop the false arm (Bennett-c6ex)"))
        if tlabel == phi_block
            return _and_wire!(gates, wa, block_pred[src_block], cw)
        elseif flabel == phi_block
            not_cw = _not_wire!(gates, wa, cw)
            return _and_wire!(gates, wa, block_pred[src_block], not_cw)
        end
        throw(AssertionError(
            "_edge_predicate!: block $src_block ends in a conditional branch to " *
            "($tlabel, $flabel), neither of which is $phi_block. Returning " *
            "block_pred[$src_block] would over-approximate the edge predicate " *
            "(false-path sensitization, CLAUDE.md 'Phi Resolution'). The phi cites " *
            "a non-predecessor: malformed IR, or a CFG rewrite (e.g. " *
            "_expand_switches) failed to patch it (Bennett-c6ex)."))
    end
    # No branch_info: src ends in an unconditional branch, OR is a loop header
    # seen from its exit block (function level), OR is a ret block (multi-ret
    # merge). Membership is enforced by lower_phi! (_assert_phi_incoming_preds).
    return block_pred[src_block]
```

**5c. New helper plus two calls in `lower_phi!` (invariant I2).** This catches CE3, CE3c and CE3u, and single-incoming aliases too.
```julia
function _assert_phi_incoming_preds(inst::IRPhi, phi_block::Symbol, preds)
    plist = get(preds, phi_block, Symbol[])
    for (_, blk) in inst.incoming
        blk in plist || throw(AssertionError(
            "lower_phi!: phi %$(inst.dest) in block $phi_block has an incoming from " *
            "block $blk, which is not a registered CFG predecessor of $phi_block " *
            "(registered: $(plist)). Either the IR is malformed (phi cites a " *
            "non-predecessor, e.g. a stale switch incoming), or $blk is a loop-body " *
            "block exiting the loop (break), which lower_loop! does not model " *
            "(Bennett-c6ex)."))
    end
    return nothing
end
```
Where to call it:
- ptr path: immediately before `merged = PtrOrigin[]`.
- integer path: immediately before `isempty(block_pred) && throw(...)`, i.e. after the fq8n width loop, so that fq8n T1/T2 still see `DimensionMismatch`.

**5d. `src/lowering/cfg.jl`.**

(i) New helper:
```julia
"""Labels of blocks unreachable from `entry` over all IRBranch edges (Bennett-c6ex)."""
function _unreachable_blocks(blocks::Vector{IRBasicBlock}, entry::Symbol)
    block_map = Dict(b.label => b for b in blocks)
    seen = Set{Symbol}([entry]); stack = Symbol[entry]
    while !isempty(stack)
        t = block_map[pop!(stack)].terminator
        t isa IRBranch || continue
        for s in branch_targets(t)
            (haskey(block_map, s) && !(s in seen)) || continue
            push!(seen, s); push!(stack, s)
        end
    end
    return Set{Symbol}(b.label for b in blocks if !(b.label in seen))
end
```

(ii) Body-block predicate at `cfg.jl:312-316`, replacing the silent `if`:
```julia
isempty(get(iter_preds, blabel, Symbol[])) && throw(AssertionError(
    "lower_loop!: body block $blabel of loop $hlabel has no in-region " *
    "predecessor (Bennett-c6ex)"))
iter_block_pred[blabel] =
    _compute_block_pred!(gates, wa, blabel, iter_preds,
                         iter_branch_info, iter_block_pred)
```

(iii) Header phis at `cfg.jl:162-177` (I3):
```julia
phi_info = Tuple{Symbol, Int, Vector{Tuple{IROperand,Symbol}}, IROperand}[]
for inst in header.instructions
    inst isa IRPhi || continue
    pre_ops = Tuple{IROperand,Symbol}[]; latch_ops = Tuple{IROperand,Symbol}[]
    for (val, blk) in inst.incoming
        if blk in latch_labels || blk == hlabel
            push!(latch_ops, (val, blk))
        else
            push!(pre_ops, (val, blk))
            blk in pre_header_preds || push!(pre_header_preds, blk)
        end
    end
    isempty(pre_ops) && throw(AssertionError("lower_loop!: phi $(inst.dest) has no pre-header incoming"))
    isempty(latch_ops) && throw(AssertionError("lower_loop!: phi $(inst.dest) has no latch incoming"))
    length(latch_ops) == 1 || throw(AssertionError(
        "lower_loop!: phi %$(inst.dest) in loop header $hlabel has " *
        "$(length(latch_ops)) latch incomings $(last.(latch_ops)); multi-latch " *
        "loops are not supported — the MUX-freeze carries ONE latch value (Bennett-c6ex)"))
    (length(pre_ops) > 1 && inst.width == 0) && throw(AssertionError(
        "lower_loop!: pointer-typed header phi %$(inst.dest) with multiple " *
        "pre-header incomings is not supported (Bennett-c6ex)"))
    push!(phi_info, (inst.dest, inst.width, pre_ops, latch_ops[1][1]))
end
```

(iv) Seeding at `cfg.jl:208-210`. The single-preheader path is byte-identical to today:
```julia
for (dest, width, pre_ops, _) in phi_info
    vw[dest] = if length(pre_ops) == 1
        resolve!(gates, wa, vw, pre_ops[1][1], width)
    else
        # Bennett-c6ex: several pre-header predecessors (optimize=false if/else
        # falling straight into a while header). Select by edge predicate over
        # the FUNCTION-LEVEL block_pred / branch_info (pre-headers are lowered
        # before the header).
        resolve_phi_predicated!(gates, wa,
            [(resolve!(gates, wa, vw, v, width), b) for (v, b) in pre_ops],
            opts.block_pred, width; phi_block=hlabel, branch_info)
    end
end
```
`branch_info` here must be `lower_loop!`'s positional (function-level) argument, not `iter_branch_info`.

**5e. `src/lowering/driver.jl`.**
- After `order = topo_sort(...)`: `unreachable = _unreachable_blocks(blocks, order[1])`.
- Block-predicate arms become entry | `elseif label in unreachable` → `nothing` (dead: no predicate, no gates) | `elseif !isempty(...)`.
- The `_compute_block_pred!` call becomes `_compute_block_pred!(gates, wa, label, preds, branch_info, block_pred; unreachable)`.
- Add a final arm:
  ```julia
  else
      throw(AssertionError("lower: block $label is reachable from entry but no " *
            "predecessor registered an edge into it (Bennett-c6ex)"))
  end
  ```

**5f. Test fixture.** In `test/test_fq8n_phi_mixed_widths.jl` T3 (and T1/T2 for robustness), pass `Dict(:PhiBlock => [:BlockA, :BlockB])` instead of the empty `preds`. The fixture currently describes an inconsistent CFG.

### 6. Impact on gate counts
This was measured, not inferred: identical before and after the patch.

| Function | Gates |
|---|---|
| diamond, opt f / t | 318 / 228 |
| nested, opt f / t | 1138 / 1070 |
| select3, opt f | 218 |
| multiret, opt f | 330 |
| `_u05_acc` f, K=4 | 1183 |
| `_u05_br` f / t, K=4 | 2297 / 774 |
| collatz t, K=20 | 14673 |
| `cl` (if{while} else) f, K=8 | 2777 |
| `cont` f, K=8 | 4715 |
| `pre3` (ternary merge, then loop) f, K=8 | 3437 |
| 2-entry shared-target switch | 412 |
| CE1 | 320 |

Gates change only for programs that were previously wrong (`pre2`, `pre4`) or previously threw (CE1c).

### 7. Red-green plan
New file `test/test_c6ex_phi_predicate_invariants.jl`, registered in `runtests.jl`. The hand `.ll` cases can be parsed from a string via `LLVM.Context(); parse(LLVM.Module, ir); Bennett._extract_from_module(mod, fname, String[])`, or written with `mktempdir` plus `extract_parsed_ir_from_ll`.

**Red today (wrong output or no error), green after:**
- CE3: expect `AssertionError` containing "Bennett-c6ex" (today 127/256 wrong).
- CE3c: throws (today 256/256 wrong).
- CE3u: throws (today 127/256 wrong).
- Unit: `_edge_predicate!(…, :A, :D, bp, Dict(:A=>(cw,:B,:C)))` throws (today returns `bp[:A]`).
- Unit: `_compute_block_pred!` with `preds[:C]=[:A,:X]`, `:X` not in `block_pred` and no `unreachable` kwarg, throws (today it silently skips). With `unreachable=Set([:X])` it succeeds.
- Unit: `_compute_block_pred!` with `preds[:C]=[:A,:B]` and `branch_info[:A]=(cw,:D,:E)` throws (today it silently drops the term).
- Unit: `_edge_predicate!` with `tl == fl` throws.
- `pre2` and `pre4` at `optimize=false`, K=8: 0 wrong over x∈Int8 × n∈0:8 (today 1143 and 2268 wrong). Use `simulate` exhaustively, which checks ancillae. Do not use `verify_reversibility`, whose random n values trip the `LoopGuard`.
- Two-latch hand IR throws with the multi-latch message (today 48/119 wrong).
- CE1c compiles with 0/256 wrong (today it throws).

**Green before and after (pin the gate counts from §6):**
- CE1: 0/256 wrong, 320 gates.
- diamond, nested diamond, select3, multiret: exhaustive over Int8.
- `_u05_br` / `jepw` (diamond in loop body), collatz, `cl`, `cont`, `pre3`.
- u21m shared-target switch, 1-entry and 2-entry.
- Also rerun `test_p94b`, `test_jepw`, `test_httg`, `test_s0tn`, `test_y986`, `test_u21m`, `test_t3j0`, `test_jghk`, and the gate-count regression files.

### 8. Risks and follow-ups
- **Error precedence changes.** A loop `break` into the exit (e.g. `brk` at `optimize=true`) now throws the membership message instead of `_edge_predicate!: no predicate for block L2`. No test asserts the old text; it appears only in a comment in `test_jepw`.
- **Hand-built ParsedIR** with non-predecessor phi incomings now fails loudly. This is intended.
- **Ptr-typed header phi** with multiple pre-headers is guarded with a throw, not implemented.
- **Suggested new beads, outside c6ex scope:**
  - `_expand_switches`: emit an unconditional branch when a cmp block's true target equals its false target (CE2 false rejection), and dedupe `(val, pred)` phi incomings (412→392 gates for multi-edge switches).
  - The `lower_loop!` exit heuristic `exit_on_true = !(true_label==h || true_label∈latches)` misidentifies `br c, body, exit` headers. Today that is loud ("IRRet in loop body"). Replace it with a natural-loop computation.
  - A loop body that reaches `:__unreachable__` (collatz at `optimize=false`) gives `KeyError: :__unreachable__` in `_collect_loop_body_blocks`: loud but opaque.
  - Add an `else throw` for unknown terminator types in the `driver.jl` terminator dispatch.
  - `resolve_phi_predicated!` computes the last incoming's edge predicate and never uses it. That wastes gates, but leave it alone here because of the gate-count pins.
- **Full suite.** It was not run (4 shared cores). The implementer must run it; I expect only fq8n T3 to need the fixture edit.

### Critical files for implementation
- /home/user/Bennett.jl/src/lowering/phi.jl
- /home/user/Bennett.jl/src/lowering/cfg.jl
- /home/user/Bennett.jl/src/lowering/driver.jl
- /home/user/Bennett.jl/test/test_fq8n_phi_mixed_widths.jl
- /home/user/Bennett.jl/src/extract/module_walk.jl (`_expand_switches`, follow-ups only)