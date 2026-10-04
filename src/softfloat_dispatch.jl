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
# Bennett-g6u9: mixed equality. SoftFloat is not a Number, so without these
# `SoftFloat(0.0) == 0.0` falls to Base's generic `x === y` (false) and the
# branch folds away at trace time — a silent miscompile. `!=` follows via
# Base's `!(x == y)`. Integer comparison is exact like Base's Float64/Integer
# `==`: `Float64(b) == b` (Base semantics, constant-folded for literals) is
# false when `b` is not representable, and then no Float64 equals `b`.
@inline Base.:(==)(a::SoftFloat, b::Float64) = a == SoftFloat(b)
@inline Base.:(==)(a::Float64, b::SoftFloat) = SoftFloat(a) == b
@inline function Base.:(==)(a::SoftFloat, b::Integer)
    fb = Float64(b)
    return (a == SoftFloat(fb)) & (fb == b)
end
@inline Base.:(==)(a::Integer, b::SoftFloat) = b == a
Base.:(==)(a::SoftFloat, b::Real) = _softfloat_mixed_eq_reject(b)
Base.:(==)(a::Real, b::SoftFloat) = _softfloat_mixed_eq_reject(a)
@noinline _softfloat_mixed_eq_reject(y) =
    throw(ArgumentError("SoftFloat == $(typeof(y)) is not supported (Bennett-g6u9): only " *
                        "Float64 and Integer operands compare exactly against a SoftFloat; " *
                        "convert the operand to Float64 explicitly"))
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
# Bennett-k2w6: Base.min/max route to the NaN-propagating
# soft_fminimum/soft_fmaximum (matches Julia's hardware float semantics
# bit-exactly). The NaN-absorbing soft_fmin/soft_fmax are reserved for
# the LLVM `llvm.minnum`/`llvm.maxnum` ingest path.
@inline Base.min(a::SoftFloat, b::SoftFloat) = SoftFloat(soft_fminimum(a.bits, b.bits))
@inline Base.max(a::SoftFloat, b::SoftFloat) = SoftFloat(soft_fmaximum(a.bits, b.bits))
# Bennett-jexo / Path A: ^(SoftFloat, SoftFloat) → soft_pow_julia
# (bit-exact vs Base.:^), distinct from LLVM `llvm.pow.f64` direct
# dispatch which keeps using `soft_pow` (musl-tracking) for raw .ll/.bc
# ingest from non-Julia frontends.
@inline Base.:^(a::SoftFloat, b::SoftFloat) = SoftFloat(soft_pow_julia(a.bits, b.bits))
# Bennett-l5v8: transcendental overloads. These were missing entirely, so
# `reversible_compile(sin, Float64)` compiled its wrapper to a
# jl_f_throw_methoderror body with a void return and died at the dq8l/U81
# VoidType extraction wall. Every primitive below already existed in
# SoftFloatLib and was registered as a callee (src/callees.jl
# _CALLEES_FP_TRANS) — only the dispatch layer was absent.
@inline Base.sin(x::SoftFloat)   = SoftFloat(soft_sin(x.bits))
@inline Base.cos(x::SoftFloat)   = SoftFloat(soft_cos(x.bits))
@inline Base.tan(x::SoftFloat)   = SoftFloat(soft_tan(x.bits))
@inline Base.asin(x::SoftFloat)  = SoftFloat(soft_asin(x.bits))
@inline Base.acos(x::SoftFloat)  = SoftFloat(soft_acos(x.bits))
@inline Base.atan(x::SoftFloat)  = SoftFloat(soft_atan(x.bits))
@inline Base.atan(y::SoftFloat, x::SoftFloat) = SoftFloat(soft_atan2(y.bits, x.bits))
@inline Base.sinh(x::SoftFloat)  = SoftFloat(soft_sinh(x.bits))
@inline Base.cosh(x::SoftFloat)  = SoftFloat(soft_cosh(x.bits))
@inline Base.tanh(x::SoftFloat)  = SoftFloat(soft_tanh(x.bits))
@inline Base.asinh(x::SoftFloat) = SoftFloat(soft_asinh(x.bits))
@inline Base.acosh(x::SoftFloat) = SoftFloat(soft_acosh(x.bits))
@inline Base.atanh(x::SoftFloat) = SoftFloat(soft_atanh(x.bits))
@inline Base.log(x::SoftFloat)   = SoftFloat(soft_log(x.bits))
@inline Base.log2(x::SoftFloat)  = SoftFloat(soft_log2(x.bits))
@inline Base.log10(x::SoftFloat) = SoftFloat(soft_log10(x.bits))
@inline Base.log1p(x::SoftFloat) = SoftFloat(soft_log1p(x.bits))
@inline Base.expm1(x::SoftFloat) = SoftFloat(soft_expm1(x.bits))

