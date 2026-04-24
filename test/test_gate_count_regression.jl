using Test
using Bennett

@testset "Gate count regression baselines" begin
    # CLAUDE.md Principle 6: gate counts are regression baselines.
    # These values reflect the current pipeline with path-predicate phi resolution.
    # Toffoli counts match the original baselines (28, 60, 124, 252).
    # Total is higher due to block-predicate overhead (NOT + CNOT gates).
    #
    # Bennett-11xt / U23: each compiled circuit below now carries a
    # `verify_reversibility` call — gate counts alone are not
    # correctness proof; a Bennett-invariant-violating circuit could
    # hit the same count.

    @testset "Addition gate counts (x + 1)" begin
        c8  = reversible_compile(x -> x + Int8(1), Int8)
        c16 = reversible_compile(x -> x + Int16(1), Int16)
        c32 = reversible_compile(x -> x + Int32(1), Int32)
        c64 = reversible_compile(x -> x + Int64(1), Int64)
        @test verify_reversibility(c8)
        @test verify_reversibility(c16)
        @test verify_reversibility(c32)
        @test verify_reversibility(c64)
        @test simulate(c8,  Int8(0))  == Int8(1)
        @test simulate(c16, Int16(0)) == Int16(1)
        @test simulate(c32, Int32(0)) == Int32(1)
        @test simulate(c64, Int64(0)) == Int64(1)

        gc8, gc16, gc32, gc64 = gate_count(c8), gate_count(c16), gate_count(c32), gate_count(c64)

        @test gc8.total  == 100
        @test gc16.total == 204
        @test gc32.total == 412
        @test gc64.total == 828

        # Toffoli counts (original baselines, unaffected by predicate overhead)
        @test gc8.Toffoli  == 28
        @test gc16.Toffoli == 60
        @test gc32.Toffoli == 124
        @test gc64.Toffoli == 252

        # 2x+4 scaling invariant (4 extra from path-predicate per doubling)
        @test gc16.total == 2 * gc8.total + 4
        @test gc32.total == 2 * gc16.total + 4
        @test gc64.total == 2 * gc32.total + 4

        # Toffoli-depth baselines (M2, bd Bennett-z29g).
        # Ripple-carry adder: Toffoli-depth == Toffoli count because the carry
        # chain serializes every Toffoli. This is the reason QCLA (O(log n)
        # Toffoli-depth) is the natural next primitive.
        @test toffoli_depth(c8)  == 28
        @test toffoli_depth(c16) == 60
        @test toffoli_depth(c32) == 124
        @test toffoli_depth(c64) == 252
    end

    @testset "Polynomial gate count (x*x + 3x + 1)" begin
        # U28 / Bennett-epwy: fold_constants default flipped to true.
        # Pre-fix: total=872, toffoli_depth=90 (352 Toffoli).
        # Post-fix: total=562, toffoli_depth=64 (200 Toffoli). The
        # constants 3 and 1 propagate through the multiply-and-add chain
        # and collapse partially-constant Toffolis to CNOTs.
        c = reversible_compile(x -> x * x + Int8(3) * x + Int8(1), Int8)
        @test gate_count(c).total == 562
        @test toffoli_depth(c) == 64
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(1)
    end

    @testset "x + 3 gate count" begin
        c = reversible_compile(x -> x + Int8(3), Int8)
        @test gate_count(c).total == 102
        @test toffoli_depth(c) == 28
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(3)
    end

    @testset "Multiplication Toffoli-depth (shift-and-add)" begin
        # Baselines BEFORE the Sun-Borissov qcla_tree multiplier lands.
        # Expected: gets replaced by O(log^2 n) once mul=:qcla_tree is wired.
        # U28 / Bennett-epwy: fold_constants default flipped to true.
        # Pre-fix: Toffoli 296 / 1232, depth 68 / 214.
        # Post-fix: Toffoli 144 / 664, depth 62 / 208. The shift-and-add
        # chain on `x*x` folds the zero-initialised accumulator words.
        c8  = reversible_compile(x -> x * x, Int8)
        c16 = reversible_compile(x -> x * x, Int16)
        @test gate_count(c8).Toffoli  == 144
        @test gate_count(c16).Toffoli == 664
        @test toffoli_depth(c8)  == 62
        @test toffoli_depth(c16) == 208
        @test verify_reversibility(c8)
        @test verify_reversibility(c16)
        @test simulate(c8,  Int8(3))  == Int8(9)
        @test simulate(c16, Int16(7)) == Int16(49)
    end
end
