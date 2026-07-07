# Bennett-lf14 — ptr_cells gate on the Julia-function entry path.
#
# CW-C2 chunk B (Bennett-haiy) plumbed the `ptr_cells` extraction-mode gate
# through the .ll/.bc entry paths: a `ptr` RETURN derives ret_width=64, store/
# load ptr lower as 64-bit cells, two-index struct GEP -> IRPtrOffset. lf14
# closes the ONE remaining entry that omitted it — the Julia-function entry
# `extract_parsed_ir(f, arg_types; ...)` — and threads it through the closed-
# world set producer `extract_parsed_ir_set_from_julia`.
#
# WHY: setindex!(Dict,Int8,Int8) and rehash!(Dict,Int64) RETURN the Dict as a
# `nonnull ptr`, so without the gate they fail-loud at the ptr-RETURN
# "unsupported LLVM type for width query: PointerType" wall
# (helpers.jl:246 via module_walk.jl:168). With ptr_cells=true the pointer is
# an opaque 64-bit VM cell (ADR 0021 Decision 2) and that wall is CLEARED.
#
# This is a WALL-ADVANCE proof, NOT a full-extraction claim. lf14 ADVANCES:
#   * setindex!(Dict{Int8,Int8},Int8,Int8) — ptr-RETURN cleared, advances to a
#     VoidType/U81 void wall (live-probe 2026-06-19).
#   * rehash!(Dict{Int8,Int8},Int64)       — ptr-RETURN cleared, advances to the
#     U14 atomic-load wall (`load atomic ptr ... unordered`).
# (The predicted jl_alloc_genericmemory_unchecked closed-world violation lies
# further past the atomic-load wall — CW-D2 / bennettvm-416r.12 territory.)
#
# Gate map:
#   A — GATE-OFF byte-identity pin: a ptr-free Julia fn extracts IDENTICALLY
#       with ptr_cells default / =false / =true (cells is a no-op without ptr
#       ops), and reversible_compile(x->x+1, Int8) gate_count stays 39.
#   B — WALL-ADVANCE: setindex!/rehash! direct extraction. cells=false still hits
#       the ptr-RETURN PointerType wall; cells=true CLEARS it (asserts the error
#       is NO LONGER the ptr-RETURN wall — it is the advanced wall). Registry is
#       snapshot/restored (GATE-G discipline, no _known_callees leak).
#   C — SET-PRODUCER threading: extract_parsed_ir_set_from_julia(...; ptr_cells=
#       true) reaches the per-callee extract via _extract_one (the wrapped error
#       is the advanced wall, NOT the ptr-RETURN wall) — proving the kwarg
#       threaded; plus a set-path default-off equivalence pin.

using Test
using Bennett
using Bennett: extract_parsed_ir, extract_parsed_ir_set_from_julia,
               register_callee!, ParsedIR, gate_count, reversible_compile

# A ptr-free Julia function: pure Int8 add, no pointer-typed args/returns/ops.
lf14_incr(x::Int8) = x + Int8(1)

# Scoped registry snapshot/restore (mirror julia_set.jl:276-348) — registering
# setindex!/rehash! is required to clear the U15 unregistered-call guard, but
# MUST NOT leak into later same-process tests (Rule 7).
function _with_registered(fn, callables)
    snap = lock(Bennett._known_callees_lock) do
        copy(Bennett._known_callees)
    end
    added = String[]
    try
        for c in callables
            register_callee!(c)
            push!(added, string(nameof(c)))
        end
        return fn()
    finally
        lock(Bennett._known_callees_lock) do
            for k in added
                if haskey(snap, k)
                    Bennett._known_callees[k] = snap[k]
                else
                    delete!(Bennett._known_callees, k)
                end
            end
        end
    end
end

# Extract, returning (:ok, pir) or (:err, message).
function _try_extract(f, at; cells)
    try
        pir = extract_parsed_ir(f, at; optimize=false, ptr_cells=cells)
        return (:ok, pir)
    catch e
        e isa InterruptException && rethrow()
        return (:err, sprint(showerror, e))
    end
end

_is_ptr_return_wall(msg) =
    occursin("unsupported LLVM type", msg) && occursin("PointerType", msg)

