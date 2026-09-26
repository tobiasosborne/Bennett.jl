# Astra review — B-tests-api — 2026-09-26
Status: COMPLETE
Scope: test/, src/Bennett.jl, README.md, docs/src/, Project.toml, Manifest.toml, precompile workload; fail-fast survey outside core lowering.
Method: Read CLAUDE.md in full. Read-only audit and focused Julia probes with bounds checks; no full suite. Only this report is written, as specifically instructed; no worklog, issue-tracker, or git mutations.

## Executive summary

21 outstanding findings: **2 S0, 11 S1, 8 S2**; one additional S1 was fixed concurrently and reverified.
The S0 defects are wider-return truncation by tabulation and stale compilation after Julia method redefinition; both pass reversibility verification.
Mutation probes show green tests with an identity Feistel hash, an empty ABI extraction set, a broken callee lookup, and an injected compiler exception.
Other API gaps include captured closures, over-wide simulator inputs, missing Float64 fma dispatch, and inconsistent Float64 call forms.
The 30-file sample finds incomplete Int8 oracle sweeps; doctests remain disabled behind a passing guard.
All requested ripple baselines and every plotted depth series reproduce; all initial 328 test files are registered (329 after the concurrent fix).
README/tutorial examples were executed, with specific copy-paste failures recorded. No full suite or repository code changes were made by this reviewer.

## Findings

### F6 — [S0] `strategy=:tabulate` silently truncates a wider return to the first input's width
- Where: `src/Bennett.jl:358-360,384-386`; `src/tabulate.jl:140-152`; `test/test_tabulate.jl`.
- Evidence: `square_wide(x::Int8)=Int16(x)*Int16(x); c=reversible_compile(square_wide,Int8;strategy=:tabulate); println(c.output_elem_widths, " ", simulate(c,Int8(20)), " ",verify_reversibility(c))` prints **[8] -112 true**. The expression strategy prints **[16] 400 true**, matching native 400. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a valid pure integer function whose result is wider than argument 1 loses high result bits; the verifier correctly checks ancilla hygiene but cannot detect a wrong function. Width is chosen from the first argument, never from the return type.
- Fix: infer/check the actual return type and output width before constructing the lookup table; reject unsupported/non-uniform returns. Keep intentional `bit_width` truncation as a separately documented contract. The automatic-table branch needs the same fix.
- Test: cross-strategy exhaustive Int8 comparison for Int16/Int32 returns, mixed-width arguments, Bool returns, and overflow/sign edges; assert output widths as well as values.
- Already tracked? No matching open bead found.

### F7 — [S0] Transparent compile caching returns an obsolete function after Julia method redefinition
- Where: `src/extract/callees.jl:37-60`; `src/Bennett.jl:376,432-439,508-519`; `docs/src/reference/api.md:347-348`; `test/test_uiaq_compile_cache_transparent.jl:60-69`.
- Evidence: `hot(x::Int8)=x+Int8(1); c1=reversible_compile(hot,Int8); @eval hot(x::Int8)=x+Int8(2); c2=reversible_compile(hot,Int8)` gives **c1 === c2: true**, **simulate(c2,Int8(5)): 6**, **hot(Int8(5)): 7**, **verify_reversibility(c2): true**. Calling the documented `_clear_compile_cache!()` and recompiling still returns **6**. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: normal REPL/Revise development recompiles a changed Julia function and gets the previous implementation silently. Clearing only the circuit cache keeps the stale ParsedIR cache. Existing invalidation tests change no function semantics and assert only object inequality/invariants, so cannot detect stale results.
- Fix: invalidate extraction and circuit caches together on method-world/registry changes, or scope caching to immutable explicitly owned snapshots. Expose one documented invalidation operation; include world/dependency validity in cache keys. Correct the contradictory docstring claiming top-level compiles do not hit this cache (`Bennett.jl:462-466`).
- Test: redefine the root and a registered callee, then compare compiled results with current native results, before and after the documented invalidation call. Retain identity tests only for unchanged functions.
- Already tracked? No matching open bead found. **Bennett-uiaq**, **Bennett-sr8v** are the introducing cache work; c6 B2 discussed shared mutation but did not demonstrate stale method recompilation.

### F4 — [S1] Captured closures compile successfully with an extra, undocumented input
- Where: `src/Bennett.jl:281-399` (no validation/binding of callable environment); `src/extract/entry.jl` → module argument extraction; `README.md:24` claims “Any pure Julia function”.
- Evidence: `using Bennett; mk(k)=x->x+k; f=mk(Int8(7)); c=reversible_compile(f,Int8); println(c.input_widths); simulate(c,Int8(5))` prints **[8, 8]** then `simulate(circuit, input) requires single-input circuit, got 2 inputs`. Same result with `optimize=false`; native `f(Int8(5))` is 12. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: an ordinary pure Julia closure is accepted as a unary function, but its captured environment becomes caller-supplied circuit input. A loop that captures a type parameter similarly exposed two inputs during this review.
- Fix: bind immutable captured fields as compile-time constants and exclude the callable environment from the public argument register, or reject non-singleton callable environments up front with an actionable message until supported. Do not return a circuit whose arity contradicts the requested signature.
- Test: compile closures capturing Int8 constants (different values), singleton type parameters, and a callable struct; assert the requested input widths and all 256 native outputs, with simulator invariants enabled.
- Already tracked? No matching open bead found. **Bennett-40ys** concerns instance-less callees in the closed-world walker, not this public unary-closure acceptance.