# ---- Bennett-8aes: the rest of the Float64 surface ordinary code uses ----
# Without these, mixed `<`, `isnan`, `fma`, `x^2`, mixed `min`, ... threw on
# the host and died at the VoidType wall when compiled; `isequal` silently
# fell to Base's generic `x == y` (wrong for NaN and ±0). Operand rules follow
# Bennett-g6u9: Float64 and Integer operands behave exactly as Base's Float64
# methods; other Reals are rejected loudly.
const _SF_ABS  = UInt64(0x7fffffffffffffff)
const _SF_INF  = UInt64(0x7ff0000000000000)
const _SF_MINN = UInt64(0x0010000000000000)   # floatmin(Float64)
const _SFOther = Union{Float64, Integer}       # operands handled exactly

@noinline _softfloat_mixed_reject(op, y) =
    throw(ArgumentError("SoftFloat $op $(typeof(y)) is not supported (Bennett-8aes): " *
                        "only Float64 and Integer operands mix with a SoftFloat; " *
                        "convert the operand to Float64 explicitly"))
@inline _to_softfloat(x::SoftFloat) = x
@inline _to_softfloat(x::_SFOther) = SoftFloat(Float64(x))
_to_softfloat(x::Real) = _softfloat_mixed_reject("arithmetic with", x)

Base.zero(::Type{SoftFloat}) = SoftFloat(UInt64(0))
Base.one(::Type{SoftFloat}) = SoftFloat(1.0)
Base.zero(::SoftFloat) = zero(SoftFloat)
Base.one(::SoftFloat) = one(SoftFloat)
@inline Base.isnan(x::SoftFloat) = (x.bits & _SF_ABS) > _SF_INF
@inline Base.isinf(x::SoftFloat) = (x.bits & _SF_ABS) == _SF_INF
@inline Base.isfinite(x::SoftFloat) = (x.bits & _SF_ABS) < _SF_INF
@inline Base.signbit(x::SoftFloat) = (x.bits >> 63) != UInt64(0)
@inline Base.iszero(x::SoftFloat) = (x.bits & _SF_ABS) == UInt64(0)
@inline function Base.issubnormal(x::SoftFloat)
    a = x.bits & _SF_ABS
    return (a != UInt64(0)) & (a < _SF_MINN)
end
@inline Base.inv(x::SoftFloat) = one(SoftFloat) / x
@inline Base.abs2(x::SoftFloat) = x * x

# Ordered comparisons. `<=`, `>`, `>=` follow from Base's generic
# `(x < y) | (x == y)` / argument swap. Integer operands compare exactly like
# Base's Float64/Integer `<`: `fb = Float64(b)` (constant-folded for
# literals) is the nearest Float64, so no Float64 lies strictly between `b`
# and `fb`, and a tie with `fb` is decided by Base's exact `fb < b`.
@inline Base.:(<)(a::SoftFloat, b::Float64) = a < SoftFloat(b)
@inline Base.:(<)(a::Float64, b::SoftFloat) = SoftFloat(a) < b
@inline function Base.:(<)(a::SoftFloat, b::Integer)
    fb = SoftFloat(Float64(b))
    return (a < fb) | ((a == fb) & (Float64(b) < b))
end
@inline function Base.:(<)(a::Integer, b::SoftFloat)
    fa = SoftFloat(Float64(a))
    return (fa < b) | ((fa == b) & (a < Float64(a)))
end
Base.:(<)(a::SoftFloat, b::Real) = _softfloat_mixed_reject("<", b)
Base.:(<)(a::Real, b::SoftFloat) = _softfloat_mixed_reject("<", a)

# Total order (`isequal` / `isless`), ported from Base's AbstractFloat
# methods (operators.jl). `cmp` and `sort` use Base's isless-based generics.
@inline Base.isequal(a::SoftFloat, b::SoftFloat) = (isnan(a) & isnan(b)) | (a.bits == b.bits)
@inline Base.isequal(a::SoftFloat, b::_SFOther) =
    (isnan(a) & isnan(b)) | ((signbit(a) == signbit(b)) & (a == b))
@inline Base.isequal(a::_SFOther, b::SoftFloat) = isequal(b, a)
Base.isequal(a::SoftFloat, b::Real) = _softfloat_mixed_reject("isequal", b)
Base.isequal(a::Real, b::SoftFloat) = _softfloat_mixed_reject("isequal", a)
@inline _softfloat_isless(x, y) =
    (!isnan(x) & (isnan(y) | (signbit(x) & !signbit(y)))) | (x < y)
@inline Base.isless(a::SoftFloat, b::SoftFloat) = _softfloat_isless(a, b)
@inline Base.isless(a::SoftFloat, b::_SFOther) = _softfloat_isless(a, b)
@inline Base.isless(a::_SFOther, b::SoftFloat) = _softfloat_isless(a, b)
Base.isless(a::SoftFloat, b::Real) = _softfloat_mixed_reject("isless", b)
Base.isless(a::Real, b::SoftFloat) = _softfloat_mixed_reject("isless", a)
# NaN is unordered: Base's `isgreater` (findmin / findmax / argmin / argmax)
# would otherwise rank it like the generic non-float fallback.
@inline Base.isunordered(x::SoftFloat) = isnan(x)
# Base's generic clamp converts the bounds to promote_type(...), which is Any
# for a SoftFloat, so an Integer bound came back as an Integer. Same tests as
# Base's, as a branchless select, with the bounds converted like Base.
@inline Base.clamp(x::SoftFloat, lo::Union{SoftFloat, Real}, hi::Union{SoftFloat, Real}) =
    ifelse(x > hi, _to_softfloat(hi), ifelse(x < lo, _to_softfloat(lo), x))
