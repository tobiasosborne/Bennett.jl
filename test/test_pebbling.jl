@testset "Pebbling strategies" begin

    @testset "Knill recursion base cases" begin
        # F(1, s) = 1 for all s >= 1
        for s in 1:10
            @test Bennett.knill_pebble_cost(1, s) == 1
        end
    end

    @testset "Full Bennett = 2n-1" begin
        # F(n, n) = 2n-1 (unlimited space)
        for n in 1:20
            @test Bennett.knill_pebble_cost(n, n) == 2n - 1
        end
    end

    @testset "min_pebbles" begin
        @test Bennett.min_pebbles(1) == 1
        @test Bennett.min_pebbles(2) == 2
        @test Bennett.min_pebbles(4) == 3
        @test Bennett.min_pebbles(8) == 4
        @test Bennett.min_pebbles(16) == 5
        @test Bennett.min_pebbles(100) == 8  # 1 + ceil(log2(100)) = 8
    end

    @testset "space-time tradeoff" begin
        n = 100
        # Full Bennett: space=100, time=199
        full = Bennett.pebble_tradeoff(n)
        @test full.space == 100
        @test full.time == 199

        # Constrained: fewer pebbles = more time, time matches Knill formula
        for s in [10, 15, 20, 50]
            result = Bennett.pebble_tradeoff(n; max_space=s)
            @test result.space >= Bennett.min_pebbles(n)
            @test result.time >= 2n - 1
            @test result.time == Bennett.knill_pebble_cost(n, result.space)
            println("  n=$n, space=$(result.space): time=$(result.time), overhead=$(round(result.overhead, digits=2))x")
        end
    end

    @testset "pebbled_bennett correctness" begin
        # Pebbled Bennett must produce same results as full Bennett
        f(x::Int8) = x * x + Int8(3) * x + Int8(1)

        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8})
        lr = Bennett.lower(parsed)

        # Full Bennett (baseline)
        c_full = Bennett.bennett(lr)

        # Pebbled Bennett with constrained space
        n_gates = length(lr.gates)
        c_peb = pebbled_bennett(lr; max_pebbles=n_gates ÷ 2)

        # Must produce identical results for all inputs
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_peb, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_peb)

        # Pebbled should have more gates (recomputation) but same correctness
        gc_full = gate_count(c_full)
        gc_peb = gate_count(c_peb)
        println("  full Bennett: $(gc_full.total) gates")
        println("  pebbled ($(n_gates÷2) pebbles): $(gc_peb.total) gates")
    end

    @testset "Knill Theorem 2.3: feasibility" begin
        # n <= 2^{s-1}
        @test Bennett.knill_pebble_cost(2, 2) < typemax(Int) ÷ 2  # 2 <= 2^1 ✓
        @test Bennett.knill_pebble_cost(4, 3) < typemax(Int) ÷ 2  # 4 <= 2^2 ✓
        @test Bennett.knill_pebble_cost(8, 4) < typemax(Int) ÷ 2  # 8 <= 2^3 ✓
    end
end
