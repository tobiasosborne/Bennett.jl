# Verification — B-tests-api (Astra 2026-09-26)

Verifier: independent re-execution, 2026-09-26. All probes were run with `julia --project --check-bounds=yes`.
Mutations were done **in-process only**: `@eval Bennett <redefinition>`, or `Base.include_string`/AST rewrite of the test text.
No file under `src/` or `test/` was modified. Probe scripts are in the session scratchpad (`v/api.jl`, `f9.jl`, `f14.jl`, `f15.jl`, `f20.jl`).
No `bd`, no commit, no full suite.

Severity rubric used: S1 = a test stays green when the implementation is broken, or a public-API crash on a documented input.
Where a per-file S1 is mitigated at suite level, the table says so.

## Summary table

| F# | Verdict | Severity ok? | Dedup | Note |
|---|---|---|---|---|
| F1 | CONFIRMED | S1 by rubric; keep P2 via existing bead | **Bennett-gygy** (open P2), exact match | `doctest = false` at make.jl:56; guard matches the comment on line 13; doh6 green |
| F4 | CONFIRMED — **bug**, not just docs | S1 ok (silent hidden-arg ABI) | NEW (40ys is closed-world walker; 4ddk covers callable-struct MethodError only) | capture becomes **input 1**: `x->x-k`, k=7 → widths [8,8]; `simulate(c,Int8,(10,7))` = -3 vs native 3 |
| F8 | CONFIRMED | S1→**S2** | NEW (exb3 distinct) | `lower(p)` == `lower(p;fold_constants=true)` gate-for-gate (28/28); unfolded = 41. 16 other test files do use `fold_constants=false`, so the unfolded path is covered at suite level |
| F9 | CONFIRMED | S1 ok | NEW | injected `error(...)` gives 17 pass / 1 broken / 0 fail; unmutated file is 38/38 today, so the catch is pure masking |
| F14 | CONFIRMED (stronger mutation) | S1 by rubric, practically S2 | **Bennett-z3j3** (open P2, astra) already names the vacuous avalanche test; annotate, no new bead | identity `emit_feistel!` passes 21/21; output(0x12345678) = 305419896 = input |
| F15 | CONFIRMED | S1 ok (fallback path only) | NEW test bead; related **Bennett-9tg3** (open P3, producer side) | original testset 9/9 (both members present today); empty-set mutant 2/2 |
| F18 | CONFIRMED | S1 ok | **Bennett-0a6f** (open P2) = implementation; annotate 0a6f with the test gap rather than a separate bead | Float64 mul, default vs `target=:depth`: identical gate vectors, 149456 gates. Int32 does differ (6860 vs 52984) |
| F19 | CONFIRMED | S1 ok | NEW (or annotate **Bennett-vpgj**, open P3) | optimize=true: 1 block, 0 phis. (1,100) returns 100 with K=5. `add=:cuccaro` and `:ripple` both give 506 gates. With optimize=false: 4 blocks, 2 phis |
| F20 | CONFIRMED | S1 per file; suite-level S2 | NEW (**Bennett-7stg** closed; 6rqq distinct) | `_lookup_callee` throws, yet the file passes 2/2; nthreads = 1. A broken lookup would fail other files (soft-float callees), so the unique loss is concurrency coverage |
| F22 | CONFIRMED | S1 ok | **Same root cause as B-softfloat F4** (missing SoftFloat dispatch incl. fma); fold into that bead; yn08 distinct | `fma` on 3×Float64 → `VoidType reached _type_width`; there is no `Base.fma(::SoftFloat…)` in softfloat_dispatch.jl. README:231, floats.md:118, api.md:400 advertise fma |
| F5 | mapping confirmed | — | **Bennett-ukup** (open P2, astra) | not re-verified (fixed concurrently) |
| F6 | mapping confirmed | — | **Bennett-iwj6** (open P1, astra) | not re-verified |
| F7 | mapping confirmed | — | **Bennett-4ddk** (open P1, astra) = circuit-core F1 | not re-verified |
| F10 | mapping confirmed | — | **Bennett-iwj6** (title includes kwarg bypass) | not re-verified |
| F12 | mapping confirmed | — | **Bennett-qa2g** (open P1, astra) | not re-verified |
| F2 | CONFIRMED (executed) | S2 ok | NEW (uxyy closed; aggregate only) | `runtests.jl test_doh6… __no_such_test__` ran 1 file and exited 0 |
| F3 | CONFIRMED (executed) | S2 ok | NEW (gm83 and figa distinct) | `test/test_increment.jl` → `UndefVarError: @testset not defined in Main` |
| F11 | LOOKS RIGHT | S2 ok | NEW | README:25 `f` is `Int8`-only but :70-71 compile it at Int64. `collatz_steps` is undefined in README. Memory how-to line 118 passes `(Int8, Int8)` |
| F13 | CONFIRMED (executed) | S2 ok | NEW (srsy closed) | `BENNETT_CI=1` → 15 pass, 1 error "Expression evaluated to non-Boolean" at line 58 |
| F16 | LOOKS RIGHT | S2 ok | NEW (2xws is the defect, not the gating) | persistent.jl includes research/okasaki, hamt, cf unconditionally; their runtests entries sit behind `BENNETT_RESEARCH_TESTS` (default "0") |
| F17 | LOOKS RIGHT | S2 ok | NEW (systematic) | 8su4:41 uses `-8:8`; y986:162 uses `1:30`. Sample classification not re-audited |
| F21 | CONFIRMED (executed) | S2 ok | NEW | `g(x)=x*x+1.0`: `Tuple{Float64}` → `fmul … unsupported LLVM opcode`; vararg `Float64` compiles (209376 gates) |

