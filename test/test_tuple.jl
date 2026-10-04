using Test, Bennett
@testset "Tuple return (insertvalue/aggregate)" begin
    @testset "Swap pair" begin
        swap_pair(a::Int8, b::Int8) = (b, a)
        circuit = reversible_compile(swap_pair, Int8, Int8)

        for a in Int8(0):Int8(15), b in Int8(0):Int8(15)
            @test simulate(circuit, (a, b)) == (b, a)
        end
        @test verify_reversibility(circuit)
        println("  Swap pair: ", gate_count(circuit))
    end

    @testset "Complex mul real" begin
        complex_mul_real(a_re::Int8, a_im::Int8, b_re::Int8) = (a_re * b_re, a_im * b_re)
        circuit = reversible_compile(complex_mul_real, Int8, Int8, Int8)

        for ar in Int8(0):Int8(7), ai in Int8(0):Int8(7), br in Int8(0):Int8(7)
            @test simulate(circuit, (ar, ai, br)) == complex_mul_real(ar, ai, br)
        end
        @test verify_reversibility(circuit)
        println("  Complex mul real: ", gate_count(circuit))
    end

    @testset "Dot product (4-arg, scalar return)" begin
        dot_product(x1::Int8, x2::Int8, y1::Int8, y2::Int8) = x1 * y1 + x2 * y2
        circuit = reversible_compile(dot_product, Int8, Int8, Int8, Int8)

        for x1 in Int8(0):Int8(7), x2 in Int8(0):Int8(7),
            y1 in Int8(0):Int8(7), y2 in Int8(0):Int8(7)
            @test simulate(circuit, (x1, x2, y1, y2)) == dot_product(x1, x2, y1, y2)
        end
        @test verify_reversibility(circuit)
        println("  Dot product: ", gate_count(circuit))
    end
end
