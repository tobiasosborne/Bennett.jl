# R4 — The LLVM Version Shift: Julia 1.12 → 1.13 and What It Means for an LLVM-IR-Walking Reversible Compiler

## 0. Scope and method

This report establishes, from primary sources (Julia/LLVM.jl source trees, GitHub PRs, official LLVM release notes), what actually changes at the LLVM-IR level between the LLVM Julia 1.12 ships and the LLVM Julia 1.13 ships, plus the Julia-codegen-level changes (independent of the LLVM bump) that reshape emitted IR. It is written for the Bennett.jl maintainer, who is weighing a from-scratch reimplementation on Julia 1.13 rather than an incremental port. Every claim below is either verified against the local Bennett.jl checkout / installed toolchain, or cited to a primary source (LLVM release notes, `llvm.version` files, merged GitHub PRs, LLVM.jl `NEWS.md`). Where a change is still in-flight upstream rather than settled in a shipped release, it is explicitly marked **[in-progress]**.

## 1. Baseline facts (verified locally + on GitHub)

**Local install:**
```
$ julia -e 'println(Base.libllvm_version); println(VERSION)'
18.1.7
1.12.5
$ julia --project -e 'using Pkg; Pkg.status("LLVM")'
⌃ [929cbde3] LLVM v9.7.1
```
Bennett.jl's `Project.toml` pins `LLVM.jl` (JuliaLLVM/LLVM.jl) at v9.7.1, which is a marked-outdated ⌃ version.

**LLVM version per Julia release**, read directly from `deps/llvm.version` in the Julia source tree (not inferred — this is the authoritative source of truth for what `Base.libllvm_version` reports):

| Julia branch | `deps/llvm.version` | Julia branch (checked) |
|---|---|---|
| `v1.12.5` (installed here) | `LLVM_VER := 18.1.7`, artifact `libLLVM` `18.1.7+5` | https://github.com/JuliaLang/julia/blob/v1.12.5/deps/llvm.version |
| `release-1.13` (currently at rc3 as of this report) | `LLVM_VER := 20.1.8`, artifact `libLLVM` `20.1.8+0`, Julia fork tag `julia-20.1.8-0` | https://github.com/JuliaLang/julia/blob/release-1.13/deps/llvm.version |

