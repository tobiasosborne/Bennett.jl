# cc0.3 + cc0.5 Design — Proposer B

**Beads**: Bennett-cc0.3 (LLVMGlobalAliasValueKind) and Bennett-cc0.5
(thread_ptr GEP base). Both land together — cc0.3 is the first error on
many Julia allocation pathways; if cc0.3 is fixed alone, cc0.5 becomes the
NEXT error on the same IR, so shipping only one leaves the corpus still RED.

**Scope discipline (CLAUDE.md §12)**: every fix proposed below lives in
`src/ir_extract.jl`. `lower.jl` is not touched — the existing
`GEP base … not found in variable wires` / `lower_alloca!` paths already
produce clear errors for anything that escapes the extractor's new
recogniser, which is exactly what the acceptance criteria ask for.

**Core idea**: both problems come from an assumption the extractor used to
hold — "every operand I see is a thing I can wire." That assumption was
always fragile (it crashed on GlobalAlias, on thread_ptr GEPs, on opaque
runtime calls); the partial fixes in cc0.7 (`_safe_is_vector_type`,
`_any_vector_operand`) already concede the point by swallowing the
crash. Proposer B formalises the concession: every operand the extractor
cannot materialise becomes a typed **opaque sentinel** that flows through
ParsedIR so lower.jl can produce a clean, bead-scoped error if that operand
is ever actually consumed. Most of the time it isn't consumed (it's the
aliasee pointer that the Julia runtime writes into a dead GC slot, or the
`thread_ptr` at the root of a TLS chain that gets stored somewhere the
Julia function's observable semantics never read).

---

## §1 — cc0.3 strategy (one paragraph)

The cc0.3 crash is not "how do we compile a GlobalAlias" — GlobalAliases
in Julia's emitted IR overwhelmingly refer to **opaque runtime storage**
(type descriptors, dispatch tables, boxed constant roots). Compiling them
as primal wires would be wrong. The fix is to **never let
`LLVM.Value(ref)` see an alias ref** in the first place: intercept every
site where the extractor takes a raw ref and materialises a wrapper
(operand iteration, constant-expression descent, name-table build,
`_extract_const_globals`) and route alias refs through a single new helper
`_resolve_value_safely(ref)` which (a) uses `LLVMGetValueKind` to probe
the kind, (b) for `LLVMGlobalAliasValueKind` calls `LLVMAliasGetAliasee`
once to resolve the target, (c) recurses with a tiny depth cap (8) to
handle alias-of-alias chains, (d) if the terminal aliasee is a
GlobalVariable / Function we produce a normal wrapper, (e) otherwise
returns an `__opaque_ptr__` sentinel IROperand. **Rationale over
alternatives**: pure "try/catch and swallow" (the current cc0.7 style)
leaves `_operand` crashing whenever a GlobalAlias survives
`_any_vector_operand`'s early bail-out — which is exactly what happens in
TJ1's `store ptr @"jl_global#139.jit", ptr %0` (no vectors, plain scalar
store). Emitting a "ConstantPtr(aliasee_name)" IR type would cost a new
lowering handler and buy nothing because lower.jl can't do anything with
the aliasee either. The sentinel approach matches the precedent set by
`__poison_lane__` (cc0.7), `__zero_agg__` (sret), and `__unreachable__`
(dead-code branches): a fail-loud marker that costs nothing when the
operand isn't consumed and gives a clean error when it is.

## §2 — cc0.5 strategy (one paragraph)

