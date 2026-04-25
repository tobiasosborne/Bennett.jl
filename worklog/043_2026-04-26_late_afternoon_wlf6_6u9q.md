# Bennett.jl Work Log

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
