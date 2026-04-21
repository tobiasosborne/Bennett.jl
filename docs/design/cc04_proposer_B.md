# cc0.4 Proposer B — ConstantExpr pointer-icmp folding in `_operand`

*Bennett-cc0.4 (constant-pointer `icmp eq/ne` appearing as an ordinary
operand). Proposer B, independent design. Do not read in conjunction with
Proposer A until the orchestrator synthesises consensus.*

---

## §Context

Under `optimize=true`, Julia's mid-level optimizer can fold a chain of
mutable-struct allocations + field loads + `isnothing(field)` checks into
a static comparison between two named runtime-type-descriptor globals.
The load-bearing IR shape is an ordinary `select` whose condition is a
`ConstantExpr` (opcode = ICmp):

```llvm
%spec.select = select i1 icmp eq (ptr @"+Main.TJ3Node#N.jit",
                                   ptr @"+Core.Nothing#N.jit"),
                       i8 -1, i8 %rhs
```

Here `@…#N.jit` are `LLVMGlobalAlias`es (the source of the cc0.3 crash)
pointing at Julia's runtime type descriptors. Two **distinct named
globals** always have distinct link-time addresses, so at compile time
`icmp eq` is statically `false` and `icmp ne` is statically `true`.

Today `src/ir_extract.jl` line 1751–1761's `_operand` raises
`"Unknown operand ref for: i1 icmp eq (ptr @A, ptr @B)"` because
`ConstantExpr` falls through the `ConstantInt` / `ConstantAggregateZero`
/ named-SSA ladder and into the error branch. Every consumer (select,
icmp, binop, phi, ret, cast, insertvalue, …) touches the same fall-through
since they all call `_operand(ops[k], names)`.

cc0.4's task: teach `_operand` to recognise one class of
`ConstantExpr` — pointer-typed `icmp eq/ne` between two **distinct** named
globals (directly or via alias chain) — and fold it to an `i1`
`iconst(0)` or `iconst(1)`. Everything else remains fail-loud. This is the
minimum scope that flips `test/test_cc04_repro.jl` (and transitively
`test_t5_corpus_julia.jl::TJ3`) from RED to GREEN without opening the
ptrtoint/inttoptr/GEP ConstantExpr cans (cc0.6 territory).

**Precedents I lean on:**

- cc0.3 (`docs/design/cc03_05_consensus.md`) — already shipped
  `OPAQUE_PTR_SENTINEL`, `_resolve_aliasee`, `_safe_operands`,
  `_operand_safe`. Anything involving a GlobalAlias ref goes through
  `_resolve_aliasee` to dodge LLVM.jl's `identify` crash on value kind 6.
- cc0.7 (`docs/design/cc07_consensus.md`) — the style model for this
  doc. Single-point-of-change extension in `ir_extract.jl`, zero touches
  to `lower.jl` / `bennett.jl` / `ir_types.jl` / `simulator.jl`.
- `freeze` handling at `ir_extract.jl:1141+` and `:__zero_agg__` /
  `:__poison_lane__` / `:__opaque_ptr__` constant-sentinel idiom.

---

## §Minimum reproduction

**RED test**: `test/test_cc04_repro.jl` (freshly written). The function
`f_cc04(x::Int8)::Int8` builds a three-node linked list and runs
`!isnothing(n1.next) && !isnothing(n1.next.next)`. Under `optimize=true`
the entire allocation chain vanishes; what remains is the select quoted
at the top of §Context. Expected post-fix behaviour: the `icmp eq` of two
distinct globals folds to `false`, so the select's false arm wins and
the function reduces to `x + 2` for every i8. The test runs all 256
inputs and calls `verify_reversibility` with `n_tests=3`.

**Empirical probe on the exact failing IR** (verified via `LLVM.API`,
cited from the bead discovery notes — do NOT re-run, trust the audit):

- The crashing operand is `LLVM.ConstantExpr`, value kind
  `LLVM.API.LLVMConstantExprValueKind` (enum 10).
- `LLVM.API.LLVMGetConstOpcode(ce.ref)` → `LLVM.API.LLVMICmp`.
- `LLVM.API.LLVMGetICmpPredicate(ce.ref)` → `LLVM.API.LLVMIntEQ`.
- `LLVM.API.LLVMGetNumOperands(ce.ref)` → 2, both sub-operand refs have
  value kind `LLVMGlobalAliasValueKind`.
- `_resolve_aliasee` on each sub-operand returns a non-alias terminal
  ref (typically a `LLVMGlobalVariableValueKind` type descriptor).
- The two terminal refs differ ⇒ static `false` for `eq`, static `true`
  for `ne`.

**Downstream effect of today's crash:** `_convert_instruction`'s select
handler at line 719–728 calls `_operand(ops[1], names)` on the
`ConstantExpr`, which falls through to `haskey(names, r) || error(...)`
(line 1758). The catch-and-skip fallback installed by cc0.3
(`ir_extract.jl` near line 459 — the wrapper around
`_convert_instruction` that swallows "Unknown value kind" /
"LLVMGlobalAlias" / "PointerType"-MethodError) does **not** swallow
`"Unknown operand ref"`, so the whole extraction aborts and TJ3 /
`test_cc04_repro` fail loud. That is correct fail-fast behaviour — we
want to crash, not silently miscompile — but now the crash is our
target for promotion into a fold.

---

## §API surface

Minimum viable intervention: extend `_operand` itself plus one new private
helper. No signature changes to any other existing function. No new public
exports.

### Current

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

### Proposed

```julia
function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(convert(Int, val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)
    elseif val isa LLVM.ConstantExpr
        # Bennett-cc0.4: fold compile-time-decidable constant-pointer
        # icmp eq/ne between distinct named globals. Everything else
        # still errors fail-loud.
        return _fold_constexpr_operand(val, names)
    else
        r = val.ref
        haskey(names, r) || error("Unknown operand ref for: $(string(val))")
        return ssa(names[r])
    end
end
```

