module Bennett

include("ir_types.jl")
include("ir_extract.jl")
include("ir_parser.jl")
include("gates.jl")
include("wire_allocator.jl")
include("adder.jl")
include("qcla.jl")
include("multiplier.jl")
include("lower.jl")
include("bennett_transform.jl")
include("simulator.jl")
include("diagnostics.jl")
include("controlled.jl")
include("dep_dag.jl")
include("pebbling.jl")
include("eager.jl")
include("value_eager.jl")
include("pebbled_groups.jl")
include("sat_pebbling.jl")
include("divider.jl")
include("softfloat/softfloat.jl")
include("softmem.jl")
include("qrom.jl")
include("tabulate.jl")
include("memssa.jl")
include("feistel.jl")
include("shadow_memory.jl")
include("fast_copy.jl")
include("partial_products.jl")
include("parallel_adder_tree.jl")
include("mul_qcla_tree.jl")

export reversible_compile, simulate, extract_ir, parse_ir, extract_parsed_ir, register_callee!
export soft_fadd, soft_fsub, soft_fmul, soft_fma, soft_fdiv, soft_fsqrt, soft_fneg, soft_fcmp_olt, soft_fcmp_oeq, soft_fcmp_ole, soft_fcmp_une, soft_fptosi, soft_sitofp, soft_fpext, soft_fptrunc, soft_exp, soft_exp2, soft_exp_fast, soft_exp2_fast
export ReversibleCircuit, ControlledCircuit, controlled
export gate_count, ancilla_count, constant_wire_count, depth, t_count, t_depth, toffoli_depth, peak_live_wires, print_circuit, verify_reversibility
export pebbled_bennett, eager_bennett, value_eager_bennett, pebbled_group_bennett, checkpoint_bennett

reversible_compile(f, types::Type...; kw...) = reversible_compile(f, Tuple{types...}; kw...)

"""
    reversible_compile(f, arg_types::Type{<:Tuple}) -> ReversibleCircuit

Compile a plain Julia function into a reversible circuit via LLVM IR.
Uses LLVM.jl to walk the IR as typed objects (no regex parsing).
"""
function reversible_compile(f, arg_types::Type{<:Tuple};
                            optimize::Bool=true, max_loop_iterations::Int=0,
                            compact_calls::Bool=false, bit_width::Int=0,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            strategy::Symbol=:auto)
    strategy in (:auto, :tabulate, :expression) ||
        error("reversible_compile: unknown strategy :$strategy; " *
              "supported: :auto, :tabulate, :expression")

    # Explicit tabulate: evaluate f classically on all 2^W inputs and emit as
    # a QROM lookup. Skip IR extraction entirely.
    if strategy === :tabulate
        ok, reason = _tabulate_applicable(arg_types, bit_width)
        ok || error("reversible_compile: strategy=:tabulate not applicable — $reason")
        widths = _tabulate_input_widths(arg_types, bit_width)
        out_width = bit_width > 0 ? bit_width : sizeof(arg_types.parameters[1]) * 8
        lr = lower_tabulate(f, arg_types, widths; out_width)
        return bennett(lr)
    end

    # Expression path (also base for :auto). Extract IR once; the cost model
    # inspects it to decide whether to redirect to tabulate.
    parsed = extract_parsed_ir(f, arg_types; optimize)

    if strategy === :auto && _tabulate_auto_picks(parsed, arg_types, bit_width)
        widths = _tabulate_input_widths(arg_types, bit_width)
        out_width = bit_width > 0 ? bit_width : sizeof(arg_types.parameters[1]) * 8
        lr = lower_tabulate(f, arg_types, widths; out_width)
        return bennett(lr)
    end

    if bit_width > 0
        parsed = _narrow_ir(parsed, bit_width)
    end
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul)
    return bennett(lr)
end

"""
    _narrow_ir(parsed::ParsedIR, W::Int) -> ParsedIR

Narrow all widths in a ParsedIR to W bits. This enables compiling
functions written for Int8 as if they operated on W-bit integers.
All arithmetic wraps modulo 2^W.
"""
function _narrow_ir(parsed::ParsedIR, W::Int)
    # Narrow arguments
    new_args = [(name, W) for (name, _) in parsed.args]
    # Narrow all instructions
    new_blocks = IRBasicBlock[]
    for block in parsed.blocks
        new_insts = IRInst[]
        for inst in block.instructions
            push!(new_insts, _narrow_inst(inst, W))
        end
        new_term = _narrow_inst(block.terminator, W)
        push!(new_blocks, IRBasicBlock(block.label, new_insts, new_term))
    end
    return ParsedIR(W, new_args, new_blocks, [W for _ in parsed.ret_elem_widths])
