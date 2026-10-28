# Worklog chunk 122 — 2026-10-28 — reboot workstream handoff

Previous: chunk 121 (2026-10-27 blueprint; 2026-10-28 north-star council
to consensus, ISA spec rounds 1–4, repo bootstrap, process change).

## Session log — 2026-10-28 — HANDOFF: state of the reboot at session pause

**Read this first.** The maintainer paused the session here. Everything
below is on disk and pushed; nothing is in flight that needs this
session except ISA council round 5, whose outputs land on disk by
themselves (see "Immediate next step").

### What the project is now

Bennett.jl v1 (this repo's `src/`, `test/`) and BennettVM.jl are
**deprecated as designs**. The reboot is specified by two documents at
this repo's root, iterated with a three-model council:

- `Bennett-NorthStar.md` (iteration 7): the vision. **Council consensus
  reached** (round 6: codex/muse/opus all accept, mean 4.46). Treat as
  settled; change only with a reason that would survive the council.
- `Bennett-ISA-Spec.md` (draft 0.5): the virtual ISA, the one semantics
  both executors implement. **Not accepted**; four no-go rounds (means
  2.12 → 2.83 → 3.04 → 2.83), round 5 running on 0.5. Goal per
  maintainer: "an accepted spec that is likely correct; implementation
  will expose frictions"; and "formal correctness is best pursued after
  practical considerations have forced several revisions".

Thirteen public repos exist under **https://github.com/bennett-quantum**
(org created by the maintainer 2026-10-28; local clones under
`~/Projects/bennett-workspace/`): `bennett` (meta: manifest, clone and
remote scripts), `bennett-dialect-spec`, `bennett-isa-spec`,
`bennett-sched`, `bennett-plugin`, `bennett-driver`, `bennett-vm`,
`bennett-circuits`, `bennett-estimate`, `bennett-targets`,
`bennett-runtimes`, `bennett-arith`, `bennett-conformance`. Each is a
skeleton: LICENSE (AGPL-3.0), CLAUDE.md with the non-negotiables,
SPEC_VERSIONS.toml, pre-push hook (installed), worklog/001, HANDOFF.md,
Rust crates with one passing test where applicable. `Bennett.jl` v2 (the
Julia quantum language; Sturm.jl is sunset) stays in THIS repo as a
future major; v1 goes to a `v1` branch / `v1-final` tag when that starts.
No beads (`bd init`) in the new repos yet.

### The council: how to run a round

Tooling: `tools/council.py` (resumable; state in-repo under
`docs/council/<run>/round-N/`), `tools/isa_check.py` (pre-flight),
rubrics `docs/council/rubric.md` (vision) and `rubric-isa.md` (spec),
process in `docs/council/README.md`. Members: codex `gpt-6-astra` xhigh
(10–30 min per round, worked every time), muse `muse-wonder-full-1.0`,
Claude Opus 5.5 via nested `claude -p` (prompt on stdin, `CLAUDECODE*`
unset). Gotchas: codex blocks forever unless stdin is the prompt or
closed; `--allowedTools` is variadic and swallows a trailing prompt arg.

The ISA process as of this session (encoded in the tooling, not optional):

1. **Surgical edits only** between rounds; never a rewrite (every
   rewrite this session introduced new mechanical errors: `r ^= r`,
   an incomplete inverse step, an unsound borrow lemma, a tautological
   hash table).
2. **Pre-flight**: `python3 tools/isa_check.py` must pass before a round
   is prepared; `prepare --precheck "python3 tools/isa_check.py"`
   enforces it. The check parses the spec's two example objects per §16,
   recomputes their hashes by §9.2 (Tarjan SCC; header names are
   definitions, not references), asserts the printed envelope bytes hash
   to the `inc8` hash, checks layout disjointness, and executes both
   examples on a reference interpreter (lifted subset: const, add, sub,
   icmp, zext, mov, addr, boundscheck, load, call, ret, retval, qjump,
   qbranch) against their stated results. **Add every new example or
   stated result to this check before grading it.** If you change the
   envelope rule in §9.2, change `compute_hashes` to match and let the
   check re-patch the printed hashes (see chunk 121 for the snippet).
3. **S0-only blocking**: two conformant implementations would differ /
   unsound / contradictory / missing normative decision. S1 (any choice
   conformant; enumeration gaps with a stated default; proof formats,
   mechanisation, numerical witness schemas) are suggestions. Blockers
   carry `scope` (core|contract) and `severity`; members return
   `verdict_core` and `previous_status` per prior blocker and
   `regressions`. **Core consensus first** (every `verdict_core` =
   accept, no core blocker), contracts after.
4. The diff from the previous snapshot is attached to the prompt
   automatically.

Commands:

```
python3 tools/council.py aggregate --run isa-2026-10-28 --round 5     # when round 5 is done
python3 tools/council.py status    --run isa-2026-10-28
# revise Bennett-ISA-Spec.md surgically; write docs/council/isa-2026-10-28/round-5/response.md
python3 tools/isa_check.py
python3 tools/council.py prepare --run isa-2026-10-28 --round 6 --doc Bennett-ISA-Spec.md \
   --rubric docs/council/rubric-isa.md --context Bennett-NorthStar.md \
   --subject "the sixth normative draft (0.6) of the Bennett virtual ISA specification (the bennett-isa-spec contract named in the north-star document supplied as background)" \
   --precheck "python3 tools/isa_check.py"
python3 tools/council.py run --run isa-2026-10-28 --round 6 --timeout 3600 --attempts 6
```

### Immediate next step

ISA **round 5** was launched at 12:34 UTC on snapshot sha256 3e27f482…
(draft 0.5 before the small post-launch fixes: header-name rule in §9.2
and the hash table keyed by symbol name; those do not change semantics).
At pause: muse and opus done, codex running. The run's `state.json` and
`out-*.json` land under `docs/council/isa-2026-10-28/round-5/` whether
or not a Claude session is attached. Next agent: run `aggregate` for
round 5 (if codex never finished, `run --run isa-2026-10-28 --round 5
--member codex` resumes just that member), read `report.md`, then
proceed per the process above. Expect blockers in: the step-machine
inverse wording (§3.6), the `lift.call`/`lift.ret` sub-operation order
(§3.7), the translation lemma (§5.6), provenance transfer rules (§6.1),
the envelope rule (§9.2), schedule specificity (§11), certificate claim
formats (§12; now S1 by policy). Round 5 members were NOT yet told the
S0/S1 policy (it was added after launch), so re-classify their blockers
yourself: contract-enumeration items with a stated default are S1.

Draft 0.6 should also add a **"Decisions deferred to implementation,
with defaults"** section (replacing the bare deferred list in §17): each
S1 item gets a default implementers follow until revised. That is how S1
items are closed under the new rubric.

**Round 5 result (aggregated at pause):** codex: revise, 10 blockers; muse: revise, 6 blockers; opus: revise, 3 blockers. Report: `docs/council/isa-2026-10-28/round-5/report.md`. Start from its blocking list, re-classified by the S0/S1 rule.

### Other open items, in priority order

1. Chunk 120's pending maintainer decisions remain pending: **amah**
   (beads dolt journal at 93.7 MB vs GitHub's 100 MiB limit: `bd export`
   then `bd flatten --force`) and **v4iy** (ULP wording). Untouched.
2. When the ISA spec reaches core consensus: move `Bennett-ISA-Spec.md`,
   `Bennett-NorthStar.md`, `tools/council.py`, `tools/isa_check.py` and
   `docs/council/` into the `bennett` meta repo and `bennett-isa-spec`
   (its `spec/README.md` says so); `tools/isa_check.py`'s interpreter
   and hasher are the seed of `bennett-isa-spec/reference-interpreter`.
3. `bd init` in the new repos; the north star's §9 ordering (legality
   spike first) applies to the dialect spec, which has no draft yet.
