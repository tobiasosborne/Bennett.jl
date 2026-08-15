# Completeness critique of the 13-report re-architecture sweep

**Role:** completeness critic. **Date:** 2026-08-15. **Inputs:** all 13 reports under
`rearch/` (c1–c8 read in full or in their verdict/answer sections; r1–r5 read in full for
r3/r5, summaries plus targeted reads for r1/r2/r4).

**Independent verification performed** (so the adjudications below rest on facts, not on
report cross-citation):

| Claim | Verified |
|---|---|
| `src/extract/` size | **18,144 LOC**, 46% of `src/`'s 39,098 (`wc -l`) |
| Text round-trip substrate | `entry.jl:10,60` `sprint(code_llvm …)`; `entry.jl:97,251,309` `parse(LLVM.Module, ir_string)` — 3 parse sites plus a membuf path |
| `mem=:vm` unreachable from `reversible_compile` | `Bennett.jl:232` `mem in (:auto,:persistent,:heap) \|\| throw` — confirmed |
| `ptr_cells` blast radius | 225 occurrences in `instructions.jl` alone |
| `ptr_cells` is *not* cleanly VM-only | `lowering/driver.jl:12`: "`ptr_cells=true` + `lower()` is a live combination in this suite (`test_59zi`, `test_lf14`)" — so the flag reaches the gate backend, which is why `_bvmd_reject_normalised_alloca!` exists |

The sweep is unusually good: the codebase agents measured rather than asserted, and c3, c5
and c2 each found executed defects (spurious `controlled` errors, MUX-EXCH cost inversion,
`add=:cuccaro` unsoundness) that no amount of reading would have produced. What follows is
what it did *not* settle.

---

## 1. GAPS

### G1. Nobody wrote down what v2 must compile.

