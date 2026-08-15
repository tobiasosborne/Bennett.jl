# R3 — The new parser/lowering/introspection stack: JuliaSyntax, JuliaLowering, Compiler-as-stdlib, and whether IRCode is a reliable compilation substrate

**Date:** 2026-08-15 · **Baseline:** Julia 1.12.5 (installed) · **Also examined:** Julia 1.13.0-rc3 (shipped 2026-08-14, one day before this report)

## 0. TL;DR answer to the core question

**No — as of August 2026, a package cannot *reliably* consume `Core.Compiler.IRCode` as a long-term compilation substrate the way it can consume LLVM IR via LLVM.jl.** Every real package that does this today (Mooncake.jl, JET.jl, Diffractor.jl, GPUCompiler.jl) pays a recurring, nontrivial "IR tax" on every Julia minor release, and the people running those packages say so explicitly and in writing. JET.jl's own README states it plainly: *"Julia's compiler plugin system is unstable and changes frequently."* Mooncake.jl needed a 91-commit PR to port its IRCode-based IR wrapper (`BBCode`) from 1.11 to 1.12, touching function renames, inference internals, and CodeInfo world-age semantics. A 2026 GitHub issue (#61711) shows that even *within* a single Julia version, load-order effects (loading the REPL stdlib) can trigger ~1,600 method invalidations for packages that subtype `AbstractInterpreter` — undermining the premise that AbstractInterpreter is a stable extension point at all.

That said, the *shape* of the instability is changing in a way relevant to a from-scratch Bennett redesign: Julia 1.12 shipped `Compiler.jl` as a real stdlib (a package-manager-addressable wrapper around `Base.Compiler`) and `@code_ircode` as a public `InteractiveUtils` macro, and 1.13-era work-in-progress (`AbstractCompilerFrontend`, `JuliaLowering.jl`) is visibly aimed at eventually making the *lowering* layer (not just IR access) into a stable, introspectable, provenance-preserving pipeline. None of that is production-ready today. It is the right thing to *watch*, not yet the right thing to *build on*.

---

## 1. Julia 1.13 status as of this report

