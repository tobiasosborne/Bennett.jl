# Bennett-qmv7 — CW-D: `setindex!` heap-Memory value-store memcpy whose DST is a
# RUNTIME-INDEXED `julia.gc_loaded` heap-Memory cell, under the closed-world
# `ptr_cells=true` gate. The dual of vbv9 (const-offset gc_alloc ARENA dst); here
# the dst byte-offset is a RUNTIME SSA (`%off * STRIDE`), the Int8 value-store
# into the Dict's `vals` `Memory`.
#
# The closed-world fdict root advances (post 6bu3/iwo9) so that
# `extract_parsed_ir(setindex!, Tuple{Dict{Int8,Int8},Int8,Int8};
#  optimize=false, ptr_cells=true)` walls at `instructions.jl` Predicate-6
# (`dst_root === nothing`) on
#   call void @llvm.memcpy.p0.p0.i64(ptr %memoryref_data40, ptr %"sret_box[2]_ptr", i64 1)
# where
#   %d    = call ptr @julia.gc_loaded(ptr %mem, ptr %data)
#   %bo   = mul i64 %off, STRIDE        ; byte offset = element_index * stride
#   %addr = getelementptr inbounds i8, ptr %d, i64 %bo
# i.e. the dst traces to a `julia.gc_loaded` data-pointer launder, NOT an alloca.
#
# qmv7 routes this (under ptr_cells ONLY) through `_handle_memcpy_gc_loaded`,
# which RECOVERS the raw element index `%off` (splitting the `mul %off, STRIDE`
# — the eln6-safe split, identical to the proven `mem=:vm` recogniser) and emits
# a FRESH IRVarGEP + IRLoad + IRStore at the VALUE element width (= N*8 = the
# Memory's byte stride scaled to bits).
#
#   *** THE eln6 BYTE/CELL CONTRACT (Bennett-eln6) — the load-bearing check ***
# The dst GEP is ALWAYS an `i8` GEP whose index is the BYTE offset `%off*STRIDE`.
# BVM's IRVarGEP is CELL-addressed (stride 1, one Int64/cell) and consumes the
# index operand AS the element index. Feeding the byte offset directly (as the
# already-lowered `IRVarGEP(:addr,:d,:bo,8)` for the dst GEP does) would address
# cell `off*STRIDE` — correct only for STRIDE==1 (the i8 coincidence), an `8×`
# misaddress for an i64-vals Memory. qmv7 emits the RAW index `%off` at the VALUE
# width, so cell `off` is correct for EVERY element width. The i64 variant below
# proves byte-offset != cell-index is handled (the eln6 catch).
#
# Gate map:
#   (a) ptr_cells=true POSITIVE node-shape (i8 AND i64): the memcpy lowers to a
#       FRESH IRVarGEP whose index is the RAW element index `%off` (NOT the byte
#       offset `%bo`) at width = N*8, + IRLoad(src) + IRStore(dst). The gc_loaded
#       IRCall is present (the heap base).
#   (b) ptr_cells=false byte-identity: the SAME fixture → :err at the UNCHANGED
#       Predicate-6 "not alloca-backed" (Bennett-37mt) wall.
#   (c) eln6 CORRECTNESS — i8 AND i64: assert the emitted dst IRVarGEP index SSA
#       is the raw `%off` and width is the value width (8 / 64), NOT `%bo` / 8 —
#       the structural eln6 catch a byte-offset-reuse regression would FAIL.
#   (d) the real setindex! root wall-ADVANCE (optimize=false, ptr_cells=true):
#       extracts CLEAN (ret_width==64, 12 blocks); the memcpy wall is gone.
#       Registry snapshot/restore (Rule 7 — no _known_callees leak).
#   (e) fail-loud matrix: multi-element (N != stride), src-not-alloca, non-`mul`
#       index — each rejected loud (qmv7 breadcrumbs / the unchanged 302 wall).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir, register_callee!,
               ParsedIR, IRVarGEP, IRLoad, IRStore, IRCall,
               SSAOperand, ConstOperand
