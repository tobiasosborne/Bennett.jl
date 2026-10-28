# ISA-specification rubric — the council's scale

The rubric the council (`docs/council/README.md`) uses to grade
`Bennett-ISA-Spec.md`, the founding draft of the Bennett virtual ISA
specification (the `bennett-isa-spec` contract of `Bennett-NorthStar.md`
§4.4 and §6.1). Eight criteria, each scored 1–5 on an absolute scale, plus
blocking issues, a path to accept, and a verdict. Scores are advisory; the
maintainer decides.

## What is being graded

A **specification**, at the level of a first normative draft: the
document a VM author, a circuit-specialiser author, a plugin author, a
scheduler author and a hardware vendor would each implement against,
independently, and be conformance-tested on. It is not an implementation
and not a vision; the vision is `Bennett-NorthStar.md`, supplied as
background and not graded. Grade whether the spec *pins the semantics
precisely enough that two independent executors built from it would
agree*, whether what it pins is physically and mathematically sound, and
whether every cross-repository contract the north star assigns to it is
actually here.

Do not deduct for encodings, binary layouts or performance numbers that
the draft explicitly defers; do deduct, and block, for a semantic rule
that is ambiguous, inconsistent, physically wrong, or missing where an
implementer would have to guess.

## The standard

The PTX ISA document, the JVM specification, the RISC-V unprivileged spec,
the LLVM language reference: a stranger implements from the text alone,
and two strangers get the same machine.

- **Scores are absolute**, not on a curve.
- **Precision over breadth.** A smaller instruction set defined exactly
  scores above a larger one defined loosely.
- **Skepticism is required.** Check the quantum semantics (predicated
  execution, reversibility, uncomputation validity, measurement, fault
  outcomes, phases) against your own knowledge; check reversible-ABI and
  linking claims against how linkers and ABIs actually work.
- **Blocking means blocking.** A blocking issue is one that, uncorrected,
  would make two conformant implementations disagree, would make the
  machine unphysical or irreversible where it claims reversibility, or
  would leave a north-star contract unspecified. Everything else is a
  suggestion.

### Scale

- **5:** implementable by strangers with no questions; sound; complete for
  its declared scope; nothing superfluous.
- **4:** implementable with one gap an implementer names at once.
- **3:** a competent draft; the shape is right but several rules need an
  author's clarification before implementation.
- **2:** aspirational; semantics sketched, not pinned.
- **1:** inconsistent or unphysical at the core.

## Criteria

### C1 Machine model

Are the tiers, the state (classical registers and memory, wires, quantum
memory, predicate stack, budget, fault register, history, effect tape),
the types, and the step relation defined unambiguously? Could two
implementers draw the same state diagram?

### C2 Instruction set

Does every instruction have a form, operands, well-formedness rules,
semantics, and a cost hook? Is the set closed and sufficient for what the
dialect must lower (classical control, allocation classes, gates, quantum-
addressed memory, copy/xor/exchange, predication, the step machine,
regions, measurement, effects, faults)? Is anything underdetermined?

### C3 Coherent semantics

Is the predicated step machine defined so that both executors compute the
same function? Are the lifted-oracle interface F_B, the quantum-action
interface, nesting, exit synchronisation, the prefix-reversal invariant,
the fault register, the budget unit, in-place bijections and the
uncomputation-validity invariant stated as checkable rules? Is anything
irreversible, phase-unsafe, or dependent on inspecting superposed data?

### C4 Resources and targets

Is the resource vector, the qubit-class model, the target-description
format (classes, gate alphabet with costs, capabilities such as QRAM and
measurement, objective as weights or lexicographic order, units) complete
enough that a vendor could write one and the scheduler could consume it?
Is the import rule for existing resource models stated?

### C5 Contracts

Are the object format, link format, reversible ABI (call/uncall, ancilla
frames, structural symbol resolution), host–device launch ABI, scheduling
interface, certificate schema and coverage-report format each specified
to the level the north star promises, so that the thirteen repositories
can be developed independently? Is anything that two repositories must
agree on left to convention?

### C6 Formal model and conformance

Is there an abstract semantics an implementer can check against? Are the
theorems (totality and fault determinism, prefix reversal, the
permutation theorem with its exact domain, round-trip for the reversible
tier, validity implies no residual entanglement, executor agreement)
stated with hypotheses? Can the conformance suite be derived from the
text?

### C7 Consistency with the north star and with prior art

Does the spec contradict `Bennett-NorthStar.md` anywhere? Does it use the
established forms where they exist (linear wire SSA as in Quake/QSSA,
Silq/Unqomp validity, QCM synchronisation, Bennett/Knill history) rather
than reinventing them badly?

### C8 Implementability and clarity

Could a VM author and a specialiser author each start tomorrow from this
text? Are the explicitly deferred items genuinely non-semantic? Is the
document organised so a reader finds a rule where they expect it?

## What the council returns

Per criterion: a score 1–5, one or two sentences of evidence pointing at
the document's text, and the single change that would most raise the
score. Then `blocking` (each with id, section, problem, and a concrete
fix: the rule the spec should state), `suggestions`, `path_to_accept`,
`verdict` (`accept` / `revise` / `reject`), and `summary`.

Consensus is reached when every member returns `accept` with an empty
blocking list.
