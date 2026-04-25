# Bennett-wlf6 / U145 — public API docstrings now use ```jldoctest
# fences (with `setup = :(using Bennett)`) instead of plain ```julia
# fences for executable example blocks. Once Documenter.jl is wired
# in (Bennett-doh6 / U158), these are auto-executed by the doctest
# runner and a docstring drift becomes a CI-style test failure.
#
# This test does NOT actually run the doctests — that needs
# Documenter.jl, which is not yet a project dep. It DOES verify by
# static inspection that the canonical jldoctest fence is present in
# each of the load-bearing public-API docstrings (reversible_compile,
# simulate, gate_count, depth, controlled), so a future agent who
# regresses one of them by reverting the fence to plain ```julia
# (or by stripping the setup kwarg) sees an immediate test failure.

using Test
using Bennett

# Files where at least one ```jldoctest fence must exist post-wlf6.
const _WLF6_DOCTEST_FILES = [
    "Bennett.jl",        # reversible_compile entry-point
    "simulator.jl",      # simulate
    "diagnostics.jl",    # gate_count, depth
    "controlled.jl",     # controlled / simulate(::ControlledCircuit, ...)
]

@testset "Bennett-wlf6 / U145 — jldoctest fences on public API" begin

    @testset "each file has at least one ```jldoctest fence" begin
        for fname in _WLF6_DOCTEST_FILES
            path = joinpath(dirname(pathof(Bennett)), fname)
            src = read(path, String)
            @testset "$fname" begin
                @test occursin("```jldoctest", src)
                # Each block uses the project-standard `setup = :(using Bennett)`
                # so doctests don't need to redeclare imports.  Plain `using Test`
                # is left to the runner; only `using Bennett` is doctest-local.
                @test occursin("setup = :(using Bennett)", src)
            end
        end
    end

    @testset "no plain ```julia fence with `julia> ` content slipped back" begin
        # Scan each file for the regression pattern: a ```julia opener
        # immediately followed by `julia> ` content (not a freeform code
        # block).  Use a multi-line slice rather than a regex over the
        # whole file so a legitimate ```julia block describing CLI usage
        # (no `julia> ` prompt) doesn't trip the test.
        for fname in _WLF6_DOCTEST_FILES
            path = joinpath(dirname(pathof(Bennett)), fname)
            lines = split(read(path, String), '\n')
            for (i, line) in enumerate(lines)
                if strip(line) == "```julia" && i + 1 <= length(lines)
                    @testset "$fname line $i: ```julia not followed by julia>" begin
                        # Look ahead up to 3 lines for a `julia>` prompt.
                        body = join(lines[i+1:min(i+3, end)], "\n")
                        @test !occursin("julia> ", body)
                    end
                end
            end
        end
    end

    @testset "doctest output blocks are deterministic (smoke check)" begin
        # The four doctest values that the example blocks pin must
        # actually be produced by the canonical baseline. If this test
        # fails the docstring example is wrong — fix the docstring,
        # not the test.
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test simulate(c, Int8(5)) == 6
        @test simulate(c, Int8(-1)) == 0
        @test gate_count(c) == (total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
        @test depth(c) == 19
        @test toffoli_depth(c) == 12
        @test verify_reversibility(c)

        c2 = reversible_compile((x, y) -> x + y, Int8, Int8)
        @test simulate(c2, (Int8(3), Int8(4))) == 7

        c3 = reversible_compile(x -> (x, Int8(2) * x), Int8)
        @test simulate(c3, Int8(7)) == (7, 14)

        cc = controlled(c)
        @test simulate(cc, true,  Int8(5)) == 6
        @test simulate(cc, false, Int8(5)) == 0
    end
end
