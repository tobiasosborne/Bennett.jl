# ---- helpers ----

"""Get the dereferenceable byte count from a pointer parameter, or 0 if no
`dereferenceable(N)` attribute is present on the parameter's slot.

Bennett-8b2f / U17: the IR-string fallback previously did
`match(r"dereferenceable\\((\\d+)\\)", defline)` — function-wide,
returning the FIRST N on the `define` line regardless of which
parameter was being queried. On multi-ptr functions where the params
had different dereferenceable counts (or where some had none), every
call returned the same first-found value → phantom input-wire widths
for non-matching params. Fix: anchor the fallback regex to the specific
`%paramname`, matching `dereferenceable\\((\\d+)\\)[^,)]*%NAME\\b` which
walks within a single param slot (bounded by `,` / `)`).

Bennett-zyjn / U94: previously returned 0 for THREE distinct outcomes
— (a) param not in func, (b) defline malformed, (c) param has no
`dereferenceable(N)` attribute — collapsing two caller-side / format-
mismatch BUGS into the same silent value as the legitimate "no attr"
case. Now (a) and (b) `error()` with attribution; only (c) returns 0.
"""
function _get_deref_bytes(func::LLVM.Function, param::LLVM.Argument)
    # Bennett-zyjn / U94: this function used to return 0 for THREE
    # distinct outcomes — (a) param not in func, (b) defline missing
    # `(...)` parameter list, (c) param found but has no
    # `dereferenceable(N)` attribute on its slot. Bugs (a) and (b) now
    # error() with attribution; only (c) — the legitimate "no attr"
    # case — returns 0. Caller's `deref > 0` check is unchanged.

    # Find the parameter index (1-based)
    idx = 0
    for p in LLVM.parameters(func)
        idx += 1
        p.ref == param.ref && @goto found_param
    end
    error("_get_deref_bytes: parameter $(LLVM.name(param)) is not in " *
          "func=@$(LLVM.name(func)) parameter list (caller-side miswiring; " *
          "Bennett-zyjn / U94)")
    @label found_param
    # Check parameter attributes for dereferenceable(N)
    try
        for attr in LLVM.parameter_attributes(func, idx)
            s = string(attr)
            m = match(r"dereferenceable\((\d+)\)", s)
            if m !== nothing
                return parse(Int, m.captures[1])
            end
        end
    catch e
        e isa InterruptException && rethrow()
        e isa MethodError || rethrow()
    end
    # Fallback: walk the param slot list on the `define` line and read
    # `dereferenceable(N)` only from the slot whose `%NAME` matches.
    # Regex is fragile here because Julia mangled names arrive as
    # `%"t::Tuple"` with quotes — a simple `%NAME\b` won't match.
    # Slice by parameter, then look for both `%NAME` and `%"NAME"`.
    ir_str = string(func)
    defline = split(ir_str, "\n")[1]
    pname = LLVM.name(param)
    # Extract the (...) parameter list. A missing or out-of-order pair is
    # an LLVM.jl format mismatch — fail loud rather than silently returning 0.
    lp = findfirst('(', defline)
    rp = findlast(')', defline)
    (lp === nothing || rp === nothing || lp >= rp) && error(
        "_get_deref_bytes: malformed `define` line for func=@$(LLVM.name(func)); " *
        "could not locate the parameter list `(...)`. " *
        "LLVM.jl `string(func)` may have changed format. (Bennett-zyjn / U94)\n  " *
        "defline: $defline")
    param_list = defline[lp+1:rp-1]
    # Split on top-level commas. Paren nesting within a slot (e.g.
    # `sret([2 x i64])`, `dereferenceable(16)`) must not split the slot.
    slots = String[]
    depth = 0
    slot_start = 1
    for (i, c) in pairs(param_list)
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
        elseif c == ',' && depth == 0
            push!(slots, param_list[slot_start:prevind(param_list, i)])
            slot_start = nextind(param_list, i)
        end
    end
    push!(slots, param_list[slot_start:end])
    # Find the slot containing our %NAME (quoted or bare).
    needle_q = "%\"" * pname * "\""
    needle_b = "%" * pname
    for slot in slots
        has_q = occursin(needle_q, slot)
        has_b = !has_q && (occursin(" " * needle_b, slot) ||
                           startswith(strip(slot), needle_b))
        if has_q || has_b
            m = match(r"dereferenceable\((\d+)\)", slot)
            return m === nothing ? 0 : parse(Int, m.captures[1])
        end
    end
    return 0
