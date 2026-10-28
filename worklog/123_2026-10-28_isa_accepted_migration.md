# Worklog chunk 123 — 2026-10-28 — ISA accepted; documents migrated to the bennett-quantum repos

Previous: chunk 122 (2026-10-28 handoff; bd repair; ISA rounds 5–8 to
consensus).

## Session log — 2026-10-28 — north star, ISA spec, council tooling and records moved out of Bennett.jl

**Where things are now** (handoff item 2 of chunk 122, executed):

| Was (Bennett.jl) | Now |
|---|---|
| `Bennett-ISA-Spec.md` (0.8, accepted) | `bennett-isa-spec/spec/Bennett-ISA-Spec.md` @ ec1a443 |
| `tools/isa_check.py` | `bennett-isa-spec/reference-interpreter/isa_check.py` (SPEC path → `../spec/`) |
| `Bennett-NorthStar.md` (it. 7, consensus) | `bennett/docs/Bennett-NorthStar.md` @ 0b23100 |
| `tools/council.py`, `docs/council/**` (both runs, all rounds, responses, rubrics, README) | `bennett/tools/council.py`, `bennett/docs/council/**` |

Both destination repos are pushed to github.com/bennett-quantum. Pointer
stubs with the same filenames remain here so links in old worklog
entries resolve; the last in-repo text is `git show 40e5f273:<file>`.
`bennett-isa-spec/SPEC_VERSIONS.toml` 0.3 → 0.8; its `spec/README.md`
carries the change rules (surgical edits; bump the version string on any
semantic change and `--repatch` the hashes; examples into the checker
before grading; §17 defaults first; revisions through the council).

**Running the council from the meta repo**: `cd bennett && python3
tools/council.py prepare --run <run> --round N --doc
../bennett-isa-spec/spec/Bennett-ISA-Spec.md --rubric
docs/council/rubric-isa.md --context docs/Bennett-NorthStar.md
--precheck "python3 ../bennett-isa-spec/reference-interpreter/isa_check.py"`
— the runner resolves `docs/council/` relative to its own repo and runs
members with cwd = that repo, so codex's read-only sandbox sees the
records but must be given the spec path explicitly (it is embedded in
the prompt verbatim anyway).

**Next session starts in `~/Projects/bennett-workspace/bennett/HANDOFF.md`** (state table for all 13 repos, council how-to, open items in order). This repo is the v1 reference and differential oracle only.

**Beads**: `Bennett-amah` (dolt journal bloat) closed — flatten done, force push pending with the maintainer. The post-flatten noms journal restarts small and is tracked again.

**Not done / open**: `bd init` in the new repos (chunk 122 item 3; bd
itself was only just repaired here); the dialect spec has no draft
(north star §9 item 1: legality spike first); BennettVM.jl archive
(awaiting the maintainer); `bd dolt push --force` for the flattened
beads history (maintainer; blocked for agents as a destructive git op);
chunk 120's **v4iy** (ULP wording) still pending. The council members'
round-8 S1 suggestions are in `bennett/docs/council/isa-2026-10-28/
round-8/out-*.json` and should become bennett-isa-spec's first issues.
