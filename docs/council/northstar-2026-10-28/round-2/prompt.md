# Council

You are a member of a three-model council grading the document below, the founding vision for a from-scratch reboot of Bennett (a reversible / quantum compiler toolchain; see the document). Grade it against the rubric on the absolute scale. Be exacting and skeptical: verify every technical premise against your own knowledge; name any that is false. Grade the vision for being the right vision, stated precisely; do not deduct for things that are not built yet. A blocking issue is one that would make the project build the wrong thing if uncorrected; everything else is a suggestion. Return `accept` only if the blocking list is empty.

You may read the repository you are running in (read-only) to check claims about the current code; its root contains Bennett-NorthStar.md (the document, identical to the snapshot below), Bennett-Reboot-Blueprint.md and Bennett-V2-PRD.md (the superseded plans), worklog/ (session logs; chunk 121 has the 2026-10-28 ground-truth survey), reviews/2026-09-26-astra/ (the last review campaign), and src/ (the deprecated v1). Reading is optional; the snapshot below is what you grade.

Answer only with JSON matching the schema.

# Previous round (1)

Verdicts: codex: revise, muse: revise, opus: revise

Blocking issues raised last round:
- [codex] B1_EFFECT_DOMAINS (§§0, 1.3–1.4, 3 effects row, 5, 7): The unrestricted controlled-anything promise conflates classical reversibility with quantum coherence. Recording a measurement result does not restore the discarded coherence, and recording external output does not make the external observer reversible. A bounded deterministic simulation of SQLite or Linux can become a coherent oracle; an execution that exposes branch-dependent information to an ordinary console, filesystem, or measurement record cannot generally be uncomputed into that oracle. Likewise, replaying one recorded environment is not equivalent to evaluating every superposed input against a live environment. [Measurement and reversibility](https://arxiv.org/abs/1808.08598). Fix proposed: Define separate execution capabilities for classical execution/replay, coherent reversible computation, and measurement-bearing computation. Preserve broad language coverage through an explicitly modeled environment: specify inputs, randomness, memory, bounds, and effects included in the reversible state. Require external effects to be coherently modeled or deferred where coherent control is promised; define rejection or another explicit semantic outcome otherwise. State the defined LLVM execution domain, including the treatment of undefined behavior.
- [codex] B2_LLVM_CONTRACT (§3 and §8.1): The extension-point table asserts guarantees these mechanisms do not provide. Target extension types are not linear; address spaces qualify pointers rather than arbitrary iN values; unfamiliar instruction metadata can be dropped; and llvm.lifetime.end describes memory lifetime, not quantum cleanup. [LLVM language reference](https://llvm.org/docs/LangRef.html). Convergence constrains particular control-flow transformations rather than furnishing general quantum effect semantics. [Convergence semantics](https://llvm.org/docs/ConvergentOperations.html). Genuine new llvm.* intrinsics require LLVM-side definitions, unlike Enzyme-style external marker calls. [Extending LLVM](https://llvm.org/docs/ExtendingLLVM.html). Consequently, the claimed blanket legality does not follow from the proposed mechanisms. Fix proposed: Commit to a viable conservative no-fork representation: distinguish classical computations awaiting coherent lifting from explicit quantum state and effects; use ordinary effectful marker calls where necessary; carry mandatory bounds and lifecycle operations semantically rather than solely as metadata. State where verification and quantum lowering occur relative to ordinary optimization. Exact attributes may remain a design question, but their claimed guarantees cannot remain settled facts.
- [codex] B3_COHERENT_RUNTIME (§§1.6, 3, 4, 8.3–8.7): A classical runtime cannot inspect a superposed trip count, allocation decision, pointer, or garbage value to choose an ordinary execution path without potentially destroying coherence. Nor can classical checkpointing be transferred to arbitrary quantum states by copying them. Maximum-bound padding addresses execution length, but does not specify coherent allocation, history, release, or what happens when only some branches exceed a bound. Leaving these as unrestricted resource policy risks building a reversible classical debugger and calling it a quantum VM. Fix proposed: Require scheduling decisions either to depend only on classical information or to be implemented coherently. Identify coherent versus classical heap, history, and control state; define bound-exhaustion semantics and the memory/recursion bounds needed for specialization. Specify clean release and dirty borrowing as semantic obligations, including restoration of correlations with external reference systems. Defer the scheduling algorithms, not these invariants.
- [codex] B4_QUANTUM_CORRECTNESS (§§2, 5, 7, 8.8): Matching native bit outputs and returning ancillae to zero does not establish a correct quantum oracle. A circuit implementing |x,0> → (-1)^g(x)|x,f(x)> passes those checks while introducing an unintended phase; even a global phase becomes observable when the operation is controlled. Measurement-bearing programs require comparison of quantum instruments or channels, not merely recorded outcomes. The current success definition can therefore certify artifacts that break the flagship quantum algorithms. Fix proposed: State the intended phase-sensitive oracle embedding and the semantics of general quantum operations, including entangled inputs and dirty ancillae. Add small exhaustive operator/channel checks and interference tests to the ladder. Specify approximation budgets for rotations and hardware lowering, and identify what proof-carrying output proves, under which assumptions, with what independent checking. Describe differential testing as evidence rather than universal proof.
- [muse] B1 (§3): Several rows are false as stated: llvm.lifetime.start/end annotate memory objects, not SSA garbage values; LLVM loop metadata is droppable and cannot carry load-bearing bound semantics; target extension types do not give linear ownership, because LLVM SSA uses may be duplicated, selected and threaded before any after-the-fact verifier runs; and a pass plugin cannot register new llvm.* intrinsics, only recognise calls to declarations. The iN-plus-taint row also conflicts with the target-extension-type row: ordinary iN values carry no address-space or per-value taint that survives optimisation. Fix proposed: Rewrite the table around verified mechanisms: opaque declared marker functions rather than new intrinsics, bounds as explicit operands of marker calls, custom garbage markers, region outlining before general optimisation of tainted code, and a named pipeline placement. Make a legality spike against stock LLVM passes a gate on freezing bennett-dialect-spec.
- [muse] B2 (§1.3-1.4, §6): 'Loaded by clang, rustc, and Julia without modification' and reuse of clang's GPU offload model are not true at the level needed. clang offload outlining, fat binaries and launch are front-end/driver mechanisms tied to language annotations and target triples, not something a middle-end plugin can conjure after taint analysis; rustc does not load clang pass plugins, does not use the clang driver, and exposes LLVM plugins only unstably; Julia integration is a separate problem the document itself defers in §8.9. Fix proposed: Scope the claim: a clang/opt pass plugin first; rustc needs its unstable LLVM-plugin/codegen-backend path and Julia needs an LLVM.jl pipeline integration, each named as its own front-end integration. State that Bennett needs its own driver, link step and launch runtime (bennett-driver), with clang offload as the model, not a reused mechanism.
- [muse] B3 (§4, §8.4): The ISA's central semantics are conflated: 'branch on a qubit' and 'loop while a quantum register is nonzero' cannot be classical instruction-pointer control in superposition; coherent control is predication padded to a maximum, as §4 half-admits, while measured feedback is ordinary classical branching. Until the vision says which class each ISA control instruction belongs to, 'one semantics, two executors' and 'circuit as bounded specialisation of the VM' are undefined, and the ISA spec, the VM and the specialiser would be built against different machines. Fix proposed: Define two control classes in the vision itself: classical control flow on measured/host data, which is genuinely dynamic, and coherent control, which is predicated execution padded to a bound in both executors. State that the circuit is a specialisation of the VM only under that shared padded semantics, and drop any implication that run-time bounds unlock superposition trip counts.
- [muse] B4 (§0, §3, §5, §7): An effect tape makes classical replay deterministic; it does not make I/O, syscalls, measurement or host filesystem access unitary. As written, Grover over SQLite executed 'by the actual SQLite engine' and amplitude amplification with 'the kernel panics' as oracle require coherent access to external state and an irreversible effect inside an oracle, which is physically incoherent. The same gap covers UB/poison, atomics, volatile, inline asm and exceptions: §0 promises universality for anything clang accepts, but no reversible semantics for undefined or effectful executions is stated, only deferred in §8.11. Fix proposed: Add an effect boundary to the thesis: coherent regions are closed and effect-free, with classical inputs fixed before entry and outputs emitted after measurement; databases and kernels run as reversible code over reversible memory, with panic/query-match as computed predicates. Restate universality as covering every defined, effect-bounded execution, with trap/shim semantics for the rest, and rewrite rungs 4 and 7 accordingly.
- [muse] B5 (§5, §7): Differential equivalence against native execution on classical inputs cannot detect relative-phase errors or residual garbage entanglement, yet the thesis is controlled-anything: an artefact correct on every basis state can be wrong under control and in superposition, which is the only place it will be used. 'It compiles and it is correct are the same statement' therefore overclaims, and 'proof-carrying circuit' is never given a checkable meaning. Fix proposed: Redefine correct as basis-state differential equivalence plus phase-sensitive checks: unitary equivalence at exhaustive small widths and controlled/interference differential tests (run the artefact controlled and in interference against a reference), with proof-carrying output given a concrete certificate notion a checker can validate.
- [muse] B6 (§1.6, §6, §6.1): The dialect spec and ISA spec are not sufficient for every pair of components to communicate, and §8.6 defers exactly the missing pieces: plugin, driver, runtimes and arith also couple through a reversible ABI, a linkable object format, a host/device launch ABI, and a cost-certificate format shared by circuits, arith, estimate and Bennett.jl. Two internal contradictions hide the monolith: §1.6 makes compiler and VM 'the same optimiser at two time scales' across the contract boundary, and §6 gives both executors 'one codebase' while §6.1 splits them into independently replaceable repositories. Fix proposed: Either expand the ISA spec's stated contents to own the object/link format, reversible ABI, host launch/runtime ABI and cost-certificate schema, or name them as further contracts. Resolve the scheduler and one-codebase contradictions explicitly: what is shared, through which spec, such that a competitor's VM or specialiser could still replace either executor.
- [opus] B1-dialect-extension-points (§3 table, §1.2): Several extension points the dialect depends on are not available to an out-of-tree plugin, or do not do what is claimed. Out-of-tree code cannot add llvm.* intrinsics. Target extension type properties are hardcoded per name inside LLVM, so target("bennett.qubit") is unsized: it cannot be stored, alloca'd, made a global, or placed in memory aggregates, which rules out qubit arrays and 'quantum memory'. clang and rustc cannot emit the type from source. Address spaces and attributes cannot taint iN values. lifetime intrinsics apply only to allocas. Loop metadata is droppable and cannot carry a runtime bound operand. The cited examples (NVPTX, AMDGPU, SPIR-V) are in-tree. Built as written, the project would rest on mechanisms that do not exist. Fix proposed: Restate §3 in terms of mechanisms that do exist: marker function declarations (Enzyme-style) with call-site attributes added by the plugin, handle retyping at PipelineStartEP, bounds as real operands of marker calls, garbage lifetime from liveness, and taint from analysis. Where a target-extension-type property entry is genuinely needed, say it will be proposed upstream (an upstream patch, not a fork), or design without it.
- [opus] B2-qubit-semantics (§3 rows 1 and 4, §1.7): The document wants qubits as 'SSA values … never opaque pointers' that are visible to dataflow, and also gates as intrinsics with memory effects so that passes cannot CSE, hoist or delete them. If gates have memory effects, the qubit is a handle whose state changes through hidden memory. That is QIR's problem again. Value semantics with readnone gates instead invites speculation that breaks linearity. Opacity does not prevent copies either, because SSA uses are free. This choice is the core design decision of the dialect, and CUDA-Q's Quake has both ref and wire forms precisely because of it. Fix proposed: Decide value vs reference semantics, or say which form is used at which pipeline stage, at the vision level. State plainly that LLVM cannot enforce linearity, so linearity rests on a fail-loud verifier plus the legality contract.
- [opus] B3-taint-compilation-model (§1.3–1.4, §5 toolchain, §6.1 driver): Taint and controlled or adjoint bodies depend on the call context across the whole program. A function in one TU may be called under a qubit from another, and generating its controlled body needs its IR, which is Enzyme's own requirement. clang's offload machinery (outlining, fat binaries, launch) is driven by the frontend and driver over separately compiled device modules, so a pass cannot reuse it after the fact. As written, a per-TU plugin cannot decide what is 'never ours', and 'one reversible object per TU' is underspecified. Fix proposed: Specify the compilation model. Every function is emitted natively and also carries embedded IR (a fat object). Device specialisation, taint resolution, and control and adjoint generation happen at link time (LTO plugin) or load time (runtime JIT). Define 'untainted' relative to the resolved call graph. The ISA lowering must accept host-triple IR (datalayout, ABI, target intrinsics, inline asm as trapped or shimmed).
- [opus] B4-effects-under-superposition (§3 effects row, §4 effect tape, §7 rungs 4/6–8): A recorded effect tape gives deterministic replay only for classical and reversible execution. In a superposed region, the effect sequence differs per branch, and a real outside-world effect (console, disk, a SQLite file read at a quantum-dependent address) decoheres or is simply undefined. The flagship rungs (Grover over SQLite, kernel fuzzing) depend on this semantics, which the document does not define. Fix proposed: Define effect semantics per tier. The classical and reversible tiers may tape. The superposition tier must either trap on external effects or virtualise them as state inside the device (SQLite through an in-memory VFS over QROM/QRAM, devices modelled reversibly). Also state that VM run-time policy may depend only on classical data.
- [opus] B5-repo-split-contradiction (§6 Rust row vs §6.1, §1.6): §6 says the two executors live in one codebase, giving one semantics by construction, but §6.1 makes them independently replaceable repositories. Decision 6 says the compiler and VM are one optimiser, but the optimiser is split across C++ and Rust with no shared code, which breaks the document's own rule that C++ is used only where LLVM is linked. The host↔device launch ABI and the reversible object format belong to no contract. The split would be built wrong. Fix proposed: Choose one executor arrangement and make the ISA spec's formal model plus the conformance suite the source of 'one semantics'. Move the scheduler and cost model into a non-LLVM component behind a specified interface used by both plugin and VM. Make the ISA spec explicitly own the launch ABI, object/linking format, and cost-certificate format.

## Editor's response (what changed, what was declined and why)

# Editor's response to round 1

All three members returned `revise` (mean 2.62). Their blocking issues
cluster into eight themes; every theme was accepted and the document was
rewritten (iteration 2). Where a point was accepted with a correction, the
correction is stated.

## Accepted and changed

1. **§3 extension-point table overclaimed** (codex B2, muse B1, opus B1).
   Rewritten as §3.1 around mechanisms an out-of-tree plugin has: declared
   marker functions (no plugin-registered intrinsics), opaque handle
   pointers in an address space (front ends can emit these; target
   extension types cannot be emitted and are unsized out of tree), taint
   by analysis not types, bounds as real operands of marker calls (no
   metadata), garbage from liveness (no lifetime intrinsics), legality as
   the ordinary property of non-speculatable side-effecting calls (no
   invented attributes; `convergent` dropped). The legality spike is now a
   gate on freezing the dialect spec (§3.2, §9.1). Upstream patch, not
   fork, wherever LLVM-side support is genuinely needed.
2. **Compilation model missing** (muse B2, opus B3, codex C5). New §3.3:
   link time over whole-program bitcode, fat objects, our own driver with
   clang offload as the model not the mechanism, host-triple IR accepted
   by the lowering, per-front-end integration named (clang `-flto`; rustc
   via bitcode emission because in-process plugins are nightly-only; Julia
   via LLVM.jl). "Loaded by clang, rustc and Julia without modification"
   is withdrawn and replaced by "any front end that emits bitcode".
3. **Effects under superposition undefined** (codex B1, muse B4, opus B4).
   New §4.2 effect table per tier: coherent regions are closed and
   effect-free, devices virtualised as reversible state inside the device,
   classical inputs fixed before entry, outputs through measurement after
   exit, unvirtualisable effects refused at compile time by name. §0
   restated as "every defined, effect-bounded execution". Rungs 4, 7, 8
   rewritten with fixed classical state, virtualised devices, and
   acceptance tests.
4. **Two control classes conflated** (codex B3, muse B3, opus C3). §4.2
   now separates classical control (dynamic) from coherent control
   (predicated, padded to a classical bound fixed before entry). Run-time
   policy may inspect only classical data, stated as an architectural
   invariant. The implication that run-time bounds unlock superposed trip
   counts is withdrawn explicitly. Honest costs of superposition added
   (§4.3): both arms paid, O(N) quantum-addressed memory, padded
   allocation. Clean release and dirty borrowing are semantic obligations.
5. **Correctness blind to phase** (codex B4, muse B5, opus C6). Accepted
   with a correction: for the permutation tier (X/CX/CCX/MCX only) basis-
   state agreement plus clean ancillae on every basis input determines the
   unitary exactly, so no relative phase and no garbage entanglement is
   possible; differential testing is complete there, by theorem. Phase-
   sensitive verification (unitary equivalence at small widths, controlled-
   interference tests, stated ε) is required for measurement-based
   uncomputation, rotations, and synthesised non-permutation gates, and
   algorithms are verified compositionally by simulation with branch
   enumeration. "Proof-carrying" now says what the certificate asserts and
   who checks it (§5.1).
6. **Qubit value vs reference semantics undecided** (opus B2). Decided:
   reference semantics (handles) at the dialect level, where LLVM cannot
   enforce linearity and a fail-loud verifier does; linear wire semantics
   in the ISA. Both forms at named stages, as Quake keeps ref and wire.
7. **Repo split contradictions and missing contracts** (muse B6, opus B5,
   codex C4). "One codebase holds both executors" withdrawn; one semantics
   comes from the ISA spec's formal model and conformance suite. The
   scheduler and cost model move into `bennett-sched` (Rust, C ABI),
   linked by both the plugin and the VM, which makes decision 6 literally
   true. The ISA spec now explicitly owns the object and link format, the
   reversible ABI, the host–device launch ABI, and the cost-certificate
   schema (§4.4, §6.1). The build dependency of runtimes and arith on the
   driver is declared.
8. **Prior art absent; QIR critique partly wrong** (all three, C7). New §7
   landscape table (Enzyme, PTX/offload, QIR, OpenQASM 3, CUDA-Q/Quake,
   Catalyst/MLIR, Q#, Quipper, Silq/Unqomp/Reqomp/SQUARE, Tower,
   Qualtran/Azure RE, QSSA/QIRO, ReVerC, pebbling literature) with a
   narrow novelty claim. QIR critique corrected: opaque pointers do
   participate in SSA dataflow; adaptive profile and memory-management
   spec acknowledged; the defensible criticism restated.

Also from suggestions: optimality qualified (pebbling is PSPACE-complete;
optimal within a declared search space with gap certificates); resource-
vector decision rule (scalarisation or lexicographic order supplied by the
target); governance paragraph; Rust is affine not linear; C++ rationale
corrected (`llvmGetPassPluginInfo` has C linkage, registration and analyses
are C++); pipeline placement and "correctness invariant, cost not" stated;
non-normative ISA sketch and example target description added (§4.5);
each ladder rung has an acceptance test with instance sizes and oracles;
xkcd aside removed; the "leading figures" sentence moved out of the
argument into the provenance note.

## Declined or kept, with reasons

- **Drop the appeal to the maintainer's year of discussion entirely**
  (opus C8). Kept as provenance, not as argument, at the maintainer's
  explicit instruction that this context matters; it is no longer inside
  §4.
- **"A classical runtime cannot inspect a superposed value"** (codex B3)
  is accepted as the invariant; the stronger reading that the VM is
  therefore "a reversible classical debugger" is answered in §4.2's last
  paragraph: the VM is a classical runtime that schedules quantum
  operations, and that is the claim, not a retreat from it.
- **The branch-enumeration simulation** is new in this iteration, added
  because it is what makes rungs 4, 7, 8 testable at small instance size
  without a state vector the size of SQLite's memory. Members are asked to
  check the claim: a permutation oracle applied to a state vector is a
  permutation of amplitudes, so running the reversible program once per
  basis state of the superposed inputs is an exact simulation of the
  oracle.


Re-grade the revised document below from scratch on the absolute scale. For each blocking issue above, state in your summary whether it is resolved; re-raise it in `blocking` only if it is not.


# Rubric

# Vision-document rubric — the council's scale

The rubric the council (`docs/council/README.md`) uses to grade
`Bennett-NorthStar.md`, the from-scratch reboot vision for Bennett. Eight
criteria, each scored 1–5 on an absolute scale, plus blocking issues and a
verdict. Scores are advisory; the maintainer decides.

## What is being graded

A **vision document**, not an implementation. The current Bennett.jl and
BennettVM.jl are declared deprecated as designs; the document describes
what the reboot must become. Grade the vision for being the right vision,
stated so that strangers could build it. Do not deduct for "this does not
exist yet". Do deduct, and block, for a technical premise that is false
(for example a claim about what LLVM permits without a fork), an internal
contradiction, a missing load-bearing piece, or ambition that is incoherent
rather than merely large.

## The standard

The maintainer's standard: **unreasonably ambitious, and right.** The
document should read as the founding document of the abstraction layer
quantum programming has lacked, the way the PTX ISA document, the JVM
specification, or the LLVM language reference read for their domains. The
question for each criterion is whether a hardware vendor, a language
designer, and a compiler engineer could each read this and know what to
build and why it will matter.

- **Scores are absolute**, not on a curve, and never relative to the
  current code.
- **Ambition is a virtue; vagueness is not.** A bold claim stated
  precisely scores; a bold claim that hides a contradiction does not.
- **Skepticism is required.** Verify technical premises against your own
  knowledge of LLVM, Enzyme, PTX, QIR, OpenQASM, MLIR, Catalyst, CUDA-Q,
  Silq, Q#, Quipper, Tower, and the reversible-computing and
  resource-estimation literature. Name the premise if it is wrong.
- **Blocking means blocking.** A blocking issue is one that, uncorrected,
  would make the project build the wrong thing. Everything else is a
  suggestion.

### Scale

- **5:** founding-document quality. Precise, complete for its level,
  premises verified, nothing load-bearing missing, nothing superfluous.
- **4:** right, with one gap a domain expert names at once.
- **3:** a competent plan. Sound but generic; nothing a field would rally
  around.
- **2:** aspirational. Direction is visible, but premises are unexamined or
  key pieces are missing.
- **1:** incoherent, or built on a false premise.

## Criteria

### C1 Ambition and coherence

Is the north star unreasonably ambitious *and* internally coherent? Do the
thesis, the decisions, the architecture, and the demo ladder describe one
thing, or several things stapled together?

### C2 Technical premises

Are the technical claims true? In particular: that the dialect can live in
LLVM IR through sanctioned extension points without a fork (target
extension types, address spaces, intrinsics with attribute-stated legality,
function-granularity adjoint/control, lifetime intrinsics, loop metadata);
that the Enzyme plugin model (optimise, transform, optimise) transfers; that
the GPU offload model fits the taint tiers; that the pass-plugin entry point
and the needed analyses are C++-only; the stated problems with QIR.

### C3 The quantum VM as the revolution

Is the VM articulated as the abstraction layer quantum programming lacks,
with a clear account of what it abstracts (virtual qubits, allocation
classes, bounded dynamic control flow, garbage as a scheduled resource, the
resource vector, the effect tape)? Are the pre-VM-era lessons the right
ones? Is the "circuit model as the bounded specialisation of the VM" claim
sound, and is the padded-to-maximum semantics for loops in superposition
stated honestly?

### C4 Modularity and independence

Is the split into independent repositories right? Are the two contracts
(dialect spec, ISA spec) sufficient for every pair of components to
communicate, and are they the *only* coupling? Could each repository be
replaced by a competitor's implementation of the same spec? Where is a
monolith hiding?

### C5 Universality without forking

Is "any LLVM language, invisibly, with no fork" credible as stated? Are the
costs (optimiser not reversibility-aware, regions must be functions,
per-LLVM-version builds) the real costs, and are any missing? Is the
host/device split the right place for the classical/reversible/quantum
boundary?

### C6 Verifiability and success criteria

Is the demo ladder measurable, ordered, and sufficient to define success?
Is "correct" defined as differential equivalence against native execution
rather than as a reversibility check? Is proof-carrying output and
resource estimation without materialised gates a coherent verification and
cost story?

### C7 Position in the landscape

Does the document understand prior art (QIR, OpenQASM 3, MLIR dialects,
Catalyst, CUDA-Q, Silq, Q#, Quipper, Tower, Qualtran-style resource
estimation, reversible-computing pebbling literature) and state precisely
what is new? Is anything claimed as new that is not? Is anything existing
ignored that should be built on or interoperated with?

### C8 Clarity and completeness as a document

Could the three readers (hardware vendor, language designer, compiler
engineer) each read this and know what to build? Are the open technical
questions the right ones, correctly deferred, and is anything deferred that
is actually load-bearing for the vision?

## What the council returns

Per criterion: a score 1–5, one or two sentences of evidence pointing at
the document's text, and the single change that would most raise the
score.

Then:

- **blocking**: a list (possibly empty) of blocking issues, each with a
  short id, the section it concerns, the problem, and the fix. Blocking
  means the project would build the wrong thing if uncorrected.
- **suggestions**: non-blocking improvements, ranked.
- **verdict**: `accept` (ready as the founding vision, blocking list
  empty), `revise` (right direction, blocking issues to fix), or `reject`
  (wrong direction or false premise at the core).
- **summary**: one paragraph.

Consensus is reached when every member returns `accept` with an empty
blocking list. The loop runs at most three rounds.


# The document (`Bennett-NorthStar.md`, round 2 snapshot)

# Bennett — North Star (reboot vision, iteration 2)

**Date:** 2026-10-28. **Status:** vision settled at the level of "what it
truly looks like"; technical design NOT started. Iteration 2 after council
round 1 (`docs/council/northstar-2026-10-28/round-1/report.md`; three
members, all "revise"; the editor's response is in `round-1/response.md`).
Nothing here is implemented, and no code is to be written on the strength
of this document alone (maintainer process rule: vision, then design, then
spikes, then code).

**Provenance.** Written up from maintainer/agent design discussions on
2026-10-28. The maintainer's position on the quantum VM (§4) was formed
over a year of discussion across the quantum-information community; the
document states that position and the reasons, and asks to be judged on
the reasons.

**Relation to earlier documents.** Supersedes `Bennett-Reboot-Blueprint.md`
§3.1–§3.4 (its standalone "BIR" is dropped: the IR is LLVM IR with a
dialect inside it). The blueprint's §5 keep/kill list, §6 ladder and §7
risks carry over where they do not conflict. `Bennett-V2-PRD.md` remains
parked. `Bennett-VISION-PRD.md`'s Enzyme analogy turns out to be literal.

**Ground truth this was checked against** (2026-10-28 read-only survey of
both repos, the Astra reviews, BENCHMARKS.md, and the Sturm.jl checkout at
`~/old/Projects/Sturm.jl`): worklog chunk 121, session 2026-10-28. The
current Bennett.jl / BennettVM.jl are deprecated as designs; their research
assets (arithmetic generators, soft-float with its test conventions, gate
algebra, scaling-relation regressions, the 6502 native-oracle harness) are
the only things carried forward.

---

## 0. Thesis

**Every program is already a quantum program.** The user never writes a
circuit, never declares a subset, never learns a new language. They write
C, Rust, Julia, anything LLVM eats, and the toolchain decides at every
instruction whether it runs classically, reversibly, or coherently. The
only thing a quantum programmer adds to a classical codebase is a handful
of marker calls: allocate qubits, rotate by theta, measure, and a way to
condition a region on a qubit. Everything else is inferred.

Tagline: **controlled-anything.** If it compiles with clang, you can put it
under a qubit.

Stated precisely, because precision is what makes the slogan true rather
than a slogan (§3.1): *every defined, effect-bounded execution of any LLVM
program can be run coherently under a qubit, with its external effects
either virtualised inside the device or refused at compile time with a
named reason.* Undefined behaviour is concretised and recorded; effects
outside the model are a coverage-report line, never a silent wrong answer.

The project is predicated on scalable logical quantum computation becoming
real: plenty of logical qubits and gates at usable gate times. Efficiency
is pursued hard; universality is never traded for it.

## 1. Decisions (settled 2026-10-28, refined after council round 1)

1. **Bennett is the LLVM of quantum.** Language designers introduce quantum
   constructs *as they please*, the way LLVM lets anyone design a classical
   language. We provide the target and the optimiser, never the language.
   Whether `if (q)` on a qubit is a source construct is a front-end
   question, not ours.
2. **The IR is LLVM IR. We never fork LLVM.** Forking is the disaster
   scenario. Decades of classical optimisation are kept by sitting inside
   the ecosystem through mechanisms an out-of-tree plugin can actually rely
   on (§3). Where an upstream change would help, it is proposed upstream as
   a patch, never carried as a fork.
3. **Delivery is a pass plugin, a driver, and a runtime.** The plugin runs
   at **link time over whole-program bitcode** (§3.3): optimise, reverse,
   optimise. Any front end that can emit bitcode is supported without
   modification; per-front-end integration is a driver concern, named per
   front end, never a language change.
4. **Three execution tiers, one program.** Classical (host, native code,
   never ours), reversible (device, deterministic forwards and backwards,
   effects on a tape), coherent (device, closed and effect-free, every
   control decision predicated and padded, §4.2). The quantum VM is the
   device, in the sense a GPU is a device: the host launches, the device
   executes.
5. **One virtual ISA, one target description per hardware.** The PTX move.
   The ISA is a versioned public specification with a conformance suite;
   the formal model is of the spec, not of any implementation.
6. **The VM is a scheduler over an extensible resource vector**, and its
   run-time policy depends only on classical data. Base resource:
   qubit-time by qubit class. Targets declare further resources. Garbage is
   a schedulable resource with an occupancy cost. Compile-time scheduling
   and run-time scheduling are the same optimiser, implemented once as a
   component (`bennett-sched`, §6.1) that both the plugin and the VM link.
7. **Correctness is defined by a theorem and two oracles, not by a
   reversibility check** (§5.1).
8. **QIR, OpenQASM 3, and MLIR quantum dialects are edge formats**, read
   and written at the boundary. Never the semantics. The landscape and what
   is genuinely new are in §7.
9. **Languages: the right tool for the job, taste excluded** (§6).
10. **Many small repositories, published contracts, no monolith** (§6.1).

## 2. The architecture, in one picture

```
  Front ends     clang (C/C++)   rustc   Julia (Bennett.jl)   QIR / MLIR-dialect importers
                     └──────────────┴────────┴───────────────────────┘
                         emit LLVM bitcode + __bennett_* marker calls (the dialect, §3)
                                              │
  Link time      bennett-driver: whole-program bitcode (LTO) ─► LLVM's own optimiser (unmodified)
                                              │
                 bennett-plugin (C++, the only LLVM-linked component):
                   taint over the resolved call graph → region outlining → controlled/adjoint
                   body generation → lowering to the virtual ISA → bennett-sched (cost, schedule)
                                              │
  Objects        fat object: native host code + ISA object(s) + cost certificate (ISA spec, §4.4)
                                              │
  Executors       ┌───────────────────────────┴───────────────────────────┐
                  ▼                                                       ▼
        bennett-vm (device runtime)                         bennett-circuits (bounded specialiser)
        reversible + coherent tiers, history layers,        hierarchical circuit IR, placement,
        effect tape, branch-enumeration simulation          proof-carrying output, exporters
                  └───────────────────────────┬───────────────────────────┘
                                              ▼
  Backends     Sturm.jl (Perm/MCX)   OpenQASM 3   QIR   bennett-estimate   hardware via bennett-targets
```

One semantics: the ISA spec's formal model and conformance suite. Two
executors, in separate repositories, each conformant to that spec, and
permanently differentially tested against each other and against native
execution of the same bitcode.

## 3. The dialect: what an out-of-tree plugin can rely on

Round 1 of the council was right that the previous version of this section
claimed guarantees LLVM does not give out of tree. This version lists only
mechanisms that exist for a plugin today, states what each does and does
not guarantee, and names the legality spike that gates freezing the spec.

### 3.1 Mechanisms

| Need | Mechanism (out-of-tree, stock LLVM) | What it does NOT give, and what covers the gap |
|---|---|---|
| Quantum operations: allocate (clean / dirty / class), release, gate, rotate(θ), measure | **Declared marker functions** `__bennett_*` with fixed signatures, exactly as Enzyme's `__enzyme_autodiff`. They are ordinary external calls with side effects, not `llvm.*` intrinsics (a plugin cannot register intrinsics). The plugin recognises them by name and signature and adds call-site attributes at `PipelineStartEP`. | Stock passes may inline, unroll, or clone a call (its *dynamic* sequence on every path is preserved; its static count is not). They will not speculate, hoist across other side effects, CSE, or delete a non-`readnone`, non-`speculatable` call. That is the legality the dialect relies on; it is a property of ordinary side-effecting calls, not of any attribute we invent. |
| Qubit handles | **Reference semantics at the dialect level**: a handle is an opaque pointer in a dedicated address space (clang can emit `__attribute__((address_space(N)))`; rustc and Julia can emit the same pointer type from their LLVM bindings). The handle names a VM-managed qubit; gates are side-effecting calls on handles. | LLVM cannot enforce linearity; SSA uses are free to duplicate. Linearity is **not** a type-system property at this level: it is a fail-loud verifier obligation after outlining, plus the ISA's value semantics below. This is the point on which QIR is faulted in §7, and the answer is to be explicit about it, not to pretend LLVM can do better. |
| Qubit values in the ISA | **Linear value semantics in the virtual ISA** (wire form, as in Quake's wire dialect and QSSA): each use consumes, each definition produces. The plugin converts handles to wires after outlining and verifies the conversion. | The ISA, not LLVM IR, is where the quantum dataflow is explicit and optimisable. Both forms exist, at named pipeline stages, for the same reason CUDA-Q keeps both. |
| Quantum memory | Loads and stores through handle pointers in the quantum address space; the plugin lowers them to ISA quantum-addressed memory operations. | A new address space needs no DataLayout cooperation if handles are pointer-sized and never dereferenced by host code; the plugin owns their meaning. Honest cost: a quantum-addressed access is O(N) in gates (QROM / QRAM circuits) unless the target provides QRAM hardware (§4.3). |
| Taint: classical vs reversible vs coherent | **Analysis, not types**: a forward dataflow over the whole-program call graph from marker results and from control regions. | No per-value attribute survives optimisation and none is needed; taint is recomputed at link time over the resolved call graph. "Untainted" is defined relative to that graph, never per translation unit. |
| Control as structure: adjoint, controlled-by-qubit, compute-with-uncompute | **Function granularity**: a region is outlined to a function (LLVM's `CodeExtractor`) and entered through a marker call `__bennett_ctrl(q, @f, args…)` / `__bennett_adj(@f, …)` / `__bennett_compute(@f, …)`. The plugin generates controlled and adjoint bodies on demand from one source body. | Front ends that want `when`-style syntax do the outlining themselves (Julia macro, clang attribute plugin, Rust proc-macro) and emit the marker call; the dialect does not require it. Generating a body needs the callee's IR, which is why the plugin runs at link time (§3.3). |
| Bounds for data-dependent iteration and recursion | **Real operands of marker calls**: `__bennett_bound(i64 n)` returns a token consumed by the loop's or call's guard, so the bound is a value in the dataflow, never metadata (metadata is droppable). Scalar evolution supplies static bounds where they exist; the host supplies run-time bounds before entering a coherent region. | A missing bound on a coherent loop is a compile error naming the loop. |
| Garbage and uncomputation | **Liveness analysis** on the outlined region plus the compute/uncompute marker; no lifetime intrinsics (they apply only to allocas). | The scheduler (`bennett-sched`) decides when to pay to free a dead value; the dialect only has to make deadness computable. |
| Measurement and classical feedback | Marker call returning `i1`, flowing into ordinary `br` / `select` / `phi`. | Branching on a measurement result is classical control (§4.2). |
| Effects | Marker calls on the device side for the effects the device models (console, clock, entropy, block device); everything else is a host call. | Effect semantics per tier are in §4.2; an effect the device does not model inside a coherent region is a compile-time refusal with a name. |

### 3.2 Pipeline placement and the cost of staying in-tree

- **Correctness is invariant under LLVM's optimiser; cost is not.** Any
  semantics-preserving optimisation of the classical part is lowered as
  it stands, so differential testing (§5.1) is against the native binary
  built from the *same* optimised bitcode. But optimisations that erase or
  duplicate intermediate values change gate counts, so tainted regions get
  a curated region pipeline after outlining. This is the pinned-target-
  machine lesson from v1, made structural.
- **Regions are functions.** Every `when`, adjoint and compute block
  outlines first. Enzyme lives with this.
- **Per-LLVM-major builds** of the plugin, as Enzyme is built: clang,
  rustc and Julia pin different LLVM majors.
- **The legality spike** (§8.1) is a conformance test, not a design
  question: a corpus of marker-bearing bitcode run through every stock
  pass at O3 must preserve the dynamic sequence of marker calls on every
  path. Freezing `bennett-dialect-spec` is gated on it passing.

### 3.3 Compilation model: link time, whole program, fat objects

Taint and controlled bodies depend on the calling context across the whole
program: a function in one translation unit may be called under a qubit
from another, and generating its controlled body needs its IR. So:

- Front ends emit **bitcode** (clang `-flto`, rustc `-Clinker-plugin-lto`
  or `--emit=llvm-bc`, Julia through LLVM.jl). This is the one universal
  thing every LLVM front end can do without modification. No front end has
  to load our plugin.
- **`bennett-driver`** merges the bitcode, runs LLVM's optimiser, loads the
  plugin at the LTO pipeline extension point (or runs it through `opt`),
  resolves taint over the whole call graph, and produces a **fat object**:
  native host code for the classical tier, ISA object(s) for the device
  tiers, and a cost certificate. clang's offload model (outlining, fat
  binaries, a launch runtime) is the **model**, not a reused mechanism: a
  middle-end pass cannot conjure clang's driver machinery, so we own ours.
- **Host-triple IR is what the device lowering accepts**: datalayout,
  ABI-lowered calls, target intrinsics and inline asm arrive as the host
  front end produced them. Target intrinsics and asm are classified
  *lowered / trapped / shimmed*, per the coverage report. There is no
  `bennett` triple, because a plugin cannot add a clang target and we do
  not fork.
- **Per-front-end integration is named work, not "unmodified"**: clang
  needs only the `-flto` flags; rustc's in-process plugin path is nightly-
  only, so Rust goes through bitcode emission and the driver; Julia goes
  through LLVM.jl's pipeline and the same driver in-process. Bennett.jl
  is the Julia integration.
- A per-TU plugin invocation remains available as a **fast path** for
  programs that are closed within one unit (the REPL case), with the same
  semantics.

## 4. The virtual ISA and the device

### 4.1 Why the VM is the revolution

The circuit model is to quantum programming what bare-metal machine code
was to classical programming before virtual machines, virtual memory, and
portable ISAs: every program welded to one machine, every vendor with its
own toolchain, no dynamic allocation, no loops beyond what you unrolled by
hand, no portability, and no way for a software vendor to ship one
artefact to many machines. The classical world escaped through abstraction
layers that sat *between* program and hardware: virtual memory, the
process, the JVM, LLVM, PTX. Quantum programming has not had its layer.
The mistakes of the pre-VM era are listed so the design never repeats
them:

- **No program is written against a machine.** Programs target the virtual
  ISA; hardware implements the ISA through a target description. A program
  compiled today runs on a machine built in ten years.
- **Memory is virtual.** Qubits are allocated and released through the VM,
  never addressed physically by the program. Clean, dirty, and class are
  properties of an allocation request, not of a wire index.
- **Loops and recursion are instructions, not unrolling.** Bounds are
  values the VM enforces.
- **Resource accounting is part of the architecture**, in the ISA spec.
- **The spec is public and versioned**, so an ecosystem can form around it
  without anyone's permission. **Governance:** PTX and the JVM each had a
  controlling steward and a conformance regime; this ISA has a published
  spec, a conformance suite, and a steward who accepts target descriptions
  and spec revisions through a recorded process. A vendor implements it
  before an ecosystem exists for the same reason vendors implemented PTX:
  the programs are written against it, not against them.

### 4.2 Execution semantics by tier (the part round 1 found missing)

Two control disciplines, kept apart by name in the ISA:

- **Classical control** (host data, measurement results, run-time bounds):
  genuinely dynamic, an instruction pointer, data-dependent trip counts,
  real allocation. This is where the VM's run-time scheduling, history
  layers, checkpointing, and pebbling policy live, and **every such
  decision may inspect only classical data**. This is an architectural
  invariant, not a policy.
- **Coherent control** (a decision that depends on a qubit): **predicated
  execution padded to a bound**, in both executors. A branch on a qubit
  executes both arms, each under its predicate, and pays for both. A loop
  whose continuation depends on a qubit runs to its bound with the body
  predicated. An allocation whose size depends on a qubit is padded to its
  bound. The bound is classical and is fixed before the region is entered;
  run-time bounds come from the host or from measurement results, never
  from superposed data. **Nothing about the VM makes superposed trip
  counts observable or cheap; what it makes possible is choosing the bound
  at run time from classical data instead of at compile time.** Whether
  anything better exists for particular algorithms (variable-time
  amplitude amplification, for one) is an algorithm-level question; the
  ISA states the padded semantics and nothing stronger.

Effects by tier:

| Tier | Where | Effects | Nondeterminism |
|---|---|---|---|
| classical | host, native | real | real |
| reversible | device | recorded on the effect tape forwards, replayed backwards; the device models console, clock, entropy, block storage as reversible device models | concretised and recorded, so reversal replays the same choice |
| coherent | device | **closed and effect-free**: no external effect may occur inside a coherent region. Devices the program touches are virtualised as reversible state inside the device (an in-memory VFS, a console register, a device model) and become part of the oracle's state. Classical inputs are fixed before entry; outputs leave through measurement after exit. An effect the device cannot virtualise is a compile-time refusal naming the call site. | none: undefined values are concretised at entry and are part of the fixed classical input |

What the VM physically *is* at run time: a classical runtime that
schedules quantum operations. Coherent regions are lowered to bounded
predicated blocks; the classical runtime decides when to run them, with
what resources, and how to uncompute their garbage, using only classical
information. On a simulator target the same VM executes a coherent region
by **branch enumeration**: a permutation oracle applied to a state vector
is a permutation of amplitudes, so the region is run once per basis state
of the superposed inputs, which is exactly what makes small-instance
end-to-end demos (§7) checkable.

### 4.3 Resources

- **The resource vector.** Qubit-time by qubit class is the base. Qubit
  classes are register classes: a target declares tiers with costs, and
  allocation chooses a class the way a register allocator does. Garbage
  carries an occupancy cost per qubit-second. Targets may add energy,
  routing, T, Clifford, measurement, or anything else; the ISA does not
  enumerate resources, the target description does. **Decision rule:** a
  target description supplies either a scalarisation (weights) or a
  lexicographic order over its resources; the scheduler optimises that
  objective and reports every component; conformance tests check the
  accounting of each declared resource against the target's own units.
- **Honest costs of superposition**, stated once so nobody is surprised: a
  coherent branch pays for both arms; a quantum-addressed memory access
  costs O(N) gates through QROM/QRAM circuits unless the target provides
  QRAM; coherent allocation is padded to its bound; dirty ancillae are
  cheaper to borrow and more expensive to use.
- **Allocation classes:** clean |0⟩ allocation, **dirty borrowing** (a
  first-class resource with no analogue in the current code or in
  Sturm.jl), and release, with clean release and restored correlations as
  **semantic obligations** the verifier checks, not scheduler preferences.

### 4.4 What the ISA spec owns

The ISA spec is one of the two contracts (§6.1). It therefore owns, by
name, every format two repositories exchange across the device boundary:

- the instruction set and its formal model (abstract semantics and the
  round-trip theorem);
- the resource vector and the **target-description format**;
- the **object format** for ISA programs and the **link format** for
  separate compilation, with a call/uncall convention and shared ancilla
  frames (the reversible ABI);
- the **host–device launch ABI**: how a host program starts, suspends,
  reverses, and reads back a device program;
- the **cost-certificate schema** that `bennett-circuits`,
  `bennett-arith`, `bennett-estimate` and `Bennett.jl` all consume;
- the serialisation and versioning rules, and the conformance suite.

### 4.5 An illustrative sketch (non-normative)

So a hardware vendor and a language designer can each see their surface.
Instruction classes, not encodings:

```
  qalloc   class=<name> n=<classical>            → wires        ; clean
  qborrow  class=<name> n=<classical>            → wires        ; dirty
  qfree    wires                                                 ; verifier: clean
  gate     op=<X|CX|CCX|MCX|RZ(θ)|…> wires       → wires        ; linear: consumes, produces
  qload    addr=<wires> mem=<region>             → wires        ; O(N) unless target QRAM
  qstore   addr=<wires> val=<wires> mem=<region>
  pred     p=<wire> { … }                                        ; coherent control: both arms, padded
  loop     bound=<classical> { … }                               ; coherent loop: padded to bound
  measure  wires                                 → classical bits
  br / call / ret / alloc / load / store                         ; classical control, host data only
  effect   dev=<model> …                                         ; reversible tier only; taped
  bound    <classical>                           → token         ; feeds pred/loop/call guards
```

A target description names its qubit classes with costs, its native gate
alphabet, whether it provides QRAM, and its resource scalarisation:

```
  target: surface-code-d17-example
  classes: { logical: {qubit_second: 1.0}, dirty_pool: {qubit_second: 0.3} }
  gates:   { CX: {t: 0}, CCX: {t: 7, depth: 3}, RZ: {t: "synth(ε)"} , measure: {time: 1} }
  qram:    none
  objective: weighted { t: 1.0, qubit_second: 0.05 }
```

## 5. Scenes from the finished thing, and what "correct" means

**The REPL.** Define a Julia function. Do not compile it. Write
`when(q) do f(x) end` and it runs, in a simulator or on hardware, because
compilation is invisible, incremental, cached by world age, composable.
Quantum registers are REPL values with lexical lifetime. `@cost f(x)`
prints T-count, T-depth, logical qubits, and wall time on a named target,
the way `@time` prints allocations. Redefine `f` and everything downstream
recompiles. Hand a compiled function to another function as an ordinary
callee. The Lisp image, holding reversible objects with cost certificates.

**The toolchain.** `-flto` plus our driver beside clang. Point it at a
mature codebase: one fat object per link, a coverage report honest to the
instruction (lowered / trapped / shimmed), and a resource estimate. Partial
compilation is a region marker, and the toolchain is provably the identity
on everything outside the tainted call graph. The kernel compiles, boots on
the VM in the reversible tier with its devices modelled, writes a serial
console to the tape, and un-boots to the reset vector.

**The device.** The quantum VM of §4, as a device runtime the way a GPU
runtime is: host code at native speed, only device tiers pay for
reversibility.

**The compiler is optimal within what it claims.** Optimality is defined
against a target description and a declared search space. Optimal
reversible pebbling is PSPACE-complete, so: small kernels are exactly
synthesised and provably minimal for their gate set and objective; large
programs carry closed-form cost bounds and a certificate of the gap
between the schedule found and the best bound known. The compiler chooses
adders, pebbling, measurement-based versus unitary uncomputation, QROM
versus QRAM, under a space budget, and emits a proof-carrying artefact.

**The ecosystem.** A registry of reversible libraries with cost
certificates: libc, libm, zlib, crypto, SQLite, published as linkable ISA
objects so nobody compiles them twice. Arithmetic is library code too
(§6).

### 5.1 Correctness

Ancilla-zero is not correctness: every historical S0 defect in this
project passed a reversibility check. Correctness is defined in three
parts.

1. **Permutation tier, by theorem.** A circuit over {X, CX, CCX, MCX} is a
   permutation matrix. A permutation is determined by its action on basis
   states. So if the artefact agrees with native execution of the same
   bitcode on every basis input *and* returns every ancilla to |0⟩ on every
   basis input, then its unitary is exactly |x⟩|t⟩|0⟩ ↦ |x⟩|t⊕f(x)⟩|0⟩: no
   relative phase is possible and no garbage entanglement is possible. For
   this tier, basis-state differential testing against native execution,
   exhaustive at small widths and property-based above, is **complete**,
   not merely evidence.
2. **Non-permutation lowerings, by simulation.** Measurement-based
   uncomputation (a CZ fixup conditioned on a measurement), rotations, and
   any synthesised non-permutation gate can introduce phases that basis
   tests cannot see. Every such lowering is verified by **unitary
   equivalence at exhaustive small widths** on a state-vector simulator
   and by **controlled-interference tests** (run the artefact controlled
   and inside an interferometer against the reference), with the
   approximation budget ε of any rotation synthesis stated in the
   certificate.
3. **Algorithms, compositionally.** Grover, amplitude estimation and
   friends are verified by state-vector simulation at small instance size
   with the compiled oracle applied by branch enumeration (§4.2), and
   their resource estimates are produced from the oracle's certificate
   without materialising gates.

**What a proof-carrying artefact asserts:** the ISA object, the target, the
objective, the claimed resource vector, the tier of each region, the
verification performed (1, 2, or 3 above, with instance sizes and seeds),
and for small kernels an exact-synthesis witness. A checker in
`bennett-conformance` validates the certificate against the object without
trusting the compiler.

## 6. The right language for each job

| Component | Language | Why (taste excluded) |
|---|---|---|
| Pass plugin (taint, outlining, body generation, lowering to the ISA) | **C++** | The only component that links LLVM. `llvmGetPassPluginInfo` has C linkage, but registering a new-PM pass and every analysis the plugin needs (loop info, dominators, scalar evolution for bounds, alias analysis, MemorySSA, `CodeExtractor`) are C++ API only. v1 is the evidence of avoiding this: it reimplements loop analysis in `src/lowering/cfg.jl` and parses MemorySSA out of printed text in `src/memssa.jl`. Enzyme is C++ for the same reason. Built per LLVM major. Kept narrow: it does not contain the scheduler. |
| Scheduler and cost model (`bennett-sched`) | **Rust**, C ABI | Linked by both the plugin (compile time) and the VM (run time); it is what makes decision 6 literally true. No LLVM dependency. |
| ISA spec tooling, VM / device runtime, circuit specialiser, estimator, driver | **Rust** | None touch LLVM: they consume the ISA's serialised form. Embeddable device library with no runtime; memory safety in a component that must never crash a host; usable without std near kernels; a JIT tier available without LLVM. Rust ownership is affine, not linear, so it models qubit ownership well with a leak check, not natively. |
| Front door, REPL, Sturm bridge, research laboratory | **Julia (Bennett.jl)** | The REPL experience is the product's face; LLVM.jl runs the driver in-process; new lowerings and arithmetic are prototyped here against the spec. |
| Arithmetic and runtime libraries (adders, multipliers, QROM, soft-float, allocator shims, libc) | **Any** | Ordinary code compiled through the same pipeline and shipped as ISA objects with cost certificates. "Runtimes are libraries" applies to arithmetic too; the specialiser links them. |

Consequence: the centre of gravity leaves Julia. Bennett.jl is the front
door of Bennett, not the whole of it. The maintainer has stated this is
acceptable; the north star outranks language preference.

### 6.1 Many small repositories, two contracts, fully enumerated

**A monolith will grind to a halt** (maintainer, 2026-10-28). Independent
repositories, each developable, versioned, tested, and released on its
own, communicating only through **two published contracts**:

- **`bennett-dialect-spec`**: the marker-function ABI (names, signatures,
  call-site attributes), the handle address space, the outlining and
  bound conventions, the legality conformance corpus, versioning.
- **`bennett-isa-spec`**: everything in §4.4: instruction set and formal
  model, resource vector and target-description format, object and link
  format with the reversible ABI, host–device launch ABI, cost-certificate
  schema, serialisation, conformance suite.

Nothing shares code across a contract boundary; anything that needs to is
a sign the boundary is wrong. The previous iteration's "one codebase holds
both executors" is withdrawn: **one semantics comes from the ISA spec's
formal model and conformance suite, never from shared code.**

| Repository | Owns | Depends on |
|---|---|---|
| `bennett-dialect-spec` | as above | nothing |
| `bennett-isa-spec` | as above | nothing |
| `bennett-sched` | scheduler and cost model, C ABI, used at compile time and run time | ISA spec |
| `bennett-plugin` | the C++ LLVM pass plugin; built per LLVM major | dialect spec, ISA spec, sched (binary) |
| `bennett-driver` | link-time driver: bitcode merge, plugin invocation, fat objects, launch, coverage reports; per-front-end integration notes | dialect spec, ISA spec, plugin (binary) |
| `bennett-vm` | the Rust device runtime: classical-control tier, history layers, effect tape, device models, branch-enumeration simulation, JIT tier | ISA spec, sched |
| `bennett-circuits` | the bounded specialiser: hierarchical circuit IR, placement, proof-carrying output, exporters (OpenQASM 3, QIR, Sturm `Perm`) | ISA spec, sched |
| `bennett-estimate` | resource estimation from ISA objects, certificates and target descriptions, no gates materialised | ISA spec |
| `bennett-targets` | target descriptions per hardware model, contributed by vendors; importers for existing resource-model formats | ISA spec |
| `bennett-runtimes` | allocator, libc/musl shims, device models, Julia shim runtime, as ordinary code compiled to ISA objects | dialect spec; driver (build tool) |
| `bennett-arith` | adders, multipliers, QROM, soft-float, as ISA library objects with cost certificates | dialect spec; driver (build tool) |
| `Bennett.jl` | Julia front door, REPL, `@cost`, Sturm bridge, research lab | driver (binary), ISA spec |
| `bennett-conformance` | the demo ladder as executable gates, the certificate checker, differential harness against native | everything, as a consumer only |

The test of the split: every repository can be replaced by a competitor's
implementation of the same spec without the rest noticing.

## 7. Landscape: what is taken, what is rejected, what is new

| System | What Bennett takes | What it does differently |
|---|---|---|
| **Enzyme** | The whole delivery model: an LLVM plugin, marker calls, optimise–transform–optimise, LTO for cross-TU bodies, per-LLVM-major builds. | Reversibilisation instead of differentiation; the output is a program for a second executor, not more LLVM IR. |
| **PTX / CUDA, OpenMP offload** | Virtual ISA with per-hardware target descriptions; host/device split; fat objects; a launch runtime. | We own the driver and launch runtime; nothing is reused from clang's offload machinery. |
| **QIR** (QIR Alliance) | LLVM as the carrier; the idea of profiles (as a warning). Its adaptive profile and memory-management spec exist and are read on import. | The defensible criticism, stated precisely: qubits are opaque pointers with no ownership discipline (they do participate in SSA dataflow); adjoint and controlled bodies are emitted by the front end as separate functions, so the IR carries no structural algebra over them; there is no uncomputation, no garbage, no resource model, and no oracle abstraction; the profiles mix "program the host runs" with "circuit the device executes". Bennett keeps control and adjoint structural, keeps ownership explicit in the ISA, and puts resources in the spec. |
| **OpenQASM 3** | `ctrl@` / `inv@` modifiers and its dynamic classical control as the export target's expectations. | OpenQASM 3's dynamic control is classical control (§4.2); it is a circuit language, not a program model with memory, linking, or resources. Export only. |
| **CUDA-Q / Quake** | Quantum kernels as device code; `cudaq::control` / `cudaq::adjoint` at function granularity; the ref-vs-wire distinction, which Bennett adopts as dialect-vs-ISA. | Not a new language or kernel annotation: taint is inferred over unmodified C, Rust, Julia. Not MLIR-centred: the carrier is LLVM bitcode, because that is what every front end emits. |
| **Catalyst, MLIR quantum dialects** | Import path for programs already in those dialects; precedent for a JIT tier. | See above; Catalyst compiles a Python-hosted language, not arbitrary LLVM programs. |
| **Q#** | Adj+Ctl specialisation from one body. | Specialisation happens in the plugin over any language's IR, not in one language's compiler. |
| **Quipper** | Oracle synthesis from classical code; `with_computed`. | Any LLVM language, not Haskell-embedded; a VM and ISA beneath, not circuits only. |
| **Silq, Unqomp, Reqomp, SQUARE** | Automatic and budgeted uncomputation; the idea that garbage is a resource with a budget. | Uncomputation is scheduled at run time by the VM as well as at compile time, under a target's resource vector. |
| **Tower** | Superposed pointers and classically bounded recursion as the right semantics for coherent data structures. | The same semantics, for programs nobody rewrote. |
| **Qualtran, Azure RE** | Symbolic, hierarchical resource counting without materialised gates; target models as data. | Certificates attached to linkable objects; the target-description format accepts imported models. |
| **QSSA, QIRO** | Linear SSA for quantum values. | Used in the ISA, not imposed on LLVM IR. |
| **ReVerC** | Verified reversible compilation of a small language. | Correctness by theorem plus oracle (§5.1) for arbitrary LLVM input. |
| **Reversible pebbling (Bennett 89, Knill 95, PRS15, Chan et al.)** | The space-time trade-off theory and its hardness result. | Pebbling as run-time policy over a resource vector, not only a compile-time choice. |

**What is new**, claimed narrowly: (a) inferred-taint reversibilisation of
unmodified programs in any LLVM language, delivered as a link-time plugin;
(b) a public virtual ISA for quantum programs with virtual qubits,
allocation classes, bounded coherent control, garbage as a scheduled
resource, a resource vector, and a host–device ABI; (c) one scheduler used
at compile time and run time; (d) correctness defined by the permutation
theorem plus simulation oracles, attached to linkable objects as
certificates. Everything else in this document is adopted from the systems
above with attribution.

## 8. Demo ladder (success criteria, each with its acceptance test)

| Rung | Demo | Acceptance test |
|---|---|---|
| 1 | Scalar C, Rust, Julia functions | Exhaustive at Int8, both executors agree with native execution (§5.1 part 1). |
| 2 | Pointers, structs, byte memory | A C hashtable (the existing 258-line corpus) reversed byte-exactly, both executors. |
| 3 | musl hello-world | Linked, run in the reversible tier with a console device model, un-run to the reset state; tape replay deterministic. |
| 4 | **Grover over SQLite** | SQLite compiled unmodified to the coherent tier with an in-memory VFS over quantum-addressed memory. Database of N rows fixed classically before entry; the predicate is a real SQL query; the oracle bit is the query's match. (a) Oracle verified by §5.1 part 1 against native SQLite over all rows for N ≤ 2¹⁰. (b) End-to-end Grover by state-vector simulation with branch enumeration at N ≤ 2⁸. (c) A resource estimate for N = 2²⁰ under a named target description. Nobody rewrote SQLite. |
| 5 | Julia on a shim runtime | `push!` and `Dict` work because the allocator works, with zero compiler awareness of either; differential against native Julia. |
| 6 | xv6, then Linux `tinyconfig` | Boots in the reversible tier with device models, serial console on the tape, un-boots to the reset vector; tape replay byte-identical. |
| 7 | **Quantum fuzzing of the kernel** | Kernel state snapshot fixed classically after boot; a bounded number of steps; syscall arguments as the superposed input over a declared small space; devices virtualised; the oracle bit is the panic flag. (a) Oracle verified by §5.1 part 1 against native execution of the same snapshot per basis input. (b) Amplitude amplification by state-vector simulation at a toy argument space. (c) A resource estimate under a named target. The oracle is Linux. |
| 8 | **Amplitude estimation on a Monte Carlo in plain C** | Written by someone who has never heard of a Toffoli gate; entropy fixed classically before entry (the sampler's randomness becomes the superposed input); (a) oracle by §5.1 part 1; (b) estimation by simulation at small precision; (c) resource estimate. |

Rungs 1–3 and 5–6 are the blueprint's; 4, 7, 8 define success for the
vision; nobody promises 6–8 on a schedule.

## 9. Open technical questions (deferred by the maintainer's rule: vision first)

In the order the next iteration should take them. The first three were
promoted from "detail" to "load-bearing" by council round 1 and are now
answered at vision level above; they remain here because their designs are
not written.

1. **The legality spike** (§3.2): the marker corpus against every stock
   pass at O3; gate on freezing the dialect spec.
2. **Qubit handle → wire conversion**: the verifier, what it rejects, how
   the ISA's linear form is checked (Rust affinity means a leak check).
3. **Compilation model mechanics** (§3.3): LTO extension point vs `opt`
   invocation; fat-object layout; the launch ABI; host-triple intrinsic and
   asm classification tables.
4. **Bound certificates**: produced by scalar evolution, the user, or the
   host at run time; what each executor checks vs trusts; bound-exhaustion
   semantics inside a coherent region (a predicate that is false forever is
   the only legal outcome).
5. **Effect virtualisation**: which device models exist (VFS, console,
   clock, entropy, block device, network as a recorded peer), how they are
   expressed as reversible state, what is refused.
6. **Measurement-based uncomputation under control**: Sturm.jl's
   `PermClean` certificate cannot express it; the certificate kind with
   classical fixup, agreed with Sturm before any gate record freezes.
7. **Reversible ABI and linking**: call/uncall convention, shared ancilla
   frames, structural symbol resolution, content-addressed objects.
8. **Run-time scheduling policy**: history layers, checkpoint interval,
   delta quality, as resource policy under the vector of §4.3; the
   `bennett-sched` interface.
9. **ISA serialisation and versioning**; conformance suite; the formal
   model's scope.
10. **Per-LLVM-major builds**; Julia in-process invocation through LLVM.jl.
11. Floating point (soft-float as a library), concurrency (sequentialised
    with a recorded schedule), self-modifying code, signals, setjmp.
12. Repository hosting and release mechanics for §6.1.

## 10. Process

Vision first (this document), iterate with the council, then design, then
spikes, then code. The current Bennett.jl and BennettVM.jl are frozen as
the v1 reference and differential oracle. No reboot code is written on the
strength of this document. Worklog, beads, red-green, exhaustive
verification, no remote CI carry over unchanged.
