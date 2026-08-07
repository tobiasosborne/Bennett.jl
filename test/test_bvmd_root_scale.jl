# test/test_bvmd_root_scale.jl — bead Bennett-bvmd (xkl frontier wall 8):
# ROOT-SCALE COHERENCE, and the byte-stamped admission of `julia.gc_alloc_obj`
# aggregate-store targets it makes sound.
#
# # The invariant (SC)
#
# BennettVM is CELL-addressed: one `Int64` per cell, a pointer IS a cell index,
# and `IRPtrOffset(dest, base, offset_bytes, elem_width)` lowers to
# `Define(dest, base, :add, offset_bytes ÷ (elem_width÷8))`
# (`BennettVM/src/ir/ingest_body.jl:534`). So `elem_width` is nothing but the
# BYTES-PER-CELL SCALE of the object being addressed — and that scale is already
# fixed, per allocation shape, by BennettVM code that ships today:
#
#   | root shape                  | scale (bytes/cell) | cap (cells) | authority |
#   |-----------------------------|--------------------|-------------|-----------|
#   | `IRAlloca(d, ew, n)`        | `ew ÷ 8`           | `n`         | `_lower_alloca!` reserves `n` cells; "`elem_width` (in bits) does NOT enter the address" (ingest_body.jl:581-586) |
#   | `julia.gc_alloc_obj(_,nb,_)`| **1**              | `nb`        | `_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nb)` (intrinsics.jl:256-257) |
#   | `malloc` / `calloc`         | **8**              | `nb ÷ 8`    | `_alloc_cells(::IntrinsicMalloc) = _cell_count(nb)` (intrinsics.jl:246) |
#   | param / global / phi / load | UNKNOWN            | —           | no reservation exists in this function |
#
#   (SC) For every pointer root `R` whose scale is KNOWN, every `IRPtrOffset` /
#        `IRVarGEP` derived from `R` must carry `elem_width == 8 · scale(R)`.
#
# (SC) is not an invented tag: the extractor READS the scale off the same
# allocator table BVM's `_alloc_cells` implements, exactly as
# `_alloca_reservation` is already the single source of truth shared between the
# alloca arm and `_p06b_alloca_cells`.
#
# # What this file pins
#
#   (A) BYTE-TIER EMISSION — a `{ptr,ptr}` aggregate store into a
#       `julia.gc_alloc_obj(_, 24, _)` target decomposes at `elem_width = 8`
#       (cells +0/+8), which is xkl wall 8 cleared.
#   (B) WORD-TIER NEGATIVE CONTROL — the same store into `malloc(24)` still
#       emits `elem_width = 64`. The C tier is byte-identical.
#   (C) UNION CONTROL (bennettvm-416r.13) — a literal `{i64,ptr}` header GEP
#       whose base is a `load ptr, ptr @"jl_global#N"` singleton has NO
#       allocation root, and MUST still stamp 8 via the shipped TYPE predicate.
#       The provenance rule is a UNION with it, never a replacement — a
#       replacement would silently demote the shipped singleton layout
#       (length@byte-cell 0, data-ptr@byte-cell 8) to word granularity.
#   (D) CLASS-D AGREEMENT — the finding the bead text does not contain
#       (scout §2, probe `b04_stamps.jl`, promoted here to a permanent test):
#       byte offset 8 of ONE corpus object was sent to cell +8 by `gep i8` and
#       to cell +1 by `gep {ptr,ptr} 0,1`. Two cells for one field, live in the
#       ROOT body today. Both must now land on +8.
#   (E) TYPED-ARRAY CONTROL — (SC) is PER-ROOT AGREEMENT, not a byte/word
#       binary: `alloca i32, i32 8` (scale 4) + `gep i32 …, 3` (stamp 32) is
#       coherent and stays byte-identical. This is the control that refutes a
#       blanket byte-normalisation of every reservation.
#   (F) z2ia REFUSAL — `alloca [9 x i64]` (scale 8, 9 cells) addressed by
#       `gep i8 …, 56` (cell +56) is the corpus closure-env write. Refused
#       LOUDLY with both cell numbers, converting a silent adjacent-allocation
#       clobber (which `bennettvm-pdqx` does NOT catch) into a crash. Admitting
#       it needs byte-granular reservations and stays filed as Bennett-z2ia.
#   (G) STREAM BACKSTOP — (SC) is a property of the EMITTED IRPtrOffset stream,
#       so ONE check covers all nine construction sites (`instructions.jl` ×6,
#       `heap.jl` ×2, `vectors.jl`) including the six no one has audited. Pinned
#       with a shape no per-site stamp change touches.
#   (H) Bennett-4y0d — a K≥2 global-src memcpy into a `gc_alloc` dst.
#   (I) The CORPUS gate: the push! set advances to the CURRENT wall. Wall 8 at
#       this bead; ADVANCED to wall 10 by Bennett-sy29 (which cleared wall 9,
#       the arena-src memcpy) — the gate tracks the frontier, not a fixed wall.
#
# Rule 5: no LLVM formatting, instruction ordering or `#NNN` naming is pinned —
# every assertion is programmatic over extracted `IRInst` nodes or over a
# fail-loud message's NON-NUMERAL anchors (Bennett-0ncn).

