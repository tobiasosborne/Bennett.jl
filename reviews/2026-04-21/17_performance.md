# Bennett.jl — Performance & Compilation-Cost Review

**Reviewer**: independent (perf/compile-cost)
**Date**: 2026-04-21
**Commit**: `7f7caff` (main, clean tree apart from beads dolt drift)
**Host**: Linux 6.6 WSL2, Julia from `--project=.`
**Principle**: reproduce everything live, trust nothing.

---

## 1. Measured baselines table (LIVE)

All numbers reproduced in fresh Julia processes with one Bennett warm-up call (`x+Int8(1)`) before timing. Post-warm `reversible_compile` is what a repeated user sees; first-call numbers would include ~12s of LLVM/Julia-JIT cost that is not Bennett's.

| Bench | WORKLOG/BENCHMARKS claim | **Reproduced** | Δ | Compile t (post-JIT) | Notes |
|---|---:|---:|---|---:|---|
| `x+Int8(1)` total gates | 100 | **100** | 0 | 68 ms | 28 Toffoli, 10 ancilla — matches |
| `x+Int16(1)` total | 204 | **204** | 0 | 160 ms | |
| `x+Int32(1)` total | 412 | **412** | 0 | 167 ms | |
| `x+Int64(1)` total | 828 | **828** | 0 | 175 ms | 2× per doubling holds |
| `x²+3x+1 Int8` | 872 | **872** | 0 | 1.58 s | |
| `x*y Int8×Int8` | 690 | **690** | 0 | 315 ms | |
| `x*y Int32×Int32` | 11,202 | **11,202** | 0 | 221 ms | |
| `_ls_demo` (persistent intf) | 436 / 90T | **436 / 90T** | 0 | n/a (test path) | |
| popcount32 standalone | 2,782 | **2,782** | 0 | n/a | |
| HAMT demo | 96,788 | **96,788** | 0 | n/a | |
| CF demo | 11,078 | **11,078** | 0 | n/a | |
| CF+Feistel | 65,198 | **65,198** | 0 | n/a | |
| TJ3 corpus | 180 | **180** | 0 | n/a | |
| `soft_fptrunc` | 36,474 | **36,474** | 0 | 5.38 s (incl. JIT) | |
| `soft_fadd` via `x+1.0` | 95,046 | **95,046** | 0 | 13.6 s (incl. JIT) | |
| `soft_fma` (UInt64³) | — | 447,728 / 148,340 T | — | 0.53 s | not in BENCHMARKS |
| i32 mul `qcla_tree` T-depth | 56 | **56** | 0 | — | README claim reproduces |
| i32 mul `shift_add` T-depth | 190 | **190** | 0 | — | |
| **Full test suite** (`Pkg.test()`) | README: "~90 s" | **3 min 56 s** | **+163 s (2.6×)** | — | **stale** |
| `using Bennett` cold | — | 1.0 s | — | — | no sysimage |
| 1st `reversible_compile` | — | 11.9 s | — | 901 MB alloc | 99.97% "compilation time" = Julia JIT |

**All gate-count baselines from WORKLOG/BENCHMARKS reproduce exactly.** The only drift is in doc claims: full test suite is 2.6× slower than README states, and the file-count claim ("~60 test files") is also stale (now ~100).

### Sub-phase compile cost (soft_fadd, i.e. the worst realistic case)

```
soft_fadd total compile breakdown (175 parsed IR insts → 94,768 gates):
  extract: 21.7 ms  alloc=1.82 MB
  lower:   319.7 ms alloc=3.51 MB
  bennett:  1.2 ms  alloc=1.63 MB
```

Lowering dominates at 320 ms / 3.5 MB. `bennett()` is cheap. `extract` is a lightweight walk.

### Straight-line compile-time scaling (N chained adds, `optimize=false`)