cc0.5 is different: extraction succeeds, lowering fails. The `thread_ptr`
→ GEP → load → GEP → load → `@ijl_gc_small_alloc` chain is a **Julia GC
allocation protocol**, fully deterministic and recognisable by shape. The
strategy is **pattern-recognition at extraction time**: detect the TLS
prologue once per function, collapse the entire chain (from the inline-asm
`thread_ptr` call through every `@ijl_gc_small_alloc` call site) into
synthetic **IRAlloca** nodes — one per `gc_small_alloc` call, sized by the
constant `size` argument (the second i32 operand of the call) — and
mark every intermediate instruction (the `thread_ptr` call, the `ptls`
GEPs, the `ptls_load`s, the allocator call itself, plus the GC-frame
slot stores) as **suppressed**. This mirrors exactly the sret pre-walk
architecture (`_collect_sret_writes` + `suppressed::Set{_LLVMRef}`
already in the code — lines 221–342) so there is no new concept to
introduce, only a second pre-walk: `_collect_tls_alloc_writes`. Each
synthesised IRAlloca's `dest` is the LLVMValueRef of the allocator call
(so downstream `store ptr %memory_data, ptr %"new::Array"` resolves to a
name that maps to the alloca's wire array); the alloca's element width
is always 8 (byte-addressed) and its n_elems is the byte-size from the
call's `size` argument. **Rationale over alternatives**: (a) "tag the
`ijl_gc_small_alloc` result" without a pre-walk would still leave the
`thread_ptr` / `ptls_field` GEPs as raw instructions that crash lower.jl
— you'd need to suppress them anyway; (b) "emit a clearer
'TLS allocator unsupported' error at lowering" satisfies the bead literal
but defeats its spirit, because the `_pick_alloca_strategy` reachability
target means the bead expects the TJ4 path to actually exercise the
shadow-checkpoint dispatch. Pattern-rewriting to IRAlloca is the minimal
change that gets TJ4 into `_pick_alloca_strategy`.

---

## §3 — Chain analysis

I traced both IR samples by hand. Here's what the post-fix path looks
like for each.

### TJ1 (cc0.3 repro) — line by line

```
1   define i8 @julia_f1_152(i8 signext %"x::Int8")
4   %gcframe1 = alloca [7 x ptr], align 16            — IRAlloca(56, 8)   (CURRENT: crashes on
                                                                           ptr elem ty — lower.jl
                                                                           returns `nothing` via
                                                                           `elem_ty isa LLVM.IntegerType`
                                                                           check on line 1293)
6   %"new::#_growend!…" = alloca [9 x i64]            — IRAlloca(64, 9)
7   %sret_box = alloca [2 x i64]                      — IRAlloca(64, 2)
8   %thread_ptr = call ptr asm "movq %fs:0…"          — cc0.5 scope: SUPPRESSED by
                                                        _collect_tls_alloc_writes
9   %tls_ppgcstack = getelementptr i8, %thread_ptr,-8 — SUPPRESSED (tls chain step)
10  %tls_pgcstack = load ptr, %tls_ppgcstack          — SUPPRESSED
11  store i64 20, ptr %gcframe1                       — STORE to alloca — handled
12  %frame.prev = gep ptr, %gcframe1, 1               — IRPtrOffset (known base)
13  %task.gcstack = load ptr, %tls_pgcstack            — SUPPRESSED (tls load)
14  store ptr %task.gcstack, ptr %frame.prev          — NEEDS DECISION — see below
15  store ptr %gcframe1, ptr %tls_pgcstack            — SUPPRESSED (tls write)
16  %memory_data = load ptr, ptr (gep (ptr @"jl_global#154.jit", 1))
                                                     — cc0.3 scope: constant-expression GEP with
                                                       GlobalAlias base. Decision: ptr-typed load
                                                       returns nothing (lower.jl line 1131 already
                                                       rejects non-IntegerType loads). The operand
                                                       never becomes an IR node.
17  %ptls_field = gep i8, %tls_pgcstack, 16           — SUPPRESSED
18  %ptls_load = load ptr, %ptls_field                — SUPPRESSED
19  %"new::Array" = call @ijl_gc_small_alloc(%ptls_load, 408, 32, …)
                                                     — cc0.5 scope: IRAlloca(8, 32)
                                                       (32-byte allocation)
20  %tag_addr = gep i64, %"new::Array", -1            — negative offset into alloca
                                                       → IRPtrOffset(-8). Currently lower.jl's
                                                       lower_ptr_offset! multiplies offset_bytes by 8
                                                       (line 1528) to get bit_offset and slices as
                                                       `base_wires[(bit_offset+1):end]` which for
                                                       negative offset will fail Julia bounds-check
                                                       — see UNCERTAINTY #1
21  store atomic i64 …, %tag_addr                     — IRStore to -1 offset — see UNCERTAINTY #1
22  %0 = gep i8, %"new::Array", 8                     — IRPtrOffset(+8)
23  store ptr %memory_data, ptr %"new::Array"         — IRStore of ptr-typed value: lower.jl line 1278
                                                       already skips non-IntegerType stores via
                                                       `vt isa LLVM.IntegerType || return nothing`.
24  store ptr @"jl_global#154.jit", ptr %0            — cc0.3 scope: store of ALIAS to tracked alloca.
                                                       In the extractor's _operand() the alias op1
                                                       is the stored value; lower.jl line 1278 skips
                                                       it anyway because the alias is ptr-typed.
                                                       BUT _operand crashes BEFORE the skip check.
                                                       Fix: _operand returns opaque-ptr sentinel for
                                                       alias-typed operands. The IRStore is then
                                                       rejected (non-integer value type) and skipped.
                                                       Sentinel never flows anywhere.
25  %size_ptr = gep i8, %"new::Array", 16             — IRPtrOffset(+16)
26  store i64 0, %size_ptr                            — IRStore of i64 0 at offset 16 of alloca
27  %memory_data3 = load ptr, ptr (gep (@"jl_global#154.jit", 1))
                                                     — ptr-typed load, skipped. ConstExpr GEP
                                                       operand must not crash _operand. Fix: _operand
                                                       on constant-expression GEP containing alias
                                                       returns opaque-ptr sentinel.
28  %1 = ptrtoint ptr %memory_data3 to i64            — currently unsupported opcode. After fix:
                                                       %memory_data3 is the opaque sentinel, so
                                                       ptrtoint receives an opaque arg. Decision:
                                                       ptrtoint of sentinel = second opaque sentinel
                                                       i64 → %memoryref_offset is sentinel-tainted.
                                                       See §6 sentinel design.
29  %2 = ptrtoint ptr %memory_data to i64             — same issue, same treatment.
30  %memoryref_offset = sub i64 %2, %1                — binop on two opaque sentinels. Extractor
                                                       emits IRBinOp; sentinels propagate through
                                                       _operand → iconst(0) (zero operand). See §6.
...
34  br i1 %.not, label %L16, label %L129              — reached
60  call void @"j_#_growend!##0_156"(...)             — unknown callee (Julia internal). Current
                                                       _convert_instruction returns nothing for
                                                       unrecognised calls (line 1082). Still OK.
```

**Predicted NEW error for TJ1**: after cc0.3 is in, the extractor produces
a valid ParsedIR but `%memoryref_offset` / `%3` / `%.unbox` carry
sentinel-derived zeros. The `br i1 %.not` then picks the `%L129` branch
(because `0 < 1` is false → `.not = icmp slt %.unbox, %3` is false →
L129). We reach `store i8 %"x::Int8", ptr %memoryref_data17` where
`%memoryref_data17` is a phi of `%memoryref_data.pre` (ptr-load of
alloca slot) and `%memory_data` (opaque sentinel). The phi is
ptr-typed, so the existing cc0-M2b handler applies `width=0 sentinel`
(line 717). The store through a sentinel-origin pointer then fails at
`lower_store!` with `lower_store!: no provenance for ptr` — exactly the
fail-fast behaviour CLAUDE.md §1 wants. The `@test_throws ErrorException`
still passes, with a clearer error about provenance.

**Whether cc0.5 then fires on TJ1**: TJ1's TLS prologue goes
thread_ptr → ppgcstack → pgcstack → (no ptls_field GEP — TJ1 doesn't
allocate through gc_small_alloc, it calls `j_#_growend!` which is an
external Julia runtime function). So there's no `@ijl_gc_small_alloc`
call in TJ1, which means the cc0.5 synthesiser produces zero IRAllocas
for TJ1. The tls-prologue SUPPRESSION (thread_ptr call + 2 GEPs + 2
loads) still runs because we detect the prologue by inline-asm opcode
match. With the prologue suppressed, TJ1's crash location shifts from
extraction-time to lowering-time, and acceptance criterion "cc0.3:
TJ1+TJ2 no longer error at extraction" is satisfied.

### TJ4 (cc0.5 repro) — line by line

```
4   %gcframe1 = alloca [3 x ptr]                      — IRAlloca(8, 24)  (ptr elem ty → byte alloca)
6   %"new::Tuple23" = alloca [1 x i64]                — IRAlloca(64, 1)
7   %thread_ptr = call ptr asm "movq %fs:0…"          — SUPPRESSED
8   %tls_ppgcstack = gep i8, %thread_ptr, -8          — SUPPRESSED
9   %tls_pgcstack = load ptr, %tls_ppgcstack          — SUPPRESSED
10  store i64 4, ptr %gcframe1                        — IRStore to alloca — handled
11  %frame.prev = gep ptr, %gcframe1, 1               — IRPtrOffset
12  %task.gcstack = load ptr, %tls_pgcstack           — SUPPRESSED
13  store ptr %task.gcstack, ptr %frame.prev          — IRStore of ptr-typed value: skipped
14  store ptr %gcframe1, ptr %tls_pgcstack            — SUPPRESSED
15  %ptls_field = gep i8, %tls_pgcstack, 16           — SUPPRESSED
16  %ptls_load = load ptr, %ptls_field                — SUPPRESSED
17  %"Memory{Int8}[]" = call @ijl_gc_small_alloc(%ptls_load, 960, 288, …)
                                                     — cc0.5: IRAlloca(elem_width=8, n_elems=288).
                                                       The synthetic alloca's dest name = the call's
                                                       LLVM SSA name ("Memory{Int8}[]" in this IR).
                                                       ctx.alloca_info[:"Memory{Int8}[]"] = (8, 288).
                                                       ctx.ptr_provenance set with entry predicate.
18  %tag_addr = gep i64, %"Memory{Int8}[]", -1        — see UNCERTAINTY #1 (negative offset)
19  store atomic i64 ..., %tag_addr                   — IRStore at offset -8
20  %memory_ptr = gep {i64, ptr}, %"Memory{Int8}[]", 0, 1
                                                     — struct-index GEP (two indices). lower.jl
                                                       currently only handles single-index GEPs
                                                       (ir_extract.jl line 1090 `length(ops) == 2`).
                                                       Currently returns nothing. OK for TJ4 —
                                                       value unused by bead-relevant computation.
21  %memory_data = gep i8, %"Memory{Int8}[]", 16      — IRPtrOffset(+16) into alloca (provenance
                                                       propagated by lower_ptr_offset!).
22  store ptr %memory_data, %memory_ptr               — ptr store, skipped (non-integer value).
23  store i64 256, ptr %"Memory{Int8}[]"              — IRStore i64 at offset 0 of alloca (length
                                                       field). Handled by existing M2b path
                                                       because ptr_provenance is populated for
                                                       the synthetic alloca.
24  %gc_slot_addr_0 = gep ptr, %gcframe1, 2           — IRPtrOffset
25  store ptr %"Memory{Int8}[]", %gc_slot_addr_0      — ptr store, skipped.
26  %ptls_load34 = load ptr, %ptls_field              — SUPPRESSED (second tls reload)
27  %"new::Array" = call @ijl_gc_small_alloc(%ptls_load34, 408, 32, …)
                                                     — cc0.5: SECOND synthetic IRAlloca(8, 32)
28  %tag_addr = gep …                                 — same tag-addr pattern
29  store atomic i64 ...                              — same
30  %0 = gep i8, %"new::Array", 8                     — IRPtrOffset(+8)
31  store ptr %memory_data, ptr %"new::Array"         — ptr store, skipped
32  store ptr %"Memory{Int8}[]", ptr %0               — ptr store, skipped (aliasee ptr)
33  %size_ptr = gep i8, %"new::Array", 16             — IRPtrOffset(+16)
34  store i64 256, %size_ptr                          — IRStore at offset 16 of "new::Array"
35  %1 = sext i8 %"i::Int8" to i64                    — IRCast sext
36..39  math on i                                     — IRBinOp/IRCast chain
40  %.not = icmp ult i64 %5, 256                      — IRICmp
41  br i1 %.not, label %L71, label %L32               — conditional branch
43..48 L32: bounds-error block, unreachable          — currently routed to __unreachable__ (line 784)
50  L71:
51  %memoryref_data5 = gep i8, %memory_data, %5       — IRVarGEP with dynamic index %5.
                                                       Base %memory_data is the IRPtrOffset result
                                                       from line 21 (offset +16 into alloca
                                                       "Memory{Int8}[]"). Because lower_ptr_offset!
                                                       propagates ptr_provenance via the +16 bump,
                                                       and lower_var_gep! picks up the origin and
                                                       calls ctx.ptr_provenance[inst.dest] =
                                                       new_origins with inst.index = %5 — which
                                                       means _lower_store_via_mux! / _pick_alloca_
                                                       strategy gets called with idx_op.kind == :ssa
                                                       and shape (8, 288).
52  store i8 %"x::Int8", ptr %memoryref_data5         — lower_store! walks to _pick_alloca_strategy
                                                       with shape=(8,288), idx=ssa.
                                                       _pick_alloca_strategy returns :shadow_checkpoint
                                                       because 8*288 = 2304 > 64. ACCEPTANCE CRITERION
                                                       SATISFIED: TJ4 reaches _pick_alloca_strategy.
```

So after the cc0.5 pre-walk, TJ4 lowers through `_pick_alloca_strategy`
and hits either (a) a successful shadow-checkpoint store/load pair, in
which case TJ4 turns from RED to GREEN — which is NOT what the test
asserts (it says `@test_throws`); or (b) a secondary error inside
`_lower_store_via_shadow_checkpoint!` that I can't fully predict without
running the lowering. **Risk**: the test currently expects
ErrorException. If the fix is actually complete enough to GREEN the test,
the existing `@test_throws ErrorException` will FAIL as a false positive.
See §7 on test strategy for the handling of this case — we pre-emptively
update the test to either assert a more specific error or convert to a
GREEN assertion if lowering succeeds. The bead text confirms this is
expected: "Full T5-P6 integration is a separate bead" and "we can change
the error TYPE/MESSAGE but not eliminate it" — but acceptance says TJ4
should *reach* `_pick_alloca_strategy`, which is strictly downstream of
the current extraction error, so any fix that actually passes the
acceptance criterion will alter the eventual error message (and possibly
eliminate it if shadow-checkpoint happens to work end-to-end).

---

## §4 — Per-site handler specification

All fixes in `src/ir_extract.jl`. Seven concrete sites touched.

### Site A — new helper `_is_alias_ref(ref) -> Bool` (new, ~line 1330)

```julia
# Returns true iff `ref` is a GlobalAlias value (LLVMGlobalAliasValueKind == 6).
# Uses the raw C API so we never call LLVM.Value(ref) on an alias-kind ref
# (which would crash `identify` in LLVM.jl 19).
function _is_alias_ref(ref::_LLVMRef)
    ref == C_NULL && return false
    return LLVM.API.LLVMIsAGlobalAlias(ref) != C_NULL
end
```

### Site B — new helper `_resolve_aliasee(ref; depth=8) -> _LLVMRef` (new, ~line 1340)

```julia
# Walk LLVMAliasGetAliasee transitively (LangRef allows alias-of-alias) up
# to `depth` hops. Returns the terminal non-alias ref, or C_NULL if the
# chain exceeds the depth cap (aliases in pathological cycles — shouldn't
# happen in Julia's emitted IR but we guard anyway).
function _resolve_aliasee(ref::_LLVMRef; depth::Int=8)
    for _ in 1:depth
        _is_alias_ref(ref) || return ref
        ref = LLVM.API.LLVMAliasGetAliasee(ref)
        ref == C_NULL && return C_NULL
    end
    return C_NULL   # exhausted depth — treat as opaque
end
```

### Site C — new helper `_opaque_ptr_operand() -> IROperand` (new)

Single shared sentinel, so equality checks in lower.jl can key on it.

```julia
# Sentinel IROperand for any pointer value the extractor cannot materialise
# as a concrete wire reference. This includes:
#   - GlobalAlias with no known integer initializer (Julia type descriptors,
#     dispatch tables, runtime alias chains that terminate in opaque storage)
#   - ConstantExpr GEPs whose base is itself opaque
#   - Terminal Function values (callee of indirect calls)
#
# Consumers in lower.jl must reject this operand with a clear error if they
# actually try to wire it. Most sites skip opaque operands implicitly because
# the surrounding instruction is already "non-integer" (ptr load/store), but
# any path that routes through resolve! / vw will crash fail-loud.
const _OPAQUE_PTR_OPERAND = IROperand(:const, :__opaque_ptr__, 0)
_opaque_ptr_operand() = _OPAQUE_PTR_OPERAND
```

### Site D — `_operand` refactor (line 1666)

Replace the current body:

```julia
function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(convert(Int, val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)
    else
        r = val.ref
        haskey(names, r) || error("Unknown operand ref for: $(string(val))")
        return ssa(names[r])
    end
end
```

with a version that tolerates opaque pointers. The key design point:
`_operand` is called with an already-wrapped `LLVM.Value`, but the
wrapping step itself can crash if the ref is a GlobalAlias (because
`Value(ref)` → `identify` → "Unknown value kind 6"). So we introduce a
sibling `_operand_by_ref` that takes a raw ref and decides whether to
materialise a wrapper:

```julia
# Ref-based entry point: call this when iterating operands via the raw C API
# (e.g. when `LLVM.operands(inst)` fails because some operand is an alias).
# Safe to call on any ref; returns an opaque sentinel for unsupported kinds.
function _operand_by_ref(ref::_LLVMRef, names::Dict{_LLVMRef, Symbol})
    if _is_alias_ref(ref)
        # Try to resolve through the aliasee chain. If the terminal aliasee
        # is a GlobalVariable with an integer initializer, we may get a
        # const-data value we can use. Most Julia aliases resolve to opaque
        # runtime storage — fall through to the sentinel.
        target = _resolve_aliasee(ref)
        if target != C_NULL && !_is_alias_ref(target)
            # Probe the terminal kind; if it's a GlobalVariable we've seen in
            # _extract_const_globals it already lives in parsed.globals and
            # will dispatch via the IRVarGEP path (existing Case B in GEP
            # handling at line 1107). For anything else, opaque.
            k = LLVM.API.LLVMGetValueKind(target)
            if k == LLVM.API.LLVMGlobalVariableValueKind
                # Materialise the aliasee as a normal value wrapper — this
                # is safe because the ref is now non-alias.
                return _operand(LLVM.Value(target), names)
            end
        end
        return _opaque_ptr_operand()
    end
    # Constant-expression handling (ConstantExpr kind = 10). Includes
    # `getelementptr inbounds (ptr, ptr @g, i64 1)`, `ptrtoint @g to i64`,
    # etc. We don't descend into ConstantExprs; the whole expr is opaque
    # unless its ultimate base is a known integer-initializer global.
    k = LLVM.API.LLVMGetValueKind(ref)
    if k == LLVM.API.LLVMConstantExprValueKind
        return _constexpr_operand(ref, names)
    end
    # Happy path: safe to materialise.
    return _operand(LLVM.Value(ref), names)
end
```

And retrofit the existing `_operand`:

```julia
function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(convert(Int, val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)
    elseif val isa LLVM.ConstantExpr
        return _constexpr_operand(val.ref, names)
    elseif val isa LLVM.Function
        # Call-instruction callees: already handled at callsite via LLVM.name;
        # if an operand ever reaches _operand as a Function, it's the target of
        # an indirect call we can't resolve. Opaque.
        return _opaque_ptr_operand()
    elseif val isa LLVM.UndefValue || val isa LLVM.PoisonValue
        return _opaque_ptr_operand()   # matches cc0.7 poison handling
    else
        r = val.ref
        haskey(names, r) || begin
            # Last-resort check: could this be an alias we didn't catch upstream?
            _is_alias_ref(r) && return _opaque_ptr_operand()
            error("Unknown operand ref for: $(string(val))")
        end
        return ssa(names[r])
    end
end
```

Note: `val isa LLVM.ConstantExpr` is a NEW branch — this is the key fix
for the `load ptr getelementptr inbounds (ptr, ptr @"jl_global#139.jit", i64 1)`
case, where the operand IS a constant-expression GEP (not a plain
constant, not an SSA name).

### Site E — `_constexpr_operand` (new helper, ~line 1675)

```julia
# Recognise common ConstantExpr shapes. The only shape we materialise is
# `getelementptr inbounds (ptr, ptr @G, i64 idx)` where @G is a known
# integer-initializer global in parsed.globals — that re-uses the existing
# T1c.2 global-constant dispatch. Everything else becomes opaque.
#
# This keeps the extractor honest: if the ConstantExpr is reading from a
# legitimate constant data table, it flows through the QROM path (already
# implemented). If it's reading from an alias / type descriptor / runtime
# pointer, it becomes opaque and fails loud only at lower time if consumed.
function _constexpr_operand(ref::_LLVMRef, names::Dict{_LLVMRef, Symbol})
    # Retrieve the constexpr's opcode; for GEP we'd dispatch to a global
    # lookup. But: we don't have `globals` in scope here (it's built in
    # _module_to_parsed_ir). So: conservatively return opaque; the actual
    # ConstantExpr-GEP-of-global case is rare enough (Julia's constant
    # tables use plain GlobalVariables, not GEP-of-global constexprs) that
    # we accept the opaque sentinel. An explicit follow-up bead can thread
    # `globals` into _operand if the need arises.
    #
    # N=0 operand (IsNull): materialise as iconst(0) for ptr-null compare.
    if LLVM.API.LLVMIsNull(ref) != 0
        return iconst(0)
    end
    return _opaque_ptr_operand()
end
```

### Site F — `_extract_const_globals` tightening (line 521)

The current try/catch on `LLVM.initializer(g)` works but iterates every
global including aliases. Short-circuit the alias case so we don't even
try:

```julia
function _extract_const_globals(mod::LLVM.Module)
    out = Dict{Symbol, Tuple{Vector{UInt64}, Int}}()
    for g in LLVM.globals(mod)
        # Skip aliases — they have no initializer per LangRef; the alias
        # name maps via LLVMAliasGetAliasee to a (possibly opaque) target.
        _is_alias_ref(g.ref) && continue
        LLVM.isconstant(g) || continue
        init = try LLVM.initializer(g) catch; nothing end
        ...   # rest unchanged
    end
    return out
end
```

Note: `LLVM.globals(mod)` already skips aliases in the LLVM.jl API
(separate `LLVM.aliases(mod)` iterator), but the guard is cheap insurance.

### Site G — `_any_vector_operand` strengthening (line 1335)

Already uses raw-API fallback. Add: when raw-API scan encounters an
alias ref, it's definitely not a vector — `continue` (currently does).
No change needed; the existing code is correct. Just add a comment.

### Site H — name-table pass (line 450)

The "name all instructions" pass already only hits **instructions**, not
operands, so it doesn't encounter GlobalAliases at all. No change needed.

### Site I — `_collect_tls_alloc_writes` (NEW pre-walk, ~line 342)

Modelled on `_collect_sret_writes`. Runs once per function; returns a
`(tls_suppressed::Set{_LLVMRef}, synthetic_allocas::Vector{...})` pair.
Outline:

```julia
# Detect Julia's TLS GC-allocator prologue:
#   %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"()
#   %tls_ppgcstack = getelementptr i8, %thread_ptr, -8
#   %tls_pgcstack = load ptr, %tls_ppgcstack
#   [%ptls_field = getelementptr i8, %tls_pgcstack, 16]   (optional)
#   [%ptls_load  = load ptr, %ptls_field]                 (optional, 1 or more times)
#   %X = call @ijl_gc_small_alloc(%ptls_load, i32 pool, i32 size_bytes, i64 tag)
#
# For each @ijl_gc_small_alloc call with a constant byte-size second-to-last
# i32 operand, synthesise IRAlloca(elem_width=8, n_elems=size_bytes). The
# call's SSA name becomes the alloca's dest.
function _collect_tls_alloc_writes(func::LLVM.Function, names::Dict{_LLVMRef, Symbol})
    suppressed = Set{_LLVMRef}()
    synthetic  = Tuple{_LLVMRef, IRAlloca}[]   # (insert-before-this-ref, IRAlloca)

    # Pass 1: find the thread_ptr (inline asm call) and its transitively-
    # dominated TLS chain instructions. Recognised by exact-match on the asm
    # string "movq %fs:0, $0" (Julia's canonical emission on x86_64) or by
    # the ptr type of an isolated inline-asm call — see UNCERTAINTY #2.

    thread_ptr_ref = C_NULL
    tls_pgcstack_ref = C_NULL
    ptls_field_refs  = Set{_LLVMRef}()  # all gc pointers derived from tls_pgcstack
    ptls_load_refs   = Set{_LLVMRef}()

    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        if LLVM.opcode(inst) == LLVM.API.LLVMCall
            # inline asm check via LLVMIsAInlineAsm on the callee operand
            ops = LLVM.operands(inst)
            !isempty(ops) || continue
            callee = ops[end]
            if _is_inline_asm(callee.ref)
                thread_ptr_ref = inst.ref
                push!(suppressed, inst.ref)
            end
        end
    end
    thread_ptr_ref == C_NULL && return (suppressed, synthetic)

    # Pass 2: GEP from thread_ptr with offset -8 → tls_ppgcstack.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        if LLVM.opcode(inst) == LLVM.API.LLVMGetElementPtr
            ops = LLVM.operands(inst)
            length(ops) == 2 || continue
            ops[1].ref == thread_ptr_ref || continue
            ops[2] isa LLVM.ConstantInt || continue
            convert(Int, ops[2]) == -8 || continue
            push!(suppressed, inst.ref)
            # The subsequent load is tls_pgcstack. Find it.
            for user_bb in LLVM.blocks(func), user_inst in LLVM.instructions(user_bb)
                if LLVM.opcode(user_inst) == LLVM.API.LLVMLoad
                    uops = LLVM.operands(user_inst)
                    !isempty(uops) && uops[1].ref == inst.ref || continue
                    tls_pgcstack_ref = user_inst.ref
                    push!(suppressed, user_inst.ref)
                end
            end
        end
    end

    # Pass 3: every GEP/load derived from tls_pgcstack is a ptls access.
    # Also suppress the `store ptr %task.gcstack, ptr %frame.prev` /
    # `store ptr %gcframe1, ptr %tls_pgcstack` pair that sets up the GC
    # frame — these are ptr-typed stores that lower.jl skips anyway (line
    # 1278), but suppressing them explicitly keeps the IR walk clean.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        opc = LLVM.opcode(inst)
        if opc == LLVM.API.LLVMLoad
            ops = LLVM.operands(inst)
            !isempty(ops) || continue
            if ops[1].ref == tls_pgcstack_ref
                push!(suppressed, inst.ref)          # task.gcstack reload
            end
        elseif opc == LLVM.API.LLVMGetElementPtr
            ops = LLVM.operands(inst)
            length(ops) == 2 || continue
            if ops[1].ref == tls_pgcstack_ref && ops[2] isa LLVM.ConstantInt &&
               convert(Int, ops[2]) == 16
                push!(suppressed, inst.ref)          # ptls_field
                push!(ptls_field_refs, inst.ref)
                # Loads from ptls_field
                for ubb in LLVM.blocks(func), uinst in LLVM.instructions(ubb)
                    if LLVM.opcode(uinst) == LLVM.API.LLVMLoad
                        uops = LLVM.operands(uinst)
                        !isempty(uops) && uops[1].ref == inst.ref || continue
                        push!(suppressed, uinst.ref)
                        push!(ptls_load_refs, uinst.ref)
                    end
                end
            end
        end
    end

    # Pass 4: every call to @ijl_gc_small_alloc / @ijl_gc_alloc_typed /
    # @ijl_gc_pool_alloc / @ijl_gc_big_alloc whose first operand is a ptls
    # ref is synthesised as an IRAlloca.
    const _ALLOC_NAMES = ("ijl_gc_small_alloc", "ijl_gc_alloc_typed",
                          "ijl_gc_pool_alloc", "ijl_gc_big_alloc")
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMCall || continue
        ops = LLVM.operands(inst)
        length(ops) >= 4 || continue
        callee_name = try LLVM.name(ops[end]) catch; "" end
        any(startswith(callee_name, n) for n in _ALLOC_NAMES) || continue
        ops[1].ref in ptls_load_refs || continue
        # ijl_gc_small_alloc signature: (ptls, i32 pool, i32 size_bytes, i64 tag)
        # size_bytes is the third-from-end operand (before the last-pos tag and
        # callee). Adjust per callee signature — see UNCERTAINTY #3.
        size_op = ops[3]   # i32 size_bytes in ijl_gc_small_alloc
        size_op isa LLVM.ConstantInt ||
            error("ijl_gc_small_alloc size must be a compile-time constant; " *
                  "got dynamic size in $(string(inst))")
        size_bytes = convert(Int, size_op)
        dest_sym   = names[inst.ref]
        alloca     = IRAlloca(dest_sym, 8, iconst(size_bytes))
        push!(synthetic, (inst.ref, alloca))
        push!(suppressed, inst.ref)
    end

    return (suppressed, synthetic)
end
```

### Site J — hook into `_module_to_parsed_ir` (line 463)

After the sret pre-walk, before the block conversion loop:

```julia
tls_writes = _collect_tls_alloc_writes(func, names)
# Merge into sret_writes.suppressed if present; else use tls_writes's set.
tls_suppressed = tls_writes[1]
tls_allocas    = Dict{_LLVMRef, IRAlloca}(ref => a for (ref, a) in tls_writes[2])
```

Then in the block walk (line 470), before `_convert_instruction`:

```julia
# cc0.5: suppress TLS/allocator bookkeeping.
if inst.ref in tls_suppressed
    if haskey(tls_allocas, inst.ref)
        push!(insts, tls_allocas[inst.ref])   # substitute synthetic IRAlloca
    end
    continue
end
```

---

## §5 — ConstantExpr GEPs (how cc0.3 IR is actually tolerated)

The specific pattern `load ptr, ptr getelementptr inbounds (ptr, ptr @"jl_global#139.jit", i64 1)`
contains a **ConstantExpr GEP as the pointer operand of a load**. Walking
it:

1. `_convert_instruction` sees `LLVMLoad` opcode. `ops[1]` is the
   ConstantExpr ref.
2. Current line 1129 does `haskey(names, ptr.ref)` → false (the
   ConstantExpr has no name-table entry because it's not a plain
   instruction — the first-pass loop only names `LLVM.instructions(bb)`).
3. The load falls through to `return nothing` (line 1135) — already
   the correct behaviour, so the load produces no IR inst.
4. BUT: `LLVM.operands(inst)` iterates operands lazily, and the
   ConstantExpr-GEP's own operands contain the GlobalAlias. The iterator
   crashes in cc0.7's `_any_vector_operand` raw-API fallback (line 1345,
   `LLVM.Value(ref)`), which triggers the outer try/catch and returns
   `false` — then control returns to the main path, which again calls
   `LLVM.operands(inst)` at line 1127 for the load... wait.

