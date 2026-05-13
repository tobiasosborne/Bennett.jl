## Session log — 2026-05-13 — Bennett-ao66 vector intrinsic scalarisation

Implemented `Bennett-ao66`: vector-form LLVM intrinsic calls in
`src/extract/vectors.jl` now scalarise lane-wise instead of failing with
`unsupported vector opcode LLVMCall`.

Design / implementation notes:

* Added `_VectorLaneValue`, an extractor-local adapter that implements
  `_iwidth` / `_operand` for already-resolved lane operands. This lets
  vector calls reuse the existing scalar `_handle_intrinsic` dispatch
  table without constructing fake LLVM `CallInst`s or duplicating the
  scalar intrinsic lowering logic.
* `_vector_shape` now accepts floating-point vector element types as
  bit-pattern lanes, enabling `<2 x i64> <-> <2 x double>` vector
  bitcast plumbing for `llvm.sqrt.v2f64` and `llvm.fma.v2f64`.
* `extractelement` now uses `_type_width` instead of `LLVM.width`, so
  extracting a `double` lane works before scalar bitcast back to `i64`.
* Vector `LLVMCall` handling rejects scalar-return vector calls
  (reductions), non-LLVM vector calls, poison/undef lane reads, and
  vector intrinsics whose scalar handler returns `nothing`.
* Reviewer catch: broad scalar handler reuse could silently miscompile
  floating-point `llvm.minimum` / `llvm.maximum` / `llvm.minnum` /
  `llvm.maxnum`, because their current scalar handlers use integer
  `IRICmp` on bit patterns. Added fail-loud rejection for floating
  vector min/max forms until a bit-exact soft-float implementation is
  designed.
* Reviewer catch: `llvm.abs`, `llvm.ctlz`, and `llvm.cttz` with poison
  immarg `true` can produce poison for lane-dependent inputs. Added
  fail-loud validation for non-constant or `true` poison immargs in the
  vector scalarisation path. `i1 true` can appear as `ConstOperand(-1)`.
* Explicitly did not add ConstantFP vector-lane decoding. Direct
  `<2 x double> <double ...>` constants still fail loud in
  `_resolve_vec_lanes`; current f64 fixtures use integer bit-pattern
  vectors plus vector bitcast. Future support needs NaN-payload-aware
  ConstantFP decoding.

Tests added:

* `test/test_ao66_vector_intrinsic_rescalarise.jl`
* Raw `.ll` fixtures for `llvm.smax.v4i64`, `llvm.umax.v2i64`,
  `llvm.abs.v4i32`, `llvm.sqrt.v2f64`, `llvm.fma.v2f64`,
  unsupported `llvm.expect.v4i64`, rejected `llvm.sqrt.v2f32`,
  rejected poison `llvm.abs.v4i32(..., true)`, and rejected
  `llvm.minimum.v2f64`.
* The ao66 test is included in `test/runtests.jl`.

Validation completed:

* `julia --project test/test_ao66_vector_intrinsic_rescalarise.jl`
  passed: 41/41.
* `julia --project test/test_vector_ir.jl` passed.
* `julia --project test/test_cc07_repro.jl` passed.
* Wrapped direct runs of `test/test_1pb_llvm_transcendentals.jl` and
  `test/test_h6f_llvm_fma_dispatch.jl` passed: 44/44 and 14/14.
* Reviewer agent re-review found no blocking findings after the min/max
  and poison-immarg guards; only a low-severity i1-width nit, which was
  fixed.

Validation caveat:

* Full `julia --project -e 'using Pkg; Pkg.test()'` did **not** complete
  with a clean final status in this session. One attempt was interrupted
  by the user while it was still running; an earlier attempt lost final
  output after the long soft-float/corpus sections even though no Julia
  process remained. A redirected attempt failed before startup because
  the Julia launcher could not create a lockfile on a read-only sandbox
  path. Based on the focused extractor/vector/intrinsic tests and
  reviewer pass, the change is likely correct, but the next handoff
  should rerun full `Pkg.test()` serially from a clean shell.

---

## Session log — 2026-05-13 — Bennett-k31q stale close (`test_t0_preprocessing` memset allowlist gap no longer reproduces)

**Closed:** `Bennett-k31q` as stale/already-fixed by the current
`Bennett-9nwt` memset handling and current Julia/LLVM IR shape.

Ground-truth read before action:

* `Bennett-k31q` claimed `test/test_t0_preprocessing.jl` failed because
  `cond_pair` hit a raw `llvm.memset.p0.i64` extraction error and the
  test allowlist did not include `memset`.
* Current `test/test_t0_preprocessing.jl` only measures extraction and
  preprocessing store/alloca survival; it does not simulate the corpus.
