# C6 — Public API surface, test architecture, docs/process artifacts

Adversarial architecture review, area 6 of 8. Read-only pass over
`src/Bennett.jl`, `src/softfloat_dispatch.jl`, `test/runtests.jl`, ~12 sampled test
files, `README.md`, the PRD set, and `docs/`. All line numbers are as of
commit `980805de` (2026-08-14).

---

## 1. What this area actually does

### 1.1 The public API, as built

`src/Bennett.jl` (583 lines) is not a module skeleton — it is the API layer. It
contains, in order: 34 `include`s with inline archaeology comments, a 100-name
export list, a 13-field `CompileOptions` struct, a hand-rolled kwarg validator, and
**three** `reversible_compile` kwarg overloads plus **four** `CompileOptions`
positional overloads. `src/softfloat_dispatch.jl` (207 lines) adds the Float64
overloads plus 40 `Base.*` method definitions on a `SoftFloat` wrapper struct.

The *actual* entry-point topology is:

```
reversible_compile(f, T...)                    → Tuple overload (Bennett.jl:271)
reversible_compile(f, Tuple{...})              → Tuple overload
reversible_compile(f, Float64...)              → SoftFloat wrapper (softfloat_dispatch.jl:103)
reversible_compile(parsed::ParsedIR)           → the real funnel (Bennett.jl:467)
reversible_compile(…, opts::CompileOptions)    → 4 forwarders (Bennett.jl:541,559 + dispatch:154,172,190)
```

Everything funnels into `reversible_compile(::ParsedIR)`, which does three things:
intercepts `target === :reversible_vm` and hands off to a `Ref{Any}` backend hook
(`Bennett.jl:419`, `490`), consults a module-global memo `Dict{Tuple,ReversibleCircuit}`
keyed on `objectid(parsed)` plus ten kwargs (`Bennett.jl:410`, `498`), and otherwise
calls `lower(...)` then `bennett(lr)`.

Thirteen knobs cross this surface: `optimize`, `max_loop_iterations`,
`compact_calls`, `bit_width`, `add`, `mul`, `strategy`, `fold_constants`, `target`,
`auto_self_reversing`, `mem`, `persistent_impl`, `hashcons`. They are not uniform:
`bit_width` and `optimize` and `strategy` are Tuple-overload-only; `bit_width` is
rejected on Float64; `mem=:heap` is an *extraction*-phase flag that gets normalised
to `:auto` before `lower` sees it (`Bennett.jl:367`). Because Julia's kwarg dispatch
would produce a `MethodError` with LLVM-backed spew, each overload re-declares the
names it accepts as a `const` tuple and calls `_reject_unknown_kwargs`
(`Bennett.jl:173-196`, tuples at `265`, `395`, `402`, and `softfloat_dispatch.jl:95`,
`101`). So the kwarg contract exists in *four* parallel representations: the
`CompileOptions` struct fields, the `const` name tuples, the physical kwarg
signatures, and the forwarding call sites.

Concretely: adding one boolean knob today requires edits at ~15 sites. Evidence:
`auto_self_reversing`, a single `Bool`, appears **21 times** across the two API files
(13 in `Bennett.jl`, 8 in `softfloat_dispatch.jl`). `hashcons`, which is `:none`-only
today, appears **30 times**. `persistent_impl` occupies 28 lines.

### 1.2 The test architecture, as built

322 `test_*.jl` files, 49,878 lines, 8,280 `@test` invocations expanding to the
claimed ~692k assertions (loops dominate), ~28 min cold. `test/runtests.jl` is a
1,092-line flat registration list: **315 `runfile` calls and 702 comment lines** —
the registration manifest is 70% prose. Each `runfile` line typically carries a
3-15 line commit-message-grade comment explaining the bead it came from
(e.g. `runtests.jl:596-612`, a 17-line paragraph for one include).

Structurally there are three test genres, deliberately named:

* **Feature/pipeline files** — `test_increment.jl`, `test_branch.jl`, `test_qcla.jl`.
  Small, exhaustive-for-Int8, the real correctness core.
* **Per-bead regression files** — ~90 of them (`test_57hd_value_identity.jl`,
  1,265 lines; `test_a70z_overflow_const_bit.jl`, 1,003; `test_foz5_confined_bounds.jl`,
  928). These are not tests in the classical sense; they are *executable ADRs*.
  `test_57hd_value_identity.jl:1-45` is 45 lines of soundness argument before the
  first `@test`.
* **Meta/process files** — tests that assert things about the source text:
  `test_wlf6_jldoctest_fences.jl` (docstrings contain "```jldoctest"),
  `test_doh6_docs_makejl.jl` (make.jl contains "doctest = true"),
  `test_f6qa_error_message_prefixes.jl`, `test_kh6n_prefix_discipline.jl`,
  `test_uoem_research_relocation.jl`, `test_5kio_sizehint_arithmetic.jl`
  ("pin the static presence of the hints").

