# Proposer A — cc0.4: constant-pointer `icmp eq/ne` in `_operand`

**Milestone**: Bennett-cc0.4 — unblock `optimize=true` extraction for Julia
functions where a field-typed `Union{T,Nothing}` `isnothing(...)` check gets
folded to a static comparison of two runtime type descriptors.

**Failing target**: `test/test_cc04_repro.jl` (the minimal repro written this
session). End-to-end motivating target: `test/test_t5_corpus_julia.jl` TJ3
(three-node linked list traversed via `isnothing(n.next) && isnothing(n.next.next)`).

**Current error**:
```
ErrorException: Unknown operand ref for: i1 icmp eq (ptr @"+Main.TJ3Node#...jit",
                                                      ptr @"+Core.Nothing#...jit")
```
raised from `_operand` (`src/ir_extract.jl:1758`) while the `select` handler
(`src/ir_extract.jl:720`) is walking its i1 condition operand.

**Contract with co-proposer / implementer**: the design must obey §Regression
invariants (§7 below) — gate-count baselines stay byte-identical, every
currently-GREEN test stays GREEN. The decision table (§4) is load-bearing; if
an opcode/operand-kind pair is not explicitly listed, fail loud.

---

## 1. Context

### 1.1 What Julia emits today (post-`optimize=true`)

For the TJ3 source (paraphrased):

```julia
mutable struct TJ3Node{T}
    val::T
    next::Union{TJ3Node{T}, Nothing}
end

function f_tj3(x::Int8)::Int8
    n3 = TJ3Node{Int8}(x + Int8(2), nothing)
    n2 = TJ3Node{Int8}(x + Int8(1), n3)
    n1 = TJ3Node{Int8}(x, n2)
    if !isnothing(n1.next) && !isnothing(n1.next.next)
        n1.next.next.val
    else
        Int8(-1)
    end
end
```

After `optimize=true`, sroa + mem2reg + instcombine + simplifycfg fold the
whole struct-allocation chain away, because every field is a compile-time
constant relative to `x`. The `isnothing` predicate becomes: "does the
runtime *type tag* of the `Union{TJ3Node{Int8}, Nothing}` discriminator at
slot `.next` equal `Nothing`?" Julia models that discriminator as a pointer
to a runtime `jl_typetag_t` object, one per concrete type. So the fold
reduces to a static pointer comparison against `Core.Nothing`'s typetag
pointer — exactly the shape

```llvm
%sel = select i1 icmp eq (ptr @"+Main.TJ3Node#NNN.jit",
                          ptr @"+Core.Nothing#MMM.jit"),
              i8 -1, i8 %rhs
```

These `@"…#NNN.jit"` symbols are runtime-JIT-emitted `GlobalAlias` or
`GlobalVariable` declarations of Julia's datatype descriptors. Under the
common JIT setup they arrive as `GlobalAlias`; under some alternative
codegen paths they are straight `GlobalVariable`s. Either way: two *distinct*
named globals → distinct link-time addresses → `icmp eq` is statically
false, `icmp ne` is statically true.

### 1.2 Where today's code dies

`_operand` at `src/ir_extract.jl:1751-1761`:

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

A `LLVM.ConstantExpr` is none of `ConstantInt`, `ConstantAggregateZero`, nor
a named SSA — it falls through to the final `haskey || error` branch and
crashes. We need a new explicit branch in `_operand` that recognises
ConstantExpr values carrying an integer-result `icmp` opcode and folds them
to an `iconst(0)` / `iconst(1)` i1 literal.

### 1.3 Why this is the *right* intervention site

The bead description says: "extend `_operand`". It's right. Three facts
point at `_operand`:

1. **The crashing call-site is inside `_operand`**, not inside the `select`
   handler. `select` just innocently asks for its three operands; so does
   `icmp`, `phi`, `br`, and every other handler that takes an i1. Patching
   `select` alone would leave the other handlers RED on the same shape.

2. **The result of the constant-folded icmp is `i1` — an integer literal.**
   Once we know the answer, it rides the same codepath as every other i1
   constant: `iconst(0)` or `iconst(1)` flowing through `IRSelect.cond`,
   `IRICmp.op{1,2}`, `IRPhi.incoming`, `IRBranch.cond`. `resolve!` in
   `lower.jl` (lines 168–186) already allocates a 1-wire and runs 0 or 1
   `NOTGate`s for a width-1 constant; no downstream change is required.

3. **Minimum blast radius.** Every operand site funnels through `_operand`.
   One patch covers all of them. Per CLAUDE.md §7 (bugs are deep and
   interlocked), the less of the dispatcher we touch the less risk of
   leakage into scalar codepaths.

I considered three alternatives and rejected each:

| Alternative | Why rejected |
|---|---|
| Add the branch in `_convert_instruction` (above the select handler) | Fails for icmp condition operand, phi incoming operand, br condition operand, ret value, etc. Duplicated logic → CLAUDE.md §12 violation. |
| Route through `_operand_safe` / `_safe_operands` (the cc0.3 sentinel path) | cc0.3's sentinel is for *pointer* operands that flow into memory ops (store/load/GEP base). Here the operand is `i1`, not a pointer. Emitting `OPAQUE_PTR_SENTINEL` into a select's condition would mis-type the operand and the downstream `resolve!` guard (width=1) would crash on a 0-width sentinel. Wrong abstraction. |
| New pass that constant-folds ConstantExprs into ConstantInts before walking | LLVM.jl's `Value` API won't let us mutate the IR in-place; we'd need to materialise fresh ConstantInts. Much larger surface; no win. |

---

## 2. Minimum reproduction

`test/test_cc04_repro.jl` (already written, RED):

```julia
mutable struct CC04Node{T}
    val::T
    next::Union{CC04Node{T}, Nothing}
end

function f_cc04(x::Int8)::Int8
    n3 = CC04Node{Int8}(x + Int8(2), nothing)
    n2 = CC04Node{Int8}(x + Int8(1), n3)
    n1 = CC04Node{Int8}(x, n2)
    if !isnothing(n1.next) && !isnothing(n1.next.next)
        n1.next.next.val
    else
        Int8(-1)
    end
end

c = reversible_compile(f_cc04, Int8)
for x in typemin(Int8):typemax(Int8)
    @test simulate(c, Int8(x)) == (x + Int8(2)) % Int8
end
@test verify_reversibility(c; n_tests=3)
```

The post-`optimize=true` LLVM IR reduces to roughly:

```llvm
define i8 @julia_f_cc04(i8 signext %x) {
top:
  %rhs = add i8 %x, 2
  %sel = select i1 icmp eq (ptr @"+Main.CC04Node#NNN.jit",
                            ptr @"+Core.Nothing#MMM.jit"),
                i8 -1, i8 %rhs
  ret i8 %sel
}
```

The condition operand is a `LLVM.ConstantExpr` whose constant opcode
(`LLVMGetConstOpcode`) is `LLVMICmp`, with `LLVMGetICmpPredicate` returning
`LLVMIntEQ`, and two operands — both pointers, both named globals (one or
both possibly GlobalAlias). Distinct globals → distinct addresses →
`icmp eq` statically false → select picks `i8 %rhs` → return `x + 2`.

