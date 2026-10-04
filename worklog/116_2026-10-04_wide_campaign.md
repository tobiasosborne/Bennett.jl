# Worklog chunk 116 — 2026-10-04 — wide campaign (six slots)

Previous: chunk 115 (2026-10-03 session close and handoff).

## Session log — 2026-10-04 — n9o8 (2ab3748, core cfg.jl) and 2op8 (4796e24) landed; review 1 launched

**Bennett-n9o8 — the loop convergence guard fires only on executions that reach the header.**
`conv_w := ¬header_pred ∨ conv_cond = 1 ⊕ header_pred ⊕ (header_pred ∧ conv_cond)`, written straight
into `conv_w` (NOT + CNOT + Toffoli, no ancilla). `header_pred = opts.block_pred[hlabel][1]` at loop
entry — the same wire the per-iteration predicates (`header_pred ∧ iter_active`) and the exit-phi
masking already use, so gating the guard with it adds no new assumption about that wire.
- The gating is skipped when `_loop_header_always_reached(hlabel, block_map, entry)`: a CFG walk from
  the entry that never enters the header reaches no `IRRet`. `:__unreachable__` edges are not
  completing paths; an unknown entry or a non-`IRBranch` terminator answers false (keeps the gating).
  **Why a CFG walk and not the predicate wire:** pre-headers that come from an if/else join give an
  OR wire whose value is always 1 but which is not the entry wire, so "is `block_pred[header]` the
  constant 1" cannot be read off the wire.
- Pins moved, each +2 forward gates doubled by the reverse pass: c6ex "cl f K8" 3463 → 3467, c6ex
  collatz K20 12903 → 12907, y986 T3 Collatz 14913 → 14917 (Toffoli 2492 → 2494, ancillae
  unchanged). In both Collatz cases `optimize=true` rotates the loop behind an entry guard, so the
  header really is conditional. Loops after an if/else join (g1, pre3) and every t9rh pin are
  unchanged; the `x+1` baselines did not move.
- Evidence on the FINAL code: landing logs n9o8 484/484, i5zn 138, c6ex 115, 73gr 80 + 33, cohv 281,
  gate baselines 39. The worker said it had run `t9rh_pinned` only against an earlier, wider version
  of the gating and had run y986 / `test_loop_explicit` by hand; orchestrator re-runs at 2ab3748:
  `test_t9rh_pinned_target` 34/34, y986 81/81, `test_loop_explicit` 31/31. httg, jepw, stwr and
  `test_bennett` have only the worker's word; the full suite covers them.
- y986 and `test_loop_explicit` still lack `using Test, Bennett` (Bennett-guj0): run them as
  `../jl -e 'using Test, Bennett; include("test/…")'`.
- Open questions handed to review 1, not answered here: a loop nested in a loop (is the inner
  guard gated per outer iteration?), and whether an execution that natively throws before the loop
  (erased error branch, Bennett-jzhh) can now trip or silence a guard.