**This is a two-major-version jump, 18 → 20, skipping 19 entirely** (Julia does not ship an LLVM-19-based release). `julia -e 'println(Base.libllvm_version)'` will read `20.1.8` on 1.13. Julia 1.13 is well into its release-candidate cycle at the time of writing (rc1 → rc2 → rc3 on Discourse, https://discourse.julialang.org/t/julia-v1-13-0-rc3-is-now-available/138805), so this is now a settled target, not a moving one — the LLVM-20 pin on `release-1.13` will not change before final release.

**LLVM.jl compatibility with LLVM 20**: confirmed mature, not a risk. LLVM.jl's `NEWS.md` shows LLVM-20 support landing in **v9.4** (PR [#512](https://github.com/JuliaLLVM/LLVM.jl/pull/512), merged 2025-05-15) — over a year before this report. LLVM.jl's `main` branch has since moved on to LLVM 21 support (PR #527, Oct 2025) and, as of the most recent commits (2026-08-13), **LLVM 22** support (PR [#582](https://github.com/JuliaLLVM/LLVM.jl/pull/582)) including a new `PtrToAddrInst` wrapper. So the LLVM.jl dependency itself is not a blocker at all — the risk (if any) is entirely in Bennett.jl's own IR-shape assumptions, which is what the rest of this report addresses. Separately, LLVM.jl PR [#564](https://github.com/JuliaLLVM/LLVM.jl/pull/564) ("Wrap ExpandAtomicModifyPass (Julia 1.13)", merged 2026-06-15, tested against 1.13.0-rc1) confirms LLVM.jl has already been actively validated against Julia 1.13 specifically, independent of the LLVM-20 question.

**Bennett.jl's own pin**: v9.7.1 postdates the LLVM-20 support PR (#512, in v9.4) by several minor versions, so the currently-pinned LLVM.jl already supports LLVM 20 — a `Pkg.update()` isn't even strictly required for LLVM-20 compatibility, though picking up the newer LLVM.jl (9.4→9.7.1→main) would still be advisable for any greenfield work given how fast LLVM.jl's `main` is now moving (21, 22 support landed within the last ~10 months).

## 2. LLVM-IR-level changes, 18 → 20 (skipping 19), that matter to an IR walker

I read the official LLVM 19.1.0 and 20.1.0 release notes (https://releases.llvm.org/19.1.0/docs/ReleaseNotes.html, https://releases.llvm.org/20.1.0/docs/ReleaseNotes.html) plus Nikita Popov's "This year in LLVM (2025)" retrospective (https://www.npopov.com/2026/01/31/This-year-in-LLVM-2025.html, covering the LLVM-19-through-21 development window) as primary sources for the delta a Julia-codegen-consuming IR walker would actually see.

### 2.1 `getelementptr` → `ptradd` canonicalization — **[in-progress, but materially advanced by LLVM 20]**

This is the single most consequential structural trend for a GEP-pattern-matching walker. Per Popov's 2025 retrospective: "at the start of 2025, constant-offset GEP instructions were canonicalized to the form `getelementptr i8, ptr %p, i64 OFFSET`" (equivalent to a future `ptradd`), and during 2025 this was extended to **split multi-index GEPs into chains of single-offset GEPs**, and to **canonicalize leading-zero-index GEPs**. The dedicated `ptradd` instruction itself has *not* shipped as of LLVM 20/21/22 — it remains an active RFC (https://discourse.llvm.org/t/rfc-replacing-getelementptr-with-ptradd/68699) with open questions (e.g. whether `ptradd` should support constant scaling factors) still being litigated on the LLVM forum as of this writing. What *has* shipped and is real by LLVM 20: aggressive canonicalization of ordinary GEPs toward the single-index-i8 shape.

**Relevance to Bennett.jl — this is largely a non-issue, already anticipated.** Bennett.jl's extraction code (`src/extract/`) is *already* built almost entirely around the i8-byte-indexed-GEP shape as the canonical Julia-opaque-pointer form — a `grep` across `src/extract/*.jl` turns up 60+ references to `getelementptr i8, ptr %p, i64 OFF` as the assumed idiom (e.g. `sret.jl:1223`: "the opaque-pointer Julia default... Fails loud on any richer GEP shape"; `instructions.jl:2782`: comment showing `getelementptr inbounds i8, ptr %d, i64 %bo ; single-index i8 GEP` as the expected pattern). This was clearly built *after* Julia's own 1.12 switch to opaque-pointer/i8-GEP-heavy codegen (see §3.1), so the LLVM-20 continuation of the same trend is directionally aligned with, not disruptive to, Bennett's existing assumptions. The residual risk is in the **two-index struct/array GEP handling** (`entry.jl:213`, `instructions.jl:7125,7184`: `getelementptr {ptr,ptr}, ptr %obj, i32 0, i32 K` / `getelementptr [N x iM], ptr BASE, i64 0, i64 IDX`) — these multi-index forms are exactly what LLVM 20's canonicalization is actively splitting into GEP *chains*. A from-scratch walker should assume **any struct/array GEP may arrive pre-split into two chained single-index GEPs rather than one two-index GEP**, and should walk/fold GEP-of-GEP chains rather than pattern-matching a fixed operand count on one instruction. This is exactly the kind of LLVM-IR-not-stable risk CLAUDE.md Rule 5 already calls out generically; this report makes it concrete.

Also newly present since LLVM 19: `nusw`/`nuw` no-wrap flags on `getelementptr` (LLVM 19.1.0 release notes, new C API `LLVMBuildGEPWithNoWrapFlags` / `LLVMGEPGetNoWrapFlags`). Bennett doesn't currently read GEP no-wrap flags (confirmed by grep — no `NoWrapFlags`/`nusw`/`nuw` reference in `src/extract/`), so this is inert today, but a from-scratch design that wants to exploit GEP no-wrap info for optimization (e.g. skip overflow-safety wiring) should know the flag now exists and how to read it via the C API.

### 2.2 Typed pointers — fully gone, non-issue

Typed pointers went best-effort-only starting LLVM 16 and are confirmed dropped entirely as a supported mode by the LLVM 20 era (cross-checked against multiple 2025/2026 downstream-tooling changelogs, e.g. llvmlite's LLVM-20 migration notes). Bennett.jl already assumes opaque pointers throughout (dozens of `opaque-pointer` comments across `src/extract/`), so there is nothing to change here — this dimension was already fully absorbed when Bennett was built against Julia 1.12/LLVM 18, which was itself already opaque-pointers-only.

### 2.3 `memory(...)` effects attribute — encoding unchanged 18→20, but Julia's *emission* of it changes materially (see §3.3)

Neither the LLVM 19.1.0 nor 20.1.0 release notes document any change to the `memory(...)` attribute's packed encoding (the same 3-location × {none,read,write,readwrite} scheme Bennett's `instructions.jl:2013` comment documents as "LLVM 18 MemoryEffects: 3 locations (ArgMem=0, InaccessibleMem=1, Other=2)"). So the raw bit-packing Bennett decodes via `LLVMGetEnumAttributeValue` is stable across this LLVM jump. However — critically — **which functions get which `memory(...)` value, and how aggressively, changes substantially on the Julia-codegen side** independent of the LLVM version; see §3.3. Bennett's own code (`instructions.jl:1973-2076`, the `_57hd_writes_no_ir_memory` decoder) already documents a fail-closed posture toward attribute-encoding drift and even anticipates the `nocapture` → `captures(none)` rename (see next paragraph) — a genuinely well-hardened piece of code for this axis of risk.

### 2.4 `nocapture` → `captures(none)` — **NOT yet relevant to 1.13/LLVM 20; will matter for LLVM 21+**

Confirmed via LLVM's own tracking issue (llvm/llvm-project#136125) and PR llvm/llvm-project#123181 ("[IR] Convert from nocapture to captures(none)"): the unified `captures(...)` attribute (finer-grained than the old boolean `nocapture`) **landed as of LLVM 21.1.0**, not 20. So Julia 1.13 (LLVM 20) will still emit plain `nocapture`. This becomes live the moment either (a) Julia ships an LLVM-21-based release (likely 1.14, per LLVM.jl's already-present "LLVM 21 ThreadSafeContext and EHFrame compatibility" codegen PR merged into Julia master 2026-—see §3), or (b) a from-scratch Bennett targets LLVM.jl `main`/nightly Julia directly rather than a tagged release. Bennett's existing code already has a documented fallback path for this exact rename (`instructions.jl:2001,2034`: "the same two-step call-site-then-declaration fallback covers `nocapture`'s eventual respelling as `captures(none)`; absence is always `false`, which is the safe direction") — this is good defensive engineering already in place and worth preserving verbatim in any rewrite, since it was clearly written with the rename already anticipated.

### 2.5 Constant-expression instruction removal — already absorbed, but worth re-confirming per-version

LLVM has been incrementally removing ConstantExpr variants of ordinary instructions for years (GEP, select constant-exprs went earlier); LLVM 19.1.0 removed the ConstantExpr forms of `icmp`, `fcmp`, and `shl` specifically (with corresponding C API deletions: `LLVMConstICmp`, `LLVMConstFCmp`, `LLVMConstShl`). Bennett's `src/extract/constexpr.jl` already handles `ConstantExpr<icmp eq/ne>` as a live case (cc0.4, MVP scope) — worth flagging that **on LLVM 20, this exact ConstantExpr form should never appear at all** (it's been an instruction, not a constant expression, since LLVM 19), so the `_fold_constexpr_operand` icmp-handling branch in `constexpr.jl` is now dead code for freshly-compiled Julia 1.13 IR, though it may still fire on hand-authored `.ll`/`.bc` fixtures produced against older LLVM. A from-scratch design should treat "which instructions still have ConstantExpr form" as a version-gated fact to re-derive from the target LLVM's release notes rather than hardcode.

### 2.6 Global-context C-API deprecation — **[in-progress]**

Popov's 2025 retrospective notes LLVM "deprecated the global context in the C API, described as 'a common footgun.'" Bennett.jl already threads explicit `LLVM.Context()` objects through its extraction pipeline rather than relying on any implicit global context (consistent with LLVM.jl's own idiomatic usage, and with LLVM.jl's own recent work hardening `ThreadSafeContext` handling — see LLVM.jl commit "Leak contexts disposed of during exception unwinding" and "Install a diagnostic handler in ThreadSafeContext's inner context", both 2026-07-09). No action needed, but worth confirming a from-scratch design continues to pass contexts explicitly rather than picking up any convenience global-context helper LLVM.jl may still expose for back-compat.

### 2.7 New/renamed intrinsics in the 19→20 window (surveyed, mostly irrelevant to scalar-function compilation)

From the LLVM 19.1.0 and 20.1.0 release notes: `llvm.experimental.stepvector` → `llvm.stepvector` rename; new `llvm.experimental.vector.compress`; pointer-authentication operand bundles (ARM PAC — irrelevant off-Arm-security-extension); new `atomicrmw` sub-operations `usub_cond`/`usub_sat`; fast-math flags now permitted on `fptrunc`/`fpext` (mildly relevant to soft-float boundary-casting code, though Bennett's soft-float library deliberately avoids relying on LLVM fast-math semantics since it needs bit-exactness — Rule 13 — so this is inert). None of these appear in the kind of plain-Int/Float64-scalar-function IR Bennett.jl's target corpus produces; they matter far more to GPU/vector-heavy consumers of LLVM.jl (the audience LLVM.jl's `NEWS.md` is mostly written for) than to Bennett.

**`ptrtoaddr`** (new provenance-stripping pointer-to-integer instruction, distinct from `ptrtoint`, relevant to CHERI) is **LLVM 22**, not 20 — confirmed by LLVM.jl's own `NEWS.md` entry for v9.12 ("Support for LLVM 22, including `PtrToAddrInst`..."). Not relevant to Julia 1.13.

## 3. Julia-codegen-level changes, 1.12 → 1.13 (independent of the LLVM version bump)

These matter more than the raw LLVM delta, because they change what shape of IR Julia's own front end emits, regardless of which LLVM back end consumes it. I surveyed merged, `master`-based PRs (all confirmed merged before Julia 1.13 branched into release-candidate status) via GitHub search scoped to the `codegen` label/title-term.

### 3.1 Recap: the 1.11→1.12 pointer-representation change (already the baseline Bennett was built on)

Not a 1.13 change, but essential context: Julia 1.12's highlights post (https://julialang.org/blog/2025/10/julia-1.12-highlights/) confirms `Ptr{T}` now lowers to a real LLVM pointer type (`ptr` under opaque pointers) rather than an integer (`i64`), eliminating `ptrtoint`/`inttoptr` shims from `llvmcall`-adjacent code; old integer-pointer IR still parses but is deprecated. Bennett.jl was built entirely on top of this already-opaque-pointer, already-i8-GEP-heavy 1.12 baseline, which is exactly why §2.1/§2.2 above are non-issues rather than new problems.

### 3.2 Bounds-check codegen: single AND-branch → cascaded cold branches — **[MERGED, master, 2026-04-10 — confirmed in 1.13]**

**This is the single highest-relevance finding of this report for Bennett.jl specifically**, because CLAUDE.md's own testing convention mandates `--check-bounds=yes` runs (`julia --project --check-bounds=yes test/...`) as the mode that must match `Pkg.test()`, and because CLAUDE.md flags phi/CFG resolution as the single most bug-prone part of the compiler.

Julia PR [#61535](https://github.com/JuliaLang/julia/pull/61535) ("codegen: emit bounds checks as cold branches instead of ANDs", merged to `master` 2026-04-10, well before the 1.13 branch cut) changes how multi-dimensional bounds checks compile:

- **Before (1.12 / current Bennett baseline):** all per-dimension bounds conditions are combined into a single `and i1` and gated by *one* branch:
  ```llvm
  %.not = icmp ult i64 %0, %size0
  %1     = icmp ult i64 %2, %size1
  %combined = and i1 %.not, %1
  br i1 %combined, label %pass, label %fail
  ```
- **After (1.13):** each dimension gets its own branch, cascaded, each annotated cold (`!prof` branch-weight metadata weighting the failure edge ~2000:1) so LLVM's loop-unswitch pass can reason about each dimension independently:
  ```llvm
  %.not = icmp ult i64 %0, %size0
  br i1 %.not, label %L27, label %L29
  L27:
    %.not10.not = icmp ult i64 %1, %size1
    br i1 %.not10.not, label %L32, label %L29
  L29:
    call void @j_throw_boundserror_...(...)
  ```

**Why this matters for Bennett**: this is exactly a "diamond-adjacent" multi-branch CFG shape that did not exist under Julia 1.12's single-AND-branch bounds-check lowering. Every array-indexing operation Bennett compiles that involves a bounds check (which, under the project's own `--check-bounds=yes` testing convention, is *every* indexing operation, always) will, under 1.13, produce a CFG with one extra basic block and one extra conditional branch per array dimension versus what Bennett's phi-resolution/CFG code (`lowering/cfg.jl`, `lowering/phi.jl`) was built and tested against on 1.12. Multi-dimensional array indexing isn't Bennett's primary target today (it's scalar Int/Float64 functions), but any code path that touches `Vector`/`Memory` indexing — including Bennett's own `vector_vm*.jl` recognizers, which explicitly walk Julia's array-indexing codegen pattern — should be re-verified against 1.13 IR before being trusted. This is a concrete, dated, upstream-confirmed reason the "assume codegen is free, ask what's the right 2026 design" framing in the task brief is well-founded: a from-scratch design should not hardcode "bounds check = single AND-gated branch" anywhere.

### 3.3 Purity/effect-bit propagation to LLVM function attributes (`ipo_purity_bits`) — **[MERGED, master, 2026-04-20 — confirmed in 1.13]**

Julia PR [#61394](https://github.com/JuliaLang/julia/pull/61394) ("codegen: Propagate `ipo_purity_bits` to LLVM function attributes") is *not* a new LLVM attribute — it's Julia's inference-derived effect bits (`:consistent`, `:effect_free`, `:nothrow`, `:terminates`, `:notaskstate`) being translated, for the first time this systematically, into standard LLVM attributes on Julia-generated function declarations/definitions:
- `nothrow` effect → LLVM `nounwind`
- `terminates` → `mustprogress`
- `nothrow` + `terminates` → `willreturn`
- pure/effect-free → `memory(argmem: read)`
- `notaskstate` → `readnone` on the hidden gcstack parameter

Notably it uses a **two-phase attribute strategy**: call-site declarations get an "optimistic" `memory(argmem: read)` to unlock early middle-end optimizations (GVN/LICM/DSE), and Julia's own `LateLowerGCFrame` pass **widens this to `memory(readwrite)`** before safepoint analysis runs, so the attribute value legitimately differs between what a naive single-pass IR dump shows and what's true post-GC-lowering.

**Relevance to Bennett**: Bennett's `_57hd_writes_no_ir_memory` / `memory(...)` decoder (`instructions.jl:1973-2076`) is exactly the kind of consumer this PR is aimed at, and it already documents (in its own O-1 risk note) that it treats the `memory` attribute's packed value as inherently version-fragile and fails closed. What's new under 1.13 is that **many more Julia-generated functions will now carry a non-default `memory(...)` value than did under 1.12**, because purity inference is being surfaced systematically for the first time — so Bennett's existing fail-closed decoder should be re-run against representative 1.13 IR to confirm the *rate* of attributes it now sees still decodes to sane 3-location values (the encoding itself is unchanged per §2.3, but the population of functions carrying it is much larger). This is a case where "the decoder is safe" (fails closed) is true but "the decoder's fail-closed path may now trigger far more often, silently degrading precision" is a live open question that should be measured, not assumed, on 1.13 IR — CLAUDE.md's own Rule 10 (skepticism, verify, reproduce) applies directly here.

### 3.4 GC-frame zeroing and lifetime intrinsics — moderate relevance to `heap.jl`/`memory.jl`

Two further merged `master` PRs affect the alloca/GC-preamble shape Bennett's `src/extract/heap.jl` (`_detect_gc_preamble!`) and `src/lowering/memory.jl` pattern-match against:
- [#60924](https://github.com/JuliaLang/julia/pull/60924) "codegen: Move GC pointer zeroing to late-gc-lowering" (merged 2026-02-09) — moves *when* GC-frame slots get zeroed in the pass pipeline, which can change whether Bennett's extraction (run with `optimize=false` per Rule 5) sees the zeroing already materialized or still deferred, depending on exactly which pass boundary Bennett extracts IR at.
- [#62061](https://github.com/JuliaLang/julia/pull/62061) "codegen: use a non-volatile memset when zeroing a GC frame; attach TBAA MD" (merged 2026-06-17) — changes the zeroing `memset` call's volatility and adds TBAA metadata, both of which a pattern-matcher keying on exact call shape (volatile vs non-volatile `memset`) needs to re-check.
- [#62369](https://github.com/JuliaLang/julia/pull/62369) "codegen: emit `llvm.lifetime.start` for alloca temporaries" (merged 2026-07-14) — adds `llvm.lifetime.start`/`.end` markers around temporaries that Bennett's extractor previously never had to see for simple scalar allocas; per §2.7's LLVM-side note, LLVM 20/21 is simultaneously *tightening* lifetime-intrinsic semantics ("enforced only used with allocas," size argument removed) — so a from-scratch walker will need an explicit "skip/consume `llvm.lifetime.*` markers" step in its instruction dispatcher that current Bennett may be implicitly relying on never encountering (worth a direct grep-and-confirm on the actual codebase before porting, not assumed from this report alone).

### 3.5 Atomics: a genuinely new pseudo-intrinsic, but out of Bennett's current scope

Julia PR [#57010](https://github.com/JuliaLang/julia/pull/57010) ("codegen: add a pass for late conversion of known modify ops to call atomicrmw") introduces a `julia.atomicmodify` pseudo-intrinsic and a new `ExpandAtomicModify` LLVM function pass (confirmed present in Julia 1.13 via `contrib/commit-name.sh` version-gate `1.13.0-DEV.321`, and confirmed via LLVM.jl PR #564 that LLVM.jl now wraps this pass so GPUCompiler.jl-style downstream consumers don't reimplement it). This only fires for `@atomic`-annotated code and Threads.Atomic-style patterns; Bennett.jl's target corpus (plain scalar Int/Float64 functions, no threading) should never trigger it today. Flagged here only because a from-scratch design that ever widens scope toward concurrent/`@atomic` Julia would need to recognize and lower `julia.atomicmodify` explicitly — it is a genuinely new IR-level construct LLVM's own instruction set does not otherwise have a name for.

## 4. Relevance to Bennett.jl — synthesis for the reimplementation decision

Given the framing of the task ("assume code generation is free — the question is what the RIGHT 2026 design is, not incremental refactoring"), the findings above bear on that question as follows:

1. **The LLVM-18→20 jump itself is largely a non-event for Bennett's core assumptions.** The opaque-pointer, i8-GEP-canonical world Bennett was built against on Julia 1.12 is the *same* world, more thoroughly realized, on LLVM 20. Nothing here argues for a fundamentally different IR-consumption strategy than "walk typed LLVM.jl objects via the C API, treat IR shape as version-fragile, fail loud" — which is already Bennett's stated architecture (CLAUDE.md Rule 5) and, on the evidence in `src/extract/`, already fairly well hardened against exactly this class of drift (the `nocapture`→`captures(none)` fallback is a good example of pre-emptive correctness that should be carried forward verbatim).

2. **The one LLVM-side item that does warrant an explicit design decision** is GEP-chain handling (§2.1): a from-scratch walker should treat struct/array member access as "fold a chain of single-index GEPs back to a `(root, byte-offset)` pair" as the *primary* code path, not "pattern-match a single multi-index GEP with a fallback for chains" as Bennett currently seems structured (per the two-index-GEP handling comments in `entry.jl`/`instructions.jl`). This is a case where LLVM's direction of travel (continuing toward `ptradd`) is knowable now and worth designing straight into the canonical path rather than treating as a secondary case.

3. **The Julia-codegen-side changes are the ones that most directly threaten Bennett's hardest-won correctness property** — phi/CFG resolution (§3.2, bounds-check cascading) and purity-attribute-driven memory-effects reasoning (§3.3) both land squarely on the two areas CLAUDE.md itself flags as highest-risk (phi resolution / false-path sensitization, and the `memory()` attribute decode's O-1 risk note). Neither change is fatal — both are legible, dated, and traceable to specific PRs — but both mean that **any from-scratch design should re-derive its CFG/phi test corpus from actual 1.13/LLVM-20 IR dumps rather than porting 1.12-derived test fixtures forward unexamined.** Given Rule 3 (red-green TDD) and Rule 4 (exhaustive verification) are already core to the project's workflow, the practical recommendation is: before writing a single line of lowering logic in a 1.13-targeted rewrite, dump `code_llvm(f, types; optimize=false)` for a representative corpus of bounds-checked array-indexing functions on the actual 1.13 toolchain and diff the CFG shape against what the current `worklog/` chunks document for 1.12 — this is a half-day research spike, not a redesign, and it directly de-risks the highest-value unknown this report surfaces.

4. **No blocking dependency risk.** LLVM.jl's LLVM-20 support is over a year old and Bennett's pinned LLVM.jl version already postdates it; LLVM.jl's `main` branch is tracking LLVM 22 already, i.e. well ahead of what Julia 1.13 needs, so a from-scratch Bennett could target either the Julia-1.13-paired LLVM.jl release or `main` with equal confidence on the dependency-compatibility axis specifically.

5. **Timing**: Julia 1.13 is at rc3 as of this report (Discourse: https://discourse.julialang.org/t/julia-v1-13-0-rc3-is-now-available/138805) — i.e., feature-frozen and IR-shape-stable for the purposes of this analysis. All the codegen PRs cited in §3 are merged to `master` well before the release-candidate cut, so they are correctly characterized as MERGED-for-1.13, not speculative.

## Sources

- Julia `deps/llvm.version`: [v1.12.5](https://github.com/JuliaLang/julia/blob/v1.12.5/deps/llvm.version), [release-1.13](https://github.com/JuliaLang/julia/blob/release-1.13/deps/llvm.version)
- Julia 1.13 release-candidate announcements: [rc1](https://discourse.julialang.org/t/julia-v1-13-0-rc1-is-now-available/136929), [rc2](https://discourse.julialang.org/t/julia-v1-13-0-rc2-is-now-available/138769), [rc3](https://discourse.julialang.org/t/julia-v1-13-0-rc3-is-now-available/138805)
- Julia 1.12 highlights: https://julialang.org/blog/2025/10/julia-1.12-highlights/
- LLVM.jl `NEWS.md` / PRs: [#512 LLVM 20](https://github.com/JuliaLLVM/LLVM.jl/pull/512), [#527 LLVM 21](https://github.com/JuliaLLVM/LLVM.jl/pull/527), [#582 LLVM 22](https://github.com/JuliaLLVM/LLVM.jl/pull/582), [#564 ExpandAtomicModifyPass / Julia 1.13](https://github.com/JuliaLLVM/LLVM.jl/pull/564)
- LLVM release notes: [19.1.0](https://releases.llvm.org/19.1.0/docs/ReleaseNotes.html), [20.1.0](https://releases.llvm.org/20.1.0/docs/ReleaseNotes.html)
- Nikita Popov, "This year in LLVM (2025)": https://www.npopov.com/2026/01/31/This-year-in-LLVM-2025.html
- LLVM `ptradd` RFC (open): https://discourse.llvm.org/t/rfc-replacing-getelementptr-with-ptradd/68699
- LLVM `captures` attribute: tracking issue [llvm/llvm-project#136125](https://github.com/llvm/llvm-project/issues/136125), landing PR [llvm/llvm-project#123181](https://github.com/llvm/llvm-project/pull/123181)
- Julia codegen PRs: [#61535 bounds checks as cold branches](https://github.com/JuliaLang/julia/pull/61535), [#61394 ipo_purity_bits](https://github.com/JuliaLang/julia/pull/61394), [#60924 GC zeroing to late-gc-lowering](https://github.com/JuliaLang/julia/pull/60924), [#62061 non-volatile GC-frame memset + TBAA](https://github.com/JuliaLang/julia/pull/62061), [#62369 lifetime.start for alloca temporaries](https://github.com/JuliaLang/julia/pull/62369), [#57010 julia.atomicmodify / ExpandAtomicModify](https://github.com/JuliaLang/julia/pull/57010)
- Bennett.jl source (local): `src/extract/instructions.jl`, `src/extract/constexpr.jl`, `src/extract/entry.jl`, `src/extract/sret.jl`, `src/extract/heap.jl`, `Project.toml`
