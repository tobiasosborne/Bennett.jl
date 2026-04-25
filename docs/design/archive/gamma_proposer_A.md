# Bennett-uyf9 (γ) — Proposer A

**Bead:** Bennett-uyf9 (P1, bug, labels: `3plus1,core`).
**Scope:** handle memcpy-form sret under `optimize=false`.
**Prereqs landed:** Bennett-atf4 (α), Bennett-0c8o (β), both shipped 2026-04-21.
**Target file:** `src/ir_extract.jl`.
**Author:** Proposer A (independent of Proposer B).
**Date:** 2026-04-21.

---

## 1. Recommendation: **C1 (auto-SROA on sret detection)**

I recommend the narrow fix: when `_detect_sret` returns a non-`nothing`
NamedTuple and the caller did not already include `"sroa"` in the effective
pass list, prepend `["sroa", "mem2reg"]` to the pipeline before running
`_run_passes!`. This is what the current `preprocess=true` escape hatch
already does and what the live-repro confirmed in
`docs/design/p6_research_local.md §4.3`.

Reasoning in one paragraph: the memcpy-form sret exists because Julia's
frontend, at `-O0`, spills the per-slot stores into a local alloca and emits
a bulk `llvm.memcpy` into `%sret_return`. SROA + mem2reg *is* the LLVM
transformation whose documented job is "promote allocas, break up aggregate
loads/stores". Running those two passes rewrites
`alloca [9 x i64] + N stores + memcpy-to-sret` into `N direct i64 stores
into %sret_return`, which is the exact shape `_collect_sret_writes` already
consumes. No byte-level walker required, no Enzyme-port risk, no LLVM
version fragility — we reuse the `LLVM.NewPMPassBuilder` infrastructure
`_run_passes!` already wraps.

