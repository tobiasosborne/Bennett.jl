# test/test_sy29_arena_src_memcpy.jl — bead Bennett-sy29 (xkl frontier wall 9):
# a `julia.gc_alloc_obj` ARENA root on EITHER SIDE of a const-size, cell-aligned
# `llvm.memcpy`, under the closed-world `ptr_cells=true` gate.
#
# # The wall
#
# The push! closed-world ROOT (`v = Int64[]; push!(v, n); @inbounds v[1]`) walls
# at
#
#     call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Array.size",
#                                      ptr align 8 %"new::Array.size_ptr1",
#                                      i64 8, i1 false)
#
# where `%"new::Array.size"` is an `alloca i64` and `%"new::Array.size_ptr1"` is
# `getelementptr i8, ptr %"new::Array", i32 16` off a
# `julia.gc_alloc_obj(_, i64 24, _)` result. The rejecting predicate is
# Predicate 6's SRC half in `_handle_memcpy_arm`: "memcpy src operand is not
# alloca-backed ... (Bennett-37mt Phase 1)". Three identical sites in the ROOT
# body, plus one MIRROR site (`%L18`) copying an `alloca [1 x i64]` INTO arena
# byte 16.
#
# # What sy29 admits, and the shape of the admission
#
# Route R1 — the vbv9 arm's mirror: per-cell
# `IRPtrOffset + IRPtrOffset + IRLoad + IRStore` decomposition, with the
# Bennett-4y0d PER-SIDE byte-tier stamp discipline. The two numbers that HEAD
# conflates are:
#
#   * the VALUE width each `IRLoad`/`IRStore` carries (64 — one whole Int64 cell,
#     ADR 0018 §A), and
#   * the ADDRESS stamp each `IRPtrOffset` carries, which BennettVM divides the
#     byte offset by (`Define(d, b, :add, off ÷ (ew÷8))`, `ingest_body.jl:534`)
#     and which is therefore the ROOT's bytes-per-cell SCALE, read off
#     `_root_scale`.
#
# For the corpus pairing those differ ON EVERY SIDE:
#
#   | side  | root                        | scale | stamp | cell of element k |
#   |-------|-----------------------------|-------|-------|-------------------|
#   | src   | `julia.gc_alloc_obj` (byte) | 1     | 8     | `src + 8k`        |
#   | dst   | `alloca i64` (word)         | 8     | 64    | `dst + k`         |
#
# and the cell-map argument is that each side is an INDEPENDENT address
# computation off its own root; the shared quantity is the 64-bit VALUE, which
# occupies exactly ONE cell in BOTH tiers (byte tier: at the field's base byte
# address, `+1…+7` never named — the bennettvm-416r.13 / 9n3y / vbv9 convention;
# word tier: cell `k`). So `K = N/8` and element `k` is `src+8k → dst+k`.
#
# # THE K=1 TRAP — why gate (b) exists and why a K=1-only file proves NOTHING
#
# `_check_scale_coherence!`'s vacuity exemption (`instructions.jl:593`) skips a
# node whose emitted and intended cells COINCIDE — canonically offset 0. At
# `K == 1` the only offset IS 0, so an arena-side node wrongly stamped 64 passes
# (SC) SILENTLY. That is precisely how the pre-4y0d vbv9 defect stayed green
# behind `test_vbv9_arena_memcpy.jl`'s K=1 pins, and the whole corpus is K=1.
# Gate (b) is therefore the load-bearing gate of this file: it asserts
# `(8, 8)` on the src side at `k = 1`, where a mis-stamp is visible.
#
# # What this file pins
#
#   (a) K=1 CORPUS SHAPE — arena src (`gep i8 %obj, 16`) → `alloca i64` dst
#       extracts `:ok`; per-side stamps `(0,8)` / `(0,64)`; the VALUE width is
#       64 on both the `IRLoad` and the `IRStore`.
#   (b) K=2 ARENA-SRC — the (SC) vacuity trap. src offsets `{(0,8),(8,8)}`,
#       dst offsets `{(0,64),(8,64)}`, i.e. src cells `{+0,+8}` and dst cells
#       `{+0,+1}`. A HEAD-style single-stamp emission would put src element 1
#       at cell +1 and read garbage.
#   (c) K=2 MIRROR (site #6's direction) — `alloca [2 x i64]` src → arena dst.
#       Same discipline, transposed.
#   (d) CROSS-WIDTH REJECT — `memcpy(alloca i8 dst, arena src, 8)`: an arena
#       side is fixed at 64, so Predicate 8b must fail loud (doih's G6 analogue).
#   (e) SAME-ROOT REJECT — the generalised Predicate 7. `memcpy(gep i8 %obj, 0,
#       gep i8 %obj, 8, 8)` is semantically memmove and MUST keep failing loud.
#       Load-bearing: route R1 bypasses BennettVM's runtime overlap check
#       (`forward(::IntrinsicMemcpy)`, `intrinsics_bulk.jl:117-121`) because it
#       never emits an `IntrinsicMemcpy`, so this extraction-time guard REPLACES
#       that check rather than adding one.
#   (f) `ptr_cells=false` BYTE-IDENTITY — the SAME fixtures still fail loud with
#       the UNCHANGED Predicate-6 message on the circuit path. The circuit model
#       has no gc_alloc cell and no history tape.
#   (g) NON-8-ALIGNED ARENA OFFSET REJECT — `gep i8 %obj, 4` as the memcpy src.
#       (SC) does NOT catch this (a byte GEP at 4 is perfectly scale-coherent);
#       the byte-tier convention places a 64-bit value in ONE cell at its base
#       byte address, so an 8-byte chunk starting at byte 4 has no faithful
#       single-cell gather. A genuinely NEW guard, not a copy of vbv9.
#   (h) VARIABLE-OFFSET ARENA REJECT — `gep i8 %obj, i64 %n`: the arena root
#       resolves but the offset is not a compile-time constant, so alignment is
#       unprovable. Rule 1 refusal.
#   (i) THE CORPUS GATE — the push! set advances from wall 9 to wall 10 (the
#       `ptrtoint %memory_data3` base-cancelling cluster, Bennett-583s /
#       Bennett-foz5). See `docs/design/sy29_scout.md` §9.
#
# Rule 5: no LLVM formatting, instruction ordering or `%NNN` naming is pinned —
# every assertion is programmatic over extracted `IRInst` nodes, or over a
# fail-loud message's NON-NUMERAL anchors (the Bennett-0ncn lesson).
#
# Ref: `docs/design/sy29_scout.md` (the ratified design),
#      `src/extract/instructions.jl` (`_handle_memcpy_arm`, `_gc_alloc_root_ref`,
#      `_gc_alloc_root_offset`, `_root_scale`),
#      `../BennettVM.jl/test/test_sy29_arena_src_vm.jl` (the downstream E2E).

