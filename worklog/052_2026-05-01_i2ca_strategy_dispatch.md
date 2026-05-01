# Bennett.jl Work Log

## Session log — 2026-05-01 — Bennett-i2ca / U55 close (BennettStrategy dispatch)

**Shipped:** see git log around the next commit.

- `src/bennett_strategies.jl` — **new** (~110 LOC): `abstract type
  BennettStrategy` plus 6 concrete subtypes (`DefaultStrategy`,
  `EagerStrategy`, `ValueEagerStrategy`, `CheckpointStrategy`,
  `PebbledStrategy(max_pebbles=0)`, `PebbledGroupStrategy(max_pebbles=0)`).
  Public dispatch:
  - `bennett(lr; strategy::BennettStrategy=DefaultStrategy())`
  - `bennett(lr, strategy)` — multiple-dispatch on the strategy type.
  Five legacy aliases (`eager_bennett`, `value_eager_bennett`,
  `checkpoint_bennett`, `pebbled_bennett`, `pebbled_group_bennett`) kept
  as zero-overhead forwarders (no `@deprecate` — see §"Why" below).
- `src/bennett_transform.jl` — body of `bennett(lr)` extracted to
  private `_bennett_default(lr)`. New helpers `_allocate_copy_wires(lr)
  -> (Vector{Int}, Int)` and `_emit_copy_gates!(result, output_wires,
  copy_wires)` next to existing `_compute_ancillae` / `_build_circuit`.
  The default body now uses both helpers; the duplicated 4-line copy-
  wire block is gone here and in three pebble files.
- `src/pebble/eager.jl` — `eager_bennett` → `_eager_bennett_impl`,
  uses helpers.
- `src/pebble/value_eager.jl` — `value_eager_bennett` →
  `_value_eager_bennett_impl`, uses helpers.
- `src/pebble/pebbling.jl` — `pebbled_bennett` →
  `_pebbled_bennett_impl`, uses `_allocate_copy_wires` only (the
  recursive scheduler builds its own `copy_gates` array).
- `src/pebble/pebbled_groups.jl` — `pebbled_group_bennett` →
  `_pebbled_group_bennett_impl`; `checkpoint_bennett` →
  `_checkpoint_bennett_impl`; the cross-call at line 300 now goes
  direct to `_checkpoint_bennett_impl(lr)` rather than through the
  legacy alias. Internal 5-arg `_emit_copy_gates!` is left alone (it
  takes a `live_map::Dict{Symbol,ActivePebble}` for checkpoint replay
  and coexists with the new 3-arg helper via Julia arity dispatch).