end

# i1 boolean values (from icmp, short-circuit &&/||, boolean ternaries) must
# stay i1 under narrowing — the width is logical, not numeric. Matches the
# IRPhi / IRCast guard.
_narrow_inst(inst::IRBinOp, W::Int) = IRBinOp(inst.dest, inst.op, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRICmp, W::Int) = IRICmp(inst.dest, inst.predicate, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRSelect, W::Int) = IRSelect(inst.dest, inst.cond, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRCast, W::Int) = IRCast(inst.dest, inst.op, inst.operand,
                                             inst.from_width > 1 ? W : 1,
                                             inst.to_width > 1 ? W : 1)
_narrow_inst(inst::IRRet, W::Int) = IRRet(inst.op, W)
_narrow_inst(inst::IRPhi, W::Int) = IRPhi(inst.dest, inst.width > 1 ? W : 1, inst.incoming)
_narrow_inst(inst::IRBranch, W::Int) = inst  # branches don't have widths
_narrow_inst(inst::IRInsertValue, W::Int) = IRInsertValue(inst.dest, inst.agg, inst.val, inst.index, W, inst.elem_count)
_narrow_inst(inst::IRExtractValue, W::Int) = IRExtractValue(inst.dest, inst.agg, inst.index, W)
_narrow_inst(inst::IRCall, W::Int) = inst  # calls handle their own widths
# IRStore/IRAlloca: preserve i1 widths like the other narrow methods; n_elems
# is a count, not a bit-width, so it passes through.
_narrow_inst(inst::IRStore, W::Int) = IRStore(inst.ptr, inst.val,
                                              inst.width > 1 ? W : 1)
_narrow_inst(inst::IRAlloca, W::Int) = IRAlloca(inst.dest,
                                                inst.elem_width > 1 ? W : 1,
                                                inst.n_elems)
_narrow_inst(inst::IRInst, W::Int) = inst  # fallback: pass through

# ---- Register soft-float functions for gate-level inlining ----
register_callee!(soft_fadd)
register_callee!(soft_fsub)
register_callee!(soft_fmul)
register_callee!(soft_fma)
register_callee!(soft_fneg)
register_callee!(soft_fcmp_olt)
register_callee!(soft_fcmp_oeq)
register_callee!(soft_udiv)
register_callee!(soft_urem)
register_callee!(soft_fdiv)
register_callee!(soft_fsqrt)
register_callee!(soft_fpext)
register_callee!(soft_fptrunc)
register_callee!(soft_exp)
register_callee!(soft_exp2)
register_callee!(soft_exp_fast)
register_callee!(soft_exp2_fast)
register_callee!(soft_fptosi)
register_callee!(soft_sitofp)
register_callee!(soft_fcmp_ole)
register_callee!(soft_floor)
register_callee!(soft_ceil)
register_callee!(soft_trunc)
register_callee!(soft_fcmp_une)
register_callee!(soft_mux_store_4x8)
register_callee!(soft_mux_load_4x8)
register_callee!(soft_mux_store_8x8)
register_callee!(soft_mux_load_8x8)

# ---- Float64 support via SoftFloat dispatch ----

"""
    SoftFloat

Wrapper type that redirects Float64 arithmetic to soft-float functions
(soft_fadd, soft_fmul, soft_fneg) operating on UInt64 bit patterns.
Used internally by `reversible_compile(f, Float64)` to produce LLVM IR
that calls our soft-float implementations instead of hardware float ops.
"""
struct SoftFloat
    bits::UInt64
end