### F12 — [S1] The simulator's advertised width guard silently accepts over-wide integers at 64 bits
- Where: `src/simulator.jl:12-15,177-188`; `test/test_6fg9_simulate_arity.jl:34-38` tests only a narrow register.
- Evidence: `c=reversible_compile(x->x+UInt64(1),UInt64); simulate(c,UInt128(1)<<64)` prints **1**; `simulate(c,-(Int128(1)<<80))` also prints **1**. The high bits disappear. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: the public `Integer` overload accepts UInt128/Int128/BigInt, but `_assert_input_fits` returns immediately at width 64 on the assumption that inputs are at most UInt64. This contradicts the entry contract to reject values outside both signed/unsigned representable ranges.
- Fix: perform a range comparison for width 64 too, without first narrowing the supplied value. Preserve valid Int64/UInt64 boundaries and reject wider values outside range.
- Test: 64-bit and controlled/in-place overloads with `2^64`, `-2^63-1`, huge BigInt, and valid endpoints; all invalid values must throw ArgumentError.
- Already tracked? No matching bead found. **Bennett-6fg9** is the previous narrower guard work. Cross-scope simulator finding included because the API validation audit exposed it.

### F22 — [S1] Documented Float64 `fma` is unavailable through the ordinary Float64 compiler entry point
- Where: `src/softfloat_dispatch.jl:16-76` (no Base.fma overload); `README.md:231`; `docs/src/tutorials/floats.md:118`; `docs/src/reference/api.md:400`.
- Evidence: `f(a,b,c)=fma(a,b,c); reversible_compile(f,Float64,Float64,Float64)` raises **ir_extract.jl: VoidType reached _type_width**, rather than compiling the advertised bit-exact fused operation. The soft_fma primitive exists, but the public wrapper has no corresponding method. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: users follow the Float64 tutorial's generic-function requirement and use a documented arithmetic primitive; compilation fails inside LLVM type handling.
- Fix: implement `Base.fma(::SoftFloat,::SoftFloat,::SoftFloat)` through soft_fma, and explicitly handle supported mixed Real arguments; alternatively narrow the documentation until the wrapper is implemented. Validate unsupported wrapper operations before the opaque VoidType failure.
- Test: compile generic fma via the public API, compare native fma bits on cancellation/subnormal/rounding cases, and check ancilla invariants. Primitive-only and raw-LLVM dispatch tests do not cover this API.
- Already tracked? **Bennett-yn08** concerns host-dependent native fma extraction, not this missing SoftFloat wrapper. No matching open bead found for the wrapper defect.

### F1 — [S1] The doctest guard passes while all Documenter doctests are disabled
- Where: `test/test_doh6_docs_makejl.jl:23`; `docs/make.jl:13,56`; `test/test_wlf6_jldoctest_fences.jl`.
- Evidence: `julia --project --check-bounds=yes test/runtests.jl test_doh6_docs_makejl.jl __astra_no_such_test__` prints **14/14 passed**. The guard searches the entire file for `doctest=true`, which occurs in a comment on line 13; the actual `makedocs` argument on line 56 is `doctest = false`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: every executable documentation example can regress while the nominal doctest invariant remains green. Fence-presence tests do not execute those examples either.
- Fix: enable and execute Documenter doctests as a local gate; remove the raw substring proxy. Keep any structure checks separate from the claim that examples execute.
- Test: deliberately change a documented expected result and confirm the local documentation gate fails.
- Already tracked? **Bennett-gygy**, accurately described and still reproducible. The earlier c6 A1 finding remains valid.

### F14 — [S1] The entire Feistel test file accepts an identity function as the claimed hash
- Where: `test/test_feistel.jl:26-33,38-111`, especially the “deterministic + reversible” and “avalanche” assertions at 70-79.
- Evidence: an in-memory mutation replaced ONLY `_compile_feistel` with an identity circuit plus `rounds` inactive Toffoli gates on three zero scratch wires. The unchanged file passes **21/21**, and input `0x12345678` returns **305419896** (itself). No source file was modified. Replacement construction: allocate W input wires and three scratch wires; emit `ToffoliGate(d[1],d[2],d[3])` once per round; Bennett-wrap with `output_wires=key`.
  Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: bijection, determinism, `o1 != o3`, an upper gate limit, and increasing round counts do not specify a Feistel permutation or meaningful diffusion. Identity satisfies every semantic assertion; dummy gates satisfy the cost assertions.
- Fix: add an independent native Feistel oracle with the intended half-swap and round function; compare all 256 W=8 inputs, odd widths, multiple rounds, and wide edges. Keep bijection/cost checks as supplementary properties.
- Test: the identity mutation above must fail. Test actual output patterns, not merely image cardinality or difference on distinct inputs.
- Already tracked? **Bennett-z3j3** (present in the current issues JSONL, absent from the initial open-beads snapshot) accurately identifies the Feistel/doc/avalanche issue. This mutation proves the whole-file coverage gap without duplicating the arithmetic implementation review.

### F8 — [S1] Constant-folding equivalence test compiles the folded path twice
- Where: `test/test_constant_fold.jl:8-10,16-22,32-34`; `src/lowering/driver.jl` default `fold_constants=true`.
- Evidence: `p=extract_parsed_ir(x->x+Int8(3),Tuple{Int8}); a=Bennett.lower(p); b=Bennett.lower(p;fold_constants=true)` prints **a.gates == b.gates: true**, lengths **(28,28)**. The first test compares these identical gate streams on all 256 inputs and asserts `folded <= standard`, which accepts equality. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: regressions in the unfolded path are never exercised; a shared wrong-output error in the folded x+3 case passes all 256 “correctness” comparisons. The polynomial section does compare against native Julia, so the whole file is not vacuous.
- Fix: explicitly set `fold_constants=false` for the reference, assert a genuine reduction on a fixture known to fold, and compare both circuit outputs to native `f(x)`.
- Test: mutation of the unfolded path must fail this file; verify both distinct paths and all 256 native results.
- Already tracked? No matching open bead found. Broader strategy fallback **Bennett-exb3** is related but distinct.

