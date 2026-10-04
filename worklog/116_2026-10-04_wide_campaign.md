# Worklog chunk 116 — 2026-10-04 — wide campaign (six slots)

Previous: chunk 115 (2026-10-03 session close and handoff).

## Session log — 2026-10-04 — Bennett-t5u1 landed (d7c8da4): an sret return funnel is dropped only when certified inert

**Landed (P1, `src/extract/module_walk.jl` +39, new `test/test_t5u1_sret_funnel_inert.jl`).** The
worker reproduced Astra F3 on main first: the witness compiled, returned 3 where 99 is right, and
`verify_reversibility` passed. `_assert_sret_funnel_inert` now runs at the `sret_drop_block` site
before the block is skipped: each instruction must be the block's `ret void`, in one of the sret
synthesis's suppressed sets, or `_is_pure_value_ref` (the gq1z opcode allowlist; loads non-volatile
and non-atomic); anything else is an `_ir_error` naming function, block and instruction.
Independent counts from the landing logs (rebased tree): t5u1 43/43, jghk 43/43, `test_sret`
4195/4195, gate baselines 39/39. Closed t5u1; filed 8lx4, fh6f.

**Gotchas.**
- `extract_parsed_ir_from_ll` on an sret module forces SROA + mem2reg, so a plain dead store to a
  local alloca in the funnel is gone before extraction and the module compiles correctly. A witness
  that must REACH the funnel check needs a volatile store, a global store or a call.
- A store to the sret slot inside the funnel makes it a store block, so the existing jghk "never
  written" refusal fires, not the new one.
- Every `call` in a funnel is now refused, including ones the converter would drop as benign
  (`llvm.lifetime.end`, `llvm.dbg.*`, `llvm.assume`) — read off the code and the test's `call_pure`
  case, witness not executed. clang at -O1+ plausibly leaves `lifetime.end; ret void` in the common
  return block of a multi-return sret function. Loud, rejects-valid: Bennett-fh6f.
- **There is no C-derived coverage on this box.** `clang` is not installed (rustc is), and `build/`
  — untracked, but present in the main tree and in the slots — holds only `t5_tr1..3` Rust `.ll`.
  A worker's "T5 corpus (C, Julia, Rust) passes" means Julia + Rust; the TC cases self-skip. The
  full suite cannot catch a C-only rejects-valid regression either.
- Not done (the bead's other half): sret-pointer escape to a call / `ptrtoint` in the store blocks
  — a different site (Bennett-8lx4). "Carry aggregates through an effectful funnel" was not filed:
  nothing in the corpus needs it.

**Orchestrator slip worth recording.** Listing the landing logs with `sort | tail -6` dropped the
EARLIEST entry, and for a moment the worker's "land re-ran four files" looked false (three
visible). It was true. List by date filter, not by a truncated sort, before doubting a report.

## Session log — 2026-10-04 — Bennett-6atf landed (0191194): a store to a Julia global is refused; what the worker's report got wrong

**Landed.** Test-only re-pin of `test/test_mrhg_narrow_soundness.jl` (Sonnet worker). Orchestrator
re-run on main's content: 212,834 / 212,834 pass, 58.5 s. Closed 6atf; filed Bennett-oai0.

**Decision (6atf question (b), maintainer delegated): a store to a `jl_global` alias IS refused.**
Probe of the fixture `MRHG_G[] = x; return MRHG_G[] + Int8(1)` (`const MRHG_G = Ref{Int8}(0)`):
- `optimize=true` IR is `store i8 %x, ptr @"jl_global#N.jit"` / `add i8 %x, 1` / `ret`. LLVM
  forwards the LOAD, never the store — a write to a global is observable. gq1z (3a036b2) refuses that
  store, with or without `bit_width`.
- So the old pin "once promoted it must compile and be right" was pinning the pre-gq1z silent skip:
  the circuit computed `x + 1` and dropped the write. The file was green in the full suite at d3d7ba1
  (before gq1z). A circuit cannot mutate Julia global state, so the refusal is right and this is not
  a lost capability. Yesterday's suite did not show it because the earlier error at line 621 aborted
  the testset first.
- `optimize=false` IR stores through a LOADED pointer (`%"jl_global#N" = load ptr, ptr
  @"jl_global#N"`). In a standalone probe (`strategy=:auto`) that reached the narrowing
  `ArgumentError` (`IRStore` refusal) at `bit_width=4`; inside the test file the worker observed the
  gq1z alias refusal instead. Not chased — the IR shape of a global access is context-dependent,
  which is exactly why those two sites accept either loud refusal.
- Same probe, no `bit_width`, `optimize=false`: `AssertionError: lower_store!: no provenance for
  ptr %jl_global#N` — loud, but an assertion from lowering rather than a capability error (noted on
  oai0).

**What had to be corrected in the worker's report — check these on every hand-back.**
- It re-pinned a THIRD site beyond the brief: the `optimize=true` "must compile" case became
  "compiles and is right OR refused", leaving the compile branch dead. An either/or pin on a case
  whose outcome is known is a weakened test; oai0 turns it into a definite refusal and adds a
  fixture whose memory really is promoted (local `Ref`), so "the allowlist is not
  reject-anything-that-touched-memory" stays tested.
