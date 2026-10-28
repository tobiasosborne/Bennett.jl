# Council

You are a member of a three-model council grading the document below, the founding vision for a from-scratch reboot of Bennett (a reversible / quantum compiler toolchain; see the document). Grade it against the rubric on the absolute scale. Be exacting and skeptical: verify every technical premise against your own knowledge; name any that is false. Grade the vision for being the right vision, stated precisely; do not deduct for things that are not built yet. A blocking issue is one that would make the project build the wrong thing if uncorrected; everything else is a suggestion. Return `accept` only if the blocking list is empty.

Be constructive, not only critical: for every blocking issue the `fix` field must say concretely how to overcome it, at vision level (the sentence or semantics the document should state, or the decision it should take), not merely that it is wrong. Where you see two viable ways out, name both and say which you would take. In `path_to_accept`, state the minimal set of changes that would make you return `accept`; if you already accept, say what would raise the lowest-scoring criterion by one point.

You may read the repository you are running in (read-only) to check claims about the current code; its root contains Bennett-NorthStar.md (the document, identical to the snapshot below), Bennett-Reboot-Blueprint.md and Bennett-V2-PRD.md (the superseded plans), worklog/ (session logs; chunk 121 has the 2026-10-28 ground-truth survey), reviews/2026-09-26-astra/ (the last review campaign), and src/ (the deprecated v1). Reading is optional; the snapshot below is what you grade.

Answer only with JSON matching the schema.

# Previous round (4)

Verdicts: codex: revise, muse: accept, opus: revise

Blocking issues raised last round:
- [codex] B_FREEZE_DETERMINISM (§§3.2, 4.2 and 5.1): The premise that LLVM freeze deterministically selects the reference machine's value is false. Freeze stabilises an arbitrary choice for its uses; it does not prescribe a canonical choice shared by independent lowerings. See the [LLVM freeze semantics](https://llvm.org/docs/LangRef.html#freeze-instruction). Locally, clang 18 compiled the same freeze i1 poison return to an undefined return register at -O0 and zero at -O3. Consequently, using the same freeze-normalised bitcode does not establish one deterministic F_B shared by native execution and both executors. Fix proposed: Prefer an explicit deterministic normalisation contract: undef/poison choices and encountered immediate UB are lowered to specified ordinary values or checked faults before subsequent optimisation, and the native comparison build uses that same defined normalisation. Freeze may assist stabilisation but is not the canonicalisation mechanism. Alternatively, retain deterministic choices only in Bennett's reference semantics and restrict native differential equivalence to executions whose results are independent of LLVM's unspecified choices; validate the remainder against the checked interpreter. State this distinction in certificates.
- [codex] B1_QUANTUM_STATE_WRITE_SEMANTICS (§§3.1, 4.2 and 5.1): The new copy/store/inverse paragraph resolves the individual operations, but the encompassing interface remains contradictory. Section 4.2 says every coherent region preserves inputs and is an XOR-result involution. A region containing RZ(theta) is generally not an involution, and an in-place increment changes its operand. These operations cannot satisfy the stated oracle mapping merely by cleaning workspace. Thus ctrl/adj/compute still lack an unambiguous contract for persistent quantum state. Fix proposed: Scope F_B, XOR accumulation, input preservation, and self-adjointness to lifted classical-oracle calls. Separately define quantum action regions as U on declared mutable wires, with borrowed inputs preserved and workspace restored; control means controlled-U and adjoint means U†. In-place bijections belong to this action interface. Define their admissible budget/fault policy separately rather than inheriting the oracle formula. Alternatively, restrict regions to classical oracles and narrow the claims about arbitrary quantum bodies and persistent in-place updates. I would retain the ambition and introduce the two explicit interfaces.
- [codex] B_INPLACE_BOUNDED_INVERSE (§3.1 coherent memory row and §4.2 coherent memory, budgets and totality): Compute–swap–uncompute requires a valid inverse on the values actually produced, including its bounded execution. If forward evaluation faults, its canonical zero payload cannot replace the original register; if inverse evaluation faults, it need not erase the old input. Simply preserving x on failure and XORing an error is not a general repair: a bounded NOT succeeding at x=0 and faulting at x=1 would map both (x,e)=(0,1) and (1,0) to (1,1). The current document supplies no reversible failure extension for this case. Fix proposed: For the minimal design, reserve in-place actions for mutually inverse total bijections on a specified finite encoding, with bounds sufficient for forward evaluation and inverse cleanup. Fallible computations use the out-of-place oracle interface; scope the no-compile-error budget promise accordingly. Library modular multiplication must state its coprimality condition and treatment of unused encodings. Alternatively, define a larger reversible interface retaining explicit status/history registers, its complete failure-state mapping, and its adjoint. I would choose the bounded total-bijection restriction first.
- [opus] B1_FREEZE_REFINEMENT_NOT_NATIVE (§3.2 Definedness (referenced by §0, §4.2, §5.1, rung 7)): The contract says undef/poison are 'refined deterministically by freeze… with the refinement stated in the spec', and that the native comparison binary, built from the same freeze-normalised bitcode, therefore 'includes the refinement'. That is false. LLVM's `freeze` yields an arbitrary but fixed value, and the backend lowers it to whatever bits the register or memory holds. Two examples: `shl` by ≥ width is masked on x86 but would be whatever the spec picks, and uninitialised struct padding read via memcmp/memcpy holds stale memory natively. So on any execution where a frozen poison/undef value reaches the output or fault, the reference interpreter and the native binary legitimately disagree. 'Equals native, or is flagged' (§5.1) then becomes ill-posed exactly where real C code (SQLite, Linux) routinely goes. The project would build a correctness oracle that its own native leg cannot satisfy. Fix proposed: Preferred (option A): state that normalisation *materialises* the refinement instead of freezing it. Before the reference and the native binary are both built, the normaliser rewrites the region's optimised bitcode into a poison- and undef-free form: strip poison-generating flags (nsw/nuw/exact/inbounds-poison and the like), make partial operations total with an explicit stated result (e.g. a shift by ≥ width yields 0 via select), zero-initialise allocas, heap and region-input padding, and replace any remaining `undef` operand by a stated constant. After this, the bitcode has one defined meaning, which native codegen and the ISA interpreter both implement; only immediate UB (traps, unreachable, faulting access, division by zero) remains, and it becomes a fault code. Option B: keep freeze as nondeterministic choice in the spec, have the reference interpreter track poison/undef provenance, and classify any execution where a frozen value influences payload or fault as *indeterminate*: excluded from native comparison, counted like the UBSan exclusions. The artefact must still pick one fixed refinement so that F_B stays deterministic. I would take A, because B leaves F_B under-specified across competing implementations and excludes a large, uninteresting slice of real executions.

## Editor's response (what changed, what was declined and why)

# Editor's response to round 4

Verdicts: muse **accept**, codex revise, opus revise. Mean 4.33 (4.04 →
4.33). All five round-3 blocking issues confirmed resolved by all three
members. Three new blocking issues, all genuine and all accepted; by the
maintainer's rule (a further round only when new blockers emerge) a round
5 follows.

## Accepted and changed

1. **`freeze` is not a deterministic refinement** (codex B_FREEZE,
   opus B1). The editor's round-3 fix was wrong on this premise: `freeze`
   stabilises an arbitrary value, and codegen lowers it to whatever the
   register holds (opus: `shl` by ≥ width is masked on x86; padding holds
   stale memory; codex: clang 18 gives an undefined register at -O0 and
   zero at -O3 for the same frozen poison). Both members' preferred option
   A is taken: §3.2 now specifies **materialised normalisation**: strip
   poison-generating flags, totalise partial operations with stated
   results via `select`, zero-initialise allocas/heap/padding/region
   inputs, replace remaining `undef` by stated constants; both the
   reference interpreter and the native comparison binary are built from
   the materialised bitcode, so it has one defined meaning; only immediate
   UB remains, as a fault code. The §4.2 tier table says "refined by the
   materialised normalisation" instead of "by `freeze`". The certificate
   records the LLVM version and pipeline, and "never of the compiler" is
   corrected to "never of Bennett's own lowering".
