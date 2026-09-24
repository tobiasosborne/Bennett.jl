# Bennett-t9rh — PROPOSER B (verbatim hand-back)

> 3+1 protocol, proposer B, 2026-09-24, read-only design agent on an AVX-512 host. Recovered verbatim from the agent transcript after a container restart.

# Proposer B design: Bennett-t9rh, host-CPU-dependent extraction

## 0. Summary

The PoisonLaneSentinel crash is a symptom of a wider problem. Every `optimize=true` extraction (the default, and always used for callees) runs Julia's JIT pass pipeline with the host's TargetMachine. The IR, and therefore gate counts and even whether a function compiles, depends on the host CPU and on the session's `-O` level. I measured silent gate-count differences of up to about 15x between real CPUs.

**Recommendation: do both fixes, in this order.**

- **(A) Primary fix: make extraction host-independent.** Always take Julia's `optimize=false` IR. Then, inside the Bennett process, run Julia's own pipeline (`"julia<level=2>"`) with a pinned TargetMachine (`cpu="x86-64"`, no features). This reproduces `julia -C x86-64` exactly, on any host.
- **(B) Defense in depth: make poison-lane scalarisation sound, following the LangRef.** In lane-wise ops, a poison lane produces a poison lane. For `select`, refine a poison arm to the other arm. Keep the loud errors at every point where a lane is actually observed.

Fix B alone is not acceptable. It turns the loud crash into a silent gate-count difference: soft_fmul gives 149,834 on AVX-512 vs 149,198 elsewhere, and `F64 a*b` gives 150,092 vs the BENCHMARKS value of 149,456.

## 1. How IR is acquired, and where the host CPU gets in

- `src/extract/entry.jl:60` `extract_parsed_ir` calls `code_llvm(io, f, T; debuginfo=:none, optimize, dump_module=true)`. `optimize` defaults to `true` (`CompileOptions`, `src/Bennett.jl:112`).
- Callees always go through `src/lowering/call.jl:91` → `_extract_parsed_ir_cached(inst.callee, arg_types)`, which defaults to `optimize=true` whatever the top-level option says.
- `code_llvm(optimize=true)` runs Julia's NewPM pipeline using the JIT's TargetMachine. That TM comes from `-C` / `JULIA_CPU_TARGET`, or the host by default. Its TTI decides SLP and loop vectorisation, partial/runtime unroll factors, and speculation costs. The `CPUFeatures` pass lowers `julia.cpu.have_fma` from the TM's features.
- The emitted text carries no target-cpu attribute, so the dependency can't be seen in the IR.
- The session opt level (`julia -O1/-O3`) is a second hidden input. With `-C x86-64`: soft_fmul is 149,380 at `-O1` vs 149,198 at `-O2`/`-O3`, and F64 sqrt is 244,683 at `-O1` vs 431,289.
- `optimize=false` IR is host-independent: byte-identical under native, haswell and x86-64 for all 60 `soft_*` functions once embedded pointer addresses are normalised.
- Other extraction paths:
  - `extract_parsed_ir_from_ll` / `_from_bc`, `run_memssa` and julia_set bodies (`optimize=false`) are already host-independent.
  - `_run_passes!` runs with no TM, so it uses the base TTI. That is host-independent, but see risk 8.
  - `extract_parsed_ir_by_sig(...; optimize=true)` has the same problem as the main path.
- Bennett-bq5m (the `optimize=true` default contradicts Rule 5) was deferred because flipping the default re-baselines everything. This design keeps `optimize=true` semantics and only pins the target.

## 2. Root cause, with IR evidence

Host is cascadelake (AVX-512F/VL/BW/DQ). Native `code_llvm(soft_fmul, (UInt64,UInt64); optimize=true)` shows SLP-vectorised exponent/normalisation code (61 vector lines). With `-C haswell` or `-C x86-64` there are 0 vector lines. The offending lines:

