# Bennett.jl — Test Coverage Review (QA, skeptical)

Reviewer: adversarial QA subagent, 2026-04-21.
Scope: `src/**/*.jl` vs `test/**/*.jl` (56 source files, 112 test files, 13.3 KLOC src / 11.3 KLOC tests).

The user’s standard: "every line of code gets looked at critically." I applied that standard to the test suite, not just the tests but their **quality as a safety net**. The short of it: the test count is impressive, but roughly a third of the suite is softer than it looks — trivial asserts, print-only baselines, narrow sampling on functions that could be exhausted, hardcoded error-site gaps, and (critically) a `verify_reversibility` helper whose name oversells what it proves. The suite is correct in aggregate only because `simulate` itself enforces the ancilla-zero invariant; remove that single `error(...)` line in `simulator.jl` and a lot of "passing" tests would silently regress.

---

## 1. Coverage matrix: source → test

Every `src/*.jl` file with the primary test(s) that hit it. "Transitive" = exercised only through the top-level compile pipeline, never called directly. "ORPHAN" = no test touches it by name.

| Source file | Direct tests | Notes |
|---|---|---|
| `Bennett.jl` (module) | nearly every test file | `reversible_compile` is the hot entry |
| `ir_types.jl` | **ORPHAN (no direct test)** | only transitive; ParsedIR constructors / IRPhi / IRSwitch / IRInsertValue have no unit tests |
| `ir_extract.jl` | `test_parse`, `test_cc04/06/07`, `test_vector_ir`, `test_sret`, `test_0c8o`, `test_uyf9`, `test_p5a/b_*`, `test_atf4_*`, `test_t0_preprocessing`, `test_preprocessing`, `test_t5_corpus_*` | 2,394 LOC, 20 `error()` sites — only a handful have `@test_throws` |
| `ir_parser.jl` (legacy regex) | `test_parse.jl` only calls it, not unit-tested | `parse_function_header`, `parse_ssa_name`, `parse_operand` have no direct test; regex edge cases untested |
| `gates.jl` | transitive; indirectly via toffoli_depth / constant_wire_count tests | no `NOTGate`/`CNOTGate`/`ToffoliGate` constructor-level tests |
| `wire_allocator.jl` | `test_wire_allocator.jl` | solid, 5 testsets |
| `adder.jl` | `test_add_dispatcher`, `test_cuccaro_safety`, implicit via all arithmetic | `lower_add_cuccaro!` / `lower_sub!` not directly unit-tested with handcrafted wires |
| `qcla.jl` | `test_qcla.jl` | only targets the primitive indirectly via `reversible_compile(...; add=:qcla)` |
| `multiplier.jl` | `test_karatsuba.jl` (ORPHAN — not in `runtests.jl`), `test_mul_dispatcher.jl` | `lower_mul_wide!` / `_karatsuba_wide!` have no direct unit tests |
| `lower.jl` | dozens of tests transitively; `test_narrow`, `test_tabulate`, `test_loop`, `test_branch`, `test_switch`, `test_predicated_phi`, etc. | 2,662 LOC with 81 `error()` sites — very few `@test_throws` |
| `bennett_transform.jl` | transitive via every `verify_reversibility` and every `bennett(lr)` call | `bennett(lr)` with `self_reversing=true` tested in `test_self_reversing.jl`; `_compute_ancillae` has no direct test |
| `simulator.jl` | transitive via every simulate | `_read_output` / `_read_int` / multi-element tuple return tested only indirectly |
| `diagnostics.jl` | `test_toffoli_depth`, `test_constant_wire_count`, `test_sha256`, `test_sha256_full` | **`depth(c)` is NEVER asserted on anywhere in the test suite** — dead API from a coverage perspective (see CRITICAL-3) |
| `controlled.jl` | `test_controlled.jl` | only 5 test scenarios; does not exercise `promote_gate!` error paths |
| `dep_dag.jl` | `test_dep_dag.jl` | smoke-level only (see HIGH-7) |
| `pebbling.jl` | `test_pebbling.jl` | covers Knill recursion + `pebbled_bennett`; `pebble_tradeoff` edge cases (`max_space=0`) not explicitly tested |
| `eager.jl` | `test_eager_bennett.jl`, `test_ancilla_reuse.jl` | final `gate count baselines` testset has **zero asserts** (see MEDIUM-12) |
| `value_eager.jl` | `test_value_eager.jl` | |
| `pebbled_groups.jl` | `test_pebbled_wire_reuse.jl` | `ActivePebble` struct, `_remap_wire`, `_replay_forward!/_reverse!` have no direct unit tests |
| `sat_pebbling.jl` | `test_sat_pebbling.jl` | reasonable; no `@test_throws` for cardinality-constraint corner cases |
| `divider.jl` | `test_division.jl` | |
| `softfloat/fneg.jl` | `test_softfloat.jl` | 5 hand-picked inputs |
| `softfloat/fadd.jl` | `test_softfloat.jl` | basic + 10k random in [-100,100] — **shallow fuzz** (see HIGH-10) |
| `softfloat/fsub.jl` | `test_softfsub.jl` | mirror of fadd, same shallow fuzz |
| `softfloat/fmul.jl` | `test_softfmul.jl` | same |
| `softfloat/fma.jl` | `test_softfma.jl` | **best fuzzing of the bunch** — has raw-bits `rand(rng, UInt64)` path |
| `softfloat/fdiv.jl` | `test_softfdiv.jl`, `test_softfdiv_subnormal.jl` | subnormal test does 200k raw-bits — excellent, but only for fdiv |
| `softfloat/fsqrt.jl` | `test_softfsqrt.jl` | |
| `softfloat/fcmp.jl` | `test_softfcmp.jl` | |
| `softfloat/fpconv.jl` (fpext/fptrunc) | `test_softfconv.jl` | 1 file; fptrunc inverse-round-trip not fuzzed heavily |
| `softfloat/fptosi.jl` | `test_softfconv.jl` | |
| `softfloat/sitofp.jl` | `test_soft_sitofp.jl` | raw-bits fuzz (good) |
| `softfloat/fround.jl` | `test_soft_fround.jl` | |
| `softfloat/fexp.jl` | `test_softfexp.jl` | |
| `softfloat/fexp_julia.jl` | `test_softfexp_julia.jl` | |
| `softfloat/softfloat_common.jl` | transitive only | helpers have no dedicated tests |
| `softmem.jl` | `test_soft_mux_mem.jl`, `test_soft_mux_mem_circuit.jl`, `test_soft_mux_mem_guarded.jl`, `test_soft_mux_scaling.jl`, `test_memory_corpus.jl` | **only `_2x8/_4x8/_8x8` and their guarded variants are exhaustively covered by `test_soft_mux_scaling.jl` + `test_soft_mux_mem_guarded.jl`**; the `_2x16`, `_4x16`, `_2x32` shapes are **only** in `test_soft_mux_mem_guarded.jl` as 1000-random fuzzing — no pure-Julia exhaustive check |
| `qrom.jl` | `test_qrom.jl`, `test_qrom_dispatch.jl` | |
| `tabulate.jl` | `test_tabulate.jl` | only W=2, W=3, W=4 tested; W=8 (the natural ceiling) not exercised |
| `memssa.jl` | `test_memssa.jl`, `test_memssa_integration.jl` | |
| `feistel.jl` | `test_feistel.jl` | bijection only checked for W=8 and sampled for W=16; W=32/64 only deterministic+avalanche check (see MEDIUM-14) |
| `shadow_memory.jl` | `test_shadow_memory.jl`, `test_memory_corpus.jl` | `emit_shadow_store_guarded!` → `test_soft_mux_mem_guarded.jl` |
| `fast_copy.jl` | `test_fast_copy.jl` | solid |
| `partial_products.jl` | `test_partial_products.jl` | |
| `parallel_adder_tree.jl` | `test_parallel_adder_tree.jl` | |
| `mul_qcla_tree.jl` | `test_mul_qcla_tree.jl`, `test_mul_qcla_tree_paper_match.jl` | |
| `persistent/persistent.jl` | transitive | module glue |
| `persistent/interface.jl` | `test_persistent_interface.jl` | |
| `persistent/linear_scan.jl` | `test_persistent_interface.jl` | |
| `persistent/okasaki_rbt.jl` | `test_persistent_okasaki.jl` | |
| `persistent/hamt.jl` | `test_persistent_hamt.jl` | |
| `persistent/cf_semi_persistent.jl` | `test_persistent_cf.jl` | |
| `persistent/hashcons_feistel.jl` | `test_persistent_hashcons.jl` | |
| `persistent/hashcons_jenkins.jl` | `test_persistent_hashcons.jl` | |
| `persistent/popcount.jl` | `test_persistent_hamt.jl` | only transitively (`soft_popcount32` used inside HAMT) |
| `persistent/harness.jl` | every `test_persistent_*` | |

