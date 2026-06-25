# Worklog chunk 090

## Session log — 2026-06-25 — Cross-repo beads sync (Bennett.jl + BennettVM.jl) + orientation

Operational session: bring beads into sync via git and reconcile the local
dolt DBs via `bd import` in **both** repos. No source/compiler changes. Also
re-familiarised with both projects (BennettVM orientation via a read-only
Explore subagent — Phase 2 production, CW-D closed-world Julia producer the
active front, epic `bennettvm-416r.11`).

### The two repos use DIFFERENT beads-over-git sync models — this matters

- **Bennett.jl — embedded-dolt-IN-git.** `.beads/embeddeddolt/` IS git-tracked
  (the `dolt` remote is `git+https://github.com/tobiasosborne/Bennett.jl.git` —
  `bd dolt push/pull` rides the git remote via `git-remote-cache/`). So the
  authoritative dolt store travels in git commits; `issues.jsonl` is a
  secondary export.
- **BennettVM.jl — jsonl-ONLY.** `.beads/embeddeddolt/` is NOT tracked
  (0 files in `git ls-files`). Bead state crosses machines purely through the
  git-tracked `.beads/issues.jsonl`. The local dolt DB is per-machine, so
  `bd import .beads/issues.jsonl` is the ONLY way it picks up a peer's changes.

Implication: in BennettVM, `git pull` alone leaves the local dolt DB stale —
the `bd import` step is load-bearing, not cosmetic.

### Bennett.jl — what was found and done

- Was **10 commits behind** origin/main (the 2026-06-23 CW-D cluster:
  3ptu/iwo9/r92o/beaw/vbv9/6bu3/...), 0 ahead. 8 untracked `git-remote-cache`
  objects were **byte-identical** to objects already in origin/main
  (content-addressed) — removed them to unblock a clean fast-forward; the pull
  restored them as tracked.
- **GOTCHA — origin's own `issues.jsonl` was stale.** The dolt store advanced
  to **575** issues across those commits but `issues.jsonl` was never
  re-exported, leaving it pinned at **568**. A fresh clone doing `bd import`
  would have loaded a stale snapshot (missing 7 beads: amah/beaw/eln6/pljv/
  r92o/sxse/vbv9; and 5 state changes: 37ib/3ptu/6bu3/iwo9 closed, 8bys
  updated). Regenerated the export and committed it (`08a5c0e`, jsonl-only).
- **GOTCHA — `repo_state.json` carries a machine-specific path.** `bd import`
  dirtied the dolt working set, incl. flipping the `backup_export` URL from
  `/home/tobiasosborne/...` (origin's machine) to `/home/tobias/...` (this
  machine). That ping-pongs between the user's two machines — **reverted** the
  embeddeddolt churn; committed ONLY `issues.jsonl`. (The dolt store already
  had all 575 pre-import, so reverting lost nothing.)
- Pushed with `SKIP_PUSH_TESTS=1` (the pre-push hook's own sanctioned escape
  hatch for docs/beads-only pushes — no source changed, so `Pkg.test()` is
  unaffected). Final: 0/0, clean.

### BennettVM.jl — what was found and done

- Was **2 commits behind** origin/master (140766e 6bu3 consumer + 3760f8b
  CW-D3 Lever 3), 0 ahead. Had a **staged 217-line `issues.jsonl` rewrite**
  that turned out to be a **stale, lossy older export**: semantically it
  differed from origin by exactly one bead (`416r.12` open/2026-06-10 vs
  origin in_progress/2026-06-23) and it had **dropped the lone memory record**
  (`case-b-closed-world-settled`). Discarded it (no unique local state), then
  fast-forwarded.
- `bd import` then upserted origin's jsonl into the local dolt DB:
  416r.12 → in_progress/2026-06-23, memory re-imported. ("216 issues + 1
  memory".)
- **GOTCHA — bd's auto-export drops memories.** After import, bd auto-re-staged
  `issues.jsonl`, and that re-export (a) was 0-semantic-diff vs origin for all
  216 issues but 435 lines of pure reordering churn, AND (b) **dropped the
  memory line** (default `bd export` excludes memories unless
  `--include-memories`). Committing it would delete the memory from the
  git-tracked export and ping-pong serialization with the other machine —
  **reverted** it, keeping origin's canonical jsonl (memory intact). Net:
  nothing to commit (BennettVM was purely behind); final 0/0.

### Reusable lessons

1. After any `bd import`, **diff semantically (id,status,updated_at) before
   committing the re-export** — bd's default auto-export reorders every line
   and silently drops memory records. A 400-line diff is usually 0-semantic
   churn + a lost memory, not real work. Revert it unless the semantic diff is
   non-empty.
2. `repo_state.json`'s `backup_export` URL is a per-machine absolute path
   (`/home/<user>/...`); never commit its flip. It's effectively local-only
   even though it's tracked.
3. Bennett.jl's `issues.jsonl` can lag its dolt store (the dolt store is the
   git-tracked source of truth there). If you want the portable jsonl current,
   `bd import` then commit the jsonl deliberately.