### F9 — [S1] Mixed-width test turns arbitrary compiler exceptions into an expected broken test
- Where: `test/test_mixed_width.jl:32-40`.
- Evidence: read the test into memory, replace only `reversible_compile(widen_mul, Int8)` with `error("injected compiler regression")`, and evaluate with `Base.include_string` under Test/Bennett (no file modification). It returns successfully with **17 passes, 1 broken, 0 failures/errors**, warning “widen_mul skipped (unsupported IR)” with the injected error. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a MethodError, BoundsError, OOM, interruption, or newly introduced compiler error on this path never turns the test red. `@test_broken false` also cannot become an unexpected pass when support improves.
- Fix: either require successful compile and native comparison, or assert one narrowly identified unsupported-input diagnostic outside the success path. Remove blanket catch-to-broken conversion.
- Test: injected unrelated errors must propagate; once supported, all 256 inputs must run with invariant checks. Intentional unsupported status should be an explicit, issue-linked expectation.
- Already tracked? No matching open bead found.

### F15 — [S1] Real-program ABI pins report success when the required callees disappear entirely
- Where: `test/test_416r17_sret_forward_cell_args.jl:130-170`; `test/test_416r16_consumed_sret_reconcile.jl:254`; similar missing-target fallback in `test/test_land_ptrfield_struct.jl:268,281`.
- Evidence: parsed the `natural pin: fdict_d1b recursive + consumed calls` testset AST and replaced only the call to `extract_parsed_ir_set_from_julia` with `Pair{Symbol,ParsedIR}[]`. Evaluating the unchanged assertions prints both “pin skipped” messages and **2/2 passed**. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: `on_extract_error=:skip` loses setindex! and/or ht_keyindex2 because of a new extraction regression. The very integrated ABI paths the test claims to pin vanish; their absence produces a green `@test true`.
- Fix: require named callees to be present on the supported Julia/bounds configuration, or report an explicit broken/skip with a narrowly justified unsupported version. Prefer `:fail_loud` for a fixture expected to work. Keep synthetic ABI unit tests as separate coverage.
- Test: an empty set or a set missing either required member must fail; use exact expected-member checks before traversing instructions.
- Already tracked? Related **Bennett-9tg3** accurately tracks empty-set acceptance in the producer. No separate bead found for tests turning that case green. Ordinary successful-extraction `@test true` branches elsewhere are weaker smoke tests, but are not all equivalent to this demonstrated missing-member bug.

### F18 — [S1] The Float64 target-propagation test passes while the requested target is ignored
- Where: `test/test_4fri_mul_target.jl:66-75`; `src/lowering/call.jl:97`; `src/softfloat_dispatch.jl:131-146`.
- Evidence: compile `f(x,y)=x*y` with `(Float64,Float64)` at default and `target=:depth`. Both produce **149456 gates (11852 NOT, 98720 CNOT, 38884 Toffoli)** and **identical gate vectors**. The test's only Float64 assertion is `isa ReversibleCircuit`, which is true either way. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: the advertised target reaches the wrapper but not its arithmetic callees; a test whose comment explicitly says “target propagation matters there too” validates only return type. It remains green while the known forwarding defect persists.
- Fix: thread the options into callee lowering (tracked separately), and strengthen the API regression to observe the resolved callee strategy or expected depth/gate difference, plus native outputs and invariants.
- Test: default versus explicit depth on a soft-float multiply; assert the intended internal strategy/depth change, not merely successful compilation. Do the same for add/mul/fold and CompileOptions forwarding.
- Already tracked? **Bennett-0a6f** accurately describes the implementation defect. This finding is the untested public-API contract that allows it to remain green.

### F19 — [S1] The loop Cuccaro-corruption regression fixture contains no loop after extraction
- Where: `test/test_y986_loop_header_dispatch.jl:121-131,177-189`.
- Evidence: compile the test's `_y986_acc` body with its kwargs `max_loop_iterations=5,add=:cuccaro`. Optimized extraction has **1 block, 0 IRPhi instructions, 0 circuit loop guards**. Simulations `(1,5)`, `(1,6)`, `(1,100)` return **5,6,100** despite K=5. This is legal optimization; it proves the targeted loop dispatcher is absent. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: loop-local Cuccaro dispatch can regress without this specifically named “Cuccaro-corruption guard” detecting it; LLVM replaced the loop with closed-form arithmetic.
- Fix: use `optimize=false` plus an assertion that the extracted CFG actually contains a loop, or a hand-built ParsedIR loop. Use bounded valid native inputs and explicit expected overflow-rejection cases rather than random unbounded n with K=5.
- Test: pin a nonempty loop guard/back-edge before testing the loop-only property; a mutation removing the loop-local safe-adder choice must make the test fail.
- Already tracked? **Bennett-vpgj** tracks actual loop strategy fallback behavior, but not this fixture's failure to exercise it.

### F20 — [S1] Registry concurrency tests pass even when every callee lookup throws
- Where: `test/test_7stg_register_callee_locking.jl:12-15,18-53`.
- Evidence: in an isolated process redefine `Bennett._lookup_callee(s::String)=error("injected lookup failure")`, confirm a direct lookup throws, then include this unchanged test file. Result: **2/2 passed**. The default invocation also reports **Threads.nthreads() == 1**. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: all compiled fixtures are direct arithmetic roots; none requires a registered out-of-line callee lookup. On the documented default invocation their spawned tasks also share one worker. The test can certify “register/lookup thread-safe” while lookup is completely broken and no concurrent reader is exercised.
- Fix: use a noinline registered helper actually present as IRCall, assert its native circuit outputs, and run the concurrency-specific check in a local process with at least two threads and coordinated overlapping readers/writers. Keep serial idempotence as its own test.
- Test: the injected lookup failure above must turn red; assert the test observed both lookup calls and multiple worker threads.
- Already tracked? **Bennett-7stg** introduced the locking test. **Bennett-6rqq** concerns registry isolation across files, a separate issue.

