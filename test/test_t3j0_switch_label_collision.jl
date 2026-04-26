# Bennett-t3j0 / U83: defensive collision guard for `_expand_switches`'s
# synthetic block labels and the `:__unreachable__` sentinel.
#
# Pre-fix `_expand_switches` generated synthetic blocks named
# `_sw_<orig_label>_<i>` and `_sw_cmp_<orig_label>_<i>`. If `_expand_switches`
# was ever invoked twice on the same blocks list (or the input happened to
# already contain blocks named with that prefix), the second pass would
# emit blocks whose labels collided with existing ones — silent shadowing.
# Similarly, the `unreachable` LLVM terminator is rewritten to
# `IRBranch(nothing, :__unreachable__, nothing)`, and a user block
# coincidentally named `:__unreachable__` would be confused with the
# sentinel.
#
# Per CLAUDE.md §1 (fail loud) the extraction layer now asserts up-front
# that no input block uses a reserved label.

using Test
using Bennett
using Bennett: IRBasicBlock, IRBranch, IRRet, IROperand, _expand_switches

@testset "Bennett-t3j0 / U83: switch / unreachable label-collision asserts" begin

    @testset "T1: _expand_switches errors on input named with `_sw_` prefix" begin
        # A user block with the synthetic prefix — cannot proceed without
        # ambiguity.
        bad_block = IRBasicBlock(:_sw_top_1,
                                 Bennett.IRInst[],
                                 IRRet(IROperand(:const, Symbol(""), 0), 8))
        @test_throws ErrorException _expand_switches([bad_block])
    end

    @testset "T2: _expand_switches errors on `_sw_cmp_` prefix too" begin
        bad_block = IRBasicBlock(:_sw_cmp_foo_3,
                                 Bennett.IRInst[],
                                 IRRet(IROperand(:const, Symbol(""), 0), 8))
        @test_throws ErrorException _expand_switches([bad_block])
    end

    @testset "T3: _expand_switches errors on `:__unreachable__` block" begin
        # A user block coincidentally named the same as the unreachable
        # sentinel — would be confused with dead-code branches.
        bad_block = IRBasicBlock(:__unreachable__,
                                 Bennett.IRInst[],
                                 IRRet(IROperand(:const, Symbol(""), 0), 8))
        @test_throws ErrorException _expand_switches([bad_block])
    end

    @testset "T4: regression — non-conflicting labels still work" begin
        # An ordinary single block with no switch terminator passes
        # through untouched.
        ok_block = IRBasicBlock(:top,
                                Bennett.IRInst[],
                                IRRet(IROperand(:const, Symbol(""), 0), 8))
        result = _expand_switches([ok_block])
        @test length(result) == 1
        @test result[1].label === :top
    end

    @testset "T5: regression — end-to-end function with switch still extracts" begin
        # Functions whose Julia source compiles to a switch-like cascade
        # must still produce a well-formed ParsedIR with the synthetic
        # `_sw_*` blocks unaffected by the new asserts.
        f(x::Int8) = x == Int8(1) ? Int8(10) :
                     x == Int8(2) ? Int8(20) :
                     x == Int8(3) ? Int8(30) : Int8(0)
        c = reversible_compile(f, Int8)
        for x in Int8(0):Int8(5)
            @test simulate(c, Int8, x) == f(x)
        end
        @test verify_reversibility(c; n_tests=8)
    end
end
