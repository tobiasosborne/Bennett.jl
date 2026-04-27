# Bennett.jl Work Log

## Session log — 2026-04-27 (evening) — Bennett-heup / U127 close (_fold_constants — investigated, doc-only)

**Shipped:** see git log around the next commit; expanded `_fold_constants` docstring (src/lower.jl:577-602) + new contract test `test/test_heup_fold_constants_contract.jl` (539 assertions / 4 testsets) registered in runtests.jl.

**Why:** Bennett-heup / U127 — review #12 torvalds B10 + #13 carmack F8 flagged "_fold_constants mixes three concerns; 93-line pass off-by-default" with no benchmarks and no tests.

**Mode:** direct grind, "investigated, doc-only" disposition (chunk 045 / 046 pattern, cf. 2yky / 3of2 / xiqt / y56a / yys3).

**Investigation finding — both load-bearing claims are stale:**

1. **"Off-by-default"** — already false. Bennett-epwy / U28 (commit a9dc115, 2026-04-24) flipped the default to `true` at `src/lower.jl:375` and at every `reversible_compile` entry point in `src/Bennett.jl` (lines 152, 230, 444). The flip-commit ships exhaustive correctness + the gate-count win documented in commit message. The chunk-045 calibration ("bead-claim numbers go stale") is in force here.

2. **"Mixes three concerns"** — empirically a single concern (constant propagation through reversible gates) with three operator-dispatch cases (NOTGate / CNOTGate / ToffoliGate). The function tracks ONE piece of state, `known::Dict{Int,Bool}`, and mutates it per gate. Splitting the dispatch would not separate concerns; it would duplicate the state-update logic three times. Per CLAUDE.md §12 (no duplicated lowering), keeping the single-pass shape is the right call.

3. **"No benchmark"** — also false. The U28 commit message documents `polynomial 872 → 562 (35% ↓)` and `x*x Toffoli 296 → 144`. Pre-existing tests `test/test_constant_fold.jl` + `test/test_epwy_fold_constants_default.jl` pin the default-true contract and the polynomial reduction.

**Live empirical baselines (post-5qrn peephole, measured 2026-04-27):**

| Function | off | on | Reduction |
|---|---:|---:|---|
| polynomial total | 848 | 482 | 43% |
| polynomial Toffoli | 352 | 168 | 52% |
| x*x total | 690 | 380 | 45% |
| x*x Toffoli | 296 | 144 | 51% |
| x*x depth | 97 | 89 | 8% |
| x*3 ratio | 343 | 106 | 3.24× |
| x+3 | 41 | 28 | 32% |

The 5qrn / U57 peephole pass (independent layer) further amplified the U28 wins since the bead was filed.

**Test coverage:** `test/test_heup_fold_constants_contract.jl` — 539 assertions / 4 testsets:

- **Default-true at every entry point** — `lower()` no-kwarg = explicit-on; `reversible_compile(f, Int8)` exhaustive correctness over Int8.
- **Per-gate-type dispatch witnesses** — hand-built `LoweringResult`s exercise each of 5 dispatch arms: NOTGate flip+materialize, CNOTGate constant-true control collapse, CNOTGate data-control pass-through, ToffoliGate one-known-false noop, ToffoliGate one-true+one-unknown CNOT reduction. Pins all dispatch arms reachable + behaving as documented.
- **Self_reversing short-circuit** — pointer-equality contract test (per Bennett-egu6 / U03): a self_reversing input returns `=== lr_sr` without any folding.
- **Empirical reduction baselines** — polynomial 482 ± 5%, Toffoli 168 ± 12, x*3 ratio ≥ 3×; exhaustive correctness over Int8.

**Adjacent docstring update:** `_fold_constants` docstring (src/lower.jl:577-602) now documents the dispatch arms, cites Bennett-heup / U127 + Bennett-epwy / U28 + Bennett-5qrn / U57, and pins the live baselines.

**Gotchas / Lessons:**

