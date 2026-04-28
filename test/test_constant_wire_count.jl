using Test
using Bennett

# Bennett-11xt / U23: each compiled circuit below now carries a
# `verify_reversibility` call (+ sanity `simulate` on zero). Pre-U23
# these tests checked only `constant_wire_count(c)` and never
# confirmed the circuit satisfies Bennett's invariants.
@testset "constant_wire_count" begin
    # Bennett-kv7b / U65 (#03 F13): pin EXACT values rather than `>= 0/1`
    # smoke checks. A regression that drops a constant wire or doubles
    # the count silently was previously invisible — the test would still
    # pass at >=1. Pinned baselines below; update intentionally when the
    # constant-wire derivation in lower.jl changes.

    @testset "x + 3 (Int8): 3 constant wires" begin
        c = reversible_compile(x -> x + Int8(3), Int8)
        @test constant_wire_count(c) == 3   # was `>= 1`
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(3)
    end

    @testset "x + 0 (Int8): 1 constant wire (entry-block predicate only)" begin
        c = reversible_compile(x -> x + Int8(0), Int8)
        @test constant_wire_count(c) == 1   # was `>= 1`
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(0)
    end

    @testset "x*x + 3x + 1 (Int8): 4 constant wires" begin
        c = reversible_compile(x -> x * x + Int8(3) * x + Int8(1), Int8)
        @test constant_wire_count(c) == 4   # was `>= 1`
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(1)
    end

    @testset "x + 1 (Int8): 2 constant wires" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test constant_wire_count(c) isa Int
        @test constant_wire_count(c) == 2   # was `>= 0`
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(1)
    end
end
