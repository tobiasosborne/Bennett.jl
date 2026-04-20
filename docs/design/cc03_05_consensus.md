# cc0.3 + cc0.5 Consensus

**Beads**: Bennett-cc0.3 (LLVMGlobalAliasValueKind) + Bennett-cc0.5 (thread_ptr GEP).
Paired PR because cc0.3 fires first, cc0.5 fires next on same pathways.

**Proposers**: `cc03_05_proposer_A.md` (924 lines), `cc03_05_proposer_B.md` (1,303 lines).

## Convergence

Both independently picked the same shape:

- **cc0.3**: raw-C-API operand reader that detects GlobalAlias refs via
  `LLVMGetValueKind` + `LLVMAliasGetAliasee`, follows aliasee chain with
  cycle detection, falls back to `IROperand(:const, :__opaque_ptr__, 0)`
  sentinel when the target is unresolvable.
- **cc0.5**: pre-walk modelled on the existing `_collect_sret_writes`
  pattern (`ir_extract.jl:221`). Recognises the deterministic Julia TLS
  allocator prologue (`asm %fs:0` → GEP-8 → load → GEP+16 → load →
  `@ijl_gc_small_alloc`), suppresses those instructions, synthesises an
  `IRAlloca(8, payload_bytes)` keyed on the allocator-call's SSA name.

## Choices (proposer diffs)

### Alias chain depth — B's seen-set wins
A: fixed depth 8. B: depth cap with cycle detection. A flagged in their
own uncertainty list that a seen-`Set` is safer. **Adopted: seen-set, depth 16
as belt+suspenders.**

### Sentinel centralisation — A's const module global wins
Both use `IROperand(:const, :__opaque_ptr__, 0)`. A proposes centralising as
`const OPAQUE_PTR_SENTINEL = IROperand(...)` at module scope alongside the
existing `:__zero_agg__` / `:__poison_lane__` conventions. **Adopted.**