### New helper

```julia
# Bennett-cc0.4 — Fold a ConstantExpr operand to an IROperand.
#
# Scope (MVP, cc0.4): pointer-typed `icmp eq/ne` whose both sub-operands
# resolve via `_resolve_aliasee` to distinct non-alias refs (named globals
# or null-ptr constants). Both `eq` (→ iconst(0)) and `ne` (→ iconst(1))
# are handled.
#
# Any ConstantExpr shape outside that scope raises a clear, actionable
# error citing cc0.4. This preserves fail-loud semantics per CLAUDE.md §1
# and preserves our ability to detect miscompiles — we fold only cases
# where correctness is guaranteed by the "distinct named globals have
# distinct addresses" invariant.
#
# Returns an `IROperand`; never `nothing`, never a sentinel.
function _fold_constexpr_operand(ce::LLVM.ConstantExpr,
                                 names::Dict{_LLVMRef, Symbol})::IROperand
    # ... see §Implementation sketch ...
end
```

No new struct, no new field on `ParsedIR`, no new dict. The fold produces
an ordinary `iconst`, which flows through `resolve!` in `lower.jl` using
the same code path that already handles i1 constants produced by
`IRBinOp`, `IRPhi`, etc.

---

## §Decision table

Let the sub-operands (after chasing alias chains) be `a`, `b` ∈ one of
{`GlobalVariable`, `GlobalAlias`-terminal, `Function`, `PointerNull`,
`ConstantExpr`-nested, unresolvable (`_resolve_aliasee` → `nothing`)}.

**Predicate column**: value of `LLVM.API.LLVMGetConstOpcode(ce.ref)`.
**Sub-predicate column** (when opcode is ICmp): value of
`LLVM.API.LLVMGetICmpPredicate(ce.ref)`.

| ConstantExpr opcode            | Sub-operands                                                     | Action (MVP)                                                 | Rationale |
|-------------------------------:|:-----------------------------------------------------------------|:-------------------------------------------------------------|:----------|
| ICmp EQ                        | distinct named-global refs (both resolved, non-null, `a ≠ b`)    | `iconst(0)`                                                  | Distinct globals have distinct link-time addresses ⇒ statically false. |
| ICmp NE                        | distinct named-global refs (both resolved, non-null, `a ≠ b`)    | `iconst(1)`                                                  | Negation of EQ. |
| ICmp EQ                        | **same** named-global ref after alias resolution (`a === b`)     | `iconst(1)`                                                  | Reflexive equality. Rare in practice (LLVM folds earlier), but trivially correct. |
| ICmp NE                        | same named-global ref after alias resolution (`a === b`)         | `iconst(0)`                                                  | Negation of above. |
| ICmp EQ                        | one null-ptr, one named global (or vice-versa)                    | `iconst(0)`                                                  | A `@global` symbol always has a non-null link address. |
| ICmp NE                        | one null-ptr, one named global (or vice-versa)                    | `iconst(1)`                                                  | Negation of above. |
| ICmp EQ                        | both null-ptr                                                    | `iconst(1)`                                                  | Reflexive. |
| ICmp NE                        | both null-ptr                                                    | `iconst(0)`                                                  | Negation. |
| ICmp EQ / NE                   | **any** sub-operand unresolvable (`_resolve_aliasee` → `nothing`)| **fail-loud error**                                          | Can't prove distinctness without resolution; refusing to guess is correct per CLAUDE.md §1 §10. |
| ICmp EQ / NE                   | **one or both** sub-operands are nested `ConstantExpr` (e.g. a `bitcast` or `getelementptr` over a global) | **fail-loud error** | Deferred to cc0.6 / future bead. We do not recursively fold. |
| ICmp EQ / NE                   | **integer-typed** operands (not pointer-typed)                    | **fail-loud error**                                          | LangRef permits this but we haven't seen it in the wild; defer. See §Deferred §D.5. |
| ICmp with ordering predicate (SLT/ULT/SGT/UGT/SLE/ULE/SGE/UGE) | any pointer operands                  | **fail-loud error**                                          | Pointer ordering is implementation-defined; would not appear in plain Julia ISNOTHING code. Defer. |
| Non-ICmp opcode (BitCast, PtrToInt, IntToPtr, GetElementPtr, AddrSpaceCast, Trunc, ZExt, SExt, Select, ExtractElement, InsertElement, ShuffleVector, etc.) | any | **fail-loud error** | Each would need a distinct fold and motivation. None appear in `test_cc04_repro.jl`; defer. See §Deferred. |

**Key invariant**: every "fail-loud" row emits an error that names the
ConstantExpr opcode symbolically (via an `_OPC_TO_SYM`-style map) and
cites cc0.4, so future extension is discoverable from the message.

**Null-ptr handling note**: `LLVM.PointerNull` is a registered Julia
type in LLVM.jl (`register(PointerNull, API.LLVMConstantPointerNullValueKind)`
at `src/core/value/constant.jl:59`), so `LLVM.Value(ref)` wraps a null
cleanly — no crash. Alias resolution on a null ref is a no-op
(`_resolve_aliasee` returns the ref itself since its kind ≠ GlobalAlias).
We treat null as its own non-alias terminal "identity".

---

## §Implementation sketch

### §I.1 The helper in detail

