# Worklog chunk 121 — 2026-10-27 — reboot blueprint discussion

Previous: chunk 120 (2026-10-04 wide campaign close; 32 beads closed;
handoff with maintainer decisions pending — amah journal flatten,
v4iy ULP wording — both STILL PENDING, untouched this session).

## Session log — 2026-10-28 — north-star vision settled; `Bennett-NorthStar.md` written (docs only, NO src/test change)

**What happened.** Maintainer-led vision discussion for the from-scratch
reboot, with the current repos declared 100% deprecated as designs. Six
read-only survey agents gathered ground truth first (Astra reviews,
BennettVM state, circuit-vs-literature gaps, controlled/REPL layer, LLVM
ingestion state, and the Sturm.jl checkout at `~/old/Projects/Sturm.jl`).
The settled vision is in [`Bennett-NorthStar.md`](../Bennett-NorthStar.md),
which supersedes `Bennett-Reboot-Blueprint.md` §3.1–3.4 (the standalone
"BIR" idea is dropped).

**Decisions recorded (load-bearing):**
1. Thesis: every program is a quantum program; "controlled-anything"; no
   new language. Bennett is the LLVM of quantum — language designers add
   quantum constructs as they please; we are the target, never the language.
2. **The IR is LLVM IR. Never fork LLVM** (maintainer: the disaster
   scenario). Dialect via sanctioned extension points only: target
   extension types for qubits, an address space for quantum memory,
   intrinsics with attribute-stated legality, function-granularity
   adjoint/control à la Enzyme's `__enzyme_autodiff`, `llvm.lifetime.*`
   for garbage. Delivery = pass plugin + runtime: optimise, reverse,
   optimise. The VISION PRD's Enzyme analogy is literal.
3. Tainted code is device code (GPU offload model); the quantum VM is a
   device. One virtual ISA (public, versioned spec + conformance suite),
   one target description per hardware — the PTX move.
4. The VM is a **scheduler over an extensible resource vector**
   (qubit-time by qubit class as base; energy / quality tiers etc. per
   target; garbage is a schedulable resource). Maintainer chose this over
   "memory manager" explicitly.
5. QIR / OpenQASM 3 are edge formats, never the semantics.
6. Languages (maintainer: "use the right lang for the job", taste
   excluded): plugin in **C++** because the new-PM plugin entry point is a
   C++ ABI and every needed analysis (LoopInfo, DomTree, SCEV, AA,
   MemorySSA, CodeExtractor) is C++-API-only — evidence: v1 reimplements
   loop analysis in `cfg.jl` and parses MemorySSA from printed text in
   `memssa.jl`. VM / ISA / specialiser / estimator in **Rust** (no LLVM
   dependency; embeddable; linear types for qubit ownership). Julia =
   front door, REPL, Sturm bridge, lab. Arithmetic + runtimes = libraries
   in any language, compiled through the same pipeline, shipped as ISA
   objects with cost certificates. Centre of gravity leaves Julia;
   maintainer accepts.

**Ground-truth surprises worth remembering (from the survey agents):**
- Sturm.jl is real (~16k LOC) with a working Bennett bridge
  (`src/bennett/bridge.jl`, `inplace.jl`, `ext/SturmBennettExt.jl`):
  contract |x⟩|t⟩|0⟩ ↦ |x⟩|t⊕f(x)⟩|0⟩, MCX-native `Perm`, `ctrl(Perm)=Perm`,
  clean-|0⟩ alloc only, no dirty borrow, MBU banned under `ctrl` by type.
  The 2026-08 critique's "nobody read Sturm.jl" is now resolved.
