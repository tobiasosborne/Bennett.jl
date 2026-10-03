# Bennett-czox: the SoftFloat trace must not compile a different method than
# the requested Float64 signature selects.
#
# `reversible_compile(f, Float64)` compiles `f(::SoftFloat)`, and since
# Bennett-19jw `Tuple{Float64}` delegates there too. With
# `f(x::Float64) = Int8(1); f(x) = Int8(2)` both spellings compiled the generic
# method: the circuit returned 2 where `f(0.0) == 1` (verify_reversibility
# true). The same happened one level down, through a helper with a
# Float64-specific method, through `::AbstractFloat` / `::Real` methods (which
# SoftFloat does not subtype) and through `x isa Float64` tests. Post-fix:
#   * the Float64 overload rejects such an `f` with an ArgumentError naming
#     the bead;
#   * the Tuple spelling does not delegate it and takes the native-IR route,
#     which compiles the natively selected code (or rejects native float
#     arithmetic loudly, Bennett-19jw);
#   * ordinary generic float code still delegates, with the identical circuit.

using Test
using Bennett
using Random

const _BCZ = Bennett
_bitsz(x::Float64) = reinterpret(UInt64, x)

const _EDGE_CZOX = Float64[0.0, -0.0, 1.0, -1.0, 1.5, -2.5, 0.1, Inf, -Inf,
                           NaN, -NaN, nextfloat(0.0), -nextfloat(0.0),
                           floatmin(Float64), prevfloat(floatmin(Float64)),
                           floatmax(Float64), -floatmax(Float64), 1e300, -1e-300]

function _sweep_czox(n::Int; seed::Integer=0xc0)
    rng = MersenneTwister(seed)
    vcat(_EDGE_CZOX, [reinterpret(Float64, rand(rng, UInt64)) for _ in 1:n],
         randn(rng, n) .* 1e3)
end

_same_circuit_czox(a, b) = a.n_wires == b.n_wires && a.gates == b.gates &&
    a.input_wires == b.input_wires && a.output_wires == b.output_wires &&
    a.ancilla_wires == b.ancilla_wires && a.input_widths == b.input_widths &&
    a.output_elem_widths == b.output_elem_widths

_msg_czox(f, Ts...) = try
    reversible_compile(f, Ts...); "no error"
catch e
    e isa ArgumentError ? sprint(showerror, e) : "non-ArgumentError: $(typeof(e))"
end

# 1-arg circuit vs native over the sweep (integer / Bool result).
function _check_vs_native(c, f; n=40)
    @test verify_reversibility(c)
    bad = Tuple{Float64, Any, Any}[]
    for x in _sweep_czox(n)
        got = simulate(c, _bitsz(x)); exp = f(x)
        (exp isa Bool ? (got != 0) == exp : got % typeof(exp) == exp) ||
            push!(bad, (x, got, exp))
    end
    isempty(bad) || @info "mismatches" first(bad, 3)
    @test isempty(bad)
end

# The reviewer's witness, verbatim.
review_dispatch(x::Float64) = Int8(1)
review_dispatch(x) = Int8(2)

# Argument-type variants: SoftFloat is not <: AbstractFloat / Real.
cz_af(x::AbstractFloat) = Int8(1);  cz_af(x) = Int8(2)
cz_re(x::Real) = Int8(1);           cz_re(x) = Int8(2)
cz_two(x::Float64, y) = x < y;      cz_two(x, y) = x > y     # only arg 1 specialised
cz_two2(x, y::Float64) = x <= y;    cz_two2(x, y) = x >= y   # only arg 2 specialised
cz_arith(x::Real) = x * 2.0;        cz_arith(x) = x + 1.0    # float arithmetic

# Helper-level: f is generic, its helper is not.
cz_g(x::Float64) = Int8(1);  cz_g(x) = Int8(2)
cz_h(x) = cz_g(x) + Int8(0)
cz_ga(x::AbstractFloat) = x * x;  cz_ga(x) = x + x
cz_ha(x) = cz_ga(x) - 1.0
cz_isa(x) = x isa Float64 ? Int8(1) : Int8(2)
cz_isa_noelse(x) = (y = Int8(1); if !(x isa AbstractFloat); y = Int8(2); end; y)
cz_map(x) = map(cz_g, (x,))[1]
cz_h2(x, y) = cz_two(x, y)

# Ordinary generic float code: must delegate, identical circuits.
cz_sq(x) = x * x
cz_poly(x) = cz_sq(x) + 1.0          # user helper, generic
cz_lt(x, y) = x < y
cz_sign(x) = zero(x) < one(x) ? x : -x
cz_neg(x) = -x

