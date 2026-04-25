# Bennett.jl Work Log

## Session log — 2026-04-26 (night) — ardf close + 9c4o investigation in flight

**Shipped:** see `git log` `b52351f..2cd5c06` (2 commits). One bead closed, one bead's investigation pre-staged for next session.

| Bead | What |
|---|---|
| **Bennett-ardf** P3 / U138 (BUG) | Two threads in one bead: (1) replaced unused `_overflow_result` binding in `src/softfloat/fdiv.jl:82` with `_` (explicit discard) — the 2nd return position from `_sf_round_and_pack` was dead because the overflow flags fire `inf_result` directly via the select chain at lines 87–95; (2) added strict-bit-level NaN regression tests for `soft_floor` / `soft_ceil` / `soft_trunc` in new `test_ardf_floor_ceil_nan.jl`. 73 asserts cover 8 NaN bit patterns (canonical qNaN ±, qNaN-with-payload, sNaN that gets quieted, arbitrary payloads). Each fn round-trips bit-exactly through `Base.floor`/`ceil`/`trunc`. Existing `test_soft_fround.jl` only had `if isnan(expected); @test isnan(result)` round-trip checks — never asserted bit-exact NaN preservation. |

**In flight (claimed but not landed) — Bennett-9c4o / U89:** lower.jl forward-refs symbols from modules included AFTER it in `src/Bennett.jl`. Investigation done; the actual code-call dependencies are:

- `divider.jl`: provides `soft_udiv` / `soft_urem` (lower_binop! at line 1578 references these via the callee dispatcher).
- `softmem.jl`: provides `soft_mux_load_*` / `soft_mux_store_*` / `soft_mux_store_guarded_*` (lower_load!/store! M2b paths).
- `qrom.jl`: provides `_emit_qrom_from_gep!` (lower_var_gep! at line 1700 calls into it).
- `shadow_memory.jl`: provides `emit_shadow_load!` / `emit_shadow_store!` / `emit_shadow_store_guarded!` (lower_store! shadow paths).
- `mul_qcla_tree.jl`: provides `lower_mul_qcla_tree!` (lower_binop! mul-strategy dispatcher at line 1260).

None of these forward-ref'd modules call BACK into lower.jl at code level (some have docstring mentions only). Reorder plan: move `lower.jl` from include position 13 to AFTER divider/softmem/qrom/shadow_memory/mul_qcla_tree (and their support files like fast_copy/partial_products/parallel_adder_tree). This is safe because:

- adder/qcla/multiplier are called by lower.jl's strategy dispatchers and stay BEFORE lower.jl (current position).
- `tabulate.jl` constructs `LoweringResult` so MUST come after lower.jl (currently at line 28; stays AFTER).
- `bennett_transform.jl`, `simulator.jl`, etc. consume LoweringResult and stay after.

Bennett-9c4o is left **claimed** so the next agent can pick up from this analysis. The actual edit is a one-block include-list reorder in `src/Bennett.jl`. Risk: subtle Revise / precompile interactions with the new order — Pkg.test should catch any. Recommend the next session run Pkg.test BEFORE and AFTER the reorder to confirm nothing depends on the OLD order.

**Why:** continuation of catalogue grind. ardf was a clean two-part fix (dead-code + missing test). 9c4o investigation took the session's runway; punting the implementation to a fresh session is the right call rather than hurrying it.

**Gotchas / Lessons:**

- **Bead-cited line numbers go stale fast.** ardf cited "src/softfloat/fdiv.jl:82-87" — line 82 was correct (the `_overflow_result` site) but the actual code occupied lines 81-83 not 82-87. 9c4o cited "src/lower.jl:1140, 1458, 1935, 1941, 2260" — none of those line numbers had relevant content; the actual forward-refs were at 1260, 1578, 1700, 1854, 1875, etc. *Pattern*: when triaging a bead with line-numbers, grep for the symbol-of-interest, NOT the line numbers. Line numbers are write-once-read-stale.

