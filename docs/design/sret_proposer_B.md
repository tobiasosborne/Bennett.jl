# Design: `sret` Aggregate-Return Support (Bennett-dv1z)

**Author**: Proposer B (independent, read-only — does not mutate source files)
**Scope**: `src/ir_extract.jl` only. No changes to `lower.jl`, `bennett.jl`, `gates.jl`, `ir_types.jl`, or tests of existing behavior.
**Goal**: Enable compilation of Julia functions returning tuples of 3+ `UInt32` (or any aggregate > 16 bytes) so that BC.3 (full SHA-256) can compile. Must not regress any existing test.

## 0. Design in one sentence

**At extraction time, detect the `sret` parameter attribute, record its aggregate type and byte-offset layout in a small extractor-local table, exclude the `sret` parameter from `parsed.args`, redirect every `store` whose pointer chain lands on the `sret` buffer into a synthetic per-element value slot, and on `ret void` emit a synthetic `insertvalue` chain plus a single `IRRet` that references the synthesised aggregate SSA name exactly like the existing n=2 path.** Everything downstream of `ir_extract.jl` — `lower.jl`, `bennett.jl`, `simulator.jl`, the gate-count regression baseline — is untouched.

This keeps the fix "skin-deep": the normal (non-`sret`) path is untouched, so the gate-count regression table (`i8`=86, `i16`=174, `i32`=350, `i64`=702, `swap_pair`, `complex_mul_real`, `dot_product`) is preserved bit-for-bit; and the downstream pipeline continues to see a perfectly normal `insertvalue`-built aggregate terminated by `IRRet`.

---

## 1. Detection

### 1.1 Where to detect

Inside `_module_to_parsed_ir` (`src/ir_extract.jl`, line 135 onward), **immediately before the existing parameter-naming loop at line 169**. Two queries are needed:

1. The sret parameter and its aggregate type (if any).
2. The sret aggregate's element layout (widths and byte offsets).

Rationale: we need the sret info available both during parameter naming (to *skip* the sret arg) and during instruction conversion (to redirect stores). Computing it up-front and threading it through the per-instruction conversion is cleaner than two passes.

### 1.2 How to detect — the C API walk

Per the brief, `LLVM.parameter_attributes(f, i)` errors with `MethodError` in this LLVM.jl version. Use the C API directly:

```
kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)        # -> Cuint(78) on current LLVM
attr_ref  = LLVM.API.LLVMGetEnumAttributeAtIndex(func, param_idx, kind_sret)
if attr_ref != C_NULL
    ty_ref = LLVM.API.LLVMGetTypeAttributeValue(attr_ref)
    agg_ty = LLVM.LLVMType(ty_ref)              # ArrayType or StructType
end
```

This API is already used in spirit in `_extract_const_globals` (lines 242–274) via `LLVM.API.LLVMGetElementAsConstant` / `LLVMConstIntGetZExtValue`, so it's a pattern the codebase already has.

The sret is **always** the first parameter on x86_64 SysV ABI (confirmed in every LLVM snapshot given in the brief). We still scan every parameter index because:

- Robustness against future ABI variants (e.g. sret-after-context on some targets).
- Future-proofing for Julia's `swifterror` / `swiftself` slots if they end up in front.

Pseudocode in context:

```
# ---- sret detection (NEW, inserted before line 169) ----
kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
sret_info = nothing                  # Nothing or (sym::Symbol, agg_ty, slot_widths::Vector{Int},
                                     #             slot_offsets::Vector{Int}, slot_count::Int,
                                     #             total_bytes::Int)
sret_param_ref = nothing             # LLVMValueRef of the sret parameter

for (i, p) in enumerate(LLVM.parameters(func))
    attr = LLVM.API.LLVMGetEnumAttributeAtIndex(func, i, kind_sret)
    if attr != C_NULL
        # Only one sret parameter is allowed by LangRef; assert loudly.
        sret_info === nothing ||
            error("Multiple sret parameters — LangRef forbids this")
        ty = LLVM.LLVMType(LLVM.API.LLVMGetTypeAttributeValue(attr))
        sret_param_ref = p.ref
        sret_info = _build_sret_layout(mod, ty, p)   # see §2
    end
end
```

### 1.3 No-sret path — must not regress

If `sret_info === nothing` after the scan, the rest of the function executes **exactly as today**: `rt = LLVM.return_type(ft)` is a scalar integer, float, or ArrayType, and the existing branches handle it. This is the key no-regression invariant: no existing code path is altered when there is no sret attribute.

Concrete assertion (to be baked into the new code): after the sret scan, either `sret_info !== nothing` **or** `!(rt isa LLVM.VoidType)` — if both fail, the compiler would have already crashed at line 1074 ("Unsupported LLVM type for width: LLVM.VoidType"), which is exactly the status-quo failure.

---

## 2. Deriving `ret_elem_widths` and `ret_width`

Today (`src/ir_extract.jl:152–160`):

```
ft = LLVM.function_type(func)
rt = LLVM.return_type(ft)
ret_width = _type_width(rt)
ret_elem_widths = if rt isa LLVM.ArrayType
    [LLVM.width(LLVM.eltype(rt)) for _ in 1:LLVM.length(rt)]
else
    [ret_width]
end
```

When `sret_info` is set, `rt` is `VoidType` and `_type_width` crashes. The fix is conditional:

```
if sret_info !== nothing
    ret_width       = sret_info.total_bits
    ret_elem_widths = sret_info.slot_widths     # each element's bit width, in field order
else
    # ---- existing code, unchanged ----
    ret_width = _type_width(rt)
    ret_elem_widths = if rt isa LLVM.ArrayType
        [LLVM.width(LLVM.eltype(rt)) for _ in 1:LLVM.length(rt)]
    else
        [ret_width]
    end
end
```

