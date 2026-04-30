# ---- Bennett-cc0.7: vector SSA scalarisation ----
#
# LLVM's SLP pass vectorises sequential same-type ops into `<N x iM>` SIMD.
# Bennett has no native vector lowering. We scalarise at the extractor:
# every vector SSA ref maps to N per-lane IROperands in `lanes`; vector ops
# desugar into N independent scalar IRInsts. insertelement / shufflevector
# are pure SSA plumbing (emit nothing, mutate `lanes`). extractelement renames
# via `IRBinOp(:add, lane, 0, w)` — known ~W+2 gates per extract, acceptable
# MVP cost (see `docs/design/cc07_consensus.md` §Choice 4).

# ---- Bennett-cc0.3: LLVMGlobalAlias handling ----
#
# LLVM.jl has no Julia wrapper for LLVMGlobalAliasValueKind (enum 6) — its
# `identify` function raises when `LLVM.Value(ref)` is called on such a ref.
# Julia's runtime emits GlobalAliases liberally for JIT-loaded global slots
# (@"jl_global#NNN.jit") that user code can't meaningfully read. We resolve
# the aliasee via raw C API when possible; otherwise fall back to a sentinel
# that flows through ParsedIR and is rejected fail-loud at lowering time.
# See `docs/design/cc03_05_consensus.md`.

# Sentinel `IROperand` for pointer values the extractor cannot materialise as
# a concrete wire reference. Produced when GlobalAlias resolution fails or
# when a ConstantExpr's sub-operands can't be wrapped. Consumers that treat
# it as user arithmetic fail loud in `lower.jl`'s `resolve!`.
const OPAQUE_PTR_SENTINEL = IROperand(:const, :__opaque_ptr__, 0)

# Follow a GlobalAlias chain via raw C API (LLVM.jl has no `aliasee`
# accessor). Returns the terminal non-alias ref, or nothing on cycles,
# depth overflow, or NULL. Depth cap 16 is well beyond anything Julia emits.
function _resolve_aliasee(ref::_LLVMRef)::Union{_LLVMRef, Nothing}
    ref == C_NULL && return nothing
    seen = Set{_LLVMRef}()
    cur = ref
    for _ in 1:16
        cur in seen && return nothing         # cycle guard
        push!(seen, cur)
        kind = LLVM.API.LLVMGetValueKind(cur)
        kind == LLVM.API.LLVMGlobalAliasValueKind || return cur
        next = LLVM.API.LLVMAliasGetAliasee(cur)
        next == C_NULL && return nothing
        cur = next
    end
    return nothing                            # exceeded depth
end

# Iterate an instruction's operands via raw C API, returning a vector of
# `Union{LLVM.Value, Nothing}`. `nothing` slots represent unresolvable
# GlobalAlias operands or operand kinds LLVM.jl refuses to wrap. Use this
# instead of `LLVM.operands(inst)` at sites where a pointer operand could
# be a GlobalAlias — the regular iterator crashes on alias refs.
function _safe_operands(inst::LLVM.Instruction)::Vector{Union{LLVM.Value, Nothing}}
    n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
    out = Vector{Union{LLVM.Value, Nothing}}(undef, n)
    for i in 0:(n - 1)
        ref = LLVM.API.LLVMGetOperand(inst.ref, i)
        resolved = _resolve_aliasee(ref)
        out[i + 1] = resolved === nothing ? nothing : try
            LLVM.Value(resolved)
        catch e
            e isa InterruptException && rethrow()
            nothing
        end
    end
    return out
end

# `_operand` variant that accepts an optional `Nothing` (from `_safe_operands`)
# and emits the opaque-pointer sentinel for unresolvable operands.
function _operand_safe(val::Union{LLVM.Value, Nothing},
                       names::Dict{_LLVMRef, Symbol})::IROperand
    val === nothing && return OPAQUE_PTR_SENTINEL
    return _operand(val, names)
end

# ---- Bennett-cc0.4 helpers: ConstantExpr operand folding ----
#
# `optimize=true` folds `isnothing()` checks on `Union{T,Nothing}` fields to
# `select i1 icmp eq (ptr @TypeA, ptr @TypeB), ..., ...` — the condition is a
# LLVM.ConstantExpr, which `_operand` otherwise doesn't recognise. MVP scope:
# `icmp eq/ne` on pointer operands that resolve (via cc0.3's `_resolve_aliasee`
# + trivial-cast peeling) to named globals or null. Fold to `iconst(0/1)`;
# consumer width is inferred at lowering time just like `ConstantInt` literals.
# Every other ConstantExpr shape fails loud with a cc0.4 breadcrumb.

# Map ConstantExpr opcode → human-readable name for error messages.
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

