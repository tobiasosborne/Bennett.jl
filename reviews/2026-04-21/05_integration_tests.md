# Integration & End-to-End Coverage Review — Bennett.jl

**Reviewer:** QA Integration (independent, skeptical)
**Date:** 2026-04-21
**Scope:** `test/` (~112 files, 11,330 LOC), `runtests.jl`, CI, pipeline seams
**Mandate:** Assess whether feature **combinations** are actually exercised — not whether each feature has unit tests.

---

## 0. Feature × Feature interaction coverage matrix

Coverage key: **COVERED** = a test drives both features through the full pipeline and checks
correctness. **PARTIAL** = touched but gaps (no correctness sweep, or one feature stubbed, or narrow input range). **UNCOVERED** = no test found.

| # | Feature A | Feature B | Coverage | Citation |
|---|-----------|-----------|----------|----------|
| 1 | NTuple input | phi resolution | UNCOVERED | `test_ntuple_input.jl` has only 2- and 3-elt tuples, no branching inside `process3`/`tuple_max` (the second uses a bare `?:` which LLVM folds to `select`, not a CFG phi). |
| 2 | NTuple input | soft-float return | UNCOVERED | No test. `test_0c8o_vector_sret.jl` tests NTuple{9,UInt64} in `linear_scan_pmap_set` but return is `UInt64`, no soft-float op inside. |
| 3 | NTuple input | controlled circuit | UNCOVERED | `test_controlled.jl` has no NTuple cases. |
| 4 | NTuple input | shadow memory / MUX EXCH | UNCOVERED | NTuple flattening is tested only on straight-line arithmetic (`t[1]*t[2]+t[3]`). No NTuple input feeding an alloca-backed store. |
| 5 | Shadow memory | phi (diamond CFG) | COVERED | `test_memory_corpus.jl` L7e (shadow+diamond), L7g (T4+diamond). Dedicated. |
| 6 | Shadow memory | MUX EXCH (mixed) | COVERED | `test_qrom_dispatch.jl` "static-idx stores + dynamic-idx load" — exactly the compose case. |
| 7 | Shadow memory | QROM | PARTIAL | `test_qrom_dispatch.jl` tests QROM alone and mixed shadow+MUX alone; no test combines a shadow alloca AND a global-const QROM table AND a load in one function. |
| 8 | Shadow memory | Feistel | UNCOVERED | Feistel is a standalone primitive (`test_feistel.jl` uses `_compile_feistel` hand-built LR); it is never mixed with a shadow-backed store. |
| 9 | MUX EXCH | controlled circuit | UNCOVERED | `test_controlled.jl` never wraps a MUX-EXCH-backed circuit. `test_mutable_array.jl` tests MUX without controlling. |
| 10 | QROM | controlled circuit | UNCOVERED | No QROM-inside-controlled test. |
| 11 | QROM | phi / branch | PARTIAL | `test_qrom.jl`/`test_qrom_dispatch.jl` do not exercise QROM inside an `if`. |
| 12 | Cuccaro adder | phi | UNCOVERED | `test_cuccaro_safety.jl` has only straight-line fns; no branching. |
| 13 | QCLA adder | wider widths | COVERED | `test_add_dispatcher.jl` `:qcla` + Int8; `test_qcla.jl` wider. |
| 14 | QCLA adder | phi / branch | UNCOVERED | No `add=:qcla` inside an `if`. |
| 15 | QCLA tree multiplier | phi / branch | UNCOVERED | `test_mul_dispatcher.jl` has no branching function with `mul=:qcla_tree`. |
| 16 | Karatsuba mul | mixed width | UNCOVERED | Karatsuba only tested on Int16×Int16 identity shape. |
| 17 | `mul=:qcla_tree` | `add=:qcla` | UNCOVERED | No test passes BOTH strategy kwargs simultaneously. |
| 18 | `optimize=true` | sret | COVERED | `test_0c8o_vector_sret.jl` (SLP vectorised optimize=true). |
| 19 | `optimize=false` | sret | COVERED | `test_uyf9_memcpy_sret.jl` + `test_0c8o` "memcpy-form auto-canonicalised". |
| 20 | `optimize=false` | tuple return | PARTIAL | `test_sret.jl` uses default optimize=true; only Bennett-uyf9 regression asserts optimize=false extraction (not the full reversible_compile). |
| 21 | `preprocess=true` | `use_memory_ssa=true` | COVERED | `test_memssa_integration.jl` at L37-47 with both flags. |
| 22 | `preprocess=true` | sret | UNCOVERED | Never combined. |
| 23 | `use_memory_ssa=true` | reversible_compile correctness | UNCOVERED | `test_memssa_integration.jl` only verifies MemSSA info fields. Never calls `reversible_compile` with `use_memory_ssa=true` and simulates. (Honest caveat in the test file comments: "Wiring the info into lower_load! for correctness-improving dispatch is out-of-scope follow-up.") |
| 24 | Soft-float | integer ops in same function | COVERED | `test_float_poly.jl`, `test_float_circuit.jl` polynomial `x*x+3x+1`. |
| 25 | Soft-float | reversible_compile agreement with hardware | PARTIAL | `test_float_poly.jl` compares compiled simulate against `f(x)` (Julia native) for ~60 points. `test_softfloat.jl` verifies `soft_fadd == +` at Float64 level. No test verifies the **composed** chain `reversible_compile(x→x+y, Float64) ≡ Float64(a)+Float64(b)` across a random battery. |
| 26 | Soft-float | phi / branch | PARTIAL | Inside the soft-float library itself; the source is branchy. User-facing test has limited cases: `x > 0 ? … : …` on Float64 is untested. |
| 27 | Soft-float | controlled circuit | UNCOVERED | No controlled(float_circuit) test. |
| 28 | Soft-float | MUX EXCH | UNCOVERED | `test_soft_mux_mem_guarded.jl` exercises guarded MUX, not Float64 inside memory. |
| 29 | Persistent map | controlled circuit | UNCOVERED | Persistent tests never wrap in `controlled()`. |
| 30 | Persistent map | nested loop | UNCOVERED | Persistent tests use straight-line 3-key demos (`_ls_demo`). |
| 31 | Persistent map | MUX EXCH / shadow | N/A / UNCOVERED | Persistent implementations are callee-inlined; their memory pattern is straight-line; no combination beyond own internals. |
| 32 | Persistent map | phi resolution | COVERED (weakly) | Persistent map set/get have internal conditional merging. Circuit compiles and passes correctness sweep on 30 random inputs; no exhaustive exercise. |
| 33 | Multi-argument | phi | COVERED | `test_predicated_phi.jl` `nested_shared(a,b)` — but only Int8. |
| 34 | Multi-argument | callee inlining | PARTIAL | `test_callee_bennett.jl` exercises Float64-poly multi-arg inlined soft-float; `test_general_call.jl` exercises user `register_callee!`; never multi-arg+CFG-phi+callee in one function. |
| 35 | `max_loop_iterations` | phi | PARTIAL | `test_loop_explicit.jl` collatz_steps has `while` with inner `if`; x in Int8(1):Int8(30) only, not exhaustive. |
| 36 | Bounded loops | wider types | UNCOVERED | `max_loop_iterations` is Int8-only in existing tests. |
| 37 | Mixed-width (sext/zext/trunc) | tuple return | UNCOVERED | `test_mixed_width.jl` has no tuple returns. `test_sret.jl` "mixed arg widths" passes through, no sext/zext. |
| 38 | Mixed-width | soft-float | UNCOVERED | Float32↔Float64 conversion tested (`test_float_circuit.jl`), but never combined with integer sext. |
| 39 | `optimize=true` | mixed-width | PARTIAL | Default optimize=true in test_mixed_width but no sret combination. |
| 40 | Tabulate strategy | controlled | UNCOVERED | `test_tabulate.jl` doesn't wrap in `controlled()`. |
| 41 | Tabulate strategy | NTuple input | UNCOVERED | Tabulate only tested on scalar Int8. |
| 42 | `strategy=:tabulate` | `mul=:qcla_tree` | UNCOVERED | Dispatcher kwargs never combined. |
| 43 | Switch statement | phi | PARTIAL | `test_switch.jl` has basic switch+phi but no diamond+switch+loop combination. |
| 44 | Division | phi | UNCOVERED | `test_division.jl` is straight-line. |
| 45 | Cross-language ingest (.ll/.bc) | full reversible pipeline | COVERED (narrow) | `test_p5a_ll_ingest.jl`, `test_p5b_bc_ingest.jl` do a full .ll → ParsedIR → reversible_compile → simulate → verify for one trivial `x+3 :: i8` function. Nothing else. |
| 46 | Cross-language (C/Rust) | lowering | UNCOVERED (intentional) | `test_t5_corpus_c.jl`, `test_t5_corpus_rust.jl` only verify extract succeeds + `@test_throws ErrorException reversible_compile(parsed)`. Not integration; RED-placeholder for T5-P6. |
| 47 | Controlled circuit | soft-float | UNCOVERED | No test compiles soft_fadd, then controls it, then simulates both branches. |
| 48 | Self-reversing | bennett transform choice | PARTIAL | `test_self_reversing.jl` tests the flag on hand-built LoweringResult; never integrates with a whole `reversible_compile(f, T)` pipeline where f happens to be self-reversing. |
| 49 | Circuit composition (two circuits) | anything | **UNCOVERED — NO API EXISTS** | `grep compose` returns nothing useful in src/. There is no public `compose(c1, c2)` function. You can't stitch two compiled circuits together at the ReversibleCircuit level. This is a gap for the stated quantum-control goal. |
| 50 | Full Bennett round-trip (start state reachable after circuit applied and unapplied on ancillae) | Non-trivial f | MISINTERPRETED | `verify_reversibility` runs the circuit FORWARD then BACKWARD on random input bits and checks `bits == orig` (diagnostics.jl:145-161). This is a **reversibility-of-gates** check, NOT a Bennett-construction-invariant check. The actual Bennett invariant (ancillae = 0 at end of forward-only execution) is checked only inside `simulate` (simulator.jl:30-32). But `verify_reversibility` is what 256 call sites actually invoke. |