```llvm
%80 = call <2 x i64> @llvm.umax.v2i64(<2 x i64> %4, <2 x i64> <i64 1, i64 1>)   ; needs AVX-512VL vpmaxuq -> SLP profitable only here
...
%93 = select <2 x i1> %8, <2 x i64> %80, <2 x i64> %92
%shift = shufflevector <2 x i64> %93, <2 x i64> poison, <2 x i32> <i32 1, i32 poison>
%94 = add nsw <2 x i64> %93, %shift        ; lane1 = %93[1] + poison  (dead)
%95 = extractelement <2 x i64> %94, i64 0  ; only lane 0 observed
```

This is SLP's horizontal-add idiom. How it reaches the crash:

1. `src/extract/vectors.jl` shufflevector branch: mask element -1 becomes `POISON_LANE` (correct per the LangRef).
2. The vector binop branch (`vectors.jl` ~l.489) emits `IRBinOp(lane_dest, :add, %93[1], POISON_LANE)` for dead lane 1.
3. Lowering calls `resolve!` on that operand, which hits the catch-all in `src/lowering/operand.jl:65` and throws "PoisonLaneSentinel reached lowering (Bennett-v958 / U68)".

The icmp, select, cast and intrinsic lane loops have the same gap. The intrinsic loop at l.610 already errors at extraction, even for dead lanes.

## 3. Blast radius (measured on this host; `-C` subprocesses emulate other hosts)

**IR level: optimized IR differs between native and haswell for 30 of 60 `soft_*` functions.**
- Vectorised natively (0 vector lines under haswell/x86-64): acos, acosh, asin, asinh, atanh, fdiv, fma, fmul, log, log2, log10, log1p, pow. These contain poison shuffles.
- Vectorised with no poison: fcmp_* ×10, fmin/fmax/fminimum/fmaximum/minimumnum/maximumnum.
- haswell vs x86-64 also differ, with no vectors involved, for 19 functions (sqrt, fdiv, tanh, sinh, cosh, tan, atan, atan2, log1p, powi, …). The cause is different loop unroll factors.
- Among non-soft-float registered callees, these also vectorise natively: hamt/linear_scan/cf `pmap_set`, and `soft_mux_store_{5..8}x8`. haswell also vectorises hamt and linear_scan.

**Hard errors on AVX-512 (all compile on haswell and x86-64):**
- soft_fmul, `(a,b)->a*b` on Float64, fneg∘fmul, soft_fma, soft_exp_julia, soft_exp2_julia, and Float64 `x/y`.
- Test files currently red on this host (sample of 33 files): test_float_circuit (7 errors), test_5qrn_identity_peepholes (1), test_ao66_vector_intrinsic_rescalarise (1), test_lx5h_float_vector_reductions (1). The last two fail because the callee soft_fma/soft_fmul is extracted natively.
- The pinned `benchmark/regression_baselines.jsonl` entry soft_fma = 247,398 cannot be produced on AVX-512.

**Silent gate-count differences (total gates):**

| function | x86-64 | haswell / skylake / alderlake / x86-64-v3 | cascadelake (native) | znver3 | znver4 |
|---|---|---|---|---|---|
| soft_fcmp_olt | 6,248 | 6,248 | **6,252** | 6,248 | 6,252 |
| soft_fcmp_oeq | 3,524 | 3,524 | **3,528** | | |
| soft_mux_store_8x8 | 6,178 | 6,178 | **6,242** | 6,178 | 6,242 |
| linear_scan_pmap_set | 13,962 | 13,994 | 13,994 | | |
| cf_pmap_set | 60,566 | 60,566 | 60,568 | | |
| hamt_pmap_set | 64,138 | 64,390 | 64,386 | | |
| `_soft_udiv_compile` (K=64) | **825,319** | 1,594,161 | 1,594,161 | **12,594,211** | 12,594,211 |
| F64 `sqrt` (K=70) | **431,289** | 791,317 | 791,317 | **5,798,513** | 5,798,513 |
| F64 `x/y` (K=60) | **409,933** | 695,293 | ERROR | | |
| soft_fmul | 149,198 | 149,198 | ERROR | 149,198 | ERROR |

