# Bennett-iffz: the SoftFloat dispatch-divergence check (Bennett-czox) assumed
# that one Method typed under Float64 and under SoftFloat has one statement
# list. A `@generated` method breaks that: its two specializations are
# different generated bodies.
#   T3 (wrong result): `T === Float64 ? :(Int8(1)) : :(Int8(2))` — same Method,
#      same statement count, differing Int8 constants — passed the check, and
#      both the Float64 overload and `Tuple{Float64}` compiled 2 (native: 1).
#   T6 (rejects valid): `:(x)` vs `:(identity(identity(x)))` has different
#      statement counts and tripped an unconditional "introspection internals
#      changed" error on BOTH entry points, killing the Tuple route's native
#      fallback.
# Post-fix: a generated method anywhere on the walk, or two bodies that cannot
# be matched statement by statement, is "unresolved": the Float64 overload
# refuses with an ArgumentError naming the bead, the Tuple overload does not
# delegate and compiles the natively selected code on the native-IR route.

using Test
using Bennett
using Random

_bitsi(x::Float64) = reinterpret(UInt64, x)

const _EDGE_IFFZ = Float64[0.0, -0.0, 1.0, -1.0, 1.5, -2.5, 0.1, Inf, -Inf,
                           NaN, -NaN, nextfloat(0.0), -nextfloat(0.0),
                           floatmin(Float64), prevfloat(floatmin(Float64)),
                           floatmax(Float64), -floatmax(Float64), 1e300, -1e-300]

function _sweep_iffz(n::Int; seed::Integer=0x1ff)
    rng = MersenneTwister(seed)
    vcat(_EDGE_IFFZ, [reinterpret(Float64, rand(rng, UInt64)) for _ in 1:n],
         randn(rng, n) .* 1e3)
end

_msg_iffz(f, Ts...) = try
    reversible_compile(f, Ts...); "no error"
catch e
    e isa ArgumentError ? sprint(showerror, e) : "non-ArgumentError: $(typeof(e)): " *
                                                 sprint(showerror, e)
end

# 1-arg circuit vs native over the sweep. Float64 results compare as IEEE bits.
function _check_vs_native_iffz(c, f; n=40)
    @test verify_reversibility(c)
    bad = Tuple{Float64, Any, Any}[]
    for x in _sweep_iffz(n)
        got = simulate(c, _bitsi(x)); exp = f(x)
        ok = exp isa Float64 ? got % UInt64 == _bitsi(exp) :
             exp isa Bool ? (got != 0) == exp : got % typeof(exp) == exp
        ok || push!(bad, (x, got, exp))
    end
    isempty(bad) || @info "mismatches" first(bad, 3)
    @test isempty(bad)
end

# The reviewer's witnesses, verbatim.
@generated function generated_choice(x::T) where {T}
    T === Float64 ? :(Int8(1)) : :(Int8(2))
end

@generated function generated_identity(x::T) where {T}
    T === Float64 ? :(x) : :(identity(identity(x)))
end

# A generated helper reached from a generic root, and an equivalent-body
# generated helper (same result on both typings — still not traceable soundly).
iffz_root(x) = generated_choice(x) + Int8(0)
@generated iffz_gen_same(x) = :(signbit(x))
iffz_root_same(x) = iffz_gen_same(x)

# Non-generated user code whose inferred constants differ between the two
# typings (not a Bool): `Int8(2)` vs `Int8(1)` through a helper that is only
# Base-dispatched. And a splat into a Float64-specialised helper.
iffz_k(::Type{Float64}) = Int8(1); iffz_k(::Type) = Int8(2)
iffz_const(x) = iffz_k(typeof(x))
# (Results are not inference constants, so the splat itself must be refused.)
iffz_g(x::Float64) = signbit(x); iffz_g(x) = !signbit(x)
iffz_splat(x) = iffz_g((x,)...)

const D_IFFZ = Bennett._softfloat_dispatch_divergence

@testset "Bennett-iffz: @generated methods are not traced on SoftFloat" begin

    @testset "T3 witness: generated constant choice" begin
        d = D_IFFZ(generated_choice, 1)
        @test d isa String && startswith(d, Bennett._SFD_UNRESOLVED)
        m = _msg_iffz(generated_choice, Float64)
        @test occursin("Bennett-iffz", m) && occursin("@generated", m)
        @test occursin("Bennett-iffz", _msg_iffz(generated_choice, Float64, CompileOptions()))
        c = reversible_compile(generated_choice, Tuple{Float64})
        @test simulate(c, UInt64(0)) % Int8 == generated_choice(0.0) == Int8(1)
        _check_vs_native_iffz(c, generated_choice)
    end

    @testset "T6 witness: equivalent generated bodies of different length" begin
        @test startswith(D_IFFZ(generated_identity, 1), Bennett._SFD_UNRESOLVED)
        m = _msg_iffz(generated_identity, Float64)
        @test occursin("Bennett-iffz", m)
        @test !occursin("introspection internals", m)
        c = reversible_compile(generated_identity, Tuple{Float64})
        @test simulate(c, _bitsi(1.5)) % UInt64 == _bitsi(1.5)
        _check_vs_native_iffz(c, generated_identity)
    end

    @testset "generated helper under a generic root" begin
        # iffz_root's Int8(1)-vs-Int8(2) result is also an inference
        # constant in the (non-generated) root, which reports it first.
        @test D_IFFZ(iffz_root, 1) isa String
        @test occursin("Bennett-czox", _msg_iffz(iffz_root, Float64))
        @test startswith(D_IFFZ(iffz_root_same, 1), Bennett._SFD_UNRESOLVED)
        @test occursin("Bennett-iffz", _msg_iffz(iffz_root_same, Float64))
        for f in (iffz_root, iffz_root_same)
            _check_vs_native_iffz(reversible_compile(f, Tuple{Float64}), f)
        end
    end

    @testset "non-Bool constant difference and splat: no delegation" begin
        d = D_IFFZ(iffz_const, 1)
        @test d isa String
        @test occursin("Bennett-czox", _msg_iffz(iffz_const, Float64)) ||
              occursin("Bennett-iffz", _msg_iffz(iffz_const, Float64))
        _check_vs_native_iffz(reversible_compile(iffz_const, Tuple{Float64}), iffz_const)
        @test startswith(D_IFFZ(iffz_splat, 1), Bennett._SFD_UNRESOLVED)
        @test occursin("Bennett-iffz", _msg_iffz(iffz_splat, Float64))
        _check_vs_native_iffz(reversible_compile(iffz_splat, Tuple{Float64}), iffz_splat)
    end
end
