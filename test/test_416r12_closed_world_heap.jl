# Bennett CW-D2 / bennettvm-416r.12 — close the fdict closed-world set.
#
# This bead makes `extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
# ptr_cells=true, on_extract_error=:fail_loud)` return a FULLY CLOSED 4-body set
# (`fdict_d1b`, `setindex!`, `rehash!`, `ht_keyindex2_shorthash!`).
#
# Two changes make it close:
#   (1) src/extract/julia_set.jl — a 4th closed-world classifier bucket
#       `_D1B_MODELED_HEAP_INTRINSICS` (exact-name match, mirrors BennettVM's
#       `_HEAP_DISPATCH`) tolerating the modeled heap/runtime intrinsics
#       (`gc_alloc_obj`, `jl_alloc_genericmemory_unchecked`, `memset`, ...) that
#       BennettVM ingest lowers to an `Intrinsic*`. An UNKNOWN runtime callee
#       still fails loud (Rule 1).
#   (2) src/extract/instructions.jl — `julia.write_barrier` is GC card-marking
#       with NO VM value semantics; it is DROPPED at extraction (like
#       gc_preserve / safepoint), so it never surfaces as an IRCall BVM has no
#       home for.
#
# Before CW-D2 the set walled at `_closed_world_check!` on the `gc_alloc_obj`
# Symbol callee (a real heap intrinsic that `transitive_callees` defers). This
# file pins the CLOSED set + the classifier's fail-loud floor for a genuinely
# unknown Symbol callee (Rule 4: invariants, not "didn't throw").
#
# CRITICAL (Rule 5): assert BARE names (`rsplit(key, "#"; limit=2)[1]`), NEVER
# the full digest keys — digests are hash(::DataType)-based and vary across
# processes.

using Test
using Bennett: extract_parsed_ir_set_from_julia, _closed_world_check!,
               _D1B_MODELED_HEAP_INTRINSICS,
               ParsedIR, IRBasicBlock, IRCall, IRRet, ssa
import Bennett

# --- Fixture (identical to test_d1b_julia_set.jl's closed-world target) ------
# Dict-touching root: its call graph is fdict_d1b → setindex! →
# ht_keyindex2_shorthash! → rehash!, plus the modeled heap/runtime intrinsics
# (gc_alloc_obj, jl_alloc_genericmemory_unchecked, memset) and the dropped
# julia.write_barrier / julia.gc_loaded meta-ops.
fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

# bare name of a canonical set key (`<barename>#<digest>`), rsplit on the LAST
# `#` (S1 — a gensym barename can itself contain `#`).
_bare416(k) = Symbol(rsplit(String(k), "#"; limit=2)[1])
_calls416(pir) = [ins for b in pir.blocks for ins in b.instructions if ins isa IRCall]

