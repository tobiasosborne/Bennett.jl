# Bennett-72xf: the SoftFloat dispatch-divergence walk (Bennett-czox / iffz /
# blnv / dlp8) did not descend into a call whose argument types are a Union
# (more than one candidate method), and refused a non-concrete call site only
# in user methods. Witness (executed, verify_reversibility passed):
#   hb_d(x::Float64) = signbit(x); hb_d(x) = !signbit(x)
#   hb_u(x::Int) = false;          hb_u(x) = hb_d(x)
#   fb(x) = (y = signbit(x) ? 1 : x; map(hb_u, (y,))[1])
# Inside `map` (a Base method) `hb_u(::Union{Int,Float64})` has the same two
# candidates under both typings, so the walk stopped; natively the Float64
# value reaches hb_d(::Float64), on the SoftFloat trace the generic hb_d.
# reversible_compile(fb, Float64) returned 1 at 1.0; native fb(1.0) == false.
#
# Invariant: a call whose argument types are a Union of concrete types is
# split into its concrete calls (a Float64 component paired with the
# SoftFloat one, identical components with each other) and each is checked
# and walked like a concrete call — in Base and user methods; a call whose
# argument types are otherwise non-concrete, or that has more than one
# candidate, and may select a user method is "unresolved" in Base methods
# too, not only in user methods.

using Test
using Bennett

_bits_72xf(x::Float64) = reinterpret(UInt64, x)
const _EDGE_72XF = Float64[0.0, -0.0, 1.0, -1.0, 1.5, -2.5, Inf, -Inf,
                           nextfloat(0.0), -nextfloat(0.0), floatmax(Float64)]

_msg_72xf(f) = try
    reversible_compile(f, Float64); "no error"
catch e
    e isa ArgumentError ? sprint(showerror, e) :
        "non-ArgumentError: $(typeof(e)): " * sprint(showerror, e)
end

# Divergent callees: the Float64 component reaches a Float64-specific method.
hb_d_72xf(x::Float64) = signbit(x);   hb_d_72xf(x) = !signbit(x)
hb_u_72xf(x::Int) = false;            hb_u_72xf(x) = hb_d_72xf(x)   # indirect
hb_w_72xf(x::Float64) = signbit(x);   hb_w_72xf(x) = false          # direct
hb_v_72xf(a, b::Int) = false;         hb_v_72xf(a, b) = hb_d_72xf(b)
# Benign callees: generic on the Float64 component.
ok_one_72xf(x) = iszero(x) | (x isa Int)                            # one method
ok_two_72xf(x::Int) = false;          ok_two_72xf(x) = !signbit(x)  # two, non-divergent
ok_v_72xf(a, b::Int) = false;         ok_v_72xf(a, b) = !signbit(b)

uy_72xf(x) = signbit(x) ? 1 : x          # Union{Int64, Float64}
ub_72xf(x) = signbit(x) ? true : x       # Union{Bool, Float64}

# wrapper kind => (unary g, binary g2, union source) -> unary entry
const _WRAP_72XF = [
    :user    => (g, g2, u) -> (x -> g(u(x))),
    :map1    => (g, g2, u) -> (x -> map(g, (u(x),))[1]),
    :map3    => (g, g2, u) -> (x -> map(g, (u(x), 2, 3))[1]),
    :fix1    => (g, g2, u) -> (x -> Base.Fix1(g2, false)(u(x))),
    :compose => (g, g2, u) -> (x -> (identity ∘ g)(u(x))),
]
# Shapes whose walk verdict is checked (they do not lower today: jlcallframe
# allocas), so only the verdict is pinned. (`map(g, y)` on the scalar itself
# selects map(f, ::Number) natively but the generic map(f, A) on SoftFloat —
# different Base methods, which the walk does not descend into; it fails to
# lower today.)
const _WALK_ONLY_72XF = [
    :bcast   => (g, g2, u) -> (x -> g.((u(x),))[1]),
    :foldl   => (g, g2, u) -> (x -> foldl(g2, (u(x),); init=false)),
    :itermap => (g, g2, u) -> (x -> first(Iterators.map(g, (u(x),)))),
]

@testset "Bennett-72xf: Union-typed calls inside Base forwarders" begin
    @testset "witness" begin
        fb(x) = (y = signbit(x) ? 1 : x; map(hb_u_72xf, (y,))[1])
        @test fb(1.0) == false
        d = Bennett._softfloat_dispatch_divergence(fb, 1)
        @test d !== nothing
        msg = _msg_72xf(fb)
        @test occursin("reversible_compile(f, Float64...)", msg)
        @test occursin("hb_d_72xf", msg)
    end

    @testset "divergent: $wk / $(nameof(g)) / $(nameof(u))" for (wk, mk) in
            vcat(_WRAP_72XF, _WALK_ONLY_72XF),
            (g, g2) in ((hb_u_72xf, hb_v_72xf), (hb_w_72xf, hb_v_72xf)),
            u in (uy_72xf, ub_72xf)
        f = mk(g, g2, u)
        d = Bennett._softfloat_dispatch_divergence(f, 1)
        @test d !== nothing
        if any(p -> p.first === wk, _WRAP_72XF)
            msg = _msg_72xf(f)
            @test occursin("reversible_compile(f, Float64...)", msg)
            @test occursin("_72xf", msg)   # names the divergent user method
        end
    end

    @testset "non-splittable argument types are unresolved, Base or user" begin
        for f in (x -> hb_u_72xf(Base.inferencebarrier(x)),     # user method, ::Any
                  x -> map(hb_u_72xf, (Base.inferencebarrier(x),))[1], # in map
                  x -> Base.Fix1(hb_v_72xf, false)(Base.inferencebarrier(x)),
                  x -> Base.splat(hb_u_72xf)((Base.inferencebarrier(x),)),
                  x -> hb_u_72xf.((uy_72xf(x),))[1])     # broadcast: UnionAll Broadcasted
            d = Bennett._softfloat_dispatch_divergence(f, 1)
            @test d isa String && startswith(d, Bennett._SFD_UNRESOLVED)
            @test occursin("Bennett-72xf", d)
        end
    end

    @testset "known gap: different Base methods are not descended into" begin
        # map(g, ::Float64) is map(f, ::Number); map(g, ::SoftFloat) the
        # generic map(f, A). Not walked; refused later at lowering.
        f = x -> map(hb_u_72xf, uy_72xf(x))
        @test_broken Bennett._softfloat_dispatch_divergence(f, 1) !== nothing
        @test_throws Exception reversible_compile(f, Float64)
    end

    @testset "benign: $wk / $(nameof(g)) / $(nameof(u))" for (wk, mk) in _WRAP_72XF,
            (g, g2) in ((ok_one_72xf, ok_v_72xf), (ok_two_72xf, ok_v_72xf)),
            u in (uy_72xf, ub_72xf)
        f = mk(g, g2, u)
        @test Bennett._softfloat_dispatch_divergence(f, 1) === nothing
        c = reversible_compile(f, Float64)
        @test verify_reversibility(c)
        @test all(x -> (simulate(c, _bits_72xf(x)) != 0) == f(x), _EDGE_72XF)
    end
end
