# --- Operand: SSA variable or integer constant ---

struct IROperand
    kind::Symbol       # :ssa or :const
    name::Symbol       # SSA name (if :ssa)
    value::Int         # constant value (if :const)
end

ssa(name::Symbol)    = IROperand(:ssa, name, 0)
iconst(value::Int)   = IROperand(:const, Symbol(""), value)

# --- Instructions ---

abstract type IRInst end

struct IRBinOp <: IRInst
    dest::Symbol
    op::Symbol         # :add, :sub, :mul, :and, :or, :xor, :shl, :lshr, :ashr
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IRICmp <: IRInst
    dest::Symbol
    predicate::Symbol  # :eq, :ne, :ult, :slt, :ugt, :sgt, :ule, :sle, :uge, :sge
    op1::IROperand
    op2::IROperand
    width::Int         # width of operands (result is always i1)
end

struct IRSelect <: IRInst
    dest::Symbol
    cond::IROperand    # i1
    op1::IROperand     # true value
    op2::IROperand     # false value
    width::Int         # width of result
end

struct IRRet <: IRInst
    op::IROperand
    width::Int
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
    op::Symbol         # :sext, :zext, :trunc
    operand::IROperand
    from_width::Int
    to_width::Int
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
end

# --- memory writes ---
# IRStore produces no SSA value (void in LLVM); matches IRBranch/IRRet convention
# by omitting `dest`. Existing `hasproperty(inst, :dest)` guards in lower.jl /
# dep_dag.jl / liveness analysis handle dest-less instructions uniformly.
struct IRStore <: IRInst
    ptr::IROperand      # destination pointer (SSA, resolved via vw)
    val::IROperand      # value to store (SSA or constant)
    width::Int          # stored value width in bits (i1-aware via narrow guard)
end

# IRAlloca produces a pointer SSA value. `n_elems::IROperand` mirrors
# IRVarGEP.index — :const for static allocas, :ssa for dynamic. Static-only at
# lower time; dynamic is rejected with a clear error until a shadow-memory or
# conservative-upper-bound strategy is implemented (T3b).
struct IRAlloca <: IRInst
    dest::Symbol         # SSA name of produced pointer
    elem_width::Int      # bit width per element
    n_elems::IROperand   # :const for static, :ssa for dynamic
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
    width::Int
    incoming::Vector{Tuple{IROperand, Symbol}}  # (value, from_block)
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