Actually the ORIGINAL cc0.3 crash isn't here. Let me re-trace.

Re-examining: `ops = LLVM.operands(inst)` on the LOAD instruction returns
an Array of `LLVM.Value`s — which triggers `LLVM.Value(ref)` on the
ConstantExpr's ref, not on the GlobalAlias inside it. ConstantExpr kind
is 10, which is supported by LLVM.jl (`@checked struct ConstantExpr`
registered at kind 10). **The ConstantExpr ref does not crash.** Good.

So `ops[1]` on the load is a `LLVM.ConstantExpr`. The `haskey(names,
ptr.ref)` on line 1129 returns false. `return nothing`. **This load
instruction is already extraction-safe!**

The actual cc0.3 crash site is line 23 of the IR: `store ptr
@"jl_global#154.jit", ptr %0`. Here `ops[1]` (the stored value) IS the
GlobalAlias directly — not wrapped in a ConstantExpr. `LLVM.operands(inst)`
iterates and calls `LLVM.Value(alias_ref)`, which crashes in `identify`
with "Unknown value kind 6".

**So the constant-expression GEP case doesn't actually need special
handling** — the load is already skipped because `names` doesn't know the
ConstantExpr ref. What DOES need handling:

- **Direct alias as operand** (cc0.3 line 24, line 32): alias is `ops[1]`
  of a store / `ops[0]` of a load. `LLVM.operands(inst)` crashes at
  iteration time.
