# Bennett-t9rh — PROPOSER A: poison vector lanes + host-CPU-dependent IR

> 3+1 protocol, proposer A. 2026-09-24, read-only design agent on an AVX-512 host
> (cascadelake, Julia 1.12.7, LLVM 18.1.7). Prototypes were in-memory only; scratch at
> the session scratchpad `t9rh_A/` (pinned.jl, vectors_patched.jl, fixture.ll/fixt.jl,
> surveys). Archived in substance by the orchestrator.

**Recommendation: (c) both, two commits.** (1) option (a) — correctness, needed on ALL
hosts (the crash also reproduces on AVX2 / `-C haswell` / pinned `x86-64-v3`, and on
external `.ll`/`.bc`); (2) option (b) — pin the target CPU for `optimize=true` IR
acquisition, for Rule-6 reproducibility (gate counts silently drift with host CPU, up to 1.8×).

## 1. Root cause

**IR acquisition.** `extract_parsed_ir` (entry.jl:60) → `code_llvm(...; optimize=true,
dump_module=true)` → `InteractiveUtils._dump_function_llvm` → `jl_get_llvmf_defn`; with
optimize=true that runs exactly `NewPM PM{jl_ExecutionEngine->cloneTargetMachine(),
getOptLevel(jl_options.opt_level)}; PM.run(*m)` (Julia 1.12 aotcompile.cpp ~L2435) — the
host JIT TargetMachine drives SLP/loop-vectoriser and unroll cost models. Then
`jl_dump_function_ir(strip_ir_metadata=true)` runs RemoveJuliaAddrspacesPass and strips
metadata/dbg. `Base.CodegenParams` has no target field — the only in-process lever is to
re-run the pipeline ourselves. The failing IR is the callee `soft_fmul`'s own module
(via lowering/call.jl:91 → `_extract_parsed_ir_cached`).

**Offending IR (native soft_fmul: 93 vector insts; haswell/x86-64: 0):**
```llvm
  %0 = insertelement <2 x i64> poison, i64 %"b::UInt64", i64 0
  %1 = insertelement <2 x i64> %0, i64 %"a::UInt64", i64 1
  ...
  %93 = select <2 x i1> %8, <2 x i64> %80, <2 x i64> %92
  %shift = shufflevector <2 x i64> %93, <2 x i64> poison, <2 x i32> <i32 1, i32 poison>
  %94 = add nsw <2 x i64> %93, %shift   ; lane0 = expB+expA, lane1 = %93[1]+poison
  %95 = extractelement <2 x i64> %94, i64 0   ; only lane 0 observed
```
**Path (backtrace-confirmed):** shufflevector arm (vectors.jl:446-447) maps mask -1 →
`POISON_LANE`; vector-binop arm (vectors.jl:489-493) emits a scalar op per lane
(`IRBinOp(:__v283, :add, SSA(:__v281), PoisonLaneSentinel(), 64)`); no DCE, so the dead lane
is lowered: driver.jl:536 → types.jl:241 → lower_binop! (arith.jl:200) → resolve! catch-all
(operand.jl:67) → AssertionError.

**AVX2 also fails:** `k(x::Int64) = (a = zeros(Int64,4); for i in 1:4; a[i]=x*i; end; a[2]+a[4])`
fails natively, `-C haswell`, pinned x86-64-v3:
```llvm
  %broadcast.splat = shufflevector <4 x i64> %broadcast.splatinsert, <4 x i64> poison, <4 x i32> <i32 poison, i32 0, i32 poison, i32 0>
  %0 = shl <4 x i64> %broadcast.splat, <i64 0, i64 1, i64 0, i64 2>
  %1 = extractelement <4 x i64> %0, i64 1
```
**Semantics (LLVM 18 LangRef):** "Most instructions return 'poison' when one of their
arguments is 'poison'. A notable exception is the select instruction."; "It is correct to
replace a poison value with an undef value or any value of the type."; shufflevector "A
poison element in the mask vector specifies that the resulting element is poison"; select is
per-element; InstSimplify folds `select ?, poison, X -> X` (InstructionSimplify.cpp
release/18.x L4883-4895). Poison is UB only at specific uses (load/store ptr, divisor, branch
cond, noundef) — none here. Every pipeline step refines the (deterministic, poison-free)
Julia source ⇒ not computing an unobserved lane is a sound refinement; bit-exact (Rule 13):
soft_fmul under (a) matched on all 13×13 edge pairs + 40 randoms; fma, fneg∘fmul, fcmp_olt pass.

