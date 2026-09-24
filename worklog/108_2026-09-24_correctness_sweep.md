# Worklog chunk 108 — 2026-09-24 — correctness sweep: stwr, t9rh, c6ex, gcf7 (5viz FAIL), hsm3

## Session log — 2026-09-24 — SESSION CLOSE (wind-down) — handoff: READ FIRST

**State of main (fast-forwarded from claude/loving-ptolemy-8a914n):** stwr, t9rh,
c6ex, hsm3, q9pi + 6 hygiene beads landed; all 3+1 design archives under
docs/design/{stwr,t9rh,c6ex,hsm3}/, gcf7 review + probes under docs/design/.

**Bennett-hsm3 (CLOSED)** — semantic certification of `jl_global#N` literals:
`src/extract/jlglobal_cert.jl`. The address is NEVER dereferenced (codegen temp
roots are dropped after emission on the reflection path); classification = membership
of the address in the live empty-GenericMemory singleton set (`T.instance` over
`Core.TypeName.cache`/`.linearcache` — these are `@atomic`: read with
`getfield(tn, :cache, :acquire)`; a plain iteration threw a TypeError in precompiled
code), taken inside a GC-off window opened BEFORE emission. Refusal is USE-directed
(`_assert_no_refused_jl_global_use` after the walk): throw-path String literals in
pruned blocks don't re-wall Dict/push!. Objects are keyed `jl_global#N.obj` —
Julia names the first slot load's SSA value identically to the slot, so "names[v]
=== G" proves nothing. `.ll` ingest refuses unless `jl_globals=:live_session`.
Data-ptr cell = non-null trapping sentinel `2^48+2^47` (gcf7 D3). Any
`jl_global#N.jit` alias operand fails loud (fnxh/O1). BennettVM: ADR 0021
Amendment B + `test_hsm3_literal_certification_vm.jl`.

**Full-suite gate (final tree):** `Pkg.test()` OOM-KILLS on this 16 GB container
(single runtests process reaches ~12 GB RSS; a concurrent precompile tips it over —
dmesg "Memory cgroup out of memory"). Ran instead as 9 chunks of ~40 files, each a
separate `julia --check-bounds=yes test/runtests.jl <files…>` process: **~1.53M
assertions**; the only failures were (a) test_g27k's fixed 4000-char source window
(hsm3 pushed the anchor to offset 3989 — false red; now bounded by the catch
terminator) and (b) Aqua "not found" — an artifact of running runtests.jl outside
`Pkg.test` (test extras not on the load path); green under
`Pkg.test(test_args=["hygiene_aqua_jet"])`. Bennett-gm83 (parallel test runner)
would make this the default.

**Priority order for the next agent:**
1. Bennett-23ml (P2) — the 5viz BennettVM E2E gate (now non-vacuous); then close
   Bennett-5viz (P1, blocked on it). Do NOT build walls 12–14 before.
2. The remaining v2-sweep correctness bugs: 9k7n (lower_call! free-list aliasing),
   g7d6 (bit_width drops globals), sy9t (load-legacy silent skip), exb3
   (fold_constants disables strategies), n4di (GlobalAlias swallow), n9o8 (loop guard
   not gated by header predicate), gygy (doctest test asserts the opposite of truth).
3. 0a6f / jgyx (lower_call! drops compile options), vpgj (loop adds ignore explicit add).
4. Bennett-amah: the dolt noms blob is ~68 MB (GitHub hard limit 100 MB; grows ~0.85 MB
   per busy session).
v2 (Bennett-0orf) remains parked by maintainer choice.

**Environment for cloud sessions:** Julia 1.12.7 (history: 1.12.5; both work);
**bd MUST be 1.0.2** (`npm i -g @beads/bd@1.0.2`) for the schema-v32 DB — newer bd
refuses writes pending a migration that must be done from ONE machine only; clone
BennettVM to `/home/user/bennettvm.jl` + symlink `BennettVM.jl`; BennettVM's default
branch is `master`, Bennett's is `main`.

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