using Test
import Bennett
using Bennett: extract_parsed_ir_from_ll

_sy29_insts(pir) = reduce(vcat, [b.instructions for b in pir.blocks];
                          init = Bennett.IRInst[])

function _sy29_extract(ir::AbstractString, fn::AbstractString; cells::Bool=true)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        return extract_parsed_ir_from_ll(path; entry_function = fn,
                                         ptr_cells = cells)
    end
end

function _sy29_msg(ir::AbstractString, fn::AbstractString; cells::Bool=true)
    try
        _sy29_extract(ir, fn; cells = cells)
        return ""
    catch e
        e isa InterruptException && rethrow()
        return sprint(showerror, e)
    end
end

# Every `(offset_bytes, elem_width)` pair emitted off a given base — the cell
# map as a pinned object rather than a prose claim (the `_bvmd_offsets` idiom).
_sy29_offsets(pir, base::Symbol) =
    Set((o.offset_bytes, o.elem_width) for o in _sy29_insts(pir)
        if o isa Bennett.IRPtrOffset && o.base isa Bennett.SSAOperand &&
           o.base.name === base)

# The cell an emitted offset node resolves to, computed exactly the way
# BennettVM computes it (`Define(d, b, :add, off ÷ (ew÷8))`).
_sy29_cell(p) = p[1] ÷ (p[2] ÷ 8)

# The unchanged Predicate-6 SRC reject (the circuit-path byte-identity anchor).
_is_37mt_src_wall(msg) =
    occursin("src operand is not alloca-backed", msg) &&
    occursin("Bennett-37mt", msg)