| N insts | gates | extract | lower | bennett | alloc |
|---:|---:|---:|---:|---:|---:|
| 2 | 790 | 0.48 ms | 6.2 ms (1st call warmup) | 0.01 ms | 0.03 MB |
| 8 | 3,068 | 0.78 ms | 0.10 ms | 0.02 ms | 0.12 MB |
| 16 | 6,116 | 0.92 ms | 0.13 ms | 0.04 ms | 0.19 MB |
| 32 | 12,228 | 1.56 ms | 0.20 ms | 0.06 ms | 0.38 MB |
| 64 | 24,484 | 2.43 ms | 0.34 ms | 0.09 ms | 0.78 MB |
| 128 | 49,060 | 4.49 ms | 0.58 ms | 0.17 ms | 1.54 MB |

Compile-time scales **linearly** in IR-instruction count — no quadratic blowup. 128→64 doubling raises each phase ~1.7–2.0× across the board. This is the good news.

### Simulator throughput

| Circuit | Gates | Sim time (μs) | Allocs/call |
|---|---:|---:|---:|
| `x+Int8(1)` (256 inputs) | 100 | 0.12 μs/input | 2 |
| soft_fadd | 94,768 | 160 μs | 3 (+ 2.73 MB over 100 calls → 27 KB/call) |

Simulator is good — 94k-gate circuit runs in 160μs despite iterating over `Vector{ReversibleGate}` (abstract eltype → dynamic dispatch per gate); the method-table sees only three concrete types so inline caches handle it.

---

## 2. Executive summary (15 bullets)

1. **All published gate-count baselines reproduce exactly** — no regression. WORKLOG and BENCHMARKS.md are trustworthy on numbers.
2. **README test-suite-time claim is 2.6× stale**: 3m56s measured vs 90s claimed. Test-file-count claim also stale (now ~100 not ~60).
3. **No CI** (`.github/` absent). Gate-count and compile-time regressions can and will land silently — only defence is local `Pkg.test()` before push, required by CLAUDE.md §6 but unenforced.
4. **No precompilation / PackageCompiler setup.** `using Bennett` cold is ~1.0s (fine); first `reversible_compile` call pays ~12s of Julia+LLVM JIT.
5. **No benchmark of compile time**, only gate count. A compile-time regression in `lower()` would go unnoticed until the persistent sweep at max_n=1000 (which takes 2 min). Add `@elapsed` columns to `run_benchmarks.jl`.
6. **BENCHMARKS.md is current** (timestamp 2026-04-21). Persistent sweep JSONL is one day old and matches the summary. Reproducibility is solid.
7. **`:auto` dispatcher for `add=` is sub-optimal on gate count for two-operand adds.** Measured i32 `x+y`: auto=410 / ripple=350 / qcla T-depth=24. Auto picks Cuccaro (worse total gate count and worse T-depth) when ripple would be strictly better. The docstring says auto optimises for "in-place safety"; it does not advertise that this sacrifices ~60 gates per add for no counteracting benefit when in-place isn't actually engaged.
8. **`:auto` for `mul=` never picks qcla_tree or karatsuba** at any width. README headline "QCLA tree 6× shallower at W=64" is reachable only by explicit `mul=:qcla_tree`. No width-based heuristic. For FTQC the default is the worst option.
9. **Trivial-identity peepholes missing in the lowerer.** `x+0 optimize=false` = 98 gates (no fold). `x*1 optimize=false` = 692 gates (partial fold to 156 only if `fold_constants=true`, which is **off by default**). Matters because the persistent sweep mandates `optimize=false`; all its benchmarks pay the no-peephole tax.
10. **`fold_constants=false` is the default of `lower()` — the one optimisation guaranteed to never pessimise anything, and it's opt-in.** Every test-run pays full cost. Enabling by default (or forcing on for `optimize=false`) would materially cut the 1.4M-gate linear_scan N=1000 number.
11. **Type-unstable hot-path field access.** `LoweringCtx.preds::Any`, `branch_info::Any`, `block_order::Any` (src/lower.jl:54-56). These are hit on every instruction dispatched through `_lower_inst!`. Concretising (even with a type parameter) would remove dynamic dispatch from the inner loop. Estimated 10-30% lowering speedup.
12. **`_convert_instruction` returns a 17-element `Union{...}`** in the extractor's hot loop (one `Vector` catch-all). Union-splitting handles the common cases but the `Vector` arm forces allocation. Could be split into scalar-return + `append!` variants.
13. **`Vector{ReversibleGate}` with abstract element type** — every gate is a boxed pointer, ~3× the memory of a packed representation. For 1.4M-gate persistent-sweep circuits this is ~40 MB of pointer overhead that would vanish with a tagged-union struct. Same cost applied during simulate iteration (per-gate dynamic dispatch, albeit with small concrete-set inline caching).
14. **No `sizehint!` in `lower.jl` / `ir_extract.jl` despite 142+69 `push!` calls.** The `gates::Vector{ReversibleGate}` grows by doubling over the whole compile. `bennett_transform.jl`, `controlled.jl`, `eager.jl`, `value_eager.jl` all `sizehint!` correctly — these are the easier transforms. The core pipeline doesn't.
15. **Depth is tracked** (`depth`, `toffoli_depth`, `t_depth` in diagnostics.jl). Good. But `peak_live_wires` is the quantum-relevant scalar and it's only used in two benchmark files — not surfaced in the standard `show(::ReversibleCircuit)` output.

