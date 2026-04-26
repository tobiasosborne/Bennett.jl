# Bennett-jepw / U05-followup: diamond-in-body phi resolution.
#
# Pre-fix: a `while` loop whose body contains an `if/else` (diamond CFG) cannot
# compile under `optimize=false` because `lower_loop!` did NOT compute per-block
# path predicates for body blocks. The merge-block IRPhi reached
# `_edge_predicate!` looking for `block_pred[L8]` and crashed:
#
#   ERROR: _edge_predicate!: no predicate for block L8 in phi resolution
#
# This test exercises the case the MVP from Bennett-httg (U05) deferred:
# `_u05_branching_body` — `a = (x>0) ? a+x : a-x` inside a while loop. After the
# fix, the circuit must compile, simulate identically to Julia for every legal
# input, and pass `verify_reversibility`.
#
# Per CLAUDE.md §4 (exhaustive verification), every reversible_compile result
# is checked against a Julia-native oracle for ALL inputs in the chosen sweep,
# AND `verify_reversibility` is asserted.

using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility, gate_count

# Diamond inside loop body — the canonical jepw repro.
function _jepw_branching_body(x::Int8, n::Int8)
    a = Int8(0); i = Int8(0)
    while i < n
        a = (x > Int8(0)) ? a + x : a - x
        i = i + Int8(1)
    end
    return a
end

# Diamond inside loop body with a TRIVIAL phi-merge (output of the diamond
# does not feed the loop-carried phi). Catches a different shape: phi at
# the merge whose result is consumed by a subsequent body op, not by the
# header phi.
function _jepw_diamond_used_locally(x::Int8, n::Int8)
    s = Int8(0); i = Int8(0)
    while i < n
        d = (x > Int8(0)) ? Int8(1) : Int8(-1)
        s = s + d
        i = i + Int8(1)
    end
    return s
end

# Diamond inside loop body that BOTH paths preserve the loop-carried value
# (no-op merge): a control-flow split with identical effect.
function _jepw_diamond_noop_merge(x::Int8, n::Int8)
    a = Int8(0); i = Int8(0)
    while i < n
        if x > Int8(0)
            a = a + Int8(1)
        else
            a = a - Int8(1)
        end
        i = i + Int8(1)
    end
    return a
end

@testset "Bennett-jepw / U05-followup: diamond-in-body phi resolution" begin

    @testset "T1: branching body — Julia oracle agreement (output)" begin
        # K=5 truncates the loop. Test all (x, n) with n ≤ K.
        c = reversible_compile(_jepw_branching_body, Int8, Int8;
                               max_loop_iterations=5, optimize=false)
        for x in Int8(-3):Int8(3), n in Int8(0):Int8(5)
            @test simulate(c, (x, n)) == _jepw_branching_body(x, n)
        end
    end

    @testset "T1b: branching body — verify_reversibility" begin
        c = reversible_compile(_jepw_branching_body, Int8, Int8;
                               max_loop_iterations=5, optimize=false)
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T2: diamond used locally — Julia oracle agreement" begin
        c = reversible_compile(_jepw_diamond_used_locally, Int8, Int8;
                               max_loop_iterations=4, optimize=false)
        for x in Int8(-3):Int8(3), n in Int8(0):Int8(4)
            @test simulate(c, (x, n)) == _jepw_diamond_used_locally(x, n)
        end
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T3: diamond noop-merge — Julia oracle agreement" begin
        c = reversible_compile(_jepw_diamond_noop_merge, Int8, Int8;
                               max_loop_iterations=4, optimize=false)
        for x in Int8(-3):Int8(3), n in Int8(0):Int8(4)
            @test simulate(c, (x, n)) == _jepw_diamond_noop_merge(x, n)
        end
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T4: gate count scales with K (no silent body drop)" begin
        # If diamond-in-body silently drops, K=3 and K=10 give equal counts.
        c3  = reversible_compile(_jepw_branching_body, Int8, Int8;
                                 max_loop_iterations=3,  optimize=false)
        c10 = reversible_compile(_jepw_branching_body, Int8, Int8;
                                 max_loop_iterations=10, optimize=false)
        @test gate_count(c10).total > gate_count(c3).total
    end

    @testset "T5: regression — linear body (httg/T1) still green" begin
        # Bennett-httg / U05 baseline: linear multi-block body must keep
        # working. This guards against the jepw fix breaking the MVP.
        function _u05_accumulator(x::Int8, n::Int8)
            a = Int8(0); i = Int8(0)
            while i < n
                a = a + x
                i = i + Int8(1)
            end
            return a
        end
        c = reversible_compile(_u05_accumulator, Int8, Int8;
                               max_loop_iterations=6, optimize=false)
        for x in Int8(-3):Int8(3), n in Int8(0):Int8(6)
            @test simulate(c, (x, n)) == _u05_accumulator(x, n)
        end
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T6: regression — non-loop sanity (i8 x+1 baseline pinned)" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        gc = gate_count(c)
        @test gc.total == 58
        @test gc.Toffoli == 12
    end
end