## Per-finding details (S1)

### F1 — doctest guard (CONFIRMED)

- `test/test_doh6_docs_makejl.jl:23`: `@test occursin("doctest = true", src) || occursin("doctest=true", src)`.
- `docs/make.jl:13` is a comment ("…set doctest=true and validate the build"). `docs/make.jl:56` is `doctest = false,`.
- Ran `test/runtests.jl test_doh6_docs_makejl.jl __no_such_test__`: "ran 1 file(s), skipped 323", doh6 ✓, exit 0.
- Bennett-gygy (open, P2) describes exactly this. It is a duplicate; no new bead.
- The rubric makes this S1: every doctest can regress while the guard stays green. The bead's P2 is reasonable because the loss is documentation examples, not compiler output.

### F4 — captured closures (CONFIRMED; public-API bug)

- `mk(k)=x->x+k; f=mk(Int8(7)); c=reversible_compile(f,Int8)` gives `c.input_widths == [8, 8]`. The same holds with `optimize=false`.
- `simulate(c, Int8(5))` throws `requires single-input circuit, got 2 inputs`, so the unary path does fail loudly.
- **The captured field is prepended as argument 1.** Probe with `x->x-k`, k=7, where native `f(10) = 3`:
  - `simulate(c,Int8,(10,7))` = **-3**
  - `simulate(c,Int8,(7,10))` = 3
  - `simulate(c,Int8,(10,0))` = -10
