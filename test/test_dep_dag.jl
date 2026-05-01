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

    # Bennett-kv7b / U65 (#03 F7): the suite above was smoke-only
    # (preds is a Vector{Int}, no self-loops, length > 0). Add the
    # actual semantic invariants — topological order, read-after-write
    # correctness, output-node reachability — so that a regression in
    # `extract_dep_dag` can't silently produce a dag with the right
    # SHAPE but the wrong DEPENDENCIES.

    @testset "DAG nodes are in topological order (preds always earlier)" begin
        # `extract_dep_dag` constructs nodes by walking forward gates in
        # order; every predecessor must therefore have a strictly
        # smaller index than its successor.
        for c in (reversible_compile(x::Int8 -> x + Int8(1), Int8),
                  reversible_compile(x::Int8 -> x * x + Int8(3) * x + Int8(1), Int8),
                  reversible_compile((x::Int8, y::Int8) -> x * y + x - y, Int8, Int8))
            dag = Bennett.extract_dep_dag(c)
            for (i, node) in enumerate(dag.nodes)
                for p in node.preds
                    @test p < i
                end
                for s in node.succs
                    @test s > i
                end
            end
        end
    end

    @testset "DAG captures read-after-write on shared wires" begin
        # f(x) = x + 1 — one of the simplest functions whose lowering
        # exercises a control wire. Build the DAG; for each forward
        # gate, every control wire it reads must trace back (via preds)
        # to the most recent earlier gate that targeted that wire.
        f(x::Int8) = x + Int8(1)
        c = reversible_compile(f, Int8)
        dag = Bennett.extract_dep_dag(c)

        # The forward-gate slice corresponding to dag.nodes
        n_out = length(c.output_wires)
        n_total = length(c.gates)
        n_forward = (n_total - n_out) ÷ 2
        forward_gates = c.gates[1:n_forward]
        @test length(dag.nodes) == n_forward

        # For each gate, walk back over previous gates to find the most
        # recent producer of each control wire and assert it's in preds.
        for (i, gate) in enumerate(forward_gates)
            controls = Bennett._gate_controls(gate)
            for w in controls
                # Find the latest j < i with target_wire == w (RAW dep)
                latest = 0
                for j in (i - 1):-1:1
                    if dag.nodes[j].target_wire == w
                        latest = j
                        break
                    end
                end
                if latest > 0
                    @test latest in dag.nodes[i].preds
                end
            end
        end
    end

    @testset "DAG output_nodes are reachable from forward gates" begin
        # Output nodes (those whose target_wire feeds the CNOT copy
        # phase) must be valid forward-gate indices, and the gate they
        # point at must indeed write to a wire that's a forward-pre-copy
        # output. extract_dep_dag computes this via the copy-phase scan;
        # mirror the contract here.
        f(x::Int8) = x + Int8(1)
        c = reversible_compile(f, Int8)
        dag = Bennett.extract_dep_dag(c)

        @test !isempty(dag.output_nodes)
        # Each output node's target_wire must equal a circuit output_wire
        # (after accounting for the CNOT copy mapping in the circuit).
        n_total = length(c.gates)
        n_out = length(c.output_wires)
        n_forward = (n_total - n_out) ÷ 2
        copy_gates = c.gates[(n_forward + 1):(n_forward + n_out)]
        copy_sources = Set(Bennett._gate_controls(g)[1] for g in copy_gates)
        for oi in dag.output_nodes
            @test dag.nodes[oi].target_wire in copy_sources
        end
    end
end
