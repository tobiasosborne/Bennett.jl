# Bennett-k7al / U99: validation tables for the IR instruction structs.
# Listed once here so a typo (`:slt` vs `:lt`, `:zxt` vs `:zext`) fails
# at construction time with a clear error, not 500 lines later during
# lowering when the elseif chain falls through.
const _IR_OPERAND_KINDS = (:ssa, :const)
const _IR_BINOP_OPS     = (:add, :sub, :mul, :and, :or, :xor,
                           :shl, :lshr, :ashr,
                           :udiv, :sdiv, :urem, :srem)
const _IR_ICMP_PREDS    = (:eq, :ne,
                           :ult, :ule, :ugt, :uge,
                           :slt, :sle, :sgt, :sge)
const _IR_CAST_OPS      = (:sext, :zext, :trunc)

# --- Operand: SSA variable or integer constant ---

struct IROperand
    kind::Symbol       # :ssa or :const
    name::Symbol       # SSA name (if :ssa)
    value::Int         # constant value (if :const)
    function IROperand(kind::Symbol, name::Symbol, value::Int)
        kind in _IR_OPERAND_KINDS ||
            error("IROperand: kind=:$kind not in $_IR_OPERAND_KINDS")
        new(kind, name, value)
    end
end

ssa(name::Symbol)    = IROperand(:ssa, name, 0)
iconst(value::Int)   = IROperand(:const, Symbol(""), value)

# --- Instructions ---

abstract type IRInst end

struct IRBinOp <: IRInst
    dest::Symbol
    op::Symbol         # :add, :sub, :mul, :and, :or, :xor, :shl, :lshr, :ashr,
                       # :udiv, :sdiv, :urem, :srem (see _IR_BINOP_OPS)
    op1::IROperand
    op2::IROperand
    width::Int
    function IRBinOp(dest::Symbol, op::Symbol, op1::IROperand, op2::IROperand, width::Int)
        op in _IR_BINOP_OPS ||
            error("IRBinOp: op=:$op not in $_IR_BINOP_OPS (dest=$dest)")
        width >= 1 ||
            error("IRBinOp: width=$width must be >= 1 (dest=$dest, op=:$op)")
        new(dest, op, op1, op2, width)
    end
end

struct IRICmp <: IRInst
    dest::Symbol
    predicate::Symbol  # see _IR_ICMP_PREDS
    op1::IROperand
    op2::IROperand
    width::Int         # width of operands (result is always i1)
    function IRICmp(dest::Symbol, predicate::Symbol, op1::IROperand, op2::IROperand, width::Int)
        predicate in _IR_ICMP_PREDS ||
            error("IRICmp: predicate=:$predicate not in $_IR_ICMP_PREDS (dest=$dest)")
        width >= 1 ||
            error("IRICmp: width=$width must be >= 1 (dest=$dest, predicate=:$predicate)")
        new(dest, predicate, op1, op2, width)
    end
end

struct IRSelect <: IRInst
    dest::Symbol
    cond::IROperand    # i1
    op1::IROperand     # true value
    op2::IROperand     # false value
    width::Int         # width of result; 0 is the Bennett-cc0 M2b pointer
                       # sentinel — pointer-typed selects don't materialise
                       # as wires (routing lives in ptr_provenance).
    function IRSelect(dest::Symbol, cond::IROperand, op1::IROperand, op2::IROperand, width::Int)
        width >= 0 ||
            error("IRSelect: width=$width must be >= 0 (dest=$dest); " *
                  "use 0 only for pointer-typed selects")
        new(dest, cond, op1, op2, width)
    end
end

struct IRRet <: IRInst
    op::IROperand
    width::Int
    function IRRet(op::IROperand, width::Int)
        width >= 1 ||
            error("IRRet: width=$width must be >= 1")
        new(op, width)
    end
end

struct IRInsertValue <: IRInst
    dest::Symbol
    agg::IROperand       # aggregate operand (or :zero for zeroinitializer)
    val::IROperand       # value to insert
    index::Int           # 0-based element index
    elem_width::Int      # bit width of each element
    n_elems::Int         # number of elements in the aggregate
