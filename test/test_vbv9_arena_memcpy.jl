# Bennett-vbv9 — CW-D: global-src memcpy into a `julia.gc_alloc_obj`-backed
# ARENA cell, under the closed-world `ptr_cells=true` gate.
#
# The closed-world fdict root (`fdict_d1b(a,b)=(d=Dict{Int8,Int8}();d[a]=b;d[a])`,
# optimize=false, ptr_cells=true) walls at field-init memcpys of the shape
#   memcpy(ptr %"new::Dict.ndel_ptr", ptr @"_j_const#1", i64 8)
# where the dst is a `getelementptr inbounds i8, ptr %obj, i32 OFF` off the
# `julia.gc_alloc_obj` result (an ARENA pointer, NOT an alloca) and the src is
# a SCALAR `i64` const-global. The pre-vbv9 global-src memcpy handler only
# supported alloca-backed dsts → fails loud at the G3 predicate
# ("not alloca-backed ... (Bennett-doih)").
#
# vbv9 advances the wall in two interlocked parts:
#   PART 1 — `_extract_const_globals` now captures SCALAR `ConstantInt` globals
#            (previously dropped — only ConstantDataArray/Struct/AggregateZero
#            were captured). Without this, fixing G3 only moves the wall from G3
#            to G5 (`haskey(globals, gname)`).
#   PART 2 — G3 in `_handle_memcpy_global_src` is generalised: under ptr_cells,
#            a dst that traces (via const-`i8`-GEPs) to a `julia.gc_alloc_obj`
#            call is accepted as an ARENA dst (cell width 64, ADR 0018). The
#            arena branch SKIPS the alloca-specific G4/G9 gates but KEEPS G6
#            (cross-width reject), G7 (cell-alignment), G8 (bounds). Emission is
#            the SAME K-pair shape: IRPtrOffset(...,k*8,64) + IRStore(iconst,64).
#
# On the circuit path (`ptr_cells=false`) the arena branch is INERT — the dst
# still fails the G3 "not alloca-backed" wall byte-identically (the gate that
# routes a non-alloca dst to the arena root is `ptr_cells`-conditioned).
#
# Gate map:
#   (a) ptr_cells=true POSITIVE node-shape: a hermetic global-src memcpy into a
#       gc_alloc'd arena cell extracts :ok; exactly one IRStore width=64 whose
#       value is the global's constant; the dst-GEP IRPtrOffset present; the
#       gc_alloc_obj IRCall present; ZERO byte-granular (width=8) stores.
#   (b) ptr_cells=false byte-identity: the SAME fixture → :err at the unchanged
#       G3/doih "not alloca-backed" wall (or an upstream gc_alloc_obj wall).
#   (c) globals-capture: `parsed.globals` carries the scalar i64 global as
#       ([value],64); AND a NON-64-bit scalar global into an arena dst under
#       ptr_cells=true → :err at the G6 cross-width reject.
#   (d) real fdict_d1b root wall-ADVANCE (optimize=false, ptr_cells=true):
#       NEGATIVE (no longer the doih global-src-memcpy G3 wall) + an inclusive
#       disjunction of plausible CW-D successors. Registry snapshot/restore
#       (Rule 7 — no _known_callees leak).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               ParsedIR, IRStore, IRPtrOffset, IRCall, ConstOperand
import LLVM

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). Each mirrors
# the real fdict field-init shape: a SCALAR i64 const-global memcpy'd (i64 8
# bytes) into a `getelementptr inbounds i8` off a `julia.gc_alloc_obj` result.
# ---------------------------------------------------------------------------

# POSITIVE arena fixture: global @gval (scalar i64 = 7) → arena cell at byte
# offset 24 off the gc_alloc'd object. Mirrors `new::Dict.ndel` field-init.
# The function returns i64 0 (a plain integer return, so the function-level
# return-width derivation needs no ptr_cells gymnastics — keeps the fixture's
# wall squarely on the memcpy).
const ARENA_MEMCPY = """
declare noalias nonnull ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, ptr noalias nocapture readonly, i64, i1 immarg)
@gval = private unnamed_addr constant i64 7, align 8
define i64 @arena_memcpy(ptr %task, ptr %tag) {
top:
  %obj = call noalias nonnull align 8 ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %tag)
  %fld = getelementptr inbounds i8, ptr %obj, i32 24
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %fld, ptr align 8 @gval, i64 8, i1 false)
  ret i64 0
}
"""