```julia
# ---- Bennett-cc0.4: ConstantExpr operand folding ----
#
# See `docs/design/cc04_consensus.md` for design notes. MVP scope is the
# single ConstantExpr shape that fires on `optimize=true` plain Julia:
# pointer-typed `icmp eq/ne` between two named globals (often
# GlobalAliases chasing down to runtime type descriptors).
#
# Extension path: any new shape adds one branch to this function. The
# error messages name the opcode + predicate so the next agent knows
# exactly where to add a handler.

# Map of ConstantExpr opcodes to human-readable symbols, for error
# messages. Kept small: only names we have ever seen in the wild or that
# appear directly in the fail-loud error rows of the decision table.
const _CONSTEXPR_OPC_NAMES = Dict{UInt32, Symbol}(
    UInt32(LLVM.API.LLVMICmp)           => :icmp,
    UInt32(LLVM.API.LLVMBitCast)        => :bitcast,
    UInt32(LLVM.API.LLVMPtrToInt)       => :ptrtoint,
    UInt32(LLVM.API.LLVMIntToPtr)       => :inttoptr,
    UInt32(LLVM.API.LLVMGetElementPtr)  => :getelementptr,
    UInt32(LLVM.API.LLVMAddrSpaceCast)  => :addrspacecast,
    UInt32(LLVM.API.LLVMTrunc)          => :trunc,
    UInt32(LLVM.API.LLVMZExt)           => :zext,
    UInt32(LLVM.API.LLVMSExt)           => :sext,
    UInt32(LLVM.API.LLVMSelect)         => :select,
)

_constexpr_opc_name(opc) = get(_CONSTEXPR_OPC_NAMES, UInt32(opc), Symbol(string(opc)))

# Bennett-cc0.4 — fold a ConstantExpr operand to an IROperand.
#
# MVP scope: pointer-typed `icmp eq/ne` between two resolved, distinct
# named-global refs (or one named global vs a null-ptr). Everything else
# fails loud with an actionable message citing cc0.4.
function _fold_constexpr_operand(ce::LLVM.ConstantExpr,
                                 names::Dict{_LLVMRef, Symbol})::IROperand
    opc = LLVM.API.LLVMGetConstOpcode(ce.ref)

    if opc != LLVM.API.LLVMICmp
        error("Bennett-cc0.4: unsupported ConstantExpr opcode " *
              "`$(_constexpr_opc_name(opc))` in operand: $(string(ce)). " *
              "Only constant-pointer `icmp eq/ne` between named globals " *
              "is folded in cc0.4 MVP. Add a handler in " *
              "`_fold_constexpr_operand` (src/ir_extract.jl) if this " *
              "shape needs support. (CLAUDE.md §1 fail-loud.)")
    end

    pred = LLVM.API.LLVMGetICmpPredicate(ce.ref)
    if !(pred == LLVM.API.LLVMIntEQ || pred == LLVM.API.LLVMIntNE)
        error("Bennett-cc0.4: unsupported constant icmp predicate " *
              "$(pred) in ConstantExpr operand: $(string(ce)). Only " *
              "`eq` and `ne` are folded (ordering predicates on " *
              "pointers are implementation-defined). (CLAUDE.md §1.)")
    end

    n = Int(LLVM.API.LLVMGetNumOperands(ce.ref))
    n == 2 || error("Bennett-cc0.4: constant icmp has $n operands, " *
                    "expected 2: $(string(ce))")

    a_ref_raw = LLVM.API.LLVMGetOperand(ce.ref, 0)
    b_ref_raw = LLVM.API.LLVMGetOperand(ce.ref, 1)

    a_ref = _resolve_aliasee(a_ref_raw)
    b_ref = _resolve_aliasee(b_ref_raw)

    if a_ref === nothing || b_ref === nothing
        error("Bennett-cc0.4: constant-ptr icmp has unresolvable " *
              "alias operand in $(string(ce)). `_resolve_aliasee` " *
              "returned `nothing` for " *
              "$(a_ref === nothing ? "operand 0" : "operand 1"). " *
              "Refusing to fold an undecidable comparison. Either the " *
              "alias chain is cyclic, exceeds depth 16, or terminates " *
              "in NULL. Investigate the IR. (CLAUDE.md §1 fail-loud, §10 " *
              "skepticism.)")
    end

    # We have two non-alias terminal refs. Decide:
    # - If identically the same ref, reflexive equality.
    # - If both are recognised as non-alias pointer kinds (GlobalVariable,
    #   Function, PointerNull), they are distinct ⇒ compare by ref.
    # - If either terminal is itself a ConstantExpr (e.g. GEP-over-global),
    #   that's out of MVP scope — fail loud.
    a_kind = LLVM.API.LLVMGetValueKind(a_ref)
    b_kind = LLVM.API.LLVMGetValueKind(b_ref)

    _is_address_identity_kind(k) =
        k == LLVM.API.LLVMGlobalVariableValueKind ||
        k == LLVM.API.LLVMFunctionValueKind       ||
        k == LLVM.API.LLVMConstantPointerNullValueKind

    if !_is_address_identity_kind(a_kind) || !_is_address_identity_kind(b_kind)
        error("Bennett-cc0.4: constant-ptr icmp operand has " *
              "non-address-identity kind ($(a_kind), $(b_kind)) in " *
              "$(string(ce)). Only GlobalVariable, Function, and " *
              "ConstantPointerNull are folded in cc0.4 MVP. Nested " *
              "ConstantExpr operands (bitcast/gep/etc.) are deferred " *
              "to a later bead. (CLAUDE.md §1.)")
    end

    # All four non-alias kinds have a well-defined distinct link-time
    # address (null is the unique all-zero address; each GlobalVariable /
    # Function has its own non-zero address). Ref-equality is sufficient
    # and sound: the LLVM ref pointer IS the distinguishing identity.
    is_equal = (a_ref == b_ref)

    if pred == LLVM.API.LLVMIntEQ
        return iconst(is_equal ? 1 : 0)
    else   # LLVMIntNE
        return iconst(is_equal ? 0 : 1)
    end
end
```

### §I.2 Why ref-equality is sound

LLVM canonicalises unique constants. Two `LLVMGlobalVariable` refs with
distinct `LLVMGetValueName` strings are distinct allocations in the
LLVMContext and will link to distinct addresses. A single named global
has exactly one ref throughout a module. Alias chains that terminate at
the same underlying global collapse to the same terminal ref via
`_resolve_aliasee`. Two aliases to the *same* underlying global (rare,
but possible) would compare equal — which is also the semantically
correct answer for `icmp eq` at link time.