Execution model: strictly serial `Base.include` inside one root `@testset "Bennett"`
(`runtests.jl:56`). Parallelism exists only *inside* four files as ad-hoc
`Threads.@threads` over input sweeps (`test_division.jl:19`, `test_softfma.jl:178`).
Three env gates carve out subsets: `BENNETT_HEAVY_TESTS` (17 transcendental files,
~15 min — the majority of wall time), `BENNETT_T5_TESTS`, `BENNETT_RESEARCH_TESTS`.
A substring `ARGS` filter with loud "NOT a full-suite green" banners
(`runtests.jl:22-26`, `1084-1092`) is a genuinely good touch.

### 1.3 Docs and process artifacts

* README.md — 503 lines, unusually good: honest about limits, cites papers with
  DOIs, tables of measured numbers, generated SVG/PNG figures whose plot scripts
  re-verify the numbers before drawing.
* `docs/` — 201 files, 6.5 MB. A well-formed Diátaxis site (20 pages under
  `docs/src/`), 40 `docs/design/*.md` proposer/consensus snapshots, 6 PRDs under
  `docs/prd/`, literature PDFs.
* Root — 5 more PRD-class documents (`Bennett-VISION-PRD.md` 580 lines,
  `Bennett-Memory-PRD.md`, `Bennett-Memory-T5-PRD.md`, `Bennett-ReversibleVM-PRD.md`,
  `Bennett-Enzyme-Parity-NorthStar.md`), `CHANGELOG.md`, `BENCHMARKS.md`.
* `worklog/` — 109 shards + a 176 KB `WORKLOG.md` index; 29,118 lines total.
* `reviews/` — 964 KB of frozen audit snapshots (two full review generations).
* `bd` — 650 issues (539 closed, 99 open).

Totals: **39k lines of `src/`, 50k lines of `test/`, 81k lines of Markdown outside
the worklog, plus 29k lines of worklog.** Prose outruns source ~2.8:1.

---

## 2. Antipatterns, tech debt, accidental complexity

I separate these into (A) genuine defects, (B) accidental complexity that is real
but explicable, and (C) complexity the domain actually earns.

### A. Genuine defects