end

# --- v0.3: branch, phi, basic blocks ---

struct IRCast <: IRInst
    dest::Symbol
    op::Symbol         # see _IR_CAST_OPS
    operand::IROperand
    from_width::Int
    to_width::Int
    function IRCast(dest::Symbol, op::Symbol, operand::IROperand,
                    from_width::Int, to_width::Int)
        op in _IR_CAST_OPS ||
            error("IRCast: op=:$op not in $_IR_CAST_OPS (dest=$dest)")
        from_width >= 1 ||
            error("IRCast: from_width=$from_width must be >= 1 (dest=$dest, op=:$op)")
        to_width >= 1 ||
            error("IRCast: to_width=$to_width must be >= 1 (dest=$dest, op=:$op)")
        new(dest, op, operand, from_width, to_width)
    end
end

struct IRPtrOffset <: IRInst
    dest::Symbol
    base::IROperand     # pointer SSA name
    offset_bytes::Int   # byte offset from base
end

struct IRVarGEP <: IRInst
    dest::Symbol
    base::IROperand     # pointer SSA name (flat wire array)
    index::IROperand    # 0-based element index (runtime SSA)
    elem_width::Int     # bit width per element
end

struct IRLoad <: IRInst
    dest::Symbol
    ptr::IROperand      # pointer (or ptr+offset SSA name)
    width::Int          # load width in bits
    function IRLoad(dest::Symbol, ptr::IROperand, width::Int)
        width >= 1 ||
            error("IRLoad: width=$width must be >= 1 (dest=$dest)")
        new(dest, ptr, width)
    end
end

# --- memory writes ---
# IRStore produces no SSA value (void in LLVM); matches IRBranch/IRRet convention
# by omitting `dest`. Existing `hasproperty(inst, :dest)` guards in lower.jl /
# dep_dag.jl / liveness analysis handle dest-less instructions uniformly.
struct IRStore <: IRInst
    ptr::IROperand      # destination pointer (SSA, resolved via vw)
    val::IROperand      # value to store (SSA or constant)
    width::Int          # stored value width in bits (i1-aware via narrow guard)
    function IRStore(ptr::IROperand, val::IROperand, width::Int)
        width >= 1 ||
            error("IRStore: width=$width must be >= 1")
        new(ptr, val, width)
    end
end

# IRAlloca produces a pointer SSA value. `n_elems::IROperand` mirrors
# IRVarGEP.index — :const for static allocas, :ssa for dynamic. Static-only at
# lower time; dynamic is rejected with a clear error until a shadow-memory or
# conservative-upper-bound strategy is implemented (T3b).
struct IRAlloca <: IRInst
    dest::Symbol         # SSA name of produced pointer
    elem_width::Int      # bit width per element
    n_elems::IROperand   # :const for static, :ssa for dynamic
    function IRAlloca(dest::Symbol, elem_width::Int, n_elems::IROperand)
        elem_width >= 1 ||
            error("IRAlloca: elem_width=$elem_width must be >= 1 (dest=$dest)")
        new(dest, elem_width, n_elems)
    end
end

struct IRExtractValue <: IRInst
    dest::Symbol
    agg::IROperand       # aggregate operand
    index::Int           # 0-based element index
    elem_width::Int      # bit width of each element
    n_elems::Int         # number of elements in the aggregate
end

