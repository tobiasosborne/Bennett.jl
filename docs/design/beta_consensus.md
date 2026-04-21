# Bennett-0c8o Consensus — vector-lane sret via deferred resolution + vector-load handler

**Bead**: Bennett-0c8o. Labels: `3plus1,core`.
**Date**: 2026-04-21.
**Inputs**: `docs/design/beta_proposer_A.md` (996 lines), `docs/design/beta_proposer_B.md` (1351 lines).

Both proposers independently found and verified:

1. **Option (c) Scalarizer is empirically non-viable.** LLVM.jl's `NewPMPassBuilder` does not accept `"scalarizer<load-store>"` parameter syntax; plain `"scalarizer"` leaves load/store scalarisation defaulted off — the `<4 x i64>` store survives (confirmed live, both proposers ran this probe).
2. **Option (b) walker reorder is overkill** — touches too much load-bearing state.
3. **Option (a) local-lanes is the right approach.**
4. **The vector store's value cone reaches `load <4 x i64>`.** `_convert_vector_instruction` has no `LLVMLoad` handler today. This means a naive vector-store fix still crashes in pass 2 when the select's false-arm vector load is processed.

## 1. Chosen design — A-structural + A's §12.1 vector-load handler

A's structural design is cleaner: it **separates slot-range reservation (pre-walk) from lane-SSA materialisation (pass 2)**, reusing `_convert_vector_instruction` as the single source of vector→scalar decomposition (CLAUDE.md §12 — no duplicated lowering). B's inline recursive decomposer `_sret_decompose_vec_value` would duplicate that logic.

The vector-load gap A punted to a follow-up bead **must** land inside Bennett-0c8o. Reasons:

1. Without it, the end-to-end `linear_scan_pmap_set` case still fails — the ostensible blocker for T5-P6. Splitting creates an artificial dependency chain.
2. The fix is small (~20 LOC per A §12.1 sketch) and co-located with the rest of the bead.
3. User directive 2026-04-21: "no quick fixes. NO alternatives. We do this PROPERLY."

**Final design**:

- **Pre-walk (`_collect_sret_writes`)**: adds vector-store branch that registers `pending_vec[store.ref] = (first_slot, n_lanes)` + `pending_val_refs[store.ref] = val.ref`; reserves slots with `:__pending_vec_lane__` sentinel; suppresses the store.
- **Pass 2 hook**: after each `_convert_instruction` returns, call `_resolve_pending_vec_for_val!(sret_writes, inst.ref, lanes)`. When the vector value producer is walked, its `lanes[ref]` is copied into `slot_values`.
- **`_assert_no_pending_vec_stores!`** before `_synthesize_sret_chain` fails loud if any sentinel survives.
- **New `_convert_vector_instruction` case for LLVMLoad**: synthesises N scalar `IRPtrOffset` + `IRLoad` pairs at lane byte offsets, populating `lanes[load.ref]`.

