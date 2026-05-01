# Bennett-kv7b / U65 (#05 F9): cross-product of add × mul strategy
# kwargs. test_add_dispatcher.jl and test_mul_dispatcher.jl each
# exercise their own kwarg in isolation; neither tested an `f` that
# uses BOTH adders AND multipliers, with both kwargs explicitly set.
# A regression that broke `mul=:qcla_tree` only when paired with
# `add=:cuccaro` (or vice versa) would slip past both individual
# dispatchers. This file pins the cross product on a representative
# `f(x, y) = x*y + x + y` over Int8.

@testset "Bennett-kv7b / U65 (#05 F9) — add × mul strategy cross" begin
    f(x::Int8, y::Int8) = x * y + x + y

    # All supported (add, mul) combinations that are advertised in the
    # individual dispatcher tests. `:auto` represents the
    # default-strategy contract (covered by Bennett-fidj / U217 for
    # add=:auto liveness invariance).
    for add in (:auto, :ripple, :cuccaro, :qcla)
        for mul in (:auto, :shift_add, :qcla_tree)
            @testset "add=$add mul=$mul" begin
                c = reversible_compile(f, Int8, Int8; add=add, mul=mul)
                @test verify_reversibility(c)
                # Sample a 5×5 quadrant — full 65,536 sweep is overkill
                # for a cross-product test (12 combinations × 65k = ~785k
                # additional asserts that don't catch new regressions
                # beyond the per-pair `verify_reversibility`).
                for x in Int8(-2):Int8(2), y in Int8(-2):Int8(2)
                    @test simulate(c, (x, y)) == f(x, y)
                end
            end
        end
    end
end