---

## Executive summary (skeptical)

- Unit coverage is dense and mostly conscientious; **integration/interaction coverage is shallow and ad hoc**.
- **The name `verify_reversibility` is misleading.** It asserts `forward ∘ reverse = id` on gate sequences — trivially true for any circuit composed of self-inverse gates (NOT, CNOT, Toffoli are all involutions). **This invariant holds for ANY gate sequence regardless of whether Bennett's construction is correctly applied.** The actual Bennett invariant is checked only via side-effect in `simulate` (`bits[w] && error("Ancilla wire $w not zero — Bennett construction bug")`). Tests that call `verify_reversibility` without also calling `simulate` with representative inputs **prove essentially nothing about Bennett-correctness**. This is a systemic problem affecting many tests — see CRITICAL-1.
- `runtests.jl` has **no `@testset` wrapper around its 100+ includes**. A throw outside an `@testset` would abort the suite with no error summary. The top-level include list is a bare include-sequence.
- **No CI configuration** — there is no `.github/workflows/*`, no `.gitlab-ci.yml`, no `Buildkite`, no Travis/Appveyor. Testing is purely local. For a project claiming "~90 seconds, ~10,000 assertions" this is a visible gap; any regression found by a PR author relies on local Julia environment and manual discipline.
- **No gate-count-scaling integration test.** `test_gate_count_regression.jl` pins *individual* values (Int8/16/32/64) and asserts the 2x+4 invariant for `x+1` specifically, but there is no generalised scaling harness (e.g., "for every registered multiplier, verify Toffoli count stays within O(n²) bound across W∈{8,16,32,64}"). The scaling properties advertised in README (Karatsuba O(n^log₂3), QCLA O(log²n)) are asserted **only** for one benchmark datum each.
- **The soft-float ↔ native agreement claim is half-tested.** README says "bit-exact with hardware on add/sub/mul/div/neg/cmp/fptosi/sitofp across 1.2M random raw-bit pairs". The test files do exercise random pairs, but the property tested is `soft_fadd(a_bits, b_bits) == reinterpret(UInt64, a + b)` **at the Julia level**; the reversible-compiled circuit's agreement with native is checked on a much smaller set (~100 pairs in `test_float_circuit.jl`). The README's "1.2M" figure is Julia-level, not circuit-level.
- **No Bennett-construction round-trip test for a non-trivial function.** There is no test that checks the actual Bennett identity `(x, 0) → (x, f(x))` (output contains both the preserved input AND the computed f(x), on disjoint wires, with all ancillae zero). `simulate` gives you f(x); it discards the preserved-input information. The garbage-free property that makes Bennett's 1973 construction non-trivial is never explicitly checked.
- **The multi-language ingest tests are mostly RED-placeholders, not integration tests.** `test_t5_corpus_c.jl`, `test_t5_corpus_rust.jl`, `test_t5_corpus_julia.jl` for the most part wrap `@test_throws ErrorException`. The green test in the whole T5 corpus is 1 function (`TJ3`). P5a/P5b test one function. Calling this "multi-language ingest coverage" oversells by 10×.
- **Circuit composition is not an API.** For a project whose stated goal is `when(qubit) do f(x) end` in Sturm.jl, the inability to compose `controlled(circuit_a)` with `controlled(circuit_b)` and reason about reversibility of the whole is a foundational gap. No test would notice because no test tries.
- **Dispatcher combination is a hole.** `mul=:qcla_tree add=:qcla` never combined in a test. The kwargs can diverge silently.
- The SHA-256 full (64-round) test is the gold-standard e2e. `test_sha256_full.jl` does compile + simulate + verify + check against IEEE reference vector. But the 2-round and 8-round variants are compile-smoke; only the 64-round matches the `"abc"` canonical vector.
- **Pipeline-seam splice tests are well-covered for one seam (`ParsedIR → reversible_compile`).** `_compile_ir(ir_string::String)` helpers in `test_memory_corpus.jl`, `test_mutable_array.jl`, `test_qrom_dispatch.jl` etc. exercise `parse(LLVM.Module, ...) → _module_to_parsed_ir → lower → bennett`. **But the other seam (ParsedIR → lower → bennett without going through LLVM at all)** is never exercised. There is no test that hand-constructs a `ParsedIR` value directly.
- **There is no feature-matrix generator / property test harness.** Each combination must be hand-written. Given ~112 tests vs the 40+ combination cells above with UNCOVERED, the coverage-to-cost ratio is poor.
- Cross-module integration (wire_allocator + bennett + simulator on a non-trivial hand-built circuit) exists in `test_shadow_memory.jl`, `test_feistel.jl`, `test_self_reversing.jl`. Not bad — these are the strongest integration tests in the suite.
- `Pkg.test()` vs `julia --project test/runtests.jl`: `Project.toml` does not list an explicit `test` target block; Pkg.test runs `test/runtests.jl` by default. They are equivalent. Good.
- `test_t5_corpus_rust.jl` silently no-ops if `rustc` not on PATH — **a regression there would pass on a machine without rust**. Similar for `clang`, `llvm-as`.