- `_soft_udiv_compile` backs every integer `÷` and `%`, so this one matters most: roughly 2x on Intel and roughly 15x on AMD Zen.
- The cause is TTI-driven partial/runtime unrolling. `max_loop_iterations=K` counts iterations of the loop after LLVM has unrolled it, so circuit size scales with the host's unroll factor.
- Both the x86-64 and haswell div/sqrt circuits were bit-exact on 300 random inputs. The problem is size, not correctness.

**Assumption about the maintainer's machine.** It is non-AVX-512 x86. Evidence: the BENCHMARKS values (soft_fmul 149,456 for `F64 a*b`, soft_fma 247,398, soft_fadd 63,058) and the regression_baselines values (62,800 / 247,398) are reproduced exactly by haswell and x86-64, and cannot be produced on AVX-512.

These artefacts do not distinguish haswell-class, x86-64 or Zen3 from each other, and nothing pins div/sqrt/udiv totals (I grepped tests, worklog and benchmarks). If the maintainer is on Apple Silicon, I could not emulate it (see risk 3).

## 4. Options, argued against the rules

- **Only B (poison fix).**
  - Rule 1: good.
  - Rules 6 and 13: fails. AVX-512 hosts silently get different baselines (fmul +636, fma +596, fcmp +4, F64 x/y +644). The Zen vs Intel loop blow-ups are untouched.
  - Rule 5: not addressed.
  - Rejected as the sole fix.
- **Only A (canonical target).**
  - Rules 5 and 6: fixed for the Julia path.
  - Still leaves a latent crash for vector IR from `.ll`/`.bc` (clang/rustc T5 corpus, `-O2` SLP output), and for any future SLP pattern under the canonical TM. hamt_pmap_set still has 29 vector lines at x86-64 (SSE2).
- **A + B (recommended).** A makes the circuit a function of (source, Bennett, options, Julia/LLVM version). B makes the vector scalariser sound for every entry point.
  - B only changes code paths that currently always crash. So B cannot move any existing gate count; it can only turn a crash into a compiled circuit.
- **A′ (optional follow-up, separate bead): add `no_enable_vector_pipeline` to the canonical pipeline.**
  - Measured: removes all Julia-path vectors; the 33-file sample stays green; non-loop baselines are unchanged.
  - Loop circuits shrink further: udiv 436,577, sqrt 244,683, hamt 64,110.
  - Cost: we would diverge from Julia's standard pipeline and lose the `julia -C x86-64` oracle. Under Rule 6 this is a strategy change and needs a BENCHMARKS note. Not part of this change.

**Why `x86-64` as the canonical CPU:**
- It is the x86-64 baseline ISA (SSE2).
- LLVM `"generic"` and `"x86-64-v2"` give identical numbers to it on everything I measured.
- It has an out-of-process oracle: `julia -C x86-64`.
- It gives the smallest loop circuits of any real-CPU setting measured. (No-TM, i.e. the base TTI, was smaller for sqrt, but it vectorises aggressively and crashes; see §6.)
- The alternative is `x86-64-v3`, which equals haswell. It would keep haswell-class loop counts but brings AVX2/FMA TTI with it. Either choice leaves the sampled pinned tests unchanged. x86-64 is the more principled "generic" choice.

## 5. In-process feasibility (verified by redefining Bennett functions at runtime; no repo files touched)

Recipe:

```julia
ir = code_llvm(f, T; optimize=false, dump_module=true)
mod = parse(LLVM.Module, ir)
tm  = LLVM.TargetMachine(LLVM.Target(triple=triple(mod)), triple(mod), "x86-64", "")
LLVM.run!("julia<level=2>", mod, tm)
```

`LLVM.Interop.JuliaPipeline(opt_level=2)` produces the same pipeline string. LLVM.jl's `run!` registers Julia's pass callbacks (`jl_register_passbuilder_callbacks`), so the Julia passes (LateLowerGCFrame, AllocOpt, CPUFeatures, FinalLowerGC, …) run.

