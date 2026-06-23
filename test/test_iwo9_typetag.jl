# Bennett-iwo9 / CW-D3 Lever 1 — Julia type-tag globals + ptrtoint/inttoptr
# round-trip under the closed-world `ptr_cells=true` VM gate.
#
# The Julia GC-typed-allocation cluster the `fdict` root hits is:
#
#   %tag  = load ptr, ptr @"+Main.Base.Dict#148"   ; type-tag global
#   %Dict = ptrtoint ptr %tag to i64
#   %1    = inttoptr i64 %Dict to ptr
#   ... call ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %1)
#
# Lever 1 (THIS bead) models ONLY the type-tag recognition + the
# load / ptrtoint / inttoptr round-trip (decisions 1-3 of the consensus doc
# docs/design/Bennett-iwo9-CW-D3-typetag-consensus.md). gc_alloc_obj (Lever 2)
# and BennettVM ingest (Lever 3) are out of scope.
#
# Soundness contract (consensus §Soundness):
#   - Type-tag globals are recognised BY NAME (`startswith("+")` && `#\d+$`),
#     NEVER by the non-deterministic JIT address in their initializer.
#   - The canonical type path strips the leading `+` and the trailing `#N`,
#     so `Dict#148` and `Dict#999` are the SAME type → SAME interned id.
#   - The id is minted deterministically (first-seen walk order) into an
#     extraction-local interning table; extracting the same fixture twice
#     yields the same id.
#   - A genuine pointer<->int round-trip whose source is NOT a type tag
#     (e.g. a function-arg pointer) is NOT modelled and FAILS LOUD
#     (CLAUDE.md §1) — only the type-tag round-trip is sound.
#   - All arms are `ptr_cells`-gated: with `ptr_cells=false` the SAME fixture
#     walls at the pre-existing "unsupported LLVM opcode" ptrtoint fail-loud
#     (circuit path byte-identical).
#
# Pre-fix wall (R1, empirically captured 2026-06-23):
#   ir_extract.jl: ptrtoint in @f:%top:   %d = ptrtoint ptr %tag to i64 — unsupported LLVM opcode
# (the `ptrtoint` opcode hits the generic fall-through; identical under both
# gate values pre-fix).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, ParsedIR, IRBinOp, ConstOperand, SSAOperand

# --- Fixtures -------------------------------------------------------------
# The type-tag global is an external `ptr` global declaration (R3: this is the
# form Julia's JIT emits; the name carries the `+Type#N` tag, and we recognise
# by name without reading any initializer).

# Round-trip: load tag → ptrtoint → inttoptr → ptrtoint → ret i64.
const TAG_DICT_148 = """
@"+Main.Base.Dict#148" = external global ptr

define i64 @f() {
top:
  %tag = load ptr, ptr @"+Main.Base.Dict#148"
  %d = ptrtoint ptr %tag to i64
  %p = inttoptr i64 %d to ptr
  %d2 = ptrtoint ptr %p to i64
  ret i64 %d2
}
"""

# Same TYPE (Main.Base.Dict), different `#N` suffix (#999 not #148). Must mint
# the SAME canonical path / id as TAG_DICT_148 (`#N`-invariance).
const TAG_DICT_999 = """
@"+Main.Base.Dict#999" = external global ptr

define i64 @f() {
top:
  %tag = load ptr, ptr @"+Main.Base.Dict#999"
  %d = ptrtoint ptr %tag to i64
  %p = inttoptr i64 %d to ptr
  %d2 = ptrtoint ptr %p to i64
  ret i64 %d2
}
"""

# A DIFFERENT type (Core.AssertionError) → DIFFERENT canonical path / id.
const TAG_ASSERTERR_153 = """
@"+Core.AssertionError#153" = external global ptr

define i64 @f() {
top:
  %tag = load ptr, ptr @"+Core.AssertionError#153"
  %d = ptrtoint ptr %tag to i64
  ret i64 %d
}
"""

# `#N`-invariance + type discrimination in ONE extraction (the interning table
# is extraction-local, so dense ids restart at 0 per extraction — the invariance
# assertion is only meaningful WITHIN a single function walk). `Dict#148` and
# `Dict#999` are the same canonical type → SAME id; `Core.AssertionError#153`
# is a distinct type → DIFFERENT id.
const TAG_INVARIANCE = """
@"+Main.Base.Dict#148" = external global ptr
@"+Main.Base.Dict#999" = external global ptr
@"+Core.AssertionError#153" = external global ptr

define i64 @f() {
top:
  %a = load ptr, ptr @"+Main.Base.Dict#148"
  %da = ptrtoint ptr %a to i64
  %b = load ptr, ptr @"+Main.Base.Dict#999"
  %db = ptrtoint ptr %b to i64
  %c = load ptr, ptr @"+Core.AssertionError#153"
  %dc = ptrtoint ptr %c to i64
  %s1 = add i64 %da, %db
  %s2 = add i64 %s1, %dc
  ret i64 %s2
}
"""

