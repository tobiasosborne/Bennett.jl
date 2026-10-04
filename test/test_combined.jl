using Test, Bennett
@testset "Combined: controlled + branching" begin
    @testset "Controlled nested-if" begin
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

        circuit = reversible_compile(q, Int8)
        cc = controlled(circuit)

        for x in typemin(Int8):typemax(Int8)
            @test simulate(cc, true, x) == q(x)
            @test simulate(cc, false, x) == Int8(0)
        end
        @test verify_reversibility(cc)
        println("  Controlled nested-if: ", gate_count(cc.circuit))
    end

    @testset "Controlled compare+select" begin
        k(x::Int8) = x > Int8(10) ? x + Int8(1) : x + Int8(2)
        circuit = reversible_compile(k, Int8)
        cc = controlled(circuit)

        for x in typemin(Int8):typemax(Int8)
            @test simulate(cc, true, x) == k(x)
            @test simulate(cc, false, x) == Int8(0)
        end
        @test verify_reversibility(cc)
        println("  Controlled compare+select: ", gate_count(cc.circuit))
    end
end