Every report answers "how" for its own area. None states the input contract. This is not a
stylistic omission — it is the missing premise that makes the substrate argument unresolvable.
On the scope "pure integer/float kernels, bounded loops, explicit reversible memory", the
recogniser tier (c1's products (c)+(d), ~8–9k LOC) has no reason to exist on *any* substrate
and the LLVM-vs-IRCode question shrinks to ~2.5k LOC of ABI handling. On the scope "arbitrary
Julia including `Vector`/`Dict`/`push!`", c7's wall/marker divergence argument is decisive and
the substrate must change. The reports argue substrate *first* and scope *incidentally*; the
dependency runs the other way.

**Close it:** one page, first artefact of the plan, in the shape of `test_memory_corpus.jl`'s
L0–L10 ladder (c5 calls this the closest thing to a memory specification) generalised to the
whole language, with RED entries — the programs v2 must refuse, loudly, forever.

### G2. The output side — the entire reason the project exists — is uncovered.

No report examined how a `ReversibleCircuit` reaches a consumer. There is no area for export,
gate-set selection, or the Sturm.jl interface. Nobody read Sturm.jl. Concretely missing:

- **Gate set.** v1 fixes NOT/CNOT/Toffoli. c3 proposes a 16-byte `Gate` record with "room for
  MCX-k, SWAP later" — but whether MCX-k, Clifford+T, or measurement-based primitives are in
  the target alphabet is a *product* decision that determines the record layout, the cost
  model (D5), and every gate-count baseline.
- **Measurement-based uncomputation is not representable at all.** Gidney's temporary-AND
  (measure + classically-controlled fixup) is the standard way to halve T-count on exactly the
  compute/uncompute pattern Bennett generates, and the current gate model — a permutation of
  bit-vectors — cannot express it. For a project whose stated destination is quantum control,
  no report raised this. It may or may not be in scope; it must be *decided* before c3's gate
  record is frozen.
- **`t_count`/`t_depth` exist in `diagnostics.jl` with no export path.** The Toffoli→T
  decomposition is implicit, so the numbers published in BENCHMARKS.md have no artefact behind
  them.
- **The `when(qubit) do f(x) end` contract.** c5 §5d is the only treatment and it covers only
  the memory side. `controlled.jl`'s 6.3× T-count blow-up (c3) is presented as a circuit-algebra
  defect; it is equally a statement about what Sturm will actually pay, and nobody checked what
  Sturm expects to receive.

### G3. There is no empirical Julia 1.13 / LLVM 20 data anywhere in the sweep.

r1, r2, r4 are changelog and PR archaeology — good archaeology, but 1.13 is not installed on
this machine and nothing was run against it. r4 explicitly recommends a half-day spike and it
was not performed. Unmeasured, and each one can invalidate a plan decision:

- Whether the pinned gate counts (58/114/226/450) move under LLVM 20 **before any v2 code is
  written** (c6 §3.1 shows they are downstream of Julia's codegen, not just Bennett's lowering).
  If they move, c7's week-1 acceptance gate fails for the wrong reason.
- Julia PR #61535's cascaded per-dimension bounds-check CFG (r4) landing on the phi resolver —
  the project's declared #1 correctness risk — under the `--check-bounds=yes` mode CLAUDE.md
  mandates.
- Julia PR #61394's systematic purity→`memory(argmem: read)` attribute propagation (r4) hitting
  the raw packed-integer `memory`-attribute decoder at `instructions.jl:2013` at a population it
  was never tested against.

**Close it:** install 1.13-rc3 alongside 1.12.5; run extraction+lowering over the ~130
non-bead-named test files; diff CFG and attribute shape against the worklog's 1.12-era notes.
This is the cheapest high-information action available and it gates D2 and C3.

### G4. The two headline redesign numbers are estimates, not measurements.

- c5's `RegFile` write at "≈30 gates pre-Bennett" versus today's 7,122, and the "10–200×"
  claim, are derived from `qrom.jl`'s asymptotics. No prototype exists. The same section's
  strongest empirical point (MUX-EXCH is 15–40× *worse* than the arm it preempts) is a
  cross-reading of `BENCHMARKS.md:106-117` against `worklog/024:91` — two numbers measured
  under different conditions, which c5 itself notes were never compared directly.
- c3's 2× simulate speedup is an isolated-loop microbenchmark; the 64× bit-slicing win is
  unimplemented. Both are plausible; neither is evidence.

**Close it:** one-day spike implementing `read`/`write` on the existing `qrom.jl` tree and
measuring against the same L4/L6 corpus entries BENCHMARKS.md used. Do this *before* D4, not
after.

### G5. BennettVM's requirements were never elicited.

c1 measures that 45–50% of extraction serves it; c7 finds it *de facto owns Bennett's
front-end roadmap* (ten consecutive beads, zero VM source changes); c1 says "give it its own
front-end"; c5 and c1 both recommend deleting the recognisers it depends on. Nobody read
BennettVM's PRD or ADRs, nobody established what it needs from `ParsedIR`, and nobody asked
whether it survives v2. The `Manifest.toml` path dependency with a documentary-only pin
(`BENNETT_JL_PIN.md:6-19`) means the rewrite breaks it silently on day one.

This is a decision, not a research task — but it must be made *early*, because it sets the size
of the front end and determines whether v1 has to stay alive on a maintained branch for the
duration of the rewrite.

### G6. Three load-bearing recommendations rest on unverified capabilities.

- **c2's primary phi fix** ("run `StructurizeCFG` in LLVM so the extractor only sees `select`")
  — nobody checked that LLVM.jl exposes it in the new pass-manager pipeline, that it behaves on
  Julia-emitted IR, or what it does with irreducible CFGs. c2's own §5(a) concedes "some CFGs
  don't structurize"; the fallback therefore has to exist regardless, which changes the
  recommendation's status from "the fix" to "an optimisation".
- **c5's "recognise only what LLVM canonicalises"** (run `sroa`+`mem2reg`, accept surviving
  `alloca`/`load`/`store`, "0 LOC of recogniser"). The passes are wired at `entry.jl:23` but
  default off, and c7 notes the sret memcpy canonicalisation *already depends* on SROA — so
  turning them on is not free and interacts with the ABI tier.