# ---------------------------------------------------------------------------
# Fixtures. Every one carries the distilled-corpus datalayout so the byte/word
# tiers are unambiguous.
# ---------------------------------------------------------------------------
const _SY29_DL = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"
"""

const _SY29_DECLS = """
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
"""

# (a) THE CORPUS SHAPE, distilled: arena `+16` → `alloca i64`, N = 8, K = 1.
const _SY29_K1_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_k1(ptr %task, ptr %tag) {
top:
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %slot = alloca i64, align 8
  %fld = getelementptr inbounds i8, ptr %box, i32 16
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %slot, ptr align 8 %fld, i64 8, i1 false)
  %v = load i64, ptr %slot, align 8
  ret i64 %v
}
"""

# (b) THE K=2 ARENA-SRC TRAP: two cells copied out of the box at bytes 8 and 16
# into an `alloca [2 x i64]`. At K = 2 the second element's offset is NON-ZERO,
# so (SC)'s vacuity exemption no longer hides a wrong stamp.
const _SY29_K2_SRC_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_k2_src(ptr %task, ptr %tag) {
top:
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %slot = alloca [2 x i64], align 8
  %fld = getelementptr inbounds i8, ptr %box, i32 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %slot, ptr align 8 %fld, i64 16, i1 false)
  %v = load i64, ptr %slot, align 8
  ret i64 %v
}
"""

# (c) THE K=2 MIRROR (corpus site #6's direction): `alloca [2 x i64]` → arena.
const _SY29_K2_DST_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_k2_dst(ptr %task, ptr %tag) {
top:
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %slot = alloca [2 x i64], align 8
  %fld = getelementptr inbounds i8, ptr %box, i32 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %fld, ptr align 8 %slot, i64 16, i1 false)
  ret i64 0
}
"""

# (d) CROSS-WIDTH: an `alloca i8` dst against an arena src fixed at 64.
const _SY29_XWIDTH_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_xwidth(ptr %task, ptr %tag) {
top:
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %slot = alloca i8, i32 8, align 1
  %fld = getelementptr inbounds i8, ptr %box, i32 16
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %slot, ptr align 8 %fld, i64 8, i1 false)
  ret i64 0
}
"""

# (e) SAME ROOT on both sides — semantically memmove, and route R1 has no
# overlap backstop (it never emits an `IntrinsicMemcpy`, so BVM's runtime
# overlap check is not in the path).
const _SY29_SAMEROOT_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_sameroot(ptr %task, ptr %tag) {
top:
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %d = getelementptr inbounds i8, ptr %box, i32 0
  %s = getelementptr inbounds i8, ptr %box, i32 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %s, i64 8, i1 false)
  ret i64 0
}
"""

# (g) SUB-CELL ARENA OFFSET — byte 4 of the box. Perfectly scale-coherent, so
# (SC) says nothing; the byte-tier single-cell gather is what breaks.
const _SY29_MISALIGN_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_misalign(ptr %task, ptr %tag) {
top:
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %slot = alloca i64, align 8
  %fld = getelementptr inbounds i8, ptr %box, i32 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %slot, ptr align 8 %fld, i64 8, i1 false)
  ret i64 0
}
"""

# (j) THE EXECUTED MISCOMPILE (hostile-review D2, reviewer probe `p2_overlap_vm`).
# The arena is a MONOTONE BUMP, so a 16-byte box %a is immediately followed by
# %b and `%a + 24` IS `%b + 8`. dst is rooted at %a, src at %b: DISTINCT ROOTS,
# GENUINELY OVERLAPPING RANGES. Pre-D2 this extracted and ran, giving s = 222
# against an oracle of 333. Predicate 6d refuses it because the dst range
# [24, 40) leaves %a's own 16-byte object.
const _SY29_OVERLAP_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_bump_overlap(ptr %t, ptr %g, i64 %x, i64 %y) {
top:
  %a  = call ptr @julia.gc_alloc_obj(ptr %t, i64 16, ptr %g)
  %b  = call ptr @julia.gc_alloc_obj(ptr %t, i64 32, ptr %g)
  %b0 = getelementptr inbounds i8, ptr %b, i32 0
  %b8 = getelementptr inbounds i8, ptr %b, i32 8
  store i64 %x, ptr %b0, align 8
  store i64 %y, ptr %b8, align 8
  %ad = getelementptr inbounds i8, ptr %a, i32 24
  call void @llvm.memcpy.p0.p0.i64(ptr %ad, ptr %b0, i64 16, i1 false)
  ret i64 0
}
"""

