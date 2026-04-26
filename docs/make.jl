# Bennett-doh6 / U158: Documenter.jl wiring. Builds the curated pages
# (index/tutorial/api/architecture) plus a `reference.md` that pulls in
# the public-API docstrings via @docs blocks so the ```jldoctest fences
# from Bennett-wlf6 / U145 execute as part of the build. Local-only —
# no deploydocs, no GitHub CI per CLAUDE.md §14.
#
# Build:
#   julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#   julia --project=docs docs/make.jl
#
# A doctest drift fails the build with the diff between expected and
# actual output, providing the same regression surface a CI doctest job
# would — at the cost of running it manually.

using Documenter
using Bennett

DocMeta.setdocmeta!(Bennett, :DocTestSetup, :(using Bennett); recursive=true)

makedocs(
    sitename = "Bennett.jl",
    modules = [Bennett],
    authors = "Tobias Osborne",
    pages = [
        "Home" => "index.md",
        "Tutorial" => "tutorial.md",
        "API Reference" => "api.md",
        "Reference (autogen)" => "reference.md",
        "Architecture" => "architecture.md",
    ],
    doctest = true,
    checkdocs = :none,
    warnonly = [:missing_docs, :cross_references, :docs_block],
    format = Documenter.HTML(prettyurls = false),
)
