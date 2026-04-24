using Test
using Bennett

@testset "Gate count regression baselines" begin
    # CLAUDE.md Principle 6: gate counts are regression baselines.
    # Current pipeline: path-predicate phi resolution, fold_constants
    # on by default (U28 / Bennett-epwy), `add=:auto` → `:ripple` (U27 /
    # Bennett-spa8).
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

        # Post-U27/U28 baselines. Pre-U27 (Cuccaro default): 100/204/412/828
        # with 28/60/124/252 Toffoli. Ripple + fold collapses the
        # known-zero carry-in path AND the constant-1 operand: most of
        # the carry Toffolis fold to CNOTs where one control is known
        # false, landing at these ~2× smaller totals.
        @test gc8.total  == 58
        @test gc16.total == 114
        @test gc32.total == 226
        @test gc64.total == 450

        @test gc8.Toffoli  == 12
        @test gc16.Toffoli == 28
        @test gc32.Toffoli == 60
        @test gc64.Toffoli == 124

        # Scaling invariant (post-ripple+fold): each doubling adds
        # essentially one extra carry + the prior width's work minus
        # the constant-1 head-bit fold-out.  Empirically `2*W - 2`.
        @test gc16.total == 2 * gc8.total - 2
        @test gc32.total == 2 * gc16.total - 2
        @test gc64.total == 2 * gc32.total - 2

        # Toffoli-depth baselines.
        # Ripple-carry adder: Toffoli-depth == Toffoli count because the carry
        # chain serializes every Toffoli. This is the reason QCLA (O(log n)
        # Toffoli-depth) is the natural next primitive.
        @test toffoli_depth(c8)  == 12
        @test toffoli_depth(c16) == 28
        @test toffoli_depth(c32) == 60
        @test toffoli_depth(c64) == 124
    end

    @testset "Polynomial gate count (x*x + 3x + 1)" begin
        # Pre-U28/U27: total=872, toffoli_depth=90 (352 Toffoli).
        # Post-U28 (fold default): total=562, depth=64.
        # Post-U27 (:auto add → ripple): total=482, depth=36. The
        # ripple-add carry chain shortens post-fold significantly —
        # the constant `1` operand's high bits fold out cleanly.
        c = reversible_compile(x -> x * x + Int8(3) * x + Int8(1), Int8)
        @test gate_count(c).total == 482
        @test toffoli_depth(c) == 36
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(1)
    end

    @testset "x + 3 gate count" begin
        # Pre-U27 (Cuccaro default): total=102, toffoli_depth=28.
        # Post-U27 (ripple): total=64, toffoli_depth=12.
        c = reversible_compile(x -> x + Int8(3), Int8)
        @test gate_count(c).total == 64
        @test toffoli_depth(c) == 12
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