---

## Findings (prioritized)

### CRITICAL

**CRITICAL-1 — `verify_reversibility` is semantically misnamed and tests misuse it.**

`src/diagnostics.jl:145-161`:
```julia
function verify_reversibility(c::ReversibleCircuit; n_tests::Int=100)
    for _ in 1:n_tests
        bits = zeros(Bool, c.n_wires)
        ... set input bits randomly ...
        orig = copy(bits)
        for g in c.gates; apply!(bits, g); end
        for g in Iterators.reverse(c.gates); apply!(bits, g); end
        bits == orig || error(...)
    end
    return true
end
```

NOT, CNOT, and Toffoli are all involutions (each gate is its own inverse). Applying a sequence forward then backward **always** returns the original state, regardless of whether the ancillae were uncomputed by the Bennett construction. A broken lowering that never uncomputes anything would still pass this check. The only places the true Bennett invariant (ancillae zero after forward pass on real inputs starting at zero) is asserted are:

1. `src/simulator.jl:30-32` (inside `simulate`) — checks `bits[w] && error(...)` for ancilla wires
2. Tests that call `simulate(circuit, input)` with specific inputs

Tests that call ONLY `verify_reversibility` without exhaustive/random `simulate` on real inputs are not verifying Bennett-correctness. Examples:

- `test_sha256.jl:11,17,21,25` — each sub-function is verified only by `verify_reversibility` (lines 11,17,21,25); correctness is only checked on the composed SHA-256 round at line 60-63 (two input vectors).
- `test_shadow_memory.jl:96-99` — asserts gate count but not correctness for W∈{4,8,16} single-store.
- `test_feistel.jl:40` "W=8 rounds=4 — bijective on all 256 inputs" — **this one is fine** (it does iterate inputs). But the W=16/32 variants are sampled, not exhaustive.

**Severity: CRITICAL.** Principle 4 of CLAUDE.md explicitly says "'Runs without errors' is not a passing test. The test must verify the actual output against a known-correct answer for every input." The current `verify_reversibility` is precisely "runs without errors" — it is not, despite its name, a Bennett-invariant check.

**Remediation:**
1. Rename to `verify_gate_involution` or `verify_forward_reverse_identity`. This is what it does.
2. Add a *real* `verify_bennett_invariant(c)` that runs the circuit forward on random-input-ancilla-zero state and checks `c.ancilla_wires` are zero at end. (This is what `simulate` does internally; factor it out.)
3. Audit all ~256 call sites and ensure each is paired with an exhaustive / sampled correctness sweep of real `simulate` outputs, OR upgrade the call to use the new invariant check.

---

**CRITICAL-2 — No CI. "Full test suite must pass" is an honor system.**

