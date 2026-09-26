# Astra review — B-tests-api — 2026-09-26
Status: IN PROGRESS
Scope: test/, src/Bennett.jl, README.md, docs/src/, Project.toml, Manifest.toml, precompile workload; fail-fast survey outside core lowering.
Method: Read CLAUDE.md in full. Read-only audit and focused Julia probes with bounds checks; no full suite. Only this report is written, as specifically instructed; no worklog, issue-tracker, or git mutations.

## Executive summary

Pending completion.

## Findings

### F1 — [S1] The doctest guard passes while all Documenter doctests are disabled
- Where: `test/test_doh6_docs_makejl.jl:23`; `docs/make.jl:13,56`; `test/test_wlf6_jldoctest_fences.jl`.
- Evidence: `julia --project --check-bounds=yes test/runtests.jl test_doh6_docs_makejl.jl __astra_no_such_test__` prints **14/14 passed**. The guard searches the entire file for `doctest=true`, which occurs in a comment on line 13; the actual `makedocs` argument on line 56 is `doctest = false`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: every executable documentation example can regress while the nominal doctest invariant remains green. Fence-presence tests do not execute those examples either.
- Fix: enable and execute Documenter doctests as a local gate; remove the raw substring proxy. Keep any structure checks separate from the claim that examples execute.
- Test: deliberately change a documented expected result and confirm the local documentation gate fails.
- Already tracked? **Bennett-gygy**, accurately described and still reproducible. The earlier c6 A1 finding remains valid.

### F2 — [S2] A misspelled filter is silently accepted when any other filter matches
- Where: `test/runtests.jl:22-26,1176-1185`.
- Evidence: a sole `__astra_no_such_test__` exits 1 with “matched no test files”; the same argument alongside `test_doh6_docs_makejl.jl` exits **0**, runs one file and reports 14 passes. Command and output are given in F1. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a multi-file chunk lists one valid filename and one typo (or a research file gated off); only the valid file runs, and the command succeeds. This is material to the chunked validation described in worklog/108.
- Fix: count matches per supplied pattern, reject any unmatched pattern, and report selected-but-disabled files separately. Validate arguments before running files. Also reject unknown dash-prefixed arguments instead of dropping all of them (line 22), which otherwise turns an intended filter into a full run.
- Test: assert nonzero exit for `[valid, typo]`, for an explicitly selected disabled research file, and for an unknown option. Preserve successful single-pattern and unfiltered runs.
- Already tracked? **Bennett-uxyy** is closed; its aggregate no-match protection works, but does not cover this case. No separate open bead found.

### F3 — [S2] The documented standalone test command cannot run 69 test files
- Where: `test/test_increment.jl:1`; 69 files lacking a Test import; `CLAUDE.md` Build & Test and rule 8.
- Evidence: a lexical inventory finds **69/328** test files without `using Test` or `import Test`; these rely on the imports in runtests. `julia --project --check-bounds=yes test/test_increment.jl` exits 1 with `UndefVarError: @testset not defined in Main` at line 1. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: contributors follow the prescribed quick check and fail at `@testset`, before testing the feature. Several files also depend on Bennett imports from the runner.
- Fix: make every file import its own dependencies, or consistently document `julia --project --check-bounds=yes test/runtests.jl <filename>` as the supported per-file command and stop claiming standalone execution.
- Test: run the documented increment command in a fresh Julia process; validate each advertised standalone file without inheriting Main from runtests.
- Already tracked? c6 A2 was correct and remains applicable. **Bennett-gm83** calls these files standalone; **Bennett-figa** covers bounds-check parity, not missing imports.

### F4 — [S1] Captured closures compile successfully with an extra, undocumented input
- Where: `src/Bennett.jl:281-399` (no validation/binding of callable environment); `src/extract/entry.jl` → module argument extraction; `README.md:24` claims “Any pure Julia function”.
- Evidence: `using Bennett; mk(k)=x->x+k; f=mk(Int8(7)); c=reversible_compile(f,Int8); println(c.input_widths); simulate(c,Int8(5))` prints **[8, 8]** then `simulate(circuit, input) requires single-input circuit, got 2 inputs`. Same result with `optimize=false`; native `f(Int8(5))` is 12. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: an ordinary pure Julia closure is accepted as a unary function, but its captured environment becomes caller-supplied circuit input. A loop that captures a type parameter similarly exposed two inputs during this review.
- Fix: bind immutable captured fields as compile-time constants and exclude the callable environment from the public argument register, or reject non-singleton callable environments up front with an actionable message until supported. Do not return a circuit whose arity contradicts the requested signature.
- Test: compile closures capturing Int8 constants (different values), singleton type parameters, and a callable struct; assert the requested input widths and all 256 native outputs, with simulator invariants enabled.
- Already tracked? No matching open bead found. **Bennett-40ys** concerns instance-less callees in the closed-world walker, not this public unary-closure acceptance.

### F5 — [S1] Zero or negative verifier sample counts certify a dirty circuit without executing it
- Where: `src/diagnostics.jl:239-278`.
- Evidence: `c=reversible_compile(x->x+Int8(1),Int8); push!(c.gates,NOTGate(first(c.ancilla_wires))); for n in (0,-1,1); try println(n," => ",verify_reversibility(c;n_tests=n)) catch e println(sprint(showerror,e)) end end` prints **0 => true**, **-1 => true**, then for 1 reports `ancilla wire 9 not zero after forward pass`. Mutation exists only in that probe process. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a computed or misconfigured sample budget becomes nonpositive; the exported checker returns the same success value as a verified circuit despite a deterministic ancilla leak.
- Fix: require `n_tests > 0` with ArgumentError before the loop. Consider exhaustive enumeration for sufficiently small domains, separately from sample-count validation.
- Test: deliberately dirty circuit with zero and negative budgets must reject the budget; positive budget must detect the dirty ancilla.
- Already tracked? No matching bead found; **Bennett-asw2** fixed the older forward/reverse-only tautology, but not the empty-loop case.

## Unconfirmed suspicions

## What is sound (brief)

## Nits (S4)

## Coverage log

- CLAUDE.md read in full.
- Inventory: 328 test files, 328 unique registrations, no orphans. Six research files default off; T5/heavy default on.
- Reproduced explicit ripple/fold x+1 counts: Int8 58/12, Int16 114/28, Int32 226/60, Int64 450/124 (total/Toffoli); verifier true and 256 native comparisons per width. All exported names defined on Julia 1.12.3.
