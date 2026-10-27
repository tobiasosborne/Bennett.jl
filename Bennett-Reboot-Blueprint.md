# Bennett + BennettVM — Reboot Blueprint (DRAFT, for iteration)

**Date:** 2026-10-27. **Status:** discussion draft, NOT ratified. Written
up from a maintainer/agent design discussion the same day; the maintainer
verdict on this draft was "feels ok, does need a bunch of iterations."
Nothing here supersedes `Bennett-V2-PRD.md` until the maintainer says so;
where this draft and the V2 PRD differ, the difference is flagged.

**Provenance:** a from-scratch reimagining of Bennett.jl + BennettVM.jl,
grounded in (a) a read of both codebases' main files, (b) the 2026-09-26
Astra review campaign (`reviews/2026-09-26-astra/`, VM reports in the
BennettVM repo), and (c) the 14-agent rearchitecture sweep behind
`Bennett-V2-PRD.md` (`docs/design/rearch-2026-08/`).

## Maintainer decisions recorded in the discussion

1. **North star (scope):** Bennett.jl + VM work for *any* LLVM language —
   C, Rust, Julia. The dream state: **the full Linux kernel compiles**
   (perhaps not efficiently, but it does). This explicitly rejects both
   the V2 PRD's D0 strict-declared-subset contract as the *system-level*
   scope, and a VM-first / formal-verification-first / neutral-tooling
   framing as the centre of gravity. Strictness moves down a level: the
   IR contract is strict and total; universality is a system property
   built on top of it (see §3).
2. **Structure:** one workspace, several packages, VM co-designed against
   a versioned IR from day one. Current repos frozen as v1
   reference/oracle.
3. **Process:** blueprint in discussion first (this file), iterate,
   before any implementation or spike work.

## 0. The one-sentence version

Today: two backends, two duplicated semantics, and a front end that
*recognises* what Julia's runtime is doing and deletes it. Reboot: **one
total, byte-addressed, effect-explicit IR with a single semantics;
runtimes are ordinary code that gets compiled, never patterns that get
recognised; the VM is the universal executor and the circuit is an
optimising specialisation of it.**

The kernel north star makes this forced rather than aesthetic. A fixed
circuit cannot be the universal target — the kernel is unbounded,
interrupt-driven, and self-modifying at the edges. So universality lives
in the VM, and "the kernel compiles" must mean something precise:

> Every LLVM module ingests with a complete coverage report, links,
> executes forward on the VM, and un-executes to its exact initial
> state — with the outside world (MMIO, interrupts, timer, entropy)
> supplied and recorded on an effect tape.

Efficiency is explicitly not promised. Correctness and totality are.

## 1. Why the current shape cannot get there

Three structural choices in the present code are each, alone,
disqualifying at kernel scale:

- **Recognisers.** `src/extract/heap.jl`, `dict_vm.jl`, `vector_vm*.jl`
  classify IR as runtime machinery and drop it. At kernel scale there is
  no recogniser for "the scheduler" — and every misclassification is a
  silent wrong answer, which is the entire Astra S0 list in that tier
  (Bennett-7v22 / bc2m / po36 / o6ge / q5hc).
- **Cell-addressed memory.** The VM's Int64 cells, the circuit's wire
  groups, and LLVM's bytes are three different memory models, and the
  seams between them (`ptr_cells`, `mem=:vm/:heap/:persistent`,
  width-stamping) generated a disproportionate share of both codebases'
  bugs. A kernel does byte pointer arithmetic in its sleep.
- **Whole-program closed-world extraction.** The kernel is separate
  compilation and linking, thousands of modules. A pipeline that starts
  from one Julia function and chases transitive callees does not scale
  to it even in principle.

For scale, the current trees measure (2026-10-27): Bennett.jl 45,853
LOC src / 68,436 test, of which `src/extract/` is ~18k LOC and
`extract/instructions.jl` alone is 8,615 lines with bead-ID function
names (`_57hd_certified`, `_p06b_slot_key`); BennettVM.jl 17,275 /
32,618, with `interpreter/Interpreter.jl` at 1,890 lines the standout.

## 2. Assessment carried into the reboot (summary)