Julia 1.13.0 is in release-candidate stage: **rc1** (2026-07-xx), **rc2**, and **rc3** (2026-08-14 06:07 UTC) have shipped; no GA tag yet as of 2026-08-15. [Discourse: rc3](https://discourse.julialang.org/t/julia-v1-13-0-rc3-is-now-available/138805), [rc2](https://discourse.julialang.org/t/julia-v1-13-0-rc2-is-now-available/138769), [rc1](https://discourse.julialang.org/t/julia-v1-13-0-rc1-is-now-available/136929). NEWS.md for 1.13 ([raw, v1.13.0-beta1](https://github.com/JuliaLang/julia/blob/v1.13.0-beta1/NEWS.md), confirmed against rc3) is comparatively thin — no "Compiler/Runtime improvements" section at all (1.12 had one; 1.13 doesn't), which is itself a signal: the interesting parser/lowering/introspection work for 1.13 mostly landed as **infrastructure/groundwork**, not user-facing NEWS-worthy features. What *is* in 1.13's NEWS.md relevant to this topic:

- `@__FUNCTION__` macro (#58940) — new, minor.
- Unicode 16/17 operator additions inherited from JuliaSyntax.jl's own PR #525 (i.e. JuliaSyntax.jl is still the vehicle for new operator syntax; confirms it's the load-bearing parser, unchanged in kind since 1.10).
- `@code_typed`/`@which`/`@edit` now accept type-annotation placeholders like `f(1, ::Float64, 3)` matching stacktrace signatures (#57909, #58222) — an introspection-ergonomics improvement, not a substrate change.
- `@code_lowered`/`@code_typed` broadcasting support improved (#58349).
- `macroexpand`/`macroexpand!` gain a `legacyscope` kwarg, explicitly flagged as **deprecating a known-buggy legacy scope-resolution pass** — this is lowering-adjacent housekeeping ahead of a JuliaLowering transition, not a finished feature.

None of the headline "parser stuff, introspection" that JuliaCon hallway-track chatter references shows up as *shipped, user-visible* 1.13 features in NEWS.md. It shows up as **merged groundwork that isn't default-on yet** — see §3.

## 2. JuliaSyntax.jl — mature, stable, boring (in the good sense)

JuliaSyntax.jl has been Julia's default parser since 1.10 (replacing the old flisp `jl-parser.scm`). By 2026 it is not "new" in any interesting sense for this report: it's a settled, in-tree dependency that receives incremental additions (new operator glyphs per Unicode revision, per #525 above) but no architectural churn. It is not the risky part of this stack. If Bennett ever needed raw syntax-tree access (it currently doesn't — it enters at the LLVM IR / typed level), JuliaSyntax's `SyntaxNode`/green-tree API is about as stable a target as exists in this space.

## 3. JuliaLowering.jl — real, active, but explicitly pre-production

[c42f/JuliaLowering.jl](https://github.com/c42f/JuliaLowering.jl) is Claire Foster's from-scratch Julia reimplementation of Julia's own lowering passes (macro expansion → desugaring → scope analysis → closure conversion → untyped IR → `CodeInfo`), built directly on JuliaSyntax's `SyntaxTree`/`SyntaxGraph` instead of the old flisp `Expr`-based pipeline. Its own README is unambiguous about status: **"a work in progress; many types of syntax are not yet handled"**, requires a **Julia 1.13.0-DEV** build (a specific dev commit, not even rc3), and states outright: *"JuliaLowering relies on Julia internals and may be broken on the latest Julia dev version from time to time."*

The strategic direction, per the Julia blog's "This Month in Julia World" series (Dec 2025 / Jan 2026 issues):

- A merged PR introduces a **compiler frontend API that does not depend on `Expr`** for `include_string()`/`eval()` — a `TopLevelCodeIterator` interface and an `AbstractCompilerFrontend` type. ([This Month in Julia World, Jan 2026](https://julialang.org/blog/2026/02/this-month-in-julia-world/index.html))
- This is explicitly framed as **groundwork** to let JuliaSyntax+JuliaLowering become the default frontend "while preserving full expression provenance" for tools like Revise and Cthulhu, and to support **syntax versioning** (Rust-Editions-style per-module opt-in syntax versions).
- The end goal stated repeatedly across these posts is a **flisp-free bootstrap** — replacing the last flisp-implemented compiler stage with JuliaLowering.
- As of the most recent monthly roundup available (through Feb 2026), this is still **infrastructure landing incrementally**, not a flag you can flip. No target Julia version for "JuliaLowering becomes default" was found in any primary source.

**Implication:** JuliaLowering is the most exciting piece of this stack for anyone who cares about IR provenance and macro hygiene, but it is 12-24+ months from being something a production package like Bennett could depend on as its compilation substrate. It is a "track it, don't build on it yet" item.

## 4. The Compiler stdlib — `Base.Compiler` becomes package-manager-addressable

Since Julia 1.10 there has existed a `Compiler` standard library slot; **since 1.12 it supports "switching compiler implementations"** — i.e., `Compiler` is now a real, versioned package (registered, with its own `Project.toml`/UUID under `JuliaLang/BaseCompiler.jl`) that you can `]add`/pin like any dependency, rather than reaching into `Base.Compiler` directly. [docs.juliahub.com/General/Compiler](https://docs.juliahub.com/General/Compiler/stable/), [JuliaLang/BaseCompiler.jl](https://github.com/JuliaLang/BaseCompiler.jl).

Critically, as of this report **the only registered release is v0.1**, which the docs describe as **"a placeholder implementation... that re-exports Base.Compiler"** — i.e. it is *not yet* a genuinely separable, independently-versioned compiler. It exists so the *machinery* for pinning/switching is in place; actual alternate-version releases (where `Compiler@0.2` might diverge meaningfully from whatever ships in the runtime, or where you could pin an older compiler against a newer Julia to dodge a breaking change) don't exist yet. `InteractiveUtils.@activate Compiler` is needed to make reflection tools (`@code_typed` etc.) target a non-Base `Compiler` implementation when one is loaded.

**Why this matters for the core question:** this is the *single most structurally significant* difference between "depend on LLVM IR via LLVM.jl" and "depend on IRCode via Core.Compiler" going forward. LLVM.jl extraction has no analogous pinning mechanism — you get whatever LLVM version ships bundled with your Julia binary, full stop (this is explicitly Bennett's own CLAUDE.md rule 5: "LLVM IR is not stable... never assume specific IR formatting"). A mature `Compiler` stdlib would let a package pin `Compiler@x.y` in `Project.toml` exactly like any other dependency, decoupling "IRCode's shape" from "which Julia binary the user has installed." **That mechanism is the theoretical fix for the stability problem — but it isn't real yet.** v0.1-as-placeholder means today it buys you nothing beyond a fancier import path.

## 5. `code_ircode` / `@code_ircode` — a public window onto an unstable structure

`InteractiveUtils.@code_ircode` was added in Julia 1.12 via [PR #56390](https://github.com/JuliaLang/julia/pull/56390), giving a documented, exported entry point to `Core.Compiler.IRCode` alongside the long-standing `@code_typed`/`@code_lowered`/`@code_llvm` family. `CompilerPluginTools.jl` (JuliaCompilerPlugins org) builds a small library of helpers on top (`code_ircode_by_mi`, `code_ircode_by_signature`, `@make_ircode`, custom-interpreter scaffolding) aimed at people writing compiler plugins, but its own docs make no claim of insulating callers from `Core.Compiler` churn — it "tracks Julia's internal compiler APIs closely rather than providing cross-version compatibility" (assessed from its docs page, no explicit compat-shim language found: [docs](https://juliacompilerplugins.github.io/CompilerPluginTools.jl/dev/)).

The distinction worth internalizing: **making `IRCode` reachable via a documented macro is an ergonomics/discoverability improvement, not a stability contract.** `IRCode`'s field layout, `AbstractInterpreter` interface methods, and inference internals remain governed by no semver-like promise — Julia's own devdocs and community discussion (e.g. [discourse #48819, "RFC: marking private and public APIs"](https://github.com/JuliaLang/julia/discussions/48819)) confirm the ecosystem is still working out what "public API" even means for compiler-adjacent symbols; `Core.Compiler` was not resolved as "public" by that discussion.

## 6. AbstractInterpreter in practice — two concrete 2026 data points

**(a) Cross-version breakage, quantified.** [Mooncake.jl PR #714](https://github.com/chalk-lab/Mooncake.jl/pull/714), "Add Julia v1.12 compatibility," is the best available primary-source evidence of what it actually costs to keep an IRCode-based tool alive across one Julia minor bump. Mooncake maintains `BBCode` — "`Core.Compiler.IRCode` plus names for every line and basic block" — as its AD compilation substrate. Porting it from 1.11 to 1.12 required (per the PR's own commit history, ~91 commits):
- `inlining_policy` renamed to `src_inlining_policy`, **and its required return type changed** (must now always return a `Bool`).
- `CC.add_edges_impl!` interface extension needed for a new "stackless inference" implementation built on `CC.Future`.
- `_ir_abstract_constant_propagation` relocated/renamed internally.
- Opaque-closure construction semantics changed.
- **Binding partitions became lazily populated**, affecting `GlobalRef` resolution.
- `CodeInfo` now requires explicit world-age bounds to be set.
- `invoke` gained support for `CodeInstance` arguments requiring new handling.

This is not a fringe or careless package — Mooncake is chalk-lab's flagship AD engine, well-staffed, well-tested (DIT test suite). It still needed a 91-commit adaptation pass for one minor version. That is the realistic cost model for "consume IRCode as your substrate."

**(b) Even same-version stability is shaky.** [Julia issue #61711](https://github.com/JuliaLang/julia/issues/61711) (2026): packages defining a custom `Core.Compiler.AbstractInterpreter` subtype and exercising it during precompilation see **~1,600 method-instance invalidations the moment a user's session loads the `REPL` stdlib** — even though nothing about the package itself changed. Root cause is load-order coupling between `REPL`'s own definitions and previously-established compiler/inference state. Reported against `cuTile.jl`; `JET.jl` flagged as plausibly affected. The practical workaround (import `REPL` inside your own package to force load order) is a workaround, not a fix, and it signals that `AbstractInterpreter` extension is *not* a hermetic, well-isolated extension point even in the same Julia binary.

## 7. What today's IRCode-consuming packages actually say about it

- **JET.jl** ([README](https://github.com/aviatesk/JET.jl)): *"due to JET's tight integration with the Julia compiler, the results presented by JET can vary significantly depending on the version of Julia you are using"* and, more bluntly, **"Julia's compiler plugin system is unstable and changes frequently."** Its policy is to cap supported Julia versions per release ("the latest release series, v0.12, supports full JET functionality on Julia v1.12 and v1.13 only") and to have the Julia General registry apply compat caps retroactively to older JET releases as new Julia versions ship. This is the honest, mature-project answer to "can you build reliably on IRCode": *you can, if you accept a standing maintenance burden and a compat matrix that requires active curation on every Julia release, forever.*
- **Mooncake.jl**: see §6(a) — accepts the burden, pays it in large PRs per Julia minor.
- **Diffractor.jl**: reverse-mode was stripped out pending rework "until it can be properly implemented on top of new Julia compiler changes" (per repo history/discourse), i.e. even a JuliaLang-adjacent, compiler-team-connected AD project has had to *shed functionality* rather than keep chasing IRCode churn.
- **CassetteOverlay.jl** (JuliaDebug): experimental method-overlay mechanism, explicitly labeled experimental; no evidence found of a stability policy beyond "works on the Julia versions it's tested against."
- **GPUCompiler.jl** (JuliaGPU, backs CUDA.jl/AMDGPU.jl/Metal.jl/oneAPI.jl): the most successful long-lived consumer of Julia's compiler internals in the ecosystem, but it is maintained by people effectively embedded in the Julia compiler team's orbit, has a large dedicated maintenance budget, and still tracks new Julia releases release-by-release rather than offering forward compatibility guarantees. No evidence found of a documented cross-version IRCode-stability abstraction layer distinct from "we update GPUCompiler.jl promptly."

The pattern across every real example: **surviving on IRCode is a function of dedicated, ongoing maintenance investment, not of any stability contract that exists to be relied on.** The packages that do it well (Mooncake, GPUCompiler) do it well *because* they have people whose job is to re-port on every release, not because Julia promises them anything.

## 8. Relevance to Bennett.jl

Bennett.jl's current substrate is LLVM IR via LLVM.jl's C API (`src/extract/entry.jl` calls `code_llvm(...; dump_module=true)` then walks the result through LLVM.jl's typed object API). CLAUDE.md rule 5 already states the project's operating stance: *"LLVM IR IS NOT STABLE... Always use `optimize=false` for predictable IR when testing."* The research question for the from-scratch redesign is whether swapping this for `Core.Compiler.IRCode` would be a strict improvement. Based on the evidence gathered:

**It would not, today, and probably not for the 1.13 cycle either.** Concretely:

1. **The instability is not smaller on the IRCode side — plausibly worse.** LLVM's IR format churns on LLVM's own multi-year release cadence and is *cross-language, professionally spec'd, and heavily tooled* (verifier, textual round-trip, decades of external consumers). `Core.Compiler.IRCode` churns on *Julia's* minor-release cadence (every ~6 months) and is explicitly, by Julia's own core devs' own actions and JET's own words, an internal implementation detail with no stability contract. The Mooncake 91-commit port for one version bump is a strictly worse empirical data point than anything Bennett has hit with LLVM IR to date.

2. **The one structural advantage IRCode could someday offer — version pinning via the `Compiler` stdlib — is not real yet.** `Compiler.jl` v0.1 is a placeholder that just re-exports `Base.Compiler`; there is no alternate-version release to pin *against* the runtime. This is worth re-checking in 6-12 months (watch `JuliaLang/BaseCompiler.jl` releases), but building Bennett's core substrate on a promise that isn't shipped is exactly the kind of guess CLAUDE.md rule 9/10 (research steps explicit, skepticism) warns against.

3. **IRCode is *further* from Bennett's actual needs than LLVM IR, not closer.** Bennett's lowering (`src/lowering/`) wants a small, closed, well-typed instruction set (binops, icmp, select, phi, load/store, call) with explicit bit-widths — which is exactly what LLVM IR gives cleanly today (typed values, explicit `iN` widths, a stable-per-version textual/C-API form). `IRCode`'s `Expr`/`SSAValue`/`GotoIfNot`/`PhiNode` statement forms are *higher-level and Julia-semantics-laden* (multiple dispatch, boxing, abstract types still partially present pre-lowering-to-machine-types) — Bennett would still need to lower through to concrete integer/float bit operations, arguably re-deriving a chunk of what LLVM's backend already does for free, and would do so on a *more* volatile IR.

4. **Where IRCode access genuinely helps Bennett is diagnostics/tooling, not the core pipeline.** `@code_ircode` (public since 1.12) is a nice debugging aid for comparing "what did Julia's own optimizer do with this function" against Bennett's LLVM-IR walk when chasing a lowering bug — cheap to use, zero architectural commitment, no rule-2 (3+1 agent) implications since it touches nothing in `ir_extract.jl`/`lower.jl`/`bennett_transform.jl`.

5. **JuliaLowering is the one genuinely exciting long-term signal, but it's a parser/macro-hygiene/provenance story, not a Bennett-compilation-substrate story.** Even if/when it becomes Julia's default frontend, it produces `CodeInfo` (untyped-ish, pre-inference) — Bennett needs *typed, optimized, integer-width-explicit* IR, which is downstream of inference+optimization, i.e. still `IRCode`/LLVM territory regardless of what emits the `CodeInfo` feeding into it. JuliaLowering maturing doesn't change the IRCode-stability calculus in §1-4.

**Recommendation for the from-scratch redesign:** keep LLVM IR (via LLVM.jl) as Bennett's compilation substrate for the 1.13 cycle. It is the empirically better-trodden path (GPUCompiler.jl/CUDA.jl-scale precedent working reliably across Julia versions specifically *because* LLVM IR extraction sidesteps `Core.Compiler` churn) and CLAUDE.md's own rule 5 already encodes the correct defensive posture (`optimize=false`, IR-extract layer as sole source of truth, adapt when LLVM changes). File a low-priority tracking bead to re-run this evaluation when either (a) `Compiler.jl` ships a real non-placeholder release with documented version-pinning semantics, or (b) JuliaLowering.jl reaches a stated "recommended for production use" milestone — whichever comes first. Neither condition is close as of August 2026.

## Sources

- [Julia v1.13.0-rc3 announcement](https://discourse.julialang.org/t/julia-v1-13-0-rc3-is-now-available/138805) / [rc2](https://discourse.julialang.org/t/julia-v1-13-0-rc2-is-now-available/138769) / [rc1](https://discourse.julialang.org/t/julia-v1-13-0-rc1-is-now-available/136929)
- [Julia 1.13 NEWS.md (v1.13.0-beta1, cross-checked vs rc3)](https://github.com/JuliaLang/julia/blob/v1.13.0-beta1/NEWS.md)
- [Julia 1.12 NEWS.md (release-1.12 branch)](https://github.com/JuliaLang/julia/blob/release-1.12/NEWS.md)
- [Julia 1.12 Highlights blog post](https://julialang.org/blog/2025/10/julia-1.12-highlights/index.html)
- [This Month in Julia World — January 2026](https://julialang.org/blog/2026/02/this-month-in-julia-world/index.html)
- [c42f/JuliaLowering.jl README](https://github.com/c42f/JuliaLowering.jl)
- [Compiler.jl stdlib docs (JuliaHub)](https://docs.juliahub.com/General/Compiler/stable/)
- [JuliaLang/BaseCompiler.jl](https://github.com/JuliaLang/BaseCompiler.jl)
- [InteractiveUtils `@code_ircode` PR #56390](https://github.com/JuliaLang/julia/pull/56390)
- [Julia issue #61711 — REPL stdlib causes invalidations in code relying on AbstractInterpreter](https://github.com/JuliaLang/julia/issues/61711)
- [Mooncake.jl PR #714 — Add Julia v1.12 compatibility](https://github.com/chalk-lab/Mooncake.jl/pull/714)
- [Mooncake.jl discussion #136 — Internal Design](https://github.com/chalk-lab/Mooncake.jl/discussions/136)
- [JET.jl README](https://github.com/aviatesk/JET.jl)
- [Diffractor.jl repo/README](https://github.com/JuliaDiff/Diffractor.jl)
- [CassetteOverlay.jl repo](https://github.com/JuliaDebug/CassetteOverlay.jl)
- [CompilerPluginTools.jl docs](https://juliacompilerplugins.github.io/CompilerPluginTools.jl/dev/)
- [GPUCompiler.jl repo](https://github.com/JuliaGPU/GPUCompiler.jl)
- [Julia discussion #48819 — RFC: marking private and public APIs](https://github.com/JuliaLang/julia/discussions/48819)
- Local: `/home/tobias/Projects/Bennett.jl/src/extract/entry.jl` (current LLVM.jl-based extraction), `/home/tobias/Projects/Bennett.jl/CLAUDE.md` rule 5 (LLVM IR stability stance)
