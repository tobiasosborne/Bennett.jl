# Bennett-6l2h / U67 + Bennett-xmdx / U66 — branching-callee coverage gaps
#
# Two related untested code paths:
#   - U67 (lower_call! `compact=true`): existing test_callee_bennett.jl only
#     exercises straight-line callees (x*x + 3x + 1, x+1.0).  This file
#     adds branching coverage.
#   - U66 (`controlled(circuit)` on branching): existing test_controlled.jl
#     only wraps straight-line circuits.  Bead claims MUX × controlled
#     interaction may leak ancillae when ctrl=0.  This file pins the
#     correctness invariant.
#
# Both gaps share the same "branching callee" pattern, so one file covers
# them.  Using `abs(x)` (branching on sign bit) and a more complex
# branch-then-arithmetic case.

using Test
using Bennett

# ── Branching callees (top-level for LLVM IR extraction per CLAUDE.md §5) ──

# Plain Int8 abs.  Branches on sign.  Bennett-friendly: pure, deterministic.
function _abs_i8(x::Int8)::Int8
    return x < Int8(0) ? -x : x
end

# Branch + arithmetic.  Different gate counts on each path force
# real MUX-conditional behaviour.
function _piecewise_i8(x::Int8)::Int8
    return x > Int8(0) ? x * Int8(2) : x + Int8(1)
end

@testset "Bennett-6l2h / U67 — lower_call! compact=true on branching callee" begin

    @testset "abs(x) under compact_calls=true vs default" begin
        c_default = reversible_compile(_abs_i8, Int8)
        c_compact = reversible_compile(_abs_i8, Int8; compact_calls=true)

        @test verify_reversibility(c_default)
        @test verify_reversibility(c_compact)

        # Exhaustive Int8 sweep — 256 inputs.  Both arms must produce the
        # same result and match Julia's native abs (well, to the extent
        # _abs_i8 above mirrors it).
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_default, x) == _abs_i8(x)
            @test simulate(c_compact, x) == _abs_i8(x)
        end

        # `compact_calls=true` re-applies Bennett to each callee, which
        # always produces strictly more gates than the inlined-forward
        # form (the test_callee_bennett.jl pattern).  Sanity-check the
        # ordering as a regression on the strategy.
        @test gate_count(c_compact).total >= gate_count(c_default).total
    end

    @testset "piecewise(x) under compact_calls=true" begin
        c = reversible_compile(_piecewise_i8, Int8; compact_calls=true)
        @test verify_reversibility(c)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == _piecewise_i8(x)
        end
    end
end

@testset "Bennett-xmdx / U66 — controlled() on branching callee" begin

    @testset "controlled(abs(x)) ctrl=0/1 exhaustive Int8" begin
        c  = reversible_compile(_abs_i8, Int8)
        cc = controlled(c)

        @test verify_reversibility(cc)

        # Bead's correctness invariant: ctrl=0 ⇒ output is zero (gated off);
        # ctrl=1 ⇒ output matches the unwrapped circuit.  Any ancilla leak
        # under ctrl=0 from the MUX × controlled interaction would surface
        # here as either non-zero output or as `verify_reversibility` failing
        # (returning ancillae must be zero).
        for x in typemin(Int8):typemax(Int8)
            @test simulate(cc, true,  x) == _abs_i8(x)
            @test simulate(cc, false, x) == Int8(0)
        end
    end

    @testset "controlled(piecewise(x)) ctrl=0/1 exhaustive Int8" begin
        c  = reversible_compile(_piecewise_i8, Int8)
        cc = controlled(c)

        @test verify_reversibility(cc)

        for x in typemin(Int8):typemax(Int8)
            @test simulate(cc, true,  x) == _piecewise_i8(x)
            @test simulate(cc, false, x) == Int8(0)
        end
    end
end