# (j2) THE SECOND SYMPTOM of the same hole: an arena SRC range running past its
# own reservation, which silently READ THE NEXT OBJECT (`leak = 999`).
const _SY29_SRC_OOB_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_src_oob(ptr %t, ptr %g) {
top:
  %a = call ptr @julia.gc_alloc_obj(ptr %t, i64 24, ptr %g)
  %slot = alloca [2 x i64], align 8
  %sp = getelementptr inbounds i8, ptr %a, i32 16
  call void @llvm.memcpy.p0.p0.i64(ptr %slot, ptr %sp, i64 16, i1 false)
  ret i64 0
}
"""

# (j3)/(j4) THE PRE-EXISTING alloca↔alloca HOLE (reviewer probes A1/A2), which
# HEAD had before sy29 and which the generalised predicate now owns. `%o`
# reserves 2×i64 = 16 bytes; the copy addresses [24, 40) / [0, 32).
const _SY29_A2_SRC_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_a2_src(i64 %x) {
top:
  %o = alloca i64, i32 2, align 8
  %slot = alloca [2 x i64], align 8
  %sp = getelementptr inbounds i8, ptr %o, i32 24
  call void @llvm.memcpy.p0.p0.i64(ptr %slot, ptr %sp, i64 16, i1 false)
  ret i64 0
}
"""

const _SY29_A2_DST_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_a2_dst(i64 %x) {
top:
  %o = alloca i64, i32 2, align 8
  %src = alloca [4 x i64], align 8
  call void @llvm.memcpy.p0.p0.i64(ptr %o, ptr %src, i64 32, i1 false)
  ret i64 0
}
"""

# (j5) THE ARENA-DST CLOBBER VARIANT (reviewer variant A4): the mirror
# direction walking off the end of its own arena object.
const _SY29_ARENA_DST_OOB_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_arena_dst_oob(ptr %t, ptr %g) {
top:
  %a = call ptr @julia.gc_alloc_obj(ptr %t, i64 24, ptr %g)
  %slot = alloca [2 x i64], align 8
  %dp = getelementptr inbounds i8, ptr %a, i32 16
  call void @llvm.memcpy.p0.p0.i64(ptr %dp, ptr %slot, i64 16, i1 false)
  ret i64 0
}
"""

