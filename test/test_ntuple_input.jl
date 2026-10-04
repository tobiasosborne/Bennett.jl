using Test, Bennett
@testset "NTuple input (pointer parameters)" begin

    # Pack a tuple of Int8s into a single integer for simulate
    function pack_tuple(vals::NTuple{N, Int8}) where N
        result = UInt64(0)
        for i in 1:N
            result |= UInt64(reinterpret(UInt8, vals[i])) << (8 * (i - 1))
        end
        return result
    end

    @testset "3-element tuple: a*b + c" begin
        function process3(t::NTuple{3, Int8})::Int8
            return t[1] * t[2] + t[3]
        end
        c = reversible_compile(process3, Tuple{NTuple{3, Int8}})
        for a in Int8(-4):Int8(3), b in Int8(-4):Int8(3), cc in Int8(-4):Int8(3)
            @test Int8(simulate(c, pack_tuple((a, b, cc)))) == process3((a, b, cc))
        end
        @test verify_reversibility(c)
    end

    @testset "2-element tuple: max" begin
        function tuple_max(t::NTuple{2, Int8})::Int8
            return t[1] > t[2] ? t[1] : t[2]
        end
        c = reversible_compile(tuple_max, Tuple{NTuple{2, Int8}})
        for a in Int8(-8):Int8(7), b in Int8(-8):Int8(7)
            @test Int8(simulate(c, pack_tuple((a, b)))) == tuple_max((a, b))
        end
        @test verify_reversibility(c)
    end
end