1. **Stale-bead disposition is the right pattern when the review was correct AT FILING TIME but the underlying defect has been independently fixed.** Bennett-heup was filed 2026-04-22; Bennett-epwy / U28 landed 2026-04-24 (2 days later). Without empirical verification I would have spent the session "splitting" a function whose flagship complaint had already been resolved. The chunk-045 directive's MEASURE-FIRST step (#3) catches this class of bead before any design work.

2. **Two reviewers describing the same surface in different language can both be stale.** Torvalds called it "second-pass peephole optimizer written by someone who felt like writing one"; Carmack called it "mixes three concerns, 93-line pass off-by-default". Both claims rest on the SAME premise (`fold_constants=false` default + no benchmarks) — and both are now equally stale post-U28.

3. **Hand-built `LoweringResult`s are the right tool for testing dispatch arms.** Each arm of `_fold_constants` has a specific pre-state in `known` that's easy to set up by choosing input_wires + initial gate sequence. Same pattern as Bennett-y986's hand-built `ParsedIR` for testing loop-internal dispatch (chunk 046).

4. **`gate_count(c).Toffoli` (capital T)** — the NamedTuple field is `Toffoli`, not `toffoli`. First measurement attempt errored on `getproperty`; field-name capitalization matters.

**Rejected alternatives:**

- **Split `_fold_constants` into 3 functions** (one per gate type) — would duplicate the `known::Dict{Int,Bool}` state-update logic three times AND require a new outer-loop driver. Net LOC increase, no clarity win, no behavior change. CLAUDE.md §12 (no duplicated lowering) prefers the single-pass shape.
- **Delete `_fold_constants` entirely** (torvalds B10 final option: "make it default, document the benefit, and test the counts — or delete it") — discarded; the empirical wins (43-52% reduction on representative workloads) are load-bearing for the gate-count regression baselines pinned in `test_gate_count_regression.jl`. Deletion would shift every pinned baseline.
- **Add `error("not implemented")` for unsupported gate types in dispatch** — the existing dispatch silently passes ToffoliGate-with-extractvalue / vector-typed gates through unchanged. CLAUDE.md §1 fail-loud would prefer an explicit error, but the pass operates on `ReversibleGate` which only has 3 concrete subtypes (NOTGate / CNOTGate / ToffoliGate). No fail-loud needed unless a 4th gate type is added.

**Filed (follow-ups):** none. Per the bugs-only directive, no follow-up beads.

**Test count:** 83,787 → **84,326** (+539, exact match).

**Bd-tracked snapshot (post-heup close):**

```
bd ready -n 200 | grep '\[bug\]' → 4 open [bug] beads (down from 5).
- P2: 25dm (blocked on z2dj IN-PROGRESS), ponm (bd-infra not Bennett.jl).
- P3: q04a, jc0y (both 3+1 refactors, yesterday's filings).
- IN-PROGRESS: cc0.5 (P2 bug — Julia TLS allocator GEP base, T5-P6.3).
```

**Next agent — start here:** Continue bugs-only. Of the 3 remaining actionable beads (excluding 25dm blocked + ponm bd-infra + cc0.5 in-progress), only `q04a` and `jc0y` remain — both 3+1 refactors of yesterday's `59jj` cuts:

- **`q04a`** — split `_convert_instruction` 17-arm Union return into `_single` + `_expand!`. Touches `src/ir_extract.jl`. Per CLAUDE.md §2: 3+1 protocol required.
- **`jc0y`** — `ReversibleCircuit.gates` storage layout (abstract `Vector{ReversibleGate}` boxes pointers, ~56 MB on 1.4M gates). Touches `src/gates.jl`. Per CLAUDE.md §2: 3+1 protocol required.

Both have measurable empirical baselines (memory pressure, allocation counts). Pickup order: `jc0y` first (smaller blast radius — the storage layout is one struct field; the change is contained), then `q04a` (touches the extractor's hot dispatch path; needs careful baseline measurement).

After both 3+1s land, the [bug] backlog is exhausted (excluding bd-infra `ponm` and cross-team-blocked `25dm`).

### Branch state at session-end

`main @ <next commit>`, pushed and up to date with `origin/main`. Worklog: chunk 047 starts here (chunk 046 hit 508 lines after the yys3 entry, well past the ~280 cap).

---