# A SoftFloat is not hashable consistently with `isequal` (all NaNs equal);
# hashing a traced value has no circuit meaning, so refuse instead.
Base.hash(::SoftFloat, ::UInt) =
    throw(ArgumentError("hash(::SoftFloat) is not supported (Bennett-8aes)"))

# Mixed min / max: Base promotes Float64/Integer to Float64 (round to nearest).
# Base's generic minmax is isless-based (NaN-absorbing); Float64's is min, max.
@inline Base.minmax(a::SoftFloat, b::SoftFloat) = (min(a, b), max(a, b))
for op in (:min, :max, :minmax)
    @eval begin
        @inline Base.$op(a::SoftFloat, b::_SFOther) = $op(a, _to_softfloat(b))
        @inline Base.$op(a::_SFOther, b::SoftFloat) = $op(_to_softfloat(a), b)
        Base.$op(a::SoftFloat, b::Real) = _softfloat_mixed_reject($(string(op)), b)
        Base.$op(a::Real, b::SoftFloat) = _softfloat_mixed_reject($(string(op)), a)
    end
end

# fma / muladd → soft_fma (one rounding). `muladd` may fuse per Julia's docs;
# fusing matches the `llvm.fmuladd` ingest path (Bennett-h6f), so traced and
# raw-IR Float64 code agree. Any operand position may hold the SoftFloat.
@inline _softfloat_fma(a::SoftFloat, b::SoftFloat, c::SoftFloat) =
    SoftFloat(soft_fma(a.bits, b.bits, c.bits))
for op in (:fma, :muladd)
    @eval begin
        @inline Base.$op(a::SoftFloat, b::Union{SoftFloat, Real}, c::Union{SoftFloat, Real}) =
            _softfloat_fma(a, _to_softfloat(b), _to_softfloat(c))
        @inline Base.$op(a::Real, b::SoftFloat, c::Union{SoftFloat, Real}) =
            _softfloat_fma(_to_softfloat(a), b, _to_softfloat(c))
        @inline Base.$op(a::Real, b::Real, c::SoftFloat) =
            _softfloat_fma(_to_softfloat(a), _to_softfloat(b), c)
    end
end

# Powers. Literal exponents mirror Base's Float64 `literal_pow` (intfuncs.jl):
# 0..3, -1, -2 expand to `*` / `inv` and compile today. Every other power goes
# through `^(SoftFloat, SoftFloat)` = soft_pow_julia, bit-exact vs Base.:^ on
# the host. It extracts (Bennett-bie9: straight-line integer-power body) and
# `reversible_compile(^, Float64, Float64; max_loop_iterations=64)` compiles
# (the inlined soft_fdiv keeps its division loop, so the bound is required;
# 28.8M gates — test/test_bie9_pow_julia_compile.jl).
@inline Base.literal_pow(::typeof(^), x::SoftFloat, ::Val{0}) = one(x)
@inline Base.literal_pow(::typeof(^), x::SoftFloat, ::Val{1}) = x
@inline Base.literal_pow(::typeof(^), x::SoftFloat, ::Val{2}) = x * x
@inline Base.literal_pow(::typeof(^), x::SoftFloat, ::Val{3}) = x * x * x
@inline Base.literal_pow(::typeof(^), x::SoftFloat, ::Val{-1}) = inv(x)
@inline Base.literal_pow(::typeof(^), x::SoftFloat, ::Val{-2}) = (i = inv(x); i * i)
@inline Base.literal_pow(::typeof(^), x::SoftFloat, ::Val{p}) where {p} = x^p
# Base's `x^n` and `x^Float64(n)` both reach `pow_body(x, n)` exactly when
# `n` is in Base's power-by-squaring range; outside it Base takes a split
# path soft_pow_julia does not reproduce, so reject.
@inline function Base.:^(a::SoftFloat, n::Integer)
    -2^12 <= n <= 3 * 2^13 || throw(ArgumentError(
        "SoftFloat ^ $n: integer exponents outside [-4096, 24576] are not " *
        "supported (Bennett-8aes); pass a Float64 exponent"))
    return a ^ SoftFloat(Float64(n))
end
@inline Base.:^(a::SoftFloat, b::Float64) = a ^ SoftFloat(b)
@inline Base.:^(a::_SFOther, b::SoftFloat) = _to_softfloat(a) ^ b
Base.:^(a::SoftFloat, b::Real) = _softfloat_mixed_reject("^", b)
Base.:^(a::Real, b::SoftFloat) = _softfloat_mixed_reject("^", a)

