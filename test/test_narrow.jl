using Test
using Bennett

@testset "Narrow bit-width compilation" begin
    @testset "Int4 (4-bit) addition" begin
        c = reversible_compile(x -> x + Int8(1), Int8; bit_width=4)

        # Exhaustive: all 16 inputs
        for x in 0:15
            expected = mod(x + 1, 16)
            @test simulate(c, Int8(x)) == expected
        end
        @test verify_reversibility(c)

        gc = gate_count(c)
        println("  Int4 x+1: $(gc.total) gates, $(c.n_wires) wires")
        @test gc.total < 60  # should be ~48, well under Int8's 100
    end

    @testset "Int2 (2-bit) exhaustive" begin
        c = reversible_compile(x -> x + Int8(1), Int8; bit_width=2)

        @test simulate(c, Int8(0)) == 1
        @test simulate(c, Int8(1)) == 2
        @test simulate(c, Int8(2)) == 3
        @test simulate(c, Int8(3)) == 0  # wraps mod 4
        @test verify_reversibility(c)

        gc = gate_count(c)
        println("  Int2 x+1: $(gc.total) gates, $(c.n_wires) wires")
        @test gc.total < 30  # should be ~22
    end

    @testset "Int4 polynomial" begin
        c = reversible_compile(x -> x * x + Int8(3) * x + Int8(1), Int8; bit_width=4)

        f(x) = mod(x * x + 3 * x + 1, 16)
        for x in 0:15
            @test simulate(c, Int8(x)) == f(x)
        end
        @test verify_reversibility(c)

        gc = gate_count(c)
        println("  Int4 poly: $(gc.total) gates, $(c.n_wires) wires")
        @test gc.total < gate_count(reversible_compile(x -> x * x + Int8(3) * x + Int8(1), Int8)).total
    end

    @testset "Int4 two-arg addition" begin
        c = reversible_compile((x, y) -> x + y, Int8, Int8; bit_width=4)

        for x in 0:3, y in 0:3
            @test simulate(c, (Int8(x), Int8(y))) == mod(x + y, 16)
        end
        @test verify_reversibility(c)
        println("  Int4 x+y: $(gate_count(c).total) gates")
    end

    @testset "Gate count scaling with bit_width" begin
        for W in [2, 3, 4, 6, 8]
            c = reversible_compile(x -> x + Int8(1), Int8; bit_width=W)
            gc = gate_count(c)
            println("  Int$W x+1: $(gc.total) gates")
        end
    end

    @testset "narrow with integer comparison (IRCast)" begin
        # x == 5 forces a cast of the literal in the LLVM IR (Int64 5 → i8).
        # Regression test for _narrow_inst(::IRCast) — previously referenced a
        # nonexistent src_width field and passed args in the wrong positional
        # order, breaking any bit_width>0 compile of a function with a cast.
        #
        # Bennett-koi8: this ran at bit_width=3, reading 5 as the 3-bit
        # PATTERN 101 (true at x = -3).  An eq/ne constant at W < 8 must now
        # lie in 0..2^(W-1)-1, the values every reading agrees on, because the
        # IR cannot tell `x == C` from an ordering the optimizer folded into
        # one; 5 is fine at W = 4, and the W = 3 compile is a refusal.
        f(x::Int8) = Int8(x == 5 ? 1 : 0)
        c = reversible_compile(f, Int8; bit_width=4)
        for x in 0:15
            @test simulate(c, Int8(x)) == (x == 5 ? Int8(1) : Int8(0))
        end
        @test verify_reversibility(c)
        @test_throws ArgumentError reversible_compile(f, Int8; bit_width=3)
    end

    @testset "narrow with compound boolean predicate (i1 IRBinOp)" begin
        # && on two i1 comparison results lowers to `and i1 %a, %b` in LLVM IR.
        # Regression test for _narrow_inst(::IRBinOp) — previously narrowed the
        # width unconditionally, so the i1 operands of the and became i3 while
        # resolve! still returned only 1 wire, crashing lower_and! in the loop
        # over 1:W. Predicate is chosen width-agnostic (== is not signed/unsigned).
        # Bennett-koi8: bit_width=4 (was 3), so that 5 is in 0..2^(W-1)-1.
        f(x::Int8) = Int8((x != Int8(0) && x != Int8(5)) ? 1 : 0)
        c = reversible_compile(f, Int8; bit_width=4)
        for x in 0:15
            expected = (x != 0 && x != 5) ? Int8(1) : Int8(0)
            @test simulate(c, Int8(x)) == expected
        end
        @test verify_reversibility(c)
    end
end
