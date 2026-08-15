# Bennett v2 — Reimplementation Plan (PRD draft)

**Date:** 2026-08-15. **Status:** plan, awaiting maintainer sign-off on the four open
decisions in §8. **Provenance:** synthesised from a 14-agent sweep (5 research agents on
Julia 1.13 / LLVM 20 / ecosystem precedents; 8 review agents over the full codebase and
all 107 worklog chunks; 1 completeness critic). Full reports archived at
`docs/design/rearch-2026-08/` — every claim below cites one of them.

---

## 0. The verdict, honestly stated

Yes, reimplement — but the sweep changes what "from scratch" means. The codebase is not
uniformly rotten; it is **two very different halves welded together** (c7):

- The **back half** (~10k LOC: gates + wire-partition invariant, Bennett construction,
  the arithmetic circuit library, QROM, soft-float, simulator/diagnostics) is
  substrate-independent, literature-grounded, exhaustively tested, and is the project's
  research content. It gets **ported**, not rewritten. Regenerating it would be free;
  re-*verifying* it would not (c7 §4).
- The **front half** (`src/extract/`, ~18k LOC, 46% of `src/`) is not an LLVM IR reader
  but a *decompiler for Julia's codegen output*: 8,143-line `instructions.jl` whose
  function names are bead IDs, GC-skeleton recognisers keyed on mangled symbol names and
  hard-coded frame offsets, and a wall/marker treadmill that is locally converging and
  **globally diverging** — eleven walls cleared to extract ONE `push!` program, cost per
  wall rising, wall 12 already "silent, no wall" (c7 §5c). It gets **replaced**, and
  most of it gets replaced by *deleting its job* (see D0).
- The **middle** (lowering) has excellent circuit algorithms trapped inside a driver
  with verified soundness bugs (`add=:cuccaro` aliasing, dead liveness analysis, silent
  phi fallthroughs, a strategy layer that is provably unreachable in production — c2,
  c3). It gets **redesigned** around a new IR.

The critic's framing note is the plan's spine: *the sweep's loudest debate (substrate)
is downstream of its quietest omission (scope)*. Decide the input contract first and
half the substrate argument evaporates — the recogniser tier that dominates the cost
table is deleted on independent grounds by c1, c5, and X6 regardless of substrate.

One number to retire immediately: the "modern Julia fixes this" hope is mostly false
for 1.13. Native sub-byte ints (`Int2`) merged to master **after** 1.13 branched, are
self-described "preliminary, not quite safe", and odd-width *arithmetic* intrinsics are
untested upstream (r2). 1.13's real payload for Bennett is the silent LLVM 18→20 bump
plus two Julia codegen changes (#61535 cascaded bounds-check CFGs, #61394 systematic
memory-attribute propagation) that land precisely on the two areas CLAUDE.md flags as
highest-risk (r1, r4). IRCode-as-substrate is empirically *less* stable than LLVM IR
(Mooncake needed ~91 commits for one minor-version port; JET caps versions per release;
Compiler.jl v0.1 is an explicit placeholder — r3).

---

## 1. D0 — The input contract (decides everything else)

**Bennett v2.0 compiles:** pure Julia functions over `Int8..Int64` / `UInt8..UInt64` /
`Bool` / `Float64` (via soft-float) and tuples/immutable structs thereof; `if`/`else`
and diamond CFGs; loops with a static trip bound; calls (inlined or reversible-call,
D3); memory **only** via an explicit `RegFile{N,W}` API (D4). `bit_width=W` is a real
lowering parameter (not a post-hoc IR rewrite), covering the Int2/Int4 use case until
native odd-bit ints are trustworthy upstream (r2's revisit trigger: odd-width
*arithmetic* intrinsic tests landing in Julia, not merely "1.14 ships").

**v2.0 refuses, loudly and permanently (the RED ladder):** `Vector`/`Dict`/`push!` and
all heap recognition, dynamic allocation, exceptions (NaN/flag policies instead),
unbounded recursion, dynamic dispatch, `String`, Float32 arithmetic (still rejected —
the double-rounding contract from Bennett-3rph stands until native 24-bit kernels
exist).

