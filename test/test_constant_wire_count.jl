using Test
using Bennett

# Bennett-11xt / U23: each compiled circuit below now carries a
# `verify_reversibility` call (+ sanity `simulate` on zero). Pre-U23
# these tests checked only `constant_wire_count(c)` and never
# confirmed the circuit satisfies Bennett's invariants.
@testset "constant_wire_count" begin
    @testset "x + 3 has at least 1 constant wire" begin
        c = reversible_compile(x -> x + Int8(3), Int8)
        cw = constant_wire_count(c)
        # At minimum the entry block predicate wire is constant
        @test cw >= 1
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(3)
    end

    @testset "identity-like function has constant predicate wire" begin
        c = reversible_compile(x -> x + Int8(0), Int8)
        cw = constant_wire_count(c)
        # Entry block predicate wire is always targeted and constant
        @test cw >= 1
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(0)
    end

    @testset "polynomial has constants" begin
        c = reversible_compile(x -> x * x + Int8(3) * x + Int8(1), Int8)
        cw = constant_wire_count(c)
        @test cw >= 1
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(1)
    end

    @testset "constant_wire_count returns non-negative Int" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        cw = constant_wire_count(c)
        @test cw isa Int
        @test cw >= 0
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(1)
    end
end