using Test
import Bennett
using Bennett: extract_parsed_ir_from_ll

_bvmd_insts(pir) = reduce(vcat, [b.instructions for b in pir.blocks];
                          init = Bennett.IRInst[])

function _bvmd_extract(ir::AbstractString, fn::AbstractString; cells::Bool=true)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        return extract_parsed_ir_from_ll(path; entry_function = fn,
                                         ptr_cells = cells)
    end
end

function _bvmd_msg(ir::AbstractString, fn::AbstractString; cells::Bool=true)
    try
        _bvmd_extract(ir, fn; cells = cells)
        return ""
    catch e
        return sprint(showerror, e)
    end
end

# Every offset/elem_width pair the extraction emitted, as a Set — the coherence
# table as a pinned object rather than a prose claim.
_bvmd_offsets(pir, base::Symbol) =
    Set((o.offset_bytes, o.elem_width) for o in _bvmd_insts(pir)
        if o isa Bennett.IRPtrOffset && o.base isa Bennett.SSAOperand &&
           o.base.name === base)

# Bead names that must NEVER appear in a bvmd fail-loud (each is a wall this arc
# does not touch; a hit means the message was misattributed).
const _BVMD_FORBIDDEN = ("Bennett-lgzx", "Bennett-jbko", "Bennett-iwo9",
                         "Bennett-6bu3", "Bennett-cc0")

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# (A)/(D) THE CORPUS SHAPE, distilled. One `julia.gc_alloc_obj(_, 24, _)` box
# carrying every access class the scout's §2 census found on `%"new::Array"`:
#   class A — byte field-init store  `gep i8 %obj, 8`
#   class E — whole-aggregate store  `store {ptr,ptr} %agg, ptr %obj`
#   class D — two-index struct GEPs  `gep {ptr,ptr} %obj, 0, {0,1}`
#   class B — byte access at +16     `gep i8 %obj, 16`
const _BVMD_BYTE_LL = """
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
define i64 @bvmd_byte_tier(ptr %task, ptr %tag, ptr %a, ptr %b) {
entry:
  %obj = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %b8 = getelementptr inbounds i8, ptr %obj, i32 8
  store ptr null, ptr %b8, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %obj, align 8
  %w0 = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %w1 = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1
  %r0 = load i64, ptr %w0, align 8
  %r1 = load i64, ptr %w1, align 8
  %b16 = getelementptr inbounds i8, ptr %obj, i32 16
  %r2 = load i64, ptr %b16, align 8
  %s0 = add i64 %r0, %r1
  %s1 = add i64 %s0, %r2
  ret i64 %s1
}
"""

# (B) WORD-TIER NEGATIVE CONTROL — the same aggregate store into a `malloc(24)`
# target. scale 8 ⇒ 8·scale = 64, precisely the stamp this arm already emits.
const _BVMD_WORD_LL = """
declare ptr @malloc(i64)
define i64 @bvmd_word_tier(ptr %a, ptr %b) {
entry:
  %slot = call ptr @malloc(i64 24)
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  %w1 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 1
  %r1 = load i64, ptr %w1, align 8
  ret i64 %r1
}
"""

# (C) UNION CONTROL — the bennettvm-416r.13 singleton. `load ptr, ptr @g` emits
# NO IRLoad (it aliases the dest to the global), so the header GEP's base has NO
# allocation root: scale UNKNOWN. The shipped TYPE predicate must still stamp 8.
const _BVMD_UNION_LL = """
@"jl_global#93" = external global ptr
define i64 @bvmd_union_singleton() {
entry:
  %m = load ptr, ptr @"jl_global#93", align 8
  %len_ptr = getelementptr inbounds { i64, ptr }, ptr %m, i32 0, i32 0
  %len = load i64, ptr %len_ptr, align 8
  %data_ptr = getelementptr inbounds { i64, ptr }, ptr %m, i32 0, i32 1
  %data = load ptr, ptr %data_ptr, align 8
  %e0 = load i64, ptr %data, align 8
  %r = add i64 %len, %e0
  ret i64 %r
}
"""

# (E) TYPED-ARRAY CONTROL — `alloca i32, i32 8` is scale 4, and `gep i32 …, 3`
# stamps 32 = 8·4. COHERENT. A blanket byte-normalisation of reservations would
# make this root scale 1 and turn a shipped, correct program into a violation.
const _BVMD_TYPED_LL = """
define i64 @bvmd_typed_array(i32 %x) {
entry:
  %a = alloca i32, i32 8, align 4
  %p = getelementptr inbounds i32, ptr %a, i32 3
  store i32 %x, ptr %p, align 4
  %v = load i32, ptr %p, align 4
  %r = zext i32 %v to i64
  ret i64 %r
}
"""

# (F) z2ia — the ROOT body's own closure-env frame, verbatim in shape
# (scout §7.1, probe `b09_alloca.jl`): `alloca [9 x i64]` reserves NINE cells
# and Julia codegen addresses it with `gep i8 …, 56` → cell +56, 48 cells past
# its own reservation, inside the NEXT allocation.
const _BVMD_Z2IA_LL = """
define i64 @bvmd_z2ia(i64 %x) {
entry:
  %env = alloca [9 x i64], align 8
  %g = getelementptr inbounds i8, ptr %env, i32 56
  store i64 %x, ptr %g, align 8
  %v = load i64, ptr %g, align 8
  ret i64 %v
}
"""

