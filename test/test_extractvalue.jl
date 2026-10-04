using Test, Bennett
@testset "extractvalue + switch + freeze" begin

    # extractvalue: return individual elements from a tuple
    @testset "extractvalue — swap pair" begin
        function swap_pair(a::Int8, b::Int8)
            return (b, a)
        end
        c = reversible_compile(swap_pair, Int8, Int8)
        for a in Int8(-8):Int8(7), b in Int8(-8):Int8(7)
            ra, rb = swap_pair(a, b)
            result = simulate(c, (a, b))
            @test result == (ra, rb)
        end
        @test verify_reversibility(c)
    end

    # extractvalue: access one element of a tuple return
    @testset "extractvalue — first element" begin
        function first_of_pair(a::Int8, b::Int8)::Int8
            t = (a + b, a - b)
            return t[1]
        end
        c = reversible_compile(first_of_pair, Int8, Int8)
        for a in Int8(-8):Int8(7), b in Int8(-8):Int8(7)
            @test Int8(simulate(c, (a, b))) == first_of_pair(a, b)
        end
        @test verify_reversibility(c)
    end

    # three-way branch (uses select chain in optimized IR, but may produce switch in unoptimized)
    @testset "three-way if/elseif/else" begin
        function classify(x::Int8)::Int8
            if x > Int8(10)
                return x - Int8(10)
            elseif x > Int8(0)
                return x
            else
                return Int8(0) - x
            end
        end
        c = reversible_compile(classify, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test Int8(simulate(c, x)) == classify(x)
        end
        @test verify_reversibility(c)
    end
end
