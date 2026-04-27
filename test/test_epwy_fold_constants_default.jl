using Test
using Bennett

# Bennett-epwy / U28: `fold_constants=false` was the default despite the
# pass being strictly safe (can only remove/simplify gates — never adds
# one). The default is now `true` in `lower()` so every user of
# `reversible_compile` gets the win automatically.
#
# These tests pin that the default path equals the explicit-on path and
# beats the explicit-off path on patterns where folding helps. They must
# FAIL when the default is `false` and PASS when it's `true`.
@testset "U28 / Bennett-epwy: fold_constants default is true" begin

    @testset "lower() default == fold_constants=true on x*3 (optimize=false)" begin
        # Originally pinned `x * Int8(1)`, but Bennett-5qrn / U57 added a
        # trivial-identity peephole at the dispatcher that catches x*1
        # before fold even runs (both lr_on and lr_off collapse to the
        # 8-CNOT copy-out, eliminating the fold delta). x*3 still has
        # partial-product Toffolis with constant operand bits that fold
        # collapses, preserving the U28 "fold meaningfully helps" assertion
        # this test was originally written for. Measured ratio: 3.24×.
        f(x::Int8) = x * Int8(3)
        # Re-extract per call — the IR object is not stateless across
        # `lower`'s side-effectful wire allocator.
        lr_default = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}; optimize=false))
        lr_on      = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}; optimize=false);
                                   fold_constants=true)
        lr_off     = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}; optimize=false);
                                   fold_constants=false)
        @test length(lr_default.gates) == length(lr_on.gates)
        @test length(lr_default.gates) < length(lr_off.gates)
        # Regression guard: the U28 catalogue claim was x*1 → ~4× reduction
        # (now superseded by the 5qrn peephole). For x*3 the post-peephole
        # ratio is ~3.24×; pin "at least 3× smaller" so normal churn doesn't
        # silently demote this below the documented level.
        @test length(lr_off.gates) >= 3 * length(lr_on.gates)
    end

    @testset "lower() default == fold_constants=true on polynomial (optimize=true)" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        lr_default = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}; optimize=true))
        lr_on      = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}; optimize=true);
                                   fold_constants=true)
        lr_off     = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}; optimize=true);
                                   fold_constants=false)
        @test length(lr_default.gates) == length(lr_on.gates)
        @test length(lr_default.gates) < length(lr_off.gates)
    end

    @testset "reversible_compile path inherits the default — polynomial Int8" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        c = reversible_compile(g, Int8)
        @test verify_reversibility(c)
        # Exhaustive correctness under the folded default.
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == g(x)
        end
        # Regression guard (U28): the folded total is strictly less than the
        # pre-fix 872 gates baseline from test_gate_count_regression.jl.
        @test gate_count(c).total < 872
    end

    @testset "self_reversing primitives are not corrupted by the fold" begin
        # `_fold_constants` drops `gate_groups` and previously also dropped
        # `self_reversing` (a pre-P1 constructor). A self-reversing `lr`
        # that then entered `bennett()` would have been double-run. Pin
        # the round-trip: fold(lr_self_reversing) must preserve self_reversing.
        lr = Bennett.LoweringResult(Bennett.ReversibleGate[], 4,
                                    [1, 2], [3, 4], [2], [2],
                                    Bennett.GateGroup[], true)
        lr2 = Bennett._fold_constants(lr)
        @test lr2.self_reversing == true
    end
end