## 2. Blast radius
IR-level: x86-64, -v2, -v3, haswell, skylake, znver2/3, alderlake — no poison-lane vector ops
in the soft-float family; AVX-512 (x86-64-v4, cascadelake, znver4, sapphirerapids) — 87-290
vector ops, 3-12 poison refs (fmul, fma, fdiv, log/log2/log10, pow, asin, acos; fcmp_* have a
poison insertelement base fully overwritten). **Scalar-level drift**: atan, atan2, tan, fsqrt,
fdiv, asin, acos differ between SSE-class, Intel AVX2 and Zen2/3/alderlake (unroll/tuning;
e.g. soft_fsqrt loop ×2 on x86-64, ×4 on v3).

Gate counts native (AVX-512) vs `-C x86-64`:

| function | native | x86-64 |
|---|---|---|
| soft_fmul | ERROR | 149,198 |
| soft_fma | ERROR | 247,398 (= BENCHMARKS.md) |
| Float64 x*y+1 | ERROR | 209,376 |
| soft_fcmp_olt | **6,252** | 6,248 |
| soft_fcmp_oeq | **3,528** | 3,524 |
| soft_fsqrt (max_loop_iterations=64) | **724,597** (= v3) | 394,689 |
| ls_demo_16 (cc0.7 fixture) | 3,944 (vectorised on v2+) | 3,928 |

Identical: soft_fadd/fsub/fptrunc, i8 x+1 = 58, i64 x*y, i32 poly, i16 loop.
Residual unpinnable dependence: `Base.fma(::Float64)` resolved by `Core.Intrinsics.have_fma`
at codegen — unoptimised IR is `llvm.fma.f64` on FMA hosts, `@j_fma_emulated` under -C x86-64
(follow-up bead).

## 3. Options
**(a) Poison propagation in the scalariser** (`_convert_vector_instruction`, four lane-wise arms;
observation-points keep failing loud):
```julia
# binop (~L489) / icmp (~L508), per lane i:
if a_lanes[i] isa PoisonLaneSentinel || b_lanes[i] isa PoisonLaneSentinel
    out[i] = POISON_LANE; continue          # LangRef: poison propagates; emit NO gates
end
# cast (~L550):
if src_lanes[i] isa PoisonLaneSentinel; out[i] = POISON_LANE; continue; end
# select (~L530), after c_op:
if c_op isa PoisonLaneSentinel || (t_lanes[i] isa PoisonLaneSentinel && f_lanes[i] isa PoisonLaneSentinel)
    out[i] = POISON_LANE; continue
elseif t_lanes[i] isa PoisonLaneSentinel; out[i] = f_lanes[i]; continue   # select ?, poison, X -> X
elseif f_lanes[i] isa PoisonLaneSentinel; out[i] = t_lanes[i]; continue
end
```
All-poison arm returns empty `IRInst[]`. Observed poison now fails EARLIER with context
(`extractelement ... reads poison lane — undefined behaviour`, ErrorException via `_ir_error`).
Zero gate-count impact on anything that compiles today. Native AVX-512 with (a) only: fmul
149,834; fneg∘fmul 150,224; fma 247,994; k 1,180 (bit-exact, but ≈636 CNOTs of lane plumbing
off other hosts). Conservatism: `_resolve_vec_lanes` Path D maps `undef` → POISON_LANE too, so
an observed `and undef, 0` is rejected (loud, never miscompiles). (a) alone does NOT satisfy Rule 6.

