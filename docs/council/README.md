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
python3 tools/council.py prepare --run isa-2026-10-28 --round N --doc Bennett-ISA-Spec.md \
        --rubric docs/council/rubric-isa.md --context Bennett-NorthStar.md \
        --subject "..." --precheck "python3 tools/isa_check.py"
python3 tools/isa_check.py        # the pre-flight on its own
python3 tools/council.py run     --run northstar-2026-10-28 --round 1 [--member codex …] [--dry-run]
python3 tools/council.py status  --run northstar-2026-10-28
python3 tools/council.py aggregate --run northstar-2026-10-28 --round 1
```

## Convergence process (adopted 2026-10-28 after ISA rounds 1–4)

The north star converged in six rounds; the ISA spec oscillated (2.12 →
2.83 → 3.04 → 2.83) because each round was a full rewrite that introduced
new mechanical errors, and because members were grading field-level
completeness of contracts as blockers. The process is now:

1. **Surgical edits between rounds, never rewrites.** Accepted text does
   not move. The editor applies each blocker's fix in place and records
   it in `round-<N>/response.md`.
2. **Pre-flight before every round.** `prepare --precheck` runs
   `tools/isa_check.py`: the spec's example objects must parse per the
   grammar, their hashes must reproduce from the spec's own envelope rule,
   their layouts must be disjoint, and their stated results must hold on
   a reference interpreter. A round is not prepared if the check fails.
   Add every new example or claim to the check before grading it.
3. **Diff attached.** `prepare` attaches the unified diff from the previous
   snapshot; members confirm fixes there first, then hunt new S0 issues.
4. **S0 only blocks.** The rubric defines blocking as "two conformant
   implementations would differ, or unsound, or contradictory, or a
   missing normative decision". S1 (implementer must choose, any choice
   conformant; enumeration gaps with a stated default) goes to
   suggestions. The spec carries a deferred-decisions section with
   defaults so S1 items can be closed by stating a default.
5. **Staged acceptance.** Every blocker is tagged `core` or `contract`;
   members give `verdict_core` and `verdict`. Core consensus first.
6. **Status accounting.** Members fill `previous_status` for every prior
   blocker and list `regressions`; the report shows them, so a regression
   is visible as such and never mistaken for new depth.
7. **Formal correctness after practical revisions.** Statements with
   hypotheses are required; proofs, mechanisation and witness formats
   are S1 until implementation has forced the revisions it will force.
8. **Executable spec as the tie-breaker.** When a round still disputes a
   core rule, the rule is implemented in `bennett-isa-spec`'s reference
   interpreter and the example extended, rather than re-worded.

Between rounds the editor revises the document on the blocking issues
(and on suggestions it agrees with), records what changed and what was
declined in `docs/council/<run>/round-<N>/response.md`, and prepares the
next round with `--precheck "python3 tools/isa_check.py"`.