---

## 3. API surface

### 3.1 Modified function

```julia
function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})::IROperand
```

Add one branch: `val isa LLVM.ConstantExpr` → dispatch to
`_operand_constexpr`. Everything else unchanged.

### 3.2 New helpers (all file-private, in `src/ir_extract.jl`)

```julia
# Bennett-cc0.4: fold a ConstantExpr into an IROperand.
# Currently handles `icmp eq` / `icmp ne` whose operands are named globals
# (GlobalVariable or GlobalAlias). Every other ConstantExpr shape is
# fail-loud; extend via a new bead when a new shape is observed in IR.
function _operand_constexpr(val::LLVM.ConstantExpr,
                             names::Dict{_LLVMRef, Symbol})::IROperand

# Decide whether two resolved pointer refs denote the same address at link
# time. Returns true iff `a === b` after alias chasing. Returns false iff
# they are both non-null named globals that differ. Returns `nothing` when
# the answer is not statically determinable (NULL, non-global, alias-cycle,
# or anything we don't recognise) — callers must fail loud on `nothing`.
function _ptr_addresses_equal(a::_LLVMRef, b::_LLVMRef)::Union{Bool, Nothing}
```

### 3.3 No other touches

- `ir_types.jl` — unchanged. `iconst(0)` / `iconst(1)` already exist and
  carry no width; width is inferred from consumer context (as today's
  `_operand` does for ConstantInt).
- `lower.jl` — unchanged. `resolve!` handles width-1 constants natively
  (lines 174–185).
- `bennett.jl` / `simulator.jl` / `diagnostics.jl` — unchanged.
- `_safe_operands` / `_operand_safe` / `OPAQUE_PTR_SENTINEL` — unchanged.
  cc0.4 produces proper `iconst` values for integer operands, never the
  opaque sentinel. (cc0.3's sentinel is exclusively for *pointer* operands
  that flow into memory ops.)

---

## 4. Decision table

The ConstantExpr operand space is wide. We explicitly enumerate which shapes
to handle, which to reject fail-loud, and which to defer.

### 4.1 ConstantExpr opcode × operand-kind

| ConstantExpr opcode | Operand kinds | Action |
|---|---|---|
| `LLVMICmp` eq/ne | both pointer operands, each resolves via `_resolve_aliasee` to a GlobalValue (`LLVMFunctionValueKind=5`, `LLVMGlobalVariableValueKind=8`, `LLVMGlobalIFuncValueKind=7`) | **Handle**: fold to `iconst(0)` / `iconst(1)` per §5 below |
| `LLVMICmp` eq/ne | exactly one operand is `LLVMConstantPointerNullValueKind=20` (i.e. `null`), the other is a GlobalValue | **Handle**: named global at link time is never NULL; `eq` → false, `ne` → true. |
| `LLVMICmp` eq/ne | both operands are `LLVMConstantPointerNullValueKind` | **Handle**: both NULL; `eq` → true, `ne` → false. (Unlikely in practice but free to handle.) |
| `LLVMICmp` eq/ne | alias resolution returns `nothing` for either operand (cycle / depth overflow / NULL aliasee) | **Fail loud**: can't fold a comparison whose sides we don't understand. |
| `LLVMICmp` eq/ne | one or both operands is a nested ConstantExpr (e.g. `bitcast`/`addrspacecast` wrapping a global) | **Handle via peel**: §5.3 peels trivial same-address-preserving casts (`bitcast`, `addrspacecast`) and retries. `getelementptr`/`ptrtoint`/`inttoptr` → fail loud (different address semantics). |
| `LLVMICmp` eq/ne | one or both operands is an `LLVMArgument` (i.e. a function parameter — shouldn't be possible inside a ConstantExpr, but guard) | **Fail loud**: non-constant inside a ConstantExpr is malformed IR. |
| `LLVMICmp` eq/ne | integer operands (not pointer) | **Fail loud**: LLVM's `ConstFolder` would have folded this to a `ConstantInt`. If it didn't, the operand is something weird we don't understand. |
| `LLVMICmp` ult/ugt/ule/uge/slt/sgt/sle/sge | any | **Fail loud**: ordering of pointer addresses is not defined for distinct globals at Julia-compile time (allocator is free to interleave). Folding would be unsound. Defer to a later bead if empirically observed. |
| `LLVMBitCast`, `LLVMAddrSpaceCast` wrapping a ConstantInt/GlobalValue | — | **Fail loud for MVP**: these appear as *operands to* other ConstantExprs (§5.3 peel), not as top-level operands of instructions. If they ever hit `_operand` top-level, we'd need to decide whether to fold `bitcast i64 1 to ptr` (unlikely to appear). Defer. |
| `LLVMPtrToInt`, `LLVMIntToPtr` | — | **Fail loud with hint**: "Bennett-cc0.6 territory (ptrtoint/inttoptr handler)". This is a stronger hint for the user to file a follow-up. |
| `LLVMGetElementPtr` | — | **Fail loud**: the GEP computes a pointer that isn't fully resolvable at extraction time (needs GEP-of-global tracking, cc0.3's const-global pre-walk only partially covers this). Defer to cc0.6-scope. |
| `LLVMAdd` / `LLVMSub` / `LLVMMul` / `LLVMAnd` / `LLVMOr` / `LLVMXor` / `LLVMShl` / `LLVMLShr` / `LLVMAShr` on two ConstantInts | — | **Fail loud**: LLVM's ConstFolder should have reduced this at build time. If it didn't, we got a weird input; crash with the raw ConstantExpr stringification. (Empirically 2026-04-20: I have not observed Julia emit these in unfolded form.) |
| `LLVMSelect` with ConstantInt condition | — | **Fail loud**: same as above — should be pre-folded by LLVM. |
| Anything else (LangRef adds new ConstantExpr opcodes) | — | **Fail loud with a clear hint to file a bead**. |

### 4.2 Operand-site × operand-type for the resulting `iconst`

The folded i1 literal flows into whichever instruction originally asked for
the operand. We enumerate each site in `_convert_instruction` to confirm
nothing downstream chokes on an i1 constant from this fold:

| Site | Line(s) | Safe? |
|---|---|---|
| `LLVMSelect` condition (`ops[1]`) | 719–728 | **Yes**: `IRSelect.cond` is `IROperand`; `lower_select!` calls `resolve!(…, cond, 1)` → allocates 1 wire, runs ≤1 NOTGate. |
| `LLVMICmp` operands (`ops[1]`, `ops[2]`) | 711–716 | **Yes**: `IRICmp.op{1,2}` is `IROperand`. `_iwidth(ops[1])` still queries the LLVM operand's type, which is `i1` for a ConstantExpr<icmp> — that's a valid `LLVM.IntegerType(1)` → width=1. |
| `LLVMPHI` incoming value | 731–738 | **Yes**: `IRPhi.incoming[i][1]` is `IROperand`. |
| `LLVMBr` condition | 761–764 | **Yes**: `IRBranch.cond::Union{IROperand, Nothing}`. |
| `LLVMRet` return value | wherever | **Yes** (but unusual to return a folded i1). |
| `LLVMAdd`/... binop operand | 700–708 | **Yes** in principle, but a folded i1 flowing into an i8 add is a type mismatch that instcombine would have already fixed. If encountered, `_iwidth(ops[i])` returns 1, creating an i1 IRBinOp — which lowers fine. |
| `LLVMSelect` true/false value | 719–728 | **Yes**: same mechanism. |

