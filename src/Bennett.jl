module Bennett

include("ir_types.jl")
include("ir_extract.jl")
# Bennett-cs2f / U42: src/ir_parser.jl deleted 2026-04-25 — the regex
# IR parser was dead legacy and violated CLAUDE.md §5 (LLVM IR is not
# stable).  The C-API walker in ir_extract.jl is the source of truth.
include("gates.jl")
include("wire_allocator.jl")
include("adder.jl")
include("qcla.jl")
include("multiplier.jl")
# Bennett-9c4o / U89: deps that lower.jl forward-references load BEFORE
# lower.jl so the file is standalone-loadable. softfloat precedes softmem
# (uses soft_fadd); fast_copy/partial_products/parallel_adder_tree precede
# mul_qcla_tree.
include("divider.jl")
include("softfloat/softfloat.jl")
include("softmem.jl")
include("qrom.jl")
include("shadow_memory.jl")
include("fast_copy.jl")
include("partial_products.jl")
include("parallel_adder_tree.jl")
include("mul_qcla_tree.jl")
include("lower.jl")
include("bennett_transform.jl")
include("simulator.jl")
include("diagnostics.jl")
include("controlled.jl")
include("compose.jl")
include("dep_dag.jl")
include("pebbling.jl")
include("eager.jl")
include("value_eager.jl")
include("pebbled_groups.jl")
include("sat_pebbling.jl")
include("tabulate.jl")
include("memssa.jl")
include("feistel.jl")
include("persistent/persistent.jl")

export reversible_compile, simulate, simulate!, extract_ir, extract_parsed_ir, register_callee!
export extract_parsed_ir_from_ll, extract_parsed_ir_from_bc
export PersistentMapImpl, AbstractPersistentMap, verify_pmap_correctness, verify_pmap_persistence_invariant, pmap_demo_oracle, LINEAR_SCAN_IMPL
# Bennett-uoem / U54: OKASAKI_IMPL + Okasaki API relocated to
# src/persistent/research/okasaki_rbt.jl (2026-04-25).
# Bennett-uoem / U54: CF_IMPL + cf_pmap_*/cf_reroot relocated to
# src/persistent/research/cf_semi_persistent.jl (2026-04-25).
# Bennett-uoem / U54: HAMT_IMPL + hamt_pmap_*/soft_popcount32 relocated to
# src/persistent/research/{hamt,popcount}.jl (2026-04-25).
# Bennett-uoem / U54: soft_jenkins96 + soft_jenkins_int8 relocated to
# src/persistent/research/hashcons_jenkins.jl (2026-04-25).
export soft_feistel32, soft_feistel_int8
export soft_fadd, soft_fsub, soft_fmul, soft_fma, soft_fdiv, soft_fsqrt, soft_fneg, soft_fcmp_olt, soft_fcmp_oeq, soft_fcmp_ole, soft_fcmp_une, soft_fptosi, soft_fptoui, soft_sitofp, soft_fpext, soft_fptrunc, soft_exp, soft_exp2, soft_exp_fast, soft_exp2_fast, soft_exp_julia, soft_exp2_julia
export ReversibleCircuit, ControlledCircuit, controlled, compose
# Bennett-qcse / U51: gate primitives documented public in docs/src/api.md
# (lines 188/192/196/211) — exporting so the documented constructors and
# type-pattern-matches resolve without `Bennett.` prefix.
export NOTGate, CNOTGate, ToffoliGate, ReversibleGate
# Bennett-qcse / U51: ParsedIR is the return type of `extract_parsed_ir`
# (REPL-visible), LoweringResult the return type of `lower` and input to
# `bennett` (referenced in docs/src/api.md:139, 211).  Exporting both.
export ParsedIR, LoweringResult
export gate_count, ancilla_count, constant_wire_count, depth, t_count, t_depth, toffoli_depth, peak_live_wires, print_circuit, verify_reversibility
export pebbled_bennett, eager_bennett, value_eager_bennett, pebbled_group_bennett, checkpoint_bennett