Absence of `.github/`, `.gitlab-ci.yml`, Travis, Appveyor, Buildkite, or any other CI configuration means pre-merge verification is entirely local to the author's machine. The project makes specific claims about gate counts, timing, and reversibility that depend on LLVM version, Julia version, and platform. The WORKLOG (gitStatus-referenced) and git log are full of assertions about what "passes locally" — none of which are publicly verifiable by a reviewer.

**Severity: CRITICAL** for a compiler claiming bit-exactness and reproducibility. **Remediation:** add a `.github/workflows/test.yml` that runs `julia --project -e 'using Pkg; Pkg.test()'` on a supported Julia version matrix (1.10, 1.11 + nightly). Pin LLVM version explicitly. Cache `~/.julia/artifacts`. This is a one-day job.

---

**CRITICAL-3 — No circuit composition API, no test — blocks the stated v1.0 goal.**

Per README §"Why": `when(qubit) do f(x) end` requires compositional control. The current `ReversibleCircuit` is an opaque record of `gates, n_wires, input_wires, output_wires, ancilla_wires, output_elem_widths`. There is no `compose(c1, c2)` or `chain(c1, c2)` in `src/`. `controlled(c)` wraps a single circuit. There is no way to express "apply c1 to wires A, then c2 to wires B where B partially overlaps A's output." No test in the 112-file suite tries.

For a reversible-computing compiler, this is a semantic-API gap. Tests that might have surfaced it: composing `controlled(reversible_compile(ch, UInt32, UInt32, UInt32))` with `controlled(reversible_compile(maj, ...))` to build a controlled-SHA-round piecewise. Nobody tried.

**Severity: CRITICAL** against the stated v1.0 roadmap. MEDIUM for current scope if quantum-control is explicitly deferred — but then the README's framing is aspirational, not current.

---

### HIGH

**HIGH-1 — T5 corpus (C / Rust / Julia) is misrepresented as "multi-language integration."**

`test_t5_corpus_c.jl` TC1/TC2/TC3, `test_t5_corpus_rust.jl` TR1/TR2/TR3, `test_t5_corpus_julia.jl` TJ1/TJ2/TJ4 — **9 of 10 cases are `@test_throws ErrorException`**. Only TJ3 (mutable linked list) actually compiles end-to-end, and that case compiles because LLVM constant-folds the whole function into `x + Int8(2)` (see L138-143 of test_t5_corpus_julia.jl: "distinct named globals ⇒ icmp eq is statically false ⇒ the whole function reduces to `x + Int8(2)`").

The `test_p5a_ll_ingest.jl` / `test_p5b_bc_ingest.jl` files cover a single hand-crafted `.ll` with `add i8 %x, 3`. One function. One width. One opcode.

**The claim "multi-language ingest" is supported by ONE non-trivial `.ll` fixture, ONE bitcode conversion, and three `@test_throws`.** Calling these "integration tests" overstates by roughly an order of magnitude.

**Severity: HIGH.** The TC/TR files are not integration tests — they are tracker pins for a TODO. They should be renamed `test_t5_corpus_c_pending.jl` or moved out of `runtests.jl` when T5-P6 lands. Alternatively, add one non-trivial C and one non-trivial Rust fixture that DO go end-to-end *today* (e.g., a C function equivalent to `x + 3` that is not just hand-written `.ll`), so the ingest claim has teeth.

---

**HIGH-2 — `use_memory_ssa=true` is never validated end-to-end.**

`test_memssa_integration.jl` tests (L37-123) assert that `parsed.memssa` is populated after `extract_parsed_ir(f, T; preprocess=true, use_memory_ssa=true)`. **Zero tests call `reversible_compile` with `use_memory_ssa=true` and `simulate` the result against native.** The test file explicitly acknowledges this at L14-16 ("Wiring the info into lower_load! for correctness-improving dispatch is out-of-scope follow-up").

This means `use_memory_ssa=true` is an **advertised public feature** in the README (line 168-173) whose compilation-correctness under the flag is **not tested in the suite**. If a future `lower_load!` starts reading `parsed.memssa`, no regression test will catch a MemSSA-dependent correctness bug.

**Severity: HIGH.** Remediation: add at least one `reversible_compile(f, T; use_memory_ssa=true)` test that simulates against native on a function where MemSSA info is non-trivial (e.g., the diamond-with-conditional-store at L49-70 of `test_memssa_integration.jl`).

---

**HIGH-3 — `runtests.jl` is a bare include list with no guarding `@testset`.**

