# MemorySSA investigation — T2a.1 (Bennett-law3)

**Date:** 2026-04-12
**Status (Bennett-5ttt / U156):** **SHIPPED** — recommendation
implemented as `src/memssa.jl` (parser) + `MemSSAInfo` struct in
`src/ir_types.jl` (Bennett-by8j / U44, commit `5411d1a` 2026-04-25
concretised the field type). The printer-pass-output parsing approach
this doc proposes is the live codepath gated by
`extract_parsed_ir(...; use_memory_ssa=true)`. No alternative remains
on the design table.

**Original status:** Investigation complete. **Go** with printer-pass-output parsing.

## Summary

LLVM.jl 9.4.6 (linked against LLVM 18.1.7) exposes MemorySSA **only through the
New-Pass-Manager pipeline**, not as a queryable analysis object. We CAN run the
`print<memoryssa>` pass and **capture its textual output via `redirect_stderr`
onto a `Pipe`**; the captured text is a standard LLVM-IR annotation format
parseable via regex/line-based scanning. This gives us the full MemoryDef /
MemoryUse / MemoryPhi graph we need, at the cost of one extra pass run and a
ten-line parser.

**Recommendation: implement T2a.2 using printer-pass-output parsing.** Effort
estimate: ~200 LOC parser + ~50 LOC integration into `LoweringCtx`. No
LLVM.jl changes required.

Rejected alternatives documented below.

## What LLVM.jl exposes

```julia
julia> filter(n -> occursin("Memor", string(n)), names(LLVM, all=true))
# …
# :MemorySSAPrinterPass
# :MemorySSAVerifierPass
# :MemorySSAWalkerPrinterPass
# :MemorySanitizerPass (unrelated — sanitizer)
```

**Passes available via string pipelines:**
- `"print<memoryssa>"` — runs MemorySSA analysis, writes annotated IR to stderr
- `"verify<memoryssa>"` — runs verifier (errors on inconsistency)
- `"print<memoryssawalker>"` — walker-specific diagnostics

**What's NOT exposed:** the analysis object itself (`MemorySSA`), its nodes
(`MemoryDef`, `MemoryUse`, `MemoryPhi`), the walker (`MemorySSAWalker`), any
clobbering-def query API. All of these exist in LLVM C++ but have no C-API
wrappers, and LLVM.jl binds only the C API.

## What the printer produces

Running `print<memoryssa>` on

```llvm
define i64 @julia_f(i64 %x) {
top:
  %arr = alloca [4 x i64]
  %p0  = getelementptr [4 x i64], ptr %arr, i64 0, i64 0
  store i64 %x, ptr %p0
  %p1  = getelementptr [4 x i64], ptr %arr, i64 0, i64 1
  %y = add i64 %x, 1
  store i64 %y, ptr %p1
  %v = load i64, ptr %p0
  ret i64 %v
}
```

yields (stderr):

```llvm
MemorySSA for function: julia_f
define i64 @julia_f(i64 %x) {
top:
  %arr = alloca [4 x i64]
  %p0  = getelementptr [4 x i64], ptr %arr, i64 0, i64 0
; 1 = MemoryDef(liveOnEntry)
  store i64 %x, ptr %p0
  %p1  = getelementptr [4 x i64], ptr %arr, i64 0, i64 1
  %y   = add i64 %x, 1
; 2 = MemoryDef(1)
  store i64 %y, ptr %p1
; MemoryUse(1)
  %v = load i64, ptr %p0
  ret i64 %v
}
```

Critically, the load's `MemoryUse(1)` correctly tells us that `%v` reads from
MemoryDef #1 (the store to `%p0`), **not** MemoryDef #2 (the store to `%p1`).
This is exactly the dependency that T0 preprocessing (`sroa`, `mem2reg`) cannot
fold away when the array has variable indices or is indirectly reached — and
it's what T1b.3 currently has to reconstruct heuristically via `ptr_provenance`.

Phi-node form:

```
; 3 = MemoryPhi({true_block,2},{false_block,1})
```

Annotations appear on comment lines (`;`-prefixed) immediately **before** the
instruction they describe. Always one annotation per memory-touching
instruction; never interleaved with instruction text.

## Captured via Julia `Pipe`

Working code (tested on LLVM.jl 9.4.6, LLVM 18.1.7, Julia 1.12.3):

```julia
using LLVM
pipe = Pipe()
LLVM.Context() do _ctx
    mod = parse(LLVM.Module, ir_string)
    Base.redirect_stderr(pipe) do
        @dispose pb = LLVM.NewPMPassBuilder() begin
            LLVM.add!(pb, "print<memoryssa>")
            LLVM.run!(pb, mod)
        end
    end
end
close(pipe.in)
annotated_ir = read(pipe, String)
```

Produces ~10 KB of annotated IR for a 4-store + 2-load function. Standard
LLVM-IR textual format otherwise; comment-line annotations pure ASCII.

## Rejected alternatives

### Option A — Direct C++ API call via `ccall`

Bind `llvm::MemorySSA`, `MemorySSAAnalysis`, etc. via direct `ccall` into
`libLLVM.so`. **Rejected:** requires maintaining C++ name mangling by hand,
across LLVM versions. Non-portable. High maintenance cost for zero correctness
gain vs printer parsing.

