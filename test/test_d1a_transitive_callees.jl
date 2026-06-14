# Bennett CW-D1a / bennettvm-416r.11 chunk a — transitive_callees typed
# call-graph walker (the path to SC9 Case B: reversible Dict).
#
# The walker (src/extract/callgraph.jl) starts from a root `(f, argtypes)`, asks
# Julia inference for the optimized typed code of every reached method, harvests
# the `:invoke` targets, and transitively closes the callee set — root EXCLUDED,
# edges harvested at `optimize=true` (ADR-0021 Decision-1, as corrected: the
# O0-vs-O2 split was probe-verified — O0 emits ZERO `:invoke`s; only the
# optimized body has the resolved edges. Callee BODY extraction at O0 is D1b.)
#
# Gates 1–6:
#   1. fdict_d1a reaches exactly the 4-callee set; length(transitive_callees)==4
#   2. no duplicates; self-recursive ht_keyindex2_shorthash! deduped to once
#   3. call-local state: twice == equal; rehash! sub-walk unpolluted
#   4. AssertionError bottoms out (empty)
#   5. O0-regression tripwire: fdict_d1a callees non-empty
#   6. mi_of canary: Core.CodeInstance `.def` field, idempotence, version split

using Test
using Bennett: transitive_callees, _transitive_callee_specTypes, mi_of

# Fixture: a tiny Dict-touching function. setindex! is the inlining root that
# pulls in ht_keyindex2_shorthash! (self-recursive) + rehash! + AssertionError.
# Uniquely named (`fdict_d1a`, not `fdict`) to avoid extending a shared-module
# generic also defined in test_bd5f_heap_m4.jl — runtests.jl includes every test
# file into one module, so a bare `fdict` would couple the two files' dispatch.
fdict_d1a(a, b) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

const _SI    = Tuple{typeof(setindex!), Dict{Int8,Int8}, Int8, Int8}
const _HTKI  = Tuple{typeof(Base.ht_keyindex2_shorthash!), Dict{Int8,Int8}, Int8}
const _REH   = Tuple{typeof(Base.rehash!), Dict{Int8,Int8}, Int64}
const _ASSERT = Tuple{Type{AssertionError}, String}

@testset "Bennett-CW-D1a transitive_callees typed call-graph walker" begin

    # ============================================================
    # GATE 1 — fdict_d1a reaches exactly the expected 4-callee set.
    # ============================================================
    @testset "GATE 1 — exact reached specTypes set + length 4" begin
        got = _transitive_callee_specTypes(fdict_d1a, Tuple{Int8,Int8})
        @test got == Set{DataType}([_SI, _HTKI, _REH, _ASSERT])
        @test length(transitive_callees(fdict_d1a, Tuple{Int8,Int8})) == 4
    end

    # ============================================================
    # GATE 2 — no duplicates; self-recursion deduped to exactly once.
    # ============================================================
    @testset "GATE 2 — dedup; ht_keyindex2_shorthash! present once" begin
        vec = transitive_callees(fdict_d1a, Tuple{Int8,Int8})
        # The returned vector is (callee_key, argtypes) pairs; no duplicate pair.
        @test length(vec) == length(Set(vec))
        # ht_keyindex2_shorthash! is self-recursive at the :invoke level; it must
        # be PRESENT in the reached set (a Set can't prove dedup — the genuine
        # dedup proof is its single appearance in the dup-capable vector below).
        spec = _transitive_callee_specTypes(fdict_d1a, Tuple{Int8,Int8})
        @test _HTKI in spec
        kt = (typeof(Base.ht_keyindex2_shorthash!), Tuple{Dict{Int8,Int8},Int8})
        @test count(==(kt), vec) == 1
    end

    # ============================================================
    # GATE 3 — call-local state: twice == equal; rehash! sub-walk unpolluted.
    # ============================================================
    @testset "GATE 3 — call-local state + rehash! sub-walk" begin
        a = _transitive_callee_specTypes(fdict_d1a, Tuple{Int8,Int8})
        b = _transitive_callee_specTypes(fdict_d1a, Tuple{Int8,Int8})
        @test a == b   # no module-level state leaking between calls
        # rehash! is NOT self-recursive at :invoke level; its only edge is the
        # AssertionError constructor. A polluted shared cache would leak the
        # fdict_d1a-walk nodes (setindex!/ht_keyindex2) into here.
        @test _transitive_callee_specTypes(Base.rehash!, Tuple{Dict{Int8,Int8},Int64}) ==
              Set{DataType}([_ASSERT])
    end

    # ============================================================
    # GATE 4 — AssertionError bottoms out (no further edges).
    # ============================================================
    @testset "GATE 4 — AssertionError constructor bottoms out" begin
        @test isempty(transitive_callees(AssertionError, Tuple{String}))
    end

    # ============================================================
    # GATE 5 — O0-regression tripwire: fdict_d1a callees are non-empty.
    # ============================================================
    @testset "GATE 5 — fdict_d1a callees non-empty (O0-regression tripwire)" begin
        # If a future change accidentally harvests edges at optimize=false the
        # walk would return an EMPTY set (O0 has zero :invoke). This is the
        # canary for that regression.
        @test !isempty(transitive_callees(fdict_d1a, Tuple{Int8,Int8}))
    end

    # ============================================================
    # GATE 6 — mi_of canary: Core.CodeInstance internals contract.
    # ============================================================
    @testset "GATE 6 — mi_of canary on a real :invoke arg1" begin
        # Harvest a real :invoke arg-1 from the optimized typed fdict_d1a.
        cinfos = Base.code_typed_by_type(Tuple{typeof(fdict_d1a),Int8,Int8}; optimize=true)
        arg1 = nothing
        for (ci, _rt) in cinfos
            for stmt in ci.code
                if stmt isa Expr && stmt.head === :invoke
                    arg1 = stmt.args[1]
                    break
                end
            end
            arg1 !== nothing && break
        end
        @test arg1 !== nothing                                   # IR sanity
        @test fieldnames(Core.CodeInstance)[1] === :def          # mi_of(::CodeInstance) contract
        @test mi_of(arg1) isa Core.MethodInstance
        @test mi_of(arg1).specTypes isa DataType
        @test mi_of(mi_of(arg1)) === mi_of(arg1)                 # idempotence (MethodInstance fixpoint)
        if VERSION >= v"1.11"
            @test arg1 isa Core.CodeInstance
        end
    end
end