- **Alias nested inside a ConstantExpr** (cc0.3 line 16, line 27): only
  shows up when some future code actually descends INTO the ConstantExpr.
  Today nothing does. Safe.

**Fix for the direct-operand case**: can't use `LLVM.operands(inst)`
iterator because it eagerly wraps. Must use the raw-API approach already
prototyped in `_any_vector_operand` — index-based `LLVMGetOperand` then
gate via `_is_alias_ref` BEFORE attempting `LLVM.Value(ref)`. Wrap the
whole store/load operand fetch in `_operands_safe`:

```julia
# cc0.3-aware operand fetcher: returns a Vector{Union{LLVM.Value, _LLVMRef}}
# where raw _LLVMRef entries flag operands that couldn't be materialised
# (GlobalAlias, unsupported value kinds). Callers handle these via
# _operand_by_ref.
function _operands_safe(inst::LLVM.Instruction)::Vector{Any}
    n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
    out = Vector{Any}(undef, n)
    for i in 0:(n - 1)
        ref = LLVM.API.LLVMGetOperand(inst.ref, i)
        if _is_alias_ref(ref)
            out[i + 1] = ref            # raw ref; consumer uses _operand_by_ref
        else
            try
                out[i + 1] = LLVM.Value(ref)
            catch
                out[i + 1] = ref        # unwrappable kind; also raw
            end
        end
    end
    return out
end
```