### F5 — [S1] Zero or negative verifier sample counts certified a dirty circuit (fixed concurrently)
- Where: `src/diagnostics.jl:239-278`.
- Evidence: `c=reversible_compile(x->x+Int8(1),Int8); push!(c.gates,NOTGate(first(c.ancilla_wires))); for n in (0,-1,1); try println(n," => ",verify_reversibility(c;n_tests=n)) catch e println(sprint(showerror,e)) end end` prints **0 => true**, **-1 => true**, then for 1 reports `ancilla wire 9 not zero after forward pass`. Mutation exists only in that probe process. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a computed or misconfigured sample budget becomes nonpositive; the exported checker returns the same success value as a verified circuit despite a deterministic ancilla leak.
- Fix: require `n_tests > 0` with ArgumentError before the loop. Consider exhaustive enumeration for sufficiently small domains, separately from sample-count validation.
- Test: deliberately dirty circuit with zero and negative budgets must reject the budget; positive budget must detect the dirty ancilla.
- Already tracked? Initially no matching bead; while this report was in progress another actor added **Bennett-ukup** guards to diagnostics.jl and controlled.jl. This finding records the original executed defect and is **not outstanding on the final working tree**; a fresh-process verification is recorded in Coverage log. This reviewer changed neither source file.

### F10 — [S2] The table-compilation shortcut bypasses strategy and target validation
- Where: `src/Bennett.jl:353-360,381-386`; validation otherwise in `lower`.
- Evidence: each of `reversible_compile(x->x+Int8(1),Int8;strategy=:tabulate,add=:bogus)`, the same with `mul=:bogus`, and the same with `target=:bogus` succeeds and returns **2556 gates**. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: invalid documented enum values are accepted depending on the chosen/automatic compilation path. A misspelled target quietly produces a circuit rather than an error.
- Fix: validate target/add/mul at the public entry before all shortcut returns; explicitly document/reject valid but inapplicable options instead of relying on the lowerer for validation.
- Test: table-driven bad-value checks across expression/tabulate/auto and all entry overloads, including CompileOptions.
- Already tracked? No matching open bead found; **Bennett-k0bg**, **Bennett-xlsz** cover earlier validation, not this bypass.

### F21 — [S2] Tuple and vararg Float64 signatures take different compilation paths
- Where: `src/Bennett.jl:104,281,312-318,376`; `src/softfloat_dispatch.jl:103-149`; `docs/src/reference/api.md:29-35,162-168`.
- Evidence: `reversible_compile(x->x*x+1.0,Tuple{Float64})` passes argument-type validation but fails with **unsupported LLVM opcode fmul**. The documented Float64 vararg path wraps the same generic function through SoftFloat and compiles; the tutorial's larger float polynomial was executed successfully. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: code building a tuple of argument types generically cannot use the same Float64 function that works with the apparent scalar signature sugar. The supported-type whitelist accepts Float64 but the tuple path does not provide the advertised soft-float arithmetic route.
- Fix: route homogeneous Float64 tuple signatures through the same wrapper, or reject them up front with an actionable explicit alternative and document that the call forms are not equivalent. Preserve the intended direct-LLVM path through a distinct extraction API.
- Test: equivalent tuple/vararg/CompileOptions calls for one to three Float64 arguments must agree or give a deliberate documented early diagnostic.
- Already tracked? No matching open bead found.

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

### F13 — [S2] Enabling the documented strict toolchain mode makes its own guard test fail
- Where: `test/test_srsy_ci_toolchain_guard.jl:51-60`; `README.md:398-399`.
- Evidence: `BENNETT_CI=1 julia --project --check-bounds=yes test/test_srsy_ci_toolchain_guard.jl` exits **1**, with **15 passes, 1 error**: `Expression evaluated to non-Boolean`, value `nothing`. `@info` returns nothing on the right side of `@test ... || @info(...)`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: even a fully provisioned local machine cannot run a green strict-toolchain suite, because enabling the documented mode triggers this test failure independent of toolchain availability.
- Fix: move logging outside `@test`; test strict/non-strict missing-toolchain behavior directly in isolated local processes. The legacy environment-variable name does not imply remote automation.
- Test: run this file under both 0 and 1; test a mocked missing tool lookup with each mode.
- Already tracked? **Bennett-srsy** introduced the guard; no open bead found for this regression.

### F11 — [S2] Several advertised copy-paste examples do not run in their documented context
- Where: `README.md:25,70-74`; `docs/src/tutorials/control_flow_and_loops.md:236`; `docs/src/howto/reversible_memory.md:118`.
- Evidence: executed README/tutorial code fences in page order, preserving definitions and expected-error examples. README's `f` is Int8-only, so both `reversible_compile(f,Int64)` target examples raise **ArgumentError: f has no method for arg_types=Tuple{Int64}**. `collatz_steps` is never defined on that page. The control-flow tutorial's final example uses undefined `f`, producing **UndefVarError**, before its claimed VM-backend behavior. Memory guide passes value tuple `(Int8,Int8)` where the API accepts `Tuple{Int8,Int8}` or separate types (also isolated and execution-checked). Verified: VERIFIED-BY-EXECUTION for README/tutorial; memory call also VERIFIED-BY-EXECUTION: a defined two-Int8 function with that call raises `MethodError: no method matching reversible_compile(::typeof(f), ::Tuple{DataType, DataType}; ...)`.
- Failure scenario: readers cannot reproduce the introduction to selecting targets or the memory example. Missing optional BennettVM installation is not itself counted as a defect.
- Fix: use a locally defined Int64 function and define/link Collatz, use `ilog2` in its own tutorial, and correct the memory signature to `Tuple{Int8,Int8}`.
- Test: execute documentation examples in their actual page contexts, retaining expected errors and explicit external-package prerequisites.
- Already tracked? No matching open bead; **Bennett-gygy** explains why these examples are not guarded.

