# Bennett-11xt / U23: each compiled circuit below now carries a
# `verify_reversibility` call (+ simulate sanity) so the DAG extraction
# is rooted in a circuit that actually satisfies Bennett's invariants.
@testset "Dependency DAG extraction" begin

    @testset "simple addition DAG" begin
        f(x::Int8) = x + Int8(1)
        c = reversible_compile(f, Int8)
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(1)
        dag = Bennett.extract_dep_dag(c)

        # DAG should have nodes for each gate
        @test length(dag.nodes) > 0

        # Each node should have predecessor list
        for node in dag.nodes
            @test isa(node.preds, Vector{Int})
        end

        # Output nodes should be identifiable
        @test !isempty(dag.output_nodes)
    end

    @testset "polynomial DAG" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        c = reversible_compile(g, Int8)
        @test verify_reversibility(c)
        @test simulate(c, Int8(0)) == Int8(1)
        dag = Bennett.extract_dep_dag(c)

        # More complex function = more nodes
        @test length(dag.nodes) > 10
        println("  polynomial DAG: $(length(dag.nodes)) nodes")
    end

    @testset "DAG edge correctness" begin
        f(x::Int8) = x + Int8(1)
        c = reversible_compile(f, Int8)
        @test verify_reversibility(c)
        dag = Bennett.extract_dep_dag(c)

        # Every pred/succ relationship must be symmetric
        for (i, node) in enumerate(dag.nodes)
            for pred_idx in node.preds
                @test i in dag.nodes[pred_idx].succs
            end
            for succ_idx in node.succs
                @test i in dag.nodes[succ_idx].preds
            end
        end

        # No self-loops
        for (i, node) in enumerate(dag.nodes)
            @test !(i in node.preds)
            @test !(i in node.succs)
        end

        # Output nodes should exist and have valid indices
        for oi in dag.output_nodes
            @test 1 <= oi <= length(dag.nodes)
        end
    end
end
