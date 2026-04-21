# Bennett-uyf9 Consensus — auto-SROA when sret is detected

**Bead**: Bennett-uyf9. Labels: `3plus1,core`.
**Date**: 2026-04-21.
**Inputs**: `docs/design/gamma_proposer_A.md` (~700 lines), `docs/design/gamma_proposer_B.md` (978 lines).

Both proposers independently chose **Option C1 (auto-SROA)** over C2 (Enzyme
memcpy_sret_split port). C1 is ~15 LOC of infrastructure; C2 is ~120 LOC
porting logic that a single stock LLVM pass already handles correctly.

## 1. Chosen design — A-minimal

| Question | Choice | Rationale |
|---|---|---|
| C1 or C2? | **C1 (auto-SROA)** | Both proposers agree. Smaller surface, reuses battle-tested SROA, no need to replicate Enzyme's recursive type-walk machinery. Existing memcpy error path stays as defensive fallback. |
| Pass list | `["sroa", "mem2reg"]` | Minimal pair that canonicalises memcpy-of-alloca into per-slot scalar stores (verified empirically per `p6_research_local.md` §4.3). Don't pull in full `DEFAULT_PREPROCESSING_PASSES` (simplifycfg, instcombine) — narrower blast radius. |
| New opt-out kwarg? | **No** (A's approach, not B's) | B suggested `auto_preprocess_sret::Bool=true`. Rejected: the auto-behaviour is always correct (SROA on a post-codegen function with sret is a no-op if no alloca-memcpy pattern is present). Adding a kwarg for a case we can't construct violates YAGNI. If a user wants the old memcpy-rejection behaviour, they can still use `preprocess=false` AND avoid sret functions — the user's existing contract. |
| Gate | `_detect_sret` returns non-nothing AND `"sroa"` not already in `effective_passes` | A's gate. Avoids double-running SROA when the user already passed `preprocess=true`. |
| Keep existing memcpy-rejection error? | Yes, as defensive fallback | If SROA doesn't eliminate the memcpy for some pathological shape, the existing `_ir_error` at `ir_extract.jl:451-461` fires with its current helpful message. |
| `test_sret.jl:125-136` | **Update** to assert successful extraction post-fix | The test previously pinned the "memcpy rejected" contract; that contract is now relaxed. |

### Why C1 wins (full reasoning from both proposers)

- A/B both note: `optimize=false, preprocess=true` already works empirically (`p6_research_local.md` §4.3). We're automating the workaround, not inventing new machinery.
- B flags: porting Enzyme's `copy_struct_into!` would require stripping the `any_jltypes` gate (which short-circuits on pure primitives) and replicating ~70 LOC of recursive type-walk. That increases maintenance surface, not decreases it.
- A flags: SROA is a known-safe canonicaliser. Running it on a function that has no alloca-memcpy pattern is a no-op.

## 2. Code — final consensus

### 2.1 New predicate `_module_has_sret`

Place near `_detect_sret` in `src/ir_extract.jl` (around line 370):

```julia
"""
    _module_has_sret(mod::LLVM.Module) -> Bool

Bennett-uyf9: true iff any function in `mod` has an `sret` parameter. Used to
auto-enable SROA + mem2reg in the pass pipeline under `optimize=false` — Julia's
no-optimisation codegen emits aggregate returns via `alloca [N x iM]` + memcpy
into the sret buffer, which SROA decomposes into per-slot scalar stores that
`_collect_sret_writes` handles natively.
"""
function _module_has_sret(mod::LLVM.Module)::Bool
    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
    for func in LLVM.functions(mod)
        # Declarations have no body; skip.
        length(LLVM.blocks(func)) == 0 && continue
        for (i, _) in enumerate(LLVM.parameters(func))
            attr = LLVM.API.LLVMGetEnumAttributeAtIndex(
                func, UInt32(i), kind_sret)
            attr == C_NULL || return true
        end
    end
    return false
end
```

### 2.2 Auto-prepend in `extract_parsed_ir`

At `src/ir_extract.jl:41-81`, inside the `LLVM.Context() do _ctx` block, after
parsing the module and before running passes, add the sret check:

```julia
LLVM.Context() do _ctx
    mod = parse(LLVM.Module, ir_string)

    # Bennett-uyf9: auto-canonicalise memcpy-form sret into per-slot scalar
    # stores via SROA when the module contains sret-returning functions and
    # the caller hasn't already opted into preprocessing. Handles the
    # optimize=false path that Julia's specfunc emits as
    # `alloca + memcpy → sret`. Byte-identical for non-sret functions.
    if !("sroa" in effective_passes) && _module_has_sret(mod)
        prepend!(effective_passes, ["sroa", "mem2reg"])
    end

    if !isempty(effective_passes)
        _run_passes!(mod, effective_passes)
    end
    result = _module_to_parsed_ir(mod)
    dispose(mod)
end
```

Parallel changes in `extract_parsed_ir_from_ll` and `extract_parsed_ir_from_bc`
(the same pattern applies — they funnel through `_extract_from_module`).

## 3. RED test — `test/test_uyf9_memcpy_sret.jl`

Adapted from both proposers. Four testsets:

1. **Primary repro under `optimize=false`**: `extract_parsed_ir(g, ...; optimize=false)` where g returns NTuple{9,UInt64} — succeeds, `ret_elem_widths == [64]×9`.
2. **Primary repro with explicit preprocess=false**: same function, with `preprocess=false` explicitly — the auto-SROA still kicks in because of the sret check.
3. **Non-sret regression**: non-sret function under `optimize=false` still extracts without auto-SROA (no IR shape change).
4. **Explicit preprocess=true**: works unchanged (SROA not double-prepended).

## 4. `test_sret.jl:125-136` update

The existing test asserts the memcpy error. After γ, the error no longer fires
under the default path. Update: flip to assert successful extraction + add a
note that γ closed the memcpy-error contract.

Old:
```julia
@testset "memcpy-form sret is rejected with helpful message" begin
    f3(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
    ex = try
        extract_parsed_ir(f3, Tuple{UInt32, UInt32, UInt32}; optimize=false)
        nothing
    catch e; e; end
    @test ex isa ErrorException
    @test occursin("memcpy", ex.msg)
    @test occursin("optimize=true", ex.msg)
    @test occursin("preprocess=true", ex.msg)
end
```

New:
```julia
@testset "memcpy-form sret auto-canonicalised (Bennett-uyf9)" begin
    # Prior behaviour: errored with "sret with llvm.memcpy form is not
    # supported". Bennett-uyf9 added auto-SROA when sret is detected, so
    # optimize=false now extracts successfully.
    f3(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
    pir = extract_parsed_ir(f3, Tuple{UInt32, UInt32, UInt32}; optimize=false)
    @test pir.ret_width == 96
    @test pir.ret_elem_widths == [32, 32, 32]
end
```

## 5. Regression plan

| Test | Expected invariant |
|------|-------------------|
| `test_sret.jl:105-117` swap2 | gate_count == 82 (unchanged — swap2 is n=2 by-value, no sret) |
| `test_sret.jl` n=3..n=8 UInt32 under default optimize=true | byte-identical (SROA not re-run if already in pipeline) |
| `test_sret.jl:125-136` | **Updated** — expects successful extraction |
| test_atf4 (α) | byte-identical |
| test_0c8o (β) | byte-identical (β's vector-store path is orthogonal) |
| i8/i16/i32/i64 x+1 = 100/204/412/828 | byte-identical (non-sret) |
| `_ls_demo` = 436/90T | byte-identical (fully inlined, no sret) |
| HAMT / CF / CF+Feistel / TJ3 | byte-identical |

## 6. Risks

1. **IR-shape drift under auto-SROA** (both proposers flagged). Mitigation: the
   auto-prepend is gated on (a) sret present (b) SROA not already in list. Under
   `optimize=true`, sret functions already went through Julia's own SROA
   pipeline, so a second SROA is a near-no-op. The existing `test_sret.jl` n=2
   through n=8 baselines under default `optimize=true` are unaffected (SROA
   would have run before the walker either way).

2. **Module-wide SROA on external .ll ingest**: A flagged that `.ll`/`.bc`
   modules may contain many functions; running SROA module-wide affects all
   of them. Mitigation: `extract_parsed_ir_from_ll` / `_from_bc` pick a single
   entry function via `_find_entry_function`, but the module-wide pass still
   mutates unused functions. Low risk — SROA is semantics-preserving.

3. **CLAUDE.md §5 ("use `optimize=false` for predictable IR")**: auto-SROA under
   `optimize=false` changes IR shape. Mitigation: this only happens for sret
   functions, which the user already cannot extract without some canonicalisation
   (the previous error message explicitly told them to use `preprocess=true`).
   The new behaviour does exactly what the error message recommended, just
   automatically.

4. **Interaction with β (vector-store sret)**: orthogonal. β's vector-store
   pre-walk runs after pass-execution. SROA under γ may produce different
   scalar/vector patterns; the β path handles both. Tested in regression.

5. **Interaction with `use_memory_ssa=true`**: A flagged that MemSSA is built
   before our new SROA runs. The MemSSA analysis reflects pre-SROA memory state
   but the walker runs post-SROA. Low priority: no current test uses
   `use_memory_ssa=true` with sret functions. Flag as follow-up.

## 7. Implementation sequence

1. **RED**: write `test/test_uyf9_memcpy_sret.jl` + `test/runtests.jl` include.
   Run: primary repro fails with memcpy error (current behaviour).
2. **Helper**: add `_module_has_sret(mod)` to `src/ir_extract.jl` near
   `_detect_sret`.
3. **Auto-prepend**: add the sret-gated `prepend!(effective_passes, ...)` call
   to `extract_parsed_ir` + `extract_parsed_ir_from_ll` + `extract_parsed_ir_from_bc`.
4. **Update `test_sret.jl:125-136`**: flip to successful-extraction assertion.
5. **Run `test_uyf9_memcpy_sret.jl`** — expect GREEN.
6. **Run full `Pkg.test()`** — expect GREEN. Spot-check baselines.
7. **Commit + close** Bennett-uyf9.

## 8. Scope boundaries

- **IN**: memcpy-to-sret decomposition via auto-SROA under `optimize=false`,
  `test_sret.jl:125-136` update.
- **OUT**: `FixupJuliaCallingConventionSRetPass` port (Enzyme C++ side); non-sret
  memcpy handling; MemSSA interaction with auto-SROA (follow-up if needed).

---

End of consensus. Implementer proceeds with §7.
