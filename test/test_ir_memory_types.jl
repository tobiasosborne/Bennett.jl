using Test
using Bennett: IRStore, IRAlloca, IROperand, ssa, iconst, _narrow_inst, _ssa_operands

@testset "T1a.1 IRStore and IRAlloca types" begin

    @testset "IRStore — struct shape" begin
        s = IRStore(ssa(:gep), ssa(:v), 8)
        @test s.ptr == ssa(:gep)
        @test s.val == ssa(:v)
        @test s.width == 8
        # No dest field — matches IRBranch/IRRet void-instruction pattern
        @test !hasproperty(s, :dest)
    end

    @testset "IRAlloca — struct shape" begin
        a = IRAlloca(:p_arr, 8, iconst(4))
        @test a.dest == :p_arr
        @test a.elem_width == 8
        @test a.n_elems == iconst(4)
    end

    @testset "IRStore _narrow_inst refuses (Bennett-mrhg)" begin
        # Bennett-mrhg: a store's width is a MEMORY LAYOUT (element width of
        # the slot, byte stride, index range), not a wire width.  The pre-mrhg
        # pass rewrote it to W and produced circuits whose layout no longer
        # matched, so narrowing now refuses memory loudly.
        s8 = IRStore(ssa(:p), ssa(:v), 8)
        for s in (s8, IRStore(ssa(:p), ssa(:b), 1))
            @test_throws ArgumentError _narrow_inst(s, 8, 3)
        end
        err = try
            _narrow_inst(s8, 8, 3)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test err isa ArgumentError && occursin("Bennett-mrhg", err.msg)
        @test err isa ArgumentError && occursin("IRStore", err.msg)
    end

    @testset "IRAlloca _narrow_inst refuses (Bennett-mrhg)" begin
        # An alloca's elem_width plus n_elems IS the allocated layout; a
        # uniform width rewrite corrupts it (see the IRStore case above).
        for a in (IRAlloca(:p, 8, iconst(4)), IRAlloca(:flags, 1, iconst(8)))
            @test_throws ArgumentError _narrow_inst(a, 8, 3)
        end
        err = try
            _narrow_inst(IRAlloca(:p, 8, iconst(4)), 8, 3)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test err isa ArgumentError && occursin("Bennett-mrhg", err.msg)
    end

    @testset "IRStore _ssa_operands reports ptr and val" begin
        # Both SSA
        s = IRStore(ssa(:p), ssa(:v), 8)
        @test Set(_ssa_operands(s)) == Set([:p, :v])

        # Constant val (common after mem2reg leaves residue)
        sc = IRStore(ssa(:p), iconst(0), 8)
        @test _ssa_operands(sc) == [:p]

        # Fully-constant store (degenerate)
        scc = IRStore(iconst(0), iconst(0), 8)
        @test _ssa_operands(scc) == Symbol[]
    end

    @testset "IRAlloca _ssa_operands is empty for static, names for dynamic" begin
        # Static: n_elems is a const
        a_static = IRAlloca(:p, 8, iconst(4))
        @test _ssa_operands(a_static) == Symbol[]

        # Dynamic (not yet supported at lower time, but type accepts)
        a_dyn = IRAlloca(:p, 8, ssa(:n))
        @test _ssa_operands(a_dyn) == [:n]
    end

    @testset "Existing IR types still work (backward compat)" begin
        # sanity: existing instruction types still construct correctly
        using Bennett: IRBinOp, IRICmp, IRCast
        b = IRBinOp(:dst, :add, ssa(:a), ssa(:b), 8)
        @test b.width == 8
        c = IRCast(:dst, :zext, ssa(:x), 1, 8)
        @test c.from_width == 1
    end
end