struct IRCall <: IRInst
    dest::Symbol
    callee::Function       # Julia function to compile and inline
    args::Vector{IROperand}
    arg_widths::Vector{Int}
    ret_width::Int
    function IRCall(dest::Symbol, callee::Function, args::Vector{IROperand},
                    arg_widths::Vector{Int}, ret_width::Int)
        length(args) == length(arg_widths) ||
            error("IRCall: length(args)=$(length(args)) != length(arg_widths)=$(length(arg_widths)) " *
                  "(dest=$dest, callee=$(nameof(callee)))")
        # Bennett-2yky / U130 investigation: a tighter upper bound (e.g.
        # `<= 64` per Bennett-zmw3 / U111) was tested and reverted —
        # NTuple aggregate returns (e.g. NTuple{9,UInt64} ⇒ 576 bits)
        # are legitimately wider than 64. The Bennett-zmw3 contract
        # applies to the SCALAR `:const` path inside `resolve!`, not to
        # IRCall arg widths derived from `_iwidth` / aggregate
        # `_type_width`. Lower bounds + length match suffice here.
        ret_width >= 1 ||
            error("IRCall: ret_width=$ret_width must be >= 1 (dest=$dest, callee=$(nameof(callee)))")
        for (i, w) in enumerate(arg_widths)
            w >= 1 ||
                error("IRCall: arg_widths[$i]=$w must be >= 1 (dest=$dest, callee=$(nameof(callee)))")
        end
        new(dest, callee, args, arg_widths, ret_width)
    end
end

struct IRBranch <: IRInst
    cond::Union{IROperand, Nothing}      # nothing for unconditional
    true_label::Symbol
    false_label::Union{Symbol, Nothing}  # nothing for unconditional
end

struct IRSwitch <: IRInst
    cond::IROperand                                   # value being switched on
    cond_width::Int                                    # bit width of condition
    default_label::Symbol                              # default target
    cases::Vector{Tuple{IROperand, Symbol}}            # (case_val, target_label)
end

struct IRPhi <: IRInst
    dest::Symbol
    width::Int          # 0 is the Bennett-cc0 M2b pointer sentinel — same
                        # convention as IRSelect.
    incoming::Vector{Tuple{IROperand, Symbol}}  # (value, from_block)
    function IRPhi(dest::Symbol, width::Int, incoming::Vector{Tuple{IROperand, Symbol}})
        width >= 0 ||
            error("IRPhi: width=$width must be >= 0 (dest=$dest); " *
                  "use 0 only for pointer-typed phis")
        isempty(incoming) &&
            error("IRPhi: incoming is empty (dest=$dest); a phi with no predecessors is malformed")
        new(dest, width, incoming)
    end
end

# Bennett-cc0 M2b — pointer provenance entry. Represents one possible origin
# of a pointer SSA value: the backing alloca, the element index within it,
# and the path-predicate wire that is true on the control-flow path under
# which this origin is the live value of the pointer.
#
# `ptr_provenance[name]::Vector{PtrOrigin}` — exactly one origin per pointer
# in the common (pre-M2b) case; multiple origins for pointers merged by a
# pointer-typed phi or select. When lowering a store/load through a
# multi-origin pointer, each origin gets a guarded shadow write/read keyed
# on its own `predicate_wire`; at runtime exactly one origin's predicate is
# true, so exactly one primal register is touched.
#
# For single-origin producers (alloca, GEP of known alloca), the
# `predicate_wire` is `ctx.block_pred[ctx.entry_label][1]` — the trivial
# "always-1" entry predicate, which preserves every BENCHMARKS.md baseline.
struct PtrOrigin
    alloca_dest::Symbol    # which alloca this origin points into
    idx_op::IROperand      # element index within that alloca
    predicate_wire::Int    # 1-wire path predicate
end

struct IRBasicBlock
    label::Symbol
    instructions::Vector{IRInst}  # non-terminator instructions
    terminator::IRInst             # IRBranch or IRRet
end