---

## 3. Findings — prioritised

### CRITICAL

**C-1. `:auto` add dispatcher is monotonically worse than `:ripple` for multi-operand addition.**

Evidence:
```
i32 x+y auto:    gates=410  T=124  T-depth=124
i32 x+y ripple:  gates=350  T=124  T-depth= 64
i64 x+y auto:    gates=826  T=252  T-depth=252
i64 x+y ripple:  gates=702  T=252  T-depth=128
```

Source: `_pick_add_strategy` picks Cuccaro when `op2_dead`. For `(x,y) -> x+y`, y is last-used so Cuccaro fires. Cuccaro for a one-shot add delivers the same Toffoli count but **twice the depth** and **more total gates** than ripple. The win from Cuccaro is 1-ancilla vs n-ancilla — but the Bennett copy-out already doubles ancilla, so the ancilla savings don't compound.

Recommendation: change `:auto` to pick ripple unless the function has multiple sequential adds where ancilla pressure matters. Better: profile and publish a width-aware policy. As-is, every user paying `:auto` for two-input adds gets worse depth and more gates.

---

### HIGH

**H-1. `:auto` mul dispatcher never picks QCLA-tree or Karatsuba; README claim is locked behind opt-in.**

Evidence: `_pick_mul_strategy` at `src/lower.jl:1088-1094` requires the caller to set `use_karatsuba=true` for Karatsuba, or `mul=:qcla_tree` for QCLA-tree. `:auto` → shift_add unconditionally.

Measured i32 x*y: shift_add T-depth=190, karatsuba=132, qcla_tree=56. i64: shift_add=382, karatsuba=260, qcla_tree=64. **6× depth win locked away from `:auto`.**

README says: "Head-to-head at W=64 for `x * y`: QCLA tree Toffoli-depth=64 vs shift-add 382 (6× shallower)" — technically true but hidden behind a keyword the docstring doesn't foreground. FTQC users who don't read deeply get shift_add.

Recommendation: at W ≥ 32, `:auto` should pick qcla_tree when optimising T-depth (add a `target=:gate_count|:depth|:ancilla` kwarg, default `:gate_count`, and route accordingly). If backward-compat demands shift_add as the byte-identical default, document this explicitly and publish a loud WARNING when users compile wide multiplies with `:auto`.

---

**H-2. Missing peepholes: `x+0`, `x*1`, `x|0`, ripple-add with zero-constant operand all pay full price under `optimize=false`.**

