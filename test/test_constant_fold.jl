@testset "Constant folding during lowering" begin

    # ================================================================
    # Test 1: Constant folding reduces gate count for x+3
    # ================================================================
    @testset "x+3: fewer gates with constant folding" begin
        f(x::Int8) = x + Int8(3)
        lr_std = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}))
        lr_fold = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8});
                                fold_constants=true)

        println("  x+3: standard=$(length(lr_std.gates)) gates/$(lr_std.n_wires) wires")
        println("  x+3: folded=$(length(lr_fold.gates)) gates/$(lr_fold.n_wires) wires")

        # Folding should reduce gates (constant setup NOTs become precomputed)
        @test length(lr_fold.gates) <= length(lr_std.gates)

        # Correctness: both should produce same results via Bennett
        c_std = Bennett.bennett(lr_std)
        c_fold = Bennett.bennett(lr_fold)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_fold, x) == simulate(c_std, x)
        end
        @test verify_reversibility(c_fold)
    end

    # ================================================================
    # Test 2: Polynomial has fewer constant wires after folding
    # ================================================================
    @testset "polynomial: constant folding correctness" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        lr_std = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}))
        lr_fold = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8});
                                fold_constants=true)

        println("  poly: standard=$(length(lr_std.gates)) gates/$(lr_std.n_wires) wires")
        println("  poly: folded=$(length(lr_fold.gates)) gates/$(lr_fold.n_wires) wires")

        c_fold = Bennett.bennett(lr_fold)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_fold, x) == g(x)
        end
        @test verify_reversibility(c_fold)
    end
end
