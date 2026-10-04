using Test, Bennett
using Random

@testset "Float64 polynomial (end-to-end)" begin
    f(x) = x * x + 3x + 1

    @testset "compile and simulate" begin
        circuit = reversible_compile(f, Float64)

        function check(x::Float64)
            x_bits = reinterpret(UInt64, x)
            result_bits = reinterpret(UInt64, simulate(circuit, x_bits))
            expected_bits = reinterpret(UInt64, f(x))
            @test result_bits == expected_bits
        end

        # Basic values
        check(0.0)
        check(1.0)
        check(-1.0)
        check(2.0)
        check(2.5)
        check(0.5)
        check(-0.5)
        check(10.0)
        check(0.1)
        check(3.14)

        # Random values
        rng = Random.MersenneTwister(42)
        for _ in 1:50
            x = rand(rng) * 20 - 10
            check(x)
        end

        @test verify_reversibility(circuit)
        gc = gate_count(circuit)
        println("  Float64 polynomial x²+3x+1: ", gc)
    end
end
