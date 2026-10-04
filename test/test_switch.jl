using Test, Bennett
@testset "Switch instruction (dynamic NTuple indexing)" begin

    @testset "simple switch: select from 3 cases" begin
        function select3(x::Int8)::Int8
            if x == Int8(0)
                return Int8(10)
            elseif x == Int8(1)
                return Int8(20)
            else
                return Int8(30)
            end
        end

        c = reversible_compile(select3, Int8)
        @test Int8(simulate(c, Int8(0))) == Int8(10)
        @test Int8(simulate(c, Int8(1))) == Int8(20)
        @test Int8(simulate(c, Int8(2))) == Int8(30)
        @test Int8(simulate(c, Int8(5))) == Int8(30)  # default
        @test verify_reversibility(c)
        println("  select3: $(gate_count(c).total) gates")
    end
end