### TLS-prologue matching precision — B's explicit-asm-string approach wins
A flagged fragility of hard-coded offsets. B proposes matching on the
inline-asm string (`movq %fs:0, $0`) AND offsets (-8, +16). **Adopted:**
check inline-asm via `LLVMIsAInlineAsm` + confirm result-flows-into-GEP-8
pattern. Fail silently (don't match) on any deviation — the `thread_ptr`
error resurfaces with a clear message for future Julia codegen drift.

### TJ4 success risk — Proposer A's flag is load-bearing
If cc0.5 enables TJ4 to fully compile and `verify_reversibility` passes,
the existing `@test_throws ErrorException` flips RED. **Strategy:** let
the synthetic alloca flow through `_pick_alloca_strategy` normally. If it
dispatches to `:shadow_checkpoint` and produces a working circuit, flip
the test GREEN. If it errors at lowering, keep RED. Measure empirically,
don't pre-guard — pre-guarding would require owning the dispatcher's
logic which is T5-P6's job.

### ConstantExpr GEP policy
Both proposers: route ConstantExpr through `_safe_operand` (the wrapping
fails inside LLVM.jl when LLVM walks sub-operands of the ConstantExpr),
catch the failure, return sentinel. No special handling for nested GEP
structure — we're satisfying extraction, not materialising the global.

### Operand-site scope
Both agree the crash-prone sites are:
- `_convert_instruction` operand iteration (stores, loads, calls, GEPs)
- `_collect_sret_writes` pre-walk operand iteration
- `_extract_const_globals` (already partially guarded)
- `_convert_vector_instruction` operand probe (already guarded by cc0.7)

**Adopted minimum-invasion path:** add `_safe_operands(inst)` that returns
`Vector{Union{LLVM.Value, Nothing}}` with alias resolution. Route call /
store / load / GEP handlers through it. Leave integer arithmetic handlers
untouched — they never take ptr operands in valid IR.

## Implementation contract

### Helpers (new, in `ir_extract.jl`)

```julia
const OPAQUE_PTR_SENTINEL = IROperand(:const, :__opaque_ptr__, 0)

# Follow GlobalAlias chain via raw C API. Returns the terminal non-alias
# ref, or nothing if the chain is cyclic, too deep, or terminates in
# something unwrappable.
function _resolve_aliasee(ref::_LLVMRef)::Union{_LLVMRef, Nothing}
    ref == C_NULL && return nothing
    seen = Set{_LLVMRef}()
    cur = ref
    for _ in 1:16
        cur in seen && return nothing        # cycle
        push!(seen, cur)
        kind = LLVM.API.LLVMGetValueKind(cur)
        kind == LLVM.API.LLVMGlobalAliasValueKind || return cur
        next = LLVM.API.LLVMAliasGetAliasee(cur)
        next == C_NULL && return nothing
        cur = next
    end
    return nothing                           # exceeded depth
end

# Safe operand iteration via raw C API. Returns a Vector{Union{LLVM.Value,
# Nothing}} of length n_operands. Nothing slots represent unresolvable
# GlobalAlias operands (lower.jl consumers must handle or fail loud).
function _safe_operands(inst::LLVM.Instruction)::Vector{Union{LLVM.Value, Nothing}}
    n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
    out = Vector{Union{LLVM.Value, Nothing}}(undef, n)
    for i in 0:(n - 1)
        ref = LLVM.API.LLVMGetOperand(inst.ref, i)
        resolved = _resolve_aliasee(ref)
        out[i + 1] = resolved === nothing ? nothing : try
            LLVM.Value(resolved)
        catch
            nothing
        end
    end
    return out
end

# Sentinel-aware _operand that accepts Nothing.
function _operand_safe(val::Union{LLVM.Value, Nothing}, names)::IROperand
    val === nothing && return OPAQUE_PTR_SENTINEL
    return _operand(val, names)
end
```

### cc0.3 surface

Route these handlers' operand reads through `_safe_operands`:
- `LLVMStore` (val can be GlobalAlias)
- `LLVMLoad` (ptr can be ConstantExpr<GEP<GlobalAlias>>)
- `LLVMGetElementPtr` (base can be GlobalAlias)
- `LLVMCall` (callee slot can be GlobalAlias — already defensive via cc0.7)

Extend `_extract_const_globals` to skip GlobalAlias-kind globals
(they have no initializer).

Extend `_collect_sret_writes` inner loop with try/catch around
`LLVM.operands(inst)` — skip instructions whose operands can't be
materialised (they cannot target sret).

### cc0.5 surface

New pre-walk `_collect_tls_allocs(func, names)`, called from
`_module_to_parsed_ir` after naming pass, before main dispatch. Returns
`(synthetic_allocas::Dict{_LLVMRef, IRAlloca}, suppressed::Set{_LLVMRef})`.

Pattern matcher:
1. Find `%thread_ptr = call ptr asm "movq %fs:0, $0", "=r"()` via
   `LLVMIsAInlineAsm` on the callee.
2. Walk forward: find GEP with base=`thread_ptr` and const offset `-8`.
3. Walk forward: find load from that GEP (`%tls_pgcstack`).
4. Walk forward: find GEP with base=`tls_pgcstack` and const offset `+16`.
5. Walk forward: find load from THAT GEP (`%ptls_load`).
6. Walk forward: find call `@ijl_gc_small_alloc(%ptls_load, i32, i32 size_bytes, i64)`.
7. Suppress all six (+ any in-between unrelated instructions? No — the
   allocator uses them, so they're already in the chain).
8. Emit `IRAlloca(call.ref, 8, iconst(size_bytes))` keyed on the call's
   SSA name.

Multiple allocator calls in one function: pattern-match each independently.
The shared TLS preamble (steps 1-3, and 4-5 for `ptls_field`/`ptls_load`)
can be reused across allocator calls — suppress each only once.

Suppress also the post-alloca housekeeping (`tag_addr`, size_ptr stores)
that the sret pre-walk's GEP-suppression inspired. Audit what the sret
pre-walk does for GC-frame stores and mirror exactly.

### Zero touches to lower.jl unless required

Proposer B proposed one defensive guard in `resolve!`:
```julia
op.kind == :const && op.name === :__opaque_ptr__ &&
    error("lower.jl resolve!: opaque pointer operand reached integer " *
          "wire allocation — see Bennett-cc0.3. ...")
```

**Adopt this guard** — fail-loud per CLAUDE.md §1. Without it, a sentinel
that slipped through would silently coerce to integer 0 (silent miscompile).
Single line.

### Tests

- `test/test_t5_corpus_julia.jl` TJ1/TJ2/TJ3/TJ4: existing `@test_throws`
  stays; may change error message.
- New assertions in same file: extracted error message no longer contains
  `"LLVMGlobalAliasValueKind"` (for TJ1/TJ2) or `"thread_ptr"` (for TJ4).
- Full suite: zero gate-count regressions (functions without
  aliases/TLS-allocator are byte-identical).

### Sequence (RED → GREEN)

1. Implement cc0.3 helpers + route the 4 handler sites.
2. Run TJ1/TJ2 — new error message must NOT mention LLVMGlobalAliasValueKind.
3. Implement cc0.5 pre-walk.
4. Run TJ4 — either compiles (flip `@test_throws` to GREEN test) or errors
   at `_pick_alloca_strategy` or downstream (keep `@test_throws`, assert
   message is informative).
5. Full suite — zero regression on GREEN tests.
6. Measure: any tests that previously hit cc0.3/cc0.5 paths via
   auto-vectorised extraction now flip GREEN (if so, record delta).

### Risk acknowledgments

1. **TJ4 may fully compile.** Acceptable outcome — measure and flip test GREEN.
2. **TLS-prologue recogniser brittleness.** Julia/LLVM refactor silently
   breaks it → the old `thread_ptr` error resurfaces, not a miscompile.
3. **Sentinel not audited in all `lower.jl` `.kind == :const` sites** — one
   defensive guard in `resolve!` is proposed; broader audit deferred unless
   a test catches something.
4. **Negative-offset GEPs** (GC tag slot at offset `-1`) — B flagged. Check
   if currently errors; if yes, suppress as part of TLS pre-walk.
