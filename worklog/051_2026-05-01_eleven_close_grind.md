# Bennett.jl Work Log

## Session log — 2026-05-01 — Bennett-8403 / U159 close (per-source test homes)

**Shipped:** see git log around the next commit.

- `test/test_bennett.jl` — new (31 asserts): `_SUPPORTED_SCALAR_ARGS`
  whitelist, `CompileOptions` defaults, kwarg-form ↔ opts-form
  equivalence, kwarg-validation rejections, `_is_supported_arg_type`
  coverage including the Bennett-3rph Float32 deviation.
- `test/test_lower.jl` — new (6 asserts): `lower()` entry-point
  validation — unknown add/mul strategies → ArgumentError, unknown
  `target` → ArgumentError, `target=:depth` pre-resolves
  `mul=:auto → :qcla_tree` (Bennett-4fri / U30), Bennett-httg
  loop-without-`max_loop_iterations` contract.
- `test/test_ir_extract.jl` — new (8 asserts): top-level
  `extract_parsed_ir` shape invariants (args, blocks count for
  Collatz-style truly-branching IR, sret aggregate ret_elem_widths,
  Tuple-overload ↔ ParsedIR-overload round-trip equivalence).
- `test/PER_SOURCE_INDEX.md` — navigation index documenting every
  src/X.jl ↔ test/* mapping and the per-subdir convention.
- `test/runtests.jl` — include the three new files.

**Why:** U159 catalogue item — test layout doesn't mirror src;
regression-targeted edits get scattered across feature suites with no
canonical home for "this src file's behavior". Establishing
`test/test_X.jl` per `src/X.jl` would be 30+ files for top-level
src files alone (70+ counting subdirs); the catalogue named only
three (`test_bennett.jl`, `test_lower.jl`, `test_ir_extract.jl`).
Pragmatic close: create those three substantively + a markdown
navigation index for the rest.

**Gotchas / Lessons:**

- **Test failures from premise drift while writing the file.** First
  pass had `lower() rejects unknown add strategy` expecting
  `ErrorException` — but the vpch codemod just turned that exact site
  into `ArgumentError`. Second pass had `for _ in 1:4; ...` as the
  loop-detection test — but Julia/LLVM unrolls a literal-bounded
  range at IR-extract time, so no back-edge survives, so lower()
  succeeds. Switched to a Collatz-style data-dependent loop that LLVM
  cannot fold; that one DOES leave a back-edge.
- **`x > 0 ? x+1 : -x` is single-block in LLVM IR** — folded to
  `select`. For "branching IR" tests, use truly side-effect-y or
  unfoldable branches (e.g. inside a loop body) so `length(blocks)
  >= 2` holds.
- The 70+ src files aren't worth one stub each; the index doc is
  the right abstraction. Future agents adding regressions for src/X
  should grep PER_SOURCE_INDEX.md first; if test_X.jl exists, use
  it; if not, create one as a stub and append to the index.

**Tests:** `Pkg.test()` clean — 419291 asserts pass (+45 new across
3 new files). 3 broken (1 advisory Aqua ambiguities + 2 pre-existing).

**Next agent starts here:** `kv7b` epic still has a long tail of test
sub-items; `i2ca` strategy sprawl needs 3+1; `25dm` blocked on z2dj.
The clean-quick wins on the catalogue are now exhausted at the P3/P4
tier — the remaining work is either large (i2ca, kv7b) or blocked
(25dm).

## Session log — 2026-05-01 — Bennett-sa39 / U211 close (BenchmarkTools harness)

**Shipped:** see git log around the next commit.

- `benchmark/Project.toml` — new environment Project (no name/uuid/version
  — it's a Julia env, not a package) listing BenchmarkTools 1.x and
  Bennett (via `[sources] = {path=".."}`).
- `benchmark/timing_bench.jl` — new BenchmarkTools-based compile-time
  benchmark with 4 measurements: tiny `x+1` Int8 + Int64, medium
  Cuccaro adder Int32, heavy `soft_fadd` Float64. Each uses
  `@benchmark` with small samples (2-5) and generous wall-clock cap
  (15-120s) since each compile is slow.

Run with: `julia --project=benchmark benchmark/timing_bench.jl`.

**Why:** U211 catalogue item — the existing `bc{1..6}_*.jl` and
`sweep_*.jl` files measure GATE-COUNT metrics (Toffoli, ancillae,
depth) but not WALL-CLOCK time. Compile time is a real concern (post-
Bennett-qxg9 the soft_fadd path went 33× faster from a perf bug fix
in worklog/048; the regression-prevention motivation is exactly to
catch a recurrence). BenchmarkTools.jl gives proper trimmed-mean
timings + memory allocs and is the Julia-ecosystem standard.

**Gotchas / Lessons:**

- **`Pkg.develop(path="..")` overwrites the Project.toml.** It strips
  comments + custom fields. After running it the carefully-written
  `[sources]`-style Project.toml became 3 lines. Solution: write the
  Project.toml after the develop step, OR (cleaner) use the modern
  `[sources]` block from the start and just `Pkg.instantiate()` —
  Julia 1.11+ supports `[sources]` natively without `Pkg.develop`.
- **Avoid fake UUIDs.** Started with `1f37c4d4-2026-05-01-aaaa-...`
  (the date pretending to be a UUID). Pkg's UUID parser hard-failed
  with "Malformed UUID string". Replaced with a real
  `UUIDs.uuid4()`-generated UUID (`96478d28-...`). Eventually dropped
  name/uuid/version entirely once I realised this is an environment,
  not a package.
- **`cd benchmark` persists between Bash tool calls.** Burned ~3
  minutes when an early `cd benchmark && julia ...` left CWD in the
  benchmark dir; subsequent `Pkg.develop(path="..")` then created
  `benchmark/benchmark/Project.toml` (doubled path). Cleaned up by
  `rm -rf benchmark/benchmark/`. Lesson: stick to `--project=benchmark`
  from the repo root, never `cd`.
- **Don't add BenchmarkTools to main `Project.toml [extras]`.** It
  would precompile during every `Pkg.test()` even when not used,
  inflating `using Bennett` time. Separate `benchmark/Project.toml`
  is the Julia convention (mirrors `docs/Project.toml`).

**Tests:** Main `Pkg.test()` clean — same baseline asserts pass; no
behavior change. Smoke benchmark on `x + 1` Int8 reports ~1.7ms median
(post-warmup, single-eval, 2 samples).

**Next agent starts here:** `8403` (per-source unit tests). Big P2
items unchanged.

## Session log — 2026-05-01 — Bennett-58rl / U214 close (dolt-cache commit hygiene documented)

**Shipped:** doc-only — `CLAUDE.md` "Beads Issue Tracker" section
gains a "Dolt-cache commit hygiene" subsection documenting the
bundled-commit convention.

**Why:** U214 catalogue item — flagged that ~half of the last 60
commits (as of 2026-04-22) were "bd: sync dolt cache" standalone
commits, polluting the git log. The convention has since changed:
zero standalone dolt-cache commits in the last 60 commits at close
time. The fix here is to DOCUMENT the bundled-commit convention so
future agents don't reintroduce the standalone-commit pattern.

The catalogue's other two fixes — separate branch, history rewrite —
are destructive (would lose 122 historical bd-close-and-sync commits)
or break beads' git-as-transport mechanism. The "gitignore the cache
entirely" alternative isn't viable because beads uses the
`.dolt/git-remote-cache/` blobs as the sync layer.

**Gotchas / Lessons:**

- 122/450 commits (~27 %) in total history are "bd: sync dolt cache"
  standalone commits. Last 60 commits: ZERO. The hygiene shift has
  already occurred organically; documenting it just pins it.
- An agent who runs `bd close <id>` and finds ONLY `.beads/`
  modifications in `git status` should treat that as a "did you
  actually do the work" red flag — no source changes means the close
  was probably premature or the bead was filed against state that
  changed in some other way. Documented the check in CLAUDE.md.

**Tests:** N/A (doc-only).

**Next agent starts here:** `8403` (per-source unit tests), `sa39`
(BenchmarkTools port). Big P2 items unchanged.

## Session log — 2026-05-01 — Bennett-fidj / U217 close (liveness × :auto coverage)

**Shipped:** new file `test/test_fidj_liveness_auto_dispatcher.jl` —
17 asserts pinning that `:auto` add strategy is liveness-independent,
i.e. `lower(parsed; use_inplace=true, add=:auto)` and `lower(parsed;
use_inplace=false, add=:auto)` produce identical gate counts and both
match `:ripple` (per the post-Bennett-spa8 / U27 contract).

Three testsets:
1. `x + 1` straight-line: 4-corner matrix `(use_inplace ∈ {true, false}) × (add ∈ {:auto, :ripple})` all four agree.
2. `x*x + x` multi-use: even when liveness analysis sees a re-used arg, `:auto` (= ripple) is unaffected.
3. End-to-end `reversible_compile` (which uses `use_inplace=true` by default): `:auto` matches `:ripple` and the circuit reverses correctly across `Int8(-5):Int8(5)`.

The "loop-tests-Int8-only" half of fidj is already covered by
`Bennett-kv7b` (test_loop.jl spans Int8/Int16/Int32/Int64).

**Why:** U217 catalogue item — the `:auto` dispatcher's
liveness-independence was an implicit invariant. Adding the test pins
it so a future change to `_pick_add_strategy(:auto)` that
re-introduces a liveness branch would shift gate counts and fail this
test loudly.

**Gotchas / Lessons:**

- `use_inplace` is a `lower()` kwarg, NOT a `reversible_compile`
  kwarg, so the test reaches one level deeper via `Bennett.lower(parsed;
  use_inplace, add)`. End-to-end smoke at `reversible_compile` level
  exercises only `use_inplace=true` (the default).
- `:auto → :ripple` is the post-U27 contract. If `:auto` ever
  legitimately changes to `:cuccaro` or `:qcla` for a particular
  shape, this test will fail and the new contract should be encoded
  here explicitly.

**Tests:** `Pkg.test()` clean — 419246 asserts pass (+17 new).

**Next agent starts here:** `8403` (per-source unit tests), `sa39`
(BenchmarkTools port), `58rl` (dolt-cache out of git history). Big P2
items unchanged.

## Session log — 2026-05-01 — Bennett-gk1h / U210 close (Aqua.jl + JET.jl hygiene gates)

**Shipped:** see git log around the next commit.

- `Project.toml` — Aqua (0.8) + JET (0.10) added as test-only deps (under `[extras]` + `[targets].test`).
- `test/test_hygiene_aqua_jet.jl` — new file with three testsets:
  1. `Aqua.test_all` with `ambiguities=false`, `piracies=false`, `deps_compat=false` — covers the high-signal checks (unbound args, undefined exports, project_extras, stale_deps).
  2. `@test_broken Aqua.test_ambiguities` — advisory; LLVM.jl + Base operator overload set produces transient ambiguities.
  3. JET `report_package` smoke — pin the report count under 200 so a 10× balloon catches regression without mandating zero (pure Julia `@inline` lowering surfaces lots of "redefining method" noise that JET flags).
- `test/runtests.jl` — include the new file at the end of the outer `@testset "Bennett"`.

**Why:** U210 catalogue item — no static-analysis hygiene gates. With
`Pkg.test()` the only quality gate (per CLAUDE.md §14, no GitHub CI),
catching a stray ambiguity or undefined export by Aqua's eye is the
cheapest way to keep the surface clean.

**Gotchas / Lessons:**

- **`Aqua.deps_compat` flags InteractiveUtils** because stdlib deps
  don't carry `[compat]` bounds (they ride the Julia version). The
  per-check escape hatches `check_extras=false, check_weakdeps=false`
  don't apply to the main `[deps]` section in Aqua 0.8 — had to
  disable `deps_compat` wholesale. Non-stdlib direct deps (LLVM,
  PrecompileTools, Aqua, JET) DO have compat entries; the disable
  only removes the in-test reminder.
- **Ambiguities check left as `@test_broken`** rather than trying to
  fix every transient ambiguity introduced by LLVM.jl operator
  overloads. The catalogue rule is "add the gate", not "drive
  ambiguities to zero". Future agents can graduate this from
  `@test_broken` to `@test` once the surface stabilises.
- **`Pkg.test()` runs the test suite in an isolated environment** —
  Aqua/JET in `[extras]` are only visible there. Direct `julia
  --project test/test_hygiene_aqua_jet.jl` fails with `Aqua not
  found`; the only way to exercise the test is via `Pkg.test()`.
  Tests added a few seconds to total runtime (12.4s for Aqua + JET).

**Tests:** 419229 asserts pass (vs 419226 prior; +3 from new testsets).
3 broken (1 new for ambiguities advisory + 2 pre-existing).

**Next agent starts here:** `8403` (per-source unit tests), `sa39`
(BenchmarkTools port), `fidj` (P4), `58rl` (dolt-cache out of git
history). Big P2 items unchanged.

## Session log — 2026-05-01 — Bennett-3rph / U137 close (Float32 deviation documented)

**Shipped:** Doc-only — `README.md`, `CLAUDE.md` rule §13, and
`src/softfloat/fpconv.jl` docstring header gain explicit "Float32 is
NOT bit-exact" deviation notes. Native 24-bit-mantissa f32 primitives
(`soft_f32_fadd`, …) filed as **Bennett-e283** (P4 feature) for
future work.

**Why:** U137 catalogue item — Float32 arithmetic via `fpext → f64-op
→ fptrunc` double-rounds and is not bit-exact against hardware f32.
The catalogue allows two fixes: implement native or document the
deviation. Documenting now is the no-new-code path; the actual
implementation lives in e283 to be picked up later.

**Gotchas / Lessons:**

- `Float32` is already not in `_SUPPORTED_SCALAR_ARGS` in
  `src/Bennett.jl`, so `reversible_compile(f, Float32)` already raises
  `ArgumentError` at validation. The deviation only matters for f32
  ops that arrive INSIDE Float64-entry mixed-precision IR — those go
  through fpext→f64→fptrunc unconditionally and could surprise the
  caller about the 1-ulp double-rounding gap. Documenting in the
  fpconv.jl header (where every reader of soft_fpext / soft_fptrunc
  lands) is the highest-signal location.
- The bit-exact contract in CLAUDE.md §13 was previously written
  unqualified ("Every soft-float function must be bit-exact"). Updated
  to "Float64 only" + a pointer to fpconv.jl. Future agents adding f32
  paths should restore the unqualified form once e283 lands.

**Tests:** `Pkg.test()` clean — no behavior change; doc-only.

**Next agent starts here:** `8403` (per-source unit tests), `gk1h`
(Aqua.jl/JET.jl), `sa39` (BenchmarkTools), `fidj` (P4
liveness×:auto), `58rl` (dolt-cache out of git history). The big
P2 epics (i2ca strategy sprawl needs 3+1; kv7b test coverage epic;
25dm T5 corpus blocked on z2dj) remain.

## Session log — 2026-05-01 — Bennett-vpch / U45 close (typed-exception codemod)

**Shipped:** see git log around the next commit. Per-site classification
codemod across `src/` converting plain `error("...")` to typed
`throw(ArgumentError|DimensionMismatch|AssertionError(...))` per the
catalogue rule:

- bad-arg / unknown-enum / "must be >= N" on caller-supplied scalar → `ArgumentError`
- wire/length/element-count mismatch → `DimensionMismatch`
- internal invariant (private predicate that always holds given lowering's own state) → `AssertionError`
- "not supported / unhandled / coverage gap" → stay as plain `error()` (`ErrorException`)

**Counts** (29 src/ files touched, 176/176 lines insertions/deletions):

- ArgumentError: ~45 sites (bad enum, range-violating scalars)
- DimensionMismatch: ~46 sites (length(args) != length(arg_widths) class)
- AssertionError: ~55 sites (provenance map invariants, predicate-wire
  shape contracts, IRPhi pre/latch incoming postconditions, ...)
- Left as ErrorException: ~57 sites (every "ConstantFP operand not
  supported", "VectorType reached scalar _type_width", etc.)

**Why:** U45 catalogue item — 190+ `error()` sites all threw
`ErrorException`; tests couldn't target specific failure categories.
With typed exceptions, future tests can write `@test_throws
ArgumentError` on caller-validation paths, `@test_throws
DimensionMismatch` on wire-length contracts, etc.

**Process:** I converted `src/ir_types.jl` (17 constructor-validation
sites — clean ArgumentError / 1 DimensionMismatch case) by hand, then
spawned a sub-agent to handle the remaining 28 files with the same
classification rule.

**Gotchas / Lessons:**

- **Test-side `@test_throws ErrorException` is the constraint.** ~24
  source sites that catalogue rules called for typed exceptions had to
  be REVERTED back to plain `error()` because existing tests assert
  `@test_throws ErrorException foo()` (or `e isa ErrorException`).
  Filed as **Bennett-imz7** (P3 follow-up) — tighten the test side
  first, then convert source. List of reverted sites is in the bead
  description.
- **Width/shape checks split between ArgumentError and DimensionMismatch
  was per-site judgment.** A `width >= 1` check on a single scalar
  argument is ArgumentError (the arg is bad). `length(args) ==
  length(arg_widths)` is DimensionMismatch (two parallel quantities
  must match). The agent applied the split consistently after I
  documented it.
- **Sub-agent approach worked well** for this kind of mechanical-
  with-judgment work. The agent reported back its full revert list
  and final test count (419220 passed) in one structured response.

**Tests:** `Pkg.test()` clean — 419220 asserts pass; gate counts
unchanged at every site.

**Next agent starts here:** still-open catalogue items in priority order:
`8403` (per-source unit tests), `3rph` (Float32), `gk1h` (Aqua.jl),
`sa39` (BenchmarkTools), `fidj` (P4), `58rl` (dolt cache out of git
history). The big P2 epics (`i2ca` strategy sprawl, `kv7b` test
coverage, `25dm` T5 corpus blocked on z2dj) remain.

## Session log — 2026-05-01 — Bennett-u2yp / U149 close (drop sat_pebbling + PicoSAT)

**Shipped:** see git log around the next commit. Pure deletion:

- `src/pebble/sat_pebbling.jl` (211 LOC) — removed.
- `test/test_sat_pebbling.jl` (50 LOC) — removed.
- `src/Bennett.jl` — drop the include line.
- `test/runtests.jl` — drop the include line.
- `Project.toml` — drop PicoSAT from `[deps]` + `[compat]`.
- `Manifest.toml` — regenerated (PicoSAT + 4 transitive deps removed; precompiled-package count dropped 38 → 34).
- `CLAUDE.md` — updated Project.toml description + sat_pebbling.jl line.

**Why:** U149 catalogue item — `sat_pebbling.jl` was 211 LOC of unwired
code carrying a PicoSAT dependency. Never invoked from any strategy
dispatcher (`bennett`, `eager_bennett`, `value_eager_bennett`,
`pebbled_bennett`, `pebbled_group_bennett`, `checkpoint_bennett`); only
the standalone `sat_pebble` function in `test_sat_pebbling.jl` exercised
it. The Meuli et al. 2019 algorithm itself is interesting; the *current*
PicoSAT backend is too weak by 2025 standards (per `Bennett-fg2` P2,
which proposes Kissat/CaDiCaL). Deleting now means we don't carry a dep
that has zero callers; when fg2 lands a modern SAT backend, it can
re-introduce sat_pebbling.jl atop it.

**Gotchas / Lessons:**

- **Pkg.rm errored visibly but actually succeeded** — final `grep
  PicoSAT Manifest.toml` was empty. The transient error was Julia
  trying to access something during the rm; the manifest was correctly
  rewritten. Worth noting for future `Pkg.rm` calls — don't trust the
  exit code alone, check the manifest.
- **The `Bennett-fg2` task description still says "replace PicoSAT…"**
  — left unchanged for now since the wording is comprehensible
  (replace = re-introduce a SAT solver, just better). When that bead is
  picked up the description should be tweaked to "introduce
  Kissat/CaDiCaL backend + restore sat_pebbling".
- The `pebble/` subdir now contains 4 files (was 5). `dep_dag.jl`
  wasn't in `pebble/` — listed at the top level.

**Tests:** `Pkg.test()` clean — same baseline asserts pass; net -261
LOC; -1 prod dep (PicoSAT) + -4 transitive precompile deps.

**Next agent starts here:** `vpch` (typed exception codemod, ~162 sites)
remains the next big P2 piece, then `8403` (per-source unit tests),
`3rph` (Float32), `gk1h` (Aqua.jl), `sa39` (BenchmarkTools), `58rl`
(dolt cache), `fidj` (P4).

## Session log — 2026-05-01 — Bennett-x2iw / U88 close (BlockLoweringOpts bundle)

**Shipped:** see git log around the next commit. Three changes in
`src/lowering/`:

1. **`Base.@kwdef struct BlockLoweringOpts`** added in `types.jl`. Fields
   match the 11 optional kwargs that `lower_block_insts!` and
   `lower_loop!` were carrying separately:
   `block_pred, ssa_liveness, inst_counter, gate_groups, compact_calls,
   globals, add, mul, alloca_info, ptr_provenance, entry_label,
   loop_headers`. Each defaults to a fresh empty container (or sentinel)
   so a bare `BlockLoweringOpts()` is the trivial-input call.

2. **`lower_block_insts!` (driver.jl)** signature collapsed from 11
   kwargs → `opts::BlockLoweringOpts = BlockLoweringOpts()`. Body uses
   `opts.<field>` for every state read.

3. **`lower_loop!` (cfg.jl)** signature collapsed similarly. `block_order`
   moved from kwarg → 10th positional (its real callers always pass the
   function-level Dict; the `Symbol[]` default was vestigial). Body
   updated: `block_pred → opts.block_pred`, `inst_counter → opts.inst_counter`,
   the LoweringCtx constructor now reads `opts.compact_calls`,
   `opts.alloca_info`, `opts.ptr_provenance`, `opts.globals`,
   `opts.mul`, `opts.entry_label`. The hard-coded `:ripple` for
   loop-body adders is preserved (Bennett-y986 invariant).

The 1 caller in `driver.jl` builds a `block_opts` once outside the per-
block loop and threads it into both `lower_loop!` and
`lower_block_insts!` — alloca_info / ptr_provenance dicts persist
across blocks of the same function as required (Bennett-cc0 M2a).

**Why:** U88 catalogue item — `lower_block_insts!` carried 15 kwargs
(11 after the vdlg split). Bundling into a single struct surfaces the
"this is per-function lowering state, not per-call configuration"
intent and keeps the kwarg API surface from creeping further as more
context fields get added.

**Gotchas / Lessons:**

- **`_collect_loop_body_blocks` reads `loop_headers`** inside
  `lower_loop!`'s body. Easy miss: the bare-name `loop_headers`
  reference at cfg.jl:196 silently became a Bennett-module global
  lookup once the kwarg was removed, surfacing as
  `UndefVarError: loop_headers not defined in Bennett` at first test
  run. Fixed by switching to `opts.loop_headers`. Lesson: when
  refactoring kwargs into a bundle, grep the body for ALL kwarg names
  including ones that were used incidentally (passed through to inner
  helpers).
- **`block_order` as positional in `lower_loop!`** is a small API
  improvement — the kwarg default `Symbol[]` was a Vector while every
  real caller passed the `Dict{Symbol,Int}` from `lower()`. Now the
  signature documents the real contract.
- The `BlockLoweringOpts` bundle is built ONCE per function (outside
  the `for label in order` loop in `driver.jl`) and shared across
  every block call. The mutable fields (alloca_info, ptr_provenance,
  block_pred, gate_groups, inst_counter Ref) accumulate across blocks
  as before — no per-block dict identity reset.

**Tests:** `Pkg.test()` clean — 418k+ asserts pass; gate counts
unchanged.

**Next agent starts here:** `vpch` (typed exception codemod, ~162
sites) or `u2yp` (drop sat_pebbling.jl + PicoSAT dep).

## Session log — 2026-05-01 — Bennett-u71l / U161 close (CompileOptions struct)

**Shipped:** see git log around the next commit. Three changes:

1. **`Base.@kwdef struct CompileOptions`** added in `src/Bennett.jl` with
   all 9 fields (`optimize`, `max_loop_iterations`, `compact_calls`,
   `bit_width`, `add`, `mul`, `strategy`, `fold_constants`, `target`).
   `const _DEFAULT_COMPILE_OPTIONS = CompileOptions()` is the single
   source-of-truth for defaults.

2. **All three existing kwarg overloads** (Tuple, ParsedIR, Float64)
   now reference `_DEFAULT_COMPILE_OPTIONS.<field>` for their kwarg
   defaults instead of repeating literal defaults. The kwarg API surface
   is unchanged — every existing caller keeps working.

3. **Three new overloads** accept `opts::CompileOptions` positionally
   and forward each field as a kwarg:
   - `reversible_compile(f, arg_types::Type{<:Tuple}, opts)`
   - `reversible_compile(parsed::ParsedIR, opts)`
   - `reversible_compile(f, ::Type{Float64}[, ::Type{Float64}[, ::Type{Float64}]], opts)`
   Per-overload applicability enforced via `_check_field_at_default`:
   ParsedIR rejects non-default `optimize`/`bit_width`/`strategy`;
   Float64 rejects non-default `bit_width`. Same error class as the
   existing kwarg cross-rejection (`ArgumentError`).

**Why:** U161 catalogue item — three overloads carried divergent kwarg
surfaces with literal defaults duplicated in three places. With this
change, the struct is the canonical place defaults live, and users with
a config they want to reuse can pass `CompileOptions(...)` once.

**Gotchas / Lessons:**

- **No deprecation of the kwarg paths yet.** The catalogue suggested
  "deprecate kwarg-only paths" but that would emit warnings on every
  one of the 565 existing kwarg call sites — too noisy for one PR. Left
  the kwarg API in place; the struct is additive. Future deprecation
  can ride on top.
- **Struct field order matches the kwarg ordering** in the existing
  signatures, so each forwarded field reads in sync with the kwarg
  signature.
- **`_check_field_at_default` uses `==` against the default** so a
  user passing `CompileOptions(bit_width=0)` to ParsedIR is OK
  (default), but `bit_width=8` raises. This matches the kwarg-side
  intuition: "this option doesn't apply on this overload."
- The Float64 overload is variadic over `Type{Float64}...` (1, 2, or 3
  args). The CompileOptions wrapper provides explicit 1-/2-/3-arg
  methods rather than chasing the splat — three short methods are
  clearer than one method with index-walking. Same fan-out the kwarg
  side already does internally.

**Tests:** `Pkg.test()` clean — same baseline asserts pass; zero gate-
count drift; new smoke tests confirm the opts-form gates match the
kwarg-form gates exactly.

**Next agent starts here:** `x2iw` (BlockLoweringOpts — `lower_block_insts!`
takes 15 kwargs).

## Session log — 2026-05-01 — Bennett-iwv5 / U90 close (softfloat + persistent → submodules)

**Shipped:** see git log around the next commit. Two namespace cleanups:

1. **`src/softfloat/softfloat.jl`** — wrapped contents in `module SoftFloatLib`
   with explicit `export` for the 32 public `soft_*` primitives. The ~75
   internal helpers (`_add128`, `_sub128`, `_neg128`, `_shiftRightJam128`,
   `_sf_normalize_to_bit52`, `_sf_handle_subnormal`, `_sf_round_and_pack`,
   `_sf_widemul_u64_to_128`, `_EXP_TAB`, `_EXPM1B_*`, `_LOGBO256*`,
   `_TWO_POW_NEG_*`, …) and bit-pattern constants (`EXP_MASK`, `FRAC_MASK`,
   `IMPLICIT`, `INDEF`, `QNAN`, `QUIET_BIT`, `INF_BITS`) are now module-
   private. `Bennett.jl` adds `using .SoftFloatLib` after the include so all
   downstream files (`softmem.jl`, `callees.jl`, `lowering/*`, `extract/*`,
   `softfloat_dispatch.jl`) keep their unqualified `soft_fadd(...)`
   references.

2. **`src/persistent/persistent.jl`** — same pattern, `module Persistent`,
   exporting `AbstractPersistentMap`, `PersistentMapImpl`,
   `verify_pmap_correctness`, `verify_pmap_persistence_invariant`,
   `pmap_demo_oracle`, `LinearScanState`, `LINEAR_SCAN_IMPL`,
   `linear_scan_pmap_{new,set,get}`, `soft_feistel32`, `soft_feistel_int8`.
   Tests reaching `Bennett.linear_scan_pmap_*` continue to resolve via the
   re-export.

**Why:** U90 catalogue item — the bare-`include`-list pattern leaked ~110
internal symbols into `Bennett.*`. Encapsulating them is a structural-only
change with no behaviour delta; gate counts and verify_reversibility paths
are unchanged because the exported public surface is bit-identical.

**Gotchas / Lessons:**

- **Module name had to deviate from the catalogue's `module SoftFloat`
  suggestion.** `src/softfloat_dispatch.jl` already defines a user-facing
  `struct SoftFloat` at `Bennett` top level. Naming the module the same
  forces either a struct rename (user-visible breaking change) or
  `Bennett.SoftFloat.SoftFloat` from outside (gross). Picked
  `SoftFloatLib` and documented the rationale at the top of
  `src/softfloat/softfloat.jl`.
- **`using .Sub` is enough** — names imported into `Bennett` via `using`
  are accessible as `Bennett.<name>` from outside (verified by
  `Bennett.soft_fadd`, `Bennett.linear_scan_pmap_new` working in tests
  unmodified). No need for explicit `import .Sub: name` re-export.
- **Three white-box tests** reached for private softfloat helpers via
  `using Bennett: _foo` / `Bennett._foo`. Updated to
  `Bennett.SoftFloatLib._foo`, which preserves the encapsulation goal
  (private helpers stay private; only this test reaches in by qualified
  path):
  - `test/test_tpg0_normalize_zero_input.jl` — `_sf_normalize_to_bit52`
  - `test/test_xiqt_subnormal_boundary.jl` — `_sf_handle_subnormal`
  - `test/test_yys3_uint128_compiler_rt.jl` — `_sf_widemul_u64_to_128`,
    `_add128`, `_sub128`, `_neg128`
- The `research/` subdir under `src/persistent/` is NOT loaded by the
  module (consistent with prior `Bennett-uoem / U54` decision); it stays
  outside the `module Persistent` boundary. CLAUDE.md description updated
  to reflect this.

**Tests:** `Pkg.test()` clean — 418k+ asserts pass (same count as 2026-05-01
v958/ehoa/lm3x baseline); zero new failures, zero gate-count drift.

**Next agent starts here:** continuing the catalogue grind; `iwv5` was the
hardest pure-LOC namespace refactor remaining. Next up per today's plan:
`u71l` (CompileOptions), `x2iw` (BlockLoweringOpts), `vpch` (typed errors).