end

"""
    _const_int_as_int(v::LLVM.ConstantInt) -> Int

Bennett-l9cl / U09: LLVM.jl's `convert(Int, ::ConstantInt)` uses the C API
`LLVMConstIntGetSExtValue`, which returns only the low 64 bits; any wider
constant is silently truncated (`i128 2^127` → 0). IROperand.value is Int64,
so there is no safe place for a >64-bit constant to go. Fail loud until
IROperand widens to Int128/BigInt (tracked in U09 bead).
"""
@inline function _const_int_as_int(v::LLVM.ConstantInt)
    w = LLVM.width(LLVM.value_type(v))
    w > 64 && error(
        "ir_extract.jl: ConstantInt with width $w bits encountered (>64); " *
        "LLVM.jl `convert(Int, ::ConstantInt)` silently truncates to the low " *
        "64 bits and IROperand.value is Int64 — widen IROperand to " *
        "Int128/BigInt before enabling i128+ constants (Bennett-l9cl / U09)." *
        "\n  Source constant: $(string(v))")
    return convert(Int, v)
end

function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(_const_int_as_int(val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)  # special: zero aggregate
    elseif val isa LLVM.ConstantExpr
        # Bennett-cc0.4: fold statically-decidable ConstantExprs (today:
        # pointer-typed icmp eq/ne between named globals) to i1 literals.
        return _fold_constexpr_operand(val, names)
    elseif val isa LLVM.ConstantFP
        # Bennett-bjdg / U80: floating-point constant in operand position.
        # Bennett.jl extracts integer values and routes Float64 arithmetic
        # through the SoftFloat dispatcher (src/Bennett.jl:380+); raw
        # ConstantFP operands have no canonical integer encoding here.
        # Pre-bjdg this fell through to the misleading "unknown operand
        # ref ... producing instruction was skipped" error.
        error("ir_extract.jl: ConstantFP operand not supported: " *
              "$(string(val)) — Bennett.jl does not lower raw " *
              "floating-point constants. Wrap in `SoftFloat(...)` at the " *
              "call site, or change the function to take/return integer " *
              "types. See src/Bennett.jl:380+ for the SoftFloat dispatch " *
              "path. (Bennett-bjdg / U80)")
    elseif val isa LLVM.PoisonValue
        # Bennett-bjdg / U80: poison operand. Per LLVM LangRef poison is
        # undefined behavior on observation; reading it is never legal.
        error("ir_extract.jl: PoisonValue operand: $(string(val)) — " *
              "reading poison is undefined behavior per LLVM LangRef. " *
              "This usually means a prior instruction produced poison " *
              "(integer overflow flagged with `nsw`/`nuw`, divide by " *
              "zero, etc.) and the result is being consumed without a " *
              "guard. Bennett.jl rejects poison operands to fail fast. " *
              "(Bennett-bjdg / U80)")
    elseif val isa LLVM.UndefValue
        # Bennett-bjdg / U80: undef operand (UndefValue, not the
        # PoisonValue subclass — the latter caught above). Implementation-
        # defined per LLVM LangRef; Bennett.jl rejects to fail fast per
        # CLAUDE.md §1.
        error("ir_extract.jl: UndefValue operand: $(string(val)) — " *
              "reading undef is implementation-defined per LLVM LangRef. " *
              "Bennett.jl rejects undef operands to fail fast " *
              "(CLAUDE.md §1). (Bennett-bjdg / U80)")
    else
        # Bennett-bjdg / U80: precise check for ConstantPointerNull
        # (LLVM.jl doesn't expose a Julia-level type for it, so use the
        # value-kind C API). Anything else still in this branch is a
        # genuinely-unknown SSA ref — the original error message applies.
        r = val.ref
        if r != C_NULL
            kind = LLVM.API.LLVMGetValueKind(r)
            if kind == LLVM.API.LLVMConstantPointerNullValueKind
                error("ir_extract.jl: ConstantPointerNull operand: " *
                      "$(string(val)) — null-pointer dereference. " *
                      "Bennett.jl does not currently lower null-pointer " *
                      "operands. (Bennett-bjdg / U80)")
            end
        end
        haskey(names, r) || error(
            "ir_extract.jl: unknown operand ref for: $(string(val)) — the " *
            "producing instruction was skipped or is not yet supported; " *
            "check the cc0.x gaps in the extractor")
        return ssa(names[r])
    end
end

function _iwidth(val)
    tp = LLVM.value_type(val)
    _type_width(tp)
end

function _type_width(tp)
    if tp isa LLVM.IntegerType
        return LLVM.width(tp)
    elseif tp isa LLVM.ArrayType
        return LLVM.length(tp) * _type_width(LLVM.eltype(tp))
    elseif tp isa LLVM.FloatingPointType
        # IEEE 754: half=16, float=32, double=64
        tp isa LLVM.LLVMDouble && return 64
        tp isa LLVM.LLVMFloat  && return 32
        tp isa LLVM.LLVMHalf   && return 16
        error("ir_extract.jl: unsupported float type for width query: $tp")
    elseif tp isa LLVM.VectorType
        # Bennett-qmk6 / U82: precise error for vector-typed values reaching
        # the scalar width-query path. Vector lanes have their own dedicated
        # extractors (`_vector_shape`, `_resolve_vec_lanes`) used by the
        # cc0.7 vector-handling code; if a value is asking for a scalar
        # width when its type is a vector, the caller is on the wrong path.
        error("ir_extract.jl: VectorType $(tp) reached scalar _type_width — " *
              "vectors are extracted via `_vector_shape` / `_resolve_vec_lanes` " *
              "(Bennett-cc0.7 MVP). If you got here from a vector return type, " *
              "Bennett.jl does not yet support vector-valued returns. " *
              "(Bennett-qmk6 / U82)")
    elseif tp isa LLVM.StructType
        # Bennett-qmk6 / U82 (related): struct-typed values can't be encoded
        # as a single width. They're handled either via sret (the caller
        # passes a pointer to the struct as an extra argument) or via
        # `extractvalue` / `insertvalue` after extraction. A bare struct
        # arriving at scalar _type_width means the surrounding dispatch
        # missed the aggregate case.
        error("ir_extract.jl: StructType $(tp) reached scalar _type_width — " *
              "structs are aggregate values; pass via sret or unpack with " *
              "extractvalue. (Bennett-qmk6 / U82)")
    elseif tp isa LLVM.VoidType
        # Bennett-dq8l / U81: void return type reaching _type_width means a
        # void-returning instruction is being treated as a value-producing
        # instruction. Likely a void call or store handler missed its
        # branch. Pre-fix this fell through to the generic message.
        error("ir_extract.jl: VoidType reached _type_width — caller is " *
              "querying the width of a void value (likely a void-returning " *
              "call or a store/branch instruction). Void instructions don't " *
              "produce SSA values; the surrounding dispatch should special-case " *
              "them upstream. (Bennett-dq8l / U81)")
    else
        error("ir_extract.jl: unsupported LLVM type for width query: $tp")
    end
end

const _OPCODE_MAP = Dict(
    LLVM.API.LLVMAdd  => :add,  LLVM.API.LLVMSub  => :sub,
    LLVM.API.LLVMMul  => :mul,  LLVM.API.LLVMAnd  => :and,
    LLVM.API.LLVMOr   => :or,   LLVM.API.LLVMXor  => :xor,
    LLVM.API.LLVMShl  => :shl,  LLVM.API.LLVMLShr => :lshr,
    LLVM.API.LLVMAShr => :ashr,
)
_opcode_to_sym(opc) = _OPCODE_MAP[opc]

const _PRED_MAP = Dict(
    LLVM.API.LLVMIntEQ  => :eq,  LLVM.API.LLVMIntNE  => :ne,
    LLVM.API.LLVMIntULT => :ult, LLVM.API.LLVMIntUGT => :ugt,
    LLVM.API.LLVMIntULE => :ule, LLVM.API.LLVMIntUGE => :uge,
    LLVM.API.LLVMIntSLT => :slt, LLVM.API.LLVMIntSGT => :sgt,
    LLVM.API.LLVMIntSLE => :sle, LLVM.API.LLVMIntSGE => :sge,
)
_pred_to_sym(pred) = _PRED_MAP[pred]
