# Worklog chunk 110 — 2026-10-03 — wide campaign over the Astra queue (4 concurrent workers)

## Session log — 2026-10-03 — batch 1 landed: Bennett-u91f (6665a60), Bennett-g6u9 (5b0ab97), Bennett-3wk7 (0cce5d9), Bennett-9k7n (9b04a87)

**Bennett-u91f — controlled() simulate misdecoded unsigned outputs** (6665a60). `_simulate_ctrl`
passed `(Int(ctrl), x...)` to `_simulate`; the zc50 signedness heuristic (all inputs Unsigned and
all widths equal) saw the signed 1-bit ctrl and always decoded signed, so
`simulate(controlled(identity-UInt8), true, 0xff) == -1`. Fix: heuristic factored into
`_infer_unsigned_out` (src/simulator.jl), `_simulate` / `_simulate_with_buffer!` take an
`unsigned_out` keyword, and src/controlled.jl runs it on the payload widths only. New
test_u91f_controlled_signedness.jl: 2613 pass; related controlled/zc50 files green. Two
test_controlled.jl cases (soft_fneg, soft_fmul-then-fneg) relied on the bug via
`reinterpret(UInt64, Int64(raw))` and now compare `raw === soft_fneg(x_bits)`. Gate counts
unchanged. Bead closed with one related case NOT fixed: typed `simulate(c8, UInt16, 0xffff)` on
`x%UInt8` returns 0xffff instead of 0x00ff (width-mismatched, needs output signedness stored on
the circuit); carved out into Bennett-13xy (P1).

**Bennett-g6u9 — mixed SoftFloat `==` miscompiled** (5b0ab97). `SoftFloat` is not a `Number` and
only SoftFloat==SoftFloat existed, so `SoftFloat(0.0) == 0.0` hit Base's `===` fallback, returned
false during tracing, and `x == 0.0 ? x + 1.0 : x` compiled to a 66-gate identity circuit that
still passed `verify_reversibility`. Fix (src/softfloat_dispatch.jl only): mixed `==` in both
orders; Float64 via `soft_fcmp_oeq`; Integer exact like Base (compare with `Float64(b)` and
require `Float64(b) == b`); other Reals throw an ArgumentError naming the bead. New
test_g6u9_softfloat_mixed_eq.jl: 2531 pass (host parity, plus seven compiled circuits bit-exact
on 50 inputs). Targeted run 9157/9157. Gate counts unchanged.

**Bennett-3wk7 — f32/f16 int<->float casts fell into a silent IRCast** (0cce5d9).
`_convert_instruction` (src/extract/instructions.jl) routed only `double` through the soft
casts; f32/f16 fell into a width-only `IRCast` reinterpreting float bits as an integer
(`unsafe_trunc(Int32, 1.5f0)` gave 1069547520). Reproduced from plain Julia; the bead's "raw .ll
only" text was wrong (Float32 intermediates reach it). Both fallbacks now call
`_int_fp_cast_error`, which raises a loud `_ir_error` naming Bennett-3wk7 / Bennett-3rph.
New test_3wk7_f32_cast_reject.jl: red 24 fail / 514 pass, green 538/538; f64 casts stay
bit-exact over all 256 inputs. Gate counts unchanged. Float32 fptosi via exact fpext left out of
scope (rejection matches the bead). Bennett-s6d6 confirmed still broken; not touched here.

**Bennett-9k7n — lower_call! callee wire remap vs free-list reuse** (9b04a87). `lower_call!`
(src/lowering/call.jl, compact and non-compact) took `wire_offset = wire_count(wa)`, discarded
`allocate!`'s returned vector and mapped callee wire k to `wire_offset + k`. `allocate!` serves
the free list first and QROM frees its scratch wires, so a table lookup followed by a call put
callee gates on unreserved wires (compact: wrong output with `verify_reversibility` true;
non-compact: dirty ancillae). Fix: `wmap = allocate!(wa, n)` and every callee wire, gate and
loop-guard maps through `wmap[k]`; `_remap_gate_offset` became `_remap_gate(g, wmap)`. With an
empty free list `wmap` is the old contiguous range, so gate counts are unchanged. New
test_9k7n_call_wire_remap_freelist.jl: 48/48 ParsedIR + 8/8 Julia witness; both red before the
fix. Targeted runs 4257/4257 and, after rebase, 586/586 including gate_count_regression.

**Gotchas.**
- 3wk7: `_type_width` maps float/half to 32/16, so only `src_w == 64` distinguished double; test
  `LLVM.value_type(...) isa LLVM.LLVMDouble`, not the width.
- g6u9: the 66-gate identity is the miscompile signature. An ArgumentError thrown while tracing
  surfaces as "VoidType reached _type_width (Bennett-dq8l / U81)", not the original message.
