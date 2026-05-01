@testset "Two args: m(x::Int8, y::Int8) = x*y + x - y" begin
    m(x::Int8, y::Int8) = x * y + x - y
    circuit = reversible_compile(m, Int8, Int8)

    # Bennett-kv7b / U65 (#03 F9): the original sweep covered 256 of
    # 65,536 Int8×Int8 pairs (16×16 in the non-negative quadrant) — a
    # 0.4 % corner sample. Replace with the FULL 65,536-pair exhaustive
    # cross-product so every signed/unsigned overflow boundary, every
    # negative-times-negative product, and every sign-flip carry path is
    # touched.
    for x in typemin(Int8):typemax(Int8), y in typemin(Int8):typemax(Int8)
        @test simulate(circuit, (x, y)) == m(x, y)
    end

    @test verify_reversibility(circuit)
    println("  Two args: ", gate_count(circuit))
end
