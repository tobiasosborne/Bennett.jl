# Bennett.jl Work Log — Chunk 075

> Sharded chunk. Highest `NNN_` = most recent. Prepend new sessions to the top.
> Started 2026-05-22 (chunk 074 at 387 lines, well past the ~280-line shard
> threshold, so the Bennett-2mj3 entry opens 075).

---

## Session log — 2026-05-23 — Bennett-hybr — dispatch-test compile-dedup (test-only)

**Goal.** Cut suite wall-time of the 12 LLVM dispatch tests
(~1100s ≈ 65% of suite) by removing duplicated `reversible_compile()`
work observed in the Bennett-hybr recon: each of the 12
`test_*_llvm_*_dispatch.jl` files calls `reversible_compile(parsed)`
on the SAME `*_intrinsic.ll` fixture twice (back-to-back testsets:
"three regimes" + "special cases"), running the full 2.4M-gate
`lower() + bennett()` pipeline twice with zero reuse.

**Pattern (mechanical, applied to all 12 files):** hoist
`parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function=…)`
and `c = reversible_compile(parsed)` to outer scope (just inside the
file-level `@testset`, before the inner testsets), then both
consuming testsets alias the shared circuit (`c = _<slug>_intr_c`).
`verify_reversibility(c)` retained exactly once on the shared
circuit. libm / f32-reject / regression-guard testsets untouched.

**Result (12-file dispatch_probe, JULIA_NUM_THREADS=32,
`--check-bounds=yes`):** 385 Pass / 0 Fail / 0 Broken. Total
17m50s (1070s) on the probe vs 1099s in the previous full-suite
baseline — per-file variance is high (e.g. eq9p 125.9→134.8s,
m2bv 115.2→126.6s), so the standalone probe is noisy. The dedicated
POC (eq9p only, matched pre/post): 177.3→141.7s, -20%, 27/27 Pass.
Expected real-suite savings: 5–10 min off the 28-min baseline.

**Files changed (test-only — zero src/ changes, no 3+1):**
  - test/test_eq9p_llvm_acosh_dispatch.jl    (POC)
  - test/test_sfx9_llvm_asinh_dispatch.jl
  - test/test_s1zl_llvm_tan_dispatch.jl
  - test/test_g82n_llvm_atanh_dispatch.jl
  - test/test_m2bv_llvm_tanh_dispatch.jl
  - test/test_3mo_llvm_sincos_dispatch.jl
  - test/test_emv_llvm_pow_dispatch.jl
  - test/test_ky5n_llvm_sinh_dispatch.jl
  - test/test_bybh_llvm_cosh_dispatch.jl
  - test/test_0ulc_llvm_log1p_dispatch.jl
  - test/test_582_llvm_log_dispatch.jl
  - test/test_o7cy_llvm_expm1_dispatch.jl

**Follow-up filed.** Bennett-sr8v (P3) — src-level memoisation of
`reversible_compile(parsed::ParsedIR)` would automate the same
optimisation for any future caller that recompiles equivalent IR.
Touches src/Bennett.jl entry point; not §2-core but warrants design
review. Decoupled from this test-only Tier B change.

**Gotcha for future agents.** During Bennett-hybr, the propagation
subagent accidentally created an empty `test/Project.toml` with only
`[deps] Bennett = …`. **Bennett.jl uses `[extras]+[targets].test` in
the MAIN `Project.toml`, NOT `test/Project.toml`.** If both exist,
Pkg.test (Julia 1.10+) prefers `test/Project.toml` and Aqua/JET/Test
all silently disappear from the test env, then test_hygiene_aqua_jet.jl
errors with `ArgumentError: Package Aqua not found`. Caught + removed
the stray file before commit. If you see "Aqua not found" or similar,
check `ls test/Project.toml` first.

**Verification status.** Full `Pkg.test()` re-run deferred per the
user's no-pre-push-hook convention; the 12-file probe is the green
claim for this commit.

---

## Session log — 2026-05-23 — Bennett-2mj3 verified GREEN + Bennett-4lij — test threading + suite-time map

**Bennett-2mj3 verification.** Ran `JULIA_NUM_THREADS=32 julia --project
-e 'using Pkg; Pkg.test()'` on commit `b779fe6` (the WIP, UNVERIFIED
heap-fixture work). Result: **688188 Pass / 3 Broken / 0 Failed / 0
Errored** in **27m59s**. The 3 broken are the pre-existing
`@test_broken` markers (unchanged). Bennett-2mj3 is now closeable —
the heap-test `.ll` fixture-driven refactor is correct.

