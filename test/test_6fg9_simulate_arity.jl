using Test
using Bennett

# Bennett-6fg9 / U19 — `simulate(circuit, inputs::Tuple)` had no arity
# check. A single-input circuit called with a two-tuple silently used
# `inputs[1]` and dropped the rest; a circuit called with a too-short
# tuple crashed with a raw BoundsError deep inside the simulator. Same
# gap in `_simulate_ctrl`. Post-fix: loud at the entry point naming the
# expected vs supplied arity.

@testset "Bennett-6fg9 simulate arity guard" begin

    # Two-input circuit: f(x, y) = x + y (Int8).
    c2 = reversible_compile((x::Int8, y::Int8) -> x + y, Int8, Int8)
    @test length(c2.input_widths) == 2
    # Baseline sanity: correct 2-arg call.
    @test simulate(c2, (Int8(3), Int8(4))) == Int8(7)

    # T1 — wrong-arity tuple (too short).
    @test_throws Exception simulate(c2, (Int8(3),))
    # T2 — wrong-arity tuple (too long).
    @test_throws Exception simulate(c2, (Int8(3), Int8(4), Int8(5)))

    # One-input circuit: guard on the tuple overload too.
    c1 = reversible_compile(x::Int8 -> x + Int8(1), Int8)
    @test length(c1.input_widths) == 1
    @test simulate(c1, (Int8(7),)) == Int8(8)           # correct
    @test_throws Exception simulate(c1, (Int8(7), Int8(9)))   # wrong arity
    @test_throws Exception simulate(c1, ())                   # empty tuple

    # The scalar overload already had a guard; re-verify.
    @test_throws ErrorException simulate(c2, Int8(3))   # 2-input circuit, scalar input

    # Bit-width bounds: values too big for their declared width should
    # raise (not silently wrap). 8-bit input accepts [-128, 255] inclusive
    # (we ingest from `(v >> i) & 1`, so any overflow is silently chopped
    # — raise instead).
    @test_throws Exception simulate(c1, Int64(1) << 40)  # 40-bit value → 8-bit input
end