### F16 — [S2] A default-off research gate still excludes regressions for publicly selectable map implementations
- Where: `test/runtests.jl:1120-1141`; `src/persistent/persistent.jl:37,47-48,59`; `test/test_uoem_research_relocation.jl:5-15,23,33-68`; CLAUDE.md file-map claims.
- Evidence: `test_uoem_research_relocation.jl` passes **29/29**, while `isdefined(Bennett,s)` is **true** for HAMT_IMPL, OKASAKI_IMPL and CF_IMPL. These implementations are unconditionally included and selectable through `persistent_impl`; nevertheless their six older test files, including `test_hmn0_hamt_overflow` and `test_n3z4_cf_reroot_key_zero`, are behind default `BENNETT_RESEARCH_TESTS=0`. Verified: VERIFIED-BY-EXECUTION for loaded symbols/test result; registration traced directly.
- Failure scenario: a normal local full suite excludes overflow/persistence regressions for live public options. The relocation test checks only `names(Bennett)` (exports), which does not prove its stated “removed from production” invariant. Default dispatcher files provide some coverage, so this is not a claim of zero map coverage.
- Fix: move tests for promoted implementations to the default gate; keep only genuinely unloaded research code optional. Rewrite relocation/docs claims to distinguish filesystem placement, exported names, and loaded/selectable behavior.
- Test: default runner selection must include promoted map regressions; assert actual load/dispatch policy rather than inferring it from exports.
- Already tracked? **Bennett-6883**, **Bennett-d746**, **Bennett-qi6c** promoted these implementations. **Bennett-2xws** tracks a real HAMT collision defect; no open bead found for stale test gating.

### F17 — [S2] The 30-file random audit finds incomplete Int8 oracle coverage, despite the exhaustive-test rule
- Where: deterministic audit table in Coverage log; especially `test_8su4_volatile_c0_memset.jl:41`, `test_fq8n_phi_mixed_widths.jl:100`, `test_munq_arr_i8_alloca.jl:30,47,57`, `test_y986_loop_header_dispatch.jl:162`, `test_pksz_controlled_contiguous_wires.jl:32`.
- Evidence: these unary Int8 checks enumerate **17, 7, 17, 30, and 3** inputs respectively, rather than 256. Focused executions pass **24/24** (8su4), **12/12** (fq8n), **69/69** (munq), confirming that their small-domain omissions do not make the test runner red. Verified: VERIFIED-BY-EXECUTION for those files and iteration domains; remaining sample classifications are direct source audit.
- Failure scenario: bugs confined to unsampled bit patterns or overflow edges survive the feature's regression test. A random `verify_reversibility` call does not compare output against native Julia and cannot substitute for exhaustive oracle coverage.
- Fix: sweep all 256 values for valid unary 8-bit inputs, with explicit rejection expectations for invalid domains. For multi-argument functions state the chosen coverage contract and sweep each 8-bit coordinate/edge interaction; do not imply exhaustive 2^(8N) coverage from a few tuples.
- Test: count distinct inputs exercised by each unary oracle fixture; include signed extrema and overflow. Every simulated value already receives ancilla/input checks internally, so lack of a separate verifier call is NOT itself an ancilla gap.
- Already tracked? No matching open bead for this systematic gap. CLAUDE.md rules 3/4 and README:394 make the stronger claim.

## Unconfirmed suspicions

- **MemorySSA output capture may block on large IR (REASONED-ONLY, not a confirmed finding).** `src/memssa.jl:123-142` redirects LLVM's printer to a Pipe and reads it only after the synchronous LLVM pass returns. A large producer could fill the pipe. Confirm with a bounded child-process probe whose annotations exceed pipe capacity; fix would require safe concurrent draining or a suitable capture backend. No large/hanging probe was run during this review.
- **Unbounded global caches plausibly contribute to monolithic-suite memory pressure (REASONED-ONLY as an OOM attribution).** Both `_parsed_ir_cache` and `_compile_cache` retain strong references indefinitely. The comment calling the extraction cache “small” and stable after warm-up predates its expansion to all user functions. Worklog/108 documents ~12 GB RSS/OOM, but this review did not profile retained memory and does not attribute all of that cost to the caches. **Bennett-gm83/o540** cover local worker/depot work.
- **Julia 1.10/LLVM 10 compatibility remains unverified.** Bounds allow Julia 1.10 and LLVM 9/10, while this instantiated manifest is Julia 1.12.3/LLVM.jl 9.4.6. No second Julia installation or dependency-resolution mutation was used. This is a coverage limitation, not evidence that the compat bounds are wrong.

## What is sound (brief)

- Ordinary `simulate`/`simulate!` assert ancilla-zero and input preservation internally; missing standalone `verify_reversibility` calls are not automatically missing invariant coverage. Verifier failures throw, so merely omitting `@test` around a call is not a lost false return.
- All 328 initial test files were registered exactly once. A sole unmatched filter fails loudly; T5 and heavy tests default **on**. The earlier c6 orphan-file finding is resolved. A concurrent verifier fix added a 329th file/registration before review completion.
- The requested four explicit ripple/folding baselines reproduce exactly, with native outputs and invariants checked. The entire gate-count regression file passed 39/39. Polynomial explicitly pins both arithmetic strategies; multiplication pins `mul=:shift_add`, whose implementation directly calls its fixed adder rather than consulting the public add dispatcher.
- README/tutorial numerical examples and both plots match the current measured gate/depth data; detailed reproduction results are below. No fabricated gate-count drift is reported.
- Native soft-float oracle coverage exists separately from circuit-versus-soft-primitive tests. For example test_softfloat compares against native addition, and test_5qrn compares compiled add/multiply bits against native arithmetic. Comparing circuit execution to the exact source function is useful compiler isolation; it is not by itself proof of IEEE correctness, but it is not intrinsically vacuous either.
- `test_dep_dag.jl` now checks concrete read-after-write edges, topological ordering and output producers after its older shape-only checks. Do not delete those semantic additions based on the old smoke-test comments.
- Unknown kwargs and many cross-overload mistakes have actionable ArgumentErrors; Float32 rejection is documented honestly. All exported bindings were defined in the running package.