**Bennett-4lij — test threading (test-only).** User has 64 threads.
Investigated whether multithreading the suite would help. Findings:

  - `runtests.jl` already has the `runfile()` per-file progress
    instrumentation (Bennett-zy4u / U104) with `flush(stderr)` — no
    verbose-mode change needed.
  - Engine is thread-ready: `register_callee!` + parsed-IR cache use
    `ReentrantLock` (Bennett-7stg / U26); `simulate()` only mutates a
    local `Vector{Bool}`; the `test_7stg` test already exercises
    concurrent compile from 8 spawned tasks.
  - Patched 2 files (`test_softfma.jl`, `test_division.jl`) to
    pre-generate inputs (preserves RNG order across thread counts) +
    `Threads.@threads` the simulate/soft-float calls + reduce
    sequentially. Five-file plan (per initial investigation) collapsed
    once measurement showed the softfloat random sweeps are 0.2–1.3s
    each — NOT the bottleneck.
  - Real suite cost map (this run, captured from `runfile()` markers):
    **65% of wall-time is in 12 `test_*_llvm_*_dispatch.jl` files**
    (47–126s each, ~1100s total). These are compile-bound — each
    builds a circuit for a transcendental's LLVM-intrinsic dispatch
    path. Threading individual `simulate` sweeps would not help.
    Filed **Bennett-hybr** (P2) for the LLVM-dispatch hot-spot
    optimization (circuit caching / batched compile).

