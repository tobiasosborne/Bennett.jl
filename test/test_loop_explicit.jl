using Test, Bennett
@testset "Explicit loops (bounded unrolling)" begin
    @testset "Collatz steps" begin
        function collatz_steps(x::Int8)
            steps = Int8(0)
            val = x
            while val > Int8(1) && steps < Int8(20)
                if val % Int8(2) == Int8(0)
                    val = val >> Int8(1)
                else
                    val = Int8(3) * val + Int8(1)
                end
                steps += Int8(1)
            end
            return steps
        end

        ir = extract_ir(collatz_steps, Tuple{Int8})
        println("  collatz_steps IR:\n", ir)

        circuit = reversible_compile(collatz_steps, Int8; max_loop_iterations=20)

        for x in Int8(1):Int8(30)
            @test simulate(circuit, x) == collatz_steps(x)
        end
        @test verify_reversibility(circuit)
        println("  Collatz steps: ", gate_count(circuit))
        print_circuit(circuit)
    end
end