- BennettVM has zero quantum notions; its history tape is Bennett's
  garbage under another name. "amah journal flatten" is the beads dolt
  store (93.7 MB vs GitHub's 100 MiB), not the VM.
- No C/Rust program has ever gone end-to-end through Bennett.jl; the T5
  corpus tests assert `@test_throws`. Largest foreign code anywhere is
  BennettVM's 948-line 6502 emulator.
- Circuit gaps vs literature: 32-bit add 122 Toffoli vs ~31 (Gidney
  temporary-AND); f64 add 12,488 vs ~2,000 (Häner et al.); SHA-256 round
  1.8× Toffoli / 3.3× wires vs PRS15. No Clifford-vs-T model, no MCX,
  `target=:depth` is a no-op. SURVEY.md has no arithmetic section.
- `controlled()` controls every gate (i8 x+1: 12 → 76 Toffoli) instead of
  control-only-the-copy-out.

**Later the same session — two maintainer side notes folded into the doc,
then the council.** (1) "The quantum VM is a massive revolution … let us
not make the mistakes of the pre-VM era of classical computing" → new
preamble to `Bennett-NorthStar.md` §4 (virtual-ISA-not-machine, virtual
qubit memory, loops as instructions, resource accounting in the spec,
public spec). (2) "as tight and modular and microserviced as possible;
prefer more independent repos; a monolith *will* grind to a halt" → new
§6.1: twelve independent repos coupled only by the dialect spec and the
ISA spec; test of the split = any repo replaceable by a competitor's
implementation of the same spec.

**The council** (maintainer: codex `gpt-6-astra` xhigh + muse
`muse-wonder-full-1.0` + Claude Opus 5.5; grade against criteria; iterate
until all agree; max 3 rounds; resumable against network/capacity
failures; modelled on `../sublimite/docs/design/council.md` and the
t3dotgg/tstack `council` skill). Built: `docs/council/rubric.md` (8
criteria C1–C8, absolute 1–5, blocking issues, verdict accept/revise/
reject; consensus = all accept with empty blocking), `docs/council/
README.md`, `tools/council.py` (prepare/run/status/aggregate/selftest;
state under `docs/council/<run>/round-N/` in-repo, atomic state.json,
parallel members, per-member resume, retries with 60/180/420 s backoff,
raw output of every attempt kept). Gotchas found by probing: `codex exec`
blocks forever unless stdin is closed or is the prompt (`-- -` +
stdin=file); nested `claude -p` needs `CLAUDECODE*` unset and the prompt
on stdin because `--allowedTools` is variadic and swallows a trailing
prompt; muse prints status lines before its JSON (take the last object).
Round 1 of run `northstar-2026-10-28` launched 08:41 UTC on doc snapshot
sha256 f0a43e76…; maintainer reports codex capacity trouble today — the
retry loop and `run` re-invocation cover it.

**Council round 1 result** (all three members in one attempt each; muse
139 s, opus 222 s, codex 1031 s — codex worked despite the capacity
trouble): all `revise`, mean 2.62/5, C2/C5/C7 all 2s. Fifteen blocking
issues that converge on eight themes, every one accepted (see
`docs/council/northstar-2026-10-28/round-1/response.md`): §3 overclaimed
out-of-tree LLVM (no plugin intrinsics, target-ext types unsized and not
front-end-emittable, no iN taint via addrspace/attrs, lifetime only on
allocas, loop metadata droppable, SSA uses duplicable → rewritten around
Enzyme-style marker declarations + handles in an addrspace + bounds as
operands + taint by analysis + legality spike as gate); no compilation
model (→ link-time over whole-program bitcode, fat objects, own driver,
clang offload as model not mechanism, rustc via bitcode since plugins are
nightly-only); effects under superposition undefined (→ three tiers,
coherent = closed + effect-free + devices virtualised); two control
classes conflated (→ classical dynamic vs coherent predicated-and-padded;
VM policy inspects classical data only); correctness blind to phase (→
accepted with the permutation theorem: X/CX/CCX circuits are permutation
matrices so basis-state + clean-ancilla agreement on every input
determines the unitary exactly; phase-sensitive checks only for MBU /
rotations); qubit value-vs-reference undecided (→ handles in dialect,
linear wires in ISA, the Quake ref/wire lesson); repo split contradicted
"one codebase" and the two contracts omitted object/ABI/launch/certificate
formats (→ withdrawn; `bennett-sched` as its own Rust/C-ABI repo used by
plugin and VM; ISA spec enumerates every cross-boundary format); prior
art absent (→ §7 landscape table, QIR critique corrected). Iteration 2 of
the doc (sha256 7ec8f6fa…) is ~2× the length. Round 2 launched.

**Council round 2 result** (muse 174 s, opus 225 s, codex 850 s, one
attempt each): all `revise` but mean 3.75 (from 2.62); C1/C3/C4/C7/C8
unanimous 4s; seven blockers on three themes + one ABI point, all
accepted (`round-2/response.md`): (1) bound exhaustion / totality →
region-level classical budget (steps, heap, depth) as marker operands or
out-of-band, never per-loop source annotations; general coherent
execution = predicated step machine over any post-O3 CFG; every coherent
region total with a **fault register** (budget / immediate UB /
unmodelled effect), workspace still returned clean on fault; equivalence
= "equals native or is flagged", fault rate zero on acceptance domains;
(2) verification scope → permutation tier defined *after* decomposition
into emitted gates (relative-phase Toffolis and MBU excluded), theorem
domain D stated exactly (all x, all t, all dirty-ancilla values),
exhaustive-on-D is complete, sampling is evidence, MBU verified as a
channel (Choi + reference system), certificates label proof vs evidence;
(3) definedness → "UB concretised" withdrawn; reference semantics is the
optimised bitcode, freeze refinement, immediate UB = fault, UBSan-
instrumented native oracle excludes UB-triggering inputs; (4) handles =
ordinary addrspace(0) `ptr`/integer (Rust can't emit address spaces),
quantum memory only via qload/qstore markers (also kills the GVN hazard).
Plus: positive legality requirement on markers, Quil/QAM/eQASM/Knill-QRAM
/Spire/Qrisp in §7, sched interface owned by the ISA spec. Maintainer
mid-round: "ask them for constructive criticism, i.e., how to overcome
blockers" → prompt now demands a concrete vision-level fix per blocker
and a required `path_to_accept` field (schema + validate + report). Round
3 (final; max 3 by maintainer rule) launched on sha256 81b6d2f0….

**Council round 3 result (final; three-round budget spent):** muse
`accept`, codex `revise`, opus `revise`; mean 4.04; every criterion ≥ 4
(codex C4 = 5, muse C6 = 5); all seven round-2 blockers confirmed
resolved by all three. Residue = five semantic paragraphs with explicit
paths-to-accept, all agreed and folded into iteration 4 of the doc
without a fourth round (`round-3/response.md`): (1) one authoritative
definedness contract — reference semantics = ISA formal-model
interpreter on freeze-normalised optimised bitcode; erased source UB is
a recorded assumption, not a fault guarantee (codex demonstrated
`clang -O3` folding `10/x` away); (2) deterministic faulted result
F_B(x) — success XORs f(x), failure XORs zero payload + fault code; XOR
both ways ⇒ involution ⇒ composes under Grover iteration; prefix-
reversal invariant; budget unit = reference-interpreter steps; (3) input
preservation as a theorem hypothesis + full-register-tuple equality in
§5.1; (4) coherent memory: read = CNOT copy, write = XOR (store into
not-known-clean = compile error), in-place x←g(x) needs an inverse
(`__bennett_inplace(@g,@ginv)` or library bijection) — this is what
makes `when(q) do x += a end` compile; (5) uncomputation-validity
invariant (Silq qfree/const, Unqomp): garbage uncomputed only while its
dependency set is unmodified, cleaned before any non-permutation op on a
dependency; schedulers confined to valid schedules. Timings: muse 103 s,
opus 245 s, codex 765 s; zero retries across all three rounds despite
the codex capacity day. Trajectory 2.62 → 3.75 → 4.04.

**Gotcha for future councils:** members converge fast on *premises*
(LLVM facts, prior art) but each round surfaces one deeper *semantic*
layer (effects → bounds/totality → memory/uncomputation validity).
Budget rounds for depth, not for premise-fixing; and ask for
`path_to_accept` from round 1, not round 3.

**Not done.** No tests run; no src/test change; nothing committed or
pushed this session yet (maintainer still iterating). BennettVM untouched.

**Next.** Iterate `Bennett-NorthStar.md` §8 (open technical questions) in
maintainer-chosen order — the legality contract (§8.1) and region
outlining (§8.2) gate the rest. Still pending from chunk 120: amah / v4iy
decisions.


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
