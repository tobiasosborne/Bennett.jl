# test/test_5viz_loaded_ptr_src_memcpy.jl — bead Bennett-5viz (xkl frontier
# wall 11): a const-size `llvm.memcpy` whose SRC is a LOADED POINTER that
# canonicalises to a `.globals` SINGLETON root, under the closed-world
# `ptr_cells=true` gate.
#
# # The wall
#
# The push! closed-world ROOT (`v = Int64[]; push!(v, n); @inbounds v[1]`) walls
# at
#
#     call void @llvm.memcpy.p0.p0.i64(ptr align 8 %23,
#                                      ptr align 8 %"new::Array.ref.mem",
#                                      i64 8, i1 false)
#
# in `%L16`, where `%23 = getelementptr inbounds i8, ptr %"new::#_growend!…", 40`
# is the `_growend!` closure env (an `alloca [9 x i64]`) and
# `%"new::Array.ref.mem" = extractvalue { ptr, ptr } %"new::Array.ref", 1` is a
# LOADED pointer with no alloca and no arena root at the site. The rejecting
# predicate is Predicate 6's SRC half in `_handle_memcpy_arm`: "memcpy src
# operand is not alloca-backed … (Bennett-37mt Phase 1)" — CHARACTER-IDENTICAL
# to the reject Bennett-sy29 cleared at wall 9. Corpus site #4 of the sy29
# census; `Bennett-8bys` is the standing catch-all for the family.
#
# # TWO CORRECTIONS TO THE BEAD TEXT, both measured (docs/design/5viz_scout.md)
#
#  1. **There is no gc_alloc'd `Memory` in this program.** `Int64[]` yields the
#     SHARED EMPTY `Memory{Int64}` SINGLETON, which `_extract_const_globals`
#     already models — under the shipped `bennettvm-416r.13 / CW-D3 Lever 2`
#     arm, `ptr_cells`-gated — as a 16-BYTE ZERO BLOB in `ParsedIR.globals`
#     (`jl_global#N => (zeros(UInt64,16), 8)`). The certification target is a
#     GLOBAL root, not an arena root.
#  2. **The copied VALUE is an `Int64`, not a pointer.** The memcpy's src
#     OPERAND is a pointer; the copied VALUE is the 8 bytes AT that address —
#     the `Memory` header's `{i64 length, ptr data}` field 0, i.e. `length`.
#     `env+40` is the closure's FIFTH `Int64` field (the env is
#     `ptr@+0, Int64@+8…+40, Memory@+48, GenericMemoryRef@+56` = 9 × i64; the
#     three GC-tracked fields go to a separate `alloca ptr, i32 3` roots array,
#     never to the env). Consequence for Predicate 8: `src_ew = 64` is the VALUE
#     width, NEVER the global's stored `ew = 8`, which is the ADDRESS SCALE.
#     Confusing the two rejects the corpus at Predicate 8b.
#
# # The route (single survivor; three alternatives closed by MEASUREMENT)
#
# An sy29-arm WIDENING, not a new arm, and NOT a change to ADR 0017 §4b:
#
#   * `_57hd_insertvalue_field(agg, j)` strips the top-level `extractvalue`
#     (pure SSA algebra: `extractvalue (insertvalue A, v, j), j` IS `v`);
#   * `_57hd_canon` — ZERO changes to §4b — reduces the stripped value to the
#     `load ptr, ptr @"jl_global#N"` via its (a) STORE-FORWARD clause;
#   * root / capacity / scale then come from `parsed.globals`, which the memcpy
#     arm ALREADY receives, via doih G8's own formula
#     (`capacity = length(data) * (ew ÷ 8)`);
#   * disjointness against the alloca dst is STRUCTURAL: BennettVM lays globals
#     in a fourth address tier based at `GLOBAL_BASE = 2^48`, READ-ONLY
#     (`BennettVM/src/ir/IState.jl`, `memory_floor.jl`), while stack allocas
#     live below it — so a global-rooted src and an alloca-rooted dst cannot
#     alias by address-space construction.
#
# Rejected, each because it re-opens a hole sy29's own hostile review EXECUTED
# (`222` vs oracle `333`; `leak = 999`): "admit any certified cell pointer"
# (loses Predicate 7 AND 6d), `_57hd_roots_disjoint` instead of root identity
# (survives P7 but supplies no capacity, so 6d is skipped), and routing to
# `IRCall(:memcpy)` (closed by BVM's `_enforce_julia_heap_tier!`, which refuses
# `IntrinsicMemcpy`/`IntrinsicMemmove` in any `gc_alloc_obj`-bearing program —
# and this program is one).
#
# # ┌──────────────── THE CANON-BLOCK TRAP — MEASURED, READ THIS ─────────────┐
#   │ `_57hd_canon` is INTRA-BLOCK BY DESIGN                                  │
#   │ (`LLVM.parent(v).ref == blk.ref || return v.ref`). The memcpy lives in   │
#   │ `%L16`; the src's definition chain lives in `%top`. Running canon in the │
#   │ MEMCPY's block returns the value UNCHANGED — the arm becomes DEAD CODE   │
#   │ and the wall silently persists. It MUST run in the block where the       │
#   │ STRIPPED value is DEFINED. That is sound because canon establishes a     │
#   │ fact about an SSA VALUE AT ITS DEFINITION, and SSA values are immutable: │
#   │ the fact holds at every use, in every block. Gate (d) is a THREE-BLOCK   │
#   │ fixture in which BOTH naive block choices (the memcpy's block AND the    │
#   │ `extractvalue`'s own block) would no-op, so the arm can only fire if the │
#   │ defining block was chosen.                                              │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# # What this file pins
#
#   (a0) DIRECT loaded-singleton src — no `extractvalue`, no store-forward; the
#        degenerate case where canon's answer is the value itself.
#   (a)  K = 1 CORPUS SHAPE — cross-block canon through the aggregate store;
#        extracts, and the emitted src base is the GLOBAL's stable name, not the
#        `extractvalue`'s.
#   (b)  K = 2 — the (SC) VACUITY TRAP. At K = 1 with offset 0 EVERY address
#        stamp passes `_check_scale_coherence!`'s `cell_emitted == cell_meant`
#        exemption, which is exactly how the pre-4y0d vbv9 defect stayed green.
#        Only a K ≥ 2 fixture can see a wrong stamp. NON-NEGOTIABLE, inherited
#        from sy29 §5.
#   (c)  NON-ZERO SRC OFFSET — the second half of the same obligation.
#   (d)  THE CANON-BLOCK TRAP — the three-block dead-arm control.
#   (e)  NON-SINGLETON LOADED SRC still fails loud with the UNCHANGED
#        `Bennett-37mt` / `Bennett-8bys` Predicate-6 text.
#   (f)  CANONICALISED-GLOBAL DST — refused, and by the DST half of Predicate 6
#        (writing a read-only `GLOBAL_BASE` tier has no reversible semantics).
#   (g)  6d IN-OBJECT RANGE — `off + N > capacity` refused, naming the predicate.
#   (h)  6c CELL ALIGNMENT — a sub-cell src offset refused, naming the predicate.
#   (i)  `ptr_cells=false` BYTE-IDENTITY — the circuit path never reaches the new
#        branch and keeps its UNCHANGED messages.
#   (j)  WALL 14 IS PRE-EXISTING AND IS `Bennett-bvmd`'s — with a BYTE-GEP'd
#        word-tier env dst the 5viz src admission still FIRES (no 37mt src
#        reject) and the program walls at the bvmd SCALE-COHERENCE tier check
#        instead. 5viz keeps the sy29 dst-stamp rule unchanged; the tier decision
#        is deferred to the bvmd-family arc (scout §3).
#   (k)  THE CORPUS GATE — the push! set advances from wall 11 to wall 12.
#
# Rule 5: no LLVM formatting, instruction ordering or `%NNN` naming is pinned —
# every assertion is programmatic over extracted `IRInst` nodes, or over a
# fail-loud message's NON-NUMERAL anchors (the Bennett-0ncn lesson).
#
# Ref: `docs/design/5viz_scout.md` (the ratified design),
#      `src/extract/instructions.jl` (`_handle_memcpy_arm`,
#      `_5viz_global_src_root`, `_57hd_canon`, `_57hd_insertvalue_field`),
#      `src/extract/module_walk.jl` (`_extract_const_globals`, the 416r.13 arm),
#      `../BennettVM.jl/test/test_5viz_global_src_vm.jl` (the downstream E2E),
#      `Bennett-8bys` (site #4 CLEARED here; site #5's `alloca { ptr, ptr }` src
#      class remains 8bys territory).

