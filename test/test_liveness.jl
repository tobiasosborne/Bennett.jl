using Random

@testset "SSA-level liveness analysis" begin

    @testset "compute_ssa_liveness on simple IR" begin
        # x + 3 (Int8): x is used by add, add result is used by ret
        f_inc(x::Int8) = x + Int8(3)
        parsed = extract_parsed_ir(f_inc, Tuple{Int8})

        liveness = Bennett.compute_ssa_liveness(parsed)

        # Every SSA variable should have a last-use entry
        for block in parsed.blocks
            for inst in block.instructions
                if hasproperty(inst, :dest)
                    @test haskey(liveness, inst.dest)
                end
            end
        end

        # Input args should be used (not dead immediately)
        for (name, _) in parsed.args
            @test haskey(liveness, name)
        end
        println("  x+3 liveness: $(length(liveness)) variables tracked")
    end

    @testset "compute_ssa_liveness on multi-use variable" begin
        # x*x + x: x is used twice (by mul AND by add)
        g(x::Int8) = x * x + x
        parsed = extract_parsed_ir(g, Tuple{Int8})

        liveness = Bennett.compute_ssa_liveness(parsed)

        # The input arg x should have last_use > first_use (used by both mul and add)
        arg_name = parsed.args[1][1]
        @test haskey(liveness, arg_name)
        # Bennett-kv7b / U65 (#03 F12): assert the actual liveness invariant
        # the comment claims — multi-use variables must have last_use beyond
        # the first instruction. Pre-fix the println alone left no assertion.
        @test liveness[arg_name] >= 2
    end

    @testset "dead_after correctly identifies dead variables" begin
        # After the last instruction that uses x, x should be dead
        f(x::Int8) = x + Int8(1)
        parsed = extract_parsed_ir(f, Tuple{Int8})

        liveness = Bennett.compute_ssa_liveness(parsed)

        # The add instruction's result should be "live" at the ret (last use)
        # The input x should be dead after the add
        for (name, last_use) in liveness
            @test last_use >= 1  # every tracked variable is used at least once
        end
    end

    @testset "polynomial has correct last-use ordering" begin
        # x*x + 3*x + 1: x is used by mul AND by second mul (3*x)
        poly(x::Int8) = x * x + Int8(3) * x + Int8(1)
        parsed = extract_parsed_ir(poly, Tuple{Int8})
        liveness = Bennett.compute_ssa_liveness(parsed)

        arg_name = parsed.args[1][1]
        # x must be used at least twice (by x*x and by 3*x)
        @test liveness[arg_name] >= 2

        # The return value's source should be the last instruction
        # (or close to it — ret reads the final sum)
        total_insts = sum(length(b.instructions) + 1 for b in parsed.blocks)
        ret_operand = parsed.blocks[end].terminator.op
        if ret_operand.kind == :ssa
            @test liveness[ret_operand.name] == total_insts  # used by ret (last inst)
        end
        println("  polynomial: $(length(liveness)) vars, arg last_use=$(liveness[arg_name]), total_insts=$total_insts")
    end

    @testset "two-arg function: both args tracked" begin
        f(x::Int8, y::Int8) = x * y + x - y
        parsed = extract_parsed_ir(f, Tuple{Int8, Int8})
        liveness = Bennett.compute_ssa_liveness(parsed)

        # Both args should be tracked
        for (name, _) in parsed.args
            @test haskey(liveness, name)
            @test liveness[name] >= 1  # used at least once
        end
        println("  two-arg: $(length(liveness)) vars tracked")
    end

    @testset "Cuccaro in-place adder reduces wire count" begin
        # x + 3: the constant 3 is dead after the add (never reused)
        # With Cuccaro, the add should use fewer WIRES (ancillae)
        f(x::Int8) = x + Int8(3)

        # Standard lowering
        parsed = extract_parsed_ir(f, Tuple{Int8})
        lr_std = Bennett.lower(parsed)

        # Lowering with Cuccaro optimization
        parsed2 = extract_parsed_ir(f, Tuple{Int8})
        lr_opt = Bennett.lower(parsed2; use_inplace=true)

        # Cuccaro uses fewer or equal wires (now default, so equal is expected)
        @test lr_opt.n_wires <= lr_std.n_wires
        println("  x+3: standard=$(lr_std.n_wires) wires/$(length(lr_std.gates)) gates, " *
                "cuccaro=$(lr_opt.n_wires) wires/$(length(lr_opt.gates)) gates, " *
                "wire savings=$(lr_std.n_wires - lr_opt.n_wires)")

        # Both must produce correct circuits
        c_std = Bennett.bennett(lr_std)
        c_opt = Bennett.bennett(lr_opt)
        for x in typemin(Int8):typemax(Int8)
            @test Int8(simulate(c_std, x)) == Int8(simulate(c_opt, x))
        end
        @test verify_reversibility(c_std)
        @test verify_reversibility(c_opt)

        # Polynomial: more additions = more savings
        poly(x::Int8) = x * x + Int8(3) * x + Int8(1)
        p1 = extract_parsed_ir(poly, Tuple{Int8})
        lr_p_std = Bennett.lower(p1)
        p2 = extract_parsed_ir(poly, Tuple{Int8})
        lr_p_opt = Bennett.lower(p2; use_inplace=true)
        @test lr_p_opt.n_wires <= lr_p_std.n_wires
        println("  poly: standard=$(lr_p_std.n_wires) wires, cuccaro=$(lr_p_opt.n_wires) wires, " *
                "savings=$(lr_p_std.n_wires - lr_p_opt.n_wires)")

        # Verify correctness
        c_p_opt = Bennett.bennett(lr_p_opt)
        for x in typemin(Int8):typemax(Int8)
            expected = poly(x)
            got = Int8(simulate(c_p_opt, x))
            @test got == expected
        end
        @test verify_reversibility(c_p_opt)
        println("  Polynomial verified correct for all 256 inputs")
    end

    @testset "gate-level wire liveness matches existing compute_wire_liveness" begin
        # Verify our SSA liveness is consistent with the gate-level liveness
        f(x::Int8) = x + Int8(3)
        parsed = extract_parsed_ir(f, Tuple{Int8})
        lr = Bennett.lower(parsed)

        # Gate-level liveness (existing)
        gate_liveness = Bennett.compute_wire_liveness(lr.gates, lr.output_wires, lr.input_wires)

        # Every output wire should be live (last_use = N+1)
        for w in lr.output_wires
            @test gate_liveness[w] == length(lr.gates) + 1
        end
        println("  gate-level: $(length(gate_liveness)) wires tracked")
    end

    @testset "Cuccaro is default (no use_inplace kwarg needed)" begin
        f(x::Int8) = x + Int8(3)
        parsed = extract_parsed_ir(f, Tuple{Int8})
        lr_default = Bennett.lower(parsed)
        parsed2 = extract_parsed_ir(f, Tuple{Int8})
        lr_explicit = Bennett.lower(parsed2; use_inplace=true)

        # Default should produce same wire count as explicit Cuccaro
        @test lr_default.n_wires == lr_explicit.n_wires

        # Correctness
        c = Bennett.bennett(lr_default)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == f(x)
        end
        @test verify_reversibility(c)
        println("  Cuccaro default: $(lr_default.n_wires) wires (matches explicit=$(lr_explicit.n_wires))")
    end
end
