# Bennett-dlp8: the SoftFloat dispatch-divergence walk (Bennett-czox / iffz /
# blnv) skipped any call whose Float64 typing had no matching method
# (`mF === nothing && continue`). A callable defined only on SoftFloat was
# therefore traced as if the native call existed. Reviewer's witness (executed):
#   g(x::Bennett.SoftFloat) = !signbit(x); f(x) = Base.splat(g)((x,))
# compiled, passed verification and returned 1 on input 1.0, while native
# f(1.0) throws a MethodError. The direct call `f(x) = g(x)` had the same hole.
#
# Invariant: the walk skips a call only when both typings select the same
# method(s), or both select none (the call throws a MethodError either way).
# Asymmetric availability — one typing selects a method, the other none (no
# method, or an ambiguity) — is "unresolved", in user and Base methods, on the
# ordinary-call path and after a builtin splat / invokelatest is resolved; at
# the top level too (`f(x::SoftFloat)` alone). A native MethodError never
# becomes a circuit that returns a value.

using Test
using Bennett

const _SF_DLP8 = Bennett.SoftFloat
_bits_dlp8(x::Float64) = reinterpret(UInt64, x)
const _EDGE_DLP8 = Float64[0.0, -0.0, 1.0, -1.0, 1.5, -2.5, Inf, -Inf, NaN,
                           -NaN, nextfloat(0.0), -nextfloat(0.0), floatmax(Float64)]

_msg_dlp8(f, Ts...) = try
    reversible_compile(f, Ts...); "no error"
catch e
    e isa ArgumentError ? sprint(showerror, e) :
        "non-ArgumentError: $(typeof(e)): " * sprint(showerror, e)
end

# availability => (unary callable, binary callable)
dlp8_b1(x) = !signbit(x);                 dlp8_b2(x, y) = !signbit(x) & signbit(y)
dlp8_s1(x::_SF_DLP8) = !signbit(x);       dlp8_s2(x::_SF_DLP8, y) = !signbit(x)
dlp8_f1(x::Float64) = !signbit(x);        dlp8_f2(x::Float64, y) = !signbit(x)
dlp8_n1(x::Int) = true;                   dlp8_n2(x::Int, y) = true

const _AVAIL_DLP8 = [:both => (dlp8_b1, dlp8_b2), :softfloat_only => (dlp8_s1, dlp8_s2),
                     :float64_only => (dlp8_f1, dlp8_f2), :neither => (dlp8_n1, dlp8_n2)]

# wrapper kind => (g1, g2) -> unary entry
const _WRAP_DLP8 = [
    :direct  => (g1, g2) -> (x -> g1(x)),
    :splat   => (g1, g2) -> (x -> Base.splat(g1)((x,))),
    :compose => (g1, g2) -> (x -> (identity ∘ g1)(x)),
    :fix1    => (g1, g2) -> (x -> Base.Fix1(g2, x)(x)),
    :fix2    => (g1, g2) -> (x -> Base.Fix2(g2, x)(x)),
    :map     => (g1, g2) -> (x -> map(g1, (x,))[1]),
]

dlp8_am(x::AbstractFloat, y) = true
dlp8_am(x, y::AbstractFloat) = false
dlp8_am(x, y) = !signbit(x)
dlp8_top(x::_SF_DLP8) = !signbit(x)

_throws_dlp8(f, x) = try f(x); false catch e; e isa MethodError end

@testset "Bennett-dlp8: asymmetric method availability is refused" begin
    @testset "reviewer witness" begin
        w(x) = Base.splat(dlp8_s1)((x,))
        @test _throws_dlp8(w, 1.0)
        d = Bennett._softfloat_dispatch_divergence(w, 1)
        @test d !== nothing && startswith(d, Bennett._SFD_UNRESOLVED) &&
              occursin("MethodError", d)
        m = _msg_dlp8(w, Float64)
        @test occursin("cannot verify", m) && occursin("MethodError", m)
    end

    for (kind, mk) in _WRAP_DLP8, (avail, (g1, g2)) in _AVAIL_DLP8,
        guarded in (false, true)
        inner = mk(g1, g2)
        # guarded: the call runs only for non-negative x, so neither typing
        # always throws and the decision is the walk's alone.
        f = guarded ? (x -> signbit(x) ? false : inner(x)) : inner
        @testset "$kind $avail guarded=$guarded" begin
            d = Bennett._softfloat_dispatch_divergence(f, 1)
            if avail === :both
                @test d === nothing
                c = reversible_compile(f, Float64)
                @test verify_reversibility(c)
                @test all(x -> (simulate(c, _bits_dlp8(x)) != 0) == f(x), _EDGE_DLP8)
            elseif avail === :neither
                # MethodError on both typings: not a dispatch divergence.
                @test _throws_dlp8(f, 1.0)
                @test d === nothing
                guarded || @test occursin("always throws", _msg_dlp8(f, Float64))
            else
                # native: MethodError iff the Float64 method is missing
                @test _throws_dlp8(f, 1.0) == (avail === :softfloat_only)
                m = _msg_dlp8(f, Float64)
                @test startswith(m, "ArgumentError")
                if avail === :float64_only && !guarded
                    # The trace itself always throws: refused before the walk.
                    @test occursin("always throws", m)
                elseif avail === :float64_only
                    # Refused: either as a call that is unreachable on the
                    # trace (czox, user methods) or as asymmetric (dlp8).
                    @test d !== nothing
                    @test occursin("reversible_compile(f, Float64...)", m)
                else
                    @test d !== nothing && startswith(d, Bennett._SFD_UNRESOLVED) &&
                          occursin("MethodError", d)
                    @test occursin("cannot verify", m) && occursin("MethodError", m)
                end
            end
        end
    end

    # An ambiguity is a MethodError too: natively ambiguous, a unique method
    # on the trace.
    @testset "ambiguous natively" begin
        for f in (x -> dlp8_am(x, x), x -> Base.splat(dlp8_am)((x, x)))
            @test _throws_dlp8(f, 1.0)
            m = _msg_dlp8(f, Float64)
            @test occursin("cannot verify", m) && occursin("MethodError", m)
        end
    end

    # The entry function itself defined only on SoftFloat.
    @testset "entry defined only on SoftFloat" begin
        @test _throws_dlp8(dlp8_top, 1.0)
        d = Bennett._softfloat_dispatch_divergence(dlp8_top, 1)
        @test d !== nothing && startswith(d, Bennett._SFD_UNRESOLVED) &&
              occursin("MethodError", d)
        @test occursin("MethodError", _msg_dlp8(dlp8_top, Float64))
        # The Tuple overload must not delegate it to the SoftFloat trace.
        @test _msg_dlp8(dlp8_top, Tuple{Float64}) != "no error"
    end

    # invokelatest resolves to the call it performs: same rule.
    @testset "invokelatest" begin
        f = x -> Base.invokelatest(dlp8_s1, x)
        d = Bennett._softfloat_dispatch_divergence(f, 1)
        @test d !== nothing && occursin("MethodError", d)
        @test Bennett._softfloat_dispatch_divergence(
            x -> Base.invokelatest(dlp8_b1, x), 1) === nothing
    end
end