- **c4's two upstream fixes** (widen the walker's operand to 128-bit; disable SLP for extracted
  functions). SLP runs inside Julia's own optimize=true pipeline; whether it can be disabled
  per-compile through the extraction path is unverified, and today's workaround is *contorted
  numerical source* — the clearest case of accidental complexity in the sweep.

### G7. Compile-time cost is unprofiled, so the biggest lever is unknown.

Anecdotes only: ~45 s and ~11M gates for `soft_sin` (c4), 3.4 GB at N=1000 (c5), 28 min suite
(c6). Nobody profiled where a compile actually goes — extraction, lowering, wire allocation, or
`bennett`. That determines whether c3's arena/hierarchical-IR redesign, c4's reversible
call/uncall, or c2's callee lowering cache is the dominant win. Profile one `soft_sin` compile
before committing to any of them.

### G8. The reversible subroutine call fell between areas.

c4 names it the largest available gate-count lever ("`lower_call!` re-emits whole gate lists
per call site… an order of magnitude for sin/pow", and says design it *before* v2's numerics).
c2 independently finds there is no lowering cache and that callees are re-lowered per call site
with the user's options discarded. c3's `Circ` IR sketch — the one place a v2 IR is actually
drafted — has `Prim/Seq/Adj/Compute/Ctl/Scope` and **no `Call` node**. Nobody designed or
costed it. It is a first-class IR question and it is currently nobody's.

### G9. Provenance and licensing of the numeric tables.

c4 records ~1,200 hand-transcribed hex constants from musl / ARM optimized-routines / FreeBSD
SunPro, with no test verifying them against upstream and no attribution mentioned anywhere in
the sweep. A from-scratch rewrite is the moment to (a) generate them from upstream into a
checked-in artefact with a regeneration test, and (b) get the attribution right. Cheap to close,
awkward to discover later.

### G10. The benchmark harness is unowned, and at least two published results are suspect.

`benchmark/` and BENCHMARKS.md are cited as authority by c3 and c5 but audited by nobody. c3
finds the published "Peak Live" column measures an all-zero-input trace; c5 finds the
persistent-DS headline ("linear_scan wins at all scales") is very likely a constant-folding
artefact of the benchmark generator. Any v2 acceptance criterion that cites BENCHMARKS.md
inherits both. The plan needs a decision about the harness itself, not just about what it
measured.

### G11. Migration mechanics.

Where v2 lives (same repo, new repo, branch); how 650 beads and 109 worklog shards carry over
(c6 §5d covers artefacts, not mechanics); how the maintainer keeps a working compiler through a
6–9 week rewrite; whether CLAUDE.md's 3+1-agent rule and rule-6 baseline discipline bind v2 code
from day one or from first green. Unaddressed.

### G12. c6's highest-leverage change collides with a standing project constraint.

c6 names parallel per-file test workers "the single highest-leverage change available". The
user's own persistent memory says: *no concurrent Julia test runs — pgrep julia first;
precompile cache corrupts*. c6 does not mention it. The mechanism (precompile once, then
read-only shared depot; or per-worker `JULIA_DEPOT_PATH`; and `--check-bounds=yes` inherited by
every worker, per c8) needs designing, not assuming.

---

## 2. CONTRADICTIONS

### X1. The substrate. **Adjudicated: keep LLVM — and the disagreement is smaller than it looks.**

| Report | Position |
|---|---|
| c1 | Typed `IRCode` as the *primary* Julia front end; LLVM `.ll`/`.bc` secondary for C/Rust. "2,500–4,000 LOC for the same capability." |
| c7 | Reject pure IRCode (kills language neutrality + the VISION taint contract). Recommend Candidate B: GPUCompiler-style LLVM hook + an inference "type oracle" side-channel. |
| r3 | "No — a package cannot reliably consume IRCode as a long-term substrate." Mooncake's 91-commit port for one minor; JET's per-release compat caps; #61711's 1,600 invalidations; `Compiler.jl` v0.1 is a placeholder. Keep LLVM. |
| r5 | Same conclusion, and — importantly — rates **GPUCompiler-style hooks *Low* on stability**, with julia#44174 (purity modelling broke overlay tables) as precedent. |

Three adjudications:

**(a) c7's central exhibit does not survive scope netting.** The "~7,400 LOC substrate tax"
table is the strongest quantitative case for switching. But 2,863 (`heap.jl`) + 1,691
(`dict_vm` + `vector_vm*`) = **4,554 of it is Julia-collection recognition that c1 and c5
independently recommend deleting regardless of substrate** — and `dict_vm`/`vector_vm` sit
behind `mem=:vm`, which `reversible_compile` rejects outright (verified, `Bennett.jl:232`), i.e.
they are *BennettVM* tax, not substrate tax. Netting out, the honest price of staying on LLVM is
`sret.jl` 1,518 + `vectors.jl` 719 + `constexpr.jl` 331 + `sig_llvm.jl` 181 + `memssa.jl` 143 ≈
**2,900 LOC, of which `memssa` is dead code anyway** — call it ~2,570. That is a real cost and a
much weaker case than either c1 or c7 presents.

**(b) c7 recommends the option r5 rates worst on stability, and c7 could not see r5.** But the
two are not describing the same thing: c7 wants the hook *only* to obtain an `LLVM.Module`
without the printer round-trip and to run passes before GC lowering. It does not require overlay
method tables or world-age abuse — which is exactly what broke in #44174. **The narrow version
(module acquisition) is defensible; the wide version (overlay tables) is not.** Take r5's
framing: steal the pattern, not the package, and keep the callee registry explicit.

**(c) One thing all four agree on and nobody disputes:** stop round-tripping the substrate
through `sprint(code_llvm)` text (verified at `entry.jl:10,60,97,251,309`). That is a substrate
*fix*, orthogonal to the substrate *choice*, and it should be in the plan regardless.

**Verdict:** keep LLVM IR. Delete the recogniser tier by changing scope (G1/X6), not by changing
substrate. Acquire the module without the text round-trip. Treat an inference side-channel as an
*optional* enhancement gated on a written list of facts it would supply — if D0's scope excludes
Julia collections, that list may be nearly empty. Adopt r3's revisit trigger: a non-placeholder,
version-pinnable `Compiler.jl` release.

### X2. The Bennett strategy layer. **Adjudicated for c3.**

c3 measures that `reversible_compile` never passes a strategy, that `fold_constants=true`
(the default) erases `gate_groups` so four of six strategies unconditionally fall back, that
`PebbledStrategy` is *provably* the identity schedule at O(n³s) cost, and that `EagerStrategy`
is disproven by its own trailing comment. c7 lists "six strategies behind one dispatch point" as
**justified domain complexity — "the project's research content"**.

Measurement beats principle here, but c7 is right about *why* it matters, and c3 supplies the
root cause that reconciles them: **wire indices are frozen by `lower()` before any strategy
runs, so no strategy can reduce `n_wires`.** The space–time tradeoff genuinely is the research
content — which is precisely the argument for moving it to where it can act (a placement pass
over symbolic wires, D5), not for preserving six unreachable subtypes. Keep the Knill DP as the
scheduler's cost model (both reports want this).

### X3. Gate-count baselines. **Adjudicated: c6's mechanism + c2's relations, with a caveat the plan must state.**

c7 makes "reproduce 58/114/226/450 and Toffoli 12/28/60/124 exactly, from hand-built IR, with no
LLVM in the repo" the week-1 hard gate. c2 says re-derive them, because a new lowering
legitimately produces different constants, and only the scaling laws (`total(2W)=2·total(W)−2`,
`T(2W)=2·T(W)+4`) are structural. c6 says keep the principle, assert the relations, and move the
constants into one machine-generated file stamped with `(julia_version, llvm_version, strategy)`.

All three are right about different things. The plan must say explicitly:

- The week-1 fidelity gate is legitimate **only for a legacy-equivalent configuration**
  (ripple adder, default Bennett, `fold_constants=true`). It proves the port is faithful.
- The moment carry-out uncompute (c2 §5d), `mul_low`, hierarchical `Adj` (c3) or a new phi path
  lands, the constants move *by design*, and the relations plus a reviewed baselines diff become
  the regression mechanism.
- **The constants may move on 1.13/LLVM 20 before any v2 code exists** (c6 §3.1). Measure that
  first (G3) or the gate fails for the wrong reason and burns a day of confusion.

### X4. Phi resolution. **Not a contradiction — a layered answer nobody assembled.**

- c2: do if-conversion upstream in LLVM (`StructurizeCFG`) *and* make predicates first-class
  values with a BDD/SAT mutual-exclusion proof before any gate exists.
- c7: port the path-predicate algorithm as-is; fix the silent fallthrough at `phi.jl:56`.
- c8: historically the *cheapest real fix* was upstream in the source — write `soft_fadd`
  branchless so LLVM emits `select` and no phi exists.
- c4: and yet the branchless style is *why the soft-float library must exist*; if v2 wants to
  compile `Base.Math` directly, branchy code becomes mandatory and the phi resolver must be
  trustworthy.

Assembled: **Layer 1** — predicates as first-class IR values with a checkable
mutual-exclusion obligation (c2's *second* mechanism). This is the structural fix and it is
independent of whether LLVM structurises. **Layer 2** — run `StructurizeCFG` opportunistically
*if* G6 shows it is available and robust. **Layer 3** — fail loud on CFGs neither handles.
Do **not** adopt upstream if-conversion as the primary mechanism before G6 closes; c2's own
section concedes the fallback is needed anyway. And record c4's irony as a design constraint:
the phi resolver's trustworthiness is the gate on whether the soft-float library can ever shrink.

### X5. Soft-float scope. **Sequenced, not contradictory — but one decision is due now.**

c7 and c6: port ~7k LOC verbatim; it is ~30k assertions of verified numerics and the best asset
in the repo. c4: shrink to ~1,500 LOC of tier A/B kernels by moving f64 op lowering into the
compiler, and tiers C/D may disappear if `Base.Math` compiles directly.

These sequence cleanly (port verbatim → add native `fadd/fmul/…` lowering → delete what becomes
redundant), and the plan should say so. But one decision **cannot** be deferred, because it
determines the IR: **does extraction keep routing `fcmp`/`fptosi`/transcendentals to registered
`soft_*` callees, or do these become IR nodes lowered later?** Today `llvm.ctpop.i64` becomes
~257 `IRInst`s *inside the extractor* (c1) — an optimisation decision made in the parser,
invisible to `lower.jl`, untunable by strategy. Fixing this makes the soft-float library a
*lowering table* rather than a *callee registry*, and that is a D3-time choice.

Secondary tension to resolve explicitly: c4 wants the `*_julia` variants deleted (they carry the
Julia-1.12-internals coupling, including bit-exactness that depends on an `@noinline` annotation
on `Base.pow_body`); c6/c8 treat bit-exactness-vs-`Base` as the oracle. Both are satisfiable only
by stating the contract *per tier* (A/B bit-exact vs hardware; C ≤1 ULP vs `Base`, bit-exact vs
musl; D deleted or explicitly version-pinned).

### X6. Does Julia-collection support survive? **Adjudicated for c5, and this partly resolves X1.**

c5: not as a supported compile path — explicit `RegFile`, recognition demoted to a labelled
best-effort plugin. c7: rebuild it on an inference oracle (Candidate B, weeks 4–6). c1: at typed-IR
altitude the problem becomes "match a call to `Base.setindex!`" and the zoo has no reason to exist.

c5's argument is the strongest because it is about **cost and semantics, not substrate**: even
with perfect type information you must still decide what a *reversible* `Vector{Int}` is, and the
only honest answer is a statically-bounded register file. An inference oracle makes recognition
cheaper; it does not make a growable heap reversible. So: `RegFile` is the supported path on every
substrate, and recognition — however obtained — is a convenience that maps onto it. This is also
what shrinks X1's substrate tax to the ABI tier.

### X7. Numbers that disagree, to be reconciled before the plan quotes them.

- Extraction size: c1 says 19,020 LOC / 49%; c7 says "~14k". **Verified: `src/extract/` = 18,144
  = 46% of 39,098**; c1's figure additionally counts `ir_types.jl`, `callees.jl`, `narrow.jl`.
  Use one number and say what it covers.
- c1's "45–50% of extraction is unreachable from `reversible_compile`" is verified for `mem=:vm`,
  **but `ptr_cells=true` + `lower()` is a live, tested combination** (`driver.jl:12`), which is
  exactly why `_bvmd_reject_normalised_alloca!` exists in the gate backend. The boolean is not
  cleanly separable *today* even on the circuit path — which strengthens, not weakens, the case
  for splitting the front end by target rather than by flag.

### X8. Native narrow integers. **Adjudicated for r2 over c1.**

c1 §5d hopes native `Int4` obsoletes `narrow.jl`, flagging it as speculative and telling the
maintainer to verify. r2 verified: merged to `master` 2026-07-21, **not in 1.13** (ancestry
diff, `release-1.13` vs `master` reported as *diverged*), self-described "preliminary… not quite
safe to use yet", **odd-width arithmetic intrinsics explicitly untested upstream**, and a
memory-safety follow-up PR still open as of 2026-08-14. Consequence: `bit_width` must be a real
parameter of lowering (c7) or restricted to the tabulate path (c1's own option b) — not a
post-extraction IR rewrite, and not a bet on 1.14. r2's revisit trigger is the right one:
*arithmetic-intrinsic test coverage landing upstream*, not "1.14 ships".

### X9. Test parallelisation vs. the project's own constraint. **Needs a mechanism, not a preference.**

See G12. c6's recommendation is right; its precondition is unstated.

### X10. Minor: r1's reassurance should not be over-read.

r1 notes Bennett's opcode dispatch uses stable C-API integer enums and "should absorb most of the
version churn". True and irrelevant to the actual fragility, which c1/c7 locate elsewhere: the
text round-trip, Julia ABI symbol names and mangling regexes, and the raw packed-integer decode of
LLVM's `memory` attribute at `instructions.jl:2013` (explicitly "NOT a stable API"). Do not let
r1's opcode-enum point be quoted as "extraction is safe on LLVM 20".

---

## 3. SYNTHESIS GUIDANCE — the decisions the plan must make, in dependency order

**D0. The input contract (scope).** *Blocks everything.* Name the exact program class v2
compiles: recommended — pure functions on `Int8..Int64`/`Float64`, loops with a static trip
bound, memory only via an explicit `RegFile{N,W}`, no Julia collections, no dynamic allocation,
no exceptions (NaN/saturate policy instead); everything else fails loud. Deliverable: an
L0–L10-style conformance ladder including RED entries. Without this, X1 cannot be closed and c7's
"substrate tax" cannot be priced.

**D1. BennettVM.** Decide: (a) versioned `BennettIR` package both repos consume; (b) BennettVM
gets its own front end; (c) BennettVM is frozen against v1. This sets whether ~22% of today's
extraction exists in v2, whether `ptr_cells` exists at all, and whether v1 must be maintained on
a branch through the rewrite. Elicit requirements first (G5) — this is the sweep's largest
unexamined dependency.

**D2. Substrate and module acquisition.** Given D0/D1: **keep LLVM IR**; kill the
`sprint(code_llvm)` text round-trip; acquire the module through a compiler hook limited to
module acquisition and pass control (no overlay method tables, no world-age tricks — r5's
breakage precedent). Decide the inference side-channel by writing the explicit list of facts it
would supply and checking that list against D0; if the list is short, drop it. Record r3's
revisit trigger. **Precondition: G3** (measure on 1.13-rc3 first).

**D3. The IR — the centre of the rewrite.** Five constituencies converge here and none of them
drafted it together: predicates as first-class values with a checkable mutual-exclusion
obligation (c2); linear/affine wire handles with compute/uncompute regions (c2 §5c, c3);
`Adj`/`Compute`/`Scope` so uncompute is structure, not materialised gates (c3); a `guard` field
on every effectful op (c5); **and a `Call`/uncall node with a shared ancilla frame, which is in
nobody's sketch (G8)**. Plus: closed sum types with no sentinel discriminators, `Bits`/`Bytes`/
`ElemIndex` newtypes (c1 R5 — unit confusion is the most common historical bug class), and a
version stamp if D1 keeps a shared interface. Also settle X5's intrinsic question here (IR node
vs. extractor-expanded callee). Write this once, with all five constituencies present.

**D4. Memory.** `RegFile{N,W}` as an SSA-threaded value, two unary-iteration primitives, guard in
the IR, const index as a compile-time specialisation of the same primitive; a SELECT-SWAP/QROAM
variant designed in from the start as the ancilla↔T-count knob. Delete `persistent/`,
`softmem.jl`, `memssa.jl`, and heap/Dict/Vector recognition as supported modes. **Precondition:
G4** — prototype and measure against the same corpus BENCHMARKS.md used before committing.

**D5. Placement and schedule.** One scheduler with a space budget, operating on symbolic wires
after lowering, replacing all six strategies; Knill's DP retained as its cost model. Acceptance
criterion that today's system cannot meet: **it must actually reduce `n_wires` on a real
circuit.** Depends on D3's regions and linear handles.

**D6. Soft-float staging.** Port verbatim first — it is the oracle and the acceptance test for
everything else — then add native f64 op lowering, then decide whether tiers C/D shrink. Port
c4's 11 test conventions *before* any implementation, and add the missing assertion that
generated soft-float IR contains no `br`. State the bit-exactness contract per tier (X5).

**D7. API and configuration.** One options struct that is the only representation; targets as
types (`CircuitTarget`/`VMTarget`) dispatching instead of a `Ref{Any}` hook and symbol carve-outs;
retire the word `strategy` in favour of `schedule` (how to uncompute) and `objective` (what to
minimise); caller-owned caching. Do this *before* the test suite, since every test writes against
it.

**D8. Verification and baselines.** First code written in the rewrite: **the ancilla-zero check
after the FORWARD pass** — c8's meta-bug (a tautological `verify_reversibility` hid five real bugs
for months) means anything written before a sound oracle is validated by nothing. Then: three
tiers (structural guarantee / seeded property-based with shrinking, aimed at diamond CFGs /
ANF-or-SAT miter for kernels), bit-sliced simulation, directory-discovered parallel tiers with an
answer to G12, and baselines as a machine-generated environment-stamped file plus asserted scaling
relations (X3).

**D9. Export and target contract.** Decide the output side before D3 freezes the gate record:
gate alphabet (Toffoli / MCX-k / Clifford+T), whether measurement-based uncomputation (Gidney AND)
must be representable, serialisation format, and what Sturm.jl actually consumes. Currently
uncovered (G2); deferring it risks invalidating D3's record and D5's cost model.

**Staging gate — all reports converge, keep it:** the back half first, built from hand-written IR
with no LLVM in the repo, reproducing the legacy-equivalent gate counts and the soft-float oracle.
The back half is the asset; the front end is the liability. See X3 for what "reproducing" may
legitimately mean once 1.13/LLVM 20 is under it.
