# Bennett-u2kk — CW-D: global-src memcpy into a function POINTER-PARAMETER cell
# field (a const-offset GEP off the Dict pointer param), under the closed-world
# `ptr_cells=true` gate.
#
# After Bennett-vbv9 cleared the gc_alloc'd ARENA dst and Bennett-xrd6 cleared
# the sret-call wall, the closed-world `rehash!` root
#   extract_parsed_ir(Base.rehash!, Tuple{Dict{Int8,Int8},Int64};
#                      optimize=false, ptr_cells=true)
# walls at FOUR field-init memcpys of the shape
#   memcpy(ptr %"h::Dict.idxfloor_ptr", ptr @"_j_const#1", i64 8)
# where the dst is a `getelementptr inbounds i8, ptr %"h::Dict", i32 OFF` off the
# Dict POINTER PARAMETER (NOT an alloca, NOT a gc_alloc arena) and the src is a
# SCALAR `i64` const-global. The pre-u2kk global-src memcpy handler only accepts
# alloca (`_alloca_root_ref`) or arena (`_gc_alloc_root_ref`) dst roots → fails
# loud at the G3 predicate ("not alloca-backed ... (Bennett-doih)").
#
# u2kk adds a THIRD G3 root, `_param_ptr_root_ref` — a dst that traces (via
# const-`i8`-GEPs) to an LLVM Argument of PointerType is accepted as a PARAM-CELL
# dst (cell width 64, ADR 0018) UNDER ptr_cells. The param branch SKIPS the
# alloca-specific G4 elem-width probe and the G9 freshness gate (see the
# reversibility justification in the source comment — the write is a DESTRUCTIVE
# live-field overwrite, reversible only via BVM's Bennett-1973 history tape, which
# is a ptr_cells/BVM artifact), but KEEPS G6 (cross-width reject). Emission is the
# SAME `IRPtrOffset + IRStore(iconst,64)` shape the proven setindex! field-stores
# already produce off a Dict param cell.
#
# On the circuit path (`ptr_cells=false`) the param branch is INERT — the dst
# still fails the G3 "not alloca-backed" wall byte-identically (the gate that
# routes a non-alloca dst to the param root is `ptr_cells`-conditioned, and the
# circuit model has no history tape — destructive overwrite stays fail-loud).
#
# Gate map:
#   (a) ptr_cells=true POSITIVE node-shape: a global-src memcpy into a param-cell
#       field extracts :ok; exactly one IRStore width=64 whose value is the
#       global's constant; the dst field-GEP IRPtrOffset (offset 48) present; the
#       memcpy chunk-0 IRPtrOffset (offset 0, elem_width 64) present; ZERO
#       byte-granular (width=8) stores.
#   (b) ptr_cells=false byte-identity: the SAME fixture → :err at the UNCHANGED
#       G3/doih "not alloca-backed" wall (circuit path must keep rejecting).
#   (c) cross-width reject: a NON-64-bit (i32) scalar global into a param-cell
#       dst under ptr_cells=true → :err at the G6 cross-width reject.
#   (d) real rehash! root wall-ADVANCE (optimize=false, ptr_cells=true): NEGATIVE
#       (no longer the doih G3 global-src-memcpy wall) + an inclusive disjunction
#       of plausible CW-D successors. Registry snapshot/restore (Rule 7 — no
#       _known_callees leak).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               ParsedIR, IRStore, IRPtrOffset, IRCall, ConstOperand
import LLVM

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). Each mirrors
# the real rehash! field-init shape: a SCALAR const-global memcpy'd into a
# `getelementptr inbounds i8` off a `dereferenceable`-attributed pointer PARAM
# (the Julia struct-by-ref `Dict` cell). The function returns a plain i64 0 so
# the return-width derivation needs no ptr-cell gymnastics (and, crucially, so
# the ptr_cells=false byte-identity path reaches the memcpy rather than walling
# earlier on a `void` return — see the dq8l/U81 VoidType wall).
# ---------------------------------------------------------------------------

# POSITIVE param fixture: scalar i64 global (= 7) → param-cell field at byte
# offset 48 off the deref(64) pointer param. Mirrors `h::Dict.idxfloor` init.
const PARAM_MEMCPY = """
declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, ptr noalias nocapture readonly, i64, i1 immarg)
@gval = private unnamed_addr constant i64 7, align 8
define i64 @param_memcpy(ptr noundef nonnull align 8 dereferenceable(64) %h) {
top:
  %fld = getelementptr inbounds i8, ptr %h, i32 48
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %fld, ptr align 8 @gval, i64 8, i1 false)
  ret i64 0
}
"""