### 2.1 `_build_sret_layout` — the offset table

This is a small helper, new to `ir_extract.jl`, that builds the layout we'll thread through instruction conversion. It handles both `ArrayType` and `StructType` (heterogeneous tuples, which Julia emits for mixed-width `Tuple{UInt32, UInt64, UInt32}`).

For `ArrayType`:

```
elem_ty     = LLVM.eltype(agg_ty)
elem_ty isa LLVM.IntegerType ||
    error("sret aggregate element type $elem_ty is not an integer; unsupported")
n           = LLVM.length(agg_ty)                 # e.g. 3 for [3 x i32]
w           = LLVM.width(elem_ty)                 # e.g. 32
elem_bytes  = w ÷ 8                               # element size in bytes
slot_widths = fill(w, n)
slot_offsets = [i * elem_bytes for i in 0:(n-1)]  # bytes from sret base
total_bits  = w * n
```

For `StructType` (Julia heterogeneous tuples with padding):

```
elems       = collect(LLVM.elements(agg_ty))
n           = length(elems)
dl          = LLVM.datalayout(mod)                # this is LLVM.jl's DataLayout(mod)
slot_widths = [LLVM.width(e) for e in elems]
slot_offsets = [Int(LLVM.offsetof(dl, agg_ty, i-1)) for i in 1:n]
total_bits  = sum(slot_widths)                    # ← sum of field widths, NOT storage_size
```

For sanity, every slot must be an integer type in MVP (see §6 "Error boundaries"). `LLVM.offsetof(dl, agg_ty, i-1)` is verified to work against a freshly-parsed module — I confirmed with `LLVM.jl` against real Julia IR for `(UInt32, UInt64, UInt32)`: offsets are `[0, 8, 16]`.

Note the deliberate choice: `total_bits = sum(widths)`, not `storage_size`. The padding between fields (e.g. 32 bits between `i32 @ 0` and `i64 @ 8`) never carries information — it's not stored into, so the Bennett circuit has no wires for it. `ret_elem_widths` is already tuple-field-ordered and the simulator's `_read_output` walks it in order without caring about gaps. Keeping `total_bits = sum(widths)` means downstream code (the `copy(resolve!(...))` at `lower.jl:361`) gets exactly the right wire count.

### 2.2 `sret_info` struct

A single `NamedTuple` (or `struct`) — I'll use a NamedTuple here to avoid adding a new type:

```
sret_info = (
    param_sym     :: Symbol,                   # what we named the sret parameter
    agg_ty        :: LLVM.LLVMType,            # ArrayType or StructType (for debugging)
    slot_widths   :: Vector{Int},              # [32, 32, 32] for [3 x i32]
    slot_offsets  :: Vector{Int},              # [0, 4, 8] bytes
    total_bits    :: Int,                      # 96 for [3 x i32]
    total_bytes   :: Int,                      # 12 for [3 x i32]  — matches dereferenceable(N)
    slot_by_byte  :: Dict{Int, Int},           # byte_offset -> slot index (0-based)
)
```

`slot_by_byte` is the hot-path lookup used when translating each store. For `[3 x i32]`, it's `Dict(0=>0, 4=>1, 8=>2)`. For `{i32,i64,i32}`, `Dict(0=>0, 8=>1, 16=>2)`.

---

## 3. Args list handling — excluding `sret`

### 3.1 What changes in the parameter loop

Current loop (`src/ir_extract.jl:169–191`):

```
for p in LLVM.parameters(func)
    nm = LLVM.name(p)
    sym = isempty(nm) ? _auto_name(counter) : Symbol(nm)
    names[p.ref] = sym
    ptype = LLVM.value_type(p)
    if ptype isa LLVM.IntegerType
        push!(args, (sym, LLVM.width(ptype)))
    elseif ptype isa LLVM.FloatingPointType
        push!(args, (sym, _type_width(ptype)))
    elseif ptype isa LLVM.PointerType
        deref = _get_deref_bytes(func, p)
        if deref > 0
            w = deref * 8
            push!(args, (sym, w))
            ptr_params[sym] = (sym, deref)
        end
    end
end
```

The sret parameter is a `PointerType` with `dereferenceable(N)` set. Under the current code it would be pushed into `args` as a 96-bit "input" wire array — which is wrong: sret is an output buffer, not a function input. The circuit would allocate 96 input wires for something the caller doesn't supply.

### 3.2 Proposed loop — skip sret, still name it

```
for (i, p) in enumerate(LLVM.parameters(func))
    nm  = LLVM.name(p)
    sym = isempty(nm) ? _auto_name(counter) : Symbol(nm)
    names[p.ref] = sym              # name it — needed for store-ptr lookup

    # sret parameter: record the sym, skip args, do NOT register as ptr_params
    if sret_info !== nothing && p.ref === sret_param_ref
        sret_info = merge(sret_info, (; param_sym = sym))
        continue                    # ← critical: excluded from args
    end

    ptype = LLVM.value_type(p)
    # ... existing branches unchanged ...
end
```