I rejected C2 (porting Enzyme's `memcpy_sret_split!`) because it ships ~120
LOC of new mutation logic to replicate what a single well-understood stock
pass already does, and because Enzyme's `any_jltypes` gate doesn't match
Bennett's needs and would need to be torn out and replaced with Bennett's
own recursion rules — increasing rather than decreasing maintenance
surface.

The rest of this document specifies the change line-by-line, enumerates
edge cases against the C1 choice, provides a full RED test file, spells
out the required `test_sret.jl:125-136` update, lays out the regression
plan, and flags three specific risks with mitigations.

---

## 2. Design — C1 in detail

### 2.1 Where the fix lives

Single function: `extract_parsed_ir` at `src/ir_extract.jl:41-81`. No other
entry point. `extract_parsed_ir_from_ll` and `extract_parsed_ir_from_bc`
use their own `effective_passes` construction (lines 111-150 and 164-191)
but none of the current test suite exercises sret through those entry
points, and callees inside the persistent-tree arm go through
`extract_parsed_ir(f, arg_types)`, so the fix is scoped to the
Julia-function path.

A conservative follow-up could mirror the same auto-SROA into the two
external-IR entry points, but that is **out of scope for γ** — file a
follow-up if/when external-IR sret extraction comes up.

### 2.2 Decision to auto-promote

The decision criterion is: the extracted LLVM IR has a function whose
parameter carries the `sret` attribute. `_detect_sret` already returns
the metadata we need. The tricky bit is we must run it *before* the pass
pipeline, on the freshly-parsed module, not on the post-pass module (by
that point it would be too late).

Luckily `_detect_sret` is a pure read — it inspects parameter attributes
via LLVM's C API. Nothing prevents us from running it before
`_run_passes!`, observing the result, and then running `_run_passes!`
with a possibly-augmented pass list. We can re-use the result inside
`_module_to_parsed_ir_on_func` as well, but for now the simpler thing is
to let the main walker call `_detect_sret` again on the post-pass
module — it's idempotent and cheap.

### 2.3 Exact code change

**File:** `src/ir_extract.jl`
**Function:** `extract_parsed_ir`
**Lines before the fix:** 41-81.

Current body (lines 41-81):

```julia
function extract_parsed_ir(f, arg_types::Type{<:Tuple};
                           optimize::Bool=true,
                           preprocess::Bool=false,
                           passes::Union{Nothing,Vector{String}}=nothing,
                           use_memory_ssa::Bool=false)
    ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

    # T2a.2: capture MemorySSA annotations before the main IR walk. Runs in a
    # separate context so stderr capture for the printer doesn't collide with
    # our main extraction.
    memssa = if use_memory_ssa
        annotated = _run_memssa_on_ir(ir_string; preprocess=preprocess)
        parse_memssa_annotations(annotated)
    else
        nothing
    end

    local result::ParsedIR
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        if !isempty(effective_passes)
            _run_passes!(mod, effective_passes)
        end
        result = _module_to_parsed_ir(mod)
        dispose(mod)
    end
    # ... memssa stamping ...
    return result
end
```

Modified body (the delta is localised to the module block):

```julia
function extract_parsed_ir(f, arg_types::Type{<:Tuple};
                           optimize::Bool=true,
                           preprocess::Bool=false,
                           passes::Union{Nothing,Vector{String}}=nothing,
                           use_memory_ssa::Bool=false)
    ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

    memssa = if use_memory_ssa
        annotated = _run_memssa_on_ir(ir_string; preprocess=preprocess)
        parse_memssa_annotations(annotated)
    else
        nothing
    end

    local result::ParsedIR
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)

        # Bennett-uyf9: when an sret parameter is present but the effective
        # pass list does not already include SROA, auto-prepend
        # ["sroa", "mem2reg"]. This canonicalises the `optimize=false`
        # memcpy-form sret into per-slot scalar stores that
        # `_collect_sret_writes` can consume. See docs/design/gamma_proposer_A.md
        # for the rationale; empirically verified in
        # docs/design/p6_research_local.md §4.3.
        if !("sroa" in effective_passes) && _module_has_sret(mod)
            effective_passes = vcat(["sroa", "mem2reg"], effective_passes)
        end

        if !isempty(effective_passes)
            _run_passes!(mod, effective_passes)
        end
        result = _module_to_parsed_ir(mod)
        dispose(mod)
    end
    if memssa !== nothing
        result = ParsedIR(result.ret_width, result.args, result.blocks,
                          result.ret_elem_widths, result.globals, memssa)
    end
    return result
end
```

The single line of behavioural change is the `if !("sroa" in
effective_passes) && _module_has_sret(mod)` block. Everything else is
byte-identical to the current file.

### 2.4 The `_module_has_sret` helper

New helper function, placed right above `_detect_sret` (before line 370 in
the current file). ~10 LOC:

```julia
"""
    _module_has_sret(mod::LLVM.Module) -> Bool

Scan every function with a body in `mod` and return `true` iff at least
one non-declaration function has a parameter carrying the `sret` attribute.
Used by `extract_parsed_ir` to decide whether to auto-prepend `["sroa",
"mem2reg"]` to the effective pass pipeline under Bennett-uyf9.

Byte-identical to calling `_detect_sret` on the first
`julia_*`-named function with a body and returning `something !== nothing`
— but decoupled from the entry-function heuristic so the fix doesn't
fight with `_find_entry_function`.
"""
function _module_has_sret(mod::LLVM.Module)
    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
    for f in LLVM.functions(mod)
        isempty(LLVM.blocks(f)) && continue  # skip declarations
        for (i, _p) in enumerate(LLVM.parameters(f))
            attr = LLVM.API.LLVMGetEnumAttributeAtIndex(f, UInt32(i), kind_sret)
            attr == C_NULL || return true
        end
    end
    return false
end
```

Design choices worth flagging:

1. **Scan every function with a body.** The module produced by
   `code_llvm(...; dump_module=true)` contains multiple functions: the
   entry `julia_*` function plus any non-inlined callees. We want SROA
   to run on *all* of them, because β's `_collect_sret_writes` runs on
   whichever function the main walker selects, and the persistent-tree
   arm will eventually extract sub-callees too (via `lower_call!`
   re-invoking `extract_parsed_ir`). One sret-bearing function anywhere
   in the module is enough to warrant running SROA.

2. **Skip declarations.** A function with no blocks has no parameters we
   care about — LLVM IR sometimes declares `julia_*` builtins that never
   get defined in the emitted module. Matches the existing filter in
   `_find_entry_function` (`!isempty(LLVM.blocks(f))`).

3. **Don't reuse `_detect_sret`.** `_detect_sret` errors on
   heterogeneous-struct sret and non-{8,16,32,64} element widths —
   designed for the entry-function consumer path. We need a pure yes/no
   predicate, no error. Re-implementing the three-line attribute scan
   is cleaner than adding a `strict::Bool` kwarg to `_detect_sret` that
   no other caller needs.

4. **Return on the first hit.** Short-circuits in the (very common)
   case of a single sret-returning function.

### 2.5 Why not `preprocess=true`-equivalent (full `DEFAULT_PREPROCESSING_PASSES`)?

`DEFAULT_PREPROCESSING_PASSES = ["sroa", "mem2reg", "simplifycfg", "instcombine"]`
(`src/ir_extract.jl:23`). The full pipeline runs `simplifycfg` and
`instcombine` on top, which the research doc confirmed "are part of how
we got into Form B" (`docs/design/p6_research_online.md §7.3`). For the
γ use-case we only need memcpy decomposition; adding `simplifycfg` risks
collapsing the L15/L16/L17 `-O0` fall-through blocks in ways that could
alter gate counts for non-sret functions that happen to be in the same
module. Running only `sroa` + `mem2reg` is the minimum sufficient
transform for memcpy-form sret per `docs/design/p6_research_local.md §10.2`.

The `preprocess=true` caller path remains available as the escape hatch
for users who need the full four-pass pipeline. It continues to set
`"sroa"` in `effective_passes` before the auto-detect check, which means
the `!("sroa" in effective_passes)` guard will skip the auto-prepend and
the user's explicit pipeline wins verbatim. Desired behaviour.

### 2.6 Interaction with `preprocess=true` and explicit `passes=...`

Three concrete cases to verify in the RED test:

| `optimize` | `preprocess` | `passes=` | sret present? | effective passes |
|---|---|---|---|---|
| false | false | nothing | yes | `["sroa", "mem2reg"]` (auto-prepended) |
| false | true  | nothing | yes | `["sroa", "mem2reg", "simplifycfg", "instcombine"]` (unchanged, user-explicit already contains sroa) |
| false | false | `["gvn"]` | yes | `["sroa", "mem2reg", "gvn"]` |
| true  | false | nothing | yes | `[]` (post-optimise IR already SROA'd; β handles vector stores) |
| false | false | nothing | no  | `[]` (no auto-prepend; no regression) |

The fifth case is the load-bearing invariant for the "no-regression"
guarantee: non-sret functions under `optimize=false` continue to run with
`effective_passes=[]`, byte-identical to the current behaviour. This is
the precise condition that CLAUDE.md §5 ("LLVM IR IS NOT STABLE; always
use optimize=false for predictable IR when testing") asks us to protect.

The fourth case is where β's vector-store path takes over. Under
`optimize=true`, Julia's own optimiser has already run SROA, so the IR
arrives with no allocas — the memcpy form doesn't exist. `_module_has_sret`
returns true, we auto-prepend `["sroa", "mem2reg"]`, and running SROA on
already-SROA'd IR is a no-op (verified: running SROA twice on the same IR
is idempotent per LLVM docs). So the auto-prepend is harmless for the
`optimize=true` path. **Verify this empirically in the test.**

### 2.7 Alternative shape considered: gated on `_module_has_sret` AND `optimize=false`

A more conservative version of the fix would scope the auto-prepend to
`optimize=false` only — on the reasoning that `optimize=true` can't
produce memcpy-form sret in the first place, so there's nothing to fix
there. I rejected this variant because:

- Under `optimize=true` with an sret function, running SROA redundantly
  is a measured no-op (empirically verified by inspecting the output IR
  of `okasaki_pmap_set` at `optimize=true, preprocess=true` vs `optimize=true,
  preprocess=false` — identical gate counts per the research doc).
- Adding the `optimize=false` gate means the auto-prepend condition is
  `!sroa_in_passes && _has_sret && !optimize` — three conjuncts — and if
  anyone ever sets `optimize=false, preprocess=false, passes=["gvn"]`
  they'd hit the memcpy error again. The gate just reintroduces a
  confusing failure mode.
- The `!("sroa" in effective_passes)` guard already prevents double-SROA
  in the cases where the user explicitly asked for it.

So the simpler rule "auto-prepend sroa+mem2reg whenever sret present and
sroa not already requested" wins.

---

## 3. Edge cases

All edge cases below are against the C1 design. C2-specific edge cases
(partial memcpy size, multi-memcpy-to-sret, unrelated memcpys) are
**covered for free by C1** because C1 doesn't walk memcpys at all — it
lets SROA handle whatever pattern Julia emits, and `_collect_sret_writes`'s
existing rejection logic catches anything SROA couldn't canonicalise.

### 3.1 Memcpy size doesn't match sret aggregate size

Under C1: not our problem. SROA either promotes the source alloca (in
which case the memcpy is dead-stripped) or leaves it alone. If SROA
leaves it alone, `_collect_sret_writes` still rejects the memcpy at
lines 451-461 with the current error message — which is correct: partial
sret writes are genuinely unsupported per β's design invariants.

Under C2 (Enzyme-port): we'd explicitly need a `convert(Int, operands(cur)[3]) == sret_info.agg_byte_size`
check and to fail loud otherwise. Not a problem we have to solve.

### 3.2 Memcpy destination is NOT the sret pointer

Under C1: the auto-SROA runs on the whole module, but SROA's memcpy
transformations are scoped to the allocas it's promoting. Memcpys between
two non-alloca pointers (e.g., user-level `unsafe_copyto!`) are left
alone. Our current code doesn't have any such memcpys anyway, but if a
future test introduces one, it'll survive SROA untouched.

Under C2: we'd need the `dst == parameters(f)[1]` check from Enzyme
verbatim (lines 531-533 of the cited source). Not a problem we have to
solve.

### 3.3 Multiple memcpys target the sret

Under C1: Julia under `-O0` emits exactly one memcpy-to-sret per
returning block. Once SROA promotes the source alloca, all its stores
flow directly into the sret pointer. If someone constructs a hostile
`.ll` file with multiple memcpys to the same sret — we don't support
that entry point under γ (it goes through `extract_parsed_ir_from_ll`,
which this fix doesn't modify), and if we did, SROA might or might not
canonicalise them. The post-SROA `_collect_sret_writes` would catch any
residual memcpy via the existing error path.

Under C2: this is the main edge case — "only split the last one; error
on conflict". Not a problem we have to solve.

### 3.4 Non-sret functions with memcpys elsewhere

Under C1: `_module_has_sret` returns false, the auto-prepend is skipped,
`effective_passes` stays `[]`, and behaviour is byte-identical to the
current compiler.

This is the most important invariant to lock in a regression test: every
existing test that doesn't touch sret must be unaffected. Gate-count
baselines in `test_gate_count_regression.jl` (i8=86, i16=174, i32=350,
i64=702 per CLAUDE.md §6) must not budge.

### 3.5 Module containing *both* sret and non-sret functions

Can happen when `dump_module=true` emits declarations/helpers alongside
the entry. Under C1: `_module_has_sret` returns true, SROA runs on every
function in the module, and any non-sret function that happens to have
an alloca gets SROA'd too. This could in principle change gate counts
for non-sret functions that share a module with an sret function.

**Mitigation:** the `julia_*`-named entry function is extracted by
`_find_entry_function`, so only the SROA'd entry function gets walked
into a `ParsedIR`. The other functions in the module are dead for the
compiler — changing them doesn't affect the output circuit.

Verified by inspecting `_find_entry_function` at
`src/ir_extract.jl:694-727`: it picks one function by name and the rest
are ignored. The SROA side-effects on inlined callees are invisible.

### 3.6 Empty pass list + sret + no module has sret = idempotent

If the caller explicitly sets `passes=String[]` (empty vector) and
sret is absent, we do NOT auto-prepend. `effective_passes` stays empty,
`_run_passes!` is not called (due to the `isempty(effective_passes)`
guard at line 69), and the module walks verbatim.

### 3.7 `use_memory_ssa=true` interaction

MemorySSA annotations are captured from `ir_string` before the module is
parsed (`src/ir_extract.jl:56-64`). The annotated IR is what
`_run_memssa_on_ir` produces — itself applying `preprocess` if set. Our
auto-SROA only affects the second module parse, not the memssa
annotations. So if a caller passes `use_memory_ssa=true, optimize=false,
preprocess=false` on an sret function, the memssa annotations come from
pre-SROA IR while the walker sees post-SROA IR. This is a potential
inconsistency — but `use_memory_ssa=true` is a niche flag
(`src/ir_extract.jl:114` docstring calls it experimental), and no sret
test currently uses it. **Document it as a known limitation** in the
WORKLOG entry for γ and file a follow-up bead.

---

## 4. RED test — `test/test_uyf9_memcpy_sret.jl`

Full file content below. Cover the five test scenarios from §2.6, plus
the load-bearing γ workload (NTuple{9,UInt64} callee), plus the
regression-guard non-sret function. Structure follows `test_sret.jl`
conventions (`_match` helper, `@testset` nesting).

```julia
using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, extract_parsed_ir

# Bennett-uyf9 (γ): memcpy-form sret under optimize=false.
#
# Before this fix: extract_parsed_ir(f, ...; optimize=false) on an
# sret-returning function errors with
#   "sret with llvm.memcpy form is not supported ..."
#
# After this fix: extract_parsed_ir auto-prepends ["sroa", "mem2reg"]
# to the pass pipeline when an sret parameter is detected and the
# user hasn't already requested SROA, canonicalising the memcpy into
# per-slot scalar stores that _collect_sret_writes consumes.

_match(result::Tuple, expected::Tuple) =
    all(reinterpret(unsigned(typeof(e)), r % unsigned(typeof(e))) ===
        reinterpret(unsigned(typeof(e)), e)
        for (r, e) in zip(result, expected))

@testset "Bennett-uyf9 memcpy-form sret under optimize=false" begin

    @testset "n=3 UInt32 extracts under optimize=false (smallest sret)" begin
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        # Before: ErrorException "sret with llvm.memcpy form is not supported".
        # After:  clean ParsedIR with ret_elem_widths == [32, 32, 32].
        parsed = extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32}; optimize=false)
        @test parsed.ret_width == 96
        @test parsed.ret_elem_widths == [32, 32, 32]
        @test length(parsed.args) == 3
        @test parsed.args == [(Symbol("a"), 32), (Symbol("b"), 32), (Symbol("c"), 32)]
    end

    @testset "n=9 UInt64 extracts under optimize=false (load-bearing γ shape)" begin
        # The load-bearing case for T5-P6: NTuple{9,UInt64} callee that
        # previously required preprocess=true as a workaround.
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)
        parsed = extract_parsed_ir(
            g, Tuple{NTuple{9,UInt64}, Int8, Int8}; optimize=false)
        @test parsed.ret_width == 576
        @test parsed.ret_elem_widths == fill(64, 9)
        # (:state::Tuple, 576), (:k::Int8, 8), (:v::Int8, 8)
        @test length(parsed.args) == 3
        @test parsed.args[1][2] == 576
        @test parsed.args[2][2] == 8
        @test parsed.args[3][2] == 8
    end

    @testset "optimize=false + user-requested passes=[\"gvn\"] still auto-prepends SROA" begin
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        parsed = extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32};
                                   optimize=false, passes=["gvn"])
        @test parsed.ret_width == 96
        @test parsed.ret_elem_widths == [32, 32, 32]
    end

    @testset "optimize=false + preprocess=true still works (user-explicit path)" begin
        # Regression: the preprocess=true workaround continues to function
        # byte-identically. The auto-prepend guard must NOT fire because
        # "sroa" is already in effective_passes.
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        parsed = extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32};
                                   optimize=false, preprocess=true)
        @test parsed.ret_width == 96
        @test parsed.ret_elem_widths == [32, 32, 32]
    end

    @testset "optimize=true path untouched (β is responsible, not γ)" begin
        # NTuple{9,UInt64} under optimize=true: post-β this works via
        # vector-store decomposition. γ's auto-SROA still fires (SROA is
        # idempotent on post-optimise IR) but must not change anything.
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)
        parsed_opt = extract_parsed_ir(
            g, Tuple{NTuple{9,UInt64}, Int8, Int8}; optimize=true)
        @test parsed_opt.ret_elem_widths == fill(64, 9)
        @test parsed_opt.ret_width == 576
    end

    @testset "non-sret function under optimize=false: no auto-prepend, no change" begin
        # Regression guard: the invariant that CLAUDE.md §5 protects.
        # Any function without an sret param must see effective_passes=[]
        # under optimize=false (no preprocess, no explicit passes).
        # We can't easily introspect effective_passes from outside, but
        # we can verify the gate count baseline is preserved.
        f(x::Int8) = x + Int8(3)
        c_baseline = reversible_compile(f, Int8)
        @test gate_count(c_baseline).total == 86  # i8 adder baseline
        @test verify_reversibility(c_baseline)

        # Direct IR extraction also works under optimize=false with no
        # pass list.
        parsed = extract_parsed_ir(f, Tuple{Int8}; optimize=false)
        @test parsed.ret_width == 8
        @test parsed.ret_elem_widths == [8]
    end

    @testset "n=3 UInt32 full roundtrip under optimize=false" begin
        # Beyond extraction: lower + bennett + simulate on an
        # optimize=false-sourced sret function. Uses ParsedIR extracted
        # above. The simulator must produce semantically correct output.
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        parsed = extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32}; optimize=false)
        lr = Bennett.lower(parsed)
        circuit = Bennett.bennett(lr)
        @test verify_reversibility(circuit)
        for (a, b, c) in [
                (UInt32(0),          UInt32(0),          UInt32(0)),
                (UInt32(1),          UInt32(2),          UInt32(3)),
                (typemax(UInt32),    typemax(UInt32),    typemax(UInt32)),
                (UInt32(0x12345678), UInt32(0xCAFEBABE), UInt32(0xDEADBEEF)),
            ]
            @test _match(simulate(circuit, (a, b, c)), (a, b, c))
        end
    end

    @testset "heterogeneous struct-sret still fails loud" begin
        # Regression: γ must not weaken _detect_sret's rejection of
        # struct-typed sret (Tuple{UInt32, UInt64} -> sret({i32, i64})).
        # The auto-SROA runs before _detect_sret in the main walker, but
        # the error path in _detect_sret fires unchanged.
        f(a::UInt32, b::UInt64) = (a, b)
        @test_throws ErrorException extract_parsed_ir(
            f, Tuple{UInt32, UInt64}; optimize=false)
    end
end
```

Add to `test/runtests.jl` after line 56 (`include("test_sret.jl")`):

```julia
include("test_uyf9_memcpy_sret.jl")
```

### Expected RED states

Before the fix:

- `"n=3 UInt32 extracts under optimize=false"` fails with
  `ErrorException "sret with llvm.memcpy form is not supported..."`.
- `"n=9 UInt64 extracts under optimize=false"` fails with the same error.
- `"optimize=false + user-requested passes=[...]"` fails with the same error.
- `"heterogeneous struct-sret still fails loud"` PASSES already (no change).
- `"non-sret function under optimize=false"` PASSES already.
- `"optimize=true path untouched"` PASSES already (β landed).
- `"optimize=false + preprocess=true still works"` PASSES already.
- `"n=3 UInt32 full roundtrip"` fails at the `extract_parsed_ir` call.

After the fix: all seven testsets GREEN.

---

## 5. `test_sret.jl:125-136` update — spelled out

The current testset at `test/test_sret.jl:125-136` asserts the exact
error message for memcpy-form sret under `optimize=false`. After γ
lands, that error is no longer emitted for the exact input — γ converts
it to a successful extraction. The testset must be UPDATED, not
preserved.

Replace lines 125-136:

```julia
    @testset "error: optimize=false memcpy form rejected with helpful message" begin
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        ex = try
            extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32}; optimize=false)
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("memcpy", ex.msg)
        @test occursin("optimize=true", ex.msg)
    end
```

with:

```julia
    @testset "optimize=false memcpy form now auto-canonicalises (Bennett-uyf9)" begin
        # Bennett-uyf9 (γ): memcpy-form sret under optimize=false is now
        # auto-resolved by prepending ["sroa", "mem2reg"] to the pass
        # pipeline when sret is detected. The previous error message
        # ("sret with llvm.memcpy form is not supported") no longer fires
        # for this input.
        #
        # The original error path is preserved in _collect_sret_writes
        # (`ir_extract.jl:451-461`) — it now only fires if SROA somehow
        # fails to eliminate the memcpy, which would indicate a genuine
        # extractor bug. Full coverage of the new behaviour lives in
        # test_uyf9_memcpy_sret.jl.
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        parsed = extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32}; optimize=false)
        @test parsed.ret_width == 96
        @test parsed.ret_elem_widths == [32, 32, 32]
    end
```

**Rationale for this exact shape:**

- The testset name changes from `"error: ... rejected with helpful message"`
  to `"optimize=false memcpy form now auto-canonicalises (Bennett-uyf9)"`
  so that a reader running the suite sees explicitly which bead
  deprecated the old error path.
- The assertions are intentionally minimal (`ret_width`,
  `ret_elem_widths`) to avoid duplicating the fuller coverage in
  `test_uyf9_memcpy_sret.jl`. This testset is the "did the old behaviour
  change?" canary, not the full γ acceptance test.
- The inline comment documents what happened and points the next reader
  at the new test file.
- Critically, we **leave the `_ir_error` call at `src/ir_extract.jl:451-461`
  in place** — it now acts as a defensive check: if SROA fails to
  canonicalise the memcpy for some pathological input, the original
  helpful error still fires. The message stays accurate because the
  user-facing workaround ("Re-compile with optimize=true ... or set
  preprocess=true") still works. We could refine the message to also
  mention that this should no longer be reachable after γ, but that's
  gold-plating for a follow-up.

---

## 6. Regression plan

### 6.1 Automated test suite

Run the full `Pkg.test()` and confirm all GREEN. Particularly watch:

1. **`test_sret.jl`** — all 8 testsets must pass with the updated
   testset 8 from §5. Testsets 1-7 are byte-identical expectations and
   must not shift. Testset 7 (`n=2 by-value regression`) is the gate-count
   baseline `@test gate_count(circuit).total == 82` — must hold
   (§6.2 below).
2. **`test_tuple.jl`** — n=2 aggregate return paths, no sret
   involved. Must pass byte-identically.
3. **`test_extractvalue.jl`** — n=2 aggregate access paths. Must pass
   byte-identically.
4. **`test_gate_count_regression.jl`** — the CLAUDE.md §6 baselines:
   i8=86, i16=174, i32=350, i64=702. Auto-prepend must NOT fire for
   these (they're non-sret scalar returns). If a baseline shifts, γ is
   touching code it shouldn't.
5. **`test_uyf9_memcpy_sret.jl`** (new) — all 8 testsets GREEN.

### 6.2 Gate-count baselines

CLAUDE.md §6 baselines to verify unchanged:

| Function | Expected gates |
|---|---|
| `x -> x + Int8(1)` | 86 (i8 adder) |
| `x -> x + Int16(1)` | 174 (i16 adder) |
| `x -> x + Int32(1)` | 350 (i32 adder) |
| `x -> x + Int64(1)` | 702 (i64 adder) |
| `(a, b) -> (b, a)` (Int8) | 82 (swap pair, see `test_sret.jl:116`) |

None of these exercise sret, so `_module_has_sret` returns false and
`effective_passes` stays empty. Byte-identical to pre-γ.

Run via:

```bash
julia --project test/test_gate_count_regression.jl
julia --project test/test_sret.jl
julia --project test/test_increment.jl  # i8 baseline
```

### 6.3 Manual live-repro verification

Reproduce the ground-truth from `docs/design/p6_research_local.md §3.5`
to confirm the exact repro is fixed:

```bash
julia --project -e '
using Bennett
g(state::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(state, k, v)
pir = Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8}; optimize=false)
println("ret_width = ", pir.ret_width)
println("args     = ", pir.args)
println("elems    = ", pir.ret_elem_widths)
'
```

Expected output after γ:

```
ret_width = 576
args     = [(Symbol("state::Tuple"), 576), (Symbol("k::Int8"), 8), (Symbol("v::Int8"), 8)]
elems    = [64, 64, 64, 64, 64, 64, 64, 64, 64]
```

(No error.)

### 6.4 Non-regression sampling

For peace of mind, spot-check on representative existing workloads:

- `reversible_compile(x -> x * x + 3*x + 1, Int8)` — i8 polynomial,
  scalar return, no sret.
- `reversible_compile((a, b) -> a | b, Int16, Int16)` — bitwise, scalar
  return, no sret.
- `reversible_compile(soft_fadd, UInt64, UInt64)` — soft-float addition,
  scalar return, no sret.

All three should report identical gate counts pre- and post-γ.

---

## 7. Risk analysis

### 7.1 IR-shape drift under new SROA pass (C1-specific)

**Risk:** SROA runs on every function in the module when sret is
detected. If a non-sret helper function in the same module happens to
have an alloca that SROA promotes, its IR shape changes. This could
surface if `_find_entry_function` ever walks a non-sret entry in a
module with an sret sibling.

**Exposure:** narrow. `_find_entry_function` picks exactly one function
(the first `julia_*` with a body, or a name-matched entry). Changes to
other functions are invisible to the walker. No gate counts in the test
suite can shift via this mechanism — verified by reasoning about what
`_module_to_parsed_ir_on_func` reads.

**Mitigation:** the regression run of `test_gate_count_regression.jl` +
`test_sret.jl` + `test_tuple.jl` + `test_extractvalue.jl` covers every
current sret/aggregate path. Any shift fails a test, which is the
desired RED signal per CLAUDE.md §6.

### 7.2 SROA behavioural surprise — CLAUDE.md §5 violation?

**Risk:** CLAUDE.md §5 says "Always use optimize=false for predictable
IR when testing." A user setting `optimize=false` might now get
post-SROA IR when they expected pre-SROA. This is a subtle divergence
from the documented contract.

**Exposure:** narrow but real. The divergence only fires when sret is
present, which is only for aggregate-returning functions (n ≥ 3
typically). The "predictable IR" principle is primarily aimed at
integer-scalar testing, which is unaffected.

**Mitigation:**

1. Document the behaviour in the γ WORKLOG entry and in
   `extract_parsed_ir`'s docstring. Update the docstring block at lines
   26-40 to note: "When an sret parameter is present and `passes` does
   not already include `sroa`, Bennett-uyf9 auto-prepends `[sroa,
   mem2reg]` to canonicalise memcpy-form sret."
2. The `preprocess=true` escape hatch remains available if a user
   genuinely wants to observe the pre-SROA shape — though if sret is
   present, SROA would still run on their behalf.
3. For callers who need "pre-SROA, sret-preserved" IR (an edge case I
   can't motivate concretely), a follow-up bead can add a
   `sret_auto_sroa=true` kwarg with a default matching γ's new
   behaviour. Not in γ's scope.

### 7.3 Interaction with β's vector-store path

**Risk:** β added `_collect_sret_writes` vector-store handling
(`src/ir_extract.jl:522-554`). Under `optimize=true` with sret, γ now
auto-prepends SROA. Could running SROA *again* on β's post-optimiser
vector stores trip β's assumptions?

**Exposure:** very narrow. SROA does not undo SLP vectorisation — the
vector stores stay as `store <4 x i64>`. SROA's only effect on
already-SROA'd IR is to promote any residual alloca-based code (there
won't be any, because Julia's optimiser already did this). So β's
vector-store handler sees the same IR it saw before γ.

**Mitigation:** the new test `"optimize=true path untouched"` in
`test_uyf9_memcpy_sret.jl` asserts end-to-end that β's ret_elem_widths
output is unchanged for the load-bearing shape
(`NTuple{9,UInt64}, Int8, Int8`). If β and γ interact badly, this test
goes RED.

**Orthogonality check:** β's pre-walker (`_collect_sret_writes`) runs
*after* `effective_passes` are applied, so both β's and γ's concerns
meet on the same post-pass IR. They read different instruction shapes
(β reads `store <N x iM>`, γ reads `store iM` post-SROA) and do not
share mutable state. Orthogonal.

### 7.4 Risk I'm not certain about

**Risk:** could SROA on `-O0` Julia IR introduce phi nodes in unexpected
places, tripping `lower.jl`'s phi resolution (CLAUDE.md "Phi Resolution
and Control Flow — CORRECTNESS RISK")?

**Exposure:** unknown. The research doc §4.3 confirmed the
`optimize=false, preprocess=true` path works for the load-bearing case
— but only verified that `extract_parsed_ir` succeeds, not that the
resulting `ParsedIR` lowers to a correct circuit.

**Mitigation:** the new test's `"n=3 UInt32 full roundtrip under
optimize=false"` testset exercises `extract → lower → bennett →
simulate` end-to-end with 4 input tuples. If SROA introduces phi nodes
that trip the phi resolver, `verify_reversibility` fails and we know
immediately. Broader phi-CFG coverage (e.g., the diamond test in β's
regression set) is not repeated here — γ inherits whatever β verified.

---

## 8. Implementation sequence

Ordered steps with RED→GREEN checkpoints. Each is a single git-commit-
sized unit of work.

### Step 1 — RED: write the test file

Create `test/test_uyf9_memcpy_sret.jl` with the full content from §4.
Add `include("test_uyf9_memcpy_sret.jl")` to `test/runtests.jl` after
line 56.

**Check:** Run `julia --project test/test_uyf9_memcpy_sret.jl`.
**Expected RED:**

- `"n=3 UInt32 extracts under optimize=false"` fails with the memcpy
  error.
- `"n=9 UInt64 extracts under optimize=false"` fails with the memcpy
  error.
- `"optimize=false + user-requested passes=[...]"` fails with the
  memcpy error.
- `"n=3 UInt32 full roundtrip under optimize=false"` fails at the
  `extract_parsed_ir` call.
- Everything else already passes.

### Step 2 — RED: update test_sret.jl testset 8

Edit `test/test_sret.jl` lines 125-136 per §5. No new file, just the
replacement inline.

**Check:** Run `julia --project test/test_sret.jl`.
**Expected RED:** testset 8 now expects a successful extraction but
γ isn't implemented yet, so it fails with the same memcpy error
(now bubbling up as a failed extraction instead of an expected
`ErrorException`).

### Step 3 — GREEN: implement `_module_has_sret`

Insert the new helper from §2.4 into `src/ir_extract.jl` immediately
above `_detect_sret` (around line 369).

**Check:** Run `julia --project -e 'using Bennett'` — ensure no
compile errors. No test impact yet because nothing calls the helper.

### Step 4 — GREEN: wire auto-prepend into `extract_parsed_ir`

Add the conditional auto-prepend block from §2.3 into
`extract_parsed_ir` inside the `LLVM.Context() do _ctx ... end` block,
immediately after `parse(LLVM.Module, ir_string)` and before the
`isempty(effective_passes)` check.

**Check:** Run the full test suite with
```bash
julia --project -e 'using Pkg; Pkg.test()'
```
**Expected GREEN:** all 8 testsets of `test_uyf9_memcpy_sret.jl` pass,
`test_sret.jl` testset 8 passes, everything else unchanged.

### Step 5 — Regression verification

Spot-check the gate-count baselines per §6.2:

```bash
julia --project -e '
using Bennett
using Bennett: reversible_compile, gate_count
for (f, T, expected) in [
    (x -> x + Int8(1), Int8, 86),
    (x -> x + Int16(1), Int16, 174),
    (x -> x + Int32(1), Int32, 350),
    (x -> x + Int64(1), Int64, 702),
]
    c = reversible_compile(f, T)
    actual = gate_count(c).total
    @assert actual == expected "expected $expected got $actual for $T"
    println("OK $T: $actual")
end
'
```

**Expected GREEN:** all four baselines unchanged.

### Step 6 — Manual live-repro

Run the γ-specific live repro from §6.3 and verify the output matches
the expected shape.

**Expected GREEN:** extraction succeeds, no error.

### Step 7 — WORKLOG entry

Per CLAUDE.md Principle 0, append a γ session entry to `WORKLOG.md`.
Key points:

- γ lands C1 (auto-SROA on sret detection), not C2 (Enzyme port).
- Fix is ~12 LOC total (`_module_has_sret` + one conditional block in
  `extract_parsed_ir`).
- `test_sret.jl:125-136` testset was updated, not preserved — prior
  behaviour was `@test ex isa ErrorException`; new behaviour is
  successful extraction.
- Gate-count baselines unchanged.
- Known limitation: `use_memory_ssa=true` under `optimize=false, sret
  present` now sees pre-SROA memssa annotations but post-SROA walker
  IR. Follow-up bead for that.
- Open question for future agent: if a user sets
  `passes=String[]` explicitly (empty), they still implicitly get
  `["sroa", "mem2reg"]` when sret is present. Is this surprising?
  Currently: no, because the empty vector is identical to `nothing`
  from the caller's perspective. Future: consider a
  `sret_auto_sroa::Bool` kwarg.

### Step 8 — Commit

One commit with all of Steps 1-7 batched, following the codebase's
commit style (sample: `git log` shows terse subject lines like
"Fix Bennett-r6e3: soft_fdiv subnormal bug via pre-normalization"):

```
Fix Bennett-uyf9: memcpy-form sret via auto-SROA when sret detected
```

Body bullets: what/why/test/regression-proof/follow-ups.

**Do not push** until Bennett-z2dj unblocks; γ is a prerequisite for
z2dj but the two lands together per the consensus plan in
`docs/design/p6_consensus.md §2`.

---

## 9. Open questions and uncertainties

### 9.1 Does `_run_passes!` fail on `passes=["sroa", "mem2reg"]` for a module with no allocas?

**Best guess:** no — running SROA on an alloca-free module is a no-op
per LLVM's New Pass Manager documentation. No documented precedent of a
stock LLVM pass erroring on an empty workload. But I didn't verify
empirically on the `optimize=true` IR shape.

**Mitigation:** Step 4's GREEN check runs the full test suite including
the `optimize=true` path, which covers this case.

### 9.2 Does auto-prepending SROA affect Bennett's 2× gate-count-per-width-doubling invariant?

**Best guess:** no — the adder/multiplier gate counts are set by
`src/adder.jl` and `src/multiplier.jl`, which don't go through sret
paths. SROA runs only on sret modules, which are aggregate-return
functions. Non-aggregate arithmetic paths are untouched.

**Mitigation:** Step 5's regression verification confirms this directly
for i8/i16/i32/i64.

### 9.3 Does the order of `["sroa", "mem2reg"]` matter?

**Best guess:** yes, but the chosen order is correct. SROA splits
aggregate allocas first; mem2reg promotes any residual scalar allocas
to SSA. Running mem2reg first would leave aggregate allocas intact (it
doesn't split aggregates), and SROA then has nothing to bind to
because the stores have already been SSA-promoted with the wrong shape.

**Mitigation:** this is the same order `DEFAULT_PREPROCESSING_PASSES`
uses. Verified empirically via the `preprocess=true` workaround
success in `docs/design/p6_research_local.md §4.3`.

### 9.4 Subtle: what if `_module_has_sret` returns true but the entry function itself is non-sret?

**Scenario:** module has entry function `f(x)::Int8` plus a helper
`g(state)::NTuple{9,UInt64}` that's kept as a non-inlined call. SROA
runs on both; `_find_entry_function` picks `f`, which has no aggregate
allocas; SROA is a no-op on `f`'s body.

**Mitigation:** this is fine — SROA on `f` is idempotent, and the
walker sees `f`'s unchanged IR. `g` benefits from SROA if it's ever
extracted separately (e.g., via `lower_call!`'s re-invocation of
`extract_parsed_ir`).

### 9.5 Not verified: does SROA emit phi nodes for the post-memcpy shape that the phi resolver handles?

**Best guess:** the research doc's `/tmp/g_noopt_sroa.ll:49-66` excerpt
shows clean scalar stores only — no phi nodes introduced by SROA for
this specific workload. But SROA *can* emit phi nodes when values flow
through branches, and the `optimize=false` IR has many such branches
(L15/L16/L17/...).

**Mitigation:** the new test's `"n=3 UInt32 full roundtrip"` testset
exercises the full lower+bennett pipeline under `optimize=false`,
which will trip the phi resolver if SROA introduces pathological
phis. The test picks `(a, b, c) -> (a, b, c)` — identity — which has
no branches, so phi introduction is unlikely there. A stronger test
would use a branching function like `(a, b, c) -> a < b ? (a, b, c) :
(c, b, a)` but that's a belt-and-suspenders addition for a later bead.

---

## 10. Minimal-change summary

- **File touched:** `src/ir_extract.jl` only.
- **LOC added:** ~15 (10 for `_module_has_sret`, 5 for the conditional
  block).
- **LOC deleted:** 0 (the existing memcpy error path at lines 451-461
  stays as defensive fallback).
- **Existing tests changed:** `test/test_sret.jl` lines 125-136 (one
  testset replaced; same file position; adjacent testsets untouched).
- **New test file:** `test/test_uyf9_memcpy_sret.jl` (~100 lines, 8
  testsets).
- **Public API changes:** none.
- **Gate-count impact on non-sret paths:** zero (verified by design,
  tested in regression).

---

## 11. Critical fail-loud points (CLAUDE.md §1 check)

1. `_module_has_sret` short-circuits on first hit and returns `Bool`.
   No silent fallback — always definitive.
2. Auto-prepend only fires when both conditions are met (`sroa` not
   already present AND sret detected). If the conditions fail, we do
   exactly nothing — no silent side effects.
3. Existing `_collect_sret_writes` rejection at lines 451-461 stays in
   place as a defensive check. If SROA fails to canonicalise the memcpy
   for a pathological input, the original helpful error still fires —
   no silent miscompile.
4. `_detect_sret`'s existing fail-loud paths (multiple sret, struct
   pointee, non-integer element, bad width) are all untouched. γ does
   not weaken any of them.

---

**End of Proposer A design.**