## Nits (S4)

- README:393 still says 320 files/~692k assertions; initial inventory was 328, and worklog/108 claims ~1.53M chunked assertions. The latter total was not rerun here. `scripts/pre-push:13` still says ~4 minutes versus README's ~28 minutes.
- JET's smoke-test comment says a ceiling of 50 while the assertion is `< 200`; JET is intentionally absent from the test target (**Bennett-pljv**). Aqua still checks undefined exports, stale deps, unbound arguments and project extras; c6's “approximately nothing” description overstates its weakness.
- `test_hashcons_feistel.jl:35` expects ~250 occupied low-byte outputs from 256 samples of a good hash; that is not a justified occupancy baseline. Its actual 207 pin belongs to that particular algorithm. The file's compiled circuit is checked for invariants/count only; the image-size check is classical, not a compiled/native equivalence test.
- `test_8kno_extract_const_globals_narrowing.jl:61` labels x+1 a real globals-extraction regression, but the executed fixture has **0 globals**. Use an actual constant table when strengthening that test; the source-string checks remain only structural proxies.
- The export surface includes compiler sentinels and pending-lane helpers (`src/Bennett.jl:95-97`), explicitly retained for historical tests. These are candidates for a qualified/internal API in a planned breaking release, not names to remove casually from the current compatibility surface.

## Coverage log

### Scope and execution controls

Only this report was written by this reviewer. No bd, commits/stashes/checkouts, full Pkg.test, docs build, plot regeneration, installation, or corpus compiler invocation was performed. Some corpus tests generate tracked build fixtures, so those were read rather than run. Test mutations used `Base.include_string` or AST rewriting **in memory** in isolated Julia processes. Probes used `julia --project --check-bounds=yes` throughout. Source snippets/output were bounded; generated IR was suppressed for the mixed-width mutation.

During review, another actor changed diagnostics.jl/controlled.jl and added a verifier-budget regression test. F5 was rechecked in a fresh process: both circuit kinds with n_tests=0 and -1 now raise ArgumentError. These external changes are not this reviewer's edits. Other findings' line numbers refer to the source at examination; the small concurrent insertion shifts later diagnostics lines.

### Deterministic 30-file sample

Selection at audit start: sorted test filenames whose text contains both `reversible_compile(` and `Int8` (133 candidates), sampled with Python `random.Random(20260926).sample(candidates,30)`. This is a reproducible lexical pipeline sample, not a claim that every selected file is a unary Int8 oracle test. Pure error/shape tests are labeled separately. `S` means per-input simulator invariant checks; `V` means a separate verifier call. “Partial” describes output coverage, not proof of a faulty implementation.

| Sample file (under test/) | Output/oracle coverage actually read | Ancilla/invariant audit |
|---|---|---|
| test_8su4_volatile_c0_memset.jl | Unary Int8: 17 values, -8:8; partial | S + V |
| test_6883_hamt_dispatch.jl | Seven Int8 args: 3 fixed + 10 random compiled tuples; collision-free inserted keys; classical 30-trial oracle | S + V; arbitrary semantics not exhaustive |
| test_4bcp_ntuple_input_error.jl | Positive tuple/multiarg cases only count gates; no output oracle | V only |
| test_intrinsics.jl | Four unary Int8 intrinsics exhaust all 256; wider ops sample native edges | S + V |
| test_fq8n_phi_mixed_widths.jl | Unary diamond: 7 values; unit phi happy path checks wire shape | S + V(8) on pipeline case |
| test_5qrn_identity_peepholes.jl | 19 Int8 identities each 256 independent known outputs; wider identities mostly count-only; native soft-add/mul edges | S on exhaustive cases; V on size cases |
| test_6fg9_simulate_arity.jl | Two positive examples; primarily negative API tests | S on successes; invalid calls deliberately reject |
| test_y986_loop_header_dispatch.jl | Collatz 1:30; twoarg accumulator 5×6 points; manual 64-bit cases; F19 identifies absent targeted loop | S + V, except count-only subcases |
| test_jghk_multireturn_sret.jl | UInt64/Int64 edge samples with per-field native oracle; Int8 appears as a result field | S + V; not a unary Int8 domain |
| test_rjk7_self_reversing_all_strategies.jl | Self-reversing case: 256 native outputs × 6; ordinary case: 256 comparisons to default circuit, not native | S + V |
| test_cc07_repro.jl | Two Int8 args, 4 pairs vs native fixture | S + V |
| test_t5_corpus_julia.jl | TJ1 fixture + TJ3 each 256 native/known outputs; TJ2/TJ4 are rejection tests | S + V on positive cases |
| test_branch.jl | Both unary functions sweep all 256 native outputs | S + V |
| test_7stg_register_callee_locking.jl | No outputs checked; compile/nonexception only; F20 mutation survives | Neither S nor V |
| test_persistent_okasaki.jl | Sevenarg compiled map: 30 random + named edges; classical Dict oracle in separate section; default gated off | S + V(3) |
| test_qrom_dispatch.jl | Three UInt8 tables × 256 native outputs | S + V |
| test_hashcons_feistel.jl | Compiled UInt32 hash: no output oracle; Int8 image sweep only classical | V(3) on compiled circuit |
| test_pksz_controlled_contiguous_wires.jl | 3 unary inputs × both control states; partial | S + V on main fixture; empty shape fixture unchecked |
| test_59jj_typed_simulate.jl | Unary 7 values, twoarg 25 pairs, two untyped edges; partial | S (typed path delegates to checked simulator) |
| test_preprocessing.jl | Backcompat x+3: 256 native outputs; custom-pass cases mostly IR type/shape | S + V only on backcompat pipeline |
| test_division.jl | UInt8: all numerators × 9 nonzero divisors; Int8: -8:7 × 6 divisors + edges; zero-return branches not directly pinned | S + V |
| test_predicated_phi.jl | Three unary cases × 256; nested twoarg case 32×32 only, avoiding overflow extremes | S + V |
| test_loop.jl | Unary Int8/UInt8 exhaustive; Int16 also exhaustive; wider seeded edges/samples; explicitly LLVM-unrolled | S + V |
| test_negative.jl | Mostly expected errors; one correct twoarg sum | S + V on compiled positive fixture |
| test_t5_corpus_c.jl | All three corpus examples assert rejection; desired output loops are comments | No positive circuit, so invariant check not applicable |
| test_bd5f_heap_m4.jl | Scoped extraction rejection with diagnostic checks | No accepted circuit; not an output test |
| test_mlny_depth.jl | Hand-built depth shapes plus compiled size metrics; no function-output test | No V on compiled metric fixtures |
| test_munq_arr_i8_alloca.jl | Three unary Int8 fixtures each 17 points; i16 five edges | S + V |
| test_ve3m_show_peak_live_wires.jl | Show-format test only; not a pipeline oracle | No V; formatting assertions should not be counted as exhaustive correctness |
| test_int64.jl | Main Int64 function: 7 edges + 500 seeded native samples; i8/i16/i32 table merely prints | S + V for main circuit; printed table unchecked |