# (k) ARENA → ARENA, K = 2 (reviewer probe `p7_a2a`). Two DISTINCT arena roots,
# both ranges IN-OBJECT. Admitted by the arm and — before this fix cycle —
# exercised by NO test. Both sides are byte tier, so both stamp 8.
const _SY29_A2A_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_a2a(ptr %t, ptr %g, i64 %x, i64 %y) {
top:
  %a = call ptr @julia.gc_alloc_obj(ptr %t, i64 24, ptr %g)
  %b = call ptr @julia.gc_alloc_obj(ptr %t, i64 24, ptr %g)
  %a8 = getelementptr inbounds i8, ptr %a, i32 8
  %a16 = getelementptr inbounds i8, ptr %a, i32 16
  store i64 %x, ptr %a8, align 8
  store i64 %y, ptr %a16, align 8
  %b0 = getelementptr inbounds i8, ptr %b, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr %b0, ptr %a8, i64 16, i1 false)
  %b8 = getelementptr inbounds i8, ptr %b, i32 8
  %r0 = load i64, ptr %b0, align 8
  %r1 = load i64, ptr %b8, align 8
  %s = add i64 %r0, %r1
  ret i64 %s
}
"""

# (h) VARIABLE-OFFSET ARENA SRC — the root resolves, the offset does not.
const _SY29_VAROFF_LL = _SY29_DL * _SY29_DECLS * """
define i64 @sy29_varoff(ptr %task, ptr %tag, i64 %n) {
top:
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %slot = alloca i64, align 8
  %fld = getelementptr inbounds i8, ptr %box, i64 %n
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %slot, ptr align 8 %fld, i64 8, i1 false)
  ret i64 0
}
"""

@testset "Bennett-sy29 arena-root memcpy under ptr_cells (xkl wall 9)" begin

    # ======================================================================
    # (a) THE CORPUS SHAPE — K = 1, arena src → alloca dst.
    # ======================================================================
    @testset "(a) K=1 arena-src memcpy extracts with per-side stamps" begin
        pir = _sy29_extract(_SY29_K1_LL, "sy29_k1")
        insts = _sy29_insts(pir)

        # The src address is stamped at the ARENA's byte scale ...
        @test _sy29_offsets(pir, :fld) == Set([(0, 8)])
        # ... and the dst address at the ALLOCA's word scale.
        @test _sy29_offsets(pir, :slot) == Set([(0, 64)])

        # The VALUE width is 64 on BOTH sides — one whole Int64 cell.
        lds = [i for i in insts if i isa Bennett.IRLoad]
        sts = [i for i in insts if i isa Bennett.IRStore]
        @test any(l -> l.width == 64, lds)
        @test length(sts) == 1
        @test sts[1].width == 64

        # Exactly one quad: two IRPtrOffset (one per side) + one IRLoad + one
        # IRStore. Counted off the memcpy's OWN bases — the `%fld` GEP
        # instruction independently emits its own IRPtrOffset off `:box`, which
        # is not part of the quad.
        pos = [i for i in insts if i isa Bennett.IRPtrOffset &&
                                   i.base isa Bennett.SSAOperand &&
                                   i.base.name in (:fld, :slot)]
        @test length(pos) == 2
        # ... and no bulk-copy IRCall was emitted (route R1, not R2).
        @test !any(i -> i isa Bennett.IRCall &&
                        occursin("memcpy", String(i.callee)), insts)

        # The gc_alloc_obj call survived as an IRCall (the arena root).
        @test any(i -> i isa Bennett.IRCall &&
                       occursin("gc_alloc_obj", String(i.callee)), insts)
    end

    # ======================================================================
    # (b) THE K=2 TRAP — the load-bearing gate of this file.
    # ======================================================================
    @testset "(b) K=2 arena-src offsets are BYTE-true at k=1" begin
        pir = _sy29_extract(_SY29_K2_SRC_LL, "sy29_k2_src")
        src_offs = _sy29_offsets(pir, :fld)
        dst_offs = _sy29_offsets(pir, :slot)

        # SRC: byte tier. Element 1 sits at byte 8 → cell +8.
        @test (0, 8) in src_offs
        @test (8, 8) in src_offs        # a HEAD-style stamp emits (8, 64)
        @test all(p -> p[2] == 8, src_offs)
        @test Set(_sy29_cell(p) for p in src_offs) == Set([0, 8])

        # DST: word tier. Element 1 sits at byte 8 → cell +1.
        @test (0, 64) in dst_offs
        @test (8, 64) in dst_offs
        @test all(p -> p[2] == 64, dst_offs)
        @test Set(_sy29_cell(p) for p in dst_offs) == Set([0, 1])

        # NON-VACUITY, stated as an inequality: the two tiers genuinely
        # disagree at k = 1, which is what makes this fixture a test.
        @test 8 ÷ (8 ÷ 8) != 8 ÷ (64 ÷ 8)

        insts = _sy29_insts(pir)
        @test count(i -> i isa Bennett.IRLoad && i.width == 64, insts) >= 2
        @test count(i -> i isa Bennett.IRStore && i.width == 64, insts) == 2
    end

    # ======================================================================
    # (c) THE MIRROR — corpus site #6's direction (alloca src → arena dst).
    # ======================================================================
    @testset "(c) K=2 arena-DST mirror is byte-true too" begin
        pir = _sy29_extract(_SY29_K2_DST_LL, "sy29_k2_dst")
        @test _sy29_offsets(pir, :fld)  == Set([(0, 8), (8, 8)])
        @test _sy29_offsets(pir, :slot) == Set([(0, 64), (8, 64)])
        insts = _sy29_insts(pir)
        @test count(i -> i isa Bennett.IRStore && i.width == 64, insts) == 2
    end

    # ======================================================================
    # (d) CROSS-WIDTH — Predicate 8b, doih's G6 analogue.
    # ======================================================================
    @testset "(d) an i8 alloca against an arena side fails loud" begin
        msg = _sy29_msg(_SY29_XWIDTH_LL, "sy29_xwidth")
        @test msg != ""
        @test occursin("cross-width", msg)
        @test occursin("Bennett-sy29", msg) || occursin("Bennett-ixiz", msg)
    end

    # ======================================================================
    # (e) SAME ROOT — the generalised Predicate 7. THE OVERLAP GUARD.
    # ======================================================================
    @testset "(e) src and dst on the SAME arena root stays refused" begin
        msg = _sy29_msg(_SY29_SAMEROOT_LL, "sy29_sameroot")
        @test msg != ""
        @test occursin("memmove", msg)
        @test occursin("Bennett-sy29", msg) || occursin("Bennett-37mt", msg)
        # ... and the refusal is NOT the generic "not alloca-backed" wall:
        # the arena root RESOLVED, and was then refused for overlap.
        @test !occursin("is not alloca-backed", msg)
    end

    # ======================================================================
    # (f) CIRCUIT-PATH BYTE-IDENTITY — `ptr_cells=false` is untouched.
    # ======================================================================
    @testset "(f) ptr_cells=false keeps the unchanged Predicate-6 message" begin
        for (ir, fn) in ((_SY29_K1_LL, "sy29_k1"),
                         (_SY29_K2_SRC_LL, "sy29_k2_src"),
                         (_SY29_MISALIGN_LL, "sy29_misalign"))
            msg = _sy29_msg(ir, fn; cells = false)
            @test msg != ""
            @test _is_37mt_src_wall(msg)
            # No sy29 breadcrumb may appear on the circuit path — the branch
            # is `ptr_cells`-gated, so it must be wholly inert here.
            @test !occursin("Bennett-sy29", msg)
        end
        # The MIRROR direction walls on the DST half of Predicate 6, also
        # byte-identically.
        msg = _sy29_msg(_SY29_K2_DST_LL, "sy29_k2_dst"; cells = false)
        @test occursin("dst operand is not alloca-backed", msg)
        @test occursin("Bennett-37mt", msg)
        @test !occursin("Bennett-sy29", msg)
    end

    # ======================================================================
    # (g) SUB-CELL ARENA OFFSET — a guard (SC) cannot supply.
    # ======================================================================
    @testset "(g) a non-8-aligned arena offset fails loud" begin
        msg = _sy29_msg(_SY29_MISALIGN_LL, "sy29_misalign")
        @test msg != ""
        @test occursin("Bennett-sy29", msg)
        @test occursin("cell-aligned", msg) || occursin("sub-cell", msg)
        # NOT a (SC) violation: `gep i8 %box, 4` is perfectly scale-coherent,
        # which is exactly why this predicate has to exist.
        @test !occursin("SCALE-COHERENCE", msg)
    end

    # ======================================================================
    # (h) VARIABLE ARENA OFFSET — unprovable alignment, Rule 1 refusal.
    # ======================================================================
    @testset "(h) a runtime-offset arena operand fails loud" begin
        msg = _sy29_msg(_SY29_VAROFF_LL, "sy29_varoff")
        @test msg != ""
        @test occursin("Bennett-sy29", msg)
        @test occursin("constant", msg) || occursin("runtime", msg)
    end

    # ======================================================================
    # (j) PREDICATE 6d — THE IN-OBJECT RANGE GUARD.
    #
    # This is the hostile review's D2. The disjointness argument Predicate 7
    # rests on ("distinct roots ⇒ disjoint ranges") is FALSE without it, and the
    # counterexample was EXECUTED, not hypothesised: the arena bump makes
    # `%a + 24` and `%b + 8` the SAME cell, so a memcpy with distinct roots
    # genuinely overlapped and this arm's ascending load-then-store miscopied it
    # (s = 222 against an oracle of 333). Route R1 never emits an
    # `IntrinsicMemcpy`, so BennettVM's runtime overlap check is not in the path
    # to catch it either.
    # ======================================================================
    @testset "(j) a range that leaves its own object fails loud" begin
        for (ir, fn, what) in (
                (_SY29_OVERLAP_LL,       "sy29_bump_overlap",   "bump-adjacent overlap"),
                (_SY29_SRC_OOB_LL,       "sy29_src_oob",        "arena src past reservation"),
                (_SY29_ARENA_DST_OOB_LL, "sy29_arena_dst_oob",  "arena dst past reservation"),
                (_SY29_A2_SRC_LL,        "sy29_a2_src",         "alloca src past reservation"),
                (_SY29_A2_DST_LL,        "sy29_a2_dst",         "alloca dst past reservation"))
            msg = _sy29_msg(ir, fn)
            # ANCHOR: $what
            @test msg != ""
            @test occursin("Bennett-sy29", msg)
            @test occursin("leaves its own object", msg)
            @test occursin("_root_byte_offset", msg)
        end
    end

    @testset "(j2) the alloca↔alloca hole is closed on the CIRCUIT path too" begin
        # The pre-existing hole was not `ptr_cells`-specific: HEAD's alloca arm
        # had no bounds check at all. The generalised predicate owns both paths,
        # so the refusal must hold with ptr_cells=false as well. (`_root_scale`
        # resolves an alloca reservation regardless of the flag.)
        for (ir, fn) in ((_SY29_A2_SRC_LL, "sy29_a2_src"),
                         (_SY29_A2_DST_LL, "sy29_a2_dst"))
            msg = _sy29_msg(ir, fn; cells = false)
            @test msg != ""
            @test occursin("leaves its own object", msg)
        end
    end

    @testset "(j3) an EXACTLY-fitting range is still admitted" begin
        # The boundary control: `roff + N == cap_bytes` must PASS, or 6d would
        # reject the corpus itself (`alloca i64` + N = 8 is exactly full).
        pir = _sy29_extract(_SY29_K1_LL, "sy29_k1")
        @test !isempty(_sy29_insts(pir))
        # ... and gate (b)'s K=2 fixture copies bytes [8,24) of a 24-byte box:
        # also exactly flush against the end.
        pir2 = _sy29_extract(_SY29_K2_SRC_LL, "sy29_k2_src")
        @test _sy29_offsets(pir2, :fld) == Set([(0, 8), (8, 8)])
    end

    # ======================================================================
    # (k) ARENA → ARENA, K = 2 — the shape the arm admits and no test covered
    #     (reviewer probe `p7_a2a`, promoted to a permanent gate).
    # ======================================================================
    @testset "(k) arena→arena K=2 stamps BOTH sides at the byte tier" begin
        pir = _sy29_extract(_SY29_A2A_LL, "sy29_a2a")
        # BOTH roots are byte tier, so both sides stamp 8 — the degenerate case
        # of the per-side rule, and the one where a single shared stamp would
        # coincidentally look right. Gate (b) is what distinguishes them.
        @test _sy29_offsets(pir, :a8) == Set([(0, 8), (8, 8)])
        @test _sy29_offsets(pir, :b0) == Set([(0, 8), (8, 8)])
        insts = _sy29_insts(pir)
        @test count(i -> i isa Bennett.IRLoad && i.width == 64, insts) >= 2
        @test count(i -> i isa Bennett.IRStore && i.width == 64, insts) == 4
    end

    # ======================================================================
    # (i) THE CORPUS GATE — wall 9 → wall 10.
    #
    # After sy29 the push! set walls at the ROOT body's
    #   %12 = ptrtoint ptr %memory_data3 to i64
    # whose base-cancelling difference ESCAPES through `udiv exact` into two
    # closure-env stores. `Bennett-foz5` §4a clause (iii) requires EVERY use of
    # the `sub` to be an `icmp`; here the sole use is the `udiv`, so the
    # confined-value contract legitimately declines it. Wall 10's contract is
    # NOT designed here — see `docs/design/sy29_scout.md` §9.
    # ======================================================================
    @testset "(i) push! corpus advances from wall 9 to wall 10" begin
        f = n::Int64 -> begin
            v = Int64[]; push!(v, n); @inbounds v[1]
        end
        msg = try
            Bennett.extract_parsed_ir_set_from_julia(f, Tuple{Int64};
                                                     ptr_cells = true)
            ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test msg != ""                        # walls 10/11 remain
        # NEW LOAD-BEARING NEGATIVE — wall 9 is CLEARED, so a 37mt reject is
        # now a REGRESSION rather than the expected wall.
        @test !occursin("Bennett-37mt", msg)
        @test !occursin("Bennett-sy29", msg)
        # POSITIVE, wall 10 — non-numeral anchors only (Bennett-0ncn),
        # disjoined because WHICH predicate is named first is not a contract.
        @test occursin("Bennett-583s", msg) || occursin("Bennett-foz5", msg)
        @test occursin("ptrtoint", msg)
        # Walls 3/5/6/7/8 stay cleared.
        @test !(occursin("Bennett-p06b", msg) && occursin("gc_alloc_obj", msg))
        for neg in ("Bennett-jbko", "Bennett-iwo9", "Bennett-lgzx", "memmove",
                    "BYTE-granular getelementptr", "Bennett-bvmd",
                    "store of non-integer type")
            @test !occursin(neg, msg)
        end
    end
end
