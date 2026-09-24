using Random

# Bennett-stwr: `compute_ssa_liveness` (per-name last-use index) was deleted —
# last-use liveness is unsound for the predicated, K-fold-unrolled,
# non-LIFO-uncomputed lowering, and its index space never matched the
# lowering's. Its replacement is the order-free occurrence count
# `compute_ssa_use_counts` + exclusive-reader set `compute_inplace_targets`
# (consumed only by an explicit `add=:cuccaro`). Full soundness sweep:
# test_stwr_cuccaro_soundness.jl.

@testset "SSA operand occurrences + in-place eligibility" begin

    @testset "compute_ssa_use_counts on simple IR" begin
        # x + 3 (Int8): x is read by the add, the add result by the ret
        f_inc(x::Int8) = x + Int8(3)
        parsed = extract_parsed_ir(f_inc, Tuple{Int8})
        uses = Bennett.compute_ssa_use_counts(parsed)

        # Every argument is read exactly once; the returned value exactly
        # once (the ret terminator is counted).
        for (name, _) in parsed.args
            @test get(uses, name, 0) == 1
        end
        ret = parsed.blocks[end].terminator
        @test ret isa Bennett.IRRet && ret.op isa Bennett.SSAOperand
        @test uses[ret.op.name] == 1
        # ... so both are exclusive readers.
        t = Bennett.compute_inplace_targets(parsed)
        @test parsed.args[1][1] in t
    end

    @testset "compute_ssa_use_counts on multi-use variable" begin
        # x*x + x: x is read by the mul AND by the add
        g(x::Int8) = x * x + x
        for opt in (true, false)
            parsed = extract_parsed_ir(g, Tuple{Int8}; optimize=opt)
            arg_name = parsed.args[1][1]
            @test Bennett.compute_ssa_use_counts(parsed)[arg_name] >= 2
            @test !(arg_name in Bennett.compute_inplace_targets(parsed))
        end
    end

    @testset "occurrences, not users: add %x, %x counts 2" begin
        f(x::Int8) = x + x
        parsed = extract_parsed_ir(f, Tuple{Int8}; optimize=false)
        @test any(i -> i isa Bennett.IRBinOp && i.op === :add && i.op1 == i.op2,
                  parsed.blocks[1].instructions)
        @test Bennett.compute_ssa_use_counts(parsed)[parsed.args[1][1]] == 2
        @test isempty(intersect(Bennett.compute_inplace_targets(parsed),
                                Set(first.(parsed.args))))
        # every recorded count is ≥ 1
        @test all(>=(1), values(Bennett.compute_ssa_use_counts(parsed)))
    end

    @testset "polynomial: arg multi-use, ret operand counted once" begin
        # x*x + 3*x + 1: x is read by x*x (twice) AND by 3*x
        poly(x::Int8) = x * x + Int8(3) * x + Int8(1)
        parsed = extract_parsed_ir(poly, Tuple{Int8})
        uses = Bennett.compute_ssa_use_counts(parsed)
        arg_name = parsed.args[1][1]
        @test uses[arg_name] >= 2
        ret_operand = parsed.blocks[end].terminator.op
        if ret_operand isa Bennett.SSAOperand
            @test uses[ret_operand.name] == 1
        end
    end

    @testset "two-arg function: both args multi-use ⇒ neither is a target" begin
        # optimize=false: LLVM (optimize=true) reassociates to x*(y+1) - y,
        # which reads x only once (rule 5 — pin the IR shape we reason about).
        f(x::Int8, y::Int8) = x * y + x - y
        parsed = extract_parsed_ir(f, Tuple{Int8, Int8}; optimize=false)
        uses = Bennett.compute_ssa_use_counts(parsed)
        t = Bennett.compute_inplace_targets(parsed)
        for (name, _) in parsed.args
            @test uses[name] >= 2
            @test !(name in t)
        end
    end

    @testset "explicit add=:cuccaro uses fewer wires than :ripple" begin
        # x + 3: the constant's fresh wires are consumed in place.
        f(x::Int8) = x + Int8(3)
        parsed = extract_parsed_ir(f, Tuple{Int8})
        lr_rip = Bennett.lower(parsed; add=:ripple)
        lr_cuc = Bennett.lower(parsed; add=:cuccaro)
        @test lr_cuc.n_wires < lr_rip.n_wires

        c_rip = Bennett.bennett(lr_rip)
        c_cuc = Bennett.bennett(lr_cuc)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_rip, x) == f(x)
            @test simulate(c_cuc, x) == f(x)
        end
        @test verify_reversibility(c_rip)
        @test verify_reversibility(c_cuc)

        # Polynomial: more additions, still fewer wires and still correct.
        poly(x::Int8) = x * x + Int8(3) * x + Int8(1)
        p = extract_parsed_ir(poly, Tuple{Int8})
        lr_p_rip = Bennett.lower(p; add=:ripple)
        lr_p_cuc = Bennett.lower(p; add=:cuccaro)
        @test lr_p_cuc.n_wires < lr_p_rip.n_wires
        c_p = Bennett.bennett(lr_p_cuc)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_p, x) == poly(x)
        end
        @test verify_reversibility(c_p)
    end

    @testset "gate-level wire liveness matches existing compute_wire_liveness" begin
        f(x::Int8) = x + Int8(3)
        parsed = extract_parsed_ir(f, Tuple{Int8})
        lr = Bennett.lower(parsed)

        # Gate-level liveness (existing)
        gate_liveness = Bennett.compute_wire_liveness(lr.gates, lr.output_wires, lr.input_wires)

        # Every output wire should be live (last_use = N+1)
        for w in lr.output_wires
            @test gate_liveness[w] == length(lr.gates) + 1
        end
    end

    @testset "use_inplace=true is lower()'s default; false forces copy-in" begin
        f(x::Int8, y::Int8) = x + y
        parsed = extract_parsed_ir(f, Tuple{Int8, Int8})
        lr_default  = Bennett.lower(parsed; add=:cuccaro)
        lr_explicit = Bennett.lower(parsed; add=:cuccaro, use_inplace=true)
        lr_copy     = Bennett.lower(parsed; add=:cuccaro, use_inplace=false)
        @test lr_default.gates == lr_explicit.gates
        @test lr_default.n_wires == lr_explicit.n_wires
        @test lr_copy.n_wires == lr_default.n_wires + 8    # +W wires for the copy

        for lr in (lr_default, lr_copy)
            c = Bennett.bennett(lr)
            for x in Int8(-20):Int8(20), y in typemin(Int8):typemax(Int8)
                @test simulate(c, (x, y)) == f(x, y)
            end
            @test verify_reversibility(c)
        end
    end
end
