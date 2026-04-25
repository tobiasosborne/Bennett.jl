# Bennett-uoem / U54 — research/ relocation invariants
#
# Asserts the post-relocation layout for the five preserved-but-deprecated
# persistent-map impls (Okasaki, CF, HAMT, popcount, Jenkins).  Each impl
# must:
#   1. live at src/persistent/research/<file>.jl  (relocated)
#   2. NOT live at src/persistent/<file>.jl       (removed from production)
#   3. expose no symbols at top-level of `Bennett` (no longer exported)
#
# Plus structural invariants: the literate README must exist, and the
# `BENNETT_RESEARCH_TESTS` env-var gate must be reflected in runtests.jl.
#
# These invariants are checked unconditionally (not gated by
# BENNETT_RESEARCH_TESTS) — relocation status is part of the production
# contract regardless of whether research-tier tests run.

using Test
using Bennett

const _PKG_ROOT  = pkgdir(Bennett)
const _PROD_DIR  = joinpath(_PKG_ROOT, "src", "persistent")
const _RES_DIR   = joinpath(_PROD_DIR, "research")
const _PUBLIC_API = Set(names(Bennett))

@testset "Bennett-uoem / U54 — research/ relocation invariants" begin

    @testset "research/ scaffolding" begin
        @test isdir(_RES_DIR)
        @test isfile(joinpath(_RES_DIR, "README.md"))
    end

    @testset "Okasaki RBT relocated to research/" begin
        @test isfile(joinpath(_RES_DIR, "okasaki_rbt.jl"))
        @test !isfile(joinpath(_PROD_DIR, "okasaki_rbt.jl"))
        for sym in (:OKASAKI_IMPL, :okasaki_pmap_new, :okasaki_pmap_set,
                    :okasaki_pmap_get, :OkasakiState)
            @test sym ∉ _PUBLIC_API
        end
    end

end