- g6u9: `isequal(SoftFloat, x)` falls back to `==`; NaN and +-0 disagree with Float64.
- 9k7n: the bug needs a constant table of >= 32 entries (size 16 passed before the fix); it shows
  with optimize=true in plain Julia, passes with optimize=false.
- 9k7n: a failing first top-level `@testset` aborts the file; run a testset alone to confirm red.
  `simulate` throws on dirty ancillae, so mismatch counters need `try`.
- u91f: any outside code using the `reinterpret(UInt64, Int64(raw))` workaround on controlled
  circuits now throws InexactError for results >= 2^63.

**Filed:** Bennett-13xy (P1) ReversibleCircuit output signedness (UInt16->UInt8 witness);
Bennett-ero9 (P2) SoftFloat isequal/hash; Bennett-l3a0 (P2) GateGroup wire ranges assume
contiguous allocation (includes the aggregate.jl:159-166 comment recheck); Bennett-ddap (P3) typed
simulate for ControlledCircuit; Bennett-ju3o (P3) f32 fptosi/fptoui via fpext; Bennett-n47e (P3)
int width > 64 guard on raw .ll casts.   **Annotated:** Bennett-8aes — tracing-time throws surface
as the VoidType wall.

## Session log — 2026-10-03 — campaign setup: four worktree slots, serialised landing, batched review

**Mode (maintainer, 2026-10-03).** Wide instead of serial: four coding subagents (Opus) work
concurrently, one bead each, land it, stop. Review (`codex exec -m gpt-6.1-sol`, effort high) is
launched by the orchestrator only after several items have landed, over the accumulated diff —
CLAUDE.md rule 2 reworded to say so. Sonnet subagents for triage and quick fixes. No Astra or
Fable subagents (quota). ONE full-suite run for the whole session, mid/late campaign; workers
run targeted files only. Work stays under quota pace (the `quota` skill, polled at checkpoints).

**Queue.** A Sonnet triage of the 196 open beads (98 P1/P2) classified them by the four verdict
classes of worklog/109 and by area, with likely files and size. Class-1 (recogniser) beads are
held back pending the V2-PRD D0 decision. Waves of four are chosen so the four beads touch
different files. Known same-file clusters that must run serially: `extract/callees.jl`
(4ddk, p9a0, wh1p); `softfloat_dispatch.jl` (g6u9, lgwa, 8aes, 19jw); the eager strategy files
(3vji, htu2, ui55, exb3, o23d); `diagnostics.jl` (u3b2, kk3y; 1f92 depends on u3b2); `cfg.jl`
(73gr, n9o8, next to the parked i5zn branch); `call.jl` (9k7n, 0a6f).

**Setup facts worth keeping (worktrees + Julia precompile):**
- `Manifest.toml` is gitignored, so a fresh `git worktree` has none and `julia --project` cannot
  load the deps. Copy the main tree's `Manifest.toml` into each worktree.
- Dependency caches are shared across worktrees (same manifest → same versions; Julia accepts a
  cache written under another active project). Bennett's own cache is per source path, so each
  worktree precompiles Bennett once per source change: **~51 s wall, ~2.9 GB RSS** on this box
  (64 cores, 62 GB). Four in parallel is fine here.
- Julia keeps at most 10 cache files per package name; each (worktree path × flag set) is one
  file. Four slots + main + default-vs-`--check-bounds=yes` would thrash, so the workers use ONE
  flag set (suite mode, `--check-bounds=yes`) through a wrapper that also sets
  `JULIA_MAX_NUM_PRECOMPILE_FILES=64`, `JULIA_PKG_OFFLINE=true` and a `timeout`. Fixed slot paths
  are reused across beads (`git checkout -B work/<bead> main`), so the cache count stays bounded.
- Slots were pre-warmed serially for the first one (it also proves the deps are cached under the
  flag set), then the other three in parallel, before any worker started.
- Workers never run `bd` (each worktree has its own copy of the tracked dolt store; `bd show`
  churns it), never run `Pkg` operations, and never touch `.beads/`, `worklog/`, `WORKLOG.md`,
  `CLAUDE.md`, `Manifest.toml`. Bead text is dumped once to files by the orchestrator.
- Landing is serialised by a `flock` script: refuse if the branch touches orchestrator-owned
  files → if `main` moved, rebase and hand back for a targeted re-test → otherwise
  `merge --ff-only` into the main tree and push. The orchestrator closes beads and writes the
  worklog in batches (single writer for `.beads/` and `worklog/`).
- New test files are registered with a `runfile(...)` line next to a related file, not at the
  end of `test/runtests.jl`, to keep four concurrent branches from colliding on one hunk.
- Codex's configured default model is `gpt-6-astra`; the reviewer must always be named
  explicitly (`-m gpt-6.1-sol -c model_reasoning_effort=high`).