`test/runtests.jl:1-134` — no outer `@testset`. Each include defines its own `@testset`. If any include throws at top level (not inside @testset — e.g., a macro expansion error, a module-load error, or a `const` evaluation failure), `Pkg.test` reports a failed test file but there is no aggregate pass/fail summary and subsequent tests don't run.

More concerning: `const C_FIXTURES = joinpath(@__DIR__, "fixtures", "c")` is evaluated at include time. If a test file moves fixtures, the entire suite fails during loading, not on a specific test. Debugging is harder than necessary.

**Severity: HIGH** for maintainability. Minimal fix: wrap the 100+ includes in a single `@testset "Bennett.jl" begin ... end`. Include ordering should also move `test_sha256_full.jl` (slow) to the end — it's currently at position 48 of 100, so a quick run-till-fail on an early include still takes minutes.

---

**HIGH-4 — No gate-count scaling regression (O(n), O(n²), O(log n), O(log²n) claims unenforced).**

README advertises:
- Karatsuba O(n^log₂3)
- QCLA O(log n) Toffoli-depth
- Sun-Borissov O(log²n) T-depth
- Ripple O(n) depth

`test_gate_count_regression.jl` pins individual values for Int8/16/32/64 `x+1` (3 widths × 1 function), `x^2+3x+1` at Int8 only, and `x*x` at Int8+Int16 only. **There is no test asserting "Toffoli count at W=64 is between K·64 and K·64·log₂(64)".** A regression that makes Karatsuba O(n²) at W=64 would not be caught.

**Severity: HIGH.** Remediation: for each advertised scaling, add a parameterised test over W∈{8,16,32,64} that asserts `t_count(c) < C·W^α` with a ~2× margin. Pin each α-exponent to the README claim.

---

**HIGH-5 — Soft-float circuit-level agreement with hardware is under-tested.**

Claim (README line 178): "bit-exact with hardware on add/sub/mul/div/neg/cmp/fptosi/sitofp across 1.2M random raw-bit pairs including all subnormal, NaN, Inf, signed-zero, and overflow regions."

`test_softfloat.jl` does exercise many edge cases and random batches — at the **Julia soft_fadd(a,b) vs a+b level**. That's bit-exactness of the *soft-float function*. Fine.

`test_float_circuit.jl` for `soft_fadd` compiled: 10 basic + 6 equal-magnitude + 100 random = 116 pairs. For `soft_fmul`: 11 basic + 2 equal + 100 random = 113. **Far from 1.2M at circuit level.** The "1.2M random raw-bit pairs" figure applies to the Julia function, not the reversible circuit. The README conflates these.

**Severity: HIGH** for truth-in-advertising. MEDIUM for correctness risk (the circuit is derived mechanically from the Julia function, so if the Julia function is bit-exact and the compiler is correct, the circuit is bit-exact). Remediation: either widen circuit-level random sweeps to 10k+ pairs, or clarify the README.

---

**HIGH-6 — No dispatcher-combination tests.**

`test_add_dispatcher.jl` varies `add=`; `test_mul_dispatcher.jl` varies `mul=`. Neither exercises both at once. Neither combines `strategy=:tabulate` with a dispatcher. Neither combines `optimize=false` with a dispatcher (default optimize=true throughout).

A concrete bug this could mask: if `lower!` hard-codes ripple-adder instances inside the shift-add multiplier (as it may, given that the multiplier predates the adder dispatcher), setting `mul=:shift_add, add=:qcla` could yield a mixed-strategy circuit that happens to be correct for Int8 but breaks at Int32. **No test would catch this.**

**Severity: HIGH.** Remediation: a matrix test `for m in (:shift_add,:karatsuba,:qcla_tree), a in (:ripple,:cuccaro,:qcla)` at one or two widths.

---

### MEDIUM

**MEDIUM-1 — The `_ls_demo` persistent-map test is the only integration point for the entire persistent-DS lineage.**

`test_persistent_interface.jl` covers linear_scan, and the Okasaki/HAMT/CF/Hashcons tests each compile `_ls_demo`-like functions. But none of them test the dispatcher *selecting* a persistent strategy — they hand-call the implementation. Integration with `reversible_compile(f, T)` where f uses `Vector{Int8}` and the dispatcher picks a persistent-map strategy is TODO (T5-P6).

Fine — persistent DS is WIP. But the README (line 97-110) lists scaling results as if they were integration-verified. They are implementation-verified, not dispatcher-verified. Clarify scope.

---