"""
    reversible_compile(f, ::Type{Float64}; ...) -> ReversibleCircuit
    reversible_compile(f, ::Type{Float64}, ::Type{Float64}, ...; ...) -> ReversibleCircuit

Compile a Julia function on Float64 into a reversible circuit. Float operations
are routed through soft-float functions (soft_fadd, soft_fmul, soft_fdiv, etc.)
via SoftFloat dispatch, producing LLVM IR with `call` instructions that are
inlined at the gate level during lowering.

The resulting circuit operates on UInt64 bit patterns (IEEE 754 encoding).
The function must be generic (no ::Float64 type annotations on arguments).
A Float64 result (computed or constant) is output as its UInt64 bit pattern;
a Bool or Int8-Int64 / UInt8-UInt64 result is output as itself. Any other
result type is rejected with an `ArgumentError` (Bennett-lgwa).

`reversible_compile(f, Tuple{Float64,...})` delegates here whenever `f` has a
SoftFloat method, so both spellings build the same circuit (Bennett-19jw).

`f` is rejected with an `ArgumentError` when the SoftFloat trace would take a
different user method or type-test branch than `f(::Float64...)` does — e.g.
`f(x::Float64)` next to a generic `f(x)`, or a helper with such a pair
(Bennett-czox); the Tuple spelling then takes the native-IR route instead.

Implementation: The user's function is called with SoftFloat arguments inside a
`@force_inline`-d wrapper. This ensures Julia inlines through f → SoftFloat./ →
soft_fdiv etc., eliminating struct-passing ABI and producing clean integer IR
with direct `call @j_soft_fdiv` instructions that the callee registry recognizes.
"""
# ---- Bennett-lgwa: adapt the wrapped function's result ----
# The wrapper used to take `.bits` of whatever `f` returned, so a constant
# Float64, Bool or integer result compiled to a throwing body and died with
# "VoidType reached _type_width". Results are now adapted by type; the set of
# accepted kinds is checked against `f`'s inferred return type before
# extraction, so anything else is rejected with a message naming the cause.
const _SF_INT_RESULTS = Union{Bool, Int8, Int16, Int32, Int64,
                              UInt8, UInt16, UInt32, UInt64}
@inline _softfloat_result(r::SoftFloat) = r.bits
@inline _softfloat_result(r::Float64) = reinterpret(UInt64, r)
@inline _softfloat_result(r::_SF_INT_RESULTS) = r

# Circuit output type of one result kind (nothing = no encoding).
_softfloat_result_type(::Type{<:Union{SoftFloat, Float64}}) = UInt64
_softfloat_result_type(T::Type{<:_SF_INT_RESULTS}) = T
_softfloat_result_type(::Type) = nothing

function _check_softfloat_result(f, N::Int)
    argT = Tuple{ntuple(_ -> SoftFloat, N)...}
    hasmethod(f, argT) || throw(ArgumentError(
        "reversible_compile(f, Float64...): $f has no method for $N SoftFloat " *
        "argument(s). The Float64 overload calls f on SoftFloat values, so f " *
        "must be generic: drop ::Float64 argument annotations (Bennett-lgwa)"))
    R = Core.Compiler.return_type(f, argT)
    R === Union{} && throw(ArgumentError(
        "reversible_compile(f, Float64...): $f always throws on SoftFloat " *
        "arguments — it uses a Float64 operation or conversion with no SoftFloat " *
        "method (e.g. Int64(x); missing operators are tracked in Bennett-8aes). " *
        "Call it natively on SoftFloat values to see the error (Bennett-lgwa)"))
    outs = unique(map(_softfloat_result_type, Base.uniontypes(R)))
    (length(outs) == 1 && outs[1] !== nothing) || throw(ArgumentError(
        "reversible_compile(f, Float64...): unsupported result type $R for $f. " *
        "Supported: Float64 (circuit output = IEEE bits as UInt64), Bool, and " *
        "Int8-Int64 / UInt8-UInt64; a Union must map to one output type " *
        "(Bennett-lgwa)"))
    return nothing
end

# ---- Bennett-czox: the SoftFloat trace must take f's native dispatch path ----
# The Float64 overload compiles `f(::SoftFloat...)`, not `f(::Float64...)`.
# The two select different user code whenever a method, a helper method, or a
# type test is specific to Float64/AbstractFloat/Real/Number (SoftFloat
# subtypes none of them): `f(x::Float64) = 1; f(x) = 2` compiled to 2.
# Detection walks f's *unoptimized* typed code under both typings in
# parallel: one Method's lowered code typed two ways has the same statement
# list (inference wraps unreachable statements as `Core.Const(stmt)::Union{}`),
# so call site i on one side is call site i on the other. A divergence is a
# call that selects different methods where either is user code (defined
# outside Base/Core/Bennett — Base float primitives and soft_* differ by
# design), a user statement reachable natively but not on the trace, or a
# user Bool constant (`x isa Float64`) that differs. Same-method calls with
# different argument types are walked recursively (this reaches user code
# called through Base, e.g. `map(g, (x,))`); identical signatures are pruned.
# Non-unique matches on abstract types are not descended into. Bennett-blnv:
# a builtin that invokes a callable (`Core._apply_iterate` — the splat inside
# `Base.splat(g)` and `g ∘ h` —, `invokelatest`, `invoke`, ...) whose argument
# types differ is resolved to the call it performs (splat of fixed-length
# tuples, `invokelatest(g, args...)`) and checked as that call, or else is
# "unresolved" — in Base methods too, which were previously skipped, so
# `Base.splat(g)((x,))` silently compiled the generic `g`.
# Bennett-iffz: statement correspondence is only an assumption, so whenever
# it cannot be established the verdict is "unresolved" (a String starting
# with `_SFD_UNRESOLVED`), never `nothing` and never an internal error:
# a `@generated` method anywhere on the walk (its two specializations are
# different bodies — `T === Float64 ? :(Int8(1)) : :(Int8(2))` passed as
# "same method, same length"), two typed bodies of different length, and, in
# user methods, a splat / `invoke` whose argument types differ or a call
# whose argument types are not concrete and may select a user method (the
# walk cannot see what either side picks at run time). Bennett-dlp8: a call
# (or f itself) that selects a method under one typing and none under the
# other (no method / ambiguous: a MethodError) is "unresolved"; it was
# skipped, so `g(x::SoftFloat)` alone compiled where native Julia throws. A
# call with no method under both typings throws on both and is skipped.
# The Float64 overload refuses an unresolved f; the Tuple overload does not
# delegate it.
const _SFD_UNRESOLVED = "unresolved: "