- `src/Bennett.jl` — `include("bennett_strategies.jl")` after the four
  pebble/* files; six new strategy-type exports added next to the
  existing 5-alias export line.
- `test/test_bennett_strategy.jl` — **new** (~110 LOC): per-strategy
  parity asserts (alias gate sequence == kwarg form == positional
  form) on a straight-line incrementer. Dedicated branching-fallback
  testset confirms each variant's internal `return bennett(lr)` still
  routes to `DefaultStrategy` (Bennett-prtp / U04 + rggq / U02
  invariants survived). `MethodError` on a bogus strategy.
- `test/runtests.jl`, `test/PER_SOURCE_INDEX.md`, `CLAUDE.md` —
  updated.

**Why:** U55 catalogue item — six entry points (`bennett`,
`eager_bennett`, `value_eager_bennett`, `pebbled_bennett`,
`pebbled_group_bennett`, `checkpoint_bennett`) shared Phase-1/2/3
scaffolding but were untestable orthogonally. The Phase-2 copy-wire
allocation block (4 lines, identical) appeared in 4 source files. With
strategy dispatch, future variants land as a struct + a single
`bennett(lr, ::NewStrategy)` method without touching the public API
surface.

**Process — 3+1 protocol per CLAUDE.md §2.** Two parallel `Plan`
proposers (each given the same problem statement; neither saw the
other's output), then synthesis + implementation by the orchestrator
(this session). Both proposers converged tightly:
- **Don't** create `src/bennett/common.jl` as the catalogue suggests —
  helpers stay in `bennett_transform.jl` next to existing `_build_circuit`.
- **Don't** rename `_build_circuit` to `finalize_circuit` — pure churn,
  the existing name is accurate.
- 6 concrete strategy types (no `Bennett` prefix — the module already
  namespaces them).
- `max_pebbles` lives on `PebbledStrategy` / `PebbledGroupStrategy`
  structs, not as a kwarg on `bennett`.
- Plain forwarders for the 5 aliases (no `@deprecate`).
- New 3-arg `_emit_copy_gates!` coexists with `pebbled_groups.jl`'s
  existing 5-arg version via arity dispatch.

The single material disagreement was on `bennett_direct`: Proposer B
wanted to absorb it as `DirectStrategy`. Proposer A correctly observed
it's a **precondition guard** (`lr.self_reversing == true || throw(...)`)
that delegates to `bennett(lr)`, not a strategy. Kept Proposer A's call.

**Gotchas / Lessons:**

- **Catch the in-flight refactor before tests run.** I started a
  baseline `Pkg.test()` in the background, then immediately renamed
  `bennett(lr) → _bennett_default(lr)` in `bennett_transform.jl`. The
  background run (which read the current source) tripped on
  `UndefVarError: bennett not defined in Bennett` during precompile —
  because `bennett(lr)` was renamed but `bennett_strategies.jl` wasn't
  yet wired into the include list. **Lesson**: kick off the baseline
  BEFORE any source edits OR use the prior chunk's pinned baseline
  (chunk 051 = 419,291). I switched to the latter.
- **The fallback paths inside pebble/* are the highest-risk diff.**
  Twelve `return bennett(lr)` sites in pebble/{value_eager,pebbling,
  pebbled_groups}.jl exist for branching-CFG / no-groups / in-place
  fallbacks. After the refactor, these route through
  `bennett_strategies.jl`'s 1-arg → 2-arg → DefaultStrategy chain at
  runtime. **NONE** of them changed to `bennett(lr, current_strategy)`
  — that would have caused `_pebbled_bennett_impl` on a branching CFG
  to recursively re-enter itself instead of dropping to canonical
  Bennett. Verified by the new "branching fallback routes to default"
  testset (`test_bennett_strategy.jl`) which exercises every strategy
  on a ternary-branching `lr` and asserts the alias-form and kwarg-
  form return identical gate sequences.
- **`struct` definitions inside `@testset` are illegal.** First draft
  put `struct _BogusStrategy <: Bennett.BennettStrategy end` inside
  the "unknown strategy raises" testset; Julia's `@testset` macro
  wraps the body in `let`, and `struct` is a top-level construct.
  Moved the type definition to file-module scope (and renamed
  `_I2caBogusStrategy` to make its source clear).
- **The cross-strategy delegation site** at
  `pebbled_groups.jl:300` (`return checkpoint_bennett(lr)` inside
  `_pebbled_group_bennett_impl`) is changed to call
  `_checkpoint_bennett_impl(lr)` directly — a name resolution that
  works during file load (`pebbled_groups.jl` defines both `_impl`s)
  rather than waiting for the alias forwarder in `bennett_strategies.jl`
  to load. Same effect, no new forward reference.
- **Docstring on `_bennett_default`** references `BennettStrategy` /
  `DefaultStrategy` which are defined in `bennett_strategies.jl`
  (loaded later). Julia processes docstrings lazily; no load-time
  resolution needed. Verified by the precompile.
- **Internal `bennett(lr)` calls inside the `_*_impl` functions** —
  e.g. `_value_eager_bennett_impl` calls `return bennett(lr)` for its
  empty-groups and branching fallbacks. These are RUNTIME calls; by
  the time anyone calls `bennett(...)`, `bennett_strategies.jl` has
  loaded, so the lookup succeeds. Kept as-is.

**Rejected alternatives:**

- **`@deprecate eager_bennett(lr) bennett(lr; strategy=EagerStrategy())`** —
  emits a depwarn the first time each alias is called per session.
  With 7 test files calling the aliases (test_pebbled_space.jl,
  test_eager_bennett.jl, test_pebbled_wire_reuse.jl, test_value_eager.jl,
  test_prtp_pebbled_branching.jl, test_pebbling.jl,
  test_rggq_value_eager_branching.jl), every `Pkg.test()` would
  produce 5+ depwarn lines. No external consumers, so the warning has
  zero benefit and real cost. Forwarders without `@deprecate` win.
- **`Compat` submodule for the aliases** — overkill for 5 one-line
  wrappers. Forwarders live alongside the dispatch methods in
  `bennett_strategies.jl`.
- **Symbol dispatch (`strategy=:eager`)** — neither proposer
  considered this seriously, but worth noting for the record. Loses
  multiple-dispatch and the ability to attach parameters
  (`PebbledStrategy(max_pebbles=7)` is much cleaner than
  `(:pebbled, 7)`).
- **`abstract type BennettStrategy` in `bennett_transform.jl`** — would
  let bennet_transform.jl directly own DefaultStrategy + the kwarg
  form, leaving only the non-default strategies in
  `bennett_strategies.jl`. Rejected: cleaner to have **all**
  strategy-related code in one file.

**Test count delta:** 419,291 → 419,317 (+26 new asserts from
`test_bennett_strategy.jl`). 3 broken (Aqua advisory + 2 pre-existing),
unchanged. Gate counts unchanged at every site (regression test
`test/test_gate_count_regression.jl` would fail on any drift; it didn't).

**Next agent starts here:** `kv7b` test-coverage epic (~10 sub-items
remaining). Hardest catalogue item now closed; remaining is
test-only work plus `25dm` (blocked on z2dj). The catalogue is at **2
of 173 beads open** = 1.2 % open after this close.