# Two DISTINCT type tags in ONE function → two distinct dense ids; first-seen
# walk order assigns id 0 to the first-loaded tag, id 1 to the second.
const TAG_TWO_TYPES = """
@"+Main.Base.Dict#148" = external global ptr
@"+Core.AssertionError#153" = external global ptr

define i64 @f() {
top:
  %t1 = load ptr, ptr @"+Main.Base.Dict#148"
  %d1 = ptrtoint ptr %t1 to i64
  %t2 = load ptr, ptr @"+Core.AssertionError#153"
  %d2 = ptrtoint ptr %t2 to i64
  %s = add i64 %d1, %d2
  ret i64 %s
}
"""

# FAIL-LOUD: the source of the ptr<->int round-trip is a function ARGUMENT,
# NOT a type tag. Under ptr_cells=true this must fail loud (only the type-tag
# round-trip is sound; a genuine arena/arg pointer must not be modelled).
const NON_TAG_ARG = """
define ptr @g(i64 %x) {
top:
  %p = inttoptr i64 %x to ptr
  ret ptr %p
}
"""

# FAIL-LOUD: a type-tag value cast to a NON-64-bit width (`ptrtoint ptr to
# i32`). `%tag` IS a recognised tag (source ∈ tag_ssa), but the 64-bit type-tag
# round-trip is the only sound model — a narrower cast is genuine pointer
# arithmetic that truncates the Int64 VM cell. Must fail loud (width guard).
const TAG_NARROW_WIDTH = """
@"+Main.Base.Dict#148" = external global ptr

define i32 @f() {
top:
  %tag = load ptr, ptr @"+Main.Base.Dict#148"
  %d = ptrtoint ptr %tag to i32
  ret i32 %d
}
"""

# FAIL-LOUD: a `+`-prefixed global WITHOUT a trailing `#N` suffix. The
# canonicalizer must reject this loudly (unexpected JIT naming, CLAUDE.md §1).
const TAG_NO_HASH = """
@"+Main.Base.Dict" = external global ptr

define i64 @f() {
top:
  %tag = load ptr, ptr @"+Main.Base.Dict"
  %d = ptrtoint ptr %tag to i64
  ret i64 %d
}
"""

# --- Extraction helper ----------------------------------------------------
function _extract_ll_iwo9(name, ir, entry; cells)
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

_all_insts_iwo9(pir) = [ins for b in pir.blocks for ins in b.instructions]

# Find the IRBinOp(:or, iconst(id), iconst(0), 64) for the tag-load `dest`.
# Returns the minted id (Int), or `nothing` if no such instruction exists.
function _tag_load_id(pir, dest::Symbol)
    for ins in _all_insts_iwo9(pir)
        if ins isa IRBinOp && ins.dest === dest && ins.op === :or && ins.width == 64 &&
           ins.op1 isa ConstOperand && ins.op2 isa ConstOperand && ins.op2.value == 0
            return ins.op1.value
        end
    end
    return nothing
end