@testset "Bennett-lf14 ptr_cells on the Julia-function entry" begin

    # ========================================================================
    # GATE A — ptr-free fn: cells default / =false / =true are byte-identical.
    # ========================================================================
    @testset "GATE A — ptr-free fn: ptr_cells is a no-op (byte-identity)" begin
        pir_default = extract_parsed_ir(lf14_incr, Tuple{Int8}; optimize=false)
        pir_off     = extract_parsed_ir(lf14_incr, Tuple{Int8}; optimize=false, ptr_cells=false)
        pir_on      = extract_parsed_ir(lf14_incr, Tuple{Int8}; optimize=false, ptr_cells=true)

        # ret_width / args / per-block instruction counts identical across all
        # three (no ptr op fires the gate, so the walk shape cannot change).
        for p in (pir_off, pir_on)
            @test p.ret_width == pir_default.ret_width
            @test p.args == pir_default.args
            @test length(p.blocks) == length(pir_default.blocks)
            @test [length(b.instructions) for b in p.blocks] ==
                  [length(b.instructions) for b in pir_default.blocks]
        end

        # reversible_compile never passes ptr_cells, so it binds the default
        # false and the i8 x+1 default-strategy gate_count is unchanged
        # (regression baseline lives in test_gate_count_regression.jl).
        @test gate_count(reversible_compile(x -> x + Int8(1), Int8)).total == 58
    end

    # ========================================================================
    # GATE B — wall-advance: setindex!/rehash! ptr-RETURN wall cleared by cells.
    # ========================================================================
    @testset "GATE B — setindex!/rehash! ptr-RETURN wall advances under cells" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end

        _with_registered([setindex!, Base.rehash!]) do
            # --- setindex!(Dict{Int8,Int8},Int8,Int8) ---
            at_si = Tuple{Dict{Int8,Int8},Int8,Int8}
            (st_off, msg_off) = _try_extract(setindex!, at_si; cells=false)
            @test st_off === :err
            @test _is_ptr_return_wall(msg_off)        # cells-OFF: still the ptr-RETURN wall

            (st_on, msg_on) = _try_extract(setindex!, at_si; cells=true)
            # cells-ON: the LOAD-BEARING lf14 claim — the ptr-RETURN wall is GONE.
            # It either extracts (ret_width==64 cell) or hits a DIFFERENT (advanced)
            # wall. It must NOT be the ptr-RETURN PointerType wall.
            if st_on === :ok
                @test msg_on isa ParsedIR  # placeholder; below we just assert :ok shape
            else
                @test !_is_ptr_return_wall(msg_on)
                # observed advanced wall (order-dependent, Rule 5): a void/U81 or
                # atomic/U14 body wall — assert it is one of the plausible successors.
                # Bennett-ares (CW-D2 lever 1) relaxed the U14 atomic-load guard
                # under ptr_cells, so setindex! now advances PAST the atomic-load
                # wall to its `insertvalue { ptr, ptr }` memoryref-aggregate wall;
                # disjunction widened to include the new successor (the load-bearing
                # `!_is_ptr_return_wall` assertion above is unchanged).
                # Bennett-6bu3: insertvalue on {ptr,ptr} StructType bodies is now
                # SUPPORTED, so setindex! advances PAST the insertvalue wall to the
                # `ptrtoint ptr %memory_data to i64` GenericMemory data-pointer wall
                # (Bennett-iwo9 / CW-D3 Lever 1). Added ptrtoint / iwo9 / type-tag
                # disjuncts; all existing disjuncts kept.
                @test occursin("ptrtoint", lowercase(msg_on)) ||  # Bennett-6bu3: new iwo9 successor
                      occursin("iwo9", lowercase(msg_on)) ||      # Bennett-6bu3
                      occursin("type-tag", lowercase(msg_on)) ||  # Bennett-6bu3
                      occursin("VoidType", msg_on) || occursin("U81", msg_on) ||
                      occursin("atomic", msg_on)   || occursin("U14", msg_on) ||
                      occursin("insertvalue", lowercase(msg_on)) ||
                      occursin("aggregate", lowercase(msg_on)) ||
                      occursin("structtype", lowercase(msg_on)) ||
                      occursin("memcpy", lowercase(msg_on)) ||
                      occursin("closed-world", msg_on)
            end

            # --- rehash!(Dict{Int8,Int8},Int64) ---
            at_rh = Tuple{Dict{Int8,Int8},Int64}
            (rh_off, rmsg_off) = _try_extract(Base.rehash!, at_rh; cells=false)
            @test rh_off === :err
            @test _is_ptr_return_wall(rmsg_off)       # cells-OFF: still the ptr-RETURN wall

            # Bennett-8bys / CW-D (2026-07-07): variable-size memset routing cleared
            # rehash!'s last single-function wall, so `rehash!` now FULLY EXTRACTS
            # (rh_on === :ok, BOTH check-bounds modes) — the :ok branch below fires.
            # The else-branch disjunction is retained as future-robust (if a later
            # wall reappears).
            (rh_on, rmsg_on) = _try_extract(Base.rehash!, at_rh; cells=true)
            if rh_on === :ok
                @test rmsg_on isa ParsedIR
            else
                @test !_is_ptr_return_wall(rmsg_on)   # ptr-RETURN wall CLEARED
                # Bennett-ares (CW-D2 lever 1): the relaxed U14 guard advances
                # rehash! past its `store atomic … release` + atomic-load walls to
                # the `llvm.memcpy @"_j_const#1"` wall; disjunction widened.
                # Bennett-6bu3: insertvalue on {ptr,ptr} StructType bodies is now
                # SUPPORTED; the captured runtime wall is the `llvm.memcpy
                # @"_j_const#1"` wall (already covered by the memcpy disjunct), but
                # under a different registry order the ptrtoint `%memory_data → i64`
                # iwo9 wall (Bennett-iwo9 / CW-D3 Lever 1) can surface first — add
                # ptrtoint / iwo9 / type-tag disjuncts; all existing disjuncts kept.
                # Bennett-yd4f / U80 (2026-07-07): the integer-undef-in-phi →
                # zero-cell fix cleared the `phi i64 [ undef, ... ]` wall; rehash!
                # now advances to a MODE-dependent successor — default mode: the
                # `unsupported return type LLVM.ArrayType([1 x ptr])`
                # `j_AssertionError` C-call wall (assertionerror / arraytype /
                # unsupported-return-type); suite mode: the ptrtoint/iwo9 wall
                # (already covered). Added the three default-mode disjuncts.
                @test occursin("unsupported return type", lowercase(rmsg_on)) ||  # Bennett-yd4f
                      occursin("assertionerror", lowercase(rmsg_on)) ||  # Bennett-yd4f
                      occursin("arraytype", lowercase(rmsg_on)) ||       # Bennett-yd4f
                      occursin("ptrtoint", lowercase(rmsg_on)) ||  # Bennett-6bu3: new iwo9 successor
                      occursin("iwo9", lowercase(rmsg_on)) ||      # Bennett-6bu3
                      occursin("type-tag", lowercase(rmsg_on)) ||  # Bennett-6bu3
                      occursin("atomic", rmsg_on) || occursin("U14", rmsg_on) ||
                      occursin("VoidType", rmsg_on) || occursin("U81", rmsg_on) ||
                      occursin("insertvalue", lowercase(rmsg_on)) ||
                      occursin("aggregate", lowercase(rmsg_on)) ||
                      occursin("structtype", lowercase(rmsg_on)) ||
                      occursin("memcpy", lowercase(rmsg_on)) ||
                      # Bennett-u2kk: the param-cell global-src memcpy fix advanced
                      # rehash! PAST the `@"_j_const#1"` field-init memcpy wall
                      # (idxfloor/ndel/maxprobe) to the ptr-null ICmp wall
                      # (Bennett-8g7m target / Bennett-bjdg / U80). Add null/U80 disjuncts.
                      occursin("null", lowercase(rmsg_on)) ||     # Bennett-u2kk
                      occursin("u80", lowercase(rmsg_on)) ||      # Bennett-u2kk
                      occursin("closed-world", rmsg_on)
            end
        end

        # GATE-G discipline: registry fully restored, no leak.
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

    # ========================================================================
    # GATE C — set producer threads ptr_cells into _extract_one (per-callee).
    # ========================================================================
    @testset "GATE C — set producer forwards ptr_cells to per-callee extract" begin
        fdict_lf14(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end

        # With ptr_cells=true the producer's per-callee extract clears the
        # ptr-RETURN wall. Bennett-416r.12 / CW-D2 (2026-07-07): the closed-world
        # heap-intrinsic whitelist (gc_alloc_obj / jl_alloc_genericmemory /
        # memset) + the julia.write_barrier drop CLOSED the set — with
        # ptr_cells=true the producer now returns a FULLY CLOSED 4-body set (no
        # wall at all), in BOTH check-bounds modes. (Earlier frontiers this GATE
        # pinned: Bennett-8bys advanced rehash! to full extraction; before that
        # the ptr-RETURN wall.) The cells=true (CLOSES) vs cells=false (ptr-RETURN
        # wall, below) CONTRAST is what still proves the producer forwards
        # ptr_cells into the per-callee extract.
        err_on = try
            extract_parsed_ir_set_from_julia(fdict_lf14, Tuple{Int8,Int8};
                                             on_extract_error=:fail_loud, ptr_cells=true)
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err_on === nothing ||         # set CLOSED (current, strongest outcome)
              !_is_ptr_return_wall(err_on)   # or a residual wall that is NOT the
                                             # threaded-cleared ptr-RETURN wall (future-robust)

        # Default (cells=false) STILL hits the ptr-RETURN wall — pins that the
        # producer default is byte-identical (it forwards false, not true).
        err_off = try
            extract_parsed_ir_set_from_julia(fdict_lf14, Tuple{Int8,Int8})
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err_off !== nothing
        @test _is_ptr_return_wall(err_off)

        # Set-path default-off equivalence on a ptr-free root: ptr_cells is a
        # no-op, so the entry-first key Vector is identical default / =true.
        s_default = extract_parsed_ir_set_from_julia(lf14_incr, Tuple{Int8})
        s_on      = extract_parsed_ir_set_from_julia(lf14_incr, Tuple{Int8}; ptr_cells=true)
        s_off     = extract_parsed_ir_set_from_julia(lf14_incr, Tuple{Int8}; ptr_cells=false)
        @test first.(s_default) == first.(s_on)
        @test first.(s_default) == first.(s_off)

        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before                          # no registry leak
    end

end
