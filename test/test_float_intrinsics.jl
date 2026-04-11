@testset "Float utility intrinsics" begin

    @testset "copysign(Float64, Float64)" begin
        f(x, y) = copysign(x, y)
        circuit = reversible_compile(f, Float64, Float64)
        @test verify_reversibility(circuit)

        gc = gate_count(circuit)
        println("  copysign: $(gc.total) gates, $(gc.Toffoli) Toffoli")

        # Test cases
        for (x, y, expected) in [
            (3.0, 1.0, 3.0),
            (3.0, -1.0, -3.0),
            (-3.0, 1.0, 3.0),
            (-3.0, -1.0, -3.0),
            (0.0, -1.0, -0.0),
        ]
            result_bits = simulate(circuit, (reinterpret(UInt64, x), reinterpret(UInt64, y)))
            result = reinterpret(Float64, reinterpret(UInt64, Int64(result_bits)))
            @test result === expected
        end
    end

    @testset "floor(Float64)" begin
        f_floor(x) = floor(x)
        circuit = reversible_compile(f_floor, Float64)
        @test verify_reversibility(circuit)

        gc = gate_count(circuit)
        println("  floor: $(gc.total) gates, $(gc.Toffoli) Toffoli")

        for (x, expected) in [
            (2.7, 2.0), (-2.7, -3.0), (0.5, 0.0), (-0.5, -1.0),
            (3.0, 3.0), (-3.0, -3.0), (0.0, 0.0),
        ]
            result_bits = simulate(circuit, reinterpret(UInt64, x))
            result = reinterpret(Float64, reinterpret(UInt64, Int64(result_bits)))
            @test result === expected
        end
    end

    @testset "ceil(Float64)" begin
        f_ceil(x) = ceil(x)
        circuit = reversible_compile(f_ceil, Float64)
        @test verify_reversibility(circuit)

        gc = gate_count(circuit)
        println("  ceil: $(gc.total) gates, $(gc.Toffoli) Toffoli")

        for (x, expected) in [
            (2.3, 3.0), (-2.3, -2.0), (0.5, 1.0), (-0.5, -0.0),
            (3.0, 3.0), (-3.0, -3.0), (0.0, 0.0),
        ]
            result_bits = simulate(circuit, reinterpret(UInt64, x))
            result = reinterpret(Float64, reinterpret(UInt64, Int64(result_bits)))
            @test result === expected
        end
    end

    @testset "trunc(Float64)" begin
        f_trunc(x) = trunc(x)
        circuit = reversible_compile(f_trunc, Float64)
        @test verify_reversibility(circuit)

        gc = gate_count(circuit)
        println("  trunc: $(gc.total) gates, $(gc.Toffoli) Toffoli")

        for (x, expected) in [
            (2.7, 2.0), (-2.7, -2.0), (0.5, 0.0), (-0.5, -0.0),
        ]
            result_bits = simulate(circuit, reinterpret(UInt64, x))
            result = reinterpret(Float64, reinterpret(UInt64, Int64(result_bits)))
            @test result === expected
        end
    end
end
