using Test, Bennett
@testset "Bitwise: h(x::Int8) = (x & Int8(0x0f)) | (x >> 2)" begin
    h(x::Int8) = (x & Int8(0x0f)) | (x >> 2)
    circuit = reversible_compile(h, Int8)

    for x in typemin(Int8):typemax(Int8)
        @test simulate(circuit, x) == h(x)
    end

    @test verify_reversibility(circuit)
    println("  Bitwise: ", gate_count(circuit))
end