# (R4) control — a GENUINE `[N x i8]` alloca with 8-bit traffic. Coherent at
# scale 1, so nothing is normalised, and `lower()` must NOT refuse it: the
# refusal keys on the actual width incompatibility, never on the reservation's
# shape (Bennett-munq's whole tier looks like this).
const _BVMD_I8ARR_LL = """
define i64 @bvmd_i8arr(i8 %x) {
entry:
  %a = alloca [16 x i8], align 1
  %g = getelementptr inbounds i8, ptr %a, i32 3
  store i8 %x, ptr %g, align 1
  %v = load i8, ptr %g, align 1
  %r = zext i8 %v to i64
  ret i64 %r
}
"""

# (V) THE IRVarGEP ARM. A RUNTIME-index GEP has no constant cell, so the
# vacuity exemption must NOT reach it — the predicate is bare stamp equality.
# HOSTILE-REVIEW DEFECT D1: the first revision set both cell numbers to -1 for
# an IRVarGEP, so the exemption swallowed EVERY variable-index node and the arm
# was DEAD CODE. `gep i64, ptr %obj, i64 %i` off a byte-tier `gc_alloc` box
# extracted silently at `elem_width = 64` while BennettVM strides an IRVarGEP by
# ONE CELL per index unit — an 8x misaddress, silent.
const _BVMD_VARGEP_BYTE_LL = """
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
define i64 @bvmd_vargep_byte(ptr %task, ptr %tag, i64 %i) {
entry:
  %obj = call ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %tag)
  %g = getelementptr inbounds i64, ptr %obj, i64 %i
  %v = load i64, ptr %g, align 8
  ret i64 %v
}
"""

# ... and the word-tier direction: a runtime i32 index into an 8-byte-cell
# object. Byte offset 4i is not expressible as a cell of an `alloca i64` array.
const _BVMD_VARGEP_WORD_LL = """
define i64 @bvmd_vargep_word(i64 %i) {
entry:
  %a = alloca i64, i32 8, align 8
  %g = getelementptr inbounds i32, ptr %a, i64 %i
  %v = load i32, ptr %g, align 4
  %r = zext i32 %v to i64
  ret i64 %r
}
"""

# COHERENT CONTROL — a runtime index whose stamp IS the root's scale must stay
# silent, so the arm is discriminating rather than a blanket IRVarGEP refusal.
const _BVMD_VARGEP_OK_LL = """
define i64 @bvmd_vargep_ok(i64 %i) {
entry:
  %a = alloca i64, i32 8, align 8
  %g = getelementptr inbounds i64, ptr %a, i64 %i
  %v = load i64, ptr %g, align 8
  ret i64 %v
}
"""

# (F2) THE MIXED OBJECT — the case NO reservation can serve. The same frame is
# addressed at byte granularity (`gep i8 …, 8` → cell +8) AND at word
# granularity (`gep i64 …, 2` → cell +2). Byte-normalising it would break the
# second; leaving it word breaks the first. This is `bennettvm-jb6w`'s hazard,
# and it is the case the guard exists to make LOUD.
const _BVMD_MIXED_LL = """
define i64 @bvmd_mixed(i64 %x) {
entry:
  %env = alloca [9 x i64], align 8
  %gb = getelementptr inbounds i8, ptr %env, i32 8
  store i64 %x, ptr %gb, align 8
  %gw = getelementptr inbounds i64, ptr %env, i32 2
  %v = load i64, ptr %gw, align 8
  ret i64 %v
}
"""

# (G) STREAM BACKSTOP — an `i64`-strided GEP off a byte-tier root. No stamp
# change in this arc touches the single-index integer-GEP arm (it correctly
# reports its own source element width), so ONLY a check over the emitted
# stream can see that 64 disagrees with the root's scale of 1.
const _BVMD_BACKSTOP_LL = """
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
define i64 @bvmd_backstop(ptr %task, ptr %tag) {
entry:
  %obj = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %g = getelementptr inbounds i64, ptr %obj, i32 1
  %v = load i64, ptr %g, align 8
  ret i64 %v
}
"""

# (G2) THE VACUOUS DISAGREEMENT, and the D2 hazard that makes it non-trivial.
# `gep i8 %a, 0` off a word-tier alloca stamps 8 against a scale of 8 — but byte
# offset 0 is cell +0 under EVERY stamp, so nothing is addressed wrongly and the
# guard MUST stay silent. MEASURED: without this exemption `test_40ys`
# (G)/(H)/(K) go red on an offset of zero. `%g8` is the D2 hazard: the exempt
# GEP's RESULT is a fresh byte-granular base, and an offset off IT is a genuine
# violation which the FULL-CHAIN walk must still catch.
const _BVMD_ZERO_LL = """
define i64 @bvmd_zero_offset(i64 %x) {
entry:
  %a = alloca i64, i32 4, align 8
  %g0 = getelementptr inbounds i8, ptr %a, i32 0
  store i64 %x, ptr %g0, align 8
  %v = load i64, ptr %g0, align 8
  ret i64 %v
}
"""

