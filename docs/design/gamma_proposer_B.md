# Bennett-uyf9 (γ) — Proposer B

**Bead:** Bennett-uyf9 — `ir_extract: handle memcpy-form sret under optimize=false (auto-SROA or Enzyme-style split)`
**Author:** Proposer B (independent)
**Date:** 2026-04-21
**Status:** proposal (not yet implemented)
**Peers:** α = Bennett-atf4 (SHIPPED), β = Bennett-0c8o (SHIPPED). This γ proposal is the third and final of the T5-P6 triad.

---

## 0. TL;DR

**Recommendation: Option C1 (auto-SROA on sret detection), with three small hardenings that make it safe for the `optimize=false` contract stated in CLAUDE.md §5.**

Why C1 over C2:

1. C1 is a **~15 LOC change** in `extract_parsed_ir` and its two sibling entry points; C2 is a **~120+ LOC port** of Enzyme's `memcpy_sret_split!` + `copy_struct_into!`, plus a new pass-registration concern, plus a maintenance burden on every LLVM.jl version bump.
2. The **empirical workaround already works** (`p6_research_local.md` §4.3, §10.4): `optimize=false, preprocess=true` on the live `NTuple{9,UInt64}` repro produces exactly the slot-by-slot stores `_collect_sret_writes` was written for. We are not guessing — the fix is already validated, we just need to wire it in automatically.
3. C2's upsides (byte-identical IR outside sret, out-of-optimizer) only matter if users are already observing SROA-pass side-effects **and** we can't constrain the pipeline. We can: see §4.3 below for the "minimal SROA-only" scope restriction.
4. CLAUDE.md §5 ("optimize=false for predictable IR") is not violated: SROA is **deterministic** and the user has already opted into `preprocess=true` semantics whenever sret is present — we're just removing the foot-gun. We additionally preserve an opt-out (§4.5).

The three hardenings in C1 (§4.4):
- **Scope the auto-SROA to sret-bearing functions only**, not to the whole module unconditionally.
- **Run a minimal pass list** (`"sroa"` only, or `"sroa,mem2reg"`), not the full `DEFAULT_PREPROCESSING_PASSES` — to minimise IR-shape drift.
- **Provide an explicit escape hatch** (`auto_preprocess_sret=false`) so a user debugging IR can turn it off.

---

## 1. Preamble — what the brief + landed work already establishes

α (Bennett-atf4) shipped: `lower_call!` derives real callee arg types from `methods()`, so an NTuple-typed callee types correctly at dispatch time. **No γ dependency here.**

β (Bennett-0c8o) shipped: `_collect_sret_writes` now handles vector-lane sret stores via a pending-lane table (see `src/ir_extract.jl:436-438, 522-554, 614-644`). `_convert_vector_instruction` learned `LLVMLoad` so a `<4 x i64>` load feeding a vector-store is lane-resolvable. **β fixes `optimize=true`.** γ fixes `optimize=false`.

γ's scope — the **memcpy-form sret** — is orthogonal to β's scope. Under `optimize=false`:

```
%"new::Tuple" = alloca [9 x i64], align 8
; ... per-slot i64 stores into %"new::Tuple" at offsets 0, 8, ..., 64 ...
call void @llvm.memcpy.p0.p0.i64(ptr align 8 %sret_return,
                                  ptr align 8 %"new::Tuple",
                                  i64 72, i1 false)
ret void
```

