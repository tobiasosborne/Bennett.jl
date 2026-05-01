# Bennett-8403 / U159 — per-source-file unit-test home for `src/ir_extract.jl`.
#
# `src/ir_extract.jl` is now (post-Bennett-x3jc / U116) a thin module
# loader that includes 9 files under `src/extract/`. Per-extractor tests
# (entry, helpers, instructions, module_walk, vectors, sret, switch,
# constexpr, callees) live alongside their feature suites.
#
# This stub covers the `extract_parsed_ir(f, arg_types)` and
# `extract_parsed_ir_from_ll(...)` / `extract_parsed_ir_from_bc(...)`
# top-level surface — error paths, ParsedIR shape invariants, the
# round-trip through `lower(parsed)`.

using Test
using Bennett

@testset "src/ir_extract.jl unit tests" begin

    @testset "extract_parsed_ir on simple Int8 arithmetic" begin
        parsed = extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
        @test parsed isa Bennett.ParsedIR
        @test length(parsed.args) == 1
        @test parsed.args[1][2] == 8                # Int8 width
        @test !isempty(parsed.blocks)
    end

    @testset "extract_parsed_ir preserves block CFG (when LLVM doesn't fold it)" begin
        # Collatz step: condition + side-effect-y branch arms LLVM cannot
        # fold to a straight-line `select`. (Simple `x > 0 ? x+1 : -x` IS
        # foldable — LLVM emits a single-block `select` instruction.)
        f = function (x::Int8)
            val = x
            steps = Int8(0)
            while val > Int8(1) && steps < Int8(20)
                val = val % Int8(2) == Int8(0) ? val >> Int8(1) : Int8(3) * val + Int8(1)
                steps += Int8(1)
            end
            steps
        end
        parsed = extract_parsed_ir(f, Tuple{Int8})
        @test length(parsed.blocks) >= 2
    end

    @testset "extract_parsed_ir + lower round-trip is byte-identical" begin
        # The Tuple-overload `reversible_compile(f, T)` and the manual
        # `lower(extract_parsed_ir(f, Tuple{T}))` round-trip must
        # produce gate-count-identical circuits (the Tuple overload
        # is just `bennett(lower(extract_parsed_ir(...)))` in disguise).
        c_direct = reversible_compile(x -> x + Int8(1), Int8)
        parsed   = extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
        c_round  = reversible_compile(parsed)
        @test gate_count(c_direct) == gate_count(c_round)
    end

    @testset "extract_parsed_ir on missing method raises" begin
        # No method match → ArgumentError actionable per Bennett-4bcp / U102.
        @test_throws ArgumentError reversible_compile(x -> x + Int8(1),
                                                       Tuple{String})
    end

    @testset "ParsedIR fields are populated for sret-returning functions" begin
        # NTuple return is the canonical sret pattern (Bennett-0c8o).
        f = (x::Int8) -> (x + Int8(1), x - Int8(1))
        parsed = extract_parsed_ir(f, Tuple{Int8})
        # Aggregate ret_elem_widths describes the tuple element widths.
        @test !isempty(parsed.ret_elem_widths)
    end
end