All sites converge on "flows through as a width-aware `iconst`". **No
downstream code needs any change.**

### 4.3 Same-global EQ / NE (corner that matters)

If `_resolve_aliasee(a) == _resolve_aliasee(b)` (same terminal ref), the
operands denote the same address → `eq = true`, `ne = false`. Julia's
optimizer sometimes emits trivially-true `icmp eq` when it wants to keep a
CFG edge for debugging but not actually take it. Handle this case — it's
free once we have the alias-resolution machinery.

### 4.4 GlobalValue subtype sanity

After `_resolve_aliasee` returns a terminal ref, its `LLVMGetValueKind`
should be one of:
- `LLVMFunctionValueKind = 5`
- `LLVMGlobalIFuncValueKind = 7`
- `LLVMGlobalVariableValueKind = 8`
- `LLVMConstantPointerNullValueKind = 20` (only if one operand is literal `null`)

Anything else (e.g. a ConstantExpr, a ConstantPointerNull that came from an
alias chain — weird but theoretically possible) → fail loud with the raw
kind enum value in the message.

---

## 5. Implementation sketch

### 5.1 The patched `_operand`

```julia
function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})::IROperand
    if val isa LLVM.ConstantInt
        return iconst(convert(Int, val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)  # special: zero aggregate
    elseif val isa LLVM.ConstantExpr
        # Bennett-cc0.4: fold statically-decidable ConstantExprs (today:
        # icmp eq/ne on pointer-typed globals) into i1 literals.
        return _operand_constexpr(val, names)
    else
        r = val.ref
        haskey(names, r) || error("Unknown operand ref for: $(string(val))")
        return ssa(names[r])
    end
end
```

Zero churn on the existing three branches. One new branch between
`ConstantAggregateZero` and the named-SSA fall-through. The ordering matters
slightly: `ConstantExpr` must be checked **before** the `haskey(names, r)`
lookup, because a ConstantExpr is not in `names` and would crash on the
existing error.

### 5.2 `_operand_constexpr`

```julia
function _operand_constexpr(val::LLVM.ConstantExpr,
                             names::Dict{_LLVMRef, Symbol})::IROperand
    opc = LLVM.API.LLVMGetConstOpcode(val.ref)

    if opc == LLVM.API.LLVMICmp
        pred = LLVM.API.LLVMGetICmpPredicate(val.ref)
        pred in (LLVM.API.LLVMIntEQ, LLVM.API.LLVMIntNE) ||
            error("Bennett-cc0.4: ConstantExpr<icmp $pred> with ordering " *
                  "predicate is not foldable at extraction time (pointer " *
                  "address ordering is allocator-dependent). Operand: " *
                  "$(string(val)). File a new bead extending cc0.4 if " *
                  "this arises in real code.")

        n = Int(LLVM.API.LLVMGetNumOperands(val.ref))
        n == 2 ||
            error("Bennett-cc0.4: ConstantExpr<icmp> with $n operands " *
                  "(expected 2): $(string(val))")

        a = LLVM.API.LLVMGetOperand(val.ref, 0)
        b = LLVM.API.LLVMGetOperand(val.ref, 1)

        a_peeled = _peel_trivial_ptrcast(a)
        b_peeled = _peel_trivial_ptrcast(b)
        a_peeled === nothing && error(
            "Bennett-cc0.4: ConstantExpr<icmp> lhs operand is a non-trivial " *
            "ConstantExpr (expected GlobalValue, GlobalAlias, null, or a " *
            "bitcast/addrspacecast wrapping one). Operand: $(string(val)). " *
            "File a new bead extending cc0.4.")
        b_peeled === nothing && error(
            "Bennett-cc0.4: ConstantExpr<icmp> rhs operand is a non-trivial " *
            "ConstantExpr (expected GlobalValue, GlobalAlias, null, or a " *
            "bitcast/addrspacecast wrapping one). Operand: $(string(val)). " *
            "File a new bead extending cc0.4.")

        eq = _ptr_addresses_equal(a_peeled, b_peeled)
        eq === nothing && error(
            "Bennett-cc0.4: ConstantExpr<icmp eq/ne> cannot be statically " *
            "decided — one or both operands did not resolve to a GlobalValue " *
            "or null. Operand: $(string(val)). File a new bead extending cc0.4.")

        # eq is Bool. Translate predicate+eq → i1 literal.
        result_true = (pred == LLVM.API.LLVMIntEQ) ? eq : !eq
        return iconst(result_true ? 1 : 0)
    end

    # Other ConstantExpr opcodes.
    if opc == LLVM.API.LLVMPtrToInt || opc == LLVM.API.LLVMIntToPtr
        error("Bennett-cc0.4/cc0.6: ConstantExpr<$(_constexpr_opcode_name(opc))> " *
              "requires ptrtoint/inttoptr handling (cc0.6 scope). Operand: " *
              "$(string(val)).")
    end

    error("Bennett-cc0.4: unhandled ConstantExpr opcode " *
          "$(_constexpr_opcode_name(opc)) in operand position. " *
          "Operand: $(string(val)). File a new bead extending cc0.4 with " *
          "a minimal repro.")
end
```

### 5.3 `_peel_trivial_ptrcast`

LLVM commonly wraps one side of a pointer-equality icmp in an address-
preserving cast (opaque-pointer era mostly eliminates `bitcast ptr to ptr`,
but `addrspacecast` still happens on platforms with multiple address spaces,
and old-style LLVM pre-opaque-ptr IR can still appear via bitcode). Peel
those; retain anything else as "not foldable".