Total LOC: ~120 (100 for A's structural part + ~20 for vector-load handler).

## 2. Code — final consensus

### 2.1 New vector-store branch in `_collect_sret_writes`

Insert before `vt isa LLVM.IntegerType` check at `src/ir_extract.jl:517`:

```julia
# Bennett-0c8o: vector-typed SLP store decomposition.
if vt isa LLVM.VectorType
    lane_ty = LLVM.eltype(vt)
    lane_ty isa LLVM.IntegerType || _ir_error(inst,
        "sret vector store at byte offset $byte_off has non-integer " *
        "lane type $lane_ty")
    lw = Int(LLVM.width(lane_ty))
    lw == ew || _ir_error(inst,
        "sret vector store at byte offset $byte_off has lane width " *
        "$lw but aggregate element width is $ew")
    (byte_off % eb == 0) || _ir_error(inst,
        "sret vector store at byte offset $byte_off is not aligned " *
        "to element size $eb")
    n_lanes = Int(LLVM.length(vt))
    first_slot = byte_off ÷ eb
    (0 <= first_slot && first_slot + n_lanes <= n) || _ir_error(inst,
        "sret vector store spans slots [$first_slot, " *
        "$(first_slot + n_lanes - 1)] which exceed aggregate range [0, $n)")
    for lane in 0:(n_lanes - 1)
        slot = first_slot + lane
        haskey(slot_values, slot) && _ir_error(inst,
            "sret slot $slot already written; vector store (lane $lane) " *
            "cannot re-write it")
        slot_values[slot] = IROperand(:const, :__pending_vec_lane__, lane)
    end
    pending_vec[inst.ref] = (first_slot, n_lanes)
    pending_val_refs[inst.ref] = val.ref
    push!(suppressed, inst.ref)
    continue
end
```

Also extend the scalar-store duplicate-slot check at line 532 to give a sharper error when a vector sentinel collides.

### 2.2 Extended `_collect_sret_writes` return NamedTuple

```julia
return (slot_values      = slot_values,
        suppressed       = suppressed,
        pending_vec      = pending_vec,
        pending_val_refs = pending_val_refs)
```

### 2.3 New helpers (place near `_synthesize_sret_chain`)

```julia
function _resolve_pending_vec_for_val!(sret_writes,
                                        produced_ref::_LLVMRef,
                                        lanes::Dict{_LLVMRef, Vector{IROperand}})
    store_ref = nothing
    for (sref, vref) in sret_writes.pending_val_refs
        if vref === produced_ref
            store_ref = sref
            break
        end
    end
    store_ref === nothing && return nothing

    first_slot, n_lanes = sret_writes.pending_vec[store_ref]
    haskey(lanes, produced_ref) || error(
        "ir_extract.jl: pending sret vector store's stored value " *
        "$(produced_ref) was not registered in the vector-lane table " *
        "during pass 2.")
    per_lane = lanes[produced_ref]
    length(per_lane) == n_lanes || error(
        "ir_extract.jl: pending sret vector store expected $n_lanes lanes " *
        "but got $(length(per_lane)) from the vector-lane table")
    for lane in 0:(n_lanes - 1)
        sret_writes.slot_values[first_slot + lane] = per_lane[lane + 1]
    end
    delete!(sret_writes.pending_vec, store_ref)
    delete!(sret_writes.pending_val_refs, store_ref)
    return nothing
end

function _assert_no_pending_vec_stores!(sret_writes)
    isempty(sret_writes.pending_vec) && return nothing
    refs = collect(keys(sret_writes.pending_vec))
    error("ir_extract.jl: $(length(refs)) pending sret vector store(s) " *
          "remain unresolved at ret void. This means the producer " *
          "of the stored vector value wasn't processed in pass 2. " *
          "Likely cause: the vector-producer instruction was skipped " *
          "by _convert_instruction's catch-block.")
end
```

### 2.4 Pass-2 integration hooks

At the pass-2 loop (around `ir_extract.jl:721-775`), after `_convert_instruction` returns successfully (after `ir_inst === nothing && continue`, before `ir_inst isa Vector` dispatch):

```julia
if sret_writes !== nothing
    _resolve_pending_vec_for_val!(sret_writes, inst.ref, lanes)
end
```

Before `_synthesize_sret_chain`:

```julia
_assert_no_pending_vec_stores!(sret_writes)
```

### 2.5 New LLVMLoad handler in `_convert_vector_instruction`

Per A §12.1 sketch, add to `_convert_vector_instruction` (currently at `ir_extract.jl:1909-2121`):

```julia
if opc == LLVM.API.LLVMLoad
    ops = LLVM.operands(inst)
    shape = _vector_shape(inst)
    shape === nothing && _ir_error(inst,
        "vector load return type is not a vector")
    n, w = shape
    ptr = ops[1]
    eb = w ÷ 8
    insts = IRInst[]
    out = Vector{IROperand}(undef, n)
    for i in 1:n
        gep_dest = _auto_name(counter)
        load_dest = _auto_name(counter)
        push!(insts, IRPtrOffset(gep_dest, _operand(ptr, names), (i - 1) * eb))
        push!(insts, IRLoad(load_dest, ssa(gep_dest), w))
        out[i] = ssa(load_dest)
    end
    lanes[inst.ref] = out
    return insts
end
```

Uses only `IRPtrOffset` + `IRLoad`, both handled by `lower.jl` already.

### 2.6 `counter` threading

`_convert_vector_instruction` already takes `counter::Ref{Int}` for `_auto_name`. The new LLVMLoad handler uses it. No new plumbing required.

## 3. RED test — `test/test_0c8o_vector_sret.jl`

Adopt A §7.2 test structure with these refinements:

1. Primary repro: `extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8})` under `optimize=true` succeeds, `ret_elem_widths == [64]×9`, 9 IRInsertValues, no sentinel in any.
2. End-to-end linear_scan_pmap_set: `reversible_compile` succeeds AND `verify_reversibility` passes AND simulated output matches Julia reference for a small sweep. **Not** `@test_broken` — since we're fixing the vector-load handler in this bead.
3. Synthetic splat (Julia-source n=8 UInt64 with SLP-friendly pattern).
4. Regression: n=2 swap2 = 82 gates, all `test_sret.jl` cases, heterogeneous rejection, memcpy rejection.
5. n=9 UInt64 SLP variants (Julia-source).

## 4. Regression plan

Adopt A §8 plus the end-to-end linear_scan check.

Byte-identical guarantees:
- Scalar sret stores route through the unchanged integer-store branch.
- Non-sret functions never enter `_collect_sret_writes`.
- `_convert_vector_instruction`'s new LLVMLoad case activates only when opcode is LLVMLoad AND the return type is a vector. Non-vector loads are handled by `_convert_instruction`'s existing scalar-load case, unchanged.

Spot-check matrix:
| Test | Invariant |
|------|-----------|
| `test_sret.jl:105-117` swap2 | gate_count == 82 |
| `test_sret.jl` n=3..n=8 UInt32 | byte-identical |
| `test_tuple.jl`, `test_extractvalue.jl`, `test_ntuple_input.jl` | byte-identical |
| `test_cc07_repro.jl` | byte-identical (existing vector corpus) |
| i8/i16/i32/i64 x+1 = 100/204/412/828 | byte-identical |
| `_ls_demo` = 436/90T | byte-identical |
| CF demo = 11078, CF+Feistel = 65198, HAMT = 96788 | byte-identical |

## 5. Implementation sequence

1. **RED** — write `test/test_0c8o_vector_sret.jl`, add to `runtests.jl`. Run — primary repro fails on `<4 x i64>` rejection (current behaviour).
2. **Helpers first** — add `_resolve_pending_vec_for_val!` + `_assert_no_pending_vec_stores!` to `ir_extract.jl`. Run — test still RED (helpers not yet called).
3. **Pre-walk branch** — add vector-store branch in `_collect_sret_writes`, extend return NamedTuple with `pending_vec` + `pending_val_refs`. Run — primary repro now hits pass-2 vector-load gap.
4. **Pass-2 hook** — insert `_resolve_pending_vec_for_val!` + `_assert_no_pending_vec_stores!` calls in pass-2 loop. Run — primary repro fails with "cannot resolve vector lanes" on the vector load.
5. **LLVMLoad handler** — add the LLVMLoad case to `_convert_vector_instruction`. Run — primary repro GREEN.
6. **Full `Pkg.test()`** — verify all baselines byte-identical.
7. **Commit + close** Bennett-0c8o.

## 6. Risks

1. **Vector-load in non-sret paths.** The new LLVMLoad handler activates for any vector load processed by `_convert_vector_instruction`. Today, `test_cc07_repro.jl` exercises the vector-instruction corpus. Risk: the new handler fires on a test that previously crashed with "unsupported opcode" (possibly a GREEN outcome, possibly a new regression). Mitigation: step 5's full regression catches it.
2. **Vector-load addr not an alloca or tuple ptr.** Julia's `%"state::Tuple[2]_ptr"` is the GEP of a function argument. `lower.jl`'s IRLoad handler expects ptr_provenance for this. The existing `from_ll/from_bc` paths for NTuple args already set `ptr_params` at `ir_extract.jl:685-691`; the lowering-time provenance chain should already work. If not, a follow-up bead addresses.
3. **Ordering**: pass-2 populates `lanes` in source order (A §5.5). SSA dominance guarantees producers precede users. No ordering risk.
4. **`_convert_instruction` catch block** doesn't wrap vector calls; any failure leaves pending entries orphaned, caught by `_assert_no_pending_vec_stores!`.
5. **False-path sensitization**: not applicable — sret slots are write-once by construction (A §9.1).
6. **LLVM version drift** (CLAUDE.md §5): new vector producers would fail loud at `_resolve_vec_lanes`. No silent miscompile.

## 7. Deliberate uncertainties

- The end-to-end linear_scan `reversible_compile` may reveal further gaps (e.g. vector `icmp <4 x i64>` comparing with a `<i64 0,1,2,3>` constant vector — need to verify `_convert_vector_instruction` handles this; §6.1 of A says ConstantDataVector is already handled). If a new gap surfaces during implementation, add a handler per A §12.1's pattern.
- `_convert_vector_instruction`'s `counter::Ref{Int}` must be threaded through the new LLVMLoad case. Confirm by inspection it's already in scope.

---

End of consensus. Implementer proceeds with §5 step-by-step.