using Test
import Bennett
using Bennett: extract_parsed_ir_from_ll

_5viz_insts(pir) = reduce(vcat, [b.instructions for b in pir.blocks];
                          init = Bennett.IRInst[])

function _5viz_extract(ir::AbstractString, fn::AbstractString; cells::Bool=true)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        return extract_parsed_ir_from_ll(path; entry_function = fn,
                                         ptr_cells = cells)
    end
end

function _5viz_msg(ir::AbstractString, fn::AbstractString; cells::Bool=true)
    try
        _5viz_extract(ir, fn; cells = cells)
        return ""
    catch e
        e isa InterruptException && rethrow()
        return sprint(showerror, e)
    end
end

# Every `(offset_bytes, elem_width)` pair emitted off a given base — the cell map
# as a pinned object rather than a prose claim (the `_sy29_offsets` idiom).
_5viz_offsets(pir, base::Symbol) =
    Set((o.offset_bytes, o.elem_width) for o in _5viz_insts(pir)
        if o isa Bennett.IRPtrOffset && o.base isa Bennett.SSAOperand &&
           o.base.name === base)

# The cell an emitted offset node resolves to, computed exactly the way
# BennettVM computes it (`Define(d, b, :add, off ÷ (ew÷8))`).
_5viz_cell(p) = p[1] ÷ (p[2] ÷ 8)