**Bennett-2op8 (+ gft0) — one rule for every stateful callable.** Closures, callable structs
(Function subtype or not), `Fix1`/`Fix2`, `ComposedFunction`: immutable plain-bits state, `Type{T}`
fields included, is bound as constants; anything else (mutable callable, `Ref`, `Vector`,
`Core.Box`) is an `ArgumentError` on `:expression`, `:tabulate` and `:auto`. Input widths are the
declared arguments under every strategy. The o9sv path was extended, not copied
(`_is_closure_type`, `_tabulate_state_ok`, `_check_tabulate_state` are gone; `_capture_ok` recurses
through immutable concrete structs). Landing logs: 2op8 429/429, o9sv 116/116, 0ysp 63/63, 4ddk
1313/1313, gate baselines 39/39; the worker's "czox re-run by land" has no landing log.
- **Behaviour change that reverses a 2026-10-03 pin:** a MUTABLE callable under `:expression` used
  to compile with its field as a hidden second input (`[8,8]`; 0ysp deliberately left it, u9cc's
  test pinned it). It is now refused on every strategy. That follows the recorded decision ("bind
  immutable isbits, reject the rest"), but it is a rejects-formerly-accepted change — BennettVM has
  not been run against it.
- Before the fix a struct with a `Type{T}` field plus an Int8 compiled to `[128, 64, 8]` under
  `:expression` (a 16-byte object input plus the 64-bit roots input) and was refused under
  `:tabulate`; now `[8]` everywhere. A field that is never read still arrives as an input and is
  bound. Binding uses NOT-preset ancillae, not constant folding, so no gate count moved.
- The Float64 entry needed no change: its SoftFloat wrapper is a closure capturing `f`, so the same
  rule already applied.

**Review 1** (`gpt-6.1-sol` high, read-only, on `s0` detached at 4796e24) over
`2d38524..4796e24 -- src`: t5u1, blnv, vke7, n9o8, 2op8. Prompt in
`~/Projects/Bennett-slots/logs/review_d1.prompt`; it names the specific doubts above per commit and
asks for executed witnesses.

**Quota at 09:35:** Claude Weekly 64.0 % (2.4 % behind pace), Fable 59.0 %, Codex 5.0 %. Since 08:40
both Claude rows rose by 2 points with two Fable sessions and six Opus/Sonnet workers running, so
the Weekly–Fable gap stayed at 5. A single 25-minute reading that showed Fable +1 / Weekly +0 was
rounding at 1 % resolution, not a rate difference.

## Session log — 2026-10-04 — blnv (9110bfa) and vke7 (d659a54) landed; the transcendental contract is ≤2 ULP, not bit-exact; beads journal near GitHub's file limit

**Bennett-blnv (P1 wrong result, `src/softfloat_dispatch.jl` +67).** `_sfd_walk` did `continue` on
every builtin call inside Base methods; the differing-types refusal for `_apply_iterate` / `invoke`
fired only in user methods. `Base.splat(g)` and `g ∘ h` reach `g` through `Core._apply_iterate`
INSIDE Base, so `g(::Float64)` vs `g(::SoftFloat)` was never compared and both Float64 entry points
compiled the generic method. Now a callable-invoking builtin (`_SFD_CALLING_BUILTINS`) whose
argument types differ is replaced by the call it performs — a splat of fixed-length tuples through
`iterate`, or `invokelatest(g, args...)` — and checked as that call, or refused as unresolved
(`invoke`, world-age calls, `finalizer`, `applicable`, `modify*!`, splat of a Vector / Vararg tuple).
`Fix1`/`Fix2`/`map` were already caught: they reach `g` by an ordinary call. Landing-log counts:
blnv 93/93, czox 66/66, iffz 28/28, 19jw 32/32, gate baselines 39/39.
- Julia 1.12: `Base.invokelatest === Core.invokelatest` is a builtin; `code_typed` on it returns a
  `Method`, not a `CodeInfo`.
- Splatting into `tuple` (very common) is not refused: `Core.tuple` is a builtin that calls nothing,
  so the resolved call is skipped as before (read off the diff, not separately tested).
- Left open, recorded on Bennett-hgya (worker's findings, not re-verified): `hasmethod` / a
  user-level `applicable` answer differently on Float64 and SoftFloat; the non-concrete call-site
  check is gated by `user &&`, so a type-unstable Base forwarder can reach a user method unseen.
  The builtin list is by name — a callable-invoking builtin not on it is still skipped.

**Bennett-vke7 (`src/softfloat/fatan2.jl`).** A 200k sweep by the worker put every mismatch in the
x<0 half-plane (~31 % of Q2 and Q3, none in Q0/Q1): the code computed `π − z` where Base computes
`π − (z − PI_LO)`. `soft_atan2` now follows Base's `atan(y, x)` step by step, including the k>60 /
k<−60 shortcuts, Base's override order and its NaN rule (x if NaN, else y, payload unchanged —
before, y won and the quiet bit was set). Landing logs: vke7 2175/2175, softfatan2 138/138, 7goc
circuit 32/32, gate baselines 39/39. atan2 circuit 5,081,598 → 5,145,016 gates (one more
`soft_fsub`); nothing pins it, BENCHMARKS.md has no atan2 row.

**The worker then reported a "remaining defect" that is in fact the documented contract.** A
residual 1-ULP miss is inherited from `soft_atan` (witness `atan(0.4280128875928157)`: Base …616,
soft …615 — reproduced by the orchestrator). The worker's cause: Base's `atan` polynomial uses
`@horner` → `muladd`, fused on this host; `soft_atan` does a separate multiply and add (this host
does fuse `muladd`; the causal step itself was not re-derived). It proposed two beads: fix
`soft_atan`, and audit every transcendental. Before filing, an orchestrator sweep at d659a54, 200k
random inputs per function, bit mismatches vs Base, every one exactly 1 ULP:

| function | mismatches | | function | mismatches |
|---|---|---|---|---|
| `soft_log10` | 34105 (17 %) | | `soft_sin` | 201 |
| `soft_log2` | 18538 (9.3 %) | | `soft_tan` | 7 |
| `soft_asin` | 2271 (1.1 %) | | `soft_cos`, `soft_log` | 2 each |
| `soft_exp2` | 1985 | | `soft_atan2` | 1 |
| `soft_exp` | 1969 (1 %) | | `soft_atan` | 0 in this sample |
| `soft_acos` | 724 | | `soft_exp_julia`, `soft_exp2_julia` | 0 |

- This is in-contract: `flog.jl:414` and `fexp.jl:7` state "the §13 transcendental contract —
  current target is ≤2 ULP", and the tests assert ≤2 ULP. Only the `*_julia` ports are bit-exact.
  So neither proposed bead was filed.
- CLAUDE.md rule 13 itself says "must be bit-exact" for every Float64 function, then "(or ≤1 ulp
  tol)" in the transcendental convention. Three statements, three numbers; that is how vke7 and armp
  became P1 "rule 13 violations" on 2026-10-03. Filed Bennett-v4iy with the table and a proposed
  wording (arithmetic / conversions / comparisons bit-exact; transcendentals ≤2 ULP unless a
  `*_julia` port exists). The rule text is the maintainer's to change.