`_collect_sret_writes` rejects this at `src/ir_extract.jl:451-461` (I'll call this site **R** hereafter).

The post-fix post-SROA IR from `p6_research_local.md:749-754` is:

```
store i64 %14, ptr %sret_return, align 8                                 ; slot 0
%"…sroa_idx" = getelementptr inbounds i8, ptr %sret_return, i64 8
store i64 %11, ptr %"…sroa_idx", align 8                                  ; slot 1
... seven more i64 stores at offsets 16, 24, ..., 64
ret void
```

— **exactly the shape that the existing pre-walk at `src/ir_extract.jl:508-586` handles byte-for-byte.** No downstream change needed. This is key to why C1 is viable.

---

## 2. Design options, evaluated

### 2.1 Option C1 — auto-SROA on sret detection

**Where:** `extract_parsed_ir`, `extract_parsed_ir_from_ll`, `extract_parsed_ir_from_bc` — `src/ir_extract.jl:41-81, 111-150, 164-191`.

**What:** When building `effective_passes`, peek ahead at the parsed module, run `_detect_sret` on the entry function, and if sret is present AND the user has not already requested `preprocess=true`, prepend a minimal SROA-only pass list.

**Cost:** ~15 LOC. No new pass logic; we piggyback on the existing `_run_passes!` plumbing (`src/ir_extract.jl:195-202`) and on the existing `_detect_sret` (`src/ir_extract.jl:370-404`).

**Trade-off:** runs an LLVM pass when the user asked for `optimize=false`. CLAUDE.md §5 says "always use `optimize=false` for predictable IR when testing" — but SROA is deterministic (same input ⇒ same output) and is only triggered when sret is detected. §4.5's opt-out preserves the escape hatch.

### 2.2 Option C2 — port Enzyme's `memcpy_sret_split!`

**Where:** new helper in `src/ir_extract.jl`, called from `_collect_sret_writes` before the memcpy rejection at site R.

**What:** walk the function, find `llvm.memcpy` calls targeting the sret pointer with matching total byte size, replace each with N typed load/store pairs (one per sret slot), then erase the memcpy. Subsequent `_collect_sret_writes` sees only scalar stores.

**Cost:** ~120 LOC of Julia-LLVM.jl IR-building glue, mirroring `copy_struct_into!` (`EnzymeAD/Enzyme.jl:src/compiler.jl:4152-4219`). Plus InstCombine run to break up aggregate-value stores if any surface. Plus careful handling of the `any_jltypes` gate — Enzyme only descends pointer-bearing paths; we must descend all paths.

**Trade-off:** more code, more maintenance. Upside: byte-identical IR outside sret, no "I ran SROA behind your back" surprise.

### 2.3 Side-by-side

| Dimension | C1 (auto-SROA) | C2 (Enzyme-style split) |
|---|---|---|
| LOC | ~15 | ~120+ |
| Surface area for bugs | new kwarg, one extra `_detect_sret` call pre-pass | hand-rolled LLVM IRBuilder walker |
| IR shape outside sret | SROA may alter unrelated allocas | untouched |
| User-visible behaviour | `optimize=false` now "just works" for sret | same |
| Maintenance on LLVM.jl upgrades | low (LLVM SROA pass is stable) | medium (IRBuilder API drift, opaque-pointer migration) |
| Interacts with β's vector path | no | no |
| Test-surface cost | 1 new test file + 1 test update | 1 new test file + 1 test update + unit tests for the splitter |
| Precedent | already works as `preprocess=true` today | Enzyme MIT-licensed |

**Verdict: C1.** The "IR shape outside sret may drift" risk is real but isolatable — see §4.3 (minimal pass set) and §8 (risk plan).

---

## 3. The bug, reproducible

**Live repro** (from the brief, re-verified in `p6_research_local.md:513-521`):

```julia
using Bennett
g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
    Bennett.linear_scan_pmap_set(state, k, v)
Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8}; optimize=false)
# → ErrorException: ir_extract.jl: call in @julia_g_NNN:%L86:
#   call void @llvm.memcpy.p0.p0.i64(ptr align 8 %sret_return,
#     ptr align 8 %"new::Tuple", i64 72, i1 false)
#   — sret with llvm.memcpy form is not supported (emitted under optimize=false).
#   Re-compile with optimize=true (Bennett.jl default) or set preprocess=true
#   to canonicalise via SROA/mem2reg.
```

**Rejection site (R):** `src/ir_extract.jl:449-465` (transcribed):

```julia
# llvm.memcpy into sret → reject (optimize=false form)
if opc == LLVM.API.LLVMCall
    ops = LLVM.operands(inst)
    n_ops = length(ops)
    if n_ops >= 1
        cname = try LLVM.name(ops[n_ops]) catch; "" end
        if startswith(cname, "llvm.memcpy")
            if n_ops >= 2 && ops[1].ref === sret_ref
                _ir_error(inst,
                    "sret with llvm.memcpy form is not supported " *
                    "(emitted under optimize=false). Re-compile with " *
                    "optimize=true (Bennett.jl default) or set " *
                    "preprocess=true to canonicalise via SROA/mem2reg.")
            end
        end
    end
end
```

**Post-SROA IR** that `_collect_sret_writes` already handles:

```
store i64 %14, ptr %sret_return, align 8                                 ; slot 0
%sroa_idx_8  = getelementptr inbounds i8, ptr %sret_return, i64 8
store i64 %11, ptr %sroa_idx_8, align 8                                   ; slot 1
%sroa_idx_16 = getelementptr inbounds i8, ptr %sret_return, i64 16
store i64 %x2, ptr %sroa_idx_16, align 8                                  ; slot 2
...
ret void
```

`_collect_sret_writes`'s scalar store path at `src/ir_extract.jl:509-586` handles all nine slots without modification.

---

## 4. Option C1 — concrete design

### 4.1 Public kwargs

Add one kwarg to `extract_parsed_ir` and its two `_from_ll` / `_from_bc` siblings:

```julia
auto_preprocess_sret::Bool = true
```

Default: `true`. When `true`, and sret is detected on the entry function, and no explicit `preprocess=true` was supplied, a minimal SROA-only pass list is auto-prepended.

Rationale for defaulting to `true`: today the error message at R already tells users "set preprocess=true" — i.e. the user is already expected to run SROA. Auto-preprocess just does this step for them.

Users who want byte-stable `optimize=false` IR for debugging set `auto_preprocess_sret=false` and handle the sret-memcpy themselves (via `preprocess=true`, or by letting the error fire).

### 4.2 Auto-detected pass list

```julia
const SRET_MEMCPY_FALLBACK_PASSES = ["sroa", "mem2reg"]
```

Note: **not** the full `DEFAULT_PREPROCESSING_PASSES`. We intentionally drop `simplifycfg` and `instcombine` here to minimise IR-shape drift (§4.3).

- **`sroa`** — required. Decomposes the `%"new::Tuple" = alloca [9 x i64]` into scalar SSA values and rewrites the memcpy-into-sret into per-slot stores. This is the core canonicalisation.
- **`mem2reg`** — required as a defensive follow-up. SROA sometimes leaves single-value allocas if a slot is loaded once; `mem2reg` promotes those. Empirically necessary: `p6_research_local.md:1132-1133` shows `opt=false passes=["sroa"]` works, and `opt=false passes=["sroa","mem2reg"]` works; we pick the latter for robustness against IR variants.

We do **not** include:
- `simplifycfg` — collapses empty merge blocks. Under `optimize=false`, Julia emits many such blocks (e.g. L15, L16, …, L84 in `/tmp/g_noopt.ll`). Running `simplifycfg` changes block boundaries, which would invalidate any "the block-label matches" assertion elsewhere. Not needed for our fix.
- `instcombine` — local peephole folds. Can change which SSA names appear in the IR. Not needed for our fix.

(If a future user sets `preprocess=true` explicitly, they still get the full `DEFAULT_PREPROCESSING_PASSES`. We are only constraining the *auto* path.)

### 4.3 The scoping question

Do we run these passes on the whole module, or only on the sret-bearing function?

**LLVM New-Pass-Manager `sroa,mem2reg` is a function pass when applied to a function-level adaptor, but the `_run_passes!` helper at `src/ir_extract.jl:195-202` runs them at module level via `NewPMPassBuilder` + a pass-pipeline string.**

- `sroa` with a module-level pipeline string runs function-by-function. Non-sret functions see SROA too, but since SROA only rewrites allocas that it can prove safe to split, effects on a function without a triggering pattern are nil.
- Practically: the Julia module we get from `code_llvm(…; dump_module=true)` contains the entry function plus its call-graph (incl. runtime intrinsics, `jl_f_*` declarations, etc.). Most of those have no bodies. SROA is a no-op on declarations.

**Decision: run the passes at module level via the existing `_run_passes!`.** Scoping to a single function would require a separate `FunctionPass` plumbing path; that's not justified given the observed impact (~zero) on non-sret functions.

However, the **test** I specify below (§5) includes a guard that verifies a pure non-sret function under `optimize=false, auto_preprocess_sret=true` still produces byte-identical `ParsedIR` as under `optimize=false, auto_preprocess_sret=false`, catching any drift.

### 4.4 Algorithm

```julia
function extract_parsed_ir(f, arg_types::Type{<:Tuple};
                           optimize::Bool=true,
                           preprocess::Bool=false,
                           passes::Union{Nothing,Vector{String}}=nothing,
                           use_memory_ssa::Bool=false,
                           auto_preprocess_sret::Bool=true)
    ir_string = sprint(io -> code_llvm(io, f, arg_types;
                                       debuginfo=:none, optimize, dump_module=true))

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

    # γ (Bennett-uyf9): under optimize=false, Julia's specfunc emits
    # aggregate sret returns via alloca + llvm.memcpy. _collect_sret_writes
    # cannot handle that form (it requires per-slot scalar stores). SROA
    # canonicalises the memcpy into the scalar-store form. We only trigger
    # when sret is actually present on the entry function, and only when
    # the user hasn't already requested preprocessing (since that would be
    # a superset).
    if auto_preprocess_sret && !preprocess && !optimize
        if _needs_sret_canonicalisation(ir_string)
            prepend!(effective_passes, SRET_MEMCPY_FALLBACK_PASSES)
        end
    end

    # ... rest unchanged (memssa, _module_to_parsed_ir, ...)
end
```

Where `_needs_sret_canonicalisation` is:

```julia
# γ (Bennett-uyf9): peek at the parsed module, detect sret on the entry
# function, and return true iff an auto-SROA pre-pass is warranted.
# Does a throw-away parse — cheap compared to the main walk.
function _needs_sret_canonicalisation(ir_string::AbstractString)::Bool
    result = false
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        try
            entry = try
                _find_entry_function(mod, nothing)
            catch
                nothing
            end
            entry === nothing && return
            result = _detect_sret(entry) !== nothing
        finally
            dispose(mod)
        end
    end
    return result
end
```

Parallel treatment in `extract_parsed_ir_from_ll` (`src/ir_extract.jl:111-150`) and `extract_parsed_ir_from_bc` (`src/ir_extract.jl:164-191`) — same kwarg, same `_needs_sret_canonicalisation` pre-check but reading from the provided `.ll` / `.bc` (not Julia-source IR). Neither of those paths has a `optimize=` kwarg, so the gate is simply `auto_preprocess_sret && !preprocess` for those.

**Trade-off on `_needs_sret_canonicalisation`:** this does a second `parse(LLVM.Module, ir_string)`, throw-away. Parse is O(module size); typical module is a few hundred lines; cost is sub-millisecond. Worth it to avoid running SROA on non-sret modules (which, per CLAUDE.md §5, we really want to keep byte-stable).

**Alternative:** move the `_detect_sret` into the main body. Pull sret-detection up before `_run_passes!`, then if detected, append SROA + rerun. This avoids the second parse but adds branching to the hot path. I prefer the upfront check — it keeps the pipeline linear and the sret detection single-sourced.

### 4.5 Escape hatch

`auto_preprocess_sret=false` disables the auto-injection. Use case: an agent debugging which LLVM pass mangled their IR, or an `.ll` corpus test that should see the raw memcpy form.

When this is `false` and the memcpy would fire, the existing error at R still fires with its current message — recommending `preprocess=true`. Backwards-compatible.

### 4.6 Why this respects CLAUDE.md §5

Principle §5 says "always use `optimize=false` for predictable IR when testing". The principle is about **LLVM IR determinism**, not about "run zero passes". SROA is deterministic: same input IR ⇒ same output IR. `mem2reg` likewise. The user gets predictable IR; they just get a canonicalised flavour of it.

The alternative — fail loudly — forces every user writing an sret-producing function to know to set `preprocess=true`. That's a foot-gun.

---

## 5. The RED test: `test/test_uyf9_memcpy_sret.jl`

```julia
# Bennett-uyf9 — γ: handle memcpy-form sret under optimize=false.
#
# Under optimize=false, Julia's specfunc emits aggregate sret via
# alloca + llvm.memcpy. Pre-γ, _collect_sret_writes rejected the memcpy
# form at ir_extract.jl:451-461. γ auto-injects SROA+mem2reg when sret
# is detected on optimize=false entry, canonicalising the memcpy into
# the per-slot store shape that the existing pre-walk handles.
#
# See docs/design/gamma_consensus.md for the final design.
# RED→GREEN TDD per CLAUDE.md §3.

using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, extract_parsed_ir
using Bennett: IRInsertValue, IRRet

@testset "Bennett-uyf9 γ — memcpy-form sret under optimize=false" begin

    # ---------------- primary repro: NTuple{9,UInt64} under optimize=false ------
    @testset "linear_scan_pmap_set: optimize=false auto-SROA" begin
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        # Pre-γ: this threw with the "sret with llvm.memcpy form is not
        # supported" message. Post-γ: auto_preprocess_sret=true (default)
        # injects SROA+mem2reg and the extraction succeeds.
        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                optimize=false)

        # Same shape invariants as the β test (test_0c8o_vector_sret.jl:33-54).
        @test pir.ret_width == 576
        @test pir.ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
        @test length(pir.args) == 3
        @test pir.args[1][2] == 576
        @test pir.args[2][2] == 8
        @test pir.args[3][2] == 8

        # Synthetic IRInsertValue chain of length 9 terminated by IRRet.
        last_block = pir.blocks[end]
        iv_chain = [i for i in last_block.instructions if i isa IRInsertValue]
        @test length(iv_chain) == 9
        for (k, iv) in enumerate(iv_chain)
            @test iv.index == k - 1
            @test iv.elem_width == 64
            @test iv.n_elems == 9
            # No pending-lane sentinel survives (β invariant).
            @test !(iv.val.kind == :const &&
                    iv.val.name === :__pending_vec_lane__)
        end
        @test last_block.terminator isa IRRet
        @test last_block.terminator.width == 576
    end

    # ---------------- end-to-end reversible_compile under optimize=false ---------
    # Note: reversible_compile defaults to optimize=true via extract_parsed_ir's
    # default; this test exercises the direct extract path. For the full
    # end-to-end compile we still rely on the β test (test_0c8o_vector_sret.jl:63)
    # which uses optimize=true. γ only needs to prove extraction succeeds under
    # optimize=false and produces an equivalent ParsedIR.
    @testset "optimize=false vs optimize=true: equivalent ret shape" begin
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        pir_noopt = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                       optimize=false)
        pir_opt   = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                       optimize=true)

        # Same return shape; block-level equality not asserted (optimize=true
        # collapses control flow differently).
        @test pir_noopt.ret_width         == pir_opt.ret_width
        @test pir_noopt.ret_elem_widths   == pir_opt.ret_elem_widths
        @test length(pir_noopt.args)      == length(pir_opt.args)
        for i in 1:length(pir_noopt.args)
            @test pir_noopt.args[i][2] == pir_opt.args[i][2]
        end
    end

    # ---------------- opt-out: auto_preprocess_sret=false reverts to error -------
    # Debugging escape hatch. With auto-injection disabled, the existing
    # memcpy rejection at ir_extract.jl:451-461 fires unchanged.
    @testset "auto_preprocess_sret=false preserves pre-γ error behaviour" begin
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        ex = try
            extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                              optimize=false, auto_preprocess_sret=false)
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("memcpy", ex.msg)
        @test occursin("optimize=true", ex.msg)
        @test occursin("preprocess=true", ex.msg)
    end

    # ---------------- smaller sret: n=3 UInt32 under optimize=false --------------
    # Proves auto-SROA doesn't trip for the already-working n=3 case
    # (ensures the auto path is a strict superset of the pre-γ behaviour).
    @testset "n=3 UInt32 identity under optimize=false" begin
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        pir = extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32};
                                 optimize=false)
        @test pir.ret_width == 96
        @test pir.ret_elem_widths == [32, 32, 32]
    end

    # ---------------- regression: non-sret function is unaffected by auto-SROA --
    # CLAUDE.md §5: optimize=false should produce predictable IR. The auto-SROA
    # injection is gated on sret presence; a non-sret function under optimize=false
    # must parse identically with auto_preprocess_sret=true and =false.
    @testset "non-sret function unaffected by auto_preprocess_sret" begin
        f(x::Int8) = x + Int8(3)   # scalar return; no sret

        pir_a = extract_parsed_ir(f, Tuple{Int8}; optimize=false,
                                   auto_preprocess_sret=true)
        pir_b = extract_parsed_ir(f, Tuple{Int8}; optimize=false,
                                   auto_preprocess_sret=false)

        # Structural equivalence: same return, same args, same block count,
        # same per-block instruction count. IRInst equality is structural
        # (Julia default on immutable structs).
        @test pir_a.ret_width       == pir_b.ret_width
        @test pir_a.ret_elem_widths == pir_b.ret_elem_widths
        @test pir_a.args            == pir_b.args
        @test length(pir_a.blocks)  == length(pir_b.blocks)
        for i in 1:length(pir_a.blocks)
            @test length(pir_a.blocks[i].instructions) ==
                  length(pir_b.blocks[i].instructions)
        end
    end

    # ---------------- non-sret function with other memcpys: untouched -----------
    # Bennett.jl's codebase does not currently have a non-sret function that
    # emits an llvm.memcpy at optimize=false through the supported feature set.
    # This testset is a forward guard: if one ever appears, we assert it still
    # extracts (SROA doesn't corrupt its IR) under auto_preprocess_sret=true.
    # Today it's identical to the "non-sret unaffected" test above.
    @testset "non-sret memcpy (placeholder — see gamma_consensus §regression)" begin
        # No direct construction available; smoke-test via a medium-sized
        # identity function whose optimize=false IR we know doesn't memcpy.
        f(a::UInt32, b::UInt32) = (a + b) ⊻ (a - b)
        pir = extract_parsed_ir(f, Tuple{UInt32, UInt32}; optimize=false)
        @test pir.ret_width == 32
        @test pir.ret_elem_widths == [32]
    end

    # ---------------- interaction with explicit preprocess=true -----------------
    # A user who sets preprocess=true gets the full DEFAULT_PREPROCESSING_PASSES.
    # auto_preprocess_sret must NOT double-prepend SROA in that case.
    @testset "explicit preprocess=true supersedes auto_preprocess_sret" begin
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        # Before γ: preprocess=true on optimize=false already worked
        # (p6_research_local.md:760-767). Post-γ: same behaviour, no regression.
        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                 optimize=false, preprocess=true)
        @test pir.ret_width == 576
        @test pir.ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
    end

    # ---------------- interaction with β's optimize=true path -------------------
    # Sanity: γ's auto-injection is gated on !optimize, so optimize=true is
    # unaffected. β's vector-lane sret path still handles the <4 x i64> case.
    @testset "optimize=true path unchanged by γ" begin
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            Bennett.linear_scan_pmap_set(state, k, v)

        # This is the β-shipped behaviour; γ must not break it.
        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                 optimize=true)
        @test pir.ret_width == 576
        @test pir.ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
    end
end
```

### 5.1 Update to `test/test_sret.jl:125-136`

The current test **asserts** the memcpy error fires. Post-γ, that is no longer the default behaviour — so the test must be **updated**, not preserved. Exact proposed replacement:

```julia
    @testset "error: optimize=false memcpy form rejected when auto-SROA disabled" begin
        # Pre-γ (Bennett-uyf9): this used to error by default. Post-γ, the
        # default optimize=false path auto-injects SROA+mem2reg when sret is
        # detected, so memcpy is canonicalised and extraction succeeds. To
        # observe the pre-γ error behaviour (e.g. for IR-shape debugging),
        # pass auto_preprocess_sret=false. See test_uyf9_memcpy_sret.jl
        # for the happy-path coverage.
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        ex = try
            extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32};
                              optimize=false,
                              auto_preprocess_sret=false)
            nothing
        catch e
            e
        end
        @test ex isa ErrorException
        @test occursin("memcpy", ex.msg)
        @test occursin("optimize=true", ex.msg)
        @test occursin("preprocess=true", ex.msg)
    end
```

The testset name changes subtly (adds `when auto-SROA disabled`), the invocation adds `auto_preprocess_sret=false`, the comment documents the γ change. Everything else — the three `@test occursin` assertions — is preserved verbatim.

### 5.2 `runtests.jl` hook

Add after `include("test_0c8o_vector_sret.jl")` (line 107):

```julia
# Bennett-uyf9 — γ: memcpy-form sret under optimize=false (auto-SROA).
# Closes the last T5-P6 blocker on top of α (Bennett-atf4) and β (Bennett-0c8o).
include("test_uyf9_memcpy_sret.jl")
```

---

## 6. Edge cases (from the brief)

### 6.1 memcpy size ≠ sret aggregate size

**Question:** What if the memcpy's size operand doesn't match `sret_info.agg_byte_size`?

Under C1, this question is subsumed by SROA: SROA will only rewrite the memcpy if it's safe. If the sizes don't match, SROA leaves the memcpy alone; `_collect_sret_writes` then still sees the memcpy at R and errors. The error message remains appropriate ("memcpy form is not supported").

Under C1, the only new failure mode is: SROA runs but doesn't remove the memcpy. In that case the existing error at R fires after SROA. This is a **fail-loud** outcome per CLAUDE.md §1 — not a silent miscompile. We just keep the error text.

**Recommendation:** no new error handling needed. If SROA fails to canonicalise for any reason, the existing R error is the correct outcome.

### 6.2 memcpy destination ≠ sret pointer

**Question:** What if the memcpy goes somewhere else (e.g. between two allocas)?

Under C1, SROA runs on the whole module and may eliminate or leave alone such memcpys depending on usage. Either way, `_collect_sret_writes` only inspects memcpys whose first operand is the sret pointer (see R's `ops[1].ref === sret_ref` guard at `src/ir_extract.jl:456`). Unrelated memcpys are not our problem at R; they flow through to `_convert_instruction` which handles `LLVMCall` instructions uniformly.

**Recommendation:** no new logic needed. R already filters.

### 6.3 Multiple memcpys targeting the sret

**Question:** What if there are two memcpys into `%sret_return` in the same function?

LLVM LangRef + Julia's emitter: Julia does not emit multiple memcpys into the same sret in the optimize=false path. The pattern is always `alloca-fill-then-single-memcpy-at-ret`. Under SROA, all slot-stores end up as direct stores to `%sret_return`.

**However**, post-SROA, if two code paths converge into the sret via different stores to the same byte offset, the existing pre-walk at `src/ir_extract.jl:569-580` rejects "sret slot N has multiple stores" — this is the correct failure mode.

**Recommendation:** existing duplicate-store check handles this. No new logic.

### 6.4 Non-sret functions with memcpys elsewhere

**Question:** Under C1's auto-SROA, will we inadvertently mangle non-sret memcpy-using functions?

Answer: SROA is designed to only rewrite IR where it can prove the rewrite is semantics-preserving. A non-sret function's memcpy between allocas is fair game for SROA regardless of γ. This already happens today when the user explicitly sets `preprocess=true`.

**Concrete safeguard:** the `_needs_sret_canonicalisation` gate (§4.4) ensures auto-SROA only runs on modules where sret is detected on the entry function. A non-sret entry function gets no auto-SROA.

**Test coverage:** the "non-sret function unaffected by auto_preprocess_sret" testset in §5 above explicitly verifies this.

### 6.5 sret with multiple conflicting pass orderings

**Question:** When the user explicitly sets `preprocess=true`, does the auto-γ injection stack on top (double SROA)?

Answer: no. The logic at §4.4 is:

```julia
if auto_preprocess_sret && !preprocess && !optimize
    if _needs_sret_canonicalisation(ir_string)
        prepend!(effective_passes, SRET_MEMCPY_FALLBACK_PASSES)
    end
end
```

`!preprocess` short-circuits the auto path when the user has already asked for the broader preprocess pipeline. SROA-twice is harmless (idempotent) but we keep the logic clean.

**Test coverage:** the "explicit preprocess=true supersedes auto_preprocess_sret" testset in §5.

---

## 7. Regression plan

| # | Suite / file | What it proves | Why γ doesn't break it |
|---|---|---|---|
| R1 | `test/test_sret.jl:14-117` (testsets `n=3 UInt32 identity` through `regression: n=2 by-value path still works`) | Existing sret coverage (n=2..n=8), including `gate_count(swap2).total == 82` baseline | γ is gated on `optimize=false && auto_preprocess_sret && sret-detected`; all these tests default to `optimize=true`. Byte-identical gate counts. |
| R2 | `test/test_sret.jl:119-123` (error: struct-typed sret) | Heterogeneous struct sret is rejected | Rejection is in `_detect_sret` (`src/ir_extract.jl:384-387`), pre-dates γ. Not touched. |
| R3 | `test/test_sret.jl:125-136` (error: optimize=false memcpy form) | **UPDATES to add `auto_preprocess_sret=false`.** See §5.1 above. | This is an explicit update, not a regression — the test's content is preserved verbatim except for the one kwarg add. |
| R4 | `test/test_0c8o_vector_sret.jl` (β shipped 2026-04-21) | Vector-lane sret stores under `optimize=true` | γ is gated on `!optimize`, so β's `optimize=true` path is untouched. The "optimize=true path unchanged by γ" testset in §5 explicitly re-verifies. |
| R5 | `test/test_atf4_lower_call_nontrivial_args.jl` (α shipped) | `lower_call!` methods()-based typing | Orthogonal: γ is upstream in the pipeline (extraction, not lowering). |
| R6 | `test/test_increment.jl`, `test/test_polynomial.jl`, `test/test_compare.jl`, etc. | Int8 end-to-end with `reversible_compile` | `reversible_compile` defaults to `optimize=true` via `extract_parsed_ir`. γ only fires under `optimize=false`. |
| R7 | `test/test_ntuple_input.jl` | NTuple-by-reference INPUT (not output) | γ is an sret (output) fix. NTuple input is a `byval`/pointer-arg story, unrelated. |
| R8 | Gate-count regression baselines (CLAUDE.md §6): i8 add = 86, i16 = 174, i32 = 350, i64 = 702 | Width-doubling invariant | These functions all default to `optimize=true`. γ does not run. |
| R9 | `test/test_p5a_ll_ingest.jl`, `test/test_p5b_bc_ingest.jl` | External `.ll` / `.bc` ingest | γ adds `auto_preprocess_sret` kwarg to both paths; existing tests do not pass the new kwarg, so they use the default (`true`). No corpus file in the existing p5 tests uses memcpy-form sret, so auto-injection is a no-op on them. Verified via grep: no `llvm.memcpy` in `test/corpora/`. |
| R10 | All other test files in `test/runtests.jl` | Full suite | γ's auto path fires only when `_detect_sret` returns non-`nothing`. No non-sret test changes behaviour. |

**Execution plan:**

```bash
# Full suite, pre- and post-γ, diff gate counts + pass/fail
julia --project -e 'using Pkg; Pkg.test()'
```

If any gate count changes, investigate (per CLAUDE.md §6 this is a regression signal).

**Acceptance criteria:**
- Full suite passes (all prior tests green, new `test_uyf9_memcpy_sret.jl` green, `test_sret.jl:125-136` updated per §5.1 and green).
- No gate-count deltas on non-sret tests.
- No gate-count deltas on `test_sret.jl:116` (`swap2` → 82 gates).
- Live repro (§3) now extracts without error.

---

## 8. Risk analysis

### 8.1 Risk A — IR-shape drift under new SROA pass

**Probability:** low. **Impact:** could silently alter gate counts.

**Mitigation:** the auto-injection is gated on `_needs_sret_canonicalisation`, which returns `true` only when sret is detected on the entry function. Non-sret tests cannot trigger it. Gate-count baselines (i8 = 86, i16 = 174, …) are all on non-sret functions.

The minimal pass set (`"sroa", "mem2reg"`) reduces drift surface compared to the full `DEFAULT_PREPROCESSING_PASSES`. Notably, we do NOT inject `simplifycfg` (which alters block labels) or `instcombine` (which alters SSA names).

**Test:** the "non-sret function unaffected" testset in §5 compares `auto_preprocess_sret=true` vs `=false` on a pure non-sret function under `optimize=false` and requires structural equality. This is the canary.

### 8.2 Risk B — `_detect_sret` re-parse cost

**Probability:** high (we always do it under `optimize=false`). **Impact:** sub-millisecond per extraction.

`_needs_sret_canonicalisation` parses the IR module a second time. Typical Julia IR module for a small function is a few hundred lines; parse is O(text size) and finishes in well under a millisecond. Bennett's test suite runs thousands of extractions — adding ~0.5ms each is a ~1s total overhead. Acceptable.

**Mitigation (if ever needed):** thread the `sret_info` through to skip the second parse. Out of scope for γ.

### 8.3 Risk C — interaction with `use_memory_ssa=true`

**Probability:** low. **Impact:** MemSSA annotation runs on pre-SROA IR if our injection happens after.

Looking at `extract_parsed_ir` lines 56-64: the `_run_memssa_on_ir` runs on the raw `ir_string` before `_run_passes!`. So MemSSA sees pre-SROA IR. If a user sets both `use_memory_ssa=true` and `optimize=false` on an sret function, the MemSSA annotations will be on the memcpy-form IR while the main walker sees the post-SROA IR — they would diverge.

**Mitigation:** in §4.4, thread the auto-SROA passes into `_run_memssa_on_ir` as well, so both paths see canonicalised IR. Concretely:

```julia
memssa = if use_memory_ssa
    # Apply the same effective_passes (inc. γ's auto-SROA) to the MemSSA path
    # so the two walks see equivalent IR.
    annotated = _run_memssa_on_ir(ir_string;
                                   preprocess=preprocess || gamma_auto_preprocess)
    parse_memssa_annotations(annotated)
else
    nothing
end
```

Where `gamma_auto_preprocess` is a local bool set by the γ gate. This requires reading `_run_memssa_on_ir`; if its `preprocess` kwarg only selects between `DEFAULT_PREPROCESSING_PASSES` and nothing, we may need to extend it to accept an explicit pass list. Out-of-scope detail for the γ proposal — flag as a **follow-up** for the consensus step. Impact is limited because no test in the current suite uses `use_memory_ssa=true` with sret.

**Flagging:** see §11 (open questions).

### 8.4 Risk D — test_sret.jl:125-136 change

**Probability:** the change is intentional. **Impact:** reviewers must notice the test is updated, not preserved.

Brief is explicit: "test_sret.jl:125-136 needs UPDATING, not preserving". §5.1 spells out the exact replacement. The testset name change surfaces the semantic shift in test output.

### 8.5 Risk E — `copy_struct_into!` semantic translation (applies to C2 only, not picked)

For completeness, if C2 were picked: the main semantic risk is Enzyme's `any_jltypes` gate. Enzyme only recurses into pointer-bearing sub-types (since their concern is reference tracking for autodiff). For `[9 x i64]`, `any_jltypes` returns false, so the top-level case emits a single load/store of the whole array — which is **still an aggregate-value store**, exactly what we wanted to avoid. We would have to remove the `any_jltypes` guards.

This is a minor port risk but multiplies the review surface. Another reason to prefer C1.

### 8.6 Risk F — interaction with β's vector-store path

**Probability:** nil. **Impact:** nil.

γ fires only under `optimize=false`. β fires only under `optimize=true` (the vector stores are an `optimize=true` artifact). The two paths never run simultaneously. The "optimize=true path unchanged by γ" testset in §5 re-verifies at test-time.

### 8.7 Risk G — `_from_ll` / `_from_bc` entry points

These accept raw `.ll` / `.bc` and thus have no `optimize` kwarg. Under γ, the gate becomes `auto_preprocess_sret && !preprocess`. If a raw `.ll` file happens to have sret-memcpy form, auto-SROA will decompose it. If the user wanted the raw shape, they set `auto_preprocess_sret=false`.

Existing `test/test_p5a_ll_ingest.jl` and `test/test_p5b_bc_ingest.jl` don't use sret-memcpy fixtures, so no behaviour change. Forward-compatible.

---

## 9. Implementation sequence

Ordered RED-GREEN checkpoints per CLAUDE.md §3.

**Step 1 — RED:** write `test/test_uyf9_memcpy_sret.jl` with the content from §5. Run it. Expected: first testset fails with "sret with llvm.memcpy form is not supported".

```bash
julia --project test/test_uyf9_memcpy_sret.jl
# → expect: Test Failed
```

**Step 2 — GREEN (minimal):** implement `_needs_sret_canonicalisation` and the `auto_preprocess_sret` kwarg + gating logic in `extract_parsed_ir`. Skip `_from_ll` / `_from_bc` for now. Run the new test file. Expect: primary repro passes, opt-out test passes.

**Step 3 — GREEN (siblings):** add `auto_preprocess_sret` kwarg to `extract_parsed_ir_from_ll` (`src/ir_extract.jl:111`) and `extract_parsed_ir_from_bc` (`src/ir_extract.jl:164`). The gate here is `auto_preprocess_sret && !preprocess` (no `optimize` kwarg on these paths).

**Step 4 — UPDATE test_sret.jl:125-136:** apply the §5.1 replacement. Verify the test still captures the error path when `auto_preprocess_sret=false`.

**Step 5 — Regression sweep:** run the full suite per §7 execution plan. Investigate any gate-count delta.

**Step 6 — WORKLOG update:** per CLAUDE.md §0, capture the learning: "auto-SROA on sret-detected `optimize=false` extraction eliminates the memcpy-rejection path. Gate: `_needs_sret_canonicalisation`. Minimal pass list: sroa+mem2reg only. Regression-clean on full suite."

**Step 7 — commit:** per CLAUDE.md session completion, push to remote; run `bd update uyf9 --close`.

### 9.1 Refactor points (after GREEN)

- Extract the auto-SROA gate into a helper if it ever needs to be reused outside `extract_parsed_ir`. For now, inline is fine — it's three lines.
- If `use_memory_ssa` + `optimize=false` + sret becomes a real use case, wire `_run_memssa_on_ir` to see the same passes (Risk C).

---

## 10. Code sketch — exact diffs

Minimum complete diff for the three entry points:

### 10.1 `src/ir_extract.jl` — new constant near line 23

```julia
# γ (Bennett-uyf9): minimal pass list auto-injected when _detect_sret fires
# under optimize=false. SROA is the core canonicaliser (decomposes
# alloca+memcpy into per-slot stores); mem2reg promotes any single-value
# allocas SROA leaves behind. We intentionally exclude simplifycfg and
# instcombine here to minimise IR-shape drift outside the sret canonicalisation.
const SRET_MEMCPY_FALLBACK_PASSES = ["sroa", "mem2reg"]
```

### 10.2 `src/ir_extract.jl` — new helper (placed alongside `_detect_sret`)

```julia
"""
    _needs_sret_canonicalisation(ir_string::AbstractString) -> Bool

γ (Bennett-uyf9): detect whether the entry function in `ir_string` takes an
sret parameter, to decide whether to auto-inject SROA+mem2reg under the
optimize=false path. Uses a throw-away parse of the module, so the cost is
one extra `parse(LLVM.Module, ...)` call per extraction — typically well
under a millisecond.

Returns `false` if the module has no entry function (no `julia_*` with a
body) or if the entry function has no sret parameter. Silent on errors
inside `_detect_sret`; if `_detect_sret` raises, we fall through to the
existing rejection path at R (ir_extract.jl:451-461) which preserves the
helpful error message.
"""
function _needs_sret_canonicalisation(ir_string::AbstractString)::Bool
    result = false
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        try
            entry = try
                _find_entry_function(mod, nothing)
            catch
                nothing
            end
            entry !== nothing && (result = _detect_sret(entry) !== nothing)
        finally
            dispose(mod)
        end
    end
    return result
end
```

### 10.3 `src/ir_extract.jl` — `extract_parsed_ir` (lines 41-81 of the current file)

Change signature + add the gate:

```julia
function extract_parsed_ir(f, arg_types::Type{<:Tuple};
                           optimize::Bool=true,
                           preprocess::Bool=false,
                           passes::Union{Nothing,Vector{String}}=nothing,
                           use_memory_ssa::Bool=false,
                           auto_preprocess_sret::Bool=true)
    ir_string = sprint(io -> code_llvm(io, f, arg_types;
                                       debuginfo=:none, optimize, dump_module=true))

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

    # γ (Bennett-uyf9): under optimize=false, Julia emits aggregate sret
    # returns via alloca + llvm.memcpy. _collect_sret_writes cannot handle
    # that form (it requires per-slot scalar stores). Auto-inject a minimal
    # SROA+mem2reg pass list when sret is detected on the entry function.
    # Gated on `!preprocess` (so explicit preprocess=true supersedes this)
    # and `!optimize` (under optimize=true Julia has already run SROA).
    if auto_preprocess_sret && !preprocess && !optimize &&
       _needs_sret_canonicalisation(ir_string)
        prepend!(effective_passes, SRET_MEMCPY_FALLBACK_PASSES)
    end

    # ... rest unchanged (memssa, LLVM.Context ..., _module_to_parsed_ir, ...)
end
```

### 10.4 `src/ir_extract.jl` — `extract_parsed_ir_from_ll` (lines 111-150)

Add same kwarg + gate. Since there is no `optimize` kwarg on this path (input is already `.ll`), the gate is `auto_preprocess_sret && !preprocess`:

```julia
function extract_parsed_ir_from_ll(path::AbstractString;
                                    entry_function::AbstractString,
                                    preprocess::Bool=false,
                                    passes::Union{Nothing,Vector{String}}=nothing,
                                    use_memory_ssa::Bool=false,
                                    auto_preprocess_sret::Bool=true)
    isfile(path) || error(...)
    ir_string = read(path, String)

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

    # γ (Bennett-uyf9): mirror extract_parsed_ir's auto-SROA gate.
    if auto_preprocess_sret && !preprocess &&
       _needs_sret_canonicalisation(ir_string)
        prepend!(effective_passes, SRET_MEMCPY_FALLBACK_PASSES)
    end

    # ... rest unchanged.
end
```

### 10.5 `src/ir_extract.jl` — `extract_parsed_ir_from_bc` (lines 164-191)

The bc path reads bitcode directly into an `LLVMMemoryBufferFile`; there is no `ir_string` intermediate. We have two options:

- **(a)** `LLVM.strmat(mod)` or equivalent to get a text representation, pass to `_needs_sret_canonicalisation`.
- **(b)** Refactor `_needs_sret_canonicalisation` to accept an already-parsed `LLVM.Module` and call it from inside the `LLVM.Context`.

Option (b) is cleaner. Sketch:

```julia
function _needs_sret_canonicalisation_mod(mod::LLVM.Module)::Bool
    entry = try
        _find_entry_function(mod, nothing)
    catch
        return false
    end
    return entry !== nothing && _detect_sret(entry) !== nothing
end
```

Then the bc path:

```julia
function extract_parsed_ir_from_bc(path::AbstractString;
                                    entry_function::AbstractString,
                                    preprocess::Bool=false,
                                    passes::Union{Nothing,Vector{String}}=nothing,
                                    auto_preprocess_sret::Bool=true)
    # ... existing setup ...

    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

    local result::ParsedIR
    LLVM.Context() do _ctx
        @dispose membuf = LLVM.MemoryBufferFile(String(path)) begin
            mod = parse(LLVM.Module, membuf)
            try
                # γ (Bennett-uyf9): in-context sret detection for the bc path.
                if auto_preprocess_sret && !preprocess &&
                   _needs_sret_canonicalisation_mod(mod)
                    prepend!(effective_passes, SRET_MEMCPY_FALLBACK_PASSES)
                end
                # Note: _extract_from_module runs the (now augmented) passes.
                result = _extract_from_module(mod, entry_function, effective_passes)
            finally
                dispose(mod)
            end
        end
    end
    return result
end
```

`_needs_sret_canonicalisation` (the text-based variant) can either be kept as a thin wrapper or consolidated. I suggest keeping both — the text path is cheaper when we already have `ir_string` in hand.

### 10.6 Total LOC delta

- 1 new const (`SRET_MEMCPY_FALLBACK_PASSES`): 6 lines with comment.
- 2 new helpers (`_needs_sret_canonicalisation`, `_needs_sret_canonicalisation_mod`): ~25 lines including docstring.
- 3 kwargs added to public functions + 3 gate blocks (~4 lines each): ~12 lines.
- 1 test file (new): ~170 lines.
- 1 test update (`test_sret.jl:125-136`): 1 kwarg add, 1 comment block (~5 lines changed).
- `runtests.jl`: 2 lines.

**Total:** ~220 LOC changed/added, of which ~170 is test. Core code change is ~50 LOC.

---

## 11. Open questions for consensus

1. **Kwarg name.** Is `auto_preprocess_sret` clear? Alternatives: `auto_canonicalise_sret`, `sret_preprocess_fallback`. I prefer `auto_preprocess_sret` — it mirrors the existing `preprocess` kwarg and is Google-able.

2. **Default.** Should `auto_preprocess_sret` default to `true` or `false`? I argue `true` (§4.1) — today's error message already tells users to set `preprocess=true`, so we're just automating the remediation. `false` would preserve strict CLAUDE.md §5 behaviour but re-introduces the foot-gun. The opt-out (§4.5) covers CLAUDE.md §5 users.

3. **Pass list granularity.** `["sroa", "mem2reg"]` vs `["sroa"]` vs full `DEFAULT_PREPROCESSING_PASSES`. I argue the middle: `["sroa", "mem2reg"]`. Research (`p6_research_local.md:1132-1133`) shows `["sroa"]` alone works, but `mem2reg` is cheap insurance and hard-to-imagine-regresses.

4. **MemSSA interaction (Risk C).** Should γ also thread the auto-passes into `_run_memssa_on_ir`? I defer to consensus. My reading: no current test exercises this combination, so we can leave it and file a follow-up bead.

5. **Should `extract_parsed_ir_from_ll` / `_from_bc` also have `auto_preprocess_sret`?** I argue yes (§10.4, §10.5) — consistency with the main `extract_parsed_ir`. It's a no-op on existing tests.

6. **Docstring.** Update `extract_parsed_ir`'s docstring to document the new kwarg. Exact text:

   ```
   - `auto_preprocess_sret=true` (γ, Bennett-uyf9): when sret is detected on
     the entry function and `optimize=false`, auto-inject SROA+mem2reg to
     canonicalise Julia's memcpy-form aggregate return into per-slot stores.
     Set to `false` to preserve raw `optimize=false` IR for debugging (and
     get the "memcpy form not supported" error as before).
   ```

7. **Should we add a test for `optimize=false, auto_preprocess_sret=true` on `.ll` input?** My sketch omits this. Consensus could add it if deemed valuable; the `_from_ll` path shares the gate with `_needs_sret_canonicalisation`, so the logic is exercised.

---

## 12. Summary

- **Pick C1.** ~15 LOC core change vs ~120+ LOC port.
- **Gate:** `auto_preprocess_sret && !preprocess && !optimize && _needs_sret_canonicalisation(ir_string)`.
- **Passes:** `["sroa", "mem2reg"]`, prepended to `effective_passes`.
- **Opt-out:** `auto_preprocess_sret=false` kwarg — preserves today's error message.
- **Test file:** `test/test_uyf9_memcpy_sret.jl` covers primary repro (NTuple{9,UInt64}), opt-in/opt-out, non-sret regression, interaction with `preprocess=true` and `optimize=true`.
- **Test update:** `test/test_sret.jl:125-136` gets `auto_preprocess_sret=false` added to its call site; all three `@test occursin` assertions preserved verbatim.
- **Risk posture:** mitigated by (a) minimal pass list, (b) sret-presence gate, (c) opt-out kwarg, (d) explicit non-sret regression test.
- **Unblocks:** Bennett-z2dj (T5-P6 landing) per `docs/design/p6_consensus.md`.

Ship γ. The T5-P6 triad closes.

---

## Appendix A — source citations (ground truth at file:line)

- `src/ir_extract.jl:23` — `DEFAULT_PREPROCESSING_PASSES` definition.
- `src/ir_extract.jl:41-81` — `extract_parsed_ir` entry point.
- `src/ir_extract.jl:111-150` — `extract_parsed_ir_from_ll`.
- `src/ir_extract.jl:164-191` — `extract_parsed_ir_from_bc`.
- `src/ir_extract.jl:195-202` — `_run_passes!` via `NewPMPassBuilder`.
- `src/ir_extract.jl:243-336` — `_ir_error` / `_ir_error_msg` helpers + opcode table.
- `src/ir_extract.jl:370-404` — `_detect_sret` (sret attribute detection, `[N x iM]` constraint).
- `src/ir_extract.jl:430-602` — `_collect_sret_writes` (memcpy rejection at 449-465; vector-lane path 522-554 from β).
- `src/ir_extract.jl:614-644` — `_resolve_pending_vec_for_val!` (β).
- `src/ir_extract.jl:663-686` — `_synthesize_sret_chain` (unchanged by γ).
- `src/ir_extract.jl:694-736` — `_find_entry_function` (reused by `_needs_sret_canonicalisation`).
- `src/ir_extract.jl:749-765` — sret detection + ret_width plumbing.
- `test/test_sret.jl:105-117` — `swap2` gate-count baseline (82 gates — regression guard).
- `test/test_sret.jl:125-136` — **to be updated per §5.1**.
- `test/test_0c8o_vector_sret.jl:26-54` — β's `optimize=true` shape assertions (γ must not break).
- `test/runtests.jl:55, 104, 107` — inclusion order (γ adds after line 107).
- `docs/design/p6_research_local.md:486-521` — memcpy rejection site, live repro, exact error.
- `docs/design/p6_research_local.md:717-768` — `optimize=false` IR shape (Form A) + preprocess=true workaround.
- `docs/design/p6_research_local.md:1108-1133` — pass-combination probe (confirms `opt=false, passes=["sroa","mem2reg"]` works).
- `docs/design/p6_research_local.md:1265-1277` — `optimize`/`preprocess` matrix (γ's target cell: `false, false` → FAIL, becomes OK post-γ).
- `docs/design/p6_research_local.md:1462-1481` — §12.3 option analysis (independent arrival at C1).
- `docs/design/p6_research_online.md:422-424` — external precedent for memcpy canonicalisation.
- `docs/design/p6_research_online.md:486-648` — Enzyme's `memcpy_sret_split!` + `copy_struct_into!` (C2 precedent; considered and rejected).
- `docs/design/p6_research_online.md:1027-1033` — §11.3 Option C (port Enzyme) — rejected in favour of C1.

## Appendix B — what γ does NOT do (scope boundaries)

Per the brief:

- **Does not** touch the vector-store sret path (β handled it).
- **Does not** touch non-sret memcpy handling (orthogonal to sret extraction).
- **Does not** port Enzyme's `FixupJuliaCallingConventionSRetPass` (C++ side, opaque).
- **Does not** change the `_detect_sret` constraint set (still only `[N x iM]` homogeneous).
- **Does not** change the scalar-sret pre-walk at `_collect_sret_writes` lines 508-586 (post-SROA shape matches it as-is).
- **Does not** change the synthetic `IRInsertValue` chain at `_synthesize_sret_chain`.
- **Does not** change anywhere downstream (`lower.jl`, `bennett.jl`, `simulator.jl`).

γ is entirely scoped to `src/ir_extract.jl`'s public entry points + one test file + one test update.