# NON-64-bit-global fixture: source global is i8 (5), memcpy size i64 1 into an
# arena cell. Must fail loud at G6 cross-width (a non-64-bit global into an
# arena cell is rejected — the arena cell is fixed at width 64).
const ARENA_MEMCPY_I8 = """
declare noalias nonnull ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, ptr noalias nocapture readonly, i64, i1 immarg)
@gval8 = private unnamed_addr constant i8 5, align 1
define i64 @arena_memcpy_i8(ptr %task, ptr %tag) {
top:
  %obj = call noalias nonnull align 8 ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %tag)
  %fld = getelementptr inbounds i8, ptr %obj, i32 24
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %fld, ptr align 1 @gval8, i64 1, i1 false)
  ret i64 0
}
"""

# Extract a hand-built .ll fixture, returning (:ok, pir) or (:err, message).
function _vbv9_extract_ll(name, ir, entry; cells)
    mktempdir() do dir
        path = joinpath(dir, "$(name).ll")
        write(path, ir)
        try
            pir = extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=cells)
            return (:ok, pir)
        catch e
            e isa InterruptException && rethrow()
            return (:err, sprint(showerror, e))
        end
    end
end

# Collect all instructions across blocks, INCLUDING terminators.
function _vbv9_all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# Is `msg` the Bennett-doih G3 "not alloca-backed" global-src-memcpy wall?
_is_doih_g3_wall(msg) =
    occursin("not alloca-backed", msg) &&
    occursin("Bennett-doih", msg)