This replaces `LLVM.operands(inst)` at the specific call sites that
touch potentially-alias-bearing operands: **LLVMStore** (line 1273),
**LLVMLoad** (line 1126), **call operand iteration for IRCall** (line
1069), and the **GEP handling** at line 1087. Everywhere else, keep the
existing `LLVM.operands(inst)` — binops/icmps/selects/phis don't receive
aliases directly (they receive integer values), so the existing code
works. **List of sites that change**:

1. Line 1127 (`ops = LLVM.operands(inst)` for load) → `_operands_safe(inst)`
2. Line 1274 (store) → `_operands_safe(inst)`
3. Line 789 (call) → `_operands_safe(inst)`
4. Line 1087 (GEP) → `_operands_safe(inst)`

At each of these, when an operand is a raw `_LLVMRef`, skip the
instruction (for load/store — they were already skipping non-integer
types anyway) or dispatch through `_operand_by_ref` (for call args that
might be the target callee name).

This is **minimally invasive**: four `LLVM.operands(inst)` call sites
change to `_operands_safe(inst)`. Everywhere else is unchanged.

**Consolidation with cc0.7's `_any_vector_operand`**: the raw-API scan
in `_any_vector_operand` already handles alias-ref iteration failure.
Keep it; it's the pre-dispatcher. The changes above only touch the
main scalar-handler paths.

---

## §6 — Sentinel design

`IROperand(:const, :__opaque_ptr__, 0)` is the single sentinel for "this
pointer value is opaque to the extractor." Its `value=0` doubles as a
conservative numeric coercion (so when a sentinel flows through `ptrtoint
→ i64 → sub → icmp slt`, it produces a constant-zero chain that doesn't
trip lowering until someone actually stores through the sentinel). The
name prefix `__opaque_` mirrors the existing convention
(`__poison_lane__`, `__zero_agg__`, `__unreachable__`).

**Propagation rules** (enforced in `_operand` by the `:const` kind check —
no lowering changes):

- `_operand` returning sentinel → subsequent IRBinOp with it produces a
  normal IRBinOp where op1 is the sentinel. **Lowering behaviour**:
  `resolve!` is called on `__opaque_ptr__` in lower.jl. Resolving a
  `:const` operand currently looks up by `.value` and wires up a
  constant-value register. **Zero is a valid constant**, so the sentinel
  silently becomes a zero wire in arithmetic contexts. The bug hazard
  here is "silent miscompile via zero coercion." Mitigation: add a
  fail-loud check in `resolve!` that refuses `:const` operands whose
  `name === :__opaque_ptr__`. That's a one-line defensive change in
  lower.jl — violates §9's "zero touches to lower.jl preferred" but
  **necessary** to honour CLAUDE.md §1 (fail fast). **This is the one
  lower.jl change I justify below in §9.**

- `_operand` returning sentinel for a **pointer-typed value** never
  reaches `resolve!` because the consuming instruction is already
  ptr-typed (load/store of ptr) and gets skipped via the
  `vt isa LLVM.IntegerType || return nothing` guards (lines 1131, 1278).