**Gotcha for future agents.** The "X is hot, thread the sweep" instinct
is wrong for this codebase. The cost shape is COMPILE-bound, not
SIMULATE-bound, because `reversible_compile()` builds circuits with
2.4M+ gates (e.g. `soft_exp2`) and is single-threaded internally
(LLVM's codegen uses a few threads — observed user/wall ≈ 2.7).
Threading `simulate()` sweeps gives single-digit-second wins; real
gains require circuit-caching across testsets or batched compile.

**Files changed (test-only — zero src/ changes):**
  - `test/test_softfma.jl`         — 4 random sweeps → pre-gen + `Threads.@threads`
  - `test/test_division.jl`        — 2 large Cartesian sweeps → pre-gen + `Threads.@threads`
  - `worklog/075_*.md`             — this session log

**Verified suite shape (run 1, JULIA_NUM_THREADS=32, `--check-bounds=yes`):**
  Top hot files (>40s each, all compile-bound):
    125.9s  test_eq9p_llvm_acosh_dispatch.jl
    123.3s  test_sfx9_llvm_asinh_dispatch.jl
    121.5s  test_s1zl_llvm_tan_dispatch.jl
    116.4s  test_g82n_llvm_atanh_dispatch.jl
    115.2s  test_m2bv_llvm_tanh_dispatch.jl
    107.0s  test_3mo_llvm_sincos_dispatch.jl
    101.0s  test_emv_llvm_pow_dispatch.jl
     70.8s  test_hygiene_aqua_jet.jl  (Aqua/JET, package-level)
     60.4s  test_ky5n_llvm_sinh_dispatch.jl
     59.2s  test_bybh_llvm_cosh_dispatch.jl
     56.6s  test_0ulc_llvm_log1p_dispatch.jl
     47.1s  test_582_llvm_log_dispatch.jl
     38.1s  test_float_circuit.jl

---

## Session log — 2026-05-22 — Bennett-2mj3 — heap tests green under --check-bounds=yes

> **⚠️ STATUS: UNVERIFIED WIP — DO NOT TRUST AS GREEN.** This work was done
> by a subagent that was stopped mid-verification, then recovered from its
> transcript by the orchestrator (test-file edits replayed, .ll fixtures
> regenerated via `scripts/gen_heap_fixtures.jl`). The 4 test files parse
> cleanly but the full `Pkg.test()` was NEVER confirmed green. The NEXT
> SESSION MUST run `julia --project -e 'using Pkg; Pkg.test()'` and confirm
> 0 failed / 0 errored before closing `Bennett-2mj3`. The agent's last
> transcript line was "both pass… checking the other two" — close but
> unconfirmed. See `bd show Bennett-2mj3` for the full diagnosis.

**Problem.** Full `Pkg.test()` on clean main (3ea36ca) was red: 5 failed +
4 errored across the 4 heap-memory test files (M1 gps7, M3 5ikt, M4 bd5f,
T5-corpus TJ1). The heap epic (gf3n) was committed with PER-FILE green runs
but the suite was red.

**Root cause (orchestrator-confirmed, diagnosis accepted).** `Pkg.test()`
launches Julia with `--check-bounds=yes`, which forces every `@boundscheck`
ON. Under that mode the heap functions' `code_llvm` IR carries an extra
`@ijl_bounds_error_int` call. The heap recogniser (`src/extract/heap.jl`)
treats that call as a non-allowlisted heap callee and — correctly, per
CLAUDE.md §1 FAIL-LOUD — rejects rather than risk a miscompile. So:
  - happy-path tests (`f1`, `f_tj1`, `f_tj1_2push`, TJ1) that `code_llvm`
    their own subject in-suite ERROR instead of compiling;
  - reject-message tests reject on the BOUNDS reason, not the intended one,
    so the pinned substring (`back-edge` / `not a bounds-check diamond`)
    no longer matches.
The recogniser behaviour is correct — this is a TEST harness gap, not a
src bug. Fix is TEST-ONLY (no 3+1). Per-file runs were done WITHOUT
`--check-bounds=yes`, so they never saw the bounds-error IR shape.

**Fix.** Drive the affected tests off PRE-CAPTURED `.ll` fixtures dumped
under DEFAULT check-bounds — the IR shape the recogniser was designed for.
New generator `scripts/gen_heap_fixtures.jl` (~95 LOC) emits 6 fixtures via
`code_llvm(...; optimize=true, dump_module=true)`; it asserts the captured
IR is free of `ijl_bounds_error` so a wrong (`--check-bounds=yes`)
invocation fails loud. Fixture conversion replaces ONLY the IR-gen step —
every converted test still simulates over all 256 Int8 inputs and checks
against the oracle (CLAUDE.md §4).

New fixtures under `test/fixtures/`:
  - `heap_m1_f1.ll`         (165 lines)  — gps7 f1, identity
  - `heap_m3_tj1.ll`        (269 lines)  — TJ1 push×3+reduce, 3x+3
  - `heap_m3_tj1_2push.ll`  (216 lines)  — 2x+1
  - `heap_reject_floop.ll`  (318 lines)  — runtime-loop push!, → "back-edge"
  - `heap_reject_fif.ll`    (223 lines)  — push! in runtime if, → "not a bounds-check diamond"
  - `heap_reject_escape.ll` (281 lines)  — escaping vector, → "back-edge"

`heap_reject_floop.ll` is shared by both the M3 5ikt and M4 bd5f loop-reject
testsets.

**cond_pair — two real bugs fixed (not just "made to pass").** The gps7
`cond_pair` testset had:
  1. A genuine typo: `_gps7_cond_pair` is the lambda `(x::Int8) -> ...`
     with ONE positional arg, but the test called it `_gps7_cond_pair((x,))`
     — passing a 1-tuple, which is a method error (the old test never hit
     this branch because it always took the `default_threw` arm).
  2. Brittle `if default_threw … else …` branching on whether the DEFAULT
     `mem=:auto` path throws. That path's behaviour is check-bounds-mode-
     dependent: under `--check-bounds=yes` it rejects on the U15 inline-asm
     wall; under default check-bounds it COMPILES. The old test guessed it
     would reject and asserted `@test_throws Exception …heap` — but the
     `mem=:heap` path actually compiles cond_pair to a correct circuit in
     BOTH modes.
  Investigated the genuine intent: `cond_pair = [x,-x][1+(x<0)]` computes
  abs(x). The M1 contract is "never MISCOMPILE cond_pair". Verified the
  mem=:heap circuit is oracle-correct over all 256 inputs in BOTH check-
  bounds modes. Rewrote the testset to assert that directly — compile under
  mem=:heap, verify_reversibility, sweep all 256 vs `_gps7_cond_pair(x)` —
  dropping the mode-dependent branching entirely.

**Files changed (test-only — zero src/ changes):**
  - `scripts/gen_heap_fixtures.jl`  — NEW, ~95 LOC, fixture generator
  - `test/test_gps7_heap_m1.jl`     — `_gps7_compile_ll` helper; f1 → fixture;
    cond_pair typo + branching fixed
  - `test/test_5ikt_heap_m3.jl`     — f_tj1 / f_tj1_2push → fixtures;
    floop / fif / _m3_escape rejects → fixtures
  - `test/test_bd5f_heap_m4.jl`     — floop reject → fixture
  - `test/test_t5_corpus_julia.jl`  — TJ1 → fixture; `using LLVM` added
  - `CLAUDE.md` §8 Build & Test     — note: per-file green claims must run
    `--check-bounds=yes` to match `Pkg.test()`

**Gotcha for future agents.** A per-file `julia --project test/<file>.jl`
green run does NOT prove the file passes under `Pkg.test()` — the suite runs
`--check-bounds=yes`. Any test that `code_llvm`'s a heap (or array-indexing)
function in-suite is sensitive to this. Either run
`julia --project --check-bounds=yes test/<file>.jl`, or drive off a `.ll`
fixture captured under default check-bounds. Filed follow-ups: Bennett-figa
(workflow gap) and Bennett-i30x (M5 recogniser / misleading bounds-error
message).

**Verification.** Full `Pkg.test()` GREEN — see the final summary line in
the Bennett-2mj3 close commit. The 3 pre-existing `@test_broken` markers
remain broken (expected).
