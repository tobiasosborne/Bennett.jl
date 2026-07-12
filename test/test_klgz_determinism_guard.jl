# test_klgz_determinism_guard.jl — beads `Bennett-klgz` (front-end) /
# `bennettvm-90l` (VM mirror): the reversible determinism guard.
#
# # What this pins
#
# The 416r.13 "unrecognized Julia JIT global" reject site (instructions.jl) now
# CLASSIFIES a runtime-callee GOT-stub global (`@"jlplt_<callee>_<N>_got"`) by
# demangled callee name BEFORE the generic reject, refining the diagnostic:
#
#   (a) IDENTITY hashers (`ijl_object_id`, …) — a mutable-struct Dict key hashes
#       the object's allocation ADDRESS (default `hash` = `objectid`), which is
#       non-deterministic across replays ⇒ unreplayable ⇒ the genuine
#       in-principle blocker of the reversible floor (ADR 0015 Decision 3). The
#       reject NAMES the construct (Rule 1).
#   (b) CONTENT hashers (`memhash_seed`, the `String`/`Symbol` byte hash) — a
#       DETERMINISTIC hash, IN SCOPE for the floor; the reject is a MODELING GAP
#       (runtime-callee GOT-stub modeling is future work), NOT a correctness
#       floor — a distinct message so a future agent does not mistake it for one.
#
# # Scope rule (CRITICAL): this change ADMITS NOTHING NEW — every family still
# fails loud; only the message/cause is refined. So (c) pins that the isbits
# `fdict` set still extracts bit-identically (>= 4 bodies, no throw).
#
# The strings asserted are the guard's OWN diagnostic prose (drift-immune), NOT
# LLVM formatting / the drifting `_<N>_` GOT discriminator (CLAUDE.md Rule 5).
#
# Protocol note: this guard refinement was scoped as implementer + hostile-
# reviewer on a scout-RATIFIED design (orchestrator decision; scout report
# BennettVM.jl/scratchpad/scout-90l-determinism.md, Q5 recommendation), NOT a
# full 2-proposer core-change pass — it admits no construct and adds no lowering.
#
# Ref: src/extract/constexpr.jl (`_demangle_got_callee`,
#      `_IDENTITY_HASH_GOT_CALLEES`, `_CONTENT_HASH_GOT_CALLEES`),
#      src/extract/instructions.jl (the classifier at the 416r.13 reject site),
#      BennettVM.jl src/ir/ingest_call.jl (`_NONDETERMINISTIC_CALLEES` mirror).

using Test
import Bennett
using Bennett: extract_parsed_ir_set_from_julia, extract_parsed_ir_from_ll

# A mutable struct key ⇒ default `hash` = `objectid` (address-hashed).
mutable struct _KlgzMK
    x::Int8
end
Base.:(==)(a::_KlgzMK, b::_KlgzMK) = a.x == b.x

_klgz_fmk(m::_KlgzMK, b::Int8)  = (d = Dict{_KlgzMK,Int8}(); d[m] = b; d[m])
_klgz_fstr(a::String, b::Int8)  = (d = Dict{String,Int8}();   d[a] = b; d[a])
_klgz_fdict(a::Int8, b::Int8)   = (d = Dict{Int8,Int8}();     d[a] = b; d[a])

# Run an extraction, returning (threw::Bool, message::String).
function _klgz_try(f, T)
    try
        extract_parsed_ir_set_from_julia(f, T; ptr_cells = true)
        return (false, "")
    catch e
        return (true, sprint(showerror, e))
    end
end

