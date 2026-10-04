using Test, Bennett
@testset "Increment: f(x::Int8) = x + Int8(3)" begin
    f(x::Int8) = x + Int8(3)
    circuit = reversible_compile(f, Int8)

    for x in typemin(Int8):typemax(Int8)
        @test simulate(circuit, x) == f(x)
    end

    @test verify_reversibility(circuit)
    println("  Increment: ", gate_count(circuit))
end
