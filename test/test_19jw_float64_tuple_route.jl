# Bennett-19jw: `reversible_compile(f, Tuple{Float64...})` and the varargs
# `reversible_compile(f, Float64...)` spelling must agree.
#
# Pre-fix, the varargs form ran `f` on `SoftFloat` values (bit-exact soft-float
# calls), while the `Tuple` form extracted f's NATIVE Float64 IR: `g(x) =
# x*x + 1.0` compiled as `Float64` (209,376 gates) but died as `Tuple{Float64}`
# with "fmul ... unsupported LLVM opcode". Post-fix:
#   * an all-Float64 Tuple with a generic `f` delegates to the Float64
#     overload — the SAME circuit;
#   * `::Float64`-annotated / mixed Float64-integer signatures stay on the
#     native-IR route, which lowers float comparisons and conversions through
#     the bit-exact soft_* callees, and now rejects native float arithmetic
#     with an ArgumentError naming the bead;
#   * a tuple-typed argument with Float64 elements is rejected up front (the
#     native route crashed on it with an undefined-SSA AssertionError).

using Test
using Bennett
using Random

const _B19 = Bennett
_bits(x::Float64) = reinterpret(UInt64, x)

const _EDGE_19JW = Float64[0.0, -0.0, 1.0, -1.0, 1.5, -2.5, 3.0, 0.1, -7.25,
                           Inf, -Inf, NaN, -NaN, nextfloat(0.0), -nextfloat(0.0),
                           floatmin(Float64), prevfloat(floatmin(Float64)),
                           floatmax(Float64), -floatmax(Float64), 1e300, -1e-300]

function _sweep_19jw(n_rand::Int; seed::Integer=0x19)
    rng = MersenneTwister(seed)
    vcat(_EDGE_19JW,
         [reinterpret(Float64, rand(rng, UInt64)) for _ in 1:n_rand],
         randn(rng, n_rand) .* 1e3)
end

# Circuit-level identity: same wiring, same gate list.
_same_circuit(a, b) = a.n_wires == b.n_wires && a.gates == b.gates &&
    a.input_wires == b.input_wires && a.output_wires == b.output_wires &&
    a.ancilla_wires == b.ancilla_wires && a.input_widths == b.input_widths &&
    a.output_elem_widths == b.output_elem_widths

g19_1(x) = x * x + 1.0
g19_2(a, b) = a * b + a
g19_3(a, b, c) = a * b - c
g19_lt(x) = x < 1.5
g19_4(a, b, c, d) = a + b + c + d
h19_ann(x::Float64) = x * x
h19_mix(x, n) = x * n
h19_le(x::Float64, y::Float64) = x <= y
h19_mcmp(x::Float64, n::Int8) = x < Float64(n) ? n : -n
t19_first(t) = t[1]

