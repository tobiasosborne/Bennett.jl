# 085 — 2026-06-19 — beads cross-repo sync + Bennett-3cna closed (superseded)

**Type:** housekeeping (no compiler code touched). Synced the `bd` issue trackers
of **both** Bennett.jl and BennettVM.jl via git + `bd import`, and retired a stale
local-only WIP bead. Recorded here so a future agent knows *why* a 243-LOC file
disappeared and why `Bennett-3cna` is closed with no matching commit.

## What happened

**Bennett.jl.** Local `main` was 5 commits behind `origin/main`, with an
uncommitted source WIP sitting on top: `src/extract/julia_callgraph.jl` (243 LOC,
untracked) + a 5-line `include(...)` in `ir_extract.jl`, tracked by the in-progress
bead **`Bennett-3cna`** ("CW-D1a: Julia typed-callgraph walker"). That WIP was
**superseded** — the same CW-D1a deliverable shipped on origin as
`src/extract/callgraph.jl` (commit `0c2a7f8`, worklog/081, under cross-repo bead
`bennettvm-416r.11`), wired into `ir_extract.jl` lines 9–10. The local
`julia_callgraph.jl` was the older (2026-06-10) abandoned variant; `callgraph.jl`
(2026-06-14) won.

Resolution (user-approved): preserved the WIP (patch + file copy in `/tmp`),
fast-forwarded to `origin/main` (561 issues), reconciled the local dolt cache via
`bd import` (confirmed content-identical), then **force-closed `Bennett-3cna`**
(reason: superseded / done-by-other-means; its dep on open `Bennett-nd45` is moot)
and **deleted the redundant `julia_callgraph.jl`**. Net tracker delta: 561 → 562
(the one closed bead). Pushed beads-only with `SKIP_PUSH_TESTS=1`.

**BennettVM.jl.** Git already up to date with `origin/master`, but the **local dolt
cache had drifted *behind* the committed `issues.jsonl`** (215 vs 217). Content diff
showed the committed jsonl was strictly newer: it carried `bennettvm-2k1k` (open,
2026-06-15) and `bennettvm-416r.11` at `in_progress` (2026-06-14) that the local
dolt lacked. The stale working-tree export (a 215-line `bd export`) would have
**silently dropped `2k1k` + a memory record** if committed. Fix: restored the
canonical committed jsonl, `bd import`-ed it to catch the dolt up (→ 216 issues +
memory), discarded the lossy re-export, left the tree clean. Nothing to push.

## Gotchas (will recur on every sync)

1. **`bd export` writes to STDOUT by default** — it does *not* update
   `.beads/issues.jsonl` unless you pass `-o .beads/issues.jsonl`. A bare `bd export`
   looks like it worked (prints JSONL) but leaves the file stale.
2. **`bd import` auto-re-exports + stages `issues.jsonl`** in the running `bd`
   version's format. If the committed file is an *older* export format (e.g. BennettVM
   issue lines lack `"_type":"issue"`), import churns every line cosmetically. Verify
   with a **content-normalized diff** (`id`/`status`/`updated_at`), not a raw line
   diff, before deciding whether a change is real.
3. **`bd close` mutates the dolt working set but does NOT re-export the jsonl.** After
   a close you must `bd export -o .beads/issues.jsonl` to capture the new status, else
   the staged jsonl shows the pre-close state.
4. **The local dolt cache can silently fall behind the git-committed `issues.jsonl`.**
   Always reconcile direction with a content diff before committing a fresh
   `bd export` — a stale export can erase issues/memories that a teammate already
   committed (BennettVM's `2k1k` near-miss). Treat the git-committed jsonl as canonical;
   `bd import` it to catch the local dolt up.