**MEDIUM-2 — Bennett round-trip (preserved input + computed output + zero ancillae) is implicit, not asserted.**

The Bennett-construction **identity** is `(x, 0) → (x, f(x))`. `simulate` reads only `c.output_wires` (which are the f(x) copy) and does not assert that `c.input_wires` bits STILL HOLD x after forward execution. Since the simulator is bitwise and wires are disjoint, x is preserved by construction, but no test asserts this directly. A bug where input wires get corrupted mid-circuit but zeroed before "copy" would be invisible.

Remediation: one test `assert_input_preserved(c, x)` that runs forward and checks input wires hold original x.

---

**MEDIUM-3 — No test of the ParsedIR → lower seam without LLVM.**

`test_mutable_array.jl` / `test_memory_corpus.jl` / `test_qrom_dispatch.jl` use hand-written `.ll` strings, parsed via `LLVM.parse(LLVM.Module, ...)`, then `_module_to_parsed_ir → lower → bennett`. This tests `parse + convert + lower + bennett`.

A test that hand-constructs a `ParsedIR` Julia value (bypassing LLVM entirely, then feeding `lower(parsed)` then `bennett(lr)`) does not exist. This seam is relevant for the stated future "other LLVM-emitting languages" story — if I want to emit ParsedIR from a hypothetical Rust-MIR frontend, I need this seam to be stable and tested.

Severity: MEDIUM now, HIGH if the roadmap includes non-LLVM frontends.

---

**MEDIUM-4 — No composition of `controlled` with non-trivial memory.**

`test_controlled.jl` wraps `f(x) = x+3`, `x*x+3x+1`, two-arg, Int16, tuple-return. None involve a `Ref`, an alloca, a QROM table, or a soft-float op. If `controlled()` mishandles ancilla patterns produced by shadow or QROM, no test would notice.

---

**MEDIUM-5 — The multi-language fixtures silently skip without rust/clang/llvm-as.**

`test_t5_corpus_rust.jl:33`, `test_t5_corpus_c.jl:29`, `test_p5b_bc_ingest.jl:18` all use `@test_skip` when the compiler isn't on PATH. In CI this is usually fine, but **there's no CI**, and on a bare dev machine the output reads as "tests passed" when actually nothing ran.

Remediation: at minimum, print a loud warning; ideally fail hard in CI and skip only in a `BENNETT_DEV_SKIP=1` local mode.

---

**MEDIUM-6 — `test_sha256_full.jl`'s 2-round and 8-round variants test "it compiles" but not "against IEEE reference."**

L155-166 of test_sha256_full.jl: the 2-round and 8-round subtests check `simulate == sha256_compress_N(reference Julia impl)`. That's tautological — you're testing the compiler against the same Julia code you just extracted. The IEEE test vector check happens only for the 64-round variant. If the unrolling logic in `_sha256_body` was buggy, the reference and the compiler would both be wrong, and the test would pass.

Remediation: assert `sha256_compress_64(H0, abc...) == expected_hash` (already present L143) AND for 8-round at least, derive a non-trivial assertion about partial state.

---

**MEDIUM-7 — `test_float_circuit.jl` conflates circuit-level tests and soft-float tests.**

The "Float64 division end-to-end" subtest (L104-152) compiles `x/y`, which routes through SoftFloat → soft_fdiv → reversible circuit. Random 50 pairs ∈ [-100, 100]. It compares `simulate(circuit, ...) == a/b` (the **native** hardware div). That's one of the few genuinely compositional integration tests: soft-float + circuit + vs-hardware. Good — but it's 50 pairs only. A single subnormal/NaN test battery (like the Julia-level `test_softfloat.jl`) at the compiled-circuit level across 1000+ pairs would be far stronger.

---

### LOW

**LOW-1 — Wire allocator + bennett + simulator integration exists only via shadow/feistel tests.**

`test_wire_allocator.jl`, `test_shadow_memory.jl`, `test_feistel.jl`, `test_self_reversing.jl` hand-assemble `ReversibleGate[]` arrays and call `bennett(LoweringResult(...))`. These are good cross-module tests. However, they use hand-written gate sequences, not output of `lower`. They verify the *wire-level abstractions*, not the full end-to-end compilation.

Not a bug — just note that what looks like "cross-module tests" are mostly isolated lower-bennett-simulate without `lower()`.

---

**LOW-2 — Liveness analysis is tested in isolation, not combined with dispatchers.**

`test_liveness.jl` (not read but present) tests liveness independently. `:auto`-mode Cuccaro depends on liveness. No test crosses `add=:auto` with a function where liveness analysis could be fooled (e.g., phi-merged operand).