@testset "Bennett-CW-D2 / 416r.12: closed-world heap-intrinsic classifier" begin

    # ========================================================================
    # GATE 1 — the fdict set now CLOSES: 4 bodies, exact BARE-name set.
    # (RED before CW-D2: closed-world violation on the `gc_alloc_obj` callee.)
    # ========================================================================
    @testset "GATE 1 — fdict_d1b set closes to 4 under :fail_loud + ptr_cells" begin
        s = extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                             ptr_cells=true, on_extract_error=:fail_loud)
        @test s isa Vector{Pair{Symbol,ParsedIR}}
        @test length(s) == 4
        # BARE names only (digests drift across processes — Rule 5).
        bares = Set(_bare416(k) for (k, _) in s)
        @test bares == Set([:fdict_d1b, :setindex!, Symbol("rehash!"),
                            Symbol("ht_keyindex2_shorthash!")])
        # root is entry-first (prepended).
        @test _bare416(first(s[1])) === :fdict_d1b
    end

    # ========================================================================
    # GATE 2 — julia.write_barrier is DROPPED at extraction; the modeled
    # `jl_alloc_genericmemory_unchecked` / `memset` IRCalls SURVIVE (proving
    # the classifier tolerates, not the drop swallowing everything).
    # ========================================================================
    @testset "GATE 2 — write_barrier dropped; modeled-heap IRCalls survive in rehash!" begin
        s = extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                             ptr_cells=true, on_extract_error=:fail_loud)
        # rehash! is the body carrying the Memory-backing allocs (+ their memsets).
        idx = findfirst(p -> _bare416(first(p)) === Symbol("rehash!"), s)
        @test idx !== nothing
        rehash_pir = last(s[idx])
        callees = [c.callee for c in _calls416(rehash_pir)]

        # write_barrier NEVER surfaces as an IRCall (dropped at extraction).
        @test !any(c -> c === Symbol("julia.write_barrier"), callees)
        # ...and it is not swallowing the real work: the modeled heap intrinsics
        # DO survive as Symbol-callee IRCalls the closed-world check tolerates.
        @test any(c -> c === :jl_alloc_genericmemory_unchecked, callees)
        @test any(c -> c === :memset, callees)
    end

    # ========================================================================
    # GATE 3 — classifier fail-loud floor: a genuinely-unknown Symbol callee
    # STILL fails loud (the modeled set is EXACT-name, not a blanket pass).
    # ========================================================================
    @testset "GATE 3 — over-open guard: unknown Symbol callee still fails loud" begin
        # Hand-build a 1-block ParsedIR set with one Symbol IRCall.
        function _build_set(callee_sym::Symbol)
            call = IRCall(:r, callee_sym, [ssa(:x)], [8], 8)
            ret  = IRRet(ssa(:r), 8)
            blk  = IRBasicBlock(:entry, Bennett.IRInst[call], ret)
            pir  = ParsedIR(8, [(:x, 8)], [blk], [8])
            return Pair{Symbol,ParsedIR}[:myroot => pir]
        end
        bare_to_key      = Dict{Symbol,Vector{Symbol}}(:myroot => [:myroot])
        throw_leaf_names = Set{Symbol}([:AssertionError])

        # Negative: a runtime callee NOT in the modeled set → fail loud.
        @test_throws "closed-world violation" _closed_world_check!(
            _build_set(:jl_definitely_bogus_runtime_fn), bare_to_key, throw_leaf_names)
        # And the message names the offender.
        err = try
            _closed_world_check!(_build_set(:jl_definitely_bogus_runtime_fn),
                                 bare_to_key, throw_leaf_names)
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("jl_definitely_bogus_runtime_fn", err)

        # Positive: a MODELED heap intrinsic resolves WITHOUT error (the new
        # bucket). Covers both the bare gc_alloc_obj/memset and the allocator.
        @test _closed_world_check!(_build_set(:gc_alloc_obj),
                                   bare_to_key, throw_leaf_names) === nothing
        @test _closed_world_check!(_build_set(:jl_alloc_genericmemory_unchecked),
                                   bare_to_key, throw_leaf_names) === nothing
        @test _closed_world_check!(_build_set(:memset),
                                   bare_to_key, throw_leaf_names) === nothing
    end

    # ========================================================================
    # GATE 4 — the modeled set is the exact mirror the coupling test pins.
    # (The machine-checked BVM-side equality lives in BennettVM's test; here we
    # just pin the membership this repo's classifier depends on.)
    # ========================================================================
    @testset "GATE 4 — _D1B_MODELED_HEAP_INTRINSICS membership" begin
        @test _D1B_MODELED_HEAP_INTRINSICS isa Set{Symbol}
        for k in (:malloc, :calloc, :realloc, :free, :memset, :memcpy, :memmove,
                  :gc_alloc_obj, :jl_alloc_genericmemory_unchecked)
            @test k in _D1B_MODELED_HEAP_INTRINSICS
        end
        # not a blanket pass — an unknown runtime name is absent.
        @test !(:jl_definitely_bogus_runtime_fn in _D1B_MODELED_HEAP_INTRINSICS)
    end

end