# The stores the MEMCPY DECOMPOSITION emitted, isolated from every other store
# in the fixture by following the dst offset nodes. A blunt
# `count(i isa IRStore)` would also count the corpus preamble's aggregate
# `store { ptr, ptr }`, which the p06b arm legitimately decomposes into two
# 64-bit stores of its own — measured, and the reason this helper exists.
function _5viz_copy_stores(pir, dstbase::Symbol)
    insts = _5viz_insts(pir)
    dests = Set(o.dest for o in insts
                if o isa Bennett.IRPtrOffset && o.base isa Bennett.SSAOperand &&
                   o.base.name === dstbase)
    return [s for s in insts
            if s isa Bennett.IRStore && s.ptr isa Bennett.SSAOperand &&
               s.ptr.name in dests]
end

# The UNCHANGED Predicate-6 SRC reject — the circuit-path byte-identity anchor
# and the wall-11 regression detector.
_is_37mt_src_wall(msg) =
    occursin("src operand is not alloca-backed", msg) &&
    occursin("Bennett-37mt", msg)

const _5VIZ_G = Symbol("jl_global#93")

# ---------------------------------------------------------------------------
# Fixtures. Every one carries the distilled-corpus datalayout so the byte/word
# tiers are unambiguous.
#
# THE SINGLETON GLOBAL. Julia emits `@"jl_global#N" = private constant ptr
# @"jl_global#N.jit"` where the `.jit` alias is `inttoptr (i64 <JIT-addr>)` — a
# GlobalAlias LLVM.jl cannot represent, so `LLVM.initializer` THROWS and
# `_extract_const_globals` takes its `init === nothing` arm. The distilled form
# below spells the pointer constant DIRECTLY (`constant ptr inttoptr (…)`),
# which lands in the same function's belt-and-suspenders `else` arm — the
# `ptr_cells && _is_singleton_data_global_name && PointerType` clause — and
# seeds the IDENTICAL `(zeros(UInt64,16), 8)` entry. Both forms verified to
# produce the same `.globals` entry, so the fixture is faithful without
# depending on LLVM.jl's alias-parse behaviour (Rule 5). The JIT address itself
# is NEVER read (ADR 0021 D3).
# ---------------------------------------------------------------------------
const _5VIZ_DL = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"
"""

const _5VIZ_GLOB = """
@"jl_global#93" = private unnamed_addr constant ptr inttoptr (i64 140234000 to ptr)
"""

const _5VIZ_DECLS = """
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
"""

# (a0) The DIRECT shape: the memcpy src IS the singleton load. No
# `extractvalue`, no store-forward — `_57hd_canon` returns the load itself and
# the certification is one step. Also the `ptr_cells=false` control (gate (i)),
# because it contains no `{ptr,ptr}` `insertvalue` and therefore does not wall
# earlier at Bennett-6bu3 on the circuit path.
const _5VIZ_DIRECT_LL = _5VIZ_DL * _5VIZ_GLOB * _5VIZ_DECLS * """
define i64 @v5_direct(ptr %task, ptr %tag) {
top:
  %g = load ptr, ptr @"jl_global#93", align 8
  %env = alloca [9 x i64], align 8
  %d = getelementptr inbounds i64, ptr %env, i32 5
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %g, i64 8, i1 false)
  ret i64 0
}
"""

# The CORPUS-SHAPED preamble: the singleton pointer is stored into a
# `gc_alloc_obj` box as field 1 of an aggregate `{ptr,ptr}`, re-loaded out of
# that field, re-packed into a second aggregate, and finally `extractvalue`d —
# the exact chain `%"new::Array.ref.mem"` has in the ROOT. `dgep` is the dst
# address expression; `body` the memcpy (and any src GEP).
#
# THE DST IS A WORD GEP (`getelementptr i64, ptr %env, 5` = byte 40), NOT the
# corpus's byte GEP. Deliberate, and gate (j) is the reason: a BYTE GEP off a
# word-tier `alloca [9 x i64]` trips the PRE-EXISTING `Bennett-bvmd`
# SCALE-COHERENCE check, which is wall 14 and is NOT this bead's (scout §3 —
# it is raised by the already-shipped site-#3 memcpy's word stamp, not by
# anything 5viz emits). Both forms give `_root_byte_offset == 40` and
# `_root_scale == (8, 9)`, so the 5viz predicates see an IDENTICAL dst; only
# the bvmd tier question differs, and gate (j) pins that separately.
function _5viz_fx(name::AbstractString, fld1::AbstractString,
                  body::AbstractString;
                  dgep::AbstractString = "%d = getelementptr inbounds i64, ptr %env, i32 5")
    _5VIZ_DL * _5VIZ_GLOB * _5VIZ_DECLS * """
