using Random

@testset "Float circuits (soft-float → reversible)" begin
    @testset "soft_fneg circuit" begin
        circuit = reversible_compile(soft_fneg, UInt64)

        for x in [1.0, -1.0, 0.0, -0.0, 3.14, Inf]
            x_bits = reinterpret(UInt64, x)
            result = reinterpret(UInt64, simulate(circuit, x_bits))
            @test result == soft_fneg(x_bits)
        end
        @test verify_reversibility(circuit)
        println("  soft_fneg: ", gate_count(circuit))
    end

    @testset "soft_fadd circuit" begin
        circuit = reversible_compile(soft_fadd, UInt64, UInt64)

        function check_circuit(a::Float64, b::Float64)
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_i64 = simulate(circuit, (a_bits, b_bits))
            result = reinterpret(UInt64, result_i64)
            expected = soft_fadd(a_bits, b_bits)
            @test result == expected
        end

        # Basic pairs
        check_circuit(1.0, 2.0)
        check_circuit(1.0, -1.0)
        check_circuit(3.14, 2.72)
        check_circuit(-5.0, 3.0)
        check_circuit(0.0, 0.0)
        check_circuit(1.0, 0.0)
        check_circuit(0.5, 0.5)
        check_circuit(-0.0, -0.0)
        check_circuit(Inf, 1.0)
        check_circuit(Inf, -Inf)

        # Equal-magnitude same-sign: triggers false-path sensitization
        # (subtraction path computes wa - wb_aligned == 0, leaks through phi)
        check_circuit(1.0, 1.0)
        check_circuit(2.0, 2.0)
        check_circuit(-0.5, -0.5)
        check_circuit(-3.14, -3.14)
        check_circuit(1.0e10, 1.0e10)
        check_circuit(5.0e-100, 5.0e-100)

        # Random pairs
        rng = Random.MersenneTwister(42)
        for _ in 1:100
            a = rand(rng) * 200 - 100
            b = rand(rng) * 200 - 100
            check_circuit(a, b)
        end

        @test verify_reversibility(circuit)
        gc = gate_count(circuit)
        println("  soft_fadd: ", gc)
    end

    @testset "soft_fmul circuit" begin
        circuit = reversible_compile(soft_fmul, UInt64, UInt64)

        function check_circuit(a::Float64, b::Float64)
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_i64 = simulate(circuit, (a_bits, b_bits))
            result = reinterpret(UInt64, result_i64)
            expected = soft_fmul(a_bits, b_bits)
            @test result == expected
        end

        # Basic pairs
        check_circuit(2.0, 3.0)
        check_circuit(1.0, 1.0)
        check_circuit(0.5, 0.5)
        check_circuit(-2.0, 3.0)
        check_circuit(-2.0, -3.0)
        check_circuit(3.14, 2.72)
        check_circuit(0.0, 0.0)
        check_circuit(1.0, 0.0)
        check_circuit(Inf, 2.0)
        check_circuit(Inf, 0.0)
        check_circuit(Inf, -Inf)

        # Equal-magnitude (branchless: no false-path risk)
        check_circuit(2.0, 2.0)
        check_circuit(-3.0, -3.0)

        # Random pairs
        rng = Random.MersenneTwister(77)
        for _ in 1:100
            a = rand(rng) * 200 - 100
            b = rand(rng) * 200 - 100
            check_circuit(a, b)
        end

        @test verify_reversibility(circuit)
        gc = gate_count(circuit)
        println("  soft_fmul: ", gc)
    end

    @testset "Float64 division end-to-end" begin
        # Function must be generic (no ::Float64 annotation) for SoftFloat dispatch
        float_div(x, y) = x / y
        circuit = reversible_compile(float_div, Float64, Float64; max_loop_iterations=60)

        function check_div(a::Float64, b::Float64)
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result_i64 = simulate(circuit, (a_bits, b_bits))
            result_bits = reinterpret(UInt64, result_i64)
            expected_bits = reinterpret(UInt64, a / b)
            result_f = reinterpret(Float64, result_bits)
            expected_f = a / b
            # NaN sign bit is implementation-defined (IEEE 754 §6.2)
            if isnan(expected_f)
                @test isnan(result_f)
            else
                @test result_bits == expected_bits
            end
        end

        # Basic cases
        check_div(6.0, 2.0)
        check_div(1.0, 3.0)
        check_div(10.0, 10.0)
        check_div(-6.0, 2.0)
        check_div(-6.0, -2.0)
        check_div(3.14, 2.72)

        # Edge cases
        check_div(0.0, 1.0)
        check_div(1.0, Inf)
        check_div(Inf, 1.0)
        check_div(0.0, 0.0)      # NaN
        check_div(Inf, Inf)      # NaN

        # Random pairs
        rng = Random.MersenneTwister(99)
        for _ in 1:50
            a = rand(rng) * 200 - 100
            b = rand(rng) * 200 - 100
            b == 0.0 && continue
            check_div(a, b)
        end

        @test verify_reversibility(circuit)
        gc = gate_count(circuit)
        println("  Float64 div (end-to-end): ", gc)
    end

    @testset "Float64 sqrt end-to-end (Bennett-ux2)" begin
        float_sqrt(x) = sqrt(x)
        circuit = reversible_compile(float_sqrt, Float64; max_loop_iterations=70)

        # Positive finite / zero / Inf / NaN: compare against Julia's sqrt.
        # Julia's sqrt(::Float64) throws DomainError on negatives, so for
        # negative-finite/-Inf cases we check NaN directly (the IEEE-correct result).
        function check_sqrt_nonneg(a::Float64)
            a_bits = reinterpret(UInt64, a)
            result_i64 = simulate(circuit, a_bits)
            result_bits = reinterpret(UInt64, result_i64)
            expected_bits = reinterpret(UInt64, sqrt(a))
            result_f = reinterpret(Float64, result_bits)
            expected_f = sqrt(a)
            if isnan(expected_f)
                @test isnan(result_f)
            else
                @test result_bits == expected_bits
            end
        end

        function check_sqrt_nan(a::Float64)
            # IEEE: sqrt(negative non-zero) = NaN, sqrt(-Inf) = NaN
            result_i64 = simulate(circuit, reinterpret(UInt64, a))
            @test isnan(reinterpret(Float64, result_i64))
        end

        # Perfect squares
        check_sqrt_nonneg(0.0)
        check_sqrt_nonneg(1.0)
        check_sqrt_nonneg(4.0)
        check_sqrt_nonneg(9.0)
        check_sqrt_nonneg(16.0)
        check_sqrt_nonneg(100.0)
        check_sqrt_nonneg(0.25)

        # Irrational (correctly rounded)
        check_sqrt_nonneg(2.0)
        check_sqrt_nonneg(3.0)
        check_sqrt_nonneg(0.5)
        check_sqrt_nonneg(10.0)

        # Special cases
        check_sqrt_nonneg(Inf)
        check_sqrt_nonneg(-0.0)   # IEEE §6.3: sqrt(-0) = -0
        check_sqrt_nonneg(NaN)
        check_sqrt_nan(-1.0)
        check_sqrt_nan(-Inf)

        # Subnormal input
        check_sqrt_nonneg(reinterpret(Float64, UInt64(1)))   # smallest subnormal

        @test verify_reversibility(circuit)
        gc = gate_count(circuit)
        println("  Float64 sqrt (end-to-end): ", gc)
    end
end