```julia
# Peel trivial address-preserving pointer casts wrapping a GlobalValue / null.
# `bitcast ptr → ptr` and `addrspacecast ptr → ptr` preserve addresses for
# the purposes of Julia-JIT-emitted typetag comparisons. Returns `ref` if
# it's already a leaf (GlobalValue / GlobalAlias / ConstantPointerNull),
# the peeled inner ref if wrapped in one of the two casts, or nothing if
# wrapped in something whose address semantics we don't understand.
function _peel_trivial_ptrcast(ref::_LLVMRef)::Union{_LLVMRef, Nothing}
    ref == C_NULL && return nothing
    cur = ref
    for _ in 1:4   # practical cap; JIT-emitted IR never nests deeper
        kind = LLVM.API.LLVMGetValueKind(cur)
        if kind == LLVM.API.LLVMFunctionValueKind ||
           kind == LLVM.API.LLVMGlobalIFuncValueKind ||
           kind == LLVM.API.LLVMGlobalVariableValueKind ||
           kind == LLVM.API.LLVMGlobalAliasValueKind ||
           kind == LLVM.API.LLVMConstantPointerNullValueKind
            return cur
        end
        if kind == LLVM.API.LLVMConstantExprValueKind
            inner_opc = LLVM.API.LLVMGetConstOpcode(cur)
            if inner_opc == LLVM.API.LLVMBitCast ||
               inner_opc == LLVM.API.LLVMAddrSpaceCast
                nsub = Int(LLVM.API.LLVMGetNumOperands(cur))
                nsub == 1 || return nothing
                cur = LLVM.API.LLVMGetOperand(cur, 0)
                cur == C_NULL && return nothing
                continue
            end
            # ptrtoint / inttoptr / GEP / anything else inside the icmp
            # operand position changes addressing semantics; not foldable.
            return nothing
        end
        return nothing
    end
    return nothing   # peel-depth exhausted
end
```

### 5.4 `_ptr_addresses_equal`

```julia
# After alias peeling, decide whether two GlobalValue / null refs denote
# the same link-time address.
#
# Contract:
#   - Both inputs MUST already be the output of `_peel_trivial_ptrcast`
#     (i.e. leaf kinds: Function / GlobalIFunc / GlobalVariable /
#      GlobalAlias / ConstantPointerNull). Callers enforce this.
#   - GlobalAlias refs are chased to their terminal aliasee via
#     `_resolve_aliasee`. Cycle / depth overflow / NULL → return nothing.
#   - Named globals (Function, GlobalIFunc, GlobalVariable) are compared
#     by ref pointer equality (LLVM guarantees each named global has one
#     Value object per module).
#   - ConstantPointerNull ≠ any named global (named globals are never
#     NULL at link time — ELF / Mach-O give every defined global a nonzero
#     address, and Julia's JIT materialises every typetag).
#   - Two ConstantPointerNulls are equal.
function _ptr_addresses_equal(a::_LLVMRef, b::_LLVMRef)::Union{Bool, Nothing}
    a == C_NULL && return nothing
    b == C_NULL && return nothing

    a_resolved = _resolve_aliasee(a)
    b_resolved = _resolve_aliasee(b)
    (a_resolved === nothing || b_resolved === nothing) && return nothing

    a_kind = LLVM.API.LLVMGetValueKind(a_resolved)
    b_kind = LLVM.API.LLVMGetValueKind(b_resolved)

    # Leaf kinds after alias resolution.
    _is_named_global(k) =
        k == LLVM.API.LLVMFunctionValueKind ||
        k == LLVM.API.LLVMGlobalIFuncValueKind ||
        k == LLVM.API.LLVMGlobalVariableValueKind
    _is_null(k) = k == LLVM.API.LLVMConstantPointerNullValueKind

    if _is_null(a_kind) && _is_null(b_kind)
        return true
    end
    if _is_null(a_kind) && _is_named_global(b_kind)
        return false    # named globals are not NULL
    end
    if _is_named_global(a_kind) && _is_null(b_kind)
        return false
    end
    if _is_named_global(a_kind) && _is_named_global(b_kind)
        # Distinct named globals have distinct addresses. LLVM guarantees a
        # single Value object per named global per module, so ref-pointer
        # equality is correct here.
        return a_resolved == b_resolved
    end

    return nothing   # unexpected kind; caller fails loud
end
```

### 5.5 Small helper for error messages

```julia
# Map a ConstantExpr opcode enum to a human-readable name for error
# messages. Keep this table minimal; if an opcode isn't listed the
# `sprint(show, opc)` fallback renders "LLVMOpcode(NN)" which is still
# diagnostic.
const _CONSTEXPR_OPCODE_NAMES = Dict(
    LLVM.API.LLVMICmp          => "icmp",
    LLVM.API.LLVMBitCast       => "bitcast",
    LLVM.API.LLVMAddrSpaceCast => "addrspacecast",
    LLVM.API.LLVMPtrToInt      => "ptrtoint",
    LLVM.API.LLVMIntToPtr      => "inttoptr",
    LLVM.API.LLVMGetElementPtr => "getelementptr",
    LLVM.API.LLVMSelect        => "select",
    LLVM.API.LLVMTrunc         => "trunc",
    LLVM.API.LLVMZExt          => "zext",
    LLVM.API.LLVMSExt          => "sext",
    LLVM.API.LLVMAdd           => "add",
    LLVM.API.LLVMSub           => "sub",
    LLVM.API.LLVMMul           => "mul",
    LLVM.API.LLVMAnd           => "and",
    LLVM.API.LLVMOr            => "or",
    LLVM.API.LLVMXor           => "xor",
    LLVM.API.LLVMShl           => "shl",
    LLVM.API.LLVMLShr          => "lshr",
    LLVM.API.LLVMAShr          => "ashr",
)

_constexpr_opcode_name(opc) =
    get(_CONSTEXPR_OPCODE_NAMES, opc, sprint(show, opc))
```

---

## 6. Test plan

### 6.1 RED → GREEN sequence

1. **Already-written**: `test/test_cc04_repro.jl`. Before implementation:
   runs, crashes with `"Unknown operand ref for: i1 icmp eq (...)"`. After
   implementation: passes (compiles, simulates, verifies reversibility).

2. **TJ3 flip**: `test/test_t5_corpus_julia.jl` at lines ~132–146. Today:
   `@test_throws ErrorException reversible_compile(f_tj3, Int8)`. Post-fix:
   replace with the currently-commented GREEN block:
   ```julia
   c = reversible_compile(f_tj3, Int8)
   for x in typemin(Int8):typemax(Int8)
       @test simulate(c, Int8(x)) == x + Int8(2)
   end
   @test verify_reversibility(c; n_tests=3)
   println("  TJ3: ", gate_count(c))
   ```
   Record the TJ3 gate count in WORKLOG.md — this is a new baseline.

3. **Full suite**: `julia --project=. -e 'using Pkg; Pkg.test()'`. Every
   currently-GREEN test must remain GREEN. Every `@test_throws` that was
   catching "Unknown operand ref" for a cc0.4-shaped case must be audited —
   they likely flip GREEN.

### 6.2 New micro-tests (in a new `test/test_cc04.jl`, added to runtests.jl)

Three positive-path cases and three fail-loud cases. Each uses a real
end-to-end compilation (not synthetic IR), because `optimize=true` reliably
produces the ConstantExpr shape whenever a `Union{T, Nothing}` field is
involved:

```julia
using Test
using Bennett

# --- Positive-path tests ---

mutable struct CC04P1{T}
    val::T
    next::Union{CC04P1{T}, Nothing}
end

@testset "Bennett-cc0.4 — folded `icmp eq` (false)" begin
    # Two distinct types → icmp eq folds to false → select takes false arm.
    function g(x::Int8)::Int8
        n = CC04P1{Int8}(x, nothing)
        isnothing(n.next) ? x + Int8(5) : Int8(-1)
    end
    c = reversible_compile(g, Int8)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, Int8(x)) == (x + Int8(5)) % Int8
    end
    @test verify_reversibility(c; n_tests=3)
end

@testset "Bennett-cc0.4 — folded `icmp ne`" begin
    # Same pattern but the conditional is negated (Julia often emits
    # !isnothing via icmp ne on the same ConstantExpr shape).
    function h(x::Int8)::Int8
        n = CC04P1{Int8}(x, nothing)
        !isnothing(n.next) ? Int8(-1) : x + Int8(7)
    end
    c = reversible_compile(h, Int8)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, Int8(x)) == (x + Int8(7)) % Int8
    end
    @test verify_reversibility(c; n_tests=3)
end

@testset "Bennett-cc0.4 — two-hop linked list (TJ3 micro)" begin
    # Matches test_cc04_repro.jl but kept separate from the
    # reproduction file so this file doesn't depend on that one.
    function two_hop(x::Int8)::Int8
        n3 = CC04P1{Int8}(x + Int8(2), nothing)
        n2 = CC04P1{Int8}(x + Int8(1), n3)
        n1 = CC04P1{Int8}(x, n2)
        if !isnothing(n1.next) && !isnothing(n1.next.next)
            n1.next.next.val
        else
            Int8(-1)
        end
    end
    c = reversible_compile(two_hop, Int8)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, Int8(x)) == (x + Int8(2)) % Int8
    end
    @test verify_reversibility(c; n_tests=3)
end
```

### 6.3 Fail-loud tests (new file, same `test_cc04.jl`)

We can't easily craft a Julia source that reliably emits an out-of-scope
ConstantExpr shape (instcombine is too aggressive). Instead, test the
helpers directly against synthetic inputs — these are unit tests for
`_ptr_addresses_equal` and `_peel_trivial_ptrcast`:

Skip this section if direct helper testing is awkward (they're file-private
in `ir_extract.jl`). A practical alternative: run a version of `f_cc04`
that tries to compare pointer ordering (hard to craft in safe Julia);
simpler to leave the fail-loud paths as code review only, covered
structurally by the decision table in §4.

**Decision**: do NOT add helper-level unit tests. Cover fail-loud paths by
code review + the `error()` messages being specific enough to debug when
they fire. The positive-path tests exercise the actual extraction pipeline
end-to-end, which is what matters.

### 6.4 Gate-count spot-checks

Per CLAUDE.md §6 and WORKLOG.md ("Key recent session insights" #1),
baselines that must stay byte-identical:

- i8 add: 86 gates
- i16 add: 174 gates
- i32 add: 350 gates
- i64 add: 702 gates
- soft_fptrunc: 36,474 gates
- popcount32 standalone: 2,782 gates
- HAMT demo max_n=8: 96,788 gates
- CF demo max_n=4: 11,078 gates
- CF+Feistel: 65,198 gates
- ls_demo_16 (optimize=true): 5,218 gates

After implementing, run a quick script that measures each of these and
compare. They MUST match byte-for-byte. If any of them moves: §7 argues
this can't happen (new ConstantExpr branch is unreachable for these
inputs). If empirically it does, STOP and debug.

### 6.5 New baseline to record

- TJ3 gate count: to be measured post-fix, logged in WORKLOG.md as a new
  regression baseline.

---

## 7. Regression argument

**Claim**: every currently-GREEN test stays GREEN byte-for-byte in gate
count, and the existing RED→`@test_throws` tests either keep catching
their original error shape or flip to new GREEN assertions.

### 7.1 Why scalar codepaths are untouched

The only modification to an existing function is one new `elseif` branch
in `_operand`:

```julia
elseif val isa LLVM.ConstantExpr
    return _operand_constexpr(val, names)
```

For this branch to execute, `val isa LLVM.ConstantExpr` must be true. A
`LLVM.ConstantExpr` is a specific concrete type in LLVM.jl
(`/home/tobias/.julia/packages/LLVM/fEIbx/src/core/value/constant.jl:544`)
— it is not a supertype of `ConstantInt` or `ConstantAggregateZero`, nor
of instruction-SSA values. The branch is unreachable for any operand that
today takes one of the three existing branches.

Therefore: for any LLVM IR that the extractor currently accepts, the
behaviour of `_operand` is bitwise-identical. The emitted `IROperand`
stream into `IRBinOp` / `IRICmp` / `IRSelect` / `IRPhi` / `IRBranch` /
`IRRet` is unchanged. `lower.jl` produces byte-identical gate sequences.
Gate counts are preserved.

### 7.2 Why new codepaths can't leak

`_operand_constexpr` only returns three kinds of values:
- `iconst(0)` or `iconst(1)` (the folded i1 literal)
- Never returns — raises `error()` (fail loud path)

These are exactly the same `IROperand` shapes `_operand` already emits for
`ConstantInt` ops. No new operand types. No new sentinels. No wire-width
surprises (the folded i1 is width-1 via `_iwidth(ops[i])` on the original
LLVM operand, which correctly returns 1 for a `ConstantExpr<icmp>` result
type).

### 7.3 Why `_peel_trivial_ptrcast` is safe

It only runs when `val isa LLVM.ConstantExpr` AND the outer opcode is
`LLVMICmp`. The peeling is a read-only traversal via `LLVMGetOperand` —
it does not mutate the LLVM module and does not affect naming, ordering,
or any pre-walk. Its output is an `_LLVMRef` consumed only by
`_ptr_addresses_equal`, whose output is a `Bool`/`nothing`, folded into an
`iconst` — same shape as today's ConstantInt path.

### 7.4 Why fail-loud branches can't regress

Every new `error()` is raised only inside `_operand_constexpr`, which is
only entered when `val isa LLVM.ConstantExpr`. For any IR where today's
`_operand` doesn't crash, it cannot enter this branch (because the
ConstantExpr type-check fails). For IR where today's `_operand` DOES
crash on a ConstantExpr, today we already get a generic "Unknown operand
ref" — the new code either succeeds (better) or raises a more-specific
error (still RED, but more actionable).

### 7.5 Interaction with cc0.3's `_safe_operands`

cc0.3's `_safe_operands` is only wired into a specific subset of sites
(store / load / GEP / call). It uses `_operand_safe` which wraps
`_operand`. After cc0.4:

- `_operand_safe` calls `_operand` on a `Union{LLVM.Value, Nothing}` value.
- If the value is a ConstantExpr (e.g. a ConstantExpr<bitcast> wrapping a
  global in a load address), the new branch fires. For bitcast-of-global
  the fold path (§4 table row "bitcast/addrspacecast") raises fail-loud
  because we don't fold to an integer — we fold ONLY icmp. So the
  behaviour matches today: fail loud on a ConstantExpr operand in a load
  address. Except the error is now "Bennett-cc0.4: unhandled ConstantExpr
  opcode bitcast..." which is strictly more actionable than the current
  generic message.

  **Wait**: that changes error messages seen by downstream callers. Does
  any current test assert on the exact text of such a message? Let me
  check — `@test_throws ErrorException` in TJ1/TJ2 does NOT assert on
  message text (only that an error is raised). The error-message-text
  assertions in cc03_05_consensus.md §Tests are "extracted error message
  no longer contains `LLVMGlobalAliasValueKind`". After cc0.4, they still
  won't contain it; they'll contain "unhandled ConstantExpr opcode
  bitcast" or "unhandled ConstantExpr opcode getelementptr" instead. That
  is consistent with the assertion. Safe.