_sfd_is_user(m::Method) = !(Base.moduleroot(m.module) in (Base, Core, Bennett))

_sfd_unresolved(why::String) = _SFD_UNRESOLVED * why

# Constants whose differing between the typings is expected: the type
# objects themselves (`typeof(x)` is Float64 vs SoftFloat) and tuples of them.
_sfd_typeish(@nospecialize(v)) = v isa Type || (v isa Tuple && any(_sfd_typeish, v))

_sfd_dead(ci, i) = ci.code[i] isa Core.Const && ci.ssavaluetypes[i] === Union{}

function _sfd_argtype(ci, @nospecialize(a))
    t = if a isa Core.SSAValue
        ci.ssavaluetypes[a.id]
    elseif a isa Core.SlotNumber
        ci.slottypes === nothing ? Any : ci.slottypes[a.id]
    elseif a isa Core.Argument
        ci.slottypes === nothing ? Any : ci.slottypes[a.n]
    elseif a isa GlobalRef
        isdefined(a.mod, a.name) && isconst(a.mod, a.name) ?
            Core.Typeof(getglobal(a.mod, a.name)) : Any
    elseif a isa QuoteNode
        Core.Typeof(a.value)
    elseif a isa Expr
        Any
    else
        Core.Typeof(a)
    end
    return Core.Compiler.widenconst(t)
end

# Every method a call signature can select (one for a concrete signature).
# Bennett-dlp8: `Method[]` when none can be selected — no method matches, or
# (concrete signature) the call is ambiguous; either way the call throws a
# MethodError. `nothing` only when the method-table query itself fails
# (`_methods_by_ftype` returns `nothing` / `false`): the walk cannot tell.
function _sfd_methods(@nospecialize(sig))
    ms = Base._methods_by_ftype(sig, -1, Base.get_world_counter())
    (ms === nothing || ms === false) && return nothing
    return Method[mm.method for mm in ms]
end

# Bennett-dlp8: compare method availability under the two typings. `nothing`
# when both select some method(s) (the caller compares them) or both select
# none (the call throws a MethodError on both — the same behaviour, so not a
# divergence); otherwise an "unresolved" verdict: a lookup failed, or one
# typing selects a method and the other none, so the trace would return a
# value where native Julia throws a MethodError, or the reverse.
function _sfd_availability(@nospecialize(stF), @nospecialize(stS), mF, mS, site::String)
    (mF === nothing || mS === nothing) && return _sfd_unresolved(
        "the method lookup for $site failed for " *
        "$(mF === nothing ? stF : stS)")
    isempty(mF) == isempty(mS) && return nothing
    return isempty(mF) ?
        _sfd_unresolved("$site has no unique method for Float64 arguments " *
            "($stF; natively a MethodError) but selects $(_sfd_show(mS)) on " *
            "the SoftFloat trace (Bennett-dlp8)") :
        _sfd_unresolved("$site selects $(_sfd_show(mF)) natively but has no " *
            "unique method on the SoftFloat trace ($stS; a MethodError there) " *
            "(Bennett-dlp8)")
end

_sfd_call(@nospecialize(s)) =
    s isa Expr && s.head === :call ? s :
    s isa Expr && s.head === :(=) && s.args[2] isa Expr &&
        s.args[2].head === :call ? s.args[2] : nothing

_sfd_show(ms::Vector{Method}) = join((sprint(show, m) for m in ms), " | ")

const _SFD_MAX_NODES = 5_000

# Bennett-blnv: builtins that call a callable passed to them. Each is either
# resolved to the argument types of the call it performs or "unresolved".
const _SFD_CALLING_BUILTINS = Tuple(typeof(getglobal(Core, n)) for n in
    (:_apply_iterate, :invokelatest, :_call_latest, :invoke, :invoke_in_world,
     :_call_in_world, :_call_in_world_total, :finalizer, :applicable,
     :modifyfield!, :modifyglobal!, :memoryrefmodify!)
    if isdefined(Core, n))

