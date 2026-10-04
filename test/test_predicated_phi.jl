using Test, Bennett
@testset "Path-predicate phi resolution" begin

    # Simple if/else (baseline)
    @testset "simple if/else" begin
        f(x::Int8) = x > Int8(0) ? x + Int8(1) : x - Int8(1)
        c = reversible_compile(f, Int8)
        for x in typemin(Int8):typemax(Int8)
            expected = f(x)
            @test Int8(simulate(c, x)) == expected
        end
        @test verify_reversibility(c)
    end

    # Diamond: both branches contribute to same phi
    @testset "diamond CFG" begin
        function diamond(x::Int8)::Int8
            if x > Int8(0)
                y = x + x
                if y > Int8(20)
                    return Int8(20)
                end
            else
                y = Int8(0) - x
                if y == Int8(0)
                    return Int8(99)
                end
            end
            return y
        end
        c = reversible_compile(diamond, Int8)
        for x in typemin(Int8):typemax(Int8)
            expected = diamond(x)
            @test Int8(simulate(c, x)) == expected
        end
        @test verify_reversibility(c)
    end

    # Nested conditionals with overlapping conditions
    @testset "nested with shared condition pattern" begin
        function nested_shared(a::Int8, b::Int8)::Int8
            if a > b
                diff = a - b
            else
                diff = b - a
            end
            # diff is |a - b| (for non-wrapping values)
            if diff > Int8(10)
                return Int8(10)
            end
            return diff
        end
        c = reversible_compile(nested_shared, Int8, Int8)
        for a in Int8(-16):Int8(15), b in Int8(-16):Int8(15)
            expected = nested_shared(a, b)
            @test Int8(simulate(c, (a, b))) == expected
        end
        @test verify_reversibility(c)
    end

    # Three-way branch (chained if/elseif/else)
    @testset "three-way branch" begin
        function three_way(x::Int8)::Int8
            if x > Int8(10)
                return x - Int8(10)
            elseif x > Int8(0)
                return x
            else
                return Int8(0) - x
            end
        end
        c = reversible_compile(three_way, Int8)
        for x in typemin(Int8):typemax(Int8)
            expected = three_way(x)
            @test Int8(simulate(c, x)) == expected
        end
        @test verify_reversibility(c)
    end
end