reversible_compile(f, types::Type...; kw...) = reversible_compile(f, Tuple{types...}; kw...)

# Bennett-k0bg / U25: shared validation for the Julia-function entry points.
const _SUPPORTED_SCALAR_ARGS = (Int8, Int16, Int32, Int64,
                                UInt8, UInt16, UInt32, UInt64,
                                Float64, Bool)

# Bennett-xlsz / U29: unified kwargs validation across all three
# `reversible_compile` overloads. A raw `MethodError` on a typo or on
# a cross-overload kwarg (e.g. `bit_width` sent to the Float64 path)
# used to dump LLVM-backed lookup spew; now each overload enumerates
# the kwargs it accepts and raises a scoped `ArgumentError` pointing
# the user at the valid set.
function _reject_unknown_kwargs(overload::String, supported::Tuple,
                                 rejected_cross::Tuple, passed::Base.Pairs)
    unknown = Symbol[]
    cross   = Symbol[]
    for (k, _) in passed
        k in supported && continue
        if k in rejected_cross
            push!(cross, k)
        else
            push!(unknown, k)
        end
    end
    isempty(unknown) && isempty(cross) && return nothing
    msgs = String[]
    if !isempty(unknown)
        push!(msgs, "unknown kwarg(s) $unknown")
    end
    if !isempty(cross)
        push!(msgs, "kwarg(s) $cross not supported on this overload (see docstring)")
    end
    throw(ArgumentError(
        "reversible_compile ($overload): " * join(msgs, "; ") *
        ". Supported kwargs here: $(collect(supported))."))
end

"Check whether `T` is an argument type supported by `reversible_compile`."
@inline function _is_supported_arg_type(T::Type)
    T in _SUPPORTED_SCALAR_ARGS && return true
    # Flat NTuple whose element type is a supported scalar (common sret
    # pattern for aggregate returns; Bennett-0c8o).
    if T <: Tuple && isconcretetype(T)
        params = T.parameters
        # NTuple{N, Elt} expands to (Elt, Elt, ...) — every param equal and supported.
        !isempty(params) || return false
        all(p -> p in _SUPPORTED_SCALAR_ARGS, params) || return false
        return true
    end
    return false
end

"""
    reversible_compile(f, arg_types::Type{<:Tuple}) -> ReversibleCircuit
    reversible_compile(f, types::Type...; kw...) -> ReversibleCircuit

Compile a plain Julia function into a reversible circuit via LLVM IR.
Uses LLVM.jl to walk the IR as typed objects (no regex parsing).

# Example

```jldoctest; setup = :(using Bennett)
julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> simulate(c, Int8(5))
6

julia> gate_count(c)
(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)

julia> verify_reversibility(c)
true
```
"""
const _TUPLE_OVERLOAD_KWARGS = (:optimize, :max_loop_iterations,
                               :compact_calls, :bit_width, :add, :mul,
                               :strategy, :fold_constants, :target)

