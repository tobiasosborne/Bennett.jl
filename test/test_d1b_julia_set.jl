# Bennett CW-D1b / bennettvm-416r.11 chunk b — extract_parsed_ir_set_from_julia
# closed-world Julia multi-IR producer (src/extract/julia_set.jl). The closed-
# world path to SC9 Case B (ADR-0017, SETTLED).
#
# The producer walks transitive_callees(f, argtypes), extracts the root + every
# reached helper body, keys them by drift-free canonical Symbols
# (<barename>#<argtype-digest>), and fails loud (Rule 1) on any IRCall that
# escapes the closed world (not in-set, not a throw-leaf, not benign).
#
# Gate map:
#   A — synthetic root whose callees DO extract at O0 → Vector{Pair{Symbol,ParsedIR}},
#       length >= 3, root first, all values ParsedIR.  (PROBE-VERIFIED: root_d1b's
#       O0 body emits surviving Function-callee IRCalls to h_d1b/g_d1b.)
#   B — canonical key contains the bare name + a digest, invariant across calls,
#       distinct across argtypes, no mangled _NNN tail.
#   C — _is_throw_leaf classifies Type{<:Exception} vs typeof(g); throw-leaf
#       dropped from a set (not extracted, not an error).
#   D — closed-world violation fails loud naming the symbol; :ijl_throw resolves.
#   E — fdict_d1b HONEST tripwire: :fail_loud throws (U81/U14/sret wall),
#       :skip's >=4 is @test_broken (BLOCKED on CW-D2).
#   F — under :skip, non-root key bare-names == transitive_callees bare names
#       minus throw leaves (run on the extractable synthetic fixture).

using Test
using Bennett: extract_parsed_ir_set_from_julia, _canonical_callee_key,
               _is_throw_leaf, _closed_world_check!, transitive_callees,
               ParsedIR, IRBasicBlock, IRCall, IRRet, ssa
import Bennett

# --- Fixtures ---------------------------------------------------------------
# Synthetic root whose callees extract cleanly at O0 (PROBE-VERIFIED: the @noinline
# barrier keeps g/h as resolvable inter-callee :invoke edges, and their bodies are
# pure bit-ops + add — no Dict/heap walls). Uniquely named (`*_d1b`, not the shared
# `fdict`) to dodge the cross-file generic-collision lesson from D1a.
@noinline g_d1b(x::Int8) = x ⊻ Int8(7)
@noinline h_d1b(x::Int8) = g_d1b(x) + Int8(1)
root_d1b(x::Int8) = h_d1b(x) + g_d1b(x)

# Dict-touching fixture — the closed-world target. Its callee bodies (setindex! →
# ht_keyindex2_shorthash! → rehash!) hit the U81 ptr-width / U14 atomic-load /
# dv1z heterogeneous-sret walls; this is the accepted closed-world runway, NOT a
# D1b bug. Uniquely named `fdict_d1b`.
fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