Evidence:
```
x+0  optimize=false, fold_constants=false: 98 gates   (should be ~10)
x*1  optimize=false, fold_constants=false: 692 gates  (should be ~10)
x*1  optimize=false, fold_constants=true:  156 gates  (~half what it should be)
x+0  optimize=false, fold_constants=true:   98 gates  (NO IMPROVEMENT — fold pass misses this)
```

Under `optimize=true` LLVM eliminates these before we see them, so end users rarely hit them. But **the persistent-DS sweep mandates `optimize=false`** (documented in summary §Limitations). Every extra gate-per-no-op compounds ×max_n in that sweep.

Recommendation: add peephole passes in `lower.jl`:
- `lower_add!`: if `b` is a freshly-constant-wire vector of known zeros, emit only the `CNOTGate(a[i], result[i])` sequence (skip Toffolis, skip carry-propagation).
- `lower_mul!`: if `b` is known-1, emit copy-out of `a`. If known-0, emit nothing (result stays zero).
- Fix `_fold_constants` to recognise the ripple-add-with-zero-operand pattern. Right now it only folds partial constants; whole-operand-zero should collapse to copy-out.

Impact estimate: persistent_scan N=1000 is 1.4M gates; a significant fraction are "preserve N-1 slots" — those are exactly the x+0/x*1 cases. Implementing these peepholes could cut 20-40% off the persistent numbers without changing the algorithm.

---

**H-3. `fold_constants=false` is the default despite being safe.**

Evidence: `src/lower.jl:308` — `fold_constants::Bool=false`. Confirmed benefit on `x*1 optimize=false`: 692 → 156 gates (4.4× reduction).

There is no documented reason not to enable this by default. It's a pure forward-propagation and elimination of gates whose controls are provably constant. If it has an edge case, the comment doesn't explain it. Measured cost for i64 `x+1`: unchanged (100 gates with or without). So default-off costs every user and benefits nobody in the simple cases.

Recommendation: flip the default to `fold_constants=true`. If there's a correctness concern not in the docstring, surface it.

---

**H-4. Type-unstable field access in `LoweringCtx` hot path.**

Evidence:
```julia
struct LoweringCtx
    ...
    preds::Any              # Dict{Symbol,Vector{Symbol}} — typed Any to accept any dict shape from caller
    branch_info::Any
    block_order::Any
    ...
```

Comment says "to accept any dict shape" — but the only caller is `lower_block_insts!` which passes concrete `Dict{Symbol,Vector{Symbol}}` / `Dict{Symbol,Tuple{...}}` / `Vector{Symbol}`. So `Any` buys nothing and costs an unboxing check on every `ctx.preds` / `ctx.branch_info` / `ctx.block_order` access in the instruction dispatch loop. Grep of `ctx.preds` / `ctx.branch_info` / `ctx.block_order` shows ~30 access sites, all in hot dispatch paths.