const _BVMD_ZERO_THEN_BYTE_LL = """
define i64 @bvmd_zero_then_byte(i64 %x) {
entry:
  %a = alloca i64, i32 4, align 8
  %g0 = getelementptr inbounds i8, ptr %a, i32 0
  %g8 = getelementptr inbounds i8, ptr %g0, i32 8
  store i64 %x, ptr %g8, align 8
  %v = load i64, ptr %g8, align 8
  ret i64 %v
}
"""

# ... and the same chain MIXED with a word access. The byte leg is TWO GEPs deep
# behind an offset-0 hop, so this only fails loud if the walk goes all the way
# to the allocation root at every node — the assertion that distinguishes the
# offset-0 exemption from p06b's dropped D2 one-level carve-out.
const _BVMD_CHAIN_MIXED_LL = """
define i64 @bvmd_chain_mixed(i64 %x) {
entry:
  %a = alloca i64, i32 4, align 8
  %g0 = getelementptr inbounds i8, ptr %a, i32 0
  %g8 = getelementptr inbounds i8, ptr %g0, i32 8
  store i64 %x, ptr %g8, align 8
  %gw = getelementptr inbounds i64, ptr %a, i32 2
  %v = load i64, ptr %gw, align 8
  ret i64 %v
}
"""

# (P4c) BYTE-TIER CAPACITY — a 2-field `{ptr,ptr}` store needs bytes [0,16);
# an 8-byte box reserves only 8 byte-cells, so the second field would clobber
# the NEXT allocation. Must refuse.
const _BVMD_CAP_LL = """
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
define i64 @bvmd_cap(ptr %task, ptr %tag, ptr %a, ptr %b) {
entry:
  %obj = call ptr @julia.gc_alloc_obj(ptr %task, i64 8, ptr %tag)
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %obj, align 8
  ret i64 0
}
"""

# (P5) WORD-TIER REJECT — the b06 probe shape, promoted to a permanent test.
# A malloc target (scale 8) addressed BOTH by its `{ptr,ptr}` field GEPs (stamp
# 64) and by a `gep i8 …, 8` (stamp 8) is genuinely two cell maps for one
# object, and stays refused. The tier-parametrised (P5) must NOT invert here.
const _BVMD_P5_WORD_LL = """
declare ptr @malloc(i64)
define i64 @bvmd_p5_word(ptr %a, ptr %b) {
entry:
  %slot = call ptr @malloc(i64 24)
  %byte8 = getelementptr inbounds i8, ptr %slot, i32 8
  store ptr null, ptr %byte8, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}
"""

# (H) Bennett-4y0d — K=2 global-src memcpy into a `gc_alloc` dst. At K=1 the
# only offset is 0, which is cell 0 under EVERY stamp — which is why the shipped
# `test_vbv9_arena_memcpy.jl` pins were green over a latent defect.
const _BVMD_4Y0D_LL = """
@_j_const_bvmd = private unnamed_addr constant [2 x i64] [i64 111, i64 222], align 8
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
define i64 @bvmd_4y0d(ptr %task, ptr %tag) {
entry:
  %obj = call ptr @julia.gc_alloc_obj(ptr %task, i64 32, ptr %tag)
  %d = getelementptr inbounds i8, ptr %obj, i32 16
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 @_j_const_bvmd, i64 16, i1 false)
  ret i64 0
}
"""

