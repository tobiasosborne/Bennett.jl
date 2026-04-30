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
    # Bennett-kv7b / U65 (#03 F16) — was 4×4=16 sampled pairs. Now
    # exhaustive 256×256 Int8 (65,536 assertions) + Int16 sweep across
    # signed boundary cases. The mul lowering must be bit-exact across
    # the whole representable Int8 range; sampling left ~99.97% of pairs
    # untested.
    c = reversible_compile((x, y) -> x * y, Int8, Int8; mul=:shift_add)
    @test verify_reversibility(c)
    for x in typemin(Int8):typemax(Int8), y in typemin(Int8):typemax(Int8)
        @test simulate(c, (x, y)) == (x * y)
    end
    # UInt8 — exhaustive (also 65,536 pairs)
    c_u = reversible_compile((x, y) -> x * y, UInt8, UInt8; mul=:shift_add)
    @test verify_reversibility(c_u)
    for x in typemin(UInt8):typemax(UInt8), y in typemin(UInt8):typemax(UInt8)
        @test simulate(c_u, (x, y)) == (x * y)
    end
    # Int16 — boundary sample (typemin/typemax/-1/0/1/etc) cross-product
    c16 = reversible_compile((x, y) -> x * y, Int16, Int16; mul=:shift_add)
    @test verify_reversibility(c16)
    edges16 = Int16[typemin(Int16), typemin(Int16) + Int16(1), Int16(-256), Int16(-1),
                    Int16(0), Int16(1), Int16(256), typemax(Int16) - Int16(1), typemax(Int16)]
    for x in edges16, y in edges16
        @test simulate(c16, (x, y)) == (x * y)
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
    # Bennett-kv7b / U65 (#03 F16) — was 3×3=9 sampled pairs.
    # Exhaustive 256×256 Int8 sweep against the schoolbook reference.
    for x in typemin(Int8):typemax(Int8), y in typemin(Int8):typemax(Int8)
        @test simulate(c_tree, (x, y)) == (x * y)
    end
end

@testset "mul dispatcher: unknown strategy fails loudly" begin
    @test_throws Exception reversible_compile((x, y) -> x * y, Int8, Int8; mul=:bogus)
end