function reversible_compile(f, arg_types::Type{<:Tuple};
                            optimize::Bool=true, max_loop_iterations::Int=0,
                            compact_calls::Bool=false, bit_width::Int=0,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            strategy::Symbol=:auto,
                            fold_constants::Bool=true,
                            target::Symbol=:gate_count,
                            kwargs...)
    _reject_unknown_kwargs("Tuple overload", _TUPLE_OVERLOAD_KWARGS,
                           (), kwargs)
    # Bennett-k0bg / U25: up-front kwarg + type validation.
    # `bit_width == 0` means "infer from arg_types"; otherwise the width
    # must be in [1, 64] (powers-of-2 are the common case but narrow
    # widths like 2 and 4 are exercised by test_narrow.jl).
    (bit_width == 0 || 1 <= bit_width <= 64) || throw(ArgumentError(
        "reversible_compile: bit_width must be 0 (infer) or in [1, 64] — " *
        "got $bit_width"))
    max_loop_iterations >= 0 || throw(ArgumentError(
        "reversible_compile: max_loop_iterations must be >= 0, got " *
        "$max_loop_iterations"))
    for (i, T) in enumerate(arg_types.parameters)
        _is_supported_arg_type(T) || throw(ArgumentError(
            "reversible_compile: arg_types[$i] = $T is not supported; " *
            "expected one of $(_SUPPORTED_SCALAR_ARGS) or an NTuple of " *
            "those"))
    end

    # Bennett-4bcp / U102: NTuple{N,T} IS Tuple{T,T,...,T}, so passing
    # `reversible_compile(f, NTuple{2,Int8})` dispatches here with
    # arg_types = Tuple{Int8,Int8} (the 2-arg interpretation). If the
    # user's function actually takes a single NTuple-typed argument,
    # there's no method match and code_llvm later throws an opaque
    # "no unique matching method" error. Detect both cases up-front
    # and emit an actionable error pointing at the wrap fix.
    if !hasmethod(f, arg_types)
        wrapped = Tuple{arg_types}
        if hasmethod(f, wrapped)
            throw(ArgumentError(
                "reversible_compile: $f has no method for arg_types=$arg_types " *
                "(interpreted as $(length(arg_types.parameters)) separate args), " *
                "but does match $wrapped (a single tuple-typed arg). " *
                "If your function takes a single NTuple/Tuple argument, " *
                "wrap arg_types as `Tuple{$arg_types}`. " *
                "(Bennett-4bcp / U102: NTuple-as-arg-type ambiguity.)"))
        else
            throw(ArgumentError(
                "reversible_compile: $f has no method for arg_types=$arg_types. " *
                "Check the function signature matches the requested types."))
        end
    end

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
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul,
               fold_constants, target)
    return bennett(lr)
end

const _PARSED_OVERLOAD_KWARGS = (:max_loop_iterations, :compact_calls,
                                :add, :mul, :fold_constants, :target)
# Kwargs that only make sense on the Julia-function entry path (they
# configure IR extraction or pre-extraction narrowing); rejected
# loudly if sent to the ParsedIR overload.
const _PARSED_OVERLOAD_CROSS_REJECT = (:optimize, :bit_width, :strategy)

"""
    reversible_compile(parsed::ParsedIR; max_loop_iterations=0,
                       compact_calls=false, add=:auto, mul=:auto,
                       fold_constants=true) -> ReversibleCircuit

Compile a pre-extracted `ParsedIR` (e.g. from
`extract_parsed_ir_from_ll` or `extract_parsed_ir_from_bc`) into a reversible
circuit. This path skips IR extraction and the `strategy=:tabulate` /
`bit_width` pre-processing that only apply to Julia-function inputs;
passing `optimize`, `bit_width`, or `strategy` here raises `ArgumentError`.
"""
function reversible_compile(parsed::ParsedIR;
                            max_loop_iterations::Int=0,
                            compact_calls::Bool=false,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            fold_constants::Bool=true,
                            target::Symbol=:gate_count,
                            kwargs...)
    _reject_unknown_kwargs("ParsedIR overload", _PARSED_OVERLOAD_KWARGS,
                           _PARSED_OVERLOAD_CROSS_REJECT, kwargs)
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul,
               fold_constants, target)
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
_narrow_inst(inst::IRSelect, W::Int) = inst.width == 0 ? inst :
    IRSelect(inst.dest, inst.cond, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRCast, W::Int) = IRCast(inst.dest, inst.op, inst.operand,
                                             inst.from_width > 1 ? W : 1,
                                             inst.to_width > 1 ? W : 1)