**(b) Pin the target CPU for optimize=true IR** (verified faithful):
1. `InteractiveUtils._dump_function_llvm(mi, src, false, #=strip=#false, #=dump_module=#true,
   #=optimize=#false, :none, params)` with code_llvm's params (`safepoint_on_entry=false,
   gcstack_arg=false`) — MUST be unstripped (without tbaa + addrspace(10), memory code optimises differently).
2. parse into an `LLVM.Context`.
3. `run!(NewPMPassBuilder + LLVM.Interop.JuliaPipeline(opt_level=2), mod,
   TargetMachine(Target(triple), triple, PINNED_CPU, ""))`.
4. emulate jl_dump_function_ir's strip: `LLVM.Interop.RemoveJuliaAddrspacesPass()`; clear all
   `LLVMInstructionGetAllMetadataOtherThanDebugLoc` kinds; erase llvm.dbg.value/declare;
   `LLVMGlobalClearMetadata` on globals/functions; `strip_debuginfo!`.
5. `string(mod)`.
Evidence: pinned-with-host-CPU reproduces native `code_llvm(optimize=true)` for 8 functions
(modulo name counters / comment lines); pinned x86-64 in the AVX-512 process ≡ `code_llvm` in a
`julia -C x86-64` process for all 8; pinned x86-64-v3 hashes identically in native, `-C x86-64-v3`,
`-C haswell`; end-to-end, all 14 gate counts reproduce `-C x86-64` exactly (fneg∘fmul 149,588).
Cost ≈0.03 s (fmul) – 0.2 s (pow) per extraction + one-off 0.7 s warm-up.

**Pinned CPU choice** (one named constant): recommend `"x86-64-v3"` on x86_64, `"generic"`
elsewhere. v3 is byte-identical to haswell/skylake for the whole soft-float family and
ls_demo_16 — the likely historical dev-host class (it didn't crash on fmul ⇒ no AVX-512;
probably Intel AVX2) ⇒ no movement on such hosts; keeps cc0.7 SLP coverage. Alternatives:
`x86-64` (fsqrt(64) 394,689 vs 724,597; ls_demo_16 3,928 unvectorised ⇒ test_cc07_repro stops
exercising cc0.7; k 8,746 vs 1,180); `x86-64-v2` (= x86-64 for soft-float, still SLP-vectorises
ls_demo_16). **The maintainer must confirm the class of the host the baselines were recorded on.**
(b) alone is insufficient (k still has poison lanes under v3).

## 4. Implementation plan
Commit 1 (a): vectors.jl four arms + header comment citing LangRef/InstSimplify; update
`_resolve_vec_lanes` docstring ("sentinel lanes propagate through lane-wise ops and fail loud
when *observed*").
Commit 2 (b): new `src/extract/target_pin.jl` (included from ir_extract.jl before sig_llvm.jl):
`_PINNED_OPT_LEVEL = 2`, `_pinned_target_cpu(triple)`, `_strip_like_jl_dump_function_ir!(mod)`,
`_optimize_pinned(raw; cpu=...)` (try/finally dispose). sig_llvm.jl: add
`(LLVM.Interop, :JuliaPipeline)`, `(LLVM.Interop, :RemoveJuliaAddrspacesPass)` to
`_SIG_LLVM_CAPABILITIES`; `_code_llvm_by_sig` optimize ⇒ unoptimised unstripped dump →
`_optimize_pinned`; optimize=false byte-identical; ArgumentError for raw && optimize.
entry.jl: `extract_parsed_ir` and `extract_ir` both use the pinned path for optimize=true
(Rule 12: one IR source). `_run_passes!` already passes no TargetMachine. No cache-key change.
Docs: worklog; BENCHMARKS (pinned CPU in header, soft_fmul note); one-line CLAUDE.md Rule 5
addendum; file `have_fma` follow-up.

## 5. Red-green tests
A. `test/test_t9rh_poison_lane_propagation.jl` — host-independent `.ll` fixtures via
`extract_parsed_ir_from_ll`: `hadd` (exact fmul idiom, a+b on Int64 edges + verify_reversibility);
`splat_shl` (k idiom, 6x); `cmp_sel` (icmp+zext+select, poison in both arms, exhaustive
65,536 UInt8 pairs vs `(y>3) ? UInt8(x<10) : y`, 320 gates); dead op (all lanes poison ⇒
empty IRInst[]); fail-loud observed (extractelement of propagated poison ⇒ ErrorException
containing "poison lane"; RED today as AssertionError); vector reduce / <N x i1> bitcast over
poison still throw; structural (no PoisonLaneSentinel in any IRInst field). RED on every host today.
B. `test/test_t9rh_pinned_target.jl` — (1) bead repro `fneg∘fmul` bit-exact, total 149,588;
soft_fma 247,398; soft_fcmp_olt 6,248 (RED on AVX-512); (2) host-independence subprocess
(`Sys.ARCH === :x86_64`): `$(Base.julia_cmd()) -C x86-64 --project=...` computes ls_demo_16
and soft_fcmp_olt totals; assert equal to in-process (RED today on any SSE4.2+ host: 3,928 vs
3,944); last `-C` wins over julia_cmd's `-C native`; check load path under Pkg.test;
(3) fidelity canary: subprocess `code_llvm(optimize=true)` of soft_fmul and k vs in-process
`_optimize_pinned(...; cpu="x86-64")`, normalised (`#NNN`, `; ` comments).
Re-run: test_controlled, test_vector_ir, test_cc07_repro, test_40ys_instanceless_callees,
test_float_circuit, test_gate_count_regression.

## 6. Risks
Julia internals (`_dump_function_llvm` arg order; "optimize = only the NewPM run"; strip set;
`julia<level=2>` pipeline string) — guard with capabilities check + canary B3. `-O1/-O3` stop
affecting Bennett (intended). Churn under v3 pin: none on Intel AVX2; Zen2/3/alderlake:
acos, asin, atan, atan2, fdiv, fsqrt, tan change; AVX-512: errors → counts, fcmp −4.
Precompile workload populates `_parsed_ir_cache` (baked into pkgimage) — now via pinned path;
sanity-check. Non-x86 → "generic", untested. `have_fma` residual.