- **Julia's late-binding lets forward-refs work but breaks single-file loadability.** Globals are resolved at function-call time, not parse time. So lower.jl's `soft_udiv` reference at line 1578 works as long as `soft_udiv` is defined by the time `lower_divrem!` is CALLED. The cost: lower.jl can't be standalone-loaded for testing or REPL inspection without first loading the entire dependency stack. The 9c4o fix restores that property by putting all referenced modules BEFORE lower.jl.

- **Comments containing function names trigger string-search false positives.** First grep for `lower_var_gep` in qrom.jl found a hit, but the hit was a docstring mention ("Dispatch helper invoked by `lower_var_gep!` ..."). No actual call site. *Pattern*: when checking dependencies, always look at the matching LINE — docstring mentions don't create code-level dependencies.

- **Strict-bits NaN test for soft_floor/ceil revealed they were correct all along.** Wrote the regression test, ran it, all 73 asserts passed first try. The bead's claim was "untested" not "wrong" — and the existing implementation chains through soft_trunc → soft_fadd which already has strict-bits NaN coverage from Bennett-r84x. Pure coverage gap fill.

- **Bead-level scope can usefully split into "easy" and "more serious" within ONE bead.** ardf had two distinct concerns (dead binding fix + missing tests). Both shipped in one bead-close + one commit. Some beads have a similar shape; reading the description carefully reveals separable threads.

**Rejected alternatives:**

- **Doing the 9c4o include-reorder this session.** Would have squeezed it into the available runway but required an extra full Pkg.test cycle (~5 min) plus careful verification. Better to land the analysis and let the next session execute cleanly.

- **Adding a reordering test for 9c4o.** The actual invariant the include order encodes is "every symbol referenced by `lower.jl` must be defined by the end of `Bennett.jl`'s `include(\"lower.jl\")` call". This is hard to assert without running the module load — Pkg.test does that organically. No new test needed for the reorder.