---

**LOW-3 — Loop tests are Int8 only.**

`test_loop.jl` and `test_loop_explicit.jl` operate on Int8. No Int16/Int32 loop coverage. Int64 loops (inherently slower to unroll) are untested.

---

**LOW-4 — No golden-file / serialisation test.**

A compiled `ReversibleCircuit` is a pure value. No test serialises a circuit, reloads it, and compares. Relevant for interchange with future quantum-simulation backends.

---

**LOW-5 — `test_parse.jl` uses the *legacy regex* parser.**

The CLAUDE.md §5 explicitly says LLVM IR is not stable and the LLVM.jl C API walker is the source of truth. `test_parse.jl` imports `extract_ir + parse_ir` (regex path). These are legacy per `src/Bennett.jl:6` (`include("ir_parser.jl")`). The tests pass, but they test the deprecated path. This is fine as backcompat but deserves a comment.

---

### NIT

**NIT-1** — `runtests.jl:94-114` has mixed-case commenting conventions ("Bennett-cc0.7 —", "T5 — persistent map", etc.). Readable, but not uniform.

**NIT-2** — `test_p5_fail_loud.jl` tests `ErrorException`-ness via `occursin` on string messages ("file not found"). If an error message is reworded, the test breaks. Consider asserting error *type* or using a structured error hierarchy.

**NIT-3** — `test_sret.jl:9-12` defines a private `_match` helper with an eccentric signature (reinterpret-and-compare). Fine, but belongs in a shared test utility module, not per-file.

**NIT-4** — Several tests `println` intermediate gate counts for human readability. In CI these become log noise. Consider gating behind `ENV["VERBOSE"] == "1"`.

**NIT-5** — `test_memssa_integration.jl:47` uses bare `@test !isempty(...)`. The tests make weak assertions (non-emptiness) when stronger ones are available (specific number of Defs / Uses).

---

## What's done well

- `test_memory_corpus.jl` is **the strongest integration test file in the suite.** It enumerates the memory-strategy ladder, pins the strategy-picker dispatch, mixes strategies (L7g: T4+diamond), and explicitly distinguishes RED/GREEN. Use it as the template.
- `test_sha256_full.jl`'s 64-round variant is a real end-to-end integration test against a standardised vector. Gold standard.
- `test_qrom_dispatch.jl`'s "static-idx stores + dynamic-idx load" test is exactly the kind of compositional correctness test that catches dispatcher/strategy bugs. More like this, please.
- `test_cuccaro_safety.jl` tests a specific correctness-by-construction property (liveness-driven strategy selection must not fire when operand is live).
- The `_compile_ir` pattern (used in ≥5 test files) is a clean seam for testing ParsedIR → circuit without Julia extraction quirks. Extend this to a first-class helper in a `test/support/` module.

---

## Suggested minimal actions (ordered)

1. **Fix CRITICAL-1**: rename + re-audit `verify_reversibility` call sites. Either add input-sweep pairs or switch to new `verify_bennett_invariant`. (1 day)
2. **Fix CRITICAL-2**: add a basic GitHub Actions workflow. (1 day)
3. **Fix HIGH-3**: wrap `runtests.jl` in one outer `@testset`. Move slow tests last. (30 minutes)
4. **Fix HIGH-6**: add a dispatcher-matrix test. (1 day)
5. **Fix HIGH-2**: one end-to-end test with `use_memory_ssa=true`. (1/2 day)
6. **Address MEDIUM-3**: provide and test a hand-built ParsedIR → lower seam. (1/2 day)
7. **Address HIGH-4**: parameterised scaling regression. (1 day)

File paths (absolute):
- `/home/tobiasosborne/Projects/Bennett.jl/src/diagnostics.jl` (verify_reversibility)
- `/home/tobiasosborne/Projects/Bennett.jl/src/simulator.jl` (ancilla-zero check)
- `/home/tobiasosborne/Projects/Bennett.jl/test/runtests.jl` (no outer testset, no CI target)
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_memory_corpus.jl` (strongest integration file — template)
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_sha256_full.jl` (strongest e2e)
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_gate_count_regression.jl` (narrow regression baseline)
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_memssa_integration.jl` (unconnected to compile correctness)
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_t5_corpus_{c,rust,julia}.jl` (mostly red placeholders)
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_add_dispatcher.jl` + `test_mul_dispatcher.jl` (uncombined)
- No `.github/`, no `.gitlab-ci.yml`, no CI.