Note `continue` — the sret parameter is still entered in the `names` map (so `_operand(sret_return, ...)` won't crash with "Unknown operand ref"), but it contributes zero input wires. The downstream simulator's `_simulate` loop over `input_widths` (simulator.jl:18) iterates only over real inputs, which is the desired behaviour.

### 3.3 Why not also do this for non-sret `dereferenceable` pointer params?

The existing behavior for pointer params (`NTuple` byref inputs, like `f_ptr_in_out` in my scratch IR) treats them as flat 96-bit read-only wire arrays, which is correct — those are genuine inputs. Only sret is an output-only buffer. Keying the skip on the `sret` attribute (not on `PointerType`) preserves that existing path.

---

## 4. Store tracking

### 4.1 The problem

Under `optimize=true`, the IR shape for sret (from the brief and my confirmation runs) is:

```
store i32 %v0, ptr %sret_return, align 4                                 ; slot 0
%p1 = getelementptr inbounds i8, ptr %sret_return, i64 4                 ; &slot_1
store i32 %v1, ptr %p1, align 4                                          ; slot 1
%p2 = getelementptr inbounds i8, ptr %sret_return, i64 8                 ; &slot_2
store i32 %v2, ptr %p2, align 4                                          ; slot 2
```

Key observations from my IR walk (`LLVM.API.LLVMGetGEPSourceElementType` returns `i8`):

- The first store writes directly through `sret_return` (no GEP — implicit offset 0).
- Subsequent stores go through byte-offset GEPs from `sret_return` with source element type `i8` and a `ConstantInt` operand.
- The value type is the element integer type (`i32` for `[N x i32]`).

### 4.2 Current handler — why it doesn't work

`_convert_instruction` has handlers for `GetElementPtr` (lines 785–822) and `Store` (lines 970–982). The GEP handler produces `IRPtrOffset`, and the store handler produces `IRStore`. Both rely on the `names[ptr.ref]` being in the SSA map.

Then `lower.jl`'s `lower_store!` demands provenance back to an *alloca*, which sret-return is not, so it would error out:

```
error("lower_store!: no provenance for ptr %$(inst.ptr.name); " *
      "store must target an alloca or GEP thereof")
```

### 4.3 Proposed mechanism — intercept at extraction time

Route sret stores away from `IRStore` and into a synthetic per-slot value table. The table lives in the extractor (pre-lowering), and the downstream view is a clean insertvalue-chain + IRRet, identical to the n=2 path.

Extractor-local state, threaded through `_convert_instruction`:

```
sret_ctx = (
    info           :: NamedTuple,                      # from §2
    gep_byte_map   :: Dict{_LLVMRef, Int},             # dest SSA ref -> byte offset
                                                       # (populated as GEPs from sret are seen)
    slot_value     :: Dict{Int, Tuple{IROperand, Int}} # slot index -> (latest value, store order)
                                                       #   0-based slot index
)
```

Two new mini-handlers in `_convert_instruction` (inserted before the existing GEP handler at line 785 and before the existing store handler at line 972):

#### GEP from sret → record byte offset, return nothing

```
if opc == LLVM.API.LLVMGetElementPtr && sret_info !== nothing
    ops = LLVM.operands(inst)
    base = ops[1]
    if base.ref === sret_param_ref && length(ops) == 2 && ops[2] isa LLVM.ConstantInt
        byte_off = convert(Int, ops[2])
        sret_ctx.gep_byte_map[inst.ref] = byte_off
        return nothing                           # consumed — no IRInst emitted
    end
    # Also handle GEP-of-GEP where the chain's ultimate base is sret_return.
    # (Not seen in optimize=true IR, but future-proof.)
    if haskey(sret_ctx.gep_byte_map, base.ref) && length(ops) == 2 && ops[2] isa LLVM.ConstantInt
        byte_off = sret_ctx.gep_byte_map[base.ref] + convert(Int, ops[2])
        sret_ctx.gep_byte_map[inst.ref] = byte_off
        return nothing
    end
end
```

Src-element-type on the GEP is always `i8` in the observed IR (so 1 byte per index unit = the `ConstantInt` value = byte offset). We don't need to scale by an element size. We do assert the type-ref reads back as i8 as a defence-in-depth check:

```
src_elt = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(inst))
(src_elt isa LLVM.IntegerType && LLVM.width(src_elt) == 8) ||
    error("Unsupported sret-GEP src element type $src_elt (expected i8)")
```

#### Store into sret → record value, return nothing

```
if opc == LLVM.API.LLVMStore && sret_info !== nothing
    ops = LLVM.operands(inst)
    val, ptr = ops[1], ops[2]
    vt = LLVM.value_type(val)
    vt isa LLVM.IntegerType || # fall through; handle normally (still unsupported for pointer or vector val)

    byte_off = nothing
    if ptr.ref === sret_param_ref
        byte_off = 0
    elseif haskey(sret_ctx.gep_byte_map, ptr.ref)
        byte_off = sret_ctx.gep_byte_map[ptr.ref]
    end

    if byte_off !== nothing
        # This store targets the sret buffer.
        slot = get(sret_info.slot_by_byte, byte_off, nothing)
        slot === nothing &&
            error("sret store at byte offset $byte_off does not match any slot " *
                  "(slots: $(sret_info.slot_by_byte)). Partial / misaligned stores " *
                  "into sret are not supported.")

        stored_bits = LLVM.width(vt)
        stored_bits == sret_info.slot_widths[slot + 1] ||
            error("sret store at slot $slot: value width $stored_bits doesn't match " *
                  "slot width $(sret_info.slot_widths[slot + 1])")

        sret_ctx.slot_value[slot] = _operand(val, names)   # note: _operand resolves SSA/const
        return nothing                                     # consumed
    end
    # Not an sret store — fall through to existing IRStore handler.
end
```

Note two crucial "fall-through" conditions:

- Non-integer store value (`vt` is a pointer or `<2 x i32>` vector). These are rare but appear under some LLVM optimisations (I saw `store <2 x i32> %1, ptr %p` in one NTuple-in/out fixture). We fall through; the existing store handler already returns `nothing` for non-integer value types (`vt isa LLVM.IntegerType || return nothing` at line 977). This means vector stores into sret are **silently dropped** — a correctness bug. We must catch this: if the pointer lands on sret and the value is non-integer, emit a hard `error()` (see §6).
- The pointer isn't sret-relative. The store stays on the normal `IRStore` path and flows through `lower_store!` — which will error if it has no alloca provenance. That's the correct fail-fast behavior for non-sret stores we don't understand.

### 4.4 Why GEPs return `nothing` rather than something synthetic

An alternative would be to emit a marker `IRInst` on GEPs from sret. That adds downstream complexity (every pass in `lower.jl` / `dep_dag.jl` / `liveness` would need a case for the marker). Returning `nothing` from `_convert_instruction` is already legal (see GEP with unknown base at line 821, `store` with non-integer value at line 977) and the outer loop drops `nothing` values gracefully (`ir_inst === nothing && continue` at line 210). The offset map lives in the extractor's local state only — no IR type pollution, no lowering-pass changes.

### 4.5 Multi-block control flow — sret stores in different blocks

The brief and my exploratory runs confirm LLVM's optimizer is aggressive:

- For `if/else` branches returning different tuples, LLVM hoists scalar ops to a common successor and threads values through `phi` nodes, so the actual stores live in one block (`common.ret`).
- For diamond CFGs where both branches truly compute separately, the same pattern holds — the stores are gated by phi'd values in a merge block.

**Assumption we rely on (and must check)**: under `optimize=true`, every slot has **exactly one** store in the compiled function. The stored value may itself be a phi node (so it carries branching information, merged via the lowering pipeline's existing phi resolution), but the store instruction itself is unique.

My proposal therefore includes a defensive check at `ret void` translation time:

```
for slot in 0:(sret_info.slot_count - 1)
    haskey(sret_ctx.slot_value, slot) ||
        error("sret slot $slot has no store — sret translation requires every slot " *
              "to be written before ret void (multi-store or conditional-no-store " *
              "patterns not yet supported)")
end
```

If this fires, the failure mode is the classic "loop-assembled struct" or "nested if with return in one branch" pattern, which this design deliberately defers (see §6).

**What if the same slot is stored twice?** This happens under `optimize=false` via `alloca+memcpy`, which this design rejects (§6). Under `optimize=true`, the last store wins in LLVM semantics; we could honour that by `sret_ctx.slot_value[slot] = ...` on every assignment and taking the last. My design keeps the hard error for the multi-store case and is permissive only if a test fixture forces us to loosen it — fail-fast is more in keeping with CLAUDE.md rule 1.

---

## 5. `IRRet` synthesis at `ret void`

### 5.1 What existing code does for n=2

The existing `insertvalue`-chain flow (brief's n=2 IR):

```
%a0 = insertvalue [2 x i8] zeroinitializer, i8 %b, 0
%a1 = insertvalue [2 x i8] %a0, i8 %a, 1
ret [2 x i8] %a1
```

Produces:

```
IRInsertValue(:a0, __zero_agg__, %b, 0, 8, 2)
IRInsertValue(:a1, :a0,          %a, 1, 8, 2)
IRRet(:a1, 16)
```

Which `lower.jl` resolves to a 16-wire aggregate and `IRRet` reads those 16 wires as the output.

### 5.2 What we synthesise for sret n=3

At the `ret void` instruction inside `_convert_instruction`, when `sret_info !== nothing`, we:

1. Assert every slot has a stored value (see §4.5 defensive check).
2. Emit a synthetic `IRInsertValue` chain into the block's instruction list **just before** the terminator.
3. Return an `IRRet` referencing the final chain's dest.

Concretely, the ret handler becomes (replacing the single return path, not duplicating the whole ret code):

```
if opc == LLVM.API.LLVMRet
    if sret_info !== nothing
        ops = LLVM.operands(inst)
        isempty(ops) ||
            error("ret with operand but sret attribute set; malformed IR")
        return _synthesise_sret_ret(sret_info, sret_ctx, counter)   # ← returns Vector{IRInst}
    end
    # existing non-sret ret path unchanged
    ops = LLVM.operands(inst)
    return IRRet(_operand(ops[1], names), _iwidth(ops[1]))
end
```

Where `_synthesise_sret_ret` constructs the chain. Note: `_convert_instruction` already supports returning `Vector{IRInst}` from a single LLVM instruction (see `llvm.umax/bswap/fshl` handlers at lines 492–706; the block-walker at line 211 splits `Vector` return into multiple `push!` calls, and then checks the final element for terminator status at line 215).

But — and this is an important subtlety — the `Vector{IRInst}` split at line 211–220 pushes all-but-one into `insts` and then checks whether the *whole* vector is a terminator. Current handlers return vectors that all end in a non-terminator (e.g. the final `IRBinOp` of a `bswap` expansion). For us, the final element is an `IRRet`, which **is** a terminator.

Looking at the exact loop more carefully (lines 208–220):

```
for inst in LLVM.instructions(bb)
    ir_inst = _convert_instruction(inst, names, counter)
    ir_inst === nothing && continue
    if ir_inst isa Vector
        for sub in ir_inst
            push!(insts, sub)
        end
    elseif ir_inst isa IRRet || ir_inst isa IRBranch || ir_inst isa IRSwitch
        terminator = ir_inst
    else
        push!(insts, ir_inst)
    end
end
```

A Vector return always goes through `push!(insts, sub)` for every element — including a terminator. That's a latent bug but also a usable hook: we can return `(Vector{IRInst}, IRRet)` separately. But that would change the handler contract.

**My preferred approach**: return the **insertvalue chain as a `Vector{IRInst}`**, but arrange for the chain to be emitted in the block's instruction stream *on a previous instruction* (the `ret void` itself). Specifically, emit the chain from the `ret void` handler, and return a single `IRRet` value — the block walker pushes the chain into `insts` internally first, then registers the final `IRRet` as terminator.

Problem: the existing loop only treats a single instruction return — vectors are all pushed as instructions. It would never recognise the last element as a terminator.

**Solution (simplest)**: make the synthetic `IRInsertValue`s be a prefix in the vector, and the final element be an `IRRet`. Then patch the outer loop so that when `ir_inst isa Vector` and its last element is a terminator (`IRRet|IRBranch|IRSwitch`), the prefix is pushed into `insts` and the last becomes the `terminator`:

```
if ir_inst isa Vector
    last = ir_inst[end]
    if last isa IRRet || last isa IRBranch || last isa IRSwitch
        for sub in ir_inst[1:end-1]
            push!(insts, sub)
        end
        terminator = last
    else
        for sub in ir_inst
            push!(insts, sub)
        end
    end
elseif ir_inst isa IRRet || ir_inst isa IRBranch || ir_inst isa IRSwitch
    terminator = ir_inst
else
    push!(insts, ir_inst)
end
```

This tiny 4-line patch is confined to `_module_to_parsed_ir`'s block walk and preserves all existing single-instruction-or-Vector behaviours. The `bswap`-style handlers that end in a non-terminator are unaffected (their last element is `IRBinOp`). No test should regress from this.

### 5.3 The synthetic chain

```
function _synthesise_sret_ret(info, ctx, counter)
    n = info.slot_count
    chain = IRInst[]
    prev = ssa(Symbol("__sret_zero"))           # placeholder, never used; we re-map below
    # simpler: start with __zero_agg__ sentinel, same convention as n=2 path
    agg_op = IROperand(:const, :__zero_agg__, 0)

    # compute a "normalized" element width for the aggregate.
    # For ArrayType the widths are uniform; for StructType they may differ —
    # the existing IRInsertValue has a single `elem_width` field, which already
    # encodes that uniformity assumption. We emit per-slot IRInsertValue with
    # the correct slot width; n_elems is the slot count.
    for slot in 0:(n - 1)
        dest = _auto_name(counter)              # synthesize a fresh SSA name
        val_op = ctx.slot_value[slot]           # set in §4
        w      = info.slot_widths[slot + 1]
        push!(chain, IRInsertValue(dest, agg_op, val_op, slot, w, n))
        agg_op = ssa(dest)
    end
    push!(chain, IRRet(agg_op, info.total_bits))
    return chain
end
```

Note a caveat for `StructType` (heterogeneous widths): the current `IRInsertValue` type has a single `elem_width` field, implying the aggregate is homogeneous. For `ArrayType` sret (the SHA-256 case: all slots are `i32`), this is fine. For `StructType` with mixed widths (`{i32, i64, i32}`), the downstream `lower_insertvalue!` at `lower.jl:1559` computes `total_w = inst.elem_width * inst.n_elems` — which is wrong for heterogeneous aggregates.

**Mitigation option A (preferred, MVP)**: Reject `StructType` sret with a clear error. Julia's common case — `NTuple{N,UInt32}` returns for SHA-256 — is always `ArrayType`. `StructType` returns come from `Tuple{UInt32, UInt64, UInt32}` etc.; those can be added later.

**Mitigation option B (future)**: Extend `IRInsertValue` to carry a per-slot width (or a pre-computed total). This would be an `ir_types.jl` change, requiring the 3+1 workflow. Out of scope for this proposal.

My recommendation: **MVP = option A**. SHA-256 ships with homogeneous `[8 x i32]` sret, which is all BC.3 needs.

### 5.4 Integrating with `_ssa_operands` and liveness

`_ssa_operands(IRInsertValue)` at `lower.jl:175` already reads `agg` and `val`. The synthetic chain's `val_op` inherits the SSA name of whatever computed the slot's value — that name is already a real SSA in the IR (the stored value). So liveness analysis correctly extends the slot-value's live range to the end of the function. Nothing to add.

---

## 6. Error boundaries

Invariant: **fail fast with a precise message**. The shape of unsupported sret IR must error at extraction time with enough context to debug.

### 6.1 Supported (MVP)

| Pattern                                                         | Status    |
| --------------------------------------------------------------- | --------- |
| `sret([N x iM])`, direct stores to `sret_return` + byte GEPs    | Supported |
| `sret([N x iM])` with stores in a single block                  | Supported |
| `sret([N x iM])` with stored values that are phi nodes (multi-block merge into single-store-block) | Supported |
| n=3..16, widths in {8, 16, 32, 64}                              | Supported |
| `optimize=true` (the default)                                   | Supported |

### 6.2 Errored (MVP) with specific messages

| Pattern | Error |
| --- | --- |
| `optimize=false` shape (`alloca + memcpy` to sret) | `error("sret extraction requires optimize=true; got memcpy-style sret pattern. Re-compile with optimize=true, or register the function's implementation as a SoftFloat-style callee.")` |
| `StructType` sret (heterogeneous widths) | `error("Heterogeneous sret aggregate $agg_ty is not yet supported (IRInsertValue has a single elem_width). Use a homogeneous tuple like NTuple{N,UInt32}.")` |
| Store into sret with non-integer value type (e.g. `store <2 x i32> %v, ...`) | `error("sret store with value type $vt; only integer stores are supported. Vectorised sret stores happen when sret coexists with a vector-loaded NTuple input.")` |
| GEP from sret with non-i8 source element type | `error("sret GEP with source element type $src_elt; expected i8. This is an unsupported ABI variant.")` |
| GEP from sret with non-constant index | `error("sret GEP with SSA index; byte offset cannot be resolved at compile time.")` |
| Byte offset that doesn't match any slot | `error("sret store at byte offset $byte_off doesn't match any slot; partial / misaligned stores into sret are not supported. Slot offsets: $(info.slot_by_byte)")` |
| Value width != slot width | `error("sret slot $slot: stored value width $v != slot width $s.")` |
| A slot with no store before `ret void` | `error("sret slot $slot has no store before ret void. Multi-block patterns where some paths don't write every slot are not supported.")` |
| Multiple sret parameters | `error("Multiple sret parameters — LangRef forbids this")` |
| Aggregate element type is not an integer (e.g., `sret([N x float])`) | `error("sret aggregate element type $elem_ty; only integer elements are supported. Float tuple returns should be UInt64-reinterpreted via the SoftFloat wrapper.")` |

### 6.3 Silent (existing behavior preserved)

- Non-integer store outside sret: existing `return nothing` at `ir_extract.jl:977`.
- Pgcstack / non-sret pointer param without `dereferenceable`: existing skip at line 188.

### 6.4 Defensive playbook comment

The new code carries a block comment: "If sret extraction errors, first verify (1) `optimize=true`, (2) tuple type is homogeneous `NTuple{N,UInt32}`-shape, (3) every control-flow path writes every slot. To debug: run `code_llvm(f, args; optimize=true, debuginfo=:none)` and check every `store` targets either `%sret_return` directly or a byte-offset GEP from it. `store <N x iW>` or `@llvm.memcpy` indicates an optimiser form this design doesn't yet handle."

---

## 7. Test plan

New file: **`test/test_sret.jl`**. Must be added to `test/runtests.jl` (one-line include).

Test cases, each **exhaustive over representative input ranges** and followed by `verify_reversibility(circuit)`:

### 7.1 Basic sret compilation

```
sret3(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
sret4(a::UInt32, b::UInt32, c::UInt32, d::UInt32) = (a, b, c, d)
sret5(a::UInt32, b::UInt32) = (a, b, a+b, a-b, a*b)
sret8(a::UInt32, b::UInt32) = (a+b, a*b, a^b, a|b, a&b, a-b, a<<1, b<<1)   # BC.3-shaped
sret16(a::UInt32, b::UInt32) = ntuple(i -> i % 2 == 0 ? a : b, Val(16))    # larger stress test
```

For each: compile, then for 4-8 representative (UInt32, UInt32[, ...]) inputs, `simulate` and check the result matches the native function's output. Verify reversibility.

### 7.2 sret with mixed widths in arguments (not in return)

```
sret_widening(a::UInt8, b::UInt16, c::UInt32) = (UInt32(a), UInt32(b), c)
```

Homogeneous return (all `UInt32`), mixed-width args. Tests that `args` skips sret but keeps widened-input tracking.

### 7.3 sret with branching (phi-fed values)

```
function sret_branch(a::UInt32, b::UInt32, cond::UInt32)
    if cond > 100
        return (a*a, b*b, a+b)
    else
        return (a+b, a-b, a*b)
    end
end
```

This produces (from my exploratory run):

- 3 `phi` nodes in `common.ret`
- 3 stores to sret in `common.ret`, each feeding from a phi

Which means our design handles it: the `IROperand` we record for each slot is an SSA reference to a phi, and the phi resolution in `lower.jl` has already been proven correct for this topology.

### 7.4 sret with unreachable / guard pattern

```
function sret_guard(a::UInt32)
    a == 0 && throw(DomainError(a))
    return (a, a+UInt32(1), a+UInt32(2))
end
```

Julia inserts a guard block with `throw` + `unreachable`. The sret stores live on the normal path. Tests that we don't stumble on the unreachable branch.

### 7.5 No-sret regression

Running the existing `test/test_tuple.jl` (swap_pair, complex_mul_real, dot_product) and `test_gate_count_regression.jl` after the change must produce identical gate counts. Lock the known-good `gate_count` returned from the current baseline (captured from `WORKLOG.md` baselines `i8=86, i16=174, i32=350, i64=702`) as asserted values in the new sret test file so any future drift fires loudly.

### 7.6 Negative tests — errors must fire with clear messages

```
@testset "sret errors" begin
    # Heterogeneous tuple should error with a specific StructType message
    f_het(a::UInt32, b::UInt64) = (a, b, a)
    @test_throws ErrorException reversible_compile(f_het, UInt32, UInt64)
    # Float elements
    # (Requires construction — could skip if no good way to force)
end
```

### 7.7 SHA-256 end-to-end smoke (optional, if time permits)

Wire the new sret handling into a smaller-than-full SHA-256 fixture (e.g. one round function that returns 8 UInt32). A full SHA-256 test can be deferred to `test_sha256_full.jl` after merge.

### 7.8 Test invocation

```
julia --project test/test_sret.jl
julia --project -e 'using Pkg; Pkg.test()'    # full suite
```

Both must pass. Running single-file is fast for red-green TDD (CLAUDE.md rule 3, 8).

---

## 8. Edge cases

### 8.1 Single-block vs multi-block

- **Single-block**: the ordinary SHA-256 round shape; all stores and the `ret void` live in `top`. Handled directly.
- **Multi-block with scalar phis in `common.ret`**: stores and `ret void` live in `common.ret`; stored values are phis merged from predecessor blocks. Handled — the value-operand tracking stores an `IROperand(:ssa, phi_name, ...)`, and the existing phi resolution in `lower.jl` computes the merged wire set. We do nothing special.
- **Multi-block with stores in predecessor blocks (no merge)**: rare under `optimize=true`, but possible. If the stores are in different blocks and the same slot is written in only one predecessor of a join block, we'd see only one of them depending on which block we visit first. The §4.5 defensive check catches this (`slot_value` won't have all slots populated).

### 8.2 Does the existing n=2 `[N x iM]` by-value path still apply?

Yes. When the return is a small enough aggregate (≤16 bytes, homogeneous, standard case), Julia emits `ret [N x iM] %agg`. The existing line 156 path handles it:

```
ret_elem_widths = if rt isa LLVM.ArrayType
    [LLVM.width(LLVM.eltype(rt)) for _ in 1:LLVM.length(rt)]
else
    [ret_width]
end
```

Our new code only runs when `sret_info !== nothing`. So `swap_pair`, `complex_mul_real`, and `dot_product` from `test_tuple.jl` don't route through any new code — zero bytes of new code execute for them, and gate counts are bit-for-bit preserved.

### 8.3 Cross-talk with the "dereferenceable ptr-param treated as flat input" path

The existing `ptr_params` dict at line 168 is the "byref input" path. My design ensures the sret parameter never lands in `ptr_params` (the `continue` at §3.2 skips all of the `PointerType` branches). For a function taking an `NTuple{3,UInt32}` input *and* returning a 3-tuple (see my `f_ptr_in_out` exploratory IR), both paths coexist cleanly:

- Input NTuple param: `ptr_params[sym] = (sym, deref)`; flows through `IRLoad` / `IRPtrOffset`.
- Output sret param: recorded in `sret_info.param_sym`; flows through the new intercept.

### 8.4 Aliasing: can a store GEP target be the sret buffer via a non-constant offset?

This shouldn't happen under `optimize=true` — SROA hoists everything to constants. If it does happen, the GEP-intercept rejects (§6.2 "GEP from sret with non-constant index"), and the function fails compilation with a clear error. User's escape: set `optimize=true` and lower the abstraction in the source.

### 8.5 Liveness / in-place optimisation

The in-place optimiser (`lower.jl`, `compute_ssa_liveness` at line 231) uses `_ssa_operands(IRRet)` at line 190. `IRRet` reads one SSA name. The synthetic chain appends one `IRInsertValue` per slot, each reading two (agg, val). These are normal instructions; in-place optimisations (wire reuse, liveness-driven ancilla recycling) apply as for any other aggregate construction.

### 8.6 Constant-folding pass

`_fold_constants` (lower.jl:418) walks the gate stream — it doesn't care about the source of the gates, only about which wires are constant. Our synthetic chain produces normal CNOT gates via `lower_insertvalue!`, so constant folding works as before.

### 8.7 The `counter` for synthetic names

`counter` is already a local `Ref{Int}` (line 136), not a global. Our `_auto_name(counter)` calls append to the same counter, so synthetic SSA names never collide with real LLVM names. Existing handlers (`llvm.umax`, `ctlz`, `bswap`, etc.) already use this pattern.

---

## 9. Alternatives considered — and why rejected

### 9.1 IR-rewriting pass before extraction (`sret → by-value`)

**Idea**: Run an LLVM pass that rewrites `void @f(sret(T) %s, ...) { ... store ...; ret void }` into `T @f(...) { ...; ret T %aggregate }` before `_module_to_parsed_ir`. Then the existing n=2 code path handles everything unchanged.

**Why rejected**:

- Writing a correct pass is a large amount of code (CFG rewiring, GEP→insertvalue substitution, phi fix-up across predecessors).
- Requires touching the LLVM IR layer, which is where the bug density is highest.
- Doesn't actually simplify the problem: a pass has to solve the same "which byte offset corresponds to which slot" question as our extraction-time synthesis. We'd just be solving it in a more expensive language (LLVM pass builder) with worse diagnostics.
- LLVM's pipelines don't have an `unsret` pass; we'd have to write one.
- Violates CLAUDE.md rule 5 ("LLVM IR is not stable") — rewriting IR *to* something stable is still rewriting.
- **Most damning**: The pass would have to run before SROA/mem2reg/etc., but after Julia's ABI lowering has already inserted the sret param. The phase ordering is awkward.

Verdict: **extraction-time synthesis is strictly simpler**. Our synthesis produces normal-shape `IRInsertValue + IRRet` instructions for the rest of the pipeline — from `lower.jl`'s perspective, a 3-tuple sret is indistinguishable from a by-value 2-tuple return.

### 9.2 Add a new `IRRet`-equivalent carrying sret metadata

**Idea**: Introduce `IRSretRet(slot_values::Vector{IROperand}, slot_widths::Vector{Int})` as a new IR type.

**Why rejected**:

- Changes `ir_types.jl`, triggering the 3+1 agent workflow for core types (rule 2).
- Requires `lower.jl` changes to handle the new instruction; forks the existing `IRRet` path.
- The synthetic `IRInsertValue` chain is functionally equivalent and costs zero changes to `lower.jl`, `bennett.jl`, or `simulator.jl`.
- Gate counts would have to be re-verified from scratch.

### 9.3 Return a tuple of pointers pretending sret is an input wire array

**Idea**: Treat the sret buffer as a 96-bit "output wire" that the caller pre-allocates. Stores become writes into those wires; `ret void` becomes `IRRet(sret_wires, 96)`.

**Why rejected**:

- Requires plumbing output wires distinct from ancillae in the Bennett construction. The current model is: output = resolve(IRRet.op). There's no pattern for "take these pre-allocated wires as outputs".
- The sret parameter has `sret` semantics (uninitialised buffer), so treating it as an input wire array is semantically wrong — input wires are assumed to be initialised by the caller. A 96-bit "uninit input" doesn't cleanly fit Bennett's invariant (ancillae-zero at start; inputs carry caller data).

### 9.4 Just run the LLVM `argpromotion` or `deadargelim` passes first

**Idea**: Use an existing pass to eliminate sret.

**Why rejected**:

- `argpromotion` doesn't handle sret specifically — it targets arg-load patterns, not sret stores.
- None of the standard NPM passes unlower sret; it's an ABI lowering, not an optimisation.
- I checked: running `sroa,mem2reg,simplifycfg,instcombine` (the `DEFAULT_PREPROCESSING_PASSES`) on a sret function leaves sret unchanged (as expected).

---

## 10. Integration risk & verification plan

### 10.1 Which tests might this affect?

**Guaranteed unaffected** — no sret present, so the new code path is never entered. This covers the bulk of the 71-file suite: all scalar-return tests (`test_increment`, `test_polynomial`, `test_bitwise`, `test_compare`, `test_branch`, `test_loop*`, `test_combined`, `test_mixed_width`, `test_int{16,32,64}`, `test_two_args`, `test_narrow`, `test_negative`), all softfloat tests (`test_softfloat`, `test_float_*`, `test_soft_*`, `test_softf{add,sub,mul,div,cmp}`), all memory tests (`test_store_alloca_extract`, `test_rev_memory`, `test_shadow_memory`, `test_memssa*`, `test_var_gep`, `test_qrom*`, `test_lower_store_alloca`, `test_mutable_array`, `test_ir_memory_types`, `test_ntuple_input`), all algorithm tests (`test_karatsuba`, `test_feistel`, `test_division`, `test_switch`, `test_controlled`, `test_sha256` pre-sret subset), all scheduling tests (`test_pebbling*`, `test_eager_bennett`, `test_value_eager`, `test_dep_dag`, `test_liveness`, `test_constant_*`, `test_sat_pebbling`), and the regression gate (`test_gate_count_regression`).

**Potentially affected**:

- `test_tuple.jl`: uses by-value tuple returns (Int8, ≤16 bytes) — **no sret** — the new code path isn't entered. Gate counts preserved bit-exact. Key regression test.
- `test_extractvalue.jl`: by-value `ret [N x iM]` — unaffected.
- `test_sha256_full.jl`: currently fails for the sret reason; after this fix, it should start passing. We should NOT mark it as regression-affected; it's regression-unblocked.

### 10.2 Verification procedure

Before merge:

1. **Red-green TDD**: write `test/test_sret.jl` from §7, confirm it fails with the current `Unsupported LLVM type for width: LLVM.VoidType(void)` message.
2. Implement the sret intercept per this design.
3. Watch `test_sret.jl` pass.
4. Run the full test suite: `julia --project -e 'using Pkg; Pkg.test()'`.
5. Compare gate-count output of `test_tuple.jl`, `test_increment.jl`, `test_polynomial.jl`, `test_int32.jl`, `test_int64.jl` against WORKLOG.md baselines. These must be **identical**.
6. If `test_gate_count_regression.jl` exists and checks baseline numbers, it must pass unchanged.
7. `verify_reversibility` must return true for every sret-compiled circuit.

### 10.3 Post-merge smoke

After the fix lands, `test_sha256_full.jl` (previously blocked) should compile. Running it is the final integration check for BC.3.

---

## 11. Summary: implementation checklist

1. **Detect** sret via `LLVMGetEnumAttributeAtIndex(func, i, kind_sret=78)` on every parameter; build `sret_info` NamedTuple (`param_sym`, `slot_widths`, `slot_offsets`, `total_bits`, `slot_by_byte`).
2. **`ArrayType` only** in MVP; reject `StructType` with a precise error (IRInsertValue's single `elem_width` forces homogeneous).
3. **`ret_width` / `ret_elem_widths`**: derive from `sret_info` when present; else use existing lines 152–160 unchanged.
4. **Param loop**: name sret parameter (for `names[p.ref]`), then `continue` — do not push into `args` or `ptr_params`.
5. **New intercepts in `_convert_instruction`**, inserted before existing GEP (line 785) and Store (line 970) handlers:
   - GEP from sret, constant byte-offset index: record in `sret_ctx.gep_byte_map`, return `nothing`.
   - Store to sret (direct or via known GEP): record in `sret_ctx.slot_value`, return `nothing`.
   - `ret void` with sret present: synthesise `IRInsertValue` chain + `IRRet`, return as `Vector{IRInst}`.
6. **Block-walker patch** (4 lines): when `Vector{IRInst}` ends in a terminator, split and assign `terminator` to the last element.
7. **Defensive check at ret void**: every slot must have a value, else error.
8. **Tests**: `test/test_sret.jl` with n=3,4,5,8,16, branching, mixed-width args, and negative tests. Existing suite must run unchanged with identical gate counts.

---

## 12. Appendix: IR fixtures I confirmed against

I ran each of these against `code_llvm(..., optimize=true, debuginfo=:none)` before writing the design and confirmed the shapes claimed in §1–5:

| Fixture | Shape observed | Used to validate |
| --- | --- | --- |
| `f3(a,b,c)=(a,b,c)` (UInt32) | `sret([3 x i32])`, 3 stores, 2 GEPs (i8 src, const offset 4/8), in `top` | §1.2, §4.1, §4.3 |
| `f_complex(a,b,cond)` branching ternary | `sret([3 x i32])`, 3 phis + 3 stores in `common.ret`, 2 predecessor blocks | §4.5, §7.3 |
| `f_het(a::UInt32,b::UInt64,c::UInt32)=(a,b,c)` | `sret({i32,i64,i32})`, `dereferenceable(24)`, offsets `[0,8,16]` via `LLVM.offsetof` | §2.1, §5.3 rejection |
| `f4(a,b)=(a,b,a,b)` (UInt32, 16 bytes) | Already sret — confirms ABI threshold is ≤16 bytes exclusive | §10.1 threshold |
| `f_mixed(a::UInt8,b::UInt32,c::UInt16)` returning 4×i8 | By-value `[4 x i8]` return, no sret — §8.2 regression case | §8.2 |
| `f_sha(a,b)→8-tuple UInt32` | `sret([8 x i32])`, `dereferenceable(32)`, 8 stores, 7 GEPs in `top` | §7.1 BC.3 shape |

All confirmed compatible with this design. The LLVM.jl C API probes for sret attribute detection (`LLVMGetEnumAttributeKindForName("sret",4) → 78`; `LLVMGetEnumAttributeAtIndex`/`LLVMGetTypeAttributeValue`) all return valid non-null handles on these fixtures, with the expected `ArrayType`/`StructType` types, element counts, and offsets.

---

**End of design document.**