**A1 — A green test asserts the opposite of the truth (doctests).**
`test_doh6_docs_makejl.jl:23` asserts
`occursin("doctest = true", src) || occursin("doctest=true", src)` over `docs/make.jl`.
`docs/make.jl:56` says `doctest = false`. The test passes anyway, because
`docs/make.jl:13` contains the *prose* "set doctest=true and validate the build".
So: ten `src/*.jl` files carry `​```jldoctest` fences (`Bennett.jl:252`,
`simulator.jl:51,141,294`, `diagnostics.jl:14,53,84`, `controlled.jl:23,144`,
`compose.jl:85`), two test files exist specifically to protect the doctest surface,
and **not one doctest is ever executed**. `test_wlf6_jldoctest_fences.jl:63-85`
partially compensates by hand-transcribing a few of the expected values into real
`@test`s — which means the same constants are now pinned in three places instead of
executed once. This is the single clearest instance of the project's dominant
failure mode: *proxy tests over source text passing while the thing they proxy is
off.* It also means `checkdocs = :none` and `warnonly = [:missing_docs,
:cross_references, :docs_block]` (`docs/make.jl:57-58`) have silently disabled every
Documenter correctness check.

**A2 — The documented single-file test command does not work for 69 of 322 files.**
`CLAUDE.md:33` and `:240,245` and `README.md:390` all advertise
`julia --project test/test_increment.jl`. Verified:

```
ERROR: LoadError: UndefVarError: `@testset` not defined in `Main`
in expression starting at test/test_increment.jl:1
```

`test_increment.jl` has no `using Test` / `using Bennett`; it relies on being
`Base.include`d into a `Main` that already has them. 69 files share this. The
project's own §8 "GET FEEDBACK FAST" workflow is broken for 21% of the suite, and
the failure mode is a confusing `UndefVarError` rather than a missing-import message.

**A3 — Six test files are orphaned from `runtests.jl`.** `test_5viz_loaded_ptr_src_memcpy.jl`
(594 lines, committed 2026-08-07), `test_k2w6_soft_fminmax.jl`,
`test_kh6n_prefix_discipline.jl`, `test_mq6f_round_away.jl`,
`test_p19b_minimumnum_maximumnum.jl`, `test_zc50_simulate_signedness.jl`
(2026-04-24). Four of these were committed alongside src changes that shipped
(`soft_fmin`/`fmax`, `soft_round_away`, `minimumnum`/`maximumnum`, simulate
signedness) — so live, exported behaviour has *zero* suite coverage while appearing
to be tested. `CLAUDE.md:209` claims "314 wired"; the real count of unwired files
is 6, and nothing detects drift. A one-line directory-vs-manifest test would have
caught all six; the project instead has meta-tests for docstring fence formatting.

**A4 — `CompileOptions` is dead API.** 13 fields, 4 forwarder overloads
(`Bennett.jl:541,559`, `softfloat_dispatch.jl:154,172,190`), one bespoke validator
`_check_field_at_default` (`Bennett.jl:519`), a 25-line docstring — and **the only
caller in the entire repo is `test_bennett.jl:28-43`**, the test written to justify
it. It was introduced (Bennett-u71l / U161) as "single source of truth for the
defaults", but it is not: each overload still re-declares every default as
`_DEFAULT_COMPILE_OPTIONS.field`, and the `const` name tuples remain a fourth,
independent list. So the deduplication bead *added* a representation instead of
removing three.

**A5 — Two incompatible meanings of the word `strategy`, and the headline feature is
unreachable.** `reversible_compile(...; strategy=)` accepts `:auto/:tabulate/:expression`
(`Bennett.jl:333`) — a *lowering* choice. `bennett(lr; strategy=)` accepts a
`BennettStrategy` object — the *space–time uncompute schedule*
(`bennett_strategies.jl:90-98`). `reversible_compile` never forwards the latter: it
unconditionally calls `bennett(lr)` (`Bennett.jl:350,376,506`). The README devotes a
whole section and a six-row table to "Space–time trade-offs" (`README.md:247-259`),
but a user cannot reach `PebbledStrategy(k)` through `reversible_compile` at all —
they must drop to `lower()` + `bennett(lr, strategy)` manually. Six strategies, one
abstract type, five legacy aliases, all exported (`Bennett.jl:99-102`), zero
top-level reachability.

**A6 — 100 exported names for a compiler with one entry point.** `names(Bennett)`
returns 100. That includes 39 `soft_*` primitives (`Bennett.jl:81`), the IR operand
sentinels `OPAQUE_PTR_SENTINEL`, `POISON_LANE`, `ZERO_AGG`, `PendingVecLane`
(`Bennett.jl:95-97`), `ParsedIR`/`LoweringResult`, and the persistent-map research
API. The comments admit *why* — `Bennett.jl:87-89` "exporting so the documented
constructors … resolve without `Bennett.` prefix"; `Bennett.jl:93-94` "exported for
backward compat (Bennett-ibz5 / U96 test depends on it)". **Exports were added to
make tests and docstrings shorter.** That is the tail wagging the dog: every one of
those names is now a compatibility surface.

**A7 — Baseline constants duplicated across 20+ files with no single source.**
`(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)` appears in `README.md:114`,
`src/diagnostics.jl:18`, `src/Bennett.jl:259`, eight `docs/src/**` pages, and at
least four test files (`test_gate_count_regression.jl:40`, `test_bennett.jl:23`,
`test_k7al_ir_constructor_asserts.jl:133`, `test_egu6_self_reversing_check.jl:86`,
`test_uiaq_compile_cache_transparent.jl:30`, `test_wlf6_jldoctest_fences.jl:71`).
Only the first is a regression pin; the rest are copies that must be updated by
hand when the number legitimately moves. With doctests disabled (A1), the docs
copies are unverified prose.

**A8 — 27 of 49 `Random`-using test files never seed.** Unseeded fuzz includes
`test_9x75_softfloat_raw_bits_sweep.jl` (~30k strict-bit asserts),
`test_softfma.jl`, `test_softfdiv.jl`, `test_softfconv.jl`, `test_sha256.jl`. When
one of these fails, the input that broke it is not reproducible. CLAUDE.md §13's
own post-mortem (`CLAUDE.md:45`) is about a random sweep that *missed a region*;
the response was a per-function convention rather than a suite-wide "seed from a
printed run-id" rule.

**A9 — A ratchet loosened 4× and the comment left stale.**
`test_hygiene_aqua_jet.jl:74-75`: comment says "50 is a generous ceiling picked to
catch a regression of 10×"; the assertion is `@test n_reports < 200`. Meanwhile the
whole JET block is dead in practice — JET is de-listed from `Project.toml`
`[extras]`/`[targets]` (Bennett-37ib), so `_JET_OK` is false in any clean env and
the testset self-skips. Aqua itself runs with `ambiguities=false`,
`deps_compat=false`, `piracies=false`, and `test_ambiguities` wrapped in
`@test_broken` (`:62`). The hygiene gate asserts approximately nothing.

**A10 — Byte-template test duplication.** `test_6883_okasaki_dispatch.jl` (103),
`test_6883_hamt_dispatch.jl` (134), `test_6883_cf_dispatch.jl` (134) are
acknowledged in `runtests.jl:1009-1016` as "Byte-template duplicate". Three files,
one parameterisable table. The same pattern recurs across the 17 transcendental
LLVM-dispatch files, which differ only in the intrinsic name.

**A11 — CLAUDE.md's own file map is stale.** `CLAUDE.md:7` and `:82-94` place
`Bennett-PRD.md`, `BennettIR-PRD.md`, `BennettIR-v03/04/05-PRD.md` at the repo
root; all six moved to `docs/prd/`. The root files that *do* exist
(`Bennett-Enzyme-Parity-NorthStar.md`, `Bennett-ReversibleVM-PRD.md`,
`CHANGELOG.md`) are absent from the map. `CLAUDE.md:88` says "77 sharded session-log
files (as of 2026-05-23)"; there are 109. `:15` says the top chunk is `075_*`; it is
higher. `README.md:98` and `Project.toml` say Julia 1.10+; `src/extract/heap.jl:139`
hard-asserts `(VERSION.major, VERSION.minor) == (1, 12)`. The single most-read
document in the repo drifts because nothing tests it — while
`test_uoem_research_relocation.jl` exists to test that a *directory move* stayed moved.

### B. Accidental complexity that is real but explicable

**B1 — `_reject_unknown_kwargs`.** Hand-rolling kwarg validation is ugly, but the
stated motivation (`Bennett.jl:167-172`) is legitimate: a `MethodError` on a
`reversible_compile` typo dumps LLVM-backed method-table spew. The right fix is a
single options object *actually* threaded through (see §5a), not three name tuples.

**B2 — `objectid`-keyed compile cache** (`Bennett.jl:404-410`, `497-509`). Correct
about its own weakness — the docstring at `:443-465` is honest that `ParsedIR` has
no `==`/`hash`, that the cache is identity-keyed, that the returned circuit is
shared and must not be mutated, and offers `_clear_compile_cache!`. It is a global
mutable cache returning shared mutable objects with an "please don't mutate"
docstring, which is a landmine, but the reasoning is sound and the invalidation
hazard (`register_callee!` after a cached compile) is documented.

**B3 — `Ref{Any}` VM backend hook** (`Bennett.jl:419`). A weakly-typed global
function slot to avoid a dependency cycle with BennettVM. Justified by the
constraint, but it means `reversible_compile` has a return type of
`Union{ReversibleCircuit, Any}` and the `target=:reversible_vm` carve-outs leak into
two unrelated branches (`:343`, `:371`) with explanatory comments about not being
"silently swallowed".

**B4 — `SoftFloat` type piracy.** `softfloat_dispatch.jl` defines 40 `Base.*`
methods on a locally-owned struct — that is *not* piracy (own type), and Aqua's
`piracies=false` note at `test_hygiene_aqua_jet.jl:52` is technically over-broad but
harmless. The `N==1/2/3` closure triplication (`softfloat_dispatch.jl:130-150`) plus
three `CompileOptions` arity overloads (`:154,172,190`) is pure copy-paste that a
`ntuple`/`Vararg` formulation removes.

### C. Complexity the domain earns — do not "clean this up"

* **Exhaustive Int8 sweeps** (39 files). `for x in typemin(Int8):typemax(Int8)`
  against a native oracle is exactly right for this domain and cheap.
* **Bit-exact soft-float oracle tests** (34 files, ~20 comparing directly against
  `Base.exp/log/sin/...`). This is the crown jewel of the suite (see §5b).
* **`verify_reversibility` on every compiled circuit.** CLAUDE.md §4 is the correct
  invariant discipline; the fact that `test_gate_count_regression.jl:24-27` adds
  `verify_reversibility` next to every pinned count (Bennett-11xt / U23) is exactly
  the right instinct.
* **Long prose headers on the closed-world admission-contract tests.** These
  encode soundness arguments that genuinely cannot be derived from the code
  (`test_57hd_value_identity.jl:1-45`). The prose is the deliverable; the `@test`s
  are its executable shadow. This is *good*, merely misfiled — it belongs in
  `docs/adr/` with the test referencing it.
* **Fail-loud regression files per wall cleared.** The `ptr_cells` frontier work
  is genuinely a sequence of individually-justified admissions; one test per
  admission is defensible.

---

## 3. Version coupling (Julia 1.12 → 1.13)

Within my area, the coupling is mostly *indirect but severe*:

1. **Every gate-count baseline is a function of Julia's codegen, not just of
   Bennett's lowering.** `test_gate_count_regression.jl` pins `x + Int8(1)` at 58
   gates with `add=:ripple, fold_constants=true`. That number is downstream of the
   LLVM IR Julia 1.12 emits at `optimize=false`. CLAUDE.md §6's careful decoupling
   from `:auto` *defaults* does nothing about coupling to the *frontend*. A Julia
   1.13 with a newer LLVM that canonicalises `add i8 %0, 1` differently — or emits
   a different number of `zext`/`trunc` pairs — moves 58 without any Bennett change.
   Because the same constant is copied into 20 files (A7), a legitimate frontend
   shift becomes a 20-file manual edit with no mechanical way to distinguish
   "frontend moved" from "we broke lowering".
2. **`Project.toml` declares `julia = "1.10"` and `LLVM = "9, 10"`** while
   `src/extract/heap.jl:139` hard-errors off `(1,12)` and README says "tested on
   1.12". The compat bound is a fiction; on 1.13 the package will resolve, load, and
   fail deep inside extraction. Aqua's `deps_compat=false`
   (`test_hygiene_aqua_jet.jl:51`) means nothing checks it.
3. **JET is de-listed because it hangs precompiling under the 1.12 test config**
   (`Project.toml` `[targets]` note, `test_hygiene_aqua_jet.jl:17-25`). A 1.13
   rewrite gets a free re-evaluation of that decision.
4. **`@inline` at the call site through the SoftFloat dispatch chain**
   (`softfloat_dispatch.jl:126-131`). This depends on Julia's inliner actually
   inlining `f → SoftFloat./ → soft_fdiv`; the comment states that without it Julia
   emits struct-passing ABI that `ir_extract` cannot handle. That is an inliner-
   heuristic dependency, not a language guarantee, and it is exactly the sort of
   thing that shifts between minor versions. There is no test that *asserts* the
   inlining happened — only end-to-end tests that fail confusingly if it doesn't.
5. **`test_d1a_transitive_callees.jl:113`** branches on `VERSION >= v"1.11"`; the
   closed-world walker touches Julia inference internals that are explicitly
   not-a-stable-API (`src/extract/sig_llvm.jl:83-97`). Those tests are the most
   1.13-fragile in the suite.
6. **What gets *simpler* on 1.13:** `Base.@kwdef`, `public` (1.11+) instead of
   `export` for the 60-odd names that are public-for-testing only, and package
   extensions (`[extensions]`) as a first-class replacement for the `Ref{Any}` VM
   hook (B3). All three are available today on 1.12 and unused.

---

## 4. From-scratch verdict

Assume code generation is free. Then the question is *what is worth re-deriving vs
re-typing*, and the answer differs sharply between the three sub-areas.

### KEEP — port verbatim or near-verbatim

* **The soft-float oracle corpus.** 34 files, ~20 of which assert bit-exactness
  against `Base.exp/log/sin/cos/pow/sqrt/fma`. This is an *oracle*, not a test
  suite: it is valuable independent of Bennett's architecture, it is expensive to
  re-derive (each was tuned against a specific musl/FreeBSD port), and CLAUDE.md §13's
  subnormal-output-sweep convention encodes a real, hard-won bug class
  (`test/test_softfexp.jl:135`). Port it as-is on day one; it is the best asset in
  the repo.
* **The exhaustive-Int8 feature tests** (39 files). Cheap, total, oracle-backed.
* **The three Bennett invariants** as an executable contract: ancilla-zero,
  input-preservation, forward∘reverse = identity (`verify_reversibility`, CLAUDE.md §4,
  Bennett-asw2 / U01, Bennett-6azb / U58). These are the definition of correctness
  for this compiler and must be the *first* code written in a rewrite.
* **The gate-count doubling laws** (`total(2W) = 2·total(W) − 2`,
  `T(2W) = 2·T(W) + 4`) — as *relations*, not as absolute constants. See §5c.
* **README.md.** It is genuinely excellent technical writing and mostly
  architecture-independent. Port the prose; regenerate the numbers.
* **The `runtests.jl` filtered-run guard rails** (`:22-26`, `:1084-1092`) — the
  "this is NOT a full-suite green" banner is a small thing that prevents a large
  class of false confidence.
* **The closed-world admission-contract prose** — as ADRs, not as test headers.

### DISCARD

* **`CompileOptions` and all seven forwarder overloads** (A4). Replace with one
  options struct that is *actually* the only representation.
* **`_reject_unknown_kwargs` and the three `const` name tuples** — an options
  struct makes typos a `MethodError` on a field name, which is already good.
* **Every meta-test over source text**: `test_wlf6_jldoctest_fences.jl`,
  `test_doh6_docs_makejl.jl`, `test_f6qa_error_message_prefixes.jl`,
  `test_kh6n_prefix_discipline.jl`, `test_uoem_research_relocation.jl`,
  `test_5kio_sizehint_arithmetic.jl` ("pin the static presence of the hints"). These
  test the *ritual*, not the behaviour, and A1 proves they can be green while the
  behaviour is off. Doctests should be *executed*; error messages should be
  asserted at the `@test_throws` site that produces them.
* **The 1,092-line flat `runtests.jl`.** Replace with directory discovery (see §5b).
* **The 40 `docs/design/*.md` proposer/consensus snapshots and 964 KB of
  `reviews/`.** Historical process artifacts of a process the rewrite replaces.
  Archive the repo; don't port them.
* **Five root PRDs + six `docs/prd/` PRDs.** See §5d.
* **The `test_6883_*` triplets and the 17 near-identical transcendental dispatch
  files** — regenerate as one parameterised table each.

### REDESIGN

* **The public API** — §5a.
* **The test architecture** — §5b.
* **Baseline pinning** — §5c.
* **Process artifacts** — §5d.
* **Exports → `public`.** Ship ~12 `export`s (`reversible_compile`, `simulate`,
  `verify_reversibility`, the metrics, `ReversibleCircuit`, `controlled`, `compose`)
  and mark the rest `public` (Julia 1.11+) or leave them qualified. Tests should use
  `Bennett.foo`; that is not a reason to export.
* **The VM backend hook** — a package extension (`Bennett/ext/BennettVMExt.jl`)
  instead of `Ref{Any}` + two `target !== :reversible_vm` carve-outs.

---

## 5. Specific questions

### (a) The v2 `reversible_compile` surface

Today: 13 flat `Symbol`/`Bool` kwargs, three of which (`mem`, `persistent_impl`,
`hashcons`) are only meaningful together, one of which (`strategy`) collides in
meaning with `bennett`'s, one of which (`hashcons`) has exactly one legal value, and
one of which (`mem=:heap`) is silently rewritten before reaching `lower`. The knobs
are validated in four places and threaded by hand through five overloads.

I would ship exactly this:

```julia
reversible_compile(f, argtypes; target = CircuitTarget(), opts = CompileOpts())
reversible_compile(ir::ParsedIR; target, opts)
```

with the configuration expressed as **types, not symbols**:

```julia
# WHAT you want out — dispatch, not a Symbol.
abstract type CompileTarget end
struct CircuitTarget <: CompileTarget          # the default
    schedule::BennettSchedule  = BennettDefault()   # ← today's `bennett(lr; strategy=)`
    objective::Objective       = MinGates()          # or MinToffoliDepth()
end
struct VMTarget <: CompileTarget end            # provided by the BennettVM extension

# HOW to lower — a nested, validated bundle.
Base.@kwdef struct CompileOpts
    frontend::FrontendOpts = FrontendOpts()   # optimize, bit_width, ptr_cells
    arith::ArithOpts       = ArithOpts()      # add, mul, fold_constants
    loops::LoopOpts        = LoopOpts()       # max_loop_iterations
    memory::MemoryPlan     = AutoMemory()     # AutoMemory | PersistentMemory(impl, hashcons) | HeapMemory
    calls::CallOpts        = CallOpts()       # compact_calls, callee registry
end
```

Why this shape:

1. **One representation.** `CompileOpts` is the *only* place a default lives. No
   name tuples, no `_DEFAULT_COMPILE_OPTIONS.field` echoes in five signatures, no
   `_check_field_at_default`. Adding a knob is a one-line struct edit, not 15 sites.
2. **Illegal states unrepresentable.** `persistent_impl`/`hashcons` only exist
   inside `PersistentMemory`, so `validate_persistent_config` (`Bennett.jl:226-241`)
   disappears. `bit_width` lives in `FrontendOpts` and is checked once at
   construction, so the Float64/ParsedIR cross-rejection machinery disappears.
   `mem=:heap`-normalised-to-`:auto` (`Bennett.jl:367`) becomes an explicit
   frontend-vs-lowering split at the type level.
3. **Targets dispatch.** `CircuitTarget` vs `VMTarget` is a method, not two
   `target !== :reversible_vm` carve-outs plus a `Ref{Any}`. The extension defines
   `reversible_compile(::VMTarget, ...)`; if it isn't loaded, the user gets a
   `MethodError` naming `VMTarget` — which is exactly the "requires `using BennettVM`"
   message, for free.
4. **The space–time schedule becomes reachable** (fixes A5). `CircuitTarget(schedule
   = Pebbled(k))` is the *only* spelling; `bennett(lr, schedule)` remains the
   internal seam. The word "strategy" is retired entirely — the two old meanings
   become `objective` (what to minimise) and `schedule` (how to uncompute), and the
   `add`/`mul` picks become `ArithOpts` fields.
5. **Float64 stops being an overload.** `reversible_compile(f, Float64)` should be
   a *frontend mode*, not three arity-specific closures
   (`softfloat_dispatch.jl:130-150`). Take `argtypes::Type{<:Tuple}` uniformly and
   let a `SoftFloatFrontend` wrap arbitrary arity via `ntuple`.
6. **Caching moves out of the API.** The `objectid`-keyed global memo (B2) should be
   an opt-in `cache::CompileCache` object the caller owns, or nothing at all.
   Returning a shared, mutable, globally-memoised `ReversibleCircuit` with a
   "please don't mutate" docstring is not a contract a library can enforce.

Keep the good parts: actionable `ArgumentError`s (the NTuple-ambiguity message at
`Bennett.jl:316-331` is genuinely excellent and should be ported verbatim), up-front
arg-type validation, and the "fail loud, never silently produce a circuit for a VM
request" instinct.

### (b) Test architecture for a reimplementation

The current suite's problem is not size — 692k assertions on a compiler is *good* —
it is that it is a **flat serial list of hand-registered files with three genres
mixed together and no execution model**. Day-one architecture:

**Four tiers, in separate directories, with different cost budgets:**

| Tier | Dir | Content | Budget | When |
|---|---|---|---|---|
| 1. Unit/seam | `test/unit/` | hand-built `ParsedIR` → lower → bennett → simulate, no LLVM (today's `test_8p0g_parsed_ir_seam.jl` is the model) | < 30 s | every save |
| 2. Oracle | `test/oracle/` | exhaustive-Int8 + soft-float bit-exactness vs `Base` | < 3 min, parallel | every commit |
| 3. Property | `test/property/` | seeded generative: random pure Julia fns → compile → invariants | 5 min tunable | every commit |
| 4. Corpus/heavy | `test/corpus/` | transcendental E2E, `.ll`/`.bc` fixtures, multi-language | unbounded, opt-in | pre-push / nightly-local |

**Parallel by construction.** Discover files by directory walk (no manifest ⇒ A3
is structurally impossible), then run tiers 2–4 with one worker per file using
`Distributed`/`ReTestItems.jl`-style workers. Every test file must be *standalone
runnable* (`using Test, Bennett` at the top — enforced by a lint, fixing A2). On a
32-thread box the 28-min suite becomes bounded by its slowest single file, not by
its sum; the 17 transcendental files parallelise perfectly. This is the single
highest-leverage change available.

**Property-based is the tier that is missing today.** The invariants are unusually
well-suited to it: for *any* compiled circuit, (i) ancillae are zero after
execution, (ii) inputs are preserved, (iii) `simulate(c, x) == f(x)` for the native
`f`, (iv) forward∘reverse = identity, (v) `gate_count` is deterministic across
recompiles. A generator over {arith expression trees, bit widths, control-flow
shapes incl. **diamond CFGs**} × {add, mul, schedule, memory plan} would attack the
phi-resolution/false-path-sensitisation class that CLAUDE.md flags as the top
correctness risk — a class currently covered by *hand-written examples added after
each bug*. Every generated case must print its seed and shrink; that also fixes A8
(seed everything, print the run-id, one env var to replay).

**What is a porting asset vs ballast:**

* **Asset (port verbatim):** the soft-float oracle corpus (34 files); the
  exhaustive-Int8 feature tests (39); `verify_reversibility` and its invariant
  definitions; the `.ll`/`.bc` fixture corpus in `test/fixtures/` and `build/`
  (21 files, language-agnostic, architecture-independent — these are pure input
  data and survive any rewrite); the doubling-law *relations*; the actionable-error
  `@test_throws` cases (`test_k0bg`, `test_xlsz`, `test_lgzx`, `test_5oyt`).
* **Ballast (do not port):** every meta-test over source text; the `test_6883_*`
  triplets; the `test_<bead>_*` naming convention itself (see below); the 702
  comment lines in `runtests.jl`; `@test_broken`-wrapped hygiene assertions.
* **Convert, don't port:** the ~90 per-bead admission-contract files. Their *prose*
  is a spec asset → `docs/adr/`. Their assertions collapse into a handful of
  parameterised tables ("these IR shapes are admitted; these fail loud with this
  message class"). 1,265 lines becomes ~80 lines of table plus an ADR.

**Retire the `test_<beadid>_*` convention.** Bead IDs are process metadata with a
half-life; `test_57hd_value_identity.jl` tells a future reader nothing about *what*
is tested without a `bd show`. Name by subject (`test/oracle/softfloat_exp.jl`,
`test/unit/phi_diamond.jl`) and put the bead reference in a header comment. The
convention's one virtue — traceability to the bug — is better served by a
`# regression: Bennett-57hd` line, which greps just as well.

### (c) Gate-count baselines pinned to explicit strategies — keep?

**Keep the principle; change the mechanism in three ways.**

The principle is right and is one of this project's genuinely good ideas: a
reversible compiler's output size is its product, and an unnoticed 2× regression is
as bad as a wrong answer. CLAUDE.md §6's Bennett-hjwp refinement (pin *explicit*
strategies, let `:auto` evolve) is exactly the correct decoupling and should carry
over verbatim.

Three changes:

1. **Separate the *relation* from the *constant*.** `total(2W) = 2·total(W) − 2`
   and `T(2W) = 2·T(W) + 4` are architecture-level theorems about the ripple adder;
   they should be `@test`ed as relations across W ∈ {8,16,32,64} and should *never*
   need editing. The absolute `58` is a frontend-dependent measurement (see §3.1)
   and should live in **one** machine-written file — a `test/baselines.toml`
   regenerated by `julia scripts/update_baselines.jl --review`, with the diff shown
   for human approval. Then a Julia/LLVM upgrade is a single reviewed diff, not a
   20-file manual edit, and the *relations* stay red if lowering actually broke.
2. **Record the environment with the baseline.** Every pinned constant should be
   stamped with `(julia_version, llvm_version, strategy_kwargs)`. A baseline that
   doesn't match the current environment should report "baseline recorded under
   Julia 1.12/LLVM 18, running 1.13/LLVM 20 — regenerate" rather than a bare
   inequality failure. This is the missing piece that makes §3.1 tractable.
3. **Never let a baseline appear in prose.** The docs' 20 copies (A7) should be
   generated from the baselines file at doc-build time, or omitted. A number in
   Markdown that nothing checks is a lie in waiting.

Also keep Bennett-11xt/U23's rule — every pinned count sits next to a
`verify_reversibility` (`test_gate_count_regression.jl:24-27`) — because a
gate-count match is not a correctness proof.

### (d) PRD-per-version + worklog + beads — what carries into a rewrite?

Current state: 11 PRD-class documents (4,544 lines), 109 worklog shards + a 176 KB
index (29,118 lines), 40 design-consensus snapshots, 964 KB of frozen reviews, 650
beads. Prose outweighs source ~2.8:1.

**Carries over, keep as-is:**

* **`bd` (beads).** Durable, queryable, git-backed issue state that survives context
  compaction is the single most valuable process artifact here, and the
  bundled-dolt-commit hygiene rule (`CLAUDE.md:275-293`) shows the convention has
  already been debugged once. Keep it, and keep the "no TodoWrite, no markdown TODO"
  rule.
* **The worklog *as a practice*.** "Write down what a future agent would wish it
  knew that isn't derivable from the diff" is the correct instruction and is why
  this codebase is legible at all. The evidence is strong: nearly every non-obvious
  decision in the API files carries a bead ID and a one-paragraph rationale
  (`Bennett.jl:39-53`, `:404-409`, `:413-418`).
* **CLAUDE.md's non-negotiables 1, 3, 4, 5, 7, 9, 10** (fail loud; red-green;
  exhaustive verification; LLVM IR is not stable; bugs are interlocked; research
  steps explicit; skepticism). These are the project's real institutional memory and
  they are *correct*.
* **No-CI (§14)** is a legitimate maintainer preference; a rewrite should keep the
  pre-push hook and make the local gate *faster* (§5b) rather than argue.

**Carries over, but restructured:**

* **PRD-per-version → one living spec + ADRs.** Six versioned PRDs plus five
  root PRD-class documents is not a spec, it is a stratigraphy: `Bennett-PRD.md`
  (v0.1) describes a compiler that no longer exists, and nothing marks it
  superseded. A rewrite should have exactly **one** `SPEC.md` (current intended
  behaviour, edited in place) plus a numbered, append-only `docs/adr/` for decisions.
  BennettVM already uses ADR numbering (ADR 0003/0017/0018/0020 are referenced
  throughout) — adopt it repo-wide. The 40 `docs/design/*_consensus.md` files become
  ADRs or get deleted; the ~90 admission-contract test headers become ADRs.
* **Worklog → capped and indexed.** 29k lines with a 176 KB index is past the point
  where anyone reads it; the sharding bead (Bennett-fyni) treated the symptom. Cap
  it: worklog entries older than N months get compacted into a decisions digest, and
  anything load-bearing gets promoted to an ADR or to `bd remember` at write time.
  A destructive re-sharding script that CLAUDE.md must warn agents not to run
  (`CLAUDE.md:15`) is a sign the format is fighting its tooling.
* **The 3+1 agent protocol (§2)** demonstrably worked for the phi/false-path class.
  Keep it for the equivalent core (lowering + uncompute scheduling), but scope it to
  a named list of files rather than "core changes", and require the output to land
  as an ADR rather than as three loose files in `docs/design/`.

**Does not carry over:**

* `reviews/` (964 KB of two review generations) — archive with the old repo.
* The convention that every bead gets a test file named after it (§5b).
* CLAUDE.md's file-map section. It is 150 lines of inventory that drifts within
  weeks (A11) and that `ls` answers better. Keep the *rules*, which are timeless;
  delete the *map*, which is not — or generate it.

**One process rule I would add:** a rewrite should adopt "**no test may assert on
source text**". Every one of the six meta-tests in this suite would have been
prevented by it, and A1 — a green suite while doctests are off — is precisely the
failure it prevents.

---

## Bottom line

The API layer is over-parameterised, under-typed, and duplicated four ways; the one
abstraction introduced to fix that (`CompileOptions`) added a fifth representation
and has no callers. The test suite contains a world-class oracle corpus buried in a
1,092-line hand-maintained manifest, executes serially when it is embarrassingly
parallel, and has drifted into testing its own rituals — with at least one meta-test
green while the thing it guards is switched off, and six live test files silently
unwired. The docs are genuinely excellent prose sitting on top of 20 unverified
copies of a constant that only one file actually checks.

None of that is architectural. In a rewrite where code generation is free, this
entire area is a two-day job: one options struct, target types instead of symbols,
directory-discovered parallel tiers, a generated baselines file, one living spec plus
ADRs — and then port the soft-float oracle corpus and the exhaustive-Int8 sweeps
verbatim, because those are the only things here that took real time to be right.
