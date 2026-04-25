# Bennett-5kio / U109 — adder.jl, multiplier.jl, qcla.jl now call
# `sizehint!(gates, length(gates) + bound)` before their inner push!
# loops. The bound is a conservative O(W) upper estimate that avoids
# the O(log₂N) intermediate-vector reallocations Julia would otherwise
# trigger as the gate stream doubles its capacity from 0 to thousands.
#
# Pure performance hint — the gate stream's CONTENTS are unchanged.
# These tests pin:
#   1. Static inspection: each touched function calls sizehint! before
#      its push! body (no future regression silently drops the hint).
#   2. Behavioural equivalence: the canonical gate-count baselines
#      (i8 x+1 = 58, i32 x+1 = 226, i64 x+1 = 450) still hold; the i32
#      multiplication produces the documented 6860-gate / 2856-Toffoli
#      circuit; verify_reversibility passes on all four baselines.

using Test
using Bennett

@testset "Bennett-5kio / U109 — sizehint! before arithmetic push! loops" begin

    @testset "static inspection: each touched fn calls sizehint!" begin
        # adder.jl: 3 functions get a sizehint before their push! body.
        adder_src = read(joinpath(dirname(pathof(Bennett)), "adder.jl"), String)
        # Three sizehints, one per function.  An accidental drop fails here.
        @test count(==("sizehint!"),
                    [m.match for m in eachmatch(r"sizehint!", adder_src)]) >= 3
        @test occursin("Bennett-5kio", adder_src)

        mul_src = read(joinpath(dirname(pathof(Bennett)), "multiplier.jl"), String)
        @test occursin("sizehint!", mul_src)
        @test occursin("Bennett-5kio", mul_src)

        qcla_src = read(joinpath(dirname(pathof(Bennett)), "qcla.jl"), String)
        @test occursin("sizehint!", qcla_src)
        @test occursin("Bennett-5kio", qcla_src)
    end

    @testset "canonical gate counts unchanged" begin
        # CLAUDE.md §6 baselines (post-U27 add=:auto→:ripple, post-U28
        # fold_constants=true). sizehint! must be a no-op behaviourally.
        c8  = reversible_compile(x -> x + Int8(1),  Int8)
        c16 = reversible_compile(x -> x + Int16(1), Int16)
        c32 = reversible_compile(x -> x + Int32(1), Int32)
        c64 = reversible_compile(x -> x + Int64(1), Int64)

        @test gate_count(c8)  == (total = 58,  NOT = 6, CNOT = 40,  Toffoli = 12)
        @test gate_count(c16) == (total = 114, NOT = 6, CNOT = 80,  Toffoli = 28)
        @test gate_count(c32) == (total = 226, NOT = 6, CNOT = 160, Toffoli = 60)
        @test gate_count(c64) == (total = 450, NOT = 6, CNOT = 320, Toffoli = 124)
    end

    @testset "i32 multiply baseline (touches lower_mul_wide!)" begin
        c = reversible_compile((x, y) -> x * y, Int32, Int32)
        gc = gate_count(c)
        @test gc.total == 6860
        @test gc.Toffoli == 2856
    end

    @testset "verify_reversibility holds across baselines" begin
        @test verify_reversibility(reversible_compile(x -> x + Int8(1),  Int8))
        @test verify_reversibility(reversible_compile(x -> x + Int32(1), Int32))
        @test verify_reversibility(
            reversible_compile((x, y) -> x * y, Int8, Int8))
    end
end