**Orphans (no direct test by name):** `ir_types.jl`, `ir_parser.jl` (only legacy regex — no unit tests for its parse functions), `gates.jl` (no constructor/invariant unit tests). `popcount.jl` is only exercised transitively.

**Orphan test file:** `test_karatsuba.jl` is NOT included in `runtests.jl`. It is never run by `Pkg.test()`. Silent dead test.

---

## 2. Executive summary (≤15 bullets)

1. **The crown-jewel invariant is under-tested at its name.** `verify_reversibility(c)` (src/diagnostics.jl:145–161) only proves `apply_forward; apply_reverse ≡ identity`. That is **mathematically vacuous for any circuit made of self-inverse gates** (NOT, CNOT, Toffoli all are). It does NOT check ancilla-zero. Tests that call only `verify_reversibility` and skip `simulate` are checking a tautology. The real ancilla-zero invariant is enforced inside `simulate()` via `bits[w] && error(...)`. Net effect: the suite's safety net only works when tests actually simulate.
2. **CLAUDE.md §4 claim diverges from code.** CLAUDE.md says "Every test must call `verify_reversibility` or check ancilla values explicitly." But `verify_reversibility` does not check ancillae. This is a docstring/implementation contradiction that misleads every future agent following the rule.
3. **Five tests compile circuits without any form of ancilla-zero check.** `test_constant_wire_count.jl`, `test_dep_dag.jl`, `test_gate_count_regression.jl`, `test_negative.jl`, `test_toffoli_depth.jl` never call `verify_reversibility` or `simulate`. Gate-count regressions in `test_gate_count_regression.jl` would catch a gate-count change but NOT an ancilla-leak introduced by the same refactor.
4. **121 `error()` sites in src, 26 `@test_throws` in test.** `lower.jl` alone has 81 error sites; only a small handful (strategy=:bogus, unknown decomp, decl-only function) are actually triggered by a test. If you changed an error message or lost a guard, nothing would notice.
5. **`depth(c)` is a dead metric in the test suite.** It is exported, documented, called in `diagnostics.jl` to print, used in benchmarks — but never asserted against anywhere in `test/`. Any regression in depth goes unnoticed.
6. **"Int8 should be exhaustive (256 inputs)" is honoured inconsistently.** Several tests that could easily be exhaustive are not: `test_karatsuba.jl` uses 21×21=441/65536 and calls itself "Int8 exhaustive"; `test_vector_ir.jl` uses 6–12 sample Int8 values; `test_mul_dispatcher.jl` uses 12–16 sample pairs. `test_two_args.jl` uses 256+10 of 65536 possible i8×i8. Easy coverage left on the table.
7. **Soft-float fuzzing is pathologically narrow.** Nearly every soft-float test fuzzes with `rand(rng) * 200 - 100` — Float64s in [-100, 100]. That excludes subnormals, extreme exponents, NaN payloads, and the entire UInt64 bit-pattern space. Only `soft_fdiv` (subnormal regression, 200k raw-bits), `soft_fma` (one test), and `soft_sitofp` use `rand(rng, UInt64)`. The claim "1,037 tests in test_softfloat.jl" (CLAUDE.md §text) is about loop iterations, not independent coverage.
8. **Regression baselines from WORKLOG live only in WORKLOG for many cases.** `test_gate_count_regression.jl` has i8/i16/i32/i64 addition + polynomial + shift-add mul. But WORKLOG references many more: HAMT demo = 96,788, Okasaki, CF, Feistel, popcount32 = 2,782, etc. Of these, HAMT is "anchored" only as `10_000 < total < 1_000_000` — a band large enough to hide a 10× regression. Same for `test_persistent_interface.jl` ("sanity bounds" of `100 < total < 100_000`). Not real regression anchors.
9. **Hardcoded gate counts couple tests to IR shape (CLAUDE.md §5 warning).** `test_gate_count_regression.jl` has exact equality asserts on total/Toffoli counts that WILL drift under LLVM upgrades. That's OK intentionally (it's the point of a regression test), but CLAUDE.md §5 says "LLVM IR is not stable" — and there is no fallback plan documented for when these legitimately drift.
10. **Tests that pass the wrong way.** Several tests only assert trivially true properties: `test_constant_wire_count.jl` only asserts `cw >= 0` / `cw >= 1`; `test_ancilla_reuse.jl` only prints `ancilla_count` without asserting it; `eager_bennett: gate count baselines` testset in `test_eager_bennett.jl` has no `@test` at all. These would pass if the underlying function returned any non-negative Int.
11. **Test harness fail-stop.** `test/runtests.jl` is a flat `include()` list with no top-level `@testset` wrap; failures inside each included file's `@testset` don't stop the suite. Fine for CI iteration but means one failing test doesn't halt a hundred more before it.
12. **External-tool tests skip silently-ish.** `test_t5_corpus_c.jl`/`_rust.jl`/`test_p5b_bc_ingest.jl` emit `@test_skip` when clang/rustc/llvm-as is absent. That's better than silently no-op-ing, but CI without these tools has unobservable holes unless someone reads the skip count. There is no `@info "REQUIRED TOOL MISSING"` gate or fail-loud option for CI.
13. **No property tests for the Bennett invariant.** There is no test that asserts, e.g., `bennett(bennett(lr))` is self-consistent, or that `simulate(c, x) == f(x)` holds for a randomly generated `f` drawn from a grammar. Every correctness test names a specific function and a specific oracle. Cannot surface classes of bugs.
14. **`ir_types.jl`, `ir_parser.jl`, `gates.jl` are orphans.** No dedicated unit tests. The ParsedIR constructor-with-memssa path, IRPhi empty-incoming, IRSwitch with no cases, IRInsertValue with out-of-range index — tested only through end-to-end compiles. Any refactor of these types has no fast feedback loop.
15. **`test_karatsuba.jl` is not in `runtests.jl`.** Literal dead test file. Never run by `Pkg.test()`. Only one; still a red flag for process.