# --- MemorySSA type bundle (Bennett-by8j / U44) ---
#
# Defined here in ir_types.jl, ahead of ParsedIR, so the
# `memssa::Union{Nothing, MemSSAInfo}` field below is concretely
# typed.  Previously the field was `::Any` because src/memssa.jl was
# included AFTER ir_types.jl and the textual struct definition lived
# there; that forced ParsedIR to be type-unstable on every memssa
# read.  Parsing methods (`parse_memssa_annotations`) stay in
# `src/memssa.jl`; only the type definition + zero-arg constructor
# move here.
"""
    MemSSAInfo

Parsed `print<memoryssa>` annotations.  Indexed by 1-based line number
of the annotated instruction within `annotated_ir` so downstream
consumers can correlate to LLVM.jl's instruction walk (same instruction
ordering, same module).

Fields:
- `def_at_line` — line → MemoryDef id
- `def_clobber` — Def id → clobbered Def id (or `:live_on_entry` sentinel)
- `use_at_line` — line → Def id this use reads from
- `phis` — Phi id → `[(incoming_block, incoming_id), …]`
- `annotated_ir` — raw annotated text (kept for debugging)

IDs (`Int`) match LLVM's numbering; `:live_on_entry` is the sentinel
for memory state at function entry.
"""
struct MemSSAInfo
    def_at_line::Dict{Int, Int}
    def_clobber::Dict{Int, Union{Int, Symbol}}
    use_at_line::Dict{Int, Int}
    phis::Dict{Int, Vector{Tuple{Symbol, Int}}}
    annotated_ir::String
end

MemSSAInfo() = MemSSAInfo(Dict{Int,Int}(), Dict{Int,Union{Int,Symbol}}(),
                           Dict{Int,Int}(), Dict{Int,Vector{Tuple{Symbol,Int}}}(),
                           "")

# --- Parsed IR bundle ---

struct ParsedIR
    ret_width::Int
    args::Vector{Tuple{Symbol, Int}}
    blocks::Vector{IRBasicBlock}
    ret_elem_widths::Vector{Int}   # [8] for i8, [8,8] for [2 x i8]
    # T1c.2 globals: compile-time-constant arrays. Maps global name (as extracted
    # from LLVM, e.g. `_j_const#1`) to (data_words, elem_width). `data_words[i+1]`
    # is the i-th element of the array, zero-extended into UInt64. Used by
    # lower_var_gep! to dispatch to QROM when the GEP base is a global constant.
    globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}
    # T2a.2 memssa: parsed MemorySSA annotations (nothing unless
    # extract_parsed_ir was called with use_memory_ssa=true).  Bennett-by8j
    # / U44: typed concretely as Union{Nothing, MemSSAInfo} after
    # MemSSAInfo's definition was moved here above ParsedIR.
    memssa::Union{Nothing, MemSSAInfo}
    _instructions_cache::Vector{IRInst}  # cached flattened instructions for backward compat
end

# Constructor without cache or globals (auto-computes, empty globals, no memssa)
function ParsedIR(ret_width::Int, args::Vector{Tuple{Symbol, Int}},
                  blocks::Vector{IRBasicBlock}, ret_elem_widths::Vector{Int})
    ParsedIR(ret_width, args, blocks, ret_elem_widths,
             Dict{Symbol, Tuple{Vector{UInt64}, Int}}(), nothing)
end

# Constructor with globals but no memssa
function ParsedIR(ret_width::Int, args::Vector{Tuple{Symbol, Int}},
                  blocks::Vector{IRBasicBlock}, ret_elem_widths::Vector{Int},
                  globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}})
    ParsedIR(ret_width, args, blocks, ret_elem_widths, globals, nothing)
end

# Full constructor (auto-computes instructions cache)
function ParsedIR(ret_width::Int, args::Vector{Tuple{Symbol, Int}},
                  blocks::Vector{IRBasicBlock}, ret_elem_widths::Vector{Int},
                  globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}},
                  memssa)
    insts = IRInst[]
    for block in blocks
        append!(insts, block.instructions)
        push!(insts, block.terminator)
    end
    ParsedIR(ret_width, args, blocks, ret_elem_widths, globals, memssa, insts)
end

# Backward compat: parsed.instructions returns cached flattened list
function Base.getproperty(p::ParsedIR, name::Symbol)
    if name === :instructions
        return getfield(p, :_instructions_cache)
    else
        return getfield(p, name)
    end
end

Base.propertynames(::ParsedIR) = (:ret_width, :args, :blocks, :instructions,
                                   :ret_elem_widths, :globals, :memssa)
