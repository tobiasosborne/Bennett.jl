using Test
using Bennett

# D1: verify the add-op strategy dispatcher can force each available strategy
# via a kwarg and that :auto preserves pre-D1 default behavior.

@testset "add dispatcher: :auto preserves pre-D1 defaults" begin
    # x + 1 at Int8: pre-D1 baseline is Cuccaro (op2=const is dead, in-place fires).
    # This exact gate count matches test_gate_count_regression.jl.
    c_auto = reversible_compile(x -> x + Int8(1), Int8; add=:auto)
    c_now  = reversible_compile(x -> x + Int8(1), Int8)   # unchanged call
    @test gate_count(c_auto).total == gate_count(c_now).total
    @test gate_count(c_auto).Toffoli == gate_count(c_now).Toffoli
end

@testset "add dispatcher: :ripple forces ripple-carry" begin
    c_rip = reversible_compile(x -> x + Int8(1), Int8; add=:ripple)
    c_auto = reversible_compile(x -> x + Int8(1), Int8; add=:auto)
    # Ripple has different structure than Cuccaro, so gate counts must differ
    # at some level (either total or Toffoli). Verify at least one differs.
    @test gate_count(c_rip) != gate_count(c_auto)
    @test verify_reversibility(c_rip)
    # Simulate + check: x + 1 still works
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
