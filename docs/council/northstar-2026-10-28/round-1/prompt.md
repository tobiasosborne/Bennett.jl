# Council

You are a member of a three-model council grading the document below, the founding vision for a from-scratch reboot of Bennett (a reversible / quantum compiler toolchain; see the document). Grade it against the rubric on the absolute scale. Be exacting and skeptical: verify every technical premise against your own knowledge; name any that is false. Grade the vision for being the right vision, stated precisely; do not deduct for things that are not built yet. A blocking issue is one that would make the project build the wrong thing if uncorrected; everything else is a suggestion. Return `accept` only if the blocking list is empty.

You may read the repository you are running in (read-only) to check claims about the current code; its root contains Bennett-NorthStar.md (the document, identical to the snapshot below), Bennett-Reboot-Blueprint.md and Bennett-V2-PRD.md (the superseded plans), worklog/ (session logs; chunk 121 has the 2026-10-28 ground-truth survey), reviews/2026-09-26-astra/ (the last review campaign), and src/ (the deprecated v1). Reading is optional; the snapshot below is what you grade.

Answer only with JSON matching the schema.

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


# The document (`Bennett-NorthStar.md`, round 1 snapshot)

# Bennett — North Star (reboot vision, iteration 1)

**Date:** 2026-10-28. **Status:** vision settled at the level of "what it
truly looks like"; technical design NOT started. Written up from a
maintainer/agent discussion on 2026-10-28. Nothing here is implemented, and
no code is to be written on the strength of this document alone (maintainer
process rule: vision, then design, then spikes, then code).

**Relation to earlier documents.** This supersedes
`Bennett-Reboot-Blueprint.md` §3.1–§3.4 (which proposed a new standalone IR,
"BIR"): the IR is now LLVM IR itself, with a dialect inside it. The
blueprint's §5 keep/kill list, §6 ladder, and §7 risks carry over where they
do not conflict. `Bennett-V2-PRD.md` remains parked. `Bennett-VISION-PRD.md`'s
Enzyme analogy turns out to be literal, not a metaphor (§3 below).

**Ground truth this was checked against** (2026-10-28 read-only survey of
both repos, the Astra reviews, BENCHMARKS.md, and the Sturm.jl checkout at
`~/old/Projects/Sturm.jl`): see worklog chunk 121, session 2026-10-28. The
short version: the current Bennett.jl / BennettVM.jl are deprecated as
designs; their research assets (arithmetic generators, soft-float with its
test conventions, gate algebra, scaling-relation regressions, the 6502
native-oracle harness) are the only things carried forward.

---

## 0. Thesis

**Every program is already a quantum program.** The user never writes a
circuit, never declares a subset, never learns a new language. They write
C, Rust, Julia, anything LLVM eats, and the toolchain decides at every
instruction whether it runs classically, reversibly, or in superposition.
The only thing a quantum programmer adds to a classical codebase is a
handful of intrinsics: allocate qubits, rotate by theta, measure, and a way
to condition on a qubit. Everything else is inferred.

Tagline: **controlled-anything.** If it compiles with clang, you can put it
under a qubit.

The project is predicated on scalable logical quantum computation becoming
real: plenty of logical qubits and gates at usable gate times. Efficiency is
pursued to optimality; universality is never traded for it.

## 1. Decisions (settled 2026-10-28)

1. **Bennett is the LLVM of quantum.** Language designers introduce quantum
   constructs *as they please*, the way LLVM lets anyone design a classical
   language. We provide the target and the optimiser, never the language.
   Whether `if (q)` on a qubit is a source construct is a front-end
   question, not ours.
2. **The IR is LLVM IR. We never fork LLVM.** Forking is the disaster
   scenario. Decades of classical optimisation are kept by sitting inside
   the ecosystem, invisibly, through sanctioned extension points only
   (§3). What is classical is optimised by LLVM, unmodified, before and
   after us.
3. **Delivery is a pass plugin plus a runtime.** Optimise, reverse,
   optimise. Loaded by clang, rustc, and Julia without modification. The
   Linux kernel already builds with `make LLVM=1`; "the kernel compiles" is
   one extra flag on an unmodified build.
4. **Tainted code is device code.** The classical/reversible/quantum taint
   tiers map onto the host/device offload model clang already has for GPUs
   (outlining, fat binaries, a launch runtime). Untainted code is host code:
   compiled natively, never reversed, never ours. The quantum VM is a device
   in exactly the sense a GPU is a device.
