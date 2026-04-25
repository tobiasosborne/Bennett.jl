# Bennett.jl Work Log

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
