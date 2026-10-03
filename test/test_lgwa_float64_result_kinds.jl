# Bennett-lgwa: the Float64 overload of `reversible_compile` wraps `f` so it
# runs on `SoftFloat` values, and used to take `.bits` of whatever `f`
# returned. A function returning anything but a `SoftFloat` — a constant
# Float64 (`x -> 1.0`), a Bool (`x -> x == x`), an integer — compiled the
# wrapper to a throwing body and died with the opaque "VoidType reached
# _type_width". The same message came out for any `f` that throws on SoftFloat
# arguments (a Float64 operation with no SoftFloat method, `Int64(x)`) and for
# a `(x::Float64) -> ...` annotation (no method for SoftFloat at all).
#
# Fixed: the result is adapted by type (SoftFloat / Float64 -> IEEE bits;
# Bool and <=64-bit machine integers pass through) and any other result type,
# or an `f` with no SoftFloat method / that always throws, is rejected with an
# ArgumentError before extraction.

using Test
using Bennett
using Random

@inline _lgwa_bits(x::Float64) = reinterpret(UInt64, x)

const LGWA_EDGE = Float64[0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 1.5, -2.5,
                          Inf, -Inf, NaN, -NaN,
                          reinterpret(Float64, 0x7ff0000000000001),  # sNaN
                          5.0e-324, -5.0e-324, floatmin(Float64), -floatmin(Float64),
                          prevfloat(floatmin(Float64)), floatmax(Float64), -floatmax(Float64)]

const LGWA_INPUTS = let rng = Random.MersenneTwister(0x1a6a)
    vcat(LGWA_EDGE, [reinterpret(Float64, rand(rng, UInt64)) for _ in 1:40],
         [randn(rng) * 10 for _ in 1:20])
end

# Expected circuit output for a native result `r`, as the integer simulate
# value compares: Float64 results are their bit pattern, integers themselves.
_lgwa_expect(r::Float64) = _lgwa_bits(r)
_lgwa_expect(r::Union{Bool, Integer}) = r

function _lgwa_mismatches(c, f, args_list)
    bad = Any[]
    for args in args_list
        want = _lgwa_expect(f(args...))
        bits = map(_lgwa_bits, args)
        got = simulate(c, length(bits) == 1 ? bits[1] : bits)
        # simulate's signedness inference may hand back an unsigned result
        # as the signed type of the same width; compare the bit pattern.
        got_cmp = want isa Bool ? got : got % typeof(want)
        got_cmp == want || push!(bad, (args, got, want))
    end
    isempty(bad) || println("  first mismatches: ", first(bad, 3))
    return bad
end

function _lgwa_check1(f, label)
    @testset "$label" begin
        c = reversible_compile(f, Float64)
        @test isempty(_lgwa_mismatches(c, f, [(x,) for x in LGWA_INPUTS]))
        @test verify_reversibility(c; n_tests=8)
    end
end

function _lgwa_check2(f, label)
    @testset "$label" begin
        c = reversible_compile(f, Float64, Float64)
        pairs = vec([(a, b) for a in LGWA_EDGE, b in LGWA_EDGE])
        rng = Random.MersenneTwister(0x2b2b)
        append!(pairs, [(reinterpret(Float64, rand(rng, UInt64)),
                         reinterpret(Float64, rand(rng, UInt64))) for _ in 1:40])
        @test isempty(_lgwa_mismatches(c, f, pairs))
        @test verify_reversibility(c; n_tests=8)
    end
end

@testset "Bennett-lgwa: Float64 overload result kinds" begin

    @testset "constant Float64 results" begin
        _lgwa_check1(x -> 1.0, "x -> 1.0")
        _lgwa_check1(x -> -0.0, "x -> -0.0")
        _lgwa_check1(x -> NaN, "x -> NaN")
        _lgwa_check1(x -> 5.0e-324, "x -> 5.0e-324 (subnormal)")
        _lgwa_check2((a, b) -> -Inf, "(a, b) -> -Inf")
    end

    @testset "captured constant (closure binding, Bennett-o9sv)" begin
        k = 2.75
        _lgwa_check1(x -> k, "x -> k (captured)")
    end

    @testset "Bool results" begin
        _lgwa_check1(x -> x == x, "x -> x == x")
        _lgwa_check1(x -> x != x, "x -> x != x")
        _lgwa_check1(x -> x == 0.0, "x -> x == 0.0")
        _lgwa_check2((a, b) -> a < b, "(a, b) -> a < b")
        _lgwa_check2((a, b) -> a == b, "(a, b) -> a == b")
    end

    @testset "integer results" begin
        _lgwa_check1(x -> 42, "x -> 42")
        _lgwa_check1(x -> x == 0.0 ? 1 : 2, "x -> x == 0.0 ? 1 : 2 (Int64)")
        _lgwa_check1(x -> x < x * 2.0 ? Int8(-3) : Int8(7), "Int8 select")
        _lgwa_check2((a, b) -> a < b ? UInt32(0xdeadbeef) : UInt32(1), "UInt32 select")
    end

    @testset "Union{SoftFloat, Float64} result" begin
        _lgwa_check1(x -> x == 0.0 ? 1.0 : x * 2.0, "x == 0.0 ? 1.0 : x * 2.0")
    end

    @testset "SoftFloat results unchanged" begin
        _lgwa_check1(x -> x + 1.0, "x -> x + 1.0")
    end

    @testset "unsupported results are rejected loudly" begin
        function rejects(f, n, needle)
            err = try
                reversible_compile(f, ntuple(_ -> Float64, n)...)
                nothing
            catch e
                e
            end
            ok = err isa ArgumentError && occursin("Bennett-lgwa", err.msg) &&
                 occursin(needle, err.msg)
            ok || println("  got: ", err === nothing ? "no error" : sprint(showerror, err))
            return ok
        end
        # Always throws on SoftFloat (no Int64(::SoftFloat) conversion).
        @test rejects(x -> Int64(x), 1, "always throws")
        # Annotated argument: no SoftFloat method at all.
        @test rejects((x::Float64) -> x + 1.0, 1, "no method")
        @test rejects((a::Float64, b::Float64) -> a + b, 2, "no method")
        # Results with no circuit encoding, or mixing encodings.
        @test rejects(x -> (x, x), 1, "result type")
        @test rejects(x -> 1.0f0, 1, "result type")
        @test rejects(x -> Int128(1), 1, "result type")
        @test rejects(x -> x == 0.0 ? 1 : 2.0, 1, "result type")
        @test rejects(x -> x == 0.0 ? true : 1, 1, "result type")
    end
end
