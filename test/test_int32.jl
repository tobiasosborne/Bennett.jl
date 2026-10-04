using Test, Bennett
@testset "Int32 arithmetic" begin
    f(x::Int32) = x * Int32(7) + Int32(42)
    circuit = reversible_compile(f, Int32)

    # Random sampling — can't exhaustively test 2^32
    using Random
    Random.seed!(42)
    for _ in 1:1000
        x = rand(Int32(-10000):Int32(10000))
        @test simulate(circuit, x) == f(x)
    end
    # Edge cases
    for x in Int32[0, 1, -1, typemax(Int32), typemin(Int32)]
        @test simulate(circuit, x) == f(x)
    end
    @test verify_reversibility(circuit)
    println("  Int32 linear: ", gate_count(circuit))
end