The one edge case worth mentioning: `@llvm.used`-style aliases where a
single global has two different aliases that both point at it. The
aliasee resolution collapses both to the same terminal, so `eq` folds to
`iconst(1)`. Correct.

Null-ptr handling: `LLVM.API.LLVMGetValueKind(null_ref) =
LLVMConstantPointerNullValueKind` ≠ `LLVMGlobalAliasValueKind`, so
`_resolve_aliasee` returns the null ref itself. `null == null` → same
ref → `eq` folds to `iconst(1)`. Two distinct pointer-typed nulls in the
same LLVMContext are canonicalised to one ref per type, so this is also
fine even across "different null types" (rare — all our pointers in
Julia-emitted IR are address-space 0 opaque ptrs).

### §I.3 Edit sites

Exactly two edits to `src/ir_extract.jl`:

1. **Insert** (new code block, between line ~1400 `_operand_safe` and
   line ~1402 cc0.7 helpers comment): the helper `_fold_constexpr_operand`
   and its companion constants `_CONSTEXPR_OPC_NAMES` /
   `_constexpr_opc_name`.
2. **Edit** (extend), lines 1751–1761: add one `elseif val isa
   LLVM.ConstantExpr` branch calling `_fold_constexpr_operand(val, names)`.

No other file is touched. No other function signature changes.

### §I.4 Paranoia assertions

CLAUDE.md §1 fail-loud + §10 skepticism: I include four explicit error
branches in `_fold_constexpr_operand`:

1. Non-ICmp ConstantExpr opcode → error with symbolic opcode name.
2. Unsupported ICmp predicate (ordering) → error.
3. Operand count ≠ 2 → error. (Defensive; icmp always has 2.)
4. Unresolvable alias operand → error citing `_resolve_aliasee`.
5. Non-address-identity terminal kind → error.

Each carries the ConstantExpr's `string(ce)` verbatim (so the user sees
the IR), the reason, and a cc0.4 breadcrumb.

---

## §Test plan

### §T.1 Tests I author (minimum viable)

**Primary**: `test/test_cc04_repro.jl` — already written by the bead
author. This is the load-bearing RED→GREEN gate. I do **not** modify it.

**TJ3 flip**: `test/test_t5_corpus_julia.jl` lines 120–145. After my
fix, the commented-out GREEN block in TJ3 becomes live:

```julia
# POST-cc0.4 GREEN:
c = reversible_compile(f_tj3, Int8)
for x in typemin(Int8):typemax(Int8)
    @test simulate(c, Int8(x)) == x + Int8(2)
end
@test verify_reversibility(c; n_tests=3)
println("  TJ3: ", gate_count(c))
```

and the `@test_throws ErrorException reversible_compile(f_tj3, Int8)` is
**deleted** (not replaced — the bead explicitly promises that the RED
guard lifts). Implementer note: if the end-to-end test surfaces a
downstream error that is NOT the ConstantExpr one (e.g. an alloca
dispatch that re-enables now that the ConstantExpr no longer short-
circuits the extraction), we STOP and report — the bead scope was
"unblock TJ3 via cc0.4", and a separate failure is a separate bead.

### §T.2 Additional micro-tests I recommend

I recommend **one** new small test file rather than expanding
`test_cc04_repro.jl`, to keep the repro minimal and focused:

`test/test_constexpr_icmp.jl` — three @testsets:

1. **Same-global reflexive**. A contrived function whose IR emits
   `icmp eq (ptr @g, ptr @g)` (requires a helper to build the IR
   directly via `LLVM.Context()` — see template below). Expected:
   `iconst(1)` for eq, `iconst(0)` for ne.
2. **Null-vs-global mix**. Build a ConstantExpr `icmp eq (ptr null, ptr
   @g)`. Expected: `iconst(0)` (distinct).
3. **Unsupported-shape fail-loud**. Build a ConstantExpr `bitcast`
   operand. Expected: `ErrorException` whose message contains "cc0.4"
   and "bitcast".

Template for (1):

```julia
using LLVM
using Bennett: _fold_constexpr_operand   # currently unexported; use invoke
LLVM.Context() do _ctx
    mod = LLVM.Module("m")
    i8 = LLVM.IntType(8)
    ptr_ty = LLVM.PointerType()
    g = LLVM.GlobalVariable(mod, i8, "g")
    # Use LLVM.API.LLVMConstICmp(LLVMIntEQ, g, g) or similar to build
    # the ConstantExpr directly; verify the type before calling.
    ce = LLVM.Value(LLVM.API.LLVMConstICmp(LLVM.API.LLVMIntEQ, g, g))
    @assert ce isa LLVM.ConstantExpr
    names = Dict{LLVM.API.LLVMValueRef, Symbol}()
    @test Bennett._fold_constexpr_operand(ce, names) ==
          IROperand(:const, Symbol(""), 1)
end
```

**Implementer verification**: confirm `LLVM.API.LLVMConstICmp` exists in
the installed LLVM.jl version (`grep LLVMConstICmp
~/.julia/packages/LLVM/`). If not, skip (2)/(3) and rely on the
integration tests in `test_cc04_repro.jl` + TJ3.

### §T.3 Whether the unit tests are worth their weight

**Argument in favour**: the unit tests give us direct coverage of the
decision table rows that `test_cc04_repro.jl` alone can't exercise.
`test_cc04_repro.jl` only hits the `EQ, distinct named globals → 0` row.
The null-vs-global, same-global, and fail-loud rows are untested by the
integration test, and a bug there could silently miscompile a future
workload before anyone notices.

**Argument against**: building a ConstantExpr directly via the raw LLVM
C API is awkward, and the surface area is genuinely small (~30 lines of
new code). Per CLAUDE.md §4 "exhaustive verification" vs "gold-plate
never" trade-off, I lean toward writing the unit tests but keeping them
minimal and guarded (skip tests if `LLVMConstICmp` etc. aren't
available).