- A Int16 capture gives widths `[16, 8]`. An unused capture is elided (widths `[8]`), so arity depends on the optimiser.
- A callable struct `Adder(k)` raises `MethodError: no method matching _extract_parsed_ir_cached(::Adder, …)`. That part is already in Bennett-4ddk (circuit-core F15).
- Verdict: this is a **bug**, not only a documentation gap. The returned circuit's arity and argument order contradict the requested `Tuple{Int8}`, and nothing warns. README:24 says "Any pure Julia function".
- Fix direction (reviewer's): bind captured immutable fields as constants, or reject non-singleton callables up front. This is a core extraction change and needs 3+1 under rule 2.
- No existing bead: Bennett-40ys (closed) is closed-world callee keys.

### F8 — constant-fold test compares folded against folded (CONFIRMED)

- `p=extract_parsed_ir(x->x+Int8(3),Tuple{Int8})`:
  - `lower(p).gates == lower(p;fold_constants=true).gates` → **true**, (28, 28).
  - Explicit `fold_constants=false` → 41 gates.
- The test's "standard" path is therefore the folded path. The `<=` assertion and the 256-input comparison are tautological.
- A mutation of the unfolded path cannot affect this testset. This is REASONED from the gate-vector identity; the unfolded path is never invoked there.
- Severity: 16 other test files pass `fold_constants=false`, so a broken unfolded lowering would not stay suite-green. Per-file S1, **S2 overall**.

### F9 — mixed-width catch-to-broken (CONFIRMED)

- Replaced `circuit = reversible_compile(widen_mul, Int8)` in memory with `error("injected compiler regression")` and ran via `include_string`.
- Result: **17 Pass, 1 Broken, 0 Fail**, with the warning "widen_mul skipped (unsupported IR) exception = injected compiler regression".
- The unmutated file passes **38/38** today, so `widen_mul` compiles. The try/catch now only masks regressions.
- S1 ok. New bead: remove the blanket catch and require all 256 inputs.

### F14 — Feistel identity survives the whole file (CONFIRMED)

- This mutation is stronger than the report's, which replaced the test helper. I redefined the **source primitive** `Bennett.emit_feistel!` in-process to:
  - return `key_wires` unchanged (the identity), and
  - emit `rounds` inert `ToffoliGate`s on 3 fresh zero wires.
- The unchanged `test/test_feistel.jl` passes **21/21**. `_compile_feistel(32)` maps 0x12345678 to **305419896**, which is the input.
- Every assertion is satisfied by the identity: bijection, determinism, `o1 != o3`, Toffoli ceilings, and monotone round counts (the dummy gates provide these).
- Dedup: **Bennett-z3j3** (open P2, astra, from B-arith) already states "avalanche test is vacuous". Annotate z3j3 with this whole-file mutation; do not file a new bead.
- The rubric gives S1. In practice it is S2: the primitive is bijective and ancilla-clean; only hash quality is unpinned.

### F15 — ABI pins go green on an empty set (CONFIRMED)

- AST-extracted the testset `natural pin: fdict_d1b recursive + consumed calls` from `test/test_416r17_sret_forward_cell_args.jl`.
  - Unmutated, with `--check-bounds=yes`: **9/9** pass. Both `ht_keyindex2_shorthash!` and `setindex!` are present, so the pin is live today.
  - With `extract_parsed_ir_set_from_julia(...)` replaced by `Pair{Symbol,ParsedIR}[]`: both "pin skipped" infos are printed and the result is **2/2 pass**.
- The same `@info …; @test true` fallback exists at `test_416r16_consumed_sret_reconcile.jl:252-254`.
- `test_land_ptrfield_struct.jl:268-282` has a similar fallback, but it is keyed on fixture/symbol absence. That is a weaker case.
- Dedup: Bennett-9tg3 (open P3) is the producer-side empty-set guard. It is related but does not fix the tests. File a new test bead, or add both to a 9tg3 annotation.

### F18 — Float64 target propagation test (CONFIRMED)

- `(x,y)->x*y` compiled at `Float64, Float64`, default vs `target=:depth`: both give `(total=149456, NOT=11852, CNOT=98720, Toffoli=38884)`, and `d1.gates == d2.gates` is **true**.
- `test_4fri_mul_target.jl:75` asserts only `isa ReversibleCircuit`.
- Control: the Int32 compile does differ (6860 vs 52984 gates), so `target` works for native integers.
- Dedup: the implementation defect is **Bennett-0a6f** (open P2), whose description names this exact `target=:depth` soft-float case. Annotate 0a6f so its fix includes strengthening this assertion.

### F19 — y986 Cuccaro guard has no loop (CONFIRMED)

- `extract_parsed_ir(_y986_acc, Tuple{Int8,Int8})` (optimize=true, as the test uses) gives **1 block, 0 IRPhi**.
- With K=5, `simulate` on (1,5), (1,6), (1,100) returns **[5, 6, 100]**. K is irrelevant because LLVM closed-formed the loop.
- With `add=:cuccaro` and `add=:ripple` the total is 506 for both, so the kwarg has no observable effect on this fixture.
- With `optimize=false`: 4 blocks, 2 phis. The fix suggested in the report is viable.
- S1 ok. File a new small test bead, or annotate Bennett-vpgj (which tracks the loop add override).

### F20 — register_callee! locking test tolerates broken lookup (CONFIRMED)

- Ran `@eval Bennett _lookup_callee(s::String) = error("injected lookup failure")`. A direct call throws.
- `Threads.nthreads()` = 1.
- The unchanged `test_7stg_register_callee_locking.jl` then passes **2/2**. The fixtures (`xor`, `+`, `>>`, `*`) produce no `IRCall`, so lookup is never reached.
- Suite-level mitigation: soft-float, division and memory tests go through `_lookup_callee`, so a broken lookup would not leave the suite green.
- The unique gap is that the file's stated purpose (concurrent register/lookup safety) is never exercised: there is 1 thread and no callee.
- Per-file S1 ok; suite-level S2. Bennett-7stg is closed. New bead.

### F22 — Float64 fma (CONFIRMED)

- `h(a,b,c)=fma(a,b,c); reversible_compile(h,Float64,Float64,Float64)` fails with `ir_extract.jl: VoidType reached _type_width — caller is querying the width of a void value…`.
- `src/softfloat_dispatch.jl` has no `fma` method. Its only "fma" hits are `soft_fmaximum` and related names.
- fma is advertised as bit-exact at README:231, docs/src/tutorials/floats.md:118, and docs/src/reference/api.md:400.
- Relation to B-softfloat (`B-softfloat.verification.md`):
  - **softfloat F4** (CONFIRMED S1): `x->fma(x,x,x)` and missing SoftFloat methods for `^`, mixed `<`, `isnan`, `isfinite`, `min`. That is the **same root cause**, and F22 is a strict subset.
  - **softfloat F7** (non-SoftFloat returns → `.bits` applied unconditionally): a different root cause. It shares the same misleading VoidType diagnostic, which both findings recommend replacing with an early check.
- Recommendation: do not file separately. Add the documented-API angle (README/tutorial/api.md claims) and the 3-arg `fma(a,b,c)` probe to the softfloat-F4 bead under `astra-2026-09-26`.
- Bennett-yn08 (host `have_fma`) is distinct.
- S1 ok: a public-API crash on a documented input.

## S2 skim (one line each)

- **F2** — CONFIRMED by execution. `_FILE_FILTERS` is ORed (`any(...)`) and the epilogue only errors when `_RAN_FILES[] == 0`; dash-prefixed args are dropped at line 22.
- **F3** — CONFIRMED by execution. `test/test_increment.jl` has no `using Test`, which contradicts CLAUDE.md's "Run a single test file" command.
- **F11** — Looks right from the docs:
  - README:25 `f(x::Int8)` vs `reversible_compile(f, Int64)` at :70-71.
  - `collatz_steps` appears only at README:74.
  - `reversible_memory.md:118` passes a value tuple `(Int8, Int8)`.
  - The tutorial `f` claim was not re-executed.
- **F13** — CONFIRMED by execution. `@test cond || @info(...)` evaluates to `nothing` when `BENNETT_CI=1`; 15 pass + 1 error.
- **F16** — Looks right. `persistent.jl:37,47,57` include the research okasaki/hamt/cf files unconditionally, while the runtests research block, gated at line ~1131, holds their regressions.
- **F17** — Looks right on the spot-checked lines (8su4:41 `-8:8`, y986:162 `1:30`). Note this is rule-3/4 policy drift, not a demonstrated miscompile.
- **F21** — CONFIRMED by execution (see probe below). The tuple form bypasses the SoftFloat wrapper and dies at extraction with an opaque opcode error instead of an up-front diagnostic.

## F21 probe

`g(x)=x*x+1.0`:
- `reversible_compile(g, Tuple{Float64})` vs
- `reversible_compile(g, Float64)`

Result:
- `Tuple{Float64}` → `ir_extract.jl: fmul in @julia_g_…: %0 = fmul double … — unsupported LLVM opcode`
- `Float64` → compiles, 209376 gates.

## Dedup notes

- Confirmed that every id the report cites exists in `.beads/issues.jsonl` with a matching title: gygy, z3j3, 9tg3, 0a6f, vpgj, 7stg(closed), 6rqq, iwj6, 4ddk, qa2g, ukup, yn08, exb3, uxyy(closed), gm83, figa, srsy(closed), 2xws, 40ys(closed).
- No other `*.triage.md` maps a tests-api finding. B-circuit-core F1/F15 → 4ddk overlaps F7 and the callable-struct half of F4.
- Suggested new beads: F4, F8, F9, F15, F19, F20, plus the S2 set (F2, F3, F11, F13, F16, F17, F21).
- Annotate rather than file: F1→gygy, F14→z3j3, F18→0a6f, F22→softfloat-F4 bead.