import LLVM

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). Each mirrors
# the real `setindex!` value-store: a runtime-indexed `julia.gc_loaded` element
# store fed by a const-size memcpy from an alloca-backed value box.
# ---------------------------------------------------------------------------

# i8-vals (STRIDE=1, N=1): the real `Dict{Int8,Int8}` fdict shape. The src box is
# an `[2 x i64]` alloca (the setindex! sret box) read through a const-i8-GEP.
const GCL_I8 = """
declare ptr @julia.gc_loaded(ptr, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
define i64 @gcl_i8(ptr %mem, ptr %data, i64 %idx, i8 %v) {
top:
  %fld  = alloca [2 x i64], align 8
  %sp   = getelementptr inbounds i8, ptr %fld, i32 8
  store i8 %v, ptr %sp, align 1
  %off  = sub i64 %idx, 1
  %bo   = mul i64 %off, 1
  %d    = call ptr @julia.gc_loaded(ptr %mem, ptr %data)
  %addr = getelementptr inbounds i8, ptr %d, i64 %bo
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %addr, ptr align 1 %sp, i64 1, i1 false)
  ret i64 0
}
"""

# i64-vals (STRIDE=8, N=8): the GENERAL case where byte offset != element index.
# Proves the eln6 split: the emitted IRVarGEP index must be `%off` (cell `off`),
# NOT `%bo == off*8` (cell `off*8` — an 8x misaddress), at width 64 (NOT 8).
const GCL_I64 = """
declare ptr @julia.gc_loaded(ptr, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
define i64 @gcl_i64(ptr %mem, ptr %data, i64 %idx, i64 %v) {
top:
  %fld  = alloca [2 x i64], align 8
  %sp   = getelementptr inbounds i8, ptr %fld, i32 8
  store i64 %v, ptr %sp, align 8
  %off  = sub i64 %idx, 1
  %bo   = mul i64 %off, 8
  %d    = call ptr @julia.gc_loaded(ptr %mem, ptr %data)
  %addr = getelementptr inbounds i8, ptr %d, i64 %bo
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %addr, ptr align 8 %sp, i64 8, i1 false)
  ret i64 0
}
"""

# Multi-element reject: N=2 but stride=1 (two i8 elements) — out of scope.
const GCL_MULTI = """
declare ptr @julia.gc_loaded(ptr, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
define i64 @gcl_multi(ptr %mem, ptr %data, i64 %idx, i8 %v) {
top:
  %fld  = alloca [2 x i64], align 8
  %sp   = getelementptr inbounds i8, ptr %fld, i32 8
  store i8 %v, ptr %sp, align 1
  %off  = sub i64 %idx, 1
  %bo   = mul i64 %off, 1
  %d    = call ptr @julia.gc_loaded(ptr %mem, ptr %data)
  %addr = getelementptr inbounds i8, ptr %d, i64 %bo
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %addr, ptr align 1 %sp, i64 2, i1 false)
  ret i64 0
}
"""

# src-not-alloca reject: src is a function-arg ptr (no alloca root).
const GCL_SRCPARAM = """
declare ptr @julia.gc_loaded(ptr, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
define i64 @gcl_srcparam(ptr %mem, ptr %data, i64 %idx, ptr %srcp) {
top:
  %off  = sub i64 %idx, 1
  %bo   = mul i64 %off, 1
  %d    = call ptr @julia.gc_loaded(ptr %mem, ptr %data)
  %addr = getelementptr inbounds i8, ptr %d, i64 %bo
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %addr, ptr align 1 %srcp, i64 1, i1 false)
  ret i64 0
}
"""