@testset "Bennett-19jw: Tuple{Float64...} agrees with the Float64 overload" begin

    @testset "all-Float64 Tuple, 1-3 args: same circuit, bit-exact" begin
        xs = _sweep_19jw(40)
        for (f, N) in ((g19_1, 1), (g19_2, 2), (g19_3, 3))
            Ts = ntuple(_ -> Float64, N)
            c_var = reversible_compile(f, Ts...)
            c_tup = reversible_compile(f, Tuple{Ts...})
            @test _same_circuit(c_tup, c_var)
            @test verify_reversibility(c_tup)
            rng = MersenneTwister(N)
            bad = Tuple[]
            for i in eachindex(xs)
                args = ntuple(k -> k == 1 ? xs[i] : xs[rand(rng, eachindex(xs))], N)
                got = simulate(c_tup, N == 1 ? _bits(args[1]) : map(_bits, args))
                exp = _bits(f(args...))
                got % UInt64 == exp || push!(bad, (args, got, exp))
            end
            isempty(bad) || @info "g19_$N mismatches" first(bad, 3)
            @test isempty(bad)
        end
    end

    @testset "Float64 literal + Bool result (was ConstantFP reject)" begin
        c_var = reversible_compile(g19_lt, Float64)
        c_tup = reversible_compile(g19_lt, Tuple{Float64})
        @test _same_circuit(c_tup, c_var)
        @test verify_reversibility(c_tup)
        bad = [x for x in _sweep_19jw(100) if (simulate(c_tup, _bits(x)) != 0) != (x < 1.5)]
        @test isempty(bad)
    end

    @testset "capturing closure keeps working on the Tuple spelling" begin
        cap = let k = 2.5; x -> x * k; end
        c_var = reversible_compile(cap, Float64)
        c_tup = reversible_compile(cap, Tuple{Float64})
        @test _same_circuit(c_tup, c_var)
        @test verify_reversibility(c_tup)
        bad = [x for x in _sweep_19jw(30) if simulate(c_tup, _bits(x)) % UInt64 != _bits(x * 2.5)]
        @test isempty(bad)
    end

    @testset "CompileOptions + kwarg forwarding" begin
        c_var = reversible_compile(g19_1, Float64)
        @test _same_circuit(reversible_compile(g19_1, Tuple{Float64}, CompileOptions()), c_var)
        @test _same_circuit(reversible_compile(g19_1, Tuple{Float64}; add=:ripple),
                            reversible_compile(g19_1, Float64; add=:ripple))
        # Bennett-iwj6: a Float64 argument still cannot be narrowed.
        @test_throws ArgumentError reversible_compile(g19_1, Tuple{Float64}; bit_width=8)
        # The Float64 overload's own limits apply to both spellings.
        @test_throws ArgumentError reversible_compile(g19_4, Float64, Float64, Float64, Float64)
        @test_throws ArgumentError reversible_compile(g19_4, Tuple{Float64, Float64, Float64, Float64})
        @test_throws ArgumentError reversible_compile(g19_1, Tuple{Float64}; strategy=:tabulate)
    end

    _msg(f, T) = try
        reversible_compile(f, T); "no error"
    catch e
        e isa ArgumentError ? sprint(showerror, e) : "non-ArgumentError: $(typeof(e))"
    end

    @testset "native float arithmetic rejected loudly, naming the bead" begin
        # `::Float64`-annotated: no SoftFloat method, so the Tuple form takes the
        # native-IR route; the Float64 form rejects the annotation (Bennett-lgwa).
        @test occursin("Bennett-19jw", _msg(h19_ann, Tuple{Float64}))
        @test_throws ArgumentError reversible_compile(h19_ann, Float64)
        # Mixed Float64/integer: no SoftFloat route exists.
        @test occursin("Bennett-19jw", _msg(h19_mix, Tuple{Float64, Int8}))
        @test occursin("Bennett-19jw", _msg(h19_mix, Tuple{Float64, Int64}))
    end

    @testset "tuple-typed Float64 argument rejected up front" begin
        @test occursin("Bennett-19jw", _msg(t19_first, Tuple{NTuple{2, Float64}}))
        @test occursin("Bennett-19jw", _msg((n, t) -> t[1], Tuple{Int8, NTuple{2, Float64}}))
        # Integer NTuple arguments are unaffected.
        @test reversible_compile(t19_first, Tuple{NTuple{2, Int8}}) isa ReversibleCircuit
    end

    @testset "native-IR route stays bit-exact where it lowers" begin
        # Annotated all-Float64 comparison → soft_fcmp_ole callee.
        c = reversible_compile(h19_le, Tuple{Float64, Float64})
        @test verify_reversibility(c)
        xs = _sweep_19jw(20)
        bad = [(a, b) for a in xs, b in xs
               if (simulate(c, (_bits(a), _bits(b))) != 0) != (a <= b)]
        @test isempty(bad)
        # Mixed signature: sitofp + fcmp olt → soft_sitofp / soft_fcmp_olt.
        c = reversible_compile(h19_mcmp, Tuple{Float64, Int8})
        @test verify_reversibility(c)
        ns = Int8[-128, -127, -1, 0, 1, 2, 3, 126, 127]
        bad = [(x, n) for x in _sweep_19jw(20), n in ns
               if simulate(c, (_bits(x), n)) % Int8 != h19_mcmp(x, n)]
        @test isempty(bad)
    end
end