@testset "Bennett-iwo9 CW-D3 Lever 1: type-tag globals + ptrtoint/inttoptr" begin

    # =====================================================================
    # GATE (a) — ptr_cells=true: the round-trip extracts; the tag load
    # lowers to IRBinOp(:or, iconst(id), iconst(0), 64) with a CONCRETE id,
    # and the ptrtoint/inttoptr chain binds through real SSA defs.
    # =====================================================================
    @testset "GATE (a) — tag round-trip extracts under ptr_cells" begin
        (st, pir) = _extract_ll_iwo9("tag148", TAG_DICT_148, "f"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts_iwo9(pir)
            # The tag load (%tag) lowers to IRBinOp(:or, iconst(id), iconst(0), 64).
            id = _tag_load_id(pir, :tag)
            @test id !== nothing
            @test id isa Int
            # Each chain link (%d, %p, %d2) is a width-64 :or identity whose
            # op1 is the SSA ref to its source and op2 is iconst(0).
            for (dst, src) in ((:d, :tag), (:p, :d), (:d2, :p))
                hit = filter(x -> x isa IRBinOp && x.dest === dst && x.op === :or &&
                                  x.width == 64 && x.op1 isa SSAOperand &&
                                  x.op1.name === src && x.op2 isa ConstOperand &&
                                  x.op2.value == 0, insts)
                @test length(hit) == 1
            end
            # The function returns the round-tripped tag value (width 64).
            @test pir.ret_width == 64
        end
    end

    # =====================================================================
    # GATE (a2) — DETERMINISM: extracting the SAME fixture twice yields the
    # SAME minted id (first-seen walk order is deterministic).
    # =====================================================================
    @testset "GATE (a2) — determinism: same fixture → same id" begin
        (s1, p1) = _extract_ll_iwo9("det1", TAG_DICT_148, "f"; cells=true)
        (s2, p2) = _extract_ll_iwo9("det2", TAG_DICT_148, "f"; cells=true)
        @test s1 === :ok && s2 === :ok
        if s1 === :ok && s2 === :ok
            id1 = _tag_load_id(p1, :tag)
            id2 = _tag_load_id(p2, :tag)
            @test id1 !== nothing && id2 !== nothing
            @test id1 == id2
        end
    end

    # =====================================================================
    # GATE (a3) — `#N`-INVARIANCE: Dict#148 and Dict#999 are the SAME type
    # (same canonical path) → SAME id; a different type (Core.AssertionError)
    # → DIFFERENT id.
    # =====================================================================
    @testset "GATE (a3) — #N-invariance + type discrimination" begin
        # Single extraction (interning is extraction-local — dense ids restart
        # at 0 per walk, so the invariance assertion is only meaningful within
        # ONE function).
        (st, pir) = _extract_ll_iwo9("inv", TAG_INVARIANCE, "f"; cells=true)
        @test st === :ok
        if st === :ok
            id148 = _tag_load_id(pir, :a)    # Main.Base.Dict#148
            id999 = _tag_load_id(pir, :b)    # Main.Base.Dict#999
            idaerr = _tag_load_id(pir, :c)   # Core.AssertionError#153
            @test id148 !== nothing && id999 !== nothing && idaerr !== nothing
            # Dict#148 and Dict#999 collapse to the same canonical type id.
            @test id148 == id999
            # Core.AssertionError is a distinct type → distinct id.
            @test idaerr != id148
        end
    end

    # =====================================================================
    # GATE (a4) — TWO distinct types in one function → two distinct dense ids
    # assigned in first-seen order (0, then 1).
    # =====================================================================
    @testset "GATE (a4) — two distinct type tags → distinct dense ids" begin
        (st, pir) = _extract_ll_iwo9("two", TAG_TWO_TYPES, "f"; cells=true)
        @test st === :ok
        if st === :ok
            id1 = _tag_load_id(pir, :t1)   # Main.Base.Dict (first seen)
            id2 = _tag_load_id(pir, :t2)   # Core.AssertionError (second seen)
            @test id1 !== nothing && id2 !== nothing
            @test id1 != id2
            # Dense, first-seen interning: 0 then 1.
            @test id1 == 0
            @test id2 == 1
        end
    end

    # =====================================================================
    # GATE (b) — FAIL-LOUD: a ptr<->int round-trip whose source is NOT a type
    # tag (a function arg) must fail loud under ptr_cells=true, with a
    # CW-D3/iwo9 breadcrumb. Only the type-tag round-trip is modelled.
    # =====================================================================
    @testset "GATE (b) — non-tag inttoptr fails loud under ptr_cells" begin
        (st, msg) = _extract_ll_iwo9("nontag", NON_TAG_ARG, "g"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("inttoptr", msg) || occursin("ptrtoint", msg)
            @test occursin("iwo9", msg) || occursin("CW-D3", msg)
        end
    end

    # =====================================================================
    # GATE (b2) — FAIL-LOUD: a `+`-prefixed global WITHOUT a `#N` suffix is
    # malformed type-tag naming → fail loud in the canonicalizer.
    # =====================================================================
    @testset "GATE (b2) — +-named global without #N fails loud" begin
        (st, msg) = _extract_ll_iwo9("nohash", TAG_NO_HASH, "f"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("iwo9", msg) || occursin("CW-D3", msg) ||
                  occursin("#N", msg) || occursin("type-tag", msg)
        end
    end

    # =====================================================================
    # GATE (b3) — FAIL-LOUD: a recognised type-tag value cast to a NON-64-bit
    # width (`ptrtoint ptr %tag to i32`). The source IS a tag (∈ tag_ssa), but
    # only the 64-bit round-trip is sound — a narrower cast truncates the Int64
    # VM cell and is genuine pointer arithmetic. Width guard must fire.
    # =====================================================================
    @testset "GATE (b3) — type-tag cast to non-64-bit width fails loud" begin
        (st, msg) = _extract_ll_iwo9("narrow", TAG_NARROW_WIDTH, "f"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("iwo9", msg) || occursin("CW-D3", msg)
            # The breadcrumb names the offending width (64-bit round-trip only).
            @test occursin("64-bit", msg) || occursin("width", msg)
        end
    end

    # =====================================================================
    # GATE (c) — BYTE-IDENTITY: with ptr_cells=false the SAME round-trip
    # fixture walls at the pre-existing "unsupported LLVM opcode" ptrtoint
    # fail-loud (R1). The new arms live behind the ptr_cells gate; the
    # circuit path is unchanged.
    # =====================================================================
    @testset "GATE (c) — ptr_cells=false: pre-fix wall unchanged (byte-identity)" begin
        (st, msg) = _extract_ll_iwo9("off", TAG_DICT_148, "f"; cells=false)
        @test st === :err
        if st === :err
            @test occursin("unsupported LLVM opcode", msg)
            @test occursin("ptrtoint", msg)
        end
    end

end