What I checked:

- **Match against the oracle.** In-process output, with SSA/global names canonicalised, is identical to `julia -C <cpu>` `code_llvm(optimize=true)` for 59 of 60 `soft_*` functions, for both haswell and x86-64. soft_fptrunc differs by one `nonnull` attribute on a throw-path call. Gate counts are identical.
- **Gate counts under the patched extractor with the x86-64 TM** match `-C x86-64` exactly: fmul 149,198; F64* 149,456; F64+ 63,058; fma 247,398; fcmp_olt 6,248; F64 x/y 409,933; F64 sqrt 431,289; x+1 i8 = 58.
- **Host independence.** The same patched code running in a `julia -C znver3` process gives the x86-64 numbers (udiv 825,319, sqrt 431,289, hamt 64,138), not Zen's 12.6M / 5.8M.
- **No TM at all** (base TTI): SLP vectorises everything and fmul, fcmp, fma and div hit PoisonLaneSentinel. So the TM must be pinned, not omitted.
- **Test sample.** 33 test files, including all pinned-gate-count files (regression, 5qrn, y986, httg, jepw, 5kio, zmw3, 0c8o, eager, egu6, sret×3, persistent_hamt, pebbled, h0ai, 57hd, 8kno, k7al, uiaq, sr8v, lf14, bennett) plus loop, vector and float files. Under `--check-bounds=yes` on this AVX-512 host, all are green with the x86-64 TM, with or without the vector pipeline. Unpatched native has 10 failures.
- **Speed.** Compile time is about the same or faster. y986 took 34 s vs 1 m 56 s native, because of less unrolling.

## 6. Implementation

### Part A: `src/extract/entry.jl`

```julia
# Bennett-t9rh: canonical, host-independent optimisation target.
const _CANONICAL_OPT_LEVEL = 2                      # pinned; ignores session -O
const _CANONICAL_CPU = Dict("x86_64" => "x86-64")   # arch => LLVM CPU; other arches -> "generic"
const _CANONICAL_FEATURES = ""                      # no +fma/+avx*: TTI and CPUFeatures fixed

_canonical_cpu(triple::AbstractString) = get(_CANONICAL_CPU, first(split(triple, '-')), "generic")

# Run Julia's own O2 pipeline on UNOPTIMISED Julia IR with a pinned TargetMachine.
# `cpu` is an internal test hook only (lets tests reproduce e.g. skylake-avx512 SLP IR).
function _canonical_optimize_ir(ir_unopt::AbstractString; cpu::Union{Nothing,String}=nothing)::String
    local out::String
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_unopt)
        try
            tr = LLVM.triple(mod)
            isempty(tr) && error("ir_extract.jl: module has no target triple; cannot build canonical TargetMachine (Bennett-t9rh)")
            LLVM.TargetMachine(LLVM.Target(triple=tr), tr, something(cpu, _canonical_cpu(tr)), _CANONICAL_FEATURES) do tm
                LLVM.run!(LLVM.Interop.JuliaPipeline(opt_level=_CANONICAL_OPT_LEVEL), mod, tm)
            end
            out = string(mod)
        finally
            dispose(mod)
        end
    end
    return out
end

# Single source of Julia-function IR for every extraction entry.
function _julia_ir_string(f, arg_types::Type{<:Tuple}; optimize::Bool)
    raw = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize=false, dump_module=true))
    return optimize ? _canonical_optimize_ir(raw) : raw
end
```