---

## 3. Prioritised findings

### CRITICAL

#### CRITICAL-1 — `verify_reversibility` does not verify what its callers assume
`src/diagnostics.jl:145–161`, `src/controlled.jl:89–107`.

**What's missing:** the function never inspects `c.ancilla_wires` to assert they are zero. It only checks `forward; reverse ≡ identity`. For any circuit where every gate is self-inverse (every gate in this codebase is), that identity is a **theorem**, not a runtime property — the check can fail only if there is a bug in `apply!` or the gate-list is mutated mid-simulation. It tells you essentially nothing about Bennett's construction being correct.

**Why it matters:** CLAUDE.md §4 claims this function is sufficient to check the "ancilla returns to zero" invariant. It is not. Five test files rely solely on it without also calling `simulate`. If Bennett's uncompute pass silently skipped half the gates but matched up at start/end, this check would still return `true`. The real ancilla-zero guard is in `src/simulator.jl:30–32` (`bits[w] && error("Ancilla wire $w not zero")`). Tests that only `verify_reversibility` a circuit without calling `simulate` pass a null assertion.

**Suggested fix:** rewrite `verify_reversibility` to run a fresh random input through `simulate` (or inline its ancilla check):
```julia
function verify_reversibility(c::ReversibleCircuit; n_tests::Int=100)
    for _ in 1:n_tests
        bits = zeros(Bool, c.n_wires)
        # ... randomise inputs ...
        for g in c.gates; apply!(bits, g); end
        for w in c.ancilla_wires
            bits[w] && error("Ancilla wire $w not zero after forward pass")
        end
        # optionally still check forward+reverse=identity
    end
    return true
end
```
Then update CLAUDE.md §4 to reflect what the function actually proves.