define i64 @$(name)(ptr %task, ptr %tag) {
top:
  %g = load ptr, ptr @"jl_global#93", align 8
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %agg0 = insertvalue { ptr, ptr } zeroinitializer, ptr %box, 0
  %agg = insertvalue { ptr, ptr } %agg0, ptr $(fld1), 1
  store { ptr, ptr } %agg, ptr %box, align 8
  %f1 = getelementptr inbounds { ptr, ptr }, ptr %box, i32 0, i32 1
  %ld = load ptr, ptr %f1, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %box, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %ld, 1
  br label %L1

L1:
  %mem = extractvalue { ptr, ptr } %ref, 1
  br label %L2

L2:
  %env = alloca [9 x i64], align 8
  $(dgep)
$(body)
  ret i64 0
}
"""
end

const _5VIZ_CP = "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %mem, i64 8, i1 false)"

const _5VIZ_K1_LL   = _5viz_fx("v5_k1", "%g", _5VIZ_CP)
const _5VIZ_K2_LL   = _5viz_fx("v5_k2", "%g",
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %mem, i64 16, i1 false)")
const _5VIZ_OFF8_LL = _5viz_fx("v5_off8", "%g",
    "  %s = getelementptr inbounds i8, ptr %mem, i32 8\n" *
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %s, i64 8, i1 false)")
# (g) 6d: bytes [8, 24) of a blob that seeds only 16.
const _5VIZ_OOB_LL  = _5viz_fx("v5_oob", "%g",
    "  %s = getelementptr inbounds i8, ptr %mem, i32 8\n" *
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %s, i64 16, i1 false)")
# (h) 6c: byte 4 of the blob — perfectly scale-coherent, but the byte tier names
# a 64-bit value by its BASE byte address and never names +1…+7.
const _5VIZ_MISALIGN_LL = _5viz_fx("v5_mis", "%g",
    "  %s = getelementptr inbounds i8, ptr %mem, i32 4\n" *
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %s, i64 8, i1 false)")
# (e) The aggregate's field 1 is the BOX itself, so canon reduces the src to a
# `julia.gc_alloc_obj` CALL — certified, but NOT a load of a `.globals`
# singleton. The arm must decline and the UNCHANGED wall must stand.
const _5VIZ_NONSINGLE_LL = _5viz_fx("v5_ns", "%box", _5VIZ_CP)
# (f) The canonicalised-global value as the DST.
const _5VIZ_GDST_LL = _5viz_fx("v5_gdst", "%g",
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %mem, ptr align 8 %d, i64 8, i1 false)")
# (j) The CORPUS's own byte-GEP dst off the word-tier env.
const _5VIZ_BYTEDST_LL = _5viz_fx("v5_bytedst", "%g", _5VIZ_CP;
    dgep = "%d = getelementptr inbounds i8, ptr %env, i32 40")

@testset "Bennett-5viz — loaded-ptr memcpy src canonicalising to a .globals root" begin

    # ======================================================================
    # (a0) THE DIRECT SHAPE — canon's degenerate answer.
    # ======================================================================
    @testset "(a0) direct loaded-singleton src is admitted" begin
        pir = _5viz_extract(_5VIZ_DIRECT_LL, "v5_direct")
        @test haskey(pir.globals, _5VIZ_G)
        @test pir.globals[_5VIZ_G] == (zeros(UInt64, 16), 8)
        # SRC addresses are stamped from the GLOBAL's own scale (ew ÷ 8 == 1),
        # i.e. the BYTE tier: `8 * 1 == 8`.
        @test _5viz_offsets(pir, _5VIZ_G) == Set([(0, 8)])
        # DST addresses keep the sy29 rule: `8 * _root_scale(env)[1] == 64`.
        @test _5viz_offsets(pir, :d) == Set([(0, 64)])
        insts = _5viz_insts(pir)
        # The VALUE width is 64 on BOTH sides — one whole Int64 (the `Memory`
        # header's `length` field), which occupies exactly ONE cell in the byte
        # tier and ONE cell in the word tier.
        @test count(i -> i isa Bennett.IRLoad && i.width == 64, insts) == 1
        @test count(i -> i isa Bennett.IRStore && i.width == 64, insts) == 1
        @test !any(i -> i isa Bennett.IRCall, insts)
    end

    # ======================================================================
    # (a) THE K = 1 CORPUS SHAPE — cross-block canon through the aggregate
    #     store, exactly the `%"new::Array.ref.mem"` chain.
    # ======================================================================
    @testset "(a) corpus-shaped loaded .mem src is admitted, K = 1" begin
        pir = _5viz_extract(_5VIZ_K1_LL, "v5_k1")
        @test haskey(pir.globals, _5VIZ_G)
        # THE LOAD-BEARING ASSERTION: the emitted src base is the GLOBAL's
        # STABLE name, not the `extractvalue`'s drifting SSA name. That can only
        # happen if `_57hd_canon` resolved the chain — the arm is not merely
        # "not rejecting", it PROVED the root.
        @test _5viz_offsets(pir, _5VIZ_G) == Set([(0, 8)])
        @test isempty(_5viz_offsets(pir, :mem))
        @test _5viz_offsets(pir, :d) == Set([(0, 64)])
        cps = _5viz_copy_stores(pir, :d)
        @test length(cps) == 1                       # K = 1
        @test only(cps).width == 64                  # the VALUE width
    end

    # ======================================================================
    # (b) K = 2 — THE (SC) VACUITY TRAP. At K = 1 the only offset is 0, which is
    #     cell 0 under EVERY stamp, so `_check_scale_coherence!`'s
    #     `cell_emitted == cell_meant` exemption passes a WRONG stamp silently
    #     — the exact mechanism that kept the pre-4y0d vbv9 defect green. A
    #     corpus-shaped K = 1 fixture proves NOTHING about the stamp; this gate
    #     does. Inherited verbatim from sy29 §5 as a NON-NEGOTIABLE obligation.
    # ======================================================================
    @testset "(b) K = 2 pins (8, 8) on the src side at k = 1" begin
        pir = _5viz_extract(_5VIZ_K2_LL, "v5_k2")
        offs = _5viz_offsets(pir, _5VIZ_G)
        @test offs == Set([(0, 8), (8, 8)])
        # …and the cells those stamps MEAN, under BennettVM's own formula.
        @test Set(_5viz_cell(p) for p in offs) == Set([0, 8])
        # The dst is the word tier: byte offset 8 is cell +1 there. ONE memcpy,
        # TWO cell maps — and that is correct.
        doffs = _5viz_offsets(pir, :d)
        @test doffs == Set([(0, 64), (8, 64)])
        @test Set(_5viz_cell(p) for p in doffs) == Set([0, 1])
        @test 8 ÷ (8 ÷ 8) != 8 ÷ (64 ÷ 8)
        cps = _5viz_copy_stores(pir, :d)
        @test length(cps) == 2
        @test all(s -> s.width == 64, cps)
    end

    # ======================================================================
    # (c) NON-ZERO SRC OFFSET — the second half of the sy29 §5 obligation. The
    #     offset must be measured from the CANONICAL GLOBAL ROOT and carried
    #     into the emission; a HEAD-style `k * ew_bytes` alone would address
    #     cell 0 and read the blob's `length` slot instead of its `data` slot.
    # ======================================================================
    @testset "(c) non-zero src offset is carried from the canonical root" begin
        pir = _5viz_extract(_5VIZ_OFF8_LL, "v5_off8")
        offs = _5viz_offsets(pir, _5VIZ_G)
        @test offs == Set([(8, 8)])
        @test Set(_5viz_cell(p) for p in offs) == Set([8])
        @test isempty(_5viz_offsets(pir, :s))
    end

    # ======================================================================
    # (d) THE CANON-BLOCK TRAP — the dead-arm control.
    #
    # Every fixture built by `_5viz_fx` is THREE blocks: the definition chain in
    # `%top`, the `extractvalue` in `%L1`, the memcpy in `%L2`. `_57hd_canon` is
    # INTRA-BLOCK, so BOTH naive choices return the value UNCHANGED:
    #   * canon in the MEMCPY's block (`%L2`)      → dead arm, wall persists;
    #   * canon in the `extractvalue`'s own block (`%L1`) → dead arm too.
    # Only `LLVM.parent(stripped_value)` (`%top`) reaches the global. So gate (a)
    # passing IS the control — this gate states the invariant explicitly, and
    # asserts the structural precondition (the memcpy's block contains no part
    # of the chain) so a future fixture edit that collapses the blocks cannot
    # silently disarm it.
    # ======================================================================
    @testset "(d) canon runs in the STRIPPED VALUE's defining block" begin
        # The fixture really is three blocks with the chain confined to `%top`.
        @test occursin("br label %L1", _5VIZ_K1_LL)
        @test occursin("br label %L2", _5VIZ_K1_LL)
        body = split(_5VIZ_K1_LL, "L2:")[end]
        for producer in ("insertvalue", "gc_alloc_obj", "store { ptr, ptr }")
            @test !occursin(producer, body)          # nothing to canon in %L2
        end
        l1 = split(split(_5VIZ_K1_LL, "L1:")[end], "L2:")[1]
        @test !occursin("insertvalue", l1)           # nothing to canon in %L1
        # And the arm still fires, with the GLOBAL as the proven src root.
        pir = _5viz_extract(_5VIZ_K1_LL, "v5_k1")
        @test _5viz_offsets(pir, _5VIZ_G) == Set([(0, 8)])
    end

    # ======================================================================
    # (e) NON-SINGLETON LOADED SRC — canon succeeds but lands on a
    #     `julia.gc_alloc_obj` CALL, not a load of a `.globals` singleton. No
    #     capacity, no scale, no root identity ⇒ Predicates 6d and 7 would both
    #     be unenforceable, which is precisely the hole sy29's hostile review D2
    #     EXECUTED. The UNCHANGED wall must stand, character for character.
    # ======================================================================
    @testset "(e) non-singleton loaded src keeps the 37mt/8bys wall" begin
        msg = _5viz_msg(_5VIZ_NONSINGLE_LL, "v5_ns")
        @test msg != ""
        @test _is_37mt_src_wall(msg)
        @test occursin("Bennett-8bys", msg)
        @test !occursin("Bennett-5viz", msg)
        @test !occursin("jl_global", msg)
    end

    # ======================================================================
    # (f) CANONICALISED-GLOBAL DST — refused. BennettVM's global tier
    #     (`GLOBAL_BASE = 2^48`) is READ-ONLY; a `MemoryStore` there fails loud
    #     at run time anyway, but CLAUDE.md §1 wants the refusal at the earliest
    #     point. 5viz adds NO dst-side canonicalisation, so the DST half of
    #     Predicate 6 owns this and its text is unchanged. Pinned to what IS
    #     there (the sy29 lesson), not to a message we wish were there.
    # ======================================================================
    @testset "(f) canonicalised-global dst is refused by Predicate 6's dst half" begin
        msg = _5viz_msg(_5VIZ_GDST_LL, "v5_gdst")
        @test msg != ""
        @test occursin("dst operand is not alloca-backed", msg)
        @test occursin("Bennett-37mt", msg)
        @test !occursin("Bennett-5viz", msg)
        # It is the DST half, not the SRC half — the src of THIS memcpy is the
        # alloca, so the src reject must NOT be what fires.
        @test !occursin("src operand is not alloca-backed", msg)
    end

    # ======================================================================
    # (g) 6d IN-OBJECT RANGE — bytes [8, 24) of a 16-byte blob. This is the
    #     predicate that makes Predicate 7's disjointness argument TRUE rather
    #     than assumed; without it an over-long src silently reads whatever the
    #     VM seeded next (`leak = 999` on sy29's reviewer probe). Capacity comes
    #     from doih G8's own formula, `length(data) * (ew ÷ 8) == 16 * 1`.
    # ======================================================================
    @testset "(g) over-capacity global src is refused by Predicate 6d" begin
        msg = _5viz_msg(_5VIZ_OOB_LL, "v5_oob")
        @test msg != ""
        @test occursin("Bennett-5viz", msg)
        @test occursin("Predicate 6d", msg)
        @test occursin("_5viz_global_src_root", msg)
        @test occursin("jl_global#93", msg)
        # It must NOT degrade into the generic "not alloca-backed" wall: the src
        # WAS certified, and reporting otherwise would be actively misleading.
        @test !_is_37mt_src_wall(msg)
        # The corpus is FLUSH on this bound (`0 + 8 <= 16`), so gate (a) is this
        # predicate's own mutation test: flipping `<=` to `<` reddens (a).
        @test occursin("16", msg)
    end

    # ======================================================================
    # (h) 6c CELL ALIGNMENT — byte 4 of the blob. `_check_scale_coherence!` says
    #     NOTHING here (a byte GEP off a byte-tier root is coherent by
    #     construction), so this is a genuinely separate guard: the byte tier
    #     names a 64-bit value by its BASE byte address and never names +1…+7,
    #     so an 8-byte chunk starting at byte 4 has no faithful single-cell
    #     gather.
    # ======================================================================
    @testset "(h) sub-cell global src offset is refused by Predicate 6c" begin
        msg = _5viz_msg(_5VIZ_MISALIGN_LL, "v5_mis")
        @test msg != ""
        @test occursin("Bennett-5viz", msg)
        @test occursin("Predicate 6c", msg)
        @test occursin("_5viz_global_src_root", msg)
        @test !_is_37mt_src_wall(msg)
    end

    # ======================================================================
    # (i) `ptr_cells=false` BYTE-IDENTITY. The whole branch is behind
    #     `ptr_cells &&`, so the circuit path never reaches it and every
    #     pre-5viz message is unchanged character-for-character. That is the
    #     vbv9 / u2kk / qmv7 / sy29 gating pattern, and it is what keeps
    #     `test_37mt` and `test_lqif` pinned.
    # ======================================================================
    @testset "(i) circuit path (ptr_cells=false) is unchanged" begin
        # The DIRECT fixture reaches the memcpy on the circuit path (it has no
        # `{ptr,ptr}` `insertvalue`), so it pins the UNCHANGED Predicate-6 text.
        msg = _5viz_msg(_5VIZ_DIRECT_LL, "v5_direct"; cells = false)
        @test _is_37mt_src_wall(msg)
        @test !occursin("Bennett-5viz", msg)
        # The corpus-shaped fixtures wall EARLIER on the circuit path, at the
        # Bennett-6bu3 pointer-field `insertvalue` reject — also unchanged, and
        # never a 5viz message.
        for (ll, fn) in ((_5VIZ_K1_LL, "v5_k1"), (_5VIZ_K2_LL, "v5_k2"),
                         (_5VIZ_OOB_LL, "v5_oob"), (_5VIZ_MISALIGN_LL, "v5_mis"))
            m = _5viz_msg(ll, fn; cells = false)
            @test m != ""
            @test occursin("Bennett-6bu3", m)
            @test !occursin("Bennett-5viz", m)
        end
    end

    # ======================================================================
    # (j) WALL 14 PRE-EXISTS 5viz AND BELONGS TO THE `Bennett-bvmd` FAMILY.
    #
    # The corpus dst is a BYTE GEP into a WORD-tier `alloca [9 x i64]`. bvmd's
    # use-directed BYTE-NORMALISATION does not fire on it, and the reason is the
    # memcpy arm itself: the ALREADY-SHIPPED 37mt/sy29 emission for corpus site
    # #3 stamps `ptr_ew_dst = 8 * _root_scale(env)[1] = 64`, which sets
    # `all_byte[env] = false`. 5viz keeps that rule UNCHANGED (scout §3): its
    # dst is byte-identical in shape to site #3's, so 5viz neither creates nor
    # worsens wall 14, and flipping the dst stamp is a TIER decision with blast
    # radius across three shipped arms — `Bennett-bvmd`'s charter, not a
    # memcpy-src capability. The scout's probe `p10` records that byte-stamping
    # ALL THREE env-rooted memcpys makes the ROOT extract with NO WALL AT ALL;
    # that datum is filed on the bvmd bead rather than acted on here.
    #
    # What this gate pins is that the 5viz SRC ADMISSION FIRED: the program no
    # longer walls at the 37mt src reject, it walls at the bvmd tier check.
    # ======================================================================
    @testset "(j) byte-GEP'd env dst reaches the pre-existing bvmd wall" begin
        msg = _5viz_msg(_5VIZ_BYTEDST_LL, "v5_bytedst")
        @test msg != ""
        # The src admission FIRED — this is no longer a 37mt src reject.
        @test !_is_37mt_src_wall(msg)
        # …and the residual is the bvmd tier question, named as such.
        @test occursin("SCALE-COHERENCE", msg)
        @test occursin("Bennett-bvmd", msg)
        @test !occursin("Bennett-5viz", msg)
    end

    # ======================================================================
    # (k) THE CORPUS GATE — wall 11 → wall 12.
    #
    # ┌──────────────────── THE `.mem` SUFFIX TRAP — MEASURED ─────────────────┐
    # │ Wall 12's message DOES contain the substring `new::Array.ref` (it       │
    # │ quotes `store { ptr, ptr } %"new::Array.ref", …`). It does NOT contain  │
    # │ `new::Array.ref.mem`. So the wall-11 regression detector inverts safely │
    # │ ONLY IF THE `.mem` SUFFIX IS KEPT: `!occursin("new::Array.ref.mem")` is │
    # │ correct; `!occursin("new::Array.ref")` would be RED. Check every        │
    # │ rewritten marker against the REAL wall-12 text — the sy29 lesson, again.│
    # └────────────────────────────────────────────────────────────────────────┘
    #
    # Wall 12 is `Bennett-p06b`'s OWN reject (the `alloca { ptr, ptr }` whose
    # allocated type the alloca arm SILENTLY SKIPS). Its message does NOT
    # contain the string `Bennett-1zow` — a marker written against that bead tag
    # would never fire — and it does NOT contain `Bennett-37mt`. Pin what IS
    # there.
    # ======================================================================
    @testset "(k) push! corpus advances from wall 11 to wall 12" begin
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
        @test msg != ""                        # walls 12+ remain
        # WALL 12, POSITIVE — pinned on what the message actually says.
        @test occursin("Bennett-p06b", msg)
        @test occursin("_p06b_cell_ptr_target_kind", msg)
        @test occursin("SILENTLY SKIPS", msg)
        # WALL 11 IS CLEARED — a 37mt/8bys src reject at the corpus is now a
        # REGRESSION. This negative is STRONGER than the operand-name pair it
        # replaces, because it does not depend on which operand the prefix
        # quotes.
        @test !occursin("Bennett-37mt", msg)
        @test !occursin("new::Array.ref.mem", msg)   # keep the `.mem` SUFFIX
        @test !occursin("Bennett-5viz", msg)         # 5viz is not the new wall
        # Walls 3/5/6/8/9/10 stay cleared.
        @test !occursin("base-cancelling", msg)
        @test !occursin("_foz5_confined_dead_bounds", msg)
        @test !occursin("_57hd_value_identity_cluster", msg)
        @test !occursin("Bennett-sy29", msg)
        @test !occursin("SCALE-COHERENCE", msg)
        for neg in ("Bennett-jbko", "Bennett-iwo9", "Bennett-lgzx", "memmove",
                    "BYTE-granular getelementptr", "Bennett-bvmd",
                    "store of non-integer type")
            @test !occursin(neg, msg)
        end
        # …and the p06b reject here is the AGGREGATE-STORE one, not the
        # gc_alloc_obj one (wall 8's inverted discriminator, unchanged).
        @test !(occursin("Bennett-p06b", msg) && occursin("gc_alloc_obj", msg))
    end
end