Changes at the call sites:
- `extract_parsed_ir`: `ir_string = _julia_ir_string(f, arg_types; optimize)`. Everything else stays the same; `_parsed_ir_from_ir_string` is unchanged, and memssa still sees the optimised string as it does today.
- `extract_parsed_ir_by_sig`: `raw = _code_llvm_by_sig(sig; optimize=false, dump_module=true, ...)`, then `optimize && (raw = _canonical_optimize_ir(raw))`. The optional leading `; WARNING` comment line parses fine.
- `extract_ir` (debug printer): route through the same helper so that what users inspect is what gets compiled. On an AVX-512 box, host `code_llvm` shows vector IR that Bennett never sees.
- Docstrings: say that `optimize=true` means "Julia's O2 pipeline, TargetMachine = x86-64 generic, fixed", not "host JIT".
- No cache-key change (`_extract_parsed_ir_cached`): the canonical target is a process-wide constant.
- Do **not** add an environment variable or kwarg to override the CPU. That would reintroduce a hidden input.

### Part B: `src/extract/vectors.jl` (`_convert_vector_instruction`)

Add `@inline _is_poison(op) = op === POISON_LANE`. Then, in each lane loop:

- **Binop** (add…ashr) and **icmp**:
  `if _is_poison(a[i]) || _is_poison(b[i]); out[i] = POISON_LANE; continue; end`
  - LangRef 18 §Poison Values: "Most instructions return 'poison' when one of their arguments is 'poison'. A notable exception is the select instruction."
  - Vector ops are defined per element, e.g. lshr: "If the arguments are vectors, each vector element of op1 is shifted by the corresponding shift amount in op2". The LangRef's own example has `<i32 undef, i32 poison>` extracting lane-wise to undef and poison respectively.
  - Vector udiv/sdiv (poison divisor is UB) are not in the supported list; keep it that way.
- **Casts** (sext/zext/trunc): `_is_poison(src[i])` → poison lane.
- **Select**, per lane:
  - `c` poison → poison lane.
  - Both arms poison → poison lane.
  - Exactly one arm poison → `out[i] = other_arm[i]`. This is a pure alias with no gates.
  - Justification: LangRef §Poison Values, "It is correct to replace a poison value with an undef value or any value of the type." Replacing the poison arm with the other arm gives `select c, x, x = x`, a legal refinement. §select: vector conditions select "element by element". Also cite the LangRef text on `select` with an undef arm being eliminable "if %Y is provably not 'poison'".
  - Scalar `i1` condition (broadcast) is unchanged.
- **Lane-wise intrinsic loop** (l.606–626): replace the `reads poison lane` error with `if any(lv -> _is_poison(lv.op), lane_ops); out[i] = POISON_LANE; continue; end`. Put it **before** `_validate_vector_intrinsic_lane` and `_handle_intrinsic`. The immarg validation only checks constant scalar args, which are never poison.
- **Keep fail-loud** where lanes are observed:
  - `extractelement` of a poison lane (l.472). Fix the message: it is not UB; per the LangRef it yields scalar poison, which Bennett cannot represent. Reference Bennett-t9rh.
  - Reductions (l.344).
  - `<N x i1>` → `iN` bitcast (l.667).
  - The `resolve!` catch-all in `operand.jl` stays as the backstop, e.g. poison lanes flowing into sret/vector returns via `PendingVecLane`.