- If the value resolves as `nothing` (GlobalAlias chase failed pre-cc0.4),
  `_operand_safe` returns `OPAQUE_PTR_SENTINEL` unchanged. cc0.4 doesn't
  touch this path.

### 7.6 Interaction with cc0.7's `lanes` side table

`_convert_vector_instruction` calls `_operand(elem, names)` inside the
`insertelement` handler for the scalar element. If that element is ever a
ConstantExpr (unusual — Julia's SLP vectorizer splats scalars that are
themselves named SSA, not constants), our new branch handles it. For the
two positive predicates we fold, the result is a width-1 or width-0
iconst; insertelement stashes it into `lanes[inst.ref]`, same as it would
a ConstantInt. No perturbation to cc0.7.

### 7.7 Empirical backstop

The CLAUDE.md §6 gate-count baselines are the ultimate check. If any of
them moves after this change, the regression argument is wrong and the
implementer must stop and investigate. I've argued above that they can't
move; empirical verification is non-negotiable.

---

## 8. Deferred / follow-up

The following shapes are explicitly NOT handled in cc0.4. Each raises
fail-loud with a hint pointing at a future bead.

### 8.1 Pointer ordering (ULT/UGT/ULE/UGE/SLT/SGT/SLE/SGE on pointers)

Julia might emit `icmp ult (ptr @A, ptr @B)` in rare cases (e.g. type
ordering for dispatch). The result is allocator-dependent at link time —
not statically decidable. **Fail loud**. Deferred: file a new bead if this
pattern arises in real code and we need to emit a symbolic wire.

### 8.2 `ptrtoint` / `inttoptr` ConstantExprs in operand slots