#### CRITICAL-2 — 5 test files compile circuits but never check ancilla-zero
`test/test_constant_wire_count.jl`, `test/test_dep_dag.jl`, `test/test_gate_count_regression.jl`, `test/test_negative.jl` (partly intentional), `test/test_toffoli_depth.jl`.

These call `reversible_compile(...)` but never `simulate` nor `verify_reversibility`. Assuming `verify_reversibility` were fixed (per CRITICAL-1), these tests would still be blind to ancilla leaks. `test_gate_count_regression.jl` is the most concerning — it locks in exact total/Toffoli counts at multiple widths, but if a regression (a) matched the gate count exactly and (b) leaked ancillae, it would pass.

**Suggested fix:** add `@test verify_reversibility(c)` and at least one `simulate(c, 0)` sanity call to each of these test files.

#### CRITICAL-3 — `depth(c)` is exported, documented, and tested nowhere
`src/diagnostics.jl:14–24` (definition), `src/Bennett.jl:47` (export).

No test asserts on `depth(c)` anywhere in `test/`. It's called only to print in `diagnostics.jl` and `bc6_mul_strategies.jl`. An uncaught bug in `depth` (e.g. ignoring NOT gates, off-by-one at wire initialisation, miscomputing with empty gate list) would not be caught.

**Suggested fix:** a ~10-line `@testset "depth basic shapes"` analogous to `test_toffoli_depth.jl`: empty circuit → 0; sequential gates on same target → N; parallel gates on disjoint wires → 1; mixed.

### HIGH

#### HIGH-4 — 81 `error()` sites in `lower.jl`, ~3 exercised by `@test_throws`
`src/lower.jl` has 81 `error()` calls (covering `lower_add!`, `lower_mul!`, `lower_phi!`, ptr-select ancilla checks, unsupported icmp predicates, `Cannot topologically sort blocks`, `Loop header must end with conditional branch`, etc.). Current `@test_throws` coverage:
- `test_mul_dispatcher.jl:44` — `mul=:bogus`
- `test_add_dispatcher.jl:49` — `add=:nonsense_strategy`
- `test_tabulate.jl:117, 124` — unknown strategy, tabulate-on-Float64
- `test_negative.jl:22, 27, 33` — unrolled loop, too-many-float-args, wrong-arity simulate

