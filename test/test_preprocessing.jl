using Test
using Bennett

@testset "T0.1 LLVM pass pipeline control in extract_parsed_ir" begin

    @testset "default empty passes (Bennett-s8gs)" begin
        # Bennett-s8gs / U206: passes defaults to String[] (empty Vector),
        # not Union{Nothing,Vector{String}}. Type-stable hot path. Empty
        # default and explicit empty are equivalent.
        f(x::Int8) = x + Int8(1)
        parsed_default = Bennett.extract_parsed_ir(f, Tuple{Int8})
        parsed_empty   = Bennett.extract_parsed_ir(f, Tuple{Int8}; passes=String[])
        @test length(parsed_default.blocks) == length(parsed_empty.blocks)
        for (b1, b2) in zip(parsed_default.blocks, parsed_empty.blocks)
            @test length(b1.instructions) == length(b2.instructions)
        end
    end

    @testset "custom passes run without error" begin
        f(x::Int8) = x * Int8(3) + Int8(1)
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8}; passes=["sroa", "mem2reg"])
        @test parsed isa Bennett.ParsedIR
        @test !isempty(parsed.blocks)
    end

    @testset "combine with optimize=false" begin
        f(x::Int8) = x + Int8(2)
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8}; optimize=false, passes=["mem2reg"])
        @test parsed isa Bennett.ParsedIR
    end

    @testset "empty pass list is a no-op" begin
        f(x::Int8) = x + Int8(1)
        parsed_empty = Bennett.extract_parsed_ir(f, Tuple{Int8}; passes=String[])
        parsed_default = Bennett.extract_parsed_ir(f, Tuple{Int8})
        @test length(parsed_empty.blocks) == length(parsed_default.blocks)
    end

    @testset "reversible_compile still works (full pipeline)" begin
        # Backward compat: the top-level reversible_compile path should be unaffected.
        c = reversible_compile(x -> x + Int8(3), Int8)
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == x + Int8(3)
        end
        @test verify_reversibility(c)
    end
end

@testset "T0.2 preprocess=true runs SROA+mem2reg+simplifycfg+instcombine" begin
    using LLVM
    using InteractiveUtils: code_llvm

    @testset "DEFAULT_PREPROCESSING_PASSES is defined and non-empty" begin
        @test Bennett.DEFAULT_PREPROCESSING_PASSES isa Vector{String}
        @test "sroa" in Bennett.DEFAULT_PREPROCESSING_PASSES
        @test "mem2reg" in Bennett.DEFAULT_PREPROCESSING_PASSES
    end

    @testset "preprocess=true eliminates allocas in a function that has them" begin
        # This function produces 5 allocas + 6 stores in raw Julia IR (optimize=false)
        f1(x::Int8) = let arr = [x, x + Int8(1)]; arr[1] + arr[2]; end

        # Count raw-IR allocas/stores to establish baseline
        buf = IOBuffer()
        code_llvm(buf, f1, (Int8,); optimize=false, debuginfo=:none, dump_module=true)
        raw_ir = String(take!(buf))
        raw_allocas = length(collect(eachmatch(r"= alloca ", raw_ir)))
        @test raw_allocas > 0  # sanity check: this function should have allocas

        # After preprocess=true, the module should have zero allocas/stores
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, raw_ir)
            Bennett._run_passes!(mod, Bennett.DEFAULT_PREPROCESSING_PASSES)
            post = sprint(io -> show(io, mod))
            @test length(collect(eachmatch(r"= alloca ", post))) == 0
            @test length(collect(eachmatch(r"(?m)^[ \t]+store ", post))) == 0
            dispose(mod)
        end
    end

    @testset "extract_parsed_ir; preprocess=true runs on optimize=false IR" begin
        f(x::Int8) = x + Int8(1)
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8}; optimize=false, preprocess=true)
        @test parsed isa Bennett.ParsedIR
        @test !isempty(parsed.blocks)
    end

    @testset "preprocess=true is additive with explicit passes=" begin
        # If both are supplied, preprocess provides defaults that the explicit list appends to
        f(x::Int8) = x + Int8(1)
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8};
                                           preprocess=true,
                                           passes=["simplifycfg"])
        @test parsed isa Bennett.ParsedIR
    end
end