### Option B — Write a custom LLVM pass in C++

Compile a `.cpp` pass that walks `MemorySSAResult`, emits info as LLVM metadata
attached to instructions (`!memssa`), then read metadata from Julia via LLVM.jl.
**Rejected:** requires C++ build infrastructure in a pure-Julia package.
Nontrivial CI burden. Metadata would need a custom format LLVM doesn't natively
preserve across pass runs (gets stripped by verifier).

### Option C — Reimplement MemorySSA in Julia

Walk the basic-block instruction stream ourselves, compute a reaching-definitions
analysis over memory operations. **Rejected:** reimplementation of 2500+ lines
of LLVM's `MemorySSA.cpp`, with alias-analysis dependencies we'd also have to
reimplement. High effort, high bug surface, low leverage (LLVM's analysis is
already written and battle-tested).

### Option D — Rely on T0 preprocessing alone

Don't integrate MemorySSA; trust `sroa` + `mem2reg` + `simplifycfg` to eliminate
memory ops before we see them. **Insufficient:** T0 handles scalar/small-static
allocas but leaves variable-index-accessed arrays intact. Those are exactly the
cases where MemorySSA's def-use info would let us do better than T1b.3's
heuristic provenance tracking. T0 is a strong baseline; MemorySSA is the
marginal-value extension.

## Chosen path: T2a.2 implementation plan

Printer-pass-output parsing with these concrete pieces:

1. **New module `src/memssa.jl`:**
   - `run_memssa(mod::LLVM.Module) -> MemSSAResult` — runs the pass, captures
     stderr, returns parsed annotations.
   - `MemSSAResult` struct holds:
     - `defs::Dict{Int, InstructionKey}` — MemoryDef ID → the instruction it's
       attached to (keyed by textual instruction signature: "opcode + operand names")
     - `uses::Dict{InstructionKey, Int}` — MemoryUse instruction → Def ID it reads
     - `phis::Dict{Int, Vector{Tuple{Symbol, Int}}}` — MemoryPhi ID → (block, incoming def)
     - `clobber_chain::Dict{Int, Union{Int, Symbol}}` — Def → its immediate clobber (Int ID or `:liveOnEntry`)

2. **Hook into `extract_parsed_ir`:**
   - New kwarg `use_memory_ssa::Bool=false`. When true, run memssa on the
     preprocessed module, cross-reference each `IRLoad`/`IRStore` with the
     MemSSAResult, attach a `memdef_id::Int` field to the IR instruction (or
     side-map in `ParsedIR`).
   - Field placement respects Proposer A's T1a.1 decision (Bennett-fvh): no
     `memdef_version` field on `IRStore` — use a side-map keyed by instruction.

3. **Hook into `lower_load!`:**
   - When `ctx.memssa` is present and `inst` has a MemoryUse of Def #N,
     resolve Def #N to the specific prior store or `liveOnEntry`. Use this to
     route through the right wire-mapping path — currently `ptr_provenance`
     handles only direct alloca-index matches; with memssa, conditional
     stores and aliased pointers become tractable.

4. **Testing (T2a.3, Bennett-08wr):**
   - Case A: conditional store that T0 misses
     (`if c; arr[i] = x; end; v = arr[j]`).
   - Case B: two allocas with same element type but different data.
   - Case C: load that clobbers across a phi (two branches both store).
   - Each test compares the gate count with and without `use_memory_ssa=true`
     and asserts reversibility in both cases.

## Scope limits

- **Parser must tolerate LLVM version drift.** The printer output format is
  part of LLVM's IR textual contract (has been stable for years) but not
  LLVM's C API. Add a version check that errors loudly if the format changes.
- **Only capture MemoryDef/Use/Phi annotations** — the walker printer
  (`print<memoryssawalker>`) provides more detailed clobber queries but the
  basic printer is sufficient for T2a.2's goal of integrating def-use info
  into our lowering.
- **Don't implement `MemorySSA.getClobberingMemoryAccess`** as a separate Julia
  API. If a load's Use doesn't directly correspond to a Def in the printer
  output (rare but possible for `liveOnEntry` cases), fall back to
  `ptr_provenance`.

## Risk register

1. **LLVM 19+ format change.** If LLVM restructures MemorySSA output text,
   our parser breaks. Mitigation: pin a fmt version in the test suite; add a
   probe at init time that verifies a known-good input produces a known-good
   parse.
2. **stderr contention.** If another pass in the pipeline also writes to
   stderr (e.g., warnings), our parser will see interleaved output.
   Mitigation: run memssa in a dedicated `run_passes!` call, not alongside
   other passes.
3. **Performance.** Running the pass on every compilation adds latency.
   Mitigation: `use_memory_ssa` is opt-in; only enable for compilations where
   T0 preprocessing left memory operations behind.

## Next step

T2a.2 (Bennett-81bs): implement `src/memssa.jl`, plumb through
`extract_parsed_ir`, and run the T2a.3 integration tests. Estimate: one focused
session (4-6 hours).