2. **Oracle vs quantum-action interface** (codex B1_QUANTUM_STATE_WRITE).
   The universal "XOR involution with inputs preserved" formula cannot
   describe a region containing RZ(θ) or an in-place increment. §4.2 now
   names **two region interfaces**: the *lifted classical oracle* (F_B,
   XOR accumulation, input preserved, self-adjoint, fault register) and
   the *quantum action* (a unitary U on declared mutable wires, borrowed
   inputs preserved, workspace restored; ctrl = controlled-U, adj = U†;
   no fault outcome of its own, fallible work delegated to lifted oracles
   whose fault registers it declares). They nest; the plugin classifies
   each region by contents and the verifier checks the declared
   interface. Exit synchronisation to a common halt counter is stated
   (muse's suggestion, the QCM condition).
3. **In-place updates need bounded inverses** (codex B_INPLACE). Codex's
   minimal design is taken: `__bennett_inplace` is admitted only for
   mutually inverse **total bijections on a declared finite encoding**
   with budgets sufficient for forward and inverse evaluation; fallible or
   budget-limited computations are never in-place and use the oracle
   interface; library modular multiplication states its coprimality
   condition and the treatment of unused encodings; g∘ginv = id is a
   checked obligation (part 1 at small widths or a library certificate),
   and a wrong inverse is caught because swap-then-uncompute leaves the
   scratch non-clean (opus's suggestion).

Also taken from suggestions: both halves of the Silq discipline (`qfree`
computation as well as preserved dependencies); MBU fixup computed for
the actual schedule (D becomes U D U† after an intervening U); the
`qstore` source-level clean-target restriction distinguished from the
oracle ABI; "unmodified" defined as no source edits with build flags and
shims allowed and recorded; the Grover fault-entanglement reason for a
zero fault rate; dirty-pool tractability lemma or evidence label;
"UBSan-instrumented" shorthand replaced by the §3.2 wording everywhere;
host-effect/handle interleaving split assigned to the launch ABI; ISA
sub-artefacts versioned independently; "only LLVM-linked component"
qualified to the compiler core; HUGR/Guppy/tket2 added to §7.

## Declined

- Codex's "add small normative examples" (a faulting oracle, a non-self-
  inverse action, a controlled in-place bijection): agreed in spirit but
  deferred to the dialect spec, where worked examples belong; the vision
  document already carries a non-normative ISA sketch and the council has
  not treated the absence of examples as blocking.


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


# The document (`Bennett-NorthStar.md`, round 5 snapshot)

# Bennett — North Star (reboot vision, iteration 5)

**Date:** 2026-10-28. **Status:** vision settled at the level of "what it
truly looks like"; technical design NOT started. Iteration 5 after council
rounds 1–4 (`docs/council/northstar-2026-10-28/round-*/report.md`; the
editor's responses are in `round-*/response.md`). Round 4: one accept, two
revise at mean 4.33/5, with every earlier blocker confirmed resolved and
three new ones (materialised normalisation instead of `freeze`; separate
oracle and quantum-action interfaces; in-place updates restricted to total
bijections), all folded in here. Nothing here is
implemented, and no code is to be written on the strength of this
document alone (maintainer process rule: vision, then design, then
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
both repos, the Astra reviews, BENCHMARKS.md, and the checkout of the now-
sunset Sturm.jl at `~/old/Projects/Sturm.jl`): worklog chunk 121, session
2026-10-28. The
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
under a qubit. "Unmodified" means **no source edits**; build-configuration
flags and runtime shims are allowed and are recorded in the certificate.

Stated precisely, because precision is what makes the slogan true rather
than a slogan: *every execution of any LLVM program that is defined under
the reference semantics of §3.2, effect-bounded, and within a classical
resource budget can be run coherently under a qubit; executions that the
reference machine can see are outside that domain produce a named fault
outcome that is part of the result (§4.2), never a silent wrong answer
and never a crash of the region.* Source-level undefined behaviour that
the optimiser has already erased is not detectable by anyone after the
fact; it is covered by an explicit definedness assumption recorded in the
certificate, not by a fault guarantee (§3.2).

The project is predicated on scalable logical quantum computation becoming
real: plenty of logical qubits and gates at usable gate times. Efficiency
is pursued hard; universality is never traded for it.

## 1. Decisions (settled 2026-10-28, refined after council rounds 1–2)

1. **Bennett is the LLVM of quantum.** Language designers introduce quantum
   constructs *as they please*, the way LLVM lets anyone design a classical
   language. We provide the target and the optimiser, never the language.
2. **The IR is LLVM IR. We never fork LLVM.** Forking is the disaster
   scenario. Decades of classical optimisation are kept by sitting inside
   the ecosystem through mechanisms an out-of-tree plugin can actually rely
   on (§3). Where an upstream change would help, it is proposed upstream
   as a patch, never carried as a fork.
3. **Delivery is a pass plugin, a driver, and a runtime.** The plugin runs
   at **link time over whole-program bitcode** (§3.3): optimise, reverse,
   optimise. Any front end that can emit bitcode is supported; per-front-
   end integration is a driver concern, named per front end with its
   costs, never a language change.
4. **Three execution tiers, one program.** Classical (host, native code,
   never ours), reversible (device, deterministic forwards and backwards,
   effects on a tape), coherent (device, closed and effect-free, every
   control decision predicated, every region total with a fault output,
   §4.2). The quantum VM is the device, in the sense a GPU is a device.
5. **One virtual ISA, one target description per hardware.** The PTX move.
   The ISA is a versioned public specification with a conformance suite;
   the formal model is of the spec, not of any implementation.
6. **The VM is a scheduler over an extensible resource vector**, and its
   run-time policy depends only on classical data. Compile-time and run-
   time scheduling are the same optimiser, implemented once
   (`bennett-sched`) behind an interface the ISA spec owns (§4.4).
7. **Correctness is defined by a theorem, two oracles, and a fault
   outcome, never by a reversibility check** (§5.1). Certificates say
   which parts are proof and which are evidence.
8. **QIR, OpenQASM 3, Quil, and MLIR quantum dialects are edge formats**,
   read and written at the boundary. Never the semantics (§7).
9. **Languages: the right tool for the job, taste excluded** (§6).
10. **Many small repositories, published contracts, no monolith** (§6.1).

## 2. The architecture, in one picture

```
  Front ends     clang (C/C++)   rustc   Julia (Bennett.jl)   QIR / Quil / MLIR-dialect importers
                     └──────────────┴────────┴───────────────────────┘
                         emit LLVM bitcode + __bennett_* marker calls (the dialect, §3)
                                              │
  Link time      bennett-driver: whole-program bitcode (LTO) ─► LLVM's own optimiser (unmodified)
                                              │
                 bennett-plugin (C++, the only LLVM-linked component):
                   taint over the resolved call graph → region outlining → controlled/adjoint
                   body generation → lowering to the virtual ISA → bennett-sched (cost, schedule)
                                              │
  Objects        fat object: native host code + ISA object(s) + certificate (ISA spec, §4.4)
                                              │
  Executors       ┌───────────────────────────┴───────────────────────────┐
                  ▼                                                       ▼
        bennett-vm (device runtime)                         bennett-circuits (bounded specialiser)
        reversible + coherent tiers, history layers,        hierarchical circuit IR, placement,
        effect tape, branch-enumeration simulation,         proof-carrying output, exporters
        launch-time lowering to the target alphabet
                  └───────────────────────────┬───────────────────────────┘
                                              ▼
  Backends     Bennett.jl simulators   OpenQASM 3   QIR   Quil   bennett-estimate   hardware via bennett-targets
```

One semantics: the ISA spec's formal model and conformance suite. Two
executors, in separate repositories, each conformant to that spec, and
permanently differentially tested against each other and against native
execution of the same bitcode.

## 3. The dialect: what an out-of-tree plugin can rely on

This section lists only mechanisms that exist for a plugin today, states
what each does and does not guarantee, and names the legality spike that
gates freezing the spec.

### 3.1 Mechanisms

| Need | Mechanism (out-of-tree, stock LLVM) | What it does NOT give, and what covers the gap |
|---|---|---|
| Quantum operations: allocate (clean / dirty / class), release, gate, rotate(θ), measure, quantum-addressed load and store | **Declared external marker functions** `__bennett_*` with fixed signatures, exactly as Enzyme's `__enzyme_autodiff`. Not `llvm.*` intrinsics (a plugin cannot register them). The plugin recognises them by name and signature at link time. **Positive legality requirement:** a marker is declared as an external function that may read and write memory and may not return (no `readnone`, `readonly`, `speculatable`, `willreturn`, `nounwind`-only combinations that would license elimination, commoning or speculation). Stock passes then preserve the *dynamic sequence* of marker calls on every executed path. | Containing functions may be inlined, cloned, unrolled or versioned, so the *static* count of marker call sites is not preserved; the external declaration itself is never inlined. *Explicit quantum registers* are accessed only through markers, never through LLVM `load`/`store`, so no alias-analysis or forwarding pass can touch them. The ordinary loads and stores of lifted classical code (all of SQLite's) are not quantum-register accesses: they are lifted coherently according to the incoming memory model, as classical memory whose contents happen to be superposed. This legality is a property of ordinary effectful external calls, not of any attribute we invent; the legality corpus (§3.2) tests it. |
| Qubit handles | **Portable handles**: an ordinary `ptr` in address space 0 (or an integer handle) returned by `__bennett_qalloc`, which every front end can emit from unmodified source: clang, rustc, Julia. Never dereferenced by host code. The plugin normalises recognised handles into its internal representation after outlining, respecting the incoming target's pointer size. **Reference semantics at the dialect level.** | LLVM cannot enforce linearity; SSA uses are free to duplicate. Linearity is a fail-loud verifier obligation after outlining, plus the ISA's value semantics below. A handle that flows through memory or through an `inttoptr`/`ptrtoint` round trip before outlining is **rejected fail-loud** (not tracked) in v1 of the dialect; any handle use that survives into host native code is rejected likewise. Any code that touches handles or measurement results runs in the device's classical-control tier, never as host native code. This is the point on which QIR is faulted in §7, and the answer is to be explicit about it. |
| Qubit values in the ISA | **Linear value semantics in the virtual ISA** (wire form, as in Quake's wire dialect and QSSA): each use consumes, each definition produces. The plugin converts handles to wires after outlining and verifies the conversion. | Both forms exist, at named pipeline stages, for the same reason CUDA-Q keeps both. |
| Coherent memory and in-place update | **Copy-on-read, XOR-on-write, total-bijection-for-in-place** (§4.2): `__bennett_qload` is a CNOT copy of the register onto fresh wires (source preserved, copy is retained workspace until uncomputed under the validity invariant); `__bennett_qstore` XORs into its target, so a store into a known-clean register is a copy and a store into a register not known to be clean is a **compile-time error** (this source-level restriction is distinct from the oracle ABI, whose targets may hold any value); an in-place update x ← g(x) is written `__bennett_inplace(@g, @ginv, …)` and is admitted **only when g and ginv are mutually inverse total bijections on a declared finite encoding**, with budgets sufficient for forward evaluation and inverse cleanup, and is lowered compute-out-of-place, swap, uncompute-with-g⁻¹; library bijections (add a constant, xor, rotate, modular add, modular multiply with its coprimality condition and its treatment of unused encodings stated) carry their inverses and their g∘ginv = id certificates in `bennett-arith`. | A fallible or budget-limited computation cannot be in-place: it uses the out-of-place oracle interface (§4.2). A declared inverse is a correctness obligation: g∘ginv = id is checked by §5.1 part 1 at exhaustive small widths or carried as a library certificate, and a wrong inverse is caught because swap-then-uncompute leaves the scratch register non-clean. An in-place update with no inverse fails loud at compile time. Front ends may instead compose two compute regions and a swap themselves. This is what makes `when(q) do x += a end`, the founding use case of the Julia language (§6), work as written. |
| Taint: classical vs reversible vs coherent | **Analysis, not types**: a context-sensitive interprocedural analysis over data dependence, control dependence and memory effects, from marker results and region entries, over the whole-program call graph, with polyvariant specialisation when one function is used both classically and coherently. | No per-value attribute survives optimisation and none is needed. "Untainted" is defined relative to the resolved call graph, never per translation unit. |
| Control as structure: adjoint, controlled-by-qubit, compute-with-uncompute, reversible-tier entry | **Function granularity**: a region is outlined to a function (LLVM's `CodeExtractor`) and entered through a marker call `__bennett_ctrl(q, @f, budget, args…)`, `__bennett_adj(@f, …)`, `__bennett_compute(@f, …)`, or `__bennett_reversible(@f, budget, …)` for the reversible tier. The plugin generates controlled and adjoint bodies on demand from one source body. **Well-formedness:** a `ctrl`/`adj`/`compute` region is unitary: user measurement inside it is refused (or, when the front end asks for it, deferred by the deferred-measurement principle, which the certificate states); allocations inside are released clean or borrowed and restored; the compiler's own measurement-based uncomputation is the sole exception, and until its controlled form is fixed in the language's certificate kinds (§9.6) **unitary uncomputation is the fallback under control**. Exceptions and unwinding (`invoke`/`landingpad`, Rust panics, C++ `throw`) inside a region are step-machine control flow where the handler is in the region, and a fault code where it is not. | Front ends that want `when`-style syntax do the outlining themselves (Julia macro, clang attribute, Rust proc-macro) and emit the marker call; the dialect does not require it. Generating a body needs the callee's IR, which is why the plugin runs at link time (§3.3). |
| Bounds for coherent regions | **A region-level classical budget**: dynamic steps, heap bytes and recursion depth, passed as ordinary integer operands of the region-entry marker or supplied out of band by the host or driver (a project-wide default, a per-function table), and applied by the plugin after outlining. **No per-loop source annotation is ever required**, so unmodified SQLite, Linux and the Monte Carlo compile as they are. Per-loop bounds from scalar evolution, and optional per-loop markers, are *refinements* that let the specialiser tighten padding; they are not needed for correctness and no loop identity has to survive O3. | A region whose budget is exhausted on some basis input produces a fault outcome on that input (§4.2); it is never a compile error and never a truncated result. |
| Garbage and uncomputation | **Liveness analysis** on the outlined region plus the compute/uncompute marker; no lifetime intrinsics. | The scheduler decides when to pay to free a dead value; the dialect only has to make deadness computable. |
| Measurement and classical feedback | Marker call returning `i1`, flowing into ordinary `br` / `select` / `phi`, outside unitary regions. | Branching on a measurement result is classical control (§4.2). |
| Effects | Marker calls on the device side for the effects the device models (console, clock, entropy, block device); everything else is a host call. | Effect semantics per tier are in §4.2; an unvirtualisable effect inside a coherent region is a fault code on the executions that reach it, and a coverage-report line at compile time. |

### 3.2 Pipeline placement and the cost of staying in-tree

- **Correctness is invariant under LLVM's optimiser; cost is not.** Any
  semantics-preserving optimisation of the classical part is lowered as it
  stands, so differential testing (§5.1) is against the native binary
  built from the *same* optimised bitcode. Optimisations that erase or
  duplicate intermediate values change gate counts, so tainted regions get
  a curated region pipeline after outlining.
- **Definedness.** Source-level undefined behaviour cannot be "concretised"
  after an optimiser has exploited it (`clang -O3` turns `int y = 10/x;
  return 0;` into `return 0`, and nothing remains to fault on), so the
  document does not claim that. The contract, stated once and referenced
  by §0, §4.2, §5.1 and §8: **the reference semantics is the ISA formal-
  model interpreter run on the *materialised* optimised bitcode of the
  outlined region**, mapped by the dialect's reference semantics, before
  the curated region pipeline. **Materialised normalisation**, not
  `freeze`: LLVM's `freeze` yields an arbitrary fixed value that codegen
  lowers to whatever the register holds, so it cannot define one meaning
  shared by native code and the device. Instead the normaliser rewrites
  the region's optimised bitcode into a **poison-free, undef-free form**:
  poison-generating flags (`nsw`, `nuw`, `exact`, `inbounds` and kin) are
  stripped; partial operations are totalised with a stated result (a
  shift by ≥ width yields 0 through a `select`; division by zero becomes
  a fault, below); allocas, heap, padding and region inputs are zero-
  initialised; any remaining `undef` operand is replaced by a stated
  constant. After this the bitcode has **one defined meaning**, which
  native codegen and the ISA interpreter both implement, and the native
  comparison binary is built from that materialised bitcode. Only
  immediate undefined behaviour that the reference machine encounters
  (traps, `unreachable`, faulting memory access, division by zero) remains,
  and it is a fault code (§4.2); compiled artefacts must never fault where
  the reference does not. Source UB that optimisation erased before this
  point is **not detectable** and is covered by an explicit definedness
  assumption recorded in the certificate, together with the LLVM version
  and pipeline, since the fault set depends on them. The conformance
  harness classifies inputs with instrumented builds (UBSan, ASan, MSan)
  or a checked reference interpreter, as a separate build from the
  comparison binary; these are **supplementary classifiers**, not a
  complete decision procedure for source definedness, and inputs they
  flag are reported as *undefined* and excluded from comparison.
- **Regions are functions.** Every `when`, adjoint, compute and
  reversible-tier block outlines first. Enzyme lives with this.
- **Per-LLVM-major builds** of the plugin, as Enzyme is built. A mixed-
  language link (bitcode from different LLVM majors, different front-end
  IR idioms, one target datalayout) is supported only within a **tested
  compatibility envelope** published with each driver release: bitcode-
  reader versions, target layouts and ABIs, front-end pairs.
- **The legality spike** (§9.1) is a conformance corpus, not a design
  question: marker-bearing bitcode through every stock pass at O3, plus
  native code generation of fat objects, must preserve the dynamic
  sequence of marker calls on every path and must leave no handle use in
  host code. Freezing `bennett-dialect-spec` is gated on it passing, and
  on actual emission examples from clang, rustc and Julia.

### 3.3 Compilation model: link time, whole program, fat objects

Taint and controlled bodies depend on the calling context across the whole
program, and generating a controlled body needs the callee's IR. So:

- Front ends emit **bitcode** (clang `-flto`, rustc `--emit=llvm-bc` or
  `-Clinker-plugin-lto`, Julia through LLVM.jl). This is the one universal
  thing every LLVM front end does. No front end loads our plugin; pre-link
  per-TU optimisation sees markers only as unknown external calls, which
  is exactly the legality contract.
- **`bennett-driver`** merges the bitcode, runs LLVM's optimiser, loads the
  plugin at the LTO pipeline extension point (or runs it through `opt`),
  resolves taint over the whole call graph, and produces a **fat object**:
  native host code for the classical tier, ISA object(s) for the device
  tiers, and a certificate. clang's offload model (outlining, fat
  binaries, a launch runtime) is the **model**, not a reused mechanism: a
  middle-end pass cannot conjure clang's driver machinery, so we own ours.
- **Host-triple IR is what the device lowering accepts**: datalayout, ABI-
  lowered calls, target intrinsics and inline asm arrive as the host front
  end produced them. Target intrinsics and asm are classified *lowered /
  trapped / shimmed* in the coverage report. There is no `bennett` triple,
  because a plugin cannot add a clang target and we do not fork.
- **Stated coverage constraints:** a tainted call needs the callee's
  bitcode. Rust's distributed `std` normally carries embedded LLVM bitcode
  in its rlibs; the driver extracts it where present and compatible, and
  a rebuild (`-Zbuild-std`) is needed only where it is missing or from an
  incompatible LLVM major. The Julia runtime and precompiled native
  libraries need bitcode builds or shims (`bennett-runtimes`). Calls with
  no bitcode are coverage-report lines (*trapped*), never silent.
- **Per-front-end integration is named work**: clang needs only `-flto`
  and the driver; rustc goes through bitcode emission because its in-
  process plugin path is nightly-only; Julia goes through LLVM.jl and the
  same driver in-process. Bennett.jl is the Julia integration.
- A per-TU invocation remains available as a **fast path** for programs
  closed within one unit (the REPL case), with the same semantics.

## 4. The virtual ISA and the device

### 4.1 Why the VM is the revolution

The circuit model is to quantum programming what bare-metal machine code
was to classical programming before virtual machines, virtual memory and
portable ISAs: every program welded to one machine, every vendor with its
own toolchain, no dynamic allocation, no loops beyond what you unrolled by
hand, no portability, no way to ship one artefact to many machines. The
classical world escaped through abstraction layers *between* program and
hardware: virtual memory, the process, the JVM, LLVM, PTX.

Quantum programming has had abstract machines before: Knill's QRAM model
(1996), Quil's Quantum Abstract Machine, eQASM, and the circuit-plus-
classical-controller model every SDK ships. What none of them has is the
*rest* of the classical escape: virtual allocation with classes and
garbage as a resource, bounded coherent control over arbitrary programs
rather than hand-built circuits, separate compilation and linking, a
resource vector in the specification, and a program model that any LLVM
language targets without being rewritten. That combination is the layer
quantum programming lacks. The mistakes of the pre-VM era are listed so
the design never repeats them:

- **No program is written against a machine.** Programs target the virtual
  ISA; hardware implements the ISA through a target description.
- **Memory is virtual.** Qubits are allocated and released through the VM,
  never addressed physically. Clean, dirty and class are properties of an
  allocation request, not of a wire index.
- **Loops and recursion are instructions, not unrolling.** Budgets are
  values the VM enforces.
- **Resource accounting is part of the architecture**, in the ISA spec.
- **The spec is public and versioned.** Governance: PTX and the JVM each
  had a steward and a conformance regime; this ISA has a published spec, a
  conformance suite, and a steward who accepts target descriptions and
  revisions through a recorded process. A vendor implements it before an
  ecosystem exists for the reason vendors implemented PTX: the programs
  are written against it, not against them.

### 4.2 Execution semantics by tier

Two control disciplines, kept apart by name in the ISA:

- **Classical control** (host data, measurement results, run-time
  budgets): genuinely dynamic, an instruction pointer, data-dependent trip
  counts, real allocation. This is where run-time scheduling, history
  layers, checkpointing and pebbling policy live, and **every such
  decision may inspect only classical data**: an architectural invariant.
  Classical checkpointing never copies quantum state; a checkpoint of a
  coherent region is a point from which it is *recomputed*, which the
  scheduler may choose only where the region's own semantics permit.
- **Coherent control** (a decision that depends on a qubit): **predicated
  execution under a classical budget**, in both executors. The general
  construction, for an arbitrary and possibly irreducible post-O3 CFG, is
  a **predicated step machine**: a superposed block counter, stepped for
  the budget, every block executed under the predicate "the counter names
  me"; structured `pred { }` and `loop { }` blocks are optimisations of it
  that the specialiser applies where the CFG is structured. A branch on a
  qubit pays for both arms. An allocation whose size depends on a qubit is
  padded to its bound. The budget is classical and fixed before entry;
  run-time budgets come from the host or from measurement results, never
  from superposed data. **Nothing about the VM makes superposed trip
  counts observable or cheap; what it makes possible is choosing the
  budget at run time from classical data instead of at compile time.**

**Two region interfaces, kept apart by name.** Every coherent region is
one of:

- a **lifted classical oracle**: classical code that the plugin
  reversibilises. It computes one deterministic bounded result F_B(x),
  success or fault, with the interface and the XOR/involution properties
  below. Control is control of the XOR; adjoint is the same region.
- a **quantum action**: a region whose body contains non-permutation
  operations (rotations, Hadamards) or in-place bijections, acting as a
  unitary U on its **declared mutable wires**, with borrowed inputs
  preserved and workspace restored. Control means controlled-U, adjoint
  means U†. It is not an involution and does not XOR; in-place bijections
  belong here, and because they are total bijections with bounded
  inverses (§3.1) a quantum action has no fault outcome of its own: any
  fallible computation it needs is a lifted oracle it calls, whose fault
  register it declares among its outputs.

Lifted oracles and quantum actions nest freely; the plugin classifies
each outlined region by its contents and the verifier checks the
declared interface. At region exit the step machine synchronises: all
branches pad to a common halt counter before control workspace is
restored (the Quantum Control Machine condition, §7).

**Totality of lifted oracles: F_B(x), success or fault.** The oracle's
interface is: inputs (preserved), a caller-supplied output target (any
value), a caller-supplied **fault register**, and workspace. The **budget
unit** is steps of the ISA formal-model interpreter on the materialised
outlined region (§3.2), so the fault set is a property of program plus
budget plus recorded LLVM version and pipeline, never of Bennett's own
lowering; compiled artefacts pad internally as needed and never fault
where the reference does not. On success, F_B(x) = (f(x), 0): the output
target is XORed with f(x) and the fault register is unchanged. On failure,
F_B(x) = (0, code): the output target is XORed with the **canonical zero
payload** (left unchanged) and the fault register is XORed with a distinct
code per cause (budget exhausted: steps, heap, recursion; immediate
undefined behaviour reached; unmodelled effect reached), the code chosen
by the reference semantics. Because both halves are XORs, the region is
an involution on its targets: repeated, controlled and adjoint invocation
compose by XOR accumulation, which is what Grover-style iteration needs.
Inputs are preserved, dirty registers are unchanged and clean workspace is
restored on *every* basis input, faulted or not, by the **prefix-reversal
invariant**: on a faulted branch the step machine continues to the budget
with the fault predicate off, and its recorded history is reversed exactly
as on a clean branch. Two implementations that return the same fault code
therefore return the same quantum state, not merely the same flag. The
fault register is part of the oracle's interface: algorithms test it,
resource estimates report it, and the acceptance tests of §8 require its
rate to be zero on their declared domains, because a nonzero fault code on
some basis inputs entangles the fault register with x and degrades the
interference an algorithm such as Grover relies on. Both executors
implement exactly this; the circuit specialiser is the VM's semantics
under a fixed budget, no more and no less.

**Coherent memory and the region interface.** Classical code acting on
quantum state that outlives a region has exactly these meanings (mirrored
in the dialect, §3.1): a read is a CNOT copy onto fresh workspace, the
source preserved; a write XORs into its target, so writing a known-clean
register is a copy and writing a register not known to be clean is a
compile-time error; region inputs are preserved and declared outputs are
XORed into caller-supplied targets, every other write being restored
workspace; an in-place update x ← g(x) requires a total bijection with a
bounded inverse (a declared `__bennett_inplace(@g, @ginv)` or a library
bijection, §3.1) and is lowered as compute-out-of-place, swap, uncompute-
with-g⁻¹, else it fails loud; a fallible computation is never in-place.
This is the rule that makes controlled modular arithmetic, and `when(q)
do x += a end`, compile from unmodified code.

**Uncomputation validity (the Silq `qfree`/`const` and Unqomp
condition).** Garbage is a cost choice inside a correctness envelope, not
free policy. Each garbage value records its dependency set and was
computed by a `qfree` (classical, permutation-tier) computation; both
halves of the Silq discipline apply. It may be uncomputed by reversal or
recomputation only while that set is unmodified since its computation,
and it **must** be cleaned before any non-permutation operation
(Hadamard, non-diagonal rotation, measurement) or in-place update acts on
a wire in its dependency set, and before the end of the enclosing unitary
region. Measurement-based uncomputation with phase fixup is the
sanctioned alternative where that window has closed, with the fixup
computed for the actual schedule: after an intervening U the correction
D becomes U D U†, and §5.1 part 2 verifies the fixup as scheduled, never
an assumed one.
Compile-time and run-time schedulers choose **only among schedules that
satisfy this invariant**; the handle→wire verifier rejects violations;
conformance exercises them with interference tests (§5.1 part 2). A
scheduler that deferred uncomputation past an interfering operation
would compute the wrong state while every ancilla still returned to zero,
which is exactly the class of bug the invariant exists to make
unrepresentable.

Effects by tier:

| Tier | Where | Effects | Undefined values |
|---|---|---|---|
| classical | host, native | real | real |
| reversible | device | recorded on the effect tape forwards, replayed backwards; the device models console, clock, entropy, block storage as reversible device models; entered through `__bennett_reversible` or a driver mode | refined by the materialised normalisation of §3.2; immediate UB is a fault, recorded |
| coherent | device | **closed and effect-free**: no external effect may occur inside a coherent region. Devices the program touches are virtualised as reversible state inside the device (an in-memory VFS, a console register, a device model) and become part of the oracle's state. Classical inputs are fixed before entry; outputs leave through measurement after exit. An effect the device cannot virtualise is a fault code on the executions that reach it. | refined by the materialised normalisation of §3.2; immediate UB is a fault code |

What the VM physically *is* at run time: a classical runtime that
schedules quantum operations. Coherent regions are lowered to predicated
blocks; the classical runtime decides when to run them, with what
resources, and how to uncompute their garbage, using only classical
information; at launch it lowers predicated ISA blocks to the target's
declared gate alphabet using `bennett-targets` capability declarations
(the specialiser does the same ahead of time). On a simulator target the
VM executes a **permutation segment** by **branch enumeration**: a
permutation applied to a state vector is a permutation of amplitudes, so
the segment is run once per basis configuration of the superposed inputs,
tracking the full configuration including garbage and virtualised device
state. Non-permutation gates between segments (rotations, Hadamards,
measurement-based fixups) are applied to amplitudes and may increase the
branch count. This is what makes small-instance end-to-end demos (§8)
checkable without a state vector the size of SQLite's memory.

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
- **Honest costs of superposition**: a coherent branch pays for both arms;
  a quantum-addressed memory access costs O(N) gates through QROM/QRAM
  circuits unless the target provides QRAM; coherent allocation is padded
  to its bound; dirty ancillae are cheaper to borrow and more expensive to
  use; a predicated step machine over an unstructured CFG costs the budget
  times the block count unless the specialiser recovers structure.
- **Allocation classes:** clean |0⟩ allocation, **dirty borrowing** (a
  first-class resource with no analogue in the current code), and release, with clean release and restored correlations as
  **semantic obligations** checked by simulation (§5.1), since they cannot
  be decided statically in general.

### 4.4 What the ISA spec owns

The ISA spec is one of the two contracts (§6.1). It owns, by name, every
format or interface two repositories exchange across the device boundary:

- the instruction set and its formal model (abstract semantics, the fault
  register, the round-trip theorem);
- the resource vector and the **target-description format**, including
  capability declarations (gate alphabet, QRAM, measurement) beyond costs;
- the **object format** for ISA programs and the **link format** for
  separate compilation, with a call/uncall convention and shared ancilla
  frames (the reversible ABI);
- the **host–device launch ABI**: how a host program starts, suspends,
  reverses, and reads back a device program, budgets and fault registers
  included;
- the **scheduling interface**: scheduling problem in (ISA program, target
  description, objective), schedule and certificate out, with the C ABI,
  objective semantics and versioning, so a competitor's scheduler is
  substitutable and a competitor's VM cannot invalidate compile-time
  schedules;
- the **certificate schema** that `bennett-circuits`, `bennett-arith`,
  `bennett-estimate` and `Bennett.jl` all consume, including the proof-
  versus-evidence labels of §5.1;
- the **coverage-report format** the driver emits;
- serialisation and versioning rules, and the conformance suite.

### 4.5 An illustrative sketch (non-normative)

Instruction classes, not encodings:

```
  region   budget={steps,heap,depth} outputs=… → outputs, fault   ; coherent region entry
  qalloc   class=<name> n=<classical>            → wires           ; clean
  qborrow  class=<name> n=<classical>            → wires           ; dirty
  qfree    wires                                                   ; verifier: clean / restored
  gate     op=<X|CX|CCX|MCX|RZ(θ)|…> wires       → wires           ; linear: consumes, produces
  qload    addr=<wires> mem=<region>             → wires           ; O(N) unless target QRAM
  qstore   addr=<wires> val=<wires> mem=<region>
  step     pc=<wires> blocks=…                                      ; predicated step machine
  pred     p=<wire> { … }                                           ; structured optimisation of step
  loop     bound=<classical> { … }                                  ; structured optimisation of step
  fault    code=<const>                                             ; sets the region's fault register
  measure  wires                                 → classical bits   ; outside unitary regions
  br / call / ret / alloc / load / store                            ; classical control, host data only
  effect   dev=<model> …                                            ; reversible tier only; taped
```

A target description names its qubit classes with costs, its native gate
alphabet, whether it provides QRAM, and its resource scalarisation:

```
  target: surface-code-d17-example
  classes: { logical: {qubit_second: 1.0}, dirty_pool: {qubit_second: 0.3} }
  gates:   { CX: {t: 0}, CCX: {t: 7, depth: 3}, RZ: {t: "synth(ε)"}, measure: {time: 1} }
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
callee. The Lisp image, holding reversible objects with certificates.

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
synthesised, and *minimality* is claimed only with a checkable lower-bound
or exhaustive-search certificate (an exact-synthesis witness alone shows
attainability); large programs carry closed-form cost bounds and a
certificate of the gap between the schedule found and the best bound
known. The compiler chooses adders, pebbling, measurement-based versus
unitary uncomputation, QROM versus QRAM, under a space budget.

**The ecosystem.** A registry of reversible libraries with certificates:
libc, libm, zlib, crypto, SQLite, published as linkable ISA objects so
nobody compiles them twice. Arithmetic is library code too (§6).

### 5.1 Correctness

Ancilla-zero is not correctness: every historical S0 defect in this
project passed a reversibility check. Correctness is defined in three
parts, and every certificate labels each claim as **proof** (exhaustive
over a declared finite domain, or compositional/structural) or
**evidence** (sampled, with seeds and counts), never blurring the two.

1. **Permutation tier, by theorem.** Define the permutation tier *after
   decomposition into the gates actually emitted*: a circuit over
   {X, CX, CCX, exact MCX} is a permutation matrix. Relative-phase Toffoli
   decompositions and measurement-based fixups are **not** in this tier.
   A permutation is determined by its action on basis states. Therefore,
   over a declared finite domain D (every input x, every output-target
   value t, every fault-register value e, every value of every borrowed
   dirty ancilla d, clean ancillae in their declared state): if on every
   element of D the artefact's **entire final register tuple** equals the
   expected tuple |x⟩|t ⊕ payload(F_B(x))⟩|e ⊕ code(F_B(x))⟩|d⟩|0⟩, where
   F_B is the bounded reference result of §4.2 (native execution supplies
   f(x); the embedding specification supplies the rest), then its
   restriction to D is exactly that permutation, with input preserved, no
   relative phase and no residual entanglement. Input preservation is a
   hypothesis of the theorem and an acceptance check, not a consequence:
   an artefact that flipped an input bit after an otherwise correct oracle
   would pass every output-only check. **Exhaustive agreement on D is
   complete for D. Sampled differential testing above exhaustive widths is
   evidence, labelled as such.** Clean release and dirty restoration are
   checked by this simulation, not statically.
2. **Non-permutation lowerings, by channel comparison.** Measurement-based
   uncomputation is a channel (an instrument where outcomes are exposed),
   not a unitary on the data; rotations and synthesised gates are unitaries
   with an approximation budget ε. Every such lowering is verified against
   its reference by **process comparison at exhaustive small widths**: the
   induced channel (Choi-state comparison, including a reference system to
   catch lost correlations) for measurement-assisted implementations, and
   unitary equivalence plus **controlled-interference tests** (the artefact
   run controlled and inside an interferometer) for unitaries, with ε and
   its **composition rule** stated per artefact: the metric is the diamond
   norm for channels and a phase-sensitive operator-norm bound for
   unitaries under control, budgets add along a sequence, and the
   certificate carries the sum. Floating-point matrix agreement counts as
   proof only with a rigorous numerical error bound; otherwise it is
   evidence. This is proof for the widths tested and evidence above them.
3. **Algorithms, compositionally.** Grover, amplitude estimation and
   friends are verified by state-vector simulation at small instance size
   with the compiled oracle applied by branch enumeration over its
   permutation segments (§4.2), and resource estimates are produced from
   the oracle's certificate without materialising gates.

**Equivalence is "equals native, or is flagged".** On every element of a
rung's declared domain the artefact must return either the native result
or a fault code; the fault rate over the domain is reported and must be
zero on the rung's acceptance instances; inputs the instrumented
classifiers of §3.2 report as undefined are excluded and counted
separately. Domain D stays finite and tractable when large dirty pools
are borrowed by a structural lemma: borrowed wires are used only inside
verified compute–use–uncompute frames, so their restoration is proved per
frame; where that lemma does not apply, dirty restoration above small
widths is labelled evidence.

**What a certificate asserts:** the ISA object, the target, the objective,
the claimed resource vector, the tier and budget of each region, the
definedness assumption, the verification performed (parts 1–3, with
domains, widths, seeds and counts, each labelled proof or evidence), the
fault rate per declared domain, and for small kernels an exact-synthesis
witness and, where minimality is claimed, its lower-bound certificate. A
checker in `bennett-conformance` validates a certificate against the
object without trusting the compiler; replayable validation records are
not proofs and are labelled evidence.

## 6. The right language for each job

| Component | Language | Why (taste excluded) |
|---|---|---|
| Pass plugin (taint, outlining, body generation, lowering to the ISA) | **C++** | The only component of the compiler core that links LLVM (Bennett.jl, as a front end, uses LLVM.jl). `llvmGetPassPluginInfo` has C linkage, but registering a new-PM pass and every analysis the plugin needs (loop info, dominators, scalar evolution for bound refinement, alias analysis, MemorySSA, `CodeExtractor`) are C++ API only. v1 is the evidence of avoiding this: it reimplements loop analysis in `src/lowering/cfg.jl` and parses MemorySSA out of printed text in `src/memssa.jl`. Enzyme is C++ for the same reason. Built per LLVM major. Kept narrow: it does not contain the scheduler. |
| Scheduler and cost model (`bennett-sched`) | **Rust**, C ABI owned by the ISA spec | Linked by the plugin (compile time) and the VM (run time); it is what makes decision 6 literally true. No LLVM dependency. |
| ISA spec tooling, VM / device runtime, circuit specialiser, estimator | **Rust** | None touch LLVM: they consume the ISA's serialised form. Embeddable device library with no runtime; memory safety in a component that must never crash a host; usable without std near kernels; a JIT tier available without LLVM. Rust ownership is affine, not linear, so it models qubit ownership well with a leak check, not natively. |
| Driver | **Rust**, invoking LLVM tools (`opt`, `lld`) as external processes and the plugin through them | The driver orchestrates bitcode but does not link LLVM itself; that keeps the "C++ only where LLVM is linked" rule true. |
| **The Julia quantum language**, REPL, research laboratory | **Julia (Bennett.jl)** | Bennett is the family name: Bennett.jl *is* the Julia quantum language (`when`, oracles, in-place regions, certificates, `@cost`), the first front end built on the dialect, and the product's face. The former Sturm.jl is sunset; its surface constructs and its MCX kernel are absorbed here. Bennett.jl orchestrates the driver in-process through LLVM.jl while the LLVM tools themselves run out of process; new lowerings and arithmetic are prototyped here against the spec. |
| Arithmetic and runtime libraries (adders, multipliers, QROM, soft-float, allocator shims, libc, device models) | **Any** | Ordinary code compiled through the same pipeline and shipped as ISA objects with certificates. "Runtimes are libraries" applies to arithmetic too; the specialiser links them. |

Consequence: the centre of gravity leaves Julia. Bennett.jl is the front
door of Bennett, not the whole of it. The maintainer has stated this is
acceptable; the north star outranks language preference.

### 6.1 Many small repositories, two contracts, fully enumerated

**A monolith will grind to a halt** (maintainer, 2026-10-28). Independent
repositories, each developable, versioned, tested, and released on its
own, communicating only through **two published contracts**:

- **`bennett-dialect-spec`**: the marker-function ABI (names, signatures,
  the positive legality requirement), the portable handle convention, the
  outlining, budget and region well-formedness conventions, the legality
  conformance corpus, the driver's plugin-invocation interface,
  versioning.
- **`bennett-isa-spec`**: everything in §4.4: instruction set and formal
  model, resource vector and target-description format with capabilities,
  object and link format with the reversible ABI, host–device launch ABI
  (including how host code that interleaves genuine host effects with
  handle or measurement manipulation is split from the device's
  classical-control tier), scheduling interface, certificate schema,
  coverage-report format, serialisation, conformance suite. Its sub-
  artefacts (ISA, object format, launch ABI, certificate schema) are
  versioned independently.

Nothing shares code across a contract boundary; anything that needs to is
a sign the boundary is wrong. **One semantics comes from the ISA spec's
formal model and conformance suite, never from shared code.** The dialect
spec additionally carries a **reference semantics** from marker programs
to the ISA formal model (including the copy, store and in-place rules of
§4.2), so a competing plugin is conformance-tested at spec level and not
only by native differential. **Binary edges are versioned too:** a
`bennett-sched` built against ISA spec vN is replaceable without
rebuilding the plugin, and a plugin is replaceable without rebuilding the
driver; the substitutability test covers binary edges as well as document
edges.

| Repository | Owns | Depends on |
|---|---|---|
| `bennett-dialect-spec` | as above | nothing |
| `bennett-isa-spec` | as above | nothing |
| `bennett-sched` | scheduler and cost model behind the ISA spec's scheduling interface | ISA spec |
| `bennett-plugin` | the C++ LLVM pass plugin; built per LLVM major | dialect spec, ISA spec, sched (binary) |
| `bennett-driver` | link-time driver: bitcode merge, plugin invocation, fat objects, launch, coverage reports; per-front-end integration | dialect spec, ISA spec, plugin (binary) |
| `bennett-vm` | the Rust device runtime: classical-control tier, history layers, effect tape, device models, branch-enumeration simulation, launch-time lowering to the target alphabet, JIT tier | ISA spec, sched |
| `bennett-circuits` | the bounded specialiser: hierarchical circuit IR, placement, proof-carrying output, exporters (OpenQASM 3, QIR, Quil) | ISA spec, sched |
| `bennett-estimate` | resource estimation from ISA objects, certificates and target descriptions, no gates materialised | ISA spec |
| `bennett-targets` | target descriptions per hardware model, contributed by vendors; importers for existing resource-model formats | ISA spec |
| `bennett-runtimes` | allocator, libc/musl shims, device models, Julia shim runtime, bitcode builds of language runtimes, as ordinary code compiled to ISA objects | dialect spec; driver (build tool) |
| `bennett-arith` | adders, multipliers, QROM, soft-float, as ISA library objects with certificates | dialect spec; driver (build tool) |
| `Bennett.jl` | the Julia quantum language: `when`, oracles, in-place regions, certificate kinds, simulators as VM targets, REPL, `@cost`, research lab | driver (binary), ISA spec |
| `bennett-conformance` | the demo ladder as executable gates, the certificate checker, the legality corpus runner, the differential harness with the instrumented classifiers of §3.2 | everything, as a consumer only |

The test of the split: every repository can be replaced by a competitor's
implementation of the same spec without the rest noticing.

## 7. Landscape: what is taken, what is rejected, what is new

| System | What Bennett takes | What it does differently |
|---|---|---|
| **Enzyme** | The delivery model: an LLVM plugin, marker calls, optimise–transform–optimise, LTO for cross-TU bodies, per-LLVM-major builds; activity analysis as the precedent for taint analysis. | Reversibilisation instead of differentiation; the output is a program for a second executor, not more LLVM IR. |
| **PTX / CUDA, OpenMP offload** | Virtual ISA with per-hardware target descriptions; host/device split; fat objects; a launch runtime. | We own the driver and launch runtime; nothing is reused from clang's offload machinery. |
| **Quil / QAM, eQASM, Knill's QRAM model** | The idea of a public abstract machine with a classical controller; Quil as an import/export format. | Those machines execute hand-built circuits with classical control; none has virtual allocation classes, garbage as a resource, bounded coherent control over arbitrary programs, linking, or a resource vector. |
| **QIR** (QIR Alliance) | LLVM as the carrier; profiles as a warning. Its adaptive profile and memory-management spec exist and are read on import. | Stated precisely: qubits are opaque pointers with no ownership discipline (they do participate in SSA dataflow); adjoint and controlled bodies are emitted by the front end as separate functions, so the IR carries no structural algebra over them; no uncomputation, garbage, resource model, or oracle abstraction; the profiles mix "program the host runs" with "circuit the device executes". Bennett keeps control and adjoint structural, keeps ownership explicit in the ISA, and puts resources in the spec. |
| **OpenQASM 3** | `ctrl@` / `inv@` modifiers and its dynamic classical control as the export target's expectations. | OpenQASM 3's dynamic control is classical control (§4.2); it is a circuit language, not a program model with memory, linking, or resources. Export only. |
| **CUDA-Q / Quake** | Quantum kernels as device code; `cudaq::control` / `cudaq::adjoint` at function granularity; the ref-vs-wire distinction, adopted as dialect-vs-ISA. | Not a new language or kernel annotation: taint is inferred over unmodified C, Rust, Julia. The carrier is LLVM bitcode, because that is what every front end emits; MLIR lowering paths are an import door. |
| **Catalyst, MLIR quantum dialects, Qrisp** | Import path for programs already in those dialects; precedent for a JIT tier; Qrisp's automatic uncomputation over Python-level programs. | Arbitrary LLVM programs, not a Python-hosted language. |
| **Q#** | Adj+Ctl specialisation from one body. | Specialisation in the plugin over any language's IR, not in one language's compiler. |
| **Quipper** | Oracle synthesis from classical code; `with_computed`. | Any LLVM language; a VM and ISA beneath. |
| **Silq, Unqomp, Reqomp, SQUARE** | Automatic and budgeted uncomputation; garbage as a resource with a budget; **the uncomputation-validity condition of §4.2 is Silq's `qfree`/`const` discipline and Unqomp's criterion, adopted as an ISA invariant.** | Uncomputation scheduled at run time by the VM as well as at compile time, under a target's resource vector, inside that invariant. |
| **Quantum Control Machine (Yuan, Villanyi, Carbin 2023)** | The injectivity and synchronisation analysis of quantum control flow, which the step machine of §4.2 must satisfy. | Bennett's embedding preserves classical inputs through the oracle interface and cleans control state at region exit, rather than lifting unrestricted quantum control flow. |
| **QCOR / XACC, Qiskit classical-function compiler, tweedledum / RevKit, ProjectQ Compute/Uncompute, REVS (Parent–Roetteler–Svore)** | C++ quantum kernels through a clang plugin with compute/action/uncompute and automatic ctrl/adjoint; oracle synthesis from classical functions; the compute/uncompute idiom. | Whole programs in any LLVM language rather than annotated kernels or small classical-function languages; a VM and ISA beneath. |
| **Tower, Spire** | Superposed pointers and classically bounded recursion as the right semantics for coherent data structures; Spire's accounting of the cost of padded coherent control. | The same semantics, for programs nobody rewrote; the step machine of §4.2 is the general case. |
| **Qualtran, Azure RE** | Symbolic, hierarchical resource counting without materialised gates; target models as data. | Certificates attached to linkable objects; the target-description format accepts imported models, converting units where they align with the target's declared resources and otherwise importing them as new named resources. |
| **QSSA, QIRO, HUGR / Guppy / tket2** | Linear SSA for quantum values; HUGR's hierarchical hybrid graph and Guppy's Python-embedded typed quantum language as the closest contemporary program-level IR. | Used in the ISA, not imposed on LLVM IR; HUGR is an import/export door. |
| **ReVerC** | Verified reversible compilation of a small language. | Correctness by theorem plus oracle (§5.1) for arbitrary LLVM input. |
| **Reversible pebbling (Bennett 89, Knill 95, PRS15, Chan et al.)** | The space-time trade-off theory and its hardness result. | Pebbling as run-time policy over a resource vector, not only a compile-time choice. |

**What is new**, claimed narrowly: (a) inferred-taint reversibilisation of
unmodified programs in any LLVM language, delivered as a link-time plugin,
with total coherent regions and a fault outcome; (b) a public virtual ISA
for quantum programs with virtual qubits, allocation classes, bounded
coherent control of arbitrary CFGs, garbage as a scheduled resource, a
resource vector, linking, and a host–device ABI; (c) one scheduler used at
compile time and run time behind a published interface; (d) correctness
defined by the permutation theorem plus channel-comparison oracles,
attached to linkable objects as certificates that separate proof from
evidence. Everything else is adopted from the systems above with
attribution.

## 8. Demo ladder (success criteria, each with its acceptance test)

| Rung | Demo | Acceptance test |
|---|---|---|
| 1 | Scalar C, Rust, Julia functions | Exhaustive at Int8 over the full domain D of §5.1 part 1, both executors equal to native; fault rate zero. |
| 2 | Pointers, structs, byte memory | A C hashtable (the existing 258-line corpus): forward result equal to native on every tested input (independent check), then reversed byte-exactly, both executors. |
| 3 | musl hello-world | Forward output equal to native; run in the reversible tier with a console device model; un-run to the reset state; tape replay deterministic. |
| 4 | **Grover over SQLite** | SQLite compiled unmodified to the coherent tier under a region budget, with an in-memory VFS over quantum-addressed memory. Database of N rows fixed classically before entry; the predicate is a real SQL query; the oracle bit is the query's match. (a) Oracle verified by §5.1 part 1 over all rows and all target values for N ≤ 2¹⁰, fault rate zero. (b) End-to-end Grover by state-vector simulation with branch enumeration at N ≤ 2⁸. (c) A resource estimate for N = 2²⁰ under a named target, reporting the budget and the padded cost. Nobody rewrote SQLite. |
| 5 | Julia on a shim runtime | `push!` and `Dict` work because the allocator works, with zero compiler awareness of either; forward results equal to native Julia; reversal exact. |
| 6 | xv6, then Linux `tinyconfig` | Serial console output equal to a native (QEMU) run of the same image (independent forward check); boots in the reversible tier with device models; un-boots to the reset vector; tape replay byte-identical. |
| 7 | **Quantum fuzzing of the kernel** | Kernel state snapshot fixed classically after boot; a step budget; syscall arguments as the superposed input over a declared small space; devices virtualised; the oracle bit is the panic flag. The contract is the optimised-IR reference semantics of §3.2 under a recorded definedness assumption; the kernel's own source UB is not detected after optimisation and is not claimed to be. (a) Oracle verified by §5.1 part 1 against native execution of the same snapshot per basis input, with classifier-flagged inputs reported, fault rate zero on the declared space. (b) Amplitude amplification by state-vector simulation at a toy argument space. (c) A resource estimate under a named target. The oracle is Linux. |
| 8 | **Amplitude estimation on a Monte Carlo in plain C** | Written by someone who has never heard of a Toffoli gate. The entropy device is replaced by a superposed register; everything else is fixed classically before entry. (a) Oracle by §5.1 part 1; (b) estimation by simulation at small precision; (c) resource estimate. |

Rungs 1–3 and 5–6 are the blueprint's; 4, 7, 8 define success for the
vision; nobody promises 6–8 on a schedule.

## 9. Open technical questions (deferred by the maintainer's rule: vision first)

In the order the next iteration should take them. Items the council
promoted from "detail" to "load-bearing" are now answered at vision level
above and appear here only for their mechanics.

1. **The legality spike** (§3.2): the marker corpus against every stock
   pass at O3 and through native codegen; emission examples from clang,
   rustc and Julia; gate on freezing the dialect spec.
2. **Handle → wire conversion**: the verifier, what it rejects (including
   the uncomputation-validity invariant and the copy/store/in-place rules
   of §4.2), the leak check.
3. **Compilation model mechanics** (§3.3): LTO extension point vs `opt`;
   fat-object layout; the launch ABI; host-triple intrinsic and asm
   classification tables; bitcode builds of language runtimes.
4. **Budget mechanics**: out-of-band budget tables; scalar-evolution
   refinement; how the specialiser recovers structure from the step
   machine; the exact fault-code set.
5. **Effect virtualisation**: which device models exist (VFS, console,
   clock, entropy, block device, network as a recorded peer), how they are
   expressed as reversible state, what is refused.
6. **Measurement-based uncomputation under control**: the v1
   `PermClean`-style certificate (inherited from the sunset Sturm.jl)
   cannot express it; the certificate kind with classical fixup and its
   controlled form, fixed in Bennett.jl's language before any gate record
   freezes.
7. **Reversible ABI and linking**: call/uncall convention, shared ancilla
   frames, structural symbol resolution, content-addressed objects.
8. **Run-time scheduling policy**: history layers, checkpoint interval,
   delta quality, recomputation of coherent regions, as resource policy
   under the vector of §4.3.
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