_sfd_builtin_name(@nospecialize(b)) =
    isdefined(b, :instance) ? "Core.$(nameof(b.instance))" : string(b)

# For a builtin call with argument types `a`: `nothing` when the builtin does
# not invoke a callable; the argument types of the call it performs for a
# splat of fixed-length tuples (`_apply_iterate(iterate, g, (x,), (y, z))` is
# `g(x, y, z)`) and for `invokelatest(g, args...)`; `:unresolved` otherwise
# (splat of a Vector / Vararg tuple, `invoke`, world-age calls, ...).
function _sfd_builtin_callee(a::Vector{Any})
    b = a[1]
    b in _SFD_CALLING_BUILTINS || return nothing
    if isdefined(Core, :invokelatest) && b === typeof(Core.invokelatest) ||
       isdefined(Core, :_call_latest) && b === typeof(Core._call_latest)
        length(a) >= 2 || return :unresolved
        return Any[a[2:end]...]
    elseif b === typeof(Core._apply_iterate)
        (length(a) >= 3 && a[2] === typeof(iterate)) || return :unresolved
        out = Any[a[3]]
        for t in a[4:end]
            (t isa DataType && t <: Tuple && !Base.isvatuple(t)) ||
                return :unresolved
            append!(out, t.parameters)
        end
        return out
    end
    return :unresolved
end

function _sfd_walk(@nospecialize(sigF), @nospecialize(sigS), m::Method, visited)
    (sigF, sigS) in visited && return nothing
    push!(visited, (sigF, sigS))
    Base.hasgenerator(m) && return _sfd_unresolved(
        "$m is a @generated method, whose Float64 and SoftFloat " *
        "specializations are different generated bodies")
    length(visited) > _SFD_MAX_NODES && error(
        "reversible_compile(f, Float64...): dispatch-divergence walk exceeded " *
        "$_SFD_MAX_NODES nodes at $m (Bennett-czox)")
    rF = Base.code_typed_by_type(sigF; optimize=false)
    rS = Base.code_typed_by_type(sigS; optimize=false)
    (length(rF) == 1 && length(rS) == 1) || return nothing
    ciF = rF[1][1]; ciS = rS[1][1]
    length(ciF.code) == length(ciS.code) || return _sfd_unresolved(
        "typed code of $m has $(length(ciF.code)) statements for Float64 " *
        "arguments but $(length(ciS.code)) on the SoftFloat trace")
    user = _sfd_is_user(m)
    for i in eachindex(ciF.code)
        _sfd_dead(ciF, i) && continue
        if _sfd_dead(ciS, i)
            user && return "statement $i of $m runs natively but is " *
                           "unreachable on the SoftFloat trace"
            continue
        end
        if user
            tF = ciF.ssavaluetypes[i]; tS = ciS.ssavaluetypes[i]
            tF isa Core.Const && tS isa Core.Const && tF.val isa Bool &&
                tS.val isa Bool && tF.val !== tS.val &&
                return "statement $i of $m is the constant $(tF.val) natively " *
                       "but $(tS.val) on the SoftFloat trace (a type test)"
            # Bennett-iffz: any other same-typed constant (not a type
            # object) that differs is a divergence too, e.g. `Int8(1)` vs
            # `Int8(2)`; 0.0 vs SoftFloat(0.0) differ in type and are expected.
            tF isa Core.Const && tS isa Core.Const &&
                typeof(tF.val) === typeof(tS.val) && !_sfd_typeish(tF.val) &&
                tF.val !== tS.val &&
                return "statement $i of $m is the constant $(repr(tF.val)) " *
                       "natively but $(repr(tS.val)) on the SoftFloat trace"
        end
        cF = _sfd_call(ciF.code[i]); cF === nothing && continue
        cS = _sfd_call(ciS.code[i])
        cS === nothing && return _sfd_unresolved(
            "statement $i of $m is a call for Float64 arguments but not on " *
            "the SoftFloat trace")
        aF = Any[_sfd_argtype(ciF, a) for a in cF.args]
        aS = Any[_sfd_argtype(ciS, a) for a in cS.args]
        aF[1] === Union{} && continue
        stF = Tuple{aF...}; stS = Tuple{aS...}
        if aF[1] <: Core.Builtin
            stF == stS && continue
            user && aF[1] in (typeof(Core._apply_iterate), typeof(Core.invoke)) &&
                return _sfd_unresolved(
                    "call $i in $m is a splat or invoke whose argument types " *
                    "differ between Float64 and SoftFloat")
            # Bennett-blnv: a builtin that invokes a callable (a splat in
            # Base.splat / ComposedFunction, invokelatest, ...) is replaced by
            # the call it performs, or refused — in Base methods too.
            while aF[1] <: Core.Builtin
                rF = _sfd_builtin_callee(aF); rS = _sfd_builtin_callee(aS)
                rF === nothing && rS === nothing && break
                (rF isa Vector && rS isa Vector) || return _sfd_unresolved(
                    "call $i in $m invokes a callable through " *
                    "$(_sfd_builtin_name(aF[1])) with argument types that " *
                    "differ between Float64 and SoftFloat, and the walk " *
                    "cannot resolve the call it performs (Bennett-blnv)")
                aF = rF; aS = rS
            end
            aF[1] <: Core.Builtin && continue
            (aF[1] === Union{}) != (aS[1] === Union{}) && return _sfd_unresolved(
                "call $i in $m invokes a callable through a builtin that never " *
                "returns under only one of the Float64 / SoftFloat typings")
            aF[1] === Union{} && continue
            stF = Tuple{aF...}; stS = Tuple{aS...}
            stF == stS && continue
        end
        mF = _sfd_methods(stF); mS = _sfd_methods(stS)
        r = _sfd_availability(stF, stS, mF, mS, "call $i in $m")
        r === nothing || return r
        isempty(mF) && continue   # MethodError under both typings
        user && !(Base.isdispatchtuple(stF) && Base.isdispatchtuple(stS)) &&
            (any(_sfd_is_user, mF) || any(_sfd_is_user, mS)) &&
            return _sfd_unresolved(
                "call $i in $m has non-concrete argument types and may select " *
                "a user method at run time")
        if mF != mS
            (any(_sfd_is_user, mF) || any(_sfd_is_user, mS)) &&
                return "call $i in $m selects $(_sfd_show(mF)) natively but " *
                       "$(_sfd_show(mS)) on the SoftFloat trace"
            continue
        end
        (stF == stS || length(mF) != 1) && continue
        r = _sfd_walk(stF, stS, mF[1], visited)
        r === nothing || return r
    end
    return nothing