# CROSS-WIDTH fixture: source global is i32 (5), memcpy size i64 4 into a param
# cell. Must fail loud at G6 cross-width (a non-64-bit global into a 64-bit param
# cell is rejected — same fence as the arena dst).
const PARAM_MEMCPY_I32 = """
declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, ptr noalias nocapture readonly, i64, i1 immarg)
@gval32 = private unnamed_addr constant i32 5, align 4
define i64 @param_memcpy_i32(ptr noundef nonnull align 8 dereferenceable(64) %h) {
top:
  %fld = getelementptr inbounds i8, ptr %h, i32 48
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %fld, ptr align 4 @gval32, i64 4, i1 false)
  ret i64 0
}
"""

# Extract a hand-built .ll fixture, returning (:ok, pir) or (:err, message).
function _u2kk_extract_ll(name, ir, entry; cells)
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
function _u2kk_all_insts(pir)
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

@testset "Bennett-u2kk param-cell-dst global-src memcpy under ptr_cells" begin

    # =======================================================================
    # GATE (a) — ptr_cells=true: global-src memcpy into a pointer-param cell
    # field lowers to a single 64-bit IRStore of the global's value. Positive
    # node-shape assertions (Rule 4: no-throw is not a pass).
    # =======================================================================
    @testset "GATE (a) — param memcpy lowers to one 64-bit IRStore" begin
        (st, pir) = _u2kk_extract_ll("param_memcpy", PARAM_MEMCPY, "param_memcpy"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _u2kk_all_insts(pir)

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

            # The dst field-GEP IRPtrOffset (byte offset 48) must be present (the
            # GEP→param chain was walked, not folded away).
            @test any(x -> x isa IRPtrOffset && x.offset_bytes == 48, insts)

            # The memcpy emits a fresh dst-GEP IRPtrOffset at offset 0 (the single
            # 8-byte chunk), elem_width 64 (the param cell width).
            chunk_offs = filter(x -> x isa IRPtrOffset && x.offset_bytes == 0 &&
                                     x.elem_width == 64, insts)
            @test length(chunk_offs) >= 1
        end
    end

    # =======================================================================
    # GATE (b) — ptr_cells=false: the SAME fixture still walls at the unchanged
    # G3/doih "not alloca-backed" memcpy wall (byte-identity — the param root is
    # only consulted under ptr_cells, so on the circuit path a non-alloca dst
    # fails loud exactly as pre-u2kk: there is no history tape to reverse a
    # destructive live-field overwrite).
    # =======================================================================
    @testset "GATE (b) — param memcpy walls on the circuit path (byte-identity)" begin
        (st, msg) = _u2kk_extract_ll("param_memcpy_off", PARAM_MEMCPY, "param_memcpy"; cells=false)
        @test st === :err
        if st === :err
            @test _is_doih_g3_wall(msg)
        end
    end

    # =======================================================================
    # GATE (c) — cross-width reject: a NON-64-bit (i32) scalar global into a
    # param-cell dst under ptr_cells=true fails loud at the G6 cross-width gate
    # (an i32 global cannot pack into a 64-bit param cell in the MVP — same fence
    # as the arena dst).
    # =======================================================================
    @testset "GATE (c) — non-64-bit global into param dst → G6 cross-width" begin
        (st, msg) = _u2kk_extract_ll("param_memcpy_i32", PARAM_MEMCPY_I32, "param_memcpy_i32"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("cross-width", msg)
        end
    end

    # =======================================================================
    # GATE (d) — real rehash! root wall-ADVANCE under cells=true. Pre-u2kk the
    # root walls at the doih G3 "not alloca-backed" memcpy wall (the 4 param-
    # field-init memcpys); post-u2kk the param branch fires and a LATER wall
    # surfaces. Assert NEGATIVELY (no longer the G3 memcpy wall) + an inclusive
    # disjunction of plausible successors. Registry snapshot/restore (Rule 7).
    # =======================================================================
    @testset "GATE (d) — rehash! root advances past the param-memcpy G3 wall" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            at = Tuple{Dict{Int8,Int8},Int64}

            on_msg = try
                extract_parsed_ir(Base.rehash!, at; optimize=false, ptr_cells=true)
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
                      occursin("gc_loaded", lowercase(on_msg))       ||
                      occursin("ptrtoint", lowercase(on_msg))        ||
                      occursin("inttoptr", lowercase(on_msg))        ||
                      occursin("smul", lowercase(on_msg))            ||
                      occursin("overflow", lowercase(on_msg))        ||
                      occursin("kvdv", lowercase(on_msg))            ||
                      occursin("null", lowercase(on_msg))            ||
                      occursin("bjdg", lowercase(on_msg))            ||
                      occursin("U80", on_msg)                        ||
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
