# Worklog chunk 122 — 2026-10-28 — reboot workstream handoff

Previous: chunk 121 (2026-10-27 blueprint; 2026-10-28 north-star council
to consensus, ISA spec rounds 1–4, repo bootstrap, process change).

## Session log — 2026-10-28 — ISA draft 0.6 from round 5; council round 6 launched

Orchestrator session (Fable). Round 5 aggregated at the previous pause:
codex 10 / muse 6 / opus 3 blockers, mean 3.12, no `verdict_core`
(members graded before the S0/S1 rubric landed). Draft 0.6 written by
surgical edits only (no rewrite); editor's response with the S0/S1
re-classification table in `docs/council/isa-2026-10-28/round-5/
response.md`. Decisions and gotchas worth keeping:

- **A+D inverse.** The real bug behind codex B1 / muse B1: §3.6 grouped
  "direct sub-ops, then assignment exchanges", so `lift.ret`'s stack
  addresses were evaluated under the caller's `fp`. 0.6 defines the
  inverse of an A+D row as the literal reverse of its elementary
  sub-operation list and prints C1–C5 / R1–R5 with both inverse lists.
  Three slot kinds (assignment / capture / delivery) because capture
  slots have no destination to exchange back into.
- **Result name is a location** (after params, before regs). That makes
  `R_sum = 16`, so example 2 at n = 16 needs 17·16 = 272 stack cells;
  `S_cells` went 8 → 9. The pre-flight now models the monotonic stack and
  tests the capacity boundary (16(n+1) cells succeed, one fewer faults).
- **Segment `uncall`.** Took the pure-suffix rule (legal only if every
  frame after the segment is pure) and *dropped* redo/re-execution:
  with a pure suffix the state at the `uncall` frame already equals the
  pre-segment state on everything but instances, so whole-run reversal
  simply skips reversed segments and `uncall` frames. Instances defined
  inside the segment cease to exist after `uncall` (use → trap).
- **MBU deferred** (not admitted in 0.6; unitary cleanup only; §17 item
  6 default). The fixup after X-measurement is (−1)^{m·g(x)}, a property
  of g's computing sequence, not of the target, so `mbu_schemes` in the
  target format was the wrong home anyway.
- **Expansion library** instead of carrying the realised gate graph in
  every schedule: `bindings.expansion = {name, version, hash}`; the
  reference library `ref` is the default (§17 item 7). Both codex and
  muse listed this as the acceptable alternative.
- **Globals are data symbols of the same name** (`image` = the global's
  name). This resolves the `@zero` ambiguity (global or symbol?) that the
  envelope rule depended on silently.
- **Diamond-norm SDP printed** (Watrous 2009 §4, Hermiticity-preserving
  form, Y₀ = Y₁ = Y): accept iff Y ∓ J(Φ) ⪰ 0, μI − Tr_out Y ⪰ 0, μ ≤
  bound; ‖Φ‖◇ ≤ μ with no factor 2. Opus's variant (Y ⪰ 0, Y ⪰ J, 2μ)
  is also valid for TP differences but looser; codex's form was taken.
- **Checker gotcha.** A printed envelope for a self-referential
  one-member SCC (`@sum`) hashes to `scc_hash`, and the symbol's hash
  is SHA-256("<scc_hash>:0"); the check accepts either. `isa_check.py`
  gained `--repatch` (rewrites every printed hash to the computed one,
  needed whenever the version string or a closure leaf changes) and
  `--print-envelope NAME`.
- New §17 "Decisions deferred to implementation, with defaults" (14
  items) replaces the bare list; S1 items close by stating a default.
- bd: the sonnet agent's repair (below) left one step: `bd dolt push
  --force`, blocked for the agent harness as a destructive git action;
  the maintainer runs it.

## Session log — 2026-10-28 — bd repair (sonnet agent)

Ran: `chmod 700 .beads`; `git config beads.role maintainer`; raw `cp -a .beads` safety copy to scratchpad (pre-migration `bd export` FAILS on v32: "table not found: leases"); `bd migrate --force` (v32->v66, ok); `bd export --all -o .beads/pre-flatten-backup.jsonl` (888 issues + 10 memories = 898 lines; `bd stats` total 888); `bd flatten --force` (2323 commits -> 1; store 246.8 MB -> 58.3 MB; stats total still 888).
Sizes: noms/vvvv... journal 93.7 MB -> gone; largest now `.beads/backup/*.darc` 56.9 MB (gitignored) + two git-remote-cache packs 24.2/15.5 MB (tracked). `.beads` 159M -> 121M.
Gotchas: (1) `bd export` only works after migration. (2) After flatten, `bd dolt push` first failed "not a git repository" because git-remote-cache/*/repo.git lost its empty `refs/{heads,tags}` dirs; recreated with mkdir. (3) Push then rejected non-fast-forward (flattened history diverges from remote refs/dolt/data); a force push is required and was NOT done by the agent (needs maintainer OK). Tracked `.beads/issues.jsonl` (898 lines, 2026-10-04) is stale vs the DB. (4) `.beads.gate.lock` is bd-created, covered by ignore; `tools/__pycache__/` added to .gitignore. Open count shifted 221->227 post-migration (status reclassification; total unchanged).

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