end

"""
    _softfloat_dispatch_divergence(f, N) -> Union{Nothing, String}

`nothing` when calling `f` on `N` SoftFloat values selects the same user
methods and type-test outcomes as calling it on `N` Float64 values; otherwise
a description of the first divergence found (Bennett-czox), or a String
starting with `_SFD_UNRESOLVED` when correspondence of the two traces cannot
be established (`@generated` methods, unmatched bodies — Bennett-iffz).
"""
function _softfloat_dispatch_divergence(f, N::Int)
    sigF = Tuple{Core.Typeof(f), ntuple(_ -> Float64, N)...}
    sigS = Tuple{Core.Typeof(f), ntuple(_ -> SoftFloat, N)...}
    mF = _sfd_methods(sigF); mS = _sfd_methods(sigS)
    r = _sfd_availability(sigF, sigS, mF, mS, "$f")
    r === nothing || return r
    isempty(mF) && return nothing   # no method either way: the trace throws loudly
    if mF != mS
        (any(_sfd_is_user, mF) || any(_sfd_is_user, mS)) &&
            return "$f selects $(_sfd_show(mF)) for Float64 arguments but " *
                   "$(_sfd_show(mS)) for SoftFloat arguments"
        return nothing
    end
    length(mF) == 1 || return nothing
    return _sfd_walk(sigF, sigS, mF[1], Set{Any}())
end

function _check_softfloat_dispatch(f, N::Int)
    d = _softfloat_dispatch_divergence(f, N)
    d !== nothing && startswith(d, _SFD_UNRESOLVED) && throw(ArgumentError(
        "reversible_compile(f, Float64...): cannot verify that tracing $f on " *
        "SoftFloat values selects the same code as f(::Float64...): " *
        "$(chopprefix(d, _SFD_UNRESOLVED)). A @generated method (or a body " *
        "the walk cannot match statement by statement) cannot be traced on " *
        "SoftFloat soundly; `reversible_compile(f, Tuple{Float64...})` " *
        "compiles the native method instead (Bennett-iffz)"))
    d === nothing || throw(ArgumentError(
        "reversible_compile(f, Float64...): $d. The Float64 overload traces f " *
        "on SoftFloat values, and SoftFloat is not a Float64 / AbstractFloat / " *
        "Real / Number, so that trace would bypass a Float64-specific method " *
        "or branch and compile a different function than f(::Float64...). " *
        "Make the method generic or call it through a generic wrapper " *
        "(Bennett-czox)"))
    return nothing
end

const _FLOAT64_OVERLOAD_KWARGS =(:optimize, :max_loop_iterations,
                                  :compact_calls, :strategy, :add, :mul,
                                  :fold_constants, :target,
                                  :auto_self_reversing,
                                  :mem, :persistent_impl, :hashcons)
# Kwargs that only make sense on the Tuple-of-integers path.
const _FLOAT64_OVERLOAD_CROSS_REJECT = (:bit_width,)

