using Test
using Bennett

@testset "Pebbled Bennett recursive splitting" begin
    @testset "pebbled_bennett produces correct results" begin
        f(x::Int8) = x * x + Int8(3) * x + Int8(1)

        Bennett._reset_names!()
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8})
        lr = Bennett.lower(parsed)

        n_fwd = length(lr.gates)
        n_out = length(lr.output_wires)

        c_full = Bennett.bennett(lr)

        # Pebbled with tight budget
        s = max(Bennett.min_pebbles(n_fwd), 10)
        c_peb = pebbled_bennett(lr; max_pebbles=s)

        # Gate count: 2*n_fwd + n_out (same as full Bennett for chain-structured gates)
        @test gate_count(c_peb).total == 2 * n_fwd + n_out

        # Correctness: same output for all inputs
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_peb, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_peb)

        println("  polynomial: n_fwd=$n_fwd, s=$s, gates=$(gate_count(c_peb).total)")
    end

    @testset "pebbled_bennett with minimum pebbles" begin
        f(x::Int8) = x + Int8(3)

        Bennett._reset_names!()
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8})
        lr = Bennett.lower(parsed)

        n_fwd = length(lr.gates)
        s_min = Bennett.min_pebbles(n_fwd)

        c_full = Bennett.bennett(lr)
        c_peb = pebbled_bennett(lr; max_pebbles=s_min)

        # Correctness
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_peb, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_peb)

        println("  x+3: n_fwd=$n_fwd, s_min=$s_min, gates=$(gate_count(c_peb).total)")
    end

    @testset "pebbled_bennett error on insufficient pebbles" begin
        f(x::Int8) = x * x + Int8(3) * x + Int8(1)

        Bennett._reset_names!()
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8})
        lr = Bennett.lower(parsed)

        n_fwd = length(lr.gates)
        s_min = Bennett.min_pebbles(n_fwd)

        # One fewer than minimum should error
        if s_min > 1
            @test_throws ErrorException pebbled_bennett(lr; max_pebbles=1)
        end
    end
end