# non-`mul` index reject: the index is `add %idx, 3`, NOT `mul %off, STRIDE`, so
# `_gc_loaded_dst_elem_ref` returns nothing → falls to the UNCHANGED 302 wall.
const GCL_ADDIDX = """
declare ptr @julia.gc_loaded(ptr, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
define i64 @gcl_addidx(ptr %mem, ptr %data, i64 %idx, i8 %v) {
top:
  %fld  = alloca [2 x i64], align 8
  %sp   = getelementptr inbounds i8, ptr %fld, i32 8
  store i8 %v, ptr %sp, align 1
  %bo   = add i64 %idx, 3
  %d    = call ptr @julia.gc_loaded(ptr %mem, ptr %data)
  %addr = getelementptr inbounds i8, ptr %d, i64 %bo
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %addr, ptr align 1 %sp, i64 1, i1 false)
  ret i64 0
}
"""

# Extract a hand-built .ll fixture, returning (:ok, pir) or (:err, message).
function _qmv7_extract_ll(name, ir, entry; cells)
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

# All instructions across blocks, including terminators.
function _qmv7_all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# Is `msg` the unchanged Bennett-37mt Predicate-6 "not alloca-backed" wall?
_is_37mt_dst_wall(msg) =
    occursin("memcpy dst operand is not alloca-backed", msg) &&
    occursin("Bennett-37mt", msg)

# Find the qmv7-emitted heap-store triple: the IRVarGEP whose base is the
# gc_loaded result, feeding an IRStore through the IRLoad'd value. Returns the
# IRVarGEP, or nothing. The qmv7 dst-GEP is the one whose index is the RAW
# element index `:off` (the dead dst-GEP lowering carries `:bo`).
function _qmv7_heap_store_vargep(pir)
    insts = _qmv7_all_insts(pir)
    # The gc_loaded call names the heap base (`:d`).
    gcl = filter(x -> x isa IRCall && x.callee === Symbol("julia.gc_loaded"), insts)
    isempty(gcl) && return nothing
    base_sym = gcl[1].dest
    # The qmv7 store reads the value via IRLoad then IRStore through a fresh
    # IRVarGEP off the gc_loaded base. Find the IRStore whose ptr SSA is the
    # dest of an IRVarGEP off `base_sym`.
    vgeps = filter(x -> x isa IRVarGEP && x.base isa SSAOperand &&
                        x.base.name === base_sym, insts)
    stores = filter(x -> x isa IRStore && x.ptr isa SSAOperand, insts)
    for s in stores
        for vg in vgeps
            vg.dest === s.ptr.name && return vg
        end
    end
    return nothing
end

