# 083 — 2026-06-15 — env-drift repairs: JET de-list + T5 HashMap hash-robustness

**Context:** running the full `Pkg.test()` gate (to validate the additive CW-D1a/D1b
work before pushing) surfaced TWO pre-existing environment-drift failures on this
machine — both unrelated to the CW-D work, both blocking the gate AND the push (the
pre-push hook runs the same `--check-bounds` suite). The 2026-06-10 handoff records a
green 688655-assertion suite, so the env has drifted since (this machine also had the
reference PDFs absent). Repaired both; suite now GREEN (688697 pass, 0 fail, 0 error,
2 expected `@test_broken`). User chose the JET stopgap (env-gate) explicitly.

## 1. JET test-dep breaks Pkg.test (Bennett-37ib)
`JET = "0.10"` (test-only dep, used solely by `test/test_hygiene_aqua_jet.jl`) crashes
during its OWN precompile workload on Julia 1.12.5 (`include_package_for_output` →
JET `virtualprocess.jl`). Pkg.test precompiles the test env EAGERLY, so JET crashed at
setup, aborting the whole suite (exit 1) before any Bennett test ran. Gating the test
file alone could NOT help (the crash is pre-runtests). Fix (stopgap, Bennett-37ib):
- **`Project.toml`**: commented JET out of `[targets]` test, `[extras]`, `[compat]`
  (so the test env never resolves/precompiles JET). One-line restore each, once JET is
  repaired (update to a 1.12.5-compatible JET).
- **`test_hygiene_aqua_jet.jl`**: `using JET` made resilient (try/catch → `_JET_OK`,
  honors `BENNETT_SKIP_JET`); the JET static-analysis testset is gated on `_JET_OK` and
  auto-runs again once JET is restored to `[targets]`. Aqua portion untouched.

## 2. T5 HashMap acceptance test pinned a drift-prone mangled hash (Rule 5)
`test_land_ptrfield_struct.jl:257` (T5 acceptance) pinned the exact Rust mangled name
`...HashMap$LT$K$C$V$GT$3new17hd5ce489df0fbe51fE`, but the committed
`build/t5_tr2_hashmap.ll` actually mangles it `...17he9858c4ee88d18a9E` — i.e. the test
and the committed fixture were committed INCONSISTENTLY. The test had been "passing"
only by being SKIPPED when the fixture was absent (06-10 env); on this machine the
fixture is present, so it ran → "entry function not found" → uncaught → errored. This
is a Rule-5 violation (mangled `17h<hash>E` suffix is not a stable API). Fix:
- Find `HashMap::new` by its STABLE demangled substring
  (`r"_ZN3std…HashMap\$LT\$K\$C\$V\$GT\$3new17h[0-9a-f]+E"`) at runtime instead of
  pinning the hash; skip cleanly if absent.
- With the name resolved, HashMap::new hits the **Bennett-dv1z heterogeneous-sret
  wall** (it returns a `HashMap` struct by sret; only `[N x iM]` aggregates supported).
  Per the test's OWN spec ("EITHER compile OR clean fail-loud"), a dv1z reject IS a
  clean fail-loud — added `:dv1z_sret_reject` to the accepted outcomes. (Notably the
  same dv1z wall is on the CW-D closed-world runway; this test flips to `:compiled`
  when heterogeneous-sret support lands.)

## Validation
Full `julia --project -e 'Pkg.test()'` (`--check-bounds=yes`, the project default ==
the pre-push hook's gate): **exit 0, "Testing Bennett tests passed"**, 0 fail / 0 error
/ 2 expected broken. CW-D1a 15/15, CW-D1b 30/1, gate-count 39/39 all green in-suite.
Pushed with `SKIP_PUSH_TESTS=1` (the manual run IS the hook's gate — avoids a redundant
~85-min re-run; per the project's documented manual-gate-then-skip pattern).

## Follow-up
`Bennett-37ib` (P1) tracks the proper JET fix (restore `[targets]`/`[extras]`/`[compat]`
+ the `_JET_OK` gate auto-re-enables). The dv1z heterogeneous-sret support is CW-D
runway work (Bennett-dv1z / bennettvm-x3t0).
