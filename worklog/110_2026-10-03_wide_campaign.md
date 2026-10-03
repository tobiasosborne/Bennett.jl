# Worklog chunk 110 — 2026-10-03 — wide campaign over the Astra queue (4 concurrent workers)

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