The clearest unary-domain omissions are recorded in F17. Do not report a single “percent compliant” by counting all 30 equally: the sample deliberately includes negative API tests, multiarg programs, rendering tests and wider inputs.

### Suspicious-test triage and full reads

Repo-wide grep covered every test file for constant true/broken/skip/nowarn assertions, type-only checks, `catch`, environment gates, simulator-vs-simulator and soft-function comparisons, and verifier calls. There were three live `@test_broken` sites (mixed-width, Aqua wrapper, D1b cells=false), and two live `@test_nowarn` sites (allocator legitimate free, callee-lowering smoke). No file-level testset-with-zero-assertions was found by the lexical inventory; branch-dependent omissions are documented separately.

Full test files read (including all executable bodies; longer files in bounded slices): test_gate_count_regression, test_doh6_docs_makejl, test_wlf6_jldoctest_fences, test_mixed_width, test_y56a_division_paths, test_hygiene_aqua_jet, test_atf4_lower_call_nontrivial_args, test_hashcons_feistel, test_memssa, test_g27k_cc03_catch_narrow, test_8kno_extract_const_globals_narrowing, test_uinn_catch_narrowing, test_sqtd_feistel_not_bijection, test_5kio_sizehint_arithmetic, test_kmuj_callee_groups, test_constant_fold, test_callee_bennett, test_pebbled_space, test_4fri_mul_target, test_fehu_simulate_inplace, test_feistel, test_dep_dag, test_asw2_verify_reversibility, test_7stg_register_callee_locking, test_4bcp_ntuple_input_error, test_uiaq_compile_cache_transparent, test_sr8v_compile_cache, test_uoem_research_relocation, test_srsy_ci_toolchain_guard, test_bennett, test_cc07_repro, test_ve3m_show_peak_live_wires, test_f6qa_error_message_prefixes, test_kh6n_prefix_discipline, test_tabulate, test_negative, test_preprocessing, test_pksz_controlled_contiguous_wires, test_8su4_volatile_c0_memset, test_6fg9_simulate_arity, test_59jj_typed_simulate, test_branch, test_qrom_dispatch, test_int64, test_fq8n_phi_mixed_widths, test_rjk7_self_reversing_all_strategies, test_hmn0_hamt_overflow, test_division, test_y986_loop_header_dispatch, test_mlny_depth, test_munq_arr_i8_alloca, test_persistent_okasaki, test_bd5f_heap_m4, test_t5_corpus_julia, test_t5_corpus_c, test_intrinsics, test_predicated_phi, test_loop. All names carry `.jl` under `test/`.

Additional targeted reads: 6883_hamt_dispatch (oracle/compile/limits), 5qrn_identity_peepholes (all identity/oracle sections and static guards), jghk_multireturn_sret (all assertions, native comparisons, fixture paths), bennett_strategy (dispatch/fallback sections), float_circuit (neg/add/mul/div plus sqrt start), softfloat native-add oracle, 9x75 raw-bit oracle/seed handling; real-target sections of 416r16, 416r17, yd4f, ares, 583s, p06b, land; metadata/guard sites of other grep hits. Long extraction-contract files were not all read in full, and that is not claimed.

### Executed checks and mutations

- Focused original files: gate_count_regression **39/39**, 8su4 **24/24**, fq8n **12/12**, munq **69/69**, doh6 **14/14**, uoem **29/29**, 7stg **2/2**. The strict-toolchain srsy mode fails as F13 records. Standalone increment fails before tests as F3 records.
- Filter runner: sole unmatched pattern fails; mixed valid+unmatched pattern succeeds with one file. No full suite run was made.
- Mutation controls: mixed-width injected exception **17 pass/1 broken**; identity Feistel **21/21**; empty real-program ABI set **2/2**; completely broken callee lookup **2/2**. None modifies repository source.
- Direct API probes: widening-return tabulation, closure arity, method-redefinition caching and documented invalidation, invalid tabulate kwargs, over-wide simulation input, Float64 tuple/fma/target behavior, loop-fixture CFG, verifier budget before and after concurrent fix.
- Ripple x+1: all four requested widths; each also tested on all 256 values -128:127 with native output comparisons. Full Int8 domain, representative wider domain. Totals/Toffolis 58/12, 114/28, 226/60, 450/124.