**Why not a new IR type?** A new IR node (e.g. `IROpaque`) would need:
(a) a lowering handler, (b) pattern-matching in every upstream
consumer, (c) invalidation tests. The sentinel operand reuses the
existing `:const` kind dispatch and adds one guard. Simpler, fewer
moving parts, same correctness guarantee.

**Cross-referenced precedent**: cc0.7's `__poison_lane__` is the exact
same mechanism at lane granularity. m2b's `PtrOrigin(entry_predicate)`
uses a similar "trivially-safe marker that upgrades to fail-loud if
actually consumed" pattern.

---

## §7 — Test strategy

### Keep the existing `@test_throws ErrorException` passing

The bead text is explicit: "existing tests use `@test_throws
ErrorException ...` so any ErrorException satisfies the test." Our fix
doesn't eliminate errors on TJ1/TJ2/TJ4 — it shifts them downstream.

For **TJ1 / TJ2**: after cc0.3, extraction completes. Lowering then hits
`lower_store!: no provenance for ptr` or similar. Still an
ErrorException. `@test_throws` green.

For **TJ4**: after cc0.3 + cc0.5, extraction completes and lowering
reaches `_pick_alloca_strategy` which dispatches to `:shadow_checkpoint`.
One of three outcomes:

1. **Shadow-checkpoint succeeds end-to-end**: TJ4 compiles. The
   existing `@test_throws ErrorException` becomes a false failure. We
   must update the test to assert success (invert the throws into a
   compile + simulate + verify_reversibility triple).
2. **Shadow-checkpoint errors out downstream** (e.g. on the
   `gcframe1`/ptr-typed alloca-of-ptrs that's NOT `elem_ty isa
   LLVM.IntegerType`): lower.jl already returns nothing from
   IRAlloca on ptr elem types, but the synthesised IRAlloca uses
   elem_width=8 so it'll lower fine. Then the actual error appears in
   IRStore with ptr value — already skipped by line 1278. So the
   first REAL error in TJ4 post-fix is likely a bounds / width
   mismatch inside the shadow-checkpoint path. Still ErrorException.
   `@test_throws` passes.
3. **Shadow-checkpoint emits incorrect-but-runnable gates**: fails
   `verify_reversibility`. Not applicable because TJ4 uses `@test_throws`
   — we never run verify.

The safe approach is to **strengthen the existing test to a message
match** so we don't accidentally accept the wrong error:

```julia
# Before:
@test_throws ErrorException reversible_compile(f_tj1, Int8)
# After (only if message is stable):
@test_throws "store must target an alloca" reversible_compile(f_tj1, Int8)
```

But per the bead text: "we can change the error TYPE/MESSAGE" —
changing to a specific substring-match is permissible. **Do NOT** do
this as part of cc0.3/cc0.5 itself because the message depends on which
lower-level error path fires, and that's fragile against future work.
**Recommended**: leave `@test_throws ErrorException` as-is, add ONE new
informational test per bead that asserts the NEW error message is
informative:

```julia
@testset "cc0.3: TJ1 extraction no longer crashes on alias" begin
    f_tj1(x::Int8) = let v = Int8[]; push!(v,x); reduce(+,v) end
    # extraction must succeed (ParsedIR returns without error)
    parsed = Bennett.extract_parsed_ir(f_tj1, Tuple{Int8}; optimize=true)
    @test parsed isa Bennett.ParsedIR
    # lowering may still fail — that's a downstream bead
    @test_throws ErrorException reversible_compile(f_tj1, Int8)
end

@testset "cc0.5: TJ4 reaches _pick_alloca_strategy" begin
    f_tj4(x::Int8, i::Int8) = let a = Array{Int8}(undef, 256)
        a[mod(i,256)+1] = x
        a[mod(i,256)+1]
    end
    parsed = Bennett.extract_parsed_ir(f_tj4, Tuple{Int8,Int8}; optimize=true)
    # Must contain at least one synthesised IRAlloca from gc_small_alloc
    @test any(b -> any(i -> i isa Bennett.IRAlloca, b.instructions), parsed.blocks)
    # The error, if any, must not be the thread_ptr error
    err = try reversible_compile(f_tj4, Int8, Int8); nothing
          catch e; e end
    if err !== nothing
        @test !occursin("thread_ptr", sprint(showerror, err))
        @test !occursin("GlobalAlias", sprint(showerror, err))
    end
end
```

This lets both the acceptance criterion and the literal test corpus
agree.

### Micro-tests for new helpers

Add `test/test_cc03_05_helpers.jl`:

- `_is_alias_ref(C_NULL) == false`
- `_is_alias_ref(int_const_ref) == false`
- `_is_alias_ref(alias_ref) == true` (construct via `LLVM.Alias`)
- `_resolve_aliasee` on 3-deep chain → terminal
- `_resolve_aliasee` on cycle (if constructible) → C_NULL
- `_operand_by_ref` on alias → opaque sentinel
- `_operand_by_ref` on constant-expr GEP of global → opaque (or iconst if we
  later thread globals through)
- `_collect_tls_alloc_writes` on synthetic IR with thread_ptr pattern →
  emits expected suppressed set + one IRAlloca per gc_small_alloc call

### Regression (CLAUDE.md §6)

Run the full test suite and spot-check gate counts on:
- `test_increment.jl` (i8 add = 86 gates)
- `test_polynomial.jl`
- `test_int16.jl / test_int32.jl / test_int64.jl` (174/350/702)
- `test_softfloat.jl`

None of these touch GlobalAliases or gc_small_alloc, so counts must be
byte-identical pre/post.

---

## §8 — Concrete diff sketch (~180 lines)

```diff
--- a/src/ir_extract.jl
+++ b/src/ir_extract.jl
@@ -341,6 +341,7 @@ end
     return (slot_values = slot_values, suppressed = suppressed)
 end

+include_str = raw"""
 """
     _synthesize_sret_chain(sret_info, slot_values, counter) -> (Vector{IRInst}, IRRet)

@@ -458,6 +459,20 @@ function _module_to_parsed_ir(mod::LLVM.Module)
     sret_writes = sret_info === nothing ? nothing :
                   _collect_sret_writes(func, sret_info, names)

+    # Bennett-cc0.5: detect Julia's TLS GC-allocator prologue and synthesise
+    # IRAlloca nodes for every @ijl_gc_small_alloc call. Suppresses the
+    # thread_ptr inline-asm call, the tls_ppgcstack/tls_pgcstack GEPs and
+    # loads, the ptls_field GEPs, and the gc_small_alloc calls themselves —
+    # instead emitting one IRAlloca per allocator call, sized from the
+    # constant byte-size argument. Runs after `names` is populated so the
+    # synthetic IRAlloca can use the call's SSA name as dest.
+    tls_writes = _collect_tls_alloc_writes(func, names)
+    tls_suppressed = tls_writes[1]
+    tls_allocas    = Dict{_LLVMRef, IRAlloca}()
+    for (ref, a) in tls_writes[2]
+        tls_allocas[ref] = a
+    end
+
     # Convert blocks (second pass)
     blocks = IRBasicBlock[]
     for bb in LLVM.blocks(func)
@@ -472,6 +487,14 @@ function _module_to_parsed_ir(mod::LLVM.Module)
             if sret_writes !== nothing && inst.ref in sret_writes.suppressed
                 continue
             end
+            # cc0.5 hook: substitute synthetic IRAlloca, or skip if just
+            # suppressed (thread_ptr / tls_ppgcstack / tls_pgcstack / ptls_*).
+            if inst.ref in tls_suppressed
+                if haskey(tls_allocas, inst.ref)
+                    push!(insts, tls_allocas[inst.ref])
+                end
+                continue
+            end
             # sret hook: at `ret void`, emit the synthetic IRInsertValue chain
             if sret_writes !== nothing &&
                LLVM.opcode(inst) == LLVM.API.LLVMRet &&
@@ -521,6 +544,9 @@ function _extract_const_globals(mod::LLVM.Module)
     out = Dict{Symbol, Tuple{Vector{UInt64}, Int}}()
     for g in LLVM.globals(mod)
+        # cc0.3: defensively skip aliases — LLVM.globals shouldn't yield them,
+        # but belt-and-braces against future LLVM.jl changes.
+        _is_alias_ref(g.ref) && continue
         LLVM.isconstant(g) || continue
         init = try LLVM.initializer(g) catch; nothing end
         init === nothing && continue
