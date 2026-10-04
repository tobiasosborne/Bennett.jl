using Test, Bennett
@testset "Polynomial: g(x::Int8) = x*x + Int8(3)*x + Int8(1)" begin
    g(x::Int8) = x * x + Int8(3) * x + Int8(1)
    circuit = reversible_compile(g, Int8)

    for x in typemin(Int8):typemax(Int8)
        @test simulate(circuit, x) == g(x)
    end

    @test verify_reversibility(circuit)
    println("  Polynomial: ", gate_count(circuit))
    print_circuit(circuit)
end