@testset "Bennett-vbv9 arena-dst global-src memcpy under ptr_cells" begin

    # =======================================================================
    # GATE (a) — ptr_cells=true: global-src memcpy into a gc_alloc'd arena
    # cell lowers to a single 64-bit IRStore of the global's value. Positive
    # node-shape assertions (Rule 4: no-throw is not a pass).
    # =======================================================================
    @testset "GATE (a) — arena memcpy lowers to one 64-bit IRStore" begin
        (st, pir) = _vbv9_extract_ll("arena_memcpy", ARENA_MEMCPY, "arena_memcpy"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _vbv9_all_insts(pir)

            # The gc_alloc_obj IRCall is present (the arena root).
            gc_calls = filter(x -> x isa IRCall && x.callee === :gc_alloc_obj, insts)
            @test length(gc_calls) == 1

            # Exactly one IRStore, width 64, value == the global's constant (7).
            stores = filter(x -> x isa IRStore, insts)
            @test length(stores) == 1
            if length(stores) == 1
                s = stores[1]
                @test s.val isa ConstOperand
                @test s.val.value == 7
                @test s.width == 64
            end

            # ZERO byte-granular (width=8) stores from the memcpy chunking.
            @test count(x -> x isa IRStore && x.width == 8, insts) == 0

            # The memcpy emits a fresh dst-GEP IRPtrOffset at offset 0 (the
            # single 8-byte chunk). There is also the field-GEP
            # `getelementptr i8 %obj, 24` lowered as its own IRPtrOffset;
            # assert the memcpy's chunk-0 one is present.
            #
            # RE-AUTHORED by Bennett-4y0d / Bennett-bvmd. This used to pin
            # `elem_width == 64` — the ARENA CELL WIDTH — conflating the width
            # of the VALUE each store writes (still 64, pinned above) with the
            # bytes-per-cell SCALE BennettVM divides the byte offset by. The
            # `julia.gc_alloc_obj` tier is reserved BYTE-granular
            # (`_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nb)`), so the
            # ADDRESS stamp is 8. At K == 1 the only offset is 0, and
            # `0 ÷ 8 == 0 ÷ 1 == 0` — the CELL is byte-identical, which is
            # exactly why this pin stayed green over a latent defect (at K == 2
            # the old stamp put element 1 on cell +1 instead of cell +8;
            # `test_bvmd_root_scale.jl` (H) is that gate).
            chunk_offs = filter(x -> x isa IRPtrOffset && x.offset_bytes == 0 &&
                                     x.elem_width == 8, insts)
            @test length(chunk_offs) >= 1
            # NOTE, deliberately NOT asserted here: "the cell is unchanged".
            # At K == 1 the only chunk offset is 0 and `0 ÷ k == 0` for every
            # k, so any such assertion on `chunk_offs` is a TAUTOLOGY (it
            # filters `offset_bytes == 0` and then divides it). The real
            # property — that element k of a K >= 2 arena memcpy lands on BYTE
            # cell 8k rather than word cell k — is unrepresentable in this
            # K == 1 fixture and is gated in
            # `test_bvmd_root_scale.jl` (H) instead.

            # The dst field-GEP IRPtrOffset (byte offset 24) must be present too
            # (proves the GEP→arena chain was walked, not folded away).
            @test any(x -> x isa IRPtrOffset && x.offset_bytes == 24, insts)
            # ... and THAT one carries a non-zero offset, so asserting its cell
            # is load-bearing: the arena tier is BYTE-reserved
            # (`_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nb)`), so byte 24
            # of the object is cell +24, not word cell +3.
            fld = only(filter(x -> x isa IRPtrOffset && x.offset_bytes == 24, insts))
            @test fld.elem_width == 8
            @test fld.offset_bytes ÷ (fld.elem_width ÷ 8) == 24
        end
    end

    # =======================================================================
    # GATE (b) — ptr_cells=false: the SAME fixture still walls at the unchanged
    # G3/doih "not alloca-backed" memcpy wall (byte-identity — the arena root
    # is only consulted under ptr_cells, so on the circuit path a non-alloca
    # dst fails loud exactly as pre-vbv9). Allow the disjunction with an
    # upstream gc_alloc_obj wall (gc_alloc_obj is ptr_cells-gated too, so under
    # cells=false the gc_alloc_obj call may wall earlier).
    # =======================================================================
    @testset "GATE (b) — arena memcpy walls on the circuit path (byte-identity)" begin
        (st, msg) = _vbv9_extract_ll("arena_memcpy_off", ARENA_MEMCPY, "arena_memcpy"; cells=false)
        @test st === :err
        if st === :err
            @test _is_doih_g3_wall(msg) ||
                  occursin("gc_alloc_obj", lowercase(msg)) ||
                  occursin("julia.gc_", lowercase(msg)) ||
                  occursin("no registered callee", msg) ||
                  occursin("closed-world", msg)
        end
    end

    # =======================================================================
    # GATE (c) — globals-capture + cross-width reject.
    #   (c1) PART 1: `_extract_const_globals` captures the scalar i64 global as
    #        ([7], 64) — directly, via the module walk on the fixture.
    #   (c2) PART 2/G6: a NON-64-bit scalar global into an arena dst under
    #        ptr_cells=true fails loud at the G6 cross-width gate (an i8 global
    #        cannot pack into a 64-bit arena cell in the MVP).
    # =======================================================================
    @testset "GATE (c1) — scalar i64 global captured as ([value],64)" begin
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ARENA_MEMCPY)
            globals, _ = Bennett._extract_const_globals(mod)
            @test haskey(globals, Symbol("gval"))
            if haskey(globals, Symbol("gval"))
                (data, ew) = globals[Symbol("gval")]
                @test data == UInt64[7]
                @test ew == 64
            end
        end
    end

    @testset "GATE (c2) — non-64-bit global into arena dst → G6 cross-width" begin
        (st, msg) = _vbv9_extract_ll("arena_memcpy_i8", ARENA_MEMCPY_I8, "arena_memcpy_i8"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("cross-width", msg)
        end
    end

    # =======================================================================
    # GATE (d) — real fdict_d1b root wall-ADVANCE under cells=true. Pre-vbv9 the
    # root walls at the doih G3 "not alloca-backed" memcpy wall (from the 5
    # field-init memcpys into gc_alloc'd arena cells); post-vbv9 the arena
    # branch fires and a LATER wall surfaces. Assert NEGATIVELY (no longer the
    # G3 memcpy wall) + an inclusive disjunction of plausible successors.
    # Registry snapshot/restore (Rule 7 — no _known_callees leak).
    # =======================================================================
    @testset "GATE (d) — fdict_d1b root advances past the arena-memcpy G3 wall" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            at = Tuple{Int8,Int8}

            on_msg = try
                extract_parsed_ir(fdict_d1b, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            if on_msg === nothing
                @test true  # fully extracted — even stronger than wall-advance
            else
                # NEGATIVE: no longer the doih G3 global-src-memcpy wall.
                @test !_is_doih_g3_wall(on_msg)
                # POSITIVE inclusive disjunction of plausible CW-D successors.
                @test occursin("insertvalue", lowercase(on_msg))     ||
                      occursin("aggregate", lowercase(on_msg))       ||
                      occursin("structtype", lowercase(on_msg))      ||
                      occursin("genericmemory", lowercase(on_msg))   ||
                      occursin("gc_alloc_obj", lowercase(on_msg))    ||
                      occursin("ptrtoint", lowercase(on_msg))        ||
                      occursin("inttoptr", lowercase(on_msg))        ||
                      occursin("memcpy", lowercase(on_msg))          ||
                      occursin("unsupported llvm opcode", lowercase(on_msg)) ||
                      occursin("atomic", lowercase(on_msg))          ||
                      occursin("U14", on_msg)                        ||
                      occursin("VoidType", on_msg)                   ||
                      occursin("U81", on_msg)                        ||
                      occursin("sret", lowercase(on_msg))            ||
                      occursin("U15", on_msg)                        ||
                      occursin("no registered callee", on_msg)       ||
                      occursin("closed-world", on_msg)               ||
                      occursin("PointerType", on_msg)
            end
        finally
            lock(Bennett._known_callees_lock) do
                empty!(Bennett._known_callees)
                merge!(Bennett._known_callees, before)
            end
        end

        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

end
