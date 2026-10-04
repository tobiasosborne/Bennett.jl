using Test, Bennett
@testset "Compare+select: k(x::Int8) = x > 10 ? x+1 : x+2" begin
    k(x::Int8) = x > Int8(10) ? x + Int8(1) : x + Int8(2)
    circuit = reversible_compile(k, Int8)

    for x in typemin(Int8):typemax(Int8)
        @test simulate(circuit, x) == k(x)
    end

    @test verify_reversibility(circuit)
    println("  Compare+select: ", gate_count(circuit))
    print_circuit(circuit)
end