The Astra verdict "sound core, unsound perimeter" is substantially
right on findings (all S0/S1 independently re-executed before beading),
with three qualifications from the 2026-10-27 review:

- The headline finding count inflates: nine overlapping scopes re-find
  each other, and several extract S0s are `from_ll`-only. Read it as
  ~80 distinct defects, not ~150 findings.
- "Sound core" needs scoping: compile-cache staleness, tabulation
  truncation, `controlled()` unsigned decode, checkpoint replay bit
  permutation, and QCLA self-CNOTs on `x+x` are public-API wrong
  answers, not perimeter. What is sound: the Bennett construction
  itself, the gate algebra, the arithmetic generators, soft-float core
  ops (1.8M raw-bit comparisons green under Astra's own probes).
- The defect *rate* is structural: 45 Astra beads closed in the
  2026-10-03/04 campaign, 36 remain open, and follow-up Sol reviews
  immediately found more of the same class (Bennett-sl4h narrowing).
  A recogniser-based front end produces this class indefinitely; that
  is the architectural fact the reboot has to remove, not a backlog
  to burn down.

## 3. The architecture

### 3.1 BIR — one IR, defined by its semantics, not by its producers

A small, closed, versioned IR. Byte-addressed sparse memory.
Integer-typed SSA values with explicit widths (`Bits`/`Bytes`/
`ElemIndex` as distinct types — unit confusion is a top historical bug
class). Every effectful operation carries a guard predicate. Phi-joins
are explicit predicated merges with a *mechanically checked*
mutual-exclusion-and-coverage obligation — the false-path sensitisation
class dies at validation time, before any backend runs.

Three policies fixed in the spec, because "any LLVM" forces them:

- **Undef/poison are concretised, and the choice is recorded.** BIR
  execution is deterministic given the effect tape; where LLVM leaves
  a value open, the VM draws from the tape so reversal replays the
  same choice. No silent zero-fill, no trusting names (the Bennett-hsm3
  `jl_global#N` lesson).
- **Atomics and concurrency are sequentialised with a recorded
  schedule.** Forward execution records the interleaving actually
  taken; reversal replays it — the rr lesson as a language semantic:
  record nondeterminism, replay determinism. SMP kernel boot becomes
  possible in principle on day one, at whatever speed it runs.
- **Inline assembly is an effect**, dispatched to a per-architecture
  shim library with explicit clobber semantics. Unshimmed asm is a
  coverage-report line, not a crash and never a deletion. The honest
  metric is "% of tinyconfig covered," trending up.

The reference semantics is a slow, obviously-correct interpreter
written first, plus a Lean model of BIR small enough to actually
finish — abstract semantics and the round-trip theorem, not the
implementation. (BennettVM's existing bounded-Lean scope carries over.)

### 3.2 Ingest is total, and deletes nothing

`BennettLLVM.jl` lowers LLVM to BIR per-function, via the C API
in-process (no `sprint(code_llvm) |> parse` text round-trip — the V2
PRD D2 item). Every LLVM instruction either lowers or becomes an
explicit unsupported-trap node listed in a coverage report. That
report — instructions lowered / trapped / shimmed, per module — is a
first-class build artefact and the scoreboard for kernel progress.

Per-instruction refinement is tested Alive2-style against LLVM
semantics, and end-to-end against native execution (`lli`, clang
binaries — the BennettVM 6502-emulator harness generalised).

### 3.3 Runtimes are libraries, not recognisers

The single biggest deletion. Julia support stops meaning "recognise
the GC skeleton and suppress it" and starts meaning what C support
means: a runtime — allocator, GC-free subset shims, the `jl_*` entry
points that matter — implemented in ordinary code, compiled to BIR,
linked in. Same for musl/libc. A `push!` then works the way `malloc`
works: real allocator code runs on real VM memory, forwards and
backwards. Slowly. Correctly. The eleven-wall treadmill is replaced
by a shim-coverage list, which only ever shrinks.

Growth of language coverage happens *here*, in libraries, never again
in the compiler. This is how the maintainer's universal scope and the
V2 PRD's strictness are both satisfied: strictness at the IR level,
universality at the system level.

### 3.4 Two executors, one semantics

- **The VM** is the universal executor: three-layer history
  (injective / delta / checkpoint-replay), but injectivity is a
  *proved analysis result with a certificate*, not a hand-maintained
  type table (the bennettvm-6xy0 failure mode). Checkpoint+replay is
  the always-available fallback, so every BIR program reverses from
  the day ingest lands; the cleverer layers are pure optimisation,
  differentially tested against the fallback forever. Forward-oracle
  property testing (bennettvm-tghl's lesson) is built in from the
  start, whole register file, not declared returns only.
- **The circuit backend** is a specialiser: given boundedness
  certificates (loop bounds, recursion depth, memory budget — proved,
  or supplied and enforced by guard wires), it partially evaluates a
  VM program into a hierarchical circuit IR (`Compute`/`Adj`/`Ctl`/
  `Call` nodes over a gate arena, symbolic wires, one
  placement/scheduling pass with a space budget — the V2 PRD's D3/D5
  design survives intact). Unbounded input is a loud refusal naming
  the missing bound.

One semantics, two executors, permanent differential testing between
them. The current duplicated lowering (`src/lowering/` for circuits,
BennettVM `ingest*.jl` for the VM, drifting apart) ceases to exist.

### 3.5 Separate compilation and a reversible ABI

Functions compile independently to BIR object files with a
call/uncall convention and shared ancilla frames; a BIR linker
resolves symbols *structurally* (interned IDs, never bare-name string
matching — Bennett-p9a0 / wh1p / xzsb die as a class). Content-addressed
caching under an explicit `CompilationSession`; no module-global
caches, so method-redefinition staleness (Bennett-4ddk) is
unrepresentable. This also ends per-call-site re-emission of the
arithmetic libraries.

## 4. Packages (one workspace)

| Package | Contents |
|---|---|
| `BennettIR.jl` | BIR spec, validator, reference semantics, serialisation |
| `BennettLLVM.jl` | Total LLVM→BIR lowering, coverage reports |
| `BennettVM.jl` | Fast interpreter, history layers, effect tape |
| `ReversibleCircuits.jl` | Hierarchical circuit IR, scheduler, metrics, QASM export |
| `ReversibleArithmetic.jl` | Adders/multipliers/QROM (ported) |
| `SoftFloat.jl` | IEEE library (ported, tables regenerated) |
| `BennettRuntimes.jl` | musl/Julia/allocator shims as compiled code |
| `Bennett.jl` | Thin meta-package: language front doors, drivers |

The current Bennett.jl and BennettVM.jl repos are frozen as the v1
reference implementation and differential oracle. Whether the new
workspace is a fresh repo or a subtree is an open question (§8).

## 5. Keep / kill / port-then-shrink

**Keep (the research assets):** gate algebra and the wire-partition
invariant; the arithmetic generators (after the alias fixes);
soft-float's bit-level test conventions — subnormal-output binade
sweeps, NaN bit-pattern (never `isnan`) comparison; gate-count
*scaling relations* as regression oracles; the three-layer history
idea; RSSA's phi-on-splits-and-joins insight, baked into BIR; the
6502-style native-oracle harness; pinned target machine for
optimised IR; beads/worklog/red-green/exhaustive-verification
discipline; no remote CI.

**Kill (the accretion):** every recogniser in `src/extract/`
(heap/dict/vector-VM arms); cell-addressed memory and the `mem=` mode
zoo; name-based identity everywhere; sentinel-field IR nodes; the
six-strategy layer (one scheduler replaces it — four of the six are
unreachable under default constant folding today, since
`_fold_constants` clears `gate_groups`); tabulation as a default path
(it survives as an explicit, semantics-preserving pass); the LLVM
text round-trip; bead-ID function names (provenance goes in comments
and ADRs; identifiers describe what code does).

**Port, then shrink:** soft-float moves verbatim with its tests
first; then its ~1,200 hand-transcribed constants are regenerated
from upstream (musl / ARM optimized-routines / FreeBSD) with
attribution and a regeneration test — the `fsin` INV_2PI limb-12
transcription bug (Bennett-6gxm) is what hand-copying costs. The
persistent-map workstream and the `RegFile{N,W}` construction from
`qrom.jl` carry into the circuit backend's memory story (V2 PRD D4,
still gated on spike S2 measurement).

## 6. The road to the kernel, as a ladder

Each rung is a conformance gate; the coverage report is the
scoreboard:

1. Scalar C and Rust functions, exhaustive at Int8, both executors
   agreeing.
2. Pointers, structs, byte memory; the existing C hashtable corpus
   reversed byte-exactly.
3. `musl` hello-world: linked, run, un-run to the reset state.
4. A real C library under its own test suite, forward-and-reverse
   (SQLite is the classic torture test).
5. Julia functions on the Julia shim runtime — `push!`/`Dict` working
   because the allocator works, with zero compiler awareness of either.
6. xv6 booting and un-booting. Then Linux `tinyconfig` to a recorded
   serial console, reversed to the reset vector.

Nobody should promise rung 6 on a schedule. But every rung is
measurable, none requires a new idea, and no rung requires the
compiler to get cleverer about recognising other people's code. The
gap list lives in shim libraries and asm coverage, where work is
additive and never silently wrong.

## 7. Honest costs and risks

- **Interpreter speed is existential.** A kernel boot is billions of
  steps; the VM likely needs a compiled execution tier eventually
  (BIR as semantics, JIT as implementation — the spec must permit it
  from the start).
- **History space at scale** makes checkpoint interval and delta
  quality a resource-policy problem, not a detail.
- **"Compiles" long precedes "boots."** Ingest coverage is
  achievable well before the shim surface closes. The blueprint's
  claim is narrower: under this architecture, remaining work is
  *enumerable from the coverage report*, and nothing on the list is
  a silent wrong answer.
- **Self-modifying code, exceptions/setjmp, signals** need explicit
  BIR-level answers (code as data under a recorded-modification
  rule; non-local control lowered to explicit state; signals as
  effect-tape events). None is designed yet — iteration items.
- **Floating point in the VM** stays soft-float-as-library; no new
  FP-reversibility scheme is invented here (BennettVM PRD position
  stands).

## 8. Open questions for the next iterations

1. Where does the workspace live — fresh repo, or subtree of
   Bennett.jl? (V2 PRD §8.3, still open.)
2. Gate alphabet and the Sturm.jl contract (MCX-k natively?
   measurement-based uncomputation representable?) — V2 PRD D9,
   needs the S6 elicitation before the circuit Gate record freezes.
3. BIR memory model details: provenance tracked (checked mode) or
   flat bytes with provenance only as a debug overlay? Affects both
   VM speed and circuit extraction.
4. What exactly is a boundedness certificate, who produces it, and
   what is checked vs trusted at each executor?
5. Effect-tape format and its interaction with checkpointing
   (tape entries as checkpointable state vs append-only log).
6. Concurrency v1: sequentialised-with-recorded-schedule only, or
   a real interleaving semantics from the start?
7. Weeks-0 spikes, unchanged in spirit from V2 PRD §9: non-textual
   LLVM module acquisition (S1), RegFile measurement (S2),
   StructurizeCFG viability (S3), interpreter throughput ceiling
   (new — this blueprint makes it load-bearing), Sturm/VM
   requirements elicitation (S6).

## 9. Relation to existing plans

- `Bennett-V2-PRD.md` (2026-08-15, parked by maintainer instruction):
  its back-half port list, circuit IR (D3), scheduler (D5),
  soft-float plan (D6), verification tiers (D8), and staging gate
  all carry into this blueprint. Its D0 input contract is revised
  per §1 of the maintainer decisions above: the strict subset
  becomes the *circuit backend's* contract, not the system's.
- BennettVM PRD v4 + ADRs 0001–0023: the three-layer history, RSSA
  grounding, golden-master discipline, and bounded Lean scope carry
  over. The cell-addressed memory model and name-keyed ingest do not.
- Near-term v1 work is unaffected by this draft: the priority order
  from the 2026-10-27 assessment (amah journal flatten; v4iy ULP
  decision; verifier soundness 6xy0; executed silent miscompiles;
  VM re-pin) stands until the maintainer ratifies a reboot.