@inline SoftFloat(x::Float64) = SoftFloat(reinterpret(UInt64, x))
@inline SoftFloat(x::Int) = SoftFloat(reinterpret(UInt64, Float64(x)))
@inline Base.:+(a::SoftFloat, b::SoftFloat) = SoftFloat(soft_fadd(a.bits, b.bits))
@inline Base.:*(a::SoftFloat, b::SoftFloat) = SoftFloat(soft_fmul(a.bits, b.bits))
@inline Base.:-(a::SoftFloat) = SoftFloat(soft_fneg(a.bits))
@inline Base.:-(a::SoftFloat, b::SoftFloat) = SoftFloat(soft_fsub(a.bits, b.bits))
@inline Base.:/(a::SoftFloat, b::SoftFloat) = SoftFloat(soft_fdiv(a.bits, b.bits))
@inline Base.:/(a::SoftFloat, b::Real) = a / SoftFloat(Float64(b))
@inline Base.:/(a::Real, b::SoftFloat) = SoftFloat(Float64(a)) / b
@inline Base.:+(a::SoftFloat, b::Real) = a + SoftFloat(Float64(b))
@inline Base.:+(a::Real, b::SoftFloat) = SoftFloat(Float64(a)) + b
@inline Base.:*(a::SoftFloat, b::Real) = a * SoftFloat(Float64(b))
@inline Base.:*(a::Real, b::SoftFloat) = SoftFloat(Float64(a)) * b
@inline Base.:-(a::SoftFloat, b::Real) = a - SoftFloat(Float64(b))
@inline Base.:-(a::Real, b::SoftFloat) = SoftFloat(Float64(a)) - b
@inline Base.:(<)(a::SoftFloat, b::SoftFloat) = soft_fcmp_olt(a.bits, b.bits) != UInt64(0)
@inline Base.:(==)(a::SoftFloat, b::SoftFloat) = soft_fcmp_oeq(a.bits, b.bits) != UInt64(0)
@inline Base.copysign(x::SoftFloat, y::SoftFloat) =
    SoftFloat((x.bits & UInt64(0x7fffffffffffffff)) | (y.bits & UInt64(0x8000000000000000)))
@inline Base.abs(x::SoftFloat) = SoftFloat(x.bits & UInt64(0x7fffffffffffffff))
@inline Base.floor(x::SoftFloat) = SoftFloat(soft_floor(x.bits))
@inline Base.ceil(x::SoftFloat) = SoftFloat(soft_ceil(x.bits))
@inline Base.trunc(x::SoftFloat) = SoftFloat(soft_trunc(x.bits))
@inline Base.sqrt(x::SoftFloat) = SoftFloat(soft_fsqrt(x.bits))
@inline Base.exp(x::SoftFloat) = SoftFloat(soft_exp(x.bits))
@inline Base.exp2(x::SoftFloat) = SoftFloat(soft_exp2(x.bits))

"""
    reversible_compile(f, ::Type{Float64}; ...) -> ReversibleCircuit
    reversible_compile(f, ::Type{Float64}, ::Type{Float64}, ...; ...) -> ReversibleCircuit

Compile a Julia function on Float64 into a reversible circuit. Float operations
are routed through soft-float functions (soft_fadd, soft_fmul, soft_fdiv, etc.)
via SoftFloat dispatch, producing LLVM IR with `call` instructions that are
inlined at the gate level during lowering.

The resulting circuit operates on UInt64 bit patterns (IEEE 754 encoding).
The function must be generic (no ::Float64 type annotations on arguments).

Implementation: The user's function is called with SoftFloat arguments inside a
`@force_inline`-d wrapper. This ensures Julia inlines through f → SoftFloat./ →
soft_fdiv etc., eliminating struct-passing ABI and producing clean integer IR
with direct `call @j_soft_fdiv` instructions that the callee registry recognizes.
"""
function reversible_compile(f::F, float_types::Type{Float64}...;
                            optimize::Bool=true, max_loop_iterations::Int=0,
                            compact_calls::Bool=false,
                            strategy::Symbol=:auto) where {F}
    strategy in (:auto, :expression) ||
        error("reversible_compile: strategy=:$strategy not supported for Float64 " *
              "(2^64 table would be absurd); use :auto or :expression")
    N = length(float_types)
    N >= 1 || error("Need at least one Float64 argument type")

    # Use @inline at the call site to force Julia to inline f through the SoftFloat
    # dispatch chain. Without this, Julia emits struct-passing ABI (alloca + store +
    # call(ptr...)) which ir_extract can't handle. @inline at the call site makes
    # Julia inline f → SoftFloat./ → soft_fdiv etc., producing clean integer IR
    # with direct soft_* calls that the callee registry recognizes.
    if N == 1
        w = (x::UInt64) -> (@inline f(SoftFloat(x))).bits
        return reversible_compile(w, UInt64; optimize, max_loop_iterations, compact_calls)
    elseif N == 2
        w = (a::UInt64, b::UInt64) -> (@inline f(SoftFloat(a), SoftFloat(b))).bits
        return reversible_compile(w, UInt64, UInt64; optimize, max_loop_iterations, compact_calls)
    elseif N == 3
        w = (a::UInt64, b::UInt64, c::UInt64) -> (@inline f(SoftFloat(a), SoftFloat(b), SoftFloat(c))).bits
        return reversible_compile(w, UInt64, UInt64, UInt64; optimize, max_loop_iterations, compact_calls)
    else
        error("Float64 compile supports up to 3 arguments (got $N)")
    end
end

end # module
