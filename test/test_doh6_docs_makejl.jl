# Bennett-doh6 / U158 — docs/make.jl was missing, blocking Documenter.jl
# build + executable jldoctest fences (Bennett-wlf6 / U145). Static-
# inspection regression: scaffold files exist, declare the canonical
# pages + doctest=true + the doctested functions. The actual doctest
# execution lives in `julia --project=docs docs/make.jl` per CLAUDE.md
# §14 (no GitHub CI).

using Test

const _DOH6_DOCS_DIR = abspath(joinpath(@__DIR__, "..", "docs"))

@testset "Bennett-doh6 / U158 — docs/make.jl scaffold" begin

    @testset "scaffold files exist" begin
        @test isfile(joinpath(_DOH6_DOCS_DIR, "make.jl"))
        @test isfile(joinpath(_DOH6_DOCS_DIR, "Project.toml"))
        @test isfile(joinpath(_DOH6_DOCS_DIR, "src", "index.md"))
        @test isfile(joinpath(_DOH6_DOCS_DIR, "src", "reference.md"))
    end

    @testset "make.jl pins the doctest invariants" begin
        src = read(joinpath(_DOH6_DOCS_DIR, "make.jl"), String)
        @test occursin("doctest = true", src) || occursin("doctest=true", src)
        @test occursin("modules = [Bennett]", src) || occursin("modules=[Bennett]", src)
        # DocTestSetup wires `using Bennett` for every doctest in the module.
        @test occursin("DocTestSetup", src)
        # CLAUDE.md §14: no remote deploys. Match the call shape so the
        # narrative "no deploydocs" mention in the header comment doesn't
        # trip the test.
        @test !occursin("deploydocs(", src)
    end

    @testset "reference.md pulls in the wlf6-doctested functions" begin
        src = read(joinpath(_DOH6_DOCS_DIR, "src", "reference.md"), String)
        @test occursin("```@docs", src)
        # Each of the four src/*.jl files with wlf6 jldoctest fences
        # must surface here so Documenter executes their doctests.
        for sym in ("reversible_compile", "simulate", "gate_count", "controlled")
            @test occursin(sym, src)
        end
    end

    @testset "Project.toml declares Documenter" begin
        src = read(joinpath(_DOH6_DOCS_DIR, "Project.toml"), String)
        @test occursin("Documenter", src)
    end
end
