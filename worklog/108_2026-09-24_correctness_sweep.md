# Worklog chunk 108 — 2026-09-24 — correctness sweep: stwr, t9rh, c6ex, gcf7 (5viz FAIL), hsm3

## Session log — 2026-09-24 (cont.) — linear pass over the most important issues

Continuation of the 2026-09-24 cloud session (first half in worklog/107). Four 3+1
core changes landed, one hostile review failed a landing, and the v2 sweep's
never-filed v1 bugs were triaged into beads. Container restarted twice mid-session:
**background agent hand-backs are lost on restart** — recover them from
`/root/.claude/projects/.../subagents/agent-<id>.jsonl` (the SubagentHandback
tool_use input holds the full report; the last text message is only a summary).
Archive every proposal into `docs/design/<bead>/` as soon as it arrives.

**Bennett-stwr (CLOSED) — add=:cuccaro soundness.** Liveness subsystem deleted
(`compute_ssa_liveness`/`ssa_liveness`/`inst_counter`); replaced by the order-free
exclusive-reader criterion `compute_inplace_targets` (exactly one operand occurrence
in the whole ParsedIR incl. terminators; arg or fresh-wire def; IRPhi excluded; empty
set in loop contexts) + lowering-time `vw` exclusivity scan + `delete!(vw, op2)`;
op1 commutative swap; else copy-in (+W CNOT/+W wires, Toffoli unchanged). Key
finding: **ValueEager and Eager do NOT fall back to plain Bennett on in-place
groups** (only Checkpoint/PebbledGroup do) — "last use" is unsound under non-LIFO
uncompute; the criterion must be "exclusive reader". Before: soft_fadd under
`add=:cuccaro` 97/100 wrong, zero simulator errors. All pinned counts unchanged.
Design: docs/design/stwr/.

**Bennett-t9rh (CLOSED) — host-CPU-dependent extraction.** `code_llvm(optimize=true)`
runs Julia's O-pipeline under the host JIT TargetMachine; AVX-512 SLP emitted a
horizontal-add with a poison lane that crashed lowering; loop-bearing callees drifted
silently across hosts (udiv callee 825k x86-64 / 1.59M haswell / 12.6M Zen3). Fix:
(1) sound poison-lane propagation in vectors.jl; **undef is NOT poison** (new
`UNDEF_LANE`; `or i8 undef, 255` = 255) — the proposers' shared recipe would have
miscompiled `select ?, undef, X`; intrinsic propagation allowlisted
(`_POISON_PROPAGATING_INTRINSICS`); (2) `src/extract/target_pin.jl`: unstripped
unoptimised dump → `JuliaPipeline(opt_level=2)` under a pinned TargetMachine →
emulate `jl_dump_function_ir`'s strip. **Maintainer decision: pin `x86-64-v3`.**
Optimising the already-stripped `optimize=false` text is NOT faithful (tbaa +
addrspace(10) lost). No pinned count moved; subprocess tests prove `-C x86-64 -O1`
and `-C znver3` reproduce in-process counts. CLAUDE.md rule 5 amended.
Design: docs/design/t9rh/.

**Bennett-c6ex (CLOSED) — predication soundness.** The v2-review sites were silent
only on malformed IR, but BOTH proposers independently found **silent miscompiles
from plain Julia at optimize=false in `lower_loop!`**: a loop header with several
pre-header incomings kept only the LAST (`if/else` falling into `while`: up to
2268/2304 wrong); multi-latch kept the last latch; a `break` second exit was never
modelled (96/256). optimize=true (loop-simplify) hides all three — the default path
was safe, the Rule-5 test path was not. Fix: predicate-merged multi-preheader seed;
distinct-value multi-latch and second exits fail loud; up-front CFG validator
(`_check_predication_cfg`, V1–V4); same-target `br c, X, X` canonicalised
(fixes valid-IR false rejections from switch expansion); dead blocks record no
edges; `PRED_AUDIT` mutual-exclusion auditor. Gotcha: a stray phi incoming only
miscompiles when it is not LAST (the last incoming is the MUX default).
Design: docs/design/c6ex/.

**Bennett-gcf7 hostile review of 5viz = FAIL.** Executed silent miscompile: the
5viz arm certifies `load ptr, ptr @jl_global#N` by NAME; Julia names every heap
literal that way. Worse, **Bennett-hsm3 (P1, pre-existing)**: `const RI = Ref(42);
RI[]+x` already extracts under ptr_cells to a read of the 416r.13 zero blob and
runs+reverses on BennettVM returning x. **Maintainer decision: semantic
certification** (resolve the alias address to the object in the live session;
admit only the empty GenericMemory singleton; ADR 0021 D3 amendment: address used
to classify at extraction time, never baked in). 3+1 in progress. All claimed
5viz marker advances were RED-verified in a pristine worktree.

**v2-sweep triage:** filed c6ex, sy9t, g7d6, 9k7n, exb3, gygy, vscb, mjtl, 4iuj
(+ follow-ups vpgj, 0a6f, lcye, htu2, t3ou, yn08, nyln, 2o4r, v0rc, n9o8, je4n,
8nfb, hsm3, fnxh). The sweep's findings were a better bug list than the tracker.

**Process gotchas:** worktree agents may be based on `main`, not the session
branch — tell them to `git merge --ff-only claude/loving-ptolemy-8a914n` first;
the Julia compile cache is shared across worktrees ("being precompiled by another
process"), ~75–100 s per source edit; `pkill -f <pattern>` kills your own shell if
the pattern is in the command line.
