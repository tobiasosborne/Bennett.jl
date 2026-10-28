# The council

A loop in which three models from three providers grade a document against
`docs/council/rubric.md`, the maintainer's editor (a Claude Code session)
revises the document on their blocking issues, and the loop repeats until
every member accepts, or three rounds have run. The loop shape is borrowed
from the `council` skill in t3dotgg/tstack ("gets review from three models
from different providers, and loops until they agree") and from the design
council in `../sublimite/docs/design/council.md`. The rubric and the
resumable runner are ours.

Scores are advisory. The maintainer decides.

## Members

| Member | Call | Notes |
|---|---|---|
| Codex `gpt-6-astra`, reasoning `xhigh` | `codex exec -m gpt-6-astra -c model_reasoning_effort=xhigh -s read-only --ephemeral --output-schema … -o …` | stdin must be closed (`< /dev/null`) or codex waits on it forever. Run from the repo so the read-only sandbox can read it. |
| Muse `muse-wonder-full-1.0`, reasoning `high` | `muse exec --model muse-wonder-full-1.0 --reasoning-effort high --output-schema … --prompt-file …` | Prints status lines before the JSON; the runner takes the last JSON object. |
| Claude Opus 5.5 | `claude -p --model opus --output-format json --json-schema … --allowedTools Read Grep Glob` with the prompt on stdin | Nested inside a Claude Code session, so the runner unsets `CLAUDECODE*` in the child's environment. The prompt goes on stdin because `--allowedTools` is variadic and swallows a trailing prompt argument. |

Each member may read the repository (read-only) to check the document's
claims; the document itself is embedded verbatim in the prompt so a member
that reads nothing still grades the right text.

## Resumability

Everything lives under `docs/council/<run>/round-<N>/` inside the
repository, never in a session-scoped temp directory, so a crashed Claude
session, a dropped network, or a provider capacity failure loses nothing:

- `prepare` snapshots the document (`doc.md` plus its SHA-256 in
  `state.json`), writes `prompt.md` and `schema.json`. Re-running `prepare`
  on a round that already has member output refuses unless `--force`.
- `run` launches every member that has no valid `out-<member>.json`, in
  parallel, each with a wall-clock timeout, retrying on failure with
  backoff (60 s, 180 s, 420 s) up to four attempts. Every attempt's stdout
  and stderr are kept (`raw-<member>-<attempt>.txt`). Output is validated
  against the schema before it counts; an invalid answer is a failed
  attempt. `state.json` is rewritten atomically after every state change,
  so `status` always tells the truth and `run` is safe to invoke again at
  any time.
- `aggregate` validates all outputs, writes `report.md` and
  `consensus.json` (`{"agree": bool, "verdicts": …, "blocking": …}`).
- `status` prints the state of every round of a run.

## Run

```sh
python3 tools/council.py selftest
python3 tools/council.py prepare --run northstar-2026-10-28 --round 1 --doc Bennett-NorthStar.md
python3 tools/council.py run     --run northstar-2026-10-28 --round 1 [--member codex …] [--dry-run]
python3 tools/council.py status  --run northstar-2026-10-28
python3 tools/council.py aggregate --run northstar-2026-10-28 --round 1
```

Between rounds the editor revises the document on the blocking issues (and
on suggestions it agrees with), records what changed and what was declined
in `docs/council/<run>/round-<N>/response.md`, and prepares the next round.
From round 2 on, the prompt includes the previous round's blocking issues
and the editor's response so members can confirm each is resolved.