# Canonical pointer identity. Julia-JIT emits GlobalAliases whose aliasees
# are `inttoptr (i64 K to ptr)` — literal runtime addresses of type
# descriptors. So a ref-based equality check isn't enough: we must follow
# aliases, peel trivial address-preserving casts, and recognise
# inttoptr-of-const as a numeric address.
#
# Returns a canonical identity tag:
#   (:addr,  K::UInt64)    — absolute address from `inttoptr (i64 K to ptr)`
#   (:named, r::_LLVMRef)  — named global (Function / GlobalVariable / IFunc)
#   (:null,  UInt64(0))    — null pointer
#   nothing                — undecidable (caller fails loud)
function _ptr_identity(ref::_LLVMRef)::Union{Tuple{Symbol, UInt64}, Tuple{Symbol, _LLVMRef}, Nothing}
    ref == C_NULL && return nothing
    cur = ref
    for _ in 1:16
        kind = LLVM.API.LLVMGetValueKind(cur)
        if kind == LLVM.API.LLVMFunctionValueKind ||
           kind == LLVM.API.LLVMGlobalIFuncValueKind ||
           kind == LLVM.API.LLVMGlobalVariableValueKind
            return (:named, cur)
        elseif kind == LLVM.API.LLVMConstantPointerNullValueKind
            return (:null, UInt64(0))
        elseif kind == LLVM.API.LLVMGlobalAliasValueKind
            next = LLVM.API.LLVMAliasGetAliasee(cur)
            next == C_NULL && return nothing
            cur = next
            continue
        elseif kind == LLVM.API.LLVMConstantExprValueKind
            inner_opc = LLVM.API.LLVMGetConstOpcode(cur)
            if inner_opc == LLVM.API.LLVMBitCast ||
               inner_opc == LLVM.API.LLVMAddrSpaceCast
                Int(LLVM.API.LLVMGetNumOperands(cur)) == 1 || return nothing
                inner = LLVM.API.LLVMGetOperand(cur, 0)
                inner == C_NULL && return nothing
                cur = inner
                continue
            elseif inner_opc == LLVM.API.LLVMIntToPtr
                # `inttoptr (i64 K to ptr)` — Julia JIT's typetag aliasee.
                Int(LLVM.API.LLVMGetNumOperands(cur)) == 1 || return nothing
                inner = LLVM.API.LLVMGetOperand(cur, 0)
                inner == C_NULL && return nothing
                inner_val = try
                    LLVM.Value(inner)
                catch e
                    e isa InterruptException && rethrow()
                    return nothing
                end
                inner_val isa LLVM.ConstantInt || return nothing
                return (:addr, UInt64(_const_int_as_int(inner_val) % UInt64))
            else
                return nothing   # ptrtoint / gep / … not handled
            end
        else
            return nothing       # unexpected kind (Argument, Instruction, …)
        end
    end
    return nothing                # chase-depth exhausted
end

# Decide whether two pointer refs denote the same link-time address.
# Returns `nothing` if either identity is undecidable (caller fails loud).
function _ptr_addresses_equal(a::_LLVMRef, b::_LLVMRef)::Union{Bool, Nothing}
    ia = _ptr_identity(a)
    ib = _ptr_identity(b)
    (ia === nothing || ib === nothing) && return nothing
    return ia == ib
end

# Fold a ConstantExpr operand into an IROperand. MVP scope:
#   icmp eq/ne on pointer operands → iconst(0/1)
# Everything else fails loud with a cc0.4 breadcrumb.
function _fold_constexpr_operand(ce::LLVM.ConstantExpr,
                                 names::Dict{_LLVMRef, Symbol})::IROperand
    opc = LLVM.API.LLVMGetConstOpcode(ce.ref)

    if opc == LLVM.API.LLVMPtrToInt || opc == LLVM.API.LLVMIntToPtr
        error("ir_extract.jl: Bennett-cc0.4/cc0.6: ConstantExpr<" *
              "$(_constexpr_opcode_name(opc))> in operand position requires " *
              "ptrtoint/inttoptr handling (cc0.6 scope). Operand: $(string(ce)).")
    end

    if opc != LLVM.API.LLVMICmp
        error("ir_extract.jl: Bennett-cc0.4: unhandled ConstantExpr opcode " *
              "`$(_constexpr_opcode_name(opc))` in operand position. " *
              "Operand: $(string(ce)). File a new bead extending cc0.4 with " *
              "a minimal repro.")
    end

    pred = LLVM.API.LLVMGetICmpPredicate(ce.ref)
    pred in (LLVM.API.LLVMIntEQ, LLVM.API.LLVMIntNE) ||
        error("ir_extract.jl: Bennett-cc0.4: ConstantExpr<icmp $pred> with " *
              "ordering predicate is not foldable at extraction time (pointer " *
              "address ordering is allocator-dependent). Operand: $(string(ce)). " *
              "File a new bead extending cc0.4 if this arises in real code.")

    n = Int(LLVM.API.LLVMGetNumOperands(ce.ref))
    n == 2 ||
        error("ir_extract.jl: Bennett-cc0.4: ConstantExpr<icmp> with $n operands " *
              "(expected 2): $(string(ce))")

    a_raw = LLVM.API.LLVMGetOperand(ce.ref, 0)
    b_raw = LLVM.API.LLVMGetOperand(ce.ref, 1)

    eq = _ptr_addresses_equal(a_raw, b_raw)
    eq === nothing && error(
        "ir_extract.jl: Bennett-cc0.4: ConstantExpr<icmp eq/ne> cannot be " *
        "statically decided — one or both operands did not resolve to a " *
        "canonical pointer identity (named global, null, or `inttoptr " *
        "(i64 K to ptr)`). Operand: $(string(ce)). File a new bead extending " *
        "cc0.4 with a minimal repro.")

    result_true = (pred == LLVM.API.LLVMIntEQ) ? eq : !eq
    return iconst(result_true ? 1 : 0)
end

