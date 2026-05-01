# Bennett-8403 / U159 — per-source-file unit-test home for `src/Bennett.jl`.
#
# `src/Bennett.jl` is the module top-level: defines `_SUPPORTED_SCALAR_ARGS`,
# `CompileOptions`, `_reject_unknown_kwargs`, `_is_supported_arg_type`, and
# the three `reversible_compile` overloads (Tuple / ParsedIR / Float64) plus
# their `CompileOptions`-positional wrappers (Bennett-u71l / U161).
#
# The reversible_compile entry point is exercised end-to-end by every other
# test file in this directory; this stub holds tests that target the
# DISPATCH and VALIDATION layer specifically (kwarg validation, the
# `_SUPPORTED_SCALAR_ARGS` whitelist, the `CompileOptions`→kwarg
# conversion). Per-strategy lowering tests live in `test_lowering_*.jl`
# style files; this one is for the surface API.

using Test
using Bennett

@testset "src/Bennett.jl unit tests" begin

    @testset "reversible_compile basic dispatch (Tuple overload)" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test c isa Bennett.ReversibleCircuit
        @test gate_count(c).total == 58   # pinned baseline (CLAUDE.md §6)
        @test verify_reversibility(c)
    end

    @testset "CompileOptions defaults are the kwarg defaults" begin
        opts = CompileOptions()
        @test opts.optimize == true
        @test opts.add == :auto
        @test opts.mul == :auto
        @test opts.strategy == :auto
        @test opts.fold_constants == true
        @test opts.target == :gate_count
        @test opts.bit_width == 0
        @test opts.max_loop_iterations == 0
        @test opts.compact_calls == false
    end

    @testset "CompileOptions overload matches kwarg overload (Tuple path)" begin
        c_kw   = reversible_compile(x -> x + Int8(1), Tuple{Int8})
        c_opts = reversible_compile(x -> x + Int8(1), Tuple{Int8}, CompileOptions())
        @test gate_count(c_kw) == gate_count(c_opts)
    end

    @testset "kwarg validation rejects unknown kwargs" begin
        # Tuple overload accepts `optimize`; passing a typo raises ArgumentError
        # via `_reject_unknown_kwargs` (Bennett-xlsz / U29).
        @test_throws ArgumentError reversible_compile(x -> x, Int8;
                                                       optimze=true)  # typo
    end

    @testset "ParsedIR overload rejects cross-overload kwargs" begin
        parsed = extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
        # `optimize` only applies to the Tuple/Float64 path (controls IR
        # extraction); ParsedIR rejects it.
        @test_throws ArgumentError reversible_compile(parsed; optimize=false)
        @test_throws ArgumentError reversible_compile(parsed; bit_width=8)
        @test_throws ArgumentError reversible_compile(parsed; strategy=:tabulate)
    end

    @testset "_is_supported_arg_type covers all SUPPORTED_SCALAR_ARGS" begin
        for T in Bennett._SUPPORTED_SCALAR_ARGS
            @test Bennett._is_supported_arg_type(T)
        end
        @test !Bennett._is_supported_arg_type(Float32)  # Bennett-3rph deviation
        @test !Bennett._is_supported_arg_type(Symbol)
        @test  Bennett._is_supported_arg_type(NTuple{4, UInt64})  # aggregate
    end

    @testset "rejects unsupported arg types with actionable error" begin
        @test_throws ArgumentError reversible_compile(x -> x, Float32)
    end
end
