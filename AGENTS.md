# Agent Instructions

**CLAUDE.md at the repo root is the single source of truth for this
project.** Read it in full before doing anything else — it is not
Claude-specific despite the filename; it applies to every agent working
in this repository. This file is a short pointer, not a substitute:
if anything here ever conflicts with CLAUDE.md, CLAUDE.md wins.

The handful of rules below are restated here only because getting them
wrong is destructive or hard to undo. Full rationale for each is in
CLAUDE.md.

- **Worklog**: every session, prepend a `## Session log — YYYY-MM-DD`
  block to the file with the **highest** `NNN_` prefix under
  `worklog/` (check with `ls worklog/ | sort -r | head -1` — do not
  hardcode a number, it changes every session). `WORKLOG.md` at the
  root is just a thin index into `worklog/`.
- **NEVER run `python3 scripts/shard_worklog.py`.** It is destructive:
  it wipes all existing worklog chunk files. Edit chunks by hand.
- **No GitHub CI, no remote build automation.** Quality gates run
  locally only (`Pkg.test()`, the pre-push git hook, `bd`). Do not
  create `.github/workflows/`, propose CI, or reference external
  build/test services.
- **Issue tracking is `bd` (beads) only** — do not use TodoWrite,
  markdown TODO lists, or MEMORY.md files. Run `bd prime` for the full
  workflow (ready/show/claim/close) and session-close protocol.
- **Fail fast, fail loud**; **red-green TDD**; **exhaustive
  reversibility verification** — see CLAUDE.md §§1, 3, 4 for the full
  non-negotiable list (14 rules total).

For everything else — pipeline architecture, file structure, build/test
commands, core-change review requirements (3+1 agents), gate-count
regression baselines — read CLAUDE.md.