**Deliverable:** a conformance ladder modelled on `test_memory_corpus.jl`'s L0–L10,
generalised to the whole language, with GREEN and RED entries. This document *is* the
substrate-tax boundary: under it, c7's "7,400 LOC substrate tax" prices out at ~2,900
LOC of honest ABI handling (X1), and walls 6–14 never exist.

Julia-collection support does not "move to v2.1" as recognition. X6's adjudication is
the permanent design position: **even with perfect type information, a growable heap is
not reversible** — the only honest semantics is a statically-bounded register file. If
collection *sugar* ever returns, it is a front-end lowering of `Vector`-shaped source
onto `RegFile`, declared as such, never a byte-pattern recogniser.

## 2. D1 + D2 — BennettVM and the substrate

**BennettVM (recommendation, needs sign-off — §8):** freeze v1 for it. v1 lives on a
protected branch; BennettVM's path dependency + documentary pin (`BENNETT_JL_PIN.md`)
is replaced by a real pin against that branch. v2 ships **`BennettIR.jl`** as a
versioned package with an explicit schema version and a stage-boundary validator;
BennettVM migrates when it chooses, or never. Its requirements get elicited (spike S6)
*before* BennettIR's memory nodes freeze. This ends the current situation where an
unversioned struct shared across two repos is the ABI and BennettVM de facto owns
Bennett's front-end roadmap (c7 §1.5).

**Substrate: keep LLVM IR.** All four relevant reports converge after the critic's
netting (X1): IRCode churns worse (r3), tracing/MLIR substrates cannot see both branches
of an `if` — disqualifying for a MUX compiler (r5); and the existing lowering tier maps
1:1 onto LLVM's bit-width-explicit instruction set. Three changes, though:

