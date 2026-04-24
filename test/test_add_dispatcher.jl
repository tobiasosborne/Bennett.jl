using Test
using Bennett

# D1: verify the add-op strategy dispatcher can force each available strategy
# via a kwarg. U27 / Bennett-spa8: `:auto` was pre-D1 Cuccaro-when-op2-dead
# but Cuccaro loses on every measured metric, so `:auto` → `:ripple` now.

@testset "add dispatcher: :auto equals :ripple (U27)" begin
    # x + 1 at Int8: the `:auto` path was Cuccaro pre-U27; now ripple.
    # Pin the equivalence explicitly so silent re-regression would fail here.
    c_auto = reversible_compile(x -> x + Int8(1), Int8; add=:auto)
    c_rip  = reversible_compile(x -> x + Int8(1), Int8; add=:ripple)
    @test gate_count(c_auto).total   == gate_count(c_rip).total
    @test gate_count(c_auto).Toffoli == gate_count(c_rip).Toffoli
end

@testset "add dispatcher: :ripple distinguishable from :cuccaro" begin
    c_rip = reversible_compile(x -> x + Int8(1), Int8; add=:ripple)
    c_cuc = reversible_compile(x -> x + Int8(1), Int8; add=:cuccaro)
    # Cuccaro and ripple produce genuinely different gate lists — if
    # they matched, the explicit kwarg wasn't being honored.
    @test gate_count(c_rip) != gate_count(c_cuc)
    @test verify_reversibility(c_rip)
    for x in Int8(-5):Int8(5)
        @test simulate(c_rip, x) == x + Int8(1)
    end
end

@testset "add dispatcher: :cuccaro forces Cuccaro in-place" begin
    c = reversible_compile(x -> x + Int8(1), Int8; add=:cuccaro)
    @test verify_reversibility(c)
    for x in Int8(-5):Int8(5)
        @test simulate(c, x) == x + Int8(1)
    end
end

@testset "add dispatcher: :qcla forces QCLA" begin
    c_qcla = reversible_compile((x, y) -> x + y, Int8, Int8; add=:qcla)
    c_auto = reversible_compile((x, y) -> x + y, Int8, Int8; add=:auto)
    # QCLA has distinctly more Toffolis than ripple/Cuccaro at W=8
    @test gate_count(c_qcla).Toffoli > gate_count(c_auto).Toffoli
    @test verify_reversibility(c_qcla)
    for x in (Int8(-5), Int8(0), Int8(5), Int8(42)), y in (Int8(0), Int8(1), Int8(-1), Int8(10))
        @test simulate(c_qcla, (x, y)) == x + y
    end
end

@testset "add dispatcher: unknown strategy fails loudly" begin
    @test_throws Exception reversible_compile(x -> x + Int8(1), Int8; add=:nonsense_strategy)
end
