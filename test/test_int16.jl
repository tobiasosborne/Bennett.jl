using Test, Bennett
@testset "Int16 arithmetic" begin
    f(x::Int16) = x * x + Int16(3) * x + Int16(1)
    circuit = reversible_compile(f, Int16)

    for x in Int16(-50):Int16(50)
        @test simulate(circuit, x) == f(x)
    end
    # Edge cases
    for x in [typemin(Int16), typemax(Int16), Int16(32766), Int16(-32767)]
        @test simulate(circuit, x) == f(x)
    end
    @test verify_reversibility(circuit)
    println("  Int16 polynomial: ", gate_count(circuit))
end
