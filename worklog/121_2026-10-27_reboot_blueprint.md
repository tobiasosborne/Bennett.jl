# Worklog chunk 121 — 2026-10-27 — reboot blueprint discussion

Previous: chunk 120 (2026-10-04 wide campaign close; 32 beads closed;
handoff with maintainer decisions pending — amah journal flatten,
v4iy ULP wording — both STILL PENDING, untouched this session).

## Session log — 2026-10-27 — familiarisation + code assessment + reboot blueprint (docs only, NO src/test change)

**What happened.** A fresh agent session (Muse Code) read both repos end
to end (CLAUDE.md both sides, README/HANDOFF/PHASE/pin on the VM side,
main source files, all nine Astra triage files, Bennett-V2-PRD), gave
the maintainer a code assessment, and then — at the maintainer's
request — drafted a from-scratch reimagining of both projects. The
discussion is stored at the repo root as
[`Bennett-Reboot-Blueprint.md`](../Bennett-Reboot-Blueprint.md)
(DRAFT, not ratified; maintainer: "feels ok, does need a bunch of
iterations").

**Maintainer decisions recorded (the load-bearing output):**
1. **North star:** Bennett.jl + VM work for *any* LLVM language
   (C/Rust/Julia); the dream state is the full Linux kernel compiling
   — "perhaps not efficiently, but it does." This revises the V2 PRD's
   D0 strict-subset contract: in the blueprint, strictness is the
   *circuit backend's* contract; universality is a *system* property
   (total byte-addressed IR + runtimes-as-libraries + VM as universal
   executor + effect tape for the outside world). The maintainer
   rejected, via structured choices, both "strict subset only" and
   "maximal Julia coverage via recognisers," and likewise rejected
   VM-first / formal-first / Sturm-first as the centre of gravity.
2. **Structure:** one workspace, several packages (BennettIR /
   BennettLLVM / BennettVM / ReversibleCircuits /
   ReversibleArithmetic / SoftFloat / BennettRuntimes / Bennett
   meta-package); current repos frozen as v1 reference/oracle if/when
   the reboot is ratified.
3. **Process:** blueprint first, iterate in discussion; no spikes or
   implementation until the maintainer moves it forward.

**Assessment summary (detail in the blueprint §2).** Astra's
"sound core, unsound perimeter" is right on findings, too kind in
framing: cache staleness, tabulation, controlled-decode, checkpoint
replay are public-API wrong answers, not perimeter. What is sound:
construction + gate algebra + arithmetic generators + soft-float core
ops. Measured codebase shape (2026-10-27): Bennett 45,853 src LOC /
68,436 test, 111 src files, 417 test files (CLAUDE.md's "328 test
files" line is stale); `src/extract/instructions.jl` = 8,615 lines,
19% of src. BennettVM 17,275 / 32,618; its module docstring still
claims "M0.1 skeleton only" and its CLAUDE.md still names PRD v3
where PHASE.md says v4 governs (doc drift, VM side untouched).

**Not done / not verified.** No tests run this session (read-only
review). BennettVM beads could not be queried live from this sandbox
(VM repo is read-only there; `bd` lock fails) — VM priorities quoted
from its HANDOFF.md (2026-09-27: 6xy0 first, then wtda/aul4/gn6o/
hyi6/av72). BennettVM HANDOFF.md was NOT updated (same sandbox
write restriction); the blueprint is discoverable from the VM side
via `../Bennett.jl/Bennett-Reboot-Blueprint.md`. The pre-existing
uncommitted `.beads/embeddeddolt/.../repo_state.json` modification
predates this session and is left unstaged.

**Next session, in order.** Unchanged from chunk 120 §"Next session"
(maintainer decisions amah/v4iy first; VM re-pin; sl4h; jzhh/xzsb
scouts) — PLUS, when the maintainer is ready: iterate
`Bennett-Reboot-Blueprint.md` (its §8 lists seven open questions;
§8.1 workspace location and §8.2 Sturm gate contract gate the rest).
Do not start reboot code on the strength of this draft.