4. The landscape table in the north star (§7): codex asked for a
   sourced feature comparison instead of categorical negatives; S1.
5. BennettVM.jl: archive read-only once the maintainer says so.

### Facts worth not re-deriving

- `bennett-lang` on GitHub is an empty 2026-08-19 account that is NOT
  the maintainer's (no verification mail, no local gh login, no
  transcripts); ignore it.
- GitHub orgs are web-only; `gh repo create <org>/<repo>` works with
  `repo` scope once the org exists.
- A permutation circuit's unitary is determined by its basis action:
  basis-state differential testing plus clean ancillae is *complete* for
  the exact-permutation tier (north star §5.1 part 1, ISA T3). Phase-
  sensitive checks matter only once ε > 0 realisations or measurement-
  based cleanup enter.
- The determinism contract for "equals native" took three rounds to
  close: `freeze` is not deterministic; poison/undef removal is not
  enough (NaN bits, fmuladd, addresses); the answer is deterministic
  soft-float in BOTH builds plus a driver-controlled layout. Do not
  reopen it without a new counterexample.
- Council timing per round: muse 2–9 min, opus 2–6 min, codex 8–31 min;
  zero retries across 11 rounds today. Quota was not a problem.

### Not done this session

No tests of v1 were run (docs/tooling only; `src/` and `test/` untouched).
`tools/isa_check.py` covers only the lifted subset the examples use. The
C header in §10 is untested against a compiler. The `bennett-plugin`
CMake configure has never run (no cmake on this box).
