# Bennett-t9rh — orchestrator review of proposals A and B

2026-09-24. Maintainer decision (asked explicitly): **pinned CPU = `x86-64-v3`** on x86_64,
`"generic"` elsewhere.

## Consensus (both proposers, independently verified by experiment)
- Root cause: `code_llvm(optimize=true)` runs Julia's NewPM O-pipeline under the host JIT
  TargetMachine; TTI drives SLP/loop vectorisation + unroll. On AVX-512, SLP emits a horizontal-add
  idiom with a poison lane (`shufflevector <1, poison>` → `add` → only lane 0 extracted); the
  scalariser emits a scalar op for the dead lane, Bennett has no DCE, `resolve!` asserts.
- The poison-lane crash is NOT AVX-512-only (A: `k` array loop crashes on AVX2 / haswell / v3).
- Silent gate-count drift across hosts is real and large (B: udiv callee 825,319 x86-64 /
  1,594,161 haswell / 12,594,211 Zen3; F64 sqrt 431,289 / 791,317 / 5,798,513). The session `-O`
  level is a second hidden input.
- Fix = both: (b) host-independent `optimize=true` IR by re-running Julia's own
  `JuliaPipeline(opt_level=2)` in-process under a pinned `TargetMachine`, and (a) sound poison
  propagation in the lane-wise scalariser arms (LangRef §Poison Values; select-arm refinement per
  InstSimplify), observation points keep failing loud.

## Resolved differences
1. **IR acquisition — take A's.** Use the UNSTRIPPED unoptimised module
   (`InteractiveUtils._dump_function_llvm(mi, src, false, false, true, false, :none, params)` with
   code_llvm's params), run the pinned pipeline, then emulate `jl_dump_function_ir`'s strip
   (RemoveJuliaAddrspacesPass, clear non-debugloc instruction metadata, erase dbg intrinsics,
   clear global metadata, strip_debuginfo!). A showed that optimising the already-stripped
   `optimize=false` text (B's recipe) is NOT faithful for memory code (tbaa + addrspace(10) lost;
   Vector/Dict fns optimise differently); B's 59/60 fidelity check was over the soft_* family only.
   A's path reproduced native `code_llvm(optimize=true)` for Vector/Dict/soft-float fns when pinned
   to the host CPU, and `julia -C <cpu>` output when pinned to <cpu>.
2. **CPU — maintainer chose `x86-64-v3`** (A's recommendation; byte-identical to haswell/skylake for
   the soft-float family; keeps cc0.7 SLP coverage). B preferred `x86-64` (smaller loop circuits);
   recorded as the alternative. Implement as ONE named constant.
3. **Opt level pinned to 2** (both); no env var / kwarg override (B) — a hidden input is what we
   are removing. An internal `cpu=` hook for tests only.
4. **Poison propagation scope — take B's superset:** binop, icmp, cast, select, AND the lane-wise
   intrinsic loop (propagate before `_validate_vector_intrinsic_lane`/`_handle_intrinsic`).
   Keep loud: extractelement of a poison lane (fix message: yields scalar poison, which Bennett
   cannot represent — not "UB"), reductions, `<N x i1>`→iN bitcast, `resolve!` backstop.
5. Route `extract_parsed_ir`, `extract_parsed_ir_by_sig(optimize=true)` and `extract_ir` through
   one helper (Rule 12). `optimize=false` path byte-identical to today.

## Tests (union)
A's host-independent `.ll` poison fixtures (hadd, splat_shl, cmp_sel exhaustive, all-poison dead
op, observed-poison fail-loud, reduce/bitcast still throw, structural no-sentinel check); bead repro
bit-exact + pins (fneg∘fmul, soft_fma, soft_fcmp_olt — values under v3 to be measured and pinned);
host-independence subprocess test (`-C x86-64` and `-C znver3` processes must reproduce in-process
counts for a vector-sensitive fixture, e.g. ls_demo_16 + soft_fcmp_olt + a loop fn); fidelity canary
(subprocess `-C x86-64-v3` `code_llvm(optimize=true)` vs in-process pinned output, normalised).
Re-run all pinned-count files (B's list of 22 + test_gate_count_regression).

## Follow-ups to file
`have_fma` codegen-time host dependence of `Base.fma(::Float64)`; optional vectoriser-off pipeline
(B: smaller loop circuits) as a separate decision; CLAUDE.md Rule 5 addendum (never study host
`code_llvm(optimize=true)`; use `Bennett.extract_ir`).