- **Soundness argument for B.** B never manufactures bits. The only values it materialises are the select-arm refinements, which the LangRef licenses. Marking a lane poison too eagerly (for example an intrinsic that doesn't propagate poison) can only cause a spurious loud error if that lane is later observed; it can never cause a miscompile.
- Out of scope: `freeze` of vectors; it could be materialised as 0 later.

### Also

- Worklog entry in the top chunk.
- BENCHMARKS.md note: "extraction target = x86-64 generic, O2 (Bennett-t9rh)", plus the loop-bearing deltas below.
- Suggest a line under CLAUDE.md Rule 5: never study host `code_llvm(optimize=true)` output; use `Bennett.extract_ir` or `julia -C x86-64`.

## 7. Expected impact on gate counts

- **Pinned baselines** (`test_gate_count_regression`, the other 22 files with `== N` pins, BENCHMARKS fadd/fmul/fma, regression_baselines): unchanged. Every pinned file I ran is green, and the BENCHMARKS / regression_baselines entries I checked (fadd, fmul, fma) are reproduced exactly.
- **Part B:** zero change to any currently compiling circuit, by construction.
- **Behaviour that changes, none of it pinned:**
  - AVX-512 hosts: the crashing functions now compile to the canonical counts (fmul 149,198, F64* 149,456, fma 247,398). fcmp_* and mux_store_8x8 move to 6,248 / 3,524 / 6,178.
  - Loop-bearing functions on hosts that unrolled more:
    - `_soft_udiv_compile`: 1,594,161 (Intel) or 12,594,211 (Zen) → 825,319.
    - F64 sqrt (K=70): 791,317 / 5,798,513 → 431,289.
    - F64 x/y (K=60): 695,293 → 409,933.
    - hamt_pmap_set: 64,390 → 64,138.
    - linear_scan_pmap_set: 13,994 → 13,962.
- The implementer must still run the full suite on this host. My sample is 33 of 314 files. Any pinned delta must be investigated under Rule 6, not re-baselined blindly.

## 8. Red-green tests (all host-agnostic)

1. **`test/test_t9rh_canonical_extraction.jl`** (skip with an explicit message if `Sys.ARCH !== :x86_64`).
   - (a) **Pinned values on any host:**
     - `gate_count(reversible_compile(soft_fmul,UInt64,UInt64)).total == 149198`
     - `(a,b)->a*b` on Float64: 149456
     - `soft_fma`: 247398
     - `soft_fcmp_olt`: 6248
     - `_known_callees["soft_mux_store_8x8"]`: 6178
     - `x->sqrt(x)` on Float64 with K=70: 431289
     - `_known_callees["_soft_udiv_compile"]` with K=64: 825319
     - Each also gets `verify_reversibility` plus bit-exact checks on random and edge inputs.
     - Red today on AVX-512 (errors) and on haswell-class hosts (sqrt 791317, udiv 1594161), so it is red on every x86 host I could emulate.
   - (b) **Oracle equivalence.** Spawn `$(Base.julia_cmd()) -C x86-64 --project=... -e 'print(code_llvm(...; optimize=true, dump_module=true))'` for soft_fmul, soft_fsqrt and soft_fcmp_olt. Compare against `Bennett._julia_ir_string(f,T; optimize=true)` with SSA/global names, `#N` attribute ids and inttoptr addresses canonicalised, comparing sorted body lines. This detects drift in the Julia pipeline in future.
   - (c) **Host independence.** Spawn `julia -C znver3 --project` computing `gate_count(...).total` for `_soft_udiv_compile` and sqrt through Bennett; assert it equals the in-process value. Today it is 12,594,211 vs 825,319.
   - (d) **Opt-level independence.** A `julia -O1` subprocess gives soft_fmul 149198. Today it gives 149380.
2. **`test/fixtures/ll/t9rh_poison_lanes.ll` + `test/test_t9rh_poison_lanes.jl`** (host-independent, via `extract_parsed_ir_from_ll`):
   - `@hsum`: `insertelement` ×2 → `shufflevector <1, poison>` → `add` → `icmp ult` → `zext` → `llvm.umax.v2i64` → `select` → `extractelement` lane 0. Expected result `max(a+b, zext(a+b<a))`.
   - I verified this exact function: today it crashes with PoisonLaneSentinel; with the patch it gives 3,026 gates, `verify_reversibility` true, and correct results for (3,5), (typemax,2) and (0,0). Add random sweeps.
   - A select-with-poison-arm case (`select <2 x i1> %c, <2 x i64> %v, <2 x i64> poison`, extract lane 0 under a condition that is true for some inputs, false for others) to pin the refinement.
   - Negatives, which must stay loud with the t9rh/extract message and **not** the `resolve!` message:
     - Extracting lane 1 of `@hsum`. Verified: it errors at extraction with "extractelement reads poison lane".
     - `vector.reduce.add` over a vector with a poison lane.
     - `<2 x i1>` → `i2` bitcast with a poison lane.
3. **Real SLP IR on any host.** Call `Bennett._canonical_optimize_ir(raw; cpu="skylake-avx512")` on soft_fmul's `optimize=false` IR. Creating that TM does not need the host to support it. Then:
   - assert that `shufflevector … poison` occurs;
   - run `_parsed_ir_from_ir_string` → `reversible_compile(parsed)`;
   - assert it is bit-exact on 200 or more random operands plus edge cases (0, -0, Inf, NaN, subnormals).
   - I measured this at 149,834 gates with 0 mismatches in 200 random inputs.
   - This exercises Part B on real vectoriser output even on non-AVX-512 machines.
4. **Now green on AVX-512 hosts:** test_float_circuit, test_5qrn, test_ao66, test_lx5h (currently red here). Also run `benchmark/regression_check.jl` without `--update`. It may regenerate a gitignored generated file.

## 9. Risks

1. **Pipeline drift.** Future Julia versions may change what `code_llvm(optimize=true)` does beyond the pass pipeline. Test 1b detects this. Gate counts remain a function of the Julia/LLVM version; record it with baselines.
2. **CPUFeatures and FMA.** With features `""`, `julia.cpu.have_fma` lowers to false, so `Base.fma(::Float64)` in user code takes `fma_emulated` rather than `llvm.fma`. Today that choice depends on the host. SoftFloat dispatch has no `fma` method (it errors identically on every host), so I measured no current impact. This is a deliberate, documented decision; the alternative is features `"+fma"`, which I did not evaluate.
3. **Other architectures.** On aarch64 the table falls back to `"generic"` for the module's own triple. Julia's frontend codegen is architecture-specific, so x86 and ARM gate counts are not promised to match. Document this and add a guard in tests.
4. **`max_loop_iterations` meaning.** K counts post-unroll iterations. A K tuned on a host that unrolled heavily (Zen, 8x) may overflow under canonical 2x unrolling. Bennett-s0tn's convergence wire makes that loud at `simulate`. test_float_circuit (div K=60, sqrt K=70) passes under x86-64: 430/430.
5. **Remaining hidden inputs.** `JULIA_LLVM_ARGS` (global LLVM cl::opts such as `-unroll-threshold`) and `--check-bounds` (frontend; Bennett-2mj3) are still hidden inputs. Out of scope; note in the docstring.
6. **Cost.** One extra parse/print round-trip plus one TargetMachine per extraction, on the order of milliseconds. Callee caching is unchanged.
7. **Julia-API dependency.** `run!` depends on LLVM.jl's `jl_register_passbuilder_callbacks` wiring, which is stable in LLVM.jl 9.x / Julia 1.12. Note `LLVM.Interop` in the code comment.
8. **`_run_passes!` stays TM-less** (base TTI). It is host-independent, but if a user requests SLP or loop-vectorize passes it vectorises aggressively. Leave it unchanged here, since threading the TM in could move `preprocess=true` baselines through simplifycfg costs. File a follow-up.
9. **Part B over-approximation** can only produce spurious loud errors, never wrong bits. The only materialisation is the LangRef-licensed select refinement.

### Critical files for implementation
- /home/user/Bennett.jl/src/extract/entry.jl (`extract_parsed_ir`, `extract_parsed_ir_by_sig`, `extract_ir`, new `_canonical_optimize_ir` / `_julia_ir_string`)
- /home/user/Bennett.jl/src/extract/vectors.jl (`_convert_vector_instruction` lane loops: binop, icmp, cast, select, intrinsic; message at extractelement)
- /home/user/Bennett.jl/src/lowering/operand.jl (`resolve!` catch-all stays as the backstop; reference only)
- /home/user/Bennett.jl/src/extract/callees.jl and /home/user/Bennett.jl/src/lowering/call.jl:91 (callees always extracted with `optimize=true`, which is how the host dependency reaches every soft-float circuit)
- New: /home/user/Bennett.jl/test/test_t9rh_canonical_extraction.jl, /home/user/Bennett.jl/test/test_t9rh_poison_lanes.jl, /home/user/Bennett.jl/test/fixtures/ll/t9rh_poison_lanes.ll