`ConstantExpr<ptrtoint (ptr @X to i64)>` could appear as a 64-bit integer
operand of an add or icmp. Resolving it would require assigning a concrete
address to `@X` at compile time (we don't have one — LLVM assigns them at
link time) or symbolically representing "address-of-global" in the wire
model (Bennett doesn't support this today). **Fail loud**. Deferred to
cc0.6 per the bead description ("error-report cleanup ... likely via same
opaque-ptr sentinel infrastructure cc0.3 landed").

The error message for this case explicitly points at cc0.6.

### 8.3 `getelementptr` ConstantExprs

`ConstantExpr<getelementptr (ptr @X, i64 3)>` computes an offset into a
named global. We have a partial machinery for GEP-of-global via
`_extract_const_globals`, but it lives in the pre-walk and currently keys
on the *global itself*, not on a GEP expression. **Fail loud**. Deferred
to cc0.5/cc0.6 once real IR produces this shape.

### 8.4 Nested ConstantExpr with non-peelable outer ops

E.g. `icmp eq (ptrtoint ptr @A to i64, i64 0)` (checking if `@A` is
NULL-addressed). Resolving would require the same pointer-symbolic
machinery as §8.2. **Fail loud**. Deferred.

### 8.5 ConstantExpr with floating-point operands

`ConstantExpr<fcmp ...>` shouldn't appear in our plain-integer-Julia target
corpus (floating point routes through the soft-float module). **Fail loud**
with a hint to extend soft-float coverage rather than cc0.4.

### 8.6 `LLVMConstantStruct` / `LLVMConstantArray` / `LLVMConstantVector` as top-level operands

These are distinct value kinds from ConstantExpr, not caught by `val isa
LLVM.ConstantExpr`. They'd hit the final `haskey(names, r) || error`
branch same as today. Not cc0.4's problem; they have their own beads if
they ever arise.

### 8.7 Same-global `icmp ult` (trivially false because ordering is reflexive)

A redundancy pass normally kills this. If it appears, we don't fold —
§8.1 applies.

### 8.8 Impact on cc0.6 (ptrtoint/inttoptr)

The WORKLOG notes cc0.6 will likely extend this infrastructure. Argue
shape-compatibility:

- cc0.6 needs to handle ptrtoint/inttoptr as *instructions* (not
  ConstantExprs) — emitted from Julia's runtime helpers in some patterns
  not seen in the current corpus. The instruction handler lives in
  `_convert_instruction`, a different dispatch site.
- cc0.6 *may also* need to handle `ConstantExpr<ptrtoint>` in operand
  slots. Our §5.2 already has an explicit branch for this case that
  raises "cc0.6 territory". When cc0.6 lands, that branch is the hook:
  replace the `error()` with a call to a new `_operand_constexpr_ptrtoint`
  helper that consults a symbolic-address map (if cc0.6 introduces one).
- Alternatively, cc0.6 might push the ptrtoint handling back to the
  pre-walk (resolve the named global's layout, emit a synthetic `IRAlloca`
  or `IRLoad` with a fixed address). Either way, `_operand_constexpr` is
  a natural extension point. The shape is compatible: one more branch in
  the opcode dispatch.

The `_peel_trivial_ptrcast` helper is also directly reusable by cc0.6 —
it already knows how to strip bitcast/addrspacecast wrappers, which is
exactly what cc0.6 needs to see through ptrtoint-wrapped-in-bitcast
patterns.

### 8.9 Impact on multi-language ingest (T5-P5a / P5b)

cc0.4 is written in terms of the LLVM.jl C API, which is agnostic to
whether the IR was parsed from a .ll text, a .bc bitcode file, or the
in-process Julia compiler. No new dependency on Julia-specific structure.
T5-P5 will exercise the same `_operand` → `_operand_constexpr` path.
Shape-compatible.

---

## 9. Code snippet — full patched `_operand` + helpers

This is the exact code the implementer should paste. It goes in
`src/ir_extract.jl`, immediately after the cc0.3 helpers block (currently
ending at line 1400) and before `_operand` (currently at line 1751), so
that `_operand` can reference `_operand_constexpr` without forward
declaration.

```julia
# ---- Bennett-cc0.4: ConstantExpr folding for `icmp eq/ne` on pointers ----
#
# Julia under `optimize=true` folds `isnothing(x.next)` on Union{T,Nothing}
# fields into a static comparison of two runtime type descriptors:
#
#   %sel = select i1 icmp eq (ptr @"+Main.T#NNN.jit",
#                             ptr @"+Core.Nothing#MMM.jit"),
#                 i8 -1, i8 %rhs
#
# The i1 condition is a LLVM.ConstantExpr (not a named SSA, ConstantInt, or
# ConstantAggregateZero), so it crashes `_operand` pre-fix. Fold
# statically-decidable cases: eq/ne on two named globals (distinct globals
# differ; same ref is equal; null ≠ named global). Everything else
# fails loud with a specific message.
#
# See docs/design/cc04_consensus.md for the full decision table and
# regression argument.

# Human-readable names for ConstantExpr opcodes in error messages.
# Keep minimal; unknown opcodes fall back to the raw enum formatter.
const _CONSTEXPR_OPCODE_NAMES = Dict(
    LLVM.API.LLVMICmp          => "icmp",
    LLVM.API.LLVMBitCast       => "bitcast",
    LLVM.API.LLVMAddrSpaceCast => "addrspacecast",
    LLVM.API.LLVMPtrToInt      => "ptrtoint",
    LLVM.API.LLVMIntToPtr      => "inttoptr",
    LLVM.API.LLVMGetElementPtr => "getelementptr",
    LLVM.API.LLVMSelect        => "select",
    LLVM.API.LLVMTrunc         => "trunc",
    LLVM.API.LLVMZExt          => "zext",
    LLVM.API.LLVMSExt          => "sext",
    LLVM.API.LLVMAdd           => "add",
    LLVM.API.LLVMSub           => "sub",
    LLVM.API.LLVMMul           => "mul",
    LLVM.API.LLVMAnd           => "and",
    LLVM.API.LLVMOr            => "or",
    LLVM.API.LLVMXor           => "xor",
    LLVM.API.LLVMShl           => "shl",
    LLVM.API.LLVMLShr          => "lshr",
    LLVM.API.LLVMAShr          => "ashr",
)

_constexpr_opcode_name(opc) =
    get(_CONSTEXPR_OPCODE_NAMES, opc, sprint(show, opc))

# Peel trivial address-preserving pointer casts wrapping a GlobalValue or
# null. Returns the leaf ref, or `nothing` if the ConstantExpr is wrapped
# in a cast whose address semantics we don't understand (ptrtoint,
# inttoptr, getelementptr) or if peel depth is exceeded. Leaf kinds:
# Function, GlobalIFunc, GlobalVariable, GlobalAlias, ConstantPointerNull.
function _peel_trivial_ptrcast(ref::_LLVMRef)::Union{_LLVMRef, Nothing}
    ref == C_NULL && return nothing
    cur = ref
    for _ in 1:4
        kind = LLVM.API.LLVMGetValueKind(cur)
        if kind == LLVM.API.LLVMFunctionValueKind ||
           kind == LLVM.API.LLVMGlobalIFuncValueKind ||
           kind == LLVM.API.LLVMGlobalVariableValueKind ||
           kind == LLVM.API.LLVMGlobalAliasValueKind ||
           kind == LLVM.API.LLVMConstantPointerNullValueKind
            return cur
        end
        if kind == LLVM.API.LLVMConstantExprValueKind
            inner_opc = LLVM.API.LLVMGetConstOpcode(cur)
            if inner_opc == LLVM.API.LLVMBitCast ||
               inner_opc == LLVM.API.LLVMAddrSpaceCast
                nsub = Int(LLVM.API.LLVMGetNumOperands(cur))
                nsub == 1 || return nothing
                cur = LLVM.API.LLVMGetOperand(cur, 0)
                cur == C_NULL && return nothing
                continue
            end
            return nothing
        end
        return nothing
    end
    return nothing
end

# Decide whether two peeled pointer refs denote the same link-time address.
# Inputs MUST be the output of `_peel_trivial_ptrcast` — i.e. Function,
# GlobalIFunc, GlobalVariable, GlobalAlias, or ConstantPointerNull.
# Returns Bool (statically decidable) or nothing (undecidable).
function _ptr_addresses_equal(a::_LLVMRef, b::_LLVMRef)::Union{Bool, Nothing}
    a == C_NULL && return nothing
    b == C_NULL && return nothing

    a_resolved = _resolve_aliasee(a)
    b_resolved = _resolve_aliasee(b)
    (a_resolved === nothing || b_resolved === nothing) && return nothing

    a_kind = LLVM.API.LLVMGetValueKind(a_resolved)
    b_kind = LLVM.API.LLVMGetValueKind(b_resolved)

    _is_named_global(k) =
        k == LLVM.API.LLVMFunctionValueKind ||
        k == LLVM.API.LLVMGlobalIFuncValueKind ||
        k == LLVM.API.LLVMGlobalVariableValueKind
    _is_null(k) = k == LLVM.API.LLVMConstantPointerNullValueKind

    if _is_null(a_kind) && _is_null(b_kind)
        return true
    end
    if _is_null(a_kind) && _is_named_global(b_kind)
        return false
    end
    if _is_named_global(a_kind) && _is_null(b_kind)
        return false
    end
    if _is_named_global(a_kind) && _is_named_global(b_kind)
        return a_resolved == b_resolved
    end

    return nothing
end

# Fold a ConstantExpr into an IROperand. Currently: `icmp eq/ne` on
# pointer-typed globals only. Extend via new beads for ptrtoint (cc0.6),
# getelementptr (cc0.6+), etc.
function _operand_constexpr(val::LLVM.ConstantExpr,
                             names::Dict{_LLVMRef, Symbol})::IROperand
    opc = LLVM.API.LLVMGetConstOpcode(val.ref)

    if opc == LLVM.API.LLVMICmp
        pred = LLVM.API.LLVMGetICmpPredicate(val.ref)
        pred in (LLVM.API.LLVMIntEQ, LLVM.API.LLVMIntNE) ||
            error("Bennett-cc0.4: ConstantExpr<icmp $pred> with non-EQ/NE " *
                  "predicate is not foldable at extraction time (pointer " *
                  "address ordering is allocator-dependent). Operand: " *
                  "$(string(val)). File a new bead extending cc0.4 if " *
                  "this arises in real code.")

        n = Int(LLVM.API.LLVMGetNumOperands(val.ref))
        n == 2 ||
            error("Bennett-cc0.4: ConstantExpr<icmp> with $n operands " *
                  "(expected 2): $(string(val))")

        a = LLVM.API.LLVMGetOperand(val.ref, 0)
        b = LLVM.API.LLVMGetOperand(val.ref, 1)

        a_peeled = _peel_trivial_ptrcast(a)
        a_peeled === nothing && error(
            "Bennett-cc0.4: ConstantExpr<icmp> lhs is a non-trivial " *
            "ConstantExpr (expected GlobalValue, GlobalAlias, null, or a " *
            "bitcast/addrspacecast wrapping one). Operand: $(string(val)). " *
            "File a new bead extending cc0.4.")
        b_peeled = _peel_trivial_ptrcast(b)
        b_peeled === nothing && error(
            "Bennett-cc0.4: ConstantExpr<icmp> rhs is a non-trivial " *
            "ConstantExpr (expected GlobalValue, GlobalAlias, null, or a " *
            "bitcast/addrspacecast wrapping one). Operand: $(string(val)). " *
            "File a new bead extending cc0.4.")

        eq = _ptr_addresses_equal(a_peeled, b_peeled)
        eq === nothing && error(
            "Bennett-cc0.4: ConstantExpr<icmp eq/ne> cannot be statically " *
            "decided — one or both operands did not resolve to a " *
            "GlobalValue or null after alias peeling. Operand: " *
            "$(string(val)). File a new bead extending cc0.4.")

        result_true = (pred == LLVM.API.LLVMIntEQ) ? eq : !eq
        return iconst(result_true ? 1 : 0)
    end

    if opc == LLVM.API.LLVMPtrToInt || opc == LLVM.API.LLVMIntToPtr
        error("Bennett-cc0.4/cc0.6: ConstantExpr<" *
              "$(_constexpr_opcode_name(opc))> in operand position is " *
              "cc0.6 scope (ptrtoint/inttoptr handling). Operand: " *
              "$(string(val)).")
    end

    error("Bennett-cc0.4: unhandled ConstantExpr opcode " *
          "$(_constexpr_opcode_name(opc)) in operand position. " *
          "Operand: $(string(val)). File a new bead extending cc0.4 with " *
          "a minimal repro.")
end
```

And the patched `_operand` itself:

```julia
function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(convert(Int, val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)  # special: zero aggregate
    elseif val isa LLVM.ConstantExpr
        # Bennett-cc0.4: fold statically-decidable ConstantExprs (today:
        # icmp eq/ne on pointer-typed globals) into i1 literals. All other
        # ConstantExpr shapes fail loud with a specific message.
        return _operand_constexpr(val, names)
    else
        r = val.ref
        haskey(names, r) || error("Unknown operand ref for: $(string(val))")
        return ssa(names[r])
    end
end
```

---

## 10. Implementer checklist (RED → GREEN)

1. Read this doc and Proposer B's doc; the implementer (or orchestrator)
   writes a consensus doc citing the synthesised decisions.
2. Add `_CONSTEXPR_OPCODE_NAMES`, `_constexpr_opcode_name`,
   `_peel_trivial_ptrcast`, `_ptr_addresses_equal`, and
   `_operand_constexpr` to `src/ir_extract.jl` (after the cc0.3 helpers
   block, before `_operand`).
3. Patch `_operand` to add the `LLVM.ConstantExpr` branch.
4. Run `julia --project=. test/test_cc04_repro.jl` — confirm GREEN.
5. Flip `test/test_t5_corpus_julia.jl` TJ3 from `@test_throws` to the
   currently-commented GREEN block (lines ~137–145). Run. Confirm GREEN.
   Record TJ3 gate count.
6. Run the full suite: `julia --project=. -e 'using Pkg; Pkg.test()'`.
   All green.
7. Spot-check gate-count baselines (§6.4 list) via a small script; all
   byte-identical.
8. Update `WORKLOG.md` with:
   - cc0.4 close
   - TJ3 gate count (new baseline)
   - Any surprises / gotchas encountered
   - Remove the "cc0.4 ○ **next** (P2)" row from the epic-status table;
     add a "cc0.4 ✓ closed" row.
9. Commit: `Bennett-cc0.4: _operand folds ConstantExpr<icmp eq/ne> on
   pointer globals`. Push.

---

## 11. Uncertainty acknowledgments

Three facts that I'm relying on but that a careful implementer should
re-verify at paste time:

1. **`LLVM.API.LLVMGetConstOpcode` + `LLVMGetICmpPredicate` signatures and
   return types.** Grepped at
   `/home/tobias/.julia/packages/LLVM/fEIbx/lib/18/libLLVM.jl:3538-3539`
   and `:5204-5205`. Both take `LLVMValueRef` and return `LLVMOpcode` /
   `LLVMIntPredicate` respectively. The ir_extract codebase uses these
   pattern correctly in cc0.3 and cc0.7. No surprise expected.

2. **`LLVM.ConstantExpr` is a dispatchable concrete type.** Confirmed at
   `/home/tobias/.julia/packages/LLVM/fEIbx/src/core/value/constant.jl:544-547`
   — it's a `@checked struct ConstantExpr <: Constant` registered to
   `LLVMConstantExprValueKind`. `val isa LLVM.ConstantExpr` works exactly
   like the other `isa` checks in `_operand` today.

3. **`LLVM.ConstantExpr.ref` attribute.** Used above via `val.ref`. All
   LLVM.jl value wrappers expose `.ref::LLVMValueRef`; confirmed by the
   existing `val.ref` usage in `_operand` at line 1757.

4. **Distinct named globals have distinct addresses at link time.** This
   is the core semantic claim of §5.4. It is true under every ELF /
   Mach-O / COFF linker I know of, AND true under LLVM's in-process JIT
   (each GlobalVariable gets a distinct allocation from the memory
   manager). The one theoretical exception: two globals both `internal
   linkonce_odr` declared with the same unnamed_addr attribute — the
   linker may merge them. In our target corpus (plain Julia under
   `optimize=true`), typetag globals are emitted with external linkage
   and distinct addresses are guaranteed.

5. **`LLVMGetOperand` on a ConstantExpr.** Confirmed safe — ConstantExpr
   inherits the `User` interface which provides `LLVMGetOperand` /
   `LLVMGetNumOperands`. The existing `_safe_operands` uses these on
   Instructions (also Users); the same API works on ConstantExpr.

6. **Error-message content vs the `@test_throws ErrorException` assertion
   in TJ1/TJ2/TJ4.** `@test_throws ErrorException` does not match
   message text, only type. The cc0.4 error messages all fail-loud as
   `ErrorException`. If a future agent tightens these assertions with
   message regex, this proposal's messages must be updated too.

---

## 12. One-page summary

- **What**: `_operand` can't handle `LLVM.ConstantExpr` values (current
  code: three `isa` branches + `haskey(names, r) || error`).
- **Why it matters**: `optimize=true` on any Julia function with a
  `Union{T, Nothing}` field traversed via `isnothing` folds to a
  ConstantExpr<icmp eq> on two runtime typetag globals. TJ3 blocked.
- **Fix shape**: one `elseif` branch in `_operand` dispatching to a new
  `_operand_constexpr` helper. Helper folds icmp eq/ne on pointer globals
  to `iconst(0)` / `iconst(1)`. Everything else fail-loud.
- **Blast radius**: one function gains one branch; three new file-private
  helpers; zero touches to `lower.jl`, `bennett.jl`, `ir_types.jl`, or
  any test infrastructure.
- **Regression safety**: new branch is unreachable for any non-ConstantExpr
  operand (today's codepath is byte-identical). `_ptr_addresses_equal` and
  `_peel_trivial_ptrcast` are read-only and only run inside the new
  branch.
- **Deferred**: pointer ordering (ULT/...), ptrtoint/inttoptr (cc0.6),
  getelementptr-of-global (cc0.5/cc0.6), nested non-peelable shapes. All
  fail loud with specific messages naming the follow-up bead.
- **Tests**: `test/test_cc04_repro.jl` flips RED→GREEN; TJ3
  `@test_throws` flips to GREEN assertions + gate-count log; new
  `test/test_cc04.jl` with three positive-path micro-tests; all existing
  gate-count baselines stay byte-identical.