@testset "Bennett-CW-D1b extract_parsed_ir_set_from_julia" begin

    # ========================================================================
    # GATE A — synthetic root + extractable callees → entry-first Pair vector.
    # ========================================================================
    @testset "GATE A — synthetic set: shape, length>=3, root-first" begin
        res = extract_parsed_ir_set_from_julia(root_d1b, Tuple{Int8})
        @test res isa Vector{Pair{Symbol,ParsedIR}}
        @test length(res) >= 3                      # root + h_d1b + g_d1b
        @test all(v -> v isa ParsedIR, last.(res))  # every value is a ParsedIR
        # root is FIRST (entry-first ordering — prepended).
        @test occursin("root_d1b", String(first(res[1])))
        # every non-root key is a reached callee bare name.
        nonroot = Set(Symbol(split(String(first(p)), "#")[1]) for p in res[2:end])
        @test :g_d1b in nonroot
        @test :h_d1b in nonroot
    end

    # ========================================================================
    # GATE B — canonical key: bare name + digest, invariant, distinct, no _NNN.
    # ========================================================================
    @testset "GATE B — canonical_callee_key invariants" begin
        at1 = Tuple{Dict{Int8,Int8},Int8,Int8}
        k1 = _canonical_callee_key(typeof(setindex!), at1)
        k2 = _canonical_callee_key(typeof(setindex!), at1)
        @test k1 isa Symbol
        @test occursin("setindex!", String(k1))      # contains the bare name
        @test occursin("#", String(k1))              # contains the digest separator
        @test k1 == k2                                # invariant across two calls
        # distinct argtypes → distinct key.
        k3 = _canonical_callee_key(typeof(setindex!), Tuple{Dict{Int16,Int16},Int16,Int16})
        @test k1 != k3
        # NO mangled _NNN tail (the Rule-5 drift this design avoids).
        @test match(r"_\d+$", String(k1)) === nothing
        @test match(r"_\d+$", String(k3)) === nothing
    end

    # ========================================================================
    # GATE C — throw-leaf classification + drop-before-extraction.
    # ========================================================================
    @testset "GATE C — is_throw_leaf + throw-leaf dropped (not extracted)" begin
        @test _is_throw_leaf(Type{AssertionError})
        @test _is_throw_leaf(Type{BoundsError})
        @test !_is_throw_leaf(typeof(setindex!))
        @test !_is_throw_leaf(Type{Int8})   # Int8 is not <: Exception

        # fdict_d1b reaches Type{AssertionError}; under :skip the AssertionError
        # body is NEVER extracted (it would hit the ptr-width wall) and is NOT an
        # error — its bare name is recorded for the closed-world check instead.
        # Assert no emitted key bears the AssertionError bare name.
        res = extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                               on_extract_error=:skip)
        @test !any(p -> startswith(String(first(p)), "AssertionError#"), res)
    end

    # ========================================================================
    # GATE D — closed-world violation fails loud; benign/throw-leaf resolve.
    # ========================================================================
    @testset "GATE D — closed-world check: fail-loud on stranger, accept benign" begin
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

        # Negative: a Symbol callee that is neither in-set, throw-leaf, nor benign.
        @test_throws "closed-world violation" _closed_world_check!(
            _build_set(:totally_unknown_fn), bare_to_key, throw_leaf_names)
        # The message must NAME the offending symbol.
        err = try
            _closed_world_check!(_build_set(:totally_unknown_fn), bare_to_key, throw_leaf_names)
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("totally_unknown_fn", err)

        # Positive: a Symbol IRCall to :ijl_throw resolves WITHOUT error (benign).
        @test _closed_world_check!(_build_set(:ijl_throw), bare_to_key, throw_leaf_names) === nothing
        # Positive: a Symbol IRCall to the throw-leaf :AssertionError resolves.
        @test _closed_world_check!(_build_set(:AssertionError), bare_to_key, throw_leaf_names) === nothing
    end

    # ========================================================================
    # GATE E — fdict_d1b HONEST tripwire (NOT faked green).
    # ========================================================================
    @testset "GATE E — fdict_d1b: :fail_loud throws; dead-block walls cleared (utzc); :skip>=4 broken" begin
        # :fail_loud (default, cells=FALSE) MUST throw — a reached Dict-helper body
        # hits a real extractor wall. Capture & inspect rather than matching the
        # wrapper's hardcoded hint text (S3): assert (a) the :fail_loud wrapper
        # fired on an EXTRACTION failure, and (b) the WRAPPED underlying error is a
        # genuine LLVM extractor wall — NOT a D1b logic bug. This invocation uses
        # the default cells=FALSE gate, which Bennett-utzc leaves BYTE-IDENTICAL
        # (the dead-block pruner is ptr_cells-gated), so setindex! still surfaces
        # FIRST on the ptr-RETURN "unsupported LLVM type ... PointerType" wall.
        err = try
            extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8})
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing                          # MUST throw
        @test occursin("extraction FAILED", err)       # via the :fail_loud wrapper
        # A real extractor wall, not a D1b bug. Order-dependent (Rule 5); accept
        # any plausible cells-OFF wall. "closed-world violation" retained for the
        # future frontier where the ptr-return/void/atomic walls all clear.
        @test occursin("unsupported LLVM type", err) || occursin("sret", err) ||
              occursin("atomic", err) || occursin("VoidType", err) ||
              occursin("U81", err) || occursin("closed-world violation", err)

        # utzc RESOLUTION (cells=TRUE): the dead-block extraction walls that this
        # gate historically pinned are GONE. Before Bennett-utzc, the ptr_cells=true
        # set walled INSIDE a provably-dead unreachable throw block — the `rehash!`
        # `[1 x ptr] @j_AssertionError` ArrayType-return call (default mode) and the
        # `setindex!` U114 `store { ptr, ptr }` box-store (suite mode). utzc prunes
        # those dead blocks, so the wall ADVANCES to the CW-D2 frontier
        # (bennettvm-416r.12): :skip walls on the `gc_alloc_obj` Symbol callee (not
        # yet in the closed-world whitelist), proving the rehash!/setindex! bodies
        # now extract PAST their dead blocks. Assert the specific thing this gate
        # was pinning — the dead-block wall — is resolved. (Live-probe-verified
        # 2026-07-07, BOTH check-bounds modes.)
        skmsg = try
            extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                             ptr_cells=true, on_extract_error=:skip)
            ""   # (future) fully closed — no closed-world violation
        catch e
            sprint(showerror, e)
        end
        @test !occursin("j_AssertionError", skmsg)     # AssertionError dead block pruned
        @test !occursin("[1 x ptr", skmsg)             # its [1 x ptr] return-type wall gone
        @test skmsg == "" || occursin("gc_alloc_obj", skmsg) ||
              occursin("closed-world violation", skmsg)   # advanced to CW-D2 frontier

        # >=4 is BLOCKED on CW-D2, NOT on D1b — and NOT on the dead-block walls
        # utzc just cleared. The :skip path (cells=FALSE here, byte-identical under
        # utzc) tolerates every wall and returns whatever bodies extract today
        # (currently 0). Beyond the utzc-pruned dead blocks the remaining CW-D2
        # frontier is `llvm.smul.with.overflow.i64` (struct `{i64,i1}` return in a
        # LIVE rehash! block) + the `gc_alloc_obj` closed-world whitelist gap
        # (bennettvm-416r.12). HONEST tripwire: when that frontier lands this flips
        # to a real pass and the @test_broken starts failing-as-unexpected-pass,
        # prompting promotion to @test. (cells=FALSE; utzc left the default
        # byte-identical so this stays broken.)
        @test_broken length(extract_parsed_ir_set_from_julia(
            fdict_d1b, Tuple{Int8,Int8}; on_extract_error=:skip)) >= 4
    end

    # ========================================================================
    # GATE F — :skip non-root key bare-names == callee bare-names minus throws.
    # ========================================================================
    @testset "GATE F — :skip set keys match transitive_callees (minus throws)" begin
        # Run on the EXTRACTABLE synthetic fixture: this invariant is only
        # meaningful when bodies actually extract (fdict's bodies all hit walls,
        # so its :skip set is empty by Gate E — covered there). root_d1b's
        # callees extract cleanly, so the equality is exact.
        res = extract_parsed_ir_set_from_julia(root_d1b, Tuple{Int8};
                                               on_extract_error=:skip)
        nonroot_bares = Set(Symbol(split(String(first(p)), "#")[1]) for p in res[2:end])
        callee_bares = Set{Symbol}()
        for (k, _at) in transitive_callees(root_d1b, Tuple{Int8})
            _is_throw_leaf(k) && continue
            push!(callee_bares, k isa Type{<:Type} ? nameof(k.parameters[1]) : nameof(k.instance))
        end
        @test nonroot_bares == callee_bares
    end

    # ========================================================================
    # GATE G — no global registry pollution: the producer is side-effect-free.
    # ========================================================================
    @testset "GATE G — _known_callees restored after each call (Rule 7)" begin
        # The producer registers live callees internally to clear the U15 guard,
        # but MUST restore _known_callees afterward — else a later same-process
        # compile (e.g. test_bd5f_heap_m4's Dict-rejection tests) sees setindex!
        # spuriously registered. Snapshot, call (incl. the fdict :skip path that
        # registers setindex!/rehash!), and assert the registry is unchanged.
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        extract_parsed_ir_set_from_julia(root_d1b, Tuple{Int8})
        extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8}; on_extract_error=:skip)
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before                 # registry fully restored — no leak
        @test !haskey(after, "g_d1b")          # g_d1b is unique to this file → proves restore
        @test !haskey(after, "setindex!") || haskey(before, "setindex!")  # no spurious setindex!
    end

end
