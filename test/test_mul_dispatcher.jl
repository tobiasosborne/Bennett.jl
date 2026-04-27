using Test
using Bennett

# P2/P3: verify reversible_compile(f, T; mul=:auto|:shift_add|:qcla_tree)
# forces each strategy and yields distinct gate counts.
# Bennett-tbm6 (2026-04-27): :karatsuba removed — vestigial at every
# supported width. The dispatcher now rejects it loud.

@testset "mul dispatcher: :auto preserves pre-P2/P3 default" begin
    c_auto = reversible_compile((x, y) -> x * y, Int8, Int8; mul=:auto)
    c_now  = reversible_compile((x, y) -> x * y, Int8, Int8)
    @test gate_count(c_auto) == gate_count(c_now)
end

@testset "mul dispatcher: :shift_add gives shift-and-add baseline" begin
    c = reversible_compile((x, y) -> x * y, Int8, Int8; mul=:shift_add)
    @test verify_reversibility(c)
    for x in (Int8(-5), Int8(0), Int8(5), Int8(7)), y in (Int8(0), Int8(1), Int8(3), Int8(-1))
        @test simulate(c, (x, y)) == (x * y)
    end
end

@testset "mul dispatcher: :karatsuba is removed (Bennett-tbm6)" begin
    # Pre-tbm6 Karatsuba was 1.91-3.49× WORSE Toffoli count than schoolbook
    # at every supported width (W ≤ 64). Retired 2026-04-27.
    @test_throws Exception reversible_compile((x, y) -> x * y, Int16, Int16; mul=:karatsuba)
end

@testset "mul dispatcher: :qcla_tree forces Sun-Borissov tree" begin
    c_tree = reversible_compile((x, y) -> x * y, Int8, Int8; mul=:qcla_tree)
    c_auto = reversible_compile((x, y) -> x * y, Int8, Int8; mul=:auto)
    @test verify_reversibility(c_tree)
    # Distinct strategies → distinct total gate counts.
    @test gate_count(c_tree).total != gate_count(c_auto).total
    # QCLA tree uses more Toffolis than shift-add at W=8.
    @test gate_count(c_tree).Toffoli > gate_count(c_auto).Toffoli
    for x in (Int8(2), Int8(-3), Int8(7)), y in (Int8(3), Int8(-5), Int8(0))
        @test simulate(c_tree, (x, y)) == (x * y)
    end
end

@testset "mul dispatcher: unknown strategy fails loudly" begin
    @test_throws Exception reversible_compile((x, y) -> x * y, Int8, Int8; mul=:bogus)
end