That's ~6 of 81. The rest are completely untested: any of them could become dead code (unreachable) silently, or (worse) their message format could drift and users would get unhelpful errors. The phi-resolution errors in particular (`_edge_predicate!`, `lower_phi!: ptr-phi`, `Cannot resolve phi node`) have no @test_throws despite CLAUDE.md explicitly flagging phi resolution as "the most complex and bug-prone part of the compiler."

**Suggested fix:** write a `test_lower_errors.jl` that constructs minimal hand-crafted `ParsedIR` inputs (or malformed `.ll` via the P5 extract path) hitting ~10 of the most load-bearing error sites. Prioritise: loop back-edge without `max_loop_iterations`, phi from block with empty pred_list, fan-out > 8 in ptr-select.

#### HIGH-5 — 20 `error()` sites in `ir_extract.jl`, ~3 tested
Same pattern. `test_cc06_error_context.jl` nicely tests the error-message FORMAT (good!) but not the triggering conditions. Vector-IR errors (`vector lane-count mismatch`, `vector element width not supported`, `extractelement reads poison lane`) have no `@test_throws`. If Julia starts emitting a new vector pattern that hits one of these, we won't get a regression signal from tests — only from user reports.

**Suggested fix:** hand-construct LLVM modules that exercise 5–8 of the representative error sites via `getfield(Bennett, :_module_to_parsed_ir)(mod)` (the pattern already in `test_cc06_error_context.jl`). Focus on cc0.7 vector errors, since vector IR is CLAUDE.md §5 "not stable" territory.

#### HIGH-6 — `test_karatsuba.jl` is not included in `runtests.jl`
`test/test_karatsuba.jl` — a complete `@testset` that tests Karatsuba multiplication correctness AND asserts `gc_karat.Toffoli < gc_school.Toffoli` (a meaningful gate-count regression). It is not in `runtests.jl`. `Pkg.test()` skips it entirely. If Karatsuba regresses in correctness OR loses its gate-count advantage, no one finds out from `Pkg.test()`.

Additionally, the testset name is `"karatsuba: Int8 exhaustive"` but the input range is `Int8(-10):Int8(10)` for both x and y → 441 of 65536 possible Int8×Int8 pairs. Not exhaustive.

**Suggested fix:** add `include("test_karatsuba.jl")` to `runtests.jl`. Rename testset or expand to `typemin(Int8):typemax(Int8)` for both arguments (65536 iterations takes seconds at most; the test will actually finish).

#### HIGH-7 — `test_dep_dag.jl` is smoke-only
`test/test_dep_dag.jl:9` — `@test length(dag.nodes) > 0`. `test/test_dep_dag.jl:26` — `@test length(dag.nodes) > 10`. The only structural check is "preds and succs are symmetric" and "no self-loops". No test asserts that the DAG topology matches the actual data flow for a specific known circuit — e.g., that in `x + 1`, the ret-node has a specific predecessor count. A completely wrong DAG (e.g. one that returned every node as a predecessor of every other) would pass both the symmetry check AND the size checks.

**Suggested fix:** add a testset with a known 3-gate circuit (e.g., Toffoli(1,2,3), CNOT(3,4), CNOT(3,5)) and assert exact expected preds/succs per node.

#### HIGH-8 — SHA-256 round tested against exactly 2 inputs
`test/test_sha256.jl:56–70`. The full round function — a 10-argument UInt32 function that is the basis for the entire SHA-256 benchmark — is tested on exactly the SHA-256 initial hash values (`0x6a09e667, ...`) and one derived input. A round function that was accidentally a no-op for those specific inputs (e.g. due to a bit-canceling bug) would pass. The full SHA round is reversible-compiled in `test_sha256_full.jl`, but that also samples only hand-picked values.

**Suggested fix:** add 100 random UInt32 rounds cross-checked against a native-Julia SHA-256 round function. The circuit is already compiled; the marginal cost of 100 sims is trivial.

#### HIGH-9 — `test_two_args.jl` tests 266/65536 Int8×Int8 pairs
`test/test_two_args.jl:5` — `for x in Int8(0):Int8(15), y in Int8(0):Int8(15)` + 10 edge cases. That's 266 inputs of a possible 65536. For a function `m(x, y) = x*y + x - y` which overflows and wraps across the entire i8×i8 space, this is ~0.4% coverage.

**Suggested fix:** bump to full `typemin(Int8):typemax(Int8)` for both args. 65536 simulations per test takes a few seconds.

