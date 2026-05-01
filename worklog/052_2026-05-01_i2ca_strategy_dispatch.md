# Bennett.jl Work Log

## Session log — 2026-05-01 (evening) — Bennett-kv7b / U65 close (test-coverage epic)

**Shipped:** see git log around the next commit. The remaining open kv7b
sub-items addressed this session (the prior 8 were closed across chunks
048/049):

- **#03 F9 — `test_two_args.jl` 256/65,536 → exhaustive.** Replaced the
  `Int8(0):Int8(15)` quadrant + 10 corner cases with a full
  `typemin(Int8):typemax(Int8)` cross-product. +65,280 asserts.
- **#03 F11 — persistent-map sanity bounds tightened.** 4 files
  (`test_persistent_interface.jl`, `test_persistent_cf.jl`,
  `test_persistent_okasaki.jl`, `test_persistent_hashcons.jl`) had
  bounds with 100×–5000× spans (`@test gc.total > 100`,
  `@test 100 < gc.total < 500_000`). Replaced with ±20 % regression-
  anchor bounds around 2026-05-01 measurements (404 / 2880 / 26,386 /
  6794 total respectively).
- **#03 F7 — `test_dep_dag.jl` smoke-only → semantic invariants.**
  3 new testsets: topological order (every pred has a strictly smaller
  index than its node), read-after-write correctness (every control-
  wire dep traces back to the latest earlier gate that targeted it),
  and output-node reachability (each output node's target wire equals
  some CNOT-copy source).
- **#05 F5 — `use_memory_ssa=true` end-to-end pipeline pinned.** Two
  new testsets in `test_memssa_integration.jl` exercise the FULL
  `extract_parsed_ir → reversible_compile → simulate → verify_reversibility`
  flow with the flag both off and on, asserting byte-identical
  `gate_count` and `c.gates` output (since `lower()` doesn't yet
  consume memssa info, the flag MUST be a pure pass-through). When
  `lower` starts dispatching on memssa, the byte-identical assertion
  is the right forcing function to convert this to "behaviourally
  equivalent".
- **#05 F9 — add × mul dispatcher kwarg cross.** New file
  `test/test_add_mul_cross.jl`: 12 combinations of `(add ∈
  {auto,ripple,cuccaro,qcla}) × (mul ∈ {auto,shift_add,qcla_tree})` on
  `f(x, y) = x*y + x + y` over Int8, each verified via
  `verify_reversibility` and a 5×5 quadrant simulate sweep.
- **#05 F13 — `controlled(c)` × soft-float / memory-backed.** Two new
  testsets in `test_controlled.jl`: (a) `controlled(reversible_compile
  (soft_fneg, UInt64))` exhaustively swept over 12 IEEE 754 corner
  doubles, asserting bit-exact match against `soft_fneg` after the
  required `Int64 → UInt64` reinterpret; (b) `controlled` of a
  `soft_fmul → soft_fneg` composition (the closest end-to-end-
  lowerable proxy for "memory-backed" — pure var-index local-array
  loads are blocked on Bennett-z2dj T5-P6).
- **#03 F17 / #05 F14 — external tool silent-skip already addressed**
  by Bennett-srsy / U103 (`BENNETT_CI=1` promotes missing-clang /
  missing-rustc / missing-llvm-as to a hard error; default keeps the
  `@info` + `@test_skip` so local contributors aren't blocked).
  Re-confirmed during this grind; no source change needed.
- **#03 F6 — `test_karatsuba.jl` orphaned** is **moot** since
  Bennett-tbm6 / 2026-04-27 deleted `src/multiplier.jl`'s Karatsuba
  branch + the test file along with it.

**Why:** kv7b was the last big-effort catalogue item open after i2ca
landed today. With the 8 prior sub-item closures (chunks 048/049) and
this batch of 8 today, every distinct `kv7b` source-report finding is
either CLOSED or MOOT. The catalogue is now at **1 of 173 beads
open** = 0.6 % (only `25dm` remaining, blocked on `z2dj` T5-P6).

**Gotchas / Lessons:**

- **`simulate(cc, ctrl, x_bits::UInt64)` returns `Int64`, not `UInt64`.**
  The signedness of the `_simulate` return follows the inner buffer's
  signed-int encoding. To compare against `soft_fneg(x_bits::UInt64)`,
  wrap with `reinterpret(UInt64, Int64(on_raw))` — exactly the pattern
  in `test/test_float_circuit.jl`. First draft used `UInt64(on_raw)`
  which raises on negative-as-Int64 inputs.
- **`reversible_compile` doesn't yet handle var-index local arrays.**
  First-pass controlled-memory-backed test used
  `f(x::UInt8, i::UInt8) = let a = [x, …]; a[(i & 0x3) + 1]; end` —
  exactly the catalogue's "memory-backed" exemplar. It hits
  `AssertionError: lower_var_gep!: GEP base Memory{UInt8}[] not found
  in variable wires` because the `:persistent_tree` dispatcher arm
  (z2dj) isn't wired. Substituted `soft_fmul → soft_fneg` (a registered
  soft-float callee whose lowering goes through `softmem.jl`'s MUX-
  store / shadow-memory primitives) as the closest available proxy.
- **`@test expr msg` syntax is invalid in this project's Test version.**
  Tried `@test simulate(c, (x, y)) == f(x, y) "add=$add mul=$mul …"` —
  Test.jl rejected it as "invalid test macro call". Solved by wrapping
  each (add, mul) iteration in its own `@testset "add=$add mul=$mul"`
  block — same context surfaced via testset name in failure output.
- **The first pipeline-end-to-end memssa test hit the same var-gep
  issue as #05 F13.** First draft of the array-using end-to-end
  testset called `reversible_compile(parsed)` on a parsed with
  surviving var-indexed loads. Same `lower_var_gep!` AssertionError.
  Replaced with a multi-arg straight-line function
  (`g(x, y) = x * y + x - y`) that exercises the preprocess+memssa
  combination without retaining unlowerable memory ops.

**Test count delta:** 419,317 → 486,831 (+67,514). Of which:
  - +65,280 from `test_two_args.jl` exhaustive Int8×Int8 sweep
  - +~600 from `test_controlled.jl` soft-float + soft_fmul testsets
  - +~480 from `test_memssa_integration.jl` end-to-end testsets
  - +300 from `test_add_mul_cross.jl` (12 combinations × 25-pair sweep
    + verify_reversibility)
  - +~750 from `test_dep_dag.jl` topological / RAW / output-reachability
  - +4 from persistent-map bounds (4 tightened upper bounds; 4
    tightened lowers)

**3 broken** (Aqua advisory + 2 pre-existing) — unchanged.

**Next agent starts here:** `25dm` (only remaining catalogue item,
blocked on `z2dj` T5-P6 IN-PROGRESS). The catalogue is effectively
**done** — the only open work is downstream of an in-flight P2 item
that's not part of the review-cycle backlog itself. Future agents:
when z2dj lands, the var-gep-blocked tests in this session
(`controlled(reversible_compile(f, UInt8, UInt8))` for
var-index-array `f`, and the `array-using function` end-to-end memssa
test) can be REINSTATED — replace the `soft_fmul`/`g(x,y)` proxies
with the original var-index pattern. Both are flagged with comments
naming z2dj.

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