1. **Kill the text round-trip.** Today's substrate is literally
   `sprint(code_llvm) |> parse(LLVM.Module, _)` (entry.jl:59,96) — the exact
   instability CLAUDE.md §5 forbids, at the serialisation step. v2 acquires the module
   behind a narrow `acquire_module(f, types)::LLVM.Module` interface. Spike S1
   determines the mechanism (in-context C-API acquisition, GPUCompiler-*style* hook
   limited to module acquisition + pass control — explicitly **no** overlay method
   tables or world-age tricks, the parts that actually break, per julia#44174 / r5).
   If the spike fails, the textual path survives *behind the same interface* as an
   acknowledged stopgap; the interface is the commitment.
2. **The inference type-oracle is deferred, by construction.** Under D0's contract the
   list of facts it would supply is nearly empty (X1's gating test). The BennettIR seam
   keeps c7's Candidate B and even Candidate C recoverable later without touching the
   back half.
3. **`.ll`/`.bc` ingest stays.** It is cheap once lowering is LLVM-shaped, it keeps the
   T5 C/Rust corpus and the VISION taint contract alive, and it is the argument that the
   front end is swappable.

Recorded revisit triggers: a non-placeholder, version-pinnable Compiler.jl release;
JuliaLowering.jl production-readiness; odd-bit arithmetic tests upstream.

## 3. D3 — The IR (the centre of the rewrite)

Two IRs, both new, both closed sum types with versioned schemas, no sentinel-field
discriminators (the IRRet/`offset_bytes` disease — c1/c7 A4), and `Bits`/`Bytes`/
`ElemIndex` newtypes (unit confusion is the most common historical bug class, c8).

**BIR (program level, replaces ParsedIR):**
- Every effectful op carries a **first-class guard predicate**. Phi-joins become
  explicit predicated merges with a **checkable mutual-exclusion + coverage
  obligation**, discharged by BDD/SAT *at compile time, before any gate exists*
  (c2's second mechanism; X4 layer 1). This is the structural fix for false-path
  sensitization — the project's signature bug class — replacing an argument in a
  docstring with a checked property. StructurizeCFG-based if-conversion is layer 2,
  used opportunistically iff spike S3 shows it available and robust; CFGs neither
  layer handles fail loud (layer 3).
- A **Call node with a reversible call/uncall convention and shared ancilla frames**
  (G8 — the largest gate-count lever named in the sweep and present in nobody's v1
  design; today `lower_call!` re-emits ~149k gates per `soft_fmul` call site and
  discards the user's options, c2/c4).
- Float ops and intrinsics (`fadd`, `fcmp`, `ctpop`, transcendentals) are **IR nodes
  lowered by tables**, not callees expanded inside the extractor (X5's decision:
  today `llvm.ctpop.i64` becomes ~257 IRInsts inside the parser, invisible to
  strategy). The soft-float library becomes a lowering table's implementation detail.
- `RegFile` read/write as first-class ops with the guard field (D4).

**Circ (circuit level, from c3's draft, extended):** one 16-byte isbits `Gate` record
on a shared arena; hierarchical nodes `Prim/Seq/Adj/Compute/Ctl/Scope` **plus `Call`**
(frame-sharing, G8). Uncomputation is *structure, not materialised gates*:
`gate_count(Adj(c))` is closed-form, `soft_sin` memory halves, ancilla-cleanliness of
`Compute` nodes is true by construction (Quipper `with_computed` / Q# `within/apply`
precedent), and `Ctl(Compute(...))` rewrites to control-only-the-copy — deleting the
measured 6.3× controlled-circuit T-count blow-up that Sturm would otherwise pay (c3).
The gate record's alphabet is frozen only after D9.

## 4. D4 + D5 — Memory and scheduling

**Memory:** one abstraction, `RegFile{N,W}`, an SSA-threaded value with two
unary-iteration primitives (read/write; 2(N−1) Toffoli, T-count independent of W —
the construction already exists in `qrom.jl` and was never applied to the writable
path), guard as an IR field, const-index as a compile-time specialisation of the same
primitive, and a select-swap/QROAM variant as the ancilla-vs-T knob. This replaces the
five accreted models and the `N·W ≤ 64` shape lattice (~5,000 LOC → ~600, with the
dispatcher's stated priority currently *backwards* by 15–40× — c5). **Precondition:
spike S2**, because the 10–200× improvement claim is asymptotic, not measured (G4).

**Scheduling:** the six Bennett strategies are measured to be dead or no-ops in the
shipped pipeline (four unconditionally fall back because `fold_constants=true` erases
gate groups; `PebbledStrategy` is provably the identity at O(n³s) cost — c3, X2). The
root cause is architectural: wire indices freeze before any strategy runs, so no
strategy *can* reduce wires. v2: lowering emits `Circ` over **symbolic wires**; a
single **placement/scheduling pass with a space budget** assigns physical indices,
using Knill's DP as its cost model, choosing where to insert `Compute` checkpoints.
Acceptance criterion the current system provably cannot meet: **it reduces `n_wires`
on a real circuit.** The space–time research content survives — relocated to the one
place it can act.

## 5. D6 — Soft-float

Sequenced, per X5 — port, then shrink:

1. **Port verbatim into standalone `SoftFloat.jl`** (zero deps — it is plain Julia,
   c7 §5b) *with its test conventions first*: the subnormal-output binade sweeps, raw
   `UInt64` bit fuzzing (seeded — 27 of 49 files currently never seed, c6), NaN
   bit-pattern (never `isnan`) comparison, INDEF pins, boundary triples, per-tier
   bit-exactness contracts stated explicitly (A/B bit-exact vs hardware; C ≤1–2 ulp;
   the `*_julia` tier D and its `@noinline Base.pow_body` coupling documented as the
   fragile thing it is — c4). Add the missing assertion: **no `br` in generated
   soft-float IR** (the library's headline invariant is currently untested and
   already violated by `soft_pow_julia`).
2. **Then restructure:** width-parameterised `unpack`/`pack_round` (f32/f16 become a
   type parameter — the principled path to retiring the Float32 rejection), the
   transcendental kernel generator generalised from the in-tree prototype
   `_exp_impl_julia`, and the ~1,200 hand-transcribed table constants regenerated from
   upstream (musl / ARM optimized-routines / FreeBSD SunPro) into a checked-in artefact
   with a regeneration test **and attribution** (G9 — do this now, awkward later).
3. **Then delete what native lowering obsoletes:** once D3's float IR nodes and the
   call/uncall convention land, tiers C/D shrink or go; the branchless-source
   contortions (the SLP-dodging "qpke gotcha") die with the extractor that forced them.

## 6. D7 + D8 — API, verification, tests

**API:** one `CompileSpec` struct that is the *only* representation (v1 has five —
c6); stage-scoped options (`ExtractOptions`/`LowerOptions`/`SynthOptions`, c7 §4-R2)
so no symbol crosses a boundary it doesn't belong to; targets as types
(`CircuitTarget`/`VMTarget` methods, not a `Ref{Any}` hook); the word "strategy"
retired in favour of **schedule** (how to uncompute) and **objective** (what to
minimise); a `CompilationSession` object replacing all module-global caches.

**Verification — the first code written in the rewrite is the oracle.** c8's meta-bug
is the ledger's sharpest lesson: `verify_reversibility` was *tautological* for months
(forward∘reverse of self-inverse gates always returns the input) and hid five real
bugs including a 100% ancilla leak on every branching function. **Ancilla-zero is
asserted after the FORWARD pass**, before anything else exists; everything written
before a sound oracle is validated by nothing. Then three tiers (c3):
- *Tier 0, by construction:* `Compute`/`Scope` make cleanliness structural; only
  hand-written self-reversing primitives carry runtime contract checks.
- *Tier 1, property-based:* `verify(f, c; rng=StableRNG(seed), n)` — functional
  equivalence vs the Julia oracle + invariants, seed printed on failure, shrinking,
  with generators aimed squarely at diamond-CFG/phi shapes.
- *Tier 2, algebraic:* ANF/BDD symbolic simulation for kernels ("ancilla ≡ 0" as a
  polynomial identity, exhaustive in one pass) and a SAT miter for
  circuit-vs-source equivalence. Local solvers; CLAUDE.md §14 forbids remote CI, not
  SAT.
- Exhaustive Int8 stays as the smoke tier — 4 passes under the **bit-sliced
  simulator** (64 inputs/pass, ~50 LOC, plausibly the highest-ROI single change given
  the 28-minute sweep-dominated suite).

**Test architecture:** directory-discovered, cost-tiered, **parallel by
construction**, with the G12 mechanism designed in: precompile once, then spawn
workers against a read-only shared depot (respecting the standing
no-concurrent-Julia-precompile constraint), `--check-bounds=yes` inherited by every
worker. Baselines become one **machine-generated, environment-stamped file**
(julia_version, llvm_version, schedule) + asserted scaling *relations*
(`total(2W)=2·total(W)−2`, `T(2W)=2·T(W)+4`), per X3: the week-1 exact-reproduction
gate applies only to the legacy-equivalent configuration; after that, relations + a
reviewed baselines diff are the mechanism. c8's four executed miscompiles (the
`store ptr %a, ptr %a` self-store; the arena-adjacency false-disjointness; the
capacity-certification gap; the cross-function scale re-stamp) become named
acceptance tests for any v2 memory/alias code. The full lessons ledger
(`docs/design/rearch-2026-08/c8-lessons-ledger.md`, 103 entries) ships in v2's docs
on day one.

## 7. D9 — The output contract (decide before the Gate record freezes)

The sweep's biggest blind spot (G2): nobody examined what a circuit is *for*.
Recommendation, pending Sturm.jl requirements (spike S6):
- Core alphabet stays {X, CX, CCX}, but the `Gate` record and cost model admit
  **MCX-k** natively.
- **Measurement-based uncomputation (Gidney temporary-AND) must be representable** —
  as an alternative lowering of `Compute`'s adjoint half, which halves T-count on
  exactly the compute/copy/uncompute pattern Bennett generates and which a pure
  bit-vector permutation model cannot express. Backends may decline it; the IR must
  not make it unrepresentable.
- `t_count`/`t_depth` get an explicit, documented Toffoli→T decomposition artefact
  behind them (today they are numbers with no construction, G2c).
- Serialisation: the versioned BennettIR/Circ schema is the interchange format;
  OpenQASM 3 export for interop.

## 8. Open decisions needing the maintainer (everything else is committed)

1. **BennettVM disposition** — freeze-on-v1-branch + versioned BennettIR migration
   path (recommended), vs. co-develop v2 with BennettVM as a launch consumer.
2. **Gate alphabet / Sturm contract** (§7) — needs a read of Sturm.jl's actual
   interface; S6 drafts it, you confirm.
3. **Where v2 lives** — recommended: a fresh workspace with the five packages
   (`ReversibleCircuits.jl`, `ReversibleArithmetic.jl`, `SoftFloat.jl`,
   `BennettIR.jl`, `BennettLLVM.jl`) and `Bennett.jl` as the thin meta-package; v1
   repo untouched throughout. Alternative: `v2/` subtree here.
4. **Language neutrality** — the plan keeps `.ll`/`.bc` ingest (cheap under D0); if
   you'd rather declare v2 Julia-only, Candidate C's extra leverage becomes available
   but the VISION taint contract must be restated.

## 9. Week-0 spikes (each de-risks a committed decision; none is optional)

| # | Spike | Gates |
|---|-------|-------|
| S1 | Install 1.13-rc3; run the gate-count + IR-shape battery; diff #61535 bounds-check CFGs and #61394 memory-attr population; prototype non-textual module acquisition | D2, X3's baseline caveat, G3 |
| S2 | RegFile read/write prototype on today's `qrom.jl`, measured against the BENCHMARKS corpus entries | D4 (the 10–200× claim) |
| S3 | StructurizeCFG availability/behaviour via LLVM.jl on Julia-emitted IR, incl. irreducible CFGs | X4 layer 2 |
| S4 | Profile one `soft_sin` compile end-to-end (extract vs lower vs wires vs bennett) | which of D3/D5/G8 dominates (G7) |
| S5 | Parallel-test depot mechanism (precompile-once + read-only depot) — benefits v1 today via Bennett-gm83 | D8, G12 |
| S6 | Read Sturm.jl; elicit BennettVM's actual ParsedIR requirements | D1, D9 |

## 10. Staging (the hard gate every report converged on)

**Nothing enters the new front end until the back half reproduces every
legacy-equivalent pinned gate count and every soft-float bit-exactness test from
hand-built IR, with zero LLVM in the tree.** The back half is the asset; the front
end is the liability. Build order:

- **P0** — spikes S1–S6 (~1 week).
- **P1** — `ReversibleCircuits.jl`: Gate arena, Circ IR, *sound verifier first*,
  bit-sliced simulator. Gate: legacy-equivalent baselines from hand-built IR (as
  re-measured on 1.13 in S1).
- **P2** — `ReversibleArithmetic.jl` port + the placement/scheduler pass. Gate: cost
  formulas reproduce; scheduler reduces `n_wires` on a real circuit.
- **P3** — `BennettIR.jl`: predicated BIR + validator + call/uncall + RegFile ops;
  lowering tier. Gate: diamond-CFG property tier green; mutual-exclusion obligation
  discharged mechanically; c8's four miscompiles pass as tests.
- **P4** — `BennettLLVM.jl`: narrow-scope front end, no recognisers, no text
  round-trip; `.ll`/`.bc` ingest. Gate: conformance ladder GREEN entries compile,
  RED entries refuse loudly; T5 corpus subset passes.
- **P5** — `SoftFloat.jl` port (conventions first), then native float lowering.
  Gate: full bit-exactness battery; `sin(f64)` end-to-end with call/uncall sharing —
  expected order-of-magnitude gate-count drop vs 11.0M (measured, not assumed).
- **P6** — API surface, parallel test tiers, docs; v1 → v2 migration notes.

Rough scale: 6–9 weeks of agent time. Process rules carry over wholesale: worklog
discipline, beads, red-green, 3+1 for core changes (referents updated to the BIR /
lowering / scheduler files), exhaustive verification, **no remote CI**. Honesty
clause, carried from the critic: three of this plan's inputs (StructurizeCFG, the
RegFile win, the whole 1.13 risk picture) are currently *unverified inferences with
cheap spikes attached* — that is why §9 is not optional, and why P0 precedes any
commitment the spikes could falsify.
