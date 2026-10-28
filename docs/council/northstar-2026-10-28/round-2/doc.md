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