@testset "Bennett-klgz — reversible determinism guard" begin

    # ---------------------------------------------------------------------
    # (a) mutable-struct key ⇒ IDENTITY-hash ⇒ determinism-floor reject.
    #     RED before the classifier (generic "UNRECOGNIZED" message);
    #     GREEN after (names the construct).
    # ---------------------------------------------------------------------
    @testset "(a) objectid-hashed key → determinism floor" begin
        threw, msg = _klgz_try(_klgz_fmk, Tuple{_KlgzMK,Int8})
        @test threw
        # The guard's own construct-naming prose (identity family).
        @test occursin("OBJECT IDENTITY", msg)
        @test occursin("objectid", msg)
        @test occursin("ijl_object_id", msg)          # the demangled callee
        @test occursin("determinism floor", msg)
        # It is NOT the generic 416r.13 message.
        @test !occursin("UNRECOGNIZED", msg)
        # It is NOT the content-hash message.
        @test !occursin("MODELING GAP", msg)
    end

    # ---------------------------------------------------------------------
    # (b) String key ⇒ CONTENT-hash ⇒ modeling-gap reject (deterministic,
    #     in-scope, not-yet-modeled) — and specifically NOT the determinism
    #     message. RED before (generic "UNRECOGNIZED"); GREEN after.
    # ---------------------------------------------------------------------
    @testset "(b) content-hashed String key → modeling gap (not determinism)" begin
        threw, msg = _klgz_try(_klgz_fstr, Tuple{String,Int8})
        @test threw
        # The guard's own content-hash prose.
        @test occursin("content hash", msg)
        @test occursin("memhash_seed", msg)            # the demangled callee
        @test occursin("MODELING GAP", msg)
        @test occursin("IN SCOPE", msg)
        # It is NOT the identity/determinism message (the "not the determinism
        # message" clause) — "OBJECT IDENTITY" is unique to the identity arm.
        @test !occursin("OBJECT IDENTITY", msg)
        # It is NOT the generic 416r.13 message.
        @test !occursin("UNRECOGNIZED", msg)
    end

    # ---------------------------------------------------------------------
    # (c) SCOPE GUARANTEE: the isbits fdict set still extracts unchanged.
    #     Nothing new is admitted, nothing previously-green regresses — the
    #     3 fdict ptrtoint are `+Type#N` type tags that never reach this site.
    # ---------------------------------------------------------------------
    @testset "(c) isbits fdict set extracts unchanged (>= 4 bodies)" begin
        local set
        @test (set = extract_parsed_ir_set_from_julia(
                   _klgz_fdict, Tuple{Int8,Int8}; ptr_cells = true)) !== nothing
        @test length(set) >= 4
    end

    # ---------------------------------------------------------------------
    # (unit) The classifier on hand-built GOT-stub IR — drift-immune, fast,
    # and directly exercises all three arms (identity / content / unknown).
    # ---------------------------------------------------------------------
    @testset "(unit) classifier on hand-built jlplt_*_got IR" begin
        function _run_ll(gname)
            ir = """
            @"$(gname)" = private unnamed_addr constant ptr null
            define i64 @wf(ptr noundef %p) {
            entry:
              %x = load ptr, ptr @"$(gname)", align 8
              ret i64 0
            }
            """
            mktempdir() do dir
                path = joinpath(dir, "wf.ll")
                write(path, ir)
                try
                    extract_parsed_ir_from_ll(path; entry_function = "wf",
                                              ptr_cells = true)
                    return (false, "")
                catch e
                    return (true, sprint(showerror, e))
                end
            end
        end

        # identity family → determinism floor
        t1, m1 = _run_ll("jlplt_ijl_object_id_5_got")
        @test t1
        @test occursin("OBJECT IDENTITY", m1)
        @test !occursin("UNRECOGNIZED", m1)

        # content family → modeling gap (not determinism)
        t2, m2 = _run_ll("jlplt_memhash_seed_7_got")
        @test t2
        @test occursin("MODELING GAP", m2)
        @test !occursin("OBJECT IDENTITY", m2)
        @test !occursin("UNRECOGNIZED", m2)

        # unknown jlplt callee → generic reject (unchanged fall-through)
        t3, m3 = _run_ll("jlplt_some_other_runtime_fn_9_got")
        @test t3
        @test occursin("UNRECOGNIZED", m3)
        @test !occursin("OBJECT IDENTITY", m3)
        @test !occursin("MODELING GAP", m3)

        # not a GOT stub at all → generic reject (unchanged)
        t4, m4 = _run_ll("weird_global#5")
        @test t4
        @test occursin("UNRECOGNIZED", m4)
    end
end