* Current `_handle_memset_arm` already has the intended `c == 0`
  silent-drop Case A and precise fail-loud handling for unsupported
  `c != 0` shapes.
* Existing `test/test_9nwt_memset_const.jl` already pins the relevant
  memset behavior, including `c=0 N=8` silent drop and reject cases.

Validation:

* `julia --project test/test_t0_preprocessing.jl` passed. Current
  `cond_pair` does **not** enter `skipped`; it extracts as `raw=3,
  post-pp=3` dynamic-index memory ops. `array_even_idx` has the same
  shape. Corpus total remains 6 surviving stores+allocas.
* `julia --project test/test_9nwt_memset_const.jl` passed: 82/82.

Decision:

* Do **not** broaden the T0 allowlist with `memset`. That would weaken
  the canary without a current failure. If a future Julia/LLVM version
  reintroduces a fail-loud memset skip, the test should surface it and
  the exact shape should be investigated under `Bennett-8bys` or a new
  narrower bead.
* No source/test edits were warranted. The only durable changes are the
  bead close and this worklog note.

---

## Session log — 2026-05-13 — project orientation + beads workflow check

Orientation-only session. Read `README.md`, `AGENTS.md`, `CLAUDE.md`,
top-of-index `WORKLOG.md`, latest worklog shard 063, `src/Bennett.jl`,
`test/runtests.jl`, and sampled the current source/test layout. No
compiler source changes.

Project shape confirmed:

* Public entry point is `reversible_compile`, with tuple/scalar overloads
  in `src/Bennett.jl` and Float64 SoftFloat dispatch in
  `src/softfloat_dispatch.jl`.
* Pipeline is LLVM.jl C-API extraction -> `ParsedIR` -> `lower` ->
  Bennett transform -> simulation/diagnostics.
* `src/lower.jl` and `src/ir_extract.jl` are now split into
  `src/lowering/*` and `src/extract/*` include trees, but the root files
  remain core pipeline surfaces for the 3+1 rule.
* Current recent frontier per worklog is Tier C2 transcendental work:
  `soft_log1p` and `soft_expm1` landed on top of completed Tier C1
  hyperbolics. Important gotcha from 063: every
  `startswith(cname, "llvm.<intrinsic>")` prefix match needs a trailing
  dot when matching LLVM intrinsic families, or sibling names like
  `llvm.expm1.*` can be swallowed by `llvm.exp.*`.

Beads workflow learned/verified:

* Always start with `bd prime` for local workflow context.
* Use `bd ready` / `bd show <id>` / `bd update <id> --claim` to start
  work, and `bd close <id> --reason="..."` to close completed work.
* Do not run multiple `bd` commands concurrently in this checkout: the
  embedded Dolt backend takes an exclusive lock. A parallel `bd ready`
  overlapped with `bd prime` and failed with the expected lock error.
* Current `bd stats`: 481 total issues, 35 open, 3 in progress, 432
  closed, 35 ready. Current in-progress beads observed:
  `Bennett-cc0.5`, `Bennett-tzrs`, `Bennett-z2dj`.
* `bd ready -n 20` shows the top ready queue including `Bennett-7kzr`,
  `Bennett-8guh`, `Bennett-25dm`, `Bennett-ponm`, `Bennett-2uas`,
  `Bennett-ktt8`, `Bennett-glh`, and `Bennett-fg2`.
* `bd prime`/`bd stats` warn `.beads` has mode 0755; recommendation is
  0700. They also try a Dolt auto-push, which fails in the sandboxed
  environment because `github.com` cannot resolve. That failure did not
  block local reads.
* `bd` read commands dirtied embedded Dolt files under
  `.beads/embeddeddolt/...`; treat this as tool-state side effect, not a
  source change or bead close.

Validation:

* Julia smoke check required escalation because the launcher needed to
  create normal user-level lock/config files. Approved prefix:
  `julia --project`.
* Smoke command:
  `julia --project -e 'using Bennett; c = reversible_compile(x -> x + Int8(1), Int8; add=:ripple); println(gate_count(c)); println(simulate(c, Int8(5))); println(verify_reversibility(c))'`
* Result: precompiled Bennett, then printed
  `(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)`, `6`, `true`.
  This matches the pinned explicit ripple i8 increment baseline.

Minor observation for future cleanup: several comments in
`src/softfloat/fasinh.jl`, `facosh.jl`, `fatanh.jl`, and `fsinh.jl`
still say Bennett lacks `soft_log1p` / `soft_expm1`. That was true when
those files landed, but is now historical after the 0ulc/o7cy commits.
Do not "fix" casually if a cleanup bead exists; those comments document
why the original wider polynomial regimes were chosen.