@testset "Bennett-czox: SoftFloat trace keeps native dispatch" begin

    @testset "reviewer witness: Tuple route compiles the Float64 method" begin
        c = reversible_compile(review_dispatch, Tuple{Float64};
                               strategy=:expression)
        @test Int(simulate(c, reinterpret(UInt64, 0.0))) == review_dispatch(0.0) == 1
        _check_vs_native(c, review_dispatch)
        # Float64 overload: rejected, naming the bead.
        m = _msg_czox(review_dispatch, Float64)
        @test occursin("Bennett-czox", m)
        @test occursin("review_dispatch(x::Float64)", m)
        @test occursin("Bennett-czox", _msg_czox(review_dispatch, Float64, CompileOptions()))
    end

    @testset "argument-type variants" begin
        for f in (cz_af, cz_re)
            @test occursin("Bennett-czox", _msg_czox(f, Float64))
            _check_vs_native(reversible_compile(f, Tuple{Float64}), f)
        end
        # 2-arg, one argument specialised: native compare route, bit-exact.
        xs = _sweep_czox(12)
        for f in (cz_two, cz_two2)
            @test occursin("Bennett-czox", _msg_czox(f, Float64, Float64))
            c = reversible_compile(f, Tuple{Float64, Float64})
            @test verify_reversibility(c)
            bad = [(a, b) for a in xs, b in xs
                   if (simulate(c, (_bitsz(a), _bitsz(b))) != 0) != f(a, b)]
            @test isempty(bad)
        end
        # Specialised method does float arithmetic: no route compiles it
        # faithfully, so both spellings reject loudly.
        @test occursin("Bennett-czox", _msg_czox(cz_arith, Float64))
        @test occursin("Bennett-19jw", _msg_czox(cz_arith, Tuple{Float64}))
    end

    @testset "helper-level and type-test divergence" begin
        for f in (cz_h, cz_isa, cz_isa_noelse, cz_map)
            @test occursin("Bennett-czox", _msg_czox(f, Float64))
            _check_vs_native(reversible_compile(f, Tuple{Float64}), f)
        end
        @test occursin("Bennett-czox", _msg_czox(cz_h2, Float64, Float64))
        @test occursin("Bennett-czox", _msg_czox(cz_ha, Float64))
        @test occursin("Bennett-19jw", _msg_czox(cz_ha, Tuple{Float64}))
    end

    @testset "divergence detector: no false positives on generic code" begin
        D = _BCZ._softfloat_dispatch_divergence
        for (f, N) in ((cz_sq, 1), (cz_poly, 1), (cz_lt, 2), (cz_sign, 1),
                       (cz_neg, 1), (x -> x^2 + abs(x) - sqrt(abs(x)), 1),
                       (x -> muladd(x, 2.0, 1.0), 1), ((a, b) -> max(a, b) + min(a, b), 2),
                       (x -> exp(x), 1), (x -> clamp(x, -1.0, 1.0), 1),
                       (x -> floor(x) + round(x), 1), (x -> Base.Fix2(-, 1.0)(x), 1),
                       ((a, b, c) -> fma(a, b, c), 3), (identity, 1), (-, 1),
                       (+, 2), (abs, 1))
            @test D(f, N) === nothing
        end
        @test D(review_dispatch, 1) isa String
        @test D(cz_h, 1) isa String
    end

    @testset "generic code still delegates: identical circuit, bit-exact" begin
        xs = _sweep_czox(25)
        for f in (cz_poly, cz_sign, cz_neg)
            c_var = reversible_compile(f, Float64)
            c_tup = reversible_compile(f, Tuple{Float64})
            @test _same_circuit_czox(c_tup, c_var)
            @test verify_reversibility(c_tup)
            bad = [x for x in xs if simulate(c_tup, _bitsz(x)) % UInt64 != _bitsz(f(x))]
            @test isempty(bad)
        end
        c_var = reversible_compile(cz_lt, Float64, Float64)
        c_tup = reversible_compile(cz_lt, Tuple{Float64, Float64})
        @test _same_circuit_czox(c_tup, c_var)
        @test verify_reversibility(c_tup)
        ys = _sweep_czox(8)
        bad = [(a, b) for a in ys, b in ys
               if (simulate(c_tup, (_bitsz(a), _bitsz(b))) != 0) != (a < b)]
        @test isempty(bad)
    end
end
