# Bennett-g6u9: mixed SoftFloat/Float64 and SoftFloat/Integer equality.
#
# Before the fix only `==(::SoftFloat, ::SoftFloat)` existed, so
# `SoftFloat(0.0) == 0.0` fell to Base's generic `==(x, y) = x === y` and
# returned `false` at trace time. `reversible_compile(x -> x == 0.0 ? x + 1.0 : x,
# Float64)` then folded the branch away and produced a 66-gate identity circuit
# that passed `verify_reversibility` while returning the wrong value.
#
# The mixed methods must match Julia's Float64 semantics exactly, including
# the exact Float64/Integer comparison (no rounding of integers beyond 2^53).

using Test
using Bennett
using Random

const G6U9_SF = Bennett.SoftFloat

@inline _g6u9_bits(x::Float64) = reinterpret(UInt64, x)

const G6U9_FLOATS = Float64[0.0, -0.0, 1.0, -1.0, 2.0, 0.5, NaN, -NaN, Inf, -Inf,
                           5.0e-324, -5.0e-324, floatmax(Float64), floatmin(Float64),
                           9.007199254740992e15, 9.007199254740994e15,
                           9.223372036854776e18, -9.223372036854776e18]

const G6U9_INTS = Any[0, 1, -1, 2, 2^53, 2^53 + 1, 2^53 + 2, typemax(Int64),
                      typemin(Int64), typemax(UInt64), true, false, Int8(-1),
                      UInt8(255), Int128(2)^70, Int128(2)^70 + 1]

@testset "Bennett-g6u9: mixed SoftFloat equality" begin

    @testset "host: SoftFloat vs Float64, both orders" begin
        for x in G6U9_FLOATS, y in G6U9_FLOATS
            @test (G6U9_SF(x) == y) === (x == y)
            @test (y == G6U9_SF(x)) === (y == x)
            @test (G6U9_SF(x) != y) === (x != y)
            @test (y != G6U9_SF(x)) === (y != x)
        end
    end

    @testset "host: SoftFloat vs Integer is exact, both orders" begin
        for x in G6U9_FLOATS, n in G6U9_INTS
            @test (G6U9_SF(x) == n) === (x == n)
            @test (n == G6U9_SF(x)) === (n == x)
            @test (G6U9_SF(x) != n) === (x != n)
        end
        # 2^53 + 1 rounds to 2^53 as a Float64 but is not equal to it.
        @test (G6U9_SF(9.007199254740992e15) == 2^53 + 1) === false
        @test (G6U9_SF(9.007199254740992e15) == 2^53) === true
        # typemax(Int64) rounds to 2^63 but is not equal to it.
        @test (G6U9_SF(9.223372036854776e18) == typemax(Int64)) === false
    end

    @testset "host: other Real types are rejected loudly" begin
        for y in (1.0f0, Float16(1), 1 // 1, big(1.0), π)
            @test_throws ArgumentError G6U9_SF(1.0) == y
            @test_throws ArgumentError y == G6U9_SF(1.0)
        end
    end

    rng = Random.MersenneTwister(0x6609)
    inputs = vcat(G6U9_FLOATS, [reinterpret(Float64, rand(rng, UInt64)) for _ in 1:24],
                  [randn(rng) for _ in 1:8])

    function check_circuit(f, label)
        c = reversible_compile(f, Float64)
        @testset "$label" begin
            for x in inputs
                @test simulate(c, _g6u9_bits(x)) % UInt64 == _g6u9_bits(f(x))
            end
            @test verify_reversibility(c; n_tests=8)
        end
        return c
    end

    @testset "compiled branches match native Float64" begin
        # The bead witness.
        c = check_circuit(x -> x == 0.0 ? x + 1.0 : x, "x == 0.0 ? x + 1.0 : x")
        @test simulate(c, UInt64(0)) % UInt64 == _g6u9_bits(1.0)
        check_circuit(x -> ifelse(x == 0.0, -x, x), "ifelse(x == 0.0, -x, x)")
        check_circuit(x -> ifelse(0.0 == x, -x, x), "ifelse(0.0 == x, -x, x)")
        check_circuit(x -> ifelse(x == 0, -x, x), "ifelse(x == 0, -x, x)")
        check_circuit(x -> ifelse(x != 1, -x, x), "ifelse(x != 1, -x, x)")
        check_circuit(x -> ifelse(x == 2^53, -x, x), "ifelse(x == 2^53, -x, x)")
        check_circuit(x -> ifelse(x == 2^53 + 1, -x, x), "ifelse(x == 2^53 + 1, -x, x)")
    end
end