#### HIGH-10 — Soft-float fuzzing is shallow
`test/test_softfloat.jl:93, 112`, `test/test_softfsub.jl:59`, `test/test_softfmul.jl:85`, `test/test_softfma.jl:175, 259`, `test/test_softfcmp.jl:83`, `test/test_softfdiv.jl:48`, `test/test_float_circuit.jl:52, 94, 143`.

Every one of these fuzzes over `rand(rng) * 200 - 100` — a Float64 in [-100, 100]. The tests then check bit-exactness against Julia. But:
- No subnormals (< 2^-1022 ≈ 2.2e-308)
- No extreme exponents (> 10^100)
- No NaN payload variation
- No denormal boundaries
- No random UInt64 → Float64 bit-patterns

`test_softfdiv_subnormal.jl` shows what proper raw-bits fuzzing looks like: `reinterpret(Float64, rand(rng, UInt64))` for 200k trials with finite/nonzero filtering. That pattern exists once. It should exist once per soft-float primitive. CLAUDE.md §13 says soft-float must be "bit-exact with random inputs AND edge cases (0, -0, Inf, NaN, subnormals, overflow boundaries)". "Random inputs" as currently implemented mostly tests well-behaved range.

**Suggested fix:** add a `raw_bits_sweep` helper in `test_softfloat.jl`:
```julia
function raw_bits_sweep(rng, op_soft, op_native; n=100_000)
    failures = 0
    for _ in 1:n
        a = reinterpret(Float64, rand(rng, UInt64))
        b = reinterpret(Float64, rand(rng, UInt64))
        r_soft = op_soft(reinterpret(UInt64, a), reinterpret(UInt64, b))
        expected = op_native(a, b)
        # ... NaN-aware compare ...
    end
    @test failures == 0
end
```
and call it for each of fadd/fsub/fmul/fdiv/fma/fsqrt.

### MEDIUM

#### MEDIUM-11 — "Sanity bounds" regression anchors are too wide
`test/test_persistent_hamt.jl:154` — `@test 10_000 < gc.total < 1_000_000`.
`test/test_persistent_interface.jl:83` — `@test 100 < gc.total < 100_000`.

Range ratios of 100× and 1000×. A 2× or 10× regression would pass. These are not regression anchors; they are ""runs to completion"" probes.

**Suggested fix:** freeze a real value with tighter bounds (e.g., `gc.total == 96_788`, or `95_000 < gc.total < 100_000` for ±3%). When the number legitimately changes, update the constant and note in commit.

#### MEDIUM-12 — Tests with testset names that imply assertions but have none
`test/test_eager_bennett.jl:99–108` — testset `"eager_bennett: gate count baselines"` has only `println`s, no `@test`. Would "pass" (emit zero tests) regardless of behaviour. Julia's `@testset` emits nothing if no `@test` runs, so the test appears in counts as 0/0.

`test/test_ancilla_reuse.jl:19, 29` — prints `ancilla_count(c)` but does not assert on it. Test name suggests reuse is being validated.

`test/test_liveness.jl:39` — prints liveness stats; one `@test` asserts trivially that every tracked variable has last_use >= 1.

**Suggested fix:** either add asserts or delete/rename the misleading testset names to `@testset "print baselines (informational only)" begin ... end` so a reader isn't misled.

#### MEDIUM-13 — `test_constant_wire_count.jl` has only trivially-true asserts
Four testsets, asserts `cw >= 1` (three times) and `cw >= 0` and `cw isa Int`. Would pass if `constant_wire_count` always returned 1 or even 0. For a "constant_wire_count" metric used as a potential optimization target, there should be a test asserting exact values on a known circuit. E.g., `x + Int8(3)` has exactly N known constants for its 3-immediate wires — assert that.

#### MEDIUM-14 — Feistel bijectivity partially checked
`test/test_feistel.jl:50–59` — W=16 checks "bijection" only by sampling `UInt16(0):UInt16(16):UInt16(0xfff0)` (4096 samples of 65536) and asserting `length(outputs) >= 4000`. A bijection on all 65536 inputs should have exactly 65536 distinct outputs on 65536 distinct inputs; partial sampling proves nothing about bijectivity.

W=32 (line 62–71) only checks determinism + avalanche. A scramble function that repeats every 2^16 outputs would pass.

**Suggested fix:** for W=16, do full 65536 sweep and assert `length(outputs) == 65536`. For W=32, a random sample of 10k distinct inputs and assert no collisions.