### Documentation execution and plots

Extracted **every Julia/jldoctest fence** from README, getting_started/quickstart, and all four tutorials. Executed expressions in page order in isolated page modules. REPL prompts/continuations were converted to their Julia expressions; expected output text was compared with concise emitted results rather than running Documenter (disabled). Installation's `Pkg.add` was deliberately not executed because it would mutate other files. Optional BennettVM was not installed in this project; this prerequisite limitation is distinguished from undefined names/signatures in F11. Expected-error examples (loop without K, overflowing K=4, Float32) produced the documented errors.

All numerical successes checked: polynomial output 41 / 482 gates; increment 58 gates, 25 ancillae, T-count 84, depth 19, Toffoli-depth 12; controlled on/off; S-box 114 gates; 3-bit increment 23 gates/16 wires and exact gate sequence; absolute value 258 gates/100 ancillae; min 216 gates; constant loop 22 gates; ilog2 K=8 2039 gates/939 ancillae and all 256 native outputs; Float64 polynomial 341476 gates/235759 ancillae, values 11.0 and 2.75. K=4 ilog2 fits input16 and rejects100 exactly as documented.

Read the numeric portions of docs/plots scripts and inspected both PNGs plus SVG text. Recomputed every depth-plot series without drawing/writing: ripple **[14,30,62,126]**, Cuccaro **[26,58,122,250]**, QCLA **[16,20,24,28]**, shift-add **[36,84,180]**, QCLA-tree **[40,48,56]**. Scaling PNG agrees with the four ripple baselines. No plot artifact was overwritten.

Other docs: inventoried all docs/src fences; read reference API/strategies' signatures, kwargs, caveats and caching sections, how-to arithmetic/memory/VM examples, installation requirements, relevant Float64 prose and architectural claims. These non-tutorial pages were not all executed as standalone programs (many fences are signatures, placeholders, external compiler commands or package installation). F11's memory call was isolated with a defined function and executed to prove the signature error. Historical design c6 and worklog/108 were used as hypotheses, not authorities.

### API, dependencies and fail-fast survey

Read src/Bennett.jl and softfloat_dispatch.jl in full; precompile.jl in full; relevant extraction-cache/registry code, tabulation width/table builder, simulator entry checks and verifier, persistent module loader, full MemorySSA parser/capture path. No undefined exports found. InteractiveUtils is used for code_llvm, LLVM is the extractor dependency, and PrecompileTools is used by the workload: no unused direct dependency found. Project compat is LLVM 9/10, PrecompileTools 1, Julia 1.10; installed manifest is Julia 1.12.3/LLVM.jl 9.4.6/PrecompileTools 1.3.3. Test extras are Aqua/Test/Random; JET de-listing is explicit. No dependency environment was modified.

The precompile workload still calls live API paths (Int8 +1, Int32 ×3, Int64 +7, Float64 +1.0). Int32 ×3 extraction still contains IRBinOp(:mul), so the suspected stale multiplication workload is refuted; it is a 32-bit constant multiply rather than a widening-result multiply. Compilation-only workload behavior is appropriate to its purpose; it is not a correctness test.

Repo-wide catch/return-nothing/warn grep was triaged outside the extraction/lowering/arithmetic reviewers' core areas. Most outside-core `return nothing` sites are successful validators, cache reset functions, registration, or void emitters. The real bad early return identified here is the simulator's width>=64 guard (F12); public shortcut validation (F10) and stale-cache handling (F7) are more consequential than blanket complaints about the spelling `return nothing`. MemorySSA capture remains an explicitly unconfirmed concern above. Existing extraction/lowering swallow beads (n4di, sy9t, 1zow, wo5z, etc.) were not re-filed without independently executing them.

### Reassessment of prior review claims

- c6 A1 (doctests) and A2 (standalone imports): confirmed, F1/F3.
- c6 A3 (six orphans): refuted on this tree; all are registered.
- c6 A4 (“CompileOptions dead API”): bundle is a working public feature with docs examples; sparse internal usage alone does not establish a defect. Its tests mostly use defaults and should add non-default forwarding coverage (F18), rather than deleting it reflexively.
- c6 A5: high-level `strategy` is indeed a separate selector from BennettStrategy scheduling; docs now explicitly describe the lower-level qualified scheduler route. The public API distinction is awkward but documented; no claim of an inaccessible implementation is repeated without qualification.
- c6 A8: its named random examples are now explicitly seeded (9x75=0x9075, fma multiple fixed seeds, fdiv=42, fconv=1234/20260415, SHA=0x5a256cd5). Do not repeat the old “27/49” count. The verifier itself still uses random probes.
- c6 A9: JET remains intentionally disabled; comment/threshold drift remains. Aqua is not wholly vacuous because enabled checks and inner Test assertions still execute.
- Bennett-25dm: title is partly stale: TJ1 has a positive saved-IR fixture and TJ3 is positive/exhaustive. TJ2/TJ4 and C corpus still assert rejection; those assertions do not prove successful multi-language memory support. Bennett-890r correctly describes TJ4's future store/load mirage. T5 gate is on by default; only missing external tools can skip C/Rust under normal mode.

- CLAUDE.md read in full.
- Inventory: 328 test files, 328 unique registrations, no orphans. Six research files default off; T5/heavy default on.
- Reproduced explicit ripple/fold x+1 counts: Int8 58/12, Int16 114/28, Int32 226/60, Int64 450/124 (total/Toffoli); verifier true and 256 native comparisons per width. All exported names defined on Julia 1.12.3.