@@ -786,7 +812,7 @@ function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Sym
     if opc == LLVM.API.LLVMCall
-        ops = LLVM.operands(inst)
+        ops = _operands_safe(inst)
         n_ops = length(ops)
         if n_ops >= 1
-            cname = try LLVM.name(ops[n_ops]) catch; "" end
+            cname = _safe_operand_name(ops[n_ops])
@@ -1084,7 +1110,7 @@ function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Sym
     # GEP with constant or variable offset
     if opc == LLVM.API.LLVMGetElementPtr
-        ops = LLVM.operands(inst)
+        ops = _operands_safe(inst)
         base = ops[1]
+        base isa LLVM.Value || return nothing    # cc0.3: alias base → skip
         # Case A: base is a local SSA value that we've already named
@@ -1124,7 +1150,7 @@ function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Sym
     # Load from pointer → IRLoad (CNOT-copy from wire subset)
     if opc == LLVM.API.LLVMLoad
-        ops = LLVM.operands(inst)
+        ops = _operands_safe(inst)
         ptr = ops[1]
+        ptr isa LLVM.Value || return nothing     # cc0.3: alias ptr → skip
         if haskey(names, ptr.ref)
@@ -1272,7 +1300,7 @@ function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Sym
     # store: `store ty val, ptr p` -> IRStore (no dest — void in LLVM).
     if opc == LLVM.API.LLVMStore
-        ops = LLVM.operands(inst)
+        ops = _operands_safe(inst)
         val = ops[1]
         ptr = ops[2]
+        (val isa LLVM.Value && ptr isa LLVM.Value) || return nothing
         vt = LLVM.value_type(val)
@@ -1664,6 +1692,78 @@ function _get_deref_bytes(func::LLVM.Function, param::LLVM.Argument)
     return 0
 end

+# ===== Bennett-cc0.3: GlobalAlias tolerance =====
+
+"""Returns true iff `ref` is a GlobalAlias value (kind 6 in LLVM.jl 19)."""
+function _is_alias_ref(ref::_LLVMRef)
+    ref == C_NULL && return false
+    return LLVM.API.LLVMIsAGlobalAlias(ref) != C_NULL
+end
+
+"""Walk alias chains to terminal aliasee; returns C_NULL if depth exceeded."""
+function _resolve_aliasee(ref::_LLVMRef; depth::Int=8)
+    for _ in 1:depth
+        _is_alias_ref(ref) || return ref
+        ref = LLVM.API.LLVMAliasGetAliasee(ref)
+        ref == C_NULL && return C_NULL
+    end
+    return C_NULL
+end
+
+const _OPAQUE_PTR_OPERAND = IROperand(:const, :__opaque_ptr__, 0)
+_opaque_ptr_operand() = _OPAQUE_PTR_OPERAND
+
+"""Fetch operands as Vector{Any} where raw _LLVMRef entries flag
+unwrappable values (GlobalAlias, other unknown kinds). Callers check
+`x isa LLVM.Value` and skip or route to _operand_by_ref."""
+function _operands_safe(inst::LLVM.Instruction)::Vector{Any}
+    n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
+    out = Vector{Any}(undef, n)
+    for i in 0:(n - 1)
+        ref = LLVM.API.LLVMGetOperand(inst.ref, i)
+        if _is_alias_ref(ref)
+            out[i + 1] = ref
+        else
+            try
+                out[i + 1] = LLVM.Value(ref)
+            catch
+                out[i + 1] = ref
+            end
+        end
+    end
+    return out
+end
+
+"""Safely extract the LLVM name of a possibly-raw operand."""
+_safe_operand_name(v::LLVM.Value) = try LLVM.name(v) catch; "" end
+_safe_operand_name(::_LLVMRef)    = ""
+
+# ===== Bennett-cc0.5: TLS-allocator pattern recognition =====
+
+function _is_inline_asm(ref::_LLVMRef)
+    ref == C_NULL && return false
+    return LLVM.API.LLVMIsAInlineAsm(ref) != C_NULL
+end
+
+"""Pre-walk the function body looking for Julia's TLS GC allocator prologue.
+Returns `(suppressed, synthetic)` where `suppressed::Set{_LLVMRef}` is the
+set of refs to skip during the main walk, and `synthetic::Vector{Tuple{
+_LLVMRef, IRAlloca}}` is the list of IRAllocas to emit in place of the
+suppressed `@ijl_gc_small_alloc` calls.
+
+Recognised protocol (exact Julia emission on x86_64):
+  %thread_ptr   = call ptr asm "movq %fs:0, \$0", "=r"()
+  %tls_ppgcstack = getelementptr i8, %thread_ptr, -8
+  %tls_pgcstack  = load ptr, %tls_ppgcstack
+  %ptls_field    = getelementptr i8, %tls_pgcstack, 16    [optional]
+  %ptls_loadN    = load ptr, %ptls_field                  [0..n times]
+  %X = call @ijl_gc_small_alloc(%ptls_loadN, i32 pool, i32 size, i64 tag)
+
+See `/tmp/cc03_05/tj1_ir.ll` (no alloc calls) and `/tmp/cc03_05/tj4_ir.ll`
+(two alloc calls) for concrete examples."""
+function _collect_tls_alloc_writes(func::LLVM.Function,
+                                   names::Dict{_LLVMRef, Symbol})
+    # [full body as sketched in §4 site I]
+end
+
 function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
     if val isa LLVM.ConstantInt
         return iconst(convert(Int, val))
     elseif val isa LLVM.ConstantAggregateZero
         return IROperand(:const, :__zero_agg__, 0)
+    elseif val isa LLVM.ConstantExpr
+        return _constexpr_operand(val.ref, names)
+    elseif val isa LLVM.Function
+        return _opaque_ptr_operand()
+    elseif val isa LLVM.UndefValue || val isa LLVM.PoisonValue
+        return _opaque_ptr_operand()
     else
         r = val.ref
-        haskey(names, r) || error("Unknown operand ref for: $(string(val))")
+        if !haskey(names, r)
+            _is_alias_ref(r) && return _opaque_ptr_operand()
+            error("Unknown operand ref for: $(string(val))")
+        end
         return ssa(names[r])
     end
 end

+function _operand_by_ref(ref::_LLVMRef, names::Dict{_LLVMRef, Symbol})
+    if _is_alias_ref(ref)
+        target = _resolve_aliasee(ref)
+        if target != C_NULL && !_is_alias_ref(target)
+            k = LLVM.API.LLVMGetValueKind(target)
+            k == LLVM.API.LLVMGlobalVariableValueKind &&
+                return _operand(LLVM.Value(target), names)
+        end
+        return _opaque_ptr_operand()
+    end
+    k = LLVM.API.LLVMGetValueKind(ref)
+    k == LLVM.API.LLVMConstantExprValueKind &&
+        return _constexpr_operand(ref, names)
+    return _operand(LLVM.Value(ref), names)
+end
+
+function _constexpr_operand(ref::_LLVMRef, names::Dict{_LLVMRef, Symbol})
+    if LLVM.API.LLVMIsNull(ref) != 0
+        return iconst(0)
+    end
+    return _opaque_ptr_operand()
+end
+
 function _iwidth(val)
     tp = LLVM.value_type(val)
     _type_width(tp)
```

Diff size: ~180 LOC added (helpers + pre-walk body), ~20 LOC modified
(4 `LLVM.operands(inst)` → `_operands_safe(inst)` + guards). Zero
removed.

---

## §9 — Interaction with lower.jl

**One required change** (justified by §6's fail-loud requirement):

In `resolve!` (lower.jl — need to locate the `:const` dispatch), insert
a check that `op.name !== :__opaque_ptr__` before treating the operand
as a zero constant. One-line guard:

```julia
op.kind == :const && op.name === :__opaque_ptr__ &&
    error("resolve!: cannot wire opaque pointer operand (from GlobalAlias " *
          "or unsupported LLVM ConstantExpr). This operand reached a context " *
          "that requires a concrete integer value. File a bd issue if this " *
          "is a pattern Bennett should support.")
