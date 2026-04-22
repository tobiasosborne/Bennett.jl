# Bennett-httg / U05: lower_loop! silently drops non-arithmetic body
# instructions AND multi-block bodies.
#
# Two defects in src/lower.jl:719-810 (`lower_loop!`):
#
# 1. Body-instruction cascade at lines ~770-776 handles only IRBinOp, IRICmp,
#    IRSelect, IRCast. Every other IR type (IRCall, IRStore, IRLoad, IRPhi,
#    IRBr, IRRet, IRPtrOffset, IRAlloca, ...) is silently dropped per
#    iteration. A loop body with `soft_fadd` or any non-arithmetic op
#    compiles to gates referencing undefined SSA names.
#
# 2. Line 751 collects ONLY the header block's non-phi instructions into
#    `body_insts`. `while`/`for` loops whose body sits in separate basic
#    blocks (typical under `optimize=false`) are silently dropped entirely.
#    `max_loop_iterations` has no effect on gate count for such loops.
#
# Fix: walk the loop body region (all blocks between header successors and
# the exit, excluding back-edges) in topological order per unroll iteration
# and dispatch each instruction through the canonical `_lower_inst!`
# dispatcher. Fail loud on nested loops, early returns, and unsupported
# in-body allocas.
#
# Catalogue: reviews/2026-04-21/UNIFIED_CATALOGUE.md U05. Reports: #04 F1,
# #04 F3 (max_loop_iterations no-op), #13 F4, #18 F9.

using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility, gate_count

# Minimal multi-block while loop. Under optimize=false, the body ends up in
# a distinct basic block (header tests the condition, body block has
# `a = a + x; i = i + 1`), exposing both defects.
function _u05_accumulator(x::Int8, n::Int8)
    a = Int8(0); i = Int8(0)
    while i < n
        a = a + x
        i = i + Int8(1)
    end
    return a
end

# Diamond inside loop body exercises phi resolution within a body block.
function _u05_branching_body(x::Int8, n::Int8)
    a = Int8(0); i = Int8(0)
    while i < n
        a = (x > Int8(0)) ? a + x : a - x
        i = i + Int8(1)
    end
    return a
end

@testset "Bennett-httg / U05: loop bodies with multi-block / non-arith ops" begin

    @testset "T1: simple multi-block while loop (catalogue repro)" begin
        c = reversible_compile(_u05_accumulator, Int8, Int8;
                               max_loop_iterations=6, optimize=false)
        # The circuit truncates at K=6 iterations; match native up to n<=6.
        for x in Int8(-3):Int8(3), n in Int8(0):Int8(6)
            @test simulate(c, (x, n)) == _u05_accumulator(x, n)
        end
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T2: max_loop_iterations actually scales gate count" begin
        c3  = reversible_compile(_u05_accumulator, Int8, Int8;
                                 max_loop_iterations=3,  optimize=false)
        c10 = reversible_compile(_u05_accumulator, Int8, Int8;
                                 max_loop_iterations=10, optimize=false)
        # Pre-fix: the body is dropped so gate counts are ~equal.
        # Post-fix: gate count grows monotonically with K.
        @test gate_count(c10).total > gate_count(c3).total
    end

    @testset "T3: diamond inside body (phi resolution within body block)" begin
        # Deferred scope — the MVP handles linear body regions only.
        # Diamond-in-body needs per-block predicate computation which in
        # turn needs the header's exit-branch condition available to body
        # blocks. Filed as follow-up bead. Stays @test_broken until fixed.
        @test_broken try
            c = reversible_compile(_u05_branching_body, Int8, Int8;
                                   max_loop_iterations=5, optimize=false)
            all(simulate(c, (x, n)) == _u05_branching_body(x, n)
                for x in Int8(-2):Int8(2) for n in Int8(0):Int8(5))
        catch
            false
        end
    end

    @testset "T4: Collatz (existing header-only body) still green — no regression" begin
        # This is the pre-existing passing test from test_loop_explicit.jl;
        # my fix must keep it byte-identical. Header-only bodies are a
        # degenerate one-block body region — the new code path reduces to
        # the old behaviour.
        function collatz_steps(x::Int8)
            steps = Int8(0); val = x
            while val > Int8(1) && steps < Int8(20)
                if val % Int8(2) == Int8(0)
                    val = val >> Int8(1)
                else
                    val = Int8(3) * val + Int8(1)
                end
                steps += Int8(1)
            end
            return steps
        end
        c = reversible_compile(collatz_steps, Int8; max_loop_iterations=20)
        for x in Int8(1):Int8(30)
            @test simulate(c, x) == collatz_steps(x)
        end
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T5: gate-count regression baselines unchanged (i8 x+1 = 100/28)" begin
        # Sanity check: non-loop lowerings remain byte-identical to baselines.
        c = reversible_compile(x -> x + Int8(1), Int8)
        gc = gate_count(c)
        @test gc.total == 100
        @test gc.Toffoli == 28
    end
end
