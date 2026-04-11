using Test
using Bennett

@testset "Gate count regression baselines" begin
    # CLAUDE.md Principle 6: gate counts are regression baselines.
    # These values reflect the current pipeline with path-predicate phi resolution.
    # Toffoli counts match the original baselines (28, 60, 124, 252).
    # Total is higher due to block-predicate overhead (NOT + CNOT gates).

    @testset "Addition gate counts (x + 1)" begin
        gc8  = gate_count(reversible_compile(x -> x + Int8(1), Int8))
        gc16 = gate_count(reversible_compile(x -> x + Int16(1), Int16))
        gc32 = gate_count(reversible_compile(x -> x + Int32(1), Int32))
        gc64 = gate_count(reversible_compile(x -> x + Int64(1), Int64))

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
    end

    @testset "Polynomial gate count (x*x + 3x + 1)" begin
        gc = gate_count(reversible_compile(x -> x * x + Int8(3) * x + Int8(1), Int8))
        @test gc.total == 872
    end

    @testset "x + 3 gate count" begin
        gc = gate_count(reversible_compile(x -> x + Int8(3), Int8))
        @test gc.total == 102
    end
end