- "Bit-exact vs Base" is host-dependent for anything Base builds on `@horner` / `evalpoly` /
  `muladd`: the `*_julia` ports (which use `soft_fma`) match Base only on FMA hosts.
- The `soft_atan` zero is a sampling artefact, not a clean bill: log-uniform magnitudes over forty
  e-folds put under 1 % of samples in the two intervals where the worker saw misses. A sweep's
  "0 mismatches" is only as good as its distribution — the witness is the evidence.
- The new vke7 test tolerates ≤20 misses in 20k, each of which must be explained by the inner
  `soft_atan` miss; that matches the contract, though the file is named `…_bit_exact`.

**Beads journal vs GitHub's 100 MiB file limit (Bennett-amah).** `noms/vvvv…` is 90.5 MB. Measured
35–55 KB per `bd` write (a `bd close` of five ids costs the same as five closes: one Dolt commit
per issue) — roughly 290 writes of headroom at the start of today. A Sonnet agent trialled the three
compaction commands on scratchpad copies (remote removed first); the orchestrator re-compared the
exports independently: 874 records (864 issues + 10 memories), none missing, added or differing in
any copy.
- `bd flatten --force`: 2212 Dolt commits → 1, noms 97.5 MB → 1.98 MB, 2.9 s, GC built in.
- `bd compact --force` (default `--days 30`): → 13.9 MB, 398 commits.
- `bd gc --skip-decay --force`: → 54.1 MB (Dolt GC only). **Never plain `bd gc`** — its dry run
  says it would delete 507 closed issues (decay, closed > 90 days).
- Not run on the real store: it rewrites tracker history, so it waits for the maintainer. The
  pre-flatten store stays recoverable from git history.
- Any `bd` command in a COPY of `.beads` still tries the automatic Dolt push to the real remote
  (the agent's first `bd where` did; it failed on auth as always). Remove the remote in a copy
  before the first command, and use `--sandbox`.
- An orchestrator commit that takes the landing lock can wait several minutes behind a worker's
  rebase-and-re-test. While it waits, run no `bd` writes: `git add` would snapshot a store that is
  being modified. And `exit 0` from a `flock … bash -c 'add && commit && push; git log'` chain says
  nothing about the commit — check `git log` and `origin/main`.

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
