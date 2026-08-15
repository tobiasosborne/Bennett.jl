# Julia 1.13 — Release Status and NEWS.md Sweep (as of 2026-08-15)

Research memo for the Bennett.jl "from-scratch on 1.13" design question.
All facts below are sourced against primary sources (GitHub raw files, GitHub
REST API, Discourse) fetched live on 2026-08-15; each claim is tagged
**[MERGED-1.13]**, **[1.14-dev / future]**, or **[process/meta]**.

---

## 1. Release status: branched, feature-frozen, in late RC — NOT yet GA

Primary evidence, `https://api.github.com/repos/JuliaLang/julia/releases`:

| Tag | Published (UTC) | prerelease |
|---|---|---|
| `v1.13.0-beta1` | 2026-01-13 | true |
| `v1.13.0-beta2` | 2026-02-05 | true |
| `v1.13.0-beta3` | 2026-03-17 | true |
| `v1.13.0-rc1`   | 2026-04-29 | true |
| `v1.12.6`       | 2026-04-10 | **false** (1.12 patch, released *after* 1.13-beta3, confirms 1.12 is the stable line while 1.13 stabilizes) |
| `v1.13.0-rc2`   | 2026-08-13 | true |
| `v1.13.0-rc3`   | 2026-08-14 | true |