@testset "Bennett-bvmd root-scale coherence + byte-stamped admission" begin

    # ======================================================================
    # (A) BYTE-TIER EMISSION — xkl wall 8 cleared.
    # ======================================================================
    @testset "(A) gc_alloc_obj aggregate store decomposes at elem_width 8" begin
        pir = _bvmd_extract(_BVMD_BYTE_LL, "bvmd_byte_tier")
        insts = _bvmd_insts(pir)
        # The decomposition emits one IRExtractValue + IRPtrOffset + IRStore per
        # field. Exactly TWO whole-cell stores, not sixteen byte stores:
        # BennettVM's `MemoryStore` carries NO width and writes a whole cell
        # (`memory_floor.jl:156-168`), so a sub-cell store is not expressible.
        sts = [i for i in insts if i isa Bennett.IRStore]
        @test length([s for s in sts if s.width == 64]) >= 2
        offs = _bvmd_offsets(pir, :obj)
        # THE assertion: byte offsets 0 and 8, stamped 8 — cells +0 and +8.
        @test (0, 8) in offs
        @test (8, 8) in offs
        # and NOTHING off this object is word-stamped.
        @test all(p -> p[2] == 8, offs)
    end

    # ======================================================================
    # (D) CLASS-D AGREEMENT — the scout's `b04_stamps.jl` probe, permanent.
    # ======================================================================
    @testset "(D) byte GEP and struct GEP of one object land on ONE cell" begin
        pir = _bvmd_extract(_BVMD_BYTE_LL, "bvmd_byte_tier")
        offs = _bvmd_offsets(pir, :obj)
        # BVM cell = offset_bytes ÷ (elem_width÷8). Compute it, don't assert it
        # in prose.
        cells = Set(p[1] ÷ (p[2] ÷ 8) for p in offs)
        # class A (`gep i8 …, 8`), class D (`gep {ptr,ptr} 0,1`) and class E
        # (aggregate store field 1) must ALL be cell +8 — at HEAD the struct GEP
        # was cell +1 and the split was live in the corpus ROOT.
        @test 8 in cells
        @test 0 in cells
        @test 16 in cells
        # The CW-D4 split is gone FOR THIS OBJECT, and more generally for every
        # object whose allocation ROOT this function can see. SCOPE, stated
        # rather than implied: a pointer with no root here (a parameter, a
        # global, a `phi`/`select`, one round-tripped through memory, a
        # `julia.gc_loaded` launder) is scale-UNKNOWN, so neither the shared
        # stamp nor the (SC) stream check constrains it — for those, cell
        # agreement is still only checked by p06b's (P5), and only where an
        # AGGREGATE STORE targets the object. Rootless two-granularity objects
        # with no aggregate store remain unguarded; that is a disclosed
        # pre-existing hole, not something this bead closed.
        @test !(1 in cells)
        # every cell inside the 24-byte-cell reservation
        @test maximum(cells) < 24
    end

    # ======================================================================
    # (B) WORD-TIER NEGATIVE CONTROL — the C tier is byte-identical.
    # ======================================================================
    @testset "(B) malloc target keeps elem_width 64" begin
        pir = _bvmd_extract(_BVMD_WORD_LL, "bvmd_word_tier")
        offs = _bvmd_offsets(pir, :slot)
        @test (0, 64) in offs
        @test (8, 64) in offs
        @test all(p -> p[2] == 64, offs)
    end

    # ======================================================================
    # (C) UNION CONTROL — provenance NEVER replaces the type predicate.
    # ======================================================================
    @testset "(C) 416r.13 singleton header GEP still stamps 8" begin
        pir = _bvmd_extract(_BVMD_UNION_LL, "bvmd_union_singleton")
        pos = [o for o in _bvmd_insts(pir) if o isa Bennett.IRPtrOffset]
        @test !isempty(pos)
        # the data-ptr field is at byte 8 and MUST be byte-cell +8, the layout
        # the shipped 416r.13 singletons already ship.
        @test any(o -> o.offset_bytes == 8 && o.elem_width == 8, pos)
        @test all(o -> o.elem_width == 8, pos)
    end

    # ======================================================================
    # (E) TYPED-ARRAY CONTROL — (SC) is per-root agreement, not byte-vs-word.
    # ======================================================================
    @testset "(E) alloca i32 + gep i32 stays (12, 32)" begin
        pir = _bvmd_extract(_BVMD_TYPED_LL, "bvmd_typed_array")
        offs = _bvmd_offsets(pir, :a)
        @test (12, 32) in offs
        # and the gate-off path is byte-identical
        pir0 = _bvmd_extract(_BVMD_TYPED_LL, "bvmd_typed_array"; cells = false)
        @test _bvmd_offsets(pir0, :a) == offs
    end

    # ======================================================================
    # (F) z2ia — ADMITTED by use-directed byte-normalisation, ptr_cells-GATED.
    # ======================================================================
    @testset "(F) an all-byte-addressed word alloca is BYTE-NORMALISED" begin
        pir = _bvmd_extract(_BVMD_Z2IA_LL, "bvmd_z2ia")
        env = only([a for a in _bvmd_insts(pir)
                    if a isa Bennett.IRAlloca && a.dest === :env])
        # `alloca [9 x i64]` reserved NINE cells and Julia addressed cell +56.
        # The RESERVATION is widened to 72 BYTE cells, which covers it.
        @test env.elem_width == 8
        @test env.n_elems == Bennett.ConstOperand(72)
        # WIRE-COUNT NEUTRALITY on the gate path, pinned rather than asserted in
        # prose: `_lower_alloca_const_n!` allocates `elem_width * n` BITS, and
        # 64·9 == 8·72 == 576.
        @test 64 * 9 == env.elem_width * env.n_elems.value
        # ... and the access is coherent: cell +56, inside 72.
        @test (56, 8) in _bvmd_offsets(pir, :env)
        # WHY THE RESERVATION AND NOT THE ACCESSES. Re-stamping
        # `IRPtrOffset(_, env, 56, 8) → (_, env, 56, 64)` (cell +7 inside the
        # untouched 9) was BUILT and REJECTED: this pass runs PER FUNCTION, so a
        # caller would re-stamp to word cells while the CALLEE — which receives
        # the same object as a scale-UNKNOWN pointer parameter — would keep byte
        # cells. Caller writes +1, callee reads +8. Executed witness:
        # `Bennett-40ys`'s caller→callee `Pair40ys` set returned 30 for an
        # oracle of 42 (`../BennettVM.jl/test/test_40ys_closure_callee_vm.jl`
        # gate (g)). Widening the RESERVATION changes size, never addressing, so
        # it is closed under function boundaries by construction.
        pir0 = _bvmd_extract(_BVMD_Z2IA_LL, "bvmd_z2ia"; cells = false)
        env0 = only([a for a in _bvmd_insts(pir0)
                     if a isa Bennett.IRAlloca && a.dest === :env])
        @test env0.elem_width == 64
        @test env0.n_elems == Bennett.ConstOperand(9)
    end

    # ======================================================================
    # (R4) THE GATE-BACKEND REFUSAL — hostile-review defect D2.
    #
    # `ptr_cells` is an EXTRACTION flag, NOT a backend selector, and
    # `ptr_cells=true` + `lower()` is a LIVE combination (test_59zi, test_lf14).
    # So a byte-normalised alloca DOES reach the circuit backend, whose
    # shadow-tape path requires `store width == alloca elem_width`. Before this
    # bead the same `.ll` lowered fine (the circuit backend has its own coherent
    # divide-by-alloca-width scheme). Honest fail-fast, named, with the fix that
    # removes it named too.
    # ======================================================================
    @testset "(R4) a byte-normalised ParsedIR is REFUSED by lower(), by name" begin
        pir1 = _bvmd_extract(_BVMD_Z2IA_LL, "bvmd_z2ia")               # ptr_cells
        msg = try
            Bennett.lower(pir1); ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("Bennett-bvmd", msg)
        @test occursin("_bvmd_reject_normalised_alloca!", msg)   # the predicate
        @test occursin("BYTE-NORMALISED", msg)
        @test occursin("ptr_cells=false", msg)                   # the workaround
        @test occursin("shadow", msg)                            # the real fix
        # THE CONTROL that makes this a refusal and not a regression: the SAME
        # `.ll` extracted for the circuit target lowers exactly as it always did.
        pir0 = _bvmd_extract(_BVMD_Z2IA_LL, "bvmd_z2ia"; cells = false)
        c0 = Bennett.bennett(Bennett.lower(pir0))
        @test Bennett.gate_count(c0).total > 0
        # ... and a GENUINE `[N x i8]` alloca with 8-bit traffic is NOT caught by
        # the predicate — it keys on the actual width incompatibility, never on
        # the shape of the reservation alone (Bennett-munq must stay lowerable).
        pir_i8 = _bvmd_extract(_BVMD_I8ARR_LL, "bvmd_i8arr")
        @test Bennett.gate_count(Bennett.bennett(Bennett.lower(pir_i8))).total > 0
    end

    # ======================================================================
    # (V) THE IRVarGEP ARM IS LIVE — hostile-review defect D1.
    # ======================================================================
    @testset "(V) a runtime-index GEP is checked by bare stamp equality" begin
        # byte-tier root, word-stamped runtime index — an 8x misaddress that
        # extracted SILENTLY before the fix.
        mb = _bvmd_msg(_BVMD_VARGEP_BYTE_LL, "bvmd_vargep_byte")
        @test occursin("Bennett-bvmd", mb)
        @test occursin("IRVarGEP", mb)
        @test occursin("RUNTIME value", mb)   # no cell numbers are claimed
        @test occursin("_root_scale", mb)
        # word-tier root, byte-ish (i32) runtime index — the other direction.
        mw = _bvmd_msg(_BVMD_VARGEP_WORD_LL, "bvmd_vargep_word")
        @test occursin("Bennett-bvmd", mw)
        @test occursin("IRVarGEP", mw)
        # DISCRIMINATING, not blanket: a runtime index stamped at the root's own
        # scale is silent.
        @test _bvmd_msg(_BVMD_VARGEP_OK_LL, "bvmd_vargep_ok") == ""
        # ... and both rejects are ptr_cells-GATED.
        @test _bvmd_msg(_BVMD_VARGEP_BYTE_LL, "bvmd_vargep_byte"; cells=false) == ""
        @test _bvmd_msg(_BVMD_VARGEP_WORD_LL, "bvmd_vargep_word"; cells=false) == ""
    end

    # ======================================================================
    # (F2) THE MIXED OBJECT — normalisation cannot apply, so it is LOUD.
    # ======================================================================
    @testset "(F2) an object addressed at TWO granularities fails loud" begin
        msg = _bvmd_msg(_BVMD_MIXED_LL, "bvmd_mixed")
        @test occursin("Bennett-bvmd", msg)
        @test occursin("_root_scale", msg)          # the enforcing predicate
        @test occursin("Bennett-z2ia", msg)         # the residual it names
        @test occursin("bennettvm-jb6w", msg)       # the hazard class
        # both cell numbers, named — the message asserts only what it computes
        @test occursin("base+8", msg) || occursin("base+1", msg)
        for f in _BVMD_FORBIDDEN
            @test !occursin(f, msg)
        end
        # GATE CONTROL: on the circuit path `elem_width` is inert, so the guard
        # MUST NOT fire there.
        @test _bvmd_msg(_BVMD_MIXED_LL, "bvmd_mixed"; cells = false) == ""
    end

    # ======================================================================
    # (G) STREAM BACKSTOP — one check, nine construction sites.
    # ======================================================================
    @testset "(G) an i64-strided GEP off a byte-tier root fails loud" begin
        msg = _bvmd_msg(_BVMD_BACKSTOP_LL, "bvmd_backstop")
        @test occursin("Bennett-bvmd", msg)
        @test occursin("_root_scale", msg)
        for f in _BVMD_FORBIDDEN
            @test !occursin(f, msg)
        end
        @test _bvmd_msg(_BVMD_BACKSTOP_LL, "bvmd_backstop"; cells = false) == ""
    end

    # ======================================================================
    # (G2) VACUOUS DISAGREEMENT is exempt — and the D2 hazard still fires.
    # ======================================================================
    @testset "(G2) offset 0 is exempt; the chain behind it is still walked" begin
        # cell +0 under every stamp ⇒ NO disagreement, so nothing to normalise
        # and nothing to refuse: the alloca must stay BYTE-IDENTICAL. Without
        # this exemption `test_40ys` (G)/(H) go red on a byte offset of zero,
        # and `gep i8 %obj, 0` is a routine Julia codegen shape.
        pirz = _bvmd_extract(_BVMD_ZERO_LL, "bvmd_zero_offset")
        az = only([a for a in _bvmd_insts(pirz)
                   if a isa Bennett.IRAlloca && a.dest === :a])
        @test az.elem_width == 64
        @test az.n_elems == Bennett.ConstOperand(4)
        # ... but the exempt GEP's RESULT is a FRESH byte-granular base, which
        # is exactly p06b's dropped D2 carve-out hazard. An 8-byte offset off it
        # IS a genuine byte access, so the object is all-byte and gets
        # BYTE-NORMALISED — landing at cell +8, inside 32.
        pirc = _bvmd_extract(_BVMD_ZERO_THEN_BYTE_LL, "bvmd_zero_then_byte")
        ac = only([a for a in _bvmd_insts(pirc)
                   if a isa Bennett.IRAlloca && a.dest === :a])
        @test ac.elem_width == 8
        @test ac.n_elems == Bennett.ConstOperand(32)
        # THE assertion that distinguishes the exemption from a re-introduced
        # one-level carve-out: put a WORD access on the same root and the byte
        # leg — two GEPs deep, behind an offset-0 hop — must still be SEEN, so
        # the object is mixed and the guard fires.
        msg = _bvmd_msg(_BVMD_CHAIN_MIXED_LL, "bvmd_chain_mixed")
        @test occursin("Bennett-bvmd", msg)
        @test occursin("_root_scale", msg)
    end

    # ======================================================================
    # (P4c) BYTE-TIER CAPACITY — the byte-unit arm of the D1 capacity guard.
    # ======================================================================
    @testset "(P4c) an 8-byte gc_alloc box refuses a 16-byte decomposition" begin
        msg = _bvmd_msg(_BVMD_CAP_LL, "bvmd_cap")
        @test occursin("Bennett-p06b", msg)
        @test occursin("CLOBBERED", msg)
    end

    # ======================================================================
    # (P5) tier-parametrisation must NOT invert for a WORD-tier target.
    # ======================================================================
    @testset "(P5) word-tier target + byte GEP still rejects" begin
        msg = _bvmd_msg(_BVMD_P5_WORD_LL, "bvmd_p5_word")
        @test occursin("Bennett-p06b", msg)
        @test occursin("granularity", msg)
        @test occursin("BYTE-granular", msg)
    end

    # ======================================================================
    # (H) Bennett-4y0d — K≥2 arena memcpy offsets are byte-true.
    # ======================================================================
    @testset "(H) K=2 global-src memcpy into a gc_alloc dst is byte-stamped" begin
        pir = _bvmd_extract(_BVMD_4Y0D_LL, "bvmd_4y0d")
        offs = _bvmd_offsets(pir, :d)
        @test (0, 8) in offs
        @test (8, 8) in offs        # HEAD emitted (8, 64) → cell +1, byte-wrong
        @test all(p -> p[2] == 8, offs)
    end

    # ======================================================================
    # (I) THE CORPUS GATE — wall 11 → wall 12 (Bennett-5viz).
    # ======================================================================
    @testset "(I) push! corpus advances from wall 11 to wall 12" begin
        f = n::Int64 -> begin
            v = Int64[]; push!(v, n); @inbounds v[1]
        end
        msg = try
            Bennett.extract_parsed_ir_set_from_julia(f, Tuple{Int64};
                                                     ptr_cells = true)
            ""
        catch e
            sprint(showerror, e)
        end
        @test msg != ""                        # still walls — walls 10/11 remain
        # ===================== WALL 10 CLEARED — Bennett-57hd =====================
        # ADVANCED by Bennett-57hd (ADR 0017 §4b, the VALUE-IDENTITY contract): wall
        # 10 — the ROOT body's `%12 = ptrtoint ptr %memory_data3 to i64`, whose
        # base-cancelling difference escaped through `udiv exact` — is CLEARED, so a
        # 583s / foz5 / 57hd reject in the ROOT body is now a REGRESSION rather than
        # the expected wall. (Replaces the sy29-era positive, which asserted exactly
        # that reject.) Non-numeral anchors only (Bennett-0ncn).
        @test !occursin("base-cancelling", msg)
        @test !occursin("_foz5_confined_dead_bounds", msg)
        @test !occursin("_57hd_value_identity_cluster", msg)
        # ===================== WALL 11 CLEARED — Bennett-5viz =====================
        # ADVANCED by Bennett-5viz (xkl wall 11): the loaded-`ptr` (`.mem`) memcpy SRC —
        # corpus site #4 of the sy29 census, `Bennett-8bys` territory — is now certified
        # by `_5viz_global_src_root`, which strips the `extractvalue` with the shipped
        # `_57hd_insertvalue_field` and canonicalises the result with `_57hd_canon`
        # (ZERO ADR 0017 §4b change) down to the EMPTY-`GenericMemory` SINGLETON's
        # `.globals` root; root/capacity/scale then come from `parsed.globals` via
        # doih G8's own formula. WALL 12 is `Bennett-p06b`'s OWN reject: the
        # `alloca { ptr, ptr }` whose allocated type the alloca arm SILENTLY SKIPS, so
        # nothing ever reserved the cells that aggregate store would write.
        @test occursin("Bennett-p06b", msg)
        @test occursin("_p06b_cell_ptr_target_kind", msg)   # names the predicate
        @test occursin("SILENTLY SKIPS", msg)
        # ┌────────── THE `.mem` SUFFIX TRAP — MEASURED, DO NOT SHORTEN ───────────┐
        # │ The wall-11 discriminator INVERTS here: a `Bennett-37mt` / `-8bys` src  │
        # │ reject at the corpus is now a REGRESSION. This negative is STRONGER     │
        # │ than the operand-name pair it replaces — it does not depend on which    │
        # │ operand the `_ir_error` prefix happens to quote.                        │
        # │ BUT: wall 12's message DOES contain the substring `new::Array.ref` (it  │
        # │ quotes `store { ptr, ptr } %"new::Array.ref", …`) and does NOT contain  │
        # │ `new::Array.ref.mem`. KEEP THE `.mem` SUFFIX — dropping it turns the    │
        # │ line RED. Check discriminators against the MESSAGE TEXT, never against  │
        # │ the IR: the Bennett-sy29 lesson, applied to its own successor.          │
        # └────────────────────────────────────────────────────────────────────────┘
        @test !occursin("Bennett-37mt", msg)
        @test !occursin("new::Array.ref.mem", msg)
        @test !occursin("Bennett-5viz", msg)       # 5viz must not be the new wall
        # NOTE FOR WHOEVER CLEARS WALL 12 — all four points MEASURED on the wall-12
        # text itself, not forecast:
        #   * wall 12's own message contains NEITHER `Bennett-1zow` NOR
        #     `_p06b_granularity_violation`, so a marker written against either tag
        #     would never fire. Pin what IS there.
        #   * wall 13 is a SECOND 37mt/8bys memcpy reject (`memcpy operand alloca has
        #     non-integer element type` — corpus site #5's `alloca { ptr, ptr }` src,
        #     still `Bennett-8bys` territory), so `!occursin("Bennett-37mt")` will have
        #     to FLIP BACK to a positive one wall later; the discriminator against wall
        #     11 at that point is the operand pair (`%0` / `env+56`, NO `.mem`).
        #   * wall 14 is the bvmd `SCALE-COHERENCE` reject on the 9×i64 closure alloca.
        #     It PRE-EXISTS 5viz — raised by the already-shipped site-#3 memcpy's word
        #     stamp setting `all_byte[env] = false`, not by anything 5viz emits — and
        #     the 5viz scout's probe `p10` measured that byte-stamping ALL THREE
        #     env-rooted memcpys makes the ROOT extract with NO WALL AT ALL. That tier
        #     decision is deferred to the `Bennett-bvmd` family arc (5viz scout §3);
        #     5viz deliberately keeps the sy29 dst-stamp rule unchanged.
        #   * the `%L21` / `%L43` clusters are NOT future walls — already admitted
        #     under ADR 0017 §4a (gate (S) of test_57hd_value_identity.jl).
        # INVERTED discriminator: after bvmd a p06b reject naming `gc_alloc_obj`
        # is a REGRESSION, not the expected wall.
        @test !(occursin("Bennett-p06b", msg) && occursin("gc_alloc_obj", msg))
        # (P5) must not be the new wall — if it is, the D4 re-stamp was skipped
        # and the arc is a no-op (scout §5, probe `b06_p5.jl`).
        @test !occursin("BYTE-granular getelementptr", msg)
        # bvmd's own guard must not be the new wall either.
        @test !occursin("Bennett-bvmd", msg)
        # BODY SCOPE — the retired blanket `!Bennett-583s` negative, narrowed
        # rather than deleted so its original intent survives: wall 7 was the
        # CLOSURE's `%idxend41` cluster, cleared by Bennett-foz5. Wall 10 is in
        # the ROOT body, so a 583s reject naming `_growend!` would be a re-open
        # of wall 7 and not the expected successor. (The bvmd-suggested
        # `udiv exact` discriminator is NOT constructible: the `_ir_error` prefix
        # quotes the *ptrtoint*, not the cluster, so the message text contains no
        # `udiv` — see docs/design/sy29_scout.md §10.2.)
        @test !(occursin("Bennett-583s", msg) && occursin("_growend!", msg))
        # LOAD-BEARING NEGATIVES — walls 3/5/6 stay cleared. Measured still-true
        # at wall 10.
        for neg in ("Bennett-jbko", "Bennett-iwo9", "Bennett-lgzx", "memmove",
                    "store of non-integer type")
            @test !occursin(neg, msg)
        end
    end
end