Recommendation: concretise to the exact types (they're documented in the comment). If different callers really need different types, parameterise: `LoweringCtx{P,B,O}`. Expected compile-speedup 10-30% on lowering phase.

---

**H-5. No CI — silent regressions likely.**

Evidence: no `.github/`, no `.gitlab-ci.yml`, no `ci.jl`. CLAUDE.md §6 ("gate counts are regression baselines") relies entirely on local discipline.

Given this project's value prop is its gate-count numbers against published baselines, a nightly CI running the sweep and comparing against a locked-in JSONL of "must reproduce exactly" values is nearly free insurance. Add a GitHub Actions workflow.

---

### MEDIUM

**M-1. Abstract `Vector{ReversibleGate}` pays boxed-pointer overhead.**

Evidence: `src/gates.jl:4` — `abstract type ReversibleGate end`, three concrete subtypes. Stored as `Vector{ReversibleGate}` everywhere. Each element is a pointer to a heap-allocated 16-byte struct → ~24 bytes effective per gate vs 12-16 bytes for a packed representation.

For the persistent-sweep 1.4M-gate N=1000 circuit: ~34 MB of pointer-array + ~22 MB of boxed structs = ~56 MB; a tagged-union struct (`struct Gate; tag::UInt8; a::Int32; b::Int32; c::Int32; end`, 16 B packed) would cost ~22 MB — 2.5× reduction. Also: cache-line density helps simulator throughput.

Julia has good patterns for this (`Vector{UInt128}` packed representation, or `StructArrays.jl`). Moderate refactor; not a tiny change.

Recommendation: not urgent, but a Pareto-front improvement. Candidate for a benchmark-first exploration.

---

**M-2. No `sizehint!` in core pipeline despite it existing in peripherals.**

Evidence:
- `grep sizehint`: `bennett_transform.jl`, `controlled.jl`, `eager.jl`, `value_eager.jl` all size-hint correctly.
- `src/lower.jl`, `src/ir_extract.jl`, `src/adder.jl`, `src/multiplier.jl`: **zero** sizehints, but 142+69+... `push!` calls.

The final gate count is predictable for many operations (ripple-add = 5W, mul = O(W²), etc.). Even a rough `sizehint!(gates, 6 * total_ir_insts)` at the top of `lower()` would eliminate many reallocation copies.

Recommendation: cheap win. Add `sizehint!(gates, max(256, 10 * n_insts))` at the start of `lower()`.

---

**M-3. `_convert_instruction` returns a 17-element Union and heap-allocates per call.**

Evidence:
```
Body::UNION{NOTHING, BENNETT.IRALLOCA, BENNETT.IRBINOP, BENNETT.IRBRANCH,
            BENNETT.IRCALL, BENNETT.IRCAST, BENNETT.IREXTRACTVALUE,
            BENNETT.IRICMP, BENNETT.IRINSERTVALUE, BENNETT.IRLOAD,
            BENNETT.IRPHI, BENNETT.IRPTROFFSET, BENNETT.IRRET, BENNETT.IRSELECT,
            BENNETT.IRSTORE, BENNETT.IRSWITCH, BENNETT.IRVARGEP, VECTOR}
```

Julia will union-split up to ~4 concrete arms (tunable). 17+Vector blows past the threshold — every return pays a type-test. The `VECTOR` arm especially costs: it's for instruction-expansions (`llvm.umax` → 2 insts, `llvm.abs` → 3 insts, `llvm.ctpop` → O(W) insts) and triggers a separate code path in the caller (`if ir_inst isa Vector …`).

Recommendation: split into two APIs — `_convert_instruction_single(inst) -> IRInst` (returns one) and `_convert_instruction_expand!(out::Vector{IRInst}, inst)` (appends N). Callers dispatch based on opcode known upfront. Eliminates the Union entirely.

---

**M-4. `Dict{_LLVMRef, Symbol}` names table — potentially slow lookup on big functions.**

Evidence: `names::Dict{Ptr{LLVM.API.LLVMOpaqueValue}, Symbol}`. For soft_fadd at 175 insts + params + constants: ~200 entries. For a 64-round SHA-256: thousands.

Dict hash-lookup on a `Ptr` is fast (identity hash) but there are 66+ `_operand()` sites and the walker calls `names[r]` inside. A sorted `Vector{Pair{Ptr, Symbol}}` with binary search would be faster for <1000 entries given identity hash collisions don't matter; a `Base.IdDict` might also work (though IdDict has its own overhead).

Not the bottleneck per measurement, but worth checking once bigger circuits are compiled (full SHA-256, full AES).

---

**M-5. Simulator allocates per-call despite being otherwise well-optimized.**

Evidence:
```
100-call soft_fadd simulate: 300 allocs, 2.73 MB total → 27 KB/call.
```

Per call, allocates the Bool vector (n_wires × 1 B), output tuple, and possibly small scratch. For batch simulation (e.g., verify_reversibility across 256 inputs) this is 256× pointless re-alloc.

Recommendation: add `simulate!(buffer::Vector{Bool}, circuit, input)` variant. `verify_reversibility` should use it internally.

---

**M-6. `soft_fma` compiles to **447,728 gates** but is not benchmarked in BENCHMARKS.md.**

Evidence: I ran `reversible_compile(Bennett.soft_fma, UInt64, UInt64, UInt64)` cold: 0.53s compile (after warm), 447,728 gates, 148,340 Toffoli. This is registered as a callee (`register_callee!(soft_fma)` in Bennett.jl:166) so users get it via `x*y+z` in Float64 code, but it's invisible in published benchmarks.

Recommendation: add to run_benchmarks.jl and flag as a top-heavy primitive. Users compiling `fma`-heavy Float64 code will be surprised by the size.

---

### LOW

**L-1. `_simulate` return type is `Union{Int8,Int16,Int32,Int64,Tuple{Vararg{Int64}}}`.**

Acknowledged in source: `# Note: return type is inherently unstable (depends on circuit's output_elem_widths)`. Fine as-is; forcing a single return type would push casting into user code. But: callers that know the output type could use an `unsafe_simulate(T, circuit, input)::T` variant that asserts the width.

---

**L-2. `reversible_compile` re-extracts parsed IR even when strategy preview triggers `_tabulate_applicable` / `_tabulate_auto_picks`.**

Evidence: `src/Bennett.jl:80` extracts first, then inspects for tabulate, then maybe re-enters the tabulate path which ignores the parsed IR. For strategy-`:tabulate` direct callers the re-extraction isn't paid, but `:auto` on a tabulate-eligible function pays the extraction cost twice if both heuristics match.

Minor — only a few ms. Mention.

---

**L-3. `benchmark/` has no makefile / regression harness.**

Evidence: `ls benchmark/` shows 12 individual scripts plus a summary. To reproduce BENCHMARKS.md or the persistent sweep, the operator has to know `julia --project=. benchmark/run_benchmarks.jl`. No top-level orchestrator. No "did the numbers drift since last run" diff.

Recommendation: simple `benchmark/regression_check.jl` that runs `run_benchmarks.jl` and diffs against a committed `expected_results.jsonl`. Would make the CI gap (F-5) easier to close.

---

**L-4. `extract_ir` (the legacy text path) still lives in `src/ir_extract.jl:9`** and is not removed despite the LLVM.jl typed walker being the primary path. Not costing anything directly, but code debt.

---

### NIT

**N-1.** `simulate` with `Tuple{Vararg{Integer}}` input API can't accept wider-than-64-bit state (documented in WORKLOG NEXT AGENT §1). Known.

**N-2.** No reference comparisons to Q# compiler, Silq, Quipper, ReverC, Qiskit Aer **as apples-to-apples compile-time measurements**. BENCHMARKS.md compares gate counts against PRS15 Table II and ReVerC 2017 numbers lifted from papers — this is the right comparison for output quality. But "how long does Q# take to compile the same function" is not known. Worth a single-row entry in BENCHMARKS.md if only to remove the asymmetry.

**N-3.** `BenchmarkTools.jl` is not in `Project.toml` — benchmarks use raw `@elapsed` / `@allocated`. Acceptable but less statistically robust.

**N-4.** `benchmark/sweep_persistent_impls_gen.jl` is **17,815 lines**. Metaprogrammed harness. Worth noting in a design doc — a fresh reviewer will be overwhelmed when they open it.

---

## 4. Competitive-comparison sketch

A fair head-to-head would be:

| Compiler | Input | Output | Reference | Notes |
|---|---|---|---|---|
| Q# | Q# source | QIR / Toffoli net | MSR | gate count only; compile time is a Q# concern |
| Silq | Silq source | Toffoli net | Bichsel 2020 | smaller scope, pure Toffoli |
| ReverC 2017 | Revs (custom DSL) | Toffoli | Parent/Roetteler/Svore 2017 | 27.5k Toffoli on MD5 full (Bennett.jl extrapolated: ~48k, 1.75× worse) |
| Quipper | Haskell EDSL | Quipper | Green 2013 | compile time n/a |
| Qiskit Aer | Python gate-level | simulation | IBM | not a compiler |

Bennett.jl's differentiator is **plain Julia → reversible** (no DSL). None of the others take Julia/C/Rust. The comparable angle is "compile time per Toffoli" — but nobody publishes that number. Publishing it for Bennett.jl would be novel.

Absolute compile-time today (measured): **~3 μs per output gate** at the soft_fadd scale (320 ms / 94k gates). Straight-line adds: **~12 μs per gate** at N=128 (5.2 ms / 410 gates). The straight-line case is slower per-gate — lowering overhead amortises better on bigger circuits.

---

## 5. Priority summary

- **Fix first** (user-visible correctness-of-defaults): H-1, C-1, H-3 — the dispatcher defaults and fold_constants default are silently costing users gates and T-depth.
- **Fix next** (compile-speed): H-4 (LoweringCtx Any fields), M-2 (sizehint), M-3 (Union return).
- **Fix eventually** (infra): H-5 (CI), L-3 (regression harness), M-6 (fma benchmark).
- **Research** (peepholes): H-2 — the persistent-sweep N=1000 number could likely drop 20-40% with no-op add/mul folding.

---

## 6. What I did NOT verify

- Did not reproduce SHA-256 full benchmark (BC.3) — 64-round metaprogramming, slow.
- Did not run `benchmark/codegen_sweep_impls.jl` — orthogonal to perf review.
- Did not benchmark against other reversible compilers — out of scope (local hardware, no Q# / Silq toolchain).
- Did not profile `@profile` / `Profile.print()` — `@allocated` + `@time` + `code_warntype` gave enough signal.
- Did not examine every persistent-DS file. The dispatcher summary conclusion (linear_scan O(1) per-set) is plausible given measured numbers.

---

## 7. Key files referenced

- `/home/tobiasosborne/Projects/Bennett.jl/CLAUDE.md` — project invariants
- `/home/tobiasosborne/Projects/Bennett.jl/README.md` — claims to verify
- `/home/tobiasosborne/Projects/Bennett.jl/BENCHMARKS.md` — gate-count tables (all reproduce)
- `/home/tobiasosborne/Projects/Bennett.jl/WORKLOG.md` — baseline numbers (all reproduce)
- `/home/tobiasosborne/Projects/Bennett.jl/benchmark/sweep_persistent_summary.md` — sweep methodology
- `/home/tobiasosborne/Projects/Bennett.jl/benchmark/sweep_persistent_results.jsonl` — raw sweep data (2026-04-20)
- `/home/tobiasosborne/Projects/Bennett.jl/src/lower.jl` — hot paths: `lower`, `lower_block_insts!`, `lower_binop!`, `LoweringCtx`, `_pick_add_strategy`, `_pick_mul_strategy`, `_fold_constants`
- `/home/tobiasosborne/Projects/Bennett.jl/src/ir_extract.jl` — `_convert_instruction` (Union return), `_operand` / `names` dict
- `/home/tobiasosborne/Projects/Bennett.jl/src/adder.jl` — `lower_add!`, `lower_add_cuccaro!`, `lower_sub!`
- `/home/tobiasosborne/Projects/Bennett.jl/src/multiplier.jl` — `lower_mul!`, `lower_mul_karatsuba!`
- `/home/tobiasosborne/Projects/Bennett.jl/src/gates.jl` — abstract `ReversibleGate` + three concrete types
- `/home/tobiasosborne/Projects/Bennett.jl/src/simulator.jl` — simulate, `apply!`
- `/home/tobiasosborne/Projects/Bennett.jl/src/bennett_transform.jl` — `bennett` (well-sized)
- `/home/tobiasosborne/Projects/Bennett.jl/src/diagnostics.jl` — `depth`, `toffoli_depth`, `t_depth` (all present)
- `/home/tobiasosborne/Projects/Bennett.jl/Project.toml` — no PackageCompiler, no precompile directives