function reversible_compile(f::F, float_types::Type{Float64}...;
                            optimize::Bool=_DEFAULT_COMPILE_OPTIONS.optimize,
                            max_loop_iterations::Int=_DEFAULT_COMPILE_OPTIONS.max_loop_iterations,
                            compact_calls::Bool=_DEFAULT_COMPILE_OPTIONS.compact_calls,
                            strategy::Symbol=_DEFAULT_COMPILE_OPTIONS.strategy,
                            add::Symbol=_DEFAULT_COMPILE_OPTIONS.add,
                            mul::Symbol=_DEFAULT_COMPILE_OPTIONS.mul,
                            fold_constants::Bool=_DEFAULT_COMPILE_OPTIONS.fold_constants,
                            target::Symbol=_DEFAULT_COMPILE_OPTIONS.target,
                            auto_self_reversing::Bool=_DEFAULT_COMPILE_OPTIONS.auto_self_reversing,
                            mem::Symbol=_DEFAULT_COMPILE_OPTIONS.mem,
                            persistent_impl::Symbol=_DEFAULT_COMPILE_OPTIONS.persistent_impl,
                            hashcons::Symbol=_DEFAULT_COMPILE_OPTIONS.hashcons,
                            kwargs...) where {F}
    _reject_unknown_kwargs("Float64 overload", _FLOAT64_OVERLOAD_KWARGS,
                           _FLOAT64_OVERLOAD_CROSS_REJECT, kwargs)
    strategy in (:auto, :expression) ||
        throw(ArgumentError("reversible_compile: strategy=:$strategy not supported for Float64 " *
              "(2^64 table would be absurd); use :auto or :expression"))
    N = length(float_types)
    N >= 1 || throw(ArgumentError("Need at least one Float64 argument type"))
    N <= 3 || throw(ArgumentError("Float64 compile supports up to 3 arguments (got $N)"))
    _check_softfloat_result(f, N)
    _check_softfloat_dispatch(f, N)

    # Use @inline at the call site to force Julia to inline f through the SoftFloat
    # dispatch chain. Without this, Julia emits struct-passing ABI (alloca + store +
    # call(ptr...)) which ir_extract can't handle. @inline at the call site makes
    # Julia inline f → SoftFloat./ → soft_fdiv etc., producing clean integer IR
    # with direct soft_* calls that the callee registry recognizes.
    if N == 1
        w = (x::UInt64) -> _softfloat_result(@inline f(SoftFloat(x)))
        return reversible_compile(w, UInt64; optimize, max_loop_iterations,
                                  compact_calls, add, mul, fold_constants, target,
                                  auto_self_reversing,
                                  mem, persistent_impl, hashcons)
    elseif N == 2
        w = (a::UInt64, b::UInt64) -> _softfloat_result(@inline f(SoftFloat(a), SoftFloat(b)))
        return reversible_compile(w, UInt64, UInt64; optimize, max_loop_iterations,
                                  compact_calls, add, mul, fold_constants, target,
                                  auto_self_reversing,
                                  mem, persistent_impl, hashcons)
    elseif N == 3
        w = (a::UInt64, b::UInt64, c::UInt64) -> _softfloat_result(@inline f(SoftFloat(a), SoftFloat(b), SoftFloat(c)))
        return reversible_compile(w, UInt64, UInt64, UInt64; optimize, max_loop_iterations,
                                  compact_calls, add, mul, fold_constants, target,
                                  auto_self_reversing,
                                  mem, persistent_impl, hashcons)
    else
        throw(ArgumentError("Float64 compile supports up to 3 arguments (got $N)"))
    end
end

# ---- Float64 + CompileOptions wrapper (Bennett-u71l / U161) ----
function reversible_compile(f::F, ::Type{Float64}, opts::CompileOptions) where {F}
    _check_field_at_default("Float64 overload", opts, :bit_width)
    return reversible_compile(f, Float64;
        optimize            = opts.optimize,
        max_loop_iterations = opts.max_loop_iterations,
        compact_calls       = opts.compact_calls,
        strategy            = opts.strategy,
        add                 = opts.add,
        mul                 = opts.mul,
        fold_constants      = opts.fold_constants,
        target              = opts.target,
        auto_self_reversing = opts.auto_self_reversing,
        mem                 = opts.mem,
        persistent_impl     = opts.persistent_impl,
        hashcons            = opts.hashcons,
    )
end

function reversible_compile(f::F, ::Type{Float64}, ::Type{Float64}, opts::CompileOptions) where {F}
    _check_field_at_default("Float64 overload", opts, :bit_width)
    return reversible_compile(f, Float64, Float64;
        optimize            = opts.optimize,
        max_loop_iterations = opts.max_loop_iterations,
        compact_calls       = opts.compact_calls,
        strategy            = opts.strategy,
        add                 = opts.add,
        mul                 = opts.mul,
        fold_constants      = opts.fold_constants,
        target              = opts.target,
        auto_self_reversing = opts.auto_self_reversing,
        mem                 = opts.mem,
        persistent_impl     = opts.persistent_impl,
        hashcons            = opts.hashcons,
    )
end

function reversible_compile(f::F, ::Type{Float64}, ::Type{Float64}, ::Type{Float64},
                            opts::CompileOptions) where {F}
    _check_field_at_default("Float64 overload", opts, :bit_width)
    return reversible_compile(f, Float64, Float64, Float64;
        optimize            = opts.optimize,
        max_loop_iterations = opts.max_loop_iterations,
        compact_calls       = opts.compact_calls,
        strategy            = opts.strategy,
        add                 = opts.add,
        mul                 = opts.mul,
        fold_constants      = opts.fold_constants,
        target              = opts.target,
        auto_self_reversing = opts.auto_self_reversing,
        mem                 = opts.mem,
        persistent_impl     = opts.persistent_impl,
        hashcons            = opts.hashcons,
    )
end