@testset "Bennett-qmv7 gc_loaded heap-Memory value-store memcpy under ptr_cells" begin

    # =======================================================================
    # GATE (a) — ptr_cells=true POSITIVE node-shape (i8). The memcpy lowers to a
    # fresh IRVarGEP(raw idx)+IRLoad(src)+IRStore. Rule 4: no-throw is not a pass.
    # =======================================================================
    @testset "GATE (a) — i8 gc_loaded memcpy lowers to IRVarGEP+IRLoad+IRStore" begin
        (st, pir) = _qmv7_extract_ll("gcl_i8", GCL_I8, "gcl_i8"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _qmv7_all_insts(pir)

            # The gc_loaded IRCall is present (the heap base).
            gc_calls = filter(x -> x isa IRCall &&
                                   x.callee === Symbol("julia.gc_loaded"), insts)
            @test length(gc_calls) == 1

            # The qmv7 heap-store IRVarGEP is present and uses the RAW element
            # index (the `%off` SSA), at value width 8.
            vg = _qmv7_heap_store_vargep(pir)
            @test vg !== nothing
            if vg !== nothing
                @test vg.index isa SSAOperand
                @test vg.index.name === :off       # RAW index, NOT :bo
                @test vg.elem_width == 8            # value width = N*8
            end

            # The store value flows from an IRLoad off the src box, at width 8.
            stores = filter(x -> x isa IRStore && x.ptr isa SSAOperand &&
                                 vg !== nothing && x.ptr.name === vg.dest, insts)
            @test length(stores) == 1
            if length(stores) == 1
                @test stores[1].width == 8
                @test stores[1].val isa SSAOperand
                loads = filter(x -> x isa IRLoad &&
                                    x.dest === stores[1].val.name, insts)
                @test length(loads) == 1
                length(loads) == 1 && @test loads[1].width == 8
            end
        end
    end

    # =======================================================================
    # GATE (b) — ptr_cells=false byte-identity: the SAME fixture must still wall
    # at the UNCHANGED Predicate-6 "not alloca-backed" (Bennett-37mt) message.
    # =======================================================================
    @testset "GATE (b) — circuit path (ptr_cells=false) still walls byte-identically" begin
        (st, msg) = _qmv7_extract_ll("gcl_i8", GCL_I8, "gcl_i8"; cells=false)
        @test st === :err
        st === :err && @test _is_37mt_dst_wall(msg)
        # And it must NOT mention qmv7 (the gc_loaded arm is unreachable off-gate).
        st === :err && @test !occursin("Bennett-qmv7", msg)
    end

    # =======================================================================
    # GATE (c) — eln6 CORRECTNESS, i64-vals (STRIDE=8). The GENERAL case where
    # byte offset (%bo = off*8) != element index (%off). The emitted dst IRVarGEP
    # index MUST be the raw `%off` (cell `off`), at width 64 — NOT `%bo` / width
    # 8 (the 8x misaddress a byte-offset-reuse regression would produce).
    # =======================================================================
    @testset "GATE (c) — eln6 byte/cell: raw index %off, NOT byte offset %bo" begin
        (st, pir) = _qmv7_extract_ll("gcl_i64", GCL_I64, "gcl_i64"; cells=true)
        @test st === :ok
        if st === :ok
            vg = _qmv7_heap_store_vargep(pir)
            @test vg !== nothing
            if vg !== nothing
                # The eln6 catch: index is the RAW element index, NOT the byte
                # offset, and the width is the VALUE width (64), NOT the i8 GEP
                # type and NOT a blind 64-as-coincidence.
                @test vg.index isa SSAOperand
                @test vg.index.name === :off       # cell `off`, correct
                @test vg.index.name !== :bo        # NOT the byte offset off*8
                @test vg.elem_width == 64          # value width = N*8 = 64
            end
            # The store + load are at width 64.
            insts = _qmv7_all_insts(pir)
            if vg !== nothing
                stores = filter(x -> x isa IRStore && x.ptr isa SSAOperand &&
                                     x.ptr.name === vg.dest, insts)
                @test length(stores) == 1
                length(stores) == 1 && @test stores[1].width == 64
            end
        end
    end

    # =======================================================================
    # GATE (d) — the real `setindex!(Dict{Int8,Int8})` root advances PAST the
    # memcpy "not alloca-backed" wall under ptr_cells. The memcpy dst wall (this
    # bead's target) must be GONE: setindex! either extracts CLEAN (ret_width==64,
    # 12 blocks — the `optimize=false`, NO-bounds-check shape) OR advances to a
    # DIFFERENT (already-tracked) wall. Rule 5 / Bennett-2mj3: under
    # `--check-bounds=yes` (the Pkg.test() suite mode) `code_llvm` emits extra
    # bounds-check IR that surfaces the EARLIER `ptrtoint` GenericMemory
    # data-pointer wall (Bennett-iwo9 / jfw6 — the next CW-D frontier) BEFORE the
    # memcpy; so the clean-extract shape is mode-dependent. The load-bearing,
    # mode-INVARIANT assertion is the NEGATIVE: it is no longer the qmv7 memcpy
    # dst wall. Registry snapshot/restore (Rule 7 — no _known_callees leak).
    # =======================================================================
    @testset "GATE (d) — setindex! root advances past the memcpy wall" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        added = String[]
        try
            register_callee!(setindex!)
            push!(added, string(nameof(setindex!)))

            at = Tuple{Dict{Int8,Int8},Int8,Int8}

            on_result = try
                pir = extract_parsed_ir(setindex!, at; optimize=false, ptr_cells=true)
                (:ok, pir)
            catch e
                e isa InterruptException && rethrow()
                (:err, sprint(showerror, e))
            end

            if on_result[1] === :ok
                # NO-bounds-check mode: extracts clean (the bead's predicted
                # shape). Even stronger than wall-advance.
                pir = on_result[2]
                @test pir.ret_width == 64
                @test length(pir.blocks) == 12
                vg = _qmv7_heap_store_vargep(pir)
                @test vg !== nothing
            else
                msg = on_result[2]
                # MODE-INVARIANT: the memcpy dst "not alloca-backed" wall is GONE.
                @test !_is_37mt_dst_wall(msg)
                # POSITIVE disjunction — the EXACT downstream wall is
                # REGISTRY-ORDER-DEPENDENT (Rule 7; found via the full-suite run,
                # Bennett-6rqq):
                #   * clean registry (standalone): setindex! advances to the
                #     iwo9/jfw6 `ptrtoint` GenericMemory data-pointer wall.
                #   * once a PRIOR file has registered the Dict helpers
                #     (`ht_keyindex2_shorthash!`/`rehash!` — e.g. test_59zi leaks
                #     them into the global `_known_callees`), the recursive
                #     extraction goes FURTHER and hits the dq8l/U81 VoidType
                #     `_type_width` wall instead.
                # Both are legitimate "advanced past the qmv7 memcpy wall"
                # successors; accept the known CW-D walls in EITHER order and rely
                # on the mode-invariant negative above for the qmv7 guarantee.
                lm = lowercase(msg)
                @test occursin("ptrtoint", lm)        ||  # iwo9 / jfw6 (clean registry)
                      occursin("iwo9", lm)             ||
                      occursin("type-tag", lm)         ||
                      occursin("genericmemory", lm)    ||
                      occursin("jfw6", lm)             ||
                      occursin("inttoptr", lm)         ||
                      occursin("closed-world", lm)     ||
                      occursin("_type_width", lm)      ||  # dq8l / U81 (Dict callees registered)
                      occursin("voidtype", lm)         ||
                      occursin("dq8l", lm)             ||
                      occursin("u81", lm)
            end

            # cells=false: still the EARLIER ptr-return PointerType wall (lf14:
            # the ret_width query on a `ptr` return fails before the body is
            # reached). UNCHANGED off-gate, mode-invariant.
            off_msg = try
                extract_parsed_ir(setindex!, at; optimize=false, ptr_cells=false)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            @test off_msg !== nothing
            off_msg !== nothing && @test occursin("unsupported LLVM type", off_msg) &&
                                         occursin("PointerType", off_msg)
        finally
            lock(Bennett._known_callees_lock) do
                for k in added
                    if haskey(before, k)
                        Bennett._known_callees[k] = before[k]
                    else
                        delete!(Bennett._known_callees, k)
                    end
                end
            end
        end
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

    # =======================================================================
    # GATE (e) — fail-loud matrix (Rule 1). Each out-of-scope shape rejects loud;
    # no previously-rejected program silently passes.
    # =======================================================================
    @testset "GATE (e) — fail-loud matrix" begin
        # Multi-element (N != stride) → qmv7-multi reject.
        (stm, msgm) = _qmv7_extract_ll("gcl_multi", GCL_MULTI, "gcl_multi"; cells=true)
        @test stm === :err
        stm === :err && @test occursin("Bennett-qmv7-multi", msgm)

        # src not alloca-backed → qmv7 src reject.
        (sts, msgs) = _qmv7_extract_ll("gcl_srcparam", GCL_SRCPARAM, "gcl_srcparam"; cells=true)
        @test sts === :err
        sts === :err && @test occursin("src is not alloca-backed", msgs) &&
                              occursin("Bennett-qmv7", msgs)

        # non-`mul` index → falls through to the UNCHANGED 302 wall (proves the
        # qmv7 recogniser is narrow: a non-element-store gc_loaded GEP is still
        # rejected exactly as before).
        (sta, msga) = _qmv7_extract_ll("gcl_addidx", GCL_ADDIDX, "gcl_addidx"; cells=true)
        @test sta === :err
        sta === :err && @test _is_37mt_dst_wall(msga)
        sta === :err && @test !occursin("Bennett-qmv7", msga)
    end
end