- **Replacing the dead `_overflow_result` with a runtime assertion** that `_overflow_result == inf_result` whenever the overflow flag fires. Tempting (would catch a future inconsistency in `_sf_round_and_pack`'s contract) but adds branchy code to a hot path. The select chain already handles the overflow cleanly via `inf_result`; a redundant check would buy nothing meaningful.

**Next agent starts here:**

1. **Branch state at session-end**: `2cd5c06` on main, pushed. Worklog top is **this** entry; chunk 043 is now ~270 lines. Approaching the 280 cap; chunk 044 likely starts next session.

2. **Catalogue progress this session (1 close, 1 in-flight)**: ~126 → ~125 ready remaining (ardf closed; 9c4o still claimed). Cumulative for the day's grind = 28 closes (6t8s through ardf). Test count growth: +678 across 18 new test files. Pkg.test count: 73068/73071 (3 broken).

3. **Next agent: pick up Bennett-9c4o** by executing the include reorder per the analysis above. Concretely: cut `include("lower.jl")` from `src/Bennett.jl:13` and re-paste it after `include("mul_qcla_tree.jl")` (currently line 35). Run Pkg.test. If green, ship. If something breaks, the most likely culprit is a missing `softfloat/softfloat.jl` ordering — softfloat may need to be loaded BEFORE softmem (which uses `soft_fadd`), and softmem must be before lower.

4. **Quick wins still on the menu** (each ~30-90 min, no 3+1 needed):
   - **Bennett-vpch** U45 — 190+ `error()` → typed exceptions.
   - **Bennett-zpj7** U160 — pebbling/eager file rename.
   - **Bennett-doh6** U158 — docs/make.jl absent.
   - **Bennett-qjet** P3 — empirical timing reorder.
   - **Bennett-mggz** U92 — ParsedIR._instructions_cache compat hack.

5. **3+1-protected real bugs still open** (unchanged): jepw, 25dm, 5qrn, zmw3, y986, 3of2, p94b. zmw3 bumped 14 sessions running.

---

## Session log — 2026-04-26 (late evening) — kcxv + op6a + b2fs closes (3 in one slot — duplicate close, docstring fix, tabulate Vector{Any} → Tuple)

**Shipped:** see `git log` `d18e0af..542bdcd` (4 commits). Three beads closed.

| Bead | What |
|---|---|
| **Bennett-kcxv** P3 / U86 | Closed as already-fixed-by **Bennett-cs2f / U42** (chunk 039 night, commit `142bcf1`). `_reset_names!()` was deleted from `src/ir_extract.jl` 2026-04-25; the 8 dead test-file callers were cleaned up subsequently in `c7d1144`. Verified via grep: zero hits today. |
| **Bennett-op6a** P3 / U140 (BUG) | Corrected `lower_add_cuccaro!` docstring in `src/adder.jl`. Old text advertised "2n Toffoli, 5n CNOT, 2n NOT" (the original Cuccaro 2004 paper's carry-out variant) but the implementation is the mod-2^W carry-suppressed variant: `2W − 2 Toffoli, 4W − 2 CNOT, 0 NOT, total 6W − 4`. Measured across W ∈ {2, 3, 4, 8, 16, 32, 64}: every formula holds exactly. New `test_op6a_cuccaro_gate_count.jl` (30 asserts) pins the formulas. |
| **Bennett-b2fs** P3 / U148 | Replaced `Any[]` in `src/tabulate.jl _unpack_args` with `ntuple(n) do k ... end`. Old form was a per-row heap allocation + boxed elements; downstream `f(args...)` splat was type-unstable. New form returns a `Tuple` (stack-allocated, concretely-typed once Julia specialises). Hot-path called once per row of a 2^N-entry lookup table — for 24-bit input spaces that's 16M rows. End-to-end: tabulate i8 xor 1 (2556 gates) + tabulate (i8, i8) + (655356 gates) both verify. New `test_b2fs_tabulate_tuple_unpack.jl` (22 asserts) pins the Tuple return + heterogeneous (Int8, UInt16) per-element typing + end-to-end correctness + static `Any[]` regression guard. |

**Why:** continuation of catalogue grind. kcxv was a 30-second triage close (already fixed). op6a was a doc-correctness fix with a regression-test anchor. b2fs was the substantive perf fix — Vector{Any} on a 16M-row hot path is exactly the kind of Julia-idiom violation that compounds at scale.

**Gotchas / Lessons:**

- **Triple-close in one "slot" works when one is dispatch-only.** kcxv was a "verify already-fixed → close-as-duplicate" 30-second triage. Then op6a + b2fs filled the easy + serious slots. Triage should be the first move on every bead pickup: `grep -rn <symbol>` to confirm the current state matches the bead's RED evidence. Saves time vs starting an investigation that's mooted.

- **Docstring gate-count drift is a real failure mode.** op6a's docstring claimed `2n/5n/2n` but the implementation emits `2W-2/4W-2/0`. Pre-fix, no test asserted either; the formula was just narrative. Fix pattern: any docstring claiming a specific gate count for a specific algorithm should pair with a regression-anchor test pinning the actual measurements at canonical widths. Worth applying the same to other adder/multiplier docstrings whose cost formulas are stated but not pinned.

- **`ntuple(n)` with a runtime n is `Tuple{Vararg{Any}}` BUT downstream specialisation often handles it correctly.** Julia's compiler specialises `f(args...)` on the concrete tuple type at the call site, so even a "vararg" return type often gets the right code path. Verified by the b2fs end-to-end correctness tests — the i8 + (i8,i8) tabulate baselines hold to gate count exactly. For a true compile-time-fixed-N use case `ntuple(f, Val(n))` is a stronger guarantee but requires N to be known at compile time.

- **Static-inspection regression guard for `Any[]` was a one-line test.** `@test !occursin("Any[]", read(path, String))`. Catches the most common reintroduction pattern. The earlier regression I had (`Vector{Any}` matching the new docstring's literal phrase) was a useful reminder to scan only for code-construction patterns, not phrase mentions.

- **Bennett.jl's test count crossed 73k this session.** 72995/72998 (3 intentional broken). Started the day at ~72400 ish; +595 over the day's 25-bead grind. Most growth is from per-bead invariant tests rather than feature tests — the static-inspection pattern is paying off.

**Rejected alternatives:**

- **Replace `tabulate.jl`'s entire architecture per the second half of the b2fs bead** ("fold tabulate.jl into a PRD or delete it"). Out of scope for the perf fix; the structural decision is for a future PRD review session, not a hot-path bead.

- **Use `MArray`/`SVector` for `_unpack_args`'s return.** StaticArrays adds a heavyweight dep for a stack-allocated container; native `Tuple` does the same job with no new deps. Rejected on that basis.

- **Keep the carry-out variant of Cuccaro and add a NOT-emission step** to match the original docstring's claim of "2n NOT". Tempting because it matches the paper, but the current mod-2^W form is what `lower_add!` and friends consume — a carry-out wire would need extra plumbing and would likely break callers expecting the b array overwrite. Doc-fix-to-match-implementation is the right call; the impl is correct.

**Next agent starts here:**

1. **Branch state at session-end**: `542bdcd` on main, pushed. Worklog top is **this** entry; chunk 043 is now ~210 lines. Approaching the 280 cap — next session may want to start `worklog/044_*.md`.

2. **Catalogue progress this session (3 closes)**: ~129 → ~126 ready remaining. Cumulative for the day's grind = 27 closes. Test count growth: +605 new assertions across 17 new test files. Pkg.test count: 72995/72998 (3 broken).

3. **Quick wins still on the menu** (each ~30-90 min, no 3+1 needed):
   - **Bennett-vpch** U45 — 190+ `error()` → typed exceptions (substantial; needs taxonomy).
   - **Bennett-zpj7** U160 — pebbling/eager file rename.
   - **Bennett-doh6** U158 — docs/make.jl absent.
   - **Bennett-qjet** P3 — empirical timing reorder.
   - **Bennett-9c4o** U89 — lower.jl forward-refs 6 modules included after it (structural).
   - **Bennett-mggz** U92 — ParsedIR._instructions_cache compat hack.
   - **Bennett-ardf** U138 — soft_fdiv dead binding + soft_floor/soft_ceil NaN coverage.

4. **3+1-protected real bugs still open** (unchanged): jepw, 25dm, 5qrn, zmw3, y986, 3of2, p94b. zmw3 bumped 13 sessions running.

5. **The triage-first pattern (kcxv this session) is reusable.** Many catalogue beads were filed against a pre-fix snapshot; a quick `grep` against current src/ often resolves them in 30 seconds. Procedure: for any bead whose Sites: list a specific symbol or line range, grep for that symbol BEFORE starting investigation. If gone, close-as-fixed-by with the resolving-bead reference.

---

## Session log — 2026-04-26 (evening) — g0jb + 5kio closes (asw2 flake fix + sizehint! arithmetic preallocation)

**Shipped:** see `git log` `499d4b9..9ecf6f7` (4 commits). Two beads closed.

| Bead | What |
|---|---|
| **Bennett-g0jb** P3 (BUG, NEW from chunk-042) | Bumped `n_tests=4` → `n_tests=20` in `test_asw2_verify_reversibility.jl:76` (T6 ControlledCircuit dirty-ancilla testset). The dirty-ancilla violation only fires when `verify_reversibility`'s randomly-chosen ctrl bit is 1; with 4 trials and `ctrl ~ Bernoulli(0.5)`, P(all four pick ctrl=0) = 6.25%. n_tests=20 brings P(flake) to ~10⁻⁶. Comment block records the rationale + the chunk-042 incident reference. Zero behavioural change. |
| **Bennett-5kio** P3 / U109 | Added `sizehint!(gates, length(gates) + bound)` preallocations to the predictable-final-size push! loops in `src/adder.jl` (lower_add!, lower_add_cuccaro!, lower_sub!), `src/multiplier.jl` (lower_mul_wide!), and `src/qcla.jl` (lower_add_qcla!). Each upper bound is O(W) or O(W²) per the cost formulas. Avoids the O(log₂N) intermediate-vector reallocations Julia would otherwise trigger on multi-thousand-gate paths. Karatsuba left untouched (vestigial per Bennett-tbm6); ir_extract.jl + lower.jl deferred — their per-iteration gate counts are less predictable. New `test_5kio_sizehint_arithmetic.jl` (15 asserts) statically verifies the hints are present + pins canonical gate counts (i8/i16/i32/i64 = 58/114/226/450, i32 mul = 6860/2856 Toff). Pure perf hygiene — zero behavioural change. |

**Why:** continuation of catalogue grind. g0jb was the obvious one-line fix for the flake I caught last session — defusing in-flight noise before another contributor hits it. 5kio was the substantive perf hygiene: every Int32+ compile pushes thousands of gates through tight inner loops, and Julia's default Vector growth pattern was forcing log₂N reallocations per pipeline pass. The cost formulas already documented in the QCLA / Cuccaro / ripple docstrings make the upper bounds easy.

**Gotchas / Lessons:**

- **The 1 grep hit on "errored" in the Pkg.test output was a false positive.** Looked alarming after the run; turned out to be the literal string "Skipped (extract errored): 1" in a benchmark info line. Tests passed (`Bennett | 72943 pass / 3 broken / 72946 total`). *Pattern*: when verifying Pkg.test results, prefer `tail -3` for the actual pass/fail summary line over `grep -c` for failure substrings — info lines can contain failure-shaped tokens without indicating a real failure.

- **Test count grew from 72928 → 72943 (+15)** even though the asw2 T6 testset's n_tests grew 4 → 20. Each `verify_reversibility(cc; n_tests=N)` call internally runs N iterations but emits ONE `@test_throws` assertion, so the test count change is just the +15 from `test_5kio_sizehint_arithmetic.jl`. The asw2 bump's overhead is invisible at the count level (still 8 asserts in that testset).

- **`sizehint!(gates, length(gates) + bound)` is the additive form.** Native `sizehint!(v, n)` ensures a TOTAL capacity of n, not n more. So if `gates` already holds 1000 gates from a prior `lower_add_qcla!` call (e.g. inside `parallel_adder_tree.jl`), `sizehint!(gates, 9*W)` would actually SHRINK the capacity. Used `length(gates) + bound` everywhere to grow relative to current size. Verified via the test that gate counts match the canonical baselines exactly.

- **Cost formulas already lived in the docstrings** — qcla.jl §"Cost formulas" lists Toffoli/CNOT/ancilla/depth as exact functions of W. Adder.jl Cuccaro docstring lists 2n Toff + 5n CNOT + 2n NOT + 1 ancilla. The sizehint! upper bounds are conservative round-ups of these — 5W for ripple (actual 5W-2), 6W for Cuccaro (actual ~6W-4), 9W for QCLA (actual ~5W+3W = 8W-1). Future agents adding similar arithmetic primitives should both document the cost formula AND interpolate it into the sizehint!.

- **Karatsuba's docstring contains the same kind of cost formula** (Θ(W^log₂3) Toffolis) but its "vestigial" status (k:s ratio still above 1 at every supported W per Bennett-sg0w / tbm6) made adding sizehint! low-priority. If tbm6 ever salvages Karatsuba, the obvious follow-up is the same pattern there.

- **The static-inspection test pattern was the right shape AGAIN.** Five sessions running where a per-file-property invariant test (uinn, f6qa, srsy, wlf6, now 5kio) is the right regression mechanism. Cheap to write (~30 LOC each), no runtime cost beyond reading source files once, catches regressions that no other mechanism would.

**Rejected alternatives:**

- **`empty!(gates); sizehint!(gates, total)` at function entry** to drop pre-existing contents. Would have been wrong — these functions APPEND to an existing gate stream that contains the prior pipeline's gates. The call signature is `lower_*!(gates, ...)` precisely so the caller threads ONE gates Vector through every step.

- **Adding sizehint! inside `_karatsuba_wide!`.** See "vestigial" point above. Filed conceptually as part of tbm6's salvage-or-remove decision; not worth a separate bead.

- **A benchmark to MEASURE the perf delta.** sizehint! is well-understood Julia perf hygiene; there's no doubt it's a strict improvement on growth paths that would otherwise call `_growend!`. No benchmark would change the decision to apply it. The new test pins behavioural equivalence (gate counts) + presence of the hint, which is the meaningful regression surface.

**Next agent starts here:**

1. **Branch state at session-end**: `9ecf6f7` on main, pushed. Worklog top is **this** entry; chunk 043 is now ~150 lines (was ~80 pre-this-session).

2. **Catalogue progress this session (2 closes)**: ~131 → ~129 ready remaining. Cumulative for the day's grind = 24 closes (6t8s, ej4n, 348q, tfo8, 2jny, kmuj, uzic, uinn, 069e, k7al, pksz, zyjn, 8kno, zy4u, d1ee, f6qa, 5ttt, srsy, hjbf, 8p0g, wlf6, 6u9q, g0jb, 5kio). Test count growth: +553 new assertions across 15 new test files. Total Pkg.test count is now 72943 / 72946 (3 intentional broken).

3. **Quick wins still on the menu** (each ~30-90 min, no 3+1 needed):
   - **Bennett-vpch** U45 — 190+ `error()` → typed exceptions (substantial; needs taxonomy first).
   - **Bennett-59jj** U47 — type instability in hot paths (P2; some sub-tasks need 3+1, others don't).
   - **Bennett-zpj7** U160 — pebbling/eager file rename.
   - **Bennett-doh6** U158 — docs/make.jl absent. Pairs with the wlf6 jldoctest fences.
   - **Bennett-qjet** P3 — zy4u-followup, empirical timing-based reorder.

4. **3+1-protected real bugs still open** (unchanged): jepw, 25dm, 5qrn, zmw3, y986, 3of2, p94b. zmw3 bumped 12 sessions running.

5. **The sizehint! pattern is now established for arithmetic kernels.** ir_extract.jl + lower.jl push! sites are the natural follow-ups once a measurement justifies them. The bound calculation requires per-LLVM-instruction gate-count estimates which are less stable than the closed-form arithmetic formulas, so probably wants a benchmark before commit.

---

## Session log — 2026-04-26 (late afternoon) — wlf6 + 6u9q closes (jldoctest fences + quantum vision integration test)

**Shipped:** see `git log` `4a87e03..b8db45d` (5 commits). Two beads closed, one new flake-followup bead filed.

| Bead | What |
|---|---|
| **Bennett-wlf6** P3 / U145 | Converted four `julia>`-style example blocks across the public-API docstrings from plain ```julia fences to ```jldoctest fences (with `setup = :(using Bennett)`): `src/Bennett.jl reversible_compile` (NEW example), `src/simulator.jl simulate`, `src/diagnostics.jl gate_count + depth/toffoli_depth + print_circuit`, `src/controlled.jl controlled + simulate(::ControlledCircuit)`. Caught + fixed a stale `Peak live: 17` → `Peak live: 4` in the print_circuit docstring (peak_live_wires for the canonical i8 x+1 baseline is 4, was outdated). New `test_wlf6_jldoctest_fences.jl` (18 asserts) statically pins the fences + smoke-checks every doctest's expected value against the canonical baseline. Once Bennett-doh6 wires Documenter.jl, every block becomes an executable doctest. |
| **Bennett-6u9q** P3 / U146 | New `test_6u9q_quantum_vision_integration.jl` (21 asserts) demonstrates the Sturm.jl `when(qubit) do f(x) end` vision end-to-end: compiles `x → !x` (Bool, `bit_width=1`), wraps via `controlled()`, treats the resulting 8-wire circuit as a 2^8 = 256 unitary on a `Vector{ComplexF64}`. Three coverage axes: (1) basis-state behaviour matches classical `simulate(cc, ctrl, x)` — for every (ctrl, x) the unique non-zero amplitude is `1.0 + 0im` at the predicted index AND the read-out output bit equals the classical result; (2) random complex superposition has norm preserved to atol 1e-10 (unitarity beyond basis states); (3) the canonical superposition `(1/√2)(|ctrl=0,x=0,0⟩ + |ctrl=1,x=0,0⟩)` produces the entangled `(1/√2)(|0,0,0⟩ + |1,0,1⟩)` exactly. Gate application is via permutation of basis-state indices (NOT/CNOT/Toffoli are each permutation matrices) so no dense 256×256 matrix is materialised. Avoided LinearAlgebra stdlib (not in test extras) by inlining a 5-line `_norm2` helper. |

**Why:** continuation of catalogue grind. wlf6 was a doc-snack that sets up Documenter doctest pickup once doh6 lands. 6u9q was the substantive add — the only test in the suite that exercises the *vision* end-to-end (controlled∘compile on a small statevector). Both are infrastructure-shaped: wlf6 is regression-resistant via the new static-inspection test; 6u9q is fast-running (~7s) and pins the unitarity invariant against any future changes to `controlled()` or the gate-emission path.

**Gotchas / Lessons:**

- **Pre-existing flake at test_asw2_verify_reversibility.jl:76 (~6.25% miss rate) tripped once.** The T6 testset constructs a 3-wire circuit with an ancilla-violation gate, wraps via `controlled()`, then expects `verify_reversibility(cc; n_tests=4)` to throw. The violation only fires when the random ctrl bit is 1 in any of the 4 trials; with `(1/2)^4 = 6.25%` probability all four are 0 and the test passes silently with no error → `@test_throws` fails. Filed a follow-up bead recommending `n_tests=20` (drops failure to ~10^-6) OR an explicit seed. NOT a regression from this session — confirmed by isolation runs.

- **`LinearAlgebra` is NOT in the project's `[extras]` test target.** First version of `test_6u9q` used `using LinearAlgebra: norm`; full Pkg.test errored with `Package LinearAlgebra not found in current path`. The standalone `julia --project -e 'using Test, Bennett, Random, LinearAlgebra; ...'` form worked because Random and LinearAlgebra were on the user-shell load path, but Pkg.test's isolated env only has the test deps. Inlined a 5-line `_norm2(v) = sqrt(sum(abs2, v))` helper. *Pattern for future*: if a new test wants stdlib not yet in extras, either add it to Project.toml `[extras]` + `targets.test`, or inline the small helper. Adding stdlib to extras is one line but adds a Manifest-touching commit; inlining is preferable for tiny one-off uses.

- **The 2^N statevector pattern is gate-emission-pattern reusable.** `_apply_gate_to_statevector!` indexes into `Vector{ComplexF64}` of length `2^N` and permutes amplitudes by bit-fiddling the basis-state index (NOT flips one bit, CNOT conditionally flips, Toffoli double-conditionally flips). No dense 256×256 matrix needed. Future agents writing similar quantum-flavoured tests: this same helper drops in unchanged for any 2^N statevector simulation up to N≈15 or so (after which 2^N memory dominates).

- **`Peak live: 17` → `Peak live: 4` was a stale doc claim.** print_circuit's docstring had `Peak live: 17` for the canonical i8 x+1 example. Actual value is 4 (verified). The number is well-known from earlier worklog entries (chunk 040 said `peak_live_wires=4` repeatedly). The docstring just hadn't been refreshed when the simulator's peak-live computation was tightened. *Procedure*: any doctest conversion should `julia --project -e ...` the example first to verify the literal expected output, then convert the fence.

- **The `bit_width=1` kwarg gives ridiculously cheaper circuits for Bool functions.** Default `bit_width=0` (infer-from-types) on `Bool` produced a 49-wire circuit; `bit_width=1` collapsed it to 7 wires (8 post-controlled). 256× smaller statevector. *Pattern*: when writing tests that need tractable wire counts, always pass `bit_width=1` explicitly for Bool inputs.

**Rejected alternatives:**

- **Adding `LinearAlgebra` to Project.toml `[extras]` + `targets.test`.** Touches Manifest.toml, increases test boilerplate. The `_norm2` inline is 5 lines and self-contained — no externalised dep just for `sqrt(sum(abs2, v))`.

- **A larger (Int8) function for 6u9q.** `f(x::Int8) = x + Int8(1)` is the canonical baseline but produces a 41-wire circuit → 2^41 amplitudes is `~17TB`. Even Int4 (if possible via narrow bit_width) would be 2^16 = 65k entries × 16 bytes/complex = 1MB which is tractable but cubed for matrix-matrix ops. Bool with `bit_width=1` is the sweet spot for an integration test.

- **Statevector simulation of the FULL i8 x+1 circuit** to test "scaling". Out of scope for U146 which asks for a *small* test demonstrating the vision. The bigger circuits already have classical-simulator coverage; the unitarity-on-superposition property is the new bit and only needs a small example to prove.

- **Wiring Documenter.jl into Pkg.test for wlf6** so the jldoctest blocks actually execute. Out of scope per CLAUDE.md §14 (which forbids GitHub CI but is silent on local doctest runners). The right move is Bennett-doh6 (docs/make.jl) which puts Documenter on the project's test surface; gated on a separate bead.

**Next agent starts here:**

1. **Branch state at session-end**: `b8db45d` on main, pushed. Worklog top is **this** file (`worklog/043_*.md`, ~150 lines pre-this-line + this entry). Chunk 042 stayed at ~270 lines.

2. **Catalogue progress this session (2 closes + 1 new flake bead)**: ~134 → ~131 ready remaining. Cumulative for the day's grind = 22 closes (6t8s, ej4n, 348q, tfo8, 2jny, kmuj, uzic, uinn, 069e, k7al, pksz, zyjn, 8kno, zy4u, d1ee, f6qa, 5ttt, srsy, hjbf, 8p0g, wlf6, 6u9q). Test count growth: +538 new assertions across 14 new test files. Total Pkg.test count is now 72928 / 72931 (3 intentional broken).

3. **Quick wins still on the menu** (each ~30-90 min, no 3+1 needed):
   - **Bennett-vpch** U45 — 190+ `error()` → typed exceptions (substantial; needs taxonomy first).
   - **Bennett-59jj** U47 — type instability in hot paths.
   - **Bennett-zpj7** U160 — pebbling/eager file rename.
   - **Bennett-5kio** U109 — sizehint! across 142+69 push! sites.
   - **Bennett-doh6** U158 — docs/make.jl absent. Pairs with the wlf6 jldoctest fences (would unlock executable doctests).
   - **Bennett-qjet** P3 — zy4u-followup, empirical timing-based reorder.
   - The new flake bead from this session.

4. **3+1-protected real bugs still open** (unchanged): jepw, 25dm, 5qrn, zmw3, y986, 3of2, p94b. zmw3 bumped 11 sessions running.

5. **The basis-state-permutation pattern from 6u9q is reusable** for any quantum-flavoured test. The `_apply_gate_to_statevector!` helper bit-fiddles indices instead of materialising matrices, so it scales to N≈15 wires before memory dominates. Worth recording as a template for any future "this circuit must be unitary" test that lands.

6. **`bit_width=1` is the canonical small-circuit knob.** When you need a tractable circuit for a quantum-flavoured test, compile a Bool function with `bit_width=1`. Default infer-from-Bool gives 49 wires; explicit `bit_width=1` gives 7. Documented in this chunk's "Lessons" section.