#### MEDIUM-15 — `test_vector_ir.jl` samples 6–12 Int8 inputs
`test/test_vector_ir.jl:23, 44`. For Int8-typed functions, 6 inputs is the wrong default. The LLVM vector IR path is highly sensitive to bit-pattern edge cases (i8 overflow, sign wrap, splat boundary conditions). Exhaustive i8 sweep of `f_splat_add` costs 256 sims; exhaustive i8×i8 sweep of `f_splat_icmp` costs 65536 sims — both tolerable.

#### MEDIUM-16 — `test_mul_dispatcher.jl` samples 12 pairs
`test/test_mul_dispatcher.jl:16, 25, 38`. For Int8 mul tests, full 65536 sweep is cheap and expected per CLAUDE.md §3. 12 pairs is token.

#### MEDIUM-17 — external-tool-gated tests are silently fragile
`test_t5_corpus_c.jl` and `_rust.jl` skip when `clang`/`rustc` are absent via `@test_skip`. `test_p5b_bc_ingest.jl` skips when `llvm-as` is absent. CI configurations that lack these tools emit skipped markers, but there is no top-level CI guard asserting these tools are present on the "official" test environment. A developer could accidentally `apt remove clang`, watch CI go green, and not notice.

**Suggested fix:** add a `test_required_tools.jl` (early in `runtests.jl`) that `@info`s when tools are missing and, under `ENV["BENNETT_CI"] == "1"` or similar, fails loudly.

#### MEDIUM-18 — `test_t0_preprocessing.jl` and `test_preprocessing.jl` have "runs without error" asserts
`test/test_preprocessing.jl:16–21` — `"custom passes run without error"`: asserts `parsed isa Bennett.ParsedIR` and `!isempty(parsed.blocks)`. A preprocessing pass that dropped all instructions but kept the block header would pass.

**Suggested fix:** after custom-passes run, assert something specific about the post-pass IR — e.g., "mem2reg on a function with allocas removes all IRAlloca instructions" — not just "it's still a ParsedIR."

#### MEDIUM-19 — `ir_parser.jl` (legacy) has no dedicated tests
`src/ir_parser.jl` contains regex-based parsing (`parse_function_header`, `parse_ssa_name`, `parse_operand`, and constants `RE_FUNCDEF`, `RE_ARG`). It's reached only via `parse_ir(ir)` in `test_parse.jl`, which calls it implicitly. The regex edge cases — quoted SSA names, signext/zeroext modifiers, negative integer constants — have no direct unit tests. If someone removes `ir_parser.jl` entirely under the assumption "we're on LLVM.jl now", `test_parse.jl` will fail (the module depends on it). Thin safety net for dead-code identification.

### LOW

