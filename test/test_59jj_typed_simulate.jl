# Bennett-59jj / U47 cut: typed `simulate(c, ::Type{T}, inputs)` overload.
#
# Pre-fix `simulate(c, input)` returns a 9-arm
# `Union{Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32,UInt64,Tuple}` (verified
# live via `@code_warntype`). Hot loops over many inputs pay union-dispatch
# overhead. A typed overload `simulate(c, T, input)::T` lets callers opt in
# to a concrete return type.
#
# Per CLAUDE.md §4 every test pairs an output-vs-Julia-oracle assertion with
# a structural check (here: `Test.@inferred` to assert type stability).

using Test
using Bennett
using Bennett: reversible_compile, simulate

@testset "Bennett-59jj / U47: typed simulate overload" begin

    @testset "T1: single-input Int8 circuit, T=Int8 — concrete return" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        # Type stability: @inferred passes iff the inferred return type is
        # concrete (no Union, no abstract).
        for x in Int8(-3):Int8(3)
            r = @inferred Int8 simulate(c, Int8, x)
            @test r == x + Int8(1)
        end
    end

    @testset "T2: single-input Int8 circuit, T=Int16 (wider) — concrete return" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        for x in Int8(-3):Int8(3)
            r = @inferred Int16 simulate(c, Int16, x)
            @test r == Int16(x + Int8(1))
        end
    end

    @testset "T3: multi-input tuple, T=Int8 — concrete return" begin
        c = reversible_compile((x::Int8, y::Int8) -> x + y, Int8, Int8)
        for x in Int8(-2):Int8(2), y in Int8(-2):Int8(2)
            r = @inferred Int8 simulate(c, Int8, (x, y))
            @test r == x + y
        end
    end

    @testset "T4: untyped simulate still returns Union (untouched)" begin
        # Regression: the existing untyped overload must keep behaving
        # exactly as before.
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test simulate(c, Int8(5)) == Int8(6)
        @test simulate(c, Int8(127)) == Int8(-128)   # 8-bit overflow
    end

    @testset "T5: arity guard (single-input variant on multi-input circuit)" begin
        c = reversible_compile((x::Int8, y::Int8) -> x + y, Int8, Int8)
        # Calling the single-input typed variant on a multi-input circuit
        # must error loudly per CLAUDE.md §1.
        @test_throws ArgumentError simulate(c, Int8, Int8(5))
    end

    @testset "T6: rejects multi-element output for Integer T" begin
        # A circuit whose output is a tuple cannot be flattened into a
        # single Integer T — must error per CLAUDE.md §1.
        c = reversible_compile((x::Int8, y::Int8) -> (x, y), Int8, Int8)
        @test_throws ArgumentError simulate(c, Int8, (Int8(1), Int8(2)))
    end

    @testset "T7: rejects T too narrow to hold the output" begin
        # Output is 16 bits; T=Int8 (8 bits) cannot hold it.
        c = reversible_compile(x -> x + Int16(1), Int16)
        @test_throws ArgumentError simulate(c, Int8, Int16(5))
    end

end
