# Bennett-blnv: the SoftFloat dispatch-divergence walk (Bennett-czox / iffz)
# only refused a splat (`Core._apply_iterate`) whose argument types differ when
# it sat in a *user* method. A Base wrapper that forwards to a user callable
# through a splat — `Base.splat(g)`, `ComposedFunction` (`∘`) — splats inside
# Base, so the walk skipped the call and never compared `g(::Float64)` with
# `g(::SoftFloat)`. Reviewer's witness (executed):
#   g(x::Float64) = signbit(x); g(x) = !signbit(x); f(x) = Base.splat(g)((x,))
# compiled to 1 on input 1.0 on both Float64 entry points; native is 0.
# Same gap: `Core.invokelatest` (a builtin in Julia 1.12) was never resolved.
#
# Invariant: a builtin call that invokes a callable (`_apply_iterate`,
# `invokelatest`, `invoke`, ...) and whose argument types differ between the
# Float64 and SoftFloat typings is either resolved to the call it performs
# (a splat of fixed-length tuples, `invokelatest(f, args...)`) and checked like
# any other call, or refused as unresolved — in Base methods as in user ones.
# The Float64 overload then refuses a divergent f; the `Tuple{Float64...}`
# overload compiles the native method.

using Test
using Bennett
using Random

_bitsb(x::Float64) = reinterpret(UInt64, x)

const _EDGE_BLNV = Float64[0.0, -0.0, 1.0, -1.0, 1.5, -2.5, Inf, -Inf, NaN,
                           -NaN, nextfloat(0.0), -nextfloat(0.0), floatmax(Float64)]

_inputs_blnv(N) = N == 1 ? [(x,) for x in _EDGE_BLNV] :
    [(a, b) for a in _EDGE_BLNV[1:7] for b in _EDGE_BLNV[1:7]]

_sim_blnv(c, xs) = length(xs) == 1 ? simulate(c, _bitsb(xs[1])) :
                                     simulate(c, map(_bitsb, xs))

_msg_blnv(f, Ts...) = try
    reversible_compile(f, Ts...); "no error"
catch e
    e isa ArgumentError ? sprint(showerror, e) :
        "non-ArgumentError: $(typeof(e)): " * sprint(showerror, e)
end

function _check_native_blnv(c, f, N)
    @test verify_reversibility(c)
    bad = [xs for xs in _inputs_blnv(N) if (_sim_blnv(c, xs) != 0) != f(xs...)]
    isempty(bad) || @info "mismatches" first(bad, 3)
    @test isempty(bad)
end

# Callables: divergent (a Float64-specific method that SoftFloat skips) and
# generic (one method), unary and binary.
blnv_d1(x::Float64) = signbit(x);    blnv_d1(x) = !signbit(x)
blnv_g1(x) = signbit(x)
blnv_d2(x::Float64, y) = signbit(x); blnv_d2(x, y) = !signbit(x)
blnv_g2(x, y) = signbit(x) & !signbit(y)

# The reviewer's witness, verbatim.
blnv_witness(x) = Base.splat(blnv_d1)((x,))

@testset "Bennett-blnv: SoftFloat walk resolves or refuses Base wrappers" begin
    @testset "reviewer witness" begin
        @test blnv_witness(1.0) === false
        @test occursin("blnv_d1(x::Float64)", _msg_blnv(blnv_witness, Float64))
        c = reversible_compile(blnv_witness, Tuple{Float64})
        _check_native_blnv(c, blnv_witness, 1)
    end

    # wrapper kind => (unary callable, binary callable) -> entry functions by
    # arity. Fix1/Fix2 bind a binary callable, so arity 1 reuses the argument.
    wrappers = [
        :splat     => (g1, g2) -> (x -> Base.splat(g1)((x,)),
                                   (x, y) -> Base.splat(g2)((x, y))),
        :compose_o => (g1, g2) -> (x -> (identity ∘ g1)(x),
                                   (x, y) -> (identity ∘ g2)(x, y)),
        :compose_i => (g1, g2) -> (x -> (g1 ∘ identity)(x),
                                   (x, y) -> (Base.splat(g2) ∘ tuple)(x, y)),
        :fix1      => (g1, g2) -> (x -> Base.Fix1(g2, x)(x),
                                   (x, y) -> Base.Fix1(g2, x)(y)),
        :fix2      => (g1, g2) -> (x -> Base.Fix2(g2, x)(x),
                                   (x, y) -> Base.Fix2(g2, y)(x)),
        :map       => (g1, g2) -> (x -> map(g1, (x,))[1],
                                   (x, y) -> map(g2, (x,), (y,))[1]),
    ]
    for (kind, mk) in wrappers, divergent in (true, false), N in (1, 2)
        fs = divergent ? mk(blnv_d1, blnv_d2) : mk(blnv_g1, blnv_g2)
        f = fs[N]
        Ts = ntuple(_ -> Float64, N)
        @testset "$kind divergent=$divergent arity=$N" begin
            if divergent
                # Natively the Float64 method runs; the SoftFloat trace would
                # take the generic one. Must be refused, naming the selection.
                m = _msg_blnv(f, Ts...)
                @test occursin("reversible_compile(f, Float64...)", m)
                @test occursin(N == 1 && kind ∉ (:fix1, :fix2) ?
                               "blnv_d1(x::Float64)" : "blnv_d2(x::Float64, y)", m)
                # The Tuple overload must not delegate: native-equal circuit.
                _check_native_blnv(reversible_compile(f, Tuple{Ts...}), f, N)
            else
                @test Bennett._softfloat_dispatch_divergence(f, N) === nothing
                _check_native_blnv(reversible_compile(f, Ts...), f, N)
            end
        end
    end

    # Core.invokelatest is a builtin: the call it performs is f(args...).
    # (Its result type is Any, so only the walk's verdict is pinned.)
    @testset "invokelatest arity=$N" for N in (1, 2)
        fd = N == 1 ? (x -> Base.invokelatest(blnv_d1, x)) :
                      ((x, y) -> Base.invokelatest(blnv_d2, x, y))
        fg = N == 1 ? (x -> Base.invokelatest(blnv_g1, x)) :
                      ((x, y) -> Base.invokelatest(blnv_g2, x, y))
        d = Bennett._softfloat_dispatch_divergence(fd, N)
        @test d !== nothing && occursin("::Float64", d)
        @test Bennett._softfloat_dispatch_divergence(fg, N) === nothing
    end

    # A splat in Base whose arguments are not fixed-length tuples cannot be
    # resolved to one call: refused as unresolved, not skipped.
    @testset "unresolvable splat in Base is refused" begin
        blnv_vsplat(x) = Base.splat(blnv_d1)([x])
        m = _msg_blnv(blnv_vsplat, Float64)
        @test occursin("cannot verify", m) && occursin("_apply_iterate", m)
    end
end
