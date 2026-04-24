using Test
using Bennett

# Bennett-spa8 / U27: `_pick_add_strategy(:auto)` used to pick Cuccaro
# whenever op2 was dead (const OR SSA last-use). The theoretical
# advantage of the in-place Cuccaro adder is a 1-wire saving. In
# practice Bennett's copy-out pass doubles the output wires anyway,
# so the saving evaporates — and Cuccaro has strictly worse Toffoli
# depth and slightly worse total gates on every 2-operand add.
#
# Measured on `(x,y) -> x+y` at W=32:
#   cuccaro: 410 total / T-depth 124
#   ripple : 346 total / T-depth 62   (~2× depth reduction)
#
# This test pins `add=:auto` to the ripple choice so the regression
# is invisible no more.
@testset "Bennett-spa8 / U27: add :auto picks ripple" begin

    @testset "2-operand x+y: auto == ripple on total + Toffoli-depth" begin
        for (T, W) in [(Int8, 8), (Int16, 16), (Int32, 32), (Int64, 64)]
            c_auto = reversible_compile((x, y) -> x + y, T, T)
            c_rip  = reversible_compile((x, y) -> x + y, T, T; add=:ripple)
            @test gate_count(c_auto).total   == gate_count(c_rip).total
            @test gate_count(c_auto).Toffoli == gate_count(c_rip).Toffoli
            @test toffoli_depth(c_auto)      == toffoli_depth(c_rip)
            @test verify_reversibility(c_auto)
        end
    end

    @testset "1-operand x+const: auto == ripple" begin
        for T in (Int8, Int16, Int32, Int64)
            one = T(1)
            c_auto = reversible_compile(x -> x + one, T)
            c_rip  = reversible_compile(x -> x + one, T; add=:ripple)
            @test gate_count(c_auto).total   == gate_count(c_rip).total
            @test gate_count(c_auto).Toffoli == gate_count(c_rip).Toffoli
            @test verify_reversibility(c_auto)
        end
    end

    @testset "explicit add=:cuccaro still available" begin
        # Cuccaro isn't removed — users can still request it when they
        # genuinely want the in-place behaviour (e.g. building up
        # gate-group-sensitive pipelines).
        c = reversible_compile((x, y) -> x + y, Int32, Int32; add=:cuccaro)
        @test verify_reversibility(c)
        # Cuccaro total should differ from ripple on this 2-op pattern —
        # if it didn't, the dispatch never fired.
        c_rip = reversible_compile((x, y) -> x + y, Int32, Int32; add=:ripple)
        @test gate_count(c).total != gate_count(c_rip).total
    end

    @testset "Toffoli-depth wins — ≥ 1.5× on W ≥ 16" begin
        for (T, minW) in [(Int16, 16), (Int32, 32), (Int64, 64)]
            c_auto = reversible_compile((x, y) -> x + y, T, T)
            c_cuc  = reversible_compile((x, y) -> x + y, T, T; add=:cuccaro)
            # Cuccaro serializes every Toffoli through a carry chain;
            # ripple's carry chain is the same length but doesn't hold
            # the uncompute half, so Bennett's reversed copy roughly
            # halves the effective T-depth. Pin ≥ 1.5× margin.
            @test 1.5 * toffoli_depth(c_auto) <= toffoli_depth(c_cuc)
        end
    end
end