**Decision**: write `test_constexpr_icmp.jl` with the three @testsets.
Estimated ~80 lines. If any helper API is unavailable, skip that
@testset rather than working around — our goal is to exercise the code
path, not to wrestle LLVM.jl.

### §T.4 Regression guardrail

After implementation, run:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

and confirm zero gate-count changes on every existing test that prints
its gate count. The specific baselines cited in `WORKLOG.md` that must
remain byte-identical are in §Regression argument below.

---

## §Regression argument

**Claim**: The only observable behaviour change from this patch is that
`_operand` accepts one new case (`ConstantExpr` with a specific
structure) instead of erroring. Scalar functions that do not contain
`ConstantExpr` operands traverse the same code paths as before.

**Proof sketch**:

- `_operand`'s first three branches (`ConstantInt`,
  `ConstantAggregateZero`, named-SSA) are untouched in object-code
  sense — the `elseif val isa LLVM.ConstantExpr` branch is added
  **after** the existing ones, so any function whose operands fit the
  old decision tree hits the identical branch.
- The `else` error branch is reached identically for any operand that
  isn't `ConstantInt` / `ConstantAggregateZero` / `ConstantExpr` /
  named-SSA. Error message is unchanged.
- `_fold_constexpr_operand` is a newly-introduced function. No existing
  call site invokes it. The only new call site is the new branch in
  `_operand`. Therefore no pre-existing control flow is perturbed.

**Concrete byte-identical baselines** (from `WORKLOG.md` post-cc0.7 /
post-cc0.3 close), each of which must remain unchanged:

| Workload                     | Gate count  | Why unchanged                                                        |
|-----------------------------:|:------------|:---------------------------------------------------------------------|
| soft_fptrunc                 | 36,474      | Pure integer arithmetic; zero ConstantExpr operands.                 |
| popcount32 (standalone)      | 2,782       | Bitwise ops on `i32`; zero ConstantExpr operands.                    |
| HAMT demo (max_n=8)          | 96,788      | Persistent-DS with known alloca pattern; no constant-ptr-icmp.       |
| CF demo (max_n=4)            | 11,078      | Controlled circuits; no pointer arithmetic at all.                   |
| CF + Feistel                 | 65,198      | Same as above; integer block cipher.                                 |
| i8 addition                  | 86          | Pure integer; exercises the golden BenchmarkBaseline row.            |
| i16 addition                 | 174         | Same; exactly 2× i8 per CLAUDE.md §6.                                |
| i32 addition                 | 350         | Same; exactly 2× i16.                                                |
| i64 addition                 | 702         | Same; exactly 2× i32.                                                |
| ls_demo_16 (post-cc0.7)      | 5,218       | Vector IR scalarised in cc0.7; no ConstantExpr operands appear.      |

For each of these, `_operand` is called thousands of times per function
with operands that satisfy `val isa LLVM.ConstantInt` OR named SSA, and
never with `ConstantExpr`. The new branch is not taken; the emitted
gates are byte-identical.

