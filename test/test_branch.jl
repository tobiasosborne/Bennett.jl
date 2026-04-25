@testset "Multi-block branching" begin
    @testset "Nested if/else (q)" begin
        function q(x::Int8)
            if x > Int8(100)
                if x > Int8(120)
                    return x + Int8(3)
                else
                    return x + Int8(2)
                end
            else
                return x + Int8(1)
            end
        end

        ir = extract_ir(q, Tuple{Int8})
        parsed = extract_parsed_ir(q, Tuple{Int8})  # Bennett-cs2f / U42 — was parse_ir(ir)
        println("  q(x) blocks: ", length(parsed.blocks))
        println("  q(x) IR:\n", ir)

        circuit = reversible_compile(q, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(circuit, x) == q(x)
        end
        @test verify_reversibility(circuit)
        println("  Nested if/else: ", gate_count(circuit))
    end

    @testset "Branch with computation (t)" begin
        function t(x::Int8)
            if x > Int8(0)
                y = x * x
            else
                y = x + x
            end
            return y + Int8(1)
        end

        circuit = reversible_compile(t, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(circuit, x) == t(x)
        end
        @test verify_reversibility(circuit)
        println("  Branch w/ computation: ", gate_count(circuit))
    end
end