5. **One virtual ISA, one target description per hardware.** The PTX move.
   The ISA is a versioned public specification with a conformance suite; the
   formal model is of the spec, not of any implementation. A hardware vendor
   writes a target description without talking to us.
6. **The VM is a scheduler over an extensible resource vector**, not a
   memory manager. Base resource: qubit-time, by qubit class. Targets
   declare further resources (energy per qubit, qubit quality tiers,
   routing, T, Clifford, measurement). Garbage is a schedulable resource
   with an occupancy cost. Pebbling, checkpointing, and measurement-based
   uncomputation are one decision: when to pay to free a resource. The
   compiler and the VM are the same optimiser at two time scales.
7. **QIR and OpenQASM 3 are edge formats.** Read and written at the
   boundary, like LLVM reads and writes bitcode. Never the semantics. (QIR's
   known problems: qubits as opaque pointers invisible to dataflow, adjoint
   and controlled bodies emitted by the front end so the IR cannot reason
   about them, no uncomputation, no ownership, no resource model, no oracle
   abstraction, profiles that mix "program the host runs" with "circuit the
   device executes".)
8. **Languages: the right tool for the job, taste excluded.** See §6.

## 2. The architecture, in one picture

```
  Front doors            Julia (REPL, Bennett.jl)   C / Rust via clang / rustc   QIR in   MLIR dialects (door, not centre)
                                        │                       │                  │          │
                                        ▼                       ▼                  ▼          ▼
  One IR                ───────────────  LLVM IR  +  the Bennett dialect (ext. types, intrinsics, addrspace, attrs, metadata)
                                                    │
                        LLVM's own optimiser (unmodified)   ──►   Bennett pass plugin (C++, the only LLVM-linked component):
                                                                  taint → outline → lower to virtual ISA → optimising scheduler
                                                    │
  One virtual ISA       ───────────────  Bennett virtual ISA (public spec, versioned, conformance suite, formal model)
                                                    │
  Two executors                 ┌───────────────────┴────────────────────┐
                                ▼                                        ▼
                     Quantum VM / device runtime              Circuit specialiser (bounded case)
                     (run-time scheduler, resource vector,    (hierarchical circuit IR, closed-form costs,
                      garbage ledger, effect tape)             proof-carrying output)
                                └───────────────────┬────────────────────┘
                                                    ▼
  Backends              Sturm.jl (Perm/MCX)   OpenQASM 3   QIR out   Resource estimator   Hardware, via target descriptions
```

One semantics (the virtual ISA spec), two executors, permanent differential
testing between them and against native execution of the same binary.

## 3. The dialect: what must be expressible, and how LLVM already lets us

The dialect is a contract, not a new IR. Each construct below maps onto an
extension point LLVM sanctions for out-of-tree use (this is how NVPTX/AMDGPU
address spaces, SPIR-V target extension types, and Enzyme's plugin all
work without forks).

| Must be expressible | LLVM extension point |
|---|---|
| Qubits and quantum registers as SSA values with linear ownership, never opaque pointers | Target extension types (`target("bennett.qubit", …)`), opaque to every pass, so no pass can invent a copy |
| Classical and quantum data in one type lattice (an integer stored in qubits is still an integer to every classical pass) | Ordinary `iN` values plus an address-space / attribute taint; the plugin's taint analysis infers the lattice |
| Quantum memory, addressable by quantum pointers (a page table in superposition) | A dedicated address space; alias analysis is already conservative on unknown address spaces |
| Gates, allocate clean / allocate dirty / release, measure, rotate(θ) | Intrinsics with memory-effect and convergence-style attributes so the optimiser can neither duplicate, CSE, nor hoist them. **The attribute set is the legality contract** (open, §8) |
| Control as structure: adjoint, controlled-by-predicate, compute-with-uncompute, composable (controlled-controlled-adjoint is a rewrite, not a new body) | Function granularity, as Enzyme's `__enzyme_autodiff(f, args)`: a region outlines to a function plus a marker call; the plugin generates adjoint/controlled bodies on demand, one source body per function |
| Data-dependent iteration and recursion with a **bound value**, not a bound constant | Ordinary loops; the bound is an operand carried by loop metadata or a marker intrinsic; scalar evolution supplies static bounds where they exist |
| Garbage as a first-class value with a lifetime, so uncomputation is scheduled like deallocation | `llvm.lifetime.start/end` already exist; the scheduler reads them |
| Measurement and classical feedback as ordinary dataflow, including feedback into further quantum control | Intrinsic results flowing into ordinary `br`/`select`/`phi` |
| Effects, including the outside world, on a recorded tape so execution and un-execution are deterministic | Runtime calls on the device side; tape format is a runtime concern |
| Byte-addressed classical memory and quantum-addressed quantum memory through the same load/store | Address classes on the same `load`/`store` instructions |

Linear ownership of qubits is a verifier pass, not a type system: a borrow
checker run after the fact.

Two things LLVM will push back on, and we live with: its optimiser is not
reversibility-aware, so some legal transformations on the tainted region are
expensive (the current project already pins the target machine for this
reason; the fix is a region pass pipeline, never a fork); and regions must
be functions, so every `when` and every uncompute block outlines first.
Enzyme lives with both.

## 4. The virtual ISA and the device

**The quantum VM is the revolution; everything else in this document is in
its service.** The circuit model is to quantum programming what bare-metal
machine code was to classical programming before virtual machines, virtual
memory, and portable ISAs: every program welded to one machine, every
vendor with its own toolchain, no dynamic allocation, no loops beyond what
you unrolled by hand, no portability, and no way for a software vendor to
ship one artefact to many machines. The classical world escaped through
abstraction layers that sat *between* program and hardware: virtual memory,
the process, the JVM, LLVM, PTX. Quantum programming has not had its
abstraction layer, and the field's tooling shows it. The maintainer's
position, after a year of discussion with the field's leading figures, is
that this layer is the missing piece and that it will matter to hardware
vendors and software vendors alike. The mistakes of the pre-VM era are
listed here so the design never repeats them:

- **No program is written against a machine.** Programs target the virtual
  ISA; hardware implements the ISA through a target description. A program
  compiled today runs on a machine built in ten years.
- **Memory is virtual.** Qubits are allocated and released through the VM,
  never addressed physically by the program. Clean, dirty, and class are
  properties of an allocation request, not of a wire index.
- **Loops and recursion are instructions, not unrolling.** Bounds are
  values the VM enforces at run time.
- **Resource accounting is part of the architecture**, not an afterthought
  bolted on by each vendor. The resource vector is in the ISA spec.
- **The spec is public and versioned**, so the ecosystem can form around it
  without anyone's permission.

- **Not a circuit, not an interpreter: an architecture.** A qubit heap with
  clean and dirty allocation; a classical coprocessor; an instruction set in
  which "branch on a qubit" and "loop while a quantum register is nonzero,
  up to a bound" are legal instructions; a garbage ledger with a run-time
  pebbling policy; effect tape; measurement with feedback.
- **The circuit model is the bounded specialisation of the VM.** Given
  bounds (proved, or supplied and enforced), the specialiser partially
  evaluates a VM program into a hierarchical circuit with closed-form costs,
  so a resource estimate of a controlled kernel takes seconds and never
  materialises a gate.
- **Bounds move from compile time to run time.** That is the real unlock of
  the VM: a loop with a data-dependent trip count runs under a bound chosen
  when the program is loaded, from classical data. Trip counts in
  superposition still need a maximum, and the circuit pads to it; this is
  physics, not a limitation we accept lightly, and it is stated here so it
  can be argued with.
- **Resource vector.** Qubit-time by qubit class is the base. Qubit classes
  are register classes: a target declares tiers of quality with costs, and
  allocation chooses a class the way a register allocator does. Garbage
  carries an occupancy cost per qubit-second. Targets may add energy,
  routing, T, Clifford, measurement, or anything else; the ISA does not
  enumerate resources, the target description does.
- **Public standard.** The ISA document and the dialect are versioned
  specifications with a conformance suite. (Yes, xkcd 927. A standard is
  what people use; the point is that the spec exists so a vendor can target
  it without us.)
- **Dirty ancillae are a first-class resource**, with no analogue in the
  current code or in Sturm.jl's clean-|0⟩-only allocation.

## 5. Scenes from the finished thing

**The REPL.** Define a Julia function. Do not compile it. Write
`when(q) do f(x) end` and it runs, in a simulator or on hardware, because
compilation is invisible, incremental, cached by world age, composable.
Quantum registers are REPL values with lexical lifetime. `@cost f(x)` prints
T-count, T-depth, logical qubits, and wall time on a named hardware model,
the way `@time` prints allocations. Redefine `f` and everything downstream
recompiles. Hand a compiled function to another function as an ordinary
callee. The Lisp image, holding reversible objects with cost certificates.

**The toolchain.** A plugin flag beside clang. Point it at a mature
codebase: one reversible object per translation unit, a linker that
resolves symbols structurally, and a coverage report honest to the
instruction (lowered / trapped / shimmed). Partial compilation is a region
annotation, and the toolchain is provably the identity on everything
outside it. The kernel compiles, boots on the VM, writes a serial console,
and un-boots to the reset vector.

**The device.** The quantum VM as described in §4, implemented as a device
runtime the way a GPU runtime is: host code at native speed, only the
reversible region pays for reversibility.

**The compiler is optimal, and knows it.** Optimality is defined against a
target description. The compiler chooses adders, pebbling, measurement-based
versus unitary uncomputation, QROM versus QRAM, under a space budget, and
emits a proof-carrying circuit. Small kernels are exactly synthesised and
provably minimal; large ones carry closed-form bounds. Every artefact is
differentially verified against native execution of the same binary, so
"it compiles" and "it is correct" are the same statement. Ancilla-zero is
not correctness: every historical S0 in this project passed a
reversibility check.

**The ecosystem.** A registry of reversible libraries with cost
certificates: libc, libm, zlib, crypto, SQLite, published as linkable
virtual-ISA objects so nobody compiles them twice. Arithmetic is library
code too (§6).

## 6. The right language for each job

| Component | Language | Why (taste excluded) |
|---|---|---|
| Pass plugin (taint, outlining, lowering to the virtual ISA, optimising scheduler) | **C++** | The only component that links LLVM. Two hard facts: the pass-plugin entry point clang/rustc load is a C++ ABI (no C API registers a new-PM pass); and every analysis the plugin needs (loop info, dominators, scalar evolution for bounds, alias analysis, MemorySSA, the code extractor for outlining, cost-model hooks) exists only behind the C++ API. The current repo is the evidence of avoiding this: it reimplements loop/topo analysis in `src/lowering/cfg.jl` and parses MemorySSA out of printed text in `src/memssa.jl`. Enzyme is C++ for this reason and no other. Built per LLVM version, as Enzyme is. Kept narrow. |
| Virtual ISA spec, VM / device runtime, circuit specialiser, resource estimator | **Rust** | None of these touch LLVM: they consume the ISA's serialised form. Embeddable device library with no runtime; memory safety in a component that must never crash a host; usable without std near kernels; a JIT tier available without LLVM; ownership types that model qubit linearity natively. One codebase holds both executors, so one semantics by construction. |
| Front door, REPL, Sturm bridge, research laboratory | **Julia (Bennett.jl)** | The REPL experience is the product's face; LLVM.jl runs the same plugin in-process; new lowerings and arithmetic are prototyped here against the spec. |
| Arithmetic and runtime libraries (adders, multipliers, QROM, soft-float, allocator shims, libc) | **Any** | They are ordinary code compiled through the same pipeline and shipped as virtual-ISA objects with cost certificates. "Runtimes are libraries" applies to arithmetic too; the specialiser links them. The prototyping language stops mattering. |

Consequence: the centre of gravity leaves Julia. Bennett.jl is the front
door of Bennett, not the whole of it. The maintainer has stated this is
acceptable; the north star outranks language preference.

### 6.1 Many small repositories, two contracts

**A monolith will grind to a halt** (maintainer, 2026-10-28). The
blueprint's "one workspace, several packages" is replaced by **independent
repositories, each developable, versioned, tested, and released on its
own**, communicating only through two published contracts: the **dialect
spec** (what the plugin accepts, in LLVM IR) and the **virtual ISA spec**
(what executors accept). Nothing shares code across a contract boundary;
anything that needs to is a sign the boundary is wrong.

| Repository | Owns | Depends on |
|---|---|---|
| `bennett-dialect-spec` | The LLVM dialect: extension types, intrinsics, address space, attribute legality contract, versioning, conformance tests | nothing |
| `bennett-isa-spec` | The virtual ISA: instruction set, resource vector, target-description format, serialisation, formal model, conformance suite | nothing |
| `bennett-plugin` | The C++ LLVM pass plugin: taint, outlining, lowering, optimising scheduler; built per LLVM version | dialect spec, ISA spec |
| `bennett-vm` | The Rust device runtime: run-time scheduler, history layers, effect tape, JIT tier | ISA spec |
| `bennett-circuits` | The Rust circuit specialiser: hierarchical circuit IR, placement, cost certificates, exporters (OpenQASM 3, QIR, Sturm) | ISA spec |
| `bennett-estimate` | Resource estimation from ISA objects and target descriptions, no gates materialised | ISA spec |
| `bennett-targets` | Target descriptions per hardware model, contributed by vendors | ISA spec |
| `bennett-runtimes` | Allocator, libc/musl shims, Julia shim runtime, as ordinary code compiled to ISA objects | dialect spec |
| `bennett-arith` | Adders, multipliers, QROM, soft-float, as ISA library objects with cost certificates | dialect spec |
| `Bennett.jl` | Julia front door, REPL, `@cost`, Sturm bridge, research lab | plugin (binary), ISA spec |
| `bennett-driver` | The clang/rustc-side driver and linker for reversible objects; coverage reports | dialect spec, ISA spec |
| `bennett-conformance` | The demo ladder as executable gates, differential against native | everything, as a consumer only |

Each repository is small enough that one person can hold it in their head,
and each can be replaced by a competitor's implementation of the same spec
without the rest noticing. That last property is the test of whether the
split is right.

## 7. Demo ladder (success criteria, measurable, in order)

1. Scalar C, Rust, and Julia functions, exhaustive at Int8, both executors
   agreeing with native execution.
2. Pointers, structs, byte memory; a C hashtable reversed byte-exactly.
3. musl hello-world: linked, run, un-run to the reset state.
4. **Grover over SQLite.** The predicate is a real SQL query against a real
   database, executed by the actual SQLite engine under a qubit. Nobody
   rewrote SQLite.
5. Julia functions on a shim runtime: `push!` and `Dict` work because the
   allocator works, with zero compiler awareness of either.
6. xv6 boots and un-boots. Then Linux `tinyconfig` to a recorded serial
   console, reversed to the reset vector.
7. **Quantum fuzzing of the kernel.** Amplitude amplification over syscall
   arguments with "the kernel panics" as the oracle. The oracle is Linux.
8. **Amplitude estimation on a Monte Carlo written in plain C** by someone
   who has never heard of a Toffoli gate.

Rungs 1–3 are the blueprint's; 4, 7, 8 are the demos that define success
for the vision; nobody promises 6–8 on a schedule.

## 8. Open technical questions (deferred by the maintainer's rule: vision first)

These are not to be designed in this document. They are listed so the next
iteration can order them.

1. The **legality contract**: the exact attribute set on quantum intrinsics
   and extension types that makes every LLVM transformation either correct
   or conservative on the tainted region (convergent, memory effects,
   noduplicate-style constraints, what `inaccessiblememonly` buys).
2. **Region granularity and outlining**: how `when` / uncompute / adjoint
   regions outline, how the plugin generates controlled and adjoint bodies,
   and how it composes them without blow-up.
3. **Bound certificates**: what they are, who produces them (scalar
   evolution, the user, the runtime), what each executor checks vs trusts.
4. **Loops in superposition**: the padded-to-maximum semantics stated in §4,
   and whether anything better is possible for the VM.
5. **Measurement-based uncomputation under control**: Sturm.jl's
   `PermClean` certificate cannot express it and bans it under `ctrl` by
   type; the reboot needs a cleanliness certificate with classical fixup,
   agreed with Sturm before any gate record freezes.
6. **Reversible ABI and linking**: call/uncall convention, shared ancilla
   frames, structural symbol resolution, content-addressed objects.
7. **Run-time pebbling policy**: history layers, checkpoint interval, delta
   quality, as resource policy under the vector of §4.
8. **Virtual ISA serialisation and versioning**; the conformance suite; the
   formal model's scope (abstract semantics and the round-trip theorem).
9. **Julia in-process loading** of the C++ plugin through LLVM.jl's pass
   manager.
10. **Per-LLVM-version builds** of the plugin (clang, rustc, and Julia pin
    different LLVM majors).
11. Floating point (soft-float as a library, as today), concurrency
    (sequentialised with a recorded schedule, as the blueprint proposes),
    self-modifying code, signals, setjmp.
12. Repository hosting and release mechanics for the split in §6.1
    (organisation, naming, per-repo versioning against the two specs).

## 9. Process

Blueprint first, iterate in discussion, then design, then spikes, then
code. The current Bennett.jl and BennettVM.jl are frozen as the v1 reference
and differential oracle. No reboot code is written on the strength of this
document. Worklog, beads, red-green, exhaustive verification, no remote CI
carry over unchanged.