#### LOW-20 — `runtests.jl` has no top-level `@testset` wrap
`test/runtests.jl` is 135 lines of flat `include()` calls. Failures in one testset do not abort the suite (as is Julia's `@testset` default), and there is no aggregate report at the top level beyond what `Pkg.test()` emits. Minor: a top-level `@testset "Bennett.jl full suite"` wrap would produce one summary line even if intermediate test files misbehave.

#### LOW-21 — Redundant assertion in `test_toffoli_depth.jl`
`test/test_toffoli_depth.jl:91–95` asserts three equivalent equalities: `toffoli_depth == t_depth(;:ammr) == t_depth()` (default). The `t_depth()` default being `:ammr` is already asserted in the explicit line; the third line is a tautology given the second. Not a bug, just noise.

#### LOW-22 — Print-only "baselines" in many tests are hard to regress-detect
Dozens of testsets `println("  <name>: $(gate_count(...))")` without asserting. These are useful for humans reading CI output but provide no automated signal. A future cleanup could move all of them to an `@info "baseline" ...` pattern or a `benchmark/` script that produces JSON deltas.

#### LOW-23 — `_compute_ancillae` (bennett_transform.jl) has no direct test
`src/bennett_transform.jl:1–6`. A 3-line function. If it returned an empty list, every subsequent test using simulate would still pass (no ancilla wires to check). Minor orphan.

#### LOW-24 — `_read_output`/`_read_int` (simulator.jl) return types are untested at exotic widths
`src/simulator.jl:42–68` has special-case branches for W ∈ {8, 16, 32, 64}. Other widths (1, 2, 3, 7, 17, 33) fall to the generic `Int(raw & ...)` branch. The tabulate tests exercise W=2/3/4 outputs. No test at W=5 or W=7 (used by Cuccaro internals? unclear). Minor.

### NITs

#### NIT-25 — CLAUDE.md footer statement about test_softfloat
CLAUDE.md file structure lists `test_softfloat.jl — soft-float library (1,037 tests)`. The file has 18 `@test` / `@testset` lines and ~117 lines of code. 1,037 is the count of test iterations (random fuzzing loops contribute 10_000 iterations with 1 @test each, etc.). Not a lie, but misleading — "test" in Julia-land is usually a single `@test` call.

#### NIT-26 — Several testset names use inconsistent capitalization / framing
e.g., "Increment:", "Polynomial:", "Bitwise:", "Two args:", "Multi-block branching", "Controlled circuits", "EAGER Bennett cleanup" — mixing colons, capitalization styles. Minor.

#### NIT-27 — `test_float_circuit.jl` uses `using Random` inside the testset body
Good hygiene — and it's used to seed `Random.MersenneTwister(42)`. But `rand(rng) * 200 - 100` everywhere encodes the same narrow-range bias as the unit tests. See HIGH-10.

---

## 4. Tests I suspect pass the wrong way

| File:lines | Assertion | Why suspect false-positive |
|---|---|---|
| `test_constant_wire_count.jl:9, 15, 23, 29` | `@test cw >= 1` / `>= 0` | Passes for any non-negative return; does not pin the value |
| `test_ancilla_reuse.jl` (all testsets) | no `@test` on ancilla count; prints only | Passes if `ancilla_count` returns literally anything |
| `test_eager_bennett.jl:99–108` (`"eager_bennett: gate count baselines"`) | no `@test` at all | Empty testset; passes trivially |
| `test_dep_dag.jl:9, 26` | `length(dag.nodes) > 0`, `> 10` | Passes for any non-trivial DAG; no topology check |
| `test_persistent_hamt.jl:154` | `10_000 < gc.total < 1_000_000` | Range ratio 100×; not a real anchor |
| `test_persistent_interface.jl:83` | `100 < gc.total < 100_000` | Range ratio 1000×; not a real anchor |
| `test_feistel.jl:58` | `length(outputs) >= 4000` (of 4096 samples) | A 3% collision rate would still pass; does not prove bijectivity |
| `test_liveness.jl:52` | `last_use >= 1` for every tracked variable | Trivially true by construction of the liveness map |
| `test_sha256.jl` full round | 2 hand-picked inputs | Any round function that happens to work for SHA-256's canonical IVs would pass |
| `test_preprocessing.jl:19` | `parsed isa Bennett.ParsedIR && !isempty(parsed.blocks)` | Passes for any non-trivial preprocessing pass — including ones that drop everything useful but keep headers |

And more generally: **every test file that compiles a circuit and calls only `verify_reversibility` without `simulate`** is effectively checking a tautology. Under the current `verify_reversibility` implementation, that function would only fail if `apply!` is buggy or the gate list mutates. Not if Bennett's construction is buggy.

Ranked: 5 files exhibit this pattern (per CRITICAL-2).

---

## 5. What IS good (worth preserving)

- `test_wire_allocator.jl` — proper unit tests of the allocator, including high-water-mark, free-and-reuse, empty-free edge cases.
- `test_shadow_memory.jl` — thorough correctness sweeps on stored + loaded primal state with exhaustive i8 round-trips.
- `test_softfdiv_subnormal.jl` — the only soft-float test that uses raw-bit fuzzing. Should be the template.
- `test_soft_mux_mem_guarded.jl` — excellent coverage of all NxW shapes with both edge-case sweeps AND 1000 randoms per shape.
- `test_increment.jl`, `test_polynomial.jl`, `test_bitwise.jl`, `test_compare.jl` — the Int8-exhaustive foundation tests. Gold standard.
- `test_cc06_error_context.jl` — exemplar of error-message-format testing.
- `test_p5_fail_loud.jl` — proper fail-loud contract tests for file I/O + declaration-only errors.
- `test_toffoli_depth.jl` — comprehensive basic-shapes coverage.
- `test_self_reversing.jl` — well-targeted P1 coverage.

If every source file had testing as tight as `test_wire_allocator.jl` and `test_shadow_memory.jl`, this review would be much shorter.

---

## 6. Top-3 priority fixes (if I were given half a day)

1. **Fix `verify_reversibility` to actually check ancilla-zero** (CRITICAL-1). One function, ~10 lines. Fixes a semantic lie in the test suite's load-bearing helper.
2. **Add `@test verify_reversibility + simulate` to the 5 files in CRITICAL-2.** Fifteen minutes of edits. Eliminates 5 silent gaps.
3. **Add `test_karatsuba.jl` to `runtests.jl` AND widen its input range to `typemin:typemax`** (HIGH-6). Two lines in runtests.jl + one line in test_karatsuba.jl. Turns a dead file into a live guard.

Next tier: `depth(c)` unit tests (CRITICAL-3), raw-bits soft-float fuzzing templated from `test_softfdiv_subnormal.jl` (HIGH-10), tightening the persistent-map "sanity bounds" (MEDIUM-11).