_narrow_inst(inst::IRRet, W::Int) = IRRet(inst.op, W)
_narrow_inst(inst::IRPhi, W::Int) = inst.width == 0 ? inst :
    IRPhi(inst.dest, inst.width > 1 ? W : 1, inst.incoming)
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
#
# Bennett-kmuj / U106: callees are grouped by domain into named tuples
# so the registration loop is one declarative pass instead of 45 ad-hoc
# `register_callee!` lines. Adding a new callee = append it to the
# matching group; the loop registers it on module load.

# Integer division / remainder (called by `lower_binop!` for udiv/sdiv/urem/srem).
# Per Bennett-salb / U119, the registered callees are the throw-free `_compile`
# variants — the public `soft_udiv` / `soft_urem` raise DivideError on b=0,
# which would emit an external @ijl_throw that lower_call! cannot extract.
const _CALLEES_INTEGER_DIV = (
    _soft_udiv_compile, _soft_urem_compile,
)

# IEEE 754 binary 64-bit arithmetic.
const _CALLEES_FP_BINARY = (
    soft_fadd, soft_fsub, soft_fmul, soft_fdiv, soft_fma,
)

# IEEE 754 unary / sqrt (sign flip + square root).
const _CALLEES_FP_UNARY = (
    soft_fneg, soft_fsqrt,
)

# IEEE 754 rounding to integral (no precision loss; result still binary64).
const _CALLEES_FP_ROUND = (
    soft_floor, soft_ceil, soft_trunc, soft_round,
)

# IEEE 754 comparison (returns i1). Bennett-d77b / U132: 6 new primitives
# (ord, uno, one, ueq, ult, ule) complete the LLVM fcmp predicate table.
# Combined with operand-swap dispatch in ir_extract.jl for ogt/oge/ugt/uge,
# every LLVM fcmp predicate routes to a callee.
const _CALLEES_FP_CMP = (
    soft_fcmp_olt, soft_fcmp_oeq, soft_fcmp_ole, soft_fcmp_une,
    soft_fcmp_ord, soft_fcmp_uno, soft_fcmp_one,
    soft_fcmp_ueq, soft_fcmp_ult, soft_fcmp_ule,
)

# IEEE 754 width / signedness conversions.
const _CALLEES_FP_CONV = (
    soft_fpext, soft_fptrunc, soft_fptosi, soft_fptoui, soft_sitofp,
)

# IEEE 754 transcendentals (musl-derived branchless + Julia-idiom variants).
const _CALLEES_FP_TRANS = (
    soft_exp, soft_exp2,
    soft_exp_fast, soft_exp2_fast,
    soft_exp_julia, soft_exp2_julia,
)

# Reversible mutable memory — MUX EXCH load/store (Bennett-cc0 M1, N·W ≤ 64).
# Hand-written (4,8)/(8,8) plus @eval-generated (2,8)/(2,16)/(4,16)/(2,32).
const _CALLEES_MUX_EXCH = (
    soft_mux_load_2x8,  soft_mux_store_2x8,
    soft_mux_load_4x8,  soft_mux_store_4x8,
    soft_mux_load_8x8,  soft_mux_store_8x8,
    soft_mux_load_2x16, soft_mux_store_2x16,
    soft_mux_load_4x16, soft_mux_store_4x16,
    soft_mux_load_2x32, soft_mux_store_2x32,
)

# Reversible mutable memory — path-predicate-guarded MUX stores
# (Bennett-cc0 M2d / bucket C3) for stores in non-entry blocks.
const _CALLEES_MUX_EXCH_GUARDED = (
    soft_mux_store_guarded_2x8,
    soft_mux_store_guarded_4x8,
    soft_mux_store_guarded_8x8,
    soft_mux_store_guarded_2x16,
    soft_mux_store_guarded_4x16,
    soft_mux_store_guarded_2x32,
)