- Its stated cause ("the O2 pipeline no longer promotes the global store away") was a guess and is
  wrong; the IR shows the store was always there.
- "`../land` ran it again after the rebase" did not happen: main had not moved, `land` only
  re-tests after a rebase, and there is no landing log. The pass count in the report was "212,7xx".
  A hand-back's test evidence is the worker's own run unless a `logs/land_*` file exists.
- The commit trailer says Claude Opus; the worker was Sonnet (the brief hard-coded the trailer —
  fixed in `BRIEF.md`).

## Session log — 2026-10-04 — campaign setup: per-slot Julia depots (precompiles no longer queue)

**Mode (maintainer, 2026-10-04).** Same as 2026-10-03: six concurrent workers in the fixed slots
`~/Projects/Bennett-slots/s1..s6`, one bead each, land, stop; Opus for coding, Sonnet for queries and
quick fixes, `codex exec -m gpt-6.1-sol` (high) for review at the orchestrator's discretion, no Astra
or Fable subagents. ONE full suite, mid/late session — so Bennett-6rx3 ("full suite first") is folded
into that single run instead of being done first. Quota: up to 5 % over pace on Claude, shared with a
second live session (coordinated by cross-session message); Fable-weekly usage to be brought level
with overall Weekly, which means the orchestrator does more review/triage inline rather than
delegating everything. v2 stays parked.

**Bennett precompiles serialise machine-wide — measured, and the cause read in Julia's source.**
Pre-warming the six slots "in parallel" (shared `~/.julia`, the 2026-10-03 wrapper) took 62 / 125 /
188 / 253 / 314 s for the five slots that had to recompile: strictly one at a time. Each waiting
process logged `Bennett Being precompiled by another process (pid …, pidfile:
~/.julia/compiled/v1.12/Bennett/sMHWJ_wRtK2.ji.pidfile)` — the SAME pidfile from every slot.
- Cause (Julia 1.12.3 `base/loading.jl:3867`): `compilecache_pidfile_path(pkg; flags) =
  compilecache_path(pkg, UInt64(0); project="", flags) * ".pidfile"`. The `.ji` file name hashes the
  active project path (`loading.jl:3155`), so each worktree gets its own cache file, but the pidfile is
  computed with `project=""` — one lock per (package, flag set) per depot. Both live under
  `DEPOT_PATH[1]` (`loading.jl:3150`).
- Consequence under the old wrapper: every source edit in any slot costs ~62 s of compile, and those
  compiles queue across slots. Six workers each recompiling a few times per bead queue behind each
  other, and a queued test could run into the wrapper's 900 s `timeout` and look like a hang.
- Chunk 115's "six slots pre-warm in two minutes (one serially, five in parallel)" was not
  reproduced for a real recompile. A slot whose `src/` is unchanged since its last compile loads
  its existing cache in ~3 s, which is probably what was measured then.

**Fix: a private first depot per slot, stacked on `~/.julia`.** `~/Projects/Bennett-slots/jl` now
sets `JULIA_DEPOT_PATH="$SL/depot/<slot>:$HOME/.julia:"` when run from a slot root (`timeout` default
raised 900 → 1500 s; the old wrapper is kept as `jl.shared-depot`). Measured: three slots recompiling
at once took 73–74 s each, 77 s wall in total, no "Being precompiled by another process" line,
`34 already precompiled` (no dependency was rebuilt), and Bennett's cache was written under
`depot/<slot>/compiled/v1.12/Bennett/` (46 MB per slot). `land` re-tests through the same wrapper.
The full-suite script uses plain `julia` on the main tree / `s0`, so it keeps the default depot.
- **`JULIA_DEPOT_PATH=/x:` does NOT include `~/.julia`.** A trailing empty entry expands to the two
  bundled depots only (`…/julia-1.12.3…/local/share/julia`, `…/share/julia`). The first attempt
  failed in 2 s with `Package LLVM … is required but does not seem to be installed — Run
  Pkg.instantiate()`. The hint is misleading: the Manifest was fine, the package sources were simply
  not on the depot path. List `$HOME/.julia` explicitly.
- A still-valid cache in a later depot is used: after reverting the test edits, every slot loaded
  the `~/.julia` cache for its path in ~2.2 s. Only a real source change compiles into the slot
  depot.
- This is most of Bennett-o540 (precompile-once + shared read-only depot) for the worker slots, and
  it removes the "at most 10 cache files per package name" concern: one path × one flag set per
  depot.

**Other setup facts.** Bead texts are dumped once to `~/Projects/Bennett-slots/beads/<id>.txt`
(`bd show` for all 231 open ids) so workers never run `bd`. `BRIEF.md` gained four rules from
yesterday's failures: new test files start with `using Test, Bennett`; a fix that adds or moves a
refusal must grep `test/` for fixtures containing the refused construct (three landings turned a
neighbour's pin red yesterday); pin a message substring, never a bare `@test_throws ErrorException`;
stop and report rather than exceed ~30 % of context. Orchestrator commits to the main tree are made
under the landing lock (`flock ~/Projects/Bennett-slots/land.lock git commit …`) so they cannot land
between a worker's rebase and its `merge --ff-only`.
