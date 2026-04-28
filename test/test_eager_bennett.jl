@testset "EAGER Bennett cleanup" begin

    @testset "compute_wire_mod_paths" begin
        gates = Bennett.ReversibleGate[
            Bennett.CNOTGate(1, 3),
            Bennett.CNOTGate(2, 3),
            Bennett.CNOTGate(1, 4),
            Bennett.CNOTGate(3, 5),
        ]
        paths = Bennett.compute_wire_mod_paths(gates)
        @test paths[3] == [1, 2]
        @test paths[4] == [3]
        @test paths[5] == [4]
        @test !haskey(paths, 1)
        @test !haskey(paths, 2)
    end

    @testset "compute_wire_liveness" begin
        gates = Bennett.ReversibleGate[
            Bennett.CNOTGate(1, 3),
            Bennett.CNOTGate(3, 4),
            Bennett.CNOTGate(2, 5),
        ]
        last_use = Bennett.compute_wire_liveness(gates, [5], [1, 2])
        @test last_use[1] == 1
        @test last_use[3] == 2
        @test last_use[2] == 3
        @test last_use[5] == 4

        gates2 = Bennett.ReversibleGate[
            Bennett.ToffoliGate(1, 2, 3),
            Bennett.CNOTGate(3, 4),
        ]
        last_use2 = Bennett.compute_wire_liveness(gates2, [4], [1, 2])
        @test last_use2[1] == 1
        @test last_use2[2] == 1
        @test last_use2[3] == 2
        @test last_use2[4] == 3
    end

    @testset "eager_bennett: increment correctness" begin
        f(x::Int8) = x + Int8(3)
        lr = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}))
        c_eager = eager_bennett(lr)
        c_full  = Bennett.bennett(lr)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_eager, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_eager)
    end

    @testset "eager_bennett: polynomial correctness" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        lr = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}))
        c_eager = eager_bennett(lr)
        c_full  = Bennett.bennett(lr)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_eager, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_eager)
    end

    @testset "eager_bennett: two-argument function" begin
        h(x::Int8, y::Int8) = x + y
        lr = Bennett.lower(Bennett.extract_parsed_ir(h, Tuple{Int8, Int8}))
        c_eager = eager_bennett(lr)
        c_full  = Bennett.bennett(lr)
        for x in Int8(-10):Int8(10), y in Int8(-10):Int8(10)
            @test simulate(c_eager, (x, y)) == simulate(c_full, (x, y))
        end
        @test verify_reversibility(c_eager)
    end

    @testset "eager_bennett: peak liveness reduction" begin
        f(x::Int8) = x + Int8(3)
        lr = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}))
        c_full  = Bennett.bennett(lr)
        c_eager = eager_bennett(lr)
        p_full  = peak_live_wires(c_full)
        p_eager = peak_live_wires(c_eager)
        println("  x+3: full peak=$p_full, eager peak=$p_eager")
        @test p_eager <= p_full

        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        lr2 = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}))
        c_full2  = Bennett.bennett(lr2)
        c_eager2 = eager_bennett(lr2)
        p_full2  = peak_live_wires(c_full2)
        p_eager2 = peak_live_wires(c_eager2)
        println("  poly: full peak=$p_full2, eager peak=$p_eager2")
        @test p_eager2 <= p_full2
    end

    @testset "eager_bennett: gate count baselines" begin
        # Bennett-kv7b / U65 (#03 F12): pre-fix this testset printed gate
        # counts but had ZERO @test assertions — a regression that
        # changed eager_bennett's output silently passed. Now pinned.
        f(x::Int8) = x + Int8(1)
        lr = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}))
        c_full  = Bennett.bennett(lr)
        c_eager = eager_bennett(lr)
        gc_full  = gate_count(c_full)
        gc_eager = gate_count(c_eager)
        # eager_bennett MUST preserve the gate count of bennett() — it's
        # a re-scheduling only (PRS15 EAGER cleanup), not an additional
        # optimization. Toffoli count is identical for the same reason.
        @test gc_eager.total == gc_full.total
        @test gc_eager.Toffoli == gc_full.Toffoli
        # Pinned post-U27/U28 baselines (matches test_gate_count_regression).
        @test gc_full.total == 58
        @test gc_full.Toffoli == 12
        # eager_bennett's win is in peak_live_wires (not gate count).
        @test peak_live_wires(c_eager) <= peak_live_wires(c_full)
        @test verify_reversibility(c_full)
        @test verify_reversibility(c_eager)
    end
end