```

This avoids the silent-zero-coercion miscompile hazard. It's the only
lower.jl touch, it's monotonic (only emits errors that would otherwise
be silent wrong-answers), and it doesn't affect any GREEN test because
no GREEN test currently produces `:__opaque_ptr__` operands.

Similarly `lower_store!` and `lower_load!` should defensively reject
`__opaque_ptr__` pointers — but these are already handled because the
store/load extraction skips ptr-typed values before emitting an IRStore,
so an opaque pointer never reaches lower_{store,load}! as `inst.ptr`.
No additional changes needed there.

**Zero other touches.**

---

## §10 — Out of scope

Explicit non-goals of this bead pair:

1. **Making TJ1/TJ2 GREEN end-to-end.** Those require T5-P6 (persistent
   DS lowering) or a working Vector/Dict model in lower.jl. The
   extractor fix here gets them past extraction only.
2. **Making TJ4 GREEN end-to-end.** The shadow-checkpoint path for
   N=288, W=8 may or may not already work. If it does — great, we
   update the test. If it doesn't, that's a separate bead
   (downstream of the shadow-checkpoint implementation).
3. **TJ3's constant-ptr icmp eq.** The `icmp eq (ptr @A, ptr @B)` case
   with two GlobalAliases is a different error path ("Unknown operand
   ref for: i1 icmp eq (ptr @A, ptr @B)"). Under our fix, both operands
   become opaque-ptr sentinels; the icmp then becomes
   `IRICmp(:eq, __opaque_ptr__, __opaque_ptr__, w)` which is ill-defined
   semantically (comparing two sentinels is not true or false). I
   recommend a **follow-up bead** to either: (a) resolve the alias
   chain and if both aliasees are distinct named globals,
   constant-fold to `iconst(0)`; or (b) leave it as opaque and let
   lower.jl fail loud. Not in scope here.
4. **Dynamic gc_small_alloc sizes.** Julia emits constant sizes for
   allocation of statically-sized Arrays and Memories. If a dynamic
   size appears, we fail loud (see §4 Site I). Supporting it requires
   deriving N from a ptr-to-integer conversion chain — a harder
   bead.
5. **Inline-asm opcode matching.** We match `_is_inline_asm(callee)`
   without inspecting the asm string. This accepts any inline asm as
   "thread_ptr" — a false positive would only occur if the function
   has non-TLS inline asm that also produces a pointer used in a
   `-8 offset GEP`, which is unheard of in Julia-emitted IR. Documented
   as a known-acceptable precision tradeoff.
6. **Other GC alloc callees.** `ijl_gc_big_alloc`,
   `ijl_gc_alloc_typed`, `ijl_gc_pool_alloc` are listed in Site I but
   only `ijl_gc_small_alloc` is exercised by TJ4. The others are
   added defensively with TODO comments; their first-real-use will
   reveal any signature differences.
7. **Pre-alloca instructions in other blocks.** Our `_collect_tls_alloc_writes`
   scans the whole function, not just the entry block. The prologue
   happens in the entry block per Julia's convention, but if a future
   Julia version emits a second `thread_ptr` call in a middle block we
   still catch it. No scope limitation needed.
8. **Cross-call alias flow.** If function A returns an opaque sentinel
   and function B consumes it — today `reversible_compile` doesn't
   inline across boundaries except through IRCall, and IRCall takes
   integer args only. Opaque ptrs never cross an IRCall boundary. Safe.

---

## Synthesis paragraph

Both beads share a root cause: the extractor assumed every LLVM value it
sees is something it can either wire or fail-on. cc0.3 violates that on
the **alias-wrapping** step; cc0.5 violates it on the **semantic
matching** of Julia's runtime allocator protocol. Proposer B fixes both
in `src/ir_extract.jl` with two mechanisms: an **opaque-pointer sentinel
operand** (for cc0.3) that tolerates GlobalAlias refs without crashing
and flows through the IR walker as a typed marker lower.jl can reject
loudly, and a **TLS-allocator pre-walk** (for cc0.5) that recognises the
`thread_ptr → tls_pgcstack → ptls → ijl_gc_small_alloc` chain, suppresses
every step, and emits synthetic IRAlloca nodes for each allocator call
sized by its constant byte argument. The pre-walk architecture mirrors
the existing `_collect_sret_writes`/`suppressed` pattern one-for-one,
minimising cognitive overhead for reviewers. Four call sites move from
`LLVM.operands(inst)` to a new `_operands_safe` helper that gates
GlobalAlias iteration behind the raw C API. The only lower.jl touch is
one defensive guard in `resolve!` (§9) to prevent silent zero-coercion
miscompiles when an opaque sentinel accidentally reaches arithmetic —
an additive safety check that cannot regress any currently-GREEN test.
Net change: ~180 LOC added to `ir_extract.jl`, ~5 LOC added to
`lower.jl`, zero lines removed. Acceptance: TJ1/TJ2 extract cleanly
(then fail at provenance), TJ4 reaches `_pick_alloca_strategy` via the
synthesised IRAlloca + ptr_provenance chain.

---

## Uncertainty items for orchestrator review

1. **Negative-offset GEPs** (lines 20 and 28 of TJ4 IR:
   `gep i64, %"new::Array", -1`). The tag_addr pattern points to
   byte-offset −8 from the alloca start — *before* the tracked wire
   range. Julia uses the -8 slot for the object tag that the GC reads;
   it's never part of the user-visible array. `lower_ptr_offset!` at
   line 1528 computes `bit_offset = -1 * 8 = -8` and slices
   `base_wires[-7:end]` which would error (Julia 1-based indexing, out
   of range). **Unknown**: whether this currently errors or the negative
   value silently wraps into a bogus slice. I don't know the current
   failure mode because today TJ4 crashes much earlier (thread_ptr).
   **Proposed handling**: either (a) have `_collect_tls_alloc_writes`
   also suppress the tag_addr GEP and its associated store (they're
   bookkeeping the GC never exposes), or (b) let `lower_ptr_offset!`
   reject negative offsets with a clear error. Option (a) is cleaner
   and mirrors sret's GEP-suppression pattern. Recommend (a) but
   needs verification during implementation.

2. **Inline-asm string matching.** `_is_inline_asm(ref)` via
   `LLVMIsAInlineAsm` detects any inline asm, not specifically
   `movq %fs:0, $0`. Julia occasionally emits other inline asm for
   cpu-feature probes or atomics. If a non-TLS asm call's result flows
   into a `-8 offset GEP` we'd misidentify it as a thread_ptr. This
   can't currently happen in plain Julia code, but I don't have a
   strong invariant. **Mitigation option**: also match on the asm
   template string via `LLVM.API.LLVMGetInlineAsmAsmString` — adds
   specificity but is stricter against future Julia codegen changes.
   Low priority because the false-positive consequence is "we incorrectly
   suppress some instruction" which degrades gracefully into lowering
   errors, not silent miscompiles. Orchestrator may want to decide
   whether to tighten this.

3. **ijl_gc_small_alloc argument layout.** I'm reading from TJ4's IR:
   `call @ijl_gc_small_alloc(ptr %ptls_load, i32 408, i32 32, i64 126839824963712)`
   and inferring: op[1]=ptls (suppressed), op[2]=pool_id,
   op[3]=size_bytes, op[4]=type_tag, op[end]=callee (per LLVM's
   convention of placing callee as last operand). My pre-walk takes
   `size_bytes = op[3]`. **Unknown**: whether `ijl_gc_alloc_typed` and
   `ijl_gc_big_alloc` have the same layout. They're mentioned in the
   pre-walk for defensive coverage but only `ijl_gc_small_alloc` is
   exercised by TJ4. Orchestrator should either (a) accept the
   TODO-documented uncertainty and restrict the pre-walk to the three
   names we've verified, or (b) require the implementer to extract IR
   for Array / Dict / Vector cases that use the other callees and
   confirm signatures before accepting their entries in the match set.

4. **Sentinel collision with `:const`-kind dispatch in `resolve!`.**
   The `:__opaque_ptr__` name has value=0. Any code path in lower.jl
   that keys on `op.kind == :const` and uses `op.value` directly would
   interpret it as the integer 0 — silent miscompile. I've proposed
   one defensive check in `resolve!` (§9), but I haven't exhaustively
   audited every `op.kind == :const` use in lower.jl. Risk: a consumer
   I missed silently accepts the sentinel as zero. Mitigation: the
   implementer should grep `op.kind == :const` / `.kind == :const`
   across lower.jl and add the same guard at every site that uses
   `.value` (not just `resolve!`).
