# Bennett-c6ex — PROPOSER B (verbatim hand-back, 2026-09-24)

# Proposer B: predication soundness in `src/lowering/phi.jl` (with cfg.jl and driver.jl)

## Summary

- **Both flagged fallthroughs are real, and both give silent wrong outputs when reached.** For IR that LLVM would accept as valid, neither is reachable today.
  - **Site 2** (`_edge_predicate!` returning the source block's predicate when neither branch target is the phi block): **127/256 wrong outputs**. It is reached through `.ll` ingest with a phi that names a block which is not a predecessor. `LLVM.parse` does not run the verifier, so such IR gets in.
  - **Site 1** (`_compute_block_pred!` skipping a predecessor that has no predicate): **49/256 wrong** with a hand-built `ParsedIR` holding an unexpanded `IRSwitch`, passed through the public `reversible_compile(::ParsedIR)`. `verify_reversibility` still returns true. For valid IR it fires only for dead blocks (not reachable from the entry), where skipping happens to be exact.
- **A third silent arm exists in `_compute_block_pred!`.** When a predecessor has `branch_info` but neither target is the block, its contribution is dropped without any error.
- **`br i1 %c, label %X, label %X` is handled wrongly by both functions.** Each returns `pred∧c`, which ignores the false edge. It never becomes a miscompile because the duplicate-predecessor assertion always fires first. That assertion wrongly rejects valid IR, including every switch whose last case targets the default block.
- **Worse bugs, in the same soundness class, sit in `lower_loop!`.** They were found with the same method, and all go through the official `reversible_compile` + `simulate` path:
  1. **Loop header with more than one pre-header predecessor.** Plain Julia at `optimize=false` produces this: `if c; n = …; end; while n > 0 … end`. `lower_loop!` keeps only the last pre-header incoming. Wrong outputs: g1 **40/256**, g2 **128/256**, g4 **128/256**, hand `.ll` H5 **127/256**.
  2. **Loop with more than one latch.** Only the last latch incoming is kept. Hand `.ll` H6′: **160/256 wrong**. The docstring says multi-latch fails loud; it does not.
  3. **Loop with a second exit (`break`) at `optimize=false`.** The break edge from the body to the exit is never modelled, so iteration continues after the break. l5: **96/256 wrong**.
- **Proposed fix.**
  - One up-front CFG check plus canonicalization at `lower()` entry.
  - Dead blocks stop recording predecessor edges.
  - All three fallthroughs become assertions; same-target conditional branches become unconditional.
  - Header phis are merged by predicate: over pre-header edges for the seed, and over latch edges each iteration.
  - A second loop exit becomes a loud error.
  - An optional debug-mode checker verifies mutual exclusion and coverage at run time.
- **Gate-count impact: zero for correct programs.** Measured on 29 programs and all 12 correct loop programs: gate and wire counts are identical. Counts change only for programs that were previously wrong or previously rejected.

All experiments ran in-session. Functions were redefined with `Core.eval(Bennett, …)`, IR was passed through heredocs, and no files were written. I did not run the full test suite.

---

## 1. Soundness conditions

Setup:
- The CFG G is built from the terminators, after switch expansion.
- π(x) is the executed path on input x.
- At function level, each loop is collapsed to its header. Inside an unrolled iteration, the body is a DAG in which the back-edges have been removed.

Required invariants, for every lowered block b and every CFG edge e = (p→b):

- **(P1) Block predicate is exact:** `block_pred[b](x) = [b ∈ π(x)]`. For the entry block it is the constant 1.
- **(P2) Edge predicate is exact:**
  - `edge(p→b) = block_pred[p] ∧ c_p` when p ends in `br c_p, b, other`.
  - `edge(p→b) = block_pred[p] ∧ ¬c_p` when p ends in `br c_p, other, b`.
  - `edge(p→b) = block_pred[p]` when p ends in `br b`.
  - **`edge(p→b) = block_pred[p]` when p ends in `br c, b, b`**, because both polarities enter b.
- **(P3) Join equation:** `block_pred[b] = OR over all CFG edges e into b of edge(e)`. Dropping an edge is exact only if `block_pred[src] ≡ 0`, i.e. src is not reachable from the entry.
- **(P4) Mutual exclusion and coverage at each join:**
  - For every phi or multi-return merge at b, and every x: #{distinct source blocks s with edge(s→b)(x)=1} equals 1 if b ∈ π(x), otherwise 0.
  - This follows from P1 through P3 in a DAG, since a path enters each block at most once.
  - It also requires phi incoming blocks = CFG predecessors of b. A spurious entry breaks exclusion; a missing entry breaks coverage.
  - Duplicate entries for the same block must carry identical values (LLVM's rule).
- **(P5) Loops:**
  - A header phi's initial value is the merge of its pre-header incomings, weighted by their edge predicates.
  - Its loop-carried value is the merge of its latch incomings, weighted by the iteration-local edge predicates.
  - `header→exit` must be the loop's only exit edge. Under the `LoopGuard` convergence invariant, `edge(H→exit) = block_pred[H]`, which is what the function-level code uses.

Known caveat, unchanged by this proposal: on inputs where the Julia source throws (a branch into `:__unreachable__`), no return block is active. P4 then fails at the multi-return merge, and the output is the default (last) value.

## 2. Reachability of each site, with evidence

The harness redefined `_compute_block_pred!`, `_edge_predicate!` and `resolve_phi_predicated!` to log every firing and record the edge wires. It then simulated the forward gates of `lower(...; fold_constants=false)` exhaustively over Int8 inputs, compared outputs with the Julia reference, and checked P4 at every recorded merge.

**Corpus, with no firings and no P4 violations:** f1–f6 (diamonds, nested diamonds, early returns, `&&`/`||`, ternary chains, switches at `optimize=true`) and l2, l3, l4, l6, l7 (data-dependent loops: `continue`, diamond body, pre-loop ternary), each at both `optimize=false` and `optimize=true`.

A static CFG validator (§4.2) reported no violations on: soft_fadd, soft_fmul, soft_fma, soft_exp, soft_sin and soft_fptosi at both settings, plus soft_fdiv and soft_fsqrt at `optimize=true` (their `optimize=false` extraction fails on an undef operand); jghk multi-return sret f and g; the q/r/g7 integer functions; and switch-bearing f6. Real Julia IR does contain blocks with no predecessor (`after_noret`, zero instructions, branching to `:__unreachable__`), but none of them feeds a live block.

### Site 1: `haskey(block_pred, p) || continue` (phi.jl:58)

How a recorded predecessor p can lack a predicate:
- At function level, forward predecessors come earlier in topological order.
- Loop-body blocks never record function-level edges. The loop exit gets `hlabel` pushed by `lower_loop!`.
- Inside a loop, `iter_preds` holds only in-region blocks that have already been lowered.
- The only remaining case is **p not reachable from the entry**: a root other than the entry, with no predecessors. It is lowered without a predicate but still records edges to its successors.

Findings:
- **Valid IR (benign):** H4c is a dead block feeding live block M. The site fires, the result is exact (0/256 wrong), and the true predicate of p is 0. A dead chain D1→D2→M currently fails with "no predicate contributions", which is a spurious rejection.
- **Malformed input (silent miscompile):** a `ParsedIR` with an unexpanded `IRSwitch` in block S. The driver has no `else` branch for unknown terminators, so S's successors get no predicate and M's predicate drops them. **49/256 wrong**, and `verify_reversibility` passes. Expanding the switch in the same case gives 0 wrong.
- **Third silent arm:** p has `branch_info` but neither target is `label`, so its contribution vanishes. It never fired in the corpus; with a consistent `preds`/`branch_info` it cannot occur.

### Site 2: `_edge_predicate!` fallthrough (phi.jl:120–130)

- The site requires a phi incoming from a block that is not a CFG predecessor. That is invalid LLVM, but `LLVM.parse` does not verify, and `_expand_switches` A11 deliberately leaves such an incoming in place.
- H9: `phi [99, %S], …` where S is a switch block that does not branch to M. After expansion S has `branch_info (cmp, A, Bb)`, and the edge predicate becomes `block_pred[S]`. **127/256 wrong**, P4 violated on 127/127 of the affected inputs.
- The final "unconditional" return is equally unchecked: a phi citing any non-predecessor that ends in an unconditional branch also gets `block_pred[src]`.
- **Valid IR: not reachable.**
  - Function-level `branch_info[p]` is p's own terminator, and incoming ⊆ preds implies p targets the phi block.
  - The loop-exit phi from `hlabel` takes the unconditional arm on purpose, which is correct by P5.
  - The multi-return merge passes return blocks, which have no `branch_info`.

### Same-target branch `br i1 %c, label %X, label %X`

- Both functions would return `pred∧c`, which is wrong by P2.
- It is never reached: the driver pushes the predecessor twice, and the Bennett-p94b duplicate assertion fires.
- It is a loud but **spurious rejection of valid IR**:
  - H1 (with phi `[1,%B],[1,%B]`): AssertionError.
  - H1b (no phi): AssertionError.
  - H2, `switch … label %M [1→A, 2→M]`: `_expand_switches` emits `_sw_top_2: br cmp, M, M`, so AssertionError. Any switch whose last case targets the default hits this.
- In a loop latch, `br c, H, H` works today (H12).

### Switch duplicate targets (H3)

Two cases target T, and the phi lists S twice. Expansion yields 4 incomings (S and `_sw_S_2`, each twice). Output is correct (0/256). The raw P4 count is 2 on 2 inputs, but the count by distinct source block is 0. This is benign, though it wastes gates.

### Adjacent silent miscompiles (cfg.jl `lower_loop!`)

| case | CFG feature | wrong / 256 via official pipeline |
|---|---|---|
| g1 `n=x&7; if x>50; n=x&3; end; while n>0 …` (`optimize=false`) | header phi `[L4, top.L5_crit_edge, latch]`: two pre-headers | **40** |
| g2 / g4 (same shape, different carried values) | two pre-headers | **128 / 128** |
| H5 `.ll`: P1/P2 → self-loop H | two pre-headers | **127** |
| H6′ `.ll`: header exit on true, B → LA or LB, both latches | two latches | **160** |
| l5 `while n>0; if s>9; break; end; …` (`optimize=false`) | body block L8 → exit L12, which has no phi | **96** |

Cause: `lower_loop!` lines 163–177 overwrite `pre_op`/`latch_op` with the last matching incoming. The body walk collects the break block, and its exit edge is silently ignored.

Loud but misleading, recorded as a follow-up only:
- A header of the form `br c, body, exit` whose true target is not a latch has its exit mis-identified. H8 fails with "IRRet in loop body".
- Rotated loops that exit from the latch fail the same way.

## 3. Root cause, in one sentence

Sites 1 and 2 turn "this edge doesn't exist" or "this predecessor was never lowered" into an over- or under-approximated predicate instead of an error. The loop code turns "more than one incoming edge" into "the last one".

## 4. The fix (exact code)

### 4.1 `src/lowering/cfg.jl`: canonicalization and validator (new, placed above `find_back_edges`)

```julia
"""
    _canonicalize_same_target_branches(blocks) -> Vector{IRBasicBlock}

`br i1 %c, label %X, label %X` is semantically `br label %X` (both polarities
enter X; edge predicate = block_pred[src]). The polarity-based predicate code
cannot express that, so rewrite it before lowering. Arises from
`_expand_switches` whenever the last case targets the default. Returns `blocks`
itself (identity) when nothing changes, so every other program is byte-identical.
"""
function _canonicalize_same_target_branches(blocks::Vector{IRBasicBlock})
    _same(t) = t isa IRBranch && t.cond !== nothing && t.true_label === t.false_label
    any(b -> _same(b.terminator), blocks) || return blocks
    return IRBasicBlock[_same(b.terminator) ?
        IRBasicBlock(b.label, b.instructions, IRBranch(nothing, b.terminator.true_label, nothing)) : b
        for b in blocks]
end

"""
    _check_predication_cfg(blocks) -> Set{Symbol}

Establish the structural preconditions of predicated lowering (CLAUDE.md
"Phi Resolution and Control Flow — CORRECTNESS RISK") and return the set of
blocks unreachable from the entry. Checks:
 (V1) every terminator is IRBranch or IRRet (IRSwitch must already be expanded);
 (V2) every branch target is a block of this function or `:__unreachable__`;
 (V3) the entry block has no predecessors;
 (V4) for every phi at block b: incoming blocks ⊆ CFG preds(b) (else the edge
      predicate is undefined — the old `_edge_predicate!` fallthrough), every CFG
      pred of b has an incoming (else coverage fails and the MUX chain silently
      yields the last value), and duplicate incomings from one block agree.
"""
function _check_predication_cfg(blocks::Vector{IRBasicBlock})
    labels = Set{Symbol}(b.label for b in blocks)
    preds = Dict{Symbol,Set{Symbol}}()
    succs = Dict{Symbol,Vector{Symbol}}()
    for b in blocks
        t = b.terminator
        succs[b.label] = Symbol[]
        if t isa IRBranch
            for s in branch_targets(t)
                s === :__unreachable__ && continue
                s in labels || error("lower: block $(b.label) branches to $s, which is not a " *
                    "block of this function — the edge would be silently dropped from " *
                    "path-predicate computation")
                push!(get!(preds, s, Set{Symbol}()), b.label)
                push!(succs[b.label], s)
            end
        elseif !(t isa IRRet)
            error("lower: block $(b.label) has terminator $(typeof(t)); only IRBranch/IRRet " *
                  "are lowerable (IRSwitch must be expanded by `_expand_switches` first). An " *
                  "unhandled terminator contributes no CFG edges, so its successors' path " *
                  "predicates would silently omit it")
        end
    end
    entry = blocks[1].label
    haskey(preds, entry) && error("lower: entry block $entry has predecessors " *
        "$(sort!(collect(preds[entry]))); the entry path predicate is the constant 1")
    for b in blocks, inst in b.instructions
        inst isa IRPhi || continue
        ps = get(preds, b.label, Set{Symbol}())
        seen = Dict{Symbol,IROperand}()
        for (val, blk) in inst.incoming
            blk in ps || error("lower: phi %$(inst.dest) in block $(b.label) has an incoming " *
                "from $blk, which is not a CFG predecessor of $(b.label) (predecessors: " *
                "$(sort!(collect(ps)))) — its edge predicate is undefined (false-path sensitization)")
            if haskey(seen, blk)
                seen[blk] == val || error("lower: phi %$(inst.dest) in block $(b.label) lists " *
                    "predecessor $blk twice with different values ($(seen[blk]) vs $val)")
            else
                seen[blk] = val
            end
        end
        for p in ps
            haskey(seen, p) || error("lower: phi %$(inst.dest) in block $(b.label) has no " *
                "incoming for CFG predecessor $p — control arriving via $p would fire no edge " *
                "predicate and the MUX chain would silently yield the last incoming value")
        end
    end
    reach = Set{Symbol}([entry]); stack = [entry]
    while !isempty(stack)
        u = pop!(stack)
        for v in succs[u]
            v in reach || (push!(reach, v); push!(stack, v))
        end
    end
    return setdiff(labels, reach)
end
```

### 4.2 `src/lowering/driver.jl`

**(a)** Replace line 180, `blocks = parsed.blocks`, with:

```julia
    # Bennett-<bead>: predication preconditions (CLAUDE.md phi-resolution rules).
    blocks = _canonicalize_same_target_branches(parsed.blocks)
    entry_unreachable = _check_predication_cfg(blocks)
```

**(b)** In the `for label in order` predicate computation (lines 240–261), add a final branch:

```julia
        elseif !(label in entry_unreachable)
            error("lower: block $label is reachable from the entry but none of its " *
                  "predecessors was lowered before it — its path predicate would be undefined")
        end
```

**(c)** In the terminator processing (lines 318–336), stop entry-unreachable blocks from recording edges. Keep the `resolve!` of the condition so gates stay byte-identical:

```julia
        elseif term isa IRBranch && term.cond !== nothing
            if !(label in loop_headers)
                ... (unchanged: _ws/_gs, cw = resolve!(...), gate_group push)
                if !(label in entry_unreachable)   # a dead block's edges carry predicate 0: omitting them is exact
                    branch_info[label] = (cw, term.true_label, term.false_label)
                    push!(get!(preds, term.true_label, Symbol[]), label)
                    push!(get!(preds, term.false_label, Symbol[]), label)
                end
            end
        elseif term isa IRBranch
            if !(label in loop_headers) && !(label in entry_unreachable)
                push!(get!(preds, term.true_label, Symbol[]), label)
            end
        elseif !(term isa IRRet)
            error("lower: block $label has unsupported terminator $(typeof(term))")
        end
```

### 4.3 `src/lowering/phi.jl`

**`_compute_block_pred!`**: replace lines 57–79 with:

```julia
    for p in pred_list
        # Every recorded predecessor carries a predicate: forward preds precede
        # `label` in topo order, entry-unreachable blocks record no edges
        # (driver.jl), loop-body blocks record only into iteration-local dicts.
        # The pre-fix `continue` silently dropped a term from the OR.
        haskey(block_pred, p) ||
            throw(AssertionError("_compute_block_pred!: predecessor $p of block $label has no " *
                  "path predicate; omitting it would silently weaken block_pred[$label] " *
                  "(CLAUDE.md phi-resolution rules)"))
        length(block_pred[p]) == 1 || throw(...)   # unchanged Bennett-p94b check
        if haskey(branch_info, p)
            (cw, tlabel, flabel) = branch_info[p]
            tlabel === flabel && throw(AssertionError("_compute_block_pred!: block $p has a " *
                  "conditional branch with identical targets ($tlabel); " *
                  "`_canonicalize_same_target_branches` must run before lowering"))
            if tlabel == label
                push!(contributions, _and_wire!(gates, wa, block_pred[p], cw))
            elseif flabel == label
                not_cw = _not_wire!(gates, wa, cw)
                push!(contributions, _and_wire!(gates, wa, block_pred[p], not_cw))
            else
                throw(AssertionError("_compute_block_pred!: $p is recorded as a predecessor of " *
                      "$label but branches to ($tlabel, $flabel) — preds/branch_info inconsistent"))
            end
        else
            push!(contributions, block_pred[p])
        end
    end
```

**`_edge_predicate!`**: replace lines 120–130 with:

```julia
    if haskey(branch_info, src_block)
        (cw, tlabel, flabel) = branch_info[src_block]
        tlabel === flabel && throw(AssertionError("_edge_predicate!: block $src_block has a " *
              "conditional branch with identical targets ($tlabel); " *
              "`_canonicalize_same_target_branches` must run before lowering"))
        tlabel == phi_block && return _and_wire!(gates, wa, block_pred[src_block], cw)
        if flabel == phi_block
            not_cw = _not_wire!(gates, wa, cw)
            return _and_wire!(gates, wa, block_pred[src_block], not_cw)
        end
        throw(AssertionError("_edge_predicate!: block $src_block branches conditionally to " *
              "($tlabel, $flabel), neither of which is the merge block $phi_block; there is no " *
              "edge $src_block→$phi_block and returning block_pred[$src_block] would be an " *
              "over-approximated edge predicate (false-path sensitization)"))
    end
    # Unconditional edge. Callers guarantee src_block→phi_block exists:
    # lower_phi! via `_check_predication_cfg` (incoming ⊆ preds); the multi-ret
    # merge passes IRRet blocks (phi_block === Symbol("")); loop seed/exit merges
    # from a loop header use block_pred[header] — exact under the LoopGuard
    # convergence invariant because header→exit is the ONLY exit edge
    # (`_collect_loop_body_blocks`).
    return block_pred[src_block]
```

Also update the `resolve_phi_predicated!` docstring. Replace "Correct for arbitrary CFGs" with the preconditions: canonicalized CFG, `_check_predication_cfg` passed, single-exit loops.

### 4.4 `src/lowering/cfg.jl`: loop phi seeding, latches, and the second exit

**New helper:**

```julia
"""Merge a loop-header phi's pre-header (seed) or latch incomings. Identical
operands → single `resolve!` (byte-identical to the pre-fix single-incoming
path); otherwise a predicated MUX over the edges into `hlabel`."""
function _merge_loop_phi_incoming!(gates, wa, vw, inc::Vector{Tuple{IROperand,Symbol}},
                                   width::Int, hlabel::Symbol, block_pred, branch_info;
                                   audit_site::Symbol=:loop_seed, audit_active_neg::Vector{Int}=Int[])
    ops = unique(v for (v, _) in inc)
    length(ops) == 1 && return resolve!(gates, wa, vw, ops[1], width)
    wired = [(resolve!(gates, wa, vw, v, width), b) for (v, b) in unique(inc)]
    return resolve_phi_predicated!(gates, wa, wired, block_pred, width;
                                   phi_block=hlabel, branch_info, audit_site, audit_active_neg)
end
```

**In `lower_loop!`:**

- Replace lines 158–181, the `pre_op`/`latch_op` split and the `pre_header_preds` push (which only re-adds duplicates into `preds[hlabel]`), with:

  ```julia
      latch_labels = Set(src for (src, dst) in back_edges if dst == hlabel)
      phi_info = Tuple{Symbol,Int,Vector{Tuple{IROperand,Symbol}},Vector{Tuple{IROperand,Symbol}}}[]
      for inst in header.instructions
          inst isa IRPhi || continue
          pre = Tuple{IROperand,Symbol}[]; lat = Tuple{IROperand,Symbol}[]
          for (val, blk) in inst.incoming
              (blk in latch_labels || blk == hlabel) ? push!(lat, (val, blk)) : push!(pre, (val, blk))
          end
          isempty(pre) && throw(AssertionError("lower_loop!: phi $(inst.dest) has no pre-header incoming"))
          isempty(lat) && throw(AssertionError("lower_loop!: phi $(inst.dest) has no latch incoming"))
          push!(phi_info, (inst.dest, inst.width, pre, lat))
      end
  ```

- Seed, replacing lines 208–210:

  ```julia
      for (dest, width, pre, _) in phi_info
          vw[dest] = _merge_loop_phi_incoming!(gates, wa, vw, pre, width, hlabel,
                                               opts.block_pred, branch_info)
      end
  ```

- Latch values, replacing lines 350–353. Here `exit_cond_wire` has already been computed at step (c):

  ```julia
          latch_vals = Vector{Int}[]
          for (_, width, _, lat) in phi_info
              push!(latch_vals, _merge_loop_phi_incoming!(gates, wa, vw, lat, width, hlabel,
                        iter_block_pred, iter_branch_info;
                        audit_site=:loop_latch, audit_active_neg=[exit_cond_wire[1]]))
          end
  ```

  Keep `phi_info` destructuring as `(dest, width, _, _)` at step (e).

**In `_collect_loop_body_blocks`**, inside `for t in branch_targets(bterm)`, after the `back_set` skip:

```julia
            t == exit_label && error("lower_loop!: body block $b of loop $hlabel branches to " *
                "the loop exit $t — a second loop exit (e.g. `break`) is not supported: the " *
                "unroller freezes loop-carried state on the HEADER's exit condition only, so " *
                "iterations would silently continue past the break (Bennett-<bead>)")
```

Also fix the docstring claim that multi-latch fails loud.

### 4.5 Optional debug-mode runtime checker (`phi.jl`; zero gates when off)

```julia
struct PredAuditRecord
    site::Symbol              # :phi, :multi_ret, :loop_seed, :loop_latch
    phi_block::Symbol
    active_pos::Vector{Int}   # merge is live iff all(active_pos) && !any(active_neg)
    active_neg::Vector{Int}
    srcs::Vector{Symbol}
    edge_wires::Vector{Int}
end
const PRED_AUDIT = Base.ScopedValues.ScopedValue{Union{Nothing,Vector{PredAuditRecord}}}(nothing)
```

Add kwargs `audit_site::Symbol=:phi, audit_active_pos::Union{Nothing,Vector{Int}}=nothing, audit_active_neg::Vector{Int}=Int[]` to `resolve_phi_predicated!`. After computing `edge_preds`, add:

```julia
    rec = PRED_AUDIT[]
    if rec !== nothing
        pos = audit_active_pos !== nothing ? audit_active_pos :
              phi_block === Symbol("") ? Int[] : [block_pred[phi_block][1]]
        push!(rec, PredAuditRecord(phi_block === Symbol("") ? :multi_ret : audit_site, phi_block,
                                   pos, audit_active_neg, [b for (_, b) in incoming],
                                   [e[1] for e in edge_preds]))
    end
```

Test helper:
- Run `with(PRED_AUDIT => recs) do lower(p; fold_constants=false, …) end`.
- Simulate the forward gates on a `BitVector`.
- For each record, assert #distinct `srcs` with a true edge == (live ? 1 : 0).

Prototype results: 0 violations on f2, f3, f6, l6 and g4 at both settings, and on H6′ (18 latch records). The same property flagged 127/127 violations on H9 under the old code.

Limitation: the checker verifies merges that exist. The multi-preheader bug created no merge at all, so it is caught only by output comparison or by §4.4.

## 5. Gate-count impact (measured; `lower` gates and `n_wires`)

**Identical before and after the full patch (§4.1–4.4):**
- f1–f6, r, l2, l6, l7 at both `optimize` settings.
- q (two Int8 arguments, about 799k gates) at both settings.
- jghk f at both settings; jghk g at `optimize=true`.
- soft_fadd at `optimize=false` (33,876 gates / 40,031 wires).
- H3 (switch with duplicate targets), H4c (dead block into live), H12 (latch `br c, H, H`).
- Loop fix alone: identical on l2–l7 at both settings (l5 at `optimize=true`) and on g1, g2, g4 at `optimize=true`.

**Changed only where previously wrong or rejected:**

| case | before (gates, wrong) | after (gates, wrong) |
|---|---|---|
| g1 | 1794, 40 wrong | 1805, 0 |
| g2 | 1792, 128 | 1827, 0 |
| g4 | 1811, 128 | 1853, 0 |
| H5 | 1877, 127 | 1893, 0 |
| H6′ | 2417, 160 | 2973, 0 |
| H1 | assertion error | 125 gates, 0 wrong |
| H2 | assertion error | 92 gates, 0 wrong |
| H9 | 127 wrong | loud error |
| unexpanded IRSwitch | 49 wrong | loud error |
| l5 at `optimize=false` | 96 wrong | loud error |

Why zero change is guaranteed:
- Canonicalization returns the same vector unless a same-target branch exists. Such branches currently always fail, except in a latch, where the condition is an SSA value and `resolve!` emits no gates (H12 is identical).
- Dead blocks no longer recording edges removes exactly the terms the old `continue` dropped.
- The loop seed and latch take the single-operand fast path whenever all incomings agree.

## 6. Red→green test plan (new `test/test_<bead>_predication_soundness.jl`)

**R1.** g1, g2, g4 at `optimize=false`, `max_loop_iterations=9`, exhaustive Int8 → 0 wrong. RED today: 40 / 128 / 128.

**R2 and R3.** `.ll` fixtures H5 (two pre-headers) and H6′ (two latches, header `br i1 %done, label %E, label %B`) → 0 wrong. RED today: 127 and 160.

**R4.** l5 at `optimize=false` → `@test_throws` with a message containing "second loop exit". RED today: 96 wrong, silent.

**R5.** H1, H1b and H2 (switch whose last case is the default) → compile, exhaustive 0 wrong. RED today: AssertionError.

**R6.** H9 (`.ll` phi citing a non-predecessor switch block) → `@test_throws ErrorException` matching "not a CFG predecessor". RED today: 127 wrong.

**R7.** Hand-built `ParsedIR` with an unexpanded `IRSwitch` (fixture §2, blocks top/S/A/A2/M/P/Q/J) → error matching "IRSwitch must be expanded". RED today: 49 wrong.

**R8 (unit tests):**
- `_edge_predicate!` with `branch_info = Dict(:A => (w, :X, :Y))` and `phi_block = :B` → `@test_throws AssertionError`. Today it returns `block_pred[:A]`.
- `_compute_block_pred!` with `preds = Dict(:C => [:A, :B])`, `block_pred` containing only `:B` → throws. Today it silently returns B's predicate.
- Same, but with `branch_info[:A] = (w, :X, :Y)` and both A and B present → throws. Today A's contribution is silently dropped.
- Same-target `branch_info` (`:A => (w, :C, :C)`) → throws in both functions.

**R9 (green guards):**
- H4c (dead block into live block, no phi) → compiles, 0 wrong.
- Dead chain D1→D2→M → compiles (today: "no predicate contributions").
- The existing `test_p94b` T1–T6 and `test_jepw_diamond_in_body` must pass unchanged.

**R10 (gate-count pins).** Record `gate_count(reversible_compile(...))` on pre-change code for f2, f3, f6, l2, l6, r, soft_fadd and a switch-bearing f6 at `optimize=true`. Assert equality after the change. BENCHMARKS baselines must not move.

**R11 (audit).** With `PRED_AUDIT` active, run exhaustive Int8 over f2, f3, f6, l6, g4 and H6′ → 0 violations. Negative control: call `resolve_phi_predicated!` directly with overlapping edge predicates → the helper reports violations.

**R12.** Run the full suite. New error strings use the `lower:`, `lower_loop!:`, `_compute_` and `_edge_` prefixes, satisfying `test_f6qa`.

## 7. Risks and follow-ups

- **Validator false positives.** Some extraction rewrites could leave phis naming non-predecessors or missing predecessors: sret funnel handling, the `ptr_cells` dead-block pruner, and `_expand_switches` A11's "leave alone" branch. My sample showed no violations, but the full suite must run. Any hit is a latent extraction bug. BennettVM (`target=:reversible_vm`) does not call `lower()`, so it is unaffected.
- **The second-exit error can turn currently-passing tests red** where a break is never taken on the tested inputs. Those tests are latent miscompiles: mark them `@test_broken` and file a bead for real multi-exit support. That needs a per-iteration done flag, a freeze MUX driven by the running done state, and exit-phi merges over exit edges across iterations.
- **Follow-ups, not in this change:**
  - Make `_expand_switches` A11 fail loud at the source.
  - Run `LLVM.verify(mod)` in `.ll` ingest.
  - Identify the loop exit by loop membership, so `br c, body, exit` headers and latch-exits are handled instead of failing with a misleading "IRRet in loop body".
  - Deduplicate same-block phi incomings. This reduces gates for H3-like switches, so it needs its own baseline update.
  - Phi incomings from entry-unreachable blocks (H4b) could be dropped rather than rejected.
  - Separate pre-existing issue: the loop convergence guard is not gated by the header's predicate, so a skipped loop with garbage seeds can still trip `LoopGuard`.
- **Throw-arm inputs** still violate P4 at the multi-return merge. Document it as a known exception; the audit helper should allow `:multi_ret` on throwing inputs.

### Critical files for implementation
- /home/user/Bennett.jl/src/lowering/phi.jl
- /home/user/Bennett.jl/src/lowering/cfg.jl
- /home/user/Bennett.jl/src/lowering/driver.jl
- /home/user/Bennett.jl/src/extract/module_walk.jl (`_expand_switches`, A11 follow-up)
- /home/user/Bennett.jl/test/test_p94b_predicate_asserts.jl (existing unit tests to keep green or extend)