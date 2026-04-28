# ---- Float64 support via SoftFloat dispatch (Bennett-19g6 extracted from Bennett.jl) ----

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
