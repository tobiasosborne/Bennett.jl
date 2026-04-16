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

    @testset "Float32 <-> Float64 conversion (Bennett-4gk)" begin
        @testset "fpext circuit" begin
            c = reversible_compile(Bennett.soft_fpext, UInt32)

            function check(a::Float32)
                bits32 = reinterpret(UInt32, a)
                result = simulate(c, bits32)
                expected = reinterpret(UInt64, Float64(a))
                if isnan(Float64(a))
                    @test isnan(reinterpret(Float64, reinterpret(UInt64, result)))
                else
                    @test reinterpret(UInt64, result) == expected
                end
            end

            check(0.0f0); check(1.0f0); check(-1.0f0); check(3.14f0)
            check(Inf32); check(-Inf32); check(-0.0f0)
            check(floatmin(Float32)); check(floatmax(Float32))
            check(reinterpret(Float32, UInt32(1)))   # smallest subnormal
            check(reinterpret(Float32, UInt32(0x007FFFFF)))   # largest subnormal

            @test verify_reversibility(c)
            println("  soft_fpext circuit: ", gate_count(c))
        end

        @testset "fptrunc circuit" begin
            c = reversible_compile(Bennett.soft_fptrunc, UInt64)

            function check(a::Float64)
                bits64 = reinterpret(UInt64, a)
                result = simulate(c, bits64)
                expected = reinterpret(UInt32, Float32(a))
                if isnan(Float32(a))
                    @test isnan(reinterpret(Float32, reinterpret(UInt32, result)))
                else
                    @test reinterpret(UInt32, result) == expected
                end
            end

            check(0.0); check(1.0); check(-1.0); check(3.14)
            check(Inf); check(-Inf); check(-0.0)
            check(1e40)                              # overflow → Inf
            check(1e-40)                             # Float32 subnormal
            check(5e-324)                            # F64 smallest subnormal → 0
            check(Float64(floatmax(Float32)))        # exact max F32

            @test verify_reversibility(c)
            println("  soft_fptrunc circuit: ", gate_count(c))
        end
    end

    @testset "Float64 exp / exp2 end-to-end (Bennett-cel, Bennett-wigl)" begin
        # First IEEE-754 binary64 reversible exp / exp2 — algorithm: musl/Arm
        # Optimized Routines Tang-style with N=128 lookup table, degree-5
        # polynomial, and full underflow specialcase (Bennett-wigl) for
        # bit-exact subnormal output. Compiles to ~5M gates per call; ≤1 ulp
        # vs Base.exp / Base.exp2 (bit-exact vs musl reference).

        @testset "soft_exp2 circuit (bit-exact)" begin
            c = reversible_compile(Bennett.soft_exp2, UInt64)

            function check(a::Float64; tol::Int=1)
                bits = reinterpret(UInt64, a)
                result = UInt64(simulate(c, bits))
                expected = reinterpret(UInt64, exp2(a))
                if isnan(exp2(a))
                    @test isnan(reinterpret(Float64, result))
                else
                    diff = result >= expected ? result - expected : expected - result
                    @test Int64(diff) <= tol
                end
            end

            # Exact integer powers
            check(0.0; tol=0); check(1.0; tol=0); check(-1.0; tol=0)
            check(10.0; tol=0); check(-10.0; tol=0); check(50.0; tol=0); check(-50.0; tol=0)
            # Irrational
            check(0.5); check(0.25); check(-0.5); check(0.1); check(3.14159)
            # Subnormal output range (was garbage pre-Bennett-wigl)
            check(-1022.0; tol=0)       # smallest normal (boundary)
            check(-1023.0; tol=0)       # largest subnormal
            check(-1050.0; tol=0)       # mid subnormal
            check(-1074.0; tol=0)       # smallest subnormal
            # Boundary
            check(1024.0; tol=0)        # overflow → +Inf
            check(-1075.0; tol=0)       # underflow → +0
            check(Inf; tol=0); check(-Inf; tol=0); check(NaN)

            @test verify_reversibility(c)
            println("  soft_exp2 circuit (bit-exact): ", gate_count(c))
        end

        @testset "soft_exp circuit (bit-exact)" begin
            c = reversible_compile(Bennett.soft_exp, UInt64)

            function check(a::Float64; tol::Int=1)
                bits = reinterpret(UInt64, a)
                result = UInt64(simulate(c, bits))
                expected = reinterpret(UInt64, exp(a))
                if isnan(exp(a))
                    @test isnan(reinterpret(Float64, result))
                else
                    diff = result >= expected ? result - expected : expected - result
                    @test Int64(diff) <= tol
                end
            end

            check(0.0; tol=0); check(-0.0; tol=0)
            check(1.0); check(2.0); check(-1.0); check(0.5)
            check(0.69314718); check(2.302585)
            # Subnormal output range (was garbage pre-Bennett-wigl)
            check(-710.0; tol=0); check(-720.0; tol=0); check(-730.0; tol=0)
            check(-740.0; tol=0); check(-745.0; tol=0)
            # Boundary
            check(710.0; tol=0); check(-750.0; tol=0)
            check(Inf; tol=0); check(-Inf; tol=0); check(NaN)

            @test verify_reversibility(c)
            println("  soft_exp circuit (bit-exact): ", gate_count(c))
        end

        @testset "soft_fma circuit" begin
            c = reversible_compile(Bennett.soft_fma, UInt64, UInt64, UInt64)

            function check(a::Float64, b::Float64, cc::Float64)
                ab = reinterpret(UInt64, a)
                bb = reinterpret(UInt64, b)
                cb = reinterpret(UInt64, cc)
                result = reinterpret(UInt64, Int64(simulate(c, (ab, bb, cb))))
                expected = reinterpret(UInt64, Base.fma(a, b, cc))
                if isnan(Base.fma(a, b, cc))
                    @test isnan(reinterpret(Float64, result))
                else
                    @test result == expected
                end
            end

            # Basic
            check(3.0, 7.0, 0.0)
            check(1.0, 1.0, 1.0)
            check(2.0, 3.0, 4.0)
            check(-2.0, 3.0, 1.0)
            # Kahan single-rounding witness
            check(0x1.fffffffffffffp-1, 0x1.fffffffffffffp-1, -1.0)
            # Exact cancellation → +0 under RNE
            check(1.5, 2.0, -3.0)
            # Near cancellation
            check(3.14, 2.72, -1.0)
            # Subnormal mixed-scale
            check(0x1p-600, 0x1p-500, 0x1p-1100)
            # Specials
            check(Inf, 0.0, 1.0)      # Inf·0 → NaN
            check(Inf, 1.0, -Inf)     # Inf clash
            check(NaN, 1.0, 1.0)

            @test verify_reversibility(c)
            println("  soft_fma circuit: ", gate_count(c))
        end
    end
end