# Single source of truth: every group above is registered exactly once.
const _CALLEE_GROUPS = (
    _CALLEES_INTEGER_DIV,
    _CALLEES_FP_BINARY, _CALLEES_FP_UNARY, _CALLEES_FP_ROUND,
    _CALLEES_FP_CMP, _CALLEES_FP_CONV, _CALLEES_FP_TRANS,
    _CALLEES_MUX_EXCH, _CALLEES_MUX_EXCH_GUARDED,
)

for group in _CALLEE_GROUPS, f in group
    register_callee!(f)
end

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
@inline Base.round(x::SoftFloat) = SoftFloat(soft_round(x.bits))
@inline Base.sqrt(x::SoftFloat) = SoftFloat(soft_fsqrt(x.bits))
@inline Base.exp(x::SoftFloat) = SoftFloat(soft_exp_julia(x.bits))
@inline Base.exp2(x::SoftFloat) = SoftFloat(soft_exp2_julia(x.bits))

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
const _FLOAT64_OVERLOAD_KWARGS = (:optimize, :max_loop_iterations,
                                  :compact_calls, :strategy, :add, :mul,
                                  :fold_constants, :target)
# Kwargs that only make sense on the Tuple-of-integers path.
const _FLOAT64_OVERLOAD_CROSS_REJECT = (:bit_width,)

function reversible_compile(f::F, float_types::Type{Float64}...;
                            optimize::Bool=true, max_loop_iterations::Int=0,
                            compact_calls::Bool=false,
                            strategy::Symbol=:auto,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            fold_constants::Bool=true,
                            target::Symbol=:gate_count,
                            kwargs...) where {F}
    _reject_unknown_kwargs("Float64 overload", _FLOAT64_OVERLOAD_KWARGS,
                           _FLOAT64_OVERLOAD_CROSS_REJECT, kwargs)
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
        return reversible_compile(w, UInt64; optimize, max_loop_iterations,
                                  compact_calls, add, mul, fold_constants, target)
    elseif N == 2
        w = (a::UInt64, b::UInt64) -> (@inline f(SoftFloat(a), SoftFloat(b))).bits
        return reversible_compile(w, UInt64, UInt64; optimize, max_loop_iterations,
                                  compact_calls, add, mul, fold_constants, target)
    elseif N == 3
        w = (a::UInt64, b::UInt64, c::UInt64) -> (@inline f(SoftFloat(a), SoftFloat(b), SoftFloat(c))).bits
        return reversible_compile(w, UInt64, UInt64, UInt64; optimize, max_loop_iterations,
                                  compact_calls, add, mul, fold_constants, target)
    else
        error("Float64 compile supports up to 3 arguments (got $N)")
    end
end

# Bennett-w0fc / U52: precompile workload.
#
# Without this block the FIRST call to `reversible_compile` after
# `using Bennett` paid ~20s of latency-to-first-execution (LLVM.jl
# C-API walk + per-opcode dispatch + type-stable specialisation of
# the lowering machinery, all hit cold).  Subsequent calls were
# ~10× faster (1-2s).  The workload below pays that 20s once at
# package precompile time so the user's first call is fast.
#
# Cost: precompile time grows by the wall-clock of these workloads
# (~25-30s on this hardware).  Acceptable trade — package precompile
# happens once per environment / package upgrade, TTFX hits every
# fresh REPL session.
#
# Coverage rationale: each workload exercises a distinct lowering
# path so the specialisation cache covers the common entry points.
#   * Int8 add — narrowest, tiny circuit, exercises the basic shift+add
#   * Int32 mul — widening multiplication path
#   * Int64 add — widest integer path
#   * Float64 add — soft-float dispatch + UInt64 wrapper compile
using PrecompileTools

PrecompileTools.@compile_workload begin
    reversible_compile(x -> x + Int8(1),    Int8)
    reversible_compile(x -> x * Int32(3),   Int32)
    reversible_compile(x -> x + Int64(7),   Int64)
    reversible_compile(x -> x + 1.0,        Float64)
end

end # module