Source: [github.com/JuliaLang/julia/releases](https://github.com/JuliaLang/julia/releases), confirmed via `gh`/REST API `releases` endpoint.

- The `release-1.13` branch exists and is live (`raw.githubusercontent.com/JuliaLang/julia/release-1.13/NEWS.md` resolves). `master` has already moved on and its `NEWS.md` header reads **"Julia v1.14 Release Notes"** — i.e. 1.13 is fully branched off and master is 1.14-dev. This is unambiguous confirmation the branch cut happened.
- **~3.5-month gap between rc1 (Apr 29) and rc2 (Aug 13)** stalled the release. Per Discourse thread ["Is the development of 1.13 stuck?"](https://discourse.julialang.org/t/is-the-development-of-1-13-stuck/138693) (opened by user `ufechner7`), core contributor `dilumaluthge` gave the reason: *"We had to make significant changes to our CI infrastructure to improve security. So some of the 1.13 work has been blocked waiting on CI work."* — i.e. the delay was **infra/process, not unresolved language design**. **[process/meta]**
- rc2 → rc3 turnaround was **one day** (Aug 13 → Aug 14), rc3 fixing a macOS app-icon packaging bug (issue #62726) — evidence the tree is now essentially stable and only cosmetic/packaging issues remain.
- The `1.13` GitHub milestone (#48) shows **5 open / 46 closed** issues as of 2026-08-15. All 5 open items are non-language, non-compiler: macOS icon (#62726), a `@doc` breaking-change doc note (#61877), a compile-time regression from *alpha2* (#60313, likely stale/already fixed at rc-time), REPL history-search UX (#60144), and non-interactive precompile progress display (#59924). **None touch codegen, type system, or IR.**
- The rc1→rc2 diff is 122 commits / 210 files — normal RC-cycle bugfix backport volume (touches `Compiler/src/{abstractinterpretation,typeinfer,effects}.jl` etc., but these are backported *bugfixes* to existing 1.13 behavior, not new features — 1.13's `NEWS.md` content is unchanged between rc1 and rc3).
- Announcement: [Julia v1.13.0-rc2 is now available](https://discourse.julialang.org/t/julia-v1-13-0-rc2-is-now-available/138769) (posted 2026-08-12/13), [Julia v1.13.0-rc3 is now available](https://discourse.julialang.org/t/julia-v1-13-0-rc3-is-now-available/138805) (2026-08-14). Both carry the standard disclaimer: *"As a release candidate, 1.13.0-rc3 should not be considered production-ready."* No GA date has been announced in either thread.

**Bottom line: Julia 1.13 is feature-frozen, deep in its RC cycle (rc3, one day old), with no compiler/language-level open issues left on its milestone. A GA release plausibly lands within weeks, but is not out as of 2026-08-15.** Designing against 1.13's `NEWS.md`/`release-1.13` branch content is safe — it will not gain new language features between now and 1.13.0 final. The currently-installed toolchain on this machine is Julia **1.12.5** (confirmed via `julia --version`), i.e. one full minor behind.

---

## 2. Full sweep of 1.13's `NEWS.md` (verbatim, from `release-1.13` branch)

Fetched raw from `https://raw.githubusercontent.com/JuliaLang/julia/release-1.13/NEWS.md`. This is materially **shorter and quieter** than a typical Julia minor release — most of the diff is REPL/UX and library additions, not compiler/IR. Organized below by relevance to a package that (a) extracts LLVM IR via LLVM.jl's C API, (b) walks/lowers that IR per-instruction, (c) does its own reversible-circuit codegen and bit-vector simulation.

### 2a. Directly relevant to IR/compiler-facing code

- **`InteractiveUtils` introspection changes** (Bennett doesn't currently use `@code_typed`/`@code_lowered` directly — it uses LLVM.jl's C API — but this is the closest 1.13 gets to "compiler reflection" news):
  - *"Code introspection macros such as `@code_lowered` and `@code_typed` now have a much better support for broadcasting expressions, including broadcasting assignments of the form `x .+= f(y)`"* (#58349).
  - *"Introspection utilities such as `@code_typed`, `@which` and `@edit` now accept type annotations as substitutes for values"* — new syntax `f(1, ::Float64, 3)` (#57909, #58222). Not a breaking change; irrelevant to LLVM.jl-based extraction but signals continued modernization of the reflection layer that a future design could lean on more (see §4).
- **`macroexpand`/`macroexpand!` gain a `legacyscope` keyword** (#57137) — NEWS explicitly warns *"The legacy scope resolution code has known design bugs and will be disabled by default in a future version."* Only relevant if Bennett ever macro-expands user code pre-extraction (it currently does not — it goes through LLVM IR, not Julia AST macros), but worth knowing the macro-hygiene internals are actively being reworked upstream.
- **Nothing else in 1.13's `NEWS.md` touches `Core.Compiler`, effects analysis, `CodeInfo`/`IRCode` representation, generated functions, world age, or method tables.** This is a genuinely quiet release on the compiler-internals front (contrast with 1.9's opaque closures, 1.10's `--trim`/juliac work, or 1.12's `--trim` promotion — see §3). No NEWS entry mentions `--trim`, `juliac`, or static compilation for 1.13 at all — that workstream did not advance in the 1.13 cycle.

### 2b. Language / semantic changes (bite risk for numeric code)

- **`hash` algorithm changed for `AbstractString`** (#57509, #59691): *"The `hash(::AbstractString)` function is now a zero-copy / zero-cost function, based upon providing a correct implementation of the `codeunit` and `iterate` functions. Third-party string packages should migrate to the new algorithm by deleting their existing overrides of the `hash` function."* — Bennett doesn't hash user strings, but see §5 for one indirect touch point (`_argtype_digest` in `src/extract/julia_set.jl` hashes `DataType`s, not strings — almost certainly unaffected, but worth a one-line regression check post-upgrade since NEWS says "most notably" `AbstractString`, implying other types' hash values were not guaranteed stable either).
- **No changes to integer overflow semantics, `Int` promotion rules, or arithmetic operators in 1.13.** (The new `+%`/`-%`/`*%` wrapping-arithmetic operators are **1.14-dev only** — see §4.)
- **No type-system changes in 1.13 proper.** (The `Type{T} <: S` subtyping soundness fix is **1.14-dev only** — see §4.)

### 2c. Command-line / build

- `--sysimage-native-code=no` **deprecated** (irrelevant to Bennett — it doesn't touch sysimage build flags).
- `JULIA_CPU_TARGET` gains a `sysimage` keyword (#58970); `Sys.sysimage_target()` new public function (#58970). Marginally relevant only if a future Bennett/Sturm.jl deployment story wants to inspect/pin the CPU target used for AOT-compiled reversible circuits.
- New `--trace-eval` flag + `Base.TRACE_EVAL` for tracing top-level evaluation (#57137) — a debugging aid, not relevant to IR extraction (Bennett extracts LLVM IR post-inference, not top-level eval).

### 2d. Library-level (mostly irrelevant, noted for completeness)

`@__FUNCTION__` macro, Unicode 16/17 operator glyphs, `AbstractSpinLock`/`PaddedSpinLock`, `Base.@acquire`, `nth`, `ispositive`/`isnegative`, exported `fieldindex`, public `Base.donotdelete` (dead-code-elimination guard — mildly interesting if Bennett ever needs to pin down LLVM-side DCE behavior during IR extraction, since `optimize=false` is already Bennett's practice per CLAUDE.md rule 5), `Sys.sysimage_target()`, `Iterators.findeach`, `fieldoffset` by symbol, `Base.AbstractOneTo`, `takestring!`, `chopprefix`/`chopsuffix` char support, `LazyScopedValue`, `Base.active_manifest()`, float `mod` bugfix, `ReinterpretArray` indexless bounds-check fix, `randperm!`/`randcycle!` non-`Array` support, `shuffle(::NTuple)`, REPL UX (bracketed paste, live syntax highlighting, auto-closing brackets, fzf-style history search), `Test` module additions (`JULIA_TEST_VERBOSE`, `@test_throws` 3-arg form, `ScopedValue`-backed testset stack — mildly relevant since Bennett's 320 `test_*.jl` files use `@testset`/`@test` per CLAUDE.md rule 3), `Dates` ISO week functions, 7-Zip bump, `merge(combine, d...)` **deprecated** in favor of `mergewith`.

### 2e. Deprecated or removed (full list — only one item)

- `merge(combine::Callable, d::AbstractDict...)` deprecated → use `mergewith` (#59775). Grep `src/` for this call pattern before upgrading (quick check, not done in this research pass — flagged for the implementer).

---

## 3. What did NOT change (notable by absence)

For a package built on LLVM.jl's C-API IR walk, absence of change is itself a finding:

- **No `Core.Compiler`/`AbstractInterpreter` public-API changes** landed in 1.13's `NEWS.md` (some internal churn is visible in the rc1→rc2 diff under `Compiler/src/`, but it's bugfix backporting to existing 1.13-era code, not new-in-1.13 surface).
- **No changes to `@generated` functions, world age, or method invalidation semantics.**
- **No promotion of `--trim`/`juliac` static compilation** beyond its 1.12 experimental state (introduced 1.12: *"New experimental option `--trim` that creates smaller binaries by removing code not proven to be reachable..."*). If the Bennett→Sturm.jl story eventually wants small/static reversible-circuit binaries, `--trim` is still "experimental" as of 1.13, unchanged.
- **No opaque-closure changes**, no new intrinsic/builtin additions mentioned.

---

## 4. Major infra-level change NOT in NEWS.md: LLVM 18 → LLVM 20 bump — HIGH RELEVANCE

This is the single most consequential fact for Bennett.jl and is **absent from `NEWS.md`** entirely (Julia's `NEWS.md` essentially never documents its bundled-LLVM version bump as a user-facing entry). Found by diffing `deps/llvm.version` across release branches:

```
release-1.12/deps/llvm.version:  LLVM_VER := 18.1.7   (LLVM_ASSERT_JLL_VER := 18.1.7+5)
release-1.13/deps/llvm.version:  LLVM_VER := 20.1.8   (LLVM_ASSERT_JLL_VER := 20.1.8+0)
```

Julia 1.13 bundles **LLVM 20.1.8** (a Julia-patched fork, branch `julia-20.1.8-0`), up from LLVM 18.1.7 in 1.12/1.12.5 (the version this machine currently runs). That's a two-major-version LLVM jump, which is significant because **Bennett.jl's entire IR-extraction layer (`src/extract/`) is built directly against LLVM.jl's C-API bindings and is described in `CLAUDE.md` rule 5 as depending on IR that "is not a stable API."**

Compatibility check on **LLVM.jl** (the wrapper Bennett depends on — note it moved orgs, now `github.com/JuliaLLVM/LLVM.jl`, formerly `maleadt/LLVM.jl`):

- `LLVM.jl`'s `Project.toml` (`main` branch, fetched 2026-08-15) declares `julia = "1.10"` with **no upper bound**, `LLVM = ...` (current tagged release **v9.12.0**; Bennett's `Manifest.toml`/`Pkg.status` currently resolves **v9.7.1**, one behind).
- README states: *"LLVM.jl is supported on Julia 1.10+, and thus requires LLVM 15. However, the package is really only intended to be used with the LLVM library shipped with Julia."* — i.e. LLVM.jl's version support tracks whatever LLVM each Julia release bundles, by design.
- **LLVM.jl added LLVM 22 wrapper support on 2026-08-13** (commit *"Add LLVM 22 wrappers and instruction support"*, merged via PR #582 *"llvm22"*, plus companion commits *"Support LLVM 22"*, *"Fix inline assembly operand constraints"*, *"Complete LLVM.jl 9.x release notes"*), all dated 2026-08-13 — the **same day rc2 shipped**. This means LLVM.jl is already ahead of Julia 1.13's LLVM 20, having exercised the 20→21→22 boundary, which is strong evidence LLVM 20 (1.13's version) is solid, well-trodden ground for LLVM.jl by the time 1.13 GAs.
- Net assessment: **LLVM.jl support for Julia-1.13's LLVM 20.1.8 is mature and current as of 2026-08-15.** Bennett.jl should bump its `LLVM` compat bound from the `9, 10` range currently pinned in `Project.toml` (grep result: `LLVM = "9, 10"`) and re-pin to whatever `LLVM.jl` version pairs with 1.13 once that's finalized — this is a mechanical Pkg bump, not a design blocker.
- **What could still bite**: LLVM 18→20 spans several LLVM releases known upstream for opcode/attribute churn (e.g. continued tightening of `getelementptr` inbounds/nuw semantics, poison/freeze refinements, attribute-list representation changes across LLVM 19/20) — none of which are itself surfaced in Julia's `NEWS.md`, and general web search did not surface a Julia-side writeup enumerating IR-shape changes from this specific bump (searches for "Julia LLVM 20 codegen changes" returned no dedicated writeup — this is a gap other agents should be aware they'd need to close empirically, e.g. by diffing `code_llvm(f, types; optimize=false)` output for a battery of Bennett's existing test functions between 1.12.5 and a 1.13 install). Per CLAUDE.md rule 5 ("LLVM IR is not stable... The LLVM.jl C API walker is the source of truth"), this is exactly the class of risk the project's own rules already anticipate — it is a **known, expected category of work**, not a surprise.
- Reassuring structural fact from a quick grep of `src/extract/instructions.jl`: opcode dispatch is done via `LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr` etc. — i.e. against LLVM's **stable C-API integer opcode enum**, not string/regex matching on textual IR. This is the right defensive pattern and should absorb most of the LLVM 18→20 churn automatically; the residual risk is in *new* instruction shapes/flags appearing in **optimized** IR that Bennett's opcode-by-opcode lowering (`src/lowering/`) doesn't yet have a case for — mitigated by the project's existing practice of using `optimize=false` (CLAUDE.md rule 5) to keep IR close to naive/unoptimized shape.

---

## 5. Preview of 1.14-dev (`master`) — NOT in 1.13, but directly informs "what's the right 2026 design"

Since `master`'s `NEWS.md` header now reads "Julia v1.14 Release Notes," everything below is **[1.14-dev / future]**, i.e. merged to `master` post-1.13-branch-cut but not part of 1.13 and with no announced ship date. These are the entries most likely to matter for a ground-up Bennett redesign that assumes "code generation is free" and wants to bet on where Julia is heading rather than churn-adapting to 1.13 alone:

- **Type-system soundness fix**: *"`Type{T} <: S` now holds only if every type `==` to `T` is an instance of `S`, fixing a long-standing soundness hole... `Type{T}` is no longer a subtype of any single kind: use a union of kinds instead"* (#33136, #62141). If a future Bennett design does anything with `Type{T}` dispatch over reflected argument types (e.g. in callee registries, dispatch tables keyed by `Type{<:Integer}`), this closes a subtyping hole that's been open since #33136 was filed (a very old, well-known issue) — worth designing *with* the fix in mind rather than around the old (buggy) behavior.
- **Non-byte-multiple primitive types** (#61359): *"Primitive types with non-byte-multiple logical widths can now be defined."* This is **extremely relevant** to a reversible-circuit compiler that currently only handles byte-aligned widths (Int8/16/32/64, Float64 via 64-bit soft-float). A from-scratch design targeting 1.14+ could define genuinely arbitrary-bit-width primitive types (e.g. a native `UInt3` or a qubit-count-matched integer type) instead of Bennett's current bit-width narrowing via `src/narrow.jl`'s `_narrow_ir`, which today narrows *after* extraction. Native sub-byte primitive types could let user code express circuit-width intent directly in the Julia type system.
- **Explicitly wrapping arithmetic operators `+%`, `-%`, `*%`** (#50790): *"Introduced explicitly wrapping arithmetic operators... to annotate arithmetic operations that are semantically safe to wrap/overflow. Their behavior is currently identical to the default operators. However, in a future version, there may be opt-in support to detect unannotated wrapping in the default operators."* This is a live signal that Julia is heading toward **distinguishing checked/UB-on-overflow arithmetic from intentionally-wrapping arithmetic at the syntax level** — directly relevant to a reversible compiler, since reversible arithmetic gates (ripple/QCLA adders in Bennett's `src/adder.jl`/`src/qcla.jl`) are inherently modular/wrapping. A 1.14+-targeted design could lean on `+%` as the canonical spelling for "this add is a reversible mod-2^W add," rather than inferring wrap intent from LLVM `nsw`/`nuw` flag *absence* as Bennett presumably does today via IR extraction.
- **Type inference refines field types through conditional checks** (#41199, #47574): *"after `if !isnothing(x.field)`, inference knows `x.field` is not `nothing`... Similarly, after a call like `func(x.field)` where `func(::Int)` is the only matching method, inference refines `x.field` to `Int`."* This is inference-level narrowing analogous in spirit to the phi/path-predicate problem Bennett's own `src/lowering/phi.jl` solves at the *gate* level (CLAUDE.md's "false-path sensitization" warning) — worth reading the Julia compiler PR for this feature as prior art/validation of the general approach, even though it operates one layer up (type inference, not reversible-gate synthesis).
- **`@methods` macro** (#62311) — lists all applicable methods for a call expression by argument types; could be a nicer reflection primitive than manual `methods(f, types)` walking if a future Bennett design wants richer multi-method/multiple-dispatch-aware extraction (e.g. Bennett's `extract/callgraph.jl` / `extract/julia_set.jl` closed-world multi-IR producer).
- **`detect_closure_boxes`/`detect_closure_boxes_all`** (#60478) — finds methods that allocate `Core.Box` from captured closure variables. Directly useful as a *pre-flight linter* for a Bennett-style compiler: closures that box captured variables are exactly the kind of "plain Julia function" input that would produce surprising/unsupported LLVM IR shapes during extraction. Worth adopting as an input-validation pass regardless of which Julia version Bennett targets, once available.
- **Cancellation tokens** (`Base.CancellationTokenSource`, #60281) — likely irrelevant to Bennett's synchronous compile pipeline, but relevant if a future design does long-running parallel circuit synthesis (e.g. `benchmark/` sweep scripts, or parallel lowering of independent basic blocks) and wants cooperative cancellation instead of ad hoc `@async`/task management.
- **`Threads.@threads` gains array-comprehension support + scheduler overhead reduction (up to 1000x for oversubscribed spawn)** (#59019, #61826) — relevant to Bennett's own parallelization opportunities (e.g. `parallel_adder_tree.jl`, wire allocation, or per-basic-block lowering) if a redesign wants to parallelize gate synthesis at compile time.
- **`typegroup` blocks for mutually recursive struct types** (#60569) — could simplify Bennett's `ir_types.jl` IR-struct hierarchy (`IRBinOp`, `IRICmp`, `IRPhi`, ... currently presumably using forward-declared/abstract-supertype patterns) if any of those types are mutually recursive.
- **Syntax versioning via `compat.julia`/`syntax.julia_version` in Project.toml** (#60018) — an "editions"-like mechanism; relevant only as a packaging/compat-declaration detail for whichever Julia version(s) a rewritten Bennett targets.

**Caveat**: all of §4 is **1.14-dev, unreleased, no milestone due-date, and could still change before it ships** (in fact the 1.14 milestone itself shows 8 open / 18 closed issues as of 2026-08-15 — very early-stage). None of this is safe to build against today; it is intelligence for "which way the language is leaning," not a target platform. **The only safe near-term target is 1.13 (or 1.12.x, the current LTS-adjacent stable line).**

---

## 6. Relevance to Bennett.jl — summary judgment

1. **1.13 is safe to target now.** It is feature-frozen, deep in RC (rc3), with zero open compiler/language issues on its milestone. Nothing in its `NEWS.md` breaks Bennett's approach (no type-system, no `Core.Compiler`-public-API, no generated-function, no world-age changes). The only NEWS-documented item requiring a grep-and-check is the single deprecation (`merge(combine, d...)` → `mergewith`) and a sanity-check that nothing in `src/` relies on `hash(::AbstractString)` bit-values being stable across Julia versions (a light risk, and per CLAUDE.md rule 13's own bit-exactness philosophy, this is exactly the kind of thing the project already knows to test for).
2. **The real 1.13 migration cost is the LLVM 18→20 bump**, invisible in `NEWS.md`, found only by diffing `deps/llvm.version` across release branches. This is squarely inside the risk category CLAUDE.md rule 5 already names ("LLVM IR is not stable... walk it, don't hallucinate it") — expect to re-run `extract_parsed_ir`/`code_llvm(..., optimize=false)` across Bennett's existing IR-shape test battery on a real Julia-1.13 install and diff for new instruction/attribute shapes before trusting the extractor on 1.13. LLVM.jl itself (the wrapper) is in good shape for this — it already supports LLVM 20 solidly and added LLVM 22 support on 2026-08-13, one day into 1.13's rc2. Bennett's `Project.toml` `LLVM = "9, 10"` compat bound and currently-resolved `v9.7.1` should be bumped as part of any 1.13 migration.
3. **For a from-scratch 2026 redesign, the interesting signal isn't in 1.13 at all — it's in 1.14-dev on `master`.** Two items stand out as potentially reshaping the *right* design rather than just porting the current one: (a) **non-byte-multiple primitive types** (#61359), which could let a redesigned front-end express sub-byte/arbitrary-width reversible-circuit types natively in Julia's type system instead of post-hoc bit-narrowing via `src/narrow.jl`; and (b) **explicit wrapping-arithmetic operators `+%`/`-%`/`*%`** (#50790), which map almost one-to-one onto "this is a reversible modular-arithmetic gate" and could become the idiomatic way for user code to declare wrap-safe arithmetic that Bennett's adders lower directly, rather than inferring wrap-safety from the *absence* of LLVM `nsw`/`nuw` flags as must currently be done. Both are unreleased, unstable, and could change — they are a *directional* signal for a 1.14+-era design, not something to build against today.
4. **No changes anywhere (1.13 or 1.14-dev) threaten the soft-float bit-exactness contract, the Bennett-transform ancilla-zero invariant, or the phi-resolution false-path-sensitization concern** — those are Bennett's own algorithmic risk surface, orthogonal to upstream Julia/LLVM churn. The 1.14-dev conditional-field-narrowing inference feature is worth a skim as prior art for a similar problem one layer up the stack, but nothing upstream provides a shortcut around Bennett's own path-predicate machinery.

---

## Sources

- [JuliaLang/julia `release-1.13/NEWS.md`](https://raw.githubusercontent.com/JuliaLang/julia/release-1.13/NEWS.md) (fetched raw via curl, 2026-08-15)
- [JuliaLang/julia `master/NEWS.md`](https://raw.githubusercontent.com/JuliaLang/julia/master/NEWS.md) — now titled "Julia v1.14 Release Notes" (fetched raw via curl, 2026-08-15)
- [JuliaLang/julia `release-1.13/deps/llvm.version`](https://raw.githubusercontent.com/JuliaLang/julia/release-1.13/deps/llvm.version) vs [`release-1.12/deps/llvm.version`](https://raw.githubusercontent.com/JuliaLang/julia/release-1.12/deps/llvm.version)
- [github.com/JuliaLang/julia/releases](https://github.com/JuliaLang/julia/releases) (REST API `releases` endpoint)
- [github.com/JuliaLang/julia/milestone/48](https://github.com/JuliaLang/julia/milestone/48) (1.13 milestone, 5 open / 46 closed) and [milestone/49](https://github.com/JuliaLang/julia/milestone/49) (1.14, 8 open / 18 closed)
- [Julia v1.13.0-rc2 is now available](https://discourse.julialang.org/t/julia-v1-13-0-rc2-is-now-available/138769) — Discourse, 2026-08-12/13
- [Julia v1.13.0-rc3 is now available](https://discourse.julialang.org/t/julia-v1-13-0-rc3-is-now-available/138805) — Discourse, 2026-08-14
- [Is the development of 1.13 stuck?](https://discourse.julialang.org/t/is-the-development-of-1-13-stuck/138693) — Discourse thread, `dilumaluthge` response re: CI infra blocking
- [github.com/JuliaLLVM/LLVM.jl](https://github.com/JuliaLLVM/LLVM.jl) (formerly `maleadt/LLVM.jl`) — `README.md`, `Project.toml`, commit history (LLVM 22 support merged 2026-08-13)
- Local: `julia --version` → 1.12.5; `git log -1` on Bennett.jl → 2026-08-14; `Pkg.status("LLVM")` → resolves `v9.7.1`; `Project.toml` `[compat] LLVM = "9, 10"`, `julia = "1.10"`; grep of `src/extract/instructions.jl` (opcode dispatch via `LLVM.API.LLVMGetElementPtr` etc., not textual matching) and `src/extract/julia_set.jl` (`_argtype_digest` uses `hash(::DataType)`, not `AbstractString`).