**Gate-count impact on the newly-GREEN TJ3 function**: expected very
small. The fold replaces a ConstantExpr icmp (which today crashes) with
an `i1` `iconst(0)` inside a `select`. The `select` is then the only
instruction that consumes the ConstantExpr's role; at lowering time,
`lower_select!` will see `cond.kind == :const && cond.value == 0`, allocate
a 1-wire constant, never toggle its NOTGate, and route through
`lower_ite!` (or equivalent) with a compile-time-dead true-arm. Actual
post-fix gate count for TJ3 should be logged to `WORKLOG.md` as a new
baseline. Prediction: roughly `gate_count(x -> x + Int8(2)) + 20` (a
handful of ancilla-bookkeeping gates for the select's zero-condition).

**Regression guard**: per CLAUDE.md §6, the implementer MUST spot-check
at least the i8/i16/i32/i64 addition baselines and 3 of the exotic ones
(soft_fptrunc, popcount32, HAMT demo) before committing. Any delta is a
signal, not an improvement — investigate.

---

## §Deferred

I explicitly do NOT handle these in cc0.4:

### §D.1 Pointer-icmp ordering predicates (slt/ult/sgt/ugt/sle/ule/sge/uge)

LangRef defines these on pointers by treating them as their address-space
integer representation, but the semantics are implementation-defined for
most systems and plain Julia never emits them. Deferred to a future bead
if ever observed. Error message names the predicate.

### §D.2 Integer-typed ConstantExpr icmp

LangRef permits `icmp eq (i32 ..., i32 ...)` as a ConstantExpr but LLVM's
`llvm::ConstantFoldBinaryInstruction` folds these at construction time
for plain integer constants, so they virtually never reach us as
ConstantExpr — they arrive as `ConstantInt`. I verified (via the cited
empirical probe) that the only ConstantExpr icmp we see in TJ3 is the
pointer one. If an integer-typed ConstantExpr icmp did slip through, our
`_is_address_identity_kind` gate would reject it with a clear error.
Deferred.

### §D.3 Nested ConstantExpr sub-operands (bitcast/ptrtoint/gep over globals)

Example: `icmp eq (ptr @g, ptr bitcast (ptr @h to ptr))`. The left
sub-operand is a `GlobalVariable`, the right is a `ConstantExpr` of
kind `LLVMBitCast`. `_is_address_identity_kind` rejects
`LLVMConstantExprValueKind`, which is the correct fail-loud choice.
Recursive folding would add ~30 lines and a broader attack surface; the
cleanest path is to wait until a real workload demands it. cc0.6 is the
natural home.

### §D.4 Non-ICmp ConstantExpr operand shapes

Specifically:

- `BitCast (ptr @g to ptr)` as an operand — currently the bead description
  for cc0.6 mentions ptrtoint/inttoptr in runtime contexts.
- `PtrToInt (ptr @g to iN)` — cc0.6 also calls out this shape.
- `IntToPtr (iN k to ptr)` — cc0.6.
- `GetElementPtr (Ty, ptr @g, iN k)` — would require extracting global
  contents; T1c.2 globals pipeline already exists for GEPs into
  `_j_const#k` arrays (see `ir_extract.jl` around line 325), but that
  path is invoked from a GEP **instruction**, not a ConstantExpr.
- `AddrSpaceCast`, `Select`, `ExtractElement`, `InsertElement`,
  `ShuffleVector` — no evidence in Bennett workloads.

For each: cc0.4 raises a fail-loud error whose message names the opcode
symbolically (`:bitcast`, `:ptrtoint`, etc.) and cites cc0.4 as the
extension site.

### §D.5 `_operand` called on a `ConstantExpr` that cannot be folded

Specifically: the decision-table rows that return `fail-loud error`.
Today's extractor already aborts TJ3 with a clear message. My change
narrows the crash surface — the icmp/eq-ne/pointer/named-global case now
succeeds — and keeps every other crash behaviour identical. If a future
workload produces a ConstantExpr shape we haven't folded, the error
message (now citing cc0.4 specifically) points the next agent at the
right extension site.

### §D.6 `_operand_safe` extension

The cc0.3 `_operand_safe` variant accepts an optional `Nothing` for
unresolvable-alias operands from `_safe_operands` and returns
`OPAQUE_PTR_SENTINEL`. That's orthogonal: when `_safe_operands` returns
a wrapped `LLVM.Value` (not `Nothing`) that happens to be a
`ConstantExpr`, it flows through `_operand_safe → _operand →
_fold_constexpr_operand` as designed. No signature change needed.

### §D.7 Downstream defensive guard in `resolve!`

The cc0.3 consensus proposed (but didn't ship) a `resolve!` guard:

```julia
op.kind == :const && op.name === :__opaque_ptr__ &&
    error("lower.jl resolve!: opaque pointer operand reached integer " *
          "wire allocation — see Bennett-cc0.3.")
```

That guard is orthogonal to cc0.4 (my fold never produces
`:__opaque_ptr__`; only `iconst(0)` / `iconst(1)` with `Symbol("")`
name). I do not add it. If the orchestrator wants to pick it up while
touching the area, it's a one-liner — but it belongs in a cc0.3
follow-up bead, not cc0.4.

### §D.8 `ConstantExpr` appearing as a GEP base

`IRVarGEP` / `IRPtrOffset` instructions read their `base::IROperand`
slot; today this slot is resolved via `_operand` at extraction time. If
the base is a `ConstantExpr` (e.g. the constant GEP of a global), we'd
hit the same fall-through. My fix keeps that case fail-loud because
`_fold_constexpr_operand` refuses non-ICmp opcodes. Correct behaviour
for cc0.4 scope; this is precisely the cc0.6 / T1c.2 terrain.

---

## §Forward compatibility

Does this infrastructure extend cleanly to cc0.6 (ptrtoint / inttoptr in
runtime contexts)?

**Yes, cleanly.** cc0.6 scope per WORKLOG NEXT AGENT is "error-report
cleanup ... needs handler for ptrtoint/inttoptr in runtime contexts,
likely via same opaque-ptr sentinel infrastructure cc0.3 landed."

Two scenarios for cc0.6:

1. **`ptrtoint` / `inttoptr` as an instruction** (the common case for
   runtime-ptr tagging in Julia). That's a `_convert_instruction`
   opcode handler, not a ConstantExpr operand. Unrelated to
   `_fold_constexpr_operand`; cc0.4 infrastructure neither helps nor
   hurts.

2. **`ptrtoint (ptr @g to iN)` as a ConstantExpr operand** — say, in an
   `IRBinOp(:add, ptrtoint(g), const_offset, 64)` pattern. That is a
   new branch in `_fold_constexpr_operand`:

   ```julia
   elseif opc == LLVM.API.LLVMPtrToInt
       # Extract the named-global operand, look up its address-like
       # integer representation. If the global is in parsed.globals
       # (T1c.2), return its base-wire SSA. Otherwise opaque.
       # ... cc0.6 scope ...
   end
   ```

   The helper's signature, its place in `_operand`, its error-message
   conventions, and its opcode-dispatch shape are all directly reusable.
   cc0.4 lays the extension scaffold; cc0.6 adds one case.

**What I do NOT pre-build**: any scaffolding specifically for cc0.6. My
helper has exactly one case (ICmp) plus a uniform fail-loud elsewhere.
Adding a second case is mechanical. Over-engineering a generic dispatch
would violate CLAUDE.md §11 (don't implement beyond current PRD) and
make the patch harder to review.

**What I DO ensure**: the error messages in the fail-loud paths name
the opcode symbolically via `_CONSTEXPR_OPC_NAMES`, so when cc0.6's
target workload first crashes, the message reads "unsupported
ConstantExpr opcode `ptrtoint`" — immediately telling the cc0.6
implementer which branch to add.

---

## §Full code listing of patched `_operand` + helpers, paste-ready

This is the complete diff-equivalent listing. Insert the new block at
the natural home (just after `_operand_safe`, line ~1400) and edit
`_operand` in place (line ~1751).

```julia
# ---- Bennett-cc0.4: ConstantExpr operand folding ----
#
# Under `optimize=true`, Julia's optimizer can fold `isnothing(x.field)`
# checks on `Union{T,Nothing}` fields into a static `select` whose
# condition is a ConstantExpr of the form
#   `icmp eq (ptr @TypeA, ptr @TypeB)`
# where @TypeA and @TypeB are distinct named runtime-type-descriptor
# globals (often `LLVMGlobalAlias` refs; see cc0.3). Two distinct named
# globals have distinct link-time addresses, so `icmp eq` folds to
# statically `false`, `icmp ne` to `true`.
#
# We handle this narrow case at `_operand` time by recognising
# `LLVM.ConstantExpr` operands and dispatching into
# `_fold_constexpr_operand`. Unsupported ConstantExpr shapes raise
# fail-loud errors with an actionable message citing cc0.4 and naming
# the offending opcode.
#
# Scope boundary (MVP, cc0.4):
#   - ICmp EQ / NE only.
#   - Sub-operands: GlobalVariable, Function, PointerNull, or a
#     GlobalAlias that `_resolve_aliasee` chases to one of the above.
#   - Everything else: fail loud. Extend this helper for cc0.6 etc.
#
# Correctness invariant: two distinct non-alias pointer refs represent
# two distinct link-time addresses, so ref-equality on the resolved
# terminals is a sound decider for `icmp eq`. LLVM canonicalises unique
# constants in a module context, so ref-inequality ⇒ address-inequality
# is safe.
#
# See `docs/design/cc04_consensus.md` for the full design and decision
# table.

# Map of ConstantExpr opcodes we reference in error messages.
const _CONSTEXPR_OPC_NAMES = Dict{UInt32, Symbol}(
    UInt32(LLVM.API.LLVMICmp)           => :icmp,
    UInt32(LLVM.API.LLVMBitCast)        => :bitcast,
    UInt32(LLVM.API.LLVMPtrToInt)       => :ptrtoint,
    UInt32(LLVM.API.LLVMIntToPtr)       => :inttoptr,
    UInt32(LLVM.API.LLVMGetElementPtr)  => :getelementptr,
    UInt32(LLVM.API.LLVMAddrSpaceCast)  => :addrspacecast,
    UInt32(LLVM.API.LLVMTrunc)          => :trunc,
    UInt32(LLVM.API.LLVMZExt)           => :zext,
    UInt32(LLVM.API.LLVMSExt)           => :sext,
    UInt32(LLVM.API.LLVMSelect)         => :select,
)

_constexpr_opc_name(opc) =
    get(_CONSTEXPR_OPC_NAMES, UInt32(opc), Symbol(string(opc)))

# Bennett-cc0.4 — fold a ConstantExpr operand to an IROperand.
#
# Scope (MVP): pointer-typed `icmp eq/ne` between resolved, distinct
# named-global refs (or one named global vs a null-ptr). Both EQ and NE
# fold.
#
# Any other ConstantExpr shape raises a fail-loud error citing cc0.4.
# Returns an `IROperand`; never `nothing`, never a sentinel.
function _fold_constexpr_operand(ce::LLVM.ConstantExpr,
                                 names::Dict{_LLVMRef, Symbol})::IROperand
    opc = LLVM.API.LLVMGetConstOpcode(ce.ref)

    if opc != LLVM.API.LLVMICmp
        error("Bennett-cc0.4: unsupported ConstantExpr opcode " *
              "`$(_constexpr_opc_name(opc))` in operand: $(string(ce)). " *
              "Only constant-pointer `icmp eq/ne` between named globals " *
              "is folded in cc0.4 MVP. Extend `_fold_constexpr_operand` " *
              "in src/ir_extract.jl to support this shape. " *
              "(CLAUDE.md §1 fail-loud.)")
    end

    pred = LLVM.API.LLVMGetICmpPredicate(ce.ref)
    if !(pred == LLVM.API.LLVMIntEQ || pred == LLVM.API.LLVMIntNE)
        error("Bennett-cc0.4: unsupported constant icmp predicate " *
              "$(pred) in ConstantExpr operand: $(string(ce)). Only " *
              "`eq` and `ne` are folded (pointer ordering predicates " *
              "are implementation-defined). (CLAUDE.md §1.)")
    end

    n = Int(LLVM.API.LLVMGetNumOperands(ce.ref))
    n == 2 || error("Bennett-cc0.4: constant icmp has $n operands, " *
                    "expected 2: $(string(ce))")

    a_ref_raw = LLVM.API.LLVMGetOperand(ce.ref, 0)
    b_ref_raw = LLVM.API.LLVMGetOperand(ce.ref, 1)

    a_ref = _resolve_aliasee(a_ref_raw)
    b_ref = _resolve_aliasee(b_ref_raw)

    if a_ref === nothing || b_ref === nothing
        which = a_ref === nothing ? "operand 0" :
                b_ref === nothing ? "operand 1" : "(both)"
        error("Bennett-cc0.4: constant-ptr icmp has unresolvable alias " *
              "operand in $(string(ce)). `_resolve_aliasee` returned " *
              "`nothing` for $which. Alias chain is cyclic, exceeds " *
              "depth 16, or terminates in NULL — refusing to fold an " *
              "undecidable comparison. (CLAUDE.md §1 fail-loud, §10 " *
              "skepticism.)")
    end

    a_kind = LLVM.API.LLVMGetValueKind(a_ref)
    b_kind = LLVM.API.LLVMGetValueKind(b_ref)

    if !_is_address_identity_kind(a_kind) ||
       !_is_address_identity_kind(b_kind)
        error("Bennett-cc0.4: constant-ptr icmp operand has " *
              "non-address-identity kind (lhs kind = $(a_kind), " *
              "rhs kind = $(b_kind)) in $(string(ce)). Only " *
              "GlobalVariable, Function, and ConstantPointerNull " *
              "terminal kinds are folded in cc0.4 MVP. Nested " *
              "ConstantExpr operands (bitcast/gep/ptrtoint/etc.) are " *
              "deferred to a later bead. (CLAUDE.md §1.)")
    end

    # Two distinct non-alias pointer refs represent two distinct
    # link-time addresses. Ref-equality is a sound decider because LLVM
    # canonicalises unique constants within a module context.
    is_equal = (a_ref == b_ref)

    if pred == LLVM.API.LLVMIntEQ
        return iconst(is_equal ? 1 : 0)
    else   # LLVMIntNE
        return iconst(is_equal ? 0 : 1)
    end
end

# Whether a resolved (non-alias) pointer ref has a well-defined
# distinct link-time identity. Used by `_fold_constexpr_operand` to
# gate the ref-equality decider: only kinds in this set are safe to
# compare by ref-equality.
#
# GlobalVariable, Function: each has its own unique address.
# ConstantPointerNull: the unique zero address.
# GlobalAlias is intentionally excluded — it should have been resolved
# by `_resolve_aliasee` before this is called.
# ConstantExpr is intentionally excluded — nested constexprs are
# deferred beyond cc0.4 MVP.
function _is_address_identity_kind(k)::Bool
    return k == LLVM.API.LLVMGlobalVariableValueKind ||
           k == LLVM.API.LLVMFunctionValueKind       ||
           k == LLVM.API.LLVMConstantPointerNullValueKind
end
```

And the patched `_operand` (line 1751–1761 today, after patch):

```julia
function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(convert(Int, val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)
    elseif val isa LLVM.ConstantExpr
        # Bennett-cc0.4: fold pointer-typed `icmp eq/ne` between named
        # globals. Unsupported ConstantExpr shapes raise fail-loud
        # errors citing cc0.4 for extension.
        return _fold_constexpr_operand(val, names)
    else
        r = val.ref
        haskey(names, r) || error("Unknown operand ref for: $(string(val))")
        return ssa(names[r])
    end
end
```

### §L.1 LLVM.jl symbols used, all verified

- `LLVM.ConstantExpr` — registered Julia wrapper type for value kind 10
  (`src/core/value/constant.jl:544–547`).
- `LLVM.API.LLVMGetConstOpcode(ref)` — raw C API, returns
  `LLVM.API.LLVMOpcode` (same enum as instruction opcodes). Found at
  `lib/19/libLLVM.jl:3738–3750` (also present in 17/18).
- `LLVM.API.LLVMGetICmpPredicate(ref)` — raw C API, returns
  `LLVM.API.LLVMIntPredicate`. Found at `lib/19/libLLVM.jl:5478–5488`.
- `LLVM.API.LLVMGetNumOperands(ref)` / `LLVM.API.LLVMGetOperand(ref,
  idx)` — already used in cc0.3 helpers (`ir_extract.jl:1379–1392`).
- `LLVM.API.LLVMGetValueKind(ref)` — used in `_resolve_aliasee`
  (`ir_extract.jl:1365`).
- `LLVM.API.LLVMGlobalAliasValueKind` / `LLVMGlobalVariableValueKind`
  / `LLVMFunctionValueKind` / `LLVMConstantPointerNullValueKind` /
  `LLVMConstantExprValueKind` — `@cenum LLVMValueKind`
  `lib/19/libLLVM.jl:636–665`. cc0.3 already uses the first.
- `LLVM.API.LLVMIntEQ` / `LLVMIntNE` / other `LLVMInt*` predicates —
  `@cenum LLVMIntPredicate` in the same file.
- `LLVM.API.LLVMICmp` / `LLVMBitCast` / `LLVMPtrToInt` / `LLVMIntToPtr`
  / `LLVMGetElementPtr` / `LLVMAddrSpaceCast` / `LLVMTrunc` / `LLVMZExt`
  / `LLVMSExt` / `LLVMSelect` / other `LLVMOpcode` members — `@cenum
  LLVMOpcode` in the same file. Already used throughout `ir_extract.jl`
  for instruction dispatch.
- `_resolve_aliasee(ref)::Union{_LLVMRef, Nothing}` — cc0.3 helper at
  `ir_extract.jl:1358–1372`. Unchanged.
- `_LLVMRef = LLVM.API.LLVMValueRef` — alias at `ir_extract.jl:122`.

No symbol used in this proposal is hallucinated. All are either cited
from the LLVM.jl source or already in active use in `ir_extract.jl`.

---

## §Summary

- **One-point patch**: one new branch in `_operand`, one new helper
  (`_fold_constexpr_operand`) plus a small opcode-name dict and a
  private kind-predicate. ~80 lines total, entirely in
  `src/ir_extract.jl`.
- **Scope**: pointer-typed `icmp eq/ne` between resolved, distinct
  named-global refs. Everything else stays fail-loud.
- **Soundness**: ref-equality on non-alias terminal refs is a correct
  decider because LLVM canonicalises unique constants. Aliases are
  chased via the cc0.3 `_resolve_aliasee`; unresolvable chains fail
  loud.
- **Regression risk**: zero by construction. The new branch is taken
  only on `ConstantExpr` operands; every scalar, vector, and soft-float
  workload in the regression corpus has no `ConstantExpr` operands and
  is byte-identical.
- **Tests**: the bead-supplied `test/test_cc04_repro.jl` is the primary
  RED→GREEN gate. TJ3's `@test_throws` flips to GREEN per the
  commented-out template in `test_t5_corpus_julia.jl`. I recommend one
  additional small file (`test_constexpr_icmp.jl`) with three micro-
  tests covering the decision-table rows the integration test can't
  exercise.
- **Forward compatibility**: the helper is the natural extension point
  for cc0.6's ConstantExpr `ptrtoint` / `inttoptr` shapes — one
  additional branch per new opcode, no scaffolding changes. I
  deliberately do not pre-build cc0.6 scaffolding.
- **CLAUDE.md adherence**: §1 fail-loud (every unsupported shape errors
  with context), §3 red-green (test exists; watch it flip), §5 LLVM IR
  instability (every decision leans on the typed LLVM.jl / raw C API,
  not IR text parsing), §6 gate-count baselines (explicit regression
  argument), §10 skepticism (five distinct error branches, none
  optimistic about input shape), §11 PRD-driven (scope strictly limited
  to the bead), §12 no duplicated lowering (we emit an `iconst`, which
  flows through the existing `resolve!` i1-constant path without any
  new primitive).
